import SwiftUI

struct WorkspaceRGBA: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double = 1.0

    var color: Color {
        Color(red: red, green: green, blue: blue).opacity(opacity)
    }

    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

struct SheetPreviewPalette: Equatable {
    var canvasBackground: WorkspaceRGBA
    var pageFill: WorkspaceRGBA
    var sheetBorder: WorkspaceRGBA
    var panelFill: WorkspaceRGBA
    var panelStroke: WorkspaceRGBA
    var detailStroke: WorkspaceRGBA
    var overflowFill: WorkspaceRGBA
    var overflowStroke: WorkspaceRGBA
    var label: WorkspaceRGBA
}

enum WorkspaceDarkModePalette {
    static func viewportBackground(for colorScheme: ColorScheme) -> WorkspaceRGBA {
        switch colorScheme {
        case .dark:
            return WorkspaceRGBA(red: 0.10, green: 0.11, blue: 0.13)
        default:
            return WorkspaceRGBA(red: 0.72, green: 0.77, blue: 0.80)
        }
    }

    static func sheetPreview(for colorScheme: ColorScheme) -> SheetPreviewPalette {
        switch colorScheme {
        case .dark:
            return SheetPreviewPalette(
                canvasBackground: WorkspaceRGBA(red: 0.08, green: 0.09, blue: 0.11),
                pageFill: WorkspaceRGBA(red: 0.16, green: 0.17, blue: 0.19),
                sheetBorder: WorkspaceRGBA(red: 0.70, green: 0.74, blue: 0.78),
                panelFill: WorkspaceRGBA(red: 0.86, green: 0.86, blue: 0.84, opacity: 0.16),
                panelStroke: WorkspaceRGBA(red: 1.00, green: 0.50, blue: 0.40),
                detailStroke: WorkspaceRGBA(red: 0.46, green: 0.68, blue: 1.00, opacity: 0.94),
                overflowFill: WorkspaceRGBA(red: 1.00, green: 0.62, blue: 0.16, opacity: 0.20),
                overflowStroke: WorkspaceRGBA(red: 1.00, green: 0.72, blue: 0.28),
                label: WorkspaceRGBA(red: 0.82, green: 0.84, blue: 0.88)
            )
        default:
            return SheetPreviewPalette(
                canvasBackground: WorkspaceRGBA(red: 0.96, green: 0.97, blue: 0.98),
                pageFill: WorkspaceRGBA(red: 1.00, green: 1.00, blue: 1.00),
                sheetBorder: WorkspaceRGBA(red: 0.16, green: 0.18, blue: 0.20),
                panelFill: WorkspaceRGBA(red: 0.99, green: 0.98, blue: 0.96, opacity: 0.95),
                panelStroke: WorkspaceRGBA(red: 0.74, green: 0.04, blue: 0.00),
                detailStroke: WorkspaceRGBA(red: 0.05, green: 0.20, blue: 0.95, opacity: 0.82),
                overflowFill: WorkspaceRGBA(red: 1.00, green: 0.58, blue: 0.00, opacity: 0.12),
                overflowStroke: WorkspaceRGBA(red: 0.92, green: 0.42, blue: 0.00),
                label: WorkspaceRGBA(red: 0.38, green: 0.40, blue: 0.44)
            )
        }
    }
}
