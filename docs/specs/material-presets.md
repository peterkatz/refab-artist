# Material Presets — spec

What the **Material** picker in Manufacturing Settings does, which fields a
preset sets, and how the slot offset (kerf) reaches the cut geometry.

Sources: `MaterialPreset.swift` (material presets), `CustomMaterial.swift`
(built-in sheet presets and saved materials), `ManufacturingSettingsPanel` in
`ContentView.swift` (picker behaviour).

---

## 1. Why presets exist

The parameters that matter most for a physical cut — material thickness,
slot offset, sheet size — depend on what the user is cutting and on which
machine. Most users know "plywood, 6 mm, laser", not their cutter's kerf to
three decimals. A preset maps that description onto the manufacturing fields;
the user can then adjust any individual value.

Presets are **defaults for parameters, not locks on them.**

---

## 2. Manufacturing fields

All lengths are stored in mm. The panel has an mm / in display toggle that
converts only what is shown and typed.

| Field | Meaning |
|---|---|
| Thickness | Stock thickness. Slice spacing and slot widths derive from it. |
| Slot Offset (`slotClearance`) | The width the cutting tool removes, added to every slot so parts fit. **This is the field the slot geometry reads.** |
| `kerf` | A stored mirror of Slot Offset, always kept equal to it (kept for saved-material JSON compatibility). |
| Tool Dia. | Cutter (router bit) diameter: **the one tool diameter**. It sizes the relief cut at the inside corners of slots and notches in every mode that cuts relief: Interlocked Slot relief and Radial Relief Type. 0 cuts no relief. |
| Sheet W / Sheet H | Size of one sheet; parts are packed onto sheets of this size. |
| Margin | The packer's page margin, kept clear round every sheet: the same value as Margin in Export layout. |

### 2.0 Which rows each mode shows

A row a mode never reads is left out; a row another setting overrides is
greyed out with a short caption under it.

| Row | Shown and live | Greyed out | Left out |
|---|---|---|---|
| Slot Offset | Interlocked, Radial, Curve, Folded | Interlocked and Curve while Notch width is on: "Notch width sets the slot width, so Slot Offset is not used." Folded with a Joint Type that passes nothing through a slot: Laced and Ticked ("Laced joints fit nothing into a slot, so Slot Offset is not used.") and None ("Joint Type None cuts no slots, so Slot Offset is not used."). | Stacked |
| Tool Dia. | Interlocked with Slot relief on; Radial with a Relief Type other than Square | Interlocked with Slot relief off ("Sizes Slot relief, which is off."); Radial with Square relief ("Square relief cuts no circles, so the tool size is not used.") | Stacked, Curve, Folded |

Thickness, Sheet W / H and Margin are shown in every mode that has the
panel. Units and Material apply to all of them. 3D Slices has no
Manufacturing Settings at all: its layered mesh has no stock, slots or
sheets (`docs/specs/threeD.md` § 1).

### 2.0.1 Tool Dia. in older projects

Projects now save Tool Dia. (`toolDiameter`). Projects saved before it
existed kept a tool diameter per mode instead: Radial's Tool Diameter
(`radialToolDiameter`, default 0) and Interlocked's Relief diameter
(`slotReliefDiameter`, default 3 mm). Opening such a project carries one of
them into Tool Dia. when its relief was turned on (Radial: a Relief Type
other than Square; Interlocked: Slot relief) or when it differs from its
default, so the project cuts the relief it cut before. When both qualify,
the project's own mode wins, then Radial's. When neither does, Tool Dia.
keeps its current value. Both older fields are still read, and are still
written from Tool Dia. for older builds: Radial's Tool Diameter equal to it,
and Interlocked's Relief diameter held to that control's 0.5–12 mm range (the
range older builds read it in). So an older build opening a project saved with
Slot relief on and Tool Dia. 0 cuts 0.5 mm relief discs where this build cuts
none, and one saved with Tool Dia. above 12 mm cuts 12 mm discs. This build
always reads Tool Dia. itself.

### 2.1 Kerf and slot geometry

There is a single kerf parameter: the Slot Offset. A slot is cut
`thickness + slotOffset` wide (clamped to a 0.1 mm minimum), unless the user
sets an explicit notch-width override. Interlocked, Radial and the headless
exporter all use this rule. The separate `kerf` value is never applied on top
of it — applying both would double the compensation. Corner relief
(Interlocked dog bones; Radial Horizontal / Vertical / Dog Bone) is sized by
Tool Dia., not by kerf; a kerf-scaled corner relief is not implemented.

---

## 3. What the picker lists

The Material menu has three groups.

### 3.1 Material presets

| Preset | Thickness (mm) | Slot Offset (mm) |
|---|---|---|
| Custom | — (no change) | — (no change) |
| Cardboard 3 mm | 3.0 | 0.15 |
| Plywood 3 mm | 3.0 | 0.10 |
| Plywood 6 mm | 6.0 | 0.15 |
| Acrylic 3 mm | 3.0 | 0.20 |

These set thickness and Slot Offset only; sheet size, tool diameter and
margins are left as they are. `Custom` is the "no preset" state: choosing it
changes nothing.

### 3.2 Built-in sheet presets

Fourteen standard sheet sizes. Each sets thickness, sheet width and height,
Slot Offset 0.254 mm (0.01 in), Tool Dia. 0, and the page margin:

| Group | Presets | Thickness | Margins |
|---|---|---|---|
| A series | A4, A3, A2, A1 | 0.1772 in (≈ 4.501 mm) | 0.2 in (5.08 mm) |
| North American | Letter, Legal | 0.1772 in | 0.2 in |
| B series | B5, B4, B3, B2, B1 | 0.1772 in | 0.2 in |
| P series (mm) | P1 181 × 181, P2 384 × 384, P3 384 × 790 | 4.5 mm | 0.2 mm (P2: 0) |

Built-in presets cannot be deleted. Duplicating one creates a saved material.

### 3.3 Saved materials

**Save Current as Material…** stores the manufacturing fields under a name, app-wide
and across sessions (`UserDefaults` key `customMaterials`, JSON). Saving again
under an existing name edits that entry. Saved materials can be duplicated and
deleted. Records written before Tool Dia., `kerf` and the margins existed
decode with defaults (`kerf` 0.254, Tool Dia. 0, margins 0.254). A material
stores the page margin as its horizontal margin, and saves its vertical
margin equal to it; the packer has a single margin.

---

## 4. Selection semantics

1. Picking a preset or saved material writes its fields into the current
   manufacturing settings and shows its name in the menu.
2. Editing a field afterwards switches the menu label back to **Custom**. The
   preset itself is not changed. A saved material stays selected only while
   the live values still match it: thickness, Slot Offset, `kerf`, sheet
   size, Tool Dia. and the page margin (against its horizontal margin).
3. Re-selecting a preset re-applies all of its values.
4. Editing Slot Offset writes the same value to `kerf`.
5. When a saved or built-in record carries a zero Slot Offset but a non-zero
   `kerf` (older records), the `kerf` value is used as the Slot Offset.

---

## 5. Edge cases

- **Thickness not in any preset** (for example 7 mm plywood): pick the nearest
  preset and edit Thickness; the label switches to Custom.
- **Method mismatch** (a laser preset used on a CNC router): the app does not
  block it. The user matches the preset to the machine, or edits Slot Offset
  and Tool Dia.
- **Very small Slot Offset with a knife-cut material**: 0 is allowed; the slot
  is then exactly the material thickness.

---

## 6. Not implemented

A per-material × per-method preset library (plywood / MDF / acrylic /
cardboard × laser / CNC / knife, each setting kerf, connector sizes and
minimum part area) has been discussed but does not exist. Presets today set
only the fields in § 2.
