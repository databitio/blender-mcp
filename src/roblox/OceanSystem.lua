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
            gridRadius    = 2,
            chunkSize     = 64,
            studsPerTile  = 16,
            scrollSpeed   = Vector2.new(2, 1),
            baseHeight    = -10,
        })
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
	textureId: string?,
	gridRadius: number?,
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
	textureId: string?,
	gridRadius: number,
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
}

local OceanSystem = {}

local DEFAULT_WAVES: { WaveParams } = {
	{ amplitude = 1.0, frequencyX = 1.0, frequencyZ = 0.0, phase = 0, speed = 1.0 },
	{ amplitude = 0.8, frequencyX = 2.2, frequencyZ = 0.5, phase = 5.52, speed = 1.3 },
	{ amplitude = 0.6, frequencyX = 0.5, frequencyZ = 2.9, phase = 0.93, speed = 0.8 },
	{ amplitude = 0.4, frequencyX = 1.8, frequencyZ = 4.6, phase = 8.94, speed = 1.6 },
}

-- Module state
local running: boolean = false
local activeChunks: { [string]: ChunkData } = {}
local chunkPool: { ChunkData } = {}
local heartbeatConn: RBXScriptConnection? = nil
local container: Folder? = nil
local scrollU: number = 0
local scrollV: number = 0
local elapsed: number = 0
local warnedNoBones: boolean = false

local function chunkKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

local function resolveConfig(raw: OceanConfig): ResolvedConfig
	assert(typeof(raw.chunkTemplate) == "Instance", "OceanSystem: chunkTemplate is required")

	local template = if raw.chunkTemplate:IsA("MeshPart")
		then raw.chunkTemplate
		else raw.chunkTemplate:FindFirstChildWhichIsA("MeshPart", true)
	assert(template, "OceanSystem: chunkTemplate must be or contain a MeshPart")

	return {
		chunkTemplate = template,
		textureId = raw.textureId,
		gridRadius = raw.gridRadius or 2,
		chunkSize = raw.chunkSize or 64,
		studsPerTile = raw.studsPerTile or 16,
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

local function createChunk(c: ResolvedConfig): ChunkData
	local part = c.chunkTemplate:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false

	if c.textureId then
		local tex = Instance.new("Texture")
		tex.Texture = c.textureId
		tex.Face = Enum.NormalId.Top
		tex.StudsPerTileU = c.studsPerTile
		tex.StudsPerTileV = c.studsPerTile
		tex.Parent = part
	end

	local bones, offsets = cacheBones(part)
	return { part = part, bones = bones, offsets = offsets }
end

local function acquireChunk(c: ResolvedConfig): ChunkData
	if #chunkPool > 0 then
		return table.remove(chunkPool) :: ChunkData
	end
	return createChunk(c)
end

local function releaseChunk(chunk: ChunkData)
	for _, bone in ipairs(chunk.bones) do
		bone.Transform = CFrame.identity
	end
	chunk.part.Parent = nil
	table.insert(chunkPool, chunk)
end

local function updateGrid(c: ResolvedConfig)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local pos = cam.CFrame.Position
	local cx = math.floor(pos.X / c.chunkSize)
	local cz = math.floor(pos.Z / c.chunkSize)
	local r = c.gridRadius

	local needed: { [string]: { number } } = {}
	for dx = -r, r do
		for dz = -r, r do
			needed[chunkKey(cx + dx, cz + dz)] = { cx + dx, cz + dz }
		end
	end

	for key, chunk in pairs(activeChunks) do
		if not needed[key] then
			releaseChunk(chunk)
			activeChunks[key] = nil
		end
	end

	for key, cell in pairs(needed) do
		if not activeChunks[key] then
			local chunk = acquireChunk(c)
			chunk.part.Position = Vector3.new(cell[1] * c.chunkSize, c.baseHeight, cell[2] * c.chunkSize)
			chunk.part.Parent = container
			activeChunks[key] = chunk
		end
	end
end

local function updateTextures(c: ResolvedConfig, dt: number)
	scrollU = (scrollU + c.scrollSpeed.X * dt) % c.studsPerTile
	scrollV = (scrollV + c.scrollSpeed.Y * dt) % c.studsPerTile

	for _, chunk in pairs(activeChunks) do
		local tex = chunk.part:FindFirstChildOfClass("Texture")
		if tex then
			tex.OffsetStudsU = scrollU
			tex.OffsetStudsV = scrollV
		end
	end
end

function OceanSystem.start(rawConfig: OceanConfig)
	if running then
		OceanSystem.stop()
	end

	local c = resolveConfig(rawConfig)
	running = true
	scrollU = 0
	scrollV = 0
	elapsed = 0
	warnedNoBones = false

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

	for _, chunk in ipairs(chunkPool) do
		chunk.part:Destroy()
	end
	table.clear(chunkPool)

	if container then
		container:Destroy()
		container = nil
	end

	running = false
	scrollU = 0
	scrollV = 0
	elapsed = 0
end

return OceanSystem
