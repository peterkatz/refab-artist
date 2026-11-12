import Foundation

/// Measures trapped material intervals along one undirected pull axis.
///
/// The ray-event construction is adapted into Partition-owned code from the
/// low-level triangle math in `MoldUndercutAnalyzer`. No mold type or mold
/// implementation is imported, called, or modified.
enum DirectionalAccessibilityAnalyzer {
    struct Configuration: Equatable {
        var targetGridStepMM: Double?
        var gridDivisor: Double
        var refinementPasses: Int
        var maximumSamples: Int
        var linearWeldMM: Double
        var rayHitCoincidenceMM: Double
        var minimumTriangleAreaMM2: Double
        var draftAdvisoryDegrees: Double

        init(
            targetGridStepMM: Double? = nil,
            gridDivisor: Double = 256,
            refinementPasses: Int,
            maximumSamples: Int,
            linearWeldMM: Double = 1.0e-6,
            rayHitCoincidenceMM: Double,
            minimumTriangleAreaMM2: Double,
            draftAdvisoryDegrees: Double = 1
        ) {
            self.targetGridStepMM = targetGridStepMM
            self.gridDivisor = gridDivisor
            self.refinementPasses = refinementPasses
            self.maximumSamples = maximumSamples
            self.linearWeldMM = linearWeldMM
            self.rayHitCoincidenceMM = rayHitCoincidenceMM
            self.minimumTriangleAreaMM2 = minimumTriangleAreaMM2
            self.draftAdvisoryDegrees = draftAdvisoryDegrees
        }

        /// Deterministic count budgets are explicit because §4.2 does not yet
        /// assign per-direction sample counts. These provisional values must be
        /// benchmark-locked in M2; they are never wall-clock limits.
        init(
            quality: UndercutSearchQuality,
            tolerancePolicy: UndercutSplitTolerancePolicy = .current,
            draftAdvisoryDegrees: Double = 1
        ) {
            switch quality {
            case .quick:
                gridDivisor = 128
                refinementPasses = 1
                maximumSamples = 80_000
            case .standard:
                gridDivisor = 256
                refinementPasses = 2
                maximumSamples = 240_000
            case .thorough:
                gridDivisor = 512
                refinementPasses = 3
                maximumSamples = 720_000
            }
            targetGridStepMM = nil
            linearWeldMM = tolerancePolicy.linearWeldMM
            rayHitCoincidenceMM = tolerancePolicy.rayHitCoincidenceMM
            minimumTriangleAreaMM2 = tolerancePolicy.minimumTriangleAreaMM2
            self.draftAdvisoryDegrees = draftAdvisoryDegrees
        }

        var sanitized: Configuration {
            var result = self
            if let step = targetGridStepMM {
                result.targetGridStepMM = step.isFinite ? min(max(step, 0.2), 2.0) : nil
            }
            result.gridDivisor = gridDivisor.isFinite ? max(gridDivisor, 1) : 256
            result.refinementPasses = min(max(refinementPasses, 0), 8)
            result.maximumSamples = max(maximumSamples, 1)
            result.linearWeldMM = linearWeldMM.isFinite ? max(linearWeldMM, 1.0e-12) : 1.0e-6
            result.rayHitCoincidenceMM = rayHitCoincidenceMM.isFinite
                ? max(rayHitCoincidenceMM, 1.0e-12)
                : 1.0e-7
            result.minimumTriangleAreaMM2 = minimumTriangleAreaMM2.isFinite
                ? max(minimumTriangleAreaMM2, 0)
                : 1.0e-12
            result.draftAdvisoryDegrees = draftAdvisoryDegrees.isFinite
                ? min(max(draftAdvisoryDegrees, 0), 10)
                : 1
            return result
        }
    }

    struct MaterialInterval: Codable, Equatable {
        let lower: Double
        let upper: Double

        init(lower: Double, upper: Double) {
            self.lower = lower
            self.upper = upper
        }

        var thickness: Double { max(0, upper - lower) }
    }

    enum PieceStatus: String, Codable, Equatable {
        case withinTolerance
        case exceedsTolerance
    }

    struct Result: Codable, Equatable {
        let pullAxis: Vec3
        let regions: [UndercutRegionClusterer.Region]
        let baseResolutionMM: Double
        let effectiveResolutionMM: Double
        let sampleCount: Int
        let maximumSamples: Int
        let violatingColumnCount: Int
        let sampleBudgetExhausted: Bool
        let discardedDegenerateTriangleCount: Int
        let nearVerticalWallAreaMM2: Double

        var worstDepthMM: Double { regions.map(\.depthMM).max() ?? 0 }

        func status(toleranceMM: Double, minRegionAreaMM2: Double) -> PieceStatus {
            let tolerance = toleranceMM.isFinite ? max(toleranceMM, 0) : 0
            let minimumArea = minRegionAreaMM2.isFinite ? max(minRegionAreaMM2, 0) : 0
            return regions.contains { region in
                region.areaMM2 >= minimumArea && region.depthMM > tolerance
            } ? .exceedsTolerance : .withinTolerance
        }

        func measuredStatus(toleranceMM: Double, minRegionAreaMM2: Double) -> String {
            let formattedTolerance = String(format: "%.3g", max(toleranceMM, 0))
            let formattedResolution = String(format: "%.3g", effectiveResolutionMM)
            let measurement = "measured at \(formattedResolution) mm grid; \(sampleCount) columns"
            switch status(toleranceMM: toleranceMM, minRegionAreaMM2: minRegionAreaMM2) {
            case .withinTolerance:
                return "Model is within the \(formattedTolerance) mm undercut tolerance along "
                    + "\(Self.axisText(pullAxis)) (\(measurement))."
            case .exceedsTolerance:
                let formattedDepth = String(format: "%.3g", worstDepthMM)
                return "Model has measured undercut regions deeper than the \(formattedTolerance) mm "
                    + "tolerance along \(Self.axisText(pullAxis)); worst \(formattedDepth) mm "
                    + "(\(measurement))."
            }
        }

        private static func axisText(_ axis: Vec3) -> String {
            String(format: "(%.4g, %.4g, %.4g)", axis.x, axis.y, axis.z)
        }
    }

    enum AnalysisError: LocalizedError, Equatable {
        case emptyGeometry
        case invalidPullAxis
        case coordinateRangeExceeded
        case invalidTriangleIndex(faceID: Int)
        case openInput(boundaryEdgeCount: Int)
        case closedSolidValidationFailed
        case noUsableTriangles
        case projectedGridTooLarge(required: Int, budget: Int)
        case intervalConstruction(sampleIndex: Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyGeometry:
                return "Input validation failed: the source mesh is empty."
            case .invalidPullAxis:
                return "Direction setup failed: the pull axis must be finite and nonzero."
            case .coordinateRangeExceeded:
                return "Input validation failed: a source coordinate is outside the supported finite millimeter range."
            case .invalidTriangleIndex(let faceID):
                return "Input validation failed: source face \(faceID) references a missing vertex."
            case .openInput(let boundaryEdgeCount):
                return "Input validation failed: the source has \(boundaryEdgeCount) open boundary edges. Use Make Watertight, then analyze the explicit healed source."
            case .closedSolidValidationFailed:
                return "Input validation failed: the boundary-closed source could not be loaded as a solid."
            case .noUsableTriangles:
                return "Triangle preparation failed: the source has no finite nondegenerate faces."
            case .projectedGridTooLarge(let required, let budget):
                return "Grid construction failed: \(required) base columns exceed the deterministic \(budget)-column budget."
            case .intervalConstruction(let sampleIndex):
                return "Interval construction failed at measured column \(sampleIndex)."
            case .cancelled:
                return "Directional accessibility measurement was cancelled."
            }
        }
    }

    typealias Region = UndercutRegionClusterer.Region

    static func analyze(
        geometry: MeshGeometryData,
        pullAxis rawPullAxis: Vec3,
        configuration rawConfiguration: Configuration,
        shouldCancel: () -> Bool = { false }
    ) throws -> Result {
        guard !geometry.vertices.isEmpty, !geometry.triangleIndices.isEmpty else {
            throw AnalysisError.emptyGeometry
        }
        // MeshPreflight welds on a 1e-6 mm integer grid. Reject coordinates
        // outside that representable range before invoking it, so malformed
        // finite values become a named measurement failure rather than a trap.
        let preflightCoordinateLimit = Double(Int64.max) * 1.0e-6 * 0.5
        guard geometry.vertices.allSatisfy({ vertex in
            vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite
                && abs(vertex.x) <= preflightCoordinateLimit
                && abs(vertex.y) <= preflightCoordinateLimit
                && abs(vertex.z) <= preflightCoordinateLimit
        }) else {
            throw AnalysisError.coordinateRangeExceeded
        }
        guard let pullAxis = PullDirectionCandidates.canonicalized(rawPullAxis) else {
            throw AnalysisError.invalidPullAxis
        }

        // Closure by welded-edge parity over ALL triangles (R4). Preflight's
        // boundary count skips degenerate triangles first, so a piece carrying
        // one benign clip sliver would read as open and become unmeasurable.
        let openEdges = PartitionGeometry.openEdgeCount(geometry)
        guard openEdges == 0 else {
            throw AnalysisError.openInput(boundaryEdgeCount: openEdges)
        }
        do {
            let validation = try ManifoldEngine.make(from: geometry)
            withExtendedLifetime(validation) {}
        } catch {
            throw AnalysisError.closedSolidValidationFailed
        }

        let configuration = rawConfiguration.sanitized
        let prepared = try prepareTriangles(
            geometry: geometry,
            minimumAreaMM2: configuration.minimumTriangleAreaMM2
        )
        guard !prepared.triangles.isEmpty else { throw AnalysisError.noUsableTriangles }
        if shouldCancel() { throw AnalysisError.cancelled }

        let frame = ProjectionFrame(axis: pullAxis)
        let projectionBounds = ProjectionBounds(vertices: prepared.referencedVertices, frame: frame)
        let diagonal = geometryDiagonal(prepared.referencedVertices)
        var baseStep = configuration.targetGridStepMM
            ?? min(max(diagonal / configuration.gridDivisor, 0.2), 2.0)
        var uCount = max(1, Int(ceil(max(projectionBounds.width, 0) / baseStep)))
        var vCount = max(1, Int(ceil(max(projectionBounds.height, 0) / baseStep)))
        var (requiredBase, overflow) = uCount.multipliedReportingOverflow(by: vCount)
        // A footprint too large for the column budget coarsens the base step
        // deterministically instead of failing: the reported effective
        // resolution is the honesty valve (§3.2.5, R3), and one big piece
        // must degrade its own measurement precision, not abort a plan.
        var coarseningAttempts = 0
        while (overflow || requiredBase > configuration.maximumSamples), coarseningAttempts < 8 {
            let requiredEstimate = overflow
                ? Double(Int.max)
                : Double(requiredBase)
            let factor = (requiredEstimate / Double(configuration.maximumSamples))
                .squareRoot() * 1.01
            baseStep *= max(factor, 1.1)
            uCount = max(1, Int(ceil(max(projectionBounds.width, 0) / baseStep)))
            vCount = max(1, Int(ceil(max(projectionBounds.height, 0) / baseStep)))
            (requiredBase, overflow) = uCount.multipliedReportingOverflow(by: vCount)
            coarseningAttempts += 1
        }
        guard !overflow, requiredBase <= configuration.maximumSamples else {
            throw AnalysisError.projectedGridTooLarge(
                required: overflow ? Int.max : requiredBase,
                budget: configuration.maximumSamples
            )
        }
        let bvh = TriangleBVH(
            triangles: prepared.triangles,
            frame: frame,
            projectionBounds: projectionBounds,
            cellSizeMM: baseStep
        )
        let rayMargin = max(diagonal * 0.01, configuration.rayHitCoincidenceMM * 16)

        var samples: [SampleMeasurement] = []
        samples.reserveCapacity(min(configuration.maximumSamples, requiredBase * 2))
        var seen: Set<SampleKey> = []
        var budgetExhausted = false

        func measure(_ u: Double, _ v: Double) throws -> SampleMeasurement? {
            let key = SampleKey(u: u, v: v)
            guard seen.insert(key).inserted else { return nil }
            guard samples.count < configuration.maximumSamples else {
                budgetExhausted = true
                return nil
            }
            if samples.count % 256 == 0, shouldCancel() { throw AnalysisError.cancelled }
            let origin = frame.point(u: u, v: v, t: projectionBounds.minimumT - rayMargin)
            let hits = bvh.hits(
                origin: origin,
                direction: pullAxis,
                coincidenceMM: configuration.rayHitCoincidenceMM
            )
            let directIntervals = constructIntervals(
                hits: hits,
                coincidenceMM: configuration.rayHitCoincidenceMM
            )
            let intervals: [HitInterval]
            if let directIntervals {
                intervals = directIntervals
            } else if let resolved = resolveAmbiguousColumn(
                u: u,
                v: v,
                frame: frame,
                projectionBounds: projectionBounds,
                rayStartT: projectionBounds.minimumT - rayMargin,
                direction: pullAxis,
                bvh: bvh,
                coincidenceMM: configuration.rayHitCoincidenceMM,
                gridStepMM: baseStep
            ) {
                intervals = resolved
            } else {
                throw AnalysisError.intervalConstruction(sampleIndex: samples.count)
            }
            let measurement = sampleMeasurement(
                u: u,
                v: v,
                intervals: intervals,
                pullAxis: pullAxis
            )
            samples.append(measurement)
            return measurement
        }

        // Base grid: row-major V then U, with one centered sample even when a
        // projected dimension is thinner than the target step.
        for row in 0..<vCount {
            let v = centeredCoordinate(
                index: row,
                count: vCount,
                minimum: projectionBounds.minimumV,
                maximum: projectionBounds.maximumV
            )
            for column in 0..<uCount {
                let u = centeredCoordinate(
                    index: column,
                    count: uCount,
                    minimum: projectionBounds.minimumU,
                    maximum: projectionBounds.maximumU
                )
                _ = try measure(u, v)
            }
        }

        // Deterministic face-normal pre-pass. Faces on the positive side should
        // face +axis and faces on the negative side should face -axis; seed the
        // projected vertices of faces that oppose that classification.
        let middleT = (projectionBounds.minimumT + projectionBounds.maximumT) / 2
        for triangle in prepared.triangles.sorted(by: { $0.face.id < $1.face.id }) {
            let centroidT = dot(triangle.face.centroid, pullAxis)
            let side = centroidT >= middleT ? 1.0 : -1.0
            guard dot(triangle.face.normal, pullAxis) * side < -1.0e-12 else { continue }
            for vertex in [triangle.face.vertices.0, triangle.face.vertices.1, triangle.face.vertices.2] {
                if samples.count >= configuration.maximumSamples {
                    budgetExhausted = true
                    break
                }
                let vertexU = dot(vertex, frame.u)
                let vertexV = dot(vertex, frame.v)
                do {
                    _ = try measure(vertexU, vertexV)
                } catch AnalysisError.intervalConstruction(_) {
                    // A column exactly through a vertex can be topologically
                    // undefined. Resolve that seed by measuring a deterministic
                    // four-point micro-neighborhood; these are real columns,
                    // not an invented parity event. Grid-column ambiguity still
                    // fails the whole measurement above.
                    let delta = max(configuration.rayHitCoincidenceMM * 4, baseStep * 1.0e-6)
                    var resolvedCount = 0
                    for (du, dv) in [(delta, 0.0), (-delta, 0.0), (0.0, delta), (0.0, -delta)] {
                        let u = vertexU + du
                        let v = vertexV + dv
                        guard projectionBounds.contains(u: u, v: v, tolerance: 0) else { continue }
                        do {
                            if try measure(u, v) != nil { resolvedCount += 1 }
                        } catch AnalysisError.intervalConstruction(_) {
                            continue
                        }
                    }
                    if resolvedCount == 0 {
                        throw AnalysisError.intervalConstruction(sampleIndex: samples.count)
                    }
                }
            }
        }

        var frontier = samples.filter { $0.depthMM > 0 }
        var effectiveStep = baseStep
        if !budgetExhausted, configuration.refinementPasses > 0 {
            for pass in 1...configuration.refinementPasses {
                guard !frontier.isEmpty else { break }
                let step = baseStep / pow(2, Double(pass))
                var nextFrontier: [SampleMeasurement] = []
                for source in frontier {
                    for dv in [-step, 0, step] {
                        for du in [-step, 0, step] where du != 0 || dv != 0 {
                            let u = source.projectedU + du
                            let v = source.projectedV + dv
                            guard projectionBounds.contains(u: u, v: v, tolerance: baseStep * 1.0e-9) else {
                                continue
                            }
                            if let candidate = try measure(u, v) {
                                effectiveStep = step
                                if candidate.depthMM > 0 { nextFrontier.append(candidate) }
                            }
                            if budgetExhausted { break }
                        }
                        if budgetExhausted { break }
                    }
                    if budgetExhausted { break }
                }
                frontier = nextFrontier
                if budgetExhausted { break }
            }
        }

        let violating = samples.filter { $0.depthMM > 0 }
        let clustered = UndercutRegionClusterer.cluster(
            faces: prepared.triangles.map(\.face),
            violatingColumns: violating.map {
                UndercutRegionClusterer.ViolatingColumn(
                    projectedU: $0.projectedU,
                    projectedV: $0.projectedV,
                    depthMM: $0.depthMM,
                    blockingFaceIDs: $0.blockingFaceIDs,
                    suggestedEscapeDirections: $0.suggestedEscapeDirections
                )
            },
            gridStepMM: effectiveStep,
            weldToleranceMM: configuration.linearWeldMM
        )

        let draftThreshold = sin(configuration.draftAdvisoryDegrees * Double.pi / 180)
        let nearVerticalArea = prepared.triangles.reduce(0.0) { total, triangle in
            abs(dot(triangle.face.normal, pullAxis)) <= draftThreshold
                ? total + triangle.face.areaMM2
                : total
        }

        return Result(
            pullAxis: pullAxis,
            regions: clustered,
            baseResolutionMM: baseStep,
            effectiveResolutionMM: effectiveStep,
            sampleCount: samples.count,
            maximumSamples: configuration.maximumSamples,
            violatingColumnCount: violating.count,
            sampleBudgetExhausted: budgetExhausted,
            discardedDegenerateTriangleCount: prepared.discardedDegenerateCount,
            nearVerticalWallAreaMM2: nearVerticalArea
        )
    }

    static func columnDepth(for intervals: [MaterialInterval]) -> Double {
        guard intervals.count >= 2 else { return 0 }
        let thicknesses = intervals.map(\.thickness)
        var prefix = Array(repeating: 0.0, count: thicknesses.count + 1)
        for index in thicknesses.indices {
            prefix[index + 1] = prefix[index] + thicknesses[index]
        }
        let total = prefix[thicknesses.count]
        var maximum = 0.0
        for gapIndex in 0..<(intervals.count - 1) {
            let down = prefix[gapIndex + 1]
            let up = total - down
            maximum = max(maximum, min(up, down))
        }
        return maximum
    }

    // MARK: - Interval construction

    private struct Hit {
        let t: Double
        let normalDotDirection: Double
        let faceID: Int
    }

    private struct BoundaryEvent {
        enum Kind { case entering, exiting }
        let t: Double
        let kind: Kind
        let faceIDs: [Int]
    }

    private struct HitInterval {
        let material: MaterialInterval
        let boundaryFaceIDs: [Int]
    }

    private static func constructIntervals(
        hits: [Hit],
        coincidenceMM: Double
    ) -> [HitInterval]? {
        guard !hits.isEmpty else { return [] }
        let sorted = hits.sorted {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.faceID < $1.faceID
        }
        var events: [BoundaryEvent] = []
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count, sorted[end].t - sorted[index].t <= coincidenceMM {
                end += 1
            }
            let group = sorted[index..<end]
            let orientation = group.reduce(0.0) { $0 + $1.normalDotDirection }
            if abs(orientation) > 1.0e-12 {
                events.append(BoundaryEvent(
                    t: group.reduce(0.0) { $0 + $1.t } / Double(group.count),
                    kind: orientation < 0 ? .entering : .exiting,
                    faceIDs: Array(Set(group.map(\.faceID))).sorted()
                ))
            }
            index = end
        }

        var open: BoundaryEvent?
        var winding = 0
        var intervals: [HitInterval] = []
        for event in events {
            switch event.kind {
            case .entering:
                if winding == 0 { open = event }
                winding += 1
            case .exiting:
                guard winding > 0 else { return nil }
                winding -= 1
                if winding == 0 {
                    guard let lower = open, event.t >= lower.t - coincidenceMM else { return nil }
                    if event.t - lower.t > coincidenceMM {
                        intervals.append(HitInterval(
                            material: MaterialInterval(lower: lower.t, upper: event.t),
                            boundaryFaceIDs: Array(Set(lower.faceIDs + event.faceIDs)).sorted()
                        ))
                    }
                    open = nil
                }
            }
        }
        guard winding == 0, open == nil else { return nil }
        return intervals
    }

    /// Resolve a column that lands on a self-contact, edge, or vertex by
    /// measuring a deterministic micro-neighborhood. Resolution succeeds only
    /// when at least two valid neighboring columns agree within the configured
    /// grid's depth uncertainty; otherwise the winding remains unresolved and
    /// the caller returns `measurementFailed` for interval construction.
    private static func resolveAmbiguousColumn(
        u: Double,
        v: Double,
        frame: ProjectionFrame,
        projectionBounds: ProjectionBounds,
        rayStartT: Double,
        direction: Vec3,
        bvh: TriangleBVH,
        coincidenceMM: Double,
        gridStepMM: Double
    ) -> [HitInterval]? {
        let delta = max(coincidenceMM * 8, gridStepMM * 1.0e-4)
        let offsets = [
            (delta, 0.0), (-delta, 0.0),
            (0.0, delta), (0.0, -delta),
            (delta, delta), (delta, -delta),
            (-delta, delta), (-delta, -delta),
        ]
        var valid: [([HitInterval], Double)] = []
        for (du, dv) in offsets {
            let probeU = u + du
            let probeV = v + dv
            guard projectionBounds.contains(u: probeU, v: probeV, tolerance: 0) else { continue }
            let origin = frame.point(u: probeU, v: probeV, t: rayStartT)
            let hits = bvh.hits(origin: origin, direction: direction, coincidenceMM: coincidenceMM)
            guard let intervals = constructIntervals(hits: hits, coincidenceMM: coincidenceMM) else {
                continue
            }
            valid.append((intervals, columnDepth(for: intervals.map(\.material))))
        }
        guard valid.count >= 2 else { return nil }
        let depths = valid.map(\.1)
        guard let minimum = depths.min(), let maximum = depths.max(),
              maximum - minimum <= max(gridStepMM, coincidenceMM * 16) else {
            return nil
        }
        return valid.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let leftFaces = lhs.0.flatMap(\.boundaryFaceIDs)
            let rightFaces = rhs.0.flatMap(\.boundaryFaceIDs)
            return leftFaces.lexicographicallyPrecedes(rightFaces)
        }.first?.0
    }

    private struct SampleMeasurement: Equatable {
        let projectedU: Double
        let projectedV: Double
        let depthMM: Double
        let blockingFaceIDs: [Int]
        let suggestedEscapeDirections: [Vec3]
    }

    private static func sampleMeasurement(
        u: Double,
        v: Double,
        intervals: [HitInterval],
        pullAxis: Vec3
    ) -> SampleMeasurement {
        let materials = intervals.map(\.material)
        let depth = columnDepth(for: materials)
        guard depth > 0 else {
            return SampleMeasurement(
                projectedU: u,
                projectedV: v,
                depthMM: 0,
                blockingFaceIDs: [],
                suggestedEscapeDirections: []
            )
        }

        let thicknesses = materials.map(\.thickness)
        var prefix = Array(repeating: 0.0, count: thicknesses.count + 1)
        for index in thicknesses.indices {
            prefix[index + 1] = prefix[index] + thicknesses[index]
        }
        let total = prefix[thicknesses.count]
        var faces: Set<Int> = []
        var directions: [Vec3] = []
        for gapIndex in 0..<(materials.count - 1) {
            let down = prefix[gapIndex + 1]
            let up = total - down
            let gapDepth = min(up, down)
            guard abs(gapDepth - depth) <= 1.0e-9 else { continue }
            if down <= up {
                for interval in intervals[0...gapIndex] {
                    faces.formUnion(interval.boundaryFaceIDs)
                }
                directions.append(Vec3(x: -pullAxis.x, y: -pullAxis.y, z: -pullAxis.z))
            }
            if up <= down {
                for interval in intervals[(gapIndex + 1)...] {
                    faces.formUnion(interval.boundaryFaceIDs)
                }
                directions.append(pullAxis)
            }
        }
        return SampleMeasurement(
            projectedU: u,
            projectedV: v,
            depthMM: depth,
            blockingFaceIDs: faces.sorted(),
            suggestedEscapeDirections: directions
        )
    }

    // MARK: - Triangle preparation and BVH

    private struct PreparedTriangle {
        let face: UndercutRegionClusterer.FaceRecord
        let bounds: AxisBounds
    }

    private struct PreparedGeometry {
        let triangles: [PreparedTriangle]
        let referencedVertices: [Vec3]
        let discardedDegenerateCount: Int
    }

    private static func prepareTriangles(
        geometry: MeshGeometryData,
        minimumAreaMM2: Double
    ) throws -> PreparedGeometry {
        guard geometry.triangleIndices.count.isMultiple(of: 3) else {
            throw AnalysisError.invalidTriangleIndex(faceID: geometry.triangleIndices.count / 3)
        }
        var triangles: [PreparedTriangle] = []
        var referencedIndices: Set<Int> = []
        var discarded = 0
        for faceID in 0..<(geometry.triangleIndices.count / 3) {
            let base = faceID * 3
            let ia = Int(geometry.triangleIndices[base])
            let ib = Int(geometry.triangleIndices[base + 1])
            let ic = Int(geometry.triangleIndices[base + 2])
            guard geometry.vertices.indices.contains(ia),
                  geometry.vertices.indices.contains(ib),
                  geometry.vertices.indices.contains(ic) else {
                throw AnalysisError.invalidTriangleIndex(faceID: faceID)
            }
            let a = geometry.vertices[ia]
            let b = geometry.vertices[ib]
            let c = geometry.vertices[ic]
            guard a.x.isFinite, a.y.isFinite, a.z.isFinite,
                  b.x.isFinite, b.y.isFinite, b.z.isFinite,
                  c.x.isFinite, c.y.isFinite, c.z.isFinite else {
                discarded += 1
                continue
            }
            let normalVector = cross(subtract(b, a), subtract(c, a))
            let twiceArea = sqrt(dot(normalVector, normalVector))
            let area = twiceArea / 2
            guard area.isFinite, area > minimumAreaMM2, twiceArea > 1.0e-15 else {
                discarded += 1
                continue
            }
            let normal = scale(normalVector, 1.0 / twiceArea)
            let centroid = scale(add(add(a, b), c), 1.0 / 3.0)
            let face = UndercutRegionClusterer.FaceRecord(
                id: faceID,
                vertexIndices: (ia, ib, ic),
                vertices: (a, b, c),
                centroid: centroid,
                normal: normal,
                areaMM2: area
            )
            triangles.append(PreparedTriangle(
                face: face,
                bounds: AxisBounds(points: [a, b, c])
            ))
            referencedIndices.insert(ia)
            referencedIndices.insert(ib)
            referencedIndices.insert(ic)
        }
        let referenced = referencedIndices.sorted().map { geometry.vertices[$0] }
        return PreparedGeometry(
            triangles: triangles,
            referencedVertices: referenced,
            discardedDegenerateCount: discarded
        )
    }

    private indirect enum BVHNode {
        case leaf(bounds: AxisBounds, triangleIndices: [Int])
        case branch(bounds: AxisBounds, lower: BVHNode, upper: BVHNode)

        var bounds: AxisBounds {
            switch self {
            case .leaf(let bounds, _), .branch(let bounds, _, _): return bounds
            }
        }
    }

    private struct TriangleBVH {
        let triangles: [PreparedTriangle]
        let root: BVHNode?
        private let projectedGrid: ProjectedGrid?

        init(
            triangles: [PreparedTriangle],
            frame: ProjectionFrame,
            projectionBounds: ProjectionBounds,
            cellSizeMM: Double
        ) {
            self.triangles = triangles
            projectedGrid = ProjectedGrid(
                triangles: triangles,
                frame: frame,
                bounds: projectionBounds,
                cellSizeMM: cellSizeMM
            )
            root = projectedGrid == nil
                ? Self.build(indices: Array(triangles.indices), triangles: triangles)
                : nil
        }

        func hits(origin: Vec3, direction: Vec3, coincidenceMM: Double) -> [Hit] {
            if let candidateIndices = projectedGrid?.triangleIndices(for: origin) {
                var result: [Hit] = []
                result.reserveCapacity(min(candidateIndices.count, 16))
                for triangleIndex in candidateIndices {
                    let triangle = triangles[triangleIndex]
                    if let t = Self.rayIntersection(
                        origin: origin,
                        direction: direction,
                        face: triangle.face,
                        epsilon: coincidenceMM
                    ) {
                        result.append(Hit(
                            t: t,
                            normalDotDirection: dot(triangle.face.normal, direction),
                            faceID: triangle.face.id
                        ))
                    }
                }
                return result
            }
            var result: [Hit] = []
            if let root {
                collect(node: root, origin: origin, direction: direction, epsilon: coincidenceMM, into: &result)
            }
            return result
        }

        /// All rays in one analysis are parallel. A deterministic 2D index in
        /// the projection plane avoids walking the 3D BVH for every one of up
        /// to hundreds of thousands of columns. A triangle is inserted into
        /// every base-grid cell overlapped by its projected bounding box, so
        /// the candidate reduction is exact; the BVH remains the bounded-memory
        /// fallback for meshes with very large projected triangles.
        private struct ProjectedGrid {
            private struct RangeRecord {
                var triangleIndex: Int
                var minimumU: Int
                var maximumU: Int
                var minimumV: Int
                var maximumV: Int
            }

            let frameU: Vec3
            let frameV: Vec3
            let minimumU: Double
            let maximumU: Double
            let minimumV: Double
            let maximumV: Double
            let uCount: Int
            let vCount: Int
            let buckets: [[Int]]

            init?(
                triangles: [PreparedTriangle],
                frame: ProjectionFrame,
                bounds: ProjectionBounds,
                cellSizeMM: Double
            ) {
                guard cellSizeMM.isFinite, cellSizeMM > 0,
                      bounds.width.isFinite, bounds.height.isFinite else { return nil }
                frameU = frame.u
                frameV = frame.v
                minimumU = bounds.minimumU
                maximumU = bounds.maximumU
                minimumV = bounds.minimumV
                maximumV = bounds.maximumV
                uCount = max(1, Int(ceil(max(bounds.width, 0) / cellSizeMM)))
                vCount = max(1, Int(ceil(max(bounds.height, 0) / cellSizeMM)))
                let (bucketCount, overflow) = uCount.multipliedReportingOverflow(by: vCount)
                guard !overflow, bucketCount <= 1_000_000 else { return nil }

                func coordinateIndex(
                    _ value: Double,
                    minimum: Double,
                    maximum: Double,
                    count: Int
                ) -> Int {
                    guard count > 1, maximum > minimum else { return 0 }
                    let fraction = (value - minimum) / (maximum - minimum)
                    return min(max(Int(floor(fraction * Double(count))), 0), count - 1)
                }

                var records: [RangeRecord] = []
                records.reserveCapacity(triangles.count)
                var insertionCount = 0
                let maximumInsertions = max(2_000_000, triangles.count * 48)
                for (triangleIndex, triangle) in triangles.enumerated() {
                    let vertices = [
                        triangle.face.vertices.0,
                        triangle.face.vertices.1,
                        triangle.face.vertices.2,
                    ]
                    let projectedU = vertices.map { dot($0, frame.u) }
                    let projectedV = vertices.map { dot($0, frame.v) }
                    let minimumCellU = coordinateIndex(
                        projectedU.min() ?? bounds.minimumU,
                        minimum: bounds.minimumU,
                        maximum: bounds.maximumU,
                        count: uCount
                    )
                    let maximumCellU = coordinateIndex(
                        projectedU.max() ?? bounds.maximumU,
                        minimum: bounds.minimumU,
                        maximum: bounds.maximumU,
                        count: uCount
                    )
                    let minimumCellV = coordinateIndex(
                        projectedV.min() ?? bounds.minimumV,
                        minimum: bounds.minimumV,
                        maximum: bounds.maximumV,
                        count: vCount
                    )
                    let maximumCellV = coordinateIndex(
                        projectedV.max() ?? bounds.maximumV,
                        minimum: bounds.minimumV,
                        maximum: bounds.maximumV,
                        count: vCount
                    )
                    let width = maximumCellU - minimumCellU + 1
                    let height = maximumCellV - minimumCellV + 1
                    let (insertions, insertionOverflow) = width.multipliedReportingOverflow(by: height)
                    guard !insertionOverflow else { return nil }
                    insertionCount += insertions
                    guard insertionCount <= maximumInsertions else { return nil }
                    records.append(RangeRecord(
                        triangleIndex: triangleIndex,
                        minimumU: minimumCellU,
                        maximumU: maximumCellU,
                        minimumV: minimumCellV,
                        maximumV: maximumCellV
                    ))
                }

                var mutableBuckets = Array(repeating: [Int](), count: bucketCount)
                for record in records {
                    for v in record.minimumV...record.maximumV {
                        for u in record.minimumU...record.maximumU {
                            mutableBuckets[v * uCount + u].append(record.triangleIndex)
                        }
                    }
                }
                buckets = mutableBuckets
            }

            func triangleIndices(for origin: Vec3) -> [Int]? {
                let u = dot(origin, frameU)
                let v = dot(origin, frameV)
                let tolerance = 1.0e-9
                guard u >= minimumU - tolerance, u <= maximumU + tolerance,
                      v >= minimumV - tolerance, v <= maximumV + tolerance else {
                    return nil
                }
                func coordinateIndex(
                    _ value: Double,
                    minimum: Double,
                    maximum: Double,
                    count: Int
                ) -> Int {
                    guard count > 1, maximum > minimum else { return 0 }
                    let fraction = (value - minimum) / (maximum - minimum)
                    return min(max(Int(floor(fraction * Double(count))), 0), count - 1)
                }
                let column = coordinateIndex(
                    u,
                    minimum: minimumU,
                    maximum: maximumU,
                    count: uCount
                )
                let row = coordinateIndex(
                    v,
                    minimum: minimumV,
                    maximum: maximumV,
                    count: vCount
                )
                return buckets[row * uCount + column]
            }
        }

        private func collect(
            node: BVHNode,
            origin: Vec3,
            direction: Vec3,
            epsilon: Double,
            into result: inout [Hit]
        ) {
            guard node.bounds.intersectsRay(origin: origin, direction: direction, epsilon: epsilon) else {
                return
            }
            switch node {
            case .leaf(_, let indices):
                for triangleIndex in indices {
                    let triangle = triangles[triangleIndex]
                    if let t = Self.rayIntersection(
                        origin: origin,
                        direction: direction,
                        face: triangle.face,
                        epsilon: epsilon
                    ) {
                        result.append(Hit(
                            t: t,
                            normalDotDirection: dot(triangle.face.normal, direction),
                            faceID: triangle.face.id
                        ))
                    }
                }
            case .branch(_, let lower, let upper):
                collect(node: lower, origin: origin, direction: direction, epsilon: epsilon, into: &result)
                collect(node: upper, origin: origin, direction: direction, epsilon: epsilon, into: &result)
            }
        }

        private static func build(indices: [Int], triangles: [PreparedTriangle]) -> BVHNode {
            let bounds = indices.dropFirst().reduce(triangles[indices[0]].bounds) {
                $0.union(triangles[$1].bounds)
            }
            if indices.count <= 8 {
                return .leaf(bounds: bounds, triangleIndices: indices.sorted())
            }
            let extent = bounds.extent
            let axis: Int
            if extent.x >= extent.y, extent.x >= extent.z {
                axis = 0
            } else if extent.y >= extent.z {
                axis = 1
            } else {
                axis = 2
            }
            let ordered = indices.sorted {
                let left = component(triangles[$0].face.centroid, axis)
                let right = component(triangles[$1].face.centroid, axis)
                if left != right { return left < right }
                return triangles[$0].face.id < triangles[$1].face.id
            }
            let middle = ordered.count / 2
            let lower = build(indices: Array(ordered[..<middle]), triangles: triangles)
            let upper = build(indices: Array(ordered[middle...]), triangles: triangles)
            return .branch(bounds: bounds, lower: lower, upper: upper)
        }

        private static func rayIntersection(
            origin: Vec3,
            direction: Vec3,
            face: UndercutRegionClusterer.FaceRecord,
            epsilon: Double
        ) -> Double? {
            let edge1 = subtract(face.vertices.1, face.vertices.0)
            let edge2 = subtract(face.vertices.2, face.vertices.0)
            let p = cross(direction, edge2)
            let determinant = dot(edge1, p)
            guard abs(determinant) > 1.0e-14 else { return nil }
            let inverse = 1.0 / determinant
            let translated = subtract(origin, face.vertices.0)
            let u = dot(translated, p) * inverse
            let barycentricTolerance = min(max(epsilon * 1.0e-3, 1.0e-12), 1.0e-7)
            guard u >= -barycentricTolerance, u <= 1 + barycentricTolerance else { return nil }
            let q = cross(translated, edge1)
            let v = dot(direction, q) * inverse
            guard v >= -barycentricTolerance, u + v <= 1 + barycentricTolerance else { return nil }
            let t = dot(edge2, q) * inverse
            return t >= -epsilon ? max(t, 0) : nil
        }
    }

    private struct AxisBounds {
        let minimum: Vec3
        let maximum: Vec3

        init(points: [Vec3]) {
            var minimum = points[0]
            var maximum = points[0]
            for point in points.dropFirst() {
                minimum = Vec3(
                    x: min(minimum.x, point.x),
                    y: min(minimum.y, point.y),
                    z: min(minimum.z, point.z)
                )
                maximum = Vec3(
                    x: max(maximum.x, point.x),
                    y: max(maximum.y, point.y),
                    z: max(maximum.z, point.z)
                )
            }
            self.minimum = minimum
            self.maximum = maximum
        }

        var extent: Vec3 {
            subtract(maximum, minimum)
        }

        func union(_ other: AxisBounds) -> AxisBounds {
            AxisBounds(points: [
                Vec3(
                    x: min(minimum.x, other.minimum.x),
                    y: min(minimum.y, other.minimum.y),
                    z: min(minimum.z, other.minimum.z)
                ),
                Vec3(
                    x: max(maximum.x, other.maximum.x),
                    y: max(maximum.y, other.maximum.y),
                    z: max(maximum.z, other.maximum.z)
                ),
            ])
        }

        func intersectsRay(origin: Vec3, direction: Vec3, epsilon: Double) -> Bool {
            var minimumT = -Double.infinity
            var maximumT = Double.infinity
            for axis in 0..<3 {
                let originValue = Self.component(origin, axis)
                let directionValue = Self.component(direction, axis)
                let lower = Self.component(minimum, axis) - epsilon
                let upper = Self.component(maximum, axis) + epsilon
                if abs(directionValue) < 1.0e-15 {
                    if originValue < lower || originValue > upper { return false }
                    continue
                }
                var t0 = (lower - originValue) / directionValue
                var t1 = (upper - originValue) / directionValue
                if t0 > t1 { swap(&t0, &t1) }
                minimumT = max(minimumT, t0)
                maximumT = min(maximumT, t1)
                if maximumT < minimumT { return false }
            }
            return maximumT >= max(minimumT, 0)
        }

        private static func component(_ value: Vec3, _ axis: Int) -> Double {
            switch axis {
            case 0: return value.x
            case 1: return value.y
            default: return value.z
            }
        }
    }

    // MARK: - Projection

    private struct ProjectionFrame {
        let axis: Vec3
        let u: Vec3
        let v: Vec3

        init(axis: Vec3) {
            self.axis = axis
            let reference: Vec3
            if abs(axis.x) <= abs(axis.y), abs(axis.x) <= abs(axis.z) {
                reference = Vec3(x: 1, y: 0, z: 0)
            } else if abs(axis.y) <= abs(axis.z) {
                reference = Vec3(x: 0, y: 1, z: 0)
            } else {
                reference = Vec3(x: 0, y: 0, z: 1)
            }
            let rawU = cross(reference, axis)
            let length = sqrt(dot(rawU, rawU))
            u = scale(rawU, 1.0 / length)
            v = cross(axis, u)
        }

        func point(u: Double, v: Double, t: Double) -> Vec3 {
            add(add(scale(self.u, u), scale(self.v, v)), scale(axis, t))
        }
    }

    private struct ProjectionBounds {
        let minimumU: Double
        let maximumU: Double
        let minimumV: Double
        let maximumV: Double
        let minimumT: Double
        let maximumT: Double

        init(vertices: [Vec3], frame: ProjectionFrame) {
            var minimumU = Double.infinity
            var maximumU = -Double.infinity
            var minimumV = Double.infinity
            var maximumV = -Double.infinity
            var minimumT = Double.infinity
            var maximumT = -Double.infinity
            for vertex in vertices {
                let u = dot(vertex, frame.u)
                let v = dot(vertex, frame.v)
                let t = dot(vertex, frame.axis)
                minimumU = min(minimumU, u)
                maximumU = max(maximumU, u)
                minimumV = min(minimumV, v)
                maximumV = max(maximumV, v)
                minimumT = min(minimumT, t)
                maximumT = max(maximumT, t)
            }
            self.minimumU = minimumU
            self.maximumU = maximumU
            self.minimumV = minimumV
            self.maximumV = maximumV
            self.minimumT = minimumT
            self.maximumT = maximumT
        }

        var width: Double { maximumU - minimumU }
        var height: Double { maximumV - minimumV }

        func contains(u: Double, v: Double, tolerance: Double) -> Bool {
            u >= minimumU - tolerance && u <= maximumU + tolerance
                && v >= minimumV - tolerance && v <= maximumV + tolerance
        }
    }

    private struct SampleKey: Hashable {
        let u: UInt64
        let v: UInt64

        init(u: Double, v: Double) {
            self.u = Self.standardizedBits(u)
            self.v = Self.standardizedBits(v)
        }

        private static func standardizedBits(_ value: Double) -> UInt64 {
            let standardized = value == 0 ? 0.0 : value
            return standardized.bitPattern
        }
    }

    private static func centeredCoordinate(
        index: Int,
        count: Int,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard count > 1, maximum > minimum else { return (minimum + maximum) / 2 }
        return minimum + (Double(index) + 0.5) * (maximum - minimum) / Double(count)
    }

    private static func geometryDiagonal(_ vertices: [Vec3]) -> Double {
        let bounds = AxisBounds(points: vertices)
        return sqrt(dot(bounds.extent, bounds.extent))
    }

    private static func component(_ value: Vec3, _ axis: Int) -> Double {
        switch axis {
        case 0: return value.x
        case 1: return value.y
        default: return value.z
        }
    }

    // MARK: - Math

    @inline(__always) private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inline(__always) private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    @inline(__always) private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    @inline(__always) private static func scale(_ value: Vec3, _ amount: Double) -> Vec3 {
        Vec3(x: value.x * amount, y: value.y * amount, z: value.z * amount)
    }

    @inline(__always) private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }
}
