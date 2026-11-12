import Foundation
import Testing
@testable import RefabArtist

struct AssemblyStepTests {
    @Test
    func stackedStepsUseSliceLabelsInOrder() {
        let plan = StackedSlicePlan(axis: .z, materialThickness: 3, rangeMin: 0, rangeMax: 6, positions: [1.5, 4.5])

        let steps = AssemblyStepPlanner.steps(stacked: plan)

        #expect(steps.count == 2)
        #expect(steps[0].index == 1)
        #expect(steps[0].title == "Place slice_001")
        #expect(steps[1].title == "Place slice_002")
        #expect(steps[0].detail.contains("Z"))
        #expect(steps[0].detail.contains("1.5 mm"))
    }

    @Test
    func interlockedStepsIncludeFamiliesSlotsAndWidth() {
        let primary = StackedSlicePlan(axis: .z, materialThickness: 5, rangeMin: 0, rangeMax: 10, positions: [2.5, 7.5])
        let secondary = StackedSlicePlan(axis: .x, materialThickness: 5, rangeMin: 0, rangeMax: 5, positions: [2.5])
        let plan = InterlockedSlicePlan(
            primary: primary,
            secondary: secondary,
            materialThickness: 5,
            slotClearance: 0.2,
            slotWidth: 5.2,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        )

        let steps = AssemblyStepPlanner.steps(interlocked: plan)

        #expect(steps.count == 3)
        #expect(steps.map(\.title) == ["Place primary_001", "Place primary_002", "Insert secondary_001"])
        #expect(steps[0].detail.contains("4 slots"))
        #expect(steps[0].detail.contains("5.2 mm"))
        #expect(steps[2].detail.contains("matching primary slots"))
    }

    @Test
    func radialStepsUseDeterministicRadialLabels() {
        let plan = RadialSlicePlan(
            center: Vec3(x: 0, y: 0, z: 0),
            radius: 25,
            angles: [0, .pi / 4, .pi / 2]
        )

        let steps = AssemblyStepPlanner.steps(radial: plan)

        #expect(steps.count == 3)
        #expect(steps[0].title == "Insert radial_001")
        #expect(steps[2].title == "Insert radial_003")
        #expect(steps[2].detail.contains("90 degrees"))
    }

    @Test
    func radialStepsPlaceDisksFirstThenFins() {
        var plan = RadialSlicePlan(
            center: Vec3(x: 0, y: 0, z: 0),
            radius: 25,
            angles: [0, .pi]
        )
        plan.nRadial = 2
        plan.primary = StackedSlicePlan(axis: .z, materialThickness: 5, rangeMin: -25, rangeMax: 25, positions: [-12.5, 12.5])

        let steps = AssemblyStepPlanner.steps(radial: plan)

        #expect(steps.map(\.index) == [1, 2, 3, 4])
        #expect(steps.map(\.title) == [
            "Place first_axis_001",
            "Place first_axis_002",
            "Insert radial_001",
            "Insert radial_002"
        ])
        #expect(steps[0].detail.contains("Z ring at -12.5 mm"))
        #expect(steps[3].detail.contains("180 degrees"))
    }

    /// 3D Slices builds only the Z family's bands, so only they get steps,
    /// named as the mesh names its bands; each keeps the index counted
    /// through the X, Y and Z families, which the viewport maps to its band.
    @Test
    func threeDStepsAreTheBandsItBuilds() {
        let x = StackedSlicePlan(axis: .x, materialThickness: 5, rangeMin: 0, rangeMax: 5, positions: [2.5])
        let y = StackedSlicePlan(axis: .y, materialThickness: 5, rangeMin: 0, rangeMax: 5, positions: [2.5])
        let z = StackedSlicePlan(axis: .z, materialThickness: 5, rangeMin: 0, rangeMax: 10, positions: [2.5, 7.5])

        let steps = AssemblyStepPlanner.steps(threeD: ThreeDSlicePlan(x: x, y: y, z: z))

        #expect(steps.count == 2)
        #expect(steps.map(\.index) == [3, 4])
        #expect(steps.map(\.title) == ["Place three_d_001", "Place three_d_002"])
        #expect(steps[1].detail.contains("7.5 mm"))
        let highlight = AssemblyStepHighlighter.highlight(
            selectedStepID: steps[1].id, mode: .threeD, slicePlans: [x, y, z],
            radialPlan: nil, curvePlan: nil, foldedPanelPlan: nil
        )
        #expect(highlight == .stacked(familyIndex: 2, layerIndex: 1))
    }

    /// A slice whose parts are all left out of the export (a Radial ring no
    /// fin reaches: the simple chair's legs) has no step; the others keep
    /// their indices, so every part on the sheet keeps its step, and the
    /// guide numbers what is left in order.
    @Test
    func slicesLeftOutWholeHaveNoStep() throws {
        let chair = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/real-world/simple_chair.stl"))
        let plan = try #require(RadialSlicePlanner.plan(model: chair, nRadial: 12, materialThickness: 5))
        let document = CutSheetLayoutBuilder.document(radial: plan, model: chair, settings: .defaultValue, revision: 1)
        let planned = AssemblyStepPlanner.steps(radial: plan)
        let stepIndices = AssemblyStepPlanner.stepIndices(in: document, mode: .radial)
        let steps = AssemblyStepPlanner.exported(planned, stepIndices: stepIndices)

        // Rings 1 to 5 cut through the legs only, and no fin reaches them.
        #expect(planned.count - steps.count == 5)
        #expect(!steps.contains { ["first_axis_001", "first_axis_005"].contains(AssemblyStepPartLabel.label(for: $0) ?? "") })
        #expect(steps.first?.index == 6)
        let partSteps = Set(document.sheets.flatMap(\.parts).compactMap(\.stepIndex))
        #expect(Set(steps.map(\.index)) == partSteps)
        #expect(document.notes.contains { $0.hasPrefix("Z-1, Z-2, Z-3, Z-4 and Z-5 cross no fin and are left out") })

        let guide = AssemblyGuideExporter.document(
            context: AssemblyGuideContext(
                modelName: "simple_chair.stl", constructionMode: .radial, materialThickness: 5,
                slotClearance: 0, slotAngleDegrees: 0, dowelsEnabled: false, dowelDiameter: 0, dowelInset: 0
            ),
            steps: steps
        )
        #expect(guide.contains("1. \(steps[0].title)"))
        #expect(guide.contains("\(steps.count). \(steps[steps.count - 1].title)"))
        #expect(!guide.contains("\(steps.count + 1). "))

        // Without a cut sheet, or for a mode whose parts are not numbered by
        // step, nothing is dropped.
        #expect(AssemblyStepPlanner.exported(planned, stepIndices: nil) == planned)
        #expect(AssemblyStepPlanner.stepIndices(in: document, mode: .foldedPanels) == nil)
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
