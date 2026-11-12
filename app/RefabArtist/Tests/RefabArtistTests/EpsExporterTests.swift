import Foundation
import Testing
@testable import RefabArtist

struct EpsExporterTests {
    @Test
    func stackedEpsLayoutIncludesLinesLabelsAndDowelCircles() {
        let layout = EpsExporter.layout(
            contours: Self.squareContours(),
            dowels: DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 5)
        )

        #expect(layout.parts.count == 1)
        #expect(layout.parts[0].label == "slice_001")
        #expect(layout.parts[0].lines.count == 4)
        #expect(layout.parts[0].circles.count == 4)
        #expect(layout.parts[0].circles.allSatisfy { $0.radius == 2 })
    }

    @Test
    func stackedEpsExportWritesPostScriptCommands() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-eps-test-\(UUID().uuidString).eps")
        defer { try? FileManager.default.removeItem(at: url) }

        try EpsExporter.write(
            layout: EpsExporter.layout(
                contours: Self.squareContours(),
                layoutSettings: .defaultValue,
                dowels: DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 5)
            ),
            to: url
        )

        let eps = try String(contentsOf: url, encoding: .ascii)
        #expect(eps.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))
        #expect(eps.contains("%%BoundingBox: 0 0"))
        #expect(eps.contains("(slice_001) show"))
        #expect(eps.components(separatedBy: " lineto stroke\n").count - 1 == 4)
        #expect(eps.components(separatedBy: " arc stroke\n").count - 1 == 4)
        #expect(eps.contains("showpage\n"))
        #expect(eps.hasSuffix("%%EOF\n"))
    }

    @Test
    func sheetEpsExportWritesBoundaryPathWhenConfigured() throws {
        let eps = try Self.export(EpsExporter.layout(
            contours: Self.squareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 70)
        ))

        #expect(eps.contains("155.906 0 lineto 155.906 198.425 lineto 0 198.425 lineto closepath stroke"))
    }

    @Test
    func cubeFixtureEpsExportContainsExpectedFabricationGeometry() throws {
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3)!
        let contours = StackedSliceContourer.generate(model: model, plan: plan)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-cube-eps-test-\(UUID().uuidString).eps")
        defer { try? FileManager.default.removeItem(at: url) }

        try EpsExporter.write(
            layout: EpsExporter.layout(
                contours: contours,
                layoutSettings: .defaultValue,
                dowels: DxfExporter.DowelSettings(enabled: true, diameter: 3, inset: 6)
            ),
            to: url
        )

        let eps = try String(contentsOf: url, encoding: .ascii)
        #expect(plan.sliceCount == 16)
        #expect(eps.contains("(slice_001) show"))
        #expect(eps.contains("(slice_016) show"))
        #expect(eps.components(separatedBy: " lineto stroke\n").count - 1 == 64)
        #expect(eps.components(separatedBy: " arc stroke\n").count - 1 == 64)
    }

    @Test
    func interlockedEpsExportRendersTheCutSheet() throws {
        // Interlocked EPS is the cut sheet (FlatPartExport routes it to
        // CutSheetDocumentExporter): every slotted outline, one per part.
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10)
        let document = CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: settings, revision: 1)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-eps-interlocked-\(UUID().uuidString).eps")
        defer { try? FileManager.default.removeItem(at: url) }

        try FlatPartExport.write(.interlocked(plan), format: .eps, model: model, settings: settings, to: url)
        let eps = try String(contentsOf: url, encoding: .ascii)

        let parts = document.sheets.flatMap(\.parts)
        #expect(document.sheets.count == 1)
        #expect(parts.count == plan.sliceCount)
        #expect(parts.contains { $0.label == "Z-1" })
        #expect(parts.contains { $0.label == "X-1" })
        #expect(eps.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0\n"))
        // One closed path per outline, plus the sheet border.
        let outlines = parts.flatMap(\.cutLoops).filter { $0.count >= 2 }.count
        #expect(eps.components(separatedBy: " closepath stroke\n").count - 1 == outlines + 1)
        #expect(eps.hasSuffix("%%EOF\n"))
    }

    @Test
    func radialEpsExportUsesModeLabels() throws {
        let model = try Self.cubeModel()
        let radial = RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5)!

        let radialEps = try Self.export(EpsExporter.layout(radial: radial, model: model, layoutSettings: .defaultValue))

        let radialParts = RadialPartBuilder.diskPartsModel(plan: radial, model: model)
            + RadialPartBuilder.wedgePartsModel(plan: radial, model: model)
        #expect(radialEps.contains("(first_axis_001) show"))
        #expect(radialEps.contains("(radial_001) show"))
        #expect(radialEps.contains("(radial_012) show"))
        #expect(radialEps.components(separatedBy: " lineto stroke\n").count - 1 == radialParts.reduce(0) { $0 + $1.loop.count })
        #expect(radialEps.hasSuffix("%%EOF\n"))
    }

    @Test
    func customLayoutSettingsAffectEpsPageAndOffsets() {
        let layout = EpsExporter.layout(
            contours: Self.twoSquareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 25, pageMargin: 5)
        )

        #expect(layout.pageWidth == 75)
        #expect(layout.pageHeight == 37)
        #expect(layout.pageMargin == 5)
        #expect(layout.parts.map(\.offset.x) == [5, 50])
        #expect(layout.parts.map(\.offset.y) == [5, 5])
    }

    @Test
    func sheetLayoutCarriesIntoEpsPageAndOffsets() {
        let layout = EpsExporter.layout(
            contours: Self.threeSquareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 70)
        )

        #expect(layout.pageWidth == 55)
        #expect(layout.pageHeight == 70)
        #expect(layout.sheetWidth == 55)
        #expect(layout.sheetHeight == 70)
        #expect(layout.overflowsSheet == false)
        #expect(layout.parts.map(\.offset.x) == [5, 30, 5])
        #expect(layout.parts.map(\.offset.y) == [5, 5, 37])
    }

    private static func squareContours() -> StackedSliceContours {
        StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 0,
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

    private static func twoSquareContours() -> StackedSliceContours {
        var contours = squareContours()
        contours.layers.append(contours.layers[0])
        contours.layers[1].position = 1
        return contours
    }

    private static func threeSquareContours() -> StackedSliceContours {
        var contours = twoSquareContours()
        contours.layers.append(contours.layers[0])
        contours.layers[2].position = 2
        return contours
    }

    /// Writes a single-sheet layout and returns the EPS text.
    private static func export(_ layout: EpsExporter.Layout) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-eps-mode-test-\(UUID().uuidString).eps")
        defer { try? FileManager.default.removeItem(at: url) }
        try EpsExporter.write(layout: layout, to: url)
        return try String(contentsOf: url, encoding: .ascii)
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
