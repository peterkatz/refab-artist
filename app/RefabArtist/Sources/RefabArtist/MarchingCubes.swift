import Foundation

/// Watertight marching-cubes isosurface extractor over a regular scalar field
/// sampled at GRID CORNERS.
///
/// Why this exists: the previous heal evaluated its SDF once per grid sample
/// across the manifoldc C↔Swift boundary inside `manifold_level_set`. That
/// per-sample trampoline serialized the hot path and dominated runtime (the
/// parallel C entry point was SLOWER than a serial pure-Swift field loop). We
/// instead compute the whole field on the grid in one vectorized PARALLEL Swift
/// pass, then extract the level-`iso` isosurface here in pure Swift — no C
/// callback in the hot path. The resulting mesh is handed to ManifoldEngine only
/// once (a single `of_meshgl`), where a manifold handle is needed downstream.
///
/// Watertightness: each isosurface vertex lives on a unique GRID EDGE and is
/// linearly interpolated from that edge's two corner field values. Two adjacent
/// cubes sharing an edge interpolate the IDENTICAL point and we dedupe by a
/// canonical edge key, so every emitted vertex is shared by all incident faces
/// → a closed, 2-manifold surface (no cracks). Manifold's `of_meshgl` then
/// confirms 2-manifoldness.
enum MarchingCubes {

    /// A regular scalar field sampled at corners of an `(nx+1)·(ny+1)·(nz+1)`
    /// lattice spanning `[origin, origin + size·spacing]`.
    struct ScalarField {
        /// Corner counts along each axis (cells = corners - 1).
        let cx: Int   // corners in x  (= nx + 1)
        let cy: Int
        let cz: Int
        let origin: Vec3
        let dx: Double
        let dy: Double
        let dz: Double
        /// Flat corner values, indexed by `(z*cy + y)*cx + x`.
        var values: [Double]

        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
            (z * cy + y) * cx + x
        }
        @inline(__always) func corner(_ x: Int, _ y: Int, _ z: Int) -> Vec3 {
            Vec3(x: origin.x + Double(x) * dx,
                 y: origin.y + Double(y) * dy,
                 z: origin.z + Double(z) * dz)
        }
    }

    /// Extract the `iso`-level isosurface as a deduplicated, indexed,
    /// outward-oriented mesh. Convention: the solid is where `value > iso`
    /// (matches the healer's positive-inside field), so triangles are wound so
    /// their normals point OUT of the solid.
    static func surface(_ f: ScalarField, iso: Double = 0.0) -> MeshGeometryData {
        let cellX = f.cx - 1, cellY = f.cy - 1, cellZ = f.cz - 1
        guard cellX > 0, cellY > 0, cellZ > 0 else {
            return MeshGeometryData(vertices: [], triangleIndices: [])
        }

        var verts: [Vec3] = []
        var indices: [Int32] = []
        // Edge-key -> emitted vertex id. A grid edge is keyed by its lower corner
        // linear index plus the edge axis (0=x,1=y,2=z), unique across the lattice.
        var edgeVertex: [Int: Int32] = [:]
        verts.reserveCapacity(cellX * cellY * cellZ / 4 + 8)
        indices.reserveCapacity(cellX * cellY * cellZ / 2 + 8)

        // Corner offsets in the standard marching-cubes vertex numbering.
        // Corner i bit set => that corner is INSIDE (value > iso).
        let cornerOffset: [(Int, Int, Int)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        // Each of the 12 cube edges as (cornerA, cornerB).
        let edgeCorners: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]

        var cornerVal = [Double](repeating: 0, count: 8)
        var cornerPos = [Vec3](repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
        var cornerIdx = [(Int, Int, Int)](repeating: (0, 0, 0), count: 8)
        var edgeVid = [Int32](repeating: -1, count: 12)

        for z in 0..<cellZ {
            for y in 0..<cellY {
                for x in 0..<cellX {
                    // Gather the 8 corner values + classify inside/outside.
                    var cubeIndex = 0
                    for ci in 0..<8 {
                        let (ox, oy, oz) = cornerOffset[ci]
                        let gx = x + ox, gy = y + oy, gz = z + oz
                        let v = f.values[f.index(gx, gy, gz)]
                        cornerVal[ci] = v
                        cornerIdx[ci] = (gx, gy, gz)
                        if v > iso { cubeIndex |= (1 << ci) }
                    }
                    let edgeMask = MarchingCubesTables.edgeTable[cubeIndex]
                    if edgeMask == 0 { continue }

                    // Lazily compute corner positions only for active cubes.
                    for ci in 0..<8 {
                        let (gx, gy, gz) = cornerIdx[ci]
                        cornerPos[ci] = f.corner(gx, gy, gz)
                    }

                    // For each active edge, get-or-create its interpolated vertex.
                    for e in 0..<12 where (edgeMask & (1 << e)) != 0 {
                        let (a, b) = edgeCorners[e]
                        edgeVid[e] = vertexForEdge(
                            f: f, iso: iso,
                            ca: cornerIdx[a], cb: cornerIdx[b],
                            pa: cornerPos[a], pb: cornerPos[b],
                            va: cornerVal[a], vb: cornerVal[b],
                            verts: &verts, edgeVertex: &edgeVertex
                        )
                    }

                    // Emit triangles from the case table.
                    let tri = MarchingCubesTables.triTable[cubeIndex]
                    var i = 0
                    while i < tri.count && tri[i] >= 0 {
                        // Wind so normals point OUT of the solid (value > iso).
                        // The tri table is authored for "inside = value < iso";
                        // since our solid is value > iso (sign flipped), reverse
                        // the winding to keep outward normals.
                        let e0 = Int(tri[i]), e1 = Int(tri[i + 1]), e2 = Int(tri[i + 2])
                        indices.append(edgeVid[e0])
                        indices.append(edgeVid[e2])
                        indices.append(edgeVid[e1])
                        i += 3
                    }
                }
            }
        }
        return MeshGeometryData(vertices: verts, triangleIndices: indices)
    }

    /// Canonical key for the grid edge between corners `ca` and `cb` (each a grid
    /// corner triple). The edge is identified by its minimum corner's linear
    /// index and the axis it runs along — identical for both cubes sharing it.
    @inline(__always)
    private static func vertexForEdge(
        f: ScalarField, iso: Double,
        ca: (Int, Int, Int), cb: (Int, Int, Int),
        pa: Vec3, pb: Vec3, va: Double, vb: Double,
        verts: inout [Vec3], edgeVertex: inout [Int: Int32]
    ) -> Int32 {
        // Order corners canonically (lower linear index first).
        let ia = (ca.2 * f.cy + ca.1) * f.cx + ca.0
        let ib = (cb.2 * f.cy + cb.1) * f.cx + cb.0
        let lowIdx = Swift.min(ia, ib)
        // Axis: the single coordinate that differs.
        let axis: Int = (ca.0 != cb.0) ? 0 : (ca.1 != cb.1) ? 1 : 2
        // 3 edge slots per corner; key is collision-free across the lattice.
        let key = lowIdx * 3 + axis

        if let existing = edgeVertex[key] { return existing }

        // Linear interpolation of the iso-crossing along the edge.
        let denom = (vb - va)
        let t = abs(denom) > 1e-12 ? (iso - va) / denom : 0.5
        let tc = Swift.min(Swift.max(t, 0.0), 1.0)
        let p = Vec3(x: pa.x + tc * (pb.x - pa.x),
                     y: pa.y + tc * (pb.y - pa.y),
                     z: pa.z + tc * (pb.z - pa.z))
        let id = Int32(verts.count)
        verts.append(p)
        edgeVertex[key] = id
        return id
    }
}
