import Foundation
import Testing
@testable import RefabArtist

struct StlExporterTests {
    @Test
    func stackedStlExportWritesSliceSlabFacets() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(
            contours: Self.squareContours(position: 10),
            materialThickness: 4,
            to: url
        )

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(stl.hasPrefix("solid refabartist_stacked_slices\n"))
        #expect(stl.hasSuffix("endsolid refabartist_stacked_slices\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 == 12)
        #expect(stl.components(separatedBy: "vertex").count - 1 == 36)
        #expect(stl.contains("vertex 0.000000 0.000000 8.000000\n"))
        #expect(stl.contains("vertex 0.000000 0.000000 12.000000\n"))
    }

    @Test
    func cubeFixtureStlExportContainsExpectedFacetCount() throws {
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3)!
        let contours = StackedSliceContourer.generate(model: model, plan: plan)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-cube-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(contours: contours, materialThickness: plan.materialThickness, to: url)

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(plan.sliceCount == 16)
        #expect(stl.components(separatedBy: "facet normal").count - 1 == 192)
        #expect(stl.components(separatedBy: "vertex").count - 1 == 576)
    }

    @Test
    func threeDStlExportWritesLayeredSurfaceMesh() throws {
        // 3D Slices = the model sliced into surface-preserving layers (NOT a
        // three-family waffle). The STL is the union of the per-layer shell
        // meshes; its facet count tracks the layered-mesh builder exactly.
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = ThreeDSlicePlanner.plan(model: model, materialThickness: 3)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-cube-3d-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(threeD: plan, model: model, to: url)

        let layers = ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)
        let triangleCount = layers.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 }
        #expect(layers.count >= 2)                                   // sliced into layers
        #expect(triangleCount > 0)
        #expect(layers.allSatisfy { $0.name.hasPrefix("three_d_") }) // single-axis layer naming

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(stl.hasPrefix("solid refabartist_3d_slices\n"))
        #expect(stl.hasSuffix("endsolid refabartist_3d_slices\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 == triangleCount)
        #expect(stl.components(separatedBy: "vertex").count - 1 == triangleCount * 3)
    }

    @Test
    func radialStlExportWritesSliceSolidsInRadialPlanes() throws {
        let model = try Self.cubeModel()
        let plan = RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(radial: plan, model: model, materialThickness: 3, to: url)

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(stl.hasPrefix("solid refabartist_radial_slices\n"))
        #expect(stl.hasSuffix("endsolid refabartist_radial_slices\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 > 0)
        #expect(stl.contains(" -1.500000 "))
        #expect(stl.contains(" 1.500000 "))
    }

    @Test
    func interlockedStlExportWritesSlottedPanelFacets() throws {
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 10)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-interlocked-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(interlocked: plan, model: model, to: url)

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(stl.hasPrefix("solid refabartist_interlocked_slices\n"))
        #expect(stl.hasSuffix("endsolid refabartist_interlocked_slices\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 > plan.sliceCount * 12)
        #expect(stl.components(separatedBy: "vertex").count - 1 > plan.sliceCount * 36)
    }

    @Test
    func curveStlExportWritesSliceSolidsInCurvePlanes() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-curve-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(curve: plan, model: model, materialThickness: 3, to: url)

        let stl = try String(contentsOf: url, encoding: .utf8)
        #expect(stl.hasPrefix("solid refabartist_curve_slices\n"))
        #expect(stl.hasSuffix("endsolid refabartist_curve_slices\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 > 0)
        #expect(stl.contains("vertex "))
    }

    @Test
    func foldedStlExportWritesOnePrismPerNet() throws {
        let model = try Self.cubeModel()
        let plan = FoldedPanelPlanner.plan(model: model)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-folded-stl-test-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }

        try StlExporter.write(folded: plan, materialThickness: 3, to: url)

        let stl = try String(contentsOf: url, encoding: .utf8)
        // One extruded plate per assembled net (the cube is a single tabbed
        // cross), derived from the same preview paths the exporter consumes.
        let layout = FoldedPanelPreviewLayouter.layout(plan: plan)
        let expectedFacets = layout.paths.reduce(0) { total, path in
            let vertexCount = max(0, path.points.count - 1)
            return total + ((vertexCount - 2) * 2) + (vertexCount * 2)
        }

        #expect(stl.hasPrefix("solid refabartist_folded_panels\n"))
        #expect(stl.hasSuffix("endsolid refabartist_folded_panels\n"))
        #expect(stl.components(separatedBy: "facet normal").count - 1 == expectedFacets)
        #expect(stl.components(separatedBy: "vertex").count - 1 == expectedFacets * 3)
        #expect(stl.contains(" -1.500000\n"))
        #expect(stl.contains(" 1.500000\n"))
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
