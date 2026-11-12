import Foundation

/// The half-lap joints that hold a Curve Slices model together.
///
/// Every first-axis rib meets every curve rib along the line their two planes
/// share. Wherever both ribs' stock would occupy the same space around that
/// line (the beam where their two thicknesses overlap), each gets a slot
/// there: the first-axis rib loses one part of the shared span and the curve
/// rib loses the rest. Pushed together along the line, each rib slides into
/// the other's slot until the two slot bottoms meet. They meet in the middle
/// of the span, unless a slot from there would run into a hole of its own
/// part; then the meeting point moves along the span just far enough that
/// each slot opens through one edge of its rib, when that is possible. Two
/// stretches of a line whose slots would run into each other (a crossing
/// beside a hollow's inside wall) become one joint.
///
/// The line is vertical when the first axis is X or Y: the first-axis rib's
/// slot opens at the top and the curve rib drops in from above. With first
/// axis Z the line is horizontal and runs along the curve rib: the first-axis
/// rib's slot opens toward one side of the curve rib (`RibLayout.slotSide`)
/// and the curve rib slides in from that side.
///
/// Ribs that cross at a slant need wider slots: the other rib's stock meets
/// this rib's face at an angle and drifts sideways on its way through this
/// rib's thickness. A slot is `(w + t·|cos a|) / sin a` wide, for slot width
/// `w`, stock thickness `t` and angle `a` between the ribs; at a right angle
/// that is the slot width itself.
///
/// Curve ribs stand square to the spline, so where it bends they fan in and,
/// far enough from the spline, run into each other or crowd their slots. No
/// slot can join two ribs a few degrees apart, so each curve rib stops short
/// of where that would happen (its reach, `ribLayout`); the part beyond is
/// cut away like a slot.
enum CurveJointPlanner {
    struct Joint: Equatable {
        var primaryLayer: Int
        var curveLayer: Int
        /// The span both ribs share on their crossing line, in model
        /// coordinates. The first-axis rib keeps the part from `start` to
        /// `meet` and the curve rib the part from `meet` to `end`.
        var start: Vec3
        var end: Vec3
        /// Where the two slot bottoms meet.
        var meet: Vec3
        /// Slot width in both ribs.
        var width: Double
        /// In each rib's section, the middle of every stretch of material it
        /// keeps on the crossing line at this joint: a piece of the rib
        /// holding one takes part in the joint.
        var primaryPoints: [Vec2] = []
        var curvePoints: [Vec2] = []
    }

    struct Slots: Equatable {
        var joints: [Joint]
        /// Closed slot rectangles per first-axis layer, in that layer's
        /// section coordinates.
        var primary: [[SlicePath2D]]
        /// Closed rectangles cut out of each curve layer, in that rib's
        /// section coordinates: its slots, and the part of the rib beyond its
        /// reach.
        var curve: [[SlicePath2D]]
        /// How far each curve rib runs along its section (`u`, distance from
        /// the spline along the plane; `RibLayout.reach`); unbounded on a side
        /// where it meets nothing it must stop for.
        var curveReach: [Span] = []
        /// Per first-axis layer, a point in the middle of the material the
        /// rib keeps at each of its joints (section coordinates): a piece the
        /// slots cut off that holds one of these took part of a joint with it.
        var primaryKept: [[Vec2]] = []
        /// The same for each curve layer.
        var curveKept: [[Vec2]] = []
        /// Each first-axis layer's pieces as every output cuts them
        /// (`assemble`).
        var primaryPieces: [[Piece]] = []
        /// The same for each curve layer.
        var curvePieces: [[Piece]] = []
        /// The layer of every piece left out because it keeps no joint's
        /// material (`assemble`), per family.
        var primaryLeftOut: [Int] = []
        var curveLeftOut: [Int] = []

        /// Each first-axis layer's pieces as closed outlines and holes, for
        /// the outputs that draw or extrude whole sections (STL / OBJ, the 3D
        /// view, the row-layout exports).
        var primaryPaths: [[SlicePath2D]] {
            primaryPieces.map { $0.flatMap(\.paths) }
        }

        /// The same for each curve layer.
        var curvePaths: [[SlicePath2D]] {
            curvePieces.map { $0.flatMap(\.paths) }
        }

        /// What the app and the CLI say about how the parts hold together:
        /// pieces left out, and parts joined only among themselves (shown
        /// blue on the cut sheet). `axisLetter` names the first-axis ribs.
        func assemblyNotes(axisLetter: String) -> [String] {
            var notes: [String] = []
            // A rib left out whole is named; otherwise its pieces are counted.
            var named: [String] = []
            for (prefix, leftOut, kept) in [(axisLetter, primaryLeftOut, primaryPieces), ("C", curveLeftOut, curvePieces)] {
                for layer in Set(leftOut).sorted() {
                    let count = leftOut.filter { $0 == layer }.count
                    let whole = !kept.indices.contains(layer) || kept[layer].isEmpty
                    let rib = "\(prefix)-\(layer + 1)"
                    named.append(whole ? rib : (count == 1 ? "a piece of \(rib)" : "\(count) pieces of \(rib)"))
                }
            }
            if !named.isEmpty {
                let one = named.count == 1 && !named[0].first!.isNumber
                let joined = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
                let list = joined.prefix(1).uppercased() + joined.dropFirst()
                notes.append(one
                    ? "\(list) crosses no slice of the other family and is left out: nothing would hold it in place."
                    : "\(list) cross no slice of the other family and are left out: nothing would hold them in place.")
            }
            let detached = Self.labels(primaryPieces, prefix: axisLetter).filter(\.1).map(\.0)
                + Self.labels(curvePieces, prefix: "C").filter(\.1).map(\.0)
            if !detached.isEmpty {
                notes.append("\(detached.count) parts are joined to each other but not to the rest of the model "
                    + "(\(Self.listed(detached))) and shown blue on the cut sheet: glue them in place, "
                    + "or try another 1st axis, fewer slices or thinner stock.")
            }
            let thin = thinLabels(axisLetter: axisLetter)
            if !thin.isEmpty {
                let (parts, verb) = thin.count == 1 ? ("Part \(thin[0]) is", "it") : ("Parts \(Self.listed(thin)) are", "them")
                notes.append("\(parts) narrower than the stock in places, where a slot comes close to an edge or a hole "
                    + "or the model is that thin: handle \(verb) with care, or use thinner stock.")
            }
            return notes
        }

        /// The labels of the parts narrower than the stock somewhere
        /// (`Piece.thin`).
        func thinLabels(axisLetter: String) -> [String] {
            func thin(_ layers: [[Piece]], _ prefix: String) -> [String] {
                layers.enumerated().flatMap { layer, pieces in
                    pieces.enumerated().compactMap { index, piece in
                        piece.thin ? pieceLabel(prefix: prefix, layer: layer, piece: index, of: pieces.count) : nil
                    }
                }
            }
            return thin(primaryPieces, axisLetter) + thin(curvePieces, "C")
        }

        /// The cut-sheet label of every piece (`pieceLabel`) and whether it
        /// is detached.
        static func labels(_ layers: [[Piece]], prefix: String) -> [(String, Bool)] {
            layers.enumerated().flatMap { layer, pieces in
                pieces.enumerated().map { index, piece in
                    (pieceLabel(prefix: prefix, layer: layer, piece: index, of: pieces.count), piece.detached)
                }
            }
        }

        private static func listed(_ labels: [String]) -> String {
            labels.prefix(6).joined(separator: ", ") + (labels.count > 6 ? ", …" : "")
        }
    }

    /// One piece of a rib as every output cuts it: a piece of its section
    /// with the rib's slots cut out (`CutSheetLayoutBuilder.slottedPieces`).
    struct Piece: Equatable {
        /// The outline, then the holes, in the rib's section coordinates.
        var loops: [[Vec2]]
        var openPaths: [[Vec2]] = []
        /// The slots cut it off from material one of its joints keeps, or
        /// took it away whole (then it is kept uncut).
        var severed = false
        /// The joints (indices into `Slots.joints`) whose material it keeps.
        var joints: [Int] = []
        /// Joined to other pieces, but not to the rest of the model.
        var detached = false
        /// Somewhere narrower than the stock (`slotWeb`): a slot comes that
        /// close to an edge or a hole, or the model is that thin there.
        var thin = false

        var paths: [SlicePath2D] {
            loops.compactMap { loop -> SlicePath2D? in
                guard let first = loop.first else { return nil }
                return SlicePath2D(points: loop + [first], closed: true)
            } + openPaths.map { SlicePath2D(points: $0, closed: false) }
        }

        /// Whether the piece's material (outline less holes) holds `point`.
        func holds(_ point: Vec2) -> Bool {
            guard let outline = loops.first, CutSheetLayoutBuilder.contains(outline, point: point) else { return false }
            return !loops.dropFirst().contains { CutSheetLayoutBuilder.contains($0, point: point) }
        }
    }

    /// The cut-sheet label of piece `piece` of the `count` pieces of rib
    /// `layer` (0-based): `Z-3`, or `Z-3-2` when the rib has several.
    static func pieceLabel(prefix: String, layer: Int, piece: Int, of count: Int) -> String {
        count > 1 ? "\(prefix)-\(layer + 1)-\(piece + 1)" : "\(prefix)-\(layer + 1)"
    }

    /// Shared spans shorter than this (mm) are grazing contact, not a joint.
    static let minimumSpan = 0.1
    /// Ribs closer to parallel than this (the sine of the angle between them)
    /// get no joint: their crossing line runs far outside the model, and a slot
    /// for it would be many times the stock thickness wide.
    static let minimumCrossingSine = 0.1
    /// How far (mm) a slot runs past the part's edge at its mouth, so the
    /// opening is clean across the slot's whole width.
    static let mouthOvershoot = 1.0
    /// Thinnest web of material (mm) left between two slots in one part.
    /// Where ribs converge their slots crowd together; anything thinner
    /// than this would burn away or snap, so it is cut away with the slots.
    static let minimumWeb = 1.0
    /// Thinnest web (mm) left between two curve ribs' slots in a first-axis
    /// rib, and between their slots where the ribs leave the spline: the
    /// stock thickness, and at least `minimumWeb`. Where curve ribs crowd
    /// closer than this they stop short of that first-axis rib, and the
    /// planner cuts no more ribs than stand this far apart.
    static func slotWeb(thickness: Double) -> Double {
        max(minimumWeb, thickness)
    }
    /// Gap (mm) left between a curve rib cut short and the stock of the curve
    /// rib it would otherwise run into, or the beam of a crossing it stops
    /// short of.
    static let ribClearance = 0.5
    /// Lines across the slot width along which the part's edge is found.
    private static let widthSamples = 9
    /// Lines per side of the beam's cross-section along which the two ribs'
    /// shared material is found.
    private static let beamSamples = 5

    static func slots(plan: CurveSlicePlan, primary: StackedSliceContours, curve: CurveSliceContours) -> Slots {
        let primaryLoops = primary.layers.map { closedLoops($0.paths) }
        let thickness = plan.primary.materialThickness
        let layout = ribLayout(plan: plan)
        let reach = curve.layers.indices.map { layout.reach.indices.contains($0) ? layout.reach[$0] : Span(lo: -.infinity, hi: .infinity) }
        let cutAway = zip(curve.layers, reach).map { layer, span in
            beyondReach(closedLoops(layer.paths), reach: span)
        }
        // Every piece the stops leave within reach takes part in the joints.
        let curveLoops = zip(curve.layers, cutAway).map { layer, cut -> [[Vec2]] in
            let cuts = closedLoops(cut)
            guard !cuts.isEmpty else { return closedLoops(layer.paths) }
            return CutSheetLayoutBuilder.islandize(paths: layer.paths).flatMap { island in
                CutSheetLayoutBuilder.slottedPieces(cuts, from: island, keepingEveryPiece: true).flatMap(\.loops)
            }
        }
        var joints: [Joint] = []
        var primarySlots = Array(repeating: [SlicePath2D](), count: primary.layers.count)
        var curveSlots = cutAway
        var primaryKept = Array(repeating: [Vec2](), count: primary.layers.count)
        var curveKept = Array(repeating: [Vec2](), count: curve.layers.count)

        for (primaryIndex, primaryLayer) in primary.layers.enumerated() {
            for (curveIndex, curveLayer) in curve.layers.enumerated() {
                guard let line = crossing(
                    axis: primary.axis,
                    position: primaryLayer.position,
                    center: curveLayer.center,
                    inPlane: curveLayer.normal
                ) else {
                    continue
                }
                let cosine = (max(0, 1 - line.sine * line.sine)).squareRoot()
                let width = (plan.slotWidth + thickness * cosine) / line.sine
                let beam = beamOffsets(
                    line: line,
                    primaryFrame: PartPlaneFrame(axis: primary.axis, position: primaryLayer.position),
                    curveFrame: PartPlaneFrame(center: curveLayer.center, inPlaneDirection: curveLayer.normal),
                    thickness: thickness
                )
                let sharedSpans = merged(beam.flatMap { offset in
                    overlaps(
                        materialSpans(primaryLoops[primaryIndex], along: line.primary, offset: offset.primary),
                        materialSpans(curveLoops[curveIndex], along: line.curve, offset: offset.curve)
                    )
                })
                // With first axis Z the line runs along the curve rib, and the
                // first-axis rib is slotted toward the side the layout picked
                // for it (`RibLayout.slotSide`): away from where the curve rib
                // is cut short, so its slots open where it reaches.
                let side = primary.axis == .z && layout.slotSide.indices.contains(curveIndex) ? layout.slotSide[curveIndex] : 1
                let backward = side < 0
                let start = primary.axis == .z && layout.slotStart.indices.contains(curveIndex)
                    ? layout.slotStart[curveIndex] : -.infinity
                let primaryRun = RunSide(loops: primaryLoops[primaryIndex], line: line.primary)
                let curveRun = RunSide(loops: curveLoops[curveIndex], line: line.curve)
                let centre = overlaps(
                    materialSpans(primaryLoops[primaryIndex], along: line.primary),
                    materialSpans(curveLoops[curveIndex], along: line.curve)
                )
                // One joint per stretch the two ribs share, each split where
                // the slot bottoms meet. A slot that would run on into the
                // next stretch (no gap between them on some line across it)
                // makes the two one joint.
                var spans = sharedSpans.filter { $0.hi - $0.lo >= minimumSpan }
                var planned: [(span: Span, middle: Double, primaryMouth: Double, curveMouth: Double)] = []
                while true {
                    planned = spans.map { shared in
                        let inside = centre.filter { $0.hi > shared.lo && $0.lo < shared.hi }
                        let centreSpan = Span(
                            lo: max(shared.lo, inside.map(\.lo).min() ?? shared.lo),
                            hi: min(shared.hi, inside.map(\.hi).max() ?? shared.hi)
                        )
                        let middle = meetingPoint(
                            of: shared,
                            centre: centreSpan,
                            forward: backward ? curveRun : primaryRun,
                            backward: backward ? primaryRun : curveRun,
                            width: width,
                            web: slotWeb(thickness: thickness),
                            firstAxisForward: !backward,
                            lowest: backward ? -.infinity : start,
                            highest: backward ? -start : .infinity
                        )
                        let (primaryEnd, curveEnd) = backward ? (shared.hi, shared.lo) : (shared.lo, shared.hi)
                        let primaryMouth = mouth(
                            loops: primaryLoops[primaryIndex], line: line.primary, width: width,
                            middle: middle, edge: curveEnd, forward: !backward
                        )
                        let curveMouth = mouth(
                            loops: curveLoops[curveIndex], line: line.curve, width: width,
                            middle: middle, edge: primaryEnd, forward: backward
                        )
                        return (shared, middle, primaryMouth, curveMouth)
                    }
                    let runsOn = planned.indices.dropLast().first { k in
                        let (upward, downward) = backward
                            ? (planned[k].curveMouth, planned[k + 1].primaryMouth)
                            : (planned[k].primaryMouth, planned[k + 1].curveMouth)
                        return upward > planned[k + 1].span.lo || downward < planned[k].span.hi
                    }
                    guard let k = runsOn else { break }
                    spans[k] = Span(lo: spans[k].lo, hi: spans[k + 1].hi)
                    spans.remove(at: k + 1)
                }
                for joint in planned {
                    let shared = joint.span
                    let middle = joint.middle
                    // The first-axis rib keeps the span from `start` to the
                    // meeting point and the curve rib the rest.
                    let (primaryEnd, curveEnd) = backward ? (shared.hi, shared.lo) : (shared.lo, shared.hi)
                    joints.append(Joint(
                        primaryLayer: primaryIndex,
                        curveLayer: curveIndex,
                        start: line.point(at: primaryEnd),
                        end: line.point(at: curveEnd),
                        meet: line.point(at: middle),
                        width: width,
                        primaryPoints: keptStretches(primaryLoops[primaryIndex], along: line.primary, from: primaryEnd, to: middle),
                        curvePoints: keptStretches(curveLoops[curveIndex], along: line.curve, from: middle, to: curveEnd)
                    ))
                    // The first-axis rib is slotted from the meeting point out
                    // through its edge on the curve rib's side; the curve rib
                    // from its edge on the other side to the meeting point.
                    primarySlots[primaryIndex].append(rectangle(
                        line.primary, from: min(middle, joint.primaryMouth), to: max(middle, joint.primaryMouth), width: width
                    ))
                    curveSlots[curveIndex].append(rectangle(
                        line.curve, from: min(middle, joint.curveMouth), to: max(middle, joint.curveMouth), width: width
                    ))
                    primaryKept[primaryIndex].append(line.primary.point(at: (primaryEnd + middle) / 2))
                    curveKept[curveIndex].append(line.curve.point(at: (middle + curveEnd) / 2))
                }
            }
        }
        var slots = Slots(
            joints: joints,
            primary: primarySlots,
            curve: curveSlots,
            curveReach: reach,
            primaryKept: primaryKept,
            curveKept: curveKept
        )
        assemble(&slots, primary: primary.layers.map(\.paths), curve: curve.layers.map(\.paths), web: slotWeb(thickness: thickness))
        return slots
    }

    /// Whether the material of `loops` (an outline, then its holes) falls
    /// into more pieces when shrunk by half of `web` and grown back: it is
    /// narrower than `web` somewhere between two parts of it.
    static func narrowerThan(_ web: Double, _ loops: [[Vec2]]) -> Bool {
        guard let outline = loops.first, outline.count >= 3 else { return false }
        let rings = [CutSheetLayoutBuilder.signedArea(outline) >= 0 ? outline : Array(outline.reversed())]
            + loops.dropFirst().map { CutSheetLayoutBuilder.signedArea($0) <= 0 ? $0 : Array($0.reversed()) }
        guard let opened = PlanarBoolean.joining(rings, closingBy: 0, openingBy: web / 2 - 0.05) else { return false }
        return opened.filter { CutSheetLayoutBuilder.signedArea($0) > 0.5 }.count > 1
    }

    /// The middle of every stretch of the section's material on `line`
    /// between `a` and `b`; with none, the middle of the two.
    private static func keptStretches(_ loops: [[Vec2]], along line: SectionLine, from a: Double, to b: Double) -> [Vec2] {
        let lo = min(a, b)
        let hi = max(a, b)
        let points = materialSpans(loops, along: line).compactMap { span -> Vec2? in
            let start = max(lo, span.lo)
            let end = min(hi, span.hi)
            return end - start > 1.0e-6 ? line.point(at: (start + end) / 2) : nil
        }
        return points.isEmpty ? [line.point(at: (a + b) / 2)] : points
    }

    /// Cuts every rib into its pieces (`Slots.primaryPieces`,
    /// `Slots.curvePieces`) and works out how the joints hold them together.
    /// Each piece of a section is cut by its rib's slots
    /// (`CutSheetLayoutBuilder.slottedPieces`: the largest piece, and every
    /// piece that keeps a joint's material). A piece that keeps no joint's
    /// material touches no rib of the other family, so nothing would hold it
    /// in place: it is left out (`Slots.primaryLeftOut`,
    /// `Slots.curveLeftOut`). The joints join the rest into groups; the
    /// largest (most pieces, then most material) is the model, and every
    /// piece of another group is `detached`: it holds together with its own
    /// group, not with the rest. With no joint at all, every piece is kept.
    /// A piece that falls apart when shrunk by half of `web` and grown back
    /// is `thin` somewhere.
    static func assemble(_ slots: inout Slots, primary: [[SlicePath2D]], curve: [[SlicePath2D]], web: Double) {
        func cut(_ layers: [[SlicePath2D]], slots cuts: [[SlicePath2D]], kept: [[Vec2]], points: [[(Vec2, Int)]]) -> [[Piece]] {
            layers.enumerated().map { index, paths in
                let layerCuts = cuts.indices.contains(index) ? closedLoops(cuts[index]) : []
                let layerKept = kept.indices.contains(index) ? kept[index] : []
                let layerPoints = points.indices.contains(index) ? points[index] : []
                return CutSheetLayoutBuilder.islandize(paths: paths).flatMap { island -> [Piece] in
                    let cutPieces = layerCuts.isEmpty
                        ? [island]
                        : CutSheetLayoutBuilder.slottedPieces(layerCuts, from: island, keeping: layerKept)
                    return cutPieces.filter { !$0.loops.isEmpty || !$0.openPaths.isEmpty }.map { cutPiece in
                        var piece = Piece(loops: cutPiece.loops, openPaths: cutPiece.openPaths, severed: cutPiece.isError)
                        piece.joints = Array(Set(layerPoints.filter { piece.holds($0.0) }.map(\.1))).sorted()
                        piece.thin = narrowerThan(web, piece.loops)
                        return piece
                    }
                }
            }
        }
        var primaryPoints = Array(repeating: [(Vec2, Int)](), count: primary.count)
        var curvePoints = Array(repeating: [(Vec2, Int)](), count: curve.count)
        for (index, joint) in slots.joints.enumerated() {
            if primaryPoints.indices.contains(joint.primaryLayer) {
                primaryPoints[joint.primaryLayer] += joint.primaryPoints.map { ($0, index) }
            }
            if curvePoints.indices.contains(joint.curveLayer) {
                curvePoints[joint.curveLayer] += joint.curvePoints.map { ($0, index) }
            }
        }
        var primaryPieces = cut(primary, slots: slots.primary, kept: slots.primaryKept, points: primaryPoints)
        var curvePieces = cut(curve, slots: slots.curve, kept: slots.curveKept, points: curvePoints)
        guard !slots.joints.isEmpty else {
            slots.primaryPieces = primaryPieces
            slots.curvePieces = curvePieces
            return
        }

        // Every piece, both families, numbered; and which hold each joint.
        var ids: [(primary: Bool, layer: Int, piece: Int)] = []
        var primaryHolders = [Int: [Int]]()
        var curveHolders = [Int: [Int]]()
        for (primaryFamily, layers) in [(true, primaryPieces), (false, curvePieces)] {
            for (layer, pieces) in layers.enumerated() {
                for (index, piece) in pieces.enumerated() {
                    for joint in piece.joints {
                        if primaryFamily {
                            primaryHolders[joint, default: []].append(ids.count)
                        } else {
                            curveHolders[joint, default: []].append(ids.count)
                        }
                    }
                    ids.append((primaryFamily, layer, index))
                }
            }
        }
        var parent = Array(ids.indices)
        func root(_ id: Int) -> Int {
            var id = id
            while parent[id] != id {
                parent[id] = parent[parent[id]]
                id = parent[id]
            }
            return id
        }
        var linked = Array(repeating: false, count: ids.count)
        for joint in slots.joints.indices {
            guard let a = primaryHolders[joint], let b = curveHolders[joint] else { continue }
            for id in a + b {
                linked[id] = true
                parent[root(id)] = root(b[0])
            }
        }
        func piece(_ id: Int) -> Piece {
            let entry = ids[id]
            return entry.primary ? primaryPieces[entry.layer][entry.piece] : curvePieces[entry.layer][entry.piece]
        }
        var groups: [Int: (count: Int, area: Double)] = [:]
        for id in ids.indices where linked[id] {
            let area = piece(id).loops.first.map { abs(CutSheetLayoutBuilder.signedArea($0)) } ?? 0
            let group = groups[root(id), default: (0, 0)]
            groups[root(id)] = (group.count + 1, group.area + area)
        }
        // Most pieces, then most material, then the group of the first piece.
        let main = groups.max { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            if lhs.value.area != rhs.value.area { return lhs.value.area < rhs.value.area }
            return lhs.key > rhs.key
        }?.key

        for id in ids.indices.reversed() {
            let entry = ids[id]
            if !linked[id] {
                if entry.primary {
                    primaryPieces[entry.layer].remove(at: entry.piece)
                    slots.primaryLeftOut.insert(entry.layer, at: 0)
                } else {
                    curvePieces[entry.layer].remove(at: entry.piece)
                    slots.curveLeftOut.insert(entry.layer, at: 0)
                }
            } else if root(id) != main {
                if entry.primary {
                    primaryPieces[entry.layer][entry.piece].detached = true
                } else {
                    curvePieces[entry.layer][entry.piece].detached = true
                }
            }
        }
        slots.primaryPieces = primaryPieces
        slots.curvePieces = curvePieces
    }

    // MARK: - Where the curve ribs stand and stop

    /// Where a curve rib stands on the spline: its sample point, the spline's
    /// tangent there (the normal of the rib's plane) and the rib's in-plane
    /// direction across the spline.
    struct RibStation: Equatable {
        var center: Vec3
        var direction: Vec2
        var normal: Vec2
    }

    /// Where every curve rib stops, and, with first axis Z, which way the
    /// first-axis ribs are slotted for it. Worked out from where the ribs
    /// stand, the first-axis rib positions and the model's bounding box, so
    /// the planner can check a rib count before any section is cut.
    struct RibLayout: Equatable {
        /// How far each curve rib runs along its section (`u`, distance from
        /// the spline along the plane); unbounded on a side where it meets
        /// nothing it must stop for.
        var reach: [Span]
        /// First axis Z: the side (+1 along `n`, -1 against it) toward which
        /// the first-axis ribs are slotted for each curve rib (the curve rib
        /// slides in from that side). +1 for other axes.
        var slotSide: [Double]
        /// First axis Z: how near the spline (measured toward `slotSide`)
        /// a first-axis rib's slot for each curve rib may start, so the slots
        /// keep a stock-thick web from their neighbours'.
        var slotStart: [Double]
        /// False when some rib cannot be kept clear of the ribs around it:
        /// ribs closer together than their stock at the spline, a rib that
        /// meets a first-axis rib it cannot join too near the spline to stop
        /// short of it, a rib cut short on both sides with first axis Z, or
        /// slots that close in on each other. The planner cuts fewer ribs
        /// until this holds.
        var standsClear: Bool
    }

    /// Whether two curve ribs stand far enough apart where they leave the
    /// spline: for at least one of them, at its own sample point, the space
    /// between its stock and the other's is `ribClearance` or more (so it can
    /// stop short of the other where they close in), and the web between
    /// their slots in a first-axis rib crossing both there is at least
    /// `slotWeb`.
    static func ribsStandApart(_ a: RibStation, _ b: RibStation, thickness: Double, slotWidth: Double) -> Bool {
        let web = slotWeb(thickness: thickness)
        func clears(_ rib: RibStation, of other: RibStation) -> Bool {
            let along = (other.center.x - rib.center.x) * other.direction.x
                + (other.center.y - rib.center.y) * other.direction.y
            let cosine = abs(rib.direction.x * other.direction.x + rib.direction.y * other.direction.y)
            let gap = abs(along) - thickness / 2 * (1 + cosine)
            let slotGap = abs(along) - slotWidth / 2 * (1 + cosine)
            return gap >= ribClearance - 1.0e-9 && slotGap >= web - 1.0e-9
        }
        return clears(a, of: b) || clears(b, of: a)
    }

    static func ribLayout(plan: CurveSlicePlan) -> RibLayout {
        ribLayout(
            stations: plan.centers.indices.map {
                RibStation(center: plan.centers[$0], direction: plan.directions[$0], normal: plan.normals[$0])
            },
            axis: plan.primary.axis,
            positions: plan.primary.positions,
            thickness: plan.primary.materialThickness,
            slotWidth: plan.slotWidth,
            bounds: plan.bounds
        )
    }

    /// Where each curve rib stops (`RibLayout`).
    ///
    /// Curve ribs stand square to the spline, so where it bends they close in
    /// on each other. For every two ribs, the stretch of each where its stock
    /// would come within `ribClearance` of the other's, inside the model's
    /// bounding box, is found from where they stand. Both ribs stop short of
    /// it, on that side; a rib that meets the other's stock at its own
    /// sample point cannot, so the other stops alone. With first axis Z a rib
    /// cut short on both sides could not be slotted without leaving part of a
    /// slot empty, so where it can, one of its neighbours stops alone instead.
    ///
    /// With first axis X or Y the crossings with the first-axis ribs run up
    /// the curve rib. A rib must not end inside the beam of such a crossing
    /// without reaching across its line, so it stops short of that beam
    /// instead; nor may it run on where its slot in a first-axis rib would come
    /// within `slotWeb` of the next curve rib's slot (or of the line of a rib
    /// that stops short of that first-axis rib): then both stop short of that
    /// first-axis rib. A rib nearly parallel to a first-axis rib (closer than
    /// `minimumCrossingSine`) is not joined to it and stops short of its stock.
    static func ribLayout(
        stations: [RibStation],
        axis: SliceAxis,
        positions: [Double],
        thickness: Double,
        slotWidth: Double,
        bounds: Bounds3D
    ) -> RibLayout {
        let count = stations.count
        let half = thickness / 2
        let web = slotWeb(thickness: thickness)
        var clear = true
        let footprints = stations.map { footprint(of: $0, in: bounds) }

        // Where each rib's stock would meet each other rib's, in its own u.
        var meets = Array(repeating: [Int: Span](), count: count)
        for a in 0..<count {
            for b in 0..<count where b != a {
                if let meeting = stockMeeting(stations[a], stations[b], footprints[a], footprints[b], thickness: thickness) {
                    meets[a][b] = meeting
                }
            }
        }
        func stuck(_ span: Span?) -> Bool {
            span.map { $0.lo <= 0 && $0.hi >= 0 } ?? false
        }
        // Who stops for whom: stopsFor[a] holds the ribs `a` stops short of.
        var stopsFor = Array(repeating: Set<Int>(), count: count)
        for a in 0..<count {
            for b in (a + 1)..<max(a + 1, count) {
                let toB = meets[a][b]
                let toA = meets[b][a]
                guard toB != nil || toA != nil else { continue }
                let aCanStop = toB != nil && !stuck(toB)
                let bCanStop = toA != nil && !stuck(toA)
                if stuck(toB) || stuck(toA) {
                    if stuck(toB) && bCanStop {
                        stopsFor[b].insert(a)
                    } else if stuck(toA) && aCanStop {
                        stopsFor[a].insert(b)
                    } else {
                        clear = false
                    }
                    continue
                }
                if aCanStop { stopsFor[a].insert(b) }
                if bCanStop { stopsFor[b].insert(a) }
            }
        }
        func cutSides(_ a: Int) -> (plus: [Int], minus: [Int]) {
            var plus: [Int] = []
            var minus: [Int] = []
            for b in stopsFor[a].sorted() {
                guard let meeting = meets[a][b] else { continue }
                if meeting.lo > 0 { plus.append(b) } else { minus.append(b) }
            }
            return (plus, minus)
        }
        if axis == .z {
            // A rib cut short on both sides: free the side whose partners can
            // all stop alone without being cut short on both sides themselves.
            var changed = true
            var rounds = 0
            while changed && rounds < 4 * count {
                changed = false
                rounds += 1
                for a in 0..<count {
                    let sides = cutSides(a)
                    guard !sides.plus.isEmpty, !sides.minus.isEmpty else { continue }
                    let choices = sides.plus.count <= sides.minus.count
                        ? [sides.plus, sides.minus]
                        : [sides.minus, sides.plus]
                    for partners in choices {
                        let absorbed = partners.allSatisfy { b in
                            guard let meeting = meets[b][a], !stuck(meeting) else { return false }
                            let other = cutSides(b)
                            return meeting.lo > 0 ? other.minus.isEmpty : other.plus.isEmpty
                        }
                        guard absorbed else { continue }
                        for b in partners {
                            stopsFor[a].remove(b)
                            stopsFor[b].insert(a)
                        }
                        changed = true
                        break
                    }
                }
            }
        }

        var reach = Array(repeating: Span(lo: -.infinity, hi: .infinity), count: count)
        for a in 0..<count {
            for b in stopsFor[a] {
                guard let meeting = meets[a][b] else { continue }
                if meeting.lo > 0 {
                    reach[a].hi = min(reach[a].hi, meeting.lo)
                } else {
                    reach[a].lo = max(reach[a].lo, meeting.hi)
                }
            }
        }

        var slotSide = Array(repeating: 1.0, count: count)
        var slotStart = Array(repeating: -Double.infinity, count: count)
        if axis == .z {
            for a in 0..<count {
                guard let footprint = footprints[a] else { continue }
                let cutPlus = reach[a].hi < footprint.hi
                let cutMinus = reach[a].lo > footprint.lo
                if cutPlus && cutMinus {
                    clear = false
                }
                slotSide[a] = cutPlus && !cutMinus ? -1 : (cutMinus && !cutPlus ? 1 : divergingSide(a, stations: stations, footprint: footprint))
            }
            // A rib's slots keep a stock-thick web from every other rib's
            // line, slotted or not: each starts where its line has drawn far
            // enough from the others', and none may run on to where another
            // rib's line closes in on it.
            for a in 0..<count {
                guard let footprintA = footprints[a] else { continue }
                let side = slotSide[a]
                let end = side > 0 ? footprintA.hi : -footprintA.lo
                for b in 0..<count where b != a {
                    guard let footprintB = footprints[b] else { continue }
                    let rib = stations[a]
                    let other = stations[b]
                    let dx = rib.center.x - other.center.x
                    let dy = rib.center.y - other.center.y
                    let offset = dx * other.direction.x + dy * other.direction.y
                    let slope = side * (rib.normal.x * other.direction.x + rib.normal.y * other.direction.y)
                    let cosine = abs(rib.direction.x * other.direction.x + rib.direction.y * other.direction.y)
                    let reachOut = slotWidth / 2 * (1 + cosine) + web
                    guard var close = band(offset: offset, slope: slope, halfWidth: reachOut) else { continue }
                    // Only where the other rib's line lies inside the model.
                    let acrossOffset = dx * other.normal.x + dy * other.normal.y
                    let acrossSlope = side * (rib.normal.x * other.normal.x + rib.normal.y * other.normal.y)
                    guard let inside = range(offset: acrossOffset, slope: acrossSlope, within: footprintB) else { continue }
                    close = Span(lo: max(close.lo, inside.lo), hi: min(close.hi, inside.hi))
                    guard close.hi > close.lo, close.lo < end else { continue }
                    if close.lo <= slotStart[a] || close.lo <= 0 {
                        // Behind or around the spline: start the slot past it.
                        slotStart[a] = max(slotStart[a], close.hi)
                    } else {
                        // Ahead, where the two close in on each other.
                        clear = false
                    }
                }
            }
            // Behind where its slots may start the rib could only be joined
            // with crowded slots, so it stops there; at the spline itself the
            // ribs stand too close.
            for a in 0..<count where slotStart[a].isFinite {
                if slotStart[a] >= 0 {
                    clear = false
                } else if slotSide[a] > 0 {
                    reach[a].lo = max(reach[a].lo, slotStart[a])
                } else {
                    reach[a].hi = min(reach[a].hi, -slotStart[a])
                }
            }
        } else {
            // First axis X or Y: the crossings with the first-axis ribs.
            struct Crossing {
                var layer: Int
                var at: Double
                var beam: Double
                var along: Double
                var width: Double
            }
            var crossings = Array(repeating: [Crossing](), count: count)
            for (a, rib) in stations.enumerated() {
                guard let footprint = footprints[a] else { continue }
                let toward = axis == .y ? rib.normal.y : rib.normal.x
                let from = axis == .y ? rib.center.y : rib.center.x
                let sine = abs(toward)
                let cosine = (max(0, 1 - sine * sine)).squareRoot()
                for (layer, position) in positions.enumerated() {
                    if sine >= minimumCrossingSine {
                        let at = (position - from) / toward
                        guard at > footprint.lo, at < footprint.hi else { continue }
                        let along = axis == .y ? rib.center.x + at * rib.normal.x : rib.center.y + at * rib.normal.y
                        crossings[a].append(Crossing(
                            layer: layer,
                            at: at,
                            beam: half * (1 + cosine) / sine,
                            along: along,
                            width: (slotWidth + thickness * cosine) / sine
                        ))
                    } else if var stock = band(offset: from - position, slope: toward, halfWidth: half * (1 + cosine) + ribClearance) {
                        // Too near parallel to join: keep clear of its stock.
                        stock = Span(lo: max(stock.lo, footprint.lo), hi: min(stock.hi, footprint.hi))
                        guard stock.hi > stock.lo else { continue }
                        if stock.lo <= 0 && stock.hi >= 0 {
                            clear = false
                        } else if stock.lo > 0 {
                            reach[a].hi = min(reach[a].hi, stock.lo)
                        } else {
                            reach[a].lo = max(reach[a].lo, stock.hi)
                        }
                    }
                }
            }
            var changed = true
            var rounds = 0
            while changed && rounds < 8 * max(1, count) {
                changed = false
                rounds += 1
                for a in 0..<count {
                    let beams = crossings[a].map { (at: $0.at, beam: $0.beam) }
                    for sign in [1.0, -1.0] {
                        let end = sign > 0 ? reach[a].hi : reach[a].lo
                        guard end.isFinite else { continue }
                        guard let cleared = clearOfBeams(end: end, crossings: beams, sign: sign) else {
                            clear = false
                            continue
                        }
                        if cleared != end {
                            if sign > 0 { reach[a].hi = cleared } else { reach[a].lo = cleared }
                            changed = true
                        }
                    }
                }
                for layer in positions.indices {
                    // Stop one rib at a time short of this first-axis rib
                    // until no two slots in it crowd each other.
                    while true {
                        var reaching: [(rib: Int, crossing: Crossing)] = []
                        var stopping: [(rib: Int, crossing: Crossing)] = []
                        for a in 0..<count {
                            for crossing in crossings[a] where crossing.layer == layer {
                                let reaches = crossing.at >= 0 ? reach[a].hi > crossing.at : reach[a].lo < crossing.at
                                if reaches {
                                    reaching.append((a, crossing))
                                } else {
                                    stopping.append((a, crossing))
                                }
                            }
                        }
                        reaching.sort { $0.crossing.along < $1.crossing.along }
                        // The ribs that could stop short of this rib's beam,
                        // and where.
                        func stop(_ entry: (rib: Int, crossing: Crossing)) -> Double? {
                            let cut = abs(entry.crossing.at) - entry.crossing.beam - ribClearance
                            return cut > 0 ? cut : nil
                        }
                        var crowded: [(rib: Int, crossing: Crossing)]?
                        for (left, right) in zip(reaching, reaching.dropFirst()) {
                            let gap = right.crossing.along - left.crossing.along
                                - (left.crossing.width + right.crossing.width) / 2
                            if gap < web {
                                crowded = [left, right]
                                break
                            }
                        }
                        if crowded == nil {
                            for slot in reaching {
                                if stopping.contains(where: {
                                    abs($0.crossing.along - slot.crossing.along) < slot.crossing.width / 2 + ribClearance
                                }) {
                                    crowded = [slot]
                                    break
                                }
                            }
                        }
                        guard let pair = crowded else { break }
                        // Stop the one that keeps the most of itself.
                        let choice = pair
                            .compactMap { entry in stop(entry).map { (entry: entry, cut: $0) } }
                            .max { $0.cut < $1.cut }
                        guard let chosen = choice else {
                            clear = false
                            break
                        }
                        let a = chosen.entry.rib
                        if chosen.entry.crossing.at >= 0 {
                            reach[a].hi = min(reach[a].hi, chosen.cut)
                        } else {
                            reach[a].lo = max(reach[a].lo, -chosen.cut)
                        }
                        changed = true
                    }
                }
            }
        }
        return RibLayout(reach: reach, slotSide: slotSide, slotStart: slotStart, standsClear: clear)
    }

    /// The stretch of `u` over which the rib's line runs inside the model's
    /// bounding box (seen from above), or nil when it misses it.
    private static func footprint(of rib: RibStation, in bounds: Bounds3D) -> Span? {
        var lo = -Double.infinity
        var hi = Double.infinity
        let limits = [
            (rib.center.x, rib.normal.x, min(bounds.min.x, bounds.max.x), max(bounds.min.x, bounds.max.x)),
            (rib.center.y, rib.normal.y, min(bounds.min.y, bounds.max.y), max(bounds.min.y, bounds.max.y))
        ]
        for (start, step, low, high) in limits {
            guard let inside = range(offset: start, slope: step, within: Span(lo: low, hi: high)) else { return nil }
            lo = max(lo, inside.lo)
            hi = min(hi, inside.hi)
        }
        return hi > lo ? Span(lo: lo, hi: hi) : nil
    }

    /// The stretch of rib `a` (in its `u`) where its stock, with
    /// `ribClearance` to spare, would meet rib `b`'s, inside both ribs'
    /// footprints; nil when they do not meet there.
    private static func stockMeeting(
        _ a: RibStation,
        _ b: RibStation,
        _ footprintA: Span?,
        _ footprintB: Span?,
        thickness: Double
    ) -> Span? {
        guard let footprintA, let footprintB else { return nil }
        let dx = a.center.x - b.center.x
        let dy = a.center.y - b.center.y
        let cosine = abs(a.direction.x * b.direction.x + a.direction.y * b.direction.y)
        guard let near = band(
            offset: dx * b.direction.x + dy * b.direction.y,
            slope: a.normal.x * b.direction.x + a.normal.y * b.direction.y,
            halfWidth: thickness / 2 * (1 + cosine) + ribClearance
        ), let onB = range(
            offset: dx * b.normal.x + dy * b.normal.y,
            slope: a.normal.x * b.normal.x + a.normal.y * b.normal.y,
            within: footprintB
        ) else {
            return nil
        }
        let lo = max(footprintA.lo, near.lo, onB.lo)
        let hi = min(footprintA.hi, near.hi, onB.hi)
        return hi > lo ? Span(lo: lo, hi: hi) : nil
    }

    /// The side (+1 along `n`, -1 against it) on which rib `index`'s
    /// neighbours along the spline draw away from it.
    private static func divergingSide(_ index: Int, stations: [RibStation], footprint: Span) -> Double {
        let rib = stations[index]
        let length = max(abs(footprint.lo), abs(footprint.hi), 1)
        var plus = Double.infinity
        var minus = Double.infinity
        for other in [index - 1, index + 1] where stations.indices.contains(other) {
            let neighbour = stations[other]
            func distance(_ u: Double) -> Double {
                abs((rib.center.x + u * rib.normal.x - neighbour.center.x) * neighbour.direction.x
                    + (rib.center.y + u * rib.normal.y - neighbour.center.y) * neighbour.direction.y)
            }
            plus = min(plus, distance(length))
            minus = min(minus, distance(-length))
        }
        return minus > plus + 1.0e-9 ? -1 : 1
    }

    /// The values of `u` with `|offset + u * slope| < halfWidth`, or nil.
    private static func band(offset: Double, slope: Double, halfWidth: Double) -> Span? {
        guard abs(slope) > 1.0e-12 else {
            return abs(offset) < halfWidth - 1.0e-9 ? Span(lo: -.infinity, hi: .infinity) : nil
        }
        let a = (-halfWidth - offset) / slope
        let b = (halfWidth - offset) / slope
        return Span(lo: min(a, b), hi: max(a, b))
    }

    /// The values of `u` with `offset + u * slope` inside `span`, or nil.
    private static func range(offset: Double, slope: Double, within span: Span) -> Span? {
        guard abs(slope) > 1.0e-12 else {
            return offset >= span.lo && offset <= span.hi ? Span(lo: -.infinity, hi: .infinity) : nil
        }
        let a = (span.lo - offset) / slope
        let b = (span.hi - offset) / slope
        return Span(lo: min(a, b), hi: max(a, b))
    }

    /// Where a curve rib's end at `end` (its `+n` end for `sign` 1, its `-n`
    /// end for -1) must move so it neither stops inside the beam of a
    /// first-axis crossing it does not reach across, nor short of a crossing
    /// line whose beam it reaches into: back toward the spline to
    /// `ribClearance` short of that beam. Nil when that would take it back
    /// past the spline.
    private static func clearOfBeams(end: Double, crossings: [(at: Double, beam: Double)], sign: Double) -> Double? {
        guard end.isFinite else { return end }
        var cut = end * sign
        // Each crossing's span along the rib that the end must not fall in:
        // from just short of the crossing line to just past its beam, measured
        // outward from the spline.
        let windows = crossings
            .map { (lo: $0.at * sign - $0.beam - ribClearance, hi: $0.at * sign + ribClearance) }
            .sorted { $0.hi > $1.hi }
        for window in windows where cut > window.lo && cut < window.hi {
            cut = window.lo
        }
        return cut > 0 ? cut * sign : nil
    }

    /// The part of a curve rib's section beyond its reach, as rectangles
    /// running past the section's ends.
    static func beyondReach(_ loops: [[Vec2]], reach: Span) -> [SlicePath2D] {
        let points = loops.flatMap { $0 }
        guard let minU = points.map(\.x).min(), let maxU = points.map(\.x).max(),
              let minZ = points.map(\.y).min(), let maxZ = points.map(\.y).max() else {
            return []
        }
        let across = SectionLine(origin: Vec2(x: 0, y: (minZ + maxZ) / 2), direction: Vec2(x: 1, y: 0))
        let height = maxZ - minZ + 2 * mouthOvershoot
        var cut: [SlicePath2D] = []
        if reach.hi < maxU {
            cut.append(rectangle(across, from: reach.hi, to: max(maxU, reach.hi) + mouthOvershoot, width: height))
        }
        if reach.lo > minU {
            cut.append(rectangle(across, from: min(minU, reach.lo) - mouthOvershoot, to: reach.lo, width: height))
        }
        return cut
    }

    // MARK: - Crossing lines

    /// A line in a section's coordinates: `origin + u * direction`, with
    /// `direction` a unit vector. The same `u` names the same model point in
    /// both ribs' sections.
    struct SectionLine: Equatable {
        var origin: Vec2
        var direction: Vec2

        func point(at u: Double, offset: Double = 0) -> Vec2 {
            Vec2(
                x: origin.x + direction.x * u - direction.y * offset,
                y: origin.y + direction.y * u + direction.x * offset
            )
        }
    }

    struct Crossing: Equatable {
        var primary: SectionLine
        var curve: SectionLine
        var origin: Vec3
        var direction: Vec3
        /// Sine of the angle between the two ribs.
        var sine: Double

        func point(at u: Double) -> Vec3 {
            Vec3(x: origin.x + direction.x * u, y: origin.y + direction.y * u, z: origin.z + direction.z * u)
        }
    }

    /// The line shared by the first-axis rib at `position` and the curve rib
    /// through `center` whose section runs along `inPlane`. First-axis
    /// sections use the stacked projection ((y, z), (x, z) or (x, y)); curve
    /// sections use (distance along `inPlane`, z).
    static func crossing(axis: SliceAxis, position: Double, center: Vec3, inPlane: Vec2) -> Crossing? {
        let up = Vec2(x: 0, y: 1)
        switch axis {
        case .z:
            return Crossing(
                primary: SectionLine(origin: Vec2(x: center.x, y: center.y), direction: inPlane),
                curve: SectionLine(origin: Vec2(x: 0, y: position), direction: Vec2(x: 1, y: 0)),
                origin: Vec3(x: center.x, y: center.y, z: position),
                direction: Vec3(x: inPlane.x, y: inPlane.y, z: 0),
                sine: 1
            )
        case .y:
            guard abs(inPlane.y) >= minimumCrossingSine else { return nil }
            let along = (position - center.y) / inPlane.y
            let x = center.x + along * inPlane.x
            return Crossing(
                primary: SectionLine(origin: Vec2(x: x, y: 0), direction: up),
                curve: SectionLine(origin: Vec2(x: along, y: 0), direction: up),
                origin: Vec3(x: x, y: position, z: 0),
                direction: Vec3(x: 0, y: 0, z: 1),
                sine: abs(inPlane.y)
            )
        case .x:
            guard abs(inPlane.x) >= minimumCrossingSine else { return nil }
            let along = (position - center.x) / inPlane.x
            let y = center.y + along * inPlane.y
            return Crossing(
                primary: SectionLine(origin: Vec2(x: y, y: 0), direction: up),
                curve: SectionLine(origin: Vec2(x: along, y: 0), direction: up),
                origin: Vec3(x: position, y: y, z: 0),
                direction: Vec3(x: 0, y: 0, z: 1),
                sine: abs(inPlane.x)
            )
        }
    }

    // MARK: - Material along a line

    struct Span: Equatable {
        var lo: Double
        var hi: Double
    }

    /// Where the line (shifted sideways by `offset`) runs inside `loops`,
    /// counted even-odd, as sorted spans of `u`.
    static func materialSpans(_ loops: [[Vec2]], along line: SectionLine, offset: Double = 0) -> [Span] {
        let origin = line.point(at: 0, offset: offset)
        let normal = Vec2(x: -line.direction.y, y: line.direction.x)
        var crossings: [Double] = []
        for loop in loops where loop.count >= 3 {
            for index in loop.indices {
                let a = loop[index]
                let b = loop[(index + 1) % loop.count]
                let da = (a.x - origin.x) * normal.x + (a.y - origin.y) * normal.y
                let db = (b.x - origin.x) * normal.x + (b.y - origin.y) * normal.y
                guard (da > 0) != (db > 0) else { continue }
                let t = da / (da - db)
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                crossings.append((x - origin.x) * line.direction.x + (y - origin.y) * line.direction.y)
            }
        }
        crossings.sort()
        return stride(from: 0, to: crossings.count - 1, by: 2).map { Span(lo: crossings[$0], hi: crossings[$0 + 1]) }
    }

    /// Where, in each rib's section, the lines across the beam lie: the beam
    /// is where both ribs' stock (`thickness` thick, centred on its plane)
    /// overlaps around the crossing line. Each entry is one line's sideways
    /// offset from the crossing line in the first-axis and in the curve
    /// section.
    static func beamOffsets(
        line: Crossing,
        primaryFrame: PartPlaneFrame,
        curveFrame: PartPlaneFrame,
        thickness: Double
    ) -> [(primary: Double, curve: Double)] {
        let primaryNormal = cross(primaryFrame.xAxis, primaryFrame.yAxis)
        let curveNormal = cross(curveFrame.xAxis, curveFrame.yAxis)
        let primarySide = sideways(line.primary, in: primaryFrame)
        let curveSide = sideways(line.curve, in: curveFrame)
        var offsets: [(primary: Double, curve: Double)] = []
        for i in 0..<beamSamples {
            for j in 0..<beamSamples {
                let primaryDepth = thickness * (Double(i) / Double(beamSamples - 1) - 0.5)
                let curveDepth = thickness * (Double(j) / Double(beamSamples - 1) - 0.5)
                // The point off the crossing line at these depths into the two
                // ribs' stock, square to the line.
                guard let shift = solve(
                    rows: [primaryNormal, curveNormal, line.direction],
                    values: [primaryDepth, curveDepth, 0]
                ) else { continue }
                offsets.append((primary: dot(shift, primarySide), curve: dot(shift, curveSide)))
            }
        }
        return offsets
    }

    static func overlaps(_ lhs: [Span], _ rhs: [Span]) -> [Span] {
        var result: [Span] = []
        for a in lhs {
            for b in rhs {
                let lo = max(a.lo, b.lo)
                let hi = min(a.hi, b.hi)
                if hi > lo {
                    result.append(Span(lo: lo, hi: hi))
                }
            }
        }
        return result.sorted { $0.lo < $1.lo }
    }

    /// Where the slot from `middle` toward `edge` must end so it opens clean
    /// through the part's edge across its whole width: past the farthest edge
    /// crossing of any line across the slot, by `mouthOvershoot`, but stopping
    /// halfway to material that starts again beyond the edge. `forward` is
    /// true when the mouth lies at larger `u`.
    static func mouth(
        loops: [[Vec2]],
        line: SectionLine,
        width: Double,
        middle: Double,
        edge: Double,
        forward: Bool
    ) -> Double {
        let sign = forward ? 1.0 : -1.0
        var exit = edge * sign
        var resume = Double.greatestFiniteMagnitude
        for sample in 0..<widthSamples {
            let offset = width * (Double(sample) / Double(widthSamples - 1) - 0.5)
            // Work in the slot's own direction: spans run from `middle * sign`
            // outward.
            let spans = materialSpans(loops, along: line, offset: offset).map { span in
                forward ? span : Span(lo: -span.hi, hi: -span.lo)
            }
            for span in spans {
                if span.lo < edge * sign, span.hi > middle * sign {
                    exit = max(exit, span.hi)
                } else if span.lo >= edge * sign {
                    resume = min(resume, span.lo)
                }
            }
        }
        let overshoot = resume > exit ? min(mouthOvershoot, (resume - exit) / 2) : 0
        return (exit + overshoot) * sign
    }

    /// One rib's material along a crossing line: its section loops and the
    /// line in its section coordinates.
    struct RunSide {
        var loops: [[Vec2]]
        var line: SectionLine
    }

    /// Where in `span` the slot bottoms meet: its middle, moved just far
    /// enough that each slot opens through one edge of its rib and cuts no
    /// hole of its own rib into the open. The slot running toward larger `u`
    /// (in rib `forward`) must start, on every line across it, at least `web`
    /// (the stock thickness, `slotWeb`) past the start of that rib's last
    /// stretch of material in the span, so a web that thick is left between
    /// its bottom and the hole or edge below it; the slot running toward
    /// smaller `u` (in rib `backward`) must stop as far short of the end of
    /// its rib's first stretch. Neither slot runs on beside a strip of its
    /// rib narrower than `web` (`thinStrips`) when the meeting point can
    /// stop it short of one. Each rib keeps some of the span where both have
    /// material on the crossing line itself (`centre`), and the meeting point
    /// stays within `lowest` and `highest` (slots kept apart near the
    /// spline). Where that cannot all be met, the webs shrink to
    /// `minimumWeb`, and the strips are let be; when both slots still cannot
    /// be kept clear, the first-axis rib's slot is (`firstAxisForward` says
    /// which one that is), then the curve rib's; failing both, the middle.
    static func meetingPoint(
        of span: Span,
        centre: Span? = nil,
        forward: RunSide,
        backward: RunSide,
        width: Double,
        web: Double = minimumWeb,
        firstAxisForward: Bool = true,
        lowest: Double = -.infinity,
        highest: Double = .infinity
    ) -> Double {
        let middle = (span.lo + span.hi) / 2
        // Each rib keeps some of the stretch on the crossing line itself.
        let held = centre.map { Span(lo: max(span.lo, $0.lo), hi: min(span.hi, $0.hi)) }
            .flatMap { $0.hi > $0.lo ? $0 : nil } ?? span
        let keep = min(minimumWeb, (held.hi - held.lo) / 4)
        let low = max(held.lo + keep, min(lowest, held.hi - keep))
        let high = min(held.hi - keep, max(highest, held.lo + keep))
        // A slot runs from the meeting point out through its rib's edge:
        // the forward rib's starts `minimumWeb` past every thin strip of
        // that rib that ends inside the span, and the backward rib's stops
        // as far short of every one of its own.
        let stripLow = thinStrips(forward, width: width, web: web)
            .filter { $0.hi < held.hi - keep && $0.hi > span.lo }
            .map { $0.hi + minimumWeb }.max() ?? -.infinity
        let stripHigh = thinStrips(backward, width: width, web: web)
            .filter { $0.lo > held.lo + keep && $0.lo < span.hi }
            .map { $0.lo - minimumWeb }.min() ?? .infinity
        let clearances = web > minimumWeb ? [web, minimumWeb] : [minimumWeb]
        let forwardStart = runStart(forward, width: width, within: span, last: true)
        let backwardEnd = runStart(backward, width: width, within: span, last: false)
        var candidates: [(Double, Double)] = []
        for clearance in clearances {
            candidates += [
                (max(low, forwardStart + clearance, stripLow), min(high, backwardEnd - clearance, stripHigh)),
                (max(low, forwardStart + clearance), min(high, backwardEnd - clearance))
            ]
        }
        let forwardOnly = clearances.map { (max(low, forwardStart + $0), high) }
        let backwardOnly = clearances.map { (low, min(high, backwardEnd - $0)) }
        candidates += firstAxisForward ? forwardOnly + backwardOnly : backwardOnly + forwardOnly
        for (lo, hi) in candidates where lo <= hi {
            return min(max(middle, lo), hi)
        }
        return low <= high ? min(max(middle, low), high) : middle
    }

    /// Stretches of `u`, at least twice `web` long, where a slot of `width`
    /// on the rib's crossing line would leave the rib's material beside it
    /// narrower than `web` on one side: the section's edge, or a hole, runs
    /// along the slot closer than that. A slot running on beside such a
    /// strip leaves it to hold the rib together.
    static func thinStrips(_ side: RunSide, width: Double, web: Double) -> [Span] {
        var thin: [Span] = []
        for sign in [-1.0, 1.0] {
            let beside = materialSpans(side.loops, along: side.line, offset: sign * (width / 2 + 0.05))
            guard !beside.isEmpty else { continue }
            var solid = beside
            for step in 1...4 {
                let offset = sign * (width / 2 + (web - 0.05) * Double(step) / 4)
                solid = merged(overlaps(solid, materialSpans(side.loops, along: side.line, offset: offset)))
            }
            thin += subtracting(solid, from: beside)
        }
        return merged(thin).filter { $0.hi - $0.lo >= 2 * web }
    }

    /// The parts of `spans` outside every span of `cuts` (both sorted and
    /// merged).
    static func subtracting(_ cuts: [Span], from spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans {
            var lo = span.lo
            for cut in cuts where cut.hi > lo && cut.lo < span.hi {
                if cut.lo > lo {
                    result.append(Span(lo: lo, hi: cut.lo))
                }
                lo = max(lo, cut.hi)
            }
            if lo < span.hi {
                result.append(Span(lo: lo, hi: span.hi))
            }
        }
        return result
    }

    /// Along the lines across a slot of `width`: for `last`, the latest start
    /// of the last stretch of material each line has in `span` (a slot
    /// running toward larger `u` must start past it); otherwise the earliest
    /// end of the first stretch (a slot running toward smaller `u` must stop
    /// short of it). Lines with no material in the span are skipped; with
    /// none at all, the span's own end.
    private static func runStart(_ side: RunSide, width: Double, within span: Span, last: Bool) -> Double {
        var bound = last ? -Double.infinity : Double.infinity
        for sample in 0..<widthSamples {
            let offset = width * (Double(sample) / Double(widthSamples - 1) - 0.5)
            let runs = materialSpans(side.loops, along: side.line, offset: offset)
                .filter { $0.hi > span.lo && $0.lo < span.hi }
            if last, let run = runs.max(by: { $0.hi < $1.hi }) {
                bound = max(bound, run.lo)
            } else if !last, let run = runs.min(by: { $0.lo < $1.lo }) {
                bound = min(bound, run.hi)
            }
        }
        if bound.isFinite { return bound }
        return last ? span.lo - minimumWeb : span.hi + minimumWeb
    }

    /// Where a Radial Slices joint's slot bottoms meet (`RadialPartBuilder`):
    /// the middle of `span`, moved just far enough that the slot running
    /// toward larger `u` starts past every gap of its own rib's material in
    /// the span (`forwardGaps`) and the slot running toward smaller `u` stops
    /// short of every gap of its own (`backwardGaps`), with a web of material
    /// between; each rib keeps some of the span. When that cannot be met,
    /// the middle.
    static func meetingPoint(of span: Span, forwardGaps: [Span], backwardGaps: [Span]) -> Double {
        let middle = (span.lo + span.hi) / 2
        let keep = min(minimumWeb, (span.hi - span.lo) / 4)
        var low = span.lo + keep
        var high = span.hi - keep
        for gap in forwardGaps {
            low = max(low, gap.hi + minimumWeb)
        }
        for gap in backwardGaps {
            high = min(high, gap.lo - minimumWeb)
        }
        guard low <= high else { return middle }
        return min(max(middle, low), high)
    }

    /// Gaps in the part's material inside `span`, along lines across a slot
    /// of `width`: stretches between two pieces of material on one line, such
    /// as a hole the line passes.
    static func gaps(_ loops: [[Vec2]], along line: SectionLine, width: Double, within span: Span) -> [Span] {
        var result: [Span] = []
        for sample in 0..<widthSamples {
            let offset = width * (Double(sample) / Double(widthSamples - 1) - 0.5)
            let spans = materialSpans(loops, along: line, offset: offset)
            for (before, after) in zip(spans, spans.dropFirst()) where after.lo > before.hi {
                if after.lo > span.lo, before.hi < span.hi {
                    result.append(Span(lo: before.hi, hi: after.lo))
                }
            }
        }
        return result
    }

    static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { $0.lo < $1.lo }) {
            if let last = result.last, span.lo <= last.hi {
                result[result.count - 1].hi = max(last.hi, span.hi)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// The model direction of a section line's sideways offset.
    private static func sideways(_ line: SectionLine, in frame: PartPlaneFrame) -> Vec3 {
        let side = Vec2(x: -line.direction.y, y: line.direction.x)
        return Vec3(
            x: frame.xAxis.x * side.x + frame.yAxis.x * side.y,
            y: frame.xAxis.y * side.x + frame.yAxis.y * side.y,
            z: frame.xAxis.z * side.x + frame.yAxis.z * side.y
        )
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    /// The point `p` with `rows[k] · p == values[k]` (Cramer's rule), or nil
    /// when the rows are dependent.
    private static func solve(rows: [Vec3], values: [Double]) -> Vec3? {
        let determinant = dot(rows[0], cross(rows[1], rows[2]))
        guard abs(determinant) > 1.0e-12 else { return nil }
        let x = dot(Vec3(x: values[0], y: rows[0].y, z: rows[0].z), cross(
            Vec3(x: values[1], y: rows[1].y, z: rows[1].z), Vec3(x: values[2], y: rows[2].y, z: rows[2].z)))
        let y = dot(Vec3(x: rows[0].x, y: values[0], z: rows[0].z), cross(
            Vec3(x: rows[1].x, y: values[1], z: rows[1].z), Vec3(x: rows[2].x, y: values[2], z: rows[2].z)))
        let z = dot(Vec3(x: rows[0].x, y: rows[0].y, z: values[0]), cross(
            Vec3(x: rows[1].x, y: rows[1].y, z: values[1]), Vec3(x: rows[2].x, y: rows[2].y, z: values[2])))
        return Vec3(x: x / determinant, y: y / determinant, z: z / determinant)
    }

    static func rectangle(_ line: SectionLine, from lo: Double, to hi: Double, width: Double) -> SlicePath2D {
        let half = width / 2
        let corners = [
            line.point(at: lo, offset: -half),
            line.point(at: hi, offset: -half),
            line.point(at: hi, offset: half),
            line.point(at: lo, offset: half)
        ]
        return SlicePath2D(points: corners + [corners[0]], closed: true)
    }

    static func closedLoops(_ paths: [SlicePath2D]) -> [[Vec2]] {
        paths.compactMap { path in
            guard path.closed || path.points.first == path.points.last else { return nil }
            var points = path.points
            if points.count >= 2, let first = points.first, let last = points.last,
               abs(first.x - last.x) < 1.0e-9, abs(first.y - last.y) < 1.0e-9 {
                points.removeLast()
            }
            return points.count >= 3 ? points : nil
        }
    }
}
