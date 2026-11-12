import Testing
@testable import RefabArtist

struct InspectorPanelSectionTests {
    @Test
    func loadedModelOrderKeepsPrimaryWorkflowTopToBottom() {
        // Left control flow (Object Size, Modify Form, model stats, and issues
        // live in the separate right-side inspector):
        // Actions -> Construction Technique -> Structures -> Manufacturing
        // Settings -> Technique Settings -> Slice Direction -> Dowels ->
        // Assembly -> Export. Dowels follows Slice Direction so the cut
        // direction is chosen before placing rods (owner decision, 2026-06-14); it's a
        // stacked-only section. Structures sits right after Construction (its
        // params panel, shown only in Structures mode); MotherMold's params
        // panel follows it (shown only in MotherMold mode).
        #expect(InspectorPanelSection.loadedModelOrder == [
            .actions,
            .construction,
            .structures,
            .motherMold,
            .manufacturing,
            .constructionSettings,
            .sliceDirection,
            .dowels,
            .assembly,
            .export,
        ])
    }

    @Test
    func emptyModelOrderShowsOnlyActionsAndModelState() {
        #expect(InspectorPanelSection.emptyModelOrder == [
            .actions,
            .model,
        ])
    }

    @Test
    func allSectionsHaveNativeInspectorLabelsAndSymbols() {
        for section in InspectorPanelSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.systemImage.isEmpty)
            #expect(section.accessibilityLabel == "\(section.title) inspector section")
        }
    }
}
