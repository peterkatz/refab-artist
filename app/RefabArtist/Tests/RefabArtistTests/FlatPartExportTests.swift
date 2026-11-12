import Foundation
import Testing
@testable import RefabArtist

struct FlatPartExportTests {
    /// The app's Interlocked DXF export (the same call ContentView makes:
    /// FlatPartExport.write with the preview's cut sheet) must carry every
    /// part on every sheet, in true millimetres.
    @Test
    func interlockedCubeDxfWritesEveryCutSheetPart() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 3
        ))
        let settings = ExportLayoutSettings.defaultValue
        let source = FlatPartExport.Source.interlocked(plan)
        // What the sheet preview builds and the app hands to the export.
        let document = FlatPartExport.cutSheetDocument(for: source, model: model, settings: settings, revision: 1)
        let url = Self.temporaryURL("interlocked-cube.dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try FlatPartExport.write(
            source,
            format: .dxf,
            model: model,
            settings: settings,
            cutSheet: { document },
            to: url
        )

        #expect(writer == .cutSheet)
        let parts = document.sheets.flatMap(\.parts)
        // Every slice of the plan is a part on the sheet (10 + 10 here).
        #expect(document.partCount == plan.sliceCount)
        #expect(parts.count > 1)

        let dxf = try Self.readDXF(url)
        #expect(Set(dxf.partLayers) == Set(parts.map(\.label)))
        #expect(dxf.partLayers.count == parts.count)
        #expect(dxf.sheetLayers.count == document.sheets.count)
        for part in parts {
            let expected = part.cutLoops.reduce(0) { $0 + Self.closedSegmentCount($1) }
                + part.holeLoops.reduce(0) { $0 + Self.closedSegmentCount($1) }
                + part.openCuts.reduce(0) { $0 + max(0, $1.count - 1) }
            #expect(dxf.lineCount(onLayer: part.label) == expected, "part \(part.label)")
        }
        // True millimetres: each part spans the 50 mm cube section, and
        // everything sits inside the sheet width.
        for part in parts {
            let span = dxf.span(ofLayer: part.label)
            #expect(max(span.width, span.height) > 45 && max(span.width, span.height) < 55, "part \(part.label)")
        }
        #expect(dxf.maxX <= settings.sheetWidth + 1e-6)
    }

    @Test
    func writerTableFollowsTheFormatPicker() {
        for mode in ConstructionMode.allCases {
            for format in ExportFormat.allCases {
                let offered = format.usesVectorLayout
                    && ExportFormatSupport.availableFormats(for: mode).contains(format)
                #expect((FlatPartExport.writer(for: mode, format: format) != nil) == offered, "\(mode) \(format)")
            }
        }
        for mode: ConstructionMode in [.stacked, .interlocked, .radial, .curve, .foldedPanels, .inflatables] {
            #expect(FlatPartExport.writer(for: mode, format: .svg) == .cutSheet)
            #expect(FlatPartExport.writer(for: mode, format: .pdf) == .cutSheet)
        }
        #expect(FlatPartExport.writer(for: .stacked, format: .dxf) == .stackedDXF)
        #expect(FlatPartExport.writer(for: .interlocked, format: .dxf) == .cutSheet)
        #expect(FlatPartExport.writer(for: .radial, format: .dxf) == .radialDXF)
        #expect(FlatPartExport.writer(for: .curve, format: .dxf) == .cutSheet)
        #expect(FlatPartExport.writer(for: .foldedPanels, format: .dxf) == .cutSheet)
        #expect(FlatPartExport.writer(for: .inflatables, format: .dxf) == .inflatablesCutSheet)
        #expect(FlatPartExport.writer(for: .interlocked, format: .eps) == .cutSheet)
        #expect(FlatPartExport.writer(for: .curve, format: .eps) == .cutSheet)
        #expect(FlatPartExport.writer(for: .foldedPanels, format: .eps) == .cutSheet)
        for mode: ConstructionMode in [.stacked, .radial] {
            #expect(FlatPartExport.writer(for: mode, format: .eps) == .sheetEPS)
        }
        #expect(FlatPartExport.writer(for: .inflatables, format: .eps) == nil)
    }

    /// The cut-sheet DXF is the preview the right way up: a sheet point at
    /// `y` is written at `dxfY(sheet) - y`, sheet 1 spans 0 to the sheet
    /// height and each further sheet lies wholly below the one before.
    @Test
    func cutSheetDxfIsThePreviewTheRightWayUp() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3
        ))
        // A small sheet, so the twenty parts take several.
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 200, sheetHeight: 150)
        let source = FlatPartExport.Source.interlocked(plan)
        let document = FlatPartExport.cutSheetDocument(for: source, model: model, settings: settings, revision: 1)
        #expect(document.sheets.count > 1)
        let url = Self.temporaryURL("upright.dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try FlatPartExport.write(source, format: .dxf, model: model, settings: settings, cutSheet: { document }, to: url)

        let dxf = try Self.readDXF(url)
        var previousBottom = Double.infinity
        for (index, sheet) in document.sheets.enumerated() {
            let top = CutSheetDocumentExporter.dxfY(sheetIndex: index, sheetHeight: settings.sheetHeight)
            for part in sheet.parts {
                let loop = part.cutLoops[0]
                let written = dxf.lines.filter { $0.layer == part.label }
                #expect(written.contains { line in
                    abs(line.a.x - loop[0].x) < 1.0e-5 && abs(line.a.y - (top - loop[0].y)) < 1.0e-5
                        && abs(line.b.x - loop[1].x) < 1.0e-5 && abs(line.b.y - (top - loop[1].y)) < 1.0e-5
                }, "\(part.label)")
            }
            let boundary = dxf.lines.filter { $0.layer == (index == 0 ? "sheet_boundary" : "sheet_boundary_\(index + 1)") }
            let ys = boundary.flatMap { [$0.a.y, $0.b.y] }
            #expect(abs((ys.max() ?? .nan) - top) < 1.0e-6)
            #expect(abs((ys.min() ?? .nan) - (top - settings.sheetHeight)) < 1.0e-6)
            #expect((ys.max() ?? .nan) < previousBottom)
            previousBottom = ys.min() ?? .nan
        }
        #expect(abs(CutSheetDocumentExporter.dxfY(sheetIndex: 0, sheetHeight: settings.sheetHeight) - 150) < 1.0e-9)
    }

    /// The Inflatables DXF is its cut sheet the right way up, as the
    /// cut-sheet DXF is: a sheet point at `y` is written at `dxfY(sheet) - y`,
    /// so a part is not mirrored and sheet 2 lies below sheet 1.
    @Test
    func inflatablesDxfIsTheCutSheetTheRightWayUp() throws {
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 200, sheetHeight: 150)
        // An L-shaped panel near the top of each sheet: its foot at the
        // bottom of the shape, so a mirrored sheet would put it on top.
        let panel = [
            Vec2(x: 20, y: 20), Vec2(x: 30, y: 20), Vec2(x: 30, y: 50),
            Vec2(x: 60, y: 50), Vec2(x: 60, y: 60), Vec2(x: 20, y: 60)
        ]
        func part(_ label: String) -> CutSheetPart {
            CutSheetPart(
                label: label,
                stepIndex: nil,
                cutLoops: [panel],
                openCuts: [],
                guideLines: [[Vec2(x: 25, y: 25), Vec2(x: 25, y: 55)]],
                circles: [SvgExporter.Circle(center: Vec2(x: 40, y: 55), radius: 2)],
                bounds: SvgExporter.Bounds2(min: Vec2(x: 20, y: 20), max: Vec2(x: 60, y: 60)),
                labelAnchor: Vec2(x: 25, y: 40),
                labelRadius: 4,
                overflowsSheet: false
            )
        }
        let document = CutSheetDocument(
            sheetWidth: settings.sheetWidth,
            sheetHeight: settings.sheetHeight,
            sheets: [CutSheetSheet(index: 1, parts: [part("1")]), CutSheetSheet(index: 2, parts: [part("2")])],
            revision: 1
        )
        let url = Self.temporaryURL("inflatables.dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try InflatablesDXFExporter.write(document: document, settings: settings, to: url)
        let dxf = try Self.readDXF(url)
        let text = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let cuts = dxf.lines.filter { $0.layer == InflatablesDXFExporter.Layer.cut }
        let seams = dxf.lines.filter { $0.layer == InflatablesDXFExporter.Layer.seam }
        let edges = dxf.lines.filter { $0.layer == InflatablesDXFExporter.Layer.foldRegistration }
        #expect(cuts.count == 2 * panel.count)
        var previousBottom = Double.infinity
        for (index, sheet) in document.sheets.enumerated() {
            let top = CutSheetDocumentExporter.dxfY(sheetIndex: index, sheetHeight: settings.sheetHeight)
            let loop = sheet.parts[0].cutLoops[0]
            for k in loop.indices {
                let a = loop[k]
                let b = loop[(k + 1) % loop.count]
                #expect(cuts.contains { line in
                    abs(line.a.x - a.x) < 1.0e-6 && abs(line.a.y - (top - a.y)) < 1.0e-6
                        && abs(line.b.x - b.x) < 1.0e-6 && abs(line.b.y - (top - b.y)) < 1.0e-6
                }, "sheet \(index + 1) edge \(k)")
            }
            #expect(seams.contains { abs($0.a.y - (top - 25)) < 1.0e-6 && abs($0.b.y - (top - 55)) < 1.0e-6 })
            let ys = edges.flatMap { [$0.a.y, $0.b.y] }.filter { $0 <= top + 1.0e-6 && $0 >= top - settings.sheetHeight - 1.0e-6 }
            #expect(abs((ys.max() ?? .nan) - top) < 1.0e-6)
            #expect(abs((ys.min() ?? .nan) - (top - settings.sheetHeight)) < 1.0e-6)
            #expect(top < previousBottom)
            previousBottom = top - settings.sheetHeight
        }
        // The label sits where the preview puts it on sheet 1, and the drill
        // circle too.
        func values(after entity: String) -> [(x: Double, y: Double)] {
            var found: [(Double, Double)] = []
            for index in text.indices.dropLast() where text[index] == "0" && text[index + 1] == entity {
                var fields: [String: String] = [:]
                var cursor = index + 2
                while cursor + 1 < text.count, text[cursor] != "0" {
                    fields[text[cursor]] = text[cursor + 1]
                    cursor += 2
                }
                found.append((Double(fields["10"] ?? "") ?? .nan, Double(fields["20"] ?? "") ?? .nan))
            }
            return found
        }
        let firstTop = CutSheetDocumentExporter.dxfY(sheetIndex: 0, sheetHeight: settings.sheetHeight)
        #expect(values(after: "TEXT").contains { abs($0.x - 25) < 1.0e-6 && abs($0.y - (firstTop - 40)) < 1.0e-6 })
        #expect(values(after: "CIRCLE").contains { abs($0.x - 40) < 1.0e-6 && abs($0.y - (firstTop - 55)) < 1.0e-6 })
    }

    /// EPS writes one file per sheet, in a ZIP when there are several, and
    /// the export dialog's count (which picks .eps or .zip) is the number
    /// written. Interlocked and Curve Slices render the cut sheet; the other
    /// modes count their own row layout's sheets.
    @Test
    func epsWritesOneFilePerSheetAndTheExportKnowsHowMany() throws {
        let model = try Self.cubeModel()
        let interlocked = try #require(InterlockedSlicePlanner.plan(
            model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3
        ))
        let curve = try #require(CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10))
        let stacked = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 3))
        let sources: [FlatPartExport.Source] = [
            .interlocked(interlocked),
            .curve(curve),
            .stacked(stacked, contours: nil, dowels: nil)
        ]
        let small = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 200, sheetHeight: 150)
        for settings in [ExportLayoutSettings.defaultValue, small] {
            for source in sources {
                let document = FlatPartExport.cutSheetDocument(for: source, model: model, settings: settings, revision: 1)
                let url = Self.temporaryURL("sheets.eps")
                defer { try? FileManager.default.removeItem(at: url) }
                let writer = try FlatPartExport.write(
                    source, format: .eps, model: model, settings: settings, cutSheet: { document }, to: url
                )
                let expected = try FlatPartExport.epsFileCount(source, model: model, settings: settings, cutSheet: { document })
                let data = try Data(contentsOf: url)
                let header = Data([0x50, 0x4B, 0x03, 0x04])
                let isZip = data.starts(with: header)
                var files = 0
                var cursor = data.startIndex
                while let found = data.range(of: header, in: cursor..<data.endIndex) {
                    files += 1
                    cursor = found.upperBound
                }
                #expect((isZip ? files : 1) == expected, "\(source.mode) \(settings.sheetHeight)")
                if source.mode == .interlocked || source.mode == .curve {
                    #expect(writer == .cutSheet)
                    #expect(expected == document.sheets.count)
                    if !isZip {
                        let text = try #require(String(data: data, encoding: .ascii))
                        // Every part drawn in blue, with its label.
                        let parts = document.sheets.flatMap(\.parts)
                        let labelled = parts.filter {
                            CutSheetRenderModel.labelSize(radius: $0.labelRadius, characterCount: $0.label.count) > 0.2
                        }
                        #expect(text.components(separatedBy: "0.0 0.0 1.0 setrgbcolor").count - 1 == parts.count)
                        #expect(text.components(separatedBy: " stringwidth ").count - 1 == labelled.count)
                    }
                } else {
                    #expect(writer == .sheetEPS)
                }
            }
        }
    }

    /// Without a sheet size the per-sheet EPS writer puts every part on one
    /// page fitted to the layout.
    @Test
    func perSheetEpsWithoutASheetSizeKeepsEveryPart() throws {
        let model = try Self.cubeModel()
        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5))
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10)
        let layout = EpsExporter.layout(contours: StackedSliceContourer.generate(model: model, plan: plan), layoutSettings: settings)
        #expect(layout.sheetCount == 0)
        #expect(!layout.parts.isEmpty)
        let url = Self.temporaryURL("no-sheet.eps")
        defer { try? FileManager.default.removeItem(at: url) }
        try EpsExporter.write(layout: layout, to: url)
        let text = try String(contentsOf: url, encoding: .ascii)
        for part in layout.parts {
            #expect(text.contains("(\(part.label)) show"), "\(part.label)")
        }
        #expect(!text.contains("%%BoundingBox: 0 0 0 0"))
    }

    @Test
    func threeDSlicesHaveNoFlatExport() throws {
        let model = try Self.cubeModel()
        let plan = try #require(ThreeDSlicePlanner.plan(model: model, materialThickness: 5))
        for format: ExportFormat in [.dxf, .eps, .pdf, .svg] {
            let url = Self.temporaryURL("three-d.\(format.rawValue)")
            #expect(throws: FlatPartExport.ExportError.self) {
                try FlatPartExport.write(.threeD(plan), format: format, model: model, settings: .defaultValue, to: url)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// A radial plan with no fins exports exactly like its Interlocked plan.
    @Test
    func radialWithoutFinsExportsAsInterlocked() throws {
        let model = try Self.cubeModel()
        let radial = try #require(RadialSlicePlanner.plan(model: model, nRadial: 0, materialThickness: 5))
        let fallback = try #require(radial.interlockedFallbackPlan())
        let radialURL = Self.temporaryURL("radial-n0.dxf")
        let interlockedURL = Self.temporaryURL("interlocked.dxf")
        defer {
            try? FileManager.default.removeItem(at: radialURL)
            try? FileManager.default.removeItem(at: interlockedURL)
        }

        let writer = try FlatPartExport.write(.radial(radial), format: .dxf, model: model, settings: .defaultValue, to: radialURL)
        try FlatPartExport.write(.interlocked(fallback), format: .dxf, model: model, settings: .defaultValue, to: interlockedURL)

        #expect(writer == .cutSheet)
        #expect(try Data(contentsOf: radialURL) == Data(contentsOf: interlockedURL))
    }

    /// The headless CLI writes the same bytes the app export writes for the
    /// same plan and sheet settings.
    @Test
    func headlessInterlockedDxfMatchesTheAppExport() throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl")
        let cliURL = Self.temporaryURL("cli-interlocked.dxf")
        let appURL = Self.temporaryURL("app-interlocked.dxf")
        defer {
            try? FileManager.default.removeItem(at: cliURL)
            try? FileManager.default.removeItem(at: appURL)
        }

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "interlocked",
            "--format", "dxf",
            "--fixture", fixture.path,
            "--axis", "z",
            "--secondary-axis", "x",
            "--thickness", "3",
            "--output", cliURL.path
        ])

        // Loaded the way the CLI loads it: millimetres, Z up.
        let model = ImportUpAxis.z.orientedModel(MeshScaler.scaled(
            try MeshInspector.inspect(url: fixture),
            factor: MeshScaler.combinedFactor(unit: .millimeters, userScale: 1)
        ))
        let export = try HeadlessExportCommand.buildExport(
            mode: .interlocked,
            model: model,
            axis: .z,
            secondaryAxis: .x,
            materialThickness: 3,
            sliceDepth: nil,
            slotClearance: 0,
            notchWidth: nil,
            slotAngle: 0,
            slotRelief: SlotReliefSettings(enabled: false, diameter: 4),
            sliceCount: nil,
            firstAxisCount: nil,
            curveSliceCount: nil,
            amplitude: 10,
            splineControlPoints: nil
        )
        let settings = ExportLayoutSettings.defaultValue
        let document = FlatPartExport.cutSheetDocument(for: export.flatPartSource, model: model, settings: settings, revision: 7)
        try FlatPartExport.write(export.flatPartSource, format: .dxf, model: model, settings: settings, cutSheet: { document }, to: appURL)

        #expect(try Data(contentsOf: cliURL) == Data(contentsOf: appURL))
    }

    // MARK: - Helpers

    private struct ParsedDXF {
        var lines: [(layer: String, a: Vec2, b: Vec2)] = []

        var partLayers: [String] {
            var seen: [String] = []
            for line in lines where !line.layer.hasPrefix("sheet_boundary") && !line.layer.hasSuffix("_guide") {
                if !seen.contains(line.layer) { seen.append(line.layer) }
            }
            return seen
        }

        var sheetLayers: Set<String> {
            Set(lines.map(\.layer).filter { $0.hasPrefix("sheet_boundary") })
        }

        var maxX: Double {
            lines.flatMap { [$0.a.x, $0.b.x] }.max() ?? 0
        }

        func lineCount(onLayer layer: String) -> Int {
            lines.filter { $0.layer == layer }.count
        }

        func span(ofLayer layer: String) -> (width: Double, height: Double) {
            let points = lines.filter { $0.layer == layer }.flatMap { [$0.a, $0.b] }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    /// LINE entities of a cut-sheet DXF (group codes 8, 10/20, 11/21).
    private static func readDXF(_ url: URL) throws -> ParsedDXF {
        let rows = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var parsed = ParsedDXF()
        var index = 0
        while index + 1 < rows.count {
            guard rows[index] == "0", rows[index + 1] == "LINE" else {
                index += 2
                continue
            }
            var fields: [String: String] = [:]
            var cursor = index + 2
            while cursor + 1 < rows.count, rows[cursor] != "0" {
                fields[rows[cursor]] = rows[cursor + 1]
                cursor += 2
            }
            let value = { (code: String) in Double(fields[code] ?? "") ?? .nan }
            parsed.lines.append((
                layer: fields["8"] ?? "",
                a: Vec2(x: value("10"), y: value("20")),
                b: Vec2(x: value("11"), y: value("21"))
            ))
            index = cursor
        }
        return parsed
    }

    /// Segments the cut-sheet DXF writes for a closed loop: one per edge,
    /// plus the closing edge unless the loop already repeats its first point.
    private static func closedSegmentCount(_ loop: [Vec2]) -> Int {
        guard loop.count >= 2 else { return 0 }
        return loop.count - 1 + (loop.first == loop.last ? 0 : 1)
    }

    private static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "flat-part-export-\(UUID().uuidString)-\(name)")
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
