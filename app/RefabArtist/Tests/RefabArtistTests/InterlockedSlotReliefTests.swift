import Foundation
import Testing
@testable import RefabArtist

/// Interlocked Slot relief as the cut sheet cuts it, the notch-width
/// override, and the axes the planner picks itself.
struct InterlockedSlotReliefTests {
    @Test
    func mergedSlotsLeaveNoReliefToCutAndTheSheetSaysSo() throws {
        // 5 mm stock on the 50 mm cube's 5 mm slice spacing: the slots merge.
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 5,
            slotRelief: SlotReliefSettings(enabled: true, diameter: 4)
        ))
        let document = CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1)

        #expect(InterlockedPartBuilder.slotsMerge(plan: plan))
        #expect(document.reliefCutCount == 0)
        #expect(CutSheetLayoutBuilder.interlockedReliefCutCount(plan: plan, model: model) == 0)
        #expect(document.notes.count == 1)
        #expect(document.notes.first?.contains("merge") == true)
        // Nothing is cut: the same outlines as without relief.
        var plain = plan
        plain.slotRelief = .disabled
        let plainDocument = CutSheetLayoutBuilder.document(interlocked: plain, model: model, settings: .defaultValue, revision: 1)
        #expect(Self.cutLoops(document) == Self.cutLoops(plainDocument))
        #expect(plainDocument.notes.isEmpty)
    }

    @Test
    func reliefIsCutAtEveryInsideSlotCornerWhenTheSlotsStandApart() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 3,
            slotRelief: SlotReliefSettings(enabled: true, diameter: 1)
        ))
        let document = CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1)

        #expect(!InterlockedPartBuilder.slotsMerge(plan: plan))
        // Two inside corners at the bottom of every slot.
        #expect(document.reliefCutCount == plan.slotCount * 2)
        #expect(document.notes.isEmpty)
    }

    @Test
    func slotReliefWithNoToolCutsNothingAndSaysWhy() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 3,
            slotRelief: SlotReliefSettings(enabled: true, diameter: 0)
        ))
        let document = CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1)

        #expect(document.reliefCutCount == 0)
        #expect(document.notes.first?.contains("tool diameter is 0") == true)
    }

    @Test
    func slotOffsetChangesNothingWhileNotchWidthIsOn() throws {
        let model = try Self.cubeModel()
        func loops(clearance: Double, notchWidth: Double?) throws -> [[Vec2]] {
            let plan = try #require(InterlockedSlicePlanner.plan(
                model: model,
                primaryAxis: .z,
                secondaryAxis: .x,
                materialThickness: 3,
                slotClearance: clearance,
                notchWidthOverride: notchWidth,
                slotAngleDegrees: 30
            ))
            return Self.cutLoops(CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1))
        }

        let tight = try loops(clearance: 0.1, notchWidth: 3.4)
        let loose = try loops(clearance: 0.9, notchWidth: 3.4)
        #expect(tight == loose)

        // A notch width of stock + offset cuts what that offset does.
        let offset = try loops(clearance: 0.4, notchWidth: nil)
        #expect(offset.count == tight.count)
        let worst = zip(offset, tight).flatMap { a, b in
            zip(a, b).map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }
        }.max() ?? 0
        #expect(worst < 1.0e-6)
    }

    @Test
    func automaticAxesOverrideTheChosenOnesUnlessTheSidesTie() {
        func bounds(_ x: Double, _ y: Double, _ z: Double) -> Bounds3D {
            Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: x, y: y, z: z))
        }
        #expect(InterlockedSlicePlanner.automaticAxes(bounds: bounds(50, 50, 50)) == nil)
        #expect(InterlockedSlicePlanner.automaticAxes(bounds: bounds(60, 60, 20)).map { [$0.primary, $0.secondary] } == [.x, .y])
        #expect(InterlockedSlicePlanner.automaticAxes(bounds: bounds(20, 30, 80)).map { [$0.primary, $0.secondary] } == [.x, .y])
        #expect(InterlockedSlicePlanner.automaticAxes(bounds: bounds(80, 30, 20)).map { [$0.primary, $0.secondary] } == [.y, .z])

        let chosen = InterlockedSlicePlanner.selectAxes(bounds: bounds(50, 50, 50), givenPrimary: .y, givenSecondary: .z)
        #expect(chosen.primary == .y && chosen.secondary == .z)
        let picked = InterlockedSlicePlanner.selectAxes(bounds: bounds(80, 30, 20), givenPrimary: .z, givenSecondary: .x)
        #expect(picked.primary == .y && picked.secondary == .z)
    }

    private static func cutLoops(_ document: CutSheetDocument) -> [[Vec2]] {
        document.sheets.flatMap(\.parts).flatMap(\.cutLoops)
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
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
