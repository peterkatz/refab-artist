# 3D Slices — spec

**3D Slices** cuts the model into contiguous layers along one axis, and each
layer keeps the model's real 3D surface on its side walls. Stacking the
layers rebuilds the model as peel-apart bands. The result is a printable
**layered mesh**: the mode exports STL and OBJ only and has no flat cut
sheet.

It is Stacked Slices with true side walls: Stacked extrudes each
cross-section straight up into a flat plate; 3D Slices keeps the surface
between the cuts.

Sources: `ThreeDSlices.swift` (plan), `ThreeDSliceMeshExportBuilder.swift`
(layers), `ExportFormatSupport.swift` (formats).

---

## 1. Parameters

| Parameter | GUI | CLI | Default | Effect |
|---|---|---|---|---|
| Slice depth | Technique Settings → Slice depth (0.5–100 mm) | `--slice-depth` | GUI 10 mm; CLI = thickness | Spacing between layer centres. |
| Distribute count | Technique Settings → Distribute count (1–240) | `--slice-count` | off | Overrides slice depth with an even count. |
| Thickness | — (CLI only) | `--thickness` | CLI 5 mm | Used as slice depth when none is given (CLI). |
| Slice Direction | Slice Direction panel (tilt) | `--slice-tilt-first`, `--slice-tilt-second` | 0, 0 | Tilts the slicing direction away from Z (up to ±89° about X and Y). |

Slot offset, notch width and slot angle are still carried on the plan but do
not affect the layered mesh. The layered mesh has no stock, slots or sheets,
so nothing in Manufacturing Settings changes it: the app does not show that
section for 3D Slices, and the Technique Settings say so ("3D Slices builds
a layered mesh to print, so it has no Manufacturing Settings: stock, slots
and sheets do not change it."). For the same reason the assembly guide prints
the slice depth (or the Distribute count) in place of a material thickness
(`docs/specs/assembly-steps.md` § 6).

## 2. Decision logic

### 2.1 Layer centres

Layers are cut along **Z**. The centres come from the Stacked automatic rule
over the model's Z extent `[lo, hi]` with slice depth `d`:

```
n     = max(1, floor((hi - lo) / d))
base  = (lo + hi) / 2 - (n + 0.5) · d / 2
i     = ceil((lo - base)/d + 0.1) … floor((hi - base)/d + 0.1)
z_i   = i · d + base
```

With Distribute count `N`, the centres are `lo + (hi - lo)(i + 0.5)/N` for
`i = 0 … N-1`.

### 2.2 Band boundaries

The layers tile the whole model with no gaps. Interior cut planes sit at the
midpoints between consecutive centres; the first band starts at the model's
minimum and the last ends at its maximum, so the model's own top and bottom
surfaces close them. One band per centre.

### 2.3 Building a band

For each band `[a, b]`:

1. Every model triangle wholly inside the slab is kept. Triangles that cross
   a cut plane are clipped to the slab and re-triangulated; triangles wholly
   outside are dropped.
2. Each **interior** cut plane is capped with the model's cross-section at
   that plane (the Stacked contourer run at the boundary position),
   triangulated and wound to face out of the band.
3. Bands with no triangles are skipped.

Bands are named `three_d_001`, `three_d_002`, … from the bottom up.

## 3. Output

The app and the headless exporter both offer STL and OBJ only; the CLI
refuses `--format svg|pdf|eps|dxf` for 3D Slices as an unsupported format.

- **STL** — all bands in one ASCII solid named `refabartist_3d_slices`.
- **OBJ** — one object/group per band (`o three_d_NNN` / `g three_d_NNN`),
  millimetre units.
- **Viewport** — the same bands, one colour per band. The assembly stepper
  has one step per band (`Place three_d_NNN`) and ghosts bands after the
  selected step.

If the layer builder produces no bands (an empty or degenerate model), the
STL/OBJ writers fall back to flat plates extruded from the X, Y and Z
families' cross-sections.

## 4. Edge cases

- **Open or non-manifold meshes**: side walls are copied as they are, so a
  hole in the surface stays a hole in its band. Caps follow whatever closed
  cross-section loops the contourer finds at each cut.
- **Zero-height model** (no Z extent): no bands.
- **More than 600 slices across the plan's families**: the GUI shows no plan
  and asks for a larger slice depth or a smaller model.

## 5. Worked example

50 mm cube centred on the origin, CLI defaults (`--thickness 5`, no
`--slice-depth`, so `d = 5`):

- `n = 10`, `base = 0 − 10.5 · 5 / 2 = −26.25`.
- `i = ceil(0.35) … floor(10.35) = 1 … 10`, so the centres are
  `−21.25, −16.25, …, 23.75`.
- Cut planes at the midpoints `−18.75, −13.75, …, 21.25`; bands run from
  `−25` to `−18.75`, …, `21.25` to `25`.
- Ten bands, `three_d_001` … `three_d_010`. Each is a 50 × 50 mm box whose
  height is the band's span (6.25 mm for the first band, 3.75 mm for the
  last, 5 mm in between).

## 6. Known leftovers

- The plan still builds X and Y slice families; only Z is used for the mesh.
  The assembly steps are the bands only (`Place three_d_NNN`, one per Z
  slice; `docs/specs/assembly-steps.md` § 2), but they keep the indices
  counted through the X and Y families.
