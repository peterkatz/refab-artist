import Foundation

enum ViewportPreviewMode: String, CaseIterable, Identifiable {
    case model
    case slices
    case modelAndSlices

    var id: String { rawValue }

    var label: String {
        switch self {
        case .model:
            return "Model"
        case .slices:
            return "Slices"
        case .modelAndSlices:
            return "Both"
        }
    }

    var showsModel: Bool {
        switch self {
        case .model, .modelAndSlices:
            return true
        case .slices:
            return false
        }
    }

    var showsSlicePreview: Bool {
        switch self {
        case .slices, .modelAndSlices:
            return true
        case .model:
            return false
        }
    }
}
