import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Runs an NSPrintOperation on the CutSheetDocument using the existing
/// CutSheetDocumentExporter PDF renderer. The print path is GUI-only; the
/// headless export path is unaffected.
///
/// Design:
///   1. Render all sheets to a temporary multi-page PDF (same CG code as the
///      export path — one source of truth, no forked display geometry).
///   2. Load the PDF via PDFDocument so we can access individual pages.
///   3. Drive NSPrintOperation page-by-page via an NSView subclass.
///      The PrintAccessoryController in the print panel controls which sheets
///      print and at what rotation.
///
/// The macOS Print dialog itself provides the preview (via QuickLook/PDF
/// rendering) — we do not need to supply a separate preview window.
enum CutSheetPrintOperation {

    /// Presents the print panel for `document` and runs the operation on
    /// `window`. Errors are reported through `onError`.
    @MainActor
    static func run(
        document: CutSheetDocument,
        settings: ExportLayoutSettings,
        currentSheetIndex: Int,
        on window: NSWindow,
        onError: (String) -> Void
    ) {
        // 1. Render to a temporary PDF file.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refabartist-cutsheet-\(document.revision).pdf")

        do {
            try CutSheetDocumentExporter.writePDF(document: document, settings: settings, to: tmpURL)
        } catch {
            onError("Could not render the cut sheet for printing: \(error.localizedDescription)")
            return
        }

        guard let pdfDoc = PDFDocument(url: tmpURL) else {
            onError("Could not load the rendered cut-sheet PDF for printing.")
            return
        }

        let sheetCount = document.sheets.count

        // 2. Build the print accessory controller.
        let accessory = PrintAccessoryController()
        accessory.sheetCount = sheetCount
        accessory.currentSheetIndex = currentSheetIndex

        // 3. Build an NSView subclass that renders PDF pages on demand.
        let printView = PDFPagePrintView(
            pdfDoc: pdfDoc,
            accessory: accessory,
            sheetWidth: settings.sanitized.sheetWidth,
            sheetHeight: settings.sanitized.sheetHeight
        )

        // 4. Configure and run NSPrintOperation.
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let mmToPt = 72.0 / 25.4
        printInfo.paperSize = NSSize(
            width: settings.sanitized.sheetWidth * mmToPt,
            height: settings.sanitized.sheetHeight * mmToPt
        )
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit

        let operation = NSPrintOperation(view: printView, printInfo: printInfo)
        operation.printPanel.options.insert(.showsPaperSize)
        operation.printPanel.options.insert(.showsOrientation)
        operation.printPanel.addAccessoryController(accessory)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        // runOperation(in:delegate:didRun:contextInfo:) is the recommended
        // sheet-modal path on macOS. We use the simpler synchronous path
        // here; both are exercised by user interaction only.
        operation.run()
    }
}

// MARK: - PDFPagePrintView

/// An NSView that drives NSPrintOperation page-by-page: the view's
/// `knowsPageRange`, `rectForPage`, and `draw(_:)` methods are called
/// per-page by the AppKit printing machinery.
private final class PDFPagePrintView: NSView {
    private let pdfDoc: PDFDocument
    private weak var accessory: PrintAccessoryController?
    private let sheetWidthMM: Double
    private let sheetHeightMM: Double
    private var resolvedIndices: [Int] = []

    init(
        pdfDoc: PDFDocument,
        accessory: PrintAccessoryController,
        sheetWidth: Double,
        sheetHeight: Double
    ) {
        self.pdfDoc = pdfDoc
        self.accessory = accessory
        self.sheetWidthMM = sheetWidth
        self.sheetHeightMM = sheetHeight
        let mmToPt = 72.0 / 25.4
        super.init(frame: NSRect(x: 0, y: 0, width: sheetWidth * mmToPt, height: sheetHeight * mmToPt))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { false }

    // NSView page range support

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // Resolve the sheet indices at the moment the panel is committed.
        resolvedIndices = accessory?.resolvedSheetIndices() ?? Array(1...(pdfDoc.pageCount))
        range.pointee = NSRange(location: 1, length: resolvedIndices.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let mmToPt = 72.0 / 25.4
        return NSRect(x: 0, y: 0, width: sheetWidthMM * mmToPt, height: sheetHeightMM * mmToPt)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // pageNumber is 1-based within the print job; map via resolvedIndices.
        // NSPrintOperation calls draw(_:) for the current page; retrieve it.
        let printOp = NSPrintOperation.current
        let jobPage = printOp?.currentPage ?? 1
        let sheetIndex = resolvedIndices.indices.contains(jobPage - 1)
            ? resolvedIndices[jobPage - 1] - 1   // 0-based PDF page index
            : 0

        guard sheetIndex >= 0, sheetIndex < pdfDoc.pageCount,
              let pdfPage = pdfDoc.page(at: sheetIndex) else { return }

        let rotation = accessory?.pageRotationTransform ?? .identity
        let bounds = pdfPage.bounds(for: .mediaBox)
        let w = bounds.width
        let h = bounds.height

        guard let cgPage = pdfPage.pageRef else { return }
        ctx.saveGState()
        if rotation != .identity {
            // Translate to center, rotate, translate back so the page stays
            // centred on the paper.
            ctx.translateBy(x: w / 2, y: h / 2)
            ctx.concatenate(rotation)
            ctx.translateBy(x: -w / 2, y: -h / 2)
        }
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
    }
}
