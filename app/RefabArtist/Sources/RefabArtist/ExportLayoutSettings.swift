struct ExportLayoutSettings: Equatable, Codable {
    var partSpacing: Double
    var pageMargin: Double
    var sheetWidth: Double = 0
    var sheetHeight: Double = 0

    static let defaultValue = ExportLayoutSettings(partSpacing: 10.0, pageMargin: 10.0, sheetWidth: 600.0, sheetHeight: 300.0)

    var hasSheetSize: Bool {
        sheetWidth > 0 && sheetHeight > 0
    }

    var sanitized: ExportLayoutSettings {
        ExportLayoutSettings(
            partSpacing: max(0, partSpacing),
            pageMargin: max(0, pageMargin),
            sheetWidth: max(0, sheetWidth),
            sheetHeight: max(0, sheetHeight)
        )
    }
}

enum StockSheetPreset: String, CaseIterable, Identifiable {
    case custom
    case letter
    case a4
    case twelveByTwelve
    case twentyFourByTwelve
    case twentyFourByTwentyFour

    struct Size: Equatable {
        var width: Double
        var height: Double
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom:
            return "Custom"
        case .letter:
            return "Letter 8.5 x 11 in"
        case .a4:
            return "A4 210 x 297 mm"
        case .twelveByTwelve:
            return "12 x 12 in"
        case .twentyFourByTwelve:
            return "24 x 12 in"
        case .twentyFourByTwentyFour:
            return "24 x 24 in"
        }
    }

    var size: Size? {
        switch self {
        case .custom:
            return nil
        case .letter:
            return Size(width: 215.9, height: 279.4)
        case .a4:
            return Size(width: 210.0, height: 297.0)
        case .twelveByTwelve:
            return Size(width: 304.8, height: 304.8)
        case .twentyFourByTwelve:
            return Size(width: 609.6, height: 304.8)
        case .twentyFourByTwentyFour:
            return Size(width: 609.6, height: 609.6)
        }
    }

    static func matching(width: Double, height: Double) -> StockSheetPreset {
        allCases.first { preset in
            guard let size = preset.size else {
                return false
            }
            return abs(size.width - width) < 0.01 && abs(size.height - height) < 0.01
        } ?? .custom
    }
}
