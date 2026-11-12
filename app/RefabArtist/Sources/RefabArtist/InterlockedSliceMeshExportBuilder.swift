import Foundation

enum InterlockedSliceMeshExportBuilder {
    static func layers(plan: InterlockedSlicePlan, model: MeshSummary) -> [SliceMeshExportLayer] {
        let primaryContours = StackedSliceContourer.generate(model: model, plan: plan.primary)
        let secondaryContours = StackedSliceContourer.generate(model: model, plan: plan.secondary)
        let primarySlots = InterlockedSlotCutoutGenerator.slotPaths(
            for: plan.primary,
            crossing: plan.secondary,
            bounds: plan.bounds,
            mode: .primary,
            width: plan.slotWidth,
            angleDegrees: plan.normalizedSlotAngleDegrees
        )
        let secondarySlots = InterlockedSlotCutoutGenerator.slotPaths(
            for: plan.secondary,
            crossing: plan.primary,
            bounds: plan.bounds,
            mode: .secondary,
            width: plan.slotWidth,
            angleDegrees: plan.normalizedSlotAngleDegrees
        )

        return familyLayers(prefix: "primary", contours: primaryContours, slots: primarySlots, materialThickness: plan.materialThickness)
        + familyLayers(prefix: "secondary", contours: secondaryContours, slots: secondarySlots, materialThickness: plan.materialThickness)
    }

    private static func familyLayers(
        prefix: String,
        contours: StackedSliceContours,
        slots: [[SlicePath2D]],
        materialThickness: Double
    ) -> [SliceMeshExportLayer] {
        contours.layers.enumerated().map { layerIndex, layer in
            let mesh = ViewportSliceSolidRenderData.meshWithRectangularCutouts(
                outerPaths: layer.paths,
                cutoutPaths: slots.indices.contains(layerIndex) ? slots[layerIndex] : [],
                materialThickness: materialThickness,
                scenePoint: { lift($0, axis: contours.axis, depth: layer.position) },
                normal: axisNormal(contours.axis)
            ) ?? ViewportFlatShadedMesh(vertices: [], normals: [], triangleIndices: [])
            return SliceMeshExportLayer(name: String(format: "\(prefix)_%03d", layerIndex + 1), mesh: mesh)
        }
    }

    private static func lift(_ point: Vec2, axis: SliceAxis, depth: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: depth, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: depth, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: depth)
        }
    }

    private static func axisNormal(_ axis: SliceAxis) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: 1, y: 0, z: 0)
        case .y:
            return Vec3(x: 0, y: 1, z: 0)
        case .z:
            return Vec3(x: 0, y: 0, z: 1)
        }
    }
}
