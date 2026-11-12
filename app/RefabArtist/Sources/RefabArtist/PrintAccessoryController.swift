import AppKit
import Foundation

/// The print-dialog accessory (NEO-109): Print Range radios (Current Sheet /
/// All / From–To) and Rotate By preset buttons (0° / 90° / 180° / 270°).
///
/// macOS provides the printer, copies, and paper size controls; this view
/// extends the dialog with cut-sheet-specific options.
///
/// Usage:
/// ```swift
/// let controller = PrintAccessoryController()
/// let op = NSPrintOperation(data: pdfData)
/// op.printInfo.jobDisposition = .preview
/// op.printPanel.addAccessoryController(controller)
/// op.run()
/// ```
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {

    // MARK: - State

    enum RangeMode: Int {
        case currentSheet = 0
        case allSheets = 1
        case fromTo = 2
    }

    private(set) var rangeMode: RangeMode = .allSheets
    private(set) var fromSheet: Int = 1
    private(set) var toSheet: Int = 1
    private(set) var rotationDegrees: Int = 0

    /// Total sheet count; drives the From/To field validation.
    var sheetCount: Int = 1 {
        didSet {
            toSheet = min(toSheet, max(1, sheetCount))
            if isViewLoaded {
                updateFromToFieldsEnabled()
                toField?.integerValue = toSheet
            }
        }
    }
    /// 1-based index of the sheet currently visible in the sheet preview,
    /// used when the user picks "Current Sheet."
    var currentSheetIndex: Int = 1

    // MARK: - Outlets (built in code — no XIB)

    private weak var currentSheetRadio: NSButton?
    private weak var allSheetsRadio: NSButton?
    private weak var fromToRadio: NSButton?
    private weak var fromField: NSTextField?
    private weak var toField: NSTextField?
    private var rotationGroup: [NSButton] = []

    // MARK: - NSViewController

    override func loadView() {
        view = NSView()
        buildUI()
    }

    // MARK: - NSPrintPanelAccessorizing

    func keyPaths(forValuesAffectingPreview printer: NSPrinter) -> Set<String> {
        []
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        var summary: [[NSPrintPanel.AccessorySummaryKey: String]] = []
        let rangeLabel: String
        switch rangeMode {
        case .currentSheet: rangeLabel = "Current Sheet"
        case .allSheets:    rangeLabel = "All Sheets"
        case .fromTo:       rangeLabel = "Sheets \(fromSheet)–\(toSheet)"
        }
        summary.append([.itemName: "Print Range", .itemDescription: rangeLabel])
        if rotationDegrees != 0 {
            summary.append([.itemName: "Rotate By", .itemDescription: "\(rotationDegrees)°"])
        }
        return summary
    }

    // MARK: - UI construction

    private func buildUI() {
        // --- Print Range section ---
        let rangeTitle = sectionLabel("Print Range")

        let radioCurrentSheet = NSButton(radioButtonWithTitle: "Current Sheet", target: self, action: #selector(rangeChanged(_:)))
        radioCurrentSheet.tag = RangeMode.currentSheet.rawValue

        let radioAll = NSButton(radioButtonWithTitle: "All Sheets", target: self, action: #selector(rangeChanged(_:)))
        radioAll.tag = RangeMode.allSheets.rawValue
        radioAll.state = .on // default

        let radioFromTo = NSButton(radioButtonWithTitle: "Range:", target: self, action: #selector(rangeChanged(_:)))
        radioFromTo.tag = RangeMode.fromTo.rawValue

        currentSheetRadio = radioCurrentSheet
        allSheetsRadio = radioAll
        fromToRadio = radioFromTo

        let fromLabel = NSTextField(labelWithString: "From:")
        let fromF = integerField(initial: 1)
        let toLabel = NSTextField(labelWithString: "To:")
        let toF = integerField(initial: max(1, sheetCount))
        fromField = fromF
        toField = toF

        let fromToRow = NSStackView(views: [radioFromTo, fromLabel, fromF, toLabel, toF])
        fromToRow.orientation = .horizontal
        fromToRow.spacing = 6

        let rangeStack = NSStackView(views: [rangeTitle, radioCurrentSheet, radioAll, fromToRow])
        rangeStack.orientation = .vertical
        rangeStack.alignment = .leading
        rangeStack.spacing = 4

        // --- Rotate By section ---
        let rotateTitle = sectionLabel("Rotate By")

        let degrees = [0, 90, 180, 270]
        let radioButtons: [NSButton] = degrees.map { deg in
            let btn = NSButton(radioButtonWithTitle: "\(deg)°", target: self, action: #selector(rotationChanged(_:)))
            btn.tag = deg
            return btn
        }
        radioButtons.first?.state = .on
        rotationGroup = radioButtons

        let rotateRow = NSStackView(views: radioButtons)
        rotateRow.orientation = .horizontal
        rotateRow.spacing = 12

        let rotateStack = NSStackView(views: [rotateTitle, rotateRow])
        rotateStack.orientation = .vertical
        rotateStack.alignment = .leading
        rotateStack.spacing = 4

        // --- Outer container ---
        let outer = NSStackView(views: [rangeStack, rotateStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outer.topAnchor.constraint(equalTo: view.topAnchor),
            outer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        updateFromToFieldsEnabled()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    private func integerField(initial: Int) -> NSTextField {
        let f = NSTextField()
        f.integerValue = initial
        f.formatter = {
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            fmt.allowsFloats = false
            fmt.minimum = 1
            return fmt
        }()
        f.controlSize = .small
        f.frame = CGRect(x: 0, y: 0, width: 44, height: 20)
        f.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return f
    }

    private func updateFromToFieldsEnabled() {
        let on = rangeMode == .fromTo
        fromField?.isEnabled = on
        toField?.isEnabled = on
    }

    // MARK: - Actions

    @objc private func rangeChanged(_ sender: NSButton) {
        guard let mode = RangeMode(rawValue: sender.tag) else { return }
        rangeMode = mode
        currentSheetRadio?.state = mode == .currentSheet ? .on : .off
        allSheetsRadio?.state   = mode == .allSheets    ? .on : .off
        fromToRadio?.state      = mode == .fromTo       ? .on : .off
        updateFromToFieldsEnabled()
    }

    @objc private func rotationChanged(_ sender: NSButton) {
        rotationDegrees = sender.tag
        rotationGroup.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    // MARK: - Page range resolution

    /// Returns the 1-based (inclusive) sheet indices to print, clamped to
    /// [1, sheetCount]. Sorted ascending.
    func resolvedSheetIndices() -> [Int] {
        let total = max(1, sheetCount)
        switch rangeMode {
        case .currentSheet:
            return [min(max(1, currentSheetIndex), total)]
        case .allSheets:
            return Array(1...total)
        case .fromTo:
            let lo = max(1, fromField?.integerValue ?? 1)
            let hi = min(total, max(lo, toField?.integerValue ?? total))
            return Array(lo...hi)
        }
    }

    /// The CGAffineTransform corresponding to the chosen Rotate By preset,
    /// applied when rendering each page into the print context.
    var pageRotationTransform: CGAffineTransform {
        switch rotationDegrees {
        case 90:  return CGAffineTransform(rotationAngle: -.pi / 2)
        case 180: return CGAffineTransform(rotationAngle: .pi)
        case 270: return CGAffineTransform(rotationAngle: .pi / 2)
        default:  return .identity
        }
    }
}
