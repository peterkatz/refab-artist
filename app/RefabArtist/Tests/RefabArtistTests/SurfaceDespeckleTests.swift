import XCTest
@testable import RefabArtist

/// SurfaceDespeckle is the feature-preserving post-process that removes the
/// shallow triangular dimples marching cubes scatters across the gyroid sheet.
/// These tests use a synthetic flat grid (no Manifold) so they run fast.
final class SurfaceDespeckleTests: XCTestCase {

    /// Build a regular `n×n` triangulated grid on the z=0 plane with unit
    /// spacing, returning indexed geometry plus the linear index helper.
    private func flatGrid(_ n: Int) -> (MeshGeometryData, (Int, Int) -> Int) {
        var verts: [Vec3] = []
        for j in 0..<n { for i in 0..<n { verts.append(Vec3(x: Double(i), y: Double(j), z: 0)) } }
        let idx = { (i: Int, j: Int) in j * n + i }
        var tris: [Int32] = []
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = idx(i, j), b = idx(i + 1, j), c = idx(i + 1, j + 1), d = idx(i, j + 1)
                tris += [Int32(a), Int32(b), Int32(c)]
                tris += [Int32(a), Int32(c), Int32(d)]
            }
        }
        return (MeshGeometryData(vertices: verts, triangleIndices: tris), idx)
    }

    func testTopologyIsPreserved() {
        let (mesh, _) = flatGrid(12)
        let out = SurfaceDespeckle.polished(mesh)
        // Positions-only: vertex count and the index array are untouched, so a
        // watertight mesh stays watertight.
        XCTAssertEqual(out.vertices.count, mesh.vertices.count)
        XCTAssertEqual(out.triangleIndices, mesh.triangleIndices)
    }

    func testShallowDimplesAreFlattened() {
        var (mesh, idx) = flatGrid(16)
        // Push a handful of interior vertices off the plane by a SHALLOW amount
        // (the regime real MC dimples live in — gentle normal deviation).
        let dimpled = [(5, 5), (8, 4), (4, 9), (10, 10), (7, 11)]
        for (i, j) in dimpled { mesh.vertices[idx(i, j)].z = (i + j) % 2 == 0 ? 0.18 : -0.18 }

        let before = dimpled.map { abs(mesh.vertices[idx($0.0, $0.1)].z) }.reduce(0, +)
        let out = SurfaceDespeckle.polished(mesh)
        let after = dimpled.map { abs(out.vertices[idx($0.0, $0.1)].z) }.reduce(0, +)

        // The dimples are pulled substantially back toward the smooth plane.
        XCTAssertLessThan(after, before * 0.5,
                          "dimples should be at least halved (before=\(before), after=\(after))")
    }

    func testFlatRegionStaysFlat() {
        let (mesh, idx) = flatGrid(14)
        let out = SurfaceDespeckle.polished(mesh)
        // A vertex in a genuinely flat neighbourhood must not be disturbed.
        let z = out.vertices[idx(7, 7)].z
        XCTAssertEqual(z, 0, accuracy: 1e-6)
    }

    func testEmptyAndTinyMeshesAreSafe() {
        let empty = MeshGeometryData(vertices: [], triangleIndices: [])
        XCTAssertEqual(SurfaceDespeckle.polished(empty).vertices.count, 0)

        let oneTri = MeshGeometryData(
            vertices: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0)],
            triangleIndices: [0, 1, 2]
        )
        // No interior vertices to move; returns intact, no crash.
        XCTAssertEqual(SurfaceDespeckle.polished(oneTri).triangleIndices, oneTri.triangleIndices)
    }
}
