import Foundation

enum InflatablesPlanner {
    static func plan(model: MeshGeometryData, settings rawSettings: InflatablesSettings) throws -> InflatablesPlan {
        let settings = rawSettings.sanitized
        let cleaned = try InflatablesClean.cleanForInflatable(model)
        let charts = DevelopableSegmentation.segment(mesh: cleaned, settings: settings)
        guard !charts.isEmpty else {
            throw InflatablesPlannerError.segmentationFailed
        }

        let flattened = charts.compactMap { LSCM.flatten($0) }
        guard !flattened.isEmpty else {
            throw InflatablesPlannerError.segmentationFailed
        }

        let panels = InflatablesCutPattern.panels(from: flattened, settings: settings)
        let preview = InflationSimulator.simulate(mesh: cleaned, flattened: flattened, settings: settings)
        let diagnostics = flattened
            .filter { $0.maxStretch > 1.08 }
            .map {
                PlanDiagnostic(
                    kind: "flattening-distortion",
                    message: "\($0.chart.id) estimated flattening stretch is \(String(format: "%.2f", $0.maxStretch))x; add seams or lower panel width.",
                    at: nil,
                    panelID: $0.chart.id
                )
            } + InflationSimulator.diagnostics(preview: preview, flattened: flattened, settings: settings)
        return InflatablesPlan(
            panels: panels,
            seams: seamPairs(for: panels),
            preview: preview,
            cutSheet: InflatablesCutPattern.document(panels: panels, settings: settings, revision: 0),
            diagnostics: diagnostics
        )
    }

    private static func seamPairs(for panels: [FlatPanel]) -> [SeamPair] {
        guard panels.count > 1 else { return [] }
        return panels.indices.map { index in
            let next = (index + 1) % panels.count
            return SeamPair(
                id: "S\(index + 1)",
                panelA: panels[index].id,
                edgeA: 0,
                panelB: panels[next].id,
                edgeB: 0
            )
        }
    }
}
