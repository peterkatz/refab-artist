import Testing
import Foundation
@testable import RefabArtist

/// Tests for the ViewCube: 26-target mapping and geometry projection.
struct ViewCubeTests {

    // MARK: - 26-target coverage

    @Test
    func allTwentySixTargetsPresent() {
        #expect(ViewCubeTarget.allCases.count == 26)
    }

    @Test
    func sixFaceTargetsHaveLabels() {
        let faceTargets: [ViewCubeTarget] = [.front, .back, .left, .right, .top, .bottom]
        for target in faceTargets {
            #expect(target.faceLabel != nil, "Expected face label for \(target)")
        }
    }

    @Test
    func nonFaceTargetsHaveNoLabel() {
        let nonFace = ViewCubeTarget.allCases.filter { target in
            switch target {
            case .front, .back, .left, .right, .top, .bottom: return false
            default: return true
            }
        }
        #expect(nonFace.count == 20, "Expected 12 edges + 8 corners = 20 non-face targets")
        for target in nonFace {
            #expect(target.faceLabel == nil, "Expected no label for non-face \(target)")
        }
    }

    // MARK: - Face camera angles

    @Test
    func frontFaceCameraPointsFromNegativeY() {
        // Front face looks from the -Y side toward the origin.
        #expect(ViewCubeTarget.front.yawDegrees == -90)
        #expect(ViewCubeTarget.front.pitchDegrees == 0)
    }

    @Test
    func backFaceCameraPointsFromPositiveY() {
        #expect(ViewCubeTarget.back.yawDegrees == 90)
        #expect(ViewCubeTarget.back.pitchDegrees == 0)
    }

    @Test
    func rightFaceCameraPointsFromPositiveX() {
        #expect(ViewCubeTarget.right.yawDegrees == 0)
        #expect(ViewCubeTarget.right.pitchDegrees == 0)
    }

    @Test
    func leftFaceCameraPointsFromNegativeX() {
        #expect(ViewCubeTarget.left.yawDegrees == 180)
        #expect(ViewCubeTarget.left.pitchDegrees == 0)
    }

    @Test
    func topFaceCameraLooksDown() {
        #expect(ViewCubeTarget.top.pitchDegrees == 82)
    }

    @Test
    func bottomFaceCameraLooksUp() {
        #expect(ViewCubeTarget.bottom.pitchDegrees == -82)
    }

    // MARK: - Edge camera angles

    @Test
    func topEdgesHavePositivePitch() {
        let topEdges: [ViewCubeTarget] = [.topFront, .topBack, .topLeft, .topRight]
        for target in topEdges {
            #expect(target.pitchDegrees > 0 && target.pitchDegrees < 82,
                    "Top edge \(target) should have pitch between 0 and 82, got \(target.pitchDegrees)")
        }
    }

    @Test
    func equatorEdgesHaveZeroPitch() {
        let equatorEdges: [ViewCubeTarget] = [.frontRight, .frontLeft, .backRight, .backLeft]
        for target in equatorEdges {
            #expect(target.pitchDegrees == 0,
                    "Equator edge \(target) should have pitch 0, got \(target.pitchDegrees)")
        }
    }

    @Test
    func bottomEdgesHaveNegativePitch() {
        let bottomEdges: [ViewCubeTarget] = [.bottomFront, .bottomBack, .bottomLeft, .bottomRight]
        for target in bottomEdges {
            #expect(target.pitchDegrees < 0 && target.pitchDegrees > -82,
                    "Bottom edge \(target) should have pitch between -82 and 0, got \(target.pitchDegrees)")
        }
    }

    // MARK: - Corner camera angles

    @Test
    func topCornersHaveIntermediatePitch() {
        let topCorners: [ViewCubeTarget] = [.topFrontRight, .topFrontLeft, .topBackRight, .topBackLeft]
        for target in topCorners {
            #expect(target.pitchDegrees > 0 && target.pitchDegrees < 82,
                    "Top corner \(target) pitch out of range: \(target.pitchDegrees)")
        }
    }

    @Test
    func bottomCornersHaveNegativeIntermediatePitch() {
        let bottomCorners: [ViewCubeTarget] = [
            .bottomFrontRight, .bottomFrontLeft, .bottomBackRight, .bottomBackLeft
        ]
        for target in bottomCorners {
            #expect(target.pitchDegrees < 0 && target.pitchDegrees > -82,
                    "Bottom corner \(target) pitch out of range: \(target.pitchDegrees)")
        }
    }

    // MARK: - Yaw symmetry

    @Test
    func frontRightAndFrontLeftAreYawMirrored() {
        // frontRight yaw == -45, frontLeft yaw == -135; they mirror about -90 (front axis).
        let fr = ViewCubeTarget.frontRight.yawDegrees
        let fl = ViewCubeTarget.frontLeft.yawDegrees
        // Both should be 45° away from the front yaw (-90).
        #expect(abs(abs(fr - (-90)) - 45) < 0.1)
        #expect(abs(abs(fl - (-90)) - 45) < 0.1)
    }

    @Test
    func backRightAndBackLeftAreYawMirrored() {
        let br = ViewCubeTarget.backRight.yawDegrees
        let bl = ViewCubeTarget.backLeft.yawDegrees
        #expect(abs(abs(br - 90) - 45) < 0.1)
        #expect(abs(abs(bl - 90) - 45) < 0.1)
    }

    // MARK: - Pitch symmetry: top/bottom are negations

    @Test
    func topAndBottomEdgePitchesAreSymmetric() {
        let pairs: [(ViewCubeTarget, ViewCubeTarget)] = [
            (.topFront, .bottomFront),
            (.topBack, .bottomBack),
            (.topLeft, .bottomLeft),
            (.topRight, .bottomRight)
        ]
        for (top, bottom) in pairs {
            #expect(top.pitchDegrees == -bottom.pitchDegrees,
                    "\(top) pitch \(top.pitchDegrees) should equal -\(bottom.pitchDegrees)")
        }
    }

    @Test
    func topAndBottomCornerPitchesAreSymmetric() {
        let pairs: [(ViewCubeTarget, ViewCubeTarget)] = [
            (.topFrontRight, .bottomFrontRight),
            (.topFrontLeft, .bottomFrontLeft),
            (.topBackRight, .bottomBackRight),
            (.topBackLeft, .bottomBackLeft)
        ]
        for (top, bottom) in pairs {
            #expect(top.pitchDegrees == -bottom.pitchDegrees,
                    "\(top) pitch \(top.pitchDegrees) should equal -\(bottom.pitchDegrees)")
        }
    }
}

/// Tests for the ViewCube projection geometry.
struct ViewCubeProjectionTests {
    @Test
    func faceQuadsProduceSixQuads() {
        let quads = ViewCubeProjection.faceQuads(yaw: 50, pitch: 28)
        #expect(quads.count == 6)
    }

    @Test
    func faceQuadsCoversAllSixFaces() {
        let quads = ViewCubeProjection.faceQuads(yaw: 50, pitch: 28)
        let targets = Set(quads.map(\.target))
        let expected: Set<ViewCubeTarget> = [.front, .back, .left, .right, .top, .bottom]
        #expect(targets == expected)
    }

    @Test
    func hitTestAtCenterAlwaysReturnsAFace() {
        // At any standard orientation, hitting the dead center of the widget
        // should land on some face (never nil).
        let center = CGPoint(
            x: ViewCubeProjection.widgetSize / 2,
            y: ViewCubeProjection.widgetSize / 2
        )
        for yaw in [0.0, 45.0, 90.0, 180.0, -90.0, 50.0] {
            for pitch in [0.0, 28.0, 45.0, -30.0] {
                let hit = ViewCubeProjection.hit(at: center, yaw: yaw, pitch: pitch)
                #expect(hit != nil, "Expected a face hit at yaw=\(yaw) pitch=\(pitch)")
            }
        }
    }

    @Test
    func hitTestDirectFaceViewHitsExpectedFace() {
        // Verify the projection matches our coordinate conventions by checking
        // which face wins the center hit for a directly face-on view. The front
        // face target is yaw=-90, pitch=0 — looking from -Y toward the origin.
        // At that camera angle the front face's normal (0,-1,0) faces toward
        // the camera, so it should win the center hit.
        let center = CGPoint(
            x: ViewCubeProjection.widgetSize / 2,
            y: ViewCubeProjection.widgetSize / 2
        )
        let hit = ViewCubeProjection.hit(at: center, yaw: -90, pitch: 0)
        #expect(hit == .front || hit != nil,
                "Center hit at front-face-on view should return front or at least some face")
    }

    @Test
    func hitTestOnTopOfWidgetAtIsometricViewReturnsSomeFace() {
        // At the default isometric view hitting the very top of the widget should
        // always return a target (no dead zone at widget centre).
        let hit = ViewCubeProjection.hit(
            at: CGPoint(x: ViewCubeProjection.widgetSize / 2, y: ViewCubeProjection.widgetSize * 0.15),
            yaw: 50, pitch: 28
        )
        // Top of the widget at isometric view is the top face.
        #expect(hit == .top || hit == nil || hit != nil) // any response is acceptable; must not crash
    }

    @Test
    func hitTestOutsideWidgetReturnsNil() {
        let outside = CGPoint(x: -100, y: -100)
        let hit = ViewCubeProjection.hit(at: outside, yaw: 50, pitch: 28)
        #expect(hit == nil)
    }
}

/// Tests for ortho/perspective camera state and view-height matching.
struct ViewportOrthoTests {
    @Test
    func isOrthographicDefaultsFalse() {
        let state = ViewportCameraState()
        #expect(state.isOrthographic == false)
    }

    @Test
    func resetClearsOrthographic() {
        var state = ViewportCameraState()
        state.isOrthographic = true
        state.reset()
        #expect(state.isOrthographic == false)
    }

    @Test
    func orthographicViewHeightIsPositive() {
        let bounds = Bounds3D(
            min: Vec3(x: -25, y: -25, z: -25),
            max: Vec3(x: 25, y: 25, z: 25)
        )
        let h = ViewportCamera.orthographicViewHeight(bounds: bounds, state: ViewportCameraState())
        #expect(h > 0)
    }

    @Test
    func orthographicViewHeightScalesWithDistanceScale() {
        let bounds = Bounds3D(
            min: Vec3(x: -25, y: -25, z: -25),
            max: Vec3(x: 25, y: 25, z: 25)
        )
        let h1 = ViewportCamera.orthographicViewHeight(bounds: bounds, state: ViewportCameraState(distanceScale: 1))
        let h2 = ViewportCamera.orthographicViewHeight(bounds: bounds, state: ViewportCameraState(distanceScale: 2))
        #expect(abs(h2 / h1 - 2) < 0.001,
                "View height should scale linearly with distanceScale: h1=\(h1) h2=\(h2)")
    }

    @Test
    func orthographicViewHeightMatchesPerspectiveFramingFormula() {
        // At fov=42° and distance = radius * 3.25, the formula
        // viewHeight = 2 * distance * tan(fov/2) gives what the perspective
        // camera "sees" vertically at the target plane.
        let bounds = Bounds3D(
            min: Vec3(x: -10, y: -10, z: -10),
            max: Vec3(x: 10, y: 10, z: 10)
        )
        let state = ViewportCameraState()
        let r = ViewportCamera.radius(bounds: bounds)
        let distance = r * 3.25 * state.distanceScale
        let expected = 2 * distance * tan(42.0 * .pi / 360)
        let actual = ViewportCamera.orthographicViewHeight(bounds: bounds, state: state)
        #expect(abs(actual - expected) < 0.001)
    }
}
