import Foundation
import Testing
@testable import RefabArtist

/// QEM decimation for Folded Panels' dense-mesh handling: face budget is
/// honored, the surface stays manifold/watertight, and the approximation
/// stays near the original shape.
struct MeshSimplifierTests {
    private static func fixture(_ relativePath: String) throws -> MeshSummary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RefabArtistTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RefabArtist
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
        return try MeshInspector.inspect(url: root.appendingPathComponent(relativePath))
    }

    @Test
    func meshAtOrUnderTargetIsReturnedUntouched() throws {
        let cube = try Self.fixture("tests/fixtures/primitives/cube_50mm_binary.stl")
        let result = try #require(MeshSimplifier.simplify(cube, targetFaceCount: 500))
        #expect(result == cube)
    }

    @Test
    func denseSphereSimplifiesToBudgetAndStaysWatertight() throws {
        let sphere = try Self.fixture("tests/fixtures/primitives/sphere_d50mm.stl")
        #expect(sphere.triangleCount > 100)

        let simplified = try #require(MeshSimplifier.simplify(sphere, targetFaceCount: 100))
        #expect(simplified.triangleCount <= 100)
        #expect(simplified.triangleCount > 20) // didn't collapse to nothing

        // Watertight in, watertight out: the folded net assembly depends on
        // clean edge topology.
        #expect(simplified.preflight.boundaryEdgeCount == 0)
        #expect(simplified.preflight.nonManifoldEdgeCount == 0)
        #expect(simplified.preflight.degenerateTriangleCount == 0)

        // The approximation stays near the original: bounds within 10% of
        // the sphere's diameter (QEM optimal points may sit slightly off
        // the surface).
        let original = try #require(sphere.bounds)
        let result = try #require(simplified.bounds)
        let slack = 5.0 // mm on a d=50 sphere
        #expect(result.min.x > original.min.x - slack)
        #expect(result.min.y > original.min.y - slack)
        #expect(result.min.z > original.min.z - slack)
        #expect(result.max.x < original.max.x + slack)
        #expect(result.max.y < original.max.y + slack)
        #expect(result.max.z < original.max.z + slack)
        // And it still spans most of the original (didn't shrivel).
        let span = result.max.z - result.min.z
        let originalSpan = original.max.z - original.min.z
        #expect(span > originalSpan * 0.8)
    }

    @Test
    func organicMeshSimplifiesAndFoldsToBoundedPanelCount() throws {
        let blob = try Self.fixture("tests/fixtures/organic/lumpy_blob.stl")
        let target = 80
        guard blob.triangleCount > target else {
            Issue.record("fixture too small to exercise simplification")
            return
        }
        let simplified = try #require(MeshSimplifier.simplify(blob, targetFaceCount: target))
        #expect(simplified.triangleCount <= target)
        #expect(simplified.preflight.nonManifoldEdgeCount == 0)

        // The folded pipeline consumes it directly: every remaining face is
        // a panel, so the build is bounded by the Detail budget.
        let plan = FoldedPanelPlanner.plan(model: simplified)
        #expect(!plan.panels.isEmpty)
        #expect(plan.panels.count <= target)
    }

    @Test
    func headlessFoldedTargetFacesBoundsTheExport() throws {
        let blob = try Self.fixture("tests/fixtures/organic/lumpy_blob.stl")
        let unsimplified = FoldedPanelPlanner.plan(model: blob)
        let simplified = try #require(MeshSimplifier.simplify(blob, targetFaceCount: 80))
        let bounded = FoldedPanelPlanner.plan(model: simplified)
        #expect(bounded.panels.count < unsimplified.panels.count)
    }
}
