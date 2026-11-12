import Foundation
import Testing
import simd
@testable import RefabArtist

struct ModelRotationRingTests {
    private static func zRing() -> ModelRotationRing {
        ModelRotationRing(
            center: Vec3(x: 10, y: -5, z: 2),
            radius: 40,
            axis: Vec3(x: 0, y: 0, z: 1),
            reference: Vec3(x: 1, y: 0, z: 0)
        )
    }

    @Test
    func pointAndDegreesAreInverses() {
        let ring = Self.zRing()
        for degrees in stride(from: -175.0, through: 175.0, by: 12.5) {
            let p = ring.point(atDegrees: degrees)
            let back = ring.degrees(for: p)
            #expect(back != nil)
            #expect(abs(back! - degrees) < 1.0e-9)
        }
    }

    @Test
    func positiveRotationConventionMatchesRightHandRule() {
        // +90° about Z carries the +X reference onto +Y (right-hand rule) —
        // the handle moves the way MeshScaler spins the model.
        let ring = Self.zRing()
        let p = ring.point(atDegrees: 90)
        #expect(abs(p.x - ring.center.x) < 1.0e-9)
        #expect(abs(p.y - (ring.center.y + ring.radius)) < 1.0e-9)
    }

    @Test
    func centerPointHasNoAngle() {
        let ring = Self.zRing()
        #expect(ring.degrees(for: ring.center) == nil)
    }

    @Test
    func dragDeltaIsRelativeNotAbsolute() {
        // Grabbing the ring at 90° and moving to 92° is a +2° delta, not a leap
        // to the cursor's absolute angle.
        #expect(abs(ModelRotationRing.snappedDelta(grabDegrees: 90, cursorDegrees: 92, snap: 0) - 2) < 1e-9)
    }

    @Test
    func dragDeltaSnapsToGrid() {
        #expect(ModelRotationRing.snappedDelta(grabDegrees: 0, cursorDegrees: 13.7, snap: 5) == 15)
    }

    @Test
    func dragDeltaAcrossSeamDoesNotUnwind() {
        // 175° → −175° is 10° of motion across the atan2 seam, not −350°.
        #expect(abs(ModelRotationRing.snappedDelta(grabDegrees: 175, cursorDegrees: -175, snap: 0) - 10) < 1e-9)
    }

    // MARK: - World-axis rotation composition (matches the ring, not Euler)

    @Test
    func eulerRoundTripsThroughTheRotationMatrix() {
        // Decomposing forwardRotationMatrix(e) must rebuild the same orientation
        // (away from gimbal lock). Compare the matrices, not the raw triples.
        for e in [Vec3(x: 10, y: 20, z: 30), Vec3(x: -40, y: 15, z: 70),
                  Vec3(x: 93.6, y: 52.3, z: -64.8), Vec3(x: 0, y: 0, z: 0)] {
            let m = SliceFrameTransform.rotationMatrix(degrees: e)
            let back = SliceFrameTransform.euler(from: m)
            let m2 = SliceFrameTransform.rotationMatrix(degrees: back)
            for c in 0..<3 {
                for r in 0..<3 {
                    #expect(abs(m[c][r] - m2[c][r]) < 1e-4)
                }
            }
        }
    }

    @Test
    func composingAboutAWorldAxisRotatesAboutThatAxisRegardlessOfStart() {
        // The whole point: with a compound start orientation, dragging the Y
        // ring must rotate the model about WORLD Y — i.e. composing +Δ about Y
        // equals premultiplying the start matrix by Ry(Δ), so the result
        // matrix matches Ry(Δ)·start exactly (no gimbal divergence).
        let start = Vec3(x: 93.6, y: 52.3, z: -64.8)
        let result = SliceFrameTransform.composeWorldAxisRotation(start: start, axis: .y, deltaDegrees: 17)
        let expected = SliceFrameTransform.cardinalAxisRotation(.y, degrees: 17)
            * SliceFrameTransform.rotationMatrix(degrees: start)
        let got = SliceFrameTransform.rotationMatrix(degrees: result)
        for c in 0..<3 {
            for r in 0..<3 {
                #expect(abs(expected[c][r] - got[c][r]) < 1e-4)
            }
        }
    }
}
