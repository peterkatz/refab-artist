import Foundation
import Testing
@testable import RefabArtist

/// Where Curve Slices ribs stand and stop, how many fit, and the sections
/// they are cut from: crowded slots keep a stock-thick web, a rib on a
/// spline that bends both ways is never cut short on both sides with first
/// axis Z, hollow and concave models joint cleanly, and sections through a
/// cracked or open mesh come out closed.
struct CurveRibLayoutTests {
    // MARK: - Counts

    @Test
    func firstAxisRibsAreAsManyAsLeaveAStockThickWebInTheCurveRibs() throws {
        let model = try Self.fixture("tests/fixtures/primitives/sphere_d50mm.stl")
        // 3 mm: seven first-axis ribs 7.1 mm apart leave a 4.1 mm web.
        let thin = try #require(Self.plan(model: model, axis: .z, thickness: 3))
        #expect(thin.primarySliceCount == 7)
        #expect(thin.requestedFirstAxisCount == nil)
        #expect(thin.firstAxisCountNote == nil)
        // 5 mm: seven would leave 2.1 mm; five, 10 mm apart, leave 5 mm.
        let thick = try #require(Self.plan(model: model, axis: .z, thickness: 5))
        #expect(thick.primarySliceCount == 5)
        #expect(thick.requestedFirstAxisCount == 7)
        #expect(thick.firstAxisCountNote == "Only 5 first-axis slices fit across this model in 5 mm stock (7 asked for); "
            + "more would leave the curve slices too thin between their slots. Use thinner stock for more.")
        #expect(thick.curveCountNote == "Only 5 curve slices fit along this curve in 5 mm stock (12 asked for); "
            + "more would stand too close together for strong joints. Use thinner stock or a longer curve for more.")
    }

    @Test
    func withFirstAxisXTheSplineRunsAcrossTheXRibs() throws {
        let model = try Self.fixture("tests/fixtures/primitives/sphere_d50mm.stl")
        let plan = try #require(Self.plan(model: model, axis: .x, thickness: 3))
        // Along Y from +y to -y, bowed toward +x.
        #expect(plan.controlPoints == [Vec2(x: 0, y: 25), Vec2(x: 10, y: 0), Vec2(x: 0, y: -25)])
        // Every curve rib crosses the X ribs less than 30 degrees off square.
        #expect(plan.normals.allSatisfy { abs($0.x) > 0.866 })
    }

    // MARK: - Crowded slots

    @Test(arguments: [(SliceAxis.y, 3.0), (.y, 5.0), (.x, 3.0), (.z, 3.0), (.z, 5.0)])
    func curveRibSlotsInAFirstAxisRibKeepAStockThickWeb(axis: SliceAxis, thickness: Double) throws {
        let model = try Self.fixture("tests/fixtures/primitives/sphere_d50mm.stl")
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: thickness))
        let primary = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let slots = CurveJointPlanner.slots(plan: plan, primary: primary, curve: CurveSliceContourer.generate(model: model, plan: plan))
        var pairs = 0
        for (layer, rectangles) in zip(primary.layers, slots.primary) {
            let loops = CurveJointPlanner.closedLoops(layer.paths)
            // Only the part of each slot inside the rib's material counts.
            let inside = rectangles.map(\.points).filter { rectangle in
                rectangle.contains { point in loops.filter { CutSheetLayoutBuilder.contains($0, point: point) }.count % 2 == 1 }
            }
            for (i, a) in inside.enumerated() {
                for b in inside[(i + 1)...] {
                    pairs += 1
                    #expect(Self.distance(a, b) >= thickness - 0.05, "\(axis) \(thickness) mm at \(layer.position)")
                }
            }
        }
        #expect(pairs > 0)
    }

    // MARK: - A spline that bends both ways

    @Test(arguments: [3.0, 5.0])
    func onAnSCurveNoRibIsCutShortOnBothSidesAndNoSlotIsLeftEmpty(thickness: Double) throws {
        let model = try Self.fixture("tests/fixtures/primitives/sphere_d50mm.stl")
        let spline = [Vec2(x: -25, y: 0), Vec2(x: -12.5, y: 10), Vec2(x: 0, y: 0), Vec2(x: 12.5, y: -10), Vec2(x: 25, y: 0)]
        let plan = try #require(CurveSlicePlanner.plan(
            model: model, primaryAxis: .z, materialThickness: thickness, firstAxisCount: 7,
            curveSliceCount: 12, splineControlPoints: spline, slotWidth: thickness, slotAngleDegrees: 0
        ))
        let layout = CurveJointPlanner.ribLayout(plan: plan)
        #expect(layout.standsClear)
        #expect(plan.sliceCount >= 2)
        for reach in layout.reach {
            #expect(reach.lo == -.infinity || reach.hi == .infinity)
        }
        // Along every joint line, wherever it runs through the model, exactly
        // one of the two ribs holds it: no slot is left empty.
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let primary = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let joints = CurveJointPlanner.slots(plan: plan, primary: primary, curve: CurveSliceContourer.generate(model: model, plan: plan)).joints
        #expect(!joints.isEmpty)
        var checked = 0
        for joint in joints {
            // The top and bottom first-axis ribs only graze the curve ribs'
            // stock, keep no joint and are left out.
            guard let first = document.part(labeled: "Z-\(joint.primaryLayer + 1)"),
                  let curve = document.part(labeled: "C-\(joint.curveLayer + 1)") else { continue }
            checked += 1
            let length = Self.distance(joint.start, joint.end)
            for step in 1..<20 {
                let point = Self.lerp(joint.start, joint.end, Double(step) / 20)
                guard (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot() < 24.5,
                      abs(Self.distance(joint.start, point) - Self.distance(joint.start, joint.meet)) > 0.05 else { continue }
                #expect(Self.holds(first, point) != Self.holds(curve, point),
                        "\(first.label)/\(curve.label) at \(Self.distance(joint.start, point)) of \(length)")
            }
        }
        #expect(checked > 0)
    }

    // MARK: - Hollow and concave models

    @Test(arguments: [SliceAxis.z, .y])
    func aHollowBoxJointsEveryWallWithoutLeavingASlotEmpty(axis: SliceAxis) throws {
        let model = try Self.fixture("tests/fixtures/stress/hollow_box_50mm.stl")
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: 3))
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let parts = document.sheets.flatMap(\.parts)
        #expect(parts.allSatisfy { !$0.isError })
        let primary = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let joints = CurveJointPlanner.slots(plan: plan, primary: primary, curve: CurveSliceContourer.generate(model: model, plan: plan)).joints
        #expect(!joints.isEmpty)
        let letter = CutSheetLayoutBuilder.axisLetter(axis)
        func pieces(_ prefix: String) -> [CutSheetPart] {
            parts.filter { $0.label == prefix || $0.label.hasPrefix(prefix + "-") }
        }
        for joint in joints {
            let firsts = pieces("\(letter)-\(joint.primaryLayer + 1)")
            let curves = pieces("C-\(joint.curveLayer + 1)")
            let meetAt = Self.distance(joint.start, joint.meet)
            for step in 1..<20 {
                let point = Self.lerp(joint.start, joint.end, Double(step) / 20)
                let along = Self.distance(joint.start, point)
                guard abs(along - meetAt) > 0.05, Self.insideHollowBox(point) else { continue }
                let first = firsts.contains { Self.holds($0, point) }
                let curve = curves.contains { Self.holds($0, point) }
                #expect(first == (along < meetAt), "\(letter)-\(joint.primaryLayer + 1) at \(point)")
                #expect(curve == (along > meetAt), "C-\(joint.curveLayer + 1) at \(point)")
            }
        }
    }

    @Test
    func aSlotThroughARingKeepsBothHalvesThatHoldJoints() {
        // A 10 x 10 ring with a 6 x 6 hole: two slots across opposite walls
        // cut it in two; each half holds joint material and stays a part.
        let outer = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 10, y: 10), Vec2(x: 0, y: 10)]
        let hole = [Vec2(x: 2, y: 2), Vec2(x: 2, y: 8), Vec2(x: 8, y: 8), Vec2(x: 8, y: 2)]
        let island = CutSheetLayoutBuilder.Island(loops: [outer, hole], openPaths: [])
        let left = [Vec2(x: -1, y: 4), Vec2(x: 3, y: 4), Vec2(x: 3, y: 6), Vec2(x: -1, y: 6)]
        let right = [Vec2(x: 7, y: 4), Vec2(x: 11, y: 4), Vec2(x: 11, y: 6), Vec2(x: 7, y: 6)]
        let halves = CutSheetLayoutBuilder.slottedPieces([left, right], from: island, keeping: [Vec2(x: 5, y: 1), Vec2(x: 5, y: 9)])
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { !$0.isError && $0.loops.count == 1 })
        // Without joint material in it, any piece but the largest is scrap.
        #expect(CutSheetLayoutBuilder.slottedPieces([left, right], from: island).count == 1)
    }

    @Test
    func theMeetingPointKeepsBothSlotsClearOfAHoleTheyRunPast() {
        // A rib with a hole whose edge crosses the slot at a slant: the lines
        // across the slot meet the hole's far edge up to u = 3.75. The slot
        // running toward larger u must start 1 mm past that, not in the
        // middle of the span.
        let outer = [Vec2(x: -10, y: -5), Vec2(x: 10, y: -5), Vec2(x: 10, y: 5), Vec2(x: -10, y: 5)]
        let hole = [Vec2(x: -6, y: -1), Vec2(x: 2, y: -1), Vec2(x: 4, y: 1), Vec2(x: -6, y: 1)]
        let line = CurveJointPlanner.SectionLine(origin: Vec2(x: 0, y: 0), direction: Vec2(x: 1, y: 0))
        let ribWithHole = CurveJointPlanner.RunSide(loops: [outer, hole], line: line)
        let plain = CurveJointPlanner.RunSide(loops: [outer], line: line)
        let span = CurveJointPlanner.Span(lo: -10, hi: 10)
        #expect(CurveJointPlanner.meetingPoint(of: span, forward: plain, backward: plain, width: 2) == 0)
        let meet = CurveJointPlanner.meetingPoint(of: span, forward: ribWithHole, backward: plain, width: 2)
        #expect(abs(meet - 4.75) < 1.0e-9)
        // The rib slotted toward smaller u stops 1 mm short of the hole.
        let back = CurveJointPlanner.meetingPoint(
            of: CurveJointPlanner.Span(lo: -10, hi: 10), forward: plain,
            backward: CurveJointPlanner.RunSide(loops: [outer, hole], line: line), width: 2
        )
        #expect(abs(back - -7) < 1.0e-9)
    }

    // MARK: - Webs

    @Test
    func aSlotBottomKeepsAStockThickWebFromAHoleBelowIt() {
        // Both ribs are a 20 x 50 mm frame round a 16 x 30 mm hollow: on the
        // crossing line (x = 0) each has material from 0 to 10 and from 40 to
        // 50. Both slots cannot stay clear of their holes, so the first-axis
        // rib's slot (toward larger u) does, and stops a stock thickness
        // above the hollow's top wall's underside.
        let frame = [[Vec2(x: -10, y: 0), Vec2(x: 10, y: 0), Vec2(x: 10, y: 50), Vec2(x: -10, y: 50)],
                     [Vec2(x: -8, y: 10), Vec2(x: -8, y: 40), Vec2(x: 8, y: 40), Vec2(x: 8, y: 10)]]
        let line = CurveJointPlanner.SectionLine(origin: Vec2(x: 0, y: 0), direction: Vec2(x: 0, y: 1))
        let side = CurveJointPlanner.RunSide(loops: frame, line: line)
        let span = CurveJointPlanner.Span(lo: 0, hi: 50)
        let thick = CurveJointPlanner.meetingPoint(of: span, forward: side, backward: side, width: 3, web: 3)
        #expect(abs(thick - 43) < 1.0e-9)
        // In 1 mm stock the web is 1 mm.
        let thin = CurveJointPlanner.meetingPoint(of: span, forward: side, backward: side, width: 1, web: 1)
        #expect(abs(thin - 41) < 1.0e-9)
    }

    @Test
    func aSlotStopsShortOfAStripBesideItThinnerThanTheStock() {
        // An L: a 20 mm seat along the bottom and an 18 mm post up its left
        // side. The crossing line runs up the post 3 mm from its inner face,
        // so a 5 mm slot up the post would leave a 0.5 mm strip beside it:
        // the slot from the bottom stops at the seat's top, less 1 mm, and
        // the other rib's slot comes down to meet it there.
        let seatAndPost = [[Vec2(x: 0, y: 0), Vec2(x: 200, y: 0), Vec2(x: 200, y: 20), Vec2(x: 18, y: 20),
                            Vec2(x: 18, y: 170), Vec2(x: 0, y: 170)]]
        let post = [[Vec2(x: 0, y: 0), Vec2(x: 30, y: 0), Vec2(x: 30, y: 170), Vec2(x: 0, y: 170)]]
        let line = CurveJointPlanner.SectionLine(origin: Vec2(x: 15, y: 0), direction: Vec2(x: 0, y: 1))
        let strips = CurveJointPlanner.thinStrips(CurveJointPlanner.RunSide(loops: seatAndPost, line: line), width: 5, web: 5)
        #expect(strips.count == 1 && abs(strips[0].lo - 20) < 1.0e-9 && abs(strips[0].hi - 170) < 1.0e-9)
        let meet = CurveJointPlanner.meetingPoint(
            of: CurveJointPlanner.Span(lo: 0, hi: 170),
            forward: CurveJointPlanner.RunSide(loops: post, line: line),
            backward: CurveJointPlanner.RunSide(loops: seatAndPost, line: line),
            width: 5,
            web: 5
        )
        #expect(abs(meet - 19) < 1.0e-9)
    }

    @Test
    func curvePartsHaveNoNeckThinnerThanTheStock() throws {
        // The simple chair with first axis Y in 5 mm stock (its back post is
        // slotted up beside a seat it once hung from by a 3 mm strip) and the
        // hollow box with first axis Y in 3 mm (whose first-axis ribs' slots
        // once stopped 1 mm under the hollow): shrunk by half the stock and
        // grown back, no part falls into more pieces.
        let cases: [(String, Double, (CutSheetPart) -> Bool)] = [
            ("tests/fixtures/real-world/simple_chair.stl", 5, { _ in true }),
            ("tests/fixtures/stress/hollow_box_50mm.stl", 3, { $0.label.hasPrefix("Y-") })
        ]
        for (path, thickness, checked) in cases {
            let model = try Self.fixture(path)
            let plan = try #require(Self.plan(model: model, axis: .y, thickness: thickness))
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            for part in document.sheets.flatMap(\.parts) where checked(part) {
                let rings = part.cutLoops.enumerated().map { index, loop -> [Vec2] in
                    let depth = part.cutLoops.indices.filter { other in
                        other != index && CutSheetLayoutBuilder.contains(part.cutLoops[other], point: loop[0])
                    }.count
                    return (CutSheetLayoutBuilder.signedArea(loop) > 0) == (depth % 2 == 0) ? loop : Array(loop.reversed())
                }
                let opened = try #require(PlanarBoolean.joining(rings, closingBy: 0, openingBy: thickness / 2 - 0.05))
                let pieces = opened.filter { CutSheetLayoutBuilder.signedArea($0) > 0.5 }
                #expect(pieces.count == 1, "\(path) \(part.label): \(pieces.count) pieces")
            }
        }
    }

    @Test
    func partsNarrowerThanTheStockAreNamed() throws {
        // The hollow box, first axis Y, 3 mm: the end curve ribs' slots cut
        // their rings open and leave 2 mm strips. The simple chair, first
        // axis Y, 5 mm: none.
        let box = try Self.fixture("tests/fixtures/stress/hollow_box_50mm.stl")
        let boxPlan = try #require(Self.plan(model: box, axis: .y, thickness: 3))
        let boxSlots = Self.slots(model: box, plan: boxPlan)
        #expect(boxSlots.thinLabels(axisLetter: "Y") == ["C-1", "C-7"])
        #expect(boxSlots.assemblyNotes(axisLetter: "Y").last == "Parts C-1, C-7 are narrower than the stock in places, "
            + "where a slot comes close to an edge or a hole or the model is that thin: handle them with care, or use thinner stock.")
        let chair = try Self.fixture("tests/fixtures/real-world/simple_chair.stl")
        let chairPlan = try #require(Self.plan(model: chair, axis: .y, thickness: 5))
        #expect(Self.slots(model: chair, plan: chairPlan).thinLabels(axisLetter: "Y").isEmpty)
    }

    // MARK: - What holds the parts together

    @Test
    func everyPartTakesPartInAJointAndPiecesNothingHoldsAreLeftOut() throws {
        // The lumpy blob, first axis Z, 3 mm: the bottom rib's second lobe
        // lies where the curve ribs fan in and stop, so it is left out.
        let blob = try Self.fixture("tests/fixtures/organic/lumpy_blob.stl")
        let blobPlan = try #require(Self.plan(model: blob, axis: .z, thickness: 3))
        let blobSlots = Self.slots(model: blob, plan: blobPlan)
        #expect(blobSlots.primaryLeftOut == [0])
        #expect(blobSlots.curveLeftOut.isEmpty)
        #expect(blobSlots.assemblyNotes(axisLetter: "Z").first
            == "A piece of Z-1 crosses no slice of the other family and is left out: nothing would hold it in place.")
        // The spur gear, first axis Y, 3 mm: the end first-axis ribs cut the
        // teeth only where no curve rib reaches, and two curve ribs keep
        // slivers past their joints.
        let gear = try Self.fixture("tests/fixtures/real-world/spur_gear_T20_M2.stl")
        let gearPlan = try #require(Self.plan(model: gear, axis: .y, thickness: 3))
        let gearSlots = Self.slots(model: gear, plan: gearPlan)
        #expect(gearSlots.primaryPieces[0].isEmpty)
        #expect(gearSlots.assemblyNotes(axisLetter: "Y").first?.hasPrefix("Y-1, 2 pieces of Y-6, a piece of C-1 and a piece of C-6 cross no slice") == true)
        for (model, plan, slots) in [(blob, blobPlan, blobSlots), (gear, gearPlan, gearSlots)] {
            for piece in (slots.primaryPieces + slots.curvePieces).joined() {
                #expect(!piece.joints.isEmpty)
                #expect(!piece.detached)
            }
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            #expect(document.partCount == (slots.primaryPieces + slots.curvePieces).joined().count)
            #expect(document.notes == slots.assemblyNotes(axisLetter: CutSheetLayoutBuilder.axisLetter(plan.primary.axis)))
        }
    }

    @Test
    func partsJoinedOnlyAmongThemselvesAreShownBlue() throws {
        // The simple chair, first axis Z: each side curve rib runs down one
        // leg and meets only that leg's four first-axis pieces.
        let chair = try Self.fixture("tests/fixtures/real-world/simple_chair.stl")
        let plan = try #require(Self.plan(model: chair, axis: .z, thickness: 3))
        let document = CutSheetLayoutBuilder.document(curve: plan, model: chair, settings: .defaultValue, revision: 1)
        let blue = document.sheets.flatMap(\.parts).filter(\.isDetached).map(\.label).sorted()
        #expect(blue == ["C-1", "C-12"] + (1...4).flatMap { ["Z-\($0)-3", "Z-\($0)-4"] }.sorted())
        #expect(document.notes.count == 1)
        #expect(document.notes.first?.hasPrefix("10 parts are joined to each other but not to the rest of the model") == true)
        // The torus, first axis Y, 5 mm: the curve ribs that reach the low
        // first-axis ribs stop short of the high ones, and the rest the other
        // way. The smaller group is blue, the larger is the model.
        let torus = try Self.fixture("tests/fixtures/primitives/torus_R30_r10mm.stl")
        let torusPlan = try #require(Self.plan(model: torus, axis: .y, thickness: 5))
        let slots = Self.slots(model: torus, plan: torusPlan)
        let pieces = (slots.primaryPieces + slots.curvePieces).joined()
        #expect(pieces.filter(\.detached).count == 6)
        #expect(pieces.filter { !$0.detached }.count == 8)
    }

    // MARK: - Sections

    @Test
    func openChainsAreClosedAcrossTheGapAndOverlapsResolved() {
        // A 10 mm square traced as two chains with 1 mm gaps between them.
        let chains = [
            SlicePath2D(points: [Vec2(x: 0, y: 1), Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 10, y: 4)], closed: false),
            SlicePath2D(points: [Vec2(x: 10, y: 5), Vec2(x: 10, y: 10), Vec2(x: 0, y: 10), Vec2(x: 0, y: 2)], closed: false)
        ]
        let closed = CurveSliceContourer.cleaned(chains)
        #expect(closed.count == 1)
        #expect(closed.allSatisfy { $0.closed })
        #expect(abs(abs(CutSheetLayoutBuilder.signedArea(closed[0].points)) - 100) < 0.5)
        // Two loops that overlap, with nothing to say which side of them the
        // model lies on: counted even-odd.
        let a = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 10, y: 10), Vec2(x: 0, y: 10), Vec2(x: 0, y: 0)]
        let b = [Vec2(x: 5, y: 0), Vec2(x: 15, y: 0), Vec2(x: 15, y: 10), Vec2(x: 5, y: 10), Vec2(x: 5, y: 0)]
        let resolved = CurveSliceContourer.cleaned([SlicePath2D(points: a, closed: true), SlicePath2D(points: b, closed: true)])
        let area = resolved.map { CutSheetLayoutBuilder.signedArea($0.points) }.reduce(0, +)
        #expect(abs(abs(area) - 100) < 0.5)
        // Two shells of a model that overlap, their surfaces facing out of
        // both: the overlap is model, and the material their union.
        func facingOut(_ square: [Vec2], centre: Vec2) -> [CurveSliceContourer.SectionEdge] {
            zip(square, square.dropFirst()).map { p, q in
                let middle = Vec2(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                return CurveSliceContourer.SectionEdge(a: p, b: q, outward: Vec2(x: middle.x - centre.x, y: middle.y - centre.y))
            }
        }
        let edges = facingOut(a, centre: Vec2(x: 5, y: 5)) + facingOut(b, centre: Vec2(x: 10, y: 5))
        let joined = CurveSliceContourer.cleaned([SlicePath2D(points: a, closed: true), SlicePath2D(points: b, closed: true)], edges: edges)
        #expect(joined.count == 1)
        #expect(abs(CutSheetLayoutBuilder.signedArea(joined[0].points) - 150) < 0.5)
    }

    @Test
    func shellsThatRunIntoEachOtherAreCutAsOnePiece() throws {
        // Two 50 mm cubes that overlap in a 30 mm cube, (-5, 25) on every
        // axis: every section through both is the outline of their union,
        // with no hole where they overlap.
        let model = try Self.fixture("tests/fixtures/pathological/cube_self_intersecting.stl")
        for thickness in [3.0, 5.0] {
            let plan = try #require(Self.plan(model: model, axis: .z, thickness: thickness))
            for layer in CurveSliceContourer.firstAxisContours(model: model, plan: plan).layers {
                #expect(layer.paths.count == 1, "z = \(layer.position)")
                let area = layer.paths.map { CutSheetLayoutBuilder.signedArea($0.points) }.reduce(0, +)
                let expected = layer.position > -5 && layer.position < 25 ? 2 * 2500.0 - 900 : 2500
                #expect(abs(area - expected) < 1, "z = \(layer.position): \(area)")
            }
            // A curve rib may pass the two cubes apart, but never has a hole.
            for layer in CurveSliceContourer.generate(model: model, plan: plan).layers {
                #expect(layer.paths.allSatisfy { CutSheetLayoutBuilder.signedArea($0.points) > 0 })
            }
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            let parts = document.sheets.flatMap(\.parts)
            // One part per first-axis rib: none falls into pieces.
            #expect(parts.allSatisfy { !$0.isError && (!$0.label.hasPrefix("Z-") || $0.label.split(separator: "-").count == 2) })
        }
    }

    @Test
    func everyCurveSectionOfTheOrganicBlobIsClosed() throws {
        let model = try Self.fixture("tests/fixtures/organic/lumpy_blob.stl")
        for axis in [SliceAxis.z, .y] {
            let plan = try #require(Self.plan(model: model, axis: axis, thickness: 3))
            let sections = CurveSliceContourer.generate(model: model, plan: plan).layers.map(\.paths)
                + CurveSliceContourer.firstAxisContours(model: model, plan: plan).layers.map(\.paths)
            #expect(sections.allSatisfy { paths in !paths.isEmpty && paths.allSatisfy { $0.closed } })
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            #expect(document.sheets.flatMap(\.parts).allSatisfy { $0.openCuts.isEmpty && !$0.isError })
        }
    }

    // MARK: - Helpers

    private static func slots(model: MeshSummary, plan: CurveSlicePlan) -> CurveJointPlanner.Slots {
        CurveJointPlanner.slots(
            plan: plan,
            primary: CurveSliceContourer.firstAxisContours(model: model, plan: plan),
            curve: CurveSliceContourer.generate(model: model, plan: plan)
        )
    }

    private static func plan(model: MeshSummary, axis: SliceAxis, thickness: Double) -> CurveSlicePlan? {
        CurveSlicePlanner.plan(
            model: model, primaryAxis: axis, materialThickness: thickness, firstAxisCount: 7,
            curveSliceCount: 12, amplitude: 10, slotWidth: thickness, slotAngleDegrees: 0
        )
    }

    private static func insideHollowBox(_ point: Vec3) -> Bool {
        let outer = [point.x, point.y, point.z].allSatisfy { abs($0) < 24.9 }
        let inner = [point.x, point.y, point.z].allSatisfy { abs($0) < 15.1 }
        let clear = [point.x, point.y, point.z].contains { abs(abs($0) - 15) < 0.2 }
        return outer && !inner && !clear
    }

    /// Least distance between two closed polygons that do not overlap.
    private static func distance(_ a: [Vec2], _ b: [Vec2]) -> Double {
        func toSegment(_ p: Vec2, _ s: Vec2, _ e: Vec2) -> Double {
            let dx = e.x - s.x, dy = e.y - s.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((p.x - s.x) * dx + (p.y - s.y) * dy) / length)) : 0
            let x = s.x + t * dx - p.x, y = s.y + t * dy - p.y
            return (x * x + y * y).squareRoot()
        }
        func toPolygon(_ p: Vec2, _ polygon: [Vec2]) -> Double {
            polygon.indices.map { toSegment(p, polygon[$0], polygon[($0 + 1) % polygon.count]) }.min() ?? .infinity
        }
        if a.contains(where: { CutSheetLayoutBuilder.contains(b, point: $0) })
            || b.contains(where: { CutSheetLayoutBuilder.contains(a, point: $0) }) {
            return 0
        }
        return min(a.map { toPolygon($0, b) }.min() ?? .infinity, b.map { toPolygon($0, a) }.min() ?? .infinity)
    }

    /// Whether the cut part has material at the model point (projected onto
    /// its plane), counting its cut loops even-odd.
    private static func holds(_ part: CutSheetPart, _ point: Vec3) -> Bool {
        guard let frame = part.planeFrame else { return false }
        let offset = Vec3(x: point.x - frame.origin.x, y: point.y - frame.origin.y, z: point.z - frame.origin.z)
        let plan = Vec2(
            x: offset.x * frame.xAxis.x + offset.y * frame.xAxis.y + offset.z * frame.xAxis.z,
            y: offset.x * frame.yAxis.x + offset.y * frame.yAxis.y + offset.z * frame.yAxis.z
        )
        let local = Vec2(x: plan.x - part.planMin.x, y: plan.y - part.planMin.y)
        let sheet: Vec2
        if part.rotatedOnSheet {
            let localHeight = part.bounds.max.x - part.bounds.min.x
            sheet = Vec2(x: part.bounds.min.x + localHeight - local.y, y: part.bounds.min.y + local.x)
        } else {
            sheet = Vec2(x: part.bounds.min.x + local.x, y: part.bounds.min.y + local.y)
        }
        return part.cutLoops.filter { CutSheetLayoutBuilder.contains($0, point: sheet) }.count % 2 == 1
    }

    private static func lerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }

    private static func fixture(_ path: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: path))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
