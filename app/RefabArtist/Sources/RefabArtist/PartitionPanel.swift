import SwiftUI

/// Inspector controls for both Partition purposes. Purpose-specific values stay
/// in their own settings payloads so switching purposes never mutates the
/// neighboring workflow.
struct PartitionPanel: View {
    @Binding var settings: PartitionSettings
    @Binding var editIn3D: Bool
    let plan: PartitionMeshPlan?
    let modelBounds: Bounds3D?
    let undercutPlan: UndercutSplitPlan?
    let undercutPlanIsStale: Bool
    let undercutPlanningInProgress: Bool
    let undercutPlanningStartedAt: Date?
    let undercutPlanningPhase: String?
    let undercutEvaluatedCandidateCount: Int?
    @Binding var undercutEditIn3D: Bool
    @Binding var undercutFacePaintMode: UndercutFacePaintMode
    let selectedCutNodeID: PartitionCutNodeID?
    let selectedPieceRegionID: PartitionRegionID?
    let isolatedPieceRegionID: PartitionRegionID?
    let onPlanningModeChange: (UndercutPlanningMode) -> Void
    let onCutNodeSelect: (PartitionCutNodeID?) -> Void
    let onCutNodeLockToggle: (PartitionCutNodeID) -> Void
    let onCutNodeRotate: (PartitionCutNodeID, Vec3, Double) -> Void
    let onCutNodeDelete: (PartitionCutNodeID) -> Void
    let onPieceSelect: (PartitionRegionID?) -> Void
    let onPieceIsolationToggle: (PartitionRegionID) -> Void
    let onPiecePullLockToggle: (PartitionRegionID) -> Void
    let onAddCut: (PartitionRegionID, Vec3) -> Void

    @State private var advancedExpanded = false

    init(
        settings: Binding<PartitionSettings>,
        editIn3D: Binding<Bool>,
        plan: PartitionMeshPlan?,
        modelBounds: Bounds3D?,
        undercutPlan: UndercutSplitPlan? = nil,
        undercutPlanIsStale: Bool = false,
        undercutPlanningInProgress: Bool = false,
        undercutPlanningStartedAt: Date? = nil,
        undercutPlanningPhase: String? = nil,
        undercutEvaluatedCandidateCount: Int? = nil,
        undercutEditIn3D: Binding<Bool> = .constant(false),
        undercutFacePaintMode: Binding<UndercutFacePaintMode> = .constant(.none),
        selectedCutNodeID: PartitionCutNodeID? = nil,
        selectedPieceRegionID: PartitionRegionID? = nil,
        isolatedPieceRegionID: PartitionRegionID? = nil,
        onPlanningModeChange: @escaping (UndercutPlanningMode) -> Void = { _ in },
        onCutNodeSelect: @escaping (PartitionCutNodeID?) -> Void = { _ in },
        onCutNodeLockToggle: @escaping (PartitionCutNodeID) -> Void = { _ in },
        onCutNodeRotate: @escaping (PartitionCutNodeID, Vec3, Double) -> Void = { _, _, _ in },
        onCutNodeDelete: @escaping (PartitionCutNodeID) -> Void = { _ in },
        onPieceSelect: @escaping (PartitionRegionID?) -> Void = { _ in },
        onPieceIsolationToggle: @escaping (PartitionRegionID) -> Void = { _ in },
        onPiecePullLockToggle: @escaping (PartitionRegionID) -> Void = { _ in },
        onAddCut: @escaping (PartitionRegionID, Vec3) -> Void = { _, _ in }
    ) {
        _settings = settings
        _editIn3D = editIn3D
        self.plan = plan
        self.modelBounds = modelBounds
        self.undercutPlan = undercutPlan
        self.undercutPlanIsStale = undercutPlanIsStale
        self.undercutPlanningInProgress = undercutPlanningInProgress
        self.undercutPlanningStartedAt = undercutPlanningStartedAt
        self.undercutPlanningPhase = undercutPlanningPhase
        self.undercutEvaluatedCandidateCount = undercutEvaluatedCandidateCount
        _undercutEditIn3D = undercutEditIn3D
        _undercutFacePaintMode = undercutFacePaintMode
        self.selectedCutNodeID = selectedCutNodeID
        self.selectedPieceRegionID = selectedPieceRegionID
        self.isolatedPieceRegionID = isolatedPieceRegionID
        self.onPlanningModeChange = onPlanningModeChange
        self.onCutNodeSelect = onCutNodeSelect
        self.onCutNodeLockToggle = onCutNodeLockToggle
        self.onCutNodeRotate = onCutNodeRotate
        self.onCutNodeDelete = onCutNodeDelete
        self.onPieceSelect = onPieceSelect
        self.onPieceIsolationToggle = onPieceIsolationToggle
        self.onPiecePullLockToggle = onPiecePullLockToggle
        self.onAddCut = onAddCut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            purposeSection
            Divider()
            switch settings.purpose {
            case .fitPrinter:
                fitPrinterSections
            case .splitByUndercuts:
                undercutSections
            }
        }
    }

    private var purposeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Purpose")
            Picker("Purpose", selection: $settings.purpose) {
                ForEach(PartitionPurpose.allCases) { purpose in
                    Text(purpose.label).tag(purpose)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(undercutPlanningInProgress)
            .help(undercutPlanningInProgress ? "Planning is in progress. Cancel before switching purposes." : "Choose the partition objective.")
            Text(settings.purpose == .fitPrinter
                ? "Cut the model into pieces that fit the selected build volume."
                : "Measure release along stored pull axes and split only where the search finds useful planar seams.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fitPrinterSections: some View {
        buildVolumeSection
        Divider()
        splittingSection
        Divider()
        fitPrinterKeysSection
        if let plan {
            Divider()
            fitCheckSection(plan)
        }
        Divider()
        fitPrinterOutputSection
    }

    @ViewBuilder private var undercutSections: some View {
        undercutReleaseSection
            .disabled(undercutPlanningInProgress)
            .help(undercutPlanningInProgress ? "Planning is in progress." : "Configure release measurement.")
        Divider()
        undercutDecompositionSection
            .disabled(undercutPlanningInProgress)
            .help(undercutPlanningInProgress ? "Planning is in progress." : "Configure the decomposition search.")
        Divider()
        undercutStatusSection
        if undercutPlan != nil {
            Divider()
            undercutEditingSection
        }
        Divider()
        undercutOutputSection
        Divider()
        undercutAdvancedSection
            .disabled(undercutPlanningInProgress)
            .help(undercutPlanningInProgress ? "Planning is in progress." : "Configure advanced search inputs.")
    }

    // MARK: - Fit Printer

    private var buildVolumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Build volume")
            Picker("Printer", selection: $settings.printerPreset) {
                ForEach(PartitionPrinterPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .onChange(of: settings.printerPreset) { _, newValue in
                if let volume = newValue.volume { settings.buildVolume = volume }
            }
            HStack(spacing: 6) {
                numberField("W", value: $settings.buildVolume.width)
                numberField("D", value: $settings.buildVolume.depth)
                numberField("H", value: $settings.buildVolume.height)
            }
            HStack {
                Text("Bed margin").font(.caption).foregroundStyle(.secondary)
                Spacer()
                compactNumberField($settings.bedMargin)
                Text("mm").font(.caption).foregroundStyle(.tertiary)
            }
            if let dims = MeshScaler.dimensions(for: modelBounds) {
                Text("Model: \(fmt(dims.width)) × \(fmt(dims.depth)) × \(fmt(dims.height)) mm")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var splittingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Splitting")
            Picker("Mode", selection: $settings.mode) {
                ForEach(PartitionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Picker("Strategy", selection: $settings.autoStrategy) {
                ForEach(PartitionAutoStrategy.allCases) { strategy in
                    Text(strategy.label).tag(strategy)
                }
            }
            .labelsHidden()

            switch settings.mode {
            case .autoFit:
                if let summary = autoGridSummary {
                    HStack {
                        Text("Grid").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(summary).font(.caption).monospacedDigit()
                    }
                }
            case .manual:
                manualPlanesEditor
            }
        }
    }

    private var manualPlanesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $editIn3D) {
                Text("Edit cuts in 3D — drag the handles").font(.caption)
            }
            .toggleStyle(.switch)
            .disabled(settings.manualPlanes.isEmpty)
            .help(settings.manualPlanes.isEmpty ? "Add at least one cut plane first." : "Drag cut handles in the 3D viewport.")
            HStack(spacing: 6) {
                Button("Add X") { addPlane(axis: 0) }
                Button("Add Y") { addPlane(axis: 1) }
                Button("Add Z") { addPlane(axis: 2) }
            }
            .font(.caption)
            .disabled(modelBounds == nil)
            .help(modelBounds == nil ? "Load a model first." : "Add an axis-aligned cut through the model center.")
            HStack(spacing: 6) {
                Button("From Auto-fit") { populateFromAutoFit() }
                    .disabled(modelBounds == nil)
                    .help(modelBounds == nil ? "Load a model first." : "Seed editable planes from the current build volume.")
                if !settings.manualPlanes.isEmpty {
                    Button("Clear") { settings.manualPlanes.removeAll() }
                }
            }
            .font(.caption)
            if settings.manualPlanes.isEmpty {
                Text("Add cut planes, or seed them from Auto-fit, then tune positions.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach($settings.manualPlanes) { $plane in
                    HStack(spacing: 6) {
                        Text(axisLabel(plane)).font(.caption).frame(width: 48, alignment: .leading)
                        compactNumberField($plane.offset)
                        Button { tiltPlane(plane, degrees: -5) } label: { Image(systemName: "rotate.left") }
                            .buttonStyle(.borderless).help("Tilt −5°")
                        Button { tiltPlane(plane, degrees: 5) } label: { Image(systemName: "rotate.right") }
                            .buttonStyle(.borderless).help("Tilt +5°")
                        Spacer()
                        Button {
                            settings.manualPlanes.removeAll { $0.id == plane.id }
                        } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this plane")
                    }
                    .disabled(modelBounds == nil)
                }
            }
        }
    }

    private var fitPrinterKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Seams & keys")
            Picker("Key", selection: $settings.key.type) {
                ForEach(PartitionKeyType.userVisibleOptions) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            if settings.key.type != .none {
                fitPrinterPinFields
            }
        }
    }

    private var fitPrinterPinFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                labeledNumber("Key size", $settings.key.pinDiameter)
                labeledNumber("Length", $settings.key.pinLength)
            }
            HStack(spacing: 6) {
                labeledNumber("Tolerance", $settings.key.tolerance)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per seam").font(.caption2).foregroundStyle(.tertiary)
                    Stepper(value: $settings.key.pinsPerSeam, in: 1...6) {
                        Text("\(settings.key.pinsPerSeam)").monospacedDigit()
                    }
                }
            }
            HStack {
                Text("Edge margin").font(.caption).foregroundStyle(.secondary)
                Spacer()
                compactNumberField($settings.key.edgeMargin)
                Text("mm").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func fitCheckSection(_ plan: PartitionMeshPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Fit check")
            HStack {
                Label("\(plan.pieces.count) pieces", systemImage: "square.split.2x2")
                    .font(.caption)
                Spacer()
                if plan.oversizedCount == 0 {
                    Label("all fit", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                } else {
                    Label("\(plan.oversizedCount) too big", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var fitPrinterOutputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Output")
            Picker("Packaging", selection: $settings.packaging) {
                ForEach(PartitionPackaging.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            Picker("Naming", selection: $settings.naming) {
                ForEach(PartitionNaming.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            Toggle(isOn: $settings.includeAssemblyMap) {
                Text("Include assembly map").font(.caption)
            }
            explodeControl
        }
    }

    // MARK: - Split by Undercuts

    private var undercutReleaseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Release")
            Picker("Pull policy", selection: globalPullPolicyBinding) {
                Text("Automatic").tag(UndercutGlobalPullPolicy.automatic)
                Text("Fixed").tag(UndercutGlobalPullPolicy.fixed)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: globalPullPolicy) { _, policy in
                if policy == .fixed, currentUndercutSettings.fixedPullDirection == nil {
                    setUndercut(\.fixedPullDirection, Vec3(x: 0, y: 0, z: 1))
                }
            }

            if globalPullPolicy == .fixed {
                UndercutPullAxisRing(direction: fixedPullDirectionBinding)
                directionFields(fixedPullDirectionBinding)
            } else if currentUndercutSettings.pullPolicy == .perPieceLocks {
                perPiecePullLocks
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Undercut tolerance").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    compactNumberField(undercutBinding(\.undercutToleranceMM))
                    Text("mm").font(.caption2).foregroundStyle(.tertiary)
                }
                Slider(value: undercutBinding(\.undercutToleranceMM), in: 0...10, step: 0.1)
                Text("Flexible silicone often releases shallow hooks; 2 mm is the starting point, and 0 mm uses the same measurement path.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var perPiecePullLocks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let undercutPlan, !undercutPlan.pieces.isEmpty {
                ForEach(undercutPlan.pieces.sorted { $0.regionID < $1.regionID }, id: \.regionID) { piece in
                    HStack {
                        Text(shortRegionName(piece.regionID))
                        Spacer()
                        Text(axisText(currentUndercutSettings.lockedPullDirections[piece.regionID] ?? piece.pullAxis))
                            .monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                Text("Use the lock buttons in Result editing to add or remove a measured per-piece pull axis.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Per-piece pull locks are retained, but their referenced result is not loaded.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var undercutDecompositionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Decomposition")
            if manualEditingAvailable {
                Picker("Planning", selection: undercutPlanningModeBinding) {
                    Text("Automatic").tag(UndercutPlanningMode.automatic)
                    Text("Manual").tag(UndercutPlanningMode.manual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .help("Manual mode persists the current scoped cut tree; generated locks adopt it in one undoable settings change.")
            } else {
                HStack(spacing: 6) {
                    Text("Automatic")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Button("Manual") {}
                        .disabled(true)
                        .help("Analyze the model before adopting a cut tree for manual editing.")
                }
                Text("Manual editing becomes available after the first measured result.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if currentUndercutSettings.planningMode == .manual,
               currentUndercutSettings.authoredCutTree == nil {
                Text("No authored cut tree is stored. Adopt a generated result or add a scoped cut before re-analyzing.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let envelope = currentUndercutSettings.authoredCutTree,
               envelope.isQuarantined {
                Label("Authored tree quarantined", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                ForEach(envelope.diagnostics, id: \.self) { diagnostic in
                    Text(diagnostic).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Delete retained authored tree", role: .destructive) {
                    deleteQuarantinedUndercutTree()
                }
                .font(.caption)
                .help("Explicitly removes the quarantined raw payload and returns planning to Automatic. Other Partition settings are unchanged.")
            }
            HStack {
                Text("Max pieces").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: undercutBinding(\.maxPieces), in: 1...32) {
                    Text("\(currentUndercutSettings.maxPieces)").monospacedDigit()
                }
            }
            Picker("Priority", selection: undercutBinding(\.priority)) {
                Text("Fewer pieces").tag(UndercutSplitPriority.fewerPieces)
                Text("Balanced").tag(UndercutSplitPriority.balanced)
                Text("Cleaner seams").tag(UndercutSplitPriority.cleanerSeams)
            }
            .labelsHidden()
        }
    }

    private var undercutStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Status")
            if undercutPlanningInProgress {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(undercutPlanningPhase ?? "Analyzing directions and scoped cuts")
                    Spacer()
                    planningElapsedLabel
                }
                .font(.caption).foregroundStyle(.secondary)
                if let count = undercutEvaluatedCandidateCount {
                    Text("\(count) candidate\(count == 1 ? "" : "s") evaluated")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("Candidate count is awaiting a planner progress update.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let undercutPlan {
                if undercutPlanIsStale {
                    Label(UndercutSplitUIWording.staleAdvisory, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(undercutPlan.statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusColor(for: undercutPlan))
                    .fixedSize(horizontal: false, vertical: true)
                resultSummaryRow(undercutPlan)

                if undercutPlan.measurementAttached,
                   let offender = worstOffender(in: undercutPlan) {
                    Text("Worst offender: \(shortRegionName(offender.pieceID)), \(measurement(offender.depthMM)) mm deep over \(measurement(offender.areaMM2)) mm².")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Piece measurements") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(undercutPlan.pieces.sorted { $0.regionID < $1.regionID }, id: \.regionID) { piece in
                            pieceMeasurementRow(piece)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                ForEach(undercutPlan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if undercutPlanningInProgress {
                Text("No previous measured result is loaded. Cancel keeps the inspector ready for another run.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No measured result yet. Use Analyze & Split below to evaluate the current source and settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pieceMeasurementRow(_ piece: UndercutSplitPiece) -> some View {
        let measurementResult = piece.measurement
        let regionCount = measurementResult?.regions.filter {
            $0.areaMM2 >= currentUndercutSettings.minRegionAreaMM2
        }.count ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(shortRegionName(piece.regionID)).fontWeight(.medium)
                Spacer()
                Text(axisText(piece.pullAxis)).monospacedDigit()
            }
            if let measurementResult {
                HStack {
                    Text("Worst \(measurement(measurementResult.worstDepthMM)) mm · \(regionCount) measured region\(regionCount == 1 ? "" : "s")")
                    Spacer()
                }
                .foregroundStyle(.secondary)
            } else {
                Text("Measurement unavailable").foregroundStyle(.orange)
            }
            Text(measurementResult.map { "Measured at \(measurement($0.effectiveResolutionMM)) mm grid" } ?? "Measurement unavailable")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var planningElapsedLabel: some View {
        if let started = undercutPlanningStartedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("\(max(0, Int(context.date.timeIntervalSince(started)))) s")
                    .monospacedDigit()
            }
        } else {
            Text("Starting…")
        }
    }

    private var undercutEditingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Result editing")
            if let tree = currentDisplayedCutTree {
                Toggle("Edit cut planes in 3D", isOn: $undercutEditIn3D)
                    .font(.caption)
                    .disabled(tree.nodes.isEmpty)
                    .help(tree.nodes.isEmpty
                        ? "This measured result has no cut planes to edit."
                        : "Select a cut surface or handle, then drag to move it along its normal.")

                VStack(alignment: .leading, spacing: 5) {
                    Text("Source-face paint").font(.caption).foregroundStyle(.secondary)
                    Picker("Source-face paint", selection: $undercutFacePaintMode) {
                        Text("Off").tag(UndercutFacePaintMode.none)
                        Text("No cut").tag(UndercutFacePaintMode.noCut)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: undercutFacePaintMode) { _, mode in
                        if mode != .none { undercutEditIn3D = false }
                    }
                    .help("Choose a paint rule, then click source faces in the 3D viewport. Clicking an already-painted face removes that rule.")
                    Text("Preferred-seam paint is unavailable until the planner's weighted seam cost is active.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    HStack {
                        Text("\(currentUndercutSettings.faceConstraints.noCutSourceFaceIDs.count) no-cut")
                        Text("·")
                        Text("\(currentUndercutSettings.faceConstraints.preferredSeamFaces.count) preferred")
                        Spacer()
                        if !currentUndercutSettings.faceConstraints.noCutSourceFaceIDs.isEmpty
                            || !currentUndercutSettings.faceConstraints.preferredSeamFaces.isEmpty {
                            Button("Clear paint") { clearUndercutFacePaint() }
                                .buttonStyle(.borderless)
                                .help("Remove every no-cut and preferred-seam source-face rule in one undoable settings change.")
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }

                if tree.nodes.isEmpty {
                    Text("The current result is one piece, so there are no cut nodes to edit.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(tree.nodes.enumerated()), id: \.element.id) { index, node in
                            HStack(spacing: 6) {
                                Button {
                                    onCutNodeSelect(selectedCutNodeID == node.id ? nil : node.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: selectedCutNodeID == node.id ? "checkmark.circle.fill" : "circle")
                                        Text("Cut \(index + 1)")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help("Select this cut by its stable node identity.")
                                Spacer()
                                if node.isLocked {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                        .help("This cut is locked in the authored tree.")
                                }
                                Text(shortCutName(node.id))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if let selectedCutNodeID,
                   let selectedNode = tree.nodes.first(where: { $0.id == selectedCutNodeID }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Button(selectedNode.isLocked ? "Unlock cut" : "Lock cut") {
                                onCutNodeLockToggle(selectedCutNodeID)
                            }
                            .help(currentUndercutSettings.planningMode == .automatic
                                ? "Adopts the generated tree into Manual and changes the lock in one undoable settings transaction."
                                : "Changes this node's authored lock.")

                            Menu("Rotate 5°") {
                                rotationButton("X +5°", nodeID: selectedCutNodeID, axis: Vec3(x: 1, y: 0, z: 0), degrees: 5)
                                rotationButton("X −5°", nodeID: selectedCutNodeID, axis: Vec3(x: 1, y: 0, z: 0), degrees: -5)
                                rotationButton("Y +5°", nodeID: selectedCutNodeID, axis: Vec3(x: 0, y: 1, z: 0), degrees: 5)
                                rotationButton("Y −5°", nodeID: selectedCutNodeID, axis: Vec3(x: 0, y: 1, z: 0), degrees: -5)
                                rotationButton("Z +5°", nodeID: selectedCutNodeID, axis: Vec3(x: 0, y: 0, z: 1), degrees: 5)
                                rotationButton("Z −5°", nodeID: selectedCutNodeID, axis: Vec3(x: 0, y: 0, z: 1), degrees: -5)
                            }
                            .help("Rotates the selected canonical plane about its displayed center and adopts the tree into Manual.")

                            Button("Delete", role: .destructive) {
                                onCutNodeDelete(selectedCutNodeID)
                            }
                            .help("Requests confirmation, then collapses this cut's subtree. Face paint is retained and descendant pull locks are reported as dropped.")
                        }
                        .font(.caption)
                        Text("Plane \(axisText(selectedNode.plane.normal)) · offset \(measurement(selectedNode.plane.offset)) mm")
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }

            if let undercutPlan {
                Divider()
                Text("Pieces").font(.caption).fontWeight(.medium)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(undercutPlan.pieces.sorted { $0.regionID < $1.regionID }, id: \.regionID) { piece in
                        HStack(spacing: 6) {
                            Button {
                                onPieceSelect(selectedPieceRegionID == piece.regionID ? nil : piece.regionID)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: selectedPieceRegionID == piece.regionID ? "checkmark.circle.fill" : "circle")
                                    Text(shortRegionName(piece.regionID))
                                }
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button(isolatedPieceRegionID == piece.regionID ? "Show all" : "Isolate") {
                                onPieceIsolationToggle(piece.regionID)
                            }
                            .buttonStyle(.borderless)
                            .help(isolatedPieceRegionID == piece.regionID
                                ? "Show every measured piece."
                                : "Show only this piece, its measured regions, and its pull arrow.")
                            Button {
                                onPiecePullLockToggle(piece.regionID)
                            } label: {
                                Image(systemName: currentUndercutSettings.lockedPullDirections[piece.regionID] == nil
                                    ? "arrow.up.and.down"
                                    : "lock.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(currentUndercutSettings.lockedPullDirections[piece.regionID] == nil
                                ? "Lock pull axis for \(shortRegionName(piece.regionID))"
                                : "Unlock pull axis for \(shortRegionName(piece.regionID))")
                            .help(currentUndercutSettings.lockedPullDirections[piece.regionID] == nil
                                ? "Lock this measured pull axis; generated trees are adopted into Manual in one undoable settings transaction."
                                : "Remove this piece's pull-axis lock.")
                        }
                        .font(.caption)
                    }
                }

                if let selectedPieceRegionID {
                    HStack(spacing: 6) {
                        Text("Add scoped cut").font(.caption).foregroundStyle(.secondary)
                        Button("X") { onAddCut(selectedPieceRegionID, Vec3(x: 1, y: 0, z: 0)) }
                        Button("Y") { onAddCut(selectedPieceRegionID, Vec3(x: 0, y: 1, z: 0)) }
                        Button("Z") { onAddCut(selectedPieceRegionID, Vec3(x: 0, y: 0, z: 1)) }
                    }
                    .font(.caption)
                    .disabled(!canAddCut(to: selectedPieceRegionID))
                    .help(canAddCut(to: selectedPieceRegionID)
                        ? "Adds one axis-aligned plane through this measured piece's center and adopts the tree into Manual."
                        : "Re-analyze first, or increase Max pieces, before adding another scoped cut here.")
                }
            }

            Text("Authored edits preserve the last pieces for inspection and export, mark their measurements stale, and take effect when Analyze & Split runs again. Project-level Undo restores the entire adoption or edit transaction.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(undercutPlanningInProgress)
        .help(undercutPlanningInProgress ? "Planning is in progress." : "Edit the scoped cut tree and piece inspection state.")
    }

    @ViewBuilder
    private func rotationButton(
        _ title: String,
        nodeID: PartitionCutNodeID,
        axis: Vec3,
        degrees: Double
    ) -> some View {
        Button(title) { onCutNodeRotate(nodeID, axis, degrees) }
    }

    private var currentDisplayedCutTree: PartitionCutTree? {
        let split = currentUndercutSettings
        if split.planningMode == .manual, let tree = split.authoredCutTree?.typedTree {
            return tree
        }
        return undercutPlan?.cutTree
    }

    private var manualEditingAvailable: Bool {
        currentUndercutSettings.authoredCutTree?.isQuarantined != true
            && currentDisplayedCutTree != nil
    }

    private var undercutPlanningModeBinding: Binding<UndercutPlanningMode> {
        Binding(
            get: { currentUndercutSettings.planningMode },
            set: { mode in
                guard mode == .automatic || manualEditingAvailable else { return }
                onPlanningModeChange(mode)
            }
        )
    }

    private func canAddCut(to regionID: PartitionRegionID) -> Bool {
        guard let tree = currentDisplayedCutTree else { return false }
        return tree.allRegionIDs.contains(regionID)
            && !tree.nodes.contains(where: { $0.targetRegionID == regionID })
            && tree.nodes.count + 1 < currentUndercutSettings.maxPieces
    }

    private func clearUndercutFacePaint() {
        var split = currentUndercutSettings
        split.faceConstraints = .empty
        settings.undercutSplit = split.sanitized
    }

    private func deleteQuarantinedUndercutTree() {
        var split = currentUndercutSettings
        guard split.authoredCutTree?.isQuarantined == true else { return }
        split.authoredCutTree = nil
        split.planningMode = .automatic
        settings.undercutSplit = split.sanitized
    }

    private func shortCutName(_ id: PartitionCutNodeID) -> String {
        "…\(id.rawValue.suffix(6))"
    }

    private var undercutOutputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Output")
            Text("Choose STL or OBJ and export in the Output section below. Any produced pieces remain available even when measurements exceed the selected tolerance.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if undercutPlan?.status == .splitExceedsTolerance {
                Label("Export includes measurement warnings in the report.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            explodeControl
        }
    }

    private var undercutAdvancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Search quality", selection: undercutBinding(\.quality)) {
                    Text("Quick").tag(UndercutSearchQuality.quick)
                    Text("Standard").tag(UndercutSearchQuality.standard)
                    Text("Thorough").tag(UndercutSearchQuality.thorough)
                }
                .pickerStyle(.menu)

                labeledNumber("Minimum measured region area (mm²)", undercutBinding(\.minRegionAreaMM2))
                labeledNumber("Draft advisory (degrees)", undercutBinding(\.draftAdvisoryDegrees))
                labeledNumber("Minimum piece volume (mm³)", undercutBinding(\.minimumPieceVolumeMM3))
                labeledNumber("Minimum piece fraction", undercutBinding(\.minimumPieceVolumeFraction))
                labeledNumber("Minimum seam area (mm²)", undercutBinding(\.minimumSeamAreaMM2))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Deterministic seed").font(.caption2).foregroundStyle(.tertiary)
                    TextField("Seed", value: undercutBinding(\.seed), format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Tolerance policy").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(currentUndercutSettings.tolerancePolicyVersion)")
                        .font(.caption).monospacedDigit()
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
    }

    private var explodeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Explode preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((settings.explodePreview * 100).rounded()))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            Slider(value: $settings.explodePreview, in: 0...1)
        }
    }

    // MARK: - Purpose-specific bindings

    private var currentUndercutSettings: UndercutSplitSettings {
        settings.undercutSplit?.sanitized ?? .defaultValue
    }

    private func undercutBinding<Value>(_ keyPath: WritableKeyPath<UndercutSplitSettings, Value>) -> Binding<Value> {
        Binding(
            get: { currentUndercutSettings[keyPath: keyPath] },
            set: { setUndercut(keyPath, $0) }
        )
    }

    private func setUndercut<Value>(_ keyPath: WritableKeyPath<UndercutSplitSettings, Value>, _ value: Value) {
        var next = currentUndercutSettings
        next[keyPath: keyPath] = value
        settings.undercutSplit = next.sanitized
    }

    private enum UndercutGlobalPullPolicy: Hashable {
        case automatic
        case fixed
    }

    private var globalPullPolicy: UndercutGlobalPullPolicy {
        currentUndercutSettings.pullPolicy == .fixed ? .fixed : .automatic
    }

    private var globalPullPolicyBinding: Binding<UndercutGlobalPullPolicy> {
        Binding(
            get: { globalPullPolicy },
            set: { policy in
                setUndercut(\.pullPolicy, policy == .fixed ? .fixed : .automatic)
            }
        )
    }

    private var fixedPullDirectionBinding: Binding<Vec3> {
        Binding(
            get: { normalized(currentUndercutSettings.fixedPullDirection ?? Vec3(x: 0, y: 0, z: 1)) },
            set: { setUndercut(\.fixedPullDirection, normalized($0)) }
        )
    }

    private func directionFields(_ direction: Binding<Vec3>) -> some View {
        HStack(spacing: 6) {
            directionComponentField("X", direction: direction, keyPath: \.x)
            directionComponentField("Y", direction: direction, keyPath: \.y)
            directionComponentField("Z", direction: direction, keyPath: \.z)
        }
    }

    private func directionComponentField(
        _ label: String,
        direction: Binding<Vec3>,
        keyPath: WritableKeyPath<Vec3, Double>
    ) -> some View {
        numberField(label, value: Binding(
            get: { direction.wrappedValue[keyPath: keyPath] },
            set: { value in
                var next = direction.wrappedValue
                next[keyPath: keyPath] = value
                direction.wrappedValue = normalized(next)
            }
        ))
    }

    // MARK: - Helpers

    private var autoGridSummary: String? {
        guard let bounds = modelBounds else { return nil }
        let planes = PartitionPlanner.autoFitPlanes(bounds: bounds, settings: settings)
        var cuts = [0, 0, 0]
        for plane in planes {
            if let axis = plane.axisAligned { cuts[axis] += 1 }
        }
        let pieces = (cuts[0] + 1) * (cuts[1] + 1) * (cuts[2] + 1)
        return "\(cuts[0] + 1) × \(cuts[1] + 1) × \(cuts[2] + 1) = \(pieces) parts"
    }

    private func addPlane(axis: Int) {
        guard let b = modelBounds else { return }
        let center = [(b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2]
        let normals = [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1)]
        settings.manualPlanes.append(PartitionPlane(normal: normals[axis], offset: center[axis], isManual: true))
    }

    private func populateFromAutoFit() {
        guard let b = modelBounds else { return }
        settings.manualPlanes = PartitionPlanner.autoFitPlanes(bounds: b, settings: settings)
    }

    private func tiltPlane(_ plane: PartitionPlane, degrees: Double) {
        guard let b = modelBounds,
              let i = settings.manualPlanes.firstIndex(where: { $0.id == plane.id }) else { return }
        let pivot = PartitionPlaneEditing.handle(for: plane, bounds: b)
        settings.manualPlanes[i] = PartitionPlaneEditing.tilted(plane, degrees: degrees, pivot: pivot)
    }

    private func axisLabel(_ plane: PartitionPlane) -> String {
        switch plane.axisAligned {
        case 0: return "X cut"
        case 1: return "Y cut"
        case 2: return "Z cut"
        default: return "Tilted"
        }
    }

    private func statusColor(for plan: UndercutSplitPlan) -> Color {
        if undercutPlanIsStale { return .orange }
        guard plan.fullResolutionFinalized, plan.measurementAttached else { return .secondary }
        switch plan.status {
        case .wholeModelWithinTolerance, .splitWithinTolerance: return .green
        case .splitExceedsTolerance: return .orange
        case .analysisError: return .red
        }
    }

    @ViewBuilder
    private func resultSummaryRow(_ plan: UndercutSplitPlan) -> some View {
        HStack {
            Label("\(plan.pieces.count) piece\(plan.pieces.count == 1 ? "" : "s")", systemImage: "square.split.2x2")
            Spacer()
            if plan.measurementAttached {
                Text("Worst \(measurement(plan.worstMeasuredDepthMM)) mm")
                    .monospacedDigit()
            } else {
                Text("Measurement unavailable").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private struct WorstOffender {
        var pieceID: PartitionRegionID
        var depthMM: Double
        var areaMM2: Double
    }

    private func worstOffender(in plan: UndercutSplitPlan) -> WorstOffender? {
        let minimumArea = currentUndercutSettings.minRegionAreaMM2
        return plan.pieces.compactMap { piece -> WorstOffender? in
            guard let region = piece.attributedRegions
                .filter({ $0.areaMM2 >= minimumArea })
                .max(by: { $0.depthMM < $1.depthMM }) else { return nil }
            return WorstOffender(
                pieceID: piece.regionID,
                depthMM: region.depthMM,
                areaMM2: region.areaMM2
            )
        }.max { lhs, rhs in
            if lhs.depthMM != rhs.depthMM { return lhs.depthMM < rhs.depthMM }
            if lhs.areaMM2 != rhs.areaMM2 { return lhs.areaMM2 < rhs.areaMM2 }
            return lhs.pieceID < rhs.pieceID
        }
    }

    private func normalized(_ value: Vec3) -> Vec3 {
        let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        guard length.isFinite, length > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private func axisText(_ value: Vec3) -> String {
        String(format: "(%.3g, %.3g, %.3g)", value.x, value.y, value.z)
    }

    private func shortRegionName(_ id: PartitionRegionID) -> String {
        let suffix = id.rawValue.suffix(6)
        return "Piece …\(suffix)"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption).fontWeight(.medium)
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledNumber(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func compactNumberField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func measurement(_ value: Double) -> String {
        String(format: "%.3g", value)
    }
}

/// Compact hemisphere control for the undirected pull axis. The point edits X
/// and Y while Z is reconstructed on the canonical hemisphere; numeric fields
/// beside it remain available for exact entry.
private struct UndercutPullAxisRing: View {
    @Binding var direction: Vec3

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let radius = max(1, side / 2 - 7)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.06))
                    Circle()
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                    Path { path in
                        path.move(to: CGPoint(x: center.x - radius, y: center.y))
                        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                        path.move(to: CGPoint(x: center.x, y: center.y - radius))
                        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    }
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .position(
                            x: center.x + CGFloat(direction.x) * radius,
                            y: center.y - CGFloat(direction.y) * radius
                        )
                }
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        var x = Double((drag.location.x - center.x) / radius)
                        var y = Double((center.y - drag.location.y) / radius)
                        let projectedLength = sqrt(x * x + y * y)
                        if projectedLength > 1 {
                            x /= projectedLength
                            y /= projectedLength
                        }
                        let z = sqrt(max(0, 1 - x * x - y * y))
                        direction = Vec3(x: x, y: y, z: z)
                    }
                )
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pull axis")
                    .font(.caption).fontWeight(.medium)
                Text("Drag the point, or enter an exact unit vector below.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fixed pull-axis direction ring")
    }
}
