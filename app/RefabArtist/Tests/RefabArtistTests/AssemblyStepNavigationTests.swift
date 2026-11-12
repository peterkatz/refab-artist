import Testing
@testable import RefabArtist

struct AssemblyStepNavigationTests {
    @Test
    func normalizedSelectionClearsMissingStep() {
        let steps = Self.steps(count: 2)

        #expect(AssemblyStepNavigation.normalizedSelection(1, steps: steps) == 1)
        #expect(AssemblyStepNavigation.normalizedSelection(3, steps: steps) == nil)
        #expect(AssemblyStepNavigation.normalizedSelection(nil, steps: steps) == nil)
    }

    @Test
    func nextSelectionStartsAtFirstAndClampsAtLast() {
        let steps = Self.steps(count: 3)

        #expect(AssemblyStepNavigation.nextSelection(after: nil, steps: steps) == 1)
        #expect(AssemblyStepNavigation.nextSelection(after: 1, steps: steps) == 2)
        #expect(AssemblyStepNavigation.nextSelection(after: 3, steps: steps) == 3)
        #expect(AssemblyStepNavigation.nextSelection(after: 42, steps: steps) == 1)
    }

    @Test
    func previousSelectionStartsAtFirstAndClampsAtFirst() {
        let steps = Self.steps(count: 3)

        #expect(AssemblyStepNavigation.previousSelection(before: nil, steps: steps) == 1)
        #expect(AssemblyStepNavigation.previousSelection(before: 3, steps: steps) == 2)
        #expect(AssemblyStepNavigation.previousSelection(before: 1, steps: steps) == 1)
        #expect(AssemblyStepNavigation.previousSelection(before: 42, steps: steps) == 1)
    }

    @Test
    func navigationHandlesEmptySteps() {
        #expect(AssemblyStepNavigation.nextSelection(after: nil, steps: []) == nil)
        #expect(AssemblyStepNavigation.previousSelection(before: nil, steps: []) == nil)
        #expect(AssemblyStepNavigation.displayText(selectedStepID: nil, steps: []) == "0 / 0")
    }

    @Test
    func displayTextUsesOneBasedPosition() {
        let steps = Self.steps(count: 3)

        #expect(AssemblyStepNavigation.displayText(selectedStepID: nil, steps: steps) == "Select step")
        #expect(AssemblyStepNavigation.displayText(selectedStepID: 2, steps: steps) == "2 / 3")
        #expect(AssemblyStepNavigation.displayText(selectedStepID: 42, steps: steps) == "Select step")
    }

    @Test
    func partLabelsBridgeExportSheetsBackToAssemblySteps() {
        let steps = [
            AssemblyStep(index: 1, title: "Place slice_001", detail: "First stacked slice."),
            AssemblyStep(index: 2, title: "Insert secondary_001", detail: "Second interlocked family."),
            AssemblyStep(index: 3, title: "Fold folded_panel_001", detail: "Folded panel.")
        ]

        #expect(AssemblyStepPartLabel.label(for: steps[0]) == "slice_001")
        #expect(AssemblyStepPartLabel.label(for: steps[1]) == "secondary_001")
        #expect(AssemblyStepPartLabel.label(for: steps[2]) == "folded_panel_001")
        #expect(AssemblyStepPartLabel.stepID(forPartLabel: "secondary_001", steps: steps) == 2)
        #expect(AssemblyStepPartLabel.stepID(forPartLabel: "missing", steps: steps) == nil)
    }

    private static func steps(count: Int) -> [AssemblyStep] {
        (1...count).map { index in
            AssemblyStep(index: index, title: "Step \(index)", detail: "Detail \(index)")
        }
    }
}
