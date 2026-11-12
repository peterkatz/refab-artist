import Foundation

enum ViewportSliceSolidRenderData {
    static func mesh(contours: StackedSliceContours, layerIndex: Int, materialThickness: Double) -> ViewportFlatShadedMesh? {
        guard contours.layers.indices.contains(layerIndex) else {
            return nil
        }

        let layer = contours.layers[layerIndex]
        return mesh(
            paths: layer.paths,
            materialThickness: materialThickness,
            scenePoint: { lift($0, axis: contours.axis, depth: layer.position) },
            normal: axisNormal(contours.axis)
        )
    }

    static func mesh(
        paths: [SlicePath2D],
        materialThickness: Double,
        scenePoint: (Vec2) -> Vec3,
        normal: Vec3
    ) -> ViewportFlatShadedMesh? {
        guard materialThickness.isFinite, materialThickness > 0 else {
            return nil
        }
        let normal = normalized(normal)
        guard isFinite(normal), normal != Vec3(x: 0, y: 0, z: 0) else {
            return nil
        }

        let halfThickness = materialThickness / 2
        var triangles: [(Vec3, Vec3, Vec3)] = []

        for island in CutSheetLayoutBuilder.islandize(paths: paths) {
            guard var outer = island.loops.first, outer.count >= 3 else { continue }
            if signedArea(outer) < 0 { outer.reverse() }
            let holes = island.loops.dropFirst().map { loop -> [Vec2] in
                var hole = loop
                if signedArea(hole) > 0 { hole.reverse() }
                return hole
            }

            var capLoop = outer
            for hole in holes {
                capLoop = bridge(outer: capLoop, hole: hole)
            }

            let scenePoints = capLoop.map(scenePoint)
            let lower = scenePoints.map { offset($0, along: normal, distance: -halfThickness) }
            let upper = scenePoints.map { offset($0, along: normal, distance: halfThickness) }

            // Ear-clipped caps. Holes are bridged into one simple polygon so
            // hollow slice loops stay open in the 3D preview instead of
            // rendering as filled slabs.
            let capIndices = triangulate(capLoop)
            for (a, b, c) in capIndices {
                triangles.append((lower[a], lower[c], lower[b]))
                triangles.append((upper[a], upper[b], upper[c]))
            }

            appendSides(
                lower: outer.map { offset(scenePoint($0), along: normal, distance: -halfThickness) },
                upper: outer.map { offset(scenePoint($0), along: normal, distance: halfThickness) },
                to: &triangles
            )
            for hole in holes {
                appendSidesReversed(
                    lower: hole.map { offset(scenePoint($0), along: normal, distance: -halfThickness) },
                    upper: hole.map { offset(scenePoint($0), along: normal, distance: halfThickness) },
                    to: &triangles
                )
            }
        }

        guard !triangles.isEmpty else {
            return nil
        }
        return flatShadedMesh(from: triangles)
    }

    /// Ear-clipping triangulation of a simple polygon (handles concave
    /// outlines). Returns triangles as CCW index triples into `points`.
    /// Falls back to a fan if the polygon is too degenerate to clip.
    static func triangulate(_ points: [Vec2]) -> [(Int, Int, Int)] {
        let n = points.count
        guard n >= 3 else { return [] }
        if n == 3 { return [(0, 1, 2)] }

        // Work in CCW orientation.
        var area = 0.0
        for i in 0..<n {
            let j = (i + 1) % n
            area += points[i].x * points[j].y - points[j].x * points[i].y
        }
        let ccw = area >= 0
        var remaining: [Int] = ccw ? Array(0..<n) : Array((0..<n).reversed())

        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
            let d1 = cross(a, b, p)
            let d2 = cross(b, c, p)
            let d3 = cross(c, a, p)
            let hasNeg = d1 < -1.0e-12 || d2 < -1.0e-12 || d3 < -1.0e-12
            let hasPos = d1 > 1.0e-12 || d2 > 1.0e-12 || d3 > 1.0e-12
            return !(hasNeg && hasPos)
        }

        // Only REFLEX vertices can block an ear — testing every remaining
        // vertex per candidate would be cubic on big organic contours.
        func isReflex(at listIndex: Int, in list: [Int]) -> Bool {
            let count = list.count
            let a = points[list[(listIndex + count - 1) % count]]
            let b = points[list[listIndex]]
            let c = points[list[(listIndex + 1) % count]]
            return cross(a, b, c) < -1.0e-12
        }

        var result: [(Int, Int, Int)] = []
        var stuckPasses = 0
        var i = 0
        while remaining.count > 3 {
            let count = remaining.count
            if stuckPasses > count + 2 {
                // Degenerate/self-intersecting input — fall back to a fan so
                // SOMETHING renders rather than spinning forever.
                let v0 = remaining[0]
                for k in 1..<(remaining.count - 1) {
                    result.append((v0, remaining[k], remaining[k + 1]))
                }
                return result
            }
            let prevIdx = (i + count - 1) % count
            let nextIdx = (i + 1) % count
            let prev = remaining[prevIdx]
            let curr = remaining[i]
            let next = remaining[nextIdx]
            let a = points[prev], b = points[curr], c = points[next]
            if cross(a, b, c) > 1.0e-12 {
                var isEar = true
                for (listIndex, other) in remaining.enumerated()
                where other != prev && other != curr && other != next {
                    guard isReflex(at: listIndex, in: remaining) else { continue }
                    if pointInTriangle(points[other], a, b, c) {
                        isEar = false
                        break
                    }
                }
                if isEar {
                    result.append((prev, curr, next))
                    remaining.remove(at: i)
                    if i >= remaining.count { i = 0 }
                    stuckPasses = 0
                    continue
                }
            }
            i += 1
            if i >= remaining.count {
                i = 0
                stuckPasses += 1
            }
        }
        result.append((remaining[0], remaining[1], remaining[2]))
        return result
    }

    static func meshWithRectangularCutouts(
        outerPaths: [SlicePath2D],
        cutoutPaths: [SlicePath2D],
        materialThickness: Double,
        scenePoint: (Vec2) -> Vec3,
        normal: Vec3
    ) -> ViewportFlatShadedMesh? {
        let cutoutPolygons = cutoutPaths.compactMap(cutoutPolygon)
        guard !cutoutPolygons.isEmpty else {
            return mesh(paths: outerPaths, materialThickness: materialThickness, scenePoint: scenePoint, normal: normal)
        }

        var panelCells: [SlicePath2D] = []
        for path in outerPaths {
            guard let outerRect = rectangleBounds(path) else {
                return mesh(paths: outerPaths, materialThickness: materialThickness, scenePoint: scenePoint, normal: normal)
            }
            panelCells.append(contentsOf: cells(for: outerRect, subtracting: cutoutPolygons))
        }

        return mesh(paths: panelCells, materialThickness: materialThickness, scenePoint: scenePoint, normal: normal)
    }

    private static func appendSides(lower: [Vec3], upper: [Vec3], to triangles: inout [(Vec3, Vec3, Vec3)]) {
        guard lower.count == upper.count, lower.count >= 3 else {
            return
        }
        for index in 0..<lower.count {
            let next = (index + 1) % lower.count
            triangles.append((lower[index], lower[next], upper[next]))
            triangles.append((lower[index], upper[next], upper[index]))
        }
    }

    private static func appendSidesReversed(lower: [Vec3], upper: [Vec3], to triangles: inout [(Vec3, Vec3, Vec3)]) {
        guard lower.count == upper.count, lower.count >= 3 else {
            return
        }
        for index in 0..<lower.count {
            let next = (index + 1) % lower.count
            triangles.append((lower[index], upper[next], lower[next]))
            triangles.append((lower[index], upper[index], upper[next]))
        }
    }

    static func flatShadedMesh(from triangles: [(Vec3, Vec3, Vec3)]) -> ViewportFlatShadedMesh {
        var vertices: [Vec3] = []
        var normals: [Vec3] = []
        var indices: [Int32] = []

        for triangle in triangles {
            let normal = normalized(cross(subtract(triangle.1, triangle.0), subtract(triangle.2, triangle.0)))
            for point in [triangle.0, triangle.1, triangle.2] {
                vertices.append(point)
                normals.append(normal)
                indices.append(Int32(indices.count))
            }
        }

        return ViewportFlatShadedMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    private static func normalizedClosedPath(_ path: SlicePath2D) -> [Vec2]? {
        // A closed polygon is valid with 3 vertices. The old >=4 floor assumed
        // every caller repeats the first vertex at the end (triangle = 4 pts),
        // but the folded panels pass a bare triangle (3 pts, no repeat) — so
        // EVERY folded panel failed here and the viewport drew the smooth model
        // instead of the constructed faceted shape. Accept 3+, and still strip a
        // trailing duplicate when a caller does repeat it.
        guard path.closed, path.points.count >= 3 else {
            return nil
        }
        var points = path.points
        if points.count >= 4, let first = points.first,
           let last = points.last,
           samePoint(first, last) {
            points.removeLast()
        }
        guard points.count >= 3 else {
            return nil
        }
        return points
    }

    private static func rectangleBounds(_ path: SlicePath2D) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard let points = normalizedClosedPath(path), points.count == 4 else {
            return nil
        }
        let xs = Array(Set(points.map { rounded($0.x) })).sorted()
        let ys = Array(Set(points.map { rounded($0.y) })).sorted()
        guard xs.count == 2, ys.count == 2 else {
            return nil
        }
        let corners = Set(points.map { "\(rounded($0.x)):\(rounded($0.y))" })
        let expected = Set([
            "\(xs[0]):\(ys[0])",
            "\(xs[1]):\(ys[0])",
            "\(xs[1]):\(ys[1])",
            "\(xs[0]):\(ys[1])"
        ])
        guard corners == expected else {
            return nil
        }
        return (minX: xs[0], maxX: xs[1], minY: ys[0], maxY: ys[1])
    }

    private struct CutoutPolygon {
        var points: [Vec2]
        var bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)
    }

    private struct CutoutInterval {
        var bottomMinX: Double
        var bottomMaxX: Double
        var topMinX: Double
        var topMaxX: Double
        var midMinX: Double
        var midMaxX: Double
    }

    private static func cutoutPolygon(_ path: SlicePath2D) -> CutoutPolygon? {
        guard let points = normalizedClosedPath(path), points.count >= 3 else {
            return nil
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max(),
              maxX - minX > 1.0e-7,
              maxY - minY > 1.0e-7 else {
            return nil
        }
        return CutoutPolygon(points: points, bounds: (minX: minX, maxX: maxX, minY: minY, maxY: maxY))
    }

    private static func cells(
        for outer: (minX: Double, maxX: Double, minY: Double, maxY: Double),
        subtracting cutouts: [CutoutPolygon]
    ) -> [SlicePath2D] {
        let activeCutouts = cutouts.compactMap { cutout -> CutoutPolygon? in
            let minX = max(outer.minX, cutout.bounds.minX)
            let maxX = min(outer.maxX, cutout.bounds.maxX)
            let minY = max(outer.minY, cutout.bounds.minY)
            let maxY = min(outer.maxY, cutout.bounds.maxY)
            guard maxX - minX > 1.0e-7, maxY - minY > 1.0e-7 else {
                return nil
            }
            return cutout
        }
        guard !activeCutouts.isEmpty else {
            return [rectanglePath(minX: outer.minX, maxX: outer.maxX, minY: outer.minY, maxY: outer.maxY)]
        }

        let yBreaks = ([outer.minY, outer.maxY] + activeCutouts.flatMap {
            [max(outer.minY, $0.bounds.minY), min(outer.maxY, $0.bounds.maxY)]
        }).uniqueSorted()
        var cells: [SlicePath2D] = []

        for yIndex in 0..<(yBreaks.count - 1) {
            let minY = yBreaks[yIndex]
            let maxY = yBreaks[yIndex + 1]
            guard maxY - minY > 1.0e-7 else {
                continue
            }
            let intervals = activeCutouts.compactMap {
                interval(for: $0, slabMinY: minY, slabMaxY: maxY, outer: outer)
            }.sorted { $0.midMinX < $1.midMinX }

            guard !intervals.isEmpty else {
                cells.append(rectanglePath(minX: outer.minX, maxX: outer.maxX, minY: minY, maxY: maxY))
                continue
            }

            var cursorBottom = outer.minX
            var cursorTop = outer.minX
            var cursorMid = outer.minX
            for interval in intervals {
                if interval.midMaxX <= cursorMid + 1.0e-7 {
                    cursorBottom = max(cursorBottom, interval.bottomMaxX)
                    cursorTop = max(cursorTop, interval.topMaxX)
                    cursorMid = max(cursorMid, interval.midMaxX)
                    continue
                }

                appendSlabCell(
                    minY: minY,
                    maxY: maxY,
                    bottomLeftX: cursorBottom,
                    bottomRightX: interval.bottomMinX,
                    topRightX: interval.topMinX,
                    topLeftX: cursorTop,
                    midLeftX: cursorMid,
                    midRightX: interval.midMinX,
                    to: &cells
                )

                cursorBottom = max(cursorBottom, interval.bottomMaxX)
                cursorTop = max(cursorTop, interval.topMaxX)
                cursorMid = max(cursorMid, interval.midMaxX)
            }

            appendSlabCell(
                minY: minY,
                maxY: maxY,
                bottomLeftX: cursorBottom,
                bottomRightX: outer.maxX,
                topRightX: outer.maxX,
                topLeftX: cursorTop,
                midLeftX: cursorMid,
                midRightX: outer.maxX,
                to: &cells
            )
        }
        return cells
    }

    private static func interval(
        for cutout: CutoutPolygon,
        slabMinY: Double,
        slabMaxY: Double,
        outer: (minX: Double, maxX: Double, minY: Double, maxY: Double)
    ) -> CutoutInterval? {
        let midY = (slabMinY + slabMaxY) / 2
        guard cutout.bounds.maxY >= slabMinY - 1.0e-7,
              cutout.bounds.minY <= slabMaxY + 1.0e-7,
              let bottom = horizontalInterval(for: cutout, atY: slabMinY),
              let top = horizontalInterval(for: cutout, atY: slabMaxY),
              let mid = horizontalInterval(for: cutout, atY: midY) else {
            return nil
        }

        let clippedBottom = clip(bottom, minX: outer.minX, maxX: outer.maxX)
        let clippedTop = clip(top, minX: outer.minX, maxX: outer.maxX)
        let clippedMid = clip(mid, minX: outer.minX, maxX: outer.maxX)
        guard clippedMid.maxX - clippedMid.minX > 1.0e-7 else {
            return nil
        }
        return CutoutInterval(
            bottomMinX: clippedBottom.minX,
            bottomMaxX: clippedBottom.maxX,
            topMinX: clippedTop.minX,
            topMaxX: clippedTop.maxX,
            midMinX: clippedMid.minX,
            midMaxX: clippedMid.maxX
        )
    }

    private static func horizontalInterval(
        for cutout: CutoutPolygon,
        atY y: Double
    ) -> (minX: Double, maxX: Double)? {
        var intersections: [Double] = []
        let points = cutout.points
        for index in points.indices {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            if abs(start.y - end.y) < 1.0e-7 {
                if abs(y - start.y) < 1.0e-7 {
                    intersections.append(start.x)
                    intersections.append(end.x)
                }
                continue
            }
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            guard y >= minY - 1.0e-7, y <= maxY + 1.0e-7 else {
                continue
            }
            let t = (y - start.y) / (end.y - start.y)
            guard t >= -1.0e-7, t <= 1 + 1.0e-7 else {
                continue
            }
            intersections.append(start.x + (end.x - start.x) * t)
        }
        let xs = intersections.map(rounded).uniqueSorted()
        guard let minX = xs.first, let maxX = xs.last, maxX - minX > 1.0e-7 else {
            return nil
        }
        return (minX: minX, maxX: maxX)
    }

    private static func clip(
        _ interval: (minX: Double, maxX: Double),
        minX: Double,
        maxX: Double
    ) -> (minX: Double, maxX: Double) {
        (minX: max(minX, interval.minX), maxX: min(maxX, interval.maxX))
    }

    private static func appendSlabCell(
        minY: Double,
        maxY: Double,
        bottomLeftX: Double,
        bottomRightX: Double,
        topRightX: Double,
        topLeftX: Double,
        midLeftX: Double,
        midRightX: Double,
        to cells: inout [SlicePath2D]
    ) {
        guard midRightX - midLeftX > 1.0e-7 else {
            return
        }
        cells.append(closedPath([
            Vec2(x: bottomLeftX, y: minY),
            Vec2(x: bottomRightX, y: minY),
            Vec2(x: topRightX, y: maxY),
            Vec2(x: topLeftX, y: maxY)
        ]))
    }

    private static func rectanglePath(minX: Double, maxX: Double, minY: Double, maxY: Double) -> SlicePath2D {
        closedPath([
            Vec2(x: minX, y: minY),
            Vec2(x: maxX, y: minY),
            Vec2(x: maxX, y: maxY),
            Vec2(x: minX, y: maxY)
        ])
    }

    private static func closedPath(_ points: [Vec2]) -> SlicePath2D {
        guard let first = points.first else {
            return SlicePath2D(points: [], closed: false)
        }
        return SlicePath2D(points: points + [first], closed: true)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private static func lift(_ point: Vec2, axis: SliceAxis, depth: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: depth, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: depth, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: depth)
        }
    }

    private static func axisNormal(_ axis: SliceAxis) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: 1, y: 0, z: 0)
        case .y:
            return Vec3(x: 0, y: 1, z: 0)
        case .z:
            return Vec3(x: 0, y: 0, z: 1)
        }
    }

    private static func offset(_ point: Vec3, along normal: Vec3, distance: Double) -> Vec3 {
        Vec3(
            x: point.x + normal.x * distance,
            y: point.y + normal.y * distance,
            z: point.z + normal.z * distance
        )
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

    private static func normalized(_ vector: Vec3) -> Vec3 {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard length > 0 else {
            return Vec3(x: 0, y: 0, z: 0)
        }
        return Vec3(x: vector.x / length, y: vector.y / length, z: vector.z / length)
    }

    private static func isFinite(_ point: Vec3) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }

    private static func bridge(outer: [Vec2], hole: [Vec2]) -> [Vec2] {
        guard let holeStartIndex = hole.indices.max(by: { hole[$0].x < hole[$1].x }) else { return outer }
        let holePoint = hole[holeStartIndex]

        func segmentsIntersect(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
            func orient(_ p: Vec2, _ q: Vec2, _ r: Vec2) -> Double {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            let o1 = orient(a, b, c)
            let o2 = orient(a, b, d)
            let o3 = orient(c, d, a)
            let o4 = orient(c, d, b)
            return (o1 * o2 < -1.0e-12) && (o3 * o4 < -1.0e-12)
        }
        func visible(_ from: Vec2, _ to: Vec2) -> Bool {
            for index in outer.indices {
                if segmentsIntersect(from, to, outer[index], outer[(index + 1) % outer.count]) { return false }
            }
            for index in hole.indices {
                if segmentsIntersect(from, to, hole[index], hole[(index + 1) % hole.count]) { return false }
            }
            return true
        }

        let candidates = outer.indices.sorted {
            distanceSquared(outer[$0], holePoint) < distanceSquared(outer[$1], holePoint)
        }
        let outerIndex = candidates.first(where: { visible(outer[$0], holePoint) }) ?? candidates[0]
        let towardOuter = normalizedDirection(from: holePoint, to: outer[outerIndex])

        var holeWalk: [Vec2] = []
        for step in 0...hole.count {
            holeWalk.append(hole[(holeStartIndex + step) % hole.count])
        }
        holeWalk[0] = Vec2(x: holeWalk[0].x + towardOuter.x * 1.0e-6, y: holeWalk[0].y + towardOuter.y * 1.0e-6)
        holeWalk[holeWalk.count - 1] = Vec2(
            x: holeWalk[holeWalk.count - 1].x - towardOuter.x * 1.0e-6,
            y: holeWalk[holeWalk.count - 1].y - towardOuter.y * 1.0e-6
        )

        var result: [Vec2] = []
        for index in 0...outerIndex {
            result.append(outer[index])
        }
        result.append(contentsOf: holeWalk)
        result.append(Vec2(
            x: outer[outerIndex].x + towardOuter.x * -1.0e-6,
            y: outer[outerIndex].y + towardOuter.y * -1.0e-6
        ))
        for index in (outerIndex + 1)..<outer.count {
            result.append(outer[index])
        }
        return result
    }

    private static func distanceSquared(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func normalizedDirection(from a: Vec2, to b: Vec2) -> Vec2 {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 1.0e-12 else { return Vec2(x: 1, y: 0) }
        return Vec2(x: dx / length, y: dy / length)
    }

    private static func samePoint(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
        abs(lhs.x - rhs.x) <= 1.0e-7 && abs(lhs.y - rhs.y) <= 1.0e-7
    }
}

private extension Array where Element == Double {
    func uniqueSorted() -> [Double] {
        Array(Set(map { ($0 * 1_000_000).rounded() / 1_000_000 })).sorted()
    }
}
