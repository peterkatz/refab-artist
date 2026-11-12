import Foundation
import Testing
@testable import RefabArtist

struct DenseMeshStressTests {
    @Test
    func denseSphereFixtureImportsWithWatertightPreflight() throws {
        let model = try Self.denseSphere()

        #expect(model.format == "stl-binary")
        #expect(model.byteCount == 5_359_284)
        #expect(model.faceCount == 107_184)
        #expect(model.triangleCount == 107_184)
        #expect(model.vertexObservationCount == 321_552)
        #expect(model.geometry.vertices.count == 321_552)
        #expect(model.geometry.triangleIndices.count == 321_552)
        #expect(model.preflight.uniqueVertexCount == 53_594)
        #expect(model.preflight.duplicateVertexObservationCount == 267_958)
        #expect(model.preflight.invalidTriangleReferenceCount == 0)
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        #expect(model.preflight.isWatertight)
        #expect(model.bounds?.min == Vec3(x: -25, y: -25, z: -25))
        #expect(model.bounds?.max == Vec3(x: 25, y: 25, z: 25))
    }

    @Test
    func denseSphereBuildsRepresentativeStackedSvgExport() throws {
        let model = try Self.denseSphere()
        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5.0))

        #expect(plan.sliceCount == 10)

        let contours = StackedSliceContourer.generate(model: model, plan: plan)
        let allPaths = contours.layers.flatMap(\.paths)
        let allPathsClosed = allPaths.allSatisfy { $0.closed }
        #expect(contours.layers.count == plan.sliceCount)
        #expect(contours.layers.allSatisfy { !$0.paths.isEmpty })
        #expect(allPathsClosed)

        let layoutSettings = ExportLayoutSettings(
            partSpacing: 5,
            pageMargin: 5,
            sheetWidth: 600,
            sheetHeight: 300
        )
        let layout = SvgExporter.layout(contours: contours, layoutSettings: layoutSettings)
        #expect(layout.partCount == plan.sliceCount)
        #expect(layout.sheetCount >= 1)
        #expect(!layout.overflowsSheet)
        #expect(layout.parts.reduce(0) { $0 + $1.lines.count } > 1_000)

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "refabartist-dense-sphere-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try FlatPartExport.write(
            .stacked(plan, contours: contours, dowels: nil),
            format: .svg,
            model: model,
            settings: layoutSettings,
            to: outputURL
        )
        let svg = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(svg.contains("<svg"))
        #expect(svg.contains("<g id=\"part-1\">"))
        #expect(svg.contains("<g id=\"part-10\">"))
        #expect(svg.contains("<path "))
        #expect(svg.hasSuffix("</svg>\n"))
    }

    private static func denseSphere() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/stress/sphere_dense_d50mm.stl"))
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
