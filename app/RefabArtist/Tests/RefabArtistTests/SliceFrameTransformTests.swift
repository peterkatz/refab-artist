import Foundation
import Testing
@testable import RefabArtist

struct SliceFrameTransformTests {
    private func approx(_ a: Vec3, _ b: Vec3, tol: Double = 1.0e-9) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    @Test
    func inverseUndoesForwardForArbitraryTilts() {
        let center = Vec3(x: 5, y: -2, z: 3)
        let point = Vec3(x: 9, y: 1, z: 7)
        for rotation in [
            Vec3(x: 30, y: 0, z: 0),
            Vec3(x: 0, y: 45, z: 0),
            Vec3(x: 0, y: 0, z: -20),
            Vec3(x: 15, y: 25, z: -35)
        ] {
            let forward = SliceFrameTransform.forward(point, rotationDegrees: rotation, center: center)
            let back = SliceFrameTransform.inverse(forward, rotationDegrees: rotation, center: center)
            #expect(approx(back, point), "round trip failed for \(rotation): \(back)")
        }
    }

    /// The forward must match what MeshScaler bakes, or the counter-rotation
    /// would land slices in the wrong place. Compare against MeshScaler on a
    /// single vertex.
    @Test
    func forwardMatchesMeshScalerRotation() throws {
        let v = Vec3(x: 12, y: 4, z: -6)
        let other = Vec3(x: 12, y: 4, z: -6)  // duplicate so bounds center == v
        // Build a tiny degenerate-but-bounded mesh whose bounds centre is known.
        let a = Vec3(x: 0, y: 0, z: 0)
        let b = Vec3(x: 10, y: 0, z: 0)
        let c = Vec3(x: 0, y: 8, z: 0)
        let geometry = MeshGeometryData(vertices: [a, b, c], triangleIndices: [0, 1, 2])
        let model = MeshSummary(
            name: "t", path: "/t", format: "obj", byteCount: 0,
            vertexObservationCount: 3, faceCount: 1, triangleCount: 1,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 8, z: 0)),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
        let center = Vec3(x: 5, y: 4, z: 0)
        let rotation = Vec3(x: 20, y: -15, z: 35)
        let baked = MeshScaler.transformed(model, scale: Vec3(x: 1, y: 1, z: 1), rotationDegrees: rotation)
        for (index, original) in [a, b, c].enumerated() {
            let mine = SliceFrameTransform.forward(original, rotationDegrees: rotation, center: center)
            let theirs = baked.geometry.vertices[index]
            #expect(approx(mine, theirs, tol: 1.0e-6), "vertex \(index): mine \(mine) vs MeshScaler \(theirs)")
        }
        _ = (v, other)
    }
}
