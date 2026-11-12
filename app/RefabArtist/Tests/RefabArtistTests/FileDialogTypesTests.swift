import Testing
import UniformTypeIdentifiers
@testable import RefabArtist

struct FileDialogTypesTests {
    @Test
    func modelImportTypesPreserveMeshExtensions() {
        #expect(FileDialogTypes.modelImports.map(\.preferredFilenameExtension) == ["stl", "obj"])
    }

    @Test
    func projectTypePreservesCustomExtensionAndJSONConformance() {
        #expect(FileDialogTypes.project.preferredFilenameExtension == SlicerProjectDocument.fileExtension)
        #expect(FileDialogTypes.project.conforms(to: .json))
    }

    @Test
    func exportTypesPreserveAllSupportedExtensions() {
        for format in ExportFormat.allCases {
            #expect(FileDialogTypes.export(for: format).preferredFilenameExtension == format.rawValue)
        }
    }

    @Test
    func assemblyGuideUsesPlainText() {
        #expect(FileDialogTypes.assemblyGuide == .plainText)
    }
}
