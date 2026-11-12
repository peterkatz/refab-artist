import Foundation

struct PreparedMasterGeometryUpdate: Equatable {
    var basePreparedGeometry: MeshGeometryData
    var additions: [PreparedMasterBuilder.Addition]
    var effectivePreparedGeometry: MeshGeometryData

    init(
        basePreparedGeometry: MeshGeometryData,
        additions: [PreparedMasterBuilder.Addition],
        effectivePreparedGeometry: MeshGeometryData
    ) {
        self.basePreparedGeometry = basePreparedGeometry
        self.additions = additions
        self.effectivePreparedGeometry = effectivePreparedGeometry
    }
}

/// Transactional, two-pass flow tooling for reusable silicone-jacket molds.
/// Proposal owns shell/tool geometry and a complete liner-state recipe; finalization
/// is the only pass allowed to mark paths verified against the resulting liners.
enum MoldFlowPathBuilder {
    static let geometryTolerance = 0.01
    static let boreTolerance = 0.05

    struct PreparedPostDatum: Equatable {
        var gateRootPoint: Vec3
        var collarExteriorPoint: Vec3
        var receiverAxis: Vec3
        var receiverDiameter: Double
        var receiverMinimumClearanceDiameter: Double
        var isRound: Bool
        var receiverBore: MeshGeometryData
        var receiverMaterial: MeshGeometryData
        var productionGateBore: MeshGeometryData?
        var selectedSplitPlaneID: UUID?
        var fixtureHandoffID: String?

        init(
            gateRootPoint: Vec3,
            collarExteriorPoint: Vec3,
            receiverAxis: Vec3,
            receiverDiameter: Double,
            receiverMinimumClearanceDiameter: Double? = nil,
            isRound: Bool,
            receiverBore: MeshGeometryData,
            receiverMaterial: MeshGeometryData,
            productionGateBore: MeshGeometryData? = nil,
            selectedSplitPlaneID: UUID? = nil,
            fixtureHandoffID: String? = nil
        ) {
            self.gateRootPoint = gateRootPoint
            self.collarExteriorPoint = collarExteriorPoint
            self.receiverAxis = receiverAxis
            self.receiverDiameter = receiverDiameter
            self.receiverMinimumClearanceDiameter = receiverMinimumClearanceDiameter ?? receiverDiameter
            self.isRound = isRound
            self.receiverBore = receiverBore
            self.receiverMaterial = receiverMaterial
            self.productionGateBore = productionGateBore
            self.selectedSplitPlaneID = selectedSplitPlaneID
            self.fixtureHandoffID = fixtureHandoffID
        }
    }

    /// Exact registration/fixture geometry governing the removable funnel seat.
    struct FunnelInterfaceDatum: Equatable {
        var sealBead: MeshGeometryData
        var rigidStop: MeshGeometryData
        var sealContactPoint: Vec3
        var rigidStopContactPoint: Vec3
        var sealBeadInnerRadius: Double
        var sealBeadOuterRadius: Double
        var sealBeadHeight: Double
        var rigidStopInnerRadius: Double
        var rigidStopOuterRadius: Double
        var receiverPinBore: MeshGeometryData
        var pinCenter: Vec3
        var pinAxis: Vec3
        var pinDiameter: Double
        var removalAxis: Vec3
        var roundedThroatRadius: Double
        var selectedSplitPlaneID: UUID?
        var fixtureHandoffID: String?

        init(
            sealBead: MeshGeometryData,
            rigidStop: MeshGeometryData,
            sealContactPoint: Vec3? = nil,
            rigidStopContactPoint: Vec3,
            sealBeadInnerRadius: Double,
            sealBeadOuterRadius: Double,
            sealBeadHeight: Double,
            rigidStopInnerRadius: Double,
            rigidStopOuterRadius: Double,
            receiverPinBore: MeshGeometryData,
            pinCenter: Vec3,
            pinAxis: Vec3,
            pinDiameter: Double,
            removalAxis: Vec3,
            roundedThroatRadius: Double,
            selectedSplitPlaneID: UUID? = nil,
            fixtureHandoffID: String? = nil
        ) {
            self.sealBead = sealBead
            self.rigidStop = rigidStop
            self.sealContactPoint = sealContactPoint ?? rigidStopContactPoint
            self.rigidStopContactPoint = rigidStopContactPoint
            self.sealBeadInnerRadius = sealBeadInnerRadius
            self.sealBeadOuterRadius = sealBeadOuterRadius
            self.sealBeadHeight = sealBeadHeight
            self.rigidStopInnerRadius = rigidStopInnerRadius
            self.rigidStopOuterRadius = rigidStopOuterRadius
            self.receiverPinBore = receiverPinBore
            self.pinCenter = pinCenter
            self.pinAxis = pinAxis
            self.pinDiameter = pinDiameter
            self.removalAxis = removalAxis
            self.roundedThroatRadius = roundedThroatRadius
            self.selectedSplitPlaneID = selectedSplitPlaneID
            self.fixtureHandoffID = fixtureHandoffID
        }
    }

    struct ExactFixtureRegistrationHandoff: Equatable {
        var preparedPost: PreparedPostDatum
        var funnelInterface: FunnelInterfaceDatum
    }

    struct Settings: Equatable {
        var linerFillDiameter: Double
        var linerVentDiameter: Double
        var requestedLinerVentCount: Int
        var productionGateDiameter: Double
        var productionVentDiameter: Double
        var funnelDraftDegrees: Double
        var ventDraftDegrees: Double
        var sealBeadCompressionFraction: Double
        var fitClearance: Double

        init(
            linerFillDiameter: Double = 10,
            linerVentDiameter: Double = 3,
            requestedLinerVentCount: Int = 0,
            productionGateDiameter: Double = 12,
            productionVentDiameter: Double = 3,
            funnelDraftDegrees: Double = 12,
            ventDraftDegrees: Double = 2,
            sealBeadCompressionFraction: Double = 0.05,
            fitClearance: Double = 0.25
        ) {
            self.linerFillDiameter = linerFillDiameter
            self.linerVentDiameter = linerVentDiameter
            self.requestedLinerVentCount = requestedLinerVentCount
            self.productionGateDiameter = productionGateDiameter
            self.productionVentDiameter = productionVentDiameter
            self.funnelDraftDegrees = funnelDraftDegrees
            self.ventDraftDegrees = ventDraftDegrees
            self.sealBeadCompressionFraction = sealBeadCompressionFraction
            self.fitClearance = fitClearance
        }
    }

    struct ProposalInput: Equatable {
        var shellParts: [MotherMoldPart]
        var immutableSource: MeshGeometryData
        var cavityEnvelope: MeshGeometryData
        var oneTimePourPositive: MeshGeometryData
        var partingPlanes: [PartitionPlane]
        var demoldAxes: [Vec3]
        var preparedPost: PreparedPostDatum?
        var funnelInterface: FunnelInterfaceDatum?
        var linerFillUpAxis: Vec3
        var castingUpAxis: Vec3
        var settings: Settings
        var verifiedLinerAdditives: [MoldLinerFillAdditiveVolume]
        var preexistingTrimOperations: [MoldLinerTrimOperation]
        var preexistingProductionVoids: [MoldLinerPersistentVoid]
        var protectedLinerRegions: [MoldLinerProtectedRegion]
        var reservedToolingVolumes: [MeshGeometryData]
        var protectedAuditSet: ProtectedToolingAuditSet?
        var seed: Int

        init(
            shellParts: [MotherMoldPart],
            immutableSource: MeshGeometryData,
            cavityEnvelope: MeshGeometryData,
            oneTimePourPositive: MeshGeometryData,
            partingPlanes: [PartitionPlane] = [],
            demoldAxes: [Vec3] = [],
            preparedPost: PreparedPostDatum?,
            funnelInterface: FunnelInterfaceDatum?,
            linerFillUpAxis: Vec3,
            castingUpAxis: Vec3,
            settings: Settings = Settings(),
            verifiedLinerAdditives: [MoldLinerFillAdditiveVolume] = [],
            preexistingTrimOperations: [MoldLinerTrimOperation] = [],
            preexistingProductionVoids: [MoldLinerPersistentVoid] = [],
            protectedLinerRegions: [MoldLinerProtectedRegion] = [],
            reservedToolingVolumes: [MeshGeometryData] = [],
            protectedAuditSet: ProtectedToolingAuditSet? = nil,
            seed: Int = 0
        ) {
            self.shellParts = shellParts
            self.immutableSource = immutableSource
            self.cavityEnvelope = cavityEnvelope
            self.oneTimePourPositive = oneTimePourPositive
            self.partingPlanes = partingPlanes
            self.demoldAxes = demoldAxes
            self.preparedPost = preparedPost
            self.funnelInterface = funnelInterface
            self.linerFillUpAxis = linerFillUpAxis
            self.castingUpAxis = castingUpAxis
            self.settings = settings
            self.verifiedLinerAdditives = verifiedLinerAdditives
            self.preexistingTrimOperations = preexistingTrimOperations
            self.preexistingProductionVoids = preexistingProductionVoids
            self.protectedLinerRegions = protectedLinerRegions
            self.reservedToolingVolumes = reservedToolingVolumes
            self.protectedAuditSet = protectedAuditSet
            self.seed = seed
        }
    }

    struct VentFormer: Equatable {
        var id: ToolingArtifactID
        var landing: PreparedMasterBuilder.Addition
        var extractionAxis: Vec3
        var removalSweep: MeshGeometryData
        var shellSleeve: MeshGeometryData
        var linerVoid: MeshGeometryData
        var exteriorGrip: MeshGeometryData
    }

    struct PersistentMaximaEvidence: Equatable {
        var localPeakCount: Int
        var qualifyingBasinCount: Int
        var gateServedPeakIDs: [Int]
        var ventServedPeakIDs: [Int]
        var unservedPeakIDs: [Int]
        var selectedVentPeakIDs: [Int]
        var persistenceThresholdMillimeters: Double
        var trappedVolumeThresholdCubicMillimeters: Double
    }

    struct FunnelEvidence: Equatable {
        var declaredCompressionFraction: Double
        var measuredCompressionFraction: Double
        var rigidStopContactGapMillimeters: Double
        var pinBoreOverlapCubicMillimeters: Double
        var roundedThroatRadiusMillimeters: Double
        var removalAxis: Vec3
        var removalSweepClear: Bool
    }

    struct PathMeasurement: Equatable {
        var pathID: String
        var configuredDiameterMillimeters: Double
        var inMemoryMinimumDiameterMillimeters: Double
        var roundTripMinimumDiameterMillimeters: Double
        var ownerPartNames: [String]
        var connectivityVerified: Bool
    }

    enum PathKind: Equatable {
        case linerMaterial
        case productionClearance
    }

    struct PathSpec: Equatable {
        var id: String
        var label: String
        var phase: ToolingPhase
        var kind: PathKind
        var innerPoint: Vec3
        var outerPoint: Vec3
        var axis: Vec3
        var declaredDiameter: Double
        var shellTool: MeshGeometryData
        var ownerIndices: [Int]
        var ownershipWitness: MeshGeometryData?
        var artifactIDs: [ToolingArtifactID]
    }

    struct Proposal: Equatable {
        var originalShellParts: [MotherMoldPart]
        var shellParts: [MotherMoldPart]
        var immutableSource: MeshGeometryData
        var cavityEnvelope: MeshGeometryData
        var effectiveOneTimePositive: MeshGeometryData
        var preparedMasterUpdate: PreparedMasterGeometryUpdate
        var baseLiner: MeshGeometryData
        var fixtureArtifacts: [ToolingArtifact]
        var preparedMasterAdditions: [PreparedMasterBuilder.Addition]
        var linerFillAdditives: [MoldLinerFillAdditiveVolume]
        var trimOperations: [MoldLinerTrimOperation]
        var persistentProductionVoids: [MoldLinerPersistentVoid]
        var protectedLinerRegions: [MoldLinerProtectedRegion]
        var ventFormers: [VentFormer]
        var pathSpecs: [PathSpec]
        var pendingSummaries: [MoldFlowPathSummary]
        var gateOnlyMaximaEvidence: PersistentMaximaEvidence
        var funnelEvidence: FunnelEvidence
        var preparedPost: PreparedPostDatum
        var funnelInterface: FunnelInterfaceDatum
        var settings: Settings
        var castingUpAxis: Vec3
        var linerFillUpAxis: Vec3
        var protectedAuditSet: ProtectedToolingAuditSet
        var diagnostics: [MoldDiagnostic]
    }

    struct FinalizationInput: Equatable {
        var proposal: Proposal
        var asPouredLiner: MeshGeometryData
        var productionLiner: MeshGeometryData

        init(proposal: Proposal, asPouredLiner: MeshGeometryData, productionLiner: MeshGeometryData) {
            self.proposal = proposal
            self.asPouredLiner = asPouredLiner
            self.productionLiner = productionLiner
        }
    }

    struct Result: Equatable {
        var shellParts: [MotherMoldPart]
        var fixtureArtifacts: [ToolingArtifact]
        var preparedMasterAdditions: [PreparedMasterBuilder.Addition]
        var linerFillAdditives: [MoldLinerFillAdditiveVolume]
        var trimOperations: [MoldLinerTrimOperation]
        var persistentProductionVoids: [MoldLinerPersistentVoid]
        var protectedLinerRegions: [MoldLinerProtectedRegion]
        var summaries: [MoldFlowPathSummary]
        var measurements: [PathMeasurement]
        var ventFormers: [VentFormer]
        var persistentMaximaEvidence: PersistentMaximaEvidence
        var funnelEvidence: FunnelEvidence
        var protectedAuditSet: ProtectedToolingAuditSet
        var diagnostics: [MoldDiagnostic]

        var linerFillSummary: MoldFlowPathSummary { summaries.first { $0.id == "liner-fill-01" }! }
        var linerVentSummaries: [MoldFlowPathSummary] { summaries.filter { $0.id.hasPrefix("liner-vent-") } }
        var castingGateSummary: MoldFlowPathSummary { summaries.first { $0.id == "production-gate-01" }! }
        var productionVentSummaries: [MoldFlowPathSummary] { summaries.filter { $0.id.hasPrefix("production-vent-") } }
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidInput(String)
        case linerFillUnavailable(String)
        case linerVentUnavailable(requested: Int, placed: Int)
        case manualSeparateGateRequired(String)
        case funnelDatumRequired(String)
        case funnelInterfaceInvalid(String)
        case productionVentUnavailable(String)
        case protectedTrimOverlap(trimID: String, protectedID: String)
        case staleLinerState(state: String, symmetricDifference: Double)
        case pendingMeasurement(String)
        case finalVerificationFailed(String)
        case fixtureDatumMissing
        case registrationDatumMissing
        case staleFixtureRegistrationHandoff
        case handoffPlaneMismatch(fixture: UUID, registration: UUID)
        case invalidFixtureRegistrationHandoff(String)
        case protectedToolingAuditFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let reason): return "Invalid flow-path input: \(reason)."
            case .linerFillUnavailable(let reason): return "LINER FILL could not be proposed: \(reason)."
            case .linerVentUnavailable(let requested, let placed): return "LINER FILL requires \(requested) vents, but only \(placed) were proposed."
            case .manualSeparateGateRequired(let reason): return "Manual separate production gate required: \(reason)."
            case .funnelDatumRequired(let reason): return "Casting funnel datum is required: \(reason)."
            case .funnelInterfaceInvalid(let reason): return "Casting funnel interface is invalid: \(reason)."
            case .productionVentUnavailable(let reason): return "Production vent cannot be proposed: \(reason)."
            case .protectedTrimOverlap(let trimID, let protectedID): return "Trim \(trimID) overlaps protected region \(protectedID)."
            case .staleLinerState(let state, let difference): return "\(state) is stale or inconsistent with this flow proposal (symmetric difference \(difference) mm3)."
            case .pendingMeasurement(let path): return "Path \(path) could not be measured on final and round-tripped geometry."
            case .finalVerificationFailed(let reason): return "Flow transaction rolled back: \(reason)."
            case .fixtureDatumMissing: return "Fixture-to-flow handoff is missing the exact prepared production-gate datum."
            case .registrationDatumMissing: return "Registration-to-flow handoff is missing the exact funnel seal datum."
            case .staleFixtureRegistrationHandoff: return "Fixture and registration datums do not share the same provenance; regenerate registration from the current fixture result."
            case .handoffPlaneMismatch(let fixture, let registration): return "Fixture split plane \(fixture) does not match registration split plane \(registration)."
            case .invalidFixtureRegistrationHandoff(let reason): return "Fixture-to-registration handoff is invalid: \(reason)."
            case .protectedToolingAuditFailed(let reason): return "Flow tooling damaged protected geometry: \(reason)"
            }
        }
    }

    private struct BoreResult {
        var parts: [MotherMoldPart]
        var ownerIndices: [Int]
        var removedByOwner: [Int: [MeshGeometryData]]
    }

    /// A fixture may reserve the dry post path before the flow stage. Its exact
    /// collar material establishes ownership without inferring one from bounds.
    private static func prepareExactReceiver(
        parts: [MotherMoldPart],
        post: PreparedPostDatum,
        protected: [MeshGeometryData]
    ) throws -> BoreResult {
        let gateTool = post.productionGateBore ?? post.receiverBore
        let gateOwners = try parts.indices.filter {
            try intersectionVolume(parts[$0].geometry, gateTool) > geometryTolerance
        }
        if gateOwners.count == 1, let gateOwner = gateOwners.first {
            for (index, solid) in protected.enumerated()
                where try intersectionVolume(post.receiverBore, solid) > geometryTolerance {
                throw Error.finalVerificationFailed("production receiver consumes reserved or protected tooling at index \(index)")
            }
            var updated = parts
            let receiverOwners = try parts.indices.filter {
                try intersectionVolume(parts[$0].geometry, post.receiverBore) > geometryTolerance
            }
            let removedByOwner = try removedProfiles(
                parts: parts,
                ownerIndices: receiverOwners,
                tool: post.receiverBore
            )
            for owner in receiverOwners {
                let normalized = try printableNormalizedSolid(
                    try subtract(updated[owner].geometry, post.receiverBore),
                    label: "production receiver shell part \(updated[owner].name)"
                )
                guard try intersectionVolume(normalized, post.receiverBore) <= geometryTolerance else {
                    throw Error.finalVerificationFailed("production receiver was partially closed by bounded shell normalization")
                }
                updated[owner].geometry = normalized
                let handle = try ManifoldEngine.make(from: normalized)
                updated[owner].bounds = ManifoldEngine.bounds(handle)
                withExtendedLifetime(handle) {}
                updated[owner].isWatertight = true
            }
            return BoreResult(parts: updated, ownerIndices: [gateOwner], removedByOwner: removedByOwner)
        }
        guard gateOwners.isEmpty else {
            throw Error.finalVerificationFailed("round production-gate channel crosses a shell parting interface; expected exactly one owner")
        }
        let collarOwners = try parts.indices.filter {
            try intersectionVolume(parts[$0].geometry, post.receiverMaterial) > geometryTolerance
        }
        guard !collarOwners.isEmpty else {
            throw Error.finalVerificationFailed("pre-cleared production-gate has no exact collar-material owner")
        }
        return BoreResult(parts: parts, ownerIndices: collarOwners.sorted(), removedByOwner: [:])
    }

    struct Basin {
        var peak: Int
        var persistence: Double
        var estimatedVolume: Double
    }

    struct MaximaAnalysis {
        var basins: [Basin]
        var qualifying: [Basin]
        var evidence: PersistentMaximaEvidence
    }

    private struct FunnelBuild {
        var artifact: ToolingArtifact
        var geometry: MeshGeometryData
        var pinBore: MeshGeometryData
        var outerOpening: Vec3
        var shellParts: [MotherMoldPart]
        var shellClearanceRemovedByOwner: [Int: [MeshGeometryData]]
        var evidence: FunnelEvidence
    }

    private struct RodBuild {
        var artifact: ToolingArtifact
        var body: MeshGeometryData
        var grip: MeshGeometryData
        var sweep: MeshGeometryData
        var sleeve: MeshGeometryData
        var linerVoid: MeshGeometryData
        var outerPoint: Vec3
    }

    static func propose(_ input: ProposalInput) throws -> Proposal {
        try validateProposalInput(input)
        let incomingAuditSet = try input.protectedAuditSet ?? ProtectedToolingAuditSet(records: [])
        let incomingAudit = incomingAuditSet.audit(finalParts: input.shellParts, stage: .flow)
        guard incomingAudit.passes else {
            throw Error.protectedToolingAuditFailed(incomingAudit.diagnostics.joined(separator: " "))
        }
        guard let post = input.preparedPost else {
            throw Error.manualSeparateGateRequired("prepared-post receiver is absent")
        }
        guard let interface = input.funnelInterface else {
            throw Error.funnelDatumRequired("exact seal bead, rigid stop, pin bore, and removal-axis datums are absent")
        }
        if let fixtureID = post.fixtureHandoffID ?? interface.fixtureHandoffID,
           let postID = post.fixtureHandoffID,
           let interfaceID = interface.fixtureHandoffID,
           postID != interfaceID {
            _ = fixtureID
            throw Error.staleFixtureRegistrationHandoff
        }
        if let postPlane = post.selectedSplitPlaneID,
           let interfacePlane = interface.selectedSplitPlaneID,
           postPlane != interfacePlane {
            throw Error.handoffPlaneMismatch(fixture: postPlane, registration: interfacePlane)
        }
        let linerAxis = try unit(input.linerFillUpAxis, label: "liner-fill axis")
        let castingAxis = try unit(input.castingUpAxis, label: "casting axis")
        let receiverAxis = try unit(post.receiverAxis, label: "receiver axis")
        guard post.isRound,
              post.receiverDiameter >= input.settings.productionGateDiameter,
              dot(receiverAxis, castingAxis) > 0.5 else {
            throw Error.manualSeparateGateRequired("prepared receiver is not round, large enough, and compatible with casting up")
        }

        let baseLiner = try subtract(input.cavityEnvelope, input.oneTimePourPositive)
        try validSolid(baseLiner, label: "base liner")

        var parts = input.shellParts
        var paths: [PathSpec] = []
        var flowAuditRecords: [ProtectedToolingAuditSet.Record] = []
        var flowAdditives: [MoldLinerFillAdditiveVolume] = []
        var flowTrims: [MoldLinerTrimOperation] = []
        let protectedSolids = input.protectedLinerRegions.map(\.solid) + input.reservedToolingVolumes

        let fillPoint = try highestPoint(in: baseLiner, along: linerAxis)
        let fillRaw = try outwardTube(
            from: fillPoint,
            axis: linerAxis,
            diameter: input.settings.linerFillDiameter,
            parts: parts,
            exteriorMargin: 8
        )
        let fillAdditive = try actualLinerAdditive(
            rawPath: fillRaw.solid,
            baseLiner: baseLiner,
            positive: input.oneTimePourPositive
        )
        try proveLinerAddition(
            fillAdditive.addition,
            connectsTo: baseLiner,
            avoids: input.oneTimePourPositive,
            label: "liner-fill-nub-01"
        )
        let fillTrim = MoldLinerTrimOperation(
            id: "liner-fill-nub-01",
            purpose: "remove only the exterior LINER FILL nub",
            solid: fillAdditive.exteriorTrim
        )
        try proveTrimProtection(
            trims: [fillTrim],
            protected: input.protectedLinerRegions,
            productionVoids: input.preexistingProductionVoids
        )
        let fillBore = try carveUnique(parts: parts, tool: fillRaw.solid, protected: protectedSolids, label: "liner-fill")
        parts = fillBore.parts
        flowAuditRecords.append(contentsOf: try flowVoidRecords(
            id: "flow-void-liner-fill-01",
            kind: .linerFillPath,
            bore: fillBore,
            parts: parts
        ))
        flowAdditives.append(MoldLinerFillAdditiveVolume(id: "liner-fill-nub-01", purpose: "one-time LINER FILL silicone with a positive-volume liner root", solid: fillAdditive.addition))
        flowTrims.append(fillTrim)
        paths.append(PathSpec(
            id: "liner-fill-01", label: "LINER FILL", phase: .linerFill, kind: .linerMaterial,
            innerPoint: fillRaw.inner, outerPoint: fillRaw.outer, axis: linerAxis,
            declaredDiameter: input.settings.linerFillDiameter, shellTool: fillRaw.solid,
            ownerIndices: fillBore.ownerIndices, ownershipWitness: nil, artifactIDs: []
        ))

        let linerCandidates = highCandidates(baseLiner, axis: linerAxis, excluding: [fillPoint], seed: input.seed)
        for candidate in linerCandidates where flowAdditives.count - 1 < input.settings.requestedLinerVentCount {
            let ordinal = flowAdditives.count
            let id = String(format: "liner-vent-%02d", ordinal)
            guard let raw = try? outwardTube(from: candidate, axis: linerAxis, diameter: input.settings.linerVentDiameter, parts: parts, exteriorMargin: 6),
                  let bore = try? carveUnique(parts: parts, tool: raw.solid, protected: protectedSolids, label: id),
                  let additive = try? actualLinerAdditive(rawPath: raw.solid, baseLiner: baseLiner, positive: input.oneTimePourPositive),
                  (try? proveLinerAddition(additive.addition, connectsTo: baseLiner, avoids: input.oneTimePourPositive, label: id)) != nil else { continue }
            parts = bore.parts
            flowAuditRecords.append(contentsOf: try flowVoidRecords(
                id: "flow-void-\(id)",
                kind: .linerVentPath,
                bore: bore,
                parts: parts
            ))
            flowAdditives.append(MoldLinerFillAdditiveVolume(id: id, purpose: "temporary LINER FILL high-region vent with a positive-volume liner root", solid: additive.addition))
            flowTrims.append(MoldLinerTrimOperation(id: id, purpose: "remove only the exterior LINER FILL vent nub", solid: additive.exteriorTrim))
            paths.append(PathSpec(
                id: id, label: "LINER FILL VENT \(ordinal)", phase: .linerFill, kind: .linerMaterial,
                innerPoint: raw.inner, outerPoint: raw.outer, axis: linerAxis,
                declaredDiameter: input.settings.linerVentDiameter, shellTool: raw.solid,
                ownerIndices: bore.ownerIndices, ownershipWitness: nil, artifactIDs: []
            ))
        }
        let placedLinerVents = flowAdditives.count - 1
        guard placedLinerVents == input.settings.requestedLinerVentCount else {
            throw Error.linerVentUnavailable(requested: input.settings.requestedLinerVentCount, placed: placedLinerVents)
        }

        let gateBore = try prepareExactReceiver(
            parts: parts,
            post: post,
            protected: input.reservedToolingVolumes
        )
        parts = gateBore.parts
        flowAuditRecords.append(contentsOf: try flowVoidRecords(
            id: "flow-void-production-gate-receiver",
            kind: .productionGate,
            bore: gateBore,
            parts: parts
        ))
        let funnel = try buildFunnel(post: post, interface: interface, settings: input.settings, source: input.immutableSource, shellParts: parts)
        parts = funnel.shellParts
        for (owner, removedComponents) in funnel.shellClearanceRemovedByOwner.sorted(by: { $0.key < $1.key }) {
            let partName = parts[owner].name
            for (componentIndex, removed) in removedComponents.enumerated() {
                flowAuditRecords.append(ProtectedToolingAuditSet.Record(
                    id: "flow-void-casting-funnel-removal-\(partName)-\(componentIndex + 1)",
                    kind: .castingFunnelReceiver,
                    behavior: .subtractive,
                    ownership: .singlePart(partName),
                    geometry: try printableNormalizedSolid(
                        removed,
                        label: "casting-funnel removal audit witness \(partName) \(componentIndex + 1)"
                    ),
                    requiredRetention: 1,
                    requiredClearance: 0.98,
                    provenance: [.flow]
                ))
            }
        }
        let gateInnerPoint = add(post.gateRootPoint, scale(receiverAxis, -0.25))
        let gateClearTool = try tubeBetween(
            gateInnerPoint,
            funnel.outerOpening,
            lowerRadius: input.settings.productionGateDiameter / 2,
            upperRadius: input.settings.productionGateDiameter / 2,
            sides: 96
        )
        let exactGateClearTool: MeshGeometryData
        if let declaredRoundBore = post.productionGateBore {
            try validSolid(declaredRoundBore, label: "declared round production-gate bore")
            let declaredOverlap = try intersectionVolume(declaredRoundBore, post.receiverBore)
            guard declaredOverlap >= (try volume(declaredRoundBore)) - geometryTolerance else {
                throw Error.manualSeparateGateRequired("declared round gate bore is not contained in the prepared receiver")
            }
            exactGateClearTool = try unionAll([declaredRoundBore, gateClearTool])
        } else {
            exactGateClearTool = gateClearTool
        }
        guard intersects(exactGateClearTool, input.immutableSource) else {
            throw Error.manualSeparateGateRequired("receiver bore does not reach the immutable casting cavity")
        }
        var productionVoids = input.preexistingProductionVoids
        productionVoids.append(MoldLinerPersistentVoid(
            id: "production-gate-01", kind: .productionGate,
            purpose: "permanent prepared-post production gate", solid: exactGateClearTool
        ))
        paths.append(PathSpec(
            id: "production-gate-01", label: "CAST HERE", phase: .casting, kind: .productionClearance,
            innerPoint: gateInnerPoint, outerPoint: funnel.outerOpening, axis: receiverAxis,
            declaredDiameter: input.settings.productionGateDiameter, shellTool: post.productionGateBore ?? post.receiverBore,
            ownerIndices: gateBore.ownerIndices,
            ownershipWitness: post.receiverMaterial,
            artifactIDs: [funnel.artifact.id]
        ))

        let gateOnly = try analyzePersistentMaxima(
            cavity: input.immutableSource,
            gatePoint: post.gateRootPoint,
            ventPoints: [],
            axis: castingAxis
        )
        let selectedVentPeaks = try minimumVentSet(
            qualifying: gateOnly.qualifying,
            gatePoint: post.gateRootPoint,
            cavity: input.immutableSource,
            axis: castingAxis
        )

        var preparedAdditions: [PreparedMasterBuilder.Addition] = []
        var fixtureArtifacts = [funnel.artifact]
        var ventFormers: [VentFormer] = []
        for (offset, peakID) in selectedVentPeaks.enumerated() {
            let ordinal = offset + 1
            let id = String(format: "production-vent-%02d", ordinal)
            let point = input.immutableSource.vertices[peakID]
            let landingDepth = max(0.8, input.settings.productionVentDiameter * 0.35)
            let landingOuter = add(point, scale(castingAxis, landingDepth))
            let landing = try tubeBetween(
                add(point, scale(castingAxis, -0.1)), landingOuter,
                lowerRadius: input.settings.productionVentDiameter * 0.7,
                upperRadius: input.settings.productionVentDiameter * 0.6,
                sides: 64
            )
            let addition = PreparedMasterBuilder.Addition(
                region: modificationRegion(
                    id: "\(id)-landing",
                    center: point,
                    axis: castingAxis,
                    footprintRadius: input.settings.productionVentDiameter * 0.7,
                    purpose: "approved shallow production-vent landing"
                ),
                solid: landing
            )
            let rod = try buildRod(
                id: id, ordinal: ordinal, landingOuter: landingOuter, axis: castingAxis,
                diameter: input.settings.productionVentDiameter,
                draftDegrees: input.settings.ventDraftDegrees,
                clearance: input.settings.fitClearance, shellParts: parts
            )
            let sleeveBore = try carveUnique(
                parts: parts,
                tool: rod.sleeve,
                protected: protectedSolids + [post.receiverBore],
                label: "\(id)-sleeve at \(point.display)"
            )
            parts = sleeveBore.parts
            flowAuditRecords.append(contentsOf: try flowVoidRecords(
                id: "flow-void-\(id)-sleeve",
                kind: .productionVentSleeve,
                bore: sleeveBore,
                parts: parts
            ))
            try proveRod(
                rod: rod, landing: addition, source: input.immutableSource,
                shellParts: parts, protected: protectedSolids + [post.receiverBore]
            )
            preparedAdditions.append(addition)
            fixtureArtifacts.append(rod.artifact)
            productionVoids.append(MoldLinerPersistentVoid(id: id, kind: .productionVent, purpose: "permanent production-casting vent", solid: rod.linerVoid))
            ventFormers.append(VentFormer(
                id: rod.artifact.id, landing: addition, extractionAxis: castingAxis,
                removalSweep: rod.sweep, shellSleeve: rod.sleeve,
                linerVoid: rod.linerVoid, exteriorGrip: rod.grip
            ))
            paths.append(PathSpec(
                id: id, label: "VENT \(ordinal)", phase: .casting, kind: .productionClearance,
                innerPoint: point,
                outerPoint: rod.outerPoint, axis: castingAxis,
                declaredDiameter: input.settings.productionVentDiameter, shellTool: rod.sleeve,
                ownerIndices: sleeveBore.ownerIndices, ownershipWitness: nil, artifactIDs: [rod.artifact.id]
            ))
        }

        let effectivePositive = try unionAll([input.oneTimePourPositive] + preparedAdditions.map(\.solid))
        try provePreparedMasterUpdate(
            base: input.oneTimePourPositive,
            additions: preparedAdditions,
            effective: effectivePositive,
            source: input.immutableSource
        )
        let allAdditives = input.verifiedLinerAdditives + flowAdditives
        let allTrims = input.preexistingTrimOperations + flowTrims
        let allProtected = input.protectedLinerRegions
        try proveTrimProtection(trims: allTrims, protected: allProtected, productionVoids: productionVoids)
        var completeAuditSet = try incomingAuditSet.authorizingSubtractiveCuts(flowAuditRecords)
        let retainedRigidStops = try removedProfiles(
            parts: parts,
            ownerIndices: Array(parts.indices),
            tool: interface.rigidStop
        )
        guard !retainedRigidStops.isEmpty else {
            throw Error.funnelInterfaceInvalid("final rigid stop has no measurable supporting shell material")
        }
        let rigidStopRecords = try retainedRigidStops.sorted(by: { $0.key < $1.key }).flatMap { owner, retainedComponents -> [ProtectedToolingAuditSet.Record] in
            let partName = parts[owner].name
            return try retainedComponents.enumerated().map { componentIndex, retained in
                ProtectedToolingAuditSet.Record(
                    id: "flow-additive-casting-funnel-rigid-stop-\(partName)-\(componentIndex + 1)",
                    kind: .sealLand,
                    behavior: .additive,
                    ownership: .singlePart(partName),
                    geometry: try printableNormalizedSolid(
                        retained,
                        label: "final casting-funnel rigid stop witness \(partName) \(componentIndex + 1)"
                    ),
                    requiredRetention: 0.98,
                    provenance: [.flow]
                )
            }
        }
        completeAuditSet = try completeAuditSet.appending(rigidStopRecords)
        let flowAudit = completeAuditSet.audit(finalParts: parts, stage: .flow)
        guard flowAudit.passes else {
            throw Error.protectedToolingAuditFailed(flowAudit.diagnostics.joined(separator: " "))
        }
        let recipe = MoldLinerStateInput(
            cavitySolid: input.cavityEnvelope,
            oneTimePourPositive: effectivePositive,
            verifiedLinerFillAdditives: allAdditives,
            trimOperations: allTrims,
            persistentProductionVoids: productionVoids,
            protectedRegions: allProtected
        )
        _ = try MoldLinerStateBuilder.build(recipe)

        let pending = paths.map { path in
            MoldFlowPathSummary(
                id: path.id, phase: path.phase, state: .pendingMeasurement, label: path.label,
                gravityUpAxis: codable(path.phase == .linerFill ? linerAxis : castingAxis),
                entryPoint: codable(path.outerPoint), exitPoint: codable(path.innerPoint),
                declaredDiameterMillimeters: path.declaredDiameter,
                measuredMinimumDiameterMillimeters: nil,
                artifactIDs: path.artifactIDs,
                notes: ["Proposal only; final liner geometry has not yet been supplied or measured."]
            )
        }
        return Proposal(
            originalShellParts: input.shellParts,
            shellParts: parts,
            immutableSource: input.immutableSource,
            cavityEnvelope: input.cavityEnvelope,
            effectiveOneTimePositive: effectivePositive,
            preparedMasterUpdate: PreparedMasterGeometryUpdate(
                basePreparedGeometry: input.oneTimePourPositive,
                additions: preparedAdditions,
                effectivePreparedGeometry: effectivePositive
            ),
            baseLiner: baseLiner,
            fixtureArtifacts: fixtureArtifacts,
            preparedMasterAdditions: preparedAdditions,
            linerFillAdditives: allAdditives,
            trimOperations: allTrims,
            persistentProductionVoids: productionVoids,
            protectedLinerRegions: allProtected,
            ventFormers: ventFormers,
            pathSpecs: paths,
            pendingSummaries: pending,
            gateOnlyMaximaEvidence: gateOnly.evidence,
            funnelEvidence: funnel.evidence,
            preparedPost: post,
            funnelInterface: interface,
            settings: input.settings,
            castingUpAxis: castingAxis,
            linerFillUpAxis: linerAxis,
            protectedAuditSet: completeAuditSet,
            diagnostics: [MoldDiagnostic(
                .info,
                "Flow tooling proposal created; all path summaries remain pending until exact liner states are finalized.",
                subsystem: .productionCasting,
                code: MoldDiagnosticCode(rawValue: "flow.proposed"),
                recoveryActions: [.reviewAssemblyGuide]
            )]
        )
    }

    /// Bridges only exact geometry emitted by fixture and registration. This is
    /// deliberately the sole production handoff API: it neither estimates a
    /// throat from bounds nor re-derives a split plane from mesh placement.
    static func exactFixtureRegistrationHandoff(
        fixture: MoldMasterFixtureBuilder.Result,
        registration: MoldLinerRegistrationResult
    ) throws -> ExactFixtureRegistrationHandoff {
        guard fixture.kind == .fixture, let fixtureDatum = fixture.productionGate else {
            throw Error.fixtureDatumMissing
        }
        guard let gateLip = registration.gateLip else {
            throw Error.registrationDatumMissing
        }
        let seal = gateLip.funnelSeal
        guard gateLip.splitPlaneID == seal.selectedSplitPlaneID else {
            throw Error.handoffPlaneMismatch(fixture: gateLip.splitPlaneID, registration: seal.selectedSplitPlaneID)
        }
        guard fixtureDatum.selectedSplitPlaneID == gateLip.splitPlaneID else {
            throw Error.handoffPlaneMismatch(fixture: fixtureDatum.selectedSplitPlaneID, registration: gateLip.splitPlaneID)
        }
        guard seal.fixtureHandoffID == fixtureDatum.handoffID else {
            throw Error.staleFixtureRegistrationHandoff
        }
        guard fixtureDatum.productionGateDiameterMillimeters.isFinite,
              fixtureDatum.productionGateDiameterMillimeters > 0,
              fixtureDatum.receiverMinimumClearanceDiameterMillimeters > fixtureDatum.productionGateDiameterMillimeters,
              fixtureDatum.pinDiameterMillimeters.isFinite,
              fixtureDatum.pinDiameterMillimeters > 0,
              seal.beadInnerRadiusMillimeters > fixtureDatum.productionGateDiameterMillimeters / 2,
              seal.beadOuterRadiusMillimeters > seal.beadInnerRadiusMillimeters,
              seal.beadHeightMillimeters > 0,
              seal.stopOuterRadiusMillimeters > seal.stopInnerRadiusMillimeters,
              seal.roundedThroatRadiusMillimeters > 0 else {
            throw Error.invalidFixtureRegistrationHandoff("measured gate, bead, stop, pin, or throat dimensions are incomplete")
        }
        for (label, solid) in [
            ("fixture collar", fixtureDatum.collarSolid),
            ("rounded-D receiver", fixtureDatum.roundedDReceiverBore),
            ("round production-gate bore", fixtureDatum.roundProductionGateBore),
            ("shared receiver pin bore", fixtureDatum.receiverPinBore),
            ("registration seal bead", seal.bead),
            ("registration rigid stop", seal.compressionStop),
        ] { try validSolid(solid, label: label) }

        let roundBore = try ManifoldEngine.make(from: fixtureDatum.roundProductionGateBore)
        let receiver = try ManifoldEngine.make(from: fixtureDatum.roundedDReceiverBore)
        let contained = try ManifoldEngine.intersect(roundBore, receiver)
        guard abs(ManifoldEngine.volume(contained)) >= abs(ManifoldEngine.volume(roundBore)) - geometryTolerance else {
            throw Error.invalidFixtureRegistrationHandoff("the exact round gate bore is not fully contained in the rounded-D receiver")
        }
        let axis = try unit(vec(fixtureDatum.receiverAxis), label: "fixture receiver axis")
        let removalAxis = try unit(vec(seal.releaseAxis), label: "registration removal axis")
        guard dot(axis, removalAxis) > 0.999 else {
            throw Error.invalidFixtureRegistrationHandoff("registration removal axis does not match the exact fixture receiver axis")
        }
        let measuredBeadHeight = projectionBounds(seal.bead, axis: axis).max - projectionBounds(seal.bead, axis: axis).min
        guard abs(measuredBeadHeight - seal.beadHeightMillimeters) <= boreTolerance else {
            throw Error.invalidFixtureRegistrationHandoff("declared seal-bead height does not match the exact bead solid")
        }
        let sealProjection = projectionBounds(seal.bead, axis: axis)
        guard abs(sealProjection.max - dot(vec(seal.sealContactPoint), axis)) <= boreTolerance else {
            throw Error.invalidFixtureRegistrationHandoff("seal contact point does not lie on the exact bead solid")
        }
        let stopProjection = projectionBounds(seal.compressionStop, axis: axis)
        guard abs(stopProjection.max - dot(vec(seal.stopContactPoint), axis)) <= boreTolerance else {
            throw Error.invalidFixtureRegistrationHandoff("rigid-stop contact point does not lie on the exact stop solid")
        }
        guard dot(vec(seal.stopContactPoint), axis) > dot(vec(seal.sealContactPoint), axis) + boreTolerance else {
            throw Error.invalidFixtureRegistrationHandoff("rigid stop is not outward of the liner sealing bead")
        }

        return ExactFixtureRegistrationHandoff(
            preparedPost: PreparedPostDatum(
                gateRootPoint: vec(fixtureDatum.gateRootPoint),
                collarExteriorPoint: vec(fixtureDatum.collarExteriorPoint),
                receiverAxis: axis,
                receiverDiameter: fixtureDatum.productionGateDiameterMillimeters,
                receiverMinimumClearanceDiameter: fixtureDatum.receiverMinimumClearanceDiameterMillimeters,
                isRound: true,
                receiverBore: fixtureDatum.roundedDReceiverBore,
                receiverMaterial: fixtureDatum.collarSolid,
                productionGateBore: fixtureDatum.roundProductionGateBore,
                selectedSplitPlaneID: fixtureDatum.selectedSplitPlaneID,
                fixtureHandoffID: fixtureDatum.handoffID
            ),
            funnelInterface: FunnelInterfaceDatum(
                sealBead: seal.bead,
                rigidStop: seal.compressionStop,
                sealContactPoint: vec(seal.sealContactPoint),
                rigidStopContactPoint: vec(seal.stopContactPoint),
                sealBeadInnerRadius: seal.beadInnerRadiusMillimeters,
                sealBeadOuterRadius: seal.beadOuterRadiusMillimeters,
                sealBeadHeight: seal.beadHeightMillimeters,
                rigidStopInnerRadius: seal.stopInnerRadiusMillimeters,
                rigidStopOuterRadius: seal.stopOuterRadiusMillimeters,
                receiverPinBore: fixtureDatum.receiverPinBore,
                pinCenter: vec(fixtureDatum.pinCenter),
                pinAxis: vec(fixtureDatum.pinAxis),
                pinDiameter: fixtureDatum.pinDiameterMillimeters,
                removalAxis: removalAxis,
                roundedThroatRadius: seal.roundedThroatRadiusMillimeters,
                selectedSplitPlaneID: seal.selectedSplitPlaneID,
                fixtureHandoffID: fixtureDatum.handoffID
            )
        )
    }

    static func linerStateInput(for proposal: Proposal) -> MoldLinerStateInput {
        MoldLinerStateInput(
            cavitySolid: proposal.cavityEnvelope,
            oneTimePourPositive: proposal.effectiveOneTimePositive,
            verifiedLinerFillAdditives: proposal.linerFillAdditives,
            trimOperations: proposal.trimOperations,
            persistentProductionVoids: proposal.persistentProductionVoids,
            protectedRegions: proposal.protectedLinerRegions
        )
    }

    static func build(
        _ input: ProposalInput,
        linerBuilder: (MoldLinerStateInput) throws -> MoldLinerStateBuilderResult
    ) throws -> Result {
        let proposal = try propose(input)
        let liners = try linerBuilder(linerStateInput(for: proposal))
        return try finalize(FinalizationInput(
            proposal: proposal,
            asPouredLiner: liners.asPouredLiner.geometry,
            productionLiner: liners.productionLiner.geometry
        ))
    }

    static func finalize(_ input: FinalizationInput) throws -> Result {
        let proposal = input.proposal
        try validSolid(input.asPouredLiner, label: "final as-poured liner")
        try validSolid(input.productionLiner, label: "final production liner")
        let expected = try MoldLinerStateBuilder.build(linerStateInput(for: proposal))
        try requireSameSolid(expected.asPouredLiner.geometry, input.asPouredLiner, label: "AS-POURED LINER")
        try requireSameSolid(expected.productionLiner.geometry, input.productionLiner, label: "PRODUCTION LINER")

        let ventPaths = proposal.pathSpecs.filter { $0.id.hasPrefix("production-vent-") }
        let finalMaxima = try analyzePersistentMaxima(
            cavity: proposal.immutableSource,
            gatePoint: proposal.preparedPost.gateRootPoint,
            ventPoints: ventPaths.map(\.innerPoint),
            axis: proposal.castingUpAxis
        )
        guard finalMaxima.evidence.unservedPeakIDs.isEmpty else {
            throw Error.finalVerificationFailed(
                "persistent-maxima analysis leaves unserved peaks \(finalMaxima.evidence.unservedPeakIDs); selected vent peaks \(finalMaxima.evidence.selectedVentPeakIDs)"
            )
        }
        if ventPaths.isEmpty, finalMaxima.evidence.gateServedPeakIDs.count != finalMaxima.evidence.qualifyingBasinCount {
            throw Error.finalVerificationFailed("zero production vents lacks complete gate-service evidence")
        }

        let roundTripShell = try proposal.shellParts.map { part in
            MotherMoldPart(name: part.name, geometry: try roundTrip(part.geometry), isWatertight: true)
        }
        let roundTripAudit = proposal.protectedAuditSet.audit(finalParts: roundTripShell, stage: .flow)
        guard roundTripAudit.passes else {
            throw Error.protectedToolingAuditFailed(roundTripAudit.diagnostics.joined(separator: " "))
        }
        let roundTripAsPoured = try roundTrip(input.asPouredLiner)
        let roundTripProduction = try roundTrip(input.productionLiner)
        let roundTripArtifacts = try proposal.fixtureArtifacts.map { artifact -> ToolingArtifact in
            var copy = artifact
            copy.geometry = try roundTrip(artifact.geometry)
            return copy
        }
        for (label, liner) in [
            ("final as-poured liner", input.asPouredLiner),
            ("round-tripped as-poured liner", roundTripAsPoured),
            ("final production liner", input.productionLiner),
            ("round-tripped production liner", roundTripProduction),
        ] {
            guard materialComponentCount(liner) == 1 else {
                throw Error.finalVerificationFailed("\(label) is not exactly one connected material component")
            }
        }
        for part in proposal.shellParts + roundTripShell {
            try validSolid(part.geometry, label: "final shell part \(part.name)")
            guard materialComponentCount(part.geometry) == 1 else {
                throw Error.finalVerificationFailed("final shell part \(part.name) is not exactly one connected component")
            }
        }
        for artifact in proposal.fixtureArtifacts + roundTripArtifacts {
            try validSolid(artifact.geometry, label: artifact.name)
            guard materialComponentCount(artifact.geometry) == 1 else {
                throw Error.finalVerificationFailed("\(artifact.name) is not exactly one connected component")
            }
        }

        var measurements: [PathMeasurement] = []
        var summaries: [MoldFlowPathSummary] = []
        for path in proposal.pathSpecs {
            let inMemory: Double
            let afterRoundTrip: Double
            switch path.kind {
            case .linerMaterial:
                inMemory = try measureContainedBore(path: path, material: input.asPouredLiner)
                afterRoundTrip = try measureContainedBore(path: path, material: roundTripAsPoured)
            case .productionClearance:
                let artifacts = path.id == "production-gate-01" ? proposal.fixtureArtifacts.map(\.geometry) : []
                let roundArtifacts = path.id == "production-gate-01" ? roundTripArtifacts.map(\.geometry) : []
                inMemory = try measureClearBore(path: path, obstacles: proposal.shellParts.map(\.geometry) + [input.productionLiner] + artifacts)
                afterRoundTrip = try measureClearBore(path: path, obstacles: roundTripShell.map(\.geometry) + [roundTripProduction] + roundArtifacts)
            }
            let measured = min(inMemory, afterRoundTrip)
            guard measured + boreTolerance >= path.declaredDiameter else {
                throw Error.pendingMeasurement(
                    "\(path.id) (in-memory \(format(inMemory)) mm, round-trip \(format(afterRoundTrip)) mm, required \(format(path.declaredDiameter - boreTolerance)) mm)"
                )
            }
            let owners = try finalOwnerIndices(path: path, original: proposal.originalShellParts, final: proposal.shellParts)
            guard owners == path.ownerIndices,
                  path.ownerIndices.allSatisfy(proposal.shellParts.indices.contains) else {
                throw Error.finalVerificationFailed("\(path.id) final exact ownership changed")
            }
            let ownerNames = path.ownerIndices.map { proposal.shellParts[$0].name }
            measurements.append(PathMeasurement(
                pathID: path.id,
                configuredDiameterMillimeters: path.declaredDiameter,
                inMemoryMinimumDiameterMillimeters: inMemory,
                roundTripMinimumDiameterMillimeters: afterRoundTrip,
                ownerPartNames: ownerNames,
                connectivityVerified: true
            ))
            let maximaNote = path.phase == .casting
                ? "Maxima evidence: \(finalMaxima.evidence.qualifyingBasinCount) qualifying basin(s), \(finalMaxima.evidence.gateServedPeakIDs.count) gate-served, \(finalMaxima.evidence.ventServedPeakIDs.count) vent-served, \(finalMaxima.evidence.unservedPeakIDs.count) unserved."
                : "Temporary liner-fill path; excluded from production vent service."
            summaries.append(MoldFlowPathSummary(
                id: path.id, phase: path.phase, state: .geometryVerified, label: path.label,
                gravityUpAxis: codable(path.phase == .linerFill ? proposal.linerFillUpAxis : proposal.castingUpAxis),
                entryPoint: codable(path.outerPoint), exitPoint: codable(path.innerPoint),
                declaredDiameterMillimeters: path.declaredDiameter,
                measuredMinimumDiameterMillimeters: measured,
                artifactIDs: path.artifactIDs,
                notes: [
                    "Measured minimum bore \(format(inMemory)) mm in memory and \(format(afterRoundTrip)) mm after mesh round-trip; owned by \(ownerNames.joined(separator: ", ")).",
                    maximaNote,
                ]
            ))
        }

        let recheckedFunnel = try remeasureFunnel(
            proposal: proposal,
            funnel: proposal.fixtureArtifacts.first { $0.role == .castingFunnel }!.geometry,
            source: proposal.immutableSource
        )
        return Result(
            shellParts: proposal.shellParts,
            fixtureArtifacts: proposal.fixtureArtifacts,
            preparedMasterAdditions: proposal.preparedMasterAdditions,
            linerFillAdditives: proposal.linerFillAdditives,
            trimOperations: proposal.trimOperations,
            persistentProductionVoids: proposal.persistentProductionVoids,
            protectedLinerRegions: proposal.protectedLinerRegions,
            summaries: summaries,
            measurements: measurements,
            ventFormers: proposal.ventFormers,
            persistentMaximaEvidence: finalMaxima.evidence,
            funnelEvidence: recheckedFunnel,
            protectedAuditSet: proposal.protectedAuditSet,
            diagnostics: proposal.diagnostics + [MoldDiagnostic(
                .info,
                "Final flow transaction passed exact liner-state, bore, ownership, maxima-service, fixture, and round-trip gates.",
                subsystem: .productionCasting,
                code: MoldDiagnosticCode(rawValue: "flow.finalVerified"),
                recoveryActions: [.reviewAssemblyGuide]
            )]
        )
    }

    /// Internal test surface for asymmetric service-direction fixtures.
    static func analyzePersistentMaxima(
        cavity: MeshGeometryData,
        gatePoint: Vec3,
        ventPoints: [Vec3],
        axis: Vec3
    ) throws -> MaximaAnalysis {
        try validSolid(cavity, label: "production casting cavity")
        let up = try unit(axis, label: "casting up axis")
        let heights = cavity.vertices.map { dot($0, up) }
        let floor = heights.min() ?? 0
        let span = (heights.max() ?? floor) - floor
        let cavityVolume = try volume(cavity)
        let depthThreshold = max(2, span * 0.01)
        let volumeThreshold = max(50, cavityVolume * 0.001)
        let adjacency = graph(cavity)
        let basins = persistenceBasins(heights: heights, adjacency: adjacency, cavity: cavity, floor: floor)
        let qualifying = basins.filter {
            $0.persistence >= depthThreshold || $0.estimatedVolume >= volumeThreshold
        }.sorted { $0.peak < $1.peak }
        let gateVertex = nearestVertex(to: gatePoint, in: cavity.vertices)
        let gateService = reverseOutletReachable(from: gateVertex, heights: heights, adjacency: adjacency)
        let ventServices = ventPoints.map {
            reverseOutletReachable(from: nearestVertex(to: $0, in: cavity.vertices), heights: heights, adjacency: adjacency)
        }
        var gateServed: [Int] = []
        var ventServed: [Int] = []
        var unserved: [Int] = []
        for basin in qualifying {
            if gateService.contains(basin.peak) {
                gateServed.append(basin.peak)
            } else if ventServices.contains(where: { $0.contains(basin.peak) }) {
                ventServed.append(basin.peak)
            } else {
                unserved.append(basin.peak)
            }
        }
        return MaximaAnalysis(
            basins: basins,
            qualifying: qualifying,
            evidence: PersistentMaximaEvidence(
                localPeakCount: basins.count,
                qualifyingBasinCount: qualifying.count,
                gateServedPeakIDs: gateServed,
                ventServedPeakIDs: ventServed,
                unservedPeakIDs: unserved,
                selectedVentPeakIDs: ventPoints.map { nearestVertex(to: $0, in: cavity.vertices) },
                persistenceThresholdMillimeters: depthThreshold,
                trappedVolumeThresholdCubicMillimeters: volumeThreshold
            )
        )
    }

    static func outletServedVertexIDs(
        cavity: MeshGeometryData,
        outletPoint: Vec3,
        axis: Vec3
    ) throws -> [Int] {
        try validSolid(cavity, label: "outlet-service cavity")
        let up = try unit(axis, label: "outlet-service axis")
        let heights = cavity.vertices.map { dot($0, up) }
        let outlet = nearestVertex(to: outletPoint, in: cavity.vertices)
        return reverseOutletReachable(
            from: outlet,
            heights: heights,
            adjacency: graph(cavity)
        ).sorted()
    }

    private static func validateProposalInput(_ input: ProposalInput) throws {
        guard !input.shellParts.isEmpty else { throw Error.invalidInput("at least one shell part is required") }
        guard input.demoldAxes.isEmpty || input.demoldAxes.count == input.shellParts.count else {
            throw Error.invalidInput("demold axes must be omitted or parallel shell parts")
        }
        for (label, solid) in [
            ("immutable source", input.immutableSource),
            ("cavity envelope", input.cavityEnvelope),
            ("one-time pour positive", input.oneTimePourPositive),
        ] {
            try validSolid(solid, label: label)
            guard materialComponentCount(solid) == 1 else {
                throw Error.invalidInput("\(label) must be exactly one connected material component")
            }
        }
        for part in input.shellParts {
            try validSolid(part.geometry, label: part.name)
            guard materialComponentCount(part.geometry) == 1 else {
                throw Error.invalidInput("shell part \(part.name) must be exactly one connected material component")
            }
        }
        for (index, axis) in input.demoldAxes.enumerated() {
            _ = try unit(axis, label: "demold axis \(index)")
        }
        guard input.settings.linerFillDiameter > 0,
              input.settings.linerVentDiameter > 0,
              input.settings.requestedLinerVentCount >= 0,
              input.settings.productionGateDiameter > 0,
              (2...6).contains(input.settings.productionVentDiameter),
              input.settings.funnelDraftDegrees >= 12,
              input.settings.ventDraftDegrees >= 2,
              (0.02...0.10).contains(input.settings.sealBeadCompressionFraction),
              input.settings.fitClearance >= 0 else {
            throw Error.invalidInput("flow diameters, drafts, compression, clearance, or vent count are outside the reusable-tooling contract")
        }
    }

    private static func buildFunnel(
        post: PreparedPostDatum,
        interface: FunnelInterfaceDatum,
        settings: Settings,
        source: MeshGeometryData,
        shellParts: [MotherMoldPart]
    ) throws -> FunnelBuild {
        for (label, solid) in [
            ("receiver bore", post.receiverBore),
            ("receiver material", post.receiverMaterial),
            ("seal bead", interface.sealBead),
            ("rigid stop", interface.rigidStop),
            ("receiver pin bore", interface.receiverPinBore),
        ] { try validSolid(solid, label: label) }
        let axis = try unit(post.receiverAxis, label: "receiver axis")
        let removal = try unit(interface.removalAxis, label: "funnel removal axis")
        let pinAxis = try unit(interface.pinAxis, label: "funnel pin axis")
        guard dot(axis, removal) > 0.999 else {
            throw Error.funnelInterfaceInvalid("removal axis is not the single outward receiver axis")
        }
        guard interface.sealBeadHeight > 0,
              interface.sealBeadInnerRadius > settings.productionGateDiameter / 2,
              interface.sealBeadOuterRadius > interface.sealBeadInnerRadius,
              interface.rigidStopOuterRadius > interface.rigidStopInnerRadius,
              interface.pinDiameter > 0,
              interface.roundedThroatRadius > 0 else {
            throw Error.funnelInterfaceInvalid("bead, stop, pin, or rounded-throat dimensions are incomplete")
        }
        let beadProjection = projectionBounds(interface.sealBead, axis: axis)
        guard abs((beadProjection.max - beadProjection.min) - interface.sealBeadHeight) <= boreTolerance else {
            throw Error.funnelInterfaceInvalid("declared bead height does not match exact bead solid")
        }
        let stopProjection = projectionBounds(interface.rigidStop, axis: axis)
        let stopContact = dot(interface.rigidStopContactPoint, axis)
        let datumStopGap = abs(stopProjection.max - stopContact)
        guard datumStopGap <= boreTolerance else {
            throw Error.funnelInterfaceInvalid("rigid stop contact point is inconsistent with exact stop solid")
        }

        let throat = post.collarExteriorPoint
        let gateRadius = settings.productionGateDiameter / 2
        let maximumNozzleOuterRadius = post.receiverMinimumClearanceDiameter / 2 - boreTolerance
        let nozzleOuterRadius = min(
            gateRadius + max(1, settings.fitClearance * 2),
            maximumNozzleOuterRadius
        )
        guard nozzleOuterRadius > gateRadius else {
            throw Error.manualSeparateGateRequired("prepared receiver has no measured radial clearance around the declared production gate")
        }
        let nozzle = try hollowSegment(
            from: post.gateRootPoint, to: throat,
            innerRadius: gateRadius, outerRadius: nozzleOuterRadius, sides: 96
        )
        let bodyLength = max(18, settings.productionGateDiameter * 1.5)
        let body = try roundedFunnelBody(
            origin: throat, axis: axis, length: bodyLength,
            innerRadius: gateRadius,
            outerLowRadius: max(nozzleOuterRadius, interface.rigidStopInnerRadius + 0.5),
            outerHighRadius: max(settings.productionGateDiameter * 1.5, interface.rigidStopOuterRadius),
            draftDegrees: settings.funnelDraftDegrees,
            roundingRadius: interface.roundedThroatRadius
        )
        let compressionDepth = interface.sealBeadHeight * settings.sealBeadCompressionFraction
        let compressionLow = add(
            interface.sealContactPoint,
            scale(axis, -compressionDepth)
        )
        let compressionHigh = add(interface.sealContactPoint, scale(axis, max(0.5, compressionDepth)))
        let compressionLand = try annularSegment(
            from: compressionLow, to: compressionHigh,
            innerRadius: interface.sealBeadInnerRadius,
            outerRadius: interface.sealBeadOuterRadius,
            sides: 96
        )
        let sealBridge = try annularSegment(
            from: compressionLow,
            to: compressionHigh,
            innerRadius: gateRadius,
            outerRadius: interface.sealBeadOuterRadius,
            sides: 96
        )
        let stopThickness = max(2, interface.pinDiameter)
        let stopRing = try annularSegment(
            from: interface.rigidStopContactPoint,
            to: add(interface.rigidStopContactPoint, scale(axis, stopThickness)),
            innerRadius: interface.rigidStopInnerRadius,
            outerRadius: interface.rigidStopOuterRadius,
            sides: 96
        )
        let stopShoulder = try annularSegment(
            from: interface.rigidStopContactPoint,
            to: add(interface.rigidStopContactPoint, scale(axis, stopThickness)),
            innerRadius: gateRadius,
            outerRadius: interface.rigidStopOuterRadius,
            sides: 96
        )
        let stopRingProjection = projectionBounds(stopRing, axis: axis)
        let stopGap = abs(stopRingProjection.min - stopProjection.max)
        guard stopGap <= boreTolerance else {
            throw Error.funnelInterfaceInvalid("generated funnel stop does not seat on the exact rigid-stop datum")
        }
        let pinExtent = projectionBounds(interface.receiverPinBore, axis: pinAxis)
        let lugLength = max(interface.pinDiameter * 3, pinExtent.max - pinExtent.min)
        let lug = try tubeCentered(
            center: interface.pinCenter, axis: pinAxis, length: lugLength,
            lowerRadius: interface.pinDiameter * 0.8,
            upperRadius: interface.pinDiameter * 0.8,
            sides: 64
        )
        let lugRadius = interface.pinDiameter * 0.8
        let pinAxialPoint = add(throat, scale(axis, dot(subtract(interface.pinCenter, throat), axis)))
        let pinRadialOffset = subtract(interface.pinCenter, pinAxialPoint)
        let pinRadialLength = length(pinRadialOffset)
        guard pinRadialLength > lugRadius else {
            throw Error.funnelInterfaceInvalid("shared receiver pin bore is not offset from the round gate path")
        }
        let pinRadialAxis = scale(pinRadialOffset, 1 / pinRadialLength)
        let bridgeOverlap = min(max(settings.fitClearance, 0.1), nozzleOuterRadius - gateRadius)
        let bridgeStartRadius = nozzleOuterRadius + lugRadius - bridgeOverlap
        let bridgeStart = add(pinAxialPoint, scale(pinRadialAxis, bridgeStartRadius))
        let lugBridge = try tubeBetween(
            bridgeStart,
            interface.pinCenter,
            lowerRadius: lugRadius,
            upperRadius: lugRadius,
            sides: 64
        )
        let pinBore = try tubeCentered(
            center: interface.pinCenter, axis: pinAxis, length: lugLength + 2,
            lowerRadius: interface.pinDiameter / 2,
            upperRadius: interface.pinDiameter / 2,
            sides: 64
        )
        let unbored = try unionAll([
            nozzle, body, compressionLand, sealBridge, stopRing, stopShoulder, lug, lugBridge,
        ])
        let pinCutVolume = try intersectionVolume(unbored, pinBore)
        let funnel = try printableNormalizedSolid(
            try subtract(unbored, pinBore),
            label: "casting funnel"
        )
        try validSolid(funnel, label: "casting funnel")
        guard materialComponentCount(funnel) == 1 else {
            throw Error.funnelInterfaceInvalid("funnel nozzle, stop, and cross-pin lug are not one connected artifact")
        }
        guard pinCutVolume > geometryTolerance else {
            throw Error.funnelInterfaceInvalid("shared cross-pin bore does not cut the generated funnel lug")
        }

        let insertedPhysical = try unionAll([nozzle, lug, lugBridge])
        let escapedReceiver = try differenceVolume(insertedPhysical, post.receiverBore)
        guard escapedReceiver <= geometryTolerance else {
            throw Error.funnelInterfaceInvalid("funnel nozzle or pin lug escapes the exact receiver clearance by \(format(escapedReceiver)) mm3")
        }
        let pinOverlap = try intersectionVolume(pinBore, interface.receiverPinBore)
        guard pinOverlap > geometryTolerance else {
            throw Error.funnelInterfaceInvalid("funnel pin bore does not engage the shared receiver pin bore")
        }
        guard try intersectionVolume(funnel, source) <= geometryTolerance else {
            throw Error.funnelInterfaceInvalid("assembled funnel intrudes into immutable art geometry")
        }
        let minimumBoreProbe = try tubeBetween(
            add(post.gateRootPoint, scale(axis, -0.25)),
            add(throat, scale(axis, bodyLength)),
            lowerRadius: max(0.01, gateRadius - boreTolerance / 2),
            upperRadius: max(0.01, gateRadius - boreTolerance / 2),
            sides: 96
        )
        guard try intersectionVolume(funnel, minimumBoreProbe) <= geometryTolerance else {
            throw Error.funnelInterfaceInvalid("funnel stop or retaining lug narrows the declared production gate")
        }
        let beadOverlap = try intersect(funnel, interface.sealBead)
        let overlapVolume = try volume(beadOverlap)
        guard overlapVolume > geometryTolerance else {
            let beadBounds = projectionBounds(interface.sealBead, axis: axis)
            let landBounds = projectionBounds(compressionLand, axis: axis)
            throw Error.funnelInterfaceInvalid(
                "funnel seal land does not compress the exact seal bead "
                + "(overlap \(format(overlapVolume)) mm3; bead axis \(format(beadBounds.min))...\(format(beadBounds.max)); "
                + "land axis \(format(landBounds.min))...\(format(landBounds.max)); stop \(format(stopContact)))"
            )
        }
        let overlapBounds = projectionBounds(beadOverlap, axis: axis)
        let measuredCompression = (overlapBounds.max - overlapBounds.min) / interface.sealBeadHeight
        guard (0.02 - 1.0e-4...0.10 + 1.0e-4).contains(measuredCompression),
              abs(measuredCompression - settings.sealBeadCompressionFraction) <= 0.002 else {
            throw Error.funnelInterfaceInvalid("measured bead compression \(format(measuredCompression * 100))% does not match declared \(format(settings.sealBeadCompressionFraction * 100))%")
        }
        let removalTravel = distance(post.gateRootPoint, throat) + bodyLength
        let stopSupportBefore = try shellParts.reduce(0.0) {
            $0 + (try intersectionVolume($1.geometry, interface.rigidStop))
        }
        guard stopSupportBefore > geometryTolerance else {
            throw Error.funnelInterfaceInvalid("exact rigid-stop datum has no supporting final shell material")
        }
        let removalSweep = try straightRemovalSweep(
            components: [nozzle, body, sealBridge, stopShoulder, lug, lugBridge],
            axis: removal,
            travel: removalTravel,
            clearance: max(boreTolerance, settings.fitClearance)
        )
        let stopPreservingSweep = try printableNormalizedSolid(
            try subtract(removalSweep, interface.rigidStop),
            label: "casting-funnel stop-preserving removal envelope"
        )
        let shellClearance = try carveAcrossParts(
            parts: shellParts,
            tool: stopPreservingSweep,
            label: "casting-funnel straight removal envelope"
        )
        let clearedShellParts = shellClearance.parts
        let stopSupportAfter = try clearedShellParts.reduce(0.0) {
            $0 + (try intersectionVolume($1.geometry, interface.rigidStop))
        }
        let allowedStopLoss = max(geometryTolerance, stopSupportBefore * 0.005)
        guard stopSupportAfter >= stopSupportBefore - allowedStopLoss else {
            throw Error.funnelInterfaceInvalid(
                "straight-removal clearance consumes the rigid stop "
                + "(retained \(format(stopSupportAfter)) of \(format(stopSupportBefore)) mm3)"
            )
        }
        let removalClear = try proveFunnelRemoval(
            funnel: funnel,
            axis: removal,
            shellParts: clearedShellParts,
            travel: removalTravel
        )
        guard removalClear else {
            throw Error.funnelInterfaceInvalid("funnel has no straight collision-free outward removal sweep")
        }
        let id = ToolingArtifactID("CAST FUNNEL")
        return FunnelBuild(
            artifact: ToolingArtifact(
                id: id, name: "production-casting-funnel", role: .castingFunnel,
                geometry: funnel, qualification: .topologyValid,
                materialHint: "rigid removable pinned insert"
            ),
            geometry: funnel,
            pinBore: pinBore,
            outerOpening: add(throat, scale(axis, bodyLength)),
            shellParts: clearedShellParts,
            shellClearanceRemovedByOwner: shellClearance.removedByOwner,
            evidence: FunnelEvidence(
                declaredCompressionFraction: settings.sealBeadCompressionFraction,
                measuredCompressionFraction: measuredCompression,
                rigidStopContactGapMillimeters: stopGap,
                pinBoreOverlapCubicMillimeters: pinOverlap,
                roundedThroatRadiusMillimeters: interface.roundedThroatRadius,
                removalAxis: removal,
                removalSweepClear: true
            )
        )
    }

    private static func buildRod(
        id: String,
        ordinal: Int,
        landingOuter: Vec3,
        axis: Vec3,
        diameter: Double,
        draftDegrees: Double,
        clearance: Double,
        shellParts: [MotherMoldPart]
    ) throws -> RodBuild {
        let shellProjection = shellParts.flatMap { $0.geometry.vertices }.map { dot($0, axis) }.max() ?? dot(landingOuter, axis)
        let bodyOuter = add(landingOuter, scale(axis, max(8, shellProjection - dot(landingOuter, axis) + 8)))
        let bodyLength = distance(landingOuter, bodyOuter)
        let innerRadius = diameter / 2
        let outerRadius = innerRadius + tan(draftDegrees * .pi / 180) * bodyLength
        let body = try tubeBetween(landingOuter, bodyOuter, lowerRadius: innerRadius, upperRadius: outerRadius, sides: 64)
        let gripLength = max(4, diameter * 1.5)
        let gripEnd = add(bodyOuter, scale(axis, gripLength))
        let grip = try tubeBetween(
            bodyOuter, gripEnd,
            lowerRadius: outerRadius * 1.6,
            upperRadius: outerRadius * 1.6,
            sides: 64
        )
        let complete = try unite(body, grip)
        let artifactID = ToolingArtifactID("VENT \(ordinal)")
        let sleeve = try tubeBetween(
            add(landingOuter, scale(axis, -0.2)),
            add(bodyOuter, scale(axis, 1)),
            lowerRadius: innerRadius + clearance,
            upperRadius: outerRadius + clearance,
            sides: 64
        )
        let linerVoid = try tubeBetween(
            add(landingOuter, scale(axis, -0.2)),
            add(bodyOuter, scale(axis, 1)),
            lowerRadius: innerRadius,
            upperRadius: innerRadius,
            sides: 96
        )
        // The body radius grows monotonically toward the grip. Its complete
        // straight extraction sweep is therefore the initial drafted body plus
        // the grip-radius envelope extending through the full travel.
        let sweptGrip = try tubeBetween(
            bodyOuter,
            add(gripEnd, scale(axis, bodyLength)),
            lowerRadius: outerRadius * 1.6,
            upperRadius: outerRadius * 1.6,
            sides: 64
        )
        let sweep = try unite(body, sweptGrip)
        return RodBuild(
            artifact: ToolingArtifact(
                id: artifactID, name: id, role: .productionVentFormer,
                geometry: complete, qualification: .topologyValid,
                materialHint: "drafted removable former with exterior grip"
            ),
            body: body,
            grip: grip,
            sweep: sweep,
            sleeve: sleeve,
            linerVoid: linerVoid,
            outerPoint: bodyOuter
        )
    }

    private static func proveRod(
        rod: RodBuild,
        landing: PreparedMasterBuilder.Addition,
        source: MeshGeometryData,
        shellParts: [MotherMoldPart],
        protected: [MeshGeometryData]
    ) throws {
        guard try intersectionVolume(rod.body, source) <= geometryTolerance else {
            throw Error.productionVentUnavailable("rod enters immutable art outside its typed landing")
        }
        guard try intersectionVolume(rod.body, landing.solid) <= geometryTolerance else {
            throw Error.productionVentUnavailable("rod penetrates rather than seats on its shallow landing")
        }
        for solid in protected where try intersectionVolume(rod.sweep, solid) > geometryTolerance {
            throw Error.productionVentUnavailable("straight extraction sweep collides with protected tooling")
        }
        for part in shellParts where try intersectionVolume(rod.sweep, part.geometry) > geometryTolerance {
            throw Error.productionVentUnavailable("drafted rod does not clear its final shell sleeve")
        }
        try validSolid(rod.artifact.geometry, label: rod.artifact.name)
        try validSolid(rod.sweep, label: "\(rod.artifact.name) removal sweep")
        guard materialComponentCount(rod.artifact.geometry) == 1,
              materialComponentCount(rod.sweep) == 1 else {
            throw Error.productionVentUnavailable("vent former or serialized extraction sweep is disconnected")
        }
    }

    private static func provePreparedMasterUpdate(
        base: MeshGeometryData,
        additions: [PreparedMasterBuilder.Addition],
        effective: MeshGeometryData,
        source: MeshGeometryData
    ) throws {
        try validSolid(effective, label: "effective one-time prepared positive")
        guard materialComponentCount(effective) == 1 else {
            throw Error.finalVerificationFailed("prepared master plus vent landings is not one connected component")
        }
        guard try differenceVolume(base, effective) <= geometryTolerance else {
            throw Error.finalVerificationFailed("effective one-time positive does not retain the complete base prepared master")
        }
        for addition in additions {
            try validSolid(addition.solid, label: addition.region.id)
            guard materialComponentCount(addition.solid) == 1,
                  try intersectionVolume(addition.solid, source) > geometryTolerance,
                  try differenceVolume(addition.solid, effective) <= geometryTolerance else {
                throw Error.finalVerificationFailed(
                    "prepared-master addition \(addition.region.id) is disconnected from the immutable source or absent from final prepared geometry"
                )
            }
        }
    }

    private static func actualLinerAdditive(
        rawPath: MeshGeometryData,
        baseLiner: MeshGeometryData,
        positive: MeshGeometryData
    ) throws -> (addition: MeshGeometryData, exteriorTrim: MeshGeometryData) {
        let fillablePath = try subtract(rawPath, positive)
        let exteriorTrim = try subtract(fillablePath, baseLiner)
        return (fillablePath, exteriorTrim)
    }

    private static func proveLinerAddition(
        _ additive: MeshGeometryData,
        connectsTo baseLiner: MeshGeometryData,
        avoids positive: MeshGeometryData,
        label: String
    ) throws {
        try validSolid(additive, label: label)
        guard try intersectionVolume(additive, positive) <= geometryTolerance else {
            throw Error.linerFillUnavailable("\(label) adds silicone through the one-time positive/art surface")
        }
        guard try intersectionVolume(additive, baseLiner) > geometryTolerance else {
            throw Error.linerFillUnavailable("\(label) only touches the exact base liner and has no positive-volume root")
        }
        let combined = try unite(baseLiner, additive)
        guard materialComponentCount(combined) == 1 else {
            throw Error.linerFillUnavailable("\(label) does not connect to the exact base liner")
        }
    }

    private static func proveTrimProtection(
        trims: [MoldLinerTrimOperation],
        protected: [MoldLinerProtectedRegion],
        productionVoids: [MoldLinerPersistentVoid]
    ) throws {
        for trim in trims {
            for region in protected where try intersectionVolume(trim.solid, region.solid) > geometryTolerance {
                throw Error.protectedTrimOverlap(trimID: trim.id, protectedID: region.id)
            }
            for void in productionVoids where try intersectionVolume(trim.solid, void.solid) > geometryTolerance {
                throw Error.protectedTrimOverlap(trimID: trim.id, protectedID: void.id)
            }
        }
    }

    private static func minimumVentSet(
        qualifying: [Basin],
        gatePoint: Vec3,
        cavity: MeshGeometryData,
        axis: Vec3
    ) throws -> [Int] {
        guard qualifying.count <= 16 else {
            throw Error.productionVentUnavailable("exact minimum vent-set search exceeds the 16-basin fail-closed limit")
        }
        let gateOnly = try analyzePersistentMaxima(cavity: cavity, gatePoint: gatePoint, ventPoints: [], axis: axis)
        let targets = Set(gateOnly.evidence.unservedPeakIDs)
        guard !targets.isEmpty else { return [] }
        let candidates = qualifying.map(\.peak).filter { targets.contains($0) }.sorted()
        let heights = cavity.vertices.map { dot($0, normalize(axis)) }
        let adjacency = graph(cavity)
        let coverage = Dictionary(uniqueKeysWithValues: candidates.map { peak -> (Int, Set<Int>) in
            let reached = reverseOutletReachable(from: peak, heights: heights, adjacency: adjacency)
            return (peak, Set(targets.filter { reached.contains($0) }))
        })
        for count in 1...candidates.count {
            if let selection = firstCombination(candidates, count: count, covers: targets, coverage: coverage) {
                return selection
            }
        }
        throw Error.productionVentUnavailable("no deterministic vent set serves every qualifying basin")
    }

    private static func firstCombination(
        _ values: [Int],
        count: Int,
        covers targets: Set<Int>,
        coverage: [Int: Set<Int>]
    ) -> [Int]? {
        var chosen: [Int] = []
        func search(_ start: Int, _ covered: Set<Int>) -> [Int]? {
            if chosen.count == count { return covered.isSuperset(of: targets) ? chosen : nil }
            guard values.count - start >= count - chosen.count else { return nil }
            for index in start..<values.count {
                chosen.append(values[index])
                if let result = search(index + 1, covered.union(coverage[values[index]] ?? [])) { return result }
                chosen.removeLast()
            }
            return nil
        }
        return search(0, [])
    }

    private static func persistenceBasins(
        heights: [Double],
        adjacency: [[Int]],
        cavity: MeshGeometryData,
        floor: Double
    ) -> [Basin] {
        let order = heights.indices.sorted { heights[$0] == heights[$1] ? $0 < $1 : heights[$0] > heights[$1] }
        var parent = Array(repeating: -1, count: heights.count)
        var peak = Array(repeating: -1, count: heights.count)
        var members = Array(repeating: [Int](), count: heights.count)
        func root(_ start: Int) -> Int {
            var cursor = start
            while parent[cursor] != cursor { cursor = parent[cursor] }
            return cursor
        }
        var basins: [Basin] = []
        for vertex in order {
            parent[vertex] = vertex
            peak[vertex] = vertex
            members[vertex] = [vertex]
            let neighborRoots = Set(adjacency[vertex].filter { parent[$0] >= 0 }.map(root)).sorted()
            for neighborRoot in neighborRoots {
                let currentRoot = root(vertex)
                let otherRoot = root(neighborRoot)
                guard currentRoot != otherRoot else { continue }
                let currentPeak = peak[currentRoot]
                let otherPeak = peak[otherRoot]
                let currentWins = heights[currentPeak] > heights[otherPeak]
                    || (heights[currentPeak] == heights[otherPeak] && currentPeak < otherPeak)
                let winner = currentWins ? currentRoot : otherRoot
                let loser = currentWins ? otherRoot : currentRoot
                let loserPeak = peak[loser]
                let persistence = max(0, heights[loserPeak] - heights[vertex])
                if persistence > 1.0e-9 {
                    basins.append(Basin(
                        peak: loserPeak,
                        persistence: persistence,
                        estimatedVolume: estimatedVolume(
                            vertices: members[loser], heights: heights,
                            floor: heights[vertex], cavity: cavity
                        )
                    ))
                }
                parent[loser] = winner
                members[winner].append(contentsOf: members[loser])
            }
        }
        if let first = order.first {
            let finalRoot = root(first)
            let finalPeak = peak[finalRoot]
            basins.append(Basin(
                peak: finalPeak,
                persistence: max(0, heights[finalPeak] - floor),
                estimatedVolume: estimatedVolume(
                    vertices: members[finalRoot], heights: heights,
                    floor: floor, cavity: cavity
                )
            ))
        }
        var seen = Set<Int>()
        return basins.filter { seen.insert($0.peak).inserted }
    }

    /// Reverse traversal from an outlet follows non-increasing height. This is
    /// equivalent to proving a peak-to-outlet path whose height never decreases.
    private static func reverseOutletReachable(
        from outlet: Int,
        heights: [Double],
        adjacency: [[Int]]
    ) -> Set<Int> {
        var reached: Set<Int> = [outlet]
        var queue = [outlet]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for next in adjacency[current]
                where heights[next] <= heights[current] + 1.0e-9
                    && reached.insert(next).inserted {
                queue.append(next)
            }
        }
        return reached
    }

    private static func estimatedVolume(
        vertices: [Int],
        heights: [Double],
        floor: Double,
        cavity: MeshGeometryData
    ) -> Double {
        let selected = Set(vertices)
        var result = 0.0
        var index = 0
        while index + 2 < cavity.triangleIndices.count {
            let a = Int(cavity.triangleIndices[index])
            let b = Int(cavity.triangleIndices[index + 1])
            let c = Int(cavity.triangleIndices[index + 2])
            if selected.contains(a), selected.contains(b), selected.contains(c) {
                let area = triangleArea(cavity.vertices[a], cavity.vertices[b], cavity.vertices[c])
                let depth = max(0, (heights[a] + heights[b] + heights[c]) / 3 - floor)
                result += area * depth / 3
            }
            index += 3
        }
        return result
    }

    private static func measureContainedBore(path: PathSpec, material: MeshGeometryData) throws -> Double {
        try binarySearchDiameter(path: path) { probe in
            try differenceVolume(probe, material) <= geometryTolerance
        }
    }

    private static func measureClearBore(path: PathSpec, obstacles: [MeshGeometryData]) throws -> Double {
        try binarySearchDiameter(path: path) { probe in
            for obstacle in obstacles where try intersectionVolume(probe, obstacle) > geometryTolerance {
                return false
            }
            return true
        }
    }

    private static func binarySearchDiameter(
        path: PathSpec,
        accepts: (MeshGeometryData) throws -> Bool
    ) throws -> Double {
        var low = 0.0
        var high = path.declaredDiameter + 0.25
        guard try accepts(try pathProbe(path, diameter: 0.1)) else {
            throw Error.pendingMeasurement(path.id)
        }
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if try accepts(try pathProbe(path, diameter: mid)) { low = mid } else { high = mid }
        }
        return low
    }

    private static func pathProbe(_ path: PathSpec, diameter: Double) throws -> MeshGeometryData {
        try tubeBetween(
            path.innerPoint, path.outerPoint,
            lowerRadius: max(0.01, diameter / 2),
            upperRadius: max(0.01, diameter / 2),
            sides: 96
        )
    }

    private static func finalOwnerIndices(
        path: PathSpec,
        original: [MotherMoldPart],
        final: [MotherMoldPart]
    ) throws -> [Int] {
        guard original.count == final.count else { return [] }
        var owners: [Int] = []
        for index in original.indices {
            let removed = try subtract(original[index].geometry, final[index].geometry)
            if try intersectionVolume(removed, path.shellTool) > geometryTolerance { owners.append(index) }
        }
        if owners.isEmpty, let witness = path.ownershipWitness {
            for index in final.indices where try intersectionVolume(final[index].geometry, witness) > geometryTolerance {
                owners.append(index)
            }
        }
        return owners
    }

    private static func remeasureFunnel(
        proposal: Proposal,
        funnel: MeshGeometryData,
        source: MeshGeometryData
    ) throws -> FunnelEvidence {
        let roundTripped = try roundTrip(funnel)
        let interface = proposal.funnelInterface
        let post = proposal.preparedPost
        let axis = normalize(post.receiverAxis)
        let beadOverlap = try intersect(roundTripped, interface.sealBead)
        let beadBounds = projectionBounds(beadOverlap, axis: axis)
        let compression = (beadBounds.max - beadBounds.min) / interface.sealBeadHeight
        let stopBounds = projectionBounds(interface.rigidStop, axis: axis)
        let stopThickness = max(2, interface.pinDiameter)
        let stopRing = try annularSegment(
            from: interface.rigidStopContactPoint,
            to: add(interface.rigidStopContactPoint, scale(axis, stopThickness)),
            innerRadius: interface.rigidStopInnerRadius,
            outerRadius: interface.rigidStopOuterRadius,
            sides: 96
        )
        let stopGap = abs(projectionBounds(stopRing, axis: axis).min - stopBounds.max)
        let missingStopVolume = try differenceVolume(stopRing, roundTripped)
        let pinAxis = normalize(interface.pinAxis)
        let pinExtent = projectionBounds(interface.receiverPinBore, axis: pinAxis)
        let lugLength = max(interface.pinDiameter * 3, pinExtent.max - pinExtent.min)
        let pinLength = lugLength + 2
        let pinBore = try tubeCentered(
            center: interface.pinCenter, axis: pinAxis, length: pinLength,
            lowerRadius: interface.pinDiameter / 2,
            upperRadius: interface.pinDiameter / 2,
            sides: 64
        )
        let expectedLug = try tubeCentered(
            center: interface.pinCenter, axis: pinAxis, length: lugLength,
            lowerRadius: interface.pinDiameter * 0.8,
            upperRadius: interface.pinDiameter * 0.8,
            sides: 64
        )
        let expectedLugShell = try subtract(expectedLug, pinBore)
        let missingLugVolume = try differenceVolume(expectedLugShell, roundTripped)
        let pinOverlap = try intersectionVolume(pinBore, interface.receiverPinBore)
        let removalClear = try proveFunnelRemoval(
            funnel: roundTripped,
            axis: normalize(interface.removalAxis),
            shellParts: proposal.shellParts,
            travel: distance(post.gateRootPoint, post.collarExteriorPoint) + max(18, proposal.settings.productionGateDiameter * 1.5)
        )
        guard try intersectionVolume(roundTripped, source) <= geometryTolerance,
              try intersectionVolume(roundTripped, pinBore) <= geometryTolerance,
              (0.02 - 1.0e-4...0.10 + 1.0e-4).contains(compression),
              abs(compression - proposal.settings.sealBeadCompressionFraction) <= 0.002,
              pinOverlap > geometryTolerance,
              stopGap <= boreTolerance,
              missingStopVolume <= geometryTolerance,
              missingLugVolume <= geometryTolerance,
              materialComponentCount(roundTripped) == 1,
              removalClear else {
            throw Error.funnelInterfaceInvalid("funnel evidence did not survive final round-trip validation")
        }
        return FunnelEvidence(
            declaredCompressionFraction: proposal.settings.sealBeadCompressionFraction,
            measuredCompressionFraction: compression,
            rigidStopContactGapMillimeters: stopGap,
            pinBoreOverlapCubicMillimeters: pinOverlap,
            roundedThroatRadiusMillimeters: interface.roundedThroatRadius,
            removalAxis: normalize(interface.removalAxis),
            removalSweepClear: removalClear
        )
    }

    private static func carveUnique(
        parts: [MotherMoldPart],
        tool: MeshGeometryData,
        protected: [MeshGeometryData],
        label: String
    ) throws -> BoreResult {
        for (index, solid) in protected.enumerated()
            where try intersectionVolume(tool, solid) > geometryTolerance {
            throw Error.finalVerificationFailed("\(label) consumes reserved or protected tooling at index \(index)")
        }
        let owners = try parts.indices.filter { try intersectionVolume(parts[$0].geometry, tool) > geometryTolerance }
        guard owners.count == 1, let owner = owners.first else {
            throw Error.finalVerificationFailed("\(label) is not owned by exactly one shell part")
        }
        var updated = parts
        let removedByOwner = try removedProfiles(parts: parts, ownerIndices: owners, tool: tool)
        let normalized = try printableNormalizedSolid(
            try subtract(parts[owner].geometry, tool),
            label: "\(label) shell owner"
        )
        guard try intersectionVolume(normalized, tool) <= geometryTolerance else {
            throw Error.finalVerificationFailed("\(label) was partially closed by bounded shell normalization")
        }
        updated[owner].geometry = normalized
        let normalizedHandle = try ManifoldEngine.make(from: normalized)
        updated[owner].bounds = ManifoldEngine.bounds(normalizedHandle)
        withExtendedLifetime(normalizedHandle) {}
        updated[owner].isWatertight = true
        try validSolid(updated[owner].geometry, label: "\(label) shell owner")
        return BoreResult(parts: updated, ownerIndices: [owner], removedByOwner: removedByOwner)
    }

    private static func removedProfiles(
        parts: [MotherMoldPart],
        ownerIndices: [Int],
        tool: MeshGeometryData
    ) throws -> [Int: [MeshGeometryData]] {
        guard !ownerIndices.isEmpty else { return [:] }
        let toolSolid = try ManifoldEngine.make(from: tool)
        var profiles: [Int: [MeshGeometryData]] = [:]
        for index in ownerIndices where parts.indices.contains(index) {
            let part = try ManifoldEngine.make(from: parts[index].geometry)
            let removed = try ManifoldEngine.intersect(part, toolSolid)
            if !ManifoldEngine.isEmpty(removed),
               abs(ManifoldEngine.volume(removed)) > ProtectedToolingAuditSet.minimumMeasurableVolumeMM3 {
                profiles[index] = try ManifoldEngine.decompose(removed)
                    .filter { abs(ManifoldEngine.volume($0)) > ProtectedToolingAuditSet.minimumMeasurableVolumeMM3 }
                    .map { try ManifoldEngine.toMesh($0) }
            }
        }
        return profiles
    }

    private static func flowVoidRecords(
        id: String,
        kind: ProtectedToolingAuditSet.SemanticKind,
        bore: BoreResult,
        parts: [MotherMoldPart]
    ) throws -> [ProtectedToolingAuditSet.Record] {
        try bore.removedByOwner.sorted(by: { $0.key < $1.key }).flatMap { owner, geometries -> [ProtectedToolingAuditSet.Record] in
            let partName = parts[owner].name
            return try geometries.enumerated().map { componentIndex, geometry in
                ProtectedToolingAuditSet.Record(
                    id: "\(id)-\(partName)-\(componentIndex + 1)",
                    kind: kind,
                    behavior: .subtractive,
                    ownership: .singlePart(partName),
                    geometry: try printableNormalizedSolid(
                        geometry,
                        label: "\(id) audit witness \(partName) \(componentIndex + 1)"
                    ),
                    requiredRetention: 1,
                    requiredClearance: 0.98,
                    provenance: [.flow]
                )
            }
        }
    }

    private static func proveFunnelRemoval(
        funnel: MeshGeometryData,
        axis: Vec3,
        shellParts: [MotherMoldPart],
        travel: Double
    ) throws -> Bool {
        for fraction in [0.0, 0.05, 0.25, 0.5, 0.75, 1.0] {
            let moved = try translated(funnel, by: scale(axis, travel * fraction))
            for part in shellParts where try intersectionVolume(moved, part.geometry) > geometryTolerance { return false }
        }
        return true
    }

    private static func straightRemovalSweep(
        components: [MeshGeometryData],
        axis: Vec3,
        travel: Double,
        clearance: Double
    ) throws -> MeshGeometryData {
        var sweeps: [MeshGeometryData] = []
        sweeps.reserveCapacity(components.count)
        for component in components {
            let start = try ManifoldEngine.make(from: component)
            let moved = try translated(component, by: scale(axis, travel))
            let end = try ManifoldEngine.make(from: moved)
            let hull = try ManifoldEngine.convexHull(joining: start, end)
            sweeps.append(try ManifoldEngine.toMesh(hull))
            withExtendedLifetime(start) {}
            withExtendedLifetime(end) {}
            withExtendedLifetime(hull) {}
        }
        let united = try unionAll(sweeps)
        let unitedHandle = try ManifoldEngine.make(from: united)
        let clearanceBox = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: clearance * 2, y: clearance * 2, z: clearance * 2)
        ))
        let expanded = try ManifoldEngine.minkowskiSum(unitedHandle, clearanceBox)
        let expandedMesh = try ManifoldEngine.toMesh(expanded)
        withExtendedLifetime(unitedHandle) {}
        withExtendedLifetime(clearanceBox) {}
        withExtendedLifetime(expanded) {}
        return try printableNormalizedSolid(
            expandedMesh,
            label: "casting-funnel straight removal envelope"
        )
    }

    private static func carveAcrossParts(
        parts: [MotherMoldPart],
        tool: MeshGeometryData,
        label: String
    ) throws -> BoreResult {
        let owners = try parts.indices.filter {
            try intersectionVolume(parts[$0].geometry, tool) > geometryTolerance
        }
        guard !owners.isEmpty else {
            return BoreResult(parts: parts, ownerIndices: [], removedByOwner: [:])
        }
        let removedByOwner = try removedProfiles(parts: parts, ownerIndices: owners, tool: tool)
        var updated = parts
        for owner in owners {
            let normalized = try printableNormalizedSolid(
                try subtract(updated[owner].geometry, tool),
                label: "\(label) shell part \(updated[owner].name)"
            )
            guard try intersectionVolume(normalized, tool) <= geometryTolerance else {
                throw Error.finalVerificationFailed("\(label) was partially closed by bounded shell normalization")
            }
            updated[owner].geometry = normalized
            let handle = try ManifoldEngine.make(from: normalized)
            updated[owner].bounds = ManifoldEngine.bounds(handle)
            withExtendedLifetime(handle) {}
            updated[owner].isWatertight = true
        }
        return BoreResult(parts: updated, ownerIndices: owners, removedByOwner: removedByOwner)
    }

    private static func requireSameSolid(
        _ expected: MeshGeometryData,
        _ actual: MeshGeometryData,
        label: String
    ) throws {
        let difference = try differenceVolume(expected, actual) + differenceVolume(actual, expected)
        guard difference <= geometryTolerance else {
            throw Error.staleLinerState(state: label, symmetricDifference: difference)
        }
    }

    private static func validSolid(_ geometry: MeshGeometryData, label: String) throws {
        let finite = geometry.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        let indexedTriangles = geometry.triangleIndices.count >= 3
            && geometry.triangleIndices.count.isMultiple(of: 3)
        let preflight = MotherMoldValidation.printablePreflight(geometry)
        let handle = try? ManifoldEngine.make(from: geometry)
        let manifoldWatertight = handle.map { !ManifoldEngine.isEmpty($0) && ManifoldEngine.isWatertight($0) } ?? false
        let solidVolume = handle.map { abs(ManifoldEngine.volume($0)) } ?? 0
        guard !geometry.vertices.isEmpty,
              indexedTriangles,
              finite,
              preflight.isWatertight,
              manifoldWatertight,
              solidVolume > 1.0e-8 else {
            throw Error.invalidInput(
                "\(label) is not a finite, closed, positive-volume solid "
                + "(boundary \(preflight.boundaryEdgeCount), non-manifold \(preflight.nonManifoldEdgeCount), "
                + "degenerate \(preflight.degenerateTriangleCount), "
                + "manifold \(manifoldWatertight), volume \(format(solidVolume)) mm3)"
            )
        }
    }

    private static func printableNormalizedSolid(
        _ geometry: MeshGeometryData,
        label: String
    ) throws -> MeshGeometryData {
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: label,
            geometry: geometry,
            isWatertight: false
        )])
        guard validation.allPartsWatertight,
              let normalized = validation.parts.first,
              MeshPreflight.analyze(geometry: normalized.geometry).isWatertight else {
            throw Error.finalVerificationFailed("\(label) could not be normalized into safe serialized geometry")
        }
        return normalized.geometry
    }

    private static func roundedFunnelBody(
        origin: Vec3,
        axis: Vec3,
        length: Double,
        innerRadius: Double,
        outerLowRadius: Double,
        outerHighRadius: Double,
        draftDegrees: Double,
        roundingRadius: Double
    ) throws -> MeshGeometryData {
        let round = min(roundingRadius, length * 0.25)
        var stations: [(Double, Double, Double)] = []
        let roundedSteps = 6
        for step in 0...roundedSteps {
            let t = round * Double(step) / Double(roundedSteps)
            let inside = max(0, round * round - t * t).squareRoot()
            let inner = innerRadius + round - inside
            let outer = outerLowRadius + tan(draftDegrees * .pi / 180) * t
            stations.append((t, outer, inner))
        }
        stations.append((length, outerHighRadius, max(innerRadius + round, outerHighRadius - 2)))
        return try revolvedHollow(origin: origin, axis: axis, stations: stations, sides: 96)
    }

    private static func revolvedHollow(
        origin: Vec3,
        axis: Vec3,
        stations: [(Double, Double, Double)],
        sides: Int
    ) throws -> MeshGeometryData {
        let direction = try unit(axis, label: "revolved axis")
        let u = perpendicular(to: direction)
        let v = cross(direction, u)
        var vertices: [Vec3] = []
        for station in stations {
            let center = add(origin, scale(direction, station.0))
            for index in 0..<sides {
                let angle = Double(index) * 2 * .pi / Double(sides)
                let radial = add(scale(u, cos(angle)), scale(v, sin(angle)))
                vertices.append(add(center, scale(radial, station.1)))
            }
            for index in 0..<sides {
                let angle = Double(index) * 2 * .pi / Double(sides)
                let radial = add(scale(u, cos(angle)), scale(v, sin(angle)))
                vertices.append(add(center, scale(radial, station.2)))
            }
        }
        var indices: [Int32] = []
        for station in 0..<(stations.count - 1) {
            let base = station * sides * 2
            let nextBase = base + sides * 2
            for index in 0..<sides {
                let next = (index + 1) % sides
                let o0 = Int32(base + index), o1 = Int32(base + next)
                let o2 = Int32(nextBase + index), o3 = Int32(nextBase + next)
                indices += [o0, o1, o2, o1, o3, o2]
                let i0 = Int32(base + sides + index), i1 = Int32(base + sides + next)
                let i2 = Int32(nextBase + sides + index), i3 = Int32(nextBase + sides + next)
                indices += [i0, i2, i1, i1, i2, i3]
            }
        }
        let firstOuter = 0
        let firstInner = sides
        let lastOuter = (stations.count - 1) * sides * 2
        let lastInner = lastOuter + sides
        for index in 0..<sides {
            let next = (index + 1) % sides
            indices += [Int32(firstOuter + index), Int32(firstInner + index), Int32(firstOuter + next)]
            indices += [Int32(firstOuter + next), Int32(firstInner + index), Int32(firstInner + next)]
            indices += [Int32(lastOuter + index), Int32(lastOuter + next), Int32(lastInner + index)]
            indices += [Int32(lastOuter + next), Int32(lastInner + next), Int32(lastInner + index)]
        }
        return try roundTrip(MeshGeometryData(vertices: vertices, triangleIndices: indices))
    }

    private static func hollowSegment(
        from start: Vec3,
        to end: Vec3,
        innerRadius: Double,
        outerRadius: Double,
        sides: Int
    ) throws -> MeshGeometryData {
        let axis = normalize(subtract(end, start))
        return try revolvedHollow(
            origin: start, axis: axis,
            stations: [(0, outerRadius, innerRadius), (distance(start, end), outerRadius, innerRadius)],
            sides: sides
        )
    }

    private static func annularSegment(
        from start: Vec3,
        to end: Vec3,
        innerRadius: Double,
        outerRadius: Double,
        sides: Int
    ) throws -> MeshGeometryData {
        try hollowSegment(from: start, to: end, innerRadius: innerRadius, outerRadius: outerRadius, sides: sides)
    }

    private static func outwardTube(
        from point: Vec3,
        axis: Vec3,
        diameter: Double,
        parts: [MotherMoldPart],
        exteriorMargin: Double
    ) throws -> (solid: MeshGeometryData, inner: Vec3, outer: Vec3) {
        let inner = add(point, scale(axis, -0.5))
        let shellHigh = parts.flatMap { $0.geometry.vertices }.map { dot($0, axis) }.max() ?? dot(point, axis)
        let outer = add(point, scale(axis, max(exteriorMargin, shellHigh - dot(point, axis) + exteriorMargin)))
        return (
            try tubeBetween(inner, outer, lowerRadius: diameter / 2, upperRadius: diameter / 2, sides: 96),
            inner,
            outer
        )
    }

    private static func tubeBetween(
        _ start: Vec3,
        _ end: Vec3,
        lowerRadius: Double,
        upperRadius: Double,
        sides: Int
    ) throws -> MeshGeometryData {
        let length = distance(start, end)
        guard length > 1.0e-6 else { throw Error.invalidInput("flow solid has zero length") }
        return try tubeCentered(
            center: midpoint(start, end), axis: subtract(end, start), length: length,
            lowerRadius: lowerRadius, upperRadius: upperRadius, sides: sides
        )
    }

    private static func tubeCentered(
        center: Vec3,
        axis: Vec3,
        length: Double,
        lowerRadius: Double,
        upperRadius: Double,
        sides: Int
    ) throws -> MeshGeometryData {
        guard length > 0, lowerRadius > 0, upperRadius > 0, sides >= 8 else {
            throw Error.invalidInput("flow solid dimensions are invalid")
        }
        let direction = try unit(axis, label: "flow solid axis")
        let u = perpendicular(to: direction)
        let v = cross(direction, u)
        let low = add(center, scale(direction, -length / 2))
        let high = add(center, scale(direction, length / 2))
        var vertices: [Vec3] = []
        for index in 0..<sides {
            let angle = Double(index) * 2 * .pi / Double(sides)
            let radial = add(scale(u, cos(angle)), scale(v, sin(angle)))
            vertices.append(add(low, scale(radial, lowerRadius)))
        }
        for index in 0..<sides {
            let angle = Double(index) * 2 * .pi / Double(sides)
            let radial = add(scale(u, cos(angle)), scale(v, sin(angle)))
            vertices.append(add(high, scale(radial, upperRadius)))
        }
        vertices += [low, high]
        let lowCenter = Int32(sides * 2)
        let highCenter = lowCenter + 1
        var indices: [Int32] = []
        for index in 0..<sides {
            let next = (index + 1) % sides
            let lo = Int32(index), loNext = Int32(next)
            let hi = Int32(index + sides), hiNext = Int32(next + sides)
            indices += [lo, loNext, hi, loNext, hiNext, hi]
            indices += [lowCenter, loNext, lo]
            indices += [highCenter, hi, hiNext]
        }
        return try roundTrip(MeshGeometryData(vertices: vertices, triangleIndices: indices))
    }

    private static func roundTrip(_ geometry: MeshGeometryData) throws -> MeshGeometryData {
        let readback = try ManifoldEngine.toMesh(try ManifoldEngine.make(from: geometry))
        if MeshPreflight.analyze(geometry: readback).isWatertight {
            return readback
        }
        return try printableNormalizedSolid(readback, label: "round-tripped geometry")
    }

    private static func translated(_ geometry: MeshGeometryData, by offset: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.translate(
            try ManifoldEngine.make(from: geometry),
            x: offset.x, y: offset.y, z: offset.z
        ))
    }

    private static func unite(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.union(
            try ManifoldEngine.make(from: lhs), try ManifoldEngine.make(from: rhs)
        ))
    }

    private static func unionAll(_ geometries: [MeshGeometryData]) throws -> MeshGeometryData {
        guard !geometries.isEmpty else { throw Error.invalidInput("cannot union an empty geometry list") }
        let handles = try geometries.map { try ManifoldEngine.make(from: $0) }
        return try ManifoldEngine.toMesh(try ManifoldEngine.union(handles))
    }

    private static func subtract(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.difference(
            try ManifoldEngine.make(from: lhs), try ManifoldEngine.make(from: rhs)
        ))
    }

    private static func intersect(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.intersect(
            try ManifoldEngine.make(from: lhs), try ManifoldEngine.make(from: rhs)
        ))
    }

    private static func intersects(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) -> Bool {
        (try? intersectionVolume(lhs, rhs)) ?? 0 > geometryTolerance
    }

    private static func volume(_ geometry: MeshGeometryData) throws -> Double {
        abs(ManifoldEngine.volume(try ManifoldEngine.make(from: geometry)))
    }

    private static func intersectionVolume(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> Double {
        let result = try ManifoldEngine.intersect(try ManifoldEngine.make(from: lhs), try ManifoldEngine.make(from: rhs))
        return abs(ManifoldEngine.volume(result))
    }

    private static func differenceVolume(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> Double {
        let result = try ManifoldEngine.difference(try ManifoldEngine.make(from: lhs), try ManifoldEngine.make(from: rhs))
        return abs(ManifoldEngine.volume(result))
    }

    private static func projectionBounds(_ geometry: MeshGeometryData, axis: Vec3) -> (min: Double, max: Double) {
        let values = geometry.vertices.map { dot($0, axis) }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    private static func graph(_ geometry: MeshGeometryData) -> [[Int]] {
        var adjacency = Array(repeating: Set<Int>(), count: geometry.vertices.count)
        var index = 0
        while index + 2 < geometry.triangleIndices.count {
            let values = [Int(geometry.triangleIndices[index]), Int(geometry.triangleIndices[index + 1]), Int(geometry.triangleIndices[index + 2])]
            for lhs in values { for rhs in values where lhs != rhs { adjacency[lhs].insert(rhs) } }
            index += 3
        }
        return adjacency.map { $0.sorted() }
    }

    private static func highestPoint(in geometry: MeshGeometryData, along axis: Vec3) throws -> Vec3 {
        guard let value = geometry.vertices.enumerated().max(by: { lhs, rhs in
            let left = dot(lhs.element, axis), right = dot(rhs.element, axis)
            return left == right ? lhs.offset > rhs.offset : left < right
        })?.element else { throw Error.linerFillUnavailable("base liner has no vertices") }
        return value
    }

    private static func highCandidates(
        _ geometry: MeshGeometryData,
        axis: Vec3,
        excluding: [Vec3],
        seed: Int
    ) -> [Vec3] {
        let indexedHeights = geometry.vertices.enumerated().map { ($0.offset, $0.element, dot($0.element, axis)) }
        guard let minimum = indexedHeights.map(\.2).min(),
              let maximum = indexedHeights.map(\.2).max() else { return [] }
        let highBandDepth = max(2, (maximum - minimum) * 0.01)
        let ordered = indexedHeights.filter {
            $0.2 >= maximum - highBandDepth - 1.0e-9
        }.sorted {
            $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2
        }.map(\.1)
        guard !ordered.isEmpty else { return [] }
        let shift = abs(seed) % ordered.count
        let rotated = Array(ordered[shift...]) + Array(ordered[..<shift])
        return rotated.filter { candidate in excluding.allSatisfy { distance(candidate, $0) > 2 } }
    }

    private static func nearestVertex(to point: Vec3, in vertices: [Vec3]) -> Int {
        vertices.indices.min { lhs, rhs in
            let left = distance(vertices[lhs], point), right = distance(vertices[rhs], point)
            return left == right ? lhs < rhs : left < right
        } ?? 0
    }

    private static func modificationRegion(
        id: String,
        center: Vec3,
        axis: Vec3,
        footprintRadius: Double,
        purpose: String
    ) -> MasterModificationRegion {
        let sides = 64
        let direction = normalize(axis)
        let u = perpendicular(to: direction)
        let v = cross(direction, u)
        let boundary = (0..<sides).map { index -> Vec3Codable in
            let angle = Double(index) * 2 * .pi / Double(sides)
            return codable(add(
                center,
                add(
                    scale(u, cos(angle) * footprintRadius),
                    scale(v, sin(angle) * footprintRadius)
                )
            ))
        }
        let polygonArea = Double(sides) * footprintRadius * footprintRadius
            * sin(2 * .pi / Double(sides)) / 2
        return MasterModificationRegion(
            id: id,
            kind: .productionVentLanding,
            center: codable(center),
            surfaceArea: polygonArea,
            boundary: boundary,
            purpose: purpose
        )
    }

    private static func materialComponentCount(_ geometry: MeshGeometryData) -> Int {
        MoldComponentFilter.positiveMaterialComponentCount(geometry)
    }

    private static func triangleArea(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        length(cross(subtract(b, a), subtract(c, a))) / 2
    }

    private static func codable(_ value: Vec3) -> Vec3Codable {
        Vec3Codable(x: value.x, y: value.y, z: value.z)
    }

    private static func vec(_ value: Vec3Codable) -> Vec3 {
        Vec3(x: value.x, y: value.y, z: value.z)
    }

    private static func unit(_ value: Vec3, label: String) throws -> Vec3 {
        guard length(value) > 1.0e-9 else { throw Error.invalidInput("\(label) is zero") }
        return normalize(value)
    }

    private static func perpendicular(to axis: Vec3) -> Vec3 {
        let reference = abs(axis.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 0, y: 1, z: 0)
        return normalize(cross(axis, reference))
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
    private static func scale(_ value: Vec3, _ factor: Double) -> Vec3 { Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor) }
    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double { lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z }
    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.y * rhs.z - lhs.z * rhs.y, y: lhs.z * rhs.x - lhs.x * rhs.z, z: lhs.x * rhs.y - lhs.y * rhs.x) }
    private static func length(_ value: Vec3) -> Double { dot(value, value).squareRoot() }
    private static func normalize(_ value: Vec3) -> Vec3 { scale(value, 1 / length(value)) }
    private static func distance(_ lhs: Vec3, _ rhs: Vec3) -> Double { length(subtract(lhs, rhs)) }
    private static func midpoint(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { scale(add(lhs, rhs), 0.5) }
    private static func format(_ value: Double) -> String { String(format: "%.4f", value) }
}
