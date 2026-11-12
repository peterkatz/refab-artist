import Foundation
import Testing
@testable import RefabArtist

struct SliceDirectionRingTests {
    private let ring = SliceDirectionRing(
        center: Vec3(x: 10, y: -5, z: 20),
        radius: 80,
        tiltAxis: Vec3(x: 1, y: 0, z: 0),
        sliceAxis: Vec3(x: 0, y: 0, z: 1)
    )

    @Test
    func zeroDegreesSitsOnTheSliceAxis() {
        let p = ring.point(atDegrees: 0)
        #expect(abs(p.x - 10) < 1e-9)
        #expect(abs(p.y - -5) < 1e-9)
        #expect(abs(p.z - 100) < 1e-9)
    }

    @Test
    func pointAndDegreesAreInverses() throws {
        for degrees in [-45.0, -10.0, 0.0, 7.5, 15.0, 44.9] {
            let p = ring.point(atDegrees: degrees)
            let back = try #require(ring.degrees(for: p))
            #expect(abs(back - degrees) < 1e-9, "angle \(degrees) -> \(back)")
        }
    }

    @Test
    func handleTracksTheDisplayedSliceNormal() {
        // The displayed slice normal counter-rotates: tilting +15 about X
        // (MeshScaler forward = +15 on the mesh) shows planes whose normal is
        // rot(X, -15)·Z. The ring handle at +15° must sit on that direction.
        let degrees = 15.0
        let handle = ring.point(atDegrees: degrees)
        let direction = Vec3(
            x: (handle.x - ring.center.x) / ring.radius,
            y: (handle.y - ring.center.y) / ring.radius,
            z: (handle.z - ring.center.z) / ring.radius
        )
        let expected = SliceFrameTransform.inverse(
            Vec3(x: 0, y: 0, z: 1),
            rotationDegrees: Vec3(x: degrees, y: 0, z: 0),
            center: Vec3(x: 0, y: 0, z: 0)
        )
        #expect(abs(direction.x - expected.x) < 1e-9)
        #expect(abs(direction.y - expected.y) < 1e-9)
        #expect(abs(direction.z - expected.z) < 1e-9)
    }

    @Test
    func degreesProjectsOutOfPlanePointsIntoTheRingPlane() throws {
        // A point off the ring plane (offset along the tilt axis) lands on
        // the same angle — drags stay stable when the cursor ray hits the
        // plane obliquely.
        var p = ring.point(atDegrees: 22.0)
        p.x += 35
        let back = try #require(ring.degrees(for: p))
        #expect(abs(back - 22.0) < 1e-9)
    }
}
