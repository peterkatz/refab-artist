import Foundation

/// One authoritative file contract for a MotherMold packaging choice. The save
/// panel and writer both consume this value so an `.stl` path can never receive
/// ZIP bytes.
struct MotherMoldExportRequest: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case stlArchive
        case combinedOBJ
        case laidOutSTL
    }

    var packaging: MoldPackaging

    var payload: Payload {
        switch packaging {
        case .manufacturingZip, .separateZip: return .stlArchive
        case .combinedObj: return .combinedOBJ
        case .laidOutPlate: return .laidOutSTL
        }
    }

    var pathExtension: String {
        switch payload {
        case .stlArchive: return "zip"
        case .combinedOBJ: return "obj"
        case .laidOutSTL: return "stl"
        }
    }

    var label: String { pathExtension.uppercased() }

    func accepts(format: ExportFormat) -> Bool {
        switch payload {
        case .stlArchive, .laidOutSTL: return format == .stl
        case .combinedOBJ: return format == .obj
        }
    }
}

/// Writes a `MotherMoldPlan` to disk in one of the supported packagings:
///   - `.separateZip`: one STL file per part, bundled in a zip (`ZipWriter`).
///   - `.combinedObj`: a single OBJ with one named object per part (`ObjExporter`).
///   - `.laidOutPlate`: a single STL with all parts laid out on a plate
///     (`StlExporter`).
/// Optionally also writes an assembly map (`AssemblyGuideExporter`).
///
/// This is mesh-only — it never touches the slice/contour/DXF/cut-sheet path.
enum MotherMoldExporter {
    private static let maximumNumericalOverlapMM3 = 0.01

    enum ExportError: LocalizedError, Equatable {
        case emptyPlan
        case unsupportedFormat(String)
        case partsNotWatertight([String])
        case exportDisconnectedParts([String])
        case serializedPartsNotWatertight([String])
        case generatedPartsNotPairwiseDisjoint([String])
        case planContractViolation([String])
        case blockingDiagnostics([String])
        case pathExtensionMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .emptyPlan: return "The mold plan has no parts to export."
            case .unsupportedFormat(let f): return "MotherMold export does not support \(f)."
            case .partsNotWatertight(let names):
                return "Refusing to export non-watertight part(s): \(names.joined(separator: ", ")). Every exported mold part must be watertight."
            case .exportDisconnectedParts(let names):
                return "Refusing to export disconnected mold part(s): \(names.joined(separator: ", ")). Each mold part must be one printable solid; regenerate instead of silently deleting geometry."
            case .serializedPartsNotWatertight(let names):
                return "Refusing to export part(s) that become non-watertight at file precision: \(names.joined(separator: ", "))."
            case .generatedPartsNotPairwiseDisjoint(let reasons):
                return "Refusing to export generated mold parts that overlap or failed the final disjointness check: \(reasons.joined(separator: "; ")). This is an internal build failure; regenerate the mold parts instead of exporting."
            case .planContractViolation(let reasons):
                return "Refusing to export a stale or incomplete mold plan: \(reasons.joined(separator: "; ")). Rebuild the mold with the current settings before exporting."
            case .blockingDiagnostics(let messages):
                return "Refusing to export a mold with blocking errors: \(messages.joined(separator: " "))"
            case .pathExtensionMismatch(let expected, let actual):
                return "MotherMold packaging requires a .\(expected) file, not .\(actual)."
            }
        }
    }

    /// Write the plan to `url` using the packaging in `settings.packaging`.
    @discardableResult
    static func write(
        plan: MotherMoldPlan,
        settings: MotherMoldSettings,
        modelName: String,
        to url: URL
    ) throws -> MotherMoldToolingPackageWriter.Result? {
        guard !plan.parts.isEmpty else { throw ExportError.emptyPlan }
        let blocking = plan.diagnostics.filter { $0.severity == .error }.map(\.message)
        guard blocking.isEmpty else { throw ExportError.blockingDiagnostics(blocking) }
        let request = MotherMoldExportRequest(packaging: settings.packaging)
        let actualExtension = url.pathExtension.lowercased()
        guard actualExtension == request.pathExtension else {
            throw ExportError.pathExtensionMismatch(
                expected: request.pathExtension,
                actual: actualExtension.isEmpty ? "(none)" : actualExtension
            )
        }

        // Hard gate: never write a leaky or disconnected mold. Do not trust only
        // the cached flags: a plan can be constructed directly, and the exact
        // coordinates written to STL/OBJ are the product contract.
        let leaky = plan.parts.filter { !$0.isWatertight }.map(\.name)
        guard leaky.isEmpty else { throw ExportError.partsNotWatertight(leaky) }
        let exportParts = try validatedExportParts(plan.parts)
        let contractIssues = planContractIssues(plan: plan, settings: settings.sanitized)
        guard contractIssues.isEmpty else {
            throw ExportError.planContractViolation(contractIssues)
        }

        let packageResult: MotherMoldToolingPackageWriter.Result?
        switch settings.packaging {
        case .combinedObj:
            try writeCombinedOBJ(parts: exportParts, to: url)
            packageResult = nil

        case .laidOutPlate:
            // Lay parts out on a flat plate: spread each part along X so they
            // don't overlap. We offset each part by its bounding-box width + a
            // 5 mm gap, validate those exact translated coordinates, then use
            // the same round-trip-safe writer as separate-part STL output.
            let laid = try validatedExportParts(laidOutParts(exportParts))
            let output = serialiseAllSTL(parts: laid, solidName: "refabartist_mothermold")
            try output.write(to: url, atomically: true, encoding: .utf8)
            packageResult = nil

        case .manufacturingZip:
            var exportPlan = plan
            exportPlan.requestedPackaging = settings.packaging
            exportPlan.includeReferenceMeshes = settings.includeReferenceMeshes
            exportPlan.manufacturingProfile = settings.manufacturingProfile
            packageResult = try MotherMoldToolingPackageWriter.validateAndWrite(
                plan: exportPlan,
                modelName: modelName,
                destination: url
            )

        case .separateZip:
            try writeZip(parts: exportParts, modelName: modelName, to: url)
            packageResult = nil
        }

        // Optionally write the assembly map alongside the primary file.
        if settings.includeAssemblyMap, settings.packaging != .manufacturingZip {
            let guideURL = url.deletingPathExtension().appendingPathExtension("txt")
            try writeAssemblyMap(plan: plan, settings: settings, modelName: modelName, to: guideURL)
        }
        return packageResult
    }

    private static func planContractIssues(
        plan: MotherMoldPlan,
        settings: MotherMoldSettings
    ) -> [String] {
        var issues: [String] = []
        let expectedPartCount = 1 << settings.parts.planeCount
        let expectedInterfaceCount = settings.parts.planeCount * max(1, expectedPartCount / 2)

        if plan.parts.count != expectedPartCount {
            issues.append("expected \(expectedPartCount) parts, found \(plan.parts.count)")
        }
        if plan.partingPlanes.count != settings.parts.planeCount {
            issues.append("expected \(settings.parts.planeCount) parting plane(s), found \(plan.partingPlanes.count)")
        }

        if settings.flange.enabled {
            if plan.flangedSeamCount != expectedInterfaceCount {
                issues.append("expected \(expectedInterfaceCount) flanged interface(s), found \(plan.flangedSeamCount)")
            }
            if plan.flangePlatesPlaced != expectedInterfaceCount * 2 {
                issues.append("expected \(expectedInterfaceCount * 2) flange plates, found \(plan.flangePlatesPlaced)")
            }
            let expectedBoltCount = expectedInterfaceCount * settings.flange.boltHoleCount
            if plan.effectiveBoltHoleCount != expectedBoltCount {
                issues.append("expected \(expectedBoltCount) bolt holes, found \(plan.effectiveBoltHoleCount)")
            }
        } else if plan.flangedSeamCount != 0
                    || plan.flangePlatesPlaced != 0
                    || plan.effectiveBoltHoleCount != 0 {
            issues.append("the plan contains flange hardware while Mating flange is disabled")
        }

        let expectedKeyCount = settings.key.type == .none
            ? 0
            : expectedInterfaceCount * settings.key.pinsPerSeam
        if plan.registrationKeysPlaced != expectedKeyCount {
            issues.append("expected \(expectedKeyCount) tapered key pair(s), found \(plan.registrationKeysPlaced)")
        }
        if plan.toolingContractVersion < 3 {
            if !plan.spoutBored {
                issues.append("the sealed fill gate was not verified")
            }
            if plan.ventsBoredCount != settings.spout.ventCount {
                issues.append("expected \(settings.spout.ventCount) air vent(s), found \(plan.ventsBoredCount)")
            }

            if settings.subtype == .siliconeJacket,
               settings.masterMount.mode == .flatBaseSocket {
                if !plan.masterMount.isResolved {
                    issues.append("the generated master locator was not resolved")
                } else if (plan.masterMount.finalLocatorRetention ?? 0) < 0.98 {
                    issues.append("the generated master locator did not retain at least 98 percent")
                }
            }
        }

        return issues
    }

    /// Write one STL per part into a zip archive.
    static func writeZip(
        plan: MotherMoldPlan,
        modelName: String,
        to url: URL
    ) throws {
        if plan.toolingContractVersion >= 3 {
            _ = try MotherMoldToolingPackageWriter.validateAndWrite(
                plan: plan,
                modelName: modelName,
                destination: url
            )
            return
        }
        guard !plan.parts.isEmpty else { throw ExportError.emptyPlan }
        let blocking = plan.diagnostics.filter { $0.severity == .error }.map(\.message)
        guard blocking.isEmpty else { throw ExportError.blockingDiagnostics(blocking) }
        let leaky = plan.parts.filter { !$0.isWatertight }.map(\.name)
        guard leaky.isEmpty else { throw ExportError.partsNotWatertight(leaky) }
        try writeZip(parts: validatedExportParts(plan.parts), modelName: modelName, to: url)
    }

    private static func writeZip(
        parts: [MotherMoldPart],
        modelName: String,
        to url: URL
    ) throws {
        var entries: [ZipWriter.Entry] = []

        for part in parts {
            let stlString = serialiseSTL(
                mesh: ViewportMeshRenderData.flatShadedMesh(from: part.geometry),
                solidName: part.name
            )
            guard let data = stlString.data(using: .utf8) else { continue }
            let fileName = "\(safeFilename(part.name)).stl"
            entries.append(ZipWriter.Entry(name: fileName, data: data))
        }

        if entries.isEmpty {
            // Fallback: combine all into one entry so the zip is never empty.
            let combined = serialiseAllSTL(parts: parts, solidName: "refabartist_mothermold")
            if let data = combined.data(using: .utf8) {
                entries.append(ZipWriter.Entry(name: "\(safeFilename(modelName))_mothermold.stl", data: data))
            }
        }

        try ZipWriter.write(entries: entries, to: url)
    }

    // MARK: - Assembly map

    /// Write a plain-text assembly guide for the mold parts.
    static func writeAssemblyMap(
        plan: MotherMoldPlan,
        settings: MotherMoldSettings,
        modelName: String,
        to url: URL
    ) throws {
        var lines: [String] = [
            "Refab Artist MotherMold Assembly Guide",
            "",
            "Model: \(modelName)",
            "Subtype: \(settings.subtype.label)",
            "Parts: \(plan.parts.count)",
            "Packaging: \(settings.packaging.label)",
            ""
        ]
        if let materialLine = materialEstimateLine(plan) {
            lines.insert(materialLine, at: 6)
        }
        if settings.subtype == .siliconeJacket {
            let mountLine: String
            switch plan.masterMount.mode {
            case .flatBaseSocket:
                mountLine = String(
                    format: "Master mount: generated base socket, %.1f mm depth, %.2f mm fit clearance, %.1f mm seal land (sealant required before pour)",
                    plan.masterMount.socketDepthMM,
                    plan.masterMount.fitClearanceMM,
                    plan.masterMount.sealLandWidthMM
                )
            case .externalFixture:
                mountLine = "Master mount: external fixture required (not included in printed geometry)"
            case nil:
                mountLine = "Master mount: unresolved"
            }
            lines.insert(mountLine, at: min(7, lines.count))
        }

        if plan.diagnostics.contains(where: { $0.severity != .info }) {
            lines.append("WARNINGS:")
            for d in plan.diagnostics where d.severity == .error {
                lines.append("  [ERROR] \(d.message)")
            }
            for d in plan.diagnostics where d.severity == .warning {
                lines.append("  [WARN]  \(d.message)")
            }
            lines.append("")
        }

        lines.append("Parts")
        lines.append("-----")
        for (i, part) in plan.parts.enumerated() {
            let watermark = part.isWatertight ? "watertight" : "NOT watertight"
            var boundsDesc = "bounds unknown"
            if let b = part.bounds {
                let dx = b.max.x - b.min.x
                let dy = b.max.y - b.min.y
                let dz = b.max.z - b.min.z
                boundsDesc = String(format: "%.2f × %.2f × %.2f mm", dx, dy, dz)
            }
            lines.append("\(i + 1). \(part.name)  [\(watermark), \(boundsDesc)]")
        }

        lines.append("")
        lines.append("Parting planes")
        lines.append("--------------")
        for (i, plane) in plan.partingPlanes.enumerated() {
            let n = plane.normal
            lines.append(String(format: "%d. normal (%.4f, %.4f, %.4f)  offset %.4f mm",
                i + 1, n.x, n.y, n.z, plane.offset))
        }

        lines.append("")
        lines.append("Assembly steps")
        lines.append("--------------")
        var step = 1
        func addStep(_ text: String) {
            lines.append("\(step). \(text)")
            step += 1
        }
        addStep("Orient each part so supports do not touch the casting surface; verify bed fit and support placement in your printer slicer.")
        addStep("Clean the casting face, keys, bolt bores, spout, and vents of each printed part.")
        switch settings.subtype {
        case .siliconeJacket:
            switch plan.masterMount.mode {
            case .flatBaseSocket:
                addStep("Seat the physical master in the generated base socket. Confirm it cannot slide or tip, then seal the socket land with a material compatible with the master and silicone.")
            case .externalFixture:
                addStep("Build and test the external master fixture before assembly. It must hold the master at the modeled position and seal every penetration against liquid silicone.")
            case nil:
                addStep("STOP: no master fixture is defined. Do not pour until the master is positively located and sealed.")
            }
        case .slipShell:
            addStep("Assemble the rigid negative empty; the original master is not present during casting.")
        }
        if plan.parts.count > 1, plan.registrationKeysPlaced > 0 {
            let sitesByPair = Dictionary(grouping: plan.registrationKeySites) {
                "\($0.malePartName)|\($0.femalePartName)"
            }
            if sitesByPair.isEmpty {
                addStep("Align every physical mating interface using the \(plan.registrationKeysPlaced) verified tapered key pair\(plan.registrationKeysPlaced == 1 ? "" : "s"). Do not force a key that does not seat cleanly.")
            } else {
                for pair in sitesByPair.keys.sorted() {
                    let sites = sitesByPair[pair] ?? []
                    guard let site = sites.first else { continue }
                    addStep("Align \(site.malePartName) with \(site.femalePartName) using \(sites.count) tapered key pair\(sites.count == 1 ? "" : "s"). Do not force a key that does not seat cleanly.")
                }
            }
        } else if plan.parts.count > 1 {
            addStep("Mate the parts on their plain seams.")
        }
        if plan.flangePlatesPlaced > 0, plan.effectiveBoltHoleCount > 0 {
            addStep("Clamp all \(plan.flangedSeamCount) physical mating interface\(plan.flangedSeamCount == 1 ? "" : "s") with bolts through the \(plan.effectiveBoltHoleCount) verified flange hole\(plan.effectiveBoltHoleCount == 1 ? "" : "s"). Tighten evenly with washers.")
        } else if plan.flangePlatesPlaced > 0 {
            addStep("Clamp across the \(plan.flangePlatesPlaced) flange plate\(plan.flangePlatesPlaced == 1 ? "" : "s"); no effective bolt holes were bored.")
        } else {
            addStep("Clamp or strap the assembly shut (no flange plates were built - see warnings).")
        }
        if plan.spoutBored {
            let vents = plan.ventsBoredCount > 0 ? "; allow displaced air to leave through every open vent" : ""
            if settings.subtype == .siliconeJacket {
                addStep("Pour mixed silicone slowly through the sacrificial funnel and fill channel\(vents). Stop only after silicone reaches every open vent.")
            } else {
                addStep("Pour compatible casting material slowly through the sacrificial funnel and fill channel\(vents).")
            }
        } else {
            addStep("STOP: no verified pour channel was built. Do not cast until Build Status is ready.")
        }
        switch settings.subtype {
        case .siliconeJacket:
            addStep("Cure fully. Remove clamps, separate the rigid shell along its pull axes, release the silicone liner, and remove the master.")
        case .slipShell:
            addStep("Cure. Remove clamps and separate the mold parts.")
        }

        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Laid-out plate helpers

    /// Lay parts out along the X axis with a 5 mm gap between each, all sitting
    /// on z = 0, preserving each part as indexed geometry for final validation.
    private static func laidOutParts(_ parts: [MotherMoldPart]) -> [MotherMoldPart] {
        var result: [MotherMoldPart] = []
        var cursorX = 0.0
        let gap = 5.0

        for part in parts {
            let geometry = part.geometry
            // Compute bounding box and the translation needed to:
            //   - sit the part with its min-X at cursorX
            //   - centre Y/Z at 0 (or just shift min-Z to 0 for printing)
            guard !geometry.vertices.isEmpty else {
                result.append(part)
                continue
            }
            var minV = geometry.vertices[0]
            var maxV = geometry.vertices[0]
            for v in geometry.vertices {
                minV.x = Swift.min(minV.x, v.x)
                minV.y = Swift.min(minV.y, v.y)
                minV.z = Swift.min(minV.z, v.z)
                maxV.x = Swift.max(maxV.x, v.x)
                maxV.y = Swift.max(maxV.y, v.y)
                maxV.z = Swift.max(maxV.z, v.z)
            }

            let offsetX = cursorX - minV.x
            let offsetY = -(minV.y + maxV.y) / 2.0   // centre on Y
            let offsetZ = -minV.z                       // sit on Z = 0

            // Apply translation to vertices, then flat-shade.
            let translated = MeshGeometryData(
                vertices: geometry.vertices.map {
                    Vec3(x: $0.x + offsetX, y: $0.y + offsetY, z: $0.z + offsetZ)
                },
                triangleIndices: geometry.triangleIndices
            )
            var laidPart = part
            laidPart.geometry = translated
            laidPart.bounds = nil
            result.append(laidPart)

            cursorX += (maxV.x - minV.x) + gap
        }
        return result
    }

    private static func validatedExportParts(_ parts: [MotherMoldPart]) throws -> [MotherMoldPart] {
        let disconnected = parts.compactMap { part in
            MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry).droppedCount > 0
                ? part.name
                : nil
        }
        guard disconnected.isEmpty else { throw ExportError.exportDisconnectedParts(disconnected) }

        // All MotherMold mesh formats write decimal coordinates. Use 17
        // significant digits for a deterministic Double round trip, then validate
        // the values produced by formatting and parsing. A fixed 9-decimal grid
        // collapsed distinct self-contact vertices on healed organic scans.
        var prepared: [MotherMoldPart] = []
        prepared.reserveCapacity(parts.count)
        var failed: [String] = []
        var serializedDisconnected: [String] = []
        for var part in parts {
            part.geometry = roundTrippedForSerialization(part.geometry)
            let preflight = MeshPreflight.analyze(geometry: part.geometry)
            if !preflight.isWatertight {
                failed.append(part.name)
            }
            if MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry).droppedCount > 0 {
                serializedDisconnected.append(part.name)
            }
            prepared.append(part)
        }
        guard serializedDisconnected.isEmpty else {
            throw ExportError.exportDisconnectedParts(serializedDisconnected)
        }
        guard failed.isEmpty else { throw ExportError.serializedPartsNotWatertight(failed) }
        let pairwiseIssues = pairwiseDisjointnessIssues(prepared)
        guard pairwiseIssues.isEmpty else {
            throw ExportError.generatedPartsNotPairwiseDisjoint(pairwiseIssues)
        }
        return prepared
    }

    private static func pairwiseDisjointnessIssues(_ parts: [MotherMoldPart]) -> [String] {
        guard parts.count > 1 else { return [] }

        var issues: [String] = []
        issues.reserveCapacity(parts.count)

        var handles: [ManifoldHandle] = []
        handles.reserveCapacity(parts.count)

        do {
            for part in parts {
                handles.append(try ManifoldEngine.make(from: part.geometry))
            }
        } catch {
            return parts.count > 1
                ? ["final pairwise disjointness check failed while constructing generated mold parts (\(error))"]
                : []
        }

        for firstIndex in handles.indices {
            for secondIndex in handles.indices where secondIndex > firstIndex {
                do {
                    let intersection = try ManifoldEngine.intersect(handles[firstIndex], handles[secondIndex])
                    let overlapVolume = abs(ManifoldEngine.volume(intersection))
                    if overlapVolume > maximumNumericalOverlapMM3 {
                        issues.append(
                            "\(parts[firstIndex].name)/\(parts[secondIndex].name) overlap \(String(format: "%.3f", overlapVolume)) mm^3"
                        )
                    }
                    withExtendedLifetime(intersection) {}
                } catch {
                    issues.append(
                        "\(parts[firstIndex].name)/\(parts[secondIndex].name) disjointness check failed (\(error))"
                    )
                }
            }
        }
        withExtendedLifetime(handles) {}
        return issues
    }

    private static func writeCombinedOBJ(parts: [MotherMoldPart], to url: URL) throws {
        var output = "# Refab Artist mothermold mesh export\n# Units: millimeters\n"
        var vertexOffset = 1
        for part in parts {
            output += "o \(safeFilename(part.name))\n"
            output += "g \(safeFilename(part.name))\n"
            for vertex in part.geometry.vertices {
                output += "v \(fmt(vertex.x)) \(fmt(vertex.y)) \(fmt(vertex.z))\n"
            }
            let indices = part.geometry.triangleIndices
            var t = 0
            while t + 2 < indices.count {
                let a = Int(indices[t]) + vertexOffset
                let b = Int(indices[t + 1]) + vertexOffset
                let c = Int(indices[t + 2]) + vertexOffset
                output += "f \(a) \(b) \(c)\n"
                t += 3
            }
            vertexOffset += part.geometry.vertices.count
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func roundTrippedForSerialization(_ geometry: MeshGeometryData) -> MeshGeometryData {
        MeshGeometryData(
            vertices: geometry.vertices.map { vertex in
                Vec3(
                    x: Double(fmt(vertex.x)) ?? vertex.x,
                    y: Double(fmt(vertex.y)) ?? vertex.y,
                    z: Double(fmt(vertex.z)) ?? vertex.z
                )
            },
            triangleIndices: geometry.triangleIndices
        )
    }

    // MARK: - STL serialisation helpers

    /// Serialise a single `ViewportFlatShadedMesh` as an ASCII STL string.
    private static func serialiseSTL(
        mesh: ViewportFlatShadedMesh,
        solidName: String
    ) -> String {
        var out = "solid \(solidName)\n"
        for start in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            let ai = Int(mesh.triangleIndices[start])
            let bi = Int(mesh.triangleIndices[start + 1])
            let ci = Int(mesh.triangleIndices[start + 2])
            guard ai < mesh.vertices.count,
                  bi < mesh.vertices.count,
                  ci < mesh.vertices.count else { continue }
            let a = mesh.vertices[ai]
            let b = mesh.vertices[bi]
            let c = mesh.vertices[ci]
            let n = facetNormal(a: a, b: b, c: c)
            out += "  facet normal \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n"
            out += "    outer loop\n"
            out += "      vertex \(fmt(a.x)) \(fmt(a.y)) \(fmt(a.z))\n"
            out += "      vertex \(fmt(b.x)) \(fmt(b.y)) \(fmt(b.z))\n"
            out += "      vertex \(fmt(c.x)) \(fmt(c.y)) \(fmt(c.z))\n"
            out += "    endloop\n"
            out += "  endfacet\n"
        }
        out += "endsolid \(solidName)\n"
        return out
    }

    /// Serialise all parts into one ASCII STL (fallback for empty-entries zip).
    private static func serialiseAllSTL(parts: [MotherMoldPart], solidName: String) -> String {
        var out = "solid \(solidName)\n"
        for part in parts {
            let mesh = ViewportMeshRenderData.flatShadedMesh(from: part.geometry)
            for start in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
                let ai = Int(mesh.triangleIndices[start])
                let bi = Int(mesh.triangleIndices[start + 1])
                let ci = Int(mesh.triangleIndices[start + 2])
                guard ai < mesh.vertices.count,
                      bi < mesh.vertices.count,
                      ci < mesh.vertices.count else { continue }
                let a = mesh.vertices[ai]
                let b = mesh.vertices[bi]
                let c = mesh.vertices[ci]
                let n = facetNormal(a: a, b: b, c: c)
                out += "  facet normal \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n"
                out += "    outer loop\n"
                out += "      vertex \(fmt(a.x)) \(fmt(a.y)) \(fmt(a.z))\n"
                out += "      vertex \(fmt(b.x)) \(fmt(b.y)) \(fmt(b.z))\n"
                out += "      vertex \(fmt(c.x)) \(fmt(c.y)) \(fmt(c.z))\n"
                out += "    endloop\n"
                out += "  endfacet\n"
            }
        }
        out += "endsolid \(solidName)\n"
        return out
    }

    // MARK: - Utility

    private static func facetNormal(a: Vec3, b: Vec3, c: Vec3) -> Vec3 {
        let ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
        let vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
        guard len > 0 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: nx / len, y: ny / len, z: nz / len)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.17g", v)
    }

    private static func materialEstimateLine(_ plan: MotherMoldPlan) -> String? {
        guard plan.printedPlasticCC > 0 || plan.estimatedSiliconeCC != nil else { return nil }
        if let silicone = plan.estimatedSiliconeCC {
            return String(format: "Material estimates: Printed plastic %.1f cc; Estimated silicone %.1f cc",
                          plan.printedPlasticCC, silicone)
        }
        return String(format: "Material estimates: Printed plastic %.1f cc", plan.printedPlasticCC)
    }

    /// Convert a part name to a safe ASCII filename stem (spaces → underscores,
    /// strip everything that isn't alphanumeric / underscore / hyphen).
    private static func safeFilename(_ name: String) -> String {
        let mapped = name.map { c -> Character in
            if c.isLetter || c.isNumber || c == "-" { return c }
            return "_"
        }
        return String(mapped).trimmingCharacters(in: .init(charactersIn: "_"))
    }

    /// Human-readable part label: A, B, C, … Z, then A2, B2 …
    private static func partLabel(_ index: Int) -> String {
        let base = index % 26
        let round = index / 26
        let letter = String(UnicodeScalar(UInt32(65 + base))!)
        return round == 0 ? letter : "\(letter)\(round + 1)"
    }
}
