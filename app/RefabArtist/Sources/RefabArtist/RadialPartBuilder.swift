import Foundation

/// Builds the flat parts of a Radial model — rings and fins — in true-mm
/// coordinates, with the half-lap joints that lock them together.
///
///   * Rings are sections of the model on planes square to the first axis
///     (`StackedSliceContourer`), in that section's projection. A ring falls
///     into several pieces where the model does; each piece, with the holes
///     of its section, is its own part.
///   * Fins are sections of the model by half-planes that start at the hub
///     axis (the first-axis line through the centre of the model's bounding
///     box), one per fin angle, in (distance from the hub axis, position along
///     the first axis). Each closed piece of a fin section is its own part.
///   * Joints. A ring and a fin cross at right angles along the line their
///     planes share: out from the hub axis in the fin's direction, at the
///     ring's height. Where both parts' stock would occupy the same space
///     around that line, the ring keeps the inner part of the shared stretch
///     and is notched from there out through its rim; the fin keeps the outer
///     part and is slotted from its inner edge out to the same point. Both
///     cuts are the plan's slot width wide (the stock thickness plus the slot
///     offset, or the notch-width override), so each takes the other part's
///     stock. With the rings stacked, each fin slides in toward the hub axis
///     until its slot bottoms meet the rings' notch bottoms. Where the line
///     passes through the model more than once, the joint sits in the
///     outermost shared stretch and the ring keeps every stretch inward of it:
///     the fin's slot runs through those, so the fin still slides in. A fin
///     piece those slots cut off becomes a part of its own; one that holds no
///     joint anywhere is not held by the rings, and is marked as such
///     (`ModelPart.joined`) so the cut sheet can say so.
///   * Sections. Shells of the model that touch or overlap give one piece of
///     material, not one per shell (`sectionIslands`), and every joint is
///     planned against the pieces that are cut, so no notch waits for a piece
///     that is left out.
///   * Hub. Next to the hub axis neighbouring fins' stock would overlap, so
///     every fin starts `hubInset` from the axis, where it just clears its
///     neighbours. The rings span the hub.
enum RadialPartBuilder {
    // MARK: - Model-space (true mm) parts
    //
    // The GUI cut sheet, viewport solids, and default vector/mesh exports all
    // consume THESE.

    /// One ring or fin part in true model mm.
    struct ModelPart {
        /// Index into `plan.primary.positions` (rings) or `wedgeAngles`
        /// (fins).
        var sliceIndex: Int
        /// Primary-axis position in mm (rings) or fin angle in radians
        /// (fins).
        var position: Double
        /// Closed counter-clockwise outline (no duplicate closing vertex) —
        /// rings in the primary-axis projection frame, fins in the (radial,
        /// axis) frame where x is the distance from the hub axis and y the
        /// absolute axis coordinate.
        var loop: [Vec2]
        /// Holes in the part (voids of its section), clockwise, in the same
        /// frame.
        var holes: [[Vec2]] = []
        /// Disconnected piece index within a ring or fin. Most clean parts
        /// are zero; concave or broken meshes can split one section into
        /// several cuttable pieces instead of bridging voids.
        var componentIndex = 0
        /// A joint cut took away the whole piece although it holds part of
        /// one of its joints (`CutSheetLayoutBuilder.slottedPieces`).
        var severed = false
        /// The part holds at least one half-lap with a part of the other
        /// family. A piece whose every crossing is a slot or notch cut
        /// clean through it is not held there and must be glued in place.
        var joined = true
        /// Narrower than the stock somewhere between two parts of it, as
        /// Curve Slices flags its parts, or all over (`narrowerThan`): it
        /// may snap there.
        var thin = false

        /// The outline and holes as closed paths.
        var paths: [SlicePath2D] {
            ([loop] + holes).compactMap { points in
                guard let first = points.first, points.count >= 3 else { return nil }
                return SlicePath2D(points: points + [first], closed: true)
            }
        }
    }

    /// One ring/fin joint.
    struct Joint: Equatable {
        var ringLayer: Int
        var fin: Int
        /// The crossing line, `origin + u * direction`, where `u` is the
        /// distance from the hub axis.
        var origin: Vec3
        var direction: Vec3
        /// The outermost stretch of the line where both parts' stock
        /// overlaps. The ring keeps it from `start` to `meet` and the fin
        /// from `meet` to `end`.
        var start: Double
        var end: Double
        var meet: Double
        /// Where the line first runs into both parts' stock. The fin's slot
        /// runs from its inner edge before here out to `meet`.
        var inner: Double
        /// Width of the ring's notch and the fin's slot.
        var width: Double

        func point(at u: Double) -> Vec3 {
            Vec3(x: origin.x + direction.x * u, y: origin.y + direction.y * u, z: origin.z + direction.z * u)
        }
    }

    /// The rings and fins with their joints cut, and the joints.
    struct Assembly {
        var disks: [ModelPart]
        var wedges: [ModelPart]
        var joints: [Joint]
        /// The ring of every ring piece left out because no fin's stock
        /// crosses it: nothing would hold it in place (the simple chair's
        /// legs). One entry per piece.
        var uncrossedRings: [Int] = []
        /// The ring, and the fin, of every piece left out because the
        /// joints' cuts take it away whole or leave only scraps of it. One
        /// entry per piece.
        var cutAwayRings: [Int] = []
        var cutAwayFins: [Int] = []

        /// Parts that hold no half-lap (`ModelPart.joined`).
        var unjoined: [ModelPart] {
            (disks + wedges).filter { !$0.joined }
        }
    }

    /// The joints planned between the ring and fin pieces, and what they cut.
    private struct Cuts {
        var joints: [Joint] = []
        /// Notches (and their relief) per ring, in its section coordinates.
        var ringSlots: [[[Vec2]]]
        /// Slots (and their relief) per fin, in its section coordinates.
        var finSlots: [[[Vec2]]]
        /// A point in the middle of the material each ring keeps at each of
        /// its joints: a piece that holds one holds that joint.
        var ringKept: [[Vec2]]
        /// The same for each fin.
        var finKept: [[Vec2]]
        /// Per ring, the stretch of each of its joints' crossing lines it
        /// keeps (from the joint's start out to the meeting point), in its
        /// section coordinates: a piece with material there holds that
        /// joint.
        var ringHolds: [[Hold]]
        /// The same for each fin (from the meeting point out to the joint's
        /// end).
        var finHolds: [[Hold]]
        /// Per ring piece: whether some fin's stock crosses it.
        var ringCrossed: [[Bool]]
    }

    /// The stretch `lo`…`hi` of a joint's crossing line that one of its two
    /// parts keeps, in that part's section coordinates.
    private struct Hold {
        var line: CurveJointPlanner.SectionLine
        var lo: Double
        var hi: Double

        /// Whether `loops` (an outline, then its holes) keep more than
        /// `jointHoldTolerance` of the stretch.
        func held(by loops: [[Vec2]]) -> Bool {
            let kept = CurveJointPlanner.materialSpans(loops, along: line).reduce(0.0) { total, span in
                total + max(0, min(hi, span.hi) - max(lo, span.lo))
            }
            return kept > jointHoldTolerance
        }
    }

    /// Material (mm) a piece must keep along a joint's crossing line to hold
    /// that joint, as the functional gate counts it.
    private static let jointHoldTolerance = 0.02

    static func diskPartsModel(plan: RadialSlicePlan, model: MeshSummary) -> [ModelPart] {
        assembly(plan: plan, model: model).disks
    }

    static func wedgePartsModel(plan: RadialSlicePlan, model: MeshSummary) -> [ModelPart] {
        assembly(plan: plan, model: model).wedges
    }

    static func assembly(plan: RadialSlicePlan, model: MeshSummary) -> Assembly {
        guard let primary = plan.primary, let bounds = model.bounds else {
            return Assembly(disks: [], wedges: [], joints: [])
        }
        let axis = primary.axis
        let center = boxCenter(bounds)
        let angles = wedgeAngles(plan: plan)
        let rings = StackedSliceContourer.generate(model: model, plan: primary)
        let positions = rings.layers.indices.map { primary.positions.indices.contains($0) ? primary.positions[$0] : 0 }
        let triangles = meshTriangles(model)
        let winding = MeshWinding(triangles: triangles)
        let inset = hubInset(plan: plan)

        // The pieces each ring and fin is cut from: whole pieces of their
        // sections, less slivers, and the rings the viewport can extrude.
        var ringIslands = withoutSlivers(rings.layers.map { layer in
            sectionIslands(materialOnLeft(
                CurveJointPlanner.closedLoops(layer.paths),
                edges: ringSectionEdges(triangles: triangles, axis: axis, position: layer.position),
                winding: winding
            ))
        })
        ringIslands = ringIslands.indices.map { index in
            ringIslands[index].filter {
                canRenderDisk($0.loops, axis: axis, position: positions[index], materialThickness: plan.materialThickness)
            }
        }
        var finIslands = withoutSlivers(angles.map { angle in
            sectionIslands(radialSectionPolygons(
                triangles: triangles, center: center, axis: axis, angle: angle, hubInset: inset, winding: winding
            ))
        })
        let anyFin = plan.nRadial > 0 && finIslands.contains { !$0.isEmpty }

        // Plan the joints and cut the pieces. A ring piece that no fin
        // crosses has nothing to hold it and is left out (with no fin at all
        // every ring is kept, and none is held). A piece the cuts take away
        // whole, or leave only scraps of, is left out too. Either way the
        // joints are planned again without it, so no cut waits for a piece
        // that is not there.
        var disks: [ModelPart] = []
        var wedges: [ModelPart] = []
        var uncrossedRings: [Int] = []
        var cutAwayRings: [Int] = []
        var cutAwayFins: [Int] = []
        let web = CurveJointPlanner.slotWeb(thickness: plan.materialThickness)
        var cuts = planCuts(plan: plan, model: model, positions: positions, angles: angles, rings: ringIslands, fins: finIslands)
        for round in 0..<6 {
            let replan = round < 5
            if anyFin, replan, cuts.ringCrossed.contains(where: { $0.contains(false) }) {
                for ring in ringIslands.indices {
                    uncrossedRings += Array(repeating: ring, count: cuts.ringCrossed[ring].filter { !$0 }.count)
                }
                ringIslands = ringIslands.indices.map { ring in
                    ringIslands[ring].indices.filter { cuts.ringCrossed[ring][$0] }.map { ringIslands[ring][$0] }
                }
                cuts = planCuts(plan: plan, model: model, positions: positions, angles: angles, rings: ringIslands, fins: finIslands)
                continue
            }
            let ringScrap = scrapArea(ringIslands)
            let finScrap = scrapArea(finIslands)
            var lostRings = Array(repeating: [Int](), count: ringIslands.count)
            var lostFins = Array(repeating: [Int](), count: finIslands.count)
            disks = []
            wedges = []
            for ring in ringIslands.indices {
                var pieces: [ModelPart] = []
                for (index, island) in ringIslands[ring].enumerated() {
                    let cut = cutPieces(
                        island, slots: cuts.ringSlots[ring], keeping: cuts.ringKept[ring], holds: cuts.ringHolds[ring],
                        scrap: ringScrap, web: web, sliceIndex: ring, position: positions[ring]
                    )
                    if cut.isEmpty {
                        lostRings[ring].append(index)
                    }
                    pieces += cut
                }
                disks += numbered(pieces)
            }
            for fin in finIslands.indices {
                var pieces: [ModelPart] = []
                for (index, island) in finIslands[fin].enumerated() {
                    let cut = cutPieces(
                        island, slots: cuts.finSlots[fin], keeping: cuts.finKept[fin], holds: cuts.finHolds[fin],
                        scrap: finScrap, web: web, sliceIndex: fin, position: angles[fin]
                    )
                    if cut.isEmpty {
                        lostFins[fin].append(index)
                    }
                    pieces += cut
                }
                wedges += numbered(pieces)
            }
            let lost = lostRings.contains { !$0.isEmpty } || lostFins.contains { !$0.isEmpty }
            for ring in lostRings.indices {
                cutAwayRings += Array(repeating: ring, count: lostRings[ring].count)
            }
            for fin in lostFins.indices {
                cutAwayFins += Array(repeating: fin, count: lostFins[fin].count)
            }
            guard lost, replan else { break }
            ringIslands = ringIslands.indices.map { ring in
                ringIslands[ring].indices.filter { !lostRings[ring].contains($0) }.map { ringIslands[ring][$0] }
            }
            finIslands = finIslands.indices.map { fin in
                finIslands[fin].indices.filter { !lostFins[fin].contains($0) }.map { finIslands[fin][$0] }
            }
            cuts = planCuts(plan: plan, model: model, positions: positions, angles: angles, rings: ringIslands, fins: finIslands)
        }
        return Assembly(
            disks: disks,
            wedges: wedges,
            joints: cuts.joints,
            uncrossedRings: uncrossedRings.sorted(),
            cutAwayRings: cutAwayRings.sorted(),
            cutAwayFins: cutAwayFins.sorted()
        )
    }

    /// The material of a section as separate pieces, each an outer loop with
    /// the holes inside it. `loops` have the model's material on their left
    /// (`materialOnLeft`). Usually that agrees with counting how many other
    /// loops each lies inside (outer boundaries at even depth), and the
    /// loops are used as they are. Shells of the model that touch (a head on
    /// a neck, a seat on its back) or overlap (two blocks run into each
    /// other) do not: their material is the union of the loops, so the
    /// pieces come out as the solid the model shows, not one per shell or
    /// with the overlap left out.
    private static func sectionIslands(_ loops: [[Vec2]]) -> [CutSheetLayoutBuilder.Island] {
        let usable = loops.filter { $0.count >= 3 }
        let islands = CutSheetLayoutBuilder.islandize(paths: usable.map(closedPath))
            .filter { $0.loops.first.map { $0.count >= 3 } ?? false }
        let agrees = usable.indices.allSatisfy { index in
            let depth = usable.indices.filter { other in
                other != index && CutSheetLayoutBuilder.contains(usable[other], point: usable[index][0])
            }.count
            return (depth % 2 == 0) == (polyArea(usable[index]) > 0)
        }
        if agrees {
            guard islands.count > 1 else { return islands }
            let boxes = islands.map { box($0.loops[0]) }
            let touching = boxes.indices.contains { a in
                boxes.indices.contains { b in
                    b > a
                        && boxes[a].min.x <= boxes[b].max.x + sectionWeld && boxes[b].min.x <= boxes[a].max.x + sectionWeld
                        && boxes[a].min.y <= boxes[b].max.y + sectionWeld && boxes[b].min.y <= boxes[a].max.y + sectionWeld
                }
            }
            guard touching else { return islands }
        }
        guard let joined = PlanarBoolean.joining(usable, closingBy: sectionWeld) else { return islands }
        return CutSheetLayoutBuilder.islandize(paths: joined.map(closedPath))
            .filter { $0.loops.first.map { $0.count >= 3 } ?? false }
    }

    /// One segment of a section, and the direction (in the section's
    /// coordinates) the surface it was cut from faces: out of the model.
    private struct SectionEdge {
        var a: Vec2
        var b: Vec2
        var outward: Vec2
        /// The index of the triangle it was cut from (`meshTriangles`).
        var triangle: Int
    }

    /// Edges of the section of the ring plane at `position` along `axis`, in
    /// the ring's section coordinates.
    private static func ringSectionEdges(triangles: [(Vec3, Vec3, Vec3)], axis: SliceAxis, position: Double) -> [SectionEdge] {
        func project(_ point: Vec3) -> Vec2 {
            switch axis {
            case .x: return Vec2(x: point.y, y: point.z)
            case .y: return Vec2(x: point.x, y: point.z)
            case .z: return Vec2(x: point.x, y: point.y)
            }
        }
        var edges: [SectionEdge] = []
        for (index, tri) in triangles.enumerated() {
            let corners = [tri.0, tri.1, tri.2]
            let distances = corners.map { coordinate($0, axis: axis) - position }
            guard let low = distances.min(), let high = distances.max(), low < 0, high > 0 else { continue }
            var points: [Vec2] = []
            for i in 0..<3 {
                let (a, b) = (corners[i], corners[(i + 1) % 3])
                let (da, db) = (distances[i], distances[(i + 1) % 3])
                if da == 0 {
                    points.append(project(a))
                } else if (da < 0) != (db < 0), db != 0 {
                    let t = da / (da - db)
                    points.append(project(Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)))
                }
            }
            guard points.count == 2 else { continue }
            edges.append(SectionEdge(a: points[0], b: points[1], outward: project(triangleNormal(tri)), triangle: index))
        }
        return edges
    }

    /// The outward normal of a triangle, from its winding (not normalised).
    private static func triangleNormal(_ tri: (Vec3, Vec3, Vec3)) -> Vec3 {
        cross(subtract(tri.1, tri.0), subtract(tri.2, tri.0))
    }

    /// `loops` each turned so the model's material lies on its left (outer
    /// boundaries counter-clockwise, holes clockwise), as the surface the
    /// loop was cut from says: up to `orientationSamples` of each loop's
    /// edges are matched to the section `edges` they lie on, and each votes
    /// by which side the surface faces. A loop none of whose edges matches
    /// is turned by how many other loops it lies inside (even: outer).
    /// When the loops do not come out turned as their nesting says and the
    /// model's triangles wind both ways (`winding`, `MeshWinding.flips`),
    /// they are turned again with the triangles read consistently; a mesh
    /// whose triangles all agree is read as it is.
    private static func materialOnLeft(_ loops: [[Vec2]], edges: [SectionEdge], winding: MeshWinding) -> [[Vec2]] {
        let oriented = materialOnLeft(loops, edges: edges, flips: nil)
        guard !MeshWinding.followsNesting(oriented), let flips = winding.flips else {
            return oriented
        }
        return materialOnLeft(loops, edges: edges, flips: flips)
    }

    /// `materialOnLeft` with the triangles `flips` marks read the other way
    /// round.
    private static func materialOnLeft(_ loops: [[Vec2]], edges: [SectionEdge], flips: [Bool]?) -> [[Vec2]] {
        let usable = loops.filter { $0.count >= 3 }
        return usable.indices.map { index in
            let loop = usable[index]
            var vote = 0
            let samples = min(orientationSamples, loop.count)
            for sample in 0..<samples {
                let i = sample * loop.count / samples
                let (p, q) = (loop[i], loop[(i + 1) % loop.count])
                let d = Vec2(x: q.x - p.x, y: q.y - p.y)
                let length = (d.x * d.x + d.y * d.y).squareRoot()
                guard length > 1.0e-9 else { continue }
                let middle = Vec2(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                guard let edge = edges.first(where: { edge in
                    let e = Vec2(x: edge.b.x - edge.a.x, y: edge.b.y - edge.a.y)
                    let edgeLength = (e.x * e.x + e.y * e.y).squareRoot()
                    guard edgeLength > 1.0e-9, abs(d.x * e.y - d.y * e.x) <= 1.0e-3 * length * edgeLength else { return false }
                    return distance(middle, toSegment: edge.a, edge.b) <= 1.0e-5
                }) else { continue }
                // The surface faces to the right of the loop's direction:
                // the material is on its left.
                let flipped = flips.map { edge.triangle < $0.count && $0[edge.triangle] } ?? false
                let outward = flipped ? Vec2(x: -edge.outward.x, y: -edge.outward.y) : edge.outward
                vote += d.x * outward.y - d.y * outward.x < 0 ? 1 : -1
            }
            if vote != 0 {
                return vote > 0 ? loop : Array(loop.reversed())
            }
            let depth = usable.indices.filter { other in
                other != index && CutSheetLayoutBuilder.contains(usable[other], point: loop[0])
            }.count
            return oriented(loop, counterClockwise: depth % 2 == 0)
        }
    }

    /// Edges of a loop matched to its section to find which side the model
    /// lies on.
    private static let orientationSamples = 8

    private static func distance(_ point: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = Vec2(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / lengthSquared)) : 0
        let dx = point.x - (a.x + ab.x * t)
        let dy = point.y - (a.y + ab.y * t)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Pieces of a section closer than this (mm) are one piece: shells that
    /// touch along a face.
    private static let sectionWeld = 1.0e-3

    /// The material of `loops` (an outline, then its holes) less what is
    /// narrower than the 1 mm web the cuts keep (`CurveJointPlanner.minimumWeb`):
    /// shrunk by just under half the web and grown back (`hairline`). nil
    /// when that takes away less than `hairlineArea` and does not part the
    /// piece, or the opening fails.
    private static func openedLoops(_ loops: [[Vec2]]) -> [[Vec2]]? {
        guard let outline = loops.first, outline.count >= 3 else { return nil }
        let rings = [oriented(outline, counterClockwise: true)]
            + loops.dropFirst().filter { $0.count >= 3 }.map { oriented($0, counterClockwise: false) }
        guard let opened = PlanarBoolean.joining(rings, closingBy: 0, openingBy: hairline) else { return nil }
        let before = rings.reduce(0) { $0 + polyArea($1) }
        let after = opened.reduce(0) { $0 + polyArea($1) }
        let pieces = opened.filter { polyArea($0) > 0 }.count
        guard before - after >= hairlineArea || pieces != 1 else { return nil }
        return opened
    }

    /// How far (mm) a piece is shrunk and grown back to find what is
    /// narrower than the 1 mm web: just under half of it, so a web of
    /// exactly 1 mm stays.
    private static let hairline = CurveJointPlanner.minimumWeb / 2 - 0.05

    /// Least material (mm²) the opening must take away from a piece that it
    /// does not part before the piece is cut without it: less is the corner
    /// of a sharp tip, not a strip.
    private static let hairlineArea = 0.5

    /// Each family's pieces less slivers: pieces under 1% of the family's
    /// largest. A hand's thin extremity slices produce 10–30 mm² scraps that
    /// aren't buildable and just litter the sheet. Relative, so it is a
    /// no-op on uniform convex models.
    private static func withoutSlivers(_ family: [[CutSheetLayoutBuilder.Island]]) -> [[CutSheetLayoutBuilder.Island]] {
        let threshold = scrapArea(family)
        return family.map { islands in islands.filter { abs(polyArea($0.loops[0])) >= threshold } }
    }

    /// Below this outline area (mm²) a piece of the family is scrap: 1% of
    /// its largest piece, and at least the smallest part worth cutting.
    private static func scrapArea(_ family: [[CutSheetLayoutBuilder.Island]]) -> Double {
        let largest = family.joined().map { abs(polyArea($0.loops[0])) }.max() ?? 0
        return max(largest * 0.01, CutSheetLayoutBuilder.minimumPartArea)
    }

    /// `island` with the joint `slots` cut out, as parts: every piece the
    /// cuts leave that holds one of the `kept` points (the middle of the
    /// material it keeps at one of this section's joints), and every other
    /// piece that is not scrap, marked as holding no joint. A slot cut
    /// through a piece where its crossing line runs through the model again
    /// further out (where the joint is) cuts it apart; each piece becomes a
    /// part of its own. An island the cuts take away whole comes back
    /// empty, unless it holds a `kept` point: then it comes back uncut and
    /// marked severed. Hairlines the cuts leave (material narrower than the
    /// 1 mm web beside a notch, past the last slot or at a tip) are cut
    /// away (`openedLoops`) when that leaves the piece in one piece with all
    /// the joint material it keeps, and a piece that is all hairline and
    /// keeps none is dropped as scrap; a hairline that is a neck between
    /// two parts of a piece, or that keeps a joint's material, stays, so
    /// no piece is cut loose from what holds it. A part narrower than `web`
    /// somewhere (`narrowerThan`) is marked `thin`. A piece holds a joint
    /// (`ModelPart.joined`) when it holds the middle of the stretch it
    /// keeps there (a `kept` point) or keeps any of that stretch (`holds`).
    private static func cutPieces(
        _ island: CutSheetLayoutBuilder.Island,
        slots: [[Vec2]],
        keeping kept: [Vec2],
        holds: [Hold],
        scrap: Double,
        web: Double,
        sliceIndex: Int,
        position: Double
    ) -> [ModelPart] {
        func materialHolds(_ loops: [[Vec2]], _ point: Vec2) -> Bool {
            guard let outline = loops.first, CutSheetLayoutBuilder.contains(outline, point: point) else { return false }
            return !loops.dropFirst().contains { CutSheetLayoutBuilder.contains($0, point: point) }
        }
        let pieces = CutSheetLayoutBuilder.slottedPieces(slots, from: island, keeping: kept, keepingEveryPiece: true)
            .flatMap { piece -> [CutSheetLayoutBuilder.Island] in
                guard let opened = openedLoops(piece.loops) else { return [piece] }
                let trimmed = CutSheetLayoutBuilder.islandize(paths: opened.map(closedPath))
                let held = kept.filter { materialHolds(piece.loops, $0) }
                if trimmed.isEmpty {
                    // All hairline: scrap, unless it keeps a joint's material.
                    return held.isEmpty && !holds.contains(where: { $0.held(by: piece.loops) }) ? [] : [piece]
                }
                guard trimmed.count == 1, held.allSatisfy({ materialHolds(trimmed[0].loops, $0) }) else { return [piece] }
                var cut = trimmed[0]
                cut.isError = piece.isError
                return [cut]
            }
        return pieces.compactMap { piece -> ModelPart? in
            guard let outline = piece.loops.first, outline.count >= 3 else { return nil }
            let holes = Array(piece.loops.dropFirst().filter { $0.count >= 3 })
            let holdsKeptPoint = kept.contains { point in
                CutSheetLayoutBuilder.contains(outline, point: point)
                    && !holes.contains { CutSheetLayoutBuilder.contains($0, point: point) }
            }
            let joined = holdsKeptPoint || holds.contains { $0.held(by: [outline] + holes) }
            // A piece that holds no joint's middle is scrap when small, even
            // if it grazes a joint's stretch.
            if !holdsKeptPoint {
                let extent = box(outline)
                let size = max(extent.max.x - extent.min.x, extent.max.y - extent.min.y)
                guard abs(polyArea(outline)) >= scrap, size >= CutSheetLayoutBuilder.minimumPartDimension else { return nil }
            }
            return ModelPart(
                sliceIndex: sliceIndex,
                position: position,
                loop: oriented(outline, counterClockwise: true),
                holes: holes.map { oriented($0, counterClockwise: false) },
                severed: piece.isError,
                joined: joined,
                thin: narrowerThan(web, [outline] + holes, keeping: kept)
            )
        }
    }

    /// Whether the material of `loops` (an outline, then its holes) is
    /// narrower than the stock where it matters: shrunk by just under half
    /// of `web` and grown back, it falls into several pieces (a neck between
    /// two parts of it, as `CurveJointPlanner.narrowerThan` finds) or into
    /// none (thin all over); or, shrunk by just under half the 1 mm web
    /// (`hairline`) and grown back, it falls apart, or loses the middle of
    /// the material it keeps at one of its joints (`kept`: a joint held by a
    /// hairline, which would snap).
    private static func narrowerThan(_ web: Double, _ loops: [[Vec2]], keeping kept: [Vec2]) -> Bool {
        guard let outline = loops.first, outline.count >= 3 else { return false }
        let rings = [oriented(outline, counterClockwise: true)]
            + loops.dropFirst().filter { $0.count >= 3 }.map { oriented($0, counterClockwise: false) }
        func pieces(_ region: [[Vec2]]) -> Int {
            region.filter { polyArea($0) > 0.5 }.count
        }
        guard let opened = PlanarBoolean.joining(rings, closingBy: 0, openingBy: web / 2 - 0.05) else { return false }
        if pieces(opened) != 1 { return true }
        guard let shaved = PlanarBoolean.joining(rings, closingBy: 0, openingBy: hairline) else { return false }
        if pieces(shaved) != 1 { return true }
        func inside(_ region: [[Vec2]], _ point: Vec2) -> Bool {
            var winding = 0
            for loop in region where CutSheetLayoutBuilder.contains(loop, point: point) {
                winding += polyArea(loop) > 0 ? 1 : -1
            }
            return winding > 0
        }
        return kept.contains { point in inside(rings, point) && !inside(shaved, point) }
    }

    /// One ring's or fin's parts, largest first, numbered as its pieces.
    private static func numbered(_ parts: [ModelPart]) -> [ModelPart] {
        parts
            .enumerated()
            .sorted { lhs, rhs in
                let lhsArea = abs(polyArea(lhs.element.loop))
                let rhsArea = abs(polyArea(rhs.element.loop))
                return abs(lhsArea - rhsArea) > 1.0e-9 ? lhsArea > rhsArea : lhs.offset < rhs.offset
            }
            .enumerated()
            .map { index, entry in
                var part = entry.element
                part.componentIndex = index
                return part
            }
    }

    // MARK: - Joints

    /// The joints between every ring piece and fin piece, and the notches,
    /// slots and relief they cut. A ring and a fin cross along one line
    /// (`crossing`); where their stock shares stretches of it, the joint sits
    /// in the outermost stretch, and the fin is slotted clean through every
    /// stretch inward of it.
    private static func planCuts(
        plan: RadialSlicePlan,
        model: MeshSummary,
        positions: [Double],
        angles: [Double],
        rings: [[CutSheetLayoutBuilder.Island]],
        fins: [[CutSheetLayoutBuilder.Island]]
    ) -> Cuts {
        var cuts = Cuts(
            ringSlots: Array(repeating: [], count: rings.count),
            finSlots: Array(repeating: [], count: fins.count),
            ringKept: Array(repeating: [], count: rings.count),
            finKept: Array(repeating: [], count: fins.count),
            ringHolds: Array(repeating: [], count: rings.count),
            finHolds: Array(repeating: [], count: fins.count),
            ringCrossed: rings.map { Array(repeating: false, count: $0.count) }
        )
        guard let primary = plan.primary, let bounds = model.bounds else { return cuts }
        let axis = primary.axis
        let center = boxCenter(bounds)
        let hub = projectedCenter(bounds: bounds, axis: axis)
        let width = plan.slotWidth
        let ringLoops = rings.map { $0.flatMap(\.loops) }
        let finLoops = fins.map { $0.flatMap(\.loops) }
        for ring in rings.indices where !ringLoops[ring].isEmpty {
            let ringFrame = PartPlaneFrame(axis: axis, position: positions[ring])
            for (fin, angle) in angles.enumerated() where !finLoops[fin].isEmpty {
                let line = crossing(hub: hub, center: center, axis: axis, position: positions[ring], angle: angle)
                // Where both parts' stock overlaps around the line: the beam,
                // the stock thickness square, sampled across.
                let beam = CurveJointPlanner.beamOffsets(
                    line: line,
                    primaryFrame: ringFrame,
                    curveFrame: wedgeFrame(center: center, axis: axis, angle: angle),
                    thickness: plan.materialThickness
                )
                let finSpans = beam.map { CurveJointPlanner.materialSpans(finLoops[fin], along: line.curve, offset: $0.curve) }
                func sharedSpans(_ loops: [[Vec2]]) -> [CurveJointPlanner.Span] {
                    CurveJointPlanner.merged(zip(beam, finSpans).flatMap { offset, spans in
                        CurveJointPlanner.overlaps(
                            CurveJointPlanner.materialSpans(loops, along: line.primary, offset: offset.primary),
                            spans
                        )
                    }).filter { $0.hi - $0.lo >= CurveJointPlanner.minimumSpan }
                }
                let shared = sharedSpans(ringLoops[ring])
                guard let inner = shared.first, let span = shared.last else { continue }
                for (index, island) in rings[ring].enumerated() where !cuts.ringCrossed[ring][index] {
                    cuts.ringCrossed[ring][index] = !sharedSpans(island.loops).isEmpty
                }
                let meet = CurveJointPlanner.meetingPoint(
                    of: span,
                    forwardGaps: CurveJointPlanner.gaps(ringLoops[ring], along: line.primary, width: width, within: span),
                    backwardGaps: CurveJointPlanner.gaps(finLoops[fin], along: line.curve, width: width, within: span)
                )
                // The ring is notched from the meeting point out through its
                // rim; the fin is slotted from its inner edge, through any
                // stretch inward of the joint, out to the meeting point.
                let ringMouth = CurveJointPlanner.mouth(
                    loops: ringLoops[ring], line: line.primary, width: width,
                    middle: meet, edge: span.hi, forward: true
                )
                let finMouth = CurveJointPlanner.mouth(
                    loops: finLoops[fin], line: line.curve, width: width,
                    middle: meet, edge: inner.lo, forward: false
                )
                cuts.ringSlots[ring].append(slot(line.primary, from: meet, to: max(meet, ringMouth), width: width))
                cuts.finSlots[fin].append(slot(line.curve, from: min(finMouth, meet), to: meet, width: width))
                if plan.cutsRelief {
                    cuts.ringSlots[ring] += reliefCuts(
                        line: line.primary, bottom: meet, opening: 1, width: width,
                        type: plan.reliefType, radius: plan.toolDiameter / 2
                    )
                    cuts.finSlots[fin] += reliefCuts(
                        line: line.curve, bottom: meet, opening: -1, width: width,
                        type: plan.reliefType, radius: plan.toolDiameter / 2
                    )
                }
                cuts.ringKept[ring].append(line.primary.point(at: (span.lo + meet) / 2))
                cuts.finKept[fin].append(line.curve.point(at: (meet + span.hi) / 2))
                cuts.ringHolds[ring].append(Hold(line: line.primary, lo: span.lo, hi: meet))
                cuts.finHolds[fin].append(Hold(line: line.curve, lo: meet, hi: span.hi))
                cuts.joints.append(Joint(
                    ringLayer: ring,
                    fin: fin,
                    origin: line.origin,
                    direction: line.direction,
                    start: span.lo,
                    end: span.hi,
                    meet: meet,
                    inner: inner.lo,
                    width: width
                ))
            }
        }
        return cuts
    }

    /// Relief at the two inside corners of a slot that runs along `line`
    /// from its bottom at `bottom` toward `opening` (+1: larger `u`), `width`
    /// wide: a circle of the tool's `radius` through each corner, so a round
    /// cutter clears the corner and the square edge of the part that seats
    /// there goes all the way in. Horizontal relief centres the circle on
    /// the bottom's line (it digs past the bottom), Vertical on the side's
    /// line (it digs into the side), Dog Bone on the corner's diagonal.
    static func reliefCuts(
        line: CurveJointPlanner.SectionLine,
        bottom: Double,
        opening: Double,
        width: Double,
        type: RadialReliefType,
        radius: Double
    ) -> [[Vec2]] {
        guard type.requiresToolDiameter, radius > 0 else { return [] }
        return [-1.0, 1.0].map { side in
            let corner = line.point(at: bottom, offset: side * width / 2)
            let center: Vec2
            switch type {
            case .square:
                center = corner
            case .horizontal:
                center = line.point(at: bottom, offset: side * (width / 2 - radius))
            case .vertical:
                center = line.point(at: bottom + opening * radius, offset: side * width / 2)
            case .dogBone:
                let step = radius / 2.squareRoot()
                center = line.point(at: bottom + opening * step, offset: side * (width / 2 - step))
            }
            // A vertex on the corner itself, so the cut reaches it exactly.
            let start = atan2(corner.y - center.y, corner.x - center.x)
            return (0..<reliefSegments).map { k in
                let angle = start + Double(k) * 2 * .pi / Double(reliefSegments)
                return Vec2(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }
    }

    /// Sides of the polygon a relief circle is cut as.
    private static let reliefSegments = 48

    /// The cut-sheet label of every ring and fin part, in `assembly` order:
    /// rings `Z-3` (the first axis's letter), `Z-3-2` when the ring has
    /// several pieces; fins `R-5`, and `R-5-2` for its further pieces.
    static func labels(_ assembly: Assembly, axisLetter: String) -> (disks: [String], wedges: [String]) {
        let pieces = Dictionary(grouping: assembly.disks, by: \.sliceIndex).mapValues(\.count)
        let disks = assembly.disks.map { disk in
            "\(axisLetter)-\(disk.sliceIndex + 1)" + ((pieces[disk.sliceIndex] ?? 0) > 1 ? "-\(disk.componentIndex + 1)" : "")
        }
        let wedges = assembly.wedges.map { wedge in
            "R-\(wedge.sliceIndex + 1)" + (wedge.componentIndex == 0 ? "" : "-\(wedge.componentIndex + 1)")
        }
        return (disks, wedges)
    }

    /// The labels of the parts that hold no joint (`ModelPart.joined`).
    static func unjoinedLabels(_ assembly: Assembly, axisLetter: String) -> [String] {
        let labels = Self.labels(assembly, axisLetter: axisLetter)
        return zip(assembly.disks, labels.disks).filter { !$0.0.joined }.map(\.1)
            + zip(assembly.wedges, labels.wedges).filter { !$0.0.joined }.map(\.1)
    }

    /// The labels of the parts narrower than the stock somewhere
    /// (`ModelPart.thin`).
    static func thinLabels(_ assembly: Assembly, axisLetter: String) -> [String] {
        let labels = Self.labels(assembly, axisLetter: axisLetter)
        return zip(assembly.disks, labels.disks).filter { $0.0.thin }.map(\.1)
            + zip(assembly.wedges, labels.wedges).filter { $0.0.thin }.map(\.1)
    }

    /// One entry per piece left out (`Assembly.uncrossedRings`,
    /// `cutAwayRings`, `cutAwayFins`): the label of its ring or fin.
    static func leftOutLabels(_ assembly: Assembly, axisLetter: String) -> [String] {
        (assembly.uncrossedRings + assembly.cutAwayRings).sorted().map { "\(axisLetter)-\($0 + 1)" }
            + assembly.cutAwayFins.map { "R-\($0 + 1)" }
    }

    /// What the cut sheet, the app and the CLI say about how the parts hold
    /// together: pieces left out, parts no joint locks in (shown blue), and
    /// parts narrower than the stock in places.
    static func notes(_ assembly: Assembly, axisLetter: String) -> [String] {
        var notes: [String] = []
        // A ring or fin left out whole is named; otherwise its pieces are
        // counted.
        func named(_ entries: [Int], prefix: String, kept: [ModelPart]) -> [String] {
            Set(entries).sorted().map { index in
                let count = entries.filter { $0 == index }.count
                let label = "\(prefix)-\(index + 1)"
                if !kept.contains(where: { $0.sliceIndex == index }) {
                    return label
                }
                return count == 1 ? "a piece of \(label)" : "\(count) pieces of \(label)"
            }
        }
        func sentence(_ names: [String], one: String, many: String) -> String? {
            guard !names.isEmpty else { return nil }
            let joined = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            let list = joined.prefix(1).uppercased() + joined.dropFirst()
            let single = names.count == 1 && !names[0].first!.isNumber
            return "\(list) \(single ? one : many)"
        }
        if let note = sentence(
            named(assembly.uncrossedRings, prefix: axisLetter, kept: assembly.disks),
            one: "crosses no fin and is left out: nothing would hold it in place.",
            many: "cross no fin and are left out: nothing would hold them in place."
        ) {
            notes.append(note)
        }
        if let note = sentence(
            named(assembly.cutAwayRings, prefix: axisLetter, kept: assembly.disks)
                + named(assembly.cutAwayFins, prefix: "R", kept: assembly.wedges),
            one: "is left out: the notches and slots would cut it away, or leave only scraps of it.",
            many: "are left out: the notches and slots would cut them away, or leave only scraps of them."
        ) {
            notes.append(note)
        }
        let unjoined = unjoinedLabels(assembly, axisLetter: axisLetter)
        if !unjoined.isEmpty {
            notes.append(unjoinedNote(labels: unjoined))
        }
        let thin = thinLabels(assembly, axisLetter: axisLetter)
        if !thin.isEmpty {
            let shown = thin.prefix(6).joined(separator: ", ") + (thin.count > 6 ? ", …" : "")
            let (parts, verb) = thin.count == 1 ? ("Part \(thin[0]) is", "it") : ("Parts \(shown) are", "them")
            notes.append("\(parts) narrower than the stock in places, where a notch or slot comes close to an edge "
                + "or the model is that thin: handle \(verb) with care, or use thinner stock.")
        }
        return notes
    }

    /// What the app and the CLI say when some parts hold no joint with the
    /// other family (`ModelPart.joined`), given their cut-sheet labels.
    static func unjoinedNote(labels: [String]) -> String {
        let (count, them) = labels.count == 1 ? ("1 part is", "it") : ("\(labels.count) parts are", "them")
        let shown = labels.prefix(6).joined(separator: ", ") + (labels.count > 6 ? ", …" : "")
        return "\(count) not locked to any ring or fin (\(shown)) and shown blue on the cut sheet: glue \(them) in place. "
            + "A fin locks into a ring only where their crossing line last runs through the model; nearer the hub it is slotted clean through."
    }

    /// The line the ring at `position` and the fin at `angle` share: out from
    /// the hub axis in the fin's direction. In the ring's section it starts at
    /// the hub and runs in the fin's direction; in the fin's section it runs
    /// along x at the ring's position. The same `u`, the distance from the hub
    /// axis, names the same model point in both. Rings and fins cross at
    /// right angles.
    private static func crossing(
        hub: Vec2,
        center: Vec3,
        axis: SliceAxis,
        position: Double,
        angle: Double
    ) -> CurveJointPlanner.Crossing {
        var origin = center
        switch axis {
        case .x: origin.x = position
        case .y: origin.y = position
        case .z: origin.z = position
        }
        return CurveJointPlanner.Crossing(
            primary: CurveJointPlanner.SectionLine(origin: hub, direction: Vec2(x: cos(angle), y: sin(angle))),
            curve: CurveJointPlanner.SectionLine(origin: Vec2(x: 0, y: position), direction: Vec2(x: 1, y: 0)),
            origin: origin,
            direction: radialFrame(axis: axis, angle: angle).radial,
            sine: 1
        )
    }

    /// A closed slot rectangle along `line` from `lo` to `hi`, `width` wide.
    private static func slot(_ line: CurveJointPlanner.SectionLine, from lo: Double, to hi: Double, width: Double) -> [Vec2] {
        Array(CurveJointPlanner.rectangle(line, from: lo, to: hi, width: width).points.dropLast())
    }

    /// Where a ring at `position` along `axis` has its section coordinates in
    /// the model.
    static func diskFrame(axis: SliceAxis, position: Double) -> PartPlaneFrame {
        PartPlaneFrame(axis: axis, position: position)
    }

    /// Where the fin at `angle` has its section coordinates in the model: x
    /// out from the hub axis through `center`, y along `axis`.
    static func wedgeFrame(center: Vec3, axis: SliceAxis, angle: Double) -> PartPlaneFrame {
        PartPlaneFrame(
            origin: wedgeScenePoint(Vec2(x: 0, y: 0), center: center, axis: axis, angle: angle),
            xAxis: radialFrame(axis: axis, angle: angle).radial,
            yAxis: axisVector(axis)
        )
    }

    /// The centre of the model's bounding box, through which the hub axis
    /// runs.
    static func boxCenter(_ bounds: Bounds3D) -> Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }

    /// Map a wedge `ModelPart` point (radial distance, absolute axis
    /// coordinate) into the 3D scene for the wedge fanned to `angle` about the
    /// hub axis through `center`.
    static func wedgeScenePoint(_ point: Vec2, center: Vec3, axis: SliceAxis, angle: Double) -> Vec3 {
        let radial = radialFrame(axis: axis, angle: angle).radial
        var scene = Vec3(
            x: center.x + radial.x * point.x,
            y: center.y + radial.y * point.x,
            z: center.z + radial.z * point.x
        )
        switch axis {
        case .x: scene.x = point.y
        case .y: scene.y = point.y
        case .z: scene.z = point.y
        }
        return scene
    }

    /// Extrusion normal of the wedge plane at `angle` about `axis`.
    static func wedgePlaneNormal(axis: SliceAxis, angle: Double) -> Vec3 {
        radialFrame(axis: axis, angle: angle).normal
    }

    /// Whether the viewport can extrude a ring piece with these loops.
    private static func canRenderDisk(
        _ loops: [[Vec2]],
        axis: SliceAxis,
        position: Double,
        materialThickness: Double
    ) -> Bool {
        guard let outline = loops.first, outline.count >= 3 else { return false }
        return ViewportSliceSolidRenderData.mesh(
            paths: loops.compactMap { points in
                guard let first = points.first, points.count >= 3 else { return nil }
                return SlicePath2D(points: points + [first], closed: true)
            },
            materialThickness: materialThickness,
            scenePoint: { liftDiskPoint($0, axis: axis, depth: position) },
            normal: axisVector(axis)
        ) != nil
    }

    private static func box(_ loop: [Vec2]) -> (min: Vec2, max: Vec2) {
        let xs = loop.map(\.x)
        let ys = loop.map(\.y)
        return (Vec2(x: xs.min() ?? 0, y: ys.min() ?? 0), Vec2(x: xs.max() ?? 0, y: ys.max() ?? 0))
    }

    private static func liftDiskPoint(_ point: Vec2, axis: SliceAxis, depth: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: depth, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: depth, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: depth)
        }
    }

    private static func projectedCenter(bounds: Bounds3D, axis: SliceAxis) -> Vec2 {
        let cx = (bounds.min.x + bounds.max.x) / 2
        let cy = (bounds.min.y + bounds.max.y) / 2
        let cz = (bounds.min.z + bounds.max.z) / 2
        switch axis {
        case .x:
            return Vec2(x: cy, y: cz)
        case .y:
            return Vec2(x: cx, y: cz)
        case .z:
            return Vec2(x: cx, y: cy)
        }
    }

    // MARK: - Radial cross-section (self-contained, robust)

    /// Recover the actual radial plane-section polygon set and clip it to the
    /// kept radial side (`x >= hubInset`) without joining disconnected
    /// components. Each loop is clipped on its own: a single Sutherland-Hodgman
    /// half-plane clip can turn disconnected clipped regions into one
    /// artificial bridge along the clip line, which is the floating-fin failure
    /// mode on organic scans.
    ///
    /// The loops come back with the model's material on their left
    /// (`materialOnLeft`): outer boundaries counter-clockwise, holes
    /// clockwise.
    private static func radialSectionPolygons(
        triangles: [(Vec3, Vec3, Vec3)],
        center: Vec3,
        axis: SliceAxis = .z,
        angle: Double,
        hubInset: Double = 0,
        winding: MeshWinding
    ) -> [[Vec2]] {
        let frame = radialFrame(axis: axis, angle: angle)
        var segments: [(Vec2, Vec2)] = []
        var edges: [SectionEdge] = []
        for (index, tri) in triangles.enumerated() {
            if let seg = intersectTriangle(tri, center: center, frame: frame) {
                segments.append(seg)
                let normal = triangleNormal(tri)
                edges.append(SectionEdge(
                    a: seg.0,
                    b: seg.1,
                    outward: Vec2(x: dot(normal, frame.radial), y: coordinate(normal, axis: frame.axis)),
                    triangle: index
                ))
            }
        }
        let loops = materialOnLeft(
            chainLoops(segments).filter { $0.count >= 3 && abs(polyArea($0)) > 1.0e-7 },
            edges: edges,
            winding: winding
        )
        guard !loops.isEmpty else { return [] }

        var clipped: [[Vec2]] = []
        for loop in loops {
            let outer = polyArea(loop) > 0
            let pieces = clipRadialAtLeastComponents(Polygon2D.normalizedCCW(loop), line: hubInset)
            for piece in pieces {
                let cleaned = StackedSliceContourer.sanitizeClosedLoop(piece)
                guard cleaned.count >= 3, abs(polyArea(cleaned)) > 1.0e-6 else { continue }
                clipped.append(oriented(Polygon2D.normalizedCCW(cleaned), counterClockwise: outer))
            }
        }
        return clipped.sorted { lhs, rhs in
            let lhsArea = abs(polyArea(lhs))
            let rhsArea = abs(polyArea(rhs))
            if abs(lhsArea - rhsArea) > 1.0e-7 { return lhsArea > rhsArea }
            let lhsMinY = lhs.map(\.y).min() ?? 0
            let rhsMinY = rhs.map(\.y).min() ?? 0
            if abs(lhsMinY - rhsMinY) > 1.0e-7 { return lhsMinY < rhsMinY }
            return (lhs.map(\.x).min() ?? 0) < (rhs.map(\.x).min() ?? 0)
        }
    }

    /// Plane intersection of one triangle with the radial plane passing through
    /// `center`; returns the crossing segment projected to (radial, axis), or
    /// nil if the triangle does not cross in exactly two edges.
    private static func intersectTriangle(
        _ tri: (Vec3, Vec3, Vec3),
        center: Vec3,
        frame: RadialFrame
    ) -> (Vec2, Vec2)? {
        let eps = 1.0e-7
        func dist(_ p: Vec3) -> Double { dot(subtract(p, center), frame.normal) }
        func proj(_ p: Vec3) -> Vec2 {
            let delta = subtract(p, center)
            return Vec2(x: dot(delta, frame.radial), y: coordinate(p, axis: frame.axis))
        }
        var pts: [Vec2] = []
        let verts = [tri.0, tri.1, tri.2]
        for i in 0..<3 {
            let a = verts[i], b = verts[(i + 1) % 3]
            let da = dist(a), db = dist(b)
            if abs(da) <= eps && abs(db) <= eps { continue }     // edge in-plane: skip
            if abs(da) <= eps { appendUnique(proj(a), &pts); continue }
            if abs(db) <= eps { appendUnique(proj(b), &pts); continue }
            if (da < 0 && db > 0) || (da > 0 && db < 0) {
                let t = da / (da - db)
                let p = Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
                appendUnique(proj(p), &pts)
            }
        }
        guard pts.count == 2 else { return nil }
        return (pts[0], pts[1])
    }

    private struct RadialFrame {
        var axis: SliceAxis
        var radial: Vec3
        var normal: Vec3
    }

    private static func radialFrame(axis: SliceAxis, angle: Double) -> RadialFrame {
        let basis = perpendicularBasis(axis: axis)
        let c = cos(angle)
        let s = sin(angle)
        let radial = Vec3(
            x: basis.u.x * c + basis.v.x * s,
            y: basis.u.y * c + basis.v.y * s,
            z: basis.u.z * c + basis.v.z * s
        )
        return RadialFrame(axis: axis, radial: radial, normal: cross(radial, axisVector(axis)))
    }

    private static func perpendicularBasis(axis: SliceAxis) -> (u: Vec3, v: Vec3) {
        switch axis {
        case .x:
            return (Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1))
        case .y:
            return (Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 0, z: 1))
        case .z:
            return (Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0))
        }
    }

    private static func axisVector(_ axis: SliceAxis) -> Vec3 {
        switch axis {
        case .x: return Vec3(x: 1, y: 0, z: 0)
        case .y: return Vec3(x: 0, y: 1, z: 0)
        case .z: return Vec3(x: 0, y: 0, z: 1)
        }
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func coordinate(_ point: Vec3, axis: SliceAxis) -> Double {
        switch axis {
        case .x: return point.x
        case .y: return point.y
        case .z: return point.z
        }
    }

    private static func appendUnique(_ p: Vec2, _ pts: inout [Vec2]) {
        if !pts.contains(where: { abs($0.x - p.x) <= 1e-7 && abs($0.y - p.y) <= 1e-7 }) {
            pts.append(p)
        }
    }

    private static func chainLoops(_ rawSegments: [(Vec2, Vec2)]) -> [[Vec2]] {
        let eps = 1.0e-6
        func close(_ a: Vec2, _ b: Vec2) -> Bool { abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps }

        // De-duplicate undirected edges: a watertight mesh emits each crossing
        // edge from both incident triangles (forward + reverse), so the raw
        // list has ~2× duplicates that would otherwise fold the chain back on
        // itself. Keep one copy of each undirected segment, dropping degenerate
        // zero-length ones.
        var segments: [(Vec2, Vec2)] = []
        for s in rawSegments {
            if close(s.0, s.1) { continue }
            let dup = segments.contains { e in
                (close(e.0, s.0) && close(e.1, s.1)) || (close(e.0, s.1) && close(e.1, s.0))
            }
            if !dup { segments.append(s) }
        }

        var used = Array(repeating: false, count: segments.count)
        var loops: [(area: Double, minY: Double, minX: Double, points: [Vec2])] = []
        for start in segments.indices where !used[start] {
            used[start] = true
            var loop: [Vec2] = [segments[start].0, segments[start].1]
            var extended = true
            while extended {
                extended = false
                guard let last = loop.last, let first = loop.first else { break }
                if loop.count >= 3 && close(last, first) { break }
                for i in segments.indices where !used[i] {
                    let (a, b) = segments[i]
                    if close(last, a) { loop.append(b); used[i] = true; extended = true; break }
                    if close(last, b) { loop.append(a); used[i] = true; extended = true; break }
                    if close(first, a) { loop.insert(b, at: 0); used[i] = true; extended = true; break }
                    if close(first, b) { loop.insert(a, at: 0); used[i] = true; extended = true; break }
                }
            }
            if loop.count >= 4, let f = loop.first, let l = loop.last, close(f, l) {
                loop.removeLast()
            }
            let area = abs(polyArea(loop))
            guard area > 1.0e-9 else { continue }
            let xs = loop.map(\.x)
            let ys = loop.map(\.y)
            loops.append((
                area: area,
                minY: ys.min() ?? 0,
                minX: xs.min() ?? 0,
                points: loop
            ))
        }
        return loops.sorted { lhs, rhs in
            if abs(lhs.area - rhs.area) > 1.0e-7 { return lhs.area > rhs.area }
            if abs(lhs.minY - rhs.minY) > 1.0e-7 { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }.map(\.points)
    }

    /// Flatten the mesh's index buffer into triangle vertex triples.
    private static func meshTriangles(_ model: MeshSummary) -> [(Vec3, Vec3, Vec3)] {
        let verts = model.geometry.vertices
        let idx = model.geometry.triangleIndices
        var tris: [(Vec3, Vec3, Vec3)] = []
        tris.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if verts.indices.contains(a), verts.indices.contains(b), verts.indices.contains(c) {
                tris.append((verts[a], verts[b], verts[c]))
            }
            i += 3
        }
        return tris
    }

    private static func clipRadialAtLeastComponents(_ poly: [Vec2], line: Double) -> [[Vec2]] {
        guard poly.count >= 3 else { return [] }
        let eps = 1.0e-7
        func close(_ a: Vec2, _ b: Vec2) -> Bool {
            abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
        }
        func inside(_ point: Vec2) -> Bool {
            point.x >= line - eps
        }
        func addSegment(_ a: Vec2, _ b: Vec2, to segments: inout [(Vec2, Vec2)]) {
            guard !close(a, b) else { return }
            segments.append((a, b))
        }
        func addLinePoint(_ point: Vec2, to points: inout [Vec2]) {
            let snapped = Vec2(x: line, y: point.y)
            if !points.contains(where: { close($0, snapped) }) {
                points.append(snapped)
            }
        }

        var segments: [(Vec2, Vec2)] = []
        var linePoints: [Vec2] = []
        for index in 0..<poly.count {
            let current = poly[index]
            let next = poly[(index + 1) % poly.count]
            let currentIn = inside(current)
            let nextIn = inside(next)
            switch (currentIn, nextIn) {
            case (true, true):
                addSegment(current, next, to: &segments)
            case (true, false):
                let hit = intersectXLine(current, next, line: line)
                addSegment(current, hit, to: &segments)
                addLinePoint(hit, to: &linePoints)
            case (false, true):
                let hit = intersectXLine(current, next, line: line)
                addSegment(hit, next, to: &segments)
                addLinePoint(hit, to: &linePoints)
            case (false, false):
                break
            }
        }

        linePoints.sort { lhs, rhs in
            if abs(lhs.y - rhs.y) > eps { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
        if linePoints.count >= 2 {
            var index = 0
            while index + 1 < linePoints.count {
                addSegment(linePoints[index], linePoints[index + 1], to: &segments)
                index += 2
            }
        }
        return chainLoops(segments)
            .map(Polygon2D.normalizedCCW)
            .filter { $0.count >= 3 && abs(polyArea($0)) > 1.0e-6 }
    }

    private static func intersectXLine(_ a: Vec2, _ b: Vec2, line: Double) -> Vec2 {
        let dx = b.x - a.x
        guard abs(dx) > 1e-12 else { return Vec2(x: line, y: a.y) }
        let t = (line - a.x) / dx
        return Vec2(x: line, y: a.y + (b.y - a.y) * t)
    }

    // MARK: - Hub and fin angles

    /// How far from the hub axis every fin starts (model mm).
    ///
    /// The fins fan out from the hub axis `2π/n` apart, each a slab of stock
    /// `t` thick centred on its plane. Two neighbouring slabs overlap from the
    /// axis out to where the inner corners of their faces meet,
    /// `(t/2)·cot(π/n)` along each fin, so fins that start there just clear
    /// their neighbours (fins farther apart clear each other sooner). One fin
    /// has no neighbour, and two lie in one plane either side of the axis:
    /// those run to the axis. The rings span the hub, so nothing is lost there.
    static func hubInset(plan: RadialSlicePlan) -> Double {
        let count = wedgeCount(plan: plan)
        guard count >= 3, plan.materialThickness.isFinite, plan.materialThickness > 0 else { return 0 }
        return plan.materialThickness / 2 / tan(.pi / Double(count))
    }

    /// Number of radial fins: `n_radial`, except that a request for 8 is
    /// treated as the 10-fin default (`interlockedDefaultFamilyCount`). Each
    /// ring gets one notch per fin that crosses it.
    ///
    /// For a (near-)rotationally symmetric model the 2k angular cuts produce
    /// only k geometrically distinct silhouettes (a plane and its antipode
    /// share the same circle); the full `wedgeCount` fins are still emitted,
    /// one per 360/count step.
    static func wedgeCount(plan: RadialSlicePlan) -> Int {
        if plan.nRadial == 8 {
            return StackedSlicePlanner.interlockedDefaultFamilyCount
        }
        return max(1, plan.nRadial)
    }

    /// The wedge angular positions (radians), evenly spaced about the hub axis.
    static func wedgeAngles(plan: RadialSlicePlan) -> [Double] {
        let count = wedgeCount(plan: plan)
        guard count > 0 else { return [] }
        return (0..<count).map { Double($0) * 2.0 * .pi / Double(count) }
    }

    // MARK: - Small geometry helpers

    private static func closedPath(_ loop: [Vec2]) -> SlicePath2D {
        SlicePath2D(points: loop + (loop.first.map { [$0] } ?? []), closed: true)
    }

    private static func oriented(_ loop: [Vec2], counterClockwise: Bool) -> [Vec2] {
        (polyArea(loop) >= 0) == counterClockwise ? loop : Array(loop.reversed())
    }

    private static func polyArea(_ pts: [Vec2]) -> Double {
        var area = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }
}
