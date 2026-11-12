import Foundation

enum StlExporter {
    struct ContourSet {
        var contours: StackedSliceContours
        var materialThickness: Double
    }

    static func write(
        contours: StackedSliceContours,
        materialThickness: Double,
        to url: URL
    ) throws {
        try write(
            sets: [ContourSet(contours: contours, materialThickness: materialThickness)],
            to: url,
            solidName: "refabartist_stacked_slices"
        )
    }

    static func write(threeD plan: ThreeDSlicePlan, model: MeshSummary, to url: URL) throws {
        let meshLayers = ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)
        if !meshLayers.isEmpty {
            try write(
                meshes: meshLayers.map(\.mesh),
                to: url,
                solidName: "refabartist_3d_slices"
            )
            return
        }
        try write(
            sets: [
                ContourSet(contours: StackedSliceContourer.generate(model: model, plan: plan.x), materialThickness: plan.x.materialThickness),
                ContourSet(contours: StackedSliceContourer.generate(model: model, plan: plan.y), materialThickness: plan.y.materialThickness),
                ContourSet(contours: StackedSliceContourer.generate(model: model, plan: plan.z), materialThickness: plan.z.materialThickness)
            ],
            to: url,
            solidName: "refabartist_3d_slices"
        )
    }

    static func write(interlocked plan: InterlockedSlicePlan, model: MeshSummary, to url: URL) throws {
        try write(
            meshes: InterlockedSliceMeshExportBuilder.layers(plan: plan, model: model).map(\.mesh),
            to: url,
            solidName: "refabartist_interlocked_slices"
        )
    }

    static func write(radial plan: RadialSlicePlan, model: MeshSummary, materialThickness: Double, to url: URL) throws {
        let meshLayers = RadialSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: materialThickness)
        if !meshLayers.isEmpty {
            try write(
                meshes: meshLayers.map(\.mesh),
                to: url,
                solidName: "refabartist_radial_slices"
            )
            return
        }
        let contours = RadialSliceContourer.generate(model: model, plan: plan)
        try write(
            layers: contours.layers.map { layer in
                ExtrudedLayer(
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
            solidName: "refabartist_radial_slices"
        )
    }

    static func write(curve plan: CurveSlicePlan, model: MeshSummary, materialThickness: Double, to url: URL) throws {
        let meshLayers = CurveSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: materialThickness)
        if !meshLayers.isEmpty {
            try write(
                meshes: meshLayers.map(\.mesh),
                to: url,
                solidName: "refabartist_curve_slices"
            )
            return
        }
        let primaryContours = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let contours = CurveSliceContourer.generate(model: model, plan: plan)
        let primaryLayers = primaryContours.layers.map { layer in
            ExtrudedLayer(
                paths: layer.paths,
                materialThickness: plan.primary.materialThickness,
                scenePoint: { point in
                    lift(point, axis: primaryContours.axis, depth: layer.position)
                },
                normal: axisNormal(primaryContours.axis)
            )
        }
        let curveLayers = contours.layers.map { layer in
            ExtrudedLayer(
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
            solidName: "refabartist_curve_slices"
        )
    }

    static func write(folded plan: FoldedPanelPlan, materialThickness: Double, to url: URL) throws {
        let layout = FoldedPanelPreviewLayouter.layout(plan: plan)
        try write(
            layers: layout.paths.map { panel in
                ExtrudedLayer(
                    paths: [SlicePath2D(points: panel.points, closed: true)],
                    materialThickness: materialThickness,
                    scenePoint: { point in Vec3(x: point.x, y: point.y, z: 0) },
                    normal: Vec3(x: 0, y: 0, z: 1)
                )
            },
            to: url,
            solidName: "refabartist_folded_panels"
        )
    }

    static func write(sets: [ContourSet], to url: URL, solidName: String = "refabartist_slices") throws {
        let layers = sets.flatMap { set in
            set.contours.layers.map { layer in
                ExtrudedLayer(
                    paths: layer.paths,
                    materialThickness: set.materialThickness,
                    scenePoint: { point in lift(point, axis: set.contours.axis, depth: layer.position) },
                    normal: axisNormal(set.contours.axis)
                )
            }
        }
        try write(layers: layers, to: url, solidName: solidName)
    }

    private struct ExtrudedLayer {
        var paths: [SlicePath2D]
        var materialThickness: Double
        var scenePoint: (Vec2) -> Vec3
        var normal: Vec3
    }

    private static func write(layers: [ExtrudedLayer], to url: URL, solidName: String) throws {
        var output = ""
        output += "solid \(solidName)\n"

        for layer in layers {
            let closedPaths = layer.paths.compactMap { normalizedClosedPath($0) }
            guard !closedPaths.isEmpty else {
                continue
            }

            for path in closedPaths {
                let halfThickness = layer.materialThickness / 2
                let lowerVertices = path.map { offset(layer.scenePoint($0), along: layer.normal, distance: -halfThickness) }
                let upperVertices = path.map { offset(layer.scenePoint($0), along: layer.normal, distance: halfThickness) }

                writeCap(vertices: lowerVertices.reversed(), into: &output)
                writeCap(vertices: upperVertices, into: &output)
                writeSides(lower: lowerVertices, upper: upperVertices, into: &output)
            }
        }

        output += "endsolid \(solidName)\n"
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(meshes: [ViewportFlatShadedMesh], to url: URL, solidName: String) throws {
        var output = ""
        output += "solid \(solidName)\n"

        for mesh in meshes {
            for triangleStart in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
                guard let a = vertex(mesh.triangleIndices[triangleStart], in: mesh),
                      let b = vertex(mesh.triangleIndices[triangleStart + 1], in: mesh),
                      let c = vertex(mesh.triangleIndices[triangleStart + 2], in: mesh) else {
                    continue
                }
                writeFacet(a, b, c, into: &output)
            }
        }

        output += "endsolid \(solidName)\n"
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeCap(vertices: ReversedCollection<[Vec3]>, into output: inout String) {
        writeCap(vertices: Array(vertices), into: &output)
    }

    private static func writeCap(vertices: [Vec3], into output: inout String) {
        guard vertices.count >= 3 else {
            return
        }
        for index in 1..<(vertices.count - 1) {
            writeFacet(vertices[0], vertices[index], vertices[index + 1], into: &output)
        }
    }

    private static func writeSides(lower: [Vec3], upper: [Vec3], into output: inout String) {
        guard lower.count == upper.count, lower.count >= 3 else {
            return
        }
        for index in 0..<lower.count {
            let next = (index + 1) % lower.count
            writeFacet(lower[index], lower[next], upper[next], into: &output)
            writeFacet(lower[index], upper[next], upper[index], into: &output)
        }
    }

    private static func writeFacet(_ a: Vec3, _ b: Vec3, _ c: Vec3, into output: inout String) {
        let normal = normalized(cross(subtract(b, a), subtract(c, a)))
        output += "  facet normal \(format(normal.x)) \(format(normal.y)) \(format(normal.z))\n"
        output += "    outer loop\n"
        output += "      vertex \(format(a.x)) \(format(a.y)) \(format(a.z))\n"
        output += "      vertex \(format(b.x)) \(format(b.y)) \(format(b.z))\n"
        output += "      vertex \(format(c.x)) \(format(c.y)) \(format(c.z))\n"
        output += "    endloop\n"
        output += "  endfacet\n"
    }

    private static func normalized(_ vector: Vec3) -> Vec3 {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard length > 0 else {
            return Vec3(x: 0, y: 0, z: 0)
        }
        return Vec3(x: vector.x / length, y: vector.y / length, z: vector.z / length)
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
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

    private static func vertex(_ index: Int32, in mesh: ViewportFlatShadedMesh) -> Vec3? {
        guard index >= 0, Int(index) < mesh.vertices.count else {
            return nil
        }
        return mesh.vertices[Int(index)]
    }

    private static func samePoint(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
        abs(lhs.x - rhs.x) <= 1.0e-7 && abs(lhs.y - rhs.y) <= 1.0e-7
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
