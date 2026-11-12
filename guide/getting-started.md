# Getting started

This page walks through one job from a model to a cut file. The same flow applies to every mode; the mode pages say what changes.

<!--
  Screenshots: none are included yet because the guide's pictures are drawn from
  the app's exported files, not captured from the window. To add real window
  screenshots, save them in guide/images/ (for example guide/images/app-window.png)
  and add an image line under the matching heading below.
-->

## 1. Open a model

Choose **File > Import Model...** (or **Load Sample Model** to try the app first). Refab Artist reads **STL** and **OBJ** files. The open dialog has an **Up axis** menu (Y, Z or X): choose the axis your file treats as up, so the model stands the right way round. Many modelling programs use Y.

The model appears in the 3D view and nothing is sliced yet. Loading happens in the background, so a large scan will not freeze the window.

Drag to orbit, scroll to zoom. The view cube and the toolbar on the side of the view give you orbit, pan, zoom and fit.

## 2. Check the size

STL and OBJ files carry no units, so Refab Artist guesses from the model's size and shows its guess (mm, cm, m or inches) in the **Object** tab of the right inspector, under **Object Size**. If the model is the wrong size, change the unit, or type the real height, width or length. **Uniform Scale** is on by default, so the other two follow. **Reset Size** puts it back.

The same panel has a rotate row for X, Y and Z. A rotation here is baked into the model before slicing, so use it to stand the model up the way you want it built.

!!! tip
    Everything downstream is in real units, so this is the step that decides whether your parts come out at the size you expect. Check it before you slice.

## 3. Pick a construction technique

Under **Construction Technique** in the left rail, choose how the model should be built:

| If you want... | Choose |
|---|---|
| Layers you glue up in a stack | [Stacked](stacked.md) |
| A grid of slotted planks that slide together | [Interlocked](interlocked.md) |
| Rings and fins around a centre | [Radial](radial.md) |
| Slices with ribs along a curve | [Curve](curve.md) |
| A folded shell from card or thin sheet | [Folded](folded.md) |
| A layered mesh to 3D print | [3D Slices](3d-slices.md) |
| Lattices, supports or a skin to print | [Structures](structures.md) |
| A model split to fit your printer | [Partition](partition.md) |
| A casting mold | [MotherMold](mothermold.md) |

Nothing is sliced until you have chosen a technique. Choosing one reveals the sections below it.

## 4. Set your material

**Manufacturing Settings** describe the sheet you are cutting from:

- **Material:** a preset (Cardboard 3 mm, Plywood 3 mm, Plywood 6 mm, Acrylic 3 mm), a standard sheet size (A4, Letter, B-series and P-series sizes, and so on), or a material you saved yourself. Picking one fills in thickness and slot offset; the sheet-size presets also fill in the sheet size and margin, and set the thickness to about 4.5 mm, so check **Thickness** after choosing one. If you then edit a value, the label switches to **Custom**; the preset itself is not changed.
- **Thickness:** the real thickness of your stock. Measure it with calipers. Slice spacing and slot widths come from it.
- **Slot Offset:** extra width added to every slot so parts fit after your cutter removes its kerf. The presets give a starting point; you will tune it with a test cut (see [Cutting and fit](cutting-and-fit.md)).
- **Tool Dia.:** the diameter of a router bit, used for the relief cut in the inside corners of slots (Interlocked and Radial). Leave it at 0 for a laser. It is greyed out while the mode's relief is off (Interlocked **Slot relief** off, Radial **Relief Type** Square).
- **Sheet W**, **Sheet H** and **Margin:** the size of one sheet of your stock and the blank border kept round its edge. Parts are packed onto sheets of this size. The starting sheet is 600 by 300 mm with a 10 mm margin.

Values are stored in millimetres. The **Units** switch (mm or in) changes only what you see and type.

A row that the chosen technique never uses is left out, and one that another setting overrides is greyed out with a short note saying why. 3D Slices builds a layered mesh, so it has no Manufacturing Settings at all.

## 5. Set the technique's own settings

**Technique Settings** hold the controls specific to the mode: how many slices, which axis, relief type, joint type and so on. Each mode page lists the ones that matter.

**Slice Direction** is its own section below Technique Settings. It tilts the direction the model is cut along: it aims the cut and does not turn the model. Folded has no Slice Direction.

## 6. Slice

Press **Slice** (or **Generate**, for the modes that build a mesh). Changing a setting does not recompute anything until you press it again, so you can set several things and slice once. The button reads **Re-slice** afterwards.

## 7. Check the cut-sheet preview

When slicing finishes you will see the **3D view** with the parts in place and the **cut sheet** showing how the parts are laid out. The header shows how many sheets and parts there are.

- **Blue outlines** are cut edges.
- **Red lines** are scored guides: where the next piece will sit.
- **Red numbers** label each part, matching the assembly steps.
- A part filled **red** has a problem (difficult or impossible to build); a part filled **blue** is a detached piece that would fall off. Look at the **Issues** tab.

Click a sheet to see it larger. Use the **View** menu to show the 3D view, the sheet, or both side by side.

## 8. Step through the assembly

Once there are parts, the **Assembly** panel lists one step per part. The previous and next arrows walk through them: the current part is highlighted in the 3D view and outlined on the cut sheet, and parts still to come show as faint ghosts, so you can watch the model grow. Click a part on the sheet to jump to its step. The **Assembly** panel also has a button to clear the highlight and one to export the assembly guide.

## 9. Export

Choose **File > Export Current Output...** for the cut sheets (DXF, SVG, PDF or EPS) or the parts as a mesh (STL or OBJ). The mesh modes (3D Slices, Structures, Partition and MotherMold) offer STL and OBJ only. **Export Assembly Guide...** writes a printable guide, and **Print...** sends the sheets to a printer. See [Exporting](exporting.md) for what each format is for.

## 10. Save your project

**File > Save Project...** saves a `.refabartist` file holding the model and every setting, so you can come back and change the material or the slice count later. **Open Project...** brings it back.

## Before you cut

Do a test cut. Cut a small piece in your own stock, check the joints and adjust **Slot Offset**. [Cutting and fit](cutting-and-fit.md) has the steps, and [Safety](safety.md) covers the machine.
