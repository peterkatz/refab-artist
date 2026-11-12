enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case dxf
    case eps
    case obj
    case pdf
    case stl
    case svg

    var id: String { rawValue }

    var label: String {
        rawValue.uppercased()
    }

    var usesVectorLayout: Bool {
        switch self {
        case .dxf, .eps, .pdf, .svg:
            return true
        case .obj, .stl:
            return false
        }
    }

    var usesSheetLayout: Bool {
        switch self {
        case .dxf, .eps, .pdf, .svg:
            return true
        case .obj, .stl:
            return false
        }
    }
}
