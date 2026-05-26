# Ocean Chunk LOD System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ring-based LOD to OceanSystem so near chunks use a 5x5 bone grid and far chunks use a 3x3 bone grid, enabling larger ocean grids at lower per-frame cost.

**Architecture:** Two-tier LOD via Chebyshev distance from camera cell. Chunks within `nearRadius` use the existing 5x5 template; outer chunks use a new 3x3 template. Dual chunk pools, tier-aware lifecycle, same `waveHeight()` function for both tiers. Blender handlers are parameterized by `grid_size` to export both templates.

**Tech Stack:** Luau (Roblox), Python (Blender addon), MCP server (FastMCP)

**Spec:** `docs/superpowers/specs/2026-05-26-ocean-chunk-lod-design.md`

---

### Task 1: Add LOD types and module state to OceanSystem.lua

**Files:**
- Modify: `src/roblox/OceanSystem.lua:42-96`

- [ ] **Step 1: Add `farChunkTemplate` and `nearRadius` to OceanConfig**

In `src/roblox/OceanSystem.lua`, replace the `OceanConfig` type (lines 42-53) with:

```lua
export type OceanConfig = {
	chunkTemplate: Instance,
	farChunkTemplate: Instance?,
	nearRadius: number?,
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
```

- [ ] **Step 2: Add LOD fields to ResolvedConfig**

Replace the `ResolvedConfig` type (lines 55-66) with:

```lua
type ResolvedConfig = {
	chunkTemplate: MeshPart,
	farChunkTemplate: MeshPart?,
	nearRadius: number,
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
```

- [ ] **Step 3: Add tier field to ChunkData**

Replace the `ChunkData` type (lines 68-73) with:

```lua
type ChunkData = {
	part: MeshPart,
	bones: { Bone },
	offsets: { Vector3 },
	tex: Texture?,
	tier: string,
}
```

- [ ] **Step 4: Split chunkPool into two tier-specific pools**

Replace line 88 (`local chunkPool: { ChunkData } = {}`) with:

```lua
local nearPool: { ChunkData } = {}
local farPool: { ChunkData } = {}
```

- [ ] **Step 5: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add LOD types and dual chunk pools to OceanSystem"
```

---

### Task 2: Update resolveConfig for LOD fields

**Files:**
- Modify: `src/roblox/OceanSystem.lua:102-126`

- [ ] **Step 1: Resolve farChunkTemplate and nearRadius**

Replace the `resolveConfig` function (lines 102-126) with:

```lua
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
			else raw.farChunkTemplate:FindFirstChildWhichIsA("MeshPart", true) :: MeshPart
		assert(farTemplate, "OceanSystem: farChunkTemplate must be or contain a MeshPart")
	end

	local chunkSize = raw.chunkSize or template.Size.X
	local desiredTile = raw.studsPerTile or 16
	local tilesPerChunk = math.max(1, math.round(chunkSize / desiredTile))

	return {
		chunkTemplate = template,
		farChunkTemplate = farTemplate,
		nearRadius = raw.nearRadius or 1,
		textureId = raw.textureId,
		gridRadius = raw.gridRadius or 2,
		chunkSize = chunkSize,
		studsPerTile = chunkSize / tilesPerChunk,
		scrollSpeed = raw.scrollSpeed or Vector2.new(2, 1),
		baseHeight = raw.baseHeight or -10,
		foamEdges = if raw.foamEdges ~= nil then raw.foamEdges else false,
		waves = raw.waves or DEFAULT_WAVES,
		waveSpeed = raw.waveSpeed or 1.0,
	}
end
```

- [ ] **Step 2: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): resolve farChunkTemplate and nearRadius in config"
```

---

### Task 3: Tier-aware chunk lifecycle (create, acquire, release)

**Files:**
- Modify: `src/roblox/OceanSystem.lua:170-204`

- [ ] **Step 1: Add tier parameter to createChunk**

Replace the `createChunk` function (lines 170-189) with:

```lua
local function createChunk(c: ResolvedConfig, tier: string): ChunkData
	local template = if tier == "far" and c.farChunkTemplate
		then c.farChunkTemplate
		else c.chunkTemplate
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
```

- [ ] **Step 2: Add tier parameter to acquireChunk**

Replace the `acquireChunk` function (lines 191-196) with:

```lua
local function acquireChunk(c: ResolvedConfig, tier: string): ChunkData
	local pool = if tier == "far" then farPool else nearPool
	if #pool > 0 then
		return table.remove(pool) :: ChunkData
	end
	return createChunk(c, tier)
end
```

- [ ] **Step 3: Update releaseChunk to return to correct pool**

Replace the `releaseChunk` function (lines 198-204) with:

```lua
local function releaseChunk(chunk: ChunkData)
	for _, bone in ipairs(chunk.bones) do
		bone.Transform = CFrame.identity
	end
	chunk.part.Parent = nil
	local pool = if chunk.tier == "far" then farPool else nearPool
	table.insert(pool, chunk)
end
```

- [ ] **Step 4: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): tier-aware chunk create/acquire/release lifecycle"
```

---

### Task 4: LOD-aware updateGrid with Chebyshev tier assignment

**Files:**
- Modify: `src/roblox/OceanSystem.lua:206-246`

- [ ] **Step 1: Replace updateGrid with tier-aware version**

Replace the `updateGrid` function (lines 206-246) with:

```lua
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

	local needed: { [string]: { any } } = {}
	for dx = -r, r do
		for dz = -r, r do
			local tier = if c.farChunkTemplate and math.max(math.abs(dx), math.abs(dz)) > nr
				then "far"
				else "near"
			needed[chunkKey(cx + dx, cz + dz)] = { cx + dx, cz + dz, tier }
		end
	end

	for key, chunk in pairs(activeChunks) do
		local cell = needed[key]
		if not cell then
			releaseChunk(chunk)
			activeChunks[key] = nil
		elseif cell[3] ~= chunk.tier then
			releaseChunk(chunk)
			activeChunks[key] = nil
		end
	end

	for key, cell in pairs(needed) do
		if not activeChunks[key] then
			local chunk = acquireChunk(c, cell[3])
			chunk.part.Position = Vector3.new(cell[1] * c.chunkSize, c.baseHeight, cell[2] * c.chunkSize)
			chunk.part.Parent = container
			activeChunks[key] = chunk
		end
	end
end
```

Key changes from the original:
- `needed` entries now include a third element: the tier string (`"near"` or `"far"`)
- Tier is computed via Chebyshev distance: `math.max(math.abs(dx), math.abs(dz)) > nr`
- If `farChunkTemplate` is nil, all chunks get tier `"near"` (backward compat)
- Existing chunks whose tier changed are released and re-acquired from the correct pool

- [ ] **Step 2: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): LOD-aware updateGrid with Chebyshev tier assignment"
```

---

### Task 5: Update stop() to drain both pools

**Files:**
- Modify: `src/roblox/OceanSystem.lua:289-317`

- [ ] **Step 1: Replace stop function to drain nearPool and farPool**

Replace the `stop` function (lines 289-317) with:

```lua
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
```

- [ ] **Step 2: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): drain both LOD pools in stop()"
```

---

### Task 6: Update module header comment

**Files:**
- Modify: `src/roblox/OceanSystem.lua:1-29`

- [ ] **Step 1: Update header to reflect LOD capability**

Replace lines 2-18 with:

```lua
--[[
    OceanSystem — camera-following tiling ocean with bone-driven sine waves.
    Clones rigged MeshParts into an NxN grid that tracks the camera.
    Each bone's Y is set per-frame via deterministic waveHeight()
    evaluated at its world position. Seamless tiling by construction.

    Supports two-tier LOD: near chunks use a high-density bone grid,
    far chunks use a sparser grid. Both evaluate the same wave function.

    Usage:
        local Ocean = require(path.to.OceanSystem)
        Ocean.start({
            chunkTemplate    = game.ReplicatedStorage.OceanChunkNear,
            farChunkTemplate = game.ReplicatedStorage.OceanChunkFar,
            nearRadius       = 1,
            gridRadius       = 3,
            chunkSize        = 512,
            studsPerTile     = 128,
            scrollSpeed      = Vector2.new(2, 1),
            baseHeight       = -10,
        })

        -- Hot-swap waves based on player location:
        Ocean.setWaves({
            { amplitude = 1.0, frequencyX = 0.008, frequencyZ = 0.004, phase = 0, speed = 0.4 },
        })

        -- Or change multiple config fields at once:
        Ocean.setConfig({ waveSpeed = 0.5, baseHeight = -15 })

        Ocean.stop()
]]
```

- [ ] **Step 2: Commit**

```
git add src/roblox/OceanSystem.lua
git commit -m "docs(ocean): update module header for LOD usage"
```

---

### Task 7: Parameterize Blender addon ocean handlers

**Files:**
- Modify: `src/blender_mcp/addon.py:216-219` (handler dispatch table)
- Modify: `src/blender_mcp/addon.py:2327-2479` (handler implementations)

- [ ] **Step 1: Refactor create_ocean_mesh to accept grid_size**

Replace the `create_ocean_mesh_5x5` method (lines 2327-2361) with:

```python
    def create_ocean_mesh(self, chunk_size=512, grid_size=5):
        """Create subdivided plane with flat shading and planar UVs for ocean chunk."""
        label = f"{grid_size}x{grid_size}"
        mesh_name = f"OceanChunk{label}"

        existing = bpy.data.objects.get(mesh_name)
        if existing:
            bpy.data.objects.remove(existing, do_unlink=True)

        subdivisions = (grid_size - 1) * 2

        bpy.ops.mesh.primitive_plane_add(size=chunk_size, location=(0, 0, 0))
        plane = bpy.context.active_object
        plane.name = mesh_name

        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.subdivide(number_cuts=subdivisions - 1)
        bpy.ops.mesh.faces_shade_flat()
        bpy.ops.object.mode_set(mode='OBJECT')

        mesh = plane.data
        uv_layer = mesh.uv_layers.active or mesh.uv_layers.new(name="UVMap")
        half = chunk_size / 2.0
        for poly in mesh.polygons:
            for li in poly.loop_indices:
                v = mesh.vertices[mesh.loops[li].vertex_index]
                uv_layer.data[li].uv = (
                    (v.co.x + half) / chunk_size,
                    (v.co.y + half) / chunk_size,
                )

        return {
            "name": plane.name,
            "vertices": len(mesh.vertices),
            "faces": len(mesh.polygons),
            "triangles": len(mesh.polygons) * 2,
            "chunk_size": chunk_size,
            "subdivisions": subdivisions,
            "grid_size": grid_size,
        }
```

- [ ] **Step 2: Refactor create_ocean_rig to accept grid_size**

Replace the `create_ocean_rig_5x5` method (lines 2363-2404) with:

```python
    def create_ocean_rig(self, chunk_size=512, grid_size=5):
        """Create NxN bone grid armature for ocean chunk wave deformation."""
        label = f"{grid_size}x{grid_size}"
        mesh_name = f"OceanChunk{label}"
        rig_name = f"OceanRig{label}"

        mesh_obj = bpy.data.objects.get(mesh_name)
        if not mesh_obj:
            return {"error": f"{mesh_name} not found. Run create_ocean_mesh first."}

        existing = bpy.data.objects.get(rig_name)
        if existing:
            bpy.data.objects.remove(existing, do_unlink=True)

        bpy.ops.object.select_all(action='DESELECT')
        bpy.ops.object.armature_add(location=(0, 0, 0))
        arm_obj = bpy.context.active_object
        arm_obj.name = rig_name
        arm_obj.data.name = f"{rig_name}Data"

        bpy.ops.object.mode_set(mode='EDIT')
        for b in list(arm_obj.data.edit_bones):
            arm_obj.data.edit_bones.remove(b)

        half = chunk_size / 2.0
        spacing = chunk_size / (grid_size - 1)
        names = []
        for row in range(grid_size):
            for col in range(grid_size):
                name = f"Wave{label}_R{row}_C{col}"
                bone = arm_obj.data.edit_bones.new(name)
                x = -half + col * spacing
                y = -half + row * spacing
                bone.head = (x, y, 0)
                bone.tail = (x, y, 1)
                names.append(name)

        bpy.ops.object.mode_set(mode='OBJECT')

        return {
            "name": arm_obj.name,
            "bone_count": len(names),
            "bones": names,
            "spacing": round(spacing, 4),
            "grid_size": grid_size,
        }
```

- [ ] **Step 3: Refactor bind_ocean_rig to accept grid_size**

Replace the `bind_ocean_rig_5x5` method (lines 2406-2433) with:

```python
    def bind_ocean_rig(self, grid_size=5):
        """Parent ocean mesh to armature with automatic weights."""
        label = f"{grid_size}x{grid_size}"
        mesh_name = f"OceanChunk{label}"
        rig_name = f"OceanRig{label}"

        mesh_obj = bpy.data.objects.get(mesh_name)
        arm_obj = bpy.data.objects.get(rig_name)
        if not mesh_obj:
            return {"error": f"{mesh_name} not found"}
        if not arm_obj:
            return {"error": f"{rig_name} not found"}

        if mesh_obj.parent:
            mesh_obj.parent = None
        for mod in list(mesh_obj.modifiers):
            if mod.type == 'ARMATURE':
                mesh_obj.modifiers.remove(mod)

        bpy.ops.object.select_all(action='DESELECT')
        mesh_obj.select_set(True)
        arm_obj.select_set(True)
        bpy.context.view_layer.objects.active = arm_obj
        bpy.ops.object.parent_set(type='ARMATURE_AUTO')

        groups = [g.name for g in mesh_obj.vertex_groups]
        return {
            "mesh": mesh_obj.name,
            "armature": arm_obj.name,
            "vertex_groups": groups,
            "group_count": len(groups),
        }
```

- [ ] **Step 4: Refactor export_ocean_fbx to accept grid_size**

Replace the `export_ocean_fbx_5x5` method (lines 2435-2479) with:

```python
    def export_ocean_fbx(self, grid_size=5, filepath=""):
        """Export ocean chunk + rig as FBX with Roblox-compatible axis (no animation)."""
        label = f"{grid_size}x{grid_size}"
        mesh_name = f"OceanChunk{label}"
        rig_name = f"OceanRig{label}"

        mesh_obj = bpy.data.objects.get(mesh_name)
        arm_obj = bpy.data.objects.get(rig_name)
        if not mesh_obj:
            return {"error": f"{mesh_name} not found"}
        if not arm_obj:
            return {"error": f"{rig_name} not found"}

        if not filepath:
            base = bpy.path.abspath("//") if bpy.data.filepath else tempfile.gettempdir()
            filepath = os.path.join(base, f"{mesh_name}.fbx")
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
            "grid_size": grid_size,
            "settings": {
                "axis_forward": "-Z",
                "axis_up": "Y",
                "add_leaf_bones": False,
                "bake_anim": False,
            },
        }
```

- [ ] **Step 5: Update handler dispatch table**

In the `_execute_command_internal` method (line 216-219), replace the four ocean entries:

```python
            "create_ocean_mesh_5x5": self.create_ocean_mesh_5x5,
            "create_ocean_rig_5x5": self.create_ocean_rig_5x5,
            "bind_ocean_rig_5x5": self.bind_ocean_rig_5x5,
            "export_ocean_fbx_5x5": self.export_ocean_fbx_5x5,
```

with:

```python
            "create_ocean_mesh": self.create_ocean_mesh,
            "create_ocean_rig": self.create_ocean_rig,
            "bind_ocean_rig": self.bind_ocean_rig,
            "export_ocean_fbx": self.export_ocean_fbx,
```

- [ ] **Step 6: Commit**

```
git add src/blender_mcp/addon.py
git commit -m "refactor(ocean): parameterize Blender handlers by grid_size"
```

---

### Task 8: Update MCP server tools and workflow prompt

**Files:**
- Modify: `src/blender_mcp/server.py:1089-1333`

- [ ] **Step 1: Replace the four ocean MCP tools with parameterized versions**

Replace the `create_ocean_mesh_5x5` tool (lines 1089-1118) with:

```python
@telemetry_tool("create_ocean_mesh")
@mcp.tool()
def create_ocean_mesh(ctx: Context, chunk_size: int = 512, grid_size: int = 5) -> str:
    """
    Create an ocean chunk mesh: a subdivided plane with flat shading and planar UVs.

    Parameters:
    - chunk_size: Size in Blender units, maps 1:1 to Roblox studs (default 512)
    - grid_size: Bone grid dimension — 5 for near (5x5, 25 bones), 3 for far (3x3, 9 bones)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("create_ocean_mesh", {
            "chunk_size": chunk_size,
            "grid_size": grid_size,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        label = f"{grid_size}x{grid_size}"
        return (
            f"Ocean mesh '{r['name']}' created ({label} variant).\n"
            f"Vertices: {r['vertices']}, Faces: {r['faces']}, "
            f"Triangles: {r['triangles']}\n"
            f"Size: {r['chunk_size']}x{r['chunk_size']}, "
            f"Subdivisions: {r['subdivisions']}x{r['subdivisions']}\n"
            f"UVs: planar 0-1, Shading: flat"
        )
    except Exception as e:
        logger.error(f"Error creating ocean mesh {grid_size}x{grid_size}: {str(e)}")
        return f"Error creating ocean mesh: {str(e)}"
```

Replace the `create_ocean_rig_5x5` tool (lines 1121-1147) with:

```python
@telemetry_tool("create_ocean_rig")
@mcp.tool()
def create_ocean_rig(ctx: Context, chunk_size: int = 512, grid_size: int = 5) -> str:
    """
    Create an NxN bone grid armature for the ocean chunk. Bones are edge-aligned
    at chunk boundaries for seamless tiling. Requires matching OceanChunk mesh to exist.

    Parameters:
    - chunk_size: Must match the chunk_size used in create_ocean_mesh (default 512)
    - grid_size: Bone grid dimension — 5 for near (5x5), 3 for far (3x3)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("create_ocean_rig", {
            "chunk_size": chunk_size,
            "grid_size": grid_size,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        label = f"{grid_size}x{grid_size}"
        return (
            f"Ocean rig '{r['name']}' created with {r['bone_count']} bones ({label} variant).\n"
            f"Bone spacing: {r['spacing']} units\n"
            f"Bones: {', '.join(r['bones'])}"
        )
    except Exception as e:
        logger.error(f"Error creating ocean rig {grid_size}x{grid_size}: {str(e)}")
        return f"Error creating ocean rig: {str(e)}"
```

Replace the `bind_ocean_rig_5x5` tool (lines 1150-1170) with:

```python
@telemetry_tool("bind_ocean_rig")
@mcp.tool()
def bind_ocean_rig(ctx: Context, grid_size: int = 5) -> str:
    """
    Bind the ocean chunk mesh to its armature using automatic weights.
    Each bone gets a vertex group influencing its local region of the mesh.
    Requires both the OceanChunk and OceanRig for the given grid_size to exist.

    Parameters:
    - grid_size: Bone grid dimension — must match previous create steps (default 5)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("bind_ocean_rig", {
            "grid_size": grid_size,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        label = f"{grid_size}x{grid_size}"
        return (
            f"Bound '{r['mesh']}' to '{r['armature']}' with automatic weights ({label} variant).\n"
            f"Vertex groups ({r['group_count']}): {', '.join(r['vertex_groups'])}"
        )
    except Exception as e:
        logger.error(f"Error binding ocean rig {grid_size}x{grid_size}: {str(e)}")
        return f"Error binding ocean rig: {str(e)}"
```

Replace the `export_ocean_chunk_5x5` tool (lines 1173-1202) with:

```python
@telemetry_tool("export_ocean_chunk")
@mcp.tool()
def export_ocean_chunk(ctx: Context, grid_size: int = 5, filepath: str = "") -> str:
    """
    Export an ocean chunk mesh and armature as FBX with Roblox-compatible settings.
    Also saves a .blend checkpoint. Axis: -Z forward, Y up.

    Parameters:
    - grid_size: Bone grid dimension — must match previous create steps (default 5)
    - filepath: Output FBX path (default: beside .blend file or temp directory)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("export_ocean_fbx", {
            "grid_size": grid_size,
            "filepath": filepath,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        label = f"{grid_size}x{grid_size}"
        size_kb = round(r["fbx_size_bytes"] / 1024, 1)
        return (
            f"Exported ocean chunk ({label} variant):\n"
            f"  FBX: {r['fbx_path']} ({size_kb} KB)\n"
            f"  Blend: {r['blend_path']}\n"
            f"  Axis: {r['settings']['axis_forward']} fwd, "
            f"{r['settings']['axis_up']} up\n"
            f"  Leaf bones: off, Animation: off"
        )
    except Exception as e:
        logger.error(f"Error exporting ocean chunk {grid_size}x{grid_size}: {str(e)}")
        return f"Error exporting ocean chunk: {str(e)}"
```

- [ ] **Step 2: Replace the workflow prompt with dual-export version**

Replace the `ocean_chunk_5x5_workflow` prompt (lines 1296-1333) with:

```python
@mcp.prompt()
def ocean_chunk_lod_workflow() -> str:
    """Step-by-step workflow for creating near (5x5) and far (3x3) ocean chunks"""
    return """Ocean Chunk LOD Authoring Workflow
===================================

Creates two rigged meshes for OceanSystem LOD: a 5x5 near chunk and a 3x3 far chunk.
Follow these steps in order. Pause at each checkpoint for user review.

PHASE 1 — SETUP
  Call get_scene_info() to verify the MCP connection is live.

PHASE 2 — NEAR CHUNK (5x5)
  2a. Call create_ocean_mesh(chunk_size=512, grid_size=5).
      Expected: 81 vertices, 64 faces, 128 triangles, flat shaded, UVs 0-1.
  2b. Call create_ocean_rig(chunk_size=512, grid_size=5).
      Expected: 25 bones named Wave5x5_R{0-4}_C{0-4}, 128 unit spacing.
  2c. Call bind_ocean_rig(grid_size=5).
      Expected: 25 vertex groups, automatic weights.
  2d. Call export_ocean_chunk(grid_size=5).
      Expected: FBX + .blend checkpoint saved.
  -> Take a viewport screenshot for the user to inspect.

PHASE 3 — FAR CHUNK (3x3)
  3a. Call create_ocean_mesh(chunk_size=512, grid_size=3).
      Expected: 25 vertices, 16 faces, 32 triangles, flat shaded, UVs 0-1.
      Note: subdivisions derived as (grid_size-1)*2 = 4.
  3b. Call create_ocean_rig(chunk_size=512, grid_size=3).
      Expected: 9 bones named Wave3x3_R{0-2}_C{0-2}, 256 unit spacing.
  3c. Call bind_ocean_rig(grid_size=3).
      Expected: 9 vertex groups, automatic weights.
  3d. Call export_ocean_chunk(grid_size=3).
      Expected: FBX + .blend checkpoint saved.
  -> Take a viewport screenshot for the user to inspect.

PHASE 4 — NEXT STEPS
  Tell the user:
  1. Import BOTH FBX files into Roblox Studio
  2. Publish both MeshParts to get rbxassetids
  3. Use OceanSystem.lua with both templates:
     Ocean.start({
         chunkTemplate    = game.ReplicatedStorage.OceanChunkNear,
         farChunkTemplate = game.ReplicatedStorage.OceanChunkFar,
         nearRadius       = 1,
         gridRadius       = 3,
     })
  4. Chunks within nearRadius use the 5x5 mesh; outer chunks use the 3x3 mesh
  5. Both tiers evaluate the same wave function — detail fades with distance
"""
```

- [ ] **Step 3: Commit**

```
git add src/blender_mcp/server.py
git commit -m "feat(ocean): parameterized MCP tools and dual-export workflow prompt"
```

---

### Task 9: Verify Blender export pipeline

**Files:** None (verification only)

- [ ] **Step 1: Start Blender with addon enabled and verify MCP connection**

Run: Call `get_scene_info()` via MCP to confirm the connection is live.

- [ ] **Step 2: Export near chunk (5x5)**

Run through the workflow:
1. `create_ocean_mesh(chunk_size=512, grid_size=5)` — expect 81 vertices, 64 faces (8x8 subdiv)
2. `create_ocean_rig(chunk_size=512, grid_size=5)` — expect 25 bones, 128 spacing
3. `bind_ocean_rig(grid_size=5)` — expect 25 vertex groups
4. `export_ocean_chunk(grid_size=5)` — expect FBX written

Take a viewport screenshot between steps 2 and 3 to verify bone placement.

- [ ] **Step 3: Export far chunk (3x3)**

Run through the workflow:
1. `create_ocean_mesh(chunk_size=512, grid_size=3)` — expect 25 vertices, 16 faces (4x4 subdiv)
2. `create_ocean_rig(chunk_size=512, grid_size=3)` — expect 9 bones, 256 spacing
3. `bind_ocean_rig(grid_size=3)` — expect 9 vertex groups
4. `export_ocean_chunk(grid_size=3)` — expect FBX written

Take a viewport screenshot to verify the sparser bone grid.

- [ ] **Step 4: Verify bone position subset property**

Confirm the 3x3 bone positions (-256, 0, 256) are a strict subset of the 5x5 positions (-256, -128, 0, 128, 256). This is critical for seamless tiling at tier boundaries.

---

### Task 10: Verify LOD in Roblox Studio

**Files:** None (verification only)

- [ ] **Step 1: Import both FBX files into Roblox Studio**

Import OceanChunk5x5.fbx and OceanChunk3x3.fbx into Roblox Studio. Publish both MeshParts and place them in ReplicatedStorage.

- [ ] **Step 2: Test single-tier backward compatibility**

Start OceanSystem with only `chunkTemplate` (no `farChunkTemplate`):

```lua
Ocean.start({
    chunkTemplate = game.ReplicatedStorage.OceanChunk5x5,
    gridRadius = 2,
})
```

Verify: all chunks use the 5x5 mesh, waves animate correctly, identical to pre-LOD behavior.

- [ ] **Step 3: Test two-tier LOD**

Start OceanSystem with both templates:

```lua
Ocean.start({
    chunkTemplate = game.ReplicatedStorage.OceanChunk5x5,
    farChunkTemplate = game.ReplicatedStorage.OceanChunk3x3,
    nearRadius = 1,
    gridRadius = 3,
})
```

Verify:
- Near chunks (within 1 cell of camera) use the 5x5 mesh with detailed waves
- Far chunks use the 3x3 mesh with smoother/simpler waves
- No visible seam at near/far tier boundaries
- Waves animate continuously across all chunks
- Moving the camera causes correct tier transitions (chunks swap mesh at the boundary)

- [ ] **Step 4: Verify tier transition**

Fly the camera across multiple cells and confirm:
- Chunks smoothly swap between near and far tiers
- No visual pop or flicker at the transition ring
- Pool recycling works (no accumulating instances in Explorer)
