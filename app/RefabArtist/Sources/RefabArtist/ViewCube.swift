import Foundation
import SwiftUI

// MARK: - ViewCube target enum

/// All 26 click regions on a standard view cube: 6 faces, 12 edges, 8 corners.
/// Each target maps to a canonical (yaw, pitch) in degrees matching
/// ViewportCameraPreset conventions (Z-up, yaw around Z, pitch from horizon).
enum ViewCubeTarget: Hashable, CaseIterable {
    // Faces
    case front
    case back
    case left
    case right
    case top
    case bottom

    // Edges: top ring
    case topFront
    case topBack
    case topLeft
    case topRight
    // Edges: equator ring
    case frontRight
    case frontLeft
    case backRight
    case backLeft
    // Edges: bottom ring
    case bottomFront
    case bottomBack
    case bottomLeft
    case bottomRight

    // Corners: top
    case topFrontRight
    case topFrontLeft
    case topBackRight
    case topBackLeft
    // Corners: bottom
    case bottomFrontRight
    case bottomFrontLeft
    case bottomBackRight
    case bottomBackLeft

    /// Face label shown on the cube face, nil for non-face targets.
    var faceLabel: String? {
        switch self {
        case .front:  return "FRONT"
        case .back:   return "BACK"
        case .left:   return "LEFT"
        case .right:  return "RIGHT"
        case .top:    return "TOP"
        case .bottom: return "BOTTOM"
        default:      return nil
        }
    }

    // MARK: - Camera angles

    /// Yaw in degrees (rotation around Z axis, 0 = looking from +X side toward origin).
    var yawDegrees: Double {
        switch self {
        // Faces
        case .front:  return -90   // looking from -Y toward +Y
        case .back:   return 90    // looking from +Y toward -Y
        case .right:  return 0     // looking from +X toward -X
        case .left:   return 180   // looking from -X toward +X
        case .top:    return -90   // top-down (pitch dominates)
        case .bottom: return -90   // bottom-up (pitch dominates)
        // Top edges
        case .topFront:  return -90
        case .topBack:   return 90
        case .topLeft:   return 180
        case .topRight:  return 0
        // Equator edges
        case .frontRight:  return -45
        case .frontLeft:   return -135
        case .backRight:   return 45
        case .backLeft:    return 135
        // Bottom edges
        case .bottomFront:  return -90
        case .bottomBack:   return 90
        case .bottomLeft:   return 180
        case .bottomRight:  return 0
        // Top corners
        case .topFrontRight:  return -45
        case .topFrontLeft:   return -135
        case .topBackRight:   return 45
        case .topBackLeft:    return 135
        // Bottom corners
        case .bottomFrontRight:  return -45
        case .bottomFrontLeft:   return -135
        case .bottomBackRight:   return 45
        case .bottomBackLeft:    return 135
        }
    }

    /// Pitch in degrees (0 = horizon, +82 = top-down, -82 = bottom-up).
    var pitchDegrees: Double {
        switch self {
        // Faces
        case .front:  return 0
        case .back:   return 0
        case .right:  return 0
        case .left:   return 0
        case .top:    return 82
        case .bottom: return -82
        // Top edges
        case .topFront, .topBack, .topLeft, .topRight: return 45
        // Equator edges
        case .frontRight, .frontLeft, .backRight, .backLeft: return 0
        // Bottom edges
        case .bottomFront, .bottomBack, .bottomLeft, .bottomRight: return -45
        // Top corners
        case .topFrontRight, .topFrontLeft, .topBackRight, .topBackLeft: return 35
        // Bottom corners
        case .bottomFrontRight, .bottomFrontLeft, .bottomBackRight, .bottomBackLeft: return -35
        }
    }
}

// MARK: - ViewCube geometry projection

/// Projects the unit cube corners + face centers into 2D screen space
/// using the current yaw / pitch so the drawn cube tracks the viewport camera.
enum ViewCubeProjection {
    /// Size of the drawn cube widget in points.
    static let widgetSize: Double = 70

    private static func project(_ p: (x: Double, y: Double, z: Double),
                                 yaw: Double, pitch: Double) -> CGPoint {
        let yawR = yaw * .pi / 180
        let pitchR = pitch * .pi / 180
        // Rotate about Z by -yaw (camera yaw flips the cube orientation).
        let cosY = cos(-yawR), sinY = sin(-yawR)
        let x1 = p.x * cosY - p.y * sinY
        let y1 = p.x * sinY + p.y * cosY
        let z1 = p.z
        // Rotate about the new X by -pitch.
        let cosP = cos(-pitchR), sinP = sin(-pitchR)
        let z2 = y1 * sinP + z1 * cosP
        // Simple orthographic projection onto (x1, z2) — the cube is small
        // and perspective would be distracting at this size. (y2 is depth,
        // unused by the projection itself but used by faceDepth sorting.)
        let half = widgetSize / 2
        return CGPoint(x: half + x1 * half * 0.72, y: half - z2 * half * 0.72)
    }

    // MARK: Face rectangles (for hit testing and drawing)

    struct FaceQuad {
        var target: ViewCubeTarget
        var points: [CGPoint] // 4 corners, winding order front-facing
    }

    static func faceQuads(yaw: Double, pitch: Double) -> [FaceQuad] {
        let corners: [(Double, Double, Double)] = [
            (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), // bottom face corners
            (-1, -1,  1), (1, -1,  1), (1, 1,  1), (-1, 1,  1)  // top face corners
        ]
        let projected = corners.map { project((x: $0.0, y: $0.1, z: $0.2), yaw: yaw, pitch: pitch) }
        // b=bottom t=top; 0=left-back 1=right-back 2=right-front 3=left-front
        let b = projected    // indices 0..3
        let t = Array(projected[4...]) // indices 4..7

        return [
            FaceQuad(target: .bottom, points: [b[0], b[1], b[2], b[3]]),
            FaceQuad(target: .top,    points: [t[0], t[1], t[2], t[3]]),
            FaceQuad(target: .back,   points: [b[0], b[1], t[1], t[0]]),
            FaceQuad(target: .front,  points: [b[3], b[2], t[2], t[3]]),
            FaceQuad(target: .left,   points: [b[0], b[3], t[3], t[0]]),
            FaceQuad(target: .right,  points: [b[1], b[2], t[2], t[1]])
        ]
    }

    // MARK: - Hit testing

    /// Returns the nearest ViewCubeTarget hit by `point`, or nil if outside.
    static func hit(at point: CGPoint, yaw: Double, pitch: Double) -> ViewCubeTarget? {
        let quads = faceQuads(yaw: yaw, pitch: pitch)
        // Sort by depth (faces furthest from viewer drawn first, closest last)
        // so clicking an occluded face doesn't win. We approximate depth by
        // the mean z of the face's screen-projected center.
        let sorted = quads.sorted { a, b in
            faceDepth(a, yaw: yaw, pitch: pitch) < faceDepth(b, yaw: yaw, pitch: pitch)
        }
        // Walk front-to-back (reversed) and return the first face containing
        // the point.
        for quad in sorted.reversed() {
            if containsPoint(point, quad: quad.points) {
                return quad.target
            }
        }
        return nil
    }

    private static func faceDepth(_ quad: FaceQuad, yaw: Double, pitch: Double) -> Double {
        // Map face target to its unit-normal in object space, rotate it,
        // then use the resulting camera-space Z component as depth.
        let normal: (Double, Double, Double)
        switch quad.target {
        case .front:  normal = (0, -1, 0)
        case .back:   normal = (0,  1, 0)
        case .left:   normal = (-1, 0, 0)
        case .right:  normal = (1,  0, 0)
        case .top:    normal = (0,  0, 1)
        case .bottom: normal = (0,  0, -1)
        default:      normal = (0,  0,  0)
        }
        // The projection function maps object->screen; the y1 (after yaw,
        // before pitch) is the camera-forward component after the cube's yaw
        // rotation — faces with y1 > 0 are facing away from the camera.
        let yawR = yaw * .pi / 180
        let pitchR = pitch * .pi / 180
        let cosY = cos(-yawR), sinY = sin(-yawR)
        _ = normal.0 * cosY - normal.1 * sinY  // x1 (unused; kept for symmetry)
        let y1 = normal.0 * sinY + normal.1 * cosY
        let z1 = normal.2
        let cosP = cos(-pitchR), sinP = sin(-pitchR)
        let y2 = y1 * cosP - z1 * sinP
        return y2
    }

    private static func containsPoint(_ point: CGPoint, quad: [CGPoint]) -> Bool {
        guard quad.count == 4 else { return false }
        return windingContains(point, vertices: quad)
    }

    /// 2D winding-number inside polygon test.
    private static func windingContains(_ point: CGPoint, vertices: [CGPoint]) -> Bool {
        var winding = 0
        let n = vertices.count
        for i in 0..<n {
            let v0 = vertices[i]
            let v1 = vertices[(i + 1) % n]
            if v0.y <= point.y {
                if v1.y > point.y {
                    if isLeft(v0, v1, point) > 0 { winding += 1 }
                }
            } else {
                if v1.y <= point.y {
                    if isLeft(v0, v1, point) < 0 { winding -= 1 }
                }
            }
        }
        return winding != 0
    }

    private static func isLeft(_ p0: CGPoint, _ p1: CGPoint, _ p: CGPoint) -> Double {
        Double((p1.x - p0.x) * (p.y - p0.y) - (p.x - p0.x) * (p1.y - p0.y))
    }
}
