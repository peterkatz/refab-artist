import Testing
@testable import RefabArtist

struct PanelPlaneFrameTests {
    private func approxEqual(_ a: Vec3, _ b: Vec3, tol: Double = 1.0e-9) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    @Test
    func projectThenUnprojectRoundTripsAnInPlanePolygon() throws {
        // A unit square in the z = 5 plane.
        let square = [
            Vec3(x: 1, y: 1, z: 5),
            Vec3(x: 3, y: 1, z: 5),
            Vec3(x: 3, y: 4, z: 5),
            Vec3(x: 1, y: 4, z: 5)
        ]
        let frame = try #require(PanelPlaneFrame(polygon: square))
        for vertex in square {
            let round = frame.unproject(frame.project(vertex))
            #expect(approxEqual(round, vertex, tol: 1.0e-7))
        }
        // Normal points along ±z for a z-plane polygon.
        #expect(abs(abs(frame.normal.z) - 1) < 1.0e-9)
        #expect(abs(frame.normal.x) < 1.0e-9 && abs(frame.normal.y) < 1.0e-9)
    }

    @Test
    func projectionPreservesEdgeLengthsForATiltedPanel() throws {
        // A triangle in a tilted plane; projection is isometric, so the 2D
        // edge lengths must match the 3D ones (panels keep their true size
        // when laid into their own plane for extrusion).
        let tri = [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 4, y: 0, z: 3),   // length 5 from v0
            Vec3(x: 0, y: 6, z: 0)    // length 6 from v0
        ]
        let frame = try #require(PanelPlaneFrame(polygon: tri))
        let p = tri.map(frame.project)
        func dist(_ a: Vec2, _ b: Vec2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        #expect(abs(dist(p[0], p[1]) - 5) < 1.0e-9)
        #expect(abs(dist(p[0], p[2]) - 6) < 1.0e-9)
    }

    @Test
    func degeneratePolygonsReturnNil() {
        #expect(PanelPlaneFrame(polygon: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0)]) == nil)
        let collinear = [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0)
        ]
        #expect(PanelPlaneFrame(polygon: collinear) == nil)
    }
}
