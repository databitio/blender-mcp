--!strict
--[[
    OceanSystem — camera-following tiling ocean grid for Roblox.
    Clones a MeshPart into an NxN grid that tracks the camera.
    Per-chunk Y displacement via compound sine waves (Wind Waker style).
    Texture scrolling is driven by Heartbeat.

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

local OceanSystem = {}

-- Module state
local running: boolean = false
local activeChunks: { [string]: MeshPart } = {}
local chunkPool: { MeshPart } = {}
local heartbeatConn: RBXScriptConnection? = nil
local container: Folder? = nil
local scrollU: number = 0
local scrollV: number = 0

local function chunkKey(cx: number, cz: number): string
    return cx .. "," .. cz
end

local function resolveConfig(raw: OceanConfig): ResolvedConfig
    assert(typeof(raw.chunkTemplate) == "Instance",
        "OceanSystem: chunkTemplate is required")

    local template = if raw.chunkTemplate:IsA("MeshPart")
        then raw.chunkTemplate
        else raw.chunkTemplate:FindFirstChildWhichIsA("MeshPart", true)
    assert(template, "OceanSystem: chunkTemplate must be or contain a MeshPart")

    return {
        chunkTemplate = template,
        animationId = raw.animationId,
        textureId   = raw.textureId,
        gridRadius  = raw.gridRadius or 2,
        chunkSize   = raw.chunkSize or 64,
        studsPerTile = raw.studsPerTile or 16,
        scrollSpeed = raw.scrollSpeed or Vector2.new(2, 1),
        waveHeight  = raw.waveHeight or -10,
        foamEdges   = if raw.foamEdges ~= nil then raw.foamEdges else false,
    }
end

local function playAnimation(part: MeshPart, animId: string)
    local ctrl = part:FindFirstChildOfClass("AnimationController")
    if not ctrl then
        ctrl = Instance.new("AnimationController")
        ctrl.Parent = part
    end
    local animator = ctrl:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = ctrl
    end
    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    local track = animator:LoadAnimation(anim)
    track.Looped = true
    track.Priority = Enum.AnimationPriority.Core
    track:Play()
end

local function createChunk(c: ResolvedConfig): MeshPart
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

    if c.animationId then
        playAnimation(part, c.animationId)
    end

    return part
end

local function acquireChunk(c: ResolvedConfig): MeshPart
    if #chunkPool > 0 then
        return table.remove(chunkPool) :: MeshPart
    end
    return createChunk(c)
end

local function releaseChunk(chunk: MeshPart)
    chunk.Parent = nil
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

    -- Build set of cells that should exist
    local needed: { [string]: { number } } = {}
    for dx = -r, r do
        for dz = -r, r do
            needed[chunkKey(cx + dx, cz + dz)] = { cx + dx, cz + dz }
        end
    end

    -- Despawn chunks that left the grid
    for key, chunk in pairs(activeChunks) do
        if not needed[key] then
            releaseChunk(chunk)
            activeChunks[key] = nil
        end
    end

    -- Spawn chunks for newly visible cells
    for key, cell in pairs(needed) do
        if not activeChunks[key] then
            local chunk = acquireChunk(c)
            chunk.Position = Vector3.new(
                cell[1] * c.chunkSize,
                c.waveHeight,
                cell[2] * c.chunkSize
            )
            chunk.Parent = container
            activeChunks[key] = chunk
        end
    end
end

local function updateTextures(c: ResolvedConfig, dt: number)
    scrollU += c.scrollSpeed.X * dt
    scrollV += c.scrollSpeed.Y * dt

    for _, chunk in pairs(activeChunks) do
        local tex = chunk:FindFirstChildOfClass("Texture")
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

    container = Instance.new("Folder")
    container.Name = "OceanChunks"
    container.Parent = Workspace

    updateGrid(c)

    heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
        updateGrid(c)
        updateTextures(c, dt)
    end)
end

function OceanSystem.stop()
    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    for _, chunk in pairs(activeChunks) do
        chunk:Destroy()
    end
    table.clear(activeChunks)

    for _, chunk in ipairs(chunkPool) do
        chunk:Destroy()
    end
    table.clear(chunkPool)

    if container then
        container:Destroy()
        container = nil
    end

    running = false
    scrollU = 0
    scrollV = 0
end

return OceanSystem
