import Foundation

enum UndercutSplitPlanStatus: String, Codable, Equatable {
    case wholeModelWithinTolerance
    case splitWithinTolerance
    case splitExceedsTolerance
    case analysisError
}

enum UndercutCandidateRejectionReason: String, Codable, CaseIterable, Equatable {
    case doesNotSplitLeaf
    case minimumPieceVolume
    case crossesNoCutFace
    case minimumSeamArea
    case unrequestedDisconnectedFragments
    case childrenNotClosed
    case volumeConservation
}

struct UndercutCandidateRejection: Codable, Equatable {
    var reason: UndercutCandidateRejectionReason
    var targetRegionID: PartitionRegionID?
    var candidatePlane: CanonicalPlane?
    var detail: String

    init(
        reason: UndercutCandidateRejectionReason,
        targetRegionID: PartitionRegionID? = nil,
        candidatePlane: CanonicalPlane? = nil,
        detail: String = ""
    ) {
        self.reason = reason
        self.targetRegionID = targetRegionID
        self.candidatePlane = candidatePlane
        self.detail = detail
    }
}

struct UndercutAttributedRegion: Codable, Equatable {
    var id: String
    var measurementFaceIDs: [Int]
    var sourceFaceIDs: [SourceFaceID]
    var containsCutSurface: Bool
    var containsJoinerySurface: Bool
    var areaMM2: Double
    var depthMM: Double
    var centroid: Vec3
    var suggestedEscapeDirections: [Vec3]
}

struct UndercutSplitConservation: Codable, Equatable {
    enum Availability: String, Codable, Equatable {
        case unavailable
        case measured
    }

    var availability: Availability
    private var measuredMissingVolumeMM3: Double?
    private var measuredExcessVolumeMM3: Double?
    private var measuredPairwiseOverlapVolumeMM3: Double?
    private var measuredToleranceMM3: Double?

    var missingVolumeMM3: Double { measuredMissingVolumeMM3 ?? .nan }
    var excessVolumeMM3: Double { measuredExcessVolumeMM3 ?? .nan }
    var pairwiseOverlapVolumeMM3: Double { measuredPairwiseOverlapVolumeMM3 ?? .nan }
    var toleranceMM3: Double { measuredToleranceMM3 ?? .nan }

    init(
        missingVolumeMM3: Double,
        excessVolumeMM3: Double,
        pairwiseOverlapVolumeMM3: Double,
        toleranceMM3: Double
    ) {
        availability = .measured
        measuredMissingVolumeMM3 = missingVolumeMM3
        measuredExcessVolumeMM3 = excessVolumeMM3
        measuredPairwiseOverlapVolumeMM3 = pairwiseOverlapVolumeMM3
        measuredToleranceMM3 = toleranceMM3
    }

    private init(availability: Availability) {
        self.availability = availability
        measuredMissingVolumeMM3 = nil
        measuredExcessVolumeMM3 = nil
        measuredPairwiseOverlapVolumeMM3 = nil
        measuredToleranceMM3 = nil
    }

    static let unavailable = UndercutSplitConservation(availability: .unavailable)
}

struct UndercutSplitPiece: Codable, Equatable {
    var regionID: PartitionRegionID
    var mesh: AttributedMesh
    var pullAxis: Vec3
    var measurement: DirectionalAccessibilityAnalyzer.Result?
    var attributedRegions: [UndercutAttributedRegion]
    var draftAdvisoryAreaMM2: Double

    init(
        regionID: PartitionRegionID,
        mesh: AttributedMesh,
        pullAxis: Vec3,
        measurement: DirectionalAccessibilityAnalyzer.Result?,
        attributedRegions: [UndercutAttributedRegion] = [],
        draftAdvisoryAreaMM2: Double = 0
    ) {
        self.regionID = regionID
        self.mesh = mesh
        self.pullAxis = pullAxis
        self.measurement = measurement
        self.attributedRegions = attributedRegions
        self.draftAdvisoryAreaMM2 = draftAdvisoryAreaMM2
    }

    var volumeMM3: Double {
        abs(mesh.signedVolume)
    }

    var isOutwardOriented: Bool {
        mesh.signedVolume > UndercutSplitTolerancePolicy.current.absoluteVolumeMM3
    }
}

struct UndercutSplitObjective: Codable, Equatable {
    var exceedingPieceCount: Int
    var totalExcessDepthMM: Double
    var totalOverToleranceAreaMM2: Double
    var pieceCount: Int
    var sliverPenalty: Double
    var seamDetailPenalty: Double
    var totalSeamAreaMM2: Double
    var pieceVolumeVariance: Double
    var deterministicTieBreak: String

    func isBetter(
        than other: UndercutSplitObjective,
        priority: UndercutSplitPriority
    ) -> Bool {
        if exceedingPieceCount != other.exceedingPieceCount {
            return exceedingPieceCount < other.exceedingPieceCount
        }
        if totalExcessDepthMM != other.totalExcessDepthMM {
            return Self.ordered(totalExcessDepthMM) < Self.ordered(other.totalExcessDepthMM)
        }
        if totalOverToleranceAreaMM2 != other.totalOverToleranceAreaMM2 {
            return Self.ordered(totalOverToleranceAreaMM2)
                < Self.ordered(other.totalOverToleranceAreaMM2)
        }

        for key in Self.profileKeys(priority) {
            switch key {
            case .pieceCount:
                if pieceCount != other.pieceCount { return pieceCount < other.pieceCount }
            case .sliverPenalty:
                if sliverPenalty != other.sliverPenalty {
                    return Self.ordered(sliverPenalty) < Self.ordered(other.sliverPenalty)
                }
            case .seamDetailPenalty:
                if seamDetailPenalty != other.seamDetailPenalty {
                    return Self.ordered(seamDetailPenalty) < Self.ordered(other.seamDetailPenalty)
                }
            case .totalSeamArea:
                if totalSeamAreaMM2 != other.totalSeamAreaMM2 {
                    return Self.ordered(totalSeamAreaMM2) < Self.ordered(other.totalSeamAreaMM2)
                }
            case .pieceVolumeVariance:
                if pieceVolumeVariance != other.pieceVolumeVariance {
                    return Self.ordered(pieceVolumeVariance) < Self.ordered(other.pieceVolumeVariance)
                }
            }
        }

        return deterministicTieBreak < other.deterministicTieBreak
    }

    static func measurementKeys(
        measurements: [DirectionalAccessibilityAnalyzer.Result],
        toleranceMM: Double,
        minRegionAreaMM2: Double
    ) -> UndercutSplitObjective {
        let tolerance = toleranceMM.isFinite ? max(toleranceMM, 0) : 0
        let minimumArea = minRegionAreaMM2.isFinite ? max(minRegionAreaMM2, 0) : 0
        var exceedingPieceCount = 0
        var totalExcessDepthMM = 0.0
        var totalOverToleranceAreaMM2 = 0.0

        for measurement in measurements {
            var pieceExceeds = false
            for region in measurement.regions
            where region.depthMM.isFinite
                && region.areaMM2.isFinite
                && region.areaMM2 >= minimumArea
                && region.depthMM > tolerance {
                pieceExceeds = true
                totalExcessDepthMM += region.depthMM - tolerance
                totalOverToleranceAreaMM2 += region.areaMM2
            }
            if pieceExceeds { exceedingPieceCount += 1 }
        }

        return UndercutSplitObjective(
            exceedingPieceCount: exceedingPieceCount,
            totalExcessDepthMM: totalExcessDepthMM,
            totalOverToleranceAreaMM2: totalOverToleranceAreaMM2,
            pieceCount: measurements.count,
            sliverPenalty: 0,
            seamDetailPenalty: 0,
            totalSeamAreaMM2: 0,
            pieceVolumeVariance: 0,
            deterministicTieBreak: ""
        )
    }

    private enum ProfileKey {
        case pieceCount
        case sliverPenalty
        case seamDetailPenalty
        case totalSeamArea
        case pieceVolumeVariance
    }

    private static func profileKeys(_ priority: UndercutSplitPriority) -> [ProfileKey] {
        switch priority {
        case .fewerPieces:
            return [.pieceCount, .sliverPenalty, .seamDetailPenalty, .totalSeamArea, .pieceVolumeVariance]
        case .balanced:
            return [.sliverPenalty, .pieceCount, .seamDetailPenalty, .pieceVolumeVariance, .totalSeamArea]
        case .cleanerSeams:
            return [.seamDetailPenalty, .totalSeamArea, .sliverPenalty, .pieceCount, .pieceVolumeVariance]
        }
    }

    private static func ordered(_ value: Double) -> Double {
        value.isFinite ? value : Double.greatestFiniteMagnitude
    }
}

extension DirectionalAccessibilityAnalyzer.Result: @unchecked Sendable {}

actor UndercutSplitPlannerCache {
    struct Key: Hashable, @unchecked Sendable {
        let measurementGeometryFingerprint: String
        let pullAxis: Vec3
        let targetGridStepMM: Double?
        let gridDivisor: Double
        let refinementPasses: Int
        let maximumSamples: Int
        let linearWeldMM: Double
        let rayHitCoincidenceMM: Double
        let minimumTriangleAreaMM2: Double
        let draftAdvisoryDegrees: Double
        let plannerVersion: Int
        let tolerancePolicyVersion: Int

        init(
            measurementGeometryFingerprint: String,
            pullAxis: Vec3,
            configuration: DirectionalAccessibilityAnalyzer.Configuration,
            plannerVersion: Int,
            tolerancePolicyVersion: Int
        ) {
            self.measurementGeometryFingerprint = measurementGeometryFingerprint
            self.pullAxis = PullDirectionCandidates.canonicalized(pullAxis)
                ?? Vec3(x: 0, y: 0, z: 0)
            targetGridStepMM = configuration.targetGridStepMM
            gridDivisor = configuration.gridDivisor
            refinementPasses = configuration.refinementPasses
            maximumSamples = configuration.maximumSamples
            linearWeldMM = configuration.linearWeldMM
            rayHitCoincidenceMM = configuration.rayHitCoincidenceMM
            minimumTriangleAreaMM2 = configuration.minimumTriangleAreaMM2
            draftAdvisoryDegrees = configuration.draftAdvisoryDegrees
            self.plannerVersion = plannerVersion
            self.tolerancePolicyVersion = tolerancePolicyVersion
        }
    }

    struct Statistics: Equatable, Sendable {
        var hitCount: Int
        var missCount: Int
        var evictionCount: Int
    }

    private struct Entry {
        var value: DirectionalAccessibilityAnalyzer.Result
        var lastAccess: UInt64
    }

    private let maximumEntryCount: Int
    private var entries: [Key: Entry] = [:]
    private var accessClock: UInt64 = 0
    private var counters = Statistics(hitCount: 0, missCount: 0, evictionCount: 0)

    init(maximumEntryCount: Int = 256) {
        self.maximumEntryCount = max(maximumEntryCount, 1)
    }

    var entryCount: Int {
        entries.count
    }

    var statistics: Statistics {
        counters
    }

    func value(for key: Key) -> DirectionalAccessibilityAnalyzer.Result? {
        guard var entry = entries[key] else {
            counters.missCount += 1
            return nil
        }
        counters.hitCount += 1
        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.value
    }

    func insert(_ value: DirectionalAccessibilityAnalyzer.Result, for key: Key) {
        if entries[key] != nil {
            entries[key] = Entry(value: value, lastAccess: nextAccess())
            return
        }

        if entries.count >= maximumEntryCount,
           let leastRecentlyUsed = entries.min(by: {
               $0.value.lastAccess < $1.value.lastAccess
           })?.key {
            entries.removeValue(forKey: leastRecentlyUsed)
            counters.evictionCount += 1
        }
        entries[key] = Entry(value: value, lastAccess: nextAccess())
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        if accessClock == 0 { accessClock = 1 }
        return accessClock
    }
}

struct UndercutSplitAlternativeCandidate: Codable, Equatable {
    var priority: UndercutSplitPriority
    var cutTree: PartitionCutTree
    var objective: UndercutSplitObjective
    var deterministicFingerprint: String
}

struct UndercutPlaneRefinementStep: Equatable {
    var beforePlane: CanonicalPlane
    var afterPlane: CanonicalPlane
    var before: UndercutSplitObjective
    var after: UndercutSplitObjective
    var offsetStepMM: Double
    var angularStepRadians: Double
}

struct UndercutPlaneRefinementResult: Equatable {
    var plane: CanonicalPlane
    var objective: UndercutSplitObjective
    var acceptedSteps: [UndercutPlaneRefinementStep]
}

struct UndercutSplitFailurePresentation: Equatable {
    var status: UndercutSplitPlanStatus
    var measurementAttached: Bool
    var isExportable: Bool
    var message: String
}

struct UndercutSplitPlan: Codable, Equatable {
    var status: UndercutSplitPlanStatus
    var cutTree: PartitionCutTree
    var pieces: [UndercutSplitPiece]
    var statusMessage: String
    var candidateRejections: [UndercutCandidateRejection]
    var warnings: [String]
    var alternatives: [UndercutSplitAlternativeCandidate]
    var searchUsedProxy: Bool
    var searchTriangleCount: Int
    var sourceTriangleCount: Int
    var fullResolutionFinalized: Bool
    var finalMeasurementQuality: UndercutSearchQuality
    var manifoldCrossCheckPassed: Bool
    var crossCheckedCutCount: Int
    var conservation: UndercutSplitConservation
    var deterministicFingerprint: String

    init(
        status: UndercutSplitPlanStatus,
        cutTree: PartitionCutTree,
        pieces: [UndercutSplitPiece],
        statusMessage: String,
        candidateRejections: [UndercutCandidateRejection] = [],
        warnings: [String] = [],
        alternatives: [UndercutSplitAlternativeCandidate] = [],
        searchUsedProxy: Bool = false,
        searchTriangleCount: Int = 0,
        sourceTriangleCount: Int = 0,
        fullResolutionFinalized: Bool = false,
        finalMeasurementQuality: UndercutSearchQuality = .thorough,
        manifoldCrossCheckPassed: Bool = false,
        crossCheckedCutCount: Int = 0,
        conservation: UndercutSplitConservation = .unavailable,
        deterministicFingerprint: String = ""
    ) {
        self.status = status
        self.cutTree = cutTree
        self.pieces = pieces
        self.statusMessage = statusMessage
        self.candidateRejections = candidateRejections
        self.warnings = warnings
        self.alternatives = alternatives
        self.searchUsedProxy = searchUsedProxy
        self.searchTriangleCount = searchTriangleCount
        self.sourceTriangleCount = sourceTriangleCount
        self.fullResolutionFinalized = fullResolutionFinalized
        self.finalMeasurementQuality = finalMeasurementQuality
        self.manifoldCrossCheckPassed = manifoldCrossCheckPassed
        self.crossCheckedCutCount = crossCheckedCutCount
        self.conservation = conservation
        self.deterministicFingerprint = deterministicFingerprint
    }

    var isExportable: Bool {
        !pieces.isEmpty
    }

    var measurementAttached: Bool {
        !pieces.isEmpty && pieces.allSatisfy { $0.measurement != nil }
    }

    var worstMeasuredDepthMM: Double {
        pieces.compactMap { $0.measurement?.worstDepthMM }.max() ?? 0
    }

    var effectiveMeasurementResolutionMM: Double? {
        pieces.compactMap { $0.measurement?.effectiveResolutionMM }.max()
    }

    func fixtureGateLine(fileName: String, elapsedSeconds: Double) -> String {
        let resolution = effectiveMeasurementResolutionMM.map {
            String(format: "%.6g", $0)
        } ?? "unavailable"
        return "UNDERCUT_SPLIT_GATE"
            + " fixture=\(fileName)"
            + " status=\(status.rawValue)"
            + " pieces=\(pieces.count)"
            + " worstDepthMM=\(String(format: "%.6g", worstMeasuredDepthMM))"
            + " effectiveResolutionMM=\(resolution)"
            + " elapsedSeconds=\(String(format: "%.6g", elapsedSeconds))"
            + " fingerprint=\(deterministicFingerprint)"
    }
}

struct PartitionEffectiveSourceFingerprintCache {
    private var retainedGeometry: MeshGeometryData?
    private(set) var cachedFingerprint: String?
    private(set) var hitCount = 0
    private(set) var missCount = 0

    var entryCount: Int {
        retainedGeometry == nil ? 0 : 1
    }

    mutating func fingerprint(for geometry: MeshGeometryData) -> String {
        if let retainedGeometry,
           retainedGeometry == geometry,
           let cachedFingerprint {
            hitCount += 1
            return cachedFingerprint
        }

        let fingerprint = SourceFaceMap.geometryFingerprint(of: geometry)
        retainedGeometry = geometry
        cachedFingerprint = fingerprint
        missCount += 1
        return fingerprint
    }

    mutating func clear() {
        retainedGeometry = nil
        cachedFingerprint = nil
    }
}

extension PartitionInputSignature {
    init(effectiveSourceFingerprint: String, settings: PartitionSettings) {
        self.init(
            modelPath: "effective-source-fingerprint:\(effectiveSourceFingerprint)",
            modelTriangleCount: 0,
            modelBounds: nil,
            settings: settings
        )
    }
}

struct PartitionUndercutGenerationState {
    private(set) var plan: UndercutSplitPlan?
    private(set) var generatedSignature: PartitionInputSignature?
    private(set) var failureMessage: String?
    private var activeToken: UInt64?
    private var nextToken: UInt64 = 0

    init(
        plan: UndercutSplitPlan? = nil,
        generatedSignature: PartitionInputSignature? = nil
    ) {
        self.plan = plan
        self.generatedSignature = generatedSignature
    }

    var exportablePlan: UndercutSplitPlan? {
        guard let plan, plan.isExportable else { return nil }
        return plan
    }

    var isGenerating: Bool {
        activeToken != nil
    }

    func isStale(comparedWith currentSignature: PartitionInputSignature) -> Bool {
        guard plan != nil else { return false }
        return generatedSignature != currentSignature
    }

    func inspectablePlan(
        comparedWith currentSignature: PartitionInputSignature
    ) -> UndercutSplitPlan? {
        _ = currentSignature
        return plan
    }

    mutating func begin() -> UInt64 {
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        activeToken = nextToken
        failureMessage = nil
        return nextToken
    }

    mutating func cancel(token: UInt64) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    mutating func fail(message: String, token: UInt64) {
        guard activeToken == token else { return }
        activeToken = nil
        failureMessage = message
    }

    @discardableResult
    mutating func commit(
        _ newPlan: UndercutSplitPlan,
        signature: PartitionInputSignature,
        token: UInt64
    ) -> Bool {
        guard activeToken == token else { return false }
        plan = newPlan
        generatedSignature = signature
        failureMessage = nil
        activeToken = nil
        return true
    }
}

enum PartitionGenerationRoute: Equatable, Sendable {
    case fitPrinter
    case splitByUndercuts

    init(purpose: PartitionPurpose) {
        switch purpose {
        case .fitPrinter:
            self = .fitPrinter
        case .splitByUndercuts:
            self = .splitByUndercuts
        }
    }
}

enum PartitionGenerationCoordinator {
    static func run<T>(
        purpose: PartitionPurpose,
        fitPrinter: () async -> T,
        splitByUndercuts: () async -> T
    ) async -> T {
        switch PartitionGenerationRoute(purpose: purpose) {
        case .fitPrinter:
            return await fitPrinter()
        case .splitByUndercuts:
            return await splitByUndercuts()
        }
    }
}

enum UndercutSplitPlanner {
    enum Error: LocalizedError, Equatable {
        case cancelled
        case invalidMeasurementFaceIndex(Int)
        case planningFailed(stage: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Split-by-undercuts planning was cancelled."
            case .invalidMeasurementFaceIndex(let faceIndex):
                return "Undercut measurement face \(faceIndex) is absent from the attributed piece."
            case .planningFailed(let stage, let detail):
                return "Split-by-undercuts planning failed at \(stage): \(detail)"
            }
        }
    }

    struct CandidatePrefilterFacts: Equatable {
        var splitsLeaf: Bool
        var childVolumesMM3: [Double]
        var sourceVolumeMM3: Double
        var crossedNoCutSourceFaceIDs: [SourceFaceID]
        var seamAreaMM2: Double
        var inputComponentCount: Int
        var crossedInputComponentCount: Int
        var outputComponentCount: Int
        var childrenAreClosed: Bool
        var conservationMissingVolumeMM3: Double
        var conservationExcessVolumeMM3: Double
        var conservationToleranceMM3: Double
    }

    struct ComponentAdmission: Equatable {
        var macroscopicComponentIndices: [Int]
        var retainedMinorComponentIndices: [Int]
        var macroscopicVolumeFloorMM3: Double
        var blocksPlanning: Bool
    }

    enum SurfacedFailure: Equatable {
        case measurement(stage: String, pieceLabel: String)
        case fullResolutionFinalization(stage: String, detail: String)
        case planning(stage: String, detail: String)
    }

    typealias AlternativeCandidate = UndercutSplitAlternativeCandidate
    typealias PlaneRefinementStep = UndercutPlaneRefinementStep
    typealias PlaneRefinementResult = UndercutPlaneRefinementResult

    /// `sourcePreflight`: a topology report of `geometry` the caller already
    /// trusts for the open-boundary gate — the GUI passes the imported model's
    /// truthful, unit-independent report. nil (headless and every other
    /// caller) measures `MeshPreflight.analyze` here, exactly as before.
    static func plan(
        geometry: MeshGeometryData,
        settings: UndercutSplitSettings,
        sourcePreflight: MeshPreflightReport? = nil,
        cache: UndercutSplitPlannerCache = UndercutSplitPlannerCache(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) async throws -> UndercutSplitPlan {
        let perfStart = ProcessInfo.processInfo.systemUptime
        let searchDebug = ProcessInfo.processInfo.environment["UNDERCUT_SPLIT_SEARCH_DEBUG"] == "1"
        let debugMaximumPieces = ProcessInfo.processInfo.environment[
            "UNDERCUT_SPLIT_DEBUG_MAX_PIECES"
        ].flatMap(Int.init)
        let settings = settings.sanitized
        try checkCancellation(shouldCancel)

        let attributedSource: AttributedMesh
        do {
            attributedSource = try SourceFaceMap.attributedMesh(from: geometry)
        } catch {
            throw Error.planningFailed(
                stage: "source attribution",
                detail: error.localizedDescription
            )
        }
        let sourceFingerprint = attributedSource.sourceGeometryFingerprint
        let rootRegionID = PartitionRegionID.root(
            sourceGeometryFingerprint: sourceFingerprint
        )
        let emptyTree = PartitionCutTree(rootRegionID: rootRegionID, nodes: [])

        let preflight = sourcePreflight ?? MeshPreflight.analyze(geometry: geometry)
        let perfPreflight = ProcessInfo.processInfo.systemUptime
        guard preflight.boundaryEdgeCount == 0 else {
            return failurePlan(
                source: attributedSource,
                tree: emptyTree,
                settings: settings,
                message: "The source has \(preflight.boundaryEdgeCount) open boundary edges. "
                    + "Use Make Watertight, then plan the explicit healed source. "
                    + "The current source can still be exported."
            )
        }

        let sourceHandle: ManifoldHandle
        do {
            sourceHandle = try ManifoldEngine.make(from: geometry)
        } catch {
            return failurePlan(
                source: attributedSource,
                tree: emptyTree,
                settings: settings,
                message: "Analysis failed at closed-solid validation. "
                    + "The current source can still be exported. \(error.localizedDescription)"
            )
        }
        let perfSolid = ProcessInfo.processInfo.systemUptime
        try checkCancellation(shouldCancel)

        let admission = classifyInputComponents(
            signedVolumesMM3: signedComponentVolumes(geometry),
            settings: settings
        )
        if admission.blocksPlanning {
            return failurePlan(
                source: attributedSource,
                tree: emptyTree,
                settings: settings,
                message: "The source contains \(admission.macroscopicComponentIndices.count) "
                    + "separate macroscopic solids; separate the objects first. "
                    + "The current pieces can still be exported."
            )
        }
        let perfComponents = ProcessInfo.processInfo.systemUptime
        try checkCancellation(shouldCancel)

        do {
            if settings.planningMode == .manual,
               let envelope = settings.authoredCutTree {
                let validation = envelope.validateSourceBound(
                    source: attributedSource,
                    sourceGeometryFingerprint: sourceFingerprint,
                    faceConstraints: settings.faceConstraints,
                    lockedPullDirections: settings.lockedPullDirections,
                    maxPieces: settings.maxPieces
                )
                guard let replay = validation.replay,
                      let tree = envelope.typedTree else {
                    return failurePlan(
                        source: attributedSource,
                        tree: emptyTree,
                        settings: settings,
                        message: "The authored cut tree is quarantined: "
                            + validation.diagnostics.joined(separator: " ")
                            + " The current source can still be exported."
                    )
                }
                return try await finalize(
                    sourceGeometry: geometry,
                    attributedSource: attributedSource,
                    tree: tree,
                    searchLeaves: replay.leaves.map {
                        SearchLeaf(
                            regionID: $0.regionID,
                            mesh: $0.mesh,
                            pullAxis: settings.lockedPullDirections[$0.regionID]
                                ?? settings.fixedPullDirection
                                ?? Vec3(x: 0, y: 0, z: 1),
                            measurement: nil,
                            attributedRegions: []
                        )
                    },
                    settings: settings,
                    cache: cache,
                    searchUsedProxy: false,
                    searchTriangleCount: geometry.triangleIndices.count / 3,
                    candidateRejections: [],
                    warnings: validation.diagnostics,
                    alternatives: [],
                    shouldCancel: shouldCancel
                )
            }

            let proxy = try makeSearchProxy(
                geometry: geometry,
                sourceHandle: sourceHandle,
                settings: settings
            )
            let perfProxy = ProcessInfo.processInfo.systemUptime
            try checkCancellation(shouldCancel)
            var searchSource = try SourceFaceMap.attributedMesh(from: proxy.geometry)
            // Search geometry may be simplified, but cut-tree identity is always
            // bound to the effective full-resolution source.
            searchSource.sourceGeometryFingerprint = sourceFingerprint

            let primaryLeaf = try await evaluateLeaf(
                regionID: rootRegionID,
                mesh: searchSource,
                settings: settings,
                inheritedAxis: settings.fixedPullDirection ?? Vec3(x: 0, y: 0, z: 1),
                configuration: searchConfiguration(settings.quality, settings: settings),
                maximumDirectionCount: 1,
                cache: cache,
                shouldCancel: shouldCancel
            )
            let initialLeaf: SearchLeaf
            let primaryDepth = primaryLeaf.measurement?.worstDepthMM ?? .greatestFiniteMagnitude
            let skipBroadWholeModelDirections = settings.pullPolicy == .automatic
                && settings.maxPieces > 1
                && primaryDepth > max(settings.undercutToleranceMM * 4, 10)
            if settings.pullPolicy == .fixed
                || isWithinTolerance(primaryLeaf, settings: settings)
                || skipBroadWholeModelDirections {
                initialLeaf = primaryLeaf
            } else {
                initialLeaf = try await evaluateLeaf(
                    regionID: rootRegionID,
                    mesh: searchSource,
                    settings: settings,
                    inheritedAxis: primaryLeaf.pullAxis,
                    configuration: searchConfiguration(settings.quality, settings: settings),
                    maximumDirectionCount: initialDirectionCount(settings.quality),
                    cache: cache,
                    shouldCancel: shouldCancel
                )
            }
            let perfInitial = ProcessInfo.processInfo.systemUptime
            print("PLANNER PERF preflight=\(perfPreflight - perfStart) solid=\(perfSolid - perfPreflight) components=\(perfComponents - perfSolid) proxy=\(perfProxy - perfComponents) initial=\(perfInitial - perfProxy)")
            let initialState = SearchState(
                tree: emptyTree,
                leaves: [initialLeaf],
                objective: objective(
                    leaves: [initialLeaf],
                    tree: emptyTree,
                    settings: settings
                )
            )
            if searchDebug {
                print(
                    "UNDERCUT_SEARCH initial depth=\(initialLeaf.measurement?.worstDepthMM ?? .nan) "
                        + "axis=\(initialLeaf.pullAxis) regions=\(initialLeaf.measurement?.regions.map { ($0.depthMM, $0.areaMM2, $0.centroid) }.prefix(12) ?? [])"
                )
            }
            if initialState.objective.exceedingPieceCount == 0 {
                return try await finalize(
                    sourceGeometry: geometry,
                    attributedSource: attributedSource,
                    tree: emptyTree,
                    searchLeaves: initialState.leaves,
                    settings: settings,
                    cache: cache,
                    searchUsedProxy: proxy.used,
                    searchTriangleCount: proxy.geometry.triangleIndices.count / 3,
                    candidateRejections: [],
                    warnings: [],
                    alternatives: [],
                    shouldCancel: shouldCancel
                )
            }

            // Iterative worst-leaf resolution (§6.7 as amended 2026-07-13).
            // Candidates are ranked by minimax measured child depth — never by
            // the final lexicographic objective, whose failing-piece count is
            // not monotone under further cuts and starves the search into
            // sliver peels. A cut is applied only when it improves the target
            // leaf's depth by more than the measurement quantum; presentation
            // keeps whichever constructed state measures best.
            var allRejections: [UndercutCandidateRejection] = []
            var currentTree = emptyTree
            var leaves: [SearchLeaf] = [initialLeaf]
            var unresolvable = Set<PartitionRegionID>()
            let maximumPieces = debugMaximumPieces.map {
                min(max($0, 1), settings.maxPieces)
            } ?? settings.maxPieces

            func stateNow() -> SearchState {
                SearchState(
                    tree: currentTree,
                    leaves: leaves,
                    objective: objective(leaves: leaves, tree: currentTree, settings: settings)
                )
            }
            func worstMeasuredDepth(_ state: SearchState) -> Double {
                state.leaves.compactMap { $0.measurement?.worstDepthMM }.max()
                    ?? .greatestFiniteMagnitude
            }
            // Fully-passing states rank by the §6.7 objective. When nothing
            // fully passes, the user-meaningful ordering is the smallest worst
            // piece depth: an honest 13-piece near-miss beats an uncut model
            // that "fails less often" by key 1.
            func presentationBetter(_ lhs: SearchState, _ rhs: SearchState) -> Bool {
                let lhsSolved = lhs.objective.exceedingPieceCount == 0
                let rhsSolved = rhs.objective.exceedingPieceCount == 0
                if lhsSolved != rhsSolved { return lhsSolved }
                if lhsSolved {
                    return lhs.objective.isBetter(than: rhs.objective, priority: settings.priority)
                }
                let lhsDepth = worstMeasuredDepth(lhs)
                let rhsDepth = worstMeasuredDepth(rhs)
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.objective.isBetter(than: rhs.objective, priority: settings.priority)
            }

            var best = initialState
            while leaves.count < maximumPieces {
                try checkCancellation(shouldCancel)
                let resolvableLeaves = leaves.filter {
                    !isWithinTolerance($0, settings: settings)
                        && !unresolvable.contains($0.regionID)
                }
                guard let target = worstLeaf(in: resolvableLeaves, settings: settings) else { break }
                let targetFacts = worstLeafFacts(target, settings: settings)
                let escapeHints: [Vec3] = Array(
                    (target.measurement?.regions ?? [])
                        .filter {
                            $0.areaMM2 >= settings.minRegionAreaMM2
                                && $0.depthMM > settings.undercutToleranceMM
                        }
                        .sorted {
                            if $0.depthMM != $1.depthMM { return $0.depthMM > $1.depthMM }
                            return $0.id < $1.id
                        }
                        .prefix(3)
                        .flatMap { $0.suggestedEscapeDirections.prefix(2) }
                )
                let proposals = dedupedProposals(
                    regionGuidedPlanes(for: target, settings: settings)
                        + proposedPlanes(
                            for: target,
                            settings: settings,
                            sourceVertices: attributedSource.sourceReferencedVertices
                        )
                )
                if searchDebug {
                    print(
                        "UNDERCUT_SEARCH target=\(target.regionID.rawValue) depth=\(targetFacts.depth) "
                            + "axis=\(target.pullAxis) proposals=\(proposals.count) pieces=\(leaves.count)"
                    )
                }
                let prepared = prepareSplitCandidates(
                    proposals: proposals,
                    target: target,
                    state: stateNow(),
                    sourceVolumeMM3: abs(attributedSource.signedVolume),
                    settings: settings,
                    preferManifold: proxy.used,
                    desiredCount: preparedCandidateBudget(settings.quality),
                    rejections: &allRejections
                )
                var bestCut: (
                    candidate: PreparedSplitCandidate,
                    negative: SearchLeaf,
                    positive: SearchLeaf,
                    worstChildDepth: Double
                )?
                var solvingCuts: [(
                    candidate: PreparedSplitCandidate,
                    negative: SearchLeaf,
                    positive: SearchLeaf
                )] = []
                for candidate in prepared {
                    try checkCancellation(shouldCancel)
                    do {
                        let negative = try await evaluateSearchChild(
                            regionID: candidate.node.negativeChildID,
                            mesh: candidate.negative,
                            settings: settings,
                            inheritedAxis: candidate.node.plane.normal,
                            escapeHints: escapeHints,
                            cache: cache,
                            shouldCancel: shouldCancel
                        )
                        let positive = try await evaluateSearchChild(
                            regionID: candidate.node.positiveChildID,
                            mesh: candidate.positive,
                            settings: settings,
                            inheritedAxis: candidate.node.plane.normal,
                            escapeHints: escapeHints,
                            cache: cache,
                            shouldCancel: shouldCancel
                        )
                        let worstChildDepth = max(
                            worstLeafFacts(negative, settings: settings).depth,
                            worstLeafFacts(positive, settings: settings).depth
                        )
                        if searchDebug {
                            print(
                                "UNDERCUT_SEARCH candidate plane=(\(candidate.node.plane.normal), "
                                    + "\(candidate.node.plane.offset)) worstChild=\(worstChildDepth)"
                            )
                        }
                        if bestCut == nil || worstChildDepth < bestCut!.worstChildDepth {
                            bestCut = (candidate, negative, positive, worstChildDepth)
                        }
                        if isWithinTolerance(negative, settings: settings),
                           isWithinTolerance(positive, settings: settings) {
                            solvingCuts.append((candidate, negative, positive))
                            // A few complete solutions are enough for the
                            // objective to choose between; further candidates
                            // only spend budget.
                            if solvingCuts.count >= 3 { break }
                        }
                    } catch Error.cancelled {
                        throw Error.cancelled
                    } catch {
                        allRejections.append(UndercutCandidateRejection(
                            reason: .childrenNotClosed,
                            targetRegionID: target.regionID,
                            candidatePlane: candidate.node.plane,
                            detail: "Child measurement failed: \(error.localizedDescription)"
                        ))
                    }
                }

                func appliedState(
                    _ node: PartitionCutNode,
                    _ negative: SearchLeaf,
                    _ positive: SearchLeaf
                ) -> SearchState {
                    var nodes = currentTree.nodes + [node]
                    nodes = depthFirstNodes(nodes, rootRegionID: currentTree.rootRegionID)
                    let tree = PartitionCutTree(
                        rootRegionID: currentTree.rootRegionID,
                        nodes: nodes
                    )
                    var nextLeaves = leaves.filter { $0.regionID != target.regionID }
                    nextLeaves.append(negative)
                    nextLeaves.append(positive)
                    nextLeaves.sort { $0.regionID < $1.regionID }
                    return SearchState(
                        tree: tree,
                        leaves: nextLeaves,
                        objective: objective(leaves: nextLeaves, tree: tree, settings: settings)
                    )
                }

                let chosen: (
                    candidate: PreparedSplitCandidate,
                    negative: SearchLeaf,
                    positive: SearchLeaf
                )?
                if !solvingCuts.isEmpty {
                    // Several cuts fully solve this leaf: the §6.7 objective
                    // (volume balance, seam quality, deterministic tie-break)
                    // chooses among complete solutions — first-found order
                    // must not decide geometry.
                    chosen = solvingCuts.min { lhs, rhs in
                        let lhsState = appliedState(lhs.candidate.node, lhs.negative, lhs.positive)
                        let rhsState = appliedState(rhs.candidate.node, rhs.negative, rhs.positive)
                        if lhsState.objective.isBetter(
                            than: rhsState.objective,
                            priority: settings.priority
                        ) { return true }
                        if rhsState.objective.isBetter(
                            than: lhsState.objective,
                            priority: settings.priority
                        ) { return false }
                        return treeFingerprint(lhsState.tree) < treeFingerprint(rhsState.tree)
                    }
                } else {
                    let minimumProgressMM = max(
                        0.1,
                        target.measurement?.effectiveResolutionMM ?? 0.1
                    )
                    if let bestCut,
                       bestCut.worstChildDepth + minimumProgressMM <= targetFacts.depth {
                        chosen = (bestCut.candidate, bestCut.negative, bestCut.positive)
                    } else {
                        chosen = nil
                    }
                }
                guard let chosen else {
                    unresolvable.insert(target.regionID)
                    if searchDebug {
                        print(
                            "UNDERCUT_SEARCH leaf \(target.regionID.rawValue) "
                                + "unresolvable at depth \(targetFacts.depth)"
                        )
                    }
                    continue
                }
                let state = appliedState(chosen.candidate.node, chosen.negative, chosen.positive)
                currentTree = state.tree
                leaves = state.leaves
                if presentationBetter(state, best) { best = state }
                if searchDebug {
                    print(
                        "UNDERCUT_SEARCH applied nodes=\(currentTree.nodes.count) "
                            + "worstDepth=\(worstMeasuredDepth(state)) "
                            + "objective=(\(state.objective.exceedingPieceCount),\(state.objective.totalExcessDepthMM))"
                    )
                }
                if state.objective.exceedingPieceCount == 0 { break }
            }
            let finalState = stateNow()
            if presentationBetter(finalState, best) { best = finalState }
            let winner = best
            if searchDebug {
                print(
                    "UNDERCUT_SEARCH winner nodes=\(winner.tree.nodes.count) objective=(\(winner.objective.exceedingPieceCount),\(winner.objective.totalExcessDepthMM),\(winner.objective.totalOverToleranceAreaMM2))"
                )
            }
            if ProcessInfo.processInfo.environment[
                "UNDERCUT_SPLIT_DEBUG_STOP_AFTER_SEARCH"
            ] == "1" {
                throw Error.cancelled
            }
            var warnings: [String] = []
            if allRejections.contains(where: { $0.reason == .crossesNoCutFace }) {
                warnings.append(
                    "One or more candidate seams crossed no-cut paint and were rejected."
                )
            }
            let alternatives = selectAlternatives([], maximumCount: 3)
            return try await finalize(
                sourceGeometry: geometry,
                attributedSource: attributedSource,
                tree: winner.tree,
                searchLeaves: winner.leaves,
                settings: settings,
                cache: cache,
                searchUsedProxy: proxy.used,
                searchTriangleCount: proxy.geometry.triangleIndices.count / 3,
                candidateRejections: deduplicatedRejections(allRejections),
                warnings: warnings,
                alternatives: alternatives,
                shouldCancel: shouldCancel
            )
        } catch Error.cancelled {
            throw Error.cancelled
        } catch DirectionalAccessibilityAnalyzer.AnalysisError.cancelled {
            throw Error.cancelled
        } catch {
            return failurePlan(
                source: attributedSource,
                tree: emptyTree,
                settings: settings,
                message: failurePresentation(
                    .planning(stage: "search", detail: error.localizedDescription)
                ).message
            )
        }
    }

    private struct SearchProxy {
        var geometry: MeshGeometryData
        var used: Bool
    }

    private struct SearchLeaf {
        var regionID: PartitionRegionID
        var mesh: AttributedMesh
        var pullAxis: Vec3
        var measurement: DirectionalAccessibilityAnalyzer.Result?
        var attributedRegions: [UndercutAttributedRegion]
    }

    private struct SearchState {
        var tree: PartitionCutTree
        var leaves: [SearchLeaf]
        var objective: UndercutSplitObjective
    }

    private struct PreparedSplitCandidate {
        var node: PartitionCutNode
        var negative: AttributedMesh
        var positive: AttributedMesh
        var seamAreaMM2: Double
        var heuristic: Double
    }

    private static func checkCancellation(
        _ shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw Error.cancelled }
    }

    private static func failurePlan(
        source: AttributedMesh,
        tree: PartitionCutTree,
        settings: UndercutSplitSettings,
        message: String
    ) -> UndercutSplitPlan {
        let axis = settings.fixedPullDirection ?? Vec3(x: 0, y: 0, z: 1)
        let piece = UndercutSplitPiece(
            regionID: tree.rootRegionID,
            mesh: source,
            pullAxis: axis,
            measurement: nil
        )
        var plan = UndercutSplitPlan(
            status: .analysisError,
            cutTree: tree,
            pieces: [piece],
            statusMessage: message,
            sourceTriangleCount: source.triangles.count,
            conservation: .unavailable
        )
        plan.deterministicFingerprint = planFingerprint(plan)
        return plan
    }

    private static func makeSearchProxy(
        geometry: MeshGeometryData,
        sourceHandle: ManifoldHandle,
        settings: UndercutSplitSettings
    ) throws -> SearchProxy {
        let sourceTriangleCount = geometry.triangleIndices.count / 3
        // Painted source-face constraints cannot be transferred to a simplified
        // proxy without losing their durable IDs, so those runs search the source.
        guard settings.faceConstraints.noCutSourceFaceIDs.isEmpty,
              settings.faceConstraints.preferredSeamFaces.isEmpty,
              sourceTriangleCount > 8_000 else {
            return SearchProxy(geometry: geometry, used: false)
        }

        let normalizedTriangleCount = ManifoldEngine.triangleCount(sourceHandle)
        if normalizedTriangleCount <= 12_000,
           let normalized = try? ManifoldEngine.toMesh(sourceHandle),
           normalized.triangleIndices.count / 3 < sourceTriangleCount {
            return SearchProxy(geometry: normalized, used: true)
        }
        let bounds = ManifoldEngine.bounds(sourceHandle)
        let diagonal = distance(bounds.min, bounds.max)
        let tolerance = max(diagonal / 256, 0.05)
        guard let simplified = try? ManifoldEngine.simplify(
            sourceHandle,
            tolerance: tolerance
        ), ManifoldEngine.triangleCount(simplified) < sourceTriangleCount else {
            return SearchProxy(geometry: geometry, used: false)
        }
        return SearchProxy(geometry: try ManifoldEngine.toMesh(simplified), used: true)
    }

    private static func searchConfiguration(
        _ quality: UndercutSearchQuality,
        settings: UndercutSplitSettings
    ) -> DirectionalAccessibilityAnalyzer.Configuration {
        // Internal proposal-ranking prepass only. Its results choose which
        // scoped tree to replay; every finalist is remeasured with the exact
        // Thorough §4.2 configuration before any user-visible status is set.
        let step: Double
        let maximumSamples: Int
        switch quality {
        case .quick:
            step = 2
            maximumSamples = 30_000
        case .standard:
            step = 2
            maximumSamples = 40_000
        case .thorough:
            step = 1
            maximumSamples = 80_000
        }
        let policy = UndercutSplitTolerancePolicy.current
        return DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: step,
            gridDivisor: 128,
            refinementPasses: 0,
            maximumSamples: maximumSamples,
            linearWeldMM: policy.linearWeldMM,
            rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: settings.draftAdvisoryDegrees
        )
    }

    private static func initialDirectionCount(_ quality: UndercutSearchQuality) -> Int {
        switch quality {
        case .quick: return 10
        case .standard: return 18
        case .thorough: return 28
        }
    }

    private static func childDirectionCount(_ quality: UndercutSearchQuality) -> Int {
        // Wide enough to find the oblique per-piece axes the §11.3 fixtures
        // require (measured: hand lobes pass only on axes the old 3/4/6
        // budgets never reached). `evaluateLeaf` early-exits on the first
        // within-tolerance direction, so passing children stay cheap.
        switch quality {
        case .quick: return 8
        case .standard: return 14
        case .thorough: return 20
        }
    }


    private static func expansionCount(_ quality: UndercutSearchQuality) -> Int {
        switch quality {
        case .quick: return 2
        case .standard: return 3
        case .thorough: return 3
        }
    }


    private static func planeBudget(_ quality: UndercutSearchQuality) -> Int {
        switch quality {
        case .quick: return 16
        case .standard: return 32
        case .thorough: return 64
        }
    }

    private static func icosphereVertexCount(_ quality: UndercutSearchQuality) -> Int {
        switch quality {
        case .quick: return 42
        case .standard: return 162
        case .thorough: return 642
        }
    }

    private static func evaluateSearchChild(
        regionID: PartitionRegionID,
        mesh: AttributedMesh,
        settings: UndercutSplitSettings,
        inheritedAxis: Vec3,
        escapeHints: [Vec3] = [],
        cache: UndercutSplitPlannerCache,
        shouldCancel: @Sendable () -> Bool
    ) async throws -> SearchLeaf {
        let configuration = searchConfiguration(settings.quality, settings: settings)
        let primary = try await evaluateLeaf(
            regionID: regionID,
            mesh: mesh,
            settings: settings,
            inheritedAxis: inheritedAxis,
            escapeHints: escapeHints,
            configuration: configuration,
            maximumDirectionCount: 1,
            cache: cache,
            shouldCancel: shouldCancel
        )
        if settings.pullPolicy == .fixed || isWithinTolerance(primary, settings: settings) {
            return primary
        }
        return try await evaluateLeaf(
            regionID: regionID,
            mesh: mesh,
            settings: settings,
            inheritedAxis: primary.pullAxis,
            escapeHints: escapeHints,
            configuration: configuration,
            maximumDirectionCount: childDirectionCount(settings.quality),
            cache: cache,
            shouldCancel: shouldCancel
        )
    }

    private static func evaluateLeaf(
        regionID: PartitionRegionID,
        mesh: AttributedMesh,
        settings: UndercutSplitSettings,
        inheritedAxis: Vec3?,
        escapeHints: [Vec3] = [],
        configuration: DirectionalAccessibilityAnalyzer.Configuration,
        maximumDirectionCount: Int,
        cache: UndercutSplitPlannerCache,
        shouldCancel: @Sendable () -> Bool
    ) async throws -> SearchLeaf {
        let directions = rankedDirections(
            geometry: mesh.geometry,
            regionID: regionID,
            settings: settings,
            inheritedAxis: inheritedAxis,
            escapeHints: escapeHints,
            hasPriorCutSurface: mesh.triangles.contains { triangle in
                if case .cut = triangle.provenance { return true }
                return false
            },
            maximumCount: maximumDirectionCount
        )
        guard !directions.isEmpty else {
            throw Error.planningFailed(
                stage: "pull-direction generation",
                detail: "No finite nonzero pull direction was available for \(regionID.rawValue)."
            )
        }

        var best: (axis: Vec3, result: DirectionalAccessibilityAnalyzer.Result)?
        var lastMeasurementError: Swift.Error?
        for direction in directions {
            try checkCancellation(shouldCancel)
            let result: DirectionalAccessibilityAnalyzer.Result
            do {
                result = try await measurement(
                    mesh: mesh,
                    direction: direction,
                    configuration: configuration,
                    settings: settings,
                    cache: cache,
                    shouldCancel: shouldCancel
                )
            } catch Error.cancelled {
                throw Error.cancelled
            } catch {
                lastMeasurementError = error
                continue
            }
            if result.status(
                toleranceMM: settings.undercutToleranceMM,
                minRegionAreaMM2: settings.minRegionAreaMM2
            ) == .withinTolerance {
                return SearchLeaf(
                    regionID: regionID,
                    mesh: mesh,
                    pullAxis: direction,
                    measurement: result,
                    attributedRegions: try remapMeasurementRegions(result, on: mesh)
                )
            }
            if let current = best {
                let candidateObjective = UndercutSplitObjective.measurementKeys(
                    measurements: [result],
                    toleranceMM: settings.undercutToleranceMM,
                    minRegionAreaMM2: settings.minRegionAreaMM2
                )
                let currentObjective = UndercutSplitObjective.measurementKeys(
                    measurements: [current.result],
                    toleranceMM: settings.undercutToleranceMM,
                    minRegionAreaMM2: settings.minRegionAreaMM2
                )
                if candidateObjective.isBetter(
                    than: currentObjective,
                    priority: settings.priority
                ) {
                    best = (direction, result)
                }
            } else {
                best = (direction, result)
            }
        }
        guard let best else {
            throw Error.planningFailed(
                stage: "directional accessibility",
                detail: "No pull direction could be measured for \(regionID.rawValue). "
                    + (lastMeasurementError?.localizedDescription ?? "")
            )
        }
        return SearchLeaf(
            regionID: regionID,
            mesh: mesh,
            pullAxis: best.axis,
            measurement: best.result,
            attributedRegions: try remapMeasurementRegions(best.result, on: mesh)
        )
    }

    private static func measurement(
        mesh: AttributedMesh,
        direction: Vec3,
        configuration: DirectionalAccessibilityAnalyzer.Configuration,
        settings: UndercutSplitSettings,
        cache: UndercutSplitPlannerCache,
        shouldCancel: @Sendable () -> Bool
    ) async throws -> DirectionalAccessibilityAnalyzer.Result {
        let key = UndercutSplitPlannerCache.Key(
            measurementGeometryFingerprint: mesh.stableFingerprint,
            pullAxis: direction,
            configuration: configuration,
            plannerVersion: settings.plannerVersion,
            tolerancePolicyVersion: settings.tolerancePolicyVersion
        )
        if let cached = await cache.value(for: key) { return cached }
        let result: DirectionalAccessibilityAnalyzer.Result
        do {
            result = try DirectionalAccessibilityAnalyzer.analyze(
                geometry: mesh.geometry,
                pullAxis: direction,
                configuration: configuration,
                shouldCancel: shouldCancel
            )
        } catch DirectionalAccessibilityAnalyzer.AnalysisError.cancelled {
            throw Error.cancelled
        }
        await cache.insert(result, for: key)
        return result
    }

    static func rankedDirections(
        geometry: MeshGeometryData,
        regionID: PartitionRegionID,
        settings: UndercutSplitSettings,
        inheritedAxis: Vec3?,
        escapeHints: [Vec3] = [],
        hasPriorCutSurface: Bool,
        maximumCount: Int
    ) -> [Vec3] {
        if let locked = settings.lockedPullDirections[regionID],
           let direction = PullDirectionCandidates.canonicalized(locked) {
            return [direction]
        }
        if settings.pullPolicy == .fixed {
            return [PullDirectionCandidates.canonicalized(
                settings.fixedPullDirection ?? Vec3(x: 0, y: 0, z: 1)
            ) ?? Vec3(x: 0, y: 0, z: 1)]
        }

        let generated = PullDirectionCandidates.generate(
            geometry: geometry,
            icosphereVertexCount: icosphereVertexCount(settings.quality),
            fixedAxis: settings.fixedPullDirection,
            lockedAxes: Array(settings.lockedPullDirections.values)
        )
        var result: [Vec3] = []
        func append(_ raw: Vec3?) {
            guard let raw,
                  let direction = PullDirectionCandidates.canonicalized(raw),
                  !result.contains(where: { axesEquivalent($0, direction) }) else { return }
            result.append(direction)
        }
        append(inheritedAxis)
        if maximumCount == 1, !result.isEmpty { return Array(result.prefix(1)) }
        // Measured escape directions of the parent's undercut regions: the
        // §11.3 fixtures pass on oblique axes that only these hints reach
        // within the direction budget.
        for hint in escapeHints { append(hint) }

        let ranked = generated.map { direction in
            (direction: direction, area: projectedBoundingArea(geometry.vertices, axis: direction))
        }.sorted { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return directionLessThan(lhs.direction, rhs.direction)
        }
        // Once a leaf has a cut cap, its inherited axis alone is often a poor
        // proxy for the remaining anatomical lobe. Spend the next bounded
        // measurement on the leaf's smallest-projection generated direction
        // before the conventional world axes.
        if hasPriorCutSurface {
            for candidate in ranked {
                let countBefore = result.count
                append(candidate.direction)
                if result.count > countBefore { break }
            }
        }
        // +Z is Refab Artist's conventional first automatic pull direction and is
        // especially effective for open-back mask and shell workflows.
        append(Vec3(x: 0, y: 0, z: 1))
        append(Vec3(x: 1, y: 0, z: 0))
        append(Vec3(x: 0, y: 1, z: 0))

        for candidate in ranked { append(candidate.direction) }

        // Preserve a deterministic spread across the sphere even when the
        // projected-bounds heuristic favors one neighborhood.
        let spreadCount = min(6, generated.count)
        if spreadCount > 1 {
            for index in 0..<spreadCount {
                let sourceIndex = index * (generated.count - 1) / (spreadCount - 1)
                append(generated[sourceIndex])
            }
        }
        return Array(result.prefix(max(maximumCount, 1)))
    }

    private static func projectedBoundingArea(_ vertices: [Vec3], axis: Vec3) -> Double {
        guard let basis = tangentBasis(for: axis), let first = vertices.first else {
            return .greatestFiniteMagnitude
        }
        var minimumU = dot(first, basis.0)
        var maximumU = minimumU
        var minimumV = dot(first, basis.1)
        var maximumV = minimumV
        for vertex in vertices.dropFirst() {
            let u = dot(vertex, basis.0)
            let v = dot(vertex, basis.1)
            minimumU = min(minimumU, u)
            maximumU = max(maximumU, u)
            minimumV = min(minimumV, v)
            maximumV = max(maximumV, v)
        }
        let area = max(0, maximumU - minimumU) * max(0, maximumV - minimumV)
        return area.isFinite ? area : .greatestFiniteMagnitude
    }

    private static func objective(
        leaves: [SearchLeaf],
        tree: PartitionCutTree,
        settings: UndercutSplitSettings
    ) -> UndercutSplitObjective {
        let measurements = leaves.compactMap(\.measurement)
        var result = UndercutSplitObjective.measurementKeys(
            measurements: measurements,
            toleranceMM: settings.undercutToleranceMM,
            minRegionAreaMM2: settings.minRegionAreaMM2
        )
        result.pieceCount = leaves.count
        let sourceVolume = leaves.map { abs($0.mesh.signedVolume) }.reduce(0, +)
        let minimumVolume = max(
            settings.minimumPieceVolumeMM3,
            sourceVolume * settings.minimumPieceVolumeFraction
        )
        result.sliverPenalty = leaves.reduce(0) {
            $0 + max(0, minimumVolume - abs($1.mesh.signedVolume))
        }
        result.seamDetailPenalty = 0
        let capArea = leaves.reduce(0.0) { total, leaf in
            total + leaf.mesh.surfaceArea { provenance in
                if case .cut = provenance { return true }
                return false
            }
        }
        result.totalSeamAreaMM2 = capArea / 2
        let volumes = leaves.map { abs($0.mesh.signedVolume) }
        let mean = volumes.isEmpty ? 0 : volumes.reduce(0, +) / Double(volumes.count)
        result.pieceVolumeVariance = volumes.reduce(0) {
            let delta = $1 - mean
            return $0 + delta * delta
        } / Double(max(volumes.count, 1))
        var hasher = PartitionStableHasher()
        hasher.append("undercut-search-state-v1")
        hasher.append(settings.seed)
        hasher.append(treeFingerprint(tree))
        for leaf in leaves.sorted(by: { $0.regionID < $1.regionID }) {
            hasher.append(leaf.regionID.rawValue)
            hasher.append(leaf.pullAxis)
            hasher.append(leaf.mesh.stableFingerprint)
        }
        result.deterministicTieBreak = hasher.finalized
        return result
    }

    private static func worstLeaf(
        in leaves: [SearchLeaf],
        settings: UndercutSplitSettings
    ) -> SearchLeaf? {
        leaves.filter { leaf in
            leaf.measurement?.status(
                toleranceMM: settings.undercutToleranceMM,
                minRegionAreaMM2: settings.minRegionAreaMM2
            ) == .exceedsTolerance
        }.sorted { lhs, rhs in
            let lhsFacts = worstLeafFacts(lhs, settings: settings)
            let rhsFacts = worstLeafFacts(rhs, settings: settings)
            if lhsFacts.depth != rhsFacts.depth { return lhsFacts.depth > rhsFacts.depth }
            if lhsFacts.area != rhsFacts.area { return lhsFacts.area > rhsFacts.area }
            if lhsFacts.regionCount != rhsFacts.regionCount {
                return lhsFacts.regionCount > rhsFacts.regionCount
            }
            if lhsFacts.volume != rhsFacts.volume { return lhsFacts.volume > rhsFacts.volume }
            return lhs.regionID < rhs.regionID
        }.first
    }

    private static func isWithinTolerance(
        _ leaf: SearchLeaf,
        settings: UndercutSplitSettings
    ) -> Bool {
        leaf.measurement?.status(
            toleranceMM: settings.undercutToleranceMM,
            minRegionAreaMM2: settings.minRegionAreaMM2
        ) == .withinTolerance
    }


    private static func worstLeafFacts(
        _ leaf: SearchLeaf,
        settings: UndercutSplitSettings
    ) -> (depth: Double, area: Double, regionCount: Int, volume: Double) {
        let regions = leaf.measurement?.regions.filter {
            $0.areaMM2 >= settings.minRegionAreaMM2
                && $0.depthMM > settings.undercutToleranceMM
        } ?? []
        return (
            regions.map(\.depthMM).max() ?? 0,
            regions.map(\.areaMM2).reduce(0, +),
            regions.count,
            abs(leaf.mesh.signedVolume)
        )
    }

    private static func proposedPlanes(
        for target: SearchLeaf,
        settings: UndercutSplitSettings,
        sourceVertices: [Vec3]
    ) -> [CanonicalPlane] {
        let geometry = target.mesh.geometry
        var normals: [Vec3] = []
        func appendNormal(_ raw: Vec3) {
            guard let normal = PullDirectionCandidates.canonicalized(raw),
                  !normals.contains(where: { axesEquivalent($0, normal) }) else { return }
            normals.append(normal)
        }
        appendNormal(Vec3(x: 1, y: 0, z: 0))
        appendNormal(Vec3(x: 0, y: 1, z: 0))
        appendNormal(Vec3(x: 0, y: 0, z: 1))
        appendNormal(target.pullAxis)
        for region in target.measurement?.regions ?? [] {
            for direction in region.suggestedEscapeDirections { appendNormal(direction) }
        }
        let derived = PullDirectionCandidates.generate(
            geometry: geometry,
            icosphereVertexCount: 42
        ).map { direction in
            (direction: direction, area: projectedBoundingArea(geometry.vertices, axis: direction))
        }.sorted {
            if $0.area != $1.area { return $0.area < $1.area }
            return directionLessThan($0.direction, $1.direction)
        }
        for candidate in derived.prefix(8) { appendNormal(candidate.direction) }

        let regions = (target.measurement?.regions.filter {
            $0.areaMM2 >= settings.minRegionAreaMM2
                && $0.depthMM > settings.undercutToleranceMM
        } ?? target.measurement?.regions ?? []).sorted {
            if $0.depthMM != $1.depthMM { return $0.depthMM > $1.depthMM }
            if $0.areaMM2 != $1.areaMM2 { return $0.areaMM2 > $1.areaMM2 }
            return $0.id < $1.id
        }
        let rangedNormals = normals.compactMap { normal -> (Vec3, lower: Double, upper: Double)? in
            guard let range = projectionRange(geometry.vertices, normal: normal),
                  range.upper - range.lower > 1.0e-5 else { return nil }
            return (normal, range.lower, range.upper)
        }
        var rawPlanes: [CanonicalPlane] = []
        // The model origin is a common authored symmetry plane. Treat it as a
        // real symmetry proposal only when it lies safely inside the leaf.
        for entry in rangedNormals.prefix(3) {
            let span = entry.upper - entry.lower
            if entry.lower < -span * 0.05,
               entry.upper > span * 0.05,
               let plane = CanonicalPlane(normal: entry.0, offset: 0) {
                rawPlanes.append(plane)
            }
        }
        // Organic undercuts are often removed by peeling a small clear lobe,
        // not by bisecting volume. Put measured region seams ahead of generic
        // median fallbacks so the bounded evaluator sees those candidates.
        let hasPriorCutSurface = target.mesh.triangles.contains { triangle in
            if case .cut = triangle.provenance { return true }
            return false
        }
        rawPlanes.append(contentsOf: concaveFeaturePlanes(
            for: target,
            settings: settings,
            maximumCount: min(4, planeBudget(settings.quality) - rawPlanes.count)
        ))
        let regionBasisNormals = hasPriorCutSurface
            ? [target.pullAxis,
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 0, z: 1),
              ]
            : [target.pullAxis]
        let proposalRegions: [UndercutRegionClusterer.Region]
        if !hasPriorCutSurface,
           let axis = PullDirectionCandidates.canonicalized(target.pullAxis),
           let range = projectionRange(geometry.vertices, normal: axis) {
            proposalRegions = regions.sorted { lhs, rhs in
                let lhsProjection = dot(lhs.centroid, axis)
                let rhsProjection = dot(rhs.centroid, axis)
                let lhsBoundaryDistance = min(
                    lhsProjection - range.lower,
                    range.upper - lhsProjection
                )
                let rhsBoundaryDistance = min(
                    rhsProjection - range.lower,
                    range.upper - rhsProjection
                )
                if lhsBoundaryDistance != rhsBoundaryDistance {
                    return lhsBoundaryDistance < rhsBoundaryDistance
                }
                if lhs.depthMM != rhs.depthMM { return lhs.depthMM > rhs.depthMM }
                return lhs.id < rhs.id
            }
        } else {
            proposalRegions = regions
        }
        let automaticRegionLimit = hasPriorCutSurface ? 12 : 2
        for region in proposalRegions.prefix(automaticRegionLimit) {
            var regionNormals: [Vec3] = []
            for raw in regionBasisNormals
                + region.suggestedEscapeDirections
                + [target.pullAxis] {
                guard let normal = PullDirectionCandidates.canonicalized(raw),
                      !regionNormals.contains(where: { axesEquivalent($0, normal) }) else {
                    continue
                }
                regionNormals.append(normal)
            }
            for normal in regionNormals {
                guard let range = rangedNormals.first(where: {
                    axesEquivalent($0.0, normal)
                }) else { continue }
                let span = range.upper - range.lower
                let offset = dot(region.centroid, normal)
                guard offset > range.lower + span * 0.02,
                      offset < range.upper - span * 0.02,
                      let plane = CanonicalPlane(normal: normal, offset: offset) else {
                    continue
                }
                rawPlanes.append(plane)
                if rawPlanes.count >= planeBudget(settings.quality) { break }
            }
            if rawPlanes.count >= planeBudget(settings.quality) { break }
        }
        if !hasPriorCutSurface,
           let range = projectionRange(geometry.vertices, normal: target.pullAxis),
           let plane = CanonicalPlane(
                normal: target.pullAxis,
                offset: (range.lower + range.upper) / 2
           ) {
            rawPlanes.append(plane)
        }

        // Interleave normals before widening offsets. This keeps the bounded
        // prefix diverse instead of spending every candidate on X offsets.
        for fraction in [0.5, 0.35, 0.65, 0.2, 0.8] {
            for entry in rangedNormals {
                if let plane = CanonicalPlane(
                    normal: entry.0,
                    offset: entry.lower + (entry.upper - entry.lower) * fraction
                ) {
                    rawPlanes.append(plane)
                }
                if rawPlanes.count >= planeBudget(settings.quality) { break }
            }
            if rawPlanes.count >= planeBudget(settings.quality) { break }
        }

        if rawPlanes.count < planeBudget(settings.quality) {
            for entry in rangedNormals {
                let normal = entry.0
                let span = entry.upper - entry.lower
                let projectedCentroids = regions.map { dot($0.centroid, normal) }.sorted()
            for value in projectedCentroids {
                    if value > entry.lower + span * 0.05,
                       value < entry.upper - span * 0.05,
                   let plane = CanonicalPlane(normal: normal, offset: value) {
                    rawPlanes.append(plane)
                        if rawPlanes.count >= planeBudget(settings.quality) { break }
                }
            }
                if rawPlanes.count >= planeBudget(settings.quality) { break }
                if projectedCentroids.count > 1 {
                let gaps = zip(projectedCentroids, projectedCentroids.dropFirst())
                    .map { lower, upper in (gap: upper - lower, middle: (lower + upper) / 2) }
                    .sorted {
                        if $0.gap != $1.gap { return $0.gap > $1.gap }
                        return $0.middle < $1.middle
                    }
                for gap in gaps.prefix(4) where gap.gap > 1.0e-6 {
                    if let plane = CanonicalPlane(normal: normal, offset: gap.middle) {
                        rawPlanes.append(plane)
                            if rawPlanes.count >= planeBudget(settings.quality) { break }
                    }
                }
            }
                if rawPlanes.count >= planeBudget(settings.quality) { break }
            }
        }

        var result: [CanonicalPlane] = []
        for raw in rawPlanes {
            let sourceSafe = avoidSourceVertexGrazing(raw, sourceVertices: sourceVertices)
            let plane = avoidSourceVertexGrazing(
                sourceSafe,
                sourceVertices: geometry.vertices
            )
            if !result.contains(where: { planesEquivalent($0, plane) }) {
                result.append(plane)
            }
            if result.count == planeBudget(settings.quality) { break }
        }
        return result
    }

    /// Planes through sharp concave source creases are useful on organic scans:
    /// the crease is the visible boundary of a hook, and the normal-difference
    /// bisector extends the seam from that boundary into the solid. Only source
    /// triangles participate, so generated caps never become new feature lines
    /// during deeper scoped expansions.
    private static func concaveFeaturePlanes(
        for target: SearchLeaf,
        settings: UndercutSplitSettings,
        maximumCount: Int
    ) -> [CanonicalPlane] {
        struct VertexKey: Hashable, Comparable {
            var x: Int64
            var y: Int64
            var z: Int64

            init(_ point: Vec3) {
                let scale = 1 / UndercutSplitTolerancePolicy.current.linearWeldMM
                func quantize(_ coordinate: Double) -> Int64 {
                    let scaled = coordinate * scale
                    if scaled >= Double(Int64.max) { return .max }
                    if scaled <= Double(Int64.min) { return .min }
                    return Int64(scaled.rounded())
                }
                x = quantize(point.x)
                y = quantize(point.y)
                z = quantize(point.z)
            }

            static func < (lhs: VertexKey, rhs: VertexKey) -> Bool {
                if lhs.x != rhs.x { return lhs.x < rhs.x }
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                return lhs.z < rhs.z
            }
        }
        struct EdgeKey: Hashable {
            var lower: VertexKey
            var upper: VertexKey

            init(_ lhs: VertexKey, _ rhs: VertexKey) {
                if lhs < rhs {
                    lower = lhs
                    upper = rhs
                } else {
                    lower = rhs
                    upper = lhs
                }
            }
        }
        struct Incident {
            var faceIndex: Int
            var from: Vec3
            var to: Vec3
            var normal: Vec3
        }
        struct Feature {
            var plane: CanonicalPlane
            var midpoint: Vec3
            var pointA: Vec3
            var pointB: Vec3
            var keyA: VertexKey
            var keyB: VertexKey
            var angleRadians: Double
            var length: Double
            var score: Double
            var faceOrdinal: Int
        }
        struct ValleyComponent {
            var centroid: Vec3
            var pcaPlane: CanonicalPlane
            var meanBisectorPlane: CanonicalPlane?
            var score: Double
            var totalLength: Double
            var faceOrdinal: Int
        }

        guard maximumCount > 0 else { return [] }
        let violatingRegions = (target.measurement?.regions ?? []).filter {
            $0.areaMM2 >= settings.minRegionAreaMM2
                && $0.depthMM > settings.undercutToleranceMM
        }.sorted {
            if $0.depthMM != $1.depthMM { return $0.depthMM > $1.depthMM }
            if $0.areaMM2 != $1.areaMM2 { return $0.areaMM2 > $1.areaMM2 }
            return $0.id < $1.id
        }
        let worstFaceIDs = Set(violatingRegions.first?.faceIDs ?? [])
        let violatingFaceIDs = Set(violatingRegions.flatMap(\.faceIDs))
        let worstCentroid = violatingRegions.first?.centroid

        var incidentsByEdge: [EdgeKey: [Incident]] = [:]
        incidentsByEdge.reserveCapacity(target.mesh.triangles.count * 3 / 2)
        for (faceIndex, triangle) in target.mesh.triangles.enumerated() {
            guard case .source = triangle.provenance,
                  let normal = unit(cross(
                    subtract(triangle.b, triangle.a),
                    subtract(triangle.c, triangle.a)
                  )) else { continue }
            for (from, to) in [
                (triangle.a, triangle.b),
                (triangle.b, triangle.c),
                (triangle.c, triangle.a),
            ] {
                let key = EdgeKey(VertexKey(from), VertexKey(to))
                incidentsByEdge[key, default: []].append(Incident(
                    faceIndex: faceIndex,
                    from: from,
                    to: to,
                    normal: normal
                ))
            }
        }

        let minimumAngle = 10.0 * Double.pi / 180
        let maximumAngle = 170.0 * Double.pi / 180
        var features: [Feature] = []
        features.reserveCapacity(incidentsByEdge.count / 8)
        for (edgeKey, incidents) in incidentsByEdge where incidents.count == 2 {
            let ordered = incidents.sorted { lhs, rhs in
                if lhs.faceIndex != rhs.faceIndex { return lhs.faceIndex < rhs.faceIndex }
                if lhs.from.x != rhs.from.x { return lhs.from.x < rhs.from.x }
                if lhs.from.y != rhs.from.y { return lhs.from.y < rhs.from.y }
                return lhs.from.z < rhs.from.z
            }
            let first = ordered[0]
            let second = ordered[1]
            guard let edgeDirection = unit(subtract(first.to, first.from)) else { continue }
            let cosine = min(max(dot(first.normal, second.normal), -1), 1)
            let angle = acos(cosine)
            guard angle >= minimumAngle, angle <= maximumAngle else { continue }
            let signedSine = dot(cross(first.normal, second.normal), edgeDirection)
            guard signedSine < -1.0e-8,
                  let normal = unit(subtract(first.normal, second.normal)) else { continue }
            let midpoint = Vec3(
                x: (first.from.x + first.to.x) / 2,
                y: (first.from.y + first.to.y) / 2,
                z: (first.from.z + first.to.z) / 2
            )
            guard let plane = CanonicalPlane(
                normal: normal,
                offset: dot(midpoint, normal)
            ) else { continue }

            let length = distance(first.from, first.to)
            var score = length * angle
            if worstFaceIDs.contains(first.faceIndex)
                || worstFaceIDs.contains(second.faceIndex) {
                score *= 8
            } else if violatingFaceIDs.contains(first.faceIndex)
                || violatingFaceIDs.contains(second.faceIndex) {
                score *= 3
            }
            if let worstCentroid {
                score /= 1 + distance(midpoint, worstCentroid) / 40
            }
            let fromKey = VertexKey(first.from)
            let endpointA: Vec3
            let endpointB: Vec3
            if fromKey == edgeKey.lower {
                endpointA = first.from
                endpointB = first.to
            } else {
                endpointA = first.to
                endpointB = first.from
            }
            features.append(Feature(
                plane: plane,
                midpoint: midpoint,
                pointA: endpointA,
                pointB: endpointB,
                keyA: edgeKey.lower,
                keyB: edgeKey.upper,
                angleRadians: angle,
                length: length,
                score: score,
                faceOrdinal: min(first.faceIndex, second.faceIndex)
            ))
        }

        features.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.faceOrdinal != rhs.faceOrdinal { return lhs.faceOrdinal < rhs.faceOrdinal }
            if lhs.plane.offset != rhs.plane.offset { return lhs.plane.offset < rhs.plane.offset }
            return directionLessThan(lhs.plane.normal, rhs.plane.normal)
        }

        // Ten-degree curvature links most of a smooth scan into one component.
        // Sharp (40-degree) connected chains instead isolate the anatomical
        // valleys around fingers and contact folds. Fit a plane to each chain's
        // welded line network and also retain its mean dihedral bisector.
        let sharpThreshold = 40.0 * Double.pi / 180
        var unionFind = ComponentUnionFind(count: features.count)
        var firstFeatureByVertex: [VertexKey: Int] = [:]
        let sharpIndices = features.indices.filter {
            features[$0].angleRadians >= sharpThreshold
        }
        for index in sharpIndices {
            for key in [features[index].keyA, features[index].keyB] {
                if let first = firstFeatureByVertex[key] {
                    unionFind.unite(first, index)
                } else {
                    firstFeatureByVertex[key] = index
                }
            }
        }
        var indicesByRoot: [Int: [Int]] = [:]
        for index in sharpIndices {
            indicesByRoot[unionFind.find(index), default: []].append(index)
        }

        var components: [ValleyComponent] = []
        components.reserveCapacity(indicesByRoot.count)
        for indices in indicesByRoot.values where indices.count >= 3 {
            let sortedIndices = indices.sorted()
            var pointByKey: [VertexKey: Vec3] = [:]
            var normalSum = Vec3(x: 0, y: 0, z: 0)
            var totalScore = 0.0
            var totalLength = 0.0
            var faceOrdinal = Int.max
            for index in sortedIndices {
                let feature = features[index]
                pointByKey[feature.keyA] = feature.pointA
                pointByKey[feature.keyB] = feature.pointB
                let weight = max(feature.length * feature.angleRadians, 1.0e-12)
                normalSum = Vec3(
                    x: normalSum.x + feature.plane.normal.x * weight,
                    y: normalSum.y + feature.plane.normal.y * weight,
                    z: normalSum.z + feature.plane.normal.z * weight
                )
                totalScore += feature.score
                totalLength += feature.length
                faceOrdinal = min(faceOrdinal, feature.faceOrdinal)
            }
            let points = pointByKey.sorted { $0.key < $1.key }.map(\.value)
            guard points.count >= 3,
                  let pcaNormal = smallestCovarianceEigenvector(points) else { continue }
            let centroid = points.reduce(Vec3(x: 0, y: 0, z: 0)) {
                Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
            }
            let center = Vec3(
                x: centroid.x / Double(points.count),
                y: centroid.y / Double(points.count),
                z: centroid.z / Double(points.count)
            )
            guard let pcaPlane = CanonicalPlane(
                normal: pcaNormal,
                offset: dot(center, pcaNormal)
            ) else { continue }
            let meanPlane = unit(normalSum).flatMap { normal in
                CanonicalPlane(normal: normal, offset: dot(center, normal))
            }
            components.append(ValleyComponent(
                centroid: center,
                pcaPlane: pcaPlane,
                meanBisectorPlane: meanPlane,
                score: totalScore * sqrt(max(totalLength, 1)),
                totalLength: totalLength,
                faceOrdinal: faceOrdinal
            ))
        }
        components.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.totalLength != rhs.totalLength { return lhs.totalLength > rhs.totalLength }
            if lhs.faceOrdinal != rhs.faceOrdinal { return lhs.faceOrdinal < rhs.faceOrdinal }
            if lhs.centroid.x != rhs.centroid.x { return lhs.centroid.x < rhs.centroid.x }
            if lhs.centroid.y != rhs.centroid.y { return lhs.centroid.y < rhs.centroid.y }
            return lhs.centroid.z < rhs.centroid.z
        }

        var candidates: [CanonicalPlane] = []
        let leading = Array(components.prefix(5))
        for component in leading {
            for delta in [0.0, -2.0, -4.0, 2.0, -6.0, 4.0] {
                if let plane = CanonicalPlane(
                    normal: component.pcaPlane.normal,
                    offset: component.pcaPlane.offset + delta
                ) {
                    candidates.append(plane)
                }
            }
            if let mean = component.meanBisectorPlane { candidates.append(mean) }
            if candidates.count >= maximumCount { break }
        }
        if candidates.count < maximumCount {
            for feature in features {
                candidates.append(feature.plane)
                if candidates.count >= maximumCount { break }
            }
        }
        return Array(candidates.prefix(maximumCount))
    }

    private static func smallestCovarianceEigenvector(_ points: [Vec3]) -> Vec3? {
        guard points.count >= 3 else { return nil }
        let sum = points.reduce(Vec3(x: 0, y: 0, z: 0)) {
            Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        let center = Vec3(
            x: sum.x / Double(points.count),
            y: sum.y / Double(points.count),
            z: sum.z / Double(points.count)
        )
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for point in points {
            let value = [point.x - center.x, point.y - center.y, point.z - center.z]
            for row in 0..<3 {
                for column in row..<3 {
                    matrix[row][column] += value[row] * value[column]
                    matrix[column][row] = matrix[row][column]
                }
            }
        }
        var vectors = [
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, 0.0, 1.0],
        ]
        for _ in 0..<24 {
            let pairs = [(0, 1), (0, 2), (1, 2)]
            let pair = pairs.max { lhs, rhs in
                let left = abs(matrix[lhs.0][lhs.1])
                let right = abs(matrix[rhs.0][rhs.1])
                if left != right { return left < right }
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                return lhs.1 > rhs.1
            } ?? (0, 1)
            let p = pair.0
            let q = pair.1
            let offDiagonal = matrix[p][q]
            if abs(offDiagonal) <= 1.0e-12 { break }
            let angle = 0.5 * atan2(
                2 * offDiagonal,
                matrix[q][q] - matrix[p][p]
            )
            let cosine = cos(angle)
            let sine = sin(angle)
            let old = matrix
            for index in 0..<3 where index != p && index != q {
                let ip = old[index][p]
                let iq = old[index][q]
                matrix[index][p] = cosine * ip - sine * iq
                matrix[p][index] = matrix[index][p]
                matrix[index][q] = sine * ip + cosine * iq
                matrix[q][index] = matrix[index][q]
            }
            matrix[p][p] = cosine * cosine * old[p][p]
                - 2 * sine * cosine * offDiagonal
                + sine * sine * old[q][q]
            matrix[q][q] = sine * sine * old[p][p]
                + 2 * sine * cosine * offDiagonal
                + cosine * cosine * old[q][q]
            matrix[p][q] = 0
            matrix[q][p] = 0
            for row in 0..<3 {
                let vp = vectors[row][p]
                let vq = vectors[row][q]
                vectors[row][p] = cosine * vp - sine * vq
                vectors[row][q] = sine * vp + cosine * vq
            }
        }
        let smallest = (0..<3).min { lhs, rhs in
            if matrix[lhs][lhs] != matrix[rhs][rhs] {
                return matrix[lhs][lhs] < matrix[rhs][rhs]
            }
            return lhs < rhs
        } ?? 0
        return unit(Vec3(
            x: vectors[0][smallest],
            y: vectors[1][smallest],
            z: vectors[2][smallest]
        ))
    }

    private static func avoidSourceVertexGrazing(
        _ plane: CanonicalPlane,
        sourceVertices: [Vec3]
    ) -> CanonicalPlane {
        let tolerance = UndercutSplitTolerancePolicy.current.linearWeldMM
        guard sourceVertices.contains(where: {
            abs(dot($0, plane.normal) - plane.offset) <= tolerance
        }) else { return plane }
        let shift = sourceVertices.count > 300_000 ? 1.0e-3 : 5.0e-5
        for multiplier in 1...32 {
            let offset = plane.offset + shift * Double(multiplier)
            if !sourceVertices.contains(where: {
                abs(dot($0, plane.normal) - offset) <= tolerance * 4
            }), let candidate = CanonicalPlane(normal: plane.normal, offset: offset) {
                return candidate
            }
        }
        return plane
    }

    private static func preparedCandidateBudget(_ quality: UndercutSearchQuality) -> Int {
        switch quality {
        case .quick: return 8
        case .standard: return 12
        case .thorough: return 20
        }
    }

    /// Region-guided candidate planes (probe-validated 2026-07-13): unhook
    /// planes normal to a region's measured escape direction through its
    /// centroid with deterministic offsets, separator planes between deep
    /// region pairs, and world-axis planes through the deepest centroids.
    /// These families produced every resolving cut in the §11.3 feasibility
    /// study on the healed hand.
    private static func regionGuidedPlanes(
        for target: SearchLeaf,
        settings: UndercutSplitSettings
    ) -> [CanonicalPlane] {
        guard let measurement = target.measurement else { return [] }
        let regions = measurement.regions
            .filter {
                $0.areaMM2 >= settings.minRegionAreaMM2
                    && $0.depthMM > settings.undercutToleranceMM
            }
            .sorted {
                if $0.depthMM != $1.depthMM { return $0.depthMM > $1.depthMM }
                return $0.id < $1.id
            }
        var planes: [CanonicalPlane] = []
        for region in regions.prefix(4) {
            for escape in region.suggestedEscapeDirections.prefix(2) {
                let base = dot(region.centroid, escape)
                for shift in [0.0, 2.0, -2.0, 5.0, -5.0] {
                    if let plane = CanonicalPlane(normal: escape, offset: base + shift) {
                        planes.append(plane)
                    }
                }
            }
        }
        let pairSources = Array(regions.prefix(4))
        if pairSources.count >= 2 {
            for i in 0..<(pairSources.count - 1) {
                for j in (i + 1)..<pairSources.count {
                    let a = pairSources[i].centroid
                    let b = pairSources[j].centroid
                    let axis = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
                    let length = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
                        .squareRoot()
                    guard length > 5 else { continue }
                    let normal = Vec3(
                        x: axis.x / length,
                        y: axis.y / length,
                        z: axis.z / length
                    )
                    let midpoint = Vec3(
                        x: (a.x + b.x) / 2,
                        y: (a.y + b.y) / 2,
                        z: (a.z + b.z) / 2
                    )
                    for shift in [0.0, 3.0, -3.0] {
                        if let plane = CanonicalPlane(
                            normal: normal,
                            offset: dot(midpoint, normal) + shift
                        ) {
                            planes.append(plane)
                        }
                    }
                }
            }
        }
        for region in regions.prefix(2) {
            for axis in [
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 0, z: 1),
            ] {
                if let plane = CanonicalPlane(
                    normal: axis,
                    offset: dot(region.centroid, axis)
                ) {
                    planes.append(plane)
                }
            }
        }
        return planes
    }

    /// Deterministic near-duplicate removal; ±normal describes one plane.
    private static func dedupedProposals(_ planes: [CanonicalPlane]) -> [CanonicalPlane] {
        var seen = Set<String>()
        var result: [CanonicalPlane] = []
        for plane in planes {
            var normal = plane.normal
            var offset = plane.offset
            let flip: Bool
            if abs(normal.x) > 1.0e-9 { flip = normal.x < 0 }
            else if abs(normal.y) > 1.0e-9 { flip = normal.y < 0 }
            else { flip = normal.z < 0 }
            if flip {
                normal = Vec3(x: -normal.x, y: -normal.y, z: -normal.z)
                offset = -offset
            }
            let key = "\(Int((normal.x * 50).rounded())),"
                + "\(Int((normal.y * 50).rounded())),"
                + "\(Int((normal.z * 50).rounded())),"
                + "\(Int((offset * 2).rounded()))"
            if seen.insert(key).inserted { result.append(plane) }
        }
        return result
    }

    private static func prepareSplitCandidates(
        proposals: [CanonicalPlane],
        target: SearchLeaf,
        state: SearchState,
        sourceVolumeMM3: Double,
        settings: UndercutSplitSettings,
        preferManifold: Bool,
        desiredCount: Int? = nil,
        rejections: inout [UndercutCandidateRejection]
    ) -> [PreparedSplitCandidate] {
        var accepted: [PreparedSplitCandidate] = []
        let desiredPreparedCount = desiredCount ?? (expansionCount(settings.quality) + 1)
        for (ordinal, plane) in proposals.enumerated() {
            let node = PartitionCutNode.automatic(
                plannerVersion: settings.plannerVersion,
                targetRegionID: target.regionID,
                plane: plane,
                siblingOrdinal: ordinal,
                isLocked: false
            )
            let split: PartitionGeometry.AttributedSplit
            do {
                if preferManifold {
                    split = try manifoldAttributedSplit(
                        target.mesh,
                        plane: plane,
                        cutNodeID: node.id
                    )
                } else {
                    split = try PartitionGeometry.splitAttributed(
                        target.mesh,
                        plane: plane,
                        cutNodeID: node.id
                    )
                }
            } catch {
                let reason: UndercutCandidateRejectionReason
                if let splitError = error as? PartitionGeometry.AttributedSplitError {
                    switch splitError {
                    case .planeDoesNotSplit:
                        reason = .doesNotSplitLeaf
                    default:
                        reason = .childrenNotClosed
                    }
                } else {
                    reason = .childrenNotClosed
                }
                rejections.append(UndercutCandidateRejection(
                    reason: reason,
                    targetRegionID: target.regionID,
                    candidatePlane: plane,
                    detail: error.localizedDescription
                ))
                if ProcessInfo.processInfo.environment[
                    "UNDERCUT_SPLIT_SEARCH_DEBUG"
                ] == "1" {
                    print("UNDERCUT_SEARCH rejected plane=\(plane) reason=\(reason.rawValue) detail=\(error.localizedDescription)")
                }
                continue
            }

            let negativeVolume = abs(split.negative.signedVolume)
            let positiveVolume = abs(split.positive.signedVolume)
            let parentVolume = abs(target.mesh.signedVolume)
            let totalChildren = negativeVolume + positiveVolume
            let volumeDelta = totalChildren - parentVolume
            var tolerance = max(
                UndercutSplitTolerancePolicy.current.absoluteVolumeMM3,
                parentVolume * UndercutSplitTolerancePolicy.current.relativeVolumeFraction
            )
            if preferManifold {
                // Search-proxy MeshGL readback can discard sub-weld triangles;
                // finalist conservation is still checked at the strict policy.
                tolerance = max(tolerance, parentVolume * 1.0e-5)
            }
            let seamArea = split.negative.surfaceArea { provenance in
                if case .cut(let nodeID, .negative) = provenance { return nodeID == node.id }
                return false
            }
            let crossedFaces = crossedSourceFaces(
                in: target.mesh,
                by: plane
            )
            let facts = CandidatePrefilterFacts(
                splitsLeaf: negativeVolume > 0 && positiveVolume > 0,
                childVolumesMM3: [negativeVolume, positiveVolume],
                sourceVolumeMM3: sourceVolumeMM3,
                crossedNoCutSourceFaceIDs: crossedFaces,
                seamAreaMM2: seamArea,
                inputComponentCount: 1,
                crossedInputComponentCount: 1,
                outputComponentCount: 2,
                childrenAreClosed: true,
                conservationMissingVolumeMM3: max(0, -volumeDelta),
                conservationExcessVolumeMM3: max(0, volumeDelta),
                conservationToleranceMM3: tolerance
            )
            let reasons = prefilterRejections(for: facts, settings: settings)
            if !reasons.isEmpty {
                for reason in reasons {
                    rejections.append(UndercutCandidateRejection(
                        reason: reason,
                        targetRegionID: target.regionID,
                        candidatePlane: plane,
                        detail: rejectionDetail(reason, facts: facts)
                    ))
                }
                if ProcessInfo.processInfo.environment[
                    "UNDERCUT_SPLIT_SEARCH_DEBUG"
                ] == "1" {
                    print("UNDERCUT_SEARCH rejected plane=\(plane) reasons=\(reasons.map(\.rawValue))")
                }
                continue
            }

            let balance = abs(negativeVolume - positiveVolume) / max(parentVolume, 1.0e-12)
            let seamScale = seamArea / max(
                target.mesh.surfaceArea(),
                1.0e-12
            )
            let regionBalance = regionSeparationPenalty(
                target.measurement?.regions ?? [],
                plane: plane
            )
            accepted.append(PreparedSplitCandidate(
                node: node,
                negative: split.negative,
                positive: split.positive,
                seamAreaMM2: seamArea,
                heuristic: balance + seamScale * 0.1 + regionBalance * 0.25
            ))
            if accepted.count >= desiredPreparedCount { break }
        }
        return accepted
    }

    private static func manifoldAttributedSplit(
        _ mesh: AttributedMesh,
        plane: CanonicalPlane,
        cutNodeID: PartitionCutNodeID
    ) throws -> PartitionGeometry.AttributedSplit {
        let solid = try ManifoldEngine.make(from: mesh.geometry)
        let split = try ManifoldEngine.splitByPlane(
            solid,
            normal: plane.normal,
            offset: plane.offset
        )
        guard !ManifoldEngine.isEmpty(split.0), !ManifoldEngine.isEmpty(split.1) else {
            throw PartitionGeometry.AttributedSplitError.planeDoesNotSplit
        }
        func child(
            _ handle: ManifoldHandle,
            side: PartitionCutSide
        ) throws -> AttributedMesh {
            var candidate = handle
            var geometry = try ManifoldEngine.toMesh(candidate)
            var preflight = MeshPreflight.analyze(geometry: geometry)
            if preflight.degenerateTriangleCount > 0,
               let simplified = try? ManifoldEngine.simplify(
                handle,
                tolerance: UndercutSplitTolerancePolicy.current.linearWeldMM * 128
               ) {
                candidate = simplified
                geometry = try ManifoldEngine.toMesh(candidate)
                preflight = MeshPreflight.analyze(geometry: geometry)
            }
            // Same R4 parity-closure criterion as the attributed splitter:
            // benign slivers are admitted, open edges are not.
            let openEdges = PartitionGeometry.openEdgeCount(geometry)
            guard openEdges == 0 else {
                throw Error.planningFailed(
                    stage: "Manifold candidate split",
                    detail: "generated \(side.rawValue) child has \(openEdges) open edges (parity over all triangles; preflight: \(preflight.boundaryEdgeCount) boundary, \(preflight.degenerateTriangleCount) degenerate)"
                )
            }
            var result = try SourceFaceMap.attributedMesh(from: geometry)
            result.sourceGeometryFingerprint = mesh.sourceGeometryFingerprint
            let availableSourceIDs = mesh.sourceFaceIDs.sorted()
            result.triangles = result.triangles.enumerated().map { index, triangle in
                var copy = triangle
                if triangleLiesOnPlane(triangle, plane: plane) {
                    copy.provenance = .cut(nodeID: cutNodeID, side: side)
                } else if !availableSourceIDs.isEmpty {
                    copy.provenance = .source(availableSourceIDs[index % availableSourceIDs.count])
                }
                return copy
            }
            return result
        }
        return PartitionGeometry.AttributedSplit(
            negative: try child(split.1, side: .negative),
            positive: try child(split.0, side: .positive)
        )
    }

    private static func robustAttributedSplit(
        _ mesh: AttributedMesh,
        plane: CanonicalPlane,
        cutNodeID: PartitionCutNodeID
    ) throws -> PartitionGeometry.AttributedSplit {
        var attributedError: Swift.Error = Error.planningFailed(
            stage: "candidate split",
            detail: "The boundary-closed healed source requires Manifold normalization."
        )
        do {
            return try PartitionGeometry.splitAttributed(
                mesh,
                plane: plane,
                cutNodeID: cutNodeID
            )
        } catch {
            attributedError = error
        }
        do {
            return try hybridAttributedSplit(
                mesh,
                plane: plane,
                cutNodeID: cutNodeID
            )
        } catch {
            attributedError = error
        }
        let solid = try ManifoldEngine.make(from: mesh.geometry)
        let split = try ManifoldEngine.splitByPlane(
            solid,
            normal: plane.normal,
            offset: plane.offset
        )
        guard !ManifoldEngine.isEmpty(split.0), !ManifoldEngine.isEmpty(split.1) else {
            throw attributedError
        }
        func attributed(
                _ handle: ManifoldHandle,
                side: PartitionCutSide
            ) throws -> AttributedMesh {
                let cleaned = (try? ManifoldEngine.simplify(
                    handle,
                    tolerance: UndercutSplitTolerancePolicy.current.linearWeldMM * 128
                )) ?? handle
                let geometry = try ManifoldEngine.toMesh(cleaned)
                var result = try SourceFaceMap.attributedMesh(from: geometry)
                result.sourceGeometryFingerprint = mesh.sourceGeometryFingerprint
                let availableSourceIDs = mesh.sourceFaceIDs.sorted()
                result.triangles = result.triangles.enumerated().map { index, triangle in
                    var copy = triangle
                    if triangleLiesOnPlane(triangle, plane: plane) {
                        copy.provenance = .cut(nodeID: cutNodeID, side: side)
                    } else if !availableSourceIDs.isEmpty {
                        copy.provenance = .source(
                            availableSourceIDs[index % availableSourceIDs.count]
                        )
                    }
                    return copy
                }
                let preflight = MeshPreflight.analyze(geometry: result.geometry)
                guard preflight.boundaryEdgeCount == 0,
                      preflight.degenerateTriangleCount == 0 else {
                    throw Error.planningFailed(
                        stage: "candidate child normalization",
                        detail: "generated \(side.rawValue) child has \(preflight.boundaryEdgeCount) boundary edges and \(preflight.degenerateTriangleCount) degenerate triangles"
                    )
                }
                return result
            }
        return PartitionGeometry.AttributedSplit(
            negative: try attributed(split.1, side: .negative),
            positive: try attributed(split.0, side: .positive)
        )
    }

    private static func hybridAttributedSplit(
        _ mesh: AttributedMesh,
        plane: CanonicalPlane,
        cutNodeID: PartitionCutNodeID
    ) throws -> PartitionGeometry.AttributedSplit {
        let equation = PartitionGeometry.PlaneEq(
            normal: plane.normal,
            offset: plane.offset
        )
        let negativeSurface = PartitionGeometry.clipAttributedHalfSpace(
            mesh.triangles,
            plane: equation,
            keepPositive: false
        )
        let positiveSurface = PartitionGeometry.clipAttributedHalfSpace(
            mesh.triangles,
            plane: equation,
            keepPositive: true
        )
        guard !negativeSurface.isEmpty, !positiveSurface.isEmpty else {
            throw PartitionGeometry.AttributedSplitError.planeDoesNotSplit
        }

        let solid = try ManifoldEngine.make(from: mesh.geometry)
        let manifold = try ManifoldEngine.splitByPlane(
            solid,
            normal: plane.normal,
            offset: plane.offset
        )
        guard !ManifoldEngine.isEmpty(manifold.0), !ManifoldEngine.isEmpty(manifold.1) else {
            throw PartitionGeometry.AttributedSplitError.planeDoesNotSplit
        }

        func capTriangles(
            _ handle: ManifoldHandle,
            side: PartitionCutSide
        ) throws -> [AttributedTriangle] {
            let geometry = try ManifoldEngine.toMesh(handle)
            var result: [AttributedTriangle] = []
            var index = 0
            while index + 2 < geometry.triangleIndices.count {
                let indices = [
                    Int(geometry.triangleIndices[index]),
                    Int(geometry.triangleIndices[index + 1]),
                    Int(geometry.triangleIndices[index + 2]),
                ]
                index += 3
                guard indices.allSatisfy(geometry.vertices.indices.contains) else { continue }
                let triangle = AttributedTriangle(
                    a: geometry.vertices[indices[0]],
                    b: geometry.vertices[indices[1]],
                    c: geometry.vertices[indices[2]],
                    provenance: .cut(nodeID: cutNodeID, side: side)
                )
                if triangleLiesOnPlane(triangle, plane: plane),
                   triangle.area > UndercutSplitTolerancePolicy.current.minimumTriangleAreaMM2 {
                    result.append(triangle)
                }
            }
            guard !result.isEmpty else {
                throw PartitionGeometry.AttributedSplitError.capTriangulationFailed
            }
            return result
        }

        let negativeCaps = try capTriangles(manifold.1, side: .negative)
        let positiveCaps = try capTriangles(manifold.0, side: .positive)
        let linearTolerance = UndercutSplitTolerancePolicy.current.linearWeldMM
        let negative = AttributedMesh(
            triangles: negativeSurface + negativeCaps,
            sourceGeometryFingerprint: mesh.sourceGeometryFingerprint,
            sourceReferencedVertices: mesh.sourceReferencedVertices.filter {
                dot($0, plane.normal) - plane.offset <= linearTolerance
            },
            omittedDegenerateSourceFaceIDs: mesh.omittedDegenerateSourceFaceIDs
        )
        let positive = AttributedMesh(
            triangles: positiveSurface + positiveCaps,
            sourceGeometryFingerprint: mesh.sourceGeometryFingerprint,
            sourceReferencedVertices: mesh.sourceReferencedVertices.filter {
                dot($0, plane.normal) - plane.offset >= -linearTolerance
            },
            omittedDegenerateSourceFaceIDs: mesh.omittedDegenerateSourceFaceIDs
        )
        for (side, child) in [(PartitionCutSide.negative, negative), (.positive, positive)] {
            let preflight = MeshPreflight.analyze(geometry: child.geometry)
            guard preflight.boundaryEdgeCount == 0,
                  preflight.degenerateTriangleCount == 0 else {
                throw Error.planningFailed(
                    stage: "hybrid candidate cap",
                    detail: "generated \(side.rawValue) child has \(preflight.boundaryEdgeCount) boundary edges and \(preflight.degenerateTriangleCount) degenerate triangles"
                )
            }
        }
        return PartitionGeometry.AttributedSplit(negative: negative, positive: positive)
    }

    private static func crossedSourceFaces(
        in mesh: AttributedMesh,
        by plane: CanonicalPlane
    ) -> [SourceFaceID] {
        let tolerance = UndercutSplitTolerancePolicy.current.linearWeldMM
        var result = Set<SourceFaceID>()
        for triangle in mesh.triangles {
            guard case .source(let faceID) = triangle.provenance else { continue }
            let distances = [triangle.a, triangle.b, triangle.c].map {
                dot($0, plane.normal) - plane.offset
            }
            if distances.contains(where: { $0 < -tolerance })
                && distances.contains(where: { $0 > tolerance }) {
                result.insert(faceID)
            }
        }
        return result.sorted()
    }

    private static func rejectionDetail(
        _ reason: UndercutCandidateRejectionReason,
        facts: CandidatePrefilterFacts
    ) -> String {
        switch reason {
        case .doesNotSplitLeaf:
            return "The plane did not create two nonempty child solids."
        case .minimumPieceVolume:
            return "A child volume was below the configured minimum: \(facts.childVolumesMM3)."
        case .crossesNoCutFace:
            return "The plane crossed no-cut source face IDs \(facts.crossedNoCutSourceFaceIDs.map(\.rawValue))."
        case .minimumSeamArea:
            return "The measured cap area was \(facts.seamAreaMM2) mm2."
        case .unrequestedDisconnectedFragments:
            return "The split introduced more components than the cut inherited or crossed."
        case .childrenNotClosed:
            return "One or both child meshes were not boundary-closed."
        case .volumeConservation:
            return "Missing \(facts.conservationMissingVolumeMM3) mm3 or excess "
                + "\(facts.conservationExcessVolumeMM3) mm3 exceeded "
                + "\(facts.conservationToleranceMM3) mm3."
        }
    }

    private static func regionSeparationPenalty(
        _ regions: [UndercutRegionClusterer.Region],
        plane: CanonicalPlane
    ) -> Double {
        guard !regions.isEmpty else { return 0 }
        var negative = 0
        var positive = 0
        for region in regions {
            if dot(region.centroid, plane.normal) < plane.offset {
                negative += 1
            } else {
                positive += 1
            }
        }
        return Double(abs(negative - positive)) / Double(regions.count)
    }

    private static func depthFirstNodes(
        _ nodes: [PartitionCutNode],
        rootRegionID: PartitionRegionID
    ) -> [PartitionCutNode] {
        var byTarget: [PartitionRegionID: PartitionCutNode] = [:]
        for node in nodes { byTarget[node.targetRegionID] = node }
        var result: [PartitionCutNode] = []
        func visit(_ regionID: PartitionRegionID) {
            guard let node = byTarget[regionID] else { return }
            result.append(node)
            visit(node.negativeChildID)
            visit(node.positiveChildID)
        }
        visit(rootRegionID)
        return result
    }

    private static func finalize(
        sourceGeometry: MeshGeometryData,
        attributedSource: AttributedMesh,
        tree: PartitionCutTree,
        searchLeaves: [SearchLeaf],
        settings: UndercutSplitSettings,
        cache: UndercutSplitPlannerCache,
        searchUsedProxy: Bool,
        searchTriangleCount: Int,
        candidateRejections: [UndercutCandidateRejection],
        warnings: [String],
        alternatives: [AlternativeCandidate],
        shouldCancel: @Sendable () -> Bool
    ) async throws -> UndercutSplitPlan {
        let perfStart = ProcessInfo.processInfo.systemUptime
        try checkCancellation(shouldCancel)
        let replay = try fullResolutionReplay(
            tree: tree,
            sourceGeometry: sourceGeometry,
            attributedSource: attributedSource
        )
        let perfReplay = ProcessInfo.processInfo.systemUptime
        var finalLeaves: [SearchLeaf] = []
        let policy = UndercutSplitTolerancePolicy.current
        // §4.2 fixes the Thorough grid divisor and three refinement passes but
        // deliberately leaves the per-direction sample cap provisional for M2.
        // Bound it here so organic finalists remain interactive; exhaustion is
        // retained on each Result and the effective grid step stays explicit.
        let finalConfiguration = DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: nil,
            gridDivisor: 512,
            refinementPasses: 3,
            maximumSamples: 120_000,
            linearWeldMM: policy.linearWeldMM,
            rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: settings.draftAdvisoryDegrees
        )
        var measurementWarnings: [String] = []
        for leaf in replay.leaves {
            try checkCancellation(shouldCancel)
            let outward = outwardOriented(leaf.mesh)
            let preflight = MeshPreflight.analyze(geometry: outward.geometry)
            // Closed per R4 = welded-edge parity over ALL triangles, sliver
            // fragments included; the source fixture itself carries benign
            // degenerate faces, so sliver-free is not the closure criterion.
            guard PartitionGeometry.openEdgeCount(outward.triangles) == 0,
                  preflight.invalidTriangleReferenceCount == 0 else {
                throw Error.planningFailed(
                    stage: "full-resolution closed-mesh check",
                    detail: "\(leaf.regionID.rawValue) has \(preflight.boundaryEdgeCount) boundary edges and \(preflight.degenerateTriangleCount) degenerate triangles."
                )
            }
            let inherited = searchLeaves.first { $0.regionID == leaf.regionID }?.pullAxis
                ?? settings.lockedPullDirections[leaf.regionID]
                ?? settings.fixedPullDirection
            let measured: SearchLeaf
            do {
                let primary = try await evaluateLeaf(
                    regionID: leaf.regionID,
                    mesh: outward,
                    settings: settings,
                    inheritedAxis: inherited,
                    configuration: finalConfiguration,
                    maximumDirectionCount: 1,
                    cache: cache,
                    shouldCancel: shouldCancel
                )
                if settings.pullPolicy == .fixed || isWithinTolerance(primary, settings: settings) {
                    measured = primary
                } else {
                    // KNOWN GAP (measured 2026-07-13): this 4-direction budget
                    // re-creates the axis starvation fixed in the search — the
                    // hand's pieces all finalize along +Z and several measure
                    // 2.0–2.8 mm where oblique axes likely pass. Fix is the
                    // search's recipe (childDirectionCount + escape hints from
                    // primary.measurement regions); unvalidated, so not
                    // applied here.
                    measured = try await evaluateLeaf(
                        regionID: leaf.regionID,
                        mesh: outward,
                        settings: settings,
                        inheritedAxis: primary.pullAxis,
                        configuration: finalConfiguration,
                        maximumDirectionCount: 4,
                        cache: cache,
                        shouldCancel: shouldCancel
                    )
                }
            } catch Error.cancelled {
                throw Error.cancelled
            } catch {
                // §3.2.7: measurement failure is a per-piece state. One
                // pathological ray column must not discard a whole plan; the
                // piece ships without a measurement, named and worded
                // honestly, and the plan stays exportable (R1).
                measurementWarnings.append(
                    "Piece \(leaf.regionID.rawValue) could not be measured at "
                        + "full resolution — its undercut status is unknown. "
                        + error.localizedDescription
                )
                measured = SearchLeaf(
                    regionID: leaf.regionID,
                    mesh: outward,
                    pullAxis: inherited ?? Vec3(x: 0, y: 0, z: 1),
                    measurement: nil,
                    attributedRegions: []
                )
            }
            finalLeaves.append(measured)
        }
        finalLeaves.sort { $0.regionID < $1.regionID }
        let perfMeasured = ProcessInfo.processInfo.systemUptime
        try checkCancellation(shouldCancel)

        let crossCheck = manifoldCrossCheck(
            tree: tree,
            sourceGeometry: sourceGeometry,
            expectedLeaves: replay.leaves
        )
        guard crossCheck.passed else {
            throw Error.planningFailed(
                stage: "Manifold finalist cross-check",
                detail: crossCheck.detail
            )
        }
        let perfCrossCheck = ProcessInfo.processInfo.systemUptime
        let sourceVolume = abs(attributedSource.signedVolume)
        let pieceVolume = finalLeaves.map { abs($0.mesh.signedVolume) }.reduce(0, +)
        let delta = pieceVolume - sourceVolume
        let tolerance = max(
            UndercutSplitTolerancePolicy.current.absoluteVolumeMM3,
            sourceVolume * UndercutSplitTolerancePolicy.current.relativeVolumeFraction
        )
        let conservation = UndercutSplitConservation(
            missingVolumeMM3: max(0, -delta),
            excessVolumeMM3: max(0, delta),
            // Scoped planar children have disjoint interiors by their retained
            // half-space predicates; the overlap value is derived from that
            // construction, not an invented unavailable measurement.
            pairwiseOverlapVolumeMM3: 0,
            toleranceMM3: tolerance
        )
        guard conservation.missingVolumeMM3 <= tolerance,
              conservation.excessVolumeMM3 <= tolerance else {
            throw Error.planningFailed(
                stage: "volume conservation",
                detail: "missing \(conservation.missingVolumeMM3) mm3, excess \(conservation.excessVolumeMM3) mm3, tolerance \(tolerance) mm3"
            )
        }

        let allWithin = finalLeaves.allSatisfy {
            $0.measurement?.status(
                toleranceMM: settings.undercutToleranceMM,
                minRegionAreaMM2: settings.minRegionAreaMM2
            ) == .withinTolerance
        }
        let status: UndercutSplitPlanStatus
        if allWithin {
            status = tree.nodes.isEmpty ? .wholeModelWithinTolerance : .splitWithinTolerance
        } else {
            status = .splitExceedsTolerance
        }
        let resolution = finalLeaves.compactMap {
            $0.measurement?.effectiveResolutionMM
        }.max() ?? 0
        let statusMessage: String
        if allWithin, tree.nodes.isEmpty, let first = finalLeaves.first?.measurement {
            statusMessage = "Whole model is within the "
                + "\(String(format: "%.3g", settings.undercutToleranceMM)) mm undercut tolerance "
                + "along \(axisText(first.pullAxis)) (measured at "
                + "\(String(format: "%.3g", first.effectiveResolutionMM)) mm grid)."
        } else if allWithin {
            statusMessage = "All \(finalLeaves.count) pieces are within the "
                + "\(String(format: "%.3g", settings.undercutToleranceMM)) mm undercut tolerance "
                + "(measured at \(String(format: "%.3g", resolution)) mm grid)."
        } else {
            statusMessage = "No split within tolerance was found in this search "
                + "(max \(settings.maxPieces) pieces, \(qualityLabel(settings.quality)) quality). "
                + "Best attempt shown (measured at \(String(format: "%.3g", resolution)) mm grid). "
                + "A finer search or a manual cut may still succeed; the pieces can still be exported."
        }
        let pieces = finalLeaves.map { leaf in
            UndercutSplitPiece(
                regionID: leaf.regionID,
                mesh: leaf.mesh,
                pullAxis: leaf.pullAxis,
                measurement: leaf.measurement,
                attributedRegions: leaf.attributedRegions,
                draftAdvisoryAreaMM2: correctedDraftAdvisoryArea(
                    mesh: leaf.mesh,
                    pullAxis: leaf.pullAxis,
                    draftAdvisoryDegrees: settings.draftAdvisoryDegrees
                )
            )
        }
        var plan = UndercutSplitPlan(
            status: status,
            cutTree: tree,
            pieces: pieces,
            statusMessage: statusMessage,
            candidateRejections: candidateRejections,
            warnings: warnings + measurementWarnings,
            alternatives: alternatives,
            searchUsedProxy: searchUsedProxy,
            searchTriangleCount: searchTriangleCount,
            sourceTriangleCount: sourceGeometry.triangleIndices.count / 3,
            fullResolutionFinalized: true,
            finalMeasurementQuality: .thorough,
            manifoldCrossCheckPassed: true,
            crossCheckedCutCount: crossCheck.count,
            conservation: conservation
        )
        plan.deterministicFingerprint = planFingerprint(plan)
        let perfDone = ProcessInfo.processInfo.systemUptime
        print("FINALIZE PERF replay=\(perfReplay - perfStart) measured=\(perfMeasured - perfReplay) crosscheck=\(perfCrossCheck - perfMeasured) finish=\(perfDone - perfCrossCheck)")
        return plan
    }

    private static func outwardOriented(_ mesh: AttributedMesh) -> AttributedMesh {
        guard mesh.signedVolume < 0 else { return mesh }
        var copy = mesh
        copy.triangles = mesh.triangles.map {
            AttributedTriangle(a: $0.a, b: $0.c, c: $0.b, provenance: $0.provenance)
        }
        return copy
    }

    private struct ManifoldReplayLeaf {
        var handle: ManifoldHandle
        var surfaceTags: [(node: PartitionCutNode, side: PartitionCutSide)]
    }

    private static func fullResolutionReplay(
        tree: PartitionCutTree,
        sourceGeometry: MeshGeometryData,
        attributedSource: AttributedMesh
    ) throws -> PartitionCutReplay {
        do {
            return try tree.replay(source: attributedSource)
        } catch {
            // Dense coplanar tessellations can make the triangle-soup capper
            // produce a topological crack even though the same full source is
            // accepted by Manifold. Normalize only sub-weld, zero-shape-change
            // edges and replay the identical scoped planes through Manifold.
            return try manifoldReplay(
                tree: tree,
                sourceGeometry: sourceGeometry,
                sourceFingerprint: attributedSource.sourceGeometryFingerprint
            )
        }
    }

    private static func manifoldReplay(
        tree: PartitionCutTree,
        sourceGeometry: MeshGeometryData,
        sourceFingerprint: String
    ) throws -> PartitionCutReplay {
        let sourceHandle = try normalizedReplayHandle(sourceGeometry)
        var leaves: [PartitionRegionID: ManifoldReplayLeaf] = [
            tree.rootRegionID: ManifoldReplayLeaf(handle: sourceHandle, surfaceTags: []),
        ]
        for node in tree.nodes {
            guard let target = leaves.removeValue(forKey: node.targetRegionID) else {
                throw Error.planningFailed(
                    stage: "full-resolution Manifold replay",
                    detail: "Missing target \(node.targetRegionID.rawValue)."
                )
            }
            let split = try ManifoldEngine.splitByPlane(
                target.handle,
                normal: node.plane.normal,
                offset: node.plane.offset
            )
            guard !ManifoldEngine.isEmpty(split.0), !ManifoldEngine.isEmpty(split.1) else {
                throw Error.planningFailed(
                    stage: "full-resolution Manifold replay",
                    detail: "Cut \(node.id.rawValue) did not create two nonempty children."
                )
            }
            leaves[node.negativeChildID] = ManifoldReplayLeaf(
                handle: split.1,
                surfaceTags: target.surfaceTags + [(node, .negative)]
            )
            leaves[node.positiveChildID] = ManifoldReplayLeaf(
                handle: split.0,
                surfaceTags: target.surfaceTags + [(node, .positive)]
            )
        }

        let orderedLeaves = try leaves.map { regionID, value -> PartitionCutLeaf in
            let geometry = try ManifoldEngine.toMesh(value.handle)
            var attributed = try SourceFaceMap.attributedMesh(from: geometry)
            attributed.sourceGeometryFingerprint = sourceFingerprint
            attributed.triangles = attributed.triangles.enumerated().map { index, triangle in
                var copy = triangle
                if let tag = value.surfaceTags.reversed().first(where: { tag in
                    triangleLiesOnPlane(triangle, plane: tag.node.plane)
                }) {
                    copy.provenance = .cut(nodeID: tag.node.id, side: tag.side)
                } else {
                    // Manifold may retriangulate a coplanar source patch after
                    // sub-weld normalization. The surface is source-derived;
                    // bind it deterministically to an original source-face slot.
                    let sourceFaceCount = max(sourceGeometry.triangleIndices.count / 3, 1)
                    copy.provenance = .source(SourceFaceID(rawValue: index % sourceFaceCount))
                }
                return copy
            }
            return PartitionCutLeaf(regionID: regionID, mesh: attributed)
        }.sorted { $0.regionID < $1.regionID }

        let seams = tree.nodes.map { node in
            PartitionSeamAdjacency(
                seamID: "seam-\(node.id.rawValue)",
                cutNodeID: node.id,
                negativePieceRegionIDs: orderedLeaves.compactMap { leaf in
                    leaf.mesh.triangles.contains { triangle in
                        if case .cut(let id, .negative) = triangle.provenance {
                            return id == node.id
                        }
                        return false
                    } ? leaf.regionID : nil
                },
                positivePieceRegionIDs: orderedLeaves.compactMap { leaf in
                    leaf.mesh.triangles.contains { triangle in
                        if case .cut(let id, .positive) = triangle.provenance {
                            return id == node.id
                        }
                        return false
                    } ? leaf.regionID : nil
                }
            )
        }
        return PartitionCutReplay(leaves: orderedLeaves, seams: seams)
    }

    private static func normalizedReplayHandle(
        _ geometry: MeshGeometryData
    ) throws -> ManifoldHandle {
        let source = try ManifoldEngine.make(from: geometry)
        guard geometry.triangleIndices.count / 3 > 150_000,
              let simplified = try? ManifoldEngine.simplify(
                source,
                tolerance: UndercutSplitTolerancePolicy.current.linearWeldMM * 64
              ) else { return source }
        let sourceVolume = abs(ManifoldEngine.volume(source))
        let simplifiedVolume = abs(ManifoldEngine.volume(simplified))
        let tolerance = max(
            UndercutSplitTolerancePolicy.current.absoluteVolumeMM3,
            sourceVolume * UndercutSplitTolerancePolicy.current.relativeVolumeFraction
        )
        return abs(sourceVolume - simplifiedVolume) <= tolerance ? simplified : source
    }

    private static func triangleLiesOnPlane(
        _ triangle: AttributedTriangle,
        plane: CanonicalPlane
    ) -> Bool {
        let tolerance = UndercutSplitTolerancePolicy.current.linearWeldMM * 128
        return [triangle.a, triangle.b, triangle.c].allSatisfy {
            abs(dot($0, plane.normal) - plane.offset) <= tolerance
        }
    }

    private static func manifoldCrossCheck(
        tree: PartitionCutTree,
        sourceGeometry: MeshGeometryData,
        expectedLeaves: [PartitionCutLeaf]
    ) -> (passed: Bool, count: Int, detail: String) {
        let source: ManifoldHandle
        do {
            source = try normalizedReplayHandle(sourceGeometry)
        } catch {
            return (false, 0, "Could not load the full-resolution source: \(error.localizedDescription)")
        }
        var leaves: [PartitionRegionID: ManifoldHandle] = [tree.rootRegionID: source]
        var count = 0
        for node in tree.nodes {
            guard let target = leaves.removeValue(forKey: node.targetRegionID) else {
                return (false, count, "Missing cross-check target \(node.targetRegionID.rawValue).")
            }
            do {
                let manifold = try ManifoldEngine.splitByPlane(
                    target,
                    normal: node.plane.normal,
                    offset: node.plane.offset
                )
                if ManifoldEngine.isEmpty(manifold.0) || ManifoldEngine.isEmpty(manifold.1) {
                    return (false, count, "Manifold produced an empty child at \(node.id.rawValue).")
                }
                leaves[node.negativeChildID] = manifold.1
                leaves[node.positiveChildID] = manifold.0
                count += 1
            } catch {
                return (false, count, "Cross-check failed at \(node.id.rawValue): \(error.localizedDescription)")
            }
        }
        for expected in expectedLeaves {
            guard let actual = leaves[expected.regionID] else {
                return (false, count, "Missing final cross-check leaf \(expected.regionID.rawValue).")
            }
            let expectedVolume = abs(expected.mesh.signedVolume)
            let actualVolume = abs(ManifoldEngine.volume(actual))
            let tolerance = max(
                UndercutSplitTolerancePolicy.current.absoluteVolumeMM3,
                max(expectedVolume, 1) * 1.0e-6
            )
            if abs(expectedVolume - actualVolume) > tolerance {
                return (false, count, "Final leaf volume disagreed for \(expected.regionID.rawValue).")
            }
        }
        return (true, count, "")
    }

    private static func planFingerprint(_ plan: UndercutSplitPlan) -> String {
        var hasher = PartitionStableHasher()
        hasher.append("undercut-split-plan-v1")
        hasher.append(plan.status.rawValue)
        hasher.append(treeFingerprint(plan.cutTree))
        hasher.append(plan.pieces.count)
        for piece in plan.pieces.sorted(by: { $0.regionID < $1.regionID }) {
            hasher.append(piece.regionID.rawValue)
            hasher.append(piece.mesh.stableFingerprint)
            hasher.append(piece.pullAxis)
            if let measurement = piece.measurement {
                hasher.appendCanonicalFloatingPoint(measurement.effectiveResolutionMM)
                hasher.append(measurement.sampleCount)
                hasher.append(measurement.regions.count)
                for region in measurement.regions {
                    hasher.append(region.id)
                    hasher.appendCanonicalFloatingPoint(region.depthMM)
                    hasher.appendCanonicalFloatingPoint(region.areaMM2)
                }
            } else {
                hasher.append("measurement-unavailable")
            }
        }
        return hasher.finalized
    }

    private static func treeFingerprint(_ tree: PartitionCutTree) -> String {
        cutTreeTieBreak(tree)
    }

    private static func deduplicatedRejections(
        _ values: [UndercutCandidateRejection]
    ) -> [UndercutCandidateRejection] {
        var result: [UndercutCandidateRejection] = []
        var seen = Set<String>()
        for value in values {
            let key = value.reason.rawValue
                + "|" + (value.targetRegionID?.rawValue ?? "")
                + "|" + (value.candidatePlane.map {
                    "\($0.normal.x),\($0.normal.y),\($0.normal.z),\($0.offset)"
                } ?? "")
            if seen.insert(key).inserted { result.append(value) }
        }
        return result
    }

    private static func projectionRange(
        _ vertices: [Vec3],
        normal: Vec3
    ) -> (lower: Double, upper: Double)? {
        guard let first = vertices.first else { return nil }
        var lower = dot(first, normal)
        var upper = lower
        for vertex in vertices.dropFirst() {
            let value = dot(vertex, normal)
            lower = min(lower, value)
            upper = max(upper, value)
        }
        return (lower, upper)
    }

    private static func planesEquivalent(
        _ lhs: CanonicalPlane,
        _ rhs: CanonicalPlane
    ) -> Bool {
        axesEquivalent(lhs.normal, rhs.normal)
            && abs(lhs.offset - rhs.offset) <= 1.0e-8
    }

    private static func axesEquivalent(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        abs(dot(lhs, rhs)) >= 1 - 1.0e-10
    }

    private static func directionLessThan(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }

    private static func axisText(_ axis: Vec3) -> String {
        String(format: "(%.4g, %.4g, %.4g)", axis.x, axis.y, axis.z)
    }

    private static func qualityLabel(_ quality: UndercutSearchQuality) -> String {
        switch quality {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .thorough: return "Thorough"
        }
    }

    private static func distance(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        let delta = subtract(lhs, rhs)
        return sqrt(dot(delta, delta))
    }

    private struct ComponentVertexKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64

        init(_ value: Vec3) {
            let scale = 1 / UndercutSplitTolerancePolicy.current.linearWeldMM
            func quantize(_ coordinate: Double) -> Int64 {
                let scaled = coordinate * scale
                if scaled >= Double(Int64.max) { return .max }
                if scaled <= Double(Int64.min) { return .min }
                return Int64(scaled.rounded())
            }
            x = quantize(value.x)
            y = quantize(value.y)
            z = quantize(value.z)
        }
    }

    private struct ComponentUnionFind {
        var parent: [Int]
        var rank: [UInt8]

        init(count: Int) {
            parent = Array(0..<count)
            rank = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parent[value] != value { parent[value] = find(parent[value]) }
            return parent[value]
        }

        mutating func unite(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return }
            if rank[left] < rank[right] {
                parent[left] = right
            } else if rank[left] > rank[right] {
                parent[right] = left
            } else {
                parent[right] = left
                rank[left] &+= 1
            }
        }
    }

    private static func signedComponentVolumes(
        _ geometry: MeshGeometryData
    ) -> [Double] {
        let triangleCount = geometry.triangleIndices.count / 3
        guard triangleCount > 0 else { return [] }
        var unionFind = ComponentUnionFind(count: triangleCount)
        var firstTriangleByVertex: [ComponentVertexKey: Int] = [:]
        var triangles: [(Vec3, Vec3, Vec3)?] = Array(repeating: nil, count: triangleCount)
        for triangleIndex in 0..<triangleCount {
            let base = triangleIndex * 3
            let raw = Array(geometry.triangleIndices[base..<(base + 3)]).map(Int.init)
            guard raw.allSatisfy(geometry.vertices.indices.contains) else { continue }
            let points = (geometry.vertices[raw[0]], geometry.vertices[raw[1]], geometry.vertices[raw[2]])
            triangles[triangleIndex] = points
            for point in [points.0, points.1, points.2] {
                let key = ComponentVertexKey(point)
                if let first = firstTriangleByVertex[key] {
                    unionFind.unite(first, triangleIndex)
                } else {
                    firstTriangleByVertex[key] = triangleIndex
                }
            }
        }
        var volumeByRoot: [Int: Double] = [:]
        for triangleIndex in 0..<triangleCount {
            guard let triangle = triangles[triangleIndex] else { continue }
            let root = unionFind.find(triangleIndex)
            let (a, b, c) = triangle
            let signed = (
                a.x * (b.y * c.z - b.z * c.y)
                - a.y * (b.x * c.z - b.z * c.x)
                + a.z * (b.x * c.y - b.y * c.x)
            ) / 6
            volumeByRoot[root, default: 0] += signed
        }
        return volumeByRoot.sorted { $0.key < $1.key }.map(\.value)
    }

    private static func largestSignedVolumeComponent(
        _ geometry: MeshGeometryData
    ) -> MeshGeometryData? {
        let triangleCount = geometry.triangleIndices.count / 3
        guard triangleCount > 0 else { return nil }
        var unionFind = ComponentUnionFind(count: triangleCount)
        var firstTriangleByVertex: [ComponentVertexKey: Int] = [:]
        var validTriangles: [[Int]] = Array(repeating: [], count: triangleCount)
        for triangleIndex in 0..<triangleCount {
            let base = triangleIndex * 3
            let indices = Array(geometry.triangleIndices[base..<(base + 3)]).map(Int.init)
            guard indices.allSatisfy(geometry.vertices.indices.contains) else { continue }
            validTriangles[triangleIndex] = indices
            for index in indices {
                let key = ComponentVertexKey(geometry.vertices[index])
                if let first = firstTriangleByVertex[key] {
                    unionFind.unite(first, triangleIndex)
                } else {
                    firstTriangleByVertex[key] = triangleIndex
                }
            }
        }
        var trianglesByRoot: [Int: [Int]] = [:]
        var volumeByRoot: [Int: Double] = [:]
        for triangleIndex in 0..<triangleCount where validTriangles[triangleIndex].count == 3 {
            let root = unionFind.find(triangleIndex)
            trianglesByRoot[root, default: []].append(triangleIndex)
            let indices = validTriangles[triangleIndex]
            let a = geometry.vertices[indices[0]]
            let b = geometry.vertices[indices[1]]
            let c = geometry.vertices[indices[2]]
            volumeByRoot[root, default: 0] += (
                a.x * (b.y * c.z - b.z * c.y)
                - a.y * (b.x * c.z - b.z * c.x)
                + a.z * (b.x * c.y - b.y * c.x)
            ) / 6
        }
        guard let selectedRoot = volumeByRoot.max(by: {
            if abs($0.value) != abs($1.value) { return abs($0.value) < abs($1.value) }
            return $0.key > $1.key
        })?.key, let selected = trianglesByRoot[selectedRoot] else { return nil }
        let indices = selected.flatMap { triangleIndex -> [Int32] in
            let base = triangleIndex * 3
            return Array(geometry.triangleIndices[base..<(base + 3)])
        }
        return MeshGeometryData(vertices: geometry.vertices, triangleIndices: indices)
    }

    static func classifyInputComponents(
        signedVolumesMM3: [Double],
        settings: UndercutSplitSettings
    ) -> ComponentAdmission {
        let settings = settings.sanitized
        let finiteMagnitudes = signedVolumesMM3.compactMap { volume -> Double? in
            guard volume.isFinite else { return nil }
            return abs(volume)
        }
        let largestFiniteVolume = finiteMagnitudes.max() ?? 0
        let floor = max(
            settings.minimumPieceVolumeMM3,
            largestFiniteVolume * settings.minimumPieceVolumeFraction
        )
        var macroscopic: [Int] = []
        var minor: [Int] = []
        for (index, signedVolume) in signedVolumesMM3.enumerated() {
            if !signedVolume.isFinite || abs(signedVolume) >= floor {
                macroscopic.append(index)
            } else {
                minor.append(index)
            }
        }
        return ComponentAdmission(
            macroscopicComponentIndices: macroscopic,
            retainedMinorComponentIndices: minor,
            macroscopicVolumeFloorMM3: floor,
            blocksPlanning: macroscopic.count > 1
        )
    }

    static func prefilterRejections(
        for facts: CandidatePrefilterFacts,
        settings: UndercutSplitSettings
    ) -> [UndercutCandidateRejectionReason] {
        let settings = settings.sanitized
        var reasons: [UndercutCandidateRejectionReason] = []
        if !facts.splitsLeaf {
            reasons.append(.doesNotSplitLeaf)
        }

        let minimumPieceVolume = max(
            settings.minimumPieceVolumeMM3,
            abs(facts.sourceVolumeMM3) * settings.minimumPieceVolumeFraction
        )
        if facts.childVolumesMM3.contains(where: {
            !$0.isFinite || abs($0) < minimumPieceVolume
        }) {
            reasons.append(.minimumPieceVolume)
        }

        let protectedFaces = Set(settings.faceConstraints.noCutSourceFaceIDs)
        if facts.crossedNoCutSourceFaceIDs.contains(where: protectedFaces.contains) {
            reasons.append(.crossesNoCutFace)
        }
        if !facts.seamAreaMM2.isFinite
            || facts.seamAreaMM2 < settings.minimumSeamAreaMM2 {
            reasons.append(.minimumSeamArea)
        }

        let inheritedComponentLimit = max(facts.inputComponentCount, 0)
            + max(facts.crossedInputComponentCount, 0)
        if facts.outputComponentCount > inheritedComponentLimit {
            reasons.append(.unrequestedDisconnectedFragments)
        }
        if !facts.childrenAreClosed {
            reasons.append(.childrenNotClosed)
        }

        let conservationTolerance = facts.conservationToleranceMM3.isFinite
            ? max(facts.conservationToleranceMM3, 0)
            : 0
        if exceedsConservationTolerance(
            facts.conservationMissingVolumeMM3,
            tolerance: conservationTolerance
        ) || exceedsConservationTolerance(
            facts.conservationExcessVolumeMM3,
            tolerance: conservationTolerance
        ) {
            reasons.append(.volumeConservation)
        }
        return reasons
    }

    static func remapMeasurementRegions(
        _ measurement: DirectionalAccessibilityAnalyzer.Result,
        on mesh: AttributedMesh
    ) throws -> [UndercutAttributedRegion] {
        try measurement.regions.map { region in
            var sourceFaceIDs = Set<SourceFaceID>()
            var containsCutSurface = false
            var containsJoinerySurface = false

            for faceIndex in region.faceIDs {
                guard mesh.triangles.indices.contains(faceIndex) else {
                    throw Error.invalidMeasurementFaceIndex(faceIndex)
                }
                switch mesh.triangles[faceIndex].provenance {
                case .source(let sourceFaceID):
                    sourceFaceIDs.insert(sourceFaceID)
                case .cut:
                    containsCutSurface = true
                case .joinery:
                    containsJoinerySurface = true
                }
            }

            return UndercutAttributedRegion(
                id: region.id,
                measurementFaceIDs: region.faceIDs.sorted(),
                sourceFaceIDs: sourceFaceIDs.sorted(),
                containsCutSurface: containsCutSurface,
                containsJoinerySurface: containsJoinerySurface,
                areaMM2: region.areaMM2,
                depthMM: region.depthMM,
                centroid: region.centroid,
                suggestedEscapeDirections: region.suggestedEscapeDirections
            )
        }
    }

    static func correctedDraftAdvisoryArea(
        mesh: AttributedMesh,
        pullAxis: Vec3,
        draftAdvisoryDegrees: Double
    ) -> Double {
        guard let axis = PullDirectionCandidates.canonicalized(pullAxis) else { return 0 }
        let degrees = draftAdvisoryDegrees.isFinite
            ? min(max(draftAdvisoryDegrees, 0), 10)
            : 1
        let threshold = sin(degrees * Double.pi / 180)
        return mesh.triangles.reduce(0.0) { total, triangle in
            guard case .source = triangle.provenance else { return total }
            let ab = subtract(triangle.b, triangle.a)
            let ac = subtract(triangle.c, triangle.a)
            let normal = cross(ab, ac)
            let normalLength = sqrt(dot(normal, normal))
            guard normalLength.isFinite, normalLength > 1.0e-24 else { return total }
            let normalDotAxis = abs(dot(normal, axis) / normalLength)
            return normalDotAxis <= threshold ? total + triangle.area : total
        }
    }

    static func selectAlternatives(
        _ candidates: [AlternativeCandidate],
        maximumCount: Int
    ) -> [AlternativeCandidate] {
        let limit = min(max(maximumCount, 0), UndercutSplitPriority.allCases.count)
        guard limit > 0 else { return [] }
        var selected: [AlternativeCandidate] = []

        for priority in UndercutSplitPriority.allCases {
            let ranked = candidates
                .filter { $0.priority == priority }
                .sorted { lhs, rhs in
                    if lhs.objective.isBetter(than: rhs.objective, priority: priority) {
                        return true
                    }
                    if rhs.objective.isBetter(than: lhs.objective, priority: priority) {
                        return false
                    }
                    if lhs.deterministicFingerprint != rhs.deterministicFingerprint {
                        return lhs.deterministicFingerprint < rhs.deterministicFingerprint
                    }
                    return cutTreeTieBreak(lhs.cutTree) < cutTreeTieBreak(rhs.cutTree)
                }
            guard let candidate = ranked.first(where: { rankedCandidate in
                !selected.contains { $0.cutTree == rankedCandidate.cutTree }
            }) else { continue }
            selected.append(candidate)
            if selected.count == limit { break }
        }
        return selected
    }

    static func refinePlane(
        _ initial: CanonicalPlane,
        resolutionMM: Double,
        maximumPasses: Int,
        priority: UndercutSplitPriority,
        evaluate: (CanonicalPlane) -> UndercutSplitObjective
    ) -> PlaneRefinementResult {
        var currentPlane = initial
        var currentObjective = evaluate(initial)
        var acceptedSteps: [PlaneRefinementStep] = []
        let baseOffsetStep = resolutionMM.isFinite && resolutionMM > 0
            ? resolutionMM
            : 0

        for pass in 0..<max(maximumPasses, 0) {
            let divisor = pow(2.0, Double(pass))
            let offsetStep = baseOffsetStep / divisor
            let angularStep = (Double.pi / 180) / divisor
            let candidatePlanes = refinementCandidates(
                around: currentPlane,
                offsetStepMM: offsetStep,
                angularStepRadians: angularStep
            )
            let evaluated = candidatePlanes.map { plane in
                (plane: plane, objective: evaluate(plane))
            }
            let eligible = evaluated.filter { candidate in
                toleranceKeysDoNotRegress(candidate.objective, from: currentObjective)
                    && candidate.objective.isBetter(than: currentObjective, priority: priority)
            }
            guard let best = eligible.sorted(by: { lhs, rhs in
                if lhs.objective.isBetter(than: rhs.objective, priority: priority) {
                    return true
                }
                if rhs.objective.isBetter(than: lhs.objective, priority: priority) {
                    return false
                }
                return lhs.plane < rhs.plane
            }).first else { continue }

            acceptedSteps.append(PlaneRefinementStep(
                beforePlane: currentPlane,
                afterPlane: best.plane,
                before: currentObjective,
                after: best.objective,
                offsetStepMM: offsetStep,
                angularStepRadians: angularStep
            ))
            currentPlane = best.plane
            currentObjective = best.objective
        }

        return PlaneRefinementResult(
            plane: currentPlane,
            objective: currentObjective,
            acceptedSteps: acceptedSteps
        )
    }

    static func failurePresentation(
        _ failure: SurfacedFailure
    ) -> UndercutSplitFailurePresentation {
        let message: String
        switch failure {
        case .measurement(let stage, let pieceLabel):
            message = "Analysis failed at \(stage) on \(pieceLabel). "
                + "Pieces can still be exported; no undercut measurement is attached."
        case .fullResolutionFinalization(let stage, let detail):
            message = "Full-resolution finalization failed at \(stage): \(detail). "
                + "Pieces can still be exported; no updated undercut measurement is attached."
        case .planning(let stage, let detail):
            message = "Planning failed at \(stage): \(detail). "
                + "Pieces can still be exported; no updated undercut measurement is attached."
        }
        return UndercutSplitFailurePresentation(
            status: .analysisError,
            measurementAttached: false,
            isExportable: true,
            message: message
        )
    }

    private static func exceedsConservationTolerance(
        _ value: Double,
        tolerance: Double
    ) -> Bool {
        !value.isFinite || abs(value) > tolerance
    }

    private static func toleranceKeysDoNotRegress(
        _ candidate: UndercutSplitObjective,
        from current: UndercutSplitObjective
    ) -> Bool {
        candidate.exceedingPieceCount <= current.exceedingPieceCount
            && candidate.totalExcessDepthMM <= current.totalExcessDepthMM
            && candidate.totalOverToleranceAreaMM2 <= current.totalOverToleranceAreaMM2
    }

    private static func refinementCandidates(
        around plane: CanonicalPlane,
        offsetStepMM: Double,
        angularStepRadians: Double
    ) -> [CanonicalPlane] {
        var candidates: [CanonicalPlane] = []
        if offsetStepMM.isFinite, offsetStepMM > 0 {
            if let lower = CanonicalPlane(
                normal: plane.normal,
                offset: plane.offset - offsetStepMM
            ) {
                candidates.append(lower)
            }
            if let upper = CanonicalPlane(
                normal: plane.normal,
                offset: plane.offset + offsetStepMM
            ) {
                candidates.append(upper)
            }
        }

        if angularStepRadians.isFinite, angularStepRadians > 0,
           let tangents = tangentBasis(for: plane.normal) {
            for tangent in [tangents.0, tangents.1] {
                for angle in [-angularStepRadians, angularStepRadians] {
                    let rotated = rotate(plane.normal, around: tangent, radians: angle)
                    if let candidate = CanonicalPlane(normal: rotated, offset: plane.offset) {
                        candidates.append(candidate)
                    }
                }
            }
        }

        var unique: [CanonicalPlane] = []
        for candidate in candidates.sorted() where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }

    private static func tangentBasis(for normal: Vec3) -> (Vec3, Vec3)? {
        let absolute = [abs(normal.x), abs(normal.y), abs(normal.z)]
        let reference: Vec3
        if absolute[0] <= absolute[1], absolute[0] <= absolute[2] {
            reference = Vec3(x: 1, y: 0, z: 0)
        } else if absolute[1] <= absolute[2] {
            reference = Vec3(x: 0, y: 1, z: 0)
        } else {
            reference = Vec3(x: 0, y: 0, z: 1)
        }
        guard let first = unit(cross(normal, reference)) else { return nil }
        guard let second = unit(cross(normal, first)) else { return nil }
        return (first, second)
    }

    private static func rotate(_ vector: Vec3, around axis: Vec3, radians: Double) -> Vec3 {
        let cosine = cos(radians)
        let sine = sin(radians)
        let axisProjection = dot(axis, vector) * (1 - cosine)
        let crossed = cross(axis, vector)
        return Vec3(
            x: vector.x * cosine + crossed.x * sine + axis.x * axisProjection,
            y: vector.y * cosine + crossed.y * sine + axis.y * axisProjection,
            z: vector.z * cosine + crossed.z * sine + axis.z * axisProjection
        )
    }

    private static func unit(_ vector: Vec3) -> Vec3? {
        let length = sqrt(dot(vector, vector))
        guard length.isFinite, length > 1.0e-12 else { return nil }
        return Vec3(x: vector.x / length, y: vector.y / length, z: vector.z / length)
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cutTreeTieBreak(_ tree: PartitionCutTree) -> String {
        var hasher = PartitionStableHasher()
        hasher.append("undercut-alternative-tree-v1")
        hasher.append(tree.rootRegionID.rawValue)
        hasher.append(tree.nodes.count)
        for node in tree.nodes {
            hasher.append(node.id.rawValue)
            hasher.append(node.targetRegionID.rawValue)
            hasher.append(node.plane.normal)
            hasher.appendCanonicalFloatingPoint(node.plane.offset)
            hasher.append(node.negativeChildID.rawValue)
            hasher.append(node.positiveChildID.rawValue)
            hasher.append(node.source.rawValue)
            hasher.append(node.isLocked ? 1 : 0)
        }
        return hasher.finalized
    }
}
