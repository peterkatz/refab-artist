import Foundation

/// The axis the mesh considers "up" at import time, chosen in the import
/// dialog from Y / Z / X.
/// Selecting a non-Z axis bakes an import-frame correction into the loaded
/// mesh so the slicer (which treats +Z as up) sees a correctly-oriented model.
/// The user-facing Object Size rotation remains separate.
enum ImportUpAxis: String, CaseIterable, Identifiable, Codable {
    /// Y-up (Blender, Maya, many NURBS modellers). Rotate −90° about X to
    /// bring the Y axis into alignment with +Z.
    case y
    /// Z-up inputs need no rotation.
    case z
    /// X-up (rare). Rotate −90° about Y to bring the X axis into +Z.
    case x

    var id: String { rawValue }

    var label: String {
        switch self {
        case .y: return "Y"
        case .z: return "Z"
        case .x: return "X"
        }
    }

    /// Import coordinate mapping. This is deliberately a full
    /// right-handed axis permutation, not just "make the up axis vertical":
    /// a Y-up STL maps old Y to Height, old Z to Width, and old X to Length.
    func orientedPoint(_ point: Vec3) -> Vec3 {
        switch self {
        case .y:
            return Vec3(x: point.z, y: point.x, z: point.y)
        case .z:
            return point
        case .x:
            return Vec3(x: point.y, y: point.z, z: point.x)
        }
    }

    func orientedModel(_ model: MeshSummary) -> MeshSummary {
        guard self != .z else { return model }
        let vertices = model.geometry.vertices.map(orientedPoint)
        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: model.vertexObservationCount,
            faceCount: model.faceCount,
            triangleCount: model.triangleCount,
            bounds: Self.bounds(for: vertices),
            geometry: MeshGeometryData(vertices: vertices, triangleIndices: model.geometry.triangleIndices),
            preflight: model.preflight
        )
    }

    private static func bounds(for vertices: [Vec3]) -> Bounds3D? {
        guard let first = vertices.first else { return nil }
        var minV = first
        var maxV = first
        for v in vertices {
            minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
            maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
        }
        return Bounds3D(min: minV, max: maxV)
    }
}
