import Foundation
import RealityKit

/// Caches the expensive viewport geometry (slice contours, extruded slice
/// solids, the imported-model mesh resource) so RealityKit scene rebuilds do
/// NOT recompute geometry that didn't change.
///
/// Measured motivation: `StackedSliceContourer.generate` is ~687 ms for a
/// 107k-triangle mesh (and scales with triangle count), and it was re-run on
/// every `.id(sceneIdentity)` rebuild. Selecting a step changed only the
/// highlight, yet paid the full contour cost again.
///
/// Lock-based (NOT main-actor-bound) so the heavy generation can run on a
/// background task — the Slice press no longer freezes the UI while contours
/// generate; the scene appears when ready.
///
/// The cache holds geometry for a single model at a time; loading a different
/// model clears it. Within a model, distinct plans (e.g. thickness sweeps) are
/// kept up to a small bound.
final class ViewportGeometryCache: @unchecked Sendable {
    static let shared = ViewportGeometryCache()

    private let lock = NSLock()
    private var modelKey = ""
    private var meshResource: MeshResource?
    private var stackedCache: [String: StackedSliceContours] = [:]
    private var curveCache: [String: CurveSliceContours] = [:]
    /// Curve plans as laid out and as cut (`CurveSlicePlanner.joiningGroups`),
    /// with the key of the model they were cut from, most recent last. Kept
    /// apart from the single-model caches (`reset`): the plans are cut from
    /// the slicing-frame model, which under a tilt is not the one shown.
    private var joinedCurvePlans: [(modelKey: String, laidOut: CurveSlicePlan, joined: CurveSlicePlan)] = []
    private let maxJoinedCurvePlans = 8
    private var solidMeshCache: [String: ViewportFlatShadedMesh] = [:]
    private var insertionOrder: [String] = []
    private var solidInsertionOrder: [String] = []
    private let maxStackedEntries = 24
    private let maxSolidEntries = 512

    /// Number of times contours were actually generated (cache misses). Used by
    /// tests to prove caching; not for production logic.
    private(set) var stackedGenerationCount = 0

    static func modelKey(for model: MeshSummary) -> String {
        // Bounds + first vertex disambiguate transformed variants of the same
        // file (scale/rotation produce equal path+counts but different
        // geometry — without this, contour caches served stale geometry after
        // a transform).
        var key = "\(model.path)|\(model.triangleCount)|\(model.vertexObservationCount)"
        if let bounds = model.bounds {
            key += "|\(bounds.min.display)|\(bounds.max.display)"
        }
        if let v0 = model.geometry.vertices.first {
            key += "|\(v0.display)"
        }
        return key
    }

    static func planKey(for plan: StackedSlicePlan) -> String {
        let positions = plan.positions.map { String(format: "%.6f", $0) }.joined(separator: ",")
        return "\(plan.axis.rawValue)|\(positions)|\(String(format: "%.6f", plan.materialThickness))"
    }

    /// Callers must hold `lock`.
    private func reset(ifModelChanged key: String) {
        guard key != modelKey else { return }
        modelKey = key
        meshResource = nil
        stackedCache.removeAll()
        curveCache.removeAll()
        solidMeshCache.removeAll()
        insertionOrder.removeAll()
        solidInsertionOrder.removeAll()
    }

    /// Returns cached stacked-slice contours for this (model, plan), generating
    /// and storing them on a miss. Safe to call from any queue.
    func stackedContours(model: MeshSummary, plan: StackedSlicePlan) -> StackedSliceContours {
        let key = Self.planKey(for: plan)
        lock.lock()
        reset(ifModelChanged: Self.modelKey(for: model))
        if let cached = stackedCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Generate outside the lock: generation is the multi-hundred-ms part
        // and must not serialize unrelated cache reads behind it.
        let generated = StackedSliceContourer.generate(model: model, plan: plan)

        lock.lock()
        stackedGenerationCount += 1
        stackedCache[key] = generated
        insertionOrder.append(key)
        if insertionOrder.count > maxStackedEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            stackedCache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return generated
    }

    /// `stackedContours` with every layer's open chains closed across the
    /// mesh's cracks (`StackedSliceContourer.closingCracks`): the layers
    /// Stacked cuts and drills its dowels through. Cached beside them; a
    /// layer with no open chain is the same layer.
    func stackedClosedContours(model: MeshSummary, plan: StackedSlicePlan) -> StackedSliceContours {
        let key = "closed|" + Self.planKey(for: plan)
        lock.lock()
        reset(ifModelChanged: Self.modelKey(for: model))
        if let cached = stackedCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let closed = StackedSliceContourer.closingCracks(stackedContours(model: model, plan: plan))

        lock.lock()
        stackedCache[key] = closed
        insertionOrder.append(key)
        if insertionOrder.count > maxStackedEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            stackedCache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return closed
    }

    /// The Stacked slice solids the viewport shows: every layer Stacked cuts
    /// (`stackedClosedContours`, closed across the mesh's cracks as the cut
    /// sheet and every export cut them) extruded to the stock. Each solid is
    /// cached (`solidMesh`); safe to call from any queue.
    func stackedSolidMeshes(model: MeshSummary, plan: StackedSlicePlan) -> [(layerIndex: Int, mesh: ViewportFlatShadedMesh)] {
        let contours = stackedClosedContours(model: model, plan: plan)
        let planKey = Self.planKey(for: plan)
        return contours.layers.indices.compactMap { layerIndex in
            solidMesh(key: "\(planKey)|closed-solid|\(layerIndex)") {
                ViewportSliceSolidRenderData.mesh(contours: contours, layerIndex: layerIndex, materialThickness: plan.materialThickness)
            }.map { (layerIndex, $0) }
        }
    }

    /// Where the viewport shows the Stacked dowel rods and their edit
    /// markers, and where manual editing starts from: the placements the
    /// cut sheet and every export drill (`DowelLayout` over the closed
    /// layers, `stackedClosedContours`), so on a cracked scan the rods sit
    /// in the holes.
    func dowelPlacements(model: MeshSummary, plan: StackedSlicePlan, settings: DxfExporter.DowelSettings?) -> [DowelLayout.Placement] {
        DowelLayout.placements(layers: stackedClosedContours(model: model, plan: plan).layers, settings: settings)
    }

    /// The Curve plan `plan` (as laid out) as cut from `model`, if it has been
    /// joined already (`joinedCurvePlan`).
    func cachedJoinedCurvePlan(for plan: CurveSlicePlan, model: MeshSummary) -> CurveSlicePlan? {
        let key = Self.modelKey(for: model)
        lock.lock()
        defer { lock.unlock() }
        return joinedCurvePlans.last { $0.modelKey == key && $0.laidOut == plan }?.joined
    }

    /// The Curve plan `plan` (as laid out) as cut from `model`: with
    /// first-axis ribs moved where that joins parts held only among
    /// themselves (`CurveSlicePlanner.joiningGroups`). Worked out once per
    /// plan and model; safe to call from any queue.
    func joinedCurvePlan(for plan: CurveSlicePlan, model: MeshSummary) -> CurveSlicePlan {
        if let cached = cachedJoinedCurvePlan(for: plan, model: model) {
            return cached
        }
        let joined = CurveSlicePlanner.joiningGroups(plan, model: model)
        let key = Self.modelKey(for: model)
        lock.lock()
        if !joinedCurvePlans.contains(where: { $0.modelKey == key && $0.laidOut == plan }) {
            joinedCurvePlans.append((key, plan, joined))
            if joinedCurvePlans.count > maxJoinedCurvePlans {
                joinedCurvePlans.removeFirst()
            }
        }
        lock.unlock()
        return joined
    }

    /// Cached curve contours (previously regenerated on EVERY scene rebuild).
    func curveContours(model: MeshSummary, plan: CurveSlicePlan, build: () -> CurveSliceContours) -> CurveSliceContours {
        let spline = plan.controlPoints.map { "\(String(format: "%.4f", $0.x)),\(String(format: "%.4f", $0.y))" }.joined(separator: ";")
        let key = "curve|\(plan.sliceCount)|\(plan.primarySliceCount)|\(spline)"
        lock.lock()
        reset(ifModelChanged: Self.modelKey(for: model))
        if let cached = curveCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let generated = build()
        lock.lock()
        curveCache[key] = generated
        lock.unlock()
        return generated
    }

    /// Cached extruded slice-solid render mesh. The extrusion math runs once
    /// per (plan, layer, slot-config); subsequent scene rebuilds reuse it.
    /// Simplified folded-source meshes, keyed modelKey|target. Entries are
    /// small (a few hundred faces) but the inputs are huge — cache so the
    /// computed plan property never re-runs QEM.
    private var simplifiedMeshCache: [String: MeshSummary] = [:]
    private var simplifiedInsertionOrder: [String] = []
    private let maxSimplifiedEntries = 8

    func cachedSimplifiedMesh(key: String) -> MeshSummary? {
        lock.lock()
        defer { lock.unlock() }
        return simplifiedMeshCache[key]
    }

    func storeSimplifiedMesh(_ mesh: MeshSummary, key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard simplifiedMeshCache[key] == nil else { return }
        simplifiedMeshCache[key] = mesh
        simplifiedInsertionOrder.append(key)
        if simplifiedInsertionOrder.count > maxSimplifiedEntries {
            let oldest = simplifiedInsertionOrder.removeFirst()
            simplifiedMeshCache.removeValue(forKey: oldest)
        }
    }

    /// Folded Panels plans, keyed by everything the planner reads. Cutting
    /// the panels back for the stock takes a while on a detailed model, so
    /// plans are built off the main thread and land here; the most recent
    /// one stands in (for its own model only) while the next is built.
    private var foldedPlanCache: [String: FoldedPanelPlan] = [:]
    private var foldedPlanOrder: [String] = []
    private var latestFoldedPlan: (modelKey: String, plan: FoldedPanelPlan)?
    private let maxFoldedPlans = 6

    func cachedFoldedPlan(key: String) -> FoldedPanelPlan? {
        lock.lock()
        defer { lock.unlock() }
        return foldedPlanCache[key]
    }

    /// The plan stored last, when it was built for the model `modelKey`.
    func latestFoldedPlan(modelKey: String) -> FoldedPanelPlan? {
        lock.lock()
        defer { lock.unlock() }
        return latestFoldedPlan?.modelKey == modelKey ? latestFoldedPlan?.plan : nil
    }

    func storeFoldedPlan(_ plan: FoldedPanelPlan, key: String, modelKey: String) {
        lock.lock()
        defer { lock.unlock() }
        latestFoldedPlan = (modelKey, plan)
        guard foldedPlanCache[key] == nil else { return }
        foldedPlanCache[key] = plan
        foldedPlanOrder.append(key)
        if foldedPlanOrder.count > maxFoldedPlans {
            let oldest = foldedPlanOrder.removeFirst()
            foldedPlanCache.removeValue(forKey: oldest)
        }
    }

    func solidMesh(key: String, build: () -> ViewportFlatShadedMesh?) -> ViewportFlatShadedMesh? {
        lock.lock()
        if let cached = solidMeshCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let built = build() else { return nil }
        lock.lock()
        solidMeshCache[key] = built
        solidInsertionOrder.append(key)
        if solidInsertionOrder.count > maxSolidEntries, let oldest = solidInsertionOrder.first {
            solidInsertionOrder.removeFirst()
            solidMeshCache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return built
    }

    private var scaledModelKey = ""
    private var scaledModelValue: MeshSummary?

    /// Memoized transformed mesh (per-axis scale + rotation). `effectiveModel`
    /// is a computed property touched many times per SwiftUI render; without
    /// this, any non-identity transform re-copied all vertices of the mesh on
    /// every single access.
    func transformedModel(for model: MeshSummary, scale: Vec3, rotationDegrees: Vec3) -> MeshSummary {
        let identityScale = MeshScaler.sanitizedFactor(scale.x) == 1.0
            && MeshScaler.sanitizedFactor(scale.y) == 1.0
            && MeshScaler.sanitizedFactor(scale.z) == 1.0
        let identityRotation = rotationDegrees.x == 0 && rotationDegrees.y == 0 && rotationDegrees.z == 0
        guard !(identityScale && identityRotation) else { return model }
        let key = Self.modelKey(for: model)
            + "|xf|" + scale.display + "|" + rotationDegrees.display
        lock.lock()
        if scaledModelKey == key, let scaledModelValue {
            lock.unlock()
            return scaledModelValue
        }
        lock.unlock()
        let transformed = MeshScaler.transformed(model, scale: scale, rotationDegrees: rotationDegrees)
        lock.lock()
        scaledModelKey = key
        scaledModelValue = transformed
        lock.unlock()
        return transformed
    }

    func cachedModelMesh(for model: MeshSummary) -> MeshResource? {
        lock.lock()
        defer { lock.unlock() }
        reset(ifModelChanged: Self.modelKey(for: model))
        return meshResource
    }

    func storeModelMesh(_ mesh: MeshResource, for model: MeshSummary) {
        lock.lock()
        defer { lock.unlock() }
        reset(ifModelChanged: Self.modelKey(for: model))
        meshResource = mesh
    }
}
