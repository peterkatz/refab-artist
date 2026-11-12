import Foundation

/// Writes a planned partition as STL/OBJ — one combined file, a zip of per-piece
/// files, or pieces laid out flat on a single plate — plus an optional assembly
/// map. Shared by the GUI export action, the headless command, and tests.
enum PartitionExporter {
    enum UndercutOutput: String, Codable, Equatable, CaseIterable {
        case separateSTLZip
        case namedObjectOBJZip

        static func cliValue(_ value: String) -> UndercutOutput? {
            switch value.lowercased() {
            case "separate-stl-zip": return .separateSTLZip
            case "named-obj-zip": return .namedObjectOBJZip
            default: return nil
            }
        }
    }

    enum PartitionExportError: LocalizedError {
        case noPieces
        case unsupportedFormat(String)
        case pieceSerializationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPieces:
                return "The partition produced no pieces to export."
            case .unsupportedFormat(let format):
                return "\(format) is not a Partition export format (use stl or obj)."
            case .pieceSerializationFailed(let pieceName):
                return "Partition piece \(pieceName) has no triangles to serialize."
            }
        }
    }

    static func write(
        plan: PartitionMeshPlan,
        format: ExportFormat,
        packaging: PartitionPackaging,
        to url: URL
    ) throws {
        guard !plan.pieces.isEmpty else { throw PartitionExportError.noPieces }
        guard format == .stl || format == .obj else {
            throw PartitionExportError.unsupportedFormat(format.rawValue)
        }

        switch packaging {
        case .combinedObj:
            try writeCombined(layers: plan.layers, format: format, to: url)
        case .laidOutPlate:
            try writeCombined(layers: laidOutLayers(plan), format: format, to: url)
        case .separateZip:
            try writeZip(plan: plan, format: format, to: url)
        }
    }

    static func writeCombined(layers: [SliceMeshExportLayer], format: ExportFormat, to url: URL) throws {
        switch format {
        case .obj:
            try ObjExporter.write(meshLayers: layers, to: url, title: "partition")
        case .stl:
            try StlExporter.write(meshes: layers.map(\.mesh), to: url, solidName: "refabartist_partition")
        default:
            throw PartitionExportError.unsupportedFormat(format.rawValue)
        }
    }

    static func writeZip(plan: PartitionMeshPlan, format: ExportFormat, to url: URL) throws {
        try ZipWriter.write(entries: zipEntries(plan: plan, format: format), to: url)
    }

    /// Writes a Split-by-Undercuts package. Eligibility is deliberately and
    /// permanently limited to the presence of geometry; measurement status,
    /// tolerance exceedance, stale state, and analysis advisories are report
    /// facts and never prevent this call from writing the pieces.
    @discardableResult
    static func write(
        undercutPlan plan: UndercutSplitPlan,
        settings: UndercutSplitSettings,
        sourceGeometry: MeshGeometryData,
        modelName: String,
        output: UndercutOutput,
        sourcePreflightFacts: UndercutSourcePreflightFacts? = nil,
        additionalWarnings: [String] = [],
        to url: URL
    ) throws -> UndercutSplitReport {
        guard !plan.pieces.isEmpty else { throw PartitionExportError.noPieces }
        let report = UndercutSplitReport.make(
            plan: plan,
            settings: settings,
            sourceGeometry: sourceGeometry,
            output: output,
            sourcePreflightFacts: sourcePreflightFacts,
            additionalWarnings: additionalWarnings
        )
        let entries = try undercutZipEntries(
            plan: plan,
            report: report,
            modelName: modelName,
            output: output
        )
        try ZipWriter.write(entries: entries, to: url)
        return report
    }

    static func undercutZipEntries(
        plan: UndercutSplitPlan,
        report: UndercutSplitReport,
        modelName: String,
        output: UndercutOutput
    ) throws -> [ZipWriter.Entry] {
        guard !plan.pieces.isEmpty else { throw PartitionExportError.noPieces }
        let safeModelName = safeUndercutModelName(modelName)
        let piecesByID = Dictionary(uniqueKeysWithValues: plan.pieces.map {
            ($0.regionID.rawValue, $0)
        })
        var entries: [ZipWriter.Entry] = []

        switch output {
        case .separateSTLZip:
            for reportPiece in report.pieces {
                guard let piece = piecesByID[reportPiece.id], !piece.mesh.triangles.isEmpty else {
                    throw PartitionExportError.pieceSerializationFailed(reportPiece.name)
                }
                let label = reportPiece.name.replacingOccurrences(of: "Piece ", with: "")
                entries.append(ZipWriter.Entry(
                    name: "\(safeModelName)-piece-\(label).stl",
                    data: undercutPieceSTLData(piece: piece, name: reportPiece.name)
                ))
            }
        case .namedObjectOBJZip:
            guard plan.pieces.allSatisfy({ !$0.mesh.triangles.isEmpty }) else {
                let failed = report.pieces.first(where: {
                    piecesByID[$0.id]?.mesh.triangles.isEmpty != false
                })?.name ?? "unknown"
                throw PartitionExportError.pieceSerializationFailed(failed)
            }
            entries.append(ZipWriter.Entry(
                name: "\(safeModelName)-undercut-split.obj",
                data: undercutNamedObjectOBJData(
                    plan: plan,
                    report: report,
                    modelName: safeModelName
                )
            ))
        }

        entries.append(ZipWriter.Entry(
            name: "assembly-guide.txt",
            data: Data(undercutAssemblyGuideText(report: report).utf8)
        ))
        entries.append(ZipWriter.Entry(
            name: "undercut-report.json",
            data: try report.encodedJSON()
        ))
        return entries
    }

    static func zipEntries(plan: PartitionMeshPlan, format: ExportFormat) -> [ZipWriter.Entry] {
        let ext = format == .obj ? "obj" : "stl"
        var entries: [ZipWriter.Entry] = []
        for piece in plan.pieces {
            let data = format == .obj ? pieceOBJData(piece) : pieceSTLData(piece)
            entries.append(ZipWriter.Entry(name: "\(piece.name).\(ext)", data: data))
        }
        if plan.settings.includeAssemblyMap {
            entries.append(ZipWriter.Entry(name: "assembly-map.txt", data: assemblyMapData(plan)))
        }
        return entries
    }

    // MARK: - Per-piece text

    static func pieceOBJData(_ piece: PartitionPiece) -> Data {
        var s = "# Refab Artist partition piece \(piece.name)\n# Units: millimeters\n"
        s += "o \(piece.name)\ng \(piece.name)\n"
        let mesh = piece.mesh
        for v in mesh.vertices {
            s += "v \(fmt(v.x)) \(fmt(v.y)) \(fmt(v.z))\n"
        }
        var t = 0
        while t + 2 < mesh.triangleIndices.count {
            let ia = Int(mesh.triangleIndices[t]), ib = Int(mesh.triangleIndices[t + 1]), ic = Int(mesh.triangleIndices[t + 2])
            t += 3
            guard mesh.vertices.indices.contains(ia), mesh.vertices.indices.contains(ib), mesh.vertices.indices.contains(ic) else { continue }
            s += "f \(ia + 1) \(ib + 1) \(ic + 1)\n"
        }
        return Data(s.utf8)
    }

    static func pieceSTLData(_ piece: PartitionPiece) -> Data {
        let mesh = piece.mesh
        var s = "solid \(piece.name)\n"
        var t = 0
        while t + 2 < mesh.triangleIndices.count {
            let ia = Int(mesh.triangleIndices[t]), ib = Int(mesh.triangleIndices[t + 1]), ic = Int(mesh.triangleIndices[t + 2])
            guard mesh.vertices.indices.contains(ia), mesh.vertices.indices.contains(ib), mesh.vertices.indices.contains(ic) else {
                t += 3
                continue
            }
            let a = mesh.vertices[ia], b = mesh.vertices[ib], c = mesh.vertices[ic]
            let n = PartitionGeometry.normalized(PartitionGeometry.cross(PartitionGeometry.subtract(b, a), PartitionGeometry.subtract(c, a)))
            s += "  facet normal \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n    outer loop\n"
            s += "      vertex \(fmt(a.x)) \(fmt(a.y)) \(fmt(a.z))\n"
            s += "      vertex \(fmt(b.x)) \(fmt(b.y)) \(fmt(b.z))\n"
            s += "      vertex \(fmt(c.x)) \(fmt(c.y)) \(fmt(c.z))\n"
            s += "    endloop\n  endfacet\n"
            t += 3
        }
        s += "endsolid \(piece.name)\n"
        return Data(s.utf8)
    }

    // MARK: - Split by Undercuts package text

    static func undercutAssemblyGuideText(report: UndercutSplitReport) -> String {
        var lines = [
            "Refab Artist Split by Undercuts — Assembly Guide",
            "Status: \(report.overallStatus.rawValue)",
            "Pieces: \(report.pieces.count)",
            "Seams: \(report.seamAdjacency.count)",
            "",
            "Pieces:",
        ]
        for piece in report.pieces {
            lines.append("  \(piece.name)")
            lines.append("    Color: \(piece.color)")
            lines.append("    Pull axis: \(axisText(piece.pullAxis))")
            if let resolution = piece.measuredAtResolutionMM {
                lines.append("    Status: \(piece.status), measured at \(formatNumber(resolution)) mm grid")
            } else {
                lines.append("    Status: \(piece.status); no undercut measurement is attached")
            }
        }

        lines.append("")
        lines.append("Assembly steps:")
        if report.assemblySteps.isEmpty {
            lines.append("  No mating seams; the export contains one piece.")
        } else {
            for step in report.assemblySteps {
                let moving = step.movingPieceNames.isEmpty
                    ? step.movingPieceIDs.joined(separator: ", ")
                    : step.movingPieceNames.joined(separator: ", ")
                lines.append(
                    "  \(step.order). Move \(moving) along \(axisText(step.direction)) "
                        + "to mate \(step.matingSeamID); pins: \(step.pinCount); "
                        + "suggested display distance: \(formatNumber(step.suggestedDistanceMM)) mm."
                )
            }
        }

        if !report.warnings.isEmpty {
            lines.append("")
            lines.append("Advisories:")
            for warning in report.warnings { lines.append("  - \(warning)") }
        }

        lines.append("")
        if let resolution = report.effectiveMeasurementResolutionMM {
            lines.append(
                "Geometry measured for undercuts at \(formatNumber(resolution)) mm grid; "
                    + "material behavior, shrinkage, and mold construction are not simulated."
            )
        } else {
            lines.append(
                "No undercut measurement is attached; material behavior, shrinkage, "
                    + "and mold construction are not simulated."
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func undercutNamedObjectOBJData(
        plan: UndercutSplitPlan,
        report: UndercutSplitReport,
        modelName: String
    ) -> Data {
        let piecesByID = Dictionary(uniqueKeysWithValues: plan.pieces.map {
            ($0.regionID.rawValue, $0)
        })
        var text = "# Refab Artist Split by Undercuts — \(modelName)\n# Units: millimeters\n"
        var vertexOffset = 0
        for reportPiece in report.pieces {
            guard let piece = piecesByID[reportPiece.id] else { continue }
            let objectName = "\(modelName)-\(reportPiece.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            text += "o \(objectName)\ng \(objectName)\n"
            for triangle in piece.mesh.triangles {
                for vertex in [triangle.a, triangle.b, triangle.c] {
                    text += "v \(fmt(vertex.x)) \(fmt(vertex.y)) \(fmt(vertex.z))\n"
                }
                text += "f \(vertexOffset + 1) \(vertexOffset + 2) \(vertexOffset + 3)\n"
                vertexOffset += 3
            }
        }
        return Data(text.utf8)
    }

    static func undercutPieceSTLData(piece: UndercutSplitPiece, name: String) -> Data {
        let solidName = name.lowercased().replacingOccurrences(of: " ", with: "-")
        var text = "solid \(solidName)\n"
        for triangle in piece.mesh.triangles {
            let normal = PartitionGeometry.normalized(
                PartitionGeometry.cross(
                    PartitionGeometry.subtract(triangle.b, triangle.a),
                    PartitionGeometry.subtract(triangle.c, triangle.a)
                )
            )
            text += "  facet normal \(fmt(normal.x)) \(fmt(normal.y)) \(fmt(normal.z))\n"
            text += "    outer loop\n"
            for vertex in [triangle.a, triangle.b, triangle.c] {
                text += "      vertex \(fmt(vertex.x)) \(fmt(vertex.y)) \(fmt(vertex.z))\n"
            }
            text += "    endloop\n  endfacet\n"
        }
        text += "endsolid \(solidName)\n"
        return Data(text.utf8)
    }

    private static func safeUndercutModelName(_ modelName: String) -> String {
        let stem = URL(fileURLWithPath: modelName).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "model" : result
    }

    private static func axisText(_ axis: Vec3) -> String {
        "(\(formatNumber(axis.x)), \(formatNumber(axis.y)), \(formatNumber(axis.z)))"
    }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    // MARK: - Assembly map

    static func assemblyMapData(_ plan: PartitionMeshPlan) -> Data {
        Data(assemblyMapText(plan).utf8)
    }

    static func assemblyMapText(_ plan: PartitionMeshPlan) -> String {
        var lines: [String] = []
        lines.append("Refab Artist Partition — Assembly Map")
        lines.append("Pieces: \(plan.pieces.count)")
        let keyed = plan.keyedSeamCount
        let unkeyed = plan.unkeyableSeamCount
        lines.append("Seams: \(plan.seams.count) (keyed \(keyed), glue-only \(unkeyed))")
        if plan.settings.key.type == .pins {
            lines.append("Keys: \(Vec3.format(plan.settings.key.pinDiameter)) mm pins, \(Vec3.format(plan.settings.key.tolerance)) mm tolerance")
        }
        lines.append("")
        lines.append("Pieces:")
        for piece in plan.pieces {
            let s = piece.size
            let fit = piece.fitsBuildVolume ? "fits" : "TOO BIG"
            lines.append("  \(piece.name): \(Vec3.format(s.x)) × \(Vec3.format(s.y)) × \(Vec3.format(s.z)) mm — \(fit)")
        }
        if !plan.warnings.isEmpty {
            lines.append("")
            lines.append("Notes:")
            for warning in plan.warnings {
                lines.append("  - \(warning)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Plate layout

    /// Translate each piece so they sit side by side on the build plate (z = 0),
    /// in a simple row that wraps when it exceeds a square-ish width. Export-only;
    /// does not modify the plan.
    static func laidOutLayers(_ plan: PartitionMeshPlan) -> [SliceMeshExportLayer] {
        let gap = 5.0
        let bed = PartitionPlanner.effectiveBedDimensions(plan.settings)
        let rowWidthLimit = max(bed.x, plan.pieces.reduce(0.0) { max($0, $1.size.x) })
        var layers: [SliceMeshExportLayer] = []
        var cursorX = 0.0
        var cursorY = 0.0
        var rowDepth = 0.0
        for piece in plan.pieces {
            let size = piece.size
            if cursorX > 0, cursorX + size.x > rowWidthLimit {
                cursorX = 0
                cursorY += rowDepth + gap
                rowDepth = 0
            }
            let dx = cursorX - piece.bounds.min.x
            let dy = cursorY - piece.bounds.min.y
            let dz = -piece.bounds.min.z
            layers.append(
                SliceMeshExportLayer(
                    name: piece.name,
                    mesh: translate(piece.mesh, dx: dx, dy: dy, dz: dz)
                )
            )
            cursorX += size.x + gap
            rowDepth = max(rowDepth, size.y)
        }
        return layers
    }

    static func translate(_ mesh: ViewportFlatShadedMesh, dx: Double, dy: Double, dz: Double) -> ViewportFlatShadedMesh {
        ViewportFlatShadedMesh(
            vertices: mesh.vertices.map { Vec3(x: $0.x + dx, y: $0.y + dy, z: $0.z + dz) },
            normals: mesh.normals,
            triangleIndices: mesh.triangleIndices
        )
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
