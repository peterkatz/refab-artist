import Foundation

/// Deterministic, undirected pull-axis candidates for Split by Undercuts.
enum PullDirectionCandidates {
    struct Generation: Equatable {
        let directions: [Vec3]
        /// The §4.2 counts name raw antipodally symmetric icosphere vertices.
        let rawIcosphereVertexCount: Int
        /// Pull axes are undirected, so canonical d/-d pairs collapse by half.
        let uniqueIcosphereAxisCount: Int
    }

    static func generate(
        geometry: MeshGeometryData,
        icosphereVertexCount: Int,
        fixedAxis: Vec3? = nil,
        lockedAxes: [Vec3] = []
    ) -> [Vec3] {
        generateDetailed(
            geometry: geometry,
            icosphereVertexCount: icosphereVertexCount,
            fixedAxis: fixedAxis,
            lockedAxes: lockedAxes
        ).directions
    }

    static func generateDetailed(
        geometry: MeshGeometryData,
        icosphereVertexCount: Int,
        fixedAxis: Vec3? = nil,
        lockedAxes: [Vec3] = []
    ) -> Generation {
        let icosphere = icosphereVertices(closestTo: icosphereVertexCount)
        var raw: [Vec3] = [
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 0, y: 0, z: 1),
        ]

        raw.append(contentsOf: principalAxes(of: geometry.vertices))
        raw.append(contentsOf: prominentFaceNormals(in: geometry, maximumCount: 24))
        raw.append(contentsOf: clusteredFaceNormals(in: geometry, maximumCount: 12))
        raw.append(contentsOf: icosphere)
        if let fixedAxis { raw.append(fixedAxis) }
        raw.append(contentsOf: lockedAxes)

        var unique: [Vec3] = []
        for rawDirection in raw {
            guard let direction = canonicalized(rawDirection) else { continue }
            if unique.contains(where: { abs(dot($0, direction)) >= 1.0 - 1.0e-10 }) {
                continue
            }
            unique.append(direction)
        }

        let uniqueIcosphereAxes = deduplicatedAxes(icosphere)
        return Generation(
            directions: unique.sorted(by: stableLessThan),
            rawIcosphereVertexCount: icosphere.count,
            uniqueIcosphereAxisCount: uniqueIcosphereAxes.count
        )
    }

    private static func deduplicatedAxes(_ values: [Vec3]) -> [Vec3] {
        var result: [Vec3] = []
        for value in values {
            guard let canonical = canonicalized(value) else { continue }
            if result.contains(where: { abs(dot($0, canonical)) >= 1.0 - 1.0e-10 }) { continue }
            result.append(canonical)
        }
        return result.sorted(by: stableLessThan)
    }

    static func isSignCanonical(_ direction: Vec3) -> Bool {
        guard let canonical = canonicalized(direction) else { return false }
        return abs(canonical.x - direction.x) <= 1.0e-10
            && abs(canonical.y - direction.y) <= 1.0e-10
            && abs(canonical.z - direction.z) <= 1.0e-10
    }

    static func canonicalized(_ raw: Vec3) -> Vec3? {
        guard raw.x.isFinite, raw.y.isFinite, raw.z.isFinite else { return nil }
        let lengthSquared = dot(raw, raw)
        guard lengthSquared.isFinite, lengthSquared > 1.0e-24 else { return nil }
        let inverseLength = 1.0 / sqrt(lengthSquared)
        var value = Vec3(
            x: raw.x * inverseLength,
            y: raw.y * inverseLength,
            z: raw.z * inverseLength
        )
        let first = [value.x, value.y, value.z].first { abs($0) > 1.0e-12 } ?? 0
        if first < 0 {
            value = Vec3(x: -value.x, y: -value.y, z: -value.z)
        }
        value.x = abs(value.x) < 1.0e-15 ? 0 : value.x
        value.y = abs(value.y) < 1.0e-15 ? 0 : value.y
        value.z = abs(value.z) < 1.0e-15 ? 0 : value.z
        return value
    }

    // MARK: - Mesh-derived directions

    private static func prominentFaceNormals(
        in geometry: MeshGeometryData,
        maximumCount: Int
    ) -> [Vec3] {
        triangleNormals(in: geometry)
            .sorted {
                if $0.area != $1.area { return $0.area > $1.area }
                return stableLessThan($0.normal, $1.normal)
            }
            .prefix(maximumCount)
            .map(\.normal)
    }

    private static func clusteredFaceNormals(
        in geometry: MeshGeometryData,
        maximumCount: Int
    ) -> [Vec3] {
        struct Accumulator {
            var sum = Vec3(x: 0, y: 0, z: 0)
            var area = 0.0
        }

        var bins: [NormalBin: Accumulator] = [:]
        for face in triangleNormals(in: geometry) {
            let bin = NormalBin(face.normal)
            var accumulator = bins[bin] ?? Accumulator()
            accumulator.sum = add(accumulator.sum, scale(face.normal, face.area))
            accumulator.area += face.area
            bins[bin] = accumulator
        }

        return bins.map { (key: $0.key, value: $0.value) }
            .sorted {
                if $0.value.area != $1.value.area { return $0.value.area > $1.value.area }
                return $0.key < $1.key
            }
            .prefix(maximumCount)
            .compactMap { canonicalized($0.value.sum) }
    }

    private struct NormalBin: Hashable, Comparable {
        let x: Int
        let y: Int
        let z: Int

        init(_ normal: Vec3) {
            x = Int((normal.x * 10).rounded())
            y = Int((normal.y * 10).rounded())
            z = Int((normal.z * 10).rounded())
        }

        static func < (lhs: NormalBin, rhs: NormalBin) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct FaceNormal {
        let normal: Vec3
        let area: Double
    }

    private static func triangleNormals(in geometry: MeshGeometryData) -> [FaceNormal] {
        let vertices = geometry.vertices
        let indices = geometry.triangleIndices
        var result: [FaceNormal] = []
        result.reserveCapacity(indices.count / 3)
        var index = 0
        while index + 2 < indices.count {
            let ia = Int(indices[index])
            let ib = Int(indices[index + 1])
            let ic = Int(indices[index + 2])
            index += 3
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else { continue }
            let ab = subtract(vertices[ib], vertices[ia])
            let ac = subtract(vertices[ic], vertices[ia])
            let crossProduct = cross(ab, ac)
            let twiceArea = sqrt(dot(crossProduct, crossProduct))
            guard twiceArea.isFinite, twiceArea > 1.0e-12,
                  let normal = canonicalized(crossProduct) else { continue }
            result.append(FaceNormal(normal: normal, area: twiceArea / 2))
        }
        return result
    }

    /// Principal component axes also serve as the deterministic oriented-bounds
    /// frame. A symmetric 3x3 Jacobi solve avoids adding a linear-algebra
    /// dependency.
    private static func principalAxes(of vertices: [Vec3]) -> [Vec3] {
        guard !vertices.isEmpty else { return [] }
        let count = Double(vertices.count)
        let centroid = vertices.reduce(Vec3(x: 0, y: 0, z: 0), add)
        let center = scale(centroid, 1.0 / count)
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for vertex in vertices {
            let p = subtract(vertex, center)
            let values = [p.x, p.y, p.z]
            for row in 0..<3 {
                for column in row..<3 {
                    matrix[row][column] += values[row] * values[column]
                    matrix[column][row] = matrix[row][column]
                }
            }
        }
        var eigenvectors = [
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, 0.0, 1.0],
        ]

        for _ in 0..<24 {
            var p = 0
            var q = 1
            var largest = abs(matrix[0][1])
            for row in 0..<3 {
                for column in (row + 1)..<3 where abs(matrix[row][column]) > largest {
                    p = row
                    q = column
                    largest = abs(matrix[row][column])
                }
            }
            if largest < 1.0e-12 { break }
            let angle = 0.5 * atan2(2 * matrix[p][q], matrix[q][q] - matrix[p][p])
            let cosine = cos(angle)
            let sine = sin(angle)

            for row in 0..<3 where row != p && row != q {
                let rp = matrix[row][p]
                let rq = matrix[row][q]
                matrix[row][p] = cosine * rp - sine * rq
                matrix[p][row] = matrix[row][p]
                matrix[row][q] = sine * rp + cosine * rq
                matrix[q][row] = matrix[row][q]
            }
            let pp = matrix[p][p]
            let qq = matrix[q][q]
            let pq = matrix[p][q]
            matrix[p][p] = cosine * cosine * pp - 2 * sine * cosine * pq + sine * sine * qq
            matrix[q][q] = sine * sine * pp + 2 * sine * cosine * pq + cosine * cosine * qq
            matrix[p][q] = 0
            matrix[q][p] = 0

            for row in 0..<3 {
                let vp = eigenvectors[row][p]
                let vq = eigenvectors[row][q]
                eigenvectors[row][p] = cosine * vp - sine * vq
                eigenvectors[row][q] = sine * vp + cosine * vq
            }
        }

        return (0..<3).map { column in
            (value: matrix[column][column], axis: Vec3(
                x: eigenvectors[0][column],
                y: eigenvectors[1][column],
                z: eigenvectors[2][column]
            ))
        }
        .sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return stableLessThan($0.axis, $1.axis)
        }
        .compactMap { canonicalized($0.axis) }
    }

    // MARK: - Icosphere

    private static func icosphereVertices(closestTo requestedCount: Int) -> [Vec3] {
        let subdivision: Int
        if requestedCount >= 642 {
            subdivision = 3
        } else if requestedCount >= 162 {
            subdivision = 2
        } else if requestedCount >= 42 {
            subdivision = 1
        } else {
            subdivision = 0
        }

        let golden = (1.0 + sqrt(5.0)) / 2.0
        var vertices = [
            Vec3(x: -1, y: golden, z: 0), Vec3(x: 1, y: golden, z: 0),
            Vec3(x: -1, y: -golden, z: 0), Vec3(x: 1, y: -golden, z: 0),
            Vec3(x: 0, y: -1, z: golden), Vec3(x: 0, y: 1, z: golden),
            Vec3(x: 0, y: -1, z: -golden), Vec3(x: 0, y: 1, z: -golden),
            Vec3(x: golden, y: 0, z: -1), Vec3(x: golden, y: 0, z: 1),
            Vec3(x: -golden, y: 0, z: -1), Vec3(x: -golden, y: 0, z: 1),
        ].compactMap(canonicalUnitWithoutSign)

        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        for _ in 0..<subdivision {
            var midpointCache: [Edge: Int] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let edge = Edge(a, b)
                if let existing = midpointCache[edge] { return existing }
                let point = scale(add(vertices[a], vertices[b]), 0.5)
                let normalized = canonicalUnitWithoutSign(point) ?? Vec3(x: 0, y: 0, z: 1)
                vertices.append(normalized)
                let index = vertices.count - 1
                midpointCache[edge] = index
                return index
            }
            var refined: [(Int, Int, Int)] = []
            refined.reserveCapacity(faces.count * 4)
            for face in faces {
                let ab = midpoint(face.0, face.1)
                let bc = midpoint(face.1, face.2)
                let ca = midpoint(face.2, face.0)
                refined.append((face.0, ab, ca))
                refined.append((face.1, bc, ab))
                refined.append((face.2, ca, bc))
                refined.append((ab, bc, ca))
            }
            faces = refined
        }
        return vertices
    }

    private struct Edge: Hashable {
        let lower: Int
        let upper: Int

        init(_ a: Int, _ b: Int) {
            lower = min(a, b)
            upper = max(a, b)
        }
    }

    // MARK: - Math

    private static func canonicalUnitWithoutSign(_ value: Vec3) -> Vec3? {
        let squared = dot(value, value)
        guard squared.isFinite, squared > 1.0e-24 else { return nil }
        return scale(value, 1.0 / sqrt(squared))
    }

    private static func stableLessThan(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        let left = [lhs.x, lhs.y, lhs.z]
        let right = [rhs.x, rhs.y, rhs.z]
        let leftQuantized = left.map { Int64(($0 * 1_000_000_000).rounded()) }
        let rightQuantized = right.map { Int64(($0 * 1_000_000_000).rounded()) }
        if leftQuantized != rightQuantized {
            return leftQuantized.lexicographicallyPrecedes(rightQuantized)
        }
        return left.lexicographicallyPrecedes(right)
    }

    @inline(__always) private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inline(__always) private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    @inline(__always) private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    @inline(__always) private static func scale(_ value: Vec3, _ amount: Double) -> Vec3 {
        Vec3(x: value.x * amount, y: value.y * amount, z: value.z * amount)
    }

    @inline(__always) private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }
}
