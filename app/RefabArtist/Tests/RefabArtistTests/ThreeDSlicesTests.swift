import Foundation
import Testing
@testable import RefabArtist

struct ThreeDSlicesTests {
    @Test
    func threeDPlannerCreatesAllAxisFamilies() throws {
        let model = try Self.cubeModel()
        let plan = ThreeDSlicePlanner.plan(model: model, materialThickness: 5)!

        #expect(plan.x.axis == .x)
        #expect(plan.y.axis == .y)
        #expect(plan.z.axis == .z)
        #expect(plan.x.sliceCount == 10)
        #expect(plan.y.sliceCount == 10)
        #expect(plan.z.sliceCount == 10)
        #expect(plan.slotWidth == 5)
        #expect(plan.slotAngleDegrees == 0)
        #expect(plan.sliceCount == 30)
    }

    @Test
    func threeDPlannerUsesManufacturingSlotControls() throws {
        let model = try Self.cubeModel()
        let plan = try #require(ThreeDSlicePlanner.plan(
            model: model,
            materialThickness: 5,
            slotClearance: 0.4,
            notchWidthOverride: 7.5,
            slotAngleDegrees: 80
        ))

        #expect(plan.slotWidth == 7.5)
        #expect(plan.slotAngleDegrees == 60)
    }

    @Test
    func threeDPlannerSeparatesSliceDepthFromStockThickness() throws {
        let model = try Self.cubeModel()
        let plan = try #require(ThreeDSlicePlanner.plan(
            model: model,
            materialThickness: 5,
            sliceDepth: 10
        ))

        #expect(plan.x.materialThickness == 5)
        #expect(plan.y.materialThickness == 5)
        #expect(plan.z.materialThickness == 5)
        #expect(plan.x.sliceCount == 5)
        #expect(plan.y.sliceCount == 5)
        #expect(plan.z.sliceCount == 5)
        #expect(plan.slotWidth == 5)
        #expect(plan.sliceCount == 15)
    }

    @Test
    func threeDPlannerFollowsTheSliceGrid() throws {
        let model = try Self.cubeModel()
        let plan = try #require(ThreeDSlicePlanner.plan(
            model: model,
            materialThickness: 5,
            sliceDepth: 10
        ))

        // The 50 mm cube at a 10 mm slice depth is cut on each axis at
        // automaticPositions(-25, 25, 10): 5 centred slices at a 10 mm pitch
        // (asymmetric about 0 by 2.5 mm, matching the planner's grid).
        let specGrid = [-17.5, -7.5, 2.5, 12.5, 22.5]
        #expect(plan.x.sliceCount == 5)
        #expect(plan.y.sliceCount == 5)
        #expect(plan.z.sliceCount == 5)
        #expect(plan.x.positions == specGrid)
        #expect(plan.y.positions == specGrid)
        #expect(plan.z.positions == specGrid)
    }

    @Test
    func threeDMeshExportLayersPreserveSurfacePerLayer() throws {
        // 3D Slices = single-axis (Z) horizontal slicing where each layer keeps
        // the model's true surface — NOT a three-family waffle. One layer per
        // Z slice; the layers together span the full model height (the surface
        // is preserved, just divided into peel-apart bands).
        let model = try Self.cubeModel()
        let plan = ThreeDSlicePlanner.plan(model: model, materialThickness: 5)!

        let layers = ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)

        #expect(layers.count == plan.z.sliceCount)               // single axis, not 3 families
        #expect(layers.first?.name == "three_d_001")
        #expect(layers.allSatisfy { !$0.mesh.vertices.isEmpty })
        #expect(layers.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 } > 0)

        // The stacked layers reconstruct the model's full Z extent.
        let bounds = try #require(model.bounds)
        let allZ = layers.flatMap { $0.mesh.vertices.map(\.z) }
        let minZ = try #require(allZ.min())
        let maxZ = try #require(allZ.max())
        #expect(abs(minZ - bounds.min.z) < 1.0)
        #expect(abs(maxZ - bounds.max.z) < 1.0)
        // Surface preserved: a layer's cross-section spans the cube's full width,
        // not a thin slot panel.
        let xs = layers.flatMap { $0.mesh.vertices.map(\.x) }
        #expect((try #require(xs.max())) - (try #require(xs.min())) > (bounds.max.x - bounds.min.x) - 1.0)
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
