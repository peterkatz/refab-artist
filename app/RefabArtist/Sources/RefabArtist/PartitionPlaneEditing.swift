import CoreGraphics
import Foundation

/// Pure-math support for the in-viewport Partition plane gizmo: where a plane's
/// drag handle sits, which handle a click grabs, and the new offset a drag maps
/// to (slide the plane along its own normal). No RealityKit — unit-testable like
/// `ViewportDowelRayPicker`, which it reuses for ray/projection.
enum PartitionPlaneEditing {
    /// Screen-space grab radius, in view points.
    static let grabRadiusPoints = 30.0

    /// A draggable handle sits where the plane passes nearest the model centre:
    /// the projection of the bounds centre onto the plane.
    static func handle(for plane: PartitionPlane, bounds: Bounds3D) -> Vec3 {
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        let n = plane.normal
        let d = dot(center, n) - plane.offset
        return Vec3(x: center.x - n.x * d, y: center.y - n.y * d, z: center.z - n.z * d)
    }

    /// The offset range that keeps the plane within the model's bounding box
    /// (projection extent of the 8 corners onto the normal).
    static func offsetRange(normal: Vec3, bounds: Bounds3D) -> (min: Double, max: Double) {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let p = dot(Vec3(x: x, y: y, z: z), normal)
                    lo = Swift.min(lo, p)
                    hi = Swift.max(hi, p)
                }
            }
        }
        return (lo, hi)
    }

    /// The index of the manual plane whose handle is nearest the cursor (within
    /// `grabRadiusPoints`), or nil. Front-most handle wins on ties.
    static func pickPlaneIndex(
        viewPoint: CGPoint,
        viewSize: CGSize,
        pose: ViewportCameraPose,
        planes: [PartitionPlane],
        bounds: Bounds3D
    ) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, plane) in planes.enumerated() {
            let h = handle(for: plane, bounds: bounds)
            guard let projected = ViewportDowelRayPicker.project(h, viewSize: viewSize, pose: pose) else { continue }
            let dx = Double(projected.x - viewPoint.x)
            let dy = Double(projected.y - viewPoint.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= grabRadiusPoints else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// The new offset for a plane dragged so its handle follows the cursor ray,
    /// constrained to slide along the plane normal. Returns the closest point on
    /// the normal line to the ray, expressed as an offset and clamped to `range`.
    /// When the ray is nearly parallel to the normal (no leverage) the offset is
    /// unchanged.
    static func draggedOffset(
        ray: ViewportPickRay,
        normal: Vec3,
        handle: Vec3,
        currentOffset: Double,
        range: (min: Double, max: Double)
    ) -> Double {
        let n = normalize(normal)
        let u = normalize(ray.direction)
        let w0 = Vec3(x: ray.origin.x - handle.x, y: ray.origin.y - handle.y, z: ray.origin.z - handle.z)
        let b = dot(u, n)
        let denom = 1 - b * b
        guard abs(denom) > 1.0e-6 else { return currentOffset }
        let dd = dot(u, w0)
        let e = dot(n, w0)
        let s = (e - b * dd) / denom            // signed slide along the normal
        let newOffset = currentOffset + s
        return Swift.max(range.min, Swift.min(range.max, newOffset))
    }

    /// Tilt a plane by `degrees` while keeping it through `pivot` (so it rotates
    /// in place instead of jumping). Rotates the normal about the axis
    /// perpendicular to both the normal and world Z — i.e. tips the cut off
    /// vertical — giving arbitrary-angled cuts from the axis-aligned starters.
    /// Preserves the plane's identity.
    static func tilted(_ plane: PartitionPlane, degrees: Double, pivot: Vec3) -> PartitionPlane {
        let n = plane.normal
        var axis = cross(n, Vec3(x: 0, y: 0, z: 1))
        if length(axis) < 1.0e-6 { axis = cross(n, Vec3(x: 1, y: 0, z: 0)) }
        axis = normalize(axis)
        let rotated = rotate(n, about: axis, degrees: degrees)
        let offset = dot(pivot, rotated)
        return PartitionPlane(id: plane.id, normal: rotated, offset: offset, isManual: plane.isManual)
    }

    // MARK: - Vec helpers

    private static func rotate(_ v: Vec3, about axis: Vec3, degrees: Double) -> Vec3 {
        // Rodrigues; axis is unit and perpendicular to v, so the (a·v) term drops.
        let t = degrees * Double.pi / 180
        let c = cos(t), s = sin(t)
        let cr = cross(axis, v)
        return Vec3(x: v.x * c + cr.x * s, y: v.y * c + cr.y * s, z: v.z * c + cr.z * s)
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func length(_ v: Vec3) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    private static func normalize(_ v: Vec3) -> Vec3 {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard l > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: v.x / l, y: v.y / l, z: v.z / l)
    }
}
