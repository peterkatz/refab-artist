import Foundation

enum EpsExporter {
    struct Layout: Equatable {
        var pageWidth: Double
        var pageHeight: Double
        var pageMargin: Double
        var sheetWidth: Double
        var sheetHeight: Double
        var overflowsSheet: Bool
        var parts: [Part]

        var sheetCount: Int {
            guard sheetWidth > 0, sheetHeight > 0 else {
                return 0
            }
            return max(1, Int(ceil(pageHeight / sheetHeight)))
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

    static func layout(
        contours: StackedSliceContours,
        sliceSpacing: Double = 10.0,
        pageMargin: Double = 10.0,
        layoutSettings: ExportLayoutSettings? = nil,
        dowels: DxfExporter.DowelSettings? = nil
    ) -> Layout {
        layout(
            from: SvgExporter.layout(
                contours: contours,
                sliceSpacing: sliceSpacing,
                pageMargin: pageMargin,
                layoutSettings: layoutSettings,
                dowels: dowels
            )
        )
    }

    static func layout(radial plan: RadialSlicePlan, model: MeshSummary, sliceSpacing: Double = 10.0, pageMargin: Double = 10.0, layoutSettings: ExportLayoutSettings? = nil) -> Layout {
        layout(from: SvgExporter.layout(radial: plan, model: model, sliceSpacing: sliceSpacing, pageMargin: pageMargin, layoutSettings: layoutSettings))
    }

    private static func layout(from svgLayout: SvgExporter.Layout) -> Layout {
        Layout(
            pageWidth: svgLayout.width,
            pageHeight: svgLayout.height,
            pageMargin: svgLayout.pageMargin,
            sheetWidth: svgLayout.sheetWidth,
            sheetHeight: svgLayout.sheetHeight,
            overflowsSheet: svgLayout.overflowsSheet,
            parts: svgLayout.parts.map { svgPart in
                Part(
                    label: svgPart.label,
                    offset: svgPart.offset,
                    lines: svgPart.lines.map { Line(start: $0.start, end: $0.end) },
                    circles: svgPart.circles.map { Circle(center: $0.center, radius: $0.radius) },
                    bounds: Bounds2(min: svgPart.bounds.min, max: svgPart.bounds.max)
                )
            }
        )
    }
}
