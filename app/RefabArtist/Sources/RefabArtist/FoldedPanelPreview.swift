import Foundation

struct FoldedPanelPreviewLayout: Equatable {
    struct PanelPath: Equatable {
        var sourceTriangleIndex: Int
        var points: [Vec2]
    }

    /// One translated multi-net piece: closed cut outline (tabs included),
    /// interior fold lines, mating slot holes, and the placed per-panel
    /// polygons (used when an outline could not be chained, and by the 3D
    /// viewport for per-panel shading).
    struct NetPath: Equatable {
        var netIndex: Int
        var outline: [Vec2]
        var foldLines: [FoldedNetFoldEdge]
        var slotHoles: [[Vec2]]
        var panelOutlines: [[Vec2]]
    }

    var paths: [PanelPath]
    var nets: [NetPath] = []
    var bounds: FoldedPanelBounds?
}

enum FoldedPanelPreviewLayouter {
    static func layout(plan: FoldedPanelPlan, spacing: Double = 6) -> FoldedPanelPreviewLayout {
        if !plan.nets.isEmpty {
            return netLayout(plan: plan, spacing: spacing)
        }
        if let cubeNet = cubeNetLayout(plan: plan) {
            return cubeNet
        }

        var paths: [FoldedPanelPreviewLayout.PanelPath] = []
        var offsetX = 0.0
        var combinedBounds: FoldedPanelBounds?

        for panel in plan.panels {
            let translated = panel.points.map { point in
                Vec2(
                    x: point.x - panel.bounds.min.x + offsetX,
                    y: point.y - panel.bounds.min.y
                )
            }
            paths.append(
                FoldedPanelPreviewLayout.PanelPath(
                    sourceTriangleIndex: panel.sourceTriangleIndex,
                    points: translated
                )
            )
            combinedBounds = include(points: translated, in: combinedBounds)
            offsetX += (panel.bounds.max.x - panel.bounds.min.x) + spacing
        }

        return FoldedPanelPreviewLayout(paths: paths, bounds: combinedBounds)
    }

    /// Multi-net row layout: one translated piece per net, ordered, with the
    /// closed net outline carried as the back-compat `paths` entry so solid
    /// exporters and the viewport keep working unchanged. A net whose
    /// outline could not be chained contributes its placed panel polygons
    /// instead (still one coherent piece, never the global scatter).
    private static func netLayout(plan: FoldedPanelPlan, spacing: Double) -> FoldedPanelPreviewLayout {
        var nets: [FoldedPanelPreviewLayout.NetPath] = []
        var paths: [FoldedPanelPreviewLayout.PanelPath] = []
        var offsetX = 0.0
        var combinedBounds: FoldedPanelBounds?

        for (index, net) in plan.nets.enumerated() {
            let bounds = net.bounds
            let dx = offsetX - bounds.min.x
            let dy = -bounds.min.y
            func shifted(_ point: Vec2) -> Vec2 {
                Vec2(x: point.x + dx, y: point.y + dy)
            }

            var outline = net.outline.map(shifted)
            if let first = outline.first {
                outline.append(first)
            }
            let foldLines = net.foldEdges.map {
                FoldedNetFoldEdge(start: shifted($0.start), end: shifted($0.end))
            }
            let slotHoles = net.slotHoles.map { $0.map(shifted) }
            let panelOutlines = net.panelOutlines.map { $0.map(shifted) }
            nets.append(
                FoldedPanelPreviewLayout.NetPath(
                    netIndex: index,
                    outline: outline,
                    foldLines: foldLines,
                    slotHoles: slotHoles,
                    panelOutlines: panelOutlines
                )
            )

            if outline.count >= 4 {
                paths.append(FoldedPanelPreviewLayout.PanelPath(sourceTriangleIndex: index, points: outline))
                combinedBounds = include(points: outline, in: combinedBounds)
            } else {
                for polygon in panelOutlines {
                    var closed = polygon
                    if let first = polygon.first {
                        closed.append(first)
                    }
                    paths.append(FoldedPanelPreviewLayout.PanelPath(sourceTriangleIndex: index, points: closed))
                    combinedBounds = include(points: closed, in: combinedBounds)
                }
            }
            for hole in slotHoles {
                combinedBounds = include(points: hole, in: combinedBounds)
            }
            offsetX += (bounds.max.x - bounds.min.x) + spacing
        }

        return FoldedPanelPreviewLayout(paths: paths, nets: nets, bounds: combinedBounds)
    }

    private static func cubeNetLayout(plan: FoldedPanelPlan) -> FoldedPanelPreviewLayout? {
        guard plan.panels.count == 6 else {
            return nil
        }
        let widths = plan.panels.map { rounded($0.bounds.max.x - $0.bounds.min.x) }
        let heights = plan.panels.map { rounded($0.bounds.max.y - $0.bounds.min.y) }
        guard let width = widths.first,
              let height = heights.first,
              width > 0,
              abs(width - height) < 1.0e-6,
              widths.allSatisfy({ abs($0 - width) < 1.0e-6 }),
              heights.allSatisfy({ abs($0 - height) < 1.0e-6 }) else {
            return nil
        }

        let offsets = [
            Vec2(x: width, y: height),
            Vec2(x: width, y: 0),
            Vec2(x: 0, y: height),
            Vec2(x: width * 2, y: height),
            Vec2(x: width, y: height * 2),
            Vec2(x: width * 3, y: height)
        ]
        var paths: [FoldedPanelPreviewLayout.PanelPath] = []
        var combinedBounds: FoldedPanelBounds?

        for (panel, offset) in zip(plan.panels, offsets) {
            let translated = panel.points.map { point in
                Vec2(
                    x: point.x - panel.bounds.min.x + offset.x,
                    y: point.y - panel.bounds.min.y + offset.y
                )
            }
            paths.append(
                FoldedPanelPreviewLayout.PanelPath(
                    sourceTriangleIndex: panel.sourceTriangleIndex,
                    points: translated
                )
            )
            combinedBounds = include(points: translated, in: combinedBounds)
        }

        return FoldedPanelPreviewLayout(paths: paths, bounds: combinedBounds)
    }

    private static func include(points: [Vec2], in bounds: FoldedPanelBounds?) -> FoldedPanelBounds? {
        guard let first = points.first else {
            return bounds
        }
        var minX = bounds?.min.x ?? first.x
        var minY = bounds?.min.y ?? first.y
        var maxX = bounds?.max.x ?? first.x
        var maxY = bounds?.max.y ?? first.y

        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return FoldedPanelBounds(min: Vec2(x: minX, y: minY), max: Vec2(x: maxX, y: maxY))
    }

    private static func rounded(_ value: Double) -> Double {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return abs(rounded) <= 1.0e-9 ? 0 : rounded
    }
}
