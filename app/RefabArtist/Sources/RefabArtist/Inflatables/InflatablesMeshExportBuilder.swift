import Foundation

struct InflatablesPanelRenderLayer: Equatable {
    var panelID: String
    var panelIndex: Int
    var mesh: ViewportFlatShadedMesh
}

enum InflatablesMeshExportBuilder {
    static func layers(plan: InflatablesPlan) -> [SliceMeshExportLayer] {
        guard let renderMesh = renderMesh(plan: plan) else { return [] }
        return [
            SliceMeshExportLayer(
                name: "inflatable_membrane",
                mesh: renderMesh
            )
        ]
    }

    static func renderMesh(plan: InflatablesPlan) -> ViewportFlatShadedMesh? {
        guard let geometry = plan.preview?.inflatedMesh,
              !geometry.vertices.isEmpty,
              geometry.triangleIndices.count >= 3 else {
            return nil
        }
        return ViewportMeshRenderData.smoothShadedMesh(from: geometry)
    }

    static func panelRenderLayers(plan: InflatablesPlan) -> [InflatablesPanelRenderLayer] {
        guard let geometry = plan.preview?.inflatedMesh else { return [] }
        return plan.panels.enumerated().compactMap { index, panel in
            guard let panelGeometry = geometrySubset(from: geometry, faceIDs: panel.sourceFaceIDs),
                  panelGeometry.triangleIndices.count >= 3 else {
                return nil
            }
            let mesh = ViewportMeshRenderData.smoothShadedMesh(from: panelGeometry)
            guard !mesh.vertices.isEmpty, mesh.triangleIndices.count >= 3 else {
                return nil
            }
            return InflatablesPanelRenderLayer(panelID: panel.id, panelIndex: index, mesh: mesh)
        }
    }

    private static func geometrySubset(from geometry: MeshGeometryData, faceIDs: [Int]) -> MeshGeometryData? {
        var vertexMap: [Int32: Int32] = [:]
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        for faceID in faceIDs {
            let start = faceID * 3
            guard start >= 0, start + 2 < geometry.triangleIndices.count else { continue }
            for rawIndex in [
                geometry.triangleIndices[start],
                geometry.triangleIndices[start + 1],
                geometry.triangleIndices[start + 2]
            ] {
                guard rawIndex >= 0, Int(rawIndex) < geometry.vertices.count else { continue }
                if let mapped = vertexMap[rawIndex] {
                    indices.append(mapped)
                } else {
                    let mapped = Int32(vertices.count)
                    vertexMap[rawIndex] = mapped
                    vertices.append(geometry.vertices[Int(rawIndex)])
                    indices.append(mapped)
                }
            }
        }
        guard indices.count >= 3 else { return nil }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }
}
