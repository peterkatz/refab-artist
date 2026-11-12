import Foundation
import Testing
@testable import RefabArtist

struct SvgExporterTests {
    @Test
    func stackedSvgLayoutIncludesLinesLabelsAndDowelCircles() {
        let layout = SvgExporter.layout(
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
    func cubeFixtureLayoutContainsExpectedFabricationGeometry() throws {
        let fixture = Self.repoRoot()
            .appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: fixture)
        let plan = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3)!
        let contours = StackedSliceContourer.generate(model: model, plan: plan)

        let layout = SvgExporter.layout(
            contours: contours,
            dowels: DxfExporter.DowelSettings(enabled: true, diameter: 3, inset: 6)
        )

        #expect(plan.sliceCount == 16)
        #expect(layout.parts.first?.label == "slice_001")
        #expect(layout.parts.last?.label == "slice_016")
        #expect(layout.parts.flatMap(\.lines).count == 64)
        #expect(layout.parts.flatMap(\.circles).count == 64)
    }

    @Test
    func radialLayoutUsesModeLabels() throws {
        let model = try Self.cubeModel()
        let radial = RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5)!

        let radialLayout = SvgExporter.layout(radial: radial, model: model)

        // Rings first, then fins — one line per loop segment of the shared
        // disk+wedge parts.
        let radialParts = RadialPartBuilder.diskPartsModel(plan: radial, model: model)
            + RadialPartBuilder.wedgePartsModel(plan: radial, model: model)
        let radialLabels = radialLayout.parts.map(\.label)
        #expect(radialLabels.contains("first_axis_001"))
        #expect(radialLabels.contains("first_axis_010"))
        #expect(radialLabels.contains("radial_001"))
        #expect(radialLabels.contains("radial_012"))
        #expect(radialLayout.parts.flatMap(\.lines).count == radialParts.reduce(0) { $0 + $1.loop.count })
    }

    @Test
    func customLayoutSettingsAffectSvgDimensionsAndPartOffsets() {
        let layout = SvgExporter.layout(
            contours: Self.twoSquareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 25, pageMargin: 5)
        )

        #expect(layout.width == 75)
        #expect(layout.height == 37)
        #expect(layout.pageMargin == 5)
        #expect(layout.partCount == 2)
        #expect(layout.usedWidth == 75)
        #expect(layout.usedHeight == 37)
        #expect(layout.sheetUtilization == nil)
        #expect(layout.parts.map(\.offset.x) == [5, 50])
        #expect(layout.parts.map(\.offset.y) == [5, 5])
    }

    @Test
    func sheetLayoutWrapsSvgPartsAcrossRows() {
        let layout = SvgExporter.layout(
            contours: Self.threeSquareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 70)
        )

        #expect(layout.width == 55)
        #expect(layout.height == 70)
        #expect(layout.sheetWidth == 55)
        #expect(layout.sheetHeight == 70)
        #expect(layout.sheetCount == 1)
        #expect(layout.overflowsSheet == false)
        #expect(layout.partCount == 3)
        #expect(layout.usedWidth == 55)
        #expect(layout.usedHeight == 69)
        #expect(layout.sheetUtilization! > 0.98)
        #expect(layout.sheetUtilization! < 0.99)
        #expect(layout.parts.map(\.offset.x) == [5, 30, 5])
        #expect(layout.parts.map(\.offset.y) == [5, 5, 37])
    }

    @Test
    func sheetLayoutPaginatesRowsAcrossStockSheets() {
        let layout = SvgExporter.layout(
            contours: Self.threeSquareContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 60)
        )

        #expect(layout.width == 55)
        #expect(layout.height == 120)
        #expect(layout.usedWidth == 55)
        #expect(layout.usedHeight == 97)
        #expect(layout.sheetCount == 2)
        #expect(layout.sheetPartCounts == [2, 1])
        #expect(layout.sheetUtilization! > 0.80)
        #expect(layout.sheetUtilization! < 0.81)
        #expect(layout.overflowsSheet == false)
        #expect(layout.parts.map(\.offset.y) == [5, 5, 65])
        #expect(layout.parts.map { layout.sheetIndex(for: $0) } == [1, 1, 2])
    }

    @Test
    func sheetLayoutReportsOverflowWhenSinglePartCannotFitStockHeight() {
        let layout = SvgExporter.layout(
            contours: Self.tallRectangleContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 100, sheetHeight: 50)
        )

        #expect(layout.overflowsSheet)
        #expect(layout.sheetCount == 2)
    }

    @Test
    func sheetLayoutRotatesWidePartsThatFitWhenTurned() {
        let layout = SvgExporter.layout(
            contours: Self.wideRectangleContours(),
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 50, sheetHeight: 100)
        )

        #expect(layout.width == 50)
        #expect(layout.height == 100)
        #expect(layout.usedWidth == 30)
        #expect(layout.usedHeight == 87)
        #expect(layout.overflowsSheet == false)
        #expect(layout.partCount == 1)

        let part = layout.parts[0]
        #expect(part.bounds.max.x - part.bounds.min.x == 20)
        #expect(part.bounds.max.y - part.bounds.min.y == 70)
        #expect(part.offset == Vec2(x: 5, y: 5))
        #expect(part.lines.contains(SvgExporter.Line(start: Vec2(x: 0, y: 70), end: Vec2(x: 0, y: 0))))
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

    private static func wideRectangleContours() -> StackedSliceContours {
        StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 0,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 70, y: 0),
                                Vec2(x: 70, y: 20),
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

    private static func tallRectangleContours() -> StackedSliceContours {
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
                                Vec2(x: 20, y: 70),
                                Vec2(x: 0, y: 70),
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
