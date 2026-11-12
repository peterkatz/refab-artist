import Foundation

enum CurveSliceMeshExportBuilder {
    static func layers(plan: CurveSlicePlan, model: MeshSummary, materialThickness: Double) -> [SliceMeshExportLayer] {
        let primaryContours = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let curveContours = CurveSliceContourer.generate(model: model, plan: plan)
        let slots = CurveJointPlanner.slots(plan: plan, primary: primaryContours, curve: curveContours)
        let primaryPaths = slots.primaryPaths
        let curvePaths = slots.curvePaths

        let primaryLayers = primaryContours.layers.enumerated().map { layerIndex, layer -> SliceMeshExportLayer in
            let mesh = ViewportSliceSolidRenderData.mesh(
                paths: primaryPaths[layerIndex],
                materialThickness: plan.primary.materialThickness,
                scenePoint: { lift($0, axis: primaryContours.axis, depth: layer.position) },
                normal: axisNormal(primaryContours.axis)
            ) ?? ViewportFlatShadedMesh(vertices: [], normals: [], triangleIndices: [])
            return SliceMeshExportLayer(name: String(format: "first_axis_%03d", layerIndex + 1), mesh: mesh)
        }

        let curveLayers = curveContours.layers.enumerated().map { layerIndex, layer -> SliceMeshExportLayer in
            let mesh = ViewportSliceSolidRenderData.mesh(
                paths: curvePaths[layerIndex],
                materialThickness: materialThickness,
                scenePoint: { CurveSliceContourer.scenePoint($0, center: layer.center, inPlaneDirection: layer.normal) },
                normal: Vec3(x: layer.direction.x, y: layer.direction.y, z: 0)
            ) ?? ViewportFlatShadedMesh(vertices: [], normals: [], triangleIndices: [])
            return SliceMeshExportLayer(name: String(format: "curve_%03d", layerIndex + 1), mesh: mesh)
        }

        return primaryLayers + curveLayers
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
