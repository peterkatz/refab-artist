# Refab Artist PRD: Partition — Split by Undercuts

## Status

- **Document type:** product requirements, geometry contract, and staged implementation plan
- **UI name:** **Split by Undercuts** (a second Purpose inside the existing **Partition** construction mode)
- **Internal name:** `PartitionPurpose.splitByUndercuts`
- **Written:** 2026-07-11
- **Supersedes:** the *product contract* of `docs/prd-partition-undercut-elimination.md`. That
  document's Research, Patent, and repo cross-check sections remain accurate reference reading;
  its product definition (strict rigid-two-piece DHF certificates, blocked export, persona
  interviews, FTO gates, certificate hash graphs) is **void** and must not be implemented.
- **Complementary to:** `docs/prd-mothermold-reusable-tooling.md` (that doc molds the *whole*
  master; this doc splits the *object* into pieces that mold easily). Neither replaces the other.
- **Branch:** `feat/partition-split-by-undercuts`, cut from `main`. NOT from any
  `codex/mothermold-*` branch (see §13.2).
- **Final judge:** the owner, in the running app, on his own scans. No milestone is "done" on a
  self-graded agent verdict. Automated gates are necessary, not sufficient.

## 0. Why this rewrite exists

The v1 spec answered a different question than the one asked. The actual requirement:

> Split a model into pieces based on its undercuts, so each piece can be molded — something the
> user does frequently, with **organic scanned models** (hands, masks, figures) and mostly
> **flexible silicone molds** (the MotherMold workflow).

The v1 spec instead built "certify pieces for ideal *rigid* two-piece molds with **zero**
tolerated undercut," explicitly excluded flexible-silicone users from its persona, forbade a
residual-undercut tolerance in v1, and **blocked export** whenever its proof failed. On organic
scans that combination routinely produces "no verified planar solution" with a locked export
button. That is the feature refusing to do its job, politely.

This rewrite keeps everything v1 got right (scoped cut tree, honest measurement language,
attributed geometry, per-piece pull axes, the fixture discipline) and inverts the three decisions
that made it unusable:

1. **Tolerance is the acceptance criterion**, not a mathematical certificate. Strict = tolerance 0
   is just a slider position, not a different architecture.
2. **Export is never blocked.** Statuses label results; they do not lock them.
3. **The user's real scans are hard test gates.** Synthetic fixtures alone recreate the
   convex-blind-spot failure this project has hit three times.

It also deletes ~40% of v1's engineering surface (certificate hash graphs, Merkle assembly roots,
continuous-collision proof engine, atomic-ZIP re-parse revalidation, 20-flag CLI, persona
interviews, FTO counsel gates) because this is a single-user desktop tool and those artifacts
serve auditors who do not exist. §14 lists everything deliberately dropped, so no implementer
"helpfully" re-adds it.

---

## 1. Product definition

### 1.1 One-line summary

Add a **Split by Undercuts** purpose to Partition that divides a watertight model into a small
number of source-faithful pieces such that each piece, along its own stored pull axis, has **no
undercut region deeper than a user-set tolerance** — with editable seams, honest measured
reporting, and export that always works.

### 1.2 The user and workflow (fact, not hypothesis)

The user is the app's owner: a sculptor who scans organic models (hands, masks, vases with faces)
and casts them via MotherMold's silicone-jacket + rigid-shell tooling. Silicone flexes; undercuts
up to a few millimeters release fine. Splitting is needed when a model's undercuts are deep
enough to trap the cast or tear the mold — fingers against a palm, an arm against a torso, a
deep re-entrant fold.

Workflow: import scan → (Make Watertight if needed) → Partition → Split by Undercuts →
inspect/adjust seams → export pieces → build one MotherMold per piece → cast → glue per the
assembly guide.

No market interviews, no persona validation, no public-release process. If it works on
`handStand_ex3` and the mask scans, it works.

### 1.3 The four result states (all exportable)

1. **Whole model within tolerance** — one piece, its pull axis shown, zero cuts. The planner must
   return this whenever a searched or user-given axis passes (never cut an already-moldable
   model).
2. **Split within tolerance** — all pieces green, pull arrows, assembly order.
3. **Split exceeds tolerance** — best result shown; offending regions highlighted in red with
   measured depth/area; recovery actions offered (raise tolerance, add pieces, lock an axis, add
   a manual cut). **Export remains available**, with the exceedances recorded in the report.
4. **Analysis error** — a stage failed (named); pieces produced so far remain inspectable and
   exportable as plain geometry; the report states that no undercut measurement is attached.

### 1.4 Goals

- Zero cuts whenever any searched or user-specified axis puts the whole model within tolerance.
- Few pieces: fixture-manifest bounds per fixture, not a vague "low part count."
- Source surface preserved exactly (cut caps and optional seam pins are the only new geometry).
- Every automated decision inspectable and manually overridable.
- Deterministic: same source + settings + seed → identical pieces (hash-identical meshes).
- Honest measured language everywhere (§3.6). Never "proven," never "no undercuts" unqualified.
- Reuse existing Partition and MotherMold machinery; no second geometry stack, no new
  dependencies.

### 1.5 Non-goals (v1)

- Generating molds (MotherMold's job), simulating resin/silicone physics, guaranteeing draft.
- Modifying/smoothing/deforming the source surface to remove undercuts.
- Freeform/curved parting surfaces or volumetric decomposition (§14, deferred with a re-entry
  condition).
- Mathematical moldability certificates of any kind.
- Support-free FDM optimization; semantic/AI segmentation as ground truth.
- Multi-solid assemblies as one planning run (one effective solid per run; see §10).

---

## 2. Hard rules — R1–R12

These override any other reading of this document. An implementation that violates one of these
is wrong even if every test passes. Every milestone's exit gate re-asserts the rules relevant to
it.

- **R1 — Export is never blocked.** No verification outcome, tolerance exceedance, analysis
  error, or stale state may disable mesh export of the current pieces. Statuses and reports
  describe; they never gate. There is no "export requires verified" code path anywhere.

- **R2 — Tolerance is the one acceptance criterion.** A piece is *within tolerance* iff every
  undercut region with area ≥ `minRegionAreaMM2` has depth ≤ `undercutToleranceMM` (§3.3).
  Strict behavior is `undercutToleranceMM = 0` flowing through the identical code path. No
  hidden zero-tolerance gate may exist behind the user-visible tolerance.

- **R3 — Measured language only.** Every pass/fail statement carries its measurement basis
  ("measured at 0.4 mm grid"). Forbidden words in UI, report, logs, and code comments describing
  results: "proven," "certified," "guaranteed," "no undercuts" (unqualified), "optimal,"
  "moldable" (unqualified). §3.6 has the allowed/forbidden phrasing lists.

- **R4 — Healed scans are first-class inputs.** The input gate is *closed* per the
  `MeshPreflightReport` semantics established in PR #271: watertight = closed (no boundary
  edges), NOT strict 2-manifold, NOT self-intersection-free. Benign self-contact in healed
  organic scans must not block planning, must not degrade status, and must never be cosmetically
  zeroed in reports. If preflight finds the mesh open, offer the existing Make Watertight flow;
  do not silently repair.

- **R5 — Source fidelity.** The pre-joinery union of pieces reproduces the source solid within
  volume tolerance; pieces do not overlap; cut caps and seam pins/pockets are the only authored
  geometry; source exterior vertices may be welded within tolerance but never smoothed or
  displaced. Conservation is a tested invariant on every fixture.

- **R6 — Scoped cuts only.** Every cut applies to exactly one leaf region of the cut tree. A cut
  added to leaf X must leave every other leaf's mesh byte-identical (tested by hashing sibling
  meshes before/after). The Fit Printer purpose keeps its existing global-plane behavior
  untouched; Split by Undercuts never uses global plane replay.

- **R7 — Do not break existing features, and do not touch MotherMold files.** The 24 tests in
  `PartitionTests.swift` and the 5 undercut-named MotherMold tests pass unmodified at every
  milestone. All `Mold*` / `MotherMold*` source files are owned by the in-flight mothermold
  branch work and are **read-only** for this feature: the new analyzer *copies/adapts* the
  low-level math it needs into new files (§5.1) instead of refactoring shared ones. A
  deduplication pass is a separate future ticket after both land.

- **R8 — Determinism.** Same source fingerprint + settings + seed → identical cut tree, piece
  meshes, and report facts. No wall-clock time, no `Date()`, no unseeded randomness, no
  iteration-order dependence on dictionaries/sets anywhere in planning. Budgets are counts, not
  timeouts.

- **R9 — The fixture expectation manifest is law, and real scans are in it.** Gates compare
  against `Tests/Fixtures/undercut-split-expectations.json`. The manifest changes only in a
  dedicated commit whose message justifies each changed value. Weakening a bound to make a
  failing test pass without such justification is forbidden. The committed real-scan fixtures
  (`handStand_ex3_healed_50k.obj`, `open_hemisphere_mask.obj`) have hard success entries (§11.3).

- **R10 — No dead controls.** After any UI change, sweep the entire Partition inspector: every
  visible control either has an effect in the current state or is disabled with a hint
  explaining why. Purpose switching must preserve each purpose's settings (switching to Split by
  Undercuts and back never mutates Fit Printer planes/keys, and vice versa).

- **R11 — Off the main thread, cancellable.** All analysis/planning/verification runs off-main
  via the existing async Generate pattern in `ContentView`. Cancellation is cooperative and
  checked between direction batches, candidate splits, beam expansions, and measurement passes.
  No main-thread stall > 100 ms on the 892k-triangle class of model.

- **R12 — No new dependencies, no cloud.** Swift + the existing vendored Manifold bindings only.
  All gates run locally (`swift test`) — never add CI workflows. No new C/C++ libraries, no
  tetrahedralizers, no graph-cut solvers.

---

## 3. Geometry contract

### 3.1 Conventions

- All manufacturing values in millimeters after Refab Artist's existing import scale/unit
  normalization. Pull directions are normalized model-space vectors; `d` and `-d` are the same
  undirected mold axis.
- Planes: `dot(point, normal) == offset`, normal unit-length, sign-canonicalized so the first
  nonzero component in X/Y/Z order is positive (same rule as the existing private
  `MoldPartitioner.canonicalizedPlanes`; reimplement in a new shared `CanonicalPlane` utility in
  Partition-owned code — do not modify `MoldPartitioner.swift`, per R7).
- Tolerances come from one versioned `UndercutSplitTolerancePolicy` struct (linear weld, ray-hit
  coincidence, angular, min triangle area, absolute + relative volume). Changing the policy
  invalidates cached analyses (bump its version int).

### 3.2 Undercut measurement — the core definition

Implement exactly this; it is the heart of the feature.

Given a solid piece `P` (triangle mesh, closed per R4) and unit pull axis `d`:

1. **Column:** the line `x + t·d` for a sample point `x` in the plane perpendicular to `d`.
2. **Intervals:** intersect the column with the mesh (BVH), sort hits by `t`, merge hits closer
   than the ray-hit coincidence tolerance, and build material intervals
   `[a₁,b₁], …, [a_k,b_k]` (ascending, disjoint) by oriented parity (entering = normal·d < 0
   when traveling +d, standard inside/outside parity; degenerate tangencies resolved by the
   merge tolerance, never by guessing).
3. **Clear / violating:** the column is *clear* if `k ≤ 1`, *violating* if `k ≥ 2`. (One
   interval means an ideal two-sided mold parts somewhere along the column and both halves pull
   free. Two or more intervals mean mold material is trapped in a gap between them.)
4. **Column depth:** for each trapped gap `gᵢ = (bᵢ, aᵢ₊₁)`, `i ∈ 1…k−1`, the mold finger in the
   gap can escape by traversing material either upward or downward:
   - `up(i)   = Σ over j = i+1 … k of (b_j − a_j)`
   - `down(i) = Σ over j = 1 … i of (b_j − a_j)`
   - `depth(gᵢ) = min(up(i), down(i))`
   The column's depth is `max over i of depth(gᵢ)`. Intuition: this is how much material the
   trapped mold finger is hooked behind along the axis — the thing flexible silicone must
   stretch past, and the quantity a tolerance in mm meaningfully bounds.
5. **Sampling grid (deterministic, adaptive):**
   - Project the piece's bounds to the plane ⊥ `d`; lay a regular grid with target resolution
     from the quality setting (§4.2), expressed in mm (e.g. Standard ≈ bounding-diagonal / 256,
     clamped to [0.2 mm, 2.0 mm]).
   - Add one sample at the projection of every vertex of every face whose normal opposes its
     side classification (the cheap face-normal pre-pass seeds where trouble lives).
   - Refine: around every violating column, sample its 8 grid neighbors at half step, repeat
     until no new violating column appears at that scale or the per-direction sample budget
     (§4.2) is exhausted. Deterministic order: row-major, then refinement queue in discovery
     order.
   - The **effective resolution** (final smallest step used, in mm) is recorded and reported —
     it is the honesty qualifier in every status string (R3).
6. **Regions:** map each violating column's blocking hits back to their source faces; cluster
   implicated faces by mesh adjacency (fallback: spatial proximity within 2× grid step for
   faces without adjacency, e.g. across self-contact welds). Each **undercut region** records:
   deterministic content-derived ID, face IDs, `areaMM2` (sum of implicated face areas),
   `depthMM` (max column depth over its columns), centroid, and suggested escape directions
   (used later for cut proposal).
7. **Piece status at tolerance T:**
   - `withinTolerance`  — every region with `areaMM2 ≥ minRegionAreaMM2` has `depthMM ≤ T`.
   - `exceedsTolerance` — otherwise; the report lists every region either way (small regions are
     labeled "below minimum area — ignored for status," never hidden).
   - `measurementFailed` — a stage errored; named stage; no invented numbers.

This measured analysis is the decision signal for the whole feature. There is deliberately **no
separate "exact certificate verifier"** — results are advisory-with-numbers, export never
depends on them (R1), and the honesty comes from stating the resolution (R3). Do not build a
projected-arrangement exact DHF prover; it is v1-void scope (§14).

**Draft advisory (report-only):** faces whose angle to the plane ⊥ `d` is below
`draftAdvisoryDegrees` are summed into a "near-vertical wall area" advisory ("may bind for rigid
tooling; typically fine for silicone"). It never affects status. Cut caps are excluded.

### 3.3 Tolerance semantics

- `undercutToleranceMM` ∈ [0, 10], **default 2.0 mm**. UI hint: "Maximum undercut depth a piece
  may keep. Silicone molds release shallow undercuts; 0 = strict (rigid tooling)."
  The default is provisional until the owner calibrates against real casts (M5 records his verdict in
  the manifest).
- `minRegionAreaMM2` ∈ [0, 100], default 4.0 (advanced). Noise filter for scan micro-detail;
  filtered regions still appear in the report.
- Tolerance applies **per region depth**, not to any global aggregate.

### 3.4 Source fidelity (tested invariants, per R5)

- Pre-joinery: `volume(symmetricDifference(union(pieces), source)) ≤ volumeTolerance`; missing
  and excess volume reported separately; pairwise piece-interior overlap ≤ tolerance.
- Post-joinery: measured total volume equals source + Σ(pin boss) − Σ(pin pocket) within
  tolerance; nothing else changed.
- Every output triangle carries provenance (§5.3): `source(faceID)` | `cut(nodeID, side)` |
  `joinery(seamID, featureID)`. Painted constraints bind to source faces only; fidelity checks
  compare source-provenance surface against the original.

### 3.5 Assembly guarantee — the half-space argument (replaces v1's collision engine)

Every cut is planar and scoped: each child of a cut node lies entirely within one closed
half-space of that node's plane. Therefore:

> **Disassembly:** traverse the cut tree top-down; at each node, translate the positive-side
> subtree (as a rigid group) any distance along the node plane's +normal. Containment in
> disjoint half-spaces makes every such motion collision-free by construction. **Assembly** is
> the exact reverse order with inverted translations.

No continuous-collision engine, swept-volume test, or content-addressed motion-event Merkle
root is needed or permitted (§14). The assembly guide (§8.2) simply serializes this traversal:
ordered steps, each with moving piece set, direction, and a suggested display distance.

**Joinery must preserve the argument:** a seam pin pair is valid iff its axis is parallel to the
seam plane's normal (within angular tolerance) and the male boss is a prism/cone that narrows or
stays constant toward its tip. That keeps separation along the seam normal collision-free.
Enforced at placement time; violating placements are rejected with a message, not silently
skipped. After applying a pin pair, re-run undercut measurement on both affected pieces along
their pull axes; if a pin pushes a piece over tolerance, warn (do not block — R1) and name the
pin.

### 3.6 Honest status wording

Allowed (templates — substitute real numbers):

- "Whole model is within the 2.0 mm undercut tolerance along Z (measured at 0.4 mm grid)."
- "All 4 pieces are within the 2.0 mm undercut tolerance (measured at 0.4 mm grid)."
- "Piece C has 2 undercut regions deeper than tolerance (worst 5.3 mm, 210 mm²). You can add a
  cut to Piece C, raise the tolerance, change its pull axis — or export anyway."
- "Analysis failed at interval construction on Piece B. Pieces can still be exported; no
  undercut measurement is attached."
- "No split within tolerance was found in this search (max 8 pieces, Standard quality). Best
  attempt shown. A finer search or a manual cut may still succeed."

Forbidden:

- "No undercuts" without the measured-at qualifier.
- "Proven," "certified," "guaranteed," "optimal," "injection-molding ready."
- "Cannot export," "export disabled," or any equivalent (R1).
- Presenting a search miss as geometric impossibility ("this model cannot be split").

---

## 4. Parameters

### 4.1 User-facing

| Parameter | Type / range | Default | Notes |
|---|---|---|---|
| Purpose | Fit Printer / Split by Undercuts | existing projects → Fit Printer | selects objective + inspector; per-purpose settings are independent (R10) |
| Planning | Automatic / Manual | Automatic | Automatic builds the scoped cut tree; Manual edits an adopted or hand-built tree |
| Pull policy | Automatic / Fixed / Per-piece locks | Automatic | Fixed = one axis for all pieces; locking a generated piece's axis adopts the tree into Manual (one undoable action) |
| Fixed pull axis | unit vector | +Z when first selected | numeric entry + direction ring (reuse existing ring control) |
| **Undercut tolerance** | 0–10 mm | **2.0 mm** | THE acceptance knob (§3.3); 0 = strict |
| Min region area | 0–100 mm² | 4.0 | advanced; noise filter, report still lists filtered regions |
| Search quality | Quick / Standard / Thorough | Standard | deterministic budgets (§4.2), never wall-clock |
| Max pieces | 1–32 | 8 | hard search bound; exhaustion → state 3 of §1.3, still exportable |
| Priority | Fewer pieces / Balanced / Cleaner seams | Balanced | permutes tie-break order only (§6.7); never overrides tolerance keys |
| Draft advisory | 0–10° | 1° | report-only (§3.2) |
| Minimum piece volume | 0–10% of source, floor mm³ | 0.5%, floor 1 mm³ | rejects slivers at candidate stage |
| Minimum seam area | ≥ 0 mm² | 4 mm² | rejects fragile caps at candidate stage |
| No-cut paint | per-face, hard | none | source faces only; if it makes all candidates infeasible, report the conflict — never ignore paint |
| Preferred-seam paint | per-face weight 0–1 | none | soft cost only |
| Seam keys | None / Pins | None | reuses existing `PartitionKeys` pin geometry under the §3.5 axis rule; dovetail/wedge stay Fit-Printer-only in v1 |
| Output | Separate STL ZIP / Named-object OBJ ZIP | STL ZIP | reuses Partition packaging; always includes report + assembly guide |
| Seed | Int64 | stable project default | tie-breaking and candidate ordering only |

Control-interaction matrix (R10 — enforce and test):

- Purpose = Fit Printer → every Split-by-Undercuts control hidden; Fit Printer's existing
  controls untouched.
- Purpose = Split by Undercuts → Fit Printer's printer preset / build volume / bed margin /
  key-type controls hidden (not disabled-dead — hidden; they belong to the other purpose).
- Pull policy ≠ Fixed → direction ring hidden. Planning = Automatic → per-node lock buttons
  shown but tagged "adopts tree into Manual."
- Seam keys = None → pin clearance/count controls hidden.
- While planning runs → Generate becomes Cancel; all planning inputs disabled with hint
  "Planning in progress."

### 4.2 Quality budgets (implementation constants, benchmarked in M2, then locked)

| Quality | Direction samples (icosphere + derived) | Base grid target | Refinement passes | Candidate planes / leaf expansion | Beam width | Finalists re-measured at Thorough |
|---|---:|---:|---:|---:|---:|---:|
| Quick | 42 + derived | diag/128 | 1 | 16 | 4 | 2 |
| Standard | 162 + derived | diag/256 | 2 | 32 | 8 | 3 |
| Thorough | 642 + derived | diag/512 | 3 | 64 | 16 | 3 |

Grid clamps: [0.2 mm, 2.0 mm] step. The persisted setting is the enum; changing constants later
bumps `plannerVersion` so reopened projects can explain regenerated differences.

---

## 5. Code structure and persisted model

### 5.1 New files (Partition-owned; never touch `Mold*`/`MotherMold*` files — R7)

```
Sources/RefabArtist/
  UndercutSplit.swift                    // settings, enums, tolerance policy, status types
  PartitionCutTree.swift                 // tree, nodes, region IDs, replay, validation
  SourceFaceMap.swift                    // provenance through repeated clips
  CanonicalPlane.swift                   // shared plane canonicalization (new impl, §3.1)
  DirectionalAccessibilityAnalyzer.swift // §3.2 column/interval/region machinery
  UndercutRegionClusterer.swift          // region clustering + metrics
  PullDirectionCandidates.swift          // §6.2 candidate axis generation
  UndercutSplitPlanner.swift             // §6 pipeline: fast path, beam search, refinement
  UndercutSplitReport.swift              // report model + JSON encoding (§8.3)
  UndercutSplitOverlay.swift             // viewport overlay data (regions, arrows, planes)
Tests/RefabArtistTests/
  DirectionalAccessibilityTests.swift
  PartitionCutTreeTests.swift
  UndercutSplitPlannerTests.swift
  UndercutSplitFixtureTests.swift        // manifest-driven, includes real scans
  UndercutSplitExportTests.swift
Tests/Fixtures/
  undercut-split-expectations.json       // §11.3 manifest
```

Where `MoldUndercutAnalyzer.swift` contains reusable low-level math (ray parity, backdraft dot
tests), **copy and adapt** into `DirectionalAccessibilityAnalyzer.swift` with a comment noting
the origin. Do not import, call, subclass, or modify the Mold types (R7). Note one deliberate
semantic fork: MotherMold's heuristic flags a Z-axis torus as an undercut warning; the new
analyzer must report a Z-axis torus as *clear* (every column has ≤ 1 interval). A fixture pins
this (§11.2).

### 5.2 Settings and migration

```swift
enum PartitionPurpose: String, Codable {
    case fitPrinter
    case splitByUndercuts
}

// Added to the existing PartitionSettings (Partition.swift):
//   var purpose: PartitionPurpose        // decodeIfPresent, default .fitPrinter
//   var undercutSplit: UndercutSplitSettings?   // decodeIfPresent; nil → .defaultValue in UI

struct UndercutSplitSettings: Codable, Equatable {
    var planningMode: UndercutPlanningMode      // .automatic / .manual
    var pullPolicy: PullDirectionPolicy         // .automatic / .fixed / .perPieceLocks
    var fixedPullDirection: Vec3?
    var undercutToleranceMM: Double             // default 2.0
    var minRegionAreaMM2: Double                // default 4.0
    var quality: UndercutSearchQuality          // .quick / .standard / .thorough
    var maxPieces: Int                          // default 8
    var priority: UndercutSplitPriority         // .fewerPieces / .balanced / .cleanerSeams
    var draftAdvisoryDegrees: Double            // default 1.0
    var minimumPieceVolumeFraction: Double
    var minimumPieceVolumeMM3: Double
    var minimumSeamAreaMM2: Double
    var seamKeys: UndercutSeamKeySettings       // .none / .pins(existing pin params)
    var faceConstraints: PartitionFaceConstraints
    var lockedPullDirections: [PartitionRegionID: Vec3]
    var authoredCutTree: PersistedCutTreeEnvelope?  // Manual mode recipe; §5.4
    var seed: Int64
    var plannerVersion: Int
    var tolerancePolicyVersion: Int
}
```

Migration rules (all tested):

- Projects without `purpose` decode as `.fitPrinter`; zero behavior change for existing
  projects (the 24 Partition tests prove this).
- `PartitionSettings.mode`, `manualPlanes`, `key`, `packaging`, printer preset fields remain
  exclusively Fit Printer's; Split by Undercuts never reads or writes them (R10).
- New fields use `decodeIfPresent` with defaults, matching the project's existing migration
  pattern.
- The **stale/Generate signature** for this purpose reuses the app's existing stale-signature
  pattern in `ContentView`: hash of (effective source fingerprint, every `UndercutSplitSettings`
  field, purpose). No bespoke canonical-encoding hash spec — same mechanism the other modes use.

### 5.3 Cut tree, region identity, and provenance

```swift
struct PartitionCutTree: Codable, Equatable {
    var rootRegionID: PartitionRegionID
    var nodes: [PartitionCutNode]        // parent-before-child order
}

struct PartitionCutNode: Codable, Equatable, Identifiable {
    var id: PartitionCutNodeID           // stable content hash, §below
    var targetRegionID: PartitionRegionID
    var plane: CanonicalPlane
    var negativeChildID: PartitionRegionID
    var positiveChildID: PartitionRegionID
    var source: CutSource                // .automatic / .manual
    var isLocked: Bool
}
```

- Automatic node IDs: hash of (plannerVersion, canonical parent region ID, canonical plane
  coefficients, sibling ordinal). Child region IDs: hash of (node ID, "negative"/"positive").
  Manual node IDs: created once, persisted, never regenerated from time (R8).
- Replay = apply each node's plane **only to its recorded parent region** (R6), depth-first in
  serialized order. Replaying against a different source fingerprint is an error surfaced to
  the panel, never a silent regenerate.
- **Provenance:** `PartitionGeometry`'s current clip path passes bare `(Vec3,Vec3,Vec3)` soup
  (see `clipHalfSpace`) and loses face identity. Add **new attributed entry points alongside
  the existing ones** (do not change the current API Fit Printer uses): each fragment carries
  its source face ID; cap triangles carry `cut(nodeID, side)`; pin geometry carries
  `joinery(...)`. One-to-many clipping and repeated subtree replay preserving provenance are
  dedicated unit tests, not assumed.
- Seam adjacency: each cut node's cap pair defines one physical seam (piece A face ↔ piece B
  face); exported guide and pin placement use this adjacency.

### 5.4 Authored-tree persistence (Manual mode)

Keep v1's quarantine idea in simplified form, because it is genuinely good Codable hygiene:
persist the authored tree inside an envelope `{schemaVersion, sourceGeometryFingerprint,
rawTree: JSONValue}` decoded in two steps — capture `rawTree` first, then attempt the typed
decode. A typed-decode or structural-validation failure quarantines the tree (raw payload kept,
diagnostics listed in the panel, plan unavailable for this purpose) but **never** fails the
surrounding project decode or touches other purposes. Structural validation: exactly-two-children
per node, no cycles/orphans/duplicates, parent-before-child order, finite canonical planes.
Source-bound validation on load: fingerprint match, replay succeeds, constraints/locks reference
existing regions. Failing trees are kept for repair or explicit deletion — reopening a project
never silently drops or rewrites authored nodes.

What is deliberately NOT kept from v1: `selectedAutomaticAlternativeTreeHash` ceremony,
`RigidMoldGenerationInputHash` canonical-encoding law, `CurrentRigidMoldPlanKey` /
`CurrentRigidMoldExportKey`, certificates, proof digests. Automatic results are cached under the
ordinary stale signature (§5.2) and regenerate deterministically (R8) on reopen; the selected
alternative persists as a simple enum/index in view state.

---

## 6. Algorithm

### 6.1 Pipeline

```
preflight (closed per R4; unit scale; BVH; adjacency; volume; fingerprint)
 → candidate pull directions (§6.2)
 → measure whole model along ranked candidates (§3.2)
 → within tolerance? → DONE: one piece                        [zero-cut fast path]
 → cluster worst undercut regions on the worst leaf (§6.4)
 → propose scoped planes for that leaf (§6.5)
 → scoped split + measure children (§6.6)
 → deterministic beam search over cut trees (§6.7)
 → plane refinement on top states (§6.8)
 → full-resolution rebuild + final measurement + fidelity checks (§6.9)
 → apply seam pins if enabled, re-measure affected pieces (§3.5)
 → emit result (one of §1.3's four states) + report
```

Large meshes: build a search proxy via `ManifoldEngine.simplify(tolerance:)` (manifold-
preserving — never stride decimation, which produced notManifold failures in MotherMold work)
capped at ~150k triangles for stages 2–8; stage §6.9 always rebuilds and measures from the
full-resolution source.

### 6.2 Candidate pull directions

World X/Y/Z; oriented-bounding-box axes; PCA axes; stable clusters of the face-normal
distribution; normals of large planar regions; detected rotational-symmetry axes; deterministic
icosphere sample per quality (§4.2); user Fixed axis; Manual per-piece locks. Deduplicate by
angular tolerance, sign-canonicalize, sort deterministically (R8). `d`/`−d` are one candidate.

### 6.3 Zero-cut fast path

Measure the whole model along ranked candidates; first within-tolerance axis wins → return one
piece with that axis. Never cut an already-within-tolerance model because a multi-piece state
scores prettier seams. A miss is reported as "not found in this search," never "impossible"
(§3.6). Manual Fixed axis is always measured and reported even when it exceeds tolerance.

### 6.4 Worst-leaf selection and region clustering

Among leaves exceeding tolerance, pick lexicographically worst by: (1) no candidate axis within
tolerance, (2) largest max region depth, (3) largest total over-tolerance region area, (4) most
disconnected regions, (5) largest volume. Cluster per §3.2.6; record per-region escape-direction
hints and nearby concave feature lines.

### 6.5 Scoped plane proposal (for the selected leaf only)

Sources: planes through undercut-region boundaries (the seam that "unhooks" the region); large
flat-region alignments; concave-edge loops/valleys; local PCA of the violating cluster;
symmetry planes; inherited good axes for expected children; fallback quantized offsets at
20/35/50/65/80% along the leaf's principal axes; locked manual planes. Each base plane expands
into a deterministic neighborhood of offset/angle perturbations per quality.

Prefilters (reject before splitting): doesn't actually split the leaf; either child below
minimum piece volume; crosses a no-cut face; cap area below minimum seam area; creates
unrequested disconnected fragments; splitter fails to produce two closed children; volume
conservation fails.

### 6.6 Scoped split

Use the existing arbitrary-plane clip + cap pipeline through the new attributed entry points
(§5.3). Each accepted cut creates one `PartitionCutNode`, two child region IDs, one seam
adjacency. For finalists (§6.9), cross-check the triangle-soup split against
`ManifoldEngine.splitByPlane`; disagreement beyond tolerance is a surfaced geometry error, not a
pick-whichever-looks-better.

### 6.7 Beam search

Frontier of `PartitionSearchState {cutTree, leaves, facts}`; expand worst leaf per §6.4; retain
`beamWidth` best; deduplicate states by canonical cut-tree equality. Objective is lexicographic
— compare in exactly this order:

1. number of pieces exceeding tolerance          (hard-ish: dominates everything below)
2. total excess depth over tolerance, mm         (Σ over regions of max(0, depth − T))
3. total over-tolerance region area, mm²
4. piece count
5. sliver penalty
6. seam detail penalty (curvature/saliency/preferred-paint under the cut)
7. total seam area
8. piece volume variance
9. deterministic tie-break (seeded hash)

Priority profiles permute only keys 4–8 (Fewer pieces: 4,5,6,7,8; Balanced: 5,4,6,8,7; Cleaner
seams: 6,7,5,4,8). Keys 1–3 are never reordered or folded into a weighted scalar — a state that
exceeds tolerance can never beat one that doesn't on seam beauty.

> **Amended 2026-07-13.** The lexicographic objective above governs **final answer selection
> only**. It must NOT be used to rank or prune intermediate search states: key 1 (failing piece
> count) is not monotone under further cuts, so a temporarily-worse state (one hard core split
> into two hooked children) is often the only route to resolving both. Using the final objective
> during exploration provably starves the search into repeated sliver peels (measured on the
> hand fixture: the "dominance prune" implementation of this section deleted every viable
> intermediate state). Exploration ranks candidate cuts by **minimax child depth** (smallest
> worst-child measured depth, cheap direction battery), recursing on the worst failing leaf,
> and applies a cut only when it improves that leaf's depth by more than the measurement
> quantum. The final objective compares completed trees (including the always-retained
> best-so-far fallback) when choosing what to present.

Stop when: fast path already succeeded; budget exhausted; no retained state can expand; Max
Pieces reached; or cancel (cancel returns no new plan; prior plan stays, marked stale if
settings changed). Results are "best found within this search," never "optimal."

Up to three alternatives (one per profile) when their cut trees differ; identical trees shown
once.

### 6.8 Refinement

Deterministic coordinate descent on unlocked planes of top states (small offset/angle steps).
Accept only if no key 1–3 regresses on any leaf and the full objective improves. Planar in,
planar out — no curved-surface generation.

### 6.9 Full-resolution finalization

Replay the winning tree against the original full-res source (attributed). Then, per piece:
closed-mesh check, orientation, undercut measurement along its axis at Thorough grid,
conservation checks (§3.4), pairwise overlap, draft advisory. Assemble the report. Any failure
here surfaces as §1.3 state 3 or 4 — visible, explained, exportable.

---

## 7. UI specification

### 7.1 Inspector (Partition panel, left progressive rail — existing conventions)

Top: **Purpose** picker (Fit Printer / Split by Undercuts). Below, for Split by Undercuts, in
order:

1. **Release** — Pull policy (Automatic / Fixed [+ ring when Fixed]), Undercut tolerance
   slider+field with the silicone hint (§3.3).
2. **Decomposition** — Max pieces, Priority.
3. **Status** — one plain-language line per §3.6, piece count, worst offender; disclosure with
   per-piece rows (axis, worst depth, region count, measured-at resolution).
4. **Seam keys** — None / Pins (+ pin params when Pins).
5. **Output** — format picker; Export button (**always enabled** when pieces exist — R1; if
   status is exceeds-tolerance, the button subtitle reads "Exports with warnings in report").

**Advanced** disclosure: quality, min region area, draft advisory, min piece volume, min seam
area, seed, tolerance-policy version (read-only).

The existing outer construction action is the single Generate ("Analyze & Split"); no second
button inside the panel. While running: phase label, evaluated-candidate count, elapsed, Cancel
(R11).

After a result: contextual editing — select cut node (plane surface, not just a handle), move /
rotate via existing gizmo patterns keyed by node ID (never array index), add cut to selected
piece, delete cut (collapses its subtree after confirmation; preserves face paint; drops
descendant pull locks with warning), lock/unlock node, per-piece pull lock, no-cut and
preferred-seam painting, piece isolation, Explode (slider; motion follows §3.5 traversal).
Locking anything generated adopts the tree into Manual in one undoable action.

### 7.2 Viewport

- Stable per-piece colors; source ghost when exploded.
- Pull arrow per piece (reuse MotherMold demold-arrow pattern).
- Cut plane surfaces for selected/hovered nodes.
- **Red** overlays on over-tolerance regions with depth labels on hover; **amber** for
  within-tolerance-but-nonzero regions and low-draft advisory area; **green** outline only after
  final measurement passes (wording per §3.6 — measured, not proven).
- Explode animates the §3.5 disassembly order.

### 7.3 Dead-control sweep (R10)

The M3 exit gate includes a written sweep of every control in the Partition inspector in both
purposes, listing for each: visible when, enabled when, effect, and hint text when disabled.
Any control with no effect in a reachable state is a gate failure.

---

## 8. Export, report, headless

### 8.1 Packaging

Reuse the existing Partition export pipeline and ZIP packaging. Contents:

```
<model>-undercut-split.zip
  <model>-piece-A.stl …            (or one named-object OBJ)
  assembly-guide.txt
  undercut-report.json
```

Deterministic piece names from cut-tree region IDs (A, B, C… in deterministic order). Geometry
in the assembled model frame. No atomic-ZIP re-parse revalidation machinery — the existing
exporter's behavior is fine; if a piece fails to serialize, fail the export with a message
(don't silently skip pieces).

### 8.2 assembly-guide.txt

Per piece: name, color, pull axis. Then ordered assembly steps (reverse §3.5 disassembly): which
piece/group moves, along which direction, mating seam, pin count if any. Footer states exactly
what was and wasn't checked: "Geometry measured for undercuts at X mm grid; material behavior,
shrinkage, and mold construction are not simulated."

### 8.3 undercut-report.json

Schema-versioned. Contains: app/planner/tolerance-policy versions; source fingerprint, units,
bounds, volume; settings snapshot; cut tree (nodes + planes) and seam adjacency; per piece —
mesh hash, volume, bounds, pull axis, status, measured-at resolution, every region (id, depth,
area, face count, over/under tolerance, filtered-by-area flag), draft advisory area;
conservation summary (missing / excess / overlap volumes); assembly steps; overall status; and
`warnings: []` strings mirroring every UI advisory. No hash of itself, no certificates.

### 8.4 Headless flags (minimal — enough to run fixtures and scripts locally)

```
--partition-purpose split-by-undercuts
--undercut-tolerance-mm N
--undercut-quality quick|standard|thorough
--undercut-max-pieces N
--undercut-pull auto|x|y|z|NX,NY,NZ
--undercut-priority fewer|balanced|cleaner
--undercut-seed N
--undercut-output separate-stl-zip|named-obj-zip
```

Wired through the existing `HeadlessExportCommand` patterns; unknown flag = error. Headless
stdout echoes the key report facts (status, piece count, worst depth, per-piece pulls, report
path). Manual/authored-tree CLI ingestion is **not** v1 (§14) — headless is Automatic-only.

---

## 9. Performance and concurrency

- All work off-main via the existing async Generate pattern; cooperative cancellation (R11).
- Budgets (provisional until M2 measures them on the owner's machine; then locked into the manifest):
  - `handStand_ex3_healed_50k.obj` (≈50k tris), Standard: full pipeline ≤ 30 s.
  - `open_hemisphere_mask.obj`, Standard: ≤ 10 s.
  - 892k-triangle class (Sardiniers6): search on ≤150k proxy, final full-res measurement;
    Standard ≤ 5 min; peak memory < 4 GB; zero main-thread stalls > 100 ms.
- Caching: per-(mesh fingerprint, direction, resolution) accessibility fields in an actor-owned
  store, reusable across beam states; invalidated by tolerance-policy or planner version bumps.
  Manifold handles confined to one owning task (existing engine rule).
- If targets are missed: reduce proxy resolution or search breadth. Never "save time" by
  reporting a coarser measurement as if it were the configured one (R3).

---

## 10. Edge-case policy

| Case | Behavior |
|---|---|
| Open mesh | Block planning only; offer existing Make Watertight; healed mesh becomes the explicit source (R4). Export of the untouched source is of course unaffected. |
| Benign self-contact (healed scans) | Plan normally; never degrade status for it; counts reported honestly (R4). |
| Multiple disconnected solids | One effective solid per run; block planning with "separate the objects first" message. Pre-existing components never count as cuts. |
| Nested shell / trapped internal component | Honest report: "enclosed component has no linear escape path; splitting the outer shell cannot free it." Planning may proceed on the outer solid's undercuts; the report keeps the note. |
| Through-holes / internal cavities | A through-hole aligned with the pull axis is clear by the column math (single interval per column). A blind side hole shows up as a real region with a real depth. No special-casing — trust §3.2. |
| Torus along its axis | Clear (every column ≤ 1 interval). Deliberate fork from MotherMold's warning heuristic; pinned by fixture. |
| Coplanar / vertex-grazing cuts | Existing canonical tolerance handling; a cut producing zero-thickness caps or ambiguous ownership is rejected as a candidate. |
| Thin features | Detail-avoidance cost + no-cut paint (hard). If every candidate crosses protected faces, report the conflict with the faces highlighted. |
| Tiny debris from a cut | Never silently dropped: either the candidate is rejected (unrequested fragment) or the piece is named and listed. |
| Max Pieces exhausted | §1.3 state 3: best attempt, red regions, recovery actions, export available. |
| Search misses a good axis | Thorough widens sampling; Fixed/locks accept arbitrary axes; wording per §3.6. |
| Zero/low draft | Advisory only (§3.2). |
| Pin would exceed tolerance on a piece | Place-and-warn or reject per §3.5; never silently keep a stale green status. |

---

## 11. Fixtures and tests

### 11.1 Baseline protection (every milestone)

- All 24 tests in `PartitionTests.swift` pass unmodified.
- All 5 undercut-named MotherMold tests pass unmodified
  (`testUndercutAnalyzerFlagsReentrantTorus`, `testUndercutAnalyzerPassesConvexCube`,
  `testUndercutAnalyzerLPrismConcaveCornerIsReentrantLaterally`,
  `testSiliconeSubtypeDoesNotEnforceUndercutsSlipDoes`,
  `testConvexSphereHalvesAreNotReportedAsUndercut`).
- Full suite green before any milestone is declared done.

### 11.2 Analytic fixtures (generated in test code, expected values derived, not eyeballed)

| Fixture | Expected contract |
|---|---|
| Cube | 1 piece; X/Y/Z all clear; zero regions |
| Sphere | 1 piece; all sampled axes clear |
| Z-extruded L-prism | 1 piece along Z; lateral axes report a region whose depth equals the analytically known leg thickness (assert the number within grid tolerance) |
| Torus, axis Z | 1 piece along Z; **zero** regions (the deliberate fork from MotherMold's heuristic) |
| Blind side-hole block | Along Z: one region; depth = min(material above hole, material below), analytic; another axis clear if geometry allows |
| **Shallow-bead block** (block with a 1.5 mm-deep lateral groove bead) | THE tolerance-semantics fixture: 1 piece at T = 2.0; exceeds at T = 1.0; exceeds at T = 0 (strict); identical code path all three (R2) |
| Orthogonal double hook (v1's fixture: region A moldable along ±X, region B along ±Y, joined at x = 0) | 2 pieces at T = 0; the x = 0 cut recovered; per-piece axes X and Y; assembly = one step along the seam normal |
| U-joint | piece-count range from manifest |
| Hollow bottle with re-entrant flared lip | multiple pieces or honest exceeds-tolerance at planar limits; manifest records which |
| Nested shell with trapped core | honest "no linear escape" note; no false green |
| Thin protected arm | no-cut paint honored; conflict reported rather than amputation |

### 11.3 Real-scan fixtures (committed; hard gates — R9)

Already in the repo at `app/RefabArtist/Tests/Fixtures/`:

- `handStand_ex3_healed_50k.obj` — healed organic hand scan, ≈50k tris.
- `handStand_ex3_ui_healed.obj` — alternate heal of the same scan.
- `open_hemisphere_mask.obj` — mask-like open-back organic shape.

Manifest entries (`Tests/Fixtures/undercut-split-expectations.json`) record for each: source
hash, settings (T = 2.0 mm, Standard, seed fixed; explicit maxPieces per fixture), expected
overall status, allowed piece-count range, worst-depth regression bound, and runtime bound.

> **Amended 2026-07-13 (measured evidence, per §14).** The original gate demanded ≤ 8 pieces
> all within 2.0 mm on the hand. An 11-round measured feasibility study (~300 candidate planes,
> evidence-guided manual tree construction through the production splitter/analyzer; reference
> tree preserved in `UndercutFeasibilityProbeTests`) established that no planar ≤ 8-piece
> decomposition of this fixture meets 2.0 mm: measured frontier 8 pieces → worst ≈ 8.1 mm,
> 11 → ≈ 6.1 mm, 13 → ≈ 4.4 mm; full 2.0 mm compliance extrapolates to 16–20 pieces with many
> pieces marginal at 2.0–2.6 mm. Those numbers — not full compliance — are the baseline the
> planner is gated against. The 8-piece/2.0 mm pairing was authored without physical
> validation and is void as a completion condition.

**Hard requirements for M2 exit:**

- `handStand_ex3_healed_50k` (T = 2.0 mm, maxPieces 13, Standard, fixed seed): the planner's
  automatic result **matches or beats the measured manual baseline**: worst piece depth
  ≤ 4.5 mm (Thorough-confirmed), piece count ≤ 13, at least 6 pieces within 2.0 mm. Overall
  status `exceedsTolerance` is the *expected honest outcome* at these settings and does not
  fail the gate (R1/R3: describe, never block). Per-piece pull axes are expected to differ
  (fingers vs. palm) and to include non-axis-aligned directions — a single-global-axis
  solution is not required and axis-aligned-only search cannot pass this fixture.
- `open_hemisphere_mask`: within tolerance at ≤ 2 pieces.
- Both: deterministic across two consecutive runs (identical piece mesh hashes).
- Earned numbers only: the manifest records what two consecutive runs actually produced
  (achieved worst depth, piece count, cold runtime as the regression bounds). Populating the
  manifest with unearned values remains an R9 violation.

If the planner cannot meet these, **the planner is not done** — fix the planner (better plane
proposals, better direction candidates), do not relax the manifest (R9). This is the gate that
prevents the "fixtures pass, the owner's real models fail" failure mode. Conversely, chasing full
2.0 mm compliance at ≤ 8 pieces on this fixture is chasing a measured impossibility — depth
targets below the recorded frontier require either more pieces, a physically calibrated higher
tolerance (§3.3 calibration in M5), or the §14 freeform re-entry.

### 11.4 Behavioral / negative tests

- Scoped-cut isolation: hash every sibling leaf before/after adding a cut to leaf X; identical
  (R6).
- Export-never-blocked: a plan in exceeds-tolerance state exports successfully; report carries
  the warnings (R1).
- Strict mode: T = 0 on shallow-bead → exceeds; same code path verified (R2: no separate strict
  branch — assert via code coverage or a single decision-point unit test).
- Region below min-area: excluded from status, present in report with filtered flag.
- Zero-cut fast path: already-clear model with a tempting "pretty seam" candidate → 1 piece.
- Tolerance-first objective: a 3-piece within-tolerance state beats a 2-piece exceeding state
  under every priority profile (§6.7 keys 1–3 immutable).
- Healed-scan admission: `handStand_ex3_healed_50k` (which retains benign self-contact) enters
  planning without repair prompts (R4).
- Migration: a saved pre-purpose project decodes as Fit Printer with planes/keys intact; a
  project saved in each purpose round-trips both purposes' settings independently (R10).
- Quarantine: corrupt authored tree → project opens, tree quarantined with diagnostics, raw
  payload preserved (§5.4).
- Determinism: same seed twice → identical cut-tree, piece hashes, report facts; different seed
  may differ (R8).
- Pin axis rule: pin proposed off the seam normal is rejected; on-normal pin that pushes a piece
  over tolerance produces a warning, not a block (§3.5).
- Provenance: after 3 nested cuts, every triangle has provenance; source-provenance area equals
  original source area within tolerance (§5.3).
- Conservation on concave + hollow fixtures (§3.4).
- Torus fork: new analyzer clear on Z-torus while `testUndercutAnalyzerFlagsReentrantTorus`
  still passes for MotherMold (both simultaneously — proves the fork didn't leak, R7).

### 11.5 Visual evidence (M5)

For cube, torus, double hook, shallow-bead, hand scan, mask: assembled view, exploded view, pull
arrows, red/amber overlays, one exceeds-tolerance case showing recovery actions and the enabled
export button. Rendered screenshots attached to the PR; The owner reviews in-app before merge.

---

## 12. Milestones

Each milestone: tests first, exit gate = commands + expected observable output, baseline
protection (§11.1) always included. File ownership per §13.3.

### M0 — Analyzer, metric, fixtures  *(no UI, no planner)*

Deliverables: `DirectionalAccessibilityAnalyzer` (§3.2 in full: intervals, adaptive grid,
depth formula, effective-resolution reporting), `UndercutRegionClusterer`,
`PullDirectionCandidates`, `CanonicalPlane`, analytic fixture generators (§11.2), manifest file
with analytic entries + first measured real-scan baselines (measurement only — no split
expectations yet), `DirectionalAccessibilityTests`.

Exit gate:
```
swift test --package-path app/RefabArtist \
  --scratch-path /tmp/refabartist-swiftpm-undercut \
  --filter 'DirectionalAccessibility|PartitionTests|Undercut'
```
- Cube/sphere/torus-Z/L-prism-Z report zero regions; L-prism lateral and blind-hole depths match
  analytic values within grid tolerance; shallow-bead reports depth 1.5 ± grid.
- Both hand-scan heals and the mask produce region lists with measured depths; numbers recorded
  in the manifest.
- The 5 MotherMold undercut tests untouched and green (R7 — proves copy-not-refactor).

### M1 — Cut tree + attributed geometry + persistence  *(independent of M0; can run in parallel)*

Deliverables: `PartitionCutTree` (IDs, replay, structural + source-bound validation, quarantine
envelope), `SourceFaceMap`, attributed clip/cap entry points added alongside the existing
`PartitionGeometry` API, seam adjacency, `PartitionPurpose` + `UndercutSplitSettings` +
migration, `PartitionCutTreeTests`.

Exit gate: scoped-cut isolation test (R6); provenance-completeness after nested cuts;
conservation on concave/hollow fixtures; migration + quarantine + round-trip tests; 24
Partition tests green with the old API untouched.

### M2 — Planner  *(needs M0 + M1 interfaces)*

Deliverables: `UndercutSplitPlanner` (§6 complete: fast path, worst-leaf, proposal, prefilters,
beam search with the §6.7 objective, refinement, full-res finalization, alternatives,
cancellation), proxy decimation path, caching actor, Manifold cross-check on finalists,
integration behind the existing Generate/stale pattern (no visible UI yet beyond a debug hook),
`UndercutSplitPlannerTests`, `UndercutSplitFixtureTests` manifest-driven.

Exit gate: zero-cut fast path fixtures; double hook recovers the x = 0 cut with per-piece X/Y
axes; tolerance-first objective test; **the §11.3 real-scan hard gates pass**; determinism
double-run; performance budgets measured and recorded in the manifest (the owner's machine);
cancellation leaves prior plan intact.

### M3 — UI  *(needs M2 API; parallel with M4)*

Deliverables: §7 in full — purpose picker, inspector sections, status language, overlays,
editing (gizmo by node ID, add/delete/lock, paint, isolation, explode per §3.5), progress +
cancel, adoption-into-Manual transaction, undo integration.

Exit gate: dead-control sweep document (§7.3) with zero violations; wording audit — grep the
diff for forbidden phrases (§3.6/R3) finds nothing; edits never leave a stale green status
(edit → status shows stale/re-measure); export button enabled in exceeds-tolerance state (R1);
screenshots of every §1.3 state.

### M4 — Export, report, headless  *(needs M2; parallel with M3)*

Deliverables: §8 in full — packaging reuse, assembly guide, `undercut-report.json`,
headless flags, stdout facts, `UndercutSplitExportTests`.

Exit gate: export-never-blocked test; report schema test (regions, filtered flags, warnings
mirror UI); headless run on the shallow-bead fixture at three tolerances produces three
statuses through one code path (R2); assembly guide lists every seam and step; save/open →
regenerate → identical report facts (R8).

### M5 — Real-model validation + docs + owner review  *(integration; no new features)*

Deliverables: full-suite run; §11.5 visual evidence; run on the owner's live scans beyond the
committed fixtures (the hand scans under `app/RefabArtist/Tests/Fixtures/hand-scans/`; a model that is not committed is read from a path named by an environment variable and skipped when it is unset); known-
limitations doc section (planar seams only, sampling resolution, unmodeled material physics);
manifest updated with final measured budgets; ship build for the owner.

Exit gate: everything green locally; the owner loads his scans in the running app, splits one, exports
it, and accepts the seams and the status honesty **in-app**. His verdict — including a possible
tolerance-default recalibration — is recorded in the manifest justification. Only then merge.

---

## 13. Multi-agent execution guide

This spec will be driven through Codex `/goal` with a multi-agent workflow. This section is the
contract that keeps agents from colliding, façading, or self-grading.

### 13.1 Suggested /goal decomposition

One goal per milestone. Template:

> Read `docs/prd-partition-split-by-undercuts.md` — sections 2 (all rules), 3, and §12.M*n*
> only, plus the sections M*n* references. Implement milestone M*n* exactly. Obey the file-
> ownership map (§13.3). Tests first. Run the M*n* exit-gate command and paste its real output
> before claiming completion. Do not implement anything from later milestones or from §14.

Dependency order: **M0 ∥ M1** → M2 → **M3 ∥ M4** → M5. Do not start M2 until both M0 and M1
exit gates have pasted passing output on the branch. M5 is single-agent integration.

Respect the standing cost cap: **at most ~4 concurrent agents**; batch verification into one
agent rather than spawning a fleet of checkers.

### 13.2 Branch and repo discipline

- Branch `feat/partition-split-by-undercuts` off **`main`** (AGENTS.md naming). Never off
  `codex/mothermold-*`; those carry in-flight MotherMold work that owns every `Mold*` file.
- Draft PR on first push (AGENTS.md). Commit at least once per completed deliverable — agents
  have died mid-session before; the branch is the handoff medium, not the chat transcript.
- Each agent's first actions: `pwd`, `git branch --show-current`, `git status` — and verify the
  files you are about to edit exist in *this* checkout. A previous incident produced a "green
  build" by building an empty worktree while the code sat elsewhere. Build/test the checkout
  that contains your changes; paste the command output, not a summary of it.
- Canonical test invocation:
  ```
  swift test --package-path app/RefabArtist \
    --scratch-path /tmp/refabartist-swiftpm-undercut --filter '<milestone filter>'
  ```
  plus one unfiltered full-suite run before declaring a milestone done.

### 13.3 File-ownership map (merge-collision prevention)

| Workstream | Owns (create/edit) | Must not touch |
|---|---|---|
| M0 | `DirectionalAccessibilityAnalyzer.swift`, `UndercutRegionClusterer.swift`, `PullDirectionCandidates.swift`, `CanonicalPlane.swift`, `DirectionalAccessibilityTests.swift`, fixture generators, manifest | every `Mold*`/`MotherMold*` file; `Partition*.swift` |
| M1 | `PartitionCutTree.swift`, `SourceFaceMap.swift`, `UndercutSplit.swift` (settings), attributed additions to `PartitionGeometry.swift`, `purpose` field in `Partition.swift`, `PartitionCutTreeTests.swift` | existing `PartitionGeometry` entry points' behavior; `PartitionPlanner.swift` (Fit Printer logic); `Mold*` |
| M2 | `UndercutSplitPlanner.swift`, planner tests, fixture tests, minimal Generate-pipeline hookup in `ContentView.swift` | `PartitionPanel.swift`, exporters, `Mold*` |
| M3 | `PartitionPanel.swift` (purpose-conditional sections), `UndercutSplitOverlay.swift`, `ModelSceneView.swift` overlay additions | planner internals, exporters, `Mold*` |
| M4 | `PartitionExporter.swift` additions, `UndercutSplitReport.swift`, `HeadlessExportCommand.swift` additions, export tests | panel, planner internals, `Mold*` |
| M5 | manifest, docs, screenshots | new feature code |

Two agents never edit the same file concurrently. If a needed change falls in another
workstream's file, leave a `// M<n> TODO(owner)` note in your own file and surface it in the PR
description instead of editing across the boundary.

### 13.4 Known agent failure modes in this repo — do not repeat them

1. **Façade implementation.** Inflatables and Structures v1 shipped panels wired to nothing.
   Every deliverable here has a behavioral test; UI work (M3) is not done until the overlays
   show real measured regions on the real hand-scan fixture.
2. **Self-graded "verified."** Paste actual gate-command output. A summary sentence is not
   evidence. Final acceptance is the owner in-app (M5), full stop.
3. **Convex-only testing.** The real-scan gates (§11.3) exist because fixtures-pass-real-models-
   fail happened three times. Never mark M2 done on analytic fixtures alone.
4. **"Helpful" refactors of shared files.** R7 exists because MotherMold files are under active
   parallel development. Copy, don't refactor; dedup later.
5. **Silent scope growth.** §14 items are void. Re-adding certificates, exact verifiers, CCD
   engines, or export gates — even "just as an option" — is a review-blocking defect.
6. **Zeroed or cosmetic counts.** A prior workflow zeroed preflight counts to look clean and it
   was caught. Report every number honestly (R3, R4).

---

## 14. Explicitly out of scope (do not build, do not stub)

Void from v1 (some may return later with their own specs; none may be smuggled in):

- **Exact/complete DHF certificate verifier** (projected-arrangement proofs, tri-state
  certificates, proof digests). The measured analyzer at stated resolution is the decision
  signal.
- **Export gating of any kind** (R1 is permanent, not v1-scoped).
- **Freeform/volumetric solver** (tetrahedralization, graph-cut labeling, TetWild/GCO). Re-entry
  condition: measured evidence that tolerance-based planar splitting fails on the owner's real models
  at reasonable piece counts — recorded manifest numbers, not vibes. Separate spec, separate
  dependency review if that day comes.
- **Certificate/hash infrastructure:** generation-input canonical hash law, plan/export keys,
  Merkle assembly roots, content-addressed motion events, canonical-mesh quantization + ZIP
  re-parse revalidation, package-only vs. full-source revalidation scopes.
- **Continuous-collision assembly engine** (the half-space argument in §3.5 covers planar cuts).
- **New tapered-locator engine** (existing pins under the §3.5 axis rule suffice for v1).
- **Persona interviews, market validation, FTO/patent counsel gates, five-user usability
  panels, physical casting as a release gate.** The owner may cast when he likes; it gates nothing.
  (The v1 doc's patent research remains worth knowing about if Refab Artist is ever distributed
  commercially — that is a distribution decision, not an implementation task.)
- **Manual cut-tree CLI ingestion**, MotherMold one-click handoff (future integration ticket),
  "Prepare pieces for printing" chaining, support-free-FDM profile, open-face/pyramidal profile.

---

## 15. Verified repo cross-references

Ground truth verified 2026-07-11 on branch `codex/mothermold-v2` (line numbers drift; locate by
symbol):

- `ConstructionMode.partition` — `ConstructionMode.swift:10`; Partition is mesh-only.
- `PartitionSettings` — `Partition.swift:245`; `PartitionMode` (autoFit/manual) at `:185`;
  `manualPlanes: [PartitionPlane]` at `:254`. **No purpose concept exists yet.**
- Global plane replay to replace (for this purpose only): `PartitionPlanner.plan` at
  `PartitionPlanner.swift:76`, loop at `:93–101` splits every piece each plane crosses; flat
  `PartitionMeshPlan` (`:35`) — no hierarchy, no region IDs.
- Un-attributed clip path: `PartitionGeometry.clipHalfSpace` (`PartitionGeometry.swift:78`)
  takes/returns bare triangle soup — confirms the attributed-entry-point requirement (§5.3).
- Existing undercut math to copy-adapt: `MoldUndercutAnalyzer` (`MoldUndercutAnalyzer.swift:16`),
  `UndercutRegion` (`:18`), `analyze` (`:54`), `analyzeOnePart` (`:151`),
  `backdraftDotTolerance` (`:147`). Read-only per R7.
- Plane canonicalization precedent: `MoldPartitioner.canonicalizedPlanes`
  (`MoldPartitioner.swift:182–213`) — reimplement as `CanonicalPlane`, do not extract.
- Geometry kernel: `ManifoldEngine.splitByPlane` (`ManifoldEngine.swift:407`), `trimByPlane`
  (`:394`), `simplify` (`:370`), `volume` (`:455`), booleans, `minkowskiSum` (`:354`).
- Healing/preflight: `MeshManifoldRepair.userRepair` (`MeshManifoldRepair.swift:60`);
  `MeshPreflightReport` semantics per PR #271 (closed ≠ strict manifold) — the R4 foundation.
- Baselines: `PartitionTests.swift` = exactly 24 tests; 5 undercut-named tests across
  `MotherMoldTests.swift` and `MotherMoldGeometryContractTests.swift` (§11.1 lists them).
- Committed real-scan fixtures: `app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj`,
  `handStand_ex3_ui_healed.obj`, `open_hemisphere_mask.obj`.
- Canonical test invocation pattern: `swift test --package-path app/RefabArtist
  --scratch-path /tmp/… --filter '…'` (established in `docs/handoff-gpt55-structures.md`).
