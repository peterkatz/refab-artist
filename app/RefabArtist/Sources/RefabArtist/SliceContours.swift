import Foundation

struct Vec2: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

struct SlicePath2D: Equatable {
    var points: [Vec2]
    var closed: Bool
}

struct SliceContourLayer: Equatable {
    var position: Double
    var paths: [SlicePath2D]
}

struct StackedSliceContours: Equatable {
    var axis: SliceAxis
    var layers: [SliceContourLayer]
}

enum StackedSliceContourer {
    private static let epsilon = 1.0e-7

    static func generate(model: MeshSummary, plan: StackedSlicePlan) -> StackedSliceContours {
        let triangles = model.geometry.triangleIndices.chunked(into: 3).compactMap { indices -> (Vec3, Vec3, Vec3)? in
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

        let layers = plan.positions.map { position in
            var segments: [Segment2D] = []
            for triangle in triangles {
                if let segment = intersect(triangle: triangle, axis: plan.axis, position: position) {
                    segments.append(segment)
                }
            }
            return SliceContourLayer(position: position, paths: join(segments: segments))
        }
        return StackedSliceContours(axis: plan.axis, layers: layers)
    }

    private struct Segment2D {
        var a: Vec2
        var b: Vec2
    }

    private static func coordinate(_ point: Vec3, axis: SliceAxis) -> Double {
        switch axis {
        case .x: return point.x
        case .y: return point.y
        case .z: return point.z
        }
    }

    private static func project(_ point: Vec3, axis: SliceAxis) -> Vec2 {
        switch axis {
        case .x: return Vec2(x: point.y, y: point.z)
        case .y: return Vec2(x: point.x, y: point.z)
        case .z: return Vec2(x: point.x, y: point.y)
        }
    }

    private static func intersect(triangle: (Vec3, Vec3, Vec3), axis: SliceAxis, position: Double) -> Segment2D? {
        let distances = [triangle.0, triangle.1, triangle.2].map { coordinate($0, axis: axis) - position }
        if isAboveInPlaneEdge(distances: distances) {
            return nil
        }
        var points: [Vec3] = []
        collectEdgeIntersection(points: &points, start: triangle.0, end: triangle.1, axis: axis, position: position)
        collectEdgeIntersection(points: &points, start: triangle.1, end: triangle.2, axis: axis, position: position)
        collectEdgeIntersection(points: &points, start: triangle.2, end: triangle.0, axis: axis, position: position)
        guard points.count == 2, !samePoint(points[0], points[1]) else {
            return nil
        }
        return Segment2D(a: project(points[0], axis: axis), b: project(points[1], axis: axis))
    }

    /// True when two of the triangle's corners lie in the plane and the third
    /// is above it. The edge joining those corners lies in the plane, and the
    /// triangle on its other side would emit it too, so the section would
    /// trace that edge twice (a sphere sliced exactly through its equator ring
    /// came out as one loop walked round twice). Only the triangle below the
    /// plane emits an in-plane edge. `distances` are the corners' signed
    /// distances from the plane.
    static func isAboveInPlaneEdge(distances: [Double]) -> Bool {
        let onPlane = distances.filter { abs($0) <= epsilon }.count
        return onPlane == 2 && distances.contains { $0 > epsilon }
    }

    private static func collectEdgeIntersection(points: inout [Vec3], start: Vec3, end: Vec3, axis: SliceAxis, position: Double) {
        let startDistance = coordinate(start, axis: axis) - position
        let endDistance = coordinate(end, axis: axis) - position
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

        // The other endpoint of `segment`, given that one of its ends is `p`.
        func otherEnd(_ segment: Segment2D, at p: Vec2) -> Vec2? {
            if samePoint(p, segment.a) { return segment.b }
            if samePoint(p, segment.b) { return segment.a }
            return nil
        }
        // All unused segments touching `p`, as (index, far endpoint).
        func candidates(at p: Vec2) -> [(index: Int, far: Vec2)] {
            var out: [(Int, Vec2)] = []
            for k in segments.indices where !used[k] {
                if let far = otherEnd(segments[k], at: p) { out.append((k, far)) }
            }
            return out
        }
        // Pick the candidate whose direction best continues `incoming` (the
        // straightest crossing through a self-pinch). With a single candidate
        // the result IS that candidate, so
        // manifold (2-segment) vertices are untouched and the joined path is
        // byte-identical to the legacy first-match chaining.
        func choose(_ cands: [(index: Int, far: Vec2)], from p: Vec2, incoming: Vec2?) -> (index: Int, far: Vec2) {
            guard cands.count > 1, let incoming else { return cands[0] }
            let inLen = (incoming.x * incoming.x + incoming.y * incoming.y).squareRoot()
            guard inLen > epsilon else { return cands[0] }
            let inX = incoming.x / inLen, inY = incoming.y / inLen
            var chosen = cands[0]
            var bestDot = -Double.greatestFiniteMagnitude
            for c in cands {
                let dx = c.far.x - p.x, dy = c.far.y - p.y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > epsilon else { continue }
                let dot = (dx * inX + dy * inY) / len
                if dot > bestDot { bestDot = dot; chosen = c }
            }
            return chosen
        }

        for startIndex in segments.indices where !used[startIndex] {
            var path = SlicePath2D(points: [segments[startIndex].a, segments[startIndex].b], closed: false)
            used[startIndex] = true

            var extended = true
            while extended {
                extended = false
                for index in segments.indices where !used[index] {
                    let segment = segments[index]
                    guard let first = path.points.first, let last = path.points.last else { continue }
                    if samePoint(last, segment.a) || samePoint(last, segment.b) {
                        let cands = candidates(at: last)
                        let incoming = path.points.count >= 2
                            ? Vec2(x: last.x - path.points[path.points.count - 2].x,
                                   y: last.y - path.points[path.points.count - 2].y)
                            : nil
                        let pick = choose(cands, from: last, incoming: incoming)
                        path.points.append(pick.far)
                        used[pick.index] = true
                    } else if samePoint(first, segment.a) || samePoint(first, segment.b) {
                        let cands = candidates(at: first)
                        let incoming = path.points.count >= 2
                            ? Vec2(x: first.x - path.points[1].x, y: first.y - path.points[1].y)
                            : nil
                        let pick = choose(cands, from: first, incoming: incoming)
                        path.points.insert(pick.far, at: 0)
                        used[pick.index] = true
                    } else {
                        continue
                    }
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

    // MARK: - Sections through cracks

    /// `contours` with every layer's open chains, where the plane passes
    /// through a crack or hole in the mesh, joined end to end, nearest ends
    /// first, into closed outlines across the gaps, as Curve Slices closes
    /// its sections (`CurveSliceContourer.closedChains`). Each outline so
    /// closed is made simple: knots where it crosses itself are cut off
    /// (`sanitizeClosedLoop`) and lobes that touch at a point are split
    /// apart (`CutSheetLayoutBuilder.separatingPinches`); what encloses no
    /// area is dropped. The layer's closed paths stay as they are, except
    /// that one that pinches (touches itself at a point, as a section of two
    /// pieces of the model meeting at a corner is drawn as a figure of
    /// eight) is split into its lobes too; a layer with no open chain and no
    /// pinch is returned unchanged. Stacked Slices cuts these, so no export
    /// holds an open cut or two pieces held at a point.
    static func closingCracks(_ contours: StackedSliceContours) -> StackedSliceContours {
        StackedSliceContours(
            axis: contours.axis,
            layers: contours.layers.map { layer in
                let chains = layer.paths.filter { path in
                    guard !path.closed, let first = path.points.first, let last = path.points.last else { return false }
                    return path.points.count >= 2 && !(path.points.count > 2 && samePoint(first, last))
                }
                let unpinched = layer.paths.filter { path in !chains.contains(path) }.flatMap(splittingPinches)
                guard !chains.isEmpty else {
                    return unpinched.count == layer.paths.count
                        ? layer
                        : SliceContourLayer(position: layer.position, paths: unpinched)
                }
                let kept = unpinched
                let closed = CurveSliceContourer.closedChains(chains.map(\.points))
                    .map(sanitizeClosedLoop)
                    .flatMap { $0.count >= 3 ? CutSheetLayoutBuilder.separatingPinches($0) : [] }
                    .filter { $0.count >= 3 && abs(polygonArea($0)) > 1.0e-6 }
                    .map { SlicePath2D(points: $0 + [$0[0]], closed: true) }
                return SliceContourLayer(position: layer.position, paths: kept + closed)
            }
        )
    }

    /// A closed `path` as the outlines it pinches into
    /// (`CutSheetLayoutBuilder.separatingPinches`): itself when it does not
    /// touch itself, so it comes back point for point.
    private static func splittingPinches(_ path: SlicePath2D) -> [SlicePath2D] {
        var points = path.points
        if points.count > 2, let first = points.first, let last = points.last, samePoint(first, last) {
            points.removeLast()
        }
        guard points.count >= 6 else { return [path] }
        let lobes = CutSheetLayoutBuilder.separatingPinches(points)
        guard lobes.count > 1 else { return [path] }
        return lobes
            .filter { $0.count >= 3 && abs(polygonArea($0)) > 1.0e-6 }
            .map { SlicePath2D(points: $0 + [$0[0]], closed: true) }
    }

    // MARK: - Contour sanitization (simple-polygon repair)

    /// Repair a chained closed loop (no duplicate closing vertex) into a SIMPLE
    /// polygon: drop adjacent near-duplicate vertices, then iteratively snip the
    /// self-intersection "knots" the chainer leaves at pinch / multi-junction
    /// vertices on concave sections — keeping the larger sub-loop (the real
    /// boundary) and discarding the smaller spurious one. A convex section is
    /// already simple, so every step here is a no-op on convex sections.
    static func sanitizeClosedLoop(_ input: [Vec2]) -> [Vec2] {
        var pts = dedupeAdjacentCyclic(input)
        guard pts.count >= 4 else { return pts }
        var iterations = 0
        let maxIterations = pts.count * 2 + 8
        while iterations < maxIterations {
            iterations += 1
            guard let knot = firstSelfIntersection(pts) else { break }
            pts = resolveKnot(pts, i: knot.i, j: knot.j, at: knot.point)
            if pts.count < 4 { break }
        }
        return removeNeedleSpikes(pts)
    }

    /// Collapse needle spikes: a vertex whose incoming and outgoing edges nearly
    /// REVERSE (the outline darts out and comes straight back) is a degenerate
    /// protrusion — a zero-width slit or a stray spur, drawn as a thin diagonal
    /// line on the cut sheet. A proper half-lap notch turns ~90° at its corners,
    /// never reverses, so this leaves real notches intact and is a no-op on
    /// convex sections.
    private static func removeNeedleSpikes(_ input: [Vec2]) -> [Vec2] {
        var pts = input
        guard pts.count >= 4 else { return pts }
        var changed = true
        var guardCount = 0
        while changed, pts.count >= 4, guardCount < input.count + 4 {
            changed = false
            guardCount += 1
            let n = pts.count
            for i in 0..<n {
                let a = pts[(i + n - 1) % n], b = pts[i], c = pts[(i + 1) % n]
                let v1 = Vec2(x: b.x - a.x, y: b.y - a.y)
                let v2 = Vec2(x: c.x - b.x, y: c.y - b.y)
                let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
                let l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
                if l1 <= epsilon || l2 <= epsilon { continue }
                let cosAngle = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
                if cosAngle < -0.94 { // ~160°+ reversal = needle tip
                    pts.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return pts
    }

    private static func dedupeAdjacentCyclic(_ input: [Vec2]) -> [Vec2] {
        guard input.count >= 2 else { return input }
        var out: [Vec2] = []
        for p in input where out.last.map({ !samePoint($0, p) }) ?? true {
            out.append(p)
        }
        // Drop a trailing point coincident with the first (cyclic duplicate).
        if out.count >= 2, let f = out.first, let l = out.last, samePoint(f, l) {
            out.removeLast()
        }
        return out
    }

    /// First pair of non-adjacent edges (i→i+1, j→j+1) that PROPERLY cross, with
    /// the crossing point. Edges sharing a vertex are skipped so a normal vertex
    /// is never mistaken for a crossing.
    private static func firstSelfIntersection(_ pts: [Vec2]) -> (i: Int, j: Int, point: Vec2)? {
        let n = pts.count
        guard n >= 4 else { return nil }
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            for offset in 2..<(n - 1) {
                let j = (i + offset) % n
                // Skip edges adjacent to edge i (they legitimately share a vertex).
                if j == i || (j + 1) % n == i || j == (i + 1) % n { continue }
                let c = pts[j], d = pts[(j + 1) % n]
                if let x = properIntersection(a, b, c, d) {
                    return (i, j, x)
                }
            }
        }
        return nil
    }

    /// Split the loop at a self-crossing of edges i→i+1 and j→j+1 (i < j in
    /// cyclic order) meeting at `x`, and keep the larger-area sub-loop. The
    /// smaller loop is the spurious knot the chainer introduced.
    private static func resolveKnot(_ pts: [Vec2], i: Int, j: Int, at x: Vec2) -> [Vec2] {
        let n = pts.count
        // Inner loop: x, pts[i+1], …, pts[j]   (the vertices strictly between the
        // two crossing edges, walked forward from i+1 to j).
        var inner: [Vec2] = [x]
        var k = (i + 1) % n
        while true {
            inner.append(pts[k])
            if k == j { break }
            k = (k + 1) % n
        }
        // Outer loop: x, pts[j+1], …, pts[i]   (the remaining vertices).
        var outer: [Vec2] = [x]
        k = (j + 1) % n
        while true {
            outer.append(pts[k])
            if k == i { break }
            k = (k + 1) % n
        }
        let keep = abs(polygonArea(outer)) >= abs(polygonArea(inner)) ? outer : inner
        return dedupeAdjacentCyclic(keep)
    }

    private static func polygonArea(_ pts: [Vec2]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var area = 0.0
        for idx in 0..<pts.count {
            let a = pts[idx], b = pts[(idx + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Proper segment crossing (interior of both segments). Returns the crossing
    /// point, or nil for parallel / endpoint-only / non-crossing pairs.
    private static func properIntersection(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Vec2? {
        let r = Vec2(x: b.x - a.x, y: b.y - a.y)
        let s = Vec2(x: d.x - c.x, y: d.y - c.y)
        let denom = r.x * s.y - r.y * s.x
        if abs(denom) <= epsilon { return nil } // parallel / collinear
        let qp = Vec2(x: c.x - a.x, y: c.y - a.y)
        let t = (qp.x * s.y - qp.y * s.x) / denom
        let u = (qp.x * r.y - qp.y * r.x) / denom
        let edge = 1.0e-9
        guard t > edge, t < 1 - edge, u > edge, u < 1 - edge else { return nil }
        return Vec2(x: a.x + r.x * t, y: a.y + r.y * t)
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
