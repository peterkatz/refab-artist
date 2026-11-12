import Foundation
import Testing
@testable import RefabArtist

struct MeshPreflightTests {
    @Test
    func cubeFixtureReportsWatertightTopology() throws {
        let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))

        #expect(model.preflight.statusLabel == "Watertight")
        #expect(model.preflight.isWatertight)
        #expect(model.preflight.uniqueVertexCount == 8)
        #expect(model.preflight.duplicateVertexObservationCount == 28)
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 0)
        #expect(model.preflight.nonManifoldEdgeCount == 0)
    }

    @Test
    func openSingleTriangleReportsBoundaryEdges() {
        let report = MeshPreflight.analyze(geometry: MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 10, z: 0)
            ],
            triangleIndices: [0, 1, 2]
        ))

        #expect(report.statusLabel == "Needs repair")
        #expect(report.degenerateTriangleCount == 0)
        #expect(report.boundaryEdgeCount == 3)
        #expect(report.nonManifoldEdgeCount == 0)
    }

    @Test
    func collinearTriangleReportsDegenerateTriangle() {
        let report = MeshPreflight.analyze(geometry: MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 5, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0)
            ],
            triangleIndices: [0, 1, 2]
        ))

        #expect(report.statusLabel == "Needs repair")
        #expect(report.degenerateTriangleCount == 1)
        #expect(report.boundaryEdgeCount == 0)
    }

    @Test
    func duplicateVertexObservationsAreQuantized() {
        let report = MeshPreflight.analyze(geometry: MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 10, z: 0)
            ],
            triangleIndices: [0, 2, 3]
        ))

        #expect(report.uniqueVertexCount == 3)
        #expect(report.duplicateVertexObservationCount == 1)
    }

    @Test
    func edgeSharedByMoreThanTwoTrianglesReportsNonManifold() {
        let report = MeshPreflight.analyze(geometry: MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 10, z: 0),
                Vec3(x: 0, y: -10, z: 0),
                Vec3(x: 5, y: 0, z: 10)
            ],
            triangleIndices: [
                0, 1, 2,
                1, 0, 3,
                0, 1, 4
            ]
        ))

        #expect(report.statusLabel == "Needs repair")
        #expect(report.nonManifoldEdgeCount == 1)
    }

    @Test
    func outOfRangeTriangleIndexReportsInvalidReference() {
        let report = MeshPreflight.analyze(geometry: MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: 10, z: 0)
            ],
            triangleIndices: [0, 1, 7]
        ))

        #expect(report.statusLabel == "Needs repair")
        #expect(report.invalidTriangleReferenceCount == 1)
        #expect(report.degenerateTriangleCount == 0)
        #expect(report.boundaryEdgeCount == 0)
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
