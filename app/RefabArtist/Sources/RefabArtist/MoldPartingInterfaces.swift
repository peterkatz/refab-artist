import Foundation

/// Resolves the physical part pairs created by mathematical parting planes.
/// One plane creates one interface in a two-part mold, but two orthogonal
/// planes create four interfaces in a four-part mold: two segments per plane.
/// Key and flange counts are defined against these physical pairs.
enum MoldPartingInterfaces {
    struct Interface: Equatable {
        var planeIndex: Int
        var segmentIndex: Int
        var plane: PartitionPlane
        var negativePartIndex: Int
        var positivePartIndex: Int

        var label: String {
            "\(planeIndex + 1)\(Character(UnicodeScalar(65 + segmentIndex)!))"
        }
    }

    static func resolve(
        parts: [MotherMoldPart],
        planes: [PartitionPlane]
    ) -> [Interface] {
        guard parts.count >= 2, !planes.isEmpty else { return [] }
        let centroids = parts.map { areaWeightedCentroid($0.geometry) }
        var result: [Interface] = []

        for (planeIndex, plane) in planes.enumerated() {
            struct PairGroup {
                var negative: [Int] = []
                var positive: [Int] = []
            }
            var groups: [String: PairGroup] = [:]

            for partIndex in parts.indices {
                guard let centroid = centroids[partIndex] else { continue }
                let signature = planes.enumerated()
                    .filter { $0.offset != planeIndex }
                    .map { _, other in
                        signedDistance(centroid, to: other) >= 0 ? "1" : "0"
                    }
                    .joined()
                var group = groups[signature] ?? PairGroup()
                if signedDistance(centroid, to: plane) >= 0 {
                    group.positive.append(partIndex)
                } else {
                    group.negative.append(partIndex)
                }
                groups[signature] = group
            }

            var segmentIndex = 0
            for signature in groups.keys.sorted() {
                guard let group = groups[signature],
                      group.negative.count == 1,
                      group.positive.count == 1 else {
                    continue
                }
                result.append(Interface(
                    planeIndex: planeIndex,
                    segmentIndex: segmentIndex,
                    plane: plane,
                    negativePartIndex: group.negative[0],
                    positivePartIndex: group.positive[0]
                ))
                segmentIndex += 1
            }
        }
        return result
    }

    private static func signedDistance(_ point: Vec3, to plane: PartitionPlane) -> Double {
        point.x * plane.normal.x
            + point.y * plane.normal.y
            + point.z * plane.normal.z
            - plane.offset
    }

    private static func areaWeightedCentroid(_ geometry: MeshGeometryData) -> Vec3? {
        let vertices = geometry.vertices
        let indices = geometry.triangleIndices
        guard !vertices.isEmpty, indices.count >= 3 else { return nil }
        var weighted = Vec3(x: 0, y: 0, z: 0)
        var totalArea = 0.0

        for start in stride(from: 0, to: indices.count - 2, by: 3) {
            let ia = Int(indices[start])
            let ib = Int(indices[start + 1])
            let ic = Int(indices[start + 2])
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else { continue }
            let a = vertices[ia]
            let b = vertices[ib]
            let c = vertices[ic]
            let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            let cross = Vec3(
                x: ab.y * ac.z - ab.z * ac.y,
                y: ab.z * ac.x - ab.x * ac.z,
                z: ab.x * ac.y - ab.y * ac.x
            )
            let area = 0.5 * (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
            guard area > 1.0e-12 else { continue }
            let center = Vec3(
                x: (a.x + b.x + c.x) / 3,
                y: (a.y + b.y + c.y) / 3,
                z: (a.z + b.z + c.z) / 3
            )
            weighted.x += center.x * area
            weighted.y += center.y * area
            weighted.z += center.z * area
            totalArea += area
        }

        guard totalArea > 1.0e-12 else {
            let sum = vertices.reduce(Vec3(x: 0, y: 0, z: 0)) {
                Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
            }
            let count = Double(vertices.count)
            return Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
        }
        return Vec3(
            x: weighted.x / totalArea,
            y: weighted.y / totalArea,
            z: weighted.z / totalArea
        )
    }
}
