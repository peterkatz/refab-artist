import Foundation

/// Deterministic, offline package guide generated from final artifact geometry.
/// It intentionally uses measured orthographic bounds rather than viewport output.
enum MotherMoldGuideRenderer {
    struct Output: Equatable {
        var path: String
        var data: Data
        var role: PackageMemberRole
        var content: PackageMemberContent
        var mediaType: String
    }

    struct GuideArtifact: Equatable {
        var id: ToolingArtifactID
        var displayID: String
        var role: ToolingArtifactRole
        var geometry: MeshGeometryData
        var quantity: Int
    }

    static func render(
        plan: MotherMoldPlan,
        modelName: String,
        artifacts: [GuideArtifact]
    ) throws -> [Output] {
        let ordered = artifacts.sorted { lhs, rhs in
            lhs.displayID == rhs.displayID ? lhs.id < rhs.id : lhs.displayID < rhs.displayID
        }
        let views: [(String, String, Projection)] = [
            ("assembly-overview.svg", "Assembly overview", .xy),
            ("liner-fill-setup.svg", "Liner fill setup", .xz),
            ("casting-setup.svg", "Casting setup", .yz),
            ("trim-map.svg", "Trim map", .xy),
        ]
        var output = views.map { file, title, projection in
            Output(
                path: "guide/\(file)",
                data: utf8Data(svg(title: title, artifacts: ordered, projection: projection)),
                role: .assemblyGuide,
                content: .svg,
                mediaType: "image/svg+xml"
            )
        }
        output.append(Output(
            path: "guide/hardware.csv",
            data: utf8Data(hardwareCSV(items: plan.hardwareItems)),
            role: .hardwareSchedule,
            content: .csv,
            mediaType: "text/csv"
        ))
        output.append(Output(
            path: "guide/assembly-and-reuse.html",
            data: utf8Data(html(plan: plan, modelName: modelName, artifacts: ordered)),
            role: .assemblyGuide,
            content: .text,
            mediaType: "text/html"
        ))
        return output.sorted { $0.path < $1.path }
    }

    private enum Projection { case xy, xz, yz }

    private static func svg(title: String, artifacts: [GuideArtifact], projection: Projection) -> String {
        let width = 960.0
        let height = 640.0
        let rectangles = artifacts.compactMap { artifact -> (GuideArtifact, Double, Double, Double, Double)? in
            guard let bounds = bounds(of: artifact.geometry) else { return nil }
            let minimum = projected(bounds.min, projection)
            let maximum = projected(bounds.max, projection)
            return (artifact, minimum.0, minimum.1, maximum.0, maximum.1)
        }
        let minX = rectangles.map { min($0.1, $0.3) }.min() ?? 0
        let maxX = rectangles.map { max($0.1, $0.3) }.max() ?? 1
        let minY = rectangles.map { min($0.2, $0.4) }.min() ?? 0
        let maxY = rectangles.map { max($0.2, $0.4) }.max() ?? 1
        let spanX = max(1.0e-9, maxX - minX)
        let spanY = max(1.0e-9, maxY - minY)
        let scale = min((width - 120) / spanX, (height - 120) / spanY)

        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"960\" height=\"640\" viewBox=\"0 0 960 640\">",
            "<rect width=\"960\" height=\"640\" fill=\"white\"/>",
            "<text x=\"40\" y=\"42\" font-family=\"Arial, sans-serif\" font-size=\"20\">\(escape(title))</text>",
            "<text x=\"40\" y=\"68\" font-family=\"Arial, sans-serif\" font-size=\"12\">Fixed orthographic projection of final artifact bounds; dimensions are millimeters.</text>",
        ]
        for (index, item) in rectangles.enumerated() {
            let x = 60 + (min(item.1, item.3) - minX) * scale
            let y = height - 50 - (max(item.2, item.4) - minY) * scale
            let w = max(1, abs(item.3 - item.1) * scale)
            let h = max(1, abs(item.4 - item.2) * scale)
            let colors = ["#166534", "#1d4ed8", "#9a3412", "#7e22ce", "#0f766e"]
            let color = colors[index % colors.count]
            lines.append("<rect x=\(number(x)) y=\(number(y)) width=\(number(w)) height=\(number(h)) fill=\"none\" stroke=\"\(color)\" stroke-width=\"2\"/>")
            var path = ""
            let indices = item.0.geometry.triangleIndices
            for start in stride(from: 0, to: indices.count, by: 3) {
                let a = projected(item.0.geometry.vertices[Int(indices[start])], projection)
                let b = projected(item.0.geometry.vertices[Int(indices[start + 1])], projection)
                let c = projected(item.0.geometry.vertices[Int(indices[start + 2])], projection)
                func mapped(_ point: (Double, Double)) -> (Double, Double) {
                    (60 + (point.0 - minX) * scale, height - 50 - (point.1 - minY) * scale)
                }
                let pa = mapped(a), pb = mapped(b), pc = mapped(c)
                path += "M\(number(pa.0)) \(number(pa.1))L\(number(pb.0)) \(number(pb.1))L\(number(pc.0)) \(number(pc.1))Z"
            }
            lines.append("<path d=\"\(path)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"0.35\"/>")
            lines.append("<text x=\(number(x + 4)) y=\(number(max(84, y - 5))) font-family=\"Arial, sans-serif\" font-size=\"12\" fill=\"\(color)\">\(escape(item.0.displayID))</text>")
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func html(plan: MotherMoldPlan, modelName: String, artifacts: [GuideArtifact]) -> String {
        let inventory = artifacts.map { "<li><strong>\(escape($0.displayID))</strong> - \(escape($0.role.rawValue))</li>" }.joined()
        let modifications = plan.masterModificationRegions.sorted { $0.id < $1.id }.map {
            "<li>\(escape($0.id)): \(escape($0.purpose))</li>"
        }.joined()
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>MotherMold assembly and reuse</title>
        <style>body{font-family:Arial,sans-serif;max-width:900px;margin:32px auto;line-height:1.45;color:#172033}h1{margin-bottom:0}h2{margin-top:28px}img{max-width:100%;border:1px solid #94a3b8}code{background:#e2e8f0;padding:2px 4px}</style></head><body>
        <h1>MotherMold tooling: \(escape(modelName))</h1>
        <p>Use this guide with the exact files in this package. Part IDs here and in <code>manifest.json</code> are authoritative.</p>
        <h2>Package inventory</h2><ul>\(inventory)</ul>
        <p>Hardware and consumables are listed in <a href="hardware.csv">hardware.csv</a>.</p>
        <h2>Prepared-master changes</h2><ul>\(modifications.isEmpty ? "<li>No typed prepared-master changes were recorded.</li>" : modifications)</ul>
        <p>Approval signature: <code>\(escape(plan.masterPreparation.approvalSignature ?? "not recorded"))</code>.</p>
        <h2>Assembly and reuse sequence</h2>
        <ol><li>Inspect every printed part and clean the mating, gate, and vent features.</li><li>Seat the prepared master, install the hold-down yoke and cross-pin, then install each removable production-vent former between its prepared-master landing and shell sleeve.</li><li>Assemble and clamp the shell, seal only the specified land and temporary rod joints, and use the liner-fill orientation shown below.</li><li>After full cure, pull every production-vent former outward first, remove the cross-pin and yoke, open the shell, and remove the prepared master. Trim only the map-marked one-time liner-fill nubs.</li><li>For repeat casting, leave the vent-former rods out. Seat the production liner, pin the casting funnel into the shared receiver, verify every permanent production vent is open, and use the casting orientation.</li><li>After demolding, clean and dry the shell, liner, funnel, and prepared master before separate storage.</li></ol>
        <h2>Measured views</h2><p><img src="assembly-overview.svg" alt="Assembly overview"></p><p><img src="liner-fill-setup.svg" alt="Liner fill setup"></p><p><img src="casting-setup.svg" alt="Casting setup"></p><p><img src="trim-map.svg" alt="Trim map"></p>
        <h2>Shop responsibility</h2><p>These drawings describe final geometry only. They do not prove printer fit, material strength, liquid sealing, cure behavior, load capacity, or repeated-use life. Confirm those physical conditions with the selected printer, material, hardware, and shop process before pouring or casting.</p>
        </body></html>
        """
    }

    private static func hardwareCSV(artifacts: [GuideArtifact]) -> String {
        (["id,role,quantity,notes"] + artifacts.map {
            "\(csv($0.displayID)),\(csv($0.role.rawValue)),\($0.quantity),\(csv("See assembly-and-reuse.html"))"
        }).joined(separator: "\n") + "\n"
    }

    private static func bounds(of geometry: MeshGeometryData) -> Bounds3D? {
        guard let first = geometry.vertices.first else { return nil }
        var min = first, max = first
        for point in geometry.vertices {
            min.x = Swift.min(min.x, point.x); min.y = Swift.min(min.y, point.y); min.z = Swift.min(min.z, point.z)
            max.x = Swift.max(max.x, point.x); max.y = Swift.max(max.y, point.y); max.z = Swift.max(max.z, point.z)
        }
        return Bounds3D(min: min, max: max)
    }

    private static func projected(_ point: Vec3, _ projection: Projection) -> (Double, Double) {
        switch projection { case .xy: return (point.x, point.y); case .xz: return (point.x, point.z); case .yz: return (point.y, point.z) }
    }

    private static func utf8Data(_ text: String) -> Data { Data(text.utf8) }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hardwareCSV(items: [ToolingHardwareItem]) -> String {
        let header = "id,kind,description,specification,quantity,material_or_standard_hint,required_dimensions_mm,phases,uses,responsibility,qualification"
        let rows = items.sorted { $0.id < $1.id }.map { item in
            let dimensions = item.requiredDimensions.sorted { $0.kind.rawValue < $1.kind.rawValue }.map { dimension in
                let tolerance = dimension.tolerancePlusMinusMillimeters.map { " +/- \(number($0))" } ?? ""
                return "\(dimension.kind.rawValue): \(number(dimension.nominalMillimeters))\(tolerance)"
            }.joined(separator: "; ")
            return [
                item.id.rawValue,
                item.kind.rawValue,
                item.description,
                item.specification,
                String(item.quantity),
                item.materialOrStandardHint,
                dimensions,
                item.phases.map(\.rawValue).sorted().joined(separator: "; "),
                item.uses.map(\.rawValue).sorted().joined(separator: "; "),
                item.responsibility.rawValue,
                item.qualification.rawValue,
            ].map(csv).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func csv(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private static func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
}
