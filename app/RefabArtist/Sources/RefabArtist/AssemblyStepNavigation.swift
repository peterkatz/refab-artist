import Foundation

enum AssemblyStepNavigation {
    static func normalizedSelection(_ selectedStepID: AssemblyStep.ID?, steps: [AssemblyStep]) -> AssemblyStep.ID? {
        guard let selectedStepID, steps.contains(where: { $0.id == selectedStepID }) else {
            return nil
        }
        return selectedStepID
    }

    static func nextSelection(after selectedStepID: AssemblyStep.ID?, steps: [AssemblyStep]) -> AssemblyStep.ID? {
        guard !steps.isEmpty else {
            return nil
        }
        guard let selectedStepID,
              let index = steps.firstIndex(where: { $0.id == selectedStepID }) else {
            return steps.first?.id
        }
        let nextIndex = min(index + 1, steps.count - 1)
        return steps[nextIndex].id
    }

    static func previousSelection(before selectedStepID: AssemblyStep.ID?, steps: [AssemblyStep]) -> AssemblyStep.ID? {
        guard !steps.isEmpty else {
            return nil
        }
        guard let selectedStepID,
              let index = steps.firstIndex(where: { $0.id == selectedStepID }) else {
            return steps.first?.id
        }
        let previousIndex = max(index - 1, 0)
        return steps[previousIndex].id
    }

    static func displayText(selectedStepID: AssemblyStep.ID?, steps: [AssemblyStep]) -> String {
        guard let selectedStepID,
              let index = steps.firstIndex(where: { $0.id == selectedStepID }) else {
            return steps.isEmpty ? "0 / 0" : "Select step"
        }
        return "\(index + 1) / \(steps.count)"
    }
}
