# MotherMold Engine Contract

This file began as the frozen public surface for scaffold task A1. The engine is
now implemented, so current product and geometry decisions in
`docs/mothermold-v2-decisions.md` supersede historical scaffold wording and any
signature excerpts that no longer match source. Every file is under
`app/RefabArtist/Sources/RefabArtist/`.

Hard rules these signatures encode:
- No marching cubes / isosurface / SDF surface extraction anywhere. Silicone
  offset uses `ManifoldEngine.minkowskiSum`. `MeshHealer` / `MeshModifier.shrinkwrap`
  / `ManifoldEngine.levelSet` are banned in MotherMold code.
- A closed master is required. Strict `MeshPreflight` output is accepted, and a
  closed healer-grade mesh independently accepted by Manifold may enter the
  pipeline. Open or non-manifold masters still fail loudly.
- All geometry must be correct on concave / multi-loop cross-sections.
- Deterministic from `MotherMoldSettings.seed`.

---

## Module ownership

| File | Leaf module | Owns |
|------|-------------|------|
| `MotherMoldSettings.swift` | settings + reused Partition value types | all Codable settings, `MoldSubtype`/`MoldPartCount`/`PartingMode`/`MoldPackaging`/`MoldSpoutMode`, `PartingSettings`/`FlangeSettings`/`SpoutSettings`, and the reused `PartitionPlane`/`PartitionKeyType`/`PartitionKeySettings` (temporary copies until the Partition branch lands) |
| `MotherMoldPlanner.swift` | orchestrator | `MotherMoldPart`, `MoldDiagnostic(+Severity)`, `MotherMoldPlan`, `MotherMoldPlannerError`, `MotherMoldPlanner` |
| `MoldCavityBuilder.swift` | cavity stage | conformal passthrough / silicone Minkowski offset |
| `MoldShellBuilder.swift` | shell stage | `MoldShellBuilder.ShellResult`, thicken+open+floor |
| `MoldPartitioner.swift` | partition stage | `MoldPartitioner.PartitionResult`, plane resolution + split |
| `MoldUndercutAnalyzer.swift` | undercut stage | `UndercutRegion`/`PartUndercutReport`/`UndercutSummary`, ray-probe |
| `MoldKeyBuilder.swift` | keys stage | `MoldKeyBuilder.KeyResult`, wraps `PartitionKeys.capInterface` |
| `MoldFlangeBuilder.swift` | flange stage | `MoldFlangeBuilder.FlangeResult`, rim + bolt holes |
| `MoldFeatureBuilder.swift` | feature stage | `MoldFeatureBuilder.FeatureResult`, spout + vent bores |
| `MotherMoldValidation.swift` | validation gate | `MotherMoldValidation.ValidationResult`, per-part watertight/finite |
| `MotherMoldExporter.swift` | export | STL/OBJ/zip/plate + assembly map |
| `ManifoldEngine.swift` (edited) | boolean backend | new `difference`/`minkowskiSum`/`trimByPlane`/`splitByPlane` wrappers |

---

## ManifoldEngine.swift — new wrappers (REAL implementations)

```swift
static func difference(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle
static func minkowskiSum(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle
static func trimByPlane(_ h: ManifoldHandle, normal: Vec3, offset: Double) throws -> ManifoldHandle
static func splitByPlane(_ h: ManifoldHandle, normal: Vec3, offset: Double) throws -> (ManifoldHandle, ManifoldHandle)
```

- `difference(a, b)` = `a - b` (spout/vent bores, flange bolt holes).
- `minkowskiSum(a, b)` = silicone outward offset (sum decimated master with a sphere).
- `trimByPlane` keeps `dot(point, normal) <= offset`. Do not rely on the older
  wrapper comment that described this sign incorrectly.
- `splitByPlane` returns `(keepSide, otherSide)` matching `manifold_split_by_plane`; either may be empty.

---

## MotherMoldSettings.swift

### Reused Partition value types (temporary copies)

```swift
struct PartitionPlane: Codable, Equatable, Identifiable {
    var id: UUID
    var normalX, normalY, normalZ: Double
    var offset: Double
    var isManual: Bool
    init(id: UUID = UUID(), normal: Vec3, offset: Double, isManual: Bool)
    var normal: Vec3 { get }
    var axisAligned: Int? { get }   // 0/1/2 or nil
}

enum PartitionKeyType: String, CaseIterable, Identifiable, Codable {
    case none, pins, dovetail
    var id: String { get }
    var label: String { get }
}

struct PartitionKeySettings: Codable, Equatable {
    var type: PartitionKeyType
    var pinDiameter: Double      // default 6.0
    var pinLength: Double        // default 8.0
    var tolerance: Double        // default 0.2
    var pinsPerSeam: Int         // default 2
    var edgeMargin: Double       // default 3.0
    static let defaultValue: PartitionKeySettings
    var allowance: Double { get }
    var sanitized: PartitionKeySettings { get }
}
```

### MotherMold enums

```swift
enum MoldSubtype: String, CaseIterable, Identifiable, Codable, Sendable {
    case siliconeJacket, slipShell
    var id: String { get }
    var label: String { get }
    var enforcesUndercuts: Bool { get }   // true for slipShell
    var usesSiliconeGap: Bool { get }     // true for siliconeJacket
}

enum MoldPartCount: String, CaseIterable, Identifiable, Codable, Sendable {
    case two, four
    var id: String { get }
    var label: String { get }
    var planeCount: Int { get }           // 1 / 2
}

enum PartingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, manual
    var id: String { get }; var label: String { get }
}

enum MoldPackaging: String, CaseIterable, Identifiable, Codable, Sendable {
    case separateZip, combinedObj, laidOutPlate
    var id: String { get }; var label: String { get }
}

enum MoldSpoutMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, manual
    var id: String { get }; var label: String { get }
}
```

### Sub-settings (all Codable with `decodeIfPresent ?? default` migration)

```swift
struct PartingSettings: Codable, Equatable, Sendable {
    var mode: PartingMode
    var planes: [PartitionPlane]          // sized to MoldPartCount.planeCount
    static let defaultValue: PartingSettings   // .auto, []
    init(mode: PartingMode = .auto, planes: [PartitionPlane] = [])
}

struct FlangeSettings: Codable, Equatable, Sendable {
    var enabled: Bool                     // default true
    var width: Double                     // default 12.0 mm
    var thickness: Double                 // default 6.0 mm
    var boltHoleCount: Int                // default 4
    var boltDiameter: Double              // default 4.0 mm
    static let defaultValue: FlangeSettings
    var sanitized: FlangeSettings { get }
    init(enabled: Bool = true, width: Double = 12.0, thickness: Double = 6.0,
         boltHoleCount: Int = 4, boltDiameter: Double = 4.0)
}

struct SpoutSettings: Codable, Equatable, Sendable {
    var mode: MoldSpoutMode               // default .auto
    var spoutDiameter: Double             // default 12.0 mm
    var ventCount: Int                    // default 2
    var ventDiameter: Double              // default 2.0 mm
    var manualSpoutX, manualSpoutY, manualSpoutZ: Double   // manual mode only
    static let defaultValue: SpoutSettings
    var manualSpout: Vec3 { get }
    var sanitized: SpoutSettings { get }
    init(mode: MoldSpoutMode = .auto, spoutDiameter: Double = 12.0, ventCount: Int = 2,
         ventDiameter: Double = 2.0, manualSpoutX: Double = 0, manualSpoutY: Double = 0, manualSpoutZ: Double = 0)
}
```

### Top-level settings

```swift
struct MotherMoldSettings: Codable, Equatable, Sendable {
    var subtype: MoldSubtype              // default .slipShell
    var parts: MoldPartCount             // default .two
    var wallThickness: Double            // default 4.0 mm
    var siliconeGap: Double              // default 6.0 mm (silicone only)
    var smoothing: Double                // default 3.0 mm (silicone only)
    var floor: Bool                      // default false
    var floorThickness: Double           // default 4.0 mm
    var parting: PartingSettings
    var key: PartitionKeySettings
    var flange: FlangeSettings
    var spout: SpoutSettings
    var draftAngle: Double               // legacy decode compatibility only; no UI/CLI control
    var packaging: MoldPackaging         // default .separateZip
    var includeAssemblyMap: Bool         // default true
    var seed: Int                        // default 0
    static let defaultValue: MotherMoldSettings
    var sanitized: MotherMoldSettings { get }
    init(...all fields with defaults above...)
}
```

---

## MotherMoldPlanner.swift — shared result types + orchestrator

```swift
struct MotherMoldPart: Equatable {
    var name: String                     // STL solid / OBJ object / assembly label
    var geometry: MeshGeometryData
    var isWatertight: Bool               // stamped by MotherMoldValidation
    var bounds: Bounds3D?
    init(name: String, geometry: MeshGeometryData, isWatertight: Bool = false, bounds: Bounds3D? = nil)
}

enum MoldDiagnosticSeverity: String, Equatable, Sendable { case info, warning, error }

struct MoldDiagnostic: Equatable {
    var severity: MoldDiagnosticSeverity
    var message: String
    init(_ severity: MoldDiagnosticSeverity, _ message: String)
}

struct MotherMoldPlan: Equatable {
    var parts: [MotherMoldPart]
    var partingPlanes: [PartitionPlane]
    var cavity: MeshGeometryData
    var master: MeshGeometryData
    var diagnostics: [MoldDiagnostic]
    static let empty: MotherMoldPlan
    var exportLayers: [SliceMeshExportLayer] { get }   // one layer per part
}

enum MotherMoldPlannerError: LocalizedError, Equatable {
    case masterNotWatertight, emptyMaster
    case cavityFailed(String), shellFailed(String), partitionFailed(String)
}

enum MotherMoldPlanner {
    static func planThrowing(model: MeshSummary, settings rawSettings: MotherMoldSettings) throws -> MotherMoldPlan
    static func plan(model: MeshSummary, settings: MotherMoldSettings) -> MotherMoldPlan   // soft-failure
}
```

Pipeline order inside `planThrowing`: closed-master gate -> `MoldCavityBuilder`
-> `MoldShellBuilder` -> `MoldMasterMountBuilder` -> `MoldPartitioner`
(resolve + split) -> `MoldUndercutAnalyzer` -> `MoldFlangeBuilder` ->
`MoldFeatureBuilder` -> `MoldKeyBuilder` -> proof-based final repair ->
component and topology validation. Keys run after every intentional subtractive
feature so their final survival can be measured honestly.

---

## MoldCavityBuilder.swift

```swift
enum MoldCavityBuilder {
    static func buildCavity(master: MeshGeometryData, settings: MotherMoldSettings) throws -> MeshGeometryData
}
```
- `slipShell`: returns `master` verbatim.
- `siliconeJacket`: Minkowski-with-sphere outward offset by `siliconeGap` (+ `smoothing`) on a decimated master.

---

## MoldShellBuilder.swift

```swift
enum MoldShellBuilder {
    struct ShellResult: Equatable {
        var solid: MeshGeometryData
        var openPlane: PartitionPlane
        var diagnostics: [MoldDiagnostic]
        static let empty: ShellResult
    }
    static func buildShell(cavity: MeshGeometryData, cavitySummary: MeshSummary, settings: MotherMoldSettings) throws -> ShellResult
}
```
Builds a closed shell outside the complete cavity. `openPlane` is retained as a
legacy/reference name for fill-direction placement; it does not truncate the
artwork. A controlled sacrificial fill channel is added later.

---

## MoldPartitioner.swift

```swift
enum MoldPartitioner {
    struct PartitionResult: Equatable {
        var planes: [PartitionPlane]
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]
        static let empty: PartitionResult
    }
    static func resolvePlanes(shell: MeshGeometryData, settings: MotherMoldSettings) -> [PartitionPlane]
    static func partition(shell: MeshGeometryData, planes: [PartitionPlane], settings: MotherMoldSettings) throws -> PartitionResult
}
```
`resolvePlanes` returns exactly `settings.parts.planeCount` planes (auto heuristic or manual). `partition` is island-aware (concave-safe).

---

## MoldUndercutAnalyzer.swift

```swift
enum MoldUndercutAnalyzer {
    struct UndercutRegion: Equatable { var point: Vec3; var demoldAxis: Vec3; var depth: Double }
    struct PartUndercutReport: Equatable {
        var partName: String; var demoldAxis: Vec3
        var regions: [UndercutRegion]; var isDemoldable: Bool
        static func clean(partName: String, demoldAxis: Vec3) -> PartUndercutReport
    }
    struct UndercutSummary: Equatable {
        var reports: [PartUndercutReport]; var diagnostics: [MoldDiagnostic]
        static let empty: UndercutSummary
    }
    static func analyze(parts: [MotherMoldPart], demoldAxes: [Vec3], cavity: MeshGeometryData, settings: MotherMoldSettings) -> UndercutSummary
}
```
Local cavity-normal analysis is supplemented by a translated positive-volume
collision sweep along each rigid part's pull axis. Missing or failed rigid proof
is an error; silicone-jacket guidance remains informational. Concave organic
masters are required fixtures.

---

## MoldKeyBuilder.swift

```swift
enum MoldKeyBuilder {
    struct KeyResult: Equatable {
        var parts: [MotherMoldPart]; var diagnostics: [MoldDiagnostic]
        static let empty: KeyResult
    }
    static func applyKeys(parts: [MotherMoldPart], planes: [PartitionPlane], key: PartitionKeySettings) throws -> KeyResult
}
```
Builds 8-degree tapered round or tapered bar Manifold solids on every physical
part-pair interface. Male union and tolerance-enlarged female pocket difference
are transactional. Final survival is probed at five engagement depths. Missing
requested pairs block export. No-op when `key.type == .none`.

---

## MoldFlangeBuilder.swift

```swift
enum MoldFlangeBuilder {
    struct FlangeResult: Equatable {
        var parts: [MotherMoldPart]; var diagnostics: [MoldDiagnostic]
        static let empty: FlangeResult
    }
    static func applyFlanges(parts: [MotherMoldPart], planes: [PartitionPlane], flange: FlangeSettings, seed: Int) throws -> FlangeResult
}
```
Flange plates are built on both sides of every physical part-pair interface;
four parts cut by two planes therefore require four interfaces and eight
part-side plates. Bolt-hole cylinders are subtracted via
`ManifoldEngine.difference`. A bolt hole keeps its radius plus half the flange
thickness plus 1 mm clear of every neighbouring parting plane, because the part
also carries that plane's plate and it would otherwise fill the hole again.
No-op when `flange.enabled == false`.

---

## MoldFeatureBuilder.swift

```swift
enum MoldFeatureBuilder {
    struct FeatureResult: Equatable {
        var parts: [MotherMoldPart]
        var spoutLocation: Vec3?
        var ventLocations: [Vec3]
        var diagnostics: [MoldDiagnostic]
        static let empty: FeatureResult
    }
    static func applyFeatures(parts: [MotherMoldPart], cavity: MeshGeometryData, openPlane: PartitionPlane, spout: SpoutSettings, seed: Int) throws -> FeatureResult
}
```
Both subtypes receive one exterior funnel and narrow sacrificial fill channel
owned by one part, plus requested vents. Automatic placement avoids parting
planes and neighboring parts. On a flat or low-poly top it also tries the
points where the top centre is stepped off each parting plane far enough for
the funnel rim (1.5 spout diameters) to clear the seam's flange plate. Manual
seam placement is rejected transactionally without carving either mold part.

---

## MotherMoldValidation.swift

```swift
enum MotherMoldValidation {
    struct ValidationResult: Equatable {
        var parts: [MotherMoldPart]      // isWatertight/bounds populated
        var diagnostics: [MoldDiagnostic]
        var allPartsWatertight: Bool
        static let empty: ValidationResult
    }
    static func validate(parts: [MotherMoldPart]) -> ValidationResult   // REAL: runs MeshPreflight per part
    static func hasFiniteCoordinates(_ geometry: MeshGeometryData) -> Bool   // REAL
}
```

---

## MotherMoldExporter.swift

```swift
enum MotherMoldExporter {
    enum ExportError: LocalizedError, Equatable { case emptyPlan, unsupportedFormat(String) }
    static func write(plan: MotherMoldPlan, settings: MotherMoldSettings, modelName: String, to url: URL) throws
    static func writeZip(plan: MotherMoldPlan, modelName: String, to url: URL) throws
}
```
`.combinedObj` → `ObjExporter.write(meshLayers:)`; `.laidOutPlate` → `StlExporter.write(meshes:)`; `.separateZip` → one STL per part via `ZipWriter`.

---

## Shared wiring

These shared files contain the current `.motherMold` wiring:
`ConstructionMode.swift`, `ExportFormatSupport.swift`, `SlicerProjectDocument.swift`,
`ContentView.swift`, `InspectorPanelSection.swift`, and
`HeadlessExportCommand.swift`. The GUI exposes packaging, Build Status,
reversible Explode/Inspect interior, part isolation, optional undercut markers,
and collapsed engineering details. Headless MotherMold uses artist-facing key
names and rejects unknown values.
