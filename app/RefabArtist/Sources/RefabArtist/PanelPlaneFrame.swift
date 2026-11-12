import Foundation

/// An orthonormal 2D frame embedded in the plane of a 3D polygon, used to
/// flatten a coplanar panel for extrusion and map it back to its true 3D
/// position. Pure value type so the projection math is unit-testable apart
/// from RealityKit.
struct PanelPlaneFrame {
    let origin: Vec3
    let xAxis: Vec3
    let yAxis: Vec3
    let normal: Vec3

    /// Builds a frame from an ordered polygon. The normal is Newell's area
    /// normal (robust to a near-degenerate first edge and slight
    /// non-planarity); the x-axis is the first boundary edge long enough to
    /// normalize. Returns nil when the polygon has no area / no usable edge.
    init?(polygon: [Vec3]) {
        guard polygon.count >= 3 else { return nil }
        let origin = polygon[0]

        var nx = 0.0, ny = 0.0, nz = 0.0
        for i in polygon.indices {
            let current = polygon[i]
            let next = polygon[(i + 1) % polygon.count]
            nx += (current.y - next.y) * (current.z + next.z)
            ny += (current.z - next.z) * (current.x + next.x)
            nz += (current.x - next.x) * (current.y + next.y)
        }
        guard let normal = Self.normalize(Vec3(x: nx, y: ny, z: nz)) else { return nil }

        var seedAxis: Vec3?
        for vertex in polygon.dropFirst() {
            if let axis = Self.normalize(Self.subtract(vertex, origin)) {
                seedAxis = axis
                break
            }
        }
        guard let seed = seedAxis else { return nil }
        // Gram-Schmidt the seed against the normal so x lies exactly in-plane.
        let projected = Self.subtract(seed, Self.scale(normal, Self.dot(seed, normal)))
        guard let xAxis = Self.normalize(projected) else { return nil }
        let yAxis = Self.cross(normal, xAxis)

        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.normal = normal
    }

    func project(_ point: Vec3) -> Vec2 {
        let relative = Self.subtract(point, origin)
        return Vec2(x: Self.dot(relative, xAxis), y: Self.dot(relative, yAxis))
    }

    func unproject(_ point: Vec2) -> Vec3 {
        Vec3(
            x: origin.x + xAxis.x * point.x + yAxis.x * point.y,
            y: origin.y + xAxis.y * point.x + yAxis.y * point.y,
            z: origin.z + xAxis.z * point.x + yAxis.z * point.y
        )
    }

    // MARK: - Local vector math (kept self-contained for testability)

    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private static func scale(_ v: Vec3, _ s: Double) -> Vec3 {
        Vec3(x: v.x * s, y: v.y * s, z: v.z * s)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    private static func normalize(_ v: Vec3) -> Vec3? {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 1.0e-9 else { return nil }
        return Vec3(x: v.x / length, y: v.y / length, z: v.z / length)
    }
}
