# Cutting and fit

Refab Artist's checks show that an exported file is consistent and cuttable: every part fits its sheet, parts do not overlap, every cut is a closed shape, and slots are as wide as the stock. They cannot show that your parts fit **your** material. Kerf (the width of material your cutter removes), real stock thickness and the machine all matter, and no physical cut test has been recorded for 0.1.0. So cut a small test piece first.

## Kerf and Slot Offset

A slot is cut `thickness + Slot Offset` wide. **Slot Offset** is the extra width that makes the slot fit a piece of your stock after the cutter's own kerf is taken into account. Refab Artist applies it once, to the slots; do not also add kerf compensation in your cutter's software for the first run.

- **Too loose:** lower Slot Offset.
- **Won't go together, or cracks the stock:** raise it.
- **Interlocked and Curve:** if you type a **Notch width**, it replaces thickness plus offset, and Slot Offset is not used.
- **Router cutters:** a round bit cannot cut a square inside corner. Set **Tool Dia.** and a relief type (Interlocked Slot relief, Radial Relief Type) so the corners are cleared.

The material presets set a starting Slot Offset: Cardboard 3 mm 0.15 mm, Plywood 3 mm 0.10 mm, Plywood 6 mm 0.15 mm and Acrylic 3 mm 0.20 mm. They are starting points, not promises. The presets for standard sheet sizes use 0.254 mm (0.01 in).

## Measure your stock

Use calipers, not the label. Plywood sold as "3 mm" is often a little more or less. Measure at several places, and put the real figure in **Thickness**. If your stock matches no preset, pick the nearest one and edit Thickness; the label switches to Custom. You can save the result with **Save Current as Material...** so it is a pick next time.

## A test cut

Do this once for each material and machine:

1. Pick a small, quick model. A 50 mm cube in Interlocked works well: it makes real slots, and it is small enough for a quick, low-risk job.
2. Set the material to your stock, using the measured thickness. Start with the preset's Slot Offset (for example 0.10 mm for 3 mm plywood).
3. Export as DXF, SVG or PDF and import into your cutter software at 1:1 scale. Do not resize the drawing, and add no further kerf compensation.
4. Cut the whole piece from one sheet. Keep every part, even ones that cut badly, until you have finished.
5. Before assembly, measure the sheet thickness again and measure at least three slots on different parts.
6. Dry-fit the parts by hand. Note the fit: too loose, hand-fit, tight, or impossible. Note any cracking, delamination, parts that needed sanding, or slots that look wrong, and which part or slot is worst.
7. Adjust **one thing at a time**, usually Slot Offset, and cut again.

The fit is right when the piece goes together by hand without cracking, holds its shape under light handling, and needs no sanding or cleanup of the slots.

!!! tip "Keep notes"
    Write down your machine, power, speed, passes and the Slot Offset that worked. Save it as a material in Refab Artist and you will not need to do this again.

## Other things to check

- **Scale:** measure a finished part against the drawing. If it is off, the file was imported at the wrong scale or the model's size was wrong. See [Getting started](getting-started.md).
- **Grain and strength:** thin necks between slots are weak. Curve cuts no more ribs than leave a web at least as thick as the stock between two slots, but wood grain and brittle materials can still break, so handle thin parts gently.
- **Folded** needs stock that bends at the creases.
