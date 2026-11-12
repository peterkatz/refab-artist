# Refab Artist PRD: MotherMold Construction Type

## Status

Drafted 2026-06-27 from owner direction. **MotherMold is its own top-level
construction family** (not a sub-mode of Structures or Partition). It builds a
3D-printable mold around an arbitrary imported mesh, in 2-part or 4-part
construction, in one of two subtypes: a **silicone jacket** (rigid mother mold
that supports poured silicone) or a **slip-casting shell** (rigid mold whose
cavity conforms to the master).

Implementation revision 2026-07-10: `docs/mothermold-v2-decisions.md`
supersedes earlier open-face, key, socket-seal, Draft, and interface-count
wording in this historical PRD.

Like Structures and Partition, this is a mesh-only fabrication tool: Refab Artist
emits watertight printable solids (STL/OBJ) plus an assembly map. It does not do
laser-cut sheets, G-code, or printer/material profiles.

## One-line Summary

Add a mesh-only **MotherMold** construction type that wraps a watertight master
mesh in a rigid, wall-thickness-controlled mold split into 2 or 4 keyed,
flanged parts with measured demold checks - as either a smooth silicone-jacket mold (cavity
expanded and smoothed off the master by a silicone gap) or a conformal
rigid casting shell (cavity equals the master) - with optional floor, registration
keys, clamping flanges, a pour spout, and air vents, exported as separate STLs
with an assembly map.

## Product Intent

Make "I have a printed master and I want a mold of it" an in-app operation. The
two target workflows:

1. **Silicone jacket (mother mold).** The user pours/brushes silicone over the
   printed master; this rigid outer jacket holds the silicone's shape. The
   silicone fills the gap between the master surface and the jacket's inner
   surface, so the jacket cavity is **expanded outward from the master by a
   silicone gap and smoothed** — it does not need to follow fine detail (the
   silicone captures detail against the master).
2. **Rigid casting shell.** The printed mold *is* the working direct negative for
   compatible casting material, so the cavity must **conform exactly** to the
   master. No gap, no smoothing. The persisted `slipShell` identifier does not
   promise an absorbent ceramic slip-casting mold.

## Locked decisions (2026-06-27, from owner)

These are settled and must not be re-litigated during implementation:

1. **Own construction family.** `ConstructionMode.motherMold`, mesh-only
   (`isMeshOnly == true`), STL/OBJ export only. Not nested under Structures or
   Partition.
2. **Two subtypes:** `siliconeJacket` and `slipShell`, sharing one pipeline and
   differing in the cavity stage (offset+smooth vs. conformal) and in undercut
   policy (tolerant vs. enforced).
3. **Part counts:** 2-part (one parting plane) and 4-part (two orthogonal parting
   planes) for v1.
4. **Registration keys use the shared serialized key types** but MotherMold
   builds 8-degree Tapered round or Tapered bar Manifold boss/pocket pairs on
   completed physical interfaces. The Stacked **dowel** geometry is explicitly
   NOT used for mold keying.
5. **Floor is optional, default OFF.** Owner mostly will not use it.
6. **Wall thickness is user-controlled.** Single thickness parameter for the
   rigid mold wall; silicone gap is a separate parameter (silicone subtype only).
7. **Clamping is required, not just keying.** Keys align; flanges with bolt-hole
   bosses hold the parts shut against pour pressure.
8. **Pour spout + air vents are required** for both subtypes.

## Users

- Makers casting silicone molds from 3D-printed masters who need a rigid jacket.
- Ceramicists / slip-casters who want a printable conforming mold from a master.

## Non-goals (v1)

- No general boolean/CSG dependency for the core path; prefer the additive-cap
  and mitre-offset approach proven in Partition and `MeshModifier`. (Manifold is
  available and used only where a boolean is genuinely the right tool — spout/vent
  channels, flange bosses — see Engine Architecture.)
- No marching cubes / isosurface extraction for surface generation. (See Open
  Technical Risks for the silicone smooth-offset method and the pre-existing
  `MeshHealer` dependency.)
- No printer/material profiles, G-code, supports, brim/raft, thermal controls.
- No curved/freeform parting surfaces — parting is by flat plane(s) in v1.
- No laser-cut sheet export (no DXF/PDF/SVG/EPS).
- No multi-master molds, no core/insert molds, and no claimed draft-angle
  auto-correction. Legacy `draftAngle` data is read only for file compatibility.

## Scope

### Construction Family

- Label: **MotherMold**. Add `ConstructionMode.motherMold`; extend `isMeshOnly`
  to include it (it bypasses slice/contour/dowel/cut-sheet plumbing exactly like
  `.structures` and `.partition`).
- Export support: STL and OBJ only.
- Computation model: explicit **Generate** ("Build mold & preview"), off the main
  thread, cached by a settings hash — same pattern as Structures/Partition.
  Offsetting + splitting a dense master is heavy; never recompute live on a
  slider drag.
- Project persistence: all settings round-trip in Refab Artist project documents,
  following the `StructureSettings` Codable/migration pattern (optional fields
  with defaults).
- The mode hides controls that do not apply (no Manufacturing/material-thickness
  section, no Slice Direction section); MotherMold has its own parting controls.

### Pipeline (subtype-aware)

One ordered pipeline; the cavity and undercut stages branch on subtype.

1. **Validate input.** The master must be closed. Accept strict `MeshPreflight`
   output or a healer-grade closed mesh independently validated by Manifold;
   reject genuinely open/non-manifold input.
2. **Cavity surface.**
   - `slipShell`: cavity = the master surface, unchanged (conformal).
   - `siliconeJacket`: cavity = master offset **outward by the silicone gap and
     smoothed** (Minkowski-with-sphere; see Risks). Fine detail below the gap
     radius is intentionally rounded away.
3. **Shell.** Offset the cavity surface outward by the **wall thickness** into a
   solid wall (mitre-true thicken from `MeshModifier`, no MC). The inner face of
   the shell is the cavity; the outer face is the cavity + wall.
4. **Preserve the cavity.** Build a closed shell around the complete intended
   cast. Do not remove a cavity-sized open face. A controlled sacrificial fill
   gate is built after partitioning.
5. **Part the mold.** Split the shell into 2 (one plane) or 4 (two orthogonal
   planes) parts with the arbitrary-plane splitter (`PartitionGeometry` /
   PlaneSplitter). Parting plane(s) chosen Auto (widest silhouette / least
   undercut) or Manually aimed (reuse Slice-Direction-style viewport handles).
6. **Undercut check** (slip subtype enforced; silicone informational). Per part,
   ray-probe the cavity along the demold axis; flag re-entrant regions. For slip,
   either suggest more parts or warn that the part is not demoldable.
7. **Mating flanges + clamping.** Add two-sided flange plates and bolt holes on
   every physical part-pair interface so the parts clamp shut.
8. **Pour gate + vents.** Add one funnel and narrow through-channel owned by one
   part, plus air vents at high points. Auto placement avoids seams; manual seam
   placement is rejected without modifying geometry.
9. **Registration keys.** Build transactional 8-degree tapered male/female pairs
   on the completed interfaces after all intentional subtractive features, then
   verify requested pairs through the final geometry.
10. **Validate & export.** Per-part watertightness (`MeshPreflight`), finite
    coords, separate STLs (zip) / named-object OBJ / laid-out plate, plus an
    assembly map (`AssemblyGuideExporter`).

### Subtype differences (summary)

| Stage              | siliconeJacket                         | slipShell                  |
|--------------------|----------------------------------------|----------------------------|
| Cavity             | master + silicone gap, smoothed        | master (conformal, exact)  |
| Silicone gap param | enabled                                | disabled                   |
| Undercut policy    | informational (silicone flexes off)    | enforced (rigid demold)    |
| Detail capture     | by silicone against master             | by the mold cavity itself  |

### Parameters

```swift
struct MotherMoldSettings: Codable, Equatable {
    var subtype: MoldSubtype            // siliconeJacket | slipShell
    var parts: MoldPartCount            // two | four
    var wallThickness: Double           // mm, rigid mold wall
    var siliconeGap: Double             // mm, silicone subtype only (else ignored/disabled)
    var smoothing: Double               // mm, silicone smooth-offset radius (silicone only)
    var floor: Bool                     // default false
    var floorThickness: Double          // mm, when floor == true
    var parting: PartingSettings        // auto | manual + the plane set
    var key: PartitionKeySettings       // reuse Partition's key model
    var flange: FlangeSettings          // width, bolt-hole count/diameter
    var spout: SpoutSettings            // auto | manual, diameter; vent count/diameter
    var draftAngle: Double              // legacy decode compatibility only
    var packaging: MoldPackaging        // separateZip | combinedObj | laidOutPlate
    var includeAssemblyMap: Bool        // default true
    var seed: Int                       // deterministic placement
}

enum MoldSubtype: String, Codable { case siliconeJacket, slipShell }
enum MoldPartCount: String, Codable { case two, four }
```

The final shape may differ but must preserve these concepts in project files and
headless export, follow the `StructureSettings` migration pattern, and round-trip
through save/open. `PartitionKeySettings` is reused verbatim.

### Disabled / hidden controls (proactive)

Per the standing rule that a control cancelled out by another setting must be
disabled with a hint, not left dead:

- **Silicone gap** and **smoothing**: disabled (greyed, hinted) for `slipShell`.
- **Undercut check**: informational-only for `siliconeJacket`; enforced banner
  for `slipShell`.
- **Floor thickness**: disabled when **floor** is off.
- **Second parting plane** controls: hidden for 2-part.

## UI Requirements

Left progressive rail, top to bottom (matching Structures/Partition placement):

- **Mold Type**: subtype picker (silicone jacket / slip shell), 2-part / 4-part.
- **Shell**: wall thickness; silicone gap + smoothing (silicone only); floor
  toggle + floor thickness.
- **Parting**: Auto / Manual segmented control; Auto shows the chosen plane(s);
  Manual shows the plane list with "edit in viewport".
- **Keys**: key type (Tapered round / Tapered bar / None), size, tolerance, keys per interface,
  edge margin (reuse the Partition key panel).
- **Flanges & Clamping**: flange width, bolt-hole count, bolt diameter.
- **Spout & Vents**: auto/manual, spout diameter, vent count/diameter.
- **Fit / Warnings**: undercut report (slip), unkeyable seams, non-watertight
  parts.
- **Output**: packaging, assembly-map toggle.
- **Generate** ("Build mold & preview").

Viewport:

- Master shown semi-transparent inside the mold preview.
- Parting plane(s) as translucent rectangles with drag/rotate handles (Manual).
- Parts color-coded; a reversible Explode toggle and Parts isolation menu inspect
  seams, keys, flanges, fill gate, and vents without rebuilding.
- Undercut regions highlighted on the cavity (slip subtype).
- Settings changes mark the result stale; export disabled/warns until Generate.

## Engine Architecture

Mirror the Structures/Partition file split:

1. **MotherMoldPlanner** — accepts master `MeshSummary`, `MotherMoldSettings`,
   seed; orchestrates the pipeline; returns a deterministic `MotherMoldPlan`.
2. **MoldCavityBuilder** — subtype cavity surface: conformal (passthrough) or
   smooth outward offset (Minkowski-with-sphere via `ManifoldEngine`).
3. **MoldShellBuilder** — mitre-true outward thicken of the cavity into a walled
   solid (reuse `MeshModifier`); floor cap when enabled.
4. **MoldPartitioner** — parting-plane resolution (auto silhouette/least-undercut
   or manual) + arbitrary-plane split into 2/4 parts (reuse `PartitionGeometry`
   PlaneSplitter and capping).
5. **MoldUndercutAnalyzer** — per-part ray-probe along demold axis (reuse the
   Möller–Trumbore probe in `PartitionKeys.rayFirstHit`); reports re-entrant
   regions; enforced for slip.
6. **MoldKeyBuilder** — wrap `PartitionKeys.capInterface` for the seams.
7. **MoldFlangeBuilder** — flange rims + bolt-hole bosses along seams.
8. **MoldFeatureBuilder** — spout/reservoir + vent channels (this is where a
   Manifold boolean difference is the right tool for clean cylindrical bores).
9. **MoldValidation** — per-part `MeshPreflight.isWatertight`, finite coords,
   undercut/keyability summary.
10. **MotherMoldExporter** — separate STLs (`ZipWriter`), named-object OBJ,
    laid-out plate, assembly map (`AssemblyGuideExporter`).

### Reuse map (do not reinvent)

- Registration keys: `PartitionKeys.swift` (pin + dovetail, ray-probed, fallback).
- Arbitrary-plane split + island-aware cap: `PartitionGeometry` / PlaneSplitter.
- Shell / offset / thicken (no MC): `MeshModifier.swift`.
- Smooth outward offset (silicone): `ManifoldEngine` Minkowski sum (needs Swift
  wrapper around `manifold_minkowski_sum`).
- Spout/vent bores & flange bosses: `ManifoldEngine` difference/union.
- Watertight facts / healing: `MeshPreflight.swift`, `MeshHealer.swift`.
- Mesh model / bounds / scale: `MeshInspector.swift`, `MeshScaler.swift`.
- Export: `StlExporter.swift`, `ObjExporter.swift`, `ZipWriter.swift`,
  `AssemblyGuideExporter`.
- Construction-mode scaffold (Generate/stale/off-main, panel hiding, mesh-only
  export gating): `.partition` / `.structures` end-to-end, `ConstructionMode`
  `isMeshOnly`.

## Suggested Implementation Order

Each step leaves the app building and shippable.

1. Add `ConstructionMode.motherMold` + `isMeshOnly`, restrict export to STL/OBJ,
   add `MotherMoldSettings` persistence + stale/Generate state, inspector
   skeleton, empty preview. Hide Manufacturing + Slice Direction.
2. **Slip shell, 2-part, no keys, floor optional.** Conformal cavity →
   `MeshModifier` thicken → open base → single-plane split → cap → STL/OBJ/zip.
   This is the smallest fully-useful mold and needs no Minkowski and no booleans.
3. Registration keys via `PartitionKeys` at the seam; tolerance + fallback.
4. Flanges + bolt-hole bosses; 4-part (two-plane) split.
5. Undercut analyzer (slip enforced) + parting auto-selection + manual viewport
   plane handles + exploded view.
6. Spout + vents (Manifold bores).
7. **Silicone jacket subtype:** Minkowski smooth outward offset cavity + silicone
   gap/smoothing controls + subtype-aware disabling.
8. Headless CLI flags, tests, visual evidence, and artist-facing failure recovery.

## Acceptance Criteria

Functional:

- Import STL/OBJ master, choose MotherMold, pick subtype + part count, set wall
  thickness, Generate, preview parts, export.
- Slip shell cavity conforms to the master; silicone jacket cavity is expanded by
  the gap and visibly smoothed.
- 2-part and 4-part splits produce parts with measured demold evidence; rigid
  output with unresolved undercuts or extraction collision is inspection-only.
- Every requested tapered key pair survives final geometry or export is blocked.
- Flanges with bolt holes present; parts clamp conceptually (holes align).
- Spout and vents present and connected to the cavity.
- Floor present only when enabled.
- Project save/open and headless export reproduce identical output; deterministic
  from seed.

Geometry:

- Every exported part watertight (`MeshPreflight.isWatertight`), finite coords.
- Male/female key footprints differ only by tolerance; a printed pair fits.
- For slip shell, the cavity matches the master within tolerance; the assembled
  parts reconstruct the full mold volume with no dropped/duplicated regions.
- For slip shell, flagged undercut regions are genuinely re-entrant along the
  demold axis (verified on a concave organic master, not just convex fixtures).
- No marching cubes in cavity/shell/key/flange generation. (Document the one
  permitted MC dependency: `MeshHealer` watertighting of dirty input, pending
  owner decision on an MC-free healer.)

UX:

- No laser-cut export path appears for MotherMold.
- No expensive recompute until Generate; stale results visibly marked.
- Dead/irrelevant controls are disabled with hints, not left live.
- Dense masters build off the main thread without freezing.

Tests:

- `swift test --package-path app/RefabArtist`.
- `ConstructionMode` + `ExportFormatSupport` cover `.motherMold`.
- `MotherMoldSettings` Codable + project round-trip.
- Shell builder on cube/sphere/concave organic: watertight wall of correct
  thickness.
- Split into 2 and 4 parts: watertight, capped, volume conserved within tol.
- Key pair footprint differs by exactly tolerance; thin seam falls back + warns.
- Undercut analyzer flags a known re-entrant concave master and passes a convex
  one (defeats the convex-fixture blind spot).
- Silicone offset: cavity is strictly outside the master by ~gap and smoother
  (curvature bounded by the smoothing radius).
- Packaging: zip has one STL per part; OBJ one object per part.
- Visual evidence: render both subtypes of one organic master, exploded, showing
  cavity/keys/flanges/spout/vents.

## Open Technical Risks

- **Silicone smooth-offset method (owner sign-off needed).** Proposed non-MC
  method is Manifold Minkowski-sum with a sphere (rounds convex edges to the ball
  radius, fills sub-radius crevices = the desired smoothing). Cost: Minkowski on
  a dense mesh is expensive (convex-decompose + hull + union); mitigate by
  decimating the master for the jacket cavity (the jacket needs no fine detail)
  before the sum. If Minkowski proves too slow/fragile, the fallback options each
  have a cost the owner should weigh, but **no MC without explicit approval**.
- **MeshHealer uses MC.** A mold needs watertight input. Healing dirty masters
  currently goes through GWN+marching-cubes. Either require pre-healed input,
  gate healing behind a warning, or scope an MC-free healer — owner decision.
- **Undercut on concave organics is the historical blind spot.** Test undercut
  detection and capping on genuinely concave sections, never just convex
  fixtures.
- **Parting-plane auto-selection** (widest silhouette / least undercut) is a
  heuristic; manual aim must always be available as the escape hatch.
- **Spout/vent placement** auto-heuristic ("topmost cavity region") must handle
  arbitrary orientation; manual override required.

## References

- Partition PRD + handoff: `docs/prd-partition-construction-mode.md`,
  `docs/handoff-partition-construction-mode.md`.
- Key geometry: `PartitionKeys.swift` (worktree `neo/partition-construction-mode`).
- Shell/offset: `app/RefabArtist/Sources/RefabArtist/MeshModifier.swift`.
- Boolean backend: `app/RefabArtist/Sources/RefabArtist/ManifoldEngine.swift`.
- Construction-mode scaffold: `docs/prd-structures-construction-mode.md`.
