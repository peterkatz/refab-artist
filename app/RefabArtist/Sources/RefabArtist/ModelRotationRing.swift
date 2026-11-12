import Foundation

/// Geometry for the Blender-style model-rotation gizmo (NEO-97): one ring
/// per world axis around the model. Unlike SliceDirectionRing (whose handle
/// tracks the counter-rotated slice normal), these use the POSITIVE rotation
/// convention — the handle moves the way the model actually spins.
///
/// Dragging a ring edits that axis's Euler COMPONENT of the Object Size
/// rotation (the same number its slider edits, composed Rx→Ry→Rz by
/// MeshScaler). With other components nonzero the handle is a slider-in-
/// space, not a world-axis trackball — matching the panel's mental model.
struct ModelRotationRing: Equatable {
    var center: Vec3
    var radius: Double
    /// The world rotation axis this ring edits (unit).
    var axis: Vec3
    /// The 0° reference direction (unit, perpendicular to `axis`).
    var reference: Vec3

    /// axis × reference — the in-plane direction at +90°.
    var tangent: Vec3 {
        Vec3(
            x: axis.y * reference.z - axis.z * reference.y,
            y: axis.z * reference.x - axis.x * reference.z,
            z: axis.x * reference.y - axis.y * reference.x
        )
    }

    /// Ring point at `degrees` (the same number the rotation field shows).
    func point(atDegrees degrees: Double) -> Vec3 {
        let radians = degrees * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        let t = tangent
        return Vec3(
            x: center.x + (reference.x * cosA + t.x * sinA) * radius,
            y: center.y + (reference.y * cosA + t.y * sinA) * radius,
            z: center.z + (reference.z * cosA + t.z * sinA) * radius
        )
    }

    /// Angle (degrees, ±180) whose ring point is nearest to a scene point —
    /// the inverse of `point` after projecting into the ring plane. nil when
    /// the point projects onto the ring centre.
    func degrees(for scenePoint: Vec3) -> Double? {
        let v = Vec3(x: scenePoint.x - center.x, y: scenePoint.y - center.y, z: scenePoint.z - center.z)
        let t = tangent
        let alongReference = v.x * reference.x + v.y * reference.y + v.z * reference.z
        let alongTangent = v.x * t.x + v.y * t.y + v.z * t.z
        guard alongReference * alongReference + alongTangent * alongTangent > 1.0e-12 else { return nil }
        return atan2(alongTangent, alongReference) * 180 / .pi
    }

    /// Snapped rotation delta about this ring's axis for a drag from `grab` to
    /// `cursor`. A DELTA, never a jump — clicking a ring 90° from the grab must
    /// not whip the model there — and seam-safe so crossing ±180 mid-drag
    /// doesn't unwind a full turn. The caller composes this as a true rotation
    /// about the ring axis (see SliceFrameTransform.composeWorldAxisRotation),
    /// so there's no per-ring "value" to normalize anymore.
    static func snappedDelta(grabDegrees: Double, cursorDegrees: Double, snap: Double) -> Double {
        var delta = cursorDegrees - grabDegrees
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return snap > 0 ? (delta / snap).rounded() * snap : delta
    }
}
