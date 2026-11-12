import Foundation

struct AssemblyGuideContext: Equatable {
    var modelName: String
    var constructionMode: ConstructionMode
    var materialThickness: Double
    var slotClearance: Double
    /// The notch width that replaces thickness + slot clearance as the slot
    /// width, when it is on (Interlocked, Curve); nil otherwise.
    var notchWidth: Double? = nil
    var slotAngleDegrees: Double
    /// The relief cut at the inside corners of the slots, worded for the
    /// guide ("Dog Bone, 3 mm tool"); nil when none is cut.
    var relief: String? = nil
    var dowelsEnabled: Bool
    var dowelDiameter: Double
    var dowelInset: Double
    /// Folded: the Joint Type. Laced, Ticked and None cut no slot, so the
    /// guide leaves the slot clearance out for them; nil prints it.
    var foldedJoint: JoineryType? = nil
    /// 3D Slices: the slice depth its bands are spaced by, or the even layer
    /// count (Distribute count) that overrides it. The layered mesh has no
    /// stock, so the guide prints these in place of the material thickness.
    var threeDSliceDepth: Double? = nil
    var threeDLayerCount: Int? = nil
}

enum AssemblyGuideExporter {
    static func document(context: AssemblyGuideContext, steps: [AssemblyStep]) -> String {
        var lines: [String] = [
            "Refab Artist Assembly Guide",
            "",
            "Model: \(context.modelName)",
            "Mode: \(context.constructionMode.label)"
        ]
        lines += stockLines(context: context)
        lines += settingLines(context: context)

        lines.append("Step count: \(steps.count)")
        lines.append("")

        if steps.isEmpty {
            lines.append("No assembly steps available.")
        } else {
            lines.append("Steps")
            lines.append("")
            // Numbered in build order; a step's index may skip a slice that
            // is not exported (`AssemblyStepPlanner.exported`).
            for (number, step) in steps.enumerated() {
                lines.append("\(number + 1). \(step.title)")
                lines.append("   \(step.detail)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The material thickness, or for 3D Slices, whose layered mesh has no
    /// stock, the slice depth (or Distribute count) its bands are cut by.
    static func stockLines(context: AssemblyGuideContext) -> [String] {
        guard context.constructionMode == .threeD else {
            return ["Material thickness: \(Vec3.format(context.materialThickness)) mm"]
        }
        if let count = context.threeDLayerCount {
            return ["Distribute count: \(count) layers"]
        }
        if let depth = context.threeDSliceDepth {
            return ["Slice depth: \(Vec3.format(depth)) mm"]
        }
        return []
    }

    /// The settings the mode actually cuts with, after the material
    /// thickness. Only Interlocked has a slot angle; only Stacked has dowels.
    static func settingLines(context: AssemblyGuideContext) -> [String] {
        var lines: [String] = []
        let slotLine: String
        if let notchWidth = context.notchWidth {
            slotLine = "Notch width: \(Vec3.format(notchWidth)) mm"
        } else {
            slotLine = "Slot clearance: \(Vec3.format(context.slotClearance)) mm"
        }
        switch context.constructionMode {
        case .stacked:
            if context.dowelsEnabled {
                lines.append("Dowels: \(Vec3.format(context.dowelDiameter)) mm diameter, \(Vec3.format(context.dowelInset)) mm inset")
            } else {
                lines.append("Dowels: disabled")
            }
        case .interlocked:
            lines.append(slotLine)
            lines.append("Slot angle: \(Vec3.format(context.slotAngleDegrees)) degrees")
        case .curve:
            lines.append(slotLine)
        case .radial:
            // No notch-width override: the slots are the stock plus the
            // clearance.
            lines.append("Slot clearance: \(Vec3.format(context.slotClearance)) mm")
        case .foldedPanels:
            // No notch-width override; Laced, Ticked and None cut no slot.
            if context.foldedJoint.map(FoldedJoineryGeometry.readsSlotClearance) ?? true {
                lines.append("Slot clearance: \(Vec3.format(context.slotClearance)) mm")
            }
        case .threeD, .inflatables, .structures, .partition, .motherMold:
            break
        }
        if let relief = context.relief {
            lines.append("Slot relief: \(relief)")
        }
        return lines
    }

    static func write(context: AssemblyGuideContext, steps: [AssemblyStep], to url: URL) throws {
        try document(context: context, steps: steps).write(to: url, atomically: true, encoding: .utf8)
    }
}
