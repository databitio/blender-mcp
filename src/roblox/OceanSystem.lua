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
    { amplitude = 1.0, frequencyX = 1.0, frequencyZ = 0.0, phase = 0,    speed = 1.0 },
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
    assert(typeof(raw.chunkTemplate) == "Instance",
        "OceanSystem: chunkTemplate is required")

    local template = if raw.chunkTemplate:IsA("MeshPart")
        then raw.chunkTemplate
        else raw.chunkTemplate:FindFirstChildWhichIsA("MeshPart", true)
    assert(template, "OceanSystem: chunkTemplate must be or contain a MeshPart")

    return {
        chunkTemplate = template,
        textureId   = raw.textureId,
        gridRadius  = raw.gridRadius or 2,
        chunkSize   = raw.chunkSize or 64,
        studsPerTile = raw.studsPerTile or 16,
        scrollSpeed = raw.scrollSpeed or Vector2.new(2, 1),
        baseHeight  = raw.baseHeight or -10,
        foamEdges   = if raw.foamEdges ~= nil then raw.foamEdges else false,
        waves       = raw.waves or DEFAULT_WAVES,
        waveSpeed   = raw.waveSpeed or 1.0,
    }
end

return OceanSystem
