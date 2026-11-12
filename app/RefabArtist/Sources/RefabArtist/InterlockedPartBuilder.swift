import Foundation

/// Builds the flat slotted parts of an Interlocked ("waffle") model, laid out
/// in page-fit inch coordinates.
///
/// Nothing here is keyed to a particular model. Everything that defines the
/// slot geometry — slot count, pitch, width, depth, the family-dependent open
/// edge, the mouth flare, and the per-slice colinear stairstep breakpoint — is
/// COMPUTED from the slice families, the kerf/thickness/notch parameters, and
/// the page-fit scale.
///
/// Mechanism:
///   * The part emits two slice families: a primary family along the slice
///     axis and a secondary family along `slice_normal × slice_up`. Each family
///     is spaced `slice_depth` apart across the model extent.
///   * Every slice part is ONE connected CCW boundary loop: the cross-section
///     polygon with registration slots carved into the perimeter on a
///     family-dependent edge (primary opens one edge, secondary the opposite),
///     so the two families mate at the mid-plane.
///   * Slot pitch = the crossing family spacing (`slice_depth`). Each slot is
///     centered on a crossing-family position, opens from the family edge, and
///     runs inward to the mid-plane (half the in-plane extent). The slot is
///     `plan.slotWidth` wide — the stock thickness plus the slot offset, or the
///     notch-width override — so the crossing part seats in it; the mouth
///     flares slightly per `notch_widen_angle`. Slots that would overlap (stock
///     as thick as the slice spacing) merge into one wider cut.
///   * The solid edge opposite the slots carries the per-slice stairstep
///     breakpoint: a colinear vertex whose offset advances by `slice_depth`
///     per slice (it lies on the straight edge, so the cut shape is unchanged).
///
/// Layout: page-fit scaled to 8in / max-in-plane-dim with a 0.2625in margin.
/// The cut sheet scales the parts back to true mm and packs them onto sheets.
enum InterlockedPartBuilder {
    // Page-fit geometry (inches).
    static let marginIn = 0.2625
    static let fitContentIn = 8.0

    /// One slice-part boundary loop in page (inch) coordinates before final
    /// sheet packing.
    struct Part {
        /// Single closed CCW boundary loop in page (inch) coordinates.
        var loop: [Vec2]
        /// 1-based label string for the part.
        var label: String
        /// Bounding box of the loop, for annotation/label placement.
        var bounds: (min: Vec2, max: Vec2)
        /// Provenance metadata for GUI labeling (Axis-slice-piece). Defaults
        /// keep the export construction paths unchanged.
        var family: Family = .primary
        /// 0-based slice index within the part's family.
        var sliceIndex: Int = 0
        /// 0-based piece index within the slice (disconnected components).
        var pieceIndex: Int = 0
        /// A slot consumed (nearly) the whole local depth at some level — the
        /// crossing slice severs this part there. The preview flags such
        /// parts red ("Notches split part"); never exported.
        var isError = false
        /// Slot relief ("dog bone") discs to cut out of `loop`, in the same
        /// page coordinates: one at each inside corner of a slot when the plan
        /// asks for slot relief, placed so its rim passes through the corner.
        var reliefDiscs: [(center: Vec2, radius: Double)] = []
    }

    /// An inside corner of a slot, where the slot bottom meets a slot wall,
    /// and the unit diagonal from it into the slot.
    private struct SlotCorner {
        var point: Vec2
        var intoSlot: Vec2
    }

    enum Family {
        case primary
        case secondary
    }

    /// Build all slice parts for the plan.
    ///
    /// Parts are emitted largest-first: the page sequence is ordered by
    /// descending part height (the dimension that varies across a round model's
    /// chords), with the natural build order — primary family then secondary,
    /// each in slice order — preserved as a stable tiebreak among equal-sized
    /// parts. For a model whose every slice has the same cross-section (the
    /// cube: all parts are the identical full square) every height is equal, so
    /// the sort is a stable no-op and the page order is unchanged; for a round
    /// model the largest chords lead, so the biggest parts are placed first.
    static func parts(
        plan: InterlockedSlicePlan,
        model: MeshSummary,
        includeDisconnectedComponents: Bool = false
    ) -> [Part] {
        guard let bounds = model.bounds else { return [] }
        let fit = pageFitScale(plan: plan, bounds: bounds)

        let primaryContours = StackedSliceContourer.generate(model: model, plan: plan.primary)
        let secondaryContours = StackedSliceContourer.generate(model: model, plan: plan.secondary)

        var built: [Part] = []
        for (sliceIndex, layer) in primaryContours.layers.enumerated() {
            for (pieceIndex, boundary) in selectedBoundaries(layer, includeDisconnectedComponents: includeDisconnectedComponents).enumerated() {
                if var part = buildPart(family: .primary, sliceIndex: sliceIndex, boundary: boundary, plan: plan, bounds: bounds, fit: fit, label: "") {
                    part.family = .primary
                    part.sliceIndex = sliceIndex
                    part.pieceIndex = pieceIndex
                    built.append(part)
                }
            }
        }
        for (sliceIndex, layer) in secondaryContours.layers.enumerated() {
            for (pieceIndex, boundary) in selectedBoundaries(layer, includeDisconnectedComponents: includeDisconnectedComponents).enumerated() {
                if var part = buildPart(family: .secondary, sliceIndex: sliceIndex, boundary: boundary, plan: plan, bounds: bounds, fit: fit, label: "") {
                    part.family = .secondary
                    part.sliceIndex = sliceIndex
                    part.pieceIndex = pieceIndex
                    built.append(part)
                }
            }
        }

        // Stable largest-first ordering: sort by descending part height, using
        // the build index as the tiebreak so equal-height parts keep
        // their natural primary-then-secondary, in-slice-order sequence. For the
        // cube every part is the same size, so the whole list stays in natural
        // build order and the cube output is byte-identical; for a round model
        // the largest chords lead.
        let ordered = built.enumerated()
            .sorted { lhs, rhs in
                let lh = lhs.element.bounds.max.y - lhs.element.bounds.min.y
                let rh = rhs.element.bounds.max.y - rhs.element.bounds.min.y
                if abs(lh - rh) > heightOrderEpsilon { return lh > rh }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        // Re-label 1..N in final page order.
        return ordered.enumerated().map { index, part in
            var relabeled = part
            relabeled.label = "\(index + 1)"
            return relabeled
        }
    }

    /// Height tie tolerance (page units) for the largest-first part ordering.
    private static let heightOrderEpsilon = 1.0e-6

    // MARK: - Page-fit scale

    /// Page-fit scale = fitContent (8in) / max in-plane model dimension (mm),
    /// so the largest section spans the 8in content box. The in-plane
    /// dimensions are the two axes perpendicular to the slice axis; we take the
    /// largest across both families so every part fits the 8in content box.
    static func pageFitScale(plan: InterlockedSlicePlan, bounds: Bounds3D) -> Double {
        let dims = [
            extent(bounds, axis: .x),
            extent(bounds, axis: .y),
            extent(bounds, axis: .z)
        ]
        // In-plane axes for either family never include nothing useful here;
        // the max in-plane dimension across both families is simply the max of
        // the two non-slice-axis extents for the primary slice (the largest
        // cross-section any slice can have). Using the global max of all three
        // axis extents is equivalent for the perpendicular planes and keeps the
        // result independent of which axis is primary.
        let maxInPlane = inPlaneMax(plan: plan, bounds: bounds)
        guard maxInPlane > 0 else {
            // Degenerate; fall back so we never divide by zero.
            let fallback = dims.max() ?? 1
            return fallback > 0 ? fitContentIn / fallback : 1
        }
        return fitContentIn / maxInPlane
    }

    private static func inPlaneMax(plan: InterlockedSlicePlan, bounds: Bounds3D) -> Double {
        let primaryInPlane = projectionAxes(for: plan.primary.axis).map { extent(bounds, axis: $0) }
        let secondaryInPlane = projectionAxes(for: plan.secondary.axis).map { extent(bounds, axis: $0) }
        return (primaryInPlane + secondaryInPlane).max() ?? 0
    }

    // MARK: - Per-part construction

    private static func buildPart(
        family: Family,
        sliceIndex: Int,
        boundary: [Vec2],
        plan: InterlockedSlicePlan,
        bounds: Bounds3D,
        fit: Double,
        label: String
    ) -> Part? {
        let slicedPlan = family == .primary ? plan.primary : plan.secondary
        let crossingPlan = family == .primary ? plan.secondary : plan.primary

        // Determine the in-plane axes of this slice. The page layout always
        // renders the DEPTH direction horizontally (page X) — the
        // slots are cut horizontally inward from a vertical edge — and lays the
        // crossing-family positions vertically (page Y). The crossing axis is
        // therefore placed on page Y, and the remaining in-plane axis (the one
        // the slots cut along) is the depth axis on page X.
        let inPlane = projectionAxes(for: slicedPlan.axis) // the two model axes in this slice plane
        guard inPlane.contains(crossingPlan.axis) else {
            // Crossing axis is not in this slice's plane — cannot interlock.
            return nil
        }
        let crossingAxis = crossingPlan.axis
        let depthAxis = inPlane.first { $0 != crossingAxis } ?? crossingAxis

        // Page-fit transform: page = margin + (model - modelMin) * fit, per axis.
        let depthMinModel = coordinate(bounds.min, axis: depthAxis)
        let depthMaxModel = coordinate(bounds.max, axis: depthAxis)
        let crossMinModel = coordinate(bounds.min, axis: crossingAxis)
        let crossMaxModel = coordinate(bounds.max, axis: crossingAxis)

        // Full-bbox page rectangle (the cube path; also the degenerate fallback).
        let bboxDepthMinPage = marginIn
        let bboxDepthMaxPage = marginIn + (depthMaxModel - depthMinModel) * fit
        let bboxCrossMinPage = marginIn
        let bboxCrossMaxPage = marginIn + (crossMaxModel - crossMinModel) * fit

        // Real per-slice cross-section: replace the constant bbox extents with the
        // actual contour's depth/crossing span (the per-slice chord). For a box
        // cross-section the contour *is* the bbox rectangle, so these reduce to
        // the bbox extents above and the cube output stays byte-identical. For a
        // round/clipped cross-section (cylinder chord) the crossing span shrinks
        // per slice, so each part is only as tall as its own section.
        //
        // The contour points live in the slice's projection space, where
        // projection.x = projectionAxes[0] and projection.y = projectionAxes[1]
        // (see StackedSliceContourer.project). Map each point to (depth, crossing)
        // model coordinates, then through the identical page-fit transform.
        let projAxes = inPlane // == projectionAxes(for: slicedPlan.axis), in project() order
        let depthProjIndex = projAxes.firstIndex(of: depthAxis)
        let crossProjIndex = projAxes.firstIndex(of: crossingAxis)

        var depthMinPage = bboxDepthMinPage
        var depthMaxPage = bboxDepthMaxPage
        var crossMinPage = bboxCrossMinPage
        var crossMaxPage = bboxCrossMaxPage

        // The real cross-section contour mapped to page (u=depth=x, v=crossing=y)
        // coordinates, hoisted so the curved-section branch below can trace the
        // ACTUAL boundary instead of a bbox rectangle. Empty when the projection
        // axes can't be resolved (degenerate fallback → bbox rectangle path).
        var canonical: [Vec2] = []
        if let di = depthProjIndex,
           let ci = crossProjIndex {
            // Canonical (u=depth, v=crossing) in page coordinates, via the same
            // transform used for the bbox so a square lands on identical constants.
            // For the cube the contour's extreme vertices ARE the bbox corners, so
            // every page extent below is bit-for-bit equal to the bbox values and
            // the cube output stays byte-identical; for a chord they shrink.
            canonical = boundary.map { p in
                let depthModel = (di == 0) ? p.x : p.y
                let crossModel = (ci == 0) ? p.x : p.y
                return Vec2(
                    x: marginIn + (depthModel - depthMinModel) * fit,
                    y: marginIn + (crossModel - crossMinModel) * fit
                )
            }
            let us = canonical.map(\.x), vs = canonical.map(\.y)
            depthMinPage = us.min() ?? bboxDepthMinPage
            depthMaxPage = us.max() ?? bboxDepthMaxPage
            crossMinPage = vs.min() ?? bboxCrossMinPage
            crossMaxPage = vs.max() ?? bboxCrossMaxPage
        }

        // Each part is laid out from its own corner: the part's crossing chord
        // is shifted so its minimum lands on the page margin (rather than at the
        // part's position within the global bbox). Every part is cut and laid
        // out independently, so a narrow chord sits at the margin, not
        // floating where its slice plane crosses the model. For the cube every
        // slice's crossing extent already starts at the bbox edge (== margin),
        // so the shift is zero and the cube output is byte-identical.
        let crossShift = crossMinPage - marginIn
        crossMinPage -= crossShift
        crossMaxPage -= crossShift
        // Keep the traced contour in the same re-zeroed crossing space the slot
        // grid uses: crossShift was applied to the extents above but not yet to
        // the contour points.
        if crossShift != 0 {
            canonical = canonical.map { Vec2(x: $0.x, y: $0.y - crossShift) }
        }

        let depthMidPage = (depthMinPage + depthMaxPage) / 2

        // Slot half-width (page units): half the plan's slot width.
        let slitHalfModel = slotHalfWidth(plan: plan)
        let slitHalfPage = slitHalfModel * fit
        // Inner-wall depth offset past the mid-plane and edge inset/flare —
        // small kerf-derived offsets that taper the slot mouth per the notch
        // widen angle. All are sub-kerf and parametric in (kerf, angle).
        let innerOffPage = innerDepthOffset(plan: plan) * fit
        let edgeEpsPage = edgeInset(plan: plan) * fit
        let flarePage = mouthFlare(plan: plan, slitHalf: slitHalfModel) * fit

        // Crossing positions mapped onto the crossing page axis, shifted by the
        // same amount so the slots stay registered to the re-zeroed chord.
        let crossingPagePositions = crossingPlan.positions.map { pos in
            marginIn + (pos - crossMinModel) * fit - crossShift
        }.sorted()

        // Stairstep breakpoint offset for this slice on the SOLID (opposite)
        // edge. The breakpoint advances by slice_depth per slice; primary grows
        // from the depth-min side, secondary mirrors from the depth-max side.
        let stairOffsetModel = (Double(sliceIndex) + 0.5) * slicedPlan.materialThickness
        let stairOffsetPage = stairOffsetModel * fit

        let openAtDepthMax = (family == .primary) // primary opens +depth edge; secondary opens -depth edge

        // A registration slot is only carved where its full slit fits inside
        // this slice's actual crossing extent. Slots are therefore always
        // clipped to the per-slice crossing chord. This is a strict no-op when
        // the crossing extent equals the full crossing-axis bbox (the cube /
        // fin: every crossing-family centre lies well inside the full-height
        // edge, so all slots survive and the output is byte-identical), and it
        // is what collapses a cylinder X/Y slice's part to the circular chord —
        // its boundary already shrinks per slice, and dropping the slot centres
        // that fall outside the chord removes the spurious mouths that would
        // otherwise push the part taller than the chord.
        // A genuine axis-aligned rectangle section (cube, fin, and the cylinder's
        // flat vertical chords) routes through the bbox builder, so those
        // outlines stay exact rectangles. Only a genuinely curved or
        // irregular section (sphere/torus/chair) traces its real contour and
        // splices the slots into that boundary.
        let sectionIsRectangle = canonical.isEmpty || isAxisAlignedRectangle(canonical)
        let carved: (loop: [Vec2], insideCorners: [SlotCorner])
        if sectionIsRectangle {
            carved = buildLoop(
                depthMinPage: depthMinPage,
                depthMaxPage: depthMaxPage,
                depthMidPage: depthMidPage,
                crossMinPage: crossMinPage,
                crossMaxPage: crossMaxPage,
                crossingPositions: crossingPagePositions,
                slitHalfPage: slitHalfPage,
                innerOffPage: innerOffPage,
                edgeEpsPage: edgeEpsPage,
                flarePage: flarePage,
                stairOffsetPage: stairOffsetPage,
                openAtDepthMax: openAtDepthMax,
                depthIsPageX: true,
                clipSlotsToChord: true
            )
        } else {
            // Trace the real contour; if the section is too irregular to trace
            // safely (non-v-monotone sides on a noisy dense mesh) the tracer
            // returns nil and we fall back to the bbox builder rather than emit a
            // self-intersecting part.
            carved = buildSlottedContourLoop(
                contour: canonical,
                openAtDepthMax: openAtDepthMax,
                innerU: openAtDepthMax ? (depthMidPage + innerOffPage) : (depthMidPage - innerOffPage),
                crossingPositions: crossingPagePositions,
                slitHalfPage: slitHalfPage
            ) ?? buildLoop(
                depthMinPage: depthMinPage,
                depthMaxPage: depthMaxPage,
                depthMidPage: depthMidPage,
                crossMinPage: crossMinPage,
                crossMaxPage: crossMaxPage,
                crossingPositions: crossingPagePositions,
                slitHalfPage: slitHalfPage,
                innerOffPage: innerOffPage,
                edgeEpsPage: edgeEpsPage,
                flarePage: flarePage,
                stairOffsetPage: stairOffsetPage,
                openAtDepthMax: openAtDepthMax,
                depthIsPageX: true,
                clipSlotsToChord: true
            )
        }

        let loop = carved.loop
        guard loop.count >= 3 else { return nil }
        let xs = loop.map(\.x), ys = loop.map(\.y)
        let b = (min: Vec2(x: xs.min() ?? 0, y: ys.min() ?? 0),
                 max: Vec2(x: xs.max() ?? 0, y: ys.max() ?? 0))
        // A round cutter of the relief diameter, centred one radius from the
        // corner along the diagonal into the slot, reaches the corner itself,
        // so the crossing part's square edge can seat fully.
        let reliefRadiusPage = plan.slotRelief.enabled ? plan.slotRelief.radius * fit : 0
        let reliefDiscs = reliefRadiusPage > 0
            ? carved.insideCorners.map { corner in
                (center: Vec2(x: corner.point.x + corner.intoSlot.x * reliefRadiusPage,
                              y: corner.point.y + corner.intoSlot.y * reliefRadiusPage),
                 radius: reliefRadiusPage)
            }
            : []
        return Part(loop: loop, label: label, bounds: b, reliefDiscs: reliefDiscs)
    }

    /// One slot's extent along the crossing axis (page units), before it is
    /// clamped to the part. `center` is the mean of the crossing positions
    /// the slot serves.
    private struct SlotSpan {
        var low: Double
        var high: Double
        var center: Double
    }

    /// Slot spans for the sorted crossing positions, with spans that touch or
    /// overlap merged into one: when the slots are as wide as the crossing
    /// spacing, the material between them is cut away as well.
    private static func mergedSlotSpans(_ positions: [Double], halfWidth: Double) -> [SlotSpan] {
        var spans: [SlotSpan] = []
        var members = 0
        for c in positions {
            if var last = spans.last, c - halfWidth <= last.high + slotMergeTolerance {
                last.high = max(last.high, c + halfWidth)
                last.center = (last.center * Double(members) + c) / Double(members + 1)
                members += 1
                spans[spans.count - 1] = last
            } else {
                spans.append(SlotSpan(low: c - halfWidth, high: c + halfWidth, center: c))
                members = 1
            }
        }
        return spans
    }

    /// Gap (page units) below which neighbouring slots, or a slot and the
    /// end of the part, count as touching.
    private static let slotMergeTolerance = 1.0e-9

    /// Whether neighbouring slots touch or overlap and so merge into one cut
    /// (`mergedSlotSpans`): the slices of one family stand no further apart
    /// than a slot is wide. Merged slots leave no inside corners between
    /// them.
    static func slotsMerge(plan: InterlockedSlicePlan) -> Bool {
        let width = 2 * slotHalfWidth(plan: plan)
        return [plan.primary.positions, plan.secondary.positions].contains { positions in
            let sorted = positions.sorted()
            return zip(sorted, sorted.dropFirst()).contains { $1 - $0 <= width + 1.0e-9 }
        }
    }

    /// Build the single CCW boundary loop with carved slots + stairstep.
    ///
    /// The loop is authored in a canonical orientation where the DEPTH axis is
    /// horizontal (page X) and the CROSSING axis is vertical (page Y); if the
    /// real depth axis is page Y we transpose the coordinates at the end. This
    /// keeps the slot-carving logic in one place.
    private static func buildLoop(
        depthMinPage: Double,
        depthMaxPage: Double,
        depthMidPage: Double,
        crossMinPage: Double,
        crossMaxPage: Double,
        crossingPositions: [Double],
        slitHalfPage: Double,
        innerOffPage: Double,
        edgeEpsPage: Double,
        flarePage: Double,
        stairOffsetPage: Double,
        openAtDepthMax: Bool,
        depthIsPageX: Bool,
        clipSlotsToChord: Bool
    ) -> (loop: [Vec2], insideCorners: [SlotCorner]) {
        // Canonical authoring space: u = depth (horizontal), v = crossing (vertical).
        let uMin = depthMinPage, uMax = depthMaxPage
        let vMin = crossMinPage, vMax = crossMaxPage
        // Slot inner wall (the depth the slit reaches): mid-plane, nudged past.
        let innerU = openAtDepthMax ? (depthMidPage + innerOffPage) : (depthMidPage - innerOffPage)
        let edgeU = openAtDepthMax ? uMax : uMin
        let edgeExitU = openAtDepthMax ? (uMax - edgeEpsPage) : (uMin + edgeEpsPage)

        // A slot may only be carved where the full slit fits inside the crossing
        // chord. For the bbox-rectangle (cube/fin) path every crossing position is
        // inside the full-height edge so this keeps all slots; for a clipped chord
        // only the in-chord positions survive. Disabled entirely on the bbox path
        // so the cube output stays byte-identical.
        let slotPositions = clipSlotsToChord
            ? crossingPositions.filter { $0 > vMin && $0 < vMax }
            : crossingPositions
        let slots = mergedSlotSpans(slotPositions, halfWidth: slitHalfPage)
        // A slot that reaches the chord edge is CLAMPED to the boundary and
        // carves the corner there; a slot well inside the chord is emitted
        // whole.
        func reachesBottom(_ slot: SlotSpan) -> Bool { clipSlotsToChord && slot.low <= vMin + slotMergeTolerance }
        func reachesTop(_ slot: SlotSpan) -> Bool { clipSlotsToChord && slot.high >= vMax - slotMergeTolerance }

        // The stairstep breakpoints are colinear marks on the two SOLID edges
        // (one crossing-direction, one depth-direction). They must land ON those
        // edges, so the offset is clamped to the part's actual span. For a full
        // bbox rectangle (the cube/fin) the advance never reaches the far corner
        // (10 slices × slice_depth stays inside the page-fit extent), so the
        // clamp is a no-op and the cube output is byte-identical; for a clipped
        // chord, whose span is far smaller, the clamp keeps the mark on the
        // chord edge instead of spilling past it and inflating the part.
        let crossStairOffset = min(stairOffsetPage, max(0, vMax - vMin))
        let depthStairOffset = min(stairOffsetPage, max(0, (uMax - uMin) / 2 + innerOffPage))

        var pts: [(Double, Double)] = []
        // Inside corners as (u, v, v-direction into the slot); the slot opens
        // toward the open edge in u.
        var corners: [(u: Double, v: Double, intoV: Double)] = []
        let openDirection = openAtDepthMax ? 1.0 : -1.0

        if openAtDepthMax {
            // Solid edge = u == uMin. Stairstep breakpoint at v = vMin + stair.
            let stairV = vMin + crossStairOffset
            pts.append((uMin, stairV))           // left edge breakpoint (colinear)
            pts.append((uMin, vMin))              // bottom-left corner
            pts.append((uMin + depthStairOffset, vMin)) // bottom edge breakpoint (colinear)
            if !(slots.first.map(reachesBottom) ?? false) {
                pts.append((uMax, vMin))          // bottom-right corner (carved if first slot reaches it)
            }
            for slot in slots {
                // Up the open (uMax) edge: carve the slot, clamped to the
                // chord so a near-edge slot eats the corner.
                let lo = max(slot.low, vMin)
                let hi = min(slot.high, vMax)
                if !reachesBottom(slot) {
                    pts.append((edgeU, slot.low - flarePage)) // mouth low (flared)
                    corners.append((innerU, lo, 1))
                }
                pts.append((innerU, lo))          // inner low (clamped)
                pts.append((innerU, hi))          // inner high (clamped)
                if !reachesTop(slot) {
                    pts.append((edgeExitU, hi))    // exit (slightly inset)
                    corners.append((innerU, hi, -1))
                }
            }
            if !(slots.last.map(reachesTop) ?? false) {
                pts.append((uMax, vMax))          // top-right corner (carved if last slot reaches it)
            }
            pts.append((uMin + depthStairOffset, vMax)) // top edge breakpoint (colinear)
            pts.append((uMin, vMax))              // top-left corner
        } else {
            // Solid edge = u == uMax. Stairstep breakpoint at v = vMax - stair.
            let stairV = vMax - crossStairOffset
            if !(slots.last.map(reachesTop) ?? false) {
                pts.append((uMin, vMax))          // top-left corner (start; carved if top slot reaches it)
            }
            for slot in slots.reversed() {
                // Down the open (uMin) edge: carve the slot, clamped.
                let lo = max(slot.low, vMin)
                let hi = min(slot.high, vMax)
                if !reachesTop(slot) {
                    pts.append((edgeU, slot.high + flarePage)) // mouth high (flared)
                    corners.append((innerU, hi, -1))
                }
                pts.append((innerU, hi))          // inner high (clamped)
                pts.append((innerU, lo))          // inner low (clamped)
                if !reachesBottom(slot) {
                    pts.append((edgeExitU, lo))    // exit (slightly inset)
                    corners.append((innerU, lo, 1))
                }
            }
            if !(slots.first.map(reachesBottom) ?? false) {
                pts.append((uMin, vMin))          // bottom-left corner (carved if bottom slot reaches it)
            }
            pts.append((uMax - depthStairOffset, vMin)) // bottom edge breakpoint (colinear)
            pts.append((uMax, vMin))              // bottom-right corner
            pts.append((uMax, stairV))            // right edge breakpoint (colinear)
            pts.append((uMax, vMax))              // top-right corner
            pts.append((uMax - depthStairOffset, vMax)) // top edge breakpoint (colinear)
        }

        // Map canonical (u,v) back to page (x,y). When depth is page X, (u,v) =
        // (x,y); otherwise depth is page Y so swap.
        func page(_ point: (Double, Double)) -> Vec2 {
            depthIsPageX ? Vec2(x: point.0, y: point.1) : Vec2(x: point.1, y: point.0)
        }
        let diagonal = 1 / 2.0.squareRoot()
        let insideCorners = corners.map { corner in
            SlotCorner(
                point: page((corner.u, corner.v)),
                intoSlot: page((openDirection * diagonal, corner.intoV * diagonal))
            )
        }
        return (ensureCCW(pts.map(page)), insideCorners)
    }

    /// Trace the ACTUAL cross-section contour (curved/clipped sections — sphere,
    /// torus tube, chair slat) and splice registration slots into its open edge,
    /// instead of approximating the part as a bbox rectangle. The slot is cut
    /// directly into the section's boundary polygon, never a bounding box.
    ///
    /// `contour` is the closed section polygon in page (x=depth, y=crossing)
    /// coordinates, already re-zeroed by crossShift. The open edge is the
    /// depth-max side for primary parts / depth-min for secondary; slots reach
    /// inward to `innerU`. Stairstep marks are intentionally omitted: on the
    /// rectangle path they are colinear no-ops that do not change the cut
    /// shape, so they do not belong on a traced contour.
    private static func buildSlottedContourLoop(
        contour: [Vec2],
        openAtDepthMax: Bool,
        innerU: Double,
        crossingPositions: [Double],
        slitHalfPage: Double
    ) -> (loop: [Vec2], insideCorners: [SlotCorner])? {
        guard contour.count >= 3 else { return nil }

        // Split the contour at its extreme-crossing (v) vertices into two arcs,
        // then classify each as the OPEN side (toward the slotted edge) or the
        // SOLID side by mean depth. A convex chord (sphere) splits cleanly.
        var botIdx = 0, topIdx = 0
        for (i, p) in contour.enumerated() {
            if p.y < contour[botIdx].y { botIdx = i }
            if p.y > contour[topIdx].y { topIdx = i }
        }
        if botIdx == topIdx { return nil }

        func arc(_ from: Int, _ to: Int) -> [Vec2] {
            var out: [Vec2] = []
            var i = from
            while true {
                out.append(contour[i])
                if i == to { break }
                i = (i + 1) % contour.count
            }
            return out
        }
        let arcA = arc(botIdx, topIdx)
        let arcB = arc(topIdx, botIdx)
        func meanX(_ a: [Vec2]) -> Double { a.reduce(0) { $0 + $1.x } / Double(max(1, a.count)) }

        // Both arcs span [vMin, vMax]; orient each ascending in v so we can
        // interpolate a single depth at any crossing height.
        var arcAasc = arcA, arcBasc = arcB
        if (arcAasc.first?.y ?? 0) > (arcAasc.last?.y ?? 0) { arcAasc.reverse() }
        if (arcBasc.first?.y ?? 0) > (arcBasc.last?.y ?? 0) { arcBasc.reverse() }
        guard arcAasc.count >= 2, arcBasc.count >= 2 else { return nil }
        func xAt(_ a: [Vec2], _ v: Double) -> Double {
            if v <= a.first!.y { return a.first!.x }
            if v >= a.last!.y { return a.last!.x }
            for i in 0..<(a.count - 1) {
                let p = a[i], q = a[i + 1]
                if (p.y <= v && v <= q.y) || (q.y <= v && v <= p.y) {
                    let dy = q.y - p.y
                    if abs(dy) < 1.0e-12 { return p.x }
                    return p.x + (v - p.y) / dy * (q.x - p.x)
                }
            }
            return a.last!.x
        }
        func xOnSide(_ side: [Vec2], at v: Double, fallback: Double? = nil) -> Double {
            guard let first = side.first, let last = side.last else { return fallback ?? innerU }
            if v <= first.y { return first.x }
            if v >= last.y { return last.x }
            for i in 0..<(side.count - 1) {
                let a = side[i], b = side[i + 1]
                if (a.y <= v && v <= b.y) || (b.y <= v && v <= a.y) {
                    let dy = b.y - a.y
                    if abs(dy) < 1.0e-12 { return a.x }
                    return a.x + (v - a.y) / dy * (b.x - a.x)
                }
            }
            return last.x
        }

        // Detect a self-pinched (figure-8 / peanut) section: the two extreme-v
        // arcs cross in depth somewhere between the ends — at the bottom lobe one
        // arc is the right boundary, at the top lobe it is the left boundary (a
        // torus tube slice tangent to the hole). A convex chord (sphere/cylinder)
        // never crosses: one arc is the left boundary throughout, the other the
        // right, so the sign of (arcA - arcB) is constant.
        let vLo = contour[botIdx].y, vHi = contour[topIdx].y
        var sawPos = false, sawNeg = false
        for k in 1...8 {
            let v = vLo + (vHi - vLo) * Double(k) / 9.0
            let d = xAt(arcAasc, v) - xAt(arcBasc, v)
            if d > 1.0e-6 { sawPos = true }
            if d < -1.0e-6 { sawNeg = true }
        }
        let isPinched = sawPos && sawNeg

        // Rebuild both sides from the depth SILHOUETTE: at every crossing level
        // the open side is the outer depth toward the open edge and the solid
        // side the outer depth toward the solid edge. For a pinched (figure-8)
        // section both silhouettes converge at the waist, tracing the real
        // peanut outline; for an irregular organic section this produces a
        // v-monotone outline that follows the section's real profile instead
        // of its bounding rectangle. By construction it can never
        // self-intersect.
        func silhouetteSides() -> (open: [Vec2], solid: [Vec2]) {
            var levels = (arcAasc.map(\.y) + arcBasc.map(\.y)).sorted()
            var dedup: [Double] = []
            for v in levels where dedup.last.map({ abs($0 - v) > 1.0e-9 }) ?? true { dedup.append(v) }
            levels = dedup
            var openAsc: [Vec2] = [], solidDesc: [Vec2] = []
            for v in levels {
                let xa = xAt(arcAasc, v), xb = xAt(arcBasc, v)
                let openX = openAtDepthMax ? max(xa, xb) : min(xa, xb)
                let solidX = openAtDepthMax ? min(xa, xb) : max(xa, xb)
                openAsc.append(Vec2(x: openX, y: v))
                solidDesc.append(Vec2(x: solidX, y: v))
            }
            return (openAsc, solidDesc.reversed())
        }

        var openSide: [Vec2]
        var solidSide: [Vec2]
        if isPinched {
            (openSide, solidSide) = silhouetteSides()
        } else {
            // Convex chord: keep the byte-stable arc assignment + guards.
            let aIsHigher = meanX(arcA) >= meanX(arcB)
            // Near-symmetric arcs (a nearly-perfect circle on a symmetric mesh) make
            // the open/solid classification a coin-flip, which can hand both the
            // primary and secondary outermost slices the SAME open side → byte-
            // identical polygons that the extractor dedups, dropping a part. When the
            // two arcs' mean depth differ by under 1% of the chord width, bail to the
            // bbox builder, whose stairstep breakpoint distinguishes the two families.
            let xExtent = (contour.map(\.x).max() ?? 0) - (contour.map(\.x).min() ?? 0)
            if abs(meanX(arcA) - meanX(arcB)) < 0.01 * xExtent { return nil }
            openSide = (aIsHigher == openAtDepthMax) ? arcA : arcB
            solidSide = (aIsHigher == openAtDepthMax) ? arcB : arcA

            // Order the open side ascending by v, the solid side descending by v.
            if (openSide.first?.y ?? 0) > (openSide.last?.y ?? 0) { openSide.reverse() }
            if (solidSide.first?.y ?? 0) < (solidSide.last?.y ?? 0) { solidSide.reverse() }
            guard openSide.count >= 2 else { return nil }

            // The clean convex trace needs both sides crossing-monotone. A
            // section that doubles back in v (an organic/noisy-mesh profile —
            // the handStand) would trace a self-intersecting part via the arc
            // split, so rebuild it from the level silhouette instead (the old
            // behavior bailed to the bbox rectangle here, which is what cut
            // organic models into slotted rectangles).
            func monotone(_ a: [Vec2], ascending: Bool) -> Bool {
                for i in 0..<(a.count - 1) {
                    let d = a[i + 1].y - a[i].y
                    if ascending && d < -1.0e-7 { return false }
                    if !ascending && d > 1.0e-7 { return false }
                }
                return true
            }
            if !monotone(openSide, ascending: true) || !monotone(solidSide, ascending: false) {
                (openSide, solidSide) = silhouetteSides()
            } else {
                let vMin = contour[botIdx].y
                let vMax = contour[topIdx].y
                let sampleLevels = crossingPositions
                    .filter { $0 > vMin && $0 < vMax }
                    .flatMap { c in [max(c - slitHalfPage, vMin), c, min(c + slitHalfPage, vMax)] }
                let levels = sampleLevels.isEmpty
                    ? stride(from: 1, through: 8, by: 1).map { k in vMin + (vMax - vMin) * Double(k) / 9.0 }
                    : sampleLevels
                let sideAssignmentCrosses = levels.contains { v in
                    let openX = xOnSide(openSide, at: v)
                    let solidX = xOnSide(solidSide, at: v)
                    return openAtDepthMax ? openX < solidX - 1.0e-7 : openX > solidX + 1.0e-7
                }
                if sideAssignmentCrosses {
                    (openSide, solidSide) = silhouetteSides()
                }
            }
        }

        let vMin = contour[botIdx].y, vMax = contour[topIdx].y

        // Open-side depth at a given crossing v (open side is v-monotone for a
        // convex chord); clamp past the ends.
        func openU(at v: Double) -> Double {
            xOnSide(openSide, at: v)
        }

        // Slots whose center lands inside this section's crossing chord. Near
        // the chord ends the slit is clamped to the boundary instead of
        // dropped; this is visible on sphere slices where the first/last
        // registration notch eats into the circular cap.
        let slots = mergedSlotSpans(
            crossingPositions.filter { $0 > vMin && $0 < vMax }.sorted(),
            halfWidth: slitHalfPage
        )

        // Solid-side depth at a crossing level (mirror of openU), for clamping
        // the slit's inner wall inside the LOCAL section.
        let solidAsc: [Vec2] = {
            var pts = solidSide
            if (pts.first?.y ?? 0) > (pts.last?.y ?? 0) { pts.reverse() }
            return pts
        }()
        func solidU(at v: Double) -> Double {
            xOnSide(solidAsc, at: v, fallback: innerU)
        }

        // Walk the open side bottom→top, splicing each slot into the real edge:
        // mouth low on the contour, in to innerU, back out to the contour.
        var open: [Vec2] = []
        var corners: [SlotCorner] = []
        let diagonal = 1 / 2.0.squareRoot()
        let openDirection = openAtDepthMax ? diagonal : -diagonal
        var oi = 0, si = 0
        while oi < openSide.count {
            if si < slots.count {
                let c = slots[si].center
                let vLo = max(slots[si].low, vMin)
                let vHi = min(slots[si].high, vMax)
                if vHi <= vLo {
                    si += 1
                    continue
                }
                // The slit's inner wall must land INSIDE the local section.
                // When the global mid-plane wall lies inside the local span
                // (every chord of the sphere and cylinder test models) it is used
                // unchanged; on an organic section that sits entirely on one
                // side of the mid-plane the wall clamps to the LOCAL half-lap
                // (midway through the local depth), and a section too shallow
                // to host a slit at all skips the slot — the crossing slice
                // doesn't materially overlap there.
                let mouthLo = openU(at: vLo)
                let mouthHi = openU(at: vHi)
                let mouth = openAtDepthMax ? min(mouthLo, mouthHi) : max(mouthLo, mouthHi)
                let solidAtCenter = solidU(at: c)
                let localSpan = abs(mouth - solidAtCenter)
                let minimumSeat = slitHalfPage * 2
                if localSpan < minimumSeat * 2 {
                    si += 1
                    continue
                }
                let localMid = (mouth + solidAtCenter) / 2
                let innerWall: Double
                if openAtDepthMax {
                    innerWall = (innerU < mouth - minimumSeat && innerU > solidAtCenter + minimumSeat)
                        ? innerU
                        : localMid
                } else {
                    innerWall = (innerU > mouth + minimumSeat && innerU < solidAtCenter - minimumSeat)
                        ? innerU
                        : localMid
                }
                if openSide[oi].y >= vLo {
                    open.append(Vec2(x: openU(at: vLo), y: vLo)) // mouth low, on contour
                    open.append(Vec2(x: innerWall, y: vLo))      // inner low
                    open.append(Vec2(x: innerWall, y: vHi))      // inner high
                    open.append(Vec2(x: openU(at: vHi), y: vHi)) // mouth high, on contour
                    // A slot clamped to the chord's end has no wall there.
                    if slots[si].low > vMin {
                        corners.append(SlotCorner(point: Vec2(x: innerWall, y: vLo),
                                                  intoSlot: Vec2(x: openDirection, y: diagonal)))
                    }
                    if slots[si].high < vMax {
                        corners.append(SlotCorner(point: Vec2(x: innerWall, y: vHi),
                                                  intoSlot: Vec2(x: openDirection, y: -diagonal)))
                    }
                    while oi < openSide.count && openSide[oi].y < vHi { oi += 1 }
                    si += 1
                    continue
                }
            }
            open.append(openSide[oi])
            oi += 1
        }

        // Assemble: solid side (top→bottom) then open side (bottom→top).
        // Near a cap the section can be shallower than the slot over part of
        // the slot's span, so the slot cuts the cap tip off and the traced
        // loop crosses itself there; resolving the crossing keeps the part
        // and drops the tip.
        let loop = StackedSliceContourer.sanitizeClosedLoop(solidSide + open)
        guard loop.count >= 3 else { return nil }
        let survivingCorners = corners.filter { corner in
            loop.contains { abs($0.x - corner.point.x) <= 1.0e-9 && abs($0.y - corner.point.y) <= 1.0e-9 }
        }
        return (ensureCCW(loop), survivingCorners)
    }

    // MARK: - Contour-aware carving (round / irregular cross-sections)

    private static func selectedBoundaries(
        _ layer: SliceContourLayer,
        includeDisconnectedComponents: Bool
    ) -> [[Vec2]] {
        if includeDisconnectedComponents {
            return boundaryLoops(layer)
        }
        return outerBoundary(layer).map { [$0] } ?? []
    }

    /// Closed boundary paths of a slice layer, as point loops in the slice's
    /// projection space. Multi-component sections (torus tubes, chair slats)
    /// must produce one part per disconnected loop; keeping only the largest
    /// loop would drop real parts.
    static func boundaryLoops(_ layer: SliceContourLayer) -> [[Vec2]] {
        var loops: [(area: Double, minX: Double, minY: Double, points: [Vec2])] = []
        for path in layer.paths where path.closed {
            var pts = path.points
            // Drop the duplicate closing point if present.
            if let first = pts.first, let last = pts.last,
               abs(first.x - last.x) <= 1.0e-7, abs(first.y - last.y) <= 1.0e-7 {
                pts.removeLast()
            }
            guard pts.count >= 3 else { continue }
            let area = abs(signedArea(pts))
            let xs = pts.map(\.x)
            let ys = pts.map(\.y)
            loops.append((
                area: area,
                minX: xs.min() ?? 0,
                minY: ys.min() ?? 0,
                points: pts
            ))
        }
        return loops.sorted { lhs, rhs in
            if abs(lhs.area - rhs.area) > 1.0e-7 { return lhs.area > rhs.area }
            if abs(lhs.minY - rhs.minY) > 1.0e-7 { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }.map(\.points)
    }

    /// The largest closed boundary path of a slice layer. Kept for callers that
    /// intentionally need a single outer profile, such as radial disk generation.
    static func outerBoundary(_ layer: SliceContourLayer) -> [Vec2]? {
        boundaryLoops(layer).first
    }

    /// True when a closed loop is an axis-aligned rectangle: exactly four unique
    /// vertices once collinear runs are collapsed, with every edge parallel to an
    /// axis. A box cross-section reduces to this, so the cube/fin route through
    /// the unchanged bbox path; only genuinely non-rectangular contours (the
    /// cylinder chord) take the per-slice clip path.
    static func isAxisAlignedRectangle(_ loop: [Vec2]) -> Bool {
        let simplified = simplifyCollinearClosed(loop)
        guard simplified.count == 4 else { return false }
        let n = simplified.count
        for i in 0..<n {
            let a = simplified[i]
            let b = simplified[(i + 1) % n]
            let dx = abs(a.x - b.x)
            let dy = abs(a.y - b.y)
            // Each edge must be horizontal or vertical (one delta ~ 0).
            if dx > 1.0e-6 && dy > 1.0e-6 { return false }
        }
        return true
    }

    /// Signed area of a non-closed point loop (shoelace).
    private static func signedArea(_ pts: [Vec2]) -> Double {
        var area = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Remove collinear interior vertices from a closed loop (no duplicate
    /// closing point on input or output).
    private static func simplifyCollinearClosed(_ input: [Vec2]) -> [Vec2] {
        var pts = input
        guard pts.count >= 3 else { return pts }
        var changed = true
        while changed, pts.count > 3 {
            changed = false
            let count = pts.count
            for index in 0..<count {
                let prev = pts[(index + count - 1) % count]
                let cur = pts[index]
                let next = pts[(index + 1) % count]
                let cross = (cur.x - prev.x) * (next.y - prev.y) - (cur.y - prev.y) * (next.x - prev.x)
                if abs(cross) <= 1.0e-7 {
                    pts.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        return pts
    }

    /// Force counter-clockwise winding (signed area > 0).
    private static func ensureCCW(_ pts: [Vec2]) -> [Vec2] {
        guard pts.count >= 3 else { return pts }
        var area = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        return area >= 0 ? pts : Array(pts.reversed())
    }

    // MARK: - Parametric material-derived slot constants
    //
    // These are functions of the kerf / thickness / notch parameters only —
    // never of model geometry — so any two models sharing material settings
    // share the same slot geometry. The kerf multipliers below are fixed
    // design constants of this slot profile.

    /// Half the slot width, in MODEL mm: half of `plan.slotWidth`, which is
    /// the stock thickness plus the slot offset, or the notch-width override.
    static func slotHalfWidth(plan: InterlockedSlicePlan) -> Double {
        max(0.05, plan.slotWidth) / 2
    }

    /// Inner-wall depth offset past the mid-plane (model mm). A small kerf-relief
    /// nudge (0.15625 × kerf) so the slit bottoms out just past center.
    static func innerDepthOffset(plan: InterlockedSlicePlan) -> Double {
        kerfFromPlan(plan) * 0.15625
    }

    /// Edge inset at the slot exit (model mm) — the kerf-relief chamfer
    /// (0.10625 × kerf) where the slit meets the open edge.
    static func edgeInset(plan: InterlockedSlicePlan) -> Double {
        kerfFromPlan(plan) * 0.10625
    }

    /// Mouth flare (model mm) widening the slot opening per notch_widen_angle.
    static func mouthFlare(plan: InterlockedSlicePlan, slitHalf: Double) -> Double {
        let angle = plan.normalizedSlotAngleDegrees
        // The mouth opens by a small kerf-proportional amount (0.278125 × kerf,
        // reached at the 45° default widen angle). Scale with tan(angle) so a 0°
        // angle yields a square mouth and larger angles flare more.
        let base = kerfFromPlan(plan) * 0.278125
        guard angle > 0 else { return 0 }
        return base * min(1.0, tan(angle * .pi / 180))
    }

    private static func kerfFromPlan(_ plan: InterlockedSlicePlan) -> Double {
        // The kerf-compensation amount: the slot offset, or, when a notch
        // width replaces thickness + offset, the room that notch leaves
        // round the stock (so the offset, unused then, changes nothing).
        // When zero, fall back to the default 0.2 mm kerf.
        let clearance = plan.notchWidthOverride == nil
            ? plan.slotClearance
            : plan.slotWidth - plan.materialThickness
        return clearance > 0 ? clearance : 0.2
    }

    // MARK: - Axis helpers

    private static func extent(_ bounds: Bounds3D, axis: SliceAxis) -> Double {
        switch axis {
        case .x: return bounds.max.x - bounds.min.x
        case .y: return bounds.max.y - bounds.min.y
        case .z: return bounds.max.z - bounds.min.z
        }
    }

    private static func coordinate(_ point: Vec3, axis: SliceAxis) -> Double {
        switch axis {
        case .x: return point.x
        case .y: return point.y
        case .z: return point.z
        }
    }

    /// In-plane projection axes for a slice along `axis`, matching
    /// StackedSliceContourer.project (page x, page y).
    private static func projectionAxes(for axis: SliceAxis) -> [SliceAxis] {
        switch axis {
        case .x: return [.y, .z]
        case .y: return [.x, .z]
        case .z: return [.x, .y]
        }
    }
}
