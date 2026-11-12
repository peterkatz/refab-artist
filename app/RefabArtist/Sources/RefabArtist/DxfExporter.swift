import Foundation

enum DxfExporter {
    struct DowelSettings: Equatable {
        var enabled: Bool
        var diameter: Double
        var inset: Double
        /// User-placed rod positions (plan coordinates). Non-empty overrides
        /// automatic coverage placement — the add/move/delete dowel
        /// interaction, with its "Automatic" button clearing back.
        var manualPositions: [Vec2]? = nil
        /// Cross-section, per the Shape dropdown. Round cuts true
        /// circles; the others cut closed polygon outlines.
        var shape: DowelShape = .round
        /// How many rods automatic placement stands (the user chooses the
        /// number of dowels). Ignored when manualPositions is set.
        var automaticCount: Int = 2
    }

    static func write(
        contours: StackedSliceContours,
        to url: URL,
        sliceSpacing: Double = 10.0,
        pageMargin: Double = 0.0,
        layoutSettings: ExportLayoutSettings? = nil,
        dowels: DowelSettings? = nil
    ) throws {
        let settings = (layoutSettings ?? ExportLayoutSettings(partSpacing: sliceSpacing, pageMargin: pageMargin)).sanitized
        var output = ""
        beginEntities(settings: settings, into: &output)

        var cursor = LayoutCursor(settings: settings)
        writeContourSet(
            contours: contours,
            prefix: "slice",
            cursor: &cursor,
            dowels: dowels,
            into: &output
        )

        writeSheetBoundaryIfNeeded(settings: settings, sheetCount: cursor.sheetCount, into: &output)
        pair(0, "ENDSEC", into: &output)
        pair(0, "EOF", into: &output)
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rings and fins on per-part layers. A plan with no fins
    /// (n_radial == 0) is an Interlocked plan; FlatPartExport exports those
    /// as Interlocked before reaching this writer.
    static func write(radial plan: RadialSlicePlan, model: MeshSummary, to url: URL, sliceSpacing: Double = 10.0, pageMargin: Double = 0.0, layoutSettings: ExportLayoutSettings? = nil) throws {
        let settings = (layoutSettings ?? ExportLayoutSettings(partSpacing: sliceSpacing, pageMargin: pageMargin)).sanitized
        try radialDrawing(plan: plan, model: model, settings: settings).output.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write, for every part `write(radial:)` draws with the same arguments,
    /// the affine map from the part's coordinates in that DXF to model
    /// coordinates, keyed by its layer: `model = dxfToModel * (x, y, 1)`, as
    /// `CutSheetDocumentExporter.writePartFrames` writes them for the cut
    /// sheet, and `"detached": true` for a part no joint locks in. With
    /// these, a checker can put the rings and fins back where they belong in
    /// the model and test that their joints mate. `toModel`, when given,
    /// maps a point of `model` to the model the frames are for, as for the
    /// cut sheet's frames (under a Slice Direction tilt, back from the
    /// slicing frame onto the model as imported).
    static func writePartFrames(
        radial plan: RadialSlicePlan,
        model: MeshSummary,
        to url: URL,
        sliceSpacing: Double = 10.0,
        pageMargin: Double = 0.0,
        layoutSettings: ExportLayoutSettings? = nil,
        toModel: ((Vec3) -> Vec3)? = nil
    ) throws {
        let settings = (layoutSettings ?? ExportLayoutSettings(partSpacing: sliceSpacing, pageMargin: pageMargin)).sanitized
        let frames = radialDrawing(plan: plan, model: model, settings: settings, toModel: toModel).frames
        var data = try JSONSerialization.data(withJSONObject: ["parts": frames], options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url)
    }

    private static func radialDrawing(
        plan: RadialSlicePlan,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        toModel: ((Vec3) -> Vec3)? = nil
    ) -> (output: String, frames: [[String: Any]]) {
        var output = ""
        beginEntities(settings: settings, into: &output)

        // Rings + fins from the shared disk+wedge generator — the same part
        // geometry as the cut sheet.
        let parts = RadialPartBuilder.assembly(plan: plan, model: model)
        let axis = plan.primary?.axis ?? .z
        let center = model.bounds.map(RadialPartBuilder.boxCenter)
        var frames: [[String: Any]] = []
        var cursor = LayoutCursor(settings: settings)
        for (prefix, family) in [("first_axis", parts.disks), ("radial", parts.wedges)] {
            let drawn = family.filter { $0.loop.count >= 3 }
            let placements = writeContourSet(
                contours: StackedSliceContours(axis: axis, layers: SvgExporter.radialPartLayers(drawn)),
                prefix: prefix,
                cursor: &cursor,
                into: &output
            )
            for (part, placement) in zip(drawn, placements) {
                let frame = prefix == "radial"
                    ? center.map { RadialPartBuilder.wedgeFrame(center: $0, axis: axis, angle: part.position) }
                    : RadialPartBuilder.diskFrame(axis: axis, position: part.position)
                guard let frame else { continue }
                func modelPoint(_ x: Double, _ y: Double) -> Vec3 {
                    let point = frame.modelPoint(placement.layerPoint(fromDrawn: Vec2(x: x, y: y)))
                    return toModel?(point) ?? point
                }
                let origin = modelPoint(0, 0)
                let alongX = modelPoint(1, 0)
                let alongY = modelPoint(0, 1)
                let top = placement.drawnBounds.map { $0.min.y } ?? 0
                let sheet = settings.hasSheetSize && settings.sheetHeight > 0
                    ? Int(floor(max(0, top) / settings.sheetHeight)) + 1
                    : 1
                var entry: [String: Any] = [
                    "label": placement.layerName,
                    "sheet": sheet,
                    "dxfToModel": [
                        [alongX.x - origin.x, alongY.x - origin.x, origin.x],
                        [alongX.y - origin.y, alongY.y - origin.y, origin.y],
                        [alongX.z - origin.z, alongY.z - origin.z, origin.z]
                    ]
                ]
                // A part no joint locks in (blue on the cut sheet, to be
                // glued), as the cut-sheet frames mark them.
                if !part.joined {
                    entry["detached"] = true
                }
                frames.append(entry)
            }
        }

        writeSheetBoundaryIfNeeded(settings: settings, sheetCount: cursor.sheetCount, into: &output)
        pair(0, "ENDSEC", into: &output)
        pair(0, "EOF", into: &output)
        return (output, frames)
    }

    private struct Bounds2 {
        var min: Vec2
        var max: Vec2
    }

    private struct Circle {
        var center: Vec2
        var radius: Double
    }

    private struct Placement {
        var layer: SliceContourLayer
        var circles: [Circle]
        var bounds: Bounds2?
        /// The layer's bounds before it was turned a quarter to fit the
        /// sheet, when it was.
        var rotatedFrom: Bounds2? = nil
    }

    /// Where `writeContourSet` drew one layer: each of its points went to the
    /// point plus `origin`, after turning a quarter about `rotatedFrom` when
    /// that is set.
    private struct LayerPlacement {
        var layerName: String
        var origin: (x: Double, y: Double)
        var rotatedFrom: Bounds2?
        /// The drawn layer's bounds, before `origin` is added.
        var bounds: Bounds2?

        var drawnBounds: Bounds2? {
            bounds.map {
                Bounds2(
                    min: Vec2(x: $0.min.x + origin.x, y: $0.min.y + origin.y),
                    max: Vec2(x: $0.max.x + origin.x, y: $0.max.y + origin.y)
                )
            }
        }

        /// The layer point drawn at `point`.
        func layerPoint(fromDrawn point: Vec2) -> Vec2 {
            let placed = Vec2(x: point.x - origin.x, y: point.y - origin.y)
            guard let b = rotatedFrom else { return placed }
            // Inverse of `rotate(point:bounds:)`.
            return Vec2(x: b.min.y + b.max.x - placed.y, y: placed.x - b.min.x + b.min.y)
        }
    }

    private static let labelHeight = 7.0

    private static func beginEntities(settings: ExportLayoutSettings, into output: inout String) {
        pair(0, "SECTION", into: &output)
        pair(2, "ENTITIES", into: &output)
    }

    private static func writeSheetBoundaryIfNeeded(settings: ExportLayoutSettings, sheetCount: Int, into output: inout String) {
        guard settings.hasSheetSize else {
            return
        }
        for sheetIndex in 0..<max(1, sheetCount) {
            let sheetTop = Double(sheetIndex) * settings.sheetHeight
            let layer = sheetIndex == 0 ? "sheet_boundary" : "sheet_boundary_\(sheetIndex + 1)"
            let points = [
                Vec2(x: 0, y: sheetTop),
                Vec2(x: settings.sheetWidth, y: sheetTop),
                Vec2(x: settings.sheetWidth, y: sheetTop + settings.sheetHeight),
                Vec2(x: 0, y: sheetTop + settings.sheetHeight),
                Vec2(x: 0, y: sheetTop)
            ]
            for index in 0..<(points.count - 1) {
                writeLine(layer: layer, start: points[index], end: points[index + 1], offsetX: 0, offsetY: 0, into: &output)
            }
        }
    }

    private struct LayoutCursor {
        var settings: ExportLayoutSettings
        var cursorX: Double
        var cursorY: Double
        var rowHeight: Double
        var maxContentY: Double

        init(settings: ExportLayoutSettings) {
            self.settings = settings
            self.cursorX = settings.pageMargin
            self.cursorY = settings.pageMargin
            self.rowHeight = 0
            self.maxContentY = settings.pageMargin
        }

        var sheetCount: Int {
            guard settings.hasSheetSize else {
                return 0
            }
            return max(1, Int(ceil((maxContentY + settings.pageMargin) / settings.sheetHeight)))
        }

        mutating func place(bounds: Bounds2?) -> (x: Double, y: Double) {
            guard let bounds else {
                return (cursorX, cursorY)
            }

            let width = bounds.max.x - bounds.min.x
            let height = bounds.max.y - bounds.min.y
            let footprintHeight = height + DxfExporter.labelHeight
            if settings.hasSheetSize,
               cursorX > settings.pageMargin,
               cursorX + width > settings.sheetWidth - settings.pageMargin {
                cursorX = settings.pageMargin
                cursorY += rowHeight + settings.partSpacing
                rowHeight = 0
            }
            if settings.hasSheetSize,
               footprintHeight + settings.pageMargin * 2 <= settings.sheetHeight,
               cursorY > currentSheetTop + settings.pageMargin,
               cursorY + footprintHeight > currentSheetTop + settings.sheetHeight - settings.pageMargin {
                cursorX = settings.pageMargin
                cursorY = currentSheetTop + settings.sheetHeight + settings.pageMargin
                rowHeight = 0
            }

            let origin = (x: cursorX - bounds.min.x, y: cursorY - bounds.min.y)
            cursorX += width + settings.partSpacing
            rowHeight = max(rowHeight, footprintHeight)
            maxContentY = max(maxContentY, cursorY + footprintHeight)
            return origin
        }

        private var currentSheetTop: Double {
            guard settings.hasSheetSize, settings.sheetHeight > 0 else {
                return 0
            }
            return floor(max(0, cursorY) / settings.sheetHeight) * settings.sheetHeight
        }
    }

    @discardableResult
    private static func writeContourSet(
        contours: StackedSliceContours,
        prefix: String,
        cursor: inout LayoutCursor,
        dowels: DowelSettings? = nil,
        into output: inout String
    ) -> [LayerPlacement] {
        // Dowels are stack-global: one set of XY positions shared by every
        // slice so the rod actually threads (per-slice bbox corners only
        // coincide on prisms — identical there, so fixtures stay byte-stable).
        let dowelPositions = DowelLayout.globalPositions(layers: contours.layers, settings: dowels)
        let dowelRadius = (dowels?.diameter ?? 0) / 2

        var placements: [LayerPlacement] = []
        for (layerIndex, layer) in contours.layers.enumerated() {
            var layerPaths = layer.paths
            var layerCircles: [Circle] = []
            if !dowelPositions.isEmpty {
                let covered = DowelLayout.positionsCovered(by: layer, positions: dowelPositions)
                if let dowels, dowels.shape != .round {
                    // Non-round shapes ride the path pipeline (closed cut
                    // loops), so packing rotation transforms them too.
                    layerPaths += covered.compactMap { center in
                        dowels.shape.outline(center: center, diameter: dowels.diameter).map { outline in
                            SlicePath2D(points: outline + [outline[0]], closed: true)
                        }
                    }
                } else {
                    layerCircles += covered.map { Circle(center: $0, radius: dowelRadius) }
                }
            }
            let mergedLayer = SliceContourLayer(position: layer.position, paths: layerPaths)
            let placement = placement(
                for: mergedLayer,
                circles: layerCircles,
                dowels: nil,
                settings: cursor.settings
            )
            let origin = cursor.place(bounds: placement.bounds)
            let layerName = String(format: "\(prefix)_%03d", layerIndex + 1)
            write(layer: placement.layer, layerName: layerName, offsetX: origin.x, offsetY: origin.y, into: &output)
            write(circles: placement.circles, layerName: layerName, offsetX: origin.x, offsetY: origin.y, into: &output)
            writeLabelIfNeeded(label: layerName, bounds: placement.bounds, offsetX: origin.x, offsetY: origin.y, into: &output)
            placements.append(LayerPlacement(
                layerName: layerName,
                origin: origin,
                rotatedFrom: placement.rotatedFrom,
                bounds: placement.bounds
            ))
        }
        return placements
    }

    private static func placement(
        for layer: SliceContourLayer,
        circles: [Circle] = [],
        dowels: DowelSettings? = nil,
        settings: ExportLayoutSettings
    ) -> Placement {
        guard let bounds = layerBounds(layer, circles: circles) else {
            return Placement(layer: layer, circles: circles, bounds: nil)
        }

        var placedLayer = layer
        var placedCircles = circles + dowelCircles(settings: dowels, bounds: bounds)
        var placedBounds = bounds
        var rotatedFrom: Bounds2?
        if shouldRotateToFitSheet(bounds: bounds, settings: settings) {
            rotatedFrom = bounds
            placedLayer = rotate(layer: layer, bounds: bounds)
            placedCircles = placedCircles.map { rotate(circle: $0, bounds: bounds) }
            if let rotatedBounds = layerBounds(placedLayer, circles: placedCircles) {
                placedBounds = rotatedBounds
            }
        } else if !placedCircles.isEmpty,
                  let expandedBounds = layerBounds(placedLayer, circles: placedCircles) {
            placedBounds = expandedBounds
        }

        return Placement(layer: placedLayer, circles: placedCircles, bounds: placedBounds, rotatedFrom: rotatedFrom)
    }

    private static func write(
        layer: SliceContourLayer,
        layerName: String,
        offsetX: Double,
        offsetY: Double,
        maxLineCount: Int? = nil,
        into output: inout String
    ) {
        var remainingLineCount = maxLineCount
        for path in layer.paths where path.points.count >= 2 {
            for pointIndex in 0..<(path.points.count - 1) {
                if let count = remainingLineCount {
                    guard count > 0 else {
                        return
                    }
                    remainingLineCount = count - 1
                }
                writeLine(
                    layer: layerName,
                    start: path.points[pointIndex],
                    end: path.points[pointIndex + 1],
                    offsetX: offsetX,
                    offsetY: offsetY,
                    into: &output
                )
            }
        }
    }

    private static func write(circles: [Circle], layerName: String, offsetX: Double, offsetY: Double, into output: inout String) {
        for circle in circles {
            writeCircle(layer: layerName, center: circle.center, radius: circle.radius, offsetX: offsetX, offsetY: offsetY, into: &output)
        }
    }

    private static func dowelCircles(settings: DowelSettings?, bounds: Bounds2) -> [Circle] {
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

    private static func writeLabelIfNeeded(
        label: String,
        bounds: Bounds2?,
        offsetX: Double,
        offsetY: Double,
        into output: inout String
    ) {
        guard let bounds else {
            return
        }
        writeText(
            layer: label,
            text: label,
            x: bounds.min.x + offsetX,
            y: bounds.max.y + offsetY + 3,
            height: 4,
            into: &output
        )
    }

    private static func shouldRotateToFitSheet(bounds: Bounds2, settings: ExportLayoutSettings) -> Bool {
        guard settings.hasSheetSize else {
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

    private static func writeLine(layer: String, start: Vec2, end: Vec2, offsetX: Double, offsetY: Double, into output: inout String) {
        pair(0, "LINE", into: &output)
        pair(8, layer, into: &output)
        pair(10, start.x + offsetX, into: &output)
        pair(20, start.y + offsetY, into: &output)
        pair(30, 0, into: &output)
        pair(11, end.x + offsetX, into: &output)
        pair(21, end.y + offsetY, into: &output)
        pair(31, 0, into: &output)
    }

    private static func writeCircle(layer: String, center: Vec2, radius: Double, offsetX: Double, offsetY: Double, into output: inout String) {
        pair(0, "CIRCLE", into: &output)
        pair(8, layer, into: &output)
        pair(10, center.x + offsetX, into: &output)
        pair(20, center.y + offsetY, into: &output)
        pair(30, 0, into: &output)
        pair(40, radius, into: &output)
    }

    private static func writeText(layer: String, text: String, x: Double, y: Double, height: Double, into output: inout String) {
        pair(0, "TEXT", into: &output)
        pair(8, layer, into: &output)
        pair(10, x, into: &output)
        pair(20, y, into: &output)
        pair(30, 0, into: &output)
        pair(40, height, into: &output)
        pair(1, text, into: &output)
    }

    private static func pair(_ code: Int, _ value: String, into output: inout String) {
        output += "\(code)\n\(value)\n"
    }

    private static func pair(_ code: Int, _ value: Double, into output: inout String) {
        output += "\(code)\n\(String(format: "%.6f", value))\n"
    }
}
