import UniformTypeIdentifiers

enum FileDialogTypes {
    static let modelImports: [UTType] = [
        type(filenameExtension: "stl"),
        type(filenameExtension: "obj")
    ]

    static let project = type(
        filenameExtension: SlicerProjectDocument.fileExtension,
        conformingTo: .json
    )

    /// Open accepts current projects and ones saved under the earlier
    /// extension; Save always writes the current one.
    static let projectOpen: [UTType] = [
        project,
        type(filenameExtension: SlicerProjectDocument.legacyFileExtension, conformingTo: .json)
    ]

    static let assemblyGuide = UTType.plainText

    static func export(for format: ExportFormat) -> UTType {
        switch format {
        case .pdf:
            return .pdf
        case .svg:
            return .svg
        case .eps, .dxf, .obj, .stl:
            return type(filenameExtension: format.rawValue)
        }
    }

    private static func type(filenameExtension: String, conformingTo conformance: UTType? = nil) -> UTType {
        if let conformance,
           let type = UTType(filenameExtension: filenameExtension, conformingTo: conformance) {
            return type
        }
        return UTType(filenameExtension: filenameExtension) ?? .data
    }
}
