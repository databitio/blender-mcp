# Ocean Wind Waker Sine Wave Displacement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace bone animation in OceanSystem.lua with deterministic compound sine wave displacement per chunk.

**Architecture:** A pure `waveHeight(x, z, time, config)` function evaluates 4 stacked sine waves at each chunk's world position every frame. The heartbeat loop calls `updateWaves` between `updateGrid` and `updateTextures`. All animation-related code (playAnimation, AnimationController/Animator/Animation creation) is removed.

**Tech Stack:** Roblox Luau (strict mode)

**Spec:** `docs/superpowers/specs/2026-05-25-ocean-windwaker-sine-waves-design.md`

---

### File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/roblox/OceanSystem.lua` | Modify | All changes — types, sine engine, heartbeat loop, chunk creation |

---

### Task 1: Update type definitions

**Files:**
- Modify: `src/roblox/OceanSystem.lua:25-47` (type blocks)

- [ ] **Step 1: Add `WaveParams` export type**

Add after the existing `export type OceanConfig` block (after line 35). Insert the new type just above `OceanConfig`:

```lua
export type WaveParams = {
    amplitude: number,
    frequencyX: number,
    frequencyZ: number,
    phase: number,
    speed: number,
}
```

- [ ] **Step 2: Update `OceanConfig`**

Replace the current `OceanConfig` type with:

```lua
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
```

Changes from current: `animationId` removed, `waveHeight` renamed to `baseHeight`, `waves` and `waveSpeed` added.

- [ ] **Step 3: Update `ResolvedConfig`**

Replace the current `ResolvedConfig` type with:

```lua
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
```

Changes from current: `animationId` removed, `waveHeight` renamed to `baseHeight`, `waves` and `waveSpeed` added (non-optional in resolved form).

- [ ] **Step 4: Update the module header comment**

Replace lines 1-19 with:

```lua
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
```

- [ ] **Step 5: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "refactor(ocean): update types for sine wave displacement"
```

---

### Task 2: Add default wave preset and update resolveConfig

**Files:**
- Modify: `src/roblox/OceanSystem.lua:49-84` (module state + resolveConfig)

- [ ] **Step 1: Add the default wave preset constant**

Insert after the `local OceanSystem = {}` line (current line 49) and before the module state block:

```lua
local DEFAULT_WAVES: { WaveParams } = {
    { amplitude = 1.0, frequencyX = 1.0, frequencyZ = 0.0, phase = 0,    speed = 1.0 },
    { amplitude = 0.8, frequencyX = 2.2, frequencyZ = 0.5, phase = 5.52, speed = 1.3 },
    { amplitude = 0.6, frequencyX = 0.5, frequencyZ = 2.9, phase = 0.93, speed = 0.8 },
    { amplitude = 0.4, frequencyX = 1.8, frequencyZ = 4.6, phase = 8.94, speed = 1.6 },
}
```

- [ ] **Step 2: Add `elapsed` to module state**

Add to the module state block (after `local scrollV: number = 0`):

```lua
local elapsed: number = 0
```

- [ ] **Step 3: Update `resolveConfig` return table**

Replace the return table inside `resolveConfig` with:

```lua
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
```

Changes: `animationId` removed, `waveHeight` renamed to `baseHeight`, `waves` defaults to `DEFAULT_WAVES`, `waveSpeed` defaults to `1.0`.

- [ ] **Step 4: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add default wave preset and update resolveConfig"
```

---

### Task 3: Remove animation code and simplify createChunk

**Files:**
- Modify: `src/roblox/OceanSystem.lua:86-125` (playAnimation + createChunk)

- [ ] **Step 1: Delete the `playAnimation` function**

Remove the entire `playAnimation` function (current lines 86-103):

```lua
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
```

- [ ] **Step 2: Remove the animation call from `createChunk`**

In `createChunk`, remove the animation block (current lines 120-122):

```lua
    if c.animationId then
        playAnimation(part, c.animationId)
    end
```

The resulting `createChunk` function should be:

```lua
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

    return part
end
```

- [ ] **Step 3: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "refactor(ocean): remove bone animation code from chunk creation"
```

---

### Task 4: Add waveHeight function and updateWaves

**Files:**
- Modify: `src/roblox/OceanSystem.lua` (insert after `updateGrid`, before `updateTextures`)

- [ ] **Step 1: Add the `waveHeight` pure function**

Insert after the `updateGrid` function and before `updateTextures`:

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

- [ ] **Step 2: Add the `updateWaves` function**

Insert immediately after `waveHeight`:

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

- [ ] **Step 3: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add compound sine waveHeight engine and updateWaves"
```

---

### Task 5: Wire updateWaves into the heartbeat and update stop/start

**Files:**
- Modify: `src/roblox/OceanSystem.lua` (start, stop, heartbeat)

- [ ] **Step 1: Update `updateGrid` to use `baseHeight`**

In `updateGrid`, change the chunk positioning line from:

```lua
                c.waveHeight,
```

to:

```lua
                c.baseHeight,
```

- [ ] **Step 2: Update the heartbeat callback in `OceanSystem.start`**

Replace the heartbeat connection:

```lua
    heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
        updateGrid(c)
        updateTextures(c, dt)
    end)
```

with:

```lua
    heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
        updateGrid(c)
        updateWaves(c, dt)
        updateTextures(c, dt)
    end)
```

- [ ] **Step 3: Reset `elapsed` in `OceanSystem.start`**

In `OceanSystem.start`, add `elapsed = 0` next to the existing scroll resets. The reset block should read:

```lua
    running = true
    scrollU = 0
    scrollV = 0
    elapsed = 0
```

- [ ] **Step 4: Reset `elapsed` in `OceanSystem.stop`**

In `OceanSystem.stop`, add `elapsed = 0` next to the existing scroll resets. The reset block should read:

```lua
    running = false
    scrollU = 0
    scrollV = 0
    elapsed = 0
```

- [ ] **Step 5: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): wire sine wave displacement into heartbeat loop"
```

---

### Task 6: Final review and verification

**Files:**
- Read: `src/roblox/OceanSystem.lua` (full file)

- [ ] **Step 1: Read the complete file and verify**

Read `src/roblox/OceanSystem.lua` top to bottom. Check:

1. `--!strict` is still on line 1
2. `WaveParams` type is exported
3. `OceanConfig` has no `animationId` field
4. `OceanConfig` has `baseHeight`, `waves`, `waveSpeed` fields
5. `ResolvedConfig` mirrors `OceanConfig` with non-optional resolved types
6. `DEFAULT_WAVES` has exactly 4 entries with correct values
7. `elapsed` is in the module state block
8. `playAnimation` function does not exist
9. `createChunk` has no animation code
10. `waveHeight` function exists and divides by `#c.waves`
11. `updateWaves` function exists and uses `c.baseHeight + y`
12. Heartbeat order is: `updateGrid` -> `updateWaves` -> `updateTextures`
13. `updateGrid` uses `c.baseHeight` (not `c.waveHeight`)
14. Both `start` and `stop` reset `elapsed = 0`
15. No references to `animationId`, `playAnimation`, `AnimationController`, `Animator`, or `Animation` remain

- [ ] **Step 2: Verify no Luau syntax errors**

Search the file for common issues:
- Mismatched `end` keywords
- Missing commas in type definitions
- `+=` operator is valid in Luau (confirm all uses are inside functions)

- [ ] **Step 3: Final commit if any fixes were needed**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "fix(ocean): address review findings in sine wave implementation"
```

Only commit if changes were made. If verification passed clean, skip this step.
