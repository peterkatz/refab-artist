# Assembly Steps — spec

How Refab Artist orders the parts of a sliced model for assembly, how the
Assembly panel steps through them, how a step links to its parts on the cut
sheet and in the 3D view, and what the assembly guide export and the
assembly audit contain.

Sources: `AssemblySteps.swift`, `AssemblyStepNavigation.swift`,
`AssemblyStepHighlight.swift`, `AssemblyStepPartLabel.swift`,
`AssemblyGuideExporter.swift`, `AssemblyAuditCommand.swift`,
`AssemblyStepsPanel` in `ContentView.swift`, `CutSheetDocument.swift`
(`stepIndex`).

---

## 1. Scope

Assembly steps exist for the slicing modes: Stacked, Interlocked, Radial,
Curve, 3D Slices and Folded Panels. Inflatables, Structures, Partition and
MotherMold have their own build guidance and no step list here.

A step is `(index, title, detail)`. Indices are 1-based and count every
slice the plan places, in order. The last word of the title is the step's
part name (`slice_003`, `primary_002`, …).

## 2. Step order per mode

| Mode | Steps, in order | Title / detail |
|---|---|---|
| Stacked | one per slice, in slice order | `Place slice_NNN` / "Stack along <axis> at p mm." |
| Interlocked | primary slices, then secondary slices | `Place primary_NNN` / family axis, position, slot count, slot width, slot angle; `Insert secondary_NNN` / family axis, position, "mesh through matching primary slots" |
| Radial | rings bottom to top, then fins | `Place first_axis_NNN` / ring axis and position, "receives the radial fin notches"; `Insert radial_NNN` / fin angle in degrees |
| Radial, zero fins | as Interlocked | the Interlocked fallback (`docs/specs/radial.md` § 5.1) |
| Curve | first-axis ribs, then curve ribs | `Place first_axis_NNN` / axis and position, "receives curve-rib slots"; `Insert curve_NNN` / sample point and spline point count |
| 3D Slices | the bands it builds, bottom up | `Place three_d_NNN` / "Z band at p mm." The bands come from the Z family only, so the X and Y families have no steps; each step keeps the index counted through X, Y and Z, which § 5 maps to its band |
| Folded Panels | one per panel the nets hold | `Fold folded_panel_NNN` / source triangle, "align shared edges before joining" |

`NNN` is the 1-based index within its family, zero-padded to three digits.
Positions print in millimetres.

Only the steps of slices the export holds parts of are listed
(`AssemblyStepPlanner.exported`). In Stacked, Interlocked, Radial and Curve
the app builds the cut sheet off the main thread (also when the export
format is a mesh, for this alone) and keeps the steps some part on it
carries (`stepIndex`, § 4): a Curve rib left out whole, a Radial ring no fin
reaches (the simple chair's five leg rings), a slice through nothing has no
step. The other steps keep their indices, so every part keeps its step;
until the cut sheet is built, every planned step is shown. Folded Panels
leaves out the steps of the panels the stock leaves out
(`FoldedPanelPlan.leftOutPanels`, `docs/specs/folded.md`); the others keep
their indices (panel index + 1).

The order is a fixed family-by-family sequence; there is no dependency
analysis. It matches the physical build for the two-family modes because
the first family's slots face up and the second family drops into them.

## 3. Navigation

The Assembly panel shows the step count, a material render picker for the
slice solids (Cardboard / Plywood / Plastic), and a pager:

- **Previous / Next** move one step and stop at the ends. From no selection,
  either goes to the first step.
- The counter reads `i / n`, "Select step" when nothing is selected, or
  `0 / 0` when there are no steps.
- **Clear** removes the selection.
- A selection that no longer exists after the steps change (for example
  after re-slicing) is dropped.

Below the pager, one line names the parts for the selected step and where to
find them: "Place part 13-1 (sheet 2)." — every cut-sheet part whose
`stepIndex` equals the step's index, with its sheet number. If no part
matches, the step title is shown. With no selection the line explains the
pager.

## 4. Linking steps to parts

Every cut-sheet part carries a `stepIndex`:

| Mode | `stepIndex` |
|---|---|
| Stacked | slice index + 1 |
| Interlocked | primary: slice index + 1; secondary: N_primary + slice index + 1 |
| Radial | rings: ring index + 1; fins: N_rings + fin index + 1 |
| Curve | first-axis ribs: rib index + 1; curve ribs: N_first + rib index + 1 |
| Folded Panels | net index + 1 |

All pieces of one slice share its `stepIndex`. Clicking a part on the cut
sheet selects its step; selecting a step outlines its parts on the sheet.

## 5. 3D view

Selecting a step highlights its solid in the viewport, and every solid after
it in build order renders as a faint ghost, so stepping through shows the
model growing piece by piece. The step maps to a solid as follows:

- Stacked: slice `index − 1` of the single family.
- Interlocked and 3D Slices: the families in order; the index is counted
  through the first family, then the next.
- Radial: rings first, then fins (fin count as § 2).
- Curve: first-axis ribs, then curve ribs.
- Folded Panels: panel `index − 1`.

## 6. Assembly guide export

**Export assembly guide** writes a plain-text file:

```
Refab Artist Assembly Guide

Model: <file name>
Mode: <mode label>
Material thickness: <t> mm      (3D Slices: Slice depth, below)
<the mode's settings, below>
Step count: <n>

Steps

1. <title>
   <detail>
2. ...
```

The steps are numbered 1, 2, … in order in the guide, whatever their
indices.

After the thickness the guide lists only the settings the mode cuts with:

| Mode | Lines |
|---|---|
| Stacked | `Dowels: <d> mm diameter, <inset> mm inset` (or `Dowels: disabled`) |
| Interlocked | `Slot clearance: <offset> mm` (or `Notch width: <w> mm` while it is on), `Slot angle: <angle> degrees`, and `Slot relief: dog bone, <D> mm tool` when relief is cut |
| Radial | `Slot clearance: <offset> mm`, and `Slot relief: <Relief Type>, <D> mm tool` when relief is cut |
| Curve | `Slot clearance: <offset> mm` (or `Notch width: <w> mm` while it is on) |
| Folded | `Slot clearance: <offset> mm`, except for Joint Type Laced, Ticked and None, which cut no slot |
| 3D Slices | nothing more |

3D Slices builds a layered mesh with no stock, so in place of the material
thickness its guide prints the spacing its bands are cut by:
`Slice depth: <d> mm`, or `Distribute count: <n> layers` while Distribute
count overrides the depth.

Only Interlocked has a slot angle; Radial and Curve cut their joints square.
`<D>` is Tool Dia. from Manufacturing Settings.

With no steps the list is replaced by "No assembly steps available."

## 7. Assembly Reference

The Assembly Reference button (shown when a cut sheet exists) opens a sheet
viewer with pan, zoom and fit. It outlines the parts of the selected step and
lets the user pick a step by clicking a part.

## 8. Assembly audit

`RefabArtist --assembly-audit --mode <mode> --fixture <mesh>` builds the
same plans and the same cut sheet the app shows (defaults: thickness 3 mm,
axis Z, secondary axis X, 600 mm sheet width) and prints one JSON object:

| Field | Meaning |
|---|---|
| `sheets`, `parts` | cut-sheet sheet and part counts |
| `severed`, `severedLabels` | parts flagged as errors: a slot or notch cuts through the part |
| `detached`, `detachedLabels` | parts flagged as detached from the build |
| `overflow` | parts larger than the sheet |
| `assemblable` | true when there are parts and none are severed, detached or overflowing |

`--dump-cutsheet <path>` also writes every placed part's cut loops and open
cuts as text. `scripts/assembly_gate.py` runs the audit over the fixture
corpus. These are necessary conditions for an assemblable result, not proof
of one: the audit does not check that joints pair up or that slots are wide
enough for the material.

## 9. Known issues

- Folded Panels counts steps per panel but numbers cut-sheet parts per net.
