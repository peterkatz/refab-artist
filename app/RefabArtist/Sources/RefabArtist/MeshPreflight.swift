import Foundation

struct MeshPreflightReport: Equatable {
    var uniqueVertexCount: Int
    var duplicateVertexObservationCount: Int
    var invalidTriangleReferenceCount: Int
    var degenerateTriangleCount: Int
    var boundaryEdgeCount: Int
    var nonManifoldEdgeCount: Int

    /// True when the geometry came straight out of Manifold (the heal /
    /// Make-Watertight path) and Manifold validated it as a closed 2-manifold
    /// solid by its OWN index topology. `MeshPreflight.analyze` re-derives
    /// topology by welding vertex POSITIONS on a 1e-6 grid, and on a healed
    /// organic shell that weld fuses distinct manifold vertices wherever the
    /// surface self-contacts (two sheets passing within a micron — e.g. webbing
    /// between fingers), counting those self-contacts as `nonManifoldEdgeCount`.
    /// Those edges are real (an exported STL would show them) but they are
    /// SELF-CONTACT on a CLOSED solid, not holes: the mesh holds water, Manifold
    /// accepts it, and it builds molds / slices. When this flag is set we keep the
    /// honest self-contact count for display but do not let it fail the watertight
    /// verdict (which means "closed, usable solid", not "strictly 2-manifold").
    /// Defaults false, so every `analyze`-built report keeps the strict verdict.
    var manifoldValidated: Bool = false

    /// "Watertight" = a closed solid that holds water (no boundary holes) and is
    /// free of invalid/degenerate faces. Strict 2-manifoldness
    /// (`nonManifoldEdgeCount == 0`) is required UNLESS Manifold already validated
    /// the solid (`manifoldValidated`), in which case residual non-manifold edges
    /// are benign self-contacts (see above) and don't fail the verdict.
    var isWatertight: Bool {
        invalidTriangleReferenceCount == 0
            && degenerateTriangleCount == 0
            && boundaryEdgeCount == 0
            && (nonManifoldEdgeCount == 0 || manifoldValidated)
    }

    var statusLabel: String {
        guard isWatertight else { return "Needs repair" }
        return (manifoldValidated && nonManifoldEdgeCount > 0) ? "Watertight (closed solid)" : "Watertight"
    }
}

enum MeshPreflight {
    private static let tolerance = 1.0e-6
    private static let areaTolerance = 1.0e-10

    static func analyze(geometry: MeshGeometryData) -> MeshPreflightReport {
        let keys = geometry.vertices.map { VertexKey(point: $0, tolerance: tolerance) }
        let uniqueVertexCount = Set(keys).count
        var edgeUseCounts: [EdgeKey: Int] = [:]
        var invalidTriangleReferenceCount = 0
        var degenerateTriangleCount = 0

        for indices in geometry.triangleIndices.chunked(into: 3) {
            guard indices.count == 3,
                  let a = key(at: indices[0], in: keys),
                  let b = key(at: indices[1], in: keys),
                  let c = key(at: indices[2], in: keys),
                  let pointA = point(at: indices[0], in: geometry.vertices),
                  let pointB = point(at: indices[1], in: geometry.vertices),
                  let pointC = point(at: indices[2], in: geometry.vertices) else {
                invalidTriangleReferenceCount += 1
                continue
            }

            guard !isDegenerate(a: pointA, b: pointB, c: pointC) else {
                degenerateTriangleCount += 1
                continue
            }

            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                edgeUseCounts[edge, default: 0] += 1
            }
        }

        return MeshPreflightReport(
            uniqueVertexCount: uniqueVertexCount,
            duplicateVertexObservationCount: max(0, geometry.vertices.count - uniqueVertexCount),
            invalidTriangleReferenceCount: invalidTriangleReferenceCount,
            degenerateTriangleCount: degenerateTriangleCount,
            boundaryEdgeCount: edgeUseCounts.values.filter { $0 == 1 }.count,
            nonManifoldEdgeCount: edgeUseCounts.values.filter { $0 > 2 }.count
        )
    }

    private static func key(at index: Int32, in keys: [VertexKey]) -> VertexKey? {
        let index = Int(index)
        guard keys.indices.contains(index) else { return nil }
        return keys[index]
    }

    private static func point(at index: Int32, in points: [Vec3]) -> Vec3? {
        let index = Int(index)
        guard points.indices.contains(index) else { return nil }
        return points[index]
    }

    private static func isDegenerate(a: Vec3, b: Vec3, c: Vec3) -> Bool {
        let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
        let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
        let cross = Vec3(
            x: ab.y * ac.z - ab.z * ac.y,
            y: ab.z * ac.x - ab.x * ac.z,
            z: ab.x * ac.y - ab.y * ac.x
        )
        let areaTwiceSquared = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
        return areaTwiceSquared <= areaTolerance
    }
}

private struct VertexKey: Hashable, Comparable {
    var x: Int64
    var y: Int64
    var z: Int64

    init(point: Vec3, tolerance: Double) {
        x = Int64((point.x / tolerance).rounded())
        y = Int64((point.y / tolerance).rounded())
        z = Int64((point.z / tolerance).rounded())
    }

    static func < (lhs: VertexKey, rhs: VertexKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private struct EdgeKey: Hashable {
    var a: VertexKey
    var b: VertexKey

    init(_ lhs: VertexKey, _ rhs: VertexKey) {
        if lhs < rhs {
            a = lhs
            b = rhs
        } else {
            a = rhs
            b = lhs
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
