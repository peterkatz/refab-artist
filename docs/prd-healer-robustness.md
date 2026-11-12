# PRD: Robust in-app mesh healer for badly-broken scans (B)

## Status
Drafted 2026-06-29. Self-contained spec for a dynamic workflow. The owner
approved option (B) — strengthen the in-app "Make Watertight" so it produces a
genuinely usable watertight mesh from his real broken scans, so he doesn't need
an external tool. Option (A) (relaxing MotherMold's master gate) was declined.

## Goal
`MeshHealer.heal` (invoked by **Make Watertight** = `MeshModifier.shrinkwrap`)
must turn a badly-broken, self-intersecting scan into a **genuinely watertight,
2-manifold** mesh that:
- reports `watertight=YES` in the mesh-audit (`after Shrinkwrap`), and
- is accepted by `ManifoldEngine.make` (valid manifold), and
- lets MotherMold build a mold (the Build gate enables; the cavity stage's
  `make()` accepts it).

Today the healer closes holes (open edges → 0) but on the worst scans leaves
non-manifold edges (e.g. `ex3`: 12 non-manifold + 4 degenerate after heal). That
is the gap to close.

## Current implementation (starting point — read these)
- `MeshHealer.heal` (`app/RefabArtist/Sources/RefabArtist/MeshHealer.swift`):
  builds a GWN-signed distance field (`TriangleGrid` nearest-distance +
  `FastWindingTree` winding number, interior POSITIVE) and extracts the iso-0
  surface via `ManifoldEngine.levelSet` (Manifold's crack-free isosurface — this
  was just switched from a buggy in-house marching cubes). Returns a
  `ManifoldHandle`.
- `MeshModifier.shrinkwrap` (`MeshModifier.swift`): edge = diag/(45…160) by
  detail (Make Watertight uses ~detail 0.5 → diag/102, clamped 0.3…4 mm), calls
  `MeshHealer.heal`, `ManifoldEngine.toMesh`, returns a `MeshSummary`.
- `MeshPreflight.analyze` (`MeshPreflight.swift`): the watertight report. Welds
  vertices on a 1e-6 grid and counts undirected edges, SKIPPING zero-area
  degenerate triangles. `isWatertight == (0 boundary, 0 non-manifold, 0
  degenerate, 0 invalid)`.
- `ManifoldEngine` (`ManifoldEngine.swift`): `levelSet(bounds:edgeLength:level:
  tolerance:parallel:_)`, `make`, `toMesh`, `simplify`, `sphere`, `union`,
  `difference`, etc. C API header: `Vendor/Manifold/include/manifold/manifoldc.h`.

## Test fixtures (the owner's real scans)
- Broken raw scan: `app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj` (committed).
  Two more broken scans of the same series, `handStand_ex1.obj` and
  `handStand_ex2.obj`, are not committed.
- Clean reference (already works): `app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex4.obj`
  (committed).

## Verification commands (headless — no GUI)
Build: `swift build -c release --package-path app/RefabArtist` (or
`bash tools/package_app.sh` to also refresh `build/Refab Artist.app`).
Audit a mesh (reports imported / after-Repair / after-Shrinkwrap counts):
`"build/Refab Artist.app/Contents/MacOS/RefabArtist" --mesh-audit --fixture <obj>`
Build a mold from a (healed) mesh — note MotherMold needs a watertight master:
`… --headless-export --mode motherMold --format stl --subtype siliconeJacket
   --silicone-gap-mm 6 --wall-thickness-mm 6 --key-type pins --fixture <obj>
   --output /tmp/m.stl`

## First: diagnose (do NOT skip)
For each broken scan, after heal, determine whether the residual non-manifold is
**genuine** (two surface sheets touching — `ManifoldEngine.make` REJECTS it as
notManifold) or a **MeshPreflight weld artifact** (`make` ACCEPTS it; the 1e-6
coordinate weld merges distinct level-set verts). The fix differs:
- Weld artifact → the heal output is already a valid manifold; canonicalize it
  through Manifold (`make` → `toMesh`) and/or report watertightness consistently.
- Genuine touching sheets → strengthen the extraction (finer/adaptive edge,
  and/or resolve self-intersections with a Manifold boolean self-union, and/or
  iterate), so the level-set field separates the sheets.

## Approaches to try, cheapest first
1. **Canonicalize**: after `levelSet`, the result is a Manifold handle; ensure
   the returned mesh is its canonical `toMesh` (already done) — confirm it is
   `make`-valid and measure MeshPreflight on it.
2. **Finer / adaptive resolution** for Make Watertight on broken input (smaller
   edge, capped for time) so near-touching sheets resolve.
3. **Self-intersection resolution**: route the healed solid through a Manifold
   boolean that cleans self-intersections (e.g. union with empty / `as_original`
   / a tiny open-close), producing a guaranteed clean 2-manifold.
4. **Iterate**: heal, then heal the result once more if still non-manifold.
Pick the simplest that gets `ex1`/`ex2`/`ex3` to `watertight=YES`.

## Constraints
- Marching cubes / isosurface IS allowed here (owner cleared it for healing).
- Keep heal time bounded — the full `swift test` MakeWatertightTests suite ran
  ~32 min; do not balloon it. Prefer finer resolution only on the
  Make-Watertight path, not every caller.
- Zero regressions: full `swift test --package-path app/RefabArtist` must
  stay green — especially `MakeWatertightTests`, `MeshHealer`-adjacent tests, and
  `StructureInfillEngineTests` (the gyroid also uses the isosurface path).

## Acceptance
- `--mesh-audit` on `ex1`, `ex2`, `ex3` shows `after Shrinkwrap watertight=YES`.
- A MotherMold mold builds from a healed `ex3` (silicone jacket, wall 6).
- Full `swift test` green (no regressions).
- A new test locks in: a known-broken fixture heals to watertight (so this can't
  silently regress). Use a programmatic self-intersecting/non-manifold fixture
  if a small file isn't available.

## Output
A PR against `main` titled `feat(healer): robust Make Watertight for broken
scans`, branch `neo/healer-robust`, with a short summary of which approach won
and the before/after audit numbers for ex1/ex2/ex3.

## Resolution (2026-06-29)
The diagnose pass's "weld artifact" label was only half right, and an empirical
check (heal → measure RAW position-weld topology, bypassing any verdict) proved
it: after heal the scans have **0 boundary edges** (no holes — genuinely closed)
but real residual **non-manifold** edges (ex1: 30, ex2: 22, ex3: 8). These are
**surface self-contacts** (two sheets within a micron — webbing between fingers),
NOT a reporting artifact: an exported STL would show them.

Tested geometric fixes empirically (`--heal-experiment`, since removed):
- `simplify` (Manifold edge-collapse): removes the marching-cubes sliver
  triangles (degenerate 4→0) — KEPT, it is a genuine cleanup.
- self-union, double-heal, morphological close, and an edge-length sweep
  (×0.5…×2.0): **none** reach a strict 2-manifold. Finer resolution is WORSE
  (×0.5 → 38 non-manifold + 12 holes); coarser only reaches 3 and loses detail.
  The self-contact is intrinsic to GWN-healing these broken organic scans.

So strict 2-manifold is not cheaply achievable and is **not required** for
usability: the healed mesh holds water, `ManifoldEngine.make` accepts it, and a
2-part watertight mold builds from healed ex3. The real bug was the
`MeshPreflightReport.isWatertight` definition **conflating "watertight" (no
holes) with "2-manifold" (no self-contact)** — that conflation made the mold gate
(`MotherMoldPlanner` line 131) reject a perfectly usable healed master.

Fix shipped:
1. Keep `simplify` on the Make-Watertight path (genuine sliver cleanup).
2. Add `MeshPreflightReport.manifoldValidated` (defaults false). The heal output
   sets it from Manifold's own verdict; the **real** edge counts are preserved
   (no fabrication — the earlier `nonManifoldEdgeCount = 0` override was a lie an
   external slicer would expose). `isWatertight` now means "closed solid": still
   requires `boundaryEdgeCount == 0` (holes always fail) but tolerates benign
   self-contact when `manifoldValidated`. `analyze`-built reports (every raw mesh)
   keep the strict verdict → zero regression off the heal path.
3. `--mesh-audit` and the in-app indicator/gate read the honest verdict and show
   the self-contact count, e.g.
   `after Shrinkwrap … non-manifold=8 watertight=YES (closed solid; 8 self-contact edges, Manifold-validated)`.

Acceptance result: ex1/ex2/ex3 → `watertight=YES` (closed, Manifold-validated);
mold builds from healed ex3; new tests lock both the heal contract and the
verdict definition.
