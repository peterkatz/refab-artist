import Foundation
import simd

struct SupportSurfaceSample: Equatable {
    var position: Vec3
    var normal: Vec3
}

struct BranchNode: Equatable {
    var position: Vec3
    var radius: Double
    var parentIndex: Int?
    var isTip: Bool
}

struct SupportAudit: Equatable {
    var targetSampleCount: Int
    var tipCount: Int
    /// Fraction of target samples whose branch chain actually reaches the plate.
    /// (The old metric compared the tip set to itself and was always 1.0.)
    var tipCoverage: Double
    var branchCount: Int
    var maxSlopeDeg: Double
    var capsuleCount: Int
    var effectiveStepMm: Double
    /// Branch-pair merge events during growth. Zero on a non-trivial forest means
    /// "bed of nails", not an organic tree — gate on this.
    var mergeCount: Int
    /// Distinct chain endpoints at the plate. Trunk formation ⇒ well below tipCount.
    var plateRootCount: Int
    var modelIntersectionVolume: Double
    var overhangCoverage: Double
    var restOnModelCount: Int
}

struct SupportBuildResult {
    var targetSamples: [SupportSurfaceSample]
    var tips: [SupportSurfaceSample]
    var nodes: [BranchNode]
    var audit: SupportAudit
    var coarseningNotice: String?
}

struct AvoidanceVolumes {
    private let solid: ManifoldHandle
    private let stepMm: Double
    private var sliceCache: [Int: [[SIMD2<Double>]]] = [:]

    init(solid: ManifoldHandle, stepMm: Double) {
        self.solid = solid
        self.stepMm = max(stepMm, 0.05)
    }

    mutating func isClear(_ p: Vec3, radius: Double) -> Bool {
        !polygons(at: p.z).contains { Self.pointInPolygon(SIMD2(p.x, p.y), $0) }
    }

    mutating func pushOut(_ p: Vec3, radius: Double, maxStep: Double) -> Vec3? {
        let polygons = polygons(at: p.z)
        guard polygons.contains(where: { Self.pointInPolygon(SIMD2(p.x, p.y), $0) }) else {
            return p
        }
        let q = SIMD2(p.x, p.y)
        var bestPoint: SIMD2<Double>?
        var bestDistance = Double.greatestFiniteMagnitude
        for polygon in polygons {
            guard polygon.count > 1 else { continue }
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                let nearest = Self.nearestPoint(on: a, b, to: q)
                let d = simd_length(nearest - q)
                if d < bestDistance {
                    bestDistance = d
                    bestPoint = nearest
                }
            }
        }
        guard let bestPoint else { return nil }
        // The node is INSIDE the polygon; escape means moving TOWARD the nearest
        // boundary point and through it. (The original `q - bestPoint` direction
        // pointed away from the boundary, i.e. DEEPER into the model — inverted.)
        let toBoundary = bestPoint - q
        let len = simd_length(toBoundary)
        guard len > 1.0e-9 else { return nil }
        let travel = min(maxStep, len + max(radius, 0.1))
        let moved = q + toBoundary / len * travel
        return Vec3(x: moved.x, y: moved.y, z: p.z)
    }

    mutating func lineOfSight(_ a: Vec3, _ b: Vec3, radius: Double) -> Bool {
        let gap = max(horizontalDistance(a, b), 1.0e-6)
        let steps = max(1, Int((gap / 2.0).rounded(.up)))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = Vec3(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                z: min(a.z, b.z)
            )
            if !isClear(p, radius: radius) { return false }
        }
        return true
    }

    private mutating func polygons(at z: Double) -> [[SIMD2<Double>]] {
        let key = Int((z / stepMm).rounded())
        if let cached = sliceCache[key] { return cached }
        let sliceZ = Double(key) * stepMm
        let polygons = (try? ManifoldEngine.slice(solid, atZ: sliceZ)) ?? []
        sliceCache[key] = polygons
        return polygons
    }

    private static func pointInPolygon(_ p: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let denom = pj.y - pi.y
                guard abs(denom) > 1.0e-12 else {
                    j = i
                    continue
                }
                let x = (pj.x - pi.x) * (p.y - pi.y) / denom + pi.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func nearestPoint(on a: SIMD2<Double>, _ b: SIMD2<Double>, to p: SIMD2<Double>) -> SIMD2<Double> {
        let ab = b - a
        let denom = max(simd_dot(ab, ab), 1.0e-12)
        let t = min(max(simd_dot(p - a, ab) / denom, 0), 1)
        return a + ab * t
    }
}

private struct SupportRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let mantissa = state >> 11
        return Double(mantissa) / Double(UInt64.max >> 11)
    }
}

private struct SupportTriangle {
    var a: Vec3
    var b: Vec3
    var c: Vec3
    var normal: Vec3
    var area: Double
    var cumulativeArea: Double
}

enum SupportSurfaceSampler {
    /// Manifold accepts an inside-out mesh and hands it back inside-out — trust
    /// the winding only after checking the signed volume, flipping if negative.
    static func ensureOutwardWinding(_ mesh: MeshGeometryData) -> MeshGeometryData {
        var signedVolume = 0.0
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
            signedVolume += dot(a, cross(b, c)) / 6.0
        }
        guard signedVolume < 0 else { return mesh }
        var flipped = mesh
        var indices = mesh.triangleIndices
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            indices.swapAt(i + 1, i + 2)
        }
        flipped.triangleIndices = indices
        return flipped
    }

    static func samples(
        on mesh: MeshGeometryData,
        settings: SupportSettings,
        seed: UInt64,
        maxSamples: Int = 800,
        trustWinding: Bool = false
    ) -> [SupportSurfaceSample] {
        let triangles = targetTriangles(mesh: mesh, settings: settings, trustWinding: trustWinding)
        guard let totalArea = triangles.last?.cumulativeArea, totalArea > 0 else {
            return []
        }

        let spacing = max(settings.tipSpacingMm, 0.001)
        let idealCount = max(1, Int((totalArea / (spacing * spacing * 0.9)).rounded(.up)))
        let targetCount = min(maxSamples, idealCount)
        let candidateCount = max(targetCount * 8, 32)
        let minDistance = spacing
        let bucketSize = minDistance
        var rng = SupportRNG(seed: seed)
        var accepted: [SupportSurfaceSample] = []
        accepted.reserveCapacity(targetCount)
        var buckets: [SupportBucket: [Int]] = [:]

        func bucket(for p: Vec3) -> SupportBucket {
            SupportBucket(
                x: Int(floor(p.x / bucketSize)),
                y: Int(floor(p.y / bucketSize)),
                z: Int(floor(p.z / bucketSize))
            )
        }

        func canAccept(_ p: Vec3) -> Bool {
            let key = bucket(for: p)
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let neighbor = SupportBucket(x: key.x + dx, y: key.y + dy, z: key.z + dz)
                        for index in buckets[neighbor, default: []] {
                            if distance(accepted[index].position, p) < minDistance {
                                return false
                            }
                        }
                    }
                }
            }
            return true
        }

        for _ in 0..<candidateCount {
            let sample = randomSample(triangles: triangles, totalArea: totalArea, rng: &rng)
            if canAccept(sample.position) {
                let index = accepted.count
                accepted.append(sample)
                buckets[bucket(for: sample.position), default: []].append(index)
                if accepted.count >= targetCount {
                    break
                }
            }
        }

        if accepted.isEmpty, let first = triangles.first {
            let p = Vec3(
                x: (first.a.x + first.b.x + first.c.x) / 3.0,
                y: (first.a.y + first.b.y + first.c.y) / 3.0,
                z: (first.a.z + first.b.z + first.c.z) / 3.0
            )
            accepted.append(SupportSurfaceSample(position: p, normal: first.normal))
        }
        return accepted
    }

    private static func targetTriangles(
        mesh: MeshGeometryData,
        settings: SupportSettings,
        trustWinding: Bool = false
    ) -> [SupportTriangle] {
        let threshold = sin(settings.surfaceAngleDeg * Double.pi / 180.0)
        // The bbox-center flip is a CONVEX heuristic: an overhang's underside
        // always faces the model interior, so it gets flipped and down-facing
        // detection misses it entirely (the M5 fixture sampled 4 junk points and
        // the old solidifier hid it as floating balls). When the caller passes a
        // Manifold-derived mesh the winding IS outward — trust it, no heuristic.
        let center = trustWinding ? nil : meshCenter(mesh)
        var triangles: [SupportTriangle] = []
        var cumulative = 0.0
        for i in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            let ia = Int(mesh.triangleIndices[i])
            let ib = Int(mesh.triangleIndices[i + 1])
            let ic = Int(mesh.triangleIndices[i + 2])
            guard mesh.vertices.indices.contains(ia),
                  mesh.vertices.indices.contains(ib),
                  mesh.vertices.indices.contains(ic) else {
                continue
            }
            let a = mesh.vertices[ia]
            let b = mesh.vertices[ib]
            let c = mesh.vertices[ic]
            let raw = cross(subtract(b, a), subtract(c, a))
            let area2 = length(raw)
            guard area2 > 1.0e-9 else { continue }
            var normal = scale(raw, 1.0 / area2)
            let centroid = Vec3(
                x: (a.x + b.x + c.x) / 3.0,
                y: (a.y + b.y + c.y) / 3.0,
                z: (a.z + b.z + c.z) / 3.0
            )
            if let center {
                let outward = subtract(centroid, center)
                if length(outward) > 1.0e-9, dot(normal, outward) < 0 {
                    normal = scale(normal, -1.0)
                }
            }
            let include: Bool
            switch settings.targetSurface {
            case .upFacing:
                include = normal.z > threshold
            case .downFacing:
                include = normal.z < -threshold
            }
            guard include else { continue }
            cumulative += area2 * 0.5
            triangles.append(SupportTriangle(
                a: a, b: b, c: c, normal: normal, area: area2 * 0.5, cumulativeArea: cumulative
            ))
        }
        return triangles
    }

    private static func meshCenter(_ mesh: MeshGeometryData) -> Vec3? {
        guard !mesh.vertices.isEmpty else { return nil }
        var minV = mesh.vertices[0]
        var maxV = mesh.vertices[0]
        for v in mesh.vertices.dropFirst() {
            minV.x = min(minV.x, v.x)
            minV.y = min(minV.y, v.y)
            minV.z = min(minV.z, v.z)
            maxV.x = max(maxV.x, v.x)
            maxV.y = max(maxV.y, v.y)
            maxV.z = max(maxV.z, v.z)
        }
        return Vec3(
            x: (minV.x + maxV.x) * 0.5,
            y: (minV.y + maxV.y) * 0.5,
            z: (minV.z + maxV.z) * 0.5
        )
    }

    private static func randomSample(
        triangles: [SupportTriangle],
        totalArea: Double,
        rng: inout SupportRNG
    ) -> SupportSurfaceSample {
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
        let p = Vec3(
            x: tri.a.x * wa + tri.b.x * wb + tri.c.x * wc,
            y: tri.a.y * wa + tri.b.y * wb + tri.c.y * wc,
            z: tri.a.z * wa + tri.b.z * wb + tri.c.z * wc
        )
        return SupportSurfaceSample(position: p, normal: tri.normal)
    }
}

private struct SupportBucket: Hashable {
    var x: Int
    var y: Int
    var z: Int
}

enum SupportTreeBuilder {
    static func build(
        samples: [SupportSurfaceSample],
        bounds: Bounds3D,
        settings: SupportSettings,
        seed: UInt64,
        avoidance: AvoidanceVolumes? = nil
    ) -> SupportBuildResult {
        let safe = settings.sanitized
        var avoidance = avoidance
        let plateZ = bounds.min.z
        let tipRadius = safe.tipDiameterMm * 0.5
        let maxRadius = safe.branchDiameterMm * 0.5
        let verticalSpan = max(bounds.max.z - bounds.min.z, safe.stepMm)
        // Growth-node estimate with merge decay: branches fuse quickly, so the
        // naive tips×layers count over-coarsened the step 7x and turned curved
        // paths into straight polylines. The post-growth curve simplification
        // in SupportSolidifier now handles the CAPSULE budget, so this guard
        // only protects growth memory/time in extreme cases.
        let estimatedNodes = Int(Double(samples.count) * max(verticalSpan / safe.stepMm, 1.0) * 0.25)
        let nodeBudget = 60_000
        let effectiveStep = estimatedNodes > nodeBudget
            ? max(safe.stepMm, verticalSpan * Double(max(samples.count, 1)) * 0.25 / Double(nodeBudget))
            : safe.stepMm
        let notice = estimatedNodes > nodeBudget
            ? "Support growth coarsened step from \(format(safe.stepMm))mm to \(format(effectiveStep))mm to keep the branch graph tractable."
            : nil
        let preferredTan = tan(min(safe.preferredAngleDeg, safe.maxAngleDeg) * Double.pi / 180.0)
        let maxSlopeTan = tan(safe.maxAngleDeg * Double.pi / 180.0)
        let taper = tan(safe.diameterAngleDeg * Double.pi / 180.0)
        let center = averageXY(samples.map(\.position))
        // Tips descend straight for ~one tip diameter before steering (tip hold),
        // and branches flare into the plate over the last few layers.
        let tipHoldLayers = max(1, Int((safe.tipDiameterMm / effectiveStep).rounded(.up)))
        let flareZone = 3.0 * effectiveStep

        var nodes: [BranchNode] = samples.map {
            BranchNode(position: $0.position, radius: tipRadius, parentIndex: nil, isTip: true)
        }
        var depth = [Int](repeating: 0, count: nodes.count)
        var mergeCount = 0
        var restOnModelCount = 0
        var active = Array(nodes.indices)
        var hasClearedAvoidance = [Bool](repeating: avoidance == nil, count: nodes.count)
        var blockedLayers = [Int](repeating: 0, count: nodes.count)
        let variation = min(max(safe.variationPct, 0), 2)
        // SMOOTH flow fields for the wander: white noise per step averages out
        // to rough straight lines, but a branch descending through a spatially
        // smooth field sees its heading rotate GRADUALLY → real S-curves, and
        // neighboring branches curve coherently (the Cura organic snake).
        let flowWavelength = max(verticalSpan / (3.0 + 4.0 * variation), 12.0)
        let flowA = SkinNoiseField(seed: seed &* 77 &+ 5, wavelengthMm: flowWavelength)
        let flowB = SkinNoiseField(seed: seed &* 131 &+ 9, wavelengthMm: flowWavelength)
        var guardCount = 0
        while !active.isEmpty, guardCount < 10_000 {
            guardCount += 1
            var nextActive: [Int] = []
            nextActive.reserveCapacity(active.count)
            // Pair branches MUTUALLY each layer (greedy nearest-pair): both members
            // steer to the same meeting point, converging at up to maxAngle (the
            // Cura rule: preferred angle in open space, max angle when needed to
            // reach a merge). One-sided chasing never closes the gap.
            let pairs = convergencePairs(
                active: active,
                nodes: nodes,
                eligible: { depth[$0] >= tipHoldLayers },
                convergenceTan: maxSlopeTan,
                plateZ: plateZ,
                avoidance: &avoidance
            )
            for index in active {
                let node = nodes[index]
                let dz = min(effectiveStep, max(node.position.z - plateZ, 0))
                if dz <= 1.0e-6 {
                    continue
                }
                // Steering: converge on the paired branch — this is what turns
                // parallel nails into a tree. Lone branches drift toward the
                // forest centroid so trunks form; fresh tips hold vertical so
                // surface contact stays clean.
                var target: Vec3
                var steeringTan = preferredTan
                if depth[index] < tipHoldLayers {
                    target = Vec3(x: node.position.x, y: node.position.y, z: 0)
                } else if let partner = pairs[index] {
                    let other = nodes[partner]
                    let aw = pow(node.radius, 3)
                    let bw = pow(other.radius, 3)
                    let sum = max(aw + bw, 1.0e-9)
                    target = Vec3(
                        x: (node.position.x * aw + other.position.x * bw) / sum,
                        y: (node.position.y * aw + other.position.y * bw) / sum,
                        z: 0
                    )
                    steeringTan = maxSlopeTan
                } else {
                    target = avoidance == nil ? center : Vec3(x: node.position.x, y: node.position.y, z: 0)
                }
                let maxMove = dz * steeringTan
                let toTarget = Vec3(x: target.x - node.position.x, y: target.y - node.position.y, z: 0)
                let planarLength = max((toTarget.x * toTarget.x + toTarget.y * toTarget.y).squareRoot(), 1.0e-9)
                let move = min(maxMove, planarLength)
                let dirX = toTarget.x / planarLength
                let dirY = toTarget.y / planarLength
                // Seeded wander: the flow field acts as an ADDITIVE lateral push,
                // not a rotation — rotating the steering direction gets corrected
                // away by next step's re-aim (slight bow, no snake). An additive
                // push ACCUMULATES until the field reverses (~half a wavelength),
                // giving genuine serpentine sway; steering still owns convergence,
                // and spatial coherence means paired branches ride the same push,
                // so their gap keeps closing. Total lateral is clamped to the
                // maxAngle cone, so the slope gate holds by construction.
                var lateralX = dirX * move
                var lateralY = dirY * move
                if variation > 0, depth[index] >= tipHoldLayers {
                    let fieldGain = dz * maxSlopeTan * variation
                    lateralX += flowA.value(at: node.position) * fieldGain
                    lateralY += flowB.value(at: node.position) * fieldGain
                    let lateral = (lateralX * lateralX + lateralY * lateralY).squareRoot()
                    let cap = dz * maxSlopeTan
                    if lateral > cap {
                        lateralX *= cap / lateral
                        lateralY *= cap / lateral
                    }
                }
                var next = Vec3(
                    x: node.position.x + lateralX,
                    y: node.position.y + lateralY,
                    z: node.position.z - dz
                )
                if var activeAvoidance = avoidance {
                    let clear = activeAvoidance.isClear(next, radius: node.radius)
                    if clear {
                        hasClearedAvoidance[index] = true
                        blockedLayers[index] = 0
                    } else if hasClearedAvoidance[index] {
                        if let pushed = activeAvoidance.pushOut(next, radius: node.radius, maxStep: dz * maxSlopeTan) {
                            next = pushed
                        }
                        if activeAvoidance.isClear(next, radius: node.radius) {
                            blockedLayers[index] = 0
                        } else {
                            blockedLayers[index] += 1
                            if blockedLayers[index] >= 3 {
                                restOnModelCount += 1
                                avoidance = activeAvoidance
                                continue
                            }
                        }
                    }
                    avoidance = activeAvoidance
                }
                let movedHorizontal = horizontalDistance(node.position, next)
                let allowedHorizontal = dz * maxSlopeTan
                if movedHorizontal > allowedHorizontal, movedHorizontal > 1.0e-9 {
                    let scale = allowedHorizontal / movedHorizontal
                    next = Vec3(
                        x: node.position.x + (next.x - node.position.x) * scale,
                        y: node.position.y + (next.y - node.position.y) * scale,
                        z: next.z
                    )
                }
                var radius = min(maxRadius, node.radius + dz * taper)
                let heightAbovePlate = max(next.z - plateZ, 0)
                if heightAbovePlate < flareZone {
                    // Flare follows the Taper control: heavy taper = rooted trunk
                    // feet (cactus/tree); zero taper = slender vine ends.
                    let flareGain = 0.5 * min(safe.diameterAngleDeg / 5.0, 1.0)
                    let t = 1.0 - heightAbovePlate / flareZone
                    radius = min(maxRadius * 1.5, radius * (1.0 + flareGain * t))
                }
                let nextIndex = nodes.count
                nodes.append(BranchNode(
                    position: next,
                    radius: radius,
                    parentIndex: nil,
                    isTip: false
                ))
                depth.append(depth[index] + 1)
                hasClearedAvoidance.append(hasClearedAvoidance[index] || avoidance == nil)
                blockedLayers.append(blockedLayers[index])
                nodes[index].parentIndex = nextIndex
                nextActive.append(nextIndex)
            }
            active = merge(
                nodes: &nodes,
                depth: &depth,
                active: nextActive,
                maxStep: effectiveStep,
                maxSlopeTan: maxSlopeTan,
                plateZ: plateZ,
                maxRadius: maxRadius,
                maxTaperGain: safe.diameterAngleDeg / 15.0,
                mergeCount: &mergeCount
            )
            while hasClearedAvoidance.count < nodes.count {
                hasClearedAvoidance.append(avoidance == nil)
                blockedLayers.append(0)
            }
        }

        let actualTips = nodes.filter(\.isTip).map { SupportSurfaceSample(position: $0.position, normal: Vec3(x: 0, y: 0, z: 1)) }
        let audit = audit(
            targetSamples: samples,
            tips: actualTips,
            nodes: nodes,
            settings: safe,
            effectiveStep: effectiveStep,
            plateZ: plateZ,
            mergeCount: mergeCount,
            restOnModelCount: restOnModelCount
        )
        return SupportBuildResult(
            targetSamples: samples,
            tips: actualTips,
            nodes: nodes,
            audit: audit,
            coarseningNotice: notice
        )
    }

    /// Greedy nearest-pair matching over the active set: disjoint mutual pairs of
    /// branches that can still meet ABOVE the plate (each closing half the gap at
    /// `convergenceTan`). Deterministic: candidates sorted by (gap, indices).
    private static func convergencePairs(
        active: [Int],
        nodes: [BranchNode],
        eligible: (Int) -> Bool,
        convergenceTan: Double,
        plateZ: Double,
        avoidance: inout AvoidanceVolumes?
    ) -> [Int: Int] {
        guard active.count > 1 else { return [:] }
        var candidates: [(gap: Double, a: Int, b: Int)] = []
        for i in 0..<active.count {
            let aIndex = active[i]
            guard eligible(aIndex) else { continue }
            for j in (i + 1)..<active.count {
                let bIndex = active[j]
                guard eligible(bIndex) else { continue }
                let gap = horizontalDistance(nodes[aIndex].position, nodes[bIndex].position)
                let dropNeeded = (gap * 0.5) / max(convergenceTan, 1.0e-9)
                let meetZ = min(nodes[aIndex].position.z, nodes[bIndex].position.z) - dropNeeded
                guard meetZ > plateZ + 1.0e-6 else { continue }
                if var activeAvoidance = avoidance {
                    let radius = max(nodes[aIndex].radius, nodes[bIndex].radius)
                    guard activeAvoidance.lineOfSight(nodes[aIndex].position, nodes[bIndex].position, radius: radius) else {
                        avoidance = activeAvoidance
                        continue
                    }
                    avoidance = activeAvoidance
                }
                candidates.append((gap, aIndex, bIndex))
            }
        }
        candidates.sort {
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            if $0.a != $1.a { return $0.a < $1.a }
            return $0.b < $1.b
        }
        var paired = Set<Int>()
        var result: [Int: Int] = [:]
        for candidate in candidates
        where !paired.contains(candidate.a) && !paired.contains(candidate.b) {
            paired.insert(candidate.a)
            paired.insert(candidate.b)
            result[candidate.a] = candidate.b
            result[candidate.b] = candidate.a
        }
        return result
    }

    private static func merge(
        nodes: inout [BranchNode],
        depth: inout [Int],
        active: [Int],
        maxStep: Double,
        maxSlopeTan: Double,
        plateZ: Double,
        maxRadius: Double,
        maxTaperGain: Double,
        mergeCount: inout Int
    ) -> [Int] {
        guard active.count > 1 else { return active }
        var used = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(active.count)
        for i in 0..<active.count {
            let aIndex = active[i]
            guard !used.contains(aIndex) else { continue }
            var mergeWith: Int?
            for j in (i + 1)..<active.count {
                let bIndex = active[j]
                guard !used.contains(bIndex) else { continue }
                let a = nodes[aIndex]
                let b = nodes[bIndex]
                // Branches seeded on sloped surfaces run at different heights; the
                // elbow lands below BOTH (the higher edge only gets shallower), so
                // a wide z-window is safe. The old 1.5-step window left XY-touching
                // pairs descending in parallel forever.
                guard abs(a.position.z - b.position.z) <= maxStep * 6.0 else { continue }
                // Fuse once the steering has brought the pair into touching range.
                // The elbow below may legitimately span multiple steps — the old
                // `requiredDrop <= 2·step` clamp is what froze every merge and
                // produced the bed-of-nails output.
                guard horizontalDistance(a.position, b.position) < (a.radius + b.radius) * 1.25 else { continue }
                let aw = pow(a.radius, 3)
                let bw = pow(b.radius, 3)
                let sum = max(aw + bw, 1.0e-9)
                let mergeXY = Vec3(
                    x: (a.position.x * aw + b.position.x * bw) / sum,
                    y: (a.position.y * aw + b.position.y * bw) / sum,
                    z: min(a.position.z, b.position.z)
                )
                let horizontal = max(horizontalDistance(a.position, mergeXY), horizontalDistance(b.position, mergeXY))
                let requiredDrop = max(horizontal / max(maxSlopeTan, 1.0e-9), 1.0e-6)
                guard min(a.position.z, b.position.z) - requiredDrop >= plateZ else { continue }
                mergeWith = bIndex
                break
            }
            if let bIndex = mergeWith {
                let a = nodes[aIndex]
                let b = nodes[bIndex]
                let aw = pow(a.radius, 3)
                let bw = pow(b.radius, 3)
                let sum = max(aw + bw, 1.0e-9)
                let xy = Vec3(
                    x: (a.position.x * aw + b.position.x * bw) / sum,
                    y: (a.position.y * aw + b.position.y * bw) / sum,
                    z: min(a.position.z, b.position.z)
                )
                let horizontal = max(horizontalDistance(a.position, xy), horizontalDistance(b.position, xy))
                let requiredDrop = max(horizontal / max(maxSlopeTan, 1.0e-9), 1.0e-6)
                let merged = Vec3(
                    x: xy.x,
                    y: xy.y,
                    z: min(a.position.z, b.position.z) - requiredDrop
                )
                let mergedIndex = nodes.count
                // Join thickness follows Taper: at 0 the union stays as slender
                // as its bigger member (vines wind together without fattening);
                // at high taper it approaches Murray-law trunk building.
                let bigR = max(a.radius, b.radius)
                let smallR = min(a.radius, b.radius)
                let joinGain = 0.25 + 0.55 * min(maxTaperGain, 1.0)
                nodes.append(BranchNode(
                    position: merged,
                    radius: min(maxRadius, bigR + smallR * joinGain),
                    parentIndex: nil,
                    isTip: false
                ))
                depth.append(max(depth[aIndex], depth[bIndex]) + 1)
                nodes[aIndex].parentIndex = mergedIndex
                nodes[bIndex].parentIndex = mergedIndex
                used.insert(aIndex)
                used.insert(bIndex)
                result.append(mergedIndex)
                mergeCount += 1
            } else {
                used.insert(aIndex)
                result.append(aIndex)
            }
        }
        return result
    }

    private static func audit(
        targetSamples: [SupportSurfaceSample],
        tips: [SupportSurfaceSample],
        nodes: [BranchNode],
        settings: SupportSettings,
        effectiveStep: Double,
        plateZ: Double,
        mergeCount: Int,
        restOnModelCount: Int
    ) -> SupportAudit {
        let tolerance = max(effectiveStep * 0.5, 1.0e-3)
        let coverage = SupportAuditMetrics.plateReachCoverage(
            nodes: nodes,
            plateZ: plateZ,
            tolerance: tolerance
        )
        let maxSlope = SupportAuditMetrics.maxSlopeDeg(nodes: nodes)
        let branchCount = nodes.filter { $0.parentIndex != nil }.count
        let plateRoots = nodes.filter {
            $0.parentIndex == nil && abs($0.position.z - plateZ) <= tolerance
        }.count
        return SupportAudit(
            targetSampleCount: targetSamples.count,
            tipCount: tips.count,
            tipCoverage: coverage,
            branchCount: branchCount,
            maxSlopeDeg: maxSlope,
            capsuleCount: branchCount,
            effectiveStepMm: effectiveStep,
            mergeCount: mergeCount,
            plateRootCount: plateRoots,
            modelIntersectionVolume: 0,
            overhangCoverage: settings.supportMode == .scaffold ? coverage : 0,
            restOnModelCount: restOnModelCount
        )
    }

    private static func averageXY(_ points: [Vec3]) -> Vec3 {
        guard !points.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        let sum = points.reduce(Vec3(x: 0, y: 0, z: 0)) {
            Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        return Vec3(x: sum.x / Double(points.count), y: sum.y / Double(points.count), z: 0)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

enum SupportSolidifier {
    /// Solidify the node forest as junction-to-junction branch CURVES: extract
    /// chains, simplify each with a curvature-preserving Douglas-Peucker (the
    /// snaking survives; collinear runs collapse), then sweep tapered capsules.
    /// This is what lets growth run at a FINE step (smooth curves) without the
    /// capsule budget forcing branches back into long straight polylines.
    static func solidify(
        nodes: [BranchNode],
        settings: SupportSettings,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> (solid: ManifoldHandle, notice: String?) {
        guard !nodes.isEmpty else { throw StructureEngineError.missingBounds }
        var childCount = [Int](repeating: 0, count: nodes.count)
        for node in nodes {
            if let p = node.parentIndex, nodes.indices.contains(p) { childCount[p] += 1 }
        }
        // Chain heads: tips/orphans (no one above) and every junction's downward
        // continuation. Each parent-edge belongs to exactly one chain.
        var heads: [Int] = []
        for index in nodes.indices where childCount[index] == 0 || childCount[index] >= 2 {
            heads.append(index)
        }
        var chains: [[Int]] = []
        for head in heads {
            var chain = [head]
            var current = head
            while let p = nodes[current].parentIndex, nodes.indices.contains(p) {
                chain.append(p)
                if childCount[p] >= 2 { break }   // junction ends this chain; its own chain continues below
                current = p
            }
            if chain.count >= 2 { chains.append(chain) }
        }

        let rawEdges = chains.reduce(0) { $0 + $1.count - 1 }
        let budget = 9_000
        var epsilon = 0.15 * max(settings.tipDiameterMm * 0.5, 0.3)
        var simplified = chains.map { simplifyIndices($0, nodes: nodes, epsilon: epsilon) }
        var edgeCount = simplified.reduce(0) { $0 + $1.count - 1 }
        var escalations = 0
        while edgeCount > budget, escalations < 4 {
            epsilon = min(epsilon * 1.8, 1.5)
            simplified = chains.map { simplifyIndices($0, nodes: nodes, epsilon: epsilon) }
            edgeCount = simplified.reduce(0) { $0 + $1.count - 1 }
            escalations += 1
        }
        let notice: String? = escalations > 0
            ? String(format: "Support curves simplified from %d to %d capsules (deviation up to %.2f mm) to stay within the capsule budget.", rawEdges, edgeCount, epsilon)
            : nil

        var solids: [ManifoldHandle] = []
        solids.reserveCapacity(edgeCount + chains.count)
        for chain in simplified {
            for (offset, index) in chain.enumerated() {
                let node = nodes[index]
                if offset == 0, node.isTip {
                    let sphere = try engine.sphere(radius: max(settings.tipDiameterMm * 0.5, 0.05), segments: 12)
                    solids.append(try engine.translate(sphere, x: node.position.x, y: node.position.y, z: node.position.z))
                }
                guard offset + 1 < chain.count else { continue }
                let next = nodes[chain[offset + 1]]
                guard distance(node.position, next.position) > 1.0e-6 else { continue }
                let a = try engine.translate(
                    engine.sphere(radius: max(node.radius, 0.05), segments: 12),
                    x: node.position.x, y: node.position.y, z: node.position.z
                )
                let b = try engine.translate(
                    engine.sphere(radius: max(next.radius, 0.05), segments: 12),
                    x: next.position.x, y: next.position.y, z: next.position.z
                )
                solids.append(try engine.convexHull(joining: a, b))
            }
        }
        guard !solids.isEmpty else { throw StructureEngineError.missingBounds }
        return (try engine.union(solids), notice)
    }

    /// Douglas-Peucker over node indices (endpoints always kept, so junctions
    /// and tips stay exact and radii taper through the kept nodes).
    private static func simplifyIndices(_ chain: [Int], nodes: [BranchNode], epsilon: Double) -> [Int] {
        guard chain.count > 2, epsilon > 0 else { return chain }
        var keep = [Bool](repeating: false, count: chain.count)
        keep[0] = true
        keep[chain.count - 1] = true
        dpRecurse(chain, nodes, 0, chain.count - 1, epsilon, &keep)
        return chain.indices.compactMap { keep[$0] ? chain[$0] : nil }
    }

    private static func dpRecurse(
        _ chain: [Int], _ nodes: [BranchNode], _ lo: Int, _ hi: Int, _ epsilon: Double, _ keep: inout [Bool]
    ) {
        guard hi > lo + 1 else { return }
        var maxDistance = 0.0
        var maxIndex = lo
        let a = nodes[chain[lo]].position
        let b = nodes[chain[hi]].position
        for i in (lo + 1)..<hi {
            let d = pointSegmentDistance(nodes[chain[i]].position, a, b)
            if d > maxDistance {
                maxDistance = d
                maxIndex = i
            }
        }
        if maxDistance > epsilon {
            keep[maxIndex] = true
            dpRecurse(chain, nodes, lo, maxIndex, epsilon, &keep)
            dpRecurse(chain, nodes, maxIndex, hi, epsilon, &keep)
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

enum SupportAuditMetrics {
    /// Fraction of tips whose parent chain terminates at the plate. The retired
    /// metric compared the tip set against itself and could never read below 1.0.
    static func plateReachCoverage(nodes: [BranchNode], plateZ: Double, tolerance: Double) -> Double {
        let tipIndices = nodes.indices.filter { nodes[$0].isTip }
        guard !tipIndices.isEmpty else { return 0 }
        var reached = 0
        for tip in tipIndices {
            var index = tip
            var hops = 0
            while let parent = nodes[index].parentIndex, nodes.indices.contains(parent), hops < nodes.count {
                index = parent
                hops += 1
            }
            if nodes[index].position.z <= plateZ + tolerance {
                reached += 1
            }
        }
        return Double(reached) / Double(tipIndices.count)
    }

    static func maxSlopeDeg(nodes: [BranchNode]) -> Double {
        var maxSlope = 0.0
        for node in nodes {
            guard let parentIndex = node.parentIndex, nodes.indices.contains(parentIndex) else {
                continue
            }
            let parent = nodes[parentIndex]
            let dz = abs(node.position.z - parent.position.z)
            let dx = node.position.x - parent.position.x
            let dy = node.position.y - parent.position.y
            guard dz > 1.0e-9 else {
                if (dx * dx + dy * dy).squareRoot() > 1.0e-9 {
                    maxSlope = max(maxSlope, 90.0)
                }
                continue
            }
            let angle = atan((dx * dx + dy * dy).squareRoot() / dz) * 180.0 / Double.pi
            maxSlope = max(maxSlope, angle)
        }
        return maxSlope
    }

    static func surfaceCoverage(
        targets: [SupportSurfaceSample],
        tips: [SupportSurfaceSample],
        maxDistance: Double
    ) -> Double {
        guard !targets.isEmpty else { return 0 }
        var covered = 0
        for target in targets {
            if tips.contains(where: { distance($0.position, target.position) <= maxDistance }) {
                covered += 1
            }
        }
        return Double(covered) / Double(targets.count)
    }
}

private func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
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

private func dot(_ a: Vec3, _ b: Vec3) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

private func scale(_ v: Vec3, _ s: Double) -> Vec3 {
    Vec3(x: v.x * s, y: v.y * s, z: v.z * s)
}

private func distance(_ a: Vec3, _ b: Vec3) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    let dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}

private func horizontalDistance(_ a: Vec3, _ b: Vec3) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}
