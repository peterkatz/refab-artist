import Foundation

/// Immutable identity and measurement evidence for the active and prepared
/// master meshes. Imported source bytes are provenance, never assumed geometry.
struct ToolingManifestSource: Codable, Equatable, Sendable {
    var importedSourceSHA256: String?
    var activeSourceGeometrySHA256: String
    var activeSourceMetrics: SerializedGeometryMetrics
    var preparedMasterMetrics: SerializedGeometryMetrics?

    init(
        importedSourceSHA256: String? = nil,
        activeSourceGeometrySHA256: String,
        activeSourceMetrics: SerializedGeometryMetrics,
        preparedMasterMetrics: SerializedGeometryMetrics? = nil
    ) {
        self.importedSourceSHA256 = importedSourceSHA256
        self.activeSourceGeometrySHA256 = activeSourceGeometrySHA256
        self.activeSourceMetrics = activeSourceMetrics
        self.preparedMasterMetrics = preparedMasterMetrics
    }
}

struct ToolingManifestProfile: Codable, Equatable, Sendable {
    var printerProfileID: String
    var materialProfileID: String
    var profileSnapshotSHA256: String

    init(printerProfileID: String, materialProfileID: String, profileSnapshotSHA256: String) {
        self.printerProfileID = printerProfileID
        self.materialProfileID = materialProfileID
        self.profileSnapshotSHA256 = profileSnapshotSHA256
    }
}

/// Geometry-specific manifest metadata. It is absent for text, CSV, SVG, and
/// source-byte members so those members never acquire fake topology values.
struct ToolingManifestGeometryMember: Codable, Equatable, Sendable {
    var artifactID: ToolingArtifactID
    var qualification: ManufacturingQualification
    var quantity: Int
    var materialHint: String?
    var assembledTransform: Matrix4x4Codable
    var recommendedPrintTransform: Matrix4x4Codable?

    init(
        artifactID: ToolingArtifactID,
        qualification: ManufacturingQualification,
        quantity: Int,
        materialHint: String? = nil,
        assembledTransform: Matrix4x4Codable = .identity,
        recommendedPrintTransform: Matrix4x4Codable? = nil
    ) {
        self.artifactID = artifactID
        self.qualification = qualification
        self.quantity = quantity
        self.materialHint = materialHint
        self.assembledTransform = assembledTransform
        self.recommendedPrintTransform = recommendedPrintTransform
    }
}

/// One non-manifest archive member plus any geometry-only metadata required to
/// reproduce the package inventory and physical assembly placement.
struct ToolingManifestMember: Codable, Equatable, Sendable {
    var member: PackageMember
    var geometry: ToolingManifestGeometryMember?

    init(member: PackageMember, geometry: ToolingManifestGeometryMember? = nil) {
        self.member = member
        self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey {
        case path, role, toolingRole, mediaType, content, byteCount, sha256
        case geometryMetrics, sourceDependencyStatus, geometry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        member = PackageMember(
            path: try container.decode(String.self, forKey: .path),
            role: try container.decode(PackageMemberRole.self, forKey: .role),
            toolingRole: try container.decodeIfPresent(ToolingArtifactRole.self, forKey: .toolingRole),
            mediaType: try container.decode(String.self, forKey: .mediaType),
            content: try container.decode(PackageMemberContent.self, forKey: .content),
            byteCount: try container.decode(UInt64.self, forKey: .byteCount),
            sha256: try container.decode(String.self, forKey: .sha256),
            geometryMetrics: try container.decodeIfPresent(
                SerializedGeometryMetrics.self,
                forKey: .geometryMetrics
            ),
            sourceDependencyStatus: try container.decodeIfPresent(
                String.self,
                forKey: .sourceDependencyStatus
            )
        )
        geometry = try container.decodeIfPresent(
            ToolingManifestGeometryMember.self,
            forKey: .geometry
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(member.path, forKey: .path)
        try container.encode(member.role, forKey: .role)
        try container.encodeIfPresent(member.toolingRole, forKey: .toolingRole)
        try container.encode(member.mediaType, forKey: .mediaType)
        try container.encode(member.content, forKey: .content)
        try container.encode(member.byteCount, forKey: .byteCount)
        try container.encode(member.sha256, forKey: .sha256)
        try container.encodeIfPresent(member.geometryMetrics, forKey: .geometryMetrics)
        try container.encodeIfPresent(
            member.sourceDependencyStatus,
            forKey: .sourceDependencyStatus
        )
        try container.encodeIfPresent(geometry, forKey: .geometry)
    }
}

struct ToolingShellSummary: Codable, Equatable, Sendable {
    var partCount: Int
    var interfaceCount: Int
    var flangePlateCount: Int
    var boltHoleCount: Int
    var shellRegistrationKeyCount: Int

    init(
        partCount: Int,
        interfaceCount: Int,
        flangePlateCount: Int,
        boltHoleCount: Int,
        shellRegistrationKeyCount: Int
    ) {
        self.partCount = partCount
        self.interfaceCount = interfaceCount
        self.flangePlateCount = flangePlateCount
        self.boltHoleCount = boltHoleCount
        self.shellRegistrationKeyCount = shellRegistrationKeyCount
    }
}

/// Versioned, self-contained schema for `manifest.json`. The manifest list
/// excludes itself by design; its bytes and hash belong in external canonical
/// evidence after deterministic encoding.
struct MotherMoldToolingManifest: Codable, Equatable, Sendable {
    static let schema = MotherMoldToolingContract.schema
    static let currentSchemaVersion = MotherMoldToolingContract.currentSchemaVersion
    static let units = "millimeters"

    var schema: String
    var schemaVersion: Int
    var appVersion: String
    var toolingContractVersion: Int
    var deterministicSeed: Int
    var units: String
    var source: ToolingManifestSource
    var manufacturingProfile: ToolingManifestProfile?
    var members: [ToolingManifestMember]
    var hardwareItems: [ToolingHardwareItem]
    var shell: ToolingShellSummary
    var masterPreparation: MasterPreparationSummary
    var holdDownWrenchEnvelope: HoldDownWrenchEnvelope
    var linerRegistration: LinerRegistrationSummary
    var linerFillPath: MoldFlowPathSummary
    var productionCastingPath: MoldFlowPathSummary
    var productionCastingVents: [MoldFlowPathSummary]
    var linerFillSupport: ToolingSupportSummary
    var castingSupport: ToolingSupportSummary
    var exportContract: MotherMoldToolingContract
    var blockingDiagnostics: [String]
    var warningDiagnostics: [String]

    init(
        appVersion: String,
        toolingContractVersion: Int,
        deterministicSeed: Int,
        source: ToolingManifestSource,
        manufacturingProfile: ToolingManifestProfile? = nil,
        members: [ToolingManifestMember],
        hardwareItems: [ToolingHardwareItem] = [],
        shell: ToolingShellSummary,
        masterPreparation: MasterPreparationSummary = .notApplicable,
        holdDownWrenchEnvelope: HoldDownWrenchEnvelope = .notApplicable,
        linerRegistration: LinerRegistrationSummary = .notApplicable,
        linerFillPath: MoldFlowPathSummary = .notApplicable(phase: .linerFill),
        productionCastingPath: MoldFlowPathSummary = .notApplicable(phase: .casting),
        productionCastingVents: [MoldFlowPathSummary] = [],
        linerFillSupport: ToolingSupportSummary = .notApplicable(phase: .linerFill),
        castingSupport: ToolingSupportSummary = .notApplicable(phase: .casting),
        exportContract: MotherMoldToolingContract,
        blockingDiagnostics: [String] = [],
        warningDiagnostics: [String] = [],
        schema: String = MotherMoldToolingManifest.schema,
        schemaVersion: Int = MotherMoldToolingManifest.currentSchemaVersion,
        units: String = MotherMoldToolingManifest.units
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.toolingContractVersion = toolingContractVersion
        self.deterministicSeed = deterministicSeed
        self.units = units
        self.source = source
        self.manufacturingProfile = manufacturingProfile
        self.members = members
        self.hardwareItems = hardwareItems.sorted { $0.id < $1.id }
        self.shell = shell
        self.masterPreparation = masterPreparation
        self.holdDownWrenchEnvelope = holdDownWrenchEnvelope
        self.linerRegistration = linerRegistration
        self.linerFillPath = linerFillPath
        self.productionCastingPath = productionCastingPath
        self.productionCastingVents = productionCastingVents
        self.linerFillSupport = linerFillSupport
        self.castingSupport = castingSupport
        self.exportContract = exportContract
        self.blockingDiagnostics = blockingDiagnostics
        self.warningDiagnostics = warningDiagnostics
    }

    /// Canonical JSON for manifest bytes and cross-process reproducibility.
    /// Package writers own archive bytes and must not insert this manifest as a
    /// self-hashed `PackageMember`.
    func deterministicJSON(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

enum MotherMoldToolingManifestEncoding {
    static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }
}
