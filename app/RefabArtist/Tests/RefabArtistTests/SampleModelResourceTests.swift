import Testing
@testable import RefabArtist

struct SampleModelResourceTests {
    @Test
    func bundledSampleModelLoadsThroughMeshInspector() throws {
        let url = try #require(SampleModelResource.url())
        let model = try MeshInspector.inspect(url: url)

        #expect(model.name == "cube_ascii.stl")
        #expect(model.vertexObservationCount == 36)
        #expect(model.triangleCount == 12)
        #expect(model.bounds?.min == Vec3(x: -25, y: -25, z: -25))
        #expect(model.bounds?.max == Vec3(x: 25, y: 25, z: 25))
    }
}
