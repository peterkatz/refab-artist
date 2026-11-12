import Foundation


// MARK: - MotherMold enums

/// Mold subtype. `siliconeJacket` is a rigid mother mold whose cavity is the
/// master offset outward by a silicone gap and smoothed (the silicone fills the
/// gap and captures detail against the master). `slipShell` is a conformal rigid
/// casting shell whose cavity equals the master exactly. The raw value is kept
/// for project compatibility; printed plastic is not an absorbent ceramic mold.
enum MoldSubtype: String, CaseIterable, Identifiable, Codable, Sendable {
    case siliconeJacket
    case slipShell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .siliconeJacket: return "Silicone mold + shell"
        case .slipShell: return "Rigid mold"
        }
    }

    /// Silicone flexes off undercuts, so undercut detection is informational;
    /// the rigid casting shell must demold cleanly, so undercuts are enforced.
    var enforcesUndercuts: Bool { self == .slipShell }

    /// Only the silicone jacket uses the gap + smoothing offset stage.
    var usesSiliconeGap: Bool { self == .siliconeJacket }
}

/// Requested mold-part count. `two` splits on one plane; `four` splits on two
/// orthogonal planes.
enum MoldPartCount: String, CaseIterable, Identifiable, Codable, Sendable {
    case two
    case four

    var id: String { rawValue }

    var label: String {
        switch self {
        case .two: return "2-part (one parting plane)"
        case .four: return "4-part (two orthogonal planes)"
        }
    }

    /// Number of parting planes implied by the part count.
    var planeCount: Int {
        switch self {
        case .two: return 1
        case .four: return 2
        }
    }
}

/// How the parting plane(s) are chosen.
enum PartingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual axis / offset"
        }
    }
}

/// How the exported parts are packaged.
enum MoldPackaging: String, CaseIterable, Identifiable, Codable, Sendable {
    case manufacturingZip
    case separateZip
    case combinedObj
    case laidOutPlate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manufacturingZip: return "Manufacturing ZIP"
        case .separateZip: return "Separate STLs (zip)"
        case .combinedObj: return "Combined OBJ (one object per part)"
        case .laidOutPlate: return "Laid-out plate (single STL)"
        }
    }
}

/// How the pour spout and air vents are placed.
enum MoldSpoutMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (topmost cavity region)"
        case .manual: return "Manual override"
        }
    }
}

/// How a physical master is located while silicone is poured into a jacket.
/// Rigid-negative/slip-shell output does not use this setting because the master
/// is not present during casting.
enum MasterMountMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case flatBaseSocket
    case externalFixture

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flatBaseSocket: return "Printed base socket"
        case .externalFixture: return "I'll hold it myself"
        }
    }
}

// MARK: - Reusable tooling contract

enum MasterSourceMode: String, Codable, Sendable {
    case preparedPrint
    case existingPhysical
}

enum MasterRetentionMode: String, Codable, Sendable {
    case preparedPost
    case flatBaseSocket
    case externalFixture
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

/// A Sendable persistence representation for points and axes in the reusable
/// tooling contract. `Vec3` remains the geometry engine's native vector type.
struct Vec3Codable: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    var sanitized: Vec3Codable {
        Vec3Codable(
            x: x.isFinite ? x : 0,
            y: y.isFinite ? y : 0,
            z: z.isFinite ? z : 0
        )
    }
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
    /// Declared vertical hold-down capacity for an artist-supplied fixture.
    /// A force scalar does not qualify moment capacity; that remains explicit
    /// in the resulting wrench-envelope status.
    var externalFixtureCapacityNewtons: Double?

    static let defaultValue = MasterPreparationSettings()

    init(
        sourceMode: MasterSourceMode = .preparedPrint,
        retentionMode: MasterRetentionMode = .preparedPost,
        placementMode: MountPlacementMode = .auto,
        manualPoint: Vec3Codable? = nil,
        manualAxis: Vec3Codable? = nil,
        linerFillUpAxis: Vec3Codable? = nil,
        postWidth: Double = 18,
        postThickness: Double = 13.5,
        postFreeLength: Double = 20,
        crossPinDiameter: Double = 4,
        fitClearance: Double = 0.25,
        sealLandWidth: Double = 5,
        masterWeightGrams: Double? = nil,
        masterCenterOfGravity: Vec3Codable? = nil,
        externalFixtureCapacityNewtons: Double? = nil
    ) {
        self.sourceMode = sourceMode
        self.retentionMode = retentionMode
        self.placementMode = placementMode
        self.manualPoint = manualPoint
        self.manualAxis = manualAxis
        self.linerFillUpAxis = linerFillUpAxis
        self.postWidth = postWidth
        self.postThickness = postThickness
        self.postFreeLength = postFreeLength
        self.crossPinDiameter = crossPinDiameter
        self.fitClearance = fitClearance
        self.sealLandWidth = sealLandWidth
        self.masterWeightGrams = masterWeightGrams
        self.masterCenterOfGravity = masterCenterOfGravity
        self.externalFixtureCapacityNewtons = externalFixtureCapacityNewtons
    }

    static func legacyDefault(for masterMount: MasterMountSettings) -> MasterPreparationSettings {
        MasterPreparationSettings(
            sourceMode: .existingPhysical,
            retentionMode: masterMount.mode == .externalFixture ? .externalFixture : .flatBaseSocket,
            fitClearance: masterMount.fitClearance
        )
    }

    var sanitized: MasterPreparationSettings {
        var value = self
        value.manualPoint = manualPoint?.sanitized
        value.manualAxis = manualAxis?.sanitized
        value.linerFillUpAxis = linerFillUpAxis?.sanitized
        value.postWidth = MotherMoldSettings.clamp(postWidth, 1, 100)
        value.postThickness = MotherMoldSettings.clamp(postThickness, 1, 100)
        value.postFreeLength = MotherMoldSettings.clamp(postFreeLength, 1, 150)
        value.crossPinDiameter = MotherMoldSettings.clamp(crossPinDiameter, 1, 30)
        value.fitClearance = MotherMoldSettings.clamp(fitClearance, 0, 2)
        value.sealLandWidth = MotherMoldSettings.clamp(sealLandWidth, 1, 50)
        if let masterWeightGrams {
            value.masterWeightGrams = MotherMoldSettings.clamp(masterWeightGrams, 0, 100_000)
        }
        value.masterCenterOfGravity = masterCenterOfGravity?.sanitized
        if let externalFixtureCapacityNewtons {
            value.externalFixtureCapacityNewtons = MotherMoldSettings.clamp(
                externalFixtureCapacityNewtons,
                0,
                1_000_000
            )
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case sourceMode, retentionMode, placementMode
        case manualPoint, manualAxis, linerFillUpAxis
        case postWidth, postThickness, postFreeLength, crossPinDiameter
        case fitClearance, sealLandWidth, masterWeightGrams, masterCenterOfGravity
        case externalFixtureCapacityNewtons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        sourceMode = try c.motherMoldRequired(MasterSourceMode.self, forKey: .sourceMode, fallback: d.sourceMode)
        retentionMode = try c.motherMoldRequired(MasterRetentionMode.self, forKey: .retentionMode, fallback: d.retentionMode)
        placementMode = try c.motherMoldRequired(MountPlacementMode.self, forKey: .placementMode, fallback: d.placementMode)
        manualPoint = try c.motherMoldOptional(Vec3Codable.self, forKey: .manualPoint)
        manualAxis = try c.motherMoldOptional(Vec3Codable.self, forKey: .manualAxis)
        linerFillUpAxis = try c.motherMoldOptional(Vec3Codable.self, forKey: .linerFillUpAxis)
        postWidth = try c.motherMoldRequired(Double.self, forKey: .postWidth, fallback: d.postWidth)
        postThickness = try c.motherMoldRequired(Double.self, forKey: .postThickness, fallback: d.postThickness)
        postFreeLength = try c.motherMoldRequired(Double.self, forKey: .postFreeLength, fallback: d.postFreeLength)
        crossPinDiameter = try c.motherMoldRequired(Double.self, forKey: .crossPinDiameter, fallback: d.crossPinDiameter)
        fitClearance = try c.motherMoldRequired(Double.self, forKey: .fitClearance, fallback: d.fitClearance)
        sealLandWidth = try c.motherMoldRequired(Double.self, forKey: .sealLandWidth, fallback: d.sealLandWidth)
        masterWeightGrams = try c.motherMoldOptional(Double.self, forKey: .masterWeightGrams)
        masterCenterOfGravity = try c.motherMoldOptional(Vec3Codable.self, forKey: .masterCenterOfGravity)
        externalFixtureCapacityNewtons = try c.motherMoldOptional(
            Double.self,
            forKey: .externalFixtureCapacityNewtons
        )
    }
}

struct LinerRegistrationSettings: Codable, Equatable, Sendable {
    var mode: LinerRegistrationMode
    var buttonsPerPart: Int
    var buttonDiameter: Double
    var buttonDepth: Double
    var buttonDraftDegrees: Double
    var gateLipEnabled: Bool
    var gateLipDepth: Double

    static let defaultValue = LinerRegistrationSettings()

    init(
        mode: LinerRegistrationMode = .automatic,
        buttonsPerPart: Int = 2,
        buttonDiameter: Double = 8,
        buttonDepth: Double = 3,
        buttonDraftDegrees: Double = 8,
        gateLipEnabled: Bool = true,
        gateLipDepth: Double = 3
    ) {
        self.mode = mode
        self.buttonsPerPart = buttonsPerPart
        self.buttonDiameter = buttonDiameter
        self.buttonDepth = buttonDepth
        self.buttonDraftDegrees = buttonDraftDegrees
        self.gateLipEnabled = gateLipEnabled
        self.gateLipDepth = gateLipDepth
    }

    static let legacyDefault = LinerRegistrationSettings(
        mode: .none,
        gateLipEnabled: false
    )

    var sanitized: LinerRegistrationSettings {
        LinerRegistrationSettings(
            mode: mode,
            buttonsPerPart: Swift.min(Swift.max(buttonsPerPart, 0), 12),
            buttonDiameter: MotherMoldSettings.clamp(buttonDiameter, 1, 50),
            buttonDepth: MotherMoldSettings.clamp(buttonDepth, 0.5, 30),
            buttonDraftDegrees: MotherMoldSettings.clamp(buttonDraftDegrees, 0, 20),
            gateLipEnabled: gateLipEnabled,
            gateLipDepth: MotherMoldSettings.clamp(gateLipDepth, 0.5, 30)
        )
    }

    enum CodingKeys: String, CodingKey {
        case mode, buttonsPerPart, buttonDiameter, buttonDepth
        case buttonDraftDegrees, gateLipEnabled, gateLipDepth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        mode = try c.motherMoldRequired(LinerRegistrationMode.self, forKey: .mode, fallback: d.mode)
        buttonsPerPart = try c.motherMoldRequired(Int.self, forKey: .buttonsPerPart, fallback: d.buttonsPerPart)
        buttonDiameter = try c.motherMoldRequired(Double.self, forKey: .buttonDiameter, fallback: d.buttonDiameter)
        buttonDepth = try c.motherMoldRequired(Double.self, forKey: .buttonDepth, fallback: d.buttonDepth)
        buttonDraftDegrees = try c.motherMoldRequired(Double.self, forKey: .buttonDraftDegrees, fallback: d.buttonDraftDegrees)
        gateLipEnabled = try c.motherMoldRequired(Bool.self, forKey: .gateLipEnabled, fallback: d.gateLipEnabled)
        gateLipDepth = try c.motherMoldRequired(Double.self, forKey: .gateLipDepth, fallback: d.gateLipDepth)
    }
}

struct ProductionFlowSettings: Codable, Equatable, Sendable {
    var mode: ProductionFlowMode
    var processProfile: CastingProcessProfile
    var castingUpAxis: Vec3Codable?
    var gateDiameter: Double
    var ventDiameter: Double
    var manualGatePoint: Vec3Codable?
    var manualVentPoints: [Vec3Codable]

    static let defaultValue = ProductionFlowSettings()

    init(
        mode: ProductionFlowMode = .automatic,
        processProfile: CastingProcessProfile = .gravityResin,
        castingUpAxis: Vec3Codable? = nil,
        gateDiameter: Double = 12,
        ventDiameter: Double = 2,
        manualGatePoint: Vec3Codable? = nil,
        manualVentPoints: [Vec3Codable] = []
    ) {
        self.mode = mode
        self.processProfile = processProfile
        self.castingUpAxis = castingUpAxis
        self.gateDiameter = gateDiameter
        self.ventDiameter = ventDiameter
        self.manualGatePoint = manualGatePoint
        self.manualVentPoints = manualVentPoints
    }

    var sanitized: ProductionFlowSettings {
        ProductionFlowSettings(
            mode: mode,
            processProfile: processProfile,
            castingUpAxis: castingUpAxis?.sanitized,
            gateDiameter: MotherMoldSettings.clamp(gateDiameter, 1, 60),
            ventDiameter: MotherMoldSettings.clamp(ventDiameter, 0.5, 20),
            manualGatePoint: manualGatePoint?.sanitized,
            manualVentPoints: manualVentPoints.map(\.sanitized)
        )
    }

    enum CodingKeys: String, CodingKey {
        case mode, processProfile, castingUpAxis, gateDiameter, ventDiameter
        case manualGatePoint, manualVentPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        mode = try c.motherMoldRequired(ProductionFlowMode.self, forKey: .mode, fallback: d.mode)
        processProfile = try c.motherMoldRequired(CastingProcessProfile.self, forKey: .processProfile, fallback: d.processProfile)
        castingUpAxis = try c.motherMoldOptional(Vec3Codable.self, forKey: .castingUpAxis)
        gateDiameter = try c.motherMoldRequired(Double.self, forKey: .gateDiameter, fallback: d.gateDiameter)
        ventDiameter = try c.motherMoldRequired(Double.self, forKey: .ventDiameter, fallback: d.ventDiameter)
        manualGatePoint = try c.motherMoldOptional(Vec3Codable.self, forKey: .manualGatePoint)
        manualVentPoints = try c.motherMoldRequired([Vec3Codable].self, forKey: .manualVentPoints, fallback: d.manualVentPoints)
    }
}

struct SupportPlaneSettings: Codable, Equatable, Sendable {
    var origin: Vec3Codable
    var normal: Vec3Codable

    static let defaultValue = SupportPlaneSettings()

    init(
        origin: Vec3Codable = Vec3Codable(),
        normal: Vec3Codable = Vec3Codable(x: 0, y: 0, z: 1)
    ) {
        self.origin = origin
        self.normal = normal
    }

    enum CodingKeys: String, CodingKey { case origin, normal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        origin = try c.motherMoldRequired(Vec3Codable.self, forKey: .origin, fallback: d.origin)
        normal = try c.motherMoldRequired(Vec3Codable.self, forKey: .normal, fallback: d.normal)
    }

    var sanitized: SupportPlaneSettings {
        SupportPlaneSettings(origin: origin.sanitized, normal: normal.sanitized)
    }
}

struct ToolingSupportSettings: Codable, Equatable, Sendable {
    var mode: ToolingSupportMode
    var minimumSupportMargin: Double
    var manualLinerFillSupportPlane: SupportPlaneSettings?
    var manualCastingSupportPlane: SupportPlaneSettings?

    static let defaultValue = ToolingSupportSettings()

    init(
        mode: ToolingSupportMode = .automatic,
        minimumSupportMargin: Double = 5,
        manualLinerFillSupportPlane: SupportPlaneSettings? = nil,
        manualCastingSupportPlane: SupportPlaneSettings? = nil
    ) {
        self.mode = mode
        self.minimumSupportMargin = minimumSupportMargin
        self.manualLinerFillSupportPlane = manualLinerFillSupportPlane
        self.manualCastingSupportPlane = manualCastingSupportPlane
    }

    enum CodingKeys: String, CodingKey {
        case mode, minimumSupportMargin
        case manualLinerFillSupportPlane, manualCastingSupportPlane
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        mode = try c.motherMoldRequired(ToolingSupportMode.self, forKey: .mode, fallback: d.mode)
        minimumSupportMargin = try c.motherMoldRequired(Double.self, forKey: .minimumSupportMargin, fallback: d.minimumSupportMargin)
        manualLinerFillSupportPlane = try c.motherMoldOptional(SupportPlaneSettings.self, forKey: .manualLinerFillSupportPlane)
        manualCastingSupportPlane = try c.motherMoldOptional(SupportPlaneSettings.self, forKey: .manualCastingSupportPlane)
    }

    var sanitized: ToolingSupportSettings {
        ToolingSupportSettings(
            mode: mode,
            minimumSupportMargin: MotherMoldSettings.clamp(minimumSupportMargin, 0, 100),
            manualLinerFillSupportPlane: manualLinerFillSupportPlane?.sanitized,
            manualCastingSupportPlane: manualCastingSupportPlane?.sanitized
        )
    }
}

struct MoldMaterialSettings: Codable, Equatable, Sendable {
    var siliconeDensityGramsPerCC: Double
    var castingDensityGramsPerCC: Double?
    var upliftSafetyFactor: Double

    static let defaultValue = MoldMaterialSettings()

    init(
        siliconeDensityGramsPerCC: Double = 1.1,
        castingDensityGramsPerCC: Double? = nil,
        upliftSafetyFactor: Double = 3
    ) {
        self.siliconeDensityGramsPerCC = siliconeDensityGramsPerCC
        self.castingDensityGramsPerCC = castingDensityGramsPerCC
        self.upliftSafetyFactor = upliftSafetyFactor
    }

    enum CodingKeys: String, CodingKey {
        case siliconeDensityGramsPerCC, castingDensityGramsPerCC, upliftSafetyFactor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultValue
        siliconeDensityGramsPerCC = try c.motherMoldRequired(Double.self, forKey: .siliconeDensityGramsPerCC, fallback: d.siliconeDensityGramsPerCC)
        castingDensityGramsPerCC = try c.motherMoldOptional(Double.self, forKey: .castingDensityGramsPerCC)
        upliftSafetyFactor = try c.motherMoldRequired(Double.self, forKey: .upliftSafetyFactor, fallback: d.upliftSafetyFactor)
    }

    var sanitized: MoldMaterialSettings {
        MoldMaterialSettings(
            siliconeDensityGramsPerCC: MotherMoldSettings.clamp(siliconeDensityGramsPerCC, 0.1, 10),
            castingDensityGramsPerCC: castingDensityGramsPerCC.map { MotherMoldSettings.clamp($0, 0.1, 20) },
            upliftSafetyFactor: MotherMoldSettings.clamp(upliftSafetyFactor, 1, 10)
        )
    }
}

struct ToolingManufacturingProfileRef: Codable, Equatable, Sendable {
    var printerProfileID: String
    var materialProfileID: String
    var profileSnapshotSHA256: String

    init(
        printerProfileID: String = "",
        materialProfileID: String = "",
        profileSnapshotSHA256: String = ""
    ) {
        self.printerProfileID = printerProfileID
        self.materialProfileID = materialProfileID
        self.profileSnapshotSHA256 = profileSnapshotSHA256
    }

    enum CodingKeys: String, CodingKey {
        case printerProfileID, materialProfileID, profileSnapshotSHA256
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printerProfileID = try c.motherMoldRequired(String.self, forKey: .printerProfileID, fallback: "")
        materialProfileID = try c.motherMoldRequired(String.self, forKey: .materialProfileID, fallback: "")
        profileSnapshotSHA256 = try c.motherMoldRequired(String.self, forKey: .profileSnapshotSHA256, fallback: "")
    }
}

private extension KeyedDecodingContainer {
    func motherMoldRequired<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        fallback: T
    ) throws -> T {
        guard contains(key) else { return fallback }
        return try decode(T.self, forKey: key)
    }

    func motherMoldOptional<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decodeIfPresent(T.self, forKey: key)
    }
}

// MARK: - MotherMold sub-settings

/// Parting-plane resolution. In `auto` mode the engine fills `planes`; in
/// `manual` mode the user-supplied `planes` are honored. `planes` is sized to
/// the part count (`MoldPartCount.planeCount`).
struct PartingSettings: Codable, Equatable, Sendable {
    var mode: PartingMode
    var planes: [PartitionPlane]

    static let defaultValue = PartingSettings(mode: .auto, planes: [])

    init(mode: PartingMode = .auto, planes: [PartitionPlane] = []) {
        self.mode = mode
        self.planes = planes
    }

    enum CodingKeys: String, CodingKey { case mode, planes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PartingSettings.defaultValue
        mode = try c.motherMoldRequired(PartingMode.self, forKey: .mode, fallback: d.mode)
        planes = try c.motherMoldRequired([PartitionPlane].self, forKey: .planes, fallback: d.planes)
    }
}

/// Mating flange + clamping bolt-hole parameters along each seam.
struct FlangeSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var width: Double         // mm, flange rim width outward from the seam
    var thickness: Double     // mm, flange slab thickness
    var boltHoleCount: Int    // bolt holes per seam
    var boltDiameter: Double  // mm

    static let defaultValue = FlangeSettings(
        enabled: true,
        width: 12.0,
        thickness: 6.0,
        boltHoleCount: 4,
        boltDiameter: 4.0
    )

    init(
        enabled: Bool = true,
        width: Double = 12.0,
        thickness: Double = 6.0,
        boltHoleCount: Int = 4,
        boltDiameter: Double = 4.0
    ) {
        self.enabled = enabled
        self.width = width
        self.thickness = thickness
        self.boltHoleCount = boltHoleCount
        self.boltDiameter = boltDiameter
    }

    var sanitized: FlangeSettings {
        FlangeSettings(
            enabled: enabled,
            width: FlangeSettings.clamp(width, 2, 80),
            thickness: FlangeSettings.clamp(thickness, 1, 40),
            boltHoleCount: Swift.min(Swift.max(boltHoleCount, 0), 12),
            boltDiameter: FlangeSettings.clamp(boltDiameter, 1, 20)
        )
    }

    enum CodingKeys: String, CodingKey {
        case enabled, width, thickness, boltHoleCount, boltDiameter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlangeSettings.defaultValue
        enabled = try c.motherMoldRequired(Bool.self, forKey: .enabled, fallback: d.enabled)
        width = try c.motherMoldRequired(Double.self, forKey: .width, fallback: d.width)
        thickness = try c.motherMoldRequired(Double.self, forKey: .thickness, fallback: d.thickness)
        boltHoleCount = try c.motherMoldRequired(Int.self, forKey: .boltHoleCount, fallback: d.boltHoleCount)
        boltDiameter = try c.motherMoldRequired(Double.self, forKey: .boltDiameter, fallback: d.boltDiameter)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}

/// Pour spout / reservoir + air-vent parameters.
struct SpoutSettings: Codable, Equatable, Sendable {
    var mode: MoldSpoutMode
    var spoutDiameter: Double      // mm, fill port bore
    var ventCount: Int
    var ventDiameter: Double       // mm
    /// Manual spout location (model space) when `mode == .manual`; ignored in auto.
    var manualSpoutX: Double
    var manualSpoutY: Double
    var manualSpoutZ: Double

    static let defaultValue = SpoutSettings(
        mode: .auto,
        spoutDiameter: 12.0,
        ventCount: 2,
        ventDiameter: 2.0,
        manualSpoutX: 0,
        manualSpoutY: 0,
        manualSpoutZ: 0
    )

    init(
        mode: MoldSpoutMode = .auto,
        spoutDiameter: Double = 12.0,
        ventCount: Int = 2,
        ventDiameter: Double = 2.0,
        manualSpoutX: Double = 0,
        manualSpoutY: Double = 0,
        manualSpoutZ: Double = 0
    ) {
        self.mode = mode
        self.spoutDiameter = spoutDiameter
        self.ventCount = ventCount
        self.ventDiameter = ventDiameter
        self.manualSpoutX = manualSpoutX
        self.manualSpoutY = manualSpoutY
        self.manualSpoutZ = manualSpoutZ
    }

    /// Manual spout location as a point.
    var manualSpout: Vec3 { Vec3(x: manualSpoutX, y: manualSpoutY, z: manualSpoutZ) }

    var sanitized: SpoutSettings {
        SpoutSettings(
            mode: mode,
            spoutDiameter: SpoutSettings.clamp(spoutDiameter, 1, 60),
            ventCount: Swift.min(Swift.max(ventCount, 0), 12),
            ventDiameter: SpoutSettings.clamp(ventDiameter, 0.5, 20),
            manualSpoutX: manualSpoutX.isFinite ? manualSpoutX : 0,
            manualSpoutY: manualSpoutY.isFinite ? manualSpoutY : 0,
            manualSpoutZ: manualSpoutZ.isFinite ? manualSpoutZ : 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case mode, spoutDiameter, ventCount, ventDiameter
        case manualSpoutX, manualSpoutY, manualSpoutZ
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpoutSettings.defaultValue
        mode = try c.motherMoldRequired(MoldSpoutMode.self, forKey: .mode, fallback: d.mode)
        spoutDiameter = try c.motherMoldRequired(Double.self, forKey: .spoutDiameter, fallback: d.spoutDiameter)
        ventCount = try c.motherMoldRequired(Int.self, forKey: .ventCount, fallback: d.ventCount)
        ventDiameter = try c.motherMoldRequired(Double.self, forKey: .ventDiameter, fallback: d.ventDiameter)
        manualSpoutX = try c.motherMoldRequired(Double.self, forKey: .manualSpoutX, fallback: d.manualSpoutX)
        manualSpoutY = try c.motherMoldRequired(Double.self, forKey: .manualSpoutY, fallback: d.manualSpoutY)
        manualSpoutZ = try c.motherMoldRequired(Double.self, forKey: .manualSpoutZ, fallback: d.manualSpoutZ)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}

/// Jacket-only fixture settings. The generated socket replaces silicone around
/// the selected downward-facing base so the physical master is supported and
/// laterally located while the jacket is poured.
struct MasterMountSettings: Codable, Equatable, Sendable {
    var mode: MasterMountMode
    var socketDepth: Double
    var fitClearance: Double

    static let defaultValue = MasterMountSettings(
        mode: .flatBaseSocket,
        socketDepth: 5.0,
        fitClearance: 0.25
    )

    init(
        mode: MasterMountMode = .flatBaseSocket,
        socketDepth: Double = 5.0,
        fitClearance: Double = 0.25
    ) {
        self.mode = mode
        self.socketDepth = socketDepth
        self.fitClearance = fitClearance
    }

    var sanitized: MasterMountSettings {
        MasterMountSettings(
            mode: mode,
            socketDepth: Self.clamp(socketDepth, 1, 30),
            fitClearance: Self.clamp(fitClearance, 0, 2)
        )
    }

    enum CodingKeys: String, CodingKey { case mode, socketDepth, fitClearance }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaultValue
        mode = try container.motherMoldRequired(MasterMountMode.self, forKey: .mode, fallback: fallback.mode)
        socketDepth = try container.motherMoldRequired(Double.self, forKey: .socketDepth, fallback: fallback.socketDepth)
        fitClearance = try container.motherMoldRequired(Double.self, forKey: .fitClearance, fallback: fallback.fitClearance)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}

// MARK: - Top-level MotherMold settings

/// All user-facing parameters for a MotherMold build. Missing legacy keys use
/// migration defaults, while present required keys decode strictly so malformed
/// project data cannot silently change tooling behavior.
struct MotherMoldSettings: Codable, Equatable, Sendable {
    var subtype: MoldSubtype
    var parts: MoldPartCount
    var wallThickness: Double      // mm, rigid mold wall
    var siliconeGap: Double        // mm, silicone subtype only (else ignored)
    var smoothing: Double          // mm, silicone smooth-offset radius (silicone only)
    var floor: Bool                // default false
    var floorThickness: Double     // mm, when floor == true
    var parting: PartingSettings
    var key: PartitionKeySettings
    var flange: FlangeSettings
    var spout: SpoutSettings
    var masterMount: MasterMountSettings
    var draftAngle: Double         // v1.x: reserved; never implemented; decoded for document compatibility only
    var packaging: MoldPackaging
    var includeAssemblyMap: Bool   // default true
    var seed: Int                  // deterministic placement
    var masterPreparation: MasterPreparationSettings
    var linerRegistration: LinerRegistrationSettings
    var productionFlow: ProductionFlowSettings
    var toolingSupport: ToolingSupportSettings
    var material: MoldMaterialSettings
    var manufacturingProfile: ToolingManufacturingProfileRef?
    var includeReferenceMeshes: Bool
    var approvedModificationSignature: String?
    var toolingContractVersion: Int

    static let defaultValue = MotherMoldSettings(
        subtype: .siliconeJacket,
        toolingContractVersion: 2
    )

    var usesReusableToolingContract: Bool {
        toolingContractVersion >= 3 && subtype == .siliconeJacket
    }

    var requiresManufacturingZip: Bool { usesReusableToolingContract }

    init(
        subtype: MoldSubtype = .slipShell,
        parts: MoldPartCount = .two,
        wallThickness: Double = 4.0,
        siliconeGap: Double = 6.0,
        smoothing: Double = 0.0,
        floor: Bool = false,
        floorThickness: Double = 4.0,
        parting: PartingSettings = .defaultValue,
        key: PartitionKeySettings = .defaultValue,
        flange: FlangeSettings = .defaultValue,
        spout: SpoutSettings = .defaultValue,
        masterMount: MasterMountSettings = .defaultValue,
        draftAngle: Double = 0.0,
        packaging: MoldPackaging? = nil,
        includeAssemblyMap: Bool = true,
        seed: Int = 0,
        masterPreparation: MasterPreparationSettings = .defaultValue,
        linerRegistration: LinerRegistrationSettings = .defaultValue,
        productionFlow: ProductionFlowSettings = .defaultValue,
        toolingSupport: ToolingSupportSettings = .defaultValue,
        material: MoldMaterialSettings = .defaultValue,
        manufacturingProfile: ToolingManufacturingProfileRef? = nil,
        includeReferenceMeshes: Bool = false,
        approvedModificationSignature: String? = nil,
        toolingContractVersion: Int = 2
    ) {
        self.subtype = subtype
        self.parts = parts
        self.wallThickness = wallThickness
        self.siliconeGap = siliconeGap
        self.smoothing = smoothing
        self.floor = floor
        self.floorThickness = floorThickness
        self.parting = parting
        self.key = key
        self.flange = flange
        self.spout = spout
        self.masterMount = masterMount
        self.draftAngle = draftAngle
        self.packaging = packaging ?? (
            subtype == .siliconeJacket && toolingContractVersion == 3
                ? .manufacturingZip
                : .separateZip
        )
        self.includeAssemblyMap = includeAssemblyMap
        self.seed = seed
        self.masterPreparation = masterPreparation
        self.linerRegistration = linerRegistration
        self.productionFlow = productionFlow
        self.toolingSupport = toolingSupport
        self.material = material
        self.manufacturingProfile = manufacturingProfile
        self.includeReferenceMeshes = includeReferenceMeshes
        self.approvedModificationSignature = approvedModificationSignature
        self.toolingContractVersion = toolingContractVersion
    }

    /// Clamp parameters into engine-safe ranges. Called by the document's
    /// `sanitized` copy so out-of-range saved/old values never reach the engine.
    var sanitized: MotherMoldSettings {
        var s = self
        s.wallThickness = MotherMoldSettings.clamp(wallThickness, 0.4, 50)
        s.siliconeGap = MotherMoldSettings.clamp(siliconeGap, 0.5, 50)
        s.smoothing = MotherMoldSettings.clamp(smoothing, 0, 30)
        s.floorThickness = MotherMoldSettings.clamp(floorThickness, 0.4, 50)
        s.draftAngle = MotherMoldSettings.clamp(draftAngle, 0, 20)
        s.key = key.sanitized
        s.flange = flange.sanitized
        s.spout = spout.sanitized
        s.masterMount = masterMount.sanitized
        s.masterPreparation = masterPreparation.sanitized
        s.linerRegistration = linerRegistration.sanitized
        s.productionFlow = productionFlow.sanitized
        s.toolingSupport = toolingSupport.sanitized
        s.material = material.sanitized
        s.toolingContractVersion = Swift.min(Swift.max(toolingContractVersion, 2), 3)
        return s
    }

    /// Inputs that alter generated geometry. Packaging and the companion guide
    /// are write-time choices and must not make an otherwise-current mold stale.
    var generationInputs: MotherMoldSettings {
        var value = sanitized
        value.packaging = .separateZip
        value.includeAssemblyMap = true
        value.manufacturingProfile = nil
        value.includeReferenceMeshes = false
        value.approvedModificationSignature = nil
        return value
    }

    enum CodingKeys: String, CodingKey {
        case subtype, parts, wallThickness, siliconeGap, smoothing
        case floor, floorThickness, parting, key, flange, spout, masterMount
        case draftAngle, packaging, includeAssemblyMap, seed
        case masterPreparation, linerRegistration, productionFlow, toolingSupport
        case material, manufacturingProfile, includeReferenceMeshes
        case approvedModificationSignature, toolingContractVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MotherMoldSettings.defaultValue
        subtype = try c.motherMoldRequired(MoldSubtype.self, forKey: .subtype, fallback: d.subtype)
        parts = try c.motherMoldRequired(MoldPartCount.self, forKey: .parts, fallback: d.parts)
        wallThickness = try c.motherMoldRequired(Double.self, forKey: .wallThickness, fallback: d.wallThickness)
        siliconeGap = try c.motherMoldRequired(Double.self, forKey: .siliconeGap, fallback: d.siliconeGap)
        smoothing = try c.motherMoldRequired(Double.self, forKey: .smoothing, fallback: d.smoothing)
        floor = try c.motherMoldRequired(Bool.self, forKey: .floor, fallback: d.floor)
        floorThickness = try c.motherMoldRequired(Double.self, forKey: .floorThickness, fallback: d.floorThickness)
        parting = try c.motherMoldRequired(PartingSettings.self, forKey: .parting, fallback: d.parting)
        key = try c.motherMoldRequired(PartitionKeySettings.self, forKey: .key, fallback: d.key)
        flange = try c.motherMoldRequired(FlangeSettings.self, forKey: .flange, fallback: d.flange)
        spout = try c.motherMoldRequired(SpoutSettings.self, forKey: .spout, fallback: d.spout)
        masterMount = try c.motherMoldRequired(MasterMountSettings.self, forKey: .masterMount, fallback: d.masterMount)
        draftAngle = try c.motherMoldRequired(Double.self, forKey: .draftAngle, fallback: d.draftAngle)
        packaging = try c.motherMoldRequired(MoldPackaging.self, forKey: .packaging, fallback: .separateZip)
        includeAssemblyMap = try c.motherMoldRequired(Bool.self, forKey: .includeAssemblyMap, fallback: d.includeAssemblyMap)
        seed = try c.motherMoldRequired(Int.self, forKey: .seed, fallback: d.seed)

        if c.contains(.toolingContractVersion) {
            toolingContractVersion = try c.decode(Int.self, forKey: .toolingContractVersion)
            guard (2...3).contains(toolingContractVersion) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .toolingContractVersion,
                    in: c,
                    debugDescription: "Unsupported MotherMold tooling contract version \(toolingContractVersion)."
                )
            }
        } else {
            toolingContractVersion = 2
        }

        let legacyMasterPreparation = MasterPreparationSettings.legacyDefault(for: masterMount)
        masterPreparation = try c.motherMoldRequired(
            MasterPreparationSettings.self,
            forKey: .masterPreparation,
            fallback: toolingContractVersion == 2 ? legacyMasterPreparation : .defaultValue
        )
        linerRegistration = try c.motherMoldRequired(
            LinerRegistrationSettings.self,
            forKey: .linerRegistration,
            fallback: toolingContractVersion == 2 ? .legacyDefault : .defaultValue
        )
        productionFlow = try c.motherMoldRequired(ProductionFlowSettings.self, forKey: .productionFlow, fallback: .defaultValue)
        toolingSupport = try c.motherMoldRequired(ToolingSupportSettings.self, forKey: .toolingSupport, fallback: .defaultValue)
        material = try c.motherMoldRequired(MoldMaterialSettings.self, forKey: .material, fallback: .defaultValue)
        manufacturingProfile = try c.motherMoldOptional(ToolingManufacturingProfileRef.self, forKey: .manufacturingProfile)
        includeReferenceMeshes = try c.motherMoldRequired(Bool.self, forKey: .includeReferenceMeshes, fallback: false)
        approvedModificationSignature = try c.motherMoldOptional(String.self, forKey: .approvedModificationSignature)
    }

    fileprivate static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}
