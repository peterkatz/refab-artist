import Foundation

struct WorkspaceEmptyStateContent: Equatable {
    struct Action: Equatable {
        var title: String
        var systemImage: String
    }

    var systemImage: String
    var title: String
    var message: String
    var detail: String?
    var primaryAction: Action?
    var secondaryAction: Action?

    static let noModel = WorkspaceEmptyStateContent(
        systemImage: "cube.transparent",
        title: "No model loaded",
        message: "Import an STL or OBJ model, or open the bundled sample.",
        detail: "Scale, construction, assembly, and export controls appear after a model is loaded.",
        primaryAction: Action(title: "Import Model", systemImage: "square.and.arrow.down"),
        secondaryAction: Action(title: "Open Sample", systemImage: "cube")
    )

    static func modelLoadFailed(_ message: String) -> WorkspaceEmptyStateContent {
        WorkspaceEmptyStateContent(
            systemImage: "exclamationmark.triangle",
            title: "Model could not be loaded",
            message: "The selected file was not imported.",
            detail: message,
            primaryAction: Action(title: "Choose Another Model", systemImage: "square.and.arrow.down"),
            secondaryAction: Action(title: "Open Sample", systemImage: "cube")
        )
    }
}
