import Foundation

/// Drops disconnected debris fragments from mold parts before validation and
/// export. A MotherMold part is one printable solid; any smaller disconnected
/// island left by boolean stages is debris, including inverted-winding fragments.
enum MoldComponentFilter {
    struct FilterResult: Equatable {
        var geometry: MeshGeometryData
        var droppedCount: Int
        var droppedVolume: Double
    }

    static func dropDebris(_ geometry: MeshGeometryData) -> FilterResult {
        let filtered = dropVertexConnectedDebris(geometry)
        guard filtered.droppedCount > 0 else { return filtered }
        if let accepted = validationAcceptedGeometry(filtered.geometry) {
            return FilterResult(
                geometry: accepted,
                droppedCount: filtered.droppedCount,
                droppedVolume: filtered.droppedVolume
            )
        }
        if let accepted = validationAcceptedGeometry(geometry) {
            return FilterResult(geometry: accepted, droppedCount: 0, droppedVolume: 0)
        }
        return filtered
    }

    static func dropFaceDisconnectedDebris(_ geometry: MeshGeometryData) -> FilterResult {
        componentFilter(geometry: geometry, connectivity: .sharedEdges, keepPositiveLargeFragments: false)
    }

    /// Remove only face-disconnected components that satisfy the same signed-
    /// volume debris threshold as the primary component filter. Large positive
    /// solids remain so the planner can reject or choose a different partition;
    /// this must not be used to hide a materially disconnected mold part.
    static func dropFaceDisconnectedTinyDebris(_ geometry: MeshGeometryData) -> FilterResult {
        componentFilter(geometry: geometry, connectivity: .sharedEdges, keepPositiveLargeFragments: true)
    }

    /// Count physical material islands, not disconnected boundary surfaces.
    /// A hollow printable solid has one positive outer boundary and one or more
    /// negative cavity boundaries; the latter must not be reported as debris.
    static func positiveMaterialComponentCount(
        _ geometry: MeshGeometryData,
        volumeTolerance: Double = 1.0e-8
    ) -> Int {
        let triangleCount = geometry.triangleIndices.count / 3
        guard triangleCount > 0 else { return 0 }
        var parent = Array(0..<triangleCount)
        func find(_ value: Int) -> Int {
            var root = value
            while parent[root] != root { root = parent[root] }
            var cursor = value
            while parent[cursor] != root {
                let next = parent[cursor]
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        func unite(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            if left != right { parent[max(left, right)] = min(left, right) }
        }
        var ownerByVertex: [Int32: Int] = [:]
        for triangle in 0..<triangleCount {
            for vertex in geometry.triangleIndices[(triangle * 3)..<(triangle * 3 + 3)] {
                if let prior = ownerByVertex[vertex] {
                    unite(triangle, prior)
                } else {
                    ownerByVertex[vertex] = triangle
                }
            }
        }
        var signedVolumes: [Int: Double] = [:]
        for triangle in 0..<triangleCount {
            let root = find(triangle)
            let offset = triangle * 3
            let a = geometry.vertices[Int(geometry.triangleIndices[offset])]
            let b = geometry.vertices[Int(geometry.triangleIndices[offset + 1])]
            let c = geometry.vertices[Int(geometry.triangleIndices[offset + 2])]
            signedVolumes[root, default: 0] += signedTetraVolume(a, b, c)
        }
        return signedVolumes.values.filter { $0 > volumeTolerance }.count
    }

    private static func validationAcceptedGeometry(_ geometry: MeshGeometryData) -> MeshGeometryData? {
        let part = MotherMoldPart(name: "component-filter-check", geometry: geometry)
        let validation = MotherMoldValidation.validate(parts: [part])
        guard validation.allPartsWatertight, let accepted = validation.parts.first else { return nil }
        return accepted.geometry
    }

    private static func dropVertexConnectedDebris(_ geometry: MeshGeometryData) -> FilterResult {
        componentFilter(geometry: geometry, connectivity: .sharedVertices, keepPositiveLargeFragments: true)
    }

    private enum Connectivity {
        case sharedVertices
        case sharedEdges
    }

    private static func componentFilter(
        geometry: MeshGeometryData,
        connectivity: Connectivity,
        keepPositiveLargeFragments: Bool
    ) -> FilterResult {
        let verts = geometry.vertices
        let idx = geometry.triangleIndices
        let triCount = idx.count / 3
        guard triCount > 0 else {
            return FilterResult(geometry: geometry, droppedCount: 0, droppedVolume: 0)
        }

        struct Key: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        var keyToCanon: [Key: Int] = [:]
        var canonOf = [Int](repeating: 0, count: verts.count)
        for (i, v) in verts.enumerated() {
            let k = Key(
                x: Int64((v.x / 1.0e-6).rounded()),
                y: Int64((v.y / 1.0e-6).rounded()),
                z: Int64((v.z / 1.0e-6).rounded())
            )
            if let c = keyToCanon[k] {
                canonOf[i] = c
            } else {
                keyToCanon[k] = i
                canonOf[i] = i
            }
        }

        let parentCount = connectivity == .sharedEdges ? verts.count + triCount : verts.count
        var parent = Array(0..<parentCount)
        func find(_ value: Int) -> Int {
            var root = value
            while parent[root] != root { root = parent[root] }
            var current = value
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func unite(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        struct EdgeKey: Hashable {
            let a: Int
            let b: Int
            init(_ lhs: Int, _ rhs: Int) {
                a = min(lhs, rhs)
                b = max(lhs, rhs)
            }
        }
        var edgeOwner: [EdgeKey: Int] = [:]
        var triRoot = [Int](repeating: -1, count: triCount)

        var t = 0
        var tri = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
            guard canonOf.indices.contains(ia), canonOf.indices.contains(ib), canonOf.indices.contains(ic) else {
                t += 3
                tri += 1
                continue
            }
            let a = canonOf[ia], b = canonOf[ib], c = canonOf[ic]
            switch connectivity {
            case .sharedVertices:
                unite(a, b); unite(b, c); unite(c, a)
            case .sharedEdges:
                let base = tri + verts.count
                triRoot[tri] = base
                for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                    if let other = edgeOwner[edge] {
                        unite(base, other)
                    } else {
                        edgeOwner[edge] = base
                    }
                }
            }
            t += 3
            tri += 1
        }

        var componentVolume: [Int: Double] = [:]
        t = 0
        tri = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
            guard canonOf.indices.contains(ia),
                  verts.indices.contains(ia),
                  verts.indices.contains(ib),
                  verts.indices.contains(ic) else {
                t += 3
                tri += 1
                continue
            }
            let root: Int
            switch connectivity {
            case .sharedVertices:
                root = find(canonOf[ia])
            case .sharedEdges:
                guard triRoot[tri] >= 0 else {
                    t += 3
                    tri += 1
                    continue
                }
                root = find(triRoot[tri])
            }
            triRoot[tri] = root
            componentVolume[root, default: 0] += signedTetraVolume(verts[ia], verts[ib], verts[ic])
            t += 3
            tri += 1
        }

        guard componentVolume.count > 1 else {
            return FilterResult(geometry: geometry, droppedCount: 0, droppedVolume: 0)
        }

        let sortedRoots = componentVolume.keys.sorted()
        guard let largestRoot = sortedRoots.max(by: { lhs, rhs in
            let lv = abs(componentVolume[lhs] ?? 0)
            let rv = abs(componentVolume[rhs] ?? 0)
            return lv == rv ? lhs > rhs : lv < rv
        }) else {
            return FilterResult(geometry: geometry, droppedCount: 0, droppedVolume: 0)
        }
        let largestVolume = abs(componentVolume[largestRoot] ?? 0)
        let keepThreshold = max(50.0, largestVolume * 0.005)
        let keepRoots = Set(sortedRoots.filter { root in
            root == largestRoot || (keepPositiveLargeFragments && (componentVolume[root] ?? 0) >= keepThreshold)
        })

        var droppedCount = 0
        var droppedVolume = 0.0
        for root in sortedRoots where !keepRoots.contains(root) {
            droppedCount += 1
            droppedVolume += abs(componentVolume[root] ?? 0)
        }
        guard droppedCount > 0 else {
            return FilterResult(geometry: geometry, droppedCount: 0, droppedVolume: 0)
        }

        var keptIndices: [Int32] = []
        keptIndices.reserveCapacity(idx.count)
        t = 0
        tri = 0
        while t + 2 < idx.count {
            if triRoot[tri] >= 0, keepRoots.contains(triRoot[tri]) {
                keptIndices.append(idx[t])
                keptIndices.append(idx[t + 1])
                keptIndices.append(idx[t + 2])
            }
            t += 3
            tri += 1
        }

        return FilterResult(
            geometry: MeshGeometryData(vertices: verts, triangleIndices: keptIndices),
            droppedCount: droppedCount,
            droppedVolume: droppedVolume
        )
    }

    static func signedVolume(_ geometry: MeshGeometryData) -> Double {
        let verts = geometry.vertices
        let idx = geometry.triangleIndices
        var volume = 0.0
        var t = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
            if verts.indices.contains(ia), verts.indices.contains(ib), verts.indices.contains(ic) {
                volume += signedTetraVolume(verts[ia], verts[ib], verts[ic])
            }
            t += 3
        }
        return volume
    }

    private static func signedTetraVolume(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let det = a.x * (b.y * c.z - b.z * c.y)
            - a.y * (b.x * c.z - b.z * c.x)
            + a.z * (b.x * c.y - b.y * c.x)
        return det / 6.0
    }
}
