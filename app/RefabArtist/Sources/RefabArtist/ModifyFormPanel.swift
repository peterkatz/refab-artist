import SwiftUI

/// Which Modify Form tool is in play. Raw values are persisted in project
/// documents — do not rename cases.
enum ModifyFormTool: String, Codable, CaseIterable {
    case hollow
    case thicken
    case shrinkwrap

    var label: String {
        switch self {
        case .hollow: return "Hollow"
        case .thicken: return "Thicken"
        case .shrinkwrap: return "Make Watertight"
        }
    }

    /// Verb phrase for the Apply button help ("Slice and export the … form").
    /// `label.lowercased()` would read awkwardly for the watertight heal
    /// ("make watertighted form"), so spell the past form out per tool.
    var appliedFormPhrase: String {
        switch self {
        case .hollow: return "hollowed"
        case .thicken: return "thickened"
        case .shrinkwrap: return "watertight-healed"
        }
    }
}

/// How Make Watertight closes a model. Raw values are persisted.
enum WatertightMethod: String, Codable, CaseIterable {
    /// Fix in place: heal local defects and cap each opening, keeping every
    /// untouched original triangle (OpeningCapper). Raw value predates the
    /// local-heal step — keep it for saved projects.
    case closeOpenings
    /// Give an open skin real walls (inward thickness), rim left open.
    case walls
    /// Rebuild the whole surface as one solid (MeshHealer voxel heal).
    case rebuild

    var label: String {
        switch self {
        case .closeOpenings: return "Fix in place"
        case .walls: return "Make walls"
        case .rebuild: return "Rebuild as solid"
        }
    }

    /// The methods that can fix a model, best first: Fix in place whenever
    /// the damage is local, Make walls when there is an opening to build
    /// walls around, Rebuild as solid when anything is wrong. Empty while
    /// there is no current diagnosis (nothing can be recommended yet) and for
    /// a closed solid with nothing to fix. There is no default method beyond
    /// Fix in place: Rebuild as solid replaces every triangle, so it only
    /// ever runs when the user picks it by name.
    static func offered(for diagnosis: OpeningCapper.Diagnosis?) -> [WatertightMethod] {
        guard let diagnosis, !diagnosis.isNothingToFix else { return [] }
        guard diagnosis.canCloseOpenings else { return [.rebuild] }
        return diagnosis.openings.isEmpty ? [.closeOpenings, .rebuild] : [.closeOpenings, .walls, .rebuild]
    }

    /// Why `self` can't do anything useful for this model with these
    /// per-opening choices (nil = it can, or the diagnosis isn't in yet).
    /// Shown as the hint on a disabled button — never run a method that is
    /// known to change nothing.
    func unavailableReason(_ diagnosis: OpeningCapper.Diagnosis?,
                           choices: [OpeningCapper.OpeningChoice] = []) -> String? {
        guard let diagnosis else { return nil }
        let byOpening = OpeningCapper.matchChoices(choices, to: diagnosis.openings).byOpening
        switch self {
        case .closeOpenings:
            if diagnosis.isNothingToFix { return "Already a closed solid — nothing to fix." }
            guard diagnosis.canCloseOpenings else {
                return diagnosis.blockingReason
                    ?? "Fix in place can't trace these open edges into holes it can fill. Rebuild as solid can close them, but it replaces the whole surface."
            }
            if !diagnosis.openings.isEmpty, byOpening.allSatisfy({ $0?.leaveOpen ?? false }),
               !diagnosis.hasFixableProblemsBesidesOpenings {
                return "Every opening is set to Leave open, so Fix in place has nothing left to do."
            }
            return nil
        case .walls:
            if diagnosis.openings.isEmpty {
                return "Make walls needs an opening to keep open, and this model has none. For a closed model, use Hollow."
            }
            if diagnosis.blockingReason != nil {
                return "The surface is too damaged to build walls on. Use Rebuild as solid."
            }
            if byOpening.allSatisfy({ $0?.closedInWalls ?? false }) {
                return "Every opening is set to Closed. Leave at least one open for Make walls."
            }
            return nil
        case .rebuild:
            return nil
        }
    }

    /// The method a saved project / undo snapshot restores. nil = no pick
    /// saved: the diagnosis decides (`diagnosisDefault`). A Make Watertight
    /// saved active without a method AND without a top-height key predates
    /// Fix in place, so it was the whole-surface rebuild.
    static func restored(saved: String?, activeTool: ModifyFormTool?, savedTopHeight: Double?) -> WatertightMethod? {
        if let method = saved.flatMap(WatertightMethod.init(rawValue:)) { return method }
        if activeTool == .shrinkwrap, savedTopHeight == nil { return .rebuild }
        return nil
    }

    /// Whether a project / snapshot should save the method: when the user
    /// picked it, or when it produced the Make Watertight result in use (so
    /// reopening or undo reproduces that result, never a different method).
    static func shouldPersist(chosen: Bool, activeTool: ModifyFormTool?, preprocessEnabled: Bool) -> Bool {
        chosen || activeTool == .shrinkwrap || preprocessEnabled
    }
}

/// Modify Form panel — non-destructive whole-model mesh tools: select a
/// tool, adjust its slider, and apply; the eye icon previews the change.
///
/// Nothing here is destructive. The imported mesh is never replaced:
///   - The eye icon previews a tool's result in the viewport (view-only).
///   - Apply makes slicing/export use the modified form.
///   - Remove (or applying the other tool) reverts instantly.
///
/// Shipped tools (real geometry):
///   - Hollow: creates an inner shell at the requested wall thickness.
///   - Thicken: offsets every face plane outward (mitre-true offsets).
///   - Make Watertight: Close openings (OpeningCapper — caps each opening,
///     keeps every original triangle, flat/dome/dish top) or Rebuild as solid
///     (MeshHealer GWN heal — re-creates the whole surface, fills cavities).
struct ModifyFormPanel: View {

    // MARK: - Injected state

    /// Hollow wall thickness, mm.
    @Binding var hollowWallThickness: Double
    /// Thicken offset amount, mm.
    @Binding var thickenAmount: Double
    /// Make Watertight detail, 0 (coarse) … 1 (fine heal resolution).
    @Binding var shrinkwrapDetail: Double
    /// Make Watertight method (Close openings / Rebuild as solid).
    @Binding var watertightMethod: WatertightMethod
    /// Close openings: top shape in mm (0 flat, > 0 dome, < 0 dish).
    @Binding var watertightTopHeight: Double
    /// Make walls: wall thickness in mm (grows inward).
    @Binding var wallThickness: Double
    /// What's wrong with the surface (nil while it's being measured).
    var openingDiagnosis: OpeningCapper.Diagnosis?
    /// Result line of the Make Watertight run in use (nil while it isn't
    /// computed for the settings on screen).
    var watertightReceipt: String?
    /// Make Watertight runs under this Hollow / Thicken (nil = not, or
    /// Make Watertight is itself the active tool).
    var watertightUnder: String? = nil
    /// Make Watertight with the settings on screen is already known to change
    /// nothing: its result line (Apply / eye stay disabled until a setting
    /// changes).
    var watertightKnownNoOp: String? = nil
    /// Turn Make Watertight off, also when it runs under Hollow / Thicken.
    var onRemoveWatertight: (() -> Void)? = nil
    /// Per-opening choices (Cap / Leave open + own top shape in Fix in place,
    /// Open / Closed in Make walls), keyed by opening signature.
    @Binding var openingChoices: [OpeningCapper.OpeningChoice]
    /// Saved choices dropped because their opening is gone (shown once).
    var openingChoicesNotice: String? = nil
    /// The selected viewport issue marker ("opening-N" highlights row N).
    var selectedIssueSiteID: String? = nil
    /// A row was clicked: select opening `index` (0-based, diagnosis order).
    var onSelectOpening: (Int) -> Void = { _ in }

    /// The tool slicing currently uses (nil = original mesh).
    var activeTool: ModifyFormTool?
    /// The tool the viewport is eye-previewing (nil = no preview).
    var previewTool: ModifyFormTool?
    /// True while the modified mesh is computing off-main.
    var isComputing: Bool

    /// Eye toggled: preview this tool (nil turns the preview off).
    var onPreview: (ModifyFormTool?) -> Void
    /// Apply: slicing uses this tool's modified form from now on.
    var onApply: (ModifyFormTool) -> Void
    /// Remove the active tool: slicing returns to the original mesh.
    var onRemove: () -> Void
    /// Slider released / field committed for this tool — recompute if shown.
    var onParameterCommit: (ModifyFormTool) -> Void

    /// The number field being edited: leaving it commits its value (Return
    /// isn't the only way out of a field), so an applied result never goes
    /// stale silently.
    private enum Field: Hashable { case amount(ModifyFormTool), topHeight, wall, detail }
    @FocusState private var focusedField: Field?

    private func tool(of field: Field) -> ModifyFormTool {
        switch field {
        case .amount(let tool): return tool
        case .topHeight, .wall, .detail: return .shrinkwrap
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            helpBanner

            Divider()

            toolRow(
                tool: .hollow,
                symbol: "cube.transparent",
                value: $hollowWallThickness,
                range: 0.5...30.0,
                detail: "Creates a shell of the model — same outside, hollow inside. The shell is interior, so the solid view looks unchanged; the slice contours show it."
            )

            Divider()

            toolRow(
                tool: .thicken,
                symbol: "cube.fill",
                value: $thickenAmount,
                range: 0.1...20.0,
                detail: "Widens every part of the model — rescues cutouts too thin to survive cutting."
            )

            Divider()

            watertightRow
        }
        .onChange(of: focusedField) { old, _ in
            guard let old else { return }
            // After the field has written its value back.
            DispatchQueue.main.async { onParameterCommit(tool(of: old)) }
        }
    }

    // MARK: - Help banner

    @ViewBuilder
    private var helpBanner: some View {
        Text("Applies to the whole mesh before slicing. Nothing is destructive — Remove reverts to the imported mesh at any time.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if isComputing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Computing modified mesh…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Generic tool row

    @ViewBuilder
    private func toolRow(
        tool: ModifyFormTool,
        symbol: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String = "mm",
        fractionDigits: Int = 1,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            toolHeader(tool: tool, symbol: symbol)

            HStack(spacing: 8) {
                Slider(value: value, in: range, onEditingChanged: { editing in
                    if !editing { onParameterCommit(tool) }
                })
                    .frame(minWidth: 80)
                TextField(unit, value: value, format: .number.precision(.fractionLength(fractionDigits)))
                    .focused($focusedField, equals: .amount(tool))
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { onParameterCommit(tool) }
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Make Watertight row

    /// Whether the per-opening list has anything to offer for `method`:
    /// Fix in place with two or more openings, or one opening on a model with
    /// other damage (leaving it open still leaves something to fix); Make
    /// walls with two or more openings (closing the only one would seal the
    /// model). One opening and nothing else is fully covered by the global
    /// controls — no list, no dead controls.
    static func showsOpeningRows(_ diagnosis: OpeningCapper.Diagnosis?, method: WatertightMethod) -> Bool {
        guard let diagnosis, !diagnosis.openings.isEmpty, diagnosis.blockingReason == nil else { return false }
        switch method {
        case .closeOpenings:
            return diagnosis.openings.count >= 2 || diagnosis.hasFixableProblemsBesidesOpenings
        case .walls:
            return diagnosis.openings.count >= 2
        case .rebuild:
            return false
        }
    }

    /// Issue-marker id of opening `index` (0-based), as `Diagnosis.sites` names it.
    static func siteID(forOpening index: Int) -> String { "opening-\(index + 1)" }

    /// The saved choice for each diagnosed opening (nil = defaults).
    private var choicesByOpening: [OpeningCapper.OpeningChoice?] {
        OpeningCapper.matchChoices(openingChoices, to: openingDiagnosis?.openings ?? []).byOpening
    }

    /// Change opening `index`'s choice: the old entry (matched by signature)
    /// is replaced by one keyed to the opening as diagnosed now; a choice back
    /// at the defaults is removed.
    private func updateChoice(_ index: Int, commit: Bool = true, _ change: (inout OpeningCapper.OpeningChoice) -> Void) {
        guard let openings = openingDiagnosis?.openings, openings.indices.contains(index) else { return }
        let matched = choicesByOpening
        var choice = matched[index] ?? OpeningCapper.OpeningChoice(signature: openings[index].signature)
        var list = openingChoices
        if let old = matched[index], let at = list.firstIndex(of: old) { list.remove(at: at) }
        change(&choice)
        choice.signature = openings[index].signature
        if !choice.isDefault { list.append(choice) }
        openingChoices = list
        if commit { onParameterCommit(.shrinkwrap) }
    }

    @ViewBuilder
    private func openingRows(method: WatertightMethod) -> some View {
        let openings = openingDiagnosis?.openings ?? []
        let byOpening = choicesByOpening
        VStack(alignment: .leading, spacing: 4) {
            Text(method == .walls ? "Each opening" : "Each opening (top shape defaults to the slider above)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(openings.enumerated()), id: \.offset) { index, opening in
                let choice = byOpening[index]
                let selected = selectedIssueSiteID == Self.siteID(forOpening: index)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(opening.label(number: index + 1))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if method == .walls {
                            Picker("", selection: Binding(
                                get: { choice?.closedInWalls ?? false },
                                set: { closed in updateChoice(index) { $0.closedInWalls = closed } }
                            )) {
                                Text("Open").tag(false)
                                Text("Closed").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Open keeps this rim open. Closed gives it a floor or lid as thick as the wall.")
                        } else {
                            Picker("", selection: Binding(
                                get: { choice?.leaveOpen ?? false },
                                set: { open in updateChoice(index) { $0.leaveOpen = open } }
                            )) {
                                Text("Cap").tag(false)
                                Text("Leave open").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Cap closes this opening with a new top. Leave open keeps it open — the model is then not watertight, by your choice.")
                        }
                    }
                    if method == .closeOpenings, !(choice?.leaveOpen ?? false) {
                        HStack(spacing: 4) {
                            Text("Top")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { choice?.topHeight ?? watertightTopHeight },
                                set: { value in updateChoice(index, commit: false) { $0.topHeight = value } }
                            ), in: -topHeightLimit...topHeightLimit, onEditingChanged: { editing in
                                if !editing { onParameterCommit(.shrinkwrap) }
                            })
                                .controlSize(.mini)
                                .frame(minWidth: 60)
                            Text(String(format: "%.1f mm", choice?.topHeight ?? watertightTopHeight))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(choice?.topHeight == nil ? .tertiary : .secondary)
                                .frame(width: 50, alignment: .trailing)
                            Button {
                                updateChoice(index) { $0.topHeight = nil }
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .disabled(choice?.topHeight == nil)
                            .help(choice?.topHeight == nil
                                  ? "This opening follows the Top shape slider above."
                                  : "Follow the Top shape slider above again.")
                        }
                        .help("This opening's top shape: 0 is flat, right domes it outward, left dishes it inward.")
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelectOpening(index) }
                .help("Click to show this opening in the viewport.")
            }
            if let openingChoicesNotice {
                Text(openingChoicesNotice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var methodPicker: some View {
        Picker("Method", selection: $watertightMethod) {
            ForEach(WatertightMethod.allCases, id: \.self) { method in
                Text(method.label).tag(method)
            }
        }
        .labelsHidden()
    }

    /// Largest dome/dish the slider offers: half the widest opening.
    private var topHeightLimit: Double {
        let widest = openingDiagnosis?.openings.map(\.diameter).max() ?? 60
        return max(5, (widest * 0.5).rounded())
    }

    @ViewBuilder
    private var watertightRow: some View {
        let canClose = openingDiagnosis?.canCloseOpenings ?? false
        let hasOpenings = !(openingDiagnosis?.openings.isEmpty ?? true)
        let unavailable = watertightMethod.unavailableReason(openingDiagnosis, choices: openingChoices)
        VStack(alignment: .leading, spacing: 6) {
            toolHeader(tool: .shrinkwrap, symbol: "wand.and.stars.inverse",
                       disabledReason: openingDiagnosis == nil
                           ? "Measuring the surface… Make Watertight can be applied once it knows which fixes fit."
                           : (unavailable ?? watertightKnownNoOp.map { "Already tried with these settings: \($0) Change a setting to try again." }))

            if let openingDiagnosis {
                Text(openingDiagnosis.sentence)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Segments when the pane is wide enough for all three names; a
            // vertical list of the same choices when it isn't (the segments
            // can't shrink, and one row too wide widens the whole panel).
            ViewThatFits(in: .horizontal) {
                methodPicker.pickerStyle(.segmented)
                methodPicker.pickerStyle(.radioGroup)
            }
            .help("Fix in place heals the broken spots and caps each opening, keeping the rest of your surface exactly as it is. Make walls turns an open skin into a vessel with real walls. Rebuild as solid re-creates the whole surface as one solid — for scans too broken to fix.")

            switch watertightMethod {
            case .closeOpenings:
                if canClose {
                    if hasOpenings {
                        HStack(spacing: 6) {
                            Text("Dish")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $watertightTopHeight, in: -topHeightLimit...topHeightLimit, onEditingChanged: { editing in
                                if !editing { onParameterCommit(.shrinkwrap) }
                            })
                                .frame(minWidth: 80)
                            Text("Dome")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("mm", value: $watertightTopHeight, format: .number.precision(.fractionLength(1)))
                                .focused($focusedField, equals: .topHeight)
                                .frame(width: 46)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { onParameterCommit(.shrinkwrap) }
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        .help("Shape of the new top: 0 is flat, drag right to dome it outward, left to dish it inward.")
                    }
                    Text((openingDiagnosis?.openings.isEmpty ?? true)
                         ? "Heals the broken spots and closes small holes, leaving every other triangle exactly where it is."
                         : "Heals the broken spots and caps each opening with a new surface, leaving every original triangle where it is. Top shape: 0 = flat; right domes it outward, left dishes it inward.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if Self.showsOpeningRows(openingDiagnosis, method: .closeOpenings) {
                        openingRows(method: .closeOpenings)
                    }
                    if let unavailable {
                        Text(unavailable)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(openingDiagnosis == nil
                         ? "Measuring the surface…"
                         : (unavailable ?? "Fix in place can't repair this model's damage locally — use Rebuild as solid."))
                        .font(.caption2)
                        .foregroundStyle((openingDiagnosis == nil || openingDiagnosis?.isNothingToFix == true) ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .walls:
                if !hasOpenings {
                    Text(openingDiagnosis == nil
                         ? "Measuring the surface…"
                         : "Make walls is for open surfaces (a cup, a vase, a tube). This model has no opening — use Hollow above for a closed model.")
                        .font(.caption2)
                        .foregroundStyle(openingDiagnosis == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        Text("Wall")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $wallThickness, in: 0.5...10.0, onEditingChanged: { editing in
                            if !editing { onParameterCommit(.shrinkwrap) }
                        })
                            .frame(minWidth: 80)
                        TextField("mm", value: $wallThickness, format: .number.precision(.fractionLength(1)))
                            .focused($focusedField, equals: .wall)
                            .frame(width: 46)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { onParameterCommit(.shrinkwrap) }
                        Text("mm")
                            .foregroundStyle(.secondary)
                    }
                    .help("Wall thickness. The outside stays exactly as modelled; the wall grows inward.")
                    Text("Turns the open skin into a vessel with real walls: the outside stays exactly as modelled, the wall grows inward, and the rim stays open.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if Self.showsOpeningRows(openingDiagnosis, method: .walls) {
                        openingRows(method: .walls)
                    }
                    if let unavailable {
                        Text(unavailable)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .rebuild:
                HStack(spacing: 8) {
                    Text("Detail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $shrinkwrapDetail, in: 0.0...1.0, onEditingChanged: { editing in
                        if !editing { onParameterCommit(.shrinkwrap) }
                    })
                        .frame(minWidth: 80)
                    TextField("", value: $shrinkwrapDetail, format: .number.precision(.fractionLength(2)))
                        .focused($focusedField, equals: .detail)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { onParameterCommit(.shrinkwrap) }
                }
                Text("Rebuilds the whole surface as one closed solid (fills open vessels and internal cavities). For scans too broken to close. Higher detail = finer, slower.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let watertightReceipt {
                Text(watertightReceipt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tool header (name, ACTIVE, eye, Apply/Remove)

    @ViewBuilder
    private func toolHeader(tool: ModifyFormTool, symbol: String, disabledReason: String? = nil) -> some View {
        let under = tool == .shrinkwrap ? watertightUnder : nil
        let isActive = activeTool == tool || under != nil
        // A method known to change nothing can't be previewed or applied;
        // the hint says why. Remove always stays available.
        let blocked = disabledReason != nil && !isActive
        let isPreviewing = previewTool == tool
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 16, alignment: .center)
                Text(tool.label)
                    .fontWeight(.medium)
                if isActive {
                    Text(under.map { "ACTIVE · under \($0)" } ?? "ACTIVE")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                // Eye icon: view-only preview of this tool's result.
                Button {
                    onPreview(isPreviewing ? nil : tool)
                } label: {
                    Image(systemName: isPreviewing ? "eye.fill" : "eye")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(blocked && !isPreviewing)
                .help(blocked ? (disabledReason ?? "") : "See \(tool.label)'s result in the viewport without changing anything. Slicing keeps using the current form until you press Apply.")

                // Make Watertight runs under the active Hollow / Thicken (or
                // is itself active under a Hollow / Thicken about to apply).
                let watertightBelow = tool != .shrinkwrap && (watertightUnder != nil || activeTool == .shrinkwrap)
                if isActive {
                    Button("Remove", action: (tool == .shrinkwrap ? onRemoveWatertight : nil) ?? onRemove)
                        .controlSize(.small)
                        .help(under.map { "Stop using \(tool.label) — \($0) then applies to the imported mesh. Nothing was lost." }
                              ?? (tool != .shrinkwrap && watertightUnder != nil
                                  ? "Stop using \(tool.label) — slicing returns to the Make Watertight result. Nothing was lost."
                                  : "Stop using \(tool.label) — slicing returns to the imported mesh. Nothing was lost."))
                } else {
                    let applyHelp: String = {
                        if tool == .shrinkwrap, let top = activeTool, top != .shrinkwrap {
                            return "Run Make Watertight under \(top.label) — slicing uses \(top.label) on the fixed surface. Reversible — Remove takes Make Watertight out again."
                        }
                        if watertightBelow {
                            return "Slice and export the \(tool.appliedFormPhrase) form, built on the Make Watertight result. Reversible — Remove returns to the Make Watertight result."
                        }
                        return "Slice and export the \(tool.appliedFormPhrase) form. Reversible — Remove restores the original mesh."
                    }()
                    Button("Apply", action: { onApply(tool) })
                        .controlSize(.small)
                        .disabled(blocked)
                        .help(blocked ? (disabledReason ?? "") : applyHelp)
                }
            }
        }
    }
}
