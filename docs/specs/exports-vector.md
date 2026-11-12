# Vector Exports (SVG / PDF / EPS) — spec

How Refab Artist writes SVG, PDF and EPS cut files. DXF has its own spec
(`docs/specs/exports-dxf.md`); mesh formats are in
`docs/specs/exports-mesh.md`.

There are two writer families:

- **Cut-sheet writers** (SVG, PDF, and EPS for Interlocked, Curve Slices
  and Folded Panels) render the `CutSheetDocument` — the same packed, labelled,
  coloured sheets the GUI shows (`docs/specs/ui-workflow.md` § Cut sheet).
- **The row EPS writer** (Stacked, Radial) lays out the
  mode's plan contours (plus relief circles and dowel circles) in rows on its
  own. It differs from the cut sheet in layout, labels and colours.

Sources: `CutSheetDocumentExporter.swift`, `SvgExporter.swift` (the row
layout), `EpsExporter.swift`, `EpsExporter+PerSheet.swift`, and
`FlatPartExport.swift`, the writer table the app's Export command and the
headless CLI share.

---

## 1. Which writer is used

`FlatPartExport.writer(for:format:)` picks the writer; the app and the CLI
get the same file for the same plan.

| Format | Writer |
|---|---|
| SVG | cut-sheet writer, every flat-part mode |
| PDF | cut-sheet writer, every flat-part mode |
| EPS | cut-sheet writer for Interlocked, Curve Slices and Folded Panels; row EPS writer for Stacked and Radial; none for Inflatables. One file per sheet, a ZIP when there is more than one sheet |

3D Slices exports STL and OBJ only (`docs/specs/threeD.md`).

The app's Export dialog asks the writer how many EPS files it will write
(`FlatPartExport.epsFileCount`), so it offers `.zip` exactly when the writer
writes one.

## 2. Cut-sheet writers

### 2.1 Common rules

- Units: millimetres. Coordinates are the cut sheet's own, Y down.
- **Blue `#0000FF`**: everything to cut — part outlines, hole and slot loops,
  open cut fragments, dowel circles. **Red `#FF0000`**: scored guides and
  labels. Folded Panels fold lines are red, to score, or blue when Perforate
  is on, since the perforation dashes are cut. Stroke width 0.1 mm; no
  fills.
- Labels are centred on each part at the point farthest from any cut line,
  sized to fit there; the digits 6 and 9 are underlined.

### 2.2 SVG

- One SVG file. Width = sheet width; height = all sheets stacked with a 10 mm
  gap between them (`n · sheetHeight + (n − 1) · 10`).
- Each sheet is `<g id="sheet-N" transform="translate(0 y)">` holding a grey
  (`#888888`) sheet rectangle and one `<g id="part-<label>">` per part.
- Cut loops, holes, open cuts and guides are `<path>` elements (`M … L … Z`);
  dowel circles are `<circle>`; the label is `<text>` with Helvetica,
  `text-anchor="middle"`, `dominant-baseline="central"`, and an underline
  `<tspan>` for each 6 or 9.
- Numbers use `%.4f`.

### 2.3 PDF

- One page per sheet, page size = sheet size (points: mm × 72 / 25.4).
- Drawn with Core Graphics in a Y-down millimetre frame: blue cut strokes,
  red guides, red Helvetica labels drawn upright with the same 6/9 underline.
- Opens in Illustrator and other editors with the colours intact.

### 2.4 EPS (Interlocked, Curve Slices)

- One EPS per sheet, `%%BoundingBox` = the sheet in points, the right way up
  (a document point at `y` is drawn at `sheetHeight − y`). A document with no
  sheet size gets a page fitted to its parts plus the page margin.
- Grey sheet rectangle; blue cut loops, holes, open cuts and circles; red
  guides and red Helvetica labels centred on the label anchor, with 6 and 9
  underlined. Line width 0.1 mm.
- More than one sheet: a ZIP of `<name>-sheet-NN.eps`; one sheet: a plain
  `.eps` (`CutSheetDocumentExporter.writeEPS`).

## 3. Row EPS writer

### 3.1 Layout

The row EPS writer, and the DXF row writers (`docs/specs/exports-dxf.md`
§ 3), use one row layout:

- Parts are placed left to right in rows. A part that would cross the sheet's
  right margin starts a new row; a row that would cross the sheet's bottom
  margin starts a new sheet (sheets are stacked downwards in one page).
- Each part's footprint includes a 7 mm label strip under it. Parts are spaced
  by the part spacing (default 10 mm) inside the page margin (default
  10 mm).
- A part wider than the sheet's content width but no taller than it is
  rotated 90° to fit.
- A part that still does not fit marks the layout as overflowing; it is
  placed anyway.
- Default sheet: 600 × 300 mm. With no sheet size, the page grows to fit.
- Part names: `<family>_NNN` — `slice`, `primary` / `secondary`,
  `first_axis` / `radial`.
- Contents per part: the plan contours, then the plan-level slot loops
  (Interlocked, Curve), relief circles (Interlocked slot relief), and for
  Stacked with dowels four circles inset from the part's bounding-box
  corners. Every path is written as straight segments.

### 3.2 File

- `%!PS-Adobe-3.0 EPSF-3.0`, `%%Creator: Refab Artist`, `%%BoundingBox` in
  points, language level 2, one page per file.
- Black, line width 0.35, Helvetica 8 for labels; each segment is
  `newpath … moveto … lineto stroke`; circles use `arc`.
- Y is **not** flipped, so the drawing is the vertical mirror of the SVG and
  PDF pages.
- More than one sheet: a ZIP of `<name>-sheet-NN.eps`, each sheet
  re-origined to (0, 0) with its own border; parts are assigned to a sheet by
  their placement offset. One sheet: a plain `.eps`. With no sheet size, one
  EPS of the whole page holding every part.

## 4. Edge cases

- **No parts**: the file still has its header and sheet outline(s).
- **Open contours** (from broken meshes) are drawn as open paths.
- **Parts larger than the sheet**: cut sheet — the part gets its own sheet and
  is flagged as overflowing; EPS — placed at the current position and the
  layout marked as overflowing.
- **Labels** are ASCII part names (EPS) or the cut-sheet labels; PDF and EPS
  escape `\`, `(` and `)`, SVG escapes XML.

## 5. Known issues

- The row EPS writer (Stacked, Radial) lays out the plan
  differently from the cut sheet (rows versus shelf packing, black versus
  blue/red, `slice_001` versus `1`), so its EPS does not match the SVG and
  PDF, and is vertically mirrored relative to them.
- It places Stacked dowel holes at the part's bounding-box corners, not where
  the cut sheet places them.

## 6. Worked example

50 mm cube, `--mode stacked`, CLI defaults (thickness 5 mm, 600 × 300 mm
sheet, 10 mm margin and spacing): 10 slices, each a 50 × 50 mm square.

- **SVG** (`--format svg`): one 600 × 300 mm sheet, `<g id="sheet-1">`, and
  10 parts `part-1` … `part-10`. Part 1 spans x 10–60, y 10–60 with its label
  "1" centred at (35, 35); parts advance 60 mm, so parts 1–9 fill the first
  shelf (part 9 ends at x = 540) and part 10 starts the second shelf at
  y = 70.
- **EPS** (`--format eps`): the row layout, parts `slice_001` … `slice_010`.
  `slice_001` spans x 10–60, y 10–60, label at (10, 64); 9 parts fit before
  the right margin (x ≤ 590) and `slice_010` starts row 2 at
  y = 10 + 57 + 10 = 77. One sheet, so one EPS with a 1701 × 851 point
  bounding box.
