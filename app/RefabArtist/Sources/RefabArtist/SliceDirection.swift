import Foundation

/// Fine-tune tilt for the slicing frame — the Slice Direction panel, kept
/// additive to the coarse X/Y/Z axis buttons (owner call,
/// 2026-06-11: "I like the xyz buttons as well, don't remove them").
///
/// The two tilt angles rotate the slicing direction about the two axes
/// perpendicular to the chosen primary axis. Implemented as a model
/// pre-rotation in the slicing frame: rotating the model and tilting the
/// slice planes are the same operation, so planners, exporters, the
/// viewport, and dowel picking all stay in one consistent frame — no
/// per-consumer conjugation, and every output is untouched at zero tilt
/// (MeshScaler returns the identity model unchanged).
enum SliceDirection {
    static let tiltLimitDegrees = 89.0

    /// The two tilt axes for a primary slicing axis, in XYZ order.
    static func tiltAxes(for axis: SliceAxis) -> (first: SliceAxis, second: SliceAxis) {
        switch axis {
        case .x: return (.y, .z)
        case .y: return (.x, .z)
        case .z: return (.x, .y)
        }
    }

    /// MeshScaler Euler (degrees, applied X then Y then Z about the model
    /// centre) realizing the given tilts about the primary axis's two tilt
    /// axes. Non-finite input is treated as zero; values clamp inside ±89°
    /// (a 90° tilt is just a different primary axis — use the buttons).
    static func meshRotationDegrees(axis: SliceAxis, tiltFirst: Double, tiltSecond: Double) -> Vec3 {
        let first = sanitized(tiltFirst)
        let second = sanitized(tiltSecond)
        switch axis {
        case .x: return Vec3(x: 0, y: first, z: second)
        case .y: return Vec3(x: first, y: 0, z: second)
        case .z: return Vec3(x: first, y: second, z: 0)
        }
    }

    static func isIdentity(tiltFirst: Double, tiltSecond: Double) -> Bool {
        sanitized(tiltFirst) == 0 && sanitized(tiltSecond) == 0
    }

    static func sanitized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return max(-tiltLimitDegrees, min(tiltLimitDegrees, degrees))
    }
}
