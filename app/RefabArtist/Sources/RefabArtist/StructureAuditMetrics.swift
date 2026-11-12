import Foundation

struct StructureComponentMetric: Equatable {
    var volume: Double
    var bounds: Bounds3D

    var bboxDiagonal: Double {
        let dx = bounds.max.x - bounds.min.x
        let dy = bounds.max.y - bounds.min.y
        let dz = bounds.max.z - bounds.min.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

struct StructureComponentAudit: Equatable {
    var watertight: Bool
    var triangleCount: Int
    var components: [StructureComponentMetric]

    var componentCount: Int { components.count }

    var componentVolumes: [Double] {
        components.map(\.volume).sorted(by: >)
    }

    var totalVolume: Double {
        components.reduce(0) { $0 + $1.volume }
    }

    func subFloorComponentCount(wallThicknessMm: Double) -> Int {
        let wall = max(wallThicknessMm, 0)
        let volumeFloor = max(1.0e-4 * totalVolume, wall * wall * wall)
        let minDiagonal = 2.0 * wall
        return components.filter {
            $0.volume < volumeFloor || $0.bboxDiagonal < minDiagonal
        }.count
    }
}

enum StructureAuditMetrics {
    static func mesh(from layers: [SliceMeshExportLayer]) -> MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        for layer in layers {
            let base = Int32(vertices.count)
            vertices.append(contentsOf: layer.mesh.vertices)
            indices.append(contentsOf: layer.mesh.triangleIndices.map { $0 + base })
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    static func componentAudit(
        mesh: MeshGeometryData,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> StructureComponentAudit {
        let welded = StructureClipEngine.welded(mesh)
        let solid = try engine.make(from: welded)
        let watertight = engine.isWatertight(solid)
        let components = try engine.decompose(solid)
        let metrics = components.map {
            StructureComponentMetric(
                volume: abs(engine.volume($0)),
                bounds: engine.bounds($0)
            )
        }
        withExtendedLifetime(solid) {}
        withExtendedLifetime(components) {}
        return StructureComponentAudit(
            watertight: watertight,
            triangleCount: mesh.triangleIndices.count / 3,
            components: metrics
        )
    }

    static func componentAudit(
        layers: [SliceMeshExportLayer],
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> StructureComponentAudit {
        try componentAudit(mesh: mesh(from: layers), engine: engine)
    }
}
