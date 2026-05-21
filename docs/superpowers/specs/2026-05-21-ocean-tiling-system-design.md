# Ocean Tiling System Design

## Overview

A reusable, tiling, bone-animated stylized ocean system for Roblox. A single ocean chunk is modeled in Blender with a bone rig that animates vertices on offset sine curves to create rolling wave geometry. Chunks are cloned into a camera-following grid at runtime by a Luau module that also drives a scrolling user-provided texture.

## Goals

- Reusable single-ModuleScript module droppable into any Roblox game
- Low-poly geometric style (flat-shaded facets, visible polygon edges)
- Performant on mid-range hardware (GPU-skinned bones, no per-vertex Lua work)
- Seamless tiling with no visible seams or gaps between chunks

## Approach

**Single Master Chunk** — one chunk authored in Blender with edge bones constrained to mirror opposite edges. The same FBX is cloned N×N in Luau. Seams are solved at authoring time, not runtime.

## Architecture

The system has two halves:

1. **Blender side** — A single MCP session that generates the ocean chunk mesh, rigs it with bones, animates the wave motion, and exports FBX.
2. **Roblox side** — A Luau ModuleScript (`OceanSystem`) that spawns a camera-following grid of chunks and scrolls a user-provided texture across them.

---

## Section 1: Blender Chunk Authoring

### Mesh

- One subdivided plane, 64×64 Blender units (= 64×64 Roblox studs)
- 6×6 quad subdivisions = 72 triangles
- Flat shaded (no smooth normals)
- UVs: planar projection from above, UV space 0–1 maps to the full chunk so adjacent chunks tile naturally with matching `StudsPerTile`

### Bone Rig — 3×3 Grid (9 Bones)

Bones placed at even intervals across the plane, oriented vertically (Z-up). Each bone controls vertices in its region via automatic weight painting.

Naming convention: `Wave_R{row}_C{col}`

```
Wave_R2_C0 ── Wave_R2_C1 ── Wave_R2_C2
    │              │              │
Wave_R1_C0 ── Wave_R1_C1 ── Wave_R1_C2
    │              │              │
Wave_R0_C0 ── Wave_R0_C1 ── Wave_R0_C2
```

### Edge Mirroring Constraint

To guarantee seamless tiling when the chunk is duplicated:

- **Top/bottom:** Row 0 bones have identical keyframes to Row 2 bones (`R0_C0=R2_C0`, `R0_C1=R2_C1`, `R0_C2=R2_C2`)
- **Left/right:** Column 0 bones match Column 2 bones (`R0_C0=R0_C2`, `R1_C0=R1_C2`, `R2_C0=R2_C2`)
- **Corners:** All four corners share the same keyframes

Independent bones (unique animation): `Wave_R1_C1` (center), plus 3 edge-pair masters. The remaining 5 bones copy their master's keyframes.

### Animation

- Single looping action, 60–90 frames at 30fps (2–3 second loop)
- Each independent bone animates on an offset sine curve (Z-axis translation only)
- Different amplitudes and phase offsets per bone for rolling wave feel
- First and last frame match exactly for seamless loop
- Bezier interpolation on all keyframes

### Export

- FBX with baked animation
- Axis correction: `-Z` forward, `Y` up (Roblox convention)
- `add_leaf_bones = False`
- `bake_anim_simplify_factor = 0.0` (preserve all keyframes)

---

## Section 2: Luau Module — OceanSystem

### API

```lua
local Ocean = require(path.to.OceanSystem)

Ocean.start({
    chunkMeshId = "rbxassetid://XXXXX",
    textureId = "rbxassetid://XXXXX",
    gridRadius = 2,                    -- 5×5 grid (radius 2 in each direction)
    chunkSize = 64,                    -- studs per chunk edge
    studsPerTile = 16,                 -- texture tiling density
    scrollSpeed = Vector2.new(2, 1),   -- studs/sec for OffsetStudsU/V
    waveHeight = -10,                  -- Y position of ocean plane
})

Ocean.stop()
```

### Camera-Following Grid

- On each `Heartbeat`, compute which grid cell the camera occupies: `cellX = math.floor(camPos.X / chunkSize)`, same for Z
- Maintain a map of active chunks keyed by `(cellX, cellZ)`
- **Spawn** chunks entering the grid radius, **despawn** chunks leaving it
- Despawned chunks go into a reuse pool (capped at grid size) to avoid GC churn
- Calling `start()` while running calls `stop()` first (safe restart)

### Chunk Positioning

- Each chunk placed at `Vector3.new(cellX * chunkSize, waveHeight, cellZ * chunkSize)`
- All chunks are clones of the same MeshPart with the same baked animation
- Edge bone mirroring guarantees seamless tiling at any grid position

### Texture Scrolling

- Single `Heartbeat` connection updates `OffsetStudsU` and `OffsetStudsV` on every active chunk's texture
- Delta per frame: `scrollSpeed * dt`
- All chunks use identical offset values, so the texture scrolls continuously across the entire grid

### Module Internals

- Config validation at `start()`
- Internal state: `activeChunks` (map), `chunkPool` (array), `heartbeatConnection` (RBXScriptConnection)
- `stop()` disconnects heartbeat, destroys all chunks and pool, resets state

---

## Section 3: Seam-Hiding Strategy

### Primary — Matched Edge Bones

Handled entirely by the edge mirroring constraint in the Blender rig. When adjacent chunks play the same baked animation, their shared-edge vertices are driven by identical bone keyframes and occupy the same world-space position at every frame.

Flat shading reinforces this: each face has a uniform normal, so there is no smooth gradient that could reveal a discontinuity at chunk boundaries.

### Texture Continuity

All chunks share identical `StudsPerTile` and `OffsetStudsU/V` values updated in lockstep. Chunk positions are exact multiples of `chunkSize`, and UVs span 0–1 per chunk, so the texture tiles seamlessly with no additional alignment.

### Fallback (Optional)

If edge artifacts appear on specific hardware, a thin `Beam` particle along chunk boundaries with a foam texture can mask them. Exposed as an optional config flag `foamEdges = false` — off by default.

---

## Section 4: Blender MCP Session Workflow

A new single-session workflow, distinct from the existing 3-session Creature Pipeline. Builds geometry from scratch rather than importing an external model.

### Phases

1. **Setup** — Verify MCP connection, clear scene
2. **Generate mesh** — Create subdivided plane (6×6 quads), scale to 64×64 units, apply flat shading, generate planar UVs
3. **Create bone rig** — Add armature with 3×3 bone grid, position bones evenly across the plane
4. **Bind & weight** — Parent mesh to armature with automatic weights, verify each bone influences its local region
5. **Animate** — Create looping action (60–90 frames). Keyframe independent bones on offset sine curves (Z translation). Copy keyframes from master bones to mirrored edge/corner counterparts.
6. **Verify** — Take viewport screenshot, play animation, confirm loop continuity
7. **Export** — Save `.blend` checkpoint + export FBX

### User Checkpoints

- After mesh generation: inspect geometry and flat shading
- After rigging: inspect bone placement and weight painting
- After animation: preview wave motion, confirm loop
- After export: verify FBX file

### Workflow Location

New workflow doc at `AssetPipeline/workflows/ocean_chunk.md` alongside existing session guides. The Luau module lives in the game project or wherever the developer keeps their Roblox source.

---

## Performance Budget

| Metric | Value |
|---|---|
| Chunks visible | 25 (5×5 grid) |
| Triangles per chunk | 72 |
| Total triangles | 1,800 |
| Bones per chunk | 9 |
| Total bones (GPU-skinned) | 225 |
| Draw calls | 25 |
| Luau per-frame work | Texture offset update only (no bone math) |
| Transparency layers | 0 (opaque mesh) |

## Defaults

All values are configurable via `Ocean.start()`. Defaults:

| Parameter | Default | Notes |
|---|---|---|
| `gridRadius` | 2 | 5×5 = 25 chunks |
| `chunkSize` | 64 | Studs per edge |
| `studsPerTile` | 16 | Texture density |
| `scrollSpeed` | `Vector2.new(2, 1)` | Studs/sec |
| `waveHeight` | -10 | Y position |
| `foamEdges` | false | Fallback seam hiding |
