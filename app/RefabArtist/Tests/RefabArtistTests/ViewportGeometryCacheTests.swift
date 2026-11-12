import Foundation
import Testing
@testable import RefabArtist

@MainActor
struct ViewportGeometryCacheTests {
    @Test
    func reusesContoursForSamePlanAndRegeneratesOnChange() throws {
        let cube = try MeshInspector.inspect(url: Self.fixture("primitives/cube_50mm_binary.stl"))
        let cache = ViewportGeometryCache.shared
        let plan = try #require(StackedSlicePlanner.plan(model: cube, axis: .z, materialThickness: 5.0))

        let start = cache.stackedGenerationCount

        let first = cache.stackedContours(model: cube, plan: plan)
        let second = cache.stackedContours(model: cube, plan: plan)
        // Second request for the same (model, plan) is a cache hit — no regen.
        #expect(cache.stackedGenerationCount - start == 1)
        #expect(first.layers.count == second.layers.count)
        #expect(first.layers.count == plan.sliceCount)

        // A different plan (thicker slices) is a miss.
        let thicker = try #require(StackedSlicePlanner.plan(model: cube, axis: .z, materialThickness: 9.0))
        _ = cache.stackedContours(model: cube, plan: thicker)
        #expect(cache.stackedGenerationCount - start == 2)

        // Switching models clears the cache, so the original plan misses again.
        let sphere = try MeshInspector.inspect(url: Self.fixture("primitives/sphere_d50mm.stl"))
        let spherePlan = try #require(StackedSlicePlanner.plan(model: sphere, axis: .z, materialThickness: 5.0))
        _ = cache.stackedContours(model: sphere, plan: spherePlan)
        _ = cache.stackedContours(model: cube, plan: plan)
        #expect(cache.stackedGenerationCount - start == 4)
    }

    private static func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/fixtures/\(relativePath)")
    }
}
