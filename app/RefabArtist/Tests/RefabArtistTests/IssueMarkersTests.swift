import Foundation
import simd
import Testing
@testable import RefabArtist

/// Viewport issue markers: fly-to camera target math, constant on-screen
/// marker size and click picking. Pure math against `ViewportCamera.pose`
/// (the same pose the RealityKit camera is placed from).
struct IssueMarkersTests {
    private static let bounds = Bounds3D(min: Vec3(x: -20, y: -20, z: -20), max: Vec3(x: 20, y: 20, z: 20))
    private static let viewSize = CGSize(width: 900, height: 600)

    private static func site(_ id: String = "pinhole-1", at p: Vec3, size: Double = 5,
                             kind: OpeningCapper.Site.Kind = .pinhole) -> OpeningCapper.Site {
        OpeningCapper.Site(id: id, kind: kind, position: p, sizeMM: size, title: "t",
                           fixDescription: "f", elementCount: 3)
    }

    private static func length(_ v: Vec3) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
    private static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }

    @Test
    func focusPutsTheSiteAtScreenCentreAtItsFramingDistance() throws {
        let start = ViewportCameraState()
        let p = Vec3(x: 12, y: -7, z: 9)
        let target = IssueMarkers.focusState(for: Self.site(at: p, size: 5), from: start, bounds: Self.bounds)

        // View direction, spin and projection are kept.
        #expect(target.yawDegrees == start.yawDegrees)
        #expect(target.pitchDegrees == start.pitchDegrees)
        #expect(target.modelSpin == start.modelSpin)
        #expect(target.isOrthographic == start.isOrthographic)

        let pose = ViewportCamera.pose(bounds: Self.bounds, state: target)
        let screen = try #require(ViewportDowelRayPicker.project(p, viewSize: Self.viewSize, pose: pose))
        #expect(abs(screen.x - 450) < 1.0e-6)
        #expect(abs(screen.y - 300) < 1.0e-6)

        // Not clamped here: camera-to-site distance frames 4 × the size.
        #expect(target.distanceScale > 0.2 && target.distanceScale < 5)
        let expected = 20.0 / (2 * tan(21 * Double.pi / 180))
        #expect(abs(Self.length(Self.sub(pose.position, p)) - expected) < 1.0e-6)
    }

    @Test
    func focusFollowsTheModelSpin() throws {
        var start = ViewportCameraState()
        start.modelSpin = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.3, -0.5, 0.8)))
        let p = Vec3(x: -15, y: 4, z: 11)
        let target = IssueMarkers.focusState(for: Self.site(at: p, size: 8), from: start, bounds: Self.bounds)
        let world = IssueMarkers.worldPosition(p, bounds: Self.bounds, modelSpin: start.modelSpin)
        // The spun point is where the viewport draws it (root rotated about
        // the bounds centre), and the camera centres on it.
        #expect(Self.length(Self.sub(world, p)) > 1)
        let pose = ViewportCamera.pose(bounds: Self.bounds, state: target)
        let screen = try #require(ViewportDowelRayPicker.project(world, viewSize: Self.viewSize, pose: pose))
        #expect(abs(screen.x - 450) < 1.0e-3)
        #expect(abs(screen.y - 300) < 1.0e-3)
    }

    @Test
    func focusZoomStaysWithinTheCameraLimits() {
        let start = ViewportCameraState()
        let tiny = IssueMarkers.focusState(for: Self.site(at: Vec3(x: 0, y: 0, z: 0), size: 0.01), from: start, bounds: Self.bounds)
        #expect(tiny.distanceScale == 0.2)
        let huge = IssueMarkers.focusState(for: Self.site(at: Vec3(x: 0, y: 0, z: 0), size: 10_000), from: start, bounds: Self.bounds)
        #expect(huge.distanceScale == 5)
    }

    @Test
    func interpolationRunsFromStartToTargetEased() {
        let start = ViewportCameraState()
        let target = IssueMarkers.focusState(for: Self.site(at: Vec3(x: 12, y: -7, z: 9)), from: start, bounds: Self.bounds)
        #expect(IssueMarkers.interpolate(from: start, to: target, t: 0) == start)
        let end = IssueMarkers.interpolate(from: start, to: target, t: 1)
        #expect(abs(end.panX - target.panX) < 1.0e-12)
        #expect(abs(end.panY - target.panY) < 1.0e-12)
        #expect(abs(end.distanceScale - target.distanceScale) < 1.0e-12)
        let mid = IssueMarkers.interpolate(from: start, to: target, t: 0.5)
        #expect(abs(mid.distanceScale - (start.distanceScale * target.distanceScale).squareRoot()) < 1.0e-12)
        #expect(abs(mid.panX - (start.panX + target.panX) / 2) < 1.0e-12)
        #expect(IssueMarkers.easeInOut(0.25) < 0.25)
        #expect(IssueMarkers.easeInOut(0.75) > 0.75)
    }

    @Test
    func markerKeepsTheSameOnScreenSizeAtAnyZoom() {
        let p = Vec3(x: 5, y: 5, z: 5)
        for scale in [0.2, 1.0, 4.0] {
            var state = ViewportCameraState()
            state.distanceScale = scale
            let pose = ViewportCamera.pose(bounds: Self.bounds, state: state)
            let r = IssueMarkers.markerRadius(at: p, pose: pose, bounds: Self.bounds, state: state, selected: false)
            let visible = IssueMarkers.visibleHeight(at: p, pose: pose, bounds: Self.bounds, state: state)
            #expect(abs(r / visible - IssueMarkers.radiusFractionOfViewHeight) < 1.0e-12)
            let selected = IssueMarkers.markerRadius(at: p, pose: pose, bounds: Self.bounds, state: state, selected: true)
            #expect(abs(selected / r - IssueMarkers.selectedScale) < 1.0e-12)
        }
    }

    @Test
    func clickPicksTheMarkerUnderTheCursorAndMissesEmptySpace() throws {
        let state = ViewportCameraState()
        let a = Self.site("opening-1", at: Vec3(x: 10, y: 0, z: 10), kind: .opening)
        let b = Self.site("pinhole-1", at: Vec3(x: -10, y: 5, z: -8))
        let pose = ViewportCamera.pose(bounds: Self.bounds, state: state)
        let sa = try #require(IssueMarkers.project(a.position, viewSize: Self.viewSize, pose: pose, bounds: Self.bounds, state: state))
        let sb = try #require(IssueMarkers.project(b.position, viewSize: Self.viewSize, pose: pose, bounds: Self.bounds, state: state))

        let near = CGPoint(x: sa.x + 4, y: sa.y - 3)
        #expect(IssueMarkers.pick(viewPoint: near, viewSize: Self.viewSize, sites: [a, b], selectedID: nil,
                                  bounds: Self.bounds, state: state) == "opening-1")
        #expect(IssueMarkers.pick(viewPoint: sb, viewSize: Self.viewSize, sites: [a, b], selectedID: nil,
                                  bounds: Self.bounds, state: state) == "pinhole-1")
        let empty = CGPoint(x: 5, y: 5)
        #expect(IssueMarkers.pick(viewPoint: empty, viewSize: Self.viewSize, sites: [a, b], selectedID: nil,
                                  bounds: Self.bounds, state: state) == nil)
    }

    @Test
    func orthographicProjectionCentresTheFocusedSite() throws {
        var start = ViewportCameraState()
        start.isOrthographic = true
        let p = Vec3(x: -6, y: 13, z: 2)
        let target = IssueMarkers.focusState(for: Self.site(at: p), from: start, bounds: Self.bounds)
        let pose = ViewportCamera.pose(bounds: Self.bounds, state: target)
        let screen = try #require(IssueMarkers.project(p, viewSize: Self.viewSize, pose: pose, bounds: Self.bounds, state: target))
        #expect(abs(screen.x - 450) < 1.0e-6)
        #expect(abs(screen.y - 300) < 1.0e-6)
    }
}
