import Testing
@testable import RefabArtist

struct ViewportPreviewModeTests {
    @Test
    func previewModesExposeExpectedLayerVisibility() {
        #expect(ViewportPreviewMode.model.showsModel)
        #expect(!ViewportPreviewMode.model.showsSlicePreview)

        #expect(!ViewportPreviewMode.slices.showsModel)
        #expect(ViewportPreviewMode.slices.showsSlicePreview)

        #expect(ViewportPreviewMode.modelAndSlices.showsModel)
        #expect(ViewportPreviewMode.modelAndSlices.showsSlicePreview)
    }

    @Test
    func previewModesUseStableLabelsForSegmentedControl() {
        #expect(ViewportPreviewMode.allCases.map(\.label) == ["Model", "Slices", "Both"])
    }
}
