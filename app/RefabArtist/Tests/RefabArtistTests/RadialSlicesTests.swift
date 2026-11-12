import Foundation
import Testing
@testable import RefabArtist

struct RadialSlicesTests {
    @Test
    func radialPlannerCarriesSlotManufacturingControls() throws {
        let model = try Self.cubeModel()
        let plan = try #require(RadialSlicePlanner.plan(
            model: model,
            nRadial: 12,
            materialThickness: 5,
            slotClearance: 0.25,
            notchWidthOverride: 6.5,
            slotAngleDegrees: 80,
            notchFactor: 1.25,
            reliefType: .vertical
        ))

        #expect(plan.slotWidth == 6.5)
        #expect(plan.slotAngleDegrees == 60)
        #expect(plan.notchFactor == 1.25)
        #expect(plan.reliefType == .vertical)
    }

    @Test
    func radialFirstAxisDistributionOverridesThreadThroughThePlan() throws {
        let model = try Self.cubeModel()

        let byCount = try #require(RadialSlicePlanner.plan(
            model: model, nRadial: 12, materialThickness: 5, firstAxisCountOverride: 6
        ))
        #expect(byCount.primary?.sliceCount == 6)

        let byDistance = try #require(RadialSlicePlanner.plan(
            model: model, nRadial: 12, materialThickness: 5, firstAxisSpacingOverride: 10
        ))
        let positions = try #require(byDistance.primary?.positions)
        #expect(positions.count >= 2)
        for index in 1..<positions.count {
            #expect(abs(positions[index] - positions[index - 1] - 10) < 1.0e-9)
        }
        // By-distance spacing must not leak into the part thickness.
        #expect(byDistance.primary?.materialThickness == 5)

        let defaulted = try #require(RadialSlicePlanner.plan(
            model: model, nRadial: 12, materialThickness: 5
        ))
        #expect(defaulted.primary?.sliceCount == StackedSlicePlanner.interlockedDefaultFamilyCount)
    }

    @Test
    func radialRingNotchesAreTheSlotWidth() throws {
        let model = try Self.sphereModel()
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 8, materialThickness: 5))
        let width = try #require(Self.equatorNotchWidth(plan: plan, model: model))
        #expect(abs(width - plan.slotWidth) < 1.0e-6)
        #expect(plan.slotWidth == 5)
    }

    @Test
    func radialMeshExportLayersEmitDisksThenWedges() throws {
        let model = try Self.cubeModel()
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5))

        let layers = RadialSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: 5)

        let diskCount = try #require(plan.primary?.sliceCount)
        #expect(layers.count == diskCount + RadialPartBuilder.wedgeCount(plan: plan))
        #expect(layers.first?.name == "first_axis_001")
        #expect(layers.last?.name == "radial_012")
        #expect(layers.allSatisfy { !$0.mesh.vertices.isEmpty })
    }

    @Test
    func radialWedgeCountHonorsRequestedCountExceptEight() throws {
        let model = try Self.cubeModel()

        let n4 = try #require(RadialSlicePlanner.plan(model: model, nRadial: 4, materialThickness: 5))
        let n6 = try #require(RadialSlicePlanner.plan(model: model, nRadial: 6, materialThickness: 5))
        let n8Default = try #require(RadialSlicePlanner.plan(model: model, nRadial: 8, materialThickness: 5))
        let n12 = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5))

        #expect(RadialPartBuilder.wedgeCount(plan: n4) == 4)
        #expect(RadialPartBuilder.wedgeCount(plan: n6) == 6)
        #expect(RadialPartBuilder.wedgeCount(plan: n8Default) == 10)
        #expect(RadialPartBuilder.wedgeCount(plan: n12) == 12)
    }

    @Test
    func radialPrimaryAxisStaysOnZ() throws {
        let sphere = try Self.sphereModel()
        let spherePlan = try #require(RadialSlicePlanner.plan(model: sphere, nRadial: 8, materialThickness: 5))
        #expect(spherePlan.primary?.axis == .z)

        let cylinder = try Self.cylinderModel()
        let cylinderPlan = try #require(RadialSlicePlanner.plan(model: cylinder, nRadial: 8, materialThickness: 5))
        #expect(cylinderPlan.primary?.axis == .z)
    }

    /// Width of the angle-0 notch in the equator ring: the distance between
    /// its two walls, measured across it halfway out from its bottom to the
    /// rim.
    private static func equatorNotchWidth(plan: RadialSlicePlan, model: MeshSummary) -> Double? {
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        guard let primary = plan.primary,
              let equator = primary.positions.indices.min(by: { abs(primary.positions[$0]) < abs(primary.positions[$1]) }),
              let joint = assembly.joints.first(where: { $0.ringLayer == equator && $0.fin == 0 }),
              let disk = assembly.disks.first(where: { $0.sliceIndex == equator }) else { return nil }
        let across = CurveJointPlanner.SectionLine(
            origin: Vec2(x: (joint.meet + joint.end) / 2, y: 0),
            direction: Vec2(x: 0, y: 1)
        )
        let spans = CurveJointPlanner.materialSpans([disk.loop] + disk.holes, along: across)
        guard let below = spans.last(where: { $0.hi < 0 }), let above = spans.first(where: { $0.lo > 0 }) else { return nil }
        return above.lo - below.hi
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func sphereModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl"))
    }

    private static func cylinderModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl"))
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
