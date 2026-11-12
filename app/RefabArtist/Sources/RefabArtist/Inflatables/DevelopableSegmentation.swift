import Foundation

struct InflatableChart: Equatable {
    var id: String
    var mesh: MeshGeometryData
    var sourceFaceIDs: [Int]
    var axis: Int
    var angularBin: Int
}

enum DevelopableSegmentation {
    static func segment(mesh: MeshGeometryData, settings: InflatablesSettings) -> [InflatableChart] {
        let triangles = triangleIDs(mesh)
        guard !triangles.isEmpty else { return [] }

        let triangleByID = Dictionary(uniqueKeysWithValues: triangles.map { ($0.faceID, $0) })
        let adjacency = faceAdjacency(mesh: mesh, triangles: triangles)
        let targetFaces = targetFacesPerPanel(mesh: mesh, settings: settings)
        let maxCharts = max(settings.maxPanelCount, 1)
        let normalTolerance = normalToleranceRadians(settings: settings)
        let developabilityTolerance = 0.42

        var unassigned = Set(triangles.map(\.faceID))
        var groups: [[Int]] = []

        while let seed = bestSeed(from: unassigned, triangles: triangles) {
            let group = growRegion(
                seed: seed,
                unassigned: &unassigned,
                triangles: triangleByID,
                adjacency: adjacency,
                targetFaces: targetFaces,
                normalTolerance: normalTolerance,
                developabilityTolerance: developabilityTolerance
            )
            if !group.isEmpty {
                groups.append(group)
            }
        }

        groups = splitDistortedGroups(
            groups,
            mesh: mesh,
            adjacency: adjacency,
            triangles: triangleByID,
            maxCharts: maxCharts,
            maxStretch: 1.10,
            depth: 0
        )
        groups = groups.flatMap { connectedComponents(in: $0, adjacency: adjacency) }

        if groups.count > maxCharts {
            groups = mergeSmallest(groups, adjacency: adjacency, triangles: triangleByID, maxCount: maxCharts)
        }
        groups = groups.flatMap { connectedComponents(in: $0, adjacency: adjacency) }

        return groups.enumerated().compactMap { offset, faceIDs in
            chart(id: "G\(offset + 1)", mesh: mesh, faceIDs: faceIDs.sorted(), axis: 2, angularBin: offset)
        }
    }

    struct TriangleID {
        var faceID: Int
        var indices: [Int]
        var centroid: Vec3
        var normal: Vec3
        var area: Double
    }

    private struct VertexKey: Hashable, Comparable {
        var x: Int64
        var y: Int64
        var z: Int64

        init(_ point: Vec3) {
            let scale = 1_000_000.0
            x = Int64((point.x * scale).rounded())
            y = Int64((point.y * scale).rounded())
            z = Int64((point.z * scale).rounded())
        }

        static func < (lhs: VertexKey, rhs: VertexKey) -> Bool {
            (lhs.x, lhs.y, lhs.z) < (rhs.x, rhs.y, rhs.z)
        }
    }

    private struct EdgeKey: Hashable {
        var a: VertexKey
        var b: VertexKey

        init(_ first: VertexKey, _ second: VertexKey) {
            if first <= second {
                a = first
                b = second
            } else {
                a = second
                b = first
            }
        }
    }

    private static func triangleIDs(_ mesh: MeshGeometryData) -> [TriangleID] {
        stride(from: 0, to: mesh.triangleIndices.count - mesh.triangleIndices.count % 3, by: 3).compactMap { offset in
            let indices = [
                Int(mesh.triangleIndices[offset]),
                Int(mesh.triangleIndices[offset + 1]),
                Int(mesh.triangleIndices[offset + 2])
            ]
            guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { return nil }
            let points = indices.map { mesh.vertices[$0] }
            let normalVector = cross(subtract(points[1], points[0]), subtract(points[2], points[0]))
            let area = 0.5 * length(normalVector)
            guard area > 1.0e-9, let normal = normalized(normalVector) else { return nil }
            return TriangleID(
                faceID: offset / 3,
                indices: indices,
                centroid: centroid(points),
                normal: normal,
                area: area
            )
        }
    }

    private static func faceAdjacency(mesh: MeshGeometryData, triangles: [TriangleID]) -> [Int: [Int]] {
        var edgeToFaces: [EdgeKey: [Int]] = [:]
        for tri in triangles {
            for edge in geometricEdges(tri.indices, mesh: mesh) {
                edgeToFaces[edge, default: []].append(tri.faceID)
            }
        }

        var result: [Int: Set<Int>] = [:]
        for faces in edgeToFaces.values where faces.count > 1 {
            for face in faces {
                for neighbor in faces where neighbor != face {
                    result[face, default: []].insert(neighbor)
                }
            }
        }
        return result.mapValues { Array($0).sorted() }
    }

    private static func targetFacesPerPanel(mesh: MeshGeometryData, settings: InflatablesSettings) -> Int {
        let targetWidth = max(settings.targetPanelWidthMM, 10)
        let area = totalArea(mesh)
        let targetArea = targetWidth * targetWidth * 1.8
        let estimatedPanels = min(max(Int(ceil(area / max(targetArea, 1))), 1), max(settings.maxPanelCount, 1))
        let faceCount = max(mesh.triangleIndices.count / 3, 1)
        return max(Int(ceil(Double(faceCount) / Double(max(estimatedPanels, 1)))), 1)
    }

    private static func normalToleranceRadians(settings: InflatablesSettings) -> Double {
        let width = max(settings.targetPanelWidthMM, 20)
        let normalized = min(max((width - 20) / 300, 0), 1)
        let degrees = 18 + normalized * 28
        return degrees * Double.pi / 180
    }

    private static func bestSeed(from unassigned: Set<Int>, triangles: [TriangleID]) -> Int? {
        triangles
            .filter { unassigned.contains($0.faceID) }
            .max { $0.area < $1.area }?
            .faceID
    }

    private static func growRegion(
        seed: Int,
        unassigned: inout Set<Int>,
        triangles: [Int: TriangleID],
        adjacency: [Int: [Int]],
        targetFaces: Int,
        normalTolerance: Double,
        developabilityTolerance: Double
    ) -> [Int] {
        guard let seedTri = triangles[seed] else { return [] }
        var group: [Int] = []
        var queue = [seed]
        var averageNormal = seedTri.normal
        var averageCentroid = seedTri.centroid
        var count = 0
        unassigned.remove(seed)

        while let current = queue.first {
            queue.removeFirst()
            guard let currentTri = triangles[current] else { continue }
            group.append(current)
            let oldCount = Double(count)
            count += 1
            averageNormal = normalized(add(scale(averageNormal, oldCount), currentTri.normal)) ?? averageNormal
            averageCentroid = scale(add(scale(averageCentroid, oldCount), currentTri.centroid), 1 / Double(count))

            guard group.count < targetFaces else { continue }
            for neighbor in adjacency[current, default: []] where unassigned.contains(neighbor) {
                guard let neighborTri = triangles[neighbor] else { continue }
                let angle = acos(min(max(abs(dot(averageNormal, neighborTri.normal)), -1), 1))
                let developability = abs(dot(subtract(neighborTri.centroid, averageCentroid), averageNormal))
                    / max(distance(neighborTri.centroid, averageCentroid), 1.0e-6)
                guard angle <= normalTolerance, developability <= developabilityTolerance else { continue }
                unassigned.remove(neighbor)
                queue.append(neighbor)
            }
        }

        return group
    }

    private static func splitDistortedGroups(
        _ groups: [[Int]],
        mesh: MeshGeometryData,
        adjacency: [Int: [Int]],
        triangles: [Int: TriangleID],
        maxCharts: Int,
        maxStretch: Double,
        depth: Int
    ) -> [[Int]] {
        guard depth < 5 else { return groups }
        var result: [[Int]] = []
        for (index, group) in groups.enumerated() {
            let remainingInputGroups = groups.count - index - 1
            let canSplitWithinBudget = result.count + remainingInputGroups + 2 <= maxCharts
            guard canSplitWithinBudget else {
                result.append(group)
                continue
            }
            if group.count > 650,
               let split = splitGroup(group, mesh: mesh) {
                let connectedSplit = split.flatMap { connectedComponents(in: $0, adjacency: adjacency) }
                result.append(contentsOf: splitDistortedGroups(connectedSplit, mesh: mesh, adjacency: adjacency, triangles: triangles, maxCharts: maxCharts, maxStretch: maxStretch, depth: depth + 1))
                continue
            }
            guard group.count > 1,
                  group.count <= 300,
                  let testChart = chart(id: "test", mesh: mesh, faceIDs: group.sorted(), axis: 2, angularBin: 0),
                  let flattened = LSCM.flatten(testChart),
                  flattened.maxStretch > maxStretch,
                  let split = splitGroup(group, mesh: mesh) else {
                result.append(group)
                continue
            }
            let connectedSplit = split.flatMap { connectedComponents(in: $0, adjacency: adjacency) }
            result.append(contentsOf: splitDistortedGroups(connectedSplit, mesh: mesh, adjacency: adjacency, triangles: triangles, maxCharts: maxCharts, maxStretch: maxStretch, depth: depth + 1))
        }
        return result
    }

    private static func splitGroup(_ group: [Int], mesh: MeshGeometryData) -> [[Int]]? {
        let faceCentroids = group.compactMap { faceID -> (Int, Vec3)? in
            let start = faceID * 3
            guard start + 2 < mesh.triangleIndices.count else { return nil }
            let indices = [Int(mesh.triangleIndices[start]), Int(mesh.triangleIndices[start + 1]), Int(mesh.triangleIndices[start + 2])]
            guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { return nil }
            return (faceID, centroid(indices.map { mesh.vertices[$0] }))
        }
        guard faceCentroids.count > 1 else { return nil }
        let bounds = bounds(of: faceCentroids.map(\.1))
        let extents = Vec3(x: bounds.max.x - bounds.min.x, y: bounds.max.y - bounds.min.y, z: bounds.max.z - bounds.min.z)
        let axis = longestAxis(extents)
        let sorted = faceCentroids.sorted { lhs, rhs in
            coordinate(lhs.1, axis: axis) < coordinate(rhs.1, axis: axis)
        }
        let midpoint = sorted.count / 2
        let first = sorted[..<midpoint].map(\.0)
        let second = sorted[midpoint...].map(\.0)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return [Array(first), Array(second)]
    }

    private static func connectedComponents(in group: [Int], adjacency: [Int: [Int]]) -> [[Int]] {
        let groupSet = Set(group)
        var unseen = groupSet
        var components: [[Int]] = []
        while let seed = unseen.first {
            var component: [Int] = []
            var queue = [seed]
            unseen.remove(seed)
            while let face = queue.first {
                queue.removeFirst()
                component.append(face)
                for neighbor in adjacency[face, default: []] where groupSet.contains(neighbor) && unseen.contains(neighbor) {
                    unseen.remove(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(component.sorted())
        }
        return components
    }

    private static func mergeSmallest(
        _ groups: [[Int]],
        adjacency: [Int: [Int]],
        triangles: [Int: TriangleID],
        maxCount: Int
    ) -> [[Int]] {
        var result = groups.map { $0.sorted() }
        while result.count > maxCount {
            guard let smallestIndex = result.indices.min(by: { result[$0].count < result[$1].count }) else { break }
            guard let targetIndex = adjacentMergeTarget(for: smallestIndex, in: result, adjacency: adjacency, triangles: triangles) else {
                break
            }
            let smallest = result.remove(at: smallestIndex)
            let adjustedTarget = targetIndex > smallestIndex ? targetIndex - 1 : targetIndex
            result[adjustedTarget] = Array(Set(result[adjustedTarget]).union(smallest)).sorted()
        }
        return result
    }

    private static func adjacentMergeTarget(
        for groupIndex: Int,
        in groups: [[Int]],
        adjacency: [Int: [Int]],
        triangles: [Int: TriangleID]
    ) -> Int? {
        let group = Set(groups[groupIndex])
        let neighborFaces = Set(group.flatMap { adjacency[$0, default: []] })
        let candidates = groups.indices.filter { index in
            index != groupIndex && !Set(groups[index]).intersection(neighborFaces).isEmpty
        }
        guard !candidates.isEmpty else { return nil }
        let center = centroid(group.compactMap { triangles[$0]?.centroid })
        return candidates.min { lhs, rhs in
            let left = centroid(groups[lhs].compactMap { triangles[$0]?.centroid })
            let right = centroid(groups[rhs].compactMap { triangles[$0]?.centroid })
            return distance(center, left) < distance(center, right)
        }
    }

    private static func chart(id: String, mesh: MeshGeometryData, faceIDs: [Int], axis: Int, angularBin: Int) -> InflatableChart? {
        var vertexMap: [Int: Int32] = [:]
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        for faceID in faceIDs {
            let start = faceID * 3
            guard start + 2 < mesh.triangleIndices.count else { continue }
            for raw in [Int(mesh.triangleIndices[start]), Int(mesh.triangleIndices[start + 1]), Int(mesh.triangleIndices[start + 2])] {
                guard mesh.vertices.indices.contains(raw) else { continue }
                if let mapped = vertexMap[raw] {
                    indices.append(mapped)
                } else {
                    let mapped = Int32(vertices.count)
                    vertexMap[raw] = mapped
                    vertices.append(mesh.vertices[raw])
                    indices.append(mapped)
                }
            }
        }
        guard indices.count >= 3 else { return nil }
        return InflatableChart(
            id: id,
            mesh: MeshGeometryData(vertices: vertices, triangleIndices: indices),
            sourceFaceIDs: faceIDs,
            axis: axis,
            angularBin: angularBin
        )
    }

    private static func totalArea(_ mesh: MeshGeometryData) -> Double {
        var total = 0.0
        var offset = 0
        while offset + 2 < mesh.triangleIndices.count {
            let ia = Int(mesh.triangleIndices[offset])
            let ib = Int(mesh.triangleIndices[offset + 1])
            let ic = Int(mesh.triangleIndices[offset + 2])
            if mesh.vertices.indices.contains(ia), mesh.vertices.indices.contains(ib), mesh.vertices.indices.contains(ic) {
                total += 0.5 * length(cross(subtract(mesh.vertices[ib], mesh.vertices[ia]), subtract(mesh.vertices[ic], mesh.vertices[ia])))
            }
            offset += 3
        }
        return total
    }

    private static func geometricEdges(_ indices: [Int], mesh: MeshGeometryData) -> [EdgeKey] {
        guard indices.count == 3 else { return [] }
        guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { return [] }
        let keys = indices.map { VertexKey(mesh.vertices[$0]) }
        return [
            EdgeKey(keys[0], keys[1]),
            EdgeKey(keys[1], keys[2]),
            EdgeKey(keys[2], keys[0])
        ]
    }

    private static func bounds(of vertices: [Vec3]) -> Bounds3D {
        guard let first = vertices.first else {
            return Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0))
        }
        var minV = first, maxV = first
        for v in vertices {
            minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
            maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
        }
        return Bounds3D(min: minV, max: maxV)
    }

    private static func longestAxis(_ extents: Vec3) -> Int {
        if extents.x >= extents.y, extents.x >= extents.z { return 0 }
        if extents.y >= extents.z { return 1 }
        return 2
    }

    private static func coordinate(_ point: Vec3, axis: Int) -> Double {
        switch axis {
        case 0: return point.x
        case 1: return point.y
        default: return point.z
        }
    }

    private static func centroid(_ vertices: [Vec3]) -> Vec3 {
        guard !vertices.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        let sum = vertices.reduce(Vec3(x: 0, y: 0, z: 0)) { add($0, $1) }
        return scale(sum, 1 / Double(vertices.count))
    }

    private static func normalized(_ value: Vec3) -> Vec3? {
        let len = length(value)
        guard len > 1.0e-9, len.isFinite else { return nil }
        return scale(value, 1 / len)
    }

    private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private static func scale(_ value: Vec3, _ factor: Double) -> Vec3 {
        Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    private static func length(_ value: Vec3) -> Double {
        dot(value, value).squareRoot()
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        length(subtract(a, b))
    }
}
