import Foundation
import Testing
@testable import RefabArtist

struct ViewportSmoothShadingTests {
    @Test
    func smoothShadedMeshWeldsVerticesAndNormalizesNormals() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl")
        )
        let smooth = ViewportMeshRenderData.smoothShadedMesh(from: model.geometry)
        let flat = ViewportMeshRenderData.flatShadedMesh(from: model.geometry)

        // Welding by position shares vertices, so there are far fewer than the
        // flat mesh's 3-per-triangle expansion, but the triangle count matches.
        #expect(smooth.vertices.count < flat.vertices.count)
        #expect(smooth.vertices.count == smooth.normals.count)
        #expect(smooth.triangleIndices.count == flat.triangleIndices.count)
        #expect(!smooth.vertices.isEmpty)

        // Every vertex normal is unit length (smooth averaged, not zero).
        for normal in smooth.normals {
            let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
            #expect(abs(length - 1.0) < 1e-3)
        }
    }

    @Test
    func smoothShadedMeshSplitsSharpCreases() {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 0, z: 1)
            ],
            triangleIndices: [
                0, 1, 2,
                0, 3, 1
            ]
        )

        let smooth = ViewportMeshRenderData.smoothShadedMesh(from: mesh, creaseAngleDegrees: 58)

        #expect(smooth.triangleIndices.count == mesh.triangleIndices.count)
        #expect(smooth.vertices.count == 6)
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
