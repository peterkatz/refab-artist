import Foundation

/// Converts violating columns into deterministic, face-backed undercut regions.
enum UndercutRegionClusterer {
    struct FaceRecord: Equatable {
        let id: Int
        let vertexIndices: (Int, Int, Int)
        let vertices: (Vec3, Vec3, Vec3)
        let centroid: Vec3
        let normal: Vec3
        let areaMM2: Double

        static func == (lhs: FaceRecord, rhs: FaceRecord) -> Bool {
            lhs.id == rhs.id
                && lhs.vertexIndices.0 == rhs.vertexIndices.0
                && lhs.vertexIndices.1 == rhs.vertexIndices.1
                && lhs.vertexIndices.2 == rhs.vertexIndices.2
                && lhs.vertices.0 == rhs.vertices.0
                && lhs.vertices.1 == rhs.vertices.1
                && lhs.vertices.2 == rhs.vertices.2
                && lhs.centroid == rhs.centroid
                && lhs.normal == rhs.normal
                && lhs.areaMM2 == rhs.areaMM2
        }
    }

    struct ViolatingColumn: Equatable {
        let projectedU: Double
        let projectedV: Double
        let depthMM: Double
        let blockingFaceIDs: [Int]
        let suggestedEscapeDirections: [Vec3]
    }

    struct Region: Codable, Equatable {
        let id: String
        let faceIDs: [Int]
        let areaMM2: Double
        let depthMM: Double
        let centroid: Vec3
        let suggestedEscapeDirections: [Vec3]
    }

    static func cluster(
        faces: [FaceRecord],
        violatingColumns: [ViolatingColumn],
        gridStepMM: Double,
        weldToleranceMM: Double
    ) -> [Region] {
        let faceByID = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let implicatedIDs = Set(violatingColumns.flatMap(\.blockingFaceIDs))
        guard !implicatedIDs.isEmpty else { return [] }

        let orderedIDs = implicatedIDs.sorted()
        let denseIndex = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        var unionFind = UnionFind(count: orderedIDs.count)

        // The two sides that trap one sampled gap are one measured feature even
        // when their surface patches are separated by the gap itself.
        for column in violatingColumns {
            let ids = column.blockingFaceIDs.filter { implicatedIDs.contains($0) }.sorted()
            guard let first = ids.first, let firstDense = denseIndex[first] else { continue }
            for id in ids.dropFirst() {
                if let otherDense = denseIndex[id] { unionFind.union(firstDense, otherDense) }
            }
        }

        // Topological face adjacency: shared mesh edge.
        var facesByEdge: [GeometricEdge: [Int]] = [:]
        for id in orderedIDs {
            guard let face = faceByID[id] else { continue }
            let (a, b, c) = face.vertices
            for edge in [
                GeometricEdge(a, b, tolerance: weldToleranceMM),
                GeometricEdge(b, c, tolerance: weldToleranceMM),
                GeometricEdge(c, a, tolerance: weldToleranceMM),
            ] {
                facesByEdge[edge, default: []].append(id)
            }
        }
        var hasImplicatedAdjacency: Set<Int> = []
        for ids in facesByEdge.values where ids.count > 1 {
            let sorted = ids.sorted()
            guard let first = sorted.first, let firstDense = denseIndex[first] else { continue }
            for id in sorted.dropFirst() {
                guard let otherDense = denseIndex[id] else { continue }
                unionFind.union(firstDense, otherDense)
                hasImplicatedAdjacency.insert(first)
                hasImplicatedAdjacency.insert(id)
            }
        }

        // Meshes with benign self-contact can use duplicate vertices at the
        // contact. For implicated faces lacking topological neighbors, connect
        // patches whose vertices are spatially close at twice the sample step.
        let proximity = max(gridStepMM * 2, 1.0e-9)
        let isolated = orderedIDs.filter { !hasImplicatedAdjacency.contains($0) }
        var spatialBuckets: [GridKey: [(faceID: Int, point: Vec3)]] = [:]
        for id in isolated {
            guard let face = faceByID[id] else { continue }
            for point in [face.vertices.0, face.vertices.1, face.vertices.2] {
                spatialBuckets[GridKey(point, cellSize: proximity), default: []].append((id, point))
            }
        }
        let proximitySquared = proximity * proximity
        for id in isolated {
            guard let face = faceByID[id], let firstDense = denseIndex[id] else { continue }
            for point in [face.vertices.0, face.vertices.1, face.vertices.2] {
                let key = GridKey(point, cellSize: proximity)
                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            let neighbor = GridKey(x: key.x + dx, y: key.y + dy, z: key.z + dz)
                            for candidate in spatialBuckets[neighbor] ?? [] where candidate.faceID > id {
                                let delta = subtract(point, candidate.point)
                                if dot(delta, delta) <= proximitySquared,
                                   let otherDense = denseIndex[candidate.faceID] {
                                    unionFind.union(firstDense, otherDense)
                                }
                            }
                        }
                    }
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for id in orderedIDs {
            guard let index = denseIndex[id] else { continue }
            groups[unionFind.find(index), default: []].append(id)
        }

        var regions: [Region] = []
        regions.reserveCapacity(groups.count)
        for ids in groups.values {
            let faceIDs = ids.sorted()
            let idSet = Set(faceIDs)
            var totalArea = 0.0
            var weightedCentroid = Vec3(x: 0, y: 0, z: 0)
            for id in faceIDs {
                guard let face = faceByID[id] else { continue }
                totalArea += face.areaMM2
                weightedCentroid = add(weightedCentroid, scale(face.centroid, face.areaMM2))
            }
            let centroid: Vec3
            if totalArea > 0 {
                centroid = scale(weightedCentroid, 1.0 / totalArea)
            } else {
                centroid = Vec3(x: 0, y: 0, z: 0)
            }

            let columns = violatingColumns.filter { column in
                column.blockingFaceIDs.contains(where: idSet.contains)
            }
            let depth = columns.map(\.depthMM).max() ?? 0
            var directions: [Vec3] = []
            for direction in columns.flatMap(\.suggestedEscapeDirections) {
                guard let normalized = normalized(direction) else { continue }
                if directions.contains(where: { dot($0, normalized) >= 1.0 - 1.0e-10 }) { continue }
                directions.append(normalized)
            }
            directions.sort(by: stableLessThan)

            regions.append(Region(
                id: contentID(faceIDs: faceIDs),
                faceIDs: faceIDs,
                areaMM2: totalArea,
                depthMM: depth,
                centroid: centroid,
                suggestedEscapeDirections: directions
            ))
        }

        return regions.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.faceIDs.lexicographicallyPrecedes($1.faceIDs)
        }
    }

    private static func contentID(faceIDs: [Int]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for faceID in faceIDs {
            var value = UInt64(bitPattern: Int64(faceID))
            for _ in 0..<8 {
                hash ^= value & 0xff
                hash &*= 1_099_511_628_211
                value >>= 8
            }
        }
        return String(format: "undercut-%016llx", hash)
    }

    private struct GeometricEdge: Hashable {
        let lower: WeldedVertex
        let upper: WeldedVertex

        init(_ a: Vec3, _ b: Vec3, tolerance: Double) {
            let first = WeldedVertex(a, tolerance: tolerance)
            let second = WeldedVertex(b, tolerance: tolerance)
            lower = min(first, second)
            upper = max(first, second)
        }
    }

    private struct WeldedVertex: Hashable, Comparable {
        let x: Int64
        let y: Int64
        let z: Int64

        init(_ point: Vec3, tolerance: Double) {
            x = Self.quantize(point.x, tolerance: tolerance)
            y = Self.quantize(point.y, tolerance: tolerance)
            z = Self.quantize(point.z, tolerance: tolerance)
        }

        static func < (lhs: WeldedVertex, rhs: WeldedVertex) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }

        private static func quantize(_ value: Double, tolerance: Double) -> Int64 {
            let scaled = value / tolerance
            if !scaled.isFinite { return scaled.sign == .minus ? Int64.min : Int64.max }
            if scaled >= Double(Int64.max) { return Int64.max }
            if scaled <= Double(Int64.min) { return Int64.min }
            return Int64(scaled.rounded())
        }
    }

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(_ point: Vec3, cellSize: Double) {
            x = Self.cell(point.x, size: cellSize)
            y = Self.cell(point.y, size: cellSize)
            z = Self.cell(point.z, size: cellSize)
        }

        init(x: Int, y: Int, z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }

        private static func cell(_ value: Double, size: Double) -> Int {
            let scaled = floor(value / size)
            if !scaled.isFinite { return scaled.sign == .minus ? Int.min : Int.max }
            if scaled >= Double(Int.max) { return Int.max }
            if scaled <= Double(Int.min) { return Int.min }
            return Int(scaled)
        }
    }

    private struct UnionFind {
        private var parents: [Int]
        private var ranks: [UInt8]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ index: Int) -> Int {
            if parents[index] != index {
                parents[index] = find(parents[index])
            }
            return parents[index]
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let leftRoot = find(lhs)
            let rightRoot = find(rhs)
            guard leftRoot != rightRoot else { return }
            if ranks[leftRoot] < ranks[rightRoot] {
                parents[leftRoot] = rightRoot
            } else if ranks[leftRoot] > ranks[rightRoot] {
                parents[rightRoot] = leftRoot
            } else {
                parents[rightRoot] = leftRoot
                ranks[leftRoot] &+= 1
            }
        }
    }

    private static func stableLessThan(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        [lhs.x, lhs.y, lhs.z].lexicographicallyPrecedes([rhs.x, rhs.y, rhs.z])
    }

    private static func normalized(_ value: Vec3) -> Vec3? {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { return nil }
        let squared = dot(value, value)
        guard squared.isFinite, squared > 1.0e-24 else { return nil }
        return scale(value, 1.0 / sqrt(squared))
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
}
