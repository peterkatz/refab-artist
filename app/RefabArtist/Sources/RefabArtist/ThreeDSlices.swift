import Foundation

struct ThreeDSlicePlan: Equatable {
    var x: StackedSlicePlan
    var y: StackedSlicePlan
    var z: StackedSlicePlan
    var slotWidth: Double
    var slotAngleDegrees: Double

    init(x: StackedSlicePlan, y: StackedSlicePlan, z: StackedSlicePlan, slotWidth: Double? = nil, slotAngleDegrees: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.slotWidth = max(0.1, slotWidth ?? x.materialThickness)
        self.slotAngleDegrees = min(60, max(0, slotAngleDegrees))
    }

    var plans: [StackedSlicePlan] {
        [x, y, z]
    }

    var sliceCount: Int {
        x.sliceCount + y.sliceCount + z.sliceCount
    }
}

enum ThreeDSlicePlanner {
    private static let minimumSlotWidth = 0.1

    static func plan(
        model: MeshSummary,
        materialThickness: Double,
        slotClearance: Double = 0,
        notchWidthOverride: Double? = nil,
        slotAngleDegrees: Double = 0,
        sliceDepth: Double? = nil,
        sliceCountOverride: Int? = nil
    ) -> ThreeDSlicePlan? {
        guard let x = StackedSlicePlanner.plan(model: model, axis: .x, materialThickness: materialThickness, sliceDepth: sliceDepth, sliceCountOverride: sliceCountOverride),
              let y = StackedSlicePlanner.plan(model: model, axis: .y, materialThickness: materialThickness, sliceDepth: sliceDepth, sliceCountOverride: sliceCountOverride),
              let z = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: materialThickness, sliceDepth: sliceDepth, sliceCountOverride: sliceCountOverride) else {
            return nil
        }
        return ThreeDSlicePlan(
            x: x,
            y: y,
            z: z,
            slotWidth: max(minimumSlotWidth, notchWidthOverride ?? materialThickness + slotClearance),
            slotAngleDegrees: min(60, max(0, slotAngleDegrees))
        )
    }
}
