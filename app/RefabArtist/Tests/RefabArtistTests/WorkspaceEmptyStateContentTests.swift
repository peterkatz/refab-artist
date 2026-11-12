import Foundation
import Testing
@testable import RefabArtist

struct WorkspaceEmptyStateContentTests {
    @Test
    func noModelStateGivesPrimaryAndSecondaryNextActions() {
        let state = WorkspaceEmptyStateContent.noModel

        #expect(state.title == "No model loaded")
        #expect(state.primaryAction?.title == "Import Model")
        #expect(state.secondaryAction?.title == "Open Sample")
    }

    @Test
    func modelLoadFailureKeepsTheFailureMessageVisible() {
        let state = WorkspaceEmptyStateContent.modelLoadFailed("OBJ face index 9 is out of range")

        #expect(state.title == "Model could not be loaded")
        #expect(state.message == "The selected file was not imported.")
        #expect(state.detail == "OBJ face index 9 is out of range")
        #expect(state.primaryAction?.title == "Choose Another Model")
    }
}
