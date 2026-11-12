import Foundation

/// Cap + registration-key geometry for the Partition mode, built WITHOUT CSG.
///
/// `capInterface` caps a cut interface island-aware: each section is an outer
/// boundary with contained holes (tubes/bores keep their voids). The male piece
/// gets a solid cap (holes preserved) plus a closed boss per key; the female
/// piece gets a cap with the key footprints punched out plus pocket walls and a
/// floor. The female hole and the pocket wall top reuse the SAME lifted profile
/// points, so they weld and the female piece stays one watertight shell.
///
/// Two key profiles share this machinery: a round PIN (`.pins`) and a
/// rectangular anti-rotation WEDGE (`.dovetail`). Both press together along the
/// cut normal (no undercut), so both stay printable. Pin length/pocket depth are
/// ray-probed against the actual piece thickness so a key never punches through a
/// thin wall — where there is no room, the seam falls back to a butt joint.
enum PartitionKeys {
    struct Placement: Equatable {
        var center: Vec3
        var radius: Double
    }

    struct InterfaceResult {
        var male: [(Vec3, Vec3, Vec3)] = []
        var female: [(Vec3, Vec3, Vec3)] = []
        var placements: [Placement] = []
    }

    private static let circleSegments = 24
    private static let embed = 0.6

    /// Cap one cut interface. `maleSoup`/`femaleSoup` are the two clipped pieces
    /// (pre-cap), used to ray-probe how much material backs each key.
    static func capInterface(
        islands: [PartitionGeometry.Island],
        plane: PartitionGeometry.PlaneEq,
        key: PartitionKeySettings,
        maleSoup: [(Vec3, Vec3, Vec3)],
        femaleSoup: [(Vec3, Vec3, Vec3)]
    ) -> InterfaceResult {
        let (u, v) = PartitionGeometry.basis(plane.n)
        let origin = Vec3(x: plane.n.x * plane.d, y: plane.n.y * plane.d, z: plane.n.z * plane.d)
        var result = InterfaceResult()

        let base = key.pinDiameter / 2
        let isRect = key.type == .dovetail
        let halfW = isRect ? base * 1.4 : base
        let halfH = isRect ? base * 0.7 : base
        let tol = key.tolerance
        let clearRadius = (halfW * halfW + halfH * halfH).squareRoot() + tol

        for island in islands {
            let outer2D = island.outer.map { PartitionGeometry.project($0, origin: origin, u: u, v: v) }
            let holes2D = island.holes.map { hole in hole.map { PartitionGeometry.project($0, origin: origin, u: u, v: v) } }

            var keyCenters: [Vec2] = []
            if key.type != .none {
                keyCenters = placeKeys(
                    inOuter: outer2D,
                    holes: holes2D,
                    count: max(1, key.pinsPerSeam),
                    clearance: clearRadius + key.edgeMargin,
                    separation: 2 * clearRadius + key.edgeMargin
                )
            }

            // Keep only keys with enough material on both sides; clamp depth.
            struct Keyed { var center2D: Vec2; var center3D: Vec3; var pinLength: Double; var pocketDepth: Double }
            var keyed: [Keyed] = []
            for c2 in keyCenters {
                let c3 = PartitionGeometry.unproject(c2, origin: origin, u: u, v: v)
                let femaleDepth = rayFirstHit(origin: PartitionGeometry.add(c3, PartitionGeometry.scale(plane.n, 1.0e-3)), dir: plane.n, triangles: femaleSoup) ?? .greatestFiniteMagnitude
                let maleDepth = rayFirstHit(origin: PartitionGeometry.add(c3, PartitionGeometry.scale(plane.n, -1.0e-3)), dir: PartitionGeometry.scale(plane.n, -1), triangles: maleSoup) ?? .greatestFiniteMagnitude
                let maxPocket = max(0, 0.8 * femaleDepth)
                let pocketDepth = min(key.pinLength + tol + 0.5, maxPocket)
                let pinLength = max(0, pocketDepth - tol - 0.5)
                // Need a usable pocket and enough male backing to seat the boss.
                guard pocketDepth >= 2.0, pinLength >= 1.0, maleDepth >= embed + 1.0 else { continue }
                keyed.append(Keyed(center2D: c2, center3D: c3, pinLength: pinLength, pocketDepth: pocketDepth))
            }

            // Male cap: section solid (voids preserved), no key holes.
            result.male += capFromTris(triangulateWithHoles(outer: outer2D, holes: holes2D), origin: origin, u: u, v: v, outwardPositive: true)

            // Female cap: section solid with key footprints ALSO punched out.
            let keyHoles2D = keyed.map { profile(center: $0.center2D, halfW: halfW + tol, halfH: halfH + tol, rect: isRect, clockwise: true) }
            result.female += capFromTris(triangulateWithHoles(outer: outer2D, holes: holes2D + keyHoles2D), origin: origin, u: u, v: v, outwardPositive: false)

            for (index, k) in keyed.enumerated() {
                result.placements.append(Placement(center: k.center3D, radius: clearRadius))

                // Male boss: closed prism from just inside the male piece, out +n.
                let bossProfile = profile(center: k.center2D, halfW: halfW, halfH: halfH, rect: isRect, clockwise: false)
                let bossBottom = liftRing(bossProfile, origin: origin, u: u, v: v, normal: plane.n, offset: -embed)
                let bossTop = liftRing(bossProfile, origin: origin, u: u, v: v, normal: plane.n, offset: k.pinLength)
                appendClosedPrism(bottom: bossBottom, top: bossTop, into: &result.male)

                // Female pocket: walls from the hole rim (on plane) into +n, floor.
                let hole = keyHoles2D[index]
                let pocketTop = liftRing(hole, origin: origin, u: u, v: v, normal: plane.n, offset: 0)
                let pocketBottom = liftRing(hole, origin: origin, u: u, v: v, normal: plane.n, offset: k.pocketDepth)
                appendOpenTube(top: pocketTop, bottom: pocketBottom, into: &result.female)
                let floorCenter = PartitionGeometry.add(k.center3D, PartitionGeometry.scale(plane.n, k.pocketDepth))
                appendDisk(ring: pocketBottom, center: floorCenter, into: &result.female)
            }
        }
        return result
    }

    private static func capFromTris(_ tris2D: [(Vec2, Vec2, Vec2)], origin: Vec3, u: Vec3, v: Vec3, outwardPositive: Bool) -> [(Vec3, Vec3, Vec3)] {
        var out: [(Vec3, Vec3, Vec3)] = []
        for tri in tris2D {
            let a = PartitionGeometry.unproject(tri.0, origin: origin, u: u, v: v)
            let b = PartitionGeometry.unproject(tri.1, origin: origin, u: u, v: v)
            let c = PartitionGeometry.unproject(tri.2, origin: origin, u: u, v: v)
            // triangulate is CCW in (u,v) => normal +n. Reverse for the -n side.
            out.append(outwardPositive ? (a, b, c) : (a, c, b))
        }
        return out
    }

    // MARK: - Key placement

    private static func placeKeys(inOuter outer: [Vec2], holes: [[Vec2]], count: Int, clearance: Double, separation: Double) -> [Vec2] {
        guard outer.count >= 3 else { return [] }
        var minX = outer[0].x, maxX = outer[0].x, minY = outer[0].y, maxY = outer[0].y
        for p in outer {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        // Sampling density scales with the footprint so narrow channels aren't missed.
        let span = max(maxX - minX, maxY - minY)
        let steps = min(60, max(16, Int(span / max(clearance * 0.4, 1.0e-6))))

        var candidates: [(point: Vec2, clearance: Double)] = []
        for ix in 0...steps {
            for iy in 0...steps {
                let x = minX + (maxX - minX) * Double(ix) / Double(steps)
                let y = minY + (maxY - minY) * Double(iy) / Double(steps)
                let p = Vec2(x: x, y: y)
                guard PartitionGeometry.pointInPolygon2D(p, outer) else { continue }
                if holes.contains(where: { PartitionGeometry.pointInPolygon2D(p, $0) }) { continue }
                var c = clearanceToBoundary(p, outer)
                for hole in holes { c = min(c, clearanceToBoundary(p, hole)) }
                if c >= clearance { candidates.append((p, c)) }
            }
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.clearance > $1.clearance }

        var chosen: [Vec2] = []
        for candidate in candidates {
            if chosen.allSatisfy({ distance2D($0, candidate.point) >= separation }) {
                chosen.append(candidate.point)
                if chosen.count >= count { break }
            }
        }
        return chosen
    }

    // MARK: - Profiles

    private static func profile(center: Vec2, halfW: Double, halfH: Double, rect: Bool, clockwise: Bool) -> [Vec2] {
        rect ? rectangleRing(center: center, halfW: halfW, halfH: halfH, clockwise: clockwise)
             : circle(center: center, radius: halfW, clockwise: clockwise)
    }

    private static func circle(center: Vec2, radius: Double, clockwise: Bool) -> [Vec2] {
        var points: [Vec2] = []
        for i in 0..<circleSegments {
            let t = Double(i) / Double(circleSegments) * 2 * Double.pi
            let angle = clockwise ? -t : t
            points.append(Vec2(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
        return points
    }

    private static func rectangleRing(center: Vec2, halfW: Double, halfH: Double, clockwise: Bool) -> [Vec2] {
        let ccw = [
            Vec2(x: center.x - halfW, y: center.y - halfH),
            Vec2(x: center.x + halfW, y: center.y - halfH),
            Vec2(x: center.x + halfW, y: center.y + halfH),
            Vec2(x: center.x - halfW, y: center.y + halfH)
        ]
        return clockwise ? ccw.reversed() : ccw
    }

    // MARK: - Polygon-with-holes triangulation

    static func triangulateWithHoles(outer: [Vec2], holes: [[Vec2]]) -> [(Vec2, Vec2, Vec2)] {
        guard outer.count >= 3 else { return [] }
        let orientedOuter = ensureOrientation(outer, counterClockwise: true)
        let usableHoles = holes.filter { $0.count >= 3 }
        if usableHoles.isEmpty,
           let fan = starKernelFan(orientedOuter) {
            return fan
        }

        var merged = orientedOuter
        for hole in usableHoles {
            let oriented = ensureOrientation(hole, counterClockwise: false)
            merged = bridge(outer: merged, hole: oriented)
        }
        var tris: [(Vec2, Vec2, Vec2)] = []
        for (i, j, k) in triangulateWeaklySimplePolygon(merged) {
            guard merged.indices.contains(i), merged.indices.contains(j), merged.indices.contains(k) else { continue }
            let a = merged[i], b = merged[j], c = merged[k]
            let a2 = area2(a, b, c)
            // Match MeshPreflight.isDegenerate exactly (|cross|^2 > 1e-10), so a
            // triangle the cap emits is also counted by the watertight gate.
            if a2 * a2 > 1.0e-10 {
                tris.append((a, b, c))
            }
        }
        return tris
    }

    /// A star-shaped section can be capped from any point in its visibility
    /// kernel. This fan uses every original boundary edge exactly once, so
    /// near-collinear boundary vertices are joined to a distant interior point
    /// instead of becoming a final microscopic ear that MeshPreflight must
    /// discard. Return nil for non-star-shaped polygons; those continue through
    /// the general bridge + ear-clipping path below.
    private static func starKernelFan(_ polygon: [Vec2]) -> [(Vec2, Vec2, Vec2)]? {
        guard polygon.count >= 3 else { return nil }
        var minimumX = polygon[0].x
        var maximumX = polygon[0].x
        var minimumY = polygon[0].y
        var maximumY = polygon[0].y
        for point in polygon.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        let span = max(maximumX - minimumX, maximumY - minimumY)
        guard span.isFinite, span > 1.0e-9 else { return nil }
        let margin = span + 1
        var kernel = [
            Vec2(x: minimumX - margin, y: minimumY - margin),
            Vec2(x: maximumX + margin, y: minimumY - margin),
            Vec2(x: maximumX + margin, y: maximumY + margin),
            Vec2(x: minimumX - margin, y: maximumY + margin),
        ]

        func side(_ point: Vec2, edgeA: Vec2, edgeB: Vec2) -> Double {
            (edgeB.x - edgeA.x) * (point.y - edgeA.y)
                - (edgeB.y - edgeA.y) * (point.x - edgeA.x)
        }
        for index in polygon.indices {
            let edgeA = polygon[index]
            let edgeB = polygon[(index + 1) % polygon.count]
            guard !kernel.isEmpty else { return nil }
            var clipped: [Vec2] = []
            for kernelIndex in kernel.indices {
                let current = kernel[kernelIndex]
                let previous = kernel[(kernelIndex + kernel.count - 1) % kernel.count]
                let currentSide = side(current, edgeA: edgeA, edgeB: edgeB)
                let previousSide = side(previous, edgeA: edgeA, edgeB: edgeB)
                let currentInside = currentSide >= -1.0e-12
                let previousInside = previousSide >= -1.0e-12
                if currentInside != previousInside {
                    let denominator = previousSide - currentSide
                    guard abs(denominator) > 1.0e-18 else { return nil }
                    let fraction = previousSide / denominator
                    clipped.append(Vec2(
                        x: previous.x + (current.x - previous.x) * fraction,
                        y: previous.y + (current.y - previous.y) * fraction
                    ))
                }
                if currentInside { clipped.append(current) }
            }
            kernel = clipped
        }
        guard !kernel.isEmpty else { return nil }
        let center = kernel.reduce(Vec2(x: 0, y: 0)) {
            Vec2(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let interior = Vec2(
            x: center.x / Double(kernel.count),
            y: center.y / Double(kernel.count)
        )

        var triangles: [(Vec2, Vec2, Vec2)] = []
        triangles.reserveCapacity(polygon.count)
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let areaTwice = area2(interior, a, b)
            guard areaTwice > 0, areaTwice * areaTwice > 1.0e-10 else { return nil }
            triangles.append((interior, a, b))
        }
        return triangles
    }

    /// Ear clipping for the weakly-simple polygon produced by a hole bridge.
    /// The bridge intentionally repeats its two endpoints. The viewport
    /// triangulator treats the repeated coordinates as unrelated reflex
    /// vertices, so they can block every otherwise valid ear and trigger its
    /// rendering-only fan fallback (which fills the hole). Here coincident
    /// copies of an ear vertex are ignored as blockers while all other boundary
    /// points retain the normal inclusive containment test.
    private static func triangulateWeaklySimplePolygon(
        _ points: [Vec2]
    ) -> [(Int, Int, Int)] {
        let count = points.count
        guard count >= 3 else { return [] }
        if count == 3 { return [(0, 1, 2)] }

        var doubledArea = 0.0
        for index in points.indices {
            let next = points[(index + 1) % count]
            doubledArea += points[index].x * next.y - next.x * points[index].y
        }
        var remaining = doubledArea >= 0
            ? Array(points.indices)
            : Array(points.indices.reversed())

        func cross(_ origin: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - origin.x) * (b.y - origin.y)
                - (a.y - origin.y) * (b.x - origin.x)
        }
        func same(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
            abs(lhs.x - rhs.x) <= 1.0e-10 && abs(lhs.y - rhs.y) <= 1.0e-10
        }
        func pointInTriangle(_ point: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
            let d1 = cross(a, b, point)
            let d2 = cross(b, c, point)
            let d3 = cross(c, a, point)
            let hasNegative = d1 < -1.0e-12 || d2 < -1.0e-12 || d3 < -1.0e-12
            let hasPositive = d1 > 1.0e-12 || d2 > 1.0e-12 || d3 > 1.0e-12
            return !(hasNegative && hasPositive)
        }
        func isReflex(_ listIndex: Int) -> Bool {
            let n = remaining.count
            let a = points[remaining[(listIndex + n - 1) % n]]
            let b = points[remaining[listIndex]]
            let c = points[remaining[(listIndex + 1) % n]]
            return cross(a, b, c) < -1.0e-12
        }

        var result: [(Int, Int, Int)] = []
        var cursor = 0
        var failedPasses = 0
        while remaining.count > 3 {
            let n = remaining.count
            if failedPasses > n + 2 { return [] }
            let previousIndex = (cursor + n - 1) % n
            let nextIndex = (cursor + 1) % n
            let previous = remaining[previousIndex]
            let current = remaining[cursor]
            let next = remaining[nextIndex]
            let a = points[previous]
            let b = points[current]
            let c = points[next]
            let earAreaTwice = cross(a, b, c)
            if earAreaTwice > 0,
               earAreaTwice * earAreaTwice > 1.0e-10 {
                var isEar = true
                for (listIndex, other) in remaining.enumerated()
                where other != previous && other != current && other != next {
                    guard isReflex(listIndex) else { continue }
                    let point = points[other]
                    if same(point, a) || same(point, b) || same(point, c) { continue }
                    if pointInTriangle(point, a, b, c) {
                        isEar = false
                        break
                    }
                }
                if isEar {
                    result.append((previous, current, next))
                    remaining.remove(at: cursor)
                    if cursor >= remaining.count { cursor = 0 }
                    failedPasses = 0
                    continue
                }
            }
            cursor += 1
            if cursor >= remaining.count {
                cursor = 0
                failedPasses += 1
            }
        }
        let finalAreaTwice = cross(
            points[remaining[0]],
            points[remaining[1]],
            points[remaining[2]]
        )
        guard finalAreaTwice > 0,
              finalAreaTwice * finalAreaTwice > 1.0e-10 else { return [] }
        result.append((remaining[0], remaining[1], remaining[2]))
        return result
    }

    private static func bridge(outer: [Vec2], hole: [Vec2]) -> [Vec2] {
        guard !hole.isEmpty, outer.count >= 3 else { return outer }
        var hi = 0
        for i in hole.indices where hole[i].x > hole[hi].x || (hole[i].x == hole[hi].x && hole[i].y > hole[hi].y) {
            hi = i
        }
        let m = hole[hi]

        var bestIndex = -1
        var bestDistance = Double.greatestFiniteMagnitude
        for oi in outer.indices {
            let o = outer[oi]
            let d = distance2D(o, m)
            guard d < bestDistance else { continue }
            // The bridge must clear all edges AND run through the interior.
            guard segmentClearOfPolygon(m, o, outer), segmentClearOfHole(m, o, hole) else { continue }
            let mid = Vec2(x: (m.x + o.x) / 2, y: (m.y + o.y) / 2)
            guard PartitionGeometry.pointInPolygon2D(mid, outer) else { continue }
            bestDistance = d
            bestIndex = oi
        }
        if bestIndex < 0 {
            for oi in outer.indices {
                let d = distance2D(outer[oi], m)
                if d < bestDistance { bestDistance = d; bestIndex = oi }
            }
        }
        guard bestIndex >= 0 else { return outer }

        let rotated = (0..<hole.count).map { hole[(hi + $0) % hole.count] }
        var merged: [Vec2] = []
        merged.append(contentsOf: outer[0...bestIndex])
        merged.append(contentsOf: rotated)
        merged.append(rotated[0])
        merged.append(outer[bestIndex])
        if bestIndex + 1 < outer.count {
            merged.append(contentsOf: outer[(bestIndex + 1)...])
        }
        return merged
    }

    private static func segmentClearOfPolygon(_ a: Vec2, _ b: Vec2, _ poly: [Vec2]) -> Bool {
        for i in poly.indices {
            let c = poly[i]
            let d = poly[(i + 1) % poly.count]
            if samePoint(a, c) || samePoint(a, d) || samePoint(b, c) || samePoint(b, d) { continue }
            if segmentsIntersect(a, b, c, d) { return false }
        }
        return true
    }

    private static func segmentClearOfHole(_ a: Vec2, _ b: Vec2, _ hole: [Vec2]) -> Bool {
        // `a` is the hole's own bridge vertex; allow touching it, block crossing
        // any other hole edge.
        for i in hole.indices {
            let c = hole[i]
            let d = hole[(i + 1) % hole.count]
            if samePoint(a, c) || samePoint(a, d) { continue }
            if segmentsIntersect(a, b, c, d) { return false }
        }
        return true
    }

    // MARK: - Ray probe (Möller–Trumbore, nearest forward hit)

    private static func rayFirstHit(origin: Vec3, dir: Vec3, triangles: [(Vec3, Vec3, Vec3)]) -> Double? {
        var best: Double?
        for tri in triangles {
            let edge1 = PartitionGeometry.subtract(tri.1, tri.0)
            let edge2 = PartitionGeometry.subtract(tri.2, tri.0)
            let h = PartitionGeometry.cross(dir, edge2)
            let det = PartitionGeometry.dot(edge1, h)
            if abs(det) < 1.0e-12 { continue }
            let f = 1.0 / det
            let s = PartitionGeometry.subtract(origin, tri.0)
            let uu = f * PartitionGeometry.dot(s, h)
            if uu < -1.0e-9 || uu > 1.0 + 1.0e-9 { continue }
            let q = PartitionGeometry.cross(s, edge1)
            let vv = f * PartitionGeometry.dot(dir, q)
            if vv < -1.0e-9 || uu + vv > 1.0 + 1.0e-9 { continue }
            let t = f * PartitionGeometry.dot(edge2, q)
            if t > 1.0e-6 {
                if best == nil || t < best! { best = t }
            }
        }
        return best
    }

    // MARK: - Ring / shell builders

    private static func liftRing(_ poly: [Vec2], origin: Vec3, u: Vec3, v: Vec3, normal: Vec3, offset: Double) -> [Vec3] {
        poly.map { point in
            PartitionGeometry.add(PartitionGeometry.unproject(point, origin: origin, u: u, v: v), PartitionGeometry.scale(normal, offset))
        }
    }

    private static func appendClosedPrism(bottom: [Vec3], top: [Vec3], into tris: inout [(Vec3, Vec3, Vec3)]) {
        appendOpenTube(top: top, bottom: bottom, into: &tris)
        appendDisk(ring: bottom, center: centroid(bottom), into: &tris)
        appendDisk(ring: top, center: centroid(top), into: &tris)
    }

    private static func appendOpenTube(top: [Vec3], bottom: [Vec3], into tris: inout [(Vec3, Vec3, Vec3)]) {
        guard top.count == bottom.count, top.count >= 3 else { return }
        let n = top.count
        for i in 0..<n {
            let j = (i + 1) % n
            tris.append((top[i], bottom[i], bottom[j]))
            tris.append((top[i], bottom[j], top[j]))
        }
    }

    private static func appendDisk(ring: [Vec3], center: Vec3, into tris: inout [(Vec3, Vec3, Vec3)]) {
        guard ring.count >= 3 else { return }
        let n = ring.count
        for i in 0..<n {
            tris.append((center, ring[i], ring[(i + 1) % n]))
        }
    }

    private static func centroid(_ ring: [Vec3]) -> Vec3 {
        guard !ring.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        var sum = Vec3(x: 0, y: 0, z: 0)
        for p in ring { sum = PartitionGeometry.add(sum, p) }
        return PartitionGeometry.scale(sum, 1.0 / Double(ring.count))
    }

    // MARK: - 2D helpers

    private static func ensureOrientation(_ poly: [Vec2], counterClockwise: Bool) -> [Vec2] {
        (signedArea(poly) >= 0) == counterClockwise ? poly : poly.reversed()
    }

    private static func signedArea(_ poly: [Vec2]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var sum = 0.0
        for i in poly.indices {
            let j = (i + 1) % poly.count
            sum += poly[i].x * poly[j].y - poly[j].x * poly[i].y
        }
        return sum / 2
    }

    private static func area2(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func clearanceToBoundary(_ p: Vec2, _ poly: [Vec2]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for i in poly.indices {
            best = min(best, distancePointToSegment(p, poly[i], poly[(i + 1) % poly.count]))
        }
        return best
    }

    private static func distancePointToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1.0e-15 { return distance2D(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        return distance2D(p, Vec2(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// True for a proper crossing OR a collinear overlap / interior touch — the
    /// bridge visibility test must reject all of these, not just proper crossings.
    private static func segmentsIntersect(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let d1 = area2(c, d, a)
        let d2 = area2(c, d, b)
        let d3 = area2(a, b, c)
        let d4 = area2(a, b, d)
        if ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0)) {
            if abs(d1) > 1.0e-12 && abs(d2) > 1.0e-12 && abs(d3) > 1.0e-12 && abs(d4) > 1.0e-12 {
                return true
            }
        }
        // Collinear / touching cases.
        if abs(d1) <= 1.0e-12 && onSegment(c, d, a) { return true }
        if abs(d2) <= 1.0e-12 && onSegment(c, d, b) { return true }
        if abs(d3) <= 1.0e-12 && onSegment(a, b, c) { return true }
        if abs(d4) <= 1.0e-12 && onSegment(a, b, d) { return true }
        return false
    }

    private static func onSegment(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Bool {
        min(a.x, b.x) - 1.0e-9 <= p.x && p.x <= max(a.x, b.x) + 1.0e-9
            && min(a.y, b.y) - 1.0e-9 <= p.y && p.y <= max(a.y, b.y) + 1.0e-9
    }

    private static func distance2D(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func samePoint(_ a: Vec2, _ b: Vec2) -> Bool {
        abs(a.x - b.x) < 1.0e-9 && abs(a.y - b.y) < 1.0e-9
    }
}
