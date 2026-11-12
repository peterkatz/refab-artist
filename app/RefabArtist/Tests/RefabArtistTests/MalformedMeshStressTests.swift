import Foundation
import Testing
@testable import RefabArtist

struct MalformedMeshStressTests {
    @Test
    func nonManifoldFinFixtureIsRepairedToWatertightCube() throws {
        let model = try Self.inspect("tests/fixtures/pathological/cube_nonmanifold_edge.stl")

        #expect(model.faceCount == 13)
        #expect(model.vertexObservationCount == 39)
        #expect(model.triangleCount == 12)
        #expect(model.geometry.triangleIndices.count == 36)
        #expect(model.preflight.statusLabel == "Watertight")
        #expect(model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 8)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        Self.expectBounds(model.bounds, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 25, y: 25, z: 25))
    }

    @Test
    func zeroAreaFaceFixtureReportsDegenerateTriangleWithoutChangingCubeBounds() throws {
        let model = try Self.inspect("tests/fixtures/pathological/cube_zero_area_face.stl")

        #expect(model.faceCount == 13)
        #expect(model.vertexObservationCount == 39)
        #expect(model.triangleCount == 13)
        #expect(model.preflight.statusLabel == "Needs repair")
        #expect(!model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 11)
        #expect(model.preflight.degenerateTriangleCount == 1)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        Self.expectBounds(model.bounds, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 25, y: 25, z: 25))
    }

    @Test
    func openShellStressFixtureReportsBoundaryEdges() throws {
        let model = try Self.inspect("tests/fixtures/stress/thin_shell_box_open_50mm.stl")

        #expect(model.faceCount == 10)
        #expect(model.vertexObservationCount == 30)
        #expect(model.triangleCount == 10)
        #expect(model.preflight.statusLabel == "Needs repair")
        #expect(!model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 8)
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 4)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        Self.expectBounds(model.bounds, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 25, y: 25, z: 25))
    }

    @Test
    func selfIntersectingFixtureCurrentlyImportsAsWatertightByEdgePreflight() throws {
        let model = try Self.inspect("tests/fixtures/pathological/cube_self_intersecting.stl")

        #expect(model.faceCount == 24)
        #expect(model.vertexObservationCount == 72)
        #expect(model.triangleCount == 24)
        #expect(model.preflight.statusLabel == "Watertight")
        #expect(model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 16)
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        Self.expectBounds(model.bounds, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 45, y: 45, z: 45))
    }

    @Test
    func veryThinFeatureFixtureCurrentlyImportsAsWatertight() throws {
        let model = try Self.inspect("tests/fixtures/pathological/cube_very_thin_feature_1mm.stl")

        #expect(model.faceCount == 24)
        #expect(model.vertexObservationCount == 72)
        #expect(model.triangleCount == 24)
        #expect(model.preflight.statusLabel == "Watertight")
        #expect(model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 16)
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
        Self.expectBounds(model.bounds, min: Vec3(x: -25, y: -25, z: -25), max: Vec3(x: 26, y: 25, z: 25))
    }

    @Test
    func malformedFixturesDoNotCrashStackedSvgExport() throws {
        let exportableFixtures = [
            "tests/fixtures/pathological/cube_nonmanifold_edge.stl",
            "tests/fixtures/pathological/cube_zero_area_face.stl",
            "tests/fixtures/pathological/cube_self_intersecting.stl",
            "tests/fixtures/stress/thin_shell_box_open_50mm.stl"
        ]

        for fixture in exportableFixtures {
            let model = try Self.inspect(fixture)
            let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5))
            let contours = StackedSliceContourer.generate(model: model, plan: plan)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "slicer-rebuild-malformed-\(UUID().uuidString).svg")
            defer { try? FileManager.default.removeItem(at: url) }

            try FlatPartExport.write(
                .stacked(plan, contours: contours, dowels: nil),
                format: .svg,
                model: model,
                settings: .defaultValue,
                to: url
            )
            let svg = try String(contentsOf: url, encoding: .utf8)
            #expect(svg.contains("<svg"))
            #expect(svg.contains("</svg>"))
            #expect(svg.contains("<g id=\"part-"))
        }
    }

    private static func inspect(_ path: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: path))
    }

    private static func expectBounds(_ bounds: Bounds3D?, min: Vec3, max: Vec3) {
        #expect(bounds?.min == min)
        #expect(bounds?.max == max)
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
