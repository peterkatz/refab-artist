import Foundation

// MARK: - Codable geometry values

/// A column-major 4 by 4 affine transform suitable for manifest persistence.
/// Decoding rejects malformed matrices instead of silently accepting a transform
/// that a later renderer or exporter cannot interpret.
struct Matrix4x4Codable: Codable, Equatable, Sendable {
    static let elementCount = 16

    var elements: [Double]

    init(elements: [Double]) throws {
        guard elements.count == Self.elementCount, elements.allSatisfy(\.isFinite) else {
            throw Matrix4x4CodableError.invalidElements
        }
        self.elements = elements
    }

    static let identity = try! Matrix4x4Codable(elements: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(elements: container.decode([Double].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}

enum Matrix4x4CodableError: Error, Equatable, Sendable {
    case invalidElements
}

struct ToolingBounds: Codable, Equatable, Sendable {
    var minimum: Vec3Codable
    var maximum: Vec3Codable

    init(minimum: Vec3Codable, maximum: Vec3Codable) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

// MARK: - Artifact and package identity

/// Stable, artist-facing identity used consistently by geometry, the guide, and
/// the manifest. The ID is authoritative when a physical embossed label cannot fit.
struct ToolingArtifactID: Codable, Equatable, Hashable, Comparable, Sendable {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static func < (lhs: ToolingArtifactID, rhs: ToolingArtifactID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ToolingArtifactRole: String, CaseIterable, Codable, Equatable, Sendable {
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

    var isReference: Bool {
        switch self {
        case .referenceImportedSource, .referenceActiveSource, .referenceAsPouredLiner,
             .referenceProductionLiner, .referenceAssembly:
            return true
        default:
            return false
        }
    }

    var isManufacturingArtifact: Bool { !isReference }
}

/// Per-artifact geometric/print status. This deliberately does not imply
/// physical process qualification.
enum ManufacturingQualification: String, Codable, Equatable, Sendable {
    case topologyValid
    case printerProfileValidated
    case referenceOnly
}

// MARK: - Standard hardware schedule

/// Hardware identity is deliberately separate from `ToolingArtifactID`: these
/// entries have no geometry and therefore cannot become printable STL members.
struct ToolingHardwareItemID: Codable, Equatable, Hashable, Comparable, Sendable {
    var rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    static func < (lhs: ToolingHardwareItemID, rhs: ToolingHardwareItemID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ToolingHardwareKind: String, Codable, Equatable, Sendable {
    case removableCrossPin
    case fastener
    case clamp
    case sealant
    case releaseAgent
    case consumable
    case other
}

enum ToolingHardwareDimensionKind: String, Codable, Equatable, Hashable, Sendable {
    case crossPinDiameter
    case crossPinMinimumLength
    case other
}

struct ToolingHardwareDimension: Codable, Equatable, Sendable {
    var kind: ToolingHardwareDimensionKind
    var nominalMillimeters: Double
    var tolerancePlusMinusMillimeters: Double?

    init(
        kind: ToolingHardwareDimensionKind,
        nominalMillimeters: Double,
        tolerancePlusMinusMillimeters: Double? = nil
    ) {
        self.kind = kind
        self.nominalMillimeters = nominalMillimeters
        self.tolerancePlusMinusMillimeters = tolerancePlusMinusMillimeters
    }
}

/// Measured fixture dimensions copied into the schedule after prepared-post
/// geometry exists. They remain schedule data, not printable geometry.
struct ToolingHardwareFixtureRequirement: Codable, Equatable, Sendable {
    var crossPinDiameterMillimeters: Double
    var minimumCrossPinLengthMillimeters: Double

    init(crossPinDiameterMillimeters: Double, minimumCrossPinLengthMillimeters: Double) {
        self.crossPinDiameterMillimeters = crossPinDiameterMillimeters
        self.minimumCrossPinLengthMillimeters = minimumCrossPinLengthMillimeters
    }
}

enum ToolingHardwareUse: String, Codable, Equatable, Hashable, Sendable {
    case preparedMasterHoldDown
    case castingFunnelRetention
    case shellAssembly
    case linerFill
    case casting
    case demold
    case cleanup
}

enum ToolingHardwareResponsibility: String, Codable, Equatable, Sendable {
    case refabArtistSpecifiedShopSupplied
    case shopSupplied
    case artistSupplied
    case qualifiedByShop
}

/// This describes the purchased item only; it never promotes the printable
/// hold-down assembly beyond the plan's export qualification.
enum ToolingHardwareQualification: String, Codable, Equatable, Sendable {
    case geometryOnly
    case physicalEvidenceRequired
    case shopQualified
}

struct ToolingHardwareItem: Codable, Equatable, Sendable {
    var id: ToolingHardwareItemID
    var kind: ToolingHardwareKind
    var description: String
    var specification: String
    var quantity: Int
    var materialOrStandardHint: String
    var requiredDimensions: [ToolingHardwareDimension]
    var phases: [ToolingPhase]
    var uses: [ToolingHardwareUse]
    var responsibility: ToolingHardwareResponsibility
    var qualification: ToolingHardwareQualification
    var fixtureRequirement: ToolingHardwareFixtureRequirement?

    init(
        id: ToolingHardwareItemID,
        kind: ToolingHardwareKind,
        description: String,
        specification: String,
        quantity: Int,
        materialOrStandardHint: String,
        requiredDimensions: [ToolingHardwareDimension],
        phases: [ToolingPhase],
        uses: [ToolingHardwareUse],
        responsibility: ToolingHardwareResponsibility,
        qualification: ToolingHardwareQualification,
        fixtureRequirement: ToolingHardwareFixtureRequirement? = nil
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.specification = specification
        self.quantity = quantity
        self.materialOrStandardHint = materialOrStandardHint
        self.requiredDimensions = requiredDimensions
        self.phases = phases
        self.uses = uses
        self.responsibility = responsibility
        self.qualification = qualification
        self.fixtureRequirement = fixtureRequirement
    }

    var isPreparedMasterHoldDownCrossPin: Bool {
        kind == .removableCrossPin && uses.contains(.preparedMasterHoldDown)
    }

    func matchesFixtureRequirement() -> Bool {
        guard let fixtureRequirement else { return false }
        let kinds = requiredDimensions.map(\.kind)
        guard Set(kinds).count == kinds.count else { return false }
        let dimensions = Dictionary(uniqueKeysWithValues: requiredDimensions.map { ($0.kind, $0) })
        guard let diameter = dimensions[.crossPinDiameter],
              let length = dimensions[.crossPinMinimumLength] else {
            return false
        }
        let diameterTolerance = diameter.tolerancePlusMinusMillimeters ?? 0
        return abs(diameter.nominalMillimeters - fixtureRequirement.crossPinDiameterMillimeters) <= diameterTolerance
            && length.nominalMillimeters >= fixtureRequirement.minimumCrossPinLengthMillimeters
    }
}

/// Explicit package readiness avoids presenting unmeasured fixture or process
/// evidence as a manufacturing claim.
enum ToolingQualificationStatus: String, Codable, Equatable, Sendable {
    case notApplicable
    case pending
    case blocked
    case geometryOnly
    case printerFitNotChecked
    case printerProfileValidated
    case externalResponsibility
    case physicalEvidenceRequired
    case productionProfileQualified
}

/// Geometry-only output. Existing `MotherMoldPart` remains the sole rigid-shell
/// part model and is intentionally not replaced by this artifact envelope.
struct ToolingArtifact: Codable, Equatable {
    var id: ToolingArtifactID
    var name: String
    var role: ToolingArtifactRole
    var geometry: MeshGeometryData
    var qualification: ManufacturingQualification
    var materialHint: String?
    var quantity: Int
    var assembledTransform: Matrix4x4Codable
    var recommendedPrintTransform: Matrix4x4Codable?

    init(
        id: ToolingArtifactID,
        name: String,
        role: ToolingArtifactRole,
        geometry: MeshGeometryData,
        qualification: ManufacturingQualification,
        materialHint: String? = nil,
        quantity: Int = 1,
        assembledTransform: Matrix4x4Codable = .identity,
        recommendedPrintTransform: Matrix4x4Codable? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.geometry = geometry
        self.qualification = qualification
        self.materialHint = materialHint
        self.quantity = quantity
        self.assembledTransform = assembledTransform
        self.recommendedPrintTransform = recommendedPrintTransform
    }
}

enum PackageMemberContent: String, Codable, Equatable, Sendable {
    case geometry
    case text
    case csv
    case svg
    case sourceBytes
}

enum PackageMemberRole: String, Codable, Equatable, Sendable {
    case assemblyGuide
    case hardwareSchedule
    case toolingGeometry
    case sourceProvenance
    case referenceGeometry
}

/// Measured only after a geometry member has been serialized and re-read.
/// Non-geometry package members must carry `nil` rather than invented metrics.
struct SerializedGeometryMetrics: Codable, Equatable, Sendable {
    var vertexCount: Int
    var triangleCount: Int
    var connectedComponentCount: Int
    var signedVolumeCubicMillimeters: Double
    var isWatertight: Bool
    var hasFiniteCoordinates: Bool
    var hasConsistentWinding: Bool
    var bounds: ToolingBounds?

    init(
        vertexCount: Int,
        triangleCount: Int,
        connectedComponentCount: Int,
        signedVolumeCubicMillimeters: Double,
        isWatertight: Bool,
        hasFiniteCoordinates: Bool,
        hasConsistentWinding: Bool,
        bounds: ToolingBounds? = nil
    ) {
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.connectedComponentCount = connectedComponentCount
        self.signedVolumeCubicMillimeters = signedVolumeCubicMillimeters
        self.isWatertight = isWatertight
        self.hasFiniteCoordinates = hasFiniteCoordinates
        self.hasConsistentWinding = hasConsistentWinding
        self.bounds = bounds
    }
}

/// A declared non-manifest archive member. `manifest.json` is intentionally
/// absent because it cannot safely hash or size itself.
struct PackageMember: Codable, Equatable, Sendable {
    var path: String
    var role: PackageMemberRole
    var toolingRole: ToolingArtifactRole?
    var mediaType: String
    var content: PackageMemberContent
    var byteCount: UInt64
    var sha256: String
    var geometryMetrics: SerializedGeometryMetrics?
    var sourceDependencyStatus: String?

    init(
        path: String,
        role: PackageMemberRole,
        toolingRole: ToolingArtifactRole? = nil,
        mediaType: String,
        content: PackageMemberContent,
        byteCount: UInt64,
        sha256: String,
        geometryMetrics: SerializedGeometryMetrics? = nil,
        sourceDependencyStatus: String? = nil
    ) {
        self.path = path
        self.role = role
        self.toolingRole = toolingRole
        self.mediaType = mediaType
        self.content = content
        self.byteCount = byteCount
        self.sha256 = sha256
        self.geometryMetrics = geometryMetrics
        self.sourceDependencyStatus = sourceDependencyStatus
    }
}

// MARK: - Master preparation

enum MasterModificationKind: String, Codable, Equatable, Sendable {
    case anchorAndGateRoot
    case separateGateRoot
    case productionVentLanding
    case approvedRepair
}

struct MasterModificationRegion: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: MasterModificationKind
    var center: Vec3Codable
    var surfaceArea: Double
    var boundary: [Vec3Codable]
    var purpose: String

    init(
        id: String,
        kind: MasterModificationKind,
        center: Vec3Codable,
        surfaceArea: Double,
        boundary: [Vec3Codable],
        purpose: String
    ) {
        self.id = id
        self.kind = kind
        self.center = center
        self.surfaceArea = surfaceArea
        self.boundary = boundary
        self.purpose = purpose
    }
}

enum MasterPreparationState: String, Codable, Equatable, Sendable {
    case notApplicable
    case notRequired
    case pending
    case approvalRequired
    case approved
    case blocked
    case externalFixture
}

enum MasterRetentionEvidence: String, Codable, Equatable, Sendable {
    case notApplicable
    case preparedPostGeometryOnly
    case preparedPostQualified
    case socketLocatorOnly
    case externalFixtureDeclared
    case externalFixtureQualified
}

struct MasterPreparationSummary: Codable, Equatable, Sendable {
    var state: MasterPreparationState
    var retentionEvidence: MasterRetentionEvidence
    var sourceGeometrySHA256: String?
    var preparedGeometrySHA256: String?
    var approvalSignature: String?
    var modificationRegionIDs: [String]
    var notes: [String]

    static let notApplicable = MasterPreparationSummary(
        state: .notApplicable,
        retentionEvidence: .notApplicable
    )

    init(
        state: MasterPreparationState,
        retentionEvidence: MasterRetentionEvidence,
        sourceGeometrySHA256: String? = nil,
        preparedGeometrySHA256: String? = nil,
        approvalSignature: String? = nil,
        modificationRegionIDs: [String] = [],
        notes: [String] = []
    ) {
        self.state = state
        self.retentionEvidence = retentionEvidence
        self.sourceGeometrySHA256 = sourceGeometrySHA256
        self.preparedGeometrySHA256 = preparedGeometrySHA256
        self.approvalSignature = approvalSignature
        self.modificationRegionIDs = modificationRegionIDs
        self.notes = notes
    }
}

// MARK: - Load, flow, liner, and support evidence

enum ToolingPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case linerFill
    case casting
    case demold
    case storage
}

struct ForceMomentWrench: Codable, Equatable, Sendable {
    var forceNewtons: Vec3Codable
    var momentNewtonMillimeters: Vec3Codable

    static let zero = ForceMomentWrench(
        forceNewtons: Vec3Codable(x: 0, y: 0, z: 0),
        momentNewtonMillimeters: Vec3Codable(x: 0, y: 0, z: 0)
    )
}

enum WrenchQualificationState: String, Codable, Equatable, Sendable {
    case notApplicable
    case notMeasured
    case geometryOnly
    case qualified
    case external
    case blocked
}

struct WrenchLoadCase: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var phase: ToolingPhase
    var fillFraction: Double
    var wrench: ForceMomentWrench
    var utilization: Double?

    init(
        id: String,
        phase: ToolingPhase,
        fillFraction: Double,
        wrench: ForceMomentWrench,
        utilization: Double? = nil
    ) {
        self.id = id
        self.phase = phase
        self.fillFraction = fillFraction
        self.wrench = wrench
        self.utilization = utilization
    }
}

struct HoldDownWrenchEnvelope: Codable, Equatable, Sendable {
    var version: Int
    var qualification: WrenchQualificationState
    var loadCases: [WrenchLoadCase]
    var worstCaseID: String?
    var maximumUtilization: Double?
    var notes: [String]

    static let notApplicable = HoldDownWrenchEnvelope(
        version: 1,
        qualification: .notApplicable
    )

    init(
        version: Int,
        qualification: WrenchQualificationState,
        loadCases: [WrenchLoadCase] = [],
        worstCaseID: String? = nil,
        maximumUtilization: Double? = nil,
        notes: [String] = []
    ) {
        self.version = version
        self.qualification = qualification
        self.loadCases = loadCases
        self.worstCaseID = worstCaseID
        self.maximumUtilization = maximumUtilization
        self.notes = notes
    }
}

enum MoldFlowPathState: String, Codable, Equatable, Sendable {
    case notApplicable
    case notGenerated
    case pendingMeasurement
    case geometryVerified
    case blocked
}

/// A phase-specific fill, gate, or vent path. A path is only marked verified
/// after it is measured on final serialized geometry.
struct MoldFlowPathSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var phase: ToolingPhase
    var state: MoldFlowPathState
    var label: String
    var gravityUpAxis: Vec3Codable?
    var entryPoint: Vec3Codable?
    var exitPoint: Vec3Codable?
    var declaredDiameterMillimeters: Double?
    var measuredMinimumDiameterMillimeters: Double?
    var artifactIDs: [ToolingArtifactID]
    var notes: [String]

    static func notApplicable(phase: ToolingPhase) -> MoldFlowPathSummary {
        MoldFlowPathSummary(
            id: "\(phase.rawValue)-not-applicable",
            phase: phase,
            state: .notApplicable,
            label: phase.rawValue
        )
    }

    init(
        id: String,
        phase: ToolingPhase,
        state: MoldFlowPathState,
        label: String,
        gravityUpAxis: Vec3Codable? = nil,
        entryPoint: Vec3Codable? = nil,
        exitPoint: Vec3Codable? = nil,
        declaredDiameterMillimeters: Double? = nil,
        measuredMinimumDiameterMillimeters: Double? = nil,
        artifactIDs: [ToolingArtifactID] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.phase = phase
        self.state = state
        self.label = label
        self.gravityUpAxis = gravityUpAxis
        self.entryPoint = entryPoint
        self.exitPoint = exitPoint
        self.declaredDiameterMillimeters = declaredDiameterMillimeters
        self.measuredMinimumDiameterMillimeters = measuredMinimumDiameterMillimeters
        self.artifactIDs = artifactIDs
        self.notes = notes
    }
}

enum LinerRegistrationState: String, Codable, Equatable, Sendable {
    case notApplicable
    case disabled
    case pendingMeasurement
    case geometryVerified
    case blocked
}

struct LinerRegistrationSite: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var shellPartID: ToolingArtifactID
    var center: Vec3Codable
    var demoldAxis: Vec3Codable
    var diameterMillimeters: Double
    var depthMillimeters: Double

    init(
        id: String,
        shellPartID: ToolingArtifactID,
        center: Vec3Codable,
        demoldAxis: Vec3Codable,
        diameterMillimeters: Double,
        depthMillimeters: Double
    ) {
        self.id = id
        self.shellPartID = shellPartID
        self.center = center
        self.demoldAxis = demoldAxis
        self.diameterMillimeters = diameterMillimeters
        self.depthMillimeters = depthMillimeters
    }
}

struct LinerRegistrationSummary: Codable, Equatable, Sendable {
    var state: LinerRegistrationState
    var requestedButtonCount: Int
    var sites: [LinerRegistrationSite]
    var gateLipEnabled: Bool
    var gateLipDepthMillimeters: Double?
    var notes: [String]

    static let notApplicable = LinerRegistrationSummary(state: .notApplicable)

    init(
        state: LinerRegistrationState,
        requestedButtonCount: Int = 0,
        sites: [LinerRegistrationSite] = [],
        gateLipEnabled: Bool = false,
        gateLipDepthMillimeters: Double? = nil,
        notes: [String] = []
    ) {
        self.state = state
        self.requestedButtonCount = requestedButtonCount
        self.sites = sites
        self.gateLipEnabled = gateLipEnabled
        self.gateLipDepthMillimeters = gateLipDepthMillimeters
        self.notes = notes
    }
}

enum ToolingSupportState: String, Codable, Equatable, Sendable {
    case notApplicable
    case pendingMeasurement
    case stableWithoutCradle
    case supportGeometryOnly
    case qualified
    case blocked
}

struct ToolingMassState: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var fillFraction: Double
    var massGrams: Double?
    var centerOfGravity: Vec3Codable?

    init(id: String, fillFraction: Double, massGrams: Double? = nil, centerOfGravity: Vec3Codable? = nil) {
        self.id = id
        self.fillFraction = fillFraction
        self.massGrams = massGrams
        self.centerOfGravity = centerOfGravity
    }
}

struct ToolingSupportLoadEnvelope: Codable, Equatable, Sendable {
    var version: Int
    var qualification: ToolingSupportState
    var handlingSafetyFactor: Double?
    var maximumWrench: ForceMomentWrench?
    var notes: [String]

    init(
        version: Int,
        qualification: ToolingSupportState,
        handlingSafetyFactor: Double? = nil,
        maximumWrench: ForceMomentWrench? = nil,
        notes: [String] = []
    ) {
        self.version = version
        self.qualification = qualification
        self.handlingSafetyFactor = handlingSafetyFactor
        self.maximumWrench = maximumWrench
        self.notes = notes
    }
}

struct ToolingSupportSummary: Codable, Equatable, Sendable {
    var phase: ToolingPhase
    var state: ToolingSupportState
    var gravityUpAxis: Vec3Codable?
    var massStates: [ToolingMassState]
    var supportContacts: [Vec3Codable]
    var minimumSupportMarginMillimeters: Double?
    var cradleArtifactIDs: [ToolingArtifactID]
    var loadEnvelope: ToolingSupportLoadEnvelope?
    var notes: [String]

    static func notApplicable(phase: ToolingPhase) -> ToolingSupportSummary {
        ToolingSupportSummary(phase: phase, state: .notApplicable)
    }

    init(
        phase: ToolingPhase,
        state: ToolingSupportState,
        gravityUpAxis: Vec3Codable? = nil,
        massStates: [ToolingMassState] = [],
        supportContacts: [Vec3Codable] = [],
        minimumSupportMarginMillimeters: Double? = nil,
        cradleArtifactIDs: [ToolingArtifactID] = [],
        loadEnvelope: ToolingSupportLoadEnvelope? = nil,
        notes: [String] = []
    ) {
        self.phase = phase
        self.state = state
        self.gravityUpAxis = gravityUpAxis
        self.massStates = massStates
        self.supportContacts = supportContacts
        self.minimumSupportMarginMillimeters = minimumSupportMarginMillimeters
        self.cradleArtifactIDs = cradleArtifactIDs
        self.loadEnvelope = loadEnvelope
        self.notes = notes
    }
}

// MARK: - Package contract summary

enum MotherMoldToolingContractState: String, Codable, Equatable, Sendable {
    case notApplicable
    case incomplete
    case blocked
    case geometryOnly
    case printerValidated
    case productionProfileQualified
}

/// Summary consumed by UI and headless paths. It records why a package is or is
/// not releasable without turning absent physical evidence into a positive claim.
struct MotherMoldToolingContract: Codable, Equatable, Sendable {
    static let schema = "refabartist.mothermold.tooling/v3"
    static let currentSchemaVersion = 1

    var schema: String
    var schemaVersion: Int
    var toolingContractVersion: Int
    var state: MotherMoldToolingContractState
    var qualification: ToolingQualificationStatus
    var requiredArtifactRoles: [ToolingArtifactRole]
    var blockingReasons: [String]
    var warnings: [String]

    static let notApplicable = MotherMoldToolingContract(
        toolingContractVersion: 0,
        state: .notApplicable,
        qualification: .notApplicable
    )

    init(
        schema: String = MotherMoldToolingContract.schema,
        schemaVersion: Int = MotherMoldToolingContract.currentSchemaVersion,
        toolingContractVersion: Int,
        state: MotherMoldToolingContractState,
        qualification: ToolingQualificationStatus,
        requiredArtifactRoles: [ToolingArtifactRole] = [],
        blockingReasons: [String] = [],
        warnings: [String] = []
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.toolingContractVersion = toolingContractVersion
        self.state = state
        self.qualification = qualification
        self.requiredArtifactRoles = requiredArtifactRoles
        self.blockingReasons = blockingReasons
        self.warnings = warnings
    }
}
