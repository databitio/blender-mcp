# Ocean Wind Waker Sine Wave Displacement

**Date:** 2026-05-25
**Status:** Approved
**Relates to:** [Ocean Tiling System Design](2026-05-21-ocean-tiling-system-design.md)

## Overview

Replace bone-animated wave motion in `OceanSystem.lua` with a deterministic compound sine wave engine inspired by The Legend of Zelda: The Wind Waker. Each chunk's Y position is computed from a pure function of world position and time, eliminating the AnimationController/Animator/Animation dependency entirely. The result is cheaper runtime cost, simpler chunk instances, and seamless tiling by construction.

## Goals

- Remove bone animation dependency from the Lua runtime
- Per-chunk Y displacement via compound sine waves
- Configurable wave parameters with sensible Wind Waker-style defaults
- Seamless tiling without edge-mirroring (deterministic math guarantees continuity)
- Reduced instance count and GC pressure per chunk

## Non-Goals

- Surface vertex deformation (no per-vertex wave shapes within a chunk)
- Blender pipeline changes (separate future spec)
- Visual layering pass (multi-texture masking, foam rings, LOD — separate future spec)

---

## Section 1: Compound Sine Wave Engine

A pure function computes wave height at any world position:

```lua
local function waveHeight(x: number, z: number, time: number, config: ResolvedConfig): number
    local y = 0
    for i, wave in ipairs(config.waves) do
        y += wave.amplitude * math.sin(
            wave.frequencyX * x + wave.frequencyZ * z + wave.phase + wave.speed * time
        )
    end
    return y / #config.waves
end
```

Each chunk evaluates `waveHeight(chunkCenterX, chunkCenterZ, elapsedTime, config)` every frame and sets its Y position to `baseHeight + result`.

### Default Wave Preset

4 stacked sine waves matching Wind Waker's compound sine approach:

| Wave | Amplitude | FreqX | FreqZ | Phase | Speed |
|------|-----------|-------|-------|-------|-------|
| 1 | 1.0 | 1.0 | 0.0 | 0 | 1.0 |
| 2 | 0.8 | 2.2 | 0.5 | 5.52 | 1.3 |
| 3 | 0.6 | 0.5 | 2.9 | 0.93 | 0.8 |
| 4 | 0.4 | 1.8 | 4.6 | 8.94 | 1.6 |

### Seamless Tiling Property

The function is deterministic and continuous. Adjacent chunks at positions that are multiples of `chunkSize` produce smoothly varying heights. No edge-mirroring or bone-matching is needed.

---

## Section 2: Config Changes

### New Type

```lua
export type WaveParams = {
    amplitude: number,
    frequencyX: number,
    frequencyZ: number,
    phase: number,
    speed: number,
}
```

### OceanConfig Changes

**Removed:**
- `animationId: string?` — bone animation replaced by sine math

**Added:**
- `waves: { WaveParams }?` — table of wave layer definitions (defaults to 4-wave preset)
- `waveSpeed: number?` — global time multiplier for all waves (default `1.0`)

**Renamed:**
- `waveHeight` -> `baseHeight` — the resting Y plane that sine displacement oscillates around (default `-10`)

**Unchanged:**
- `chunkTemplate` — still a MeshPart, just no longer needs bones
- `textureId`, `gridRadius`, `chunkSize`, `studsPerTile`, `scrollSpeed`, `foamEdges`

### Minimal Usage

```lua
Ocean.start({
    chunkTemplate = game.ReplicatedStorage.OceanChunk,
    textureId = "rbxassetid://XXXXX",
})
```

All wave parameters default to the Wind Waker preset. A user only needs a flat MeshPart and a texture.

---

## Section 3: Runtime Loop Changes

### Removed

- `playAnimation` function
- AnimationController / Animator / Animation instance creation in `createChunk`

### New State

```lua
local elapsed: number = 0
```

### New Function

```lua
local function updateWaves(c: ResolvedConfig, dt: number)
    elapsed += dt * c.waveSpeed
    for _, chunk in pairs(activeChunks) do
        local pos = chunk.Position
        local y = waveHeight(pos.X, pos.Z, elapsed, c)
        chunk.Position = Vector3.new(pos.X, c.baseHeight + y, pos.Z)
    end
end
```

### Heartbeat Order

1. `updateGrid(c)` — spawn/despawn chunks (places new chunks at `baseHeight`)
2. `updateWaves(c, dt)` — displace chunk Y positions (corrects new chunks immediately)
3. `updateTextures(c, dt)` — scroll UVs

This order ensures newly spawned chunks never flash at the wrong Y for a frame.

### stop() Changes

Reset `elapsed = 0` alongside existing `scrollU`/`scrollV` reset. No animation cleanup needed.

---

## Section 4: Chunk Instance Simplification

### createChunk

- Clone `chunkTemplate`
- Set `Anchored = true`, `CanCollide = false`, `CastShadow = false`
- Apply `Texture` if `textureId` is provided
- No animation setup

### Instance Tree Per Chunk

```
Before:                          After:
  MeshPart                         MeshPart
  +-- Texture                      +-- Texture
  +-- AnimationController
  |   +-- Animator
  +-- Animation
```

### Pool Behavior

`acquireChunk` and `releaseChunk` unchanged. Chunks are now stateless (no animation track), so pooling is cleaner.

---

## Performance Comparison

| Metric | Before (bone animation) | After (sine waves) |
|--------|------------------------|-------------------|
| Instances per chunk | 4-5 (Mesh + Texture + AnimCtrl + Animator + Anim) | 2 (Mesh + Texture) |
| Total instances (25 chunks) | 100-125 | 50 |
| Per-frame Lua cost | Texture offset only | Texture offset + 25 sine evals (4 waves each = 100 `math.sin` calls) |
| Per-frame engine cost | 25 animation tracks evaluated | None |
| Memory per chunk | MeshPart + animation data + 3 instances | MeshPart + 1 instance |
| Blender dependency | Required (rig + animate + export) | Mesh export only |
| Edge seam strategy | Bone mirroring (authoring constraint) | Deterministic math (automatic) |

## File Changes

| File | Change |
|------|--------|
| `src/roblox/OceanSystem.lua` | Remove animation code, add `waveHeight` function, add `updateWaves`, update config types, rename `waveHeight` config to `baseHeight` |
