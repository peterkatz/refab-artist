# Exporting

Once a model is sliced, **File > Export Current Output...** writes the file. Which formats are on offer depends on the mode.

## Cut sheets (flat-part modes)

Stacked, Interlocked, Radial, Curve and Folded write cut sheets. Every format is in millimetres. (Inflatables, the experimental mode, writes DXF, SVG and PDF.)

| Format | Use it for |
|---|---|
| **DXF** | Most laser and CNC software. Each part is on its own layer (where a part has scored guides they go on a layer of their own), and each sheet has an outline layer. |
| **SVG** | Vector editors and many laser programs. One file, with the sheets stacked down the page. |
| **PDF** | Viewing, printing, and editors such as Illustrator. One page per sheet, page size equal to the sheet. |
| **EPS** | Older workflows. One file per sheet, in a ZIP when there is more than one sheet. |

Colour carries meaning in SVG and PDF cut sheets (and in EPS for Interlocked, Curve and Folded): **blue** lines are cuts, **red** lines are scored guides and labels. Line width is 0.1 mm. In Folded, fold lines are red when scored and blue when perforated, since the perforation is cut.

The labels are the part numbers shown in the app, and they match the assembly steps.

!!! tip "Use SVG, PDF or DXF to cut"
    For Stacked and Radial, the EPS writer lays the parts out in rows with its own numbering, and is vertically mirrored compared with the SVG and PDF. It is fine for a quick look but use SVG, PDF or DXF to cut.

### Sheet layout

Parts are packed onto sheets of the size you set in Manufacturing Settings (**Sheet W** and **Sheet H**), with a **Margin** round each sheet and a **Spacing** gap between parts (10 mm each by default; the Export layout section has the same Margin and Spacing). Their order on a sheet carries no meaning. A part larger than the sheet is flagged and placed on its own sheet.

### Opening the file in your cutter's software

- Import at 1:1 scale. Do not resize the drawing.
- Do not add extra kerf compensation for the first run; Slot Offset in Refab Artist already allows for it.
- Map blue to cut and red to score or engrave.

## Parts as meshes (STL and OBJ)

Every mode can write its parts as a mesh.

- **STL** is plain-text (ASCII): one solid holding every part.
- **OBJ** has one named object per part (`slice_001`, `primary_003`, and so on) and notes its units as millimetres.

For the flat-part modes, the mesh is a way to **check the assembly**: each cut part extruded to its thickness and put back in place, so you can inspect the finished model in a 3D viewer before you cut. 3D Slices, Structures, Partition and MotherMold write meshes as their real output.

Under a tilted Slice Direction the mesh is written in the tilted frame, so the whole assembly comes out turned by the tilt. The 3D view and the cut sheets are not affected.

Partition and MotherMold can also package their pieces as a ZIP of separate files, a single OBJ with named parts, or all the parts laid out on one plate, and write an assembly map.

## Assembly guide

**File > Export Assembly Guide...** writes a printable text guide: the model, the mode, your material settings, and every assembly step. It is the thing to have next to you while you build.

## Print

**File > Print...** sends the cut sheets to a printer, which is handy for paper templates or hand cutting. It is available once a cut sheet is ready.

## Projects

**File > Save Project...** writes a `.refabartist` file with the model and every setting. **File > Open Project...** reads it back. Projects are for you to resume work or share a setup; they are not a cutting format.

## Headless export

The same app can export without opening a window, from Terminal, for scripts and batch jobs. The [README](https://github.com/peterkatz/refab-artist#build-from-source) shows an example, and `docs/development.md` in the repository lists the modes and options. The app opens its window when run without those options.
