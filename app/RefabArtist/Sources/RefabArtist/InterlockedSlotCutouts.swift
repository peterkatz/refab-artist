import Foundation

enum InterlockedSlotCutoutMode {
    case primary
    case secondary
}

enum InterlockedSlotCutoutGenerator {
    static func slotPaths(
        for slicedPlan: StackedSlicePlan,
        crossing crossingPlan: StackedSlicePlan,
        bounds: Bounds3D,
        mode: InterlockedSlotCutoutMode,
        width: Double,
        angleDegrees: Double
    ) -> [[SlicePath2D]] {
        let projectionAxes = projectedAxes(for: slicedPlan.axis)
        guard projectionAxes.contains(crossingPlan.axis),
              let crossingCoordinateIndex = projectionAxes.firstIndex(of: crossingPlan.axis) else {
            return Array(repeating: [], count: slicedPlan.sliceCount)
        }

        let depthAxis = projectionAxes[1 - crossingCoordinateIndex]
        let depthMin = coordinate(bounds.min, axis: depthAxis)
        let depthMax = coordinate(bounds.max, axis: depthAxis)
        let depthMid = (depthMin + depthMax) / 2
        let halfWidth = width / 2
        let clampedAngle = min(60, max(0, angleDegrees))
        let minDepth = mode == .primary ? depthMid : depthMin
        let maxDepth = mode == .primary ? depthMax : depthMid
        let mouthFlare = (maxDepth - minDepth) * tan(clampedAngle * .pi / 180)
        let mouthAtMaxDepth = mode == .primary

        return slicedPlan.positions.map { _ in
            crossingPlan.positions.map { crossingPosition in
                slotPath(
                    crossingPosition: crossingPosition,
                    halfWidth: halfWidth,
                    mouthFlare: mouthFlare,
                    minDepth: minDepth,
                    maxDepth: maxDepth,
                    crossingCoordinateIndex: crossingCoordinateIndex,
                    mouthAtMaxDepth: mouthAtMaxDepth
                )
            }
        }
    }

    private static func slotPath(
        crossingPosition: Double,
        halfWidth: Double,
        mouthFlare: Double,
        minDepth: Double,
        maxDepth: Double,
        crossingCoordinateIndex: Int,
        mouthAtMaxDepth: Bool
    ) -> SlicePath2D {
        if mouthFlare == 0 {
            if crossingCoordinateIndex == 0 {
                return rectanglePath(
                    minX: crossingPosition - halfWidth,
                    maxX: crossingPosition + halfWidth,
                    minY: minDepth,
                    maxY: maxDepth
                )
            }
            return rectanglePath(
                minX: minDepth,
                maxX: maxDepth,
                minY: crossingPosition - halfWidth,
                maxY: crossingPosition + halfWidth
            )
        }

        if crossingCoordinateIndex == 0 {
            let innerLeft = crossingPosition - halfWidth
            let innerRight = crossingPosition + halfWidth
            let mouthLeft = crossingPosition - halfWidth - mouthFlare
            let mouthRight = crossingPosition + halfWidth + mouthFlare
            if mouthAtMaxDepth {
                return closedPath([
                    Vec2(x: innerLeft, y: minDepth),
                    Vec2(x: innerRight, y: minDepth),
                    Vec2(x: mouthRight, y: maxDepth),
                    Vec2(x: mouthLeft, y: maxDepth)
                ])
            }
            return closedPath([
                Vec2(x: mouthLeft, y: minDepth),
                Vec2(x: mouthRight, y: minDepth),
                Vec2(x: innerRight, y: maxDepth),
                Vec2(x: innerLeft, y: maxDepth)
            ])
        }

        let innerLow = crossingPosition - halfWidth
        let innerHigh = crossingPosition + halfWidth
        let mouthLow = crossingPosition - halfWidth - mouthFlare
        let mouthHigh = crossingPosition + halfWidth + mouthFlare
        if mouthAtMaxDepth {
            return closedPath([
                Vec2(x: minDepth, y: innerLow),
                Vec2(x: maxDepth, y: mouthLow),
                Vec2(x: maxDepth, y: mouthHigh),
                Vec2(x: minDepth, y: innerHigh)
            ])
        }
        return closedPath([
            Vec2(x: minDepth, y: mouthLow),
            Vec2(x: maxDepth, y: innerLow),
            Vec2(x: maxDepth, y: innerHigh),
            Vec2(x: minDepth, y: mouthHigh)
        ])
    }

    private static func rectanglePath(minX: Double, maxX: Double, minY: Double, maxY: Double) -> SlicePath2D {
        closedPath([
            Vec2(x: minX, y: minY),
            Vec2(x: maxX, y: minY),
            Vec2(x: maxX, y: maxY),
            Vec2(x: minX, y: maxY)
        ])
    }

    private static func closedPath(_ points: [Vec2]) -> SlicePath2D {
        guard let first = points.first else {
            return SlicePath2D(points: [], closed: false)
        }
        return SlicePath2D(points: points + [first], closed: true)
    }

    private static func projectedAxes(for axis: SliceAxis) -> [SliceAxis] {
        switch axis {
        case .x:
            return [.y, .z]
        case .y:
            return [.x, .z]
        case .z:
            return [.x, .y]
        }
    }

    private static func coordinate(_ point: Vec3, axis: SliceAxis) -> Double {
        switch axis {
        case .x:
            return point.x
        case .y:
            return point.y
        case .z:
            return point.z
        }
    }
}
