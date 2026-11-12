import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model: MeshSummary?
    @State private var isLoadingModel = false
    @State private var errorMessage: String?
    @State private var exportMessage: String?
    @State private var lastModelLoadFailure: String?
    @State private var lastExportFailure: String?
    @State private var constructionMode: ConstructionMode = .stacked
    @State private var hasSelectedConstructionTechnique = false
    @State private var isTechniqueChooserExpanded = false
    /// Settings → "Show experimental modes". Only changes which modes the
    /// technique chooser offers; never the current mode.
    @AppStorage(AppSettingsKey.experimentalFeatures) private var experimentalFeaturesEnabled = false
    @State private var sliceAxis: SliceAxis = .z
    /// Slice Direction fine-tune (degrees) about the primary axis's two
    /// perpendicular axes. Additive to the X/Y/Z buttons, never replacing
    /// them (owner call, 2026-06-11).
    @State private var sliceTiltFirst = 0.0
    @State private var sliceTiltSecond = 0.0
    /// In-flight slider values during a drag: the viewport previews these as
    /// pure entity transforms; the authoritative state (and the re-bake /
    /// re-slice it triggers) commits once on drag end.
    @State private var liveModelRotationPreview: Vec3?
    @State private var liveSliceTiltPreview: Vec2?
    /// Slice Direction mode: protractor rings in the viewport.
    @State private var sliceDirectionAdjustMode = false
    @State private var secondarySliceAxis: SliceAxis = .x
    @State private var materialThickness = 3.0
    @State private var threeDSliceDepth = 10.0
    @State private var slotClearance = 0.0
    @State private var notchWidthOverrideEnabled = false
    @State private var notchWidth = 3.0
    // Default 45°, range 0–90. HeadlessExportCommand uses --slot-angle
    // (default 0) instead, so headless exports stay stable — do NOT change
    // the headless default.
    @State private var slotAngleDegrees = 45.0
    @State private var radialSliceCount = 6
    @State private var radialFirstAxisByDistance = false
    @State private var radialFirstAxisCount = 10
    @State private var radialFirstAxisSpacing = 15.0
    @State private var radialNotchFactor = 0.1
    @State private var radialReliefType: RadialReliefType = .square
    // Manufacturing Settings — kerf mirror and tool diameter.
    // Defaults: kerf=0.01″=0.254mm, toolDiameter=0.
    @State private var materialKerf = 0.254
    /// Tool Dia.: the one tool diameter. It sizes the slot relief of every
    /// mode that cuts it (Interlocked Slot relief, Radial Relief Type).
    @State private var materialToolDiameter = 0.0
    @State private var curvePrimaryAxis: SliceAxis = .y
    @State private var curveFirstAxisCount = 7
    @State private var curveSliceCount = 12
    @State private var curveAmplitude = 10.0
    @State private var materialPreset: MaterialPreset = .custom
    /// Slice-solid render style: Cardboard / Plywood / Plastic. Persisted in
    /// the project document as `sliceSolidRenderStyle`.
    @State private var sliceSolidRenderStyle: SliceSolidRenderStyle = .cardboard
    @State private var slotReliefEnabled = false
    @State private var dowelsEnabled = false
    @State private var dowelDiameter = DowelShape.round.defaultDiameter
    @State private var dowelInset = 6.0
    @State private var exportFormat: ExportFormat = .dxf
    @State private var exportPartSpacing = ExportLayoutSettings.defaultValue.partSpacing
    @State private var exportPageMargin = ExportLayoutSettings.defaultValue.pageMargin
    @State private var exportSheetWidth = ExportLayoutSettings.defaultValue.sheetWidth
    @State private var exportSheetHeight = ExportLayoutSettings.defaultValue.sheetHeight
    @State private var viewportCamera = ViewportCameraState()
    @State private var viewportMode: ViewportMode = .model3D
    @State private var viewportPreviewMode: ViewportPreviewMode = .model
    @State private var isSidebarVisible = true
    @State private var selectedAssemblyStepID: AssemblyStep.ID?
    @State private var modelScale = Vec3(x: 1, y: 1, z: 1)
    @State private var modelRotationDegrees = Vec3(x: 0, y: 0, z: 0)
    @State private var importUnit: ImportUnitPreset = .millimeters
    /// Per-import up-axis selection. Y is the default.
    @State private var importUpAxis: ImportUpAxis = .y
    @State private var customSliceDistributionEnabled = false
    @State private var customSliceCount = 12
    // NEO-103: Slice Distribution method (Automatic / By Count / By Distance / Custom).
    // Starts as .automatic; migrates from legacy customSliceDistributionEnabled.
    @State private var sliceDistributionMethod: SliceDistributionMethod = .automatic
    // By Distance: spacing in mm between slices.
    @State private var sliceByDistanceSpacingMm: Double = 5.0
    // Custom: user-edited list of explicit positions in axis-space (mm).
    @State private var customSlicePositions: [Double] = []
    // Slice Edit mode: while true, viewport clicks select slices (not dowels).
    @State private var sliceEditMode3D = false
    // The currently selected slice index (into slicePlan.positions), or nil.
    @State private var selectedSliceIndex: Int? = nil
    // Slicing is an explicit action, not automatic: nothing slices until the
    // user presses Slice. Loading a model or changing any slice input re-arms
    // it (back to false), so a stale plan can't survive and nothing recomputes
    // until Slice is pressed again.
    @State private var sliceComputationEnabled = false
    // Structures (Manifold-backed infill). Like Slice, generation is an explicit
    // action: nothing runs until Generate is pressed. `structureSettings` holds
    // the live controls; `generatedStructurePlan` is the cached result of the
    // last Generate; `generatedStructureSignature` is the input snapshot that
    // produced it (mismatch with the live inputs ⇒ the result is STALE).
    @State private var structureSettings = StructureSettings.defaultValue
    @State private var generatedStructurePlan: StructureMeshPlan?
    @State private var generatedStructureSignature: StructureInputSignature?
    @State private var isGeneratingStructure = false
    @State private var structureGenerateMessage: String?
    // Partition (bed-sized splitting). Same explicit-Generate contract as
    // Structures: `partitionSettings` holds the live controls; the generated plan
    // is cached with the input snapshot that produced it (mismatch ⇒ STALE).
    @State private var partitionSettings = PartitionSettings.defaultValue
    // Fit Printer and Split by Undercuts keep independent generated results.
    // The latter must remain inspectable/export-addressable when stale or when
    // a replacement planning run is cancelled or fails (PRD R1/R10/R11).
    @State private var generatedPartitionPlan: PartitionMeshPlan?
    @State private var generatedPartitionSignature: PartitionInputSignature?
    @State private var generatedUndercutPartitionPlan: PartitionMeshPlan?
    @State private var generatedUndercutOverlay: UndercutSplitOverlay?
    @State private var undercutGenerationState = PartitionUndercutGenerationState()
    @State private var undercutPlannerCache = UndercutSplitPlannerCache(maximumEntryCount: 512)
    @State private var undercutPartitionGenerateMessage: String?
    @State private var partitionFingerprintSnapshot: PartitionSourceFingerprintSnapshot?
    @State private var partitionGenerationTask: Task<Void, Never>?
    @State private var partitionCancellationFlag: PartitionCancellationFlag?
    @State private var activeUndercutGenerationToken: UInt64?
    @State private var undercutPlanningStartedAt: Date?
    @State private var undercutCutEditMode3D = false
    @State private var selectedUndercutCutNodeID: PartitionCutNodeID?
    @State private var hoveredUndercutCutNodeID: PartitionCutNodeID?
    @State private var selectedUndercutPieceRegionID: PartitionRegionID?
    @State private var isolatedUndercutPieceRegionID: PartitionRegionID?
    @State private var hoveredUndercutRegionID: String?
    @State private var pendingUndercutCutNodeDeletion: PartitionCutNodeID?
    @State private var undercutFacePaintMode: UndercutFacePaintMode = .none
    @State private var isGeneratingPartition = false
    @State private var partitionGenerateMessage: String?
    // In-viewport plane gizmo (Manual mode): toggle + current selection.
    @State private var partitionEditMode3D = false
    @State private var selectedPartitionPlaneIndex: Int?
    // MotherMold (casting molds). Like Structures, generation is an explicit
    // action: nothing runs until Build mold is pressed. `motherMoldSettings`
    // holds the live controls; `generatedMotherMoldPlan` is the cached result of
    // the last build; `generatedMotherMoldSignature` is the input snapshot that
    // produced it (mismatch with the live inputs ⇒ the result is STALE).
    @State private var motherMoldSettings = MotherMoldSettings.defaultValue
    @State private var generatedMotherMoldPlan: MotherMoldPlan?
    @State private var generatedMotherMoldSignature: MotherMoldInputSignature?
    @State private var isGeneratingMotherMold = false
    @State private var motherMoldGenerateMessage: String?
    @State private var motherMoldBuildTask: Task<Void, Never>?
    @State private var motherMoldBuildRelay: MotherMoldBuildRelay?
    @State private var motherMoldBuildSessionID: UUID?
    @State private var motherMoldBuildStage: MoldBuildStage?
    @State private var motherMoldBuildStartedAt: Date?
    @State private var motherMoldBuildFailure: MotherMoldUIContract.BuildFailurePresentation?
    @State private var motherMoldBuildFailureSignature: MotherMoldInputSignature?
    @State private var motherMoldBuildDetailsExpanded = false
    /// View-only inspection state. It never participates in generation,
    /// staleness, project persistence, or export.
    @State private var motherMoldExploded = false
    @State private var motherMoldShowUndercuts = false
    @State private var isolatedMotherMoldPartName: String?
    @State private var motherMoldArtistViewMode: MotherMoldArtistViewMode = .assembly
    @State private var motherMoldVisibleLayers: Set<MotherMoldPreviewLayer> = Set(MotherMoldPreviewLayer.allCases)
    /// Debounced, settings-only guides shown before a fresh MotherMold plan
    /// exists. This is never persisted and never feeds generation or export.
    @State private var motherMoldPrebuildOverlay: MotherMoldPrebuildOverlay?
    /// One-shot viewport placement mode. A drag still belongs to orbit; only a
    /// stationary mouse-up on the source mesh commits and then disarms it.
    @State private var motherMoldPlacementTarget: MotherMoldSurfacePlacement.Target?

    // Inflatables: explicit Generate action builds flat membrane panels and a
    // cached cut sheet. It bypasses legacy slice/dowel planning.
    @State private var inflatablesSettings = InflatablesSettings.defaultValue
    @State private var generatedInflatablesPlan: InflatablesPlan?
    @State private var generatedInflatablesSignature: InflatablesInputSignature?
    @State private var isGeneratingInflatables = false
    @State private var inflatablesGenerateMessage: String?
    @State private var selectedInflatablePanelID: String?
    @State private var inflatablesViewMode: InflatablesViewMode = .inflated
    // Object Size: Original Size (true imported size, factor 1.0) vs Uniform Scale.
    @State private var uniformScaleEnabled = true
    // Restored from the last session; persisted on every change (below).
    @State private var viewportAppearance = ViewportAppearanceStore.load()

    enum InspectorTab: Hashable {
        case object
        case viewport
        case issues
        case statistics
    }

    @State private var inspectorTab: InspectorTab = .object
    @State private var isRepairingMesh = false
    /// NEO-97: the Blender-style model-rotation rings toggle (Object Size).
    @State private var modelRotateGizmoActive = false

    /// Collapsed left-rail sections (comma-joined section rawValues), persisted
    /// across launches as a UI preference. Default-collapses occasional or
    /// advanced panels so the left rail opens on the primary workflow controls.
    /// Every section header is a toggle.
    @AppStorage("refabartist.collapsedSections") private var collapsedSectionsRaw = "manufacturing,modifyForm,sliceDirection"
    @AppStorage("refabartist.sectionDefaultsVersion") private var sectionDefaultsVersion = 0
    /// SpaceMouse motion smoothing (0 = raw, 1 = heavy). Blends consecutive
    /// samples so a diagonal push doesn't "zipper" between axes when the driver's
    /// Dominant-Axis filter is on. Default on.
    @AppStorage("refabartist.spaceMouseSmoothing") private var spaceMouseSmoothing = 0.6
    /// SpaceMouse overall speed; 0.5 = normal (1x), 1.0 = 2x.
    @AppStorage("refabartist.spaceMouseSpeed") private var spaceMouseSpeed = 0.5
    /// Running smoothed SpaceMouse motion for the low-pass blend.
    @State private var spaceMouseSmoothed = SpaceMouseController.Motion(tx: 0, ty: 0, tz: 0, rx: 0, ry: 0, rz: 0)

    /// Binding for one section's expanded state, backed by `collapsedSectionsRaw`.
    private func sectionExpanded(_ section: InspectorPanelSection) -> Binding<Bool> {
        Binding(
            get: {
                !collapsedSectionsRaw.split(separator: ",").map(String.init).contains(section.rawValue)
            },
            set: { expanded in
                var set = Set(collapsedSectionsRaw.split(separator: ",").map(String.init))
                if expanded { set.remove(section.rawValue) } else { set.insert(section.rawValue) }
                collapsedSectionsRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    private func applySectionDefaultMigration() {
        guard sectionDefaultsVersion < 1 else { return }
        var set = Set(collapsedSectionsRaw.split(separator: ",").map(String.init))
        set.insert(InspectorPanelSection.sliceDirection.rawValue)
        collapsedSectionsRaw = set.sorted().joined(separator: ",")
        sectionDefaultsVersion = 1
    }

    // MARK: - Undo/Redo (NEO-114)

    /// A restorable instant of project state. `settings` carries every panel
    /// control (the same struct project save uses, restored through the same
    /// `applyProjectSettings`); the mesh reference covers mesh-replacing
    /// operations (Repair). Mesh copies are COW — the stack holds references,
    /// not duplicated geometry.
    struct ProjectStateSnapshot {
        var settings: SlicerProjectSettings
        var model: MeshSummary?
    }

    @State private var undoHistory = UndoHistory<ProjectStateSnapshot>()
    /// The settings value just restored by undo/redo. The restore itself must
    /// not register as a fresh edit, and a boolean suppress-flag can't work:
    /// `onChange` observes the mutation on a LATER render pass, after any
    /// synchronous flag reset. Matching the restored value is deterministic.
    @State private var lastRestoredSettings: SlicerProjectSettings?

    private var currentStateSnapshot: ProjectStateSnapshot {
        ProjectStateSnapshot(settings: projectSettings, model: model)
    }

    /// Called from `.onChange(of: projectSettings)` — one hook captures every
    /// control mutation in the app, because all undoable state lives in the
    /// persisted settings struct.
    private func recordSettingsChange(old: SlicerProjectSettings, new: SlicerProjectSettings) {
        let restored = lastRestoredSettings
        lastRestoredSettings = nil
        if new == restored { return }
        guard model != nil else { return }
        undoHistory.record(ProjectStateSnapshot(settings: old, model: model))
    }

    private func performUndo() {
        if forwardHistoryToFieldEditor(redo: false) { return }
        guard let snapshot = undoHistory.undo(current: currentStateSnapshot) else {
            NSSound.beep()
            return
        }
        restoreSnapshot(snapshot)
    }

    private func performRedo() {
        if forwardHistoryToFieldEditor(redo: true) { return }
        guard let snapshot = undoHistory.redo(current: currentStateSnapshot) else {
            NSSound.beep()
            return
        }
        restoreSnapshot(snapshot)
    }

    /// A focused text field keeps the standard text-editing undo — without
    /// this, ⌘Z while typing a dimension would silently revert slice edits.
    private func forwardHistoryToFieldEditor(redo: Bool) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isFieldEditor,
              let manager = editor.undoManager else { return false }
        if redo {
            guard manager.canRedo else { return false }
            manager.redo()
        } else {
            guard manager.canUndo else { return false }
            manager.undo()
        }
        return true
    }

    private func restoreSnapshot(_ snapshot: ProjectStateSnapshot) {
        lastRestoredSettings = snapshot.settings
        // Cheap identity proxy: Repair (the only mesh-replacing op) always
        // changes the triangle count. Avoids re-publishing an identical mesh
        // on every settings-only undo.
        if snapshot.model?.triangleCount != model?.triangleCount
            || snapshot.model?.name != model?.name {
            cancelMotherMoldBuild(showMessage: false)
            model = snapshot.model
        }
        applyProjectSettings(snapshot.settings)
    }

    // MARK: - Modify Form state (NEO-108; non-destructive since NEO-113)

    /// Hollow wall thickness slider value (mm).
    @State private var modifyHollowWallThickness = 3.0
    /// Thicken offset slider value (mm).
    @State private var modifyThickenAmount = 2.0
    /// Shrinkwrap detail slider value (0 coarse … 1 fine).
    @State private var modifyShrinkwrapDetail = 0.5
    /// Make Watertight method: Fix in place (keep the surface), Make walls, or
    /// rebuild the whole surface as a solid. Starts at Fix in place — never
    /// at Rebuild: Rebuild replaces every triangle, so it is only ever the
    /// default once the diagnosis says nothing else can fix the model.
    @State private var modifyWatertightMethod: WatertightMethod = .closeOpenings
    /// True once the user picked a method for this model, so the
    /// diagnosis-based default no longer overrides it.
    @State private var watertightMethodChosen = false
    /// Close-openings top shape, mm: 0 flat, > 0 dome, < 0 dish.
    @State private var modifyWatertightTopHeight = 0.0
    /// Make walls thickness, mm.
    @State private var modifyWallThickness = 2.0
    /// Make Watertight per-opening choices, keyed by opening signature (Cap /
    /// Leave open + own top shape; Open / Closed in Make walls).
    @State private var modifyOpeningChoices: [OpeningCapper.OpeningChoice] = []
    /// Saved per-opening choices dropped because their opening is gone.
    @State private var openingChoicesNotice: String? = nil

    /// Openings and defects of the scaled model (computed off-main).
    @State private var openingDiagnosis: OpeningCapper.Diagnosis? = nil
    /// `diagnosisKey` the diagnosis was computed for (its sites' positions
    /// are only valid for that load, scale and rotation).
    @State private var openingDiagnosisStamp: String? = nil
    /// Bumped on every model load (import, sample, project open). Part of
    /// `diagnosisKey`, so re-importing the very same file — same name, size,
    /// scale — still re-runs the diagnosis that the load just cleared.
    @State private var modelLoadGeneration = 0
    /// Model Health issue markers: the selected problem site, the latest
    /// fly-to request, and the Issues panel's "Show issues in viewport".
    @State private var selectedIssueSiteID: String? = nil
    @State private var issueFocusRequest: IssueMarkers.FocusRequest? = nil
    @AppStorage("refabartist.showIssueMarkers") private var showIssueMarkers = true
    /// Truthful, unit-independent topology report of the imported model
    /// (`OpeningCapper.importedTopologyReport`), computed off-main once per
    /// model identity. `scaledModel` carries it as its `preflight`, so every
    /// GUI consumer (Stats, Issues, the MotherMold / Partition gates) sees it
    /// instead of the raw import preflight, which is measured in the file's
    /// own units and misreads valid inch / unit-box models as broken.
    @State private var importedTopology: ImportedTopologyReport? = nil

    struct ImportedTopologyReport: Equatable {
        var modelKey: String
        var report: MeshPreflightReport

        /// Measure `imported` (off-main — this is the slow part).
        static func measure(_ imported: MeshSummary) -> ImportedTopologyReport {
            ImportedTopologyReport(
                modelKey: ViewportGeometryCache.modelKey(for: imported),
                report: OpeningCapper.importedTopologyReport(imported.geometry)
            )
        }

        /// `scaled` (the unit-scaled / rotated `imported` model) carrying this
        /// report as its preflight — only when the report was measured on
        /// `imported`; otherwise `scaled` unchanged.
        func applied(to scaled: MeshSummary, importedFrom imported: MeshSummary) -> MeshSummary {
            guard modelKey == ViewportGeometryCache.modelKey(for: imported) else { return scaled }
            var copy = scaled
            copy.preflight = report
            return copy
        }
    }
    /// The modifier slicing and export actually use (nil = pristine mesh).
    /// Set by Apply, cleared by Remove. The imported mesh is never replaced —
    /// Modify Form is a setting, not surgery, so it is always reversible.
    @State private var modifyActiveTool: ModifyFormTool? = nil
    /// Make Watertight is a preprocessing step for the current model. Hollow
    /// and Thicken must run on top of it, not replace it, or the old open-edge
    /// mesh comes back as soon as a form tool is applied.
    @State private var watertightPreprocessEnabled = false
    /// The eye icon: which tool's result the viewport is showing right now.
    /// View-only — slicing ignores it until Apply.
    @State private var modifyPreviewTool: ModifyFormTool? = nil
    /// Single-slot cache of the last modified mesh, keyed by what produced it.
    @State private var modifyComputedKey: ModifyComputationKey? = nil
    @State private var modifyComputedMesh: MeshSummary? = nil
    /// Make Watertight's result line per computation (keyed by everything
    /// that produced it), and whether that step changed nothing (it failed,
    /// or had nothing to do). Looked up by the settings on screen, so the
    /// panels only ever show the outcome of exactly those settings, and an
    /// eye preview of another tool can't erase it.
    struct WatertightOutcome: Equatable {
        var receipt: String
        var unchanged: Bool
    }
    @State private var watertightOutcomes: [ModifyComputationKey: WatertightOutcome] = [:]
    /// True while a modified mesh is computing off-main (panel shows a spinner).
    @State private var isComputingModify = false

    /// Everything the modified mesh depends on. When any of it changes the
    /// cached mesh is stale and `ensureModifiedMesh` recomputes off-main.
    struct ModifyComputationKey: Hashable {
        var tool: ModifyFormTool
        var amount: Double
        var modelStamp: String
        var watertightBase: Bool
        var watertightDetail: Double
        var watertightMethod: WatertightMethod? = nil
        var watertightTopHeight: Double = 0
        var wallThickness: Double = 0
        var openingChoices: [OpeningCapper.OpeningChoice] = []
    }

    private var modifyModelStamp: String {
        let scale = effectiveScale
        let rot = modelRotationDegrees
        return "\(model?.name ?? "")|\(model?.triangleCount ?? 0)|\(model?.vertexObservationCount ?? 0)|\(scale.x)|\(scale.y)|\(scale.z)|\(rot.x)|\(rot.y)|\(rot.z)"
    }

    private func modifyAmount(for tool: ModifyFormTool) -> Double {
        switch tool {
        case .hollow: return modifyHollowWallThickness
        case .thicken: return modifyThickenAmount
        case .shrinkwrap: return modifyShrinkwrapDetail
        }
    }

    private func modifyKey(for tool: ModifyFormTool) -> ModifyComputationKey {
        let usesWatertightBase = watertightPreprocessEnabled && tool != .shrinkwrap
        let watertightMatters = tool == .shrinkwrap || usesWatertightBase
        return ModifyComputationKey(
            tool: tool,
            amount: modifyAmount(for: tool),
            modelStamp: modifyModelStamp,
            watertightBase: usesWatertightBase,
            watertightDetail: usesWatertightBase ? modifyShrinkwrapDetail : 0,
            watertightMethod: watertightMatters ? modifyWatertightMethod : nil,
            watertightTopHeight: watertightMatters && modifyWatertightMethod == .closeOpenings ? modifyWatertightTopHeight : 0,
            wallThickness: watertightMatters && modifyWatertightMethod == .walls ? modifyWallThickness : 0,
            openingChoices: watertightMatters && modifyWatertightMethod != .rebuild ? modifyOpeningChoices : []
        )
    }

    /// Kick an off-main computation of the modified mesh if the cache doesn't
    /// already hold the result for `tool` at the current parameters. If the
    /// parameters move again while a computation is in flight, the completion
    /// re-kicks with the new key, so the cache always converges on what the
    /// UI is asking for.
    private func ensureModifiedMesh(for tool: ModifyFormTool) {
        guard let base = scaledModel else { return }
        let key = modifyKey(for: tool)
        if modifyComputedKey == key, modifyComputedMesh != nil { return }
        guard !isComputingModify else { return }
        isComputingModify = true
        Task.detached(priority: .userInitiated) {
            var input = base
            var receipt: String? = nil
            var unchanged = false
            let method = key.watertightMethod ?? .closeOpenings
            if key.watertightBase {
                let outcome = MeshModifier.makeWatertightOutcome(input, method: method, detail: key.watertightDetail, topHeight: key.watertightTopHeight, wallThickness: key.wallThickness, openingChoices: key.openingChoices)
                (input, receipt, unchanged) = (outcome.summary, outcome.receipt, !outcome.changed)
            }
            let mesh: MeshSummary
            switch key.tool {
            case .hollow: mesh = MeshModifier.hollow(input, wallThickness: key.amount)
            case .thicken: mesh = MeshModifier.thicken(input, amount: key.amount)
            case .shrinkwrap:
                let outcome = MeshModifier.makeWatertightOutcome(input, method: method, detail: key.amount, topHeight: key.watertightTopHeight, wallThickness: key.wallThickness, openingChoices: key.openingChoices)
                (mesh, receipt, unchanged) = (outcome.summary, outcome.receipt, !outcome.changed)
            }
            await MainActor.run {
                modifyComputedKey = key
                modifyComputedMesh = mesh
                if let receipt {
                    if watertightOutcomes.count > 64 { watertightOutcomes.removeAll() }
                    watertightOutcomes[key] = WatertightOutcome(receipt: receipt, unchanged: unchanged)
                }
                if unchanged, let receipt, let active = modifyActiveTool, modifyKey(for: active) == key {
                    // Replace the "… active" message posted before the
                    // outcome was known.
                    exportMessage = receipt
                }
                isComputingModify = false
                if let wanted = modifyPreviewTool ?? modifyActiveTool,
                   modifyKey(for: wanted) != key {
                    ensureModifiedMesh(for: wanted)
                }
            }
        }
    }

    /// The cached modified mesh, but only if it matches `tool` at the current
    /// parameters — a stale cache falls back to the unmodified mesh rather
    /// than showing the wrong geometry.
    private func currentModifiedMesh(for tool: ModifyFormTool?) -> MeshSummary? {
        guard let tool, let mesh = modifyComputedMesh,
              modifyComputedKey == modifyKey(for: tool) else { return nil }
        return mesh
    }

    /// Clear all Modify Form state (model import / project load).
    private func resetModifyForm() {
        modifyActiveTool = nil
        modifyPreviewTool = nil
        watertightPreprocessEnabled = false
        modifyComputedKey = nil
        modifyComputedMesh = nil
        watertightOutcomes = [:]
        modifyHollowWallThickness = 3.0
        modifyThickenAmount = 2.0
        modifyShrinkwrapDetail = 0.5
        modifyWatertightMethod = .closeOpenings
        watertightMethodChosen = false
        modifyWatertightTopHeight = 0
        modifyWallThickness = 2.0
        modifyOpeningChoices = []
        openingChoicesNotice = nil
        openingDiagnosis = nil
        openingDiagnosisStamp = nil
        modelLoadGeneration += 1
        selectedIssueSiteID = nil
        issueFocusRequest = nil
    }

    /// What the opening diagnosis depends on: the loaded model (every load
    /// counts, even of the same file), its scale and its rotation.
    private var diagnosisKey: String {
        "\(modifyModelStamp)#\(modelLoadGeneration)"
    }

    /// True once the diagnosis describes the model as loaded, scaled and
    /// rotated right now. Until then the Issues panel offers no fix — it
    /// can't yet say which fix fits.
    private var openingDiagnosisIsCurrent: Bool {
        openingDiagnosisStamp == diagnosisKey
    }

    /// New scale / unit / rotation (`diagnosisKey` changed): an applied or
    /// previewed Modify Form result is stale — recompute it (the panels show
    /// Working…) rather than silently falling back to the raw mesh. A no-op
    /// when the cached result already matches.
    private func refreshModifiedFormForCurrentModel() {
        guard let wanted = modifyPreviewTool ?? modifyActiveTool else { return }
        let stale = modifyComputedKey != modifyKey(for: wanted)
        ensureModifiedMesh(for: wanted)
        if stale, modifyActiveTool != nil { sliceComputationEnabled = false }
    }

    /// Diagnose the scaled model's openings and defects off-main. The
    /// diagnosis never changes the method: it only decides which fixes the
    /// Issues panel offers (Rebuild as solid runs only when picked by name).
    private func refreshOpeningDiagnosis() async {
        guard let geometry = scaledModel?.geometry else {
            openingDiagnosis = nil
            openingDiagnosisStamp = nil
            selectedIssueSiteID = nil
            return
        }
        let stamp = diagnosisKey
        let diagnosis = await Task.detached(priority: .utility) {
            OpeningCapper.diagnose(geometry)
        }.value
        guard !Task.isCancelled else { return }
        if openingDiagnosisStamp != stamp {
            // New geometry: the old site ids no longer name the same places.
            selectedIssueSiteID = nil
            issueFocusRequest = nil
        }
        openingDiagnosis = diagnosis
        openingDiagnosisStamp = stamp
        // Saved per-opening choices follow their opening by signature; one
        // that matches no opening of the model as it is now is dropped, and
        // the panel says so. (Only for a diagnosis of the current scale /
        // rotation — a stale one must not drop anything.)
        if stamp == diagnosisKey, let diagnosis, !modifyOpeningChoices.isEmpty {
            let unmatched = OpeningCapper.matchChoices(modifyOpeningChoices, to: diagnosis.openings).unmatched
            if !unmatched.isEmpty {
                modifyOpeningChoices.removeAll { unmatched.contains($0) }
                // Not a user edit: keep it off the undo stack (redo
                // survives), and recompute what was computed with them.
                lastRestoredSettings = projectSettings
                refreshModifiedFormForCurrentModel()
                openingChoicesNotice = unmatched.count == 1
                    ? "1 saved opening choice no longer matches any opening (the model changed) and was dropped."
                    : "\(unmatched.count) saved opening choices no longer match any opening (the model changed) and were dropped."
            }
        }
    }

    /// True when the viewport shows the very mesh the diagnosis measured (the
    /// scaled model, no Modify Form result standing in for it).
    private var issueDiagnosisDescribesViewport: Bool {
        // Make Watertight alone that changed nothing: the viewport shows the
        // diagnosed mesh, so its problem spots still apply.
        if activeWatertightFailed, modifyActiveTool == .shrinkwrap, modifyPreviewTool == nil { return true }
        return currentModifiedMesh(for: modifyPreviewTool) == nil
            && currentModifiedMesh(for: modifyActiveTool) == nil
            && !(watertightPreprocessEnabled && currentModifiedMesh(for: .shrinkwrap) != nil)
    }

    /// Problem sites to mark on the model: only while the Issues tab is up,
    /// for a current diagnosis of the displayed mesh with something to fix.
    private var viewportIssueSites: [OpeningCapper.Site] {
        guard isStatsVisible,
              let diagnosis = openingDiagnosis,
              openingDiagnosisIsCurrent,
              issueDiagnosisDescribesViewport,
              !diagnosis.isNothingToFix else { return [] }
        if inspectorTab == .issues { return diagnosis.sites }
        // Modify Form's per-opening list is on screen: mark the openings so
        // a row and its marker select each other.
        if inspectorTab == .object, sectionExpanded(.modifyForm).wrappedValue,
           ModifyFormPanel.showsOpeningRows(diagnosis, method: modifyWatertightMethod) {
            return diagnosis.sites.filter { $0.kind == .opening }
        }
        return []
    }

    /// Select a problem site (nil deselects) and fly the camera to it.
    private func selectIssueSite(_ id: String?) {
        selectedIssueSiteID = id
        if let id {
            issueFocusRequest = IssueMarkers.FocusRequest(siteID: id, nonce: (issueFocusRequest?.nonce ?? 0) + 1)
        }
    }

    /// The Issues panel's method buttons (Fix in place / Make walls /
    /// Rebuild as solid, and each spot's Fix in place): Make Watertight with
    /// exactly that method — a pick, like choosing it in Modify Form — so
    /// every button does what its label says, whatever the picker had.
    private func applyWatertight(_ method: WatertightMethod) {
        // The same fix with the same settings just changed nothing: running
        // it again would only claim success (its buttons are disabled too).
        if method == modifyWatertightMethod, watertightIsOn, activeWatertightFailed { return }
        if let active = modifyActiveTool, active != .shrinkwrap {
            // Hollow / Thicken stays applied: Make Watertight runs under it
            // with this method, and the tool on top is recomputed on it.
            if modifyWatertightMethod != method {
                modifyWatertightMethod = method
            }
            watertightMethodChosen = true
            watertightPreprocessEnabled = true
            modifyPreviewTool = nil
            ensureModifiedMesh(for: active)
            sliceComputationEnabled = false
            if let outcome = watertightOutcome(for: active), outcome.unchanged {
                exportMessage = outcome.receipt
            } else {
                exportMessage = "Make Watertight (\(method.label)) now runs under \(active.label) — slicing uses \(active.label) on the fixed surface."
            }
            return
        }
        if modifyWatertightMethod != method {
            watertightMethodBinding.wrappedValue = method
        }
        watertightMethodChosen = true
        applyModifyTool(.shrinkwrap)
    }

    /// Issues panel Remove: turn Make Watertight off, whether it is the
    /// active tool or the base under Hollow / Thicken (which stays applied,
    /// now on the imported mesh).
    private func removeWatertight() {
        if modifyActiveTool == .shrinkwrap {
            removeModifyTool()
            return
        }
        guard watertightPreprocessEnabled, let active = modifyActiveTool else { return }
        watertightPreprocessEnabled = false
        ensureModifiedMesh(for: active)
        sliceComputationEnabled = false
        exportMessage = "Make Watertight removed — \(active.label) now applies to the imported mesh."
    }

    /// Make Watertight's outcome in `tool`'s computation — only when `tool`
    /// runs a Make Watertight step AND the cache holds its result for the
    /// settings on screen now (nil = not computed for these settings).
    private func watertightOutcome(for tool: ModifyFormTool?) -> WatertightOutcome? {
        guard let tool, tool == .shrinkwrap || watertightPreprocessEnabled else { return nil }
        return watertightOutcomes[modifyKey(for: tool)]
    }

    /// Make Watertight with the settings on screen is already known to change
    /// nothing (e.g. its eye preview failed): its result line, else nil.
    private var watertightKnownNoOp: String? {
        guard let outcome = watertightOutcome(for: .shrinkwrap), outcome.unchanged else { return nil }
        return outcome.receipt
    }

    /// The applied Make Watertight changed nothing, with the settings on
    /// screen now (it failed, or had nothing to do).
    private var activeWatertightFailed: Bool {
        watertightOutcome(for: modifyActiveTool)?.unchanged ?? false
    }

    /// Make Watertight is on: the active tool, or the base under the active
    /// Hollow / Thicken.
    private var watertightIsOn: Bool {
        modifyActiveTool == .shrinkwrap || (watertightPreprocessEnabled && modifyActiveTool != nil)
    }

    /// `REFAB_LAYOUT_AUDIT=<path>`: show every construction technique and
    /// inspector tab (plus Make Watertight applied) with both side panes at
    /// their narrowest, write the sections wider than their pane to <path>
    /// (see `LayoutOverflowAudit`), and quit.
    private func runLayoutOverflowAudit() async {
        func settle(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let tabs: [InspectorTab] = [.object, .viewport, .issues, .statistics]
        collapsedSectionsRaw = ""
        isSidebarVisible = true
        LayoutOverflowAudit.context = "no-model"
        await settle(1500)
        if model == nil { loadSampleModel() }
        for _ in 0..<120 where model == nil || !openingDiagnosisIsCurrent { await settle(250) }
        isStatsVisible = true
        LayoutOverflowAudit.context = "technique-chooser"
        isTechniqueChooserExpanded = true
        await settle()
        for mode in ConstructionMode.allCases {
            for tab in tabs {
                LayoutOverflowAudit.context = "mode=\(mode.rawValue) tab=\(tab)"
                selectConstructionTechnique(mode)
                inspectorTab = tab
                await settle()
            }
        }
        selectConstructionTechnique(.stacked)
        for method in [WatertightMethod.closeOpenings, .walls] {
            applyWatertight(method)
            await settle(300)
            for _ in 0..<120 where isComputingModify { await settle(250) }
            for tab in [InspectorTab.object, .issues] {
                LayoutOverflowAudit.context = "watertight=\(method.rawValue) tab=\(tab)"
                inspectorTab = tab
                await settle()
            }
        }
        LayoutOverflowAudit.writeReport()
        NSApp.terminate(nil)
    }

    /// Issues panel "Options…": show Object → Modify Form (top shape, wall
    /// thickness, per-opening choices).
    private func showWatertightOptions() {
        inspectorTab = .object
        sectionExpanded(.modifyForm).wrappedValue = true
    }

    /// Identity of the imported model the truthful report belongs to (nil
    /// with no model). Scale and rotation don't change it: the report's
    /// tolerances are relative to the model's own size.
    private var importedTopologyKey: String? {
        model.map(ViewportGeometryCache.modelKey(for:))
    }

    /// Measure the imported model's truthful topology off-main (once per
    /// model; the raw preflight stands in until it lands).
    private func refreshImportedTopology() async {
        guard let model, let key = importedTopologyKey else {
            importedTopology = nil
            return
        }
        if importedTopology?.modelKey == key { return }
        let measured = await Task.detached(priority: .utility) {
            ImportedTopologyReport.measure(model)
        }.value
        guard !Task.isCancelled, importedTopologyKey == key, measured.modelKey == key else { return }
        importedTopology = measured
    }

    /// Method picker binding: a user pick sticks and recomputes if shown.
    private var watertightMethodBinding: Binding<WatertightMethod> {
        Binding(
            get: { modifyWatertightMethod },
            set: { newValue in
                guard newValue != modifyWatertightMethod else { return }
                if watertightIsOn || modifyPreviewTool == .shrinkwrap,
                   let reason = newValue.unavailableReason(openingDiagnosisIsCurrent ? openingDiagnosis : nil,
                                                           choices: modifyOpeningChoices) {
                    // Switching would re-run the applied / previewed result
                    // with a method known to change nothing: keep it.
                    exportMessage = "\(newValue.label) can't change this model — \(reason) Make Watertight keeps \(modifyWatertightMethod.label)."
                    return
                }
                modifyWatertightMethod = newValue
                watertightMethodChosen = true
                modifyParameterCommitted(for: .shrinkwrap)
            }
        )
    }

    /// Strip only what cannot be real surface (collapsed triangles, loose
    /// zero-area specks, winged fins) and reload the cleaned geometry in place.
    /// When nothing qualifies the model is left untouched. Open boundary edges
    /// are reported, not patched.
    private func repairMesh() {
        guard let current = model, !isRepairingMesh else { return }
        cancelMotherMoldBuild(showMessage: false)
        isRepairingMesh = true
        Task.detached(priority: .userInitiated) {
            let result = MeshManifoldRepair.safeRepair(current.geometry)
            guard result.removedTriangles > 0 else {
                await MainActor.run {
                    isRepairingMesh = false
                    exportMessage = "Repair found nothing to remove — it only deletes collapsed triangles, loose zero-area specks and winged fins, and this model has none. Your model is unchanged."
                }
                return
            }
            let cleaned = result.geometry
            let preflight = MeshPreflight.analyze(geometry: cleaned)
            var bounds: Bounds3D?
            if let first = cleaned.vertices.first {
                var minV = first
                var maxV = first
                for v in cleaned.vertices {
                    minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
                    maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
                }
                bounds = Bounds3D(min: minV, max: maxV)
            }
            let repairedSummary = MeshSummary(
                name: current.name,
                path: current.path,
                format: current.format,
                byteCount: current.byteCount,
                vertexObservationCount: cleaned.vertices.count,
                faceCount: cleaned.triangleIndices.count / 3,
                triangleCount: cleaned.triangleIndices.count / 3,
                bounds: bounds,
                geometry: cleaned,
                preflight: preflight
            )
            // The stored `preflight` stays the raw import-style report (as
            // `MeshInspector` stores it); the GUI shows and reports the
            // truthful, unit-independent one.
            let truthful = ImportedTopologyReport.measure(repairedSummary)
            await MainActor.run {
                // NEO-114: Repair replaces the mesh — bank the old one so ⌘Z
                // brings it back (the reference is COW-cheap).
                undoHistory.record(currentStateSnapshot)
                model = repairedSummary
                importedTopology = truthful
                modifyComputedKey = nil
                modifyComputedMesh = nil
                watertightOutcomes = [:]
                sliceComputationEnabled = false
                isRepairingMesh = false
                exportMessage = "Repair removed \(result.removedTriangles) broken triangles (\(result.collapsedTriangles) collapsed, \(result.looseZeroAreaTriangles) loose specks, \(result.finTriangles) fins). Remaining: \(truthful.report.boundaryEdgeCount) open edges, \(truthful.report.nonManifoldEdgeCount) non-manifold edges."
            }
        }
    }

    // MARK: - Modify Form actions (non-destructive)

    /// Apply: slicing and export now use this tool's modified form. The
    /// imported mesh is untouched — Remove (or selecting nothing) reverts.
    private func applyModifyTool(_ tool: ModifyFormTool) {
        if tool == .shrinkwrap || modifyActiveTool == .shrinkwrap {
            watertightPreprocessEnabled = true
        }
        if tool == .shrinkwrap {
            // Applying commits the method on screen: a later diagnosis
            // must never swap the method under an applied result.
            watertightMethodChosen = true
        }
        modifyActiveTool = tool
        modifyPreviewTool = nil
        ensureModifiedMesh(for: tool)
        sliceComputationEnabled = false
        if let outcome = watertightOutcome(for: tool), outcome.unchanged {
            exportMessage = outcome.receipt
            return
        }
        let amount = modifyAmount(for: tool)
        let amountLabel: String
        if tool == .shrinkwrap {
            amountLabel = modifyWatertightMethod == .rebuild
                ? "Rebuild as solid, detail \(String(format: "%.2f", amount))"
                : modifyWatertightMethod.label
        } else {
            amountLabel = "\(String(format: "%.1f", amount)) mm"
        }
        exportMessage = "\(tool.label) active (\(amountLabel)) — slicing uses the modified form. Remove it in Modify Form to revert."
    }

    /// Remove the active modifier: slicing returns to the pristine mesh.
    private func removeModifyTool() {
        if modifyActiveTool == .shrinkwrap {
            watertightPreprocessEnabled = false
        }
        modifyActiveTool = nil
        modifyPreviewTool = nil
        sliceComputationEnabled = false
        if watertightPreprocessEnabled {
            modifyActiveTool = .shrinkwrap
            ensureModifiedMesh(for: .shrinkwrap)
            exportMessage = "Modify Form removed — slicing uses the watertight mesh."
        } else {
            exportMessage = "Modify Form removed — slicing uses the original mesh again."
        }
    }

    /// The eye icon: toggle a view-only preview of `tool`'s result.
    private func setModifyPreview(_ tool: ModifyFormTool?) {
        modifyPreviewTool = tool
        if let tool {
            ensureModifiedMesh(for: tool)
        } else if let active = modifyActiveTool {
            // Preview off → the viewport goes back to the ACTIVE form, which
            // may need its mesh recomputed if the preview overwrote the cache.
            ensureModifiedMesh(for: active)
        }
    }

    /// Slider released / value committed while that tool is previewed or
    /// active: the cached mesh is stale, recompute.
    private func modifyParameterCommitted(for tool: ModifyFormTool) {
        // The slice only goes stale when the applied result does (a commit
        // with an unchanged value — e.g. leaving a field — keeps it).
        let activeStale = modifyActiveTool.map { currentModifiedMesh(for: $0) == nil } ?? false
        if modifyPreviewTool == tool || modifyActiveTool == tool {
            ensureModifiedMesh(for: tool)
        }
        if tool == .shrinkwrap,
           watertightPreprocessEnabled,
           let active = modifyActiveTool,
           active != .shrinkwrap {
            ensureModifiedMesh(for: active)
            if activeStale { sliceComputationEnabled = false }
        }
        if modifyActiveTool == tool, activeStale {
            sliceComputationEnabled = false
        }
    }

    // Model statistics live in a collapsible panel on the RIGHT, out of the
    // left control flow.
    @State private var isStatsVisible = false
    @State private var cutSheetDocument: CutSheetDocument?
    /// The notes of the last cut sheet built, whatever the Export format.
    /// Radial's and Curve's mesh exports (OBJ, STL) leave out the same
    /// pieces as the sheet, so their panels show these notes even when the
    /// sheet itself is not shown (`cutSheetDocument` is nil then).
    @State private var builtSheetNotes: [String] = []
    /// The assembly steps the parts belong to
    /// (`AssemblyStepPlanner.stepIndices`), from the cut sheet, which is
    /// built for this even when the export format draws no sheet, and what
    /// it was built from; nil until it is built, or for modes whose parts
    /// are not numbered by step.
    @State private var exportedStepIndices: Set<Int>?
    @State private var exportedStepIndicesKey: CutSheetBuildKey?
    @State private var cutSheetRevisionCounter = 0

    /// The imported mesh after unit scale + Object Size rotation, BEFORE any
    /// Modify Form tool. Memoized: this property is touched many times per
    /// render, and an unmemoized transform copied the full mesh each time
    /// (1.5M vertices per access on the owner's scan whenever the unit factor
    /// wasn't 1).
    ///
    /// Carries the imported model's truthful topology report as its
    /// `preflight` once `refreshImportedTopology` has measured it (the raw
    /// import preflight until then). Modify Form results carry their own.
    private var scaledModel: MeshSummary? {
        model.map {
            let scaled = ViewportGeometryCache.shared.transformedModel(
                for: $0,
                scale: effectiveScale,
                rotationDegrees: modelRotationDegrees
            )
            return importedTopology?.applied(to: scaled, importedFrom: $0) ?? scaled
        }
    }

    /// The mesh slicing, export, and statistics consume: the scaled model with
    /// the ACTIVE Modify Form tool applied (when its result is ready). While
    /// the modified mesh is still computing, slicing would briefly see the
    /// unmodified mesh — the Modify Form panel shows a spinner for exactly
    /// that window.
    private var effectiveModel: MeshSummary? {
        currentModifiedMesh(for: modifyActiveTool)
            ?? (watertightPreprocessEnabled && modifyActiveTool != .shrinkwrap ? currentModifiedMesh(for: .shrinkwrap) : nil)
            ?? scaledModel
    }

    private var activeModifyMeshReady: Bool {
        guard let active = modifyActiveTool else { return true }
        return currentModifiedMesh(for: active) != nil
    }

    /// The mesh the VIEWPORT displays: the eye-icon preview wins over the
    /// active tool; otherwise identical to `effectiveModel`.
    private var displayedModel: MeshSummary? {
        currentModifiedMesh(for: modifyPreviewTool) ?? effectiveModel
    }

    private var effectiveScale: Vec3 {
        let unit = importUnit.millimetersPerUnit
        return Vec3(
            x: unit * MeshScaler.sanitizedFactor(modelScale.x),
            y: unit * MeshScaler.sanitizedFactor(modelScale.y),
            z: unit * MeshScaler.sanitizedFactor(modelScale.z)
        )
    }

    /// The axis whose perpendicular plane the Slice Direction tilt rotates
    /// about, per technique. Radial and 3D have no single primary picker, so
    /// they tilt relative to Z (the radial first-axis convention).
    private var sliceDirectionAxis: SliceAxis {
        switch constructionMode {
        case .stacked, .interlocked: return sliceAxis
        case .curve: return curvePrimaryAxis
        case .radial, .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold: return .z
        }
    }

    /// The Slice Direction rotation (degrees) applied to the model purely for
    /// SLICING — the cut direction tilt. Distinct from `modelRotationDegrees`
    /// (Object Size), which orients the model itself. Zero (identity) when
    /// folded or untilted.
    private var sliceFrameRotationDegrees: Vec3 {
        guard constructionMode != .foldedPanels,
              !SliceDirection.isIdentity(tiltFirst: sliceTiltFirst, tiltSecond: sliceTiltSecond) else {
            return Vec3(x: 0, y: 0, z: 0)
        }
        return SliceDirection.meshRotationDegrees(
            axis: sliceDirectionAxis,
            tiltFirst: sliceTiltFirst,
            tiltSecond: sliceTiltSecond
        )
    }

    /// The Slice Direction bottom bar: live readouts (they follow the rings
    /// while dragging), editable fields, Reset.
    private var sliceDirectionAngleBar: some View {
        let tiltAxes = SliceDirection.tiltAxes(for: sliceDirectionAxis)
        let current = liveSliceTiltPreview ?? Vec2(x: sliceTiltFirst, y: sliceTiltSecond)
        return HStack(spacing: 14) {
            Text("Tilt \(tiltAxes.first.label)")
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f\u{00B0}", current.x))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            TextField("Tilt \(tiltAxes.first.label)", value: $sliceTiltFirst, format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .frame(width: 52)
            Divider().frame(height: 16)
            Text("Tilt \(tiltAxes.second.label)")
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f\u{00B0}", current.y))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            TextField("Tilt \(tiltAxes.second.label)", value: $sliceTiltSecond, format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .frame(width: 52)
            Button("Reset") {
                sliceTiltFirst = 0
                sliceTiltSecond = 0
                liveSliceTiltPreview = nil
            }
            .controlSize(.small)
            .disabled(sliceTiltFirst == 0 && sliceTiltSecond == 0 && liveSliceTiltPreview == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    /// The mesh the slicing engine sees: `effectiveModel` pre-rotated into the
    /// slicing frame by `sliceFrameRotationDegrees`. The planners are
    /// axis-only, so aiming the cut == rotating the model for slicing; the
    /// viewport then counter-rotates the slice solids so the displayed model
    /// stays put (ModelSceneView). Identity tilt returns the memoized
    /// `effectiveModel` instance unchanged.
    private var planningModel: MeshSummary? {
        guard activeModifyMeshReady, let model = effectiveModel else { return nil }
        let rotation = sliceFrameRotationDegrees
        guard rotation != Vec3(x: 0, y: 0, z: 0) else {
            return model
        }
        return ViewportGeometryCache.shared.transformedModel(
            for: model,
            scale: Vec3(x: 1, y: 1, z: 1),
            rotationDegrees: rotation
        )
    }

    /// Hard ceiling on slices the GUI will compute. A runaway transform (a
    /// 14-meter model at 3 mm thickness = ~4,800 slices) sent contour
    /// generation into tens of GB of allocations before this guard existed.
    static let maxGuiSliceCount = 600

    private var slicePlan: StackedSlicePlan? {
        guard hasSelectedConstructionTechnique, sliceComputationEnabled, let model = planningModel else { return nil }
        let plan: StackedSlicePlan?
        switch sliceDistributionMethod {
        case .automatic:
            plan = StackedSlicePlanner.plan(model: model, axis: sliceAxis, materialThickness: materialThickness)
        case .byCount:
            plan = StackedSlicePlanner.plan(model: model, axis: sliceAxis, materialThickness: materialThickness, sliceCountOverride: customSliceCount)
        case .byDistance:
            plan = StackedSlicePlanner.planByDistance(model: model, axis: sliceAxis, materialThickness: materialThickness, spacingMm: sliceByDistanceSpacingMm)
        case .custom:
            plan = StackedSlicePlanner.plan(model: model, axis: sliceAxis, materialThickness: materialThickness, positionsOverride: customSlicePositions.isEmpty ? nil : customSlicePositions)
        }
        guard let plan, plan.sliceCount <= Self.maxGuiSliceCount else { return nil }
        return plan
    }

    private var sliceCountOverride: Int? {
        customSliceDistributionEnabled ? customSliceCount : nil
    }

    private var notchWidthOverride: Double? {
        notchWidthOverrideEnabled ? notchWidth : nil
    }

    private var effectiveSecondarySliceAxis: SliceAxis {
        if secondarySliceAxis != sliceAxis {
            return secondarySliceAxis
        }
        return SliceAxis.allCases.first { $0 != sliceAxis } ?? .x
    }

    /// The axes Interlocked picks itself for this model (across its longest
    /// extent), which override Primary and Secondary; nil when the model's
    /// three extents tie and the chosen axes are used.
    private var interlockedAutomaticAxes: (primary: SliceAxis, secondary: SliceAxis)? {
        guard constructionMode == .interlocked, let bounds = planningModel?.bounds else { return nil }
        return InterlockedSlicePlanner.automaticAxes(bounds: bounds)
    }

    private var interlockedPlan: InterlockedSlicePlan? {
        guard hasSelectedConstructionTechnique, sliceComputationEnabled, let model = planningModel else { return nil }
        return InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: sliceAxis,
            secondaryAxis: effectiveSecondarySliceAxis,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            notchWidthOverride: notchWidthOverride,
            slotAngleDegrees: slotAngleDegrees,
            slotRelief: slotReliefSettings,
            sliceCountOverride: sliceCountOverride
        ).flatMap { $0.sliceCount <= Self.maxGuiSliceCount ? $0 : nil }
    }

    private var radialPlan: RadialSlicePlan? {
        guard hasSelectedConstructionTechnique, sliceComputationEnabled, let model = planningModel else { return nil }
        return RadialSlicePlanner.plan(
            model: model,
            nRadial: radialSliceCount,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            slotAngleDegrees: slotAngleDegrees,
            firstAxisCountOverride: radialFirstAxisByDistance ? nil : radialFirstAxisCount,
            firstAxisSpacingOverride: radialFirstAxisByDistance ? radialFirstAxisSpacing : nil,
            notchFactor: radialNotchFactor,
            reliefType: radialReliefType,
            toolDiameter: materialToolDiameter
        ).flatMap { $0.totalPartCount <= Self.maxGuiSliceCount ? $0 : nil }
    }

    /// The Curve plan as cut: with first-axis ribs moved off the even
    /// spacing where that joins parts held only among themselves
    /// (`CurveSlicePlanner.joiningGroups`). That takes a full joint pass, so it
    /// is done off the main thread with the cut sheet
    /// (`rebuildCutSheetDocument`) and cached; until it lands the plan as laid
    /// out stands in.
    private var curvePlan: CurveSlicePlan? {
        _ = curvePlanRevision
        guard let plan = curveLayoutPlan, let model = planningModel else { return nil }
        return ViewportGeometryCache.shared.cachedJoinedCurvePlan(for: plan, model: model) ?? plan
    }

    /// The Curve plan as cut, joined now if it is not yet (exports must never
    /// write the stand-in).
    private func currentCurvePlan() -> CurveSlicePlan? {
        guard let plan = curveLayoutPlan, let model = planningModel else { return nil }
        return ViewportGeometryCache.shared.joinedCurvePlan(for: plan, model: model)
    }

    /// The Curve plan as laid out, every first-axis rib at even spacing.
    private var curveLayoutPlan: CurveSlicePlan? {
        guard hasSelectedConstructionTechnique, sliceComputationEnabled, let model = planningModel else { return nil }
        return CurveSlicePlanner.plan(
            model: model,
            primaryAxis: curvePrimaryAxis,
            materialThickness: materialThickness,
            firstAxisCount: curveFirstAxisCount,
            curveSliceCount: curveSliceCount,
            amplitude: curveAmplitude,
            slotWidth: notchWidthOverride ?? materialThickness + slotClearance,
            slotAngleDegrees: slotAngleDegrees
        ).flatMap { $0.totalPartCount <= Self.maxGuiSliceCount ? $0 : nil }
    }

    private var threeDPlan: ThreeDSlicePlan? {
        guard hasSelectedConstructionTechnique, sliceComputationEnabled, let model = planningModel else { return nil }
        return ThreeDSlicePlanner.plan(
            model: model,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            notchWidthOverride: notchWidthOverride,
            slotAngleDegrees: slotAngleDegrees,
            sliceDepth: threeDSliceDepth,
            sliceCountOverride: sliceCountOverride
        ).flatMap { $0.sliceCount <= Self.maxGuiSliceCount ? $0 : nil }
    }

    /// Folded Panels unfolds one panel PER MESH FACE. On a dense scanned mesh
    /// (the owner's 497k-face hand) the planner alone takes ~52s on the main
    /// thread and would emit ~480k parts — an effective hang. Dense meshes
    /// now go through MeshSimplifier first (a simplified shape around the
    /// object); this cap only refuses inputs too large to even
    /// simplify interactively.
    static let foldedPanelFaceLimit = 2_000_000

    private var foldedPanelsUnavailableReason: String? {
        guard hasSelectedConstructionTechnique, constructionMode == .foldedPanels, let model = effectiveModel else { return nil }
        if model.faceCount > Self.foldedPanelFaceLimit {
            return "This model has \(model.faceCount) faces — too many to simplify interactively. Reduce it in a mesh tool first."
        }
        return nil
    }

    /// Rotation-FREE input to folding: the model with scale (and an active
    /// Modify tool) but WITHOUT the Object-Size rotation. Simplification and
    /// folding are orientation-independent, so caching by this lets rotating
    /// the model reuse the QEM result instead of re-decimating the whole scan
    /// every time (rotating used to re-run the whole simplification). When a Modify
    /// tool is active its result already bakes the rotation, so we keep that
    /// (rotation re-simplifies, but modify+fold is the rare path).
    private var foldedSimplifyBase: MeshSummary? {
        guard let model else { return nil }
        if modifyActiveTool != nil { return effectiveModel }
        return ViewportGeometryCache.shared.transformedModel(
            for: model, scale: effectiveScale, rotationDegrees: Vec3(x: 0, y: 0, z: 0))
    }

    /// Rotation applied to the (cheap) simplified base to orient the folded
    /// preview to the displayed model. Zero on the modify path (already baked).
    private var foldedDisplayRotation: Vec3 {
        modifyActiveTool != nil ? Vec3(x: 0, y: 0, z: 0) : modelRotationDegrees
    }

    /// The mesh Folded Panels actually folds: the simplified base oriented to
    /// the display rotation. The expensive pre-clean is cached rotation-free; only
    /// the cheap ≤Detail-vertex rotation runs per orientation.
    private var foldedSourceModel: MeshSummary? {
        guard let base = foldedSimplifyBase else { return nil }
        let rotation = foldedDisplayRotation
        func oriented(_ mesh: MeshSummary) -> MeshSummary {
            rotation == Vec3(x: 0, y: 0, z: 0)
                ? mesh
                : MeshScaler.transformed(mesh, scale: Vec3(x: 1, y: 1, z: 1), rotationDegrees: rotation)
        }
        guard base.faceCount > foldedDetailFaces else { return oriented(base) }
        let key = "\(ViewportGeometryCache.modelKey(for: base))|fold|\(foldedDetailFaces)"
        guard let simplified = ViewportGeometryCache.shared.cachedSimplifiedMesh(key: key) else { return nil }
        return oriented(simplified)
    }

    private struct FoldedSimplifyKey: Equatable {
        var modelKey: String?
        var targetFaces: Int
        var wanted: Bool
    }

    private var foldedSimplifyKey: FoldedSimplifyKey {
        FoldedSimplifyKey(
            // Rotation-free base key → the simplify task doesn't re-fire when
            // only the Object-Size rotation changes.
            modelKey: foldedSimplifyBase.map(ViewportGeometryCache.modelKey(for:)),
            targetFaces: foldedDetailFaces,
            // Not gated on the Slice action: the folded shape preview is just
            // the simplified mesh, so it must build as soon as Folded is picked
            // — otherwise the viewport shows the smooth original until Slice.
            wanted: constructionMode == .foldedPanels
                && hasSelectedConstructionTechnique
                && foldedPanelsUnavailableReason == nil
                && (foldedSimplifyBase?.faceCount ?? 0) > foldedDetailFaces
        )
    }

    /// Manifold pre-clean on a dense scan takes seconds — never on the main thread. The
    /// cache makes the plan property cheap once this lands.
    @MainActor
    private func buildFoldedSimplificationIfNeeded() async {
        // Simplify the rotation-FREE base so rotating the model reuses the
        // result (the key matches foldedSourceModel's).
        guard foldedSimplifyKey.wanted, let base = foldedSimplifyBase else { return }
        let target = foldedDetailFaces
        let key = "\(ViewportGeometryCache.modelKey(for: base))|fold|\(target)"
        guard ViewportGeometryCache.shared.cachedSimplifiedMesh(key: key) == nil else { return }
        let simplified = await Task.detached(priority: .userInitiated) {
            FoldedMeshPrecleaner.preclean(base, targetFaceCount: target)
        }.value
        guard let simplified else { return }
        ViewportGeometryCache.shared.storeSimplifiedMesh(simplified, key: key)
        foldedSimplifyRevision += 1
    }

    /// Everything the Folded planner reads. NOT gated on
    /// sliceComputationEnabled: the folded faceted shape is the simplified
    /// mesh and must show in the viewport as soon as Folded is selected (the
    /// viewport was falling back to the smooth original until you pressed
    /// Slice).
    private var foldedPlanRequest: FoldedPlanRequest? {
        guard foldedPanelsUnavailableReason == nil,
              hasSelectedConstructionTechnique,
              let model = foldedSourceModel else { return nil }
        _ = foldedSimplifyRevision // plan re-derives when a simplification lands
        // Split Panels (the Simplify Form option) halves the
        // usable net extent so the unfold splits into smaller panels.
        let splitDivisor = foldedSplitPanels ? 2.0 : 1.0
        let usableExtent = Vec2(
            x: max(exportSheetWidth - exportPageMargin * 2, 1) / splitDivisor,
            y: max(exportSheetHeight - exportPageMargin * 2, 1) / splitDivisor
        )
        return FoldedPlanRequest(
            model: model,
            joinery: foldedJoinery.sanitized,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            maxNetExtent: usableExtent,
            seamEdges: foldedSeamEdges
        )
    }

    /// The Folded plan for the current settings once it is built (off the
    /// main thread, `buildFoldedPlanIfNeeded`); until then the last plan
    /// built for this model stands in.
    private var foldedPanelPlan: FoldedPanelPlan? {
        _ = foldedPlanRevision
        guard let request = foldedPlanRequest else { return nil }
        return ViewportGeometryCache.shared.cachedFoldedPlan(key: request.key)
            ?? ViewportGeometryCache.shared.latestFoldedPlan(modelKey: request.modelKey)
    }

    /// Whether every net of the current (unsplit) Folded plan already fits
    /// in half the usable sheet: Split Panels would then change nothing.
    private var foldedNetsFitHalfSheet: Bool {
        guard !foldedSplitPanels, let plan = foldedPanelPlan, !plan.nets.isEmpty else { return false }
        let halfWidth = max(exportSheetWidth - exportPageMargin * 2, 1) / 2
        let halfHeight = max(exportSheetHeight - exportPageMargin * 2, 1) / 2
        return plan.nets.allSatisfy { net in
            let bounds = net.bounds
            return bounds.max.x - bounds.min.x <= halfWidth && bounds.max.y - bounds.min.y <= halfHeight
        }
    }

    /// The Folded plan for exactly the current settings, built now if it is
    /// not yet (exports must never write a stand-in).
    private func currentFoldedPanelPlan() -> FoldedPanelPlan? {
        guard let request = foldedPlanRequest else { return nil }
        if let plan = ViewportGeometryCache.shared.cachedFoldedPlan(key: request.key) {
            return plan
        }
        let plan = request.plan()
        ViewportGeometryCache.shared.storeFoldedPlan(plan, key: request.key, modelKey: request.modelKey)
        return plan
    }

    /// Cutting the panels back for the stock takes a while on a detailed
    /// model: never on the main thread.
    @MainActor
    private func buildFoldedPlanIfNeeded() async {
        guard let request = foldedPlanRequest,
              ViewportGeometryCache.shared.cachedFoldedPlan(key: request.key) == nil else { return }
        let plan = await Task.detached(priority: .userInitiated) {
            request.plan()
        }.value
        guard !Task.isCancelled else { return }
        ViewportGeometryCache.shared.storeFoldedPlan(plan, key: request.key, modelKey: request.modelKey)
        foldedPlanRevision += 1
    }

    @State private var customDowelPositions: [Vec2] = []
    /// Folded Panels Detail target: the polygon budget of the simplified
    /// approximating shape that dense meshes are reduced to.
    @State private var foldedDetailFaces = 250
    @State private var foldedSimplifyRevision = 0
    @State private var foldedPlanRevision = 0
    /// Bumped when a joined Curve plan lands in the cache (`curvePlan`).
    @State private var curvePlanRevision = 0
    /// Folded joinery configuration (Joint Type + per-type parameters). The
    /// GUI default is Diamond, the first Joint Type in the menu; the headless
    /// default stays `tab`.
    @State private var foldedJoinery: JoineryParameters = .preset(for: .diamond)
    /// Simplify Form "Split Panels": halves the usable net extent so the
    /// unfold splits into smaller, simpler panels.
    @State private var foldedSplitPanels = false
    /// Add/Remove Seams: mesh edges forced to CUT in the unfolded net.
    @State private var foldedSeamEdges: [FoldedSeamEdge] = []
    /// Add/Remove Seams edit mode: while on, viewport clicks toggle seams on
    /// panel-boundary edges instead of orbiting.
    @State private var foldedSeamEditMode = false

    /// Toggle a seam on the clicked mesh edge: clicking an existing seam
    /// edge removes it (merging panels back), any other edge adds one.
    private func toggleFoldedSeamEdge(_ edge: FoldedSeamEdge) {
        func samePoint(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
            abs(lhs.x - rhs.x) < 1.0e-6 && abs(lhs.y - rhs.y) < 1.0e-6 && abs(lhs.z - rhs.z) < 1.0e-6
        }
        func sameEdge(_ lhs: FoldedSeamEdge, _ rhs: FoldedSeamEdge) -> Bool {
            (samePoint(lhs.a, rhs.a) && samePoint(lhs.b, rhs.b))
                || (samePoint(lhs.a, rhs.b) && samePoint(lhs.b, rhs.a))
        }
        if let index = foldedSeamEdges.firstIndex(where: { sameEdge($0, edge) }) {
            foldedSeamEdges.remove(at: index)
        } else {
            foldedSeamEdges.append(edge)
        }
    }
    /// RealityKit re-renders every display refresh with no pause API
    /// (NEO-91). When no app window is visible, nobody can see the viewport
    /// — unmount it so the app idles near 0% instead of burning a core.
    @State private var viewportOccluded = false
    /// Placement mode. Automatic dowels show the moment you open the Dowels
    /// pane (the "Automatic" button just *regenerates* that default layout).
    /// So a fresh model starts `true` → rods appear
    /// immediately. The first edit — add, move, delete, or pressing Automatic —
    /// flips to `false` (manual), after which the explicit list is authoritative
    /// INCLUDING when it's empty: deleting the last rod stays at zero and does
    /// NOT resurrect the automatic layout (the NEO-113 bug).
    @State private var dowelUseAutomatic = true
    @State private var dowelAutomaticCount = 2
    @State private var dowelShape: DowelShape = .round
    /// Dowel edit mode: while on, viewport clicks edit dowel rods instead of
    /// orbiting.
    @State private var dowelEditMode3D = false
    @State private var selectedDowelPlan: Vec2? = nil

    private var dowelSettings: DxfExporter.DowelSettings {
        DxfExporter.DowelSettings(
            enabled: dowelsEnabled,
            diameter: dowelDiameter,
            inset: dowelInset,
            // An EMPTY manual list means zero rods — it must NOT fall back to
            // nil/automatic, or deleting the last rod resurrects the automatic
            // layout ("un-deletable dowels").
            manualPositions: dowelUseAutomatic ? nil : customDowelPositions,
            shape: dowelShape,
            automaticCount: dowelAutomaticCount
        )
    }

    /// Click on the sliced model in dowel-edit mode (already mapped to plan
    /// coordinates): adds a rod through the stack there.
    /// Threshold for "same spot" / grab radius in plan-space (mm). One hole
    /// per spot; can't grab/stack rods closer than this.
    private var dowelEditThreshold: Double { max(dowelDiameter, 6.0) }

    /// The rod list to edit: the resolved automatic layout (materialized into
    /// editable markers on first touch) or the manual list. An empty manual
    /// list stays empty — zero rods is a valid state (no auto-resurrect).
    private var editableDowelPositions: [Vec2] {
        dowelUseAutomatic ? currentAutomaticDowelPositions() : customDowelPositions
    }

    /// Click on the light-blue plane in dowel-edit mode (mapped to plan
    /// coordinates): adds a rod through the stack there.
    private func handleDowelAdd(planPoint: Vec2) {
        guard constructionMode == .stacked, dowelsEnabled else { return }
        guard let positions = DowelEditing.add(
            planPoint, to: editableDowelPositions,
            threshold: dowelEditThreshold, covers: planPositionCoversAnyLayer
        ) else { return }
        customDowelPositions = positions
        dowelUseAutomatic = false
        selectedDowelPlan = planPoint
    }

    /// Remove the rod nearest this plan point (Delete key on the selected
    /// rod, or Control-click).
    private func handleDowelRemove(near planPoint: Vec2) {
        guard constructionMode == .stacked, dowelsEnabled else { return }
        guard let positions = DowelEditing.remove(
            near: planPoint, from: editableDowelPositions, threshold: dowelEditThreshold
        ) else { return }
        customDowelPositions = positions
        dowelUseAutomatic = false
        selectedDowelPlan = nil
    }

    /// Drag a rod: relocate the rod grabbed at `from` to `to` (plan
    /// coordinates). Rejected if `to` lands in no slice's material.
    private func handleDowelMove(from: Vec2, to: Vec2) {
        guard constructionMode == .stacked, dowelsEnabled else { return }
        guard let positions = DowelEditing.move(
            from: from, to: to, in: editableDowelPositions,
            threshold: dowelEditThreshold, covers: planPositionCoversAnyLayer
        ) else { return }
        customDowelPositions = positions
        dowelUseAutomatic = false
        selectedDowelPlan = to
    }

    // MARK: - NEO-103 Slice Edit actions

    /// Add a slice at the midpoint of the largest gap between consecutive slices.
    private func handleSliceAdd() {
        guard let plan = slicePlan else { return }
        let positions = plan.positions
        guard !positions.isEmpty else { return }
        // Find largest gap: if only one slice, insert at midpoint of range.
        var insertPos: Double
        if positions.count == 1 {
            let gap0 = positions[0] - plan.rangeMin
            let gap1 = plan.rangeMax - positions[0]
            insertPos = gap0 >= gap1 ? plan.rangeMin + gap0 / 2 : positions[0] + gap1 / 2
        } else {
            // Pad with range endpoints to find gaps at the boundaries too.
            let pts = [plan.rangeMin] + positions + [plan.rangeMax]
            var largestGap = 0.0
            var gapIndex = 0
            for i in 0..<(pts.count - 1) {
                let g = pts[i + 1] - pts[i]
                if g > largestGap { largestGap = g; gapIndex = i }
            }
            insertPos = (pts[gapIndex] + pts[gapIndex + 1]) / 2
        }
        var newPositions = positions
        newPositions.append(insertPos)
        newPositions.sort()
        customSlicePositions = newPositions
        sliceDistributionMethod = .custom
    }

    /// Delete the slice at `index` from the custom positions list.
    private func handleSliceDelete(index: Int?) {
        guard let plan = slicePlan,
              let idx = index,
              plan.positions.indices.contains(idx) else { return }
        var newPositions = plan.positions
        newPositions.remove(at: idx)
        customSlicePositions = newPositions
        sliceDistributionMethod = newPositions.isEmpty ? .automatic : .custom
        selectedSliceIndex = nil
    }

    /// Reset to uniform distribution — clears the Custom override.
    private func handleSliceDistributeEvenly() {
        customSlicePositions = []
        if sliceDistributionMethod == .custom {
            sliceDistributionMethod = .byCount
        }
        selectedSliceIndex = nil
    }

    /// Called from viewport when the user clicks a slice solid in slice-edit mode.
    private func handleSliceSelect(index: Int?) {
        guard sliceEditMode3D else { return }
        selectedSliceIndex = index
    }

    /// Called from viewport when the user drags a selected slice to a new axis position.
    private func handleSliceMoveCommit(index: Int, toAxisPosition: Double) {
        guard let plan = slicePlan, plan.positions.indices.contains(index) else { return }
        var newPositions = plan.positions
        newPositions[index] = toAxisPosition
        newPositions.sort()
        customSlicePositions = newPositions
        sliceDistributionMethod = .custom
        // Recompute which index the moved slice is at after re-sort.
        if let newIdx = newPositions.firstIndex(of: toAxisPosition) {
            selectedSliceIndex = newIdx
        }
    }

    private func planPositionCoversAnyLayer(_ position: Vec2) -> Bool {
        guard let model = planningModel, let plan = slicePlan else { return false }
        // The layers the exports drill: closed across any cracks.
        let contours = ViewportGeometryCache.shared.stackedClosedContours(model: model, plan: plan)
        return contours.layers.contains { layer in
            !DowelLayout.positionsCovered(by: layer, positions: [position]).isEmpty
        }
    }

    private func currentAutomaticDowelPositions() -> [Vec2] {
        guard let model = planningModel, let plan = slicePlan else { return [] }
        var automatic = dowelSettings
        automatic.manualPositions = nil
        return ViewportGeometryCache.shared.dowelPlacements(model: model, plan: plan, settings: automatic).map(\.position)
    }

    /// The five mutually-exclusive viewport-interaction modes — each a
    /// separate panel toggle, but only one can own the mouse at a time.
    private enum ViewportInteractionMode {
        case sliceDirection, modelRotate, dowelEdit, sliceEdit, seamEdit
    }

    /// Disarm every viewport-interaction mode except `keep` (just armed).
    private func exclusiveViewportMode(keep: ViewportInteractionMode) {
        if keep != .sliceDirection { sliceDirectionAdjustMode = false }
        if keep != .modelRotate { modelRotateGizmoActive = false }
        if keep != .dowelEdit { dowelEditMode3D = false }
        if keep != .sliceEdit { sliceEditMode3D = false }
        if keep != .seamEdit { foldedSeamEditMode = false }
    }

    /// One-line interaction hint shown at the bottom of the viewport while an
    /// edit mode is active — the instructions live where the user is looking,
    /// not buried in a tooltip.
    private var viewportEditHint: String? {
        // The rotation rings only need a model, not a finished slice pass.
        if modelRotateGizmoActive && model != nil {
            return viewportCamera.isOrthographic
                ? "Editing pauses in orthographic views — pick a corner view on the cube to resume."
                : "Drag a ring to rotate the model — red X · green Y · blue Z. Ring snaps to 5°, handle is fine. Empty space orbits."
        }
        guard viewportPreviewMode.showsSlicePreview, sliceComputationEnabled else { return nil }
        let editToggled = (constructionMode == .stacked && dowelsEnabled && dowelEditMode3D)
            || (constructionMode == .stacked && sliceEditMode3D)
            || (constructionMode == .foldedPanels && foldedSeamEditMode)
        if viewportCamera.isOrthographic {
            return editToggled
                ? "Editing pauses in orthographic views — pick a corner view on the cube to resume."
                : nil
        }
        if constructionMode == .stacked && dowelsEnabled && dowelEditMode3D {
            return customDowelPositions.isEmpty && !dowelUseAutomatic
                ? "Click inside the blue placement frame to add a rod — or press Automatic in the Dowels panel."
                : "Drag a rod to move it · click selects · ⌃-click or ⌫ deletes · empty space orbits."
        }
        if constructionMode == .stacked && sliceEditMode3D {
            return "Drag a slice to move it along the stack · empty space orbits the camera."
        }
        if constructionMode == .foldedPanels && foldedSeamEditMode {
            return "Click a panel edge to add or remove a seam there."
        }
        return nil
    }

    private var slotReliefSettings: SlotReliefSettings {
        SlotReliefSettings(enabled: slotReliefEnabled, diameter: materialToolDiameter)
    }

    private var exportLayoutSettings: ExportLayoutSettings {
        ExportLayoutSettings(
            partSpacing: exportPartSpacing,
            pageMargin: exportPageMargin,
            sheetWidth: exportSheetWidth,
            sheetHeight: exportSheetHeight
        )
        .sanitized
    }

    /// The steps of the parts the export holds: steps of slices left out
    /// whole are dropped (`AssemblyStepPlanner.exported`).
    private var assemblySteps: [AssemblyStep] {
        // Only a cut sheet built from what is planned now says which steps
        // have parts.
        AssemblyStepPlanner.exported(
            plannedAssemblySteps,
            stepIndices: exportedStepIndicesKey == cutSheetBuildKey ? exportedStepIndices : nil
        )
    }

    private var plannedAssemblySteps: [AssemblyStep] {
        switch constructionMode {
        case .stacked:
            return slicePlan.map(AssemblyStepPlanner.steps(stacked:)) ?? []
        case .interlocked:
            return interlockedPlan.map(AssemblyStepPlanner.steps(interlocked:)) ?? []
        case .radial:
            return radialPlan.map(AssemblyStepPlanner.steps(radial:)) ?? []
        case .curve:
            return curvePlan.map(AssemblyStepPlanner.steps(curve:)) ?? []
        case .threeD:
            return threeDPlan.map(AssemblyStepPlanner.steps(threeD:)) ?? []
        case .foldedPanels:
            return foldedPanelPlan.map(AssemblyStepPlanner.steps(folded:)) ?? []
        case .inflatables, .structures, .partition, .motherMold:
            // Explicit-generate outputs that do not use the slice assembly
            // sequence.
            return []
        }
    }

    private var selectedAssemblyStepHighlight: AssemblyStepHighlight? {
        AssemblyStepHighlighter.highlight(
            selectedStepID: selectedAssemblyStepID,
            mode: constructionMode,
            slicePlans: previewPlans,
            radialPlan: previewRadialPlan,
            curvePlan: previewCurvePlan,
            foldedPanelPlan: previewFoldedPanelPlan
        )
    }

    private var previewPlans: [StackedSlicePlan] {
        switch constructionMode {
        case .stacked:
            return slicePlan.map { [$0] } ?? []
        case .interlocked:
            guard let interlockedPlan else { return [] }
            return [interlockedPlan.primary, interlockedPlan.secondary]
        case .radial:
            return []
        case .curve:
            return []
        case .threeD:
            return threeDPlan?.plans ?? []
        case .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return []
        }
    }

    private var previewRadialPlan: RadialSlicePlan? {
        switch constructionMode {
        case .stacked, .interlocked, .curve, .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        case .radial:
            return radialPlan
        }
    }

    private var previewInterlockedPlan: InterlockedSlicePlan? {
        switch constructionMode {
        case .interlocked:
            return interlockedPlan
        case .stacked, .radial, .curve, .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        }
    }

    private var previewThreeDPlan: ThreeDSlicePlan? {
        switch constructionMode {
        case .threeD:
            return threeDPlan
        case .stacked, .interlocked, .radial, .curve, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        }
    }

    private var previewCurvePlan: CurveSlicePlan? {
        switch constructionMode {
        case .stacked, .interlocked, .radial, .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        case .curve:
            return curvePlan
        }
    }

    private var previewFoldedPanelPlan: FoldedPanelPlan? {
        switch constructionMode {
        case .stacked, .interlocked, .radial, .curve, .threeD, .inflatables, .structures, .partition, .motherMold:
            return nil
        case .foldedPanels:
            return foldedPanelPlan
        }
    }

    private var previewInflatablesPlan: InflatablesPlan? {
        switch constructionMode {
        case .inflatables:
            return displayedInflatablesPlan
        case .stacked, .interlocked, .radial, .curve, .threeD, .foldedPanels, .structures, .partition, .motherMold:
            return nil
        }
    }

    private var viewportBounds: Bounds3D? {
        ViewportSceneBounds.bounds(
            modelBounds: effectiveModel?.bounds,
            foldedPanelPlan: viewportPreviewMode.showsSlicePreview ? previewFoldedPanelPlan : nil,
            inflatablePlan: viewportPreviewMode.showsSlicePreview ? previewInflatablesPlan : nil,
            materialThickness: materialThickness
        )
    }

    private var viewportCameraFitContext: ViewportCameraFitContext {
        ViewportCameraFitContext(
            modelPath: model?.path,
            constructionMode: constructionMode,
            previewMode: viewportPreviewMode
        )
    }

    var body: some View {
        // HSplitView so every pane — left rail, workspace, stats — has a real
        // draggable divider (the native `.inspector` column was not resizable
        // in practice).
        HSplitView {
            if isSidebarVisible {
                sidebar
                    // Wider rail: the control labels + fields were cramped at
                    // 320 (still too small in use). Roomier default, and a
                    // high cap so it can be dragged wide.
                    // Every rail control fits down to 260 pt (layout audit:
                    // REFAB_LAYOUT_AUDIT), so the 320 minimum has margin;
                    // SplitPaneMinimumWidth makes the divider honour it.
                    .frame(minWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.rail : 320,
                           idealWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.rail : 420,
                           maxWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.rail : 640)
                    .background(SplitPaneMinimumWidth(minWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.rail : 320))
            }
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if isStatsVisible, effectiveModel != nil {
                statsInspector
                    .frame(minWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.inspector : 300,
                           idealWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.inspector : 340,
                           maxWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.inspector : 460)
                    .background(SplitPaneMinimumWidth(minWidth: LayoutOverflowAudit.isEnabled ? LayoutOverflowAudit.paneWidths.inspector : 300))
            }
        }
            // Floor clears rail(320) + detail(480) + stats(300) = 1100 with
            // headroom, so no pane is squeezed on launch.
            .frame(minWidth: 1260, minHeight: 760)
            .onAppear {
                applySectionDefaultMigration()
                SpaceMouseController.shared.start()
                if LayoutOverflowAudit.isEnabled {
                    Task { await runLayoutOverflowAudit() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                let anyWindowVisible = NSApp.windows.contains {
                    $0.isVisible && $0.occlusionState.contains(.visible)
                }
                if viewportOccluded != !anyWindowVisible {
                    viewportOccluded = !anyWindowVisible
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SpaceMouseController.motionNotification)) { note in
                guard let raw = note.object as? SpaceMouseController.Motion, effectiveModel != nil else { return }
                // Low-pass blend + speed. Smoothing cancels the driver's
                // Dominant-Axis "zipper" (it alternates axes on a diagonal push)
                // by averaging consecutive samples so both axes stay live.
                let a = max(0.08, 1 - 0.9 * spaceMouseSmoothing)
                let speed = spaceMouseSpeed * 2
                spaceMouseSmoothed = SpaceMouseController.Motion(
                    tx: spaceMouseSmoothed.tx + a * (raw.tx - spaceMouseSmoothed.tx),
                    ty: spaceMouseSmoothed.ty + a * (raw.ty - spaceMouseSmoothed.ty),
                    tz: spaceMouseSmoothed.tz + a * (raw.tz - spaceMouseSmoothed.tz),
                    rx: spaceMouseSmoothed.rx + a * (raw.rx - spaceMouseSmoothed.rx),
                    ry: spaceMouseSmoothed.ry + a * (raw.ry - spaceMouseSmoothed.ry),
                    rz: spaceMouseSmoothed.rz + a * (raw.rz - spaceMouseSmoothed.rz)
                )
                let motion = SpaceMouseController.Motion(
                    tx: spaceMouseSmoothed.tx * speed, ty: spaceMouseSmoothed.ty * speed,
                    tz: spaceMouseSmoothed.tz * speed, rx: spaceMouseSmoothed.rx * speed,
                    ry: spaceMouseSmoothed.ry * speed, rz: spaceMouseSmoothed.rz * speed
                )
                // Axis identities are pinned in SpaceMouseMapping.
                let deltas = SpaceMouseMapping.cameraDeltas(for: motion)
                // All SpaceMouse rotations spin the SCULPTURE about screen axes,
                // so they stay consistent at any roll and never tilt the camera.
                if deltas.orbitX != 0 { viewportCamera.spinYaw(delta: deltas.orbitX) }
                if deltas.orbitY != 0 { viewportCamera.spinPitch(delta: deltas.orbitY) }
                if deltas.roll != 0 { viewportCamera.roll(delta: deltas.roll) }
                if deltas.panX != 0 || deltas.panY != 0 {
                    viewportCamera.pan(
                        deltaX: deltas.panX,
                        deltaY: deltas.panY,
                        radius: ViewportCamera.radius(bounds: viewportBounds)
                    )
                }
                if deltas.zoom != 0 {
                    viewportCamera.zoom(scrollDeltaY: deltas.zoom)
                }
            }
            .task(id: foldedSimplifyKey) {
                await buildFoldedSimplificationIfNeeded()
            }
            .task(id: foldedPlanRequest?.key) {
                await buildFoldedPlanIfNeeded()
            }
            .task(id: diagnosisKey) {
                refreshModifiedFormForCurrentModel()
                await refreshOpeningDiagnosis()
            }
            .task(id: importedTopologyKey) {
                await refreshImportedTopology()
            }
            .task(id: cutSheetBuildKey) {
                await rebuildCutSheetDocument()
            }
            .task(id: motherMoldPrebuildOverlaySignature) {
                await rebuildMotherMoldPrebuildOverlay()
            }
            .alert("Import failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: constructionMode) { old, mode in
                var resolved = ExportFormatSupport.normalized(format: exportFormat, for: mode)
                // Leaving a mesh-only mode (Structures / Partition / MotherMold
                // force STL/OBJ) for a laser-cut mode: a carried-over mesh format
                // would suppress the flat cut-sheet preview (it only builds for a
                // vector layout), leaving the sheet view blank / "open sheet"
                // disabled. Reset to a vector default so the sheet shows again.
                if old.isMeshOnly, !mode.isMeshOnly, !resolved.usesVectorLayout {
                    resolved = .dxf
                }
                exportFormat = resolved
                selectedAssemblyStepID = nil
                lastExportFailure = nil
                if mode != .motherMold {
                    if old == .motherMold {
                        cancelMotherMoldBuild(showMessage: false)
                    }
                    motherMoldExploded = false
                    motherMoldShowUndercuts = false
                    isolatedMotherMoldPartName = nil
                }
            }
            // NEO-114: every undoable control writes into projectSettings, so
            // this single hook records all of them (coalesced per burst).
            .onChange(of: projectSettings) { old, new in
                recordSettingsChange(old: old, new: new)
            }
            // Acceptance-review polish: only ONE viewport-interaction mode may
            // be armed at a time. Otherwise two ring sets render at once and
            // the mouse-down precedence silently steals clicks from whichever
            // mode the user thinks is active. Activating one disarms the rest.
            // (Each guard fires only on the false→true edge, so disarming the
            // others can't loop.)
            .onChange(of: sliceDirectionAdjustMode) { _, on in
                if on { exclusiveViewportMode(keep: .sliceDirection) }
            }
            .onChange(of: modelRotateGizmoActive) { _, on in
                if on { exclusiveViewportMode(keep: .modelRotate) }
            }
            .onChange(of: dowelEditMode3D) { _, on in
                if on { exclusiveViewportMode(keep: .dowelEdit) }
            }
            .onChange(of: sliceEditMode3D) { _, on in
                if on { exclusiveViewportMode(keep: .sliceEdit) }
            }
            .onChange(of: foldedSeamEditMode) { _, on in
                if on { exclusiveViewportMode(keep: .seamEdit) }
            }
            .onChange(of: viewportCameraFitContext) {
                viewportCamera.reset()
            }
            .onChange(of: exportFormat) { _, format in
                if !format.usesVectorLayout {
                    viewportMode = .model3D
                }
                lastExportFailure = nil
            }
            .onChange(of: model == nil) { _, isEmpty in
                if isEmpty {
                    hasSelectedConstructionTechnique = false
                    isTechniqueChooserExpanded = false
                    sliceComputationEnabled = false
                    viewportMode = .model3D
                    selectedAssemblyStepID = nil
                    cutSheetDocument = nil
                    builtSheetNotes = []
                    exportedStepIndices = nil
                }
            }
            .onChange(of: assemblySteps) { _, steps in
                selectedAssemblyStepID = AssemblyStepNavigation.normalizedSelection(selectedAssemblyStepID, steps: steps)
            }
            .onChange(of: sliceInputSignature) { old, new in
                // Dowel-only changes don't touch the slice plan, and slice
                // direction auto-reslices (the plan recomputes while the gate
                // stays armed) — neither forces a manual re-slice. Everything
                // else disarms the gate so a heavy recompute waits for Slice.
                guard !new.sameSlicePlanGate(as: old) else { return }
                sliceComputationEnabled = false
            }
            .focusedSceneValue(\.slicerCommandActions, commandActions)
    }

    private var commandActions: SlicerCommandActions {
        SlicerCommandActions(
            undo: performUndo,
            redo: performRedo,
            importModel: importModel,
            loadSampleModel: loadSampleModel,
            openProject: openProject,
            saveProject: saveProject,
            exportCurrent: exportCurrent,
            exportAssemblyGuide: exportAssemblyGuide,
            printSheets: printCutSheets,
            exportSlicedMesh: exportSlicedMesh,
            toggleSidebar: {
                isSidebarVisible.toggle()
            },
            showModelView: {
                viewportMode = .model3D
            },
            showSheetPreview: {
                if cutSheetDocument != nil {
                    viewportMode = .sheet2D
                }
            },
            showCombinedView: {
                if cutSheetDocument != nil {
                    viewportMode = .modelAndSheet
                }
            },
            previewModelOnly: {
                viewportPreviewMode = .model
            },
            previewSlicesOnly: {
                viewportPreviewMode = .slices
            },
            previewModelAndSlices: {
                viewportPreviewMode = .modelAndSlices
            },
            canSaveProject: model != nil && hasSelectedConstructionTechnique,
            canExport: !exportDisabled,
            canExportAssemblyGuide: assemblyGuideContext != nil && !assemblySteps.isEmpty,
            canPrint: cutSheetDocument != nil,
            canExportSlicedMesh: hasSelectedConstructionTechnique
                && ((constructionMode == .foldedPanels && foldedPanelPlan != nil)
                    || (constructionMode == .inflatables && displayedInflatablesPlan?.preview != nil)),
            canShowSheetPreview: cutSheetDocument != nil,
            hasModel: model != nil,
            canUndo: undoHistory.canUndo,
            canRedo: undoHistory.canRedo
        )
    }

    /// Everything that determines the cut-sheet document. Changing any field
    /// retriggers the async rebuild (`rebuildCutSheetDocument`).
    private struct CutSheetBuildKey: Equatable {
        var modelKey: String?
        /// The Folded plan the sheet is built from, once it is built.
        var foldedPlanKey: String?
        var signature: SliceInputSignature?
        var inflatablesSignature: InflatablesInputSignature?
        var settings: ExportLayoutSettings
        var enabled: Bool
        var usesVectorLayout: Bool
        /// Dowel edits rebuild the document WITHOUT re-arming the Slice gate
        /// (they don't change the slice plan).
        var dowelPositions: [Vec2]
    }

    private var cutSheetBuildKey: CutSheetBuildKey {
        CutSheetBuildKey(
            modelKey: effectiveModel.map(ViewportGeometryCache.modelKey(for:)),
            foldedPlanKey: constructionMode == .foldedPanels
                ? foldedPlanRequest.flatMap { request in
                    ViewportGeometryCache.shared.cachedFoldedPlan(key: request.key) == nil ? nil : request.key
                }
                : nil,
            signature: sliceInputSignature,
            inflatablesSignature: constructionMode == .inflatables ? inflatablesInputSignature : nil,
            settings: exportLayoutSettings,
            enabled: hasSelectedConstructionTechnique && sliceComputationEnabled && activeModifyMeshReady && effectiveModel != nil,
            usesVectorLayout: exportFormat.usesVectorLayout,
            dowelPositions: customDowelPositions
        )
    }

    /// Build the cut-sheet document OFF the main thread and cache it. The old
    /// implementation regenerated contours from the full mesh inside a
    /// computed property on every SwiftUI render — the "opening the cut sheet
    /// makes everything slow" freeze.
    ///
    /// The document is built for the assembly steps too
    /// (`exportedStepIndices`), so with a mesh export format it is built
    /// but not shown.
    @MainActor
    private func rebuildCutSheetDocument() async {
        if constructionMode == .inflatables {
            cutSheetDocument = displayedInflatablesPlan?.cutSheet
            builtSheetNotes = []
            exportedStepIndices = nil
            return
        }
        // The parts are cut from the model the plans were laid out on
        // (turned into the slicing frame under a Slice Direction tilt), as
        // the viewport and every export cut them.
        guard hasSelectedConstructionTechnique,
              sliceComputationEnabled,
              activeModifyMeshReady,
              let model = planningModel else {
            cutSheetDocument = nil
            builtSheetNotes = []
            exportedStepIndices = nil
            return
        }
        let showsSheet = exportFormat.usesVectorLayout
        let buildKey = cutSheetBuildKey
        cutSheetRevisionCounter += 1
        let revision = cutSheetRevisionCounter
        let mode = constructionMode
        let settings = exportLayoutSettings
        let dowels = dowelSettings
        let stacked = mode == .stacked ? slicePlan : nil
        let interlocked = mode == .interlocked ? interlockedPlan : nil
        let radial = mode == .radial ? radialPlan : nil
        // The Curve plan as laid out: it is joined (`joiningGroups`) below,
        // off the main thread, unless that is already done.
        let curve = mode == .curve ? curveLayoutPlan : nil
        let threeD = mode == .threeD ? threeDPlan : nil
        let folded = mode == .foldedPanels
            ? foldedPlanRequest.flatMap { ViewportGeometryCache.shared.cachedFoldedPlan(key: $0.key) }
            : nil
        let inflatables = mode == .inflatables ? displayedInflatablesPlan : nil

        let document: CutSheetDocument? = await Task.detached(priority: .userInitiated) {
            let source: FlatPartExport.Source?
            switch mode {
            case .stacked:
                source = stacked.map { .stacked($0, contours: nil, dowels: dowels) }
            case .interlocked:
                source = interlocked.map { .interlocked($0) }
            case .radial:
                source = radial.map { .radial($0) }
            case .curve:
                source = curve.map { .curve(ViewportGeometryCache.shared.joinedCurvePlan(for: $0, model: model)) }
            case .threeD:
                source = threeD.map { .threeD($0) }
            case .foldedPanels:
                source = folded.map { .foldedPanels($0) }
            case .inflatables:
                source = inflatables.map { .inflatables($0) }
            case .structures, .partition, .motherMold:
                // Structures, Partition, and MotherMold are 3D meshes, not 2D
                // cut sheets.
                source = nil
            }
            return source.map {
                FlatPartExport.cutSheetDocument(for: $0, model: model, settings: settings, revision: revision)
            }
        }.value

        guard !Task.isCancelled, revision == cutSheetRevisionCounter else {
            return
        }
        cutSheetDocument = showsSheet ? document : nil
        builtSheetNotes = document?.notes ?? []
        exportedStepIndices = document.flatMap { AssemblyStepPlanner.stepIndices(in: $0, mode: mode) }
        exportedStepIndicesKey = buildKey
        if mode == .curve {
            // The joined Curve plan is cached now: the viewport, the steps
            // and the panel show it (`curvePlan`).
            curvePlanRevision += 1
        }
    }

    private var sidebar: some View {
        PaneColumn(name: "rail") {
            VStack(alignment: .leading, spacing: 14) {
                InspectorSection(section: .actions) {
                    inspectorActions
                }
                Divider()

                if effectiveModel != nil {
                    InspectorSection(section: .construction, isExpanded: sectionExpanded(.construction)) {
                        ConstructionTechniqueControl(
                            selection: hasSelectedConstructionTechnique ? constructionMode : nil,
                            // `current` is the live mode, not `selection`: a
                            // newly loaded model keeps the previous mode's
                            // panel up, so its card stays too. The layout
                            // audit lists every card without touching the
                            // saved setting.
                            modes: ConstructionMode.chooserModes(
                                showingExperimental: experimentalFeaturesEnabled || LayoutOverflowAudit.isEnabled,
                                current: constructionMode
                            ),
                            isExpanded: $isTechniqueChooserExpanded,
                            onSelect: selectConstructionTechnique
                        )
                    }
                    if constructionMode == .structures {
                        // Structures: infill/supports parameters, an explicit
                        // Generate action, and mesh-only (STL/OBJ) export. It
                        // does NOT use Slice Direction, dowels, the Slice gate,
                        // assembly steps, or the 2D cut sheet.
                        Divider()
                        InspectorSection(section: .structures, isExpanded: sectionExpanded(.structures)) {
                            StructuresPanel(settings: $structureSettings)
                        }
                        Divider()
                        structureGenerateSection
                        if generatedStructurePlan != nil {
                            Divider()
                            InspectorSection(section: .export, isExpanded: sectionExpanded(.export)) {
                                exportControls
                            }
                        }
                    } else if constructionMode == .partition {
                        // Partition: build-volume + auto/manual cut planes + key
                        // controls, an explicit Generate action, and mesh-only
                        // (STL/OBJ/zip) export. No Slice Direction, dowels, slice
                        // gate, assembly steps, or 2D cut sheet.
                        Divider()
                        InspectorSection(section: .constructionSettings, isExpanded: sectionExpanded(.constructionSettings)) {
                            PartitionPanel(
                                settings: $partitionSettings,
                                editIn3D: $partitionEditMode3D,
                                plan: displayedPartitionPlan,
                                modelBounds: effectiveModel?.bounds,
                                undercutPlan: displayedUndercutPlan,
                                undercutPlanIsStale: partitionResultIsStale,
                                undercutPlanningInProgress: isGeneratingPartition
                                    && partitionSettings.purpose == .splitByUndercuts,
                                undercutPlanningStartedAt: undercutPlanningStartedAt,
                                undercutEditIn3D: $undercutCutEditMode3D,
                                undercutFacePaintMode: $undercutFacePaintMode,
                                selectedCutNodeID: selectedUndercutCutNodeID,
                                selectedPieceRegionID: selectedUndercutPieceRegionID,
                                isolatedPieceRegionID: isolatedUndercutPieceRegionID,
                                onPlanningModeChange: setUndercutPlanningMode,
                                onCutNodeSelect: { selectedUndercutCutNodeID = $0 },
                                onCutNodeLockToggle: toggleUndercutCutNodeLock,
                                onCutNodeRotate: rotateUndercutCutNode,
                                onCutNodeDelete: deleteUndercutCutNode,
                                onPieceSelect: { selectedUndercutPieceRegionID = $0 },
                                onPieceIsolationToggle: toggleUndercutPieceIsolation,
                                onPiecePullLockToggle: toggleUndercutPiecePullLock,
                                onAddCut: addUndercutCut
                            )
                        }
                        Divider()
                        partitionGenerateSection
                        if generatedPartitionPlanForCurrentPurpose != nil {
                            Divider()
                            InspectorSection(section: .export, isExpanded: sectionExpanded(.export)) {
                                exportControls
                            }
                        }
                    } else if constructionMode == .motherMold {
                        // MotherMold: mold-type/shell/parting/keys/flanges/
                        // spout panels, an explicit Build mold action, and
                        // mesh-only (STL/OBJ) export. It does NOT use the
                        // Manufacturing panel, Slice Direction, dowels, the Slice
                        // gate, assembly steps, or the 2D cut sheet.
                        Divider()
                        InspectorSection(section: .motherMold, isExpanded: sectionExpanded(.motherMold)) {
                            MotherMoldPanel(
                                settings: $motherMoldSettings,
                                placementTarget: $motherMoldPlacementTarget,
                                plan: displayedMotherMoldPlan,
                                modelBounds: effectiveModel?.bounds,
                                isBuilding: isGeneratingMotherMold,
                                buildStage: motherMoldBuildStage,
                                buildStartedAt: motherMoldBuildStartedAt,
                                buildDisabledReason: motherMoldGenerateDisabledReason,
                                status: motherMoldBuildStatus,
                                buildDetailsExpanded: $motherMoldBuildDetailsExpanded,
                                hasBuilt: generatedMotherMoldPlan != nil,
                                build: generateMotherMold,
                                cancelBuild: { cancelMotherMoldBuild() },
                                statusAction: performMotherMoldRecovery
                            )
                        }
                        if let plan = displayedMotherMoldPlan {
                            Divider()
                            InspectorSection(section: .assembly, isExpanded: sectionExpanded(.assembly)) {
                                MotherMoldWorkflowPanel(
                                    plan: plan,
                                    settings: motherMoldSettings.sanitized,
                                    exploded: $motherMoldExploded,
                                    artistViewMode: $motherMoldArtistViewMode,
                                    visibleLayers: $motherMoldVisibleLayers
                                )
                            }
                        }
                        if generatedMotherMoldPlan?.parts.isEmpty == false {
                            Divider()
                            InspectorSection(section: .export, isExpanded: sectionExpanded(.export)) {
                                exportControls
                            }
                        }
                    } else if constructionMode == .inflatables {
                        Divider()
                        InspectorSection(section: .constructionSettings, isExpanded: sectionExpanded(.constructionSettings)) {
                            InflatablesPanel(
                                settings: $inflatablesSettings,
                                viewMode: $inflatablesViewMode,
                                plan: displayedInflatablesPlan,
                                selectedPanelID: selectedInflatablePanelID,
                                onDiagnosticSelect: { diagnostic in
                                    selectedInflatablePanelID = diagnostic.panelID
                                    if diagnostic.panelID != nil, inflatablesViewMode == .target {
                                        inflatablesViewMode = .inflated
                                    }
                                }
                            )
                        }
                        Divider()
                        inflatablesGenerateSection
                        if generatedInflatablesPlan != nil {
                            Divider()
                            InspectorSection(section: .export, isExpanded: sectionExpanded(.export)) {
                                exportControls
                            }
                        }
                    } else {

                    if hasSelectedConstructionTechnique {
                        // 3D Slices builds a layered mesh to print: no stock,
                        // slots or sheets, so nothing in Manufacturing
                        // Settings would change it (its panel says so).
                        if constructionMode != .threeD {
                            Divider()
                            InspectorSection(section: .manufacturing, isExpanded: sectionExpanded(.manufacturing)) {
                                ManufacturingSettingsPanel(
                                    materialPreset: $materialPreset,
                                    materialThickness: $materialThickness,
                                    slotClearance: $slotClearance,
                                    sheetWidth: $exportSheetWidth,
                                    sheetHeight: $exportSheetHeight,
                                    kerf: $materialKerf,
                                    toolDiameter: $materialToolDiameter,
                                    pageMargin: $exportPageMargin,
                                    slotOffsetState: ManufacturingRows.slotOffset(
                                        mode: constructionMode,
                                        notchWidthOn: notchWidthOverrideEnabled,
                                        foldedJoint: foldedJoinery.type
                                    ),
                                    toolDiameterState: ManufacturingRows.toolDiameter(
                                        mode: constructionMode,
                                        slotReliefOn: slotReliefEnabled,
                                        radialReliefType: radialReliefType
                                    )
                                )
                            }
                        }
                        Divider()
                        InspectorSection(section: .constructionSettings, isExpanded: sectionExpanded(.constructionSettings)) {
                            ConstructionPanel(
                                mode: $constructionMode,
                                plan: slicePlan,
                                interlockedPlan: interlockedPlan,
                                radialPlan: radialPlan,
                                curvePlan: curvePlan,
                                threeDPlan: threeDPlan,
                                foldedPanelPlan: foldedPanelPlan,
                                axis: $sliceAxis,
                                secondaryAxis: $secondarySliceAxis,
                                materialThickness: $materialThickness,
                                threeDSliceDepth: $threeDSliceDepth,
                                slotClearance: $slotClearance,
                                notchWidthOverrideEnabled: $notchWidthOverrideEnabled,
                                notchWidth: $notchWidth,
                                slotAngleDegrees: $slotAngleDegrees,
                                materialPreset: $materialPreset,
                                slotReliefEnabled: $slotReliefEnabled,
                                toolDiameter: materialToolDiameter,
                                radialSliceCount: $radialSliceCount,
                                radialFirstAxisByDistance: $radialFirstAxisByDistance,
                                radialFirstAxisCount: $radialFirstAxisCount,
                                radialFirstAxisSpacing: $radialFirstAxisSpacing,
                                radialNotchFactor: $radialNotchFactor,
                                radialReliefType: $radialReliefType,
                                curvePrimaryAxis: $curvePrimaryAxis,
                                curveFirstAxisCount: $curveFirstAxisCount,
                                curveSliceCount: $curveSliceCount,
                                curveAmplitude: $curveAmplitude,
                                foldedDetailFaces: $foldedDetailFaces,
                                foldedJoinery: $foldedJoinery,
                                foldedSplitPanels: $foldedSplitPanels,
                                foldedSeamEdges: $foldedSeamEdges,
                                foldedSeamEditMode: $foldedSeamEditMode,
                                customSliceDistributionEnabled: $customSliceDistributionEnabled,
                                customSliceCount: $customSliceCount,
                                sliceDistributionMethod: $sliceDistributionMethod,
                                sliceByDistanceSpacingMm: $sliceByDistanceSpacingMm,
                                customSlicePositions: $customSlicePositions,
                                sliceEditMode3D: $sliceEditMode3D,
                                selectedSliceIndex: $selectedSliceIndex,
                                onAddSlice: handleSliceAdd,
                                onDeleteSlice: { handleSliceDelete(index: selectedSliceIndex) },
                                onDistributeEvenly: handleSliceDistributeEvenly,
                                foldedPanelsUnavailableReason: foldedPanelsUnavailableReason,
                                foldedNetsFitHalfSheet: foldedNetsFitHalfSheet,
                                // Every format: the mesh exports leave out
                                // the same pieces (`builtSheetNotes`).
                                radialSheetNotes: constructionMode == .radial ? builtSheetNotes : [],
                                curveSheetNotes: constructionMode == .curve ? builtSheetNotes : [],
                                interlockedSheetNotes: constructionMode == .interlocked ? (cutSheetDocument?.notes ?? []) : [],
                                interlockedAutomaticAxes: interlockedAutomaticAxes
                            )
                        }
                    } else {
                        Text("Choose a construction technique to reveal material, slicing, assembly, and export controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if hasSelectedConstructionTechnique && constructionMode != .foldedPanels {
                        Divider()
                        InspectorSection(section: .sliceDirection, isExpanded: sectionExpanded(.sliceDirection)) {
                            SliceDirectionPanel(
                                directionAxis: sliceDirectionAxis,
                                tiltFirst: $sliceTiltFirst,
                                tiltSecond: $sliceTiltSecond,
                                livePreview: $liveSliceTiltPreview,
                                adjustInViewport: $sliceDirectionAdjustMode
                            )
                        }
                    }
                    // Dowels — its own pane AFTER Slice Direction (choose the
                    // cut direction before placing rods). Stacked only.
                    if hasSelectedConstructionTechnique && constructionMode == .stacked {
                        Divider()
                        InspectorSection(section: .dowels, isExpanded: sectionExpanded(.dowels)) {
                            DowelPanel(
                                dowelsEnabled: $dowelsEnabled,
                                dowelDiameter: $dowelDiameter,
                                dowelInset: $dowelInset,
                                dowelShape: $dowelShape,
                                customDowelPositions: $customDowelPositions,
                                dowelUseAutomatic: $dowelUseAutomatic,
                                dowelAutomaticCount: $dowelAutomaticCount,
                                dowelEditMode3D: $dowelEditMode3D,
                                selectedDowelPlan: $selectedDowelPlan,
                                automaticDowelPositions: currentAutomaticDowelPositions
                            )
                        }
                    }
                    if hasSelectedConstructionTechnique {
                        Divider()
                        sliceActionSection
                    }
                    if hasSelectedConstructionTechnique && sliceComputationEnabled {
                        Divider()
                        InspectorSection(section: .assembly, isExpanded: sectionExpanded(.assembly)) {
                            AssemblyStepsPanel(
                                steps: assemblySteps,
                                selectedStepID: $selectedAssemblyStepID,
                                renderStyle: $sliceSolidRenderStyle,
                                exportAction: exportAssemblyGuide,
                                document: cutSheetDocument
                            )
                        }
                        Divider()
                        InspectorSection(section: .export, isExpanded: sectionExpanded(.export)) {
                            exportControls
                        }
                    }
                    }
                } else {
                    InspectorSection(section: .model) {
                        InspectorEmptyState(content: workspaceEmptyState)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("Inspector")
    }

    @ViewBuilder private var statsInspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector tab", selection: $inspectorTab) {
                Text("Object").tag(InspectorTab.object)
                Text("Viewport").tag(InspectorTab.viewport)
                Text("Issues").tag(InspectorTab.issues)
                Text("Stats").tag(InspectorTab.statistics)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Object adjusts size, rotation, and form. Viewport tunes how the model is lit and shaded. Issues lists part errors. Stats shows mesh details and health checks.")

            PaneColumn(name: "inspector") {
                VStack(alignment: .leading, spacing: 14) {
                    if let model = effectiveModel {
                        switch inspectorTab {
                        case .object:
                            InspectorSection(section: .scale, isExpanded: sectionExpanded(.scale)) {
                                TransformPanel(
                                    scale: $modelScale,
                                    rotationDegrees: $modelRotationDegrees,
                                    liveRotationPreview: $liveModelRotationPreview,
                                    importUnit: $importUnit,
                                    uniformScaleEnabled: $uniformScaleEnabled,
                                    rotateInViewport: $modelRotateGizmoActive,
                                    baseDimensions: MeshScaler.dimensions(for: self.model?.bounds)
                                )
                            }
                            Divider()
                            InspectorSection(section: .modifyForm, isExpanded: sectionExpanded(.modifyForm)) {
                                ModifyFormPanel(
                                    hollowWallThickness: $modifyHollowWallThickness,
                                    thickenAmount: $modifyThickenAmount,
                                    shrinkwrapDetail: $modifyShrinkwrapDetail,
                                    watertightMethod: watertightMethodBinding,
                                    watertightTopHeight: $modifyWatertightTopHeight,
                                    wallThickness: $modifyWallThickness,
                                    openingDiagnosis: openingDiagnosisIsCurrent ? openingDiagnosis : nil,
                                    watertightReceipt: watertightOutcome(for: modifyPreviewTool ?? modifyActiveTool)?.receipt,
                                    watertightUnder: watertightIsOn && modifyActiveTool != .shrinkwrap ? modifyActiveTool?.label : nil,
                                    watertightKnownNoOp: watertightKnownNoOp,
                                    onRemoveWatertight: { removeWatertight() },
                                    openingChoices: $modifyOpeningChoices,
                                    openingChoicesNotice: openingChoicesNotice,
                                    selectedIssueSiteID: selectedIssueSiteID,
                                    onSelectOpening: { selectIssueSite(ModifyFormPanel.siteID(forOpening: $0)) },
                                    activeTool: modifyActiveTool,
                                    previewTool: modifyPreviewTool,
                                    isComputing: isComputingModify,
                                    onPreview: setModifyPreview,
                                    onApply: { tool in
                                        // Make Watertight keeps a Hollow / Thicken on top
                                        // (same as the Issues buttons).
                                        if tool == .shrinkwrap, let active = modifyActiveTool, active != .shrinkwrap {
                                            applyWatertight(modifyWatertightMethod)
                                        } else {
                                            applyModifyTool(tool)
                                        }
                                    },
                                    onRemove: removeModifyTool,
                                    onParameterCommit: modifyParameterCommitted
                                )
                            }
                        case .viewport:
                            InspectorSection(section: .viewport) {
                                ViewportAppearancePanel(
                                    settings: $viewportAppearance,
                                    spaceMouseSmoothing: $spaceMouseSmoothing,
                                    spaceMouseSpeed: $spaceMouseSpeed
                                )
                            }
                        case .issues:
                            // NEO-103: Active Slice Profile — while a slice is
                            // selected in slice-edit mode, show its 2D contour.
                            if sliceEditMode3D && constructionMode == .stacked,
                               let idx = selectedSliceIndex,
                               let plan = slicePlan,
                               plan.positions.indices.contains(idx) {
                                activeSliceProfileView(model: model, plan: plan, sliceIndex: idx)
                            }
                            ModelIssuesPanel(
                                model: model,
                                document: cutSheetDocument,
                                sliced: sliceComputationEnabled,
                                selectedStepID: $selectedAssemblyStepID,
                                isRepairing: isRepairingMesh,
                                repairAction: repairMesh,
                                onApplyWatertight: { applyWatertight($0) },
                                onRemoveWatertight: { removeWatertight() },
                                onShowWatertightOptions: { showWatertightOptions() },
                                isMakingWatertight: watertightIsOn && isComputingModify,
                                watertightActive: watertightIsOn,
                                watertightFailed: activeWatertightFailed,
                                watertightResultCurrent: watertightOutcome(for: modifyActiveTool) != nil,
                                watertightKnownNoOp: watertightKnownNoOp != nil,
                                previewingTool: modifyPreviewTool?.label,
                                formToolOnTop: modifyActiveTool == .shrinkwrap ? nil : modifyActiveTool?.label,
                                watertightMethod: modifyWatertightMethod,
                                watertightReceipt: watertightOutcome(for: modifyActiveTool)?.receipt,
                                openingChoices: modifyOpeningChoices,
                                watertightTopHeight: modifyWatertightTopHeight,
                                wallThickness: modifyWallThickness,
                                diagnosisPending: !openingDiagnosisIsCurrent,
                                openingDiagnosis: openingDiagnosis,
                                diagnosisDescribesModel: modifyActiveTool == nil || (activeWatertightFailed && modifyActiveTool == .shrinkwrap),
                                issueSites: viewportIssueSites,
                                issueSitesOmitted: viewportIssueSites.isEmpty ? 0 : (openingDiagnosis?.sitesOmitted ?? 0),
                                selectedIssueSiteID: selectedIssueSiteID,
                                onSelectIssueSite: { selectIssueSite($0) },
                                showIssueMarkers: $showIssueMarkers,
                                isMotherMold: constructionMode == .motherMold,
                                motherMoldPlan: constructionMode == .motherMold ? displayedMotherMoldPlan : nil,
                                motherMoldStatus: constructionMode == .motherMold ? motherMoldBuildStatus : nil,
                                motherMoldStatusAction: performMotherMoldRecovery
                            )
                            .overflowProbe("Issues")
                        case .statistics:
                            InspectorSection(section: .model) {
                                MetadataPanel(model: model)
                            }
                        }
                    } else {
                        Text("Open a model to see its statistics.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("Model statistics")
    }

    /// NEO-103: 2D contour preview for the selected slice in slice-edit mode.
    /// Renders the layer's outermost closed path scaled to fit a square canvas.
    @ViewBuilder private func activeSliceProfileView(model: MeshSummary, plan: StackedSlicePlan, sliceIndex: Int) -> some View {
        // The layer as Stacked cuts it: closed across any cracks.
        let contours = ViewportGeometryCache.shared.stackedClosedContours(model: model, plan: plan)
        let layer: SliceContourLayer? = contours.layers.indices.contains(sliceIndex) ? contours.layers[sliceIndex] : nil
        VStack(alignment: .leading, spacing: 6) {
            Text("Slice \(sliceIndex + 1) of \(plan.sliceCount) — \(String(format: "%.2f", plan.positions[sliceIndex])) mm")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let layer, !layer.paths.isEmpty {
                Canvas { context, size in
                    // Collect all points across all paths to compute bounding box.
                    var allPoints: [Vec2] = []
                    for path in layer.paths {
                        allPoints.append(contentsOf: path.points)
                    }
                    guard !allPoints.isEmpty else { return }
                    let minX = allPoints.map(\.x).min()!
                    let maxX = allPoints.map(\.x).max()!
                    let minY = allPoints.map(\.y).min()!
                    let maxY = allPoints.map(\.y).max()!
                    let spanX = max(maxX - minX, 1e-6)
                    let spanY = max(maxY - minY, 1e-6)
                    let scale = min(size.width / spanX, size.height / spanY) * 0.9
                    let offsetX = (size.width - spanX * scale) / 2 - minX * scale
                    let offsetY = (size.height - spanY * scale) / 2 - minY * scale
                    for path in layer.paths where path.points.count >= 2 {
                        var cgPath = Path()
                        let first = path.points[0]
                        cgPath.move(to: CGPoint(x: first.x * scale + offsetX, y: size.height - (first.y * scale + offsetY)))
                        for pt in path.points.dropFirst() {
                            cgPath.addLine(to: CGPoint(x: pt.x * scale + offsetX, y: size.height - (pt.y * scale + offsetY)))
                        }
                        if path.closed { cgPath.closeSubpath() }
                        context.stroke(cgPath, with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
                .frame(height: 120)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            } else {
                Text("No contour at this slice plane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sliceActionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                sliceComputationEnabled = true
                // Reveal the result: show slices over the model once sliced.
                if viewportPreviewMode == .model {
                    viewportPreviewMode = .modelAndSlices
                }
            } label: {
                Label(sliceComputationEnabled ? "Re-slice" : "Slice", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(effectiveModel == nil || isLoadingModel || !activeModifyMeshReady)
            .help("Cuts your model into parts using the current settings. Nothing recomputes while you adjust settings — press this when you're ready to see (or refresh) the result.")
            .accessibilityLabel(sliceComputationEnabled ? "Re-slice model" : "Slice model")

            if !sliceComputationEnabled {
                Text("Press Slice to generate cut parts from your model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if activePlanMissing {
                Label(
                    "No plan — these settings would produce more than \(Self.maxGuiSliceCount) slices. Increase the thickness or slice depth, or shrink the model.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var structureGenerateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                generateStructure()
            } label: {
                HStack {
                    if isGeneratingStructure {
                        ProgressView().controlSize(.small)
                    }
                    Label(
                        generatedStructurePlan == nil ? "Generate" : "Re-generate",
                        systemImage: "cube.transparent"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(structureGenerateDisabledReason != nil)
            .help("Builds the infill lattice with the current settings and clips it to your model's skin, producing one watertight mesh. Nothing recomputes while you adjust settings — press this when you're ready.")
            .accessibilityLabel(generatedStructurePlan == nil ? "Generate structure" : "Re-generate structure")

            if let reason = structureGenerateDisabledReason, reason != "Generating…" {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if structureResultIsStale {
                Label("Settings changed — press Re-generate to update the result.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = structureGenerateMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if generatedStructurePlan == nil {
                Text("Press Generate to fill your model with an infill lattice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activePlanMissing: Bool {
        guard effectiveModel != nil else { return false }
        guard hasSelectedConstructionTechnique else { return false }
        switch constructionMode {
        case .stacked: return slicePlan == nil
        case .interlocked: return interlockedPlan == nil
        case .radial: return radialPlan == nil
        case .curve: return curvePlan == nil
        case .threeD: return threeDPlan == nil
        case .foldedPanels: return false // folded has its own refusal notice
        case .structures: return false // structures has its own Generate gate + notice
        case .partition: return false // partition has its own Generate gate + notice
        case .motherMold: return false // MotherMold has its own Generate gate + notice
        case .inflatables: return false // Inflatables has its own Generate gate + notice
        }
    }

    private func selectConstructionTechnique(_ mode: ConstructionMode) {
        let changed = !hasSelectedConstructionTechnique || constructionMode != mode
        constructionMode = mode
        hasSelectedConstructionTechnique = true
        isTechniqueChooserExpanded = false
        guard changed else { return }
        sliceComputationEnabled = false
        selectedAssemblyStepID = nil
        lastExportFailure = nil
        cutSheetDocument = nil
        builtSheetNotes = []
        exportedStepIndices = nil
        sliceTiltFirst = 0
        sliceTiltSecond = 0
        liveSliceTiltPreview = nil
        sliceDirectionAdjustMode = false
        if viewportMode != .model3D {
            viewportMode = .model3D
        }
        if viewportPreviewMode != .model {
            viewportPreviewMode = .model
        }
        if mode == .inflatables, let plan = displayedInflatablesPlan {
            cutSheetDocument = plan.cutSheet
        }
    }

    /// All inputs that affect the slice plan. Changing any of them re-arms the
    /// explicit Slice gate so nothing recomputes until the user asks.
    private var sliceInputSignature: SliceInputSignature {
        SliceInputSignature(
            constructionMode: constructionMode,
            modelScale: modelScale,
            modelRotationDegrees: modelRotationDegrees,
            importUnit: importUnit,
            materialThickness: materialThickness,
            materialPreset: materialPreset,
            sliceAxis: sliceAxis,
            sliceTiltFirst: sliceTiltFirst,
            sliceTiltSecond: sliceTiltSecond,
            secondarySliceAxis: secondarySliceAxis,
            slotClearance: slotClearance,
            notchWidth: notchWidth,
            notchWidthOverrideEnabled: notchWidthOverrideEnabled,
            slotAngleDegrees: slotAngleDegrees,
            slotReliefEnabled: slotReliefEnabled,
            toolDiameter: materialToolDiameter,
            radialSliceCount: radialSliceCount,
            radialFirstAxisByDistance: radialFirstAxisByDistance,
            radialFirstAxisCount: radialFirstAxisCount,
            radialFirstAxisSpacing: radialFirstAxisSpacing,
            radialNotchFactor: radialNotchFactor,
            radialReliefType: radialReliefType,
            curvePrimaryAxis: curvePrimaryAxis,
            curveFirstAxisCount: curveFirstAxisCount,
            curveSliceCount: curveSliceCount,
            curveAmplitude: curveAmplitude,
            threeDSliceDepth: threeDSliceDepth,
            dowelsEnabled: dowelsEnabled,
            dowelDiameter: dowelDiameter,
            dowelInset: dowelInset,
            dowelShape: dowelShape,
            dowelAutomaticCount: dowelAutomaticCount,
            foldedDetailFaces: foldedDetailFaces,
            foldedJoinery: foldedJoinery,
            foldedSplitPanels: foldedSplitPanels,
            foldedSeamEdges: foldedSeamEdges,
            customSliceDistributionEnabled: customSliceDistributionEnabled,
            customSliceCount: customSliceCount,
            sliceDistributionMethod: sliceDistributionMethod,
            sliceByDistanceSpacingMm: sliceByDistanceSpacingMm,
            customSlicePositions: customSlicePositions
        )
    }

    // MARK: - Structures generation

    /// Snapshot of every input that affects the generated structure mesh. A
    /// mismatch with `generatedStructureSignature` means the shown/cached result
    /// no longer matches the current settings, so it is STALE.
    private var structureInputSignature: StructureInputSignature {
        StructureInputSignature(
            modelPath: model?.path,
            modelTriangleCount: effectiveModel?.triangleCount ?? 0,
            modelBounds: effectiveModel?.bounds.map { "\($0.min.display)|\($0.max.display)" },
            settings: structureSettings.sanitized
        )
    }

    /// True when a generated result exists but no longer matches the live
    /// inputs (the user edited a parameter / changed the model after Generate).
    private var structureResultIsStale: Bool {
        guard generatedStructurePlan != nil else { return false }
        return generatedStructureSignature != structureInputSignature
    }

    /// Why Generate is disabled, or nil when it is allowed. Surfaced as a hint
    /// next to the button so a disabled control is never silently dead (owner
    /// rule).
    private var structureGenerateDisabledReason: String? {
        if effectiveModel == nil { return "Load a model first." }
        if isGeneratingStructure { return "Generating…" }
        if !structureSettings.category.isImplemented {
            return "\(structureSettings.category.label) generation is not yet available in this build."
        }
        if structureSettings.category == .infill, !structureSettings.pattern.isImplemented {
            return "The \(structureSettings.pattern.label) infill pattern is not yet implemented."
        }
        if structureSettings.category == .skin, structureSettings.skin.skinStyle == .perforated {
            return "Perforated skin is deferred — use Struts (it would fail at generation, not silently)."
        }
        let density = structureSettings.sanitized.density
        let densityDriven = structureSettings.category == .skin
            || (structureSettings.category == .infill && structureSettings.pattern.supportsVariableDensity)
        if densityDriven, density.source == .image, density.imagePath == nil {
            return "Choose a density image before generating image-driven density."
        }
        return nil
    }

    /// The explicit Generate action: runs the Manifold infill engine OFF the
    /// main actor, then caches the plan + its input signature on the main actor.
    /// Mirrors the Slice action's "nothing runs until you ask" contract.
    private func generateStructure() {
        guard structureGenerateDisabledReason == nil, let model = effectiveModel else { return }
        let settings = structureSettings.sanitized
        let signature = structureInputSignature
        isGeneratingStructure = true
        structureGenerateMessage = nil
        // Reveal the result in the viewport.
        if viewportPreviewMode == .model {
            viewportPreviewMode = .modelAndSlices
        }
        Task {
            let outcome: Result<StructureMeshPlan, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if let plan = try StructurePlanner.planThrowing(model: model, settings: settings) {
                        return .success(plan)
                    }
                    return .failure(StructureEngineError.missingBounds)
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            isGeneratingStructure = false
            switch outcome {
            case .success(let plan):
                generatedStructurePlan = plan
                generatedStructureSignature = signature
                // The engine's coarsening/auto-thicken notice is a promise to the
                // user (no silent caps) — it MUST reach the panel, not just JSON.
                let engineNotice = plan.coarseningNotice.map { " ⚠︎ \($0)" } ?? ""
                if plan.settings.category == .support {
                    let coverage = plan.supportAudit.map { String(format: " Tip coverage %.1f%%.", $0.tipCoverage * 100.0) } ?? ""
                    structureGenerateMessage = "Generated \(plan.triangleCount) triangles of sculpture supports.\(coverage)\(engineNotice)"
                } else if plan.settings.category == .skin {
                    let audit = plan.skinAudit.map { String(format: " %d seeds, %.1f mm mean spacing.", $0.seedCount, $0.meanSpacing) } ?? ""
                    structureGenerateMessage = "Generated \(plan.triangleCount) triangles of \(plan.settings.skin.skinPattern.label.lowercased()) skin.\(audit)\(engineNotice)"
                } else {
                    let densityNotice = plan.settings.densityEngineNotice.map { " \($0)" } ?? ""
                    structureGenerateMessage = "Generated \(plan.triangleCount) triangles of \(plan.settings.pattern.label.lowercased()) infill.\(densityNotice)\(engineNotice)"
                }
            case .failure(let error):
                generatedStructurePlan = nil
                generatedStructureSignature = nil
                let message = (error as? StructureEngineError)?.userMessage
                    ?? "Structures engine produced no geometry."
                // Inline panel message only — routing this into `errorMessage`
                // raised the shared "Import failed" modal for GENERATION errors,
                // which is both the wrong title and the wrong severity.
                structureGenerateMessage = message
            }
        }
    }

    /// The structure plan handed to the viewport: only shown once it is current
    /// (a stale result is hidden so the 3D view never lies about the geometry).
    private var displayedStructurePlan: StructureMeshPlan? {
        guard constructionMode == .structures, !structureResultIsStale else { return nil }
        return generatedStructurePlan
    }

    // MARK: - Partition generation

    private var partitionInputSignature: PartitionInputSignature {
        // explodePreview is viewport-only — exclude it so dragging the slider
        // repositions the pieces live instead of marking the plan stale.
        var signatureSettings = partitionSettings.sanitized
        signatureSettings.explodePreview = 0
        if signatureSettings.purpose == .splitByUndercuts,
           let geometry = effectiveModel?.geometry {
            if let snapshot = partitionFingerprintSnapshot,
               snapshot.matches(geometry) {
                return PartitionInputSignature(
                    effectiveSourceFingerprint: snapshot.fingerprint,
                    settings: signatureSettings
                )
            }
            // A new effective buffer has not been hashed yet. This O(1) storage
            // identity is used only to make a prior result stale; Generate
            // replaces it with the exact triangle-soup fingerprint computed
            // off-main before committing a result.
            let identity = PartitionGeometryStorageIdentity(geometry)
            return PartitionInputSignature(
                modelPath: "pending-effective-source:\(identity.cacheKey)",
                modelTriangleCount: geometry.triangleIndices.count / 3,
                modelBounds: nil,
                settings: signatureSettings
            )
        }
        return PartitionInputSignature(
            modelPath: model?.path,
            modelTriangleCount: effectiveModel?.triangleCount ?? 0,
            modelBounds: effectiveModel?.bounds.map { "\($0.min.display)|\($0.max.display)" },
            settings: signatureSettings
        )
    }

    private var partitionResultIsStale: Bool {
        switch partitionSettings.purpose {
        case .fitPrinter:
            guard generatedPartitionPlan != nil else { return false }
            return generatedPartitionSignature != partitionInputSignature
        case .splitByUndercuts:
            return undercutGenerationState.isStale(comparedWith: partitionInputSignature)
        }
    }

    private var generatedPartitionPlanForCurrentPurpose: PartitionMeshPlan? {
        switch partitionSettings.purpose {
        case .fitPrinter: return generatedPartitionPlan
        case .splitByUndercuts: return generatedUndercutPartitionPlan
        }
    }

    /// R1: a stale Split-by-Undercuts result remains export-addressable. Fit
    /// Printer deliberately retains its existing fresh-result-only behavior.
    private var exportablePartitionPlan: PartitionMeshPlan? {
        switch partitionSettings.purpose {
        case .fitPrinter:
            return partitionResultIsStale ? nil : generatedPartitionPlan
        case .splitByUndercuts:
            return generatedUndercutPartitionPlan
        }
    }

    private var currentPartitionGenerateMessage: String? {
        partitionSettings.purpose == .splitByUndercuts
            ? undercutPartitionGenerateMessage
            : partitionGenerateMessage
    }

    private var partitionGenerateDisabledReason: String? {
        if effectiveModel == nil { return "Load a model first." }
        // Fit Printer keeps its existing disabled-while-generating behavior.
        // Split by Undercuts turns the same action into cooperative Cancel.
        if isGeneratingPartition, partitionSettings.purpose == .fitPrinter {
            return "Generating…"
        }
        return nil
    }

    /// Explicit Partition action: cuts the model into bed-sized pieces OFF the
    /// main actor, then caches the plan + its input signature. Mirrors Structures'
    /// "nothing runs until you ask" contract — dense meshes never block the UI.
    private func generatePartition() {
        if isGeneratingPartition, partitionSettings.purpose == .splitByUndercuts {
            cancelUndercutPartitionGeneration()
            return
        }
        guard partitionGenerateDisabledReason == nil, let model = effectiveModel else { return }
        let settings = partitionSettings.sanitized
        let fitPrinterSignature = settings.purpose == .fitPrinter
            ? partitionInputSignature
            : nil
        isGeneratingPartition = true
        if settings.purpose == .fitPrinter {
            partitionGenerateMessage = nil
        } else {
            undercutPartitionGenerateMessage = nil
        }
        if viewportPreviewMode == .model {
            viewportPreviewMode = .modelAndSlices
        }
        let routeTask = Task { @MainActor in
            let route = await resolvedPartitionGenerationRoute(
                purposeRawValue: settings.purpose.rawValue
            )
            guard !Task.isCancelled else { return }
            switch route {
            case .fitPrinter:
                guard let fitPrinterSignature else { return }
                await generateFitPrinterPartition(
                    model: model,
                    settings: settings,
                    signature: fitPrinterSignature
                )
            case .splitByUndercuts:
                await generateUndercutPartition(model: model, settings: settings)
            }
        }
        if settings.purpose == .splitByUndercuts {
            partitionGenerationTask = routeTask
        }
    }

    /// Existing Fit Printer implementation, deliberately unchanged in result,
    /// stale, failure, and export semantics.
    @MainActor
    private func generateFitPrinterPartition(
        model: MeshSummary,
        settings: PartitionSettings,
        signature: PartitionInputSignature
    ) async {
        let plan: PartitionMeshPlan? = await Task.detached(priority: .userInitiated) {
            PartitionPlanner.plan(model: model, settings: settings)
        }.value

        guard !Task.isCancelled else { return }
        isGeneratingPartition = false
        if let plan, !plan.pieces.isEmpty {
            generatedPartitionPlan = plan
            generatedPartitionSignature = signature
            let count = plan.pieces.count
            var message = "Split into \(count) piece\(count == 1 ? "" : "s")."
            if plan.oversizedCount > 0 {
                message += " \(plan.oversizedCount) still over the build volume."
            }
            partitionGenerateMessage = message
        } else {
            generatedPartitionPlan = nil
            generatedPartitionSignature = nil
            let message = "Partition produced no pieces. Check the build volume."
            partitionGenerateMessage = message
            errorMessage = message
        }
    }

    @MainActor
    private func generateUndercutPartition(
        model: MeshSummary,
        settings: PartitionSettings
    ) async {
        let cancellation = PartitionCancellationFlag()
        partitionCancellationFlag = cancellation
        var generationState = undercutGenerationState
        let token = generationState.begin()
        undercutGenerationState = generationState
        activeUndercutGenerationToken = token
        undercutPlanningStartedAt = Date()
        let splitSettings = settings.undercutSplit?.sanitized ?? .defaultValue
        let plannerCache = undercutPlannerCache
        let bounds = model.bounds
        // The source's open-boundary gate trusts the model's own report —
        // the imported model's truthful one, or a Modify Form result's — but
        // never the RAW import preflight (measured in the file's units; it is
        // what the model still carries until the truthful report lands).
        // Then the planner measures the geometry itself, as before.
        let sourcePreflight: MeshPreflightReport? = model.preflight == self.model?.preflight
            ? nil
            : model.preflight

        let worker = Task.detached(priority: .userInitiated) {
            () throws -> UndercutPartitionGenerationOutput in
            if cancellation.isCancelled { throw UndercutSplitPlanner.Error.cancelled }
            let fingerprint = SourceFaceMap.geometryFingerprint(of: model.geometry)
            var signatureSettings = settings
            signatureSettings.explodePreview = 0
            let signature = PartitionInputSignature(
                effectiveSourceFingerprint: fingerprint,
                settings: signatureSettings
            )
            let plan = try await UndercutSplitPlanner.plan(
                geometry: model.geometry,
                settings: splitSettings,
                sourcePreflight: sourcePreflight,
                cache: plannerCache,
                shouldCancel: { cancellation.isCancelled || Task.isCancelled }
            )
            if cancellation.isCancelled { throw UndercutSplitPlanner.Error.cancelled }
            return UndercutPartitionGenerationOutput(
                plan: plan,
                viewportPlan: Self.viewportPartitionPlan(
                    from: plan,
                    settings: settings,
                    modelBounds: bounds
                ),
                overlay: UndercutSplitOverlay.make(
                    plan: plan,
                    settings: splitSettings
                ),
                signature: signature,
                fingerprint: fingerprint,
                retainedGeometry: model.geometry
            )
        }
        let outcome = await worker.result

        // A superseded task never mutates the newer generation transaction.
        guard activeUndercutGenerationToken == token else { return }
        partitionGenerationTask = nil
        partitionCancellationFlag = nil
        activeUndercutGenerationToken = nil
        isGeneratingPartition = false
        undercutPlanningStartedAt = nil

        switch outcome {
        case .success(let output):
            var state = undercutGenerationState
            guard output.plan.isExportable, !output.viewportPlan.pieces.isEmpty else {
                state.fail(message: "Planning returned no exportable pieces.", token: token)
                undercutGenerationState = state
                undercutPartitionGenerateMessage = "Planning returned no pieces. Previous pieces were kept and remain exportable."
                return
            }
            guard state.commit(output.plan, signature: output.signature, token: token) else {
                return
            }
            undercutGenerationState = state
            generatedUndercutPartitionPlan = output.viewportPlan
            generatedUndercutOverlay = output.overlay
            let validNodeIDs = Set(output.plan.cutTree.nodes.map(\.id))
            let validPieceIDs = Set(output.plan.pieces.map(\.regionID))
            if let selectedUndercutCutNodeID,
               !validNodeIDs.contains(selectedUndercutCutNodeID) {
                self.selectedUndercutCutNodeID = nil
            }
            if let selectedUndercutPieceRegionID,
               !validPieceIDs.contains(selectedUndercutPieceRegionID) {
                self.selectedUndercutPieceRegionID = nil
            }
            if let isolatedUndercutPieceRegionID,
               !validPieceIDs.contains(isolatedUndercutPieceRegionID) {
                self.isolatedUndercutPieceRegionID = nil
            }
            hoveredUndercutCutNodeID = nil
            hoveredUndercutRegionID = nil
            if output.plan.cutTree.nodes.isEmpty { undercutCutEditMode3D = false }
            partitionFingerprintSnapshot = PartitionSourceFingerprintSnapshot(
                retainedGeometry: output.retainedGeometry,
                fingerprint: output.fingerprint
            )
            undercutPartitionGenerateMessage = output.plan.statusMessage
        case .failure(let error):
            var state = undercutGenerationState
            if cancellation.isCancelled || (error as? UndercutSplitPlanner.Error) == .cancelled {
                state.cancel(token: token)
                undercutPartitionGenerateMessage = "Planning cancelled. Previous pieces were kept."
            } else {
                state.fail(message: error.localizedDescription, token: token)
                undercutPartitionGenerateMessage = "Planning failed: \(error.localizedDescription) Previous pieces were kept and remain exportable."
            }
            undercutGenerationState = state
        }
    }

    private func cancelUndercutPartitionGeneration() {
        partitionCancellationFlag?.cancel()
        partitionGenerationTask?.cancel()
        partitionGenerationTask = nil
        if let token = activeUndercutGenerationToken {
            var state = undercutGenerationState
            state.cancel(token: token)
            undercutGenerationState = state
        }
        activeUndercutGenerationToken = nil
        partitionCancellationFlag = nil
        isGeneratingPartition = false
        undercutPlanningStartedAt = nil
        undercutPartitionGenerateMessage = "Planning cancelled. Previous pieces were kept."
    }

    nonisolated private static func viewportPartitionPlan(
        from plan: UndercutSplitPlan,
        settings: PartitionSettings,
        modelBounds: Bounds3D?
    ) -> PartitionMeshPlan {
        let ordered = plan.pieces.sorted { $0.regionID < $1.regionID }
        let pieces = ordered.enumerated().compactMap { index, piece -> PartitionPiece? in
            let triangles = piece.mesh.triangles.map { ($0.a, $0.b, $0.c) }
            guard let bounds = PartitionGeometry.bounds(triangles) else { return nil }
            return PartitionPiece(
                name: String(format: "part-%02d", index + 1),
                mesh: PartitionGeometry.flatShadedMesh(triangles),
                bounds: bounds,
                // Build-volume fit is not an input or acceptance condition for
                // Split by Undercuts (R10); this legacy adapter is viewport/export only.
                fitsBuildVolume: true
            )
        }
        return PartitionMeshPlan(
            settings: settings,
            pieces: pieces,
            seams: plan.cutTree.nodes.map { _ in PartitionSeam(keyed: false, pinCount: 0) },
            warnings: plan.warnings,
            modelBounds: modelBounds
        )
    }

    /// The partition plan handed to the viewport: only shown once it is current.
    private var displayedPartitionPlan: PartitionMeshPlan? {
        guard constructionMode == .partition else { return nil }
        switch partitionSettings.purpose {
        case .fitPrinter:
            return partitionResultIsStale ? nil : generatedPartitionPlan
        case .splitByUndercuts:
            // Stale undercut geometry stays inspectable; the stale status still
            // tells the user it no longer matches current settings.
            return generatedUndercutPartitionPlan
        }
    }

    /// The measured plan remains inspectable when inputs change; only its
    /// fresh/stale presentation changes. This mirrors the R1 export contract.
    private var displayedUndercutPlan: UndercutSplitPlan? {
        guard constructionMode == .partition,
              partitionSettings.purpose == .splitByUndercuts else { return nil }
        return undercutGenerationState.inspectablePlan(comparedWith: partitionInputSignature)
    }

    /// Heavy measured patches are built off-main in the generation transaction.
    /// This computed value only applies small interaction and authored-tree
    /// overrides, keeping selection and stale-state updates responsive.
    private var displayedUndercutOverlay: UndercutSplitOverlay? {
        guard constructionMode == .partition,
              partitionSettings.purpose == .splitByUndercuts,
              let overlay = generatedUndercutOverlay else { return nil }
        let split = partitionSettings.undercutSplit?.sanitized ?? .defaultValue
        let authoredTree = split.planningMode == .manual
            ? split.authoredCutTree?.typedTree
            : nil
        return overlay.applying(
            authoredTree: authoredTree,
            selectedCutNodeID: selectedUndercutCutNodeID,
            hoveredCutNodeID: hoveredUndercutCutNodeID,
            isolatedPieceRegionID: isolatedUndercutPieceRegionID,
            hoveredRegionID: hoveredUndercutRegionID,
            isStale: partitionResultIsStale,
            faceConstraints: split.faceConstraints,
            facePaintMode: undercutFacePaintMode
        )
    }

    /// Commit a viewport drag: slide a manual plane to a new offset (keeps its
    /// normal). Re-arms Generate by changing the settings signature.
    private func handlePartitionPlaneMoved(index: Int, offset: Double) {
        guard partitionSettings.manualPlanes.indices.contains(index) else { return }
        var settings = partitionSettings
        settings.manualPlanes[index].offset = offset
        partitionSettings = settings.sanitized
    }

    private func handlePartitionPlaneDelete() {
        guard let index = selectedPartitionPlaneIndex,
              partitionSettings.manualPlanes.indices.contains(index) else { return }
        var settings = partitionSettings
        settings.manualPlanes.remove(at: index)
        partitionSettings = settings.sanitized
        selectedPartitionPlaneIndex = nil
    }

    private func setUndercutPlanningMode(_ mode: UndercutPlanningMode) {
        if mode == .automatic {
            var split = partitionSettings.undercutSplit?.sanitized ?? .defaultValue
            split.planningMode = .automatic
            var partition = partitionSettings
            partition.undercutSplit = split
            partitionSettings = partition
            undercutCutEditMode3D = false
            return
        }
        _ = commitUndercutTreeEdit(
            message: "The retained cut tree is available for manual editing. Measurements are retained until the next analysis."
        ) { _, _ in true }
    }

    private func toggleUndercutCutNodeLock(_ nodeID: PartitionCutNodeID) {
        _ = commitUndercutTreeEdit(
            preferredNodeID: nodeID,
            message: "Cut lock changed. Measurements are retained and marked stale until the next analysis."
        ) { tree, _ in
            guard let index = tree.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
            tree.nodes[index].isLocked.toggle()
            return true
        }
    }

    private func rotateUndercutCutNode(
        _ nodeID: PartitionCutNodeID,
        _ axis: Vec3,
        _ degrees: Double
    ) {
        _ = commitUndercutTreeEdit(
            preferredNodeID: nodeID,
            message: "Cut rotation changed. Measurements are retained and marked stale until the next analysis."
        ) { tree, _ in
            guard let index = tree.nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
            let oldPlane = tree.nodes[index].plane
            let pivot = displayedUndercutOverlay?.cutSurfaces
                .first(where: { $0.nodeID == nodeID })?.fallbackCenter
                ?? Self.pointOnUndercutPlaneNearOrigin(oldPlane)
            let rotatedNormal = Self.rotateUndercutVector(
                oldPlane.normal,
                around: axis,
                degrees: degrees
            )
            let offset = Self.dotUndercut(rotatedNormal, pivot)
            guard let plane = CanonicalPlane(normal: rotatedNormal, offset: offset),
                  plane != oldPlane else { return false }
            tree.nodes[index].plane = plane
            tree.nodes[index].source = .manual
            return true
        }
    }

    private func deleteUndercutCutNode(_ nodeID: PartitionCutNodeID) {
        guard displayedUndercutOverlay?.cutSurfaces.contains(where: { $0.nodeID == nodeID }) == true else {
            return
        }
        pendingUndercutCutNodeDeletion = nodeID
    }

    private func confirmUndercutCutNodeDeletion() {
        guard let nodeID = pendingUndercutCutNodeDeletion else { return }
        pendingUndercutCutNodeDeletion = nil
        var droppedLockCount = 0
        var removedRegionIDs = Set<PartitionRegionID>()
        let changed = commitUndercutTreeEdit(
            preferredNodeID: nodeID,
            message: "Cut subtree deleted. Measurements are retained and marked stale until the next analysis."
        ) { tree, split in
            guard let node = tree.nodes.first(where: { $0.id == nodeID }) else { return false }
            let byTarget = Dictionary(
                tree.nodes.map { ($0.targetRegionID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var removedRegions: Set<PartitionRegionID> = [node.negativeChildID, node.positiveChildID]
            var queue = [node.negativeChildID, node.positiveChildID]
            while let region = queue.popLast() {
                guard let descendant = byTarget[region] else { continue }
                for child in [descendant.negativeChildID, descendant.positiveChildID]
                    where removedRegions.insert(child).inserted {
                    queue.append(child)
                }
            }
            tree.nodes.removeAll { candidate in
                candidate.id == nodeID || removedRegions.contains(candidate.targetRegionID)
            }
            removedRegionIDs = removedRegions
            let oldLockCount = split.lockedPullDirections.count
            split.lockedPullDirections = split.lockedPullDirections.filter {
                !removedRegions.contains($0.key)
            }
            droppedLockCount = oldLockCount - split.lockedPullDirections.count
            if split.lockedPullDirections.isEmpty, split.pullPolicy == .perPieceLocks {
                split.pullPolicy = .automatic
            }
            return true
        }
        if changed {
            selectedUndercutCutNodeID = nil
            hoveredUndercutCutNodeID = nil
            if let selectedUndercutPieceRegionID,
               removedRegionIDs.contains(selectedUndercutPieceRegionID) {
                self.selectedUndercutPieceRegionID = nil
            }
            if let isolatedUndercutPieceRegionID,
               removedRegionIDs.contains(isolatedUndercutPieceRegionID) {
                self.isolatedUndercutPieceRegionID = nil
            }
            if droppedLockCount > 0 {
                let lockWord = droppedLockCount == 1 ? "lock was" : "locks were"
                undercutPartitionGenerateMessage = "Cut subtree deleted; \(droppedLockCount) descendant pull \(lockWord) dropped. Measurements are retained and marked stale until the next analysis."
            }
        }
    }

    private func toggleUndercutPieceIsolation(_ regionID: PartitionRegionID) {
        isolatedUndercutPieceRegionID = isolatedUndercutPieceRegionID == regionID ? nil : regionID
    }

    private func toggleUndercutFacePaint(_ sourceFaceID: SourceFaceID) {
        guard undercutFacePaintMode != .none else { return }
        var split = partitionSettings.undercutSplit?.sanitized ?? .defaultValue
        switch undercutFacePaintMode {
        case .none:
            return
        case .noCut:
            var noCut = Set(split.faceConstraints.noCutSourceFaceIDs)
            if !noCut.insert(sourceFaceID).inserted { noCut.remove(sourceFaceID) }
            split.faceConstraints.noCutSourceFaceIDs = noCut.sorted()
            split.faceConstraints.preferredSeamFaces.removeAll { $0.sourceFaceID == sourceFaceID }
        case .preferredSeam:
            if split.faceConstraints.preferredSeamFaces.contains(where: { $0.sourceFaceID == sourceFaceID }) {
                split.faceConstraints.preferredSeamFaces.removeAll { $0.sourceFaceID == sourceFaceID }
            } else {
                split.faceConstraints.preferredSeamFaces.append(
                    PreferredSeamFace(sourceFaceID: sourceFaceID, weight: 1)
                )
            }
            split.faceConstraints.noCutSourceFaceIDs.removeAll { $0 == sourceFaceID }
        }
        var partition = partitionSettings
        partition.undercutSplit = split.sanitized
        partitionSettings = partition
        undercutPartitionGenerateMessage = "Source-face paint changed. Measurements are retained and marked stale until the next analysis."
    }

    private func toggleUndercutPiecePullLock(_ regionID: PartitionRegionID) {
        guard let piece = displayedUndercutPlan?.pieces.first(where: { $0.regionID == regionID }) else {
            return
        }
        _ = commitUndercutTreeEdit(
            preferredRegionID: regionID,
            message: "Piece pull lock changed. Measurements are retained and marked stale until the next analysis."
        ) { _, split in
            if split.lockedPullDirections.removeValue(forKey: regionID) == nil {
                split.lockedPullDirections[regionID] = piece.pullAxis
                split.pullPolicy = .perPieceLocks
            } else if split.lockedPullDirections.isEmpty {
                split.pullPolicy = .automatic
            }
            return true
        }
    }

    private func addUndercutCut(_ regionID: PartitionRegionID, _ axis: Vec3) {
        guard let piece = displayedUndercutPlan?.pieces.first(where: { $0.regionID == regionID }),
              let center = Self.undercutMeshCenter(piece.mesh) else { return }
        var addedNodeID: PartitionCutNodeID?
        let changed = commitUndercutTreeEdit(
            preferredRegionID: regionID,
            message: "Scoped cut added. Measurements are retained and marked stale until the next analysis."
        ) { tree, split in
            let targetIsLeaf = tree.allRegionIDs.contains(regionID)
                && !tree.nodes.contains(where: { $0.targetRegionID == regionID })
            guard targetIsLeaf, tree.nodes.count + 1 < split.maxPieces else { return false }
            guard let plane = CanonicalPlane(
                normal: axis,
                offset: Self.dotUndercut(axis, center)
            ) else { return false }
            var hasher = PartitionStableHasher()
            hasher.append("partition-manual-ui-v1")
            hasher.append(tree.rootRegionID.rawValue)
            hasher.append(regionID.rawValue)
            hasher.appendCanonicalFloatingPoint(plane.normal.x)
            hasher.appendCanonicalFloatingPoint(plane.normal.y)
            hasher.appendCanonicalFloatingPoint(plane.normal.z)
            hasher.appendCanonicalFloatingPoint(plane.offset)
            hasher.append(split.seed)
            for existingID in tree.nodes.map(\.id).sorted() {
                hasher.append(existingID.rawValue)
            }
            let nodeID = PartitionCutNodeID(rawValue: "cut-manual-\(hasher.finalized)")
            guard !tree.nodes.contains(where: { $0.id == nodeID }) else { return false }
            tree.nodes.append(
                .manual(
                    id: nodeID,
                    targetRegionID: regionID,
                    plane: plane,
                    isLocked: false
                )
            )
            tree.nodes = Self.depthFirstUndercutNodes(tree)
            addedNodeID = nodeID
            return true
        }
        if changed {
            selectedUndercutCutNodeID = addedNodeID
            undercutCutEditMode3D = true
        }
    }

    private func moveUndercutCutNode(nodeID: PartitionCutNodeID, to plane: CanonicalPlane) {
        _ = commitUndercutTreeEdit(
            preferredNodeID: nodeID,
            message: "Cut position changed. Measurements are retained and marked stale until the next analysis."
        ) { tree, _ in
            guard let index = tree.nodes.firstIndex(where: { $0.id == nodeID }),
                  tree.nodes[index].plane != plane else { return false }
            tree.nodes[index].plane = plane
            tree.nodes[index].source = .manual
            return true
        }
    }

    @discardableResult
    private func commitUndercutTreeEdit(
        preferredNodeID: PartitionCutNodeID? = nil,
        preferredRegionID: PartitionRegionID? = nil,
        message: String,
        mutation: (inout PartitionCutTree, inout UndercutSplitSettings) -> Bool
    ) -> Bool {
        var split = partitionSettings.undercutSplit?.sanitized ?? .defaultValue
        if split.authoredCutTree?.isQuarantined == true {
            undercutPartitionGenerateMessage = "The authored cut tree is quarantined. Its retained diagnostics must be resolved or the payload explicitly deleted before editing."
            return false
        }
        let generatedPlan = displayedUndercutPlan
        let generatedTree = generatedPlan?.cutTree
        let persistedTree = split.authoredCutTree?.typedTree

        func containsPreference(_ tree: PartitionCutTree) -> Bool {
            if let preferredNodeID {
                return tree.nodes.contains(where: { $0.id == preferredNodeID })
            }
            if let preferredRegionID {
                return tree.allRegionIDs.contains(preferredRegionID)
            }
            return true
        }

        let treeAndFingerprint: (PartitionCutTree, String)? = {
            if let persistedTree, containsPreference(persistedTree) {
                return (persistedTree, split.authoredCutTree?.sourceGeometryFingerprint ?? "")
            }
            if let generatedTree, containsPreference(generatedTree) {
                return (
                    generatedTree,
                    generatedPlan?.pieces.first?.mesh.sourceGeometryFingerprint ?? ""
                )
            }
            return nil
        }()
        guard let (baseTree, fingerprint) = treeAndFingerprint,
              !fingerprint.isEmpty else {
            undercutPartitionGenerateMessage = split.authoredCutTree?.isQuarantined == true
                ? "The authored cut tree is quarantined. Its diagnostics must be resolved before editing."
                : "Analyze the model before editing its cut tree."
            return false
        }

        var tree = baseTree
        guard mutation(&tree, &split) else { return false }
        let issues = tree.structuralValidationIssues
        guard issues.isEmpty else {
            let details = issues.map(\.description).joined(separator: " ")
            undercutPartitionGenerateMessage = "Manual edit was not applied: \(details)"
            return false
        }
        do {
            split.authoredCutTree = try PersistedCutTreeEnvelope(
                tree: tree,
                sourceGeometryFingerprint: fingerprint
            )
        } catch {
            undercutPartitionGenerateMessage = "Manual edit was not applied: \(error.localizedDescription)"
            return false
        }
        split.planningMode = .manual
        var partition = partitionSettings
        partition.undercutSplit = split.sanitized
        partitionSettings = partition
        undercutPartitionGenerateMessage = message
        return true
    }

    private static func depthFirstUndercutNodes(_ tree: PartitionCutTree) -> [PartitionCutNode] {
        let byTarget = Dictionary(
            tree.nodes.map { ($0.targetRegionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [PartitionCutNode] = []
        func walk(_ regionID: PartitionRegionID) {
            guard let node = byTarget[regionID] else { return }
            ordered.append(node)
            walk(node.negativeChildID)
            walk(node.positiveChildID)
        }
        walk(tree.rootRegionID)
        return ordered
    }

    private static func undercutMeshCenter(_ mesh: AttributedMesh) -> Vec3? {
        guard let first = mesh.triangles.first?.a else { return nil }
        var minimum = first
        var maximum = first
        for triangle in mesh.triangles {
            for point in [triangle.a, triangle.b, triangle.c] {
                minimum.x = min(minimum.x, point.x)
                minimum.y = min(minimum.y, point.y)
                minimum.z = min(minimum.z, point.z)
                maximum.x = max(maximum.x, point.x)
                maximum.y = max(maximum.y, point.y)
                maximum.z = max(maximum.z, point.z)
            }
        }
        return Vec3(
            x: (minimum.x + maximum.x) / 2,
            y: (minimum.y + maximum.y) / 2,
            z: (minimum.z + maximum.z) / 2
        )
    }

    private static func pointOnUndercutPlaneNearOrigin(_ plane: CanonicalPlane) -> Vec3 {
        Vec3(
            x: plane.normal.x * plane.offset,
            y: plane.normal.y * plane.offset,
            z: plane.normal.z * plane.offset
        )
    }

    private static func rotateUndercutVector(
        _ value: Vec3,
        around rawAxis: Vec3,
        degrees: Double
    ) -> Vec3 {
        let length = sqrt(dotUndercut(rawAxis, rawAxis))
        guard length.isFinite, length > 1.0e-12 else { return value }
        let axis = Vec3(x: rawAxis.x / length, y: rawAxis.y / length, z: rawAxis.z / length)
        let radians = degrees * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let cross = Vec3(
            x: axis.y * value.z - axis.z * value.y,
            y: axis.z * value.x - axis.x * value.z,
            z: axis.x * value.y - axis.y * value.x
        )
        let aligned = dotUndercut(axis, value) * (1 - cosine)
        return Vec3(
            x: value.x * cosine + cross.x * sine + axis.x * aligned,
            y: value.y * cosine + cross.y * sine + axis.y * aligned,
            z: value.z * cosine + cross.z * sine + axis.z * aligned
        )
    }

    private static func dotUndercut(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    @ViewBuilder private var partitionGenerateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: generatePartition) {
                Label(
                    isGeneratingPartition && partitionSettings.purpose == .splitByUndercuts
                        ? "Cancel planning"
                        : (partitionSettings.purpose == .splitByUndercuts
                            ? (generatedPartitionPlanForCurrentPurpose == nil ? "Analyze & Split" : "Re-analyze & Split")
                            : (generatedPartitionPlanForCurrentPurpose == nil ? "Partition & preview" : "Re-partition")),
                    systemImage: isGeneratingPartition && partitionSettings.purpose == .splitByUndercuts
                        ? "xmark.circle"
                        : "scissors"
                )
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(partitionGenerateDisabledReason != nil)
            .accessibilityLabel(
                    isGeneratingPartition && partitionSettings.purpose == .splitByUndercuts
                        ? "Cancel undercut planning"
                        : (partitionSettings.purpose == .splitByUndercuts
                            ? (generatedPartitionPlanForCurrentPurpose == nil ? "Analyze and split model" : "Re-analyze and split model")
                            : (generatedPartitionPlanForCurrentPurpose == nil ? "Partition model" : "Re-partition model"))
            )

            if let reason = partitionGenerateDisabledReason, reason != "Generating…" {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if isGeneratingPartition {
                Text(partitionSettings.purpose == .splitByUndercuts
                    ? "Analyzing directions and scoped cuts…"
                    : "Cutting pieces…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if partitionResultIsStale {
                Label(
                    partitionSettings.purpose == .splitByUndercuts
                        ? UndercutSplitUIWording.staleAdvisory
                        : "Settings changed — re-partition to update.",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption).foregroundStyle(.orange)
            } else if let message = currentPartitionGenerateMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if generatedPartitionPlanForCurrentPurpose == nil {
                Text(partitionSettings.purpose == .splitByUndercuts
                    ? "Set the release tolerance, then press Partition to analyze and split."
                    : "Set your build volume, then press Partition to cut bed-sized pieces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - MotherMold generation

    /// Snapshot of every input that affects the generated mold parts. A mismatch
    /// with `generatedMotherMoldSignature` means the shown/cached result no
    /// longer matches the current settings, so it is STALE.
    private var motherMoldInputSignature: MotherMoldInputSignature {
        MotherMoldInputSignature(
            modelPath: model?.path,
            modelTriangleCount: effectiveModel?.triangleCount ?? 0,
            modelBounds: effectiveModel?.bounds.map { "\($0.min.display)|\($0.max.display)" },
            settings: motherMoldSettings.generationInputs
        )
    }

    /// True when a generated result exists but no longer matches the live inputs
    /// (the user edited a parameter / changed the model after Build mold).
    private var motherMoldResultIsStale: Bool {
        guard generatedMotherMoldPlan != nil else { return false }
        return generatedMotherMoldSignature != motherMoldInputSignature
    }

    /// The single five-state artist contract. Both the inspector card and the
    /// Issues tab receive this exact value, so neither surface can contradict
    /// the other after a cancellation, setting edit, or failed planner run.
    private var motherMoldBuildStatus: MotherMoldUIContract.BuildStatusPresentation {
        let activeFailure = motherMoldBuildFailureSignature == motherMoldInputSignature
            ? motherMoldBuildFailure
            : nil
        return MotherMoldUIContract.buildStatus(
            preflight: effectiveModel?.preflight,
            isBuilding: isGeneratingMotherMold,
            buildStage: motherMoldBuildStage,
            isStale: motherMoldResultIsStale,
            plan: generatedMotherMoldPlan,
            settings: motherMoldSettings.sanitized,
            buildFailure: activeFailure,
            buildMessage: motherMoldGenerateMessage
        )
    }

    /// A nil ID removes the guides. A live signature schedules one debounced
    /// settings-driven refresh; repeated slider changes cancel the prior task.
    private var motherMoldPrebuildOverlaySignature: MotherMoldInputSignature? {
        let shouldDisplay = motherMoldPlacementTarget != nil
            || MotherMoldPrebuildOverlay.shouldDisplay(
                isMotherMoldActive: constructionMode == .motherMold,
                hasGeneratedPlan: generatedMotherMoldPlan != nil,
                isGeneratedPlanStale: motherMoldResultIsStale
            )
        guard constructionMode == .motherMold, shouldDisplay else {
            return nil
        }
        return motherMoldInputSignature
    }

    @MainActor
    private func rebuildMotherMoldPrebuildOverlay() async {
        guard motherMoldPrebuildOverlaySignature != nil,
              let model = effectiveModel else {
            motherMoldPrebuildOverlay = nil
            return
        }
        do {
            try await Task.sleep(nanoseconds: MotherMoldPrebuildOverlay.debounceNanoseconds)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        motherMoldPrebuildOverlay = MotherMoldPrebuildOverlay.make(
            model: model,
            settings: motherMoldSettings
        )
    }

    private func applyMotherMoldSurfacePick(_ hit: MotherMoldSurfacePlacement.Hit) {
        guard let target = motherMoldPlacementTarget else { return }
        motherMoldSettings = MotherMoldSurfacePlacement.applying(
            hit,
            target: target,
            to: motherMoldSettings
        )
        motherMoldPlacementTarget = nil
    }

    /// Why Build mold is disabled, or nil when it is allowed. Surfaced as a hint
    /// next to the button so a disabled control is never silently dead.
    private var motherMoldGenerateDisabledReason: String? {
        if effectiveModel == nil { return "Load a model first." }
        if isGeneratingMotherMold { return "Building…" }
        if let reason = MotherMoldUIContract.openGeometryDisabledReason(preflight: effectiveModel?.preflight) {
            return reason
        }
        if let reason = MotherMoldUIContract.manualSpoutDisabledReason(for: motherMoldSettings) {
            return reason
        }
        return nil
    }

    /// The explicit Build mold action: runs the MotherMold planner OFF the main
    /// actor, then caches the plan + its input signature on the main actor.
    /// Mirrors the Structures Generate action's "nothing runs until you ask".
    private func generateMotherMold() {
        if isGeneratingMotherMold {
            cancelMotherMoldBuild()
            return
        }
        guard motherMoldGenerateDisabledReason == nil, let model = effectiveModel else { return }
        let settings = motherMoldSettings.sanitized
        let signature = motherMoldInputSignature
        let relay = MotherMoldBuildRelay()
        let sessionID = UUID()
        motherMoldBuildRelay = relay
        motherMoldBuildSessionID = sessionID
        motherMoldBuildStage = nil
        motherMoldBuildStartedAt = Date()
        isGeneratingMotherMold = true
        motherMoldGenerateMessage = nil
        motherMoldBuildFailure = nil
        motherMoldBuildFailureSignature = nil
        motherMoldBuildDetailsExpanded = false
        // Reveal the result in the viewport.
        if viewportPreviewMode == .model {
            viewportPreviewMode = .modelAndSlices
        }
        let routeTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try MotherMoldPlanner.planThrowing(
                    model: model,
                    settings: settings,
                    progress: { relay.report($0) },
                    isCancelled: { relay.isCancelled || Task.isCancelled }
                )
            }
            let progressPoller = Task { @MainActor in
                while !Task.isCancelled {
                    guard motherMoldBuildSessionID == sessionID else { return }
                    if let stage = relay.latestStage, stage != motherMoldBuildStage {
                        motherMoldBuildStage = stage
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            let outcome = await worker.result
            progressPoller.cancel()

            // A cancelled or superseded worker never commits late over a newer
            // build or a replacement model/project.
            guard motherMoldBuildSessionID == sessionID else { return }
            motherMoldBuildTask = nil
            motherMoldBuildRelay = nil
            motherMoldBuildSessionID = nil
            motherMoldBuildStage = nil
            motherMoldBuildStartedAt = nil
            isGeneratingMotherMold = false
            switch outcome {
            case .success(let plan):
                generatedMotherMoldPlan = plan
                generatedMotherMoldSignature = signature
                // The Build Status section is the single result surface. Do
                // not repeat a second message below the build button.
                motherMoldGenerateMessage = nil
                motherMoldBuildFailure = nil
                motherMoldBuildFailureSignature = nil
                motherMoldExploded = false
                motherMoldShowUndercuts = false
                isolatedMotherMoldPartName = nil
            case .failure(let error):
                generatedMotherMoldPlan = nil
                generatedMotherMoldSignature = nil
                motherMoldExploded = false
                isolatedMotherMoldPartName = nil
                NSLog("[MotherMold] Build failed: \(error)")
                let message = MotherMoldUIContract.buildFailureMessage(error)
                motherMoldGenerateMessage = message
                motherMoldBuildFailure = MotherMoldUIContract.buildFailurePresentation(error)
                motherMoldBuildFailureSignature = signature
            }
        }
        motherMoldBuildTask = routeTask
    }

    /// Cancellation is cooperative inside the CPU-bound planner, but the UI
    /// returns to its pre-build state immediately. The session guard above
    /// prevents the detached worker from committing after it reaches its next
    /// cancellation boundary.
    private func cancelMotherMoldBuild(showMessage: Bool = true) {
        guard isGeneratingMotherMold || motherMoldBuildTask != nil else { return }
        motherMoldBuildRelay?.cancel()
        motherMoldBuildTask?.cancel()
        motherMoldBuildTask = nil
        motherMoldBuildRelay = nil
        motherMoldBuildSessionID = nil
        motherMoldBuildStage = nil
        motherMoldBuildStartedAt = nil
        isGeneratingMotherMold = false
        generatedMotherMoldPlan = nil
        generatedMotherMoldSignature = nil
        motherMoldExploded = false
        motherMoldShowUndercuts = false
        isolatedMotherMoldPartName = nil
        motherMoldBuildFailure = nil
        motherMoldBuildFailureSignature = nil
        motherMoldBuildDetailsExpanded = false
        if showMessage {
            motherMoldGenerateMessage = "Build cancelled."
        }
    }

    private func performMotherMoldRecovery(_ action: MotherMoldUIContract.RecoveryAction) {
        if MotherMoldUIContract.clearsBuildFailure(whenPerforming: action) {
            motherMoldBuildFailure = nil
            motherMoldBuildFailureSignature = nil
        }
        switch action {
        case .makeWatertight:
            // Never run a method nobody picked: show the Issues choices
            // (Fix in place / Make walls / Rebuild as solid).
            isStatsVisible = true
            inspectorTab = .issues
        case .buildMold:
            generateMotherMold()
        case .cancelBuild:
            cancelMotherMoldBuild()
        case .useFewerOrSmallerKeys:
            motherMoldSettings.key.pinsPerSeam = 1
            motherMoldSettings.key.pinDiameter = max(2, motherMoldSettings.key.pinDiameter * 0.75)
        case .useExternalFixture:
            if motherMoldSettings.usesReusableToolingContract {
                motherMoldSettings.masterPreparation.retentionMode = .externalFixture
            } else {
                motherMoldSettings.masterMount.mode = .externalFixture
            }
        case .placeSpoutManually:
            if let seed = MotherMoldUIContract.manualSpoutSeed(for: effectiveModel?.bounds) {
                motherMoldSettings.spout.manualSpoutX = seed.x
                motherMoldSettings.spout.manualSpoutY = seed.y
                motherMoldSettings.spout.manualSpoutZ = seed.z
            }
            motherMoldSettings.spout.mode = .manual
            motherMoldPlacementTarget = .pourHole
        case .approvePreparedMaster(let signature):
            approvePreparedMasterChanges(signature)
        case .reduceVents:
            motherMoldSettings.spout.ventCount = max(0, motherMoldSettings.spout.ventCount - 1)
            motherMoldSettings.spout.ventDiameter = max(0.5, motherMoldSettings.spout.ventDiameter * 0.75)
        case .disableClampingRim:
            motherMoldSettings.flange.enabled = false
        case .useAutoParting:
            motherMoldSettings.parting.mode = .auto
        case .useFewerParts:
            motherMoldSettings.parts = .two
            motherMoldSettings.parting.mode = .auto
        case .reviewBuildDetails:
            motherMoldBuildDetailsExpanded = true
        }
    }

    /// Approval is deliberately tied to the currently displayed plan. The
    /// signature is copied verbatim, then the planner is rerun; any geometry
    /// setting change yields a different plan signature and cannot inherit it.
    private func approvePreparedMasterChanges(_ displayedSignature: String) {
        guard !motherMoldResultIsStale,
              let plan = displayedMotherMoldPlan,
              plan.masterPreparation.approvalSignature == displayedSignature,
              !displayedSignature.isEmpty else {
            return
        }
        motherMoldSettings.approvedModificationSignature = displayedSignature
        generateMotherMold()
    }

    /// The mold plan handed to the viewport: only shown once it is current (a
    /// stale result is hidden so the 3D view never lies about the geometry).
    private var displayedMotherMoldPlan: MotherMoldPlan? {
        guard constructionMode == .motherMold,
              motherMoldPlacementTarget == nil,
              !motherMoldResultIsStale else { return nil }
        return generatedMotherMoldPlan
    }

    /// Export geometry and settings from the same completed build. The displayed
    /// plan is nil while stale, and the signature supplies that plan's settings.
    private var exportableMotherMold: MotherMoldUIContract.ExportSnapshot? {
        MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: displayedMotherMoldPlan,
            generatedSignature: generatedMotherMoldSignature,
            currentOutputSettings: motherMoldSettings.sanitized
        )
    }

    // MARK: - Inflatables generation

    private var inflatablesInputSignature: InflatablesInputSignature {
        InflatablesInputSignature(
            modelPath: model?.path,
            modelTriangleCount: effectiveModel?.triangleCount ?? 0,
            modelBounds: effectiveModel?.bounds.map { "\($0.min.display)|\($0.max.display)" },
            settings: inflatablesSettings.sanitized
        )
    }

    private var inflatablesResultIsStale: Bool {
        guard generatedInflatablesPlan != nil else { return false }
        return generatedInflatablesSignature != inflatablesInputSignature
    }

    private var inflatablesGenerateDisabledReason: String? {
        if effectiveModel == nil { return "Load a model first." }
        if isGeneratingInflatables { return "Generating…" }
        return nil
    }

    private var displayedInflatablesPlan: InflatablesPlan? {
        guard constructionMode == .inflatables, !inflatablesResultIsStale else { return nil }
        return generatedInflatablesPlan
    }

    private func generateInflatables() {
        guard inflatablesGenerateDisabledReason == nil, let model = effectiveModel else { return }
        let settings = inflatablesSettings.sanitized
        let signature = inflatablesInputSignature
        isGeneratingInflatables = true
        inflatablesGenerateMessage = nil

        Task {
            let outcome: Result<InflatablesPlan, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try InflatablesPlanner.plan(model: model.geometry, settings: settings))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            isGeneratingInflatables = false
            switch outcome {
            case .success(let plan):
                generatedInflatablesPlan = plan
                generatedInflatablesSignature = signature
                selectedInflatablePanelID = nil
                inflatablesViewMode = .inflated
                cutSheetDocument = plan.cutSheet
                viewportPreviewMode = .slices
                viewportMode = .modelAndSheet
                let panelWord = plan.panels.count == 1 ? "panel" : "panels"
                inflatablesGenerateMessage = "Generated \(plan.panels.count) inflatable \(panelWord)."
            case .failure(let error):
                generatedInflatablesPlan = nil
                generatedInflatablesSignature = nil
                selectedInflatablePanelID = nil
                cutSheetDocument = nil
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Inflatables planner produced no panels."
                inflatablesGenerateMessage = message
                errorMessage = message
            }
        }
    }

    @ViewBuilder private var inflatablesGenerateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                generateInflatables()
            } label: {
                HStack {
                    if isGeneratingInflatables {
                        ProgressView().controlSize(.small)
                    }
                    Label(
                        generatedInflatablesPlan == nil ? "Generate panels" : "Regenerate panels",
                        systemImage: "seal"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(inflatablesGenerateDisabledReason != nil)
            .accessibilityLabel(generatedInflatablesPlan == nil ? "Generate inflatable panels" : "Regenerate inflatable panels")

            if let reason = inflatablesGenerateDisabledReason, reason != "Generating…" {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if inflatablesResultIsStale {
                Label("Settings changed — regenerate to update the sheet.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = inflatablesGenerateMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if generatedInflatablesPlan == nil {
                Text("Press Generate panels to build the cut sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inspectorActions: some View {
        HStack(spacing: 8) {
            Button {
                importModel()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Import model")

            Button {
                loadSampleModel()
            } label: {
                Image(systemName: "cube")
            }
            .help("Load sample model")

            Button {
                openProject()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open project")

            Button {
                saveProject()
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .disabled(model == nil || !hasSelectedConstructionTechnique)
            .help("Save project")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let workspaceErrorNotice {
                WorkspaceErrorNotice(content: workspaceErrorNotice)
            }
            if constructionMode != .motherMold {
                exportFormatPicker
            }
            if exportFormat.usesVectorLayout {
                ExportLayoutPanel(
                    partSpacing: $exportPartSpacing,
                    pageMargin: $exportPageMargin,
                    sheetWidth: $exportSheetWidth,
                    sheetHeight: $exportSheetHeight,
                    supportsSheetLayout: exportFormat.usesSheetLayout,
                    summary: exportFormat.usesSheetLayout ? currentExportLayoutSummary : nil
                )
            }
            if exportFormat.usesVectorLayout || constructionMode == .inflatables {
                Button {
                    viewportMode = viewportMode == .sheet2D ? .model3D : .sheet2D
                } label: {
                    Label(
                        viewportMode == .sheet2D ? "Show 3D View" : "Preview Sheet",
                        systemImage: viewportMode == .sheet2D ? "cube" : "doc.viewfinder"
                    )
                }
                .disabled(cutSheetDocument == nil)
            }
            Button {
                exportCurrent()
            } label: {
                Label(
                    constructionMode == .motherMold
                        ? "Export \(MotherMoldExportRequest(packaging: motherMoldSettings.packaging).label)"
                        : "Export \(exportFormat.label)",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(exportDisabled)
            .help(exportButtonHelp)

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exportButtonHelp: String {
        if constructionMode == .motherMold {
            if let plan = displayedMotherMoldPlan,
               let reason = MotherMoldUIContract.blockingExportReason(for: plan) {
                return "Export unavailable. \(reason)"
            }
            return "Export the validated mold parts using the packaging selected in MotherMold Output."
        }
        return "Save the cut plans or sliced mesh in the chosen format, ready for fabrication."
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HeaderBar(
                model: effectiveModel,
                isSidebarVisible: isSidebarVisible,
                isStatsVisible: isStatsVisible,
                selectedConstructionMode: hasSelectedConstructionTechnique ? constructionMode : nil,
                viewportMode: $viewportMode,
                viewportPreviewMode: $viewportPreviewMode,
                motherMoldCanExplode: displayedMotherMoldPlan?.parts.isEmpty == false,
                motherMoldHasUndercuts: displayedMotherMoldPlan?.undercutReports.contains(where: { !$0.regions.isEmpty }) == true,
                motherMoldPartNames: displayedMotherMoldPlan?.parts.map(\.name) ?? [],
                motherMoldExploded: $motherMoldExploded,
                motherMoldShowUndercuts: $motherMoldShowUndercuts,
                isolatedMotherMoldPartName: $isolatedMotherMoldPartName,
                canShowSheetPreview: cutSheetDocument != nil,
                hasModel: effectiveModel != nil,
                toggleSidebar: {
                    isSidebarVisible.toggle()
                },
                toggleStats: {
                    isStatsVisible.toggle()
                }
            )
            Divider()
            if viewportMode == .sheet2D, let document = cutSheetDocument {
                ExportSheetPreview(
                    document: document,
                    selectedStepIndex: selectedAssemblyStepID,
                    onSelectStep: { selectedAssemblyStepID = $0 }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewportMode == .modelAndSheet, let document = cutSheetDocument {
                // Resizable split between the 3D viewport and the cut sheet.
                HSplitView {
                    sceneViewport
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    ExportSheetPreview(
                        document: document,
                        selectedStepIndex: selectedAssemblyStepID,
                        onSelectStep: { selectedAssemblyStepID = $0 }
                    )
                        .frame(minWidth: 260, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                sceneViewport
            }
        }
        .overlay { modelLoadingOverlay }
    }

    @ViewBuilder private var modelLoadingOverlay: some View {
        if isLoadingModel {
            ZStack {
                Color.black.opacity(0.10)
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var sceneViewport: some View {
        if viewportOccluded {
            // Parked: the window is fully covered or minimized. A plain color
            // keeps layout; the scene remounts when the window reappears.
            Color(nsColor: .windowBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sceneViewportLive
        }
    }

    /// MotherMold reuses the structure-plan preview channel. Resolving which
    /// plan (if any) feeds the viewport here keeps the large `sceneViewportLive`
    /// expression simple enough for the Swift type-checker.
    private var viewportStructurePlan: StructureMeshPlan? {
        guard viewportPreviewMode.showsSlicePreview else { return nil }
        return displayedStructurePlan
    }

    private var sceneViewportLive: some View {
        ModelSceneView(
            model: displayedModel,
            sliceFrameModel: planningModel,
            sliceFrameRotationDegrees: sliceFrameRotationDegrees,
            bakedModelRotationDegrees: modelRotationDegrees,
            liveModelRotationPreviewDegrees: liveModelRotationPreview,
            liveSliceTiltPreviewDegrees: liveSliceTiltPreview.map {
                SliceDirection.meshRotationDegrees(axis: sliceDirectionAxis, tiltFirst: $0.x, tiltSecond: $0.y)
            },
            modelRotationPivot: model?.bounds.map {
                Vec3(
                    x: ($0.min.x + $0.max.x) / 2,
                    y: ($0.min.y + $0.max.y) / 2,
                    z: ($0.min.z + $0.max.z) / 2
                )
            },
            sliceDirectionAdjustActive: sliceDirectionAdjustMode && constructionMode != .foldedPanels,
            sliceDirectionTiltBasis: sliceDirectionAxis,
            sliceTilt: Vec2(x: sliceTiltFirst, y: sliceTiltSecond),
            liveSliceTilt: liveSliceTiltPreview,
            onSliceTiltPreview: { liveSliceTiltPreview = $0 },
            onSliceTiltCommit: { pair in
                sliceTiltFirst = pair.x
                sliceTiltSecond = pair.y
                liveSliceTiltPreview = nil
            },
            modelRotationAdjustActive: modelRotateGizmoActive && model != nil,
            onModelRotationPreview: { liveModelRotationPreview = $0 },
            onModelRotationCommit: { rotation in
                modelRotationDegrees = rotation
                liveModelRotationPreview = nil
            },
            showImportedModel: motherMoldPlacementTarget != nil || viewportPreviewMode.showsModel,
            appearance: viewportAppearance,
            previewMaterialThickness: materialThickness,
            slicePlans: viewportPreviewMode.showsSlicePreview && constructionMode != .threeD ? previewPlans : [],
            interlockedPlan: viewportPreviewMode.showsSlicePreview ? previewInterlockedPlan : nil,
            threeDPlan: viewportPreviewMode.showsSlicePreview ? previewThreeDPlan : nil,
            radialPlan: viewportPreviewMode.showsSlicePreview ? previewRadialPlan : nil,
            curvePlan: viewportPreviewMode.showsSlicePreview ? previewCurvePlan : nil,
            foldedPanelPlan: viewportPreviewMode.showsSlicePreview ? previewFoldedPanelPlan : nil,
            inflatablePlan: viewportPreviewMode.showsSlicePreview ? previewInflatablesPlan : nil,
            inflatableViewMode: inflatablesViewMode,
            selectedInflatablePanelID: selectedInflatablePanelID,
            onInflatablePanelSelect: { selectedInflatablePanelID = $0 },
            structurePlan: viewportStructurePlan,
            motherMoldPlan: viewportPreviewMode.showsSlicePreview ? displayedMotherMoldPlan : nil,
            motherMoldExploded: motherMoldExploded,
            motherMoldShowUndercuts: motherMoldShowUndercuts,
            motherMoldIsolatedPartName: isolatedMotherMoldPartName,
            motherMoldVisibleLayers: motherMoldVisibleLayers,
            motherMoldPrebuildOverlay: motherMoldPrebuildOverlay,
            motherMoldSurfacePickingEnabled: motherMoldPlacementTarget != nil,
            onMotherMoldSurfacePick: applyMotherMoldSurfacePick,
            partitionPlan: viewportPreviewMode.showsSlicePreview ? displayedPartitionPlan : nil,
            undercutSplitOverlay: viewportPreviewMode.showsSlicePreview ? displayedUndercutOverlay : nil,
            undercutCutEditMode: constructionMode == .partition
                && partitionSettings.purpose == .splitByUndercuts
                && undercutCutEditMode3D,
            undercutFacePaintMode: undercutFacePaintMode,
            onUndercutRegionHover: { hoveredUndercutRegionID = $0 },
            onUndercutCutNodeHover: { hoveredUndercutCutNodeID = $0 },
            onUndercutCutNodeSelect: { selectedUndercutCutNodeID = $0 },
            onUndercutCutNodeMoved: { nodeID, plane in
                moveUndercutCutNode(nodeID: nodeID, to: plane)
            },
            onUndercutCutNodeDeleteKey: { deleteUndercutCutNode($0) },
            onUndercutSourceFacePaint: { toggleUndercutFacePaint($0) },
            partitionExplode: partitionSettings.explodePreview,
            partitionEditMode: constructionMode == .partition
                && partitionSettings.purpose == .fitPrinter
                && partitionSettings.mode == .manual
                && partitionEditMode3D,
            partitionManualPlanes: partitionSettings.manualPlanes,
            selectedPartitionPlaneIndex: selectedPartitionPlaneIndex,
            onPartitionPlaneSelect: { selectedPartitionPlaneIndex = $0 },
            onPartitionPlaneMoved: { index, offset in handlePartitionPlaneMoved(index: index, offset: offset) },
            onPartitionPlaneDeleteKey: { handlePartitionPlaneDelete() },
            highlightedAssemblyStep: viewportPreviewMode.showsSlicePreview ? selectedAssemblyStepHighlight : nil,
            renderStyle: sliceSolidRenderStyle,
            dowelSettings: constructionMode == .stacked && viewportPreviewMode.showsSlicePreview ? dowelSettings : nil,
            dowelEditMode: constructionMode == .stacked && dowelsEnabled && dowelEditMode3D
                && viewportPreviewMode.showsSlicePreview && sliceComputationEnabled,
            selectedDowelPlan: selectedDowelPlan,
            onDowelAdd: { handleDowelAdd(planPoint: $0) },
            onDowelMove: { handleDowelMove(from: $0, to: $1) },
            onDowelRemove: { handleDowelRemove(near: $0) },
            onDowelSelect: { selectedDowelPlan = $0 },
            onDowelDeleteKey: {
                if let selected = selectedDowelPlan {
                    handleDowelRemove(near: selected)
                }
            },
            // NEO-103: Slice editing in the 3D viewport.
            sliceEditMode: constructionMode == .stacked && sliceEditMode3D && viewportPreviewMode.showsSlicePreview && sliceComputationEnabled,
            selectedSliceIndex: selectedSliceIndex,
            onSliceSelect: { handleSliceSelect(index: $0) },
            onSliceMoveCommit: { handleSliceMoveCommit(index: $0, toAxisPosition: $1) },
            // NEO-104: Add/Remove Seams edge clicks in the folded viewport.
            seamEditMode: constructionMode == .foldedPanels && foldedSeamEditMode
                && viewportPreviewMode.showsSlicePreview && sliceComputationEnabled,
            onSeamEdgeToggle: { toggleFoldedSeamEdge($0) },
            issueSites: viewportIssueSites,
            selectedIssueSiteID: selectedIssueSiteID,
            issueFocusRequest: issueFocusRequest,
            onIssueSiteSelect: { selectIssueSite($0) },
            issueMarkersVisible: showIssueMarkers,
            cameraState: $viewportCamera
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog(
                "Delete this cut and its descendant cuts?",
                isPresented: Binding(
                    get: { pendingUndercutCutNodeDeletion != nil },
                    set: { if !$0 { pendingUndercutCutNodeDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete cut subtree", role: .destructive) {
                    confirmUndercutCutNodeDeletion()
                }
                Button("Cancel", role: .cancel) {
                    pendingUndercutCutNodeDeletion = nil
                }
            } message: {
                Text("The selected cut and every cut below it will be removed. Face paint is retained; descendant pull locks are dropped and reported.")
            }
            // Remember the viewport look across launches.
            .onChange(of: viewportAppearance) { _, newValue in
                ViewportAppearanceStore.save(newValue)
            }
            // The Slice Direction bottom bar: the exact angle, editable, with
            // Reset — shown only while the rings are up.
            .overlay(alignment: .bottom) {
                if sliceDirectionAdjustMode && constructionMode != .foldedPanels && effectiveModel != nil {
                    sliceDirectionAngleBar
                        .padding(.bottom, 10)
                } else if let hint = viewportEditHint {
                    // Edit-mode interaction hint, shown where the user is
                    // looking (the rail tooltips went unread).
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            // ViewCube: top-right corner, above the nav strip.
            .overlay(alignment: .topTrailing) {
                ViewCubeOverlay(cameraState: $viewportCamera, isEnabled: effectiveModel != nil)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
            }
            // The navigation strip floats vertically along the viewport's
            // RIGHT edge.
            .overlay(alignment: .trailing) {
                ViewportControls(
                    cameraState: $viewportCamera,
                    cameraRadius: ViewportCamera.radius(bounds: viewportBounds),
                    isEnabled: effectiveModel != nil,
                    isOrthographic: Binding(
                        get: { viewportCamera.isOrthographic },
                        set: { viewportCamera.isOrthographic = $0 }
                    )
                )
                    .padding(.trailing, 12)
            }
            .overlay {
                if model == nil {
                    EmptyViewportState(
                        content: workspaceEmptyState,
                        importAction: importModel,
                        sampleAction: loadSampleModel
                    )
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(model == nil ? "Import a model to inspect it in 3D" : "3D viewport")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
    }

    private var exportFormatPicker: some View {
        // Menu, not segmented: a 6-segment macOS segmented control has a rigid
        // ~300pt minimum width that overflowed the rail pane the moment the
        // Export section appeared after slicing, center-clipping the whole rail.
        HStack(spacing: 10) {
            Text("Format")
                .foregroundStyle(.secondary)
            Picker("Export format", selection: $exportFormat) {
                ForEach(availableExportFormats) { format in
                    Text(format.label).tag(format)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        }
        .help("The file type for your cut plans. PDF is easiest to open; DXF and EPS keep cut profiles on layers for laser cutting; OBJ/STL export the sliced 3D mesh instead of 2D plans.")
    }

    private var availableExportFormats: [ExportFormat] {
        ExportFormatSupport.availableFormats(for: constructionMode)
    }

    private var projectSettings: SlicerProjectSettings {
        SlicerProjectSettings(
            constructionMode: constructionMode,
            sliceAxis: sliceAxis,
            sliceTiltFirst: sliceTiltFirst,
            sliceTiltSecond: sliceTiltSecond,
            secondarySliceAxis: secondarySliceAxis,
            materialThickness: materialThickness,
            threeDSliceDepth: threeDSliceDepth,
            slotClearance: slotClearance,
            notchWidthOverrideEnabled: notchWidthOverrideEnabled,
            notchWidth: notchWidth,
            slotAngleDegrees: slotAngleDegrees,
            radialSliceCount: radialSliceCount,
            radialFirstAxisByDistance: radialFirstAxisByDistance,
            radialFirstAxisCount: radialFirstAxisCount,
            radialFirstAxisSpacing: radialFirstAxisSpacing,
            radialNotchFactor: radialNotchFactor,
            radialReliefType: radialReliefType.rawValue,
            // Older builds read the per-mode diameters; both mirror Tool Dia.
            radialToolDiameter: materialToolDiameter,
            curvePrimaryAxis: curvePrimaryAxis,
            curveFirstAxisCount: curveFirstAxisCount,
            curveSliceCount: curveSliceCount,
            curveAmplitude: curveAmplitude,
            materialPreset: materialPreset,
            slotReliefEnabled: slotReliefEnabled,
            slotReliefDiameter: materialToolDiameter,
            toolDiameter: materialToolDiameter,
            dowelsEnabled: dowelsEnabled,
            dowelDiameter: dowelDiameter,
            dowelInset: dowelInset,
            dowelManualPositions: customDowelPositions.isEmpty
                ? nil
                : customDowelPositions.flatMap { [$0.x, $0.y] },
            dowelShape: dowelShape.rawValue,
            dowelAutomaticCount: dowelAutomaticCount,
            dowelUseAutomatic: dowelUseAutomatic,
            foldedDetailFaces: foldedDetailFaces,
            foldedJoinery: foldedJoinery,
            foldedSplitPanels: foldedSplitPanels,
            foldedSeamEdges: foldedSeamEdges.isEmpty
                ? nil
                : foldedSeamEdges.flatMap { [$0.a.x, $0.a.y, $0.a.z, $0.b.x, $0.b.y, $0.b.z] },
            exportFormat: exportFormat,
            exportLayoutSettings: exportLayoutSettings,
            modelScaleFactor: modelScale.x,
            modelTransform: [modelScale.x, modelScale.y, modelScale.z, modelRotationDegrees.x, modelRotationDegrees.y, modelRotationDegrees.z],
            importUnit: importUnit,
            importUpAxis: importUpAxis,
            customSliceDistributionEnabled: customSliceDistributionEnabled,
            customSliceCount: customSliceCount,
            sliceSolidRenderStyle: sliceSolidRenderStyle.rawValue,
            sliceDistributionMethod: sliceDistributionMethod.rawValue,
            sliceByDistanceSpacingMm: sliceByDistanceSpacingMm,
            customSlicePositions: customSlicePositions.isEmpty ? nil : customSlicePositions,
            modifyTool: modifyActiveTool?.rawValue,
            modifyHollowWallMm: modifyHollowWallThickness,
            modifyThickenMm: modifyThickenAmount,
            modifyShrinkwrapDetail: modifyShrinkwrapDetail,
            // Saved whenever the user picked it OR Make Watertight is on, so
            // undo / redo / reopening reproduces the result on screen (a
            // missing method on an active Make Watertight reads as legacy).
            modifyWatertightMethod: WatertightMethod.shouldPersist(
                chosen: watertightMethodChosen,
                activeTool: modifyActiveTool,
                preprocessEnabled: watertightPreprocessEnabled
            ) ? modifyWatertightMethod.rawValue : nil,
            modifyWatertightBase: (watertightPreprocessEnabled && modifyActiveTool != nil && modifyActiveTool != .shrinkwrap) ? true : nil,
            modifyWatertightTopHeightMm: modifyWatertightTopHeight,
            modifyWallThicknessMm: modifyWallThickness,
            modifyOpeningChoices: modifyOpeningChoices.isEmpty ? nil : modifyOpeningChoices,
            structureSettings: structureSettings,
            partitionSettings: partitionSettings,
            motherMoldSettings: motherMoldSettings,
            inflatablesSettings: inflatablesSettings
        )
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileDialogTypes.modelImports
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Accessory view: "Up axis: [Z (default) ▾]" — lets the user change
        // the mesh's up-axis while choosing the file.
        let accessory = ImportUpAxisAccessoryView()
        panel.accessoryView = accessory.view

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        // Capture the chosen axis before the panel goes away.
        let chosenUpAxis = accessory.selectedUpAxis

        loadModel(from: url) { summary in
            let orientedSummary = modelOrientedForImport(summary, upAxis: chosenUpAxis)
            model = orientedSummary
            hasSelectedConstructionTechnique = false
            isTechniqueChooserExpanded = false
            sliceComputationEnabled = false
            customDowelPositions = []
            // Fresh model: automatic dowels show immediately.
            dowelUseAutomatic = true
            dowelAutomaticCount = 2
            dowelShape = .round
            dowelEditMode3D = false
            selectedDowelPlan = nil
            resetModifyForm()
            modelScale = Vec3(x: 1, y: 1, z: 1)
            // Import up-axis is file metadata, not an Object Size rotation.
            // Bake it into the imported mesh so H/W/L and user rotations stay
            // in the same frame.
            modelRotationDegrees = Vec3(x: 0, y: 0, z: 0)
            importUpAxis = chosenUpAxis
            let detectedUnit = MeshScaler.bestFitUnit(forLongestDimension: longestModelDimension(of: orientedSummary))
            importUnit = detectedUnit
            lastExportFailure = nil
            viewportCamera.reset()
            selectedAssemblyStepID = nil
            exportMessage = importScaleNotice(for: summary, unit: detectedUnit)
            // NEO-114: imports start a fresh history. The latch carries the
            // FINAL settings value because onChange observes this whole
            // closure as one transition, after it returns.
            undoHistory.reset()
            lastRestoredSettings = projectSettings
        }
    }

    private func longestModelDimension(of summary: MeshSummary) -> Double {
        guard let dimensions = MeshScaler.dimensions(for: summary.bounds) else { return 0 }
        return max(dimensions.width, max(dimensions.depth, dimensions.height))
    }

    private func importScaleNotice(for summary: MeshSummary, unit: ImportUnitPreset) -> String? {
        guard unit != .millimeters else { return nil }
        let spanMM = longestModelDimension(of: summary) * MeshScaler.combinedFactor(unit: unit, userScale: 1.0)
        return "Imported in \(unit.label) — model spans ~\(Int(spanMM.rounded())) mm. Adjust units in Scale if needed."
    }

    private func loadSampleModel() {
        guard let url = SampleModelResource.url() else {
            lastModelLoadFailure = "Bundled sample model is missing."
            errorMessage = "Bundled sample model is missing."
            return
        }

        loadModel(from: url) { summary in
            model = summary
            hasSelectedConstructionTechnique = false
            isTechniqueChooserExpanded = false
            sliceComputationEnabled = false
            customDowelPositions = []
            // Fresh model: automatic dowels show immediately.
            dowelUseAutomatic = true
            dowelAutomaticCount = 2
            dowelShape = .round
            dowelEditMode3D = false
            selectedDowelPlan = nil
            resetModifyForm()
            modelScale = Vec3(x: 1, y: 1, z: 1)
            modelRotationDegrees = Vec3(x: 0, y: 0, z: 0)
            importUpAxis = .z
            importUnit = MeshScaler.bestFitUnit(forLongestDimension: longestModelDimension(of: summary))
            lastExportFailure = nil
            viewportCamera.reset()
            selectedAssemblyStepID = nil
            exportMessage = "Loaded \(SampleModelResource.displayName)"
            // NEO-114: fresh history; latch the final settings (see import).
            undoHistory.reset()
            lastRestoredSettings = projectSettings
        }
    }

    /// Inspects a mesh OFF the main thread so a large or broken model can't
    /// freeze the UI on open. `MeshInspector.inspect` is ~1s for a 107k-triangle
    /// mesh and scales with triangle count (an ~890k-tri model froze the app for
    /// several seconds). A loading indicator shows while it runs; `onLoaded`
    /// applies caller-specific state back on the main actor.
    private func loadModel(from url: URL, onLoaded: @escaping (MeshSummary) -> Void) {
        cancelMotherMoldBuild(showMessage: false)
        isLoadingModel = true
        errorMessage = nil
        lastModelLoadFailure = nil
        Task { @MainActor in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try MeshInspector.inspect(url: url)
                }.value
                onLoaded(summary)
            } catch {
                lastModelLoadFailure = error.localizedDescription
                errorMessage = error.localizedDescription
            }
            isLoadingModel = false
        }
    }

    private func modelOrientedForImport(_ summary: MeshSummary, upAxis: ImportUpAxis) -> MeshSummary {
        upAxis.orientedModel(summary)
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileDialogTypes.projectOpen
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let document = try JSONDecoder().decode(SlicerProjectDocument.self, from: Data(contentsOf: url))
            let modelURL = URL(fileURLWithPath: document.modelPath)
            loadModel(from: modelURL) { summary in
                // A fresh load: nothing of the previous model's Make
                // Watertight state survives, and the diagnosis re-runs even
                // for the same file. applyProjectSettings restores the rest.
                resetModifyForm()
                importUpAxis = document.settings.importUpAxis ?? .z
                model = modelOrientedForImport(summary, upAxis: importUpAxis)
                sliceComputationEnabled = false
                applyProjectSettings(document.settings)
                lastExportFailure = nil
                viewportCamera.reset()
                selectedAssemblyStepID = nil
                exportMessage = "Opened project \(url.lastPathComponent)"
                // NEO-114: fresh history; latch the final settings (see import).
                undoHistory.reset()
                lastRestoredSettings = projectSettings
            }
        } catch {
            lastModelLoadFailure = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    private func saveProject() {
        guard hasSelectedConstructionTechnique,
              let model else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [FileDialogTypes.project]
        panel.nameFieldStringValue = model.name.replacingOccurrences(of: ".", with: "-") + ".\(SlicerProjectDocument.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let document = SlicerProjectDocument(modelPath: model.path, settings: projectSettings.sanitized)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            exportMessage = "Saved project \(url.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyProjectSettings(_ rawSettings: SlicerProjectSettings) {
        cancelMotherMoldBuild(showMessage: false)
        let settings = rawSettings.sanitized
        constructionMode = settings.constructionMode
        hasSelectedConstructionTechnique = true
        isTechniqueChooserExpanded = false
        sliceAxis = settings.sliceAxis
        sliceTiltFirst = settings.sliceTiltFirst ?? 0
        sliceTiltSecond = settings.sliceTiltSecond ?? 0
        secondarySliceAxis = settings.secondarySliceAxis
        materialThickness = settings.materialThickness
        threeDSliceDepth = settings.threeDSliceDepth
        slotClearance = settings.slotClearance
        notchWidthOverrideEnabled = settings.notchWidthOverrideEnabled
        notchWidth = settings.notchWidth
        slotAngleDegrees = settings.slotAngleDegrees
        radialSliceCount = settings.radialSliceCount
        radialFirstAxisByDistance = settings.radialFirstAxisByDistance ?? false
        radialFirstAxisCount = settings.radialFirstAxisCount ?? 10
        radialFirstAxisSpacing = settings.radialFirstAxisSpacing ?? 15.0
        radialNotchFactor = settings.radialNotchFactor ?? 0.1
        radialReliefType = settings.radialReliefType.flatMap(RadialReliefType.init(rawValue:)) ?? .square
        curvePrimaryAxis = settings.curvePrimaryAxis
        curveFirstAxisCount = settings.curveFirstAxisCount
        curveSliceCount = settings.curveSliceCount
        curveAmplitude = settings.curveAmplitude
        materialPreset = settings.materialPreset
        slotReliefEnabled = settings.slotReliefEnabled
        // Tool Dia.: the saved value, or an older project's per-mode tool
        // diameter (SlicerProjectSettings.resolvedToolDiameter).
        if let toolDiameter = settings.resolvedToolDiameter {
            materialToolDiameter = toolDiameter
        }
        dowelsEnabled = settings.dowelsEnabled
        dowelDiameter = settings.dowelDiameter
        dowelInset = settings.dowelInset
        if let flat = settings.dowelManualPositions, flat.count >= 2 {
            customDowelPositions = stride(from: 0, to: flat.count - flat.count % 2, by: 2)
                .map { Vec2(x: flat[$0], y: flat[$0 + 1]) }
        } else {
            customDowelPositions = []
        }
        dowelShape = settings.dowelShape.flatMap(DowelShape.init(rawValue:)) ?? .round
        dowelAutomaticCount = settings.dowelAutomaticCount ?? 2
        dowelUseAutomatic = settings.dowelUseAutomatic ?? true
        // NEO-113: non-destructive Modify Form — restore the active tool and
        // start its mesh computing (the model is already loaded here).
        modifyHollowWallThickness = settings.modifyHollowWallMm ?? 3.0
        modifyThickenAmount = settings.modifyThickenMm ?? 2.0
        modifyShrinkwrapDetail = settings.modifyShrinkwrapDetail ?? 0.5
        modifyActiveTool = settings.modifyTool.flatMap(ModifyFormTool.init(rawValue:))
        // Make Watertight under Hollow / Thicken is saved too, so undo, redo
        // and reopening restore exactly what was on (never a stale flag).
        watertightPreprocessEnabled = modifyActiveTool == .shrinkwrap
            || (modifyActiveTool != nil && settings.modifyWatertightBase == true)
        modifyWatertightTopHeight = settings.modifyWatertightTopHeightMm ?? 0
        modifyWallThickness = settings.modifyWallThicknessMm ?? 2.0
        modifyOpeningChoices = settings.modifyOpeningChoices ?? []
        openingChoicesNotice = nil
        if let method = WatertightMethod.restored(
            saved: settings.modifyWatertightMethod,
            activeTool: modifyActiveTool,
            savedTopHeight: settings.modifyWatertightTopHeightMm
        ) {
            modifyWatertightMethod = method
            watertightMethodChosen = true
        } else {
            // No pick saved: Fix in place (never a silent Rebuild).
            modifyWatertightMethod = .closeOpenings
            watertightMethodChosen = false
        }
        modifyPreviewTool = nil
        modifyComputedKey = nil
        modifyComputedMesh = nil
        watertightOutcomes = [:]
        if let active = modifyActiveTool {
            ensureModifiedMesh(for: active)
        }
        foldedDetailFaces = settings.foldedDetailFaces ?? 250
        // NEO-104: legacy projects (nil) keep the Diamond default.
        foldedJoinery = settings.foldedJoinery?.sanitized ?? .preset(for: .diamond)
        foldedSplitPanels = settings.foldedSplitPanels ?? false
        if let flat = settings.foldedSeamEdges, flat.count >= 6 {
            foldedSeamEdges = stride(from: 0, to: flat.count - flat.count % 6, by: 6).map {
                FoldedSeamEdge(
                    a: Vec3(x: flat[$0], y: flat[$0 + 1], z: flat[$0 + 2]),
                    b: Vec3(x: flat[$0 + 3], y: flat[$0 + 4], z: flat[$0 + 5])
                )
            }
        } else {
            foldedSeamEdges = []
        }
        dowelEditMode3D = false
        selectedDowelPlan = nil
        exportFormat = settings.exportFormat
        exportPartSpacing = settings.exportLayoutSettings.partSpacing
        exportPageMargin = settings.exportLayoutSettings.pageMargin
        exportSheetWidth = settings.exportLayoutSettings.sheetWidth
        exportSheetHeight = settings.exportLayoutSettings.sheetHeight
        if let transform = settings.modelTransform, transform.count == 6 {
            modelScale = Vec3(x: transform[0], y: transform[1], z: transform[2])
            modelRotationDegrees = Vec3(x: transform[3], y: transform[4], z: transform[5])
        } else {
            // Legacy projects carry a single uniform factor.
            modelScale = Vec3(x: settings.modelScaleFactor, y: settings.modelScaleFactor, z: settings.modelScaleFactor)
            modelRotationDegrees = Vec3(x: 0, y: 0, z: 0)
        }
        importUnit = settings.importUnit
        importUpAxis = settings.importUpAxis ?? importUpAxis
        customSliceDistributionEnabled = settings.customSliceDistributionEnabled
        customSliceCount = settings.customSliceCount
        sliceSolidRenderStyle = settings.sliceSolidRenderStyle
            .flatMap(SliceSolidRenderStyle.init(rawValue:)) ?? .cardboard
        // NEO-103: restore slice distribution method (legacy files default to .automatic).
        sliceDistributionMethod = settings.sliceDistributionMethod
            .flatMap(SliceDistributionMethod.init(rawValue:)) ?? .automatic
        sliceByDistanceSpacingMm = settings.sliceByDistanceSpacingMm ?? 5.0
        customSlicePositions = settings.customSlicePositions ?? []
        sliceEditMode3D = false
        selectedSliceIndex = nil
        // Structures: restore the saved settings; any cached generated mesh is
        // discarded so the user re-runs Generate against the restored model.
        structureSettings = settings.structureSettings ?? .defaultValue
        generatedStructurePlan = nil
        generatedStructureSignature = nil
        structureGenerateMessage = nil
        // Partition: restore settings; discard any cached pieces so the user
        // re-runs Partition against the restored model.
        partitionSettings = settings.partitionSettings ?? .defaultValue
        partitionCancellationFlag?.cancel()
        partitionGenerationTask?.cancel()
        partitionGenerationTask = nil
        partitionCancellationFlag = nil
        activeUndercutGenerationToken = nil
        isGeneratingPartition = false
        generatedPartitionPlan = nil
        generatedPartitionSignature = nil
        generatedUndercutPartitionPlan = nil
        generatedUndercutOverlay = nil
        undercutGenerationState = PartitionUndercutGenerationState()
        partitionFingerprintSnapshot = nil
        partitionGenerateMessage = nil
        undercutPartitionGenerateMessage = nil
        undercutPlanningStartedAt = nil
        undercutCutEditMode3D = false
        selectedUndercutCutNodeID = nil
        hoveredUndercutCutNodeID = nil
        selectedUndercutPieceRegionID = nil
        isolatedUndercutPieceRegionID = nil
        hoveredUndercutRegionID = nil
        pendingUndercutCutNodeDeletion = nil
        undercutFacePaintMode = .none
        // MotherMold: restore the saved settings; any cached generated plan is
        // discarded so the user re-runs Build mold against the restored model.
        motherMoldSettings = settings.motherMoldSettings ?? .defaultValue
        generatedMotherMoldPlan = nil
        generatedMotherMoldSignature = nil
        motherMoldGenerateMessage = nil
        motherMoldBuildFailure = nil
        motherMoldBuildFailureSignature = nil
        motherMoldBuildDetailsExpanded = false
        // Inflatables: restore settings; discard cached panels so the user
        // regenerates against the restored model.
        inflatablesSettings = settings.inflatablesSettings ?? .defaultValue
        generatedInflatablesPlan = nil
        generatedInflatablesSignature = nil
        selectedInflatablePanelID = nil
        inflatablesViewMode = .inflated
        inflatablesGenerateMessage = nil
        viewportMode = settings.exportFormat.usesVectorLayout ? viewportMode : .model3D
    }

    private var exportDisabled: Bool {
        guard hasSelectedConstructionTechnique else { return true }
        switch constructionMode {
        case .stacked:
            return slicePlan == nil
        case .interlocked:
            return interlockedPlan == nil
        case .radial:
            return radialPlan == nil
        case .curve:
            return curvePlan == nil
        case .threeD:
            return threeDPlan == nil
        case .foldedPanels:
            return foldedPanelPlan?.panels.isEmpty ?? true
        case .structures:
            // Export only a fresh result that matches the live model/settings.
            return displayedStructurePlan == nil
        case .partition:
            // Fit Printer keeps its fresh-only rule. Split by Undercuts keeps
            // prior/stale/error-result pieces export-addressable (PRD R1).
            return exportablePartitionPlan == nil
        case .motherMold:
            return exportableMotherMold == nil
        case .inflatables:
            return generatedInflatablesPlan == nil || inflatablesResultIsStale
        }
    }

    /// The flat parts a vector export of the current mode writes; nil for
    /// the mesh-only modes or before a plan exists.
    private var flatPartSource: FlatPartExport.Source? {
        switch constructionMode {
        case .stacked:
            return slicePlan.map { .stacked($0, contours: nil, dowels: dowelSettings) }
        case .interlocked:
            return interlockedPlan.map { .interlocked($0) }
        case .radial:
            return radialPlan.map { .radial($0) }
        case .curve:
            return currentCurvePlan().map { .curve($0) }
        case .threeD:
            return threeDPlan.map { .threeD($0) }
        case .foldedPanels:
            return currentFoldedPanelPlan().map { .foldedPanels($0) }
        case .inflatables:
            return displayedInflatablesPlan.map { .inflatables($0) }
        case .structures, .partition, .motherMold:
            return nil
        }
    }

    private func exportCurrent() {
        guard hasSelectedConstructionTechnique,
              let model = effectiveModel else {
            return
        }
        // The slice modes cut their parts from the model their plans were
        // laid out on (`planningModel`: turned into the slicing frame under a
        // Slice Direction tilt), as the cut sheet and the viewport do.
        let sliceModel = planningModel ?? model
        let panel = NSSavePanel()
        // NEO-109: EPS with multiple sheets → ZIP of per-sheet files. Ask the
        // EPS writer how many it will write, so the extension matches.
        var epsFileCount = 1
        if exportFormat == .eps, let source = flatPartSource {
            epsFileCount = (try? FlatPartExport.epsFileCount(source, model: sliceModel, settings: exportLayoutSettings) {
                guard let document = cutSheetDocument else {
                    throw FlatPartExport.ExportError.cutSheetNotReady
                }
                return document
            }) ?? 1
        }
        let epsIsMultiSheet = epsFileCount > 1
        // Partition with separate-files packaging writes a .zip of per-piece meshes.
        let partitionIsZip = constructionMode == .partition
            && (partitionSettings.purpose == .splitByUndercuts
                || partitionSettings.packaging == .separateZip)
        let motherMoldRequest = constructionMode == .motherMold
            ? MotherMoldExportRequest(packaging: motherMoldSettings.packaging)
            : nil
        let wantsZip = epsIsMultiSheet || partitionIsZip || motherMoldRequest?.payload == .stlArchive
        let exportExtension: String = motherMoldRequest?.pathExtension
            ?? (wantsZip ? "zip" : exportFormat.rawValue)
        let exportUTType: UTType
        if wantsZip {
            exportUTType = .zip
        } else if motherMoldRequest?.payload == .combinedOBJ {
            exportUTType = FileDialogTypes.export(for: .obj)
        } else if motherMoldRequest?.payload == .laidOutSTL {
            exportUTType = FileDialogTypes.export(for: .stl)
        } else {
            exportUTType = FileDialogTypes.export(for: exportFormat)
        }
        panel.allowedContentTypes = [exportUTType]
        let exportStem = constructionMode == .partition
            && partitionSettings.purpose == .splitByUndercuts
            ? "undercut-split"
            : constructionMode.rawValue
        panel.nameFieldStringValue = model.name.replacingOccurrences(of: ".", with: "-") + "-\(exportStem).\(exportExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if constructionMode == .partition,
           partitionSettings.purpose == .splitByUndercuts {
            exportUndercutPartitionOffMain(model: model, to: url)
            return
        }

        do {
            let layoutSettings = exportLayoutSettings
            // Vector formats (DXF/SVG/PDF/EPS) go through FlatPartExport, the
            // same writer table the headless CLI uses. Cut-sheet writers reuse
            // the document the sheet preview already built.
            var flatPartWriter: FlatPartExport.Writer?
            func writeFlatParts(_ source: FlatPartExport.Source) throws {
                flatPartWriter = try FlatPartExport.write(
                    source,
                    format: exportFormat,
                    model: sliceModel,
                    settings: layoutSettings,
                    cutSheet: {
                        guard let document = cutSheetDocument else {
                            throw FlatPartExport.ExportError.cutSheetNotReady
                        }
                        return document
                    },
                    to: url
                )
            }
            switch constructionMode {
            case .stacked:
                guard let slicePlan else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.stacked(slicePlan, contours: nil, dowels: dowelSettings))
                case .obj:
                    let contours = StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: sliceModel, plan: slicePlan))
                    let holeLayers = StackedDowelMeshBuilder.layers(contours: contours, materialThickness: slicePlan.materialThickness, dowels: dowelsEnabled ? dowelSettings : nil)
                    if holeLayers.isEmpty {
                        try ObjExporter.write(contours: contours, materialThickness: slicePlan.materialThickness, to: url)
                    } else {
                        // Dowel HOLES carved through the slice solids, so the
                        // exported 3D parts can actually thread the rods.
                        try ObjExporter.write(meshLayers: holeLayers, to: url, title: "stacked slice")
                    }
                case .stl:
                    let contours = StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: sliceModel, plan: slicePlan))
                    let holeLayers = StackedDowelMeshBuilder.layers(contours: contours, materialThickness: slicePlan.materialThickness, dowels: dowelsEnabled ? dowelSettings : nil)
                    if holeLayers.isEmpty {
                        try StlExporter.write(contours: contours, materialThickness: slicePlan.materialThickness, to: url)
                    } else {
                        try StlExporter.write(meshes: holeLayers.map(\.mesh), to: url, solidName: "refabartist_stacked_slices")
                    }
                }
                let dowelText = dowelsEnabled ? " with dowel holes" : ""
                exportMessage = "Exported \(slicePlan.sliceCount) stacked slices\(dowelText) to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .interlocked:
                guard let interlockedPlan else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.interlocked(interlockedPlan))
                case .obj:
                    try ObjExporter.write(interlocked: interlockedPlan, model: sliceModel, to: url)
                case .stl:
                    try StlExporter.write(interlocked: interlockedPlan, model: sliceModel, to: url)
                }
                // The relief the cut sheet cuts (none where slots merge); the
                // STL/OBJ solids carry none.
                let reliefCount = exportFormat.usesVectorLayout ? (cutSheetDocument?.reliefCutCount ?? 0) : 0
                let reliefText = reliefCount > 0 ? " and \(reliefCount) relief circles" : ""
                exportMessage = "Exported \(interlockedPlan.sliceCount) interlocked slices with \(interlockedPlan.slotCount) slots\(reliefText) at \(Vec3.format(interlockedPlan.slotWidth)) mm to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .radial:
                guard let radialPlan else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.radial(radialPlan))
                case .obj:
                    try ObjExporter.write(radial: radialPlan, model: sliceModel, materialThickness: materialThickness, to: url)
                case .stl:
                    try StlExporter.write(radial: radialPlan, model: sliceModel, materialThickness: materialThickness, to: url)
                }
                exportMessage = "Exported \(radialPlan.primary?.sliceCount ?? 0) rings + \(RadialPartBuilder.wedgeCount(plan: radialPlan)) fins to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .curve:
                guard let curvePlan = currentCurvePlan() else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.curve(curvePlan))
                case .obj:
                    try ObjExporter.write(curve: curvePlan, model: sliceModel, materialThickness: materialThickness, to: url)
                case .stl:
                    try StlExporter.write(curve: curvePlan, model: sliceModel, materialThickness: materialThickness, to: url)
                }
                exportMessage = "Exported \(curvePlan.sliceCount) curve slices to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .threeD:
                guard let threeDPlan else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    // 3D Slices is mesh-only; FlatPartExport rejects these.
                    try writeFlatParts(.threeD(threeDPlan))
                case .obj:
                    try ObjExporter.write(threeD: threeDPlan, model: sliceModel, to: url)
                case .stl:
                    try StlExporter.write(threeD: threeDPlan, model: sliceModel, to: url)
                }
                exportMessage = "Exported \(threeDPlan.sliceCount) 3D slices to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .foldedPanels:
                guard let foldedPanelPlan = currentFoldedPanelPlan() else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.foldedPanels(foldedPanelPlan))
                case .obj:
                    try ObjExporter.write(folded: foldedPanelPlan, materialThickness: materialThickness, to: url)
                case .stl:
                    try StlExporter.write(folded: foldedPanelPlan, materialThickness: materialThickness, to: url)
                }
                exportMessage = "Exported \(foldedPanelPlan.panelCount) folded panels to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .inflatables:
                guard let plan = displayedInflatablesPlan else { return }
                switch exportFormat {
                case .dxf, .eps, .pdf, .svg:
                    try writeFlatParts(.inflatables(plan))
                case .obj:
                    let layers = InflatablesMeshExportBuilder.layers(plan: plan)
                    guard !layers.isEmpty else {
                        throw InflatablesPlannerError.emptyAfterClean
                    }
                    try ObjExporter.write(meshLayers: layers, to: url, title: "inflatable membrane")
                case .stl:
                    let layers = InflatablesMeshExportBuilder.layers(plan: plan)
                    guard !layers.isEmpty else {
                        throw InflatablesPlannerError.emptyAfterClean
                    }
                    try StlExporter.write(meshes: layers.map(\.mesh), to: url, solidName: "refabartist_inflatable_membrane")
                }
                let target = exportFormat.usesVectorLayout ? "panels" : "3D membrane"
                exportMessage = "Exported \(plan.panels.count) inflatable \(target) to \(url.lastPathComponent)\(layoutTrace(for: exportFormat, settings: layoutSettings))"
            case .structures:
                guard let plan = displayedStructurePlan else { return }
                switch exportFormat {
                case .obj:
                    let title = plan.settings.category == .support ? "structures support" : "structures infill"
                    try ObjExporter.write(meshLayers: plan.layers, to: url, title: title)
                case .stl:
                    let solidName = plan.settings.category == .support
                        ? "refabartist_structures_support"
                        : "refabartist_structures_infill"
                    try StlExporter.write(meshes: plan.layers.map(\.mesh), to: url, solidName: solidName)
                case .dxf, .eps, .pdf, .svg:
                    // Structures is mesh-only; the format picker never offers these.
                    return
                }
                let structureKind = plan.settings.category == .support
                    ? "sculpture supports"
                    : "\(plan.settings.pattern.label.lowercased()) infill"
                exportMessage = "Exported \(plan.triangleCount) triangles of \(structureKind) to \(url.lastPathComponent)"
            case .partition:
                guard let plan = exportablePartitionPlan else { return }
                switch exportFormat {
                case .obj, .stl:
                    try PartitionExporter.write(plan: plan, format: exportFormat, packaging: partitionSettings.packaging, to: url)
                case .dxf, .eps, .pdf, .svg:
                    // Partition is mesh-only; the format picker never offers these.
                    return
                }
                let count = plan.pieces.count
                exportMessage = "Exported \(count) partition piece\(count == 1 ? "" : "s") to \(url.lastPathComponent)"
            case .motherMold:
                guard let export = exportableMotherMold else { return }
                let plan = export.plan
                let modelName = URL(fileURLWithPath: model.path)
                    .deletingPathExtension().lastPathComponent
                try MotherMoldExporter.write(
                    plan: plan,
                    settings: export.settings,
                    modelName: modelName,
                    to: url
                )
                let partWord = plan.parts.count == 1 ? "part" : "parts"
                let request = MotherMoldExportRequest(packaging: export.settings.packaging)
                exportMessage = "Exported \(plan.parts.count) mold \(partWord) as \(request.label) to \(url.lastPathComponent)"
            }
            // A cut-sheet export writes exactly what the sheet preview shows,
            // so the message describes the sheet rather than the slices.
            if flatPartWriter?.usesCutSheet == true, let document = cutSheetDocument {
                let convention = constructionMode == .inflatables
                    ? "red = cut, blue = seam, magenta = labels"
                    : "blue = cut, red = engrave"
                exportMessage = "Exported the cut sheet (\(document.partCount) parts on \(document.sheets.count) sheet\(document.sheets.count == 1 ? "" : "s"), \(convention)) to \(url.lastPathComponent)"
            }
            errorMessage = nil
            lastExportFailure = nil
        } catch {
            let message = error.localizedDescription
            lastExportFailure = message
            errorMessage = message
        }
    }

    private func exportUndercutPartitionOffMain(model: MeshSummary, to url: URL) {
        guard let plan = undercutGenerationState.exportablePlan else { return }
        let generatedSettings = undercutGenerationState.generatedSignature?
            .settings.undercutSplit?.sanitized
        let reportSettings = generatedSettings
            ?? (partitionSettings.undercutSplit?.sanitized ?? .defaultValue)
        let output: PartitionExporter.UndercutOutput
        switch exportFormat {
        case .stl:
            output = .separateSTLZip
        case .obj:
            output = .namedObjectOBJZip
        case .dxf, .eps, .pdf, .svg:
            return
        }
        let staleWarnings = partitionResultIsStale
            ? [UndercutSplitUIWording.staleAdvisory]
            : []
        let modelName = URL(fileURLWithPath: model.path)
            .deletingPathExtension().lastPathComponent
        let sourceGeometry = model.geometry
        let count = plan.pieces.count
        exportMessage = "Writing \(count) undercut-split piece\(count == 1 ? "" : "s") and measured report…"

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try PartitionExporter.write(
                        undercutPlan: plan,
                        settings: reportSettings,
                        sourceGeometry: sourceGeometry,
                        modelName: modelName,
                        output: output,
                        additionalWarnings: staleWarnings,
                        to: url
                    )
                }
            }.value
            switch outcome {
            case .success:
                exportMessage = "Exported \(count) undercut-split piece\(count == 1 ? "" : "s") with measured report to \(url.lastPathComponent)"
                errorMessage = nil
                lastExportFailure = nil
            case .failure(let error):
                let message = error.localizedDescription
                lastExportFailure = message
                errorMessage = message
            }
        }
    }

    private var assemblyGuideContext: AssemblyGuideContext? {
        guard hasSelectedConstructionTechnique,
              let model = effectiveModel else {
            return nil
        }
        let usesNotchWidth = notchWidthOverrideEnabled
            && (constructionMode == .interlocked || constructionMode == .curve)
        let relief: String?
        switch constructionMode {
        case .interlocked:
            // The relief the cut sheet actually cuts (none where slots merge).
            relief = slotReliefEnabled && (cutSheetDocument?.reliefCutCount ?? 0) > 0
                ? "dog bone, \(Vec3.format(materialToolDiameter)) mm tool"
                : nil
        case .radial:
            // RadialSlicePlan.cutsRelief, without planning again.
            relief = radialReliefType.requiresToolDiameter && materialToolDiameter > 0
                ? "\(radialReliefType.label), \(Vec3.format(materialToolDiameter)) mm tool"
                : nil
        default:
            relief = nil
        }
        return AssemblyGuideContext(
            modelName: model.name,
            constructionMode: constructionMode,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            notchWidth: usesNotchWidth ? notchWidth : nil,
            slotAngleDegrees: slotAngleDegrees,
            relief: relief,
            dowelsEnabled: dowelsEnabled,
            dowelDiameter: dowelDiameter,
            dowelInset: dowelInset,
            foldedJoint: foldedJoinery.type,
            // threeDPlan's spacing: Distribute count overrides the depth.
            threeDSliceDepth: threeDSliceDepth,
            threeDLayerCount: sliceCountOverride
        )
    }

    private func exportAssemblyGuide() {
        guard let context = assemblyGuideContext else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [FileDialogTypes.assemblyGuide]
        panel.nameFieldStringValue = context.modelName.replacingOccurrences(of: ".", with: "-") + "-\(constructionMode.rawValue)-assembly.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try AssemblyGuideExporter.write(context: context, steps: assemblySteps, to: url)
            exportMessage = "Exported \(assemblySteps.count) assembly steps to \(url.lastPathComponent)"
            lastExportFailure = nil
            errorMessage = nil
        } catch {
            let message = error.localizedDescription
            lastExportFailure = message
            errorMessage = message
        }
    }

    /// File > Print… (Cmd+P): prints the cut sheets via NSPrintOperation.
    /// The PDF renderer is the SAME CutSheetDocumentExporter used by the
    /// export path — one source of truth. The print panel carries the
    /// PrintAccessoryController accessory (Print Range + Rotate By).
    ///
    /// This function is GUI-only; the headless export path is unaffected.
    /// "Export Sliced Mesh…": the mode's generated 3D output as
    /// STL or OBJ. Folded exports its panelized 3D net; Inflatables exports the
    /// generated membrane mesh shown in the viewport.
    private func exportSlicedMesh() {
        guard hasSelectedConstructionTechnique else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            FileDialogTypes.export(for: .stl),
            FileDialogTypes.export(for: .obj)
        ]
        panel.nameFieldStringValue = (model?.name ?? "model") + "-sliced.stl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch constructionMode {
            case .foldedPanels:
                guard let plan = currentFoldedPanelPlan() else { return }
                if url.pathExtension.lowercased() == "obj" {
                    try ObjExporter.write(folded: plan, materialThickness: materialThickness, to: url)
                } else {
                    try StlExporter.write(folded: plan, materialThickness: materialThickness, to: url)
                }
            case .inflatables:
                guard let plan = displayedInflatablesPlan else { return }
                let layers = InflatablesMeshExportBuilder.layers(plan: plan)
                guard !layers.isEmpty else { throw InflatablesPlannerError.emptyAfterClean }
                if url.pathExtension.lowercased() == "obj" {
                    try ObjExporter.write(meshLayers: layers, to: url, title: "inflatable membrane")
                } else {
                    try StlExporter.write(meshes: layers.map(\.mesh), to: url, solidName: "refabartist_inflatable_membrane")
                }
            case .stacked, .interlocked, .radial, .curve, .threeD, .structures, .partition, .motherMold:
                return
            }
        } catch {
            lastExportFailure = "Export Sliced Mesh failed: \(error.localizedDescription)"
        }
    }

    private func printCutSheets() {
        guard let document = cutSheetDocument else {
            errorMessage = "The cut sheet is not ready — slice the model first."
            return
        }
        // Determine the currently visible sheet (1-based) for the
        // "Current Sheet" radio option.
        let currentSheet = 1 // no multi-sheet scroll position yet; default to 1
        guard let window = NSApp.keyWindow else {
            errorMessage = "No key window available for the print operation."
            return
        }
        CutSheetPrintOperation.run(
            document: document,
            settings: exportLayoutSettings,
            currentSheetIndex: currentSheet,
            on: window,
            onError: { message in
                errorMessage = message
            }
        )
    }

    private func layoutTrace(for format: ExportFormat, settings: ExportLayoutSettings) -> String {
        guard format.usesVectorLayout else {
            return ""
        }
        var parts = [
            "spacing \(Vec3.format(settings.partSpacing)) mm",
            "margin \(Vec3.format(settings.pageMargin)) mm"
        ]
        if format.usesSheetLayout {
            parts.append("sheet \(Vec3.format(settings.sheetWidth)) x \(Vec3.format(settings.sheetHeight)) mm")
            if let document = cutSheetDocument {
                if document.sheets.count > 1 {
                    parts.append("\(document.sheets.count) sheets")
                }
                if document.overflowingPartCount > 0 {
                    parts.append("exceeds sheet")
                }
            }
        }
        return " (\(parts.joined(separator: ", ")))"
    }

    private var currentExportLayoutSummary: ExportLayoutSummary? {
        guard let document = cutSheetDocument else {
            return nil
        }
        return ExportLayoutSummary(document: document)
    }


    private var workspaceEmptyState: WorkspaceEmptyStateContent {
        if let lastModelLoadFailure {
            return .modelLoadFailed(lastModelLoadFailure)
        }
        return .noModel
    }

    private var workspaceErrorNotice: WorkspaceErrorNoticeContent? {
        if let lastExportFailure {
            return .exportFailed(
                lastExportFailure,
                format: exportFormat.label,
                constructionMode: constructionMode.label
            )
        }
        // The raw preflight is measured in the file's own units and misflags
        // valid inch / unit-box models; trust the unit-independent diagnosis
        // when it says the imported surface is already a closed solid.
        let importedIsClean = modifyActiveTool == nil && (openingDiagnosis?.isNothingToFix ?? false)
        if !importedIsClean,
           let preflight = effectiveModel?.preflight,
           let notice = WorkspaceErrorNoticeContent.meshPreflight(preflight) {
            return notice
        }
        return currentSlotFitNotice
    }

    private var currentSlotFitNotice: WorkspaceErrorNoticeContent? {
        guard let slotWidth = currentSlotWidth else {
            return nil
        }
        return WorkspaceErrorNoticeContent.slotFitRisk(
            slotWidth: slotWidth,
            materialThickness: materialThickness
        )
    }

    private var currentSlotWidth: Double? {
        guard hasSelectedConstructionTechnique else { return nil }
        switch constructionMode {
        case .stacked, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return nil
        case .interlocked:
            return interlockedPlan?.slotWidth
        case .radial:
            return radialPlan?.slotWidth
        case .curve:
            return curvePlan?.slotWidth
        case .threeD:
            return threeDPlan?.slotWidth
        }
    }
}

/// Snapshot of every input that affects the generated Structures mesh. Equality
/// drives the STALE badge: when the live inputs no longer match the snapshot
/// that produced the cached plan, the result is out of date.
struct StructureInputSignature: Equatable {
    var modelPath: String?
    var modelTriangleCount: Int
    var modelBounds: String?
    var settings: StructureSettings
}

/// Snapshot of every input that affects a generated partition. A mismatch with
/// the cached signature means the shown pieces are STALE.
struct PartitionInputSignature: Equatable {
    var modelPath: String?
    var modelTriangleCount: Int
    var modelBounds: String?
    var settings: PartitionSettings
}

/// O(1) identity of the two immutable Array backing stores that make up an
/// effective mesh. A fingerprint snapshot retains the corresponding arrays, so
/// their addresses cannot be recycled while the identity is cached. Because
/// Array is copy-on-write, any later geometry mutation must allocate new storage.
private struct PartitionGeometryStorageIdentity: Equatable {
    let vertexAddress: UInt
    let vertexCount: Int
    let indexAddress: UInt
    let indexCount: Int

    init(_ geometry: MeshGeometryData) {
        vertexAddress = geometry.vertices.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map(UInt.init(bitPattern:)) ?? 0
        }
        vertexCount = geometry.vertices.count
        indexAddress = geometry.triangleIndices.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map(UInt.init(bitPattern:)) ?? 0
        }
        indexCount = geometry.triangleIndices.count
    }

    var cacheKey: String {
        "v\(vertexAddress):\(vertexCount)|i\(indexAddress):\(indexCount)"
    }
}

/// One exact effective-source fingerprint plus the COW-shared storage whose
/// identity it describes. Equality of full vertex/index arrays is deliberately
/// never evaluated from SwiftUI rendering paths.
private struct PartitionSourceFingerprintSnapshot {
    let retainedGeometry: MeshGeometryData
    let storageIdentity: PartitionGeometryStorageIdentity
    let fingerprint: String

    init(retainedGeometry: MeshGeometryData, fingerprint: String) {
        self.retainedGeometry = retainedGeometry
        storageIdentity = PartitionGeometryStorageIdentity(retainedGeometry)
        self.fingerprint = fingerprint
    }

    func matches(_ geometry: MeshGeometryData) -> Bool {
        storageIdentity == PartitionGeometryStorageIdentity(geometry)
    }
}

/// Thread-safe cancellation relay shared with the detached CPU-bound planner.
/// Cancelling the outer UI Task alone does not automatically cancel an
/// unstructured detached task, so the planner checks this flag between batches.
private final class PartitionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// One lock-backed bridge owns both progress and cancellation for the detached
/// MotherMold worker. UI state polls the latest stage on the main actor; the
/// CPU-bound planner never reaches into SwiftUI state from its worker thread.
private final class MotherMoldBuildRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stage: MoldBuildStage?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var latestStage: MoldBuildStage? {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }

    func report(_ stage: MoldBuildStage) {
        lock.lock()
        self.stage = stage
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct UndercutPartitionGenerationOutput {
    let plan: UndercutSplitPlan
    let viewportPlan: PartitionMeshPlan
    let overlay: UndercutSplitOverlay
    let signature: PartitionInputSignature
    let fingerprint: String
    /// Retains the exact COW array storage fingerprinted off-main.
    let retainedGeometry: MeshGeometryData
}

/// Resolve the tested purpose route outside SwiftUI's MainActor-isolated View.
/// Passing only the raw String across the boundary avoids sending UI-isolated
/// closure values into the generic coordinator under Swift 6 strict checking.
private func resolvedPartitionGenerationRoute(
    purposeRawValue: String
) async -> PartitionGenerationRoute {
    let purpose = PartitionPurpose(rawValue: purposeRawValue) ?? .fitPrinter
    return await PartitionGenerationCoordinator.run(
        purpose: purpose,
        fitPrinter: { .fitPrinter },
        splitByUndercuts: { .splitByUndercuts }
    )
}

/// Snapshot of every input that affects the generated MotherMold parts. Equality
/// drives the STALE badge: when the live inputs no longer match the snapshot that
/// produced the cached plan, the result is out of date.
struct MotherMoldInputSignature: Equatable {
    var modelPath: String?
    var modelTriangleCount: Int
    var modelBounds: String?
    var settings: MotherMoldSettings
}

enum MotherMoldHelp {
    enum Field: String, CaseIterable {
        case subtype, parts, wallThickness, siliconeClearance, softening
        case totalCavityOffset, flatFloor, floorThickness
        case masterFixture, socketDepth, socketFit
        case partingMode, partingAxis, partingOffset
        case keyType, keySize, keyDepth, keyTolerance, keysPerSeam
        case matingFlange, flangeWidth, flangeThickness, boltCount, boltDiameter
        case spoutMode, spoutDiameter, spoutX, spoutY, spoutZ
        case ventCount, ventDiameter, packaging, assemblyGuide, buildButton
        case masterSource, retentionMode, mountPlacement, manualMountPoint
        case postWidth, postThickness, postLength, crossPin, reuseFit, sealLand
        case linerRegistration, linerButtons, linerButtonDiameter, linerButtonDepth, linerButtonDraft
        case gateLip, gateLipDepth, productionFlow, castingProcess, productionGate, productionVent
        case workingSupports, supportMargin, manufacturingProfile

        var text: String {
            switch self {
            case .subtype:
                return "Choose between a rigid mold, a flexible silicone mold with a printed shell, or reusable production tooling."
            case .parts:
                return "How many rigid pieces you'll pull apart to release the cast. Two is right for most models; four helps deep or wrap-around shapes."
            case .wallThickness:
                return "Thickness of the printed shell. 4 mm suits most desktop prints; go thicker for big molds or heavy pours."
            case .siliconeClearance:
                return "How thick the silicone layer around your model will be. Thicker is stronger and uses more silicone; 6 mm suits most sculpture."
            case .softening:
                return "Smooths fine surface detail out of the shell cavity so the silicone — not the printed shell — captures it. Raise it if the shell fights demolding."
            case .totalCavityOffset:
                return "The exact cavity offset used for this shell: Silicone thickness plus Detail softening."
            case .flatFloor:
                return "Adds a flat base so the mold stands upright on the bench."
            case .floorThickness:
                return "Sets flat-base thickness. It changes geometry only while Flat floor is enabled."
            case .masterFixture:
                return "How your printed model is held steady while silicone cures around it. The printed socket grips its base; or hold it yourself with a stem or clay bed."
            case .socketDepth:
                return "How far the socket rises around the model's base. Deeper grips better but covers more of the lower surface."
            case .socketFit:
                return "Space between model and socket. Snug locates precisely; loose inserts easily but can wobble."
            case .partingMode:
                return "Auto picks the split direction that demolds most cleanly. Manual lets you set each split plane yourself — you'll see the plane on the model as you adjust it."
            case .partingAxis:
                return "The direction the two sides pull apart. The plane on the model shows exactly where the seam will fall."
            case .partingOffset:
                return "Slides the split plane along its axis. Watch the plane on the model — the seam lands where the plane crosses the surface."
            case .keyType:
                return "Bumps and pockets along the seam that snap the parts into alignment — like the keys on a plaster mold. Tapered so they seat without forcing."
            case .keySize:
                return "Size of each key. Bigger keys align more positively but need a wider seam face."
            case .keyDepth:
                return "How far each key engages. Refab Artist shortens a key rather than punching through a thin wall."
            case .keyTolerance:
                return "Extra space around each key pocket so printed parts seat. Raise it if your printer runs tight; too much lets the halves shift."
            case .keysPerSeam:
                return "Sets the exact registration-key count for each physical part-to-part interface. Missing final keys block export."
            case .matingFlange:
                return "A flat rim along the seam with bolt holes, so the halves clamp shut against the pour. Without it, use straps or tape."
            case .flangeWidth:
                return "Sets how far the clamping rim extends from the seam. More width provides room for keys and bolt holes but increases print size."
            case .flangeThickness:
                return "Sets clamping-rim thickness. Thicker rims resist bending under clamp force but use more material."
            case .boltCount:
                return "Through-holes for bolts or zip ties. Zero leaves the rim solid."
            case .boltDiameter:
                return "Sets finished bolt-hole diameter. Match intended hardware plus your printer's fit allowance."
            case .spoutMode:
                return "Where the casting material goes in. Auto puts the funnel at the highest point of the mold; Manual lets you click a spot on the model."
            case .spoutDiameter:
                return "Width of the fill channel. Wider pours faster and suits thick materials; it leaves a bigger mark to trim off the cast."
            case .spoutX:
                return "Moves the manual pour-hole center along model-space X. Keep the complete funnel away from mold seams."
            case .spoutY:
                return "Moves the manual pour-hole center along model-space Y. Keep the complete funnel away from mold seams."
            case .spoutZ:
                return "Moves the manual pour-hole center along model-space Z onto a clear upper cavity surface."
            case .ventCount:
                return "Small holes at high points that let air escape while you pour. Without them, trapped air leaves voids in the cast."
            case .ventDiameter:
                return "Sets each air-vent bore diameter. Larger vents release air more easily but leave larger marks and leak paths."
            case .packaging:
                return "How the printable files are grouped: one ZIP of STLs, one OBJ with named parts, or all parts laid out in a single STL."
            case .assemblyGuide:
                return "Writes a step-by-step guide: assembling, clamping, sealing, pouring, curing, and demolding."
            case .buildButton:
                return "Builds the mold parts from these settings and shows them in 3D. Nothing recomputes while you adjust — press when ready."
            case .masterSource:
                return "Choose whether Refab Artist prepares and prints a derived positive or fixtures an existing physical master."
            case .retentionMode:
                return "Choose the hold-down compatible with the selected master source. A generated socket locates only; an external fixture remains shop-supplied."
            case .mountPlacement:
                return "Auto selects one bounded sacrificial patch. Pick on model arms one surface click; X, Y, and Z stay available for fine adjustment."
            case .manualMountPoint:
                return "Sets the manual mount center in model-space millimeters. Rebuild to validate the selected patch and axis."
            case .postWidth:
                return "Sets the prepared-master post width at its sacrificial root."
            case .postThickness:
                return "Sets the prepared-master post thickness at its sacrificial root."
            case .postLength:
                return "Sets the free post length between the prepared master and the hold-down yoke."
            case .crossPin:
                return "Sets the required removable cross-pin diameter for the prepared-master hold-down."
            case .reuseFit:
                return "Sets fixture clearance around the retained master. Smaller values locate more tightly but require a calibrated printer fit."
            case .sealLand:
                return "Sets the width of the reusable sealing land around the master fixture interface."
            case .linerRegistration:
                return "Controls how the reusable silicone liner registers to every rigid mold part. None is advanced and leaves registration as an explicit risk."
            case .linerButtons:
                return "Sets the requested liner registration buttons per mold part."
            case .linerButtonDiameter:
                return "Sets the diameter of each liner registration button."
            case .linerButtonDepth:
                return "Sets the engagement depth of each liner registration button."
            case .linerButtonDraft:
                return "Sets draft on liner registration buttons so the liner can release cleanly."
            case .gateLip:
                return "Adds a liner gate lip when the measured shell split can retain it without trapping the liner."
            case .gateLipDepth:
                return "Sets the gate-lip depth used to retain the production gate trim."
            case .productionFlow:
                return "Auto proposes a production casting gate and vents. Manual exposes explicit placement data for the next rebuild."
            case .castingProcess:
                return "Declares the gravity casting material family used for qualification and the guide."
            case .productionGate:
                return "Sets the nominal production casting-gate diameter."
            case .productionVent:
                return "Sets the nominal permanent production-vent diameter."
            case .workingSupports:
                return "Auto uses measured liner-fill and casting orientations to select a stable base or generate phase cradles."
            case .supportMargin:
                return "Sets the minimum required support-polygon margin for phase cradles and stable bases."
            case .manufacturingProfile:
                return "Records the printer, material, and versioned profile snapshot used for fit qualification. A populated reference does not replace required physical process evidence."
            }
        }
    }

    static func option(_ value: MoldSubtype) -> String {
        switch value {
        case .slipShell:
            return "Rigid mold: prints a direct casting negative. Shapes that cannot release from rigid pieces block the build."
        case .siliconeJacket:
            return "Silicone mold + shell: prints a rigid shell around a flexible silicone layer and your model."
        }
    }

    static func option(_ value: MoldPartCount) -> String {
        switch value {
        case .two: return "Two-part mold: one split plane and two rigid pieces. Simpler to print and assemble."
        case .four: return "Four-part mold: two orthogonal split planes and four pieces. Better access for complex forms, with more seams and hardware."
        }
    }

    static func option(_ value: MasterMountMode) -> String {
        switch value {
        case .flatBaseSocket:
            return "Printed base socket: Refab Artist prints a locating socket around the model's base. Apply compatible sealant before pouring."
        case .externalFixture:
            return "I'll hold it myself: use your own stem, suspension, or clay bed and seal every opening before pouring."
        }
    }

    static func option(_ value: PartingMode) -> String {
        switch value {
        case .auto: return "Auto: evaluate primary split axes using undercut depth and connected-part measurements."
        case .manual: return "Manual: use selected axes and offsets exactly; trapped or invalid results remain inspection-only."
        }
    }

    static func option(_ value: PartitionKeyType) -> String {
        switch value {
        case .none: return "None: plain butt joint with no automatic registration. Use only when another alignment method is planned."
        case .pins: return "Tapered round: an 8-degree drafted round boss and clearance pocket. Compact, self-centering, and easy to clean."
        case .dovetail: return "Tapered bar: an 8-degree drafted rectangular boss and pocket that resists rotation but needs more flange area."
        }
    }

    static func option(_ value: MoldSpoutMode) -> String {
        switch value {
        case .auto: return "Auto: search high cavity regions until the connected funnel and channel fit entirely on one mold part."
        case .manual: return "Manual: click the model to place the pour hole, then use X, Y, and Z for fine adjustment; placement on or across a seam is rejected."
        }
    }

    static func option(_ value: MoldPackaging) -> String {
        switch value {
        case .manufacturingZip: return "Manufacturing ZIP: validated mold parts, prepared positive, tooling accessories, manifest, and assembly guide."
        case .separateZip: return "Separate STLs: one validated STL per mold part inside a ZIP archive."
        case .combinedObj: return "Combined OBJ: one OBJ containing a named object for each mold part."
        case .laidOutPlate: return "Laid-out STL: parts translated apart into one STL; spacing is deterministic, not printer-bed-aware packing."
        }
    }

    static func option(_ value: MasterSourceMode) -> String {
        value == .preparedPrint
            ? "Print prepared master: Refab Artist adds only the displayed, approval-gated sacrificial tooling regions."
            : "Existing physical master: preserve the supplied object and select a compatible locator or external fixture."
    }

    static func option(_ value: MasterRetentionMode) -> String {
        switch value {
        case .preparedPost: return "Keyed post + cross-pin: holds a prepared printed master against uplift and rotation."
        case .flatBaseSocket: return "Generated socket: locates an existing master but is not a qualified hold-down or liquid seal."
        case .externalFixture: return "External fixture: records a shop-supplied fixture and keeps its physical qualification explicit."
        }
    }

    static func option(_ value: MountPlacementMode) -> String {
        value == .auto
            ? "Auto: evaluate bounded sacrificial mount candidates and show the selected change before approval."
            : "Pick on model: click a visible surface to set the mount center and outward direction; X, Y, and Z remain fine adjustment."
    }

    static func option(_ value: LinerRegistrationMode) -> String {
        switch value {
        case .automatic: return "Auto: find and verify liner registration sites while reserving seam and fixture regions."
        case .buttons: return "Buttons: require measured button sites on every mold part."
        case .buttonsAndGateLip: return "Buttons + lip: add measured registration buttons and a production gate lip."
        case .none: return "None: do not create liner registration; use only with an explicit shop recovery plan."
        }
    }

    static func option(_ value: ProductionFlowMode) -> String {
        value == .automatic
            ? "Auto gate + vents: search for a releasable casting gate and required permanent vents."
            : "Place manually: retain manually specified production flow locations for validation on rebuild."
    }

    static func option(_ value: CastingProcessProfile) -> String {
        switch value {
        case .gravityResin: return "Gravity resin: qualify the tooling against the recorded resin gravity process."
        case .gravityPlaster: return "Gravity plaster: qualify the tooling against the recorded plaster gravity process."
        case .customGravity: return "Custom gravity: package geometry can be valid while physical process evidence remains required."
        }
    }

    static func option(_ value: ToolingSupportMode) -> String {
        value == .automatic
            ? "Auto: evaluate both pour phases and generate stable support geometry when needed."
            : "Place manually: use an artist-specified support plane and rebuild for measured validation."
    }

    static func axisOption(_ axis: String) -> String {
        "\(axis) axis: the plane is perpendicular to model-space \(axis), and the two sides pull in opposite \(axis) directions."
    }
}

enum MotherMoldGoal: String, CaseIterable, Identifiable, Sendable {
    case castCopies
    case rigidMold
    case productionTooling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .castCopies: return "Cast copies"
        case .rigidMold: return "Rigid mold"
        case .productionTooling: return "Production tooling"
        }
    }

    var help: String {
        switch self {
        case .castCopies:
            return "A flexible silicone mold inside a rigid printed shell. Best for detailed sculpture and multiple copies in resin, plaster, or wax."
        case .rigidMold:
            return "A hard printed mold whose cavity is the exact shape of your model. Best for simple shapes and materials that release easily."
        case .productionTooling:
            return "Reusable factory-style tooling with a printed master, hold-down hardware, and process records. For repeated production runs."
        }
    }

    var systemImage: String {
        switch self {
        case .castCopies: return "square.3.layers.3d"
        case .rigidMold: return "cube.transparent"
        case .productionTooling: return "shippingbox.fill"
        }
    }
}

enum MotherMoldUIContract {
    enum RecoveryAction: Equatable {
        case makeWatertight
        case buildMold
        case cancelBuild
        case useFewerOrSmallerKeys
        case useExternalFixture
        case placeSpoutManually
        case approvePreparedMaster(String)
        case reduceVents
        case disableClampingRim
        case useAutoParting
        case useFewerParts
        case reviewBuildDetails

        var label: String {
            switch self {
            case .makeWatertight: return "Choose how to make it watertight…"
            case .buildMold: return "Build mold"
            case .cancelBuild: return "Cancel build"
            case .useFewerOrSmallerKeys: return "Use fewer/smaller keys"
            case .useExternalFixture: return "Hold it myself"
            case .placeSpoutManually: return "Place pour hole manually"
            case .approvePreparedMaster: return "Approve prepared master"
            case .reduceVents: return "Use fewer or smaller vents"
            case .disableClampingRim: return "Turn off clamping rim"
            case .useAutoParting: return "Use Auto parting"
            case .useFewerParts: return "Use fewer parts"
            case .reviewBuildDetails: return "Review build details"
            }
        }
    }

    enum BuildStatusKind: String, Equatable {
        case needsRepair
        case readyToBuild
        case building
        case readyToPrint
        case blocked
    }

    enum BuildStatusTone: Equatable {
        case secondary
        case orange
        case green
        case red
    }

    struct BuildFailurePresentation: Equatable {
        var cause: String
        var rawDetail: String
        var recovery: RecoveryAction
    }

    struct BuildStatusPresentation: Equatable {
        var kind: BuildStatusKind
        var title: String
        var summary: String
        var details: [String]
        var action: RecoveryAction?
        var rawDetails: [String]
        var tone: BuildStatusTone
    }

    struct ExportSnapshot: Equatable {
        var plan: MotherMoldPlan
        var settings: MotherMoldSettings
    }

    enum PackageReadiness: Equatable {
        case blocked(String)
        case geometryOnly(String)
        case printerValidated(String)
        case productionQualified(String)

        var title: String {
            switch self {
            case .blocked: return "Package blocked"
            case .geometryOnly: return "Package ready - geometry only"
            case .printerValidated: return "Package ready - printer validated"
            case .productionQualified: return "Production profile qualified"
            }
        }

        func title(forProductionTooling isProductionTooling: Bool) -> String {
            guard !isProductionTooling else { return title }
            switch self {
            case .blocked: return "Blocked"
            case .geometryOnly, .printerValidated, .productionQualified:
                return "Ready to print"
            }
        }

        var detail: String {
            switch self {
            case .blocked(let detail), .geometryOnly(let detail), .printerValidated(let detail), .productionQualified(let detail):
                return detail
            }
        }
    }

    struct ExportArtifactPreview: Identifiable, Equatable {
        var id: String
        var label: String
        var detail: String
    }

    static let supportsManualSpoutPlacement = true
    static let manualSpoutHint = "Manual pour-hole coordinates are measured in model space."
    static let supportsManualProductionFlowPlacement = false
    static let supportsManualToolingSupportPlacement = false
    static let manualProductionPlacementDisabledReason = "Manual placement needs the click-to-place editor — coming with the placement gizmo."
    static let manualMountPlacementLabel = "Pick on model"

    static func goal(for settings: MotherMoldSettings) -> MotherMoldGoal {
        if settings.subtype == .slipShell {
            return .rigidMold
        }
        return settings.toolingContractVersion >= 3 ? .productionTooling : .castCopies
    }

    /// Applies the artist-facing goal without resetting advanced values. Those
    /// values remain available if the artist later opts back into production.
    static func applying(_ goal: MotherMoldGoal, to settings: MotherMoldSettings) -> MotherMoldSettings {
        var updated = settings
        switch goal {
        case .castCopies:
            updated.subtype = .siliconeJacket
            updated.toolingContractVersion = 2
            if updated.packaging == .manufacturingZip {
                updated.packaging = .separateZip
            }
        case .rigidMold:
            updated.subtype = .slipShell
            updated.toolingContractVersion = 2
            if updated.packaging == .manufacturingZip {
                updated.packaging = .separateZip
            }
        case .productionTooling:
            updated.subtype = .siliconeJacket
            updated.toolingContractVersion = 3
            updated.packaging = .manufacturingZip
        }
        return updated
    }

    static func showsProductionSections(for settings: MotherMoldSettings) -> Bool {
        goal(for: settings) == .productionTooling
    }

    static func showsProductionSections(for goal: MotherMoldGoal) -> Bool {
        goal == .productionTooling
    }

    static func showsLegacyMountControls(for settings: MotherMoldSettings) -> Bool {
        goal(for: settings) == .castCopies
    }

    /// Counts the primary always-visible rows. Disclosure contents are omitted;
    /// the computed total and Build Status are included because they occupy
    /// visible rows even though they are not editable controls.
    static func visiblePrimaryControlCount(for settings: MotherMoldSettings) -> Int {
        var count = 1 // Goal gate
        count += 2 // Parts + parting mode
        if settings.parting.mode == .manual {
            count += settings.parts.planeCount * 2 // Axis + offset per plane
        }
        count += 1 // Wall
        if settings.subtype == .siliconeJacket {
            count += 3 // Silicone thickness + detail softening + computed total
        }
        count += 2 // Flat floor + floor thickness
        count += 2 // Build action + status
        return count
    }

    static func showsSpoutControls(for subtype: MoldSubtype) -> Bool {
        _ = subtype
        return true
    }

    static func manualSpoutSeed(for bounds: Bounds3D?) -> Vec3? {
        guard let bounds else { return nil }
        return Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: bounds.max.z
        )
    }

    static func manualSpoutDisabledReason(for settings: MotherMoldSettings) -> String? {
        guard showsSpoutControls(for: settings.subtype),
              settings.spout.mode == .manual,
              !supportsManualSpoutPlacement else {
            return nil
        }
        return manualSpoutHint
    }

    /// Why Build mold is disabled for the master's geometry, or nil. The GUI
    /// passes the model's truthful (unit-independent) report here, so a valid
    /// inch model is not refused for phantom open edges.
    static func openGeometryDisabledReason(preflight: MeshPreflightReport?) -> String? {
        guard let preflight, !preflight.isWatertight, preflight.boundaryEdgeCount > 0 else { return nil }
        return "This model has open geometry. Open Issues, press Make Watertight, then build the mold."
    }

    /// Resolves the one artist-facing MotherMold state used by both the build
    /// card and Issues. Precedence is deliberate: an active build always keeps
    /// Cancel visible, then source repair, stale inputs, a completed plan, a
    /// typed thrown failure, and finally the initial ready state.
    static func buildStatus(
        preflight: MeshPreflightReport?,
        isBuilding: Bool,
        buildStage: MoldBuildStage?,
        isStale: Bool,
        plan: MotherMoldPlan?,
        settings: MotherMoldSettings,
        buildFailure: BuildFailurePresentation?,
        buildMessage: String?
    ) -> BuildStatusPresentation {
        if isBuilding {
            let stage = buildStage ?? .preparingMaster
            return BuildStatusPresentation(
                kind: .building,
                title: "Building…",
                summary: "\(stage.label)… \(stage.ordinal) of \(MoldBuildStage.allCases.count)",
                details: [],
                action: .cancelBuild,
                rawDetails: [],
                tone: .secondary
            )
        }

        if let preflight, !preflight.isWatertight {
            var details: [String] = []
            if preflight.boundaryEdgeCount > 0 {
                details.append(countLine(preflight.boundaryEdgeCount, singular: "open edge", plural: "open edges"))
            }
            if preflight.nonManifoldEdgeCount > 0 {
                details.append(countLine(
                    preflight.nonManifoldEdgeCount,
                    singular: "edge shared by too many faces",
                    plural: "edges shared by too many faces"
                ))
            }
            if preflight.degenerateTriangleCount > 0 {
                details.append(countLine(
                    preflight.degenerateTriangleCount,
                    singular: "zero-area triangle",
                    plural: "zero-area triangles"
                ))
            }
            if preflight.invalidTriangleReferenceCount > 0 {
                details.append(countLine(
                    preflight.invalidTriangleReferenceCount,
                    singular: "triangle with an invalid vertex",
                    plural: "triangles with invalid vertices"
                ))
            }
            return BuildStatusPresentation(
                kind: .needsRepair,
                title: "Needs repair",
                summary: preflight.boundaryEdgeCount > 0
                    ? "This model has open edges."
                    : "This model is not ready for mold building.",
                details: details,
                action: .makeWatertight,
                rawDetails: [],
                tone: .orange
            )
        }

        if isStale {
            return readyToBuildStatus(summary: "Settings changed since the last build.")
        }

        if let plan {
            let readiness = packageReadiness(for: plan, settings: settings)
            if settings.usesReusableToolingContract,
               !preparedMasterApprovalIsFresh(plan: plan, settings: settings),
               let signature = plan.masterPreparation.approvalSignature,
               !signature.isEmpty {
                return blockedStatus(
                    cause: "Prepared-master changes still need approval.",
                    recovery: .approvePreparedMaster(signature),
                    rawDetails: plan.diagnostics.map(\.message)
                )
            }

            if let diagnostic = plan.diagnostics.first(where: { $0.severity == .error }) {
                let recovery = recoveryAction(
                    for: diagnostic,
                    approvalSignature: plan.masterPreparation.approvalSignature
                )
                return blockedStatus(
                    cause: blockedCause(for: recovery),
                    recovery: recovery,
                    rawDetails: plan.diagnostics.map(\.message)
                )
            }

            if case .blocked(let reason) = readiness {
                let diagnostic = MoldDiagnostic(.error, reason)
                let recovery = recoveryAction(for: diagnostic)
                return blockedStatus(
                    cause: blockedCause(for: recovery),
                    recovery: recovery,
                    rawDetails: [reason] + plan.diagnostics.map(\.message)
                )
            }

            return BuildStatusPresentation(
                kind: .readyToPrint,
                title: readiness.title(forProductionTooling: settings.usesReusableToolingContract),
                summary: settings.usesReusableToolingContract
                    ? readiness.detail
                    : "The mold passed its printability checks.",
                details: [],
                action: nil,
                rawDetails: plan.diagnostics.map(\.message),
                tone: productionTone(for: readiness)
            )
        }

        if let buildFailure {
            return blockedStatus(
                cause: buildFailure.cause,
                recovery: buildFailure.recovery,
                rawDetails: [buildFailure.rawDetail]
            )
        }

        return readyToBuildStatus(summary: buildMessage == "Build cancelled."
            ? "Build cancelled."
            : "Choose your mold settings, then build the mold.")
    }

    static func buildFailurePresentation(_ error: Error) -> BuildFailurePresentation {
        let rawDetail = error.localizedDescription
        let diagnostic = MoldDiagnostic(.error, rawDetail)
        let recovery = recoveryAction(for: diagnostic)
        return BuildFailurePresentation(
            cause: blockedCause(for: recovery),
            rawDetail: rawDetail,
            recovery: recovery
        )
    }

    static func recoveryAction(
        for diagnostic: MoldDiagnostic,
        approvalSignature: String? = nil
    ) -> RecoveryAction {
        if let action = diagnostic.recoveryActions.first {
            switch action {
            case .makeWatertight: return .makeWatertight
            case .rebuild: return .buildMold
            case .inspectPreparedMaster, .approveModifications:
                return approvalSignature.map(RecoveryAction.approvePreparedMaster) ?? .reviewBuildDetails
            case .choosePreparedPost, .defineExternalFixture: return .useExternalFixture
            case .adjustParting, .sendToPartition: return .useAutoParting
            case .adjustLinerRegistration: return .useFewerOrSmallerKeys
            case .reorientLinerFill, .adjustProductionGate: return .placeSpoutManually
            case .reorientCasting, .adjustProductionVents: return .reduceVents
            case .selectPrinterProfile, .reviewAssemblyGuide: return .reviewBuildDetails
            }
        }

        if diagnostic.subsystem != .legacy {
            switch diagnostic.subsystem {
            case .source, .cavity: return .makeWatertight
            case .shellRegistration, .linerRegistration: return .useFewerOrSmallerKeys
            case .masterPreparation, .holdDown: return .useExternalFixture
            case .flange: return .disableClampingRim
            case .parting: return .useAutoParting
            case .shell: return .useFewerParts
            case .linerFill: return .placeSpoutManually
            case .productionCasting: return .reduceVents
            case .support, .package, .physicalQualification: return .reviewBuildDetails
            case .legacy: break
            }
        }

        return legacyRecoveryAction(for: diagnostic.message)
    }

    /// Most recovery actions change inputs, so their previous failure no
    /// longer describes the current configuration. Reviewing details is the
    /// exception: its only job is to reveal the raw failure that is already
    /// on screen, so clearing it first would remove the disclosure entirely.
    /// Navigation-only actions keep the failure on screen: Review build
    /// details, and "Choose how to make it watertight…" (it only opens the
    /// Issues choices; the failure clears itself once a picked fix changes
    /// the model and so the build inputs).
    static func clearsBuildFailure(whenPerforming action: RecoveryAction) -> Bool {
        action != .reviewBuildDetails && action != .makeWatertight
    }

    static func buildButtonLabel(
        isBuilding: Bool,
        hasBuilt: Bool,
        status: BuildStatusPresentation
    ) -> String {
        if isBuilding { return "Cancel build" }
        if status.kind == .readyToBuild { return "Build mold" }
        return hasBuilt ? "Rebuild mold" : "Build mold"
    }

    private static func readyToBuildStatus(summary: String) -> BuildStatusPresentation {
        BuildStatusPresentation(
            kind: .readyToBuild,
            title: "Ready to build",
            summary: summary,
            details: [],
            action: .buildMold,
            rawDetails: [],
            tone: .secondary
        )
    }

    private static func blockedStatus(
        cause: String,
        recovery: RecoveryAction,
        rawDetails: [String]
    ) -> BuildStatusPresentation {
        BuildStatusPresentation(
            kind: .blocked,
            title: "Blocked",
            summary: "The mold can't be built as configured.",
            details: [cause],
            action: recovery,
            rawDetails: rawDetails,
            tone: .red
        )
    }

    private static func countLine(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)."
    }

    private static func productionTone(for readiness: PackageReadiness) -> BuildStatusTone {
        switch readiness {
        case .blocked: return .red
        case .geometryOnly, .printerValidated, .productionQualified: return .green
        }
    }

    private static func blockedCause(for action: RecoveryAction) -> String {
        switch action {
        case .makeWatertight:
            return "The source surface is not watertight enough to build a mold."
        case .buildMold, .cancelBuild, .reviewBuildDetails:
            return "A required mold-planning check needs review."
        case .useFewerOrSmallerKeys:
            return "Registration keys do not fit safely on the current seams."
        case .useExternalFixture:
            return "The printed master holder could not be verified."
        case .placeSpoutManually:
            return "The pour hole does not fit entirely on one mold part."
        case .approvePreparedMaster:
            return "Prepared-master changes still need approval."
        case .reduceVents:
            return "The requested air vents do not fit safely."
        case .disableClampingRim:
            return "The clamping rim or bolt holes could not be completed safely."
        case .useAutoParting:
            return "The current split does not produce releasable mold parts."
        case .useFewerParts:
            return "A required mold-part printability check failed."
        }
    }

    private static func legacyRecoveryAction(for message: String) -> RecoveryAction {
        let lower = message.lowercased()
        if lower.contains("prepared") && lower.contains("approv") {
            return .reviewBuildDetails
        }
        if lower.contains("master") && (
            lower.contains("socket") || lower.contains("fixture") || lower.contains("locator")
        ) {
            return .useExternalFixture
        }
        if lower.contains("spout") || lower.contains("funnel")
            || lower.contains("fill channel") || lower.contains("pour path") {
            return .placeSpoutManually
        }
        if lower.contains("vent") { return .reduceVents }
        if lower.contains("key") || lower.contains("registration")
            || lower.contains("boss") || lower.contains("pocket") {
            return .useFewerOrSmallerKeys
        }
        if lower.contains("flange") || lower.contains("clamp") || lower.contains("bolt bore") {
            return .disableClampingRim
        }
        if lower.contains("undercut") || lower.contains("demold") || lower.contains("release")
            || lower.contains("partition") || lower.contains("split plane") || lower.contains("part count") {
            return .useAutoParting
        }
        if lower.contains("disconnected") || lower.contains("debris") || lower.contains("printable part") {
            return .useFewerParts
        }
        if lower.contains("watertight") || lower.contains("non-manifold")
            || lower.contains("boundary") || lower.contains("cavity") {
            return .makeWatertight
        }
        return .reviewBuildDetails
    }

    static func buildMessage(for plan: MotherMoldPlan) -> String {
        if let reason = blockingExportReason(for: plan) {
            let prefix = plan.parts.isEmpty ? "Mold could not be built." : "Mold needs attention before export."
            return "\(prefix) \(reason)"
        }
        guard !plan.parts.isEmpty else { return "Mold build produced no parts." }
        let partWord = plan.parts.count == 1 ? "part" : "parts"
        return "Mold ready: \(plan.parts.count) printable \(partWord)."
    }

    static func preparedMasterApprovalIsFresh(
        plan: MotherMoldPlan,
        settings: MotherMoldSettings
    ) -> Bool {
        guard plan.toolingContractVersion >= 3,
              settings.usesReusableToolingContract else {
            return true
        }
        guard !plan.masterModificationRegions.isEmpty else { return true }
        return plan.masterPreparation.approvalSignature != nil
            && plan.masterPreparation.approvalSignature == settings.approvedModificationSignature
            && plan.masterPreparation.state == .approved
    }

    static func packageReadiness(for plan: MotherMoldPlan, settings: MotherMoldSettings) -> PackageReadiness {
        if let reason = blockingExportReason(for: plan, settings: settings) {
            return .blocked(reason)
        }
        guard plan.toolingContractVersion >= 3 else {
            return .geometryOnly("This legacy shell package has passed geometry checks. Physical setup remains a shop responsibility.")
        }
        switch plan.toolingExportContract.state {
        case .productionProfileQualified:
            return .productionQualified("Software checks and the versioned physical process profile are recorded. Perform the guide's phase setup and pre-pour checks.")
        case .printerValidated:
            return .printerValidated("Manufacturing meshes fit the active profile. Bench setup and phase checks remain in the guide.")
        case .geometryOnly, .notApplicable:
            return .geometryOnly("Geometry is exportable for prototyping. Printer fit, load, process, or external-fixture evidence remains unqualified and is recorded in the package.")
        case .incomplete, .blocked:
            return .blocked(plan.toolingExportContract.blockingReasons.first ?? "Required reusable-tooling artifacts are incomplete. Rebuild after resolving Build Status.")
        }
    }

    static func exportArtifactPreview(for plan: MotherMoldPlan) -> [ExportArtifactPreview] {
        var result = plan.parts.map {
            ExportArtifactPreview(id: "shell|\($0.name)", label: $0.name, detail: "Manufacturing mesh: rigid mold part")
        }
        result += plan.manufacturingToolingArtifacts.map {
            ExportArtifactPreview(id: $0.id.rawValue, label: $0.name, detail: "Manufacturing mesh: \($0.role.rawValue)")
        }
        result += plan.hardwareItems.map {
            ExportArtifactPreview(id: $0.id.rawValue, label: $0.description, detail: "Hardware: \($0.specification)")
        }
        result += [
            ExportArtifactPreview(id: "guide", label: "assembly-guide.html", detail: "Document: phase setup and recovery guide"),
            ExportArtifactPreview(id: "hardware", label: "hardware.csv", detail: "Document: shop-supplied hardware schedule"),
            ExportArtifactPreview(id: "manifest", label: "manifest.json", detail: "Document: stable artifact IDs, hashes, and qualification status"),
        ]
        return result.sorted { $0.id < $1.id }
    }

    static func blockingExportReason(for plan: MotherMoldPlan, settings: MotherMoldSettings? = nil) -> String? {
        if let settings,
           settings.usesReusableToolingContract,
           !preparedMasterApprovalIsFresh(plan: plan, settings: settings) {
            return "The displayed prepared-master changes still need approval. Inspect the typed regions, approve this exact plan, then rebuild."
        }
        if plan.toolingContractVersion >= 3,
           plan.toolingExportContract.state == .blocked || plan.toolingExportContract.state == .incomplete {
            return plan.toolingExportContract.blockingReasons.first
                ?? "The reusable tooling package is incomplete. Resolve the recovery action in Build Status, then rebuild."
        }
        guard let message = plan.diagnostics.first(where: { $0.severity == .error })?.message else {
            return nil
        }
        let lower = message.lowercased()
        if lower.contains("master socket"),
           lower.contains("joined the shell"),
           lower.contains("did not produce printable topology") {
            return "Refab Artist hit an internal automatic master-holder failure. Nothing is wrong with your model. Choose I'll hold it myself or adjust Socket depth and rebuild."
        }
        if lower.contains("master") && (
            lower.contains("socket") || lower.contains("fixture") || lower.contains("locator")
        ) {
            return "Refab Artist could not verify a stable printed master holder for this orientation. Reorient the model so a broader base faces down, increase Socket depth, or choose I'll hold it myself."
        }
        if lower.contains("spout") || lower.contains("funnel") || lower.contains("fill channel") || lower.contains("pour path") {
            return "Refab Artist could not fit the pour hole entirely on one mold part. Switch Pour hole to Manual, move it away from seams, and rebuild."
        }
        if lower.contains("vent") {
            return "Refab Artist could not place every requested air vent safely. Reduce Vent diameter or Vent count, or reorient the model, then rebuild."
        }
        if lower.contains("key site") || lower.contains("key search")
            || (lower.contains("key") && lower.contains("pattern")) ||
            lower.contains("registration") || lower.contains("key pair") || lower.contains("boss or pocket") {
            return "The requested key pattern could not be placed safely. Increase rim Width, reduce Keys per seam or key size, or choose None, then rebuild."
        }
        if lower.contains("assembled mold parts overlap")
            || lower.contains("generated part overlap")
            || (lower.contains("overlap") && (lower.contains("flange") || lower.contains("generated part") || lower.contains("final keying"))) {
            return "Refab Artist hit an internal automatic hardware-layout failure: generated mold parts overlap during rim or key placement. Nothing is wrong with your model. Export is blocked; adjust Clamping rim Width or key settings and rebuild."
        }
        if lower.contains("flange") || lower.contains("clamp") {
            return "The requested clamping rim could not be completed. Increase Width, reduce Bolt holes or Bolt diameter, or turn off Clamping rim and use straps, then rebuild."
        }
        if lower.contains("undercut") || lower.contains("demold") || lower.contains("release") {
            return "The rigid parts cannot release safely along the current split. Try Auto parting, choose four parts, or use Silicone mold + shell."
        }
        if lower.contains("disconnected") || lower.contains("debris") {
            return "The generated assembly failed: disconnected or debris material was produced during parting. Use Auto parting, fewer Parts, or reduce/disable seam features, then rebuild."
        }
        if lower.contains("watertight") || lower.contains("non-manifold") || lower.contains("boundary") || lower.contains("printable") {
            return "One or more generated mold parts are not printable. Rebuild with fewer parts or a simpler split; if the source has open geometry, use Make Watertight first."
        }
        return message
    }

    static func recoveryAction(for plan: MotherMoldPlan) -> RecoveryAction? {
        guard let message = plan.diagnostics.first(where: { $0.severity == .error })?.message.lowercased() else {
            return nil
        }
        if message.contains("master") && (
            message.contains("socket") || message.contains("fixture") || message.contains("locator")
        ) {
            return .useExternalFixture
        }
        if message.contains("spout") || message.contains("funnel") || message.contains("fill channel") || message.contains("pour path") {
            return .placeSpoutManually
        }
        return nil
    }

    static func buildFailureMessage(_ error: Error) -> String {
        guard let failure = error as? MotherMoldPlannerError else {
            return "Refab Artist could not finish this mold. Restore the default seam settings, use Auto parting, and build again."
        }
        switch failure {
        case .cancelled:
            return "Build cancelled."
        case .masterNotWatertight, .masterNotWatertightDetails:
            return "This model still has open or self-intersecting geometry. Open Issues, use Make Watertight, then build the mold again."
        case .emptyMaster:
            return "The model contains no usable surface geometry. Load a non-empty mesh, then build the mold again."
        case .cavityFailed:
            return "Refab Artist could not form a closed casting cavity from this surface. Use Make Watertight or reduce very fine surface detail, then rebuild."
        case .shellFailed:
            return "Refab Artist could not form a printable wall around this cavity. Try a thinner wall, fewer parts, or Silicone mold + shell, then rebuild."
        case .partitionFailed(let detail)
            where detail.localizedCaseInsensitiveContains("manual parting requires exactly"):
            return "\(detail) Add the required manual plane or switch Parting to Auto, then rebuild."
        case .partitionFailed(let detail):
            let lower = detail.lowercased()
            if lower.contains("partition") || lower.contains("split plane") || lower.contains("part count") {
                return "The selected split could not create separate mold parts. Switch Parting to Auto or move each manual plane through the model, then rebuild."
            }
            return "Refab Artist stopped before export because generated tooling failed a required check. \(detail)"
        case .incorrectPartCount(let requested, let produced):
            return "The split produced \(produced) of \(requested) requested mold parts. Switch Parting to Auto or move the manual planes through the model, then rebuild."
        case .disconnectedParts:
            return "The generated assembly failed: disconnected material was produced while splitting the mold. Use Auto parting, fewer Parts, or reduce/disable seam features, then rebuild."
        case .partsNotWatertight:
            return "One or more final mold parts failed the printability check. Try fewer parts, smaller seam features, or a different parting direction, then rebuild."
        }
    }

    static func exportSnapshot(
        nonStaleDisplayedPlan: MotherMoldPlan?,
        generatedSignature: MotherMoldInputSignature?,
        currentOutputSettings: MotherMoldSettings? = nil
    ) -> ExportSnapshot? {
        guard let plan = nonStaleDisplayedPlan,
              let generatedSignature,
              !plan.parts.isEmpty,
              blockingExportReason(for: plan, settings: currentOutputSettings ?? generatedSignature.settings) == nil else {
            return nil
        }
        return ExportSnapshot(
            plan: plan,
            settings: currentOutputSettings ?? generatedSignature.settings
        )
    }
}

enum MotherMoldWorkflow {
    struct Step: Equatable, Identifiable {
        var id: Int
        var title: String
        var detail: String
    }

    static func steps(
        plan: MotherMoldPlan,
        settings: MotherMoldSettings
    ) -> [Step] {
        guard MotherMoldUIContract.blockingExportReason(for: plan) == nil else {
            return [Step(
                id: 1,
                title: "Resolve build status",
                detail: "Do not print or pour yet. Follow the action in Build Status, rebuild, and confirm Ready to export."
            )]
        }

        let fixtureDetail: String
        if settings.subtype == .siliconeJacket {
            if plan.masterMount.mode == .flatBaseSocket {
                fixtureDetail = "Seat the master in the split socket. Apply compatible clay or reusable sealant continuously around the seal land; the printed fit is a locator, not a liquid seal."
            } else {
                fixtureDetail = "Install the external support at the modeled position. Test that the master cannot slide or tip, then liquid-seal every penetration."
            }
        } else {
            fixtureDetail = "Clean the cavity and apply the release system required by the casting material and printed mold material."
        }

        let clampDetail: String
        if settings.flange.enabled, plan.flangePlatesPlaced > 0 {
            let hardware = plan.effectiveBoltHoleCount > 0
                ? "Use the verified bolt holes with washers, tightening evenly."
                : "Use evenly spaced clamps or straps; no final bolt holes are available."
            clampDetail = "Dry-fit the parts and confirm every tapered key seats without force. \(hardware) Seal the exterior seam if the casting material can leak through print layers."
        } else {
            clampDetail = "Dry-fit and align the parts, then secure the complete seam with evenly spaced straps or clamps. Seal the exterior seam before pouring."
        }

        let pourDetail = settings.subtype == .siliconeJacket
            ? "Pour mixed silicone slowly through the funnel. Stop when material rises cleanly at the vents; tap or vibrate only as recommended by the silicone supplier."
            : "Pour casting material slowly through the pour hole. Watch the vents for trapped air and stop at the material supplier's recommended fill level."
        let demoldDetail = settings.subtype == .siliconeJacket
            ? "After full cure, remove hardware, separate rigid parts along the shown demold directions, then peel the flexible silicone liner from the master. Trim the gate and vent nubs."
            : "After full cure, remove hardware and separate rigid parts along the shown demold directions. Never pry against the artwork surface; trim the gate and vent nubs afterward."

        return [
            Step(id: 1, title: "Prepare printed parts", detail: "Deburr seam faces, tapered keys, bolt holes, pour hole, and vents. Wash or post-cure the print material as required, then inspect the cavity under good light."),
            Step(id: 2, title: settings.subtype == .siliconeJacket ? "Secure and seal the master" : "Prepare the cavity", detail: fixtureDetail),
            Step(id: 3, title: "Align and clamp", detail: clampDetail),
            Step(id: 4, title: "Fill and vent", detail: pourDetail),
            Step(id: 5, title: "Cure and demold", detail: demoldDetail),
        ]
    }
}

/// Snapshot of every input that affects generated Inflatables panels.
struct InflatablesInputSignature: Equatable {
    var modelPath: String?
    var modelTriangleCount: Int
    var modelBounds: String?
    var settings: InflatablesSettings
}

/// Snapshot of every input that affects a slice plan. Equality is used to
/// re-arm the explicit Slice gate whenever any of them changes.
struct SliceInputSignature: Equatable {
    var constructionMode: ConstructionMode
    var modelScale: Vec3
    var modelRotationDegrees: Vec3
    var importUnit: ImportUnitPreset
    var materialThickness: Double
    var materialPreset: MaterialPreset
    var sliceAxis: SliceAxis
    var sliceTiltFirst: Double
    var sliceTiltSecond: Double
    var secondarySliceAxis: SliceAxis
    var slotClearance: Double
    var notchWidth: Double
    var notchWidthOverrideEnabled: Bool
    var slotAngleDegrees: Double
    var slotReliefEnabled: Bool
    /// Manufacturing Tool Dia.: sizes Interlocked and Radial slot relief.
    var toolDiameter: Double
    var radialSliceCount: Int
    var radialFirstAxisByDistance: Bool
    var radialFirstAxisCount: Int
    var radialFirstAxisSpacing: Double
    var radialNotchFactor: Double
    var radialReliefType: RadialReliefType
    var curvePrimaryAxis: SliceAxis
    var curveFirstAxisCount: Int
    var curveSliceCount: Int
    var curveAmplitude: Double
    var threeDSliceDepth: Double
    var dowelsEnabled: Bool
    var dowelDiameter: Double
    var dowelInset: Double
    var dowelShape: DowelShape
    var dowelAutomaticCount: Int
    var foldedDetailFaces: Int
    // NEO-104: folded joinery + Simplify Form + seam inputs.
    var foldedJoinery: JoineryParameters
    var foldedSplitPanels: Bool
    var foldedSeamEdges: [FoldedSeamEdge]
    var customSliceDistributionEnabled: Bool
    var customSliceCount: Int
    var sliceDistributionMethod: SliceDistributionMethod
    var sliceByDistanceSpacingMm: Double
    var customSlicePositions: [Double]

    /// True when two signatures differ ONLY in dowel parameters and/or slice
    /// direction. Those changes must NOT force a manual re-slice: dowels don't
    /// alter the slice plan (they change the rods and the drilled holes, both
    /// rebuilt independently), and slice direction auto-reslices — the plan
    /// recomputes while the gate stays armed. Everything else (thickness,
    /// counts, axis, distribution…) keeps the explicit Slice gate so a heavy
    /// recompute doesn't fire on every keystroke.
    func sameSlicePlanGate(as other: SliceInputSignature) -> Bool {
        var masked = self
        masked.dowelsEnabled = other.dowelsEnabled
        masked.dowelDiameter = other.dowelDiameter
        masked.dowelInset = other.dowelInset
        masked.dowelShape = other.dowelShape
        masked.dowelAutomaticCount = other.dowelAutomaticCount
        masked.sliceTiltFirst = other.sliceTiltFirst
        masked.sliceTiltSecond = other.sliceTiltSecond
        return masked == other
    }
}

/// The three slice-distribution methods in the Stacked Slice Distribution panel.
enum SliceDistributionMethod: String, CaseIterable, Identifiable, Codable {
    /// Derive count automatically from material thickness and model extent.
    case automatic
    /// User-specified exact count (the existing "Distribute count" toggle behavior).
    case byCount
    /// User-specified spacing in mm → count derived from extent.
    case byDistance
    /// User-edited individual positions (activated automatically when the user
    /// edits slices; shows position count in the panel).
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .byCount:   return "By Count"
        case .byDistance: return "By Distance"
        case .custom:    return "Custom"
        }
    }
}

private enum ViewportMode: String, CaseIterable, Identifiable {
    case model3D
    case sheet2D
    case modelAndSheet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .model3D:
            return "3D"
        case .sheet2D:
            return "Sheet"
        case .modelAndSheet:
            return "3D+Sheet"
        }
    }
}

private struct EmptyViewportState: View {
    let content: WorkspaceEmptyStateContent
    let importAction: () -> Void
    let sampleAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: content.systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(content.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(content.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let detail = content.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360)

            HStack(spacing: 8) {
                if let action = content.primaryAction {
                    Button(action: importAction) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let action = content.secondaryAction {
                    Button(action: sampleAction) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}

private struct InspectorEmptyState: View {
    let content: WorkspaceEmptyStateContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(content.title, systemImage: content.systemImage)
                .font(.headline)
            Text(content.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = content.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WorkspaceErrorNotice: View {
    let content: WorkspaceErrorNoticeContent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: content.systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(content.title)
                    .font(.caption.weight(.semibold))
                Text(content.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = content.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(tint.opacity(WorkspaceAccessibilityVisualPolicy.noticeFillOpacity), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    tint.opacity(WorkspaceAccessibilityVisualPolicy.noticeBorderOpacity),
                    lineWidth: WorkspaceAccessibilityVisualPolicy.noticeBorderWidth
                )
        )
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch content.severity {
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct HeaderBar: View {
    let model: MeshSummary?
    let isSidebarVisible: Bool
    let isStatsVisible: Bool
    let selectedConstructionMode: ConstructionMode?
    @Binding var viewportMode: ViewportMode
    @Binding var viewportPreviewMode: ViewportPreviewMode
    let motherMoldCanExplode: Bool
    let motherMoldHasUndercuts: Bool
    let motherMoldPartNames: [String]
    @Binding var motherMoldExploded: Bool
    @Binding var motherMoldShowUndercuts: Bool
    @Binding var isolatedMotherMoldPartName: String?
    let canShowSheetPreview: Bool
    let hasModel: Bool
    let toggleSidebar: () -> Void
    let toggleStats: () -> Void

    var body: some View {
        let sidebarAccessibility = WorkspaceAccessibilityContent.sidebarToggle(isInspectorVisible: isSidebarVisible)

        HStack(spacing: 8) {
            AccessibleIconButton(
                systemImage: "sidebar.left",
                accessibility: sidebarAccessibility,
                action: toggleSidebar
            )
            .buttonStyle(.borderless)
            .help(isSidebarVisible ? "Hide inspector" : "Show inspector")

            VStack(alignment: .leading, spacing: 3) {
                Text(model?.name ?? "Refab Artist")
                    .font(.system(size: 18, weight: .semibold))
                Text(model?.path ?? "Import a model to begin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            if model != nil {
                if selectedConstructionMode != nil {
                    Picker("Preview", selection: $viewportPreviewMode) {
                        ForEach(ViewportPreviewMode.allCases) { mode in
                            Text(previewLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 142)
                    .layoutPriority(2)
                    .accessibilityLabel(Text("Preview layer visibility"))
                    .help(selectedConstructionMode == .motherMold
                        ? "Show the master, the generated mold parts, or both."
                        : "What the 3D view shows: just your original model, just the generated slices, or both together (slices with a faint shell of the model over them).")

                    if selectedConstructionMode == .motherMold, motherMoldCanExplode {
                        Toggle(isOn: $motherMoldExploded) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                Text("Explode")
                            }
                            .fixedSize()
                        }
                        .toggleStyle(.button)
                        .tint(motherMoldExploded ? .accentColor : nil)
                        .layoutPriority(2)
                        .help(motherMoldExploded
                            ? "Press again to return every mold part to its assembled position."
                            : "Move mold parts apart along their demold directions so the cavity, keys, pour hole, and vents can be inspected.")
                        .accessibilityLabel("Explode mold parts")
                        .accessibilityValue(motherMoldExploded ? "On" : "Off")

                        Menu {
                            Button {
                                isolatedMotherMoldPartName = nil
                            } label: {
                                Label("Show all parts", systemImage: isolatedMotherMoldPartName == nil ? "checkmark" : "square.stack.3d.up")
                            }
                            Divider()
                            ForEach(motherMoldPartNames, id: \.self) { partName in
                                Button {
                                    isolatedMotherMoldPartName = partName
                                } label: {
                                    Label(
                                        partName,
                                        systemImage: isolatedMotherMoldPartName == partName ? "checkmark" : "cube"
                                    )
                                }
                            }
                        } label: {
                            Text(isolatedMotherMoldPartName == nil ? "Parts" : "1 part")
                                .fixedSize()
                                .frame(minWidth: 42)
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .layoutPriority(2)
                        .help(isolatedMotherMoldPartName == nil
                            ? "Show all mold parts or isolate one part for inspection."
                            : "Only \(isolatedMotherMoldPartName ?? "one part") is visible. Choose Show all parts to restore the complete mold.")
                        .accessibilityLabel("Visible mold parts")

                        if motherMoldHasUndercuts {
                            Toggle(isOn: $motherMoldShowUndercuts) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text("Undercuts")
                                }
                                .fixedSize()
                            }
                            .toggleStyle(.button)
                            .tint(motherMoldShowUndercuts ? .red : nil)
                            .layoutPriority(2)
                            .help(motherMoldShowUndercuts
                                ? "Hide the red measured-undercut markers."
                                : "Show red markers where the current demold direction may trap a rigid part.")
                            .accessibilityLabel("Show undercut markers")
                            .accessibilityValue(motherMoldShowUndercuts ? "On" : "Off")
                        }
                    }
                }
            }
            if canShowSheetPreview {
                Picker("View", selection: $viewportMode) {
                    ForEach(ViewportMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 176)
                .accessibilityLabel(Text("Viewport layout"))
                .help("Switch between the 3D model, the 2D cut-sheet layout, or both side by side. The sheet view previews exactly what will be cut — use it to spot problems before exporting.")
            }
            if let model {
                Text(model.format.uppercased())
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button(action: toggleStats) {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .disabled(!hasModel)
            .help(isStatsVisible ? "Hide model statistics" : "Show model statistics")
            .accessibilityLabel(isStatsVisible ? "Hide model statistics" : "Show model statistics")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func previewLabel(_ mode: ViewportPreviewMode) -> String {
        guard selectedConstructionMode == .motherMold else { return mode.label }
        switch mode {
        case .model: return "Master"
        case .slices: return "Mold"
        case .modelAndSlices: return "Both"
        }
    }
}

/// Viewport navigation: a compact VERTICAL tool strip floating at the
/// viewport's right edge (orbit / pan / zoom / fit), with the view-direction
/// menu at its top standing in for the view cube.
private struct ViewportControls: View {
    @Binding var cameraState: ViewportCameraState
    let cameraRadius: Double
    let isEnabled: Bool
    @Binding var isOrthographic: Bool

    var body: some View {
        VStack(spacing: 5) {
            Menu {
                ForEach(ViewportCameraPreset.allCases) { preset in
                    Button {
                        cameraState.apply(preset)
                    } label: {
                        Label(preset.label, systemImage: "view.3d")
                    }
                }
            } label: {
                Image(systemName: "cube")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help("View direction — snap the camera to a standard view.")
            .accessibilityLabel(Text(WorkspaceAccessibilityContent.snapView.label))
            .accessibilityHint(Text(WorkspaceAccessibilityContent.snapView.hint ?? ""))

            Divider()
                .frame(width: 22)

            // Ortho/perspective toggle. Dowel-edit and ring interactions are
            // perspective-only (the picking math assumes a perspective camera);
            // switching to ortho disables them with an explanatory label if active.
            Button {
                isOrthographic.toggle()
            } label: {
                Image(systemName: isOrthographic ? "square.on.square" : "square.on.square.dashed")
                    .frame(width: 18, height: 18)
            }
            .help(isOrthographic
                ? "Orthographic projection — click to switch back to perspective. Note: dowel editing and slice-direction rings are disabled in orthographic mode."
                : "Perspective projection — click to switch to orthographic (parallel projection). Dowel editing and rings are disabled while ortho is active.")
            .accessibilityLabel(isOrthographic ? "Switch to perspective" : "Switch to orthographic")

            Divider()
                .frame(width: 22)

            // Orbit and pan are DIRECT gestures (drag to orbit; right-drag or
            // shift/option-drag to pan; scroll or pinch to zoom) — the old
            // strip of step-arrows duplicated them one nudge at a time.
            AccessibleIconButton(
                systemImage: "plus.magnifyingglass",
                accessibility: WorkspaceAccessibilityContent.zoomIn,
                action: { cameraState.zoomIn() }
            )
            .help("Zoom in — or just scroll / pinch in the viewport.")

            AccessibleIconButton(
                systemImage: "minus.magnifyingglass",
                accessibility: WorkspaceAccessibilityContent.zoomOut,
                action: { cameraState.zoomOut() }
            )
            .help("Zoom out — or just scroll / pinch in the viewport.")

            AccessibleIconButton(
                systemImage: "viewfinder",
                accessibility: WorkspaceAccessibilityContent.fitView,
                action: { cameraState.reset() }
            )
            .help("Fit the model in view and reset the camera. Drag to orbit; right-drag (or shift-drag) to pan; scroll to zoom.")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewport controls")
    }
}

private struct AccessibleIconButton: View {
    let systemImage: String
    let accessibility: WorkspaceAccessibilityDescription
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .accessibilityLabel(Text(accessibility.label))
        .accessibilityValueIfPresent(accessibility.value)
        .accessibilityHintIfPresent(accessibility.hint)
    }
}

private extension View {
    @ViewBuilder
    func accessibilityValueIfPresent(_ value: String?) -> some View {
        if let value {
            accessibilityValue(Text(value))
        } else {
            self
        }
    }

    @ViewBuilder
    func accessibilityHintIfPresent(_ hint: String?) -> some View {
        if let hint {
            accessibilityHint(Text(hint))
        } else {
            self
        }
    }

}

private struct InspectorSection<Content: View>: View {
    let section: InspectorPanelSection
    private let collapsible: Bool
    @Binding private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    /// Collapsible section — the header toggles its content (left rail).
    init(section: InspectorPanelSection, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.collapsible = true
        self._isExpanded = isExpanded
        self.content = content
    }

    /// Always-open section (no chevron) — e.g. the Actions bar / empty state.
    init(section: InspectorPanelSection, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.collapsible = false
        self._isExpanded = .constant(true)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Label(section.title, systemImage: section.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse \(section.title)" : "Expand \(section.title)")
            } else {
                Label(section.title, systemImage: section.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if isExpanded {
                content()
            }
        }
        .overflowProbe(section.title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.accessibilityLabel)
    }
}

private struct MetadataPanel: View {
    let model: MeshSummary

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Format", model.format)
            row("Bytes", "\(model.byteCount)")
            row("Vertices", "\(model.vertexObservationCount)")
            row("Faces", "\(model.faceCount)")
            row("Triangles", "\(model.triangleCount)")
            row("Min", model.bounds?.min.display ?? "n/a")
            row("Max", model.bounds?.max.display ?? "n/a")
            row("Preflight", model.preflight.statusLabel)
            row("Unique", "\(model.preflight.uniqueVertexCount)")
            row("Duplicates", "\(model.preflight.duplicateVertexObservationCount)")
            row("Invalid refs", "\(model.preflight.invalidTriangleReferenceCount)")
            row("Degenerate", "\(model.preflight.degenerateTriangleCount)")
            row("Open edges", "\(model.preflight.boundaryEdgeCount)")
            row("Non-manifold", "\(model.preflight.nonManifoldEdgeCount)")
        }
        .font(.system(size: 13, design: .monospaced))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

/// Display unit for the Manufacturing Settings fields. Values are STORED in
/// millimeters everywhere; this only converts what the fields show/accept.
enum ManufacturingDisplayUnit: String, CaseIterable, Identifiable {
    case millimeters = "mm"
    case inches = "in"

    var id: String { rawValue }
    var label: String { rawValue }

    var millimetersPerUnit: Double {
        self == .millimeters ? 1.0 : 25.4
    }

    var fieldPrecision: Int {
        self == .millimeters ? 2 : 3
    }
}

/// The "Model Issues" tab: a "Slices With Errors" list you can click to
/// highlight the offending part, plus "Global Errors" for model-level
/// problems. It is fed by the cut-sheet document's real error
/// flags (slot-splits-part, exceeds-sheet) and the mesh preflight.
private struct ModelIssuesPanel: View {
    let model: MeshSummary
    let document: CutSheetDocument?
    let sliced: Bool
    @Binding var selectedStepID: AssemblyStep.ID?
    let isRepairing: Bool
    let repairAction: () -> Void
    /// Make Watertight with exactly this method (Fix in place / Make walls /
    /// Rebuild as solid). Every fix button names its method and runs it —
    /// the panel never runs a method the user didn't pick here.
    var onApplyWatertight: ((WatertightMethod) -> Void)? = nil
    /// Turn Make Watertight off (slicing goes back to the imported mesh).
    var onRemoveWatertight: (() -> Void)? = nil
    /// Show Object → Modify Form → Make Watertight (top shape, wall
    /// thickness, per-opening choices).
    var onShowWatertightOptions: (() -> Void)? = nil
    var isMakingWatertight: Bool = false
    /// Make Watertight is on (alone, or under Hollow / Thicken).
    var watertightActive: Bool = false
    /// Its last run changed nothing (failed / nothing to do): slicing uses
    /// the original, still-open model.
    var watertightFailed: Bool = false
    /// The cache holds Make Watertight's result for the settings on screen
    /// (false: a value changed and nothing recomputed yet).
    var watertightResultCurrent: Bool = true
    /// Make Watertight with the settings on screen is already known to change
    /// nothing (an applied or previewed run of it did).
    var watertightKnownNoOp: Bool = false
    /// The tool whose eye preview is on screen (nil = none): slicing waits.
    var previewingTool: String? = nil
    /// The Hollow / Thicken applied on top of Make Watertight (nil = none).
    var formToolOnTop: String? = nil
    /// The method Make Watertight uses, and the result line of its last run.
    var watertightMethod: WatertightMethod = .closeOpenings
    var watertightReceipt: String? = nil
    /// Per-opening choices (Leave open / own top shape / Closed in walls),
    /// so each method can say what it will really do.
    var openingChoices: [OpeningCapper.OpeningChoice] = []
    /// Fix in place's top shape (mm, 0 flat) and Make walls' thickness (mm),
    /// so each choice can say what it will do.
    var watertightTopHeight: Double = 0
    var wallThickness: Double = 2
    /// True while the diagnosis below is still being measured for the model
    /// as loaded now: no fix is offered until it lands.
    var diagnosisPending: Bool = false
    /// Unit-independent diagnosis of the imported surface (openings, pinholes,
    /// doubled triangles…). Preferred over the raw preflight counts, which are
    /// measured in the file's own units.
    var openingDiagnosis: OpeningCapper.Diagnosis? = nil
    /// True when `openingDiagnosis` describes `model` itself (no Modify Form
    /// result is standing in for the imported mesh).
    var diagnosisDescribesModel: Bool = false
    /// Problem sites marked in the viewport (empty when there are no markers
    /// to show), the selection, and the actions the selected row offers.
    var issueSites: [OpeningCapper.Site] = []
    var issueSitesOmitted: Int = 0
    var selectedIssueSiteID: String? = nil
    var onSelectIssueSite: ((String?) -> Void)? = nil
    var showIssueMarkers: Binding<Bool>? = nil
    var isMotherMold: Bool = false
    var motherMoldPlan: MotherMoldPlan? = nil
    var motherMoldStatus: MotherMoldUIContract.BuildStatusPresentation? = nil
    var motherMoldStatusAction: ((MotherMoldUIContract.RecoveryAction) -> Void)? = nil

    /// The repair section shows when the model's report says it is not
    /// watertight (unless the diagnosis finds nothing to fix), and also when
    /// a closed solid Manifold accepts still has spots the diagnosis can fix
    /// in place (self-contact non-manifold edges, doubled triangles, specks) —
    /// the truthful report calls such a model watertight, so the report alone
    /// would hide Fix in Place.
    private var showsRepairSection: Bool {
        // With Make Watertight on, its status box says what was done and
        // offers the other methods; the imported model's problems no longer
        // describe what slicing uses.
        if watertightActive && !watertightFailed { return false }
        // A failed run: the other fixes, when there are any (a closed solid
        // with nothing to fix has none, and then "No global errors" is true).
        if watertightActive && watertightFailed { return !offeredMethods.isEmpty || diagnosisPending }
        if !model.preflight.isWatertight && !(openingDiagnosis?.isNothingToFix ?? false) { return true }
        return diagnosisDescribesModel && (openingDiagnosis?.hasFixableProblems ?? false)
    }

    private var errorParts: [CutSheetPart] {
        guard let document else { return [] }
        return document.sheets.flatMap(\.parts).filter { $0.isError || $0.isDetached || $0.overflowsSheet }
    }

    private func issueDescription(for part: CutSheetPart) -> String {
        if part.isError {
            return "Slot splits the part — widen the model, lower the notch width, or change the slice direction."
        }
        if part.isDetached {
            return "Detached piece — nothing holds it to the model; it will fall off. Change the slicing angle or pick another technique."
        }
        return "Too large for the sheet — use larger stock or shrink the model."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isMotherMold ? "Mold Parts" : "Parts With Errors")
                    .font(.headline)
                if isMotherMold, let plan = motherMoldPlan {
                    if motherMoldStatus?.kind != .readyToPrint {
                        Label("Inspection only until the issue below is fixed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(
                            "\(plan.parts.count) printable mold part\(plan.parts.count == 1 ? "" : "s") passed final validation",
                            systemImage: "checkmark.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.green)
                    }
                } else if isMotherMold {
                    Text("Build the mold to validate its printable parts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !sliced {
                    Text("Slice the model to check its parts for errors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if errorParts.isEmpty {
                    Label("No part errors", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    ForEach(errorParts) { part in
                        Button {
                            selectedStepID = part.stepIndex
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(part.isError ? Color.red : (part.isDetached ? Color.blue : Color.orange))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(part.label)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(issueDescription(for: part))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to highlight this part in the views.")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(isMotherMold ? "Build Status" : "Global Errors")
                    .font(.headline)
                if watertightActive {
                    activeWatertightStatus
                }
                if isMotherMold, let status = motherMoldStatus {
                    Label(status.title, systemImage: motherMoldStatusIcon(status.kind))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(motherMoldStatusColor(status.tone))
                    Text(status.summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(status.details, id: \.self) { detail in
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = status.action, let motherMoldStatusAction {
                        if action == .makeWatertight {
                            // The fixes themselves, each named — never one
                            // button that runs a method nobody picked. With
                            // Make Watertight on, its box above has them.
                            let closedSolid = !diagnosisPending && currentDiagnosis?.isNothingToFix == true
                            if closedSolid && status.kind == .blocked {
                                closedSolidMoldHint
                            } else if closedSolid {
                                Text(formToolOnTop.map { "Your imported model is a closed solid; the \($0) result is what fails the watertight check (see the counts above). Change the \($0) amount, Remove \($0) in Modify Form, or use Repair Mesh to clear collapsed triangles." }
                                     ?? "Your imported model is a closed solid, but the form slicing uses fails the watertight check (see the counts above). Repair Mesh clears collapsed triangles.")
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                repairChoices
                            } else if !watertightActive || watertightFailed {
                                repairChoices
                            } else if !diagnosisPending, !offeredMethods.contains(where: { $0 != watertightMethod }) {
                                Text("Make Watertight (\(watertightMethod.label)) is already applied, and it's the only fix this surface allows. The mold still failed after it: open the build details, or try a thinner wall or fewer parts. Remove (above) turns Make Watertight off.")
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Button(action.label) {
                                motherMoldStatusAction(action)
                            }
                            .buttonStyle(.bordered)
                            if watertightActive && watertightFailed && !offeredMethods.isEmpty {
                                repairChoices
                            }
                        }
                    }
                } else if showsRepairSection {
                    Label {
                        Text(currentDiagnosis.map { "\($0.sentence) Generated parts may be incomplete." }
                             ?? "Mesh needs repair — \(model.preflight.degenerateTriangleCount) degenerate triangles, \(model.preflight.boundaryEdgeCount) open edges, \(model.preflight.nonManifoldEdgeCount) non-manifold edges. Generated parts may be incomplete.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
                    }

                    repairChoices
                } else if isMotherMold, motherMoldPlan == nil {
                    Label("No mold validation yet", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if diagnosisPending && (!watertightActive || watertightFailed) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking the surface…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !watertightActive || model.preflight.isWatertight {
                    Label("No global errors", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                // Whenever the viewport marks problem spots, list them here.
                if !issueSites.isEmpty {
                    issueSitesSection(canClose: openingDiagnosis?.canCloseOpenings ?? false)
                }
            }
        }
    }

    /// The diagnosis, but only once it describes the model as loaded now.
    private var currentDiagnosis: OpeningCapper.Diagnosis? {
        diagnosisPending ? nil : openingDiagnosis
    }

    /// The Make Watertight methods that can fix this model, best first:
    /// Fix in place whenever the damage is local, Make walls when it has an
    /// opening to build walls around, and Rebuild as solid always (it is the
    /// only one for damage too widespread to fix in place).
    private var offeredMethods: [WatertightMethod] {
        WatertightMethod.offered(for: currentDiagnosis)
    }

    private static func mm(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
    }

    private func methodTitle(_ method: WatertightMethod) -> String {
        switch method {
        case .closeOpenings: return "Fix in place"
        case .walls: return "Make walls (a cup)"
        case .rebuild: return "Rebuild as solid"
        }
    }

    private func methodSymbol(_ method: WatertightMethod) -> String {
        switch method {
        case .closeOpenings: return "bandage"
        case .walls: return "cup.and.saucer"
        case .rebuild: return "cube.fill"
        }
    }

    /// The saved per-opening choice for each diagnosed opening.
    private var choicesByOpening: [OpeningCapper.OpeningChoice?] {
        OpeningCapper.matchChoices(openingChoices, to: currentDiagnosis?.openings ?? []).byOpening
    }

    private func topShapePhrase(_ height: Double) -> String {
        height == 0 ? "a flat"
            : (height > 0 ? "a domed (\(Self.mm(height)) mm)" : "a dished (\(Self.mm(-height)) mm)")
    }

    /// What the method does to THIS model with the per-opening choices as
    /// set, in physical terms.
    private func methodEffect(_ method: WatertightMethod) -> String {
        if let reason = method.unavailableReason(currentDiagnosis, choices: openingChoices) { return reason }
        let openings = currentDiagnosis?.openings.count ?? 0
        let byOpening = choicesByOpening
        switch method {
        case .closeOpenings:
            guard openings > 0 else {
                return "Heals only the broken spots. Every other triangle stays exactly where it is."
            }
            let leftOpen = byOpening.filter { $0?.leaveOpen ?? false }.count
            let capped = openings - leftOpen
            let ownShape = byOpening.contains { ($0?.leaveOpen ?? false) == false && $0?.topHeight != nil }
            var text: String
            if capped == 0 {
                text = "Heals the broken spots and leaves every opening open (your choice)."
            } else {
                let which = capped == 1
                    ? (openings == 1 ? "the opening" : "1 opening")
                    : (leftOpen == 0 ? "each of the \(capped) openings" : "\(capped) of the \(openings) openings")
                text = ownShape
                    ? "Caps \(which) with a new top (shapes as set per opening) and heals the broken spots."
                    : "Caps \(which) with \(topShapePhrase(watertightTopHeight)) top and heals the broken spots."
                if leftOpen > 0 {
                    text += " \(leftOpen == 1 ? "1 opening stays" : "\(leftOpen) openings stay") open by your choice."
                }
            }
            return text + " The rest of your surface stays exactly as it is."
        case .walls:
            let closed = byOpening.filter { $0?.closedInWalls ?? false }.count
            let rims = openings - closed
            var text = "Keeps the outside exactly as modelled and grows a \(Self.mm(wallThickness)) mm wall inward."
            if closed == 0 {
                text += openings == 1
                    ? " The opening stays open, so you get a cup you can print."
                    : " Every opening stays open."
            } else {
                text += " \(rims == 1 ? "1 rim stays" : "\(rims) rims stay") open; \(closed == 1 ? "1 opening gets" : "\(closed) openings get") a floor or lid as thick as the wall."
            }
            return text
        case .rebuild:
            guard currentDiagnosis?.canCloseOpenings ?? false else {
                return "The fix for damage this widespread. It re-meshes the whole surface into one closed solid, filling open vessels and inner cavities, and fine detail softens."
            }
            return openings > 0
                ? "Re-meshes the WHOLE surface into one filled solid. Openings fill in solid, their tops come out stepped, and fine detail softens. Only for damage too widespread to fix in place."
                : "Re-meshes the WHOLE surface into one solid; every triangle is replaced and fine detail softens. Only for damage too widespread to fix in place."
        }
    }

    /// `method` is the applied fix that just changed nothing with these
    /// settings: offering it again would only re-run the same no-op.
    private func failedHere(_ method: WatertightMethod) -> Bool {
        ((watertightActive && watertightFailed) || watertightKnownNoOp)
            && !isMakingWatertight && method == watertightMethod
    }

    /// Why `method`'s button is disabled (nil = it can run).
    private func methodBlockedReason(_ method: WatertightMethod) -> String? {
        if failedHere(method) { return failedHereHint(method) }
        return method.unavailableReason(currentDiagnosis, choices: openingChoices)
    }

    /// What to do about a fix that just changed nothing — naming only what is
    /// on screen and possible.
    private func failedHereHint(_ method: WatertightMethod) -> String {
        var text = "This is the fix that just changed nothing with these settings."
        let settings: String? = {
            switch method {
            case .rebuild: return "change its Detail in Object → Modify Form"
            case .closeOpenings, .walls: return optionsLinkText != nil ? "change its settings (Options…)" : nil
            }
        }()
        let another = offeredMethods.contains {
            $0 != method && $0.unavailableReason(currentDiagnosis, choices: openingChoices) == nil
        }
        let remove = watertightActive ? ", or Remove turns Make Watertight off" : ""
        switch (settings, another) {
        case let (s?, true): text += " To try again, \(s), or pick another fix."
        case let (s?, false): text += " To try again, \(s)\(remove)."
        case (nil, true): text += " Pick another fix\(remove)."
        case (nil, false): text += watertightActive ? " Remove turns Make Watertight off." : ""
        }
        return text
    }

    /// The method marked "recommended": the first offered one that can run.
    private var recommendedMethod: WatertightMethod? {
        offeredMethods.first { methodBlockedReason($0) == nil }
    }

    /// One choice: a button that runs exactly `method`, plus what it does.
    @ViewBuilder
    private func methodChoice(_ method: WatertightMethod, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let button = Button {
                onApplyWatertight?(method)
            } label: {
                Label(recommended ? "\(methodTitle(method)) — recommended" : methodTitle(method),
                      systemImage: methodSymbol(method))
            }
            .disabled(isRepairing || isMakingWatertight || onApplyWatertight == nil
                      || methodBlockedReason(method) != nil)
            .help(methodBlockedReason(method) ?? (methodEffect(method) + " Reversible: Remove turns it off again."))
            if recommended {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
            Text(failedHere(method) ? (methodBlockedReason(method) ?? "") : methodEffect(method))
                .font(.caption2)
                .foregroundStyle(failedHere(method) ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Options…" link text naming only the settings this model has (nil =
    /// none worth opening Modify Form for).
    private var optionsLinkText: String? {
        guard let diagnosis = currentDiagnosis else { return nil }
        if watertightActive {
            // Switching the picker would re-run the applied fix: name only
            // the applied method's own settings.
            switch watertightMethod {
            case .rebuild:
                return "Set the detail…"
            case .walls:
                guard !diagnosis.openings.isEmpty else { return nil }
                return ModifyFormPanel.showsOpeningRows(diagnosis, method: .walls)
                    ? "Set the wall thickness and a choice per opening…" : "Set the wall thickness…"
            case .closeOpenings:
                guard !diagnosis.openings.isEmpty else { return nil }
                return ModifyFormPanel.showsOpeningRows(diagnosis, method: .closeOpenings)
                    ? "Set the top shape (flat, dome or dish) and a choice per opening…"
                    : "Set the top shape (flat, dome or dish)…"
            }
        }
        guard !diagnosis.openings.isEmpty, offeredMethods.contains(.closeOpenings) else { return nil }
        var parts = ["top shape (flat, dome or dish)"]
        if offeredMethods.contains(.walls) { parts.append("wall thickness") }
        if ModifyFormPanel.showsOpeningRows(diagnosis, method: .closeOpenings)
            || ModifyFormPanel.showsOpeningRows(diagnosis, method: .walls) {
            parts.append("a choice per opening")
        }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Set the \(list)…"
    }

    /// MotherMold asked for Make Watertight, but the surface is already a
    /// closed solid: say so, and offer the whole-surface rebuild only by name.
    @ViewBuilder
    private var closedSolidMoldHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your model is already a closed solid, so Fix in place and Make walls have nothing to change. The mold itself failed: see the build details, or try a thinner wall or fewer parts.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let onApplyWatertight, !(watertightActive && watertightMethod == .rebuild) {
                Button {
                    onApplyWatertight(.rebuild)
                } label: {
                    Label("Rebuild as solid", systemImage: methodSymbol(.rebuild))
                }
                .buttonStyle(.bordered)
                .disabled(isRepairing || isMakingWatertight)
                .help("Re-meshes the WHOLE surface into one closed solid (every triangle is replaced, fine detail softens). Only if the build still says the source isn't watertight. Reversible: Remove turns it off again.")
            }
        }
    }

    /// The repair choices: every way to fix the surface as its own button.
    /// Nothing is offered until the diagnosis says which fixes fit.
    @ViewBuilder
    private var repairChoices: some View {
        VStack(alignment: .leading, spacing: 9) {
            if diagnosisPending {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the surface to see which fixes fit…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !offeredMethods.isEmpty {
                Text("Choose how to fix it")
                    .font(.caption.weight(.semibold))
                ForEach(offeredMethods, id: \.self) { method in
                    methodChoice(method, recommended: method == recommendedMethod)
                }
                if let onShowWatertightOptions, let optionsText = optionsLinkText {
                    Button(optionsText) {
                        onShowWatertightOptions()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    repairAction()
                } label: {
                    if isRepairing {
                        Label("Repairing…", systemImage: "hourglass")
                    } else {
                        Label("Repair Mesh", systemImage: "wrench.and.screwdriver")
                    }
                }
                .controlSize(.small)
                .disabled(isRepairing || isMakingWatertight)
                .help("Removes only triangles that can't be real surface: collapsed triangles, loose zero-area specks and winged fins. Thin but real triangles are never touched. It does NOT close holes.")
                Text("Only removes broken specks and fins; closes nothing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Make Watertight is on: which method, what it did (or that it changed
    /// nothing), and the other methods one click away, plus Remove.
    @ViewBuilder
    private var activeWatertightStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            let under = formToolOnTop.map { " (under \($0))" } ?? ""
            if watertightFailed && !isMakingWatertight {
                Label("\(watertightMethod.label) didn't change the model\(under)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Label("Make Watertight is on: \(watertightMethod.label)\(under)", systemImage: methodSymbol(watertightMethod))
                    .font(.callout.weight(.semibold))
            }
            if isMakingWatertight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let watertightReceipt {
                Text(watertightReceipt)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isMakingWatertight {
                if let previewingTool {
                    Text("Previewing \(previewingTool) in the viewport. Slicing waits until the preview is off, then uses this result again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !watertightResultCurrent {
                    Text("A setting changed and the result hasn't been recomputed yet — slicing uses the model without it until then. Release the slider or press Return to update.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if watertightFailed {
                    let onWhat = formToolOnTop.map { "\($0) applied to your original model" } ?? "your original model"
                    let next = offeredMethods.contains { $0 != watertightMethod && methodBlockedReason($0) == nil }
                        ? " Pick another fix below, or Remove."
                        : " Remove turns Make Watertight off."
                    Text("Slicing and export use \(onWhat), unchanged.\(next)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(formToolOnTop.map { "Slicing and export use \($0) applied on top of this result. Your imported model is unchanged." }
                         ?? "Slicing and export use this result. Your imported model is unchanged.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A failed run shows the full choices below (repair section).
            let others = watertightFailed ? [] : offeredMethods.filter { $0 != watertightMethod }
            if let onApplyWatertight, !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use a different fix instead:")
                        .font(.caption2.weight(.semibold))
                    ForEach(others, id: \.self) { method in
                        Button {
                            onApplyWatertight(method)
                        } label: {
                            Label(methodTitle(method), systemImage: methodSymbol(method))
                        }
                        .controlSize(.small)
                        .disabled(isRepairing || isMakingWatertight || methodBlockedReason(method) != nil)
                        .help(methodBlockedReason(method) ?? methodEffect(method))
                    }
                }
            }
            HStack(spacing: 10) {
                if let onRemoveWatertight {
                    Button("Remove") {
                        onRemoveWatertight()
                    }
                    .controlSize(.small)
                    .disabled(isMakingWatertight)
                    .help(formToolOnTop.map { "Turn Make Watertight off: \($0) then applies to the imported model." }
                          ?? "Turn Make Watertight off: slicing and export go back to the imported model.")
                }
                if let onShowWatertightOptions, let optionsText = optionsLinkText {
                    Button("Options…") {
                        onShowWatertightOptions()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(optionsText.replacingOccurrences(of: "…", with: "") + " (Object → Modify Form → Make Watertight).")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((watertightFailed ? Color.orange : Color.accentColor).opacity(0.08))
        )
    }

    /// "Problem spots": every site as a row (the same dots the viewport
    /// shows); clicking a row selects its marker and flies the camera there.
    /// The selected row expands with its size, what the fix does, and the
    /// button that does it.
    @ViewBuilder
    private func issueSitesSection(canClose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Problem spots")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let showIssueMarkers {
                    Toggle("Show in viewport", isOn: showIssueMarkers)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Mark each problem spot on the model with a coloured dot you can click.")
                }
            }
            ForEach(issueSites) { site in
                let selected = site.id == selectedIssueSiteID
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        onSelectIssueSite?(selected ? nil : site.id)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(nsColor: IssueMarkers.color(for: site.kind)))
                                .overlay(Circle().stroke(Color.primary.opacity(0.55), lineWidth: 1))
                                .frame(width: 9, height: 9)
                            Text(site.title)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(OpeningCapper.formatMM(site.sizeMM))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this spot in the viewport.")

                    if selected {
                        issueSiteDetail(site, canClose: canClose)
                            .padding(.leading, 16)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                )
            }
            if issueSitesOmitted > 0 {
                Text("+ \(issueSitesOmitted) smaller spot\(issueSitesOmitted == 1 ? "" : "s") not listed (the fix handles them too).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onExitCommand { onSelectIssueSite?(nil) }
    }

    @ViewBuilder
    private func issueSiteDetail(_ site: OpeningCapper.Site, canClose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(IssueMarkers.label(for: site.kind)) · \(OpeningCapper.formatMM(site.sizeMM)) across")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(site.fixDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            let openingIndex = site.kind == .opening
                ? (currentDiagnosis?.openings.indices).flatMap { r in r.first { ModifyFormPanel.siteID(forOpening: $0) == site.id } }
                : nil
            let leftOpen = openingIndex.map { choicesByOpening.indices.contains($0) && (choicesByOpening[$0]?.leaveOpen ?? false) } ?? false
            let othersLeftOpen = choicesByOpening.contains { $0?.leaveOpen ?? false }
            if leftOpen {
                Text("Set to Leave open: Fix in place keeps this opening open. Change it under Object → Modify Form → Make Watertight.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if site.fixableInPlace, canClose, let onApplyWatertight {
                let blocked = methodBlockedReason(.closeOpenings)
                Button {
                    onApplyWatertight(.closeOpenings)
                } label: {
                    if isMakingWatertight && watertightMethod == .closeOpenings {
                        Label("Fixing…", systemImage: "hourglass")
                    } else {
                        Label("Fix in place", systemImage: "bandage")
                    }
                }
                .controlSize(.small)
                .disabled(isRepairing || isMakingWatertight || blocked != nil)
                .help(blocked ?? (othersLeftOpen
                    ? "Make Watertight → Fix in place: fixes this spot and the other listed spots, except openings set to Leave open. The rest of your surface stays exactly as it is."
                    : "Make Watertight → Fix in place: fixes this spot and every other one listed, keeping the rest of your surface exactly as it is. Reversible — Remove turns it off."))
            }
            if site.kind == .opening, !leftOpen {
                Text(isMotherMold
                     ? "Fix in place caps it. For real walls (a cup) or a whole-surface rebuild, use the choices under Build Status."
                     : "Fix in place caps it. For real walls (a cup) or a whole-surface rebuild, use the choices under Global Errors.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func motherMoldStatusIcon(_ kind: MotherMoldUIContract.BuildStatusKind) -> String {
        switch kind {
        case .needsRepair: return "wrench.and.screwdriver.fill"
        case .readyToBuild: return "hammer"
        case .building: return "hourglass"
        case .readyToPrint: return "checkmark.circle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func motherMoldStatusColor(_ tone: MotherMoldUIContract.BuildStatusTone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .orange: return .orange
        case .green: return .green
        case .red: return .red
        }
    }
}

private struct ManufacturingSettingsPanel: View {
    @Binding var materialPreset: MaterialPreset
    @Binding var materialThickness: Double
    @Binding var slotClearance: Double
    @Binding var sheetWidth: Double
    @Binding var sheetHeight: Double
    // NEO-105 new fields
    @Binding var kerf: Double
    @Binding var toolDiameter: Double
    /// The packer's page margin: the same value as Margin in Export layout.
    /// A material carries it (applying one sets it).
    @Binding var pageMargin: Double
    /// Whether the current mode reads Slot Offset and Tool Dia.
    /// (`ManufacturingRows`).
    var slotOffsetState: ManufacturingRowState = .active
    var toolDiameterState: ManufacturingRowState = .active

    @AppStorage("manufacturingDisplayUnit") private var displayUnitRaw = ManufacturingDisplayUnit.millimeters.rawValue
    /// The user's saved materials (add-your-own-stock): named
    /// bundles of all 8 manufacturing fields, app-wide, across sessions.
    @State private var customMaterials: [CustomMaterial] = CustomMaterialStore.load()
    @State private var selectedCustomMaterialID: UUID?
    /// ID of the active built-in preset (BuiltInMaterialPreset.rawValue), or nil.
    @State private var selectedBuiltInPresetID: String?
    @State private var saveMaterialPromptVisible = false
    @State private var duplicatePromptVisible = false
    @State private var newMaterialName = ""

    private var displayUnit: ManufacturingDisplayUnit {
        ManufacturingDisplayUnit(rawValue: displayUnitRaw) ?? .millimeters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manufacturing Settings")
                .font(.headline)

            HStack {
                Text("Units")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Units", selection: $displayUnitRaw) {
                    ForEach(ManufacturingDisplayUnit.allCases) { unit in
                        Text(unit.label).tag(unit.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 92)
                .help("Show and enter the material thickness and sheet size in metric (mm) or English (inches). Values are stored exactly either way.")
            }

            HStack {
                Text("Material")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    // Legacy material presets (existing 5 enum cases)
                    ForEach(MaterialPreset.allCases) { preset in
                        Button {
                            applyLegacyPreset(preset)
                        } label: {
                            if preset == materialPreset
                                && activeCustomMaterial == nil
                                && selectedBuiltInPresetID == nil {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                    Divider()
                    // 14 built-in sheet presets (NEO-105)
                    ForEach(BuiltInMaterialPreset.allCases) { preset in
                        Button {
                            applyBuiltInPreset(preset)
                        } label: {
                            if selectedBuiltInPresetID == preset.rawValue
                                && activeCustomMaterial == nil {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                    if !customMaterials.isEmpty {
                        Divider()
                        ForEach(customMaterials) { material in
                            Button {
                                applyCustomMaterial(material)
                            } label: {
                                if material.id == activeCustomMaterial?.id {
                                    Label(material.name, systemImage: "checkmark")
                                } else {
                                    Text(material.name)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Save Current as Material\u{2026}") {
                        newMaterialName = ""
                        saveMaterialPromptVisible = true
                    }
                    // Duplicate the selected built-in or custom preset.
                    if let activeName = activeMaterialName {
                        Button("Duplicate \u{2018}\(activeName)\u{2019}\u{2026}") {
                            newMaterialName = "Copy of \(activeName)"
                            duplicatePromptVisible = true
                        }
                    }
                    if !customMaterials.isEmpty {
                        Menu("Remove Material") {
                            ForEach(customMaterials) { material in
                                Button(material.name, role: .destructive) {
                                    customMaterials.removeAll { $0.id == material.id }
                                    CustomMaterialStore.save(customMaterials)
                                    if selectedCustomMaterialID == material.id {
                                        selectedCustomMaterialID = nil
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(menuLabel)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .frame(minWidth: 100, maxWidth: 150)
                .alert("Save Material", isPresented: $saveMaterialPromptVisible) {
                    TextField("Name (e.g. Baltic Birch 6 mm)", text: $newMaterialName)
                    Button("Save") { saveCurrentAsMaterial() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Saves the current thickness, slot clearance, and sheet size as a reusable material.")
                }
                .alert("Duplicate Material", isPresented: $duplicatePromptVisible) {
                    TextField("Name", text: $newMaterialName)
                    Button("Duplicate") { saveCurrentAsMaterial() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Creates a new custom material from the current values.")
                }
                .help("Pick the material you plan to cut from — a preset like Letter fills in the right sheet size. Edit any value to switch to Custom.")
            }

            HStack {
                Text("Thickness")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Thickness", value: convertedField(editableThickness), format: .number.precision(.fractionLength(displayUnit.fieldPrecision)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text(displayUnit.label)
                    .foregroundStyle(.secondary)
            }
            .help("How thick your sheet material is. Slice spacing and slot widths are derived from it — measure your actual stock.")
            Slider(value: editableThickness, in: 0.5...25.0, step: 0.5)
                .help("Material thickness")

            // Slot Offset — the kerf. This IS the slot-geometry
            // field (slotWidth = thickness + this); the `kerf` mirror is kept
            // equal for JSON back-compat (NEO-116).
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if slotOffsetState.isShown {
                    sheetRow("Slot Offset", value: Binding(
                        get: { slotClearance },
                        set: { newValue in
                            slotClearance = newValue
                            kerf = newValue
                            materialPreset = .custom
                        }
                    ), help: "Slot Offset (kerf): the width your cutting tool removes, added to every slot so parts fit. Default 0.01\u{2033} = 0.254 mm. This drives the cut geometry; it is the same value as Slot Offset in Technique Settings.", state: slotOffsetState)
                }
                if toolDiameterState.isShown {
                    sheetRow("Tool Dia.", value: $toolDiameter, help: "Diameter of your cutter (router bit) in mm. It sizes the relief cut at the inside corners of slots and notches: Slot relief in Interlocked, Relief Type in Radial. 0 cuts no relief.", state: toolDiameterState)
                }
                sheetRow("Sheet W", value: $sheetWidth, help: "Width of one sheet of stock material. Cut parts are packed onto sheets of this size.")
                sheetRow("Sheet H", value: $sheetHeight, help: "Height of one sheet of stock material. Cut parts are packed onto sheets of this size.")
                sheetRow("Margin", value: $pageMargin, help: "The blank border kept round each sheet, where your cutter can't reach or the material is clamped. The same value as Margin in Export layout.")
            }
        }
    }

    // MARK: - Active material label helpers

    private var menuLabel: String {
        if let m = activeCustomMaterial { return m.name }
        if let id = selectedBuiltInPresetID,
           let preset = BuiltInMaterialPreset(rawValue: id) {
            return preset.label
        }
        return materialPreset.label
    }

    private var activeMaterialName: String? {
        if let m = activeCustomMaterial { return m.name }
        if let id = selectedBuiltInPresetID,
           let preset = BuiltInMaterialPreset(rawValue: id) {
            return preset.label
        }
        return nil
    }

    // MARK: - Apply presets

    private func applyLegacyPreset(_ preset: MaterialPreset) {
        materialPreset = preset
        selectedCustomMaterialID = nil
        selectedBuiltInPresetID = nil
        guard let values = preset.values else { return }
        materialThickness = values.thickness
        slotClearance = values.slotClearance
    }

    private func applyBuiltInPreset(_ preset: BuiltInMaterialPreset) {
        let m = preset.material
        materialPreset = .custom
        selectedCustomMaterialID = nil
        selectedBuiltInPresetID = preset.rawValue
        materialThickness = m.thickness
        // NEO-116: Slot Offset = kerf. Old built-in records stored
        // slotClearance 0 with the real value in kerf — fall back so they
        // still apply their offset.
        let offset = m.slotClearance > 0 ? m.slotClearance : m.kerf
        slotClearance = offset
        kerf = offset
        sheetWidth = m.sheetWidth
        sheetHeight = m.sheetHeight
        toolDiameter = m.toolDiameter
        // The packer has one page margin; a preset's margin sets it.
        pageMargin = m.horizontalMargin
    }

    /// The selected saved material, but only while the live values still
    /// match it — editing any field silently reverts the label to Custom,
    /// the same self-healing the built-in presets have.
    private var activeCustomMaterial: CustomMaterial? {
        guard let id = selectedCustomMaterialID,
              let material = customMaterials.first(where: { $0.id == id }),
              material.matches(
                thickness: materialThickness,
                slotClearance: slotClearance,
                sheetWidth: sheetWidth,
                sheetHeight: sheetHeight,
                kerf: kerf,
                toolDiameter: toolDiameter,
                pageMargin: pageMargin
              ) else { return nil }
        return material
    }

    private func applyCustomMaterial(_ material: CustomMaterial) {
        materialPreset = .custom
        selectedBuiltInPresetID = nil
        materialThickness = material.thickness
        // NEO-116: Slot Offset = kerf (see applyBuiltInPreset).
        let offset = material.slotClearance > 0 ? material.slotClearance : material.kerf
        slotClearance = offset
        kerf = offset
        sheetWidth = material.sheetWidth
        sheetHeight = material.sheetHeight
        toolDiameter = material.toolDiameter
        pageMargin = material.horizontalMargin
        selectedCustomMaterialID = material.id
    }

    private func saveCurrentAsMaterial() {
        let name = newMaterialName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var material = CustomMaterial(
            name: name,
            thickness: materialThickness,
            slotClearance: slotClearance,
            sheetWidth: sheetWidth,
            sheetHeight: sheetHeight,
            // NEO-116: kerf mirrors slotClearance (one field drives both).
            kerf: slotClearance,
            toolDiameter: toolDiameter,
            // The packer has one page margin; a material stores it in both.
            horizontalMargin: pageMargin,
            verticalMargin: pageMargin
        )
        // Saving again under an existing name is an edit, not a duplicate.
        if let existing = customMaterials.firstIndex(where: { $0.name == name }) {
            material.id = customMaterials[existing].id
            customMaterials[existing] = material
        } else {
            customMaterials.append(material)
        }
        CustomMaterialStore.save(customMaterials)
        selectedCustomMaterialID = material.id
        selectedBuiltInPresetID = nil
        materialPreset = .custom
    }

    private var editableThickness: Binding<Double> {
        Binding(
            get: { materialThickness },
            set: { value in
                materialThickness = value
                materialPreset = .custom
                selectedBuiltInPresetID = nil
            }
        )
    }

    /// Wrap a stored-mm binding so the text field shows/accepts the chosen
    /// display unit.
    private func convertedField(_ binding: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { binding.wrappedValue / displayUnit.millimetersPerUnit },
            set: { binding.wrappedValue = $0 * displayUnit.millimetersPerUnit }
        )
    }

    @ViewBuilder
    private func sheetRow(_ label: String, value: Binding<Double>, help: String, state: ManufacturingRowState = .active) -> some View {
        let enabled = state.isEnabled
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .opacity(enabled ? 1 : 0.5)
            TextField(label, value: convertedField(value), format: .number.precision(.fractionLength(displayUnit == .millimeters ? 2 : 3)))
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            Text(displayUnit.label)
                .foregroundStyle(.secondary)
                .opacity(enabled ? 1 : 0.5)
        }
        .help(help)
        if let caption = state.caption {
            // A short wrapping caption under the row; it takes the width the
            // rows give it and never widens the grid.
            GridRow {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridCellColumns(3)
                    .gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}

private struct ViewportAppearancePanel: View {
    @Binding var settings: ViewportAppearanceSettings
    @Binding var spaceMouseSmoothing: Double
    @Binding var spaceMouseSpeed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlGroup("Material") {
                Picker("Material", selection: $settings.material) {
                    ForEach(ViewportAppearanceSettings.ObjectMaterial.allCases) { material in
                        Text(material.label).tag(material)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("The model's surface finish (a MatCap style). Works in any colour.")

                ColorPicker("Object color", selection: colorBinding, supportsOpacity: false)
                    .font(.caption)
                HStack(spacing: 8) {
                    ForEach(Array(ViewportAppearanceSettings.quickColors.enumerated()), id: \.offset) { _, rgba in
                        Button {
                            settings.objectColor = rgba
                        } label: {
                            Circle()
                                .fill(rgba.color)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle().stroke(
                                        settings.objectColor == rgba ? Color.accentColor : Color.secondary.opacity(0.35),
                                        lineWidth: settings.objectColor == rgba ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                sliderRow("Edge lines", value: numericBinding(\.edgeStrength))
            }

            Divider()

            controlGroup("Slice lighting") {
                sliderRow("Key", value: numericBinding(\.keyLight))
                sliderRow("Fill", value: numericBinding(\.fillLight))
                sliderRow("Rim", value: numericBinding(\.rimLight))
            }
            .help("Lights the slice and panel solids. The imported model is MatCap-shaded.")

            Divider()

            controlGroup("Backdrop") {
                Picker("Backdrop", selection: $settings.backdrop) {
                    ForEach(ViewportAppearanceSettings.Backdrop.allCases) { backdrop in
                        Text(backdrop.label).tag(backdrop)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                sliderRow("Ground shadow", value: numericBinding(\.groundShadow))
                sliderRow("Vignette", value: numericBinding(\.vignette))
            }

            Divider()

            controlGroup("SpaceMouse") {
                sliderRow("Smoothing", value: $spaceMouseSmoothing)
                sliderRow("Speed", value: $spaceMouseSpeed)
            }
            .help("Smoothing blends 3D-mouse motion so a diagonal push moves smoothly instead of zippering between axes. Speed scales overall sensitivity (50% = normal).")

            Button {
                settings = .defaultLook
            } label: {
                Label("Reset to default", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reset the viewport look to the default.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { settings.objectColor.color },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                settings.objectColor = WorkspaceRGBA(
                    red: Double(ns.redComponent),
                    green: Double(ns.greenComponent),
                    blue: Double(ns.blueComponent)
                )
            }
        )
    }

    private func numericBinding(_ keyPath: WritableKeyPath<ViewportAppearanceSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = ViewportAppearanceSettings.clamped01($0) }
        )
    }

    @ViewBuilder
    private func controlGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(percent(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((ViewportAppearanceSettings.clamped01(value) * 100).rounded()))%"
    }
}

/// Object Size, owner-approved layout (2026-06-10): Uniform Scale is a toggle
/// (ON by default), "Original Size" became a Reset button, dimensions are
/// editable per axis when Uniform is off, and a Rotate row bakes a rotation
/// into the mesh before slicing.
private struct TransformPanel: View {
    @Binding var scale: Vec3
    @Binding var rotationDegrees: Vec3
    /// In-flight fine-rotation values while a slider is held; the viewport
    /// previews them as a pure transform, and `rotationDegrees` (plus the
    /// mesh re-bake it triggers) commits on release.
    @Binding var liveRotationPreview: Vec3?
    @Binding var importUnit: ImportUnitPreset
    @Binding var uniformScaleEnabled: Bool
    /// NEO-97: shows the Blender-style rotation rings in the viewport.
    @Binding var rotateInViewport: Bool
    /// RAW model dimensions in file units (scale NOT applied) — the absolute
    /// basis for the factor math, immune to commit-feedback compounding.
    let baseDimensions: MeshDimensions?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Object Size")
                .font(.headline)

            HStack {
                Text("Units")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Units", selection: $importUnit) {
                    ForEach(ImportUnitPreset.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 138)
                .help("The unit your model's size is shown and typed in.")
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                dimensionRow("Height", keyPath: \.height, axis: \.z, help: "How tall the finished model should be. With Uniform Scale on, the other dimensions follow; off, only the height changes.")
                dimensionRow("Width", keyPath: \.width, axis: \.x, help: "How wide the finished model should be. With Uniform Scale on, the other dimensions follow; off, only the width changes.")
                dimensionRow("Length", keyPath: \.depth, axis: \.y, help: "How long (deep) the finished model should be. With Uniform Scale on, the other dimensions follow; off, only the length changes.")
            }
            .disabled(baseDimensions == nil)

            HStack {
                Toggle("Uniform Scale", isOn: $uniformScaleEnabled)
                    .help("On: editing any dimension scales the whole model so the shape never distorts. Off: each dimension stretches independently.")
                Spacer()
                Button("Reset Size") {
                    scale = Vec3(x: 1, y: 1, z: 1)
                }
                .controlSize(.small)
                .disabled(scale.x == 1 && scale.y == 1 && scale.z == 1)
                .help("Back to the size the file came in at.")
            }

            HStack(spacing: 5) {
                Text("Rotate")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer()
                rotationButton("X", axis: \.x)
                rotationButton("Y", axis: \.y)
                rotationButton("Z", axis: \.z)
                Button {
                    rotationDegrees = Vec3(x: 0, y: 0, z: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(rotationDegrees.x == 0 && rotationDegrees.y == 0 && rotationDegrees.z == 0)
                .help("Reset rotation.")
            }

            // NEO-97: the Blender-style rotate gizmo — three axis-colored
            // rings around the model; drag to rotate live.
            Toggle("Rotate in viewport", isOn: $rotateInViewport)
                .help("Shows three rings around the model — red X, green Y, blue Z. Drag a ring to rotate the model about that axis: grabbing the ring snaps to 5°, grabbing its handle is freeform. The fields below show the exact angles.")

            // Fine rotation: drag or type any angle per axis (the quarter-turn
            // buttons above are the quick presets). "Like Blender" — fine-tune
            // the model's orientation, baked into the mesh before slicing.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                fineRotationRow("X", axis: \.x)
                fineRotationRow("Y", axis: \.y)
                fineRotationRow("Z", axis: \.z)
            }
        }
    }

    private func fineRotationRow(_ label: String, axis: WritableKeyPath<Vec3, Double>) -> some View {
        func normalized(_ value: Double) -> Double {
            var next = value.truncatingRemainder(dividingBy: 360)
            if next < 0 { next += 360 }
            return next
        }
        // Slider writes land in the live preview (viewport-only transform);
        // the rotation — and the mesh re-bake — commits once, on release.
        let live = Binding<Double>(
            get: { (liveRotationPreview ?? rotationDegrees)[keyPath: axis] },
            set: { newValue in
                var preview = liveRotationPreview ?? rotationDegrees
                preview[keyPath: axis] = normalized(newValue)
                liveRotationPreview = preview
            }
        )
        let typed = Binding<Double>(
            get: { rotationDegrees[keyPath: axis] },
            set: { rotationDegrees[keyPath: axis] = normalized($0) }
        )
        return GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            Slider(value: live, in: 0...360) { editing in
                if !editing, let preview = liveRotationPreview {
                    rotationDegrees = preview
                    liveRotationPreview = nil
                }
            }
            TextField(label, value: typed, format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
            Text("\u{00B0}")
                .foregroundStyle(.secondary)
        }
        .help("Fine-tune the model's orientation around \(label) — any angle, live while you drag. Slices, sheet, and exports follow when you let go.")
    }

    /// One click = a quarter turn about that axis (the practical case for
    /// reorienting a scan); the button shows the current total.
    private func rotationButton(_ label: String, axis: WritableKeyPath<Vec3, Double>) -> some View {
        let current = Int(rotationDegrees[keyPath: axis])
        return Button(current == 0 ? "\(label) 90°" : "\(label) \(current)°") {
            var next = rotationDegrees[keyPath: axis] + 90
            if next >= 360 { next -= 360 }
            rotationDegrees[keyPath: axis] = next
        }
        .controlSize(.small)
        .help("Rotate the model a quarter turn around \(label) before slicing — slices, sheet, and exports all follow. Click again for 180°, 270°, back to 0°.")
    }

    private func dimensionBinding(_ keyPath: KeyPath<MeshDimensions, Double>, axis: WritableKeyPath<Vec3, Double>) -> Binding<Double> {
        Binding(
            // Display = base size x scale, in the selected unit.
            get: { (baseDimensions?[keyPath: keyPath] ?? 0) * scale[keyPath: axis] },
            set: { targetInUnit in
                // ABSOLUTE factor from the base (unscaled) dimension. The old
                // multiplicative form compounded when SwiftUI re-committed the
                // field, slamming the scale to the 100x clamp (typing 2000
                // produced a 14,370 mm model).
                let base = baseDimensions?[keyPath: keyPath] ?? 0
                guard base > 0, targetInUnit.isFinite, targetInUnit > 0 else { return }
                let newFactor = MeshScaler.sanitizedFactor(targetInUnit / base)
                if uniformScaleEnabled {
                    scale = Vec3(x: newFactor, y: newFactor, z: newFactor)
                } else {
                    scale[keyPath: axis] = newFactor
                }
            }
        )
    }

    private func dimensionRow(_ label: String, keyPath: KeyPath<MeshDimensions, Double>, axis: WritableKeyPath<Vec3, Double>, help: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(label, value: dimensionBinding(keyPath, axis: axis), format: .number.precision(.fractionLength(2)))
                .help(help)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text(importUnit.label)
                .foregroundStyle(.secondary)
        }
    }
}

/// The dedicated Slice Direction panel: aims the cut direction
/// through the model. This is SEPARATE from Object Size's model rotation —
/// the model stays put; only the slicing planes reorient. Two angles off the
/// chosen axis cover an arbitrary direction; the X/Y/Z axis buttons (in
/// Construction) pick the base direction, these fine-tune it.
private struct SliceDirectionPanel: View {
    let directionAxis: SliceAxis
    @Binding var tiltFirst: Double
    @Binding var tiltSecond: Double
    /// In-flight values while a slider is held (x = first, y = second). The
    /// viewport previews these live; the bound tilt values commit on release.
    @Binding var livePreview: Vec2?
    @Binding var adjustInViewport: Bool

    var body: some View {
        let tiltAxes = SliceDirection.tiltAxes(for: directionAxis)
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Adjust in viewport", isOn: $adjustInViewport)
                .help("Shows protractor rings around the model: drag a handle to aim the slice direction; the swept angle reads out as you drag, and the exact value lives in the fields below.")

            Text("Aim the direction the slices cut through the model. The model itself doesn't move — only the cut planes tilt. 0 / 0 cuts straight along \(directionAxis.label).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            tiltControl(label: "Tilt toward \(tiltAxes.first.label)", keyPath: \.x, committed: $tiltFirst)
            tiltControl(label: "Tilt toward \(tiltAxes.second.label)", keyPath: \.y, committed: $tiltSecond)

            if tiltFirst != 0 || tiltSecond != 0 {
                HStack {
                    Spacer()
                    Button("Reset direction") {
                        tiltFirst = 0
                        tiltSecond = 0
                        livePreview = nil
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func tiltControl(label: String, keyPath: WritableKeyPath<Vec2, Double>, committed: Binding<Double>) -> some View {
        // While dragging, writes land in livePreview (viewport-only); the
        // committed value — and the re-slice it triggers — lands on release.
        let live = Binding<Double>(
            get: { livePreview?[keyPath: keyPath] ?? committed.wrappedValue },
            set: { newValue in
                var preview = livePreview ?? Vec2(x: tiltFirst, y: tiltSecond)
                preview[keyPath: keyPath] = newValue
                livePreview = preview
            }
        )
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Slider(value: live, in: -45...45) { editing in
                if !editing, let preview = livePreview {
                    committed.wrappedValue = preview[keyPath: keyPath]
                    livePreview = nil
                }
            }
            TextField(label, value: committed, format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
            Text("\u{00B0}")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConstructionTechniqueControl: View {
    let selection: ConstructionMode?
    let modes: [ConstructionMode]
    @Binding var isExpanded: Bool
    let onSelect: (ConstructionMode) -> Void

    var body: some View {
        if let selection, !isExpanded {
            SelectedTechniqueSummary(mode: selection) {
                isExpanded = true
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if selection != nil {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Choose a different technique.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Cancel") {
                            isExpanded = false
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                ConstructionTechniqueChooser(
                    selection: selection,
                    modes: modes,
                    onSelect: onSelect
                )
            }
        }
    }
}

private struct SelectedTechniqueSummary: View {
    let mode: ConstructionMode
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: mode.workflowSystemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mode.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if mode.isExperimental {
                        ExperimentalModeBadge()
                    }
                }
                Text(mode.compactWorkflowCue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button("Change", action: onChange)
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct ConstructionTechniqueChooser: View {
    let selection: ConstructionMode?
    let modes: [ConstructionMode]
    let onSelect: (ConstructionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick how this model becomes buildable parts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(modes) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    TechniqueChoiceCard(
                        mode: mode,
                        isSelected: selection == mode
                    )
                }
                .buttonStyle(.plain)
                .help(mode.workflowHelp)
            }
        }
    }
}

private struct TechniqueChoiceCard: View {
    let mode: ConstructionMode
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: mode.workflowSystemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mode.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if mode.isExperimental {
                        ExperimentalModeBadge()
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                Text(mode.workflowSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mode.workflowBestFor)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Marks a construction mode that is still in development (see
/// `ConstructionMode.isExperimental`).
private struct ExperimentalModeBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

private extension ConstructionMode {
    var workflowSystemImage: String {
        switch self {
        case .stacked:
            return "square.stack.3d.up"
        case .interlocked:
            return "grid"
        case .radial:
            return "circle.dotted"
        case .curve:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .foldedPanels:
            return "rectangle.connected.to.line.below"
        case .inflatables:
            return "seal"
        case .threeD:
            return "cube.transparent"
        case .structures:
            return "cube.transparent"
        case .partition:
            return "square.split.2x2"
        case .motherMold:
            return "shippingbox.and.arrow.backward"
        }
    }

    var workflowSummary: String {
        switch self {
        case .stacked:
            return "Parallel layers cut from sheet material and stacked into the object."
        case .interlocked:
            return "Two perpendicular families of slotted parts that lock together."
        case .radial:
            return "Rings and fins arranged around a center axis for rounded forms."
        case .curve:
            return "Straight and curved ribs that follow a path through the model."
        case .foldedPanels:
            return "A faceted net of panels, joints, and seams that folds into shape."
        case .inflatables:
            return "Flat membrane panels with seam allowance for sealed inflatable forms."
        case .threeD:
            return "Surface-following layers exported as a printable mesh, not flat parts."
        case .structures:
            return "A 3D-printer infill lattice clipped to the model's skin as one watertight mesh."
        case .partition:
            return "Splits an oversized model into bed-sized pieces that key back together for printing."
        case .motherMold:
            return "A multi-part casting mold with measured parting and demold checks."
        }
    }

    var compactWorkflowCue: String {
        switch self {
        case .stacked:
            return "Layered sheet build."
        case .interlocked:
            return "Slotted perpendicular ribs."
        case .radial:
            return "Rings and fins around an axis."
        case .curve:
            return "Ribs following a drawn path."
        case .foldedPanels:
            return "Foldable panel net."
        case .inflatables:
            return "Sealed membrane pattern."
        case .threeD:
            return "Surface-following mesh slices."
        case .structures:
            return "Skin-clipped infill lattice."
        case .partition:
            return "Split big models to fit the printer."
        case .motherMold:
            return "Multi-part casting mold."
        }
    }

    var workflowBestFor: String {
        switch self {
        case .stacked:
            return "Best when laminated layers are acceptable and alignment matters."
        case .interlocked:
            return "Best for self-supporting laser-cut structures."
        case .radial:
            return "Best for bowls, heads, vessels, and other rounded volumes."
        case .curve:
            return "Best for organic scans where ribs should follow a gesture line."
        case .foldedPanels:
            return "Best for low-poly paper, cardboard, or sheet-panel builds."
        case .inflatables:
            return "Best for taped or welded membrane prototypes from rigid sheet material."
        case .threeD:
            return "Best when the output should remain a 3D mesh."
        case .structures:
            return "Best for 3D-printed parts that need internal infill, not laser-cut sheets."
        case .partition:
            return "Best when the model is larger than your printer's build volume."
        case .motherMold:
            return "Best for casting copies of a watertight master in resin, plaster, or silicone."
        }
    }

    var workflowHelp: String {
        "\(workflowSummary) \(workflowBestFor)"
    }
}

private struct ConstructionPanel: View {
    @Binding var mode: ConstructionMode
    let plan: StackedSlicePlan?
    let interlockedPlan: InterlockedSlicePlan?
    let radialPlan: RadialSlicePlan?
    let curvePlan: CurveSlicePlan?
    let threeDPlan: ThreeDSlicePlan?
    let foldedPanelPlan: FoldedPanelPlan?
    @Binding var axis: SliceAxis
    @Binding var secondaryAxis: SliceAxis
    @Binding var materialThickness: Double
    @Binding var threeDSliceDepth: Double
    @Binding var slotClearance: Double
    @Binding var notchWidthOverrideEnabled: Bool
    @Binding var notchWidth: Double
    @Binding var slotAngleDegrees: Double
    @Binding var materialPreset: MaterialPreset
    @Binding var slotReliefEnabled: Bool
    /// Manufacturing Settings → Tool Dia., which sizes Interlocked Slot
    /// relief and Radial relief (shown here, set there).
    let toolDiameter: Double
    @Binding var radialSliceCount: Int
    @Binding var radialFirstAxisByDistance: Bool
    @Binding var radialFirstAxisCount: Int
    @Binding var radialFirstAxisSpacing: Double
    @Binding var radialNotchFactor: Double
    @Binding var radialReliefType: RadialReliefType
    @Binding var curvePrimaryAxis: SliceAxis
    @Binding var curveFirstAxisCount: Int
    @Binding var curveSliceCount: Int
    @Binding var curveAmplitude: Double
    @Binding var foldedDetailFaces: Int
    // NEO-104: folded joinery + Simplify Form + seams.
    @Binding var foldedJoinery: JoineryParameters
    @Binding var foldedSplitPanels: Bool
    @Binding var foldedSeamEdges: [FoldedSeamEdge]
    @Binding var foldedSeamEditMode: Bool
    @Binding var customSliceDistributionEnabled: Bool
    @Binding var customSliceCount: Int
    // NEO-103: slice distribution method + per-method fields.
    @Binding var sliceDistributionMethod: SliceDistributionMethod
    @Binding var sliceByDistanceSpacingMm: Double
    @Binding var customSlicePositions: [Double]
    // NEO-103: slice edit mode + selection + toolbar actions.
    @Binding var sliceEditMode3D: Bool
    @Binding var selectedSliceIndex: Int?
    var onAddSlice: (() -> Void)? = nil
    var onDeleteSlice: (() -> Void)? = nil
    var onDistributeEvenly: (() -> Void)? = nil
    var foldedPanelsUnavailableReason: String? = nil
    /// Whether every Folded net already fits in half the usable sheet, so
    /// Split Panels (which halves the extent) would change nothing.
    var foldedNetsFitHalfSheet = false
    /// What the Radial Slices cut sheet says about how its parts hold
    /// together: pieces left out, parts no joint locks in (shown blue),
    /// parts narrower than the stock (`CutSheetDocument.notes`).
    var radialSheetNotes: [String] = []
    /// What the Curve Slices cut sheet says about how its parts hold
    /// together (`CutSheetDocument.notes`).
    var curveSheetNotes: [String] = []
    /// What the Interlocked cut sheet says about its slot relief
    /// (`CutSheetDocument.notes`).
    var interlockedSheetNotes: [String] = []
    /// The axes Interlocked picks itself for this model, overriding Primary
    /// and Secondary; nil when the model's sides are about equal.
    var interlockedAutomaticAxes: (primary: SliceAxis, secondary: SliceAxis)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Interlocked lays its slices across the model's longest side and
            // uses the chosen axes only when the sides are about equal.
            let axesChosenByModel = mode == .interlocked ? interlockedAutomaticAxes : nil
            if mode == .stacked || mode == .interlocked {
                controlRow("Primary") {
                    Picker("Primary", selection: $axis) {
                        ForEach(SliceAxis.allCases) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .disabled(axesChosenByModel != nil)
                .opacity(axesChosenByModel == nil ? 1 : 0.5)
                .help("The direction the slices cut through your model. Changing it can fix errors, fit parts on the sheet, or simply look better.")
            }

            if mode == .interlocked {
                controlRow("Secondary") {
                    Picker("Secondary", selection: $secondaryAxis) {
                        ForEach(SliceAxis.allCases.filter { $0 != axis }) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .disabled(axesChosenByModel != nil)
                .opacity(axesChosenByModel == nil ? 1 : 0.5)
                .help("The direction of the second set of slices — the ones that slot crosswise into the first set to form the locking grid.")
                if let axesChosenByModel {
                    Text("Slices run across this model's longest side, on \(axesChosenByModel.primary.label) and \(axesChosenByModel.secondary.label). Primary and Secondary apply when its sides are about equal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }


            if mode == .radial {
                // Slice Distribution: Method dropdown, 1st Axis value (ring
                // count or spacing), Radial (Count).
                controlRow("Method") {
                    Picker("Method", selection: $radialFirstAxisByDistance) {
                        Text("By Count").tag(false)
                        Text("By Distance").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .help("How the rings along the first axis are distributed: an exact count, or a fixed spacing between rings.")
                if radialFirstAxisByDistance {
                    HStack {
                        Text("1st Axis")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("1st Axis", value: $radialFirstAxisSpacing, format: .number.precision(.fractionLength(3)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("mm")
                            .foregroundStyle(.secondary)
                    }
                    .help("Spacing between the rings along the first axis.")
                    Slider(value: $radialFirstAxisSpacing, in: 1.0...100.0, step: 0.5)
                } else {
                    Stepper(value: $radialFirstAxisCount, in: 1...72) {
                        HStack {
                            Text("1st Axis")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(radialFirstAxisCount)")
                                .monospacedDigit()
                        }
                    }
                    .help("How many rings to cut along the first axis. The radial fins notch into every ring they cross.")
                }
                if let note = radialPlan?.ringCountNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper(value: $radialSliceCount, in: 1...72) {
                    HStack {
                        Text("Radial (Count)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(radialSliceCount)")
                            .monospacedDigit()
                    }
                }
                .help("How many fins fan around the central axis. Each fin keys into the rings with half-lap notches.")
                // Ring notches and fin slots are always the material
                // thickness plus Slot Offset wide, so the parts fit each
                // other: Slot Offset is the one control for the fit. (The
                // Notch Factor older projects carry is read and kept, but
                // has no control: a factor that narrowed the notches would
                // stop the parts fitting.)
                kerfOffsetControls(label: "Slot Offset")
                // Radial joints are cut square: a ring and a fin slide
                // together along the whole notch, so a flared mouth would
                // only leave them loose there.
                Group {
                    HStack {
                        Text("Notch Angle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Notch Angle", value: $slotAngleDegrees, format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("deg")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $slotAngleDegrees, in: 0.0...60.0, step: 1.0)
                }
                .disabled(true)
                .opacity(0.5)
                .help("Radial notches are cut square so rings and fins fit snugly along their whole length. Use Slot Offset to loosen or tighten the joints.")
                Text("Radial notches are cut square, so Notch Angle does not apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Relief Type; the tool it is cut for is Tool Dia. in
                // Manufacturing Settings (the one tool diameter).
                controlRow("Relief Type") {
                    Picker("Relief Type", selection: $radialReliefType) {
                        ForEach(RadialReliefType.allCases) { relief in
                            Text(relief.label)
                                .tag(relief)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("For router bits, which round the inside corners of every notch and slot so the other part cannot seat fully. Square = sharp corners (laser or knife). Horizontal = a tool-sized circle at each inside corner, dug past the notch bottom. Vertical = dug into the notch sides. Dog Bone = dug in on the corner's diagonal. Horizontal/Vertical/Dog Bone are cut for Tool Dia. in Manufacturing Settings.")
                if radialReliefType.requiresToolDiameter {
                    toolDiameterNote(relief: "\(radialReliefType.label) relief")
                }
                if let note = radialPlan?.reliefNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(radialSheetNotes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if mode == .curve {
                controlRow("1st Axis") {
                    Picker("1st Axis", selection: $curvePrimaryAxis) {
                        ForEach(SliceAxis.allCases) { axis in
                            Text(axis.label).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Stepper(value: $curveFirstAxisCount, in: 1...72) {
                    HStack {
                        Text("1st Axis slices")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(curveFirstAxisCount)")
                            .monospacedDigit()
                    }
                }
                .help("How many straight slices to cut along the first axis. More slices add definition; fewer save material.")
                if let note = curvePlan?.firstAxisCountNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = curvePlan?.firstAxisMoveNote {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper(value: $curveSliceCount, in: 2...72) {
                    HStack {
                        Text("Curve slices")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(curveSliceCount)")
                            .monospacedDigit()
                    }
                }
                .help("How many rib slices to cut along the curve. More ribs follow the shape more closely.")
                if let note = curvePlan?.curveCountNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                kerfOffsetControls(label: "Slot Offset")
                    .disabled(notchWidthOverrideEnabled)
                    .opacity(notchWidthOverrideEnabled ? 0.5 : 1)
                if notchWidthOverrideEnabled {
                    Text(ManufacturingRows.notchWidthCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Notch width", isOn: $notchWidthOverrideEnabled)
                    .help("Override the width of the interlocking slots. Normally they match your material thickness automatically; turn this on only if you need them wider or narrower.")
                if notchWidthOverrideEnabled {
                    HStack {
                        Text("Width")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Notch width", value: editableNotchWidth, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("mm")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: editableNotchWidth, in: 0.1...50.0, step: 0.1)
                    if notchWidth < materialThickness {
                        Label("Narrower than the \(materialThickness.formatted(.number.precision(.fractionLength(0...2)))) mm stock: the parts will not fit into each other's slots.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text("Amplitude")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Amplitude", value: $curveAmplitude, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $curveAmplitude, in: -50.0...50.0, step: 0.5)
                if let curvePlan, abs(curveAmplitude) > abs(curvePlan.amplitude) + 0.001 {
                    Text("The curve bows at most \(abs(curvePlan.amplitude).formatted(.number.precision(.fractionLength(0...1)))) mm, the model's width along it; more has no effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(curveSheetNotes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if mode == .foldedPanels {
                if let foldedPanelsUnavailableReason {
                    Label(foldedPanelsUnavailableReason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    foldedJointTypeControls
                    Divider()
                    foldedSimplifyFormControls
                    Divider()
                    foldedSeamControls
                }
            } else {
                if mode == .threeD {
                    threeDSliceDepthControls
                    Text("3D Slices builds a layered mesh to print, so it has no Manufacturing Settings: stock, slots and sheets do not change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if mode == .stacked {
                    // NEO-103: Slice Distribution Method picker for stacked mode.
                    HStack {
                        Text("Method")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Method", selection: $sliceDistributionMethod) {
                            Text("Automatic").tag(SliceDistributionMethod.automatic)
                            Text("By Count").tag(SliceDistributionMethod.byCount)
                            Text("By Distance").tag(SliceDistributionMethod.byDistance)
                            Text("Custom").tag(SliceDistributionMethod.custom)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    .help("How slice planes are distributed. Automatic follows material thickness; By Count gives an exact number; By Distance spaces them evenly by mm; Custom lets you drag slices or edit the exact positions list.")

                    switch sliceDistributionMethod {
                    case .automatic:
                        EmptyView()
                    case .byCount:
                        Stepper(value: $customSliceCount, in: 1...240) {
                            HStack {
                                Text("Slices")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(customSliceCount)")
                                    .monospacedDigit()
                            }
                        }
                        .help("The exact number of slices to cut. Increase it for more definition; decrease it to save material.")
                    case .byDistance:
                        HStack {
                            Text("Spacing")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("Spacing", value: $sliceByDistanceSpacingMm, format: .number.precision(.fractionLength(2)))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        .help("Distance between consecutive slice planes. The number of slices = floor(model extent / spacing).")
                        Slider(value: $sliceByDistanceSpacingMm, in: 0.5...50.0, step: 0.5)
                    case .custom:
                        HStack {
                            Text("Positions")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(customSlicePositions.count) slice\(customSlicePositions.count == 1 ? "" : "s")")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .help("Custom positions set by dragging slices in the 3D view or using the Add/Delete toolbar below.")
                    }

                    // NEO-103: Slice Edit toolbar (visible whenever slices exist in stacked mode).
                    if let plan = plan, plan.sliceCount > 0 {
                        Divider()
                        Toggle(isOn: $sliceEditMode3D) {
                            Label("Edit Slices", systemImage: "pencil.and.ruler")
                        }
                        .toggleStyle(.button)
                        .help("Enable slice editing: click a slice to select it, then drag along the axis to move it.")

                        HStack(spacing: 6) {
                            Button {
                                onAddSlice?()
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Insert a new slice at the midpoint of the largest gap between existing slices.")
                            .disabled(plan.sliceCount >= 240)

                            Button {
                                onDeleteSlice?()
                            } label: {
                                Label("Delete", systemImage: "minus")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Remove the currently selected slice.")
                            .disabled(selectedSliceIndex == nil)

                            Spacer()

                            Button {
                                onDistributeEvenly?()
                            } label: {
                                Label("Distribute Evenly", systemImage: "distribute.horizontal.center")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                            }
                            .help("Reset all slices to a uniform distribution, clearing any custom positions.")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if mode == .interlocked || mode == .threeD {
                    // Interlocked and 3D keep the existing by-count control, driven by customSliceDistributionEnabled.
                    Toggle("Distribute count", isOn: $customSliceDistributionEnabled)
                        .help("Take manual control of how many slices are made instead of letting spacing follow the material thickness. More slices show more detail; fewer use less material.")
                    if customSliceDistributionEnabled {
                        Stepper(value: $customSliceCount, in: 1...240) {
                            HStack {
                                Text("Slices")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(customSliceCount)")
                                    .monospacedDigit()
                            }
                        }
                        .help("The exact number of slices to cut. Increase it for more definition; decrease it to save material.")
                    }
                }

                // Slot/notch/kerf controls are INTERLOCKED-only. 3D Slices is a
                // surface-preserving layered mesh — it has no slots, so a slot
                // offset / notch width / slot angle would be dead controls.
                if mode == .interlocked {
                    kerfOffsetControls(label: "Slot Offset")
                        .disabled(notchWidthOverrideEnabled)
                        .opacity(notchWidthOverrideEnabled ? 0.5 : 1)
                    if notchWidthOverrideEnabled {
                        Text(ManufacturingRows.notchWidthCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Notch width", isOn: $notchWidthOverrideEnabled)
                    .help("Override the width of the interlocking slots. Normally they match your material thickness automatically; turn this on only if you need them wider or narrower.")
                    if notchWidthOverrideEnabled {
                        HStack {
                            Text("Width")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("Notch width", value: editableNotchWidth, format: .number.precision(.fractionLength(2)))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: editableNotchWidth, in: 0.1...50.0, step: 0.1)
                    }

                    HStack {
                        Text("Slot angle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Slot angle", value: $slotAngleDegrees, format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("deg")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $slotAngleDegrees, in: 0.0...60.0, step: 1.0)

                    if mode == .interlocked {
                        Toggle("Slot relief", isOn: $slotReliefEnabled)
                            .help("Adds small round 'dog bone' cutouts at slot corners so slices can fully seat into one another — round cutting tools can't make sharp inside corners. Especially useful on CNC machines. The cutouts are cut for Tool Dia. in Manufacturing Settings.")
                        if slotReliefEnabled {
                            toolDiameterNote(relief: "Slot relief")
                            // Where the slots merge there is nothing to relieve.
                            if toolDiameter > 0 {
                                ForEach(interlockedSheetNotes, id: \.self) { note in
                                    Label(note, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                // Dowels moved to their own section (after Slice Direction) so
                // the cut direction is chosen before placing rods — see
                // DowelPanel / the sidebar order (owner decision, 2026-06-14).
            }

            // No plan-summary readout here: the technique panel has no
            // Count/Range/positions dump (removed 2026-06-09 after owner
            // feedback).
        }
    }

    private var materialControls: some View {
        Group {
            controlRow("Material") {
                Menu {
                    ForEach(MaterialPreset.allCases) { preset in
                        Button {
                            applyMaterialPreset(preset)
                        } label: {
                            if preset == materialPreset {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(materialPreset.label)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
            }

            HStack {
                Text("Thickness")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Thickness", value: editableMaterialThickness, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            Slider(value: editableMaterialThickness, in: 0.5...25.0, step: 0.5)
        }
    }

    private var threeDSliceDepthControls: some View {
        // "Distribute count" sets the layer count explicitly, which OVERRIDES the
        // slice-depth spacing — so when it's on, Slice depth is disabled (a dead
        // control that silently does nothing is exactly the inconsistency to
        // avoid).
        let overriddenByCount = customSliceDistributionEnabled
        return Group {
            HStack {
                Text("Slice depth")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Slice depth", value: editableThreeDSliceDepth, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            Slider(value: editableThreeDSliceDepth, in: 0.5...100.0, step: 0.5)
            if overriddenByCount {
                Text("Overridden by Distribute count below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(overriddenByCount)
        .opacity(overriddenByCount ? 0.5 : 1)
    }

    // MARK: - Folded Panels rail (NEO-104)

    /// Joint Type dropdown (menu order: Diamond default, Gear, Laced,
    /// Multitab, Puzzle, Rivet, Seam, Tab, Ticked, Tongue) + the selected
    /// type's parameter rows + Perforate.
    @ViewBuilder
    private var foldedJointTypeControls: some View {
        Text("Joint Type")
            .font(.subheadline.weight(.semibold))
        controlRow("Joint") {
            Menu {
                ForEach(JoineryType.menuOrder, id: \.self) { option in
                    Button {
                        // Selecting a type loads its built-in preset values.
                        foldedJoinery = .preset(for: option)
                    } label: {
                        if option == foldedJoinery.type {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(foldedJoinery.type.label)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
        }
        .help("How the panels join where the net is cut apart. The panel on one side is cut back so its stock rests on the other's inside face. Tab, Diamond, Tongue and Multitab pass through a slot in a lug on the other panel; Rivet's tab also takes a pin or rivet past the far face; Gear's fingers and Puzzle's round-headed neck pass through open notches; Laced cuts matching holes for a cord; Ticked notches both edges to line them up; None leaves plain edges to glue or tape.")

        if foldedJoinery.type == .trivial || foldedJoinery.type == .seam {
            Text("No joints: every cut edge stays a plain edge to glue or tape.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Joints go only where they fit: say how many cut edges got one, so
        // a joint type that fits few (or no) edges of this model is not a
        // silent no-op.
        if let census = foldedPanelPlan?.jointCensus {
            // Fewer faces make bigger panels with longer edges.
            let summary = census.summary(joint: foldedJoinery.type.label)
                + (census.tooShort > 0 ? " Lower Detail for longer edges." : "")
            if census.plain > 0 {
                Label(summary, systemImage: census.joined == 0 ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(census.joined == 0 ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // The stock can leave small panels out, or cut them back hard: say so.
        if let plan = foldedPanelPlan, let summary = plan.stockCensus.summary(thickness: plan.materialThickness) {
            Label(summary, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(plan.stockCensus.leftOut > 0 ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        foldedJointParameterRows

        Toggle("Perforate", isOn: $foldedJoinery.perforate)
            .help("Score fold lines as dashed perforation cuts (dash length follows the material thickness) instead of plain fold marks, so panels bend cleanly along each crease.")
    }

    /// The selected joint type's parameter rows: Diamond/Puzzle/Tab/Tongue →
    /// Tick Radius; Gear → Tooth Scale + Tick Space; Laced/Rivet → Hole
    /// Radius + Joint Space + Tick Radius; Multitab → Tab Fraction + Joint
    /// Space + Tick Radius; Ticked → Seam Radius + Tick Space; None → none.
    /// Every row changes the cut geometry.
    @ViewBuilder
    private var foldedJointParameterRows: some View {
        switch foldedJoinery.type {
        case .diamond, .puzzle, .tab, .tongue:
            foldedJoineryValueRow("Tick Radius", value: $foldedJoinery.tickRadius, range: 0.1...10.0, step: 0.05)
                .help("Sizes the joint: the tab (or tick, tongue, Puzzle head) is 4 × this wide, stands this far past the far face, and the lug keeps this much material round its slot.")
        case .gear:
            foldedJoineryFractionRow("Tooth Scale", value: $foldedJoinery.toothScale)
                .help("How far the fingers stand proud of the other panel's outside face, as a fraction of Tick Space (0.1 × 25.4 mm = 2.54 mm).")
            foldedJoineryValueRow("Tick Space", value: $foldedJoinery.tickSpace, range: 1.0...100.0, step: 0.5)
                .help("Finger pitch: one finger, half this wide, every Tick Space along the edge.")
        case .laced, .rivet:
            foldedJoineryValueRow("Hole Radius", value: $foldedJoinery.holeRadius, range: 0.1...10.0, step: 0.05)
                .help(foldedJoinery.type == .rivet ? "Radius of the pin or rivet hole in each tab." : "Radius of the lace holes.")
            foldedJoineryValueRow("Joint Space", value: $foldedJoinery.jointSpace, range: 1.0...100.0, step: 0.5)
                .help(foldedJoinery.type == .rivet ? "Distance between pinned tabs along an edge." : "Distance between lace holes along an edge.")
            foldedJoineryValueRow("Tick Radius", value: $foldedJoinery.tickRadius, range: 0.1...10.0, step: 0.05)
                .help("Material kept round each hole and slot.")
        case .multitab:
            foldedJoineryFractionRow("Tab Fraction", value: $foldedJoinery.tabFraction)
            foldedJoineryValueRow("Joint Space", value: $foldedJoinery.jointSpace, range: 1.0...100.0, step: 0.5)
            foldedJoineryValueRow("Tick Radius", value: $foldedJoinery.tickRadius, range: 0.1...10.0, step: 0.05)
        case .ticked:
            foldedJoineryValueRow("Seam Radius", value: $foldedJoinery.seamRadius, range: 0.1...10.0, step: 0.05)
                .help("Width and depth of each V-notch.")
            foldedJoineryValueRow("Tick Space", value: $foldedJoinery.tickSpace, range: 1.0...100.0, step: 0.5)
                .help("Distance between notches along an edge.")
        case .seam, .trivial:
            EmptyView()
        }
    }

    private func foldedJoineryValueRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        Group {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(label, value: value, format: .number.precision(.fractionLength(3)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func foldedJoineryFractionRow(
        _ label: String,
        value: Binding<Double>
    ) -> some View {
        Group {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
            }
            Slider(value: value, in: 0.01...1.0, step: 0.01)
        }
    }

    /// Simplify Form: editable Vertex Count, read-only Face Count, Split
    /// Panels — plus the Detail slider that drives the same simplification
    /// budget. A closed triangulated surface has faces ≈ 2 × vertices
    /// (Euler), which is how the two fields map onto one budget.
    @ViewBuilder
    private var foldedSimplifyFormControls: some View {
        Text("Simplify Form")
            .font(.subheadline.weight(.semibold))
        HStack {
            Text("Vertex Count")
                .foregroundStyle(.secondary)
            Spacer()
            TextField(
                "Vertex Count",
                value: Binding(
                    get: { max(foldedDetailFaces / 2, 6) },
                    set: { foldedDetailFaces = min(max($0 * 2, 12), 2000) }
                ),
                format: .number
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
        }
        .help("Adjust the vertex count to reduce the number of faces your imported model is represented by (faces ≈ 2 × vertices on a closed surface).")
        HStack {
            Text("Face Count")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(foldedDetailFaces)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("The face budget the simplified model targets — read-only; edit Vertex Count or the Detail slider.")
        Toggle("Split Panels", isOn: $foldedSplitPanels)
            .help("Split the unfolded shape into smaller panels (halves the usable sheet extent per net), so complex strips become simpler pieces.")
            .disabled(!foldedSplitPanels && foldedNetsFitHalfSheet)
        if !foldedSplitPanels && foldedNetsFitHalfSheet {
            Text("Every net already fits in half a sheet, so Split Panels would change nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Text("Detail")
                .foregroundStyle(.secondary)
            Spacer()
            TextField("Detail", value: $foldedDetailFaces, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text("faces")
                .foregroundStyle(.secondary)
        }
        Slider(
            value: Binding(
                get: { Double(foldedDetailFaces) },
                set: { foldedDetailFaces = Int($0.rounded()) }
            ),
            in: 12...2000,
            step: 1
        )
        .help("The polygon budget for the simplified shape folded panels are built from. Models denser than this are approximated first; each remaining face becomes a panel, so fewer faces means a simpler, easier build.")

        Text("Dense models are simplified to this face count before folding — the panels wrap a simplified shape around the object.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Add/Remove Seams: shows the seam count and lets the user clear them.
    /// (Seam edges force CUTS in the unfolded net; they are added by
    /// clicking mesh edges in the 3D view.)
    @ViewBuilder
    private var foldedSeamControls: some View {
        Text("Add/Remove Seams")
            .font(.subheadline.weight(.semibold))
        Toggle("Edit seams", isOn: $foldedSeamEditMode)
            .help("While on, click a panel edge of the folded preview in the 3D view to toggle a seam there. Seams force cuts, splitting large panels.")
        HStack {
            Text("Seams")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(foldedSeamEdges.count)")
                .monospacedDigit()
            Button("Clear") {
                foldedSeamEdges = []
            }
            .controlSize(.small)
            .disabled(foldedSeamEdges.isEmpty)
        }
        .help("Seams are mesh edges forced to become cuts, separating large panels into smaller ones. Clear removes every user-added seam.")
    }

    /// Where the relief's tool size comes from: Tool Dia. in Manufacturing
    /// Settings, or a warning when it is 0 and nothing is cut.
    @ViewBuilder
    private func toolDiameterNote(relief: String) -> some View {
        if toolDiameter > 0 {
            Text("\(relief) is cut for the \(toolDiameter.formatted(.number.precision(.fractionLength(0...3)))) mm Tool Dia. in Manufacturing Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Set Tool Dia. in Manufacturing Settings to cut \(relief).")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kerfOffsetControls(label: String) -> some View {
        Group {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(label, value: editableSlotClearance, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            .help("Extra room added to slots to make up for the material your cutter burns away. At 0, slots exactly equal the material thickness — often too tight. Increase it for breathing room on plywood; a snug fit is fine for cardboard. (Negative values make slots TIGHTER than the material and usually won't assemble — type one only if you know you need it.)")
            // Slider floor is 0: a small left-drag used to land on a negative
            // kerf, silently producing slots tighter than the material.
            // Negative values remain available by typing for special cases.
            Slider(value: editableSlotClearance, in: 0.0...8.0, step: 0.05)
                .help("Kerf offset")
        }
    }

    private var editableMaterialThickness: Binding<Double> {
        Binding(
            get: { materialThickness },
            set: { value in
                materialThickness = value
                materialPreset = .custom
            }
        )
    }

    private var editableThreeDSliceDepth: Binding<Double> {
        Binding(
            get: { threeDSliceDepth },
            set: { value in
                threeDSliceDepth = min(max(value, 0.5), 100.0)
            }
        )
    }

    private var editableSlotClearance: Binding<Double> {
        Binding(
            get: { slotClearance },
            set: { value in
                slotClearance = value
                materialPreset = .custom
            }
        )
    }

    private var editableNotchWidth: Binding<Double> {
        Binding(
            get: { notchWidth },
            set: { value in
                notchWidth = min(max(value, 0.1), 50.0)
                materialPreset = .custom
            }
        )
    }

    private func applyMaterialPreset(_ preset: MaterialPreset) {
        materialPreset = preset
        guard let values = preset.values else {
            return
        }
        materialThickness = values.thickness
        slotClearance = values.slotClearance
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }
}

/// Structures controls. Infill exposes pattern, density, cell size, and wall
/// thickness; Supports exposes sculpture-mode branch parameters while scaffold
/// mode remains gated with a hint. Every disabled control carries a hint, never
/// silently dead (owner rule). Generation is the explicit Generate action in the
/// rail below — this panel only edits parameters.
private struct StructuresPanel: View {
    @Binding var settings: StructureSettings

    private var cellSize: Binding<Double> {
        Binding(
            get: { settings.parameters.cellSizeMm },
            set: {
                settings.parameters.cellSizeMm = $0
                if settings.density.source == .uniform {
                    settings.density.minCellMm = $0
                    settings.density.maxCellMm = $0
                }
            }
        )
    }
    private var wallThickness: Binding<Double> {
        Binding(get: { settings.parameters.wallThicknessMm }, set: { settings.parameters.wallThicknessMm = $0 })
    }
    private var loftSlice: Binding<Double> {
        Binding(get: { settings.parameters.loftSliceMm }, set: { settings.parameters.loftSliceMm = $0 })
    }
    private var polishSurface: Binding<Bool> {
        Binding(get: { settings.parameters.polishSurface }, set: { settings.parameters.polishSurface = $0 })
    }
    private var densitySource: Binding<StructureDensitySource> {
        Binding(get: { settings.density.source }, set: { settings.density.source = $0 })
    }
    private var minCell: Binding<Double> {
        Binding(
            get: { settings.density.minCellMm },
            set: {
                settings.density.minCellMm = $0
                if settings.density.maxCellMm < $0 {
                    settings.density.maxCellMm = $0
                }
            }
        )
    }
    private var maxCell: Binding<Double> {
        Binding(
            get: { settings.density.maxCellMm },
            set: {
                settings.density.maxCellMm = $0
                if settings.density.minCellMm > $0 {
                    settings.density.minCellMm = $0
                }
            }
        )
    }
    private var imagePath: Binding<String> {
        Binding(
            get: { settings.density.imagePath ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.density.imagePath = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
    private var imageProjection: Binding<DensityImageProjection> {
        Binding(get: { settings.density.imageProjection }, set: { settings.density.imageProjection = $0 })
    }
    private var invertImage: Binding<Bool> {
        Binding(get: { settings.density.invertImage }, set: { settings.density.invertImage = $0 })
    }
    private var attractorPreset: Binding<StructureAttractorPreset> {
        Binding(get: { settings.density.attractorPreset }, set: { settings.density.attractorPreset = $0 })
    }
    private var falloff: Binding<Double> {
        Binding(get: { settings.density.falloffMm }, set: { settings.density.falloffMm = $0 })
    }
    private var nearSurfaceBand: Binding<Double> {
        Binding(get: { settings.density.nearSurfaceBandMm }, set: { settings.density.nearSurfaceBandMm = $0 })
    }
    private var customAttractorX: Binding<Double> {
        Binding(get: { settings.density.customAttractorPoint.x }, set: { settings.density.customAttractorPoint.x = $0 })
    }
    private var customAttractorY: Binding<Double> {
        Binding(get: { settings.density.customAttractorPoint.y }, set: { settings.density.customAttractorPoint.y = $0 })
    }
    private var customAttractorZ: Binding<Double> {
        Binding(get: { settings.density.customAttractorPoint.z }, set: { settings.density.customAttractorPoint.z = $0 })
    }
    private var supportMode: Binding<SupportMode> {
        Binding(get: { settings.support.supportMode }, set: { settings.support.supportMode = $0 })
    }
    private var supportTargetSurface: Binding<SupportTargetSurface> {
        Binding(get: { settings.support.targetSurface }, set: { settings.support.targetSurface = $0 })
    }
    private var supportSurfaceAngle: Binding<Double> {
        Binding(get: { settings.support.surfaceAngleDeg }, set: { settings.support.surfaceAngleDeg = $0 })
    }
    private var supportTipSpacing: Binding<Double> {
        Binding(get: { settings.support.tipSpacingMm }, set: { settings.support.tipSpacingMm = $0 })
    }
    private var supportTipDiameter: Binding<Double> {
        Binding(get: { settings.support.tipDiameterMm }, set: { settings.support.tipDiameterMm = $0 })
    }
    private var supportDiameterAngle: Binding<Double> {
        Binding(get: { settings.support.diameterAngleDeg }, set: { settings.support.diameterAngleDeg = $0 })
    }
    private var supportBranchDiameter: Binding<Double> {
        Binding(get: { settings.support.branchDiameterMm }, set: { settings.support.branchDiameterMm = $0 })
    }
    private var supportPreferredAngle: Binding<Double> {
        Binding(get: { settings.support.preferredAngleDeg }, set: { settings.support.preferredAngleDeg = $0 })
    }
    private var supportMaxAngle: Binding<Double> {
        Binding(get: { settings.support.maxAngleDeg }, set: { settings.support.maxAngleDeg = $0 })
    }
    private var supportStep: Binding<Double> {
        Binding(get: { settings.support.stepMm }, set: { settings.support.stepMm = $0 })
    }
    private var supportXYClearance: Binding<Double> {
        Binding(get: { settings.support.xyClearanceMm }, set: { settings.support.xyClearanceMm = $0 })
    }
    private var supportContactOffset: Binding<Double> {
        Binding(get: { settings.support.contactOffsetMm }, set: { settings.support.contactOffsetMm = $0 })
    }
    private var supportRestPreference: Binding<SupportRestPreference> {
        Binding(get: { settings.support.restPreference }, set: { settings.support.restPreference = $0 })
    }
    private var skinStyle: Binding<SkinStyle> {
        Binding(get: { settings.skin.skinStyle }, set: { settings.skin.skinStyle = $0 })
    }
    private var skinPattern: Binding<SkinPattern> {
        Binding(get: { settings.skin.skinPattern }, set: { settings.skin.skinPattern = $0 })
    }
    private var skinStrutDiameter: Binding<Double> {
        Binding(get: { settings.skin.strutDiameterMm }, set: { settings.skin.strutDiameterMm = $0 })
    }
    private var skinRibWidth: Binding<Double> {
        Binding(get: { settings.skin.ribWidthMm }, set: { settings.skin.ribWidthMm = $0 })
    }
    private var skinClip: Binding<SkinClip> {
        Binding(get: { settings.skin.skinClip }, set: { settings.skin.skinClip = $0 })
    }
    private var skinVariation: Binding<Double> {
        Binding(get: { settings.skin.variationPct }, set: { settings.skin.variationPct = $0 })
    }
    private var skinStrutVariation: Binding<Double> {
        Binding(get: { settings.skin.strutVariationPct }, set: { settings.skin.strutVariationPct = $0 })
    }
    private var supportVariation: Binding<Double> {
        Binding(get: { settings.support.variationPct }, set: { settings.support.variationPct = $0 })
    }
    private var patternSupportsDensity: Bool {
        settings.category == .skin || settings.pattern.supportsVariableDensity
    }
    private var variableDensityControlsEnabled: Bool {
        patternSupportsDensity && settings.density.source != .uniform && settings.density.source.isEngineBacked
    }
    private var imageControlsEnabled: Bool {
        variableDensityControlsEnabled && settings.density.source == .image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Structures")
                .font(.headline)

            controlRow("Type") {
                Picker("Type", selection: $settings.category) {
                    ForEach(StructureCategory.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .help("Infill fills the model interior. Supports grows standalone sculpture branches whose tips reform a chosen surface.")

            if settings.category == .infill {
                controlRow("Pattern") {
                    Picker("Pattern", selection: $settings.pattern) {
                        // Grouped by reference-chart family (Planar / Lattice /
                        // TPMS). A segmented picker can't hold all the patterns,
                        // so this is a menu picker with section headers.
                        ForEach(InfillPattern.Family.allCases) { family in
                            Section(family.label) {
                                ForEach(InfillPattern.patterns(in: family)) { pattern in
                                    Text(pattern.label + (pattern.isImplemented ? "" : " (soon)"))
                                        .tag(pattern)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("Choose an infill pattern from the reference chart. Planar patterns extrude 2D line families to full height; Lattice patterns build 3D strut networks; TPMS patterns mesh an implicit sheet field. Triangle is available now; the rest are landing pattern by pattern.")

                if !settings.pattern.isImplemented {
                    Label("The \(settings.pattern.label) pattern isn't implemented yet — choose Triangle to generate.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controlRow("Cell") {
                    HStack(spacing: 8) {
                        Slider(value: cellSize, in: 2...60)
                        Text(String(format: "%.1f mm", settings.parameters.cellSizeMm))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .help("Spacing between the lattice walls — smaller cells mean denser, stronger, heavier infill.")

                controlRow("Wall") {
                    HStack(spacing: 8) {
                        Slider(value: wallThickness, in: 0.4...6)
                        Text(String(format: "%.2f mm", settings.parameters.wallThicknessMm))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .help("Thickness of each wall — set it to a few nozzle widths so the lattice prints solidly.")

                densitySection

                if settings.pattern == .gyroidLofted {
                    controlRow("Slice") {
                        HStack(spacing: 8) {
                            Slider(value: loftSlice, in: 0.2...5.0, step: 0.1)
                            Text(String(format: "%.1f mm", settings.parameters.loftSliceMm))
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                    .help("Horizontal slice (layer) height of the Lofted gyroid — smaller = finer, less-stepped terraces, but slower to generate. Lofted only.")
                }

                if settings.pattern == .gyroidTiled || settings.pattern == .gyroidNetwork || settings.pattern == .gradedGyroid {
                    controlRow("Polish") {
                        HStack(spacing: 8) {
                            Toggle("", isOn: polishSurface)
                                .labelsHidden()
                                .toggleStyle(.switch)
                            Text("Smooth dimples")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .help("Feature-preserving cleanup that flattens the isolated triangular dimples marching cubes leaves on the smooth gyroid surface. The curves and sharp rail edges are kept. Turn off to compare. Marching-cubes gyroids only.")
                }
            } else if settings.category == .support {
                supportSection
            } else {
                skinSection
            }
        }
    }

    @ViewBuilder private var skinSection: some View {
        controlRow("Style") {
            Picker("Skin style", selection: skinStyle) {
                ForEach(SkinStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .help("Struts builds a hollow capsule network on the model surface. Perforated shells are a secondary M6 style.")

        controlRow("Pattern") {
            Picker("Skin pattern", selection: skinPattern) {
                ForEach(SkinPattern.allCases) { pattern in
                    Text(pattern.label).tag(pattern)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .help("Voronoi uses surface cell boundaries; Triangles connects adjacent cell seeds. Hex uses the Voronoi machinery in this pass.")

        controlRow("Cell") {
            HStack(spacing: 8) {
                Slider(value: cellSize, in: 2...60)
                Text(String(format: "%.1f mm", settings.parameters.cellSizeMm))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .help("Approximate surface cell spacing for skin seeds.")

        supportSlider("Strut", value: skinStrutDiameter, range: 0.5...10, suffix: "mm")
            .help("Diameter of the surface struts.")

        supportSlider("Variation", value: skinVariation, range: 0...1, suffix: "")
            .help("0 = regular, evenly sized cells; 1 = strongly varied organic cells (the Voronoi-helmet look). Seeded — regenerate with a different Seed for a new layout.")

        supportSlider("Strut Var", value: skinStrutVariation, range: 0...1, suffix: "")
            .help("Organic thickness: struts swell at junctions and drift thicker/thinner smoothly ALONG their length via a seeded field — never one whole strut fat and its neighbor thin.")

        controlRow("Clip") {
            Picker("Skin clip", selection: skinClip) {
                ForEach(SkinClip.allCases) { clip in
                    Text(clip.label).tag(clip)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .help("Struts straddle the surface by default. Inside keeps the embedded half (flush cage); Outside keeps the protruding half (jacket).")

        if settings.skin.skinStyle == .perforated {
            supportSlider("Rib", value: skinRibWidth, range: 0.5...10, suffix: "mm")
                .help("Rib width for perforated skin windows.")
            Label("Perforated shell generation is deferred in this build; use Struts for the M6 Crystallon-style skin.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        densitySection
    }

    @ViewBuilder private var supportSection: some View {
        controlRow("Mode") {
            Picker("Support mode", selection: supportMode) {
                ForEach(SupportMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .help("Sculpture mode makes standalone organic branches. Scaffold mode samples down-facing overhangs and avoids the model.")

        controlRow("Surface") {
            Picker("Target surface", selection: supportTargetSurface) {
                ForEach(SupportTargetSurface.allCases) { surface in
                    Text(surface.label).tag(surface)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .disabled(settings.support.supportMode == .scaffold)
        .help(settings.support.supportMode == .scaffold
              ? "Scaffold always targets down-facing overhangs; this picker applies to Sculpture mode."
              : "Choose which face normals receive branch tips.")

        supportSlider("Angle", value: supportSurfaceAngle, range: 5...89, suffix: "deg")
            .help("Minimum surface-normal angle threshold for target tips.")
        supportSlider("Tip Gap", value: supportTipSpacing, range: 1...50, suffix: "mm")
            .help("Poisson-style spacing between branch tips on the target surface.")
        supportSlider("Tip Dia", value: supportTipDiameter, range: 0.4...10, suffix: "mm")
            .help("Diameter of the pad touching the selected surface.")
        supportSlider("Branch", value: supportBranchDiameter, range: 0.4...40, suffix: "mm")
            .help("Maximum branch diameter after tapering and merging.")
        supportSlider("Taper", value: supportDiameterAngle, range: 0...15, suffix: "deg")
            .help("Thickness character: 0 = constant-diameter slender vines (joins stay thin, no root flare); high = trunk-building trees with flared feet.")
        supportSlider("Slope", value: supportPreferredAngle, range: 5...60, suffix: "deg")
            .help("Preferred branch growth angle from vertical.")
        supportSlider("Max", value: supportMaxAngle, range: 5...75, suffix: "deg")
            .help("Maximum branch angle from vertical — also the ceiling on how hard Wander can swing. Sculpture mode can go steep; printable scaffolds should stay ≤ 45-50.")
        supportSlider("Step", value: supportStep, range: 0.25...5, suffix: "mm")
            .help("Vertical growth layer step. Heavy jobs may coarsen this and report it.")
        supportSlider("Wander", value: supportVariation, range: 0...2, suffix: "")
            .help("0 = deterministic straight branches; 1 = strong snaking; above 1 the flow overpowers steering entirely (drama capped by Max — raise Max to let it swing harder). Same Seed reproduces the same forest.")

        if settings.support.supportMode == .scaffold {
            // Honesty: these two are persisted but NOT wired into the engine yet
            // (avoidance inflation + rest preference land with the avoidance
            // rework). Disabled-with-reason beats silently dead.
            supportSlider("Clear", value: supportXYClearance, range: 0.2...5, suffix: "mm")
                .disabled(true)
                .help("Not wired yet: avoidance currently tests branch centers against the uninflated model; clearance takes effect with the avoidance rework.")
            supportSlider("Contact", value: supportContactOffset, range: 0.05...2, suffix: "mm")
                .help("Surface gap between the overhang and the support tip pad.")
            controlRow("Rest") {
                Picker("Rest preference", selection: supportRestPreference) {
                    ForEach(SupportRestPreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(true)
            .help("Not wired yet: blocked or severed chains always rest on the model and are counted; the preference takes effect with the avoidance rework.")
        }
    }

    @ViewBuilder private var densitySection: some View {
        Divider()
        controlRow("Density") {
            Picker("Density", selection: densitySource) {
                ForEach(StructureDensitySource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .disabled(!patternSupportsDensity)
        .help(patternSupportsDensity ? "Choose how cell spacing is driven." : "\(settings.pattern.label) does not honor variable density yet.")

        if !patternSupportsDensity {
            densityReason("\(settings.pattern.label) does not honor variable density yet; saved non-uniform density falls back to Uniform.")
        } else if let notice = settings.sanitized.densityEngineNotice {
            densityReason(notice)
        }

        controlRow("Min Cell") {
            HStack(spacing: 8) {
                Slider(value: minCell, in: 1...200)
                    .disabled(!variableDensityControlsEnabled)
                Text(String(format: "%.1f mm", settings.density.source == .uniform ? settings.parameters.cellSizeMm : settings.density.minCellMm))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .help(variableDensityControlsEnabled ? "Smallest cell size used by the density field." : densityDisabledReason)

        controlRow("Max Cell") {
            HStack(spacing: 8) {
                Slider(value: maxCell, in: 1...200)
                    .disabled(!variableDensityControlsEnabled)
                Text(String(format: "%.1f mm", settings.density.source == .uniform ? settings.parameters.cellSizeMm : settings.density.maxCellMm))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .help(variableDensityControlsEnabled ? "Largest cell size used by the density field." : densityDisabledReason)

        if settings.density.source == .image {
            controlRow("Image") {
                HStack(spacing: 6) {
                    TextField("Path", text: imagePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!imageControlsEnabled)
                    Button {
                        chooseDensityImage()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!imageControlsEnabled)
                    .help("Choose density image")
                }
            }
            .help(imageControlsEnabled ? "Load a grayscale density image from disk." : densityDisabledReason)

            controlRow("Project") {
                Picker("Projection", selection: imageProjection) {
                    ForEach(DensityImageProjection.allCases) { projection in
                        Text(projection.label).tag(projection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!imageControlsEnabled)
            }
            .help(imageControlsEnabled ? "Project the image onto the model bounds." : densityDisabledReason)

            controlRow("Invert") {
                Toggle("", isOn: invertImage)
                    .labelsHidden()
                    .disabled(!imageControlsEnabled)
            }
            .help(imageControlsEnabled ? "Invert dark/light density mapping." : densityDisabledReason)

            if (settings.density.imagePath ?? "").isEmpty {
                densityReason("Choose an image before generating image-driven density.")
            }
        }

        if settings.density.source == .attractors {
            controlRow("Anchor") {
                Picker("Attractor", selection: attractorPreset) {
                    ForEach(StructureAttractorPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!variableDensityControlsEnabled)
            }
            .help(variableDensityControlsEnabled ? "Choose where the density is tightest." : densityDisabledReason)

            controlRow("Falloff") {
                HStack(spacing: 8) {
                    Slider(value: falloff, in: 5...500)
                        .disabled(!variableDensityControlsEnabled)
                    Text(String(format: "%.0f mm", settings.density.falloffMm))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .help(variableDensityControlsEnabled ? "Distance over which cells expand from min to max size." : densityDisabledReason)

            if settings.density.attractorPreset == .custom {
                controlRow("Point") {
                    HStack(spacing: 6) {
                        densityNumberField("X", customAttractorX)
                        densityNumberField("Y", customAttractorY)
                        densityNumberField("Z", customAttractorZ)
                    }
                }
                .help(variableDensityControlsEnabled ? "Custom attractor point in model coordinates." : densityDisabledReason)
            }
        }

        if settings.density.source == .nearSurface {
            controlRow("Band") {
                HStack(spacing: 8) {
                    Slider(value: nearSurfaceBand, in: 1...100)
                        .disabled(!variableDensityControlsEnabled)
                    Text(String(format: "%.0f mm", settings.density.nearSurfaceBandMm))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .help(variableDensityControlsEnabled ? "Distance from the model surface where cells stay smallest." : densityDisabledReason)
        }
    }

    private var densityDisabledReason: String {
        if !patternSupportsDensity {
            return settings.category == .skin
                ? "Skin honors variable density."
                : "\(settings.pattern.label) does not honor variable density yet."
        }
        if settings.density.source == .uniform {
            return "Uniform density uses the Cell value."
        }
        if !settings.density.source.isEngineBacked {
            return settings.sanitized.densityEngineNotice ?? "This density source is persisted but not engine-backed yet."
        }
        return "This control does not apply to the current density source."
    }

    private func densityReason(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDensityImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.density.imagePath = url.path
    }

    private func densityNumberField(_ label: String, _ value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 58)
            .disabled(!variableDensityControlsEnabled)
    }

    private func supportSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        controlRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                Text(String(format: "%.1f %@", value.wrappedValue, suffix))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }
}

private struct MotherMoldWorkflowPanel: View {
    let plan: MotherMoldPlan
    let settings: MotherMoldSettings
    @Binding var exploded: Bool
    @Binding var artistViewMode: MotherMoldArtistViewMode
    @Binding var visibleLayers: Set<MotherMoldPreviewLayer>

    private var steps: [MotherMoldWorkflow.Step] {
        MotherMoldWorkflow.steps(plan: plan, settings: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tooling view", selection: Binding(
                get: { artistViewMode },
                set: { mode in
                    artistViewMode = mode
                    applyViewPreset(mode)
                }
            )) {
                ForEach(MotherMoldArtistViewMode.allCases) { mode in
                    Text(mode.label).tag(mode).help(mode.help)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose a focused artist view. You can refine the visible tooling with Layers.")

            Menu {
                ForEach(MotherMoldPreviewLayer.allCases) { layer in
                    Toggle(layer.label, isOn: layerBinding(layer))
                        .help(layer.help)
                }
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
            }
            .help("Show or hide stable tooling layers. These controls affect only the viewport.")

            Toggle(isOn: $exploded) {
                Label("Inspect interior", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .toggleStyle(.button)
            .tint(exploded ? .accentColor : nil)
            .help(exploded
                ? "Press again to return all mold parts to the assembled position."
                : "Move the mold parts apart along their demold directions while leaving export geometry unchanged.")
            .accessibilityValue(exploded ? "On" : "Off")

            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(step.id)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.caption.weight(.semibold))
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func layerBinding(_ layer: MotherMoldPreviewLayer) -> Binding<Bool> {
        Binding(
            get: { visibleLayers.contains(layer) },
            set: { isVisible in
                if isVisible {
                    visibleLayers.insert(layer)
                } else {
                    visibleLayers.remove(layer)
                }
            }
        )
    }

    private func applyViewPreset(_ mode: MotherMoldArtistViewMode) {
        switch mode {
        case .master:
            visibleLayers = [.activeSource, .preparedMaster]
        case .mold:
            visibleLayers = [.moldParts, .mountHardware, .supportCradles, .flowPaths]
        case .assembly:
            var layers: Set<MotherMoldPreviewLayer> = [.preparedMaster, .moldParts, .mountHardware, .supportCradles, .flowPaths]
            layers.insert(plan.productionCastingPath.state == .geometryVerified ? .productionLiner : .asPouredLiner)
            visibleLayers = layers
        }
    }
}

private struct MotherMoldGoalChoiceCard: View {
    let goal: MotherMoldGoal
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: goal.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(goal.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                Text(goal.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Artist-facing MotherMold controls. The primary path stays compact and follows
/// Goal → Split → Shell → Build; less-frequent controls live in remembered
/// disclosures, while production-only capability remains available behind an
/// explicit Production tooling goal.
private struct MotherMoldPanel: View {
    @Binding var settings: MotherMoldSettings
    @Binding var placementTarget: MotherMoldSurfacePlacement.Target?
    /// The current (non-stale) plan, if any — drives the Fit/Warnings readout.
    var plan: MotherMoldPlan?
    var modelBounds: Bounds3D?
    var isBuilding: Bool
    var buildStage: MoldBuildStage?
    var buildStartedAt: Date?
    var buildDisabledReason: String?
    var status: MotherMoldUIContract.BuildStatusPresentation
    @Binding var buildDetailsExpanded: Bool
    var hasBuilt: Bool
    var build: () -> Void
    var cancelBuild: () -> Void
    var statusAction: (MotherMoldUIContract.RecoveryAction) -> Void

    @AppStorage("refabartist.motherMold.keysClampingExpanded") private var keysClampingExpanded = false
    @AppStorage("refabartist.motherMold.pourVentsExpanded") private var pourVentsExpanded = false
    @AppStorage("refabartist.motherMold.holdingMasterExpanded") private var holdingMasterExpanded = false
    @AppStorage("refabartist.motherMold.outputExpanded") private var outputExpanded = false

    private enum ManualPlaneAxis: String, CaseIterable, Identifiable {
        case x, y, z
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var vector: Vec3 {
            switch self {
            case .x: return Vec3(x: 1, y: 0, z: 0)
            case .y: return Vec3(x: 0, y: 1, z: 0)
            case .z: return Vec3(x: 0, y: 0, z: 1)
            }
        }
    }

    private var usesSiliconeGap: Bool { settings.subtype.usesSiliconeGap }
    private var showsSpoutControls: Bool {
        MotherMoldUIContract.showsSpoutControls(for: settings.subtype)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            goalSection
            Divider()
            splitSection
            Divider()
            shellSection
            Divider()
            buildSection

            if MotherMoldUIContract.showsProductionSections(for: settings) {
                Divider()
                masterReuseSection
            } else if MotherMoldUIContract.showsLegacyMountControls(for: settings) {
                Divider()
                DisclosureGroup(isExpanded: $holdingMasterExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        masterMountSection
                    }
                    .padding(.top, 6)
                } label: {
                    disclosureLabel("Holding the master")
                }
            }

            Divider()
            DisclosureGroup(isExpanded: $keysClampingExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    keysSection
                    Divider()
                    flangesSection
                }
                .padding(.top, 6)
            } label: {
                disclosureLabel("Keys & clamping")
            }

            Divider()
            DisclosureGroup(isExpanded: $pourVentsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    spoutSection
                }
                .padding(.top, 6)
            } label: {
                disclosureLabel("Pour & vents")
            }

            Divider()
            DisclosureGroup(isExpanded: $outputExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    outputSection
                }
                .padding(.top, 6)
            } label: {
                disclosureLabel("Output")
            }
        }
        // Fill the inspector rail width and left-align, so long hint/label text
        // wraps to the rail instead of expanding the panel and clipping.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { ensureManualPlanes() }
        .onChange(of: settings.parts) { _, _ in ensureManualPlanes() }
        .onChange(of: settings.subtype) { _, _ in enforceReusableToolingPackage() }
        .onChange(of: settings.toolingContractVersion) { _, _ in enforceReusableToolingPackage() }
    }

    // MARK: Goal

    @ViewBuilder private var goalSection: some View {
        sectionHeader("What are you making?")
        VStack(alignment: .leading, spacing: 7) {
            ForEach(MotherMoldGoal.allCases) { goal in
                Button {
                    settings = MotherMoldUIContract.applying(goal, to: settings)
                    placementTarget = nil
                    ensureManualPlanes()
                } label: {
                    MotherMoldGoalChoiceCard(
                        goal: goal,
                        isSelected: MotherMoldUIContract.goal(for: settings) == goal
                    )
                }
                .buttonStyle(.plain)
                .help(goal.help)
            }
        }
    }

    // MARK: Split

    @ViewBuilder private var splitSection: some View {
        sectionHeader("Split")
        controlRow("Parts") {
            // Short segment labels: the verbose enum labels ("2-part (one
            // parting plane)" …) blow a segmented control far wider than the
            // rail, which shoved the whole panel sideways and clipped every
            // label. The detail lives in the help tooltip instead.
            Picker("Parts", selection: $settings.parts) {
                Text("2-part")
                    .tag(MoldPartCount.two)
                    .help(MotherMoldHelp.option(MoldPartCount.two))
                Text("4-part")
                    .tag(MoldPartCount.four)
                    .help(MotherMoldHelp.option(MoldPartCount.four))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help(MotherMoldHelp.Field.parts.text)
        }
        .help(MotherMoldHelp.Field.parts.text)

        partingSection
    }

    // MARK: Shell

    @ViewBuilder private var shellSection: some View {
        sectionHeader("Shell")
        sliderRow("Wall", value: $settings.wallThickness, range: 2...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.wallThickness.text)

        if usesSiliconeGap {
            sliderRow("Silicone thickness", value: $settings.siliconeGap, range: 0.5...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.siliconeClearance.text)
            sliderRow("Detail softening", value: $settings.smoothing, range: 0...20, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.softening.text)
            Label(
                String(format: "Total cavity offset: %.1f mm", settings.siliconeGap + settings.smoothing),
                systemImage: "ruler"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(MotherMoldHelp.Field.totalCavityOffset.text)
        }

        Toggle("Flat floor", isOn: $settings.floor)
            .help(MotherMoldHelp.Field.flatFloor.text)
        sliderRow("Floor", value: $settings.floorThickness, range: 2...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.floorThickness.text)
            .disabled(!settings.floor)
            .opacity(settings.floor ? 1 : 0.45)
    }

    // MARK: Build

    @ViewBuilder private var buildSection: some View {
        sectionHeader("Build")
        VStack(alignment: .leading, spacing: 7) {
            Button(action: isBuilding ? cancelBuild : build) {
                HStack {
                    if isBuilding {
                        ProgressView().controlSize(.small)
                    }
                    Label(
                        MotherMoldUIContract.buildButtonLabel(
                            isBuilding: isBuilding,
                            hasBuilt: hasBuilt,
                            status: status
                        ),
                        systemImage: isBuilding ? "xmark.circle" : "shippingbox.and.arrow.backward"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isBuilding && buildDisabledReason != nil)
            .help(MotherMoldHelp.Field.buildButton.text)
            .accessibilityLabel(MotherMoldUIContract.buildButtonLabel(
                isBuilding: isBuilding,
                hasBuilt: hasBuilt,
                status: status
            ))

            if let reason = buildDisabledReason, reason != "Building…", status.kind != .needsRepair {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label(status.title, systemImage: statusIcon(status.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor(status.tone))
                if status.kind != .building {
                    Text(status.summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(status.details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            if isBuilding {
                let activeStage = buildStage ?? .preparingMaster
                let startedAt = buildStartedAt ?? Date()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MotherMoldBuildProgressPresentation.statusLine(
                        stage: activeStage,
                        elapsedSeconds: context.date.timeIntervalSince(startedAt)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

                if let action = status.action,
                   action != .buildMold,
                   action != .cancelBuild {
                    Button {
                        statusAction(action)
                    } label: {
                        recoveryLabel(action)
                    }
                    .buttonStyle(.bordered)
                }

                if status.kind == .readyToPrint, let plan {
                    readyPlanDetails(plan)
                }

                if !status.rawDetails.isEmpty {
                    DisclosureGroup("Build details", isExpanded: $buildDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(status.rawDetails.enumerated()), id: \.offset) { _, detail in
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 5)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusColor(status.tone).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor(status.tone).opacity(0.28), lineWidth: 1)
            )
        }
    }

    // MARK: Master Mount

    @ViewBuilder private var masterReuseSection: some View {
        sectionHeader("Master & Reuse")
        controlRow("Source") {
            Picker("Master source", selection: Binding(
                get: { settings.masterPreparation.sourceMode },
                set: { source in
                    settings.masterPreparation.sourceMode = source
                    if source == .preparedPrint {
                        settings.masterPreparation.retentionMode = .preparedPost
                    } else if settings.masterPreparation.retentionMode == .preparedPost {
                        settings.masterPreparation.retentionMode = .flatBaseSocket
                    }
                }
            )) {
                Text("Print prepared master").tag(MasterSourceMode.preparedPrint).help(MotherMoldHelp.option(MasterSourceMode.preparedPrint))
                Text("Existing physical master").tag(MasterSourceMode.existingPhysical).help(MotherMoldHelp.option(MasterSourceMode.existingPhysical))
            }
            .labelsHidden().pickerStyle(.menu).help(MotherMoldHelp.Field.masterSource.text)
        }
        .help(MotherMoldHelp.Field.masterSource.text)

        controlRow("Hold-down") {
            Picker("Retention", selection: $settings.masterPreparation.retentionMode) {
                if settings.masterPreparation.sourceMode == .preparedPrint {
                    Text("Keyed post + cross-pin").tag(MasterRetentionMode.preparedPost).help(MotherMoldHelp.option(MasterRetentionMode.preparedPost))
                } else {
                    Text("Generated socket").tag(MasterRetentionMode.flatBaseSocket).help(MotherMoldHelp.option(MasterRetentionMode.flatBaseSocket))
                    Text("External fixture").tag(MasterRetentionMode.externalFixture).help(MotherMoldHelp.option(MasterRetentionMode.externalFixture))
                }
            }
            .labelsHidden().pickerStyle(.menu).help(MotherMoldHelp.Field.retentionMode.text)
        }
        .help(MotherMoldHelp.Field.retentionMode.text)

        controlRow("Mount") {
            Picker("Mount placement", selection: Binding(
                get: { settings.masterPreparation.placementMode },
                set: { mode in
                    settings.masterPreparation.placementMode = mode
                    if mode == .manual {
                        placementTarget = .masterMount
                    } else if placementTarget == .masterMount {
                        placementTarget = nil
                    }
                }
            )) {
                Text("Auto").tag(MountPlacementMode.auto).help(MotherMoldHelp.option(MountPlacementMode.auto))
                Text(MotherMoldUIContract.manualMountPlacementLabel).tag(MountPlacementMode.manual).help(MotherMoldHelp.option(MountPlacementMode.manual))
            }
            .labelsHidden().pickerStyle(.segmented).help(MotherMoldHelp.Field.mountPlacement.text)
        }
        .help(MotherMoldHelp.Field.mountPlacement.text)

        if settings.masterPreparation.placementMode == .manual {
            placementButtons(
                target: .masterMount,
                pickLabel: settings.masterPreparation.manualPoint == nil ? "Pick on model" : "Pick again on model"
            )
            sliderRow("Mount X", value: manualPointBinding(\.x), range: coordinateRange(.x), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.manualMountPoint.text)
            sliderRow("Mount Y", value: manualPointBinding(\.y), range: coordinateRange(.y), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.manualMountPoint.text)
            sliderRow("Mount Z", value: manualPointBinding(\.z), range: coordinateRange(.z), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.manualMountPoint.text)
            if let axis = settings.masterPreparation.manualAxis {
                hint(String(format: "Surface direction: %.2f, %.2f, %.2f", axis.x, axis.y, axis.z))
            }
        }

        if settings.masterPreparation.retentionMode == .preparedPost {
            sliderRow("Post width", value: $settings.masterPreparation.postWidth, range: 1...100, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.postWidth.text)
            sliderRow("Post thick", value: $settings.masterPreparation.postThickness, range: 1...100, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.postThickness.text)
            sliderRow("Post length", value: $settings.masterPreparation.postFreeLength, range: 1...150, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.postLength.text)
            sliderRow("Cross-pin", value: $settings.masterPreparation.crossPinDiameter, range: 1...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.crossPin.text)
        }
        if settings.masterPreparation.retentionMode != .externalFixture {
            sliderRow("Fit", value: $settings.masterPreparation.fitClearance, range: 0...2, unit: "mm", format: "%.2f", help: MotherMoldHelp.Field.reuseFit.text)
            sliderRow("Seal land", value: $settings.masterPreparation.sealLandWidth, range: 1...50, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.sealLand.text)
        } else {
            hint("External fixture remains a shop responsibility. The package records it as unqualified until physical evidence is supplied.")
        }

        Divider()
        sectionHeader("Liner & Production")
        controlRow("Registration") {
            Picker("Liner registration", selection: $settings.linerRegistration.mode) {
                Text("Auto").tag(LinerRegistrationMode.automatic).help(MotherMoldHelp.option(LinerRegistrationMode.automatic))
                Text("Buttons").tag(LinerRegistrationMode.buttons).help(MotherMoldHelp.option(LinerRegistrationMode.buttons))
                Text("Buttons + lip").tag(LinerRegistrationMode.buttonsAndGateLip).help(MotherMoldHelp.option(LinerRegistrationMode.buttonsAndGateLip))
                Text("None").tag(LinerRegistrationMode.none).help(MotherMoldHelp.option(LinerRegistrationMode.none))
            }
            .labelsHidden().pickerStyle(.menu).help(MotherMoldHelp.Field.linerRegistration.text)
        }
        .help(MotherMoldHelp.Field.linerRegistration.text)
        if settings.linerRegistration.mode != .none {
            stepperRow("Buttons", value: $settings.linerRegistration.buttonsPerPart, range: 0...12, help: MotherMoldHelp.Field.linerButtons.text)
            sliderRow("Button Ø", value: $settings.linerRegistration.buttonDiameter, range: 1...50, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.linerButtonDiameter.text)
            sliderRow("Button depth", value: $settings.linerRegistration.buttonDepth, range: 0.5...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.linerButtonDepth.text)
            sliderRow("Button draft", value: $settings.linerRegistration.buttonDraftDegrees, range: 0...20, unit: "deg", format: "%.1f", help: MotherMoldHelp.Field.linerButtonDraft.text)
        }
        Toggle("Gate lip", isOn: $settings.linerRegistration.gateLipEnabled).help(MotherMoldHelp.Field.gateLip.text)
        if settings.linerRegistration.gateLipEnabled {
            sliderRow("Lip depth", value: $settings.linerRegistration.gateLipDepth, range: 0.5...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.gateLipDepth.text)
        }

        controlRow("Casting flow") {
            Menu {
                Button {
                    settings.productionFlow.mode = .automatic
                } label: {
                    Label(
                        "Auto gate + vents",
                        systemImage: settings.productionFlow.mode == .automatic ? "checkmark" : "circle"
                    )
                }
                .help(MotherMoldHelp.option(ProductionFlowMode.automatic))

                Button("Place manually") {}
                    .disabled(true)
                    .help(MotherMoldUIContract.manualProductionPlacementDisabledReason)
            } label: {
                Text(settings.productionFlow.mode == .automatic ? "Auto gate + vents" : "Place manually")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .help(MotherMoldHelp.Field.productionFlow.text)
            .accessibilityLabel("Production flow")
            .accessibilityValue(settings.productionFlow.mode == .automatic ? "Auto gate + vents" : "Place manually")
        }
        .help(MotherMoldHelp.Field.productionFlow.text)
        if settings.productionFlow.mode == .manual {
            hint(MotherMoldUIContract.manualProductionPlacementDisabledReason)
        }
        controlRow("Process") {
            Picker("Casting process", selection: $settings.productionFlow.processProfile) {
                Text("Gravity resin").tag(CastingProcessProfile.gravityResin).help(MotherMoldHelp.option(CastingProcessProfile.gravityResin))
                Text("Gravity plaster").tag(CastingProcessProfile.gravityPlaster).help(MotherMoldHelp.option(CastingProcessProfile.gravityPlaster))
                Text("Custom gravity").tag(CastingProcessProfile.customGravity).help(MotherMoldHelp.option(CastingProcessProfile.customGravity))
            }
            .labelsHidden().pickerStyle(.menu).help(MotherMoldHelp.Field.castingProcess.text)
        }
        .help(MotherMoldHelp.Field.castingProcess.text)
        sliderRow("Gate Ø", value: $settings.productionFlow.gateDiameter, range: 1...60, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.productionGate.text)
        sliderRow("Vent Ø", value: $settings.productionFlow.ventDiameter, range: 0.5...20, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.productionVent.text)

        controlRow("Supports") {
            Menu {
                Button {
                    settings.toolingSupport.mode = .automatic
                } label: {
                    Label(
                        "Auto",
                        systemImage: settings.toolingSupport.mode == .automatic ? "checkmark" : "circle"
                    )
                }
                .help(MotherMoldHelp.option(ToolingSupportMode.automatic))

                Button("Place manually") {}
                    .disabled(true)
                    .help(MotherMoldUIContract.manualProductionPlacementDisabledReason)
            } label: {
                Text(settings.toolingSupport.mode == .automatic ? "Auto" : "Place manually")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .help(MotherMoldHelp.Field.workingSupports.text)
            .accessibilityLabel("Working supports")
            .accessibilityValue(settings.toolingSupport.mode == .automatic ? "Auto" : "Place manually")
        }
        .help(MotherMoldHelp.Field.workingSupports.text)
        if settings.toolingSupport.mode == .manual {
            hint(MotherMoldUIContract.manualProductionPlacementDisabledReason)
        }
        sliderRow("Support margin", value: $settings.toolingSupport.minimumSupportMargin, range: 0...100, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.supportMargin.text)

        Divider()
        sectionHeader("Manufacturing profile")
        Toggle("Use profile reference", isOn: Binding(
            get: { settings.manufacturingProfile != nil },
            set: { enabled in
                settings.manufacturingProfile = enabled ? (settings.manufacturingProfile ?? ToolingManufacturingProfileRef()) : nil
            }
        ))
        .help(MotherMoldHelp.Field.manufacturingProfile.text)
        if settings.manufacturingProfile != nil {
            controlRow("Printer") {
                TextField("Printer profile", text: manufacturingProfileBinding(\.printerProfileID))
                    .textFieldStyle(.roundedBorder)
                    .help(MotherMoldHelp.Field.manufacturingProfile.text)
            }
            controlRow("Material") {
                TextField("Material profile", text: manufacturingProfileBinding(\.materialProfileID))
                    .textFieldStyle(.roundedBorder)
                    .help(MotherMoldHelp.Field.manufacturingProfile.text)
            }
            controlRow("Profile SHA") {
                TextField("Profile snapshot SHA-256", text: manufacturingProfileBinding(\.profileSnapshotSHA256))
                    .textFieldStyle(.roundedBorder)
                    .help(MotherMoldHelp.Field.manufacturingProfile.text)
            }
        }

        Divider()
        preparedMasterApprovalSection
    }

    @ViewBuilder private var preparedMasterApprovalSection: some View {
        sectionHeader("Prepared-master changes")
        if let plan {
            let summary = plan.masterPreparation
            let signature = summary.approvalSignature
            let isApproved = summary.state == .approved
            statusRow(icon: isApproved ? "checkmark.seal.fill" : "signature", title: isApproved ? "Approved" : "Approval required", detail: signature.map { "Plan signature \($0.prefix(12))" } ?? "No artist-surface change signature is required.", tint: isApproved ? .green : .orange)
            if plan.masterModificationRegions.isEmpty {
                hint("No art-surface change regions are proposed for this plan.")
            } else {
                ForEach(plan.masterModificationRegions) { region in
                    statusRow(icon: "scope", title: region.id, detail: String(format: "%@, %.1f mm2: %@", region.kind.rawValue, region.surfaceArea, region.purpose))
                }
            }
            if !isApproved, let signature, !plan.masterModificationRegions.isEmpty {
                Button {
                    statusAction(.approvePreparedMaster(signature))
                } label: {
                    Label("Approve prepared-master changes", systemImage: "signature")
                }
                .buttonStyle(.borderedProminent)
                .help("Approve exactly the displayed typed change regions and signature, then rebuild the prepared master. Any relevant plan change requires a new approval.")
            }
        } else {
            hint("Build the tooling to inspect the prepared-master change set before approval.")
        }
    }

    @ViewBuilder private var masterMountSection: some View {
        controlRow("Master holder") {
            Picker("Master holder", selection: $settings.masterMount.mode) {
                ForEach(MasterMountMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                        .help(MotherMoldHelp.option(mode))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help(MotherMoldHelp.Field.masterFixture.text)
        }
        .help(MotherMoldHelp.Field.masterFixture.text)
        if settings.masterMount.mode == .flatBaseSocket {
            sliderRow("Depth", value: $settings.masterMount.socketDepth, range: 1...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.socketDepth.text)
            sliderRow("Fit", value: $settings.masterMount.fitClearance, range: 0...2, unit: "mm", format: "%.2f", help: MotherMoldHelp.Field.socketFit.text)
            hint("The split socket locates the master. Apply compatible clay or reusable sealant around the seal land before pouring.")
        } else {
            Label("Provide an external support and seal its opening before pouring.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Parting

    @ViewBuilder private var partingSection: some View {
        controlRow("Mode") {
            Picker("Mode", selection: Binding(
                get: { settings.parting.mode },
                set: { newMode in
                    settings.parting.mode = newMode
                    ensureManualPlanes()
                }
            )) {
                Text("Auto").tag(PartingMode.auto)
                    .help(MotherMoldHelp.option(PartingMode.auto))
                Text("Manual").tag(PartingMode.manual)
                    .help(MotherMoldHelp.option(PartingMode.manual))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help(MotherMoldHelp.Field.partingMode.text)
        }
        .help(MotherMoldHelp.Field.partingMode.text)

        if settings.parting.mode == .manual {
            ForEach(0..<settings.parts.planeCount, id: \.self) { index in
                controlRow("Axis \(index + 1)") {
                    Picker("Plane \(index + 1) axis", selection: manualAxisBinding(index)) {
                        ForEach(availableManualAxes(index)) { axis in
                            Text(axis.label).tag(axis)
                                .help(MotherMoldHelp.axisOption(axis.label))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help(MotherMoldHelp.Field.partingAxis.text)
                }
                .help(MotherMoldHelp.Field.partingAxis.text)
                sliderRow(
                    "Offset \(index + 1)",
                    value: manualOffsetBinding(index),
                    range: manualOffsetRange(index),
                    unit: "mm",
                    format: "%.1f",
                    help: MotherMoldHelp.Field.partingOffset.text
                )
            }
        } else if settings.parts == .four {
            hint("Auto uses two orthogonal planes.")
        }
    }

    // MARK: Keys

    @ViewBuilder private var keysSection: some View {
        sectionHeader("Keys")
        controlRow("Type") {
            Picker("Key type", selection: $settings.key.type) {
                Text("None").tag(PartitionKeyType.none)
                    .help(MotherMoldHelp.option(PartitionKeyType.none))
                Text("Tapered round").tag(PartitionKeyType.pins)
                    .help(MotherMoldHelp.option(PartitionKeyType.pins))
                Text("Tapered bar").tag(PartitionKeyType.dovetail)
                    .help(MotherMoldHelp.option(PartitionKeyType.dovetail))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help(MotherMoldHelp.Field.keyType.text)
        }
        .help(MotherMoldHelp.Field.keyType.text)

        if settings.key.type != .none {
            sliderRow(settings.key.type == .pins ? "Key Ø" : "Bar size", value: $settings.key.pinDiameter, range: 2...30, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.keySize.text)
            sliderRow("Depth", value: $settings.key.pinLength, range: 2...40, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.keyDepth.text)
            sliderRow("Fit clearance", value: $settings.key.tolerance, range: 0...2, unit: "mm", format: "%.2f", help: MotherMoldHelp.Field.keyTolerance.text)
            stepperRow("Keys per seam", value: $settings.key.pinsPerSeam, range: 1...6, help: MotherMoldHelp.Field.keysPerSeam.text)
        } else {
            hint("None is a plain butt joint. Use another alignment method before clamping.")
        }
    }

    // MARK: Flanges & Clamping

    @ViewBuilder private var flangesSection: some View {
        sectionHeader("Flanges & Clamping")
        Toggle("Clamping rim", isOn: $settings.flange.enabled)
            .help(MotherMoldHelp.Field.matingFlange.text)

        if settings.flange.enabled {
            sliderRow("Width", value: $settings.flange.width, range: 2...60, unit: "mm", format: "%.0f", help: MotherMoldHelp.Field.flangeWidth.text)
            sliderRow("Thick", value: $settings.flange.thickness, range: 2...30, unit: "mm", format: "%.0f", help: MotherMoldHelp.Field.flangeThickness.text)
            stepperRow("Bolt holes", value: $settings.flange.boltHoleCount, range: 0...12, help: MotherMoldHelp.Field.boltCount.text)
            sliderRow("Bolt Ø", value: $settings.flange.boltDiameter, range: 1...16, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.boltDiameter.text)
                .disabled(settings.flange.boltHoleCount == 0)
                .opacity(settings.flange.boltHoleCount == 0 ? 0.45 : 1)
            if settings.flange.boltHoleCount == 0 {
                hint("Bolt diameter applies only when there is at least one bolt hole.")
            }
        } else {
            hint("Flange off — the parts have no clamping rim and must be banded or taped.")
        }
    }

    // MARK: Spout & Vents

    @ViewBuilder private var spoutSection: some View {
        if showsSpoutControls {
            controlRow("Pour hole") {
                Picker("Pour hole mode", selection: Binding(
                    get: { settings.spout.mode },
                    set: { newMode in
                        if newMode == .manual,
                           settings.spout.mode != .manual,
                           let seed = MotherMoldUIContract.manualSpoutSeed(for: modelBounds) {
                            settings.spout.manualSpoutX = seed.x
                            settings.spout.manualSpoutY = seed.y
                            settings.spout.manualSpoutZ = seed.z
                        }
                        settings.spout.mode = newMode
                        if newMode == .manual {
                            placementTarget = .pourHole
                        } else if placementTarget == .pourHole {
                            placementTarget = nil
                        }
                    }
                )) {
                    Text("Auto").tag(MoldSpoutMode.auto)
                        .help(MotherMoldHelp.option(MoldSpoutMode.auto))
                    Text("Manual").tag(MoldSpoutMode.manual)
                        .help(MotherMoldHelp.option(MoldSpoutMode.manual))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help(MotherMoldHelp.Field.spoutMode.text)
            }
            .help(MotherMoldHelp.Field.spoutMode.text)

            sliderRow("Pour hole Ø", value: $settings.spout.spoutDiameter, range: 2...40, unit: "mm", format: "%.0f", help: MotherMoldHelp.Field.spoutDiameter.text)
            if settings.spout.mode == .manual {
                placementButtons(target: .pourHole, pickLabel: "Pick again on model")
                sliderRow("Pour hole X", value: $settings.spout.manualSpoutX, range: coordinateRange(.x), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.spoutX.text)
                sliderRow("Pour hole Y", value: $settings.spout.manualSpoutY, range: coordinateRange(.y), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.spoutY.text)
                sliderRow("Pour hole Z", value: $settings.spout.manualSpoutZ, range: coordinateRange(.z), unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.spoutZ.text)
            }
        }

        stepperRow("Vents", value: $settings.spout.ventCount, range: 0...12, help: MotherMoldHelp.Field.ventCount.text)
        sliderRow("Vent Ø", value: $settings.spout.ventDiameter, range: 0.5...12, unit: "mm", format: "%.1f", help: MotherMoldHelp.Field.ventDiameter.text)
            .disabled(settings.spout.ventCount == 0)
            .opacity(settings.spout.ventCount == 0 ? 0.45 : 1)
        if settings.spout.ventCount == 0 {
            hint("Vent diameter applies only when there is at least one vent.")
        }
    }

    // MARK: Output

    @ViewBuilder private var outputSection: some View {
        if settings.usesReusableToolingContract {
            Label("Manufacturing ZIP required", systemImage: "shippingbox.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Prepared-master reusable tooling exports as one role-preserving manufacturing ZIP. Combined OBJ and laid-out STL are unavailable because they erase artifact roles.")
            Toggle("Reference meshes", isOn: $settings.includeReferenceMeshes)
                .help("Include reference-only source and liner meshes in the ZIP. These are not manufacturing parts.")
            if let plan {
                DisclosureGroup("Export contents") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(MotherMoldUIContract.exportArtifactPreview(for: plan)) { artifact in
                            statusRow(icon: "shippingbox", title: artifact.label, detail: artifact.detail)
                        }
                    }
                    .padding(.top, 4)
                }
                .help("Preview every manufacturing artifact, shop hardware item, and required document before exporting.")
            }
        } else {
            controlRow("Package") {
                Picker("Packaging", selection: $settings.packaging) {
                    ForEach(MoldPackaging.allCases) { packaging in
                        Text(packaging.label).tag(packaging)
                            .help(MotherMoldHelp.option(packaging))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help(MotherMoldHelp.Field.packaging.text)
            }
            .help(MotherMoldHelp.Field.packaging.text)
            Toggle("Assembly guide", isOn: $settings.includeAssemblyMap)
                .help(MotherMoldHelp.Field.assemblyGuide.text)
        }
    }

    // MARK: Build Status

    @ViewBuilder private func readyPlanDetails(_ plan: MotherMoldPlan) -> some View {
        statusRow(
            icon: "cube.fill",
            title: "\(plan.parts.count) printable part\(plan.parts.count == 1 ? "" : "s")",
            detail: "Final watertight and debris checks passed."
        )
        if settings.subtype == .siliconeJacket {
            if plan.masterMount.mode == .flatBaseSocket {
                statusRow(
                    icon: "pin.fill",
                    title: "Master locator verified",
                    detail: "Printed base socket retained; apply compatible sealant around its land before pouring."
                )
            } else {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Hold the model yourself",
                    detail: "Secure and liquid-seal the model with your own support before pouring.",
                    tint: .orange
                )
            }
        }
        statusRow(
            icon: "drop.fill",
            title: "Pour hole verified",
            detail: "The funnel and channel stay on one mold part."
        )
        if settings.spout.ventCount > 0 {
            statusRow(
                icon: plan.ventsBoredCount == settings.spout.ventCount ? "wind" : "exclamationmark.triangle.fill",
                title: "\(plan.ventsBoredCount) of \(settings.spout.ventCount) vents verified",
                detail: plan.ventsBoredCount == settings.spout.ventCount
                    ? "Requested air paths reached the cavity."
                    : "Inspect high points and add manual vents before casting.",
                tint: plan.ventsBoredCount == settings.spout.ventCount ? .secondary : .orange
            )
        }
        if settings.key.type != .none {
            statusRow(
                icon: "arrow.left.and.right",
                title: "\(plan.registrationKeysPlaced) tapered key pair\(plan.registrationKeysPlaced == 1 ? "" : "s")",
                detail: "Male and clearance-pocket geometry survived final validation."
            )
        }
        if settings.flange.enabled {
            let expectedBoltHoles = plan.flangedSeamCount * settings.flange.boltHoleCount
            statusRow(
                icon: "wrench.adjustable.fill",
                title: "\(plan.flangedSeamCount) clamping rim\(plan.flangedSeamCount == 1 ? "" : "s")",
                detail: expectedBoltHoles > 0
                    ? "\(plan.effectiveBoltHoleCount) of \(expectedBoltHoles) requested bolt holes survived."
                    : "Use clamps or straps; no bolt holes were requested.",
                tint: plan.effectiveBoltHoleCount == expectedBoltHoles ? .secondary : .orange
            )
        }
        if let material = materialEstimateText(plan) {
            Text(material)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if settings.usesReusableToolingContract {
            reusableToolingStatusRows(plan)
        }
    }

    private func statusIcon(_ kind: MotherMoldUIContract.BuildStatusKind) -> String {
        switch kind {
        case .needsRepair: return "wrench.and.screwdriver.fill"
        case .readyToBuild: return "hammer"
        case .building: return "hourglass"
        case .readyToPrint: return "checkmark.circle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func statusColor(_ tone: MotherMoldUIContract.BuildStatusTone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .orange: return .orange
        case .green: return .green
        case .red: return .red
        }
    }

    @ViewBuilder private func recoveryLabel(_ action: MotherMoldUIContract.RecoveryAction) -> some View {
        switch action {
        case .makeWatertight: Label("Choose how to make it watertight…", systemImage: "drop.fill")
        case .buildMold: Label("Build mold", systemImage: "shippingbox.and.arrow.backward")
        case .cancelBuild: Label("Cancel build", systemImage: "xmark.circle")
        case .useFewerOrSmallerKeys: Label("Use fewer/smaller keys", systemImage: "arrow.left.and.right")
        case .useExternalFixture: Label("Hold it myself", systemImage: "arrow.triangle.branch")
        case .placeSpoutManually: Label("Place pour hole manually", systemImage: "scope")
        case .approvePreparedMaster: Label("Approve prepared master", systemImage: "signature")
        case .reduceVents: Label("Use fewer or smaller vents", systemImage: "wind")
        case .disableClampingRim: Label("Turn off clamping rim", systemImage: "wrench.adjustable")
        case .useAutoParting: Label("Use Auto parting", systemImage: "wand.and.stars")
        case .useFewerParts: Label("Use fewer parts", systemImage: "square.split.2x1")
        case .reviewBuildDetails: Label("Review build details", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func statusRow(
        icon: String,
        title: String,
        detail: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func reusableToolingStatusRows(_ plan: MotherMoldPlan) -> some View {
        let regions = plan.masterModificationRegions
        statusRow(
            icon: plan.masterPreparation.state == .approved ? "checkmark.seal" : "signature",
            title: "Prepared master: \(plan.masterPreparation.state.rawValue)",
            detail: regions.isEmpty ? "No prepared-master art-surface regions." : "\(regions.count) typed change region\(regions.count == 1 ? "" : "s") across \(String(format: "%.1f", regions.reduce(0) { $0 + $1.surfaceArea })) mm2."
        )
        statusRow(
            icon: "pin.fill",
            title: "Master hold-down: \(plan.masterPreparation.retentionEvidence.rawValue)",
            detail: plan.masterPreparation.notes.first ?? "Hold-down evidence is recorded separately from export geometry."
        )
        statusRow(
            icon: "drop.fill",
            title: "Liner registration: \(plan.linerRegistration.state.rawValue)",
            detail: "\(plan.linerRegistration.sites.count) measured button site\(plan.linerRegistration.sites.count == 1 ? "" : "s"); gate lip \(plan.linerRegistration.gateLipEnabled ? "enabled" : "off")."
        )
        flowStatusRow(plan.linerFillPath, label: "Liner fill")
        flowStatusRow(plan.productionCastingPath, label: "Production casting")
        statusRow(
            icon: "square.3.layers.3d",
            title: "Working supports",
            detail: "Liner fill: \(plan.linerFillSupport.state.rawValue). Casting: \(plan.castingSupport.state.rawValue). \(plan.supportArtifacts.count) cradle artifact\(plan.supportArtifacts.count == 1 ? "" : "s")."
        )
    }

    private func flowStatusRow(_ path: MoldFlowPathSummary, label: String) -> some View {
        statusRow(
            icon: "arrow.triangle.branch",
            title: "\(label): \(path.state.rawValue)",
            detail: path.notes.first ?? "No artist-facing flow detail is available yet."
        )
    }

    private func readinessIcon(_ readiness: MotherMoldUIContract.PackageReadiness) -> String {
        switch readiness {
        case .blocked: return "xmark.octagon.fill"
        case .geometryOnly: return "exclamationmark.triangle.fill"
        case .printerValidated: return "checkmark.seal.fill"
        case .productionQualified: return "checkmark.shield.fill"
        }
    }

    private func readinessColor(_ readiness: MotherMoldUIContract.PackageReadiness) -> Color {
        switch readiness {
        case .blocked: return .red
        case .geometryOnly: return .orange
        case .printerValidated, .productionQualified: return .green
        }
    }

    private func icon(for severity: MoldDiagnosticSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for severity: MoldDiagnosticSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func materialEstimateText(_ plan: MotherMoldPlan) -> String? {
        guard plan.printedPlasticCC > 0 || plan.estimatedSiliconeCC != nil else { return nil }
        if let silicone = plan.estimatedSiliconeCC {
            return String(format: "Material: %.1f cc printed plastic, %.1f cc silicone.",
                          plan.printedPlasticCC, silicone)
        }
        return String(format: "Material: %.1f cc printed plastic.", plan.printedPlasticCC)
    }

    private func manualPointBinding(
        _ keyPath: WritableKeyPath<Vec3Codable, Double>
    ) -> Binding<Double> {
        Binding(
            get: { settings.masterPreparation.manualPoint?[keyPath: keyPath] ?? 0 },
            set: { value in
                var point = settings.masterPreparation.manualPoint ?? Vec3Codable()
                point[keyPath: keyPath] = value
                settings.masterPreparation.manualPoint = point
            }
        )
    }

    @ViewBuilder
    private func placementButtons(
        target: MotherMoldSurfacePlacement.Target,
        pickLabel: String
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                placementTarget = target
            } label: {
                Label(
                    placementTarget == target ? "Click the model…" : pickLabel,
                    systemImage: "scope"
                )
            }
            .buttonStyle(.bordered)
            .disabled(placementTarget == target)
            .help("Click a visible point on the model. Dragging still orbits; the sliders remain available for fine adjustment.")

            if placementTarget == target {
                Button("Cancel") {
                    placementTarget = nil
                }
                .buttonStyle(.borderless)
            }
        }
        if placementTarget == target {
            hint("Click the model surface to place it. A miss stays armed; drag to orbit without moving the point.")
        }
    }

    private func manufacturingProfileBinding(
        _ keyPath: WritableKeyPath<ToolingManufacturingProfileRef, String>
    ) -> Binding<String> {
        Binding(
            get: { settings.manufacturingProfile?[keyPath: keyPath] ?? "" },
            set: { value in
                var profile = settings.manufacturingProfile ?? ToolingManufacturingProfileRef()
                profile[keyPath: keyPath] = value
                settings.manufacturingProfile = profile
            }
        )
    }

    private func enforceReusableToolingPackage() {
        if settings.usesReusableToolingContract {
            settings.packaging = .manufacturingZip
        }
    }

    private func ensureManualPlanes() {
        guard settings.parting.mode == .manual else { return }
        let needed = settings.parts.planeCount
        var planes = Array(settings.parting.planes.prefix(needed))
        while planes.count < needed {
            let axis: ManualPlaneAxis = planes.isEmpty ? .x : .y
            planes.append(PartitionPlane(
                normal: axis.vector,
                offset: centerOffset(axis),
                isManual: true
            ))
        }
        settings.parting.planes = planes
    }

    private func manualAxisBinding(_ index: Int) -> Binding<ManualPlaneAxis> {
        Binding(
            get: {
                guard index < settings.parting.planes.count else { return index == 0 ? .x : .y }
                return manualAxis(settings.parting.planes[index])
            },
            set: { newAxis in
                ensureManualPlanes()
                guard index < settings.parting.planes.count else { return }
                settings.parting.planes[index] = PartitionPlane(
                    normal: newAxis.vector,
                    offset: centerOffset(newAxis),
                    isManual: true
                )
                if index == 0, settings.parting.planes.count > 1,
                   manualAxis(settings.parting.planes[1]) == newAxis {
                    let replacement = ManualPlaneAxis.allCases.first { $0 != newAxis } ?? .y
                    settings.parting.planes[1] = PartitionPlane(
                        normal: replacement.vector,
                        offset: centerOffset(replacement),
                        isManual: true
                    )
                }
            }
        )
    }

    private func manualOffsetBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard index < settings.parting.planes.count else { return 0 }
                return settings.parting.planes[index].offset
            },
            set: { value in
                ensureManualPlanes()
                guard index < settings.parting.planes.count else { return }
                let current = settings.parting.planes[index]
                settings.parting.planes[index] = PartitionPlane(
                    normal: current.normal,
                    offset: value,
                    isManual: true
                )
            }
        )
    }

    private func availableManualAxes(_ index: Int) -> [ManualPlaneAxis] {
        guard index > 0, !settings.parting.planes.isEmpty else { return ManualPlaneAxis.allCases }
        let first = manualAxis(settings.parting.planes[0])
        return ManualPlaneAxis.allCases.filter { $0 != first }
    }

    private func manualAxis(_ plane: PartitionPlane) -> ManualPlaneAxis {
        switch plane.axisAligned {
        case 1: return .y
        case 2: return .z
        default: return .x
        }
    }

    private func centerOffset(_ axis: ManualPlaneAxis) -> Double {
        guard let modelBounds else { return 0 }
        switch axis {
        case .x: return (modelBounds.min.x + modelBounds.max.x) / 2
        case .y: return (modelBounds.min.y + modelBounds.max.y) / 2
        case .z: return (modelBounds.min.z + modelBounds.max.z) / 2
        }
    }

    private func manualOffsetRange(_ index: Int) -> ClosedRange<Double> {
        let axis = index < settings.parting.planes.count
            ? manualAxis(settings.parting.planes[index])
            : (index == 0 ? ManualPlaneAxis.x : .y)
        guard let modelBounds else { return -100...100 }
        let range: ClosedRange<Double>
        switch axis {
        case .x: range = modelBounds.min.x...modelBounds.max.x
        case .y: range = modelBounds.min.y...modelBounds.max.y
        case .z: range = modelBounds.min.z...modelBounds.max.z
        }
        return range.lowerBound < range.upperBound ? range : (range.lowerBound - 1)...(range.upperBound + 1)
    }

    private func coordinateRange(_ axis: ManualPlaneAxis) -> ClosedRange<Double> {
        guard let modelBounds else { return -100...100 }
        let range: ClosedRange<Double>
        switch axis {
        case .x: range = modelBounds.min.x...modelBounds.max.x
        case .y: range = modelBounds.min.y...modelBounds.max.y
        case .z: range = modelBounds.min.z...modelBounds.max.z
        }
        return range.lowerBound < range.upperBound ? range : (range.lowerBound - 1)...(range.upperBound + 1)
    }

    // MARK: Row helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    private func disclosureLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String,
        format: String,
        help: String
    ) -> some View {
        controlRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                    .help(help)
                Text(String(format: "%@ %@", String(format: format, value.wrappedValue), unit))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                    .help(help)
            }
        }
        .help(help)
    }

    private func stepperRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        help: String
    ) -> some View {
        controlRow(label) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
            }
            .help(help)
        }
        .help(help)
    }
}

/// Dowels — its OWN pane, placed AFTER Slice Direction so
/// you choose how the model is cut before placing the rods that align the
/// stack (owner decision, 2026-06-14). Stacked mode only.
private struct DowelPanel: View {
    @Binding var dowelsEnabled: Bool
    @Binding var dowelDiameter: Double
    @Binding var dowelInset: Double
    @Binding var dowelShape: DowelShape
    @Binding var customDowelPositions: [Vec2]
    @Binding var dowelUseAutomatic: Bool
    @Binding var dowelAutomaticCount: Int
    @Binding var dowelEditMode3D: Bool
    @Binding var selectedDowelPlan: Vec2?
    /// ContentView supplies the optimizer's current rod layout (it needs the
    /// slice contours, which live up there).
    var automaticDowelPositions: () -> [Vec2] = { [] }

    private var dowelRodCountCaption: String {
        if dowelUseAutomatic {
            let n = automaticDowelPositions().count
            let rods = n == 1 ? "1 rod" : "\(n) rods"
            return "\(rods) placed automatically. Press Automatic to regenerate, or turn on Edit placement to drag, add, or delete them."
        }
        switch customDowelPositions.count {
        case 0:
            return "No rods — turn on Edit placement and click the light-blue plane to add one, or press Automatic."
        case 1:
            return "1 rod placed. Press Automatic to return to the automatic layout."
        default:
            return "\(customDowelPositions.count) rods placed. Press Automatic to return to the automatic layout."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Dowel holes", isOn: $dowelsEnabled)
                .help("Adds matching holes through every stacked slice so dowels can anchor them in place, keeping the layers aligned while you glue and assemble.")
            if dowelsEnabled {
                controlRow("Shape") {
                    Menu {
                        ForEach(DowelShape.allCases) { option in
                            Button {
                                dowelShape = option
                                dowelDiameter = option.defaultDiameter
                            } label: {
                                if option == dowelShape {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(dowelShape.label)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                }
                .help("The dowel rod's cross-section: Square, Pencil (hexagonal), Round, Cross, and flat Horizontal/Vertical Slots. Diameter is the overall size for every shape.")

                HStack {
                    Text("Diameter")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Diameter", value: $dowelDiameter, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $dowelDiameter, in: 1.0...20.0, step: 0.5)

                HStack {
                    Text("Inset")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Inset", value: $dowelInset, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $dowelInset, in: 1.0...40.0, step: 0.5)

                // "Automatic" is a BUTTON that regenerates the rods, not a
                // mode you get locked into.
                HStack(spacing: 8) {
                    Button {
                        customDowelPositions = automaticDowelPositions()
                        dowelUseAutomatic = false
                        selectedDowelPlan = nil
                        if !dowelEditMode3D { dowelEditMode3D = true }
                    } label: {
                        Label("Automatic", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Regenerates the dowels automatically: stands rods where they pass through the most slices, kept apart from each other and clear of slice edges. The result is ordinary markers — drag, add, or delete them afterwards.")
                    Stepper(value: $dowelAutomaticCount, in: 1...12) {
                        Text("\(dowelAutomaticCount)")
                            .monospacedDigit()
                    }
                    .help("How many rods Automatic stands. If the model can't fit that many with good spacing, the spacing relaxes.")
                }

                Text(dowelRodCountCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Edit placement", isOn: $dowelEditMode3D)
                    .onChange(of: dowelEditMode3D) {
                        if !dowelEditMode3D { selectedDowelPlan = nil }
                    }
                    .help("Dowel editing in the 3D view: click the light-blue plane to add a rod there, click a rod to select it (it turns orange), drag a rod to move it through the whole stack, and press Delete or Control-click to remove it. Clicks away from rods still orbit the camera.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }
}

private struct ExportLayoutPanel: View {
    @Binding var partSpacing: Double
    @Binding var pageMargin: Double
    @Binding var sheetWidth: Double
    @Binding var sheetHeight: Double
    let supportsSheetLayout: Bool
    let summary: ExportLayoutSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export layout")
                .font(.headline)

            HStack {
                Text("Spacing")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Spacing", value: $partSpacing, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            .help("The gap left between parts on the cut sheet, so cuts don't run into neighboring parts.")
            Slider(value: $partSpacing, in: 0.0...100.0, step: 0.5)

            HStack {
                Text("Margin")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Margin", value: $pageMargin, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            .help("The blank border kept around the edge of each sheet, where your cutter can't reach or the material is clamped.")
            Slider(value: $pageMargin, in: 0.0...100.0, step: 0.5)

            if supportsSheetLayout {
                controlRow("Stock") {
                    Menu {
                        ForEach(StockSheetPreset.allCases) { preset in
                            Button {
                                applyStockPreset(preset)
                            } label: {
                                if preset == selectedStockPreset {
                                    Label(preset.label, systemImage: "checkmark")
                                } else {
                                    Text(preset.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedStockPreset.label)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .help("Pick a standard sheet size — Letter, A4, 12 x 12 in, and more — and the sheet width and height fill in automatically.")
                }

                HStack {
                    Text("Sheet W")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Sheet width", value: $sheetWidth, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sheetWidth, in: 50.0...2400.0, step: 5.0)

                HStack {
                    Text("Sheet H")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Sheet height", value: $sheetHeight, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sheetHeight, in: 50.0...2400.0, step: 5.0)

                if let summary {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(summary.statusText, systemImage: summary.overflowsSheet ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(summary.overflowsSheet ? .orange : .secondary)
                        Text("\(summary.partCount) parts · \(summary.utilizationPercent)% used · \(summary.sheetText)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if summary.sheetCount > 1 {
                            Text(summary.sheetBreakdownText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var selectedStockPreset: StockSheetPreset {
        StockSheetPreset.matching(width: sheetWidth, height: sheetHeight)
    }

    private func applyStockPreset(_ preset: StockSheetPreset) {
        guard let size = preset.size else {
            return
        }
        sheetWidth = size.width
        sheetHeight = size.height
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }
}

private struct ExportLayoutSummary: Equatable {
    var partCount: Int
    var utilization: Double
    var sheetCount: Int
    var sheetPartCounts: [Int]
    var overflowsSheet: Bool

    init(document: CutSheetDocument) {
        self.partCount = document.partCount
        self.utilization = document.utilization
        self.sheetCount = document.sheets.count
        self.sheetPartCounts = document.sheetPartCounts
        self.overflowsSheet = document.overflowingPartCount > 0
    }

    var utilizationPercent: String {
        String(format: "%.1f", utilization * 100)
    }

    var statusText: String {
        overflowsSheet ? "Exceeds sheet" : "Fits sheet"
    }

    var sheetText: String {
        sheetCount == 1 ? "1 sheet" : "\(sheetCount) sheets"
    }

    var sheetBreakdownText: String {
        sheetPartCounts.enumerated()
            .map { index, count in "S\(index + 1): \(count)" }
            .joined(separator: " · ")
    }
}

private struct AssemblyStepsPanel: View {
    let steps: [AssemblyStep]
    @Binding var selectedStepID: AssemblyStep.ID?
    @Binding var renderStyle: SliceSolidRenderStyle
    let exportAction: () -> Void
    var document: CutSheetDocument?

    /// Controls whether the Assembly Reference sheet viewer popover is shown.
    @State private var showingReferenceSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Assembly")
                    .font(.headline)
                Spacer()
                Text("\(steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Material render picker — Cardboard / Plywood / Plastic.
            Picker("Material", selection: $renderStyle) {
                ForEach(SliceSolidRenderStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .help("Changes the slice-solid render style in the 3D viewport")
            .accessibilityLabel("Slice material render style")

            if steps.isEmpty {
                Text("No assembly steps available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    AccessibleIconButton(
                        systemImage: "chevron.left",
                        accessibility: WorkspaceAccessibilityContent.previousAssemblyStep,
                        action: {
                            selectedStepID = AssemblyStepNavigation.previousSelection(before: selectedStepID, steps: steps)
                        }
                    )
                    .help("Previous assembly step")

                    Text(AssemblyStepNavigation.displayText(selectedStepID: selectedStepID, steps: steps))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 40)

                    AccessibleIconButton(
                        systemImage: "chevron.right",
                        accessibility: WorkspaceAccessibilityContent.nextAssemblyStep,
                        action: {
                            selectedStepID = AssemblyStepNavigation.nextSelection(after: selectedStepID, steps: steps)
                        }
                    )
                    .help("Next assembly step")

                    Spacer()

                    // Assembly Reference button: opens the sheet thumbnail
                    // viewer. Only active when a cut-sheet document is
                    // available.
                    if document != nil {
                        AccessibleIconButton(
                            systemImage: "doc.richtext",
                            accessibility: WorkspaceAccessibilityContent.showAssemblyReference,
                            action: { showingReferenceSheet = true }
                        )
                        .help("Assembly Reference — view cut sheets")
                        .popover(isPresented: $showingReferenceSheet, arrowEdge: .trailing) {
                            AssemblyReferenceViewer(
                                document: document,
                                selectedStepID: selectedStepID,
                                onSelectStep: { stepID in selectedStepID = stepID },
                                onClose: { showingReferenceSheet = false }
                            )
                            .frame(minWidth: 420, minHeight: 360, maxHeight: 640)
                        }
                    }

                    AccessibleIconButton(
                        systemImage: "doc.text",
                        accessibility: WorkspaceAccessibilityContent.exportAssemblyGuide,
                        action: exportAction
                    )
                    .help("Export assembly guide")

                    AccessibleIconButton(
                        systemImage: "xmark",
                        accessibility: WorkspaceAccessibilityContent.clearAssemblyHighlight,
                        action: { selectedStepID = nil }
                    )
                    .disabled(selectedStepID == nil)
                    .help("Clear assembly highlight")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // One line that names the PART (the label engraved on the cut
                // sheet) and where to find it — what you actually need at the
                // bench. The old 33-row "Place slice_001 / Stack along Z at
                // 52.68 mm" list told a human nothing the build order didn't.
                Text(currentStepSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var currentStepSummary: String {
        guard let selectedStepID,
              let index = steps.firstIndex(where: { $0.id == selectedStepID }) else {
            return "Step through with the arrows — the 3D view shows the build growing piece by piece."
        }
        let stepIndex = steps[index].id
        if let document {
            let parts = document.sheets
                .enumerated()
                .flatMap { sheetNumber, sheet in
                    sheet.parts.filter { $0.stepIndex == stepIndex }.map { (sheetNumber + 1, $0.label) }
                }
            if !parts.isEmpty {
                let names = parts.map { "part \($0.1) (sheet \($0.0))" }.joined(separator: ", ")
                return "Place \(names)."
            }
        }
        return steps[index].title
    }
}

/// A 2D sheet viewer opened from the Assembly Reference button: shows the
/// cut-sheet pages as thumbnails with pan/zoom/fit, and highlights the sheet
/// containing the currently selected assembly step's part.
///
/// Sheet–step highlight: `CutSheetDocument.Part.stepIndex` carries the
/// assembly step index and is available on every part. This viewer highlights
/// the SHEET containing the current step's part by drawing an accent border
/// around matching parts (same approach as `ExportSheetPreview`).
private struct AssemblyReferenceViewer: View {
    var document: CutSheetDocument?
    var selectedStepID: AssemblyStep.ID?
    var onSelectStep: (AssemblyStep.ID) -> Void
    var onClose: () -> Void

    @State private var zoom = 1.0
    @State private var renderModel: CutSheetRenderModel?

    private var model: CutSheetRenderModel? {
        guard let document else { return nil }
        if let renderModel, renderModel.revision == document.revision {
            return renderModel
        }
        return CutSheetRenderModel(document: document)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: title, zoom controls, fit, close.
            HStack(spacing: 8) {
                Text("Assembly Reference")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                zoomControls
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Assembly Reference")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let model {
                GeometryReader { geometry in
                    let fitScale = model.fittedScale(in: geometry.size)
                    let scale = fitScale * zoom
                    let canvasSize = CGSize(
                        width: model.size.width * scale + CutSheetRenderModel.contentPadding * 2,
                        height: model.size.height * scale + CutSheetRenderModel.contentPadding * 2
                    )

                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            CutSheetCanvas(
                                model: model,
                                selectedStepIndex: selectedStepID,
                                scale: scale
                            )
                            CutSheetHitTargets(model: model, scale: scale) { stepIndex in
                                onSelectStep(stepIndex)
                            }
                        }
                        .frame(
                            width: max(canvasSize.width, geometry.size.width),
                            height: max(canvasSize.height, geometry.size.height)
                        )
                    }
                    .background(CutSheetPalette.canvas)
                }
                .onAppear { renderModel = model }
                .onChange(of: document?.revision) { _, _ in
                    if let doc = document {
                        renderModel = CutSheetRenderModel(document: doc)
                    }
                }
            } else {
                Text("No cut sheets available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CutSheetPalette.canvas)
            }
        }
        .accessibilityLabel("Assembly Reference")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
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
    }
}

/// Everything the Folded Panels planner reads, and a key that names it.
struct FoldedPlanRequest {
    var model: MeshSummary
    var joinery: JoineryParameters
    var materialThickness: Double
    var slotClearance: Double
    var maxNetExtent: Vec2
    var seamEdges: [FoldedSeamEdge]

    var modelKey: String {
        ViewportGeometryCache.modelKey(for: model)
    }

    var key: String {
        func number(_ value: Double) -> String { String(format: "%.6f", value) }
        let joint = (try? String(data: JSONEncoder.sortedKeys.encode(joinery), encoding: .utf8)) ?? joinery.type.rawValue
        let seams = seamEdges.map { "\(number($0.a.x)),\(number($0.a.y)),\(number($0.a.z)),\(number($0.b.x)),\(number($0.b.y)),\(number($0.b.z))" }
            .joined(separator: ";")
        return [modelKey, joint, number(materialThickness), number(slotClearance), number(maxNetExtent.x), number(maxNetExtent.y), seams]
            .joined(separator: "|")
    }

    func plan() -> FoldedPanelPlan {
        FoldedPanelPlanner.plan(
            model: model,
            joinery: joinery,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            maxNetExtent: maxNetExtent,
            seamEdges: seamEdges
        )
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
