# PRD: Model Repair — diagnose, fix what is broken, ask about what is intended

## Status
DRAFT v2, 2026-09-24 (Claude). Not approved, not started. Triggered by the owner's
pineapple-cup test of Make Watertight. v1 was adversarially reviewed (archetype
stress-test + engineering feasibility, both measured on the owner's real files and
the vendored Manifold 3.5.1); this version incorporates every accepted
finding. Builds on — does not reverse — `docs/prd-healer-robustness.md`
("closed + Manifold-accepted" is the bar; strict 2-manifold only where a
consumer needs it).

## What the owner asked for
One repair system that handles:
1. **Open skins** (pineapple cup): cap the opening flat, convex or concave —
   or make it a walled cup.
2. **Scans**: just fill them into something printable.
3. **Near-solid models with a few bad triangles** (the hand): heal only those
   spots without wrecking the scan surface.
4. **Anything he didn't account for.**

## Problem (measured on the shipped build, 2026-09-23)
Make Watertight (`MeshModifier.shrinkwrap` → `MeshHealer.heal`) has ONE
strategy for everything: a generalized-winding-number (GWN) signed field,
voxelized and re-meshed with Manifold `level_set`.

| Model | Wanted | Got |
|---|---|---|
| pineapple_cup.obj — clean open skin, one rim opening | cap it, or a walled cup | cavity filled solid (281 cm³); stair-step lid; crown tips trimmed (87.8 → 84.4 mm); 11 floating crumbs; 100% of the surface re-meshed; 21 s (82 s at max detail) on 1 of 8 cores |
| handStand_ex1/2/3 — solid, defects touch 0.4–0.6% of faces | heal only the spots | 0% of original triangles kept; triangle count −62…−85%; 35–62 s |
| TeaPot1, Dripper1 — open skins with inverted normals | flip, then cap/thicken | heal finds no "inside" and silently returns the model unchanged (TeaPot after 20.7 s, Dripper after 1.1 s) |

The measurement layer is worse than the heal:
- `MeshPreflight` uses ABSOLUTE tolerances in RAW FILE UNITS and **skips
  "degenerate" faces when counting edges**, which fabricates holes; the scaler
  copies that report through unit conversion (`MeshScaler.swift:167,197`).
- **Repair Mesh deletes real geometry.** Verified on the shipped binary:
  Sardiniers6.obj (a valid closed solid) reports 566,025 degenerate / 263,471
  open edges, and Repair takes it from 892,108 → 326,083 triangles (−63%) while
  still reporting 263,471 open edges. Pineapple: 33,453 → 32,290.
- Neither the inch nor the mm report is true. Pineapple true topology: 303
  open edges (a 300-edge rim loop + a 3-edge pinhole), 7 non-manifold edges
  (all from 4 back-to-back duplicate PAIRS), 1 pinch vertex on the rim,
  2 loose triangles. App in inches: 1,163 / 2,390 / 7. App in mm: 35 / 372 / 0.
- 8 of 22 real files checked are already valid solids; 4 of those look badly
  broken in the app.

## Principles
1. **Diagnose before touching.** Every action starts from a located, typed
   diagnosis.
2. **Least destructive first.** Tidy → local surgery → intent operations →
   rebuild. Never jump tiers silently.
3. **Untouched means bit-identical — measured on the geometry actually
   returned.** Local ops return Swift meshes and use Manifold only as a
   verifier. Any op that returns Manifold output imports through the 64-bit
   path (`manifold_of_meshgl64`; today's float32 `make()` leaves 0% of
   triangles bit-identical even with no edit).
4. **Intent guard.** Auto-apply ONLY the safe set (below). Anything that deletes
   a closed positive-volume body, merges bodies, closes a non-trivial hole,
   fills a cavity, or changes component count / genus / opening count is a
   listed CHOICE with a preview. The escalation loop is a correctness backstop;
   it can never detect destroyed intent, so it is never allowed to do these
   things on its own.
5. **Severity, per consumer.** Items are *blocking* (for a named consumer) or
   *informational*. "Nothing to fix" means nothing blocking. Local folds that
   Manifold and slicing accept are informational.
6. **Verify every step; escalate only upward, only locally, with a budget.**
7. **Never fail silently.** Every run ends in a receipt: what changed, where,
   per-site deviation, what is still wrong and why.
8. **Recognize "already fine"** — but only for a non-empty surface with
   positive enclosed volume.
9. **Permissive stack.** Swift + Manifold (Apache-2.0) + Accelerate +
   MIT/BSD/public-domain code. No CGAL (PRD decision D2), no Eigen, never
   AGPL/commercial.

## How it works

```
import ─► MEASURE ─► auto SAFE SET ─► RE-MEASURE ─► CHOICES (intent) ─► APPLY ─► VERIFY ─► RECEIPT
            │                                          ▲                       │
            └─► viewport markers                       └── per-opening cards   └─► escalate site (budgeted)
```

### 1. Measure — `MeshDiagnosis` (NEW analyzer; `MeshPreflight` is frozen)
- Computed ONCE at import on raw coordinates with **unit-invariant**
  tolerances (topology does not change under uniform scale or rotation):
  weld relative to the bounding box, bounded by local edge length; "degenerate"
  = numerically zero area relative to the model size, never by aspect ratio.
  Only mm-denominated facts (hole size, thickness) are multiplied by the scale.
- Edges counted over ALL non-collapsed faces. Zero-area faces that share no
  edge with anything are debris, not boundary (keeps the
  `cube_zero_area_face` test case and the `spur_gear_T20_M2` ship-gate
  fixture passing).
- Every item carries face/edge/vertex IDs for viewport markers:
  - **Boundary loops** from UNDIRECTED edges, split at pinch vertices by a
    turning rule (a directed walk fragments pinched and one-sided
    boundaries). Per loop: perimeter, width `2·area/perimeter`, planarity,
    convexity, simple-in-projection (Swift segment-crossing test), pinches.
    Classification, relative to local edge length `e`:
    - *crack* — width < 0.1·e (zero-width slit, unwelded seam, CAD
      T-junction). Fixed by edge-pairing and splitting, **never by welding**
      (a 0.2 mm weld collapses 378 TeaPot faces).
    - *pinhole* — ≤ 12 edges and width ≤ ~2·e.
    - *opening* — everything else.
  - **Non-manifold** edges/vertices, clustered into sites, cause-tagged
    (back-to-back duplicate pairs — the #1 cause on the owner's files — fins,
    kissing sheets).
  - **Orientation** by BFS on the (post-stitch) adjacency with whole-patch
    flips, and **nesting parity** for closed shells (never per-shell signed
    volume — that fills intentional cavities). Non-orientable surfaces are
    detected by a BFS conflict cycle.
  - **Components**: main body, open/zero-volume fragments, zero-volume
    internal junk shells, positive-volume bodies (separate / nested / sunk),
    intentional cavities.
  - **Self-intersections** (background, lazy): flat-array BVH, includes
    vertex-sharing pairs, exact orient3d predicates (Shewchuk, public domain)
    to separate touching from crossing, parallel. Not in the quick verdict.
  - **Thickness** (background): zero-thickness skin, thin walls.
  - **Slivers/needles**: informational only (they are normal ZBrush/CAD
    output — 3.3% of the pineapple, 8.5% of UMesh).
- **Archetype sentence**: Clean solid · Solid with small problems · Open skin
  (vessel / tube / sheet / relief) · One-sided surface · Multi-body or nested ·
  Raw scan · Points only / empty.
- **Unit status**: "guessed" when the file carries no units; absolute
  printability verdicts are suppressed until confirmed.

### 2. The safe set (automatic, reversible, receipted)
Applied in this order, then the model is re-measured:
1. Weld (relative tolerance).
2. Remove open or zero-volume fragments and zero-volume internal junk shells
   (all real debris in the corpus is this kind).
3. Remove SMALL back-to-back duplicate pairs glued onto a surface.
4. Stitch cracks (orientation-agnostic, edge split + pairing).
5. Orient: BFS with patch flips on the stitched graph; flip whole inverted
   shells by nesting parity.
6. Split pinch / bow-tie vertices; strip-and-refill non-manifold sites.
7. Fill pinholes (Liepa triangulation + refinement + fairing).

Nothing else is automatic. Local folds are left alone unless a consumer or a
chosen operation needs epsilon-valid input.

### 3. Choices (intent) — shown only when they apply, each with a live preview
- **Skin mode** (for zero-thickness skins): **Solid** (every opening capped) ·
  **Walls** (thickness mm; Inward by default so the outside stays exact /
  Centered / Outward) · **Leave open**.
- **Per opening**: open rim · **Cap** (style) · **Flat base** (reliefs:
  extrude the rim to a back plane). In Walls mode a capped opening becomes a
  floor/lid of the wall thickness. Similar openings can be grouped ("apply to
  all 12").
  - Cap styles: **Smooth** (faired, falls back C1 → C0 → minimal if it would
    hit the wall) · **Dome ↔ Dish** (one signed height slider in mm; the
    height is automatically clamped short of the wall and the clamped value
    is shown) · **Flat** (projection fill, only when the rim projects to a
    simple polygon; otherwise disabled with a hint — on the pineapple a flat
    lid would bury or cut the crown, so Flat there means "Walls + flat
    lid").
  - Planarity picks the cap *style*, never whether to cap. No default is
    applied for organic vessel rims.
  - *Built (2026-09):* openings are identified by an `OpeningSignature`
    (rim centre, diameter, outward normal — never array index) and matched
    one-to-one, closest first (centres within a quarter of the diameter,
    diameters within 25%, normals within 60°); a saved choice that matches
    nothing is dropped and the panel / receipt say so. Fix in place: per
    opening **Cap** (own Top shape, default = the global slider) or **Leave
    open** — the result is then not watertight by choice ("1 opening left
    open (your choice)"; the topology report still counts that rim's open
    edges; all openings left open with nothing else to fix is refused with
    the reason). Make walls: per opening **Open** (default) or **Closed** —
    the closed opening's flat cap joins the skin set S the wall distance is
    measured from, so the inner solid stays t away from it: a floor / lid of
    the wall thickness (measured on the result along the opening's inward
    normal and reported); every opening Closed is refused (that is Hollow).
    Modify Form lists the openings ("Opening 1 — 93 mm, top", placement from
    the outward normal / height on the +Z-up model) only when there is a real
    choice (≥ 2 openings, or one opening plus other damage in Fix in place);
    a row and its viewport marker select each other. Choices persist in the
    project (`modifyOpeningChoices`, keyed by signature; legacy projects
    decode to none). Headless: `--leave-open`, `--opening-height i=mm,…`,
    `--closed-opening` (1-based numbers or `cx:cy:cz:d[:nx:ny:nz]`).
- **Bodies**: sunk / nested / overlapping positive-volume bodies → keep
  separate · merge · treat inner as a cavity. Small closed bodies (an i-dot,
  jump rings) are never auto-deleted.
- **Cavities**: keep (hollow print) · fill.
- **Bulk hole fill for scans**: "Fill holes up to X mm" slider with a live
  count and highlight, plus "cap the scan base flat".
- **Special structures**: Join rims (bridge two parallel rims of an
  un-bridged double wall) · Thicken sheet (centered band, unioned with the
  body — for fins, leaves, capes and one-sided surfaces).
- **Rebuild as solid** (separate button, labelled "rebuilds the entire
  surface"): the explicit escape hatch for raw soups.

### 4. Rebuild as solid (fixed)
The current GWN heal, kept as the explicit fallback:
- Output-identical speedups first: narrow-band distance clamp, Swift
  `concurrentPerform` prefill of Manifold 3.5.1's lattice (origin =
  bounds.min, gridSize = dim/edge + 1, spacing = dim/(gridSize − 1),
  second lattice offset −0.5), real progress + Cancel from a Swift counter.
  The pinned `open_hemisphere_mask` fingerprint proves equivalence.
- Flip inverted skins before the GWN (fixes the TeaPot/Dripper no-op);
  surface every failure as a message.
- Output-changing fixes, landed together with a deliberate golden
  regeneration: continuous field `(2w − 1)·d` (no stair-step lid),
  crumb filter, snap-back onto the original where it is clean, keep/fill
  cavities.
- Versioned: legacy projects replay `rebuildAsSolid.v1` (today's output) so
  saved geometry and MotherMold approval hashes do not silently change.

### 5. Verify, escalate, receipt
- Verifier: closure (the new measurement), Manifold acceptance via the
  64-bit import, component count / genus / opening count compared with the
  plan, orientation, positive volume. The verifier never re-welds (that
  re-merges sheets that were deliberately split).
- Escalation: per site, only upward, with an iteration budget and a growth
  cap; merged sites keep the higher level. Chosen intent operations never
  escalate into wall edits — a conflict is reported with alternative styles.
- Receipt, per site: what was done, max deviation, topology change, rebuilt
  or not; plus totals (% original triangles bit-identical on the returned
  mesh, volume, bounds). `manifoldValidated` is set only on the geometry
  actually returned (today it is set before despeckle moves every vertex).

Example (pineapple, after choosing Solid → Smooth cap):
> Removed 4 doubled triangle pairs and 2 loose triangles, closed 1 pinhole
> (0.4 mm), split 1 pinched rim vertex, capped the top opening (smooth).
> 29 overlapping triangles in 9 small folds left as-is (harmless for
> slicing). 99.x% of your surface is untouched. Now one closed solid.

## Case walkthroughs
| Case | Path |
|---|---|
| Pineapple cup (clean skin, 1 scalloped rim) | Safe set fixes the doubled pairs, loose triangles, pinhole and pinch → one opening card → Solid (Smooth / Dome↔Dish) or Walls (t mm, inward; optional flat lid) or Leave open |
| Hand scans ex1/2/3 | Safe set only → closed, Manifold-accepted, ≥ 99.5% bit-identical, folds left as informational |
| Clean models (ex4, Sardiniers6, bench_scan, finCup, Hitem3d) | "Nothing to fix" — no phantom damage, no Repair offered |
| TeaPot (inverted lofts, 10 slits, 2 openings) | Safe set stitches the slits and flips orientation → 2 opening cards (e.g. Walls + capped bottom floor) |
| Dripper1 (tube, 2 planar openings, inverted) | Flip → Solid with Flat caps ≈ the owner's own Dripper1_closed.stl |
| Cupping (CAD patches, T-junction seams, one patch flipped) | Stitch geometrically → orient with patch flip → cards |
| diamondback_cup_nobottom (planar opening) | One card; Flat style available because the rim projects simply |
| FossilFootprint relief | Open skin (relief) → Flat base |
| shell_for_cat (zero-volume internal shell) | Safe set removes it |
| Hollowed sculpture / flipped inner shell / ship in a bottle | Bodies/cavities choice — never auto-filled or merged |
| Text with an i-dot, earrings with jump rings | Nothing deleted (closed positive-volume bodies are never debris) |
| Vase skin with a 3 mm drain hole | It is an opening (not a pinhole) → card, default Leave open |
| Fin or leaf on a solid | Thicken sheet (centered) + union |
| Möbius / one-sided surface | Labelled "one-sided"; only centered thickening offered |
| Un-bridged double wall (Hollow of an open skin) | Join rims |
| Raw photogrammetry soup | Raw-scan archetype → shown default recipe: fill holes ≤ X mm + flat base; Rebuild as solid if local fill fails over a large area |
| Points-only / empty file | "No surface to repair"; consumers disabled |
| handsStand3 (one body self-overlapping over 7% of faces) | v1: remove its junk shell, report the remote contacts; true self-union needs an arrangement engine (later) |
| Anything unrecognised | Measure → safe set → verify; unresolved sites are reported with location and reason, the rest of the model is untouched; Rebuild as solid is offered, never forced |

## Consumers
- Each consumer gets a **readiness predicate** shown as "Ready for": Slicing
  and Partition need closure (open chains are dropped); Split-by-Undercuts
  refuses open input; MotherMold needs closed + Manifold and strict
  2-manifold on export; Structures/Inflatables need a Manifold solid.
- Delete the private GWN heals in Structures (`StructureInfillEngine.swift:1991`)
  and Inflatables (`InflatableClean.swift:14`) — today they would silently
  override "Leave open" by filling the vessel. Disable with a reason instead.
- Re-point every "Make Watertight" recovery (`ContentView.swift:1958, 3324`,
  `UndercutSplitPlanner.swift:683`, `DirectionalAccessibilityAnalyzer.swift:173`)
  to Model Health.
- MotherMold contract unchanged: no healing inside MotherMold; repair happens
  upstream. Strict finishing (hoisted MotherMoldValidation ladder) runs only
  at defect sites — globally, `simplify(0.05)` leaves only 76–83% of a clean
  hand untouched.

## UX (artist-first)
- Issues panel → **Model Health**: one diagnosis sentence, then actions.
  Positions worded relative to the confirmed up axis.
- Viewport markers per site, colour by class; click to fly to it
  (Meshmixer Inspector pattern; reuse the undercut/MotherMold overlay and
  surface-pick plumbing).
  *Built (2026-09):* `OpeningCapper.Diagnosis.sites` (kind, centroid, size,
  title, what Fix in place does; ≤ 50 per kind, the rest counted) recorded by
  the passes that find each problem; `IssueMarkers.swift` holds colours, the
  constant-screen-size radius, click picking and the fly-to camera (same view
  direction, site to screen centre, zoom from size within the 0.2–5 zoom
  limits); markers draw on top of the model (unlit, blended, depth-read off),
  only on the Issues tab for a current diagnosis of the displayed mesh.
  Issues panel lists the sites; a row or marker selects + flies; Escape or an
  empty-space click deselects. Headless: `--diagnose-sites`.
- Before/after toggle, change heat-map, progress + Cancel for anything > ~1 s.
- Controls that do not apply are hidden or disabled with a hint.
- Naming: "Make walls" (not "Thicken" — Modify Form's Thicken is a different,
  persisted op). Later, move Modify Form's Hollow onto the same level-set
  construction (it has the same concave self-intersection flaw).

## Engineering notes
- **Topology core**: a compact halfedge module (collapse with link condition,
  flip, split, pinch split) is a prerequisite — none exists today.
- **Hole fill and fairing**: Swift port of Liepa + refinement + harmonic /
  bi-harmonic fairing on Accelerate `SparseFactor` (verified callable from
  this package; 20k-unknown solve in 18.6 ms). Planar caps may use
  `manifold_triangulate`.
- **Crossing-free caps (Fix in place)**: an opening's cap keeps the Liepa +
  refinement triangulation, but its corners are moved onto a level set
  {w = c} of the generalized winding number w of the skin plus every other
  cap (`WindingLevelField`: octree with a second-order far field, exact near
  field, analytic gradient). Across the skin w jumps by exactly 1, so a level
  set with 0 < c < 1 never passes through the skin (Jacobson et al. 2013);
  c = 0.5 is the flat cap (exactly the plane of a planar rim). Corners are
  placed ring by ring from the rim so each lands on the same side of the
  skin as the corners it hangs from; Newton steps never jump the skin.
  Leftover crossings are refined locally (rim chords first), then micro
  contacts (a skin corner within microns of a rim edge) get a
  keep-only-if-better nudge. A rim that touches itself within 0.5% of an
  edge length is capped as lobes meeting at the contact; a rim sliver folded
  flat back onto its neighbour is removed (reported as a doubled-up
  triangle). Dome/dish: root-finding on c so the peak moves the requested
  height off the flat cap; where a uniform level runs into the skin at the
  rim (crown valleys), the level is graded by the membrane's pressure
  profile (c = 0.5 at the rim) instead; unreachable heights are clamped and
  the measured height reported. If the level set can't be followed, the
  plain membrane is kept (never more crossings than before). Known limit:
  strongly shingled synthetic crowns (every leaf passing over both
  neighbours) still leave a few crossings, counted in the receipt — 8 leaves
  twisted 0.54 rad: 9 (membrane 65); 10 leaves 0.36 rad: 5 (17); 12 leaves
  0.3 rad: 5 (18). The pineapple cup and the 8-leaf 0.56 rad test crown
  close with none.
- **Make walls construction**: temporary cap V → inner solid
  I = {x ∈ V : dist_to_skin(x) > t} with an explicit **cap overshoot** (without
  it the difference leaves a film of 2,186 fragments at the opening; with it:
  1 component, wall 2.000–2.118 mm for t = 2) → `simplify(I)` →
  64-bit `V − I`. Grid pitch ≈ t/2 with a hard memory cap (Manifold's buffer
  ≈ 153 MB at t = 2 on the pineapple, ≈ 1.2 GB at t = 1 on a hand); splat
  triangle bands into the lattice and flood-fill the sign instead of
  per-sample BVH queries. Gates: 1 component, expected genus, nothing
  inside the opening.
- **Caching / recipe**: topology repair on raw coordinates, keyed by source
  fingerprint + recipe; scale and rotation after; form ops (walls, dome
  height) in mm on top. LRU of 2–4 entries; undo stops nilling valid caches.
  Recipe is Codable in project settings, carries the source fingerprint,
  geometric loop signatures (centroid, normal, perimeter) with a visible
  "recipe no longer matches this model" state, and versioned ops. Add a
  geometry revision ID to `MeshSummary` before any count-preserving op ships
  (today undo and the viewport cache are keyed on triangle counts).
- One `RepairPipeline.apply(recipe)` for GUI, `--mesh-audit` (gains a unit
  flag), `--headless-export` and `--dump-mesh` (today headless and GUI apply
  Hollow/Thicken and the heal in opposite orders).
- `MANIFOLD_PAR=ON` (static oneTBB) is a separate, later decision: it
  parallelizes every Manifold op app-wide but needs determinism checks
  against the MotherMold goldens.

## Milestones (sizes; each gets a hard iteration cap when started)
- **H0 — Stop Repair deleting geometry** (small; hotfix): Repair removes only
  collapsed-index faces and isolated zero-area debris; never offered when the
  only "defects" are slivers. Sequence after `codex/mothermold-artist-ux`
  merges (it carries a test that depends on today's threshold).
- **M0a — Truthful diagnosis** (medium): `MeshDiagnosis` with unit-invariant
  tolerances, loops/pinholes/cracks, components, orientation, archetype;
  Model Health shows it; consumers still read the frozen MeshPreflight.
- **M0b — Honest, faster Rebuild** (medium): output-identical narrow band +
  parallel prefill + progress/Cancel; flip-before-GWN; errors surfaced.
- **M1 — Fix small problems** (medium-large): halfedge core + revision ID +
  the safe set. Gate: ex1/2/3 closed, Manifold-accepted via 64-bit import,
  ≥ 99.5% bit-identical, folds informational; clean files stay "Nothing to
  fix"; idempotent after an STL round trip.
- **M2 — Openings: Smooth cap** (medium-large): Liepa + fair + cap-vs-mesh
  intersection check; Solid mode on the pineapple and Dripper.
- **M3 — Make walls** (large): reuses M2's cap as the temporary V.
- **M4 — Dome↔Dish, Flat, Flat base, grouped openings** (medium).
- **M5 — Recipe persistence, readiness predicates, consumer migration,
  private heals removed** (medium).
- **M6 — Rebuild v2 output changes** (medium): continuous field, crumb filter,
  snap-back, cavities choice, versioned replay.
- **Later / spikes**: markers polish, Join rims, Thicken sheet, bulk scan
  fill, thin-wall analysis, local self-intersection resolution, exact
  self-union (arrangements; license check on Geogram BSD-3 / Cherchi MIT),
  local rebuild splice (research-grade), `MANIFOLD_PAR=ON`.

## Acceptance
**Local-only real corpus** (the owner's private model library, SHA-256 pinned,
availability-checked; some files are online-only placeholders). Only the two
hand scans are committed, under `app/RefabArtist/Tests/Fixtures/hand-scans/`;
the others are looked up by file name:

| File | Expected |
|---|---|
| pineapple_cup.obj | safe set fixes 4 doubled pairs, 2 loose tris, pinhole, pinch; Solid/Smooth and Walls both closed with crown intact |
| handStand_ex1/2/3.obj | Fix small problems: closed, Manifold OK, ≥ 99.5% bit-identical |
| handStand_ex4.obj | Nothing to fix |
| Sardiniers6.obj | Nothing to fix; no triangles lost |
| bench_scan.obj | Nothing to fix (folds informational) |
| BirthdayMongo_smooth.obj | 2 pinholes filled, nothing else |
| shell_for_cat.obj | internal junk shell removed |
| finCup.obj | Nothing to fix for closure; thin-wall info |
| Dripper1.stl | flip + Solid/Flat ≈ Dripper1_closed.stl |
| TeaPot1.obj | slits stitched, flipped, 2 opening cards; never a silent no-op |
| Cupping.obj | seams stitched with patch flip, then cards |
| diamondback_cup_nobottom.obj | one card, Flat available |
| UMesh_Pluriversal.obj | two cards |
| orig_3.obj (the fossil footprint relief) | Flat base offered |
| handsStand3.stl | junk shell removed, remote contacts reported (v1) |

**Committed synthetic fixtures** (CC0, generated in-repo), one per defect
class and one per intent trap: back-to-back pair, pinch-vertex rim, isolated
zero-area face, T-junction seam, inverted open skin, scalloped non-planar rim;
i-dot text, earrings with jump rings, vase skin with a 3 mm drain hole,
hollow sphere, flipped inner shell, nested body, un-bridged double wall, fin
on a solid, Möbius strip, points-only OBJ, lattice. Plus regression cases
`spur_gear_T20_M2.stl` and `cube_zero_area_face.stl`, and an idempotence test
(`diagnose(apply(recipe))` after an STL round trip = Nothing to fix).

## Evidence
2026-09-24 session scratchpad (`wf/result.json`, `wf/critique.json`,
`wf/evidence/`, `wf/critique/`): per-model true topology, defect locality
(ring-0/1/2), the strip-and-refill proof of concept on the hands
(99.77–99.96% untouched, Manifold NoError), 64-bit vs float32 bit-identity
probes, the Make-walls film/overshoot experiment, synthetic intent traps, and
shipped-binary audits with timings. Counts of self-intersections in the
evidence are lower bounds (the probe skipped vertex-sharing pairs).
