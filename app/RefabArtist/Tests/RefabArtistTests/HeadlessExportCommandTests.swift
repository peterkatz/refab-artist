import Foundation
import Testing
@testable import RefabArtist

struct HeadlessExportCommandTests {
    @Test
    func motherMoldKeyCLIUsesArtistFacingNamesAndRejectsUnknownValues() {
        #expect(PartitionKeyType.motherMoldCLIValue("none") == PartitionKeyType.none)
        #expect(PartitionKeyType.motherMoldCLIValue("tapered-round") == .pins)
        #expect(PartitionKeyType.motherMoldCLIValue("tapered-bar") == .dovetail)
        #expect(PartitionKeyType.motherMoldCLIValue("pins") == .pins)
        #expect(PartitionKeyType.motherMoldCLIValue("dovetail") == .dovetail)
        #expect(PartitionKeyType.motherMoldCLIValue("mystery") == nil)
    }

    @Test
    func motherMoldHeadlessRejectsUnknownKeyTypeInsteadOfIgnoringIt() {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "invalid-mothermold-key-\(UUID().uuidString).stl")
        #expect(throws: HeadlessExportError.self) {
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", "mothermold",
                "--format", "stl",
                "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
                "--key-type", "mystery",
                "--output", output.path
            ])
        }
    }

    @Test
    func stackedDxfHeadlessExportWritesMeasurementJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "stacked.dxf")
        let measurement = outputDirectory.appending(path: "stacked.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "stacked",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--axis", "z",
            "--thickness", "5",
            "--output", output.path,
            "--measurement", measurement.path
        ])

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: measurement.path))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "candidate-swift")

        let stackedSlices = try #require(json["stacked_slices"] as? [String: Any])
        #expect(stackedSlices["slice_count"] as? Int == 10)

        let exports = try #require(json["exports"] as? [String: Any])
        let dxf = try #require(exports["dxf"] as? [String: Any])
        #expect(dxf["line_count"] as? Int == 44)
    }

    @Test
    func interlockedSvgHeadlessExportWritesModeMeasurementJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-interlocked-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "interlocked.svg")
        let measurement = outputDirectory.appending(path: "interlocked.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "interlocked",
            "--format", "svg",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--axis", "z",
            "--secondary-axis", "x",
            "--thickness", "5",
            "--slot-clearance", "0.2",
            "--slot-angle", "15",
            "--slot-relief",
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let svgText = try String(contentsOf: output, encoding: .utf8)
        #expect(svgText.contains("<svg"))
        #expect(svgText.contains("</svg>"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mode"] as? String == "interlocked")

        let interlocked = try #require(json["interlocked_slices"] as? [String: Any])
        #expect(interlocked["slice_count"] as? Int == 20)
        #expect(interlocked["slot_count"] as? Int == 200)

        let exports = try #require(json["exports"] as? [String: Any])
        let svg = try #require(exports["svg"] as? [String: Any])
        #expect((svg["byte_count"] as? Int ?? 0) > 32)
    }

    @Test
    func headlessExportSupportsEveryModeAndFormat() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-all-headless-exports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var exportCount = 0
        for mode in ConstructionMode.allCases {
            for format in ExportFormatSupport.availableFormats(for: mode) {
                let output = outputDirectory.appending(path: "\(mode.rawValue).\(format.rawValue)")
                // The default 12 mm pour funnel cannot sit on one half of a
                // centrally parted 50 mm cube (known issue, see
                // MotherMoldArtistUXDefaultsTests); a 10 mm one fits.
                let modeArguments = mode == .motherMold ? ["--spout-diameter-mm", "10"] : []

                try HeadlessExportCommand.run(arguments: [
                    "--headless-export",
                    "--mode", mode.rawValue,
                    "--format", format.rawValue,
                    "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
                    "--axis", "z",
                    "--secondary-axis", "x",
                    "--thickness", "5",
                    "--output", output.path
                ] + modeArguments)

                try Self.verifySignature(format: format, url: output)
                exportCount += 1
            }
        }

        // 5 legacy flat-part modes × 6 formats + Inflatables × 5
        // (DXF/PDF/SVG/STL/OBJ) + 3D Slices × 2 + Structures × 2 +
        // Partition × 2 + MotherMold × 2 (mesh-only modes: STL/OBJ).
        #expect(exportCount == 43)
    }

    @Test
    func foldedPanelsObjHeadlessExportWritesModeMeasurementJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-folded-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "folded.obj")
        let measurement = outputDirectory.appending(path: "folded.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "folded-panels",
            "--format", "obj",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/square_pyramid_ascii.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let objText = try String(contentsOf: output, encoding: .utf8)
        #expect(objText.hasPrefix("# Refab Artist"))
        #expect(objText.contains("\nv "))
        #expect(objText.contains("\nf "))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mode"] as? String == "foldedPanels")

        let folded = try #require(json["folded_panels"] as? [String: Any])
        #expect((folded["panel_count"] as? Int ?? 0) > 0)

        let exports = try #require(json["exports"] as? [String: Any])
        let obj = try #require(exports["obj"] as? [String: Any])
        #expect((obj["byte_count"] as? Int ?? 0) > 32)
    }

    @Test
    func structuresTriangleInfillHeadlessExportWritesMeshAndMeasurementJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-structures-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "structures.stl")
        let measurement = outputDirectory.appending(path: "structures.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "stl",
            "--category", "infill",
            "--pattern", "triangle",
            "--cell-size-mm", "9",
            "--wall-thickness-mm", "1.6",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let stlText = try String(contentsOf: output, encoding: .utf8)
        #expect(stlText.hasPrefix("solid refabartist_structures_infill"))
        #expect(stlText.contains("endsolid refabartist_structures_infill"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mode"] as? String == "structures")
        #expect(json["category"] as? String == "infill")
        #expect(json["pattern"] as? String == "triangle")
        #expect(json["density_source"] as? String == "uniform")
        #expect(json["density_effective_source"] as? String == "uniform")
        #expect(json["density_min_cell_mm"] as? Double == 9)
        #expect(json["density_max_cell_mm"] as? Double == 9)
        #expect(json["density_image_projection"] as? String == "xy")
        #expect(json["density_invert_image"] as? Bool == false)
        #expect(json["density_image_path"] is NSNull)
        #expect(json["density_notice"] is NSNull)
        #expect((json["triangle_count"] as? Int ?? 0) > 0)
        #expect((json["triangleCount"] as? Int ?? 0) == (json["triangle_count"] as? Int ?? -1))
        #expect(json["watertight"] as? Bool == true)
        #expect((json["componentCount"] as? Int ?? 0) > 0)
        let componentVolumes = try #require(json["componentVolumes"] as? [Double])
        #expect(!componentVolumes.isEmpty)
        #expect(componentVolumes == componentVolumes.sorted(by: >))
        #expect(json["subFloorComponentCount"] as? Int == 0)
        #expect(json["preClipDroppedCount"] as? Int == 0)
        #expect(json["preClipDroppedVolume"] as? Double == 0)
        #expect(json["postClipDroppedCount"] as? Int == 0)
        #expect(json["postClipDroppedVolume"] as? Double == 0)
        #expect(json.keys.contains("coarseningNotice"))
        let timings = try #require(json["timings"] as? [String: Any])
        #expect((timings["planningSeconds"] as? Double ?? -1) >= 0)
        #expect((timings["auditSeconds"] as? Double ?? -1) >= 0)
        #expect(json["bounds"] != nil)
    }

    @Test
    func structuresHeadlessExportAcceptsDensityFlagsAndWritesMeasurementJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-structures-density-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "structures-density.stl")
        let measurement = outputDirectory.appending(path: "structures-density.json")
        let image = outputDirectory.appending(path: "density.png")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        try png.write(to: image)

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "stl",
            "--category", "infill",
            "--pattern", "grid",
            "--cell-size-mm", "9",
            "--wall-thickness-mm", "1.6",
            "--density-source", "image",
            "--density-image", image.path,
            "--density-projection", "xz",
            "--invert-density-image",
            "--min-cell-mm", "4",
            "--max-cell-mm", "12",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        #expect(FileManager.default.fileExists(atPath: output.path))
        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mode"] as? String == "structures")
        #expect(json["pattern"] as? String == "grid")
        #expect(json["density_source"] as? String == "image")
        #expect(json["density_effective_source"] as? String == "image")
        #expect(json["density_image_path"] as? String == image.path)
        #expect(json["density_image_projection"] as? String == "xz")
        #expect(json["density_invert_image"] as? Bool == true)
        #expect(json["density_min_cell_mm"] as? Double == 4)
        #expect(json["density_max_cell_mm"] as? Double == 12)
        #expect(json["density_notice"] is NSNull)
        #expect((json["triangle_count"] as? Int ?? 0) > 0)
    }

    @Test
    func structuresSkinCategoryHeadlessExportWritesSkinMetrics() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-structures-skin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "structures-skin.stl")
        let measurement = outputDirectory.appending(path: "structures-skin.json")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "stl",
            "--category", "skin",
            "--skin-style", "struts",
            "--skin-pattern", "voronoi",
            "--cell-size-mm", "12",
            "--strut-diameter-mm", "2",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let stlText = try String(contentsOf: output, encoding: .utf8)
        #expect(stlText.hasPrefix("solid refabartist_structures_skin"))

        let objOutput = outputDirectory.appending(path: "structures-skin.obj")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "obj",
            "--category", "skin",
            "--skin-style", "struts",
            "--skin-pattern", "triangles",
            "--cell-size-mm", "14",
            "--strut-diameter-mm", "1.6",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl").path,
            "--output", objOutput.path
        ])
        let objText = try String(contentsOf: objOutput, encoding: .utf8)
        #expect(objText.hasPrefix("# Refab Artist structures skin mesh export"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["category"] as? String == "skin")
        #expect(json["skin_style"] as? String == "struts")
        #expect(json["skin_pattern"] as? String == "voronoi")
        #expect(json["skin_strut_diameter_mm"] as? Double == 2)
        #expect((json["triangle_count"] as? Int ?? 0) > 0)
        #expect(json["watertight"] as? Bool == true)
        #expect((json["seedCount"] as? Int ?? 0) > 4)
        #expect((json["segmentCount"] as? Int ?? 0) > 0)
        #expect((json["meanSpacing"] as? Double ?? 0) > 0)
        #expect(json["skinComponentCount"] as? Int == 1)
        #expect((json["skinGenus"] as? Int ?? 0) > 0)
    }

    @Test
    func structuresSupportCategoryHeadlessExportWritesSupportMetrics() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-structures-support-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "structures.stl")
        let measurement = outputDirectory.appending(path: "structures.json")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "stl",
            "--category", "support",
            "--support-mode", "sculpture",
            "--target-surface", "up-facing",
            "--surface-angle-deg", "25",
            "--tip-spacing-mm", "18",
            "--tip-diameter-mm", "1.4",
            "--branch-diameter-mm", "4",
            "--preferred-angle-deg", "20",
            "--max-angle-deg", "40",
            "--step-mm", "5",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let stlText = try String(contentsOf: output, encoding: .utf8)
        #expect(stlText.hasPrefix("solid refabartist_structures_support"))

        let objOutput = outputDirectory.appending(path: "structures.obj")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "structures",
            "--format", "obj",
            "--category", "support",
            "--support-mode", "sculpture",
            "--target-surface", "up-facing",
            "--surface-angle-deg", "25",
            "--tip-spacing-mm", "18",
            "--tip-diameter-mm", "1.4",
            "--branch-diameter-mm", "4",
            "--preferred-angle-deg", "20",
            "--max-angle-deg", "40",
            "--step-mm", "5",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", objOutput.path
        ])
        let objText = try String(contentsOf: objOutput, encoding: .utf8)
        #expect(objText.hasPrefix("# Refab Artist structures support mesh export"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["category"] as? String == "support")
        #expect(json["support_mode"] as? String == "sculpture")
        #expect((json["triangle_count"] as? Int ?? 0) > 0)
        #expect(json["watertight"] as? Bool == true)
        #expect((json["tipCoverage"] as? Double ?? 0) >= 0.95)
        #expect((json["targetSampleCount"] as? Int ?? 0) > 0)
        #expect((json["tipCount"] as? Int ?? 0) > 0)
        #expect((json["branchCount"] as? Int ?? 0) > 0)
        #expect((json["maxSlopeDeg"] as? Double ?? 99) <= 42)
        #expect(json["supportComponentsReachPlate"] as? Bool == true)
    }

    @Test
    func threeDHeadlessExportAcceptsSeparateSliceDepth() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-three-d-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "three-d.stl")
        let measurement = outputDirectory.appending(path: "three-d.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "three-d",
            "--format", "stl",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--thickness", "5",
            "--slice-depth", "10",
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let stlText = try String(contentsOf: output, encoding: .utf8)
        #expect(stlText.hasPrefix("solid refabartist_3d_slices"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let threeD = try #require(json["three_d_slices"] as? [String: Any])
        #expect(threeD["slice_count"] as? Int == 15)
        #expect(threeD["slice_depth"] as? Double == 10)

        let x = try #require(threeD["x"] as? [String: Any])
        #expect(x["slice_count"] as? Int == 5)
        #expect(x["material_thickness"] as? Double == 5)
    }

    @Test
    func curveHeadlessExportAcceptsSplineControlPoints() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-curve-spline-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "curve.dxf")
        let measurement = outputDirectory.appending(path: "curve.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "curve",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--axis", "y",
            "--thickness", "5",
            "--first-axis-count", "7",
            "--curve-slice-count", "6",
            "--spline-control-points", "[[-25,0],[-10,20],[10,20],[25,0]]",
            "--output", output.path,
            "--measurement", measurement.path
        ])

        // Curve DXF now routes through the cut-sheet document (so the export
        // carries the interlock slots the preview shows); layers use the
        // document's part labels (C-5 curve slice, Y-4 first-axis slice). In
        // 5 mm stock four of the seven first-axis ribs and five of the six
        // curve ribs fit (the spline's steep ends cross at a slant).
        let dxf = try String(contentsOf: output, encoding: .utf8)
        #expect(dxf.contains("\nC-5\n"))
        #expect(dxf.contains("\nY-4\n"))

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let curve = try #require(json["curve_slices"] as? [String: Any])
        #expect(curve["primary_slice_count"] as? Int == 4)
        #expect(curve["requested_primary_slice_count"] as? Int == 7)
        #expect(curve["curve_slice_count"] as? Int == 5)
        #expect(curve["requested_curve_slice_count"] as? Int == 6)
        #expect(curve["total_part_count"] as? Int == 9)
        #expect((curve["control_points"] as? [[Double]]) == [[-25, 0], [-10, 20], [10, 20], [25, 0]])
        let centers = try #require(curve["centers"] as? [[Double]])
        #expect(centers.count == 5)
        #expect(centers.map { $0[1] }.max()! > 15)
    }

    @Test
    func radialDefaultUsesAppN12() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-regular-radial-default-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "radial-default.dxf")
        let measurement = outputDirectory.appending(path: "radial-default.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "radial",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let radialSlices = try #require(json["radial_slices"] as? [String: Any])
        #expect(radialSlices["slice_count"] as? Int == 12)
        let angles = try #require(radialSlices["angles"] as? [Double])
        #expect(angles.count == 12)
    }

    @Test
    func stackedDxfHeadlessExportAppliesImportUnitsAndScale() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-scaled-headless-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let output = outputDirectory.appending(path: "stacked-scaled.dxf")
        let measurement = outputDirectory.appending(path: "stacked-scaled.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "stacked",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--axis", "z",
            "--thickness", "5",
            "--import-unit", "cm",
            "--scale", "0.5",
            "--output", output.path,
            "--measurement", measurement.path
        ])

        let data = try Data(contentsOf: measurement)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["import_unit"] as? String == "centimeters")
        #expect(settings["scale_factor"] as? Double == 0.5)
        #expect(settings["effective_scale_factor"] as? Double == 5.0)

        let stackedSlices = try #require(json["stacked_slices"] as? [String: Any])
        #expect(stackedSlices["slice_count"] as? Int == 50)

        let mesh = try #require(json["mesh"] as? [String: Any])
        let bounds = try #require(mesh["bounds"] as? [String: Any])
        let max = try #require(bounds["max"] as? [Double])
        #expect(max == [125.0, 125.0, 125.0])
    }

    @Test
    func joineryTypeCLIAcceptsNoneAndMapsSeamToNone() throws {
        #expect(JoineryType.cliValue("none") == .trivial)
        #expect(JoineryType.cliValue("None") == .trivial)
        // Older spellings still parse, as plain edges like a saved Seam.
        #expect(JoineryType.cliValue("seam") == .trivial)
        #expect(JoineryType.cliValue("trivial") == .trivial)
        #expect(JoineryType.cliValue("multi-tab") == nil)
        #expect(JoineryType.cliValue("multitab") == .multitab)

        let message = HeadlessExportError.unsupportedJoineryType("mystery").errorDescription ?? ""
        #expect(message.contains("none"))
        #expect(!message.contains("seam"))
        #expect(!message.contains("trivial"))

        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-folded-none-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appending(path: "folded-none.dxf")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "folded",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--joinery-type", "none",
            "--output", output.path
        ])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func sliceModesRejectArgumentsTheyDoNotRead() throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-unknown-flag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["stacked", "interlocked", "radial", "curve", "threeD", "folded", "inflatables"] {
            // The output's folder does not exist yet, and a mesh dump is asked
            // for: a refused run must create neither.
            let outputFolder = directory.appending(path: "\(mode)-out", directoryHint: .isDirectory)
            let output = outputFolder.appending(path: "parts.\(mode == "threeD" ? "stl" : "dxf")")
            let dump = directory.appending(path: "\(mode)-dump.obj")
            var thrown: Error?
            do {
                try HeadlessExportCommand.run(arguments: [
                    "--headless-export",
                    "--mode", mode,
                    "--format", mode == "threeD" ? "stl" : "dxf",
                    "--fixture", fixture,
                    "--dump-mesh", dump.path,
                    "--slot-relief-diamter", "3",
                    "--output", output.path
                ])
            } catch {
                thrown = error
            }
            let message = (thrown as? HeadlessExportError)?.errorDescription ?? ""
            #expect(message.contains("--slot-relief-diamter 3"), "\(mode): \(message)")
            #expect(!message.contains("--dump-mesh"), "\(mode): \(message)")
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(mode) wrote a file")
            #expect(!FileManager.default.fileExists(atPath: outputFolder.path), "\(mode) made the output folder")
            #expect(!FileManager.default.fileExists(atPath: dump.path), "\(mode) dumped the mesh")
        }
    }

    @Test
    func radialOffsetFlagIsGone() {
        // The app has no fin-offset control, so the CLI has no such flag.
        let output = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-offset-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(throws: HeadlessExportError.self) {
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", "radial",
                "--format", "dxf",
                "--fixture", Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl").path,
                "--radial-offset-degrees", "15",
                "--output", output.path
            ])
        }
    }

    @Test
    func interlockedMeasurementCountsTheReliefActuallyCut() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-interlocked-relief-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path

        func reliefCount(thickness: String, extra: [String]) throws -> Int {
            let output = outputDirectory.appending(path: "relief-\(thickness)-\(extra.count).dxf")
            let measurement = outputDirectory.appending(path: "relief-\(thickness)-\(extra.count).json")
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", "interlocked",
                "--format", "dxf",
                "--fixture", fixture,
                "--thickness", thickness,
                "--slot-relief",
                "--output", output.path,
                "--measurement", measurement.path
            ] + extra)
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: measurement)) as? [String: Any])
            let interlocked = try #require(json["interlocked_slices"] as? [String: Any])
            return try #require(interlocked["slot_relief_circle_count"] as? Int)
        }

        // 5 mm stock on the 5 mm slice spacing: the slots merge, no corners.
        #expect(try reliefCount(thickness: "5", extra: ["--tool-diameter", "4"]) == 0)
        // The older flag is the same tool diameter.
        #expect(try reliefCount(thickness: "5", extra: ["--slot-relief-diameter", "4"]) == 0)
        // 3 mm stock leaves material between the slots: two inside corners
        // per slot, each relieved.
        #expect(try reliefCount(thickness: "3", extra: ["--tool-diameter", "1"]) == 400)
        // No tool, no relief.
        #expect(try reliefCount(thickness: "3", extra: []) == 0)
    }

    /// Structures, Partition and MotherMold read their own flags and, like
    /// the slice modes, refuse what is left before any folder, file or mesh
    /// work.
    @Test(arguments: ["structures", "partition", "mothermold"])
    func everyModeRejectsArgumentsItDoesNotReadBeforeWritingAnything(_ mode: String) throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-unknown-flag-\(mode)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFolder = directory.appending(path: "out", directoryHint: .isDirectory)
        let output = outputFolder.appending(path: "parts.stl")
        let dump = directory.appending(path: "dump.obj")
        var thrown: Error?
        do {
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", mode,
                "--format", "stl",
                "--fixture", fixture,
                "--dump-mesh", dump.path,
                "--wall-thicknes-mm", "2",
                "--output", output.path
            ])
        } catch {
            thrown = error
        }
        let message = (thrown as? HeadlessExportError)?.errorDescription ?? ""
        #expect(message.hasPrefix("Unsupported or incomplete"), "\(mode): \(message)")
        #expect(message.contains("--wall-thicknes-mm 2"), "\(mode): \(message)")
        #expect(!FileManager.default.fileExists(atPath: output.path), "\(mode) wrote a file")
        #expect(!FileManager.default.fileExists(atPath: outputFolder.path), "\(mode) made the output folder")
        #expect(!FileManager.default.fileExists(atPath: dump.path), "\(mode) dumped the mesh")
    }

    /// Under a Slice Direction tilt the CLI cuts every part from the model
    /// its plan was laid out on, turned into the slicing frame, as the app
    /// does: the file is byte for byte the one the app's calls write.
    @Test(arguments: ["interlocked", "radial", "curve"])
    func tiltedExportsAreTheAppsBytes(_ mode: String) throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/primitives/torus_R30_r10mm.stl")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-tilt-\(mode)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func cli(_ tilt: [String]) throws -> Data {
            let output = directory.appending(path: "\(mode)-cli-\(tilt.count).dxf")
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", mode,
                "--format", "dxf",
                "--fixture", fixture.path,
                "--thickness", "3",
                "--output", output.path
            ] + tilt)
            return try Data(contentsOf: output)
        }
        let tilted = try cli(["--slice-tilt-first", "20", "--slice-tilt-second", "10"])

        // The app: `planningModel`, the plan and the cut sheet on it, and
        // `FlatPartExport` with that cut sheet (`exportCurrent`).
        let model = try MeshInspector.inspect(url: fixture)
        let planning = ViewportGeometryCache.shared.transformedModel(
            for: model,
            scale: Vec3(x: 1, y: 1, z: 1),
            rotationDegrees: SliceDirection.meshRotationDegrees(axis: .z, tiltFirst: 20, tiltSecond: 10)
        )
        let source: FlatPartExport.Source
        switch mode {
        case "interlocked":
            source = .interlocked(try #require(InterlockedSlicePlanner.plan(
                model: planning, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3, slotClearance: 0,
                notchWidthOverride: nil, slotAngleDegrees: 0, slotRelief: SlotReliefSettings(enabled: false, diameter: 0),
                sliceCountOverride: nil
            )))
        case "radial":
            source = .radial(try #require(RadialSlicePlanner.plan(model: planning, nRadial: 12, materialThickness: 3)))
        default:
            let laidOut = try #require(CurveSlicePlanner.plan(
                model: planning, primaryAxis: .z, materialThickness: 3, firstAxisCount: 7, curveSliceCount: 12,
                amplitude: 10, slotWidth: 3, slotAngleDegrees: 0
            ))
            source = .curve(ViewportGeometryCache.shared.joinedCurvePlan(for: laidOut, model: planning))
        }
        let settings = ExportLayoutSettings.defaultValue.sanitized
        let document = FlatPartExport.cutSheetDocument(for: source, model: planning, settings: settings, revision: 3)
        let app = directory.appending(path: "\(mode)-app.dxf")
        _ = try FlatPartExport.write(source, format: .dxf, model: planning, settings: settings, cutSheet: { document }, to: app)
        #expect(tilted == (try Data(contentsOf: app)), "\(mode)")
        // The tilt is cut, not ignored.
        #expect(tilted != (try cli([])), "\(mode)")
    }

    /// Under a Slice Direction tilt the parts are cut from the model turned
    /// into the slicing frame, and their part frames turn them back onto the
    /// model as imported: every corner the DXF draws, put back through its
    /// part's frame, lies in the torus file's own tube (radius 10 mm about
    /// its 30 mm centre circle). Frames left in the slicing frame put
    /// corners up to 19 mm off the torus's mid-plane. (Interlocked parts
    /// carry no frame.)
    @Test(arguments: ["radial", "curve"])
    func tiltedPartFramesPutThePartsBackInTheModelAsImported(_ mode: String) throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/primitives/torus_R30_r10mm.stl")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-tilt-frames-\(mode)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dxf = directory.appending(path: "parts.dxf")
        let framesURL = directory.appending(path: "parts.frames.json")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", mode,
            "--format", "dxf",
            "--fixture", fixture.path,
            "--thickness", "3",
            "--slice-tilt-first", "20",
            "--slice-tilt-second", "10",
            "--output", dxf.path,
            "--part-frames", framesURL.path
        ])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: framesURL)) as? [String: Any])
        let frames = try #require(json["parts"] as? [[String: Any]])
        let corners = Self.dxfLineStarts(try String(contentsOf: dxf, encoding: .utf8))
        let bounds = try #require(try MeshInspector.inspect(url: fixture).bounds)
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        var checked = 0
        for entry in frames {
            let label = try #require(entry["label"] as? String)
            let rows = try #require(entry["dxfToModel"] as? [[Double]])
            for point in corners[label] ?? [] {
                let x = rows[0][0] * point.x + rows[0][1] * point.y + rows[0][2] - center.x
                let y = rows[1][0] * point.x + rows[1][1] * point.y + rows[1][2] - center.y
                let z = rows[2][0] * point.x + rows[2][1] * point.y + rows[2][2] - center.z
                let ring = (x * x + y * y).squareRoot() - 30
                // The mesh's flat facets stand a little inside and, on the
                // hole side, a little outside the round tube.
                #expect((ring * ring + z * z).squareRoot() <= 10.25, "\(mode) \(label) (\(x), \(y), \(z))")
                checked += 1
            }
        }
        #expect(checked > 100, "\(mode)")
    }

    /// The start of every `LINE` the DXF draws, by layer.
    private static func dxfLineStarts(_ text: String) -> [String: [Vec2]] {
        let rows = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [String: [Vec2]] = [:]
        var index = 0
        while index + 1 < rows.count {
            guard rows[index] == "0", rows[index + 1] == "LINE" else {
                index += 2
                continue
            }
            var layer = ""
            var x = 0.0
            var y = 0.0
            var cursor = index + 2
            while cursor + 1 < rows.count, rows[cursor] != "0" {
                switch rows[cursor] {
                case "8": layer = rows[cursor + 1]
                case "10": x = Double(rows[cursor + 1]) ?? 0
                case "20": y = Double(rows[cursor + 1]) ?? 0
                default: break
                }
                cursor += 2
            }
            result[layer, default: []].append(Vec2(x: x, y: y))
            index = cursor
        }
        return result
    }

    /// Radial and Curve OBJ and STL solids are as thick as the stock, as the
    /// app writes them, not as wide as the slots.
    @Test(arguments: ["radial", "curve"], [ExportFormat.obj, .stl])
    func meshExportsAreTheAppsBytes(_ mode: String, _ format: ExportFormat) throws {
        let fixture = Self.repoRoot().appending(path: "tests/fixtures/primitives/torus_R30_r10mm.stl")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-mesh-\(mode)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A slot offset, so the slots (3.4 mm) are wider than the stock (3 mm).
        let output = directory.appending(path: "\(mode)-cli.\(format.rawValue)")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", mode,
            "--format", format.rawValue,
            "--fixture", fixture.path,
            "--thickness", "3",
            "--slot-clearance", "0.4",
            "--output", output.path
        ])

        // The app's calls (`exportCurrent`), with Thickness 3 mm.
        let model = try MeshInspector.inspect(url: fixture)
        let app = directory.appending(path: "\(mode)-app.\(format.rawValue)")
        if mode == "radial" {
            let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3, slotClearance: 0.4))
            #expect(plan.slotWidth > 3.3)
            if format == .obj {
                try ObjExporter.write(radial: plan, model: model, materialThickness: 3, to: app)
            } else {
                try StlExporter.write(radial: plan, model: model, materialThickness: 3, to: app)
            }
        } else {
            let laidOut = try #require(CurveSlicePlanner.plan(
                model: model, primaryAxis: .z, materialThickness: 3, firstAxisCount: 7, curveSliceCount: 12,
                amplitude: 10, slotWidth: 3.4, slotAngleDegrees: 0
            ))
            let plan = ViewportGeometryCache.shared.joinedCurvePlan(for: laidOut, model: model)
            if format == .obj {
                try ObjExporter.write(curve: plan, model: model, materialThickness: 3, to: app)
            } else {
                try StlExporter.write(curve: plan, model: model, materialThickness: 3, to: app)
            }
        }
        #expect(try Data(contentsOf: output) == Data(contentsOf: app), "\(mode) \(format.rawValue)")
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            #expect(text.hasPrefix("%!PS-Adobe"))
            #expect(text.hasSuffix("%%EOF\n"))
        case .obj:
            #expect(text.hasPrefix("# Refab Artist"))
            #expect(text.contains("\nv "))
            #expect(text.contains("\nf "))
        case .pdf:
            #expect(data.starts(with: Array("%PDF-".utf8)))
            #expect(data.suffix(6) == Array("%%EOF\n".utf8) || data.suffix(5) == Array("%%EOF".utf8))
        case .stl:
            #expect(text.hasPrefix("solid refabartist_"))
            #expect(text.contains("endsolid refabartist_"))
        case .svg:
            #expect(text.contains("<svg"))
            #expect(text.contains("</svg>"))
        }
    }
}
