import Foundation
import Testing
@testable import RefabArtist

struct Polygon2DTests {
    private static func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

    @Test
    func clockwiseRingIsReversedAndLosesItsClosingPoint() {
        let clockwise = [Self.v(0, 0), Self.v(0, 10), Self.v(10, 10), Self.v(10, 0), Self.v(0, 0)]
        let normalized = Polygon2D.normalizedCCW(clockwise)
        #expect(normalized == [Self.v(10, 0), Self.v(10, 10), Self.v(0, 10), Self.v(0, 0)])
    }

    @Test
    func counterclockwiseRingKeepsItsOrder() {
        let ring = [Self.v(0, 0), Self.v(10, 0), Self.v(10, 10), Self.v(0, 10)]
        #expect(Polygon2D.normalizedCCW(ring) == ring)
        #expect(Polygon2D.normalizedCCW(ring + [Self.v(0, 0)]) == ring)
    }

    @Test
    func shortInputsComeBackUnchanged() {
        #expect(Polygon2D.normalizedCCW([]) == [])
        #expect(Polygon2D.normalizedCCW([Self.v(1, 2)]) == [Self.v(1, 2)])
        #expect(Polygon2D.normalizedCCW([Self.v(1, 2), Self.v(1, 2)]) == [Self.v(1, 2), Self.v(1, 2)])
        // Three points that close on themselves drop to two and stop there.
        #expect(Polygon2D.normalizedCCW([Self.v(0, 0), Self.v(5, 0), Self.v(0, 0)]) == [Self.v(0, 0), Self.v(5, 0)])
    }

    @Test
    func zeroAreaRingKeepsItsOrder() {
        let collinear = [Self.v(0, 0), Self.v(5, 0), Self.v(10, 0)]
        #expect(Polygon2D.normalizedCCW(collinear) == collinear)
    }

    @Test
    func closingPointMatchesWithinOneNanometre() {
        let ring = [Self.v(0, 0), Self.v(10, 0), Self.v(10, 10), Self.v(0, 10)]
        #expect(Polygon2D.normalizedCCW(ring + [Self.v(1.0e-9, -1.0e-9)]) == ring)
        let open = ring + [Self.v(2.0e-9, 0)]
        #expect(Polygon2D.normalizedCCW(open) == open)
    }
}
