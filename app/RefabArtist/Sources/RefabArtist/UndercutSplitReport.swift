import Foundation

/// Source-topology facts carried into the export report without changing the
/// planner's closed-solid admission semantics. The fingerprint and basis make
/// it explicit which source buffer was counted, including retained-plan exports
/// where the live source may have changed after planning.
struct UndercutSourcePreflightFacts: Codable, Equatable {
    enum Basis: String, Codable, Equatable {
        case planTimeSource
        case suppliedSourceAtExport
    }

    var basis: Basis
    var sourceGeometryFingerprint: String
    var triangleCount: Int
    var uniqueVertexCount: Int
    var duplicateVertexObservationCount: Int
    var invalidTriangleReferenceCount: Int
    var degenerateTriangleCount: Int
    var boundaryEdgeCount: Int
    var nonManifoldEdgeCount: Int
    /// `nil` means the supplied triangle soup did not carry an external
    /// Manifold-validation fact. It must not be cosmetically reported as false.
    var manifoldValidated: Bool?

    static func measure(
        geometry: MeshGeometryData,
        basis: Basis = .suppliedSourceAtExport,
        manifoldValidated: Bool? = nil
    ) -> UndercutSourcePreflightFacts {
        let report = MeshPreflight.analyze(geometry: geometry)
        return UndercutSourcePreflightFacts(
            basis: basis,
            sourceGeometryFingerprint: SourceFaceMap.geometryFingerprint(of: geometry),
            triangleCount: geometry.triangleIndices.count / 3,
            uniqueVertexCount: report.uniqueVertexCount,
            duplicateVertexObservationCount: report.duplicateVertexObservationCount,
            invalidTriangleReferenceCount: report.invalidTriangleReferenceCount,
            degenerateTriangleCount: report.degenerateTriangleCount,
            boundaryEdgeCount: report.boundaryEdgeCount,
            nonManifoldEdgeCount: report.nonManifoldEdgeCount,
            manifoldValidated: manifoldValidated
        )
    }
}

/// Schema-versioned, deterministic export facts for Split by Undercuts.
///
/// The report records measured results and advisories. It is not an export
/// eligibility object: any plan with at least one piece remains exportable.
struct UndercutSplitReport: Codable, Equatable {
    static let currentSchemaVersion = 1

    struct Versions: Codable, Equatable {
        var app: String
        var planner: Int
        var tolerancePolicy: Int
    }

    struct Bounds: Codable, Equatable {
        var min: Vec3
        var max: Vec3
    }

    struct Source: Codable, Equatable {
        var fingerprint: String
        var units: String
        var bounds: Bounds?
        var volumeMM3: Double?
        var preflight: UndercutSourcePreflightFacts
    }

    struct LockedPullDirection: Codable, Equatable {
        var regionID: String
        var direction: Vec3
    }

    struct SeamKeySnapshot: Codable, Equatable {
        var type: String
        var pinSettings: PartitionKeySettings?
    }

    struct SettingsSnapshot: Codable, Equatable {
        var planningMode: UndercutPlanningMode
        var pullPolicy: PullDirectionPolicy
        var fixedPullDirection: Vec3?
        var undercutToleranceMM: Double
        var minRegionAreaMM2: Double
        var quality: UndercutSearchQuality
        var maxPieces: Int
        var priority: UndercutSplitPriority
        var draftAdvisoryDegrees: Double
        var minimumPieceVolumeFraction: Double
        var minimumPieceVolumeMM3: Double
        var minimumSeamAreaMM2: Double
        var seamKeys: SeamKeySnapshot
        var faceConstraints: PartitionFaceConstraints
        var lockedPullDirections: [LockedPullDirection]
        var authoredCutTree: PersistedCutTreeEnvelope?
        var seed: Int64
        var output: PartitionExporter.UndercutOutput

        init(
            _ rawSettings: UndercutSplitSettings,
            output: PartitionExporter.UndercutOutput
        ) {
            let settings = rawSettings.sanitized
            planningMode = settings.planningMode
            pullPolicy = settings.pullPolicy
            fixedPullDirection = settings.fixedPullDirection
            undercutToleranceMM = settings.undercutToleranceMM
            minRegionAreaMM2 = settings.minRegionAreaMM2
            quality = settings.quality
            maxPieces = settings.maxPieces
            priority = settings.priority
            draftAdvisoryDegrees = settings.draftAdvisoryDegrees
            minimumPieceVolumeFraction = settings.minimumPieceVolumeFraction
            minimumPieceVolumeMM3 = settings.minimumPieceVolumeMM3
            minimumSeamAreaMM2 = settings.minimumSeamAreaMM2
            switch settings.seamKeys {
            case .none:
                seamKeys = SeamKeySnapshot(type: "none", pinSettings: nil)
            case .pins(let pinSettings):
                seamKeys = SeamKeySnapshot(type: "pins", pinSettings: pinSettings)
            }
            faceConstraints = settings.faceConstraints
            lockedPullDirections = settings.lockedPullDirections
                .map { LockedPullDirection(regionID: $0.key.rawValue, direction: $0.value) }
                .sorted { $0.regionID < $1.regionID }
            authoredCutTree = settings.authoredCutTree
            seed = settings.seed
            self.output = output
        }
    }

    struct SeamAdjacency: Codable, Equatable {
        var seamID: String
        var cutNodeID: String
        var negativePieceIDs: [String]
        var positivePieceIDs: [String]
    }

    struct Region: Codable, Equatable {
        var id: String
        var depthMM: Double?
        var areaMM2: Double?
        var faceCount: Int
        var relationToTolerance: String
        var filteredByArea: Bool
    }

    struct Piece: Codable, Equatable {
        var id: String
        var name: String
        var color: String
        var meshHash: String
        var volumeMM3: Double?
        var bounds: Bounds?
        var pullAxis: Vec3
        var status: String
        var measuredAtResolutionMM: Double?
        var regions: [Region]
        var draftAdvisoryAreaMM2: Double?
    }

    struct Conservation: Codable, Equatable {
        var availability: UndercutSplitConservation.Availability
        var missingVolumeMM3: Double?
        var excessVolumeMM3: Double?
        var pairwiseOverlapVolumeMM3: Double?
        var toleranceMM3: Double?
    }

    struct AssemblyStep: Codable, Equatable {
        var order: Int
        var movingPieceIDs: [String]
        var movingPieceNames: [String]
        var direction: Vec3
        var matingSeamID: String
        var pinCount: Int
        var suggestedDistanceMM: Double
    }

    var schemaVersion: Int
    var versions: Versions
    var source: Source
    var settings: SettingsSnapshot
    var cutTree: PartitionCutTree
    var seamAdjacency: [SeamAdjacency]
    var pieces: [Piece]
    var conservation: Conservation
    var assemblySteps: [AssemblyStep]
    var overallStatus: UndercutSplitPlanStatus
    var overallStatusMessage: String
    var warnings: [String]

    static func make(
        plan: UndercutSplitPlan,
        settings rawSettings: UndercutSplitSettings,
        sourceGeometry: MeshGeometryData,
        output: PartitionExporter.UndercutOutput = .separateSTLZip,
        sourcePreflightFacts suppliedPreflightFacts: UndercutSourcePreflightFacts? = nil,
        additionalWarnings: [String] = [],
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
    ) -> UndercutSplitReport {
        let settings = rawSettings.sanitized
        let orderedPieces = plan.pieces.sorted { $0.regionID < $1.regionID }
        let namesByRegion = pieceNames(for: orderedPieces.map(\.regionID))
        let colorsByRegion = pieceColors(for: orderedPieces.map(\.regionID))
        let leafIDs = Set(orderedPieces.map(\.regionID))
        let seams = seamFacts(tree: plan.cutTree, leafIDs: leafIDs)
        let measuredSourceFingerprint = SourceFaceMap.geometryFingerprint(of: sourceGeometry)
        let sourceFingerprint = orderedPieces.first?.mesh.sourceGeometryFingerprint
            ?? measuredSourceFingerprint
        let suppliedSourceMatches = measuredSourceFingerprint == sourceFingerprint
        let sourcePreflightFacts = suppliedPreflightFacts ?? UndercutSourcePreflightFacts.measure(
            geometry: sourceGeometry
        )

        let reportPieces = orderedPieces.map { piece -> Piece in
            let measurement = piece.measurement
            let regions = (measurement?.regions ?? []).sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.faceIDs.lexicographicallyPrecedes(rhs.faceIDs)
            }.map { region in
                let depth = finite(region.depthMM)
                let area = finite(region.areaMM2)
                return Region(
                    id: region.id,
                    depthMM: depth,
                    areaMM2: area,
                    faceCount: region.faceIDs.count,
                    relationToTolerance: (depth ?? .infinity) > settings.undercutToleranceMM
                        ? "overTolerance"
                        : "withinTolerance",
                    filteredByArea: (area ?? -.infinity) < settings.minRegionAreaMM2
                )
            }
            let pieceStatus: String
            if let measurement {
                pieceStatus = measurement.status(
                    toleranceMM: settings.undercutToleranceMM,
                    minRegionAreaMM2: settings.minRegionAreaMM2
                ).rawValue
            } else {
                pieceStatus = "measurementUnavailable"
            }
            return Piece(
                id: piece.regionID.rawValue,
                name: namesByRegion[piece.regionID] ?? piece.regionID.rawValue,
                color: colorsByRegion[piece.regionID] ?? "#808080",
                meshHash: piece.mesh.stableFingerprint,
                volumeMM3: finite(abs(piece.mesh.signedVolume)),
                bounds: bounds(of: piece.mesh.geometry),
                pullAxis: piece.pullAxis,
                status: pieceStatus,
                measuredAtResolutionMM: measurement.flatMap { finite($0.effectiveResolutionMM) },
                regions: regions,
                draftAdvisoryAreaMM2: finite(piece.draftAdvisoryAreaMM2)
            )
        }

        let reportStatus = overallStatus(
            pieces: reportPieces,
            hasCuts: !plan.cutTree.nodes.isEmpty
        )
        let reportStatusMessage = statusMessage(
            status: reportStatus,
            plan: plan,
            settings: settings,
            pieces: reportPieces
        )
        let statusWarning: [String]
        switch reportStatus {
        case .splitExceedsTolerance, .analysisError:
            statusWarning = reportStatusMessage.isEmpty ? [] : [reportStatusMessage]
        case .wholeModelWithinTolerance, .splitWithinTolerance:
            statusWarning = []
        }
        let preflightWarning: [String]
        if sourcePreflightFacts.sourceGeometryFingerprint == sourceFingerprint {
            preflightWarning = []
        } else {
            preflightWarning = [
                "Source preflight counts describe the geometry supplied at export; "
                    + "its fingerprint differs from the retained plan source because "
                    + "plan-time preflight facts were not retained."
            ]
        }
        let warnings = stableUnique(
            plan.warnings + statusWarning + preflightWarning + additionalWarnings
        )
        let conservation = Conservation(
            availability: plan.conservation.availability,
            missingVolumeMM3: finite(plan.conservation.missingVolumeMM3),
            excessVolumeMM3: finite(plan.conservation.excessVolumeMM3),
            pairwiseOverlapVolumeMM3: finite(plan.conservation.pairwiseOverlapVolumeMM3),
            toleranceMM3: finite(plan.conservation.toleranceMM3)
        )
        let reportedSourceBounds = suppliedSourceMatches
            ? bounds(of: sourceGeometry)
            : unionBounds(reportPieces.compactMap(\.bounds))
        let reportedSourceVolume: Double?
        if suppliedSourceMatches {
            reportedSourceVolume = finite(abs(signedVolume(of: sourceGeometry)))
        } else if reportPieces.allSatisfy({ $0.volumeMM3 != nil }) {
            let pieceVolume = reportPieces.compactMap(\.volumeMM3).reduce(0, +)
            reportedSourceVolume = finite(
                pieceVolume
                    + (conservation.missingVolumeMM3 ?? 0)
                    - (conservation.excessVolumeMM3 ?? 0)
            )
        } else {
            reportedSourceVolume = nil
        }

        return UndercutSplitReport(
            schemaVersion: currentSchemaVersion,
            versions: Versions(
                app: appVersion,
                planner: settings.plannerVersion,
                tolerancePolicy: settings.tolerancePolicyVersion
            ),
            source: Source(
                fingerprint: sourceFingerprint,
                units: "millimeters",
                bounds: reportedSourceBounds,
                volumeMM3: reportedSourceVolume,
                preflight: sourcePreflightFacts
            ),
            settings: SettingsSnapshot(settings, output: output),
            cutTree: plan.cutTree,
            seamAdjacency: seams,
            pieces: reportPieces,
            conservation: conservation,
            assemblySteps: assemblySteps(
                tree: plan.cutTree,
                seams: seams,
                namesByRegion: namesByRegion,
                pinCountBySeam: pinCountsBySeam(in: orderedPieces),
                sourceBounds: reportedSourceBounds
            ),
            overallStatus: reportStatus,
            overallStatusMessage: reportStatusMessage,
            warnings: warnings
        )
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0a)
        return data
    }

    var worstMeasuredDepthMM: Double? {
        guard pieces.contains(where: { $0.measuredAtResolutionMM != nil }) else { return nil }
        return pieces.flatMap(\.regions).compactMap(\.depthMM).max() ?? 0
    }

    var effectiveMeasurementResolutionMM: Double? {
        pieces.compactMap(\.measuredAtResolutionMM).max()
    }

    // MARK: - One measured acceptance decision path

    private static func overallStatus(
        pieces: [Piece],
        hasCuts: Bool
    ) -> UndercutSplitPlanStatus {
        guard !pieces.isEmpty,
              pieces.allSatisfy({ $0.measuredAtResolutionMM != nil }) else {
            return .analysisError
        }
        let allWithinTolerance = pieces.allSatisfy { $0.status == "withinTolerance" }
        guard allWithinTolerance else { return .splitExceedsTolerance }
        return hasCuts ? .splitWithinTolerance : .wholeModelWithinTolerance
    }

    private static func statusMessage(
        status: UndercutSplitPlanStatus,
        plan: UndercutSplitPlan,
        settings: UndercutSplitSettings,
        pieces: [Piece]
    ) -> String {
        let tolerance = statusNumber(settings.undercutToleranceMM)
        let resolution = pieces.compactMap(\.measuredAtResolutionMM).max().map {
            statusNumber($0)
        }
        switch status {
        case .wholeModelWithinTolerance:
            guard let piece = pieces.first, let resolution else {
                return "Analysis failed before an undercut measurement was attached. "
                    + "Pieces can still be exported."
            }
            return "Whole model is within the \(tolerance) mm undercut tolerance along "
                + "\(axisText(piece.pullAxis)) (measured at \(resolution) mm grid)."
        case .splitWithinTolerance:
            guard let resolution else {
                return "Analysis failed before an undercut measurement was attached. "
                    + "Pieces can still be exported."
            }
            return "All \(pieces.count) pieces are within the \(tolerance) mm undercut tolerance "
                + "(measured at \(resolution) mm grid)."
        case .splitExceedsTolerance:
            guard let resolution else {
                return "Analysis failed before an undercut measurement was attached. "
                    + "Pieces can still be exported."
            }
            return "No split within tolerance was found in this search "
                + "(max \(settings.maxPieces) pieces, \(qualityLabel(settings.quality)) quality). "
                + "Best attempt shown (measured at \(resolution) mm grid). "
                + "A finer search or a manual cut may still succeed; the pieces can still be exported."
        case .analysisError:
            if !plan.statusMessage.isEmpty { return plan.statusMessage }
            return "Analysis failed before an undercut measurement was attached. "
                + "Pieces can still be exported."
        }
    }

    private static func qualityLabel(_ quality: UndercutSearchQuality) -> String {
        switch quality {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .thorough: return "Thorough"
        }
    }

    private static func axisText(_ axis: Vec3) -> String {
        "(\(statusNumber(axis.x)), \(statusNumber(axis.y)), \(statusNumber(axis.z)))"
    }

    private static func statusNumber(_ value: Double) -> String {
        String(format: "%.3g", value)
    }

    // MARK: - Deterministic identities and assembly facts

    static func pieceNames(for regionIDs: [PartitionRegionID]) -> [PartitionRegionID: String] {
        Dictionary(uniqueKeysWithValues: regionIDs.sorted().enumerated().map { index, regionID in
            (regionID, "Piece \(alphabeticLabel(index))")
        })
    }

    private static func pieceColors(for regionIDs: [PartitionRegionID]) -> [PartitionRegionID: String] {
        let palette = [
            "#4E79A7", "#F28E2B", "#59A14F", "#E15759",
            "#B07AA1", "#76B7B2", "#EDC948", "#9C755F",
        ]
        return Dictionary(uniqueKeysWithValues: regionIDs.sorted().enumerated().map { index, regionID in
            (regionID, palette[index % palette.count])
        })
    }

    private static func alphabeticLabel(_ zeroBasedIndex: Int) -> String {
        var value = max(zeroBasedIndex, 0) + 1
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(65 + value % 26)!
            result.insert(Character(scalar), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static func seamFacts(
        tree: PartitionCutTree,
        leafIDs: Set<PartitionRegionID>
    ) -> [SeamAdjacency] {
        tree.nodes.map { node in
            SeamAdjacency(
                seamID: "seam-\(node.id.rawValue)",
                cutNodeID: node.id.rawValue,
                negativePieceIDs: descendantLeaves(
                    from: node.negativeChildID,
                    tree: tree,
                    leafIDs: leafIDs
                ).map(\.rawValue),
                positivePieceIDs: descendantLeaves(
                    from: node.positiveChildID,
                    tree: tree,
                    leafIDs: leafIDs
                ).map(\.rawValue)
            )
        }
    }

    private static func descendantLeaves(
        from regionID: PartitionRegionID,
        tree: PartitionCutTree,
        leafIDs: Set<PartitionRegionID>
    ) -> [PartitionRegionID] {
        if leafIDs.contains(regionID) { return [regionID] }
        guard let node = tree.nodes.first(where: { $0.targetRegionID == regionID }) else {
            return []
        }
        return (
            descendantLeaves(from: node.negativeChildID, tree: tree, leafIDs: leafIDs)
                + descendantLeaves(from: node.positiveChildID, tree: tree, leafIDs: leafIDs)
        ).sorted()
    }

    private static func assemblySteps(
        tree: PartitionCutTree,
        seams: [SeamAdjacency],
        namesByRegion: [PartitionRegionID: String],
        pinCountBySeam: [String: Int],
        sourceBounds: Bounds?
    ) -> [AssemblyStep] {
        let seamByNode = Dictionary(uniqueKeysWithValues: seams.map { ($0.cutNodeID, $0) })
        let distance = suggestedDistance(sourceBounds)
        return tree.nodes.reversed().enumerated().compactMap { index, node in
            guard let seam = seamByNode[node.id.rawValue] else { return nil }
            let movingIDs = seam.positivePieceIDs.sorted()
            let movingNames = movingIDs.compactMap {
                namesByRegion[PartitionRegionID(rawValue: $0)]
            }
            return AssemblyStep(
                order: index + 1,
                movingPieceIDs: movingIDs,
                movingPieceNames: movingNames,
                direction: Vec3(
                    x: -node.plane.normal.x,
                    y: -node.plane.normal.y,
                    z: -node.plane.normal.z
                ),
                matingSeamID: seam.seamID,
                pinCount: pinCountBySeam[seam.seamID] ?? 0,
                suggestedDistanceMM: distance
            )
        }
    }

    private static func pinCountsBySeam(
        in pieces: [UndercutSplitPiece]
    ) -> [String: Int] {
        var featureIDsBySeam: [String: Set<String>] = [:]
        for triangle in pieces.flatMap(\.mesh.triangles) {
            guard case .joinery(let seamID, let featureID) = triangle.provenance else {
                continue
            }
            featureIDsBySeam[seamID, default: []].insert(featureID)
        }
        return featureIDsBySeam.mapValues(\.count)
    }

    private static func suggestedDistance(_ bounds: Bounds?) -> Double {
        guard let bounds else { return 10 }
        let dx = bounds.max.x - bounds.min.x
        let dy = bounds.max.y - bounds.min.y
        let dz = bounds.max.z - bounds.min.z
        let diagonal = sqrt(dx * dx + dy * dy + dz * dz)
        return max(10, diagonal * 0.25)
    }

    private static func bounds(of geometry: MeshGeometryData) -> Bounds? {
        let finiteVertices = geometry.vertices.filter {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }
        guard let first = finiteVertices.first else { return nil }
        var minimum = first
        var maximum = first
        for vertex in finiteVertices.dropFirst() {
            minimum = Vec3(
                x: min(minimum.x, vertex.x),
                y: min(minimum.y, vertex.y),
                z: min(minimum.z, vertex.z)
            )
            maximum = Vec3(
                x: max(maximum.x, vertex.x),
                y: max(maximum.y, vertex.y),
                z: max(maximum.z, vertex.z)
            )
        }
        return Bounds(min: minimum, max: maximum)
    }

    private static func unionBounds(_ values: [Bounds]) -> Bounds? {
        guard let first = values.first else { return nil }
        return values.dropFirst().reduce(first) { result, value in
            Bounds(
                min: Vec3(
                    x: min(result.min.x, value.min.x),
                    y: min(result.min.y, value.min.y),
                    z: min(result.min.z, value.min.z)
                ),
                max: Vec3(
                    x: max(result.max.x, value.max.x),
                    y: max(result.max.y, value.max.y),
                    z: max(result.max.z, value.max.z)
                )
            )
        }
    }

    private static func signedVolume(of geometry: MeshGeometryData) -> Double {
        var result = 0.0
        var cursor = 0
        while cursor + 2 < geometry.triangleIndices.count {
            let ia = Int(geometry.triangleIndices[cursor])
            let ib = Int(geometry.triangleIndices[cursor + 1])
            let ic = Int(geometry.triangleIndices[cursor + 2])
            cursor += 3
            guard geometry.vertices.indices.contains(ia),
                  geometry.vertices.indices.contains(ib),
                  geometry.vertices.indices.contains(ic) else { continue }
            let a = geometry.vertices[ia]
            let b = geometry.vertices[ib]
            let c = geometry.vertices[ic]
            result += (
                a.x * (b.y * c.z - b.z * c.y)
                    - a.y * (b.x * c.z - b.z * c.x)
                    + a.z * (b.x * c.y - b.y * c.x)
            ) / 6
        }
        return result
    }

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
