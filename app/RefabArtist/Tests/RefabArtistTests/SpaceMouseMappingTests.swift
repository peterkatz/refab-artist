import Testing
@testable import RefabArtist

/// Pins the SpaceMouse to the full 6-DOF mapping (capture-confirmed axis
/// layout): ax0=slide→h-pan, ax1=push/pull→zoom, ax2=lift→v-pan,
/// ax3=tilt-fwd/back→pitch, ax4=tilt-L/R→ROLL, ax5=twist→YAW. Every DOF is a
/// DISTINCT action; roll (ax4) and yaw (ax5) must never coincide.
struct SpaceMouseMappingTests {
    private func motion(
        tx: Double = 0, ty: Double = 0, tz: Double = 0,
        rx: Double = 0, ry: Double = 0, rz: Double = 0
    ) -> SpaceMouseController.Motion {
        SpaceMouseController.Motion(tx: tx, ty: ty, tz: tz, rx: rx, ry: ry, rz: rz)
    }

    // Left/right pair: slide (tx) MOVES, tilt/roll (ry) ROLLS — different actions.
    @Test
    func slideMovesHorizontally() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(tx: 200))
        #expect(d.panX != 0)
        #expect(d.orbitX == 0 && d.orbitY == 0 && d.roll == 0 && d.panY == 0 && d.zoom == 0)
    }

    @Test
    func tiltLeftRightRollsNotYaw() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(ry: 200))
        #expect(d.roll != 0)
        #expect(d.orbitX == 0)   // NOT yaw — roll is its own axis
        #expect(d.orbitY == 0 && d.panX == 0 && d.panY == 0 && d.zoom == 0)
    }

    @Test
    func twistYawsNotRoll() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(rz: 200))
        #expect(d.orbitX != 0)
        #expect(d.roll == 0)     // twist and tilt-L/R are DISTINCT
        #expect(d.orbitY == 0 && d.panX == 0 && d.panY == 0 && d.zoom == 0)
    }

    // Forward/back pair: push (ty) zooms, tilt (rx) pitches.
    @Test
    func pushPullZoomsNotPitch() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(ty: 150))
        #expect(d.zoom != 0)
        #expect(d.orbitY == 0 && d.roll == 0 && d.panX == 0 && d.panY == 0 && d.orbitX == 0)
    }

    @Test
    func tiltForwardBackPitches() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(rx: 150))
        #expect(d.orbitY != 0)
        #expect(d.orbitX == 0 && d.roll == 0 && d.panX == 0 && d.panY == 0 && d.zoom == 0)
    }

    // Vertical: lift (tz) pans vertically, never zooms.
    @Test
    func liftPansVerticallyNotZoom() {
        let d = SpaceMouseMapping.cameraDeltas(for: motion(tz: 200))
        #expect(d.panY != 0)
        #expect(d.zoom == 0 && d.panX == 0 && d.roll == 0)
    }
}
