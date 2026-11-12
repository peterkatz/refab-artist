import Foundation
import Testing
@testable import RefabArtist

/// The Repair button must only remove triangles that cannot be real surface.
/// Regression for the raw-unit bug: the old absolute area threshold deleted
/// 63% of a valid inch-unit relief (Sardiniers6: 892,108 -> 326,083 triangles).
struct MeshSafeRepairTests {
    private static let a = Vec3(x: 0, y: 0, z: 0)
    private static let b = Vec3(x: 10, y: 0, z: 0)
    private static let c = Vec3(x: 0, y: 10, z: 0)
    private static let d = Vec3(x: 0, y: 0, z: 10)

    /// Closed tetrahedron a, b, c, d (indices 0...3).
    private static let tetraIndices: [Int32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]

    /// Per-triangle corner positions, in order — what the surface IS,
    /// independent of vertex numbering.
    private static func corners(_ geometry: MeshGeometryData) -> [[Double]] {
        stride(from: 0, to: geometry.triangleIndices.count, by: 3).map { t in
            (0..<3).flatMap { k -> [Double] in
                let v = geometry.vertices[Int(geometry.triangleIndices[t + k])]
                return [v.x, v.y, v.z]
            }
        }
    }

    @Test
    func tinyUnitClosedCubeKeepsEveryTriangle() {
        // A closed cube 1e-4 units across (a unit-box or inch file seen in raw
        // units): every face is below the preflight's absolute area threshold,
        // yet all of it is real surface.
        let s = 1.0e-4
        let vertices = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0), Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s), Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s)
        ]
        let indices: [Int32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5,
            2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7
        ]
        let cube = MeshGeometryData(vertices: vertices, triangleIndices: indices)
        #expect(MeshPreflight.analyze(geometry: cube).degenerateTriangleCount == 12)

        let result = MeshManifoldRepair.safeRepair(cube)

        #expect(result.removedTriangles == 0)
        #expect(result.geometry == cube)
    }

    @Test
    func removesCollapsedTriangleOnly() {
        let mesh = MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d],
            triangleIndices: Self.tetraIndices + [0, 1, 1]
        )

        let result = MeshManifoldRepair.safeRepair(mesh)

        #expect(result.collapsedTriangles == 1)
        #expect(result.looseZeroAreaTriangles == 0)
        #expect(result.finTriangles == 0)
        #expect(Self.corners(result.geometry) == Self.corners(MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d],
            triangleIndices: Self.tetraIndices
        )))
    }

    @Test
    func removesLooseZeroAreaSpeck() {
        // A collinear triangle floating away from the solid.
        let mesh = MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d,
                       Vec3(x: 20, y: 0, z: 0), Vec3(x: 25, y: 0, z: 0), Vec3(x: 30, y: 0, z: 0)],
            triangleIndices: Self.tetraIndices + [4, 5, 6]
        )

        let result = MeshManifoldRepair.safeRepair(mesh)

        #expect(result.looseZeroAreaTriangles == 1)
        #expect(result.collapsedTriangles == 0)
        #expect(Self.corners(result.geometry) == Self.corners(MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d],
            triangleIndices: Self.tetraIndices
        )))
    }

    @Test
    func keepsZeroAreaTriangleStitchedIntoTheSurface() {
        // Face (a, c, b) split at m, the midpoint of a-b, leaves a T-junction;
        // the collinear sliver (a, m, b) closes it. Its three edges are each
        // shared with a real face, so deleting it would open a crack.
        let m = Vec3(x: 5, y: 0, z: 0)
        let mesh = MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d, m],
            triangleIndices: [
                0, 2, 4, 4, 2, 1,   // (a, c, m), (m, c, b)
                0, 1, 3, 0, 3, 2, 1, 2, 3,
                0, 4, 1             // zero-area sliver (a, m, b)
            ]
        )

        let result = MeshManifoldRepair.safeRepair(mesh)

        #expect(result.removedTriangles == 0)
        #expect(result.geometry == mesh)
    }

    @Test
    func stillRemovesWingedFin() {
        // Fin sharing edge a-b with the tetrahedron, with a free apex.
        let mesh = MeshGeometryData(
            vertices: [Self.a, Self.b, Self.c, Self.d, Vec3(x: 5, y: -10, z: 0)],
            triangleIndices: Self.tetraIndices + [0, 1, 4]
        )

        let result = MeshManifoldRepair.safeRepair(mesh)

        #expect(result.finTriangles == 1)
        #expect(result.geometry.triangleIndices.count == Self.tetraIndices.count)
    }
}
