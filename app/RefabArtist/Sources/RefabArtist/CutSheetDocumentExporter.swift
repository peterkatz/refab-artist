import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Renders the CutSheetDocument — the SAME artifact the GUI sheet preview
/// shows — to SVG and PDF. One source of truth: packed sheets, split pieces,
/// engrave-fitted labels, and the laser color convention (BLUE = cut,
/// RED = scored guides + labels), exactly as previewed. The legacy per-mode
/// writers laid parts out in rows with their own labels, so what you saw was
/// never what you exported.
enum CutSheetDocumentExporter {
    static let cutColor = (r: 0.0, g: 0.0, b: 1.0)
    static let guideColor = (r: 1.0, g: 0.0, b: 0.0)
    /// Hairline for cutters; engravers treat red text as engrave content.
    static let strokeWidthMM = 0.1
    static let sheetGapMM = 10.0

    // MARK: - SVG

    static func writeSVG(document: CutSheetDocument, settings: ExportLayoutSettings, to url: URL) throws {
        let sheetW = settings.sanitized.sheetWidth
        let sheetH = settings.sanitized.sheetHeight
        let sheetCount = max(1, document.sheets.count)
        let totalH = Double(sheetCount) * sheetH + Double(sheetCount - 1) * sheetGapMM

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(fmt(sheetW))mm" height="\(fmt(totalH))mm" viewBox="0 0 \(fmt(sheetW)) \(fmt(totalH))">

        """
        for (index, sheet) in document.sheets.enumerated() {
            let offsetY = Double(index) * (sheetH + sheetGapMM)
            svg += "<g id=\"sheet-\(index + 1)\" transform=\"translate(0 \(fmt(offsetY)))\">\n"
            svg += "<rect x=\"0\" y=\"0\" width=\"\(fmt(sheetW))\" height=\"\(fmt(sheetH))\" fill=\"none\" stroke=\"#888888\" stroke-width=\"\(fmt(strokeWidthMM))\"/>\n"
            for part in sheet.parts {
                svg += "<g id=\"part-\(escapeXML(part.label))\">\n"
                for loop in part.cutLoops where loop.count >= 2 {
                    svg += pathElement(points: loop, closed: true, color: "#0000FF")
                }
                for open in part.openCuts where open.count >= 2 {
                    svg += pathElement(points: open, closed: false, color: "#0000FF")
                }
                for guide in part.guideLines where guide.count >= 2 {
                    svg += pathElement(points: guide, closed: false, color: "#FF0000")
                }
                for fold in part.foldLines where fold.count >= 2 {
                    svg += pathElement(points: fold, closed: false, color: part.foldsArePerforated ? "#0000FF" : "#FF0000")
                }
                for circle in part.circles {
                    svg += "<circle cx=\"\(fmt(circle.center.x))\" cy=\"\(fmt(circle.center.y))\" r=\"\(fmt(circle.radius))\" fill=\"none\" stroke=\"#0000FF\" stroke-width=\"\(fmt(strokeWidthMM))\"/>\n"
                }
                for hole in part.holeLoops where hole.count >= 3 {
                    svg += pathElement(points: hole, closed: true, color: "#0000FF")
                }
                let size = CutSheetRenderModel.labelSize(radius: part.labelRadius, characterCount: part.label.count)
                svg += labelElement(part.label, at: part.labelAnchor, size: size)
                svg += "</g>\n"
            }
            svg += "</g>\n"
        }
        svg += "</svg>\n"
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - DXF (laser-cut format — same packed document as the preview)

    /// Render the cut-sheet document to DXF. Critically, this is the SAME
    /// `CutSheetDocument` the preview/SVG/PDF use — the legacy per-mode DXF
    /// writers diverged from the preview (e.g. curve/3D came out with the wrong
    /// or no slots), so cutting from DXF produced unbuildable parts even when
    /// the preview looked right. LINE entities grouped by part label (cut on the
    /// part layer, scored guides on a `_guide` layer). The document's
    /// coordinates run down the sheet; DXF's run up, so each sheet is turned
    /// the right way up (`dxfY`): sheet 1 spans 0…sheet height, and each
    /// further sheet lies below the one before, as in the preview.
    static func writeDXF(document: CutSheetDocument, settings: ExportLayoutSettings, to url: URL) throws {
        let sheetH = settings.sanitized.sheetHeight
        let sheetW = settings.sanitized.sheetWidth
        var out = ""
        func pair(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }
        func num(_ code: Int, _ value: Double) { out += "\(code)\n\(String(format: "%.6f", value))\n" }
        func line(_ layer: String, _ a: Vec2, _ b: Vec2, dy: Double) {
            pair(0, "LINE"); pair(8, layer)
            num(10, a.x); num(20, dy - a.y); num(30, 0)
            num(11, b.x); num(21, dy - b.y); num(31, 0)
        }
        func polyline(_ layer: String, _ pts: [Vec2], closed: Bool, dy: Double) {
            guard pts.count >= 2 else { return }
            for i in 0..<(pts.count - 1) { line(layer, pts[i], pts[i + 1], dy: dy) }
            if closed, let f = pts.first, let l = pts.last, f != l { line(layer, l, f, dy: dy) }
        }
        pair(0, "SECTION"); pair(2, "ENTITIES")
        for (index, sheet) in document.sheets.enumerated() {
            let dy = dxfY(sheetIndex: index, sheetHeight: sheetH)
            if settings.sanitized.hasSheetSize {
                let layer = index == 0 ? "sheet_boundary" : "sheet_boundary_\(index + 1)"
                polyline(layer, [Vec2(x: 0, y: 0), Vec2(x: sheetW, y: 0),
                                 Vec2(x: sheetW, y: sheetH), Vec2(x: 0, y: sheetH)], closed: true, dy: dy)
            }
            for part in sheet.parts {
                for loop in part.cutLoops { polyline(part.label, loop, closed: true, dy: dy) }
                for hole in part.holeLoops { polyline(part.label, hole, closed: true, dy: dy) }
                for open in part.openCuts { polyline(part.label, open, closed: false, dy: dy) }
                for guide in part.guideLines { polyline(part.label + "_guide", guide, closed: false, dy: dy) }
                for fold in part.foldLines { polyline(foldLayer, fold, closed: false, dy: dy) }
                for circle in part.circles {
                    pair(0, "CIRCLE"); pair(8, part.label)
                    num(10, circle.center.x); num(20, dy - circle.center.y); num(30, 0)
                    num(40, circle.radius)
                }
            }
        }
        pair(0, "ENDSEC"); pair(0, "EOF")
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The DXF layer fold lines are drawn on, for every part: neither a cut
    /// of the part nor an assembly guide. With Perforate on they are dashes
    /// to cut through (a perforated crease); with it off, full lines to
    /// score.
    static let foldLayer = "fold-line"

    /// Where a sheet's top edge lies in the DXF: a document point at `y` on
    /// sheet `sheetIndex` is written at `dxfY(...) - y`, so the sheet comes
    /// out the right way up with sheet 1 from 0 to `sheetHeight` and each
    /// further sheet `sheetGapMM` below the one before.
    static func dxfY(sheetIndex: Int, sheetHeight: Double) -> Double {
        sheetHeight - Double(sheetIndex) * (sheetHeight + sheetGapMM)
    }

    // MARK: - EPS (one file per sheet, as the preview shows them)

    /// Render the cut-sheet document to EPS: one EPS per sheet, the right
    /// way up, cuts blue and scored guides and labels red, as the preview
    /// shows them. Several sheets are written as a ZIP of
    /// `<name>-sheet-01.eps`, `<name>-sheet-02.eps`, …; one sheet as a plain
    /// EPS. A document without a sheet size gets pages fitted to its parts.
    static func writeEPS(document: CutSheetDocument, settings: ExportLayoutSettings, to url: URL) throws {
        let pages = document.sheets.isEmpty
            ? [epsPage(sheet: CutSheetSheet(index: 1, parts: []), document: document, settings: settings)]
            : document.sheets.map { epsPage(sheet: $0, document: document, settings: settings) }
        guard pages.count > 1 else {
            try pages[0].write(to: url, atomically: true, encoding: .ascii)
            return
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        let entries = pages.enumerated().map { index, page in
            ZipWriter.Entry(name: "\(baseName)-sheet-\(String(format: "%02d", index + 1)).eps", data: Data(page.utf8))
        }
        try ZipWriter.write(entries: entries, to: url)
    }

    /// The number of EPS files `writeEPS` writes for `document` (a ZIP when
    /// more than one).
    static func epsFileCount(document: CutSheetDocument) -> Int {
        max(1, document.sheets.count)
    }

    private static func epsPage(sheet: CutSheetSheet, document: CutSheetDocument, settings: ExportLayoutSettings) -> String {
        let mmToPt = 72.0 / 25.4
        var sheetW = document.sheetWidth > 0 ? document.sheetWidth : settings.sanitized.sheetWidth
        var sheetH = document.sheetHeight > 0 ? document.sheetHeight : settings.sanitized.sheetHeight
        if sheetW <= 0 || sheetH <= 0 {
            // No sheet size: a page that holds this sheet's parts.
            let margin = settings.sanitized.pageMargin
            sheetW = (sheet.parts.map(\.bounds.max.x).max() ?? 0) + margin
            sheetH = (sheet.parts.map(\.bounds.max.y).max() ?? 0) + margin
        }
        func pt(_ value: Double) -> String { String(format: "%.3f", value * mmToPt) }
        // Document y runs down the sheet; PostScript's runs up.
        func xy(_ point: Vec2) -> String { "\(pt(point.x)) \(pt(sheetH - point.y))" }
        func path(_ points: [Vec2], closed: Bool) -> String {
            guard let first = points.first, points.count >= 2 else { return "" }
            var line = "newpath \(xy(first)) moveto"
            for point in points.dropFirst() {
                line += " \(xy(point)) lineto"
            }
            return line + (closed ? " closepath stroke\n" : " stroke\n")
        }
        var out = ""
        out += "%!PS-Adobe-3.0 EPSF-3.0\n"
        out += "%%Creator: Refab Artist\n"
        out += "%%BoundingBox: 0 0 \(Int(ceil(sheetW * mmToPt))) \(Int(ceil(sheetH * mmToPt)))\n"
        out += "%%LanguageLevel: 2\n"
        out += "%%Pages: 1\n"
        out += "%%EndComments\n"
        // (string) size U: show the string underlined (labels mark 6 and 9).
        out += "/U { /sz exch def currentpoint /y0 exch def /x0 exch def show currentpoint pop /x1 exch def "
        out += "gsave newpath x0 y0 sz 0.12 mul sub moveto x1 y0 sz 0.12 mul sub lineto sz 0.06 mul setlinewidth stroke grestore "
        out += "x1 y0 moveto } def\n"
        out += "\(pt(strokeWidthMM)) setlinewidth\n"
        out += "0.533 setgray\n"
        out += path([Vec2(x: 0, y: 0), Vec2(x: sheetW, y: 0), Vec2(x: sheetW, y: sheetH), Vec2(x: 0, y: sheetH)], closed: true)
        for part in sheet.parts {
            out += "\(cutColor.r) \(cutColor.g) \(cutColor.b) setrgbcolor\n"
            for loop in part.cutLoops where loop.count >= 2 {
                out += path(loop, closed: true)
            }
            for open in part.openCuts where open.count >= 2 {
                out += path(open, closed: false)
            }
            for hole in part.holeLoops where hole.count >= 3 {
                out += path(hole, closed: true)
            }
            for circle in part.circles {
                out += "newpath \(xy(circle.center)) \(pt(circle.radius)) 0 360 arc closepath stroke\n"
            }
            if part.foldsArePerforated {
                for fold in part.foldLines where fold.count >= 2 {
                    out += path(fold, closed: false)
                }
            }
            out += "\(guideColor.r) \(guideColor.g) \(guideColor.b) setrgbcolor\n"
            for guide in part.guideLines where guide.count >= 2 {
                out += path(guide, closed: false)
            }
            if !part.foldsArePerforated {
                for fold in part.foldLines where fold.count >= 2 {
                    out += path(fold, closed: false)
                }
            }
            let size = CutSheetRenderModel.labelSize(radius: part.labelRadius, characterCount: part.label.count)
            guard size > 0.2, !part.label.isEmpty else { continue }
            let points = pt(size)
            out += "/Helvetica findfont \(points) scalefont setfont\n"
            out += "newpath \(xy(part.labelAnchor)) moveto (\(epsEscape(part.label))) stringwidth pop 2 div neg "
            out += "\(points) -0.35 mul rmoveto\n"
            for character in part.label {
                let piece = "(\(epsEscape(String(character))))"
                out += character == "6" || character == "9" ? "\(piece) \(points) U\n" : "\(piece) show\n"
            }
        }
        out += "showpage\n"
        out += "%%EOF\n"
        return out
    }

    private static func epsEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    // MARK: - Part frames (where each DXF part sits in the model)

    /// Write, for every part whose builder knows its plane, the affine map
    /// from the part's coordinates in the DXF that `writeDXF` writes to model
    /// coordinates: `model = dxfToModel * (x, y, 1)`, one row per model axis.
    /// With these, a checker can put the cut parts back where they belong in
    /// the model and test that crossing parts' slots mate. A part the sheet
    /// shows blue (not joined to the rest of the model) is marked
    /// `"detached": true`. `toModel`, when given, maps a point of the model
    /// the document was cut from to the model the frames are for: under a
    /// Slice Direction tilt the parts are cut from the model turned into the
    /// slicing frame, and `toModel` turns them back onto the model as
    /// imported (`MeshScaler.unrotating`). Without it the frames are for the
    /// model the document was cut from.
    static func writePartFrames(
        document: CutSheetDocument,
        settings: ExportLayoutSettings,
        to url: URL,
        toModel: ((Vec3) -> Vec3)? = nil
    ) throws {
        let sheetH = settings.sanitized.sheetHeight
        var parts: [[String: Any]] = []
        for (index, sheet) in document.sheets.enumerated() {
            let dy = dxfY(sheetIndex: index, sheetHeight: sheetH)
            for part in sheet.parts {
                guard let frame = part.planeFrame else { continue }
                func model(_ x: Double, _ y: Double) -> Vec3 {
                    let point = frame.modelPoint(part.planPoint(fromSheetPoint: Vec2(x: x, y: dy - y)))
                    return toModel?(point) ?? point
                }
                let origin = model(0, 0)
                let alongX = model(1, 0)
                let alongY = model(0, 1)
                let rows = [
                    [alongX.x - origin.x, alongY.x - origin.x, origin.x],
                    [alongX.y - origin.y, alongY.y - origin.y, origin.y],
                    [alongX.z - origin.z, alongY.z - origin.z, origin.z]
                ]
                var entry: [String: Any] = [
                    "label": part.label,
                    "sheet": sheet.index,
                    "dxfToModel": rows
                ]
                if part.isDetached {
                    // Shown blue: not joined to the rest of the model.
                    entry["detached"] = true
                }
                parts.append(entry)
            }
        }
        var object: [String: Any] = ["parts": parts]
        let folds = foldedPartFrames(document: document, settings: settings, toModel: toModel)
        if !folds.isEmpty {
            object["folds"] = folds
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url)
    }

    /// For every Folded Panels net, each panel's map from DXF coordinates to
    /// model coordinates (as `writePartFrames` gives a flat part's), the
    /// direction from its outside face into its stock, its outline and the
    /// joint features that stand out of it in DXF coordinates, and which
    /// panels a fold joins. A checker can fold the net back up with these and
    /// test that no two pieces of stock pass into each other. `toModel` as
    /// for `writePartFrames`.
    private static func foldedPartFrames(
        document: CutSheetDocument,
        settings: ExportLayoutSettings,
        toModel: ((Vec3) -> Vec3)?
    ) -> [[String: Any]] {
        let sheetH = settings.sanitized.sheetHeight
        var folds: [[String: Any]] = []
        for (index, sheet) in document.sheets.enumerated() {
            let dy = dxfY(sheetIndex: index, sheetHeight: sheetH)
            for part in sheet.parts where !part.foldedPanels.isEmpty {
                func dxf(_ p: Vec2) -> [Double] {
                    let q = part.sheetPoint(fromPlanPoint: p)
                    return [q.x, dy - q.y]
                }
                let panels: [[String: Any]] = part.foldedPanels.map { panel in
                    func model(_ x: Double, _ y: Double) -> Vec3 {
                        let point = panel.frame.modelPoint(part.planPoint(fromSheetPoint: Vec2(x: x, y: dy - y)))
                        return toModel?(point) ?? point
                    }
                    let origin = model(0, 0)
                    let alongX = model(1, 0)
                    let alongY = model(0, 1)
                    // A direction is turned as the step it makes from a
                    // point: where `toModel` takes the point one unit along
                    // it from the origin, less the origin.
                    var inward = panel.inward
                    if let toModel {
                        let start = panel.frame.modelPoint(part.planPoint(fromSheetPoint: Vec2(x: 0, y: dy)))
                        let tip = toModel(Vec3(x: start.x + inward.x, y: start.y + inward.y, z: start.z + inward.z))
                        inward = Vec3(x: tip.x - origin.x, y: tip.y - origin.y, z: tip.z - origin.z)
                    }
                    return [
                        "dxfToModel": [
                            [alongX.x - origin.x, alongY.x - origin.x, origin.x],
                            [alongX.y - origin.y, alongY.y - origin.y, origin.y],
                            [alongX.z - origin.z, alongY.z - origin.z, origin.z]
                        ],
                        "inward": [inward.x, inward.y, inward.z],
                        "region": panel.region.map(dxf),
                        "features": panel.features.map { $0.map(dxf) }
                    ]
                }
                folds.append([
                    "label": part.label,
                    "sheet": sheet.index,
                    "panels": panels,
                    "hinges": part.foldedHinges.map { [$0.a, $0.b] }
                ])
            }
        }
        return folds
    }

    private static func pathElement(points: [Vec2], closed: Bool, color: String) -> String {
        var d = "M \(fmt(points[0].x)) \(fmt(points[0].y))"
        for p in points.dropFirst() {
            d += " L \(fmt(p.x)) \(fmt(p.y))"
        }
        if closed { d += " Z" }
        return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(fmt(strokeWidthMM))\"/>\n"
    }

    private static func labelElement(_ label: String, at anchor: Vec2, size: Double) -> String {
        // Per-character tspans so 6 and 9 carry a disambiguating underline.
        var inner = ""
        for character in label {
            let piece = escapeXML(String(character))
            if character == "6" || character == "9" {
                inner += "<tspan text-decoration=\"underline\">\(piece)</tspan>"
            } else {
                inner += piece
            }
        }
        return "<text x=\"\(fmt(anchor.x))\" y=\"\(fmt(anchor.y))\" fill=\"#FF0000\" font-family=\"Helvetica\" font-size=\"\(fmt(size))\" text-anchor=\"middle\" dominant-baseline=\"central\">\(inner)</text>\n"
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - PDF (Illustrator opens this natively, colors intact)

    static func writePDF(document: CutSheetDocument, settings: ExportLayoutSettings, to url: URL) throws {
        let sheetW = settings.sanitized.sheetWidth
        let sheetH = settings.sanitized.sheetHeight
        let mmToPt = 72.0 / 25.4
        var mediaBox = CGRect(x: 0, y: 0, width: sheetW * mmToPt, height: sheetH * mmToPt)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "CutSheetDocumentExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the PDF file."])
        }
        let cut = CGColor(red: cutColor.r, green: cutColor.g, blue: cutColor.b, alpha: 1)
        let guide = CGColor(red: guideColor.r, green: guideColor.g, blue: guideColor.b, alpha: 1)

        for sheet in document.sheets {
            context.beginPDFPage(nil)
            context.saveGState()
            // Work in mm with Y down to match the document's coordinates.
            context.scaleBy(x: mmToPt, y: mmToPt)
            context.translateBy(x: 0, y: sheetH)
            context.scaleBy(x: 1, y: -1)
            context.setLineWidth(strokeWidthMM)

            for part in sheet.parts {
                context.setStrokeColor(cut)
                for loop in part.cutLoops where loop.count >= 2 {
                    stroke(points: loop, closed: true, in: context)
                }
                for open in part.openCuts where open.count >= 2 {
                    stroke(points: open, closed: false, in: context)
                }
                for circle in part.circles {
                    context.strokeEllipse(in: CGRect(
                        x: circle.center.x - circle.radius,
                        y: circle.center.y - circle.radius,
                        width: circle.radius * 2,
                        height: circle.radius * 2
                    ))
                }
                for hole in part.holeLoops where hole.count >= 3 {
                    stroke(points: hole, closed: true, in: context)
                }
                if part.foldsArePerforated {
                    for fold in part.foldLines where fold.count >= 2 {
                        stroke(points: fold, closed: false, in: context)
                    }
                }
                context.setStrokeColor(guide)
                for line in part.guideLines where line.count >= 2 {
                    stroke(points: line, closed: false, in: context)
                }
                if !part.foldsArePerforated {
                    for fold in part.foldLines where fold.count >= 2 {
                        stroke(points: fold, closed: false, in: context)
                    }
                }
                drawLabel(part, in: context)
            }
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func stroke(points: [Vec2], closed: Bool, in context: CGContext) {
        context.beginPath()
        context.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for p in points.dropFirst() {
            context.addLine(to: CGPoint(x: p.x, y: p.y))
        }
        if closed { context.closePath() }
        context.strokePath()
    }

    private static func drawLabel(_ part: CutSheetPart, in context: CGContext) {
        let size = CutSheetRenderModel.labelSize(radius: part.labelRadius, characterCount: part.label.count)
        guard size > 0.2 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSMutableAttributedString()
        for character in part.label {
            let attributes: [NSAttributedString.Key: Any] = character == "6" || character == "9"
                ? [.font: font, .foregroundColor: NSColor.red, .underlineStyle: NSUnderlineStyle.single.rawValue]
                : [.font: font, .foregroundColor: NSColor.red]
            attributed.append(NSAttributedString(string: String(character), attributes: attributes))
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        context.saveGState()
        // Un-flip locally so glyphs render upright.
        context.translateBy(x: part.labelAnchor.x, y: part.labelAnchor.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2 + abs(bounds.minY))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

