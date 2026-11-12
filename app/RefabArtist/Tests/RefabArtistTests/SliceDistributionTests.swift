import Foundation
import Testing
@testable import RefabArtist

struct SliceDistributionTests {
    @Test
    func stackedPlannerCanDistributeExplicitSliceCountAcrossRange() throws {
        let model = try Self.cubeModel()

        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5, sliceCountOverride: 4)

        #expect(plan?.sliceCount == 4)
        #expect(plan?.materialThickness == 5)
        #expect(plan?.positions == [-18.75, -6.25, 6.25, 18.75])
    }

    @Test
    func stackedPlannerClampsExplicitSliceCount() throws {
        let model = try Self.cubeModel()

        let low = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5, sliceCountOverride: -2)
        let high = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5, sliceCountOverride: 500)

        #expect(low?.sliceCount == 1)
        #expect(high?.sliceCount == 240)
    }

    @Test
    func automaticStackedPlannerUsesSpecCenteringFormula() throws {
        let model = try Self.cubeModel()

        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 4.50088)

        #expect(plan?.sliceCount == 11)
        #expect(abs((plan?.positions.first ?? 0) - (-21.37918)) < 1.0e-5)
        #expect(abs((plan?.positions.last ?? 0) - 23.62962) < 1.0e-5)
    }

    @Test
    func automaticStackedPlannerSliceCountsOn50mmCube() throws {
        let model = try Self.cubeModel()

        let depth5 = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5)
        let depth3 = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3)
        let depth10 = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 10)

        #expect(depth5?.sliceCount == 10)
        #expect(depth3?.sliceCount == 16)
        #expect(depth10?.sliceCount == 5)
    }

    @Test
    func interlockedPlannerUsesExplicitCountForBothFamilies() throws {
        let model = try Self.cubeModel()

        let plan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 5,
            sliceCountOverride: 3
        )

        #expect(plan?.primary.sliceCount == 3)
        #expect(plan?.secondary.sliceCount == 3)
        #expect(plan?.sliceCount == 6)
        #expect(plan?.slotCount == 18)
    }

    @Test
    func threeDPlannerUsesExplicitCountForEachAxisFamily() throws {
        let model = try Self.cubeModel()

        let plan = ThreeDSlicePlanner.plan(model: model, materialThickness: 5, sliceCountOverride: 2)

        #expect(plan?.x.sliceCount == 2)
        #expect(plan?.y.sliceCount == 2)
        #expect(plan?.z.sliceCount == 2)
        #expect(plan?.sliceCount == 6)
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
