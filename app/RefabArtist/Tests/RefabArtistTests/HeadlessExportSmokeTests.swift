import Foundation
import Testing
@testable import RefabArtist

struct HeadlessExportSmokeTests {
    @Test
    func cubeFixtureExportsEverySupportedModeAndFormat() throws {
        let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
        let exported = try Self.smokeAllSupportedExports(model: model, outputName: "cube")

        #expect(exported.count == 41) // 5 flat modes × 6 formats + Inflatables × 5 + 3D/Structures/Partition × 2
    }

    @Test
    func pyramidFixtureExportsEverySupportedModeAndFormat() throws {
        let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/square_pyramid_ascii.stl"))
        let exported = try Self.smokeAllSupportedExports(model: model, outputName: "square-pyramid")

        #expect(exported.count == 41) // 5 flat modes × 6 formats + Inflatables × 5 + 3D/Structures/Partition × 2
    }

    private static func smokeAllSupportedExports(model: MeshSummary, outputName: String) throws -> [(ConstructionMode, ExportFormat)] {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-export-smoke-\(outputName)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        // MotherMold's planner is still a scaffold stub (returns an empty plan
        // with no parts), so it has nothing to export yet — exclude it from the
        // "every mode/format must produce a file" smoke loop until the engine
        // lands. Every other mode (including Structures) is fully exercised.
        let smokeModes = ConstructionMode.allCases.filter { $0 != .motherMold }

        var exported: [(ConstructionMode, ExportFormat)] = []
        for mode in smokeModes {
            let formats = ExportFormatSupport.availableFormats(for: mode)
            #expect(!formats.isEmpty)
            for format in formats {
                let url = outputDirectory.appending(path: "\(mode.rawValue).\(format.rawValue)")
                try Self.export(mode: mode, format: format, model: model, to: url)
                try Self.verifySignature(format: format, url: url)
                exported.append((mode, format))
            }
        }

        let expectedCount = smokeModes
            .map { ExportFormatSupport.availableFormats(for: $0).count }
            .reduce(0, +)
        #expect(exported.count == expectedCount)
        return exported
    }

    private static func export(mode: ConstructionMode, format: ExportFormat, model: MeshSummary, to url: URL) throws {
        let materialThickness = 3.0
        let layoutSettings = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 180, sheetHeight: 240)
        let dowels = DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 8)
        // Vector formats go through the app's and the CLI's shared writer.
        func writeFlatParts(_ source: FlatPartExport.Source) throws {
            try FlatPartExport.write(source, format: format, model: model, settings: layoutSettings, to: url)
        }

        switch mode {
        case .stacked:
            let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: materialThickness))
            let contours = StackedSliceContourer.generate(model: model, plan: plan)
            switch format {
            case .dxf, .eps, .pdf, .svg:
                try writeFlatParts(.stacked(plan, contours: contours, dowels: dowels))
            case .obj:
                try ObjExporter.write(contours: contours, materialThickness: plan.materialThickness, to: url)
            case .stl:
                try StlExporter.write(contours: contours, materialThickness: plan.materialThickness, to: url)
            }
        case .interlocked:
            let plan = try #require(InterlockedSlicePlanner.plan(
                model: model,
                primaryAxis: .z,
                secondaryAxis: .x,
                materialThickness: materialThickness,
                slotClearance: 0.15,
                slotAngleDegrees: 15,
                slotRelief: SlotReliefSettings(enabled: true, diameter: 4)
            ))
            switch format {
            case .dxf, .eps, .pdf, .svg:
                try writeFlatParts(.interlocked(plan))
            case .obj:
                try ObjExporter.write(interlocked: plan, model: model, to: url)
            case .stl:
                try StlExporter.write(interlocked: plan, model: model, to: url)
            }
        case .radial:
            let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: materialThickness))
            switch format {
            case .dxf, .eps, .pdf, .svg:
                try writeFlatParts(.radial(plan))
            case .obj:
                try ObjExporter.write(radial: plan, model: model, materialThickness: materialThickness, to: url)
            case .stl:
                try StlExporter.write(radial: plan, model: model, materialThickness: materialThickness, to: url)
            }
        case .curve:
            let plan = try #require(CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10))
            switch format {
            case .dxf, .eps, .pdf, .svg:
                try writeFlatParts(.curve(plan))
            case .obj:
                try ObjExporter.write(curve: plan, model: model, materialThickness: materialThickness, to: url)
            case .stl:
                try StlExporter.write(curve: plan, model: model, materialThickness: materialThickness, to: url)
            }
        case .threeD:
            let plan = try #require(ThreeDSlicePlanner.plan(model: model, materialThickness: materialThickness))
            switch format {
            case .dxf, .eps, .pdf, .svg:
                // 3D Slices is mesh-only; the format picker never offers these.
                throw SmokeError.unsupported(mode, format)
            case .obj:
                try ObjExporter.write(threeD: plan, model: model, to: url)
            case .stl:
                try StlExporter.write(threeD: plan, model: model, to: url)
            }
        case .foldedPanels:
            let plan = FoldedPanelPlanner.plan(model: model)
            switch format {
            case .dxf, .eps, .pdf, .svg:
                try writeFlatParts(.foldedPanels(plan))
            case .obj:
                try ObjExporter.write(folded: plan, materialThickness: materialThickness, to: url)
            case .stl:
                try StlExporter.write(folded: plan, materialThickness: materialThickness, to: url)
            }
        case .inflatables:
            let plan = try InflatablesPlanner.plan(model: model.geometry, settings: .defaultValue)
            switch format {
            case .dxf, .pdf, .svg:
                try writeFlatParts(.inflatables(plan))
            case .obj:
                try ObjExporter.write(meshLayers: InflatablesMeshExportBuilder.layers(plan: plan), to: url, title: "inflatable membrane")
            case .stl:
                try StlExporter.write(meshes: InflatablesMeshExportBuilder.layers(plan: plan).map(\.mesh), to: url, solidName: "refabartist_inflatable_membrane")
            case .eps:
                throw SmokeError.unsupported(mode, format)
            }
        case .structures:
            // Structures = a single watertight infill mesh clipped to the model
            // skin, exported STL/OBJ only (the same SliceMeshExportLayer the
            // viewport renders).
            let settings = StructureSettings(category: .infill, pattern: .triangle)
            let plan = try #require(try StructurePlanner.planThrowing(model: model, settings: settings))
            switch format {
            case .obj:
                try ObjExporter.write(meshLayers: plan.layers, to: url, title: "structures infill")
            case .stl:
                try StlExporter.write(meshes: plan.layers.map(\.mesh), to: url, solidName: "refabartist_structures_infill")
            case .dxf, .eps, .pdf, .svg:
                throw SmokeError.unsupported(mode, format)
            }
        case .partition:
            // Partition = bed-sized watertight pieces, exported STL/OBJ only.
            // Use a combined file here so the single-file signature check applies.
            let plan = try #require(PartitionPlanner.plan(model: model, settings: PartitionSettings.defaultValue))
            switch format {
            case .obj, .stl:
                try PartitionExporter.write(plan: plan, format: format, packaging: .combinedObj, to: url)
            case .dxf, .eps, .pdf, .svg:
                throw SmokeError.unsupported(mode, format)
            }
        case .motherMold:
            // MotherMold = separate watertight casting-mold parts, exported
            // STL/OBJ only via MotherMoldExporter. The scaffold planner returns
            // an empty plan until the engine lands, so the exporter would throw
            // `emptyPlan`; this smoke case is therefore unsupported for now.
            switch format {
            case .obj, .stl:
                throw SmokeError.unsupported(mode, format)
            case .dxf, .eps, .pdf, .svg:
                throw SmokeError.unsupported(mode, format)
            }
        }
    }

    private static func verifySignature(format: ExportFormat, url: URL) throws {
        let data = try Data(contentsOf: url)
        #expect(data.count > 32)
        let text = String(data: data, encoding: .utf8) ?? ""

        switch format {
        case .dxf:
            #expect(text.contains("SECTION"))
            #expect(text.hasSuffix("0\nEOF\n"))
        case .eps:
            // One EPS per sheet; several sheets arrive as a ZIP of them.
            if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
                #expect(data.range(of: Data("%!PS-Adobe".utf8)) != nil)
            } else {
                #expect(text.hasPrefix("%!PS-Adobe"))
                #expect(text.hasSuffix("%%EOF\n"))
            }
        case .obj:
            #expect(text.hasPrefix("# Refab Artist"))
            #expect(text.contains("\nv "))
            #expect(text.contains("\nf "))
        case .pdf:
            #expect(data.prefix(5) == Data("%PDF-".utf8))
            #expect(data.range(of: Data("%%EOF".utf8)) != nil)
        case .stl:
            #expect(text.hasPrefix("solid refabartist_"))
            #expect(text.contains("endsolid refabartist_"))
        case .svg:
            #expect(text.contains("<svg"))
            #expect(text.contains("</svg>"))
        }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private enum SmokeError: Error {
        case unsupported(ConstructionMode, ExportFormat)
    }
}
