import Foundation

/// Pure dowel edit state-machine — add / move / remove a rod from a position
/// list. Extracted from ContentView so every transition is unit-testable
/// without a running view (the GUI handlers were "correct logic" no one could
/// prove). The view layer owns the automatic→manual flip and selection; this
/// owns the geometry rules:
///   - a rod can only sit where slice material covers it (`covers`),
///   - rods can't stack closer than `threshold` (one hole per spot),
///   - grab/delete hits the NEAREST rod within `threshold`, not just the first.
enum DowelEditing {
    static func distance(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Index of the rod nearest `point`, if any lies within `threshold`.
    static func nearestIndex(to point: Vec2, in positions: [Vec2], within threshold: Double) -> Int? {
        var best: (index: Int, dist: Double)?
        for (i, p) in positions.enumerated() {
            let d = distance(p, point)
            if d < threshold, best.map({ d < $0.dist }) ?? true {
                best = (i, d)
            }
        }
        return best?.index
    }

    /// Add a rod at `point`. Rejected (nil, no change) when the point covers no
    /// slice material or sits within `threshold` of an existing rod.
    static func add(_ point: Vec2, to positions: [Vec2], threshold: Double, covers: (Vec2) -> Bool) -> [Vec2]? {
        guard covers(point) else { return nil }
        guard nearestIndex(to: point, in: positions, within: threshold) == nil else { return nil }
        return positions + [point]
    }

    /// Remove the rod nearest `point` within `threshold`. nil (no change) when
    /// none is close enough.
    static func remove(near point: Vec2, from positions: [Vec2], threshold: Double) -> [Vec2]? {
        guard let index = nearestIndex(to: point, in: positions, within: threshold) else { return nil }
        var result = positions
        result.remove(at: index)
        return result
    }

    /// Move the rod grabbed near `from` to `to`. Rejected (nil) when no rod is
    /// near `from`, or `to` covers no material (a rod threading nothing would
    /// silently vanish).
    static func move(from: Vec2, to: Vec2, in positions: [Vec2], threshold: Double, covers: (Vec2) -> Bool) -> [Vec2]? {
        guard let index = nearestIndex(to: from, in: positions, within: threshold) else { return nil }
        guard covers(to) else { return nil }
        var result = positions
        result[index] = to
        return result
    }
}
