import Foundation
import Testing
@testable import RefabArtist

// Guards the viewport feature-edge cap. Each feature edge becomes its own
// RealityKit box entity and the edge set is recomputed on every scene rebuild,
// so on a dense mesh the overlay must be skipped (it both costs hundreds of ms
// and can explode into tens of thousands of entities). The mesh itself still
// renders — only the wireframe overlay is dropped above the budget.
struct ViewportPerfProbeTests {
    @Test
    func denseMeshSkipsFeatureEdgeOverlay() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/stress/sphere_dense_d50mm.stl")
        )
        #expect(model.triangleCount == 107_184)
        #expect(model.triangleCount > ViewportMeshRenderData.featureEdgeTriangleBudget)
        #expect(ViewportMeshRenderData.shouldRenderFeatureEdges(triangleCount: model.triangleCount) == false)
    }

    @Test
    func smallMeshKeepsFeatureEdgeOverlay() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cube_50mm_binary.stl")
        )
        #expect(model.triangleCount <= ViewportMeshRenderData.featureEdgeTriangleBudget)
        #expect(ViewportMeshRenderData.shouldRenderFeatureEdges(triangleCount: model.triangleCount))
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
