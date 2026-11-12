import Testing
@testable import RefabArtist

struct AssemblyStepHighlightTests {
    @Test
    func stackedStepMapsToFirstFamilyLayer() {
        let plan = StackedSlicePlan(axis: .z, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5, 4.5, 7.5])

        let highlight = AssemblyStepHighlighter.highlight(
            selectedStepID: 2,
            mode: .stacked,
            slicePlans: [plan],
            radialPlan: nil,
            curvePlan: nil,
            foldedPanelPlan: nil
        )

        #expect(highlight == .stacked(familyIndex: 0, layerIndex: 1))
    }

    @Test
    func interlockedStepMapsAcrossPrimaryAndSecondaryFamilies() {
        let primary = StackedSlicePlan(axis: .z, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5, 4.5])
        let secondary = StackedSlicePlan(axis: .x, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5, 4.5, 7.5])

        let highlight = AssemblyStepHighlighter.highlight(
            selectedStepID: 4,
            mode: .interlocked,
            slicePlans: [primary, secondary],
            radialPlan: nil,
            curvePlan: nil,
            foldedPanelPlan: nil
        )

        #expect(highlight == .stacked(familyIndex: 1, layerIndex: 1))
    }

    @Test
    func threeDStepMapsAcrossXYZFamilies() {
        let x = StackedSlicePlan(axis: .x, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5])
        let y = StackedSlicePlan(axis: .y, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5, 4.5])
        let z = StackedSlicePlan(axis: .z, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5, 4.5, 7.5])

        let highlight = AssemblyStepHighlighter.highlight(
            selectedStepID: 5,
            mode: .threeD,
            slicePlans: [x, y, z],
            radialPlan: nil,
            curvePlan: nil,
            foldedPanelPlan: nil
        )

        #expect(highlight == .stacked(familyIndex: 2, layerIndex: 1))
    }

    @Test
    func radialCurveAndFoldedStepsMapToModeSpecificLayers() {
        let radial = RadialSlicePlan(center: Vec3(x: 0, y: 0, z: 0), radius: 10, angles: [0, 1, 2])
        let curve = CurveSlicePlan(
            primary: StackedSlicePlan(axis: .y, materialThickness: 3, rangeMin: -1, rangeMax: 1, positions: [0]),
            centers: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0)],
            directions: [Vec2(x: 1, y: 0), Vec2(x: 1, y: 0)],
            normals: [Vec2(x: 0, y: 1), Vec2(x: 0, y: 1)],
            amplitude: 5,
            controlPoints: [Vec2(x: -1, y: 0), Vec2(x: 1, y: 0)],
            slotWidth: 3,
            slotAngleDegrees: 0,
            bounds: Bounds3D(min: Vec3(x: -1, y: -1, z: -1), max: Vec3(x: 1, y: 1, z: 1))
        )
        let bounds = FoldedPanelBounds(min: Vec2(x: 0, y: 0), max: Vec2(x: 1, y: 1))
        let folded = FoldedPanelPlan(panels: [
            FoldedPanel(points: [], bounds: bounds, sourceTriangleIndex: 0),
            FoldedPanel(points: [], bounds: bounds, sourceTriangleIndex: 1),
            FoldedPanel(points: [], bounds: bounds, sourceTriangleIndex: 2)
        ])

        #expect(AssemblyStepHighlighter.highlight(selectedStepID: 3, mode: .radial, slicePlans: [], radialPlan: radial, curvePlan: nil, foldedPanelPlan: nil) == .radial(layerIndex: 2))
        #expect(AssemblyStepHighlighter.highlight(selectedStepID: 1, mode: .curve, slicePlans: [], radialPlan: nil, curvePlan: curve, foldedPanelPlan: nil) == .stacked(familyIndex: 0, layerIndex: 0))
        #expect(AssemblyStepHighlighter.highlight(selectedStepID: 3, mode: .curve, slicePlans: [], radialPlan: nil, curvePlan: curve, foldedPanelPlan: nil) == .curve(layerIndex: 1))
        #expect(AssemblyStepHighlighter.highlight(selectedStepID: 1, mode: .foldedPanels, slicePlans: [], radialPlan: nil, curvePlan: nil, foldedPanelPlan: folded) == .foldedPanel(panelIndex: 0))
    }

    @Test
    func invalidOrMissingSelectionDoesNotHighlight() {
        let plan = StackedSlicePlan(axis: .z, materialThickness: 3, rangeMin: 0, rangeMax: 9, positions: [1.5])

        #expect(AssemblyStepHighlighter.highlight(selectedStepID: nil, mode: .stacked, slicePlans: [plan], radialPlan: nil, curvePlan: nil, foldedPanelPlan: nil) == nil)
        #expect(AssemblyStepHighlighter.highlight(selectedStepID: 3, mode: .stacked, slicePlans: [plan], radialPlan: nil, curvePlan: nil, foldedPanelPlan: nil) == nil)
    }
}
