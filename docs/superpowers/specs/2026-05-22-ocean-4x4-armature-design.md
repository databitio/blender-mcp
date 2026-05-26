# Ocean Chunk 4x4 Armature Variant

**Date:** 2026-05-22
**Status:** Approved
**Relates to:** [Ocean Tiling System Design](2026-05-21-ocean-tiling-system-design.md)

## Overview

A 4x4 bone-grid variant of the existing 3x3 ocean chunk system. Separate handlers and MCP tools coexist alongside the 3x3 system without modifying it. The Lua runtime (`OceanSystem.lua`) requires no changes — it is already chunk-agnostic.

## Requirements

- 4x4 armature grid (16 bones) for richer wave detail
- Seamless tiling between adjacent chunks via edge-bone mirroring
- Separate handlers/tools with `_4x4` suffix so both variants coexist
- 8x8 quad mesh (128 tris) to match denser bone grid
- Richer rolling wave pattern using 9 independent master bones

## Bone Grid Layout

16 bones named `Wave4x4_R{row}_C{col}` (row 0-3, col 0-3).

```
Wave4x4_R3_C0 ── Wave4x4_R3_C1 ── Wave4x4_R3_C2 ── Wave4x4_R3_C3
      |                |                |                |
Wave4x4_R2_C0 ── Wave4x4_R2_C1 ── Wave4x4_R2_C2 ── Wave4x4_R2_C3
      |                |                |                |
Wave4x4_R1_C0 ── Wave4x4_R1_C1 ── Wave4x4_R1_C2 ── Wave4x4_R1_C3
      |                |                |                |
Wave4x4_R0_C0 ── Wave4x4_R0_C1 ── Wave4x4_R0_C2 ── Wave4x4_R0_C3
```

**Spacing:** `chunk_size / 4.0` = 16 studs (for default 64-unit chunk).
**Origin offset:** `-chunk_size / 2.0 + spacing / 2.0` = -24 studs.
**Bone orientation:** Head at `(x, y, 0)`, tail at `(x, y, 1)` — vertical Z-axis.

## Edge-Mirroring Strategy

9 master bones have independent animation. 7 mirrored bones copy keyframes from their master to guarantee seamless tiling.

### Master Bones (9)

| Bone | Role |
|------|------|
| `R1_C1` | Interior |
| `R1_C2` | Interior |
| `R2_C1` | Interior |
| `R2_C2` | Interior |
| `R0_C1` | Top edge |
| `R0_C2` | Top edge |
| `R1_C0` | Left edge |
| `R2_C0` | Left edge |
| `R0_C0` | Corner |

### Mirror Mapping (7)

| Mirror Bone | Copies From | Reason |
|-------------|-------------|--------|
| `R3_C1` | `R0_C1` | Bottom edge = top edge |
| `R3_C2` | `R0_C2` | Bottom edge = top edge |
| `R1_C3` | `R1_C0` | Right edge = left edge |
| `R2_C3` | `R2_C0` | Right edge = left edge |
| `R0_C3` | `R0_C0` | Top-right corner = top-left corner |
| `R3_C0` | `R0_C0` | Bottom-left corner = top-left corner |
| `R3_C3` | `R0_C0` | Bottom-right corner = top-left corner |

**Tiling guarantee:** Adjacent chunks share identical edge-bone keyframes, so shared-edge vertices occupy the same world position at every frame. All 4 corners use the same keyframes.

## Wave Animation

### Phase and Amplitude Distribution

Richer rolling wave pattern with wave energy concentrated in the interior, tapering toward edges/corners.

| Bone | Phase | Amplitude Factor | Role |
|------|-------|-------------------|------|
| `R1_C1` | 0 | 1.0x | Primary interior |
| `R2_C1` | pi/4 | 0.95x | Interior, offset forward |
| `R1_C2` | pi/2 | 0.90x | Interior, offset right |
| `R2_C2` | 3*pi/4 | 0.85x | Interior, diagonal offset |
| `R0_C1` | pi/3 | 0.70x | Top edge |
| `R0_C2` | 2*pi/3 | 0.65x | Top edge |
| `R1_C0` | 5*pi/6 | 0.60x | Left edge |
| `R2_C0` | 7*pi/6 | 0.55x | Left edge |
| `R0_C0` | pi | 0.50x | Corner (all 4 corners) |

### Keyframe Structure

- Default: 72 frames at 30fps = 2.4 second loop
- frame_count + 1 keyframes for smooth Bezier handles at loop boundary
- Animation on bone local Y-axis (`location`, index=1)
- All keyframes set to Bezier interpolation
- Action named `OceanWaveAction4x4`

## Mesh

- 8x8 quad grid = 81 vertices, 64 faces, 128 triangles
- Flat shading on all faces
- Planar UV mapping (0-1 normalized)
- Object named `OceanChunk4x4`

## Blender Handlers (addon.py)

Five new handler methods on the `BlenderMCPAddon` class:

1. **`create_ocean_mesh_4x4(chunk_size=64, subdivisions=8)`** — Create 8x8 subdivided plane named `OceanChunk4x4`
2. **`create_ocean_rig_4x4(chunk_size=64)`** — Create 4x4 bone grid armature named `OceanRig4x4`
3. **`bind_ocean_rig_4x4()`** — Parent `OceanChunk4x4` to `OceanRig4x4` with automatic weights
4. **`animate_ocean_waves_4x4(frame_count=72, amplitude=1.5, fps=30)`** — Create looping wave animation with 9-master edge-mirrored keyframes
5. **`export_ocean_fbx_4x4(filepath="")`** — Export FBX with Roblox-compatible axis settings

All handlers follow the same patterns as the 3x3 equivalents. Object names use `4x4` suffix to avoid collisions.

## MCP Tools (server.py)

Five new MCP tools mirroring the handlers:

1. `create_ocean_mesh_4x4` — chunk_size, subdivisions params
2. `create_ocean_rig_4x4` — chunk_size param
3. `bind_ocean_rig_4x4` — no params
4. `animate_ocean_waves_4x4` — frame_count, amplitude, fps params
5. `export_ocean_chunk_4x4` — filepath param

Plus a new workflow prompt `ocean_chunk_4x4_workflow` guiding Claude through the 7-phase creation process.

## Lua Runtime

**No changes required.** `OceanSystem.lua` clones whatever `chunkTemplate` MeshPart is provided. The 4x4 chunks have more bones inside, which Roblox's animation system handles transparently. Same grid tiling, same texture scrolling, same object pooling.

## Performance Budget

| Metric | 3x3 System | 4x4 System |
|--------|-----------|-----------|
| Tris per chunk | 72 | 128 |
| Bones per chunk | 9 | 16 |
| Total tris (25 chunks) | 1,800 | 3,200 |
| Total bones (25 chunks) | 225 | 400 |
| Draw calls | 25 | 25 |

Both variants are well within Roblox's performance budget.

## File Changes

| File | Change |
|------|--------|
| `src/blender_mcp/addon.py` | Add 5 new `_4x4` handler methods |
| `src/blender_mcp/server.py` | Add 5 new MCP tools + workflow prompt |
| `src/roblox/OceanSystem.lua` | No changes |
