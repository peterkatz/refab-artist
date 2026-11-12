import Foundation

/// The one vector-export path (DXF, SVG, PDF, EPS) for the flat-part modes.
/// The app's Export command and the headless `--headless-export` CLI both call
/// `write`, so a mode/format pair produces the same file whichever front end
/// asked for it.
///
/// SVG and PDF always render the cut sheet: the packed, labeled document the
/// sheet preview shows. DXF renders the cut sheet too, except where a mode has
/// a dedicated DXF writer: Stacked (dowel holes) and Radial. Inflatables
/// renders its cut sheet with seam and label layers. EPS renders the cut
/// sheet for Interlocked, Curve Slices and Folded Panels, and uses the
/// per-sheet EPS writer for the other modes.
enum FlatPartExport {
    /// The flat parts of one planned export.
    enum Source {
        /// `contours` are the plan's slice outlines when the caller already
        /// has them; nil generates them only if the chosen writer needs them
        /// (the cut-sheet writers work from the finished document instead).
        case stacked(StackedSlicePlan, contours: StackedSliceContours?, dowels: DxfExporter.DowelSettings?)
        case interlocked(InterlockedSlicePlan)
        case radial(RadialSlicePlan)
        case curve(CurveSlicePlan)
        case threeD(ThreeDSlicePlan)
        case foldedPanels(FoldedPanelPlan)
        case inflatables(InflatablesPlan)

        var mode: ConstructionMode {
            switch self {
            case .stacked: return .stacked
            case .interlocked: return .interlocked
            case .radial: return .radial
            case .curve: return .curve
            case .threeD: return .threeD
            case .foldedPanels: return .foldedPanels
            case .inflatables: return .inflatables
            }
        }
    }

    enum Writer: Equatable {
        /// `CutSheetDocumentExporter`: the packed cut-sheet document.
        case cutSheet
        /// `InflatablesDXFExporter`: the Inflatables cut sheet with seam,
        /// registration and label layers.
        case inflatablesCutSheet
        /// `DxfExporter.write(contours:)`, with dowel holes.
        case stackedDXF
        /// `DxfExporter.write(radial:)`.
        case radialDXF
        /// `EpsExporter`: one EPS per sheet (a ZIP when there are several).
        case sheetEPS

        /// True when the writer renders the cut-sheet document.
        var usesCutSheet: Bool {
            self == .cutSheet || self == .inflatablesCutSheet
        }
    }

    enum ExportError: LocalizedError {
        case unsupportedFormat(ConstructionMode, ExportFormat)
        case cutSheetNotReady

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let mode, let format):
                return "\(mode.label) has no \(format.label) export."
            case .cutSheetNotReady:
                return "The cut sheet is still preparing — try again in a moment."
            }
        }
    }

    /// Which writer exports `format` for `mode`, or nil when the mode does
    /// not offer that format (the same list the format picker shows).
    static func writer(for mode: ConstructionMode, format: ExportFormat) -> Writer? {
        guard format.usesVectorLayout,
              ExportFormatSupport.availableFormats(for: mode).contains(format) else {
            return nil
        }
        switch format {
        case .svg, .pdf:
            return .cutSheet
        case .eps:
            switch mode {
            case .interlocked, .curve, .foldedPanels:
                return .cutSheet
            default:
                return .sheetEPS
            }
        case .dxf:
            switch mode {
            case .stacked:
                return .stackedDXF
            case .radial:
                return .radialDXF
            case .inflatables:
                return .inflatablesCutSheet
            case .interlocked, .curve, .foldedPanels:
                return .cutSheet
            case .threeD, .structures, .partition, .motherMold:
                return nil
            }
        case .obj, .stl:
            return nil
        }
    }

    /// The cut-sheet document for `source`: what the sheet preview shows and
    /// the cut-sheet writers render.
    static func cutSheetDocument(
        for source: Source,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        switch source {
        case .stacked(let plan, let contours, let dowels):
            return CutSheetLayoutBuilder.document(
                stacked: contours ?? StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan)),
                settings: settings,
                dowels: dowels,
                revision: revision
            )
        case .interlocked(let plan):
            return CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: settings, revision: revision)
        case .radial(let plan):
            return CutSheetLayoutBuilder.document(radial: plan, model: model, settings: settings, revision: revision)
        case .curve(let plan):
            return CutSheetLayoutBuilder.document(curve: plan, model: model, settings: settings, revision: revision)
        case .threeD(let plan):
            return CutSheetLayoutBuilder.document(threeD: plan, model: model, settings: settings, revision: revision)
        case .foldedPanels(let plan):
            return CutSheetLayoutBuilder.document(folded: plan, settings: settings, revision: revision)
        case .inflatables(let plan):
            return plan.cutSheet
        }
    }

    /// Write `source` as `format`. `cutSheet` supplies the cut-sheet document
    /// and is called only when the chosen writer renders it, so the app can
    /// hand over the document its preview already built.
    @discardableResult
    static func write(
        _ source: Source,
        format: ExportFormat,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        cutSheet: () throws -> CutSheetDocument,
        to url: URL
    ) throws -> Writer {
        // A radial plan with no fins is one disk stack plus one plank, which
        // is an Interlocked plan, so it exports exactly like Interlocked.
        if case .radial(let plan) = source, plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return try write(.interlocked(fallback), format: format, model: model, settings: settings, cutSheet: cutSheet, to: url)
        }
        guard let writer = writer(for: source.mode, format: format) else {
            throw ExportError.unsupportedFormat(source.mode, format)
        }
        let unsupported = ExportError.unsupportedFormat(source.mode, format)

        switch writer {
        case .cutSheet:
            let document = try cutSheet()
            switch format {
            case .dxf:
                try CutSheetDocumentExporter.writeDXF(document: document, settings: settings, to: url)
            case .svg:
                try CutSheetDocumentExporter.writeSVG(document: document, settings: settings, to: url)
            case .pdf:
                try CutSheetDocumentExporter.writePDF(document: document, settings: settings, to: url)
            case .eps:
                try CutSheetDocumentExporter.writeEPS(document: document, settings: settings, to: url)
            case .obj, .stl:
                throw unsupported
            }
        case .inflatablesCutSheet:
            try InflatablesDXFExporter.write(document: try cutSheet(), settings: settings, to: url)
        case .stackedDXF:
            guard case .stacked(let plan, let contours, let dowels) = source else { throw unsupported }
            try DxfExporter.write(
                contours: contours ?? StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan)),
                to: url,
                layoutSettings: settings,
                dowels: dowels
            )
        case .radialDXF:
            guard case .radial(let plan) = source else { throw unsupported }
            try DxfExporter.write(radial: plan, model: model, to: url, layoutSettings: settings)
        case .sheetEPS:
            guard let layout = epsLayout(source, model: model, settings: settings) else { throw unsupported }
            try EpsExporter.write(layout: layout, to: url)
        }
        return writer
    }

    /// How many files an EPS export of `source` writes: one per sheet, in a
    /// ZIP when there is more than one. `cutSheet` supplies the cut-sheet
    /// document for the modes whose EPS renders it.
    static func epsFileCount(
        _ source: Source,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        cutSheet: () throws -> CutSheetDocument
    ) throws -> Int {
        if case .radial(let plan) = source, plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return try epsFileCount(.interlocked(fallback), model: model, settings: settings, cutSheet: cutSheet)
        }
        switch writer(for: source.mode, format: .eps) {
        case .cutSheet:
            return CutSheetDocumentExporter.epsFileCount(document: try cutSheet())
        case .sheetEPS:
            return epsLayout(source, model: model, settings: settings).map(EpsExporter.fileCount) ?? 1
        default:
            return 1
        }
    }

    /// The row layout the per-sheet EPS writer renders, for the modes that
    /// use it.
    private static func epsLayout(_ source: Source, model: MeshSummary, settings: ExportLayoutSettings) -> EpsExporter.Layout? {
        switch source {
        case .stacked(let plan, let contours, let dowels):
            return EpsExporter.layout(
                contours: contours ?? StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan)),
                layoutSettings: settings,
                dowels: dowels
            )
        case .radial(let plan):
            return EpsExporter.layout(radial: plan, model: model, layoutSettings: settings)
        case .interlocked, .curve, .threeD, .foldedPanels, .inflatables:
            return nil
        }
    }

    /// `write` for callers with no cut sheet at hand (the headless CLI): the
    /// document is built here if the chosen writer renders it.
    @discardableResult
    static func write(
        _ source: Source,
        format: ExportFormat,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        to url: URL
    ) throws -> Writer {
        try write(
            source,
            format: format,
            model: model,
            settings: settings,
            cutSheet: { cutSheetDocument(for: source, model: model, settings: settings, revision: 1) },
            to: url
        )
    }
}
