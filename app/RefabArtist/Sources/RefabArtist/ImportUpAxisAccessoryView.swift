import AppKit

/// An NSOpenPanel accessory view for choosing the mesh's up-axis at import
/// time. The panel does not support
/// SwiftUI accessories, so we build a compact AppKit row instead.
///
/// Usage:
/// ```swift
/// let accessory = ImportUpAxisAccessoryView()
/// panel.accessoryView = accessory.view
/// // after runModal:
/// let axis = accessory.selectedUpAxis
/// ```
@MainActor
final class ImportUpAxisAccessoryView: NSObject {
    let view: NSView
    private let popup: NSPopUpButton

    override init() {
        // --- Build the label + popup row ---
        let label = NSTextField(labelWithString: "Up axis:")
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for axis in ImportUpAxis.allCases {
            popup.addItem(withTitle: axis.label)
        }
        // Default: Y (the first case), in Y / Z / X order.
        popup.selectItem(at: 0)
        self.popup = popup

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        self.view = stack
        super.init()
    }

    /// The axis the user chose before the panel was dismissed.
    var selectedUpAxis: ImportUpAxis {
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < ImportUpAxis.allCases.count else {
            return .z
        }
        return ImportUpAxis.allCases[index]
    }
}
