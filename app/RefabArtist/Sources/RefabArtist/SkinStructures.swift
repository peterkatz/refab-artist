import Foundation

struct SkinAudit: Equatable {
    var seedCount: Int
    var cellCount: Int
    var segmentCount: Int
    var meanSpacing: Double
    var componentCount: Int = 0
    var genus: Int = 0
}

struct SurfaceSeed: Equatable {
    var position: Vec3
    /// Personal spacing radius (density × per-seed variation) used at sampling
    /// time — big-radius seeds carve out big cells, the organic-helmet look.
    var radius: Double = 0
}

struct Polyline3D: Equatable {
    var points: [Vec3]
}

private struct SkinTriangle {
    var a: Vec3
    var b: Vec3
    var c: Vec3
    var area: Double
    var cumulativeArea: Double
}

enum SurfaceSampler {
    static func seeds(
        onSurfaceOf mesh: MeshGeometryData,
        density: DensityField,
        seed: UInt64,
        maxSeeds: Int = 700,
        variation: Double = 0
    ) -> [SurfaceSeed] {
        let triangles = surfaceTriangles(mesh)
        guard let totalArea = triangles.last?.cumulativeArea, totalArea > 0 else { return [] }
        let cell = max(meanCellSize(mesh: mesh, density: density), 1.0)
        let targetCount = min(maxSeeds, max(4, Int((totalArea / (cell * cell * 0.9)).rounded(.up))))
        let candidateCount = max(targetCount * 20, 128)
        let v = min(max(variation, 0), 1)
        var rng = SkinRNG(seed: seed)
        var accepted: [SurfaceSeed] = []
        accepted.reserveCapacity(targetCount)
        for _ in 0..<candidateCount {
            let p = randomPoint(triangles: triangles, totalArea: totalArea, rng: &rng)
            // Per-seed radius jitter, LOG-uniform so Variation 1.0 spans a real
            // 16x spread (factor 4 up AND down) — big open cells sprinkled among
            // tight clusters, not a mildly uneven honeycomb. No RNG draw at
            // v == 0 so zero-variation layouts stay bit-identical.
            let maxFactor = 1.0 + 3.0 * v
            let scale = v > 0 ? pow(maxFactor, rng.nextUnit() * 2.0 - 1.0) : 1.0
            let localRadius = max(density.cellSize(at: SIMD3(p.x, p.y, p.z)) * scale, 0.5)
            if accepted.allSatisfy({ other in
                distance(other.position, p) >= max(localRadius, other.radius)
            }) {
                accepted.append(SurfaceSeed(position: p, radius: localRadius))
                if accepted.count >= targetCount { break }
            }
        }
        if accepted.count < 4 {
            for tri in triangles.prefix(4 - accepted.count) {
                accepted.append(SurfaceSeed(position: Vec3(
                    x: (tri.a.x + tri.b.x + tri.c.x) / 3.0,
                    y: (tri.a.y + tri.b.y + tri.c.y) / 3.0,
                    z: (tri.a.z + tri.b.z + tri.c.z) / 3.0
                )))
            }
        }
        return accepted
    }

    private static func surfaceTriangles(_ mesh: MeshGeometryData) -> [SkinTriangle] {
        var result: [SkinTriangle] = []
        var cumulative = 0.0
        for i in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            let ia = Int(mesh.triangleIndices[i])
            let ib = Int(mesh.triangleIndices[i + 1])
            let ic = Int(mesh.triangleIndices[i + 2])
            guard mesh.vertices.indices.contains(ia),
                  mesh.vertices.indices.contains(ib),
                  mesh.vertices.indices.contains(ic) else { continue }
            let a = mesh.vertices[ia]
            let b = mesh.vertices[ib]
            let c = mesh.vertices[ic]
            let area = 0.5 * length(cross(subtract(b, a), subtract(c, a)))
            guard area > 1.0e-9 else { continue }
            cumulative += area
            result.append(SkinTriangle(a: a, b: b, c: c, area: area, cumulativeArea: cumulative))
        }
        return result
    }

    private static func meanCellSize(mesh: MeshGeometryData, density: DensityField) -> Double {
        guard !mesh.vertices.isEmpty else { return 12 }
        let stride = max(1, mesh.vertices.count / 64)
        var values: [Double] = []
        for index in Swift.stride(from: 0, to: mesh.vertices.count, by: stride) {
            let p = mesh.vertices[index]
            values.append(density.cellSize(at: SIMD3(p.x, p.y, p.z)))
        }
        return values.reduce(0, +) / Double(max(values.count, 1))
    }

    private static func randomPoint(
        triangles: [SkinTriangle],
        totalArea: Double,
        rng: inout SkinRNG
    ) -> Vec3 {
        let pick = rng.nextUnit() * totalArea
        var lo = 0
        var hi = triangles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if triangles[mid].cumulativeArea < pick {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let tri = triangles[lo]
        let r1 = rng.nextUnit()
        let r2 = rng.nextUnit()
        let sr1 = sqrt(r1)
        let wa = 1.0 - sr1
        let wb = sr1 * (1.0 - r2)
        let wc = sr1 * r2
        return Vec3(
            x: tri.a.x * wa + tri.b.x * wb + tri.c.x * wc,
            y: tri.a.y * wa + tri.b.y * wb + tri.c.y * wc,
            z: tri.a.z * wa + tri.b.z * wb + tri.c.z * wc
        )
    }
}

enum SurfaceCellNetwork {
    static func voronoiEdges(mesh: MeshGeometryData, seeds: [SurfaceSeed]) -> [Polyline3D] {
        guard seeds.count > 1 else { return [] }
        let labels = mesh.vertices.map { nearestSeedIndex(to: $0, seeds: seeds) }
        var segments: [Polyline3D] = []
        for i in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            let indices = [Int(mesh.triangleIndices[i]), Int(mesh.triangleIndices[i + 1]), Int(mesh.triangleIndices[i + 2])]
            guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { continue }
            let uniqueLabels = Array(Set(indices.map { labels[$0] }))
            guard uniqueLabels.count > 1 else { continue }
            let crossings = triangleCrossings(indices: indices, labels: labels, vertices: mesh.vertices, seeds: seeds)
            if uniqueLabels.count == 2, crossings.count >= 2 {
                segments.append(Polyline3D(points: [crossings[0], crossings[1]]))
            } else if uniqueLabels.count == 3, crossings.count >= 3 {
                let centroid = Vec3(
                    x: indices.map { mesh.vertices[$0].x }.reduce(0, +) / 3.0,
                    y: indices.map { mesh.vertices[$0].y }.reduce(0, +) / 3.0,
                    z: indices.map { mesh.vertices[$0].z }.reduce(0, +) / 3.0
                )
                for point in crossings.prefix(3) {
                    segments.append(Polyline3D(points: [point, centroid]))
                }
            }
        }
        return deduplicated(segments)
    }

    static func delaunayEdges(mesh: MeshGeometryData, seeds: [SurfaceSeed]) -> [Polyline3D] {
        let boundaries = voronoiEdges(mesh: mesh, seeds: seeds)
        var pairs = Set<SkinPairKey>()
        var result: [Polyline3D] = []
        for line in boundaries {
            guard line.points.count == 2 else { continue }
            let a = nearestSeedIndex(to: line.points[0], seeds: seeds)
            let b = nearestSeedIndex(to: line.points[1], seeds: seeds)
            guard a != b else { continue }
            let key = SkinPairKey(a, b)
            if pairs.insert(key).inserted {
                result.append(Polyline3D(points: [seeds[key.a].position, seeds[key.b].position]))
            }
        }
        return result
    }

    private static func triangleCrossings(
        indices: [Int],
        labels: [Int],
        vertices: [Vec3],
        seeds: [SurfaceSeed]
    ) -> [Vec3] {
        var result: [Vec3] = []
        let edges = [(0, 1), (1, 2), (2, 0)]
        for edge in edges {
            let ia = indices[edge.0]
            let ib = indices[edge.1]
            let la = labels[ia]
            let lb = labels[ib]
            guard la != lb else { continue }
            let a = vertices[ia]
            let b = vertices[ib]
            let fa = distance(a, seeds[la].position) - distance(a, seeds[lb].position)
            let fb = distance(b, seeds[la].position) - distance(b, seeds[lb].position)
            let denom = fa - fb
            let t = abs(denom) > 1.0e-9 ? min(max(fa / denom, 0), 1) : 0.5
            result.append(Vec3(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                z: a.z + (b.z - a.z) * t
            ))
        }
        return result
    }

    private static func nearestSeedIndex(to p: Vec3, seeds: [SurfaceSeed]) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, seed) in seeds.enumerated() {
            let d = distance(p, seed.position)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }

    private static func deduplicated(_ lines: [Polyline3D]) -> [Polyline3D] {
        var seen = Set<SkinSegmentKey>()
        var result: [Polyline3D] = []
        for line in lines {
            guard line.points.count == 2 else { continue }
            let key = SkinSegmentKey(line.points[0], line.points[1])
            if seen.insert(key).inserted {
                result.append(line)
            }
        }
        return result
    }
}

/// Deterministic seeded 3D value noise (trilinear over a hashed integer
/// lattice) — the smooth position-based field that drives organic strut
/// thickness. Same seed → same field.
struct SkinNoiseField {
    private let seed: UInt64
    private let wavelength: Double

    init(seed: UInt64, wavelengthMm: Double) {
        self.seed = seed == 0 ? 0xB16B_00B5 : seed
        self.wavelength = max(wavelengthMm, 1.0)
    }

    /// Smoothly varying value in [-1, 1].
    func value(at p: Vec3) -> Double {
        let x = p.x / wavelength, y = p.y / wavelength, z = p.z / wavelength
        let x0 = floor(x), y0 = floor(y), z0 = floor(z)
        let fx = smooth(x - x0), fy = smooth(y - y0), fz = smooth(z - z0)
        var corners = [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            let cx = Int(x0) + (i & 1)
            let cy = Int(y0) + ((i >> 1) & 1)
            let cz = Int(z0) + ((i >> 2) & 1)
            corners[i] = lattice(cx, cy, cz)
        }
        let c00 = corners[0] + (corners[1] - corners[0]) * fx
        let c10 = corners[2] + (corners[3] - corners[2]) * fx
        let c01 = corners[4] + (corners[5] - corners[4]) * fx
        let c11 = corners[6] + (corners[7] - corners[6]) * fx
        let c0 = c00 + (c10 - c00) * fy
        let c1 = c01 + (c11 - c01) * fy
        return c0 + (c1 - c0) * fz
    }

    private func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private func lattice(_ x: Int, _ y: Int, _ z: Int) -> Double {
        var h = seed
        h = (h ^ UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15)
        h = (h ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F)
        h = (h ^ UInt64(bitPattern: Int64(z)) &* 0x1656_67B1_9E37_79F9)
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return Double(h >> 11) / Double(UInt64.max >> 11) * 2.0 - 1.0
    }
}

enum SkinShellBuilder {
    static func buildStruts(
        network: [Polyline3D],
        settings: SkinSettings,
        seed: UInt64 = 1,
        meanCellMm: Double = 12,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> (solid: ManifoldHandle, notice: String?) {
        let radius = max(settings.strutDiameterMm * 0.5, 0.05)
        // Coarsening MERGES micro-segments into longer chain struts — it NEVER
        // drops them. The every-Nth subsample that shipped 2026-07-02 deleted 5
        // of 6 boundary segments on the owner's real hand and dusted the network
        // into 858 disconnected beads. Chaining preserves connectivity by
        // construction: chains share their exact junction endpoints, so capsule
        // spheres coincide there and the union stays one cage.
        let chains = SkinStrutChainer.chains(from: network)
        let microCount = network.reduce(0) { $0 + max($1.points.count - 1, 0) }
        let budget = 24_000
        var epsilon = min(radius * 0.5, 0.75)
        var simplified = chains.map { SkinStrutChainer.simplified($0, epsilon: epsilon) }
        var edgeCount = simplified.reduce(0) { $0 + max($1.points.count - 1, 0) }
        var escalations = 0
        while edgeCount > budget, escalations < 4 {
            epsilon = min(epsilon * 1.6, max(settings.strutDiameterMm, 0.1))
            simplified = chains.map { SkinStrutChainer.simplified($0, epsilon: epsilon) }
            edgeCount = simplified.reduce(0) { $0 + max($1.points.count - 1, 0) }
            escalations += 1
        }
        let notice: String? = escalations > 0
            ? String(
                format: "Skin struts simplified from %d micro-segments to %d struts (deviation up to %.2f mm) to stay within the capsule budget; network connectivity preserved.",
                microCount, edgeCount, epsilon
            )
            : nil

        // ORGANIC THICKNESS: a continuous position-based radius field — slow
        // seeded noise (regions drift thicker/thinner) × a junction swell at
        // chain ends. Position-based means every strut arriving at a junction
        // agrees on the radius there: smooth joints, never per-strut steps.
        let sv = min(max(settings.strutVariationPct, 0), 1)
        let noise = SkinNoiseField(seed: seed &+ 0x5EED, wavelengthMm: max(meanCellMm * 3.0, 8.0))
        let noiseSpan = 1.0 + 1.2 * sv          // radius factor up to ×2.2 / ÷2.2 at sv = 1
        let junctionSwell = 0.5 * sv            // up to +50% at chain ends
        let swellWidth = max(settings.strutDiameterMm * 2.0, 2.0)
        // Subdivide long simplified edges so the field can express itself ALONG
        // a strut (a 2-point straight strut would otherwise stay uniform).
        let targetSegment = max(meanCellMm / 3.0, 3.0)

        func radiusAt(_ p: Vec3, distanceToChainEnd: Double) -> Double {
            var r = radius
            if sv > 0 {
                r *= pow(noiseSpan, noise.value(at: p))
                let g = exp(-(distanceToChainEnd * distanceToChainEnd) / (swellWidth * swellWidth))
                r *= 1.0 + junctionSwell * g
            }
            return max(r, 0.3)
        }

        var solids: [ManifoldHandle] = []
        solids.reserveCapacity(edgeCount * 2)
        for line in simplified {
            guard line.points.count >= 2 else { continue }
            // Resample the chain at ~targetSegment spacing (keeping original
            // points) and track arc-length so the junction swell can localize.
            var points: [Vec3] = []
            for i in 0..<(line.points.count - 1) {
                let a = line.points[i]
                let b = line.points[i + 1]
                let span = distance(a, b)
                guard span > 1.0e-6 else { continue }
                if points.isEmpty { points.append(a) }
                if sv > 0, span > targetSegment {
                    let pieces = Int((span / targetSegment).rounded(.up))
                    for k in 1..<pieces {
                        let t = Double(k) / Double(pieces)
                        points.append(Vec3(
                            x: a.x + (b.x - a.x) * t,
                            y: a.y + (b.y - a.y) * t,
                            z: a.z + (b.z - a.z) * t
                        ))
                    }
                }
                points.append(b)
            }
            guard points.count >= 2 else { continue }
            var arc = [Double](repeating: 0, count: points.count)
            for i in 1..<points.count { arc[i] = arc[i - 1] + distance(points[i - 1], points[i]) }
            let total = arc[points.count - 1]
            var radii = [Double](repeating: radius, count: points.count)
            for i in points.indices {
                radii[i] = radiusAt(points[i], distanceToChainEnd: min(arc[i], total - arc[i]))
            }
            for i in 0..<(points.count - 1) {
                guard distance(points[i], points[i + 1]) > 1.0e-6 else { continue }
                let a = try engine.translate(engine.sphere(radius: radii[i], segments: 10), x: points[i].x, y: points[i].y, z: points[i].z)
                let b = try engine.translate(engine.sphere(radius: radii[i + 1], segments: 10), x: points[i + 1].x, y: points[i + 1].y, z: points[i + 1].z)
                solids.append(try engine.convexHull(joining: a, b))
            }
        }
        guard !solids.isEmpty else { throw StructureEngineError.missingBounds }
        return (try engine.union(solids), notice)
    }
}

/// Joins marching-triangles micro-segments into junction-to-junction polyline
/// chains (endpoints quantized to 1 µm — crossing points are computed from the
/// same vertex data on both sides of an edge, so shared endpoints quantize
/// identically), then Douglas-Peucker-simplifies each chain. Junction and
/// terminal points are always kept, so the network topology is untouched.
enum SkinStrutChainer {
    private struct NodeKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(_ p: Vec3) {
            x = Int((p.x * 1000).rounded())
            y = Int((p.y * 1000).rounded())
            z = Int((p.z * 1000).rounded())
        }
    }

    private struct Incidence {
        var segment: Int
        var startsHere: Bool
    }

    static func chains(from network: [Polyline3D]) -> [Polyline3D] {
        var segments: [(Vec3, Vec3)] = []
        for line in network {
            guard line.points.count >= 2 else { continue }
            for i in 0..<(line.points.count - 1) {
                let a = line.points[i]
                let b = line.points[i + 1]
                if distance(a, b) > 1.0e-6 { segments.append((a, b)) }
            }
        }
        guard !segments.isEmpty else { return [] }

        var adjacency: [NodeKey: [Incidence]] = [:]
        for (index, segment) in segments.enumerated() {
            adjacency[NodeKey(segment.0), default: []].append(Incidence(segment: index, startsHere: true))
            adjacency[NodeKey(segment.1), default: []].append(Incidence(segment: index, startsHere: false))
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var result: [Polyline3D] = []

        func walk(startSegment: Int, startsAtStoredStart: Bool) -> [Vec3] {
            var points: [Vec3] = []
            visited[startSegment] = true
            var (a, b) = segments[startSegment]
            if !startsAtStoredStart { swap(&a, &b) }
            points.append(a)
            points.append(b)
            var currentKey = NodeKey(b)
            while let incidents = adjacency[currentKey], incidents.count == 2 {
                guard let next = incidents.first(where: { !visited[$0.segment] }) else { break }
                visited[next.segment] = true
                var (na, nb) = segments[next.segment]
                if !next.startsHere { swap(&na, &nb) }
                points.append(nb)
                currentKey = NodeKey(nb)
            }
            return points
        }

        // Chains between junctions/terminals (node degree ≠ 2)…
        for (key, incidents) in adjacency where incidents.count != 2 {
            for incidence in incidents where !visited[incidence.segment] {
                let segment = segments[incidence.segment]
                let startsAtKey = NodeKey(segment.0) == key
                let points = walk(startSegment: incidence.segment, startsAtStoredStart: startsAtKey)
                if points.count >= 2 { result.append(Polyline3D(points: points)) }
            }
        }
        // …then leftover closed loops (every node degree 2).
        for index in segments.indices where !visited[index] {
            let points = walk(startSegment: index, startsAtStoredStart: true)
            if points.count >= 2 { result.append(Polyline3D(points: points)) }
        }
        return result
    }

    static func simplified(_ line: Polyline3D, epsilon: Double) -> Polyline3D {
        guard line.points.count > 2, epsilon > 0 else { return line }
        var keep = [Bool](repeating: false, count: line.points.count)
        keep[0] = true
        keep[line.points.count - 1] = true
        douglasPeucker(line.points, 0, line.points.count - 1, epsilon, &keep)
        return Polyline3D(points: line.points.indices.compactMap { keep[$0] ? line.points[$0] : nil })
    }

    private static func douglasPeucker(
        _ points: [Vec3], _ lo: Int, _ hi: Int, _ epsilon: Double, _ keep: inout [Bool]
    ) {
        guard hi > lo + 1 else { return }
        var maxDistance = 0.0
        var maxIndex = lo
        for i in (lo + 1)..<hi {
            let d = pointSegmentDistance(points[i], points[lo], points[hi])
            if d > maxDistance {
                maxDistance = d
                maxIndex = i
            }
        }
        if maxDistance > epsilon {
            keep[maxIndex] = true
            douglasPeucker(points, lo, maxIndex, epsilon, &keep)
            douglasPeucker(points, maxIndex, hi, epsilon, &keep)
        }
    }

    private static func pointSegmentDistance(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = subtract(b, a)
        let ap = subtract(p, a)
        let denom = max(dot(ab, ab), 1.0e-12)
        let t = min(max(dot(ap, ab) / denom, 0), 1)
        let closest = Vec3(x: a.x + ab.x * t, y: a.y + ab.y * t, z: a.z + ab.z * t)
        return distance(p, closest)
    }
}

private struct SkinRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xD1B5_4A32_D192_ED03 : seed
    }

    mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let mantissa = state >> 11
        return Double(mantissa) / Double(UInt64.max >> 11)
    }
}

private struct SkinPairKey: Hashable {
    let a: Int
    let b: Int

    init(_ x: Int, _ y: Int) {
        a = min(x, y)
        b = max(x, y)
    }
}

private struct SkinSegmentKey: Hashable {
    let ax: Int
    let ay: Int
    let az: Int
    let bx: Int
    let by: Int
    let bz: Int

    init(_ a: Vec3, _ b: Vec3) {
        let qa = Self.quantize(a)
        let qb = Self.quantize(b)
        if Self.precedes(qa, qb) {
            ax = qa.0; ay = qa.1; az = qa.2
            bx = qb.0; by = qb.1; bz = qb.2
        } else {
            ax = qb.0; ay = qb.1; az = qb.2
            bx = qa.0; by = qa.1; bz = qa.2
        }
    }

    private static func quantize(_ p: Vec3) -> (Int, Int, Int) {
        (
            Int((p.x * 1000).rounded()),
            Int((p.y * 1000).rounded()),
            Int((p.z * 1000).rounded())
        )
    }

    private static func precedes(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2 <= b.2
    }
}

private func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
}

private func dot(_ a: Vec3, _ b: Vec3) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

private func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(
        x: a.y * b.z - a.z * b.y,
        y: a.z * b.x - a.x * b.z,
        z: a.x * b.y - a.y * b.x
    )
}

private func length(_ v: Vec3) -> Double {
    (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
}

private func distance(_ a: Vec3, _ b: Vec3) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    let dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}
