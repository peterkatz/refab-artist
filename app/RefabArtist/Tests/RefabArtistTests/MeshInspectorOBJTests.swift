import Foundation
import Testing
@testable import RefabArtist

struct MeshInspectorOBJTests {
    @Test
    func objQuadFaceTriangulatesDeterministically() throws {
        let model = try Self.inspectOBJ("""
        v 0 0 0
        v 10 0 0
        v 10 10 0
        v 0 10 0
        f 1 2 3 4
        """)

        #expect(model.format == "obj")
        #expect(model.vertexObservationCount == 4)
        #expect(model.faceCount == 1)
        #expect(model.triangleCount == 2)
        #expect(model.geometry.triangleIndices == [0, 1, 2, 0, 2, 3])
        #expect(model.preflight.invalidTriangleReferenceCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 4)
    }

    @Test
    func objNegativeIndicesResolveFromCurrentVertexCount() throws {
        let model = try Self.inspectOBJ("""
        v 0 0 0
        v 10 0 0
        v 10 10 0
        v 0 10 0
        f -4 -3 -2 -1
        """)

        #expect(model.triangleCount == 2)
        #expect(model.geometry.triangleIndices == [0, 1, 2, 0, 2, 3])
        #expect(model.preflight.invalidTriangleReferenceCount == 0)
    }

    @Test
    func objOutOfRangeFaceReferenceIsReportedByPreflight() throws {
        let model = try Self.inspectOBJ("""
        v 0 0 0
        v 10 0 0
        v 0 10 0
        f 1 2 4
        """)

        #expect(model.faceCount == 1)
        #expect(model.triangleCount == 1)
        #expect(model.geometry.triangleIndices == [0, 1, 3])
        #expect(model.preflight.statusLabel == "Needs repair")
        #expect(model.preflight.invalidTriangleReferenceCount == 1)
    }

    private static func inspectOBJ(_ text: String) throws -> MeshSummary {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-obj-import-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try MeshInspector.inspect(url: url)
    }
}
