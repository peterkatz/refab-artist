# Refab Artist MotherMold: Prepared Master and Reusable Tooling Specification

Status: ratified implementation contract

Date: 2026-07-10

Scope: silicone-jacket MotherMold for ambient, gravity-fed solid casting in
silicone (for example compatible resin or plaster). Pressure, vacuum-pressure,
rotational, slush, and ceramic slip casting require separate process contracts.
The rigid casting-shell subtype keeps its current direct-negative semantics and
does not use a retained master or a reusable silicone liner.

This document extends, and where explicitly stated supersedes, the master-mount
and export wording in:

- `docs/prd-mothermold-construction-mode.md`
- `docs/plan-mothermold-artist-usability-v3.md`
- `docs/mothermold-v2-decisions.md`

The owner ratified the section 5 decisions by authorizing implementation. They
are recorded as D16-D25 in `docs/mothermold-v2-decisions.md`. This document is
the normative contract for reusable silicone-jacket tooling. It does not change
the rigid casting-shell subtype's direct-negative workflow or supersede that
subtype's controlled-gate requirements.

## 1. Executive decision

A reusable silicone-jacket tool is not only a set of rigid mold parts. It is a
tooling system whose source state and artifact classes are explicit:

1. the untouched imported source file plus the exact active/healed source
   geometry used for planning, neither of which Refab Artist overwrites;
2. an optional **prepared master**, derived from the source and carrying a
   positive mechanical anchor and sacrificial casting-gate post;
3. the rigid, multi-part mother shell and its standard hardware;
4. phase-specific hold-down, vent, funnel, and support accessories; and
5. the as-poured and trimmed production silicone-liner references, including
   deliberate registration bosses that reseat it in the rigid shell after the
   master is removed.

For new silicone-jacket projects, the recommended automatic workflow is:

- derive and export a topology-valid prepared-master manufacturing mesh, with
  printer-profile fit status when a profile is active;
- add a rounded, non-circular anchor post at a verified sacrificial base patch;
- capture that post in a split shell collar and lock it against lift with a
  standard cross-pin and a printed load-spreading yoke;
- use the post root as the production casting gate after the master is removed;
- replace the removed yoke with a drafted casting-funnel insert that seats in
  the same collar receiver;
- form any required production air vents with individually removable rods
  located by the prepared master and shell, independently of the one-time
  liner-fill vents;
- verify separate stable working orientations for the liner pour and every
  production cast, generating support cradles when the shell cannot stand safely;
- generate drafted silicone registration buttons plus a captured gate lip so
  the cured liner repeatedly returns to the same shell position; and
- export one self-describing manufacturing ZIP containing every manufacturing
  tooling part, hardware schedule, manifest, and assembly/reuse guide.

The existing generated base socket remains available for an existing physical
master that must not be modified. It is relabeled as a locator, not a positive
hold-down. External fixture remains the advanced escape hatch.

## 2. Why this is required

MotherMold v2 now proves that the rigid shell parts are watertight, disjoint,
keyed, flanged, bored, vented, and exportable. It also proves retention of the
generated base socket. That is necessary but not sufficient for reusable
tooling:

- The socket seats the master but does not necessarily prevent a light or
  hollow master from lifting under silicone buoyancy.
- The current tapered keys register rigid shell parts to each other. They do
  not register the cured silicone liner to the rigid shell.
- The current plan and exporter carry the source master only as preview data.
  They cannot emit the modified positive or fixture manufacturing meshes.
- The current `Spout` name conflates the one-time path used to create the liner
  with the opening used for every later production casting.
- The current vents release air while silicone fills around the positive. They
  do not automatically vent the negative cavity during later resin or plaster
  casting.
- A conformal liner exterior may seat approximately in an organic shell, but
  the product does not currently measure or guarantee repeatable liner seating.

This is a product-level tooling omission, not a defect in the hand fixture.

## 3. Evidence from established workflows

The design follows recurring practices rather than inventing a novel shop
process:

- Polytek's poured blanket-mold workflow secures the model to a baseboard with a
  screw or epoxy, models the future silicone space with clay, removes and then
  accurately repositions the rigid shell using reference marks and drilled
  holes, screws and seals the shell to the baseboard, pours the rubber, removes
  the master, and places the cured rubber back in the shell for casting.
  https://polytek.com/tutorial/mold-making-poured-blanket-mold-vs-poured-block-mold
- Polytek separately demonstrates a notch between a flexible rubber mold and
  its support nest so those two elements align on every reuse.
  https://polytek.com/tutorial/how-make-rubber-glove-or-sock-mold
- Polytek's brush-on workflow deliberately casts rubber pieces for the parting
  line and keys before constructing the support shell.
  https://polytek.com/how-to/video/how-make-brush-mold-mold-shell-part-i
- Carnegie Mellon's documented silicone procedure raises and secures a master
  with a screw attached to a baseplate and warns that an unsecured master can
  separate during the pour.
  https://www.cs.cmu.edu/~rapidproto/manufacturing/molds/silicone.html
- Smooth-On distinguishes the flexible mold from its rigid support shell and
  uses positive/negative keys and external straps or clamps for repeat assembly.
  https://www.smooth-on.com/assets/pdf/Smoothon_HTB_2008.pdf
- Formlabs separates alignment features that constrain an embedded object from
  registration features that mate mold blocks, and recommends orienting
  alignment features with the draw direction.
  https://formlabs.com/uk/blog/casting-silicone-guide/
- Shape Cast validates an artist-facing workflow that exports all required
  inner, outer, and bottom-ring tooling pieces, uses bolts/inserts, and presents
  a design proof before fabrication.
  https://inovo.studio/pubs/shapecast-chi24.pdf
- MoldBoxer exposes a fast automatic path and a manual confirmation path for
  box, inlet, and channel correction. Refab Artist should retain the same
  automation-first/manual-recovery principle without copying its UI.
  https://moldboxer.com/download/linux

The combined anchor-and-production-gate design below is a Refab Artist product
inference from these practices: use one artist-approved sacrificial base region
for both positive hold-down and the later casting opening when geometry permits.

## 4. Terminology

The UI, plan, manifest, guide, and tests must use these terms consistently.

| Term | Meaning |
| --- | --- |
| Imported source file | Original bytes selected by the artist. Never overwritten; may be non-moldable. |
| Active source master | Exact immutable geometry accepted by the MotherMold entry gate, including an explicitly healed form when applicable. |
| Prepared master | Derived positive manufacturing mesh with declared fixture/gate geometry. |
| Master anchor | Geometry and hardware that restrain the prepared or physical master during liner creation. |
| Anchor post | Sacrificial positive geometry joined to the prepared master. |
| Anchor collar | Split rigid-shell feature that locates and seals around the post. |
| Hold-down yoke | Separate printed part that spreads cross-pin load over the collar. |
| Casting funnel insert | Separate drafted pour cup that replaces the yoke after liner cure and feeds the production gate. |
| Silicone liner | Flexible negative poured between master and mother shell. Not normally printed. |
| Liner registration | Features that repeatedly locate the cured liner in the rigid shell. |
| Shell registration | Existing tapered boss/pocket pairs between rigid shell parts. |
| Liner fill port | One-time path used to pour silicone around the master. |
| Production casting gate | Opening into the empty silicone negative used for every later cast. |
| Production casting vent | Reusable air path from a casting-cavity high region to the exterior. |
| Liner-fill orientation | Supported assembly orientation used while silicone is poured around the positive. |
| Casting orientation | Supported assembly orientation used for repeated production casts. It may differ from liner fill. |
| Modification region | Typed, visible area where the prepared master intentionally differs from the active source. |
| As-poured liner | Expected silicone geometry before one-time fill and vent nubs are trimmed. |
| Production liner | Expected reusable silicone geometry after the prescribed trimming operation. |
| Seal land | Accessible surface where compatible sealant is applied before the liner pour. |
| Expected liner | Computed reference solid used for preview and validation. |

The interface must not use `key` without a qualifier where ambiguity is
possible. Use `Shell keys` and `Liner registration`.

## 5. Ratified product decisions

These decisions are recorded as D16-D25 in
`docs/mothermold-v2-decisions.md` and govern this implementation.

### P1. Source geometry is immutable

Refab Artist never edits or overwrites the imported file or the active source
snapshot. Every tooling change is a derived `Prepared master` artifact. Imported,
active, and prepared states are separately named; active and prepared geometry
are separately visible, measured, persisted, and hashed.

### P2. A prepared master is a first-class manufacturing output

If any positive fixture, gate, alignment, or repair geometry is applied, the
exact final prepared master is included in the manufacturing package and passes
the same serialized topology gate as mold parts.

### P3. New digital-master jacket projects default to mechanical retention

`Prepared master - keyed post` is the recommended default for a master that the
artist intends to print. It must constrain translation and rotation and must
include a positive anti-lift mechanism. A friction fit or sealant alone is not
described as a hold-down.

### P4. Existing physical masters remain supported

An artist can choose:

- `Generated socket (locator only)` for a heavy/stable physical original;
- `External fixture` for a stem, suspension, baseboard, or custom support.

Neither path silently creates or exports a modified master.

### P5. Liner registration is distinct and default-on

New jacket builds generate measured liner-to-shell registration. Disabling it
is an advanced, explicit choice recorded in the guide and manifest. Shell keys
do not satisfy this requirement.

### P6. Liner creation and production casting have separate flow contracts

The plan independently proves:

1. an exterior-to-liner-volume silicone fill path plus requested air vents; and
2. an exterior-to-casting-cavity production gate plus every required casting
   air vent after the prepared master is removed.

The UI and guide never call both simply `Spout`.

### P7. Manufacturing export is a tooling package

The default jacket output is `Manufacturing ZIP`, not an unlabeled collection
of shell meshes. The package contains every required manufacturing part and a
machine-readable manifest. A modified prepared master is never merged into a
laid-out shell STL.

### P8. No silent geometry fallback

If the post, collar, yoke, liner keys, gate, or requested shell hardware cannot
be built and measured, Refab Artist keeps the failed plan inspectable and blocks
manufacturing export with a plain-language recovery action.

No art-surface modification is approved merely because Auto calls it
low-visibility. Auto may generate the complete proposal, but manufacturing
export requires one explicit approval of the highlighted, measured modification
set.

### P9. Reuse claims require physical evidence

Software geometry gates are necessary but cannot establish leakage, silicone
tear life, or printed-material strength. Refab Artist must pass the physical reuse
matrix in section 18 before the feature is described as production-ready.

### P10. Working orientation and support are explicit

Liner filling and production casting have separate gravity vectors, stability
checks, and air-path analyses. If the assembled tool does not have a measured
stable support polygon in either orientation, Refab Artist generates and exports a
phase-labeled cradle or blocks with a concrete support action.

## 6. Supported workflows

### 6.1 Print a prepared master (recommended)

Use when the imported mesh is the digital source for a new printed positive.

1. Refab Artist proposes a sacrificial mounting patch and shows the modification.
2. The artist accepts Auto or selects a patch manually.
3. Refab Artist derives a watertight prepared master with an anchor/gate post.
4. Refab Artist builds a split collar, seal land, yoke, casting-funnel insert,
   removable production-vent rods and locators, liner registration, shell,
   liner-fill port/vents, flanges, bolts, shell keys, and any required support
   cradle.
5. The manufacturing ZIP includes the prepared master, yoke, and casting-funnel
   insert in addition to the shell parts.

### 6.2 Use an existing physical master without modification

Use when artwork cannot be drilled, glued, or reprinted.

1. Choose `Existing physical master`.
2. Choose `Generated socket (locator only)` or `External fixture`.
3. Socket mode measures seating footprint and seal land, but the status states
   that lift restraint remains the artist's responsibility unless measured
   mass/center-of-gravity/uplift/tipping gates prove the locator sufficient.
4. External mode accepts modeled fixture geometry or explicit attachment datums,
   restrained directions, and tested/declared capacity. Refab Artist checks
   collision, release, and required capacity and records any remaining external
   responsibility in the guide/manifest. A text label with no fixture evidence
   cannot become a positive production case.

### 6.3 First-time liner fabrication

For a prepared master:

1. Print and finish the prepared master, mold parts, and hold-down yoke.
2. Apply compatible release to the master and shell as required by the selected
   silicone system.
3. Assemble the shell around the post, seat shell keys, and tighten shell bolts.
4. Apply compatible sealant continuously at the anchor collar seal land.
5. Slide the yoke over the post and insert the specified cross-pin/bolt.
6. Install every labeled production-vent rod between its prepared-master landing
   and shell sleeve; seal the temporary rod/master joints as directed.
7. Place the assembly in its verified `LINER FILL` support orientation and
   verify the master cannot slide, rotate, tip, or lift.
8. Pour silicone through `LINER FILL`; stop when it reaches every liner vent.
9. Cure fully. Pull each production-vent rod outward through its sleeve, then
   remove the cross-pin/yoke, open the shell, and remove the unbranched prepared
   master from the liner in the documented sequence.
10. Trim only the highlighted one-time liner-fill nubs at the generated trim
    guides. Preserve the production gate, production-vent channels, liner
    registration, and funnel sealing bead.

### 6.4 Repeated casting

The source/prepared master is absent.

1. Inspect and clean the trimmed production liner.
2. Seat every liner registration button and the gate lip in the matching shell.
3. Close the shell using shell keys and bolts.
4. Place the assembly in its verified `CASTING` support orientation. Seat and
   cross-pin the casting-funnel insert in the collar receiver; verify
   its silicone sealing bead is evenly compressed and every labeled production
   vent is open.
5. Pour compatible casting material through `CAST HERE`; stop or manage vent
   overflow as directed for the selected material.
6. Cure, remove the funnel cross-pin and release the insert from its receiver,
   open the shell, release the flexible liner, and demold the casting; the
   drafted funnel may remain on the gate sprue until the casting is free.
7. Trim gate/vent sprues, clean, reseat, and repeat.

### 6.5 Remaking a worn liner

Reprint or reuse the prepared master, repeat the first-time liner workflow, and
replace only the liner. The original source mesh is not regenerated or altered.

## 7. User experience specification

### 7.1 Inspector organization

For `Silicone jacket`, add a `Master & Reuse` section immediately after mold
type/clearance and before parting.

Basic controls:

1. `Master source`
   - `Print prepared master` (recommended for new digital projects)
   - `Existing physical master`
2. `Hold-down`
   - Prepared source: `Keyed post + cross-pin`
   - Existing source: `Generated socket (locator only)` or `External fixture`
3. `Mount placement`
   - `Auto`
   - `Pick on model`
4. `Liner registration`
   - `Auto` (default)
   - `None` (advanced; explicit warning)
5. `Casting flow`
   - `Auto gate + vents` (default)
   - `Place manually`
6. `Working supports`
   - `Auto` (use a measured stable shell base or generate phase cradles)
   - `Place manually`
7. Optional `Master weight`, center of gravity, and `Silicone density` for
   restraint/stability guidance.

Advanced disclosure:

- production gate diameter;
- liner-fill orientation, casting orientation, support margin, and
  production-vent diameter;
- post width/thickness and cross-pin diameter;
- mount clearance and seal-land width;
- liner buttons per mold part, diameter, depth, and draft;
- gate-lip enable/size;
- include reference meshes in ZIP.

Every visible control has concise hover help. Controls that do not affect the
selected source/hold-down mode are hidden or disabled with a reason.

### 7.2 Automatic-first behavior

Auto performs a bounded candidate search and produces one recommended result.
It does not open a wizard. The selected patch and prepared-master change are
immediately visible in the viewport. Manual recovery is one command: `Pick
mount area`.

Auto may proceed without an acknowledgement dialog only when all mount gates
pass. Build Status must still name the modified area and dimensions. A low
confidence or destructive candidate blocks with actions to pick another patch,
reorient, use an existing master, or choose an external fixture.

Auto previews all proposed anchor/gate/vent landing marks immediately. Before a
v3 prepared-master package can be exported, the artist presses one clear
`Approve prepared-master changes` command. The confirmation lists every typed
region, area, location, and purpose and can be revoked by changing any relevant
setting. There is no confirmation loop for geometry that makes no art-surface
change.

### 7.3 Viewport modes

Keep the existing reversible Explode behavior. Replace the ambiguous
Master/Mold/Both preview with:

- segmented view: `Master`, `Mold`, `Assembly`;
- a Layers menu containing `Active source`, `Imported reference` when distinct,
  `Prepared master`, `As-poured liner`, `Production liner`, `Mold parts`, `Mount
  hardware`, `Support cradles`, and `Flow paths`.

Defaults:

- Master view: prepared master opaque, active source as optional wire/ghost;
  imported raw reference is separately identified when it differs.
- Mold view: colored shell parts; liner references hidden.
- Assembly view defaults to the phase-correct state: prepared master + translucent
  as-poured liner for `LINER FILL`, or production liner + funnel for `CASTING`.
- Explode: prepared master remains fixed; shell parts move along their demold
  axes; yoke/funnel/vent rods/cradles follow their phase removal or support
  directions; either liner state can remain fixed or be isolated.

Original and prepared masters use visibly different colors. The legend names
them; it never labels both `Master`.

### 7.4 Build Status

The collapsed artist summary reports separate rows:

- `Prepared master`: topology valid / printer-profile validated / not required /
  needs attention.
- `Master hold-down`: post/cross-pin verified, socket locator only, or external.
- `Estimated uplift`: worst-case or mass-adjusted force and recommended minimum
  restraint force.
- `Fixture wrench`: worst fill-state axial force, shear, bending, and torsion
  summarized as qualified/unqualified utilization.
- `Hold-down capacity`: six-degree-of-freedom motion result and selected-profile
  combined-force/moment status (`qualified`, `geometry only`, or `external`).
- `Working supports`: liner-fill and casting orientations, support margin, and
  generated cradle count, with worst empty-to-full mass state and cradle-load
  qualification.
- `Liner registration`: exact button count and gate lip.
- `Liner fill`: fill port and vent count.
- `Production casting`: casting gate, funnel insert, orientation, and exact
  required/placed vent count.
- existing shell part, key, flange, bolt, watertight, and material rows.
- `Export package`: exact manufacturing and reference artifact counts.
- `Prepared-master changes`: approved / approval required, with changed area.

Internal topology numbers remain under Build details. Artist-facing errors name
what failed, why it matters, and the next action.

The header uses two independent states so export availability is not confused
with physical process qualification:

- `Package blocked`: a required artifact/geometry/approval contract is red;
- `Package ready - geometry only`: export is valid, but printer fit, load, process,
  or external fixture remains unqualified;
- `Package ready - printer validated`: every manufacturing mesh fits the active
  profile, while bench setup checks remain in the guide;
- `Production profile qualified`: software and the versioned physical profile
  evidence are green for the declared gravity process.

The app never says simply `Ready to pour`; the artist must still perform the
phase setup and pre-pour checks on the real printed tool. A geometry-only package
may be exported for prototyping, but warnings remain in the README, guide, and
manifest rather than disappearing when the Export button enables.

### 7.5 Export interaction

The Export section previews package contents before opening the save panel:

`7 + N manufacturing meshes: 4 mold parts, 1 prepared master, 1 hold-down yoke,
1 casting funnel, N production-vent rods; plus 0-2 support cradles, 1 guide,
and 1 manifest.`

For prepared-master builds:

- `Manufacturing ZIP` is selected and required.
- Combined OBJ is available only as `Reference OBJ` and is inspection-only.
- Laid-out single STL is disabled because it erases artifact roles and mixes
  tooling that requires independent orientation/material decisions.

## 8. Settings and persistence contract

Extend, do not replace, `MasterMountSettings`. For each required v3 field, first
check `container.contains(key)`: only an absent legacy key receives its migration
default; a present key uses strict `decode` and rejects null, wrong types, and
unknown enum values. Explicitly optional fields may decode null.

```swift
enum MasterSourceMode: String, Codable, Sendable {
    case preparedPrint
    case existingPhysical
}

enum MasterRetentionMode: String, Codable, Sendable {
    case preparedPost
    case flatBaseSocket       // retained raw value
    case externalFixture      // retained raw value
}

enum MountPlacementMode: String, Codable, Sendable {
    case auto
    case manual
}

enum LinerRegistrationMode: String, Codable, Sendable {
    case automatic
    case buttons
    case buttonsAndGateLip
    case none
}

enum ProductionFlowMode: String, Codable, Sendable {
    case automatic
    case manual
}

enum CastingProcessProfile: String, Codable, Sendable {
    case gravityResin
    case gravityPlaster
    case customGravity
}

enum ToolingSupportMode: String, Codable, Sendable {
    case automatic
    case manual
}

// Add without changing the existing raw values.
enum MoldPackaging: String, Codable, Sendable {
    case manufacturingZip
    case separateZip
    case combinedObj
    case laidOutPlate
}

struct MasterPreparationSettings: Codable, Equatable, Sendable {
    var sourceMode: MasterSourceMode
    var retentionMode: MasterRetentionMode
    var placementMode: MountPlacementMode
    var manualPoint: Vec3Codable?
    var manualAxis: Vec3Codable?
    var linerFillUpAxis: Vec3Codable?
    var postWidth: Double
    var postThickness: Double
    var postFreeLength: Double
    var crossPinDiameter: Double
    var fitClearance: Double
    var sealLandWidth: Double
    var masterWeightGrams: Double?
    var masterCenterOfGravity: Vec3Codable?
}

struct LinerRegistrationSettings: Codable, Equatable, Sendable {
    var mode: LinerRegistrationMode
    var buttonsPerPart: Int
    var buttonDiameter: Double
    var buttonDepth: Double
    var buttonDraftDegrees: Double
    var gateLipEnabled: Bool
    var gateLipDepth: Double
}

struct ProductionFlowSettings: Codable, Equatable, Sendable {
    var mode: ProductionFlowMode
    var processProfile: CastingProcessProfile
    var castingUpAxis: Vec3Codable?
    var gateDiameter: Double
    var ventDiameter: Double
    var manualGatePoint: Vec3Codable?
    var manualVentPoints: [Vec3Codable]
}

struct SupportPlaneSettings: Codable, Equatable, Sendable {
    var origin: Vec3Codable
    var normal: Vec3Codable
}

struct ToolingSupportSettings: Codable, Equatable, Sendable {
    var mode: ToolingSupportMode
    var minimumSupportMargin: Double
    var manualLinerFillSupportPlane: SupportPlaneSettings?
    var manualCastingSupportPlane: SupportPlaneSettings?
}

struct MoldMaterialSettings: Codable, Equatable, Sendable {
    var siliconeDensityGramsPerCC: Double
    var castingDensityGramsPerCC: Double?
    var upliftSafetyFactor: Double
}

struct ToolingManufacturingProfileRef: Codable, Equatable, Sendable {
    var printerProfileID: String
    var materialProfileID: String
    var profileSnapshotSHA256: String
}
```

`MotherMoldSettings` adds:

```swift
var masterPreparation: MasterPreparationSettings
var linerRegistration: LinerRegistrationSettings
var productionFlow: ProductionFlowSettings
var toolingSupport: ToolingSupportSettings
var material: MoldMaterialSettings
var manufacturingProfile: ToolingManufacturingProfileRef?
var includeReferenceMeshes: Bool
var approvedModificationSignature: String?
var toolingContractVersion: Int
```

### 8.1 Migration

- Existing documents that contain `flatBaseSocket` or `externalFixture` retain
  identical geometry and export semantics.
- A document without `toolingContractVersion` decodes as version 2 with liner
  registration off. It displays `Legacy jacket: liner registration was not
  generated` and offers `Upgrade and rebuild`.
- Upgrading is explicit because it changes shell geometry and export contents.
- New jacket projects use contract version 3, prepared master, automatic liner
  registration, and Manufacturing ZIP.
- Rigid casting-shell projects ignore these settings and preserve current
  output hashes.
- Existing serialized raw values and accepted CLI aliases, including
  `slipShell`, `siliconeJacket`, `pins`, `dovetail`, `separateZip`,
  `flatBaseSocket`, and `externalFixture`, remain decodable for their existing
  contracts; strict decoding rejects unknown values without renaming known ones.
- Project open must begin checking the document version instead of relying only
  on permissive nested decoders. Unknown enum raw values and unsupported future
  contract versions produce an explicit compatibility error; they do not
  silently become defaults.
- Custom decoding distinguishes a missing legacy key from a malformed present
  value. A migration default is supplied only when `container.contains(key)` is
  false. Present nulls for required fields, unknown enums, and wrong types throw;
  only explicitly optional fields accept null. Existing `try?` enum decoding is
  not permitted in the v3 path.

## 9. Plan and artifact model

Add explicit artifact roles rather than overloading `MotherMoldPart`.

```swift
enum ToolingArtifactRole: String, Codable, Sendable {
    case moldPart
    case preparedMaster
    case holdDownYoke
    case castingFunnel
    case productionVentFormer
    case supportCradle
    case fixturePart
    case referenceImportedSource
    case referenceActiveSource
    case referenceAsPouredLiner
    case referenceProductionLiner
    case referenceAssembly
}

enum ManufacturingQualification: String, Codable, Sendable {
    case topologyValid
    case printerProfileValidated
    case referenceOnly
}

struct ToolingArtifact: Equatable {
    var name: String
    var role: ToolingArtifactRole
    var geometry: MeshGeometryData
    var qualification: ManufacturingQualification
    var materialHint: String?
    var quantity: Int
    var assembledTransform: Matrix4x4Codable
    var recommendedPrintTransform: Matrix4x4Codable?
}

enum PackageMemberContent: String, Codable, Sendable {
    case geometry
    case text
    case csv
    case svg
    case sourceBytes
}

enum PackageMemberRole: String, Codable, Sendable {
    case assemblyGuide
    case hardwareSchedule
    case toolingGeometry
    case sourceProvenance
    case referenceGeometry
}

struct PackageMember: Equatable {
    var path: String
    var role: PackageMemberRole
    var toolingRole: ToolingArtifactRole?
    var mediaType: String
    var content: PackageMemberContent
    var byteCount: UInt64
    var sha256: String
    var geometryMetrics: SerializedGeometryMetrics?
    var sourceDependencyStatus: String?
}
```

`ToolingArtifact` is only for geometry. `PackageMember` is the manifest/archive
envelope for every non-manifest geometry, README, CSV, and raw provenance member.
Text and source members do not receive fake triangle, volume, or watertight
fields. `manifest.json` cannot hash itself; its hash/byte count live in headless
measurement and canonical evidence outside the manifest member list.

```swift
enum MasterModificationKind: String, Codable, Sendable {
    case anchorAndGateRoot
    case separateGateRoot
    case productionVentLanding
    case approvedRepair
}

struct MasterModificationRegion: Equatable {
    var id: String
    var kind: MasterModificationKind
    var center: Vec3Codable
    var surfaceArea: Double
    var boundary: [Vec3Codable]
    var purpose: String
}
```

The sorted region list plus source/settings hashes produces the approval
signature. Any region, dimension, point, axis, source, or process change clears
approval.

Extend `MotherMoldPlan` with:

```swift
var sourceMaster: MeshGeometryData
var preparedMaster: ToolingArtifact?
var fixtureArtifacts: [ToolingArtifact]
var asPouredLiner: MeshGeometryData?
var productionLiner: MeshGeometryData?
var modificationRegions: [MasterModificationRegion]
var masterPreparation: MasterPreparationSummary
var holdDownWrenchEnvelope: HoldDownWrenchEnvelope
var linerRegistration: LinerRegistrationSummary
var linerFillPath: MoldFlowPathSummary
var productionCastingPath: MoldFlowPathSummary
var productionCastingVents: [MoldFlowPathSummary]
var linerFillSupport: ToolingSupportSummary
var castingSupport: ToolingSupportSummary
var packageMembers: [PackageMember]
var exportContract: MotherMoldToolingContract
```

In this model, `sourceMaster` always means the immutable active geometry that
passed the MotherMold entry gate. The imported raw file is provenance bytes, not
an assumed closed solid.

Each `ToolingSupportSummary` carries the phase's empty-to-full mass/center-of-
gravity envelope, support contacts/margin, cradle artifact IDs, and a versioned
`ToolingSupportLoadEnvelope` qualification when a cradle or strap is required.

`plan.master` remains only as a compatibility accessor and resolves to the
prepared master when present, otherwise the source master.

`plan.parts` continues to mean exactly the requested 2 or 4 rigid shell parts.
Prepared masters, yokes, fixtures, and reference meshes must never be appended
to it: existing part-count, interface-count, pairwise-disjointness, isolation,
material, and export gates all rely on that invariant.

## 10. Geometry architecture

No marching cubes, level sets, SDF extraction, or voxel remeshing are added.
Use Manifold primitives/booleans and the existing proof-based repair policy.

### 10.1 Mount patch selection

Definitions:

- `M`: source-master closed solid.
- `a`: unit mount axis pointing from the master toward the shell exterior.
- `uL`: unit up vector in the liner-fill orientation.
- `uC`: unit up vector in the production-casting orientation.
- `p`: selected sacrificial patch center on the source surface.
- `s`: maximum source-master bounding-box span.
- `g`: displayed total liner offset (`clearance + extra softening`).
- `w`: shell wall thickness.

Auto considers bounded candidates on all six primary directions and any
high-confidence planar boundary patches already present in the source. For each
candidate:

1. collect a connected patch whose normals lie within 25 degrees of `a`;
2. require unobstructed travel from the patch to the exterior along `a`;
3. measure area, equivalent diameter, planarity, local curvature, connectedness,
   distance from intended shell seams/features, and suitability as a gravity-fed
   production gate in orientation `uC`;
4. reject any candidate that intersects more than one disconnected source
   region, consumes protected detail outside its footprint, or cannot receive a
   root fillet;
5. score deterministically:

```text
score = 4 * normalizedArea
      + 2 * planarity
      + 2 * exteriorAccessibility
      + 1 * featureClearance
      + 2 * castingGateSuitability
      - 3 * curvaturePenalty
      - 3 * seamPenalty
      - 5 * detailLossPenalty
```

The exact normalization is fixture-tested and recorded. Score never overrides a
hard reject. Tie-break by axis order, quantized centroid, then seed.

Auto requires:

- connected patch area at least `max(100 mm2, 0.5% of source surface area)`;
- equivalent diameter at least `max(12 mm, 8% of s)`;
- RMS planarity error no greater than `max(0.5 mm, 2% of post width)` unless the
  artist manually approves a curved sacrificial patch;
- a clear route to the exterior for the complete post, collar, and yoke.
- either `dot(a, uC) >= cos(30 degrees)` and a fill-suitable gate site, or an
  independently valid separate production gate. Auto reports which contract it
  selected; it never assumes that any sacrificial base is a good pour location.

If no candidate passes, do not create a small arbitrary post. Offer manual
placement, reorientation, existing-master socket, or external fixture.

### 10.2 Working orientations and supports

Resolve two phase-specific assemblies before committing flow paths:

- liner-fill assembly: prepared/physical master, shell, yoke, vent rods, and
  liner-fill hardware under gravity vector `uL`;
- production assembly: trimmed production liner, shell, casting funnel, and any
  production hardware under gravity vector `uC`.

The two vectors may match but are never aliased. Liner-fill high points and
buoyancy use `uL`; production gate/air analysis uses `uC`.

Support analysis includes changing liquid mass, not only the empty rigid
assembly. For each phase, evaluate fill planes at every mesh-height topology
event and at no more than 1 mm spacing between events:

- liner phase mass state = shell + fixture + prepared/physical master + silicone
  volume reachable from `LINER FILL` below the current `uL` fill plane at
  configured density;
- production phase mass state = shell + production liner + funnel + casting
  material reachable from `CAST HERE` below the current `uC` fill plane,
  including gate/vent/funnel volume, at the selected profile density.

At every state compute total mass and center of gravity from exact clipped-volume
centroids plus entered/measured solid-part mass properties. The union of these
points is the phase center-of-gravity envelope. Missing master mass/center or
custom casting density produces a conservative bounded interval; it cannot be
replaced by a single assumed midpoint.

For each phase, intersect the assembled rigid geometry with candidate horizontal
support planes, form the convex hull of contact patches, and measure the minimum
distance from the projected center of gravity to the hull boundary. The default
minimum support margin is `max(10 mm, 5% of assembly span)`, and the assembly
must resist a 10-degree quasistatic tilt without the projection leaving the
hull. A line/point contact or rolling cylindrical contact never passes.

If mass/center-of-gravity data are incomplete, a bare free-standing shell is
not called stable. Auto generates a broad, phase-labeled cradle that positively
locates against non-art shell surfaces and supplies a measured support polygon.
A single reversible cradle may serve both phases when both orientations and all
ports remain accessible; otherwise export separate `LINER FILL STAND` and
`CASTING STAND` artifacts.

Cradles:

- contact only rigid shell/fixture geometry, never silicone or art surfaces;
- cannot cover fill, gate, vent, fastener, or demold access;
- include strap/clamp points when the center-of-gravity interval is uncertain;
- have a unique seating orientation and at least three non-collinear support
  regions;
- remain separate from `plan.parts` and are listed in the package/guide.

Cradle/strap qualification covers the maximum phase mass and worst center-of-
gravity state, 10-degree tilt reactions, strap preload, local contact pressure,
and a 1.5x handling factor. A versioned `ToolingSupportLoadEnvelope` is tied to
cradle geometry, printer/material profile, layer orientation, hardware, and
contact pads. Rated capacity must exceed every vertical, lateral, overturning,
and strap/contact component. Unknown profiles remain `support geometry only` and
cannot satisfy production release.

Manual support planes must pass the same measured polygon/access gates. A text
instruction such as `prop upright` is not a support solution.

### 10.3 Prepared master and anchor/gate post

The prepared master is `M union P union G union_i L_i`, where `P` is the
connected anchor/gate post, optional `G` is a separately approved gate root, and
each `L_i` is a shallow production-vent landing boss. All additive solids have
typed modification regions and positive overlap with `M`; the source file and
active source geometry remain unchanged. The removable vent rods are separate
artifacts and are not part of this union.

Post regions:

1. **Round gate root** at the source surface. Default diameter equals production
   gate diameter, default 12 mm, range 6-30 mm. It has a root fillet of
   `max(2 mm, 0.15 * gateDiameter)`.
2. **Silicone transition** extending from the source to the nominal outer liner
   surface. This region creates a clean round opening in the cured liner.
3. **Dry keyed post** beyond the shell shutoff. Its rounded-D profile prevents
   rotation without sharp corners.
4. **Cross-pin region** outside the shell and yoke.

Automatic D-post starts from these geometric candidates, then grows to satisfy
the selected load envelope and hardware ligaments:

```text
initialPostWidth = clamp(0.12 * s, 14 mm, 24 mm)
postThickness = 0.75 * postWidth
cornerRadius  = 0.20 * postThickness
freeLength    = max(18 mm, 3 * crossPinDiameter + 8 mm)
totalLength   = g + w + collarAllowance + freeLength
minimumPinLigament = max(3 mm, 1.25 * crossPinDiameter)
postWidth >= crossPinDiameter + 2 * minimumPinLigament
```

The D section is constant through its mating collar; it has no rigid undercut.
All edges that contact silicone have at least a 1 mm radius. The cross-pin bore
lies entirely outside the silicone volume and at least `1.5 * pinDiameter` from
the free end and collar face. The 24 mm candidate value is not a structural cap;
larger posts or multiple/external fixtures are required when the qualified load
envelope demands them.

Auto selects standard through-hardware from the physically calibrated
M4/M5/M6 table for the chosen print/material profile and worst design wrench. The pin
passes through two yoke ears and the post, so it prevents both upward lift and
sideways yoke escape; it never depends on printed threads. M4 is only the
smallest qualified option, not a universal default.

### 10.4 Split collar, shutoff, and yoke

The shell receives a connected collar around the dry D-post section:

- profile clearance defaults to 0.25 mm per side;
- collar material is additive outside the shell, never stolen from the nominal
  wall;
- collar wall is at least the configured shell wall thickness;
- collar is split by an existing parting interface so opening the shell releases
  the post;
- an accessible seal land surrounds the shutoff, default
  `max(8 mm, g + w)`;
- the collar exterior includes a broad reaction face for the yoke;
- the reaction face is a keyed receiver shared by two mutually exclusive
  artifacts: the hold-down yoke during liner creation and the casting-funnel
  insert during repeated casting;
- a continuous rigid ring may not trap the liner or master.

The separate yoke is a side-loading plate with a D-slot and two cross-pin ears.
It slides into a keyed receiver with a closed end stop after shell assembly and
sits on the collar reaction face. The cross-pin passes through both ears and the
post. The receiver/end stop prevents rotation and side escape; the pin prevents
withdrawal and axial lift. This spreads load across the assembled shell instead
of concentrating it at the post bore.

The collar constrains X/Y and rotation. The source/post shoulder establishes
the assembled depth. The yoke/cross-pin resists lift. Sealant supplies liquid
sealing only; it is not credited as structural retention.

The casting-funnel insert cannot be installed while the post/yoke is present.
It uses the same cross-pin/bolt to hold its nozzle against a molded annular
silicone sealing bead around the round gate. A rigid stop controls compression;
the default target is 5% of bead height and the allowed range is 2-10%. The
nozzle cannot protrude into the art cavity or fold the liner. Its drafted cup
releases the cured gate sprue in the documented demold direction. Receiver,
insert, stop, seal bead, and pin engagement are measured as one phase-specific
assembly.

### 10.5 Uplift and hold-down qualification

For each liner-fill state `h`, clip the prepared/physical master by the
gate-reachable silicone fill and compute the wetted displaced volume and centroid:

```text
FB(h) = siliconeDensity * submergedVolume(h) * gravity * uL
FW    = -masterMass * gravity * uL
F(h)  = FB(h) + FW

T(h)  = cross(centerOfBuoyancy(h) - fixtureDatum, FB(h))
      + cross(masterCenterOfGravity - fixtureDatum, FW)
```

Evaluate all topology-event/1 mm fill states from empty through full. Resolve
`F(h)` into axial force along mount axis `a` and transverse shear; resolve
`T(h)` into torsion about `a` and bending moment. An off-center hand or vessel
therefore cannot pass on net buoyancy alone. Unknown master weight uses 0 g as
the worst uplift case; unknown center of gravity uses the bounded master volume,
not the fixture axis.

The artist summary shows maximum uplift and required restraint. Build details
records the full worst-state force-and-moment wrench, fill height, centers of
buoyancy/gravity, and liner-fill orientation.

Defaults:

- silicone density: 1.10 g/cc;
- master weight: unknown;
- unknown weight uses `0 g` only for the worst-uplift warning; it cannot qualify
  the combined wrench because downward load/moment are then unbounded;
- safety factor: 3.0;
- minimum handling force: 10 N applied at the farthest master point from the
  fixture datum, contributing its corresponding bending/torsional moment.

Load qualification requires measured master mass and center of gravity. A
prepared print may begin with a slicer/material/infill estimate and bounded
interval, but remains `geometry only` until the finished positive is weighed and
its balance datum is confirmed using the generated check procedure.

The geometry audit sweeps the retained master in all six rigid-body degrees of
freedom before removal:

- translations along `+/-X`, `+/-Y`, and `+/-Z`;
- rotations about X, Y, and Z around the measured master center of gravity;
- outward mount-axis release with yoke/pin installed and then removed.

Maximum free translation must be no greater than configured fit clearance plus
0.05 mm; maximum angular play is 1 degree; no yoke side-exit path exists with
the cross-pin installed. After pin/yoke removal, the documented shell/master
sequence must become collision-free without tearing the production liner.

Structural status comes from a versioned `HoldDownWrenchEnvelope` calibrated by
physical proof tests for a specific print process, material, layer orientation,
post/collar/yoke dimensions, and hardware. For every fill state, apply the 3x
uncertainty factor to the fluid/gravity wrench and combine it with the minimum
handling wrench. The configuration passes only when the empirically calibrated
interaction rule is at most 1.0:

```text
utilization = |axialForce| / ratedAxial
            + shearForce / ratedShear
            + bendingMoment / ratedBending
            + |torsionMoment| / ratedTorsion
```

A supported profile earns `Load-qualified hold-down`. An unknown
material/process may be exported as `Geometry complete - load capacity
unverified`, but it cannot produce `Ready to pour` or satisfy a production
release row. A configuration beyond the calibrated envelope blocks production
status and offers a larger post/hardware, a second/external hold-down, or another
orientation.

Envelope qualification uses at least three specimens per profile/geometry
family at each governing combined-load corner, not only separate axial/shear
tests. Each rated component is no greater than half the lowest measured ultimate
component under the calibrated interaction rule. Each actual release-candidate
tool then holds `1.25 * worstDesignWrench` with simultaneous axial, shear,
bending, and torsional components for at least the greater of 30 minutes or the
declared silicone working time. It passes only with no crack, layer separation,
pin/yoke escape, hardware slip, or more than 0.10 mm permanent displacement
after unloading. These structural factors are separate from the 3x buoyancy
uncertainty factor.

Socket mode is positive only when measured master mass, center of gravity,
contact footprint, net uplift, and tipping analysis all pass without adhesive
credit. Otherwise it remains `Locator only - external hold-down required`.
External-fixture mode must record its modeled restraint directions and entered
or tested capacity; a label alone is not verification.

### 10.6 Liner states

Compute two exact liner states:

```text
baseLiner = cavityEnvelope - sourceMaster
preparedMasterFlowFormers = baseLiner
                            intersect (preparedMaster - sourceMaster)
asPouredLiner = baseLiner
              + linerRegistrationBosses
              + gateLipAndSealBead
              + linerFillAndVentPlugs
              - preparedMasterFlowFormers
              - removableProductionVentRods

productionLiner = asPouredLiner - oneTimeTrimVolumes
```

Fixture shutoff regions remove silicone only where the rigid collar seals to
the prepared post. The prepared post itself is not passed to the general cavity
offset operation; art cavity generation remains based on the source master so
the dry post does not receive an accidental silicone sleeve.

All prepared-master additions inside the liner (anchor/separate gate roots and
vent landing bosses) plus removable production-vent rods are intersected with
the liner volume exactly, not approximated by nominal cylinders later.
`oneTimeTrimVolumes` are bounded by generated trim planes at the liner exterior;
they remove only the liner-fill/liner-vent nubs and preserve every registration
boss, gate lip, sealing bead, and production-flow opening. The guide and viewport
show each cut in red before export.

Liner-fill connectivity is measured on `asPouredLiner`. Reseating, funnel seal,
production gate/vent connectivity, collision, and reuse gates are measured on
`productionLiner`. Both are reference/validation geometry, not printable
artifacts, and neither replaces the artist's poured silicone.

### 10.7 Liner registration buttons

Automatic liner registration creates outward silicone bosses whose matching
recesses and protective housings belong to individual rigid shell parts.

Default per-part count: 2.

For total liner offset `g`:

```text
buttonDiameter = clamp(2.5 * g, 10 mm, 24 mm)
buttonDepth    = clamp(0.6 * g, 3 mm, 6 mm)
buttonDraft    = 12 degrees
minimumSpacing = 1.5 * buttonDiameter
featureMargin  = buttonDiameter / 2 + max(3 mm, w)
```

Each button is a rounded drafted frustum/dome, not a sharp dovetail. It extends
outward from the nominal liner surface, adding silicone rather than thinning
the base liner. The matching shell recess is formed by first adding an exterior
housing and then subtracting the button tool; final backing remains at least
`w`.

Candidate requirements:

- completely owned by one final shell part;
- axis within 30 degrees of that part's demold axis;
- no seam crossing;
- clear of shell keys, bolt bores, master collar, liner fill port, production
  gate, vents, and other liner buttons by `featureMargin`;
- no sharp edge below 1 mm radius;
- deterministic farthest-point distribution;
- centers span at least 25% of liner bounds on two principal directions so all
  registration is not clustered in one area.

The complete requested pattern is transactional. If one final shell part cannot
receive its requested buttons, the entire liner-registration stage rolls back
and export blocks; no partial pattern is called reusable.

### 10.8 Captured gate lip

Automatic mode also forms a silicone lip around the production gate where the
liner meets the split collar. The lip:

- provides axial liner retention and a visible seating check;
- is split by at least one shell parting interface so the rigid shell can open;
- has default depth `clamp(0.5 * g, 2 mm, 4 mm)`;
- preserves at least `w` shell backing through additive housing;
- has rounded edges and a release path compatible with the selected silicone.
- includes the annular sealing bead and rigid compression-stop datum used by the
  pinned casting-funnel insert.

Buttons provide positional registration; the lip resists peel and axial creep.

### 10.9 Independent liner and production flow systems

The flow contract is phase- and process-specific. `gravityResin` and
`gravityPlaster` become qualified profiles only after section 18 records tested
viscosity/pot-life/exotherm ranges and compatible liner/shell materials.
`customGravity` can generate geometry and measurements but remains `process not
qualified` until a corresponding physical record exists. Pressure, vacuum,
rotational, slush, and ceramic slip processes are rejected by this contract
rather than inheriting gravity defaults.

#### Liner fill path

The current funnel/channel becomes `LINER FILL`. It must connect shell exterior
to `asPouredLiner` and remain owned by one rigid part. Requested liner vents
connect `asPouredLiner` high points under `uL` to the exterior. These ports are
used only while making the liner and are removed by the prescribed trim map.

#### Production casting gate

Prepared-post mode uses the round post root to form an opening from the shell
exterior into the empty liner cavity after master removal. The casting-funnel
insert seats in the collar receiver after the yoke/post are removed; its nozzle,
round liner opening, and inner casting cavity form one independently measured
minimum-bore path. The funnel has at least 12 degrees of draft, a rounded throat,
an unambiguous removal direction, and positive cross-pin retention against the
liner seal bead.

If a safe anchor-as-gate location cannot serve the production material, Auto may
propose a separate production gate. That is a visible, manual-confirmable result;
it is never silently substituted.

The assembly guide explains which silicone nubs to trim after liner creation and
which opening must remain intact for repeated casting.

#### Production casting vents

Liner-fill vents terminate in the space where silicone is being poured. They are
not credited as production casting vents. For the selected casting orientation
`uC`, Auto runs this deterministic geometric air-trap screen on the trimmed
production-liner cavity:

1. assign each cavity-surface vertex height `h = dot(position, uC)`;
2. compute local-maxima persistence on the triangle adjacency graph using stable
   vertex-ID tie breaks;
3. discard a basin only when both persistence depth is below
   `max(2 mm, 1% of cavity span)` and estimated trapped volume is below
   `max(50 mm3, 0.1% of cavity volume)`;
4. merge maxima whose catchment regions meet above the lower saddle;
5. mark a region served only when it has a monotone non-descending surface path
   to the gate or a proposed vent opening;
6. propose the minimum deterministic vent set with collision-free outward
   extraction routes, then prove each final bore on `productionLiner` and the
   assembled shell.

This is a reproducible geometric screen, not a claim to simulate viscosity,
surface tension, cure kinetics, or pressure. The selected gravity-casting
profile supplies gate/vent defaults and the physical matrix remains mandatory.

For a prepared print, each required vent uses a separate smooth, drafted former
rod. Default diameter is 3 mm, range 2-6 mm. A shallow positive landing boss on
the prepared master locates the rod; its measured footprint is a separately
approved `productionVentLanding` modification region. The rod's keyed outer end
passes through a shell sleeve, and a small compatible wax/clay fillet seals the
rod/landing joint for the one-time liner pour. After cure, every rod is pulled
outward through its sleeve before the shell opens or the master moves. The
prepared master therefore remains unbranched.

Each rod has one straight, collision-free extraction axis, at least 2 degrees
of release draft, a positive exterior grip, and a serialized removal sweep. A
rod may not bridge disconnected source regions, cross a shell seam without an
explicit split sleeve, or touch protected fixture/registration geometry. The
print package includes each qualified rod as a separate phase-labeled artifact;
the hardware schedule may name a dimensionally equivalent smooth wax/plastic
substitute, but substitution changes its status to an artist-verified shop step.

For an existing physical master, Refab Artist generates shell sleeves plus a
dimensioned placement diagram for standard wax/plastic vent rods temporarily
attached to the positive. Because the software cannot prove the artist's rod
installation, Build Status says `Casting vents: placement required` until the
artist confirms the physical setup; the manifest preserves that external step.

Zero production vents is valid only when the high-region analysis records that
the gate serves every air region. If a required region cannot be vented safely,
export blocks with direct actions to reorient the tool, place a vent manually,
move the gate, or revise the parting.

## 11. Pipeline order

The v3 planner order is:

1. Validate source master using the current closed-solid gate.
2. Resolve/validate master source and mount settings.
3. Resolve independent liner-fill/casting orientations and support strategy;
   select mount/gate patch and all typed art-surface modification regions.
4. Build the prepared master/post, separate production-vent rods, yoke, and
   casting-funnel insert when requested.
5. Build the subtype cavity from the immutable source master.
6. Build the closed rigid shell around the complete cavity.
7. Add post shutoff/collar, funnel receiver, production-gate geometry, and
   production-vent sleeves to the whole shell.
8. Resolve exact parting planes and partition the shell.
9. Run rigid-part demold/undercut analysis.
10. Build all flanges and bolt bores transactionally.
11. Build per-part liner-registration housings/recesses transactionally.
12. Build liner fill funnel, liner vents, and any separate production gate.
13. Build shell-to-shell tapered registration keys last.
14. Generate/validate phase support cradles against final shell geometry.
15. Apply proof-based final repair without consuming protected source, fixture,
    liner-registration, flow-path, flange, or key material.
16. Compute as-poured/production liner states and all flow/registration summaries.
17. Run final in-memory topology, completeness, collision, load-status, support,
    modification-approval, and retention gates.
18. Revalidate exact serialized artifacts and the package manifest before write.

Protected geometry audits extend the current generated-locator pattern to:

- prepared-master post root/profile;
- collar and seal land;
- liner-registration housing/recess contribution;
- production gate;
- production vent rods/landings/sleeves and casting-funnel receiver;
- current flanges and shell keys.

Replace the current single `protectedLocator` argument with a typed
`ProtectedToolingAuditSet`. It records additive volumes, subtractive profiles,
ownership, and required retention independently for every protected feature.
One combined volume is insufficient: a successful collar must not hide a
missing liner recess or damaged production gate.

## 12. Export package contract

### 12.1 Manufacturing ZIP layout

Example for the current four-part hand:

```text
handStand_ex3_mothermold.zip
  manifest.json
  README.txt
  print/
    mold-part-A.stl
    mold-part-B.stl
    mold-part-C.stl
    mold-part-D.stl
    prepared-master.stl
    master-hold-down-yoke.stl
    production-casting-funnel.stl
    production-vent-former-01.stl       (one per required vent)
    liner-fill-stand.stl                (when required)
    casting-stand.stl                   (when required)
  reference/
    imported-source.<original-extension> (optional byte-for-byte copy)
    active-source-master.obj            (optional exact planning reference)
    as-poured-silicone-liner.obj         (optional, DO NOT PRINT)
    production-silicone-liner.obj        (optional, DO NOT PRINT)
    assembled-tooling.obj                (optional, DO NOT PRINT)
  guide/
    assembly-and-reuse.html
    assembly-overview.svg
    liner-fill-setup.svg
    casting-setup.svg
    trim-map.svg
    hardware.csv
```

The ZIP root and directories are deterministic. Timestamps are fixed as in the
current deterministic ZIP writer.

### 12.2 Manifest

`manifest.json` uses sorted keys and includes:

- schema: `refabartist.mothermold.tooling/v3`;
- schema version: integer `1`, incremented only for incompatible manifest-shape
  changes within the v3 tooling contract;
- app/contract version and deterministic seed;
- units, imported-source byte SHA-256 when available, and canonical active-source
  geometry SHA-256;
- source and prepared-master bounds/volumes;
- manufacturing printer/material profile IDs and immutable snapshot hash when
  qualification was requested;
- every non-manifest `PackageMember` path, role, content/media type, byte count,
  SHA-256, and
  source-dependency status; geometry members additionally carry manufacturing
  qualification, quantity, material hint, triangle/volume/topology metrics,
  assembled transform, and recommended print transform;
- shell part/interface/plate/bolt/key counts;
- master source/retention mode, complete typed modification-region set and
  approval signature, mount axis/point, post/collar/yoke dimensions, selected
  hardware, seal land, six-DOF motion, force/moment fill history, worst design
  wrench, wrench-envelope version, and qualification status;
- liner button count/sites/dimensions and gate-lip dimensions;
- separate liner-fill/casting orientations, empty-to-full mass/center envelopes,
  support margins, cradle/strap reactions, and support-load qualification;
  liner-fill port/vent sites; production-gate/funnel dimensions; production-vent
  required/placed counts, sites, rod artifacts, removal axes, and diameters;
- silicone/plastic volume and mass estimates;
- blocking/warning diagnostics (a written manufacturing package has no blocking
  entries);
- references to ordered assembly, liner-fabrication, repeat-casting, demold, and
  storage steps.

The package writer must either support ZIP64 or reject a predicted archive over
the current writer's 32-bit member/archive limits before building. Large scan
geometry may not fail after a multi-minute mold build with a generic ZIP error.

The manifest artifact list is the export contract. The writer rejects missing,
extra, duplicate, role-conflicting, or hash-mismatched members.

There is one authoritative entry point:
`MotherMoldToolingPackageWriter.validateAndWrite(plan:destination:)`. It runs the
same complete plan contract used by the UI/headless status, serializes members,
reopens and remeasures every geometry member, builds `PackageMember` records,
validates the final archive set, then atomically publishes it. Low-level ZIP
emission is private. The existing direct `writeZip(plan:)` path is removed or
made a thin call to this validator; no UI, test, or headless path may bypass
contract-count/load/support/modification checks.

Archive paths are also part of the contract. The writer and independent auditor
reject absolute paths, `..` traversal, duplicate normalized paths, symlinks,
undeclared members, and a member whose bytes do not match its declared role.
Raw OBJ/other source bytes are provenance only. The manifest lists detected
external MTL/texture/dependency references and whether they were included; a raw
copy with missing dependencies is never described as a complete source project.

### 12.3 Prepared master requirements

When `sourceMode == preparedPrint`:

- `prepared-master.stl` is mandatory;
- `master-hold-down-yoke.stl` and `production-casting-funnel.stl` are mandatory;
- exact required production-vent rod and support-cradle artifacts are mandatory;
- it is never replaced by the original source mesh;
- imported raw bytes and/or the active source geometry may be copied under
  `reference/` only when requested, with distinct roles and names;
- its name and role appear in the UI, guide, manifest, and headless measurements;
- it receives independent print-orientation and material guidance.

### 12.4 Legacy formats

- Combined OBJ can include named mold, prepared-master, yoke, and reference
  objects for inspection, but it is not a manufacturing-ready package.
- Laid-out STL remains available only for legacy shell-only projects. It is
  disabled for prepared-master/reusable-tooling builds.
- Separate shell ZIP from contract v2 remains readable/exportable for unchanged
  legacy projects.

### 12.5 Visual guide and part identity

Every manufacturing artifact receives one stable short ID used everywhere:
`MOLD A...D`, `PREPARED MASTER`, `YOKE`, `CAST FUNNEL`, `VENT 1...N`, `LINER
FILL STAND`, and `CASTING STAND`. When exterior wall/feature clearance permits,
the ID is embossed or debossed at least 0.6 mm on a non-mating face. Geometry
labels are protected features and may never reduce configured wall or interfere
with seating; the guide/manifest identity remains authoritative if a physical
label cannot fit.

`assembly-and-reuse.html` is self-contained within the extracted package and
opens without a server or network. It uses generated views of the exact final
artifacts, not generic diagrams.
Canonical guide views are metadata-free SVGs from a deterministic fixed-camera
CPU/vector projection and hidden-line pipeline. GPU/RealityKit screenshots are
external evidence only and never enter the deterministic manufacturing ZIP.
It includes:

1. package inventory and hardware/consumables;
2. prepared-master change map and approval signature;
3. exact liner-fill orientation, cradle, post/yoke/pin, vent-rod, seal, fill, and
   liner-vent sequence;
4. ordered vent-rod/yoke/shell/master removal and trim map;
5. production-liner seating checks and exact casting orientation;
6. funnel pin/seal, gate, and production-vent use;
7. demold, gate/vent trimming, cleaning, storage, liner replacement, and
   prepared-master reuse;
8. all geometry-only, printer-fit-unchecked, load-unqualified, or external shop
   responsibilities in plain language.

`README.txt` points to the HTML and repeats only the artifact count, readiness
state, and critical external responsibilities. Guide/member generation is part
of authoritative package validation; stale or missing phase renders block a v3
manufacturing package.

## 13. Hard geometry and export gates

All thresholds are measured on final geometry and repeated after serialization.

### 13.1 Source preservation

- Imported-source byte hash and active-source canonical geometry hash never
  change during planning.
- The active source master is geometrically contained by the prepared master:
  `volume(activeSourceMaster - preparedMaster) <= 0.01 mm3`.
- Every intentional anchor/gate/vent/repair mark has one typed
  `MasterModificationRegion`; combined roots may carry multiple purposes but no
  change is hidden in an untyped catch-all mask.
- Outside the geometric union of approved modification regions, bidirectional
  sampled surface distance is at most 0.05 mm.
- Changed source-surface area outside that union is at most
  `max(1 mm2, 0.1% of source area)`.
- The viewport, approval command, report, and manifest record each region's
  purpose, boundary, area, and location; the approval signature matches final
  source/settings/regions at export.

### 13.2 Prepared master

- exactly one connected topology-valid manufacturing mesh;
- watertight, finite, consistent winding, positive signed volume;
- no dropped debris at any stage;
- post/source union has positive measured overlap and a connected root profile;
- complete D-post and cross-pin-bore profiles survive final serialization;
- no positive-volume collision with assembled shell/yoke above 0.01 mm3;
- configured clearances measure within +/-0.05 mm.
- every removable vent former is a separate artifact, never a branch on the
  prepared master.

### 13.3 Hold-down

- collar connected to final shell parts;
- collar completely surrounds the configured dry post profile when assembled;
- non-circular profile proves anti-rotation;
- yoke and cross-pin create a measured axial stop in the mount direction;
- six-degree-of-freedom sweep meets the translation/angular limits, proves no
  side escape, and exposes no release sequence while pin/yoke are installed;
- removing the pin/yoke enables the complete documented rod/shell/master release
  sequence without rigid collision;
- seal land continuous and accessible;
- complete mount geometry retained at least 98% through every later transaction;
- worst-case and mass-adjusted uplift values are present when source volume is
  measurable;
- selected configuration's versioned combined axial/shear/bending/torsion
  wrench envelope has utilization at most 1.0 for every fill state, or status is
  explicitly `geometry only`/`external` and cannot satisfy production release;
- casting-funnel insert and hold-down yoke are mutually exclusive in the shared
  receiver, and each has a verified seat/release direction.
- pinned funnel stop produces configured seal-bead compression without nozzle
  intrusion into the casting cavity.

### 13.4 Liner registration

- exact requested button count, including exact count per final part;
- each button/recess is owned by one shell part;
- complete production-liner boss and shell-recess profile retained at least 98%;
- local shell backing at least configured wall thickness minus 0.05 mm;
- required feature margins and spacing pass;
- gate lip is continuous but split so no closed rigid ring traps it;
- production liner remains one connected component unless a future explicit
  multi-liner mode is introduced;
- no liner button, lip, or housing damages the source-master detail surface.

### 13.5 Flow paths

- one verified liner-fill path reaches `asPouredLiner` under `uL`;
- exact requested liner vent count reaches that volume's high regions;
- the exact trim map transforms `asPouredLiner` into `productionLiner` without
  cutting registration, seal, gate, or production-vent geometry;
- one verified production gate reaches the inner casting cavity after master
  removal;
- casting-funnel throat, liner gate, and cavity form one connected path with no
  unreported step below the displayed diameter;
- cross-pin retention and the molded gate bead provide a measured liquid-seal
  load path; repeated casting does not rely on reapplied sealant at the funnel;
- every required production high region is served by the gate or an exact
  verified production vent; liner-fill vents receive no credit here;
- every separate production-vent rod survives serialization, has a complete
  outward removal sweep, and produces the same production-liner opening and
  shell-sleeve path;
- minimum bore at every path is at least the displayed diameter minus 0.05 mm;
- path names, printed labels, manifest roles, and guide steps agree;
- no bore consumes protected mount, liner-registration, flange, or shell-key
  geometry.

### 13.6 Working supports

- separate `uL` and `uC` vectors and phase assemblies are recorded;
- exact empty-to-full fluid mass/centroid states use the configured silicone and
  casting densities and include gate/vent/funnel volumes;
- each phase has either a measured stable support polygon/tilt margin or one or
  more topology-valid cradle artifacts that provide it;
- every projected center-of-gravity state/conservative interval remains inside
  the support polygon by the configured margin;
- cradle contacts and straps avoid art, silicone, ports, fasteners, and demold
  paths;
- versioned cradle/strap load-envelope capacity exceeds worst full-phase weight,
  lateral/overturning reaction, strap preload, and local contact load after the
  1.5x handling factor; otherwise status is `support geometry only`;
- support placement is unique, visible in Assembly/Explode, and documented
  before any pour step.

### 13.7 Package

- every geometry member labeled for manufacturing passes round-trip topology
  and component checks;
- shell parts remain pairwise disjoint within the existing 0.01 mm3 tolerance;
- prepared master, yoke, casting funnel, and shell are pairwise disjoint in their
  documented phase-specific assembled coordinates except zero-volume intended
  contact; the manifest never presents the yoke and casting funnel as installed
  simultaneously;
- required member set exactly matches the manifest;
- member hashes and deterministic rerun ZIP hash match;
- two independent processes writing to different output directories produce
  identical member bytes, manifest bytes, canonical evidence hash, and ZIP
  bytes; destination paths and wall-clock timestamps are excluded from canonical
  evidence;
- every non-manifest archive member has a `PackageMember`; non-geometry members
  omit geometry metrics and geometry members carry them; manifest bytes/hash are
  recorded in outer evidence without self-reference;
- no `.stl` path receives ZIP/OBJ bytes and no reference artifact is labeled as
  a manufacturing mesh;
- predicted and actual archive/member sizes remain within the selected ZIP
  implementation's limits; ZIP64 archives are independently opened and audited.

## 14. Diagnostics and recovery actions

| Failure | Artist-facing message | Direct actions |
| --- | --- | --- |
| No safe sacrificial patch | `No safe place was found for a master post without altering visible artwork.` | Pick mount area; reorient; use existing master; external fixture. |
| Post union fails | `The prepared master post did not join into one manufacturing solid.` | Pick broader area; enlarge root; repair master. |
| Collar cannot reach shell | `The master hold-down cannot connect to the rigid shell at this location.` | Pick another area; change axis; external fixture. |
| Lift not restrained | `The selected setup locates the master but does not prevent it from lifting.` | Use prepared post; add external hold-down; explicitly keep locator-only mode. |
| Load unqualified | `The hold-down geometry fits, but its strength is not qualified for this material, orientation, and estimated pour load.` | Choose supported print profile; enlarge post/hardware; test external fixture. |
| Excess fixture play | `The positive can still shift or rotate more than the allowed fit during the liner pour.` | Tighten fit; enlarge keyed post; add/verify external restraint. |
| Vent rod traps master | `A casting-vent rod cannot be removed before the positive.` | Move/re-angle rod; change sleeve/parting; remove vent proposal. |
| Unstable working orientation | `The assembled tool has no verified stable base for this pour orientation.` | Add generated cradle; choose support plane; reorient. |
| Changes need approval | `The prepared positive adds marks that have not been approved.` | Inspect highlighted regions; approve; move/remove a mark. |
| Missing liner buttons | `The reusable liner cannot be registered on every mold part.` | Widen shell clearance; reduce button count/size; change parting. |
| Thin key housing | `A liner-key pocket would leave less than the required shell wall.` | Increase wall; reduce button depth; move button. |
| Liner trapped | `The liner lip would be enclosed by a rigid ring.` | Split/move lip; change parting; disable lip with warning. |
| No production gate | `The liner can be made, but there is no verified opening for casting copies.` | Use anchor as gate; place production gate manually. |
| Trapped casting air | `This casting orientation leaves an air pocket with no safe vent.` | Reorient; place a casting vent; move the gate; revise parting. |
| Funnel cannot seat | `The casting funnel does not make a clear, releasable path into the liner.` | Rebuild receiver; enlarge gate; place a separate gate. |
| Printer fit unknown | `Manufacturing meshes are valid, but fit and support needs were not checked against a printer profile.` | Select printer profile; send artifact to Partition; export with status recorded. |
| Package incomplete | `The tooling package is missing the prepared master or fixture hardware.` | Rebuild; do not offer partial export. |

Messages never expose Manifold exception text as the primary explanation.
Engineering details remain available under Build details.

Diagnostics must carry a typed subsystem/recovery code. Existing UI logic that
classifies messages by searching for words such as `registration`, `socket`, or
`flange` must not route liner-registration failures to shell-key instructions.

## 15. Headless and automation contract

Add flags:

```text
--master-source prepared|physical
--master-mount prepared-post|socket|external
--mount-placement auto|manual
--mount-axis auto|+x|-x|+y|-y|+z|-z
--mount-point-x <mm> --mount-point-y <mm> --mount-point-z <mm>
--production-gate-diameter-mm <f>
--production-gate-point <x,y,z>
--liner-fill-up auto|+x|-x|+y|-y|+z|-z
--casting-up auto|+x|-x|+y|-y|+z|-z
--casting-process gravity-resin|gravity-plaster|custom-gravity
--production-vents auto|manual
--production-vent-diameter-mm <f>
--production-vent-point <x,y,z>       (repeatable in manual mode)
--tooling-support auto|manual
--liner-fill-support-plane <ox,oy,oz,nx,ny,nz>
--casting-support-plane <ox,oy,oz,nx,ny,nz>
--post-width-mm <f> --post-thickness-mm <f> --post-length-mm <f>
--cross-pin-diameter-mm <f>
--master-weight-g <f>
--master-cog-x <mm> --master-cog-y <mm> --master-cog-z <mm>
--external-fixture-capacity-n <f>
--silicone-density-g-cc <f>
--casting-density-g-cc <f>
--liner-registration auto|buttons|buttons-and-lip|none
--liner-buttons-per-part <i>
--liner-button-diameter-mm <f>
--liner-button-depth-mm <f>
--print-profile <id>
--approve-modifications <sha256>
--include-reference-meshes
```

Rules:

- prepared master requires `--packaging manufacturing-zip`;
- manual placement requires all point coordinates and a non-auto axis;
- unknown enum values fail; they are never ignored;
- measurement JSON adds all manifest counts, prepared-master topology metrics,
  source-preservation metrics, fill-progress hold-down wrench/envelope evidence,
  fluid-inclusive support/cradle evidence, liner registration metrics, both flow
  paths, and package hashes;
- a planning run always emits the sorted modification set and signature;
  prepared export requires `--approve-modifications` to match that exact
  signature, and any relevant plan change invalidates it;
- GUI and headless use the same settings sanitizer, plan contract, and package
  writer.
- MotherMold supplies a mode-appropriate default format/package instead of
  inheriting the global DXF default, and the argument parser rejects all
  unconsumed/unknown MotherMold flags.

## 16. Module and ownership plan

### New modules

| File | Responsibility |
| --- | --- |
| `PreparedMasterBuilder.swift` | typed modification regions, mount candidate analysis, source-preserving post/vent-landing union, cross-pin bore, prepared-master summary |
| `MoldMasterFixtureBuilder.swift` | split collar, shutoff, seal land, captured yoke, removable vent rods/sleeves, anti-lift geometry; supersedes narrow socket-only ownership in `MoldMasterMountBuilder` |
| `MoldHoldDownQualification.swift` | fill-progress center of buoyancy, six-DOF sweep, force/moment wrench, calibrated combined-wrench envelope lookup/status |
| `MoldLinerRegistrationBuilder.swift` | expected button sites, additive housings, cavity recesses, gate lip, transactional survival proof |
| `MoldLinerStateBuilder.swift` | exact as-poured liner, trim volumes, production liner, trim-map evidence |
| `MoldFlowPathBuilder.swift` | separate phase orientations, liner-fill/production-gate/persistent-maxima vent contracts, casting-funnel insert; may wrap/refactor `MoldFeatureBuilder` |
| `MoldToolingSupportBuilder.swift` | fluid-inclusive center envelope, support polygon/tilt audit, phase cradle generation/load qualification |
| `MotherMoldToolingManifest.swift` | versioned manifest schema, artifact roles, deterministic JSON |
| `MotherMoldToolingPackageWriter.swift` | sole validated/atomic package entry point, `PackageMember` contract, ZIP bytes/hashes |
| `MotherMoldGuideRenderer.swift` | deterministic fixed-camera SVG phase/trim views and self-contained HTML guide |

### Existing modules to extend

| File | Change |
| --- | --- |
| `MotherMoldSettings.swift` | new enums/settings with strict present-value decoding and versioned missing-key migration |
| `MotherMoldPlanner.swift` | new pipeline stages, artifacts, summaries, protected-geometry audits |
| `MoldCavityBuilder.swift` | preserve source-art cavity and fixture shutoff boundary |
| `MoldPartitioner.swift` | collar/lip split ownership and release directions |
| `MoldFlangeBuilder.swift` | reserve fixture/liner-registration regions |
| `MoldFeatureBuilder.swift` | migrate current spout/vent behavior to liner-fill semantics |
| `MoldKeyBuilder.swift` | avoid reserved liner/collar regions; shell keys remain last |
| `MotherMoldExporter.swift` | route v3 jacket builds only through authoritative package validation, remove direct ZIP bypass; retain v2 legacy writers |
| `HeadlessExportCommand.swift` | flags and full measurement evidence |
| `ContentView.swift` | Master & Reuse controls, status, actions, export content list |
| `ModelSceneView.swift` | source/prepared/liner/fixture layers and explode transforms |
| `SlicerProjectDocument.swift` | migration and round-trip persistence |

`ModelSceneView` currently renders only `plan.parts` while the visible master is
the imported model. V3 must render prepared/reference/liner/fixture artifacts
from the current plan so viewport evidence and exported geometry cannot diverge.
`MotherMoldPreviewLayout` gains stable identities and transforms for those
artifacts without putting view-only explode state into settings or exports.

The current checkout of this repository remains the only implementation target.

## 17. Failing-first software verification

No production edit begins until these tests fail for the intended missing
behavior.

The current suite has broad shell coverage but no first-class prepared-master,
anti-float, liner-registration, or mixed-tooling-package contract. Add focused
files rather than diluting the existing shell tests:

- `MotherMoldPreparedMasterIntegrityTests.swift`;
- `MotherMoldLinerRegistrationIntegrityTests.swift`;
- extensions to `MotherMoldPourSystemIntegrityTests.swift`;
- extensions to `MotherMoldExportIntegrityTests.swift`;
- extensions to `MotherMoldUIContractTests.swift`; and
- project/headless compatibility tests in their existing suites.

### 17.1 Prepared master

- source mesh/hash is unchanged after planning;
- `volume(activeSourceMaster - preparedMaster) <= 0.01 mm3` and added
  post/gate/vent-landing volume is positive;
- prepared master exists only in prepared mode;
- post is connected, topology-valid, and non-circular;
- cross-pin bore is complete after file serialization;
- every production-vent former is a separate serialized artifact with a matching
  prepared-master landing and shell sleeve;
- every changed surface point is inside the union of typed modification regions;
- approval signature changes when any region/source/dimension changes and exact
  approval is required before package export;
- serialized prepared-master volume differs from planned volume by at most
  `max(0.01 mm3, 0.01%)`;
- no safe patch produces an actionable blocking error, never a tiny post;
- manual patch changes real geometry and deterministic hash.

### 17.2 Fixture

- collar/yoke constrain all rigid-body degrees of freedom geometrically;
- configured post/collar clearance is measured;
- six-DOF sweep meets translation/angular limits and finds no yoke side escape;
- cross-pin passes through both yoke ears and post;
- all separate vent rods remove first, then pin/yoke/shell/master release succeeds
  in exact order; changing the order fails collision/release proof;
- supported profile's combined wrench utilization is at most 1.0 over every fill
  state; unsupported profile produces `geometry only`, never `hold-down verified`;
- seal land is connected and survives all later stages;
- socket mode is explicitly classified locator-only;
- external mode exports no fake fixture artifact.
- locator-only cannot pass a production-positive test unless mass, center of
  gravity, footprint, uplift, and tipping gates all pass.

### 17.3 Liner registration

- 2-part organic fixture: exactly four buttons plus gate lip;
- 4-part organic fixture: exactly eight buttons plus gate lip;
- pattern is non-clustered and deterministic;
- each button belongs to one shell part and follows its demold axis;
- housings preserve wall thickness;
- removal of any final button blocks export;
- `none` produces no hidden registration and a recorded warning.
- exact trim volumes transform as-poured liner into production liner;
- all reseat, button, lip, collision, and funnel-seal assertions run against the
  production liner, not the untrimmed as-poured state.

### 17.4 Flow

- liner-fill path reaches as-poured liner under `uL` but is not mistaken for production
  cavity access;
- production gate reaches empty liner cavity after virtual master removal;
- casting-funnel insert seats in the receiver, reaches the liner gate, and
  releases its drafted sprue;
- cross-pin/stop produces configured gate-seal compression without folding the
  liner or intruding into the art cavity;
- liner-fill vents receive no credit toward casting high-region coverage;
- every required production high region is served by the gate or one verified
  production vent, and zero vents requires an explicit no-trap measurement;
- persistence/trapped-volume thresholds and stable tie-breaks produce identical
  regions and rods across triangle ordering/destination changes;
- every vent rod has an outward serialized removal sweep before master motion;
- physical-master mode emits sleeves/placement evidence and labels artist
  confirmation as required rather than claiming a software-verified rod;
- anchor-as-gate and separate-gate modes both have exact contracts;
- requested vents terminate in likely liner-fill air traps;
- trimming instructions identify one-time nubs versus permanent gate.

### 17.5 Supports and manufacturing qualification

- `uL` and `uC` are independently persisted and changing either invalidates the
  applicable fill/flow/support evidence;
- empty-to-full silicone/casting states move mass/center as expected and the
  worst state, not merely the empty shell, controls support status;
- shell-only stable cases meet support polygon and 10-degree tilt gates for
  every state;
- unstable cases generate exact phase cradle artifacts with unobstructed ports,
  hardware, and demold paths;
- unknown center of gravity cannot silently pass a bare-shell stability test;
- supported cradle profile passes vertical, lateral, overturning, strap, and
  contact-load interaction; unknown/undersized profile says `support geometry
  only` and cannot satisfy release;
- with an active printer profile, every manufacturing artifact fits the build
  volume in its recommended orientation and satisfies profile minimum-feature
  checks; without one, status is exactly `printer fit not checked`.

### 17.6 Export and persistence

- prepared build ZIP has exact directory/member set and roles, with one manifest
  record for every non-manifest member and no undeclared, duplicate, absolute,
  or traversal path;
- prepared master, yoke, casting funnel, vent rods, and required cradles are
  present, topology-valid, and independently watertight;
- liner references are marked reference-only;
- every non-manifest archive member has one `PackageMember`; text/CSV/source
  members have no fake geometry metrics, and outer evidence hashes the manifest;
- manifest hashes match bytes;
- missing or extra members fail before write success;
- combined OBJ is labeled reference-only;
- laid-out STL is unavailable for prepared builds;
- v2 project decodes without geometry change;
- known legacy raw values/CLI aliases remain accepted and existing
  `mold-part-A...D.stl` names remain stable;
- explicit upgrade changes contract version and stale signature;
- missing legacy settings receive migration defaults, while a present malformed
  or unknown enum/type throws instead of reaching a `try?` fallback;
- two independent processes, different output directories, identical
  fixture/settings/seed reproduce member hashes, manifest bytes, canonical
  evidence hash, and ZIP bytes;
- destination path and timestamps do not perturb canonical evidence;
- unknown project versions/enums and unknown headless flags fail explicitly.
- archives near and over legacy ZIP size limits take the intended ZIP64 or
  preflight-rejection path.
- the independent Python audit dispatches by manifest role; it must not treat a
  prepared master, yoke, guide, or reference mesh as a rigid shell part.
- every public export route, including the former direct `writeZip(plan:)` call,
  reaches the same authoritative validator; an intentionally invalid plan is
  rejected through every entry point.
- self-contained HTML references only declared local members; required exact
  setup/trim renders are present, current, and hash-matched.

### 17.7 UI contract

- all new controls have help;
- source/retention choices reveal only applicable controls;
- prepared master modification is visible before export;
- every typed modification region is visible and one approval command signs the
  exact final set;
- Build Status separates master, liner, shell, and both flow paths;
- Build Status distinguishes geometry retention, load qualification, support,
  printer-profile fit, and external shop responsibilities;
- Explode remains reversible and export-invariant;
- Export lists every package artifact;
- viewport, physical exterior labels where feasible, HTML guide, hardware CSV,
  and manifest use identical stable artifact IDs;
- every blocking state presents at least one real action.

## 18. Fixture and physical evidence matrix

### 18.1 Software fixtures

Required fixtures:

- current healed organic hand, 2-part and 4-part;
- bust with broad sacrificial neck/base;
- asymmetric vessel with a flat foot;
- thin organic form with no acceptable auto mount patch;
- hollow watertight master for worst-case uplift;
- cantilevered master whose center of buoyancy creates large bending/torsion;
- tool whose empty support passes but whose partial/full fluid center crosses the
  bare-shell support margin;
- dense scan accepted through current healer-grade entry gate;
- symmetric master that requires anti-rotation proof;
- deliberately disconnected/invalid master;
- fixture where liner buttons compete with seam, vent, and bolt regions;
- fixture where a continuous gate lip would be rigidly trapped.

Add the tracked healed-hand fixtures to `tests/fixtures/MANIFEST.md` with face
counts and SHA-256. Add `tests/fixtures/organic/lumpy_blob.stl` to MotherMold
coverage as a difficult negative/placement case; it currently has no MotherMold
test coverage.

Every gate runs on at least one organic fixture. Cube/sphere tests are helper
tests only.

### 18.2 Software evidence

The canonical jacket matrix has eight positive rows:

```text
{low_poly_head, handStand_ex3_ui_healed}
  x {2-part, 4-part}
  x {prepared printed master, existing physical master with defined external hold-down}
```

Prepared rows require every new artifact and gate. The positive physical-master
rows use a modeled fixture with declared restraint directions and load capacity;
they require explicit `not applicable` prepared-master/yoke fields rather than
zero values that look like failed measurements. Locator-only is not a positive
row. Test it separately as:

- a passing conditional case only when measured mass, center of gravity,
  footprint, uplift, and tipping stability all pass; and
- a light/hollow failing case that says external hold-down is required.

Add the lumpy blob as the blocked-auto-placement diagnostic case and the healed
50k hand as a legacy compatibility sentinel. Run the unchanged rigid
casting-shell subtype in 2- and 4-part compatibility rows; prepared master,
liner registration, and liner-fill evidence must be explicit `not applicable`
there.

Store each case under:

```text
build/mothermold-prepared-master/matrix/<case>/
  package.zip
  measurement.json
  audit.json
  hashes.json
  assembled.png
  prepared-master-difference.png
  anchor.png
  as-poured-liner.png
  production-liner.png
  liner-registration.png
  flow-paths.png
  liner-fill-support.png
  casting-support.png
  exploded.png
```

The final report is
`docs/reports/mothermold-prepared-master-<date>.md`.

For every subtype-relevant part-count/fixture row, record:

- source/prepared topology, typed modification regions/approval signature, and
  source-preservation distance/area outside their union;
- selected patch and score;
- post/collar/yoke dimensions and retained fractions;
- collision and clearance values;
- empty-to-full force/moment history, worst combined wrench, six-DOF play, and
  wrench-envelope qualification;
- exact liner button count/sites/backing/retention;
- gate-lip split/release proof;
- as-poured/production-liner topology, volume, and exact trim delta;
- independent liner-fill and production-gate connectivity;
- separate liner-fill/casting orientations and support margins; required
  persistent high-region count, removable production-vent coverage/sequences,
  and casting-funnel seat/throat/seal/release measurements;
- all existing shell/flange/bolt/key/vent/component/watertight gates;
- serialized artifact metrics, member hashes, manifest audit, and ZIP hash;
- assembled, prepared-master-difference, as-poured-liner, production-liner,
  both support phases, exploded, isolated, and restored screenshots.

### 18.3 Physical release gate

Create `docs/physical-validation-mothermold.md` as a shop runbook and result
form. It records master mass/center of gravity, silicone/casting density,
fill-progress displaced volume/center of buoyancy, force/moment wrench, support
center envelope/reactions, observed displacement over working time, leakage,
liner reseating, and production-fill behavior. A physical pass is a measured
artifact, not a sentence in the software report.

Before production-ready language:

1. Print one 2-part and one 4-part organic tool, including prepared masters,
   yokes, funnel inserts, vent rods, and required cradles, using declared
   printer/material/layer profiles.
2. Run at least one unmodified physical-positive tool with a modeled external
   hold-down whose directions/capacity pass; separately demonstrate that the
   light/hollow locator-only setup is rejected.
3. Test at least two silicone hardnesses spanning approximately Shore A10-A30.
4. Qualify each hold-down profile/geometry family with at least three destructive
   specimens per governing combined-wrench case, rate each interaction component
   at no more than half the lowest ultimate result, then hold each actual tool
   at `1.25 * worstDesignWrench` with simultaneous axial, shear, bending, and
   torsion for the greater of 30 minutes or silicone working time. Record
   permanent displacement (maximum 0.10 mm), crack/delamination, pin/yoke escape,
   hardware slip, and envelope version.
5. Calibrate each cradle/strap profile family with at least three specimens per
   governing combined-load case, rate it at no more than half the lowest
   ultimate interaction, and proof each actual cradle for the greater of 30
   minutes or phase working time at 1.25 times its worst full-phase vertical,
   lateral, overturning, strap, and contact reactions. Allow no slip, crack,
   delamination, hardware escape, or more than 0.10 mm permanent displacement.
6. Place both phase assemblies in their specified supports, verify every
   empty-to-full center state remains inside the required margin with fill/vent
   access, then fill the complete liner volume with a hollow/light
   master and verify translation no greater than 0.25 mm and rotation no greater
   than 1 degree at measured fiducials.
7. Observe no leak through the collar or shell for the silicone's full working
   time.
8. Pull every vent rod first, then remove fixture/shell/master in the generated
   order; inspect every production gate/vent and art surface for tear or
   unintended marks. Any alternate forced sequence fails.
9. Perform the generated trim map and compare the real production liner with
   reference fiducials. Open/reseat the liner 20 times. At cycle 20:
   - every registration feature remains intact;
   - shell closes without force;
   - liner fiducials return within 0.5 mm of baseline;
   - no fold or unseated lip remains hidden at closure.
10. Produce at least 10 gravity-fed castings from one liner using the declared
   resin/plaster process profile. Compare seam/gate fiducials;
   progressive registration drift or flash over 0.5 mm fails.
11. On each casting, verify no leak passes behind the liner or through the pinned
   funnel/liner seal, the funnel releases without damaging its receiver or
   liner gate, and every required production vent passes air/material; any
   repeatable trapped-air void fails.
12. Record materials, print process, layer orientation, hardware, release,
   sealant, cure, photographs, and measured results in the release report.

Physical failure sends the design back to geometry/UX work. It is not converted
to a documentation disclaimer.

## 19. Milestones and stop lines

### M0 - Contract and red tests

- Ratify P1-P10.
- Freeze v2 output hashes and current hand evidence.
- Add missing-behavior red tests and fixture metadata.

Stop line: no new geometry before red tests prove the intended gaps.

### M1 - First-class prepared master and package skeleton

- Strict settings/persistence migration with malformed-present-value rejection.
- Immutable source + prepared artifact.
- Manufacturing ZIP, `PackageMember` manifest, sole validated writer, and
  prepared-master export.
- UI difference preview and package contents.

Gate: a simple prepared master is topology-valid and included; no fixture or
printer-profile claim yet.

### M2 - Mechanical post/collar/yoke

- Auto/manual patch selection, typed modification regions, and approval signature.
- Anchor/gate post, collar, shutoff, seal land, yoke, cross-pin evidence.
- Shared yoke/funnel receiver and drafted casting-funnel insert.
- Six-DOF sweep, scale/hardware selection, fill-progress force/moment wrench, and
  calibrated combined-wrench envelope status.

Gate: organic prepared master is source-preserved, approved, geometrically
retained, and load-qualified for at least one supported print profile.

### M3 - Reusable liner registration

- As-poured liner, exact trim map, and production liner.
- Per-part buttons/housings and captured gate lip.
- Exact transactional counts and release/backing gates.

Gate: liner registration passes 2/4-part organic fixtures with no partial output.

### M4 - Dual flow workflow

- Rename current path and vents to liner fill/liner vents.
- Anchor-as-production-gate, casting-funnel insert, separate-gate fallback, and
  independent removable production-vent rods/persistent-high-region coverage.
- Separate liner-fill/casting orientations, support polygon checks, and generated
  phase cradles with fluid-inclusive support-load qualification.
- Correct trimming, first-liner, repeat-cast, and remake-liner guide steps.

Gate: both phase paths independently connect, every rod/master removal sequence
passes, and each working orientation has verified support.

### M5 - Complete artist UX and compatibility

- Master & Reuse inspector, Layers, status, errors, export inventory.
- Legacy migration/upgrade UI.
- Headless flags and measurement schema.

Gate: an artist can identify every manufacturing part, fixture action, liner key, fill
path, casting path, and external responsibility without engineering details.

### M6 - Full software evidence

- Focused/broad tests, deterministic matrix, serialized audits, screenshots,
  assembly guide, package/app build.

Stop line: no physical release candidate with a red software gate.

### M7 - Physical validation and release decision

- Complete section 18.3.
- Record failures and corrections.
- Re-run full software and physical evidence after final geometry change.

Stop line: do not call the feature reusable or production-ready until physical
reseating/casting gates pass.

## 20. Worked example: current four-part hand

Known current settings/evidence:

- 4 rigid parts;
- 6 mm silicone clearance;
- 4 mm shell wall;
- generated socket footprint approximately 914.5 mm2;
- 8 shell key pairs;
- 4 flanged interfaces and 16 bolt holes;
- 2 liner-fill vents.

Illustrative v3 automatic result, subject to real candidate measurements:

1. Auto selects the broad sacrificial hand/wrist base patch and highlights it.
2. A 12 mm round gate root transitions outside the liner to an approximately
   18 x 13.5 mm rounded-D post.
3. Total post length is derived from 6 mm liner + 4 mm shell + collar allowance
   + at least 18 mm free length.
4. Auto selects M4/M5/M6 through-hardware and post/yoke dimensions only after
   the chosen profile's combined axial/shear/bending/torsion wrench envelope
   passes; this illustration does not preselect M4.
5. The split collar supplies a 10 mm seal land.
6. Eight liner buttons are requested: two per final rigid part. At 6 mm liner
   offset, defaults are 15 mm diameter and 3.6 mm depth with 12-degree draft.
7. One split gate lip registers and retains the liner at the production gate.
8. `LINER FILL` remains the one-time silicone path; the post-root opening is
   labeled `CAST HERE` after master removal, and production vents are labeled
   separately from liner-fill vents.
9. Required production vents use separate outward-removable rods between
   approved prepared-master landings and shell sleeves; rods come out before
   the shell or master moves.
10. The yoke is used only for liner creation. A drafted casting-funnel insert
   occupies the same collar receiver for repeated casting.
11. Liner-fill and casting orientations are evaluated independently; one or two
    cradle meshes are added if the final shell lacks a stable support polygon.
12. Export reports `7 + N` base manufacturing meshes: four shell parts, prepared
    master, hold-down yoke, casting funnel, and N vent rods, plus required
    cradles, guide, and manifest.

If the candidate patch is not genuinely sacrificial or the post route is not
clear, this example must fail to manual placement rather than alter the fingers,
face, or another visible art surface.

## 21. Release acceptance criteria

The feature is complete only when all are true:

- The imported source remains immutable and recoverable.
- Every generated positive modification is visible, measured, persisted, and
  approved as a typed region set and exported as the prepared master.
- Prepared mode passes six-DOF retention and a calibrated combined-wrench
  envelope for the selected manufacturing profile; locator-only modes are named honestly and do
  not populate the green positive matrix without full stability evidence.
- The reusable silicone liner has measured, complete registration independent
  of shell-part keys, and all reuse gates run on the exact trimmed production
  liner.
- First-liner and repeated-casting fluid paths are separate and verified;
  production trapped-air regions are served by independently verified casting
  vents rather than the one-time liner-fill vents.
- Both working orientations remain stable over their complete empty-to-full mass
  envelopes, with exported cradles/straps load-qualified when required.
- The manufacturing ZIP contains every manufacturing tooling artifact and no
  mislabeled reference geometry, and every public export route uses one
  authoritative validator.
- GUI, project, headless, manifest, guide, and file bytes express one contract.
- Existing v2 projects preserve their output unless explicitly upgraded.
- Organic software fixtures and serialized audits are green.
- The physical load, support, ordered-removal, leakage, 20-reseat, and
  10-gravity-casting gates pass for the declared process profiles.

Until then, the feature may be described as an inspectable prototype, not a
proven reusable production mold system.
