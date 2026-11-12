import Foundation

/// Cheap, settings-driven viewport guides shown before a MotherMold build.
/// This value contains display geometry only. The sole mold computation it
/// delegates is the existing silhouette-based parting-plane resolver.
struct MotherMoldPrebuildOverlay: Equatable {
    static let debounceNanoseconds: UInt64 = 16_000_000

    enum AxisTint: String, Equatable {
        case x
        case y
        case z
    }

    struct PartingPlaneGuide: Equatable {
        var plane: PartitionPlane
        var center: Vec3
        var basisU: Vec3
        var basisV: Vec3
        var width: Double
        var height: Double
        var axisTint: AxisTint
        var axisLabel: String
        var label: String
    }

    struct PourHoleMarker: Equatable {
        var point: Vec3
        var axis: Vec3
        var diameter: Double
    }

    struct MasterHolderFootprint: Equatable {
        var center: Vec3
        var width: Double
        var height: Double
        var depth: Double
    }

    struct MasterMountMarker: Equatable {
        var point: Vec3
        var axis: Vec3
    }

    typealias PlaneResolver = (
        _ shell: MeshGeometryData,
        _ reference: MeshGeometryData,
        _ settings: MotherMoldSettings
    ) -> [PartitionPlane]

    var partingPlanes: [PartingPlaneGuide]
    var pourHoleMarker: PourHoleMarker
    var masterHolderFootprint: MasterHolderFootprint?
    var masterMountMarker: MasterMountMarker?
    var fingerprint: String

    static func shouldDisplay(
        isMotherMoldActive: Bool,
        hasGeneratedPlan: Bool,
        isGeneratedPlanStale: Bool
    ) -> Bool {
        isMotherMoldActive && (!hasGeneratedPlan || isGeneratedPlanStale)
    }

    static func make(
        model: MeshSummary,
        settings rawSettings: MotherMoldSettings,
        planeResolver: PlaneResolver = { shell, reference, settings in
            MoldPartitioner.resolvePlanes(
                shell: shell,
                reference: reference,
                settings: settings
            )
        }
    ) -> MotherMoldPrebuildOverlay? {
        guard let bounds = model.bounds else { return nil }
        let settings = rawSettings.sanitized
        let resolvedPlanes = planeResolver(model.geometry, model.geometry, settings)
        let guides = resolvedPlanes.enumerated().map { index, plane in
            partingPlaneGuide(index: index, plane: plane, bounds: bounds)
        }

        let center = boundsCenter(bounds)
        let pourPoint: Vec3
        switch settings.spout.mode {
        case .auto:
            pourPoint = Vec3(x: center.x, y: center.y, z: bounds.max.z)
        case .manual:
            pourPoint = settings.spout.manualSpout
        }
        let pourMarker = PourHoleMarker(
            point: pourPoint,
            axis: Vec3(x: 0, y: 0, z: 1),
            diameter: settings.spout.spoutDiameter
        )

        let holder: MasterHolderFootprint?
        if settings.subtype == .siliconeJacket,
           settings.masterMount.mode == .flatBaseSocket {
            let width = max(0, bounds.max.x - bounds.min.x)
            let depth = max(0, bounds.max.y - bounds.min.y)
            let sealLand = settings.siliconeGap + settings.wallThickness
            holder = MasterHolderFootprint(
                center: Vec3(x: center.x, y: center.y, z: bounds.min.z),
                width: max(2, width + 2 * sealLand + 2 * settings.masterMount.fitClearance),
                height: max(2, depth + 2 * sealLand + 2 * settings.masterMount.fitClearance),
                depth: settings.masterMount.socketDepth
            )
        } else {
            holder = nil
        }

        let masterMountMarker: MasterMountMarker?
        if settings.usesReusableToolingContract,
           settings.masterPreparation.placementMode == .manual,
           let point = settings.masterPreparation.manualPoint {
            let rawAxis = settings.masterPreparation.manualAxis ?? Vec3Codable(x: 0, y: 0, z: 1)
            masterMountMarker = MasterMountMarker(
                point: Vec3(x: point.x, y: point.y, z: point.z),
                axis: normalized(Vec3(x: rawAxis.x, y: rawAxis.y, z: rawAxis.z))
            )
        } else {
            masterMountMarker = nil
        }

        let planeKey = guides.map {
            [
                $0.axisLabel,
                format($0.center.x),
                format($0.center.y),
                format($0.center.z),
                format($0.width),
                format($0.height)
            ].joined(separator: ":")
        }.joined(separator: ";")
        let holderKey = holder.map {
            "\(format($0.center.x)):\(format($0.center.y)):\(format($0.center.z)):\(format($0.width)):\(format($0.height)):\(format($0.depth))"
        } ?? "none"
        let mountKey = masterMountMarker.map {
            "\(format($0.point.x)):\(format($0.point.y)):\(format($0.point.z)):\(format($0.axis.x)):\(format($0.axis.y)):\(format($0.axis.z))"
        } ?? "none"
        let fingerprint = [
            "planes=\(planeKey)",
            "pour=\(format(pourPoint.x)):\(format(pourPoint.y)):\(format(pourPoint.z)):\(format(pourMarker.diameter))",
            "holder=\(holderKey)",
            "mount=\(mountKey)"
        ].joined(separator: "|")

        return MotherMoldPrebuildOverlay(
            partingPlanes: guides,
            pourHoleMarker: pourMarker,
            masterHolderFootprint: holder,
            masterMountMarker: masterMountMarker,
            fingerprint: fingerprint
        )
    }

    private static func partingPlaneGuide(
        index: Int,
        plane: PartitionPlane,
        bounds: Bounds3D
    ) -> PartingPlaneGuide {
        let normal = normalized(plane.normal)
        let boundsCenter = boundsCenter(bounds)
        let centerDistance = plane.offset - dot(boundsCenter, normal)
        let center = add(boundsCenter, scaled(normal, centerDistance))
        let seed = abs(normal.z) < 0.9
            ? Vec3(x: 0, y: 0, z: 1)
            : Vec3(x: 0, y: 1, z: 0)
        let basisU = normalized(cross(seed, normal))
        let basisV = normalized(cross(normal, basisU))
        let corners = boundsCorners(bounds)
        let uValues = corners.map { dot(subtract($0, center), basisU) }
        let vValues = corners.map { dot(subtract($0, center), basisV) }
        let width = max(1, ((uValues.max() ?? 0) - (uValues.min() ?? 0)) * 1.2)
        let height = max(1, ((vValues.max() ?? 0) - (vValues.min() ?? 0)) * 1.2)
        let axis = dominantAxis(normal)
        let axisLabel = axis.rawValue.uppercased()

        return PartingPlaneGuide(
            plane: plane,
            center: center,
            basisU: basisU,
            basisV: basisV,
            width: width,
            height: height,
            axisTint: axis,
            axisLabel: axisLabel,
            label: "Seam \(index + 1) — \(axisLabel) @ \(String(format: "%.1f", plane.offset)) mm"
        )
    }

    private static func dominantAxis(_ normal: Vec3) -> AxisTint {
        let x = abs(normal.x)
        let y = abs(normal.y)
        let z = abs(normal.z)
        if x >= y, x >= z { return .x }
        if y >= z { return .y }
        return .z
    }

    private static func boundsCenter(_ bounds: Bounds3D) -> Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }

    private static func boundsCorners(_ bounds: Bounds3D) -> [Vec3] {
        [
            Vec3(x: bounds.min.x, y: bounds.min.y, z: bounds.min.z),
            Vec3(x: bounds.max.x, y: bounds.min.y, z: bounds.min.z),
            Vec3(x: bounds.min.x, y: bounds.max.y, z: bounds.min.z),
            Vec3(x: bounds.max.x, y: bounds.max.y, z: bounds.min.z),
            Vec3(x: bounds.min.x, y: bounds.min.y, z: bounds.max.z),
            Vec3(x: bounds.max.x, y: bounds.min.y, z: bounds.max.z),
            Vec3(x: bounds.min.x, y: bounds.max.y, z: bounds.max.z),
            Vec3(x: bounds.max.x, y: bounds.max.y, z: bounds.max.z)
        ]
    }

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = sqrt(dot(value, value))
        guard length.isFinite, length > 1.0e-12 else {
            return Vec3(x: 0, y: 0, z: 1)
        }
        return scaled(value, 1 / length)
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func scaled(_ value: Vec3, _ factor: Double) -> Vec3 {
        Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
