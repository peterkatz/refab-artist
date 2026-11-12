import Foundation

enum RadialSliceMeshExportBuilder {
    static func layers(plan: RadialSlicePlan, model: MeshSummary, materialThickness: Double) -> [SliceMeshExportLayer] {
        // n_radial == 0 degrades to Interlocked.
        if plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return InterlockedSliceMeshExportBuilder.layers(plan: fallback, model: model)
        }
        guard let primary = plan.primary, let bounds = model.bounds else { return [] }
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )

        // Rings + fins from the shared disk+wedge generator — the same part
        // geometry as the cut sheet and the vector exports, extruded in place.
        var layers: [SliceMeshExportLayer] = []
        let parts = RadialPartBuilder.assembly(plan: plan, model: model)
        for disk in parts.disks {
            let mesh = ViewportSliceSolidRenderData.mesh(
                paths: disk.paths,
                materialThickness: materialThickness,
                scenePoint: { lift($0, axis: primary.axis, depth: disk.position) },
                normal: axisNormal(primary.axis)
            ) ?? ViewportFlatShadedMesh(vertices: [], normals: [], triangleIndices: [])
            let name = disk.componentIndex == 0
                ? String(format: "first_axis_%03d", disk.sliceIndex + 1)
                : String(format: "first_axis_%03d_%02d", disk.sliceIndex + 1, disk.componentIndex + 1)
            layers.append(SliceMeshExportLayer(
                name: name,
                mesh: mesh
            ))
        }
        for wedge in parts.wedges {
            let mesh = ViewportSliceSolidRenderData.mesh(
                paths: wedge.paths,
                materialThickness: materialThickness,
                scenePoint: { RadialPartBuilder.wedgeScenePoint($0, center: center, axis: primary.axis, angle: wedge.position) },
                normal: RadialPartBuilder.wedgePlaneNormal(axis: primary.axis, angle: wedge.position)
            ) ?? ViewportFlatShadedMesh(vertices: [], normals: [], triangleIndices: [])
            let name = wedge.componentIndex == 0
                ? String(format: "radial_%03d", wedge.sliceIndex + 1)
                : String(format: "radial_%03d_%02d", wedge.sliceIndex + 1, wedge.componentIndex + 1)
            layers.append(SliceMeshExportLayer(
                name: name,
                mesh: mesh
            ))
        }
        return layers
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
