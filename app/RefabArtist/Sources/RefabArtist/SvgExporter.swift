import Foundation

/// Row-by-row sheet layout of flat parts, used by the EPS writer. SVG
/// export itself renders the cut sheet (CutSheetDocumentExporter, via
/// FlatPartExport).
enum SvgExporter {
    struct Layout: Equatable {
        var width: Double
        var height: Double
        var pageMargin: Double
        var sheetWidth: Double
        var sheetHeight: Double
        var usedWidth: Double
        var usedHeight: Double
        var overflowsSheet: Bool
        var parts: [Part]

        var partCount: Int {
            parts.count
        }

        var sheetCount: Int {
            guard sheetWidth > 0, sheetHeight > 0 else {
                return 0
            }
            return max(1, Int(ceil(height / sheetHeight)))
        }

        var sheetPartCounts: [Int] {
            guard sheetCount > 0 else {
                return []
            }
            var counts = Array(repeating: 0, count: sheetCount)
            for part in parts {
                counts[sheetIndex(for: part) - 1] += 1
            }
            return counts
        }

        var sheetUtilization: Double? {
            guard sheetWidth > 0, sheetHeight > 0 else {
                return nil
            }
            return (usedWidth * usedHeight) / (sheetWidth * sheetHeight * Double(sheetCount))
        }

        func sheetIndex(for part: Part) -> Int {
            guard sheetHeight > 0 else {
                return 0
            }
            let minY = part.offset.y + part.bounds.min.y
            return min(sheetCount, max(1, Int(floor(max(0, minY) / sheetHeight)) + 1))
        }
    }

    struct Part: Equatable {
        var label: String
        var offset: Vec2
        var lines: [Line]
        var circles: [Circle]
        var bounds: Bounds2
    }

    struct Line: Equatable {
        var start: Vec2
        var end: Vec2
    }

    struct Circle: Equatable {
        var center: Vec2
        var radius: Double
    }

    struct Bounds2: Equatable {
        var min: Vec2
        var max: Vec2
    }

    private struct ContourSet {
        var prefix: String
        var layers: [SliceContourLayer]
        var dowels: DxfExporter.DowelSettings?
    }

    private static let labelHeight = 7.0

    static func layout(
        contours: StackedSliceContours,
        sliceSpacing: Double = 10.0,
        pageMargin: Double = 10.0,
        layoutSettings: ExportLayoutSettings? = nil,
        dowels: DxfExporter.DowelSettings? = nil
    ) -> Layout {
        let settings = layoutSettings ?? ExportLayoutSettings(partSpacing: sliceSpacing, pageMargin: pageMargin)
        return layout(
            contourSets: [
                ContourSet(prefix: "slice", layers: contours.layers, dowels: dowels)
            ],
            layoutSettings: settings
        )
    }

    static func layout(radial plan: RadialSlicePlan, model: MeshSummary, sliceSpacing: Double = 10.0, pageMargin: Double = 10.0, layoutSettings: ExportLayoutSettings? = nil) -> Layout {
        // A plan with no fins (n_radial == 0) is an Interlocked plan;
        // FlatPartExport exports those as Interlocked before reaching this
        // layout.
        let settings = layoutSettings ?? ExportLayoutSettings(partSpacing: sliceSpacing, pageMargin: pageMargin)
        // Rings + fins from the shared disk+wedge generator — the same part
        // geometry as the cut sheet.
        let parts = RadialPartBuilder.assembly(plan: plan, model: model)
        return layout(
            contourSets: [
                ContourSet(
                    prefix: "first_axis",
                    layers: radialPartLayers(parts.disks),
                    dowels: nil
                ),
                ContourSet(
                    prefix: "radial",
                    layers: radialPartLayers(parts.wedges),
                    dowels: nil
                )
            ],
            layoutSettings: settings
        )
    }

    /// One contour layer per disk/wedge model part, its outline and holes
    /// (also used by the DXF writer so both vector paths consume identical
    /// loops).
    static func radialPartLayers(_ parts: [RadialPartBuilder.ModelPart]) -> [SliceContourLayer] {
        parts.compactMap { part in
            guard part.loop.count >= 3 else { return nil }
            return SliceContourLayer(position: part.position, paths: part.paths)
        }
    }

    private static func layout(contourSets: [ContourSet], layoutSettings: ExportLayoutSettings) -> Layout {
        let settings = layoutSettings.sanitized
        var cursorX = settings.pageMargin
        var cursorY = settings.pageMargin
        var rowHeight = 0.0
        var maxContentX = settings.pageMargin
        var maxContentY = settings.pageMargin
        var overflowsSheet = false
        var parts: [Part] = []
        let useSheet = settings.hasSheetSize
        let sheetRightEdge = settings.sheetWidth - settings.pageMargin

        func currentSheetTop(for y: Double) -> Double {
            guard useSheet, settings.sheetHeight > 0 else {
                return 0
            }
            return floor(max(0, y) / settings.sheetHeight) * settings.sheetHeight
        }

        func advanceToNextSheet(from y: Double) -> Double {
            currentSheetTop(for: y) + settings.sheetHeight + settings.pageMargin
        }

        for contourSet in contourSets {
            for (index, layer) in contourSet.layers.enumerated() {
                guard let bounds = layerBounds(layer) else {
                    continue
                }

                var placedLayer = layer
                var placedCircles = dowelCircles(settings: contourSet.dowels, bounds: bounds)
                var placedBounds = bounds
                if shouldRotateToFitSheet(bounds: bounds, settings: settings, useSheet: useSheet) {
                    placedLayer = rotate(layer: layer, bounds: bounds)
                    placedCircles = placedCircles.map { rotate(circle: $0, bounds: bounds) }
                    if let rotatedBounds = layerBounds(placedLayer, circles: placedCircles) {
                        placedBounds = rotatedBounds
                    }
                }

                let width = placedBounds.max.x - placedBounds.min.x
                let height = placedBounds.max.y - placedBounds.min.y
                let footprintHeight = height + labelHeight
                let fitsSheetHeight = !useSheet || footprintHeight + settings.pageMargin * 2 <= settings.sheetHeight
                if useSheet,
                   cursorX > settings.pageMargin,
                   cursorX + width > sheetRightEdge {
                    cursorX = settings.pageMargin
                    cursorY += rowHeight + settings.partSpacing
                    rowHeight = 0
                }
                if useSheet,
                   fitsSheetHeight,
                   cursorY > currentSheetTop(for: cursorY) + settings.pageMargin,
                   cursorY + footprintHeight > currentSheetTop(for: cursorY) + settings.sheetHeight - settings.pageMargin {
                    cursorX = settings.pageMargin
                    cursorY = advanceToNextSheet(from: cursorY)
                    rowHeight = 0
                }
                if useSheet,
                   (width + settings.pageMargin * 2 > settings.sheetWidth ||
                    footprintHeight + settings.pageMargin * 2 > settings.sheetHeight) {
                    overflowsSheet = true
                }

                let offset = Vec2(x: cursorX - placedBounds.min.x, y: cursorY - placedBounds.min.y)
                let label = String(format: "\(contourSet.prefix)_%03d", index + 1)
                parts.append(
                    Part(
                        label: label,
                        offset: offset,
                        lines: lines(in: placedLayer),
                        circles: placedCircles,
                        bounds: placedBounds
                    )
                )

                cursorX += width + settings.partSpacing
                rowHeight = max(rowHeight, footprintHeight)
                maxContentX = max(maxContentX, cursorX - settings.partSpacing)
                maxContentY = max(maxContentY, cursorY + footprintHeight)
            }
        }

        let autoWidth = maxContentX + settings.pageMargin
        let autoHeight = maxContentY + settings.pageMargin
        let sheetCount = useSheet ? max(1, Int(ceil(autoHeight / settings.sheetHeight))) : 0
        let pagedHeight = useSheet ? Double(sheetCount) * settings.sheetHeight : autoHeight
        if useSheet,
           autoWidth > settings.sheetWidth {
            overflowsSheet = true
        }

        return Layout(
            width: useSheet ? max(settings.sheetWidth, autoWidth) : autoWidth,
            height: useSheet ? max(pagedHeight, autoHeight) : autoHeight,
            pageMargin: settings.pageMargin,
            sheetWidth: useSheet ? settings.sheetWidth : 0,
            sheetHeight: useSheet ? settings.sheetHeight : 0,
            usedWidth: autoWidth,
            usedHeight: autoHeight,
            overflowsSheet: overflowsSheet,
            parts: parts
        )
    }

    private static func shouldRotateToFitSheet(bounds: Bounds2, settings: ExportLayoutSettings, useSheet: Bool) -> Bool {
        guard useSheet else {
            return false
        }
        let width = bounds.max.x - bounds.min.x
        let height = bounds.max.y - bounds.min.y
        let sheetContentWidth = max(0, settings.sheetWidth - settings.pageMargin * 2)
        return width > sheetContentWidth && height <= sheetContentWidth
    }

    private static func rotate(layer: SliceContourLayer, bounds: Bounds2) -> SliceContourLayer {
        SliceContourLayer(
            position: layer.position,
            paths: layer.paths.map { path in
                SlicePath2D(points: path.points.map { rotate(point: $0, bounds: bounds) }, closed: path.closed)
            }
        )
    }

    private static func rotate(circle: Circle, bounds: Bounds2) -> Circle {
        Circle(center: rotate(point: circle.center, bounds: bounds), radius: circle.radius)
    }

    private static func rotate(point: Vec2, bounds: Bounds2) -> Vec2 {
        Vec2(
            x: bounds.min.x + point.y - bounds.min.y,
            y: bounds.min.y + bounds.max.x - point.x
        )
    }

    private static func lines(in layer: SliceContourLayer) -> [Line] {
        layer.paths.flatMap { path -> [Line] in
            guard path.points.count >= 2 else { return [] }
            return (0..<(path.points.count - 1)).map { index in
                Line(start: path.points[index], end: path.points[index + 1])
            }
        }
    }

    private static func dowelCircles(settings: DxfExporter.DowelSettings?, bounds: Bounds2) -> [Circle] {
        guard let settings,
              settings.enabled,
              settings.diameter > 0,
              settings.inset >= 0 else {
            return []
        }
        let radius = settings.diameter / 2
        let minSpan = min(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
        guard minSpan >= (settings.inset + radius) * 2 else {
            return []
        }
        return [
            Circle(center: Vec2(x: bounds.min.x + settings.inset, y: bounds.min.y + settings.inset), radius: radius),
            Circle(center: Vec2(x: bounds.max.x - settings.inset, y: bounds.min.y + settings.inset), radius: radius),
            Circle(center: Vec2(x: bounds.max.x - settings.inset, y: bounds.max.y - settings.inset), radius: radius),
            Circle(center: Vec2(x: bounds.min.x + settings.inset, y: bounds.max.y - settings.inset), radius: radius)
        ]
    }

    private static func layerBounds(_ layer: SliceContourLayer, circles: [Circle] = []) -> Bounds2? {
        var bounds: Bounds2?
        for path in layer.paths {
            for point in path.points {
                bounds = include(point: point, in: bounds)
            }
        }
        for circle in circles {
            bounds = include(point: Vec2(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius), in: bounds)
            bounds = include(point: Vec2(x: circle.center.x + circle.radius, y: circle.center.y + circle.radius), in: bounds)
        }
        return bounds
    }

    private static func include(point: Vec2, in bounds: Bounds2?) -> Bounds2 {
        guard let bounds else {
            return Bounds2(min: point, max: point)
        }
        return Bounds2(
            min: Vec2(x: min(bounds.min.x, point.x), y: min(bounds.min.y, point.y)),
            max: Vec2(x: max(bounds.max.x, point.x), y: max(bounds.max.y, point.y))
        )
    }
}
