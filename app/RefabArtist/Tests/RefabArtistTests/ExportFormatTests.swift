import Testing
@testable import RefabArtist

struct ExportFormatTests {
    @Test
    func vectorAndSheetLayoutCapabilitiesMatchExportWriters() {
        #expect(ExportFormat.allCases.filter(\.usesVectorLayout) == [.dxf, .eps, .pdf, .svg])
        #expect(ExportFormat.allCases.filter(\.usesSheetLayout) == [.dxf, .eps, .pdf, .svg])
        #expect(ExportFormat.allCases.filter { !$0.usesVectorLayout } == [.obj, .stl])
        #expect(ExportFormat.allCases.filter { !$0.usesSheetLayout } == [.obj, .stl])
    }
}
