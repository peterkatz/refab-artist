import Foundation
import Testing
@testable import RefabArtist

struct CurveSlicesTests {
    @Test
    func curvePlannerSamplesCenteredCurveThroughModelBounds() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 6, amplitude: 10)!

        #expect(plan.sliceCount == 6)
        #expect(plan.primary.axis == .y)
        #expect(plan.primarySliceCount == 7)
        #expect(plan.totalPartCount == 13)
        #expect(plan.amplitude == 10)
        #expect(plan.centers.first!.x > -25)
        #expect(plan.centers.last!.x < 25)
        #expect(plan.directions.count == 6)
        #expect(plan.normals.count == 6)
    }

    @Test
    func curvePlannerSupportsFirstAxisAndCurveCounts() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(
            model: model,
            primaryAxis: .y,
            materialThickness: 3,
            firstAxisCount: 7,
            curveSliceCount: 12,
            amplitude: 10,
            slotWidth: 3,
            slotAngleDegrees: 45
        )!

        // Twelve curve ribs asked for; on a 50 mm cube in 3 mm stock seven
        // stand far enough apart for a stock-thick web between their slots.
        #expect(plan.primarySliceCount == 7)
        #expect(plan.sliceCount == 7)
        #expect(plan.requestedSliceCount == 12)
        #expect(plan.totalPartCount == 14)
        #expect(Self.joints(model: model, plan: plan).isEmpty == false)
    }

    @Test
    func curvePlannerSamplesStraightSplineByArcLength() throws {
        let model = try Self.cubeModel()
        let controlPoints = [Vec2(x: -25, y: 0), Vec2(x: 25, y: 0)]
        let plan = CurveSlicePlanner.plan(
            model: model,
            primaryAxis: .y,
            materialThickness: 5,
            firstAxisCount: 5,
            curveSliceCount: 5,
            splineControlPoints: controlPoints,
            slotWidth: 5,
            slotAngleDegrees: 0
        )!

        #expect(plan.controlPoints == controlPoints)
        #expect(plan.centers.map { $0.x } == [-20, -10, 0, 10, 20])
        #expect(plan.centers.allSatisfy { $0.y == 0 && $0.z == 0 })
        #expect(plan.directions.allSatisfy { $0 == Vec2(x: 1, y: 0) })
        #expect(plan.normals.allSatisfy { $0 == Vec2(x: 0, y: 1) })
    }

    @Test
    func curvePlannerUsesExplicitSplineControlPointsForBentRibs() throws {
        let model = try Self.cubeModel()
        let controlPoints = [
            Vec2(x: -25, y: 0),
            Vec2(x: -10, y: 20),
            Vec2(x: 10, y: 20),
            Vec2(x: 25, y: 0)
        ]
        let plan = CurveSlicePlanner.plan(
            model: model,
            primaryAxis: .y,
            materialThickness: 5,
            firstAxisCount: 7,
            curveSliceCount: 6,
            splineControlPoints: controlPoints,
            slotWidth: 5,
            slotAngleDegrees: 45
        )!

        // Five of the six curve ribs fit in 5 mm stock, and four first-axis
        // ribs: the spline's steep ends cross them at a slant, which takes
        // wider slots and more room between them.
        #expect(plan.sliceCount == 5)
        #expect(plan.requestedSliceCount == 6)
        #expect(plan.primarySliceCount == 4)
        #expect(plan.requestedFirstAxisCount == 7)
        #expect(plan.controlPoints == controlPoints)
        #expect(plan.centers.first!.x > -25)
        #expect(plan.centers.last!.x < 25)
        #expect(plan.centers.map(\.y).max()! > 15)
        #expect(plan.directions.first!.y > 0)
        #expect(plan.directions.last!.y < 0)
        #expect(Self.joints(model: model, plan: plan).isEmpty == false)
    }

    @Test
    func curveContourerProducesOneLayerPerCurveSlice() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10)!
        let contours = CurveSliceContourer.generate(model: model, plan: plan)

        #expect(contours.layers.count == plan.sliceCount)
        #expect(contours.layers.allSatisfy { !$0.paths.isEmpty })
        #expect(contours.layers.flatMap { $0.paths }.flatMap { $0.points }.count > 0)
    }

    @Test
    func curveContourerCutsPerpendicularToSplineTangent() throws {
        let model = try Self.cubeModel()
        let plan = try #require(CurveSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            materialThickness: 5,
            firstAxisCount: 5,
            curveSliceCount: 5,
            splineControlPoints: [Vec2(x: -25, y: 0), Vec2(x: 25, y: 0)],
            slotWidth: 5,
            slotAngleDegrees: 0
        ))

        let contours = CurveSliceContourer.generate(model: model, plan: plan)
        let firstLayer = try #require(contours.layers.first)
        let lastLayer = try #require(contours.layers.last)
        let firstScene = firstLayer.paths.flatMap(\.points).map {
            CurveSliceContourer.scenePoint($0, center: firstLayer.center, inPlaneDirection: firstLayer.normal)
        }
        let lastScene = lastLayer.paths.flatMap(\.points).map {
            CurveSliceContourer.scenePoint($0, center: lastLayer.center, inPlaneDirection: lastLayer.normal)
        }

        #expect(firstScene.allSatisfy { abs($0.x - plan.centers[0].x) < 1.0e-6 })
        #expect(lastScene.allSatisfy { abs($0.x - plan.centers[4].x) < 1.0e-6 })
        #expect((firstScene.map(\.y).max() ?? 0) - (firstScene.map(\.y).min() ?? 0) > 40)
        #expect((lastScene.map(\.y).max() ?? 0) - (lastScene.map(\.y).min() ?? 0) > 40)
    }

    @Test
    func curveDxfExportWritesEveryCutSheetPart() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10)!
        let settings = ExportLayoutSettings.defaultValue
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-curve-dxf-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try FlatPartExport.write(.curve(plan), format: .dxf, model: model, settings: settings, to: url)

        // One layer per cut-sheet part (first-axis slices, then C-1...C-n).
        let document = FlatPartExport.cutSheetDocument(for: .curve(plan), model: model, settings: settings, revision: 1)
        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(writer == .cutSheet)
        for part in document.sheets.flatMap(\.parts) {
            #expect(dxf.contains("\n8\n\(part.label)\n"), "part \(part.label)")
        }
        #expect(dxf.contains("\n8\nC-1\n"))
        #expect(dxf.contains("\n8\nC-\(plan.sliceCount)\n"))
        #expect(dxf.components(separatedBy: "\nLINE\n").count - 1 > 48)
        #expect(dxf.hasSuffix("0\nEOF\n"))
    }

    @Test
    func curveMeshExportLayersUseSlottedPanelGeometry() throws {
        let model = try Self.cubeModel()
        let plan = CurveSlicePlanner.plan(model: model, sliceCount: 12, amplitude: 10)!

        let layers = CurveSliceMeshExportBuilder.layers(plan: plan, model: model, materialThickness: 3)

        #expect(layers.count == plan.totalPartCount)
        #expect(layers.first?.name == "first_axis_001")
        #expect(layers.last?.name == String(format: "curve_%03d", plan.sliceCount))
        #expect(layers.contains { $0.name.hasPrefix("first_axis_") && !$0.mesh.vertices.isEmpty })
        #expect(layers.contains { $0.name.hasPrefix("curve_") && !$0.mesh.vertices.isEmpty })
    }

    private static func joints(model: MeshSummary, plan: CurveSlicePlan) -> [CurveJointPlanner.Joint] {
        CurveJointPlanner.slots(
            plan: plan,
            primary: CurveSliceContourer.firstAxisContours(model: model, plan: plan),
            curve: CurveSliceContourer.generate(model: model, plan: plan)
        ).joints
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
