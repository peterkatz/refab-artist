import Foundation

/// Typed, pre-key input for the transactional liner-to-shell registration stage.
/// `nominalLinerSurface` is a triangle surface, not an inferred bounding volume.
struct MoldLinerRegistrationInput: Equatable {
    var finalShellParts: [MoldLinerRegistrationShellPart]
    var nominalLinerSurface: MeshGeometryData
    var totalLinerOffset: Double
    var settings: LinerRegistrationSettings
    var buttonOverride: MoldLinerRegistrationButtonDimensions?
    var wallThickness: Double
    var partingPlanes: [PartitionPlane]
    var reservedGeometry: MoldLinerRegistrationReservedGeometry
    var gateLipDatum: MoldLinerRegistrationGateLipDatum?
    var protectedAuditSet: ProtectedToolingAuditSet?

    init(
        finalShellParts: [MoldLinerRegistrationShellPart],
        nominalLinerSurface: MeshGeometryData,
        totalLinerOffset: Double,
        settings: LinerRegistrationSettings,
        buttonOverride: MoldLinerRegistrationButtonDimensions? = nil,
        wallThickness: Double,
        partingPlanes: [PartitionPlane],
        reservedGeometry: MoldLinerRegistrationReservedGeometry,
        gateLipDatum: MoldLinerRegistrationGateLipDatum? = nil,
        protectedAuditSet: ProtectedToolingAuditSet? = nil
    ) {
        self.finalShellParts = finalShellParts
        self.nominalLinerSurface = nominalLinerSurface
        self.totalLinerOffset = totalLinerOffset
        self.settings = settings
        self.buttonOverride = buttonOverride
        self.wallThickness = wallThickness
        self.partingPlanes = partingPlanes
        self.reservedGeometry = reservedGeometry
        self.gateLipDatum = gateLipDatum
        self.protectedAuditSet = protectedAuditSet
    }
}

struct MoldLinerRegistrationShellPart: Equatable {
    var id: ToolingArtifactID
    var part: MotherMoldPart
    var demoldAxis: Vec3Codable

    init(id: ToolingArtifactID, part: MotherMoldPart, demoldAxis: Vec3Codable) {
        self.id = id
        self.part = part
        self.demoldAxis = demoldAxis
    }
}

struct MoldLinerRegistrationButtonDimensions: Equatable {
    var diameter: Double
    var depth: Double
    var draftDegrees: Double
}

enum MoldLinerRegistrationReservedKind: String, CaseIterable, Equatable {
    case collar
    case linerFill
    case productionFlow
    case flange
    case boltBore
    case shellKey
}

struct MoldLinerRegistrationReservedFeature: Equatable {
    var id: String
    var kind: MoldLinerRegistrationReservedKind
    var solid: MeshGeometryData
}

/// Explicit lists make it impossible for a caller to hide a protected family in
/// a single unlabeled union. Empty lists are valid when that feature is absent.
struct MoldLinerRegistrationReservedGeometry: Equatable {
    var collar: [MoldLinerRegistrationReservedFeature]
    var linerFill: [MoldLinerRegistrationReservedFeature]
    var productionFlow: [MoldLinerRegistrationReservedFeature]
    var flanges: [MoldLinerRegistrationReservedFeature]
    var boltBores: [MoldLinerRegistrationReservedFeature]
    var shellKeys: [MoldLinerRegistrationReservedFeature]

    init(
        collar: [MoldLinerRegistrationReservedFeature] = [],
        linerFill: [MoldLinerRegistrationReservedFeature] = [],
        productionFlow: [MoldLinerRegistrationReservedFeature] = [],
        flanges: [MoldLinerRegistrationReservedFeature] = [],
        boltBores: [MoldLinerRegistrationReservedFeature] = [],
        shellKeys: [MoldLinerRegistrationReservedFeature] = []
    ) {
        self.collar = collar
        self.linerFill = linerFill
        self.productionFlow = productionFlow
        self.flanges = flanges
        self.boltBores = boltBores
        self.shellKeys = shellKeys
    }

    var all: [MoldLinerRegistrationReservedFeature] {
        collar + linerFill + productionFlow + flanges + boltBores + shellKeys
    }
}

/// The collar and gate are supplied by the stage that created them. Registration
/// never invents a gate lip from a bounding box or an untyped point.
struct MoldLinerRegistrationGateLipDatum: Equatable {
    var collarSolid: MeshGeometryData
    var linerSealPoint: Vec3Codable
    var rigidStopContactPoint: Vec3Codable
    var axis: Vec3Codable
    var gateDiameter: Double
    var splitPartingPlaneID: UUID
    var fixtureHandoffID: String?

    init(
        collarSolid: MeshGeometryData,
        linerSealPoint: Vec3Codable,
        rigidStopContactPoint: Vec3Codable,
        axis: Vec3Codable,
        gateDiameter: Double,
        splitPartingPlaneID: UUID,
        fixtureHandoffID: String? = nil
    ) {
        self.collarSolid = collarSolid
        self.linerSealPoint = linerSealPoint
        self.rigidStopContactPoint = rigidStopContactPoint
        self.axis = axis
        self.gateDiameter = gateDiameter
        self.splitPartingPlaneID = splitPartingPlaneID
        self.fixtureHandoffID = fixtureHandoffID
    }

    init(fixture: MoldMasterFixtureBuilder.Result) throws {
        guard let datum = fixture.productionGate else {
            throw MoldLinerRegistrationBuilderError.missingGateLipDatum
        }
        self.init(
            collarSolid: datum.collarSolid,
            linerSealPoint: datum.linerSealPoint,
            rigidStopContactPoint: datum.rigidStopContactPoint,
            axis: datum.receiverAxis,
            gateDiameter: datum.productionGateDiameterMillimeters,
            splitPartingPlaneID: datum.selectedSplitPlaneID,
            fixtureHandoffID: datum.handoffID
        )
    }
}

struct MoldLinerRegistrationFunnelSealDatum: Equatable {
    var bead: MeshGeometryData
    var compressionStop: MeshGeometryData
    var beadInnerRadiusMillimeters: Double
    var beadOuterRadiusMillimeters: Double
    var beadHeightMillimeters: Double
    var stopInnerRadiusMillimeters: Double
    var stopOuterRadiusMillimeters: Double
    var sealContactPoint: Vec3Codable
    var stopContactPoint: Vec3Codable
    var releaseAxis: Vec3Codable
    var selectedSplitPlaneID: UUID
    var fixtureHandoffID: String?
    var roundedThroatRadiusMillimeters: Double
}

struct MoldLinerRegistrationGateLipResult: Equatable {
    var splitPlaneID: UUID
    var lipSegments: [MoldLinerFillAdditiveVolume]
    var funnelSeal: MoldLinerRegistrationFunnelSealDatum
}

struct MoldLinerRegistrationResult: Equatable {
    var shellParts: [MoldLinerRegistrationShellPart]
    var siliconeAdditives: [MoldLinerFillAdditiveVolume]
    var protectedRegions: [MoldLinerProtectedRegion]
    var sites: [LinerRegistrationSite]
    var summary: LinerRegistrationSummary
    var gateLip: MoldLinerRegistrationGateLipResult?
    var protectedAuditSet: ProtectedToolingAuditSet
}

enum MoldLinerRegistrationBuilderError: Error, Equatable, LocalizedError {
    case invalidInput(MoldLinerRegistrationInputIssue)
    case requestedButtonsUnplaceable(partID: ToolingArtifactID, requested: Int, placed: Int)
    case distributionInsufficient(partID: ToolingArtifactID)
    case featureDidNotSurvive(partID: ToolingArtifactID, feature: MoldLinerRegistrationFeatureKind)
    case featureRetentionFailed(partID: ToolingArtifactID, feature: MoldLinerRegistrationFeatureKind, detail: String)
    case protectedToolingAuditFailed(String)
    case backingBelowMinimum(partID: ToolingArtifactID, feature: MoldLinerRegistrationFeatureKind)
    case missingGateLipDatum
    case invalidGateLipSplit(planeID: UUID)
    case gateLipHasNoReleasePath
    case invalidFunnelSealDatum
    case serializedGeometryUnsafe(partID: ToolingArtifactID)
}

enum MoldLinerRegistrationInputIssue: Equatable {
    case nonPositiveOffset
    case nonPositiveWallThickness
    case emptyShellParts
    case duplicateShellPartID(ToolingArtifactID)
    case invalidShellPart(ToolingArtifactID)
    case invalidDemoldAxis(ToolingArtifactID)
    case noNominalSurfaceCandidates
    case invalidReservedFeature(String)
    case invalidButtonDimensions
    case invalidGateDatum
}

enum MoldLinerRegistrationFeatureKind: Equatable {
    case button(Int)
    case gateLip(Int)
    case funnelSeal
}

extension MoldLinerRegistrationBuilderError {
    var errorDescription: String? {
        switch self {
        case .invalidInput(let issue):
            return "Liner registration input is invalid: \(issue). Action: correct the typed geometry supplied to this stage."
        case .requestedButtonsUnplaceable(let id, let requested, let placed):
            return "Shell part \(id.rawValue) placed \(placed) of \(requested) requested liner buttons. Action: move protected features, revise parting, or reduce the requested count."
        case .distributionInsufficient(let id):
            return "Shell part \(id.rawValue) cannot spread its liner buttons over two principal directions. Action: revise parting or add usable liner surface."
        case .featureDidNotSurvive(let id, let feature):
            return "Liner registration \(feature) did not survive on shell part \(id.rawValue). Action: revise the local shell geometry."
        case .featureRetentionFailed(let id, let feature, let detail):
            return "Liner registration \(feature) failed its measured retention gate on shell part \(id.rawValue): \(detail). Action: revise the local shell geometry."
        case .protectedToolingAuditFailed(let detail):
            return "Liner registration would damage protected fixture geometry: \(detail)"
        case .backingBelowMinimum(let id, let feature):
            return "Liner registration \(feature) leaves insufficient shell backing on \(id.rawValue). Action: increase wall thickness or relocate the feature."
        case .missingGateLipDatum:
            return "Captured gate lip requires a typed collar/gate datum. Action: generate and validate the collar and production gate before registration."
        case .invalidGateLipSplit:
            return "Captured gate lip does not cross its declared parting interface. Action: move the gate or choose a split collar interface."
        case .gateLipHasNoReleasePath:
            return "Captured gate lip has no valid axial release path. Action: reorient the collar gate or revise the parting."
        case .invalidFunnelSealDatum:
            return "Captured gate lip did not produce a complete measured annular funnel seal and rigid stop. Action: regenerate the collar handoff."
        case .serializedGeometryUnsafe(let id):
            return "Liner registration shell part \(id.rawValue) could not be normalized into printable serialized geometry. Action: revise the local shell geometry."
        }
    }
}

enum MoldLinerRegistrationBuilder {
    private static let clearance = 0.25
    private static let containmentTolerance = 0.01
    /// The reusable-tooling contract requires at least 98% of each complete
    /// housing/recess profile to survive later booleans and serialization.
    private static let maximumNormalizationFeatureLossFraction = 0.02
    private static let maximumNormalizationBackingLossFraction = 0.001
    private static let minimumSegments: Int32 = 32

    static func build(_ input: MoldLinerRegistrationInput) throws -> MoldLinerRegistrationResult {
        try validate(input)
        if let auditSet = input.protectedAuditSet {
            let audit = auditSet.audit(finalParts: input.finalShellParts.map(\.part), stage: .linerRegistration)
            guard audit.passes else {
                throw MoldLinerRegistrationBuilderError.protectedToolingAuditFailed(
                    audit.diagnostics.joined(separator: " ")
                )
            }
        }
        let settings = input.settings.sanitized
        guard settings.mode != .none else {
            let auditSet = try input.protectedAuditSet ?? ProtectedToolingAuditSet(records: [])
            return MoldLinerRegistrationResult(
                shellParts: input.finalShellParts,
                siliconeAdditives: [],
                protectedRegions: [],
                sites: [],
                summary: LinerRegistrationSummary(state: .disabled),
                gateLip: nil,
                protectedAuditSet: auditSet
            )
        }

        let dimensions = try resolvedDimensions(offset: input.totalLinerOffset, override: input.buttonOverride)
        let candidates = surfaceCandidates(input.nominalLinerSurface)
        guard !candidates.isEmpty else { throw MoldLinerRegistrationBuilderError.invalidInput(.noNominalSurfaceCandidates) }
        let margin = dimensions.diameter / 2 + max(3, input.wallThickness)
        let spacing = 1.5 * dimensions.diameter
        var workingParts = input.finalShellParts.sorted { $0.id < $1.id }
        var sites: [SelectedSite] = []

        for part in workingParts {
            let valid = try candidates.compactMap { candidate -> Candidate? in
                guard angleDegrees(candidate.normal, normalized(part.demoldAxis)) <= 30,
                      distanceToNearestPartingPlane(candidate.position, input.partingPlanes) >= margin,
                      try clearsReserved(candidate.position, radius: margin, reserved: input.reservedGeometry.all),
                      try ownsCandidate(candidate, partID: part.id, parts: workingParts, dimensions: dimensions, wall: input.wallThickness)
                else { return nil }
                return candidate
            }
            let requested = settings.buttonsPerPart
            var chosen = chooseFarthest(
                from: valid,
                count: requested,
                preselected: sites.map(\.candidate),
                minimumSpacing: spacing
            )
            guard chosen.count == requested else {
                throw MoldLinerRegistrationBuilderError.requestedButtonsUnplaceable(
                    partID: part.id, requested: requested, placed: chosen.count
                )
            }
            if requested >= 2, !spansPrincipalDirections(chosen, surface: input.nominalLinerSurface) {
                let distributed = chooseDistributedFarthest(
                    from: valid,
                    count: requested,
                    preselected: sites.map(\.candidate),
                    minimumSpacing: spacing,
                    surface: input.nominalLinerSurface
                )
                guard distributed.count == requested else {
                    throw MoldLinerRegistrationBuilderError.distributionInsufficient(partID: part.id)
                }
                chosen = distributed
            }
            sites.append(contentsOf: chosen.enumerated().map { index, candidate in
                SelectedSite(partID: part.id, ordinal: index, candidate: candidate)
            })
        }

        var additives: [MoldLinerFillAdditiveVolume] = []
        var protected: [MoldLinerProtectedRegion] = []
        var appliedFeatures: [AppliedFeature] = []
        for selected in sites {
            let feature = try makeButton(
                at: selected.candidate.position,
                axis: selected.candidate.normal,
                dimensions: dimensions,
                wall: input.wallThickness
            )
            let index = try partIndex(selected.partID, in: workingParts)
            workingParts[index] = try apply(
                feature: feature,
                to: workingParts[index],
                wall: input.wallThickness,
                kind: .button(selected.ordinal)
            )
            appliedFeatures.append(AppliedFeature(partID: selected.partID, kind: .button(selected.ordinal), feature: feature))
            let id = "liner-registration-\(selected.partID.rawValue)-\(selected.ordinal + 1)"
            additives.append(MoldLinerFillAdditiveVolume(id: id, purpose: "rounded liner registration boss", solid: feature.boss))
            protected.append(MoldLinerProtectedRegion(id: id, purpose: .registration, solid: feature.boss))
        }

        var gateLip: MoldLinerRegistrationGateLipResult?
        if settings.gateLipEnabled {
            let datum = try requiredGateDatum(input.gateLipDatum)
            let lip = try applyGateLip(
                datum: datum,
                offset: input.totalLinerOffset,
                wall: input.wallThickness,
                partingPlanes: input.partingPlanes,
                parts: workingParts
            )
            workingParts = lip.parts
            additives.append(contentsOf: lip.additives)
            protected.append(contentsOf: lip.protected)
            appliedFeatures.append(contentsOf: lip.appliedFeatures)
            gateLip = lip.result
        }

        appliedFeatures = try backingWitnessesExcludingProtectedVoids(
            appliedFeatures,
            auditSet: input.protectedAuditSet
        )
        workingParts = try normalizedAndReproved(parts: workingParts, appliedFeatures: appliedFeatures)
        workingParts = try clearProtectedVoids(
            from: workingParts,
            auditSet: input.protectedAuditSet
        )
        workingParts = try normalizedAndReproved(parts: workingParts, appliedFeatures: appliedFeatures)
        let registrationAuditRecords = try auditRecords(
            for: appliedFeatures,
            finalParts: workingParts
        )
        let completeAuditSet = try (input.protectedAuditSet ?? ProtectedToolingAuditSet(records: []))
            .appending(registrationAuditRecords)
        let completeAudit = completeAuditSet.audit(
            finalParts: workingParts.map(\.part),
            stage: .linerRegistration
        )
        guard completeAudit.passes else {
            throw MoldLinerRegistrationBuilderError.protectedToolingAuditFailed(
                completeAudit.diagnostics.joined(separator: " ")
            )
        }

        let publicSites = sites.map { selected in
            LinerRegistrationSite(
                id: "liner-registration-\(selected.partID.rawValue)-\(selected.ordinal + 1)",
                shellPartID: selected.partID,
                center: codable(selected.candidate.position),
                demoldAxis: codable(selected.candidate.normal),
                diameterMillimeters: dimensions.diameter,
                depthMillimeters: dimensions.depth
            )
        }
        let summary = LinerRegistrationSummary(
            state: .geometryVerified,
            requestedButtonCount: settings.buttonsPerPart * workingParts.count,
            sites: publicSites,
            gateLipEnabled: gateLip != nil,
            gateLipDepthMillimeters: gateLip == nil ? nil : resolvedGateLipDepth(input.totalLinerOffset),
            notes: ["Rounded outward silicone bosses, shell recesses, housings, and backing witnesses are geometry-verified."]
        )
        return MoldLinerRegistrationResult(
            shellParts: workingParts,
            siliconeAdditives: additives,
            protectedRegions: protected,
            sites: publicSites,
            summary: summary,
            gateLip: gateLip,
            protectedAuditSet: completeAuditSet
        )
    }

    private struct Candidate: Equatable {
        var position: Vec3
        var normal: Vec3
        var stableIndex: Int
    }

    private struct SelectedSite {
        var partID: ToolingArtifactID
        var ordinal: Int
        var candidate: Candidate
    }

    private struct Feature {
        var boss: MeshGeometryData
        var recess: MeshGeometryData
        var housing: MeshGeometryData
        var backingWitness: MeshGeometryData
    }

    private struct AppliedFeature {
        var partID: ToolingArtifactID
        var kind: MoldLinerRegistrationFeatureKind
        var feature: Feature
    }

    private struct GateLipApplication {
        var parts: [MoldLinerRegistrationShellPart]
        var additives: [MoldLinerFillAdditiveVolume]
        var protected: [MoldLinerProtectedRegion]
        var appliedFeatures: [AppliedFeature]
        var result: MoldLinerRegistrationGateLipResult
    }

    private static func auditRecords(
        for features: [AppliedFeature],
        finalParts: [MoldLinerRegistrationShellPart]
    ) throws -> [ProtectedToolingAuditSet.Record] {
        try features.enumerated().flatMap { index, applied -> [ProtectedToolingAuditSet.Record] in
            guard case .button(let ordinal) = applied.kind else {
                // The captured gate housing is intentionally reshaped by the
                // removable funnel envelope. Flow records its final rigid stop
                // instead of preserving this obsolete pre-flow witness.
                return []
            }
            guard let owner = finalParts.first(where: { $0.id == applied.partID }) else {
                throw MoldLinerRegistrationBuilderError.serializedGeometryUnsafe(partID: applied.partID)
            }
            let ownerSolid = try ManifoldEngine.make(from: owner.part.geometry)
            let housing = try ManifoldEngine.make(from: applied.feature.housing)
            let retainedHousing = try ManifoldEngine.intersect(housing, ownerSolid)
            guard !ManifoldEngine.isEmpty(retainedHousing),
                  ManifoldEngine.isWatertight(retainedHousing),
                  abs(ManifoldEngine.volume(retainedHousing)) > ProtectedToolingAuditSet.minimumMeasurableVolumeMM3 else {
                throw MoldLinerRegistrationBuilderError.featureDidNotSurvive(
                    partID: applied.partID,
                    feature: applied.kind
                )
            }
            let featureLabel = "button-\(ordinal + 1)"
            let prefix = "liner-registration-\(index + 1)-\(featureLabel)-\(owner.part.name)"
            return [
                ProtectedToolingAuditSet.Record(
                    id: "\(prefix)-housing",
                    kind: .linerHousing,
                    behavior: .additive,
                    ownership: .singlePart(owner.part.name),
                    geometry: try normalizedAuditGeometry(
                        try ManifoldEngine.toMesh(retainedHousing),
                        id: "\(prefix)-housing"
                    ),
                    requiredRetention: 0.98,
                    provenance: [.linerRegistration]
                ),
                ProtectedToolingAuditSet.Record(
                    id: "\(prefix)-recess",
                    kind: .linerRecess,
                    behavior: .subtractive,
                    ownership: .singlePart(owner.part.name),
                    geometry: try normalizedAuditGeometry(
                        applied.feature.recess,
                        id: "\(prefix)-recess"
                    ),
                    requiredRetention: 1,
                    requiredClearance: 0.98,
                    provenance: [.linerRegistration]
                ),
            ]
        }
    }

    private static func normalizedAuditGeometry(
        _ geometry: MeshGeometryData,
        id: String
    ) throws -> MeshGeometryData {
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: id,
            geometry: geometry
        )])
        guard validation.allPartsWatertight,
              let normalized = validation.parts.first,
              MeshPreflight.analyze(geometry: normalized.geometry).isWatertight else {
            throw MoldLinerRegistrationBuilderError.protectedToolingAuditFailed(
                "\(id) could not be serialized as a strict audit witness"
            )
        }
        return normalized.geometry
    }

    private static func clearProtectedVoids(
        from parts: [MoldLinerRegistrationShellPart],
        auditSet: ProtectedToolingAuditSet?
    ) throws -> [MoldLinerRegistrationShellPart] {
        guard let auditSet else { return parts }
        let voids = auditSet.records.filter { $0.behavior == .subtractive }
        guard !voids.isEmpty else { return parts }

        var result = parts
        for index in result.indices {
            var shell = try ManifoldEngine.make(from: result[index].part.geometry)
            for record in voids {
                let applies: Bool
                switch record.ownership {
                case .assembly:
                    applies = true
                case .singlePart(let name):
                    applies = name == result[index].part.name
                case .parts(let names):
                    applies = names.contains(result[index].part.name)
                }
                guard applies else { continue }
                shell = try ManifoldEngine.difference(
                    shell,
                    try ManifoldEngine.make(from: record.geometry)
                )
            }
            guard ManifoldEngine.isWatertight(shell), !ManifoldEngine.isEmpty(shell) else {
                throw MoldLinerRegistrationBuilderError.protectedToolingAuditFailed(
                    "clearing required voids made \(result[index].id.rawValue) empty or non-watertight"
                )
            }
            result[index].part.geometry = try ManifoldEngine.toMesh(shell)
            result[index].part.bounds = ManifoldEngine.bounds(shell)
            result[index].part.isWatertight = true
        }
        return result
    }

    private static func backingWitnessesExcludingProtectedVoids(
        _ features: [AppliedFeature],
        auditSet: ProtectedToolingAuditSet?
    ) throws -> [AppliedFeature] {
        guard let auditSet else { return features }
        let voids = auditSet.records.filter { $0.behavior == .subtractive }
        guard !voids.isEmpty else { return features }

        return try features.map { applied in
            var witness = try ManifoldEngine.make(from: applied.feature.backingWitness)
            for record in voids {
                let applies: Bool
                switch record.ownership {
                case .assembly:
                    applies = true
                case .singlePart(let name):
                    applies = name == applied.partID.rawValue
                case .parts(let names):
                    applies = names.contains(applied.partID.rawValue)
                }
                guard applies else { continue }
                witness = try ManifoldEngine.difference(
                    witness,
                    try ManifoldEngine.make(from: record.geometry)
                )
            }
            guard ManifoldEngine.isWatertight(witness),
                  !ManifoldEngine.isEmpty(witness),
                  abs(ManifoldEngine.volume(witness)) > containmentTolerance else {
                throw MoldLinerRegistrationBuilderError.backingBelowMinimum(
                    partID: applied.partID,
                    feature: applied.kind
                )
            }
            var updated = applied
            updated.feature.backingWitness = try ManifoldEngine.toMesh(witness)
            return updated
        }
    }

    private static func validate(_ input: MoldLinerRegistrationInput) throws {
        guard input.totalLinerOffset.isFinite, input.totalLinerOffset > 0 else {
            throw MoldLinerRegistrationBuilderError.invalidInput(.nonPositiveOffset)
        }
        guard input.wallThickness.isFinite, input.wallThickness > 0 else {
            throw MoldLinerRegistrationBuilderError.invalidInput(.nonPositiveWallThickness)
        }
        guard !input.finalShellParts.isEmpty else {
            throw MoldLinerRegistrationBuilderError.invalidInput(.emptyShellParts)
        }
        var ids = Set<ToolingArtifactID>()
        for part in input.finalShellParts {
            guard ids.insert(part.id).inserted else {
                throw MoldLinerRegistrationBuilderError.invalidInput(.duplicateShellPartID(part.id))
            }
            guard let solid = try? ManifoldEngine.make(from: part.part.geometry),
                  ManifoldEngine.isWatertight(solid), abs(ManifoldEngine.volume(solid)) > containmentTolerance
            else { throw MoldLinerRegistrationBuilderError.invalidInput(.invalidShellPart(part.id)) }
            guard length(part.demoldAxis) > 1.0e-9 else {
                throw MoldLinerRegistrationBuilderError.invalidInput(.invalidDemoldAxis(part.id))
            }
        }
        for feature in input.reservedGeometry.all {
            guard let solid = try? ManifoldEngine.make(from: feature.solid), ManifoldEngine.isWatertight(solid) else {
                throw MoldLinerRegistrationBuilderError.invalidInput(.invalidReservedFeature(feature.id))
            }
        }
    }

    private static func resolvedDimensions(
        offset: Double,
        override: MoldLinerRegistrationButtonDimensions?
    ) throws -> MoldLinerRegistrationButtonDimensions {
        let dimensions = override ?? MoldLinerRegistrationButtonDimensions(
            diameter: clamp(2.5 * offset, 10, 24),
            depth: clamp(offset * 3 / 5, 3, 6),
            draftDegrees: 12
        )
        guard dimensions.diameter.isFinite, dimensions.depth.isFinite, dimensions.draftDegrees.isFinite,
              dimensions.diameter >= 2, dimensions.depth >= 1, dimensions.draftDegrees >= 0, dimensions.draftDegrees <= 20
        else { throw MoldLinerRegistrationBuilderError.invalidInput(.invalidButtonDimensions) }
        return dimensions
    }

    private static func surfaceCandidates(_ surface: MeshGeometryData) -> [Candidate] {
        var normals = [Vec3](repeating: Vec3(x: 0, y: 0, z: 0), count: surface.vertices.count)
        var triangle = 0
        while triangle + 2 < surface.triangleIndices.count {
            let ids = [Int(surface.triangleIndices[triangle]), Int(surface.triangleIndices[triangle + 1]), Int(surface.triangleIndices[triangle + 2])]
            guard ids.allSatisfy(surface.vertices.indices.contains) else { triangle += 3; continue }
            let a = surface.vertices[ids[0]], b = surface.vertices[ids[1]], c = surface.vertices[ids[2]]
            let normal = cross(subtract(b, a), subtract(c, a))
            for id in ids { normals[id] = add(normals[id], normal) }
            triangle += 3
        }
        return surface.vertices.enumerated().compactMap { index, vertex in
            guard length(normals[index]) > 1.0e-9 else { return nil }
            return Candidate(position: vertex, normal: normalized(normals[index]), stableIndex: index)
        }
    }

    private static func chooseFarthest(
        from candidates: [Candidate],
        count: Int,
        preselected: [Candidate],
        minimumSpacing: Double
    ) -> [Candidate] {
        guard count > 0 else { return [] }
        var remaining = candidates.sorted { $0.stableIndex < $1.stableIndex }
        var selected: [Candidate] = []
        while selected.count < count {
            let references = preselected + selected
            let eligible = remaining.filter { candidate in
                references.allSatisfy { distance(candidate.position, $0.position) >= minimumSpacing }
            }
            guard !eligible.isEmpty else { break }
            let next = eligible.max { lhs, rhs in
                let lhsScore = farthestScore(lhs, against: references, candidates: remaining)
                let rhsScore = farthestScore(rhs, against: references, candidates: remaining)
                return lhsScore == rhsScore ? lhs.stableIndex > rhs.stableIndex : lhsScore < rhsScore
            }!
            selected.append(next)
            remaining.removeAll { $0.stableIndex == next.stableIndex }
        }
        return selected
    }

    private static func farthestScore(_ candidate: Candidate, against selected: [Candidate], candidates: [Candidate]) -> Double {
        if selected.isEmpty {
            return candidates.reduce(0) { $0 + distance(candidate.position, $1.position) }
        }
        return selected.map { distance(candidate.position, $0.position) }.min() ?? 0
    }

    /// Seed the requested pattern with a pair that proves the non-clustering
    /// contract, then complete the remaining positions with the normal farthest
    /// point rule. This is only used after the unconstrained greedy pass found
    /// an exact count but failed the two-principal-directions invariant.
    private static func chooseDistributedFarthest(
        from candidates: [Candidate],
        count: Int,
        preselected: [Candidate],
        minimumSpacing: Double,
        surface: MeshGeometryData
    ) -> [Candidate] {
        guard count >= 2 else { return chooseFarthest(from: candidates, count: count, preselected: preselected, minimumSpacing: minimumSpacing) }
        let eligible = candidates.filter { candidate in
            preselected.allSatisfy { distance(candidate.position, $0.position) >= minimumSpacing }
        }
        var seed: (first: Candidate, second: Candidate, score: Double)?
        for firstIndex in eligible.indices {
            for secondIndex in eligible.indices where secondIndex > firstIndex {
                let first = eligible[firstIndex], second = eligible[secondIndex]
                guard distance(first.position, second.position) >= minimumSpacing,
                      spansPrincipalDirections([first, second], surface: surface)
                else { continue }
                let score = 2 * distance(first.position, second.position) + [first, second].reduce(0) { partial, candidate in
                    partial + (preselected.map { distance(candidate.position, $0.position) }.min() ?? 0)
                }
                if seed == nil || score > seed!.score || (score == seed!.score && (first.stableIndex, second.stableIndex) < (seed!.first.stableIndex, seed!.second.stableIndex)) {
                    seed = (first, second, score)
                }
            }
        }
        guard let seed else { return [] }
        let remainder = chooseFarthest(
            from: eligible,
            count: count - 2,
            preselected: preselected + [seed.first, seed.second],
            minimumSpacing: minimumSpacing
        )
        guard remainder.count == count - 2 else { return [] }
        return [seed.first, seed.second] + remainder
    }

    private static func spansPrincipalDirections(_ sites: [Candidate], surface: MeshGeometryData) -> Bool {
        guard sites.count >= 2, !surface.vertices.isEmpty else { return true }
        let normalSum = sites.reduce(Vec3(x: 0, y: 0, z: 0)) { add($0, $1.normal) }
        guard length(normalSum) > 1.0e-9 else { return false }
        let basis = perpendicularBasis(normalized(normalSum))

        func span(_ points: [Vec3], along axis: Vec3) -> Double {
            let values = points.map { dot($0, axis) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }

        // Registration is distributed in the local shell tangent plane. Using
        // the source's world-axis extents incorrectly asks two buttons on a
        // planar cube face to vary along that face's fixed normal coordinate.
        let surfaceU = span(surface.vertices, along: basis.0)
        let surfaceV = span(surface.vertices, along: basis.1)
        let sitePoints = sites.map(\.position)
        return span(sitePoints, along: basis.0) >= surfaceU * 0.25
            && span(sitePoints, along: basis.1) >= surfaceV * 0.25
    }

    private static func clearsReserved(
        _ point: Vec3,
        radius: Double,
        reserved: [MoldLinerRegistrationReservedFeature]
    ) throws -> Bool {
        let probe = try translatedSphere(center: point, radius: radius)
        for feature in reserved {
            let solid = try ManifoldEngine.make(from: feature.solid)
            let overlap = try ManifoldEngine.intersect(probe, solid)
            if abs(ManifoldEngine.volume(overlap)) > containmentTolerance { return false }
        }
        return true
    }

    private static func ownsCandidate(
        _ candidate: Candidate,
        partID: ToolingArtifactID,
        parts: [MoldLinerRegistrationShellPart],
        dimensions: MoldLinerRegistrationButtonDimensions,
        wall: Double
    ) throws -> Bool {
        let probe = try housingSolid(at: candidate.position, axis: candidate.normal, dimensions: dimensions, wall: wall)
        var owners: [ToolingArtifactID] = []
        for part in parts {
            let solid = try ManifoldEngine.make(from: part.part.geometry)
            let overlap = try ManifoldEngine.intersect(probe, solid)
            if abs(ManifoldEngine.volume(overlap)) > containmentTolerance { owners.append(part.id) }
        }
        return owners == [partID]
    }

    private static func makeButton(
        at center: Vec3,
        axis: Vec3,
        dimensions: MoldLinerRegistrationButtonDimensions,
        wall: Double
    ) throws -> Feature {
        let axis = normalized(axis)
        let radius = dimensions.diameter / 2
        let embed = min(1, dimensions.depth * 0.15)
        let topRadius = max(radius * 0.5, radius - tan(dimensions.draftDegrees * .pi / 180) * dimensions.depth)
        let boss = try roundedSolid(
            center: center, axis: axis,
            profile: [
                (-embed - 0.35 * radius, 0.12 * radius), (-embed, 0.70 * radius),
                (0, radius), (dimensions.depth * 0.55, radius),
                (dimensions.depth * 0.85, topRadius), (dimensions.depth, 0.55 * topRadius),
                (dimensions.depth + 0.35 * topRadius, 0.12 * topRadius),
            ]
        )
        let recessRadius = radius + clearance
        let recessTop = max(recessRadius * 0.5, recessRadius - tan(dimensions.draftDegrees * .pi / 180) * (dimensions.depth + clearance))
        let recessEnd = dimensions.depth + clearance + 0.35 * recessTop
        let recess = try roundedSolid(
            center: center, axis: axis,
            profile: [
                (-embed - clearance - 0.35 * recessRadius, 0.12 * recessRadius),
                (-embed - clearance, 0.70 * recessRadius), (0, recessRadius),
                ((dimensions.depth + clearance) * 0.55, recessRadius),
                ((dimensions.depth + clearance) * 0.85, recessTop),
                (dimensions.depth + clearance, 0.55 * recessTop),
                (recessEnd, 0.12 * recessTop),
            ]
        )
        let housing = try housingSolid(at: center, axis: axis, dimensions: dimensions, wall: wall)
        let witness = try roundedSolid(
            center: center, axis: axis,
            profile: [
                (recessEnd + 0.05, min(1, max(0.35, wall * 0.2))),
                (recessEnd + wall, min(1, max(0.35, wall * 0.2))),
            ]
        )
        return Feature(boss: try ManifoldEngine.toMesh(boss), recess: try ManifoldEngine.toMesh(recess), housing: try ManifoldEngine.toMesh(housing), backingWitness: try ManifoldEngine.toMesh(witness))
    }

    private static func housingSolid(
        at center: Vec3,
        axis: Vec3,
        dimensions: MoldLinerRegistrationButtonDimensions,
        wall: Double
    ) throws -> ManifoldHandle {
        let radius = dimensions.diameter / 2 + clearance + max(2, wall)
        let length = dimensions.depth + wall + 2
        return try roundedSolid(
            center: center, axis: axis,
            profile: [(-1.5, 0.15 * radius), (-1, 0.85 * radius), (0, radius), (length, radius), (length + 0.5 * radius, 0.15 * radius)]
        )
    }

    private static func apply(
        feature: Feature,
        to shell: MoldLinerRegistrationShellPart,
        wall: Double,
        kind: MoldLinerRegistrationFeatureKind
    ) throws -> MoldLinerRegistrationShellPart {
        let original = try ManifoldEngine.make(from: shell.part.geometry)
        let boss = try ManifoldEngine.make(from: feature.boss)
        let housing = try ManifoldEngine.make(from: feature.housing)
        let recess = try ManifoldEngine.make(from: feature.recess)
        guard ManifoldEngine.isWatertight(boss), ManifoldEngine.isWatertight(housing), ManifoldEngine.isWatertight(recess) else {
            throw MoldLinerRegistrationBuilderError.featureDidNotSurvive(partID: shell.id, feature: kind)
        }
        let updated = try ManifoldEngine.difference(try ManifoldEngine.union(original, housing), recess)
        guard ManifoldEngine.isWatertight(updated), abs(ManifoldEngine.volume(updated)) > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.featureDidNotSurvive(partID: shell.id, feature: kind)
        }
        try prove(feature: feature, survives: updated, partID: shell.id, kind: kind)
        var copy = shell
        copy.part.geometry = try ManifoldEngine.toMesh(updated)
        copy.part.isWatertight = true
        copy.part.bounds = ManifoldEngine.bounds(updated)
        return copy
    }

    /// MotherMoldValidation is the bounded serialization repair contract. Its
    /// output, rather than Manifold's in-memory topology flag, is what later
    /// writers receive. Re-run each requested feature witness on that output.
    private static func normalizedAndReproved(
        parts: [MoldLinerRegistrationShellPart],
        appliedFeatures: [AppliedFeature]
    ) throws -> [MoldLinerRegistrationShellPart] {
        let validation = MotherMoldValidation.validate(parts: parts.map(\.part))
        guard validation.allPartsWatertight, validation.parts.count == parts.count else {
            let invalid = zip(parts, validation.parts).first { _, validated in !validated.isWatertight }?.0.id
                ?? parts.first?.id
            throw MoldLinerRegistrationBuilderError.serializedGeometryUnsafe(partID: invalid!)
        }

        var normalized = parts
        for index in normalized.indices {
            normalized[index].part = validation.parts[index]
            guard MeshPreflight.analyze(geometry: normalized[index].part.geometry).isWatertight else {
                throw MoldLinerRegistrationBuilderError.serializedGeometryUnsafe(partID: normalized[index].id)
            }
        }
        for applied in appliedFeatures {
            guard let shell = normalized.first(where: { $0.id == applied.partID }) else {
                throw MoldLinerRegistrationBuilderError.serializedGeometryUnsafe(partID: applied.partID)
            }
            let solid = try ManifoldEngine.make(from: shell.part.geometry)
            try prove(feature: applied.feature, survives: solid, partID: applied.partID, kind: applied.kind)
        }
        return normalized
    }

    private static func prove(
        feature: Feature,
        survives updated: ManifoldHandle,
        partID: ToolingArtifactID,
        kind: MoldLinerRegistrationFeatureKind
    ) throws {
        let housing = try ManifoldEngine.make(from: feature.housing)
        let recess = try ManifoldEngine.make(from: feature.recess)
        let survivingHousing = try ManifoldEngine.intersect(housing, updated)
        let survivingHousingVolume = abs(ManifoldEngine.volume(survivingHousing))
        guard survivingHousingVolume > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.featureRetentionFailed(
                partID: partID,
                feature: kind,
                detail: String(format: "housing retained only %.6f mm3", survivingHousingVolume)
            )
        }
        let recessMissingFromShell = try ManifoldEngine.difference(recess, updated)
        let recessVolume = abs(ManifoldEngine.volume(recess))
        let clearRecessVolume = abs(ManifoldEngine.volume(recessMissingFromShell))
        let allowedFeatureLoss = max(
            containmentTolerance,
            recessVolume * maximumNormalizationFeatureLossFraction
        )
        guard clearRecessVolume >= recessVolume - allowedFeatureLoss else {
            throw MoldLinerRegistrationBuilderError.featureRetentionFailed(
                partID: partID,
                feature: kind,
                detail: String(
                    format: "recess is %.6f of %.6f mm3 clear (required %.6f mm3)",
                    clearRecessVolume,
                    recessVolume,
                    recessVolume - allowedFeatureLoss
                )
            )
        }
        let witness = try ManifoldEngine.make(from: feature.backingWitness)
        let missingBacking = try ManifoldEngine.difference(witness, updated)
        // The validator is bounded to 0.05 mm; allow only its tiny boundary
        // adjustment, while rejecting any material loss that could weaken the
        // requested backing volume.
        let allowedLoss = max(
            containmentTolerance,
            abs(ManifoldEngine.volume(witness)) * maximumNormalizationBackingLossFraction
        )
        guard abs(ManifoldEngine.volume(missingBacking)) <= allowedLoss else {
            throw MoldLinerRegistrationBuilderError.backingBelowMinimum(partID: partID, feature: kind)
        }
    }

    private static func applyGateLip(
        datum: MoldLinerRegistrationGateLipDatum,
        offset: Double,
        wall: Double,
        partingPlanes: [PartitionPlane],
        parts: [MoldLinerRegistrationShellPart]
    ) throws -> GateLipApplication {
        guard datum.gateDiameter.isFinite, datum.gateDiameter > 0, length(datum.axis) > 1.0e-9,
              let collar = try? ManifoldEngine.make(from: datum.collarSolid), ManifoldEngine.isWatertight(collar)
        else { throw MoldLinerRegistrationBuilderError.invalidInput(.invalidGateDatum) }
        guard let plane = partingPlanes.first(where: { $0.id == datum.splitPartingPlaneID }) else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: datum.splitPartingPlaneID)
        }
        let sealContactPoint = vec3(datum.linerSealPoint)
        let stopContactPoint = vec3(datum.rigidStopContactPoint)
        let axis = normalized(datum.axis)
        let stopSpan = dot(subtract(stopContactPoint, sealContactPoint), axis)
        guard stopSpan > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.invalidFunnelSealDatum
        }
        guard abs(dot(sealContactPoint, plane.normal) - plane.offset) < datum.gateDiameter / 2 + resolvedGateLipDepth(offset) else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        guard abs(dot(axis, plane.normal)) < 0.95 else { throw MoldLinerRegistrationBuilderError.gateLipHasNoReleasePath }
        let lipDepth = resolvedGateLipDepth(offset)
        let gateRadius = datum.gateDiameter / 2
        // Keep the bead outside both the liquid gate and the removable funnel
        // nozzle's declared tooling wall, rather than merely equaling the gate.
        let beadInnerRadius = gateRadius + max(1.25, clearance)
        let beadOuterRadius = beadInnerRadius + max(0.8, wall * 0.2)
        let stopInnerRadius = beadOuterRadius + max(0.25, clearance)
        let stopOuterRadius = stopInnerRadius + max(1, wall * 0.4)
        let outer = try roundedSolid(center: sealContactPoint, axis: axis, profile: [(-0.75, 0.2), (-0.3, datum.gateDiameter / 2 + lipDepth), (lipDepth, datum.gateDiameter / 2 + lipDepth), (lipDepth + 0.5, 0.2)])
        let inner = try roundedSolid(center: sealContactPoint, axis: axis, profile: [(-2, 0.2), (-1, datum.gateDiameter / 2), (lipDepth + 1, datum.gateDiameter / 2), (lipDepth + 2, 0.2)])
        let fullLip = try ManifoldEngine.difference(outer, inner)
        let fullLipMesh = try ManifoldEngine.toMesh(fullLip)
        let split = try ManifoldEngine.splitByPlane(fullLip, normal: plane.normal, offset: plane.offset)
        guard !ManifoldEngine.isEmpty(split.0), !ManifoldEngine.isEmpty(split.1) else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        // Use a flat-ended annular bead. The funnel's measured compression land
        // enters this exact end face by 2-10%; a tapered cap would provide no
        // annular contact at its declared axial maximum.
        let nominalBeadHeight = min(max(1, wall * 0.25), stopSpan)
        // The bead occupies the liner side of the silicone/shell interface;
        // its outward contact face is the exact prepared-master silicone station.
        let sealCenter = add(sealContactPoint, scale(axis, -nominalBeadHeight / 2))
        let sealOuter = try roundedSolid(
            center: sealCenter,
            axis: axis,
            profile: [(-nominalBeadHeight / 2, beadOuterRadius), (nominalBeadHeight / 2, beadOuterRadius)]
        )
        let sealInner = try roundedSolid(
            center: sealCenter,
            axis: axis,
            profile: [(-nominalBeadHeight / 2 - 0.1, beadInnerRadius), (nominalBeadHeight / 2 + 0.1, beadInnerRadius)]
        )
        let bead = try ManifoldEngine.difference(sealOuter, sealInner)
        let beadMesh = try ManifoldEngine.toMesh(bead)
        // The rigid stop is shell material over the exact interval from the
        // liner seal to the declared shell-outer contact plane.
        let stopOuter = try roundedSolid(center: sealContactPoint, axis: axis, profile: [(0, stopOuterRadius), (stopSpan, stopOuterRadius)])
        let stopInner = try roundedSolid(center: sealContactPoint, axis: axis, profile: [(-0.1, stopInnerRadius), (stopSpan + 0.1, stopInnerRadius)])
        let stop = try ManifoldEngine.difference(stopOuter, stopInner)

        var updated = parts
        var segmentAdditives: [MoldLinerFillAdditiveVolume] = []
        var appliedFeatures: [AppliedFeature] = []
        for (index, segment) in [split.0, split.1].enumerated() {
            let segmentMesh = try ManifoldEngine.toMesh(segment)
            let owner = try owner(of: segment, in: updated, plane: plane)
            let inflated = try ManifoldEngine.minkowskiSum(segment, try ManifoldEngine.sphere(radius: clearance, segments: minimumSegments))
            let housing = try ManifoldEngine.minkowskiSum(segment, try ManifoldEngine.sphere(radius: wall + 1, segments: minimumSegments))
            // The source lip is split, but Minkowski expansion crosses the
            // datum plane. Keep every applied volume on its established owner
            // side so adjacent partitioned shell parts cannot gain overlap.
            let clippedInflated = try clippedToOwnerHalfSpace(inflated, owner: owner, parts: updated, plane: plane)
            let clippedHousing = try clippedToOwnerHalfSpace(housing, owner: owner, parts: updated, plane: plane)
            let backing = try ManifoldEngine.difference(clippedHousing, clippedInflated)
            let feature = Feature(
                boss: segmentMesh,
                recess: try ManifoldEngine.toMesh(clippedInflated),
                housing: try ManifoldEngine.toMesh(clippedHousing),
                backingWitness: try ManifoldEngine.toMesh(backing)
            )
            let partIndex = try self.partIndex(owner, in: updated)
            updated[partIndex] = try apply(feature: feature, to: updated[partIndex], wall: wall, kind: .gateLip(index))
            appliedFeatures.append(AppliedFeature(partID: owner, kind: .gateLip(index), feature: feature))
            let id = "captured-gate-lip-\(index + 1)"
            segmentAdditives.append(MoldLinerFillAdditiveVolume(id: id, purpose: "split rigid-shell ownership of the captured gate lip", solid: segmentMesh))
        }
        let stopMesh = try ManifoldEngine.toMesh(stop)
        let beadHeight = projectionBounds(beadMesh, axis: axis).max - projectionBounds(beadMesh, axis: axis).min
        guard beadHeight > 0,
              beadInnerRadius > gateRadius,
              beadOuterRadius > beadInnerRadius,
              stopOuterRadius > stopInnerRadius,
              MotherMoldValidation.surfaceClosure(beadMesh).closed,
              MotherMoldValidation.surfaceClosure(stopMesh).closed else {
            throw MoldLinerRegistrationBuilderError.invalidFunnelSealDatum
        }
        let capturedGateSeal = try ManifoldEngine.union(fullLip, bead)
        let capturedGateSealAdditive = MoldLinerFillAdditiveVolume(
            id: "captured-gate-lip-and-seal",
            purpose: "continuous captured silicone gate lip and annular funnel seal",
            solid: try ManifoldEngine.toMesh(capturedGateSeal)
        )
        return GateLipApplication(
            parts: updated,
            additives: [capturedGateSealAdditive],
            protected: [
                MoldLinerProtectedRegion(id: "captured-gate-lip", purpose: .gateLip, solid: fullLipMesh),
                MoldLinerProtectedRegion(id: "funnel-seal-bead", purpose: .funnelSeal, solid: beadMesh),
            ],
            appliedFeatures: appliedFeatures,
            result: MoldLinerRegistrationGateLipResult(
                splitPlaneID: plane.id,
                lipSegments: segmentAdditives,
                funnelSeal: MoldLinerRegistrationFunnelSealDatum(
                    bead: beadMesh,
                    compressionStop: stopMesh,
                    beadInnerRadiusMillimeters: beadInnerRadius,
                    beadOuterRadiusMillimeters: beadOuterRadius,
                    beadHeightMillimeters: beadHeight,
                    stopInnerRadiusMillimeters: stopInnerRadius,
                    stopOuterRadiusMillimeters: stopOuterRadius,
                    sealContactPoint: codable(sealContactPoint),
                    stopContactPoint: codable(stopContactPoint),
                    releaseAxis: codable(axis),
                    selectedSplitPlaneID: plane.id,
                    fixtureHandoffID: datum.fixtureHandoffID,
                    roundedThroatRadiusMillimeters: max(1, min(wall / 2, beadOuterRadius - beadInnerRadius))
                )
            )
        )
    }

    private static func clippedToOwnerHalfSpace(
        _ solid: ManifoldHandle,
        owner: ToolingArtifactID,
        parts: [MoldLinerRegistrationShellPart],
        plane: PartitionPlane
    ) throws -> ManifoldHandle {
        guard let ownerPart = parts.first(where: { $0.id == owner }) else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        let ownerSolid = try ManifoldEngine.make(from: ownerPart.part.geometry)
        let ownerSide = dot(boundsCenter(ManifoldEngine.bounds(ownerSolid)), plane.normal) - plane.offset
        guard abs(ownerSide) > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        let halves = try ManifoldEngine.splitByPlane(solid, normal: plane.normal, offset: plane.offset)
        let clipped = ownerSide > 0 ? halves.0 : halves.1
        guard !ManifoldEngine.isEmpty(clipped), abs(ManifoldEngine.volume(clipped)) > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.featureDidNotSurvive(partID: owner, feature: .gateLip(0))
        }
        return clipped
    }

    private static func owner(
        of solid: ManifoldHandle,
        in parts: [MoldLinerRegistrationShellPart],
        plane: PartitionPlane
    ) throws -> ToolingArtifactID {
        let owners = try parts.compactMap { part -> ToolingArtifactID? in
            let shell = try ManifoldEngine.make(from: part.part.geometry)
            let overlap = try ManifoldEngine.intersect(solid, shell)
            return abs(ManifoldEngine.volume(overlap)) > containmentTolerance ? part.id : nil
        }
        if owners.count == 1, let owner = owners.first { return owner }

        // Manifold closes a split half on its datum face, so it can report a
        // tolerance-sized overlap with both shell halves. Resolve that case from
        // the explicit split datum, while retaining a typed block for any part
        // layout that is not unambiguously on the lip half's side of the plane.
        let solidCenter = boundsCenter(ManifoldEngine.bounds(solid))
        let solidSide = dot(solidCenter, plane.normal) - plane.offset
        guard abs(solidSide) > containmentTolerance else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        let sideOwners = try owners.filter { id in
            guard let part = parts.first(where: { $0.id == id }) else { return false }
            let shell = try ManifoldEngine.make(from: part.part.geometry)
            let partCenter = boundsCenter(ManifoldEngine.bounds(shell))
            return (dot(partCenter, plane.normal) - plane.offset) * solidSide > containmentTolerance
        }
        guard sideOwners.count == 1, let owner = sideOwners.first else {
            throw MoldLinerRegistrationBuilderError.invalidGateLipSplit(planeID: plane.id)
        }
        return owner
    }

    private static func requiredGateDatum(_ datum: MoldLinerRegistrationGateLipDatum?) throws -> MoldLinerRegistrationGateLipDatum {
        guard let datum else { throw MoldLinerRegistrationBuilderError.missingGateLipDatum }
        return datum
    }

    private static func roundedSolid(center: Vec3, axis: Vec3, profile: [(Double, Double)]) throws -> ManifoldHandle {
        precondition(profile.count >= 2)
        let axis = normalized(axis)
        let (u, v) = perpendicularBasis(axis)
        var vertices: [Vec3] = []
        for (z, radius) in profile {
            for segment in 0..<Int(minimumSegments) {
                let theta = 2 * Double.pi * Double(segment) / Double(minimumSegments)
                vertices.append(add(center, add(scale(axis, z), add(scale(u, radius * cos(theta)), scale(v, radius * sin(theta))))))
            }
        }
        let bottomCenter = vertices.count
        vertices.append(add(center, scale(axis, profile[0].0)))
        let topCenter = vertices.count
        vertices.append(add(center, scale(axis, profile[profile.count - 1].0)))
        var indices: [Int32] = []
        let segments = Int(minimumSegments)
        for ring in 0..<(profile.count - 1) {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = ring * segments + segment, b = ring * segments + next
                let c = (ring + 1) * segments + segment, d = (ring + 1) * segments + next
                indices += [Int32(a), Int32(b), Int32(d), Int32(a), Int32(d), Int32(c)]
            }
        }
        for segment in 0..<segments {
            let next = (segment + 1) % segments
            indices += [Int32(bottomCenter), Int32(next), Int32(segment)]
            let topBase = (profile.count - 1) * segments
            indices += [Int32(topCenter), Int32(topBase + segment), Int32(topBase + next)]
        }
        return try ManifoldEngine.make(from: MeshGeometryData(vertices: vertices, triangleIndices: indices))
    }

    private static func translatedSphere(center: Vec3, radius: Double) throws -> ManifoldHandle {
        try ManifoldEngine.translate(ManifoldEngine.sphere(radius: radius, segments: minimumSegments), x: center.x, y: center.y, z: center.z)
    }

    private static func distanceToNearestPartingPlane(_ point: Vec3, _ planes: [PartitionPlane]) -> Double {
        planes.map { abs(dot(point, $0.normal) - $0.offset) }.min() ?? .infinity
    }

    private static func boundsCenter(_ bounds: Bounds3D) -> Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }

    private static func projectionBounds(_ mesh: MeshGeometryData, axis: Vec3) -> (min: Double, max: Double) {
        let projections = mesh.vertices.map { dot($0, axis) }
        return (projections.min() ?? 0, projections.max() ?? 0)
    }

    private static func partIndex(_ id: ToolingArtifactID, in parts: [MoldLinerRegistrationShellPart]) throws -> Int {
        guard let index = parts.firstIndex(where: { $0.id == id }) else {
            throw MoldLinerRegistrationBuilderError.invalidInput(.invalidShellPart(id))
        }
        return index
    }

    private static func resolvedGateLipDepth(_ offset: Double) -> Double { clamp(0.5 * offset, 2, 4) }
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
    private static func vec3(_ value: Vec3Codable) -> Vec3 { Vec3(x: value.x, y: value.y, z: value.z) }
    private static func codable(_ value: Vec3) -> Vec3Codable { Vec3Codable(x: value.x, y: value.y, z: value.z) }
    private static func length(_ value: Vec3Codable) -> Double { (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot() }
    private static func length(_ value: Vec3) -> Double { (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot() }
    private static func normalized(_ value: Vec3Codable) -> Vec3 { normalized(vec3(value)) }
    private static func normalized(_ value: Vec3) -> Vec3 { let l = length(value); return l > 1.0e-9 ? scale(value, 1 / l) : Vec3(x: 0, y: 0, z: 1) }
    private static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
    private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func scale(_ a: Vec3, _ scalar: Double) -> Vec3 { Vec3(x: a.x * scalar, y: a.y * scalar, z: a.z * scalar) }
    private static func distance(_ a: Vec3, _ b: Vec3) -> Double { length(subtract(a, b)) }
    private static func angleDegrees(_ a: Vec3, _ b: Vec3) -> Double { acos(clamp(dot(normalized(a), normalized(b)), -1, 1)) * 180 / .pi }
    private static func perpendicularBasis(_ axis: Vec3) -> (Vec3, Vec3) {
        let reference = abs(axis.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 0, y: 1, z: 0)
        let u = normalized(cross(reference, axis))
        return (u, normalized(cross(axis, u)))
    }
}
