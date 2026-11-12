import Foundation
import Testing
@testable import RefabArtist

struct ObjExporterTests {
    @Test
    func stackedObjExportWritesSliceSlabMesh() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(
            contours: Self.squareContours(position: 10),
            materialThickness: 4,
            to: url
        )

        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(obj.hasPrefix("# Refab Artist stacked slice mesh export\n"))
        #expect(obj.contains("o slice_001\n"))
        #expect(obj.contains("g slice_001\n"))
        #expect(obj.components(separatedBy: "\nv ").count - 1 == 8)
        #expect(obj.components(separatedBy: "\nf ").count - 1 == 6)
        #expect(obj.contains("v 0.000000 0.000000 8.000000\n"))
        #expect(obj.contains("v 0.000000 0.000000 12.000000\n"))
    }

    @Test
    func cubeFixtureObjExportContainsOneMeshObjectPerSlice() throws {
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3)!
        let contours = StackedSliceContourer.generate(model: model, plan: plan)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-cube-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(contours: contours, materialThickness: plan.materialThickness, to: url)

        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(plan.sliceCount == 16)
        #expect(obj.components(separatedBy: "\no slice_").count - 1 == 16)
        #expect(obj.components(separatedBy: "\nv ").count - 1 == 128)
        #expect(obj.components(separatedBy: "\nf ").count - 1 == 96)
        #expect(obj.contains("o slice_016\n"))
    }

    @Test
    func threeDObjExportWritesLayeredSurfaceMesh() throws {
        // 3D Slices = the model sliced into surface-preserving layers (NOT a
        // three-family waffle). One OBJ object per layer; counts track the
        // layered-mesh builder exactly.
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = ThreeDSlicePlanner.plan(model: model, materialThickness: 3)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-cube-3d-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(threeD: plan, model: model, to: url)

        let layers = ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)
        let triangleCount = layers.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 }
        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(layers.count >= 2)
        #expect(obj.hasPrefix("# Refab Artist 3D slice mesh export\n"))
        #expect(obj.components(separatedBy: "\no three_d_").count - 1 == layers.count)
        #expect(obj.contains("o three_d_001\n"))
        #expect(obj.components(separatedBy: "\nv ").count - 1 == triangleCount * 3)
        #expect(obj.components(separatedBy: "\nf ").count - 1 == triangleCount)
    }

    @Test
    func radialObjExportWritesOneMeshObjectPerRingAndFin() throws {
        let model = try Self.cubeModel()
        let plan = RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(radial: plan, model: model, materialThickness: 3, to: url)

        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(obj.hasPrefix("# Refab Artist radial slice mesh export\n"))
        #expect(obj.components(separatedBy: "\no first_axis_").count - 1 == plan.primary?.sliceCount)
        #expect(obj.components(separatedBy: "\no radial_").count - 1 == RadialPartBuilder.wedgeCount(plan: plan))
        #expect(obj.contains("o first_axis_001\n"))
        #expect(obj.contains("o radial_001\n"))
        #expect(obj.contains("o radial_012\n"))
        #expect(obj.components(separatedBy: "\nv ").count - 1 > 0)
        #expect(obj.components(separatedBy: "\nf ").count - 1 > 0)
    }

    @Test
    func interlockedObjExportWritesSlottedPrimaryAndSecondaryMeshes() throws {
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 10)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-interlocked-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(interlocked: plan, model: model, to: url)

        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(obj.hasPrefix("# Refab Artist interlocked slice mesh export\n"))
        #expect(obj.components(separatedBy: "\no primary_").count - 1 == plan.primary.sliceCount)
        #expect(obj.components(separatedBy: "\no secondary_").count - 1 == plan.secondary.sliceCount)
        #expect(obj.components(separatedBy: "\nv ").count - 1 > plan.sliceCount * 8)
        #expect(obj.components(separatedBy: "\nf ").count - 1 > plan.sliceCount * 6)
    }

    @Test
    func curveObjExportWritesFirstAxisAndCurveMeshObjects() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-curve-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(curve: plan, model: model, materialThickness: 3, to: url)

        let obj = try String(contentsOf: url, encoding: .utf8)
        #expect(obj.hasPrefix("# Refab Artist curve slice mesh export\n"))
        #expect(obj.components(separatedBy: "\no first_axis_").count - 1 == plan.primarySliceCount)
        #expect(obj.components(separatedBy: "\no curve_").count - 1 == plan.sliceCount)
        #expect(obj.contains("o first_axis_001\n"))
        #expect(obj.contains("o curve_001\n"))
        #expect(obj.contains(String(format: "o curve_%03d\n", plan.sliceCount)))
        #expect(obj.components(separatedBy: "\nv ").count - 1 > 0)
        #expect(obj.components(separatedBy: "\nf ").count - 1 > 0)
    }

    @Test
    func foldedObjExportWritesOneMeshObjectPerFacePanel() throws {
        let model = try Self.cubeModel()
        let plan = FoldedPanelPlanner.plan(model: model)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-folded-obj-test-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }

        try ObjExporter.write(folded: plan, materialThickness: 3, to: url)

        let obj = try String(contentsOf: url, encoding: .utf8)
        // One mesh object per assembled net, derived from the same preview
        // paths the exporter consumes (the cube is a single tabbed cross).
        let layout = FoldedPanelPreviewLayouter.layout(plan: plan)
        let expectedVertices = layout.paths.reduce(0) { total, path in
            total + (max(0, path.points.count - 1) * 2)
        }
        let expectedFaces = layout.paths.reduce(0) { total, path in
            total + max(0, path.points.count - 1) + 2
        }

        #expect(obj.hasPrefix("# Refab Artist folded panel mesh export\n"))
        #expect(obj.components(separatedBy: "\no folded_panel_").count - 1 == layout.paths.count)
        #expect(obj.contains("o folded_panel_001\n"))
        #expect(obj.components(separatedBy: "\nv ").count - 1 == expectedVertices)
        #expect(obj.components(separatedBy: "\nf ").count - 1 == expectedFaces)
    }

    private static func squareContours(position: Double) -> StackedSliceContours {
        StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: position,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 20, y: 0),
                                Vec2(x: 20, y: 20),
                                Vec2(x: 0, y: 20),
                                Vec2(x: 0, y: 0)
                            ],
                            closed: true
                        )
                    ]
                )
            ]
        )
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
