import Foundation

/// Per-part mesh sealing for the MotherMold pipeline.
///
/// Manifold boolean output (split, spout bore, floor union) is watertight by
/// construction, but the registration keys and flanges are built as ADDITIVE
/// CAP geometry (manual triangle stitching, reused from Partition — deliberately
/// no CSG). On a concave organic seam (e.g. between fingers) that stitching can
/// leave a few coincident-but-unpaired half-edges — small (typically 4–12 edge)
/// boundary loops that fail the watertight gate even though the part is a closed
/// solid everywhere else.
///
/// `seal` makes a part robustly watertight without changing its real surface:
///   1. Weld coincident vertices on the same 1e-6 grid `MeshPreflight` uses, so
///      coincident-but-distinct stitch vertices share one index.
///   2. Drop zero-area (degenerate) triangles (same threshold as MeshPreflight).
///   3. Fan-fill only microscopic, planar boundary loops from their centroid, with
///      winding that pairs each open half-edge — exact for the near-planar
///      crack loops the caps produce.
/// Large, non-planar, long, or area-bearing loops are left open: those signal a
/// genuine opening the watertight gate should still catch, not a stitch crack to
/// paper over.
enum MoldMeshSealer {
    static func seal(
        _ geometry: MeshGeometryData,
        maxHoleEdges: Int = 64,
        maxPatchAreaMM2: Double = 0.1,
        maxPatchPerimeterMM: Double = 4.0,
        maxPlanarityDeviationMM: Double = 0.02
    ) -> MeshGeometryData {
        // 1. Weld onto a 1e-6 grid → canonical vertex indices.
        struct Key: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        func key(_ v: Vec3) -> Key {
            Key(x: Int64((v.x / 1.0e-6).rounded()),
                y: Int64((v.y / 1.0e-6).rounded()),
                z: Int64((v.z / 1.0e-6).rounded()))
        }
        var keyToIndex: [Key: Int32] = [:]
        var verts: [Vec3] = []
        verts.reserveCapacity(geometry.vertices.count)
        func canon(_ orig: Int) -> Int32? {
            guard geometry.vertices.indices.contains(orig) else { return nil }
            let k = key(geometry.vertices[orig])
            if let i = keyToIndex[k] { return i }
            let i = Int32(verts.count)
            keyToIndex[k] = i
            verts.append(geometry.vertices[orig])
            return i
        }

        var tris: [Int32] = []
        tris.reserveCapacity(geometry.triangleIndices.count)
        let idx = geometry.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            if let a = canon(Int(idx[t])), let b = canon(Int(idx[t + 1])), let c = canon(Int(idx[t + 2])),
               a != b, b != c, a != c {
                let va = verts[Int(a)], vb = verts[Int(b)], vc = verts[Int(c)]
                let ux = vb.x - va.x, uy = vb.y - va.y, uz = vb.z - va.z
                let wx = vc.x - va.x, wy = vc.y - va.y, wz = vc.z - va.z
                let nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx
                if nx * nx + ny * ny + nz * nz > 1.0e-10 {   // matches MeshPreflight degenerate threshold
                    tris.append(a); tris.append(b); tris.append(c)
                }
            }
            t += 3
        }

        // 2. Count directed half-edges to find unpaired (boundary) ones.
        func code(_ a: Int32, _ b: Int32) -> UInt64 {
            (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
        }
        var halfEdge: [UInt64: Int] = [:]
        var s = 0
        while s + 2 < tris.count {
            let a = tris[s], b = tris[s + 1], c = tris[s + 2]
            halfEdge[code(a, b), default: 0] += 1
            halfEdge[code(b, c), default: 0] += 1
            halfEdge[code(c, a), default: 0] += 1
            s += 3
        }
        // A boundary half-edge a→b appears once and has no partner b→a. Build
        // this graph from a sorted edge list: Dictionary iteration is randomized
        // between processes, and the old `nextFrom[a] = b` silently chose an
        // arbitrary branch when a damaged vertex had multiple outgoing edges.
        // That made identical mold builds alternate between different flange
        // geometry (or occasionally fail validation) with the same seed.
        let boundaryEdges: [(Int32, Int32)] = halfEdge.compactMap { entry in
            guard entry.value == 1 else { return nil }
            let a = Int32(bitPattern: UInt32(entry.key >> 32))
            let b = Int32(bitPattern: UInt32(entry.key & 0xffff_ffff))
            guard (halfEdge[code(b, a)] ?? 0) == 0 else { return nil }
            return (a, b)
        }.sorted {
            $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1
        }
        guard !boundaryEdges.isEmpty else {
            return MeshGeometryData(vertices: verts, triangleIndices: tris)
        }

        var outgoing: [Int32: [Int32]] = [:]
        var incomingCount: [Int32: Int] = [:]
        for (a, b) in boundaryEdges {
            outgoing[a, default: []].append(b)
            incomingCount[b, default: 0] += 1
        }
        for key in outgoing.keys.sorted() {
            outgoing[key]?.sort()
        }

        // 3. Chain boundary half-edges into loops; fan-fill the small ones.
        // Only simple 1-in/1-out cycles are stitch cracks. Branching boundary
        // graphs are genuine non-manifold damage and must reach the hard gate;
        // guessing a branch can cap the wrong region and change mold volume.
        var visitedEdges = Set<UInt64>()
        for (start, firstNext) in boundaryEdges {
            let firstCode = code(start, firstNext)
            guard !visitedEdges.contains(firstCode) else { continue }
            var loop: [Int32] = []
            var cur = start
            var closed = false
            while loop.count <= maxHoleEdges {
                guard outgoing[cur]?.count == 1,
                      incomingCount[cur] == 1,
                      let nxt = outgoing[cur]?.first else {
                    break
                }
                let edge = code(cur, nxt)
                guard !visitedEdges.contains(edge) else {
                    closed = nxt == start
                    break
                }
                visitedEdges.insert(edge)
                loop.append(cur)
                if nxt == start { closed = true; break }
                cur = nxt
            }
            guard closed, loop.count >= 3, loop.count <= maxHoleEdges else { continue }

            var cx = 0.0, cy = 0.0, cz = 0.0
            for v in loop { let p = verts[Int(v)]; cx += p.x; cy += p.y; cz += p.z }
            let n = Double(loop.count)
            let center = Vec3(x: cx / n, y: cy / n, z: cz / n)

            // Newell normal gives twice the projected area for a planar loop.
            var nx = 0.0, ny = 0.0, nz = 0.0
            var perimeter = 0.0
            for i in loop.indices {
                let p = verts[Int(loop[i])]
                let q = verts[Int(loop[(i + 1) % loop.count])]
                nx += (p.y - q.y) * (p.z + q.z)
                ny += (p.z - q.z) * (p.x + q.x)
                nz += (p.x - q.x) * (p.y + q.y)
                perimeter += hypot(hypot(q.x - p.x, q.y - p.y), q.z - p.z)
            }
            let normalLength = (nx * nx + ny * ny + nz * nz).squareRoot()
            let area = normalLength * 0.5
            guard normalLength > 1.0e-12,
                  area <= maxPatchAreaMM2,
                  perimeter <= maxPatchPerimeterMM else {
                continue
            }
            let normal = Vec3(x: nx / normalLength, y: ny / normalLength, z: nz / normalLength)
            let maxDeviation = loop.reduce(0.0) { current, index in
                let point = verts[Int(index)]
                let distance = abs(
                    (point.x - center.x) * normal.x
                        + (point.y - center.y) * normal.y
                        + (point.z - center.z) * normal.z
                )
                return max(current, distance)
            }
            guard maxDeviation <= maxPlanarityDeviationMM else { continue }

            let centroid = Int32(verts.count)
            verts.append(center)
            // For each boundary half-edge a→b add triangle (centroid, b, a): it
            // supplies the missing b→a and shares its centroid spokes with the
            // neighbouring fan triangles, so the patch is itself watertight.
            for i in 0..<loop.count {
                let a = loop[i]
                let b = loop[(i + 1) % loop.count]
                tris.append(centroid); tris.append(b); tris.append(a)
            }
        }
        return MeshGeometryData(vertices: verts, triangleIndices: tris)
    }
}
