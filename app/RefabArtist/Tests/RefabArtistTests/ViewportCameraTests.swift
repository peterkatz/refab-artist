import Testing
@testable import RefabArtist

struct ViewportCameraTests {
    @Test
    func pointerDragReversesBothOrbitAxes() {
        let orbit = ViewportPointerMapping.orbitDeltas(deltaX: 12, deltaY: -7)

        #expect(orbit.deltaX == -12)
        #expect(orbit.deltaY == 7)
    }

    @Test
    func pointerOrbitMappingComposedWithRotateDecreasesYawForRightDrag() {
        var state = ViewportCameraState()
        let initialYaw = state.yawDegrees
        let orbit = ViewportPointerMapping.orbitDeltas(deltaX: 12, deltaY: 0)

        state.rotate(deltaX: orbit.deltaX, deltaY: orbit.deltaY)

        #expect(state.yawDegrees < initialYaw)
    }

    @Test
    func rotateUpdatesYawAndClampsPitch() {
        var state = ViewportCameraState()

        state.rotate(deltaX: 10, deltaY: 1_000)

        #expect(state.yawDegrees == 53.5)
        #expect(state.pitchDegrees == 82)
    }

    @Test
    func zoomControlsClampDistanceScale() {
        var state = ViewportCameraState()

        for _ in 0..<100 {
            state.zoomIn()
        }
        #expect(state.distanceScale == 0.2)

        for _ in 0..<100 {
            state.zoomOut()
        }
        #expect(state.distanceScale == 5)
    }

    @Test
    func panUsesRadiusAndZoomScale() {
        var state = ViewportCameraState(distanceScale: 2)

        state.pan(deltaX: 100, deltaY: -50, radius: 25)

        #expect(state.panX == -20)
        #expect(state.panY == -10)
    }

    @Test
    func poseFramesBoundsFromState() {
        let bounds = Bounds3D(
            min: Vec3(x: -25, y: -25, z: -25),
            max: Vec3(x: 25, y: 25, z: 25)
        )

        let defaultPose = ViewportCamera.pose(bounds: bounds, state: ViewportCameraState())
        let zoomedPose = ViewportCamera.pose(bounds: bounds, state: ViewportCameraState(distanceScale: 2))

        #expect(defaultPose.target == Vec3(x: 0, y: 0, z: 0))
        #expect(defaultPose.radius > 43)
        #expect(zoomedPose.position.x > defaultPose.position.x)
        #expect(zoomedPose.position.y > defaultPose.position.y)
        #expect(zoomedPose.position.z > defaultPose.position.z)
    }

    @Test
    func poseAppliesPanOffsetInCameraPlane() {
        let bounds = Bounds3D(
            min: Vec3(x: -25, y: -25, z: -25),
            max: Vec3(x: 25, y: 25, z: 25)
        )
        let pose = ViewportCamera.pose(
            bounds: bounds,
            state: ViewportCameraState(yawDegrees: 0, pitchDegrees: 0, distanceScale: 1, panX: 10, panY: 5)
        )

        #expect(pose.target == Vec3(x: 0, y: 10, z: 5))
    }

    @Test
    func resetRestoresDefaultCamera() {
        var state = ViewportCameraState(yawDegrees: 10, pitchDegrees: -20, distanceScale: 3, panX: 4, panY: -5)

        state.reset()

        #expect(state == ViewportCameraState())
    }

    @Test
    func cameraPresetsSnapOrientationAndKeepZoomScale() {
        var state = ViewportCameraState(yawDegrees: 12, pitchDegrees: 34, distanceScale: 2.5, panX: 7, panY: -3)

        state.apply(.top)

        #expect(state.yawDegrees == 45)
        #expect(state.pitchDegrees == 82)
        #expect(state.distanceScale == 2.5)
        #expect(state.panX == 0)
        #expect(state.panY == 0)

        state.apply(.front)

        #expect(state.yawDegrees == -90)
        #expect(state.pitchDegrees == 0)
    }

    @Test
    func cameraPresetLabelsStayStableForMenu() {
        #expect(ViewportCameraPreset.allCases.map(\.label) == ["Isometric", "Front", "Right", "Top"])
    }
}
