# UI / Workflow Spec

How Refab Artist's window is organised and the order a user works through it.
This is the reference for UI work: new controls go into the section and
position described here, and a change to the layout updates this document.

## Layout

- **Left rail** — the whole build flow, top to bottom:
  1. **Actions** — import a model, load the sample model, open and save a
     project.
  2. **Construction Technique** — a chooser listing the construction modes
     (Stacked Slices, Interlocked Slices, Curve, Radial Slices, Folded Panels,
     3D Slices, plus the mesh modes). Choosing a technique reveals the
     sections below it. Nothing is sliced before a technique is chosen.
  3. **Manufacturing Settings** — stock preset, material thickness, slot
     offset (kerf), tool diameter (Tool Dia., the one tool diameter for slot
     relief in every mode), sheet width and height, page margin. Values are
     stored in mm; the panel has an mm/in display toggle. A row the chosen
     technique never reads is left out, and one another setting overrides is
     greyed out with a caption (`docs/specs/material-presets.md` § 2.0).
     3D Slices, a layered mesh to print, has no Manufacturing Settings.
  4. **Technique Settings** — the chosen technique's parameters (slice
     distribution, notch and relief options, Folded detail, and so on).
  5. **Slice Direction** — the axis and tilt the slices are cut along (every
     technique except Folded Panels). This aims the cut; it does not rotate the
     model. Under a tilt the model is turned into the slicing frame for
     slicing (`planningModel`; the CLI's `--slice-tilt-first` and
     `--slice-tilt-second`), and everything is cut from that turned model:
     the plan, the viewport's slice solids (turned back onto the model), the
     cut sheet, every vector export and the STL / OBJ meshes (written in the
     slicing frame), in the app and the CLI alike. The CLI's part frames
     (`--part-frames`) are turned back onto the model as imported.
  6. **Dowels** — Stacked Slices only, after Slice Direction so the cut
     direction is chosen before rods are placed (see § Dowels).
  7. **Slice** — an explicit Slice / Re-slice button. Settings changes do not
     recompute anything until it is pressed.
  8. **Assembly** and **Export** — shown once the model has been sliced.
- **Viewport** — fills the centre. Overlays: a view-orientation cube and a
  vertical view toolbar (orbit / pan / zoom / fit).
- **Right inspector** — tabs:
  - **Object** — **Object Size** (units, the current post-transform height /
    width / length as editable fields, a Uniform Scale toggle that is on by
    default, a Reset Size button, and an X/Y/Z rotate row that bakes a
    rotation into the mesh before slicing) and **Modify Form** (whole-model
    mesh operations before slicing).
  - **Viewport** — viewport look (material style, colour, input-device
    tuning).
  - **Issues** — part errors and mesh-health problems.
  - **Stats** — mesh statistics (format, vertices, faces, bounds, preflight
    checks: degenerate faces, open edges, non-manifold edges, duplicates).

Model loading and slicing run off the main thread with a loading indicator;
the import unit is picked automatically from the model's size and lands in
Object Size, where it can be changed.

## Workflow sequence

1. Open a model. It shows in the viewport; nothing is sliced.
2. Pick a **Construction Technique**. Its settings appear.
3. (Optional) adjust Manufacturing Settings, Object Size, Modify Form,
   Technique Settings, Slice Direction and Dowels.
4. Press **Slice**. The cut sheet, assembly steps and export controls follow.

## Cut sheet

The cut-sheet view and the cut-sheet exports draw from the same document
(`CutSheetDocument`).

### Labels

- A slice that falls into several disconnected pieces gets one labelled part
  per piece.
- Stacked labels carry no axis: `21`, or `14-1`, `6-2` (slice-piece) when a
  slice has several pieces. Two-family modes prefix the axis letter: `Z-6`,
  `Y-2-1`.
- Labels are red, sized to the part and centred. The digits 6 and 9 carry an
  underline so they are not confused when a part is rotated.
- Exported plans (PDF / DXF / SVG) carry the same numbering.

### Colours

On screen:

- **Blue outlines** — cut edges, outside and inside the part.
- **Red lines** — scored guides: where the next piece sits during assembly.
- **Red-filled parts** — parts with an error (difficult or impossible to
  build).
- **Blue-filled parts** — detached pieces that would fall off.
- Normal parts render near-white on a grey sheet. Each sheet's number is drawn
  large at its top-left, and the panel header reads "Sheets N / Parts M".

Exported plans use two stroke colours: blue for cut lines, red for labels,
scored guides and biscuit marks. White background, no fills.

### Layout

Parts are packed to use as much of each sheet as possible; their order on a
sheet carries no meaning. Clicking a sheet opens a magnified view of it.

### Scored assembly guides

Inside each stacked part, red scored lines trace the next slice's outline
wherever it lands at least one slice depth inside this part
(`docs/specs/stacked.md` § 3.5, built by `StackedAssemblyGuides`), so the
next layer can be lined up while gluing.

## Dowels

Dowel editing happens in the 3D view:

- **Dowel holes** turns dowels on. **Shape** picks the rod cross-section:
  Square, Pencil (hexagonal), Round, Cross, Horizontal Slot, Vertical Slot.
  **Diameter** is the overall size for every shape. Pencil is a regular
  hexagon measured across flats; Cross arms and Slot widths are d/3.
- **Placement: Automatic | Manual** is a reversible segmented control. Manual
  positions are kept when switching to Automatic, so switching back restores
  them. Editing rods in the 3D view switches to Manual by itself.
- **Count** sets how many rods Automatic stands. Placement is coverage-scored:
  rods go where they pass through the most slices' material with edge
  clearance, then greedy farthest-separation; spacing relaxes if the model
  cannot fit the count.
- **Edit placement**: while on, clicking the sliced model adds a rod, clicking
  a rod selects it (orange), dragging moves it through the whole stack, and
  Delete or Control-click removes it. Clicks away from rods still orbit the
  camera.
- Each rod carries a circular marker sphere at its top end, steel-blue
  normally and orange when selected. Rods always pass through the whole
  stack; every slice whose material covers a rod gets the hole, so moving a
  dowel moves it through every piece at once.

## Radial Slices settings

A radial job is rings plus fins: a stack of disk slices along the first axis,
plus `Radial (Count)` fins fanned around it, notched into each other at every
crossing (see `docs/specs/radial.md`). The Technique Settings for Radial are:

- **Method** — By Count | By Distance, and the matching **1st Axis** value
  (ring count, or ring spacing in mm).
- **Radial (Count)** — fin count.
- **Slot Offset**, **Notch Angle** (disabled with a hint: notches are cut
  square).
- **Relief Type** — Square, Horizontal, Vertical, Dog Bone. The relief is cut
  for **Tool Dia.** in Manufacturing Settings (greyed out there for Square);
  under Relief Type the panel says which Tool Dia. it uses, or asks for one
  when it is 0.

## Folded Panels: dense meshes

Dense meshes are not refused. Folded Panels builds a simplified shape around
the object and lays that out: the **Detail** slider (12–2000 faces, default
250; also editable as Vertex Count) sets the polygon budget, and models denser
than the budget are sealed, repaired and simplified with Manifold off the main
thread before folding, so every remaining face becomes a panel
(`docs/specs/folded.md` § 3.0). Only a 2,000,000-face interactive cap
remains.
