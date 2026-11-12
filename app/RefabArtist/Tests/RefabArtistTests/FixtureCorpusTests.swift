import Foundation
import Testing
@testable import RefabArtist

struct FixtureCorpusTests {
    @Test
    func documentedCorpusFixturesLoadThroughMeshInspector() throws {
        let fixtures = [
            FixtureExpectation(name: "cube_ascii.stl", format: "stl-ascii", triangles: 12, uniqueVertices: 8, boundaryEdges: 0, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 25, y: 25, z: 25)),
            FixtureExpectation(name: "cube.obj", format: "obj", triangles: 4, uniqueVertices: 8, boundaryEdges: 8, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 25, y: 25, z: 25)),
            FixtureExpectation(name: "rectangular_prism_ascii.stl", format: "stl-ascii", triangles: 12, uniqueVertices: 8, boundaryEdges: 0, min: Vec3(x: -40, y: -20, z: -15), max: Vec3(x: 40, y: 20, z: 15)),
            FixtureExpectation(name: "square_pyramid_ascii.stl", format: "stl-ascii", triangles: 6, uniqueVertices: 5, boundaryEdges: 0, min: Vec3(x: -30, y: -30, z: 0), max: Vec3(x: 30, y: 30, z: 55))
        ]

        for fixture in fixtures {
            let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/\(fixture.name)"))
            #expect(model.format == fixture.format)
            #expect(model.triangleCount == fixture.triangles)
            #expect(model.bounds?.min == fixture.min)
            #expect(model.bounds?.max == fixture.max)
            #expect(model.preflight.uniqueVertexCount == fixture.uniqueVertices)
            #expect(model.preflight.degenerateTriangleCount == 0)
            #expect(model.preflight.boundaryEdgeCount == fixture.boundaryEdges)
            #expect(model.preflight.nonManifoldEdgeCount == 0)
        }
    }

    @Test
    func spurGearFixtureProducesSimpleStackedContours() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/real-world/spur_gear_T20_M2.stl")
        )
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)

        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5.0))
        let contours = StackedSliceContourer.generate(model: model, plan: plan)
        for (layerIndex, layer) in contours.layers.enumerated() {
            for (pathIndex, path) in layer.paths.enumerated() where path.closed {
                #expect(
                    Self.firstProperSelfIntersection(in: path.points) == nil,
                    "gear layer \(layerIndex) path \(pathIndex) must be a simple contour"
                )
            }
        }
    }

    private struct FixtureExpectation {
        var name: String
        var format: String
        var triangles: Int
        var uniqueVertices: Int
        var boundaryEdges: Int
        var min: Vec3
        var max: Vec3
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func firstProperSelfIntersection(in points: [Vec2]) -> (Int, Int)? {
        var polygon = points
        if let first = polygon.first, let last = polygon.last, samePoint(first, last) {
            polygon.removeLast()
        }
        guard polygon.count >= 4 else { return nil }
        for i in polygon.indices {
            let a1 = polygon[i]
            let a2 = polygon[(i + 1) % polygon.count]
            for j in (i + 1)..<polygon.count {
                if abs(i - j) == 1 || abs(i - j) == polygon.count - 1 {
                    continue
                }
                let b1 = polygon[j]
                let b2 = polygon[(j + 1) % polygon.count]
                if sharesVertex(a1, a2, b1, b2) {
                    continue
                }
                if segmentsProperlyCross(a1, a2, b1, b2) {
                    return (i, j)
                }
            }
        }
        return nil
    }

    private static func segmentsProperlyCross(_ a1: Vec2, _ a2: Vec2, _ b1: Vec2, _ b2: Vec2) -> Bool {
        let d1 = orient(a1, a2, b1)
        let d2 = orient(a1, a2, b2)
        let d3 = orient(b1, b2, a1)
        let d4 = orient(b1, b2, a2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    private static func sharesVertex(_ a1: Vec2, _ a2: Vec2, _ b1: Vec2, _ b2: Vec2) -> Bool {
        [a1, a2].contains { a in
            [b1, b2].contains { b in samePoint(a, b) }
        }
    }

    private static func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func samePoint(_ a: Vec2, _ b: Vec2) -> Bool {
        abs(a.x - b.x) <= 1.0e-9 && abs(a.y - b.y) <= 1.0e-9
    }
}
