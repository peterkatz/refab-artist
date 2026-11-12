import Foundation
import simd

/// Maps between the model's own frame and the rotated slicing frame.
///
/// Slice Direction works by pre-rotating the model into an axis-aligned
/// slicing frame (MeshScaler.transformed, rotation order Rx→Ry→Rz about the
/// bounds centre), planning there, and exporting from there. For the 3D
/// viewport we want the OPPOSITE presentation: the model stays put and only
/// the cut planes tilt. So the slice solids — built in the rotated frame —
/// are counter-rotated by the inverse of that same rotation about the same
/// centre, which lands them back onto the un-rotated model exactly where the
/// tilted cut passes through it.
enum SliceFrameTransform {
    /// Forward rotation a point undergoes in MeshScaler.transformed (rotation
    /// only; scale handled elsewhere). Pure, for tests.
    static func forward(_ p: Vec3, rotationDegrees: Vec3, center: Vec3) -> Vec3 {
        let rx = rotationDegrees.x * .pi / 180
        let ry = rotationDegrees.y * .pi / 180
        let rz = rotationDegrees.z * .pi / 180
        let (cx, sx) = (cos(rx), sin(rx))
        let (cy, sy) = (cos(ry), sin(ry))
        let (cz, sz) = (cos(rz), sin(rz))
        var q = Vec3(x: p.x - center.x, y: p.y - center.y, z: p.z - center.z)
        q = Vec3(x: q.x, y: q.y * cx - q.z * sx, z: q.y * sx + q.z * cx)        // X
        q = Vec3(x: q.x * cy + q.z * sy, y: q.y, z: -q.x * sy + q.z * cy)        // Y
        q = Vec3(x: q.x * cz - q.y * sz, y: q.x * sz + q.y * cz, z: q.z)         // Z
        return Vec3(x: q.x + center.x, y: q.y + center.y, z: q.z + center.z)
    }

    /// Inverse of `forward`: undoes Rz, then Ry, then Rx, about the centre.
    static func inverse(_ p: Vec3, rotationDegrees: Vec3, center: Vec3) -> Vec3 {
        let rx = rotationDegrees.x * .pi / 180
        let ry = rotationDegrees.y * .pi / 180
        let rz = rotationDegrees.z * .pi / 180
        let (cx, sx) = (cos(rx), sin(rx))
        let (cy, sy) = (cos(ry), sin(ry))
        let (cz, sz) = (cos(rz), sin(rz))
        var q = Vec3(x: p.x - center.x, y: p.y - center.y, z: p.z - center.z)
        // Inverse Z, then inverse Y, then inverse X.
        q = Vec3(x: q.x * cz + q.y * sz, y: -q.x * sz + q.y * cz, z: q.z)        // Z⁻¹
        q = Vec3(x: q.x * cy - q.z * sy, y: q.y, z: q.x * sy + q.z * cy)         // Y⁻¹
        q = Vec3(x: q.x, y: q.y * cx + q.z * sx, z: -q.y * sx + q.z * cx)        // X⁻¹
        return Vec3(x: q.x + center.x, y: q.y + center.y, z: q.z + center.z)
    }

    /// The inverse rotation as a 4×4 matrix about `center`, for applying to a
    /// RealityKit slice container so it lands on the un-rotated model.
    static func inverseMatrixAboutCenter(rotationDegrees: Vec3, center: Vec3) -> simd_float4x4 {
        let c = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        return translation(c) * inverseRotationMatrix(rotationDegrees) * translation(-c)
    }

    /// `to ∘ from⁻¹` about `center` — the EXTRA rotation that retargets
    /// geometry baked at Euler `from` so it appears as if baked at `to`.
    /// Used for live drag previews: the entity carries the delta while the
    /// mesh itself is only re-baked once, on drag end.
    static func deltaMatrixAboutCenter(fromDegrees: Vec3, toDegrees: Vec3, center: Vec3) -> simd_float4x4 {
        let c = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        let delta = forwardRotationMatrix(toDegrees) * inverseRotationMatrix(fromDegrees)
        return translation(c) * delta * translation(-c)
    }

    // MARK: - World-axis rotation composition (NEO-97 rings)

    /// Compose a true rotation of `deltaDegrees` about the WORLD `axis` onto the
    /// model already oriented at Euler `start` (MeshScaler's Rx→Ry→Rz), and
    /// return the resulting orientation re-expressed in that same Euler
    /// convention. This is what makes the rotation rings match the model: a ring
    /// drag rotates the model about the ring's actual axis (Blender-style),
    /// instead of poking one Euler component — which, under a compound rotation,
    /// spins the model about a different axis than the ring shows (gimbal
    /// coupling).
    static func composeWorldAxisRotation(start: Vec3, axis: SliceAxis, deltaDegrees: Double) -> Vec3 {
        let composed = cardinalAxisRotation(axis, degrees: deltaDegrees) * forwardRotationMatrix(start)
        return euler(from: composed)
    }

    /// MeshScaler's Rx→Ry→Rz rotation as a pure 4×4 (public for the rings).
    static func rotationMatrix(degrees: Vec3) -> simd_float4x4 {
        forwardRotationMatrix(degrees)
    }

    /// Right-handed rotation about a single world cardinal axis.
    static func cardinalAxisRotation(_ axis: SliceAxis, degrees: Double) -> simd_float4x4 {
        let a = Float(degrees * .pi / 180)
        switch axis {
        case .x: return rotationX(a)
        case .y: return rotationY(a)
        case .z: return rotationZ(a)
        }
    }

    /// Decompose a pure rotation matrix back into the Rx→Ry→Rz Euler triple
    /// (degrees) that `forwardRotationMatrix` would rebuild. R = Rz·Ry·Rx, so
    /// this is the standard ZYX (Tait-Bryan) extraction with gimbal-lock
    /// fallback at ry = ±90°. simd stores columns, so math R[row][col] =
    /// m.columns.col[row].
    static func euler(from m: simd_float4x4) -> Vec3 {
        let r20 = m.columns.0[2]            // R[2][0] = -sin(ry)
        let clamped = max(-1, min(1, -r20))
        let ry = asin(clamped)
        let cy = cos(ry)
        let rx: Float
        let rz: Float
        if abs(cy) > 1e-5 {
            rx = atan2(m.columns.1[2], m.columns.2[2])   // atan2(R[2][1], R[2][2])
            rz = atan2(m.columns.0[1], m.columns.0[0])   // atan2(R[1][0], R[0][0])
        } else {
            // Gimbal lock: fold rz into rx (pick rz = 0).
            rz = 0
            rx = atan2(-m.columns.2[1], m.columns.1[1])  // atan2(-R[1][2], R[1][1])
        }
        let toDeg = 180 / Float.pi
        return Vec3(x: Double(rx * toDeg), y: Double(ry * toDeg), z: Double(rz * toDeg))
    }

    /// MeshScaler's forward rotation (X then Y then Z) as a pure 4×4.
    private static func forwardRotationMatrix(_ degrees: Vec3) -> simd_float4x4 {
        let rx = Float(degrees.x * .pi / 180)
        let ry = Float(degrees.y * .pi / 180)
        let rz = Float(degrees.z * .pi / 180)
        return rotationZ(rz) * rotationY(ry) * rotationX(rx)
    }

    private static func inverseRotationMatrix(_ degrees: Vec3) -> simd_float4x4 {
        let rx = Float(degrees.x * .pi / 180)
        let ry = Float(degrees.y * .pi / 180)
        let rz = Float(degrees.z * .pi / 180)
        // Inverse rotation = Rx(-rx)·Ry(-ry)·Rz(-rz) (reverse order, negated).
        return rotationX(-rx) * rotationY(-ry) * rotationZ(-rz)
    }

    private static func rotationX(_ a: Float) -> simd_float4x4 {
        let (c, s) = (cos(a), sin(a))
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        let (c, s) = (cos(a), sin(a))
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationZ(_ a: Float) -> simd_float4x4 {
        let (c, s) = (cos(a), sin(a))
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }
}
