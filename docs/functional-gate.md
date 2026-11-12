# Refab Artist Functional-Correctness Gate

Runner: `scripts/functional_gate.py`. Validator: `tools/gates/cut_invariants.py`.

The ship gate asks one question per construction mode: can the parts a user
exports be cut from the sheets they are laid out on? A mode is done when its
cases pass this gate.

## What it checks

The gate reads the DXF each case exports: the file a user gets from Export.
The headless CLI (`--headless-export --format dxf`) writes it through the same
writer table as the app (`FlatPartExport`), so the gate checks real output,
not a format kept for testing.

Which writer produces that DXF depends on the mode:

| Mode | DXF writer | Layers |
|---|---|---|
| Stacked | `DxfExporter.write(contours:)` | one `slice_NNN` layer per slice (it may hold several pieces); dowel holes as circles |
| Radial | `DxfExporter.write(radial:)` | `first_axis_NNN` rings, `radial_NNN` fins |
| Interlocked, Curve, Folded Panels | `CutSheetDocumentExporter.writeDXF` (the cut sheet) | one layer per part, named by its label, holding its outline and the holes cut into it; scored guides on `<label>_guide`; Folded Panels fold lines on `fold-line` |

Every writer draws each sheet as a rectangle on `sheet_boundary`,
`sheet_boundary_2`, …, in millimetres. Fold lines and guides are scored or
perforated, not cut out, and are not part outlines. The validator recovers parts from the geometry: it chains each
layer's LINE entities into loops. Where two loops cross, the smaller is a
notch cut into the larger when at least half of it lies inside the larger (a
slot drawn across its part's outline); otherwise they stay two parts cut on
top of each other, which NO-OVERLAP reports. It nests the rest by containment
(a part's outline, then holes inside it) and gives each CIRCLE to the part
that contains its centre. TEXT labels are ignored.

It then evaluates eleven gated invariants and one metric per case:

| Invariant | Role | Meaning |
|---|---|---|
| FITS-SHEET | **gated** | every part lies inside the sheet it overlaps most |
| NO-OVERLAP | **gated** | no part's outline or notches cross another part, and no part sits in another part's material |
| VALIDITY | **gated** | every cut loop is closed, encloses area and does not cross itself; no part's outline pinches (touches itself at a point, a corner on another stretch of it within 0.0001 mm, between two lobes that lie outside each other, whichever way each turns: two pieces held only at that point; a hole that reaches the edge is not a pinch); no cut is left open or written twice |
| BISCUITS-IN-MATERIAL | **gated** | every hole (dowel or biscuit circle, mating slot, rivet hole, a void of the model) lies inside its part's material: inside the outline, clear of its edge (at least 0.01 mm of material between them: a hole that touches the edge is cut open by it), not inside another hole |
| PART-COUNT | **gated** | the file holds exactly the number of parts the case exports (`EXPECTED_PARTS`), so a dropped page or a lost piece fails |
| SLOTS-FIT-MATERIAL | **gated** | in the slotted modes (Interlocked, Radial, Curve), every slot cut into a part's edge is at least as wide as the stock the case exports at, so the crossing part seats in it. A slot is two antiparallel walls joined by a bottom, with the outline turning inward at both bottom corners; a slot at the end of a part, with no material past one wall, is not measured |
| SLOT-COUNT | **gated** | the file holds the joint cuts the case exports (`EXPECTED_SLOTS`): slots cut into part edges, plus, for Folded Panels, every hole cut into a net (slots, pin and lacing holes). Parts that should interlock but come out without their slots fail it |
| SLOTS-MATE | **gated** | for cases that export part frames: the parts put back in the model, wherever a part of one family crosses a part of the other inside the model they are joined by mating slots; for Folded Panels, every net has its frames, the nets fold into the panels the case expects, and folded up every slot hole has a panel passing through it and every tab, tongue, lug or finger meets another panel (below) |
| PARTS-CLEAR | **gated** | for the same cases: no two parts of one family pass through each other, and no two parallel parts stand closer than the stock where their outlines overlap (Radial rings, Curve first-axis ribs); for Folded Panels, each net's material lies inside its panels and features, and folded up in the case's stock no two panels' stock passes into each other (below) |
| PARTS-JOINED | **gated** | for the same cases: the joints hold every part to the rest of the model, but for the parts the part-frames file marks `detached` (shown blue on the cut sheet, to be glued), and no part so marked is held to the rest (below) |
| MATERIAL-IN-MODEL | **gated** | for the Radial and Curve cases on closed meshes: the parts put back in the model, every part's material lies in the model (below) |
| CONTOUR-MATCHES-MESH | metric | Hausdorff distance (mm) from each part outline to the closest cross-section of the source mesh along the case's axis |

### Joints: SLOTS-MATE and PARTS-CLEAR

A flat DXF cannot say which parts meet in the model, so the Radial, Curve and
Folded Panels cases also export a part-frames file (`--part-frames`, `parts.frames.json`
beside the DXF): for each part, the affine map from its DXF coordinates to
model coordinates. The validator puts every part back on its plane and, for
every two parts that are not parallel, takes the line their planes share:

- along that line, and along eight lines around the beam where the two
  parts' stock overlaps (its corners and the middles of its sides, 0.02 mm
  inside each part's faces), the two parts' material must not overlap: a
  missing, shallow or narrow slot shows as material in both. At an angle `a`
  a slot must be `t·(1 + |cos a|) / sin a` wide for stock `t`; one any
  narrower leaves material at a corner of the beam;
- for parts of different families (the label's prefix, `Z` and `C` in `Z-3`,
  `C-5`, or a row-layout layer without its number, `first_axis` and `radial`
  in `first_axis_003`, `radial_012`), each stretch where the line runs through
  the model (found from the mesh itself) must be filled by the two parts'
  material to within 1 mm: the slot depths add up. The line is inside the
  model where the surfaces around it wind round it: it enters where it
  crosses a triangle from the side its winding faces and leaves where it
  crosses one from the other side. So two shells that run into each other
  count once (their overlap is model, not a hole), and a cavity whose
  surface faces into it is outside;
- and each of the two keeps some material along the crossing, so the joint
  holds.

A part can stop short of a crossing: a Curve rib cut back where it would run
into its neighbours ends before some first-axis ribs. A part with no material
on the line and none on one side of it (looked for at twice the beam's
half-width plus 1 mm, past any slot that seats the other part) takes no part
in that crossing: it is not a joint, and the other part must fill the
stretch by itself (a slot there, with nothing to fill it, fails SLOTS-MATE).
A part with material on both sides of the line but none on it has a slot cut
right through it: that is a joint that does not hold.

Parts of one family cut from the same plane (a ring's pieces, or two Radial
fins either side of the hub axis) are checked as one. `EXPECTED_JOINTS` pins
how many such stretches each case checks, so a file whose parts no longer
cross cannot pass by checking nothing. Parts of one family that cross fail
PARTS-CLEAR instead: Radial fins all cross on the hub axis, so PARTS-CLEAR
checks that they start far enough from it to clear each other. Parallel
parts do not cross; two of them whose planes stand closer than the stock
pass through each other wherever their outlines overlap, sampled on a
40 × 40 grid over each part (more than 1 mm² fails PARTS-CLEAR). Radial
rings stand at least a stock thickness apart, so this catches rings planned
over a model shorter than their stock.

PARTS-JOINED groups the parts by those joints: two parts are joined where
each keeps material along the line of a crossing that is a joint (both take
part in it). The largest group (most parts, then most outline area) is the
model. Every part outside it must be marked `"detached": true` in the
part-frames file, which the export writes for each part its cut sheet shows
blue, and every part so marked must lie outside it. So a part no joint holds
(a curve rib cut short of every first-axis rib, a ring piece no curve rib
crosses) fails unless the export left it out or marked it, and a group of
parts held together but not to the rest (the torus with first axis Y in 5 mm
stock) passes only marked.

### Material: MATERIAL-IN-MODEL

Slots, notches and trimmed hairlines only take material away from a section,
so every bit of a Radial or Curve part, put back on its plane from the
part-frames file, must lie inside the model there. The validator cuts the
model with each part's plane (in the part's DXF coordinates, each segment
run with the model's material on its left as its triangle faces) and checks
the points of a 0.5 mm grid inside the part's material (its outline less
holes and notches): each must lie inside that section, by the winding of
the surface round it as SLOTS-MATE reads it (overlapping shells count once,
a cavity facing into itself is outside), or within 0.5 mm of its edge (the
web Curve leaves when it closes gaps under 1 mm). Material farther out is a
hole of the model cut solid, a loop turned the wrong way, or a piece that is
not the model's: a ring of the torus whose hole is filled has material up to
20 mm outside the model and fails.

The inside is read from the winding, so the mesh must be closed and wound
consistently, facing out. A case whose own mesh is not names one that is
(`REFERENCE_MESH`: the torus for the torus wound both ways and the torus
wound inside out). Open meshes (`OPEN_MESHES`: the cracked blob) are not
checked; armed on an open mesh, the check fails rather than read it wrong.
The joints (SLOTS-MATE, PARTS-CLEAR, PARTS-JOINED) never see a filled hole:
nothing crosses a ring where its hole should be. This check does.

### Folded Panels joints

A Folded Panels net folds up along its fold lines. Its entry in the
part-frames file (`folds`) gives, for each panel, the map from DXF to model
coordinates, the direction from its outside face into its stock (the stock
lies inside the model surface, `docs/specs/folded.md` § 3.4.0), the panel's
outline and the joint features that stand out of it (tabs, lugs, fingers) in
DXF coordinates, and which panels each fold joins. The validator folds every
net up, each panel a slab of the case's stock behind its outside face. Two
panels a fold joins are one bent piece and are not compared. For any other
two whose slabs come near each other, it runs lines through both slabs
parallel to where their planes meet, on a 5 × 5 grid across the two
thicknesses (0.02 mm inside each face), and the panels' material (outline and
features, less holes and notches) must not overlap along any of them by more
than 0.02 mm; panels that are (nearly) parallel are sampled point by point.
A seam whose stock was not cut back, a tab that misses its slot, a finger its
notch or a lug that its neighbour runs into each shows as overlap
(PARTS-CLEAR). The fold-up sees a net's material only inside the panels'
outlines and features the frames give, so PARTS-CLEAR first checks that the
net's material lies inside them: points every 0.25 mm along the net's
outline (a hair inside it) and on a 1 mm grid inside it must each lie in a
panel or feature, or within 0.05 mm of one. A net drawn larger than its
panels (a seam pushing into the next panel's stock outside every panel)
fails there.

SLOTS-MATE checks that every net has its frames, that the nets fold into
the number of panels the case expects (`EXPECTED_JOINTS`), so a file whose
panels go missing cannot pass by checking nothing, and that the joints
mate. Folded up, every slot hole cut in a panel (one whose area lies mostly
inside a panel's outline: not a hole the net closes around, nor a rivet
tab's pin hole) must have another panel's stock passing through it,
sampled on a 5 × 5 grid across the hole at five depths through the stock;
and every protrusion (a feature's material past its panel's outline: a tab,
tongue, lug or finger) must meet another panel, lying in its stock (in a
slot or notch) or resting on it within 0.05 mm, inside its outline or
features, or be a lug carrying, within a stock thickness, a slot another
panel passes through. Laced joints' holes are for a cord and may hold
nothing (`folded_holes_hold_joints`, off for the `-laced` cases).
BISCUITS-IN-MATERIAL checks that each slot, pin hole and lacing hole is a
closed hole with material round it, and SLOT-COUNT that the joints are all
there.

The Swift tests check the same in solids: `FoldedStockTests` folds up the
nets of a cube, a square pyramid, a box and the chair, the cylinder, sphere
and torus at the app's 250-face detail, and the spur gear at full detail, in
0.5, 3 and 5 mm stock, builds every panel's stock as a solid, and checks
that no two solids intersect, that every tab and tongue passes through its
slot and out of the far face, and that rivet pins reach their holes. The
solids are exact where the gate samples lines: a sliver of overlap between
two of the gate's lines can pass PARTS-CLEAR and still fail here. It also
checks that the torus and the lumpy blob at full detail cut as separate
clean loops (no cut touching or crossing another, none shorter than
0.001 mm).

A gated failure fails the gate. The metric is reported and does not gate. It
reads near zero for Stacked, whose parts are plain cross-sections. It does not
apply to modes whose outlines carry cut slots or come from other planes
(Interlocked, Radial, Curve) or are unfolded surfaces (Folded Panels); the
gate prints these limits with every run.

## Cases

`CASES` in `scripts/functional_gate.py` lists 128 cases: Stacked on the cube,
sphere, cylinder, torus, chair and gear; Interlocked on the cube, sphere and
cylinder; Stacked and Interlocked on the lumpy blob cracked open at its poles
(`pathological/lumpy_blob_open_poles.stl`, as real scans often are) at 5 and
3 mm (`stacked/cracked-blob`, `stacked/cracked-blob-3mm`,
`interlocked/cracked-blob`, `interlocked/cracked-blob-5mm`); Stacked on two
blocks that meet along one edge (`pathological/blocks_touching_at_corner.stl`,
`stacked/corner-blocks`, `stacked/corner-blocks-3mm`), whose every section is
two pieces touching at a corner that the contourer draws as one figure of
eight; Radial on the
cylinder and sphere, and on the torus, the chair, the
lumpy blob, the low-poly head (blocks that touch along their faces), two
cubes that run into each other (`pathological/cube_self_intersecting.stl`),
the cracked blob and the torus with a third of its triangles wound inward
(`pathological/torus_mixed_winding.stl`),
each at the CLI's defaults (5 mm stock, 12 fins) and the app's (3 mm stock,
6 fins: `radial/torus-3mm`, with `--n-radial 6` from `CASE_ARGS`); Folded Panels on the cube, the
square pyramid and the chair with every joint type that cuts geometry: Tab
(the CLI default, `folded/cube`), Diamond (the app's default), Multitab,
Tongue, Rivet, Gear, Puzzle, Ticked and Laced (`folded/cube-diamond` and so
on, exported with `--joinery-type` from `CASE_ARGS`), each in 5 and 3 mm
stock (`folded/chair-gear-3mm`), on the torus at the app's 250-face
detail (`--folded-target-faces 250`) in both, and on the spur gear at full
detail in both (`folded/gear`, `folded/gear-3mm`), whose teeth are thinner
than the stock is deep, so the stock of one flank reaches across the tooth
into the panels beyond it; Curve on the
sphere, torus, gear, hollow box, chair, lumpy blob, two cubes that run
into each other (`pathological/cube_self_intersecting.stl`,
`curve/overlap-cubes`), the cracked blob (`curve/cracked-blob`) and the
torus wound both ways (`curve/torus-mixed-winding`; `CURVE_MODELS`), each with first axis Z
(the CLI default) and Y (the app's default, `curve/sphere-y`, `curve/torus-y`
and so on, exported with `--axis y` from `CASE_ARGS`), at 3 mm and at 5 mm
(`curve/sphere-5mm`, `curve/torus-y-5mm`, …). The concave, hollow and organic
Curve models are the ones whose joints broke before (rings cut in two,
crossings beside a hollow's inside wall, overlapping shells, open sections).
The torus wound inside out (`pathological/torus_inverted.stl`) is cut in
Radial at the CLI's defaults (`radial/torus-inverted`) and in Curve with
first axis Z in 3 and 5 mm (`curve/torus-inverted`,
`curve/torus-inverted-5mm`); in Radial at the app's 3 mm and 6 fins, or in
Curve with first axis Y, it comes out the same whether or not the winding
is read right, so those are not cases. The torus wound both
ways and the one wound inside out must be cut as the torus is; since the
joint and material checks read where the model is from the triangles'
winding (`mesh_spans`), they are checked against the consistently wound
torus (`REFERENCE_MESH`).

The lumpy blob cracked open at its poles is cut in 10 cases: Stacked,
Interlocked and Radial at 3 and 5 mm, and Curve with first axis Z and Y at
3 and 5 mm.

Most cases guard a fix by failing without it. Some are regression coverage
only, passing with or without the fix they were added with, and are kept to
catch other breakage: `curve/torus-mixed-winding-y` and
`curve/torus-mixed-winding-y-5mm` (the torus's sections across Y have no
hole a wrongly turned loop could fill, so they come out the same whether or
not the winding is read right), and the Interlocked (2) and Curve (4)
cracked-blob cases (Interlocked and Curve already cut the cracked sections
cleanly before Stacked and Radial were taught to). The cases a fault in
reading the winding fails are the Radial and Curve (first axis Z)
`torus-mixed-winding` and `torus-inverted` cases, through MATERIAL-IN-MODEL;
splitting outlines that pinch is guarded by `stacked/corner-blocks` and
`stacked/corner-blocks-3mm`, through VALIDITY and PART-COUNT.
Each case exports with the CLI defaults (600 × 300 mm sheet, 10 mm spacing
and margin, no slot offset) at 5 mm material, except Interlocked, the 3 mm
Curve cases and the 3 mm Folded, Radial and Stacked cases (`MODE_THICKNESS_MM`, and
`CASE_THICKNESS_MM` for the 5 mm Curve and Interlocked and the 3 mm Folded,
Radial and Stacked cases): Interlocked cuts ten slices per family whatever the stock, so
on these 40–50 mm models 5 mm slots would fill the 5 mm slice spacing.
Curve asks for seven first-axis ribs and twelve curve ribs and cuts only as
many as leave a stock-thick web between two slots (`docs/specs/curve.md`
§ 3.1, § 3.3): on the 50 mm sphere eight curve ribs with first axis Z in
3 mm stock, five in 5 mm. `EXPECTED_PARTS`, `EXPECTED_SLOTS` and
`EXPECTED_JOINTS` give each case's part, slot and joint counts; when an
export change is meant to change a count, update it with the candidates.

## Known defects

`KNOWN_DEFECTS` in `scripts/functional_gate.py` lists the cases that fail a
gated invariant in today's export, which invariants they fail, and why. Such
a case does not fail the gate as long as it fails exactly those invariants.
Failing another invariant fails the gate, and so does a listed case that
starts passing: fix the defect, then delete its entry in the same change.

The list is empty: every case passes every gated invariant.

## The gate has teeth

`tests/gates/test_gate_mutations.py` takes committed candidates, breaks them
the way a defect would, and checks that the right invariant fails on the
right part and that the gate exits non-zero:

- a part pushed off its sheet, or half over the sheet edge: FITS-SHEET
- two parts drawn over each other, a small part dropped inside a bigger
  one, or a second piece drawn across a part on the same layer: NO-OVERLAP
- parts deleted from the file: PART-COUNT
- slots narrower than the stock (the Radial cylinder checked as if cut for
  6 mm stock, and synthetic combs in `tests/gates/test_cut_invariants.py`):
  SLOTS-FIT-MATERIAL
- a part redrawn without its slots: SLOT-COUNT, and for Curve SLOTS-MATE
  (it collides with every part it crosses)
- a Curve part moved off its place on the sheet: 2 mm along its joints
  (the slots leave a 2 mm hole: SLOTS-MATE) or 1 mm sideways (its slots miss
  the crossing parts: SLOTS-MATE); the parts checked against thicker stock
  than their slots fit (SLOTS-MATE); the slots of a curve rib crossing at a
  slant narrowed by 0.2 mm a side, still wider than the stock (SLOTS-MATE);
  a rib's frame turned out of its plane, a curve rib's turned 15 degrees
  into its neighbours, or, in 5 mm stock, slid 7 mm along the spline
  toward its neighbour (PARTS-CLEAR); a case with no part frames
  (SLOTS-MATE)
- the concave, hollow and organic Curve cases: the hollow box with one piece
  of a curve rib that a slot cut in two left off the sheet (its crossings
  are left empty: SLOTS-MATE, and PART-COUNT); a torus curve rib redrawn
  without its slots (it collides with the Z rings it crosses: SLOTS-MATE);
  the blob with one segment of a curve rib's outline missing (VALIDITY).
  Every untouched Curve case passes SLOTS-MATE, PARTS-CLEAR, PARTS-JOINED
  and VALIDITY
- the torus, first axis Y, 5 mm, with its six blue parts left unmarked in
  the part frames, or a part joined to the rest marked detached; the simple
  chair, first axis Z, whose legs Curve joins through the seat (a first-axis
  rib moved, `docs/specs/curve.md` § 3.1.1), with a leg marked detached
  (PARTS-JOINED);
  the torus, first axis Y, 3 mm, with all its curve ribs but one left off
  the sheet (the first-axis ribs that one does not cross: PARTS-JOINED); two
  parts that do not cross, unmarked (PARTS-JOINED)
- a Radial ring redrawn without its notches (it collides with all six planes
  of fins: SLOTS-MATE); a fin moved 2 mm out from the hub (its ten joints
  each leave a 2 mm hole: SLOTS-MATE); two neighbouring fins moved 3 mm in
  toward the hub (they collide with the rings, SLOTS-MATE, and with each
  other, PARTS-CLEAR; one fin moved in alone still clears its neighbours); a
  fin's frame turned 10 degrees about the hub axis (its slots miss the ring
  notches: SLOTS-MATE); a fin's slots or a ring's notches narrowed by 0.2 mm
  a side, to 4.6 mm in 5 mm stock (SLOTS-MATE as well as SLOTS-FIT-MATERIAL)
- two square ribs of the cube crossing on its axis, drawn by the test: a
  half-lap mates and the same squares unslotted collide; slots 5% narrower
  than the stock collide; turned to cross at 60 or 45 degrees, slots as wide
  as the slant needs mate and slots 8% narrower collide; a slot cut right
  through one of them does not hold; a rib ending 2 mm short of the other
  is no joint, unless the other is slotted for it anyway (SLOTS-MATE)
- a hole cut beside the part, one cut through the part's edge, one touching
  it, or a dowel landing in a void of the part: BISCUITS-IN-MATERIAL
- the Folded cube's slots (Tab, Diamond, Tongue) and rivet holes pushed onto
  their part's edge, so no material holds between them (BISCUITS-IN-MATERIAL:
  touches the outline); its Tab slots pushed 2.5 mm past their lugs, half
  off them (every tab lands in material: PARTS-CLEAR at all seven seams); the
  cube's net, cut back for 5 mm stock, folded up in 6 mm stock (PARTS-CLEAR
  at all seven seams); the frames with the folds left out (the five folds
  overlap: PARTS-CLEAR), with a panel missing (SLOTS-MATE), or without the
  nets at all (SLOTS-MATE); the cube's net drawn 0.6 mm larger all round, its
  holes kept (its material outside every panel: PARTS-CLEAR); every tab cut
  off the cube's net (the seven slots hold nothing and their lugs meet
  nothing: SLOTS-MATE); one panel's tabs left out of the frames (their
  material outside every panel: PARTS-CLEAR; their slots empty: SLOTS-MATE);
  the Laced cube checked as if its holes were slots (SLOTS-MATE). Untouched
  Folded cube, pyramid, chair and torus nets fold up clear
- an outline with one segment missing: VALIDITY
- each section of `stacked/corner-blocks` redrawn as one figure of eight
  through the corner its two pieces share: VALIDITY (pinches) and
  PART-COUNT; synthetic figures of eight in `tests/gates/test_cut_invariants.py`
  fail VALIDITY whichever way their lobes turn, and a hole reaching the edge
  is not a pinch
- the hole of a torus ring cut solid (the ring's hole lines deleted) in
  `radial/torus`, `radial/torus-mixed-winding`, `radial/torus-inverted`,
  `curve/torus-mixed-winding` and `curve/torus-inverted-5mm`: material up to
  20 mm outside the model fails MATERIAL-IN-MODEL; it is armed for exactly
  the Radial and Curve cases on closed meshes

The same file checks that an independent reader (ezdxf, when installed) sees
the same LINE and CIRCLE entities as the validator.

## Running it

```sh
# Validate the committed candidates (no Swift build needed)
python3 scripts/functional_gate.py

# Rebuild the app, export fresh candidates, validate the live output
swift build --package-path app/RefabArtist
python3 scripts/functional_gate.py --generate

# The gate's own tests
python3 -m pytest tests/gates
```

`--no-contour` skips the metric. Exit code is non-zero iff a gated invariant
fails beyond `KNOWN_DEFECTS`, or a known-defect entry has gone stale. There is
no cloud CI: run the gate locally before merging.

The committed candidates under `tests/fixtures/functional-gate/` are
Refab Artist's own exports (see the README there). After an intentional exporter
change, regenerate them with `--generate` and commit them together with the
change.
