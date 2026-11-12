import Foundation
import Testing
@testable import RefabArtist

/// A slice plane that passes exactly through a ring of mesh vertices contains
/// the mesh edges between them. Each such edge is shared by two triangles, and
/// the section must still trace it once: the cutter follows every traced
/// edge, so a loop walked round twice is cut twice.
struct SliceContourInPlaneEdgeTests {
    @Test
    func onlyTheTriangleBelowEmitsAnInPlaneEdge() {
        #expect(StackedSliceContourer.isAboveInPlaneEdge(distances: [0, 0, 1]))
        #expect(!StackedSliceContourer.isAboveInPlaneEdge(distances: [0, 0, -1]))
        // One corner on the plane, or none: an ordinary crossing.
        #expect(!StackedSliceContourer.isAboveInPlaneEdge(distances: [0, 1, -1]))
        #expect(!StackedSliceContourer.isAboveInPlaneEdge(distances: [0.5, 1, -1]))
        // A triangle lying in the plane emits nothing either way.
        #expect(!StackedSliceContourer.isAboveInPlaneEdge(distances: [0, 0, 0]))
    }

    @Test
    func sphereSlicedThroughItsEquatorRingIsTracedOnce() throws {
        let model = try Self.sphereModel()
        let plan = try #require(StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: [0]
        ))
        let layer = try #require(StackedSliceContourer.generate(model: model, plan: plan).layers.first)

        #expect(layer.paths.count == 1)
        let path = try #require(layer.paths.first)
        #expect(path.closed)
        Self.expectTracedOnce(path, vertexCount: 32)
    }

    @Test
    func curveRibThroughAMeridianIsTracedOnce() throws {
        let model = try Self.sphereModel()
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
        // The middle rib is the plane x = 0, which holds a meridian of the
        // sphere's vertices.
        #expect(plan.centers[2].x == 0)
        let layer = CurveSliceContourer.generate(model: model, plan: plan).layers[2]

        #expect(layer.paths.count == 1)
        let path = try #require(layer.paths.first)
        #expect(path.closed)
        Self.expectTracedOnce(path, vertexCount: 32)
    }

    /// The closed path visits `vertexCount` distinct points, each once.
    private static func expectTracedOnce(_ path: SlicePath2D, vertexCount: Int) {
        var points = path.points
        if let first = points.first, let last = points.last, first == last {
            points.removeLast()
        }
        let distinct = Set(points.map { "\(Int(($0.x * 1.0e4).rounded())):\(Int(($0.y * 1.0e4).rounded()))" })
        #expect(points.count == vertexCount)
        #expect(distinct.count == vertexCount)
    }

    private static func sphereModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl"))
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
