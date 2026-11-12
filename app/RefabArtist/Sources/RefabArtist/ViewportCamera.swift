import Foundation
import simd

enum ViewportCameraPreset: String, CaseIterable, Identifiable {
    case isometric
    case front
    case right
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .isometric:
            return "Isometric"
        case .front:
            return "Front"
        case .right:
            return "Right"
        case .top:
            return "Top"
        }
    }

    var yawDegrees: Double {
        switch self {
        case .isometric:
            return 50
        case .front:
            return -90
        case .right:
            return 0
        case .top:
            return 45
        }
    }

    var pitchDegrees: Double {
        switch self {
        case .isometric:
            return 28
        case .front, .right:
            return 0
        case .top:
            return 82
        }
    }
}

/// Converts conventional pointer drags into orbit deltas. This mapping is kept
/// separate from `SpaceMouseMapping` so pointer direction changes cannot alter
/// the hardware-confirmed six-degree-of-freedom controls.
enum ViewportPointerMapping {
    static func orbitDeltas(deltaX: Double, deltaY: Double) -> (deltaX: Double, deltaY: Double) {
        (-deltaX, -deltaY)
    }
}

struct ViewportCameraState: Equatable {
    var yawDegrees: Double = 50
    var pitchDegrees: Double = 28
    var distanceScale: Double = 1
    var panX: Double = 0
    var panY: Double = 0
    /// Accumulated roll of the SCULPTURE (not the camera) about the view axis,
    /// driven by the SpaceMouse roll DOF (tilt cap left/right). Rolling the
    /// object instead of the viewport keeps the camera upright, so pan stays
    /// screen-aligned. Baked as a world-space orientation so it persists across
    /// orbit. Identity for pointer navigation.
    var modelSpin: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// When true the viewport uses an OrthographicCameraComponent.
    /// Dowel-edit and ring modes are automatically disabled in this projection.
    var isOrthographic: Bool = false

    /// Largest pan offset the camera will accept, as a multiple of the model
    /// radius. Pan was the ONE unbounded mutation: a burst of bad input (a
    /// misparsed SpaceMouse report is ±32767 per axis) walked the camera
    /// thousands of millimeters away and the model "disappeared" while
    /// everything else looked normal.
    static let maxPanMagnitude = 100_000.0

    /// Raw orbit: positive deltas increase yaw/pitch. The turntable drag
    /// convention (dragging right spins the model's visible face right) is
    /// applied ONCE, in `ViewportPointerMapping.orbitDeltas`, before this is
    /// called — never add a second inversion here or the two cancel and drag
    /// goes backwards again (that exact double-flip shipped on 2026-07-16).
    /// SpaceMouse rotation goes through spinYaw/spinPitch and is unaffected.
    mutating func rotate(deltaX: Double, deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        yawDegrees = (yawDegrees + deltaX * 0.35).truncatingRemainder(dividingBy: 360)
        pitchDegrees = Self.clamp(pitchDegrees + deltaY * 0.35, min: -82, max: 82)
    }

    /// Screen-relative axes (world-space) for the current yaw/pitch: the camera
    /// stays upright so these are the on-screen right / up / into-screen dirs.
    private func screenBasis() -> (right: SIMD3<Float>, up: SIMD3<Float>, view: SIMD3<Float>) {
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let view = simd_normalize(SIMD3<Float>(
            Float(cos(pitch) * cos(yaw)), Float(cos(pitch) * sin(yaw)), Float(sin(pitch))))
        let right = SIMD3<Float>(Float(-sin(yaw)), Float(cos(yaw)), 0)
        let up = SIMD3<Float>(
            Float(-sin(pitch) * cos(yaw)), Float(-sin(pitch) * sin(yaw)), Float(cos(pitch)))
        return (right, up, view)
    }

    /// Compose an incremental rotation of the SCULPTURE about a world-space
    /// (screen-relative) axis into the persistent orientation. All SpaceMouse
    /// rotations funnel through here, so twist/pitch/roll behave identically at
    /// any orientation and never fight the (upright) camera — which keeps pan
    /// screen-aligned.
    private mutating func spinModel(_ delta: Double, about axis: SIMD3<Float>) {
        guard delta.isFinite else { return }
        let angle = Float(delta * 0.35 * .pi / 180)
        modelSpin = simd_normalize(simd_quatf(angle: angle, axis: simd_normalize(axis)) * modelSpin)
    }

    /// Twist → spin about the screen-up axis (reads as a left/right turn).
    mutating func spinYaw(delta: Double) { spinModel(-delta, about: screenBasis().up) }
    /// Tilt forward/back → pitch about the screen-right axis.
    mutating func spinPitch(delta: Double) { spinModel(delta, about: screenBasis().right) }
    /// Tilt left/right → roll about the view axis (line of sight).
    mutating func roll(delta: Double) { spinModel(delta, about: screenBasis().view) }

    mutating func zoom(scrollDeltaY: Double) {
        guard scrollDeltaY.isFinite else { return }
        let multiplier = exp(Self.clamp(scrollDeltaY, min: -400, max: 400) * 0.0025)
        distanceScale = Self.clamp(distanceScale * multiplier, min: 0.2, max: 5)
    }

    mutating func zoomIn() {
        distanceScale = Self.clamp(distanceScale * 0.82, min: 0.2, max: 5)
    }

    mutating func zoomOut() {
        distanceScale = Self.clamp(distanceScale * 1.22, min: 0.2, max: 5)
    }

    mutating func pan(deltaX: Double, deltaY: Double, radius: Double) {
        guard deltaX.isFinite, deltaY.isFinite, radius.isFinite else { return }
        let scale = max(radius, 1) * 0.004 * distanceScale
        let bound = min(Self.maxPanMagnitude, max(radius, 1) * 6)
        panX = Self.clamp(panX - deltaX * scale, min: -bound, max: bound)
        panY = Self.clamp(panY + deltaY * scale, min: -bound, max: bound)
    }

    mutating func panLeft(radius: Double) {
        pan(deltaX: 24, deltaY: 0, radius: radius)
    }

    mutating func panRight(radius: Double) {
        pan(deltaX: -24, deltaY: 0, radius: radius)
    }

    mutating func panUp(radius: Double) {
        pan(deltaX: 0, deltaY: -24, radius: radius)
    }

    mutating func panDown(radius: Double) {
        pan(deltaX: 0, deltaY: 24, radius: radius)
    }

    mutating func reset() {
        self = ViewportCameraState()
    }

    mutating func apply(_ preset: ViewportCameraPreset) {
        yawDegrees = preset.yawDegrees
        pitchDegrees = preset.pitchDegrees
        panX = 0
        panY = 0
        modelSpin = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}

struct ViewportCameraPose: Equatable {
    var position: Vec3
    var target: Vec3
    var radius: Double
    /// Upright camera up vector (world-up projected). Roll lives on the
    /// sculpture, not the camera, so this never banks.
    var up: Vec3 = Vec3(x: 0, y: 0, z: 1)
    /// Camera screen-right vector. The camera orientation is built from
    /// (right, up, viewAxis) so panning along `right` is always
    /// screen-horizontal.
    var right: Vec3 = Vec3(x: 1, y: 0, z: 0)
}

enum ViewportCamera {
    /// The orthographic view-height (in scene units) that frames the same
    /// scene extent as the perspective camera does at the current distance.
    /// Formula: 2 * distance * tan(fov/2).
    static func orthographicViewHeight(bounds: Bounds3D?, state: ViewportCameraState,
                                        fovDegrees: Double = 42) -> Double {
        let r = radius(bounds: bounds)
        let distance = r * 3.25 * state.distanceScale
        return 2 * distance * tan(fovDegrees * .pi / 360)
    }

    static func radius(bounds: Bounds3D?) -> Double {
        guard let bounds else {
            return 40
        }
        let spanX = bounds.max.x - bounds.min.x
        let spanY = bounds.max.y - bounds.min.y
        let spanZ = bounds.max.z - bounds.min.z
        return max(1, sqrt(spanX * spanX + spanY * spanY + spanZ * spanZ) / 2)
    }

    static func pose(bounds: Bounds3D?, state: ViewportCameraState) -> ViewportCameraPose {
        let center: Vec3

        if let bounds {
            center = Vec3(
                x: (bounds.min.x + bounds.max.x) / 2,
                y: (bounds.min.y + bounds.max.y) / 2,
                z: (bounds.min.z + bounds.max.z) / 2
            )
        } else {
            center = Vec3(x: 0, y: 0, z: 0)
        }

        let radius = radius(bounds: bounds)
        let yaw = state.yawDegrees * .pi / 180
        let pitch = state.pitchDegrees * .pi / 180
        let distance = radius * 3.25 * state.distanceScale
        let horizontal = cos(pitch)
        let direction = Vec3(
            x: horizontal * cos(yaw),
            y: horizontal * sin(yaw),
            z: sin(pitch)
        )
        // The camera stays UPRIGHT (no roll). Roll is applied to the sculpture
        // instead (state.modelSpin), so screen-right is always horizontal and
        // pan never drifts diagonally.
        let right = Vec3(x: -sin(yaw), y: cos(yaw), z: 0)
        let up = Vec3(
            x: -sin(pitch) * cos(yaw),
            y: -sin(pitch) * sin(yaw),
            z: cos(pitch)
        )
        let target = Vec3(
            x: center.x + right.x * state.panX + up.x * state.panY,
            y: center.y + right.y * state.panX + up.y * state.panY,
            z: center.z + up.z * state.panY
        )

        return ViewportCameraPose(
            position: Vec3(
                x: target.x + direction.x * distance,
                y: target.y + direction.y * distance,
                z: target.z + direction.z * distance
            ),
            target: target,
            radius: radius,
            up: up,
            right: right
        )
    }
}
