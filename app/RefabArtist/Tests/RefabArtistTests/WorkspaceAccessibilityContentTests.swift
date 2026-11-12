import Testing
@testable import RefabArtist

struct WorkspaceAccessibilityContentTests {
    @Test
    func sidebarToggleNamesVisibleAndHiddenStates() {
        let visible = WorkspaceAccessibilityContent.sidebarToggle(isInspectorVisible: true)
        let hidden = WorkspaceAccessibilityContent.sidebarToggle(isInspectorVisible: false)

        #expect(visible.label == "Hide inspector")
        #expect(visible.value == "Inspector visible")
        #expect(hidden.label == "Show inspector")
        #expect(hidden.value == "Inspector hidden")
        #expect(visible.hint == hidden.hint)
    }

    @Test
    func viewportControlLabelsAreUniqueAndHinted() {
        let controls = [
            WorkspaceAccessibilityContent.snapView,
            WorkspaceAccessibilityContent.orbitLeft,
            WorkspaceAccessibilityContent.orbitRight,
            WorkspaceAccessibilityContent.panLeft,
            WorkspaceAccessibilityContent.panRight,
            WorkspaceAccessibilityContent.panUp,
            WorkspaceAccessibilityContent.panDown,
            WorkspaceAccessibilityContent.zoomIn,
            WorkspaceAccessibilityContent.zoomOut,
            WorkspaceAccessibilityContent.fitView
        ]

        #expect(Set(controls.map(\.label)).count == controls.count)
        #expect(controls.allSatisfy { $0.hint?.isEmpty == false })
    }

    @Test
    func assemblyStepRowDescribesSelectionState() {
        let step = AssemblyStep(index: 3, title: "Insert secondary_001", detail: "Mesh through matching slots.")

        let selected = WorkspaceAccessibilityContent.assemblyStepRow(step, isSelected: true)
        let notSelected = WorkspaceAccessibilityContent.assemblyStepRow(step, isSelected: false)

        #expect(selected.label == "Assembly step 3: Insert secondary_001")
        #expect(selected.value == "Selected")
        #expect(selected.hint == "Clears the assembly highlight.")
        #expect(notSelected.value == "Not selected")
        #expect(notSelected.hint == "Highlights this assembly step.")
    }

    @Test
    func assemblyToolbarControlsAreHinted() {
        let controls = [
            WorkspaceAccessibilityContent.previousAssemblyStep,
            WorkspaceAccessibilityContent.nextAssemblyStep,
            WorkspaceAccessibilityContent.exportAssemblyGuide,
            WorkspaceAccessibilityContent.clearAssemblyHighlight,
            WorkspaceAccessibilityContent.resetScale
        ]

        #expect(Set(controls.map(\.label)).count == controls.count)
        #expect(controls.allSatisfy { $0.hint?.isEmpty == false })
    }

    @Test
    func visualPolicyKeepsCustomControlsLegible() {
        #expect(WorkspaceAccessibilityVisualPolicy.selectedRowFillOpacity >= 0.16)
        #expect(WorkspaceAccessibilityVisualPolicy.selectedRowFillOpacity <= 0.24)
        #expect(WorkspaceAccessibilityVisualPolicy.selectedRowBorderWidth >= 1.5)
        #expect(WorkspaceAccessibilityVisualPolicy.inactiveRowBorderOpacity >= 0.25)
        #expect(WorkspaceAccessibilityVisualPolicy.noticeFillOpacity >= 0.14)
        #expect(WorkspaceAccessibilityVisualPolicy.noticeBorderOpacity >= 0.40)
        #expect(WorkspaceAccessibilityVisualPolicy.noticeBorderWidth >= 1.0)
    }
}
