# Ocean 4x4 Armature Variant — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 4x4 bone-grid ocean chunk variant alongside the existing 3x3 system, with seamless inter-chunk tiling via edge-bone mirroring.

**Architecture:** Five new `_4x4` handler methods in `addon.py` and five new MCP tools + workflow prompt in `server.py`. Objects are named with `4x4` suffixes (`OceanChunk4x4`, `OceanRig4x4`) so both variants coexist in the same Blender scene. No Lua changes — `OceanSystem.lua` is already chunk-agnostic.

**Tech Stack:** Blender Python API (bpy), MCP SDK (FastMCP decorators), Lua (unchanged)

**Spec:** `docs/superpowers/specs/2026-05-22-ocean-4x4-armature-design.md`

---

### Task 1: Add `create_ocean_mesh_4x4` handler to addon.py

**Files:**
- Modify: `src/blender_mcp/addon.py:216-220` (command dispatch table)
- Modify: `src/blender_mcp/addon.py` (new method after line ~2362, after existing `create_ocean_mesh`)

- [ ] **Step 1: Add the handler method**

Add this method to the `BlenderMCPAddon` class, immediately after the existing `create_ocean_mesh` method (after line 2362):

```python
    def create_ocean_mesh_4x4(self, chunk_size=64, subdivisions=8):
        """Create 8x8 subdivided plane with flat shading and planar UVs for 4x4 ocean chunk."""
        existing = bpy.data.objects.get("OceanChunk4x4")
        if existing:
            bpy.data.objects.remove(existing, do_unlink=True)

        bpy.ops.mesh.primitive_plane_add(size=chunk_size, location=(0, 0, 0))
        plane = bpy.context.active_object
        plane.name = "OceanChunk4x4"

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
        }
```

- [ ] **Step 2: Register the command in the dispatch table**

In the command dispatch dictionary (around line 216-220), add this entry after `"export_ocean_fbx"`:

```python
            "create_ocean_mesh_4x4": self.create_ocean_mesh_4x4,
```

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "feat(ocean-4x4): add create_ocean_mesh_4x4 handler"
```

---

### Task 2: Add `create_ocean_rig_4x4` handler to addon.py

**Files:**
- Modify: `src/blender_mcp/addon.py:216-220` (command dispatch table)
- Modify: `src/blender_mcp/addon.py` (new method after `create_ocean_mesh_4x4`)

- [ ] **Step 1: Add the handler method**

Add this method immediately after `create_ocean_mesh_4x4`:

```python
    def create_ocean_rig_4x4(self, chunk_size=64):
        """Create 4x4 bone grid armature for ocean chunk wave deformation."""
        mesh_obj = bpy.data.objects.get("OceanChunk4x4")
        if not mesh_obj:
            return {"error": "OceanChunk4x4 not found. Run create_ocean_mesh_4x4 first."}

        existing = bpy.data.objects.get("OceanRig4x4")
        if existing:
            bpy.data.objects.remove(existing, do_unlink=True)

        bpy.ops.object.select_all(action='DESELECT')
        bpy.ops.object.armature_add(location=(0, 0, 0))
        arm_obj = bpy.context.active_object
        arm_obj.name = "OceanRig4x4"
        arm_obj.data.name = "OceanRig4x4Data"

        bpy.ops.object.mode_set(mode='EDIT')
        for b in list(arm_obj.data.edit_bones):
            arm_obj.data.edit_bones.remove(b)

        spacing = chunk_size / 4.0
        origin = -chunk_size / 2.0 + spacing / 2.0
        names = []
        for row in range(4):
            for col in range(4):
                name = f"Wave4x4_R{row}_C{col}"
                bone = arm_obj.data.edit_bones.new(name)
                x = origin + col * spacing
                y = origin + row * spacing
                bone.head = (x, y, 0)
                bone.tail = (x, y, 1)
                names.append(name)

        bpy.ops.object.mode_set(mode='OBJECT')

        return {
            "name": arm_obj.name,
            "bone_count": len(names),
            "bones": names,
            "spacing": round(spacing, 4),
        }
```

- [ ] **Step 2: Register the command in the dispatch table**

Add after `"create_ocean_mesh_4x4"`:

```python
            "create_ocean_rig_4x4": self.create_ocean_rig_4x4,
```

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "feat(ocean-4x4): add create_ocean_rig_4x4 handler"
```

---

### Task 3: Add `bind_ocean_rig_4x4` handler to addon.py

**Files:**
- Modify: `src/blender_mcp/addon.py:216-220` (command dispatch table)
- Modify: `src/blender_mcp/addon.py` (new method after `create_ocean_rig_4x4`)

- [ ] **Step 1: Add the handler method**

Add this method immediately after `create_ocean_rig_4x4`:

```python
    def bind_ocean_rig_4x4(self):
        """Parent 4x4 ocean mesh to armature with automatic weights."""
        mesh_obj = bpy.data.objects.get("OceanChunk4x4")
        arm_obj = bpy.data.objects.get("OceanRig4x4")
        if not mesh_obj:
            return {"error": "OceanChunk4x4 not found"}
        if not arm_obj:
            return {"error": "OceanRig4x4 not found"}

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

- [ ] **Step 2: Register the command in the dispatch table**

Add after `"create_ocean_rig_4x4"`:

```python
            "bind_ocean_rig_4x4": self.bind_ocean_rig_4x4,
```

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "feat(ocean-4x4): add bind_ocean_rig_4x4 handler"
```

---

### Task 4: Add `animate_ocean_waves_4x4` handler to addon.py

**Files:**
- Modify: `src/blender_mcp/addon.py:216-220` (command dispatch table)
- Modify: `src/blender_mcp/addon.py` (new method after `bind_ocean_rig_4x4`)

This is the most critical handler — it defines the 9 master bones with distinct phases and the 7 edge-mirrored bones that guarantee seamless tiling.

- [ ] **Step 1: Add the handler method**

Add this method immediately after `bind_ocean_rig_4x4`:

```python
    def animate_ocean_waves_4x4(self, frame_count=72, amplitude=1.5, fps=30):
        """Create looping sine-wave animation with 9-master edge-mirrored keyframes for 4x4 rig."""
        import math

        arm_obj = bpy.data.objects.get("OceanRig4x4")
        if not arm_obj:
            return {"error": "OceanRig4x4 not found"}

        scene = bpy.context.scene
        scene.render.fps = fps
        scene.frame_start = 0
        scene.frame_end = frame_count - 1

        action_name = "OceanWaveAction4x4"
        if action_name in bpy.data.actions:
            bpy.data.actions.remove(bpy.data.actions[action_name])
        action = bpy.data.actions.new(name=action_name)

        if not arm_obj.animation_data:
            arm_obj.animation_data_create()
        arm_obj.animation_data.action = action

        masters = {
            "Wave4x4_R1_C1": {"phase": 0.0,                "amp": amplitude},
            "Wave4x4_R2_C1": {"phase": math.pi / 4,        "amp": amplitude * 0.95},
            "Wave4x4_R1_C2": {"phase": math.pi / 2,        "amp": amplitude * 0.9},
            "Wave4x4_R2_C2": {"phase": 3 * math.pi / 4,    "amp": amplitude * 0.85},
            "Wave4x4_R0_C1": {"phase": math.pi / 3,        "amp": amplitude * 0.7},
            "Wave4x4_R0_C2": {"phase": 2 * math.pi / 3,    "amp": amplitude * 0.65},
            "Wave4x4_R1_C0": {"phase": 5 * math.pi / 6,    "amp": amplitude * 0.6},
            "Wave4x4_R2_C0": {"phase": 7 * math.pi / 6,    "amp": amplitude * 0.55},
            "Wave4x4_R0_C0": {"phase": math.pi,             "amp": amplitude * 0.5},
        }
        mirrors = {
            "Wave4x4_R3_C1": "Wave4x4_R0_C1",
            "Wave4x4_R3_C2": "Wave4x4_R0_C2",
            "Wave4x4_R1_C3": "Wave4x4_R1_C0",
            "Wave4x4_R2_C3": "Wave4x4_R2_C0",
            "Wave4x4_R0_C3": "Wave4x4_R0_C0",
            "Wave4x4_R3_C0": "Wave4x4_R0_C0",
            "Wave4x4_R3_C3": "Wave4x4_R0_C0",
        }

        bpy.context.view_layer.objects.active = arm_obj
        bpy.ops.object.mode_set(mode='POSE')

        def keyframe_bone(name, phase, amp):
            bone = arm_obj.pose.bones.get(name)
            if not bone:
                return
            for f in range(frame_count + 1):
                t = f / frame_count * 2 * math.pi
                bone.location.y = amp * math.sin(t + phase)
                bone.keyframe_insert(data_path="location", frame=f, index=1)

        for name, p in masters.items():
            keyframe_bone(name, p["phase"], p["amp"])
        for mirror_name, master_name in mirrors.items():
            p = masters[master_name]
            keyframe_bone(mirror_name, p["phase"], p["amp"])

        if hasattr(action, 'fcurves'):
            fcurves = action.fcurves
        else:
            fcurves = action.layers[0].strips[0].channelbags[0].fcurves
        for fc in fcurves:
            for kf in fc.keyframe_points:
                kf.interpolation = 'BEZIER'

        bpy.ops.object.mode_set(mode='OBJECT')

        return {
            "action": action_name,
            "frame_count": frame_count,
            "fps": fps,
            "duration_seconds": round(frame_count / fps, 2),
            "amplitude": amplitude,
            "master_bones": list(masters.keys()),
            "mirrored_bones": list(mirrors.keys()),
        }
```

- [ ] **Step 2: Register the command in the dispatch table**

Add after `"bind_ocean_rig_4x4"`:

```python
            "animate_ocean_waves_4x4": self.animate_ocean_waves_4x4,
```

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "feat(ocean-4x4): add animate_ocean_waves_4x4 handler with 9-master edge mirroring"
```

---

### Task 5: Add `export_ocean_fbx_4x4` handler to addon.py

**Files:**
- Modify: `src/blender_mcp/addon.py:216-220` (command dispatch table)
- Modify: `src/blender_mcp/addon.py` (new method after `animate_ocean_waves_4x4`)

- [ ] **Step 1: Add the handler method**

Add this method immediately after `animate_ocean_waves_4x4`:

```python
    def export_ocean_fbx_4x4(self, filepath=""):
        """Export 4x4 ocean chunk + rig as FBX with Roblox-compatible axis and baked animation."""
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
            bake_anim=True,
            bake_anim_use_all_bones=True,
            bake_anim_simplify_factor=0.0,
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
                "bake_anim_simplify_factor": 0.0,
            },
        }
```

- [ ] **Step 2: Register the command in the dispatch table**

Add after `"animate_ocean_waves_4x4"`:

```python
            "export_ocean_fbx_4x4": self.export_ocean_fbx_4x4,
```

- [ ] **Step 3: Commit**

```bash
git add src/blender_mcp/addon.py
git commit -m "feat(ocean-4x4): add export_ocean_fbx_4x4 handler"
```

---

### Task 6: Add five MCP tools to server.py

**Files:**
- Modify: `src/blender_mcp/server.py` (add 5 new tool functions after `export_ocean_chunk` at line ~1244)

All five tools follow the same pattern as the existing 3x3 tools: connect to Blender, send command, parse result, format output.

- [ ] **Step 1: Add the `create_ocean_mesh_4x4` tool**

Insert after the closing of `export_ocean_chunk` (after line 1244):

```python


@telemetry_tool("create_ocean_mesh_4x4")
@mcp.tool()
def create_ocean_mesh_4x4(ctx: Context, chunk_size: int = 64, subdivisions: int = 8) -> str:
    """
    Create the 4x4 ocean chunk mesh: an 8x8 subdivided plane with flat shading and planar UVs.
    Higher resolution variant of create_ocean_mesh for use with the 4x4 bone grid.

    Parameters:
    - chunk_size: Size in Blender units, maps 1:1 to Roblox studs (default 64)
    - subdivisions: Quad subdivisions per axis (default 8 = 128 triangles)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("create_ocean_mesh_4x4", {
            "chunk_size": chunk_size,
            "subdivisions": subdivisions,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        return (
            f"Ocean mesh '{r['name']}' created (4x4 variant).\n"
            f"Vertices: {r['vertices']}, Faces: {r['faces']}, "
            f"Triangles: {r['triangles']}\n"
            f"Size: {r['chunk_size']}x{r['chunk_size']}, "
            f"Subdivisions: {r['subdivisions']}x{r['subdivisions']}\n"
            f"UVs: planar 0-1, Shading: flat"
        )
    except Exception as e:
        logger.error(f"Error creating ocean mesh 4x4: {str(e)}")
        return f"Error creating ocean mesh 4x4: {str(e)}"
```

- [ ] **Step 2: Add the `create_ocean_rig_4x4` tool**

```python


@telemetry_tool("create_ocean_rig_4x4")
@mcp.tool()
def create_ocean_rig_4x4(ctx: Context, chunk_size: int = 64) -> str:
    """
    Create a 4x4 bone grid armature for the ocean chunk. Bones are named
    Wave4x4_R{row}_C{col} and placed at even intervals across the plane.
    Requires OceanChunk4x4 mesh to exist (run create_ocean_mesh_4x4 first).

    Parameters:
    - chunk_size: Must match the chunk_size used in create_ocean_mesh_4x4 (default 64)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("create_ocean_rig_4x4", {
            "chunk_size": chunk_size,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        return (
            f"Ocean rig '{r['name']}' created with {r['bone_count']} bones (4x4 variant).\n"
            f"Bone spacing: {r['spacing']} units\n"
            f"Bones: {', '.join(r['bones'])}"
        )
    except Exception as e:
        logger.error(f"Error creating ocean rig 4x4: {str(e)}")
        return f"Error creating ocean rig 4x4: {str(e)}"
```

- [ ] **Step 3: Add the `bind_ocean_rig_4x4` tool**

```python


@telemetry_tool("bind_ocean_rig_4x4")
@mcp.tool()
def bind_ocean_rig_4x4(ctx: Context) -> str:
    """
    Bind the OceanChunk4x4 mesh to the OceanRig4x4 armature using automatic weights.
    Each bone gets a vertex group influencing its local region of the mesh.
    Requires both OceanChunk4x4 and OceanRig4x4 to exist.
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("bind_ocean_rig_4x4", {})
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        return (
            f"Bound '{r['mesh']}' to '{r['armature']}' with automatic weights (4x4 variant).\n"
            f"Vertex groups ({r['group_count']}): {', '.join(r['vertex_groups'])}"
        )
    except Exception as e:
        logger.error(f"Error binding ocean rig 4x4: {str(e)}")
        return f"Error binding ocean rig 4x4: {str(e)}"
```

- [ ] **Step 4: Add the `animate_ocean_waves_4x4` tool**

```python


@telemetry_tool("animate_ocean_waves_4x4")
@mcp.tool()
def animate_ocean_waves_4x4(
    ctx: Context,
    frame_count: int = 72,
    amplitude: float = 1.5,
    fps: int = 30,
) -> str:
    """
    Create a looping wave animation on the OceanRig4x4 bones. Uses 9 master bones
    with distinct phase offsets for a rich rolling wave, plus 7 edge-mirrored bones
    for seamless chunk tiling. Requires OceanRig4x4 with bound mesh.

    Parameters:
    - frame_count: Total frames in the loop (default 72, = 2.4s at 30fps)
    - amplitude: Maximum displacement in Blender units (default 1.5)
    - fps: Playback frame rate (default 30)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("animate_ocean_waves_4x4", {
            "frame_count": frame_count,
            "amplitude": amplitude,
            "fps": fps,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        return (
            f"Wave animation '{r['action']}' created (4x4 variant).\n"
            f"Frames: {r['frame_count']} @ {r['fps']}fps "
            f"({r['duration_seconds']}s loop)\n"
            f"Amplitude: {r['amplitude']} units\n"
            f"Masters ({len(r['master_bones'])}): {', '.join(r['master_bones'])}\n"
            f"Mirrored ({len(r['mirrored_bones'])}): {', '.join(r['mirrored_bones'])}"
        )
    except Exception as e:
        logger.error(f"Error animating ocean waves 4x4: {str(e)}")
        return f"Error animating ocean waves 4x4: {str(e)}"
```

- [ ] **Step 5: Add the `export_ocean_chunk_4x4` tool**

```python


@telemetry_tool("export_ocean_chunk_4x4")
@mcp.tool()
def export_ocean_chunk_4x4(ctx: Context, filepath: str = "") -> str:
    """
    Export the OceanChunk4x4 mesh and OceanRig4x4 armature as FBX with Roblox-compatible
    settings. Also saves a .blend checkpoint. Axis: -Z forward, Y up.

    Parameters:
    - filepath: Output FBX path (default: beside .blend file or temp directory)
    """
    try:
        blender = get_blender_connection()
        result = blender.send_command("export_ocean_fbx_4x4", {
            "filepath": filepath,
        })
        if "error" in result.get("result", {}):
            return f"Error: {result['result']['error']}"
        r = result.get("result", {})
        size_kb = round(r["fbx_size_bytes"] / 1024, 1)
        return (
            f"Exported ocean chunk (4x4 variant):\n"
            f"  FBX: {r['fbx_path']} ({size_kb} KB)\n"
            f"  Blend: {r['blend_path']}\n"
            f"  Axis: {r['settings']['axis_forward']} fwd, "
            f"{r['settings']['axis_up']} up\n"
            f"  Leaf bones: off, Simplify: 0.0"
        )
    except Exception as e:
        logger.error(f"Error exporting ocean chunk 4x4: {str(e)}")
        return f"Error exporting ocean chunk 4x4: {str(e)}"
```

- [ ] **Step 6: Commit**

```bash
git add src/blender_mcp/server.py
git commit -m "feat(ocean-4x4): add five MCP tools for 4x4 ocean chunk workflow"
```

---

### Task 7: Add `ocean_chunk_4x4_workflow` prompt to server.py

**Files:**
- Modify: `src/blender_mcp/server.py` (add new prompt after `ocean_chunk_workflow`, before `def main()`)

- [ ] **Step 1: Add the workflow prompt**

Insert after the closing of `ocean_chunk_workflow` (after line 1378), before the `# Main execution` comment:

```python

@mcp.prompt()
def ocean_chunk_4x4_workflow() -> str:
    """Step-by-step workflow for creating a 4x4 tiling ocean chunk in Blender"""
    return """Ocean Chunk 4x4 Authoring Workflow
===================================

Higher-detail variant with a 4x4 bone grid (16 bones, 9 independent masters).
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

PHASE 5 — ANIMATE (checkpoint after)
  Call animate_ocean_waves_4x4(frame_count=72, amplitude=1.5, fps=30).
  Expected: 2.4-second loop, 9 master bones + 7 mirrored, Bezier interpolation.
  Edge mirroring: R0=R3 rows, C0=C3 columns, all corners identical.
  -> Play animation and take screenshot for user review.

PHASE 6 — EXPORT (checkpoint after)
  Call export_ocean_chunk_4x4().
  Expected: FBX with baked animation + .blend checkpoint saved.
  Settings: -Z forward, Y up, no leaf bones, simplify=0.

PHASE 7 — NEXT STEPS
  Tell the user:
  1. Import the FBX into Roblox Studio
  2. Publish the MeshPart to get an rbxassetid
  3. Use OceanSystem.lua with the asset ID to spawn the tiling grid
     (same Lua module works for both 3x3 and 4x4 chunks)
"""

```

- [ ] **Step 2: Commit**

```bash
git add src/blender_mcp/server.py
git commit -m "feat(ocean-4x4): add ocean_chunk_4x4_workflow prompt"
```

---

### Task 8: Verify full command dispatch and tool registration

**Files:**
- Read: `src/blender_mcp/addon.py` (dispatch table ~line 216)
- Read: `src/blender_mcp/server.py` (scan for all `_4x4` tool functions)

- [ ] **Step 1: Verify the addon.py dispatch table has all 5 entries**

Open `src/blender_mcp/addon.py` and confirm the dispatch table contains these five lines:

```python
            "create_ocean_mesh_4x4": self.create_ocean_mesh_4x4,
            "create_ocean_rig_4x4": self.create_ocean_rig_4x4,
            "bind_ocean_rig_4x4": self.bind_ocean_rig_4x4,
            "animate_ocean_waves_4x4": self.animate_ocean_waves_4x4,
            "export_ocean_fbx_4x4": self.export_ocean_fbx_4x4,
```

- [ ] **Step 2: Verify server.py has all 5 tools + 1 prompt**

Search `src/blender_mcp/server.py` for `_4x4` and confirm these 6 definitions exist:

1. `def create_ocean_mesh_4x4(` — tool
2. `def create_ocean_rig_4x4(` — tool
3. `def bind_ocean_rig_4x4(` — tool
4. `def animate_ocean_waves_4x4(` — tool
5. `def export_ocean_chunk_4x4(` — tool
6. `def ocean_chunk_4x4_workflow(` — prompt

- [ ] **Step 3: Verify command name consistency**

Confirm each MCP tool sends the correct command string to `blender.send_command()`:

| MCP Tool | send_command string |
|----------|-------------------|
| `create_ocean_mesh_4x4` | `"create_ocean_mesh_4x4"` |
| `create_ocean_rig_4x4` | `"create_ocean_rig_4x4"` |
| `bind_ocean_rig_4x4` | `"bind_ocean_rig_4x4"` |
| `animate_ocean_waves_4x4` | `"animate_ocean_waves_4x4"` |
| `export_ocean_chunk_4x4` | `"export_ocean_fbx_4x4"` |

Note: The export tool is named `export_ocean_chunk_4x4` (MCP) but sends `export_ocean_fbx_4x4` (addon) — this matches the 3x3 pattern where `export_ocean_chunk` sends `export_ocean_fbx`.

- [ ] **Step 4: Commit if any fixes were needed**

```bash
git add src/blender_mcp/addon.py src/blender_mcp/server.py
git commit -m "fix(ocean-4x4): correct any registration issues found during verification"
```
