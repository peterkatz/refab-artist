import Foundation

/// Builds the stacked slice solids WITH the dowel holes carved through them,
/// for the 3D mesh exports (OBJ/STL). The flat exports already drill the
/// circles; the 3D exports previously emitted solid slabs, so the printed or
/// re-imported parts had no holes to thread.
///
/// Holes are carved by bridging each hole polygon into its containing outer
/// loop (the classic ear-clipping-with-holes reduction), then triangulating
/// the bridged caps and adding inner tube walls.
enum StackedDowelMeshBuilder {
    static let holeSegments = 24

    static func layers(
        contours: StackedSliceContours,
        materialThickness: Double,
        dowels: DxfExporter.DowelSettings?
    ) -> [SliceMeshExportLayer] {
        let placements = DowelLayout.placements(layers: contours.layers, settings: dowels)
        guard !placements.isEmpty, let dowels else { return [] }
        let radius = dowels.diameter / 2

        var result: [SliceMeshExportLayer] = []
        for (layerIndex, layer) in contours.layers.enumerated() {
            var triangles: [(Vec3, Vec3, Vec3)] = []
            let half = materialThickness / 2

            for path in layer.paths where path.closed {
                var outer = path.points
                if let first = outer.first, let last = outer.last,
                   abs(first.x - last.x) <= 1.0e-9, abs(first.y - last.y) <= 1.0e-9 {
                    outer.removeLast()
                }
                guard outer.count >= 3 else { continue }
                if signedArea(outer) < 0 { outer.reverse() } // outer CCW

                // Holes whose center this outer loop contains, with the
                // outline fully inside (otherwise skip — no partial holes).
                let holes = placements.map(\.position).compactMap { center -> [Vec2]? in
                    guard DowelLayout.contains(outer, point: center) else { return nil }
                    let polygon = dowels.shape.outline(center: center, diameter: dowels.diameter)
                        ?? circlePolygon(center: center, radius: radius)
                    guard polygon.allSatisfy({ DowelLayout.contains(outer, point: $0) }) else { return nil }
                    return polygon
                }

                let lift: (Vec2, Double) -> Vec3 = { p, d in
                    let base = liftPoint(p, axis: contours.axis, depth: layer.position)
                    return offsetAlongAxis(base, axis: contours.axis, distance: d)
                }

                if holes.isEmpty {
                    appendSolid(outer: outer, lift: lift, half: half, to: &triangles)
                } else {
                    var bridged = outer
                    for hole in holes {
                        bridged = bridge(outer: bridged, hole: hole)
                    }
                    // Caps from the bridged polygon.
                    let capTriangles = ViewportSliceSolidRenderData.triangulate(bridged)
                    let lower = bridged.map { lift($0, -half) }
                    let upper = bridged.map { lift($0, half) }
                    for (a, b, c) in capTriangles {
                        triangles.append((lower[a], lower[c], lower[b]))
                        triangles.append((upper[a], upper[b], upper[c]))
                    }
                    // Outer walls from the ORIGINAL ring.
                    appendWalls(ring: outer.map { ($0, lift($0, -half), lift($0, half)) }, reversed: false, to: &triangles)
                    // Hole tube walls, wound inward.
                    for hole in holes {
                        appendWalls(ring: hole.map { ($0, lift($0, -half), lift($0, half)) }, reversed: true, to: &triangles)
                    }
                }
            }

            guard !triangles.isEmpty else { continue }
            result.append(
                SliceMeshExportLayer(
                    name: String(format: "slice_%03d", layerIndex + 1),
                    mesh: ViewportSliceSolidRenderData.flatShadedMesh(from: triangles)
                )
            )
        }
        return result
    }

    // MARK: - Geometry helpers

    private static func appendSolid(outer: [Vec2], lift: (Vec2, Double) -> Vec3, half: Double, to triangles: inout [(Vec3, Vec3, Vec3)]) {
        let capTriangles = ViewportSliceSolidRenderData.triangulate(outer)
        let lower = outer.map { lift($0, -half) }
        let upper = outer.map { lift($0, half) }
        for (a, b, c) in capTriangles {
            triangles.append((lower[a], lower[c], lower[b]))
            triangles.append((upper[a], upper[b], upper[c]))
        }
        appendWalls(ring: outer.map { ($0, lift($0, -half), lift($0, half)) }, reversed: false, to: &triangles)
    }

    private static func appendWalls(ring: [(Vec2, Vec3, Vec3)], reversed: Bool, to triangles: inout [(Vec3, Vec3, Vec3)]) {
        let count = ring.count
        guard count >= 3 else { return }
        for index in 0..<count {
            let next = (index + 1) % count
            let (lowA, upA) = (ring[index].1, ring[index].2)
            let (lowB, upB) = (ring[next].1, ring[next].2)
            if reversed {
                triangles.append((lowA, upB, lowB))
                triangles.append((lowA, upA, upB))
            } else {
                triangles.append((lowA, lowB, upB))
                triangles.append((lowA, upB, upA))
            }
        }
    }

    /// CW circle polygon (opposite winding to the CCW outer = hole).
    private static func circlePolygon(center: Vec2, radius: Double) -> [Vec2] {
        (0..<holeSegments).map { index in
            let angle = -2.0 * Double.pi * Double(index) / Double(holeSegments)
            return Vec2(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// Bridge a hole polygon into the outer loop: connect the hole's
    /// rightmost vertex to the nearest visible outer vertex, traversing the
    /// hole between two coincident (epsilon-nudged) bridge edges. The result
    /// is a single simple polygon the ear-clipper handles.
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
                let a = outer[index]
                let b = outer[(index + 1) % outer.count]
                if segmentsIntersect(from, to, a, b) { return false }
            }
            for index in hole.indices {
                let a = hole[index]
                let b = hole[(index + 1) % hole.count]
                if segmentsIntersect(from, to, a, b) { return false }
            }
            return true
        }

        let candidates = outer.indices.sorted {
            distanceSquared(outer[$0], holePoint) < distanceSquared(outer[$1], holePoint)
        }
        let outerIndex = candidates.first(where: { visible(outer[$0], holePoint) }) ?? candidates[0]

        // Walk the hole starting at its bridge vertex; nudge the duplicated
        // bridge endpoints so the ear-clipper never sees coincident points.
        var holeWalk: [Vec2] = []
        for step in 0...hole.count {
            holeWalk.append(hole[(holeStartIndex + step) % hole.count])
        }
        let towardOuter = normalizedDirection(from: holePoint, to: outer[outerIndex])
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

    private static func normalizedDirection(from: Vec2, to: Vec2) -> Vec2 {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return Vec2(x: 1, y: 0) }
        return Vec2(x: dx / length, y: dy / length)
    }

    private static func signedArea(_ points: [Vec2]) -> Double {
        var area = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            area += points[index].x * points[next].y - points[next].x * points[index].y
        }
        return area / 2
    }

    private static func liftPoint(_ point: Vec2, axis: SliceAxis, depth: Double) -> Vec3 {
        switch axis {
        case .x: return Vec3(x: depth, y: point.x, z: point.y)
        case .y: return Vec3(x: point.x, y: depth, z: point.y)
        case .z: return Vec3(x: point.x, y: point.y, z: depth)
        }
    }

    private static func offsetAlongAxis(_ point: Vec3, axis: SliceAxis, distance: Double) -> Vec3 {
        switch axis {
        case .x: return Vec3(x: point.x + distance, y: point.y, z: point.z)
        case .y: return Vec3(x: point.x, y: point.y + distance, z: point.z)
        case .z: return Vec3(x: point.x, y: point.y, z: point.z + distance)
        }
    }
}
