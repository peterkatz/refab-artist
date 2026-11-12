import Foundation

/// Helpers for plain 2D polygons stored as `[Vec2]`.
enum Polygon2D {
    /// The polygon as an open ring wound counterclockwise. A closing vertex
    /// that repeats the first one (within 1e-9 on both axes) is dropped, and
    /// a ring with negative signed area is reversed. Fewer than three points
    /// come back unchanged, and so does a ring that drops below three points
    /// once its closing vertex is gone.
    static func normalizedCCW(_ points: [Vec2]) -> [Vec2] {
        guard points.count >= 3 else { return points }
        var ring = points
        if let first = ring.first, let last = ring.last,
           abs(first.x - last.x) <= 1.0e-9, abs(first.y - last.y) <= 1.0e-9 {
            ring.removeLast()
        }
        guard ring.count >= 3 else { return ring }
        var twiceSignedArea = 0.0
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            twiceSignedArea += a.x * b.y - b.x * a.y
        }
        if twiceSignedArea < 0 {
            ring.reverse()
        }
        return ring
    }
}
