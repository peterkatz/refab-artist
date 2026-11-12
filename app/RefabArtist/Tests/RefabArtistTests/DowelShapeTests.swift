import Foundation
import Testing
@testable import RefabArtist

/// The six original dowel cross-sections: outline geometry plus the
/// integration points (mesh carving, cut-sheet document, SVG export).
struct DowelShapeTests {
    private static func signedArea(_ loop: [Vec2]) -> Double {
        var area = 0.0
        var j = loop.count - 1
        for i in loop.indices {
            area += (loop[j].x * loop[i].y) - (loop[i].x * loop[j].y)
            j = i
        }
        return area / 2
    }

    @Test
    func outlinesAreClockwiseClosedAndSized() {
        let center = Vec2(x: 7, y: -3)
        let diameter = 6.0
        for shape in DowelShape.allCases where shape != .round {
            let outline = shape.outline(center: center, diameter: diameter)!
            #expect(outline.count >= 4)
            // Hole winding (clockwise = negative signed area), matching the
            // mesh carver's circle polygon.
            #expect(Self.signedArea(outline) < 0)
            // Centered, sized by the shape's real-world measurement
            // convention: a Pencil is measured ACROSS FLATS (a 7.5 mm
            // pencil fits a hex hole with 7.5 mm between flats, so the
            // across-corners extent is d·2/√3); everything else spans d on
            // its longer dimension.
            let xs = outline.map(\.x)
            let ys = outline.map(\.y)
            let width = xs.max()! - xs.min()!
            let height = ys.max()! - ys.min()!
            if shape == .pencil {
                #expect(abs(min(width, height) - diameter) < 1e-9)
                #expect(abs(max(width, height) - diameter * 2.0 / 3.0.squareRoot()) < 1e-9)
            } else {
                #expect(abs(max(width, height) - diameter) < 1e-9)
            }
            #expect(abs((xs.max()! + xs.min()!) / 2 - center.x) < 1e-9)
            #expect(abs((ys.max()! + ys.min()!) / 2 - center.y) < 1e-9)
        }
        #expect(DowelShape.round.outline(center: center, diameter: diameter) == nil)
        // The Shape dropdown has exactly these six.
        #expect(DowelShape.allCases.count == 6)
    }

    @Test
    func shapesCarryRealWorldDefaultSizes() {
        // Selecting a shape applies its real-world size: a standard hex
        // pencil is ~7.5 mm across flats; round/square stock defaults to the
        // 1/4-inch (6.35 mm) hardware dowel.
        #expect(DowelShape.pencil.defaultDiameter == 7.5)
        #expect(DowelShape.round.defaultDiameter == 6.35)
        for shape in DowelShape.allCases {
            #expect(shape.defaultDiameter > 0)
        }
    }

    @Test
    func squareShapeCarvesSquareHolesInMeshExport() {
        // Two 40mm square slices, one manual rod at the center, square shape:
        // the carved hole's vertices must sit at center +- d/2 (a 24-gon
        // circle would have no vertex at the corners).
        let square = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0), Vec2(x: 40, y: 0),
                Vec2(x: 40, y: 40), Vec2(x: 0, y: 40), Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [square]),
                SliceContourLayer(position: 3, paths: [square])
            ]
        )
        var settings = DxfExporter.DowelSettings(enabled: true, diameter: 6, inset: 2)
        settings.manualPositions = [Vec2(x: 20, y: 20)]
        settings.shape = .square
        let layers = StackedDowelMeshBuilder.layers(contours: contours, materialThickness: 3, dowels: settings)
        #expect(layers.count == 2)
        for layer in layers {
            let corners = layer.mesh.vertices.filter { vertex in
                abs(abs(vertex.x - 20) - 3) < 1e-9 && abs(abs(vertex.y - 20) - 3) < 1e-9
            }
            // All four hole corners present in both caps and walls.
            #expect(corners.count >= 8)
        }
    }

    @Test
    func cutSheetDocumentRoutesShapesAsLoopsAndRoundAsCircles() {
        let square = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0), Vec2(x: 30, y: 0),
                Vec2(x: 30, y: 30), Vec2(x: 0, y: 30), Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [square]),
                SliceContourLayer(position: 3, paths: [square])
            ]
        )
        let layout = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 100, sheetHeight: 100)
        var settings = DxfExporter.DowelSettings(enabled: true, diameter: 6, inset: 2)
        settings.manualPositions = [Vec2(x: 15, y: 15)]

        settings.shape = .cross
        let crossDocument = CutSheetLayoutBuilder.document(stacked: contours, settings: layout, dowels: settings, revision: 1)
        for part in crossDocument.sheets.flatMap(\.parts) {
            #expect(part.circles.isEmpty)
            #expect(part.holeLoops.count == 1)
            #expect(part.holeLoops[0].count == 12) // plus-shape corners
        }

        settings.shape = .round
        let roundDocument = CutSheetLayoutBuilder.document(stacked: contours, settings: layout, dowels: settings, revision: 1)
        for part in roundDocument.sheets.flatMap(\.parts) {
            #expect(part.circles.count == 1)
            #expect(part.holeLoops.isEmpty)
        }
    }

    @Test
    func svgExportDrawsShapeHolesAsBlueClosedPaths() throws {
        let square = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0), Vec2(x: 30, y: 0),
                Vec2(x: 30, y: 30), Vec2(x: 0, y: 30), Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [square]),
                SliceContourLayer(position: 3, paths: [square])
            ]
        )
        let layout = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 100, sheetHeight: 100)
        var settings = DxfExporter.DowelSettings(enabled: true, diameter: 6, inset: 2)
        settings.manualPositions = [Vec2(x: 15, y: 15)]
        settings.shape = .verticalSlot
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: layout, dowels: settings, revision: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dowel-shape-test-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: url) }
        try CutSheetDocumentExporter.writeSVG(document: document, settings: layout, to: url)
        let svg = try String(contentsOf: url, encoding: .utf8)
        // No circles for slot dowels; the hole is a blue closed path. Each
        // part draws outline + hole = at least 2 blue Z-closed paths.
        #expect(!svg.contains("<circle"))
        let closedBluePaths = svg.components(separatedBy: "Z\" fill=\"none\" stroke=\"#0000FF\"").count - 1
        #expect(closedBluePaths >= 4)
    }

    @Test
    func dxfStackedExportCutsShapeOutlines() throws {
        let square = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0), Vec2(x: 30, y: 0),
                Vec2(x: 30, y: 30), Vec2(x: 0, y: 30), Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [square]),
                SliceContourLayer(position: 3, paths: [square])
            ]
        )
        var settings = DxfExporter.DowelSettings(enabled: true, diameter: 6, inset: 2)
        settings.manualPositions = [Vec2(x: 15, y: 15)]
        settings.shape = .square

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dowel-shape-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DxfExporter.write(
            contours: contours,
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 200, sheetHeight: 200),
            dowels: settings
        )
        let dxf = try String(contentsOf: url, encoding: .utf8)
        // Square dowels cut as polylines, not CIRCLE entities.
        #expect(!dxf.contains("CIRCLE"))

        settings.shape = .round
        try DxfExporter.write(
            contours: contours,
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 200, sheetHeight: 200),
            dowels: settings
        )
        let roundDxf = try String(contentsOf: url, encoding: .utf8)
        #expect(roundDxf.contains("CIRCLE")) // round stays a true circle
    }
}
