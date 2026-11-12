import Testing
@testable import RefabArtist

struct ViewportSceneBoundsTests {
    @Test
    func boundsIncludeFoldedShapeSurfacesInModelSpace() throws {
        // The folded preview renders the assembled shape at its true 3D
        // position, so the scene bounds grow to enclose any panel surface
        // that pokes past the supplied model bounds (here a panel reaching
        // x = 14, z = -2) — never onto a flat floor layout.
        let modelBounds = Bounds3D(
            min: Vec3(x: 0, y: 0, z: 0),
            max: Vec3(x: 10, y: 10, z: 10)
        )
        let plan = FoldedPanelPlan(
            panels: [],
            surfaces3D: [
                [
                    Vec3(x: 2, y: 2, z: -2),
                    Vec3(x: 14, y: 2, z: 0),
                    Vec3(x: 14, y: 8, z: 0),
                    Vec3(x: 2, y: 8, z: -2)
                ]
            ]
        )

        let bounds = try #require(ViewportSceneBounds.bounds(
            modelBounds: modelBounds,
            foldedPanelPlan: plan,
            materialThickness: 4
        ))

        #expect(bounds.min == Vec3(x: 0, y: 0, z: -2))
        #expect(bounds.max == Vec3(x: 14, y: 10, z: 10))
    }

    @Test
    func boundsFallBackToModelBoundsWhenNoGeneratedPreviewExtendsScene() {
        let modelBounds = Bounds3D(
            min: Vec3(x: -2, y: -3, z: -4),
            max: Vec3(x: 5, y: 6, z: 7)
        )

        #expect(ViewportSceneBounds.bounds(
            modelBounds: modelBounds,
            foldedPanelPlan: nil,
            materialThickness: 2
        ) == modelBounds)
    }
}
