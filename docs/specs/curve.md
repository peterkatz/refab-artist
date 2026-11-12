# Curve Slices — spec

**Curve Slices** is a two-family interlocking mode whose second family
follows a curve. The first family is a set of parallel cross-sections (the
**first-axis ribs**); the second is a set of vertical ribs placed along a
spline in the XY plane, each standing perpendicular to the spline (the
**curve ribs**). Half-lap slots join the two families where they cross.
Where the spline bends, the curve ribs fan in; each stops short of where it
would run into another or crowd its slots. No more ribs of either family are
cut than leave a web of material at least as thick as the stock between two
slots.

Sources: `CurveSlices.swift` (plan, spline sampling, rib counts, sections),
`CurveRibJoining.swift` (first-axis ribs moved to join parts),
`CurveJoints.swift` (where the curve ribs stop, the half-lap joints and their
slots), `CutSheetDocument.swift` (sheet parts, slots cut into them),
`PlanarBoolean.swift` (section clean-up, slot cutting),
`CutSheetDocumentExporter.swift` (DXF, EPS, part frames),
`CurveSliceMeshExportBuilder.swift`, `AssemblySteps.swift`.

---

## 1. What the mode produces

1. First-axis ribs: cross-sections perpendicular to the chosen first axis.
2. Curve ribs: sections of the model by vertical planes along the spline,
   each cut short where it would meet another curve rib, crowd its slots, or
   end inside a first-axis rib it cannot join (§ 3.4).
3. A half-lap joint wherever a first-axis rib and a curve rib cross inside
   the model: a slot in each, the two depths adding up to the span they
   share (§ 3.5). Any first axis.
4. One labelled cut-sheet part per piece of each rib: each disconnected
   piece of its section, and each piece its slots cut off that holds joint
   material (§ 3.6). A piece no joint holds is left out, and parts the
   joints hold together but not to the rest of the model are shown blue
   (§ 3.6.1), unless moving a first-axis rib off the even spacing joins them
   (§ 3.1.1).

## 2. Parameters

| Parameter | GUI | CLI | Default | Effect |
|---|---|---|---|---|
| 1st Axis | Technique Settings → 1st Axis | `--axis` | GUI Y; CLI Z | Axis of the first-axis ribs. |
| 1st Axis slices | Technique Settings (1–72) | `--first-axis-count` | 7 | Number of first-axis ribs asked for; fewer are cut when that many do not fit (§ 3.1). |
| Curve slices | Technique Settings (2–72) | `--curve-slice-count` (or `--slice-count`) | 12 | Number of curve ribs asked for; fewer are cut when that many do not fit (§ 3.3). |
| Amplitude | Technique Settings (mm) | `--amplitude` | 10 mm | Bow of the default spline, at most the model's extent along it. |
| Spline control points | — | `--spline-control-points` | — | Replaces the default spline. |
| Thickness | Manufacturing Settings | `--thickness` | GUI 3 mm; CLI 5 mm | Material thickness. |
| Slot Offset | Technique Settings / Manufacturing Settings | `--slot-clearance` | 0 | Added to thickness for the slot width. Not used while Notch width is on (both copies greyed out). |
| Notch width | Technique Settings (0.1–50 mm) | `--notch-width` | off | Replaces `thickness + offset`. |
| Notch angle | — (not shown for Curve) | `--slot-angle` | GUI 45°; CLI 0° | Recorded in the plan only; slots are cut square (§ 3.6). |
| Slice Direction | Slice Direction panel | `--slice-tilt-first`, `--slice-tilt-second` | 0, 0 | Tilts the slicing direction away from the 1st axis. |

Slot width `w`: `max(0.1, notchWidth ?? thickness + slotOffset)`; ribs that
cross at a slant get wider slots (§ 3.6).

The Technique Settings panel says so whenever a setting does less than asked:

- under **1st Axis slices** and **Curve slices**, in orange, when fewer ribs
  are cut than asked for (§ 3.1, § 3.3), for example "Only 5 first-axis
  slices fit across this model in 5 mm stock (7 asked for); more would leave
  the curve slices too thin between their slots. Use thinner stock for
  more." The CLI prints the same sentences on stderr as `note: …`, and the
  measurement JSON gives `requested_primary_slice_count` and
  `requested_curve_slice_count` beside `primary_slice_count` and
  `curve_slice_count`;
- under **1st Axis slices**, in grey, when first-axis ribs are moved off the
  even spacing to join parts (§ 3.1.1), for example "Z-3 is set off the even
  spacing, at 72.88 mm instead of 78 mm, so the joints hold parts that would
  otherwise be joined only to each other." The CLI prints it on stderr as
  `note: …`, and the measurement JSON lists the moves
  (`first_axis_moves`: `rib`, `even_position`, `position`);
- **Slot Offset** is greyed out while **Notch width** is on, with the caption
  "Notch width sets the slot width, so Slot Offset is not used."; the
  Manufacturing Settings copy is greyed out with the same caption. Tool Dia.
  is not shown for Curve, which cuts no relief;
- a **Notch width** narrower than the stock gets an orange warning: the
  parts will not fit into each other's slots;
- an **Amplitude** larger than the model's extent along the spline (the most
  it can bow, § 3.2) gets a grey caption saying so;
- at the end of the panel, in orange, when the cut sheet leaves out pieces
  no joint would hold, shows parts blue that are joined only among
  themselves (§ 3.6.1), or has parts narrower than the stock in places
  (§ 3.5), for example "Y-1 crosses no slice of the other
  family and is left out: nothing would hold it in place." These show
  whatever the Export format: the OBJ and STL meshes are cut from the same
  parts, though the sheet is not shown for them. The CLI prints the same
  sentences on stderr as `note: …` for every format.

## 3. Decision logic

### 3.1 First-axis ribs

`N` ribs spread evenly over the model's extent `[lo, hi]` on the first axis:
`p_i = lo + (hi − lo)(i + 0.5)/N`, `N` the number asked for or, when fewer
fit, the most that do; a rib is moved off the even spacing only to join parts
(§ 3.1.1). They fit when the curve ribs keep a web at least as
thick as the stock (`slotWeb`, § 3.6) between two first-axis slots: the
spacing `(hi − lo)/N` must be at least

```
w + t·|cos a| + t·sin a
```

for slot width `w`, stock `t` and the steepest angle `a` at which a curve
rib crosses the first-axis ribs anywhere along the spline (with first axis
Z every crossing is square: `w + t`). In 3 mm stock seven first-axis ribs
fit across the 50 mm test sphere with first axis Z (7.1 mm apart); in 5 mm
stock five do (10 mm apart).

#### 3.1.1 Ribs moved to join parts

Even spacing knows nothing of the model's shape. A first-axis rib can pass
just below or above where a lobe joins the rest of the model (on a scanned
hand, Z-2 cuts the thumb 1.3 mm under where it meets the palm), so the
pieces of the ribs that cross the lobe are joined to each other but to
nothing else, and would be shown blue (§ 3.6.1). With every slot and piece
worked out (§ 3.5, § 3.6), while some parts are joined only among
themselves, first-axis ribs are moved off the even spacing
(`CurveSlicePlanner.joiningGroups`):

- the ribs tried are those holding such a part and their neighbours, each
  moved at most once;
- a rib is moved by whole sixteenths of the even spacing, at most six
  (three eighths of the spacing): nearest move first, at each the ribs in
  order, and toward the lower end before the upper;
- a move is taken only when it joins parts to the rest of the model: fewer
  parts are joined only among themselves, the moved rib has a part joined
  to the rest, every other rib that had one still has one (the parts
  counted as the model stay the model), and either more parts of the other
  ribs are joined to the rest or the moved rib has fewer parts joined only
  among themselves than it had;
- and only when it loses nothing on the way: every rib that had a part
  still has one, no more pieces are left out (a rib whose section has
  material but no part, cut away whole where the curve ribs stop, counts as
  left out), and no more parts are narrower than the stock. A move that
  only lowers the count of blue parts is not taken: on the two spheres with
  first axis X (3 mm stock, 4 first-axis and 6 curve ribs, amplitude 0)
  moving X-2 toward the gap between them would empty its section, so the
  left sphere would be one part short and the right one would count as the
  model, with nothing joined; on the torus with first axis X (3 mm stock, 6
  first-axis and 16 curve ribs, amplitude 20) moving X-2 would only make
  its two blue pieces one blue piece, so only X-4, whose two blue pieces a
  move of three sixteenths joins to the rest, is moved;
- the move keeps every two neighbouring ribs at least the pitch of § 3.1
  apart, stays inside the model's extent, and leaves the curve ribs
  standing clear (§ 3.4).

When no move helps the ribs stay at even spacing and the parts stay blue.
The plan keeps the even positions (`evenFirstAxisPositions`), and the panel,
the CLI and the measurement JSON say which ribs were moved (§ 2). Every
output cuts the moved ribs, and the assembly steps give their positions. On
that hand (first axis Z, 3 mm stock, shrinkwrapped) Z-3 moves from 78 mm
to 72.88 mm, through the thumb where it is joined to the palm (on the same
scan not shrinkwrapped, moving Z-3 a quarter or five sixteenths of the
spacing would leave a part narrower than the stock, so it moves three
eighths, from 78.02 mm to 70.32 mm); on the simple
chair with first axis Z (3 and 5 mm stock) Z-4 moves from 175 mm to
181.25 mm, into the seat, and joins both legs. On the torus, the spur gear and
the lumpy blob with first axis Y in 5 mm stock no move passes these checks,
and their blue parts stay blue.

The pass works out every joint again for each move it tries, so the app does
it off the main thread with the cut sheet and keeps the result
(`ViewportGeometryCache.joinedCurvePlan`); until it lands, the viewport,
steps and panel show the ribs at even spacing. Exports always cut the
joined plan, and the CLI (`--headless-export`, `--assembly-audit`) cuts
it too.

### 3.2 The spline

The spline lives in the horizontal plane at the model's mid-height and runs
across the first-axis ribs. By default it has three control points across
the model's X extent:

```
(minX, midY), (midX, midY + a), (maxX, midY)
```

With first axis X the X ribs would stand nearly parallel to curve ribs on
that spline, so it runs across the Y extent instead, bowed toward +x:

```
(midX, maxY), (midX + a, midY), (midX, minY)
```

The amplitude `a` is clamped to ±(the model's extent along the spline).
With `--spline-control-points` the given points (at least two) are used as
they are, in model coordinates.

The control points are joined by a Catmull-Rom spline (end points repeated
as their own neighbours), tessellated at 24 steps per span. Two control
points give a straight line.

### 3.3 Curve ribs

`M` ribs (Curve slices, at least 2) are placed at equal arc length along the
tessellated spline, at `(i + 0.5)/M` of its length. Each rib is the section
of the model by the vertical plane through that point whose normal is the
spline's tangent there, so the rib stands across the curve. The section is
projected to (distance along the plane, Z).

`M` is lowered, one at a time, until

1. every two ribs **stand apart** where they leave the spline: for at least
   one of the two, at its sample point, the space between its stock and the
   other's is at least `ribClearance` (0.5 mm), and the web between their
   slots in a first-axis rib crossing both there is at least the stock:

   ```
   |(c_b − c_a) · d_b| − t/2 · (1 + |d_a · d_b|)  ≥  0.5
   |(c_b − c_a) · d_b| − w/2 · (1 + |d_a · d_b|)  ≥  t
   ```

   for sample points `c`, tangents `d`, stock `t` and slot width `w`; and
2. the ribs **stand clear** (`RibLayout.standsClear`, § 3.4): each can stop
   short of whatever it must not run into without going back past the
   spline, no rib is cut short on both sides with first axis Z, and no two
   ribs' slots close in on each other.

At worst one rib is cut. The plan keeps the count asked for
(`requestedSliceCount`) and the panel and CLI say how many fit (§ 2). On the
50 mm test sphere eight of twelve curve ribs fit in 3 mm stock with first
axis Z, seven with first axis Y; in 5 mm stock five and three. Crossings at
a slant (first axis X or Y) take wider slots, so fewer ribs fit than with
first axis Z.

### 3.4 Where curve ribs stop

Each curve rib has a **reach**: the stretch of its section (in `u`, distance
from the spline along the plane) it keeps. Everything beyond is cut away,
through the rib's whole height, as part of its slots. The reach is worked
out from where the ribs stand, the first-axis rib positions and the model's
bounding box (`CurveJointPlanner.ribLayout`), before any section is cut, so
the planner can check a rib count cheaply (§ 3.3).

**Ribs that close in on each other.** For every two curve ribs `a` and `b`,
the stretch of `a` where its stock comes within `ribClearance` of `b`'s,
inside the bounding box seen from above, is

```
|(c_a − c_b) · d_b + u · (n_a · d_b)|  <  t/2 · (1 + |d_a · d_b|) + 0.5
```

(`n` the rib's in-plane direction). Both ribs stop short of it, on the side
of the spline where it lies. A rib that meets the other's stock at its own
sample point cannot stop short of it, so the other stops alone.

**First axis Z: one side only.** A rib cut short on both sides could not be
slotted without leaving part of a first-axis slot empty (§ 3.5), so for a
rib that would be, the side whose partners can all stop alone without being
cut short on both sides themselves is freed: there only the partners stop.

**First axis X or Y.** The crossings with the first-axis ribs run up the
curve rib. A rib must not end inside the beam of a crossing (within
`t·(1 + |cos a|) / (2 sin a)` of its line, plus 0.5 mm) without reaching
0.5 mm past the line, so it stops 0.5 mm short of that beam instead, and
again past any beam that puts it in. Then, first-axis rib by first-axis rib,
while two neighbouring curve ribs' slots in it would leave a web thinner
than the stock, or a slot would cover the line of a curve rib that stops
short of that first-axis rib, one of them stops short of its beam: the one
that keeps the most of itself. A rib within about 6° of parallel to a
first-axis rib (`|n·axis| < 0.1`) is not joined to it and stops short of
its stock.

**First axis Z: slots that keep apart.** Each rib's first-axis slots open
toward one side of it (`slotSide`): away from where it is cut short, or,
uncut, toward where its neighbours draw away from it (the spline's convex
side). They must keep a web at least as thick as the stock from every other
rib's line, slotted or not, so each starts no nearer the spline than where
that holds (`slotStart`), and the rib stops there on its other side: behind
it the rib could only be joined with crowded slots.

The rib count is lowered (§ 3.3) when any of this cannot be met: a rib that
would have to stop back past the spline, a rib still cut short on both
sides with first axis Z, or slots that close in on another rib's line ahead
of where they start.

A rib its reach would take away whole is dropped; pieces of a section the
stops leave within reach all take part in the joints.

On the 50 mm test sphere (eight curve ribs, 3 mm stock, first axis Z) the
middle ribs stop a few millimetres into the spline's concave side; the rest
of the concave side is held by the first-axis ribs alone.

### 3.5 Joints

Each first-axis rib meets each curve rib along the line their two planes
share:

- First axis **Z**: the line is horizontal, at the rib's height, and runs
  along the curve rib (direction `n`, the curve rib's in-plane direction).
- First axis **Y** or **X**: the line is vertical, where the curve rib's plane
  reaches `y = p` (or `x = p`). Ribs within about 6° of parallel
  (`|n.y|` or `|n.x|` below 0.1) get no joint (§ 3.4).

Along the line, a joint is found where both ribs' stock would occupy the
same space: the beam where the two ribs' thicknesses overlap. On a 5 × 5 grid
of lines across that beam, the stretches where both ribs' sections have
material are found and merged; every merged stretch of at least 0.1 mm is a
joint, from `start` to `end`.

The first-axis rib is slotted from the meeting point toward one end of the
line and the curve rib from the meeting point toward the other: with first
axis X or Y the first-axis rib toward the top, so the curve rib drops in from
above; with first axis Z toward the curve rib's `slotSide` (§ 3.4), so the
curve rib slides in from that side. Every slot opens through an edge the
other rib reaches, and the two slot depths add up to the joint's length.

The slot bottoms meet in the middle of the joint, moved along it just far
enough that

- each slot opens through one edge of its rib and cuts no hole of its own
  rib into the open: on every one of nine lines across the slot, the slot
  starts at least `slotWeb` (the stock thickness, at least 1 mm) past the
  start of its rib's last stretch of material in the joint (the first
  stretch, for the slot running the other way), so a stock-thick web stays
  between the slot bottom and the hole or edge beyond it;
- neither slot runs on beside a strip of its own rib narrower than
  `slotWeb` (`CurveJointPlanner.thinStrips`: on one side of the slot the
  section's edge or a hole comes closer than that, over at least twice
  that length): the slot stops 1 mm short of the strip, or, for the slot
  running the other way, starts 1 mm past it. A strip the slot must open
  through is let be;
- each rib keeps some of the joint on the crossing line itself;
- with first axis Z, the first-axis slot starts no nearer the spline than
  `slotStart`.

Where that cannot all be met, the strips are let be and the webs shrink to
1 mm. When both slots still cannot be kept clear of their holes, the
first-axis rib's slot is (with a stock-thick web if it fits, else 1 mm), and
the curve rib's slot may cut its rib open (§ 3.6). On the hollow box with
first axis Y in 3 mm stock, the first-axis ribs' slots in the top wall stop
3 mm short of the hollow; on the simple chair with first axis Y in 5 mm
stock, each curve rib is slotted up through the seat only, not on up the
back post beside a 3 mm strip, and the back's first-axis rib comes down to
meet it. A part left narrower than the stock somewhere all the same (its
material falls into more pieces when shrunk by half the stock and grown
back, `CurveJointPlanner.narrowerThan`) is named in a note on the CLI and in
the Curve panel ("Parts C-1, C-7 are narrower than the stock in places,
where a slot comes close to an edge or a hole or the model is that thin:
handle them with care, or use thinner stock.") and listed in the
measurement JSON (`thin_parts`). Two joints
on one line whose slots would run into each other — a crossing beside the
inside wall of a hollow, where a line across the slot runs through the wall
from one joint to the next — become one joint over both.

### 3.6 Slot shape

A slot is a rectangle on the crossing line, as wide as

```
(w + t·|cos a|) / sin a
```

for slot width `w`, stock thickness `t` and angle `a` between the two ribs:
a rib crossing at a slant meets this rib's face at an angle and drifts
sideways through its thickness. At a right angle (always, for first axis Z)
that is `w`.

It runs from the meeting point to the rib's edge: past the farthest edge
crossing of nine lines across the slot's width, by 1 mm, but stopping
halfway to material that starts again beyond the edge. Its sides are square
(no mouth flare).

The slots of a rib are cut out of its section with a polygon difference, so
the outline comes back with the slots in it. The rib counts (§ 3.1, § 3.3)
and stops (§ 3.4) keep a web at least as thick as the stock (`slotWeb`,
`max(t, 1 mm)`) between curve-rib slots in a first-axis rib and between
first-axis slots in a curve rib, and the meeting point (§ 3.5) keeps one
between a slot's bottom and the hole or edge beyond it and along the slot's
sides where it can. As a last guard, slots closer than 1 mm
are merged into one wide cut (the union of a rib's slots is closed by
0.5 mm before it is subtracted).

A slot that runs from a hole out through the edge cuts a ring open; two cut
it in two. Each piece the cuts leave that holds material one of the rib's
joints keeps becomes a part of its own (`C-4-1`, `C-4-2`), held by those
joints. Other loose pieces (scrap) are dropped. A piece the cuts take away
whole is dropped, unless it holds joint material: then it is kept uncut and
flagged as an error (red).

Every output uses these slots and pieces (`CurveJointPlanner.Slots`,
`primaryPieces` and `curvePieces`): the cut sheet, Print, DXF / SVG / PDF,
EPS, STL / OBJ and the 3D view.

#### 3.6.1 Pieces nothing holds, and parts joined only among themselves

A piece takes part in a joint when it keeps some of the joint's material:
the middle of a stretch its rib keeps on the crossing line lies in it
(`Joint.primaryPoints`, `Joint.curvePoints`). A piece that takes part in no
joint touches no rib of the other family (ribs of one family never touch),
so nothing would hold it in place: it is left out of every output. The CLI
and the Curve panel say so, naming a rib left out whole and counting the
pieces of one that keeps others ("Y-1, 2 pieces of Y-6 and C-1 cross no
slice of the other family and are left out: nothing would hold them in
place."), and the measurement JSON lists them (`left_out_pieces`). On the
lumpy blob with first axis Z the bottom rib's second lobe lies where the
curve ribs fan in and stop (§ 3.4), and is left out.

The joints join the remaining pieces into groups. The largest group (most
pieces, then most material) is the model; every part of another group is
held together with its own group but not with the rest, and is shown blue
on the cut sheet, with "Not joined to the rest of the model: glue it in
place" in the sheet's part inspector, a note in the Curve panel and on the
CLI's stderr ("N parts are joined to each other but not to the rest of the
model (…) and shown blue on the cut sheet: glue them in place, or try
another 1st axis, fewer slices or thinner stock."), `unjoined_parts` in the
measurement JSON and `"detached": true` in the part frames. The assembly
audit counts them as detached. Before parts are shown blue, first-axis ribs
are moved where that joins them (§ 3.1.1): on the simple chair with first
axis Z the two side curve ribs each run down one leg and, at even spacing,
meet nothing but that leg's four first-axis pieces; with Z-4 moved into the
seat both legs are joined.

### 3.7 Sections

Each rib's section is cleaned before anything is cut from it
(`CurveSliceContourer.cleaned`):

1. Where the plane passes through a hole or crack in the mesh, the section
   comes out as open chains. Starting from a chain, the walk goes on from
   its far end to the nearest end of another chain (the next stretch of
   outline beyond the gap) until its own start is nearer than any other
   chain; then the outline closes. The gap is bridged with a straight edge.
2. Each loop is turned so the model lies on its left, as the triangles it
   was cut from face (up to eight of its edges are matched to the section's
   edges, and each votes; a loop none of whose edges matches is turned by
   how many other loops it lies inside). On a mesh whose triangles wind
   both ways (two triangles that share an edge run it the same way), or
   wind wholly inside out, that can turn a loop the wrong way: when the
   loops do not come out turned as their nesting says (outer boundaries
   counter-clockwise, holes clockwise), the triangles are made to agree
   first: across every edge two triangles share their windings are
   matched, and on each connected patch the way most of its triangles wind
   wins; then, when the mesh so read encloses a negative volume (it faces
   inward, as an inside-out export does), every triangle is read the other
   way round (`MeshWinding`); then the loops are turned again. A mesh whose
   triangles all agree and face out is read as it is. The rib's material is the union of
   the loops (non-zero): shells of the model that overlap or touch give one
   piece, with no hole where they overlap, a cavity whose surface faces into
   it stays a hole, and a loop that touches itself encloses what it
   encloses. The result is clean loops: outer boundaries counter-clockwise,
   holes clockwise. An outline that touches itself at a point (a corner on
   another stretch of the same outline, within 0.00001 mm; bridging a crack
   can leave one) is split there into the two lobes either side, each a
   piece of its own, when neither lies inside the other, whichever way each
   turns (an outline drawn as a figure of eight crosses over at the touch,
   so its lobes turn opposite ways; the smaller is turned like the larger)
   (`CutSheetLayoutBuilder.separatingPinches`); so is a piece the
   slots leave touching itself. Every outline cut is a simple loop.
3. Notches and holes narrower than 1 mm (cracks in the mesh, too fine to
   cut) are filled: the region is grown by 0.5 mm and shrunk back.

### 3.8 Labels and assembly order

- First-axis ribs: `Axis-i` (for example `Y-3`), `Axis-i-k` when the rib has
  several pieces. Curve ribs: `C-i`, `C-i-k`.
- Assembly steps: first-axis ribs first (`Place first_axis_NNN`, receives
  curve-rib slots), then curve ribs (`Insert curve_NNN`, through its sample
  point, along an `n`-point spline). A rib left out whole (§ 3.6.1) has no
  step (`docs/specs/assembly-steps.md` § 2).

## 4. Data structures

`CurveSlicePlan` — the first-axis plan, curve-rib sample points, tangents
and in-plane directions, amplitude, control points, slot width, slot angle,
the model bounds, and the counts asked for when fewer fit
(`requestedSliceCount`, `requestedFirstAxisCount`) with the sentences the
panel and CLI show (`curveCountNote`, `firstAxisCountNote`), and, when
first-axis ribs were moved to join parts (§ 3.1.1), their even positions
(`evenFirstAxisPositions`, `firstAxisMoves`, `firstAxisMoveNote`).
`totalPartCount = N + M`.

`CurveJointPlanner.RibLayout` — each curve rib's reach, and with first axis
Z the side its first-axis slots open toward and where they start, plus
whether every rib stands clear (§ 3.4).

`CurveJointPlanner.Slots` — the joints (`start`, `end`, `meet`, `width`, the
two ribs, and in each rib's section the middles of the stretches it keeps on
the crossing line), the slot rectangles per rib in section coordinates (for a
curve rib, also the rectangles that cut it back to its reach), each curve
rib's reach, per rib the points marking material its joints keep, each rib's
pieces as every output cuts them (`Piece`: outline and holes, severed, the
joints it takes part in, detached) and the layers of the pieces left out
(§ 3.6.1).

Each cut-sheet part carries a `PartPlaneFrame`: where its section
coordinates sit in the model. `--part-frames <file>` writes, beside a
cut-sheet export, each part's map from its DXF coordinates to the model as
imported, and `"detached": true` for a part shown blue, so a checker can put
the parts back and test the joints (`SLOTS-MATE`, `PARTS-JOINED` in the
functional gate). Under a Slice Direction tilt the parts are cut from the
model turned into the slicing frame, and the frames turn them back
(`MeshScaler.unrotating`), so they are checked against the model file
itself.

## 5. Edge cases

- **Fewer than 2 curve slices, fewer than 2 control points, zero extent
  along the spline or no bounds**: no plan.
- **More than 600 ribs in total**: the GUI shows no plan.
- **Spline leaving the model**: curve ribs whose plane misses the model have
  no section and produce no parts or joints.
- **A slice plane through a ring of mesh vertices**: each mesh edge lying in
  the plane is traced once (only the triangle below the plane emits it).
- **More ribs than fit**: fewer are cut (§ 3.1, § 3.3), down to one of each.
- **A spline that bends both ways** (`--spline-control-points`): ribs near
  the bend close in on neighbours on both sides. With first axis Z one
  neighbour stops alone where it can; otherwise, and where a rib's slots
  would close in on another rib's line, fewer ribs are cut. On the 50 mm
  sphere an S-shaped spline leaves two curve ribs with first axis Z.
- **Hollow and concave models**: joints beside a hollow's inside wall become
  one joint over both walls (§ 3.5); a slot that cuts a ring in two leaves
  two parts, each held by its joints (§ 3.6).
- **Open or cracked meshes**: sections are closed across the gaps (§ 3.7).
- **Shells that overlap** (two cubes run into each other): each section is
  the union of the shells' outlines, one part per rib (§ 3.7).

## 6. Output

| Output | Slots from |
|---|---|
| GUI cut sheet, Print, DXF / SVG / PDF / EPS (app and CLI) | the cut sheet's parts, slots cut in; DXF and EPS the right way up, one EPS per sheet |
| STL / OBJ | the slotted sections extruded to the stock thickness (app and CLI): `first_axis_NNN`, `curve_NNN` |
| Measurement JSON (CLI `--measurement`) | `curve_slices`: the plan, counts asked for and cut, and `unjoined_part_count`, `unjoined_parts` (shown blue), `left_out_pieces` (§ 3.6.1), `thin_parts` (§ 3.5) and, when ribs were moved, `first_axis_moves` (§ 3.1.1) |

## 7. Worked example

50 mm cube centred on the origin, CLI defaults (`--thickness 5`, first axis
Z, 7 first-axis ribs and 12 curve ribs asked for, amplitude 10):

- Seven first-axis ribs would be 7.1 mm apart; with 5 mm slots that leaves
  2.1 mm between them in a curve rib, so five are cut (§ 3.1), 10 mm apart:
  `z = −20, −10, 0, 10, 20`.
- Control points `(−25, 0), (0, 10), (25, 0)`. Twelve curve ribs would stand
  4.5 mm apart; five stand far enough apart for a 5 mm web between their
  slots (§ 3.3): at `(−20.16, 2.45)`, `(−10.44, 7.29)`, `(0, 10)`,
  `(10.44, 7.29)`, `(20.16, 2.45)`.
- Slot width 5 mm. Each crossing line is horizontal and runs along its curve
  rib, so every slot is 5 mm wide: the Z ribs are slotted toward the
  spline's convex side (+n), the curve ribs from the other side, at the Z
  ribs' heights.
- Cut sheet: 10 parts, `Z-1` … `Z-5` and `C-1` … `C-5`.
- In 3 mm stock seven first-axis ribs fit (7.1 mm apart) and eight curve
  ribs (15 parts), at `(−21.95, 1.49)`, `(−15.96, 4.67)`, …, each clear of
  the others, cut short on the spline's concave side (−y).

With `--axis y` the first-axis ribs become XZ planes and the joints are
vertical; slots in ribs that cross at a slant are wider than 5 mm.

## 8. Known issues

- **Short curve ribs on a tight bend.** Where the spline bends sharply the
  curve ribs stop close to it on its concave side (§ 3.4), so that side of
  the model is carried by the first-axis ribs alone. Fewer curve ribs, a
  gentler spline or thinner stock let them reach further.
- **Thin webs the slots cannot avoid.** Where a joint is too short for a
  stock-thick web on both sides of the meeting point, or a crossing line runs
  along the model's edge closer than the stock, the webs are thinner (down to
  1 mm), and the parts are named in a note (§ 3.5): on the hollow box with
  first axis Y the end curve ribs keep 2 mm strips beside the slots that cut
  their rings open, and on the simple chair in 5 mm stock the end curve
  ribs' seat strips are 4 mm over the slots, the legs' first-axis pieces
  keep 4 to 5 mm strips beside slanted slots, and with first axis Y the outer
  ribs through a back leg keep a 2 mm strip of the leg beside their slot.
- **Parts joined only among themselves.** The joints can hold a group of
  parts together but not to the rest (§ 3.6.1). Moving a first-axis rib
  (§ 3.1.1) joins the simple chair's legs with first axis Z, but not, with
  first axis Y in 5 mm stock, the torus, the spur gear and the lumpy blob,
  where the curve ribs that reach the low first-axis ribs stop short of the
  high ones and the rest the other way.
  Curve ribs are not moved, and the rib counts (§ 3.1, § 3.3) do not look
  for such groups. They are shown blue; another first axis, fewer curve
  slices or thinner stock join them.
- **Few ribs in thick stock on small models.** The stock-thick web (§ 3.6)
  leaves room for few ribs on a 50 mm model in 5 mm stock (five of each with
  first axis Z, fewer with Y or X, whose slanted crossings take wider
  slots).
- **Slicing planes on a flat face.** A first-axis rib whose plane lies on a
  flat face of the model (the low-poly head's neck top, in 5 mm stock) runs
  its crossing lines along that face, where the model's material on the line
  is ambiguous; such joints can fail the gate's check.
- **Assembly order** is not checked: a joint is checked where the parts end
  up, not that every part can be slid into place in turn. Rings cut in two
  (§ 3.6) and joints on both walls of a hollow may need parts fitted in a
  particular order.
- **Slice Direction and STL / OBJ.** Under a tilt every part is cut from the
  model turned into the slicing frame (`docs/specs/ui-workflow.md`), and the
  STL / OBJ meshes are written in that frame: the whole assembly comes out
  turned by the tilt, where the viewport turns it back onto the model. The
  part frames (§ 4) are turned back too: they map to the model as imported.
