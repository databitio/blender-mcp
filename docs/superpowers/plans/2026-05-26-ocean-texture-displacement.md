# Ocean Texture Displacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add sine-driven UV offset oscillation to OceanSystem so ocean textures wiggle organically instead of scrolling linearly.

**Architecture:** A `textureDisplacement(x, z, time, config)` function (compound sine waves, same pattern as existing `waveHeight()`) computes per-chunk U/V offsets layered on top of the existing linear scroll. Long wavelengths (~1200 studs) minimize inter-chunk seams. Fully backward compatible — omitting `displacementWaves` from config keeps current behavior.

**Tech Stack:** Luau (Roblox), runs inside OceanSystem module

**Spec:** `docs/superpowers/specs/2026-05-26-ocean-texture-displacement-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/roblox/OceanSystem.lua` | Modify | All changes — types, defaults, displacement function, updateTextures wiring |

---

### Task 1: Add DisplacementWaveParams Type and Default Constant

**Files:**
- Modify: `src/roblox/OceanSystem.lua:25-72`

- [ ] **Step 1: Add the DisplacementWaveParams type**

Insert after the existing `WaveParams` type (after line 31). This type has separate U/V amplitudes, phases, and speeds to allow asymmetric displacement per axis:

```lua
export type DisplacementWaveParams = {
	amplitudeU: number,
	amplitudeV: number,
	frequencyX: number,
	frequencyZ: number,
	phaseU: number,
	phaseV: number,
	speedU: number,
	speedV: number,
}
```

- [ ] **Step 2: Add displacementWaves to OceanConfig**

Add the optional field to the `OceanConfig` type, after the `waveSpeed` field (line 43):

```lua
	displacementWaves: { DisplacementWaveParams }?,
```

- [ ] **Step 3: Add displacementWaves to ResolvedConfig**

Add the resolved (non-optional) field to `ResolvedConfig`, after the `waveSpeed` field (line 56):

```lua
	displacementWaves: { DisplacementWaveParams },
```

- [ ] **Step 4: Add DEFAULT_DISPLACEMENT_WAVES constant**

Insert after the existing `DEFAULT_WAVES` constant (after line 72). Two compound waves with long wavelengths and asymmetric U/V parameters:

```lua
local DEFAULT_DISPLACEMENT_WAVES: { DisplacementWaveParams } = {
	{ amplitudeU = 3.0, amplitudeV = 2.0, frequencyX = 0.005, frequencyZ = 0.003, phaseU = 0, phaseV = 1.57, speedU = 0.8, speedV = 0.6 },
	{ amplitudeU = 2.0, amplitudeV = 2.5, frequencyX = 0.003, frequencyZ = 0.006, phaseU = 2.09, phaseV = 4.19, speedU = 0.5, speedV = 0.9 },
}
```

- [ ] **Step 5: Wire into resolveConfig**

Add the displacement waves resolution to the return table in `resolveConfig()`. Insert after the `waveSpeed` line (line 111 in current file):

```lua
		displacementWaves = raw.displacementWaves or DEFAULT_DISPLACEMENT_WAVES,
```

- [ ] **Step 6: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add DisplacementWaveParams type and default preset"
```

---

### Task 2: Add textureDisplacement Function and Wire Into updateTextures

**Files:**
- Modify: `src/roblox/OceanSystem.lua:115-237`

- [ ] **Step 1: Add the textureDisplacement function**

Insert after the existing `waveHeight()` function (after line 121). Same compound-sine pattern — evaluates each displacement wave at the chunk's world position and returns averaged U/V offsets:

```lua
local function textureDisplacement(x: number, z: number, time: number, c: ResolvedConfig): (number, number)
	local du, dv = 0, 0
	local waves = c.displacementWaves
	for _, w in ipairs(waves) do
		local input = w.frequencyX * x + w.frequencyZ * z
		du += w.amplitudeU * math.sin(input + w.phaseU + w.speedU * time)
		dv += w.amplitudeV * math.sin(input + w.phaseV + w.speedV * time)
	end
	return du / #waves, dv / #waves
end
```

- [ ] **Step 2: Update updateTextures to apply displacement**

Replace the current `updateTextures` function body. The only change is computing `du, dv` per chunk and adding them to the offsets. When `displacementWaves` is empty, the function would divide by zero — guard with a length check:

Replace the existing `updateTextures` function (lines 226-237) with:

```lua
local function updateTextures(c: ResolvedConfig, dt: number)
	scrollU = (scrollU + c.scrollSpeed.X * dt) % c.studsPerTile
	scrollV = (scrollV + c.scrollSpeed.Y * dt) % c.studsPerTile

	local hasDisplacement = #c.displacementWaves > 0

	for _, chunk in pairs(activeChunks) do
		local tex = chunk.part:FindFirstChildOfClass("Texture")
		if tex then
			local du, dv = 0, 0
			if hasDisplacement then
				du, dv = textureDisplacement(
					chunk.part.Position.X,
					chunk.part.Position.Z,
					elapsed, c
				)
			end
			tex.OffsetStudsU = scrollU + chunk.part.Position.X + du
			tex.OffsetStudsV = scrollV + chunk.part.Position.Z + dv
		end
	end
end
```

- [ ] **Step 3: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "feat(ocean): add textureDisplacement and wire into updateTextures"
```

---

### Task 3: Update Module Header and Verify

**Files:**
- Modify: `src/roblox/OceanSystem.lua:1-20`

- [ ] **Step 1: Update the usage comment in the module header**

Replace the existing header comment (lines 2-20) with an updated version that documents the new `displacementWaves` config option:

```lua
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
            displacementWaves = {
                { amplitudeU = 3.0, amplitudeV = 2.0, frequencyX = 0.005, frequencyZ = 0.003,
                  phaseU = 0, phaseV = 1.57, speedU = 0.8, speedV = 0.6 },
                { amplitudeU = 2.0, amplitudeV = 2.5, frequencyX = 0.003, frequencyZ = 0.006,
                  phaseU = 2.09, phaseV = 4.19, speedU = 0.5, speedV = 0.9 },
            },
        })
        Ocean.stop()
]]
```

- [ ] **Step 2: Verify in Roblox Studio — displacement enabled (defaults)**

1. Open Roblox Studio with the ocean test place
2. Call `Ocean.start()` with a valid `chunkTemplate` and `textureId`, but **omit** `displacementWaves` (so defaults apply)
3. Observe: the ocean texture should scroll linearly as before, with an additional organic wiggling/breathing motion layered on top
4. Fly the camera across multiple chunks — seams between chunks should be minimal (< 1 stud offset difference)

- [ ] **Step 3: Verify in Roblox Studio — displacement disabled**

1. Call `Ocean.start()` with `displacementWaves = {}`
2. Observe: the ocean texture should scroll purely linearly, identical to the behavior before this feature was added
3. This confirms backward compatibility

- [ ] **Step 4: Verify in Roblox Studio — custom values**

1. Call `Ocean.start()` with a single displacement wave with exaggerated amplitude to confirm it's responsive:

```lua
displacementWaves = {
    { amplitudeU = 8.0, amplitudeV = 8.0, frequencyX = 0.005, frequencyZ = 0.005,
      phaseU = 0, phaseV = 1.57, speedU = 1.5, speedV = 1.5 },
}
```

2. Observe: the texture should wiggle dramatically, confirming the config is being read and applied

- [ ] **Step 5: Commit**

```bash
git add src/roblox/OceanSystem.lua
git commit -m "docs(ocean): add displacementWaves to module header usage example"
```
