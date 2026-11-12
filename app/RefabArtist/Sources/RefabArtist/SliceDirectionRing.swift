import Foundation

/// Geometry for the in-viewport Slice Direction protractor rings — a
/// tick-marked circle with a draggable handle and a swept-angle arc. One
/// ring per tilt axis: the ring sweeps the DISPLAYED slice-plane
/// normal as it rotates about `tiltAxis`, with 0° at the plain slicing axis.
///
/// The displayed normal counter-rotates relative to the model pre-rotation
/// (see SliceFrameTransform), so a +θ field value places the handle at
/// rot(tiltAxis, −θ)·sliceAxis — the handle always sits on the direction the
/// slices will actually stack.
struct SliceDirectionRing: Equatable {
    var center: Vec3
    var radius: Double
    /// The rotation axis this ring adjusts (unit, perpendicular to sliceAxis).
    var tiltAxis: Vec3
    /// The plain slicing direction (unit) — the 0° reference.
    var sliceAxis: Vec3

    /// tiltAxis × sliceAxis — the in-plane tangent direction at 0°.
    var tangentAxis: Vec3 {
        Vec3(
            x: tiltAxis.y * sliceAxis.z - tiltAxis.z * sliceAxis.y,
            y: tiltAxis.z * sliceAxis.x - tiltAxis.x * sliceAxis.z,
            z: tiltAxis.x * sliceAxis.y - tiltAxis.y * sliceAxis.x
        )
    }

    /// Ring point at a tilt of `degrees` (the same number the field shows).
    func point(atDegrees degrees: Double) -> Vec3 {
        let radians = -degrees * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        let tangent = tangentAxis
        return Vec3(
            x: center.x + (sliceAxis.x * cosA + tangent.x * sinA) * radius,
            y: center.y + (sliceAxis.y * cosA + tangent.y * sinA) * radius,
            z: center.z + (sliceAxis.z * cosA + tangent.z * sinA) * radius
        )
    }

    /// Tilt angle (degrees) whose handle position is nearest to a scene
    /// point — the inverse of `point` after projecting into the ring plane.
    /// nil when the point projects onto the ring centre.
    func degrees(for scenePoint: Vec3) -> Double? {
        let v = Vec3(x: scenePoint.x - center.x, y: scenePoint.y - center.y, z: scenePoint.z - center.z)
        let tangent = tangentAxis
        let alongSlice = v.x * sliceAxis.x + v.y * sliceAxis.y + v.z * sliceAxis.z
        let alongTangent = v.x * tangent.x + v.y * tangent.y + v.z * tangent.z
        guard alongSlice * alongSlice + alongTangent * alongTangent > 1.0e-12 else { return nil }
        return -atan2(alongTangent, alongSlice) * 180 / .pi
    }
}
