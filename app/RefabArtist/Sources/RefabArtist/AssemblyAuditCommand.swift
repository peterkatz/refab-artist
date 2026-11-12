import Foundation

/// Headless ASSEMBLY validity audit (`--assembly-audit`): builds the same
/// plans the exports use (HeadlessExportCommand.buildExport) and the same
/// CutSheetDocument the GUI/SVG/PDF show, then reports the assembly-breaking
/// conditions per part population:
///
/// - severed:  a slot/notch disconnects a part's material (the sheet's red
///             "Notches split part" fill) — the part falls into pieces at
///             the cutter.
/// - detached: a part has no connection to the rest of the assembly (the
///             sheet's blue fill) — it falls off the finished build.
/// - overflow: a part exceeds the stock sheet — it cannot be cut at all.
///
/// These are NECESSARY conditions for an assemblable output (not yet
/// sufficient — joint pairing/connectivity analysis is tracked separately),
/// and none of them were gated before: the functional gate checked flat-part
/// geometry (fits/overlap/self-intersection/biscuits) but never assembly.
///
/// Output: one JSON object on stdout.
enum AssemblyAuditCommand {
    struct Report: Codable {
        var mode: String
        var fixture: String
        var sheets: Int
        var parts: Int
        var severed: Int
        var detached: Int
        var overflow: Int
        var assemblable: Bool
        var severedLabels: [String]
        var detachedLabels: [String]
    }

    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--assembly-audit")

        let modeValue = parser.takeValue("--mode") ?? "stacked"
        guard let mode = ConstructionMode.cliValue(modeValue) else {
            throw HeadlessExportError.unsupportedMode(modeValue)
        }
        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        let thickness = parser.takeDouble("--thickness") ?? 3
        let axisValue = parser.takeValue("--axis") ?? "z"
        guard let axis = SliceAxis(rawValue: axisValue) else {
            throw HeadlessExportError.unsupportedAxis(axisValue)
        }
        let secondaryAxisValue = parser.takeValue("--secondary-axis") ?? "x"
        guard let secondaryAxis = SliceAxis(rawValue: secondaryAxisValue) else {
            throw HeadlessExportError.unsupportedAxis(secondaryAxisValue)
        }
        // GUI-like defaults: the audit answers "is what the APP shows
        // assemblable", so layout and parameters mirror the app's defaults.
        let layoutSettings = ExportLayoutSettings(
            partSpacing: parser.takeDouble("--part-spacing") ?? ExportLayoutSettings.defaultValue.partSpacing,
            pageMargin: parser.takeDouble("--page-margin") ?? ExportLayoutSettings.defaultValue.pageMargin,
            sheetWidth: parser.takeDouble("--sheet-width") ?? 600,
            sheetHeight: parser.takeDouble("--sheet-height") ?? 300
        )

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let rawModel = try MeshInspector.inspect(url: fixtureURL)
        let importUnitValue = parser.takeValue("--import-unit") ?? ImportUnitPreset.millimeters.rawValue
        guard let importUnit = ImportUnitPreset.cliValue(importUnitValue) else {
            throw HeadlessExportError.unsupportedImportUnit(importUnitValue)
        }
        let importUpAxisValue = parser.takeValue("--import-up-axis") ?? ImportUpAxis.z.rawValue
        guard let importUpAxis = ImportUpAxis(rawValue: importUpAxisValue) else {
            throw HeadlessExportError.unsupportedImportUpAxis(importUpAxisValue)
        }
        let scale = parser.takeDouble("--scale") ?? 1
        let scaledModel = MeshScaler.scaled(rawModel, factor: MeshScaler.combinedFactor(unit: importUnit, userScale: scale))
        var model = importUpAxis.orientedModel(scaledModel)
        // Match the GUI's Shrinkwrap state when measuring "what the app shows".
        if let detail = parser.takeDouble("--shrinkwrap"), detail.isFinite, detail >= 0 {
            model = MeshModifier.shrinkwrap(model, detail: detail)
        }

        let export = try HeadlessExportCommand.buildExport(
            mode: mode,
            model: model,
            axis: axis,
            secondaryAxis: secondaryAxis,
            materialThickness: thickness,
            sliceDepth: parser.takeDouble("--slice-depth"),
            slotClearance: parser.takeDouble("--slot-clearance") ?? 0,
            notchWidth: parser.takeDouble("--notch-width"),
            slotAngle: parser.takeDouble("--slot-angle") ?? 0,
            slotRelief: SlotReliefSettings(enabled: false, diameter: 4),
            sliceCount: parser.takeDouble("--slice-count").map(Int.init),
            firstAxisCount: parser.takeDouble("--first-axis-count").map(Int.init),
            curveSliceCount: parser.takeDouble("--curve-slice-count").map(Int.init),
            amplitude: parser.takeDouble("--amplitude") ?? 10,
            splineControlPoints: nil,
            foldedTargetFaces: parser.takeDouble("--folded-target-faces").map(Int.init) ?? 250,
            // As the app does: every Folded net fits the usable sheet.
            foldedNetExtent: Vec2(
                x: layoutSettings.sanitized.sheetWidth - layoutSettings.sanitized.pageMargin * 2,
                y: layoutSettings.sanitized.sheetHeight - layoutSettings.sanitized.pageMargin * 2
            )
        )

        let document = FlatPartExport.cutSheetDocument(
            for: export.flatPartSource,
            model: model,
            settings: layoutSettings,
            revision: 1
        )

        let parts = document.sheets.flatMap(\.parts)
        // --dump-cutsheet <path>: write each placed part's cut geometry (the
        // EXACT CutSheetDocument the GUI shows) so a Python pass can measure
        // fragmentation (multiple outer loops) and slot-overrun (a hole/open cut
        // outside the outer) on what the user actually sees.
        if let dumpPath = parser.takeValue("--dump-cutsheet") {
            var s = ""
            for part in parts {
                s += "PART \(part.label) err=\(part.isError ? 1 : 0) det=\(part.isDetached ? 1 : 0)\n"
                for loop in part.cutLoops {
                    s += "LOOP\n"
                    for p in loop { s += "v \(p.x) \(p.y)\n" }
                }
                for path in part.openCuts {
                    s += "OPEN\n"
                    for p in path { s += "v \(p.x) \(p.y)\n" }
                }
                for path in part.foldLines {
                    s += "FOLD\n"
                    for p in path { s += "v \(p.x) \(p.y)\n" }
                }
            }
            try s.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
        }
        let severed = parts.filter(\.isError)
        let detached = parts.filter(\.isDetached)
        let overflow = parts.filter(\.overflowsSheet)
        let report = Report(
            mode: modeValue,
            fixture: fixtureURL.lastPathComponent,
            sheets: document.sheets.count,
            parts: parts.count,
            severed: severed.count,
            detached: detached.count,
            overflow: overflow.count,
            assemblable: severed.isEmpty && detached.isEmpty && overflow.isEmpty && !parts.isEmpty,
            severedLabels: severed.map(\.label).sorted(),
            detachedLabels: detached.map(\.label).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
