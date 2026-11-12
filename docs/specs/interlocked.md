# Interlocked Slices — spec

**Interlocked Slices** cuts the model with two perpendicular families of
parallel planes and carves half-lap slots where the families cross, so the
flat parts slide together into a waffle grid. Stacked Slices is the
one-family case; Interlocked adds the second family and the slots.

Sources: `InterlockedSlices.swift` (plan, axis choice, slot relief),
`StackedSlices.swift` (family positions), `InterlockedSlotCutouts.swift`
(plan-level slot rectangles), `InterlockedPartBuilder.swift` (the slotted part
outlines of the cut sheet), `CutSheetDocument.swift` (sheet parts, labels and
slot relief), `AssemblySteps.swift`.

---

## 1. What the mode produces

1. Two families of slices — **primary** and **secondary** — each a set of
   parallel cross-sections of the model.
2. A half-lap slot in every part at every place the other family crosses it.
   Primary parts open on one edge, secondary parts on the opposite edge, so
   each pair meets at the mid-plane.
3. One labelled cut-sheet part per disconnected piece of each slice.
4. Optional dog-bone relief at the slot corners (§ 3.5).

## 2. Parameters

| Parameter | GUI | CLI | Default | Effect |
|---|---|---|---|---|
| Primary axis | Technique Settings → Primary | `--axis` | Z | First family's slicing axis (see § 3.1). Greyed out, with a caption naming the axes used, while the model picks the axes itself. |
| Secondary axis | Technique Settings → Secondary | `--secondary-axis` | X | Second family's axis. If equal to the primary, the first other axis is used. Greyed out like Primary. |
| Thickness | Manufacturing Settings | `--thickness` | GUI 3 mm; CLI 5 mm | Material thickness; sets the slot width. |
| Slot Offset | Technique Settings / Manufacturing Settings | `--slot-clearance` | 0 | Added to the thickness to give the slot width. Not used while Notch width is on: both copies are greyed out with the caption "Notch width sets the slot width, so Slot Offset is not used." |
| Notch width | Technique Settings → Notch width (0.1–50 mm) | `--notch-width` | off | Replaces `thickness + offset` as the slot width. |
| Slot angle | Technique Settings → Slot angle (0–60°) | `--slot-angle` | GUI 45°; CLI 0° | Flares each slot mouth. Clamped to 0–60°. |
| Slot relief | Technique Settings → Slot relief | `--slot-relief` | off | Dog-bone relief at the slot corners (§ 3.5). |
| Tool Dia. | Manufacturing Settings → Tool Dia. | `--tool-diameter` (older spelling `--slot-relief-diameter`) | 0 | The relief disc diameter: the one tool diameter, shared with Radial relief. 0 cuts no relief. Greyed out while Slot relief is off. |
| Distribute count | Technique Settings → Distribute count (1–240) | `--slice-count` | off (10 per family) | Slices per family. |
| Slice Direction | Slice Direction panel | `--slice-tilt-first`, `--slice-tilt-second` | 0, 0 | Tilts the slicing direction away from the primary axis (up to ±89° about each of the two perpendicular axes). |

The slot width is `max(0.1, notchWidth ?? thickness + slotOffset)`.

## 3. Decision logic

### 3.1 Axis choice

Both families are vertical planks laid across the model's **longest**
bounding-box extent, so the longest axis is never a slicing direction. Extents
within 1 % of the longest count as tied.

| Longest extent(s) | Primary, secondary |
|---|---|
| Z only | X, Y |
| X only | Y, Z |
| Y only | X, Z |
| X and Y tied, Z shorter | X, Y |
| X and Z tied, Y shorter | X, Z |
| Y and Z tied, X shorter | Y, Z |
| All three tied (cube, sphere) | the user's axes, unchanged |

So Primary and Secondary only matter when all three extents tie. Otherwise
the app greys both pickers out and says under them which axes the slices
use ("Slices run across this model's longest side, on X and Y. Primary and
Secondary apply when its sides are about equal.").

### 3.2 Slice positions

Each family has **10** slices by default (Distribute count overrides it, up
to 240), spread evenly over the model's extent `[lo, hi]` on that family's
axis:

```
position_i = lo + (hi - lo) · (i + 0.5) / N,   i = 0 … N-1
```

So a 50 mm extent gives a 5 mm pitch and a 40 mm extent a 4 mm pitch; the
count, not the material thickness, sets the spacing.

### 3.3 Cross-sections

Each slice is the model's cross-section at its plane (the Stacked
contourer). For the cut sheet, every closed boundary loop of a slice becomes
its own part, largest first.

### 3.4 Slots

There are two slot builders.

**Plan-level slots** (3D viewport guides and mesh exports, which lay out
plan contours).
For each slice and each crossing position `c` of the other family, a
rectangle `slotWidth` wide centred on `c`, running along the slice's other
in-plane axis (the depth axis) over half of the **model's bounding box** on
that axis:

- primary slices: from the depth midpoint to the depth maximum (mouth at the
  maximum);
- secondary slices: from the depth minimum to the midpoint (mouth at the
  minimum).

With a slot angle `a > 0`, the mouth widens on both sides by
`depthSpan · tan(a)`, where `depthSpan` is the slot's length, giving a
trapezoid. There are `N_primary × N_secondary × 2` slots in total.

**Cut-sheet part outlines** (the GUI cut sheet, the DXF / SVG / PDF export
from the app and the CLI, Print and the assembly audit). Each part's outline
has the slots spliced into its boundary:

- The slot is the plan's slot width (`thickness + offset`, or the notch
  width).
- The depth midpoint is the part's **own** depth extent, not the model's.
- A slot is carved only where its crossing position lies inside the part's
  extent along the crossing axis; a slot that reaches the part's edge is
  clamped and takes the corner with it.
- The slot runs from the open edge to just past the midpoint (by
  `0.15625 × k`), where `k` is the slot offset, or 0.2 mm when the offset is
  0. While Notch width is on, `k` is the notch width less the thickness
  (0.2 mm when that is 0 or less), so the unused slot offset changes
  nothing and a notch width of `thickness + offset` cuts exactly what that
  offset does.
- The mouth flares by `0.278125 × k × min(1, tan(a))` when `a > 0`.
- Slots that touch or overlap (stock at least as thick as the slice
  spacing) merge into one cut, so the material between them goes too.
- Rectangular sections are built directly from their extents; curved or
  irregular sections trace the real contour and splice the slots into it,
  falling back to the rectangular build if the contour cannot be traced
  safely. Where a slot near a cap is deeper than the section, the slot cuts
  the cap's tip off rather than leaving the outline crossing itself.

### 3.5 Slot relief

The relief is sized by **Tool Dia.** in Manufacturing Settings, the one tool
diameter every relief-cutting mode uses (CLI `--tool-diameter`). When Slot
relief is on and Tool Dia. is above 0:

- **Cut-sheet parts**: each inside corner of a slot (where the slot bottom
  meets a wall) gets a disc of the tool diameter, centred one radius from
  the corner along the diagonal into the slot, so a round cutter of that
  diameter reaches the corner. The discs are cut out of the part outline. A
  slot clamped at the end of a part has no inside corner there. If the discs
  cut a piece off (a relief wider than the material between slots), the
  piece is dropped and the part is flagged as an error.
- **Merged slots**: slots that touch or overlap (§ 3.4) leave no inside
  corners between them. When the slots merge everywhere (stock at least as
  thick as the slice spacing, such as 5 mm stock on the 50 mm cube), nothing
  is relieved and the export is the same as without relief.
- **What is reported**: the relief actually cut. `measure.json`
  `slot_relief_circle_count` counts the discs cut out of the cut-sheet parts
  (0 for STL / OBJ, which carry no relief). When Slot relief is on but cuts
  nothing, the panel shows an orange note under Slot relief and the CLI
  prints it on stderr: "The slots are as wide as the slice spacing and merge
  into one cut, so Slot relief has no inside corners to cut." (or, with no
  tool, "Slot relief is on, but the tool diameter is 0, so no relief is
  cut."). The panel also says which Tool Dia. the relief is cut for, or asks
  for one when it is 0.
- STL / OBJ (plan-level slots) carry no relief.

### 3.6 Cut-sheet parts and labels

- Pieces smaller than 1 mm² or with an outer extent under 1.5 mm are dropped
  as uncuttable slivers before numbering.
- Labels are `Axis-slice` (`Z-6`), or `Axis-slice-piece` (`X-2-1`) when a
  slice has several surviving pieces. Slice numbers are 1-based within each
  family.
- Assembly step numbers run primary slices first (1 … N_primary), then
  secondary (N_primary + 1 …).
- Parts are shelf-packed onto sheets as for every cut-sheet mode
  (`docs/specs/ui-workflow.md` § Cut sheet).

### 3.7 Assembly steps

`Place primary_001` … then `Insert secondary_001` …, one step per slice. Each
primary step lists its family axis and position, the slot count, slot width
and slot angle; each secondary step says to mesh it through the matching
primary slots.

## 4. Data structures

- `InterlockedSlicePlan` — the two family plans (`StackedSlicePlan`: axis,
  extent, positions), material thickness, slot offset, slot width, slot angle,
  slot relief (on/off and the tool diameter), the notch-width override when
  on, and the model bounds. `sliceCount = N_p + N_s`,
  `slotCount = 2 · N_p · N_s`.
- Cut-sheet part — one closed outline loop with the slots spliced in, its
  relief discs, and its family, slice index and piece index.

## 5. Edge cases

- **Primary and secondary axes equal**: the secondary falls back to the first
  other axis (GUI) and the planner refuses equal axes after axis choice.
- **No bounds / non-positive thickness**: no plan.
- **More than 600 slices in total**: the GUI shows no plan.
- **Thin or concave sections**: a crossing position outside a part's extent
  carves no slot in that part; pieces split by the cross-section become
  separate labelled parts.
- **Disjoint shells** (two separate bodies): each slice yields several
  pieces, each its own part.

## 6. Output

| Output | Slots from |
|---|---|
| GUI cut sheet, Print, DXF / SVG / PDF / EPS (app and CLI) | cut-sheet part outlines, in millimetres, every part; DXF and EPS the right way up, one EPS per sheet (a ZIP when there are several) |
| STL / OBJ | plan contours extruded to the material thickness with plan-level slots cut out; objects `primary_NNN`, `secondary_NNN` |

See `docs/specs/exports-dxf.md`, `docs/specs/exports-vector.md` and
`docs/specs/exports-mesh.md` for the format details.

## 7. Worked example

50 mm cube centred on the origin, `--thickness 3` (the GUI default) and the
other CLI defaults (`--slot-clearance 0`, `--slot-angle 0`):

- All three extents tie, so the user's axes are kept: primary Z, secondary X.
- Each family: 10 slices at `−25 + 50(i + 0.5)/10` =
  `−22.5, −17.5, …, 22.5`.
- 20 slices, `2 × 10 × 10 = 200` plan-level slots, slot width `3 + 0 = 3` mm.
- Primary plan-level slots run over half the cube's depth (25 mm) from the
  open edge; secondary slots run over the other half.
- Cut sheet: 20 parts, `Z-1` … `Z-10` and `X-1` … `X-10`, each a 50 × 50 mm
  square with ten 3 mm slots on one edge and 2 mm of material between them.
- At the CLI's default `--thickness 5` the 5 mm slots fill the 5 mm spacing,
  so they merge and each part keeps only its unslotted half. With
  `--slot-relief --tool-diameter 4` nothing is relieved there
  (`slot_relief_circle_count` 0); at 3 mm with a 1 mm tool every slot's two
  inside corners are, `2 × 200 = 400` discs.

## 8. Known issues

- **Stock as thick as the slice spacing.** The slice count does not follow
  the thickness, so on a small model the slots merge and each part loses its
  slotted half (§ 7). Nothing warns about it; Distribute count is the fix.
- The cut sheet flags an interlocked part as an error only when relief discs
  cut a piece off; a slot that severs a thin part is not highlighted.
