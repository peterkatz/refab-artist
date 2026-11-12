import Foundation

/// `--folded-audit`: simplify the model to a face budget (as the GUI does
/// before folding), build the plan, and report whether the 3D faceted shape
/// (`surfaces3D`) populated — the arbiter for "Folded shows the smooth model,
/// not the decimated panels."
enum FoldedAuditCommand {
    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--folded-audit")
        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        let detail = parser.takeDouble("--detail").map(Int.init) ?? 250
        let wantWrap = parser.takeFlag("--shrinkwrap")

        let raw = try MeshInspector.inspect(url: URL(fileURLWithPath: fixturePath))
        let base = wantWrap ? MeshModifier.shrinkwrap(raw, detail: 0.5) : raw
        let model = (base.faceCount > detail ? MeshSimplifier.simplify(base, targetFaceCount: detail) : base) ?? base

        print("=== FOLDED AUDIT: \(URL(fileURLWithPath: fixturePath).lastPathComponent)\(wantWrap ? " (shrinkwrapped)" : "") ===")
        print("faces: imported \(raw.triangleCount) → simplified \(model.triangleCount) (target \(detail))")

        let plan = FoldedPanelPlanner.plan(model: model, materialThickness: 3.0)
        let placed = plan.nets.reduce(0) { $0 + $1.panelOutlines.count }
        print("panels=\(plan.panels.count)  surfaces3D=\(plan.surfaces3D.count)  nets=\(plan.nets.count)  netPanelsPlaced=\(placed)")
        var degenerate3D = 0
        for s in plan.surfaces3D where s.count < 3 { degenerate3D += 1 }
        print("surfaces3D with <3 points: \(degenerate3D)")
        if plan.surfaces3D.isEmpty {
            print(">>> surfaces3D EMPTY → 3D viewport falls back to the smooth model.")
        } else {
            let sizes = plan.surfaces3D.prefix(5).map { $0.count }
            print("first surfaces3D vertex counts: \(sizes)")
        }

        // Replicate makeFoldedShapeEntity's per-panel pipeline (minus the final
        // RealityKit conversion): PanelPlaneFrame → flatten → mesh builder. If
        // every panel fails here, makeFoldedShapeEntity returns nil and the
        // viewport draws the smooth model.
        let thickness = parser.takeDouble("--thickness") ?? 3.0
        var frameFail = 0, meshFail = 0, ok = 0
        for surface in plan.surfaces3D {
            guard surface.count >= 3, let frame = PanelPlaneFrame(polygon: surface) else { frameFail += 1; continue }
            let flat = surface.map(frame.project)
            if ViewportSliceSolidRenderData.mesh(
                paths: [SlicePath2D(points: flat, closed: true)],
                materialThickness: thickness,
                scenePoint: frame.unproject,
                normal: frame.normal
            ) == nil {
                meshFail += 1
            } else {
                ok += 1
            }
        }
        print("PANEL PIPELINE (thickness \(thickness)): ok=\(ok)  frameFail=\(frameFail)  meshFail=\(meshFail)")
        if ok == 0 { print(">>> ALL panels fail → makeFoldedShapeEntity returns nil → smooth fallback.") }
    }
}

/// `--radial-audit`: dump the actual disk + fin parts the radial generator
/// produces (the SAME parts the cut sheet packs and the 3D viewport draws),
/// with each part's bounding size, on the model — optionally shrinkwrapped
/// first to match the GUI's "Make Watertight" state. The arbiter for "the
/// radial result is garbage": are the parts sane closed loops bounded by the
/// model, or degenerate / unbounded?
enum RadialAuditCommand {
    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--radial-audit")
        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        let thickness = parser.takeDouble("--thickness") ?? 5
        let nRadial = parser.takeDouble("--n-radial").map(Int.init) ?? 12
        let firstAxis = parser.takeDouble("--first-axis-count").map(Int.init) ?? 10
        let wantWrap = parser.takeFlag("--shrinkwrap")

        let raw = try MeshInspector.inspect(url: URL(fileURLWithPath: fixturePath))
        let model = wantWrap ? MeshModifier.shrinkwrap(raw, detail: 0.5) : raw
        guard let b = model.bounds else { print("no bounds"); return }
        let span = Vec3(x: b.max.x - b.min.x, y: b.max.y - b.min.y, z: b.max.z - b.min.z)
        let diag = (span.x * span.x + span.y * span.y + span.z * span.z).squareRoot()

        guard let plan = RadialSlicePlanner.plan(
            model: model, nRadial: nRadial, materialThickness: thickness,
            firstAxisCountOverride: firstAxis
        ) else { print("RADIAL PLAN FAILED"); return }

        func bbox(_ loop: [Vec2]) -> (w: Double, h: Double) {
            guard let f = loop.first else { return (0, 0) }
            var mnx = f.x, mny = f.y, mxx = f.x, mxy = f.y
            for p in loop { mnx = min(mnx, p.x); mny = min(mny, p.y); mxx = max(mxx, p.x); mxy = max(mxy, p.y) }
            return (mxx - mnx, mxy - mny)
        }

        print("=== RADIAL AUDIT: \(URL(fileURLWithPath: fixturePath).lastPathComponent)\(wantWrap ? " (shrinkwrapped)" : "") ===")
        print(String(format: "model span %.1f x %.1f x %.1f  (diag %.1f)  watertight=%@",
                     span.x, span.y, span.z, diag, model.preflight.isWatertight ? "YES" : "no"))
        print("n_radial=\(nRadial)  first_axis=\(firstAxis)  thickness=\(thickness)")

        let parts = RadialPartBuilder.assembly(plan: plan, model: model)
        let disks = parts.disks
        let wedges = parts.wedges
        print("DISKS: \(disks.count)   FINS: \(wedges.count)")
        _ = bbox  // (2D bbox helper retained for reference)

        guard let primary = plan.primary else { return }
        let center = Vec3(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2, z: (b.min.z + b.max.z) / 2)
        // Precise test of the reported problem: map every part point into the SCENE
        // (the exact placement the viewport/export use) and measure how far it
        // pokes past the model's own bounding box. >tol outside = unbuildable.
        let tol = 1.0
        func overshoot(_ s: Vec3) -> Double {
            let dx = max(0, max(b.min.x - s.x, s.x - b.max.x))
            let dy = max(0, max(b.min.y - s.y, s.y - b.max.y))
            let dz = max(0, max(b.min.z - s.z, s.z - b.max.z))
            return max(dx, max(dy, dz))
        }
        func checkScene(_ label: String, _ parts: [RadialPartBuilder.ModelPart],
                        _ place: (Vec2, RadialPartBuilder.ModelPart) -> Vec3) {
            var partsOutside = 0
            var worst = 0.0
            for p in parts where p.loop.count >= 3 {
                var maxOut = 0.0
                for pt in p.loop { maxOut = max(maxOut, overshoot(place(pt, p))) }
                if maxOut > tol { partsOutside += 1; worst = max(worst, maxOut) }
            }
            print(String(format: "  %@: %d/%d parts extend OUTSIDE the model box (worst overshoot %.1f mm)",
                         label as NSString, partsOutside, parts.count, worst))
        }
        checkScene("disks", disks) { pt, part in
            ViewportDowelRayPicker.scenePoint(pt, axis: primary.axis, position: part.position)
        }
        checkScene("fins", wedges) { pt, part in
            RadialPartBuilder.wedgeScenePoint(pt, center: center, axis: primary.axis, angle: part.position)
        }

        // --dump-parts <path>: write each part's MID-PLANE placed outline (no
        // extrusion) as an OBJ point cloud, one object per part. A light Python
        // surface-distance check on these separates a real outline over-reach
        // from a mere slab-extrusion artifact.
        if let dumpPath = parser.takeValue("--dump-parts") {
            var obj = ""
            func emit(_ label: String, _ parts: [RadialPartBuilder.ModelPart],
                      _ place: (Vec2, RadialPartBuilder.ModelPart) -> Vec3) {
                for (i, part) in parts.enumerated() where part.loop.count >= 3 {
                    obj += "o \(label)_\(i)\n"
                    for pt in part.loop {
                        let s = place(pt, part)
                        obj += "v \(s.x) \(s.y) \(s.z)\n"
                    }
                }
            }
            emit("disk", disks) { pt, part in
                ViewportDowelRayPicker.scenePoint(pt, axis: primary.axis, position: part.position)
            }
            emit("fin", wedges) { pt, part in
                RadialPartBuilder.wedgeScenePoint(pt, center: center, axis: primary.axis, angle: part.position)
            }
            try? obj.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
            print("dumped \(disks.count + wedges.count) part outlines to \(dumpPath)")
        }
    }
}

/// `--mesh-audit`: report a model's manifold health, then what Repair (winged
/// fin / degenerate removal) and Shrinkwrap (voxel rewrap) each do to it. The
/// arbiter for "every slicing mode produces garbage on my scan" — slicing a
/// non-watertight mesh can't help but fragment.
enum MeshAuditCommand {
    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--mesh-audit")
        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        let detail = parser.takeDouble("--shrinkwrap-detail") ?? 0.5
        let raw = try MeshInspector.inspect(url: URL(fileURLWithPath: fixturePath))

        func report(_ label: String, _ p: MeshPreflightReport, tris: Int) {
            // Honest verdict: `isWatertight` means "closed, usable solid". For a
            // Manifold-validated heal output, residual non-manifold edges are
            // benign self-contact (shown in the column, noted here) — not holes.
            let note = (p.manifoldValidated && p.nonManifoldEdgeCount > 0)
                ? " (closed solid; \(p.nonManifoldEdgeCount) self-contact edges, Manifold-validated)" : ""
            print(String(format: "%-22@  tris=%d  degenerate=%d  open-edges=%d  non-manifold=%d  watertight=%@%@",
                         label as NSString, tris, p.degenerateTriangleCount, p.boundaryEdgeCount, p.nonManifoldEdgeCount,
                         p.isWatertight ? "YES" : "no", note))
        }

        print("=== MESH AUDIT: \(URL(fileURLWithPath: fixturePath).lastPathComponent) ===")
        report("imported", raw.preflight, tris: raw.triangleCount)

        // Mirrors the GUI's Repair button (safeRepair), not the pipeline pre-clean.
        let repaired = MeshManifoldRepair.safeRepair(raw.geometry).geometry
        report("after Repair", MeshPreflight.analyze(geometry: repaired), tris: repaired.triangleIndices.count / 3)

        let wrapped = MeshModifier.shrinkwrap(raw, detail: detail)
        report("after Shrinkwrap", wrapped.preflight, tris: wrapped.triangleCount)
    }
}

/// `--dowel-audit`: run the EXACT GUI dowel-placement pipeline on a real model
/// and print what Automatic produces. A diagnostic arbiter for "the dowels
/// don't work on my model" — the GUI and this share DowelLayout.placements +
/// StackedSliceContourer over the layers closed across any cracks
/// (`closingCracks`), so what prints here is what the viewport draws and the
/// exports drill.
enum DowelAuditCommand {
    static func run(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)
        _ = parser.takeFlag("--dowel-audit")

        guard let fixturePath = parser.takeValue("--fixture") else {
            throw HeadlessExportError.missingFixture
        }
        let thickness = parser.takeDouble("--thickness") ?? 5
        let count = parser.takeDouble("--dowel-count").map(Int.init) ?? 4
        let diameter = parser.takeDouble("--dowel-diameter") ?? 6.35
        let inset = parser.takeDouble("--dowel-inset") ?? 6.0
        let importUnitValue = parser.takeValue("--import-unit") ?? ImportUnitPreset.millimeters.rawValue
        let importUnit = ImportUnitPreset.cliValue(importUnitValue) ?? .millimeters
        let scale = parser.takeDouble("--scale") ?? 1

        let rawModel = try MeshInspector.inspect(url: URL(fileURLWithPath: fixturePath))
        let factor = MeshScaler.combinedFactor(unit: importUnit, userScale: scale)
        let model = MeshScaler.scaled(rawModel, factor: factor)

        let axis: SliceAxis
        if let raw = parser.takeValue("--axis"), let parsed = SliceAxis(rawValue: raw) {
            axis = parsed
        } else {
            axis = .z
        }

        guard let plan = StackedSlicePlanner.plan(model: model, axis: axis, materialThickness: thickness) else {
            print("PLAN FAILED")
            return
        }
        let contours = StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan))

        let settings = DxfExporter.DowelSettings(
            enabled: true, diameter: diameter, inset: inset,
            manualPositions: nil, shape: .round, automaticCount: count
        )
        let placements = DowelLayout.placements(layers: contours.layers, settings: settings)

        let b = model.bounds
        print("=== DOWEL AUDIT: \(URL(fileURLWithPath: fixturePath).lastPathComponent) ===")
        if let b {
            print(String(format: "bounds  X[%.1f..%.1f] Y[%.1f..%.1f] Z[%.1f..%.1f]",
                         b.min.x, b.max.x, b.min.y, b.max.y, b.min.z, b.max.z))
        }
        print("axis=\(axis.rawValue)  thickness=\(thickness)  layers=\(contours.layers.count)  positions=\(plan.positions.count)")

        // Per-layer material presence: how many layers actually carry a closed
        // loop, and their material area (rough). A dowel can only thread layers
        // with material at its (x,y).
        var withMaterial = 0
        for layer in contours.layers where layer.paths.contains(where: { $0.closed }) {
            withMaterial += 1
        }
        print("layers with closed material: \(withMaterial)/\(contours.layers.count)")

        print("requested rods: \(count)   PLACED: \(placements.count)")
        guard let bb = b else { print("no bounds"); return }
        let (axisLo, axisHi) = axisExtent(bounds: bb, axis: axis)
        var allWithinBounds = true
        for (i, p) in placements.enumerated() {
            let threaded = p.lastLayer - p.firstLayer + 1
            // The rod the viewport renders spans [low, high] + 0.7t margin each
            // end (makeDowelPinsEntity). Verify it sits INSIDE the model — a
            // rod poking far into empty air is the "floating" bug.
            let low = plan.positions[p.firstLayer] - thickness * 0.7
            let high = plan.positions[p.lastLayer] + thickness * 0.7
            let within = low >= axisLo - thickness && high <= axisHi + thickness
            allWithinBounds = allWithinBounds && within
            print(String(format: "  rod %d: (%.1f, %.1f)  layers %d..%d  threads %d/%d  rod-extent[%.1f..%.1f] within model[%.1f..%.1f]: %@",
                         i, p.position.x, p.position.y, p.firstLayer, p.lastLayer, threaded, contours.layers.count,
                         low, high, axisLo, axisHi, within ? "YES" : "NO ***FLOATING***"))
        }
        print("all rods within model bounds: \(allWithinBounds ? "YES" : "NO")")

        // ── Edit-session simulation: prove add/move/delete on the REAL model ──
        let threshold = max(diameter, 6.0)
        func covers(_ pt: Vec2) -> Bool {
            contours.layers.contains { !DowelLayout.positionsCovered(by: $0, positions: [pt]).isEmpty }
        }
        var rods = placements.map(\.position)
        print("--- edit session ---")
        print("start: \(rods.count) rods")
        // Add at the model's plan-centre (guaranteed on material for most models).
        let cx = ((bb.min.x + bb.max.x) / 2)
        let cy = ((bb.min.y + bb.max.y) / 2)
        let centre: Vec2
        switch axis {
        case .x: centre = Vec2(x: (bb.min.y + bb.max.y) / 2, y: (bb.min.z + bb.max.z) / 2)
        case .y: centre = Vec2(x: (bb.min.x + bb.max.x) / 2, y: (bb.min.z + bb.max.z) / 2)
        case .z: centre = Vec2(x: cx, y: cy)
        }
        if let added = DowelEditing.add(centre, to: rods, threshold: threshold, covers: covers) {
            rods = added
            print(String(format: "add at centre (%.1f,%.1f): now %d rods", centre.x, centre.y, rods.count))
        } else {
            print(String(format: "add at centre (%.1f,%.1f): rejected (no material there)", centre.x, centre.y))
        }
        if !rods.isEmpty {
            let target = Vec2(x: rods[0].x + threshold * 2, y: rods[0].y)
            if let moved = DowelEditing.move(from: rods[0], to: target, in: rods, threshold: threshold, covers: covers) {
                rods = moved
                print(String(format: "move rod 0 by %.1fmm: ok, now at (%.1f,%.1f)", threshold * 2, target.x, target.y))
            } else {
                print("move rod 0: rejected (target off material) — rod preserved, did not vanish")
            }
        }
        let before = rods.count
        if let removed = DowelEditing.remove(near: rods.first ?? centre, from: rods, threshold: threshold) {
            rods = removed
            print("delete nearest: \(before) -> \(rods.count) rods")
        }
        // Delete everything and confirm it STAYS empty (no auto-resurrect).
        while let r = rods.first, let removed = DowelEditing.remove(near: r, from: rods, threshold: threshold) {
            rods = removed
        }
        print("delete all -> \(rods.count) rods (must be 0; manual empty stays empty)")
    }

    private static func axisExtent(bounds: Bounds3D?, axis: SliceAxis) -> (Double, Double) {
        guard let b = bounds else { return (0, 0) }
        switch axis {
        case .x: return (b.min.x, b.max.x)
        case .y: return (b.min.y, b.max.y)
        case .z: return (b.min.z, b.max.z)
        }
    }
}
