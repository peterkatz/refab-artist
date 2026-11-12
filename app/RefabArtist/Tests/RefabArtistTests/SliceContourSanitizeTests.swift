import Testing
import Foundation
@testable import RefabArtist

/// `sanitizeClosedLoop` repairs the self-intersecting outlines the radial
/// half-lap notch splice produces on concave organic cross-sections (handStand
/// scan: 21/22 radial parts self-intersecting → 0/22). It MUST be a no-op on
/// already-simple loops so convex sections stay byte-identical.
struct SliceContourSanitizeTests {
    /// Count proper crossings of non-adjacent edges in a closed loop.
    private func selfIntersections(_ pts: [Vec2]) -> Int {
        func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
            func ccw(_ p: Vec2, _ q: Vec2, _ r: Vec2) -> Double {
                (r.y - p.y) * (q.x - p.x) - (q.y - p.y) * (r.x - p.x)
            }
            let d1 = ccw(c, d, a), d2 = ccw(c, d, b), d3 = ccw(a, b, c), d4 = ccw(a, b, d)
            return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0)
        }
        let n = pts.count
        var count = 0
        for i in 0..<n {
            for k in (i + 1)..<n {
                if abs(i - k) <= 1 || (i == 0 && k == n - 1) { continue }
                if cross(pts[i], pts[(i + 1) % n], pts[k], pts[(k + 1) % n]) { count += 1 }
            }
        }
        return count
    }

    @Test func simpleSquareIsUnchanged() {
        let square = [Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 4), Vec2(x: 0, y: 4)]
        let out = StackedSliceContourer.sanitizeClosedLoop(square)
        #expect(out == square)
    }

    @Test func convexPolygonIsUnchanged() {
        // A many-sided convex loop (a disk-like contour) must pass through
        // untouched — this is what keeps convex parts' bytes from moving.
        let pts = (0..<24).map { i -> Vec2 in
            let a = Double(i) / 24 * 2 * Double.pi
            return Vec2(x: 20 * cos(a), y: 20 * sin(a))
        }
        let out = StackedSliceContourer.sanitizeClosedLoop(pts)
        #expect(out == pts)
        #expect(selfIntersections(out) == 0)
    }

    @Test func bowtieIsResolvedToASimpleLoop() {
        // Classic self-crossing "bowtie": the two diagonals cross. The sanitizer
        // must snip the knot and return a simple (non-self-intersecting) loop.
        let bowtie = [Vec2(x: 0, y: 0), Vec2(x: 2, y: 0), Vec2(x: 0, y: 2), Vec2(x: 2, y: 2)]
        #expect(selfIntersections(bowtie) == 1)
        let out = StackedSliceContourer.sanitizeClosedLoop(bowtie)
        #expect(out.count >= 3)
        #expect(selfIntersections(out) == 0)
    }

    @Test func adjacentDuplicateVerticesAreDropped() {
        let dupes = [Vec2(x: 0, y: 0), Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 4), Vec2(x: 0, y: 4)]
        let out = StackedSliceContourer.sanitizeClosedLoop(dupes)
        #expect(out.count == 4)
        #expect(selfIntersections(out) == 0)
    }
}
