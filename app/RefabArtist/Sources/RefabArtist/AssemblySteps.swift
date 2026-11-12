import Foundation

struct AssemblyStep: Identifiable, Equatable {
    var index: Int
    var title: String
    var detail: String

    var id: Int { index }
}

enum AssemblyStepPlanner {
    static func steps(stacked plan: StackedSlicePlan) -> [AssemblyStep] {
        plan.positions.enumerated().map { offset, position in
            AssemblyStep(
                index: offset + 1,
                title: "Place slice_\(labelNumber(offset))",
                detail: "Stack along \(plan.axis.label) at \(Vec3.format(position)) mm."
            )
        }
    }

    static func steps(interlocked plan: InterlockedSlicePlan) -> [AssemblyStep] {
        var steps: [AssemblyStep] = []
        let slotDetail = "\(plan.slotCount) slots, \(Vec3.format(plan.slotWidth)) mm slot width, \(Vec3.format(plan.normalizedSlotAngleDegrees)) degree angle"
        for (offset, position) in plan.primary.positions.enumerated() {
            steps.append(
                AssemblyStep(
                    index: steps.count + 1,
                    title: "Place primary_\(labelNumber(offset))",
                    detail: "\(plan.primary.axis.label) family at \(Vec3.format(position)) mm; \(slotDetail)."
                )
            )
        }
        for (offset, position) in plan.secondary.positions.enumerated() {
            steps.append(
                AssemblyStep(
                    index: steps.count + 1,
                    title: "Insert secondary_\(labelNumber(offset))",
                    detail: "\(plan.secondary.axis.label) family at \(Vec3.format(position)) mm; mesh through matching primary slots."
                )
            )
        }
        return steps
    }

    static func steps(radial plan: RadialSlicePlan) -> [AssemblyStep] {
        // n_radial == 0 degrades to Interlocked.
        if plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return steps(interlocked: fallback)
        }
        // Disks first, then the fins keyed into them — the build order.
        var steps: [AssemblyStep] = []
        if let primary = plan.primary {
            for (offset, position) in primary.positions.enumerated() {
                steps.append(
                    AssemblyStep(
                        index: steps.count + 1,
                        title: "Place first_axis_\(labelNumber(offset))",
                        detail: "\(primary.axis.label) ring at \(Vec3.format(position)) mm; receives the radial fin notches."
                    )
                )
            }
        }
        let angles = plan.nRadial > 0 ? RadialPartBuilder.wedgeAngles(plan: plan) : plan.angles
        for (offset, angle) in angles.enumerated() {
            steps.append(
                AssemblyStep(
                    index: steps.count + 1,
                    title: "Insert radial_\(labelNumber(offset))",
                    detail: "Radial fin at \(Vec3.format(angle * 180 / .pi)) degrees around the hub axis."
                )
            )
        }
        return steps
    }

    static func steps(curve plan: CurveSlicePlan) -> [AssemblyStep] {
        let firstAxisSteps = plan.primary.positions.enumerated().map { offset, position in
            AssemblyStep(
                index: offset + 1,
                title: "Place first_axis_\(labelNumber(offset))",
                detail: "\(plan.primary.axis.label) family at \(Vec3.format(position)) mm; receives curve-rib slots."
            )
        }
        let curveSteps = plan.centers.enumerated().map { offset, center in
            AssemblyStep(
                index: firstAxisSteps.count + offset + 1,
                title: "Insert curve_\(labelNumber(offset))",
                detail: "Curve rib through \(center.display); mesh into first-axis slots along \(plan.controlPoints.count)-point spline."
            )
        }
        return firstAxisSteps + curveSteps
    }

    /// One step per band of the layered mesh 3D Slices builds
    /// (`three_d_NNN`, bottom up): only the Z family's slices are built, so
    /// the X and Y families have no steps. Each step keeps the index it has
    /// counted through the X, Y and Z families, which is how the viewport
    /// finds its band (`AssemblyStepHighlighter`).
    static func steps(threeD plan: ThreeDSlicePlan) -> [AssemblyStep] {
        let startIndex = plan.x.sliceCount + plan.y.sliceCount + 1
        return plan.z.positions.enumerated().map { offset, position in
            AssemblyStep(
                index: startIndex + offset,
                title: "Place three_d_\(labelNumber(offset))",
                detail: "\(plan.z.axis.label) band at \(Vec3.format(position)) mm."
            )
        }
    }

    /// `steps` less those with no part in `stepIndices`, the steps of the
    /// parts a cut sheet holds (`CutSheetPart.stepIndex`; `stepIndices(in:)`):
    /// a slice left out whole (a Curve rib no slice of the other family
    /// crosses, a Radial ring no fin reaches, a slice through nothing) is
    /// not exported, so it gets no step. The steps keep their indices, so
    /// every part on the sheet keeps its step. With no cut sheet (nil) the
    /// steps are kept as they are.
    static func exported(_ steps: [AssemblyStep], stepIndices: Set<Int>?) -> [AssemblyStep] {
        guard let stepIndices else { return steps }
        return steps.filter { stepIndices.contains($0.index) }
    }

    /// The steps the parts of `document` belong to, for the modes whose
    /// cut-sheet parts are numbered by step: Stacked, Interlocked, Radial
    /// and Curve Slices (nil for the others, whose parts are not).
    static func stepIndices(in document: CutSheetDocument, mode: ConstructionMode) -> Set<Int>? {
        switch mode {
        case .stacked, .interlocked, .radial, .curve:
            return Set(document.sheets.flatMap(\.parts).compactMap(\.stepIndex))
        case .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        }
    }

    /// One step per panel, less the panels the stock leaves out
    /// (`FoldedPanelPlan.leftOutPanels`): no net holds them. The steps keep
    /// their indices (panel index + 1), so each still finds its panel.
    static func steps(folded plan: FoldedPanelPlan) -> [AssemblyStep] {
        let leftOut = Set(plan.leftOutPanels)
        return plan.panels.enumerated().compactMap { offset, panel in
            guard !leftOut.contains(offset) else { return nil }
            return AssemblyStep(
                index: offset + 1,
                title: "Fold folded_panel_\(labelNumber(offset))",
                detail: "Panel from source triangle \(panel.sourceTriangleIndex + 1); align shared edges before joining."
            )
        }
    }

    private static func labelNumber(_ zeroBasedIndex: Int) -> String {
        String(format: "%03d", zeroBasedIndex + 1)
    }
}
