import Foundation

/// Quadric-error-metric mesh decimation (Garland–Heckbert edge collapse).
///
/// Properties the folded pipeline relies on, enforced per collapse:
/// - link condition (no pinched / non-manifold vertices introduced)
/// - normal-flip rejection (no inverted panels)
/// - boundary constraint quadrics (open-mesh borders stay put)
/// Symmetric 4x4 error quadric stored as 10 coefficients.
private struct QEMQuadric {
    var q00 = 0.0, q01 = 0.0, q02 = 0.0, q03 = 0.0
    var q11 = 0.0, q12 = 0.0, q13 = 0.0
    var q22 = 0.0, q23 = 0.0
    var q33 = 0.0

    mutating func addPlane(a: Double, b: Double, c: Double, d: Double, weight: Double = 1.0) {
        q00 += weight * a * a
        q01 += weight * a * b
        q02 += weight * a * c
        q03 += weight * a * d
        q11 += weight * b * b
        q12 += weight * b * c
        q13 += weight * b * d
        q22 += weight * c * c
        q23 += weight * c * d
        q33 += weight * d * d
    }

    func adding(_ other: QEMQuadric) -> QEMQuadric {
        var out = self
        out.q00 += other.q00
        out.q01 += other.q01
        out.q02 += other.q02
        out.q03 += other.q03
        out.q11 += other.q11
        out.q12 += other.q12
        out.q13 += other.q13
        out.q22 += other.q22
        out.q23 += other.q23
        out.q33 += other.q33
        return out
    }

    func error(_ p: Vec3) -> Double {
        let x = p.x
        let y = p.y
        let z = p.z
        let a = q00 * x * x + 2 * q01 * x * y + 2 * q02 * x * z + 2 * q03 * x
        let b = q11 * y * y + 2 * q12 * y * z + 2 * q13 * y
        let c = q22 * z * z + 2 * q23 * z + q33
        return a + b + c
    }

    /// Minimizing position, or nil when the 3x3 system is singular.
    func optimalPoint() -> Vec3? {
        let a00 = q00
        let a01 = q01
        let a02 = q02
        let a11 = q11
        let a12 = q12
        let a22 = q22
        let det = a00 * (a11 * a22 - a12 * a12)
            - a01 * (a01 * a22 - a12 * a02)
            + a02 * (a01 * a12 - a11 * a02)
        guard abs(det) > 1.0e-9 else { return nil }
        let bx = -q03
        let by = -q13
        let bz = -q23
        let inv = 1.0 / det
        let x = inv * (bx * (a11 * a22 - a12 * a12) + by * (a02 * a12 - a01 * a22) + bz * (a01 * a12 - a02 * a11))
        let y = inv * (bx * (a12 * a02 - a01 * a22) + by * (a00 * a22 - a02 * a02) + bz * (a01 * a02 - a00 * a12))
        let z = inv * (bx * (a01 * a12 - a11 * a02) + by * (a01 * a02 - a00 * a12) + bz * (a00 * a11 - a01 * a01))
        let point = Vec3(x: x, y: y, z: z)
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        return point
    }
}

enum MeshSimplifier {
    /// Collapse edges until at most `targetFaceCount` triangles remain.
    /// Returns the original summary untouched when it is already at or under
    /// the target; nil when the input has no usable triangles.
    static func simplify(_ model: MeshSummary, targetFaceCount: Int) -> MeshSummary? {
        let target = max(4, targetFaceCount)
        guard model.triangleCount > target else { return model }

        // --- Weld duplicate positions (STL-style soup -> indexed) ---------
        // Quantized to the same 1e-6 tolerance MeshPreflight uses: STL
        // exporters emit shared vertices differing in the last ulp, and a
        // bit-exact weld would leave cracks that surface as boundary edges
        // after collapse.
        struct PositionKey: Hashable {
            let x: Int64
            let y: Int64
            let z: Int64
            init(_ v: Vec3) {
                x = Int64((v.x * 1.0e6).rounded())
                y = Int64((v.y * 1.0e6).rounded())
                z = Int64((v.z * 1.0e6).rounded())
            }
        }
        var welded: [Vec3] = []
        var remap = [Int32](repeating: 0, count: model.geometry.vertices.count)
        var seen: [PositionKey: Int32] = [:]
        seen.reserveCapacity(model.geometry.vertices.count)
        for (index, vertex) in model.geometry.vertices.enumerated() {
            let key = PositionKey(vertex)
            if let existing = seen[key] {
                remap[index] = existing
            } else {
                let id = Int32(welded.count)
                welded.append(vertex)
                seen[key] = id
                remap[index] = id
            }
        }

        var positions = welded
        var triangles: [(Int32, Int32, Int32)] = []
        triangles.reserveCapacity(model.geometry.triangleIndices.count / 3)
        var index = 0
        while index + 2 < model.geometry.triangleIndices.count {
            let a = remap[Int(model.geometry.triangleIndices[index])]
            let b = remap[Int(model.geometry.triangleIndices[index + 1])]
            let c = remap[Int(model.geometry.triangleIndices[index + 2])]
            index += 3
            if a == b || b == c || a == c { continue }
            triangles.append((a, b, c))
        }
        guard triangles.count > target else {
            return rebuild(model, positions: positions, triangles: triangles)
        }

        // --- Topology ------------------------------------------------------
        var triangleAlive = [Bool](repeating: true, count: triangles.count)
        var vertexTriangles = [[Int32]](repeating: [], count: positions.count)
        for (t, triangle) in triangles.enumerated() {
            vertexTriangles[Int(triangle.0)].append(Int32(t))
            vertexTriangles[Int(triangle.1)].append(Int32(t))
            vertexTriangles[Int(triangle.2)].append(Int32(t))
        }

        // --- Quadrics ------------------------------------------------------
        func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
        }
        func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        func length(_ v: Vec3) -> Double { dot(v, v).squareRoot() }
        func triangleNormal(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3? {
            let n = cross(subtract(b, a), subtract(c, a))
            let l = length(n)
            guard l > 1.0e-12 else { return nil }
            return Vec3(x: n.x / l, y: n.y / l, z: n.z / l)
        }

        var quadrics = [QEMQuadric](repeating: QEMQuadric(), count: positions.count)
        for triangle in triangles {
            let a = positions[Int(triangle.0)]
            let b = positions[Int(triangle.1)]
            let c = positions[Int(triangle.2)]
            guard let n = triangleNormal(a, b, c) else { continue }
            let d = -dot(n, a)
            quadrics[Int(triangle.0)].addPlane(a: n.x, b: n.y, c: n.z, d: d)
            quadrics[Int(triangle.1)].addPlane(a: n.x, b: n.y, c: n.z, d: d)
            quadrics[Int(triangle.2)].addPlane(a: n.x, b: n.y, c: n.z, d: d)
        }

        // Boundary edges (exactly one incident triangle) get a heavy
        // perpendicular constraint plane so open borders keep their shape.
        func edgeKey(_ a: Int32, _ b: Int32) -> UInt64 {
            let lo = UInt64(UInt32(bitPattern: min(a, b)))
            let hi = UInt64(UInt32(bitPattern: max(a, b)))
            return (hi << 32) | lo
        }
        var edgeTriangleCount: [UInt64: Int32] = [:]
        edgeTriangleCount.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            edgeTriangleCount[edgeKey(triangle.0, triangle.1), default: 0] += 1
            edgeTriangleCount[edgeKey(triangle.1, triangle.2), default: 0] += 1
            edgeTriangleCount[edgeKey(triangle.2, triangle.0), default: 0] += 1
        }
        for triangle in triangles {
            let corners = [triangle.0, triangle.1, triangle.2]
            for i in 0..<3 {
                let u = corners[i]
                let v = corners[(i + 1) % 3]
                guard edgeTriangleCount[edgeKey(u, v)] == 1 else { continue }
                let pu = positions[Int(u)]
                let pv = positions[Int(v)]
                let pw = positions[Int(corners[(i + 2) % 3])]
                guard let faceNormal = triangleNormal(pu, pv, pw) else { continue }
                let edgeDir = subtract(pv, pu)
                let constraint = cross(edgeDir, faceNormal)
                let l = length(constraint)
                guard l > 1.0e-12 else { continue }
                let n = Vec3(x: constraint.x / l, y: constraint.y / l, z: constraint.z / l)
                let d = -dot(n, pu)
                quadrics[Int(u)].addPlane(a: n.x, b: n.y, c: n.z, d: d, weight: 1000)
                quadrics[Int(v)].addPlane(a: n.x, b: n.y, c: n.z, d: d, weight: 1000)
            }
        }

        // --- Collapse loop ---------------------------------------------------
        var vertexVersion = [Int32](repeating: 0, count: positions.count)
        var vertexDead = [Bool](repeating: false, count: positions.count)

        struct Candidate {
            var cost: Double
            var u: Int32
            var v: Int32
            var versionU: Int32
            var versionV: Int32
            var target: Vec3
        }
        var heap: [Candidate] = []
        heap.reserveCapacity(triangles.count * 2)
        func heapPush(_ candidate: Candidate) {
            heap.append(candidate)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].cost < heap[parent].cost else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        func heapPop() -> Candidate? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    let right = left + 1
                    var smallest = parent
                    if left < heap.count, heap[left].cost < heap[smallest].cost { smallest = left }
                    if right < heap.count, heap[right].cost < heap[smallest].cost { smallest = right }
                    guard smallest != parent else { break }
                    heap.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return top
        }

        func candidate(u: Int32, v: Int32) -> Candidate {
            let quadric = quadrics[Int(u)].adding(quadrics[Int(v)])
            let pu = positions[Int(u)]
            let pv = positions[Int(v)]
            let mid = Vec3(x: (pu.x + pv.x) / 2, y: (pu.y + pv.y) / 2, z: (pu.z + pv.z) / 2)
            var best = mid
            var bestCost = quadric.error(mid)
            for option in [pu, pv] where quadric.error(option) < bestCost {
                best = option
                bestCost = quadric.error(option)
            }
            if let optimal = quadric.optimalPoint(), quadric.error(optimal) < bestCost {
                best = optimal
                bestCost = quadric.error(optimal)
            }
            return Candidate(cost: bestCost, u: u, v: v, versionU: vertexVersion[Int(u)], versionV: vertexVersion[Int(v)], target: best)
        }

        var seeded = Set<UInt64>()
        seeded.reserveCapacity(triangles.count * 2)
        for triangle in triangles {
            for (u, v) in [(triangle.0, triangle.1), (triangle.1, triangle.2), (triangle.2, triangle.0)] {
                let key = edgeKey(u, v)
                guard seeded.insert(key).inserted else { continue }
                heapPush(candidate(u: u, v: v))
            }
        }

        func neighbors(_ v: Int32) -> Set<Int32> {
            var out = Set<Int32>()
            for t in vertexTriangles[Int(v)] where triangleAlive[Int(t)] {
                let triangle = triangles[Int(t)]
                if triangle.0 != v { out.insert(triangle.0) }
                if triangle.1 != v { out.insert(triangle.1) }
                if triangle.2 != v { out.insert(triangle.2) }
            }
            return out
        }

        var aliveFaces = triangles.count

        @discardableResult
        func attemptCollapse(_ popped: Candidate) -> Bool {
            let u = popped.u
            let v = popped.v
            guard !vertexDead[Int(u)], !vertexDead[Int(v)],
                  popped.versionU == vertexVersion[Int(u)],
                  popped.versionV == vertexVersion[Int(v)] else { return false }

            // Shared triangles of the edge (the ones a collapse removes).
            var sharedTriangles: [Int32] = []
            var thirdVertices = Set<Int32>()
            for t in vertexTriangles[Int(u)] where triangleAlive[Int(t)] {
                let triangle = triangles[Int(t)]
                let corners = [triangle.0, triangle.1, triangle.2]
                if corners.contains(v) {
                    sharedTriangles.append(t)
                    for corner in corners where corner != u && corner != v {
                        thirdVertices.insert(corner)
                    }
                }
            }
            guard !sharedTriangles.isEmpty else { return false }

            // Link condition: collapsing must not pinch the surface.
            if neighbors(u).intersection(neighbors(v)) != thirdVertices { return false }

            // Normal-flip / degeneracy guard on every surviving triangle.
            var flips = false
            for vertex in [u, v] {
                for t in vertexTriangles[Int(vertex)] where triangleAlive[Int(t)] && !flips {
                    let triangle = triangles[Int(t)]
                    let corners = [triangle.0, triangle.1, triangle.2]
                    if corners.contains(u) && corners.contains(v) { continue } // dies anyway
                    let before = corners.map { positions[Int($0)] }
                    let after = corners.map { $0 == vertex ? popped.target : positions[Int($0)] }
                    guard let normalBefore = triangleNormal(before[0], before[1], before[2]),
                          let normalAfter = triangleNormal(after[0], after[1], after[2]) else {
                        flips = true
                        break
                    }
                    if dot(normalBefore, normalAfter) <= 1.0e-6 {
                        flips = true
                        break
                    }
                }
            }
            if flips { return false }

            // Collapse u into v at the optimal point.
            for t in sharedTriangles {
                triangleAlive[Int(t)] = false
                aliveFaces -= 1
            }
            for t in vertexTriangles[Int(u)] where triangleAlive[Int(t)] {
                var triangle = triangles[Int(t)]
                if triangle.0 == u { triangle.0 = v }
                if triangle.1 == u { triangle.1 = v }
                if triangle.2 == u { triangle.2 = v }
                triangles[Int(t)] = triangle
                vertexTriangles[Int(v)].append(t)
            }
            vertexTriangles[Int(u)].removeAll()
            positions[Int(v)] = popped.target
            quadrics[Int(v)] = quadrics[Int(u)].adding(quadrics[Int(v)])
            vertexDead[Int(u)] = true
            vertexVersion[Int(u)] += 1
            vertexVersion[Int(v)] += 1

            for neighbor in neighbors(v) where !vertexDead[Int(neighbor)] {
                heapPush(candidate(u: v, v: neighbor))
            }
            return true
        }

        // Drain-and-reseed: a drained heap above target does not mean no
        // legal collapse exists — entries go stale as their neighborhoods
        // change and failed candidates are never re-queued. Re-seeding from
        // the surviving topology recovers them (this is what previously left
        // 170 faces against a 125 target).
        var reseedRounds = 0
        while true {
            while aliveFaces > target, let popped = heapPop() {
                attemptCollapse(popped)
            }
            guard aliveFaces > target, reseedRounds < 2 else { break }
            reseedRounds += 1
            seeded.removeAll(keepingCapacity: true)
            var reseeded = false
            for (t, triangle) in triangles.enumerated() where triangleAlive[t] {
                for (u, v) in [(triangle.0, triangle.1), (triangle.1, triangle.2), (triangle.2, triangle.0)] {
                    guard !vertexDead[Int(u)], !vertexDead[Int(v)] else { continue }
                    let key = edgeKey(u, v)
                    guard seeded.insert(key).inserted else { continue }
                    heapPush(candidate(u: u, v: v))
                    reseeded = true
                }
            }
            if !reseeded { break }
        }

        // Sliver sweep: QEM cost keeps near-zero-area slivers because their
        // collapse error is tiny, but as folded panels they are uncuttable
        // dust. Collapse the shortest edge of any triangle whose area falls
        // below a floor scaled to the model (0.1% of the bbox diagonal,
        // squared). The same link/flip guards apply, so a sliver whose
        // removal would pinch or flip the surface survives.
        func triangleArea(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
            length(cross(subtract(b, a), subtract(c, a))) / 2
        }
        var boundsMin = Vec3(x: .infinity, y: .infinity, z: .infinity)
        var boundsMax = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
        for (index, position) in positions.enumerated() where !vertexDead[index] {
            boundsMin = Vec3(x: min(boundsMin.x, position.x), y: min(boundsMin.y, position.y), z: min(boundsMin.z, position.z))
            boundsMax = Vec3(x: max(boundsMax.x, position.x), y: max(boundsMax.y, position.y), z: max(boundsMax.z, position.z))
        }
        let diagonal = length(subtract(boundsMax, boundsMin))
        if diagonal.isFinite, diagonal > 0 {
            let areaFloor = (diagonal * 1.0e-3) * (diagonal * 1.0e-3) / 2
            var sweeps = 0
            var swept = true
            while swept, sweeps < 4 {
                swept = false
                sweeps += 1
                for (t, triangle) in triangles.enumerated() where triangleAlive[t] {
                    let a = positions[Int(triangle.0)]
                    let b = positions[Int(triangle.1)]
                    let c = positions[Int(triangle.2)]
                    guard triangleArea(a, b, c) < areaFloor else { continue }
                    let edges = [
                        (triangle.0, triangle.1, length(subtract(b, a))),
                        (triangle.1, triangle.2, length(subtract(c, b))),
                        (triangle.2, triangle.0, length(subtract(a, c)))
                    ].sorted { $0.2 < $1.2 }
                    for (u, v, _) in edges {
                        if attemptCollapse(candidate(u: u, v: v)) {
                            swept = true
                            break
                        }
                    }
                }
            }
        }

        // --- Compact -------------------------------------------------------
        var finalTriangles: [(Int32, Int32, Int32)] = []
        finalTriangles.reserveCapacity(aliveFaces)
        for (t, triangle) in triangles.enumerated() where triangleAlive[t] {
            if triangle.0 == triangle.1 || triangle.1 == triangle.2 || triangle.0 == triangle.2 { continue }
            finalTriangles.append(triangle)
        }
        var compactIndex = [Int32](repeating: -1, count: positions.count)
        var finalPositions: [Vec3] = []
        for triangle in finalTriangles {
            for vertex in [triangle.0, triangle.1, triangle.2] where compactIndex[Int(vertex)] < 0 {
                compactIndex[Int(vertex)] = Int32(finalPositions.count)
                finalPositions.append(positions[Int(vertex)])
            }
        }
        let remappedTriangles = finalTriangles.map {
            (compactIndex[Int($0.0)], compactIndex[Int($0.1)], compactIndex[Int($0.2)])
        }
        guard !remappedTriangles.isEmpty else { return nil }
        return rebuild(model, positions: finalPositions, triangles: remappedTriangles)
    }

    private static func rebuild(
        _ model: MeshSummary,
        positions: [Vec3],
        triangles: [(Int32, Int32, Int32)]
    ) -> MeshSummary {
        var indices: [Int32] = []
        indices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            indices.append(triangle.0)
            indices.append(triangle.1)
            indices.append(triangle.2)
        }
        let geometry = MeshGeometryData(vertices: positions, triangleIndices: indices)
        var bounds: Bounds3D?
        if let first = positions.first {
            var minimum = first
            var maximum = first
            for p in positions {
                minimum = Vec3(x: min(minimum.x, p.x), y: min(minimum.y, p.y), z: min(minimum.z, p.z))
                maximum = Vec3(x: max(maximum.x, p.x), y: max(maximum.y, p.y), z: max(maximum.z, p.z))
            }
            bounds = Bounds3D(min: minimum, max: maximum)
        }
        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: positions.count,
            faceCount: triangles.count,
            triangleCount: triangles.count,
            bounds: bounds,
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }
}

enum FoldedMeshPrecleaner {
    static func preclean(_ model: MeshSummary, targetFaceCount: Int) -> MeshSummary? {
        let target = max(4, targetFaceCount)
        guard model.faceCount > target else { return model }

        do {
            let inputGeometry = MeshManifoldRepair.userRepair(MoldMeshSealer.seal(model.geometry))
            let input = try ManifoldEngine.make(from: inputGeometry)
            let simplified = simplify(input, targetFaceCount: target, diagonal: diagonalLength(for: inputGeometry, fallback: model.bounds))
            let mesh = try ManifoldEngine.toMesh(simplified)
            let cleaned = MeshManifoldRepair.userRepair(MoldMeshSealer.seal(mesh))
            return summary(preserving: model, geometry: cleaned)
        } catch {
            return nil
        }
    }

    private static func simplify(_ input: ManifoldHandle, targetFaceCount: Int, diagonal: Double) -> ManifoldHandle {
        let startCount = ManifoldEngine.triangleCount(input)
        guard startCount > targetFaceCount else { return input }

        let scale = max(diagonal.isFinite && diagonal > 0 ? diagonal : 1.0, 1.0e-6)
        let maxTolerance = max(scale * 0.25, 1.0e-6)
        var lower = 0.0
        var upper = max(scale * 1.0e-6, 1.0e-6)
        var bestUnderTarget: ManifoldHandle?
        var bestAny: ManifoldHandle?
        var bestAnyCount = startCount

        for _ in 0..<18 {
            guard let candidate = try? ManifoldEngine.simplify(input, tolerance: upper) else { break }
            let count = ManifoldEngine.triangleCount(candidate)
            if count < bestAnyCount {
                bestAny = candidate
                bestAnyCount = count
            }
            if count <= targetFaceCount {
                bestUnderTarget = candidate
                break
            }
            lower = upper
            if upper >= maxTolerance { break }
            upper = min(upper * 2.0, maxTolerance)
        }

        guard bestUnderTarget != nil else {
            return bestAny ?? input
        }

        for _ in 0..<6 {
            let mid = (lower + upper) / 2.0
            guard let candidate = try? ManifoldEngine.simplify(input, tolerance: mid) else { continue }
            let count = ManifoldEngine.triangleCount(candidate)
            if count <= targetFaceCount {
                bestUnderTarget = candidate
                upper = mid
            } else {
                lower = mid
                if count < bestAnyCount {
                    bestAny = candidate
                    bestAnyCount = count
                }
            }
        }

        return bestUnderTarget ?? bestAny ?? input
    }

    private static func summary(preserving model: MeshSummary, geometry: MeshGeometryData) -> MeshSummary? {
        let triangleCount = geometry.triangleIndices.count / 3
        guard triangleCount > 0 else { return nil }
        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: geometry.vertices.count,
            faceCount: triangleCount,
            triangleCount: triangleCount,
            bounds: bounds(for: geometry.vertices),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    private static func diagonalLength(for geometry: MeshGeometryData, fallback: Bounds3D?) -> Double {
        if let fallback {
            return distance(fallback.min, fallback.max)
        }
        guard let bounds = bounds(for: geometry.vertices) else { return 1.0 }
        return distance(bounds.min, bounds.max)
    }

    private static func bounds(for vertices: [Vec3]) -> Bounds3D? {
        guard let first = vertices.first else { return nil }
        var minimum = first
        var maximum = first
        for vertex in vertices {
            minimum = Vec3(x: min(minimum.x, vertex.x), y: min(minimum.y, vertex.y), z: min(minimum.z, vertex.z))
            maximum = Vec3(x: max(maximum.x, vertex.x), y: max(maximum.y, vertex.y), z: max(maximum.z, vertex.z))
        }
        return Bounds3D(min: minimum, max: maximum)
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
