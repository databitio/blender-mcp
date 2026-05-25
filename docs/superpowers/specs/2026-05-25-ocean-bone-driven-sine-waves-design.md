# Ocean Bone-Driven Sine Wave Displacement

**Date:** 2026-05-25
**Status:** Approved
**Supersedes:** [Ocean Wind Waker Sine Waves](2026-05-25-ocean-windwaker-sine-waves-design.md)
**Relates to:** [Ocean 4x4 Armature Design](2026-05-22-ocean-4x4-armature-design.md)

## Overview

Merge the bone animation system with the deterministic sine wave engine. Instead of displacing whole chunks as rigid bodies OR playing baked bone animations, drive each bone's Y position at runtime using the same `waveHeight(worldX, worldZ, time)` function. The result is a continuous deformable ocean surface with per-vertex detail, seamless tiling by mathematical construction, and no dependency on pre-baked animation assets.

Single module (`OceanSystem.lua`) replaces both `OceanSystem.lua` (chunk-level sine) and `OceanSystemAnimated.lua` (baked bone animation).

## Goals

- Per-bone vertex deformation creating a smooth, continuous ocean surface
- Deterministic sine math guarantees seamless tiling between adjacent chunks
- No baked animation dependency — Lua drives all bone transforms at runtime
- Single unified ocean module replacing both existing variants
- Keep existing 4-wave Wind Waker compound sine preset
- Reuse existing 4×4 Blender rig pipeline (mesh + rig + bind + export, no animation step)

## Non-Goals

- Per-vertex shader deformation (beyond what bone skinning provides)
- LOD system for distant chunks
- Physics/buoyancy/collision
- Foam or multi-texture layering (separate future spec)
- Retuning wave presets (use existing preset, tune later by feel)

---

## Section 1: Architecture

### System Overview

1. Camera-following grid spawns rigged MeshPart chunks (4×4 bone grid, 16 bones each)
2. Every Heartbeat, iterates all bones in all active chunks
3. For each bone: computes world position (chunk origin + bone local offset), evaluates `waveHeight(worldX, worldZ, time)`, sets `Bone.Transform` to Y displacement
4. Chunks stay fixed at `baseHeight` — all visible surface motion comes from bone transforms
5. Texture scrolling continues unchanged

### Key Invariant

`waveHeight` is a pure function of world position and time. Two bones at the same world position always produce the same Y displacement regardless of which chunk they belong to. Adjacent chunks' edge bones are 16 studs apart (same spacing as interior bones), and the continuous sine function varies smoothly across that gap. Vertex skinning interpolates between bones identically at chunk boundaries as within chunks.

### Heartbeat Loop Order

1. `updateGrid(c)` — spawn/despawn chunks, cache bone references for new chunks
2. `updateBones(c, dt)` — evaluate sine at each bone's world pos, set transforms
3. `updateTextures(c, dt)` — scroll UVs

This order ensures newly spawned chunks get correct bone transforms on the same frame.

### Performance Budget

| Metric | Value |
|--------|-------|
| Bones per chunk | 16 (4×4 grid) |
| Chunks (5×5 grid, radius=2) | 25 |
| Bone updates per frame | 400 |
| `math.sin` calls per frame | 1,600 (4 waves × 400 bones) |
| CFrame property sets per frame | 400 |
| Estimated Lua cost | ~0.112ms/frame |
| Frame budget usage (60fps) | < 1% |

---

## Section 2: Runtime Data Model

### Chunk State

```lua
type ChunkData = {
    part: MeshPart,
    bones: { Bone },         -- flat list of all 16 bones, cached at spawn
    offsets: { Vector3 },    -- each bone's local rest position (constant)
}

local activeChunks: { [string]: ChunkData } = {}
local chunkPool: { ChunkData } = {}
```

### Core Update Function

```lua
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
```

### Wave Height Function (unchanged)

```lua
local function waveHeight(x: number, z: number, time: number, c: ResolvedConfig): number
    local y = 0
    for _, wave in ipairs(c.waves) do
        y += wave.amplitude * math.sin(
            wave.frequencyX * x + wave.frequencyZ * z + wave.phase + wave.speed * time
        )
    end
    return y / #c.waves
end
```

---

## Section 3: Chunk Lifecycle

### Spawn (acquireChunk)

Pull from pool or clone template, then cache bone references:

```lua
local function cacheBones(part: MeshPart): ({ Bone }, { Vector3 })
    local bones = {}
    local offsets = {}
    for _, desc in ipairs(part:GetDescendants()) do
        if desc:IsA("Bone") then
            table.insert(bones, desc)
            table.insert(offsets, desc.Position)
        end
    end
    return bones, offsets
end
```

Runs once per spawn. Offsets are constant for the chunk's lifetime.

### Release (releaseChunk)

Reset bone transforms to identity before pooling:

```lua
local function releaseChunk(chunk: ChunkData)
    for _, bone in ipairs(chunk.bones) do
        bone.Transform = CFrame.identity
    end
    chunk.part.Parent = nil
    table.insert(chunkPool, chunk)
end
```

### Re-acquire from Pool

Bone references and offsets remain valid. Place the chunk, `updateBones` sets correct transforms on the same frame.

### Graceful Degradation

If chunk template has zero bones, log a warning once and operate as a static tiling grid (no crash, no deformation).

---

## Section 4: Config & Public API

### Types

```lua
export type WaveParams = {
    amplitude: number,
    frequencyX: number,
    frequencyZ: number,
    phase: number,
    speed: number,
}

export type OceanConfig = {
    chunkTemplate: Instance,    -- rigged MeshPart with Bone descendants
    textureId: string?,
    gridRadius: number?,        -- default 2 (5×5 grid)
    chunkSize: number?,         -- default 64
    studsPerTile: number?,      -- default 16
    scrollSpeed: Vector2?,      -- default Vector2.new(2, 1)
    baseHeight: number?,        -- default -10
    foamEdges: boolean?,        -- default false (reserved)
    waves: { WaveParams }?,     -- default 4-wave Wind Waker preset
    waveSpeed: number?,         -- default 1.0
}
```

### Default Wave Preset (unchanged)

| Wave | Amplitude | FreqX | FreqZ | Phase | Speed |
|------|-----------|-------|-------|-------|-------|
| 1 | 1.0 | 1.0 | 0.0 | 0 | 1.0 |
| 2 | 0.8 | 2.2 | 0.5 | 5.52 | 1.3 |
| 3 | 0.6 | 0.5 | 2.9 | 0.93 | 0.8 |
| 4 | 0.4 | 1.8 | 4.6 | 8.94 | 1.6 |

### Minimal Usage

```lua
local Ocean = require(path.to.OceanSystem)
Ocean.start({
    chunkTemplate = game.ReplicatedStorage.OceanChunk,
    textureId = "rbxassetid://XXXXX",
})
```

---

## Section 5: Blender Pipeline Changes

### Retained Handlers (4×4 only)

| Handler | Purpose | Changes |
|---------|---------|---------|
| `create_ocean_mesh_4x4` | Subdivided plane (8×8) | None |
| `create_ocean_rig_4x4` | 4×4 bone grid | None |
| `bind_ocean_rig_4x4` | Auto-weight vertices to bones | None |
| `export_ocean_fbx_4x4` | Export rigged mesh | Remove animation baking, export mesh+armature+weights only |

### Removed

| Item | Reason |
|------|--------|
| `animate_ocean_waves_4x4` handler | No baked animation needed |
| `animate_ocean_waves_4x4` MCP tool | No baked animation needed |
| All 3×3 handlers (5 total) | Replaced by 4×4 only |
| All 3×3 MCP tools (5 total) | Replaced by 4×4 only |
| `ocean_chunk_workflow` prompt (3×3) | Superseded |

### Updated

| Item | Change |
|------|--------|
| `ocean_chunk_4x4_workflow` prompt | Reduced to 4 steps: create mesh → create rig → bind → export |
| `export_ocean_fbx_4x4` handler | Skip animation bake, export static rig only |

### Simplified Workflow

1. `create_ocean_mesh_4x4(chunk_size=64, subdivisions=8)`
2. `create_ocean_rig_4x4(chunk_size=64)`
3. `bind_ocean_rig_4x4()`
4. `export_ocean_chunk_4x4(filepath="...")`

---

## Section 6: File Changes Summary

| File | Action |
|------|--------|
| `src/roblox/OceanSystem.lua` | Rewrite: bone-driven sine displacement, ChunkData type, updateBones, cacheBones |
| `src/roblox/OceanSystemAnimated.lua` | Delete |
| `src/blender_mcp/addon.py` | Remove 3×3 handlers, remove `animate_ocean_waves_4x4`, simplify `export_ocean_fbx_4x4` |
| `src/blender_mcp/server.py` | Remove 3×3 tools, remove animate_4x4 tool, update workflow prompt |

## Seamless Tiling Proof

Given two adjacent chunks A (at X=0) and B (at X=64) with `chunkSize=64` and 4×4 bones at spacing 16:

- Chunk A's rightmost bone column: world X = 0 + 48 = 48
- Chunk B's leftmost bone column: world X = 64 + 0 = 64

The sine function is continuous over [48, 64]. Vertices at the chunk boundary (X=64) are skinned by interpolating between bone at X=48 (chunk A's edge) and bone at X=64 (chunk B's edge). Both bone Y values come from the same continuous function, producing a smooth interpolation with no discontinuity.

This is identical to the interpolation between any two adjacent bones WITHIN a chunk (also 16 studs apart), so the boundary is visually indistinguishable from the interior.
