import AppKit
import RealityKit
import simd
import SwiftUI

struct ModelSceneView: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: MeshSummary?
    /// The model in the SLICING frame (the Slice Direction pre-rotation), used
    /// to build the slice solids. Defaults to `model`. When it differs (an
    /// active slice-direction tilt), the slice solids are counter-rotated by
    /// `sliceFrameRotationDegrees` so they sit on the un-rotated `model` — the
    /// model stays put, only the cut planes tilt.
    var sliceFrameModel: MeshSummary? = nil
    var sliceFrameRotationDegrees: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// Live drag previews: while a rotation/tilt slider is held, these carry
    /// the in-flight values and the scene applies them as pure entity
    /// TRANSFORMS each update pass — no mesh re-bake, no re-slice, no scene
    /// rebuild. The authoritative state commits once, on drag end.
    var bakedModelRotationDegrees: Vec3 = Vec3(x: 0, y: 0, z: 0)
    var liveModelRotationPreviewDegrees: Vec3? = nil
    var liveSliceTiltPreviewDegrees: Vec3? = nil
    /// MeshScaler's rotation fixed point: the RAW model's bounds centre
    /// (scale and rotation both pivot there, so it maps to itself).
    var modelRotationPivot: Vec3? = nil
    /// Slice Direction in-viewport adjustment — protractor rings. While
    /// active, dragging a ring handle writes the tilt preview
    /// (live, transform-only) and commits on release.
    var sliceDirectionAdjustActive = false
    var sliceDirectionTiltBasis: SliceAxis = .z
    var sliceTilt: Vec2 = Vec2(x: 0, y: 0)
    var liveSliceTilt: Vec2? = nil
    var onSliceTiltPreview: ((Vec2) -> Void)? = nil
    var onSliceTiltCommit: ((Vec2) -> Void)? = nil
    /// NEO-97: Blender-style model-rotation rings (X red, Y green, Z blue)
    /// around the model. Dragging edits that axis's Object Size rotation
    /// component live through the existing preview/commit pipeline.
    var modelRotationAdjustActive = false
    var onModelRotationPreview: ((Vec3) -> Void)? = nil
    var onModelRotationCommit: ((Vec3) -> Void)? = nil
    let showImportedModel: Bool
    var appearance: ViewportAppearanceSettings = .defaultLook
    let previewMaterialThickness: Double
    let slicePlans: [StackedSlicePlan]
    let interlockedPlan: InterlockedSlicePlan?
    let threeDPlan: ThreeDSlicePlan?
    let radialPlan: RadialSlicePlan?
    let curvePlan: CurveSlicePlan?
    let foldedPanelPlan: FoldedPanelPlan?
    /// Inflatables: generated watertight membrane mesh plus the associated cut
    /// sheet. The viewport shows the same membrane mesh the STL/OBJ exporters
    /// write.
    var inflatablePlan: InflatablesPlan? = nil
    var inflatableViewMode: InflatablesViewMode = .inflated
    var selectedInflatablePanelID: String? = nil
    var onInflatablePanelSelect: ((String?) -> Void)? = nil
    /// Structures (Manifold infill): a single watertight mesh clipped to the
    /// model skin, shown as flat-shaded layers. Defaults to nil so every
    /// existing call site is unchanged.
    var structurePlan: StructureMeshPlan? = nil
    /// MotherMold parts have their own preview channel so inspection transforms,
    /// part names, and undercut markers never contaminate export geometry.
    var motherMoldPlan: MotherMoldPlan? = nil
    var motherMoldExploded = false
    var motherMoldShowUndercuts = false
    var motherMoldIsolatedPartName: String? = nil
    /// Artist-facing v3 layers. This is viewport state only; no selection or
    /// explode transform is written into the plan or export package.
    var motherMoldVisibleLayers: Set<MotherMoldPreviewLayer> = Set(MotherMoldPreviewLayer.allCases)
    /// Settings-driven seam, pour-hole, and holder guides shown only while the
    /// MotherMold result is unbuilt or stale.
    var motherMoldPrebuildOverlay: MotherMoldPrebuildOverlay? = nil
    /// One-shot MotherMold placement uses the existing stationary mouse-up
    /// lane. It never takes ownership of drag, orbit, or SpaceMouse input.
    var motherMoldSurfacePickingEnabled = false
    var onMotherMoldSurfacePick: ((MotherMoldSurfacePlacement.Hit) -> Void)? = nil
    /// Partition: bed-sized pieces shown flat-shaded, the SAME mesh the exporter
    /// writes. Defaults to nil so existing call sites are unchanged.
    var partitionPlan: PartitionMeshPlan? = nil
    /// Split-by-Undercuts measurements and stable identities. This is parallel
    /// to the legacy flat plan because the latter intentionally contains only
    /// export/render meshes and cannot carry pull axes or measured regions.
    var undercutSplitOverlay: UndercutSplitOverlay? = nil
    var undercutCutEditMode = false
    var undercutFacePaintMode: UndercutFacePaintMode = .none
    var onUndercutRegionHover: ((String?) -> Void)? = nil
    var onUndercutCutNodeHover: ((PartitionCutNodeID?) -> Void)? = nil
    var onUndercutCutNodeSelect: ((PartitionCutNodeID?) -> Void)? = nil
    var onUndercutCutNodeMoved: ((PartitionCutNodeID, CanonicalPlane) -> Void)? = nil
    var onUndercutCutNodeDeleteKey: ((PartitionCutNodeID) -> Void)? = nil
    var onUndercutSourceFacePaint: ((SourceFaceID) -> Void)? = nil
    /// Viewport-only explode amount (0…1) that pulls partition pieces apart so
    /// the cuts and keys are visible. Never affects exported geometry.
    var partitionExplode: Double = 0
    /// In-viewport plane gizmo (Manual mode): when on, the manual cut planes are
    /// shown as draggable handles that slide along their normal.
    var partitionEditMode = false
    var partitionManualPlanes: [PartitionPlane] = []
    var selectedPartitionPlaneIndex: Int? = nil
    var onPartitionPlaneSelect: ((Int?) -> Void)? = nil
    var onPartitionPlaneMoved: ((Int, Double) -> Void)? = nil
    var onPartitionPlaneDeleteKey: (() -> Void)? = nil
    let highlightedAssemblyStep: AssemblyStepHighlight?
    /// Material render style for the slice-solid preview (Cardboard / Plywood /
    /// Plastic). Changed cheaply via `applyMaterialStyle` retint — no scene
    /// rebuild; the same in-place approach used by `applyHighlight`.
    var renderStyle: SliceSolidRenderStyle = .cardboard
    /// Non-nil (and enabled) only in stacked mode: renders the dowel rods
    /// through the stack.
    var dowelSettings: DxfExporter.DowelSettings?
    /// 3D-pane dowel editing: click the model to add a rod,
    /// click a rod to select it (orange), drag it to move it through the
    /// stack, Delete or Control-click to remove.
    var dowelEditMode = false
    var selectedDowelPlan: Vec2? = nil
    var onDowelAdd: ((Vec2) -> Void)? = nil
    var onDowelMove: ((Vec2, Vec2) -> Void)? = nil
    var onDowelRemove: ((Vec2) -> Void)? = nil
    var onDowelSelect: ((Vec2?) -> Void)? = nil
    var onDowelDeleteKey: (() -> Void)? = nil
    // NEO-103: Slice editing in the 3D viewport.
    /// When true, clicking a stacked slice solid selects it; dragging
    /// moves it along the slice axis. Mirrors the dowelEditMode pattern.
    var sliceEditMode = false
    /// Index of the currently selected slice (into `slicePlans.first?.positions`).
    var selectedSliceIndex: Int? = nil
    var onSliceSelect: ((Int?) -> Void)? = nil
    /// Called on mouse-up after a drag; passes the slice index and its new axis position.
    var onSliceMoveCommit: ((Int, Double) -> Void)? = nil
    // NEO-104: Add/Remove Seams in the folded 3D viewport. When true,
    // clicking a panel-boundary edge of the folded shape preview toggles a
    // seam there. Pure click mode — no drag state, no scene entities.
    var seamEditMode = false
    var onSeamEdgeToggle: ((FoldedSeamEdge) -> Void)? = nil
    /// Model Health issue markers: one clickable dot per problem site of the
    /// DISPLAYED model (positions in its frame). Empty = no markers and no
    /// marker clicks. Clicking a marker reports its id (nil for a click on
    /// empty space or Escape); a new `issueFocusRequest` flies the camera to
    /// frame that site.
    var issueSites: [OpeningCapper.Site] = []
    var selectedIssueSiteID: String? = nil
    var issueFocusRequest: IssueMarkers.FocusRequest? = nil
    var onIssueSiteSelect: ((String?) -> Void)? = nil
    /// The Issues panel's "Show issues in viewport" toggle: off hides the
    /// markers (and their clicks) but rows still fly the camera.
    var issueMarkersVisible = true
    @Binding var cameraState: ViewportCameraState

    /// The fly-to animation in flight (cancelled by the next request).
    @State private var issueFlyTask: Task<Void, Never>?

    private struct DowelDragState {
        var from: Vec2
        var current: Vec2
        var midPosition: Double
    }
    /// Live rod drag: the pin entity is repositioned IN PLACE per frame;
    /// the move only commits (and the document only rebuilds) on mouse-up.
    @State private var dowelDrag: DowelDragState?

    // NEO-103: live slice drag state.
    private struct SliceDragState {
        var sliceIndex: Int
        var startAxisPosition: Double
        var currentAxisPosition: Double
        var axis: SliceAxis
    }
    @State private var sliceDrag: SliceDragState?
    /// The slice-direction ring drag in flight: which ring, and the angle
    /// snap — grabbing the RING itself snaps to 5°; dragging the handle is
    /// freeform.
    private struct RingDragState {
        var index: Int
        var snapDegrees: Double
    }
    @State private var ringDrag: RingDragState?

    /// NEO-97: model-rotation ring drag in flight. The drag rotates the model
    /// about the ring's WORLD axis by (cursor − grab), composed onto the
    /// orientation captured at grab time (`startRotation`) — so it matches the
    /// ring instead of poking one Euler component. Banking the grab-time
    /// orientation keeps the delta drift-free across the whole drag.
    private struct ModelRingDragState {
        var index: Int
        var snapDegrees: Double
        var grabDegrees: Double
        var startRotation: Vec3
    }
    @State private var modelRingDrag: ModelRingDragState?

    /// Live partition plane-handle drag: the plane slides along its normal; the
    /// offset only commits (re-arming Generate) on mouse-up.
    private struct PartitionPlaneDragState {
        var index: Int
        var startOffset: Double
        var currentOffset: Double
        var normal: Vec3
        var handle: Vec3
        var rangeMin: Double
        var rangeMax: Double
    }
    @State private var partitionPlaneDrag: PartitionPlaneDragState?

    /// In-place pins refresh across update passes. A reference type so the
    /// async rebuild Task can see the LATEST inputs (the view struct it
    /// captured is frozen at spawn time).
    private final class DowelPinsCoordinator {
        var inFlight = false
        var latest: (model: MeshSummary, plan: StackedSlicePlan, settings: DxfExporter.DowelSettings, key: String)?
    }
    @State private var dowelPinsCoordinator = DowelPinsCoordinator()

    /// Same pattern for the edit-mode plane entity: swapped in place when
    /// placements change, without rebuilding the full scene.
    private final class DowelEditPlaneCoordinator {
        var inFlight = false
        var latest: (model: MeshSummary, plan: StackedSlicePlan, settings: DxfExporter.DowelSettings, key: String)?
    }
    @State private var dowelEditPlaneCoordinator = DowelEditPlaneCoordinator()

    /// Tracks the last render style applied in `applyMaterialStyle` so the
    /// retint pass is a no-op on frames where the style hasn't changed.
    private final class RenderStyleTracker {
        var applied: SliceSolidRenderStyle?
    }
    @State private var renderStyleTracker = RenderStyleTracker()

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.environment = .default
                content.renderingEffects.depthOfField = .disabled
                content.renderingEffects.motionBlur = .disabled
                content.renderingEffects.cameraGrain = .disabled
                content.renderingEffects.antialiasing = .multisample4X

                let root = await makeRealityRoot()
                let camera = makeCameraEntity(bounds: viewportBounds, state: cameraState)
                content.add(root)
                content.add(camera)
                content.cameraTarget = camera
            } update: { content in
                for entity in content.entities {
                    if let cameraEntity = entity.findEntity(named: Self.cameraName) {
                        if let persp = cameraEntity as? PerspectiveCamera {
                            configurePerspCamera(persp, bounds: viewportBounds, state: cameraState)
                            content.cameraTarget = persp
                        } else {
                            // Ortho camera: plain Entity carrying OrthographicCameraComponent.
                            configureOrthoCamera(cameraEntity, bounds: viewportBounds, state: cameraState)
                            content.cameraTarget = cameraEntity
                        }
                        break
                    }
                }
                applyModelSpin(content, bounds: viewportBounds, state: cameraState)
                // Selection is applied IN PLACE: retinting ~100 materials is
                // milliseconds, where the old highlight-in-identity approach
                // rebuilt the whole RealityKit scene (~seconds on a large
                // mesh) for every assembly-step or sheet-part click.
                for entity in content.entities {
                    applyHighlight(to: entity)
                    applyMaterialStyle(to: entity)
                    applyDowelPinAdjustments(to: entity)
                    applySliceDragAdjustments(to: entity)
                    applyPartitionDragAdjustments(to: entity)
                    applyUndercutOverlayState(to: entity)
                    applyLiveOrientationPreviews(to: entity)
                    applySliceDirectionRingAdjustments(to: entity)
                    applyModelRotationRingAdjustments(to: entity)
                    applyMotherMoldInspectionTransforms(to: entity)
                }
                refreshDowelPinsIfNeeded(in: content.entities)
                refreshDowelEditPlaneIfNeeded(in: content.entities)
                refreshMotherMoldPrebuildOverlayIfNeeded(in: content.entities)
                refreshIssueMarkersIfNeeded(in: content.entities)
                applyIssueMarkerState(in: content.entities)
            }
            .id(sceneIdentity)

            ViewportInteractionCaptureView(
                rotateCamera: { deltaX, deltaY in
                    let orbit = ViewportPointerMapping.orbitDeltas(deltaX: deltaX, deltaY: deltaY)
                    cameraState.rotate(deltaX: orbit.deltaX, deltaY: orbit.deltaY)
                },
                panCamera: { deltaX, deltaY in
                    cameraState.pan(deltaX: deltaX, deltaY: deltaY, radius: ViewportCamera.radius(bounds: model?.bounds))
                },
                zoomCamera: { scrollDeltaY in
                    cameraState.zoom(scrollDeltaY: scrollDeltaY)
                },
                mouseClicked: (
                    (motherMoldSurfacePickingEnabled && !cameraState.isOrthographic)
                        || inflatablePlan != nil
                        || (undercutSplitOverlay != nil && undercutFacePaintMode != .none)
                        || !visibleIssueSites.isEmpty
                ) ? { point, size in
                    if motherMoldSurfacePickingEnabled && !cameraState.isOrthographic {
                        return handleMotherMoldSurfacePick(at: point, viewSize: size)
                    }
                    // Issue markers sit on top of everything, so a click on
                    // one wins over the mode's own click.
                    if handleIssueMarkerClick(at: point, viewSize: size) { return true }
                    if inflatablePlan != nil {
                        return handleInflatablePanelClick(at: point, viewSize: size)
                    }
                    if undercutSplitOverlay != nil && undercutFacePaintMode != .none {
                        return handleUndercutFacePaintClick(at: point, viewSize: size)
                    }
                    return false
                } : nil,
                mouseMoved: undercutSplitOverlay != nil ? { point, size in
                    handleUndercutHover(at: point, viewSize: size)
                } : nil,
                // Picking math (ray/project) assumes a perspective camera.
                // Dowel editing, slice editing, and slice-direction rings are
                // disabled while orthographic is active.
                dowelMouseDown: (!cameraState.isOrthographic && (dowelEditMode || sliceEditMode || sliceDirectionAdjustActive || seamEditMode || modelRotationAdjustActive || partitionEditMode || undercutCutEditMode)) ? { point, size, isControl in
                    if handleModelRingMouseDown(at: point, viewSize: size) { return true }
                    if handleRingMouseDown(at: point, viewSize: size) { return true }
                    if seamEditMode {
                        return handleSeamMouseDown(at: point, viewSize: size)
                    }
                    if sliceEditMode {
                        return handleSliceMouseDown(at: point, viewSize: size)
                    }
                    if partitionEditMode || undercutCutEditMode {
                        return handlePartitionMouseDown(at: point, viewSize: size)
                    }
                    return dowelEditMode ? handleDowelMouseDown(at: point, viewSize: size, isControlClick: isControl) : false
                } : nil,
                dowelMouseDragged: (!cameraState.isOrthographic && (dowelEditMode || sliceEditMode || sliceDirectionAdjustActive || modelRotationAdjustActive || partitionEditMode || undercutCutEditMode)) ? { point, size in
                    if modelRingDrag != nil {
                        handleModelRingMouseDragged(at: point, viewSize: size)
                    } else if ringDrag != nil {
                        handleRingMouseDragged(at: point, viewSize: size)
                    } else if sliceEditMode {
                        handleSliceMouseDragged(at: point, viewSize: size)
                    } else if partitionEditMode || undercutCutEditMode {
                        handlePartitionMouseDragged(at: point, viewSize: size)
                    } else if dowelEditMode {
                        handleDowelMouseDragged(at: point, viewSize: size)
                    }
                } : nil,
                dowelMouseUp: (!cameraState.isOrthographic && (dowelEditMode || sliceEditMode || sliceDirectionAdjustActive || modelRotationAdjustActive || partitionEditMode || undercutCutEditMode)) ? {
                    if handleModelRingMouseUp() { return true }
                    if handleRingMouseUp() { return true }
                    if sliceEditMode { return handleSliceMouseUp() }
                    if partitionEditMode || undercutCutEditMode { return handlePartitionMouseUp() }
                    return dowelEditMode ? handleDowelMouseUp() : false
                } : nil,
                dowelDeleteKey: (!cameraState.isOrthographic && (dowelEditMode || partitionEditMode || undercutCutEditMode)) ? {
                    if undercutCutEditMode,
                       let cut = undercutSplitOverlay?.cutSurfaces.first(where: \.isSelected) {
                        onUndercutCutNodeDeleteKey?(cut.nodeID)
                    } else if partitionEditMode {
                        onPartitionPlaneDeleteKey?()
                    } else {
                        onDowelDeleteKey?()
                    }
                } : nil,
                escapeKey: (!issueSites.isEmpty && selectedIssueSiteID != nil) ? {
                    onIssueSiteSelect?(nil)
                } : nil
            )
            if appearance.vignette > 0.001 && model != nil {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .clear,
                                    Color.black.opacity(0.36 * ViewportAppearanceSettings.clamped01(appearance.vignette))
                                ],
                                center: .center,
                                startRadius: max(80, min(proxy.size.width, proxy.size.height) * 0.24),
                                endRadius: max(proxy.size.width, proxy.size.height) * 0.68
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            if motherMoldPlan != nil {
                motherMoldLegend
            }
            if motherMoldPrebuildOverlay != nil {
                motherMoldPrebuildLegend
            }
            if undercutSplitOverlay != nil {
                undercutSplitLegend
            }
            if !visibleIssueSites.isEmpty {
                issueMarkersLegend
            }
        }
        .onChange(of: issueFocusRequest) { _, request in
            guard let request, let site = issueSites.first(where: { $0.id == request.siteID }) else { return }
            flyToIssueSite(site)
        }
        .background(
            appearance.backdrop.color(for: colorScheme).color
        )
    }

    private enum SolidDisplayState: String {
        case normal = ""
        case selected = "|sel"
        case future = "|fut"
    }

    /// Assembly-order ordinal of a solid, used for the step-through
    /// "watch it being built" view: everything after the selected
    /// step renders as a faint ghost.
    private func stepOrdinal(kind: Substring, familyIndex: Int, layerIndex: Int) -> Int {
        switch kind {
        case "stacked":
            if let interlockedPlan {
                return familyIndex == 0 ? layerIndex : interlockedPlan.primary.positions.count + layerIndex
            }
            if let threeDPlan {
                let xCount = threeDPlan.x.positions.count
                let yCount = threeDPlan.y.positions.count
                switch familyIndex {
                case 0: return layerIndex
                case 1: return xCount + layerIndex
                default: return xCount + yCount + layerIndex
                }
            }
            if curvePlan != nil || radialPlan != nil {
                return layerIndex // curve/radial primary family leads the sequence
            }
            var base = 0
            for (index, plan) in slicePlans.enumerated() {
                if index == familyIndex { return base + layerIndex }
                base += plan.positions.count
            }
            return base + layerIndex
        case "curve":
            return (curvePlan?.primary.positions.count ?? 0) + layerIndex
        case "radial":
            return (radialPlan?.primary?.positions.count ?? 0) + layerIndex
        default: // folded
            return layerIndex
        }
    }

    private var selectedStepOrdinal: Int? {
        switch highlightedAssemblyStep {
        case .stacked(let family, let layer):
            return stepOrdinal(kind: "stacked", familyIndex: family, layerIndex: layer)
        case .radial(let layer):
            return stepOrdinal(kind: "radial", familyIndex: 0, layerIndex: layer)
        case .curve(let layer):
            return stepOrdinal(kind: "curve", familyIndex: 0, layerIndex: layer)
        case .foldedPanel(let panel):
            return stepOrdinal(kind: "folded", familyIndex: 0, layerIndex: panel)
        case nil:
            return nil
        }
    }

    /// Walk solid entities (named kind|family|layer|color) and swap materials
    /// only where the display state actually changed — the name suffix tracks
    /// the applied state so camera-drag updates don't churn materials. With a
    /// step selected, later steps ghost out so paging shows the build growing.
    private func applyHighlight(to entity: Entity) {
        let name = entity.name
        if name.hasPrefix("slicesolid|") {
            let previousState: SolidDisplayState
            let core: String
            if name.hasSuffix("|sel") {
                previousState = .selected
                core = String(name.dropLast(4))
            } else if name.hasSuffix("|fut") {
                previousState = .future
                core = String(name.dropLast(4))
            } else {
                previousState = .normal
                core = name
            }
            let fields = core.split(separator: "|")
            if fields.count == 5,
               let familyIndex = Int(fields[2]),
               let layerIndex = Int(fields[3]),
               let colorIndex = Int(fields[4]),
               let modelEntity = entity as? ModelEntity {
                let kind = fields[1]
                let isSelected: Bool
                switch highlightedAssemblyStep {
                case .stacked(let family, let layer):
                    isSelected = kind == "stacked" && family == familyIndex && layer == layerIndex
                case .radial(let layer):
                    isSelected = kind == "radial" && layer == layerIndex
                case .curve(let layer):
                    isSelected = kind == "curve" && layer == layerIndex
                case .foldedPanel(let panel):
                    isSelected = kind == "folded" && panel == layerIndex
                case nil:
                    if kind == "inflatables",
                       let selectedInflatablePanelID,
                       inflatablePlan?.panels.indices.contains(layerIndex) == true {
                        isSelected = inflatablePlan?.panels[layerIndex].id == selectedInflatablePanelID
                    } else if sliceEditMode, let sel = sliceDrag?.sliceIndex ?? selectedSliceIndex {
                        // NEO-103: Slice edit selection — orange-tint the dragged slice
                        // when no assembly step is highlighted.
                        isSelected = kind == "stacked" && familyIndex == 0 && layerIndex == sel
                    } else {
                        isSelected = false
                    }
                }
                let state: SolidDisplayState
                if isSelected {
                    state = .selected
                } else if let selectedOrdinal = selectedStepOrdinal,
                          stepOrdinal(kind: kind, familyIndex: familyIndex, layerIndex: layerIndex) > selectedOrdinal {
                    state = .future
                } else {
                    state = .normal
                }
                if state != previousState {
                    let panelID = kind == "inflatables" && inflatablePlan?.panels.indices.contains(layerIndex) == true
                        ? inflatablePlan?.panels[layerIndex].id
                        : nil
                    let base = kind == "inflatables"
                        ? inflatablePanelColor(panelIndex: layerIndex, panelID: panelID, plan: inflatablePlan)
                        : Self.solidPalette[colorIndex % Self.solidPalette.count]
                    modelEntity.model?.materials = [
                        sliceSolidMaterial(base: base, selected: state == .selected, future: state == .future)
                    ]
                    entity.name = core + state.rawValue
                }
            }
        }
        for child in entity.children {
            applyHighlight(to: child)
        }
    }

    /// Retint all slice-solid entities when `renderStyle` changes. Walks the
    /// entity tree once per style change (tracked by `renderStyleTracker`);
    /// no-op on all subsequent frames until the style changes again. Like
    /// `applyHighlight`, only sets materials on the entities that need it —
    /// normal/selected/future states are each re-derived so the two passes
    /// stay in sync.
    private func applyMaterialStyle(to entity: Entity) {
        let tracker = renderStyleTracker
        guard tracker.applied != renderStyle else { return }
        applyMaterialStyleRecursive(to: entity)
        // Mark the style applied after walking the whole tree. Because this
        // function is called once per entity in the root list (not once total),
        // we mark it inside the root-level entity so subsequent children skip.
        if entity.name == "Imported model root" {
            tracker.applied = renderStyle
        }
    }

    private func applyMaterialStyleRecursive(to entity: Entity) {
        let name = entity.name
        if name.hasPrefix("slicesolid|") {
            // Parse the same way applyHighlight does, re-derive state from
            // the suffix, then rebuild the material with the new style.
            let previousState: SolidDisplayState
            let core: String
            if name.hasSuffix("|sel") {
                previousState = .selected
                core = String(name.dropLast(4))
            } else if name.hasSuffix("|fut") {
                previousState = .future
                core = String(name.dropLast(4))
            } else {
                previousState = .normal
                core = name
            }
            let fields = core.split(separator: "|")
            if fields.count == 5,
               let colorIndex = Int(fields[4]),
               let modelEntity = entity as? ModelEntity {
                let kind = fields[1]
                let layerIndex = Int(fields[3]) ?? 0
                let panelID = kind == "inflatables" && inflatablePlan?.panels.indices.contains(layerIndex) == true
                    ? inflatablePlan?.panels[layerIndex].id
                    : nil
                let base = kind == "inflatables"
                    ? inflatablePanelColor(panelIndex: layerIndex, panelID: panelID, plan: inflatablePlan)
                    : Self.solidPalette[colorIndex % Self.solidPalette.count]
                modelEntity.model?.materials = [
                    sliceSolidMaterial(
                        base: base,
                        selected: previousState == .selected,
                        future: previousState == .future
                    )
                ]
            }
        }
        for child in entity.children {
            applyMaterialStyleRecursive(to: child)
        }
    }

    private var sceneIdentity: String {
        var parts = [
            model?.path ?? "empty",
            "model:\(showImportedModel)",
            "thickness:\(Vec3.format(previewMaterialThickness))",
            model.map { "\($0.triangleCount)-\($0.vertexObservationCount)" } ?? "no-model",
            // Transform signature: scale/rotation/repair change the geometry
            // without changing path or counts — without this the viewport kept
            // showing the OLD mesh after a resize (the "Reset doesn't work"
            // report: it worked, invisibly).
            model?.bounds.map { "\($0.min.display)|\($0.max.display)" } ?? "no-bounds",
            "slice-frame:\(Vec3.format(sliceFrameRotationDegrees.x)):\(Vec3.format(sliceFrameRotationDegrees.y)):\(Vec3.format(sliceFrameRotationDegrees.z))",
            "appearance:\(appearance.signature)",
            "rings:\(sliceDirectionAdjustActive):\(sliceDirectionTiltBasis.rawValue)",
            "model-rings:\(modelRotationAdjustActive)",
            "ortho:\(cameraState.isOrthographic)"
        ]
        parts.append(contentsOf: slicePlans.map { plan in
            "\(plan.axis.rawValue):\(plan.positions.map(Vec3.format).joined(separator: ","))"
        })
        if let interlockedPlan {
            parts.append("interlocked-slots:\(interlockedPlan.slotCount):\(Vec3.format(interlockedPlan.slotWidth)):\(Vec3.format(interlockedPlan.normalizedSlotAngleDegrees))")
        }
        if let threeDPlan {
            parts.append("three-d-slots:\(threeDPlan.sliceCount):\(Vec3.format(threeDPlan.slotWidth)):\(Vec3.format(threeDPlan.slotAngleDegrees))")
        }
        if let radialPlan {
            let primaryKey = radialPlan.primary.map(ViewportGeometryCache.planKey(for:)) ?? "none"
            parts.append("radial:\(radialPlan.nRadial):\(Vec3.format(radialPlan.materialThickness)):\(Vec3.format(radialPlan.slotClearance)):\(Vec3.format(radialPlan.slotWidth)):\(primaryKey)")
        }
        if let curvePlan {
            let splineKey = curvePlan.controlPoints
                .map { "\(Vec3.format($0.x)),\(Vec3.format($0.y))" }
                .joined(separator: ";")
            parts.append("curve:\(curvePlan.primary.axis.rawValue):\(curvePlan.primarySliceCount):\(curvePlan.sliceCount):\(splineKey):\(Vec3.format(curvePlan.slotWidth)):\(Vec3.format(curvePlan.slotAngleDegrees))")
        }
        if let foldedPanelPlan {
            parts.append("folded:\(foldedPanelPlan.surfaces3D.count):\(Vec3.format(previewMaterialThickness))")
        }
        if let inflatablePlan {
            let mesh = inflatablePlan.preview?.inflatedMesh
            let deviation = inflatablePlan.preview?.maxDeviationMM ?? 0
            parts.append("inflatables:\(inflatableViewMode.rawValue):\(inflatablePlan.panels.count):\(mesh?.vertices.count ?? 0):\(mesh?.triangleIndices.count ?? 0):\(Vec3.format(deviation))")
        }
        if let structurePlan {
            parts.append("structures:\(structurePlan.settings.pattern.rawValue):\(structurePlan.triangleCount)")
        }
        if let motherMoldPlan {
            let triangleCount = motherMoldPlan.parts.reduce(0) { $0 + $1.geometry.triangleIndices.count / 3 }
            let undercutCount = motherMoldPlan.undercutReports.reduce(0) { $0 + $1.regions.count }
            // Explode moves existing entities in place, preserving the camera.
            parts.append("mothermold:\(motherMoldPlan.parts.count):\(triangleCount):isolated\(motherMoldIsolatedPartName ?? "all"):undercuts\(motherMoldShowUndercuts ? undercutCount : 0)")
        }
        if let partitionPlan {
            parts.append("partition:\(partitionPlan.pieces.count):\(partitionPlan.triangleCount):\(Vec3.format(partitionExplode))")
        }
        if let overlay = undercutSplitOverlay {
            parts.append(
                "undercut-overlay:\(overlay.deterministicFingerprint):stale\(overlay.isStale)"
                    + ":isolated\(overlay.isolatedPieceRegionID?.rawValue ?? "all")"
                    + ":paint\(overlay.facePaintFingerprint)"
            )
        }
        if undercutCutEditMode {
            parts.append("undercut-cut-edit:true")
        }
        if partitionEditMode {
            // Handles rebuild when the committed plane set / selection changes;
            // the live drag repositions in place (applyPartitionDragAdjustments).
            let planeKey = partitionManualPlanes
                .map { "\(Vec3.format($0.normalX)),\(Vec3.format($0.normalY)),\(Vec3.format($0.normalZ)),\(Vec3.format($0.offset))" }
                .joined(separator: ";")
            parts.append("partedit:\(planeKey):sel\(selectedPartitionPlaneIndex ?? -1)")
        }
        if let dowelSettings, dowelSettings.enabled {
            // Manual positions are deliberately NOT part of the identity:
            // a dowel edit swaps just the pins entity in place
            // (refreshDowelPinsIfNeeded) instead of rebuilding ~45 slice
            // solids — the "every dowel click stalls the app" fix.
            parts.append("dowels:\(Vec3.format(dowelSettings.diameter)):\(Vec3.format(dowelSettings.inset)):\(dowelSettings.shape.rawValue)")
        }
        // Dowel edit mode: the outlined placement area + markers are built in
        // makeRealityRoot and must appear/disappear when the mode toggles.
        parts.append("doweledit:\(dowelEditMode)")
        // Deliberately NO highlight component: selection retints in place via
        // applyHighlight instead of rebuilding the scene.
        return parts.joined(separator: "|")
    }

    private var viewportBounds: Bounds3D? {
        if let overlayBounds = undercutSplitOverlay?.bounds {
            return overlayBounds
        }
        if let motherMoldPlan,
           let moldBounds = MotherMoldPreviewLayout.previewBounds(
                for: motherMoldPlan,
                // Stable assembled bounds keep camera refitting from visually
                // canceling the part separation.
                exploded: false,
                isolatedPartName: motherMoldIsolatedPartName,
                includeMaster: showImportedModel
           ) {
            return moldBounds
        }
        return ViewportSceneBounds.bounds(
            modelBounds: model?.bounds,
            foldedPanelPlan: foldedPanelPlan,
            inflatablePlan: inflatablePlan,
            materialThickness: previewMaterialThickness
        )
    }

    @MainActor
    private func makeRealityRoot() async -> Entity {
        let root = Entity()
        root.name = "Imported model root"
        configureLights(in: root)

        guard let model else {
            return root
        }

        let hasSlicePreview = !slicePlans.isEmpty || interlockedPlan != nil || threeDPlan != nil || radialPlan != nil || curvePlan != nil || foldedPanelPlan != nil || inflatablePlan != nil || structurePlan != nil || motherMoldPlan != nil || partitionPlan != nil || undercutSplitOverlay != nil
        var contentCount = 0
        // "Model" shows the solid model; "Both" overlays a translucent ghost of
        // the model on the slice solids so both are actually visible (an opaque
        // model would swallow the slices, and hiding it made Both == Slices).
        let showsMotherMoldSource = motherMoldPlan == nil
            || motherMoldVisibleLayers.contains(.activeSource)
        let showsUndercutSourceGhost = undercutSplitOverlay != nil && partitionExplode > 0
        if (showImportedModel || showsUndercutSourceGhost), showsMotherMoldSource,
           let modelEntity = await makeModelEntity(model, ghosted: hasSlicePreview) {
            root.addChild(modelEntity)
            contentCount += 1
        }

        // Structures infill: a single watertight mesh already in MODEL space
        // (no slice-direction tilt), so it lives directly under `root`, not the
        // counter-rotated slice frame.
        if let structurePlan, let structureEntity = await makeStructureSolidEntity(plan: structurePlan) {
            root.addChild(structureEntity)
            contentCount += 1
        }

        if let motherMoldPlan, let motherMoldEntity = await makeMotherMoldEntity(plan: motherMoldPlan) {
            root.addChild(motherMoldEntity)
            contentCount += 1
        }

        if let motherMoldPrebuildOverlay {
            root.addChild(makeMotherMoldPrebuildOverlayEntity(motherMoldPrebuildOverlay))
            contentCount += 1
        }

        // Partition pieces: watertight bed-sized chunks in MODEL space, optionally
        // exploded apart so the cuts and keys read in the viewport.
        if let partitionPlan, let partitionEntity = await makePartitionSolidEntity(plan: partitionPlan) {
            root.addChild(partitionEntity)
            contentCount += 1
        }

        if let undercutSplitOverlay,
           let overlayEntity = await makeUndercutSplitOverlayEntity(overlay: undercutSplitOverlay) {
            root.addChild(overlayEntity)
            contentCount += 1
        }

        // Inflatables membrane: generated in MODEL space and exported as the
        // same STL/OBJ mesh, so keep it outside the slice-frame root.
        if let inflatablePlan, let inflatableEntity = await makeInflatablesSolidEntity(plan: inflatablePlan) {
            root.addChild(inflatableEntity)
            contentCount += 1
        }

        // Partition plane gizmo: a draggable handle per manual cut plane.
        if (partitionEditMode || undercutCutEditMode),
           let bounds = undercutSplitOverlay?.bounds ?? model.bounds,
           let handles = makePartitionHandlesEntity(bounds: bounds) {
            root.addChild(handles)
            contentCount += 1
        }

        // Slice solids are built in the slicing frame (`sliceModel`) and live
        // under `sliceRoot`, which is counter-rotated so they land on the
        // un-rotated `model`. The model entity above stays put — only the cut
        // planes tilt. At zero tilt sliceModel == model and the transform is
        // identity, so this is byte-for-byte the previous behaviour.
        let sliceModel = sliceFrameModel ?? model
        let sliceRoot = Entity()
        sliceRoot.name = Self.sliceFrameRootName

        if let interlockedPlan {
            if let solidEntity = await makeInterlockedSolidEntity(model: sliceModel, plan: interlockedPlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
        } else if let threeDPlan {
            if let solidEntity = await makeThreeDSolidEntity(model: sliceModel, plan: threeDPlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
        } else {
            for (index, slicePlan) in slicePlans.enumerated() {
                // Contours generate inside the builder, OFF the main actor.
                if let solidEntity = await makeSliceSolidEntity(model: sliceModel, plan: slicePlan, familyIndex: index) {
                    sliceRoot.addChild(solidEntity)
                    contentCount += 1
                }
            }
            // Dowel rods through the stack.
            if let dowelSettings, dowelSettings.enabled, let plan = slicePlans.first,
               let pins = await makeDowelPinsEntity(model: sliceModel, plan: plan, settings: dowelSettings) {
                pins.name = Self.dowelPinsNamePrefix + Self.dowelPinsKey(settings: dowelSettings)
                sliceRoot.addChild(pins)
                contentCount += 1
            }
        }
        if let radialPlan {
            if let solidEntity = await makeRadialSolidEntity(model: sliceModel, plan: radialPlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
        }
        if let curvePlan {
            let primaryContours = await Self.offMain {
                CurveSliceContourer.cleaned(ViewportGeometryCache.shared.stackedContours(model: sliceModel, plan: curvePlan.primary), model: sliceModel)
            }
            let contours = await Self.offMain {
                ViewportGeometryCache.shared.curveContours(model: sliceModel, plan: curvePlan) {
                    CurveSliceContourer.generate(model: sliceModel, plan: curvePlan)
                }
            }
            let slots = await Self.offMain {
                CurveJointPlanner.slots(plan: curvePlan, primary: primaryContours, curve: contours)
            }
            if let solidEntity = await makeCurvePrimarySolidEntity(contours: primaryContours, slotted: slots.primaryPaths, plan: curvePlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
            if let solidEntity = await makeCurveSolidEntity(contours: contours, slotted: slots.curvePaths, plan: curvePlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
        }
        if let foldedPanelPlan {
            if let solidEntity = await makeFoldedShapeEntity(plan: foldedPanelPlan) {
                sliceRoot.addChild(solidEntity)
                contentCount += 1
            }
        }

        if !sliceRoot.children.isEmpty {
            if let center = model.bounds.map(Self.boundsCenter),
               sliceFrameRotationDegrees != Vec3(x: 0, y: 0, z: 0) {
                sliceRoot.transform = Transform(matrix: SliceFrameTransform.inverseMatrixAboutCenter(
                    rotationDegrees: sliceFrameRotationDegrees,
                    center: center
                ))
            }
            root.addChild(sliceRoot)
        }

        if sliceDirectionAdjustActive, let bounds = model.bounds {
            root.addChild(makeSliceDirectionRingsEntity(bounds: bounds))
        }
        // NEO-97: model-rotation rings live on the STATIC root, outside the
        // live-preview transform — world-axis rings must not spin with the
        // model they rotate.
        if modelRotationAdjustActive, let bounds = model.bounds {
            root.addChild(makeModelRotationRingsEntity(bounds: bounds))
        }

        // Nothing renderable (e.g. Slices preview while a mode can't produce a
        // plan, like Folded refusing a too-dense mesh): fall back to the solid
        // model rather than an empty scene.
        if contentCount == 0, let modelEntity = await makeModelEntity(model, ghosted: false) {
            root.addChild(modelEntity)
            contentCount += 1
        }
        // The shadow only exists under actual content — an orphaned shadow in
        // an otherwise empty viewport reads as a glitchy gray blob.
        if contentCount > 0, let ground = makeGroundShadowEntity(bounds: viewportBounds) {
            root.addChild(ground)
        }
        return root
    }

    @MainActor
    private func makeModelEntity(_ model: MeshSummary, ghosted: Bool) async -> Entity? {
        let mesh: MeshResource
        if let cached = ViewportGeometryCache.shared.cachedModelMesh(for: model) {
            mesh = cached
        } else {
            // Flat (per-face) normals: the MatCap shades
            // each facet uniformly so the viewer sees the actual mesh that will be
            // cut, not a smoothed approximation — more honest for a slicer.
            let renderMesh = ViewportMeshRenderData.flatShadedMesh(from: model.geometry)
            guard !renderMesh.vertices.isEmpty else {
                return nil
            }

            var descriptor = MeshDescriptor(name: "Imported model mesh")
            descriptor.positions = MeshBuffers.Positions(renderMesh.vertices.map(simdPoint))
            descriptor.normals = MeshBuffers.Normals(renderMesh.normals.map(simdPoint))
            // The MatCap computes its sphere UV from the view-space normal in the
            // shader, so the mesh needs no texture coordinates.
            descriptor.primitives = .triangles(renderMesh.triangleIndices.compactMap { UInt32(exactly: $0) })

            guard let built = try? await MeshResource(from: [descriptor]) else {
                return nil
            }
            ViewportGeometryCache.shared.storeModelMesh(built, for: model)
            mesh = built
        }

        let entity = Entity()
        entity.name = "Imported model"
        // Solid model → MatCap (reads form like a sculpt view). Ghosted "Both"
        // mode keeps the translucent PBR shell so it can sit over the slices.
        var modelMaterials: [RealityKit.Material] = [modelMaterial(ghosted: ghosted)]
        if !ghosted {
            do {
                modelMaterials = [try await ViewportMatcapMaterial.make(material: appearance.material, color: appearance.objectColor)]
            } catch {
                NSLog("[Viewport] MatCap unavailable — falling back to PBR model material: \(error)")
                assertionFailure("MatCap failed to load: \(error)")
            }
        }
        let meshEntity = ModelEntity(mesh: mesh, materials: modelMaterials)
        // Real soft contact shadow onto the catcher plane → grounded depth.
        meshEntity.components.set(GroundingShadowComponent(castsShadow: true))
        entity.addChild(meshEntity)
        let edgeStrength = ViewportAppearanceSettings.clamped01(appearance.edgeStrength)
        if edgeStrength > 0.001,
           ViewportMeshRenderData.shouldRenderFeatureEdges(
                triangleCount: model.triangleCount,
                ghosted: ghosted
           ) {
            for edge in ViewportMeshRenderData.featureEdges(from: model.geometry, creaseAngleDegrees: Self.importedModelFeatureEdgeCreaseAngleDegrees) {
                guard let start = point(edge.startIndex, in: model.geometry.vertices),
                      let end = point(edge.endIndex, in: model.geometry.vertices),
                      let edgeEntity = lineEntity(
                        from: start,
                        to: end,
                        color: NSColor(calibratedWhite: 0.04, alpha: 0.02 + 0.18 * edgeStrength),
                        thickness: edgeThickness(for: model) * Float(0.22 + 0.55 * edgeStrength)
                      ) else {
                    continue
                }
                edgeEntity.name = "Imported model feature edge"
                entity.addChild(edgeEntity)
            }
        }
        return entity
    }

    @MainActor
    /// Shared palette indexed by the color slot encoded in solid entity names,
    /// so the highlight pass can rebuild a material without a scene rebuild.
    static let solidPalette: [NSColor] = [.systemOrange, .systemTeal, .systemPink, .systemPurple, .systemGreen, .systemBlue]

    static func distinctInflatableColor(index: Int) -> NSColor {
        let hue = (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.68, brightness: 0.92, alpha: 0.95)
    }

    static func deviationColor(_ rawRatio: Double) -> NSColor {
        let ratio = min(max(rawRatio.isFinite ? rawRatio : 0, 0), 1)
        let hue = min(max(0.34 * (1 - ratio), 0), 0.34)
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.82, brightness: 0.94, alpha: 0.95)
    }

    /// Stable name for a slice-solid entity carrying everything the in-place
    /// highlight pass needs: kind|familyIndex|layerIndex|colorIndex.
    private static func solidName(kind: String, familyIndex: Int, layerIndex: Int, colorIndex: Int) -> String {
        "slicesolid|\(kind)|\(familyIndex)|\(layerIndex)|\(colorIndex)"
    }

    /// Run CPU-heavy geometry generation off the main actor so the Slice press
    /// doesn't freeze the UI while contours generate and solids extrude.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func makeSliceSolidEntity(model: MeshSummary, plan: StackedSlicePlan, familyIndex: Int) async -> Entity? {
        let container = Entity()
        container.name = "Stacked slice solid preview"
        let colorIndex = familyIndex % Self.solidPalette.count
        let baseColor = Self.solidPalette[colorIndex]

        // The layers the cut sheet and every export cut: closed across any
        // cracks in the mesh.
        let solids: [(layerIndex: Int, mesh: ViewportFlatShadedMesh)] = await Self.offMain {
            ViewportGeometryCache.shared.stackedSolidMeshes(model: model, plan: plan)
        }

        for (layerIndex, renderMesh) in solids {
            guard let mesh = await meshResource(from: renderMesh) else { continue }
            let selected = highlightedAssemblyStep == .stacked(familyIndex: familyIndex, layerIndex: layerIndex)
            let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: baseColor, selected: selected)])
            entity.name = Self.solidName(kind: "stacked", familyIndex: familyIndex, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    @MainActor
    private func makeInterlockedSolidEntity(model: MeshSummary, plan: InterlockedSlicePlan) async -> Entity? {
        let container = Entity()
        container.name = "Interlocked cut slice solid preview"
        let families = [
            (
                plan: plan.primary,
                crossing: plan.secondary,
                mode: InterlockedSlotCutoutMode.primary,
                familyIndex: 0,
                color: NSColor.systemOrange
            ),
            (
                plan: plan.secondary,
                crossing: plan.primary,
                mode: InterlockedSlotCutoutMode.secondary,
                familyIndex: 1,
                color: NSColor.systemTeal
            )
        ]

        for family in families {
            let familyPlan = family.plan
            let familyCrossing = family.crossing
            let familyMode = family.mode
            let planKey = ViewportGeometryCache.planKey(for: familyPlan)
            let slotKey = "\(plan.slotCount)|\(Vec3.format(plan.slotWidth))|\(Vec3.format(plan.normalizedSlotAngleDegrees))|\(familyMode)"

            let solids: [(layerIndex: Int, mesh: ViewportFlatShadedMesh)] = await Self.offMain {
                let contours = ViewportGeometryCache.shared.stackedContours(model: model, plan: familyPlan)
                let cutouts = InterlockedSlotCutoutGenerator.slotPaths(
                    for: familyPlan,
                    crossing: familyCrossing,
                    bounds: plan.bounds,
                    mode: familyMode,
                    width: plan.slotWidth,
                    angleDegrees: plan.normalizedSlotAngleDegrees
                )
                return contours.layers.indices.compactMap { layerIndex in
                    ViewportGeometryCache.shared.solidMesh(key: "\(planKey)|interlocked|\(slotKey)|\(layerIndex)") {
                        interlockedMesh(contours: contours, layerIndex: layerIndex, cutouts: cutouts, materialThickness: plan.materialThickness)
                    }.map { (layerIndex, $0) }
                }
            }

            let colorIndex = family.familyIndex % Self.solidPalette.count
            for (layerIndex, renderMesh) in solids {
                guard let mesh = await meshResource(from: renderMesh) else { continue }
                let selected = highlightedAssemblyStep == .stacked(familyIndex: family.familyIndex, layerIndex: layerIndex)
                let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)])
                entity.name = Self.solidName(kind: "stacked", familyIndex: family.familyIndex, layerIndex: layerIndex, colorIndex: colorIndex)
                container.addChild(entity)
            }
        }

        return container.children.isEmpty ? nil : container
    }

    private func interlockedMesh(
        contours: StackedSliceContours,
        layerIndex: Int,
        cutouts: [[SlicePath2D]],
        materialThickness: Double
    ) -> ViewportFlatShadedMesh? {
        guard contours.layers.indices.contains(layerIndex) else {
            return nil
        }
        let layer = contours.layers[layerIndex]
        let layerCutouts = cutouts.indices.contains(layerIndex) ? cutouts[layerIndex] : []
        return ViewportSliceSolidRenderData.meshWithRectangularCutouts(
            outerPaths: layer.paths,
            cutoutPaths: layerCutouts,
            materialThickness: materialThickness,
            scenePoint: { scenePoint($0, axis: contours.axis, position: layer.position) },
            normal: axisNormal(contours.axis)
        )
    }

    @MainActor
    private func makeThreeDSolidEntity(model: MeshSummary, plan: ThreeDSlicePlan) async -> Entity? {
        guard model.bounds != nil else {
            return nil
        }
        let container = Entity()
        container.name = "3D slice solid preview"
        // 3D Slices = the model cut into contiguous layers along one axis, each
        // layer PRESERVING the true 3D surface (a printable layered mesh — NOT a
        // waffle, NOT flat plates). Show exactly what the STL/OBJ export builds.
        let layers: [SliceMeshExportLayer] = await Self.offMain {
            ThreeDSliceMeshExportBuilder.layers(plan: plan, model: model)
        }
        for (layerIndex, layer) in layers.enumerated() {
            guard let mesh = await meshResource(from: layer.mesh) else { continue }
            let colorIndex = layerIndex % Self.solidPalette.count
            let selected = highlightedAssemblyStep == .stacked(familyIndex: 0, layerIndex: layerIndex)
            let entity = ModelEntity(
                mesh: mesh,
                materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)]
            )
            entity.name = Self.solidName(kind: "stacked", familyIndex: 0, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    /// Structures (Manifold infill): render the generated watertight mesh layers
    /// flat-shaded, the SAME `SliceMeshExportLayer` geometry the STL/OBJ
    /// exporters write — so what you see is what you export.
    @MainActor
    private func makeStructureSolidEntity(plan: StructureMeshPlan) async -> Entity? {
        let container = Entity()
        container.name = "Structures infill preview"
        for (layerIndex, layer) in plan.layers.enumerated() {
            guard let mesh = await meshResource(from: layer.mesh) else { continue }
            let colorIndex = layerIndex % Self.solidPalette.count
            let entity = ModelEntity(
                mesh: mesh,
                materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: false)]
            )
            entity.name = Self.solidName(kind: "structures", familyIndex: 0, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }
        return container.children.isEmpty ? nil : container
    }

    /// Inflatables membrane: render the generated membrane mesh flat-shaded,
    /// using the same geometry the STL/OBJ exporters write.
    @MainActor
    private func makeInflatablesSolidEntity(plan: InflatablesPlan) async -> Entity? {
        let container = Entity()
        container.name = "Inflatables membrane preview"

        if inflatableViewMode == .target {
            return await makeInflatablesTargetEntity(ghosted: false)
        }

        if inflatableViewMode == .compare,
           let target = await makeInflatablesTargetEntity(ghosted: true) {
            container.addChild(target)
        }

        let panelLayers = InflatablesMeshExportBuilder.panelRenderLayers(plan: plan)
        if !panelLayers.isEmpty {
            for layer in panelLayers {
                guard let mesh = await meshResource(from: layer.mesh) else { continue }
                let selected = layer.panelID == selectedInflatablePanelID
                let entity = ModelEntity(
                    mesh: mesh,
                    materials: [sliceSolidMaterial(base: inflatablePanelColor(panelIndex: layer.panelIndex, panelID: layer.panelID, plan: plan), selected: selected)]
                )
                entity.name = Self.solidName(
                    kind: "inflatables",
                    familyIndex: 0,
                    layerIndex: layer.panelIndex,
                    colorIndex: layer.panelIndex
                )
                container.addChild(entity)
            }
            return container.children.isEmpty ? nil : container
        }

        guard let renderMesh = InflatablesMeshExportBuilder.renderMesh(plan: plan),
              let mesh = await meshResource(from: renderMesh) else {
            return nil
        }
        let entity = ModelEntity(
            mesh: mesh,
            materials: [sliceSolidMaterial(base: Self.solidPalette[4], selected: false)]
        )
        entity.name = Self.solidName(kind: "inflatables", familyIndex: 0, layerIndex: 0, colorIndex: 4)
        container.addChild(entity)
        return container
    }

    @MainActor
    private func makeInflatablesTargetEntity(ghosted: Bool) async -> Entity? {
        guard let model else { return nil }
        let renderMesh = ViewportMeshRenderData.smoothShadedMesh(from: model.geometry)
        guard let mesh = await meshResource(from: renderMesh) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [modelMaterial(ghosted: ghosted)])
        entity.name = ghosted ? "Inflatables target ghost" : "Inflatables target"
        return entity
    }

    /// MotherMold inspection: each part is a separate entity translated along
    /// its measured pull axis when exploded. The master remains at the origin.
    @MainActor
    private func makeMotherMoldEntity(plan: MotherMoldPlan) async -> Entity? {
        let container = Entity()
        container.name = "MotherMold parts preview"
        let offsets = MotherMoldPreviewLayout.offsets(for: plan, exploded: motherMoldExploded)
        let artifactOffsets = MotherMoldPreviewLayout.artifactOffsets(for: plan, exploded: motherMoldExploded)
        var entitiesByPartName: [String: Entity] = [:]
        if motherMoldVisibleLayers.contains(.moldParts) {
            for (index, part) in plan.parts.enumerated() {
                if let motherMoldIsolatedPartName, part.name != motherMoldIsolatedPartName { continue }
                let renderMesh = ViewportMeshRenderData.flatShadedMesh(from: part.geometry)
                guard let mesh = await meshResource(from: renderMesh) else { continue }
                let colorIndex = index % Self.solidPalette.count
                let entity = ModelEntity(
                    mesh: mesh,
                    materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: false)]
                )
                entity.name = "mothermold|\(part.name)"
                if index < offsets.count {
                    entity.position = SIMD3<Float>(
                        Float(offsets[index].x),
                        Float(offsets[index].y),
                        Float(offsets[index].z)
                    )
                }
                entitiesByPartName[part.name] = entity
                container.addChild(entity)
            }
        }

        if motherMoldVisibleLayers.contains(.preparedMaster), let prepared = plan.preparedMaster {
            await addMotherMoldArtifact(prepared, layer: .preparedMaster, offset: Vec3(x: 0, y: 0, z: 0), to: container)
        }
        if motherMoldVisibleLayers.contains(.asPouredLiner), let liner = plan.asPouredLiner {
            await addMotherMoldArtifact(liner, layer: .asPouredLiner, offset: Vec3(x: 0, y: 0, z: 0), to: container)
        }
        if motherMoldVisibleLayers.contains(.productionLiner), let liner = plan.productionLiner {
            await addMotherMoldArtifact(liner, layer: .productionLiner, offset: Vec3(x: 0, y: 0, z: 0), to: container)
        }
        for artifact in plan.fixtureArtifacts {
            let layer: MotherMoldPreviewLayer = switch artifact.role {
            case .castingFunnel, .productionVentFormer: .flowPaths
            default: .mountHardware
            }
            guard motherMoldVisibleLayers.contains(layer) else { continue }
            await addMotherMoldArtifact(
                artifact,
                layer: layer,
                offset: artifactOffsets[artifact.id] ?? Vec3(x: 0, y: 0, z: 0),
                to: container
            )
        }
        if motherMoldVisibleLayers.contains(.supportCradles) {
            for artifact in plan.supportArtifacts {
                await addMotherMoldArtifact(
                    artifact,
                    layer: .supportCradles,
                    offset: artifactOffsets[artifact.id] ?? Vec3(x: 0, y: 0, z: 0),
                    to: container
                )
            }
        }

        if motherMoldShowUndercuts {
            let extent = plan.parts.compactMap(\.bounds).reduce(0.0) { current, bounds in
                max(current, max(
                    bounds.max.x - bounds.min.x,
                    max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
                ))
            }
            let markerRadius = Float(max(0.6, extent * 0.012))
            let markerMaterial = SimpleMaterial(
                color: NSColor.systemRed.withAlphaComponent(0.9),
                roughness: 0.65,
                isMetallic: false
            )
            for report in plan.undercutReports {
                if let motherMoldIsolatedPartName, report.partName != motherMoldIsolatedPartName { continue }
                guard let partEntity = entitiesByPartName[report.partName] else { continue }
                for (regionIndex, region) in report.regions.enumerated() {
                    let marker = ModelEntity(
                        mesh: .generateSphere(radius: markerRadius),
                        materials: [markerMaterial]
                    )
                    marker.name = "mothermold-undercut|\(report.partName)|\(regionIndex)"
                    marker.position = SIMD3<Float>(
                        Float(region.point.x),
                        Float(region.point.y),
                        Float(region.point.z)
                    )
                    partEntity.addChild(marker)
                }
            }
        }

        return container.children.isEmpty ? nil : container
    }

    @MainActor
    private func addMotherMoldArtifact(
        _ artifact: ToolingArtifact,
        layer: MotherMoldPreviewLayer,
        offset: Vec3,
        to container: Entity
    ) async {
        let renderMesh = ViewportMeshRenderData.flatShadedMesh(from: artifact.geometry)
        guard let mesh = await meshResource(from: renderMesh) else { return }
        let entity = ModelEntity(
            mesh: mesh,
            materials: [sliceSolidMaterial(base: motherMoldColor(for: layer), selected: false)]
        )
        entity.name = "mothermold-artifact|\(artifact.id.rawValue)"
        let position = MotherMoldPreviewLayout.artifactPosition(for: artifact, offset: offset)
        entity.position = SIMD3<Float>(
            Float(position.x),
            Float(position.y),
            Float(position.z)
        )
        container.addChild(entity)
    }

    // MARK: - Issue markers (Model Health)

    fileprivate static let issueMarkersPrefix = "Issue markers|"
    private static let issueMarkerPrefix = "issuemarker|"

    /// Which selection / container the in-place marker pass last styled, so
    /// materials and draw order only change when the selection does (the
    /// per-frame work is just the constant-screen-size scale).
    private final class IssueMarkerTracker {
        var container: ObjectIdentifier?
        var selection: String?
    }
    @State private var issueMarkerTracker = IssueMarkerTracker()

    private var visibleIssueSites: [OpeningCapper.Site] {
        issueMarkersVisible ? issueSites : []
    }

    private var issueMarkersFingerprint: String {
        var hasher = Hasher()
        for site in visibleIssueSites {
            hasher.combine(site.id)
            hasher.combine(site.kind.rawValue)
            hasher.combine(site.position.x.bitPattern)
            hasher.combine(site.position.y.bitPattern)
            hasher.combine(site.position.z.bitPattern)
        }
        return "\(visibleIssueSites.count)|\(hasher.finalize())"
    }

    /// Always-on-top marker material: unlit, blended (so it draws after the
    /// opaque model) and ignoring depth, so a marker inside a cup or behind
    /// the surface still shows.
    private static func issueMarkerMaterial(_ color: NSColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color.withAlphaComponent(1))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.readsDepth = false
        material.writesDepth = false
        return material
    }

    private static let issueOutlineMaterial = issueMarkerMaterial(NSColor(calibratedWhite: 0.06, alpha: 1), opacity: 0.88)
    private static let issueSelectedOutlineMaterial = issueMarkerMaterial(.white, opacity: 0.98)

    @MainActor
    private func makeIssueMarkersEntity(fingerprint: String) -> Entity {
        let container = Entity()
        container.name = Self.issueMarkersPrefix + fingerprint
        // Unit spheres; the in-place pass scales each marker to a constant
        // on-screen size for the current camera.
        let sphere = MeshResource.generateSphere(radius: 1)
        for site in visibleIssueSites {
            let marker = Entity()
            marker.name = Self.issueMarkerPrefix + site.id
            marker.position = simdPoint(site.position)
            // Selected only: a dark ring round the white outline, so the
            // selection reads on light and dark models alike.
            let halo = ModelEntity(mesh: sphere, materials: [Self.issueOutlineMaterial])
            halo.name = "halo"
            halo.scale = SIMD3<Float>(repeating: 1.6)
            halo.isEnabled = false
            let outline = ModelEntity(mesh: sphere, materials: [Self.issueOutlineMaterial])
            outline.name = "outline"
            outline.scale = SIMD3<Float>(repeating: 1.3)
            let fill = ModelEntity(
                mesh: sphere,
                materials: [Self.issueMarkerMaterial(IssueMarkers.color(for: site.kind), opacity: 0.96)]
            )
            fill.name = "fill"
            marker.addChild(halo)
            marker.addChild(outline)
            marker.addChild(fill)
            container.addChild(marker)
        }
        return container
    }

    @MainActor
    private func refreshIssueMarkersIfNeeded(in roots: some Collection<Entity>) {
        guard let root = roots.first(where: { $0.name == "Imported model root" }) else { return }
        let existing = issueMarkersEntity(in: root)
        let expectedName = visibleIssueSites.isEmpty ? nil : Self.issueMarkersPrefix + issueMarkersFingerprint
        guard existing?.name != expectedName else { return }
        existing?.removeFromParent()
        if expectedName != nil {
            root.addChild(makeIssueMarkersEntity(fingerprint: issueMarkersFingerprint))
        }
    }

    private func issueMarkersEntity(in root: Entity) -> Entity? {
        root.children.first { $0.name.hasPrefix(Self.issueMarkersPrefix) }
    }

    /// Per update pass: every marker keeps the same on-screen size at any zoom
    /// (scaled from its distance to the camera); on a selection change the
    /// selected marker gets the white outline, draws larger and on top.
    @MainActor
    private func applyIssueMarkerState(in roots: some Collection<Entity>) {
        guard !visibleIssueSites.isEmpty,
              let root = roots.first(where: { $0.name == "Imported model root" }),
              let container = issueMarkersEntity(in: root) else { return }
        let bounds = viewportBounds
        let pose = ViewportCamera.pose(bounds: bounds, state: cameraState)
        let sites = Dictionary(visibleIssueSites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let restyle = issueMarkerTracker.container != ObjectIdentifier(container)
            || issueMarkerTracker.selection != selectedIssueSiteID
        for (rank, marker) in container.children.enumerated() {
            guard marker.name.hasPrefix(Self.issueMarkerPrefix),
                  let site = sites[String(marker.name.dropFirst(Self.issueMarkerPrefix.count))] else { continue }
            let selected = site.id == selectedIssueSiteID
            let world = IssueMarkers.worldPosition(site.position, bounds: bounds, modelSpin: cameraState.modelSpin)
            let radius = IssueMarkers.markerRadius(at: world, pose: pose, bounds: bounds, state: cameraState, selected: selected)
            marker.scale = SIMD3<Float>(repeating: Float(radius))
            guard restyle else { continue }
            // Draw order: halo, outline, fill per marker; the selected one last.
            let base = Int32(selected ? 1_000_000 : 3 * rank)
            for child in marker.children {
                guard let model = child as? ModelEntity else { continue }
                switch child.name {
                case "halo":
                    model.isEnabled = selected
                    model.components.set(ModelSortGroupComponent(group: Self.issueMarkerSortGroup, order: base))
                case "outline":
                    model.model?.materials = [selected ? Self.issueSelectedOutlineMaterial : Self.issueOutlineMaterial]
                    model.components.set(ModelSortGroupComponent(group: Self.issueMarkerSortGroup, order: base + 1))
                default:
                    model.components.set(ModelSortGroupComponent(group: Self.issueMarkerSortGroup, order: base + 2))
                }
            }
        }
        issueMarkerTracker.container = ObjectIdentifier(container)
        issueMarkerTracker.selection = selectedIssueSiteID
    }

    private static let issueMarkerSortGroup = ModelSortGroup()

    /// A stationary click: select the marker under the cursor (true), or
    /// deselect on empty space and let the mode's own click run (false).
    private func handleIssueMarkerClick(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard !visibleIssueSites.isEmpty else { return false }
        if let id = IssueMarkers.pick(
            viewPoint: point,
            viewSize: viewSize,
            sites: visibleIssueSites,
            selectedID: selectedIssueSiteID,
            bounds: viewportBounds,
            state: cameraState
        ) {
            onIssueSiteSelect?(id)
            return true
        }
        if selectedIssueSiteID != nil { onIssueSiteSelect?(nil) }
        return false
    }

    /// Fly the camera to frame `site` over ~0.45 s: same view direction, the
    /// site moves to screen centre while the zoom eases to its framing
    /// distance. Any other camera change (drag, scroll, SpaceMouse, a view
    /// preset) stops the flight where it is.
    private func flyToIssueSite(_ site: OpeningCapper.Site) {
        issueFlyTask?.cancel()
        let start = cameraState
        let target = IssueMarkers.focusState(for: site, from: start, bounds: viewportBounds)
        let camera = $cameraState
        issueFlyTask = Task { @MainActor in
            let frames = 27
            let frameNanoseconds: UInt64 = 16_666_667
            var expected = start
            for frame in 1...frames {
                try? await Task.sleep(nanoseconds: frameNanoseconds)
                guard !Task.isCancelled, camera.wrappedValue == expected else { return }
                let next = IssueMarkers.interpolate(from: start, to: target, t: Double(frame) / Double(frames))
                camera.wrappedValue = next
                expected = next
            }
        }
    }

    @ViewBuilder
    private var issueMarkersLegend: some View {
        let kinds = OpeningCapper.Site.Kind.allCases.filter { kind in visibleIssueSites.contains { $0.kind == kind } }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: IssueMarkers.color(for: kind)))
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .frame(width: 8, height: 8)
                    Text(IssueMarkers.label(for: kind))
                }
            }
            Text("Click a marker for details")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Issue markers: " + kinds.map { IssueMarkers.label(for: $0) }.joined(separator: ", "))
    }

    // MARK: - MotherMold live pre-build guides

    private static let motherMoldPrebuildOverlayPrefix = "MotherMold prebuild overlay|"

    @MainActor
    private func makeMotherMoldPrebuildOverlayEntity(
        _ overlay: MotherMoldPrebuildOverlay
    ) -> Entity {
        let container = Entity()
        container.name = Self.motherMoldPrebuildOverlayPrefix + overlay.fingerprint

        for guide in overlay.partingPlanes {
            let tint = motherMoldPrebuildTint(guide.axisTint)
            var fill = UnlitMaterial()
            fill.color = .init(tint: tint.withAlphaComponent(0.20))
            fill.blending = .transparent(opacity: .init(floatLiteral: 1))

            let plane = ModelEntity(
                mesh: .generatePlane(
                    width: Float(guide.width),
                    depth: Float(guide.height)
                ),
                materials: [fill]
            )
            plane.name = "MotherMold \(guide.label)"
            plane.transform = Transform(
                rotation: rotation(
                    from: SIMD3<Float>(0, 1, 0),
                    to: simdPoint(guide.plane.normal)
                ),
                translation: simdPoint(guide.center)
            )
            container.addChild(plane)

            let u = scaled(guide.basisU, guide.width / 2)
            let v = scaled(guide.basisV, guide.height / 2)
            let corners = [
                add(guide.center, add(scaled(u, -1), scaled(v, -1))),
                add(guide.center, add(u, scaled(v, -1))),
                add(guide.center, add(u, v)),
                add(guide.center, add(scaled(u, -1), v))
            ]
            let edgeThickness = max(0.35, Float(max(guide.width, guide.height) * 0.006))
            for index in corners.indices {
                let next = corners[(index + 1) % corners.count]
                if let edge = lineEntity(
                    from: corners[index],
                    to: next,
                    color: tint.withAlphaComponent(0.40),
                    thickness: edgeThickness
                ) {
                    edge.name = "MotherMold \(guide.axisLabel) seam edge"
                    container.addChild(edge)
                }
            }

        }

        let pour = overlay.pourHoleMarker
        let pourColor = NSColor(
            calibratedRed: 0.98,
            green: 0.55,
            blue: 0.08,
            alpha: 0.96
        )
        let pourHeight = max(2, Float(pour.diameter * 0.75))
        let cone = ModelEntity(
            mesh: .generateCone(
                height: pourHeight,
                radius: max(0.75, Float(pour.diameter * 0.34))
            ),
            materials: [UnlitMaterial(color: pourColor)]
        )
        cone.name = "MotherMold pour hole cone"
        cone.transform = Transform(
            rotation: rotation(
                from: SIMD3<Float>(0, 1, 0),
                to: SIMD3<Float>(0, 0, 1)
            ),
            translation: SIMD3<Float>(
                Float(pour.point.x),
                Float(pour.point.y),
                Float(pour.point.z) + pourHeight / 2
            )
        )
        container.addChild(cone)
        addMotherMoldCircle(
            center: add(pour.point, Vec3(x: 0, y: 0, z: 0.45)),
            radius: max(1, pour.diameter / 2),
            color: pourColor,
            thickness: max(0.35, Float(pour.diameter * 0.055)),
            name: "MotherMold pour hole ring",
            to: container
        )

        if let holder = overlay.masterHolderFootprint {
            let holderColor = NSColor(
                calibratedRed: 0.66,
                green: 0.26,
                blue: 0.92,
                alpha: 0.24
            )
            var footprintMaterial = UnlitMaterial()
            footprintMaterial.color = .init(tint: holderColor)
            footprintMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
            let footprint = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3<Float>(
                        Float(holder.width),
                        Float(holder.height),
                        0.45
                    )
                ),
                materials: [footprintMaterial]
            )
            footprint.name = "MotherMold master holder footprint"
            footprint.transform = Transform(
                translation: SIMD3<Float>(
                    Float(holder.center.x),
                    Float(holder.center.y),
                    Float(holder.center.z) + 0.23
                )
            )
            container.addChild(footprint)
            addMotherMoldRectangle(
                center: add(holder.center, Vec3(x: 0, y: 0, z: 0.5)),
                width: holder.width,
                height: holder.height,
                color: holderColor.withAlphaComponent(0.78),
                thickness: max(0.35, Float(max(holder.width, holder.height) * 0.008)),
                name: "MotherMold master holder ring",
                to: container
            )
        }

        if let mount = overlay.masterMountMarker {
            let markerColor = NSColor(
                calibratedRed: 0.05,
                green: 0.78,
                blue: 0.92,
                alpha: 0.96
            )
            let extent = max(
                overlay.partingPlanes.map { max($0.width, $0.height) }.max() ?? 20,
                20
            )
            let stemLength = max(4, extent * 0.16)
            let stemEnd = add(mount.point, scaled(mount.axis, stemLength))
            if let stem = lineEntity(
                from: mount.point,
                to: stemEnd,
                color: markerColor,
                thickness: max(0.55, Float(extent * 0.012))
            ) {
                stem.name = "MotherMold picked master mount axis"
                container.addChild(stem)
            }
            let point = ModelEntity(
                mesh: .generateSphere(radius: max(0.9, Float(extent * 0.025))),
                materials: [UnlitMaterial(color: markerColor)]
            )
            point.name = "MotherMold picked master mount point"
            point.position = simdPoint(mount.point)
            container.addChild(point)
        }

        return container
    }

    @MainActor
    private func refreshMotherMoldPrebuildOverlayIfNeeded(
        in roots: some Collection<Entity>
    ) {
        guard let root = roots.first(where: { $0.name == "Imported model root" })
            ?? roots.first else {
            return
        }
        let existing = motherMoldPrebuildOverlayEntity(in: root)
        let expectedName = motherMoldPrebuildOverlay.map {
            Self.motherMoldPrebuildOverlayPrefix + $0.fingerprint
        }
        guard existing?.name != expectedName else { return }
        existing?.removeFromParent()
        if let motherMoldPrebuildOverlay {
            root.addChild(makeMotherMoldPrebuildOverlayEntity(motherMoldPrebuildOverlay))
        }
    }

    private func motherMoldPrebuildOverlayEntity(in entity: Entity) -> Entity? {
        if entity.name.hasPrefix(Self.motherMoldPrebuildOverlayPrefix) {
            return entity
        }
        for child in entity.children {
            if let match = motherMoldPrebuildOverlayEntity(in: child) {
                return match
            }
        }
        return nil
    }

    private func addMotherMoldCircle(
        center: Vec3,
        radius: Double,
        color: NSColor,
        thickness: Float,
        name: String,
        to container: Entity
    ) {
        let segmentCount = 32
        let points = (0...segmentCount).map { index in
            let angle = Double(index) / Double(segmentCount) * 2 * Double.pi
            return Vec3(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius,
                z: center.z
            )
        }
        for index in 0..<segmentCount {
            if let segment = lineEntity(
                from: points[index],
                to: points[index + 1],
                color: color,
                thickness: thickness
            ) {
                segment.name = name
                container.addChild(segment)
            }
        }
    }

    private func addMotherMoldRectangle(
        center: Vec3,
        width: Double,
        height: Double,
        color: NSColor,
        thickness: Float,
        name: String,
        to container: Entity
    ) {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let corners = [
            Vec3(x: center.x - halfWidth, y: center.y - halfHeight, z: center.z),
            Vec3(x: center.x + halfWidth, y: center.y - halfHeight, z: center.z),
            Vec3(x: center.x + halfWidth, y: center.y + halfHeight, z: center.z),
            Vec3(x: center.x - halfWidth, y: center.y + halfHeight, z: center.z)
        ]
        for index in corners.indices {
            if let edge = lineEntity(
                from: corners[index],
                to: corners[(index + 1) % corners.count],
                color: color,
                thickness: thickness
            ) {
                edge.name = name
                container.addChild(edge)
            }
        }
    }

    private func motherMoldPrebuildTint(
        _ tint: MotherMoldPrebuildOverlay.AxisTint
    ) -> NSColor {
        switch tint {
        case .x:
            return NSColor(
                calibratedRed: 0.94,
                green: 0.18,
                blue: 0.20,
                alpha: 1
            )
        case .y:
            return NSColor(
                calibratedRed: 0.18,
                green: 0.78,
                blue: 0.28,
                alpha: 1
            )
        case .z:
            return NSColor(
                calibratedRed: 0.16,
                green: 0.42,
                blue: 0.98,
                alpha: 1
            )
        }
    }

    private func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    private func scaled(_ value: Vec3, _ factor: Double) -> Vec3 {
        Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor)
    }

    private func motherMoldColor(for layer: MotherMoldPreviewLayer) -> NSColor {
        switch layer {
        case .activeSource: return .lightGray
        case .preparedMaster: return .systemGreen
        case .asPouredLiner: return .systemTeal
        case .productionLiner: return .systemBlue
        case .moldParts: return .systemOrange
        case .mountHardware: return .systemPurple
        case .supportCradles: return .systemYellow
        case .flowPaths: return .systemPink
        }
    }

    @MainActor
    private func applyMotherMoldInspectionTransforms(to entity: Entity) {
        guard let plan = motherMoldPlan else { return }
        let offsets = MotherMoldPreviewLayout.offsets(
            for: plan,
            exploded: motherMoldExploded
        )
        for (index, part) in plan.parts.enumerated() where index < offsets.count {
            guard let partEntity = entity.findEntity(named: "mothermold|\(part.name)") else {
                continue
            }
            partEntity.position = SIMD3<Float>(
                Float(offsets[index].x),
                Float(offsets[index].y),
                Float(offsets[index].z)
            )
        }
        let artifactOffsets = MotherMoldPreviewLayout.artifactOffsets(
            for: plan,
            exploded: motherMoldExploded
        )
        for artifact in plan.fixtureArtifacts + plan.supportArtifacts {
            guard let artifactEntity = entity.findEntity(
                named: "mothermold-artifact|\(artifact.id.rawValue)"
            ) else {
                continue
            }
            let position = MotherMoldPreviewLayout.artifactPosition(
                for: artifact,
                offset: artifactOffsets[artifact.id] ?? Vec3(x: 0, y: 0, z: 0)
            )
            artifactEntity.position = SIMD3<Float>(
                Float(position.x),
                Float(position.y),
                Float(position.z)
            )
        }
    }

    @ViewBuilder
    private var motherMoldPrebuildLegend: some View {
        if let overlay = motherMoldPrebuildOverlay {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(overlay.partingPlanes.enumerated()), id: \.offset) { _, guide in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(nsColor: motherMoldPrebuildTint(guide.axisTint)))
                            .frame(width: 7, height: 7)
                        Text(guide.label)
                    }
                }
                Label("Orange: pour hole", systemImage: "arrowtriangle.down.circle.fill")
                    .foregroundStyle(.orange)
                if overlay.masterHolderFootprint != nil {
                    Label("Purple: master holder footprint", systemImage: "rectangle.dashed")
                        .foregroundStyle(.purple)
                }
                if overlay.masterMountMarker != nil {
                    Label("Cyan: picked master mount", systemImage: "scope")
                        .foregroundStyle(.cyan)
                }
            }
            .font(.caption2)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Live mold guides. "
                    + overlay.partingPlanes.map(\.label).joined(separator: ". ")
                    + ". Orange pour hole."
                    + (overlay.masterHolderFootprint == nil ? "" : " Purple master holder footprint.")
                    + (overlay.masterMountMarker == nil ? "" : " Cyan picked master mount.")
            )
        }
    }

    private var motherMoldLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showImportedModel, motherMoldVisibleLayers.contains(.activeSource) {
                Label("White: active source", systemImage: "cube.transparent")
            }
            if motherMoldVisibleLayers.contains(.preparedMaster), motherMoldPlan?.preparedMaster != nil {
                Label("Green: prepared master", systemImage: "cube.fill")
            }
            if motherMoldVisibleLayers.contains(.asPouredLiner), motherMoldPlan?.asPouredLiner != nil {
                Label("Teal: as-poured liner", systemImage: "drop.fill")
            }
            if motherMoldVisibleLayers.contains(.productionLiner), motherMoldPlan?.productionLiner != nil {
                Label("Blue: production liner", systemImage: "drop.circle.fill")
            }
            if motherMoldVisibleLayers.contains(.moldParts) {
                Label("Colored: printable mold parts", systemImage: "square.stack.3d.up.fill")
            }
            if motherMoldVisibleLayers.contains(.mountHardware) || motherMoldVisibleLayers.contains(.flowPaths) {
                Label("Purple/pink: fixture and flow tooling", systemImage: "wrench.and.screwdriver.fill")
            }
            if motherMoldVisibleLayers.contains(.supportCradles) {
                Label("Yellow: support cradles", systemImage: "tray.full.fill")
            }
            if motherMoldExploded {
                Label("Exploded along demold directions", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if motherMoldShowUndercuts {
                Label("Red: possible undercuts", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption2)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var undercutSplitLegend: some View {
        if let overlay = undercutSplitOverlay {
            VStack(alignment: .leading, spacing: 5) {
                Label("Arrows: measured pull axes", systemImage: "arrow.left.and.right")
                if overlay.regions.contains(where: { $0.severity == .overTolerance }) {
                    Label("Red: deeper than selected tolerance", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if overlay.regions.contains(where: { $0.severity != .overTolerance }) {
                    Label("Amber: nonzero depth or draft advisory", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                }
                if overlay.pieces.contains(where: \.finalMeasurementPasses) {
                    Label("Green outline: final measured pass", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if overlay.paintPatches.contains(where: { $0.mode == .noCut }) {
                    Label("Purple: no-cut source faces", systemImage: "paintbrush.fill")
                        .foregroundStyle(.purple)
                }
                if overlay.paintPatches.contains(where: { $0.mode == .preferredSeam }) {
                    Label("Blue: preferred-seam source faces", systemImage: "paintbrush.pointed.fill")
                        .foregroundStyle(.blue)
                }
                if let hovered = overlay.hoveredRegion {
                    Text(hovered.depthLabel).monospacedDigit()
                }
                if let resolution = overlay.effectiveResolutionMM {
                    Text("Measured at \(String(format: "%.3g", resolution)) mm grid")
                        .foregroundStyle(.secondary)
                }
                if overlay.isStale {
                    Label(UndercutSplitUIWording.staleAdvisory, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    private func inflatablePanelColor(panelIndex: Int, panelID: String?, plan: InflatablesPlan?) -> NSColor {
        switch inflatableViewMode {
        case .inflated, .compare:
            guard let plan,
                  let panelID,
                  let preview = plan.preview,
                  preview.maxDeviationMM > 1.0e-6,
                  let error = preview.panelErrorMM[panelID] else {
                return Self.distinctInflatableColor(index: panelIndex)
            }
            return Self.deviationColor(error / max(preview.maxDeviationMM, 1.0e-6))
        case .panels, .target:
            return Self.distinctInflatableColor(index: panelIndex)
        }
    }

    /// Partition pieces: render each watertight piece flat-shaded (the SAME mesh
    /// the exporter writes), pushed outward from the model centre by the explode
    /// amount so the seams and keys are visible. The offset is preview-only.
    @MainActor
    private func makePartitionSolidEntity(plan: PartitionMeshPlan) async -> Entity? {
        let container = Entity()
        container.name = "Partition pieces preview"
        let center: Vec3? = plan.bounds.map {
            Vec3(x: ($0.min.x + $0.max.x) / 2, y: ($0.min.y + $0.max.y) / 2, z: ($0.min.z + $0.max.z) / 2)
        }
        let extent: Double = {
            guard let b = plan.bounds else { return 0 }
            return max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z))
        }()
        let explodeDistance = partitionExplode * extent * 0.6
        for (index, piece) in plan.pieces.enumerated() {
            let overlayPiece = undercutSplitOverlay?.pieces.indices.contains(index) == true
                ? undercutSplitOverlay?.pieces[index]
                : nil
            if let isolated = undercutSplitOverlay?.isolatedPieceRegionID,
               overlayPiece?.regionID != isolated {
                continue
            }
            guard let mesh = await meshResource(from: piece.mesh) else { continue }
            let colorIndex = (overlayPiece?.colorIndex ?? index) % Self.solidPalette.count
            let entity = ModelEntity(
                mesh: mesh,
                materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: false)]
            )
            entity.name = Self.solidName(kind: "partition", familyIndex: 0, layerIndex: index, colorIndex: colorIndex)
            if let overlayPiece, explodeDistance > 0 {
                entity.position = SIMD3<Float>(
                    Float(overlayPiece.explodeVector.x * explodeDistance * 0.58),
                    Float(overlayPiece.explodeVector.y * explodeDistance * 0.58),
                    Float(overlayPiece.explodeVector.z * explodeDistance * 0.58)
                )
            } else if let center, explodeDistance > 0 {
                let dir = Vec3(x: piece.center.x - center.x, y: piece.center.y - center.y, z: piece.center.z - center.z)
                let len = (dir.x * dir.x + dir.y * dir.y + dir.z * dir.z).squareRoot()
                if len > 1.0e-6 {
                    let f = Float(explodeDistance / len)
                    entity.position = SIMD3<Float>(Float(dir.x) * f, Float(dir.y) * f, Float(dir.z) * f)
                }
            }
            container.addChild(entity)
            if overlayPiece?.finalMeasurementPasses == true {
                let outline = makeBoundsOutlineEntity(
                    bounds: piece.bounds,
                    color: NSColor.systemGreen.withAlphaComponent(0.9),
                    thickness: Float(max(0.35, extent * 0.0028))
                )
                outline.name = "undercut-final-outline|\(overlayPiece?.regionID.rawValue ?? String(index))"
                outline.position = entity.position
                container.addChild(outline)
            }
        }
        return container.children.isEmpty ? nil : container
    }

    private func makeBoundsOutlineEntity(bounds: Bounds3D, color: NSColor, thickness: Float) -> Entity {
        let container = Entity()
        let x0 = bounds.min.x, x1 = bounds.max.x
        let y0 = bounds.min.y, y1 = bounds.max.y
        let z0 = bounds.min.z, z1 = bounds.max.z
        let corners = [
            Vec3(x: x0, y: y0, z: z0), Vec3(x: x1, y: y0, z: z0),
            Vec3(x: x1, y: y1, z: z0), Vec3(x: x0, y: y1, z: z0),
            Vec3(x: x0, y: y0, z: z1), Vec3(x: x1, y: y0, z: z1),
            Vec3(x: x1, y: y1, z: z1), Vec3(x: x0, y: y1, z: z1),
        ]
        for (start, end) in [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ] {
            if let edge = lineEntity(from: corners[start], to: corners[end], color: color, thickness: thickness) {
                container.addChild(edge)
            }
        }
        return container
    }

    /// Measured surfaces and pull-axis glyphs. Geometry is already prepared by
    /// `UndercutSplitOverlay.make`, so this main-actor stage only creates SDK
    /// render resources and never re-runs analysis.
    @MainActor
    private func makeUndercutSplitOverlayEntity(overlay: UndercutSplitOverlay) async -> Entity? {
        let container = Entity()
        container.name = "Split by Undercuts measurements"
        let extent = overlay.bounds.map {
            max($0.max.x - $0.min.x, max($0.max.y - $0.min.y, $0.max.z - $0.min.z))
        } ?? 1
        let explodeScale = partitionExplode * extent * 0.348
        let offsets = Dictionary(uniqueKeysWithValues: overlay.pieces.map { piece in
            (piece.regionID, SIMD3<Float>(
                Float(piece.explodeVector.x * explodeScale),
                Float(piece.explodeVector.y * explodeScale),
                Float(piece.explodeVector.z * explodeScale)
            ))
        })

        for region in overlay.regions {
            if let isolated = overlay.isolatedPieceRegionID, region.pieceRegionID != isolated { continue }
            let color: NSColor = region.severity == .overTolerance
                ? NSColor.systemRed.withAlphaComponent(0.72)
                : NSColor.systemOrange.withAlphaComponent(0.62)
            if let renderMesh = region.renderMesh,
               let mesh = await meshResource(from: renderMesh) {
                let patch = ModelEntity(mesh: mesh, materials: [undercutUnlitMaterial(color: color, opacity: 0.66)])
                patch.name = "undercut-region|\(region.id)"
                patch.position = offsets[region.pieceRegionID] ?? .zero
                container.addChild(patch)
            } else {
                let radius = Float(max(0.8, extent * 0.009))
                let marker = ModelEntity(
                    mesh: .generateSphere(radius: radius),
                    materials: [undercutUnlitMaterial(color: color, opacity: 0.66)]
                )
                marker.name = "undercut-region|\(region.id)"
                let offset = offsets[region.pieceRegionID] ?? .zero
                marker.position = SIMD3<Float>(
                    Float(region.centroid.x) + offset.x,
                    Float(region.centroid.y) + offset.y,
                    Float(region.centroid.z) + offset.z
                )
                container.addChild(marker)
            }
        }

        for patch in overlay.paintPatches {
            guard let mesh = await meshResource(from: patch.renderMesh) else { continue }
            let color: NSColor = patch.mode == .noCut
                ? NSColor.systemPurple.withAlphaComponent(0.84)
                : NSColor.systemBlue.withAlphaComponent(0.78)
            let entity = ModelEntity(
                mesh: mesh,
                materials: [undercutUnlitMaterial(color: color, opacity: 0.78)]
            )
            entity.name = "undercut-paint|\(patch.id)"
            entity.position = offsets[patch.pieceRegionID] ?? .zero
            container.addChild(entity)
        }

        for cut in overlay.cutSurfaces {
            let color = cut.isSelected
                ? NSColor.systemYellow.withAlphaComponent(0.72)
                : (cut.isHovered
                    ? NSColor.systemTeal.withAlphaComponent(0.48)
                    : NSColor.systemTeal.withAlphaComponent(0.01))
            let opacity: Float = cut.isSelected ? 0.72 : (cut.isHovered ? 0.48 : 0.01)
            if let renderMesh = cut.renderMesh,
               let mesh = await meshResource(from: renderMesh) {
                let surface = ModelEntity(mesh: mesh, materials: [undercutUnlitMaterial(color: color, opacity: opacity)])
                surface.name = "undercut-cut|\(cut.nodeID.rawValue)"
                container.addChild(surface)
            } else {
                let planeMesh = MeshResource.generatePlane(
                    width: Float(cut.fallbackExtentMM),
                    height: Float(cut.fallbackExtentMM)
                )
                let surface = ModelEntity(mesh: planeMesh, materials: [undercutUnlitMaterial(color: color, opacity: opacity)])
                surface.name = "undercut-cut|\(cut.nodeID.rawValue)"
                surface.position = SIMD3<Float>(
                    Float(cut.fallbackCenter.x),
                    Float(cut.fallbackCenter.y),
                    Float(cut.fallbackCenter.z)
                )
                surface.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: SIMD3<Float>(Float(cut.plane.normal.x), Float(cut.plane.normal.y), Float(cut.plane.normal.z))
                )
                container.addChild(surface)
            }
        }

        for piece in overlay.pieces {
            if let isolated = overlay.isolatedPieceRegionID, piece.regionID != isolated { continue }
            let axis = SIMD3<Float>(Float(piece.pullAxis.x), Float(piece.pullAxis.y), Float(piece.pullAxis.z))
            let length = Float(max(4, extent * 0.16))
            let radius = Float(max(0.45, extent * 0.0045))
            let offset = offsets[piece.regionID] ?? .zero
            let center = SIMD3<Float>(Float(piece.center.x), Float(piece.center.y), Float(piece.center.z)) + offset
            let material = UnlitMaterial(color: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.92, alpha: 0.95))

            let shaft = ModelEntity(
                mesh: .generateCylinder(height: length * 0.72, radius: radius),
                materials: [material]
            )
            shaft.name = "undercut-pull|\(piece.regionID.rawValue)|shaft"
            shaft.position = center
            shaft.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: axis)
            container.addChild(shaft)

            for sign: Float in [-1, 1] {
                let tip = ModelEntity(
                    mesh: .generateCone(height: length * 0.24, radius: radius * 2.8),
                    materials: [material]
                )
                tip.name = "undercut-pull|\(piece.regionID.rawValue)|tip\(sign)"
                tip.position = center + axis * (sign * length * 0.46)
                tip.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: axis * sign
                )
                container.addChild(tip)
            }
        }

        return container.children.isEmpty ? nil : container
    }

    private func undercutUnlitMaterial(color: NSColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    private func applyUndercutOverlayState(to entity: Entity) {
        for child in entity.children { applyUndercutOverlayState(to: child) }
        guard let modelEntity = entity as? ModelEntity,
              let overlay = undercutSplitOverlay else { return }
        if entity.name.hasPrefix("undercut-cut|") {
            let rawID = String(entity.name.dropFirst("undercut-cut|".count))
            guard let cut = overlay.cutSurfaces.first(where: { $0.nodeID.rawValue == rawID }) else { return }
            let color: NSColor
            let opacity: Float
            if cut.isSelected {
                color = .systemYellow
                opacity = 0.72
            } else if cut.isHovered {
                color = .systemTeal
                opacity = 0.48
            } else {
                color = .systemTeal
                opacity = 0.01
            }
            modelEntity.model?.materials = [undercutUnlitMaterial(color: color, opacity: opacity)]
        } else if entity.name.hasPrefix("undercut-region|") {
            let rawID = String(entity.name.dropFirst("undercut-region|".count))
            guard let region = overlay.regions.first(where: { $0.id == rawID }) else { return }
            let hovered = overlay.hoveredRegionID == rawID
            let color: NSColor = region.severity == .overTolerance ? .systemRed : .systemOrange
            modelEntity.model?.materials = [
                undercutUnlitMaterial(color: color, opacity: hovered ? 0.92 : 0.66)
            ]
        } else if undercutCutEditMode,
                  entity.name.hasPrefix("partitionhandle|"),
                  let index = Int(entity.name.dropFirst("partitionhandle|".count)),
                  overlay.cutSurfaces.indices.contains(index) {
            modelEntity.model?.materials = [
                Self.dowelPinMaterial(selected: overlay.cutSurfaces[index].isSelected)
            ]
        }
    }

    /// Dowel rods rendered through the stacked slices at the stack-global
    /// positions the exports drill, so the preview shows the same pins the
    /// exports cut holes for.
    @MainActor
    private func makeDowelPinsEntity(model: MeshSummary, plan: StackedSlicePlan, settings: DxfExporter.DowelSettings) async -> Entity? {
        let placements: [DowelLayout.Placement] = await Self.offMain {
            ViewportGeometryCache.shared.dowelPlacements(model: model, plan: plan, settings: settings)
        }
        guard !placements.isEmpty else { return nil }
        let container = Entity()
        container.name = "Dowel pins"
        let radius = Float(max(0.5, settings.diameter / 2))
        let material = Self.dowelPinMaterial(selected: false)
        let axis = axisNormal(plan.axis)
        let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: SIMD3<Float>(Float(axis.x), Float(axis.y), Float(axis.z)))
        for placement in placements {
            // Each rod spans only the slices it actually threads.
            guard plan.positions.indices.contains(placement.firstLayer),
                  plan.positions.indices.contains(placement.lastLayer) else { continue }
            let low = plan.positions[placement.firstLayer]
            let high = plan.positions[placement.lastLayer]
            let span = abs(high - low) + plan.materialThickness * 1.4
            let mid = (low + high) / 2
            // No end-cap markers: they read as nail heads (owner). The rod
            // itself — a true prism of its cross-section, or a cylinder for
            // Round — is the whole visual and the whole click target.
            let entity: ModelEntity
            if let outline = settings.shape.outline(center: placement.position, diameter: settings.diameter) {
                // Non-round rods: extrude the actual cross-section so the
                // displayed rod matches the hole that cuts.
                let prism = ViewportSliceSolidRenderData.mesh(
                    paths: [SlicePath2D(points: outline + [outline[0]], closed: true)],
                    materialThickness: span,
                    scenePoint: { scenePoint($0, axis: plan.axis, position: mid) },
                    normal: axis
                )
                guard let prism, let mesh = await meshResource(from: prism) else { continue }
                entity = ModelEntity(mesh: mesh, materials: [material])
                entity.name = Self.dowelPinName(plan: placement.position, mid: mid, kind: "prism")
            } else {
                let mesh = MeshResource.generateCylinder(height: Float(span), radius: radius)
                entity = ModelEntity(mesh: mesh, materials: [material])
                entity.name = Self.dowelPinName(plan: placement.position, mid: mid, kind: "cyl")
                let center = scenePoint(placement.position, axis: plan.axis, position: mid)
                entity.position = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
                entity.orientation = orientation
            }
            container.addChild(entity)
        }
        return container.children.isEmpty ? nil : container
    }

    // MARK: - Dowel editing (3D-pane interaction)

    private static func dowelPinMaterial(selected: Bool) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        // Steel blue against the wood-tan slices: rods were dowel-brown and
        // disappeared into the stack (owner: display "not very good").
        material.baseColor = PhysicallyBasedMaterial.BaseColor(
            tint: selected
                ? NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.10, alpha: 1) // orange selection highlight
                : NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.78, alpha: 1)
        )
        material.roughness = 0.55
        material.metallic = 0.0
        return material
    }

    // MARK: - Slice Direction protractor rings

    private static let ringContainerName = "Slice direction rings"

    /// The two rings (one per tilt axis), sized to clear the model.
    private func sliceDirectionRings(bounds: Bounds3D) -> [SliceDirectionRing] {
        let center = Self.boundsCenter(bounds)
        let halfX = (bounds.max.x - bounds.min.x) / 2
        let halfY = (bounds.max.y - bounds.min.y) / 2
        let halfZ = (bounds.max.z - bounds.min.z) / 2
        let radius = max(1.0, max(halfX, max(halfY, halfZ)) * 1.45)
        let axes = SliceDirection.tiltAxes(for: sliceDirectionTiltBasis)
        let sliceNormal = axisNormal(sliceDirectionTiltBasis)
        return [
            SliceDirectionRing(center: center, radius: radius, tiltAxis: axisNormal(axes.first), sliceAxis: sliceNormal),
            SliceDirectionRing(center: center, radius: radius, tiltAxis: axisNormal(axes.second), sliceAxis: sliceNormal)
        ]
    }

    /// Tick-marked rings + 1°-granular red arc segments (visibility-toggled
    /// in the update pass — no mesh regeneration during a drag) + a handle
    /// sphere per ring.
    @MainActor
    private func makeSliceDirectionRingsEntity(bounds: Bounds3D) -> Entity {
        let container = Entity()
        container.name = Self.ringContainerName
        let rings = sliceDirectionRings(bounds: bounds)
        let ringColor = NSColor(calibratedWhite: 0.25, alpha: 0.85)
        let arcColor = NSColor(calibratedRed: 0.85, green: 0.10, blue: 0.10, alpha: 1)
        let lineThickness = Float(max(0.3, rings[0].radius * 0.004))

        for (ringIndex, ring) in rings.enumerated() {
            // Circle: 5° chords, with radial tick marks (long every 15°).
            for step in 0..<72 {
                let from = ring.point(atDegrees: Double(step) * 5 - 180)
                let to = ring.point(atDegrees: Double(step + 1) * 5 - 180)
                if let chord = lineEntity(from: from, to: to, color: ringColor, thickness: lineThickness) {
                    container.addChild(chord)
                }
                let tickDegrees = Double(step) * 5 - 180
                let tickLength = ring.radius * (step % 3 == 0 ? 0.05 : 0.025)
                let inner = ring.point(atDegrees: tickDegrees)
                let direction = Vec3(
                    x: (inner.x - ring.center.x) / ring.radius,
                    y: (inner.y - ring.center.y) / ring.radius,
                    z: (inner.z - ring.center.z) / ring.radius
                )
                let outer = Vec3(
                    x: inner.x + direction.x * tickLength,
                    y: inner.y + direction.y * tickLength,
                    z: inner.z + direction.z * tickLength
                )
                if let tick = lineEntity(from: inner, to: outer, color: ringColor, thickness: lineThickness) {
                    container.addChild(tick)
                }
            }
            // Swept-angle arc: 1° segments across the draggable range, shown
            // between 0 and the current angle.
            for degree in -45..<45 {
                let from = ring.point(atDegrees: Double(degree))
                let to = ring.point(atDegrees: Double(degree + 1))
                if let segment = lineEntity(from: from, to: to, color: arcColor, thickness: lineThickness * 2.2) {
                    segment.name = "ring\(ringIndex)|arc|\(degree)"
                    segment.isEnabled = false
                    container.addChild(segment)
                }
            }
            // Handle: the grab point, sized relative to the ring.
            let handle = ModelEntity(
                mesh: MeshResource.generateSphere(radius: Float(ring.radius * 0.045)),
                materials: [Self.dowelPinMaterial(selected: false)]
            )
            handle.name = "ring\(ringIndex)|handle"
            container.addChild(handle)
        }
        return container
    }

    /// Per-update ring refresh: handle position + arc visibility for the
    /// current (live or committed) tilt. Pure transform/visibility work.
    private func applySliceDirectionRingAdjustments(to entity: Entity) {
        guard entity.name == "Imported model root",
              let container = entity.children.first(where: { $0.name == Self.ringContainerName }),
              let bounds = (model ?? sliceFrameModel)?.bounds else { return }
        let rings = sliceDirectionRings(bounds: bounds)
        let current = liveSliceTilt ?? sliceTilt
        for child in container.children {
            let fields = child.name.split(separator: "|")
            guard fields.count >= 2, fields[0].hasPrefix("ring"),
                  let ringIndex = Int(fields[0].dropFirst(4)), rings.indices.contains(ringIndex) else { continue }
            let angle = ringIndex == 0 ? current.x : current.y
            if fields[1] == "handle" {
                let position = rings[ringIndex].point(atDegrees: angle)
                child.position = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
            } else if fields[1] == "arc", fields.count == 3, let degree = Int(fields[2]) {
                let low = min(0.0, angle)
                let high = max(0.0, angle)
                child.isEnabled = Double(degree) >= low - 0.5 && Double(degree + 1) <= high + 0.5
            }
        }
    }

    private func handleRingMouseDown(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard sliceDirectionAdjustActive, let bounds = (model ?? sliceFrameModel)?.bounds else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        let rings = sliceDirectionRings(bounds: bounds)
        let current = liveSliceTilt ?? sliceTilt
        var best: (index: Int, distance: Double)?
        for (index, ring) in rings.enumerated() {
            let handleScene = ring.point(atDegrees: index == 0 ? current.x : current.y)
            guard let projected = ViewportDowelRayPicker.project(handleScene, viewSize: viewSize, pose: pose) else { continue }
            let dx = Double(projected.x - point.x)
            let dy = Double(projected.y - point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 20, best.map({ distance < $0.distance }) ?? true {
                best = (index, distance)
            }
        }
        if let best {
            // Handle grab: freeform drag (0.1° readout granularity).
            ringDrag = RingDragState(index: best.index, snapDegrees: 0.1)
            return true
        }

        // No handle under the cursor — grabbing the RING ITSELF constrains
        // the drag to 5° snaps and jumps the handle to the click. Pick the
        // ring whose circle the cursor ray
        // passes nearest.
        guard let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return false }
        var ringHit: (index: Int, degrees: Double, error: Double)?
        for (index, ring) in rings.enumerated() {
            guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: ring.center, planeNormal: ring.tiltAxis),
                  let degrees = ring.degrees(for: hit) else { continue }
            let dx = hit.x - ring.center.x
            let dy = hit.y - ring.center.y
            let dz = hit.z - ring.center.z
            let radial = (dx * dx + dy * dy + dz * dz).squareRoot()
            let error = abs(radial - ring.radius)
            if error < ring.radius * 0.08, degrees >= -47, degrees <= 47,
               ringHit.map({ error < $0.error }) ?? true {
                ringHit = (index, degrees, error)
            }
        }
        guard let ringHit else { return false }
        ringDrag = RingDragState(index: ringHit.index, snapDegrees: 5)
        applyRingAngle(ringHit.degrees, index: ringHit.index, snap: 5)
        return true
    }

    private func handleRingMouseDragged(at point: CGPoint, viewSize: CGSize) {
        guard let drag = ringDrag, let bounds = (model ?? sliceFrameModel)?.bounds else { return }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return }
        let ring = sliceDirectionRings(bounds: bounds)[drag.index]
        guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: ring.center, planeNormal: ring.tiltAxis),
              let rawDegrees = ring.degrees(for: hit) else { return }
        applyRingAngle(rawDegrees, index: drag.index, snap: drag.snapDegrees)
    }

    private func applyRingAngle(_ rawDegrees: Double, index: Int, snap: Double) {
        let clamped = min(45, max(-45, rawDegrees))
        let snapped = (clamped / snap).rounded() * snap
        var pair = liveSliceTilt ?? sliceTilt
        if index == 0 {
            pair.x = snapped
        } else {
            pair.y = snapped
        }
        onSliceTiltPreview?(pair)
    }

    private func handleRingMouseUp() -> Bool {
        guard ringDrag != nil else { return false }
        ringDrag = nil
        if let pair = liveSliceTilt {
            onSliceTiltCommit?(pair)
        }
        return true
    }

    // MARK: - NEO-97 model-rotation rings

    private static let modelRingContainerName = "Model rotation rings"
    /// Blender's axis colors: X red, Y green, Z blue.
    private static let modelRingColors: [NSColor] = [
        NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.18, alpha: 0.95),
        NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.22, alpha: 0.95),
        NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.90, alpha: 0.95)
    ]

    /// One ring per world axis, radii staggered (X in, Z out) so overlapping
    /// circles stay individually clickable. Reference directions chosen so 0°
    /// sits where the next axis points (X ring: 0° at +Y, etc. — arbitrary
    /// but stable; the value readout lives in Object Size).
    private func modelRotationRings(bounds: Bounds3D) -> [ModelRotationRing] {
        let center = Self.boundsCenter(bounds)
        let halfX = (bounds.max.x - bounds.min.x) / 2
        let halfY = (bounds.max.y - bounds.min.y) / 2
        let halfZ = (bounds.max.z - bounds.min.z) / 2
        let base = max(1.0, max(halfX, max(halfY, halfZ)))
        let axes = [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1)]
        let references = [Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1), Vec3(x: 1, y: 0, z: 0)]
        return (0..<3).map { index in
            ModelRotationRing(
                center: center,
                radius: base * (1.25 + 0.12 * Double(index)),
                axis: axes[index],
                reference: references[index]
            )
        }
    }

    /// Axis-colored full circles with tick marks and a handle sphere at the
    /// current rotation component. Like the slice-direction rings, all meshes
    /// build once — the update pass only moves handles.
    @MainActor
    private func makeModelRotationRingsEntity(bounds: Bounds3D) -> Entity {
        let container = Entity()
        container.name = Self.modelRingContainerName
        let rings = modelRotationRings(bounds: bounds)
        for (ringIndex, ring) in rings.enumerated() {
            let color = Self.modelRingColors[ringIndex]
            let lineThickness = Float(max(0.3, ring.radius * 0.004))
            for step in 0..<72 {
                let from = ring.point(atDegrees: Double(step) * 5 - 180)
                let to = ring.point(atDegrees: Double(step + 1) * 5 - 180)
                if let chord = lineEntity(from: from, to: to, color: color, thickness: lineThickness) {
                    container.addChild(chord)
                }
                if step % 3 == 0 {
                    let tickDegrees = Double(step) * 5 - 180
                    let inner = ring.point(atDegrees: tickDegrees)
                    let direction = Vec3(
                        x: (inner.x - ring.center.x) / ring.radius,
                        y: (inner.y - ring.center.y) / ring.radius,
                        z: (inner.z - ring.center.z) / ring.radius
                    )
                    let tickLength = ring.radius * 0.035
                    let outer = Vec3(
                        x: inner.x + direction.x * tickLength,
                        y: inner.y + direction.y * tickLength,
                        z: inner.z + direction.z * tickLength
                    )
                    if let tick = lineEntity(from: inner, to: outer, color: color, thickness: lineThickness) {
                        container.addChild(tick)
                    }
                }
            }
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.roughness = 0.5
            let handle = ModelEntity(
                mesh: MeshResource.generateSphere(radius: Float(ring.radius * 0.04)),
                materials: [material]
            )
            handle.name = "modelring\(ringIndex)|handle"
            container.addChild(handle)
        }
        return container
    }

    /// Per-update refresh: park each ring's grab knob at its 0° reference. The
    /// rings are fixed world-axis circles and a drag now applies a true
    /// world-axis rotation (not a per-ring Euler angle), so there's no
    /// meaningful "angle around this ring" to point the handle at — the model
    /// rotating live is the feedback, and the exact angles read out in Object
    /// Size.
    private func applyModelRotationRingAdjustments(to entity: Entity) {
        guard entity.name == "Imported model root",
              let container = entity.children.first(where: { $0.name == Self.modelRingContainerName }),
              let bounds = (model ?? sliceFrameModel)?.bounds else { return }
        let rings = modelRotationRings(bounds: bounds)
        for child in container.children {
            let fields = child.name.split(separator: "|")
            guard fields.count == 2, fields[0].hasPrefix("modelring"), fields[1] == "handle",
                  let ringIndex = Int(fields[0].dropFirst(9)), rings.indices.contains(ringIndex) else { continue }
            let position = rings[ringIndex].point(atDegrees: 0)
            child.position = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
        }
    }

    private func handleModelRingMouseDown(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard modelRotationAdjustActive, let bounds = (model ?? sliceFrameModel)?.bounds else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        let rings = modelRotationRings(bounds: bounds)
        let current = liveModelRotationPreviewDegrees ?? bakedModelRotationDegrees

        // Handle grab first: freeform 0.1° drag. Knobs sit at each ring's 0°.
        var bestHandle: (index: Int, distance: Double)?
        for (index, ring) in rings.enumerated() {
            let handleScene = ring.point(atDegrees: 0)
            guard let projected = ViewportDowelRayPicker.project(handleScene, viewSize: viewSize, pose: pose) else { continue }
            let dx = Double(projected.x - point.x)
            let dy = Double(projected.y - point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 20, bestHandle.map({ distance < $0.distance }) ?? true {
                bestHandle = (index, distance)
            }
        }
        guard let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return false }
        if let bestHandle {
            let ring = rings[bestHandle.index]
            guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: ring.center, planeNormal: ring.axis),
                  let grab = ring.degrees(for: hit) else { return false }
            modelRingDrag = ModelRingDragState(
                index: bestHandle.index,
                snapDegrees: 0.1,
                grabDegrees: grab,
                startRotation: current
            )
            return true
        }

        // Ring-circle grab: 5° snapped DELTA drag (no jump).
        var ringHit: (index: Int, degrees: Double, error: Double)?
        for (index, ring) in rings.enumerated() {
            guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: ring.center, planeNormal: ring.axis),
                  let degrees = ring.degrees(for: hit) else { continue }
            let dx = hit.x - ring.center.x
            let dy = hit.y - ring.center.y
            let dz = hit.z - ring.center.z
            let radial = (dx * dx + dy * dy + dz * dz).squareRoot()
            let error = abs(radial - ring.radius)
            if error < ring.radius * 0.06, ringHit.map({ error < $0.error }) ?? true {
                ringHit = (index, degrees, error)
            }
        }
        guard let ringHit else { return false }
        modelRingDrag = ModelRingDragState(
            index: ringHit.index,
            snapDegrees: 5,
            grabDegrees: ringHit.degrees,
            startRotation: current
        )
        return true
    }

    private func handleModelRingMouseDragged(at point: CGPoint, viewSize: CGSize) {
        guard let drag = modelRingDrag, let bounds = (model ?? sliceFrameModel)?.bounds else { return }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return }
        let ring = modelRotationRings(bounds: bounds)[drag.index]
        guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: ring.center, planeNormal: ring.axis),
              let cursorDegrees = ring.degrees(for: hit) else { return }
        // Delta about the ring's world axis (seam-safe + snapped), composed onto
        // the grab-time orientation — a TRUE rotation about the ring, so the
        // model spins about the circle you're dragging.
        let delta = ModelRotationRing.snappedDelta(
            grabDegrees: drag.grabDegrees, cursorDegrees: cursorDegrees, snap: drag.snapDegrees
        )
        let axis: SliceAxis = drag.index == 0 ? .x : (drag.index == 1 ? .y : .z)
        let rotation = SliceFrameTransform.composeWorldAxisRotation(
            start: drag.startRotation, axis: axis, deltaDegrees: delta
        )
        onModelRotationPreview?(rotation)
    }

    private func handleModelRingMouseUp() -> Bool {
        guard modelRingDrag != nil else { return false }
        modelRingDrag = nil
        if let rotation = liveModelRotationPreviewDegrees {
            onModelRotationCommit?(rotation)
        }
        return true
    }

    /// Everything that changes WHICH pins exist (not how the scene around
    /// them looks). When this differs from the built container's name the
    /// update pass swaps just the pins entity.
    private static func dowelPinsKey(settings: DxfExporter.DowelSettings) -> String {
        var parts = [
            Vec3.format(settings.diameter),
            Vec3.format(settings.inset),
            settings.shape.rawValue
        ]
        if let manual = settings.manualPositions, !manual.isEmpty {
            for position in manual {
                parts.append("\(Vec3.format(position.x)),\(Vec3.format(position.y))")
            }
        } else {
            parts.append("auto\(settings.automaticCount)")
        }
        return parts.joined(separator: "|")
    }

    private static let dowelPinsNamePrefix = "Dowel pins#"
    private static let sliceFrameRootName = "Slice frame root"
    private static let importedModelFeatureEdgeCreaseAngleDegrees = 75.0
    /// The dowel-edit placement frame shown during dowel-edit mode and the
    /// markers/trajectory children it carries. Refreshed in-place by
    /// refreshDowelEditPlaneIfNeeded (same coordinator pattern as pins).
    private static let dowelEditPlaneNamePrefix = "Dowel edit plane#"

    /// Swap the pins entity in place when dowel placement changed — a dowel
    /// edit must NOT rebuild the whole scene (~45 slice solids); it only
    /// touches a handful of rod entities. The coordinator re-checks after
    /// each build so edits landing mid-build aren't lost.
    private func refreshDowelPinsIfNeeded(in entities: some Collection<Entity>) {
        guard let root = entities.first(where: { $0.name == "Imported model root" }) else { return }
        // Pins live under the slice-frame container (counter-rotated when a
        // Slice Direction tilt is active) — swapping them anywhere else
        // produced world-oriented duplicates beside the stale tilted copy.
        guard let sliceRoot = root.children.first(where: { $0.name == Self.sliceFrameRootName }) else { return }
        let coordinator = dowelPinsCoordinator
        if let model = sliceFrameModel ?? model, let plan = slicePlans.first, let dowelSettings, dowelSettings.enabled {
            coordinator.latest = (model, plan, dowelSettings, Self.dowelPinsKey(settings: dowelSettings))
        } else {
            coordinator.latest = nil
        }

        let existing = sliceRoot.children.first { $0.name.hasPrefix(Self.dowelPinsNamePrefix) }
        let existingKey = existing.map { String($0.name.dropFirst(Self.dowelPinsNamePrefix.count)) }
        if existingKey == coordinator.latest?.key { return }
        guard !coordinator.inFlight else { return }
        coordinator.inFlight = true

        Task { @MainActor in
            defer { coordinator.inFlight = false }
            // Loop: another edit may land while a build is in flight.
            while true {
                let current = sliceRoot.children.first { $0.name.hasPrefix(Self.dowelPinsNamePrefix) }
                let currentKey = current.map { String($0.name.dropFirst(Self.dowelPinsNamePrefix.count)) }
                guard let job = coordinator.latest else {
                    current?.removeFromParent()
                    return
                }
                if currentKey == job.key { return }
                let pins = await makeDowelPinsEntity(model: job.model, plan: job.plan, settings: job.settings)
                current?.removeFromParent()
                if let pins {
                    pins.name = Self.dowelPinsNamePrefix + job.key
                    sliceRoot.addChild(pins)
                }
                if coordinator.latest?.key == job.key { return }
            }
        }
    }

    // MARK: - Dowel edit placement frame

    /// Swap the edit-plane entity in place when placement changes — the same
    /// coordinator pattern as refreshDowelPinsIfNeeded so edits land without
    /// rebuilding the full scene.
    private func refreshDowelEditPlaneIfNeeded(in entities: some Collection<Entity>) {
        guard dowelEditMode else { return }
        guard let root = entities.first(where: { $0.name == "Imported model root" }) else { return }
        guard let sliceRoot = root.children.first(where: { $0.name == Self.sliceFrameRootName }) else { return }
        let coordinator = dowelEditPlaneCoordinator
        if let model = sliceFrameModel ?? model, let plan = slicePlans.first, let dowelSettings, dowelSettings.enabled {
            coordinator.latest = (model, plan, dowelSettings, Self.dowelPinsKey(settings: dowelSettings))
        } else {
            coordinator.latest = nil
        }

        let existing = sliceRoot.children.first { $0.name.hasPrefix(Self.dowelEditPlaneNamePrefix) }
        let existingKey = existing.map { String($0.name.dropFirst(Self.dowelEditPlaneNamePrefix.count)) }
        if existingKey == coordinator.latest?.key { return }
        guard !coordinator.inFlight else { return }
        coordinator.inFlight = true

        Task { @MainActor in
            defer { coordinator.inFlight = false }
            while true {
                let current = sliceRoot.children.first { $0.name.hasPrefix(Self.dowelEditPlaneNamePrefix) }
                let currentKey = current.map { String($0.name.dropFirst(Self.dowelEditPlaneNamePrefix.count)) }
                guard let job = coordinator.latest else {
                    current?.removeFromParent()
                    return
                }
                if currentKey == job.key { return }
                let plane = await makeDowelEditPlaneEntity(model: job.model, plan: job.plan, settings: job.settings)
                current?.removeFromParent()
                if let plane {
                    plane.name = Self.dowelEditPlaneNamePrefix + job.key
                    sliceRoot.addChild(plane)
                }
                if coordinator.latest?.key == job.key { return }
            }
        }
    }

    /// Build the outlined placement frame that floats above the model during
    /// dowel editing, with a flat circle marker per placement and a
    /// dashed trajectory line dropping through the stack.
    ///
    /// Plane is perpendicular to the slice axis at
    ///   planeOffset = bounds.max(axisComponent) + materialThickness * 1.2
    /// and spans the model's cross-section × 1.06 on the two plan axes.
    @MainActor
    private func makeDowelEditPlaneEntity(
        model: MeshSummary,
        plan: StackedSlicePlan,
        settings: DxfExporter.DowelSettings
    ) async -> Entity? {
        guard let bounds = model.bounds else { return nil }

        let container = Entity()
        container.name = "Dowel edit plane container"

        // ── Plane geometry ────────────────────────────────────────────────
        // The plane sits above the stack (axis-max side) so it's unobstructed.
        let axisMax: Double
        let planWidth: Double
        let planHeight: Double
        switch plan.axis {
        // Snug to the model's cross-section (was 1.25× — a big translucent
        // sheet read as a confusing wall, especially under a Slice Direction
        // tilt). 1.06× just clears the silhouette so it's clearly "the lid you
        // click to place dowels," not scenery.
        case .x:
            axisMax = bounds.max.x
            planWidth  = (bounds.max.y - bounds.min.y) * 1.06
            planHeight = (bounds.max.z - bounds.min.z) * 1.06
        case .y:
            axisMax = bounds.max.y
            planWidth  = (bounds.max.x - bounds.min.x) * 1.06
            planHeight = (bounds.max.z - bounds.min.z) * 1.06
        case .z:
            axisMax = bounds.max.z
            planWidth  = (bounds.max.x - bounds.min.x) * 1.06
            planHeight = (bounds.max.y - bounds.min.y) * 1.06
        }
        // Closer to the stack so the perpendicular relationship to the rods
        // reads at a glance (was 2× thickness).
        let planePosition = axisMax + plan.materialThickness * 1.2

        // The plane center in plan-space is the model centre projected onto
        // the two non-axis coordinates.
        let planCenterX: Double
        let planCenterY: Double
        switch plan.axis {
        case .x:
            planCenterX = (bounds.min.y + bounds.max.y) / 2
            planCenterY = (bounds.min.z + bounds.max.z) / 2
        case .y:
            planCenterX = (bounds.min.x + bounds.max.x) / 2
            planCenterY = (bounds.min.z + bounds.max.z) / 2
        case .z:
            planCenterX = (bounds.min.x + bounds.max.x) / 2
            planCenterY = (bounds.min.y + bounds.max.y) / 2
        }

        let targetNormal = axisNormal(plan.axis)

        // A solid border gives the user the click/add area without putting a
        // translucent blue sheet over the model.
        let hw = planWidth / 2
        let hh = planHeight / 2
        let borderColor = NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.95, alpha: 0.95)
        let borderThickness = Float(max(0.4, max(planWidth, planHeight) * 0.004))
        // Plane-local axes in plan-space: width runs along the first non-axis
        // coordinate, height along the second (matches planCenterX/Y above).
        let corners = [
            Vec2(x: planCenterX - hw, y: planCenterY - hh),
            Vec2(x: planCenterX + hw, y: planCenterY - hh),
            Vec2(x: planCenterX + hw, y: planCenterY + hh),
            Vec2(x: planCenterX - hw, y: planCenterY + hh)
        ]
        for i in 0..<4 {
            let a = scenePoint(corners[i], axis: plan.axis, position: planePosition)
            let b = scenePoint(corners[(i + 1) % 4], axis: plan.axis, position: planePosition)
            if let edge = lineEntity(from: a, to: b, color: borderColor, thickness: borderThickness) {
                edge.name = "doweleditplane|border\(i)"
                container.addChild(edge)
            }
        }

        // ── Markers + dashed trajectories per placement ───────────────────
        let placements: [DowelLayout.Placement] = await Self.offMain {
            ViewportGeometryCache.shared.dowelPlacements(model: model, plan: plan, settings: settings)
        }

        let markerRadius = Float(max(3.5, settings.diameter * 0.8) / 2)
        let markerThickness = Float(max(0.4, plan.materialThickness * 0.08))
        // Marker cylinder axis = plan.axis; reuse the same orientation quat.
        let axisOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: SIMD3<Float>(Float(targetNormal.x), Float(targetNormal.y), Float(targetNormal.z))
        )
        let markerMaterial = Self.dowelPinMaterial(selected: false)

        for placement in placements {
            guard plan.positions.indices.contains(placement.firstLayer),
                  plan.positions.indices.contains(placement.lastLayer) else { continue }

            // Flat circle (thin cylinder) at planePosition.
            let markerCenter = scenePoint(placement.position, axis: plan.axis, position: planePosition)
            let markerMesh = MeshResource.generateCylinder(height: markerThickness, radius: markerRadius)
            let markerEntity = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
            markerEntity.name = Self.dowelMarkerName(plan: placement.position)
            markerEntity.position = SIMD3<Float>(Float(markerCenter.x), Float(markerCenter.y), Float(markerCenter.z))
            markerEntity.orientation = axisOrientation
            container.addChild(markerEntity)

            // Dashed trajectory from planePosition down to the bottom of the stack.
            let rodTop = planePosition
            let rodBottom = plan.positions[placement.firstLayer] - plan.materialThickness * 0.7
            let dashLength = 2.0
            let gapLength = 2.0
            let dashThickness = Float(max(0.25, plan.materialThickness * 0.04))
            let dashColor = NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.78, alpha: 0.72)
            var dashStart = rodTop
            while dashStart > rodBottom {
                let dashEnd = max(rodBottom, dashStart - dashLength)
                let startPt = scenePoint(placement.position, axis: plan.axis, position: dashStart)
                let endPt   = scenePoint(placement.position, axis: plan.axis, position: dashEnd)
                if let seg = lineEntity(from: startPt, to: endPt, color: dashColor, thickness: dashThickness) {
                    seg.name = "doweldash|\(String(format: "%.2f", placement.position.x))|\(String(format: "%.2f", placement.position.y))"
                    container.addChild(seg)
                }
                dashStart -= dashLength + gapLength
            }
        }

        return container
    }

    /// Name for a flat circle marker entity on the edit plane (must be
    /// discoverable by applyDowelPinAdjustments for orange-selection tinting).
    /// We embed a "dowelpin|" prefix so the existing tinting pass applies.
    private static func dowelMarkerName(plan: Vec2) -> String {
        // Use the same name schema as dowelPinName so applyDowelPinAdjustments
        // picks it up for orange tinting. The marker has no mid/kind slot —
        // we use a fixed mid=0 and kind="marker" to distinguish from rods.
        String(format: "dowelpin|%.4f|%.4f|0.0000|marker|nor", plan.x, plan.y)
    }

    /// Live drag previews as pure entity transforms, applied every update
    /// pass. The model entity carries `preview ∘ baked⁻¹` (it appears at the
    /// in-flight rotation while its mesh stays baked at the committed one);
    /// the slice container carries the same delta composed with the
    /// counter-rotation for the in-flight tilt. With no preview active both
    /// reduce to their at-rest transforms, so this pass is idempotent.
    private func applyLiveOrientationPreviews(to entity: Entity) {
        guard entity.name == "Imported model root" else { return }

        let modelDelta: simd_float4x4
        if let preview = liveModelRotationPreviewDegrees, let pivot = modelRotationPivot {
            modelDelta = SliceFrameTransform.deltaMatrixAboutCenter(
                fromDegrees: bakedModelRotationDegrees,
                toDegrees: preview,
                center: pivot
            )
        } else {
            modelDelta = matrix_identity_float4x4
        }

        for child in entity.children {
            if child.name == "Imported model" || child.name.hasPrefix(Self.issueMarkersPrefix) {
                // Issue markers ride on the model through a live rotation drag.
                child.transform = Transform(matrix: modelDelta)
            } else if child.name == Self.sliceFrameRootName {
                let tilt = liveSliceTiltPreviewDegrees ?? sliceFrameRotationDegrees
                var matrix = modelDelta
                if tilt != Vec3(x: 0, y: 0, z: 0), let center = (model ?? sliceFrameModel)?.bounds.map(Self.boundsCenter) {
                    matrix = modelDelta * SliceFrameTransform.inverseMatrixAboutCenter(
                        rotationDegrees: tilt,
                        center: center
                    )
                }
                child.transform = Transform(matrix: matrix)
            }
        }
    }

    /// Pin names carry the rod's BUILT plan position + axis midpoint so the
    /// update pass can move/tint them in place (no scene rebuild during a
    /// drag): dowelpin|x|y|mid|kind|state.
    private static func dowelPinName(plan: Vec2, mid: Double, kind: String) -> String {
        String(format: "dowelpin|%.4f|%.4f|%.4f|%@|nor", plan.x, plan.y, mid, kind)
    }

    /// In-place pin updates each frame: the dragged rod follows the cursor,
    /// and the selected rod tints orange (state tracked in the name suffix so
    /// camera-drag updates don't churn materials).
    ///
    /// Handles both regular rod entities (kind = "cyl" | "prism") and the
    /// flat marker circles on the edit plane (kind = "marker"). Markers slide
    /// at the plane position during a drag so the user sees the handle move
    /// before the scene rebuilds on mouse-up.
    private func applyDowelPinAdjustments(to entity: Entity) {
        for child in entity.children {
            applyDowelPinAdjustments(to: child)
        }
        guard entity.name.hasPrefix("dowelpin|"), let modelEntity = entity as? ModelEntity else { return }
        let fields = entity.name.split(separator: "|")
        guard fields.count == 6,
              let px = Double(fields[1]),
              let py = Double(fields[2]),
              let mid = Double(fields[3]) else { return }
        let kind = fields[4]
        let appliedState = fields[5]
        let axis = slicePlans.first?.axis ?? .z
        let builtPlan = Vec2(x: px, y: py)

        var effectivePlan = builtPlan
        if let dowelDrag, abs(dowelDrag.from.x - px) < 0.01, abs(dowelDrag.from.y - py) < 0.01 {
            effectivePlan = dowelDrag.current
        }

        let desiredPosition: SIMD3<Float>
        if kind == "marker" {
            // Flat circle on the edit plane: track the plan position at the
            // plane offset (above the stack), not the rod midpoint.
            // planePosition = axisMax + materialThickness*2 (mirrors
            // makeDowelEditPlaneEntity + handleDowelMouseDown).
            let planeOffset = dowelPlaneOffset()
            let markerScene = ViewportDowelRayPicker.scenePoint(effectivePlan, axis: axis, position: planeOffset)
            desiredPosition = SIMD3<Float>(Float(markerScene.x), Float(markerScene.y), Float(markerScene.z))
        } else {
            let built = ViewportDowelRayPicker.scenePoint(builtPlan, axis: axis, position: mid)
            let current = ViewportDowelRayPicker.scenePoint(effectivePlan, axis: axis, position: mid)
            if kind == "cyl" {
                desiredPosition = SIMD3<Float>(Float(current.x), Float(current.y), Float(current.z))
            } else {
                desiredPosition = SIMD3<Float>(
                    Float(current.x - built.x),
                    Float(current.y - built.y),
                    Float(current.z - built.z)
                )
            }
        }
        // Only write on change: a no-op set still marks the entity dirty and
        // keeps the render engine re-evaluating every frame.
        if modelEntity.position != desiredPosition {
            modelEntity.position = desiredPosition
        }

        let isSelected = selectedDowelPlan.map {
            abs($0.x - px) < 0.01 && abs($0.y - py) < 0.01
        } ?? false
        let desiredState = isSelected ? "sel" : "nor"
        if appliedState != Substring(desiredState) {
            let material = Self.dowelPinMaterial(selected: isSelected)
            modelEntity.model?.materials = [material]
            for child in entity.children where child.name == "dowelmarker" {
                (child as? ModelEntity)?.model?.materials = [material]
            }
            entity.name = fields.dropLast().joined(separator: "|") + "|" + desiredState
        }
    }

    /// The axis-position of the dowel-edit plane: axis-max of the model bounds
    /// + 1.2× material thickness. Returns 0 when no model/plan is available (the
    /// caller only uses this when both exist, so the value is never used).
    private func dowelPlaneOffset() -> Double {
        guard let model = sliceFrameModel ?? model,
              let bounds = model.bounds,
              let plan = slicePlans.first else { return 0 }
        let axisMax: Double
        switch plan.axis {
        case .x: axisMax = bounds.max.x
        case .y: axisMax = bounds.max.y
        case .z: axisMax = bounds.max.z
        }
        return axisMax + plan.materialThickness * 1.2
    }

    /// NEO-103: Live slice-drag preview — translate the dragged slice entity
    /// along its axis so the user sees the slice move while dragging.
    /// Mirrors the `applyDowelPinAdjustments` in-place transform pattern.
    private func applySliceDragAdjustments(to entity: Entity) {
        for child in entity.children {
            applySliceDragAdjustments(to: child)
        }
        guard let drag = sliceDrag,
              entity.name.hasPrefix("slicesolid|") else { return }
        let core: String
        if entity.name.hasSuffix("|sel") || entity.name.hasSuffix("|fut") {
            core = String(entity.name.dropLast(4))
        } else {
            core = entity.name
        }
        let fields = core.split(separator: "|")
        guard fields.count == 5,
              let familyIndex = Int(fields[2]),
              let layerIndex = Int(fields[3]),
              familyIndex == 0,
              layerIndex == drag.sliceIndex,
              let plan = slicePlans.first else { return }

        // The slice was built at plan.positions[layerIndex]; we need to
        // translate it by (current - built) along the axis.
        guard drag.sliceIndex < plan.positions.count else { return }
        let builtPos = plan.positions[drag.sliceIndex]
        let delta = Float(drag.currentAxisPosition - builtPos)
        let offset: SIMD3<Float>
        switch drag.axis {
        case .x: offset = SIMD3<Float>(delta, 0, 0)
        case .y: offset = SIMD3<Float>(0, delta, 0)
        case .z: offset = SIMD3<Float>(0, 0, delta)
        }
        if entity.position != offset {
            entity.position = offset
        }
    }

    // MARK: - Partition plane gizmo

    @MainActor
    private func makePartitionHandlesEntity(bounds: Bounds3D) -> Entity? {
        let planes = activePartitionEditingPlanes
        guard !planes.isEmpty else { return nil }
        let container = Entity()
        container.name = "Partition plane handles"
        let dx = bounds.max.x - bounds.min.x, dy = bounds.max.y - bounds.min.y, dz = bounds.max.z - bounds.min.z
        let diagonal = (dx * dx + dy * dy + dz * dz).squareRoot()
        let radius = Float(max(1.0, diagonal * 0.02))
        for (index, plane) in planes.enumerated() {
            let h = PartitionPlaneEditing.handle(for: plane, bounds: bounds)
            let undercutSelected = undercutSplitOverlay?.cutSurfaces.indices.contains(index) == true
                && undercutSplitOverlay?.cutSurfaces[index].isSelected == true
            let entity = ModelEntity(
                mesh: .generateSphere(radius: radius),
                materials: [Self.dowelPinMaterial(selected: undercutSelected || index == selectedPartitionPlaneIndex)]
            )
            entity.name = "partitionhandle|\(index)"
            entity.position = SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z))
            container.addChild(entity)
        }
        return container
    }

    /// Live in-place reposition of the dragged plane handle (no scene rebuild),
    /// mirroring `applySliceDragAdjustments`.
    private func applyPartitionDragAdjustments(to entity: Entity) {
        for child in entity.children {
            applyPartitionDragAdjustments(to: child)
        }
        guard let drag = partitionPlaneDrag, entity.name == "partitionhandle|\(drag.index)" else { return }
        let delta = drag.currentOffset - drag.startOffset
        let pos = SIMD3<Float>(
            Float(drag.handle.x + drag.normal.x * delta),
            Float(drag.handle.y + drag.normal.y * delta),
            Float(drag.handle.z + drag.normal.z * delta)
        )
        if entity.position != pos { entity.position = pos }
    }

    private func handlePartitionMouseDown(at point: CGPoint, viewSize: CGSize) -> Bool {
        let planes = activePartitionEditingPlanes
        guard partitionEditMode || undercutCutEditMode,
              let bounds = undercutSplitOverlay?.bounds ?? model?.bounds,
              !planes.isEmpty else {
            if undercutCutEditMode { onUndercutCutNodeSelect?(nil) }
            else { onPartitionPlaneSelect?(nil) }
            return false
        }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        let pickedIndex: Int? = {
            if undercutCutEditMode,
               let overlay = undercutSplitOverlay,
               let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose),
               let nodeID = overlay.cutNodeID(rayOrigin: ray.origin, rayDirection: ray.direction) {
                return overlay.cutSurfaces.firstIndex(where: { $0.nodeID == nodeID })
            }
            return PartitionPlaneEditing.pickPlaneIndex(
                viewPoint: point,
                viewSize: viewSize,
                pose: pose,
                planes: planes,
                bounds: bounds
            )
        }()
        guard let index = pickedIndex else {
            if undercutCutEditMode { onUndercutCutNodeSelect?(nil) }
            else { onPartitionPlaneSelect?(nil) }
            return false
        }
        if undercutCutEditMode,
           let cut = undercutSplitOverlay?.cutSurfaces.indices.contains(index) == true
                ? undercutSplitOverlay?.cutSurfaces[index]
                : nil {
            onUndercutCutNodeSelect?(cut.nodeID)
        } else {
            onPartitionPlaneSelect?(index)
        }
        let plane = planes[index]
        let range = PartitionPlaneEditing.offsetRange(normal: plane.normal, bounds: bounds)
        partitionPlaneDrag = PartitionPlaneDragState(
            index: index,
            startOffset: plane.offset,
            currentOffset: plane.offset,
            normal: plane.normal,
            handle: PartitionPlaneEditing.handle(for: plane, bounds: bounds),
            rangeMin: range.min,
            rangeMax: range.max
        )
        return true
    }

    private func handlePartitionMouseDragged(at point: CGPoint, viewSize: CGSize) {
        guard var drag = partitionPlaneDrag else { return }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let ray = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return }
        drag.currentOffset = PartitionPlaneEditing.draggedOffset(
            ray: ray,
            normal: drag.normal,
            handle: drag.handle,
            currentOffset: drag.startOffset,
            range: (drag.rangeMin, drag.rangeMax)
        )
        partitionPlaneDrag = drag
    }

    private func handlePartitionMouseUp() -> Bool {
        guard let drag = partitionPlaneDrag else { return false }
        partitionPlaneDrag = nil
        if abs(drag.currentOffset - drag.startOffset) > 0.05 {
            if undercutCutEditMode,
               let cut = undercutSplitOverlay?.cutSurfaces.indices.contains(drag.index) == true
                    ? undercutSplitOverlay?.cutSurfaces[drag.index]
                    : nil,
               let plane = CanonicalPlane(normal: cut.plane.normal, offset: drag.currentOffset) {
                onUndercutCutNodeMoved?(cut.nodeID, plane)
            } else {
                onPartitionPlaneMoved?(drag.index, drag.currentOffset)
            }
        }
        return true
    }

    private func handleUndercutHover(at point: CGPoint?, viewSize: CGSize) {
        guard let point, let overlay = undercutSplitOverlay else {
            onUndercutRegionHover?(nil)
            onUndercutCutNodeHover?(nil)
            return
        }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let ray = ViewportDowelRayPicker.ray(
            viewPoint: point,
            viewSize: viewSize,
            pose: pose
        ) else {
            onUndercutRegionHover?(nil)
            onUndercutCutNodeHover?(nil)
            return
        }
        onUndercutRegionHover?(
            overlay.measuredRegionID(
                rayOrigin: ray.origin,
                rayDirection: ray.direction,
                explodeAmount: partitionExplode
            )
        )
        onUndercutCutNodeHover?(
            overlay.cutNodeID(rayOrigin: ray.origin, rayDirection: ray.direction)
        )
    }

    private func handleUndercutFacePaintClick(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard undercutFacePaintMode != .none,
              let overlay = undercutSplitOverlay else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let ray = ViewportDowelRayPicker.ray(
            viewPoint: point,
            viewSize: viewSize,
            pose: pose
        ), let sourceFaceID = overlay.sourceFaceID(
            rayOrigin: ray.origin,
            rayDirection: ray.direction,
            explodeAmount: partitionExplode
        ) else { return false }
        onUndercutSourceFacePaint?(sourceFaceID)
        return true
    }

    private func handleMotherMoldSurfacePick(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard motherMoldSurfacePickingEnabled,
              !cameraState.isOrthographic,
              let model,
              let bounds = model.bounds else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let hit = MotherMoldSurfacePlacement.hit(
            viewPoint: point,
            viewSize: viewSize,
            pose: pose,
            geometry: model.geometry,
            bounds: bounds,
            modelSpin: cameraState.modelSpin
        ) else { return false }
        onMotherMoldSurfacePick?(hit)
        return true
    }

    private var activePartitionEditingPlanes: [PartitionPlane] {
        if undercutCutEditMode, let overlay = undercutSplitOverlay {
            return overlay.cutSurfaces.map {
                PartitionPlane(normal: $0.plane.normal, offset: $0.plane.offset, isManual: true)
            }
        }
        return partitionManualPlanes
    }

    private func currentDowelPlacements(model: MeshSummary, plan: StackedSlicePlan) -> [DowelLayout.Placement] {
        ViewportGeometryCache.shared.dowelPlacements(model: model, plan: plan, settings: dowelSettings)
    }

    // MARK: - Slice-frame picking transform

    /// The dowel plane, markers, rods, and slice solids are rendered inside
    /// `sliceRoot`, which is counter-rotated by `sliceFrameRotationDegrees`
    /// when a Slice Direction tilt is active. The picking math below is written
    /// in that LOCAL (untilted) frame, so the world cursor ray must be mapped
    /// into it first — otherwise, under a tilt, clicks hit the wrong plane and
    /// add/select/drag all land in the wrong place. `forward` is exactly the
    /// inverse of the `inverseMatrixAboutCenter` that sliceRoot applies.
    private var sliceFrameActive: Bool {
        sliceFrameRotationDegrees != Vec3(x: 0, y: 0, z: 0)
    }

    private var sliceFrameCenter: Vec3? {
        (model ?? sliceFrameModel)?.bounds.map(Self.boundsCenter)
    }

    /// World cursor ray → sliceRoot-local space.
    private func rayInSliceFrame(_ ray: ViewportPickRay) -> ViewportPickRay {
        guard sliceFrameActive, let c = sliceFrameCenter else { return ray }
        let o = SliceFrameTransform.forward(ray.origin, rotationDegrees: sliceFrameRotationDegrees, center: c)
        let tip = SliceFrameTransform.forward(
            Vec3(x: ray.origin.x + ray.direction.x,
                 y: ray.origin.y + ray.direction.y,
                 z: ray.origin.z + ray.direction.z),
            rotationDegrees: sliceFrameRotationDegrees, center: c)
        var d = Vec3(x: tip.x - o.x, y: tip.y - o.y, z: tip.z - o.z)
        let len = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        if len > 1e-12 { d = Vec3(x: d.x / len, y: d.y / len, z: d.z / len) }
        return ViewportPickRay(origin: o, direction: d)
    }

    /// A direction (e.g. camera forward) → sliceRoot-local space (rotation only).
    private func directionInSliceFrame(_ v: Vec3) -> Vec3 {
        guard sliceFrameActive, let c = sliceFrameCenter else { return v }
        let base = SliceFrameTransform.forward(Vec3(x: 0, y: 0, z: 0), rotationDegrees: sliceFrameRotationDegrees, center: c)
        let tip = SliceFrameTransform.forward(v, rotationDegrees: sliceFrameRotationDegrees, center: c)
        return Vec3(x: tip.x - base.x, y: tip.y - base.y, z: tip.z - base.z)
    }

    /// A LOCAL scene point (sliceRoot space) → its WORLD position, for
    /// projecting markers to the screen with the world camera pose.
    private func sliceFrameLocalToWorld(_ p: Vec3) -> Vec3 {
        guard sliceFrameActive, let c = sliceFrameCenter else { return p }
        return SliceFrameTransform.inverse(p, rotationDegrees: sliceFrameRotationDegrees, center: c)
    }

    /// Mouse-down in edit mode. Returns true when the event was consumed
    /// (rod grabbed/removed, or a rod added) so the camera doesn't orbit.
    ///
    /// Interaction order (the outlined dowel placement frame):
    ///   1. Compute the ray → plane intersection (plane ⊥ axis at planeOffset).
    ///      If the ray misses the plane, fall through to camera.
    ///   2. Marker proximity: if a placement's marker center projects within
    ///      14 pt of the cursor → select/drag/ctrl-remove that marker.
    ///      Marker wins over add (prevents spurious adds when clicking near
    ///      an existing rod).
    ///   3. If the plan point is inside the plane rect → add there.
    ///   4. Outside the plane rect → deselect + fall through to camera.
    private func handleDowelMouseDown(at point: CGPoint, viewSize: CGSize, isControlClick: Bool) -> Bool {
        guard dowelEditMode, let model, let plan = slicePlans.first,
              let dowelSettings, dowelSettings.enabled else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let worldRay = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return false }
        // The plane/markers live in the (possibly tilted) slice frame — pick there.
        let ray = rayInSliceFrame(worldRay)

        // Compute the plane offset and extents (same as makeDowelEditPlaneEntity).
        guard let bounds = model.bounds else { return false }
        let axisMax: Double
        let planWidth: Double
        let planHeight: Double
        let planCenterX: Double
        let planCenterY: Double
        switch plan.axis {
        case .x:
            axisMax = bounds.max.x
            planWidth  = (bounds.max.y - bounds.min.y) * 1.06
            planHeight = (bounds.max.z - bounds.min.z) * 1.06
            planCenterX = (bounds.min.y + bounds.max.y) / 2
            planCenterY = (bounds.min.z + bounds.max.z) / 2
        case .y:
            axisMax = bounds.max.y
            planWidth  = (bounds.max.x - bounds.min.x) * 1.06
            planHeight = (bounds.max.z - bounds.min.z) * 1.06
            planCenterX = (bounds.min.x + bounds.max.x) / 2
            planCenterY = (bounds.min.z + bounds.max.z) / 2
        case .z:
            axisMax = bounds.max.z
            planWidth  = (bounds.max.x - bounds.min.x) * 1.06
            planHeight = (bounds.max.y - bounds.min.y) * 1.06
            planCenterX = (bounds.min.x + bounds.max.x) / 2
            planCenterY = (bounds.min.y + bounds.max.y) / 2
        }
        let planePosition = axisMax + plan.materialThickness * 1.2
        let planeNormal = axisNormal(plan.axis)
        let planePoint = scenePoint(Vec2(x: planCenterX, y: planCenterY), axis: plan.axis, position: planePosition)

        // Step 1: ray ∩ plane.
        guard let planeHit = ViewportDowelRayPicker.intersectPlane(
            ray: ray,
            planePoint: planePoint,
            planeNormal: planeNormal
        ) else {
            // Ray misses the plane (edge-on view): fall through to camera.
            return false
        }

        // Plan-space coordinates of the hit point.
        let hitPlan = ViewportDowelRayPicker.planPoint(fromScene: planeHit, axis: plan.axis)

        // Step 2: marker proximity (screen-space 14 pt, same as the rod grab).
        let grabPoints = 14.0
        var closestMarker: (position: Vec2, mid: Double, viewDistance: Double)?
        for placement in currentDowelPlacements(model: model, plan: plan) {
            guard plan.positions.indices.contains(placement.firstLayer),
                  plan.positions.indices.contains(placement.lastLayer) else { continue }
            // Marker is rendered in the slice frame → project its WORLD position.
            let markerCenter = sliceFrameLocalToWorld(scenePoint(placement.position, axis: plan.axis, position: planePosition))
            guard let projected = ViewportDowelRayPicker.project(markerCenter, viewSize: viewSize, pose: pose) else { continue }
            let dx = Double(projected.x - point.x)
            let dy = Double(projected.y - point.y)
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < grabPoints, closestMarker.map({ dist < $0.viewDistance }) ?? true {
                let low = plan.positions[placement.firstLayer]
                let high = plan.positions[placement.lastLayer]
                closestMarker = (placement.position, (low + high) / 2, dist)
            }
        }
        if let marker = closestMarker {
            if isControlClick {
                onDowelRemove?(marker.position)
                onDowelSelect?(nil)
            } else {
                onDowelSelect?(marker.position)
                dowelDrag = DowelDragState(from: marker.position, current: marker.position, midPosition: marker.mid)
            }
            return true
        }

        // Step 3 + 4: click inside the plane rect → add; outside → deselect.
        let halfW = planWidth / 2
        let halfH = planHeight / 2
        let inPlanDX = hitPlan.x - planCenterX
        let inPlanDY = hitPlan.y - planCenterY
        guard !isControlClick,
              abs(inPlanDX) <= halfW,
              abs(inPlanDY) <= halfH else {
            onDowelSelect?(nil)
            return false
        }
        onDowelAdd?(hitPlan)
        return true
    }

    private func handleDowelMouseDragged(at point: CGPoint, viewSize: CGSize) {
        guard var drag = dowelDrag, let plan = slicePlans.first else { return }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let worldRay = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return }
        // Drag plane + anchor are in the slice frame; pick the ray there, and
        // bring the camera forward into the same frame so the drag plane stays
        // square to the view under a Slice Direction tilt.
        let ray = rayInSliceFrame(worldRay)
        let forward = directionInSliceFrame(Vec3(
            x: pose.target.x - pose.position.x,
            y: pose.target.y - pose.position.y,
            z: pose.target.z - pose.position.z
        ))
        let normal = ViewportDowelRayPicker.dragPlaneNormal(rodAxis: axisNormal(plan.axis), cameraForward: forward)
        let anchor = ViewportDowelRayPicker.scenePoint(drag.current, axis: plan.axis, position: drag.midPosition)
        guard let hit = ViewportDowelRayPicker.intersectPlane(ray: ray, planePoint: anchor, planeNormal: normal) else { return }
        drag.current = ViewportDowelRayPicker.planPoint(fromScene: hit, axis: plan.axis)
        dowelDrag = drag
    }

    /// Mouse-up after a rod drag: commit the move (a sub-quarter-millimeter
    /// drag is a click — selection already happened on mouse-down).
    private func handleDowelMouseUp() -> Bool {
        guard let drag = dowelDrag else { return false }
        dowelDrag = nil
        let dx = drag.current.x - drag.from.x
        let dy = drag.current.y - drag.from.y
        if (dx * dx + dy * dy).squareRoot() > 0.25 {
            onDowelMove?(drag.from, drag.current)
        }
        return true
    }

    // MARK: - NEO-104 Seam editing handler

    /// Mouse-down in seam-edit mode: pick the panel-boundary edge of the
    /// folded shape preview whose screen-space projection is closest to the
    /// cursor (within a fixed point radius, like rod grabbing) and toggle a
    /// seam on its 3D mesh edge. Screen-space picking ignores depth — among
    /// edges within the grab radius the screen-closest wins, which matches
    /// the silhouette the user actually clicked in practice. Returns true to
    /// suppress camera rotation.
    private func handleSeamMouseDown(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard seamEditMode, let plan = foldedPanelPlan, !plan.surfaces3D.isEmpty else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        let grabPoints = 10.0
        var best: (edge: FoldedSeamEdge, viewDistance: Double)?
        for surface in plan.surfaces3D where surface.count >= 2 {
            for index in surface.indices {
                let a = surface[index]
                let b = surface[(index + 1) % surface.count]
                guard let distance = ViewportDowelRayPicker.viewDistanceToSegment(
                    viewPoint: point,
                    a: a,
                    b: b,
                    viewSize: viewSize,
                    pose: pose
                ) else { continue }
                if distance < grabPoints, best.map({ distance < $0.viewDistance }) ?? true {
                    best = (FoldedSeamEdge(a: a, b: b), distance)
                }
            }
        }
        guard let best else { return false }
        onSeamEdgeToggle?(best.edge)
        return true
    }

    // MARK: - Inflatables panel selection

    private func handleInflatablePanelClick(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard inflatableViewMode != .target else {
            onInflatablePanelSelect?(nil)
            return false
        }
        guard let plan = inflatablePlan,
              let geometry = plan.preview?.inflatedMesh,
              !plan.panels.isEmpty else {
            onInflatablePanelSelect?(nil)
            return false
        }
        guard let ray = inflatablePickRay(at: point, viewSize: viewSize) else {
            return false
        }

        var best: (panelID: String, rayT: Double)?
        for panel in plan.panels {
            for faceID in panel.sourceFaceIDs {
                let start = faceID * 3
                guard start >= 0, start + 2 < geometry.triangleIndices.count,
                      let a = self.point(geometry.triangleIndices[start], in: geometry.vertices),
                      let b = self.point(geometry.triangleIndices[start + 1], in: geometry.vertices),
                      let c = self.point(geometry.triangleIndices[start + 2], in: geometry.vertices),
                      let rayT = rayTriangleIntersection(ray: ray, a: a, b: b, c: c) else {
                    continue
                }
                if best.map({ rayT < $0.rayT }) ?? true {
                    best = (panel.id, rayT)
                }
            }
        }

        onInflatablePanelSelect?(best?.panelID)
        return best != nil
    }

    private func inflatablePickRay(at point: CGPoint, viewSize: CGSize) -> ViewportPickRay? {
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        if !cameraState.isOrthographic {
            return ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose)
        }

        let width = Double(viewSize.width)
        let height = Double(viewSize.height)
        guard width > 1, height > 1,
              let forward = normalizeVec(subtractVec(pose.target, pose.position)) else {
            return nil
        }

        var right = crossVec(forward, Vec3(x: 0, y: 0, z: 1))
        if lengthVec(right) <= 1.0e-9 {
            right = crossVec(forward, Vec3(x: 0, y: 1, z: 0))
        }
        guard let normalizedRight = normalizeVec(right) else { return nil }
        let up = crossVec(normalizedRight, forward)
        let viewHeight = ViewportCamera.orthographicViewHeight(bounds: viewportBounds, state: cameraState)
        let viewWidth = viewHeight * width / height
        let ndcX = (Double(point.x) / width) * 2 - 1
        let ndcY = (Double(point.y) / height) * 2 - 1

        return ViewportPickRay(
            origin: Vec3(
                x: pose.position.x + normalizedRight.x * ndcX * viewWidth * 0.5 + up.x * ndcY * viewHeight * 0.5,
                y: pose.position.y + normalizedRight.y * ndcX * viewWidth * 0.5 + up.y * ndcY * viewHeight * 0.5,
                z: pose.position.z + normalizedRight.z * ndcX * viewWidth * 0.5 + up.z * ndcY * viewHeight * 0.5
            ),
            direction: forward
        )
    }

    private func rayTriangleIntersection(ray: ViewportPickRay, a: Vec3, b: Vec3, c: Vec3) -> Double? {
        let epsilon = 1.0e-9
        let edge1 = subtractVec(b, a)
        let edge2 = subtractVec(c, a)
        let h = crossVec(ray.direction, edge2)
        let determinant = dotVec(edge1, h)
        guard abs(determinant) > epsilon else { return nil }
        let inverseDeterminant = 1.0 / determinant
        let s = subtractVec(ray.origin, a)
        let u = inverseDeterminant * dotVec(s, h)
        guard u >= -epsilon, u <= 1 + epsilon else { return nil }
        let q = crossVec(s, edge1)
        let v = inverseDeterminant * dotVec(ray.direction, q)
        guard v >= -epsilon, u + v <= 1 + epsilon else { return nil }
        let t = inverseDeterminant * dotVec(edge2, q)
        return t > epsilon ? t : nil
    }

    private func subtractVec(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private func dotVec(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private func lengthVec(_ v: Vec3) -> Double {
        dotVec(v, v).squareRoot()
    }

    private func normalizeVec(_ v: Vec3) -> Vec3? {
        let length = lengthVec(v)
        guard length > 1.0e-9, length.isFinite else { return nil }
        return Vec3(x: v.x / length, y: v.y / length, z: v.z / length)
    }

    private func crossVec(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    // MARK: - NEO-103 Slice editing handlers

    /// Mouse-down in slice-edit mode: hit-test the stacked slice solids by
    /// intersecting the cursor ray with each slice's plane and asking whether
    /// the hit lands ON that slice's material (point-in-contour). The nearest
    /// hit to the camera wins. Returns true to suppress camera rotation —
    /// a miss returns false so the click orbits the camera like normal.
    ///
    /// (The old test measured screen distance to a point that lies on the
    /// cursor ray by construction, so EVERY click "hit" a slice and left-drag
    /// navigation died whenever edit mode was on.)
    private func handleSliceMouseDown(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard sliceEditMode, let plan = slicePlans.first, !plan.positions.isEmpty,
              let model else { return false }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let worldRay = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return false }
        // Slice solids live in the (possibly tilted) slice frame — pick there.
        let ray = rayInSliceFrame(worldRay)

        let axisN = axisNormal(plan.axis)
        // Cache hit: the slice solids on screen were built through this same
        // cache (the closed layers), so this does not recompute contours on
        // the click.
        let contours = ViewportGeometryCache.shared.stackedClosedContours(model: sliceFrameModel ?? model, plan: plan)
        var bestIndex: Int? = nil
        var bestRayT = Double.infinity
        // Slop so a thin slice is still grabbable when the click lands just
        // off its outline (its slab face is thicker than the contour line).
        let slop = max(plan.materialThickness, 1.0)

        for (i, pos) in plan.positions.enumerated() where i < contours.layers.count {
            let planePoint = scenePoint(Vec2(x: 0, y: 0), axis: plan.axis, position: pos)
            guard let hit = ViewportDowelRayPicker.intersectPlane(
                ray: ray, planePoint: planePoint, planeNormal: axisN
            ) else { continue }

            let planHit = ViewportDowelRayPicker.planPoint(fromScene: hit, axis: plan.axis)
            let probes = [
                planHit,
                Vec2(x: planHit.x + slop, y: planHit.y),
                Vec2(x: planHit.x - slop, y: planHit.y),
                Vec2(x: planHit.x, y: planHit.y + slop),
                Vec2(x: planHit.x, y: planHit.y - slop)
            ]
            guard probes.contains(where: {
                !DowelLayout.positionsCovered(by: contours.layers[i], positions: [$0]).isEmpty
            }) else { continue }

            let toHit = Vec3(x: hit.x - ray.origin.x, y: hit.y - ray.origin.y, z: hit.z - ray.origin.z)
            let rayT = toHit.x * ray.direction.x + toHit.y * ray.direction.y + toHit.z * ray.direction.z
            guard rayT > 0 else { continue }
            if rayT < bestRayT {
                bestRayT = rayT
                bestIndex = i
            }
        }

        if let idx = bestIndex {
            onSliceSelect?(idx)
            sliceDrag = SliceDragState(
                sliceIndex: idx,
                startAxisPosition: plan.positions[idx],
                currentAxisPosition: plan.positions[idx],
                axis: plan.axis
            )
            return true
        }

        // No slice hit: deselect.
        onSliceSelect?(nil)
        return false
    }

    /// Mouse-drag in slice-edit mode: update the live axis position of the
    /// dragged slice by intersecting the cursor ray against a plane
    /// perpendicular to the slice axis and through the slice's current position.
    private func handleSliceMouseDragged(at point: CGPoint, viewSize: CGSize) {
        guard var drag = sliceDrag, let plan = slicePlans.first else { return }
        let pose = ViewportCamera.pose(bounds: viewportBounds, state: cameraState)
        guard let worldRay = ViewportDowelRayPicker.ray(viewPoint: point, viewSize: viewSize, pose: pose) else { return }
        let ray = rayInSliceFrame(worldRay)

        // Use a drag plane perpendicular to the slice axis, through the current
        // slice position. Unlike dowel dragging (in-plane), we want the
        // AXIS-component of the intersection — the slice only moves along its axis.
        let axisN = axisNormal(drag.axis)
        let planePoint = scenePoint(Vec2(x: 0, y: 0), axis: drag.axis, position: drag.currentAxisPosition)

        // The drag plane is the slice plane itself (normal = axis normal). The
        // intersection gives us a 3D point; we extract just the axis coordinate.
        guard let hit = ViewportDowelRayPicker.intersectPlane(
            ray: ray, planePoint: planePoint, planeNormal: axisN
        ) else { return }

        let newAxisPos: Double
        switch drag.axis {
        case .x: newAxisPos = hit.x
        case .y: newAxisPos = hit.y
        case .z: newAxisPos = hit.z
        }

        // Clamp to model extent.
        let clamped = max(plan.rangeMin, min(plan.rangeMax, newAxisPos))
        drag.currentAxisPosition = clamped
        sliceDrag = drag
    }

    /// Mouse-up after a slice drag: commit the new position if it moved
    /// more than 0.1 mm (sub-threshold = click, not drag).
    private func handleSliceMouseUp() -> Bool {
        guard let drag = sliceDrag else { return false }
        sliceDrag = nil
        let delta = abs(drag.currentAxisPosition - drag.startAxisPosition)
        if delta > 0.1 {
            onSliceMoveCommit?(drag.sliceIndex, drag.currentAxisPosition)
        }
        return true
    }

    @MainActor
    private func makeRadialSolidEntity(model: MeshSummary, plan: RadialSlicePlan) async -> Entity? {
        // n_radial == 0 degrades to Interlocked.
        if plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return await makeInterlockedSolidEntity(model: model, plan: fallback)
        }
        guard let primary = plan.primary, let bounds = model.bounds else { return nil }
        let container = Entity()
        container.name = "Radial slice solid preview"
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        let planSig = [
            ViewportGeometryCache.planKey(for: primary),
            "\(plan.nRadial)",
            Vec3.format(plan.materialThickness),
            Vec3.format(plan.slotClearance),
            Vec3.format(plan.slotWidth)
        ].joined(separator: "|")

        // Rings + fins from the shared disk+wedge generator — the same part
        // geometry the cut sheet packs and the exports cut, extruded in place.
        let solids: [(kind: String, layerIndex: Int, mesh: ViewportFlatShadedMesh)] = await Self.offMain {
            var result: [(kind: String, layerIndex: Int, mesh: ViewportFlatShadedMesh)] = []
            let parts = RadialPartBuilder.assembly(plan: plan, model: model)
            for disk in parts.disks {
                guard disk.loop.count >= 3 else { continue }
                ViewportGeometryCache.shared.solidMesh(key: "radialdisk|\(planSig)|\(disk.sliceIndex)|\(disk.componentIndex)") {
                    ViewportSliceSolidRenderData.mesh(
                        paths: disk.paths,
                        materialThickness: plan.materialThickness,
                        scenePoint: { scenePoint($0, axis: primary.axis, position: disk.position) },
                        normal: axisNormal(primary.axis)
                    )
                }.map { result.append(("stacked", disk.sliceIndex, $0)) }
            }
            for wedge in parts.wedges {
                guard wedge.loop.count >= 3 else { continue }
                ViewportGeometryCache.shared.solidMesh(key: "radialwedge|\(planSig)|\(wedge.sliceIndex)|\(wedge.componentIndex)") {
                    ViewportSliceSolidRenderData.mesh(
                        paths: wedge.paths,
                        materialThickness: plan.materialThickness,
                        scenePoint: { RadialPartBuilder.wedgeScenePoint($0, center: center, axis: primary.axis, angle: wedge.position) },
                        normal: RadialPartBuilder.wedgePlaneNormal(axis: primary.axis, angle: wedge.position)
                    )
                }.map { result.append(("radial", wedge.sliceIndex, $0)) }
            }
            return result
        }

        for (kind, layerIndex, renderMesh) in solids {
            guard let mesh = await meshResource(from: renderMesh) else { continue }
            let colorIndex = kind == "stacked" ? 0 : 1 // disks orange, fins teal (the interlocked family pairing)
            let selected = kind == "stacked"
                ? highlightedAssemblyStep == .stacked(familyIndex: 0, layerIndex: layerIndex)
                : highlightedAssemblyStep == .radial(layerIndex: layerIndex)
            let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)])
            entity.name = Self.solidName(kind: kind, familyIndex: 0, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    /// Cache key for a curve plan's slotted solids: the slots depend on both
    /// rib families and the slot width.
    private static func curveSolidKey(_ plan: CurveSlicePlan) -> String {
        let spline = plan.controlPoints.map { "\(Vec3.format($0.x)),\(Vec3.format($0.y))" }.joined(separator: ";")
        return "\(ViewportGeometryCache.planKey(for: plan.primary))|\(plan.sliceCount)|\(spline)|\(Vec3.format(plan.slotWidth))"
    }

    @MainActor
    private func makeCurvePrimarySolidEntity(contours: StackedSliceContours, slotted: [[SlicePath2D]], plan: CurveSlicePlan) async -> Entity? {
        let container = Entity()
        container.name = "Curve first-axis solid preview"
        let planKey = Self.curveSolidKey(plan)

        let solids: [(layerIndex: Int, mesh: ViewportFlatShadedMesh)] = await Self.offMain {
            return contours.layers.indices.compactMap { layerIndex in
                ViewportGeometryCache.shared.solidMesh(
                    key: "curveprimary|\(planKey)|\(layerIndex)"
                ) {
                    ViewportSliceSolidRenderData.mesh(
                        paths: slotted[layerIndex],
                        materialThickness: plan.primary.materialThickness,
                        scenePoint: { scenePoint($0, axis: contours.axis, position: contours.layers[layerIndex].position) },
                        normal: axisNormal(contours.axis)
                    )
                }.map { (layerIndex, $0) }
            }
        }

        let colorIndex = 0 // systemOrange
        for (layerIndex, renderMesh) in solids {
            guard let mesh = await meshResource(from: renderMesh) else { continue }
            let selected = highlightedAssemblyStep == .stacked(familyIndex: 0, layerIndex: layerIndex)
            let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)])
            entity.name = Self.solidName(kind: "stacked", familyIndex: 0, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    @MainActor
    private func makeCurveSolidEntity(contours: CurveSliceContours, slotted: [[SlicePath2D]], plan: CurveSlicePlan) async -> Entity? {
        let container = Entity()
        container.name = "Curve slice solid preview"
        let planKey = Self.curveSolidKey(plan)

        let solids: [(layerIndex: Int, mesh: ViewportFlatShadedMesh)] = await Self.offMain {
            return contours.layers.indices.compactMap { layerIndex in
                let layer = contours.layers[layerIndex]
                let normal = Vec3(x: layer.direction.x, y: layer.direction.y, z: 0)
                return ViewportGeometryCache.shared.solidMesh(
                    key: "curve|\(planKey)|\(layerIndex)"
                ) {
                    ViewportSliceSolidRenderData.mesh(
                        paths: slotted[layerIndex],
                        materialThickness: plan.primary.materialThickness,
                        scenePoint: { CurveSliceContourer.scenePoint($0, center: layer.center, inPlaneDirection: layer.normal) },
                        normal: normal
                    )
                }.map { (layerIndex, $0) }
            }
        }

        let colorIndex = 4 // systemGreen
        for (layerIndex, renderMesh) in solids {
            guard let mesh = await meshResource(from: renderMesh) else { continue }
            let selected = highlightedAssemblyStep == .curve(layerIndex: layerIndex)
            let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)])
            entity.name = Self.solidName(kind: "curve", familyIndex: 0, layerIndex: layerIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    @MainActor
    private static func boundsCenter(_ bounds: Bounds3D) -> Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }

    /// Renders the folded panels at their TRUE 3D position on the mesh
    /// surface — the assembled, folded-up shape (a faceted "papercraft"
    /// version of the object), not the flat cut net. Each coplanar panel
    /// group is extruded into a thin plate in its own plane. The flat net is
    /// the cut sheet's job (CutSheetDocument), never the 3D viewport's.
    private func makeFoldedShapeEntity(plan: FoldedPanelPlan) async -> Entity? {
        let container = Entity()
        container.name = "Folded shape preview"

        for (panelIndex, surface) in plan.surfaces3D.enumerated() {
            guard surface.count >= 3, let frame = PanelPlaneFrame(polygon: surface) else {
                continue
            }
            let flat = surface.map(frame.project)
            guard let renderMesh = ViewportSliceSolidRenderData.mesh(
                paths: [SlicePath2D(points: flat, closed: true)],
                materialThickness: previewMaterialThickness,
                scenePoint: frame.unproject,
                normal: frame.normal
            ),
                let mesh = await meshResource(from: renderMesh) else {
                continue
            }
            let selected = highlightedAssemblyStep == .foldedPanel(panelIndex: panelIndex)
            let colorIndex = 5 // systemBlue
            let entity = ModelEntity(mesh: mesh, materials: [sliceSolidMaterial(base: Self.solidPalette[colorIndex], selected: selected)])
            entity.name = Self.solidName(kind: "folded", familyIndex: 0, layerIndex: panelIndex, colorIndex: colorIndex)
            container.addChild(entity)
        }

        return container.children.isEmpty ? nil : container
    }

    private func makeSliceContourEntity(model: MeshSummary, plan: StackedSlicePlan, contours: StackedSliceContours, familyIndex: Int) -> Entity {
        let container = Entity()
        container.name = "Stacked slice contour preview"
        let colors = [Self.cutEdgeColor, Self.cutEdgeColor, Self.cutEdgeColor]
        let baseColor = colors[familyIndex % colors.count]
        for (layerIndex, layer) in contours.layers.enumerated() {
            let selected = highlightedAssemblyStep == .stacked(familyIndex: familyIndex, layerIndex: layerIndex)
            let color = overlayColor(base: baseColor, selected: selected)
            let thickness = overlayThickness(for: model, selected: selected)
            for path in layer.paths {
                addPath(path.points.map { scenePoint($0, axis: plan.axis, position: layer.position) }, to: container, color: color, thickness: thickness)
            }
        }
        return container
    }

    private func makeInterlockedSlotGuideEntity(model: MeshSummary, plan: InterlockedSlicePlan) -> Entity {
        let container = Entity()
        container.name = "Interlocked slot guide preview"
        let thickness = overlayThickness(for: model) * 0.82
        for guide in InterlockedSlotGuideGenerator.guides(for: plan) {
            addPath(guide.points, to: container, color: Self.slotGuideColor, thickness: thickness)
        }
        return container
    }

    private func makeCurveContourEntity(model: MeshSummary, contours: CurveSliceContours) -> Entity {
        let container = Entity()
        container.name = "Curve slice contour preview"
        for (layerIndex, layer) in contours.layers.enumerated() {
            let selected = highlightedAssemblyStep == .curve(layerIndex: layerIndex)
            let color = overlayColor(base: Self.cutEdgeColor, selected: selected)
            let thickness = overlayThickness(for: model, selected: selected)
            for path in layer.paths {
                addPath(
                    path.points.map { CurveSliceContourer.scenePoint($0, center: layer.center, inPlaneDirection: layer.normal) },
                    to: container,
                    color: color,
                    thickness: thickness
                )
            }
        }
        return container
    }

    private func makeGroundShadowEntity(bounds: Bounds3D?) -> Entity? {
        let shadowStrength = ViewportAppearanceSettings.clamped01(appearance.groundShadow)
        guard shadowStrength > 0.001, let bounds else {
            return nil
        }
        // A soft directional shadow on an INVISIBLE ground — no platform.
        // What makes a shadow read as shadow (and not a
        // translucent slab) is the radial alpha falloff to zero at the edge:
        // any constant-alpha geometry reads as a platform regardless of how
        // transparent it is. So: an unlit plane whose opacity comes from a
        // soft radial-gradient texture.
        guard let texture = Self.softShadowTexture() else {
            return nil
        }
        let width = max(1, Float(bounds.max.x - bounds.min.x) * 1.7)
        let depth = max(1, Float(bounds.max.y - bounds.min.y) * 1.7)
        var material = UnlitMaterial()
        material.color = .init(tint: .black)
        material.blending = .transparent(opacity: .init(scale: Float(0.82 * shadowStrength), texture: .init(texture)))
        let mesh = MeshResource.generatePlane(width: width, height: depth)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "Drop shadow"
        // Slight offset away from the key light (key sits at -x,-y) so the
        // shadow reads directional.
        let radius = max(0.5, Float(ViewportCamera.radius(bounds: bounds)))
        entity.position = SIMD3<Float>(
            Float((bounds.min.x + bounds.max.x) / 2) + radius * 0.035,
            Float((bounds.min.y + bounds.max.y) / 2) + radius * 0.045,
            Float(bounds.min.z) - max(0.5, radius * 0.02)
        )
        return entity
    }

    private static var cachedSoftShadowTexture: TextureResource?

    /// Grayscale radial-falloff opacity map: ~0.45 alpha at the center easing
    /// to 0 at the edge (quadratic-smooth profile).
    private static func softShadowTexture() -> TextureResource? {
        if let cachedSoftShadowTexture {
            return cachedSoftShadowTexture
        }
        let size = 256
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let buffer = context.data else {
            return nil
        }
        let bytesPerRow = context.bytesPerRow
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)
        let center = Double(size - 1) / 2
        let maxAlpha = 0.45
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - center) / center
                let dy = (Double(y) - center) / center
                let d2 = dx * dx + dy * dy
                let falloff = max(0, 1 - d2)
                let value = maxAlpha * pow(falloff, 1.8)
                pixels[y * bytesPerRow + x] = UInt8(min(255, max(0, value * 255)))
            }
        }
        guard let image = context.makeImage(),
              let texture = try? TextureResource.generate(
                from: image,
                options: TextureResource.CreateOptions(semantic: .raw)
              ) else {
            return nil
        }
        cachedSoftShadowTexture = texture
        return texture
    }

    private func addPath(_ points: [Vec3], to container: Entity, color: NSColor, thickness: Float) {
        guard points.count >= 2 else {
            return
        }
        for index in 0..<(points.count - 1) {
            if let segment = lineEntity(from: points[index], to: points[index + 1], color: color, thickness: thickness) {
                container.addChild(segment)
            }
        }
    }

    private func lineEntity(from start: Vec3, to end: Vec3, color: NSColor, thickness: Float) -> Entity? {
        let startPoint = simdPoint(start)
        let endPoint = simdPoint(end)
        let delta = endPoint - startPoint
        let length = simd_length(delta)
        guard length > 0 else {
            return nil
        }

        let mesh = MeshResource.generateBox(size: SIMD3<Float>(thickness, length, thickness))
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        entity.transform = Transform(
            rotation: rotation(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta)),
            translation: (startPoint + endPoint) / 2
        )
        return entity
    }

    private func configureLights(in root: Entity) {
        // Three-point directional rig that lights the SLICE/panel solids and the
        // ghosted "Both" shell. (The imported model is MatCap-shaded and ignores
        // these entirely.)
        let keyAmount = ViewportAppearanceSettings.clamped01(appearance.keyLight)
        let fillAmount = ViewportAppearanceSettings.clamped01(appearance.fillLight)
        let rimAmount = ViewportAppearanceSettings.clamped01(appearance.rimLight)
        let keyIntensity = Float(1_200 + 3_200 * keyAmount)
        let fillIntensity = Float(120 + 900 * fillAmount)
        let rimIntensity = Float(300 + 1_500 * rimAmount)
        let key = DirectionalLight()
        key.name = "Viewport key light"
        key.light = DirectionalLightComponent(color: .white, intensity: keyIntensity)
        key.look(at: .zero, from: SIMD3<Float>(-3, -4, 5), relativeTo: nil)
        root.addChild(key)

        let fill = DirectionalLight()
        fill.name = "Viewport fill light"
        fill.light = DirectionalLightComponent(color: NSColor(calibratedWhite: 0.97, alpha: 1), intensity: fillIntensity)
        fill.look(at: .zero, from: SIMD3<Float>(4, 3, 2), relativeTo: nil)
        root.addChild(fill)

        let rim = DirectionalLight()
        rim.name = "Viewport rim light"
        rim.light = DirectionalLightComponent(color: NSColor(calibratedRed: 0.86, green: 0.90, blue: 1.0, alpha: 1), intensity: rimIntensity)
        rim.look(at: .zero, from: SIMD3<Float>(2, 5, 3), relativeTo: nil)
        root.addChild(rim)
    }

    private func makeCameraEntity(bounds: Bounds3D?, state: ViewportCameraState) -> Entity {
        if state.isOrthographic {
            // RealityKit does not expose an OrthographicCamera convenience class;
            // instead we attach OrthographicCameraComponent to a plain Entity.
            let entity = Entity()
            entity.name = Self.cameraName
            configureOrthoCamera(entity, bounds: bounds, state: state)
            return entity
        } else {
            let camera = PerspectiveCamera()
            camera.name = Self.cameraName
            camera.camera = PerspectiveCameraComponent(near: 0.01, far: 100_000, fieldOfViewInDegrees: 42)
            configurePerspCamera(camera, bounds: bounds, state: state)
            return camera
        }
    }

    private func configurePerspCamera(_ camera: PerspectiveCamera, bounds: Bounds3D?, state: ViewportCameraState) {
        applyCameraPose(camera, pose: ViewportCamera.pose(bounds: bounds, state: state))
    }

    /// Applies the sculpture's accumulated roll (state.modelSpin) to the model
    /// root, rotating about the model centre so the object banks in place while
    /// the camera stays upright.
    private func applyModelSpin(_ content: RealityViewCameraContent, bounds: Bounds3D?, state: ViewportCameraState) {
        guard let root = content.entities.compactMap({ $0.findEntity(named: "Imported model root") }).first
        else { return }
        let c: SIMD3<Float>
        if let bounds {
            c = SIMD3<Float>(Float((bounds.min.x + bounds.max.x) / 2),
                             Float((bounds.min.y + bounds.max.y) / 2),
                             Float((bounds.min.z + bounds.max.z) / 2))
        } else {
            c = .zero
        }
        var toC = matrix_identity_float4x4; toC.columns.3 = SIMD4<Float>(c, 1)
        var fromC = matrix_identity_float4x4; fromC.columns.3 = SIMD4<Float>(-c, 1)
        root.transform = Transform(matrix: toC * simd_float4x4(state.modelSpin) * fromC)
    }

    /// Orients the camera from the pose's explicit (right, up, viewAxis) basis
    /// rather than `look(at:upVector:)`, so the camera's screen axes are exactly
    /// the vectors we pan along. Without this, a rolled `look()` up-hint and the
    /// pan frame can disagree and pan drifts diagonally under roll.
    private func applyCameraPose(_ entity: Entity, pose: ViewportCameraPose) {
        guard let viewAxis = normalizeVec(subtractVec(pose.position, pose.target)) else {
            entity.look(at: simdPoint(pose.target), from: simdPoint(pose.position),
                        upVector: simdPoint(pose.up), relativeTo: nil)
            return
        }
        // RealityKit camera looks down -Z, so local +Z = viewAxis (target→camera),
        // +X = right, +Y = up. cross(right, up) == viewAxis, a right-handed basis.
        let right = SIMD3<Float>(Float(pose.right.x), Float(pose.right.y), Float(pose.right.z))
        let up = SIMD3<Float>(Float(pose.up.x), Float(pose.up.y), Float(pose.up.z))
        let zAxis = SIMD3<Float>(Float(viewAxis.x), Float(viewAxis.y), Float(viewAxis.z))
        entity.setOrientation(simd_quatf(float3x3(columns: (right, up, zAxis))), relativeTo: nil)
        entity.setPosition(simdPoint(pose.position), relativeTo: nil)
    }

    private func configureOrthoCamera(_ entity: Entity, bounds: Bounds3D?, state: ViewportCameraState) {
        let pose = ViewportCamera.pose(bounds: bounds, state: state)
        // OrthographicCameraComponent.scale is the world-space HEIGHT visible
        // in the viewport (half the frustum height on each side). We match
        // the framing that the perspective camera achieves at the same distance.
        let viewHeight = ViewportCamera.orthographicViewHeight(bounds: bounds, state: state)
        var ortho = OrthographicCameraComponent()
        ortho.near = -100_000
        ortho.far = 100_000
        ortho.scale = Float(max(0.001, viewHeight))
        entity.components.set(ortho)
        applyCameraPose(entity, pose: pose)
    }

    /// Legacy shim kept for any internal call sites that still expect the old name.
    private func configureCamera(_ camera: PerspectiveCamera, bounds: Bounds3D?, state: ViewportCameraState) {
        configurePerspCamera(camera, bounds: bounds, state: state)
    }

    /// PBR material for the ghosted "Both" shell and the rare MatCap-load-failure
    /// fallback. The solid model is MatCap-shaded, so this is not the primary look.
    private func modelMaterial(ghosted: Bool) -> PhysicallyBasedMaterial {
        let base = appearance.objectColor
        var material = PhysicallyBasedMaterial()
        material.baseColor = PhysicallyBasedMaterial.BaseColor(
            tint: NSColor(
                calibratedRed: min(max(base.red, 0), 1),
                green: min(max(base.green, 0), 1),
                blue: min(max(base.blue, 0), 1),
                alpha: ghosted ? 0.18 : 1
            )
        )
        material.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: ghosted ? 0.72 : 0.55)
        material.metallic = 0.0
        if !ghosted {
            material.specular = PhysicallyBasedMaterial.Specular(floatLiteral: 0.18)
            material.clearcoat = PhysicallyBasedMaterial.Clearcoat(floatLiteral: 0.06)
            material.clearcoatRoughness = PhysicallyBasedMaterial.ClearcoatRoughness(floatLiteral: 0.56)
        }
        if ghosted {
            // Faint shell over the solid slices — enough to read the target
            // surface in "Both" without washing the slices out.
            material.blending = .transparent(opacity: 0.18)
        }
        return material
    }

    private func sliceSolidMaterial(base: NSColor, selected: Bool, future: Bool = false) -> PhysicallyBasedMaterial {
        // Selecting a step highlights THAT slice (yellow); steps already
        // placed stay solid; steps AFTER the selection render as faint ghosts
        // so paging through assembly shows the object being built.
        let futureOpacity: CGFloat = 0.08
        let opacity: CGFloat = future ? futureOpacity : renderStyle.faceAlpha
        let tint = selected
            ? NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.40, alpha: opacity)
            : fabricationPanelTint(base: base, opacity: opacity)

        var material = PhysicallyBasedMaterial()
        material.baseColor = PhysicallyBasedMaterial.BaseColor(tint: tint)
        material.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: renderStyle.roughness)
        material.metallic = 0.0
        // Render both faces so a slice's side walls are never see-through from
        // the back (that was the "transparent edges").
        material.faceCulling = .none
        if opacity < 1.0 {
            material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(floatLiteral: Float(opacity)))
        }
        return material
    }

    private func fabricationPanelTint(base: NSColor, opacity: CGFloat) -> NSColor {
        // Apply the render style's material base color tinted toward the slice
        // family hue (controlled by style.familyBlend). Plastic uses a fixed
        // orange (familyBlend==0); wood modes blend the material base with
        // the per-family palette hue so different families still read as
        // distinct slices without washing out the material look.
        let styleBase = renderStyle.materialBaseColor
        let styleBaseRgb = styleBase.usingColorSpace(.deviceRGB) ?? styleBase
        let blend = renderStyle.familyBlend
        let normalized = base.usingColorSpace(.deviceRGB) ?? base
        return NSColor(
            calibratedRed: min(1.0, styleBaseRgb.redComponent * (1 - blend) + normalized.redComponent * blend),
            green: min(1.0, styleBaseRgb.greenComponent * (1 - blend) + normalized.greenComponent * blend),
            blue: min(1.0, styleBaseRgb.blueComponent * (1 - blend) + normalized.blueComponent * blend),
            alpha: opacity
        )
    }

    @MainActor
    private func meshResource(from renderMesh: ViewportFlatShadedMesh) async -> MeshResource? {
        var descriptor = MeshDescriptor(name: "Viewport slice solid mesh")
        descriptor.positions = MeshBuffers.Positions(renderMesh.vertices.map(simdPoint))
        descriptor.normals = MeshBuffers.Normals(renderMesh.normals.map(simdPoint))
        descriptor.primitives = .triangles(renderMesh.triangleIndices.compactMap { UInt32(exactly: $0) })
        return try? await MeshResource(from: [descriptor])
    }

    private func scenePoint(_ point: Vec2, axis: SliceAxis, position: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: position, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: position, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: position)
        }
    }

    private func axisNormal(_ axis: SliceAxis) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: 1, y: 0, z: 0)
        case .y:
            return Vec3(x: 0, y: 1, z: 0)
        case .z:
            return Vec3(x: 0, y: 0, z: 1)
        }
    }

    private func point(_ index: Int32, in points: [Vec3]) -> Vec3? {
        guard index >= 0, Int(index) < points.count else {
            return nil
        }
        return points[Int(index)]
    }

    private func edgeThickness(for model: MeshSummary) -> Float {
        max(0.035, Float(ViewportCamera.radius(bounds: model.bounds)) * 0.0035)
    }

    private func overlayThickness(for model: MeshSummary, selected: Bool = false) -> Float {
        let base = max(0.055, Float(ViewportCamera.radius(bounds: model.bounds)) * 0.005)
        return selected ? base * 2.35 : base * 1.18
    }

    private func overlayColor(base: NSColor, selected: Bool) -> NSColor {
        if selected {
            return NSColor.systemYellow.withAlphaComponent(1)
        }
        return base.withAlphaComponent(highlightedAssemblyStep == nil ? 1.0 : 0.42)
    }

    private func simdPoint(_ point: Vec3) -> SIMD3<Float> {
        SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
    }

    private func rotation(from source: SIMD3<Float>, to target: SIMD3<Float>) -> simd_quatf {
        let dot = simd_dot(source, target)
        if dot > 0.9999 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }
        let axis = simd_normalize(simd_cross(source, target))
        return simd_quatf(angle: acos(dot), axis: axis)
    }

    private static let cameraName = "Viewport camera"
    private static let cutEdgeColor = NSColor(calibratedRed: 0.62, green: 0.02, blue: 0.00, alpha: 1.0)
    private static let slotGuideColor = NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.95, alpha: 0.82)
}

private struct ViewportInteractionCaptureView: NSViewRepresentable {
    var rotateCamera: (Double, Double) -> Void
    var panCamera: (Double, Double) -> Void
    var zoomCamera: (Double) -> Void
    var mouseClicked: ((CGPoint, CGSize) -> Bool)?
    var mouseMoved: ((CGPoint?, CGSize) -> Void)?
    var dowelMouseDown: ((CGPoint, CGSize, Bool) -> Bool)?
    var dowelMouseDragged: ((CGPoint, CGSize) -> Void)?
    var dowelMouseUp: (() -> Bool)?
    var dowelDeleteKey: (() -> Void)?
    var escapeKey: (() -> Void)? = nil

    func makeNSView(context: Context) -> ViewportInteractionCaptureNSView {
        let view = ViewportInteractionCaptureNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ViewportInteractionCaptureNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ViewportInteractionCaptureNSView) {
        view.rotateCamera = rotateCamera
        view.panCamera = panCamera
        view.zoomCamera = zoomCamera
        view.mouseClicked = mouseClicked
        view.mouseMovedCallback = mouseMoved
        view.dowelMouseDown = dowelMouseDown
        view.dowelMouseDragged = dowelMouseDragged
        view.dowelMouseUp = dowelMouseUp
        view.dowelDeleteKey = dowelDeleteKey
        view.escapeKey = escapeKey
    }
}

private final class ViewportInteractionCaptureNSView: NSView {
    var rotateCamera: ((Double, Double) -> Void)?
    var panCamera: ((Double, Double) -> Void)?
    var zoomCamera: ((Double) -> Void)?
    var mouseClicked: ((CGPoint, CGSize) -> Bool)?
    var mouseMovedCallback: ((CGPoint?, CGSize) -> Void)?
    var dowelMouseDown: ((CGPoint, CGSize, Bool) -> Bool)?
    var dowelMouseDragged: ((CGPoint, CGSize) -> Void)?
    var dowelMouseUp: (() -> Bool)?
    var dowelDeleteKey: (() -> Void)?
    var escapeKey: (() -> Void)?

    /// True while a dowel rod owns the current mouse drag — the camera must
    /// not orbit underneath it.
    private var dowelDragActive = false
    private var pendingClickPoint: CGPoint?
    private var mouseMovedSinceDown = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        mouseMovedCallback?(convert(event.locationInWindow, from: nil), bounds.size)
    }

    override func mouseExited(with event: NSEvent) {
        mouseMovedCallback?(nil, bounds.size)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pendingClickPoint = point
        mouseMovedSinceDown = false
        guard let dowelMouseDown else { return }
        let isControl = event.modifierFlags.contains(.control)
        if dowelMouseDown(point, bounds.size, isControl) {
            dowelDragActive = true
            pendingClickPoint = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dowelDragActive {
            dowelDragActive = false
            _ = dowelMouseUp?()
            return
        }
        defer { pendingClickPoint = nil }
        guard let pendingClickPoint, !mouseMovedSinceDown else { return }
        _ = mouseClicked?(pendingClickPoint, bounds.size)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete.
        if let dowelDeleteKey, event.keyCode == 51 || event.keyCode == 117 {
            dowelDeleteKey()
            return
        }
        // 53 = Escape (deselects an issue marker).
        if let escapeKey, event.keyCode == 53 {
            escapeKey()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if dowelDragActive {
            let point = convert(event.locationInWindow, from: nil)
            dowelMouseDragged?(point, bounds.size)
            return
        }
        mouseMovedSinceDown = true
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
            panCamera?(Double(event.deltaX), Double(event.deltaY))
        } else {
            rotateCamera?(Double(event.deltaX), Double(event.deltaY))
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        panCamera?(Double(event.deltaX), Double(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        zoomCamera?(Double(event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        zoomCamera?(Double(-event.magnification * 400))
    }
}
