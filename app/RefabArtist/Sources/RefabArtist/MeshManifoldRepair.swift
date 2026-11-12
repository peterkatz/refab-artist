import Foundation

/// Load-time make-manifold pass that removes a degenerate "winged" sliver
/// triangle: a face that simultaneously
///   (a) shares a geometric edge used by more than two faces (a non-manifold
///       edge), and
///   (b) carries at least one vertex referenced by no other face (a degree-1
///       "orphan" tip).
///
/// Such a face is a thin fin welded onto an otherwise watertight solid along a
/// single shared edge with a dangling free apex; it contributes nothing to the
/// closed surface yet inflates the model's bounding box and bleeds a spurious
/// boundary into every downstream slice. Stripping it (and iterating to a
/// fixed point, then dropping any vertex left unreferenced) restores the
/// underlying manifold body and the bounding box of the real solid.
///
/// The pass is a strict no-op on any mesh with no >2-incidence edge (every
/// well-formed manifold solid), so it cannot perturb already-clean fixtures.
/// Vertices are welded with the same 1e-6 quantization the rest of the
/// pipeline (`MeshPreflight`) uses for its edge/manifold analysis, so the two
/// agree on what counts as a shared edge.
enum MeshManifoldRepair {
    private static let weldTolerance = 1.0e-6

    /// A quantized vertex location used to weld coincident vertices when
    /// building the geometric edge/incidence maps.
    private struct VertexKey: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64

        init(_ point: Vec3, tolerance: Double) {
            x = Int64((point.x / tolerance).rounded())
            y = Int64((point.y / tolerance).rounded())
            z = Int64((point.z / tolerance).rounded())
        }
    }

    /// An unordered pair of quantized vertex keys identifying a geometric edge.
    private struct EdgeKey: Hashable {
        let lo: VertexKey
        let hi: VertexKey

        init(_ a: VertexKey, _ b: VertexKey) {
            if (a.x, a.y, a.z) <= (b.x, b.y, b.z) {
                lo = a
                hi = b
            } else {
                lo = b
                hi = a
            }
        }
    }

    /// Pipeline pre-clean used by Inflatables and the Folded pre-cleaner on
    /// mm-scaled meshes: strip degenerate (collapsed-vertex or below the
    /// preflight's ABSOLUTE area threshold) triangles, then run the winged-fin
    /// pass. NOT for the user-facing Repair button: the absolute threshold is
    /// unit-dependent, so on inch or unit-box files it deletes real surface
    /// (see `safeRepair`).
    static func userRepair(_ geometry: MeshGeometryData) -> MeshGeometryData {
        repaired(strippingDegenerateTriangles(geometry))
    }

    /// What `safeRepair` removed, by kind.
    struct SafeRepairResult {
        var geometry: MeshGeometryData
        /// Triangles whose corners weld to fewer than three distinct points
        /// (or that reference a missing vertex).
        var collapsedTriangles: Int
        /// Zero-area triangles that share no edge with any real (positive
        /// area) triangle — loose specks, not part of the surface.
        var looseZeroAreaTriangles: Int
        /// Winged fins removed by `repaired`.
        var finTriangles: Int

        var removedTriangles: Int { collapsedTriangles + looseZeroAreaTriangles + finTriangles }
    }

    /// The Repair button: remove only triangles that are broken in a way that
    /// cannot be real surface, and never anything else.
    ///   1. Collapsed triangles (corners weld together) — no area, no surface.
    ///   2. Zero-area triangles that share no edge with a positive-area
    ///      triangle — loose specks. A zero-area triangle that IS stitched into
    ///      the surface (a T-junction sliver) is kept: deleting it opens a crack.
    ///   3. Winged fins (`repaired`).
    /// "Zero area" is judged relative to the model's size, so the result does
    /// not depend on the file's units. Thin-but-real slivers are never touched.
    /// Surviving triangles keep their exact vertex positions.
    static func safeRepair(_ geometry: MeshGeometryData) -> SafeRepairResult {
        let keys = geometry.vertices.map { VertexKey($0, tolerance: weldTolerance) }
        let triangles = triangleList(from: geometry.triangleIndices)

        var intact: [Triangle] = []
        intact.reserveCapacity(triangles.count)
        var collapsed = 0
        for triangle in triangles {
            guard let triKeys = welded(triangle, keys: keys),
                  triKeys[0] != triKeys[1], triKeys[1] != triKeys[2], triKeys[2] != triKeys[0] else {
                collapsed += 1
                continue
            }
            intact.append(triangle)
        }

        let zeroArea = zeroAreaFlags(intact, vertices: geometry.vertices)
        var loose = 0
        var kept = intact
        if zeroArea.contains(true) {
            var realEdges = Set<EdgeKey>()
            for (index, triangle) in intact.enumerated() where !zeroArea[index] {
                if let triKeys = welded(triangle, keys: keys) {
                    realEdges.formUnion(edges(of: triKeys))
                }
            }
            kept = []
            kept.reserveCapacity(intact.count)
            for (index, triangle) in intact.enumerated() {
                if zeroArea[index],
                   let triKeys = welded(triangle, keys: keys),
                   realEdges.isDisjoint(with: edges(of: triKeys)) {
                    loose += 1
                    continue
                }
                kept.append(triangle)
            }
        }

        let stripped = (collapsed + loose) == 0
            ? geometry
            : compacted(triangles: kept, vertices: geometry.vertices)
        let finFree = repaired(stripped)
        let fins = (stripped.triangleIndices.count - finFree.triangleIndices.count) / 3
        return SafeRepairResult(
            geometry: finFree,
            collapsedTriangles: collapsed,
            looseZeroAreaTriangles: loose,
            finTriangles: fins
        )
    }

    /// Per-triangle "numerically zero area" flags. The threshold is relative to
    /// the squared bounding-box diagonal (1e-12), so it only catches truly
    /// collinear corners in any unit system, never thin-but-real slivers.
    private static func zeroAreaFlags(_ triangles: [Triangle], vertices: [Vec3]) -> [Bool] {
        guard var lo = vertices.first else { return triangles.map { _ in false } }
        var hi = lo
        for v in vertices {
            lo = Vec3(x: min(lo.x, v.x), y: min(lo.y, v.y), z: min(lo.z, v.z))
            hi = Vec3(x: max(hi.x, v.x), y: max(hi.y, v.y), z: max(hi.z, v.z))
        }
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        let diagonalSquared = dx * dx + dy * dy + dz * dz
        let limit = 1.0e-12 * diagonalSquared
        let limitSquared = limit * limit
        return triangles.map { triangle in
            let a = vertices[triangle.a]
            let b = vertices[triangle.b]
            let c = vertices[triangle.c]
            let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            let cx = ab.y * ac.z - ab.z * ac.y
            let cy = ab.z * ac.x - ab.x * ac.z
            let cz = ab.x * ac.y - ab.y * ac.x
            // |ab x ac| is twice the area; compare squared to avoid a sqrt.
            return (cx * cx + cy * cy + cz * cz) <= limitSquared
        }
    }

    /// Remove triangles whose welded vertices collapse (two corners within the
    /// weld tolerance) or whose area is below the preflight degeneracy
    /// threshold — the zero-area slivers decimation/STL export leaves behind.
    static func strippingDegenerateTriangles(_ geometry: MeshGeometryData) -> MeshGeometryData {
        let keys = geometry.vertices.map { VertexKey($0, tolerance: weldTolerance) }
        let triangles = triangleList(from: geometry.triangleIndices)
        let kept = triangles.filter { triangle in
            guard let triKeys = welded(triangle, keys: keys) else { return false }
            if triKeys[0] == triKeys[1] || triKeys[1] == triKeys[2] || triKeys[2] == triKeys[0] {
                return false
            }
            let a = geometry.vertices[triangle.a]
            let b = geometry.vertices[triangle.b]
            let c = geometry.vertices[triangle.c]
            let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            let cx = ab.y * ac.z - ab.z * ac.y
            let cy = ab.z * ac.x - ab.x * ac.z
            let cz = ab.x * ac.y - ab.y * ac.x
            // Same degeneracy standard as MeshPreflight (squared double-area
            // against its areaTolerance) so Repair removes exactly what the
            // preflight counts.
            return (cx * cx + cy * cy + cz * cz) > 1.0e-10
        }
        guard kept.count != triangles.count else { return geometry }
        return compacted(triangles: kept, vertices: geometry.vertices)
    }

    /// Repair `geometry` by removing winged faces on non-manifold edges that
    /// carry an orphan (degree-1) vertex, iterating to a fixed point and
    /// dropping any vertex left unreferenced. Returns the input unchanged when
    /// no such face exists.
    static func repaired(_ geometry: MeshGeometryData) -> MeshGeometryData {
        var triangles = triangleList(from: geometry.triangleIndices)
        guard !triangles.isEmpty else { return geometry }

        let keys = geometry.vertices.map { VertexKey($0, tolerance: weldTolerance) }
        guard removableFaceExists(triangles: triangles, keys: keys) else {
            // No >2-incidence edge with a dangling tip: leave the mesh exactly
            // as parsed (manifold solids take this path).
            return geometry
        }

        // Remove offending faces and iterate: dropping a face can leave a new
        // vertex orphaned, which can in turn expose another winged face.
        while true {
            let kill = facesToRemove(triangles: triangles, keys: keys)
            if kill.isEmpty { break }
            triangles = triangles.enumerated()
                .filter { !kill.contains($0.offset) }
                .map { $0.element }
        }

        return compacted(triangles: triangles, vertices: geometry.vertices)
    }

    private struct Triangle {
        var a: Int
        var b: Int
        var c: Int

        var indices: [Int] { [a, b, c] }
    }

    private static func triangleList(from indices: [Int32]) -> [Triangle] {
        var result: [Triangle] = []
        result.reserveCapacity(indices.count / 3)
        var i = 0
        while i + 2 < indices.count {
            result.append(Triangle(a: Int(indices[i]), b: Int(indices[i + 1]), c: Int(indices[i + 2])))
            i += 3
        }
        return result
    }

    /// Build the geometric-edge -> incident-face map and the welded-vertex ->
    /// incident-face map, then return the set of face indices that sit on a
    /// non-manifold edge AND carry at least one degree-1 (orphan) vertex.
    private static func facesToRemove(triangles: [Triangle], keys: [VertexKey]) -> Set<Int> {
        var edgeFaces: [EdgeKey: [Int]] = [:]
        var vertexFaces: [VertexKey: Set<Int>] = [:]

        for (faceIndex, triangle) in triangles.enumerated() {
            guard let triKeys = welded(triangle, keys: keys) else { continue }
            for key in Set(triKeys) {
                vertexFaces[key, default: []].insert(faceIndex)
            }
            for edge in edges(of: triKeys) {
                edgeFaces[edge, default: []].append(faceIndex)
            }
        }

        let nonManifoldFaces = Set(
            edgeFaces.values.lazy.filter { $0.count > 2 }.flatMap { $0 }
        )
        guard !nonManifoldFaces.isEmpty else { return [] }

        let orphanFaces = Set(
            vertexFaces.values.lazy.filter { $0.count == 1 }.compactMap { $0.first }
        )
        return nonManifoldFaces.intersection(orphanFaces)
    }

    private static func removableFaceExists(triangles: [Triangle], keys: [VertexKey]) -> Bool {
        !facesToRemove(triangles: triangles, keys: keys).isEmpty
    }

    private static func welded(_ triangle: Triangle, keys: [VertexKey]) -> [VertexKey]? {
        guard keys.indices.contains(triangle.a),
              keys.indices.contains(triangle.b),
              keys.indices.contains(triangle.c) else {
            return nil
        }
        return [keys[triangle.a], keys[triangle.b], keys[triangle.c]]
    }

    private static func edges(of triKeys: [VertexKey]) -> [EdgeKey] {
        [
            EdgeKey(triKeys[0], triKeys[1]),
            EdgeKey(triKeys[1], triKeys[2]),
            EdgeKey(triKeys[2], triKeys[0])
        ]
    }

    /// Rebuild a `MeshGeometryData` from the surviving triangles, dropping any
    /// vertex no surviving triangle references and reindexing the rest.
    private static func compacted(triangles: [Triangle], vertices: [Vec3]) -> MeshGeometryData {
        var remap: [Int: Int] = [:]
        var newVertices: [Vec3] = []
        var newIndices: [Int32] = []
        newIndices.reserveCapacity(triangles.count * 3)

        func mapped(_ old: Int) -> Int32? {
            guard vertices.indices.contains(old) else { return nil }
            if let existing = remap[old] {
                return Int32(existing)
            }
            let fresh = newVertices.count
            remap[old] = fresh
            newVertices.append(vertices[old])
            return Int32(fresh)
        }

        for triangle in triangles {
            guard let a = mapped(triangle.a),
                  let b = mapped(triangle.b),
                  let c = mapped(triangle.c) else {
                continue
            }
            newIndices.append(a)
            newIndices.append(b)
            newIndices.append(c)
        }

        return MeshGeometryData(vertices: newVertices, triangleIndices: newIndices)
    }
}
