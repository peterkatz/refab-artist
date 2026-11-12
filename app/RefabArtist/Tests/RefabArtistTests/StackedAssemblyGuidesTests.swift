import Foundation
import Testing
@testable import RefabArtist

/// Assembly guides on Stacked parts: layer i carries the stretches of layer
/// i+1's outline that lie at least the clearance inside layer i's outline
/// (docs/specs/stacked.md §3.5).
struct StackedAssemblyGuidesTests {
    private static func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

    /// Closed rectangle, counterclockwise, with the closing point repeated
    /// (the shape the contourer emits).
    private static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SlicePath2D {
        SlicePath2D(points: [v(x0, y0), v(x1, y0), v(x1, y1), v(x0, y1), v(x0, y0)], closed: true)
    }

    /// Same rectangle wound clockwise, the way a hole often comes back.
    private static func hole(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SlicePath2D {
        SlicePath2D(points: [v(x0, y0), v(x0, y1), v(x1, y1), v(x1, y0), v(x0, y0)], closed: true)
    }

    private static func layers(_ pathsPerLayer: [[SlicePath2D]], spacing: Double = 3) -> [SliceContourLayer] {
        pathsPerLayer.enumerated().map { index, paths in
            SliceContourLayer(position: Double(index) * spacing, paths: paths)
        }
    }

    private static func isClosed(_ polyline: [Vec2]) -> Bool {
        polyline.count >= 4 && polyline.first == polyline.last
    }

    private static func near(_ a: Vec2, _ b: Vec2, _ tolerance: Double = 1.0e-3) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func length(_ polyline: [Vec2]) -> Double {
        zip(polyline, polyline.dropFirst()).reduce(0) { total, pair in
            total + ((pair.1.x - pair.0.x) * (pair.1.x - pair.0.x) + (pair.1.y - pair.0.y) * (pair.1.y - pair.0.y)).squareRoot()
        }
    }

    private static func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared)) : 0
        let dx = p.x - (a.x + t * abx), dy = p.y - (a.y + t * aby)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func distance(_ p: Vec2, toRing ring: [Vec2]) -> Double {
        ring.indices.map { distance(p, toSegment: ring[$0], ring[($0 + 1) % ring.count]) }.min() ?? .infinity
    }

    // MARK: - Nested outlines

    @Test
    func nestedSquareIsTracedWholeAndClosed() {
        let inner = Self.rect(10, 10, 30, 30)
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], [inner]]),
            clearance: 3
        )
        #expect(guides.count == 2)
        #expect(guides[0] == [inner.points])
        #expect(guides[1].isEmpty, "the last layer has no next layer to trace")
    }

    @Test
    func stepInSmallerThanTheClearanceGetsNoGuide() {
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], [Self.rect(2, 2, 38, 38)]]),
            clearance: 3
        )
        #expect(guides[0].isEmpty)
    }

    @Test
    func stepInOfExactlyTheClearanceIsTracedWhole() {
        let inner = Self.rect(3, 3, 37, 37)
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], [inner]]),
            clearance: 3
        )
        #expect(guides[0] == [inner.points])
    }

    @Test
    func identicalConsecutiveLayersGetNoGuides() {
        let square = Self.rect(0, 0, 40, 40)
        let guides = StackedAssemblyGuides.guides(for: Self.layers([[square], [square], [square]]), clearance: 3)
        #expect(guides.allSatisfy { $0.isEmpty })
    }

    @Test
    func largerNextLayerGetsNoGuide() {
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(10, 10, 30, 30)], [Self.rect(0, 0, 40, 40)]]),
            clearance: 3
        )
        #expect(guides[0].isEmpty)
    }

    // MARK: - Partial guides

    @Test
    func partialStepInIsCutAtTheClearance() {
        // The next layer's long edges sit 10 mm in, its short edges only
        // 2 mm in: only the long edges are traced, ending 3 mm from the edge.
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], [Self.rect(2, 10, 38, 30)]]),
            clearance: 3
        )
        #expect(guides[0].count == 2)
        guard guides[0].count == 2 else { return }
        let bottom = guides[0][0], top = guides[0][1]
        #expect(bottom.count == 2 && Self.near(bottom[0], Self.v(3, 10)) && Self.near(bottom[1], Self.v(37, 10)))
        #expect(top.count == 2 && Self.near(top[0], Self.v(37, 30)) && Self.near(top[1], Self.v(3, 30)))
    }

    @Test
    func pieceThroughTheLoopsFirstVertexStaysOnePolyline() {
        // A loop that starts inside the zone, runs out past the right edge
        // and comes back: one open guide, not two.
        let next = SlicePath2D(points: [Self.v(10, 10), Self.v(50, 10), Self.v(50, 30), Self.v(10, 30)], closed: true)
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], [next]]),
            clearance: 3
        )
        #expect(guides[0].count == 1)
        guard let guide = guides[0].first, guide.count == 4 else {
            Issue.record("expected one four-point guide, got \(guides[0])")
            return
        }
        #expect(Self.near(guide[0], Self.v(37, 30)))
        #expect(guide[1] == Self.v(10, 30))
        #expect(guide[2] == Self.v(10, 10))
        #expect(Self.near(guide[3], Self.v(37, 10)))
    }

    @Test
    func guidesFollowTheNextOutlineAndKeepClearOfTheEdge() {
        // A twelve-point star under a smaller, turned star: every guide point
        // lies on the next outline and at least the clearance inside the
        // current one.
        func star(scale: Double, turn: Double) -> [Vec2] {
            (0..<24).map { index in
                let angle = Double(index) * .pi / 12 + turn
                let radius = (index.isMultiple(of: 2) ? 40.0 : 25.0) * scale
                return Self.v(radius * cos(angle), radius * sin(angle))
            }
        }
        let current = star(scale: 1, turn: 0)
        let next = star(scale: 0.8, turn: 0.2)
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([
                [SlicePath2D(points: current, closed: true)],
                [SlicePath2D(points: next, closed: true)]
            ]),
            clearance: 3
        )
        #expect(!guides[0].isEmpty)
        for guide in guides[0] {
            #expect(!Self.isClosed(guide))
            for point in guide {
                #expect(Self.distance(point, toRing: next) < 1.0e-6)
                #expect(Self.distance(point, toRing: current) > 3 - 0.01)
            }
        }
    }

    // MARK: - Corners

    @Test
    func zoneHasASharpCornerAtAConcaveCorner() {
        // An L-shaped layer (a 40 mm square without its top-right quarter).
        // The zone's edges stay 3 mm off the outline's edges and meet in a
        // sharp corner at (17, 17), so the next square's corner at
        // (17.5, 17.5), 3.5 mm from the outline's inner corner, is left out.
        let ell = SlicePath2D(
            points: [Self.v(0, 0), Self.v(40, 0), Self.v(40, 20), Self.v(20, 20), Self.v(20, 40), Self.v(0, 40), Self.v(0, 0)],
            closed: true
        )
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[ell], [Self.rect(10, 10, 17.5, 17.5)]]),
            clearance: 3
        )
        #expect(guides[0].count == 1)
        guard let guide = guides[0].first, guide.count == 5 else {
            Issue.record("expected one five-point guide, got \(guides[0])")
            return
        }
        #expect(Self.near(guide[0], Self.v(17, 17.5)))
        #expect(Array(guide[1...3]) == [Self.v(10, 17.5), Self.v(10, 10), Self.v(17.5, 10)])
        #expect(Self.near(guide[4], Self.v(17.5, 17)))
    }

    @Test
    func narrowNotchIsCutSquareAtTheClearance() {
        // A V notch about 19 degrees wide reaches down to (30, 10). Its moved
        // edges would only meet far below the tip, so the zone is cut square
        // 3 mm under the tip instead: a square 4 mm below the tip is traced
        // whole, one that comes within 2.5 mm of it is cut.
        let notched = SlicePath2D(
            points: [Self.v(0, 0), Self.v(60, 0), Self.v(60, 40), Self.v(35, 40), Self.v(30, 10), Self.v(25, 40), Self.v(0, 40), Self.v(0, 0)],
            closed: true
        )
        let below = Self.rect(28, 4, 32, 6)
        let guides = StackedAssemblyGuides.guides(for: Self.layers([[notched], [below]]), clearance: 3)
        #expect(guides[0] == [below.points])

        let touching = StackedAssemblyGuides.guides(
            for: Self.layers([[notched], [Self.rect(28, 4, 32, 7.5)]]),
            clearance: 3
        )
        #expect(touching[0].count == 1)
        #expect(touching[0].allSatisfy { !Self.isClosed($0) && $0.allSatisfy { $0.y <= 7 + 1.0e-3 } })
    }

    // MARK: - Holes

    @Test
    func holeEdgeOfTheNextLayerIsTracedEvenOnTheCurrentHole() {
        // A washer stacked on an identical washer: the outer rings match, so
        // only the hole (10 mm inside the edge) is traced.
        let washer = [Self.rect(0, 0, 40, 40), Self.hole(10, 10, 30, 30)]
        let guides = StackedAssemblyGuides.guides(for: Self.layers([washer, washer]), clearance: 3)
        #expect(guides[0].count == 1)
        guard let guide = guides[0].first else { return }
        #expect(Self.isClosed(guide))
        #expect(guide.allSatisfy { [10, 30].contains($0.x) && [10, 30].contains($0.y) })
    }

    @Test
    func holesDoNotLimitTheZone() {
        // The next layer's smaller hole lies inside the current hole, where
        // there is no material; only the outer edge limits the zone, so it is
        // still traced.
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([
                [Self.rect(0, 0, 40, 40), Self.hole(10, 10, 30, 30)],
                [Self.rect(0, 0, 40, 40), Self.hole(14, 14, 26, 26)]
            ]),
            clearance: 3
        )
        #expect(guides[0].count == 1)
        #expect(guides[0].first.map(Self.length) == 48)
    }

    @Test
    func solidLayerUnderACavityCarriesTheCavityOutline() {
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([
                [Self.rect(0, 0, 50, 50)],
                [Self.rect(0, 0, 50, 50), Self.hole(10, 10, 40, 40)]
            ]),
            clearance: 3
        )
        #expect(guides[0].count == 1)
        #expect(guides[0].first.map(Self.length) == 120)
    }

    // MARK: - Several pieces

    @Test
    func disjointIslandsEachCarryTheirOwnGuide() {
        // Two pieces with a gap between them; the next layer has a square
        // inside each piece and one in the gap, which lands on nothing.
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([
                [Self.rect(0, 0, 30, 30), Self.rect(50, 0, 80, 30)],
                [Self.rect(10, 10, 20, 20), Self.rect(32, 10, 48, 20), Self.rect(60, 10, 70, 20)]
            ]),
            clearance: 3
        )
        #expect(guides[0] == [Self.rect(10, 10, 20, 20).points, Self.rect(60, 10, 70, 20).points])
    }

    @Test
    func whereTheCurrentOutlineStartsDoesNotMatter() {
        // Two 30 mm squares joined by a 4 mm bridge, as one loop: the zone
        // splits in two and both halves carry their guide, whichever vertex
        // the loop starts at and whichever way it winds.
        let corners = [
            Self.v(0, 0), Self.v(30, 0), Self.v(30, 13), Self.v(50, 13), Self.v(50, 0), Self.v(80, 0),
            Self.v(80, 30), Self.v(50, 30), Self.v(50, 17), Self.v(30, 17), Self.v(30, 30), Self.v(0, 30)
        ]
        let next = [Self.rect(10, 10, 20, 20), Self.rect(60, 10, 70, 20)]
        let expected = next.map(\.points)
        for start in corners.indices {
            let rotated = Array(corners[start...] + corners[..<start])
            for loop in [rotated, Array(rotated.reversed())] {
                let current = SlicePath2D(points: loop + [loop[0]], closed: true)
                let guides = StackedAssemblyGuides.guides(for: Self.layers([[current], next]), clearance: 3)
                #expect(guides[0] == expected, "start \(start)")
            }
        }
    }

    // MARK: - Open paths

    @Test
    func openPathsAreClosedByJoiningTheirEnds() {
        // The current layer could not be closed by the slicer; its zone is
        // the ring its ends make. The next layer's open fragments are traced
        // as open polylines.
        let current = SlicePath2D(points: [Self.v(0, 0), Self.v(40, 0), Self.v(40, 40), Self.v(0, 40)], closed: false)
        let inside = SlicePath2D(points: [Self.v(10, 20), Self.v(20, 22), Self.v(30, 20)], closed: false)
        let entering = SlicePath2D(points: [Self.v(1, 30), Self.v(10, 30), Self.v(20, 30)], closed: false)
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[current], [inside, entering]]),
            clearance: 3
        )
        #expect(guides[0].count == 2)
        guard guides[0].count == 2 else { return }
        #expect(guides[0][0] == inside.points)
        #expect(guides[0][1].count == 3)
        #expect(Self.near(guides[0][1][0], Self.v(3, 30)))
        #expect(Array(guides[0][1].dropFirst()) == [Self.v(10, 30), Self.v(20, 30)])
    }

    @Test
    func singleSegmentCrumbsAreNotTraced() {
        // Two-point fragments a broken mesh leaves behind are not guides,
        // even well inside the zone; neither is a "loop" of two points.
        let crumbs = [
            SlicePath2D(points: [Self.v(10, 20), Self.v(30, 20)], closed: false),
            SlicePath2D(points: [Self.v(10, 25), Self.v(30, 25), Self.v(10, 25)], closed: true)
        ]
        let guides = StackedAssemblyGuides.guides(
            for: Self.layers([[Self.rect(0, 0, 40, 40)], crumbs]),
            clearance: 3
        )
        #expect(guides[0].isEmpty)
    }

    // MARK: - Degenerate input

    @Test
    func degenerateInputGivesNoGuides() {
        let square = Self.rect(0, 0, 40, 40)
        let inner = Self.rect(10, 10, 30, 30)
        #expect(StackedAssemblyGuides.guides(for: [], clearance: 3).isEmpty)
        #expect(StackedAssemblyGuides.guides(for: Self.layers([[square]]), clearance: 3) == [[]])
        #expect(StackedAssemblyGuides.guides(for: Self.layers([[square], [inner]]), clearance: 0) == [[], []])
        #expect(StackedAssemblyGuides.guides(for: Self.layers([[], [inner]]), clearance: 3) == [[], []])
    }

    @Test
    func sameLayersGiveTheSameGuides() {
        let layers = Self.layers([
            [Self.rect(0, 0, 40, 40), Self.hole(15, 15, 25, 25)],
            [Self.rect(2, 8, 38, 30), Self.hole(14, 14, 26, 26)],
            [Self.rect(6, 12, 30, 26)]
        ])
        let first = StackedAssemblyGuides.guides(for: layers, clearance: 3)
        let second = StackedAssemblyGuides.guides(for: layers, clearance: 3)
        #expect(first == second)
        #expect(!first[0].isEmpty && !first[1].isEmpty && first[2].isEmpty)
    }
}
