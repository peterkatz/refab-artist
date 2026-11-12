import Testing
@testable import RefabArtist

struct ViewportCameraFitContextTests {
    @Test
    func fitContextChangesWhenConstructionModeChanges() {
        let stacked = ViewportCameraFitContext(
            modelPath: "/tmp/model.stl",
            constructionMode: .stacked,
            previewMode: .modelAndSlices
        )
        let folded = ViewportCameraFitContext(
            modelPath: "/tmp/model.stl",
            constructionMode: .foldedPanels,
            previewMode: .modelAndSlices
        )

        #expect(stacked != folded)
    }

    @Test
    func fitContextChangesWhenPreviewLayerModeChanges() {
        let both = ViewportCameraFitContext(
            modelPath: "/tmp/model.stl",
            constructionMode: .foldedPanels,
            previewMode: .modelAndSlices
        )
        let slicesOnly = ViewportCameraFitContext(
            modelPath: "/tmp/model.stl",
            constructionMode: .foldedPanels,
            previewMode: .slices
        )

        #expect(both != slicesOnly)
    }

    @Test
    func fitContextChangesWhenLoadedModelChanges() {
        let first = ViewportCameraFitContext(
            modelPath: "/tmp/first.stl",
            constructionMode: .stacked,
            previewMode: .modelAndSlices
        )
        let second = ViewportCameraFitContext(
            modelPath: "/tmp/second.stl",
            constructionMode: .stacked,
            previewMode: .modelAndSlices
        )

        #expect(first != second)
    }
}
