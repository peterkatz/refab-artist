import Foundation

/// The EPS writer: one EPS per sheet, written as a ZIP archive when the
/// layout has more than one sheet (NEO-109). Single-sheet layouts write a
/// plain .eps file (no wrapping needed).
extension EpsExporter {

    /// Returns the EPS string for a single sheet (0-based `sheetIndex`) by
    /// filtering the layout's parts to only those whose Y-offset falls within
    /// the sheet's Y band, and re-origin-ing them to (0, 0). A layout with no
    /// sheet size is one page holding every part.
    static func buildSheetEPS(layout: Layout, sheetIndex: Int) -> String {
        let hasSheet = layout.sheetWidth > 0 && layout.sheetHeight > 0
        let sheetH = hasSheet ? layout.sheetHeight : layout.pageHeight
        let sheetW = hasSheet ? layout.sheetWidth : layout.pageWidth
        let mmToPt = 72.0 / 25.4

        let yMin = Double(sheetIndex) * sheetH
        let yMax = Double(sheetIndex + 1) * sheetH

        // Filter parts belonging to this sheet; shift their Y offset so the
        // sheet origin becomes (0, 0).
        let sheetParts = layout.parts.compactMap { part -> Part? in
            guard !hasSheet || (part.offset.y >= yMin - 0.001 && part.offset.y < yMax + 0.001) else {
                return nil
            }
            return Part(
                label: part.label,
                offset: Vec2(x: part.offset.x, y: part.offset.y - yMin),
                lines: part.lines,
                circles: part.circles,
                bounds: part.bounds
            )
        }

        let widthPt  = Int(ceil(sheetW * mmToPt))
        let heightPt = Int(ceil(sheetH * mmToPt))

        var output = ""
        output += "%!PS-Adobe-3.0 EPSF-3.0\n"
        output += "%%Creator: Refab Artist\n"
        output += "%%BoundingBox: 0 0 \(widthPt) \(heightPt)\n"
        output += "%%LanguageLevel: 2\n"
        output += "%%Pages: 1\n"
        output += "%%EndComments\n"
        output += "/Helvetica findfont 8 scalefont setfont\n"
        output += "0 setgray\n"
        output += "0.35 setlinewidth\n"

        // Sheet border
        output += "newpath 0 0 moveto \(format(sheetW * mmToPt)) 0 lineto \(format(sheetW * mmToPt)) \(format(sheetH * mmToPt)) lineto 0 \(format(sheetH * mmToPt)) lineto closepath stroke\n"

        for part in sheetParts {
            let labelY = (part.offset.y + part.bounds.max.y + 3) * mmToPt
            let labelX = (part.offset.x + part.bounds.min.x) * mmToPt
            output += "\(format(labelX)) \(format(labelY)) moveto (\(epsEscape(part.label))) show\n"

            for line in part.lines {
                let sx = (line.start.x + part.offset.x) * mmToPt
                let sy = (line.start.y + part.offset.y) * mmToPt
                let ex = (line.end.x + part.offset.x) * mmToPt
                let ey = (line.end.y + part.offset.y) * mmToPt
                output += "newpath \(format(sx)) \(format(sy)) moveto \(format(ex)) \(format(ey)) lineto stroke\n"
            }

            for circle in part.circles {
                let cx = (circle.center.x + part.offset.x) * mmToPt
                let cy = (circle.center.y + part.offset.y) * mmToPt
                let r  = circle.radius * mmToPt
                output += "newpath \(format(cx)) \(format(cy)) \(format(r)) 0 360 arc stroke\n"
            }
        }

        output += "showpage\n"
        output += "%%EOF\n"
        return output
    }

    /// Writes a ZIP of per-sheet EPS files when sheetCount > 1, or a plain
    /// EPS when sheetCount == 1.
    ///
    /// Member filenames inside the ZIP follow the base name of `url`:
    /// `basename-sheet-01.eps`, `basename-sheet-02.eps`, …
    static func write(layout: Layout, to url: URL) throws {
        let sheetCount = fileCount(layout)

        guard sheetCount > 1 else {
            // Single sheet — plain .eps.
            let eps = buildSingleSheetEPS(layout: layout, sheetIndex: 0)
            try eps.write(to: url, atomically: true, encoding: .ascii)
            return
        }

        // Multi-sheet — ZIP of per-sheet files.
        let baseName = url.deletingPathExtension().lastPathComponent
        var entries: [ZipWriter.Entry] = []
        for i in 0..<sheetCount {
            let eps = buildSheetEPS(layout: layout, sheetIndex: i)
            let memberName = "\(baseName)-sheet-\(String(format: "%02d", i + 1)).eps"
            entries.append(ZipWriter.Entry(name: memberName, data: Data(eps.utf8)))
        }
        try ZipWriter.write(entries: entries, to: url)
    }

    /// How many EPS files `write` writes for `layout`: one per sheet, and
    /// one when the layout has no sheet size.
    static func fileCount(_ layout: Layout) -> Int {
        max(1, layout.sheetCount)
    }

    // MARK: - Private helpers

    private static func buildSingleSheetEPS(layout: Layout, sheetIndex: Int) -> String {
        buildSheetEPS(layout: layout, sheetIndex: sheetIndex)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func epsEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
