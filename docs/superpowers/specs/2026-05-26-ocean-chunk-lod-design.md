# Ocean Chunk LOD System Design

**Date:** 2026-05-26
**Status:** Approved
**Relates to:** [Ocean Bone-Driven Sine Waves](2026-05-25-ocean-bone-driven-sine-waves-design.md)

## Overview

Add a ring-based LOD system to OceanSystem that uses lower-bone-density mesh templates for chunks further from the camera. Near chunks keep the current 5x5 bone grid (25 bones, 128-stud spacing); far chunks use a 3x3 bone grid (9 bones, 256-stud spacing). Both are 512-stud meshes evaluated with the same 4-wave `waveHeight()` function. The result is a much larger visible ocean at lower per-frame cost.

Inspired by MIP maps: reduce geometric resolution with distance, since the player can't perceive fine wave detail on distant chunks.

## Goals

- Support gridRadius 3-4 (7x7 to 9x9 chunks) without exceeding the frame budget of the current radius-2 system
- Seamless tiling at near/far tier boundaries with no visible seams
- Full backward compatibility when `farChunkTemplate` is not provided
- Minimal code change: single Lua file, parameterized Blender handlers

## Non-Goals

- More than 2 LOD tiers (design accommodates future extension but only implements 2)
- Per-tier wave complexity reduction (all tiers use the same wave function)
- Continuous/distance-based LOD (ring-based Chebyshev is sufficient at 512-stud chunk scale)
- Near-chunk bone density increase (5x5 stays as the high tier)

---

## Section 1: LOD Tier Model

Two tiers, each backed by a distinct rigged MeshPart template:

| Tier | Bone Grid | Bones | Bone Spacing | Mesh Subdivisions | Use |
|------|-----------|-------|-------------|-------------------|-----|
| Near | 5x5 | 25 | 128 studs | 8x8 faces | Chunks within `nearRadius` of camera cell |
| Far | 3x3 | 9 | 256 studs | 4x4 faces | All remaining chunks |

Both meshes are 512-stud squares. The 3x3 far mesh has bones at -256, 0, 256 on each axis -- a strict subset of the 5x5 positions -- so wave displacement at shared edges uses identical world positions and produces identical `waveHeight()` values.

### Config Changes

```lua
export type OceanConfig = {
    chunkTemplate: Instance,      -- near tier (5x5), existing field
    farChunkTemplate: Instance?,  -- far tier (3x3), new field
    nearRadius: number?,          -- default 1 (Chebyshev distance threshold)
    gridRadius: number?,          -- default 2 (unchanged from current)
    -- all other fields unchanged
}
```

If `farChunkTemplate` is nil, all chunks use `chunkTemplate` -- full backward compatibility.

---

## Section 2: Grid Management & Chunk Lifecycle

### Tier Assignment

Each cell in the grid gets tagged with its tier based on Chebyshev distance from the camera cell:

```
tier = (max(|dx|, |dz|) <= nearRadius) ? "near" : "far"
```

For gridRadius=3, nearRadius=1 on a 7x7 grid:

```
  F F F F F F F
  F F F F F F F
  F F N N N F F
  F F N C N F F
  F F N N N F F
  F F F F F F F
  F F F F F F F

  Near: 9 chunks x 25 bones = 225 bone updates
  Far:  40 chunks x 9 bones = 360 bone updates
  Total: 585 bone updates/frame
```

### Two Pools, Two Templates

```lua
local nearPool: { ChunkData } = {}
local farPool:  { ChunkData } = {}
```

`acquireChunk` takes a tier parameter and pulls from the matching pool (or clones the matching template). `releaseChunk` returns chunks to the pool matching `chunk.tier`.

### Tier Transitions on Camera Movement

When the camera moves to a new cell, some chunks cross the nearRadius boundary:

1. Build the new `needed` map with tier tags
2. For each existing chunk: if the key exists in `needed` but the tier changed, release the old chunk to its pool and acquire a new one from the correct pool
3. Chunks that kept the same tier: no change
4. Chunks no longer needed: release to pool

A chunk that transitions near->far gets its 5x5 mesh returned to `nearPool` and a 3x3 mesh placed from `farPool`. The new mesh gets correct bone transforms on the same frame via `updateBones`.

### ChunkData Changes

```lua
type ChunkData = {
    part: MeshPart,
    bones: { Bone },
    offsets: { Vector3 },
    tex: Texture?,
    tier: "near" | "far",  -- new: tracks which pool to return to
}
```

---

## Section 3: Performance Budget

### Comparison at gridRadius=3, nearRadius=1

| Scenario | Chunks | Bones/frame | sin() calls | CFrame sets | Est. cost |
|----------|--------|-------------|-------------|-------------|-----------|
| Current (all 5x5, radius=2) | 25 | 625 | 2,500 | 625 | ~0.18ms |
| All 5x5 at radius=3 (no LOD) | 49 | 1,225 | 4,900 | 1,225 | ~0.34ms |
| **LOD (5x5 near + 3x3 far)** | **49** | **585** | **2,340** | **585** | **~0.16ms** |

LOD at radius=3 covers nearly 4x the area of the current system while using fewer bone updates per frame.

### Scaling to radius=4

| Scenario | Chunks | Bones/frame | Est. cost |
|----------|--------|-------------|-----------|
| All 5x5 (no LOD) | 81 | 2,025 | ~0.57ms |
| LOD (nearRadius=1) | 81 | 873 | ~0.24ms |
| LOD (nearRadius=2) | 81 | 1,201 | ~0.34ms |

### Tier Transition Cost

Camera cell changes happen every 512 studs of movement. At most ~16 chunks swap tier per transition (the ring crossing the nearRadius boundary). Each swap is one pool return + one pool acquire + one `cacheBones` call. Same order as existing chunk spawn/despawn.

---

## Section 4: Seamless Tiling at Tier Boundaries

### Bone Position Alignment

Adjacent chunks along the X axis, chunk A (near, 5x5) at X=0 and chunk B (far, 3x3) at X=512:

```
Chunk A (near 5x5)          Chunk B (far 3x3)
bones at X offsets:          bones at X offsets:
-256, -128, 0, 128, 256     -256, 0, 256

World X positions:           World X positions:
-256, -128, 0, 128, 256     256, 512, 768
```

The shared boundary is at world X=256. Both chunks have a bone there. Both evaluate `waveHeight(256, z, t)` and get identical Y displacement. No discontinuity at the edge.

### Interior Interpolation Difference

Between the shared edge bone and the next bone inward:

- **Chunk A (near)**: interpolates between bone at X=128 and X=256 (128-stud span)
- **Chunk B (far)**: interpolates between bone at X=256 and X=512 (256-stud span)

The near side captures more wave curvature; the far side smooths it out. This is the desired LOD behavior. The transition is at the shared edge bone (exact match), so there's no pop or tear. The visual difference is gradual loss of fine wave detail, masked by distance from the camera.

### Continuity

The surface is C0-continuous at tier boundaries (positions match). It is not C1-continuous (slopes may differ slightly at the edge). At 512+ studs from the camera, this slope difference is imperceptible.

### Corner Cases

Where four chunks meet at a corner, all four share a bone at that corner position. All four evaluate the same `waveHeight()`. No special handling needed.

---

## Section 5: Blender Pipeline Changes

### Parameterized Handlers

Refactor existing 5x5-specific handlers into grid-size-parameterized versions:

| Current Handler | New Handler | Key Parameter |
|----------------|-------------|---------------|
| `create_ocean_mesh_4x4` | `create_ocean_mesh(grid_size)` | subdivisions = (grid_size - 1) * 2 |
| `create_ocean_rig_4x4` | `create_ocean_rig(grid_size)` | bone positions = linspace(-chunk/2, chunk/2, grid_size) |
| `bind_ocean_rig_4x4` | `bind_ocean_rig()` | Already grid-agnostic |
| `export_ocean_fbx_4x4` | `export_ocean_fbx()` | Already grid-agnostic |

### Export Workflow

```
# Near template (5x5)
create_ocean_mesh(chunk_size=512, grid_size=5)
create_ocean_rig(chunk_size=512, grid_size=5)
bind_ocean_rig()
export_ocean_fbx(filepath="OceanChunkNear.fbx")

# Far template (3x3)
create_ocean_mesh(chunk_size=512, grid_size=3)
create_ocean_rig(chunk_size=512, grid_size=3)
bind_ocean_rig()
export_ocean_fbx(filepath="OceanChunkFar.fbx")
```

### Edge Alignment Guarantee

The 3x3 bone positions (-256, 0, 256) are a strict subset of the 5x5 positions (-256, -128, 0, 128, 256). Parameterizing via `linspace(-chunk/2, chunk/2, grid_size)` guarantees this algebraically for any odd grid_size on the same chunk_size.

---

## Section 6: File Changes Summary

### Lua (Runtime)

**`src/roblox/OceanSystem.lua`** -- ~40-50 lines of changes:

| Area | Change |
|------|--------|
| `OceanConfig` type | Add `farChunkTemplate: Instance?`, `nearRadius: number?` |
| `ResolvedConfig` type | Add `farChunkTemplate: MeshPart?`, `nearRadius: number` |
| `ChunkData` type | Add `tier: "near" \| "far"` field |
| Module state | Split `chunkPool` into `nearPool` + `farPool` |
| `resolveConfig()` | Resolve `farChunkTemplate` and `nearRadius` (default 1) |
| `createChunk()` | Accept tier parameter, clone the right template |
| `acquireChunk()` | Accept tier, pull from the right pool |
| `releaseChunk()` | Return to pool based on `chunk.tier` |
| `updateGrid()` | Compute tier per cell via Chebyshev distance, handle tier transitions |
| `stop()` | Drain both pools |

### Unchanged

- `waveHeight()` -- same function, same waves, all tiers
- `updateBones()` -- iterates `chunk.bones` as a flat list; shorter list for far chunks
- `updateTextures()` -- per-chunk texture offset is independent of bone count
- Texture displacement system
- All existing config fields
- Public API signatures (`start`, `stop`, `setWaves`, `setConfig`)

### Blender (Asset Pipeline)

**`src/blender_mcp/addon.py`**:
- Refactor 4 handlers from hardcoded 5x5 to parameterized `grid_size`
- Derive subdivisions and bone positions from `grid_size`

**`src/blender_mcp/server.py`**:
- Update MCP tool definitions with `grid_size` parameter
- Update workflow prompt for dual-export (near + far)

### Backward Compatibility

- `farChunkTemplate` omitted: all chunks use `chunkTemplate`, single-tier behavior identical to today
- Blender handlers with `grid_size=5`: identical output to current 5x5 handlers
