import Foundation

enum InflationSimulator {
    static func simulate(
        mesh sourceMesh: MeshGeometryData,
        flattened: [InflatableFlattenedChart],
        settings: InflatablesSettings
    ) -> InflationPreviewResult {
        guard !sourceMesh.vertices.isEmpty, sourceMesh.triangleIndices.count >= 3 else {
            return .empty
        }

        let restLengths = flatRestLengths(sourceMesh: sourceMesh, flattened: flattened)
        let inflatedVertices = inflateVertices(sourceMesh.vertices, indices: sourceMesh.triangleIndices, restLengths: restLengths)
        let inflatedMesh = MeshGeometryData(vertices: inflatedVertices, triangleIndices: sourceMesh.triangleIndices)
        let deviation = deviationByVertex(inflated: inflatedVertices, target: sourceMesh)
        let panelError = panelErrors(flattened: flattened, mesh: sourceMesh, deviation: deviation)

        return InflationPreviewResult(
            inflatedMesh: inflatedMesh,
            maxDeviationMM: deviation.max() ?? 0,
            meanDeviationMM: deviation.isEmpty ? 0 : deviation.reduce(0, +) / Double(deviation.count),
            deviationByVertex: deviation,
            panelErrorMM: panelError
        )
    }

    static func diagnostics(
        preview: InflationPreviewResult,
        flattened: [InflatableFlattenedChart],
        settings: InflatablesSettings
    ) -> [PlanDiagnostic] {
        let tolerance = max(6.0, settings.targetPanelWidthMM * 0.08)
        return flattened.compactMap { chart in
            guard let error = preview.panelErrorMM[chart.chart.id], error > tolerance else { return nil }
            return PlanDiagnostic(
                kind: "concavity-cannot-inflate",
                message: "\(chart.chart.id) inflated preview deviates by \(String(format: "%.1f", error)) mm; split the form here or add a baffle.",
                at: representativePoint(for: chart.chart, in: preview.inflatedMesh),
                panelID: chart.chart.id
            )
        }
        .sorted { ($0.panelID ?? "") < ($1.panelID ?? "") }
        .prefix(12)
        .map { $0 }
    }

    private struct EdgeKey: Hashable {
        var a: Int
        var b: Int

        init(_ first: Int, _ second: Int) {
            if first <= second {
                a = first
                b = second
            } else {
                a = second
                b = first
            }
        }
    }

    private static func flatRestLengths(
        sourceMesh: MeshGeometryData,
        flattened: [InflatableFlattenedChart]
    ) -> [EdgeKey: Double] {
        var totals: [EdgeKey: (sum: Double, count: Int)] = [:]

        for chart in flattened {
            let localIndices = chart.chart.mesh.triangleIndices
            let faceCount = min(chart.chart.sourceFaceIDs.count, localIndices.count / 3)
            for localFace in 0..<faceCount {
                let sourceFace = chart.chart.sourceFaceIDs[localFace]
                let sourceStart = sourceFace * 3
                let localStart = localFace * 3
                guard sourceStart + 2 < sourceMesh.triangleIndices.count,
                      localStart + 2 < localIndices.count else { continue }

                let source = [
                    Int(sourceMesh.triangleIndices[sourceStart]),
                    Int(sourceMesh.triangleIndices[sourceStart + 1]),
                    Int(sourceMesh.triangleIndices[sourceStart + 2])
                ]
                let local = [
                    Int(localIndices[localStart]),
                    Int(localIndices[localStart + 1]),
                    Int(localIndices[localStart + 2])
                ]
                for edge in [(0, 1), (1, 2), (2, 0)] {
                    guard sourceMesh.vertices.indices.contains(source[edge.0]),
                          sourceMesh.vertices.indices.contains(source[edge.1]),
                          chart.uvByVertex.indices.contains(local[edge.0]),
                          chart.uvByVertex.indices.contains(local[edge.1]) else { continue }
                    let length = distance(chart.uvByVertex[local[edge.0]], chart.uvByVertex[local[edge.1]])
                    guard length.isFinite, length > 1.0e-6 else { continue }
                    let key = EdgeKey(source[edge.0], source[edge.1])
                    let existing = totals[key] ?? (0, 0)
                    totals[key] = (existing.sum + length, existing.count + 1)
                }
            }
        }

        return totals.reduce(into: [:]) { result, item in
            result[item.key] = item.value.sum / Double(max(item.value.count, 1))
        }
    }

    private static func inflateVertices(
        _ sourceVertices: [Vec3],
        indices: [Int32],
        restLengths: [EdgeKey: Double]
    ) -> [Vec3] {
        var positions = sourceVertices
        let originalCentroid = centroid(sourceVertices)
        let diagonal = max(boundsDiagonal(sourceVertices), 1.0)
        let constraints = edgeConstraints(indices: indices, vertices: sourceVertices, restLengths: restLengths)
        guard !constraints.isEmpty else { return positions }

        let pressureStep = diagonal * 0.0018
        for _ in 0..<42 {
            let normals = vertexNormals(vertices: positions, indices: indices, center: originalCentroid)
            for index in positions.indices {
                let normal = normals[index]
                positions[index] = add(positions[index], scale(normal, pressureStep))
            }

            for _ in 0..<8 {
                for constraint in constraints {
                    let delta = subtract(positions[constraint.b], positions[constraint.a])
                    let length = vectorLength(delta)
                    guard length > 1.0e-9, length > constraint.restLength else { continue }
                    let correction = scale(delta, 0.5 * (length - constraint.restLength) / length)
                    positions[constraint.a] = add(positions[constraint.a], correction)
                    positions[constraint.b] = subtract(positions[constraint.b], correction)
                }
            }

            let drift = subtract(centroid(positions), originalCentroid)
            if vectorLength(drift) > 1.0e-9 {
                positions = positions.map { subtract($0, drift) }
            }
        }
        return positions
    }

    private struct EdgeConstraint {
        var a: Int
        var b: Int
        var restLength: Double
    }

    private static func edgeConstraints(
        indices: [Int32],
        vertices: [Vec3],
        restLengths: [EdgeKey: Double]
    ) -> [EdgeConstraint] {
        var seen = Set<EdgeKey>()
        var result: [EdgeConstraint] = []
        var offset = 0
        while offset + 2 < indices.count {
            let tri = [Int(indices[offset]), Int(indices[offset + 1]), Int(indices[offset + 2])]
            for edge in [(0, 1), (1, 2), (2, 0)] {
                let a = tri[edge.0], b = tri[edge.1]
                guard vertices.indices.contains(a), vertices.indices.contains(b) else { continue }
                let key = EdgeKey(a, b)
                guard seen.insert(key).inserted else { continue }
                let rest = restLengths[key] ?? distance(vertices[a], vertices[b])
                if rest.isFinite, rest > 1.0e-6 {
                    result.append(EdgeConstraint(a: key.a, b: key.b, restLength: rest))
                }
            }
            offset += 3
        }
        return result
    }

    private static func deviationByVertex(inflated: [Vec3], target: MeshGeometryData) -> [Double] {
        guard !target.vertices.isEmpty, target.triangleIndices.count >= 3 else {
            return Array(repeating: 0, count: inflated.count)
        }
        if inflated.count == target.vertices.count, target.triangleIndices.count / 3 > 2_500 {
            return zip(inflated, target.vertices).map { distance($0.0, $0.1) }
        }
        return inflated.map { point in
            var best = Double.greatestFiniteMagnitude
            var offset = 0
            while offset + 2 < target.triangleIndices.count {
                let ia = Int(target.triangleIndices[offset])
                let ib = Int(target.triangleIndices[offset + 1])
                let ic = Int(target.triangleIndices[offset + 2])
                if target.vertices.indices.contains(ia),
                   target.vertices.indices.contains(ib),
                   target.vertices.indices.contains(ic) {
                    best = min(best, pointTriangleDistance(point, target.vertices[ia], target.vertices[ib], target.vertices[ic]))
                }
                offset += 3
            }
            return best.isFinite ? best : 0
        }
    }

    private static func panelErrors(
        flattened: [InflatableFlattenedChart],
        mesh: MeshGeometryData,
        deviation: [Double]
    ) -> [String: Double] {
        var errors: [String: Double] = [:]
        for chart in flattened {
            var maxError = 0.0
            for faceID in chart.chart.sourceFaceIDs {
                let start = faceID * 3
                guard start + 2 < mesh.triangleIndices.count else { continue }
                for raw in [mesh.triangleIndices[start], mesh.triangleIndices[start + 1], mesh.triangleIndices[start + 2]] {
                    let index = Int(raw)
                    if deviation.indices.contains(index) {
                        maxError = max(maxError, deviation[index])
                    }
                }
            }
            errors[chart.chart.id] = maxError
        }
        return errors
    }

    private static func representativePoint(for chart: InflatableChart, in mesh: MeshGeometryData) -> Vec3? {
        var points: [Vec3] = []
        for faceID in chart.sourceFaceIDs.prefix(8) {
            let start = faceID * 3
            guard start + 2 < mesh.triangleIndices.count else { continue }
            for raw in [mesh.triangleIndices[start], mesh.triangleIndices[start + 1], mesh.triangleIndices[start + 2]] {
                let index = Int(raw)
                if mesh.vertices.indices.contains(index) {
                    points.append(mesh.vertices[index])
                }
            }
        }
        return points.isEmpty ? nil : centroid(points)
    }

    private static func vertexNormals(vertices: [Vec3], indices: [Int32], center: Vec3) -> [Vec3] {
        var normals = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: vertices.count)
        var offset = 0
        while offset + 2 < indices.count {
            let ia = Int(indices[offset])
            let ib = Int(indices[offset + 1])
            let ic = Int(indices[offset + 2])
            guard vertices.indices.contains(ia), vertices.indices.contains(ib), vertices.indices.contains(ic) else {
                offset += 3
                continue
            }
            let faceNormal = cross(subtract(vertices[ib], vertices[ia]), subtract(vertices[ic], vertices[ia]))
            let faceCenter = centroid([vertices[ia], vertices[ib], vertices[ic]])
            let outward = dot(faceNormal, subtract(faceCenter, center)) < 0 ? scale(faceNormal, -1) : faceNormal
            normals[ia] = add(normals[ia], outward)
            normals[ib] = add(normals[ib], outward)
            normals[ic] = add(normals[ic], outward)
            offset += 3
        }
        return normals.map { normal in
            if let unit = normalized(normal) {
                return unit
            }
            return Vec3(x: 0, y: 0, z: 1)
        }
    }

    private static func pointTriangleDistance(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let ab = subtract(b, a)
        let ac = subtract(c, a)
        let ap = subtract(p, a)
        let d1 = dot(ab, ap)
        let d2 = dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return distance(p, a) }

        let bp = subtract(p, b)
        let d3 = dot(ab, bp)
        let d4 = dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return distance(p, b) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return distance(p, add(a, scale(ab, v)))
        }

        let cp = subtract(p, c)
        let d5 = dot(ab, cp)
        let d6 = dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return distance(p, c) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return distance(p, add(a, scale(ac, w)))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return distance(p, add(b, scale(subtract(c, b), w)))
        }

        let normal = normalized(cross(ab, ac)) ?? Vec3(x: 0, y: 0, z: 1)
        return abs(dot(subtract(p, a), normal))
    }

    private static func boundsDiagonal(_ vertices: [Vec3]) -> Double {
        guard let first = vertices.first else { return 0 }
        var minV = first
        var maxV = first
        for v in vertices {
            minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
            maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
        }
        return distance(minV, maxV)
    }

    private static func centroid(_ vertices: [Vec3]) -> Vec3 {
        guard !vertices.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        let sum = vertices.reduce(Vec3(x: 0, y: 0, z: 0)) { partial, point in
            add(partial, point)
        }
        return scale(sum, 1 / Double(vertices.count))
    }

    private static func normalized(_ value: Vec3) -> Vec3? {
        let length = vectorLength(value)
        guard length > 1.0e-9, length.isFinite else { return nil }
        return scale(value, 1 / length)
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

    private static func vectorLength(_ value: Vec3) -> Double {
        dot(value, value).squareRoot()
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        vectorLength(subtract(a, b))
    }

    private static func distance(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
