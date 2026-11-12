import Testing
@testable import RefabArtist

/// A folded panel is a bare triangle (3 vertices, no repeated closing vertex).
/// The viewport mesh builder must accept it — it used to require ≥4 points, so
/// every triangular folded panel failed and the viewport drew the smooth model
/// instead of the constructed faceted shape (NEO-124 / the real bug).
struct ViewportFoldedPanelMeshTests {
    @Test func bareTriangleClosedPathProducesAMesh() {
        let triangle = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 0, y: 10)]
        let mesh = ViewportSliceSolidRenderData.mesh(
            paths: [SlicePath2D(points: triangle, closed: true)],
            materialThickness: 3,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        )
        #expect(mesh != nil)
    }

    @Test func explicitlyClosedTriangleStillWorks() {
        // A caller that DOES repeat the first vertex (radial/curve convention)
        // must still produce a mesh.
        let closed = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 0, y: 10), Vec2(x: 0, y: 0)]
        let mesh = ViewportSliceSolidRenderData.mesh(
            paths: [SlicePath2D(points: closed, closed: true)],
            materialThickness: 3,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        )
        #expect(mesh != nil)
    }

    @Test func degenerateTwoPointPathIsStillRejected() {
        let degenerate = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0)]
        let mesh = ViewportSliceSolidRenderData.mesh(
            paths: [SlicePath2D(points: degenerate, closed: true)],
            materialThickness: 3,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        )
        #expect(mesh == nil)
    }
}
