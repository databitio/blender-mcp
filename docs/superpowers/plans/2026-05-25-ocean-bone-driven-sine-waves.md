# Ocean Bone-Driven Sine Wave Displacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace both ocean modules with a single system that drives 4×4 bone transforms via deterministic sine math for a seamless, deformable ocean surface.

**Architecture:** Camera-following chunk grid where each rigged MeshPart's 16 bones are displaced per-frame by evaluating `waveHeight(worldX, worldZ, time)` at each bone's world position. Chunks stay at `baseHeight`; all visible motion comes from bone transforms. Blender pipeline simplified to mesh + rig + bind + export (no animation bake).

**Tech Stack:** Luau (Roblox), Python (Blender addon), MCP server (FastMCP)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/roblox/OceanSystem.lua` | Rewrite | Bone-driven sine displacement runtime |
| `src/roblox/OceanSystemAnimated.lua` | Delete | Legacy bone animation variant |
| `src/blender_mcp/addon.py` | Modify (lines 2333-2800) | Remove 3×3 handlers, remove animate_4x4, simplify export_4x4 |
| `src/blender_mcp/server.py` | Modify (lines 1089-1581) | Remove 3×3 tools, remove animate_4x4 tool, update prompts |

---

### Task 1: Rewrite OceanSystem.lua — Types and Config

**Files:**
- Modify: `src/roblox/OceanSystem.lua`

- [ ] **Step 1: Replace the entire file with the new module skeleton, types, and config resolution**

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "refactor(ocean): rewrite module skeleton with bone-driven types"
```

---

### Task 2: OceanSystem.lua — Wave Engine and Bone Update

**Files:**
- Modify: `src/roblox/OceanSystem.lua`

- [ ] **Step 1: Add waveHeight, cacheBones, and updateBones functions before the `return` statement**

Insert after `resolveConfig` and before `return OceanSystem`:

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

local function cacheBones(part: MeshPart): ({ Bone }, { Vector3 })
    local bones: { Bone } = {}
    local offsets: { Vector3 } = {}
    for _, desc in ipairs(part:GetDescendants()) do
        if desc:IsA("Bone") then
            table.insert(bones, desc)
            table.insert(offsets, desc.Position)
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
```

- [ ] **Step 2: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add waveHeight engine and bone update loop"
```

---

### Task 3: OceanSystem.lua — Chunk Lifecycle and Grid

**Files:**
- Modify: `src/roblox/OceanSystem.lua`

- [ ] **Step 1: Add chunk creation, pooling, and grid update functions after updateBones**

```lua
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
            chunk.part.Position = Vector3.new(
                cell[1] * c.chunkSize,
                c.baseHeight,
                cell[2] * c.chunkSize
            )
            chunk.part.Parent = container
            activeChunks[key] = chunk
        end
    end
end

local function updateTextures(c: ResolvedConfig, dt: number)
    scrollU += c.scrollSpeed.X * dt
    scrollV += c.scrollSpeed.Y * dt

    for _, chunk in pairs(activeChunks) do
        local tex = chunk.part:FindFirstChildOfClass("Texture")
        if tex then
            tex.OffsetStudsU = scrollU
            tex.OffsetStudsV = scrollV
        end
    end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add chunk lifecycle, pooling, and grid management"
```

---

### Task 4: OceanSystem.lua — Public API (start/stop)

**Files:**
- Modify: `src/roblox/OceanSystem.lua`

- [ ] **Step 1: Add start() and stop() functions before `return OceanSystem`**

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): wire start/stop API with bone-driven heartbeat loop"
```

---

### Task 5: Delete OceanSystemAnimated.lua

**Files:**
- Delete: `src/roblox/OceanSystemAnimated.lua`

- [ ] **Step 1: Remove the legacy animated module**

```bash
git rm src/roblox/OceanSystemAnimated.lua
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor(ocean): remove legacy OceanSystemAnimated module"
```

---

### Task 6: Blender addon.py — Remove 3×3 handlers

**Files:**
- Modify: `src/blender_mcp/addon.py` (lines 2333-2564)

- [ ] **Step 1: Remove 3×3 entries from the command dispatch map**

In the `__init__` method's command dictionary (around line 216), delete these 5 lines:

```python
            "create_ocean_mesh": self.create_ocean_mesh,
            "create_ocean_rig": self.create_ocean_rig,
            "bind_ocean_rig": self.bind_ocean_rig,
            "animate_ocean_waves": self.animate_ocean_waves,
            "export_ocean_fbx": self.export_ocean_fbx,
```

- [ ] **Step 2: Delete the five 3×3 ocean handler methods from BlenderMCPServer**

Remove these methods entirely (lines 2333-2563):
- `create_ocean_mesh` (lines 2333-2367)
- `create_ocean_rig` (lines 2369-2409)
- `bind_ocean_rig` (lines 2411-2438)
- `animate_ocean_waves` (lines 2440-2515)
- `export_ocean_fbx` (lines 2517-2563)

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "refactor(ocean): remove 3x3 Blender handlers and dispatch entries"
```

---

### Task 7: Blender addon.py — Remove animate_ocean_waves_4x4 handler

**Files:**
- Modify: `src/blender_mcp/addon.py`

- [ ] **Step 1: Remove animate_ocean_waves_4x4 from the command dispatch map**

In the `__init__` method's command dictionary, delete this line:

```python
            "animate_ocean_waves_4x4": self.animate_ocean_waves_4x4,
```

- [ ] **Step 2: Delete the `animate_ocean_waves_4x4` method**

Remove the method (find by name `def animate_ocean_waves_4x4`). This method spans ~80 lines ending before `def export_ocean_fbx_4x4`.

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "refactor(ocean): remove animate_ocean_waves_4x4 handler and dispatch"
```

---

### Task 8: Blender addon.py — Simplify export_ocean_fbx_4x4

**Files:**
- Modify: `src/blender_mcp/addon.py`

- [ ] **Step 1: Update export_ocean_fbx_4x4 to skip animation baking**

Find the `export_ocean_fbx_4x4` method and replace it with:

```python
    def export_ocean_fbx_4x4(self, filepath=""):
        """Export 4x4 ocean chunk + rig as FBX with Roblox-compatible axis (no animation)."""
        mesh_obj = bpy.data.objects.get("OceanChunk4x4")
        arm_obj = bpy.data.objects.get("OceanRig4x4")
        if not mesh_obj:
            return {"error": "OceanChunk4x4 not found"}
        if not arm_obj:
            return {"error": "OceanRig4x4 not found"}

        if not filepath:
            base = bpy.path.abspath("//") if bpy.data.filepath else tempfile.gettempdir()
            filepath = os.path.join(base, "OceanChunk4x4.fbx")
        os.makedirs(os.path.dirname(filepath) or ".", exist_ok=True)

        blend_path = filepath.replace(".fbx", ".blend")
        bpy.ops.wm.save_as_mainfile(filepath=blend_path, copy=True)

        bpy.ops.object.select_all(action='DESELECT')
        mesh_obj.select_set(True)
        arm_obj.select_set(True)
        bpy.context.view_layer.objects.active = arm_obj

        bpy.ops.export_scene.fbx(
            filepath=filepath,
            use_selection=True,
            object_types={'MESH', 'ARMATURE'},
            use_mesh_modifiers=True,
            add_leaf_bones=False,
            bake_anim=False,
            axis_forward='-Z',
            axis_up='Y',
            path_mode='AUTO',
        )

        return {
            "fbx_path": filepath,
            "blend_path": blend_path,
            "fbx_size_bytes": os.path.getsize(filepath),
            "settings": {
                "axis_forward": "-Z",
                "axis_up": "Y",
                "add_leaf_bones": False,
                "bake_anim": False,
            },
        }
```

Key change: `bake_anim=False` and removed `bake_anim_use_all_bones` and `bake_anim_simplify_factor` params.

- [ ] **Step 2: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "refactor(ocean): simplify 4x4 FBX export to skip animation bake"
```

---

### Task 9: MCP server.py — Remove 3×3 tools

**Files:**
- Modify: `src/blender_mcp/server.py` (lines 1089-1244)

- [ ] **Step 1: Delete the five 3×3 ocean MCP tool functions**

Remove these functions entirely (lines 1089-1244):
- `create_ocean_mesh` (lines 1089-1119)
- `create_ocean_rig` (lines 1122-1148)
- `bind_ocean_rig` (lines 1151-1171)
- `animate_ocean_waves` (lines 1174-1212)
- `export_ocean_chunk` (lines 1215-1244)

- [ ] **Step 2: Commit**

```bash
git add src/blender_mcp/server.py
git commit -m "refactor(ocean): remove 3x3 MCP tools"
```

---

### Task 10: MCP server.py — Remove animate_ocean_waves_4x4 tool

**Files:**
- Modify: `src/blender_mcp/server.py`

- [ ] **Step 1: Delete the `animate_ocean_waves_4x4` tool function**

Find and remove the function decorated with `@telemetry_tool("animate_ocean_waves_4x4")` (originally lines 1332-1370). This includes the `@telemetry_tool` decorator, `@mcp.tool()` decorator, function definition, docstring, and body.

- [ ] **Step 2: Commit**

```bash
git add src/blender_mcp/server.py
git commit -m "refactor(ocean): remove animate_ocean_waves_4x4 MCP tool"
```

---

### Task 11: MCP server.py — Update export tool output and workflow prompts

**Files:**
- Modify: `src/blender_mcp/server.py`

- [ ] **Step 1: Update the `export_ocean_chunk_4x4` tool's return string**

Find the `export_ocean_chunk_4x4` function and update the return string to reflect `bake_anim=off` instead of `Simplify: 0.0`:

```python
        return (
            f"Exported ocean chunk (4x4 variant):\n"
            f"  FBX: {r['fbx_path']} ({size_kb} KB)\n"
            f"  Blend: {r['blend_path']}\n"
            f"  Axis: {r['settings']['axis_forward']} fwd, "
            f"{r['settings']['axis_up']} up\n"
            f"  Leaf bones: off, Animation: off"
        )
```

- [ ] **Step 2: Delete the `ocean_chunk_workflow` prompt (3×3)**

Remove the entire `ocean_chunk_workflow` function (originally lines 1495-1536), including its `@mcp.prompt()` decorator.

- [ ] **Step 3: Replace the `ocean_chunk_4x4_workflow` prompt with the simplified 4-step version**

Find `def ocean_chunk_4x4_workflow` and replace the entire function with:

```python
@mcp.prompt()
def ocean_chunk_4x4_workflow() -> str:
    """Step-by-step workflow for creating a 4x4 tiling ocean chunk in Blender"""
    return """Ocean Chunk 4x4 Authoring Workflow
===================================

Rigged mesh for use with OceanSystem.lua (bone-driven sine wave displacement).
Follow these steps in order. Pause at each checkpoint for user review.

PHASE 1 — SETUP
  Call get_scene_info() to verify the MCP connection is live.

PHASE 2 — MESH (checkpoint after)
  Call create_ocean_mesh_4x4(chunk_size=64, subdivisions=8).
  Expected: 81 vertices, 64 faces, 128 triangles, flat shaded, UVs 0-1.
  -> Take a viewport screenshot for the user to inspect geometry.

PHASE 3 — RIG (checkpoint after)
  Call create_ocean_rig_4x4(chunk_size=64).
  Expected: 16 bones named Wave4x4_R{0-3}_C{0-3}, spaced 16 units apart.
  -> Take a viewport screenshot for the user to inspect bone placement.

PHASE 4 — BIND
  Call bind_ocean_rig_4x4().
  Expected: 16 vertex groups, one per bone, automatic weights applied.

PHASE 5 — EXPORT (checkpoint after)
  Call export_ocean_chunk_4x4().
  Expected: FBX with rigged mesh (no animation) + .blend checkpoint saved.
  Settings: -Z forward, Y up, no leaf bones, bake_anim=off.

PHASE 6 — NEXT STEPS
  Tell the user:
  1. Import the FBX into Roblox Studio
  2. Publish the MeshPart to get an rbxassetid
  3. Use OceanSystem.lua with the asset ID:
     Ocean.start({ chunkTemplate = game.ReplicatedStorage.OceanChunk })
  4. Bone displacement is driven by Lua at runtime (no animation asset needed)
"""
```

- [ ] **Step 4: Commit**

```bash
git add src/blender_mcp/server.py
git commit -m "refactor(ocean): update export output and workflow prompt"
```

---

### Task 12: Final Verification

**Files:**
- All modified files

- [ ] **Step 1: Verify OceanSystem.lua is syntactically valid**

Run: `luau --check src/roblox/OceanSystem.lua` (if luau CLI available), otherwise visually verify:
- All functions reference valid identifiers
- Type annotations are consistent
- No references to removed code (`playAnimation`, `animationId`, `updateWaves`)

- [ ] **Step 2: Verify addon.py has no dangling references**

Search for any remaining `3x3` or `animate_ocean` references that should have been removed:

```bash
grep -n "create_ocean_mesh\b\|create_ocean_rig\b\|bind_ocean_rig\b\|animate_ocean_waves\b\|export_ocean_fbx\b" src/blender_mcp/addon.py
```

Expected: only `_4x4` variants remain (except `animate_ocean_waves_4x4` which should be gone).

- [ ] **Step 3: Verify server.py has no dangling references**

```bash
grep -n "ocean_chunk_workflow\b\|animate_ocean" src/blender_mcp/server.py
```

Expected: only `ocean_chunk_4x4_workflow` remains. No animate references.

- [ ] **Step 4: Verify the command dispatch in addon.py routes correctly**

Search for the command dispatch dictionary or if/elif chain that maps command strings to handler methods. Ensure removed handlers (`create_ocean_mesh`, `create_ocean_rig`, `bind_ocean_rig`, `animate_ocean_waves`, `export_ocean_fbx`, `animate_ocean_waves_4x4`) are also removed from the dispatch map.

```bash
grep -n "ocean" src/blender_mcp/addon.py
```

Remove any dispatch entries for deleted handlers.

- [ ] **Step 5: Final commit if any cleanup was needed**

```bash
git add -A
git commit -m "chore(ocean): final cleanup of dangling references"
```
