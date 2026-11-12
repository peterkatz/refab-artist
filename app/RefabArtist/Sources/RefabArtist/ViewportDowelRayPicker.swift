import Foundation

/// A view-space ray in scene coordinates.
struct ViewportPickRay {
    var origin: Vec3
    var direction: Vec3 // normalized
}

/// Pure-math picking for dowel editing in the 3D viewport: unproject a mouse
/// point through the analytic camera (ViewportCamera.pose, vertical fov,
/// Z-up), then test rods / the model box / drag planes. No RealityKit
/// collision components — everything here is unit-testable geometry.
enum ViewportDowelRayPicker {
    struct SurfaceHit: Equatable {
        var point: Vec3
        var normal: Vec3
        var rayT: Double
        var triangleIndex: Int
    }

    /// Must match the PerspectiveCameraComponent the viewport creates.
    static let fieldOfViewDegrees = 42.0

    /// Unproject a view point (AppKit coordinates: origin bottom-left,
    /// y up) into a scene ray. Returns nil for degenerate cameras/sizes.
    static func ray(
        viewPoint: CGPoint,
        viewSize: CGSize,
        pose: ViewportCameraPose,
        fovDegrees: Double = fieldOfViewDegrees
    ) -> ViewportPickRay? {
        let width = Double(viewSize.width)
        let height = Double(viewSize.height)
        guard width > 1, height > 1 else { return nil }

        // Camera basis exactly as RealityKit's look(at:from:up:) builds it
        // with upVector (0,0,1).
        let forward = normalize(subtract(pose.target, pose.position))
        guard isFinite(forward), length(forward) > 0.5 else { return nil }
        var right = cross(forward, Vec3(x: 0, y: 0, z: 1))
        guard length(right) > 1.0e-9 else { return nil } // looking straight up/down the Z axis
        right = normalize(right)
        let up = cross(right, forward)

        // fieldOfViewInDegrees is the VERTICAL fov; horizontal scales by
        // aspect.
        let tanY = tan(fovDegrees * .pi / 360)
        let tanX = tanY * width / height
        let ndcX = (Double(viewPoint.x) / width) * 2 - 1
        let ndcY = (Double(viewPoint.y) / height) * 2 - 1

        let direction = normalize(Vec3(
            x: forward.x + right.x * ndcX * tanX + up.x * ndcY * tanY,
            y: forward.y + right.y * ndcX * tanX + up.y * ndcY * tanY,
            z: forward.z + right.z * ndcX * tanX + up.z * ndcY * tanY
        ))
        return ViewportPickRay(origin: pose.position, direction: direction)
    }

    /// Entry point of the ray into an axis-aligned box (slab method), or nil
    /// if it misses. A ray starting inside returns its exit point.
    static func intersectBox(ray: ViewportPickRay, boxMin: Vec3, boxMax: Vec3) -> Vec3? {
        var tNear = -Double.greatestFiniteMagnitude
        var tFar = Double.greatestFiniteMagnitude
        let origins = [ray.origin.x, ray.origin.y, ray.origin.z]
        let directions = [ray.direction.x, ray.direction.y, ray.direction.z]
        let mins = [boxMin.x, boxMin.y, boxMin.z]
        let maxs = [boxMax.x, boxMax.y, boxMax.z]
        for axis in 0..<3 {
            if abs(directions[axis]) < 1.0e-12 {
                if origins[axis] < mins[axis] || origins[axis] > maxs[axis] { return nil }
                continue
            }
            var t0 = (mins[axis] - origins[axis]) / directions[axis]
            var t1 = (maxs[axis] - origins[axis]) / directions[axis]
            if t0 > t1 { swap(&t0, &t1) }
            tNear = max(tNear, t0)
            tFar = min(tFar, t1)
            if tNear > tFar { return nil }
        }
        guard tFar >= 0 else { return nil }
        let t = tNear >= 0 ? tNear : tFar
        return point(on: ray, at: t)
    }

    /// Shortest distance between the ray and a segment, with the ray
    /// parameter of the closest approach (for nearest-rod ordering).
    static func distanceToSegment(ray: ViewportPickRay, a: Vec3, b: Vec3) -> (distance: Double, rayT: Double) {
        let u = ray.direction
        let v = subtract(b, a)
        let w = subtract(ray.origin, a)
        let uu = dot(u, u)
        let uv = dot(u, v)
        let vv = dot(v, v)
        let uw = dot(u, w)
        let vw = dot(v, w)
        let denominator = uu * vv - uv * uv

        var s: Double // segment parameter [0,1]
        var t: Double // ray parameter [0,inf)
        if denominator < 1.0e-12 || vv < 1.0e-12 {
            // Parallel or degenerate segment: clamp to endpoint A.
            s = 0
            t = max(0, -uw / max(uu, 1.0e-12))
        } else {
            s = (uu * vw - uv * uw) / denominator
            s = min(1, max(0, s))
            t = max(0, (s * uv - uw) / uu)
        }
        let closestOnRay = point(on: ray, at: t)
        let closestOnSegment = Vec3(x: a.x + v.x * s, y: a.y + v.y * s, z: a.z + v.z * s)
        return (length(subtract(closestOnRay, closestOnSegment)), t)
    }

    /// Ray-plane intersection (plane through `point` with `normal`), or nil
    /// when parallel / behind the origin.
    static func intersectPlane(ray: ViewportPickRay, planePoint: Vec3, planeNormal: Vec3) -> Vec3? {
        let denominator = dot(ray.direction, planeNormal)
        guard abs(denominator) > 1.0e-9 else { return nil }
        let t = dot(subtract(planePoint, ray.origin), planeNormal) / denominator
        guard t >= 0 else { return nil }
        return point(on: ray, at: t)
    }

    /// Project a scene point back to view coordinates (the exact inverse of
    /// `ray`). nil when the point sits at/behind the camera.
    static func project(
        _ scenePoint: Vec3,
        viewSize: CGSize,
        pose: ViewportCameraPose,
        fovDegrees: Double = fieldOfViewDegrees
    ) -> CGPoint? {
        let width = Double(viewSize.width)
        let height = Double(viewSize.height)
        guard width > 1, height > 1 else { return nil }
        let forward = normalize(subtract(pose.target, pose.position))
        guard isFinite(forward), length(forward) > 0.5 else { return nil }
        var right = cross(forward, Vec3(x: 0, y: 0, z: 1))
        guard length(right) > 1.0e-9 else { return nil }
        right = normalize(right)
        let up = cross(right, forward)

        let relative = subtract(scenePoint, pose.position)
        let depth = dot(relative, forward)
        guard depth > 1.0e-6 else { return nil }
        let tanY = tan(fovDegrees * .pi / 360)
        let tanX = tanY * width / height
        let ndcX = dot(relative, right) / (depth * tanX)
        let ndcY = dot(relative, up) / (depth * tanY)
        return CGPoint(x: (ndcX + 1) / 2 * width, y: (ndcY + 1) / 2 * height)
    }

    /// Distance in VIEW POINTS from a cursor position to the screen-space
    /// projection of a scene segment — rod grabbing measured in pixels stays
    /// equally forgiving at any zoom level (a fixed scene-space radius shrank
    /// to nothing zoomed out, which made selection clicks land as adds).
    static func viewDistanceToSegment(
        viewPoint: CGPoint,
        a: Vec3,
        b: Vec3,
        viewSize: CGSize,
        pose: ViewportCameraPose
    ) -> Double? {
        guard let pa = project(a, viewSize: viewSize, pose: pose),
              let pb = project(b, viewSize: viewSize, pose: pose) else { return nil }
        let vx = Double(pb.x - pa.x)
        let vy = Double(pb.y - pa.y)
        let wx = Double(viewPoint.x - pa.x)
        let wy = Double(viewPoint.y - pa.y)
        let vv = vx * vx + vy * vy
        let t = vv > 1.0e-12 ? min(1, max(0, (wx * vx + wy * vy) / vv)) : 0
        let dx = wx - vx * t
        let dy = wy - vy * t
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The drag plane for moving a rod. A rod moves in the SLICE PLANE (its
    /// two plan coordinates), so the drag plane's normal is the rod axis —
    /// the cursor ray maps to both axes at once. (The old camera-facing
    /// plane CONTAINED the rod axis; flattening its hits to plan coordinates
    /// collapsed one direction, which is why rods only moved along a single
    /// axis.) Only when the view is nearly edge-on to the slice plane does
    /// the camera-facing plane return, to keep the drag numerically stable.
    static func dragPlaneNormal(rodAxis: Vec3, cameraForward: Vec3) -> Vec3 {
        let forward = normalize(cameraForward)
        if abs(dot(forward, rodAxis)) > 0.08 {
            return rodAxis
        }
        let axisComponent = dot(cameraForward, rodAxis)
        let projected = Vec3(
            x: cameraForward.x - rodAxis.x * axisComponent,
            y: cameraForward.y - rodAxis.y * axisComponent,
            z: cameraForward.z - rodAxis.z * axisComponent
        )
        guard length(projected) > 1.0e-9 else {
            // Camera looking straight down the rod: any perpendicular works.
            let fallback = cross(rodAxis, Vec3(x: 0, y: 0, z: 1))
            return length(fallback) > 1.0e-9 ? normalize(fallback) : Vec3(x: 1, y: 0, z: 0)
        }
        return normalize(projected)
    }

    /// The visible point of a stacked slice stack under the cursor: intersect
    /// the ray with every layer's slice plane and keep the FIRST hit whose
    /// plan point lies inside that layer's material. Hitting actual slice
    /// material (not a bounding box) keeps the added rod under the cursor —
    /// a box face hit is offset by parallax and usually covers nothing.
    static func firstMaterialHit(
        ray: ViewportPickRay,
        layers: [SliceContourLayer],
        axis: SliceAxis
    ) -> Vec2? {
        let originAxis = axisComponent(ray.origin, axis: axis)
        let directionAxis = axisComponent(ray.direction, axis: axis)
        guard abs(directionAxis) > 1.0e-9 else { return nil } // ray parallel to the slabs
        var best: (t: Double, plan: Vec2)?
        for layer in layers {
            let t = (layer.position - originAxis) / directionAxis
            guard t > 0 else { continue }
            if let best, t >= best.t { continue }
            let plan = planPoint(fromScene: point(on: ray, at: t), axis: axis)
            if !DowelLayout.positionsCovered(by: layer, positions: [plan]).isEmpty {
                best = (t, plan)
            }
        }
        return best?.plan
    }

    /// Nearest actual triangle under a scene ray. This deliberately uses the
    /// imported mesh instead of its bounding box so click placement lands on
    /// the sculpture surface. It runs only on mouse-up, never per frame.
    static func intersectMeshSurface(
        ray: ViewportPickRay,
        geometry: MeshGeometryData
    ) -> SurfaceHit? {
        guard geometry.triangleIndices.count >= 3 else { return nil }
        var nearest: SurfaceHit?

        for base in stride(from: 0, to: geometry.triangleIndices.count - 2, by: 3) {
            let rawA = geometry.triangleIndices[base]
            let rawB = geometry.triangleIndices[base + 1]
            let rawC = geometry.triangleIndices[base + 2]
            guard rawA >= 0, rawB >= 0, rawC >= 0 else { continue }
            let ia = Int(rawA), ib = Int(rawB), ic = Int(rawC)
            guard ia < geometry.vertices.count,
                  ib < geometry.vertices.count,
                  ic < geometry.vertices.count else { continue }

            let a = geometry.vertices[ia]
            let edgeAB = subtract(geometry.vertices[ib], a)
            let edgeAC = subtract(geometry.vertices[ic], a)
            let p = cross(ray.direction, edgeAC)
            let determinant = dot(edgeAB, p)
            guard abs(determinant) > 1.0e-12 else { continue }
            let inverseDeterminant = 1 / determinant
            let fromA = subtract(ray.origin, a)
            let u = dot(fromA, p) * inverseDeterminant
            guard u >= -1.0e-9, u <= 1 + 1.0e-9 else { continue }
            let q = cross(fromA, edgeAB)
            let v = dot(ray.direction, q) * inverseDeterminant
            guard v >= -1.0e-9, u + v <= 1 + 1.0e-9 else { continue }
            let t = dot(edgeAC, q) * inverseDeterminant
            guard t > 1.0e-9, t < (nearest?.rayT ?? .greatestFiniteMagnitude) else { continue }

            var normal = normalize(cross(edgeAB, edgeAC))
            guard length(normal) > 0.5 else { continue }
            // A visible surface's placement axis should face the artist even
            // when a source mesh has inconsistent triangle winding.
            if dot(normal, ray.direction) > 0 {
                normal = Vec3(x: -normal.x, y: -normal.y, z: -normal.z)
            }
            nearest = SurfaceHit(
                point: point(on: ray, at: t),
                normal: normal,
                rayT: t,
                triangleIndex: base / 3
            )
        }
        return nearest
    }

    static func axisComponent(_ v: Vec3, axis: SliceAxis) -> Double {
        switch axis {
        case .x: return v.x
        case .y: return v.y
        case .z: return v.z
        }
    }

    // MARK: - Plan <-> scene mapping (mirrors ModelSceneView.scenePoint)

    static func scenePoint(_ point: Vec2, axis: SliceAxis, position: Double) -> Vec3 {
        switch axis {
        case .x: return Vec3(x: position, y: point.x, z: point.y)
        case .y: return Vec3(x: point.x, y: position, z: point.y)
        case .z: return Vec3(x: point.x, y: point.y, z: position)
        }
    }

    static func planPoint(fromScene scene: Vec3, axis: SliceAxis) -> Vec2 {
        switch axis {
        case .x: return Vec2(x: scene.y, y: scene.z)
        case .y: return Vec2(x: scene.x, y: scene.z)
        case .z: return Vec2(x: scene.x, y: scene.y)
        }
    }

    // MARK: - Small vector helpers (Vec3 has no operators)

    static func point(on ray: ViewportPickRay, at t: Double) -> Vec3 {
        Vec3(
            x: ray.origin.x + ray.direction.x * t,
            y: ray.origin.y + ray.direction.y * t,
            z: ray.origin.z + ray.direction.z * t
        )
    }

    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func length(_ v: Vec3) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    private static func normalize(_ v: Vec3) -> Vec3 {
        let l = length(v)
        guard l > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 0) }
        return Vec3(x: v.x / l, y: v.y / l, z: v.z / l)
    }

    private static func isFinite(_ v: Vec3) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
