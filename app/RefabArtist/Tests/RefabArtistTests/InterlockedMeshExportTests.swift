import Foundation
import Testing
@testable import RefabArtist

struct InterlockedMeshExportTests {
    @Test
    func interlockedMeshExportLayersPreservePrimaryAndSecondaryLabels() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 10))

        let layers = InterlockedSliceMeshExportBuilder.layers(plan: plan, model: model)

        // Each interlocked registration family contributes a fixed ten slices
        // (the decoded by-count rule, independent of the material thickness),
        // so a two-family plan has 20 layers: primary_001…primary_010 then
        // secondary_001…secondary_010.
        #expect(layers.count == plan.sliceCount)
        #expect(plan.primary.sliceCount == 10)
        #expect(plan.secondary.sliceCount == 10)
        #expect(layers.first?.name == "primary_001")
        #expect(layers.last?.name == "secondary_010")
        #expect(layers.allSatisfy { !$0.mesh.vertices.isEmpty })
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
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
