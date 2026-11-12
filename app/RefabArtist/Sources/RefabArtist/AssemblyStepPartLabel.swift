import Foundation

enum AssemblyStepPartLabel {
    static func label(for step: AssemblyStep) -> String? {
        step.title.split(separator: " ").last.map(String.init)
    }

    static func stepID(forPartLabel partLabel: String, steps: [AssemblyStep]) -> AssemblyStep.ID? {
        steps.first { label(for: $0) == partLabel }?.id
    }
}
