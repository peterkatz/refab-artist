import Foundation
import Testing
@testable import RefabArtist

struct InterlockedSlotAngleTests {
    @Test
    func defaultSlotAnglePreservesRectangularSlotLayout() throws {
        let model = try Self.cubeModel()
        let defaultPlan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 10)!
        let explicitZeroPlan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 10,
            slotAngleDegrees: 0
        )!

        #expect(defaultPlan.normalizedSlotAngleDegrees == 0)
        #expect(Self.cutLoops(defaultPlan, model: model) == Self.cutLoops(explicitZeroPlan, model: model))
    }

    @Test
    func explicitNotchWidthOverridesMaterialDerivedSlotWidth() throws {
        let model = try Self.cubeModel()

        let defaultPlan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 10,
            slotClearance: 0.5
        )!
        let overridePlan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 10,
            slotClearance: 0.5,
            notchWidthOverride: 4.25
        )!

        #expect(defaultPlan.slotWidth == 10.5)
        #expect(overridePlan.slotWidth == 4.25)
        #expect(overridePlan.slotClearance == 0.5)
    }

    @Test
    func explicitNotchWidthKeepsMinimumSlotWidth() throws {
        let model = try Self.cubeModel()

        let plan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 10,
            notchWidthOverride: -4
        )!

        #expect(plan.slotWidth == 0.1)
    }

    @Test
    func angledSlotGeometryWidensMouthWithoutChangingSlotOrPartCount() throws {
        // 3 mm stock leaves material between the 5 mm-spaced slots, so every
        // slot keeps its own mouth for the angle to widen.
        let model = try Self.cubeModel()
        let defaultPlan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let angledPlan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 3,
            slotAngleDegrees: 45
        )!

        let defaultLoops = Self.cutLoops(defaultPlan, model: model)
        let angledLoops = Self.cutLoops(angledPlan, model: model)

        #expect(angledPlan.slotCount == defaultPlan.slotCount)
        #expect(angledLoops.count == defaultLoops.count)
        #expect(angledLoops.map(\.count) == defaultLoops.map(\.count))
        #expect(angledLoops != defaultLoops)
        #expect(angledPlan.slotMouthFlare(forDepth: 25) > 24.999)
    }

    @Test
    func dxfInterlockedExportUsesAngledSlotGeometry() throws {
        // 3 mm stock leaves material between the 5 mm-spaced slots, so each
        // slot keeps its own mouth for the angle to reshape.
        let model = try Self.cubeModel()
        let defaultPlan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let angledPlan = InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 3,
            slotAngleDegrees: 45
        )!
        let defaultDxf = try Self.exportDxf(defaultPlan, model: model)
        let angledDxf = try Self.exportDxf(angledPlan, model: model)

        // Same parts on the same layers; the angle reshapes the slot mouths.
        #expect(Self.layers(in: angledDxf) == Self.layers(in: defaultDxf))
        #expect(angledDxf != defaultDxf)
    }

    private static func layers(in dxf: String) -> Set<String> {
        let rows = dxf.components(separatedBy: "\n")
        return Set(stride(from: 0, to: rows.count - 1, by: 2).compactMap { rows[$0] == "8" ? rows[$0 + 1] : nil })
    }

    /// The outline of every part on the cut sheet, in sheet order: the
    /// geometry every Interlocked vector export cuts.
    private static func cutLoops(_ plan: InterlockedSlicePlan, model: MeshSummary) -> [[Vec2]] {
        CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1)
            .sheets.flatMap(\.parts).flatMap(\.cutLoops)
    }

    private static func exportDxf(_ plan: InterlockedSlicePlan, model: MeshSummary) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-slot-angle-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try FlatPartExport.write(.interlocked(plan), format: .dxf, model: model, settings: .defaultValue, to: url)
        return try String(contentsOf: url, encoding: .utf8)
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
