import SwiftUI

/// Cut-sheet preview: gray sheets with a big sheet
/// number, near-white parts, BLUE cut outlines, RED scored guides and RED
/// part labels sized to the part (6/9 disambiguated with an underline).
///
/// Performance contract: all geometry `Path`s are built ONCE per document
/// revision (`CutSheetRenderModel`); per-frame drawing only replays cached
/// paths under the current zoom transform. No loop reconstruction, no
/// per-frame geometry work.
struct ExportSheetPreview: View {
    let document: CutSheetDocument
    let selectedStepIndex: Int?
    let onSelectStep: (Int) -> Void

    @State private var zoom = 1.0
    @State private var renderModel: CutSheetRenderModel?

    private var model: CutSheetRenderModel {
        if let renderModel, renderModel.revision == document.revision {
            return renderModel
        }
        return CutSheetRenderModel(document: document)
    }

    var body: some View {
        // The summary/zoom/selection chips live in a slim bar ABOVE the
        // canvas, never floating over it — at small pane sizes the floating
        // chips blanketed the top of sheet 1 and stole part clicks.
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let selected = model.part(forStepIndex: selectedStepIndex) {
                    selectedPartInspector(selected)
                }
                Spacer(minLength: 8)
                summaryHeader
                previewControls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            GeometryReader { geometry in
                let model = self.model
                let fitScale = model.fittedScale(in: geometry.size)
                let scale = fitScale * zoom
                let canvasSize = CGSize(
                    width: model.size.width * scale + CutSheetRenderModel.contentPadding * 2,
                    height: model.size.height * scale + CutSheetRenderModel.contentPadding * 2
                )

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        CutSheetCanvas(model: model, selectedStepIndex: selectedStepIndex, scale: scale)
                        CutSheetHitTargets(model: model, scale: scale, onSelectStep: onSelectStep)
                    }
                    .frame(
                        width: max(canvasSize.width, geometry.size.width),
                        height: max(canvasSize.height, geometry.size.height)
                    )
                }
                .background(CutSheetPalette.canvas)
            }
        }
        .onAppear { renderModel = model }
        .onChange(of: document.revision) {
            renderModel = CutSheetRenderModel(document: document)
        }
        .accessibilityLabel("Sheet preview")
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text("Sheets").font(.caption2).foregroundStyle(.secondary)
                Text("\(document.sheets.count)").font(.title3.weight(.semibold)).monospacedDigit()
            }
            VStack(spacing: 0) {
                Text("Parts").font(.caption2).foregroundStyle(.secondary)
                Text("\(document.partCount)").font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.sheets.count) sheets, \(document.partCount) parts")
    }

    private var previewControls: some View {
        HStack(spacing: 6) {
            Button {
                zoom = max(0.25, zoom / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Button {
                zoom = min(8.0, zoom * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Button {
                zoom = 1.0
            } label: {
                Image(systemName: "viewfinder")
            }
            .help("Fit sheets")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func selectedPartInspector(_ part: CutSheetRenderModel.RenderPart) -> some View {
        HStack(spacing: 8) {
            Text(part.label)
                .font(.caption.weight(.semibold))
            Text("Sheet \(part.sheetNumber)")
            Text("\(Vec3.format(part.partWidth)) x \(Vec3.format(part.partHeight)) mm")
            if part.isError {
                Label("Slot splits part", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if part.isDetached {
                Label("Not joined to the rest of the model: glue it in place", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.blue)
            }
            if part.overflowsSheet {
                Label("Exceeds sheet", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected part \(part.label), sheet \(part.sheetNumber), \(Vec3.format(part.partWidth)) by \(Vec3.format(part.partHeight)) millimeters")
    }
}

/// Cut-sheet colors. The sheet rendering uses the same light colors in both
/// system appearances.
enum CutSheetPalette {
    static let canvas = Color(red: 0.835, green: 0.847, blue: 0.862)
    static let sheetFill = Color(red: 0.604, green: 0.612, blue: 0.624)
    static let sheetFrame = Color(white: 0.92)
    static let sheetNumber = Color(white: 0.95)
    static let partFill = Color(red: 0.945, green: 0.937, blue: 0.922)
    /// Solid red error fill: the part has an error that makes the model hard
    /// or impossible to build.
    static let errorFill = Color(red: 0.78, green: 0.05, blue: 0.05)
    /// Solid blue detached fill: the piece is detached from the model and
    /// would fall off.
    static let detachedFill = Color(red: 0.16, green: 0.32, blue: 0.85)
    static let cut = Color(red: 0, green: 0, blue: 1)
    static let guide = Color(red: 1, green: 0, blue: 0)
    static let label = Color(red: 1, green: 0, blue: 0)
}

/// Prebuilt, zoom-independent render geometry for one document revision.
struct CutSheetRenderModel {
    static let contentPadding = 24.0
    static let sheetGap = 16.0

    struct RenderPart {
        var label: String
        var stepIndex: Int?
        var sheetNumber: Int
        var fillPath: Path        // even-odd: outer + holes
        var cutPath: Path         // loops + open cut fragments
        var guidePath: Path       // scored assembly guides
        var circlePath: Path
        var labelText: AttributedString
        var labelCenter: CGPoint
        var labelSize: Double
        var hitRect: CGRect       // document space
        var partWidth: Double
        var partHeight: Double
        var overflowsSheet: Bool
        /// Red error fill (e.g. "Notches split part").
        var isError = false
        /// Blue detached-piece fill (it will fall off).
        var isDetached = false
    }

    struct RenderSheet {
        var number: Int
        var rect: CGRect          // document space
        var parts: [RenderPart]
    }

    var revision: Int
    var size: CGSize
    var sheets: [RenderSheet]

    init(document: CutSheetDocument) {
        revision = document.revision

        let sheetWidth = document.sheetWidth > 0
            ? document.sheetWidth
            : document.sheets
                .flatMap(\.parts)
                .map(\.bounds.max.x)
                .max()
                .map { $0 + 10 } ?? 100
        var builtSheets: [RenderSheet] = []
        var y = 0.0
        for sheet in document.sheets {
            let sheetHeight = document.sheetHeight > 0
                ? document.sheetHeight
                : sheet.parts.map(\.bounds.max.y).max().map { $0 + 10 } ?? 100
            let rect = CGRect(x: 0, y: y, width: sheetWidth, height: sheetHeight)
            let parts = sheet.parts.map { part in
                Self.renderPart(part, sheetNumber: sheet.index, sheetOrigin: rect.origin)
            }
            builtSheets.append(RenderSheet(number: sheet.index, rect: rect, parts: parts))
            y += sheetHeight + Self.sheetGap
        }
        sheets = builtSheets
        size = CGSize(width: sheetWidth, height: max(1, y - Self.sheetGap))
    }

    func fittedScale(in viewport: CGSize) -> Double {
        let availableWidth = max(1.0, Double(viewport.width) - Self.contentPadding * 2)
        let availableHeight = max(1.0, Double(viewport.height) - Self.contentPadding * 2)
        return max(0.05, min(availableWidth / max(size.width, 1), availableHeight / max(size.height, 1)))
    }

    func part(forStepIndex stepIndex: Int?) -> RenderPart? {
        guard let stepIndex else { return nil }
        for sheet in sheets {
            if let part = sheet.parts.first(where: { $0.stepIndex == stepIndex }) {
                return part
            }
        }
        return nil
    }

    private static func renderPart(_ part: CutSheetPart, sheetNumber: Int, sheetOrigin: CGPoint) -> RenderPart {
        func point(_ p: Vec2) -> CGPoint {
            CGPoint(x: sheetOrigin.x + p.x, y: sheetOrigin.y + p.y)
        }

        var fill = Path()
        var cut = Path()
        for loop in part.cutLoops where loop.count >= 2 {
            var sub = Path()
            sub.move(to: point(loop[0]))
            for p in loop.dropFirst() {
                sub.addLine(to: point(p))
            }
            sub.closeSubpath()
            fill.addPath(sub)
            cut.addPath(sub)
        }
        for fragment in part.openCuts where fragment.count >= 2 {
            cut.move(to: point(fragment[0]))
            for p in fragment.dropFirst() {
                cut.addLine(to: point(p))
            }
        }

        var guide = Path()
        for line in part.guideLines where line.count >= 2 {
            guide.move(to: point(line[0]))
            for p in line.dropFirst() {
                guide.addLine(to: point(p))
            }
        }
        // Fold lines: perforation dashes are cut through, full fold lines
        // are scored.
        for fold in part.foldLines where fold.count >= 2 {
            if part.foldsArePerforated {
                cut.move(to: point(fold[0]))
                for p in fold.dropFirst() {
                    cut.addLine(to: point(p))
                }
            } else {
                guide.move(to: point(fold[0]))
                for p in fold.dropFirst() {
                    guide.addLine(to: point(p))
                }
            }
        }

        var circles = Path()
        for circle in part.circles {
            let center = point(circle.center)
            circles.addEllipse(in: CGRect(
                x: center.x - circle.radius,
                y: center.y - circle.radius,
                width: circle.radius * 2,
                height: circle.radius * 2
            ))
        }
        // Non-round dowel shapes share the circle path (and its dowel-edit
        // highlight).
        for hole in part.holeLoops where hole.count >= 3 {
            var sub = Path()
            sub.move(to: point(hole[0]))
            for p in hole.dropFirst() {
                sub.addLine(to: point(p))
            }
            sub.closeSubpath()
            circles.addPath(sub)
        }

        let width = part.bounds.max.x - part.bounds.min.x
        let height = part.bounds.max.y - part.bounds.min.y
        let hitRect = CGRect(
            x: sheetOrigin.x + part.bounds.min.x,
            y: sheetOrigin.y + part.bounds.min.y,
            width: width,
            height: height
        )
        return RenderPart(
            label: part.label,
            stepIndex: part.stepIndex,
            sheetNumber: sheetNumber,
            fillPath: fill,
            cutPath: cut,
            guidePath: guide,
            circlePath: circles,
            labelText: Self.labelText(part.label),
            labelCenter: CGPoint(
                x: sheetOrigin.x + part.labelAnchor.x,
                y: sheetOrigin.y + part.labelAnchor.y
            ),
            labelSize: Self.labelSize(radius: part.labelRadius, characterCount: part.label.count),
            hitRect: hitRect,
            partWidth: width,
            partHeight: height,
            overflowsSheet: part.overflowsSheet,
            isError: part.isError,
            isDetached: part.isDetached
        )
    }

    /// Red numerals sized to the part. The 6 and 9 digits carry a
    /// disambiguating underline.
    private static func labelText(_ label: String) -> AttributedString {
        var attributed = AttributedString()
        for character in label {
            var piece = AttributedString(String(character))
            if character == "6" || character == "9" {
                piece.underlineStyle = .single
            }
            attributed += piece
        }
        return attributed
    }

    /// Engrave-safe sizing: the rendered label (width ≈ chars · 0.6 · size,
    /// height ≈ size) must fit inside the inscribed circle at the anchor —
    /// never over the cut line. No lower clamp: a tiny part gets a tiny label.
    static func labelSize(radius: Double, characterCount: Int) -> Double {
        let chars = Double(max(1, characterCount))
        let heightLimited = radius * 1.2
        let widthLimited = (radius * 1.9) / (chars * 0.6)
        return min(60, max(0.6, min(heightLimited, widthLimited)))
    }
}

struct CutSheetCanvas: View {
    let model: CutSheetRenderModel
    let selectedStepIndex: Int?
    let scale: Double

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(CutSheetPalette.canvas))
            context.translateBy(x: CutSheetRenderModel.contentPadding, y: CutSheetRenderModel.contentPadding)
            context.scaleBy(x: scale, y: scale)

            for sheet in model.sheets {
                context.fill(Path(sheet.rect), with: .color(CutSheetPalette.sheetFill))
                context.stroke(Path(sheet.rect), with: .color(CutSheetPalette.sheetFrame), lineWidth: 2.0 / scale)

                let numberSize = max(6.0, min(sheet.rect.width, sheet.rect.height) * 0.075)
                context.draw(
                    Text("\(sheet.number)")
                        .font(.system(size: numberSize, weight: .bold))
                        .foregroundStyle(CutSheetPalette.sheetNumber),
                    at: CGPoint(x: sheet.rect.minX + numberSize * 0.45, y: sheet.rect.minY + numberSize * 0.55),
                    anchor: .center
                )

                for part in sheet.parts {
                    let isSelected = part.stepIndex != nil && part.stepIndex == selectedStepIndex

                    let fillColor: Color = part.isError
                        ? CutSheetPalette.errorFill
                        : (part.isDetached ? CutSheetPalette.detachedFill : CutSheetPalette.partFill)
                    context.fill(
                        part.fillPath,
                        with: .color(fillColor),
                        style: FillStyle(eoFill: true)
                    )
                    context.stroke(
                        part.cutPath,
                        with: .color(isSelected ? Color.accentColor : CutSheetPalette.cut),
                        lineWidth: (isSelected ? 1.3 : 0.8) / scale
                    )
                    if !part.guidePath.isEmpty {
                        context.stroke(part.guidePath, with: .color(CutSheetPalette.guide), lineWidth: 0.7 / scale)
                    }
                    if !part.circlePath.isEmpty {
                        context.stroke(part.circlePath, with: .color(CutSheetPalette.cut), lineWidth: 0.7 / scale)
                    }

                    context.draw(
                        Text(part.labelText)
                            .font(.system(size: part.labelSize, weight: .regular))
                            .foregroundStyle(
                                isSelected
                                    ? Color.accentColor
                                    : ((part.isError || part.isDetached) ? CutSheetPalette.sheetNumber : CutSheetPalette.label)
                            ),
                        at: part.labelCenter,
                        anchor: .center
                    )

                    if isSelected {
                        context.stroke(
                            Path(part.hitRect.insetBy(dx: -1.5 / scale, dy: -1.5 / scale)),
                            with: .color(Color.accentColor),
                            lineWidth: 1.2 / scale
                        )
                    }
                }
            }
        }
    }
}

struct CutSheetHitTargets: View {
    let model: CutSheetRenderModel
    let scale: Double
    let onSelectStep: (Int) -> Void

    var body: some View {
        ForEach(model.sheets, id: \.number) { sheet in
            ForEach(Array(sheet.parts.enumerated()), id: \.element.label) { _, part in
                if let stepIndex = part.stepIndex {
                    let rect = scaledRect(part.hitRect)
                    Button {
                        onSelectStep(stepIndex)
                    } label: {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityLabel("Select part \(part.label)")
                    .accessibilityIdentifier("sheet-part-\(part.label)")
                }
            }
        }
    }

    private func scaledRect(_ rect: CGRect) -> CGRect {
        let minX = CutSheetRenderModel.contentPadding + rect.minX * scale
        let minY = CutSheetRenderModel.contentPadding + rect.minY * scale
        let width = max(12, rect.width * scale)
        let height = max(12, rect.height * scale)
        return CGRect(
            x: minX + (rect.width * scale - width) / 2,
            y: minY + (rect.height * scale - height) / 2,
            width: width,
            height: height
        )
    }
}
