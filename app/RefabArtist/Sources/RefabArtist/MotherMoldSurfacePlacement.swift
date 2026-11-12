import Foundation
import simd

/// Pure mapping from a stationary viewport click to persisted MotherMold
/// model-space settings. Arming/cancelling the interaction remains UI state;
/// this type owns only geometry and the settings update.
enum MotherMoldSurfacePlacement {
    enum Target: Equatable {
        case pourHole
        case masterMount
    }

    struct Hit: Equatable {
        var point: Vec3
        var normal: Vec3
    }

    static func hit(
        viewPoint: CGPoint,
        viewSize: CGSize,
        pose: ViewportCameraPose,
        geometry: MeshGeometryData,
        bounds: Bounds3D,
        modelSpin: simd_quatf
    ) -> Hit? {
        guard let sceneRay = ViewportDowelRayPicker.ray(
            viewPoint: viewPoint,
            viewSize: viewSize,
            pose: pose
        ) else { return nil }
        return hit(
            sceneRay: sceneRay,
            geometry: geometry,
            bounds: bounds,
            modelSpin: modelSpin
        )
    }

    static func hit(
        sceneRay: ViewportPickRay,
        geometry: MeshGeometryData,
        bounds: Bounds3D,
        modelSpin: simd_quatf
    ) -> Hit? {
        let center = SIMD3<Float>(
            Float((bounds.min.x + bounds.max.x) / 2),
            Float((bounds.min.y + bounds.max.y) / 2),
            Float((bounds.min.z + bounds.max.z) / 2)
        )
        let inverseSpin = modelSpin.inverse
        let sceneOrigin = simd(sceneRay.origin)
        let sceneDirection = simd(sceneRay.direction)
        let modelOrigin = center + inverseSpin.act(sceneOrigin - center)
        let modelDirection = simd_normalize(inverseSpin.act(sceneDirection))
        let modelRay = ViewportPickRay(
            origin: vec(modelOrigin),
            direction: vec(modelDirection)
        )
        guard let surface = ViewportDowelRayPicker.intersectMeshSurface(
            ray: modelRay,
            geometry: geometry
        ) else { return nil }
        return Hit(point: surface.point, normal: surface.normal)
    }

    static func applying(
        _ hit: Hit,
        target: Target,
        to input: MotherMoldSettings
    ) -> MotherMoldSettings {
        var settings = input
        switch target {
        case .pourHole:
            settings.spout.mode = .manual
            settings.spout.manualSpoutX = hit.point.x
            settings.spout.manualSpoutY = hit.point.y
            settings.spout.manualSpoutZ = hit.point.z
        case .masterMount:
            settings.masterPreparation.placementMode = .manual
            settings.masterPreparation.manualPoint = codable(hit.point)
            settings.masterPreparation.manualAxis = codable(normalized(hit.normal))
        }
        return settings
    }

    private static func simd(_ value: Vec3) -> SIMD3<Float> {
        SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
    }

    private static func vec(_ value: SIMD3<Float>) -> Vec3 {
        Vec3(x: Double(value.x), y: Double(value.y), z: Double(value.z))
    }

    private static func codable(_ value: Vec3) -> Vec3Codable {
        Vec3Codable(x: value.x, y: value.y, z: value.z)
    }

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard length > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }
}
