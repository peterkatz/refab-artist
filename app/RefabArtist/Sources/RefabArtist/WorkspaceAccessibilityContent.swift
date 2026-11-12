struct WorkspaceAccessibilityDescription: Equatable {
    var label: String
    var value: String?
    var hint: String?
}

enum WorkspaceAccessibilityContent {
    static func sidebarToggle(isInspectorVisible: Bool) -> WorkspaceAccessibilityDescription {
        WorkspaceAccessibilityDescription(
            label: isInspectorVisible ? "Hide inspector" : "Show inspector",
            value: isInspectorVisible ? "Inspector visible" : "Inspector hidden",
            hint: "Toggles the inspector sidebar."
        )
    }

    static let snapView = WorkspaceAccessibilityDescription(
        label: "Snap viewport camera",
        value: nil,
        hint: "Opens camera presets for the 3D viewport."
    )

    static let orbitLeft = WorkspaceAccessibilityDescription(
        label: "Orbit viewport left",
        value: nil,
        hint: "Rotates the camera left around the model."
    )

    static let orbitRight = WorkspaceAccessibilityDescription(
        label: "Orbit viewport right",
        value: nil,
        hint: "Rotates the camera right around the model."
    )

    static let panLeft = WorkspaceAccessibilityDescription(
        label: "Pan viewport left",
        value: nil,
        hint: "Moves the camera target left."
    )

    static let panRight = WorkspaceAccessibilityDescription(
        label: "Pan viewport right",
        value: nil,
        hint: "Moves the camera target right."
    )

    static let panUp = WorkspaceAccessibilityDescription(
        label: "Pan viewport up",
        value: nil,
        hint: "Moves the camera target up."
    )

    static let panDown = WorkspaceAccessibilityDescription(
        label: "Pan viewport down",
        value: nil,
        hint: "Moves the camera target down."
    )

    static let zoomIn = WorkspaceAccessibilityDescription(
        label: "Zoom viewport in",
        value: nil,
        hint: "Moves the camera closer to the model."
    )

    static let zoomOut = WorkspaceAccessibilityDescription(
        label: "Zoom viewport out",
        value: nil,
        hint: "Moves the camera farther from the model."
    )

    static let fitView = WorkspaceAccessibilityDescription(
        label: "Fit viewport",
        value: nil,
        hint: "Resets the camera to frame the model."
    )

    static let resetScale = WorkspaceAccessibilityDescription(
        label: "Reset scale",
        value: nil,
        hint: "Restores the imported model scale to 100 percent."
    )

    static let previousAssemblyStep = WorkspaceAccessibilityDescription(
        label: "Previous assembly step",
        value: nil,
        hint: "Moves the assembly highlight to the previous step."
    )

    static let nextAssemblyStep = WorkspaceAccessibilityDescription(
        label: "Next assembly step",
        value: nil,
        hint: "Moves the assembly highlight to the next step."
    )

    static let exportAssemblyGuide = WorkspaceAccessibilityDescription(
        label: "Export assembly guide",
        value: nil,
        hint: "Exports the current assembly steps as a text guide."
    )

    static let clearAssemblyHighlight = WorkspaceAccessibilityDescription(
        label: "Clear assembly highlight",
        value: nil,
        hint: "Clears the selected assembly step highlight."
    )

    static let showAssemblyReference = WorkspaceAccessibilityDescription(
        label: "Assembly Reference",
        value: nil,
        hint: "Opens the cut-sheet reference viewer for this assembly."
    )

    static func assemblyStepRow(_ step: AssemblyStep, isSelected: Bool) -> WorkspaceAccessibilityDescription {
        WorkspaceAccessibilityDescription(
            label: "Assembly step \(step.index): \(step.title)",
            value: isSelected ? "Selected" : "Not selected",
            hint: isSelected ? "Clears the assembly highlight." : "Highlights this assembly step."
        )
    }
}

enum WorkspaceAccessibilityVisualPolicy {
    static let selectedRowFillOpacity = 0.18
    static let selectedRowBorderWidth = 1.5
    static let inactiveRowBorderOpacity = 0.28
    static let inactiveRowBorderWidth = 0.75
    static let noticeFillOpacity = 0.16
    static let noticeBorderOpacity = 0.45
    static let noticeBorderWidth = 1.0
}
