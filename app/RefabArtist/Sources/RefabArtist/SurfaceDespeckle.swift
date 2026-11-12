import Foundation

/// Feature-preserving surface de-speckle — a POST-PROCESS that removes the
/// isolated triangular pits/dimples marching cubes scatters across an otherwise
/// smooth isosurface, WITHOUT touching the marching-cubes algorithm itself, the
/// smooth curved surfaces, or the sharp "rail" edges the gyroid look depends on.
///
/// Why the dimples exist: on a thin TPMS band field (`|g| < band`), wherever an
/// iso-crossing lands almost exactly on a grid corner, the vertices there are
/// pulled a little off the smooth surface, denting individual triangles into
/// visible pits and making neighbouring facets flip light/dark under shading.
///
/// Method — **bilateral normal filtering** (Zheng et al. 2011), the standard
/// feature-preserving mesh denoiser:
///   1. Smooth each triangle's normal toward its edge-adjacent neighbours,
///      weighting each neighbour by BOTH spatial closeness (a Gaussian in
///      centroid distance) AND normal similarity (a Gaussian in normal
///      difference). The normal-similarity term is what preserves features:
///      across a sharp rail edge the neighbour normal differs a lot, so its
///      weight collapses and the edge is NOT rounded. Across the smooth sheet
///      the dimple noise is averaged away.
///   2. March the vertices a few steps so the surface matches the smoothed
///      normals (Sun et al. update). Gentle by construction — typical motion is
///      a fraction of the wall thickness.
///
/// Topology never changes (positions only), so a watertight mesh stays
/// watertight; the indexed result feeds straight back into Manifold.
enum SurfaceDespeckle {

    /// Remove dimples from `mesh` while keeping smooth curves and sharp rails.
    /// - Parameters:
    ///   - normalIterations: bilateral normal-smoothing passes.
    ///   - sigmaNormal: normal-difference falloff (the FEATURE threshold). Larger
    ///     smooths more aggressively / preserves fewer edges; ~0.35 keeps rails.
    ///   - vertexIterations: vertex-march steps per normal pass.
    static func polished(
        _ mesh: MeshGeometryData,
        normalIterations: Int = 4,
        sigmaNormal: Double = 0.35,
        vertexIterations: Int = 12
    ) -> MeshGeometryData {
        let n = mesh.vertices.count
        let idx = mesh.triangleIndices
        let faceCount = idx.count / 3
        guard n > 2, faceCount > 1 else { return mesh }

        // Face corner indices as flat Int arrays.
        var fa = [Int](repeating: 0, count: faceCount)
        var fb = [Int](repeating: 0, count: faceCount)
        var fc = [Int](repeating: 0, count: faceCount)
        for f in 0..<faceCount {
            fa[f] = Int(idx[3 * f]); fb[f] = Int(idx[3 * f + 1]); fc[f] = Int(idx[3 * f + 2])
        }

        // Edge-adjacent face pairs (manifold edge → exactly two faces). Keyed by
        // the sorted endpoint pair; the first face to claim an edge is recorded,
        // the second emits a symmetric (face,neighbour) pair.
        var firstFaceForEdge: [Int64: Int32] = [:]
        firstFaceForEdge.reserveCapacity(faceCount * 3)
        var adjSrc: [Int] = []; adjSrc.reserveCapacity(faceCount * 3)
        var adjDstArr: [Int] = []; adjDstArr.reserveCapacity(faceCount * 3)
        let nN = Int64(n)
        @inline(__always) func edgeKey(_ u: Int, _ v: Int) -> Int64 {
            let lo = Int64(min(u, v)), hi = Int64(max(u, v))
            return lo * nN + hi
        }
        for f in 0..<faceCount {
            let verts = (fa[f], fb[f], fc[f])
            let edges = [(verts.0, verts.1), (verts.1, verts.2), (verts.2, verts.0)]
            for (u, v) in edges {
                let key = edgeKey(u, v)
                if let g = firstFaceForEdge[key] {
                    let gi = Int(g)
                    adjSrc.append(f); adjDstArr.append(gi)
                    adjSrc.append(gi); adjDstArr.append(f)
                } else {
                    firstFaceForEdge[key] = Int32(f)
                }
            }
        }
        firstFaceForEdge.removeAll(keepingCapacity: false)

        var verts = mesh.vertices

        // Mean edge length → spatial sigma.
        var edgeLenSum = 0.0
        for f in 0..<faceCount { edgeLenSum += dist(verts[fa[f]], verts[fb[f]]) }
        let meanEdge = max(edgeLenSum / Double(faceCount), 1e-6)
        let sigmaC = 2.0 * meanEdge
        let invC2 = 1.0 / (2.0 * sigmaC * sigmaC)
        let invN2 = 1.0 / (2.0 * sigmaNormal * sigmaNormal)

        // Per-face working buffers.
        var fnx = [Double](repeating: 0, count: faceCount)
        var fny = [Double](repeating: 0, count: faceCount)
        var fnz = [Double](repeating: 0, count: faceCount)
        var area = [Double](repeating: 0, count: faceCount)
        var cx = [Double](repeating: 0, count: faceCount)
        var cy = [Double](repeating: 0, count: faceCount)
        var cz = [Double](repeating: 0, count: faceCount)

        @inline(__always) func recomputeFaces() {
            for f in 0..<faceCount {
                let a = verts[fa[f]], b = verts[fb[f]], c = verts[fc[f]]
                let ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
                let vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
                var nx = uy * vz - uz * vy
                var ny = uz * vx - ux * vz
                var nz = ux * vy - uy * vx
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                area[f] = 0.5 * len
                if len > 1e-12 { nx /= len; ny /= len; nz /= len } else { nx = 0; ny = 0; nz = 1 }
                fnx[f] = nx; fny[f] = ny; fnz[f] = nz
                cx[f] = (a.x + b.x + c.x) / 3.0
                cy[f] = (a.y + b.y + c.y) / 3.0
                cz[f] = (a.z + b.z + c.z) / 3.0
            }
        }
        recomputeFaces()

        let adjCount = adjSrc.count
        var accx = [Double](repeating: 0, count: faceCount)
        var accy = [Double](repeating: 0, count: faceCount)
        var accz = [Double](repeating: 0, count: faceCount)

        for _ in 0..<max(normalIterations, 1) {
            // 1) Bilateral-smooth face normals.
            // Self term (area-weighted) so a face keeps its own orientation base.
            for f in 0..<faceCount {
                accx[f] = fnx[f] * area[f]
                accy[f] = fny[f] * area[f]
                accz[f] = fnz[f] * area[f]
            }
            for e in 0..<adjCount {
                let s = adjSrc[e], d = adjDstArr[e]
                let dcx = cx[s] - cx[d], dcy = cy[s] - cy[d], dcz = cz[s] - cz[d]
                let dc2 = dcx * dcx + dcy * dcy + dcz * dcz
                let dnx = fnx[s] - fnx[d], dny = fny[s] - fny[d], dnz = fnz[s] - fnz[d]
                let dn2 = dnx * dnx + dny * dny + dnz * dnz
                let w = area[d] * exp(-dc2 * invC2) * exp(-dn2 * invN2)
                accx[s] += w * fnx[d]
                accy[s] += w * fny[d]
                accz[s] += w * fnz[d]
            }
            for f in 0..<faceCount {
                let len = (accx[f] * accx[f] + accy[f] * accy[f] + accz[f] * accz[f]).squareRoot()
                if len > 1e-12 { fnx[f] = accx[f] / len; fny[f] = accy[f] / len; fnz[f] = accz[f] / len }
            }

            // 2) March vertices toward the smoothed normals.
            for _ in 0..<max(vertexIterations, 1) {
                var dispx = [Double](repeating: 0, count: n)
                var dispy = [Double](repeating: 0, count: n)
                var dispz = [Double](repeating: 0, count: n)
                var deg = [Double](repeating: 0, count: n)
                for f in 0..<faceCount {
                    // Recompute centroid from current verts.
                    let a = verts[fa[f]], b = verts[fb[f]], c = verts[fc[f]]
                    let ccx = (a.x + b.x + c.x) / 3.0
                    let ccy = (a.y + b.y + c.y) / 3.0
                    let ccz = (a.z + b.z + c.z) / 3.0
                    let nx = fnx[f], ny = fny[f], nz = fnz[f]
                    // For each corner: disp += n * (n · (centroid - corner)).
                    let corners = (fa[f], fb[f], fc[f])
                    var k = 0
                    while k < 3 {
                        let vi = k == 0 ? corners.0 : (k == 1 ? corners.1 : corners.2)
                        let p = verts[vi]
                        let ex = ccx - p.x, ey = ccy - p.y, ez = ccz - p.z
                        let proj = nx * ex + ny * ey + nz * ez
                        dispx[vi] += nx * proj; dispy[vi] += ny * proj; dispz[vi] += nz * proj
                        deg[vi] += 1
                        k += 1
                    }
                }
                for i in 0..<n where deg[i] > 0 {
                    let inv = 1.0 / deg[i]
                    verts[i] = Vec3(x: verts[i].x + dispx[i] * inv,
                                    y: verts[i].y + dispy[i] * inv,
                                    z: verts[i].z + dispz[i] * inv)
                }
            }

            recomputeFaces()
        }

        return MeshGeometryData(vertices: verts, triangleIndices: idx)
    }

    @inline(__always) private static func dist(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
