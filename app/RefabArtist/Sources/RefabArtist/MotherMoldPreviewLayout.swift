import Foundation

enum MotherMoldArtistViewMode: String, CaseIterable, Identifiable {
    case master
    case mold
    case assembly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .master: return "Master"
        case .mold: return "Mold"
        case .assembly: return "Assembly"
        }
    }

    var help: String {
        switch self {
        case .master: return "Inspect the active source and prepared master without shell tooling obscuring the art surface."
        case .mold: return "Inspect rigid shell parts, fixture hardware, supports, and flow tooling."
        case .assembly: return "Inspect the phase-correct tooling assembly, including the selected liner state."
        }
    }
}

enum MotherMoldPreviewLayer: String, CaseIterable, Identifiable, Hashable {
    case activeSource
    case preparedMaster
    case asPouredLiner
    case productionLiner
    case moldParts
    case mountHardware
    case supportCradles
    case flowPaths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activeSource: return "Active source"
        case .preparedMaster: return "Prepared master"
        case .asPouredLiner: return "As-poured liner"
        case .productionLiner: return "Production liner"
        case .moldParts: return "Mold parts"
        case .mountHardware: return "Mount hardware"
        case .supportCradles: return "Support cradles"
        case .flowPaths: return "Flow paths"
        }
    }

    var help: String {
        switch self {
        case .activeSource: return "The imported active source, shown separately from any prepared master."
        case .preparedMaster: return "The printable prepared positive with approved tooling additions."
        case .asPouredLiner: return "Reference-only silicone liner before exterior fill nubs are trimmed."
        case .productionLiner: return "Reference-only liner after trim, used for production casting."
        case .moldParts: return "The printable rigid mother-mold shell parts."
        case .mountHardware: return "Printed hold-down, funnel, and removable vent tooling."
        case .supportCradles: return "Phase-specific printable cradles and stands."
        case .flowPaths: return "Liner-fill and production-casting path tooling."
        }
    }

    var stableColorName: String {
        switch self {
        case .activeSource: return "neutral"
        case .preparedMaster: return "green"
        case .asPouredLiner: return "cyan"
        case .productionLiner: return "blue"
        case .moldParts: return "orange"
        case .mountHardware: return "purple"
        case .supportCradles: return "yellow"
        case .flowPaths: return "pink"
        }
    }
}

/// Pure, view-only MotherMold layout math. Export geometry is never translated.
enum MotherMoldPreviewLayout {
    static func offsets(
        for plan: MotherMoldPlan,
        exploded: Bool,
        distanceFraction: Double = 0.45
    ) -> [Vec3] {
        guard exploded, !plan.parts.isEmpty else {
            return plan.parts.map { _ in Vec3(x: 0, y: 0, z: 0) }
        }

        let bounds = combinedBounds(plan.parts)
        let extent = bounds.map {
            max($0.max.x - $0.min.x, max($0.max.y - $0.min.y, $0.max.z - $0.min.z))
        } ?? 0
        let distance = max(10, extent * max(0, distanceFraction))
        let center = bounds.map {
            Vec3(
                x: ($0.min.x + $0.max.x) / 2,
                y: ($0.min.y + $0.max.y) / 2,
                z: ($0.min.z + $0.max.z) / 2
            )
        } ?? Vec3(x: 0, y: 0, z: 0)

        return plan.parts.enumerated().map { index, part in
            let axis: Vec3
            if index < plan.demoldAxes.count {
                axis = normalized(plan.demoldAxes[index])
            } else if let partCenter = part.bounds.map({
                Vec3(
                    x: ($0.min.x + $0.max.x) / 2,
                    y: ($0.min.y + $0.max.y) / 2,
                    z: ($0.min.z + $0.max.z) / 2
                )
            }) {
                axis = normalized(Vec3(
                    x: partCenter.x - center.x,
                    y: partCenter.y - center.y,
                    z: partCenter.z - center.z
                ))
            } else {
                axis = Vec3(x: 0, y: 0, z: 1)
            }
            return Vec3(x: axis.x * distance, y: axis.y * distance, z: axis.z * distance)
        }
    }

    /// Bounds of the requested assembled or exploded layout. Callers can use the
    /// assembled bounds deliberately when the camera must stay fixed while a
    /// view-only explode transform is toggled.
    static func previewBounds(
        for plan: MotherMoldPlan,
        exploded: Bool,
        isolatedPartName: String? = nil,
        includeMaster: Bool
    ) -> Bounds3D? {
        let partOffsets = offsets(for: plan, exploded: exploded)
        var result: Bounds3D?

        for (index, part) in plan.parts.enumerated() {
            if let isolatedPartName, part.name != isolatedPartName { continue }
            guard let bounds = part.bounds ?? bounds(of: part.geometry.vertices) else { continue }
            let offset = index < partOffsets.count
                ? partOffsets[index]
                : Vec3(x: 0, y: 0, z: 0)
            result = union(
                result,
                Bounds3D(
                    min: Vec3(
                        x: bounds.min.x + offset.x,
                        y: bounds.min.y + offset.y,
                        z: bounds.min.z + offset.z
                    ),
                    max: Vec3(
                        x: bounds.max.x + offset.x,
                        y: bounds.max.y + offset.y,
                        z: bounds.max.z + offset.z
                    )
                )
            )
        }

        if includeMaster, let masterBounds = bounds(of: plan.master.vertices) {
            result = union(result, masterBounds)
        }
        return result
    }

    /// Non-shell tooling is separated only in the viewport. Prepared/source
    /// masters stay fixed; fixture and support objects move along their measured
    /// phase directions so the exploded view remains an inspection transform.
    static func artifactOffsets(
        for plan: MotherMoldPlan,
        exploded: Bool,
        distanceFraction: Double = 0.30
    ) -> [ToolingArtifactID: Vec3] {
        guard exploded else { return [:] }
        let bounds = combinedBounds(plan.parts)
        let extent = bounds.map {
            max($0.max.x - $0.min.x, max($0.max.y - $0.min.y, $0.max.z - $0.min.z))
        } ?? 0
        let distance = max(8, extent * max(0, distanceFraction))
        let linerAxis = normalized(vec(plan.linerFillSupport.gravityUpAxis) ?? Vec3(x: 0, y: 0, z: 1))
        let castingAxis = normalized(vec(plan.castingSupport.gravityUpAxis) ?? linerAxis)
        var offsets: [ToolingArtifactID: Vec3] = [:]

        for artifact in plan.fixtureArtifacts + plan.supportArtifacts {
            let direction: Vec3
            switch artifact.role {
            case .castingFunnel, .productionVentFormer:
                direction = castingAxis
            case .supportCradle:
                direction = Vec3(x: -linerAxis.x, y: -linerAxis.y, z: -linerAxis.z)
            default:
                direction = linerAxis
            }
            offsets[artifact.id] = Vec3(
                x: direction.x * distance,
                y: direction.y * distance,
                z: direction.z * distance
            )
        }
        return offsets
    }

    static func artifactPosition(for artifact: ToolingArtifact, offset: Vec3) -> Vec3 {
        let transform = artifact.assembledTransform.elements
        let assembledOffset = transform.count == Matrix4x4Codable.elementCount
            ? Vec3(x: transform[12], y: transform[13], z: transform[14])
            : Vec3(x: 0, y: 0, z: 0)
        return Vec3(
            x: assembledOffset.x + offset.x,
            y: assembledOffset.y + offset.y,
            z: assembledOffset.z + offset.z
        )
    }

    private static func combinedBounds(_ parts: [MotherMoldPart]) -> Bounds3D? {
        let vertices = parts.flatMap(\.geometry.vertices)
        return bounds(of: vertices)
    }

    private static func bounds(of vertices: [Vec3]) -> Bounds3D? {
        guard var minValue = vertices.first else { return nil }
        var maxValue = minValue
        for vertex in vertices.dropFirst() {
            minValue.x = min(minValue.x, vertex.x)
            minValue.y = min(minValue.y, vertex.y)
            minValue.z = min(minValue.z, vertex.z)
            maxValue.x = max(maxValue.x, vertex.x)
            maxValue.y = max(maxValue.y, vertex.y)
            maxValue.z = max(maxValue.z, vertex.z)
        }
        return Bounds3D(min: minValue, max: maxValue)
    }

    private static func union(_ lhs: Bounds3D?, _ rhs: Bounds3D) -> Bounds3D {
        guard let lhs else { return rhs }
        return Bounds3D(
            min: Vec3(
                x: min(lhs.min.x, rhs.min.x),
                y: min(lhs.min.y, rhs.min.y),
                z: min(lhs.min.z, rhs.min.z)
            ),
            max: Vec3(
                x: max(lhs.max.x, rhs.max.x),
                y: max(lhs.max.y, rhs.max.y),
                z: max(lhs.max.z, rhs.max.z)
            )
        )
    }

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard length > 1.0e-9 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func vec(_ value: Vec3Codable?) -> Vec3? {
        guard let value else { return nil }
        return Vec3(x: value.x, y: value.y, z: value.z)
    }
}
