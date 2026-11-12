# Folded Panels — spec

**Folded Panels** does not slice. It treats the model's surface as a set of
flat **panels** (faces of the model: triangles in one plane joined edge to
edge), unfolds them into one or more flat **nets** by hinging neighbouring
panels about their shared edges, cuts each panel back where its stock would
run into a neighbouring piece's, and adds **joinery** to the cut edges that
have to be joined again after folding. Cutting a net out, folding along its
fold lines and joining the cut edges rebuilds the model as a shell of the
stock, its outside on the model surface.

Sources: `FoldedPanels.swift` (joinery parameters, planner, unfolding,
stock cut-back, outlines, perforation), `FoldedJoinery.swift` (where two
panels' stock meets, the joint features), `PlanarBoolean.swift`,
`FoldedPanelPreview.swift`, `MeshSimplifier.swift`
(`FoldedMeshPrecleaner`), `CutSheetDocument.swift`,
`CutSheetDocumentExporter.swift` (DXF, SVG, PDF, EPS, part frames).

---

## 1. What the mode produces

1. **Panels** — one per face of the model: triangles in one plane, facing
   the same way, joined edge to edge (§ 3.1).
2. **Nets** — connected, non-overlapping groups of panels laid flat, each
   small enough for the sheet, joints included.
3. **Fold lines** — where two panels of a net are joined by a bend in the
   stock, drawn on their own layer as perforation dashes or full lines.
4. **The stock** — every panel is a piece of stock behind its net, on the
   inside of the model surface. Where two pieces meet at a cut edge (a
   **seam**), one is cut back so it rests on the other instead of running
   into it (a butt joint); pieces that would still run into each other
   elsewhere (at a corner of the model, past a seam's ends, across a hollow)
   have that part cut away (§ 3.4.0).
5. **Joinery** — features on the two copies of every seam (a protrusion on
   one copy, a matching slot or notch on the other, or matching features on
   both), placed so the joint closes when the net is folded up (§ 3.4).
6. One labelled cut-sheet part per net.

## 2. Parameters

### 2.1 Joint type and its parameters

| Parameter | GUI | CLI | Default | Used by |
|---|---|---|---|---|
| Joint Type | Technique Settings → Joint Type | `--joinery-type` | GUI Diamond; CLI Tab | § 3.4 |
| jointSpace | per-type row (Joint Space) | — | 25.4 mm (Multitab, Puzzle presets: 12.7 mm) | Multitab tab pitch, Rivet pinned-tab pitch, Laced hole pitch |
| tabFraction | per-type row | — | 0.45 | Multitab tab width (fraction of jointSpace) |
| toothScale | per-type row (Tooth Scale) | — | 0.1 | How far Gear fingers stand proud of the other panel's outside face (fraction of tickSpace) |
| holeRadius | per-type row | — | 1.5875 mm | Rivet pin hole, Laced hole radius |
| tickRadius | per-type row | — | 1.5875 mm | Tab, Diamond, Tongue and Puzzle size; how far a protrusion stands past the far face; the material a lug keeps round its slot; the material every hole and notch keeps to the panel's edges |
| seamRadius | per-type row | — | 2.54 mm | Ticked notch width and depth |
| tickSpace | per-type row | — | 25.4 mm | Ticked notch and Gear finger pitch |
| Perforate | Technique Settings → Perforate | — | on | § 3.4.14 |

Choosing a joint type loads its preset. All values are clamped to sane ranges
(lengths 0.01–100 mm, spacings 0.1–500 mm, fractions 0.01–1) before use.
`toothRadius` (2.54 mm) is still read from project files but no longer
used: Gear fingers pass through open notches where the stock meets
(§ 3.4.6).

### 2.2 Shape and sheet parameters

| Parameter | GUI | CLI | Default | Effect |
|---|---|---|---|---|
| Detail / Vertex Count | Technique Settings (12–2000 faces) | `--folded-target-faces` | GUI 250; CLI none | Models with more faces are simplified to this budget first (§ 3.0). |
| Split Panels | Technique Settings | — | off | Halves the usable net extent in both directions, so nets split into smaller pieces. Disabled, with a note, when every net already fits in half a sheet. |
| Seams | 3D view, seam edit mode | — | none | User-chosen mesh edges that must be cut, never folded. |
| Thickness | Manufacturing Settings | `--thickness` | GUI 3 mm; CLI 5 mm | The stock: how far panels are cut back at seams (§ 3.4.0), the joints' sizes, perforation dash length. |
| Slot Offset | Manufacturing Settings | `--slot-clearance` | GUI 0.254 mm; CLI 0 | Added to every slot and open notch a protrusion passes through (half each side, across and along the seam) so protrusions fit after the cutter's kerf: Tab, Diamond, Multitab, Tongue, Rivet, Gear and Puzzle. Laced holes, Ticked notches and None cut no such slot and do not read it; for them the row is greyed out with a caption, and the assembly guide leaves the slot clearance out. |
| Sheet size, margin | Manufacturing / Export settings | `--sheet-width`, `--sheet-height`, `--page-margin` | 600 × 300 mm, 10 mm | Usable net extent = sheet minus both margins; nets and their joints stay within it. |

### 2.5 Parameters with no effect

Notch width and angle, slice counts, Slice Direction, dowels and Tool Dia.
do not apply to Folded Panels. Manufacturing Settings leaves Tool Dia. out in
this mode.

## 3. Decision logic

### 3.0 Simplification

When the model has more faces than the Detail budget, it is sealed,
repaired and simplified with Manifold, searching the simplification
tolerance until the face count is at or under the budget. Each remaining
face becomes (part of) a panel. The GUI refuses models above 2,000,000
faces before simplification is attempted.

### 3.1 Panels

First the triangles' windings are made to agree: across every edge two
triangles share they must run it in opposite directions, so a triangle
wound against its neighbours is turned over, and each connected piece of the
mesh is turned to face out (to enclose a positive volume). A mesh with some
faces wound the wrong way round therefore still knows which side of every
panel is outside.

Each triangle's plane is described by its unit normal (flipped so its first
non-zero component is positive) and its offset, rounded to 1e-6. Triangles
with the same rounded plane that face the same way and are joined edge to
edge form one panel; two faces in the same plane that share no edge (two
legs of a chair seen side by side), or that lie back to back, are separate
panels. The panel's boundary loop is traced from its triangles. Its
**outside** is the side its triangles' windings point to; its stock lies on
the other side. Degenerate triangles (normal length ≤ 1e-7) are skipped.
Panels are ordered by their lowest source-triangle index.

Two panels are **adjacent** when they share a mesh edge (vertices matched at
1e-6 mm) that no third panel uses. A user seam removes that edge from the
adjacency, so it is always cut.

### 3.3 Unfolding into nets

Nets are grown breadth-first, starting from the lowest-numbered panel not yet
placed:

1. Each panel is given an isometric 2D embedding in its own plane, its
   outside face up.
2. A neighbour is placed by the rigid motion that lays its copy of the shared
   edge onto the parent's copy, on the side away from the parent's interior —
   the shared edge becomes a fold line.
3. A neighbour is **not** placed in this net if it would overlap a panel
   already in the net, or if the net would then exceed the usable sheet
   extent. It waits for a later net (it may still join this net through
   another neighbour).
4. When no more neighbours fit, the net is closed and a new one starts.

Every panel lands in exactly one net. Each placed panel records its
**frame**: the map from net coordinates to where it sits on the model once
the net is folded up.

### 3.4 The stock and the joinery

#### 3.4.0 Where the stock meets

Every panel is a piece of stock of thickness `t` behind its net: its outside
face on the model surface, the stock on the inside of the model. Panels
joined by a fold line are one piece bent there (the stock must be able to
bend: card, thin sheet, a perforated or kerf-cut crease). Every other edge of
a net is cut. A model edge cut into exactly two copies is a **seam**; the
first copy (in net, then panel order) is **male**, the second **female**.

**The seam band.** Seen in section across a seam, the two pieces are two
strips of stock that leave the seam point in their own directions. Extended
past their edges they cross in a parallelogram that touches the seam point.
The band measures it from each copy's edge line, positive into the panel:
`maleNear … maleFar` across the male panel, `femaleNear … femaleFar` across
the female panel (`FoldedSeamBand`). For a square seam (a cube edge) both
run from 0 to `t`; for panels meeting at angle `θ` between their normals
(convex, θ ≤ 90°) `maleFar = t / sin θ`, `maleNear = −t cot θ`; at an inside
corner (where the two strips part) both lie at or past the edges.

**Butt joints.** The female copy keeps its edge on the model surface. The
male copy is cut back, along the whole edge, by its **trim**: the farthest
point, measured across the male panel, of the part of the parallelogram that
lies inside the female piece. Its end then rests on the female panel's
inside face instead of running into it: `t` for a square seam (a closed
corner), `t sin θ` for a flatter convex seam (a small groove is left at the
outside corner), `t tan(θ/2)` for a sharper one, 0 at an inside corner. A
seam that takes a through-slot joint is cut back past the whole band
(`maleFar`), clear of the female copy's lug.

The strip cut away runs along the edge and is ended by the lines of the
panel's neighbouring edges, so the panel's corners are cut square to its own
edges.

**Corners and hollows.** Pieces can still run into each other where no seam
clears them: panels that meet only at a corner of the model (opposite faces
of a pyramid at its apex), past the ends of a seam, or across a hollow of
the model. For every pair of pieces whose stock meets and that no fold
joins, the part of one piece's stock that lies in the other's (the region of
its net, seen square-on, where a column through its stock meets the other
piece's stock) is cut away from it: from the male copy's panel for a seam's
two panels, else from the later panel. Where that part lies inside the
panel, away from its edges (the stock of a thin tooth's far flank reaching
into the middle of the panel beyond it), the panel gets a hole there. Stock
that only touches another piece's face does not count. Parts of a panel left
narrower than 0.2 mm (a cut's width) go too. Each region is worked out
exactly from the two pieces' shapes and stock, whatever the numerical
rounding of their corners.

**Panels the stock leaves out.** A panel whose stock all lies where other
pieces' stock already is (a sliver between bigger panels, or a face of a
part of the model thinner than twice the stock) is left out. The plan counts
the panels left out and those cut back to less than half their area
(`FoldedStockCensus`); the Folded panel and the CLI say so ("3 of 172 panels
are left out and 12 panels are cut back to less than half their size: in
5 mm stock they sit where their neighbours' stock already is. Thinner stock,
or a lower Detail for bigger panels, keeps more of them."). The measurement
JSON gives the counts under `folded_panels.stock`. The plan names the panels
left out (`FoldedPanelPlan.leftOutPanels`, indices into its panels), and they
have no assembly step.

**Folds the stock takes away.** A fold whose two panels no longer share at
least 0.2 mm of it after the cut-back, or that the finished outline does not
keep, joins nothing: its two panels are two pieces, which must keep clear of
each other like any other two, and they are cut back again without it.

#### 3.4.1 Joints in general

A seam gets its joint only when the joint type's feature width × 3 is less
than both copies' lengths. Features are placed in each copy's edge frame:
along the edge from its start, and outward (past the edge) or inward (into
the panel), measured from the copy's edge line on the model surface; the
male copy's cut-back edge is at `−trim`. Both copies of a seam have the same
length and band, so they keep the same joints at the same places along it.

Feature width per type: Tab, Diamond, Tongue, Puzzle `4 × tickRadius`;
Multitab `jointSpace × tabFraction`; Rivet `2 × (holeRadius + tickRadius)`;
Gear `tickSpace / 2`; Ticked `seamRadius`; Laced `2 × holeRadius`; None 0.

The joints that pass a protrusion through the female panel's stock
(through-slot: Tab, Diamond, Multitab, Tongue, Rivet; through-notch: Gear,
Puzzle) need panels meeting at 30° (`flattestSlotAngle`) or more: on a
flatter seam the protrusion would run almost along the other panel through a
slot several thicknesses long. Through-notch joints also need the female
piece's stock to reach where the protrusion passes (not at an inside corner).

**Joints must fit.** A seam gets its joint only where both halves fit:

- nothing standing out past an edge (tab, tick, tongue, finger, neck, lug)
  overlaps a panel of its net or a joint already placed there, and it keeps
  0.5 mm of stock to them so a cut separates them;
- folded up, nothing standing out of a panel runs into any piece's stock
  but its mate's (which is cut for it);
- what stands out meets its panel along its whole base;
- what is cut into a panel (the inner part of a slot, a hole, a notch) lies
  inside the cut-back panel and keeps `tickRadius` of stock to the panel's
  other edges, to the other joints' cuts and, in the finished net, to the
  outline;
- the net, joints included, stays within the usable sheet extent.

Seams are tried in mesh-edge order; a seam whose joint does not fit stays
plain (and its male copy needs only the plain cut-back).

**The plan says how many edges got the joint.** For every joint type that
adds something to the edges (all but None) the plan carries a census
(`FoldedJointCensus`): the seams, how many got the joint, and why each other
one stayed plain: too short, too flat for a slot, no room on the net, or at
an inside corner (open-notch joints). The Folded panel shows it under Joint,
in orange with a warning sign when no edge got the joint, and adds "Lower
Detail for longer edges." when some were too short, so a joint type that
fits few or no edges of the model is never a silent no-op. The CLI prints the
same as a note on stderr when any edge stays plain, and the measurement JSON
gives the counts under `folded_panels.joints` (`cut_edges`, `joined`,
`too_short`, `too_flat`, `no_room`, `inside_corner`). On the cube every one
of the 7 seams gets the joint.

#### 3.4.2 None

No features: every seam stays a plain butt-jointed edge to glue or tape. The
Folded panel says so under Joint. (CLI `--joinery-type none`; the older
spellings `trivial` and `seam` mean the same.)

#### 3.4.3 Seam

No longer offered: it cut nothing of its own. A project or CLI run that asks
for Seam gets None.

#### 3.4.4 Feature spacing

Repeating types place `max(1, ⌊edge length / pitch⌋)` features at the pitch,
centred on the edge midpoint, and drop any feature that would reach past
either end of the edge (for through-slot joints, with its lug).

#### 3.4.5 Ticked

Both copies: V-notches `seamRadius` wide and `seamRadius` deep into the
panel, the male copy's from its cut-back edge, at `tickSpace` pitch, at the
same places along the seam on both copies: they line the edges up for
gluing or taping.

#### 3.4.6 Gear

A finger (box) joint. Male: rectangular fingers `tickSpace / 2` wide at
`tickSpace` pitch, from the cut-back edge through the band and
`toothScale × tickSpace` past the female panel's outside face. Female: open
notches through its edge where the fingers pass (`femaleFar` deep, plus Slot
Offset), so the female panel's own fingers fill the corner between them.

#### 3.4.7 Tab

Male: one rectangular tab at the edge midpoint, `4 × tickRadius` wide, from
the cut-back edge (`maleFar` in from the model surface) to `tickRadius` past
the female panel's outside face. Female: a **through-slot**, a rectangle as
long as the tab is wide and covering the band (`femaleNear … femaleFar` in
from its edge), plus Slot Offset; the slot reaches the female copy's edge
line, so the copy grows a **lug** past its edge around it, `tickRadius` of
stock beyond each end of the slot and past its outer wall. With the preset
on a square seam in 3 mm stock: the male copy cut back 3 mm, a 6.35 ×
4.5875 mm tab, a 6.35 × 3 mm slot from the edge line 3 mm into the female
panel, and a 9.525 × 1.5875 mm lug; the tab passes through the female
panel's 3 mm of stock and stands 1.5875 mm out of its outside face.

#### 3.4.8 Multitab

As Tab, repeated at `jointSpace` pitch (§ 3.4.4) with tab width
`jointSpace × tabFraction`. Lugs that would touch merge into one lug; tabs
(and their slots) that touch, at `tabFraction` 1, merge into one tab and one
slot.

#### 3.4.9 Tongue

Male: a rounded tongue `4 × tickRadius` wide — straight sides from the
cut-back edge to `tickRadius` past the female panel's outside face, capped by
a semicircle (8 chords). Female: an obround through-slot round the band, its
round ends (4 chords each) beyond straight sides as long as the tongue is
wide, so the tongue's full width passes; on a lug that keeps `tickRadius`
round it.

#### 3.4.10 Rivet

A pinned tab: a tab `2 × (holeRadius + tickRadius)` wide at `jointSpace`
pitch, through a slot on a lug as for Tab, long enough to carry a pin hole
(`holeRadius`, 16-gon) whose inner edge is on the female panel's outside
face, with `tickRadius` of stock beyond it. A rivet, pin, split pin, brad or
cable tie through the hole locks the tab: the pin bears on the female
panel's outside face and the male panel's end on its inside face.

#### 3.4.11 Laced

Both copies: holes (`holeRadius`, 16-gons) at `jointSpace` pitch, each with
`tickRadius` of stock between it and its copy's edge (the male copy's
cut-back edge), at the same places along the seam on both copies: folded up
they face each other across the seam, for a cord or wire laced through them.

#### 3.4.12 Puzzle

Male: a neck `2 × tickRadius` wide from the cut-back edge through the band,
ending in a round head of radius `2 × tickRadius` (12 chords) that lies
wholly past the female panel's outside face. Female: an open notch through
its edge as wide as the neck (plus Slot Offset). The head, wider than the
notch, holds the female panel against the male panel's end; the female
panel slides onto the neck from its edge side.

#### 3.4.13 Male and female copies

Asymmetric types (Tab, Diamond, Multitab, Tongue, Rivet, Gear, Puzzle) put
the protrusion on the male copy and the slot (with its lug) or notch on the
female copy. Symmetric types (Ticked, Laced) decorate both copies the same
way.

#### 3.4.14 Perforation

With Perforate on, fold lines are drawn as dashes: dash length = the material
thickness (at least 0.1 mm), dash centres spaced two dash lengths apart, the
first dash starting at the fold line's start. A fold line not longer than two
dashes stays one full line. With Perforate off, fold lines are full length.
A fold runs only where both its panels keep stock after the cut-back.

### 3.5 Outlines, labels and assembly order

- Each net's outline is the union of its cut-back panels and the joint
  features that stand out of them, less its notches: its fold lines are
  inside it. Pieces of the outline a hair apart where separately cut panels
  meet are joined; webs of stock narrower than 0.2 mm are cut away; where
  the outline would meet itself or another outline at a point (corners
  within 0.00001 mm of each other), or a gap in the net comes within 0.2 mm
  of another cut, a 0.2 mm square is cut away there, so every cut runs round
  on its own. Cutting those squares can make new places where cuts meet, so
  the outline's hairline gaps are closed again and it is checked again, up
  to four rounds. Edges shorter than 0.001 mm, left by the cutting, are
  merged into their neighbours. A net that the cut-back splits in two
  becomes two nets.
- Cut-sheet parts: one per net, labelled `1`, `2`, … in net order. Each part
  carries the net outline, the joints' slots and holes as cuts, and the fold
  lines on the fold layer.
- Assembly steps: one per panel the nets hold (`Fold folded_panel_NNN`,
  from its source triangle); a panel the stock leaves out has none. The steps
  keep their indices (panel index + 1), so each finds its panel in the 3D
  view, and the assembly guide numbers them 1, 2, … in order.
- Parts are shelf-packed onto sheets as for every cut-sheet mode; a part
  that fits no sheet either way round goes on a sheet of its own, flagged.

## 4. Data structures

- `JoineryParameters` — joint type plus the per-type values in § 2.1.
- `FoldedPanelPlan` — the panels (flattened per-panel polygons), the joinery,
  the material thickness, the nets, each panel's boundary in its original
  3D position (`surfaces3D`, what the 3D viewport shows), the joint census
  (`jointCensus`) and the stock census (`stockCensus`). It also keeps a
  single-net outline and fold-edge list of the model surface for models
  that unfold into one net.
- `FoldedNet` — outline (with the joints), fold lines, joint slots and holes,
  loops the outline encloses that are not joints, the cut-back panel
  polygons and, for each, its frame, the direction from its outside face
  into its stock, and the joint features that stand out of it; and the
  panels joined by each fold (`hinges`).
- `FoldedSeamBand`, `FoldedJoineryGeometry` — where two panels' stock meets
  at a seam, and each joint type's features.

## 5. Edge cases

- **Curved surfaces**: every triangle has its own plane, so every triangle is
  a panel. The Detail budget keeps the count manageable.
- **Non-developable or self-overlapping unfolds**: the net splits wherever a
  panel would overlap, producing several nets.
- **Panels larger than the sheet**: a single panel that does not fit becomes
  its own net; the cut sheet places it on its own sheet, flagged as overflow.
- **Open meshes**: edges with only one owning panel are always cut, are not
  cut back and get no joinery (they have no mate).
- **Edges shared by more than two panels** (non-manifold): not adjacent;
  always cut, no joinery.
- **Faces in one plane that do not share an edge**, or back to back (a model
  built from overlapping boxes): separate panels.
- **Faces wound the wrong way round**: turned to agree with their
  neighbours before outsides are found (§ 3.1).
- **Sub-tolerance panels** (no valid plane frame): dropped.
- **Flat seams**: where two panels' planes meet at under 30°, the joints that
  pass through the other panel leave the seam plain (§ 3.4.1).
- **Thin panels and crowded nets**: a joint whose cuts would run into
  another panel or joint, into another piece's stock, or leave less than
  `tickRadius` of stock round a hole or notch, is left out on both copies.
- **Thin models**: where the model is thinner than twice the stock, the
  pieces on either side would pass into each other; one is cut back (and
  may be left out), which the stock census reports.
- **Thick stock on small panels**: slivers are cut back hard or left out
  (§ 3.4.0).

### 5.8 Cube

A cube has 6 panels. With a sheet large enough for the whole net they unfold
into one net with 5 fold lines; the other 7 cube edges are seams, each cut
into two mating copies. Each seam is square: its male copy is cut back by the
stock, so the box closes with butt joints, and all 7 get the joint.

## 6. Output

| Output | Content |
|---|---|
| Cut sheet, Print, SVG / PDF / EPS / DXF (app and CLI) | one part per net, packed onto sheets: outline and joint holes as cuts; fold lines (perforation dashes in the cut colour, or full lines in the score colour in SVG, PDF and EPS; DXF layer `fold-line`) |
| Part frames (`--part-frames`) | for each net (`folds`), each panel's map from DXF to model coordinates, the direction into its stock, its outline and joint features in DXF coordinates, and the panels each fold joins |
| STL / OBJ | each net outline extruded at z = 0 (GUI: material thickness; headless: 3 mm) |
| Viewport | the panels in their 3D positions (the model surface) |

The app's Export and the headless CLI write every vector format through the
same cut-sheet document the sheet preview shows, so the DXF a user exports
is the one the functional gate checks.

## 7. Worked example

50 mm cube, CLI defaults (`--thickness 5`, Tab joinery, 600 × 300 mm sheet,
10 mm margin):

- 6 panels, each a 50 × 50 mm square (two triangles per face).
- Usable extent 580 × 280 mm: the whole cube unfolds into **one** net with
  5 fold lines.
- 7 seams; each is 50 mm and `3 × 6.35 = 19.05 < 50`, so each gets a joint.
  Every cube seam is square, so the band runs 0 … 5 mm across both panels:
  the male copy is cut back 5 mm and gets a 6.35 × 6.5875 mm tab (5 mm
  through the female panel's stock, then 1.5875 mm past its outside face);
  the female copy gets a 6.35 × 5 mm slot from its edge line 5 mm into the
  panel, on a 9.525 × 1.5875 mm lug. Folded up, the male panel's end rests on the female
  panel's inside face, and the tab passes through the slot and stands
  1.5875 mm out of the outside face.
- Perforation is on: each fold line becomes dashes 5 mm long, starting
  every 10 mm, along the part of the fold both panels keep after the
  cut-back.
- Cut sheet: one part, `1`.

## 8. Known issues

- Folds bend the stock: Folded Panels assumes the stock can bend at a fold
  line (card, thin sheet, a perforated or kerf-cut crease). In stock too
  stiff to bend, the fold lines must be cut through and glued, and the
  panels either side of them are not cut back for each other.
- At a convex seam other than square, the butt joint leaves a small groove
  along the outside corner (the male copy's square-cut end meets the female
  panel's inside face below the model surface); at an inside corner a gap
  is left along the inside.
- Assembly steps count panels, while the cut sheet has one part per net, so
  step numbers and sheet labels differ for every model with more than one
  panel per net.
- On curved models at the default Detail most seams are flat or border
  thin triangles, so few joints fit and most edges are left plain to be
  glued or taped; in thick stock many slivers are cut back hard or left out.
  The Folded panel says how many.
- A Puzzle or Gear female copy slides onto its male copy from its edge side;
  a panel joined that way on several sides may need a particular order of
  assembly.
