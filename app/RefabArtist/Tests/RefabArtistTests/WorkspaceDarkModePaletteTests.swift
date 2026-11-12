import SwiftUI
import Testing
@testable import RefabArtist

struct WorkspaceDarkModePaletteTests {
    @Test
    func viewportBackgroundAdaptsBetweenLightAndDarkMode() {
        let light = WorkspaceDarkModePalette.viewportBackground(for: .light)
        let dark = WorkspaceDarkModePalette.viewportBackground(for: .dark)

        #expect(light != dark)
        #expect(dark.luminance < light.luminance)
    }

    @Test
    func sheetPreviewDarkModeDoesNotReuseWhitePageOrBlackBorder() {
        let light = WorkspaceDarkModePalette.sheetPreview(for: .light)
        let dark = WorkspaceDarkModePalette.sheetPreview(for: .dark)

        #expect(light.pageFill == WorkspaceRGBA(red: 1.0, green: 1.0, blue: 1.0))
        #expect(dark.pageFill != light.pageFill)
        #expect(dark.pageFill.luminance < light.pageFill.luminance)
        #expect(dark.sheetBorder != WorkspaceRGBA(red: 0.0, green: 0.0, blue: 0.0))
        #expect(dark.sheetBorder.luminance > dark.pageFill.luminance)
    }

    @Test
    func sheetPreviewDarkModeKeepsCanvasDarkerThanPage() {
        let dark = WorkspaceDarkModePalette.sheetPreview(for: .dark)

        #expect(dark.canvasBackground.luminance < dark.pageFill.luminance)
        #expect(dark.pageFill.luminance < dark.label.luminance)
    }

    @Test
    func sheetPreviewDarkModeKeepsPanelAndDetailStrokesDistinct() {
        let dark = WorkspaceDarkModePalette.sheetPreview(for: .dark)

        #expect(dark.panelStroke != dark.detailStroke)
        #expect(dark.overflowStroke != dark.panelStroke)
        // Parts now render as light "paper" with colored cut/slot strokes,
        // so the detail stroke just needs to stay clearly
        // distinct from the panel fill — not necessarily brighter than it.
        #expect(abs(dark.detailStroke.luminance - dark.panelFill.luminance) > 0.1)
    }

    @Test
    func sheetPreviewLightModePreservesOriginalContrastRoles() {
        let light = WorkspaceDarkModePalette.sheetPreview(for: .light)

        #expect(light.canvasBackground.luminance < light.pageFill.luminance)
        #expect(light.sheetBorder.luminance < light.pageFill.luminance)
        #expect(light.panelStroke.luminance < light.pageFill.luminance)
        #expect(light.detailStroke != light.panelStroke)
    }
}
