# Build Spec: **Inflatables** construction mode — corrected product contract for Codex

> **Audience: Codex (orchestrator + sub-agents).** This document is self-contained.
> A sub-agent should be able to execute its assigned Work Unit by reading *only*
> the slice of this doc it is given plus the small read-set named in that unit —
> never the whole repo. §0 explains the multi-agent strategy and context budget.
> Read §0 → §11 in order if you are the orchestrator; otherwise read only your WU.

> **Name:** working label **"Inflatables"** (subtitle "Inflatable Sculpture"). This
> is a one-line string (`ConstructionMode.label`) — owner may rename; do not block on it.

> **2026-06-30 correction:** The previous implementation exposed production-looking
> controls before the underlying algorithms existed. This PRD now treats that as a
> product failure, not a bug to paper over. A generated plan may not silently violate
> the meaning of a visible control. If the requested design is impossible or unsupported,
> the app must fail with a clear diagnostic and no stale sheet/preview/export.

---

## 0. How to run this as a multi-agent build (context budget = the point)

The goal of the orchestration is to **keep the orchestrator's context tiny** and
**never load the whole codebase into any one agent**. Rules:

**Orchestrator agent**
- Holds ONLY this document + the Work-Unit DAG (§5) + the interface contract (§4).
- Does **not** open source files itself. It dispatches one sub-agent per Work Unit,
  passes that WU's text + read-set + contract, and collects a **structured result**
  (files changed, public symbols added/changed, test command + pass/fail) — never
  file contents.
- Builds in **dependency order** (§5 DAG). Units with no edge between them may run
  in parallel.

**Sub-agent (one per Work Unit)**
- Receives: its WU section verbatim, the **read-set** (exact files it may open — and
  for huge files like `ContentView.swift`, the exact line ranges), the **interface
  contract** it must consume/produce, the **acceptance test**, and the verification
  command.
- **Hard scope rules** (Codex best practice — restate these in every sub-agent prompt):
  1. Read only the files in your read-set. Use `grep`/`rg` with the specific symbol
     names given; do not read whole large files — read the cited line ranges.
  2. Do not change any public type or function signature defined in §4 without
     returning a "CONTRACT-CHANGE" flag to the orchestrator first.
  3. Do not refactor or "improve" unrelated code. One WU = one concern.
  4. Produce a short PLAN first (files you'll touch + approach) for any non-trivial
     WU; only then write code.
  5. Run the verification command and paste the result. Do not report success
     without a green build + passing acceptance check.
  6. Return a **structured summary only** (see output format below), not file dumps.

**Sub-agent output format (every WU returns exactly this):**
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

**Why this saves tokens:** §4 fixes the shared Swift types/signatures up front, so
every downstream unit codes against *signatures*, not against other units' source.
Agents never need to read each other's implementations, and the orchestrator never
holds more than ~1 page per completed unit.

---

## 1. What we're building (and the one physical fact)

A new **mesh-only construction mode** for designing rigid, near-inextensible sealed
inflatable sculptures. The mode ingests a watertight 3D target mesh and produces:

1. flat, laser-cuttable wall/baffle/port patterns;
2. a predicted inflated 3D preview of the assembled object;
3. diagnostics explaining where the requested shape cannot be achieved with the
   current panel budget, seam model, and baffle choices.

**The one fact that drives everything:** a flat shape sealed and inflated does NOT
become the modeled shape. Inextensible panels behave like the **Mylar balloon**
(Paulsen 1994): a flat disk sealed at the rim inflates to an oblate apple shape
(half-height ≈ 0.599·radius, rim pulls in ≈24%), not a sphere. And a closed
tension-only membrane under pressure must have **positive mean curvature everywhere**
— so **concavities physically pop outward** unless held by an internal baffle. The
preview must surface both effects. The correct paradigm for inextensible material is
**developable strips (gores) + shaped seams (broadseam)** — exactly how sails/kites
are built.

**Critical product truth:** this is NOT automatically solved by "segment mesh →
flatten charts → inflate preview." That pipeline can produce a first-pass pattern
and a useful failure visualization, but it does **not** reliably generate cut sheets
that inflate into the target sculpture. Accurate target matching requires an inverse
design loop: generate panels → simulate inflation → compare to target → adjust seams,
baffles, panel count, and broadseam → repeat until the preview is acceptable.

### Release tiers

**Tier 0 — Honest feasibility mode (must land before any user-facing release)**
- Controls are either implemented or hidden/disabled with a plain hint.
- `Max panels` is a hard contract: output panel count ≤ requested max, or Generate
  fails with a diagnostic such as "needs at least N panels for connected developable
  charts." It must never show "Max 10" and output 90 parts.
- The 3D preview and sheet are invalidated together when settings change. No stale
  plan may remain exportable.
- The app says "first-pass pattern / feasibility preview" unless inverse fitting is
  active.

**Tier 1 — First-pass cuttable output**
- Real developable segmentation, real LSCM/ARAP flattening, laser-safe labels, and a
  forward inflation preview.
- Good for inspecting whether a model is a plausible inflatable and for cutting
  simple convex/low-concavity tests.
- Still not a promise of target-accurate sculpture on organic shapes.

**Tier 2 — Assisted inflatable design**
- Baffles, seam overrides, ports, broadseam, and heatmap-driven diagnostics are real.
- User can iterate manually from the deviation preview.

**Tier 3 — Automatic target-fitting / inverse design**
- Uses the Skouras-style inverse loop to optimize seams/baffles/panels against the
  target. This is required before the feature can honestly promise "mesh in, accurate
  inflatable sculpture out."

If only Tier 0/Tier 1 are implemented, the UI must present the mode as a feasibility
and first-pass patterning tool, not as an automatic inflatable reconstruction tool.

---

## 2. Decisions locked (by the owner, 2026-06-29)

1. **Closed sealed inflatable ONLY.** No frame/tensioned-membrane mode.
2. **Internal baffles = an option** (default off). They are the mechanism for
   holding concavities and limiting over-bulge. Baffles appear on the cut sheet as
   their own labeled panels, and their **attachment lines** are marked on the wall
   panels they weld to.
3. **Cut-sheet labels are laser-safe:** ALL labels (panel IDs, edge-pair IDs, baffle
   IDs, port markers, registration text, orientation marks) are drawn in **ONE
   reserved color used for nothing else**, on its own layer, so the laser is
   configured to skip/engrave (never cut) it. See §6 — this is a hard invariant
   with an acceptance test.
4. **Open boundaries & fill ports: optional + intuitive.** Default is fully sealed.
   The user may optionally mark free-boundary edges and/or place a fill port.
5. **Symmetry: optional, OFF by default.** Offer auto-detection of a symmetry plane;
   never assume it. When on, cut mirrored pairs from one pattern and label L/R.
6. Material default = **rigid membrane** (no stretch term, no darts). Stretch-cloth
   and paper heads are later.
7. **Folded construction stays its own separate mode**, but its sliver bug is fixed
   as part of this work (WU-0), because it is the same class of geometry problem.
8. **No decorative controls.** A control may appear only if it changes planner output
   in a testable way. Otherwise hide it or disable it with a short hint. This applies
   to Material, Join, Seam, Roll, Symmetry, Ports, Baffles, and seam editing.
9. **`Max panels` is hard.** The planner must produce ≤ `maxPanelCount` panels or
   throw `requestedPanelBudgetImpossible(requested:minimumRequired:)`. It may not
   silently exceed the number. If connectedness/developability needs more panels,
   fail and say so.
10. **`Panel width` is not a max and must not be presented as one.** It is a target
    panel-size/density hint. If retained, label it "Target panel size" and explain in
    help text that `Max panels` is the hard cap.
11. **No stale result display/export.** Any setting that affects the plan invalidates
    the 3D preview, panel count, sheet, and export until Generate succeeds again.
12. **Inflated preview is mandatory.** There is no preview toggle. The feature is not
    done unless the user can see both the 3D predicted inflated result and the cut sheet,
    and export both.

---

## 3. Codebase map — where things live (read ONLY what your WU names)

All paths under `app/RefabArtist/Sources/RefabArtist/`.

**Mesh data types (consume/emit these):**
- `MeshInspector.swift` — `Vec3 {x,y,z:Double}` (L3), `Bounds3D` (L17),
  **`MeshGeometryData {vertices:[Vec3]; triangleIndices:[Int32]}`** (L22) — the
  universal mesh, **`MeshSummary`** (L27) = geometry + name/path/bounds + preflight.
- `SliceContours.swift` — `Vec2 {x,y:Double}` (L3), the 2D point for patterns.

**Clean / heal stack (reuse — do NOT use the QEM `MeshSimplifier` for this mode):**
- `MeshHealer.swift` — `MeshHealer.heal(_:edgeLength:maxCells:)` (L80): GWN-SDF →
  watertight via `ManifoldEngine.levelSet`.
- `ManifoldEngine.swift` — `make(from:)` (L152), `toMesh` (L507), `simplify(_:tolerance:)`
  (L370, manifold-preserving decimation), `minkowskiSum` (L354), `union`/`difference`/
  `intersect` (L333/342/327), `sphere`/`box`, `trimByPlane` (L394)/`splitByPlane` (L406),
  `levelSet` (L258), `bounds`/`isWatertight`/`volume`. C header:
  `Vendor/Manifold/include/manifold/manifoldc.h`.
- `MoldMeshSealer.swift` — `MoldMeshSealer.seal(_:maxHoleEdges:)` (L23): weld + drop
  zero-area + fan-fill small holes.
- `MeshManifoldRepair.swift` — `strippingDegenerateTriangles` (L67).
- `MeshPreflight.swift` — `MeshPreflight.analyze` (L48) → `MeshPreflightReport` (validation gate).
- `SurfaceDespeckle.swift` — `SurfaceDespeckle.polished` (L36): feature-preserving smooth.

**Flatten / unfold primitives (planar only — the real flattener is NEW):**
- `PanelPlaneFrame.swift` — `PanelPlaneFrame(polygon:)` (L17), `project`/`unproject`
  (Newell-normal in-plane 2D frame; exact only for already-planar panels).
- `FoldedPanels.swift` — `FoldedPanelPlanner.plan` (L285); reusable scaffolding:
  `panelAdjacency` (L1048), `spanningTree` (L1102); isometric unfold `localEmbedding`
  (L1145), `unfoldPolygon` (L1401), `unfoldTriangle` (L1423), `placeChild` (L1180);
  `groupedCoplanarPanels`/`planeKey` (L361/355) — **exact-plane** grouping (replace
  predicate for near-developable).

**Cut sheet / export (reuse for the 2D pattern + DXF/SVG/PDF):**
- `CutSheetDocument.swift` — packing, labels, `islandize` (L649), DXF/SVG/PDF export.

**Offsets / whole-mesh ops:**
- `MeshModifier.swift` — `mitreOffsetDirections` (L69, plane-true per-vertex offset),
  `thicken` (L246), `hollow` (L282), `shrinkwrap` (L366, the UI Make-Watertight).

**The QEM simplifier (WU-0 fixes this; Inflatables avoids it):**
- `MeshSimplifier.swift` — `simplify(_:targetFaceCount:)` (L86); sliver sweep
  (L393–434); normal-flip guard accepts dot > 1e-6 (≈89.9999°, L333). Used by
  Folded via `ContentView.swift` `buildFoldedSimplificationIfNeeded` (~L787,
  `MeshSimplifier.simplify` ~L795) and `HeadlessExportCommand.swift` (~L905).

**Mode registration / UI / persistence (pattern to mirror — mesh-only mode):**
- `ConstructionMode.swift` — enum cases (L1–10), `label` (L14), `isMeshOnly` (L52).
  `ConstructionMode.allCases` drives the picker (`ContentView.swift` ~L4929).
- `MotherMoldSettings.swift` — settings struct template.
- `SlicerProjectDocument.swift` — persistence (optional fields, L104–113, L411–413).
- `MotherMoldPlanner.swift` — planner template: `planThrowing`/`plan` (L120/312),
  `MotherMoldPlan` (L48), `MotherMoldPlannerError` (L78).
- `PartitionPanel.swift`, `PartitionPlanner` — alt planner/panel example.
- `ContentView.swift` — inspector dispatch chain `.structures/.partition/.motherMold`
  (L1499–1546); Generate-action pattern: Partition (L2093–2160), MotherMold
  (L2280–2300+); per-mode panels at file bottom (`StructuresPanel` L5905,
  `MotherMoldPanel` L6039); mesh-only switch arms keyed on the 3 mesh modes
  (e.g. L1112, L1143, L1470, L3046, L5007+).
- `HeadlessExportCommand.swift` — headless arm (add `--mode inflatables`).

---

## 4. Interface contract (WU-1 creates this FIRST; everyone else codes to it)

New file `Inflatables/InflatablesTypes.swift` (proposed). Signatures are the
contract; a unit may add fields but must flag any change to an existing one.

```swift
enum MaterialMode: String, Codable { case rigidMembrane, stretchCloth, paper }
enum JoinMethod: String, Codable { case tape, weld, sew }   // drives allowance + butt/overlap

struct EdgeRef: Codable, Hashable { var a: Int32; var b: Int32 }     // mesh vertex pair
struct BaffleSpec: Codable, Equatable { var id: String; var plane: PlaneEq; var inset: Double }
struct PortSpec: Codable, Equatable   { var id: String; var center: Vec3; var radiusMM: Double }

struct InflatablesSettings: Codable, Equatable {
  var material: MaterialMode = .rigidMembrane
  var targetPanelWidthMM: Double = 120        // target density hint, NOT a hard max
  var maxPanelCount: Int = 64                 // HARD cap: plan.count <= this or throw
  var seamAllowanceMM: Double = 8             // only visible once real offset exists
  var joinMethod: JoinMethod = .weld          // only visible once allowance changes by method
  var rollWidthMM: Double? = nil              // optional nesting constraint
  var symmetryEnabled: Bool = false           // OFF by default
  var symmetryPlane: PlaneEq? = nil           // optional, auto-detect offered
  var freeBoundaryEdges: [EdgeRef] = []       // optional open boundaries
  var ports: [PortSpec] = []                  // optional fill ports
  var baffles: [BaffleSpec] = []              // optional internal baffles
  var seamOverrides: [SeamEdit] = []          // user add/move/delete seams
}

struct RegistrationMark: Codable { var at: Vec2; var pairId: String }
struct FlatPanel: Codable {
  var id: String                 // label text
  var cutOutline2D: [Vec2]       // CUT line (finished + allowance)
  var seamLine2D: [Vec2]         // finished/seam line (the geometry that must match)
  var sourceFaceIDs: [Int]
  var registration: [RegistrationMark]
  var labelAnchor: Vec2
  var isBaffle: Bool
  var baffleAttachLines2D: [[Vec2]]   // on wall panels: where baffles weld
  var mirrored: Bool
}
struct SeamPair: Codable { var id: String; var panelA: String; var edgeA: Int; var panelB: String; var edgeB: Int }
enum DiagnosticSeverity: String, Codable { case info, warning, error }
struct PlanDiagnostic: Codable {
  var kind: String
  var severity: DiagnosticSeverity
  var message: String
  var at: Vec3?
  var panelID: String?
}  // e.g. "concavity-cannot-inflate", "panel-budget-impossible"

struct InflatablesPlan {
  var panels: [FlatPanel]
  var seams: [SeamPair]
  var preview: InflationPreviewResult     // always produced; not user-optional
  var cutSheet: CutSheetDocument          // laser-ready, §6 layer convention
  var diagnostics: [PlanDiagnostic]
}

enum InflatablesPlannerError: Error {
  case notWatertight
  case emptyAfterClean
  case segmentationFailed
  case requestedPanelBudgetImpossible(requested: Int, minimumRequired: Int)
  case unsupportedVisibleControl(String)
}

enum InflatablesPlanner {
  static func plan(model: MeshGeometryData, settings: InflatablesSettings) throws -> InflatablesPlan
}
```
`InflationPreviewResult`, `SeamEdit`, `PlaneEq` are defined by their owning units
(WU-7, WU-4) — WU-1 declares them as forward stubs so the package compiles.

---

## 5. Work-Unit DAG (build order; siblings may run in parallel)

```
WU-A  Current implementation audit + disable fake controls .... ROOT SAFETY GATE
WU-0  Folded QEM sliver fix .............. INDEPENDENT (do first or in parallel)
WU-1  Mode scaffold + contract (§4) ...... ROOT for new implementation
        ├── WU-2  Clean/heal pre-pass
        ├── WU-3  Developable segmentation + hard panel budget    (needs WU-2 output type)
        │     └── WU-5  LSCM flattener                            (needs WU-3 charts)
        │            └── WU-6  2D pattern + labels/§6 + nesting/export
        ├── WU-4  Seam/boundary model + interactive seam edit + ports + baffles
        ├── WU-7  Inflation preview (PBD) + heatmap + diagnostics (needs WU-5 panels + WU-4 baffles)
        │     └── WU-8  Broadseam + assisted iteration            (needs WU-7 error map)
        ├── WU-9  Truthful UI panel + viewport + Generate action  (integrates last)
        └── WU-10 Inverse fitting loop (Tier 3, optional but required for "automatic accurate")
```
Critical path for an honest Tier-1 release: **WU-A → WU-1 → WU-2 → WU-3 → WU-5
→ WU-6 → WU-7 → WU-9**. WU-4/WU-8 are required before calling the mode an assisted
inflatable design tool. WU-10 is required before promising automatic target-accurate
inflatable reconstruction.

---

## 6. Cut-sheet color / layer convention (LASER-SAFE — hard requirement)

Laser cutters select operation by color/layer. The cut sheet must emit entities on
these **distinct DXF layers, each a fixed color**:

| Layer name | Color (RGB) | Laser op | Carries |
|---|---|---|---|
| `CUT`         | red `#FF0000`     | **cut**   | panel cut outlines, port holes, baffle outer outlines |
| `SEAM`        | blue `#0000FF`    | score     | finished/seam line (inside the allowance) |
| `FOLD_REG`    | green `#00FF00`   | score     | registration ticks, fold hints |
| `BAFFLE_ATTACH` | cyan `#00FFFF`  | score/mark| baffle attachment lines on wall panels |
| **`LABEL`**   | **magenta `#FF00FF`** | **skip/engrave — NEVER cut** | **ALL text: panel IDs, edge-pair IDs, baffle IDs, port markers, registration text, orientation/L-R marks** |

**Hard invariants (acceptance-tested in WU-6):**
- The `LABEL` color/layer is used by **nothing except TEXT entities**.
- **No** TEXT entity appears on any non-`LABEL` layer.
- No cut/score geometry ever uses the `LABEL` color.
- Colors are configurable constants in one place, but the **label-color-is-exclusive**
  invariant holds regardless of the chosen palette.

Acceptance test: parse the exported DXF; assert `entities_on(LABEL)` are all `TEXT`/
`MTEXT`, and `text_entities_on(any other layer) == 0`. (See WU-6.)

---

## 7. Work Units (each is a complete sub-agent task)

For each WU: **Goal · Read-set · Write-set · Algorithm/refs · Contract · Acceptance.**
Instantiate the §0 prompt template with these fields. Keep scope to the unit.

### WU-A — Current implementation audit + disable fake controls (safety gate)
- **Goal:** Audit the existing Inflatables implementation against this corrected PRD.
  Disable or hide every user-facing control whose behavior is not implemented and
  test-backed. Remove stale generated output paths. This WU exists because the current
  branch has already exposed fake controls and soft caps.
- **Read-set:** `Inflatables/InflatablesPanel.swift`; `Inflatables/InflatablesPlanner.swift`;
  `Inflatables/InflatablesTypes.swift`; `Inflatables/DevelopableSegmentation.swift`;
  `Inflatables/LSCM.swift`; `Inflatables/InflationSimulator.swift`; `ContentView.swift`
  only the Inflatables state/generate/export/view sections.
- **Write-set:** `Inflatables/InflatablesPanel.swift`; `ContentView.swift`;
  `Inflatables/InflatablesPlanner.swift` only if needed to enforce error paths.
- **Rules:** No algorithm invention in this WU. Its job is product honesty:
  `Max panels` must be hard or Generate must fail; unsupported controls are hidden or
  disabled; stale sheets/previews/exports are impossible.
- **Acceptance:** With `handStand_ex3.obj`, setting Max 10 cannot display/export 90
  panels. It either generates ≤10 panels or shows a blocking error. Material/Join/
  Symmetry/Baffles/Ports controls do not appear as active unless they affect output
  in a regression test.

### WU-0 — Folded simplifier sliver fix (separate mode, same problem class)
- **Goal:** Stop the Folded mode emitting sliver/needle panels. Root cause: QEM is
  shape-blind — a needle on-surface has ~0 quadric error so it's never collapsed
  (and is even created); the sliver sweep only catches sub-area-floor *zero-area*
  faces, not high-aspect needles; the flip guard accepts ~89.9999° rotation.
- **Read-set:** `MeshSimplifier.swift` (esp. L86, L207–391, L319–339, L393–434);
  `ContentView.swift` L780–810 (folded simplify call site); `HeadlessExportCommand.swift`
  ~L900–915; `ManifoldEngine.swift` L370; `MoldMeshSealer.swift` L23.
- **Write-set:** `MeshSimplifier.swift` (and/or the folded call sites).
- **Algorithm:** Preferred — route Folded's pre-clean through the manifold-preserving
  stack (`ManifoldEngine.simplify` + `MoldMeshSealer.seal` + `MeshManifoldRepair`)
  instead of QEM. If QEM must stay, add an **aspect-ratio / min-angle penalty** to
  the collapse cost, replace the area-only sliver sweep with an **aspect-ratio
  sweep**, and tighten the flip threshold (reject normal rotation beyond e.g. 60°).
- **Acceptance:** On a dense organic scan, post-simplify `--mesh-audit` degenerate
  count = 0 and no triangle exceeds an aspect-ratio threshold; Folded generates
  zero degenerate/uncuttable panels. Build green. Folded remains its own mode.

### WU-1 — Mode scaffold + contract
- **Goal:** Register `Inflatables` as a mesh-only mode; create §4 types; wire an
  empty `InflatablesPlanner.plan` (returns empty plan), settings, persistence, and a
  Generate action stub through the mesh-only path so a project round-trips.
- **Read-set:** `ConstructionMode.swift`; `MotherMoldSettings.swift`;
  `SlicerProjectDocument.swift` L100–130 & L405–420; `MotherMoldPlanner.swift`
  L40–130; `ContentView.swift` L1499–1546 & L2280–2300 (pattern only).
- **Write-set:** `ConstructionMode.swift` (add `case inflatables`, `label`,
  `isMeshOnly`); new `Inflatables/InflatablesTypes.swift` (§4); new
  `Inflatables/InflatablesPlanner.swift` (empty); `SlicerProjectDocument.swift`
  (optional `inflatablesSettings`); minimal `ContentView.swift` dispatch + state.
- **Contract:** Establish §4 verbatim. This unit OWNS §4; later contract changes
  funnel through here.
- **Acceptance:** Package builds; selecting Inflatables shows an (empty) panel;
  save/open a project preserves `InflatablesSettings`. `ConstructionMode.allCases`
  shows the mode.

### WU-2 — Clean / heal pre-pass
- **Goal:** `cleanForInflatable(_ mesh: MeshGeometryData) -> MeshGeometryData` that
  yields a watertight, manifold, sliver-free mesh at a sane face budget.
- **Read-set:** `MeshHealer.swift` L80; `ManifoldEngine.swift` L152/370/507;
  `MoldMeshSealer.swift` L23; `MeshPreflight.swift` L48; `MeshModifier.swift` L366.
- **Write-set:** `Inflatables/InflatableClean.swift`.
- **Algorithm:** `heal` (GWN-SDF) → `ManifoldEngine.simplify` (manifold-preserving)
  → `seal`; verify with `MeshPreflight.analyze`. NEVER `MeshSimplifier` (QEM).
- **Acceptance:** On `handStand_ex4.obj` (clean) and a holey scan, output is
  watertight=YES, `make`-valid, degenerate=0.

### WU-3 — Developable segmentation + hard panel budget
- **Goal:** `segment(mesh, settings) -> [Chart]` where each Chart is a contiguous
  near-developable strip of faces. `targetPanelWidthMM` is a density hint.
  `maxPanelCount` is a hard budget: either return ≤ `maxPanelCount` charts or throw
  `requestedPanelBudgetImpossible(requested:minimumRequired:)`. Do not silently exceed
  the requested maximum. Seam boundaries are placed along geodesics; honor
  `freeBoundaryEdges`/`seamOverrides` once WU-4 lands.
- **Read-set:** `FoldedPanels.swift` L1040–1130 (`panelAdjacency`, `spanningTree`)
  and L355–365 (`planeKey` — the predicate to REPLACE); `MeshInspector.swift` L1–40.
- **Write-set:** `Inflatables/DevelopableSegmentation.swift`.
- **Algorithm:** **D-Charts** developability metric (Julius, Kraevoy & Sheffer,
  *Quasi-Developable Mesh Segmentation*, CGF 2005) for region growing, optionally
  refined by the **Stein–Grinspun–Crane** developability energy (*Developability of
  Triangle Meshes*, SIGGRAPH 2018). Reuse the adjacency + spanning-tree scaffolding;
  replace exact-`planeKey` grouping with a **normal-angle + developability tolerance**.
  Seam routing along **geodesics** (approximate with edge-graph Dijkstra, or the heat
  method, Crane et al. *Geodesics in Heat*). Concave/saddle regions require more seams;
  if that conflicts with `maxPanelCount`, fail clearly rather than emitting extra panels.
- **Acceptance:** A cylinder/cone segments into few clean strips with ~0 flatten
  residual; an organic scan (hand) segments without leaving non-developable charts
  above a distortion threshold; respects `maxPanelCount` as a hard cap or throws the
  panel-budget error. Test on CONCAVE sections, not just convex — see
  [[project_convex_fixture_blind_spot]]. Explicit regression: Max 10 never returns
  more than 10 charts.

### WU-4 — Seam/boundary model + interactive seam editing + ports + baffles
- **Goal:** The editable seam/boundary layer: designate edges as free-boundary vs
  seam; add/move/delete seams (`SeamEdit`); place ports; define baffles (plane +
  inset) and compute baffle panels + their attachment lines on wall charts.
- **Read-set:** WU-3 `Chart` type; `ManifoldEngine.swift` L394/406 (`trimByPlane`/
  `splitByPlane` for baffle cross-section); `MeshInspector.swift`.
- **Write-set:** `Inflatables/SeamModel.swift`, `Inflatables/Baffles.swift`; define
  `SeamEdit`, `PlaneEq`.
- **Algorithm:** Baffle = planar cross-section of the cavity (`splitByPlane` ∩ at the
  baffle plane), inset by `inset`; its boundary maps to **attachment polylines** on
  the two wall charts it spans (record as `baffleAttachLines2D`, later drawn on the
  flat panels in `BAFFLE_ATTACH` layer). Ports = small disc holes + reinforcement
  ring outline. Default: none of these (fully sealed). Make placement intuitive
  (pick on mesh) and optional.
- **Acceptance:** On a dumbbell mesh, a mid-plane baffle produces one baffle panel +
  matching attach lines on both lobes; toggling ports/boundaries off yields a fully
  sealed panel set. Until these tests pass, the UI must not expose active baffle,
  port, free-boundary, or seam-edit controls.

### WU-5 — LSCM flattener (NEW — no parameterization exists in repo)
- **Goal:** `flatten(chart) -> (outline2D, uv per vertex, distortion)` minimizing
  stretch; near-isometric on developable charts.
- **Read-set:** `PanelPlaneFrame.swift` (planar fallback); `MeshInspector.swift`.
- **Write-set:** `Inflatables/LSCM.swift` (+ optional `ARAP.swift`).
- **Algorithm:** **LSCM** — Lévy, Petitjean, Ray, Maillot, *Least Squares Conformal
  Maps for Automatic Texture Atlas Generation*, SIGGRAPH 2002 (pin 2 vertices, solve
  the sparse least-squares conformal system). Provide **ARAP** (Liu, Zhang, Xu,
  Gotsman, Gortler, *A Local/Global Approach to Mesh Parameterization*, SGP 2008) as
  an option for low-curvature charts where length fidelity matters. For a fully
  planar chart, short-circuit to `PanelPlaneFrame`. Report per-panel max stretch.
- **Acceptance:** A developable strip flattens with stretch < 1%; a hemispherical
  cap flattens with bounded, reported distortion and no flipped triangles.

### WU-6 — 2D pattern: allowance, registration, labels (§6), symmetry, nesting, export
- **Goal:** Assemble `FlatPanel`s into a laser-ready `CutSheetDocument`: seam
  allowance (join-method aware), mid-seam registration ticks, **§6 layer/label
  convention**, optional symmetry/mirroring, true-scale nesting within `rollWidthMM`,
  DXF/SVG/PDF export.
- **Read-set:** `CutSheetDocument.swift` (packing/labels/export, esp. L640–700 and
  the DXF writer); `MeshModifier.swift` L69 (`mitreOffsetDirections`) or a 2D polygon
  offset; `ManifoldEngine.swift` L354 (`minkowskiSum`) if offsetting in 3D.
- **Write-set:** `Inflatables/CutPattern.swift`; extend `CutSheetDocument` only if
  it cannot already express per-layer colors (add a layer/color field if missing —
  flag as CONTRACT-CHANGE if it touches shared export).
- **Algorithm:** Allowance = outward offset of `seamLine2D` by `seamAllowanceMM`
  (butt vs overlap per `JoinMethod`). Registration ticks at matched arc-length
  fractions along each `SeamPair`. Symmetry (if `symmetryEnabled`): cut one of each
  mirrored pair, label `…-L`/`…-R`. Nest within roll width.
- **Acceptance:** **§6 invariant test passes** (label layer = only text; no text on
  cut layers). Exported DXF opens with correct layers/colors; panels at true mm;
  with symmetry on, mirrored pairs collapse to single labeled patterns. Until
  join-method-specific allowance and symmetry pass these tests, those controls must
  be hidden/disabled.

### WU-7 — Inflation preview (forward PBD tension-field) + heatmap + diagnostics
- **Goal:** Given assembled panels (+ baffles as constraints), simulate inflation and
  return predicted inflated mesh + per-panel distance-to-target + diagnostics
  (concavity-cannot-inflate, over-bulge).
- **Read-set:** WU-5 panel output; WU-4 baffle attach lines; `MeshInspector.swift`.
- **Write-set:** `Inflatables/InflationPreview.swift`; define `InflationPreviewResult`.
- **Algorithm:** **Position-Based Dynamics** (Müller et al., *Position Based
  Dynamics*, 2007) membrane: inextensible **distance constraints** along edges
  (tension-field — allow slack/wrinkle under compression, resist stretch),
  **pressure** as a volume-proportional outward force (closed mesh), **baffles** as
  distance constraints tying the two attach lines. Converge, then measure
  closest-point distance to the target. Flag regions where the target is concave
  (positive→negative mean curvature) as `concavity-cannot-inflate`. This is the
  forward model; conceptually it is the simulation core from Skouras et al.,
  *Designing Inflatable Structures*, SIGGRAPH 2014 (we build only the forward
  preview, not their global inverse optimizer).
- **Acceptance:** A flat sealed disk inflates toward the Mylar ratio (half-height/
  radius ≈ 0.6, not 1.0); a sphere-with-a-dimple flags the dimple as un-inflatable
  unless a baffle is present; heatmap renders. Preview preserves face indexing for
  panel selection, but deviation must be measured against the target surface, not by
  assuming vertex index equality on dense meshes.

### WU-8 — Broadseam + assisted iteration (bounded local correction)
- **Goal:** Shape seam edges to inject/remove curvature so the inflated result moves
  toward the target; manual control + auto-suggest from WU-7's error map. This is the
  minimum path for "make it closer" without full inverse design.
- **Read-set:** WU-7 result; WU-5/WU-6 panel + seam types.
- **Write-set:** `Inflatables/Broadseam.swift`.
- **Algorithm:** Per-seam **broadseam**: add a tapered curved allowance along a seam
  (narrow at ends, wide in middle, signed by desired curvature) — the sailmaking
  technique; re-flatten/re-preview to confirm. Auto-suggest magnitude from the local
  error sign in the heatmap. This is the cheap *local* stand-in for Tier 3 global
  inverse design.
- **Acceptance:** Applying a positive broadseam to a too-flat region measurably
  reduces its preview error; the change is reflected in the cut outline. Diagnostics
  offer concrete actions: add panels, add a baffle, split the part, or apply broadseam.

### WU-9 — Truthful UI panel + viewport + Generate action
- **Goal:** Left-rail `InflatablesPanel` exposes only implemented, test-backed controls.
  Required controls for Tier 1: Target panel size, Max panels, Generate, view mode
  (Target/Panels/Inflated/Compare), export controls. Optional controls (material,
  join method, seam allowance, roll width, symmetry, baffles, ports, seam edit) appear
  only after their owning WU acceptance tests pass. Viewport shows flat panels + real
  inflated preview heatmap; nothing auto-runs.
- **Read-set:** `ContentView.swift` L1499–1546 (dispatch), L2093–2160 (Partition
  Generate pattern), L5905/6039 (panel structs), L4929 (picker); `PartitionPanel.swift`.
- **Write-set:** `Inflatables/InflatablesPanel.swift`; `ContentView.swift` (dispatch
  branch + off-main `Task.detached` Generate + stale-result gating, mirroring
  Partition/MotherMold); `HeadlessExportCommand.swift` (`--mode inflatables`).
- **Acceptance:** End-to-end in-app: load mesh → Generate → panels + cut sheet appear
  off-main without freezing; disabled/overridden controls are hidden with a hint
  (see [[feedback_disable_overridden_controls]]); headless export emits a DXF.
  Hard UI regression: after settings change, old panel count, old 3D preview, old
  sheet, and export are unavailable until Generate succeeds. If Max is 10, the visible
  panel count and sheet parts are ≤10 or Generate fails.

### WU-10 — Inverse fitting loop (Tier 3: automatic target-accurate mode)
- **Goal:** Close the loop between the target mesh and the inflated simulation:
  generate candidate panels, simulate inflation, compare to target, and optimize panel
  layout / broadseam / baffles / panel count until the deviation target is met or the
  requested budget is proven impossible.
- **Read-set:** WU-3, WU-5, WU-7, WU-8 outputs; Skouras reference; existing diagnostic
  and plan types.
- **Write-set:** `Inflatables/InverseInflatableFit.swift`; planner integration.
- **Algorithm:** Iterative constrained optimization. Variables may include seam graph,
  broadseam magnitudes, baffle placement, and panel density. Objective combines
  target-surface deviation, stretch/developability, seam complexity, and panel budget.
  This is the only WU allowed to make "automatic accurate reconstruction" claims.
- **Acceptance:** On a simple dimpled or dumbbell target, adding the optimizer reduces
  preview deviation relative to Tier 1 and emits an explanation when the requested max
  panel count cannot meet the fidelity target.

---

## 8. Verification (local only — NO cloud CI)

- Build: `swift build -c release --package-path app/RefabArtist`
  (or `bash tools/package_app.sh` to refresh `build/Refab Artist.app`).
- Mesh audit: `"build/Refab Artist.app/Contents/MacOS/RefabArtist" --mesh-audit --fixture <obj>`
- Headless export (add this mode in WU-9):
  `… --headless-export --mode inflatables --format dxf --fixture <obj> --output /tmp/inf.dxf`
- Real test fixtures (organic, concave — the real test, not convex toys):
  `app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex4.obj` (clean) and
  `handStand_ex3.obj` in the same folder (broken). The owner is the final judge — render and
  LOOK on a real model, and physically cut + tape one test piece before "done".
- No GitHub Actions (owner removed CI permanently); gate everything locally.

**Hard product gates before calling Inflatables usable:**
1. `Max panels` gate: on `handStand_ex3.obj`, Generate with Max 10 may not display,
   export, or report more than 10 panels. If the algorithm needs more, it must show a
   blocking `requestedPanelBudgetImpossible` error and keep the old sheet/preview
   unavailable.
2. Stale result gate: after any setting change, the visible panel count, inflated 3D
   preview, sheet preview, and export all disappear or show a clear stale state until
   Generate succeeds.
3. Control honesty gate: every visible active control has a regression proving it
   changes planner output. Otherwise the control is hidden or disabled.
4. Physical preview gate: the inflated preview changes when panel seams/baffles/
   broadseam change, preserves face indexing for selection, and reports target-surface
   deviation in millimeters.
5. Real-model visual gate: screenshots of Target, Panels, Inflated, Compare, and Sheet
   on `handStand_ex3.obj` are attached to the handoff. The cut sheet part count must
   match the generated panel count.

---

## 9. Current implementation audit (do not skip)

As of 2026-06-30 on branch `neo/op-art-vega`, the existing Inflatables code is a
prototype and does **not** satisfy this corrected PRD. Treat it as scaffolding only.

Known non-compliances to fix or disable before further feature work:
- `InflatablesPanel.swift` exposes controls whose planner behavior is missing or weak:
  Material, Join, Seam, Roll, Symmetry, baffles/ports/seam overrides.
- `DevelopableSegmentation.swift` may exceed `maxPanelCount`; `Max panels` is not yet
  a hard product contract.
- `LSCM.swift` is triangle unfolding, not least-squares conformal mapping or ARAP.
- `CutPattern.swift` maps one flattened chart to one panel with a naive radial seam
  allowance; join-method-aware allowances, true seam pairing, registration, symmetry,
  baffle attach marks, and robust nesting are incomplete.
- `InflationSimulator.swift` is a rough pressure/edge relaxer, not a validated
  Mylar/PBD membrane preview with baffle constraints and robust closest-surface
  deviation.
- The UI previously allowed stale or misleading generated plans to remain visible.

Any agent continuing this work must first run WU-A. Do not spend tokens tuning the
current heuristics until the product contract is enforced.

## 10. Codex prompting best practices (apply to EVERY sub-agent prompt)

1. **State the goal, the constraints, and the done-criteria** explicitly; paste the
   WU's Goal + Acceptance verbatim.
2. **Give exact files + line ranges** (the read-set). Tell the agent to `rg` for the
   named symbols and to read only those ranges — never `cat` `ContentView.swift`
   (it is huge).
3. **One concern per agent.** Forbid unrelated refactors and "drive-by" changes.
4. **Contract is law.** Do not change §4 signatures without returning CONTRACT-CHANGE.
5. **Plan before code** for non-trivial units (short file-list + approach), then act.
6. **Run the verify command; paste the result.** No green build → not done.
7. **Return the §0 structured summary only** — not file contents — so the
   orchestrator stays small.
8. **Ask before expanding scope.** If the read-set is insufficient, report BLOCKED
   with the specific missing file, don't go spelunking the whole repo.

---

## 11. Research references (verified)

- **Mylar balloon** (why flat-seal ≠ sphere): Paulsen, *What is the shape of a Mylar
  balloon?* (1994); en.wikipedia.org/wiki/Mylar_balloon_(geometry). Half-height/radius
  ≈ 0.599, equatorial shrink ≈ 0.76.
- **LSCM:** Lévy, Petitjean, Ray, Maillot, *Least Squares Conformal Maps*, SIGGRAPH 2002.
- **ARAP:** Liu, Zhang, Xu, Gotsman, Gortler, *A Local/Global Approach to Mesh
  Parameterization*, SGP 2008.
- **Developable segmentation:** Julius, Kraevoy, Sheffer, *D-Charts: Quasi-Developable
  Mesh Segmentation*, CGF 2005; Stein, Grinspun, Crane, *Developability of Triangle
  Meshes*, SIGGRAPH 2018.
- **Geodesics for seam routing:** Crane, Weischedel, Wardetzky, *Geodesics in Heat*, 2013.
- **Inflation simulation / inverse design:** Skouras,
  Thomaszewski, Kaufmann, Garg, Bickel, Grinspun, Gross, *Designing Inflatable
  Structures*, SIGGRAPH 2014 (Disney Research). Forward simulation is enough for
  Tier 1 diagnostics; automatic target-accurate reconstruction requires the Tier 3
  inverse loop.
- **PBD membrane:** Müller, Heidelberger, Hennix, Ratcliff, *Position Based Dynamics*, 2007.
- **Tension field theory** (compression → wrinkles, no energy): Wagner 1929; Reissner 1938.
- **Broadseaming / membrane patterning:** sailmaking practice; Sailcut CAD
  (draw-line vs cut-line, DXF); architectural membrane form-finding (force-density /
  dynamic relaxation) + geodesic seam layout.
- **Papercraft head (later):** Mitani & Suzuki, *Making Papercraft Toys from Meshes
  using Strip-Based Approximate Unfolding*, SIGGRAPH 2004; Pepakura (Tama Software).
