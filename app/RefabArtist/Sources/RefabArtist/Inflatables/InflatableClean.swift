import Foundation

enum InflatablesClean {
    static func cleanForInflatable(_ mesh: MeshGeometryData) throws -> MeshGeometryData {
        let repaired = MeshManifoldRepair.userRepair(MoldMeshSealer.seal(mesh))
        guard !repaired.vertices.isEmpty, !repaired.triangleIndices.isEmpty else {
            throw InflatablesPlannerError.emptyAfterClean
        }

        if let direct = try? ManifoldEngine.make(from: repaired) {
            return try meshFrom(handle: direct, source: repaired)
        }

        let healed = try MeshHealer.heal(repaired, maxCells: 180_000)
        return try meshFrom(handle: healed.handle, source: repaired)
    }

    private static func meshFrom(handle: ManifoldHandle, source: MeshGeometryData) throws -> MeshGeometryData {
        guard ManifoldEngine.isWatertight(handle) else {
            throw InflatablesPlannerError.notWatertight
        }
        let faceCount = ManifoldEngine.triangleCount(handle)
        let simplified: ManifoldHandle
        if faceCount > 5_000 {
            let tolerance = max(diagonal(of: source) / 600.0, 0.05)
            simplified = (try? ManifoldEngine.simplify(handle, tolerance: tolerance)) ?? handle
        } else {
            simplified = handle
        }
        let output = try ManifoldEngine.toMesh(simplified)
        let cleaned = MeshManifoldRepair.userRepair(MoldMeshSealer.seal(output))
        guard !cleaned.vertices.isEmpty, !cleaned.triangleIndices.isEmpty else {
            throw InflatablesPlannerError.emptyAfterClean
        }
        return cleaned
    }

    private static func diagonal(of mesh: MeshGeometryData) -> Double {
        guard let first = mesh.vertices.first else { return 1 }
        var minX = first.x, minY = first.y, minZ = first.z
        var maxX = first.x, maxY = first.y, maxZ = first.z
        for v in mesh.vertices {
            minX = min(minX, v.x); minY = min(minY, v.y); minZ = min(minZ, v.z)
            maxX = max(maxX, v.x); maxY = max(maxY, v.y); maxZ = max(maxZ, v.z)
        }
        let dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ
        return max((dx * dx + dy * dy + dz * dz).squareRoot(), 1)
    }
}
