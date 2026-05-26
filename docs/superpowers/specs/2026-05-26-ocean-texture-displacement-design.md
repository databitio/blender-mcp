# Ocean Texture Displacement Design

## Summary

Add sine-driven UV offset oscillation to OceanSystem's texture rendering. A compound sine function displaces each chunk's texture offsets (OffsetStudsU/V) over time, creating organic wiggling movement layered on top of the existing linear scroll. Inspired by flow-map UV distortion techniques, adapted to Roblox's per-chunk texture offset API.

## Motivation

The current ocean texture scrolls linearly at a fixed speed/direction. While functional, it looks mechanical. Real ocean surfaces exhibit organic, non-linear texture movement. True per-pixel UV distortion (flow maps) isn't possible in Roblox without custom shaders, but per-chunk sine-driven offset oscillation approximates the effect at minimal cost.

## Approach

### Chosen: Sine-Driven Per-Chunk Offset Oscillation (Runtime Lua)

Drive each chunk's `OffsetStudsU`/`OffsetStudsV` with a compound sine function evaluated at the chunk's world position. The sine function is continuous across space, so adjacent chunks get similar (but slightly different) displacement values, creating a gradual organic pattern.

### Alternatives Considered

- **Pre-baked flipbook (Blender)**: Best visual fidelity (true per-pixel UV distortion baked as 16-32 texture frames). Rejected for now due to asset pipeline complexity (16-32 uploaded textures, memory overhead). Reserved as a future upgrade path.
- **Multi-layer runtime scroll**: Stack 2-3 semi-transparent textures per chunk at different scroll speeds. Good visual richness but requires specially designed overlay textures. Can be layered on top of the chosen approach later.

## Architecture

### Texture Offset Pipeline (per frame)

```
EXISTING (unchanged)                NEW: displacement
─────────────────────               ──────────────────
scrollU += scrollSpeed.X × dt       du, dv = textureDisplacement(
scrollV += scrollSpeed.Y × dt           chunk.worldX, chunk.worldZ,
                                         elapsed, config.displacementWaves
         │                           )
         └──────────┬────────────────┘
                    ▼
    tex.OffsetStudsU = scrollU + worldPos.X + du
    tex.OffsetStudsV = scrollV + worldPos.Z + dv
```

### textureDisplacement Function

```lua
local function textureDisplacement(x, z, time, c)
    local du, dv = 0, 0
    for _, w in ipairs(c.displacementWaves) do
        local input = w.frequencyX * x + w.frequencyZ * z
        du += w.amplitudeU * math.sin(input + w.phaseU + w.speedU * time)
        dv += w.amplitudeV * math.sin(input + w.phaseV + w.speedV * time)
    end
    return du / #c.displacementWaves, dv / #c.displacementWaves
end
```

Same pattern as the existing `waveHeight()` for bone displacement — compound sine waves evaluated at world position + time.

### Chunk Seam Mitigation

Since displacement is per-chunk (not per-pixel), adjacent chunks with different offsets produce visible seams. Long wavelengths minimize this:

| Wavelength | Max Seam (A=3) | % of 16-stud Tile | Verdict |
|---|---|---|---|
| 400 studs | ~2.9 studs | 18% | Visible seams |
| 800 studs | ~1.5 studs | 9% | Subtle |
| **1200 studs** | **~1.0 studs** | **6%** | **Default sweet spot** |
| 2000 studs | ~0.6 studs | 4% | Nearly invisible |

Default frequencies (0.003–0.006) produce wavelengths of 1000–2000 studs, keeping inter-chunk seams under ~1 stud. Bone wave geometry deformation and texture scroll further mask remaining seams.

## Config API

### New Type

```lua
export type DisplacementWaveParams = {
    amplitudeU: number,   -- max U offset in studs (2-4 = moderate)
    amplitudeV: number,   -- max V offset in studs
    frequencyX: number,   -- spatial frequency on X axis (≤0.006 recommended)
    frequencyZ: number,   -- spatial frequency on Z axis
    phaseU: number,       -- initial phase for U displacement (radians)
    phaseV: number,       -- initial phase for V displacement (radians)
    speedU: number,       -- temporal speed for U (0.5-1.0 = gentle)
    speedV: number,       -- temporal speed for V
}
```

### Config Addition

```lua
Ocean.start({
    -- existing fields unchanged...
    displacementWaves = {
        {
            amplitudeU = 3.0,  amplitudeV = 2.0,
            frequencyX = 0.005, frequencyZ = 0.003,
            phaseU = 0, phaseV = 1.57,
            speedU = 0.8, speedV = 0.6,
        },
        {
            amplitudeU = 2.0, amplitudeV = 2.5,
            frequencyX = 0.003, frequencyZ = 0.006,
            phaseU = 2.09, phaseV = 4.19,
            speedU = 0.5, speedV = 0.9,
        },
    },
})
```

### Default Preset Rationale

- **2 compound waves**: enough for organic, non-repeating movement without unnecessary computation.
- **Asymmetric U/V amplitudes and speeds**: wave 1 favors U movement, wave 2 favors V. Prevents diagonal sliding; texture traces slow figure-8-like paths.
- **Phase offsets (π/2, 2π/3, 4π/3)**: ensures U and V don't peak simultaneously, maximizing visual variety.
- **Low frequencies (0.003–0.006)**: wavelengths of 1000–2000 studs keep inter-chunk seams under 1 stud.

### Backward Compatibility

If `displacementWaves` is `nil` or empty, the system behaves exactly as today — pure linear scroll, no wiggle.

## Implementation Scope

**Single file change**: `src/roblox/OceanSystem.lua`, ~30 lines added.

| Location | Change |
|---|---|
| `DisplacementWaveParams` type | New exported type |
| `OceanConfig` type | Add optional `displacementWaves` field |
| `ResolvedConfig` type | Add `displacementWaves` field |
| `DEFAULT_DISPLACEMENT_WAVES` | New constant (2-wave preset) |
| `resolveConfig()` | Resolve displacement waves field |
| `textureDisplacement()` | New function (compound sine → du, dv) |
| `updateTextures()` | Call textureDisplacement(), add du/dv to offsets |

### What Does NOT Change

- Blender addon — no mesh, rig, or export modifications
- Bone wave system — `waveHeight()` and `updateBones()` untouched
- Chunk grid and object pooling — no structural changes
- All existing config fields — fully backward compatible
- Export pipeline — no new assets required

### Sync with Bone Waves

Texture displacement reuses the existing `elapsed` time variable (already tracked for bone wave updates), so both systems stay temporally synchronized.

## Future Enhancements

- **Multi-layer scroll (Approach B)**: Add 1-2 semi-transparent overlay textures with independent scroll speeds for visual richness. Composable on top of this displacement system.
- **Pre-baked flipbook (Approach A)**: If per-chunk granularity isn't sufficient, bake true per-pixel flow-map distortion as a texture sequence in Blender.
