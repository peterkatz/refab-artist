import Foundation
import Testing
@testable import RefabArtist

/// First-axis ribs moved off the even spacing so the joints hold parts that
/// would otherwise be joined only among themselves
/// (`CurveSlicePlanner.joiningGroups`).
struct CurveRibJoiningTests {
    /// The plan the CLI and the app lay out with their Curve defaults (7
    /// first-axis ribs, 12 curve ribs, amplitude 10), slots as wide as the
    /// stock.
    static func laidOut(_ model: MeshSummary, thickness: Double, axis: SliceAxis = .z) throws -> CurveSlicePlan {
        try #require(CurveSlicePlanner.plan(
            model: model,
            primaryAxis: axis,
            materialThickness: thickness,
            firstAxisCount: 7,
            curveSliceCount: 12,
            amplitude: 10,
            slotWidth: thickness,
            slotAngleDegrees: 0
        ))
    }

    static func slots(_ plan: CurveSlicePlan, _ model: MeshSummary) -> CurveJointPlanner.Slots {
        HeadlessExportCommand.curveSlots(plan: plan, model: model)
    }

    static func detached(_ slots: CurveJointPlanner.Slots) -> Int {
        (slots.primaryPieces.flatMap { $0 } + slots.curvePieces.flatMap { $0 }).filter(\.detached).count
    }

    static func model(_ path: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: path))
    }

    /// The simple chair with first axis Z: no first-axis rib at even spacing
    /// crosses the seat, so each side curve rib and the four leg pieces it
    /// runs through are joined only to each other. Moving the fourth rib up
    /// an eighth of the spacing, into the seat, joins them to the rest.
    @Test(arguments: [3.0, 5.0])
    func theChairsLegsAreJoinedByMovingOneRibIntoTheSeat(_ thickness: Double) throws {
        let chair = try Self.model("tests/fixtures/real-world/simple_chair.stl")
        let plan = try Self.laidOut(chair, thickness: thickness)
        let before = Self.slots(plan, chair)
        #expect(Self.detached(before) == 10)

        let joined = CurveSlicePlanner.joiningGroups(plan, model: chair)
        let after = Self.slots(joined, chair)
        #expect(Self.detached(after) == 0)
        #expect(after.primaryLeftOut.count + after.curveLeftOut.count <= before.primaryLeftOut.count + before.curveLeftOut.count)
        #expect(after.thinLabels(axisLetter: "Z").count <= before.thinLabels(axisLetter: "Z").count)

        // One rib moved, by an eighth of the even spacing; nothing else.
        let spacing = (plan.primary.rangeMax - plan.primary.rangeMin) / Double(plan.primary.sliceCount)
        #expect(joined.evenFirstAxisPositions == plan.primary.positions)
        #expect(joined.firstAxisMoves.count == 1)
        let move = try #require(joined.firstAxisMoves.first)
        #expect(move.rib == 3)
        #expect(abs(move.position - (move.even + spacing / 8)) < 1.0e-9)
        var unmoved = joined
        unmoved.primary.positions = plan.primary.positions
        unmoved.evenFirstAxisPositions = nil
        #expect(unmoved == plan)
        #expect(joined.firstAxisMoveNote
                == "Z-4 is set off the even spacing, at 181.25 mm instead of 175 mm, so the joints hold parts that would otherwise be joined only to each other.")
    }

    /// Plans whose parts are all joined are cut as laid out, and a plan is
    /// joined once.
    @Test
    func aPlanEveryPartOfWhichIsJoinedIsLeftAsItIs() throws {
        for path in ["tests/fixtures/primitives/sphere_d50mm.stl", "tests/fixtures/primitives/torus_R30_r10mm.stl"] {
            let model = try Self.model(path)
            let plan = try Self.laidOut(model, thickness: 3)
            #expect(Self.detached(Self.slots(plan, model)) == 0, "\(path)")
            #expect(CurveSlicePlanner.joiningGroups(plan, model: model) == plan, "\(path)")
            #expect(plan.firstAxisMoveNote == nil)
        }
        let chair = try Self.model("tests/fixtures/real-world/simple_chair.stl")
        let joined = CurveSlicePlanner.joiningGroups(try Self.laidOut(chair, thickness: 3), model: chair)
        #expect(CurveSlicePlanner.joiningGroups(joined, model: chair) == joined)
    }

    /// No move that helps: the plan stays as laid out (the spur gear with
    /// first axis Y in 5 mm stock keeps its blue parts).
    @Test
    func noMoveThatHelpsLeavesThePlanAsLaidOut() throws {
        let gear = try Self.model("tests/fixtures/real-world/spur_gear_T20_M2.stl")
        let plan = try Self.laidOut(gear, thickness: 5, axis: .y)
        #expect(Self.detached(Self.slots(plan, gear)) > 0)
        #expect(CurveSlicePlanner.joiningGroups(plan, model: gear) == plan)
    }

    /// A move is taken only when it joins parts, never when the count of
    /// blue parts falls because parts are lost. On the two spheres with
    /// first axis X (3 mm stock, 4 first-axis and 6 curve ribs, amplitude
    /// 0) each sphere is a group of its own at even spacing; moving X-2 a
    /// sixteenth of the spacing toward the gap between them empties its
    /// section, so the left sphere is one part short and the right one
    /// counts as the model: one blue part fewer, nothing joined and X-2
    /// lost. On the blocks touching at a corner with first axis Y (2 mm
    /// stock, 16 curve ribs asked for), moving Y-3 leaves it crossing no
    /// curve rib and cuts C-6 and C-7 away whole where they were left out
    /// before. Neither move is taken, and every rib is cut as laid out.
    @Test(arguments: [
        ("tests/fixtures/stress/multi_component_2spheres.stl", SliceAxis.x, 3.0, 6),
        ("tests/fixtures/pathological/blocks_touching_at_corner.stl", SliceAxis.y, 2.0, 16)
    ])
    func aMoveThatLosesPartsInsteadOfJoiningThemIsNotTaken(_ path: String, _ axis: SliceAxis, _ thickness: Double, _ curveRibs: Int) throws {
        let model = try Self.model(path)
        let plan = try #require(CurveSlicePlanner.plan(
            model: model,
            primaryAxis: axis,
            materialThickness: thickness,
            firstAxisCount: 4,
            curveSliceCount: curveRibs,
            amplitude: 0,
            slotWidth: thickness,
            slotAngleDegrees: 0
        ))
        let before = Self.slots(plan, model)
        #expect(Self.detached(before) > 0)

        let joined = CurveSlicePlanner.joiningGroups(plan, model: model)
        #expect(joined == plan)
        #expect(joined.firstAxisMoveNote == nil)
        let after = Self.slots(joined, model)
        #expect(Self.ribsCut(after.primaryPieces) == Self.ribsCut(before.primaryPieces))
        #expect(Self.ribsCut(after.curvePieces) == Self.ribsCut(before.curvePieces))
        #expect(after.primaryLeftOut == before.primaryLeftOut)
        #expect(after.curveLeftOut == before.curveLeftOut)
    }

    /// A move that lowers the count of blue parts without joining any to the
    /// rest of the model is not taken either. On the torus with first axis
    /// X (3 mm stock, 6 first-axis and 16 curve ribs, amplitude 20), moving
    /// X-2 would only make its two blue pieces one blue piece; moving X-4
    /// joins its two blue pieces to the rest. Only X-4 is moved.
    @Test
    func aMoveThatOnlyMergesBluePartsIsNotTaken() throws {
        let torus = try Self.model("tests/fixtures/primitives/torus_R30_r10mm.stl")
        let plan = try #require(CurveSlicePlanner.plan(
            model: torus,
            primaryAxis: .x,
            materialThickness: 3,
            firstAxisCount: 6,
            curveSliceCount: 16,
            amplitude: 20,
            slotWidth: 3,
            slotAngleDegrees: 0
        ))
        let before = Self.slots(plan, torus)
        let joined = CurveSlicePlanner.joiningGroups(plan, model: torus)
        #expect(joined.firstAxisMoves.map(\.rib) == [3])
        let after = Self.slots(joined, torus)
        #expect(Self.detached(after) < Self.detached(before))
        #expect(Self.joined(after) > Self.joined(before))
        let movedJoined = after.primaryPieces[3].allSatisfy { !$0.detached }
        let unmovedBlue = after.primaryPieces[1].allSatisfy { $0.detached }
        #expect(movedJoined)
        #expect(unmovedBlue)
    }

    /// Every move taken joins parts to the rest of the model and keeps every
    /// rib that was cut, and every rib that had a part joined to the rest
    /// still has one: on the simple chair the legs join the seat.
    @Test
    func aMoveTakenJoinsPartsAndKeepsEveryRib() throws {
        let chair = try Self.model("tests/fixtures/real-world/simple_chair.stl")
        let plan = try Self.laidOut(chair, thickness: 3)
        let before = Self.slots(plan, chair)
        let joined = CurveSlicePlanner.joiningGroups(plan, model: chair)
        let after = Self.slots(joined, chair)
        #expect(Self.joined(after) > Self.joined(before))
        #expect(Self.ribsCut(before.primaryPieces).isSubset(of: Self.ribsCut(after.primaryPieces)))
        #expect(Self.ribsCut(before.curvePieces).isSubset(of: Self.ribsCut(after.curvePieces)))
        #expect(Self.ribsJoined(before.primaryPieces).isSubset(of: Self.ribsJoined(after.primaryPieces)))
        #expect(Self.ribsJoined(before.curvePieces).isSubset(of: Self.ribsJoined(after.curvePieces)))
        let move = try #require(joined.firstAxisMoves.first)
        #expect(after.primaryPieces[move.rib].contains { !$0.detached })
    }

    static func joined(_ slots: CurveJointPlanner.Slots) -> Int {
        (slots.primaryPieces.flatMap { $0 } + slots.curvePieces.flatMap { $0 }).filter { !$0.detached }.count
    }

    /// The ribs of one family with at least one part.
    static func ribsCut(_ layers: [[CurveJointPlanner.Piece]]) -> Set<Int> {
        Set(layers.indices.filter { !layers[$0].isEmpty })
    }

    /// The ribs of one family with a part joined to the rest of the model.
    static func ribsJoined(_ layers: [[CurveJointPlanner.Piece]]) -> Set<Int> {
        Set(layers.indices.filter { layers[$0].contains { !$0.detached } })
    }

    /// The CLI cuts the joined plan, as the app does (the app joins it off
    /// the main thread and caches it, `ViewportGeometryCache.joinedCurvePlan`).
    @Test
    func theCLIAndTheAppCutTheJoinedPlan() throws {
        let chair = try Self.model("tests/fixtures/real-world/simple_chair.stl")
        let export = try HeadlessExportCommand.buildExport(
            mode: .curve, model: chair, axis: .z, secondaryAxis: .x, materialThickness: 3, sliceDepth: nil,
            slotClearance: 0, notchWidth: nil, slotAngle: 0, slotRelief: SlotReliefSettings(enabled: false, diameter: 0),
            sliceCount: nil, firstAxisCount: nil, curveSliceCount: nil, amplitude: 10, splineControlPoints: nil
        )
        guard case .curve(let cut) = export else {
            Issue.record("not a Curve export")
            return
        }
        let laidOut = try Self.laidOut(chair, thickness: 3)
        #expect(cut == CurveSlicePlanner.joiningGroups(laidOut, model: chair))
        #expect(!cut.firstAxisMoves.isEmpty)
        #expect(ViewportGeometryCache.shared.joinedCurvePlan(for: laidOut, model: chair) == cut)
        #expect(ViewportGeometryCache.shared.cachedJoinedCurvePlan(for: laidOut, model: chair) == cut)
        // The steps and the guide give the positions cut.
        let steps = AssemblyStepPlanner.steps(curve: cut)
        #expect(steps[3].detail.hasPrefix("Z family at 181.2 mm"))
    }

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
