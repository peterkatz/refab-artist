import Foundation

enum AssemblyStepHighlight: Equatable {
    case stacked(familyIndex: Int, layerIndex: Int)
    case radial(layerIndex: Int)
    case curve(layerIndex: Int)
    case foldedPanel(panelIndex: Int)
}

enum AssemblyStepHighlighter {
    static func highlight(
        selectedStepID: AssemblyStep.ID?,
        mode: ConstructionMode,
        slicePlans: [StackedSlicePlan],
        radialPlan: RadialSlicePlan?,
        curvePlan: CurveSlicePlan?,
        foldedPanelPlan: FoldedPanelPlan?
    ) -> AssemblyStepHighlight? {
        guard let selectedStepID, selectedStepID > 0 else {
            return nil
        }
        let zeroBasedIndex = selectedStepID - 1

        switch mode {
        case .stacked:
            guard slicePlans.indices.contains(0),
                  slicePlans[0].positions.indices.contains(zeroBasedIndex) else {
                return nil
            }
            return .stacked(familyIndex: 0, layerIndex: zeroBasedIndex)
        case .interlocked:
            return stackedFamilyHighlight(zeroBasedIndex: zeroBasedIndex, slicePlans: slicePlans)
        case .threeD:
            return stackedFamilyHighlight(zeroBasedIndex: zeroBasedIndex, slicePlans: slicePlans)
        case .radial:
            guard let radialPlan else {
                return nil
            }
            // Disk steps lead (stacked family 0), fin steps follow.
            let diskCount = radialPlan.primary?.positions.count ?? 0
            if zeroBasedIndex < diskCount {
                return .stacked(familyIndex: 0, layerIndex: zeroBasedIndex)
            }
            let wedgeIndex = zeroBasedIndex - diskCount
            let wedgeCount = radialPlan.nRadial > 0
                ? RadialPartBuilder.wedgeCount(plan: radialPlan)
                : radialPlan.angles.count
            guard wedgeIndex < wedgeCount else {
                return nil
            }
            return .radial(layerIndex: wedgeIndex)
        case .curve:
            guard let curvePlan else {
                return nil
            }
            if curvePlan.primary.positions.indices.contains(zeroBasedIndex) {
                return .stacked(familyIndex: 0, layerIndex: zeroBasedIndex)
            }
            let curveIndex = zeroBasedIndex - curvePlan.primary.positions.count
            guard curvePlan.centers.indices.contains(curveIndex) else {
                return nil
            }
            return .curve(layerIndex: curveIndex)
        case .foldedPanels:
            guard let foldedPanelPlan, foldedPanelPlan.panels.indices.contains(zeroBasedIndex) else {
                return nil
            }
            return .foldedPanel(panelIndex: zeroBasedIndex)
        case .inflatables, .structures, .partition, .motherMold:
            // These explicit-generate modes do not use legacy slice/panel
            // assembly steps.
            return nil
        }
    }

    private static func stackedFamilyHighlight(zeroBasedIndex: Int, slicePlans: [StackedSlicePlan]) -> AssemblyStepHighlight? {
        var remainingIndex = zeroBasedIndex
        for (familyIndex, plan) in slicePlans.enumerated() {
            if plan.positions.indices.contains(remainingIndex) {
                return .stacked(familyIndex: familyIndex, layerIndex: remainingIndex)
            }
            remainingIndex -= plan.positions.count
        }
        return nil
    }
}
