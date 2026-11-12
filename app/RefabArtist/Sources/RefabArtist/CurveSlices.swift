import Foundation

struct CurveSlicePlan: Equatable {
    var primary: StackedSlicePlan
    var centers: [Vec3]
    var directions: [Vec2]
    var normals: [Vec2]
    var amplitude: Double
    var controlPoints: [Vec2]
    var slotWidth: Double
    var slotAngleDegrees: Double
    var bounds: Bounds3D
    /// The number of curve ribs asked for, when fewer can stand along the
    /// spline in the plan's stock without passing through each other; nil
    /// when all of them can.
    var requestedSliceCount: Int? = nil
    /// The number of first-axis ribs asked for, when fewer fit across the
    /// model with a stock-thick web between their slots in the curve ribs;
    /// nil when all of them do.
    var requestedFirstAxisCount: Int? = nil
    /// The first-axis positions at even spacing, when some first-axis ribs
    /// were moved off it so the joints hold parts that would otherwise be
    /// joined only among themselves (`CurveSlicePlanner.joiningGroups`); nil
    /// when every rib stands at even spacing.
    var evenFirstAxisPositions: [Double]? = nil

    var sliceCount: Int {
        centers.count
    }

    var primarySliceCount: Int {
        primary.sliceCount
    }

    var totalPartCount: Int {
        primarySliceCount + sliceCount
    }
}

extension CurveSlicePlan {
    /// What the app says under Curve slices, and the CLI notes, when fewer
    /// curve ribs are cut than were asked for; nil when all of them are.
    var curveCountNote: String? {
        guard let requested = requestedSliceCount else { return nil }
        let fit = sliceCount == 1 ? "Only 1 curve slice fits" : "Only \(sliceCount) curve slices fit"
        return "\(fit) along this curve in \(Self.millimetres(primary.materialThickness)) mm stock (\(requested) asked for); "
            + "more would stand too close together for strong joints. Use thinner stock or a longer curve for more."
    }

    /// The same for the first-axis ribs.
    var firstAxisCountNote: String? {
        guard let requested = requestedFirstAxisCount else { return nil }
        let fit = primarySliceCount == 1 ? "Only 1 first-axis slice fits" : "Only \(primarySliceCount) first-axis slices fit"
        return "\(fit) across this model in \(Self.millimetres(primary.materialThickness)) mm stock (\(requested) asked for); "
            + "more would leave the curve slices too thin between their slots. Use thinner stock for more."
    }

    /// The first-axis ribs moved off the even spacing (`evenFirstAxisPositions`):
    /// rib index, even position and the position cut.
    var firstAxisMoves: [(rib: Int, even: Double, position: Double)] {
        guard let even = evenFirstAxisPositions, even.count == primary.positions.count else { return [] }
        return even.indices.compactMap { index in
            abs(even[index] - primary.positions[index]) > 1.0e-9 ? (index, even[index], primary.positions[index]) : nil
        }
    }

    /// What the app says under 1st Axis slices, and the CLI notes, when
    /// first-axis ribs were moved off the even spacing; nil when none were.
    var firstAxisMoveNote: String? {
        let moves = firstAxisMoves
        guard !moves.isEmpty else { return nil }
        func listed(_ items: [String]) -> String {
            items.count == 1 ? items[0] : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
        let letter = CutSheetLayoutBuilder.axisLetter(primary.axis)
        let ribs = listed(moves.map { "\(letter)-\($0.rib + 1)" })
        let cut = listed(moves.map { Self.millimetres($0.position) })
        let even = listed(moves.map { Self.millimetres($0.even) })
        return "\(ribs) \(moves.count == 1 ? "is" : "are") set off the even spacing, at \(cut) mm instead of \(even) mm, "
            + "so the joints hold parts that would otherwise be joined only to each other."
    }

    private static func millimetres(_ value: Double) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }
}

struct CurveSliceLayer: Equatable {
    var center: Vec3
    var direction: Vec2
    var normal: Vec2
    var paths: [SlicePath2D]
}

struct CurveSliceContours: Equatable {
    var layers: [CurveSliceLayer]
}

enum CurveSlicePlanner {
    static func plan(model: MeshSummary, sliceCount: Int, amplitude: Double) -> CurveSlicePlan? {
        plan(
            model: model,
            primaryAxis: .y,
            materialThickness: 3.0,
            firstAxisCount: 7,
            curveSliceCount: sliceCount,
            amplitude: amplitude,
            slotWidth: 3.0,
            slotAngleDegrees: 45.0
        )
    }

    static func plan(
        model: MeshSummary,
        primaryAxis: SliceAxis,
        materialThickness: Double,
        firstAxisCount: Int,
        curveSliceCount: Int,
        amplitude: Double,
        slotWidth: Double,
        slotAngleDegrees: Double
    ) -> CurveSlicePlan? {
        guard let bounds = model.bounds,
              curveSliceCount >= 2,
              let requestedPrimary = StackedSlicePlanner.plan(
                model: model,
                axis: primaryAxis,
                materialThickness: materialThickness,
                sliceCountOverride: firstAxisCount
              ) else {
            return nil
        }

        let midX = (bounds.min.x + bounds.max.x) / 2
        let midY = (bounds.min.y + bounds.max.y) / 2
        let midZ = (bounds.min.z + bounds.max.z) / 2
        // The spline runs across the first-axis ribs: along X, or along Y
        // when the first axis is X (X ribs would stand nearly parallel to
        // curve ribs on a spline along X).
        let alongY = primaryAxis == .x
        let lower = alongY ? min(bounds.min.y, bounds.max.y) : min(bounds.min.x, bounds.max.x)
        let upper = alongY ? max(bounds.min.y, bounds.max.y) : max(bounds.min.x, bounds.max.x)
        let span = upper - lower
        guard span > 0 else {
            return nil
        }

        let clampedAmplitude = max(-span, min(span, amplitude))
        let controlPoints = alongY
            ? [
                Vec2(x: midX, y: upper),
                Vec2(x: midX + clampedAmplitude, y: (lower + upper) / 2),
                Vec2(x: midX, y: lower)
            ]
            : [
                Vec2(x: lower, y: midY),
                Vec2(x: (lower + upper) / 2, y: midY + clampedAmplitude),
                Vec2(x: upper, y: midY)
            ]
        let primary = fittedPrimary(requestedPrimary, model: model, controlPoints: controlPoints, slotWidth: max(0.1, slotWidth))
        let samples = standingSamples(
            controlPoints,
            requested: curveSliceCount,
            primary: primary,
            slotWidth: max(0.1, slotWidth),
            bounds: bounds,
            z: midZ
        )
        guard !samples.isEmpty else {
            return nil
        }

        return CurveSlicePlan(
            primary: primary,
            centers: samples.map(\.0),
            directions: samples.map(\.1),
            normals: samples.map(\.2),
            amplitude: clampedAmplitude,
            controlPoints: controlPoints,
            slotWidth: max(0.1, slotWidth),
            slotAngleDegrees: min(60, max(0, slotAngleDegrees)),
            bounds: bounds,
            requestedSliceCount: samples.count < curveSliceCount ? curveSliceCount : nil,
            requestedFirstAxisCount: primary.sliceCount < requestedPrimary.sliceCount ? requestedPrimary.sliceCount : nil
        )
    }

    static func plan(
        model: MeshSummary,
        primaryAxis: SliceAxis,
        materialThickness: Double,
        firstAxisCount: Int,
        curveSliceCount: Int,
        splineControlPoints: [Vec2],
        slotWidth: Double,
        slotAngleDegrees: Double
    ) -> CurveSlicePlan? {
        guard let bounds = model.bounds,
              curveSliceCount >= 2,
              splineControlPoints.count >= 2,
              let requestedPrimary = StackedSlicePlanner.plan(
                model: model,
                axis: primaryAxis,
                materialThickness: materialThickness,
                sliceCountOverride: firstAxisCount
              ) else {
            return nil
        }

        let midY = (bounds.min.y + bounds.max.y) / 2
        let midZ = (bounds.min.z + bounds.max.z) / 2
        let primary = fittedPrimary(requestedPrimary, model: model, controlPoints: splineControlPoints, slotWidth: max(0.1, slotWidth))
        let samples = standingSamples(
            splineControlPoints,
            requested: curveSliceCount,
            primary: primary,
            slotWidth: max(0.1, slotWidth),
            bounds: bounds,
            z: midZ
        )
        guard !samples.isEmpty else {
            return nil
        }
        let amplitude = splineControlPoints.reduce(0.0) { partial, point in
            max(partial, abs(point.y - midY))
        }

        return CurveSlicePlan(
            primary: primary,
            centers: samples.map(\.0),
            directions: samples.map(\.1),
            normals: samples.map(\.2),
            amplitude: amplitude,
            controlPoints: splineControlPoints,
            slotWidth: max(0.1, slotWidth),
            slotAngleDegrees: min(60, max(0, slotAngleDegrees)),
            bounds: bounds,
            requestedSliceCount: samples.count < curveSliceCount ? curveSliceCount : nil,
            requestedFirstAxisCount: primary.sliceCount < requestedPrimary.sliceCount ? requestedPrimary.sliceCount : nil
        )
    }

    /// `primary` with as many first-axis ribs as fit across the model: no more
    /// than leave a stock-thick web (`CurveJointPlanner.slotWeb`) between
    /// their slots in a curve rib. Ribs crossing the curve ribs at a slant
    /// need wider slots, so the steepest slant along the spline counts.
    private static func fittedPrimary(
        _ primary: StackedSlicePlan,
        model: MeshSummary,
        controlPoints: [Vec2],
        slotWidth: Double
    ) -> StackedSlicePlan {
        let count = primary.sliceCount
        guard count > 1, primary.positionsOverride == nil else { return primary }
        let thickness = primary.materialThickness
        let pitch = firstAxisPitch(axis: primary.axis, controlPoints: controlPoints, slotWidth: slotWidth, thickness: thickness)
        let extent = primary.rangeMax - primary.rangeMin
        let fits = max(1, Int((extent / pitch + 1.0e-9).rounded(.down)))
        guard fits < count,
              let fitted = StackedSlicePlanner.plan(
                model: model,
                axis: primary.axis,
                materialThickness: thickness,
                sliceCountOverride: fits
              ) else {
            return primary
        }
        return fitted
    }

    /// The least spacing between two first-axis ribs that leaves a
    /// stock-thick web (`CurveJointPlanner.slotWeb`) between their slots in a
    /// curve rib: `w + t·|cos a| + web·sin a` for slot width `w`, stock `t`
    /// and the steepest angle `a` at which a curve rib crosses the first-axis
    /// ribs along the spline (square, `w + web`, with first axis Z).
    static func firstAxisPitch(axis: SliceAxis, controlPoints: [Vec2], slotWidth: Double, thickness: Double) -> Double {
        let web = CurveJointPlanner.slotWeb(thickness: thickness)
        // The crossing angle's sine and cosine at the steepest slant.
        var sine = 1.0
        if axis != .z {
            let polyline = tessellate(controlPoints)
            for (a, b) in zip(polyline, polyline.dropFirst()) {
                let direction = normalized(Vec2(x: b.x - a.x, y: b.y - a.y))
                // The rib's in-plane direction is the tangent turned square.
                let toward = axis == .y ? abs(direction.x) : abs(direction.y)
                if toward >= CurveJointPlanner.minimumCrossingSine {
                    sine = min(sine, toward)
                }
            }
        }
        let cosine = (max(0, 1 - sine * sine)).squareRoot()
        return slotWidth + thickness * cosine + web * sine
    }

    /// The curve ribs' sample points along the spline: `requested` of them,
    /// or, when that many cannot all be cut from the stock and joined, the
    /// most that can (at least one). Ribs must stand far enough apart where
    /// they leave the spline for a stock-thick web between their slots
    /// (`CurveJointPlanner.ribsStandApart`), and each must find a place to
    /// stop short of the ribs it would run into (`CurveJointPlanner.ribLayout`).
    private static func standingSamples(
        _ controlPoints: [Vec2],
        requested: Int,
        primary: StackedSlicePlan,
        slotWidth: Double,
        bounds: Bounds3D,
        z: Double
    ) -> [(Vec3, Vec2, Vec2)] {
        let thickness = primary.materialThickness
        for count in stride(from: requested, through: 1, by: -1) {
            let samples = sampleSpline(controlPoints, count: count, z: z)
            guard samples.count == count else {
                return []
            }
            let stations = samples.map { CurveJointPlanner.RibStation(center: $0.0, direction: $0.1, normal: $0.2) }
            let apart = stations.indices.allSatisfy { i in
                stations.indices.allSatisfy { j in
                    j <= i || CurveJointPlanner.ribsStandApart(stations[i], stations[j], thickness: thickness, slotWidth: slotWidth)
                }
            }
            guard apart || count == 1 else {
                continue
            }
            let layout = CurveJointPlanner.ribLayout(
                stations: stations,
                axis: primary.axis,
                positions: primary.positions,
                thickness: thickness,
                slotWidth: slotWidth,
                bounds: bounds
            )
            if layout.standsClear || count == 1 {
                return samples
            }
        }
        return []
    }

    private static func sampleSpline(_ controlPoints: [Vec2], count: Int, z: Double) -> [(Vec3, Vec2, Vec2)] {
        guard count >= 1 else {
            return []
        }
        let polyline = tessellate(controlPoints)
        guard polyline.count >= 2 else {
            return []
        }
        var cumulative = [0.0]
        for index in 1..<polyline.count {
            cumulative.append(cumulative[index - 1] + distance(polyline[index - 1], polyline[index]))
        }
        guard let totalLength = cumulative.last, totalLength > 0 else {
            return []
        }

        return (0..<count).map { index in
            let target = totalLength * (Double(index) + 0.5) / Double(count)
            let segmentIndex = segment(for: target, in: cumulative)
            let start = polyline[segmentIndex]
            let end = polyline[segmentIndex + 1]
            let segmentLength = cumulative[segmentIndex + 1] - cumulative[segmentIndex]
            let t = segmentLength > 0 ? (target - cumulative[segmentIndex]) / segmentLength : 0
            let point = Vec2(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            let direction = normalized(Vec2(x: end.x - start.x, y: end.y - start.y))
            let normal = Vec2(x: -direction.y, y: direction.x)
            return (Vec3(x: point.x, y: point.y, z: z), direction, normal)
        }
    }

    private static func tessellate(_ controlPoints: [Vec2]) -> [Vec2] {
        guard controlPoints.count >= 2 else {
            return []
        }
        if controlPoints.count == 2 {
            return controlPoints
        }
        let stepsPerSegment = 24
        var points: [Vec2] = []
        for index in 0..<(controlPoints.count - 1) {
            let p0 = controlPoints[max(0, index - 1)]
            let p1 = controlPoints[index]
            let p2 = controlPoints[index + 1]
            let p3 = controlPoints[min(controlPoints.count - 1, index + 2)]
            if index == 0 {
                points.append(p1)
            }
            for step in 1...stepsPerSegment {
                let t = Double(step) / Double(stepsPerSegment)
                points.append(catmullRom(p0, p1, p2, p3, t: t))
            }
        }
        return points
    }

    private static func catmullRom(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, t: Double) -> Vec2 {
        let t2 = t * t
        let t3 = t2 * t
        return Vec2(
            x: 0.5 * (
                (2 * p1.x)
                + (-p0.x + p2.x) * t
                + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
            ),
            y: 0.5 * (
                (2 * p1.y)
                + (-p0.y + p2.y) * t
                + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
            )
        )
    }

    private static func segment(for target: Double, in cumulative: [Double]) -> Int {
        for index in 0..<(cumulative.count - 1) where target <= cumulative[index + 1] {
            return index
        }
        return max(0, cumulative.count - 2)
    }

    private static func distance(_ lhs: Vec2, _ rhs: Vec2) -> Double {
        let dx = rhs.x - lhs.x
        let dy = rhs.y - lhs.y
        return sqrt(dx * dx + dy * dy)
    }

    private static func normalized(_ vector: Vec2) -> Vec2 {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y)
        guard length > 0 else {
            return Vec2(x: 1, y: 0)
        }
        return Vec2(x: vector.x / length, y: vector.y / length)
    }
}

enum CurveSliceContourer {
    private static let epsilon = 1.0e-7

    static func generate(model: MeshSummary, plan: CurveSlicePlan) -> CurveSliceContours {
        let triangles = meshTriangles(model)
        let winding = MeshWinding(triangles: triangles)
        let layers = plan.centers.indices.map { index in
            let center = plan.centers[index]
            let tangent = plan.directions[index]
            let normal = plan.normals[index]
            var segments: [Segment2D] = []
            for (triangleIndex, triangle) in triangles.enumerated() {
                if var segment = intersect(triangle: triangle, center: center, planeNormal: tangent, inPlaneDirection: normal) {
                    segment.triangle = triangleIndex
                    segments.append(segment)
                }
            }
            let edges = segments.map { SectionEdge(a: $0.a, b: $0.b, outward: $0.outward, triangle: $0.triangle) }
            return CurveSliceLayer(
                center: center, direction: tangent, normal: normal,
                paths: cleaned(join(segments: segments), edges: edges, winding: winding)
            )
        }
        return CurveSliceContours(layers: layers)
    }

    /// The first-axis sections of a Curve Slices plan, cleaned like the
    /// curve ribs' (`cleaned`).
    static func firstAxisContours(model: MeshSummary, plan: CurveSlicePlan) -> StackedSliceContours {
        cleaned(StackedSliceContourer.generate(model: model, plan: plan.primary), model: model)
    }

    /// `contours` (first-axis sections of `model`) with every layer's paths
    /// cleaned (`cleaned`).
    static func cleaned(_ contours: StackedSliceContours, model: MeshSummary) -> StackedSliceContours {
        let triangles = meshTriangles(model)
        let winding = MeshWinding(triangles: triangles)
        return StackedSliceContours(
            axis: contours.axis,
            layers: contours.layers.map { layer in
                SliceContourLayer(
                    position: layer.position,
                    paths: cleaned(
                        layer.paths,
                        edges: sectionEdges(triangles, axis: contours.axis, position: layer.position),
                        winding: winding
                    )
                )
            }
        )
    }

    /// One edge of a section, and the direction (in the section's
    /// coordinates) the surface it was cut from faces: out of the model.
    struct SectionEdge {
        var a: Vec2
        var b: Vec2
        var outward: Vec2
        /// The index of the triangle it was cut from (`meshTriangles`), or
        /// -1 when not known.
        var triangle = -1
    }

    /// The edges of the model's section by the plane square to `axis` at
    /// `position`, in the first-axis sections' projection ((y, z), (x, z) or
    /// (x, y)), each with the direction its triangle faces.
    static func sectionEdges(_ triangles: [(Vec3, Vec3, Vec3)], axis: SliceAxis, position: Double) -> [SectionEdge] {
        func coordinate(_ point: Vec3) -> Double {
            switch axis {
            case .x: return point.x
            case .y: return point.y
            case .z: return point.z
            }
        }
        func project(_ point: Vec3) -> Vec2 {
            switch axis {
            case .x: return Vec2(x: point.y, y: point.z)
            case .y: return Vec2(x: point.x, y: point.z)
            case .z: return Vec2(x: point.x, y: point.y)
            }
        }
        var edges: [SectionEdge] = []
        for (triangleIndex, triangle) in triangles.enumerated() {
            let corners = [triangle.0, triangle.1, triangle.2]
            let distances = corners.map { coordinate($0) - position }
            guard let low = distances.min(), let high = distances.max(), low < 0, high > 0 else { continue }
            var points: [Vec2] = []
            for i in 0..<3 {
                let (a, b) = (corners[i], corners[(i + 1) % 3])
                let (da, db) = (distances[i], distances[(i + 1) % 3])
                if da == 0 {
                    points.append(project(a))
                } else if (da < 0) != (db < 0), db != 0 {
                    let t = da / (da - db)
                    points.append(project(Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)))
                }
            }
            guard points.count == 2 else { continue }
            edges.append(SectionEdge(a: points[0], b: points[1], outward: project(faceNormal(triangle)), triangle: triangleIndex))
        }
        return edges
    }

    /// A section's paths as the closed outlines a rib is cut from. Where the
    /// plane passes through a hole in the mesh the section comes out as open
    /// chains; these are joined end to end, nearest ends first, and closed
    /// across the hole. Each loop is then turned so the model's material lies
    /// on its left, as the surface it was cut from faces (`edges`, the
    /// section's edges; `materialOnLeft`), and the material is their union:
    /// shells that overlap or touch give one piece, holes stay holes, and a
    /// loop that touches itself encloses what it encloses. The result is
    /// clean closed loops, outer boundaries counter-clockwise and holes
    /// clockwise. Notches and holes narrower than
    /// `CurveJointPlanner.minimumWeb` (cracks in the mesh, too fine to cut)
    /// are filled. Paths that enclose no area are dropped. Without `edges`
    /// the loops are counted even-odd instead. `winding` (the model's
    /// triangles) lets a mesh whose triangles wind both ways be read
    /// consistently (`MeshWinding`). When the loops cannot be resolved they
    /// are returned closed as they are.
    static func cleaned(_ paths: [SlicePath2D], edges: [SectionEdge] = [], winding: MeshWinding? = nil) -> [SlicePath2D] {
        var rings: [[Vec2]] = []
        var chains: [[Vec2]] = []
        for path in paths where path.points.count >= 2 {
            var points = path.points
            if let first = points.first, let last = points.last, points.count > 2, samePoint(first, last) {
                points.removeLast()
                rings.append(points)
            } else if path.closed {
                rings.append(points)
            } else {
                chains.append(points)
            }
        }
        rings += closedChains(chains)
        let usable = rings.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return [] }
        let region = edges.isEmpty
            ? PlanarBoolean.evenOddRegion(usable, closingBy: CurveJointPlanner.minimumWeb / 2)
            : PlanarBoolean.joining(materialOnLeft(usable, edges: edges, winding: winding), closingBy: CurveJointPlanner.minimumWeb / 2)
        guard let region else {
            return usable.map { SlicePath2D(points: $0 + [$0[0]], closed: true) }
        }
        return region.filter { $0.count >= 3 }.map { SlicePath2D(points: $0 + [$0[0]], closed: true) }
    }

    /// `loops` each turned so the model's material lies on its left (outer
    /// boundaries counter-clockwise, holes clockwise), as the surface the
    /// loop was cut from says: up to `orientationSamples` of each loop's
    /// edges are matched to the section `edges` they lie on, and each votes
    /// by which side the surface faces. A loop none of whose edges matches
    /// (a mesh whose surface faces both ways there) is turned by how many
    /// other loops it lies inside (even: outer). When the loops do not come
    /// out turned as their nesting says and the model's triangles wind both
    /// ways (`winding`, `MeshWinding.flips`), they are turned again with the
    /// triangles read consistently. A mesh whose triangles all agree is
    /// read as it is.
    static func materialOnLeft(_ loops: [[Vec2]], edges: [SectionEdge], winding: MeshWinding? = nil) -> [[Vec2]] {
        let oriented = materialOnLeft(loops, edges: edges, flips: nil)
        guard let winding, !MeshWinding.followsNesting(oriented), let flips = winding.flips else {
            return oriented
        }
        return materialOnLeft(loops, edges: edges, flips: flips)
    }

    /// `materialOnLeft` with the triangles `flips` marks read the other way
    /// round.
    private static func materialOnLeft(_ loops: [[Vec2]], edges: [SectionEdge], flips: [Bool]?) -> [[Vec2]] {
        loops.indices.map { index in
            let loop = loops[index]
            var vote = 0
            let samples = min(orientationSamples, loop.count)
            for sample in 0..<samples {
                let i = sample * loop.count / samples
                let (p, q) = (loop[i], loop[(i + 1) % loop.count])
                let d = Vec2(x: q.x - p.x, y: q.y - p.y)
                let length = (d.x * d.x + d.y * d.y).squareRoot()
                guard length > 1.0e-9 else { continue }
                let middle = Vec2(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                guard let edge = edges.first(where: { edge in
                    let e = Vec2(x: edge.b.x - edge.a.x, y: edge.b.y - edge.a.y)
                    let edgeLength = (e.x * e.x + e.y * e.y).squareRoot()
                    guard edgeLength > 1.0e-9, abs(d.x * e.y - d.y * e.x) <= 1.0e-3 * length * edgeLength else { return false }
                    return distance(middle, toSegment: edge.a, edge.b) <= 1.0e-5
                }) else { continue }
                // The surface faces to the right of the loop's direction: the
                // material is on its left.
                let flipped = flips.map { edge.triangle >= 0 && edge.triangle < $0.count && $0[edge.triangle] } ?? false
                let outward = flipped ? Vec2(x: -edge.outward.x, y: -edge.outward.y) : edge.outward
                vote += d.x * outward.y - d.y * outward.x < 0 ? 1 : -1
            }
            if vote != 0 {
                return vote > 0 ? loop : Array(loop.reversed())
            }
            let depth = loops.indices.filter { other in
                other != index && CutSheetLayoutBuilder.contains(loops[other], point: loop[0])
            }.count
            return (CutSheetLayoutBuilder.signedArea(loop) > 0) == (depth % 2 == 0) ? loop : Array(loop.reversed())
        }
    }

    /// Edges of a loop matched to its section to find which side the model
    /// lies on.
    private static let orientationSamples = 8

    private static func distance(_ point: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = Vec2(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / lengthSquared)) : 0
        let dx = point.x - (a.x + ab.x * t)
        let dy = point.y - (a.y + ab.y * t)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The model's triangles.
    static func meshTriangles(_ model: MeshSummary) -> [(Vec3, Vec3, Vec3)] {
        model.geometry.triangleIndices.chunked(into: 3).compactMap { indices -> (Vec3, Vec3, Vec3)? in
            guard indices.count == 3 else { return nil }
            let a = Int(indices[0])
            let b = Int(indices[1])
            let c = Int(indices[2])
            guard model.geometry.vertices.indices.contains(a),
                  model.geometry.vertices.indices.contains(b),
                  model.geometry.vertices.indices.contains(c) else {
                return nil
            }
            return (model.geometry.vertices[a], model.geometry.vertices[b], model.geometry.vertices[c])
        }
    }

    /// The outward normal of a triangle, from its winding (not normalised).
    private static func faceNormal(_ triangle: (Vec3, Vec3, Vec3)) -> Vec3 {
        let u = Vec3(x: triangle.1.x - triangle.0.x, y: triangle.1.y - triangle.0.y, z: triangle.1.z - triangle.0.z)
        let v = Vec3(x: triangle.2.x - triangle.0.x, y: triangle.2.y - triangle.0.y, z: triangle.2.z - triangle.0.z)
        return Vec3(x: u.y * v.z - u.z * v.y, y: u.z * v.x - u.x * v.z, z: u.x * v.y - u.y * v.x)
    }

    /// Open chains joined into closed rings. Starting from a chain, the walk
    /// goes on from its far end to the nearest end of another chain (the
    /// next stretch of outline beyond a crack or hole in the mesh), until
    /// its own start is nearer than any other chain: then the ring closes.
    static func closedChains(_ open: [[Vec2]]) -> [[Vec2]] {
        var chains = open.filter { $0.count >= 2 }
        var rings: [[Vec2]] = []
        func gap(_ a: Vec2, _ b: Vec2) -> Double {
            (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
        }
        while !chains.isEmpty {
            var ring = chains.removeFirst()
            while let start = ring.first, let end = ring.last {
                var best: (index: Int, reversed: Bool, gap: Double)?
                for (index, chain) in chains.enumerated() {
                    guard let first = chain.first, let last = chain.last else { continue }
                    let toFirst = gap(end, first)
                    let toLast = gap(end, last)
                    let candidate = toFirst <= toLast ? (index, false, toFirst) : (index, true, toLast)
                    if best == nil || candidate.2 < best!.gap {
                        best = candidate
                    }
                }
                guard let next = best, next.gap < gap(end, start) else { break }
                var tail = chains.remove(at: next.index)
                if next.reversed {
                    tail.reverse()
                }
                if let first = tail.first, samePoint(end, first) {
                    tail.removeFirst()
                }
                ring += tail
            }
            rings.append(ring)
        }
        return rings
    }

    static func scenePoint(_ point: Vec2, center: Vec3, inPlaneDirection: Vec2) -> Vec3 {
        Vec3(
            x: center.x + inPlaneDirection.x * point.x,
            y: center.y + inPlaneDirection.y * point.x,
            z: point.y
        )
    }

    private struct Segment2D {
        var a: Vec2
        var b: Vec2
        /// The direction the triangle it was cut from faces, in the
        /// section's coordinates.
        var outward = Vec2(x: 0, y: 0)
        /// The index of that triangle (`meshTriangles`).
        var triangle = -1
    }

    private static func signedDistance(_ point: Vec3, center: Vec3, normal: Vec2) -> Double {
        (point.x - center.x) * normal.x + (point.y - center.y) * normal.y
    }

    private static func intersect(triangle: (Vec3, Vec3, Vec3), center: Vec3, planeNormal: Vec2, inPlaneDirection: Vec2) -> Segment2D? {
        let distances = [triangle.0, triangle.1, triangle.2].map { signedDistance($0, center: center, normal: planeNormal) }
        if StackedSliceContourer.isAboveInPlaneEdge(distances: distances) {
            return nil
        }
        var points: [Vec3] = []
        collectEdgeIntersection(points: &points, start: triangle.0, end: triangle.1, center: center, normal: planeNormal)
        collectEdgeIntersection(points: &points, start: triangle.1, end: triangle.2, center: center, normal: planeNormal)
        collectEdgeIntersection(points: &points, start: triangle.2, end: triangle.0, center: center, normal: planeNormal)
        guard points.count == 2, !samePoint(points[0], points[1]) else {
            return nil
        }
        let facing = faceNormal(triangle)
        return Segment2D(
            a: project(points[0], center: center, inPlaneDirection: inPlaneDirection),
            b: project(points[1], center: center, inPlaneDirection: inPlaneDirection),
            outward: Vec2(x: facing.x * inPlaneDirection.x + facing.y * inPlaneDirection.y, y: facing.z)
        )
    }

    private static func project(_ point: Vec3, center: Vec3, inPlaneDirection: Vec2) -> Vec2 {
        Vec2(
            x: (point.x - center.x) * inPlaneDirection.x + (point.y - center.y) * inPlaneDirection.y,
            y: point.z
        )
    }

    private static func collectEdgeIntersection(points: inout [Vec3], start: Vec3, end: Vec3, center: Vec3, normal: Vec2) {
        let startDistance = signedDistance(start, center: center, normal: normal)
        let endDistance = signedDistance(end, center: center, normal: normal)
        if abs(startDistance) <= epsilon, abs(endDistance) <= epsilon {
            return
        }
        if abs(startDistance) <= epsilon {
            appendUnique(start, to: &points)
            return
        }
        if abs(endDistance) <= epsilon {
            appendUnique(end, to: &points)
            return
        }
        if (startDistance < 0 && endDistance > 0) || (startDistance > 0 && endDistance < 0) {
            let t = startDistance / (startDistance - endDistance)
            appendUnique(Vec3(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
                z: start.z + (end.z - start.z) * t
            ), to: &points)
        }
    }

    private static func appendUnique(_ point: Vec3, to points: inout [Vec3]) {
        guard !points.contains(where: { samePoint($0, point) }) else { return }
        points.append(point)
    }

    private static func join(segments: [Segment2D]) -> [SlicePath2D] {
        var used = Array(repeating: false, count: segments.count)
        var paths: [SlicePath2D] = []

        for startIndex in segments.indices where !used[startIndex] {
            var path = SlicePath2D(points: [segments[startIndex].a, segments[startIndex].b], closed: false)
            used[startIndex] = true

            var extended = true
            while extended {
                extended = false
                for index in segments.indices where !used[index] {
                    let segment = segments[index]
                    guard let first = path.points.first, let last = path.points.last else { continue }
                    if samePoint(last, segment.a) {
                        path.points.append(segment.b)
                    } else if samePoint(last, segment.b) {
                        path.points.append(segment.a)
                    } else if samePoint(first, segment.a) {
                        path.points.insert(segment.b, at: 0)
                    } else if samePoint(first, segment.b) {
                        path.points.insert(segment.a, at: 0)
                    } else {
                        continue
                    }
                    used[index] = true
                    extended = true
                }
            }

            if path.points.count > 2, let first = path.points.first, let last = path.points.last, samePoint(first, last) {
                path.closed = true
                path.points[path.points.count - 1] = first
            }
            simplifyCollinear(path: &path)
            paths.append(path)
        }

        return paths
    }

    private static func simplifyCollinear(path: inout SlicePath2D) {
        guard path.points.count >= 3 else { return }
        if path.closed, let first = path.points.first, let last = path.points.last, samePoint(first, last) {
            path.points.removeLast()
        }
        var changed = true
        while changed, path.points.count > (path.closed ? 3 : 2) {
            changed = false
            let count = path.points.count
            for index in 0..<count {
                if !path.closed, (index == 0 || index + 1 == count) {
                    continue
                }
                let previous = path.points[(index + count - 1) % count]
                let current = path.points[index]
                let next = path.points[(index + 1) % count]
                if collinear(previous, current, next) {
                    path.points.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        if path.closed, let first = path.points.first {
            path.points.append(first)
        }
    }

    private static func collinear(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        abs((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) <= epsilon
    }

    private static func samePoint(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private static func samePoint(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon && abs(lhs.z - rhs.z) <= epsilon
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
