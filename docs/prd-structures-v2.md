# PRD — Structures v2: Infill · Supports · Skin

**Date:** 2026-07-02 **Status:** Contract for the GPT 5.5 rebuild run. **Supersedes** `docs/prd-structures-construction-mode.md` (the façade-era wish list — do not implement from it; anything worth keeping from it is restated here).
**Companion:** `docs/handoff-gpt55-structures.md` is the execution brief (process rules, milestones, gates, algorithm appendix). Where the two conflict, this PRD's *product* rules win and the brief's *process* rules win.

---

## §0 Orchestration & token economy (applies per milestone)

The main thread is the ORCHESTRATOR. It holds: this PRD, the WU DAG (§5), the §4 contract, and the **current milestone only**. It does not edit source files itself.

- Dispatch **one sub-agent per WU** with: the WU text verbatim, its exact read-set (files + line ranges from §5), the §4 contract, its acceptance test, and its verify command. Collect **structured summaries, never file dumps**.
- **Banned (the 6/29 failure mode):** if a sub-agent is slow, wait for it or respawn it — never "take over the implementation in the main thread."
- Route mechanical work (test scaffolding, fixture generation, audit-script plumbing, screenshot capture) to cheaper/faster models where the harness supports model selection; reserve the strongest model for the algorithm cores (WU-4, WU-6, WU-9, WU-10, WU-12, WU-13) and for gate verification.
- If the harness cannot delegate: compensate, don't improvise — never read whole large files (`rg` + the cited line ranges only; `ContentView.swift` is enormous), and reset context at every milestone boundary: commit, update the report, continue from the brief + the report alone (both are self-contained by design). After any context compaction, re-read brief §3 and the current milestone before writing more code.
- Mandatory sub-agent output block:

```
WU-<n> <title>
status: DONE | BLOCKED | CONTRACT-CHANGE
files_created: [...]
files_modified: [...]
public_symbols: [ Type/func signatures added or changed ]
verify_cmd: <command>
verify_result: <build ok? acceptance pass? 1-3 lines>
notes: <≤5 lines: assumptions, follow-ups, anything the next WU needs>
```

Any change to a §4 signature requires `status: CONTRACT-CHANGE` with justification; the orchestrator updates this PRD's §4 before dependent WUs launch.

**Coordination with the Inflatables run:** another agent owns `app/RefabArtist/Sources/RefabArtist/Inflatables/` and the inflatables sections of `HeadlessExportCommand.swift`. Never edit Inflatables files. `ContentView.swift` and `HeadlessExportCommand.swift` are shared — make only additive, structures-scoped edits. If a merge conflict with inflatables work appears, STOP (brief R7). Line numbers in this PRD/brief were audited on `main @ c57b90f`; they may drift after the inflatables merge — **always `rg` the symbol first, never trust a line number blind.**

---

## §1 Product vision (owner's requirements, 2026-07-02)

Structures becomes a three-subtype construction mode. All three emit watertight, printable, mesh-only geometry (STL/OBJ), rendered exactly as exported.

1. **Infill** (exists, 15 patterns) — two upgrades:
   a. **Speckle-free gyroids.** "The gyroids feature that uses marching cubes still leaves speckles on the surface of the mesh. Despite me having asked it to fix that." This is the owner's #1 grievance; it must be fixed first and proven with a measured gate, not a screenshot claim.
   b. **Spatially-varying cell size.** "I tried to get it to create structures based on some Op Art art work where the size of the cells could be varied and it seems like it couldn't figure that out because all the cells came out the same size." Cell size becomes drivable by a density field: uniform, grayscale image, attractor points, or distance-to-surface. Plus new Op-Art patterns the machinery makes possible.
2. **Supports** (enum exists, engine missing) — organic tree supports in the Cura/Prusa visual style, with **Sculpture mode as the primary product**: "I actually want to make sculptures out of it. I got the idea one time when I made a mask and needed to generate supports… when I took the physical mask off the supports themselves formed the face in a really cool way. I was envisioning making it easy to generate new ideas using the supports snaking all the way up to reform the upward facing surface of arbitrary meshes." Sculpture mode seeds branch tips densely on a chosen surface (default: up-facing) so the tips *reform* that surface; Scaffold mode is the classic printable-support variant (overhang detection + model avoidance) that recreates the original mask workflow physically.
3. **Skin** (never existed) — Crystallon-style hollow shells: "hollow structures where the skin of the mesh is formed by voronoi and other patterns… in the same way that the grasshopper plugin crystallon lets you create." The model's surface is replaced by a strut network (Voronoi/hex/triangle cells) or a perforated shell; output is a standalone hollow object. Cell size obeys the same density fields as Infill.

Non-goals for this run are pinned in §7 — deviating scope is a decision, not an omission.

---

## §2 Subtypes & parameters

All numeric parameters flow through `StructureSettings.sanitized` clamps; all persistence uses new tolerant-decode keys (never reuse the legacy `pattern` key — rawValue collisions; `patternV2` precedent at `app/RefabArtist/Sources/RefabArtist/Structures.swift:277`).

### §2.1 Common

| Param | Type | Default | Clamp | Notes |
|---|---|---|---|---|
| `category` | `.infill / .support / .skin` | `.infill` | — | `.skin` is a NEW enum case; unknown rawValue decodes to `.infill` (existing fallback pattern) |
| `seed` | UInt64 | 1 | ≥1 | already persisted as UInt64 default 1 (`Structures.swift:179`); becomes live for stochastic patterns |

### §2.2 Density (shared by Infill + Skin; NEW)

| Param | Type | Default | Clamp | Notes |
|---|---|---|---|---|
| `densitySource` | `.uniform / .image / .attractors / .nearSurface` | `.uniform` | — | |
| `minCellMm` / `maxCellMm` | Double | cellSize / cellSize | 1…200, min ≤ max | `.uniform` ⇒ both = `cellSizeMm` |
| `imagePath` + `imageProjection` (`.xy/.xz/.yz`, bbox-fit) + `invertImage` | — | — | — | grayscale sampled bilinear; dark = small cells by default. **Pixel value t∈[0,1] interpolates DENSITY, not cell size:** `cellSize(t) = 1 / lerp(1/minCellMm, 1/maxCellMm, t)` — this makes the M2 integral gates exact (brief §6.7). Load via CGImage (NSImage→CGImage). **Known crash:** `TextureResource(named:)` SIGSEGVs under SwiftPM — never load images through RealityKit resources. |
| `attractorPreset` | `.center / .top / .bottom / .custom(point)` | `.center` | — | + `falloffMm` (5…500) |
| `nearSurfaceBandMm` | Double | 10 | 1…100 | generalizes the CubicSubdivision distance driver |

Patterns that cannot honor a density source must disable those controls with a hint (owner rule: no silently dead controls). The support matrix is pinned in §5 (WU-7/WU-9).

### §2.3 Supports

| Param | Type | Default | Clamp |
|---|---|---|---|
| `supportMode` | `.sculpture / .scaffold` | `.sculpture` | — |
| `targetSurface` | `.upFacing / .downFacing` + `surfaceAngleDeg` | `.upFacing`, 40 | 5…89 |
| `tipSpacingMm` | Double | 4 | 1…50 |
| `tipDiameterMm` | Double | 1.2 | 0.4…10 |
| `branchDiameterMm` (max) | Double | 5 | tip…40 |
| `diameterAngleDeg` (taper τ) | Double | 5 | 0…15 |
| `preferredAngleDeg` / `maxAngleDeg` | Double | 25 / 40 | 5…60, pref ≤ max |
| `stepMm` (growth layer) | Double | 1.0 | 0.25…5 |
| `xyClearanceMm` (scaffold only) | Double | 0.8 | 0.2…5 |
| `restPreference` (scaffold only) | `.plateOnly / .plateAndModel` | `.plateOnly` | — |

Sculpture mode: no avoidance, branches may pass through the model volume, merge freely, root on the plate. Scaffold mode: model avoidance + clearance, tips touch only the target overhang surface. A down-facing surface closer to the plate than a tip plus its contact offset rests on the plate and is not an overhang; a model with no other down-facing surface (a cube, a flat-based stand) reports that nothing needs support.

### §2.4 Skin

| Param | Type | Default | Clamp |
|---|---|---|---|
| `skinStyle` | `.struts / .perforated` | `.struts` | — |
| `skinPattern` | `.voronoi / .hex / .triangles` | `.voronoi` | — |
| `cellSizeMm` | Double | 12 | 2…200 (+ Density §2.2) |
| `strutDiameterMm` (struts) | Double | 2 | 0.5…10 |
| `wallThicknessMm` + `ribWidthMm` (perforated) | Double | 2 / 2 | 0.5…10 |

`.hex` / `.triangles` are seed-lattice variants of the same machinery (hex-lattice seeds ⇒ hex Voronoi cells; Delaunay edges instead of Voronoi dual ⇒ triangles) — not separate engines.

---

## §3 UI contract

- The existing `Type` segmented picker (`StructuresPanel`, `app/RefabArtist/Sources/RefabArtist/ContentView.swift:6365`) gains **Skin**; **Supports** flips live when its milestone gate is green. Until a subtype's engine lands, its segment stays disabled-with-hint (existing `.support` precedent at `ContentView.swift:6448`).
- Per-subtype parameter sections per §2; density subsection appears for Infill + Skin only. Every control that a current selection makes irrelevant is disabled or hidden **with a reason string** — after any UI change, sweep the whole Structures panel for dead controls before calling the WU done.
- The explicit-Generate contract is unchanged: nothing recomputes on slider drag; `Task.detached` off-main; signature-staleness hides stale plans (`generateStructure()` `ContentView.swift:2143`, `structureInputSignature` `:2109`). New subtypes must extend the signature so every new parameter participates in staleness.
- Long jobs get cooperative cancellation checkpoints (engine checks `Task.isCancelled` between phases, not only at the end).
- Complexity-cap coarsening (existing caps + new ones) must surface in the UI/plan as a visible "coarsened to N%" notice and an audit JSON field — never a silent stderr line.
- Viewport continues to render the exact export layers (`makeStructureSolidEntity`, `app/RefabArtist/Sources/RefabArtist/ModelSceneView.swift:971`); never fork a display-only geometry path. Curved outputs (gyroids, branches) smooth-shaded; flat-walled patterns flat-shaded (family split at `StructureInfillEngine.swift:1806`).

---

## §4 Engine contract (public symbols; changes require CONTRACT-CHANGE)

Existing types this contract binds to (do NOT invent parallels): solids are **`ManifoldHandle`** (`ManifoldEngine.swift:60`), bounds are **`Bounds3D`** (`MeshInspector.swift:17`), points are **`Vec3`** (`MeshInspector.swift:3`), and `ManifoldEngine` is a namespace of **static funcs** — generators receive `engine: ManifoldEngine.Type` today; keep that style.

```swift
// ── ManifoldEngine additions (WU-1) — thin static wrappers over existing C API, no new geometry math
extension ManifoldEngine {
    static func convexHull(_ solid: ManifoldHandle) throws -> ManifoldHandle                    // manifold_hull
    static func convexHull(of points: [Vec3]) throws -> ManifoldHandle                          // manifold_hull_pts
    static func convexHull(joining a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle // batch_hull of [a,b] — the capsule primitive
    static func decompose(_ solid: ManifoldHandle) throws -> [ManifoldHandle]                   // manifold_decompose
    static func slice(_ solid: ManifoldHandle, atZ z: Double) throws -> [[SIMD2<Double>]]       // manifold_slice → closed polygons
}

// ── Generator seam (WU-5) — replaces makeWallSolid(bounds:params:engine:) and the
//    CubicSubdivision sourceVertices `as?` injection hack (StructureInfillEngine.swift:1479)
struct WallSolidContext {
    let bounds: Bounds3D                 // HEALED-solid bounds (clip space) — same source as today (:1474)
    let params: InfillParameters
    let engine: ManifoldEngine.Type
    let density: DensityField
    let sourceVertices: [Vec3]           // for .nearSurface density (existing data path)
}
protocol WallSolidGenerator { func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldSolid }

// ── Density core (WU-6)
struct DensityField {                    // value semantics; thread-safe; pure
    func cellSize(at p: SIMD3<Double>) -> Double        // ∈ [minCellMm, maxCellMm], total ∈ [1,200]
    func lineDensity(at p: SIMD3<Double>) -> Double     // 1 / cellSize(at:)
}
struct VariableSpacing {                 // cumulative-integral line placement (brief §6.2)
    // positions of family lines along `axis` over [lo,hi] such that local spacing tracks the field
    static func linePositions(field: DensityField, axis: SpacingAxis, lo: Double, hi: Double,
                              sampleAt: (Double) -> SIMD3<Double>) -> [Double]
}

// ── Post-clip hygiene (WU-4) — inside StructureClipEngine.clippedInfill, after intersect
struct ComponentFilter {
    // drop components with volume < max(relFloor·totalVolume, absFloorMm3) OR bboxDiagonal < minBBoxDiagonal
    // (both criteria — brief §6.1); returns kept solid + dropped stats
    static func filterSpecks(_ solid: ManifoldHandle, engine: ManifoldEngine.Type,
                             relFloor: Double, absFloorMm3: Double, minBBoxDiagonal: Double)
        throws -> (ManifoldHandle, droppedCount: Int, droppedVolume: Double)
}

// ── Supports (WU-10/11/12)
struct SupportSettings: Codable, Equatable { /* §2.3 fields; sanitized clamps */ }
struct BranchNode { var position: Vec3; var radius: Double; var parentIndex: Int? }
final class SupportTreeBuilder {
    // Vanek-style greedy top-down node growth with Cura/Prusa parameterization (brief §6.5).
    // sculpture: avoidance == nil. scaffold: avoidance = per-radius-bucket Minkowski-inflated model.
    func buildForest(tips: [Vec3], plateZ: Double, settings: SupportSettings,
                     avoidance: AvoidanceVolumes?) throws -> [BranchNode]
}
struct SupportSolidifier {
    // capsules (convexHull(joining: sphere(a,ra), sphere(b,rb))) per parent-edge, tree-reduce union
    static func solidify(forest: [BranchNode], settings: SupportSettings, engine: ManifoldEngine.Type) throws -> ManifoldHandle
}
struct AvoidanceVolumes {                // scaffold only (WU-12)
    // buckets: minkowskiSum(model, sphere(r_bucket + xyClearance)) for r_bucket ∈ {tipR, midR, maxR}
    func isClear(_ p: Vec3, radius: Double) -> Bool     // slice-cache + even-odd point-in-polygon
    func pushOut(_ p: Vec3, radius: Double, maxStep: Double) -> Vec3?
}

// ── Skin (WU-13/14)
struct SkinSettings: Codable, Equatable { /* §2.4 fields */ }
struct SurfaceSampler {
    // Poisson-disk on mesh surface, radius from DensityField (weighted sample elimination, brief §6.4)
    static func seeds(onSurfaceOf mesh: MeshGeometryData, density: DensityField, seed: Int) -> [SurfaceSeed]
}
struct SurfaceCellNetwork {
    // nearest-seed vertex labeling → boundary polylines (Voronoi dual) or Delaunay edges (brief §6.6)
    static func voronoiEdges(mesh: MeshGeometryData, seeds: [SurfaceSeed]) -> [Polyline3D]
    static func delaunayEdges(mesh: MeshGeometryData, seeds: [SurfaceSeed]) -> [Polyline3D]
}
final class SkinShellBuilder {
    func buildStruts(network: [Polyline3D], settings: SkinSettings, engine: ManifoldEngine.Type) throws -> ManifoldHandle
    func buildPerforated(mesh: MeshGeometryData, network: [Polyline3D], cells: [SurfaceCell],
                         settings: SkinSettings, engine: ManifoldEngine.Type) throws -> ManifoldHandle
}

// ── Routing
// StructurePlanner.planThrowing (StructureInfillEngine.swift:1778) branches on category;
// StructureMeshPlan gains `coarseningNotice: String?`. The bounds ⊆ source test invariant
// (StructureInfillEngineTests.swift:36) becomes category-aware: it holds for .infill and .skin,
// and is replaced for .support by "bounds ⊆ source ∪ plate-to-model column".
```

Hard rails (violating any of these is a defect, not a style choice): all new solids are built from **exact CSG primitives** (box/sphere/hull/extrude/Minkowski + boolean); marching cubes remains **gyroid-only** — any new MC use requires explicit owner sign-off first; every loop extrusion goes through `GyroidManifold.extrudeSlab` (`GyroidInfill.swift:207` — its CrossSection normalization is a segfault guard); unions of many solids use the tree-reduce `ManifoldEngine.union(_:)` (`ManifoldEngine.swift:430`) — `manifold_batch_boolean` segfaults, never call it; manifold-preserving `simplify` for solid reduction (stride decimation is acceptable only for Minkowski *input* meshes, per the `MoldCavityBuilder.swift:62` precedent); the world-global lattice phase anchoring (`s = k·cell`, `StructureInfillEngine.swift:471`) is load-bearing for CubicSubdivision nesting.

---

## §5 Work units (DAG). Read-sets are exact; `rg` the symbol if lines drifted.

| WU | Title | Depends | Read-set (files + anchors) | Acceptance (summary — gates in brief §4) |
|---|---|---|---|---|
| 1 | Wrap hull/decompose/slice in ManifoldEngine | — | `ManifoldEngine.swift` (:126–:520 API region), `CManifold/include/manifold/manifoldc.h:139–146,209`, `ManifoldEngineTests.swift` | capsule volume vs analytic ±3% @ 32 segs; decompose splits 2-sphere solid into 2; cube slice area exact |
| 2 | Structures audit JSON (extend `--measurement`) + fast fixture + dead-code removal | 1 | `HeadlessExportCommand.swift` (`exportStructures` — main@c57b90f :425, flag parsing :437–457; the working tree carries inflatables edits that shift these, `rg` first), `RefabArtist.swift:10–67`, `StructurePatternExportTests.swift` | enrich the existing structures `--measurement <path>` JSON (additive keys only): componentCount, componentVolumes desc, watertight, triangleCount, coarseningNotice, timings, per-subtype metrics — this enriched output is "the audit JSON" all later gates reference; fixture `app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj` + regen script (reuse the inflatables run's fixture if it already exists); delete dead `LatticeInfill.swift` + fix the stale comment at `StructureInfillEngine.swift:618` |
| 3 | Failing speckle acceptance tests (R4) | 2 | `StructureInfillEngine.swift` (`GyroidMC.solid` :1268, `clippedInfill` :1461), `SurfaceDespeckle.swift` | a config that REPRODUCES the visible speckles as a measured metric (sub-floor components and/or sliver-bbox components); test RED on current main — if the metric can't catch what the eye sees, iterate the metric, not the claim |
| 4 | Post-clip component filter + clip-fidelity lift | 3 | `StructureClipEngine` (:1366–:1491), `MeshHealer.swift:80`, `MeshModifier.swift:395–425` | WU-3 tests GREEN; filter both wall-solid (pre-clip) and result (post-clip); reuse full-res Make-Watertight heal when cached / raise `maxCells` within a measured time budget; dropped-speck stats in audit |
| 5 | `WallSolidContext` seam migration | 1 | `StructureInfillEngine.swift` (protocol :50, all 15 generators, `sourceVertices` hack :1479–1483) | pure mechanical refactor; all existing tests + pattern-export suite green; zero geometry change (assert identical volumes on 3 patterns) |
| 6 | DensityField + VariableSpacing core | 5 | new files; `Structures.swift` (params/persistence :164–:300) | known-answer: linear-ramp line count exact ±1 (brief §6.7); image sampling via CGImage; persistence round-trip |
| 7 | Retrofit density into planar/lattice patterns | 6 | generators: grid :214, triangle :68, triHexagon :239, cross :308, cross3D :985, cubicSubdivision :766 | grid/triangle/triHexagon/cross tile-pitch via VariableSpacing; cross3D recursion depth by local density; cubicSubdivision driver choice (surface/image/attractor); support-matrix hints for the rest |
| 8 | Density UI + persistence + CLI flags | 6,7 | `ContentView.swift` (`StructuresPanel` :6343), `HeadlessExportCommand.swift:459–478`, `SlicerProjectDocument.swift:104,293,418` | controls per §2.2; dead-control sweep; `--density-image/--density-source/--min-cell-mm/--max-cell-mm` headless flags |
| 9 | Graded gyroid (1-axis + radial phase integral) + Op-Art additions | 6 | `GyroidInfill.swift:9–40`, `StructureInfillEngine.swift:1156–1364,1598–1735` | phase-integral grading (brief §6.3) — axis + radial only, full 3D grading deferred; probe-line wall count matches integral ±1; new presets: Riley squares (width-ramp checker), graded rings, wave grating; each visually distinct |
| 10 | SupportTreeBuilder core (sculpture) | 1 | new file; brief §6.5; `MeshPreflight.swift` | tips from Poisson samples on target surface; top-down growth, merge (Murray), taper; deterministic per seed |
| 11 | Support solidify + plan/UI/CLI wiring | 10,2 | `SupportSolidifier`; `Structures.swift:12–33` (`isImplemented`), `StructurePlanner :1778`, panel :6448 | watertight forest; tip-coverage ≥95% gate; capsule budget with surfaced coarsening; Supports segment goes live |
| 12 | Scaffold mode (overhang + avoidance) | 11 | `AvoidanceVolumes`; `MoldCavityBuilder.swift:62` (triangle-reduction-before-Minkowski precedent) | overhang faces by normal threshold on healed solid; 3-bucket Minkowski avoidance; `intersect(branches, model).volume == 0`; coverage ≥98% |
| 13 | Skin seeds + surface cell network | 5,6 | new files; brief §6.4/§6.6 | seeds track density (2:1 image ⇒ spacing ratio 2:1 ±25%); network extraction on sphere + hand without dangling edges |
| 14 | Skin solidify (struts + perforated) + UI/CLI | 13,2 | `MoldShellBuilder.swift:152–199` (Minkowski band precedent) | struts: capsule network watertight, genus > 0 on sphere; perforated: window count ≈ seed count ±10%; Skin segment goes live |
| 15 | Presets, cancellation checkpoints, UI audit, report | all | `ContentView.swift:2143–2185` | named presets render distinct; heavy jobs cancellable at phase boundaries; full do-not-regress suite green; morning report complete |

---

## §6 Acceptance & known-answer constants

Pinned in brief §6.7 so gates arbitrate empirically (line-count integral, capsule volume, graded-gyroid probe crossings, Poisson spacing ratios, tip coverage, zero model-intersection). A milestone is done when its brief §4 gate passes **on the real scan** (`handStand_ex3.obj` or the 50k fast derivative per the gate's wording) — synthetic fixtures alone never close a gate.

## §7 Out of scope for this run (explicit deferrals — R9)

Full 3D density-graded gyroid via Poisson/de-homogenization phase solve (1-axis + radial ship now); polygon influence-area propagation à la CuraEngine (point-node growth ships now; noted as a refinement); space-colonization (Hyphae) alternative branch engine; geodesic-distance Voronoi (Euclidean nearest-seed ships); in-viewport density painting and attractor dragging; Lightning infill; Grasshopper/LTCX export; per-branch print-orientation analysis; auto cell-size from curvature.

## §8 Verification commands (local only — cloud CI is permanently banned)

```bash
swift build --package-path app/RefabArtist
swift test  --package-path app/RefabArtist \
  --scratch-path /tmp/refabartist-swiftpm-structures --filter 'Structure|Manifold|Density|Support|Skin'

# End-to-end + measurements (audit keys land in WU-2). --format is REQUIRED: it
# defaults to dxf and Structures is mesh-only (stl/obj).
"build/Refab Artist.app/Contents/MacOS/RefabArtist" --headless-export \
  --mode structures --category infill --pattern gyroidTiled \
  --cell-size-mm 12 --wall-thickness-mm 0.8 --format stl \
  --fixture "$FIXTURE" --output /tmp/structs.stl --measurement /tmp/structs.json

bash tools/package_app.sh && ls -l "build/Refab Artist.app/Contents/MacOS/"   # before ANY "fixed" claim
```

Fixtures: `app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj` (broken non-watertight scan, ~29k quads ≈ 59k tris — THE gate model; slow because of the GWN heal, not size), `app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex4.obj` (clean), fast fixture `app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj` (pre-healed — its speedup is skipping the GWN heal; + regen script; create if the inflatables run hasn't), synthetic cube/sphere/hemisphere-shell "mask" generated in tests, density ramp/radial PNGs generated by script (no external assets). A 35 MB, ~884k-face relief (`Sardiniers6.obj`, not committed) serves for perf spot-checks.

## §9 References (for clean-room reimplementation — see brief §6.8 licensing note)

Tree/organic supports: CuraEngine PR #1282 (Rahm, "TreeSupport 2.0") · Prusa KB "Organic supports" · Vanek et al. "Clever Support" (2014) · Runions space colonization (2007) · Nervous System "Hyphae" (prior art: branch structures as printed art). Grading: Tricard et al. "Procedural Phasor Noise" (TOG 2019) · "Distortion-minimized de-homogenization for TPMS cell-size" (arXiv 2605.06011) · Yuksel "Weighted Sample Elimination" (+ `cySampleElim.h` reference impl — reimplement in Swift, do not vendor). Skin: Crystallon (github.com/fequalsf/Crystallon) · Meshmixer "Make Pattern" dual-edge Voronoi · Geogram RVD/CVT (deferred path). TPMS: nTop "Trim Lattice / Boolean Intersect" pattern.

## §10 Codex prompting best practices (restate in EVERY sub-agent prompt)

1. Goal, constraints, and done-criteria verbatim from the WU. 2. Exact files + line ranges; `rg` the symbol first. 3. One concern per agent. 4. The §4 contract is law; signature changes = CONTRACT-CHANGE, stop. 5. Plan before code (3–6 bullets). 6. Run the verify command; paste its result. 7. Return the §0 structured summary only — no file dumps. 8. If blocked, report BLOCKED with what you tried — don't spelunk the repo.
