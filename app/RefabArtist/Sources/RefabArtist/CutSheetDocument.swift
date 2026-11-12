import Foundation

/// The screen-facing cut-sheet model:
///
/// - one part per disconnected piece of a slice, labeled `slice` /
///   `slice-piece` (stacked) or `Axis-slice(-piece)` (two-family modes)
/// - blue cut loops, red scored guide lines, red part labels
/// - parts packed onto sheets to use as much of each sheet as possible
///
/// This is the GUI preview's data source, and the document the SVG, PDF and
/// most DXF exports render (see FlatPartExport).
struct CutSheetDocument {
    /// Sheet size in mm (0 when the layout has no sheet bounds).
    var sheetWidth: Double
    var sheetHeight: Double
    var sheets: [CutSheetSheet]
    /// Cheap identity for view-side render caches: rebuilds always bump it, so
    /// two documents with the same revision are the same built artifact.
    var revision: Int
    /// What the sheet says about its parts beside them: Curve and Radial
    /// Slices pieces left out, joined only among themselves or narrower than
    /// the stock; Interlocked slot relief with nothing to cut.
    var notes: [String] = []
    /// Slot relief discs actually cut out of the parts (Interlocked Slot
    /// relief). Where slots merge there are no inside corners, so none are.
    var reliefCutCount = 0

    var partCount: Int {
        sheets.reduce(0) { $0 + $1.parts.count }
    }

    var overflowingPartCount: Int {
        sheets.reduce(0) { $0 + $1.parts.filter(\.overflowsSheet).count }
    }

    var sheetPartCounts: [Int] {
        sheets.map(\.parts.count)
    }

    /// Fraction of total sheet area covered by part bounding boxes.
    var utilization: Double {
        guard sheetWidth > 0, sheetHeight > 0, !sheets.isEmpty else { return 0 }
        let partArea = sheets.reduce(0.0) { total, sheet in
            total + sheet.parts.reduce(0.0) { sum, part in
                sum + (part.bounds.max.x - part.bounds.min.x) * (part.bounds.max.y - part.bounds.min.y)
            }
        }
        return partArea / (sheetWidth * sheetHeight * Double(sheets.count))
    }

    func part(labeled label: String) -> CutSheetPart? {
        for sheet in sheets {
            if let part = sheet.parts.first(where: { $0.label == label }) {
                return part
            }
        }
        return nil
    }
}

extension CutSheetDocument: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}

struct CutSheetSheet: Identifiable {
    /// 1-based sheet number, as printed on the sheet.
    var index: Int
    var parts: [CutSheetPart]

    var id: Int { index }
}

struct CutSheetPart: Identifiable {
    /// Part label: `"14"`, `"14-2"`, `"Z-6"`, `"Y-3-1"`.
    var label: String
    /// Matching assembly-step index (AssemblyStep.index), when the part
    /// corresponds to a planned step. Used to link sheet clicks <-> steps.
    var stepIndex: Int?
    /// Closed cut loops in sheet-local mm (first loops are outers, holes
    /// follow); rendered as blue cut lines, filled even-odd.
    var cutLoops: [[Vec2]]
    /// Open cut segments (fragments from imperfect meshes) — still cuts (blue).
    var openCuts: [[Vec2]]
    /// Open scored assembly-guide polylines (red), e.g. where the next slice
    /// sits (stacked assembly guides).
    var guideLines: [[Vec2]]
    /// Drill/relief circles (blue).
    var circles: [SvgExporter.Circle]
    /// Non-round dowel hole outlines (blue closed cut loops) — the
    /// Square/Pencil/Cross/Slot shapes.
    var holeLoops: [[Vec2]] = []
    /// Placed bounding box in sheet-local mm.
    var bounds: SvgExporter.Bounds2
    /// Engrave-safe label anchor (sheet-local mm): the part's pole of
    /// inaccessibility, so the label NEVER crosses the cut outline.
    var labelAnchor: Vec2
    /// Radius of the largest circle inscribed at `labelAnchor` — the label is
    /// sized to fit inside it.
    var labelRadius: Double
    /// True when the part could not fit the sheet content area.
    var overflowsSheet: Bool
    /// Red error fill — e.g. "Notches split part".
    var isError = false
    /// Blue detached-piece fill — it will fall off.
    var isDetached = false
    /// True when the packer rotated this part 90 degrees onto the sheet.
    var rotatedOnSheet = false
    /// The part's origin in PLAN (slice-plane) coordinates — with
    /// `rotatedOnSheet` this inverts a sheet point back to the plan, which is
    /// how click-to-place dowels map a sheet click to a rod position.
    var planMin = Vec2(x: 0, y: 0)
    /// Where the part's plan coordinates sit in the model, when its builder
    /// knows (Curve Slices, Radial Slices).
    var planeFrame: PartPlaneFrame?
    /// Fold lines (Folded Panels), drawn on their own fold layer: cut through
    /// as dashes when `foldsArePerforated`, scored full length otherwise.
    var foldLines: [[Vec2]] = []
    var foldsArePerforated = false
    /// A Folded Panels net's panels: where each sits on the model once the
    /// net is folded up, and which are joined by a fold.
    var foldedPanels: [CutSheetFoldedPanel] = []
    var foldedHinges: [FoldedNetHinge] = []

    var id: String { label }

    /// The packer's placement: a point in PLAN coordinates to SHEET
    /// coordinates (the inverse of `planPoint(fromSheetPoint:)`).
    func sheetPoint(fromPlanPoint p: Vec2) -> Vec2 {
        let local = Vec2(x: p.x - planMin.x, y: p.y - planMin.y)
        if rotatedOnSheet {
            let localHeight = bounds.max.x - bounds.min.x
            return Vec2(x: bounds.min.x + localHeight - local.y, y: bounds.min.y + local.x)
        }
        return Vec2(x: bounds.min.x + local.x, y: bounds.min.y + local.y)
    }

    /// Inverse of the packer's placement: a point in SHEET coordinates back
    /// to PLAN (slice-plane) coordinates.
    func planPoint(fromSheetPoint p: Vec2) -> Vec2 {
        let local: Vec2
        if rotatedOnSheet {
            let localHeight = bounds.max.x - bounds.min.x
            local = Vec2(x: p.y - bounds.min.y, y: localHeight - (p.x - bounds.min.x))
        } else {
            local = Vec2(x: p.x - bounds.min.x, y: p.y - bounds.min.y)
        }
        return Vec2(x: local.x + planMin.x, y: local.y + planMin.y)
    }
}

/// One panel of a Folded Panels net, in its part's plan (net) coordinates:
/// `frame` puts it where it sits on the model once the net is folded up,
/// `inward` points from its outside face into its stock, `region` is the
/// panel and `features` the joint features that stand out of it.
struct CutSheetFoldedPanel {
    var frame: PartPlaneFrame
    var inward: Vec3
    var region: [Vec2]
    var features: [[Vec2]]
}

/// The plane a flat part's plan (section) coordinates live in: the plan point
/// `p` is the model point `origin + p.x * xAxis + p.y * yAxis`.
struct PartPlaneFrame: Equatable {
    var origin: Vec3
    var xAxis: Vec3
    var yAxis: Vec3

    func modelPoint(_ p: Vec2) -> Vec3 {
        Vec3(
            x: origin.x + xAxis.x * p.x + yAxis.x * p.y,
            y: origin.y + xAxis.y * p.x + yAxis.y * p.y,
            z: origin.z + xAxis.z * p.x + yAxis.z * p.y
        )
    }
}

extension PartPlaneFrame {
    /// A stacked section at `position` along `axis`, in the stacked
    /// projection: (y, z), (x, z) or (x, y).
    init(axis: SliceAxis, position: Double) {
        let x = Vec3(x: 1, y: 0, z: 0)
        let y = Vec3(x: 0, y: 1, z: 0)
        let z = Vec3(x: 0, y: 0, z: 1)
        switch axis {
        case .x:
            self.init(origin: Vec3(x: position, y: 0, z: 0), xAxis: y, yAxis: z)
        case .y:
            self.init(origin: Vec3(x: 0, y: position, z: 0), xAxis: x, yAxis: z)
        case .z:
            self.init(origin: Vec3(x: 0, y: 0, z: position), xAxis: x, yAxis: y)
        }
    }

    /// A vertical section through `center` whose plan x runs along
    /// `inPlaneDirection` and plan y is the height.
    init(center: Vec3, inPlaneDirection: Vec2) {
        self.init(
            origin: Vec3(x: center.x, y: center.y, z: 0),
            xAxis: Vec3(x: inPlaneDirection.x, y: inPlaneDirection.y, z: 0),
            yAxis: Vec3(x: 0, y: 0, z: 1)
        )
    }
}

enum CutSheetLayoutBuilder {
    // MARK: - Mode builders

    static func document(
        stacked contours: StackedSliceContours,
        settings: ExportLayoutSettings,
        dowels: DxfExporter.DowelSettings?,
        revision: Int
    ) -> CutSheetDocument {
        let layers = contours.layers
        let guidesByLayer = stackedGuides(for: layers)

        // Stack-global dowel positions (rods must thread the whole stack);
        // each piece only gets the holes its material covers.
        let dowelPositions = DowelLayout.globalPositions(layers: layers, settings: dowels)
        let dowelRadius = (dowels?.diameter ?? 0) / 2
        let dowelShape = dowels?.shape ?? .round

        var parts: [UnplacedPart] = []
        for (layerIndex, layer) in layers.enumerated() {
            let islands = islandize(paths: layer.paths)
            let guides = guidesByLayer.indices.contains(layerIndex) ? guidesByLayer[layerIndex] : []
            for (islandIndex, island) in islands.enumerated() {
                let label = islands.count > 1
                    ? "\(layerIndex + 1)-\(islandIndex + 1)"
                    : "\(layerIndex + 1)"
                let coveredDowels: [Vec2]
                if let outer = island.loops.first, !dowelPositions.isEmpty {
                    coveredDowels = dowelPositions.filter { DowelLayout.contains(outer, point: $0) }
                } else {
                    coveredDowels = []
                }
                let part = unplacedPart(
                    label: label,
                    stepIndex: layerIndex + 1,
                    island: island,
                    guides: guides,
                    planCircles: dowelShape == .round ? coveredDowels.map { ($0, dowelRadius) } : [],
                    planHoleLoops: dowelShape == .round ? [] : coveredDowels.compactMap {
                        dowelShape.outline(center: $0, diameter: dowels?.diameter ?? 0)
                    }
                )
                parts.append(part)
            }
        }
        return pack(parts, settings: settings, revision: revision)
    }

    static func document(
        interlocked plan: InterlockedSlicePlan,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        guard let pieces = interlockedPieces(plan: plan, model: model) else {
            return emptyDocument(settings: settings, revision: revision)
        }
        var document = pack(pieces.parts, settings: settings, revision: revision)
        document.reliefCutCount = pieces.reliefCutCount
        document.notes = [interlockedReliefNote(plan: plan, reliefCutCount: pieces.reliefCutCount)].compactMap { $0 }
        return document
    }

    /// How many slot relief discs the Interlocked parts of `plan` cut: what
    /// the cut sheet, and so every vector export, carries.
    static func interlockedReliefCutCount(plan: InterlockedSlicePlan, model: MeshSummary) -> Int {
        guard plan.slotRelief.enabled, plan.slotRelief.diameter > 0 else { return 0 }
        return interlockedPieces(plan: plan, model: model)?.reliefCutCount ?? 0
    }

    /// What the sheet and the CLI say when Slot relief is on but cuts
    /// nothing; nil when it cuts something or is off.
    static func interlockedReliefNote(plan: InterlockedSlicePlan, reliefCutCount: Int) -> String? {
        guard plan.slotRelief.enabled, reliefCutCount == 0 else { return nil }
        guard plan.slotRelief.diameter > 0 else {
            return "Slot relief is on, but the tool diameter is 0, so no relief is cut."
        }
        if InterlockedPartBuilder.slotsMerge(plan: plan) {
            return "The slots are as wide as the slice spacing and merge into one cut, so Slot relief has no inside corners to cut."
        }
        return "No slot has an inside corner for Slot relief to cut."
    }

    /// The Interlocked parts before packing, in true mm, and how many relief
    /// discs were cut out of them.
    private static func interlockedPieces(
        plan: InterlockedSlicePlan,
        model: MeshSummary
    ) -> (parts: [UnplacedPart], reliefCutCount: Int)? {
        guard let bounds = model.bounds else {
            return nil
        }
        // Real slotted cross-sections (slots spliced into the boundary, only
        // where the crossing family actually intersects) from
        // `InterlockedPartBuilder` — NOT the legacy full-bbox slot stripes.
        let letterParts = InterlockedPartBuilder.parts(
            plan: plan,
            model: model,
            includeDisconnectedComponents: true
        )
        let fit = InterlockedPartBuilder.pageFitScale(plan: plan, bounds: bounds)
        guard fit > 0 else {
            return nil
        }
        let toMm = 1.0 / fit  // loops are page-fit inches: invert to true model mm

        // Drop uncuttable slivers BEFORE counting pieces so the suffix
        // numbering reflects what's actually on the sheets.
        let cuttableParts = letterParts.filter { letterPart in
            let width = (letterPart.bounds.max.x - letterPart.bounds.min.x) * toMm
            let height = (letterPart.bounds.max.y - letterPart.bounds.min.y) * toMm
            return max(width, height) >= minimumPartDimension
                && abs(signedArea(letterPart.loop)) * toMm * toMm >= minimumPartArea
        }

        // Renumber surviving pieces consecutively per (family, slice) so the
        // suffixes reflect what's actually on the sheets.
        var survivingPieces: [String: [Int]] = [:]
        for part in cuttableParts {
            survivingPieces[familySliceKey(part), default: []].append(part.pieceIndex)
        }
        for key in survivingPieces.keys {
            survivingPieces[key]?.sort()
        }

        let primaryCount = plan.primary.positions.count
        var parts: [UnplacedPart] = []
        var reliefCutCount = 0
        for letterPart in cuttableParts {
            let loopMm = letterPart.loop.map { Vec2(x: $0.x * toMm, y: $0.y * toMm) }
            guard loopMm.count >= 3 else { continue }
            var island = Island(loops: [loopMm], openPaths: [], isError: letterPart.isError)
            if !letterPart.reliefDiscs.isEmpty {
                let relieved = cuttingReliefDiscs(
                    letterPart.reliefDiscs.map { disc in
                        (center: Vec2(x: disc.center.x * toMm, y: disc.center.y * toMm), radius: disc.radius * toMm)
                    },
                    from: island
                )
                island = relieved.island
                if relieved.cut {
                    reliefCutCount += letterPart.reliefDiscs.count
                }
            }
            let axis = letterPart.family == .primary ? plan.primary.axis : plan.secondary.axis
            let siblings = survivingPieces[familySliceKey(letterPart)] ?? []
            var label = "\(axisLetter(axis))-\(letterPart.sliceIndex + 1)"
            if siblings.count > 1, let ordinal = siblings.firstIndex(of: letterPart.pieceIndex) {
                label += "-\(ordinal + 1)"
            }
            let stepIndex = letterPart.family == .primary
                ? letterPart.sliceIndex + 1
                : primaryCount + letterPart.sliceIndex + 1
            parts.append(
                unplacedPart(
                    label: label,
                    stepIndex: stepIndex,
                    island: island,
                    guides: []
                )
            )
        }
        return (parts, reliefCutCount)
    }

    /// `island` with slot relief `discs` cut out of its outline, and whether
    /// they were cut. A piece the discs cut off is dropped; if it is big
    /// enough to count as a part, the part is flagged as an error. When the
    /// cut fails the island is returned unchanged.
    private static func cuttingReliefDiscs(
        _ discs: [(center: Vec2, radius: Double)],
        from island: Island
    ) -> (island: Island, cut: Bool) {
        guard !discs.isEmpty,
              let outline = island.loops.first,
              let loops = PlanarBoolean.subtractingDiscs(discs, from: outline) else {
            return (island, false)
        }
        let outers = loops
            .filter { signedArea($0) > 0 }
            .sorted { signedArea($0) > signedArea($1) }
        guard let outer = outers.first else { return (island, false) }
        var relieved = island
        relieved.loops = [outer] + loops.filter { signedArea($0) < 0 && contains(outer, point: $0[0]) }
        if outers.dropFirst().contains(where: { signedArea($0) >= minimumPartArea }) {
            relieved.isError = true
        }
        return (relieved, true)
    }

    static func document(
        radial plan: RadialSlicePlan,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        // n_radial == 0 degrades to Interlocked.
        if plan.nRadial == 0, let fallback = plan.interlockedFallbackPlan() {
            return document(interlocked: fallback, model: model, settings: settings, revision: revision)
        }
        guard let primary = plan.primary else {
            return emptyDocument(settings: settings, revision: revision)
        }
        // Rings + fins from the disk+wedge generator (`RadialPartBuilder`), in
        // true model mm; the sheet keeps its own real-mm packing. Assembly
        // order (and so stepIndex) is disks first, then wedges.
        let diskStepCount = primary.positions.count
        var parts: [UnplacedPart] = []
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let labels = RadialPartBuilder.labels(assembly, axisLetter: axisLetter(primary.axis))
        for (disk, label) in zip(assembly.disks, labels.disks) {
            var part = unplacedPart(
                label: label,
                stepIndex: disk.sliceIndex + 1,
                island: Island(loops: [disk.loop] + disk.holes, openPaths: [], isError: disk.severed, isDetached: !disk.joined),
                guides: []
            )
            part.planeFrame = RadialPartBuilder.diskFrame(axis: primary.axis, position: disk.position)
            parts.append(part)
        }
        let center = model.bounds.map(RadialPartBuilder.boxCenter)
        for (wedge, label) in zip(assembly.wedges, labels.wedges) {
            var part = unplacedPart(
                label: label,
                stepIndex: diskStepCount + wedge.sliceIndex + 1,
                island: Island(loops: [wedge.loop] + wedge.holes, openPaths: [], isError: wedge.severed, isDetached: !wedge.joined),
                guides: []
            )
            part.planeFrame = center.map { RadialPartBuilder.wedgeFrame(center: $0, axis: primary.axis, angle: wedge.position) }
            parts.append(part)
        }
        var document = pack(parts, settings: settings, revision: revision)
        document.notes = RadialPartBuilder.notes(assembly, axisLetter: axisLetter(primary.axis))
        return document
    }

    static func document(
        curve plan: CurveSlicePlan,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        let primaryContours = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let curveContours = CurveSliceContourer.generate(model: model, plan: plan)
        let slots = CurveJointPlanner.slots(plan: plan, primary: primaryContours, curve: curveContours)
        let letter = axisLetter(plan.primary.axis)
        var parts = slottedSectionParts(
            slots.primaryPieces,
            frames: primaryContours.layers.map { PartPlaneFrame(axis: primaryContours.axis, position: $0.position) },
            labelPrefix: letter,
            stepIndexBase: 0
        )
        parts += slottedSectionParts(
            slots.curvePieces,
            frames: curveContours.layers.map { PartPlaneFrame(center: $0.center, inPlaneDirection: $0.normal) },
            labelPrefix: "C",
            stepIndexBase: primaryContours.layers.count
        )
        var document = pack(parts, settings: settings, revision: revision)
        document.notes = slots.assemblyNotes(axisLetter: letter)
        return document
    }

    static func document(
        threeD plan: ThreeDSlicePlan,
        model: MeshSummary,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        // 3D Slices has NO flat cut sheet. It produces a surface-preserving
        // layered MESH (see ThreeDSliceMeshExportBuilder), exported as STL/OBJ
        // only, with no flat cut-sheet layout. (This previously built a
        // three-family interlocking waffle — the wrong product entirely.)
        _ = plan
        _ = model
        return emptyDocument(settings: settings, revision: revision)
    }

    static func document(
        folded plan: FoldedPanelPlan,
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        var parts: [UnplacedPart] = []
        if plan.nets.isEmpty {
            // Plans built without the multi-net unfold (tests, legacy docs):
            // the per-panel paths are all there is.
            let preview = FoldedPanelPreviewLayouter.layout(plan: plan, spacing: settings.sanitized.partSpacing)
            for (index, panelPath) in preview.paths.enumerated() {
                guard panelPath.points.count >= 3 else { continue }
                parts.append(
                    unplacedPart(
                        label: "\(index + 1)",
                        stepIndex: index + 1,
                        island: Island(loops: [panelPath.points], openPaths: []),
                        guides: []
                    )
                )
            }
            return pack(parts, settings: settings, revision: revision)
        }

        // One sheet part per net, built from the net itself so the part's
        // plan coordinates are the net's: the outline (with the joints'
        // tabs, lugs and notches) and its holes as cut loops, the fold lines
        // on their own fold layer, and each panel's place on the model.
        for (index, net) in plan.nets.enumerated() {
            func closedRing(_ points: [Vec2]) -> [Vec2] {
                guard let first = points.first, points.last != first else { return points }
                return points + [first]
            }
            var loops: [[Vec2]] = []
            if net.outline.count >= 3 {
                loops.append(closedRing(net.outline))
            } else {
                let panels = net.panelOutlines.filter { $0.count >= 3 }
                let joined = PlanarBoolean.subtracting([], from: panels) ?? panels
                loops.append(contentsOf: joined.map(closedRing))
            }
            loops.append(contentsOf: net.outlineHoles.filter { $0.count >= 3 }.map(closedRing))
            loops.append(contentsOf: net.slotHoles.filter { $0.count >= 3 }.map(closedRing))
            guard !loops.isEmpty else { continue }
            var part = unplacedPart(
                label: "\(index + 1)",
                stepIndex: index + 1,
                island: Island(loops: loops, openPaths: []),
                guides: []
            )
            func local(_ point: Vec2) -> Vec2 {
                Vec2(x: point.x - part.planMin.x, y: point.y - part.planMin.y)
            }
            part.foldLines = plan.displayFoldSegments(net.foldEdges).map { [local($0.start), local($0.end)] }
            part.foldsArePerforated = plan.joinery.perforate
            for (panelIndex, region) in net.panelOutlines.enumerated() {
                guard net.panelFrames.indices.contains(panelIndex), let frame = net.panelFrames[panelIndex] else { continue }
                part.foldedPanels.append(CutSheetFoldedPanel(
                    frame: frame,
                    inward: net.panelInward.indices.contains(panelIndex) ? net.panelInward[panelIndex] : Vec3(x: 0, y: 0, z: 0),
                    region: region,
                    features: net.panelFeatures.indices.contains(panelIndex) ? net.panelFeatures[panelIndex] : []
                ))
            }
            part.foldedHinges = net.hinges
            parts.append(part)
        }
        return pack(parts, settings: settings, revision: revision)
    }

    // MARK: - Stacked scored guides

    /// Red guide lines engraved on each part, tracing where the NEXT slice's
    /// outline lands at least one slice depth inside it (see
    /// `StackedAssemblyGuides`). Returns per-layer guide polylines.
    private static func stackedGuides(for layers: [SliceContourLayer]) -> [[[Vec2]]] {
        guard layers.count >= 2 else {
            return Array(repeating: [], count: layers.count)
        }
        let sliceDepth = abs(layers[1].position - layers[0].position)
        return StackedAssemblyGuides.guides(for: layers, clearance: sliceDepth)
    }

    // MARK: - Slotted sections (curve)

    /// One part per piece of each layer (`CurveJointPlanner.Piece`), with
    /// that layer's slots cut out of it: red where the slots cut it off from
    /// a joint's material, blue where it is joined only to parts that are
    /// not joined to the rest. `frames` places each layer's section
    /// coordinates in the model.
    private static func slottedSectionParts(
        _ layers: [[CurveJointPlanner.Piece]],
        frames: [PartPlaneFrame],
        labelPrefix: String,
        stepIndexBase: Int
    ) -> [UnplacedPart] {
        var parts: [UnplacedPart] = []
        for (layerIndex, pieces) in layers.enumerated() {
            for (pieceIndex, piece) in pieces.enumerated() {
                var part = unplacedPart(
                    label: CurveJointPlanner.pieceLabel(prefix: labelPrefix, layer: layerIndex, piece: pieceIndex, of: pieces.count),
                    stepIndex: stepIndexBase + layerIndex + 1,
                    island: Island(loops: piece.loops, openPaths: piece.openPaths, isError: piece.severed, isDetached: piece.detached),
                    guides: []
                )
                part.planeFrame = frames.indices.contains(layerIndex) ? frames[layerIndex] : nil
                parts.append(part)
            }
        }
        return parts
    }

    /// `island` with the `slots` (closed rectangles) that reach it cut out of
    /// its material. A slot runs in from the part's edge, so the outline comes
    /// back with the slot as part of it. Two slots closer together than
    /// `CurveJointPlanner.minimumWeb` become one wide slot rather than leave a
    /// hairline of material between them. Any piece the slots cut off is
    /// dropped: the teeth between crowded slots are scrap. When a dropped
    /// piece holds one of the `kept` points (material a joint of this part
    /// must keep), the slots have cut the part apart and the island is
    /// flagged as an error. An island the cuts take away whole comes back
    /// empty (no loops or open paths), unless it holds a `kept` point: then
    /// it comes back uncut and flagged as an error. When the cut fails the
    /// island is returned unchanged.
    static func cuttingSlots(_ slots: [[Vec2]], from island: Island, keeping kept: [Vec2] = []) -> Island {
        guard let outline = island.loops.first, outline.count >= 3 else { return island }
        let xs = outline.map(\.x)
        let ys = outline.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return island
        }
        let reaching = slots.filter { slot in
            slot.count >= 3
                && (slot.map(\.x).max() ?? -.infinity) > minX && (slot.map(\.x).min() ?? .infinity) < maxX
                && (slot.map(\.y).max() ?? -.infinity) > minY && (slot.map(\.y).min() ?? .infinity) < maxY
        }
        guard !reaching.isEmpty else { return island }

        // Outer counter-clockwise and holes clockwise, so the material is the
        // non-zero fill of the rings.
        let outer = signedArea(outline) >= 0 ? outline : Array(outline.reversed())
        let rings = [outer] + island.loops.dropFirst().map { signedArea($0) <= 0 ? $0 : Array($0.reversed()) }
        guard let loops = PlanarBoolean.subtracting(reaching, from: rings, bridging: CurveJointPlanner.minimumWeb) else {
            return island
        }
        let outers = loops
            .filter { signedArea($0) > 0 }
            .sorted { signedArea($0) > signedArea($1) }
        guard let largest = outers.first else {
            var removed = island
            if kept.contains(where: { contains(outline, point: $0) }) {
                removed.isError = true
            } else {
                removed.loops = []
                removed.openPaths = []
            }
            return removed
        }
        var slotted = island
        slotted.loops = [largest] + loops.filter { signedArea($0) < 0 && contains(largest, point: $0[0]) }
        let dropped = outers.dropFirst()
        if kept.contains(where: { point in dropped.contains { contains($0, point: point) } }) {
            slotted.isError = true
        }
        return slotted
    }

    /// `island` with the `slots` cut out, as the pieces a Curve Slices part
    /// keeps: the largest piece, and every other piece the cuts leave that
    /// holds one of the `kept` points (material a joint of this part keeps).
    /// A slot that runs from a hole out through the edge cuts a ring open,
    /// and two such slots cut it in two; each piece is held by its own
    /// joints, so it becomes a part of its own. Other loose pieces (scrap
    /// between crowded slots) are dropped. Slots closer together than
    /// `CurveJointPlanner.minimumWeb` become one wide slot, as in
    /// `cuttingSlots`. An island the cuts take away whole comes back as
    /// nothing, unless it holds a `kept` point: then it comes back uncut and
    /// flagged as an error. When the cut fails the island comes back
    /// unchanged. With `keepingEveryPiece`, every piece is kept.
    static func slottedPieces(
        _ slots: [[Vec2]],
        from island: Island,
        keeping kept: [Vec2] = [],
        keepingEveryPiece: Bool = false
    ) -> [Island] {
        guard let outline = island.loops.first, outline.count >= 3 else { return [island] }
        let xs = outline.map(\.x)
        let ys = outline.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return [island]
        }
        let reaching = slots.filter { slot in
            slot.count >= 3
                && (slot.map(\.x).max() ?? -.infinity) > minX && (slot.map(\.x).min() ?? .infinity) < maxX
                && (slot.map(\.y).max() ?? -.infinity) > minY && (slot.map(\.y).min() ?? .infinity) < maxY
        }
        guard !reaching.isEmpty else { return [island] }

        let outer = signedArea(outline) >= 0 ? outline : Array(outline.reversed())
        let rings = [outer] + island.loops.dropFirst().map { signedArea($0) <= 0 ? $0 : Array($0.reversed()) }
        guard let loops = PlanarBoolean.subtracting(reaching, from: rings, bridging: CurveJointPlanner.minimumWeb) else {
            return [island]
        }
        // A cut that leaves the material touching itself at a point gives
        // the lobes on either side as pieces of their own
        // (`separatingPinches`).
        let outers = loops
            .filter { signedArea($0) > 0 }
            .flatMap { separatingPinches($0) }
            .sorted { signedArea($0) > signedArea($1) }
        guard !outers.isEmpty else {
            var removed = island
            if kept.contains(where: { contains(outline, point: $0) }) {
                removed.isError = true
                return [removed]
            }
            return []
        }
        let holes = loops.filter { signedArea($0) < 0 }
        var pieces: [Island] = []
        for (index, piece) in outers.enumerated() {
            guard index == 0 || keepingEveryPiece || kept.contains(where: { contains(piece, point: $0) }) else { continue }
            // Each hole belongs to the smallest piece around it.
            let own = holes.filter { hole in
                guard let probe = hole.first, contains(piece, point: probe) else { return false }
                return !outers.contains { other in
                    other != piece && contains(other, point: probe) && signedArea(other) < signedArea(piece)
                }
            }
            var slotted = island
            slotted.loops = [piece] + own
            slotted.openPaths = index == 0 ? island.openPaths : []
            pieces.append(slotted)
        }
        return pieces
    }

    // MARK: - Island splitting

    /// One disconnected piece of a slice: its outer loop, any hole loops it
    /// contains, plus open path fragments that fall inside it.
    struct Island {
        var loops: [[Vec2]]      // [0] = outer, rest = holes
        var openPaths: [[Vec2]]
        /// "Notches split part" error: the slots cut through the part and
        /// sever a piece of it. Error parts render red-filled.
        var isError = false
        /// Detached-piece warning: the piece is not connected to the rest
        /// of the model and would fall off; it renders blue. Set for Radial
        /// Slices pieces that hold no joint with the other family
        /// (`RadialPartBuilder.ModelPart.joined`), and for Curve Slices
        /// pieces joined only to parts that are not joined to the rest
        /// (`CurveJointPlanner.Piece.detached`).
        var isDetached = false
    }

    /// Split a slice's paths into disconnected pieces, labeled by slice
    /// number plus a piece number when a slice has several pieces (e.g.
    /// "6-2"). Outers are loops at even containment depth; each odd-depth
    /// loop becomes a hole of its tightest containing outer. Open fragments
    /// attach to the island whose outer contains them.
    static func islandize(paths: [SlicePath2D]) -> [Island] {
        var closed: [[Vec2]] = []
        var open: [[Vec2]] = []
        for path in paths {
            let points = normalizedLoopPoints(path)
            if points.count >= 3, isClosed(path) {
                // An outline that touches itself is cut as the lobes it
                // pinches into (`separatingPinches`).
                closed.append(contentsOf: separatingPinches(points))
            } else if path.points.count >= 2 {
                open.append(path.points)
            }
        }

        guard !closed.isEmpty else {
            // No closed loops at all (badly broken mesh) — one island carrying
            // the fragments, so they still render.
            return open.isEmpty ? [] : [Island(loops: [], openPaths: open)]
        }

        // Containment depth of each loop = number of OTHER loops containing it.
        let depths = closed.indices.map { index in
            closed.indices.reduce(0) { depth, other in
                guard other != index else { return depth }
                return depth + (contains(closed[other], point: interiorPoint(of: closed[index])) ? 1 : 0)
            }
        }

        var islands: [Island] = []
        var outerIndexByLoop: [Int: Int] = [:]  // loop index -> islands index
        for index in closed.indices where depths[index] % 2 == 0 {
            outerIndexByLoop[index] = islands.count
            islands.append(Island(loops: [closed[index]], openPaths: []))
        }
        guard !islands.isEmpty else {
            return [Island(loops: closed, openPaths: open)]
        }

        // Attach each hole to its tightest (smallest-area) containing outer.
        for index in closed.indices where depths[index] % 2 == 1 {
            let point = interiorPoint(of: closed[index])
            var best: (islandIndex: Int, area: Double)?
            for (loopIndex, islandIndex) in outerIndexByLoop {
                guard contains(closed[loopIndex], point: point) else { continue }
                let area = abs(signedArea(closed[loopIndex]))
                if best == nil || area < best!.area {
                    best = (islandIndex, area)
                }
            }
            if let best {
                islands[best.islandIndex].loops.append(closed[index])
            }
        }

        // Attach open fragments to the island containing them.
        for fragment in open {
            guard let probe = fragment.first else { continue }
            var attached = false
            for (loopIndex, islandIndex) in outerIndexByLoop where contains(closed[loopIndex], point: probe) {
                islands[islandIndex].openPaths.append(fragment)
                attached = true
                break
            }
            if !attached, !islands.isEmpty {
                islands[0].openPaths.append(fragment)
            }
        }

        // Drop uncuttable degenerate slivers (broken-mesh noise): anything
        // whose outer loop is under ~1mm² or thinner than ~1.5mm cannot be cut
        // or assembled and would otherwise become dozens of labeled crumbs.
        // Real small pieces (labeled e.g. "10-4") stay.
        let cuttable = islands.filter { island in
            guard let outer = island.loops.first else { return !island.openPaths.isEmpty }
            let area = abs(signedArea(outer))
            let xs = outer.map(\.x)
            let ys = outer.map(\.y)
            let maxDim = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            return area >= minimumPartArea && maxDim >= minimumPartDimension
        }

        // Largest first, so the biggest pieces are placed first.
        return cuttable.sorted { lhs, rhs in
            abs(signedArea(lhs.loops.first ?? [])) > abs(signedArea(rhs.loops.first ?? []))
        }
    }

    // MARK: - Pinched outlines

    /// How close (mm) a corner of an outline may come to another stretch of
    /// the same outline before the outline counts as touching itself there.
    static let pinchTolerance = 1.0e-5

    /// `loop` (closed, no repeated first point) as the outlines it pinches
    /// into. Where an outline touches itself (a corner lies on, or within
    /// `pinchTolerance` of, a stretch of the same outline it does not end)
    /// it encloses two lobes joined at a single point: no material holds
    /// them together there, and rounding to the exported precision can turn
    /// the touch into a crossing. Two lobes that lie outside each other are
    /// split apart at that point, until no lobe touches itself. They may
    /// turn the same way, or opposite ways where the outline is drawn as a
    /// figure of eight, crossing over at the touch (the contourer can join a
    /// section so where two pieces of the model meet at a corner); both
    /// enclose material, so the smaller is then turned like the larger. A
    /// lobe inside the other (a hole touching the edge) stays joined. An
    /// outline that does not touch itself comes back as it is.
    static func separatingPinches(_ loop: [Vec2]) -> [[Vec2]] {
        separatingPinches(loop, depth: 0)
    }

    private static func separatingPinches(_ loop: [Vec2], depth: Int) -> [[Vec2]] {
        guard depth < 64, let lobes = splitAtPinch(loop) else { return [loop] }
        return separatingPinches(lobes.0, depth: depth + 1) + separatingPinches(lobes.1, depth: depth + 1)
    }

    /// The two lobes of `loop` either side of the first point where it
    /// touches itself and may be split there (`separatingPinches`), or nil.
    private static func splitAtPinch(_ loop: [Vec2]) -> ([Vec2], [Vec2])? {
        let tolerance = pinchTolerance
        func close(_ a: Vec2, _ b: Vec2) -> Bool {
            abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        }
        // Corners closer than the tolerance are one corner.
        var points: [Vec2] = []
        for point in loop where points.last.map({ !close($0, point) }) ?? true {
            points.append(point)
        }
        while points.count > 1, let first = points.first, let last = points.last, close(first, last) {
            points.removeLast()
        }
        let n = points.count
        guard n >= 6 else { return nil }

        // Edges by grid cell, so each corner is checked against the edges
        // near it only.
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let extent = max(maxX - minX, maxY - minY)
        let cell = max(extent / Double(max(1, Int(Double(n).squareRoot()))), tolerance * 100)
        let columns = Int(((maxX - minX) / cell).rounded(.down)) + 2
        func column(_ x: Double) -> Int { max(0, Int(((x - minX) / cell).rounded(.down))) }
        func row(_ y: Double) -> Int { max(0, Int(((y - minY) / cell).rounded(.down))) }
        var buckets: [Int: [Int]] = [:]
        for edge in 0..<n {
            let a = points[edge]
            let b = points[(edge + 1) % n]
            for x in column(min(a.x, b.x) - tolerance)...column(max(a.x, b.x) + tolerance) {
                for y in row(min(a.y, b.y) - tolerance)...row(max(a.y, b.y) + tolerance) {
                    buckets[y * columns + x, default: []].append(edge)
                }
            }
        }
        func distanceSquared(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            let ab = Vec2(x: b.x - a.x, y: b.y - a.y)
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            let t = lengthSquared > 0 ? min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared)) : 0
            let dx = p.x - (a.x + ab.x * t)
            let dy = p.y - (a.y + ab.y * t)
            return dx * dx + dy * dy
        }
        for corner in 0..<n {
            let p = points[corner]
            let candidates = (buckets[row(p.y) * columns + column(p.x)] ?? []).sorted()
            for edge in candidates {
                let next = (edge + 1) % n
                guard edge != corner, next != corner,
                      distanceSquared(p, points[edge], points[next]) <= tolerance * tolerance else { continue }
                // Lobe one runs from the corner on round to the edge's start
                // (and back along the edge to the corner); lobe two from the
                // corner along the rest of the edge and on round to the
                // corner before it.
                var first: [Vec2] = []
                var k = corner
                while true {
                    first.append(points[k])
                    if k == edge { break }
                    k = (k + 1) % n
                }
                var second: [Vec2] = [p]
                k = next
                while k != corner {
                    second.append(points[k])
                    k = (k + 1) % n
                }
                if let last = first.last, first.count > 1, close(last, p) { first.removeLast() }
                if second.count > 1, close(second[1], p) { second.remove(at: 1) }
                guard first.count >= 3, second.count >= 3 else { continue }
                let firstArea = signedArea(first)
                let secondArea = signedArea(second)
                guard abs(firstArea) > tolerance, abs(secondArea) > tolerance else { continue }
                // Neither lobe inside the other: a point just off the touch
                // along each lobe lies outside the other.
                func probe(_ lobe: [Vec2]) -> Vec2 {
                    Vec2(x: (lobe[1].x + lobe[2].x) / 2, y: (lobe[1].y + lobe[2].y) / 2)
                }
                guard !contains(second, point: probe(first)), !contains(first, point: probe(second)) else { continue }
                // Neither starts at the touch, where it meets the other
                // lobe: a loop's first corner is what other loops are tested
                // against when nesting them (`islandize`).
                var firstLobe = Array(first.dropFirst()) + [first[0]]
                var secondLobe = Array(second.dropFirst()) + [second[0]]
                // A figure of eight crosses over at the touch, so its lobes
                // turn opposite ways: turn the smaller like the larger
                // (reversed, it would start at the touch; start one on).
                if (firstArea > 0) != (secondArea > 0) {
                    func turned(_ lobe: [Vec2]) -> [Vec2] {
                        let reversed = Array(lobe.reversed())
                        return Array(reversed.dropFirst()) + [reversed[0]]
                    }
                    if abs(firstArea) >= abs(secondArea) {
                        secondLobe = turned(secondLobe)
                    } else {
                        firstLobe = turned(firstLobe)
                    }
                }
                return (firstLobe, secondLobe)
            }
        }
        return nil
    }

    /// Minimum outer-loop area (mm²) for a piece to be worth cutting.
    static let minimumPartArea = 1.0
    /// Minimum outer-loop extent (mm) for a piece to be worth cutting.
    static let minimumPartDimension = 1.5

    // MARK: - Part assembly

    private struct UnplacedPart {
        var label: String
        var stepIndex: Int?
        var cutLoops: [[Vec2]]
        var openCuts: [[Vec2]]
        var guideLines: [[Vec2]]
        var circles: [SvgExporter.Circle] = []
        var holeLoops: [[Vec2]] = []
        var width: Double
        var height: Double
        var labelAnchor: Vec2
        var labelRadius: Double
        var isError = false
        var isDetached = false
        var planMin = Vec2(x: 0, y: 0)
        var planeFrame: PartPlaneFrame?
        var foldLines: [[Vec2]] = []
        var foldsArePerforated = false
        var foldedPanels: [CutSheetFoldedPanel] = []
        var foldedHinges: [FoldedNetHinge] = []
    }

    /// Engrave-safe label placement: the pole of inaccessibility of the
    /// part's outer loop (minus holes) — the interior point farthest from any
    /// cut line — and the inscribed radius there. Labels sized to this radius
    /// can never bleed over the part edge. Coarse grid + one refinement pass;
    /// loops are decimated for the distance test with a safety factor.
    static func labelPlacement(outer: [Vec2], holes: [[Vec2]], width: Double, height: Double) -> (anchor: Vec2, radius: Double) {
        guard outer.count >= 3, width > 0, height > 0 else {
            return (Vec2(x: width / 2, y: height / 2), max(0.5, min(width, height) * 0.3))
        }
        let testLoops = ([outer] + holes).map { decimate($0, maxPoints: 240) }

        func clearance(_ p: Vec2) -> Double {
            guard contains(outer, point: p) else { return -1 }
            for hole in holes where contains(hole, point: p) {
                return -1
            }
            var best = Double.greatestFiniteMagnitude
            for loop in testLoops {
                for index in loop.indices {
                    let a = loop[index]
                    let b = loop[(index + 1) % loop.count]
                    best = min(best, distance(p, segmentA: a, segmentB: b))
                    if best <= 0 { return 0 }
                }
            }
            return best
        }

        var bestPoint = Vec2(x: width / 2, y: height / 2)
        var bestRadius = clearance(bestPoint)
        let coarse = 14
        for yi in 0..<coarse {
            for xi in 0..<coarse {
                let p = Vec2(
                    x: width * (Double(xi) + 0.5) / Double(coarse),
                    y: height * (Double(yi) + 0.5) / Double(coarse)
                )
                let r = clearance(p)
                if r > bestRadius {
                    bestRadius = r
                    bestPoint = p
                }
            }
        }
        // Refine around the best coarse cell.
        let cellW = width / Double(coarse)
        let cellH = height / Double(coarse)
        let fine = 5
        for yi in -fine...fine {
            for xi in -fine...fine {
                let p = Vec2(
                    x: bestPoint.x + cellW * Double(xi) / Double(fine),
                    y: bestPoint.y + cellH * Double(yi) / Double(fine)
                )
                let r = clearance(p)
                if r > bestRadius {
                    bestRadius = r
                    bestPoint = p
                }
            }
        }
        if bestRadius <= 0 {
            return (Vec2(x: width / 2, y: height / 2), max(0.4, min(width, height) * 0.2))
        }
        // Safety factor for the loop decimation.
        return (bestPoint, bestRadius * 0.85)
    }

    private static func decimate(_ loop: [Vec2], maxPoints: Int) -> [Vec2] {
        guard loop.count > maxPoints else { return loop }
        let stride = Double(loop.count) / Double(maxPoints)
        return (0..<maxPoints).map { loop[min(loop.count - 1, Int(Double($0) * stride))] }
    }

    private static func distance(_ p: Vec2, segmentA a: Vec2, segmentB b: Vec2) -> Double {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else {
            let dx = p.x - a.x
            let dy = p.y - a.y
            return (dx * dx + dy * dy).squareRoot()
        }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared))
        let cx = a.x + t * abx
        let cy = a.y + t * aby
        let dx = p.x - cx
        let dy = p.y - cy
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Normalize an island to local coordinates (bbox min at origin) and clip
    /// its guides to the loops that fall within its outer bounds.
    private static func unplacedPart(
        label: String,
        stepIndex: Int?,
        island: Island,
        guides: [[Vec2]],
        planCircles: [(center: Vec2, radius: Double)] = [],
        planHoleLoops: [[Vec2]] = []
    ) -> UnplacedPart {
        var allPoints = island.loops.flatMap { $0 } + island.openPaths.flatMap { $0 }
        let outer = island.loops.first ?? []
        let ownedGuides = guides.filter { guide in
            guard let probe = guide.first else { return false }
            return outer.isEmpty || contains(outer, point: probe)
        }
        allPoints += ownedGuides.flatMap { $0 }
        let xs = allPoints.map(\.x)
        let ys = allPoints.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        func local(_ p: Vec2) -> Vec2 { Vec2(x: p.x - minX, y: p.y - minY) }
        let localLoops = island.loops.map { $0.map(local) }
        let width = maxX - minX
        let height = maxY - minY
        let placement = labelPlacement(
            outer: localLoops.first ?? [],
            holes: Array(localLoops.dropFirst()),
            width: width,
            height: height
        )
        var part = UnplacedPart(
            label: label,
            stepIndex: stepIndex,
            cutLoops: localLoops,
            openCuts: island.openPaths.map { $0.map(local) },
            guideLines: ownedGuides.map { $0.map(local) },
            width: width,
            height: height,
            labelAnchor: placement.anchor,
            labelRadius: placement.radius,
            isError: island.isError,
            isDetached: island.isDetached
        )
        part.circles = planCircles.map { SvgExporter.Circle(center: local($0.center), radius: $0.radius) }
        part.holeLoops = planHoleLoops.map { $0.map(local) }
        part.planMin = Vec2(x: minX, y: minY)
        return part
    }


    // MARK: - Packing

    /// First-fit-decreasing shelf packing — parts are fitted to use as much
    /// of each sheet as possible (material efficiency is the requirement).
    private static func pack(
        _ parts: [UnplacedPart],
        settings: ExportLayoutSettings,
        revision: Int
    ) -> CutSheetDocument {
        let sanitized = settings.sanitized
        let useSheet = sanitized.hasSheetSize
        let margin = sanitized.pageMargin
        let spacing = sanitized.partSpacing
        let sheetWidth = useSheet ? sanitized.sheetWidth : 0
        let sheetHeight = useSheet ? sanitized.sheetHeight : 0
        let contentWidth = useSheet ? max(1, sheetWidth - margin * 2) : .greatestFiniteMagnitude
        let contentHeight = useSheet ? max(1, sheetHeight - margin * 2) : .greatestFiniteMagnitude

        struct Shelf {
            var sheetIndex: Int
            var y: Double
            var height: Double
            var usedX: Double
        }
        var shelves: [Shelf] = []
        var sheetNextY: [Double] = []
        var placed: [[CutSheetPart]] = []

        func ensureSheet(_ index: Int) {
            while sheetNextY.count <= index {
                sheetNextY.append(0)
                placed.append([])
            }
        }

        // Largest dimension first.
        let order = parts.indices.sorted {
            max(parts[$0].width, parts[$0].height) > max(parts[$1].width, parts[$1].height)
        }

        for partIndex in order {
            let part = parts[partIndex]
            // Prefer landscape orientation (wide, short shelves waste less).
            var orientations: [(w: Double, h: Double, rotated: Bool)] = [
                (part.width, part.height, false),
                (part.height, part.width, true)
            ]
            if part.height > part.width {
                orientations.swapAt(0, 1)
            }

            var chosen: (shelfIndex: Int?, sheetIndex: Int, x: Double, y: Double, rotated: Bool, overflow: Bool)?

            // 1. Best fit into an existing shelf (least leftover height).
            var bestWaste = Double.greatestFiniteMagnitude
            for orientation in orientations {
                for (shelfIndex, shelf) in shelves.enumerated() {
                    let needsSpacing = shelf.usedX > 0 ? spacing : 0
                    guard shelf.usedX + needsSpacing + orientation.w <= contentWidth,
                          orientation.h <= shelf.height else {
                        continue
                    }
                    let waste = shelf.height - orientation.h
                    if waste < bestWaste {
                        bestWaste = waste
                        chosen = (shelfIndex, shelf.sheetIndex, shelf.usedX + needsSpacing, shelf.y, orientation.rotated, false)
                    }
                }
                if chosen != nil { break }
            }

            // 2. New shelf on the first sheet with room. A part that fits a
            // sheet fits a fresh one, so the search stops one past the
            // sheets there are (a part too tall for any sheet goes to 3).
            if chosen == nil {
                let lastSheetToTry = sheetNextY.count
                outer: for orientation in orientations where orientation.w <= contentWidth {
                    var sheetIndex = 0
                    while true {
                        ensureSheet(sheetIndex)
                        let y = sheetNextY[sheetIndex]
                        let needsSpacing = y > 0 ? spacing : 0
                        if y + needsSpacing + orientation.h <= contentHeight {
                            chosen = (nil, sheetIndex, 0, y + needsSpacing, orientation.rotated, false)
                            break outer
                        }
                        if !useSheet { break outer }
                        sheetIndex += 1
                        if sheetIndex > lastSheetToTry { break }
                    }
                }
            }

            // 3. Oversized: its own sheet, flagged.
            if chosen == nil {
                ensureSheet(sheetNextY.count)
                chosen = (nil, sheetNextY.count - 1, 0, 0, false, true)
            }

            guard var placement = chosen else { continue }
            ensureSheet(placement.sheetIndex)

            let w = placement.rotated ? part.height : part.width
            let h = placement.rotated ? part.width : part.height
            if placement.shelfIndex == nil, !placement.overflow {
                shelves.append(Shelf(sheetIndex: placement.sheetIndex, y: placement.y, height: h, usedX: w))
                sheetNextY[placement.sheetIndex] = placement.y + h
            } else if let shelfIndex = placement.shelfIndex {
                shelves[shelfIndex].usedX = placement.x + w
                placement.y = shelves[shelfIndex].y
            }

            let origin = Vec2(x: margin + placement.x, y: margin + placement.y)
            func place(_ p: Vec2) -> Vec2 {
                if placement.rotated {
                    // 90° rotation: (x, y) -> (h_local - y, x) keeps loops CCW.
                    return Vec2(x: origin.x + (part.height - p.y), y: origin.y + p.x)
                }
                return Vec2(x: origin.x + p.x, y: origin.y + p.y)
            }

            let sheetPart = CutSheetPart(
                label: part.label,
                stepIndex: part.stepIndex,
                cutLoops: part.cutLoops.map { $0.map(place) },
                openCuts: part.openCuts.map { $0.map(place) },
                guideLines: part.guideLines.map { $0.map(place) },
                circles: part.circles.map { SvgExporter.Circle(center: place($0.center), radius: $0.radius) },
                holeLoops: part.holeLoops.map { $0.map(place) },
                bounds: SvgExporter.Bounds2(
                    min: origin,
                    max: Vec2(x: origin.x + w, y: origin.y + h)
                ),
                labelAnchor: place(part.labelAnchor),
                labelRadius: part.labelRadius,
                overflowsSheet: placement.overflow || (useSheet && (w > contentWidth || h > contentHeight)),
                isError: part.isError,
                isDetached: part.isDetached,
                rotatedOnSheet: placement.rotated,
                planMin: part.planMin,
                planeFrame: part.planeFrame,
                foldLines: part.foldLines.map { $0.map(place) },
                foldsArePerforated: part.foldsArePerforated,
                foldedPanels: part.foldedPanels,
                foldedHinges: part.foldedHinges
            )
            placed[placement.sheetIndex].append(sheetPart)
        }

        let sheets = placed.enumerated().compactMap { index, parts -> CutSheetSheet? in
            parts.isEmpty ? nil : CutSheetSheet(index: index + 1, parts: parts)
        }
        // Renumber consecutively in case empty sheets were dropped.
        let renumbered = sheets.enumerated().map { index, sheet in
            CutSheetSheet(index: index + 1, parts: sheet.parts)
        }
        return CutSheetDocument(
            sheetWidth: sheetWidth,
            sheetHeight: sheetHeight,
            sheets: renumbered,
            revision: revision
        )
    }

    private static func emptyDocument(settings: ExportLayoutSettings, revision: Int) -> CutSheetDocument {
        let sanitized = settings.sanitized
        return CutSheetDocument(
            sheetWidth: sanitized.hasSheetSize ? sanitized.sheetWidth : 0,
            sheetHeight: sanitized.hasSheetSize ? sanitized.sheetHeight : 0,
            sheets: [],
            revision: revision
        )
    }

    // MARK: - Geometry helpers

    private static func familySliceKey(_ part: InterlockedPartBuilder.Part) -> String {
        "\(part.family == .primary ? "P" : "S")\(part.sliceIndex)"
    }

    static func axisLetter(_ axis: SliceAxis) -> String {
        switch axis {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }

    private static func isClosed(_ path: SlicePath2D) -> Bool {
        if path.closed { return true }
        guard let first = path.points.first, let last = path.points.last else { return false }
        return abs(first.x - last.x) < 1.0e-9 && abs(first.y - last.y) < 1.0e-9
    }

    private static func normalizedLoopPoints(_ path: SlicePath2D) -> [Vec2] {
        var points = path.points
        if let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1.0e-9, abs(first.y - last.y) < 1.0e-9 {
            points.removeLast()
        }
        return points
    }

    /// A point safely interior to the loop: the midpoint of the first vertex
    /// and the loop centroid biases inward for convex-ish slice contours; for
    /// containment tests against OTHER loops the first vertex itself works
    /// because distinct contour loops do not share vertices.
    private static func interiorPoint(of loop: [Vec2]) -> Vec2 {
        loop.first ?? Vec2(x: 0, y: 0)
    }

    static func contains(_ loop: [Vec2], point: Vec2) -> Bool {
        guard loop.count >= 3 else { return false }
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let a = loop[i]
            let b = loop[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }
}
