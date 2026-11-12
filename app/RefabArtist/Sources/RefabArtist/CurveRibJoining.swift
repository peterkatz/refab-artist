import Foundation

/// Moving first-axis ribs off the even spacing so the joints hold every part.
///
/// The first-axis ribs stand at even spacing (`StackedSlicePlanner`), which
/// knows nothing of the model's shape. A rib can then pass just below or
/// above where a lobe of the model joins the rest (a thumb that meets the
/// palm a millimetre over the rib), so the lobe's pieces of the ribs that
/// cross it are joined to each other but to nothing else: they would be shown
/// blue, to be glued. Moving one rib a little, so that it crosses the lobe
/// where it is still joined to the rest, joins them.
extension CurveSlicePlanner {
    /// A first-axis rib is moved by whole steps of this fraction of the even
    /// spacing, up to `joiningSteps` of them (three eighths of the spacing).
    static let joiningStep = 1.0 / 16.0
    static let joiningSteps = 6

    /// `plan` with first-axis ribs moved off the even spacing where that
    /// lets the joints hold parts that would otherwise be joined only among
    /// themselves (`CurveJointPlanner.Piece.detached`), the positions they
    /// had at even spacing kept in `evenFirstAxisPositions`; `plan` itself
    /// when every part is joined to the rest already or no move helps.
    ///
    /// While some parts are joined only among themselves, the first-axis ribs
    /// that hold one of them and their neighbours are tried, each at most
    /// once, nearest move first: one step of `joiningStep` of the spacing,
    /// then two, up to `joiningSteps`; at each, the ribs in order, toward the
    /// lower end first. A move is taken only when it joins parts to the rest
    /// of the model: fewer parts are joined only among themselves, the moved
    /// rib has a part joined to the rest, every other rib that had one still
    /// has one (the parts counted as the model stay the model), and either
    /// more parts of the other ribs are joined to the rest or the moved rib
    /// has fewer parts joined only among themselves than it had. Nothing may
    /// be lost on the way: every rib that had a part still has one, no more
    /// pieces are left out (a rib whose section has material but no part, cut
    /// away whole where the curve ribs stop, counts as left out) and no more
    /// parts are narrower than the stock. A move must also keep every two
    /// neighbouring ribs at least `firstAxisPitch` apart and inside the
    /// model's extent, and keep the curve ribs standing clear
    /// (`CurveJointPlanner.RibLayout.standsClear`).
    /// A plan already moved is returned as it is.
    static func joiningGroups(_ plan: CurveSlicePlan, model: MeshSummary) -> CurveSlicePlan {
        let primary = plan.primary
        let count = primary.positions.count
        guard plan.evenFirstAxisPositions == nil, count >= 1, primary.rangeMax > primary.rangeMin else { return plan }
        let spacing = (primary.rangeMax - primary.rangeMin) / Double(count)
        let curve = CurveSliceContourer.generate(model: model, plan: plan)

        // First-axis sections, cut and cleaned as `firstAxisContours` cuts
        // them (each layer on its own), once per position tried.
        let triangles = CurveSliceContourer.meshTriangles(model)
        let winding = MeshWinding(triangles: triangles)
        var sections: [Double: SliceContourLayer] = [:]
        func section(_ position: Double) -> SliceContourLayer {
            if let cached = sections[position] { return cached }
            let single = StackedSlicePlan(
                axis: primary.axis,
                materialThickness: primary.materialThickness,
                rangeMin: primary.rangeMin,
                rangeMax: primary.rangeMax,
                positions: [position],
                positionsOverride: nil
            )
            let paths = StackedSliceContourer.generate(model: model, plan: single).layers.first?.paths ?? []
            let layer = SliceContourLayer(
                position: position,
                paths: CurveSliceContourer.cleaned(
                    paths,
                    edges: CurveSliceContourer.sectionEdges(triangles, axis: primary.axis, position: position),
                    winding: winding
                )
            )
            sections[position] = layer
            return layer
        }

        struct Outcome {
            var plan: CurveSlicePlan
            var slots: CurveJointPlanner.Slots
            /// Parts joined only among themselves.
            var detached: Int
            var leftOut: Int
            var thin: Int
            /// The ribs of each family with at least one part, and those with
            /// a part joined to the rest of the model.
            var primaryCut: Set<Int>
            var curveCut: Set<Int>
            var primaryJoined: Set<Int>
            var curveJoined: Set<Int>

            /// The parts of first-axis rib `rib` joined only among themselves.
            func detachedParts(of rib: Int) -> Int {
                slots.primaryPieces.indices.contains(rib) ? slots.primaryPieces[rib].filter(\.detached).count : 0
            }

            /// The parts of every rib but first-axis rib `rib` (both
            /// families) joined to the rest of the model.
            func joinedParts(besides rib: Int) -> Int {
                let primary = slots.primaryPieces.indices.filter { $0 != rib }.flatMap { slots.primaryPieces[$0] }
                return (primary + slots.curvePieces.flatMap { $0 }).filter { !$0.detached }.count
            }

            /// Whether moving first-axis rib `rib` from `before` joins parts
            /// to the rest of the model and loses nothing on the way.
            func joins(_ before: Outcome, moving rib: Int) -> Bool {
                guard !slots.joints.isEmpty, detached < before.detached, primaryJoined.contains(rib) else { return false }
                // The parts counted as the model stay the model.
                guard before.primaryJoined.subtracting([rib]).isSubset(of: primaryJoined),
                      before.curveJoined.isSubset(of: curveJoined) else { return false }
                // Parts of the other ribs join it, or the moved rib's own
                // parts that were joined only among themselves do.
                guard joinedParts(besides: rib) > before.joinedParts(besides: rib)
                    || (before.detachedParts(of: rib) > 0 && detachedParts(of: rib) < before.detachedParts(of: rib)) else { return false }
                // Nothing is lost.
                return before.primaryCut.isSubset(of: primaryCut)
                    && before.curveCut.isSubset(of: curveCut)
                    && leftOut <= before.leftOut
                    && thin <= before.thin
            }
        }
        func outcome(_ candidate: CurveSlicePlan) -> Outcome {
            let layers = candidate.primary.positions.map(section)
            let contours = StackedSliceContours(axis: primary.axis, layers: layers)
            let slots = CurveJointPlanner.slots(plan: candidate, primary: contours, curve: curve)
            let pieces = slots.primaryPieces.flatMap { $0 } + slots.curvePieces.flatMap { $0 }
            func ribs(_ family: [[CurveJointPlanner.Piece]], holding: (CurveJointPlanner.Piece) -> Bool) -> Set<Int> {
                Set(family.indices.filter { family[$0].contains(where: holding) })
            }
            // A rib with material in its section but no part, and no piece
            // counted as left out, was cut away whole (a curve rib whose
            // reach is empty): it is left out too.
            func cutAwayWhole(_ sections: [[SlicePath2D]], _ kept: [[CurveJointPlanner.Piece]], _ leftOut: [Int]) -> Int {
                sections.indices.filter { layer in
                    !CurveJointPlanner.closedLoops(sections[layer]).isEmpty
                        && (!kept.indices.contains(layer) || kept[layer].isEmpty)
                        && !leftOut.contains(layer)
                }.count
            }
            return Outcome(
                plan: candidate,
                slots: slots,
                detached: pieces.filter(\.detached).count,
                leftOut: slots.primaryLeftOut.count + slots.curveLeftOut.count
                    + cutAwayWhole(layers.map(\.paths), slots.primaryPieces, slots.primaryLeftOut)
                    + cutAwayWhole(curve.layers.map(\.paths), slots.curvePieces, slots.curveLeftOut),
                thin: pieces.filter(\.thin).count,
                primaryCut: ribs(slots.primaryPieces) { _ in true },
                curveCut: ribs(slots.curvePieces) { _ in true },
                primaryJoined: ribs(slots.primaryPieces) { !$0.detached },
                curveJoined: ribs(slots.curvePieces) { !$0.detached }
            )
        }

        var current = outcome(plan)
        guard current.detached > 0 else { return plan }
        let pitch = firstAxisPitch(
            axis: primary.axis,
            controlPoints: plan.controlPoints,
            slotWidth: plan.slotWidth,
            thickness: primary.materialThickness
        )
        let laidOutClear = CurveJointPlanner.ribLayout(plan: plan).standsClear
        var moved = Set<Int>()
        while current.detached > 0 {
            let holding = current.slots.primaryPieces.indices.filter { layer in
                current.slots.primaryPieces[layer].contains(where: \.detached)
            }
            let candidates = Set(holding.flatMap { [$0 - 1, $0, $0 + 1] })
                .filter { (0..<count).contains($0) && !moved.contains($0) }
                .sorted()
            var taken: (rib: Int, outcome: Outcome)?
            search: for step in 1...joiningSteps {
                for rib in candidates {
                    for sign in [-1.0, 1.0] {
                        var positions = current.plan.primary.positions
                        let target = primary.positions[rib] + sign * Double(step) * joiningStep * spacing
                        guard target > primary.rangeMin, target < primary.rangeMax else { continue }
                        positions[rib] = target
                        if rib > 0, positions[rib] - positions[rib - 1] < pitch - 1.0e-9 { continue }
                        if rib + 1 < count, positions[rib + 1] - positions[rib] < pitch - 1.0e-9 { continue }
                        var candidate = current.plan
                        candidate.primary.positions = positions
                        if laidOutClear, !CurveJointPlanner.ribLayout(plan: candidate).standsClear { continue }
                        let next = outcome(candidate)
                        if next.joins(current, moving: rib) {
                            taken = (rib, next)
                            break search
                        }
                    }
                }
            }
            guard let taken else { break }
            moved.insert(taken.rib)
            current = taken.outcome
        }
        guard !moved.isEmpty else { return plan }
        var joined = current.plan
        joined.evenFirstAxisPositions = primary.positions
        return joined
    }
}
