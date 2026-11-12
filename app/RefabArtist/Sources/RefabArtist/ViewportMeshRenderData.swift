import Foundation

struct ViewportFeatureEdge: Equatable {
    var startIndex: Int32
    var endIndex: Int32
}

struct ViewportFlatShadedMesh: Equatable {
    var vertices: [Vec3]
    var normals: [Vec3]
    var triangleIndices: [Int32]
}

enum ViewportMeshRenderData {
    /// Above this triangle count the per-feature-edge wireframe overlay is
    /// skipped. Each feature edge becomes its own RealityKit box entity, so on
    /// dense meshes the overlay both costs hundreds of ms to compute and can
    /// explode into tens of thousands of entities — for little visual benefit
    /// on a high-poly model. The mesh itself still renders.
    static let featureEdgeTriangleBudget = 50_000

    static func shouldRenderFeatureEdges(
        triangleCount: Int,
        ghosted: Bool = false
    ) -> Bool {
        // The translucent master is context behind the mold. Its edge overlay
        // looked like black cracks through the generated cavity.
        !ghosted && triangleCount <= featureEdgeTriangleBudget
    }

    static func flatShadedMesh(from data: MeshGeometryData) -> ViewportFlatShadedMesh {
        var vertices: [Vec3] = []
        var normals: [Vec3] = []
        var indices: [Int32] = []

        for triangleStart in stride(from: 0, to: data.triangleIndices.count - 2, by: 3) {
            guard let a = point(at: data.triangleIndices[triangleStart], in: data.vertices),
                  let b = point(at: data.triangleIndices[triangleStart + 1], in: data.vertices),
                  let c = point(at: data.triangleIndices[triangleStart + 2], in: data.vertices) else {
                continue
            }

            let normal = normalized(cross(subtract(b, a), subtract(c, a)))
            for point in [a, b, c] {
                vertices.append(point)
                normals.append(normal)
                indices.append(Int32(indices.count))
            }
        }

        return ViewportFlatShadedMesh(vertices: vertices, normals: normals, triangleIndices: indices)
    }

    /// Smooth-shaded mesh: welds coincident vertices by position, but splits the
    /// render vertex when adjacent face normals form a real crease. Averaging
    /// every face at a point makes damaged scans look melted/waxy around open
    /// rims and hard folds; angle-aware groups keep those features readable
    /// without going all the way back to triangle-faceted flat shading.
    static func smoothShadedMesh(from data: MeshGeometryData, creaseAngleDegrees: Double = 58) -> ViewportFlatShadedMesh {
        let creaseDotThreshold = cos(creaseAngleDegrees * .pi / 180)
        var groupsByPosition: [QuantizedPoint: [SmoothNormalGroup]] = [:]
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var indices: [Int32] = []
        indices.reserveCapacity(data.triangleIndices.count)

        func renderVertexIndex(for position: Vec3, faceNormal: Vec3, weightedNormal: Vec3) -> Int {
            let key = QuantizedPoint(position)
            var groups = groupsByPosition[key] ?? []
            if let groupOffset = groups.indices.first(where: { dot(groups[$0].representativeNormal, faceNormal) >= creaseDotThreshold }) {
                let renderIndex = groups[groupOffset].renderIndex
                normals[renderIndex] = add(normals[renderIndex], weightedNormal)
                groups[groupOffset].representativeNormal = normalized(add(groups[groupOffset].representativeNormal, faceNormal))
                groupsByPosition[key] = groups
                return renderIndex
            }

            let renderIndex = positions.count
            positions.append(position)
            normals.append(weightedNormal)
            groups.append(SmoothNormalGroup(renderIndex: renderIndex, representativeNormal: faceNormal))
            groupsByPosition[key] = groups
            return renderIndex
        }

        for triangleStart in stride(from: 0, to: data.triangleIndices.count - 2, by: 3) {
            guard let a = point(at: data.triangleIndices[triangleStart], in: data.vertices),
                  let b = point(at: data.triangleIndices[triangleStart + 1], in: data.vertices),
                  let c = point(at: data.triangleIndices[triangleStart + 2], in: data.vertices) else {
                continue
            }
            let weightedNormal = cross(subtract(b, a), subtract(c, a))
            let faceNormal = normalized(weightedNormal)
            guard faceNormal != Vec3(x: 0, y: 0, z: 0) else {
                continue
            }

            let ia = renderVertexIndex(for: a, faceNormal: faceNormal, weightedNormal: weightedNormal)
            let ib = renderVertexIndex(for: b, faceNormal: faceNormal, weightedNormal: weightedNormal)
            let ic = renderVertexIndex(for: c, faceNormal: faceNormal, weightedNormal: weightedNormal)
            indices.append(Int32(ia))
            indices.append(Int32(ib))
            indices.append(Int32(ic))
        }

        for index in normals.indices {
            let unit = normalized(normals[index])
            normals[index] = unit == Vec3(x: 0, y: 0, z: 0)
                ? Vec3(x: 0, y: 0, z: 1)
                : unit
        }

        return ViewportFlatShadedMesh(vertices: positions, normals: normals, triangleIndices: indices)
    }

    static func featureEdges(from data: MeshGeometryData, creaseAngleDegrees: Double = 18) -> [ViewportFeatureEdge] {
        let creaseDotThreshold = cos(creaseAngleDegrees * .pi / 180)
        var edgesByPosition: [PositionEdgeKey: [EdgeObservation]] = [:]

        for triangleStart in stride(from: 0, to: data.triangleIndices.count - 2, by: 3) {
            let triangle = [
                data.triangleIndices[triangleStart],
                data.triangleIndices[triangleStart + 1],
                data.triangleIndices[triangleStart + 2]
            ]
            guard let a = point(at: triangle[0], in: data.vertices),
                  let b = point(at: triangle[1], in: data.vertices),
                  let c = point(at: triangle[2], in: data.vertices) else {
                continue
            }

            let normal = normalized(cross(subtract(b, a), subtract(c, a)))
            guard normal != Vec3(x: 0, y: 0, z: 0) else {
                continue
            }

            for (start, end) in [(triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])] {
                guard let startPoint = point(at: start, in: data.vertices),
                      let endPoint = point(at: end, in: data.vertices) else {
                    continue
                }
                let key = PositionEdgeKey(start: startPoint, end: endPoint)
                edgesByPosition[key, default: []].append(EdgeObservation(startIndex: start, endIndex: end, normal: normal))
            }
        }

        return edgesByPosition.values.compactMap { observations in
            guard let first = observations.first else {
                return nil
            }
            if observations.count == 1 {
                return ViewportFeatureEdge(startIndex: first.startIndex, endIndex: first.endIndex)
            }
            let hasCrease = observations.dropFirst().contains { observation in
                dot(first.normal, observation.normal) < creaseDotThreshold
            }
            return hasCrease ? ViewportFeatureEdge(startIndex: first.startIndex, endIndex: first.endIndex) : nil
        }
        .sorted {
            if $0.startIndex == $1.startIndex {
                return $0.endIndex < $1.endIndex
            }
            return $0.startIndex < $1.startIndex
        }
    }

    private static func point(at index: Int32, in points: [Vec3]) -> Vec3? {
        guard index >= 0, Int(index) < points.count else {
            return nil
        }
        return points[Int(index)]
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
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

    private static func normalized(_ vector: Vec3) -> Vec3 {
        let length = sqrt(dot(vector, vector))
        guard length > 0 else {
            return Vec3(x: 0, y: 0, z: 0)
        }
        return Vec3(x: vector.x / length, y: vector.y / length, z: vector.z / length)
    }
}

private struct SmoothNormalGroup {
    var renderIndex: Int
    var representativeNormal: Vec3
}

private struct EdgeObservation {
    var startIndex: Int32
    var endIndex: Int32
    var normal: Vec3
}

private struct PositionEdgeKey: Hashable {
    private var a: QuantizedPoint
    private var b: QuantizedPoint

    init(start: Vec3, end: Vec3) {
        let startKey = QuantizedPoint(start)
        let endKey = QuantizedPoint(end)
        if startKey < endKey {
            a = startKey
            b = endKey
        } else {
            a = endKey
            b = startKey
        }
    }
}

private struct QuantizedPoint: Hashable, Comparable {
    private static let scale = 1_000_000.0

    var x: Int64
    var y: Int64
    var z: Int64

    init(_ point: Vec3) {
        x = Int64((point.x * Self.scale).rounded())
        y = Int64((point.y * Self.scale).rounded())
        z = Int64((point.z * Self.scale).rounded())
    }

    static func < (lhs: QuantizedPoint, rhs: QuantizedPoint) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}
