import Foundation

struct InterlockedSlotGuide: Equatable {
    var familyIndex: Int
    var layerIndex: Int
    var points: [Vec3]
}

enum InterlockedSlotGuideGenerator {
    static func guides(for plan: InterlockedSlicePlan) -> [InterlockedSlotGuide] {
        slotGuides(for: plan.primary, crossing: plan.secondary, bounds: plan.bounds, mode: .primary, width: plan.slotWidth, angleDegrees: plan.normalizedSlotAngleDegrees, familyIndex: 0)
        + slotGuides(for: plan.secondary, crossing: plan.primary, bounds: plan.bounds, mode: .secondary, width: plan.slotWidth, angleDegrees: plan.normalizedSlotAngleDegrees, familyIndex: 1)
    }

    private static func slotGuides(
        for slicedPlan: StackedSlicePlan,
        crossing crossingPlan: StackedSlicePlan,
        bounds: Bounds3D,
        mode: InterlockedSlotCutoutMode,
        width: Double,
        angleDegrees: Double,
        familyIndex: Int
    ) -> [InterlockedSlotGuide] {
        let slotPathsByLayer = InterlockedSlotCutoutGenerator.slotPaths(
            for: slicedPlan,
            crossing: crossingPlan,
            bounds: bounds,
            mode: mode,
            width: width,
            angleDegrees: angleDegrees
        )

        return slotPathsByLayer.enumerated().flatMap { layerIndex, slotPaths in
            let layerPosition = slicedPlan.positions[layerIndex]
            return slotPaths.map { path in
                InterlockedSlotGuide(
                    familyIndex: familyIndex,
                    layerIndex: layerIndex,
                    points: path.points.map { scenePoint($0, axis: slicedPlan.axis, position: layerPosition) }
                )
            }
        }
    }

    private static func scenePoint(_ point: Vec2, axis: SliceAxis, position: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: position, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: position, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: position)
        }
    }

}
