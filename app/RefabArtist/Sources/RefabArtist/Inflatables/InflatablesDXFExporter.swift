import Foundation

enum InflatablesDXFExporter {
    enum Layer {
        static let cut = "CUT"
        static let seam = "SEAM"
        static let foldRegistration = "FOLD_REG"
        static let baffleAttach = "BAFFLE_ATTACH"
        static let label = "LABEL"
    }

    private enum Color {
        static let red = 1
        static let yellow = 2
        static let green = 3
        static let cyan = 4
        static let blue = 5
        static let magenta = 6
    }

    static func write(plan: InflatablesPlan, settings: ExportLayoutSettings, to url: URL) throws {
        try write(document: plan.cutSheet, settings: settings, to: url)
    }

    /// The cut sheet as DXF: cuts on `CUT`, seams on `SEAM`, each sheet's
    /// edge on `FOLD_REG` and part labels as text on `LABEL`. The document's
    /// coordinates run down the sheet and DXF's run up, so each sheet is
    /// turned the right way up as the cut-sheet DXF is
    /// (`CutSheetDocumentExporter.dxfY`): sheet 1 spans 0 to the sheet
    /// height and each further sheet lies below the one before, as in the
    /// preview.
    static func write(document: CutSheetDocument, settings: ExportLayoutSettings, to url: URL) throws {
        let sheet = settings.sanitized
        var out = ""
        func pair(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }
        func num(_ code: Int, _ value: Double) { out += "\(code)\n\(String(format: "%.6f", value))\n" }

        func layer(_ name: String, _ color: Int) {
            pair(0, "LAYER")
            pair(2, name)
            pair(70, "0")
            pair(62, "\(color)")
            pair(6, "CONTINUOUS")
        }

        func line(_ layer: String, _ color: Int, _ a: Vec2, _ b: Vec2, _ dy: Double) {
            pair(0, "LINE")
            pair(8, layer)
            pair(62, "\(color)")
            num(10, a.x); num(20, dy - a.y); num(30, 0)
            num(11, b.x); num(21, dy - b.y); num(31, 0)
        }

        func polyline(_ layer: String, _ color: Int, _ points: [Vec2], closed: Bool, dy: Double) {
            guard points.count >= 2 else { return }
            for index in 0..<(points.count - 1) {
                line(layer, color, points[index], points[index + 1], dy)
            }
            if closed, let first = points.first, let last = points.last, first != last {
                line(layer, color, last, first, dy)
            }
        }

        func text(_ value: String, at point: Vec2, height: Double, dy: Double) {
            pair(0, "TEXT")
            pair(8, Layer.label)
            pair(62, "\(Color.magenta)")
            num(10, point.x); num(20, dy - point.y); num(30, 0)
            num(40, max(height, 1.5))
            pair(1, value)
            pair(7, "STANDARD")
        }

        pair(0, "SECTION")
        pair(2, "TABLES")
        pair(0, "TABLE")
        pair(2, "LAYER")
        pair(70, "5")
        layer(Layer.cut, Color.red)
        layer(Layer.seam, Color.blue)
        layer(Layer.foldRegistration, Color.green)
        layer(Layer.baffleAttach, Color.cyan)
        layer(Layer.label, Color.magenta)
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")

        pair(0, "SECTION")
        pair(2, "ENTITIES")
        for (sheetIndex, sheetData) in document.sheets.enumerated() {
            let dy = CutSheetDocumentExporter.dxfY(sheetIndex: sheetIndex, sheetHeight: sheet.sheetHeight)
            if sheet.hasSheetSize {
                polyline(
                    Layer.foldRegistration,
                    Color.green,
                    [
                        Vec2(x: 0, y: 0),
                        Vec2(x: sheet.sheetWidth, y: 0),
                        Vec2(x: sheet.sheetWidth, y: sheet.sheetHeight),
                        Vec2(x: 0, y: sheet.sheetHeight)
                    ],
                    closed: true,
                    dy: dy
                )
            }
            for part in sheetData.parts {
                for loop in part.cutLoops {
                    polyline(Layer.cut, Color.red, loop, closed: true, dy: dy)
                }
                for loop in part.holeLoops {
                    polyline(Layer.cut, Color.red, loop, closed: true, dy: dy)
                }
                for open in part.openCuts {
                    polyline(Layer.cut, Color.red, open, closed: false, dy: dy)
                }
                for guide in part.guideLines {
                    polyline(Layer.seam, Color.blue, guide, closed: false, dy: dy)
                }
                for circle in part.circles {
                    pair(0, "CIRCLE")
                    pair(8, Layer.cut)
                    pair(62, "\(Color.red)")
                    num(10, circle.center.x); num(20, dy - circle.center.y); num(30, 0)
                    num(40, circle.radius)
                }
                let labelHeight = CutSheetRenderModel.labelSize(
                    radius: part.labelRadius,
                    characterCount: part.label.count
                )
                text(part.label, at: part.labelAnchor, height: labelHeight, dy: dy)
            }
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}
