import CryptoKit
import Dispatch
import Foundation

enum HeadlessExportError: LocalizedError {
    case missingValue(String)
    case unsupportedMode(String)
    case unsupportedFormat(String)
    case unsupportedAxis(String)
    case unsupportedImportUnit(String)
    case unsupportedImportUpAxis(String)
    case unsupportedJoineryType(String)
    case unsupportedReliefType(String)
    case invalidThickness(String)
    case invalidSliceDepth(String)
    case invalidScale(String)
    case invalidSplineControlPoints(String)
    case missingFixture
    case missingOutput
    case planningFailed
    case unsupportedStructureCategory(String)
    case unsupportedInfillPattern(String)
    case unsupportedDensitySource(String)
    case unsupportedDensityProjection(String)
    case structuresEngineFailed(String)
    case unsupportedMoldSubtype(String)
    case unsupportedMoldPartCount(String)
    case unconsumedMotherMoldArguments([String])
    case motherMoldEngineFailed(String)
    case unsupportedPartitionPurpose(String)
    case invalidUndercutSetting(flag: String, value: String)
    case unsupportedUndercutQuality(String)
    case unsupportedUndercutPull(String)
    case unsupportedUndercutPriority(String)
    case unsupportedUndercutOutput(String)
    case unconsumedPartitionArguments([String])
    case unconsumedArguments(mode: String, [String])
    case invalidOpeningChoice(String)
    case partFramesNeedCutSheet(String)

    var errorDescription: String? {
        switch self {
        case .partFramesNeedCutSheet(let format):
            return "--part-frames needs an export that knows where its parts sit in the model (the cut sheet, or Radial's DXF); this mode's \(format) does not"
        case .invalidOpeningChoice(let why):
            return "Invalid per-opening choice: \(why)"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .unsupportedMode(let mode):
            return "Unsupported headless export mode: \(mode)"
        case .unsupportedFormat(let format):
            return "Unsupported headless export format: \(format)"
        case .unsupportedAxis(let axis):
            return "Unsupported slice axis: \(axis)"
        case .unsupportedImportUnit(let unit):
            return "Unsupported import unit: \(unit)"
        case .unsupportedImportUpAxis(let axis):
            return "Unsupported import up-axis: \(axis)"
        case .unsupportedJoineryType(let value):
            let valid = JoineryType.menuOrder.map(\.cliName).joined(separator: ", ")
            return "Unsupported folded joinery type: \(value). Valid: \(valid)"
        case .unsupportedReliefType(let value):
            let valid = RadialReliefType.allCases.map(\.cliValue).joined(separator: ", ")
            return "Unsupported relief type: \(value). Valid: \(valid)"
        case .invalidThickness(let value):
            return "Invalid material thickness: \(value)"
        case .invalidSliceDepth(let value):
            return "Invalid slice depth: \(value)"
        case .invalidScale(let value):
            return "Invalid scale factor: \(value)"
        case .invalidSplineControlPoints(let value):
            return "Invalid spline control points: \(value). Expected JSON like [[-25,0],[0,20],[25,0]] or semicolon pairs like -25,0;0,20;25,0"
        case .missingFixture:
            return "--fixture is required"
        case .missingOutput:
            return "--output is required"
        case .planningFailed:
            return "Could not build a slice plan for the fixture"
        case .unsupportedStructureCategory(let value):
            let valid = StructureCategory.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported structure category: \(value). Valid: \(valid)"
        case .unsupportedInfillPattern(let value):
            let valid = InfillPattern.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported infill pattern: \(value). Valid: \(valid)"
        case .unsupportedDensitySource(let value):
            let valid = StructureDensitySource.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported density source: \(value). Valid: \(valid)"
        case .unsupportedDensityProjection(let value):
            let valid = DensityImageProjection.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported density projection: \(value). Valid: \(valid)"
        case .structuresEngineFailed(let message):
            return message
        case .unsupportedMoldSubtype(let value):
            let valid = MoldSubtype.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported mold subtype: \(value). Valid: \(valid)"
        case .unsupportedMoldPartCount(let value):
            let valid = MoldPartCount.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported mold part count: \(value). Valid: \(valid)"
        case .unconsumedMotherMoldArguments(let arguments):
            return "Unsupported or incomplete MotherMold arguments: \(arguments.joined(separator: " "))"
        case .motherMoldEngineFailed(let message):
            return message
        case .unsupportedPartitionPurpose(let value):
            return "Unsupported Partition purpose: \(value)"
        case .invalidUndercutSetting(let flag, let value):
            return "Invalid \(flag) value: \(value)"
        case .unsupportedUndercutQuality(let value):
            return "Unsupported undercut quality: \(value) (use quick, standard, or thorough)"
        case .unsupportedUndercutPull(let value):
            return "Unsupported undercut pull: \(value) (use auto, x, y, z, or NX,NY,NZ)"
        case .unsupportedUndercutPriority(let value):
            return "Unsupported undercut priority: \(value) (use fewer, balanced, or cleaner)"
        case .unsupportedUndercutOutput(let value):
            return "Unsupported undercut output: \(value) (use separate-stl-zip or named-obj-zip)"
        case .unconsumedPartitionArguments(let arguments):
            return "Unsupported or incomplete Partition arguments: \(arguments.joined(separator: " "))"
        case .unconsumedArguments(let mode, let arguments):
            return "Unsupported or incomplete \(mode) arguments: \(arguments.joined(separator: " "))"
        }
    }
}

enum HeadlessExportCommand {
    struct MotherMoldApprovalRequirement: Equatable {
        var signature: String
        var regions: [MasterModificationRegion]
    }

    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--headless-export")

        let modeValue = parser.takeValue("--mode") ?? "stacked"
        guard let mode = ConstructionMode.cliValue(modeValue) else {
            throw HeadlessExportError.unsupportedMode(modeValue)
        }

        let formatValue = parser.takeValue("--format")
            ?? (mode == .motherMold ? ExportFormat.stl.rawValue : "dxf")
        guard let format = ExportFormat(rawValue: formatValue.lowercased()) else {
            throw HeadlessExportError.unsupportedFormat(formatValue)
        }

        let explicitAxisValue = parser.takeValue("--axis")
        let explicitAxis: SliceAxis?
        if let explicitAxisValue {
            guard let parsedAxis = SliceAxis(rawValue: explicitAxisValue) else {
                throw HeadlessExportError.unsupportedAxis(explicitAxisValue)
            }
            explicitAxis = parsedAxis
        } else {
            explicitAxis = nil
        }

        let thicknessValue = parser.takeValue("--thickness") ?? "5"
        guard let thickness = Double(thicknessValue), thickness.isFinite, thickness > 0 else {
            throw HeadlessExportError.invalidThickness(thicknessValue)
        }
        let sliceDepth: Double?
        if let sliceDepthValue = parser.takeValue("--slice-depth") {
            guard let parsedSliceDepth = Double(sliceDepthValue), parsedSliceDepth.isFinite, parsedSliceDepth > 0 else {
                throw HeadlessExportError.invalidSliceDepth(sliceDepthValue)
            }
            sliceDepth = parsedSliceDepth
        } else {
            sliceDepth = nil
        }

        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        guard let outputPath = parser.takeValue("--output") else {
            throw HeadlessExportError.missingOutput
        }

        let measurementPath = parser.takeValue("--measurement")
        // --part-frames <path>: also write where each exported part sits in
        // the model as imported, under a Slice Direction tilt too
        // (CutSheetDocumentExporter.writePartFrames, or
        // DxfExporter.writePartFrames(radial:) for Radial's DXF).
        let partFramesPath = parser.takeValue("--part-frames")
        let importUnitValue = parser.takeValue("--import-unit") ?? ImportUnitPreset.millimeters.rawValue
        guard let importUnit = ImportUnitPreset.cliValue(importUnitValue) else {
            throw HeadlessExportError.unsupportedImportUnit(importUnitValue)
        }
        let importUpAxisValue = parser.takeValue("--import-up-axis") ?? ImportUpAxis.z.rawValue
        guard let importUpAxis = ImportUpAxis(rawValue: importUpAxisValue) else {
            throw HeadlessExportError.unsupportedImportUpAxis(importUpAxisValue)
        }
        let scaleValue = parser.takeValue("--scale") ?? "1"
        guard let scale = Double(scaleValue), scale.isFinite, scale > 0 else {
            throw HeadlessExportError.invalidScale(scaleValue)
        }
        let sheetWidth = parser.takeDouble("--sheet-width")
        let sheetHeight = parser.takeDouble("--sheet-height")
        let layoutSettings = ExportLayoutSettings(
            partSpacing: parser.takeDouble("--part-spacing") ?? ExportLayoutSettings.defaultValue.partSpacing,
            pageMargin: parser.takeDouble("--page-margin") ?? ExportLayoutSettings.defaultValue.pageMargin,
            sheetWidth: sheetWidth ?? ExportLayoutSettings.defaultValue.sheetWidth,
            sheetHeight: sheetHeight ?? ExportLayoutSettings.defaultValue.sheetHeight
        )
        let slotClearance = parser.takeDouble("--slot-clearance") ?? 0
        let notchWidth = parser.takeDouble("--notch-width")
        let slotAngle = parser.takeDouble("--slot-angle") ?? 0
        let sliceCount = parser.takeDouble("--slice-count").map(Int.init)
        // NEO-103: Custom slice positions override. Accepts a comma-separated
        // list of axis positions in mm, e.g. --slice-positions "-20,-10,0,10,20".
        // When absent the planner falls back to automatic/by-count.
        let slicePositionsOverride: [Double]?
        if let raw = parser.takeValue("--slice-positions"), !raw.isEmpty {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            slicePositionsOverride = parts.isEmpty ? nil : parts
        } else {
            slicePositionsOverride = nil
        }
        // Radial wedge count. `--n-radial 0` is the valid
        // degrade-to-Interlocked case and must survive the Int conversion.
        // The default is 12, as in the app.
        let nRadial = parser.takeDouble("--n-radial").map(Int.init)
        let curveSliceCount = parser.takeDouble("--curve-slice-count").map(Int.init)
        let firstAxisCount = parser.takeDouble("--first-axis-count").map(Int.init)
        let amplitude = parser.takeDouble("--amplitude") ?? 10
        let splineControlPointsValue = parser.takeValue("--spline-control-points")
        let splineControlPoints: [Vec2]?
        if let splineControlPointsValue {
            guard let parsed = parseSplineControlPoints(splineControlPointsValue) else {
                throw HeadlessExportError.invalidSplineControlPoints(splineControlPointsValue)
            }
            splineControlPoints = parsed
        } else {
            splineControlPoints = nil
        }
        let secondaryAxisValue = parser.takeValue("--secondary-axis") ?? "x"
        guard let secondaryAxis = SliceAxis(rawValue: secondaryAxisValue) else {
            throw HeadlessExportError.unsupportedAxis(secondaryAxisValue)
        }
        // One tool diameter, as in the app's Manufacturing Settings: it sizes
        // the slot relief of every mode that cuts it (Interlocked
        // --slot-relief, Radial --relief-type). 0 cuts no relief.
        // --slot-relief-diameter is the older Interlocked-only spelling;
        // --tool-diameter wins when both are given.
        let slotReliefEnabled = parser.takeFlag("--slot-relief")
        let legacySlotReliefDiameter = parser.takeDouble("--slot-relief-diameter")
        let toolDiameter = parser.takeDouble("--tool-diameter") ?? legacySlotReliefDiameter ?? 0
        let slotRelief = SlotReliefSettings(enabled: slotReliefEnabled, diameter: toolDiameter)
        // Radial Slices relief at the notch and slot corners, for a tool of
        // this diameter. Square (no relief) unless asked for.
        let reliefTypeValue = parser.takeValue("--relief-type")
        let reliefType: RadialReliefType
        if let reliefTypeValue {
            guard let parsed = RadialReliefType.cliValue(reliefTypeValue) else {
                throw HeadlessExportError.unsupportedReliefType(reliefTypeValue)
            }
            reliefType = parsed
        } else {
            reliefType = .square
        }

        // Folded Panels joinery type. Defaults to .tab, the engine default.
        // Unknown values fail loudly so a typo doesn't silently fall back.
        // Folded dense-mesh simplification target (the GUI's Detail slider).
        // No default here: existing headless exports stay unchanged unless a
        // case opts in explicitly.
        let foldedTargetFaces = parser.takeDouble("--folded-target-faces").map(Int.init)
        // Slice Direction fine-tune (degrees) about the primary axis's two
        // perpendicular axes; defaults 0 keep existing exports unchanged.
        let sliceTiltFirst = parser.takeDouble("--slice-tilt-first") ?? 0
        let sliceTiltSecond = parser.takeDouble("--slice-tilt-second") ?? 0
        let joineryRaw = parser.takeValue("--joinery-type")
        let joineryType: JoineryType
        if let raw = joineryRaw {
            guard let parsed = JoineryType.cliValue(raw) else {
                throw HeadlessExportError.unsupportedJoineryType(raw)
            }
            joineryType = parsed
        } else {
            joineryType = .tab
        }

        // The mesh pre-processing flags, applied below in this order. Read
        // here so the slice modes can refuse what they do not read before
        // any directory or file is written.
        let thickenValue = parser.takeDouble("--modify-thicken")
        let hollowValue = parser.takeDouble("--modify-hollow")
        let diagnoseSites = parser.takeFlag("--diagnose-sites")
        let shrinkwrapDetail = parser.takeDouble("--shrinkwrap")
        let leaveOpenArg = parser.takeValue("--leave-open")
        let openingHeightArg = parser.takeValue("--opening-height")
        let closedOpeningArg = parser.takeValue("--closed-opening")
        let makeWallsThickness = parser.takeDouble("--make-walls")
        let closeOpeningsHeight = parser.takeDouble("--close-openings")
        let dumpPath = parser.takeValue("--dump-mesh")

        // Every mode reads its own flags here and rejects what is left
        // rather than silently ignore it, before anything is written or
        // computed: a typo, or a flag another mode or command reads.
        var structureSettings: StructureSettings?
        var partitionRequest: PartitionRequest?
        var motherMoldSettings: MotherMoldSettings?
        switch mode {
        case .structures:
            structureSettings = try parseStructureSettings(parser: &parser)
            try parser.requireNoRemainingArguments(mode: mode)
        case .partition:
            partitionRequest = try parsePartitionRequest(parser: &parser, outputURL: URL(fileURLWithPath: outputPath))
            try parser.requireNoRemainingPartitionArguments()
        case .motherMold:
            motherMoldSettings = try parseMotherMoldSettings(parser: &parser, format: format)
            try parser.requireNoRemainingMotherMoldArguments()
        case .stacked, .interlocked, .radial, .curve, .threeD, .foldedPanels, .inflatables:
            try parser.requireNoRemainingArguments(mode: mode)
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let rawModel = try MeshInspector.inspect(url: fixtureURL)
        let effectiveScaleFactor = MeshScaler.combinedFactor(unit: importUnit, userScale: scale)
        let scaledModel = MeshScaler.scaled(rawModel, factor: effectiveScaleFactor)
        let importedModel = importUpAxis.orientedModel(scaledModel)

        // NEO-108: --modify-thicken / --modify-hollow pre-slice flags.
        // Absent (no flag) = no modification = existing exports unchanged.
        // At most one flag is honoured; --modify-thicken takes precedence when
        // both are somehow supplied (document the precedence so it's not a
        // silent footgun).
        var model: MeshSummary
        if let thickenMm = thickenValue, thickenMm.isFinite, thickenMm > 0 {
            model = MeshModifier.thicken(importedModel, amount: thickenMm)
        } else if let hollowMm = hollowValue, hollowMm.isFinite, hollowMm > 0 {
            model = MeshModifier.hollow(importedModel, wallThickness: hollowMm)
        } else {
            model = importedModel
        }
        // --diagnose-sites: print the diagnosis and every problem site the
        // viewport's issue markers show (kind, position, size, what Fix in
        // place does), then stop — nothing is exported.
        if diagnoseSites {
            let started = Date()
            guard let diagnosis = OpeningCapper.diagnose(model.geometry) else {
                print("diagnosis: no surface to diagnose.")
                return
            }
            print(String(format: "diagnosis (%.2fs): %@", Date().timeIntervalSince(started), diagnosis.sentence))
            print("sites: \(diagnosis.sites.count)\(diagnosis.sitesOmitted > 0 ? " (+\(diagnosis.sitesOmitted) more not listed)" : "")")
            for site in diagnosis.sites {
                print(String(
                    format: "  %@ %@ at (%.2f, %.2f, %.2f) size=%.2fmm n=%d%@ — %@ — %@",
                    site.id, site.kind.rawValue, site.position.x, site.position.y, site.position.z,
                    site.sizeMM, site.elementCount, site.fixableInPlace ? "" : " [not fixable in place]",
                    site.title, site.fixDescription
                ))
            }
            return
        }
        // --shrinkwrap <detail 0..1>: rewrap to a watertight surface before
        // slicing, matching the GUI's Shrinkwrap tool. Diagnostic/parity hook so
        // headless reproduces the exact contours the user sees with Shrinkwrap on.
        if let detail = shrinkwrapDetail, detail.isFinite, detail >= 0 {
            let started = Date()
            do {
                let (rebuilt, receipt) = try MeshModifier.rebuildAsSolid(model, detail: detail)
                model = rebuilt
                print(String(format: "rebuild (%.2fs): %@", Date().timeIntervalSince(started), receipt))
            } catch let error as MeshModifier.RebuildError {
                print(String(format: "rebuild (%.2fs): %@", Date().timeIntervalSince(started), error.userMessage))
            }
            let p = model.preflight
            print("result: tris=\(model.triangleCount) open-edges=\(p.boundaryEdgeCount) non-manifold=\(p.nonManifoldEdgeCount) manifold=\(p.manifoldValidated)")
        }
        // Per-opening choices (Make Watertight): --leave-open <list>,
        // --opening-height <item=mm,...> (Fix in place) and --closed-opening
        // <list> (Make walls). An item is a 1-based opening number in
        // diagnosis order (as --diagnose-sites / the panel list them) or a
        // signature "cx:cy:cz:d[:nx:ny:nz]" (mm). Numbers are turned into the
        // opening's signature here, so the engine matches them the way the
        // app matches saved choices.
        var openingChoices: [OpeningCapper.OpeningChoice] = []
        if leaveOpenArg != nil || openingHeightArg != nil || closedOpeningArg != nil {
            guard let diagnosis = OpeningCapper.diagnose(model.geometry) else {
                throw HeadlessExportError.invalidOpeningChoice("no surface to diagnose")
            }
            for (i, opening) in diagnosis.openings.enumerated() {
                print(String(format: "opening %d: %@ centre=(%.3f, %.3f, %.3f) d=%.3f normal=(%.3f, %.3f, %.3f)",
                             i + 1, opening.label(number: i + 1), opening.center.x, opening.center.y, opening.center.z,
                             opening.diameter, opening.normal.x, opening.normal.y, opening.normal.z))
            }
            func signature(_ token: String) throws -> OpeningCapper.OpeningSignature {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let n = Int(t) {
                    guard n >= 1, n <= diagnosis.openings.count else {
                        throw HeadlessExportError.invalidOpeningChoice("opening \(n) does not exist (the model has \(diagnosis.openings.count))")
                    }
                    return diagnosis.openings[n - 1].signature
                }
                let v = t.split(separator: ":").compactMap { Double($0) }
                guard v.count == 4 || v.count == 7 else {
                    throw HeadlessExportError.invalidOpeningChoice("bad opening '\(t)': use a number or cx:cy:cz:d[:nx:ny:nz]")
                }
                return OpeningCapper.OpeningSignature(
                    center: Vec3(x: v[0], y: v[1], z: v[2]), diameter: v[3],
                    normal: v.count == 7 ? Vec3(x: v[4], y: v[5], z: v[6]) : Vec3(x: 0, y: 0, z: 0))
            }
            func choiceIndex(_ sig: OpeningCapper.OpeningSignature) -> Int {
                if let i = openingChoices.firstIndex(where: { $0.signature == sig }) { return i }
                openingChoices.append(OpeningCapper.OpeningChoice(signature: sig))
                return openingChoices.count - 1
            }
            for token in (leaveOpenArg ?? "").split(separator: ",") {
                openingChoices[choiceIndex(try signature(String(token)))].leaveOpen = true
            }
            for token in (closedOpeningArg ?? "").split(separator: ",") {
                openingChoices[choiceIndex(try signature(String(token)))].closedInWalls = true
            }
            for item in (openingHeightArg ?? "").split(separator: ",") {
                let parts = item.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let h = Double(parts[1]), h.isFinite else {
                    throw HeadlessExportError.invalidOpeningChoice("bad --opening-height item '\(item)': use <opening>=<mm>")
                }
                openingChoices[choiceIndex(try signature(String(parts[0])))].topHeight = h
            }
        }
        // --make-walls <thickness mm>: Make walls (thicken an open skin inward,
        // keep the outside exact and the openings open).
        if let thickness = makeWallsThickness {
            do {
                let (walled, result) = try MeshModifier.makeWallsDetailed(model, thickness: thickness, choices: openingChoices)
                print(String(format: "make-walls (%.2fs): %@", result.elapsed, result.receipt))
                let report = walled.preflight
                print(String(format: "walls: pitch=%.3f samples=%d misses=%d components=%d open-edges=%d non-manifold=%d manifold=%@ untouched=%.4f inner-in-band=%.4f inner-thinner=%.4f inner-verts=%d cap-interior=%d openings=%d",
                             result.latticePitch, result.samples, result.latticeMisses, result.components,
                             report.boundaryEdgeCount, report.nonManifoldEdgeCount, report.manifoldValidated ? "true" : "false",
                             result.untouchedFraction, result.innerWithinBandFraction, result.innerThinnerFraction,
                             result.innerVertexCount, result.capInteriorTriangles, result.openingsKeptOpen))
                for c in result.closedOpenings {
                    print(String(format: "closed-opening %d (%@): %@ thickness=%@", c.number, c.placement, c.partName,
                                 c.measuredThickness.map { String(format: "%.3f", $0) } ?? "unmeasured"))
                }
                model = walled
            } catch let error as WallMaker.WallError {
                print("make-walls: \(error.userMessage)")
            }
        }
        // --close-openings <top height mm>: Make Watertight's Close-openings
        // method (cap every opening, keep the original surface).
        // Nothing to fix is a normal outcome (the model is used unchanged);
        // a mesh too damaged to fix in place fails with the reason.
        if let height = closeOpeningsHeight, height.isFinite {
            let diagnoseStarted = Date()
            if let diagnosis = OpeningCapper.diagnose(model.geometry) {
                print(String(format: "diagnosis (%.2fs): %@", Date().timeIntervalSince(diagnoseStarted), diagnosis.sentence))
            }
            let started = Date()
            do {
                let (closed, result) = try MeshModifier.closeOpenings(model, topHeight: height, choices: openingChoices)
                model = closed
                print(String(format: "close-openings (%.2fs): %@", Date().timeIntervalSince(started), result.receipt))
                let p = closed.preflight
                print("result: tris=\(closed.triangleCount) open-edges=\(p.boundaryEdgeCount) non-manifold=\(p.nonManifoldEdgeCount) zero-area=\(p.degenerateTriangleCount) manifold=\(p.manifoldValidated) watertight=\(p.isWatertight) untouched=\(String(format: "%.5f", result.untouchedFraction)) replaced=\(result.trianglesReplaced) spots=\(result.spotsHealed) patches=\(result.healPatches) flipped=\(result.trianglesFlipped) seams=\(result.seamsStitched) seam-corners=\(result.seamCornersJoined) pieces-reversed=\(result.piecesReversed) volume=\(String(format: "%.1f", OpeningCapper.signedVolume(closed.geometry))) kept=\(result.keptTriangleCount) cap-crossings=\(result.capIntersections) height=\(String(format: "%.3f", result.appliedTopHeight))")
                for o in result.openingOutcomes {
                    print(o.leftOpen
                        ? "opening \(o.number): left open"
                        : String(format: "opening %d: capped requested=%.3f applied=%.3f", o.number, o.requestedHeight, o.appliedHeight))
                }
            } catch OpeningCapper.CapError.nothingToClose {
                print(String(format: "close-openings (%.2fs): nothing to fix — model unchanged (tris=%d).", Date().timeIntervalSince(started), model.triangleCount))
            } catch OpeningCapper.CapError.everythingLeftOpen(let n) {
                print("close-openings: \(OpeningCapper.CapError.everythingLeftOpen(n).localizedDescription)")
            }
        }
        // --dump-mesh <path>: write the post-processing slicing surface (after
        // scale/thicken/hollow/shrinkwrap) as OBJ. Diagnostic hook so a
        // protrusion check can compare exported parts against the EXACT surface
        // they were cut from, not the raw import.
        if let dumpPath {
            var obj = ""
            for v in model.geometry.vertices {
                obj += "v \(v.x) \(v.y) \(v.z)\n"
            }
            let idx = model.geometry.triangleIndices
            var t = 0
            while t + 2 < idx.count {
                obj += "f \(idx[t] + 1) \(idx[t + 1] + 1) \(idx[t + 2] + 1)\n"
                t += 3
            }
            try obj.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
        }

        // Structures (Manifold infill) uses none of the slice plumbing — it has
        // its own flags, engine, mesh-only export, and measurement JSON.
        if mode == .structures, let structureSettings {
            try exportStructures(
                settings: structureSettings,
                model: model,
                format: format,
                outputURL: outputURL,
                measurementPath: measurementPath,
                fixturePath: fixturePath,
                outputPath: outputPath,
                importUnit: importUnit,
                scale: scale,
                effectiveScaleFactor: effectiveScaleFactor
            )
            return
        }

        // Partition cuts the model into bed-sized keyed pieces — its own flags,
        // planner, mesh-only export, and measurement JSON. No slice plumbing.
        if mode == .partition, let partitionRequest {
            try exportPartition(
                request: partitionRequest,
                model: model,
                format: format,
                outputURL: outputURL,
                measurementPath: measurementPath,
                fixturePath: fixturePath,
                outputPath: outputPath,
                importUnit: importUnit,
                scale: scale,
                effectiveScaleFactor: effectiveScaleFactor
            )
            return
        }

        // MotherMold (casting molds) uses none of the slice plumbing — it has
        // its own flags, planner, mesh-only export, and measurement JSON.
        if mode == .motherMold, let motherMoldSettings {
            try exportMotherMold(
                settings: motherMoldSettings,
                model: model,
                format: format,
                outputURL: outputURL,
                measurementPath: measurementPath,
                fixturePath: fixturePath,
                outputPath: outputPath,
                importUnit: importUnit,
                scale: scale,
                effectiveScaleFactor: effectiveScaleFactor
            )
            return
        }

        let axis = explicitAxis ?? .z
        let planningModel: MeshSummary
        // Under a tilt, the map from the turned model back onto the model as
        // imported, for the part frames.
        var slicingToModel: ((Vec3) -> Vec3)?
        if mode != .foldedPanels, !SliceDirection.isIdentity(tiltFirst: sliceTiltFirst, tiltSecond: sliceTiltSecond) {
            let tiltAxis: SliceAxis = (mode == .radial || mode == .threeD) ? .z : axis
            let rotation = SliceDirection.meshRotationDegrees(
                axis: tiltAxis,
                tiltFirst: sliceTiltFirst,
                tiltSecond: sliceTiltSecond
            )
            planningModel = MeshScaler.transformed(model, scale: Vec3(x: 1, y: 1, z: 1), rotationDegrees: rotation)
            slicingToModel = MeshScaler.unrotating(model, rotationDegrees: rotation)
        } else {
            planningModel = model
        }
        let export = try buildExport(
            mode: mode,
            model: planningModel,
            axis: axis,
            secondaryAxis: secondaryAxis,
            materialThickness: thickness,
            sliceDepth: sliceDepth,
            slotClearance: slotClearance,
            notchWidth: notchWidth,
            slotAngle: slotAngle,
            slotRelief: slotRelief,
            sliceCount: sliceCount,
            slicePositionsOverride: slicePositionsOverride,
            firstAxisCount: firstAxisCount,
            curveSliceCount: curveSliceCount,
            amplitude: amplitude,
            splineControlPoints: splineControlPoints,
            nRadial: nRadial,
            radialReliefType: reliefType,
            radialToolDiameter: toolDiameter,
            joinery: .preset(for: joineryType),
            foldedTargetFaces: foldedTargetFaces,
            foldedNetExtent: layoutSettings.sanitized.hasSheetSize
                ? Vec2(
                    x: layoutSettings.sanitized.sheetWidth - layoutSettings.sanitized.pageMargin * 2,
                    y: layoutSettings.sanitized.sheetHeight - layoutSettings.sanitized.pageMargin * 2
                )
                : nil
        )
        // Every part is cut from the model the plan was laid out on: turned
        // into the slicing frame under a Slice Direction tilt, as the app
        // slices it. The part frames map the parts back onto the model as
        // imported.
        try writeExport(
            export,
            format: format,
            model: planningModel,
            outputURL: outputURL,
            layoutSettings: layoutSettings,
            partFramesURL: partFramesPath.map { URL(fileURLWithPath: $0) },
            partFramesToModel: slicingToModel
        )
        if case .foldedPanels(let plan) = export, let census = plan.jointCensus, census.plain > 0 {
            let note = "note: " + census.summary(joint: plan.joinery.type.label) + "\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
        if case .foldedPanels(let plan) = export, let summary = plan.stockCensus.summary(thickness: plan.materialThickness) {
            FileHandle.standardError.write(Data("note: \(summary)\n".utf8))
        }
        if case .curve(let plan) = export {
            let assembly = curveSlots(plan: plan, model: planningModel).assemblyNotes(axisLetter: CutSheetLayoutBuilder.axisLetter(plan.primary.axis))
            for note in [plan.firstAxisCountNote, plan.firstAxisMoveNote, plan.curveCountNote].compactMap({ $0 }) + assembly {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
        }
        if case .radial(let plan) = export {
            for note in radialNotes(plan: plan, model: planningModel) {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
        }
        // Slot relief that cuts nothing (the tool is 0, or the slots merge
        // and leave no inside corners).
        var interlockedReliefCutCount = 0
        if case .interlocked(let plan) = export, plan.slotRelief.enabled {
            // The same model the cut sheet above was written from.
            interlockedReliefCutCount = CutSheetLayoutBuilder.interlockedReliefCutCount(plan: plan, model: planningModel)
            if let note = CutSheetLayoutBuilder.interlockedReliefNote(plan: plan, reliefCutCount: interlockedReliefCutCount) {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
        }

        if let measurementPath {
            let measurementURL = URL(fileURLWithPath: measurementPath)
            try FileManager.default.createDirectory(at: measurementURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let measurement = measurementJSON(
                fixture: fixturePath,
                output: outputPath,
                format: format,
                model: model,
                planningModel: planningModel,
                export: export,
                importUnit: importUnit,
                scale: scale,
                effectiveScaleFactor: effectiveScaleFactor,
                exportData: try Data(contentsOf: outputURL),
                // The cut sheet carries the relief; the STL/OBJ solids do not.
                slotReliefCutCount: format.usesVectorLayout ? interlockedReliefCutCount : 0
            )
            var data = try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: measurementURL)
        }
    }

    /// The Structures settings the CLI flags ask for (`--category`,
    /// `--pattern`, the infill, density, support and skin flags). Read before
    /// anything is written, so flags Structures does not read are refused
    /// first.
    private static func parseStructureSettings(parser: inout ArgumentParser) throws -> StructureSettings {
        let categoryValue = parser.takeValue("--category") ?? StructureCategory.infill.rawValue
        guard let category = StructureCategory(rawValue: categoryValue.lowercased()) else {
            throw HeadlessExportError.unsupportedStructureCategory(categoryValue)
        }
        let patternValue = parser.takeValue("--pattern") ?? InfillPattern.triangle.rawValue
        // Match case-insensitively so camelCase rawValues (quarterCubic, cross3D,
        // triHexagon, cubicSubdivision) work from the CLI, not just all-lowercase ones.
        guard let pattern = InfillPattern.allCases.first(where: {
            $0.rawValue.lowercased() == patternValue.lowercased()
        }) else {
            throw HeadlessExportError.unsupportedInfillPattern(patternValue)
        }

        var parameters = InfillParameters.defaultValue
        if let v = parser.takeDouble("--cell-size-mm") { parameters.cellSizeMm = v }
        if let v = parser.takeDouble("--wall-thickness-mm") { parameters.wallThicknessMm = v }
        if let v = parser.takeDouble("--gyroid-band") { parameters.gyroidBand = v }
        if let v = parser.takeDouble("--loft-slice-mm") { parameters.loftSliceMm = v }
        if let v = parser.takeDouble("--polish-surface") { parameters.polishSurface = v != 0 }
        if let v = parser.takeDouble("--seed") { parameters.seed = UInt64(max(0, v)) }

        let densityImagePath = parser.takeValue("--density-image")
        let densitySource: StructureDensitySource
        if let value = parser.takeValue("--density-source") {
            guard let parsed = parseDensitySource(value) else {
                throw HeadlessExportError.unsupportedDensitySource(value)
            }
            densitySource = parsed
        } else {
            densitySource = densityImagePath == nil ? .uniform : .image
        }
        let densityProjectionValue = parser.takeValue("--density-projection") ?? DensityImageProjection.xy.rawValue
        guard let densityProjection = DensityImageProjection(rawValue: densityProjectionValue) else {
            throw HeadlessExportError.unsupportedDensityProjection(densityProjectionValue)
        }
        var density = StructureDensitySettings(source: densitySource)
        density.imagePath = densityImagePath
        density.imageProjection = densityProjection
        density.invertImage = parser.takeFlag("--invert-density-image")
        if let v = parser.takeDouble("--min-cell-mm") { density.minCellMm = v }
        if let v = parser.takeDouble("--max-cell-mm") { density.maxCellMm = v }

        var support = SupportSettings.defaultValue
        if let v = parser.takeValue("--support-mode") {
            guard let parsed = parseSupportMode(v) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported support mode: \(v)")
            }
            support.supportMode = parsed
        }
        if let v = parser.takeValue("--target-surface") {
            guard let parsed = parseSupportTargetSurface(v) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported support target surface: \(v)")
            }
            support.targetSurface = parsed
        }
        if let v = parser.takeDouble("--surface-angle-deg") { support.surfaceAngleDeg = v }
        if let v = parser.takeDouble("--tip-spacing-mm") { support.tipSpacingMm = v }
        if let v = parser.takeDouble("--tip-diameter-mm") { support.tipDiameterMm = v }
        if let v = parser.takeDouble("--branch-diameter-mm") { support.branchDiameterMm = v }
        if let v = parser.takeDouble("--diameter-angle-deg") { support.diameterAngleDeg = v }
        if let v = parser.takeDouble("--preferred-angle-deg") { support.preferredAngleDeg = v }
        if let v = parser.takeDouble("--max-angle-deg") { support.maxAngleDeg = v }
        if let v = parser.takeDouble("--step-mm") { support.stepMm = v }
        if let v = parser.takeDouble("--xy-clearance-mm") { support.xyClearanceMm = v }
        if let v = parser.takeDouble("--contact-offset-mm") { support.contactOffsetMm = v }
        if let v = parser.takeDouble("--support-variation") { support.variationPct = v }
        if let v = parser.takeValue("--rest-preference") {
            guard let parsed = parseSupportRestPreference(v) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported support rest preference: \(v)")
            }
            support.restPreference = parsed
        }

        var skin = SkinSettings.defaultValue
        if let v = parser.takeValue("--skin-style") {
            guard let parsed = parseSkinStyle(v) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported skin style: \(v)")
            }
            skin.skinStyle = parsed
        }
        if let v = parser.takeValue("--skin-pattern") {
            guard let parsed = parseSkinPattern(v) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported skin pattern: \(v)")
            }
            skin.skinPattern = parsed
        }
        if let v = parser.takeValue("--skin-clip") {
            guard let parsed = SkinClip(rawValue: v.lowercased()) else {
                throw HeadlessExportError.structuresEngineFailed("Unsupported skin clip: \(v)")
            }
            skin.skinClip = parsed
        }
        if let v = parser.takeDouble("--skin-variation") { skin.variationPct = v }
        if let v = parser.takeDouble("--strut-variation") { skin.strutVariationPct = v }
        if let v = parser.takeDouble("--strut-diameter-mm") { skin.strutDiameterMm = v }
        if let v = parser.takeDouble("--rib-width-mm") { skin.ribWidthMm = v }

        return StructureSettings(
            category: category,
            pattern: pattern,
            parameters: parameters,
            density: density,
            support: support,
            skin: skin
        ).sanitized
    }

    /// Structures (Manifold infill) export. Flags: `--category infill|support`,
    /// `--pattern triangle|gyroid`, `--cell-size-mm <f>`, `--wall-thickness-mm
    /// <f>`, `--gyroid-band <f>`, `--seed <i>`. Mesh-only output (STL/OBJ); any
    /// other `--format` is rejected. Writes a `mode:"structures"` measurement
    /// JSON when `--measurement` is supplied. Exits with a clear error when the
    /// engine produces no geometry (non-watertight source, unimplemented
    /// category/pattern, etc.).
    private static func exportStructures(
        settings: StructureSettings,
        model: MeshSummary,
        format: ExportFormat,
        outputURL: URL,
        measurementPath: String?,
        fixturePath: String,
        outputPath: String,
        importUnit: ImportUnitPreset,
        scale: Double,
        effectiveScaleFactor: Double
    ) throws {
        let exportStart = Date()
        let plan: StructureMeshPlan
        let planningStart = Date()
        do {
            guard let built = try StructurePlanner.planThrowing(model: model, settings: settings) else {
                throw HeadlessExportError.structuresEngineFailed("Structures engine produced no geometry")
            }
            plan = built
        } catch let error as StructureEngineError {
            throw HeadlessExportError.structuresEngineFailed(error.userMessage)
        }
        let planningSeconds = Date().timeIntervalSince(planningStart)

        switch format {
        case .obj:
            let title = settings.category == .support
                ? "structures support"
                : (settings.category == .skin ? "structures skin" : "structures infill")
            try ObjExporter.write(meshLayers: plan.layers, to: outputURL, title: title)
        case .stl:
            let solidName: String
            switch settings.category {
            case .infill: solidName = "refabartist_structures_infill"
            case .support: solidName = "refabartist_structures_support"
            case .skin: solidName = "refabartist_structures_skin"
            }
            try StlExporter.write(meshes: plan.layers.map(\.mesh), to: outputURL, solidName: solidName)
        case .dxf, .eps, .pdf, .svg:
            throw HeadlessExportError.unsupportedFormat("\(format.rawValue) (Structures is mesh-only: use stl or obj)")
        }

        guard let measurementPath else { return }
        let measurementURL = URL(fileURLWithPath: measurementPath)
        try FileManager.default.createDirectory(at: measurementURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let auditStart = Date()
        let audit = try? StructureAuditMetrics.componentAudit(layers: plan.layers)
        let auditSeconds = Date().timeIntervalSince(auditStart)
        let watertight = audit?.watertight ?? false
        let bounds = plan.bounds
        let subFloorComponentCount = audit?.subFloorComponentCount(
            wallThicknessMm: settings.parameters.wallThicknessMm
        ) ?? 0
        var measurement: [String: Any] = [
            "mode": "structures",
            "fixture": fixturePath,
            "output": outputPath,
            "format": format.rawValue,
            "category": settings.category.rawValue,
            "pattern": settings.pattern.rawValue,
            "cell_size_mm": settings.parameters.cellSizeMm,
            "wall_thickness_mm": settings.parameters.wallThicknessMm,
            "gyroid_band": settings.parameters.gyroidBand,
            "seed": settings.parameters.seed,
            "density_source": settings.density.source.rawValue,
            "density_effective_source": settings.effectiveDensitySource.rawValue,
            "density_min_cell_mm": settings.density.minCellMm,
            "density_max_cell_mm": settings.density.maxCellMm,
            "density_image_path": settings.density.imagePath ?? NSNull(),
            "density_image_projection": settings.density.imageProjection.rawValue,
            "density_invert_image": settings.density.invertImage,
            "density_notice": settings.densityEngineNotice ?? NSNull(),
            "support_mode": settings.support.supportMode.rawValue,
            "support_target_surface": settings.support.targetSurface.rawValue,
            "support_surface_angle_deg": settings.support.surfaceAngleDeg,
            "support_tip_spacing_mm": settings.support.tipSpacingMm,
            "support_tip_diameter_mm": settings.support.tipDiameterMm,
            "support_branch_diameter_mm": settings.support.branchDiameterMm,
            "support_preferred_angle_deg": settings.support.preferredAngleDeg,
            "support_max_angle_deg": settings.support.maxAngleDeg,
            "support_step_mm": settings.support.stepMm,
            "support_xy_clearance_mm": settings.support.xyClearanceMm,
            "support_contact_offset_mm": settings.support.contactOffsetMm,
            "support_rest_preference": settings.support.restPreference.rawValue,
            "skin_style": settings.skin.skinStyle.rawValue,
            "skin_pattern": settings.skin.skinPattern.rawValue,
            "skin_strut_diameter_mm": settings.skin.strutDiameterMm,
            "skin_rib_width_mm": settings.skin.ribWidthMm,
            "triangle_count": plan.triangleCount,
            "triangleCount": audit?.triangleCount ?? plan.triangleCount,
            "watertight": watertight,
            "componentCount": audit?.componentCount ?? 0,
            "componentVolumes": audit?.componentVolumes ?? [],
            "subFloorComponentCount": subFloorComponentCount,
            "preClipDroppedCount": plan.preClipDroppedCount,
            "preClipDroppedVolume": plan.preClipDroppedVolume,
            "postClipDroppedCount": plan.postClipDroppedCount,
            "postClipDroppedVolume": plan.postClipDroppedVolume,
            "coarseningNotice": plan.coarseningNotice ?? NSNull(),
            "timings": [
                "planningSeconds": planningSeconds,
                "auditSeconds": auditSeconds,
                "totalSeconds": Date().timeIntervalSince(exportStart)
            ],
            "import_unit": importUnit.rawValue,
            "scale": scale,
            "effective_scale_factor": effectiveScaleFactor
        ]
        if let bounds {
            measurement["bounds"] = [
                "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                "max": [bounds.max.x, bounds.max.y, bounds.max.z]
            ]
        }
        if let supportAudit = plan.supportAudit {
            measurement["tipCoverage"] = supportAudit.tipCoverage
            measurement["targetSampleCount"] = supportAudit.targetSampleCount
            measurement["tipCount"] = supportAudit.tipCount
            measurement["branchCount"] = supportAudit.branchCount
            measurement["maxSlopeDeg"] = supportAudit.maxSlopeDeg
            measurement["capsuleCount"] = supportAudit.capsuleCount
            measurement["effectiveStepMm"] = supportAudit.effectiveStepMm
            measurement["mergeCount"] = supportAudit.mergeCount
            measurement["plateRootCount"] = supportAudit.plateRootCount
            measurement["modelIntersectionVolume"] = supportAudit.modelIntersectionVolume
            measurement["overhangCoverage"] = supportAudit.overhangCoverage
            measurement["restOnModelCount"] = supportAudit.restOnModelCount
            if let plateZ = model.bounds?.min.z, let audit {
                measurement["supportPlateZ"] = plateZ
                measurement["supportComponentsReachPlate"] = audit.components.allSatisfy {
                    $0.bounds.min.z <= plateZ + 0.1
                }
                measurement["supportChainsReachPlateOrRested"] =
                    supportAudit.tipCoverage + (Double(supportAudit.restOnModelCount) / Double(max(supportAudit.tipCount, 1))) >= 0.999
            }
        }
        if let skinAudit = plan.skinAudit {
            measurement["seedCount"] = skinAudit.seedCount
            measurement["cellCount"] = skinAudit.cellCount
            measurement["segmentCount"] = skinAudit.segmentCount
            measurement["meanSpacing"] = skinAudit.meanSpacing
            measurement["skinComponentCount"] = skinAudit.componentCount
            measurement["skinGenus"] = skinAudit.genus
        }
        var data = try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: measurementURL)
    }

    private static func parseDensitySource(_ value: String) -> StructureDensitySource? {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return StructureDensitySource.allCases.first {
            $0.rawValue
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "") == normalized
        }
    }

    private static func parseSupportMode(_ value: String) -> SupportMode? {
        normalizedCase(value).flatMap { normalized in
            SupportMode.allCases.first { normalizedCase($0.rawValue) == normalized }
        }
    }

    private static func parseSupportTargetSurface(_ value: String) -> SupportTargetSurface? {
        normalizedCase(value).flatMap { normalized in
            SupportTargetSurface.allCases.first { normalizedCase($0.rawValue) == normalized }
        }
    }

    private static func parseSupportRestPreference(_ value: String) -> SupportRestPreference? {
        normalizedCase(value).flatMap { normalized in
            SupportRestPreference.allCases.first { normalizedCase($0.rawValue) == normalized }
        }
    }

    private static func parseSkinStyle(_ value: String) -> SkinStyle? {
        normalizedCase(value).flatMap { normalized in
            SkinStyle.allCases.first { normalizedCase($0.rawValue) == normalized }
        }
    }

    private static func parseSkinPattern(_ value: String) -> SkinPattern? {
        normalizedCase(value).flatMap { normalized in
            SkinPattern.allCases.first { normalizedCase($0.rawValue) == normalized }
        }
    }

    private static func normalizedCase(_ value: String) -> String? {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    /// Partition headless export: parse build volume + key flags, plan, write the
    /// pieces (combined / zip / plate), and write a `mode:"partition"`
    /// measurement JSON when `--measurement` is supplied.
    /// What a Partition export asks for: pieces that fit the printer, or a
    /// split by undercuts.
    enum PartitionRequest {
        case fitPrinter(PartitionSettings)
        case splitByUndercuts(UndercutSplitSettings, PartitionExporter.UndercutOutput)
    }

    /// The Partition request the CLI flags ask for. Read before anything is
    /// written, so flags Partition does not read are refused first.
    private static func parsePartitionRequest(parser: inout ArgumentParser, outputURL: URL) throws -> PartitionRequest {
        if let purpose = parser.takeValue("--partition-purpose") {
            switch purpose.lowercased() {
            case "split-by-undercuts":
                let (settings, output) = try parseUndercutSplit(parser: &parser)
                return .splitByUndercuts(settings, output)
            case "fit-printer":
                break
            default:
                throw HeadlessExportError.unsupportedPartitionPurpose(purpose)
            }
        }

        var settings = PartitionSettings.defaultValue
        if let v = parser.takeValue("--partition-mode"), let m = PartitionMode.cliValue(v) { settings.mode = m }
        if let v = parser.takeValue("--printer"), let p = PartitionPrinterPreset.cliValue(v) {
            settings.printerPreset = p
            if let volume = p.volume { settings.buildVolume = volume }
        }
        if let v = parser.takeDouble("--build-width") { settings.buildVolume.width = v }
        if let v = parser.takeDouble("--build-depth") { settings.buildVolume.depth = v }
        if let v = parser.takeDouble("--build-height") { settings.buildVolume.height = v }
        if let v = parser.takeDouble("--bed-margin") { settings.bedMargin = v }
        if let v = parser.takeValue("--partition-strategy"), let s = PartitionAutoStrategy.cliValue(v) { settings.autoStrategy = s }
        if let v = parser.takeValue("--key-type"), let k = PartitionKeyType.cliValue(v) { settings.key.type = k }
        if let v = parser.takeDouble("--pin-diameter") { settings.key.pinDiameter = v }
        if let v = parser.takeDouble("--pin-length") { settings.key.pinLength = v }
        if let v = parser.takeDouble("--tolerance") { settings.key.tolerance = v }
        if let v = parser.takeDouble("--pins-per-seam") { settings.key.pinsPerSeam = Int(v) }
        if let v = parser.takeDouble("--edge-margin") { settings.key.edgeMargin = v }
        if let v = parser.takeValue("--packaging") {
            // A present-but-invalid value is an error, not a silent fallback.
            guard let p = PartitionPackaging.cliValue(v) else {
                throw HeadlessExportError.unsupportedFormat("--packaging \(v) (use separate-zip, combined, or plate)")
            }
            settings.packaging = p
        } else if outputURL.pathExtension.lowercased() == "zip" {
            settings.packaging = .separateZip
        } else {
            settings.packaging = .combinedObj
        }
        return .fitPrinter(settings.sanitized)
    }

    private static func exportPartition(
        request: PartitionRequest,
        model: MeshSummary,
        format: ExportFormat,
        outputURL: URL,
        measurementPath: String?,
        fixturePath: String,
        outputPath: String,
        importUnit: ImportUnitPreset,
        scale: Double,
        effectiveScaleFactor: Double
    ) throws {
        let settings: PartitionSettings
        switch request {
        case .splitByUndercuts(let undercutSettings, let output):
            try exportUndercutSplitPartition(
                settings: undercutSettings,
                output: output,
                model: model,
                outputURL: outputURL,
                measurementPath: measurementPath,
                fixturePath: fixturePath
            )
            return
        case .fitPrinter(let fitSettings):
            settings = fitSettings
        }

        guard let plan = PartitionPlanner.plan(model: model, settings: settings) else {
            throw HeadlessExportError.planningFailed
        }
        try PartitionExporter.write(plan: plan, format: format, packaging: settings.packaging, to: outputURL)

        guard let measurementPath else { return }
        let measurementURL = URL(fileURLWithPath: measurementPath)
        try FileManager.default.createDirectory(at: measurementURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let allWatertight = plan.pieces.allSatisfy {
            MeshPreflight.analyze(geometry: MeshGeometryData(vertices: $0.mesh.vertices, triangleIndices: $0.mesh.triangleIndices)).isWatertight
        }
        var measurement: [String: Any] = [
            "mode": "partition",
            "fixture": fixturePath,
            "output": outputPath,
            "format": format.rawValue,
            "partition_mode": settings.mode.rawValue,
            "packaging": settings.packaging.rawValue,
            "build_volume": [settings.buildVolume.width, settings.buildVolume.depth, settings.buildVolume.height],
            "bed_margin": settings.bedMargin,
            "key_type": settings.key.type.rawValue,
            "tolerance": settings.key.tolerance,
            "piece_count": plan.pieces.count,
            "oversized_count": plan.oversizedCount,
            "keyed_seam_count": plan.keyedSeamCount,
            "unkeyable_seam_count": plan.unkeyableSeamCount,
            "triangle_count": plan.triangleCount,
            "watertight": allWatertight,
            "import_unit": importUnit.rawValue,
            "scale": scale,
            "effective_scale_factor": effectiveScaleFactor
        ]
        if let bounds = plan.bounds {
            measurement["bounds"] = [
                "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                "max": [bounds.max.x, bounds.max.y, bounds.max.z]
            ]
        }
        var data = try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: measurementURL)
    }

    /// Split-by-Undercuts headless path. Manual/authored tree ingestion is not
    /// accepted here; every CLI plan uses the automatic planner and the output
    /// package remains writable for every returned status when pieces exist.
    /// The split-by-undercuts settings and output the CLI flags ask for.
    private static func parseUndercutSplit(
        parser: inout ArgumentParser
    ) throws -> (UndercutSplitSettings, PartitionExporter.UndercutOutput) {
        var settings = UndercutSplitSettings.defaultValue
        settings.planningMode = .automatic
        settings.authoredCutTree = nil

        if parser.contains("--undercut-tolerance-mm") {
            let raw = parser.takeValue("--undercut-tolerance-mm") ?? "<missing>"
            guard let value = Double(raw), value.isFinite, (0...10).contains(value) else {
                throw HeadlessExportError.invalidUndercutSetting(
                    flag: "--undercut-tolerance-mm",
                    value: raw
                )
            }
            settings.undercutToleranceMM = value
        }
        if let raw = parser.takeValue("--undercut-quality") {
            guard let quality = UndercutSearchQuality(rawValue: raw.lowercased()) else {
                throw HeadlessExportError.unsupportedUndercutQuality(raw)
            }
            settings.quality = quality
        }
        if parser.contains("--undercut-max-pieces") {
            let raw = parser.takeValue("--undercut-max-pieces") ?? "<missing>"
            guard let value = Int(raw), (1...32).contains(value) else {
                throw HeadlessExportError.invalidUndercutSetting(
                    flag: "--undercut-max-pieces",
                    value: raw
                )
            }
            settings.maxPieces = value
        }
        if let raw = parser.takeValue("--undercut-pull") {
            let pull = try parseUndercutPull(raw)
            settings.pullPolicy = pull.policy
            settings.fixedPullDirection = pull.direction
        }
        if let raw = parser.takeValue("--undercut-priority") {
            switch raw.lowercased() {
            case "fewer": settings.priority = .fewerPieces
            case "balanced": settings.priority = .balanced
            case "cleaner": settings.priority = .cleanerSeams
            default: throw HeadlessExportError.unsupportedUndercutPriority(raw)
            }
        }
        if parser.contains("--undercut-seed") {
            let raw = parser.takeValue("--undercut-seed") ?? "<missing>"
            guard let value = Int64(raw) else {
                throw HeadlessExportError.invalidUndercutSetting(
                    flag: "--undercut-seed",
                    value: raw
                )
            }
            settings.seed = value
        }
        let output: PartitionExporter.UndercutOutput
        if let raw = parser.takeValue("--undercut-output") {
            guard let parsed = PartitionExporter.UndercutOutput.cliValue(raw) else {
                throw HeadlessExportError.unsupportedUndercutOutput(raw)
            }
            output = parsed
        } else {
            output = .separateSTLZip
        }
        return (settings.sanitized, output)
    }

    private static func exportUndercutSplitPartition(
        settings: UndercutSplitSettings,
        output: PartitionExporter.UndercutOutput,
        model: MeshSummary,
        outputURL: URL,
        measurementPath: String?,
        fixturePath: String
    ) throws {

        let sourcePreflightFacts = UndercutSourcePreflightFacts.measure(
            geometry: model.geometry,
            basis: .planTimeSource,
            manifoldValidated: model.preflight.manifoldValidated
        )
        let plan = try blockingUndercutPlan(
            geometry: model.geometry,
            settings: settings
        )
        let modelName = URL(fileURLWithPath: fixturePath)
            .deletingPathExtension().lastPathComponent
        let report = try PartitionExporter.write(
            undercutPlan: plan,
            settings: settings,
            sourceGeometry: model.geometry,
            modelName: modelName,
            output: output,
            sourcePreflightFacts: sourcePreflightFacts,
            to: outputURL
        )

        let reportPath: String
        if let measurementPath {
            let measurementURL = URL(fileURLWithPath: measurementPath)
            try FileManager.default.createDirectory(
                at: measurementURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try report.encodedJSON().write(to: measurementURL, options: .atomic)
            reportPath = measurementURL.path
        } else {
            reportPath = "\(outputURL.path)#undercut-report.json"
        }
        writeUndercutStdout(report: report, reportPath: reportPath)
    }

    private static func parseUndercutPull(
        _ rawValue: String
    ) throws -> (policy: PullDirectionPolicy, direction: Vec3?) {
        switch rawValue.lowercased() {
        case "auto": return (.automatic, nil)
        case "x": return (.fixed, Vec3(x: 1, y: 0, z: 0))
        case "y": return (.fixed, Vec3(x: 0, y: 1, z: 0))
        case "z": return (.fixed, Vec3(x: 0, y: 0, z: 1))
        default:
            let values = rawValue.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 3,
                  let x = Double(values[0]), x.isFinite,
                  let y = Double(values[1]), y.isFinite,
                  let z = Double(values[2]), z.isFinite,
                  let direction = PullDirectionCandidates.canonicalized(Vec3(x: x, y: y, z: z)) else {
                throw HeadlessExportError.unsupportedUndercutPull(rawValue)
            }
            return (.fixed, direction)
        }
    }

    private static func blockingUndercutPlan(
        geometry: MeshGeometryData,
        settings: UndercutSplitSettings
    ) throws -> UndercutSplitPlan {
        let result = BlockingUndercutPlanResult()
        let semaphore = DispatchSemaphore(value: 0)
        let input = HeadlessUncheckedSendable((geometry, settings))
        Task.detached(priority: .userInitiated) {
            do {
                let plan = try await UndercutSplitPlanner.plan(
                    geometry: input.value.0,
                    settings: input.value.1
                )
                result.store(.success(plan))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.take().get()
    }

    static func undercutStdoutText(
        report: UndercutSplitReport,
        reportPath: String
    ) -> String {
        let worstDepth = report.worstMeasuredDepthMM.map {
            String(format: "%.6g", $0)
        } ?? "unavailable"
        let resolution = report.effectiveMeasurementResolutionMM.map {
            String(format: "%.6g", $0)
        } ?? "unavailable"
        let pulls = report.pieces.map { piece in
            "\(piece.name)=(\(String(format: "%.6g", piece.pullAxis.x)),"
                + "\(String(format: "%.6g", piece.pullAxis.y)),"
                + "\(String(format: "%.6g", piece.pullAxis.z)))"
        }.joined(separator: ";")
        return "UNDERCUT_SPLIT_EXPORT"
            + " status=\(report.overallStatus.rawValue)"
            + " pieces=\(report.pieces.count)"
            + " worstDepthMM=\(worstDepth)"
            + " measuredAtGridMM=\(resolution)"
            + " pulls=\(pulls)"
            + " report=\(reportPath)"
    }

    static func writeUndercutStdout(
        report: UndercutSplitReport,
        reportPath: String,
        sink: (Data) -> Void = { FileHandle.standardOutput.write($0) }
    ) {
        sink(Data((
            undercutStdoutText(report: report, reportPath: reportPath) + "\n"
        ).utf8))
    }

    /// MotherMold (casting molds) export. Flags: `--subtype siliconeJacket|slipShell`,
    /// `--parts two|four`, `--wall-thickness-mm <f>`, `--silicone-gap-mm <f>`,
    /// `--smoothing-mm <f>`, `--floor`, `--floor-thickness-mm <f>`,
    /// `--master-mount socket|external`, `--socket-depth-mm <f>`,
    /// `--socket-clearance-mm <f>`,
    /// `--key-type none|tapered-round|tapered-bar`,
    /// `--flange` / `--no-flange`, `--bolt-holes <i>`, `--spout-diameter-mm <f>`,
    /// `--vent-count <i>`, `--seed <i>`. Mesh-only output (STL/OBJ); any other
    /// `--format` is rejected. Writes a `mode:"mothermold"` measurement JSON when
    /// `--measurement` is supplied. Exits with a clear error when the master is
    /// not watertight or the planner produces no parts.
    /// The MotherMold settings the CLI flags ask for. Read before anything
    /// is written, so flags MotherMold does not read are refused first.
    private static func parseMotherMoldSettings(parser: inout ArgumentParser, format: ExportFormat) throws -> MotherMoldSettings {
        let subtypeValue = parser.takeValue("--subtype") ?? MoldSubtype.slipShell.rawValue
        guard let subtype = MoldSubtype.allCases.first(where: {
            $0.rawValue.lowercased() == subtypeValue.lowercased()
        }) else {
            throw HeadlessExportError.unsupportedMoldSubtype(subtypeValue)
        }
        let partsValue = parser.takeValue("--parts") ?? MoldPartCount.two.rawValue
        guard let parts = MoldPartCount.allCases.first(where: {
            $0.rawValue.lowercased() == partsValue.lowercased()
        }) else {
            throw HeadlessExportError.unsupportedMoldPartCount(partsValue)
        }

        var settings = MotherMoldSettings(
            subtype: subtype,
            parts: parts,
            toolingContractVersion: 3
        )
        if let v = parser.takeDouble("--wall-thickness-mm") { settings.wallThickness = v }
        if let v = parser.takeDouble("--silicone-gap-mm") { settings.siliconeGap = v }
        if let v = parser.takeDouble("--smoothing-mm") { settings.smoothing = v }
        if parser.takeFlag("--floor") { settings.floor = true }
        if let v = parser.takeDouble("--floor-thickness-mm") { settings.floorThickness = v }
        if let raw = parser.takeValue("--key-type") {
            guard let keyType = PartitionKeyType.motherMoldCLIValue(raw) else {
                throw HeadlessExportError.unsupportedFormat(
                    "--key-type \(raw) (use none, tapered-round, or tapered-bar)"
                )
            }
            settings.key.type = keyType
        }
        if parser.takeFlag("--no-flange") { settings.flange.enabled = false }
        if parser.takeFlag("--flange") { settings.flange.enabled = true }
        if let v = parser.takeDouble("--bolt-holes") { settings.flange.boltHoleCount = Int(max(0, v)) }
        if let v = parser.takeDouble("--spout-diameter-mm") { settings.spout.spoutDiameter = v }
        if let v = parser.takeDouble("--vent-count") { settings.spout.ventCount = Int(max(0, v)) }
        if let v = parser.takeDouble("--seed") { settings.seed = Int(v) }
        if let raw = parser.takeValue("--master-mount") {
            switch raw.lowercased() {
            case "prepared-post", "preparedpost":
                settings.masterPreparation.retentionMode = .preparedPost
            case "socket", "flat-base", "flatbasesocket":
                settings.masterMount.mode = .flatBaseSocket
                settings.masterPreparation.retentionMode = .flatBaseSocket
            case "external", "external-fixture", "externalfixture":
                settings.masterMount.mode = .externalFixture
                settings.masterPreparation.retentionMode = .externalFixture
            default:
                throw HeadlessExportError.unsupportedFormat("--master-mount \(raw) (use prepared-post, socket, or external)")
            }
        }
        if let v = parser.takeDouble("--socket-depth-mm") { settings.masterMount.socketDepth = v }
        if let v = parser.takeDouble("--socket-clearance-mm") { settings.masterMount.fitClearance = v }

        try applyReusableToolingArguments(parser: &parser, settings: &settings)

        // v3 reusable jackets have one manufacturing route. Legacy MotherMold
        // exports retain their format-derived package default.
        if let raw = parser.takeValue("--packaging") {
            switch raw.lowercased() {
            case "manufacturingzip", "manufacturing-zip": settings.packaging = .manufacturingZip
            case "separatezip", "separate-zip", "zip": settings.packaging = .separateZip
            case "combinedobj", "combined-obj", "combined", "obj": settings.packaging = .combinedObj
            case "laidoutplate", "laid-out-plate", "plate", "stl": settings.packaging = .laidOutPlate
            default:
                throw HeadlessExportError.unsupportedFormat("--packaging \(raw) (use manufacturing-zip, separate-zip, combined-obj, or plate)")
            }
        } else if settings.requiresManufacturingZip {
            settings.packaging = defaultMotherMoldPackaging(
                format: format,
                requiresManufacturingZip: true
            )
        } else {
            settings.packaging = defaultMotherMoldPackaging(
                format: format,
                requiresManufacturingZip: false
            )
        }

        return settings
    }

    private static func exportMotherMold(
        settings: MotherMoldSettings,
        model: MeshSummary,
        format: ExportFormat,
        outputURL: URL,
        measurementPath: String?,
        fixturePath: String,
        outputPath: String,
        importUnit: ImportUnitPreset,
        scale: Double,
        effectiveScaleFactor: Double
    ) throws {
        let sanitized = settings.sanitized
        guard !sanitized.requiresManufacturingZip || sanitized.packaging == .manufacturingZip else {
            throw HeadlessExportError.unsupportedFormat(
                "Reusable jacket tooling requires --packaging manufacturing-zip; legacy MotherMold packages are not manufacturing exports."
            )
        }

        let exportRequest = MotherMoldExportRequest(packaging: settings.packaging)
        guard exportRequest.accepts(format: format) else {
            throw HeadlessExportError.unsupportedFormat(
                "--format \(format.rawValue) conflicts with --packaging \(settings.packaging.rawValue); "
                + "use stl for manufacturing-zip, separate-zip, or plate; use obj for combined-obj"
            )
        }

        let plan: MotherMoldPlan
        do {
            plan = try MotherMoldPlanner.planThrowing(model: model, settings: sanitized)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw HeadlessExportError.motherMoldEngineFailed(message)
        }

        if let approval = reusableToolingApprovalRequirement(settings: sanitized, plan: plan) {
            if let measurementPath {
                let measurementURL = URL(fileURLWithPath: measurementPath)
                try FileManager.default.createDirectory(
                    at: measurementURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let regions: [[String: Any]] = approval.regions.map { region in
                    [
                        "id": region.id,
                        "kind": region.kind.rawValue,
                        "purpose": region.purpose,
                        "surface_area_mm2": region.surfaceArea,
                        "center_mm": [region.center.x, region.center.y, region.center.z],
                        "boundary_mm": region.boundary.map { [$0.x, $0.y, $0.z] },
                    ]
                }
                let planningMeasurement: [String: Any] = [
                    "mode": "mothermold",
                    "phase": "approval-required",
                    "fixture": fixturePath,
                    "output": outputPath,
                    "manufacturing_package_written": false,
                    "approval_signature": approval.signature,
                    "modification_regions": regions,
                    "next_action": "Rerun with --approve-modifications \(approval.signature)",
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: planningMeasurement,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: measurementURL, options: .atomic)
            }
            let regionIDs = approval.regions.map(\.id).joined(separator: ", ")
            throw HeadlessExportError.motherMoldEngineFailed(
                "Prepared-master changes require approval before manufacture. "
                    + "Inspect change region(s) [\(regionIDs)], then rerun with "
                    + "--approve-modifications \(approval.signature). No manufacturing ZIP was written."
            )
        }

        let packageResult: MotherMoldToolingPackageWriter.Result?
        switch format {
        case .obj, .stl:
            let modelName = URL(fileURLWithPath: fixturePath).deletingPathExtension().lastPathComponent
            packageResult = try MotherMoldExporter.write(
                plan: plan,
                settings: sanitized,
                modelName: modelName,
                to: outputURL
            )
        case .dxf, .eps, .pdf, .svg:
            throw HeadlessExportError.unsupportedFormat("\(format.rawValue) (MotherMold is mesh-only: use stl or obj)")
        }
        if sanitized.requiresManufacturingZip, packageResult == nil {
            throw HeadlessExportError.motherMoldEngineFailed(
                "Reusable jacket tooling did not produce an authoritative manufacturing ZIP."
            )
        }

        guard let measurementPath else { return }
        let measurementURL = URL(fileURLWithPath: measurementPath)
        try FileManager.default.createDirectory(at: measurementURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var measurement: [String: Any] = [
            "mode": "mothermold",
            "fixture": fixturePath,
            "output": outputPath,
            "format": format.rawValue,
            "subtype": sanitized.subtype.rawValue,
            "parts": sanitized.parts.rawValue,
            "part_count": plan.parts.count,
            "wall_thickness_mm": sanitized.wallThickness,
            "silicone_gap_mm": sanitized.siliconeGap,
            "detail_softening_mm": sanitized.smoothing,
            "total_cavity_offset_mm": sanitized.siliconeGap + sanitized.smoothing,
            "key_type": sanitized.key.type.rawValue,
            "flange_enabled": sanitized.flange.enabled,
            "flanged_seam_count": plan.flangedSeamCount,
            "flange_plate_count": plan.flangePlatesPlaced,
            "effective_bolt_hole_count": plan.effectiveBoltHoleCount,
            "registration_keys_placed": plan.registrationKeysPlaced,
            "master_mount_mode": sanitized.masterMount.mode.rawValue,
            "master_mount_resolved": plan.masterMount.isResolved,
            "master_mount_contact_area_mm2": plan.masterMount.contactAreaMM2,
            "spout_bored": plan.spoutBored,
            "vents_bored_count": plan.ventsBoredCount,
            "printed_plastic_cc": plan.printedPlasticCC,
            "seed": sanitized.seed,
            "all_parts_watertight": !plan.parts.isEmpty && plan.parts.allSatisfy(\.isWatertight),
            "part_metrics": plan.parts.map { part in
                [
                    "name": part.name,
                    "triangle_count": part.geometry.triangleIndices.count / 3,
                    "watertight": part.isWatertight,
                    "volume_cc": abs(MoldComponentFilter.signedVolume(part.geometry)) / 1000.0
                ] as [String: Any]
            },
            "parting_planes": plan.partingPlanes.map { plane in
                var row: [String: Any] = [
                    "normal": [plane.normalX, plane.normalY, plane.normalZ],
                    "offset": plane.offset,
                    "is_manual": plane.isManual
                ]
                if let axis = plane.axisAligned {
                    row["axis_aligned"] = axis
                }
                return row
            },
            "diagnostics": plan.diagnostics.map { diagnostic in
                [
                    "severity": diagnostic.severity.rawValue,
                    "message": diagnostic.message,
                    "subsystem": diagnostic.subsystem.rawValue,
                    "code": diagnostic.code.rawValue,
                    "recovery_actions": diagnostic.recoveryActions.map(\.rawValue)
                ]
            },
            "import_unit": importUnit.rawValue,
            "scale": scale,
            "effective_scale_factor": effectiveScaleFactor
        ]
        measurement["reusable_tooling_package_contract"] = try reusableToolingPackageContract(
            settings: sanitized,
            plan: plan,
            outputFormat: format,
            packageResult: packageResult,
            outputURL: outputURL
        )
        if let silicone = plan.estimatedSiliconeCC {
            measurement["estimated_silicone_cc"] = silicone
        }
        if let bounds = model.bounds {
            measurement["master_bounds"] = [
                "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                "max": [bounds.max.x, bounds.max.y, bounds.max.z]
            ]
        }
        var data = try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: measurementURL)
    }

    private static func applyReusableToolingArguments(
        parser: inout ArgumentParser,
        settings: inout MotherMoldSettings
    ) throws {
        if let raw = parser.takeValue("--master-source") {
            switch raw.lowercased() {
            case "prepared": settings.masterPreparation.sourceMode = .preparedPrint
            case "physical": settings.masterPreparation.sourceMode = .existingPhysical
            default: throw HeadlessExportError.unsupportedFormat("--master-source \(raw) (use prepared or physical)")
            }
        }
        if let raw = parser.takeValue("--mount-placement") {
            guard let placement = MountPlacementMode(rawValue: raw.lowercased()) else {
                throw HeadlessExportError.unsupportedFormat("--mount-placement \(raw) (use auto or manual)")
            }
            settings.masterPreparation.placementMode = placement
        }
        if let raw = parser.takeValue("--mount-axis") {
            settings.masterPreparation.manualAxis = try toolingAxis(raw, flag: "--mount-axis")
        }
        if let point = try toolingPoint(
            parser: &parser,
            xFlag: "--mount-point-x",
            yFlag: "--mount-point-y",
            zFlag: "--mount-point-z"
        ) {
            settings.masterPreparation.manualPoint = point
        }
        if let raw = parser.takeValue("--liner-fill-up") {
            settings.masterPreparation.linerFillUpAxis = try toolingAxis(raw, flag: "--liner-fill-up")
        }
        if let v = try parser.takeFiniteDouble("--post-width-mm") { settings.masterPreparation.postWidth = v }
        if let v = try parser.takeFiniteDouble("--post-thickness-mm") { settings.masterPreparation.postThickness = v }
        if let v = try parser.takeFiniteDouble("--post-length-mm") { settings.masterPreparation.postFreeLength = v }
        if let v = try parser.takeFiniteDouble("--cross-pin-diameter-mm") { settings.masterPreparation.crossPinDiameter = v }
        if let v = try parser.takeFiniteDouble("--master-weight-g") { settings.masterPreparation.masterWeightGrams = v }
        if let v = try parser.takeFiniteDouble("--external-fixture-capacity-n") {
            settings.masterPreparation.externalFixtureCapacityNewtons = v
        }
        if let cog = try toolingPoint(
            parser: &parser,
            xFlag: "--master-cog-x",
            yFlag: "--master-cog-y",
            zFlag: "--master-cog-z"
        ) {
            settings.masterPreparation.masterCenterOfGravity = cog
        }

        if let raw = parser.takeValue("--production-vents") {
            guard let mode = ProductionFlowMode(rawValue: raw.lowercased()) else {
                throw HeadlessExportError.unsupportedFormat("--production-vents \(raw) (use auto or manual)")
            }
            settings.productionFlow.mode = mode
        }
        if let raw = parser.takeValue("--casting-process") {
            switch raw.lowercased() {
            case "gravity-resin": settings.productionFlow.processProfile = .gravityResin
            case "gravity-plaster": settings.productionFlow.processProfile = .gravityPlaster
            case "custom-gravity": settings.productionFlow.processProfile = .customGravity
            default: throw HeadlessExportError.unsupportedFormat("--casting-process \(raw) (use gravity-resin, gravity-plaster, or custom-gravity)")
            }
        }
        if let raw = parser.takeValue("--casting-up") {
            settings.productionFlow.castingUpAxis = try toolingAxis(raw, flag: "--casting-up")
        }
        if let v = try parser.takeFiniteDouble("--production-gate-diameter-mm") { settings.productionFlow.gateDiameter = v }
        if let v = try parser.takeFiniteDouble("--production-vent-diameter-mm") { settings.productionFlow.ventDiameter = v }
        if let raw = parser.takeValue("--production-gate-point") {
            settings.productionFlow.manualGatePoint = try toolingVector(raw, flag: "--production-gate-point")
        }
        while let raw = parser.takeValue("--production-vent-point") {
            settings.productionFlow.manualVentPoints.append(try toolingVector(raw, flag: "--production-vent-point"))
        }

        if let raw = parser.takeValue("--tooling-support") {
            guard let mode = ToolingSupportMode(rawValue: raw.lowercased()) else {
                throw HeadlessExportError.unsupportedFormat("--tooling-support \(raw) (use auto or manual)")
            }
            settings.toolingSupport.mode = mode
        }
        if let raw = parser.takeValue("--liner-fill-support-plane") {
            settings.toolingSupport.manualLinerFillSupportPlane = try toolingSupportPlane(raw, flag: "--liner-fill-support-plane")
        }
        if let raw = parser.takeValue("--casting-support-plane") {
            settings.toolingSupport.manualCastingSupportPlane = try toolingSupportPlane(raw, flag: "--casting-support-plane")
        }

        if let raw = parser.takeValue("--liner-registration") {
            switch raw.lowercased() {
            case "auto": settings.linerRegistration.mode = .automatic
            case "buttons": settings.linerRegistration.mode = .buttons
            case "buttons-and-lip": settings.linerRegistration.mode = .buttonsAndGateLip
            case "none": settings.linerRegistration.mode = .none
            default: throw HeadlessExportError.unsupportedFormat("--liner-registration \(raw) (use auto, buttons, buttons-and-lip, or none)")
            }
        }
        if let v = try parser.takeFiniteDouble("--liner-buttons-per-part") { settings.linerRegistration.buttonsPerPart = Int(v) }
        if let v = try parser.takeFiniteDouble("--liner-button-diameter-mm") { settings.linerRegistration.buttonDiameter = v }
        if let v = try parser.takeFiniteDouble("--liner-button-depth-mm") { settings.linerRegistration.buttonDepth = v }
        if let v = try parser.takeFiniteDouble("--silicone-density-g-cc") { settings.material.siliconeDensityGramsPerCC = v }
        if let v = try parser.takeFiniteDouble("--casting-density-g-cc") { settings.material.castingDensityGramsPerCC = v }
        if let profileID = parser.takeValue("--print-profile") {
            settings.manufacturingProfile = ToolingManufacturingProfileRef(printerProfileID: profileID)
        }
        if let signature = parser.takeValue("--approve-modifications") {
            settings.approvedModificationSignature = signature
        }
        if parser.takeFlag("--include-reference-meshes") {
            settings.includeReferenceMeshes = true
        }

        if settings.masterPreparation.placementMode == .manual,
           (settings.masterPreparation.manualPoint == nil || settings.masterPreparation.manualAxis == nil) {
            throw HeadlessExportError.unsupportedFormat(
                "--mount-placement manual requires --mount-axis and all --mount-point-x/y/z coordinates"
            )
        }
    }

    private static func toolingPoint(
        parser: inout ArgumentParser,
        xFlag: String,
        yFlag: String,
        zFlag: String
    ) throws -> Vec3Codable? {
        let x = try parser.takeFiniteDouble(xFlag)
        let y = try parser.takeFiniteDouble(yFlag)
        let z = try parser.takeFiniteDouble(zFlag)
        guard x != nil || y != nil || z != nil else { return nil }
        guard let x, let y, let z else {
            throw HeadlessExportError.unsupportedFormat("\(xFlag), \(yFlag), and \(zFlag) must be supplied together")
        }
        return Vec3Codable(x: x, y: y, z: z)
    }

    private static func toolingAxis(_ raw: String, flag: String) throws -> Vec3Codable? {
        switch raw.lowercased() {
        case "auto": return nil
        case "+x": return Vec3Codable(x: 1, y: 0, z: 0)
        case "-x": return Vec3Codable(x: -1, y: 0, z: 0)
        case "+y": return Vec3Codable(x: 0, y: 1, z: 0)
        case "-y": return Vec3Codable(x: 0, y: -1, z: 0)
        case "+z": return Vec3Codable(x: 0, y: 0, z: 1)
        case "-z": return Vec3Codable(x: 0, y: 0, z: -1)
        default: throw HeadlessExportError.unsupportedFormat("\(flag) \(raw) (use auto, +x, -x, +y, -y, +z, or -z)")
        }
    }

    private static func toolingVector(_ raw: String, flag: String) throws -> Vec3Codable {
        let values = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 3, values.allSatisfy(\.isFinite) else {
            throw HeadlessExportError.unsupportedFormat("\(flag) \(raw) (expected x,y,z finite millimeter coordinates)")
        }
        return Vec3Codable(x: values[0], y: values[1], z: values[2])
    }

    private static func toolingSupportPlane(_ raw: String, flag: String) throws -> SupportPlaneSettings {
        let values = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 6, values.allSatisfy(\.isFinite) else {
            throw HeadlessExportError.unsupportedFormat("\(flag) \(raw) (expected ox,oy,oz,nx,ny,nz finite values)")
        }
        return SupportPlaneSettings(
            origin: Vec3Codable(x: values[0], y: values[1], z: values[2]),
            normal: Vec3Codable(x: values[3], y: values[4], z: values[5])
        )
    }

    static func reusableToolingPackageContract(
        settings: MotherMoldSettings,
        plan: MotherMoldPlan,
        outputFormat: ExportFormat,
        packageResult: MotherMoldToolingPackageWriter.Result?,
        outputURL: URL
    ) throws -> [String: Any] {
        let requiresAuthoritativePackage = settings.requiresManufacturingZip
        let requestedAuthoritativePackage = settings.packaging == .manufacturingZip
        let packageWritten = packageResult != nil
        var blockingReasons = plan.toolingExportContract.blockingReasons
        if requiresAuthoritativePackage && !requestedAuthoritativePackage {
            blockingReasons.append(
                "Reusable jacket tooling requires --packaging manufacturing-zip for a manufacturing export."
            )
        }
        if requiresAuthoritativePackage && !packageWritten {
            blockingReasons.append(
                "This run did not produce a validated package manifest and complete tooling inventory."
            )
        }

        var contract: [String: Any] = [
            "schema": plan.toolingExportContract.schema,
            "schema_version": plan.toolingExportContract.schemaVersion,
            "tooling_contract_version": plan.toolingContractVersion,
            "requested_packaging": settings.packaging.rawValue,
            "output_format": outputFormat.rawValue,
            "authoritative_v3_package_required": requiresAuthoritativePackage,
            "authoritative_v3_package_requested": requestedAuthoritativePackage,
            "authoritative_v3_package_written": packageWritten,
            "plan_geometry_watertight": !plan.parts.isEmpty && plan.parts.allSatisfy(\.isWatertight),
            "tooling_artifact_inventory_available": !plan.manufacturingToolingArtifacts.isEmpty,
            "tooling_artifact_count": plan.manufacturingToolingArtifacts.count,
            "manifest_available": packageResult != nil,
            "readiness": plan.toolingExportContract.state.rawValue,
            "qualification": plan.toolingExportContract.qualification.rawValue,
            "physical_process_qualified": plan.toolingExportContract.state == .productionProfileQualified,
            "blocking_reasons": blockingReasons,
            "warnings": plan.toolingExportContract.warnings
        ]
        guard let packageResult else {
            return contract
        }

        let archive = try Data(contentsOf: outputURL)
        let archiveSHA256 = sha256(archive)
        guard archiveSHA256 == packageResult.archiveSHA256 else {
            throw HeadlessExportError.motherMoldEngineFailed(
                "The written manufacturing ZIP hash does not match the authoritative package result."
            )
        }
        let manifestData = try packageResult.manifest.deterministicJSON(prettyPrinted: true)
        let geometryMembers = packageResult.manifest.members.filter {
            $0.member.content == .geometry
        }
        let artifactCounts = Dictionary(grouping: packageResult.manifest.members.compactMap {
            $0.member.toolingRole
        }, by: \.rawValue).mapValues(\.count)
        let hardwareCounts = Dictionary(grouping: packageResult.manifest.hardwareItems, by: {
            $0.kind.rawValue
        }).mapValues(\.count)

        contract["package_archive_sha256"] = archiveSHA256
        contract["package_byte_count"] = archive.count
        contract["manifest_sha256"] = sha256(manifestData)
        contract["manifest_byte_count"] = manifestData.count
        contract["manifest_member_count"] = packageResult.manifest.members.count
        contract["manifest_geometry_member_count"] = geometryMembers.count
        contract["manifest_typed_artifact_counts"] = artifactCounts
        contract["manifest_hardware_item_count"] = packageResult.manifest.hardwareItems.count
        contract["manifest_typed_hardware_counts"] = hardwareCounts
        return contract
    }

    static func reusableToolingApprovalRequirement(
        settings: MotherMoldSettings,
        plan: MotherMoldPlan
    ) -> MotherMoldApprovalRequirement? {
        guard settings.requiresManufacturingZip,
              !plan.masterModificationRegions.isEmpty,
              let signature = plan.masterPreparation.approvalSignature,
              !signature.isEmpty,
              settings.approvedModificationSignature != signature
                || plan.masterPreparation.state != .approved else {
            return nil
        }
        return MotherMoldApprovalRequirement(
            signature: signature,
            regions: plan.masterModificationRegions.sorted { $0.id < $1.id }
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func defaultMotherMoldPackaging(
        format: ExportFormat,
        requiresManufacturingZip: Bool
    ) -> MoldPackaging {
        requiresManufacturingZip ? .manufacturingZip : (format == .obj ? .combinedObj : .laidOutPlate)
    }

    /// Flatten a structure plan's layers back to a single mesh.
    private static func meshFromLayers(_ layers: [SliceMeshExportLayer]) -> MeshGeometryData {
        StructureAuditMetrics.mesh(from: layers)
    }

    enum PlannedExport {
        case stacked(StackedSlicePlan, StackedSliceContours)
        case interlocked(InterlockedSlicePlan)
        case radial(RadialSlicePlan)
        case curve(CurveSlicePlan)
        case threeD(ThreeDSlicePlan)
        case foldedPanels(FoldedPanelPlan)
        case inflatables(InflatablesPlan)

        var mode: ConstructionMode {
            switch self {
            case .stacked:
                return .stacked
            case .interlocked:
                return .interlocked
            case .radial:
                return .radial
            case .curve:
                return .curve
            case .threeD:
                return .threeD
            case .foldedPanels:
                return .foldedPanels
            case .inflatables:
                return .inflatables
            }
        }

        /// The export's flat parts, for FlatPartExport.
        var flatPartSource: FlatPartExport.Source {
            switch self {
            case .stacked(let plan, let contours):
                return .stacked(plan, contours: contours, dowels: nil)
            case .interlocked(let plan):
                return .interlocked(plan)
            case .radial(let plan):
                return .radial(plan)
            case .curve(let plan):
                return .curve(plan)
            case .threeD(let plan):
                return .threeD(plan)
            case .foldedPanels(let plan):
                return .foldedPanels(plan)
            case .inflatables(let plan):
                return .inflatables(plan)
            }
        }
    }

    static func buildExport(
        mode: ConstructionMode,
        model: MeshSummary,
        axis: SliceAxis,
        secondaryAxis: SliceAxis,
        materialThickness: Double,
        sliceDepth: Double?,
        slotClearance: Double,
        notchWidth: Double?,
        slotAngle: Double,
        slotRelief: SlotReliefSettings,
        sliceCount: Int?,
        slicePositionsOverride: [Double]? = nil,
        firstAxisCount: Int?,
        curveSliceCount: Int?,
        amplitude: Double,
        splineControlPoints: [Vec2]?,
        nRadial: Int? = nil,
        radialReliefType: RadialReliefType = .square,
        radialToolDiameter: Double = 0,
        joinery: JoineryParameters = .preset(for: .tab),
        foldedTargetFaces: Int? = nil,
        foldedNetExtent: Vec2? = nil
    ) throws -> PlannedExport {
        switch mode {
        case .stacked:
            // NEO-103: positionsOverride takes precedence over sliceCount override.
            guard let plan = StackedSlicePlanner.plan(
                model: model,
                axis: axis,
                materialThickness: materialThickness,
                sliceCountOverride: slicePositionsOverride == nil ? sliceCount : nil,
                positionsOverride: slicePositionsOverride
            ) else {
                throw HeadlessExportError.planningFailed
            }
            return .stacked(plan, StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan)))
        case .interlocked:
            guard let plan = InterlockedSlicePlanner.plan(
                model: model,
                primaryAxis: axis,
                secondaryAxis: secondaryAxis,
                materialThickness: materialThickness,
                slotClearance: slotClearance,
                notchWidthOverride: notchWidth,
                slotAngleDegrees: slotAngle,
                slotRelief: slotRelief,
                sliceCountOverride: sliceCount
            ) else {
                throw HeadlessExportError.planningFailed
            }
            return .interlocked(plan)
        case .radial:
            // One planner for both routes (rings + fins, honouring the
            // `n_radial == 0` degrade-to-Interlocked case).
            let resolvedNRadial = nRadial ?? sliceCount ?? 12
            guard let plan = RadialSlicePlanner.plan(
                model: model,
                nRadial: resolvedNRadial,
                materialThickness: materialThickness,
                slotClearance: slotClearance,
                notchWidthOverride: notchWidth,
                slotAngleDegrees: slotAngle,
                firstAxisCountOverride: firstAxisCount,
                firstAxisSpacingOverride: sliceDepth,
                reliefType: radialReliefType,
                toolDiameter: radialToolDiameter
            ) else {
                throw HeadlessExportError.planningFailed
            }
            return .radial(plan)
        case .curve:
            let resolvedFirstAxisCount = firstAxisCount ?? 7
            let resolvedCurveSliceCount = curveSliceCount ?? sliceCount ?? 12
            let resolvedSlotWidth = notchWidth ?? materialThickness + slotClearance
            let plan: CurveSlicePlan?
            if let splineControlPoints {
                plan = CurveSlicePlanner.plan(
                    model: model,
                    primaryAxis: axis,
                    materialThickness: materialThickness,
                    firstAxisCount: resolvedFirstAxisCount,
                    curveSliceCount: resolvedCurveSliceCount,
                    splineControlPoints: splineControlPoints,
                    slotWidth: resolvedSlotWidth,
                    slotAngleDegrees: slotAngle
                )
            } else {
                plan = CurveSlicePlanner.plan(
                    model: model,
                    primaryAxis: axis,
                    materialThickness: materialThickness,
                    firstAxisCount: resolvedFirstAxisCount,
                    curveSliceCount: resolvedCurveSliceCount,
                    amplitude: amplitude,
                    slotWidth: resolvedSlotWidth,
                    slotAngleDegrees: slotAngle
                )
            }
            guard let plan else {
                throw HeadlessExportError.planningFailed
            }
            // As the app cuts it: with first-axis ribs moved off the even
            // spacing where that joins parts held only among themselves.
            return .curve(CurveSlicePlanner.joiningGroups(plan, model: model))
        case .threeD:
            guard let plan = ThreeDSlicePlanner.plan(
                model: model,
                materialThickness: materialThickness,
                slotClearance: slotClearance,
                notchWidthOverride: notchWidth,
                slotAngleDegrees: slotAngle,
                sliceDepth: sliceDepth,
                sliceCountOverride: sliceCount
            ) else {
                throw HeadlessExportError.planningFailed
            }
            return .threeD(plan)
        case .foldedPanels:
            var foldedModel = model
            if let foldedTargetFaces, model.faceCount > foldedTargetFaces,
               let simplified = FoldedMeshPrecleaner.preclean(model, targetFaceCount: foldedTargetFaces) {
                foldedModel = simplified
            }
            return .foldedPanels(
                FoldedPanelPlanner.plan(
                    model: foldedModel,
                    joinery: joinery,
                    materialThickness: materialThickness,
                    slotClearance: slotClearance,
                    maxNetExtent: foldedNetExtent
                )
            )
        case .inflatables:
            return .inflatables(try InflatablesPlanner.plan(model: model.geometry, settings: .defaultValue))
        case .structures:
            // Structures uses none of the slice plumbing (no axis, contours,
            // slots, or cut sheet). It is exported by a dedicated path in
            // `run()` (`exportStructures`) and never routed through PlannedExport.
            throw HeadlessExportError.unsupportedMode("structures")
        case .partition:
            // Partition is likewise exported by a dedicated path in `run()`
            // (`exportPartition`) and never routed through PlannedExport.
            throw HeadlessExportError.unsupportedMode("partition")
        case .motherMold:
            // MotherMold likewise has no slice plumbing — it is exported by a
            // dedicated path in `run()` (`exportMotherMold`) and never routed
            // through PlannedExport.
            throw HeadlessExportError.unsupportedMode("motherMold")
        }
    }

    private static func writeExport(
        _ export: PlannedExport,
        format: ExportFormat,
        model: MeshSummary,
        outputURL: URL,
        layoutSettings: ExportLayoutSettings,
        partFramesURL: URL? = nil,
        partFramesToModel: ((Vec3) -> Vec3)? = nil
    ) throws {
        if format.usesVectorLayout {
            // The same writer table the app's Export command uses.
            guard FlatPartExport.writer(for: export.mode, format: format) != nil else {
                throw HeadlessExportError.unsupportedFormat(format.rawValue)
            }
            var document: CutSheetDocument?
            let cutSheet: () -> CutSheetDocument = {
                if let document { return document }
                let built = FlatPartExport.cutSheetDocument(
                    for: export.flatPartSource,
                    model: model,
                    settings: layoutSettings,
                    revision: 1
                )
                document = built
                return built
            }
            let writer = try FlatPartExport.write(
                export.flatPartSource,
                format: format,
                model: model,
                settings: layoutSettings,
                cutSheet: cutSheet,
                to: outputURL
            )
            if let partFramesURL {
                if writer.usesCutSheet {
                    try CutSheetDocumentExporter.writePartFrames(
                        document: cutSheet(), settings: layoutSettings, to: partFramesURL, toModel: partFramesToModel
                    )
                } else if writer == .radialDXF, case .radial(let plan) = export.flatPartSource {
                    try DxfExporter.writePartFrames(
                        radial: plan, model: model, to: partFramesURL, layoutSettings: layoutSettings, toModel: partFramesToModel
                    )
                } else {
                    throw HeadlessExportError.partFramesNeedCutSheet(format.rawValue)
                }
            }
            return
        }
        if partFramesURL != nil {
            throw HeadlessExportError.partFramesNeedCutSheet(format.rawValue)
        }

        switch export {
        case .stacked(let plan, let contours):
            switch format {
            case .obj:
                try ObjExporter.write(contours: contours, materialThickness: plan.materialThickness, to: outputURL)
            default:
                try StlExporter.write(contours: contours, materialThickness: plan.materialThickness, to: outputURL)
            }
        case .interlocked(let plan):
            switch format {
            case .obj:
                try ObjExporter.write(interlocked: plan, model: model, to: outputURL)
            default:
                try StlExporter.write(interlocked: plan, model: model, to: outputURL)
            }
        case .radial(let plan):
            switch format {
            case .obj:
                try ObjExporter.write(radial: plan, model: model, materialThickness: plan.materialThickness, to: outputURL)
            default:
                try StlExporter.write(radial: plan, model: model, materialThickness: plan.materialThickness, to: outputURL)
            }
        case .curve(let plan):
            switch format {
            case .obj:
                try ObjExporter.write(curve: plan, model: model, materialThickness: plan.primary.materialThickness, to: outputURL)
            default:
                try StlExporter.write(curve: plan, model: model, materialThickness: plan.primary.materialThickness, to: outputURL)
            }
        case .threeD(let plan):
            switch format {
            case .obj:
                try ObjExporter.write(threeD: plan, model: model, to: outputURL)
            default:
                try StlExporter.write(threeD: plan, model: model, to: outputURL)
            }
        case .foldedPanels(let plan):
            switch format {
            case .obj:
                try ObjExporter.write(folded: plan, materialThickness: plan.materialThickness, to: outputURL)
            default:
                try StlExporter.write(folded: plan, materialThickness: plan.materialThickness, to: outputURL)
            }
        case .inflatables(let plan):
            let layers = InflatablesMeshExportBuilder.layers(plan: plan)
            guard !layers.isEmpty else {
                throw InflatablesPlannerError.emptyAfterClean
            }
            switch format {
            case .obj:
                try ObjExporter.write(meshLayers: layers, to: outputURL, title: "inflatable membrane")
            default:
                try StlExporter.write(meshes: layers.map(\.mesh), to: outputURL, solidName: "refabartist_inflatable_membrane")
            }
        }
    }

    private static func measurementJSON(
        fixture: String,
        output: String,
        format: ExportFormat,
        model: MeshSummary,
        planningModel: MeshSummary,
        export: PlannedExport,
        importUnit: ImportUnitPreset,
        scale: Double,
        effectiveScaleFactor: Double,
        exportData: Data,
        slotReliefCutCount: Int = 0
    ) -> [String: Any] {
        let exportText = String(data: exportData, encoding: .utf8) ?? ""
        var json: [String: Any] = [
            "schema_version": 1,
            "source": "candidate-swift",
            "fixture": fixture,
            "mode": export.mode.rawValue,
            "settings": [
                "import_unit": importUnit.rawValue,
                "scale_factor": scale,
                "effective_scale_factor": effectiveScaleFactor
            ],
            "mesh": [
                "format": model.format,
                "bytes": model.byteCount,
                "vertex_observation_count": model.vertexObservationCount,
                "face_count": model.faceCount,
                "triangle_count": model.triangleCount,
                "bounds": boundsJSON(model.bounds)
            ],
            "exports": [
                format.rawValue: [
                    "path": output,
                    "byte_count": exportData.count,
                    "line_count": exportText.components(separatedBy: "\nLINE\n").count - 1,
                    "text_count": exportText.components(separatedBy: "\nTEXT\n").count - 1,
                    "circle_count": exportText.components(separatedBy: "\nCIRCLE\n").count - 1
                ]
            ]
        ]
        var planJSON = planMeasurementJSON(export, model: planningModel, slotReliefCutCount: slotReliefCutCount)
        if let planSettings = planJSON.removeValue(forKey: "settings") as? [String: Any],
           var settings = json["settings"] as? [String: Any] {
            settings.merge(planSettings) { _, new in new }
            json["settings"] = settings
        }
        json.merge(planJSON) { _, new in new }
        return json
    }

    /// The letter the Radial rings' labels start with: their axis.
    static func radialRingLetter(_ plan: RadialSlicePlan) -> String {
        CutSheetLayoutBuilder.axisLetter(plan.primary?.axis ?? .z)
    }

    /// What the CLI says about a Radial export: rings set further apart than
    /// asked, a notch width the stock cannot fit, and what the cut sheet says
    /// about its parts (`RadialPartBuilder.notes`: pieces left out, parts no
    /// joint locks in, parts narrower than the stock).
    static func radialNotes(plan: RadialSlicePlan, model: MeshSummary) -> [String] {
        var notes: [String] = []
        if let note = plan.ringCountNote {
            notes.append(note)
        }
        if let note = plan.reliefNote {
            notes.append(note)
        }
        if plan.slotWidth < plan.materialThickness - 1.0e-9 {
            notes.append("The \(Vec3.format(plan.slotWidth)) mm notch width is narrower than the "
                + "\(Vec3.format(plan.materialThickness)) mm stock: the rings and fins will not fit into each other's notches.")
        }
        if plan.nRadial > 0 {
            notes += RadialPartBuilder.notes(RadialPartBuilder.assembly(plan: plan, model: model), axisLetter: radialRingLetter(plan))
        }
        return notes
    }

    /// The joints and pieces a Curve Slices export cuts
    /// (`CurveJointPlanner.slots`).
    static func curveSlots(plan: CurveSlicePlan, model: MeshSummary) -> CurveJointPlanner.Slots {
        CurveJointPlanner.slots(
            plan: plan,
            primary: CurveSliceContourer.firstAxisContours(model: model, plan: plan),
            curve: CurveSliceContourer.generate(model: model, plan: plan)
        )
    }

    private static func planMeasurementJSON(_ export: PlannedExport, model: MeshSummary, slotReliefCutCount: Int) -> [String: Any] {
        switch export {
        case .stacked(let plan, let contours):
            return [
                "settings": [
                    "axis": plan.axis.rawValue,
                    "material_thickness_mm": plan.materialThickness
                ],
                "stacked_slices": stackedPlanJSON(plan),
                "contours": [
                    "axis": contours.axis.rawValue,
                    "layer_count": contours.layers.count,
                    "layers": contours.layers.map(layerJSON)
                ]
            ]
        case .interlocked(let plan):
            return [
                "interlocked_slices": [
                    "primary": stackedPlanJSON(plan.primary),
                    "secondary": stackedPlanJSON(plan.secondary),
                    "material_thickness": plan.materialThickness,
                    "slice_count": plan.sliceCount,
                    "slot_count": plan.slotCount,
                    "slot_width": plan.slotWidth,
                    "slot_clearance": plan.slotClearance,
                    "slot_angle_degrees": plan.slotAngleDegrees,
                    // Relief discs actually cut into the parts (none where
                    // the slots merge and leave no inside corners).
                    "slot_relief_circle_count": slotReliefCutCount
                ]
            ]
        case .radial(let plan):
            // What the export holds: rings and fins, or, with no fins asked
            // for, the Interlocked parts it degrades to (rings and one plank).
            let diskCount: Int
            let radialDirectionCount: Int
            let wedgePartCount: Int
            let plankCount: Int
            let unjoined: [String]
            var leftOut: [String] = []
            var thin: [String] = []
            if plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
                let labels = CutSheetLayoutBuilder.document(
                    interlocked: fallback, model: model, settings: .defaultValue, revision: 0
                ).sheets.flatMap(\.parts).map(\.label)
                diskCount = labels.filter { $0.hasPrefix(fallback.primary.axis.label + "-") }.count
                plankCount = labels.count - diskCount
                radialDirectionCount = 0
                wedgePartCount = 0
                unjoined = []
            } else {
                let parts = RadialPartBuilder.assembly(plan: plan, model: model)
                diskCount = parts.disks.count
                plankCount = 0
                radialDirectionCount = RadialPartBuilder.wedgeCount(plan: plan)
                wedgePartCount = parts.wedges.count
                unjoined = RadialPartBuilder.unjoinedLabels(parts, axisLetter: radialRingLetter(plan))
                leftOut = RadialPartBuilder.leftOutLabels(parts, axisLetter: radialRingLetter(plan))
                thin = RadialPartBuilder.thinLabels(parts, axisLetter: radialRingLetter(plan))
            }
            var radial: [String: Any] = [
                "primary": plan.primary.map(stackedPlanJSON(_:)) as Any,
                "secondary": plan.secondary.map(stackedPlanJSON(_:)) as Any,
                "first_axis_count": diskCount,
                "radial_count": radialDirectionCount,
                "radial_part_count": wedgePartCount,
                "slice_count": plan.sliceCount,
                "total_part_count": diskCount + wedgePartCount + plankCount,
                "center": [plan.center.x, plan.center.y, plan.center.z],
                "radius": plan.radius,
                "angles": plan.angles,
                "slot_width": plan.slotWidth,
                "slot_angle_degrees": plan.slotAngleDegrees,
                "ring_count": plan.primary?.sliceCount ?? 0,
                "requested_ring_count": plan.requestedRingCount ?? plan.primary?.sliceCount ?? 0,
                "minimum_ring_spacing": plan.minimumRingSpacing,
                "relief_type": plan.reliefType.cliValue,
                "tool_diameter": plan.toolDiameter,
                "unjoined_part_count": unjoined.count,
                "unjoined_parts": unjoined,
                "left_out_pieces": leftOut,
                "thin_parts": thin
            ]
            if plan.nRadial == 0 {
                radial["plank_count"] = plankCount
            }
            if let spacing = plan.requestedRingSpacing {
                radial["requested_ring_spacing"] = spacing
            }
            return ["radial_slices": radial]
        case .curve(let plan):
            let slots = curveSlots(plan: plan, model: model)
            let letter = CutSheetLayoutBuilder.axisLetter(plan.primary.axis)
            let unjoined = CurveJointPlanner.Slots.labels(slots.primaryPieces, prefix: letter).filter(\.1).map(\.0)
                + CurveJointPlanner.Slots.labels(slots.curvePieces, prefix: "C").filter(\.1).map(\.0)
            var curve: [String: Any] = [
                "primary": stackedPlanJSON(plan.primary),
                "primary_slice_count": plan.primarySliceCount,
                "curve_slice_count": plan.sliceCount,
                "requested_curve_slice_count": plan.requestedSliceCount ?? plan.sliceCount,
                "requested_primary_slice_count": plan.requestedFirstAxisCount ?? plan.primarySliceCount,
                "total_part_count": plan.totalPartCount,
                "amplitude": plan.amplitude,
                "control_points": plan.controlPoints.map { [$0.x, $0.y] },
                "centers": plan.centers.map { [$0.x, $0.y, $0.z] },
                "directions": plan.directions.map { [$0.x, $0.y] },
                "slot_width": plan.slotWidth,
                "slot_angle_degrees": plan.slotAngleDegrees,
                "unjoined_part_count": unjoined.count,
                "unjoined_parts": unjoined,
                "left_out_pieces": slots.primaryLeftOut.map { "\(letter)-\($0 + 1)" } + slots.curveLeftOut.map { "C-\($0 + 1)" },
                "thin_parts": slots.thinLabels(axisLetter: letter)
            ]
            // First-axis ribs moved off the even spacing to join parts
            // (`CurveSlicePlanner.joiningGroups`); only when some were.
            let moves = plan.firstAxisMoves
            if !moves.isEmpty {
                curve["first_axis_moves"] = moves.map { move -> [String: Any] in
                    ["rib": "\(letter)-\(move.rib + 1)", "even_position": move.even, "position": move.position]
                }
            }
            return ["curve_slices": curve]
        case .threeD(let plan):
            let xPitch = adjacentPitch(plan.x.positions)
            let yPitch = adjacentPitch(plan.y.positions)
            let zPitch = adjacentPitch(plan.z.positions)
            var threeDJSON: [String: Any] = [
                "x": stackedPlanJSON(plan.x),
                "y": stackedPlanJSON(plan.y),
                "z": stackedPlanJSON(plan.z),
                "slice_count": plan.sliceCount,
                "slot_width": plan.slotWidth,
                "slot_angle_degrees": plan.slotAngleDegrees
            ]
            if let sliceDepth = xPitch ?? yPitch ?? zPitch {
                threeDJSON["slice_depth"] = sliceDepth
            }
            return [
                "three_d_slices": threeDJSON
            ]
        case .foldedPanels(let plan):
            var joints: [String: Any] = [:]
            if let census = plan.jointCensus {
                joints = [
                    "cut_edges": census.cutEdges,
                    "joined": census.joined,
                    "too_short": census.tooShort,
                    "too_flat": census.tooFlat,
                    "no_room": census.noRoom,
                    "inside_corner": census.insideCorner
                ]
            }
            return [
                "folded_panels": [
                    "joints": joints,
                    "stock": [
                        "panels": plan.stockCensus.panels,
                        "left_out": plan.stockCensus.leftOut,
                        "cut_back_by_half": plan.stockCensus.cutBackByHalf
                    ],
                    "panel_count": plan.panelCount,
                    "panels": plan.panels.map { panel in
                        [
                            "source_triangle_index": panel.sourceTriangleIndex,
                            "point_count": panel.points.count,
                            "bounds": [
                                "min": [panel.bounds.min.x, panel.bounds.min.y],
                                "max": [panel.bounds.max.x, panel.bounds.max.y]
                            ]
                        ]
                    }
                ]
            ]
        case .inflatables(let plan):
            return [
                "inflatables": [
                    "panel_count": plan.panels.count,
                    "seam_count": plan.seams.count,
                    "diagnostic_count": plan.diagnostics.count,
                    "preview_vertex_count": plan.preview?.inflatedMesh.vertices.count ?? 0,
                    "preview_triangle_count": (plan.preview?.inflatedMesh.triangleIndices.count ?? 0) / 3,
                    "sheet_count": plan.cutSheet.sheets.count,
                    "cut_sheet_part_count": plan.cutSheet.partCount
                ]
            ]
        }
    }

    private static func stackedPlanJSON(_ plan: StackedSlicePlan) -> [String: Any] {
        [
            "axis": plan.axis.rawValue,
            "material_thickness": plan.materialThickness,
            "range_min": plan.rangeMin,
            "range_max": plan.rangeMax,
            "slice_count": plan.sliceCount,
            "positions": plan.positions
        ]
    }

    private static func adjacentPitch(_ positions: [Double]) -> Double? {
        guard positions.count >= 2 else { return nil }
        return positions[1] - positions[0]
    }

    private static func parseSplineControlPoints(_ value: String) -> [Vec2]? {
        if let data = value.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let arrays = json as? [[Any]] {
            let points = arrays.compactMap { item -> Vec2? in
                guard item.count == 2,
                      let x = numericValue(item[0]),
                      let y = numericValue(item[1]) else {
                    return nil
                }
                return Vec2(x: x, y: y)
            }
            return points.count == arrays.count && points.count >= 2 ? points : nil
        }

        let pairs = value
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard pairs.count >= 2 else {
            return nil
        }
        let points = pairs.compactMap { pair -> Vec2? in
            let parts = pair
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  x.isFinite,
                  y.isFinite else {
                return nil
            }
            return Vec2(x: x, y: y)
        }
        return points.count == pairs.count ? points : nil
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let double = value as? Double, double.isFinite {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }

    private static func boundsJSON(_ bounds: Bounds3D?) -> Any {
        guard let bounds else {
            return NSNull()
        }
        return [
            "min": [bounds.min.x, bounds.min.y, bounds.min.z],
            "max": [bounds.max.x, bounds.max.y, bounds.max.z]
        ]
    }

    private static func layerJSON(_ layer: SliceContourLayer) -> [String: Any] {
        [
            "position": layer.position,
            "path_count": layer.paths.count,
            "closed_path_count": layer.paths.filter(\.closed).count,
            "point_count": layer.paths.reduce(0) { $0 + $1.points.count },
            "bounds": boundsJSON(layer.paths),
            "paths": layer.paths.map(pathJSON)
        ]
    }

    private static func pathJSON(_ path: SlicePath2D) -> [String: Any] {
        [
            "closed": path.closed,
            "points": path.points.map { [$0.x, $0.y] }
        ]
    }

    private static func boundsJSON(_ paths: [SlicePath2D]) -> Any {
        let points = paths.flatMap(\.points)
        guard !points.isEmpty else {
            return NSNull()
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return [
            "min": [xs.min() ?? 0, ys.min() ?? 0],
            "max": [xs.max() ?? 0, ys.max() ?? 0]
        ]
    }
}

struct ArgumentParser {
    private var arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func takeFlag(_ flag: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else {
            return false
        }
        arguments.remove(at: index)
        return true
    }

    func contains(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    mutating func takeValue(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let value = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: index)
        return value
    }

    mutating func takeDouble(_ flag: String) -> Double? {
        guard let value = takeValue(flag) else {
            return nil
        }
        return Double(value)
    }

    mutating func takeFiniteDouble(_ flag: String) throws -> Double? {
        guard let value = takeValue(flag) else {
            return nil
        }
        guard let parsed = Double(value), parsed.isFinite else {
            throw HeadlessExportError.unsupportedFormat("\(flag) \(value) (expected a finite number)")
        }
        return parsed
    }

    mutating func requireNoRemainingMotherMoldArguments() throws {
        guard arguments.isEmpty else {
            throw HeadlessExportError.unconsumedMotherMoldArguments(arguments)
        }
    }

    mutating func requireNoRemainingPartitionArguments() throws {
        guard arguments.isEmpty else {
            throw HeadlessExportError.unconsumedPartitionArguments(arguments)
        }
    }

    /// Every argument has been read: anything left is a flag this mode does
    /// not know (a typo, or a flag of another command) or a flag given twice.
    mutating func requireNoRemainingArguments(mode: ConstructionMode) throws {
        guard arguments.isEmpty else {
            throw HeadlessExportError.unconsumedArguments(mode: mode.label, arguments)
        }
    }
}

private struct HeadlessUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class BlockingUndercutPlanResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<UndercutSplitPlan, Error>?

    func store(_ result: Result<UndercutSplitPlan, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func take() -> Result<UndercutSplitPlan, Error> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(HeadlessExportError.planningFailed)
    }
}

extension PartitionKeyType {
    static func motherMoldCLIValue(_ value: String) -> PartitionKeyType? {
        switch value.lowercased() {
        case "none":
            return PartitionKeyType.none
        case "tapered-round", "tapered_round", "round", "pin", "pins":
            return .pins
        case "tapered-bar", "tapered_bar", "bar", "dovetail":
            return .dovetail
        default:
            return nil
        }
    }
}

extension ImportUnitPreset {
    static func cliValue(_ value: String) -> ImportUnitPreset? {
        switch value.lowercased() {
        case "mm", "millimeter", "millimeters":
            return .millimeters
        case "cm", "centimeter", "centimeters":
            return .centimeters
        case "m", "meter", "meters":
            return .meters
        case "in", "inch", "inches":
            return .inches
        default:
            return nil
        }
    }
}

extension ConstructionMode {
    static func cliValue(_ value: String) -> ConstructionMode? {
        switch value.lowercased() {
        case "stacked":
            return .stacked
        case "interlocked":
            return .interlocked
        case "radial":
            return .radial
        case "curve":
            return .curve
        case "3d", "3d-slices", "3d_slices", "three-d", "threed", "three_d", "three-d-slices", "three_d_slices", "threed-slices":
            return .threeD
        case "folded", "folded-panels", "folded_panels", "foldedpanels":
            return .foldedPanels
        case "mothermold", "mother-mold", "mother_mold", "mold":
            return .motherMold
        default:
            return ConstructionMode(rawValue: value)
        }
    }
}
