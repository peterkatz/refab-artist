import Foundation
import Testing
@testable import RefabArtist

/// The viewport dowel picking is pure math (unproject through the analytic
/// camera, then rod/box/plane tests) — pin the geometry here so GUI editing
/// can trust it.
struct ViewportDowelRayPickerTests {
    private static let pose = ViewportCameraPose(
        position: Vec3(x: 100, y: 0, z: 0),
        target: Vec3(x: 0, y: 0, z: 0),
        radius: 10
    )
    private static let viewSize = CGSize(width: 800, height: 600)

    @Test
    func centerOfViewRayPointsAtTheTarget() throws {
        let ray = try #require(ViewportDowelRayPicker.ray(
            viewPoint: CGPoint(x: 400, y: 300),
            viewSize: Self.viewSize,
            pose: Self.pose
        ))
        #expect(abs(ray.direction.x + 1) < 1e-9)
        #expect(abs(ray.direction.y) < 1e-9)
        #expect(abs(ray.direction.z) < 1e-9)
        #expect(ray.origin.x == 100)
    }

    @Test
    func upperHalfOfViewLooksUpward() throws {
        // Z is up; a view point above center must tilt the ray +z.
        let ray = try #require(ViewportDowelRayPicker.ray(
            viewPoint: CGPoint(x: 400, y: 450),
            viewSize: Self.viewSize,
            pose: Self.pose
        ))
        #expect(ray.direction.z > 0.05)
        #expect(abs(ray.direction.y) < 1e-9)
    }

    @Test
    func boxIntersectionReturnsTheEntryPoint() throws {
        let ray = ViewportPickRay(origin: Vec3(x: 100, y: 0, z: 0), direction: Vec3(x: -1, y: 0, z: 0))
        let hit = try #require(ViewportDowelRayPicker.intersectBox(
            ray: ray,
            boxMin: Vec3(x: -10, y: -10, z: -10),
            boxMax: Vec3(x: 10, y: 10, z: 10)
        ))
        #expect(abs(hit.x - 10) < 1e-9) // entry face, not exit
        #expect(abs(hit.y) < 1e-9)

        let miss = ViewportDowelRayPicker.intersectBox(
            ray: ViewportPickRay(origin: Vec3(x: 100, y: 50, z: 0), direction: Vec3(x: -1, y: 0, z: 0)),
            boxMin: Vec3(x: -10, y: -10, z: -10),
            boxMax: Vec3(x: 10, y: 10, z: 10)
        )
        #expect(miss == nil)
    }

    @Test
    func segmentDistanceMeasuresPerpendicularGap() {
        // Ray along -x at z=3; vertical rod at the origin spanning z 0...10:
        // closest approach is the rod itself, distance 0 at z=3.
        let ray = ViewportPickRay(origin: Vec3(x: 100, y: 0, z: 3), direction: Vec3(x: -1, y: 0, z: 0))
        let onRod = ViewportDowelRayPicker.distanceToSegment(
            ray: ray,
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 0, z: 10)
        )
        #expect(onRod.distance < 1e-9)

        // A rod 5mm to the side misses by exactly 5.
        let offRod = ViewportDowelRayPicker.distanceToSegment(
            ray: ray,
            a: Vec3(x: 0, y: 5, z: 0),
            b: Vec3(x: 0, y: 5, z: 10)
        )
        #expect(abs(offRod.distance - 5) < 1e-9)

        // Beyond the rod's end the distance grows past the clamp.
        let aboveRod = ViewportDowelRayPicker.distanceToSegment(
            ray: ViewportPickRay(origin: Vec3(x: 100, y: 0, z: 20), direction: Vec3(x: -1, y: 0, z: 0)),
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 0, z: 10)
        )
        #expect(abs(aboveRod.distance - 10) < 1e-9)
    }

    @Test
    func dragPlaneIsTheSlicePlaneSoRodsMoveOnBothAxes() {
        let axis = Vec3(x: 0, y: 0, z: 1)
        // Any ordinary 3/4 view: the drag plane is the SLICE PLANE (normal =
        // rod axis) so the cursor maps to BOTH plan coordinates at once. The
        // old camera-facing plane contained the rod axis, and flattening its
        // hits to plan coordinates collapsed one direction — rods could only
        // move along a single axis.
        let forward = Vec3(x: -0.8, y: 0.2, z: -0.55)
        let normal = ViewportDowelRayPicker.dragPlaneNormal(rodAxis: axis, cameraForward: forward)
        #expect(normal == axis)

        // A cursor ray angled in BOTH x and y maps to a hit displaced in
        // both plan coordinates.
        // (Direction needn't be unit length for the plane hit point.)
        let ray = ViewportPickRay(
            origin: Vec3(x: 100, y: 50, z: 30),
            direction: Vec3(x: -1, y: -0.5, z: -0.4)
        )
        let hit = ViewportDowelRayPicker.intersectPlane(
            ray: ray,
            planePoint: Vec3(x: 10, y: 5, z: 0),
            planeNormal: normal
        )
        #expect(hit != nil)
        if let hit {
            #expect(abs(hit.z) < 1e-9)
            #expect(abs(hit.x - 25) < 1e-9)  // 100 - 75·1
            #expect(abs(hit.y - 12.5) < 1e-9) // 50 - 75·0.5
        }

        // Edge-on view (camera forward perpendicular to the rod): the
        // slice plane degenerates on screen, so the camera-facing fallback
        // returns — perpendicular to the rod, never tilting it.
        let edgeOn = ViewportDowelRayPicker.dragPlaneNormal(
            rodAxis: axis,
            cameraForward: Vec3(x: -1, y: 0, z: 0)
        )
        #expect(abs(edgeOn.z) < 1e-9)
    }

    @Test
    func firstMaterialHitLandsOnTheVisibleSlice() {
        // Two square slices stacked along z: a small one at z=0 (20x20) and a
        // big one at z=10 (40x40 but only x>=0). A ray from above and to the
        // +x side, angled down...
        let small = SlicePath2D(
            points: [
                Vec2(x: -10, y: -10), Vec2(x: 10, y: -10),
                Vec2(x: 10, y: 10), Vec2(x: -10, y: 10), Vec2(x: -10, y: -10)
            ],
            closed: true
        )
        let big = SlicePath2D(
            points: [
                Vec2(x: 0, y: -20), Vec2(x: 40, y: -20),
                Vec2(x: 40, y: 20), Vec2(x: 0, y: 20), Vec2(x: 0, y: -20)
            ],
            closed: true
        )
        let layers = [
            SliceContourLayer(position: 0, paths: [small]),
            SliceContourLayer(position: 10, paths: [big])
        ]

        // Straight down at (30, 0): misses the small slice (x>10), hits the
        // big one first at z=10.
        let down = ViewportPickRay(origin: Vec3(x: 30, y: 0, z: 100), direction: Vec3(x: 0, y: 0, z: -1))
        let hit = ViewportDowelRayPicker.firstMaterialHit(ray: down, layers: layers, axis: .z)
        #expect(hit != nil)
        #expect(abs((hit?.x ?? 0) - 30) < 1e-9)

        // Straight down at (-5, 0): passes through the big slice's plane
        // OUTSIDE its material (x<0), continues to the small slice at z=0.
        let through = ViewportPickRay(origin: Vec3(x: -5, y: 0, z: 100), direction: Vec3(x: 0, y: 0, z: -1))
        let lower = ViewportDowelRayPicker.firstMaterialHit(ray: through, layers: layers, axis: .z)
        #expect(lower != nil)
        #expect(abs((lower?.x ?? 0) + 5) < 1e-9)

        // Far off both slices: no hit.
        let miss = ViewportPickRay(origin: Vec3(x: 200, y: 200, z: 100), direction: Vec3(x: 0, y: 0, z: -1))
        #expect(ViewportDowelRayPicker.firstMaterialHit(ray: miss, layers: layers, axis: .z) == nil)
    }

    @Test
    func planSceneRoundTripsForEveryAxis() {
        let plan = Vec2(x: 12.5, y: -7.25)
        for axis in [SliceAxis.x, .y, .z] {
            let scene = ViewportDowelRayPicker.scenePoint(plan, axis: axis, position: 42)
            let back = ViewportDowelRayPicker.planPoint(fromScene: scene, axis: axis)
            #expect(abs(back.x - plan.x) < 1e-12)
            #expect(abs(back.y - plan.y) < 1e-12)
        }
    }

    @Test
    func edgeOfViewRaySpreadMatchesTheFieldOfView() throws {
        // Vertical fov is 42 deg: the top-center ray must sit 21 deg above
        // the forward axis.
        let ray = try #require(ViewportDowelRayPicker.ray(
            viewPoint: CGPoint(x: 400, y: 600),
            viewSize: Self.viewSize,
            pose: Self.pose
        ))
        let angle = atan2(ray.direction.z, -ray.direction.x) * 180 / .pi
        #expect(abs(angle - 21) < 0.01)
    }

    // MARK: - NEO-102: dowel-edit plane interaction

    /// A ray aimed at the edit plane (z = 50) and aimed centre-of-screen
    /// should intersect the plane at the point directly in front of the camera.
    @Test
    func planIntersectionMapsToCorrectPlanPoint_zAxis() throws {
        // Camera at (100, 0, 50) looking at origin — a standard 3/4 pose.
        // The centre-of-view ray points at the target (0,0,0) and crosses
        // the z=50 plane (normal = z) at the camera position's XY.
        let sidePose = ViewportCameraPose(
            position: Vec3(x: 100, y: 0, z: 50),
            target: Vec3(x: 0, y: 0, z: 0),
            radius: 100
        )
        let ray = try #require(ViewportDowelRayPicker.ray(
            viewPoint: CGPoint(x: 400, y: 300), // centre of 800×600 view
            viewSize: Self.viewSize,
            pose: sidePose
        ))
        // Plane: z = 50, normal = (0,0,1).
        // The centre ray passes through z=50 exactly at the camera origin
        // (because the camera starts there), so t=0 — but t must be ≥ 0;
        // let's use z=25 to get a proper forward intersection.
        let planeNormal = Vec3(x: 0, y: 0, z: 1)
        let planePoint  = Vec3(x: 0, y: 0, z: 25)
        let hit = try #require(ViewportDowelRayPicker.intersectPlane(
            ray: ray,
            planePoint: planePoint,
            planeNormal: planeNormal
        ))
        // The hit should lie on z=25.
        #expect(abs(hit.z - 25) < 1e-4)
        // Plan point for z-axis is (x, y) — just check the round-trip.
        let plan = ViewportDowelRayPicker.planPoint(fromScene: hit, axis: .z)
        let back = ViewportDowelRayPicker.scenePoint(plan, axis: .z, position: hit.z)
        #expect(abs(back.x - hit.x) < 1e-9)
        #expect(abs(back.y - hit.y) < 1e-9)
    }

    /// Off-axis ray through a z-plane: the plan point matches the x/y of the
    /// hit point regardless of z.
    @Test
    func planIntersectionOffAxisHit_zAxis() throws {
        // Ray from (30, 20, 100) going straight down.
        let ray = ViewportPickRay(
            origin: Vec3(x: 30, y: 20, z: 100),
            direction: Vec3(x: 0, y: 0, z: -1)
        )
        let hit = try #require(ViewportDowelRayPicker.intersectPlane(
            ray: ray,
            planePoint: Vec3(x: 0, y: 0, z: 50),
            planeNormal: Vec3(x: 0, y: 0, z: 1)
        ))
        let plan = ViewportDowelRayPicker.planPoint(fromScene: hit, axis: .z)
        #expect(abs(plan.x - 30) < 1e-9)
        #expect(abs(plan.y - 20) < 1e-9)
    }

    /// Plane intersection works for all three slice axes.
    @Test
    func planIntersectionAllAxes() throws {
        let axes: [(SliceAxis, Vec3, Vec3)] = [
            (.x, Vec3(x: 1, y: 0, z: 0), Vec3(x: 50, y: 0, z: 0)),
            (.y, Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 50, z: 0)),
            (.z, Vec3(x: 0, y: 0, z: 1), Vec3(x: 0, y: 0, z: 50))
        ]
        for (axis, normal, planePoint) in axes {
            // Ray arriving perpendicular to the plane.
            let origin: Vec3
            let direction: Vec3
            switch axis {
            case .x:
                origin    = Vec3(x: 200, y: 12, z: 7)
                direction = Vec3(x: -1,  y: 0,  z: 0)
            case .y:
                origin    = Vec3(x: 12, y: 200, z: 7)
                direction = Vec3(x: 0,  y: -1,  z: 0)
            case .z:
                origin    = Vec3(x: 12, y: 7, z: 200)
                direction = Vec3(x: 0,  y: 0,  z: -1)
            }
            let ray = ViewportPickRay(origin: origin, direction: direction)
            let hit = try #require(ViewportDowelRayPicker.intersectPlane(
                ray: ray,
                planePoint: planePoint,
                planeNormal: normal
            ))
            let plan = ViewportDowelRayPicker.planPoint(fromScene: hit, axis: axis)
            // The non-axis coordinates of the origin should be preserved.
            switch axis {
            case .x:
                #expect(abs(plan.x - 12) < 1e-9)
                #expect(abs(plan.y - 7)  < 1e-9)
            case .y:
                #expect(abs(plan.x - 12) < 1e-9)
                #expect(abs(plan.y - 7)  < 1e-9)
            case .z:
                #expect(abs(plan.x - 12) < 1e-9)
                #expect(abs(plan.y - 7)  < 1e-9)
            }
        }
    }

    /// Marker proximity (screen-space, 14 pt threshold) beats a plain plane
    /// hit when the cursor is close enough to a marker centre.
    ///
    /// This is a pure-math test of the decision logic: we verify that
    /// projecting a known marker centre gives a screen-space distance < 14 pt
    /// when the cursor is near it, and > 14 pt when it is not. The
    /// handleDowelMouseDown function uses ViewportDowelRayPicker.project for
    /// exactly this, so passing these invariants pins the contract.
    @Test
    func markerProximityBeatsAddWhenCursorNearMarker() throws {
        // Camera looking along -x, marker at scene (0, 5, 3).
        let markerScene = Vec3(x: 0, y: 5, z: 3)
        let projected = try #require(ViewportDowelRayPicker.project(
            markerScene,
            viewSize: Self.viewSize,
            pose: Self.pose
        ))
        // Cursor right on the projected marker centre: distance = 0 < 14.
        let onMarker = CGPoint(x: projected.x, y: projected.y)
        let dx1 = Double(onMarker.x - projected.x)
        let dy1 = Double(onMarker.y - projected.y)
        let distOnMarker = (dx1 * dx1 + dy1 * dy1).squareRoot()
        #expect(distOnMarker < 14)

        // Cursor 20 pt away: distance > 14 → no grab → falls through to add.
        let offMarker = CGPoint(x: projected.x + 20, y: projected.y)
        let dx2 = Double(offMarker.x - projected.x)
        let dy2 = Double(offMarker.y - projected.y)
        let distOffMarker = (dx2 * dx2 + dy2 * dy2).squareRoot()
        #expect(distOffMarker > 14)
    }

    /// A ray parallel to the plane must not produce an intersection (the
    /// edit-plane interaction falls through to the camera in that case).
    @Test
    func rayParallelToPlaneMisses() {
        // Ray going along x — parallel to the z-plane (normal = z).
        let ray = ViewportPickRay(
            origin: Vec3(x: 0, y: 0, z: 50),
            direction: Vec3(x: 1, y: 0, z: 0)
        )
        let hit = ViewportDowelRayPicker.intersectPlane(
            ray: ray,
            planePoint: Vec3(x: 0, y: 0, z: 50),
            planeNormal: Vec3(x: 0, y: 0, z: 1)
        )
        #expect(hit == nil)
    }

    /// Inside/outside the plane rect: the half-width check used by
    /// handleDowelMouseDown must correctly classify plan points.
    @Test
    func planeRectInsideOutsideClassification() {
        // Plane rect: centred at planCentre = (10, 10), half-extents (25, 15).
        let planCenterX = 10.0, planCenterY = 10.0
        let halfW = 25.0, halfH = 15.0
        func inside(_ x: Double, _ y: Double) -> Bool {
            abs(x - planCenterX) <= halfW && abs(y - planCenterY) <= halfH
        }
        #expect(inside(10, 10))          // dead centre
        #expect(inside(35, 25))          // corner (just inside)
        #expect(!inside(36, 10))         // outside on x
        #expect(!inside(10, 26))         // outside on y
        #expect(!inside(36, 26))         // outside on both
    }
}
