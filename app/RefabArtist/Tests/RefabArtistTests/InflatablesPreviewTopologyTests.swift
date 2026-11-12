import Foundation
import Testing
@testable import RefabArtist

struct InflatablesPreviewTopologyTests {
    @Test
    func inflatedPreviewPreservesCleanedTopologyAndDeviationCardinality() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl")
        )
        let cleaned = try InflatablesClean.cleanForInflatable(model.geometry)
        let plan = try InflatablesPlanner.plan(model: model.geometry, settings: .defaultValue)
        let preview = try #require(plan.preview)

        #expect(preview.inflatedMesh.vertices.count == cleaned.vertices.count)
        #expect(preview.inflatedMesh.triangleIndices == cleaned.triangleIndices)
        #expect(preview.deviationByVertex.count == preview.inflatedMesh.vertices.count)
        #expect(preview.deviationByVertex.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(preview.maxDeviationMM > 0)

        let moved = zip(preview.inflatedMesh.vertices, cleaned.vertices).contains { inflated, original in
            let dx = inflated.x - original.x
            let dy = inflated.y - original.y
            let dz = inflated.z - original.z
            return (dx * dx + dy * dy + dz * dz).squareRoot() > 1.0e-6
        }
        #expect(moved)
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
