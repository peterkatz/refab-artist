# DXF Export — spec

How Refab Artist writes DXF cut files. SVG, PDF and EPS are in
`docs/specs/exports-vector.md`; mesh formats are in
`docs/specs/exports-mesh.md`.

There are three writer families:

- **Row writers** (`DxfExporter.write(contours:)`, `write(radial:)`) lay
  out one mode's parts in rows, one layer per part.
- **The cut-sheet writer** (`CutSheetDocumentExporter.writeDXF`) renders the
  `CutSheetDocument`: the packed, labelled sheets the GUI shows
  (`docs/specs/ui-workflow.md` § Cut sheet).
- **The Inflatables writer** (`InflatablesDXFExporter`) renders the
  Inflatables cut sheet with named, coloured layers for cuts, seams and
  labels.

Sources: `DxfExporter.swift`, `CutSheetDocumentExporter.swift`,
`Inflatables/InflatablesDXFExporter.swift`, and `FlatPartExport.swift`, the
writer table the app's Export command and the headless CLI share.

---

## 1. Which writer is used

`FlatPartExport.writer(for:format:)` picks the writer, so the app and the
CLI write the same file for the same plan:

| Mode | DXF writer |
|---|---|
| Stacked | row writer, with dowel holes when dowels are on (the CLI has no dowel options) |
| Interlocked | cut-sheet writer |
| Radial | row writer |
| Curve | cut-sheet writer |
| Folded Panels | cut-sheet writer |
| Inflatables | Inflatables writer |
| 3D Slices | none: mesh formats only, and the CLI refuses DXF |

A Radial plan with no fins (`n_radial = 0`) is an Interlocked plan and is
exported as Interlocked, through the cut-sheet writer.

## 2. File structure (all writers)

- ASCII DXF: one group code and one value per line, `\n` line endings,
  UTF-8. Numbers use `%.6f`.
- The row and cut-sheet writers write only an `ENTITIES` section, then
  `EOF`. The Inflatables writer adds a `TABLES` section with a `LAYER` table
  first (§ 5).
- Entities:
  - `LINE` (`8` layer, `10/20/30` start, `11/21/31` end). Every outline,
    slot, hole loop and sheet rectangle is written as consecutive `LINE`
    segments; there are no `POLYLINE` or `LWPOLYLINE` entities.
  - `CIRCLE` (`10/20/30` centre, `40` radius) for round dowel holes.
  - `TEXT` (`10/20/30` insertion point, `40` height, `1` text) for part
    labels, where the writer has them.
- Z is always 0.
- Units are millimetres. No writer sets `$INSUNITS`, so a program that
  asks for the drawing unit should be told millimetres.
- Row writers use the layout's own coordinates: rows and sheets advance in
  +Y. The cut-sheet and Inflatables writers turn their sheets the right way
  up (§ 4, § 5).

## 3. Row writers

### 3.1 Layout

The row writers share the EPS writer's row layout
(`docs/specs/exports-vector.md` § 3.1):

- Parts are placed left to right in rows; a part that would cross the
  sheet's right margin starts a new row, a row that would cross the sheet's
  bottom margin starts a new sheet.
- Each part's footprint includes a 7 mm label strip. Parts are spaced by the
  part spacing (default 10 mm) inside the page margin (default 10 mm).
- A part wider than the sheet's content width but no taller than it is
  rotated 90° to fit; a part that still does not fit is placed anyway.
- With a sheet size, one rectangle per sheet: `sheet_boundary`,
  `sheet_boundary_2`, … Sheets are stacked edge to edge in +Y (sheet *n*
  starts at `(n − 1) · sheetHeight`).

### 3.2 Parts and layers

Each part is one layer, named after its family and 1-based index:

| Mode | Layers |
|---|---|
| Stacked | `slice_NNN` |
| Radial | `first_axis_NNN` (rings), `radial_NNN` (fins) |

A layer holds:

- the part's contours — a slice can hold several pieces and the voids
  inside them;
- Stacked with dowels: the dowel holes. Dowel positions are shared by
  the whole stack, so a rod threads every slice that covers it; a slice gets
  the holes whose centre lies inside it. Round dowels are `CIRCLE`s; other
  shapes are closed outlines.
- a `TEXT` label equal to the layer name, 4 mm high, at the part's
  bottom-left x and 3 mm past its maximum y.

Radial rings and fins come from the same part builder as the cut sheet; a
part's holes are drawn on its layer with its outline. With `--part-frames
<file>` the CLI also writes, for every layer, the affine map from the part's
coordinates in this DXF to model coordinates
(`DxfExporter.writePartFrames(radial:)`, the same JSON as the cut sheet's
part frames, in the same model coordinates, § 4), so a checker can put the
rings and fins back in the model.

### 3.3 Folded Panels

Folded Panels has no row writer: its nets are written by the cut-sheet
writer (§ 4).

## 4. Cut-sheet writer

- The cut sheet's coordinates run down the sheet, DXF's up, so each sheet is
  turned the right way up: a sheet point `(x, y)` on sheet *n* is written at
  `(x, top_n − y)` with `top_n = sheetHeight − (n − 1) · (sheetHeight + 10)`
  (`CutSheetDocumentExporter.dxfY`). Sheet 1 spans 0 to the sheet height
  and each further sheet lies 10 mm below the one before, as in the preview.
  With a sheet size each sheet gets a rectangle on `sheet_boundary` /
  `sheet_boundary_N`. The part frames (`--part-frames`) map these DXF
  coordinates to the model as imported. Under a Slice Direction tilt the
  parts are cut from the model turned into the slicing frame
  (`docs/specs/ui-workflow.md`), and the frames undo that turn
  (`MeshScaler.unrotating`): a checker given the model file can put the
  parts back without turning it.
- Each part is a layer named after its cut-sheet label (`Z-1`, `X-3-2`,
  `C-2`, …). On it: the cut loops and hole loops as closed `LINE` chains,
  open cut fragments as open chains, and round holes as `CIRCLE`s. Slots and
  slot relief are already cut into the part outline
  (`docs/specs/interlocked.md` § 3.4–3.5).
- Scored guide lines go on `<label>_guide`.
- Folded Panels: each net is one part, its joint holes (slots, pin and
  lacing holes) on its layer with its outline. Its fold lines go on
  `fold-line`, one layer for every net: whole fold lines to score, or, with
  Perforate on, the perforation dashes to cut. With `--part-frames` the
  frames file also lists, under `folds`, every net's panels: each panel's
  map from DXF to model coordinates, the direction from its outside face
  into its stock, its outline and the joint features standing out of it,
  and which panels each fold joins (`docs/specs/folded.md` § 6), so a
  checker can fold the net back up.
- Labels are not written: the cut-sheet DXF has no `TEXT`.

## 5. Inflatables writer

- `TABLES` → `LAYER` table with five layers, linetype `CONTINUOUS`:

  | Layer | Colour (ACI) | Contents |
  |---|---|---|
  | `CUT` | 1 red | panel outlines, holes, open cuts, circles |
  | `SEAM` | 5 blue | seam lines |
  | `FOLD_REG` | 3 green | sheet rectangles |
  | `BAFFLE_ATTACH` | 4 cyan | (declared, no entities) |
  | `LABEL` | 6 magenta | one `TEXT` per panel |

- Every entity also carries its colour (code `62`).
- Each sheet is turned the right way up as in the cut-sheet writer (§ 4): a
  cut-sheet point at `y` on sheet *n* is written at
  `sheetHeight − (n − 1) · (sheetHeight + 10) − y`, so sheet 1 spans 0 to
  the sheet height and each further sheet lies 10 mm below the one before,
  as in the preview. Lines, circles and labels all follow. Each label sits
  at the cut sheet's label anchor, sized like the cut-sheet label (at least
  1.5 mm), style `STANDARD`.

## 6. Edge cases

- **No parts**: the file still has its `ENTITIES` section and, with a sheet
  size, its sheet rectangle(s).
- **Open contours** (from broken meshes) are written as open `LINE` chains.
- **Parts larger than the sheet**: row writers rotate the part if that fits,
  otherwise place it and continue; the cut sheet gives it its own sheet and
  flags it as overflowing.
- **Self-intersecting outlines** are written as generated. The functional
  gate (`docs/functional-gate.md`) reports them.
- **Layer names** are part labels and are ASCII.

## 7. Known issues

- The row writers (Stacked, Radial) lay parts out in rows with their own
  labels, so their DXF does not match the cut sheet the app shows, unlike
  Interlocked, Curve and Folded Panels.
- The cut-sheet DXF carries no labels.

## 8. Worked example

50 mm cube, `--mode stacked --format dxf`, CLI defaults (thickness 5 mm,
600 × 300 mm sheet, 10 mm margin and spacing):

- 10 slices, each a 50 × 50 mm square, so 10 layers `slice_001` …
  `slice_010`, each with 4 `LINE`s and one `TEXT`.
- `slice_001` spans x 10–60, y 10–60; its label is at (10, 63), 4 mm high.
  Parts advance 60 mm, so 9 fit before the right margin; `slice_010` starts
  the second row at y = 77.
- One `sheet_boundary` rectangle, (0, 0)–(600, 300): 44 `LINE`s in all.
