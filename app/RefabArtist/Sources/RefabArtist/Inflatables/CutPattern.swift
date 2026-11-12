import Foundation

enum InflatablesCutPattern {
    static func panels(from flattened: [InflatableFlattenedChart], settings: InflatablesSettings) -> [FlatPanel] {
        flattened.enumerated().map { index, chart in
            let seam = normalized(chart.outline2D)
            let cut = offsetRadially(seam, by: settings.seamAllowanceMM)
            return FlatPanel(
                id: chart.chart.id.isEmpty ? "P\(index + 1)" : chart.chart.id,
                cutOutline2D: cut,
                seamLine2D: seam,
                sourceFaceIDs: chart.chart.sourceFaceIDs,
                registration: registrationMarks(for: seam, id: chart.chart.id),
                labelAnchor: centroid(seam),
                isBaffle: false,
                baffleAttachLines2D: [],
                mirrored: false
            )
        }
    }

    static func document(panels: [FlatPanel], settings: InflatablesSettings, revision: Int) -> CutSheetDocument {
        guard !panels.isEmpty else { return emptyDocument(revision: revision) }
        let sheetWidth = settings.rollWidthMM ?? ExportLayoutSettings.defaultValue.sheetWidth
        let sheetHeight = ExportLayoutSettings.defaultValue.sheetHeight
        let margin = ExportLayoutSettings.defaultValue.pageMargin
        let spacing = ExportLayoutSettings.defaultValue.partSpacing
        let contentWidth = max(sheetWidth - 2 * margin, 1)

        var parts: [CutSheetPart] = []
        var cursor = Vec2(x: margin, y: margin)
        var rowHeight = 0.0
        var sheetIndex = 1
        var sheets: [CutSheetSheet] = [CutSheetSheet(index: sheetIndex, parts: [])]

        for panel in panels {
            let panelBounds = bounds(of: panel.cutOutline2D)
            let width = panelBounds.max.x - panelBounds.min.x
            let height = panelBounds.max.y - panelBounds.min.y
            if cursor.x > margin, cursor.x + width > margin + contentWidth {
                cursor.x = margin
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }
            if cursor.y > margin, cursor.y + height > sheetHeight - margin {
                sheetIndex += 1
                sheets.append(CutSheetSheet(index: sheetIndex, parts: []))
                cursor = Vec2(x: margin, y: margin)
                rowHeight = 0
            }

            let offset = Vec2(x: cursor.x - panelBounds.min.x, y: cursor.y - panelBounds.min.y)
            let cut = panel.cutOutline2D.map { $0 + offset }
            let seam = panel.seamLine2D.map { $0 + offset }
            let attach = panel.baffleAttachLines2D.map { $0.map { $0 + offset } }
            let partBounds = bounds(of: cut)
            let part = CutSheetPart(
                label: panel.id,
                stepIndex: nil,
                cutLoops: [cut],
                openCuts: [],
                guideLines: [seam] + attach,
                circles: [],
                holeLoops: [],
                bounds: partBounds,
                labelAnchor: panel.labelAnchor + offset,
                labelRadius: max(4, min(width, height) * 0.2),
                overflowsSheet: width > contentWidth || height > sheetHeight - 2 * margin,
                isError: false,
                isDetached: false,
                rotatedOnSheet: false,
                planMin: panelBounds.min
            )
            sheets[sheets.count - 1].parts.append(part)
            parts.append(part)
            cursor.x += width + spacing
            rowHeight = max(rowHeight, height)
        }

        return CutSheetDocument(sheetWidth: sheetWidth, sheetHeight: sheetHeight, sheets: sheets, revision: revision)
    }

    static func emptyDocument(revision: Int) -> CutSheetDocument {
        CutSheetDocument(
            sheetWidth: ExportLayoutSettings.defaultValue.sheetWidth,
            sheetHeight: ExportLayoutSettings.defaultValue.sheetHeight,
            sheets: [],
            revision: revision
        )
    }

    private static func normalized(_ polygon: [Vec2]) -> [Vec2] {
        guard let minX = polygon.map(\.x).min(), let minY = polygon.map(\.y).min() else { return polygon }
        return polygon.map { Vec2(x: $0.x - minX, y: $0.y - minY) }
    }

    private static func registrationMarks(for polygon: [Vec2], id: String) -> [RegistrationMark] {
        guard polygon.count >= 2 else { return [] }
        return polygon.indices.map { index in
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            return RegistrationMark(
                at: Vec2(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5),
                pairId: "\(id)-E\(index + 1)"
            )
        }
    }

    private static func offsetRadially(_ polygon: [Vec2], by allowance: Double) -> [Vec2] {
        guard allowance > 0 else { return polygon }
        let c = centroid(polygon)
        return polygon.map { point in
            let dx = point.x - c.x
            let dy = point.y - c.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1.0e-9)
            return Vec2(x: point.x + dx / length * allowance, y: point.y + dy / length * allowance)
        }
    }

    private static func centroid(_ polygon: [Vec2]) -> Vec2 {
        guard !polygon.isEmpty else { return Vec2(x: 0, y: 0) }
        let total = polygon.reduce(Vec2(x: 0, y: 0)) { Vec2(x: $0.x + $1.x, y: $0.y + $1.y) }
        return Vec2(x: total.x / Double(polygon.count), y: total.y / Double(polygon.count))
    }

    private static func bounds(of polygon: [Vec2]) -> SvgExporter.Bounds2 {
        guard let first = polygon.first else {
            return SvgExporter.Bounds2(min: Vec2(x: 0, y: 0), max: Vec2(x: 0, y: 0))
        }
        var minV = first, maxV = first
        for p in polygon {
            minV = Vec2(x: min(minV.x, p.x), y: min(minV.y, p.y))
            maxV = Vec2(x: max(maxV.x, p.x), y: max(maxV.y, p.y))
        }
        return SvgExporter.Bounds2(min: minV, max: maxV)
    }
}

private extension Vec2 {
    static func + (lhs: Vec2, rhs: Vec2) -> Vec2 {
        Vec2(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}
