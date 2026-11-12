import Foundation
import Testing
@testable import RefabArtist

struct InflatablesMeshExportBuilderTests {
    @Test
    func panelRenderLayersSplitPreviewMeshByGeneratedPanels() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl")
        )
        let plan = try InflatablesPlanner.plan(model: model.geometry, settings: .defaultValue)
        let preview = try #require(plan.preview)
        let panelLayers = InflatablesMeshExportBuilder.panelRenderLayers(plan: plan)
        let wholeLayer = try #require(InflatablesMeshExportBuilder.renderMesh(plan: plan))
        let faceIDs = plan.panels.flatMap(\.sourceFaceIDs)
        let expectedFaceIDs = Array(0..<(preview.inflatedMesh.triangleIndices.count / 3))

        #expect(faceIDs.sorted() == expectedFaceIDs)
        #expect(Set(faceIDs).count == faceIDs.count)
        #expect(panelLayers.map(\.panelID) == plan.panels.map(\.id))
        #expect(panelLayers.count == plan.panels.count)
        #expect(panelLayers.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 } == wholeLayer.triangleIndices.count / 3)
        #expect(panelLayers.allSatisfy { !$0.mesh.vertices.isEmpty })
    }

    @Test
    func exportLayersUseInflatedPreviewMesh() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl")
        )
        let plan = try InflatablesPlanner.plan(model: model.geometry, settings: .defaultValue)
        let preview = try #require(plan.preview)
        let expected = ViewportMeshRenderData.smoothShadedMesh(from: preview.inflatedMesh)
        let layers = InflatablesMeshExportBuilder.layers(plan: plan)

        #expect(InflatablesMeshExportBuilder.renderMesh(plan: plan) == expected)
        #expect(layers.count == 1)
        #expect(layers.first?.mesh == expected)
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
