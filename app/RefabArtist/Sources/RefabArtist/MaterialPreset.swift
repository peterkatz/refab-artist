import Foundation

struct MaterialSettings: Equatable {
    var thickness: Double
    var slotClearance: Double

    mutating func apply(_ preset: MaterialPreset) {
        guard let values = preset.values else {
            return
        }
        thickness = values.thickness
        slotClearance = values.slotClearance
    }
}

enum MaterialPreset: String, CaseIterable, Identifiable, Codable {
    case custom
    case cardboard3mm
    case plywood3mm
    case plywood6mm
    case acrylic3mm

    struct Values: Equatable {
        var thickness: Double
        var slotClearance: Double
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom:
            return "Custom"
        case .cardboard3mm:
            return "Cardboard 3 mm"
        case .plywood3mm:
            return "Plywood 3 mm"
        case .plywood6mm:
            return "Plywood 6 mm"
        case .acrylic3mm:
            return "Acrylic 3 mm"
        }
    }

    var values: Values? {
        switch self {
        case .custom:
            return nil
        case .cardboard3mm:
            return Values(thickness: 3.0, slotClearance: 0.15)
        case .plywood3mm:
            return Values(thickness: 3.0, slotClearance: 0.10)
        case .plywood6mm:
            return Values(thickness: 6.0, slotClearance: 0.15)
        case .acrylic3mm:
            return Values(thickness: 3.0, slotClearance: 0.20)
        }
    }
}
