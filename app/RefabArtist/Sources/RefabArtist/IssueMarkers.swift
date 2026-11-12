import AppKit
import Foundation
import simd

/// Viewport issue markers (the "Model Health" markers — Meshmixer Inspector
/// pattern): one clickable dot per `OpeningCapper.Site`, drawn on top of the
/// model at a constant on-screen size, plus the fly-to camera move a click
/// makes. Everything here is pure math / styling so it can be unit tested;
/// `ModelSceneView` owns the entities and `ContentView` owns the selection.
enum IssueMarkers {
    /// A request to frame one site. `nonce` changes on every request, so
    /// clicking the same row twice flies there again.
    struct FocusRequest: Equatable {
        var siteID: String
        var nonce: Int
    }

    // MARK: Style

    /// Marker colour per kind: openings blue, pinholes / seams cyan,
    /// non-manifold red, doubled orange, loose magenta, flipped yellow.
    static func color(for kind: OpeningCapper.Site.Kind) -> NSColor {
        switch kind {
        case .opening: return NSColor(calibratedRed: 0.16, green: 0.42, blue: 1.00, alpha: 1)
        case .pinhole, .seam: return NSColor(calibratedRed: 0.05, green: 0.82, blue: 0.92, alpha: 1)
        case .nonManifoldSpot: return NSColor(calibratedRed: 0.93, green: 0.16, blue: 0.14, alpha: 1)
        case .doubledTriangles: return NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.08, alpha: 1)
        case .looseFragment: return NSColor(calibratedRed: 0.90, green: 0.20, blue: 0.86, alpha: 1)
        case .flippedPiece: return NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.10, alpha: 1)
        }
    }

    /// Legend / list label for a kind.
    static func label(for kind: OpeningCapper.Site.Kind) -> String {
        switch kind {
        case .opening: return "Opening"
        case .pinhole: return "Pinhole"
        case .seam: return "Open seam"
        case .nonManifoldSpot: return "Damaged spot"
        case .doubledTriangles: return "Doubled triangles"
        case .looseFragment: return "Loose fragment"
        case .flippedPiece: return "Flipped"
        }
    }

    /// Marker radius as a fraction of the visible view HEIGHT (so a marker is
    /// ~2.4 % of the viewport tall at any zoom — about 16 pt in a 700 pt
    /// viewport). The selected marker is drawn larger.
    static let radiusFractionOfViewHeight = 0.012
    static let selectedScale = 1.55

    // MARK: Frames

    /// Where a model-frame point sits in the scene: the viewport rotates the
    /// model root by the SpaceMouse spin about the viewport bounds' centre
    /// (`ModelSceneView.applyModelSpin`).
    static func worldPosition(_ point: Vec3, bounds: Bounds3D?, modelSpin: simd_quatf) -> Vec3 {
        let c = center(bounds)
        let p = SIMD3<Double>(point.x, point.y, point.z) - c
        let q = simd_quatd(ix: Double(modelSpin.imag.x), iy: Double(modelSpin.imag.y),
                           iz: Double(modelSpin.imag.z), r: Double(modelSpin.real))
        let r = q.act(p) + c
        return Vec3(x: r.x, y: r.y, z: r.z)
    }

    /// Visible view height (scene units) at `point`: perspective grows with
    /// depth along the view axis; orthographic is constant.
    static func visibleHeight(at point: Vec3, pose: ViewportCameraPose, bounds: Bounds3D?,
                              state: ViewportCameraState) -> Double {
        if state.isOrthographic {
            return ViewportCamera.orthographicViewHeight(bounds: bounds, state: state)
        }
        let forward = normalized(sub(pose.target, pose.position))
        let depth = max(1.0e-6, dot(sub(point, pose.position), forward))
        return 2 * depth * tan(ViewportDowelRayPicker.fieldOfViewDegrees * .pi / 360)
    }

    /// Marker radius in scene units at `worldPoint` for the current camera.
    static func markerRadius(at worldPoint: Vec3, pose: ViewportCameraPose, bounds: Bounds3D?,
                             state: ViewportCameraState, selected: Bool) -> Double {
        let r = radiusFractionOfViewHeight * visibleHeight(at: worldPoint, pose: pose, bounds: bounds, state: state)
        return selected ? r * selectedScale : r
    }

    /// Project a scene point to view coordinates (AppKit: origin bottom-left)
    /// for either projection. nil when it sits behind a perspective camera.
    static func project(_ worldPoint: Vec3, viewSize: CGSize, pose: ViewportCameraPose,
                        bounds: Bounds3D?, state: ViewportCameraState) -> CGPoint? {
        guard !state.isOrthographic else {
            let width = Double(viewSize.width), height = Double(viewSize.height)
            guard width > 1, height > 1 else { return nil }
            let viewHeight = ViewportCamera.orthographicViewHeight(bounds: bounds, state: state)
            guard viewHeight > 0 else { return nil }
            let rel = sub(worldPoint, pose.target)
            let ndcY = dot(rel, pose.up) / (viewHeight / 2)
            let ndcX = dot(rel, pose.right) / (viewHeight / 2 * width / height)
            return CGPoint(x: (ndcX + 1) / 2 * width, y: (ndcY + 1) / 2 * height)
        }
        return ViewportDowelRayPicker.project(worldPoint, viewSize: viewSize, pose: pose)
    }

    /// The site under a click: the marker whose projected centre is nearest
    /// the click, within its on-screen radius plus a few points of slack.
    /// The selected marker (drawn on top, larger) wins; among markers at
    /// (nearly) the same spot, the one drawn last — on top — wins.
    static func pick(viewPoint: CGPoint, viewSize: CGSize, sites: [OpeningCapper.Site],
                     selectedID: String?, bounds: Bounds3D?, state: ViewportCameraState) -> String? {
        let pose = ViewportCamera.pose(bounds: bounds, state: state)
        let slack = 5.0
        var best: (id: String, distance: Double, selected: Bool)? = nil
        for site in sites {
            let world = worldPosition(site.position, bounds: bounds, modelSpin: state.modelSpin)
            guard let screen = project(world, viewSize: viewSize, pose: pose, bounds: bounds, state: state) else { continue }
            let selected = site.id == selectedID
            let radiusPoints = (selected ? selectedScale : 1) * radiusFractionOfViewHeight * Double(viewSize.height)
            let d = hypot(Double(screen.x - viewPoint.x), Double(screen.y - viewPoint.y))
            guard d <= radiusPoints + slack else { continue }
            if let current = best {
                if selected && !current.selected { best = (site.id, d, true); continue }
                if current.selected && !selected { continue }
                if d > current.distance + 1 { continue }
            }
            best = (site.id, d, selected)
        }
        return best?.id
    }

    // MARK: Fly-to

    /// Share of the view height a framed site (plus context) fills.
    static let framingSizeMultiple = 4.0
    /// Smallest region framed, as a fraction of the model radius, so a
    /// sub-millimetre spot doesn't dive into the surface.
    static let minimumFramedFractionOfRadius = 0.12

    /// The camera that frames `site`: same view direction, spin and
    /// projection; pan puts the site on the view axis (screen centre); zoom
    /// sets the camera-to-site distance from the site's size (within the
    /// camera's zoom limits).
    static func focusState(for site: OpeningCapper.Site, from state: ViewportCameraState,
                           bounds: Bounds3D?) -> ViewportCameraState {
        let world = worldPosition(site.position, bounds: bounds, modelSpin: state.modelSpin)
        return focusState(worldPoint: world, size: site.sizeMM, from: state, bounds: bounds)
    }

    static func focusState(worldPoint: Vec3, size: Double, from state: ViewportCameraState,
                           bounds: Bounds3D?) -> ViewportCameraState {
        let radius = ViewportCamera.radius(bounds: bounds)
        let c = center(bounds)
        let yaw = state.yawDegrees * .pi / 180
        let pitch = state.pitchDegrees * .pi / 180
        let right = SIMD3<Double>(-sin(yaw), cos(yaw), 0)
        let up = SIMD3<Double>(-sin(pitch) * cos(yaw), -sin(pitch) * sin(yaw), cos(pitch))
        let direction = SIMD3<Double>(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
        let offset = SIMD3<Double>(worldPoint.x, worldPoint.y, worldPoint.z) - c

        var next = state
        next.panX = simd_dot(offset, right)
        next.panY = simd_dot(offset, up)
        // Camera = site + direction × (distance − depthOffset); choose the
        // distance that shows `framed` across the view height.
        let depthOffset = simd_dot(offset, direction)
        let framed = max(size.isFinite ? size : 0, 0) * framingSizeMultiple
        let visible = max(framed, minimumFramedFractionOfRadius * radius)
        let siteDistance = visible / (2 * tan(ViewportDowelRayPicker.fieldOfViewDegrees * .pi / 360))
        let scale = (siteDistance + depthOffset) / (radius * 3.25)
        next.distanceScale = min(max(scale.isFinite ? scale : state.distanceScale, 0.2), 5)
        return next
    }

    /// In-between camera for a fly-to at `t` in 0…1 (eased): pan moves
    /// linearly, zoom geometrically (steady apparent speed). View direction,
    /// spin and projection stay as in `from`.
    static func interpolate(from a: ViewportCameraState, to b: ViewportCameraState, t: Double) -> ViewportCameraState {
        let s = easeInOut(min(max(t, 0), 1))
        var next = a
        next.panX = a.panX + (b.panX - a.panX) * s
        next.panY = a.panY + (b.panY - a.panY) * s
        let la = log(max(a.distanceScale, 1.0e-6)), lb = log(max(b.distanceScale, 1.0e-6))
        next.distanceScale = exp(la + (lb - la) * s)
        return next
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Helpers

    private static func center(_ bounds: Bounds3D?) -> SIMD3<Double> {
        guard let b = bounds else { return .zero }
        return SIMD3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
    }

    private static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func normalized(_ v: Vec3) -> Vec3 {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1.0e-12 ? Vec3(x: v.x / l, y: v.y / l, z: v.z / l) : Vec3(x: 0, y: 0, z: 1)
    }
}
