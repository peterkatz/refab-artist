# Radial Slices — spec

**Radial Slices** builds the model from **rings** and **fins**: a stack of
cross-sections along the vertical axis (the rings), plus a set of vertical
fins fanned around a central hub axis. Every ring and fin crossing gets a
half-lap joint — a notch cut in from the ring's rim and a slot cut out from
the fin's inner edge, each as wide as the stock — so the two families lock
together. Rings stand at least a stock thickness apart, so their stock never
overlaps.

Sources: `RadialSlices.swift` (plan), `RadialPartBuilder.swift` (ring and fin
outlines and their joints, with the crossing-line helpers of
`CurveJoints.swift`), `DxfExporter.swift` (DXF and its part frames),
`CutSheetDocument.swift` (sheet parts and labels),
`RadialSliceMeshExportBuilder.swift`, `AssemblySteps.swift`.

---

## 1. What the mode produces

1. **Rings** — cross-sections of the model on planes perpendicular to Z.
2. **Fins** — sections of the model by half-planes that start at the hub
   axis (the vertical line through the centre of the model's bounding box),
   one per fin angle.
3. A half-lap joint at every ring/fin crossing.
4. One labelled cut-sheet part per closed piece of each ring or fin. A piece
   that holds no joint with the other family is marked on the cut sheet
   (§ 3.4.1).

All outputs — the cut sheet, every vector export, the STL/OBJ export and the
3D viewport — use the same ring and fin outlines.

## 2. Parameters

| Parameter | GUI | CLI | Default | Effect |
|---|---|---|---|---|
| Method | Technique Settings → Method | — | By Count | How rings are spaced. |
| 1st Axis (count) | Technique Settings → 1st Axis (1–72) | `--first-axis-count` | 10 | Number of rings asked for (By Count); fewer when they would stand closer than the stock (§ 3.2). |
| 1st Axis (spacing) | Technique Settings → 1st Axis (1–100 mm) | `--slice-depth` | 15 mm (GUI) | Ring spacing (By Distance); at least the stock (§ 3.2). |
| Radial (Count) | Technique Settings → Radial (Count) (1–72) | `--n-radial` (or `--slice-count`) | GUI 6; CLI 12 | Number of fins (see § 3.3.1). `0` gives the Interlocked fallback (§ 5.1). |
| Thickness | Manufacturing Settings | `--thickness` | GUI 3 mm; CLI 5 mm | Material thickness. |
| Slot Offset | Technique Settings / Manufacturing Settings | `--slot-clearance` | 0 | Added to the stock thickness to give the slot width (§ 3.4), and the gap rings keep between them (§ 3.2). |
| Notch width | — | `--notch-width` | off | Replaces the slot width (§ 3.4). The CLI notes when it is narrower than the stock. |
| Notch Factor | — (read from older project files and kept) | — | 1 | No effect on the geometry (§ 3.4). |
| Notch Angle | Technique Settings, disabled with a hint | `--slot-angle` | GUI 45°; CLI 0° | Radial notches are cut square; used only by the Interlocked fallback (§ 5.1). |
| Relief Type | Technique Settings → Relief Type | `--relief-type` (`square`, `horizontal`, `vertical`, `dog-bone`) | Square | Relief at the inside corners of every notch and slot (§ 3.4.2). |
| Tool Dia. | Manufacturing Settings → Tool Dia. (greyed out for Square) | `--tool-diameter` | 0 | Diameter of the router bit the relief is cut for: the one tool diameter, shared with Interlocked Slot relief. 0 cuts no relief. Under Relief Type the panel says which Tool Dia. the relief is cut for, or asks for one when it is 0. |

The fins always start at 0°: the app has no control to turn them, and the CLI
has no flag for it (an unknown flag is an error, as in every slice mode, and
the run then writes nothing: no output folder, export or `--dump-mesh` file).

## 3. Decision logic

### 3.1 Rings plus fins

A radial job always builds the rings along **Z**, whatever the model's
proportions. Then:

- `Radial (Count) > 0`: fins at evenly spaced angles around the hub axis
  (§ 3.3).
- `Radial (Count) = 0`: no fins; the job becomes an Interlocked job with one
  central plank (§ 5.1).

### 3.2 Ring positions

Each ring is a slab of stock `t` thick. Two rings closer together than that
would pass through each other, so rings stand at least

```
s_min = max(t, slot width)        (slot width = t + slot offset, or the notch-width override)
```

apart, centre to centre: the stock, plus the slot offset as the gap between
neighbouring rings. Over the model's Z extent `[lo, hi]`:

- **By Count** (`N` asked for, default 10): as many rings as fit,
  `N' = min(N, max(1, floor((hi − lo) / s_min)))`, at
  `z_i = lo + (hi − lo)(i + 0.5)/N'`.
- **By Distance** (spacing `d` asked for): with `d' = max(d, s_min)`,

  ```
  n    = max(1, ceil((hi - lo) / d'))
  base = (lo + hi)/2 - (n + 0.5) · d' / 2
  i    = ceil((lo - base)/d' - 1e-4) … floor((hi - base)/d' + 1e-4)
  z_i  = i · d' + base
  ```

  The rings stay the material thickness thick; `d'` only spaces them.

When fewer rings are cut, or they stand further apart, than asked, the app
says so in orange under 1st Axis and the CLI notes it on stderr, for example
"Only 3 rings fit along this model in 5 mm stock (10 asked for); rings closer
than 5 mm would pass through each other. Use thinner stock for more." The
torus (19.9 mm tall) gets 6 rings in 3 mm stock and 3 in 5 mm; the 50 mm
cube keeps all 10 in 5 mm stock.

A ring whose plane would run along a flat face of the model (a horizontal
triangle in it: where one block of the model ends and the next begins) is
moved 0.01 mm off it, below it (above it at the model's bottom face). In the
face the section is ambiguous; just below it, it is the one the slicer takes.
The low-poly head's third ring, at the neck's top face (z = 15), is cut at
z = 14.99.

### 3.3 Fins

#### 3.3.1 Fin angles

The fin count is the requested count, except that a request for **8** gives
**10** fins (§ 7). Fin `k` sits at `k · 360° / count`, measured from +X about
the hub axis.

#### 3.3.2 Fin section

For each angle the model is cut by the vertical plane through the hub axis at
that angle, and the cut is projected to (distance from the hub axis, Z). The
half on the fin's side of the axis is kept; it may split into several closed
pieces on concave or hollow models, and each piece becomes its own part.

#### 3.3.2.1 Sections of models built from several shells

Ring and fin sections are taken as the solid the model shows. Every loop of a
section is turned so the model's material lies on its left, as the triangles
it was cut from face (up to eight of its edges vote; a loop none of whose
edges can be matched is turned by how many other loops it lies inside). On a
mesh whose triangles wind both ways (two triangles that share an edge run it
the same way), or wind wholly inside out, a loop can come out turned the
wrong way: when the loops do not come out turned as their nesting says, the
triangles are first made to agree (across every edge two triangles share
their windings are matched, and on each connected patch the way most of its
triangles wind wins), then made to face out (when the mesh so read encloses
a negative volume, as an inside-out export does, every triangle is read the
other way round; `MeshWinding`), and the loops are turned again. A mesh whose
triangles all agree and face out is read as it is. An outline that touches
itself at a point is split there into its two lobes when neither lies
inside the other, whichever way each turns (`separatingPinches`), so every
outline cut is a simple loop. When
that agrees with counting loops inside loops and no two pieces touch, the
loops are used as they are. Otherwise — shells that touch along a face (a
head on a neck, the chair's back on its seat) or run into each other (two
overlapping blocks) — the section is the union of its loops (non-zero fill,
with pieces closer than 0.001 mm welded): one piece where the model is one
solid, with no hole where two shells overlap. So the chair's fins through
seat and back are one part each, and the low-poly head's rings and fins are
whole.

#### 3.3.3 Hub inset

Every fin starts a distance `h` from the hub axis, so that neighbouring fins'
stock does not overlap there. Each fin is a slab of stock `t` thick centred
on its plane, and `n` fins are `360°/n` apart. Two neighbouring slabs overlap
from the axis out to where the inner corners of their faces meet, which is
`(t/2)·cot(180°/n)` along each fin; fins farther apart clear each other
sooner. So

```
h = (t/2) · cot(180°/n)    for n ≥ 3
h = 0                      for n = 1 (no neighbour) and n = 2 (one plane, either side of the axis)
```

At `t = 5 mm`: 12 fins start 9.33 mm out, 6 fins 4.33 mm, 4 fins 2.5 mm. The
section is cut along the line `x = h`; on a concave or hollow model each
closed piece left is clipped on its own, so pieces are never bridged along
that line. The rings span the hub, so the model is still filled there. A fin
whose section lies wholly inside `h` (many fins in thick stock on a small
model) is left out.

#### 3.3.4 Ring outlines

Each closed piece of a ring's cross-section, with the holes inside it (a
torus gives annular rings), becomes a ring part. Every fin that crosses the
ring cuts a notch into it along the fin's own direction (§ 3.4). A ring piece
whose stock no fin's stock crosses is dropped, since nothing would hold it
(the simple chair's legs, which no fin plane reaches); the joints are then
planned without it. The cut sheet, the Radial panel and the CLI name what
is left out, a ring left out whole by its label and otherwise the number of
its pieces ("Z-1, Z-2, Z-3, Z-4 and Z-5 cross no fin and are left out:
nothing would hold them in place."), and the measurement JSON lists one
label per piece (`left_out_pieces`). Its assembly step is dropped
(`docs/specs/assembly-steps.md` § 2).

#### 3.3.5 Fin outlines

Each closed piece of a fin's section, with its holes, becomes a fin part.
Every ring that crosses the fin cuts a slot into it at the ring's height
(§ 3.4), only where the fin actually has material there.

#### 3.3.6 Pieces the joints are planned on

Slivers are dropped first: in each family, pieces under 1 % of the family's
largest piece (and under 1 mm²). The joints are planned
on the pieces that are left, and only those. When the cuts then take a piece
away whole, or leave nothing of it but scraps, it is dropped (and named, as
in § 3.3.4: "… are left out: the notches and slots would cut them away, or
leave only scraps of them.") and the joints are planned again without it. So
no notch or slot is cut for a piece that is not on the cut sheet: every
notch has the stock of the fin it was cut for in it.

### 3.4 Half-lap joints

A ring and a fin cross at right angles along the line their planes share: out
from the hub axis in the fin's direction, at the ring's height. Distances
along it, `u`, are measured from the hub axis.

- **Shared stretch.** Around the line, the two parts' stock overlaps in a
  beam `t` square. The joint covers every stretch of the line where, anywhere
  in that beam, the ring and the fin both have material (sampled on a 5 × 5
  grid across the beam; stretches under 0.1 mm are contact, not a joint).
- **Meeting point.** The joint sits in the outermost shared stretch
  `[a, b]`. The two slot bottoms meet in its middle, `m = (a + b)/2`, so each
  part keeps half of it (a half-lap). If a hole in the ring lies on the line
  past `m`, or a hole in the fin before it, `m` moves along the stretch just
  far enough that neither slot runs into its own part's hole, with at least
  1 mm of material between, when that is possible.
- **Ring notch.** From `m` out through the ring's rim, 1 mm past it (stopping
  halfway to any material of the ring further out). The ring keeps the line
  from the hub out to `m`, including any shared stretch inward of `[a, b]`.
- **Fin slot.** From 1 mm inside the fin's inner edge (where the line first
  enters both parts' stock) out to `m`, through any shared stretch inward of
  `[a, b]`. The fin keeps the line from `m` out.
- **Width.** Both cuts are the slot width wide, centred on the line: the
  stock thickness plus the slot offset, or the notch-width override when it
  is set. The part crossing a cut is exactly the stock thickness, so it fits.
  The Notch Factor does not change the width: a cut narrower than the stock
  could not take the other part.
- **Depths add up.** Along the line the ring holds the model up to `m` and
  the fin from `m` on, so the notch and slot depths add up to the shared
  stretch and the assembled joint is closed.

To assemble, stack the rings on the hub axis with their notches lined up,
then slide each fin straight in toward the axis: its slots open toward the
axis and the rings' notches open away from it, and on every crossing line the
ring keeps only material inward of the fin's, so nothing blocks the fin on
the way in.

Two cuts in one part closer together than 1 mm are cut as one, so no web of
material thinner than that is left between them (on the sphere at 5 mm, the
rings stand 5 mm apart and each fin's slots run together into one stepped
cut). A hairline the cuts leave (material narrower than 0.9 mm beside a
notch, past the last slot or at a tip, such as the wedge a torus fin keeps
above its top ring) is cut away: the part is shrunk by 0.45 mm and grown
back, and where that takes away at least 0.5 mm² and leaves the part in one
piece with the middle of every stretch it keeps at its joints, what is left
is cut. A piece that is hairline all over and keeps none of a joint's
stretch is scrap and dropped. A hairline that is a neck between two parts of
a piece, or that holds a joint (the 0.67 mm strip a fin at 0° keeps through
the low-poly head's neck, where the hub inset leaves it 0.67 mm of the
neck's 10 mm, and which the neck rings are notched for), stays, so no piece
is cut loose from what holds it; such a part is named instead. A part is
named as narrower than the stock when, shrunk by just under half the stock
and grown back, it falls into several pieces or into none, or, shrunk by
0.45 mm and grown back, it falls apart or loses the middle of a stretch it
keeps at a joint. The note is on the cut sheet, in the Radial panel and on
the CLI ("Parts R-1, R-2, R-6 are narrower than the stock in places, where a
notch or slot comes close to an edge or the model is that thin: handle them
with care, or use thinner stock."), and the parts are listed in the
measurement JSON (`thin_parts`), whatever the relief. Cutting such strips
away before the joints are planned was tried and not kept: on a
shrinkwrapped hand scan it left a ring piece and a fin piece joined only to
each other.

#### 3.4.1 Pieces the cuts separate, and pieces no joint holds

The cuts can separate a part into pieces. Each piece that holds a joint (the
middle of the stretch its part keeps at one of its joints) becomes a part of
its own; a piece that keeps more than 0.02 mm of such a stretch along the
crossing line, as the functional gate counts it, is not marked as unjoined. A piece that holds none is scrap when it is under 1 % of its
family's largest piece (or under 1 mm², or under 1.5 mm across) and is
dropped; otherwise it is kept and marked: blue on the cut sheet, "Not joined
to the rest of the model: glue it in place" in the sheet's part inspector, a note in
the Radial panel and on the CLI's stderr ("N parts are not locked to any ring
or fin (…) and shown blue on the cut sheet: glue them in place. A fin locks
into a ring only where their crossing line last runs through the model;
nearer the hub it is slotted clean through."), and
`unjoined_parts` in the measurement JSON. The assembly audit counts them as
detached.

This is where a crossing line runs through the model more than once: the
joint sits in the outermost stretch, and inward of it the fin is slotted
clean through and the ring kept whole, so a fin can slide in from outside.
Pieces that meet the other family only in those inner stretches are not
locked by any joint. On a cup with a post in the middle, the rings' post
discs sit in the fins' through slots and are marked; where a fin is slotted
through into bands between the rings, each band that is not scrap is kept as
its own marked part (in 3 mm stock with 4 mm ring spacing the bands are 1 mm
slivers, scrap). An
annular ring cut open by a notch stays one part (it still holds its joints);
a piece the cut takes away whole although it holds a joint comes back uncut
and flagged red ("Notches split part").

#### 3.4.2 Relief

A router bit cannot cut a square inside corner: it leaves a fillet of its own
radius at the two inside corners of every notch and slot, and the square
edge of the part that seats there stops on it. With Relief Type set and a
Tool Dia. `D` (radius `r = D/2`), a circle of radius `r` is cut at each
inside corner, through the corner itself, so the tool clears it:

- **Dog Bone**: centred on the corner's diagonal, `r/√2` along the slot and
  `r/√2` in from its side; it digs a little into both.
- **Horizontal**: centred on the bottom's line, `r` in from the side; it digs
  past the bottom, along the slot.
- **Vertical**: centred on the side's line, `r` along the slot from the
  bottom; it digs into the side.

The circle is cut as a 48-sided polygon with a corner on the slot corner.
Square relief, or Tool Dia. 0, cuts none. The relief keeps the joint
snug only while the two corners' circles leave the 1 mm web the cuts keep
(§ 3.4) between them past the slot bottom: `w − 2D` of material for
Horizontal relief, `w − √2·D` for Dog Bone (slot width `w`); any less is cut
away and the slot bottom moves. So Horizontal relief suits a tool up to
`(w − 1)/2`, Dog Bone up to `(w − 1)/√2`, Vertical up to `w` (a wider tool
cannot cut the slot at all). Relief that digs into the slot sides also eats
the web a fin keeps between two neighbouring slots (the ring spacing less
the slot width): all of `D` for Vertical, `D(1 − 1/√2)` for Dog Bone; with
less than 1 mm of it left the fin comes apart there (the pieces are marked,
§ 3.4.1). In any of these cases the app says so in orange under Relief
Type and the CLI notes it. In 5 mm notches that is 2 mm for Horizontal
and 2.83 mm for Dog Bone relief; on the cylinder, whose rings stand 8 mm
apart, Vertical relief takes a tool up to 2 mm.

### 3.5 Part filtering, labels and order

- In each family, pieces under 1 % of the family's largest piece area are
  dropped, and hairlines the cuts leave are trimmed (§ 3.4).
- The notes the cut sheet carries (pieces left out, parts no joint locks
  in, parts narrower than the stock) are shown under the Radial technique
  settings whatever the Export format (the OBJ and STL meshes leave out the
  same pieces, though the sheet is not shown for them) and printed by the
  CLI for every format.
- Ring labels: `Z-i` (`Z-i-c` when a ring has several pieces). Fin labels:
  `R-k` for the first piece, `R-k-c` for further pieces.
- Assembly order: all rings bottom to top (`Place first_axis_NNN`, receives
  the fin notches), then the fins (`Insert radial_NNN`, with the fin's
  angle).
- Parts are shelf-packed onto sheets as for every cut-sheet mode.

## 4. Data structures

- `RadialSlicePlan` — hub centre and radius (half the larger XY extent),
  ring plan (`primary`), the plank plan used by the fallback (`secondary`),
  requested fin count, recorded angle list, slot width
  (`max(0.1, notchWidth ?? thickness + offset)`: the width of every ring
  notch and fin slot, and the fallback's slot width), slot angle, slot
  offset, notch factor, relief type and tool diameter, and the ring count
  or spacing asked for when fewer or further apart rings were planned
  (`requestedRingCount`, `requestedRingSpacing`, `ringCountNote`).
- Ring / fin part — counter-clockwise outline, clockwise holes, slice (or
  fin) index, position (Z or angle), piece index, a severed flag and whether
  it holds a joint (`joined`). Ring outlines are in the ring's plane; fin
  outlines are in (distance from hub axis, Z).
- Joint — ring and fin index, the crossing line, the outermost shared
  stretch `[a, b]`, where the line first enters both parts' stock, the
  meeting point and the width.

## 5. Edge cases

### 5.1 Radial (Count) = 0

The job degrades to Interlocked: the rings become the primary family and a
**single** central plank along Y becomes the secondary family. Slot width,
slot angle and slot offset apply as in Interlocked; slot relief is off. The
cut sheet, every export, the viewport and the assembly steps follow the
Interlocked spec (`docs/specs/interlocked.md`).

### 5.2 Other cases

- **One fin**: a single half-section fin; every ring gets one notch.
- **Model shorter than the stock**: one ring, at the middle of its height
  (the gear in 5 mm stock).
- **Model that does not reach the hub axis** (a ring or torus): fins have no
  material at the hub at some heights, so those rings get no fin slot there,
  and rings with no overlapping fin are dropped.
- **No bounds / non-positive thickness**: no plan.
- **More than 600 rings plus fins**: the GUI shows no plan.

## 6. Output

| Output | Content |
|---|---|
| Cut sheet, Print, SVG / PDF (app and CLI) | ring and fin outlines, labels as § 3.5; in the app, pieces that hold no joint are blue (§ 3.4.1) |
| DXF / EPS (app and CLI) | the same outlines laid out in rows, families `first_axis` and `radial` |
| Part frames (CLI `--part-frames` with the DXF) | for each DXF layer, the map from its coordinates to the coordinates of the model as imported (under a Slice Direction tilt too: the turn into the slicing frame is undone), so a checker can put the parts back in the model, and `"detached": true` for a part no joint locks in (§ 3.4.1) |
| STL / OBJ | each outline extruded in place to the material thickness (app and CLI): `first_axis_NNN` (`_CC` for extra pieces) and `radial_NNN` |
| Viewport | the same extruded parts |
| Measurement JSON (CLI `--measurement`) | `radial_slices`: ring and fin part counts as exported (`first_axis_count`, `radial_count` fin planes, `radial_part_count`, `total_part_count`; with `--n-radial 0` the Interlocked parts: rings, `plank_count`, and no fins), `ring_count`, `requested_ring_count`, `minimum_ring_spacing`, `requested_ring_spacing` when set, `relief_type`, `tool_diameter`, `unjoined_part_count` and `unjoined_parts`, `left_out_pieces` (§ 3.3.4, § 3.3.6) and `thin_parts` (§ 3.4) |

## 7. Known issues

- **Fin count 8 gives 10 fins.**
- **Lines that cross the model more than once**: the joint sits in the
  outermost shared stretch; inward of it the fin is slotted clean through the
  model at the ring's height. Pieces that meet the other family only there
  are kept and marked to be glued (§ 3.4.1), not locked. Locking them would
  take a different assembly (some rings notched clean through instead), which
  this mode does not plan.
- **Ring pieces no fin reaches are left out** (the simple chair's legs), as
  nothing would hold them; the notes name them (§ 3.3.4).
- **Inconsistently wound and inside-out meshes** are read with their
  triangles made to agree and face out (§ 3.3.2.1). A connected patch on
  which as many triangles wind one way as the other is read the way its
  first triangle winds; a mesh whose shells overlap is still read by each
  shell's own winding.
- **Thin parts are named, not avoided.** A part narrower than the stock in
  places, a neck under 1 mm, or a strip under 1 mm that holds a joint
  (§ 3.4) is cut as planned: the ring spacing and the meeting points do not
  look for it, and cutting the strips away first would cut some pieces
  loose from what holds them.

## 8. Worked example

50 mm cube centred on the origin, CLI defaults (`--thickness 5`,
`--n-radial` absent so 12 fins, slot offset 0):

- Rings: 10 at `z = −22.5, −17.5, …, 22.5` (50 mm / 5 mm: all ten fit), each
  a 50 × 50 mm square.
- Fins: 12, at 0°, 30°, …, 330°, each starting `h = 2.5 · cot 15° = 9.33` mm
  from the hub axis. The fin at 0° reaches the cube's face at 25 mm, the fin
  at 30° at `25 / cos 30° = 28.87` mm.
- Joints: slot width 5 mm. On the 0° fin the shared stretch is
  `[9.33, 25]` and the slot bottoms meet at 17.17 mm; on the 30° fin
  `[9.33, 28.87]`, meeting at 19.10 mm.
- Each ring gets 12 notches, 5 mm wide, from the meeting point out through
  its edge. Each fin gets 10 slots from its inner edge to the meeting point;
  the rings stand 5 mm apart, so the slots run together and each fin is left
  as a 50 mm tall bar from the meeting point out (7.83 mm wide at 0°,
  9.77 mm at 30°).
- Cut sheet: 22 parts, `Z-1` … `Z-10`, `R-1` … `R-12`.
