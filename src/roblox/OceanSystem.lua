--!strict
--[[
    OceanSystem — camera-following tiling ocean with bone-driven sine waves.
    Clones a rigged MeshPart (4×4 bone grid) into an NxN grid that tracks
    the camera. Each bone's Y is set per-frame via deterministic waveHeight()
    evaluated at its world position. Seamless tiling by construction.

    Usage:
        local Ocean = require(path.to.OceanSystem)
        Ocean.start({
            chunkTemplate = game.ReplicatedStorage.OceanChunk,
            textureId     = "rbxassetid://XXXXX",
            gridRadius    = 1,
            chunkSize     = 512,
            studsPerTile  = 128,
            scrollSpeed   = Vector2.new(2, 1),
            baseHeight    = -10,
        })

        -- Hot-swap waves based on player location:
        Ocean.setWaves({
            { amplitude = 1.0, frequencyX = 0.008, frequencyZ = 0.004, phase = 0, speed = 0.4 },
        })

        -- Or change multiple config fields at once:
        Ocean.setConfig({ waveSpeed = 0.5, baseHeight = -15 })

        Ocean.stop()
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type WaveParams = {
	amplitude: number,
	frequencyX: number,
	frequencyZ: number,
	phase: number,
	speed: number,
}

export type OceanConfig = {
	chunkTemplate: Instance,
	farChunkTemplate: Instance?,
	textureId: string?,
	gridRadius: number?,
	nearRadius: number?,
	chunkSize: number?,
	studsPerTile: number?,
	scrollSpeed: Vector2?,
	baseHeight: number?,
	foamEdges: boolean?,
	waves: { WaveParams }?,
	waveSpeed: number?,
}

type ResolvedConfig = {
	chunkTemplate: MeshPart,
	farChunkTemplate: MeshPart?,
	textureId: string?,
	gridRadius: number,
	nearRadius: number,
	chunkSize: number,
	studsPerTile: number,
	scrollSpeed: Vector2,
	baseHeight: number,
	foamEdges: boolean,
	waves: { WaveParams },
	waveSpeed: number,
}

type ChunkData = {
	part: MeshPart,
	bones: { Bone },
	offsets: { Vector3 },
	tex: Texture?,
	tier: "near" | "far",
}

local OceanSystem = {}

local DEFAULT_WAVES: { WaveParams } = {
	{ amplitude = 3.0, frequencyX = 0.008, frequencyZ = 0.000, phase = 0,   speed = 0.6 },
	{ amplitude = 2.0, frequencyX = 0.012, frequencyZ = 0.004, phase = 1.2, speed = 0.8 },
	{ amplitude = 1.5, frequencyX = 0.004, frequencyZ = 0.010, phase = 2.5, speed = 0.5 },
	{ amplitude = 1.0, frequencyX = 0.010, frequencyZ = 0.008, phase = 4.0, speed = 1.0 },
}

-- Module state
local running: boolean = false
local activeConfig: ResolvedConfig? = nil
local activeChunks: { [string]: ChunkData } = {}
local nearPool: { ChunkData } = {}
local farPool: { ChunkData } = {}
local heartbeatConn: RBXScriptConnection? = nil
local container: Folder? = nil
local scrollU: number = 0
local scrollV: number = 0
local elapsed: number = 0
local warnedNoBones: boolean = false
local lastCX: number = math.huge
local lastCZ: number = math.huge

local function chunkKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

local function resolveConfig(raw: OceanConfig): ResolvedConfig
	assert(typeof(raw.chunkTemplate) == "Instance", "OceanSystem: chunkTemplate is required")

	local template = if raw.chunkTemplate:IsA("MeshPart")
		then raw.chunkTemplate
		else raw.chunkTemplate:FindFirstChildWhichIsA("MeshPart", true)
	assert(template, "OceanSystem: chunkTemplate must be or contain a MeshPart")

	local farTemplate: MeshPart? = nil
	if raw.farChunkTemplate then
		farTemplate = if raw.farChunkTemplate:IsA("MeshPart")
			then raw.farChunkTemplate :: MeshPart
			else raw.farChunkTemplate:FindFirstChildWhichIsA("MeshPart", true) :: MeshPart?
	end

	local chunkSize = raw.chunkSize or template.Size.X
	local desiredTile = raw.studsPerTile or 16
	local tilesPerChunk = math.max(1, math.round(chunkSize / desiredTile))

	local gridRadius = raw.gridRadius or 2
	local nearRadius = raw.nearRadius or 1
	assert(nearRadius <= gridRadius, "OceanSystem: nearRadius must be <= gridRadius")

	return {
		chunkTemplate = template,
		farChunkTemplate = farTemplate,
		textureId = raw.textureId,
		gridRadius = gridRadius,
		nearRadius = nearRadius,
		chunkSize = chunkSize,
		studsPerTile = chunkSize / tilesPerChunk,
		scrollSpeed = raw.scrollSpeed or Vector2.new(2, 1),
		baseHeight = raw.baseHeight or -10,
		foamEdges = if raw.foamEdges ~= nil then raw.foamEdges else false,
		waves = raw.waves or DEFAULT_WAVES,
		waveSpeed = raw.waveSpeed or 1.0,
	}
end

local function waveHeight(x: number, z: number, time: number, c: ResolvedConfig): number
	local y = 0
	for _, wave in ipairs(c.waves) do
		y += wave.amplitude * math.sin(wave.frequencyX * x + wave.frequencyZ * z + wave.phase + wave.speed * time)
	end
	return y / #c.waves
end

local function cacheBones(part: MeshPart): ({ Bone }, { Vector3 })
	local bones: { Bone } = {}
	local offsets: { Vector3 } = {}
	-- Scale bone offsets from MeshSize space to Size space so edge bones
	-- align with chunk boundaries and adjacent chunks produce identical waves.
	local scaleX = if part.MeshSize.X > 0.001 then part.Size.X / part.MeshSize.X else 1
	local scaleZ = if part.MeshSize.Z > 0.001 then part.Size.Z / part.MeshSize.Z else 1
	for _, desc in ipairs(part:GetDescendants()) do
		if desc:IsA("Bone") then
			table.insert(bones, desc)
			table.insert(offsets, Vector3.new(desc.Position.X * scaleX, desc.Position.Y, desc.Position.Z * scaleZ))
		end
	end
	if #bones == 0 and not warnedNoBones then
		warnedNoBones = true
		warn("OceanSystem: chunkTemplate has no Bone instances; surface will not deform")
	end
	return bones, offsets
end

local function updateBones(c: ResolvedConfig, dt: number)
	elapsed += dt * c.waveSpeed
	for _, chunk in pairs(activeChunks) do
		local origin = chunk.part.Position
		for i, bone in ipairs(chunk.bones) do
			local offset = chunk.offsets[i]
			local worldX = origin.X + offset.X
			local worldZ = origin.Z + offset.Z
			local y = waveHeight(worldX, worldZ, elapsed, c)
			bone.Transform = CFrame.new(0, y, 0)
		end
	end
end

local function createChunk(c: ResolvedConfig, tier: "near" | "far"): ChunkData
	local template = if tier == "far" and c.farChunkTemplate then c.farChunkTemplate else c.chunkTemplate
	local part = template:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Size = Vector3.new(c.chunkSize, part.Size.Y, c.chunkSize)

	local tex: Texture? = nil
	if c.textureId then
		tex = Instance.new("Texture")
		tex.Texture = c.textureId
		tex.Face = Enum.NormalId.Top
		tex.StudsPerTileU = c.studsPerTile
		tex.StudsPerTileV = c.studsPerTile
		tex.Parent = part
	end

	local bones, offsets = cacheBones(part)
	return { part = part, bones = bones, offsets = offsets, tex = tex, tier = tier }
end

local function acquireChunk(c: ResolvedConfig, tier: "near" | "far"): ChunkData
	local pool = if tier == "near" then nearPool else farPool
	if #pool > 0 then
		return table.remove(pool) :: ChunkData
	end
	return createChunk(c, tier)
end

local function releaseChunk(chunk: ChunkData)
	for _, bone in ipairs(chunk.bones) do
		bone.Transform = CFrame.identity
	end
	chunk.part.Parent = nil
	local pool = if chunk.tier == "near" then nearPool else farPool
	table.insert(pool, chunk)
end

local function updateGrid(c: ResolvedConfig)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local pos = cam.CFrame.Position
	local cx = math.floor(pos.X / c.chunkSize)
	local cz = math.floor(pos.Z / c.chunkSize)

	if cx == lastCX and cz == lastCZ then
		return
	end
	lastCX = cx
	lastCZ = cz

	local r = c.gridRadius
	local nr = c.nearRadius
	local hasFar = c.farChunkTemplate ~= nil

	local needed: { [string]: { cx: number, cz: number, tier: "near" | "far" } } = {}
	for dx = -r, r do
		for dz = -r, r do
			local tier: "near" | "far" = if hasFar and math.max(math.abs(dx), math.abs(dz)) > nr then "far" else "near"
			needed[chunkKey(cx + dx, cz + dz)] = { cx = cx + dx, cz = cz + dz, tier = tier }
		end
	end

	for key, chunk in pairs(activeChunks) do
		if not needed[key] then
			releaseChunk(chunk)
			activeChunks[key] = nil
		end
	end

	for key, cell in pairs(needed) do
		local existing = activeChunks[key]
		if existing and existing.tier ~= cell.tier then
			releaseChunk(existing)
			activeChunks[key] = nil
		end
		if not activeChunks[key] then
			local chunk = acquireChunk(c, cell.tier)
			chunk.part.Position = Vector3.new(cell.cx * c.chunkSize, c.baseHeight, cell.cz * c.chunkSize)
			chunk.part.Parent = container
			activeChunks[key] = chunk
		end
	end
end

local function updateTextures(c: ResolvedConfig, dt: number)
	scrollU = (scrollU + c.scrollSpeed.X * dt) % c.studsPerTile
	scrollV = (scrollV + c.scrollSpeed.Y * dt) % c.studsPerTile

	for _, chunk in pairs(activeChunks) do
		local tex = chunk.tex
		if tex then
			tex.OffsetStudsU = scrollU + chunk.part.Position.X
			tex.OffsetStudsV = scrollV + chunk.part.Position.Z
		end
	end
end

function OceanSystem.start(rawConfig: OceanConfig)
	if running then
		OceanSystem.stop()
	end

	local c = resolveConfig(rawConfig)
	activeConfig = c
	running = true
	scrollU = 0
	scrollV = 0
	elapsed = 0
	warnedNoBones = false
	lastCX = math.huge
	lastCZ = math.huge

	container = Instance.new("Folder")
	container.Name = "OceanChunks"
	container.Parent = Workspace

	updateGrid(c)

	heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		updateGrid(c)
		updateBones(c, dt)
		updateTextures(c, dt)
	end)
end

function OceanSystem.stop()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	for _, chunk in pairs(activeChunks) do
		chunk.part:Destroy()
	end
	table.clear(activeChunks)

	for _, chunk in ipairs(nearPool) do
		chunk.part:Destroy()
	end
	table.clear(nearPool)

	for _, chunk in ipairs(farPool) do
		chunk.part:Destroy()
	end
	table.clear(farPool)

	if container then
		container:Destroy()
		container = nil
	end

	running = false
	activeConfig = nil
	scrollU = 0
	scrollV = 0
	elapsed = 0
	lastCX = math.huge
	lastCZ = math.huge
end

function OceanSystem.setWaves(waves: { WaveParams })
	assert(running and activeConfig, "OceanSystem: must be running to call setWaves")
	activeConfig.waves = waves
end

function OceanSystem.setConfig(overrides: {
	waves: { WaveParams }?,
	waveSpeed: number?,
	scrollSpeed: Vector2?,
	baseHeight: number?,
})
	assert(running and activeConfig, "OceanSystem: must be running to call setConfig")
	local c = activeConfig

	if overrides.waves then
		c.waves = overrides.waves
	end
	if overrides.waveSpeed then
		c.waveSpeed = overrides.waveSpeed
	end
	if overrides.scrollSpeed then
		c.scrollSpeed = overrides.scrollSpeed
	end
	if overrides.baseHeight then
		c.baseHeight = overrides.baseHeight
		for _, chunk in pairs(activeChunks) do
			local pos = chunk.part.Position
			chunk.part.Position = Vector3.new(pos.X, c.baseHeight, pos.Z)
		end
	end
end

return OceanSystem
