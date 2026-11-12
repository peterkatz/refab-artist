import Testing
@testable import RefabArtist

struct ExportFormatSupportTests {
    @Test
    func flatPartModesExposeAllFormats() {
        // These modes expose both vector cut sheets and mesh exports.
        #expect(ExportFormatSupport.availableFormats(for: .stacked) == ExportFormat.allCases)
        #expect(ExportFormatSupport.availableFormats(for: .interlocked) == ExportFormat.allCases)
        #expect(ExportFormatSupport.availableFormats(for: .radial) == ExportFormat.allCases)
        #expect(ExportFormatSupport.availableFormats(for: .curve) == ExportFormat.allCases)
        #expect(ExportFormatSupport.availableFormats(for: .foldedPanels) == ExportFormat.allCases)
    }

    @Test
    func inflatablesExposeCutSheetAndMembraneFormats() {
        #expect(ExportFormatSupport.availableFormats(for: .inflatables) == [.dxf, .svg, .pdf, .stl, .obj])
        #expect(ExportFormatSupport.normalized(format: .eps, for: .inflatables) == .dxf)
        #expect(ExportFormatSupport.normalized(format: .stl, for: .inflatables) == .stl)
    }

    @Test
    func threeDIsMeshOnly() {
        // 3D Slices produces a surface-preserving layered MESH, not flat parts,
        // so it exposes only mesh formats.
        #expect(ExportFormatSupport.availableFormats(for: .threeD) == [.stl, .obj])
        // A vector format selected in another mode falls back to a mesh format.
        #expect(ExportFormatSupport.normalized(format: .dxf, for: .threeD) == .stl)
        #expect(ExportFormatSupport.normalized(format: .obj, for: .threeD) == .obj)
    }

    @Test
    func normalizedFormatPreservesSupportedSelection() {
        #expect(ExportFormatSupport.normalized(format: .stl, for: .curve) == .stl)
        #expect(ExportFormatSupport.normalized(format: .obj, for: .interlocked) == .obj)
    }
}
