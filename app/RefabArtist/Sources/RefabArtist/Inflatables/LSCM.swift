import Foundation

struct InflatableFlattenedChart: Equatable {
    var chart: InflatableChart
    var outline2D: [Vec2]
    var uvByVertex: [Vec2]
    var maxStretch: Double
}

enum LSCM {
    static func flatten(_ chart: InflatableChart) -> InflatableFlattenedChart? {
        let mesh = chart.mesh
        guard mesh.vertices.count >= 3, mesh.triangleIndices.count >= 3 else { return nil }

        var uv = Array(repeating: Vec2(x: .nan, y: .nan), count: mesh.vertices.count)
        let faces = triangleFaces(mesh)
        guard !faces.isEmpty else { return nil }
        let edgeToFaces = faceAdjacency(faces)
        var placedFaces = Set<Int>()

        for seed in faces.indices where !placedFaces.contains(seed) {
            placeSeedFace(faces[seed], vertices: mesh.vertices, uv: &uv)
            unfold(from: seed, faces: faces, vertices: mesh.vertices, edgeToFaces: edgeToFaces, uv: &uv, placedFaces: &placedFaces)
        }

        guard uv.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let outline = boundaryOutline(faces: faces, edgeToFaces: edgeToFaces, uv: uv) ?? convexHull(uv)
        guard outline.count >= 3 else { return nil }

        return InflatableFlattenedChart(
            chart: chart,
            outline2D: outline,
            uvByVertex: uv,
            maxStretch: estimateStretch(mesh: mesh, uv: uv)
        )
    }

    private struct Face {
        var id: Int
        var vertices: [Int]
    }

    private struct EdgeKey: Hashable {
        var a: Int
        var b: Int

        init(_ first: Int, _ second: Int) {
            if first <= second {
                a = first
                b = second
            } else {
                a = second
                b = first
            }
        }
    }

    private static func triangleFaces(_ mesh: MeshGeometryData) -> [Face] {
        stride(from: 0, to: mesh.triangleIndices.count - mesh.triangleIndices.count % 3, by: 3).compactMap { offset in
            let indices = [
                Int(mesh.triangleIndices[offset]),
                Int(mesh.triangleIndices[offset + 1]),
                Int(mesh.triangleIndices[offset + 2])
            ]
            guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { return nil }
            return Face(id: offset / 3, vertices: indices)
        }
    }

    private static func faceAdjacency(_ faces: [Face]) -> [EdgeKey: [Int]] {
        var result: [EdgeKey: [Int]] = [:]
        for face in faces {
            for edge in faceEdges(face.vertices) {
                result[EdgeKey(edge.0, edge.1), default: []].append(face.id)
            }
        }
        return result
    }

    private static func placeSeedFace(_ face: Face, vertices: [Vec3], uv: inout [Vec2]) {
        let tri = face.vertices
        guard tri.count == 3,
              vertices.indices.contains(tri[0]),
              vertices.indices.contains(tri[1]),
              vertices.indices.contains(tri[2]) else { return }
        let a = tri[0], b = tri[1], c = tri[2]
        let ab = max(distance(vertices[a], vertices[b]), 1.0e-9)
        let ac = max(distance(vertices[a], vertices[c]), 1.0e-9)
        let bc = max(distance(vertices[b], vertices[c]), 1.0e-9)
        let x = ((ac * ac) + (ab * ab) - (bc * bc)) / (2 * ab)
        let y = max((ac * ac) - (x * x), 0).squareRoot()
        uv[a] = Vec2(x: 0, y: 0)
        uv[b] = Vec2(x: ab, y: 0)
        uv[c] = Vec2(x: x, y: y)
    }

    private static func unfold(
        from seed: Int,
        faces: [Face],
        vertices: [Vec3],
        edgeToFaces: [EdgeKey: [Int]],
        uv: inout [Vec2],
        placedFaces: inout Set<Int>
    ) {
        var queue = [seed]
        placedFaces.insert(seed)
        while let faceID = queue.first {
            queue.removeFirst()
            guard faces.indices.contains(faceID) else { continue }
            let face = faces[faceID]
            for edge in faceEdges(face.vertices) {
                let key = EdgeKey(edge.0, edge.1)
                guard let adjacent = edgeToFaces[key] else { continue }
                for neighborID in adjacent where neighborID != faceID && !placedFaces.contains(neighborID) {
                    guard faces.indices.contains(neighborID) else { continue }
                    let neighbor = faces[neighborID]
                    if placeNeighbor(neighbor, across: key, from: face, vertices: vertices, uv: &uv) {
                        placedFaces.insert(neighborID)
                        queue.append(neighborID)
                    }
                }
            }
        }
    }

    private static func placeNeighbor(
        _ neighbor: Face,
        across edge: EdgeKey,
        from current: Face,
        vertices: [Vec3],
        uv: inout [Vec2]
    ) -> Bool {
        guard uv.indices.contains(edge.a), uv.indices.contains(edge.b),
              uv[edge.a].x.isFinite, uv[edge.a].y.isFinite,
              uv[edge.b].x.isFinite, uv[edge.b].y.isFinite,
              let opposite = neighbor.vertices.first(where: { $0 != edge.a && $0 != edge.b }),
              vertices.indices.contains(edge.a),
              vertices.indices.contains(edge.b),
              vertices.indices.contains(opposite) else { return false }

        if uv.indices.contains(opposite), uv[opposite].x.isFinite, uv[opposite].y.isFinite {
            return true
        }

        let a2 = uv[edge.a]
        let b2 = uv[edge.b]
        let da = distance(vertices[edge.a], vertices[opposite])
        let db = distance(vertices[edge.b], vertices[opposite])
        guard let candidates = circleIntersections(a: a2, radiusA: da, b: b2, radiusB: db) else { return false }

        let currentOpposite = current.vertices.first { $0 != edge.a && $0 != edge.b }
        let currentSide = currentOpposite.flatMap { index -> Double? in
            guard uv.indices.contains(index), uv[index].x.isFinite, uv[index].y.isFinite else { return nil }
            return signedArea(a2, b2, uv[index])
        } ?? 0
        let chosen: Vec2
        if abs(currentSide) > 1.0e-9 {
            let side0 = signedArea(a2, b2, candidates.0)
            chosen = side0 * currentSide < 0 ? candidates.0 : candidates.1
        } else {
            chosen = candidates.0
        }
        uv[opposite] = chosen
        return true
    }

    private static func boundaryOutline(
        faces: [Face],
        edgeToFaces: [EdgeKey: [Int]],
        uv: [Vec2]
    ) -> [Vec2]? {
        let boundaryEdges = edgeToFaces.compactMap { item -> EdgeKey? in
            item.value.count == 1 ? item.key : nil
        }
        guard !boundaryEdges.isEmpty else { return nil }

        var neighbors: [Int: [Int]] = [:]
        for edge in boundaryEdges {
            neighbors[edge.a, default: []].append(edge.b)
            neighbors[edge.b, default: []].append(edge.a)
        }

        var unused = Set(boundaryEdges)
        var loops: [[Int]] = []
        while let startEdge = unused.first {
            var loop = [startEdge.a, startEdge.b]
            unused.remove(startEdge)
            var previous = startEdge.a
            var current = startEdge.b

            while current != loop.first {
                let next = neighbors[current, default: []].first { candidate in
                    candidate != previous && unused.contains(EdgeKey(current, candidate))
                }
                guard let next else { break }
                unused.remove(EdgeKey(current, next))
                previous = current
                current = next
                if current != loop.first {
                    loop.append(current)
                }
            }
            loops.append(loop)
        }

        let mappedLoops = loops.compactMap { loop -> [Vec2]? in
            let mapped = loop.compactMap { index -> Vec2? in
                guard uv.indices.contains(index), uv[index].x.isFinite, uv[index].y.isFinite else { return nil }
                return uv[index]
            }
            return mapped.count >= 3 ? mapped : nil
        }
        return mappedLoops.max { perimeter($0) < perimeter($1) }
    }

    private static func estimateStretch(mesh: MeshGeometryData, uv: [Vec2]) -> Double {
        var maxRatio = 1.0
        let idx = mesh.triangleIndices
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if mesh.vertices.indices.contains(a), mesh.vertices.indices.contains(b), mesh.vertices.indices.contains(c),
               uv.indices.contains(a), uv.indices.contains(b), uv.indices.contains(c) {
                for pair in [(a, b), (b, c), (c, a)] {
                    let length3 = distance(mesh.vertices[pair.0], mesh.vertices[pair.1])
                    let length2 = distance(uv[pair.0], uv[pair.1])
                    if length3 > 1.0e-9, length2 > 1.0e-9 {
                        maxRatio = max(maxRatio, max(length2 / length3, length3 / length2))
                    }
                }
            }
            i += 3
        }
        return maxRatio
    }

    private static func faceEdges(_ vertices: [Int]) -> [(Int, Int)] {
        guard vertices.count == 3 else { return [] }
        return [(vertices[0], vertices[1]), (vertices[1], vertices[2]), (vertices[2], vertices[0])]
    }

    private static func circleIntersections(a: Vec2, radiusA: Double, b: Vec2, radiusB: Double) -> (Vec2, Vec2)? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distanceAB = (dx * dx + dy * dy).squareRoot()
        guard distanceAB > 1.0e-9, radiusA.isFinite, radiusB.isFinite else { return nil }
        let x = ((radiusA * radiusA) - (radiusB * radiusB) + (distanceAB * distanceAB)) / (2 * distanceAB)
        let h = max((radiusA * radiusA) - (x * x), 0).squareRoot()
        let ux = dx / distanceAB
        let uy = dy / distanceAB
        let base = Vec2(x: a.x + x * ux, y: a.y + x * uy)
        let perp = Vec2(x: -uy * h, y: ux * h)
        return (
            Vec2(x: base.x + perp.x, y: base.y + perp.y),
            Vec2(x: base.x - perp.x, y: base.y - perp.y)
        )
    }

    private static func signedArea(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func convexHull(_ points: [Vec2]) -> [Vec2] {
        let unique = Array(Set(points)).filter { $0.x.isFinite && $0.y.isFinite }.sorted {
            if abs($0.x - $1.x) > 1.0e-9 { return $0.x < $1.x }
            return $0.y < $1.y
        }
        guard unique.count > 2 else { return unique }
        var lower: [Vec2] = []
        for p in unique {
            while lower.count >= 2, signedArea(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Vec2] = []
        for p in unique.reversed() {
            while upper.count >= 2, signedArea(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func perimeter(_ points: [Vec2]) -> Double {
        guard points.count >= 2 else { return 0 }
        return points.indices.reduce(0) { total, index in
            total + distance(points[index], points[(index + 1) % points.count])
        }
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private static func distance(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
