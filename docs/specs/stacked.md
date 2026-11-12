# Stacked Slices — behavioral spec

> Status: describes Stacked mode as Refab Artist implements it. Where this
> spec and the code disagree, one of them has a bug; fix whichever is
> wrong and keep them in step. Section numbers are stable so the other
> mode specs can refer to them.

---

## 1. Scope

**Stacked Slices** is the simplest construction mode. The model is cut
by a set of parallel planes along one axis (the *slice axis*). Every
plane gives one flat layer, and each layer becomes one or more flat
parts cut from sheet material. Glued on top of each other in order, the
parts rebuild the model as a terraced solid.

### What Stacked produces, end to end

1. A **slice plan**: the axis and the positions of the slice planes
   along it (§3.1).
2. One **contour layer** per plane: the outline of the model in that
   plane, as closed loops; on a cracked mesh the open fragments are closed
   across the cracks (§3.2).
3. **Parts**: each layer split into its separate pieces, each piece an
   outer loop plus the holes inside it (§3.3).
4. Optional **dowel holes**: rods that thread the whole stack, with a
   hole in every part whose material the rod passes through (§3.4).
5. **Assembly guides**: red lines scored on each part that show where
   the next layer sits (§3.5).
6. **Labels**: the layer number engraved inside every part (§3.6).
7. A **cut sheet**: every part packed onto sheets of the chosen size
   (§3.7), which is what the preview, Print, and the SVG/PDF/DXF cut-sheet
   exports show.

---

## 2. Settings

All lengths are millimetres.

### 2.1 Slicing

| Setting | Default | Meaning |
|---|---|---|
| Material thickness | 3 mm (GUI) | Thickness of the sheet stock. With automatic distribution it is also the spacing between slice planes. |
| Slice axis | Z | The axis the planes are stacked along (X, Y or Z). Each layer is drawn in the plane of the other two axes (X slices use (Y, Z), Y slices use (X, Z), Z slices use (X, Y)). |
| Distribution | Automatic | How plane positions are chosen: Automatic, By Count, By Distance, or Custom (§3.1). |
| Slice count | — | By Count only: the number of planes (1 to 240). |
| Slice spacing | — | By Distance only: the target spacing between planes. |
| Custom positions | — | Custom only: the exact plane positions the user edited. |

### 2.2 Dowels

| Setting | Default | Meaning |
|---|---|---|
| Dowels on/off | off | Whether to cut dowel holes. |
| Diameter | — | Rod diameter. |
| Edge inset | — | Minimum distance from a hole to a part edge. |
| Shape | round | Round holes are cut as circles; the other shapes are cut as closed outlines. |
| Count | 2 | How many rods automatic placement stands. |
| Manual positions | none | Rods the user placed by hand; when present they replace automatic placement. |

### 2.3 Sheet layout

| Setting | Default | Meaning |
|---|---|---|
| Sheet width × height | 600 × 300 mm (GUI) | Size of each sheet of stock. With no sheet size, parts go on one unbounded sheet. |
| Part spacing | 10 mm | Gap between neighbouring parts. |
| Page margin | 10 mm | Empty border around each sheet. |

---

## 3. Behavior

### 3.1 Slice positions

Let `lo` and `hi` be the model's extent along the slice axis and
`span = hi - lo`. If the span is zero, or the thickness or spacing is not
a positive finite number, there is no plan.

**Automatic** (spacing `d` = material thickness):

1. `n = max(1, floor(span / d))`.
2. The plane grid has pitch `d`. Its index-0 plane sits at
   `base = (lo + hi) / 2 - (n + 0.5) * d / 2`.
3. Planes `i * d + base` are kept for every integer `i` from
   `ceil((lo - base) / d + 0.1)` to `floor((hi - base) / d + 0.1)`.

The result is a stack centred on the model's middle, a quarter of a
slice off-centre, with no plane outside the model.

**By Count** (`N` planes): plane `k` (from 0) sits at
`lo + span * (k + 0.5) / N`, so the planes divide the span into `N`
equal bands and sit in the middle of each.

**By Distance** (spacing `s`): By Count with
`N = max(1, min(floor(span / s), 240))`.

**Custom**: the user's positions, sorted, clamped to `[lo, hi]`, and with
duplicates closer than 1e-6 mm merged.

Layers are numbered from 1 in increasing position along the axis.

### 3.2 Contours

Every triangle that crosses a plane contributes one line segment (where
the plane cuts it). The segments are joined end to end into paths. A
chain that comes back to its start is a closed loop. A chain that cannot
be closed, because the mesh has a gap there, stays an open path. Where
more than two segments meet at a point, the join continues along the
straightest one. Where two pieces of the model meet at a corner, that can
join them into one outline that crosses over at the corner (a figure of
eight), split again below.

What Stacked cuts has no open path: a layer's open chains (where the plane
crosses a crack or hole in the mesh, as on a cracked scan) are joined end to
end, nearest ends first, into closed outlines across the gaps, as Curve
Slices closes its sections (`StackedSliceContourer.closingCracks`). Each
outline so closed is made simple: a knot where it crosses itself is cut off
(the larger side kept) and lobes that touch at a point are split apart; one
that encloses no area is dropped. Nor does it cut an outline that pinches:
a closed loop that touches itself at a point, its lobes lying outside each
other (the figure of eight above, whose lobes turn opposite ways), is split
there into the lobes, each a piece of its own, the smaller turned like the
larger (`CutSheetLayoutBuilder.separatingPinches`); a hole that touches the
outline stays part of it. Every other closed loop, and a layer with no open
chain and no pinch, is kept as it is. The cut sheet, every export (vector and
mesh) and the dowel layout use these closed layers: the dowel holes drilled,
the viewport's dowel rods and edit markers, the automatic positions manual
editing starts from, and `--dowel-audit` all come from them, so on a cracked
scan the rods sit in the holes. The viewport's slice preview shows these
closed layers too (`ViewportGeometryCache.stackedSolidMeshes`), as do the
slice picking and the slice profile of slice editing.

### 3.3 Parts

A layer's closed loops (already free of pinches, § 3.2) are sorted into
pieces. A loop inside an even
number of other loops is an *outer* loop and starts a piece. A loop inside
an odd number is a *hole* and goes to the smallest outer loop that
contains it. Open fragments go to the piece whose outer loop contains
their first point, or to the first piece if none does. A layer with no
closed loops at all becomes a single piece that carries only the open
fragments.

Pieces too small to cut or assemble are dropped: an outer loop under
1 mm² in area, or under 1.5 mm in its largest dimension. Pieces are
ordered largest area first. A layer with one piece labels it with the
layer number (`7`); a layer with several labels them `7-1`, `7-2`, …

### 3.4 Dowels

Dowels are rods that run through the whole stack, so a rod's hole has
to sit at the same plane position in every layer. Automatic placement
stands each rod where it passes through the most layers' material while
keeping the edge inset, and keeps the rods well apart (the separation
relaxes if the model cannot fit the requested count). A part gets a hole
for each rod whose position lies inside its outer loop.

### 3.5 Assembly guides

**Purpose.** Each layer has to be glued onto the one below it in the
right place. Where the next layer's edge lands close to the current
part's edge, the edges themselves show the alignment. Where the next
layer steps well inside the part, nothing on the part shows where it
goes. Guides fill that gap: red lines, scored and never cut, that trace
the next layer's outline on the part it sits on.

**Inputs.** The layers in stack order, and a clearance `d`: the spacing
between the first two slice planes (with automatic distribution, the
material thickness). With fewer than two layers, or `d = 0`, there are
no guides.

**Rule.** Guides on layer `i` trace layer `i + 1`. The last layer has
none.

1. *Fill area of layer `i`.* Every path of layer `i` with at least three
   distinct points is taken as a closed ring; an open path is closed by
   joining its two ends. The fill area is the union of the rings'
   interiors. Holes are not subtracted: a ring inside another ring adds
   nothing.
2. *Guide zone of layer `i`.* The fill area with every edge of its
   boundary moved inward by `d`, so every point of the zone is at least
   `d` from the boundary. At a concave corner of the outline the two
   moved edges are extended until they meet: the zone keeps a sharp
   corner there instead of rounding it, and a guide stops on the line
   `d` inside the edge it runs towards (at a right-angle corner, up to
   `d·√2` from the corner itself). Where the moved edges would meet more
   than `2d` from the outline's corner (a notch narrower than 60°), the
   zone is cut straight across the notch instead, `d` beyond its tip.
   Any part of the fill area narrower than `2d` leaves no zone. A point
   within 1e-4 mm of the zone's edge counts as inside, so an edge that
   steps in by exactly `d` is traced in full rather than in fragments.
3. *Guides.* Every path of layer `i + 1` — closed loops, holes and open
   fragments alike — is cut against the zone. The pieces inside the zone
   are the guides. An open fragment is traced as the polyline it is; the
   join that closed it for the zone in step 1 is not a cut edge and is
   not traced. Paths with fewer than three distinct points (the
   single-segment crumbs a broken mesh leaves behind) are not traced.

The zone depends only on the shape of layer `i`, not on where its paths
start or which way they wind.

**What that looks like.**

- Identical consecutive outlines (a cube, a cylinder): no guides.
- The next layer is larger (the lower half of a sphere): no guides.
- The next layer steps in by less than `d` all round: no guides. On a
  50 mm sphere at `d = 3` (16 layers), layer 14 steps in about 2.5 mm
  from layer 13, so 13 carries no guide; layer 15 steps in about 3.5 mm
  from layer 14, so 14 carries layer 15's whole outline, and 15 carries
  layer 16's.
- Organic outlines get partial guides: only the stretches where the next
  layer steps in by more than `d`. Each such guide ends `d` inside the
  part's edge.
- Holes in the next layer are traced wherever they fall inside the
  zone. Because only the outer edge limits the zone, a hole is traced
  even where it lines up with a hole in the current part (a hollow box:
  every layer with a cavity carries the next cavity's outline on its own
  cavity edge), and even where it falls inside the current part's hole
  (the bottom layers of a torus, where the next layer's hole is
  smaller). The layer below the first cavity layer carries the cavity's
  outline, since the cavity's walls are well inside its edge.
- A feature narrower than `2d` carries no guides, even where the next
  layer's edge crosses it (a 5 mm-wide nose at `d = 5`).
- A guide never comes closer than `d` to the part's outer edge (less
  the tolerances in step 2).

**Output schema.** For `L` layers the result is `L` lists, one per layer,
each a list of polylines (`[[[Vec2]]]`). Points are in the same plane
coordinates as the layer's contours.

- A next-layer loop that lies wholly inside the zone comes back whole:
  a closed polyline that starts at the loop's first vertex, follows the
  loop's direction, and repeats the first point at the end.
- A path that leaves the zone comes back as open polylines, each
  following the source path's direction, made of the source vertices
  that lie inside plus the points where the path crosses the zone's
  edge. On a closed loop, the piece that runs through the loop's first
  vertex is returned as one polyline, not two.
- Pieces with no length are dropped.
- Polylines are ordered by the next layer's path order, then by where
  they start along the path; a loop's piece that runs through its first
  vertex comes last.
- The last layer's list is always empty.

The computation is deterministic: the same layers give the same guides,
point for point.

**On the cut sheet.** A guide belongs to each part whose outer loop
contains the guide's first point (on a layer with no closed loops, the
single part owns them all). Guides are drawn red: `#FF0000` strokes in
the SVG, red strokes in the PDF and the preview, and layer
`<part label>_guide` in the DXF. They also count toward the part's
bounding box when the part is placed, though in practice they lie inside
it.

### 3.6 Labels

Each part's label is placed at the point inside the part farthest from
any cut line (outer loop and holes), found on a coarse grid and refined
once. Its size follows the clearance at that point, so a label never
runs over an edge.

### 3.7 Sheet layout

Parts are packed onto shelves, largest dimension first. Each part tries
its landscape orientation first, then the part turned 90 degrees:

1. It goes on the existing shelf (on any sheet) that has room and wastes
   the least shelf height.
2. Otherwise a new shelf opens under the last shelf of the first sheet
   with room left, adding sheets as needed.
3. A part that fits no sheet at all gets a sheet of its own and is
   flagged as overflowing.

---

## 4. Data structures

| Type | Holds |
|---|---|
| `StackedSlicePlan` | axis, material thickness, model extent, plane positions, custom positions (if any) |
| `SliceContourLayer` | plane position and the layer's paths (`SlicePath2D`: points plus a closed flag) |
| `StackedSliceContours` | axis and the layers in stack order |
| `CutSheetDocument` | sheets of placed parts; each part has cut loops, open cuts, guide lines, dowel holes, label anchor and size, and flags (error, detached, overflow, rotated) |

---

## 5. Edge cases

| Input | Behavior |
|---|---|
| Empty mesh or zero extent along the axis | No plan, no parts. |
| Open mesh (gaps in the surface) | Layers that cross a gap are closed across it (§3.2), so every part is a closed outline. On the lumpy blob cracked open at its poles (`tests/fixtures/pathological/lumpy_blob_open_poles.stl`) in 3 mm stock, layers 1–3 and 17–20 cross the cracks and come out as one or two closed pieces each. For guides, every path counts as a ring (§3.5). |
| Hollow model (internal cavity) | Layers through the cavity have a hole; the cavity's outline is traced as a guide on the layer below it and on each cavity layer (§3.5). |
| Several bodies or a layer that splits into pieces | One part per piece, labelled `layer-piece`. |
| Slivers | Pieces under 1 mm² or 1.5 mm across are dropped (§3.3). |
| Thin features narrower than the slice spacing | May fall between planes and disappear. |
| Very many planes | The GUI refuses plans above its slice-count limit. |

---

## 6. Output structure

For each layer, Stacked emits:

| Entity | Form | Purpose |
|---|---|---|
| Outline | closed loop per piece, blue | cut path for the part's silhouette |
| Holes | closed loops inside the outline, blue | cut paths for the part's holes |
| Open fragments | open polylines, blue | only where a layer's chains could not be closed at all (§3.2); none on a cracked mesh |
| Dowel holes | circles or closed outlines, blue | rod holes (§3.4) |
| Assembly guides | polylines, red | where the next layer sits (§3.5); scored, not cut |
| Label | text at the part's most open point | layer number, or `layer-piece` |
| Sheet boundary | rectangle per sheet | the stock outline |

---

## 7. Worked examples

**Slice positions.** A 50 mm cube centred on the origin, sliced along Z
with `d = 5`: `n = 10`, `base = -26.25`, and `i` runs from
`ceil(0.25 + 0.1) = 1` to `floor(10.25 + 0.1) = 10`. The planes sit at
**-21.25, -16.25, -11.25, -6.25, -1.25, 3.75, 8.75, 13.75, 18.75,
23.75 mm**: ten 50 × 50 mm squares. With the GUI default `d = 3`:
`n = 16`, `base = -24.75`, sixteen planes from -21.75 to 23.25 mm.

**Assembly guides.**

| Model (`d = 3`) | Layers | Guides |
|---|---|---|
| 50 mm cube | 16 | none (every layer matches the next) |
| 50 mm sphere | 16 | layer 14 carries layer 15's circle, layer 15 carries layer 16's; nothing below |
| Torus, R 30 / r 10 | 6 | the next layer's hole on layers 1–5 (on layers 1 and 2 it lies inside the part's own, larger hole); the outer rings step in by less than 3 mm, so none |
| 50 mm box with a 30 mm cavity | 16 | the cavity square on the layer below the cavity and on every cavity layer except the last |
| Lumpy blob cracked open at its poles (`pathological/lumpy_blob_open_poles.stl`) | 20 | guides on layers 12–17 and on piece 19-1; the layers through the cracks are closed across them (§3.2), layers 1, 18 and 19 into two pieces each |
