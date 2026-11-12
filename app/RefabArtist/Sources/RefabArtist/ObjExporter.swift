import Foundation

enum ObjExporter {
    struct ContourSet {
        var prefix: String
        var contours: StackedSliceContours
        var materialThickness: Double
    }

    static func write(
        contours: StackedSliceContours,
        materialThickness: Double,
        to url: URL
    ) throws {
        try write(
            sets: [ContourSet(prefix: "slice", contours: contours, materialThickness: materialThickness)],
            to: url,
            title: "stacked slice"
        )
    }

    static func write(threeD plan: ThreeDSlicePlan, model: MeshSummary, to url: URL) throws {
        let meshLayers = ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)
        if !meshLayers.isEmpty {
            try write(meshLayers: meshLayers, to: url, title: "3D slice")
            return
        }
        try write(
            sets: [
                ContourSet(prefix: "three_d_x", contours: StackedSliceContourer.generate(model: model, plan: plan.x), materialThickness: plan.x.materialThickness),
                ContourSet(prefix: "three_d_y", contours: StackedSliceContourer.generate(model: model, plan: plan.y), materialThickness: plan.y.materialThickness),
                ContourSet(prefix: "three_d_z", contours: StackedSliceContourer.generate(model: model, plan: plan.z), materialThickness: plan.z.materialThickness)
            ],
            to: url,
            title: "3D slice"
        )
    }

    static func write(interlocked plan: InterlockedSlicePlan, model: MeshSummary, to url: URL) throws {
        try write(meshLayers: InterlockedSliceMeshExportBuilder.layers(plan: plan, model: model), to: url, title: "interlocked slice")
    }

    static func write(radial plan: RadialSlicePlan, model: MeshSummary, materialThickness: Double, to url: URL) throws {
        let meshLayers = RadialSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: materialThickness)
        if !meshLayers.isEmpty {
            try write(meshLayers: meshLayers, to: url, title: "radial slice")
            return
        }
        let contours = RadialSliceContourer.generate(model: model, plan: plan)
        try write(
            layers: contours.layers.enumerated().map { layerIndex, layer in
                ExtrudedLayer(
                    name: String(format: "radial_%03d", layerIndex + 1),
                    paths: layer.paths,
                    materialThickness: materialThickness,
                    scenePoint: { point in
                        RadialSliceContourer.scenePoint(point, center: contours.center, angle: layer.angle)
                    },
                    normal: {
                        let direction = Vec2(x: cos(layer.angle), y: sin(layer.angle))
                        return Vec3(x: -direction.y, y: direction.x, z: 0)
                    }()
                )
            },
            to: url,
            title: "radial slice"
        )
    }

    static func write(curve plan: CurveSlicePlan, model: MeshSummary, materialThickness: Double, to url: URL) throws {
        let meshLayers = CurveSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: materialThickness)
        if !meshLayers.isEmpty {
            try write(meshLayers: meshLayers, to: url, title: "curve slice")
            return
        }
        let primaryContours = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let contours = CurveSliceContourer.generate(model: model, plan: plan)
        let primaryLayers = primaryContours.layers.enumerated().map { layerIndex, layer in
            ExtrudedLayer(
                name: String(format: "first_axis_%03d", layerIndex + 1),
                paths: layer.paths,
                materialThickness: plan.primary.materialThickness,
                scenePoint: { point in
                    lift(point, axis: primaryContours.axis, depth: layer.position)
                },
                normal: axisNormal(primaryContours.axis)
            )
        }
        let curveLayers = contours.layers.enumerated().map { layerIndex, layer in
            ExtrudedLayer(
                name: String(format: "curve_%03d", layerIndex + 1),
                paths: layer.paths,
                materialThickness: materialThickness,
                scenePoint: { point in
                    CurveSliceContourer.scenePoint(point, center: layer.center, inPlaneDirection: layer.normal)
                },
                normal: Vec3(x: layer.direction.x, y: layer.direction.y, z: 0)
            )
        }
        try write(
            layers: primaryLayers + curveLayers,
            to: url,
            title: "curve slice"
        )
    }

    static func write(folded plan: FoldedPanelPlan, materialThickness: Double, to url: URL) throws {
        let layout = FoldedPanelPreviewLayouter.layout(plan: plan)
        try write(
            layers: layout.paths.enumerated().map { panelIndex, panel in
                ExtrudedLayer(
                    name: String(format: "folded_panel_%03d", panelIndex + 1),
                    paths: [SlicePath2D(points: panel.points, closed: true)],
                    materialThickness: materialThickness,
                    scenePoint: { point in Vec3(x: point.x, y: point.y, z: 0) },
                    normal: Vec3(x: 0, y: 0, z: 1)
                )
            },
            to: url,
            title: "folded panel"
        )
    }

    static func write(sets: [ContourSet], to url: URL, title: String = "slice") throws {
        let layers = sets.flatMap { set in
            set.contours.layers.enumerated().map { layerIndex, layer in
                ExtrudedLayer(
                    name: String(format: "\(set.prefix)_%03d", layerIndex + 1),
                    paths: layer.paths,
                    materialThickness: set.materialThickness,
                    scenePoint: { point in lift(point, axis: set.contours.axis, depth: layer.position) },
                    normal: axisNormal(set.contours.axis)
                )
            }
        }
        try write(layers: layers, to: url, title: title)
    }

    private struct ExtrudedLayer {
        var name: String
        var paths: [SlicePath2D]
        var materialThickness: Double
        var scenePoint: (Vec2) -> Vec3
        var normal: Vec3
    }

    private static func write(layers: [ExtrudedLayer], to url: URL, title: String = "slice") throws {
        var output = ""
        output += "# Refab Artist \(title) mesh export\n"
        output += "# Units: millimeters\n"

        var vertexOffset = 1
        for layer in layers {
            output += "o \(layer.name)\n"
            output += "g \(layer.name)\n"

            let closedPaths = layer.paths.compactMap { normalizedClosedPath($0) }
            guard !closedPaths.isEmpty else {
                continue
            }

            for path in closedPaths {
                let halfThickness = layer.materialThickness / 2
                let lowerVertices = path.map { offset(layer.scenePoint($0), along: layer.normal, distance: -halfThickness) }
                let upperVertices = path.map { offset(layer.scenePoint($0), along: layer.normal, distance: halfThickness) }

                for vertex in lowerVertices + upperVertices {
                    output += "v \(format(vertex.x)) \(format(vertex.y)) \(format(vertex.z))\n"
                }

                let count = path.count
                let lowerIndices = (0..<count).map { vertexOffset + $0 }
                let upperIndices = (0..<count).map { vertexOffset + count + $0 }
                output += "f \(lowerIndices.reversed().map(String.init).joined(separator: " "))\n"
                output += "f \(upperIndices.map(String.init).joined(separator: " "))\n"
                for index in 0..<count {
                    let next = (index + 1) % count
                    output += "f \(lowerIndices[index]) \(lowerIndices[next]) \(upperIndices[next]) \(upperIndices[index])\n"
                }

                vertexOffset += count * 2
            }
        }

        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(meshLayers: [SliceMeshExportLayer], to url: URL, title: String = "slice") throws {
        var output = ""
        output += "# Refab Artist \(title) mesh export\n"
        output += "# Units: millimeters\n"

        var vertexOffset = 1
        for layer in meshLayers {
            output += "o \(layer.name)\n"
            output += "g \(layer.name)\n"
            let mesh = layer.mesh

            for vertex in mesh.vertices {
                output += "v \(format(vertex.x)) \(format(vertex.y)) \(format(vertex.z))\n"
            }
            for triangleStart in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
                let indices = [
                    vertexOffset + Int(mesh.triangleIndices[triangleStart]),
                    vertexOffset + Int(mesh.triangleIndices[triangleStart + 1]),
                    vertexOffset + Int(mesh.triangleIndices[triangleStart + 2])
                ]
                output += "f \(indices.map(String.init).joined(separator: " "))\n"
            }
            vertexOffset += mesh.vertices.count
        }

        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func normalizedClosedPath(_ path: SlicePath2D) -> [Vec2]? {
        guard path.closed, path.points.count >= 4 else {
            return nil
        }
        var points = path.points
        if let first = points.first,
           let last = points.last,
           samePoint(first, last) {
            points.removeLast()
        }
        guard points.count >= 3 else {
            return nil
        }
        return points
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

    private static func offset(_ point: Vec3, along normal: Vec3, distance: Double) -> Vec3 {
        Vec3(
            x: point.x + normal.x * distance,
            y: point.y + normal.y * distance,
            z: point.z + normal.z * distance
        )
    }

    private static func samePoint(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
        abs(lhs.x - rhs.x) <= 1.0e-7 && abs(lhs.y - rhs.y) <= 1.0e-7
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
