import Foundation

/// Low-level mesh operations for the Partition construction mode: clip a solid
/// triangle soup against an arbitrary plane, extract the planar cross-section as
/// closed loops, and cap those loops. This is the general primitive — axis-
/// aligned grid cuts are just planes whose normal is a basis vector.
///
/// The crossing point of a plane with a mesh edge is computed through ONE
/// canonical helper used by both the clip and the section extractor, so the cap
/// vertices are bit-identical to the clipped-surface boundary vertices. They
/// then weld (MeshPreflight tolerance 1e-6) and the capped piece is watertight.
enum PartitionGeometry {
    /// Plane `{ p : dot(p, n) == d }`, `n` a unit normal.
    struct PlaneEq: Equatable {
        var n: Vec3
        var d: Double

        init(normal: Vec3, offset: Double) {
            let len = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
            if len > 1.0e-12 {
                n = Vec3(x: normal.x / len, y: normal.y / len, z: normal.z / len)
                d = offset / len
            } else {
                n = Vec3(x: 0, y: 0, z: 1)
                d = offset
            }
        }
    }

    // MARK: - Model triangles

    static func triangleSoup(_ model: MeshSummary) -> [(Vec3, Vec3, Vec3)] {
        triangleSoup(model.geometry)
    }

    static func triangleSoup(_ geometry: MeshGeometryData) -> [(Vec3, Vec3, Vec3)] {
        let verts = geometry.vertices
        let idx = geometry.triangleIndices
        var tris: [(Vec3, Vec3, Vec3)] = []
        tris.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if verts.indices.contains(a), verts.indices.contains(b), verts.indices.contains(c) {
                tris.append((verts[a], verts[b], verts[c]))
            }
            i += 3
        }
        return tris
    }

    static func bounds(_ triangles: [(Vec3, Vec3, Vec3)]) -> Bounds3D? {
        var lo: Vec3?
        var hi: Vec3?
        func include(_ p: Vec3) {
            if let l = lo, let h = hi {
                lo = Vec3(x: min(l.x, p.x), y: min(l.y, p.y), z: min(l.z, p.z))
                hi = Vec3(x: max(h.x, p.x), y: max(h.y, p.y), z: max(h.z, p.z))
            } else {
                lo = p
                hi = p
            }
        }
        for tri in triangles {
            include(tri.0)
            include(tri.1)
            include(tri.2)
        }
        guard let lo, let hi else { return nil }
        return Bounds3D(min: lo, max: hi)
    }

    // MARK: - Half-space clip

    /// Triangles clipped to one side of `plane`. `keepPositive` keeps the
    /// `dot(p, n) >= d` half; otherwise the `<= d` half. The cut boundary lies
    /// exactly on the plane (capped separately by `capLoops`).
    static func clipHalfSpace(
        _ triangles: [(Vec3, Vec3, Vec3)],
        plane: PlaneEq,
        keepPositive: Bool
    ) -> [(Vec3, Vec3, Vec3)] {
        var out: [(Vec3, Vec3, Vec3)] = []
        out.reserveCapacity(triangles.count)
        for tri in triangles {
            let sa = signed(tri.0, plane), sb = signed(tri.1, plane), sc = signed(tri.2, plane)
            let ia = inside(sa, keepPositive), ib = inside(sb, keepPositive), ic = inside(sc, keepPositive)
            if ia && ib && ic {
                out.append(tri)
                continue
            }
            if !ia && !ib && !ic {
                continue
            }
            let verts = [tri.0, tri.1, tri.2]
            let svals = [sa, sb, sc]
            var poly: [Vec3] = []
            for i in 0..<3 {
                let cur = verts[i], curS = svals[i]
                let prevIdx = (i + 2) % 3
                let prev = verts[prevIdx], prevS = svals[prevIdx]
                let curIn = inside(curS, keepPositive), prevIn = inside(prevS, keepPositive)
                if curIn {
                    if !prevIn { poly.append(crossing(prev, prevS, cur, curS)) }
                    poly.append(cur)
                } else if prevIn {
                    poly.append(crossing(prev, prevS, cur, curS))
                }
            }
            guard poly.count >= 3 else { continue }
            for k in 1..<(poly.count - 1) {
                out.append((poly[0], poly[k], poly[k + 1]))
            }
        }
        return out
    }

    // MARK: - Cross-section extraction

    /// Closed loops where `plane` cuts the solid, stitched from per-triangle
    /// crossing segments. Loops do not repeat their first point.
    static func sectionLoops(_ triangles: [(Vec3, Vec3, Vec3)], plane: PlaneEq) -> [[Vec3]] {
        var segments: [(Vec3, Vec3)] = []
        for tri in triangles {
            let a = tri.0, b = tri.1, c = tri.2
            let sa = signed(a, plane), sb = signed(b, plane), sc = signed(c, plane)
            let pa = sa >= 0, pb = sb >= 0, pc = sc >= 0
            if pa == pb && pb == pc { continue }
            var pts: [Vec3] = []
            if pa != pb { pts.append(crossing(a, sa, b, sb)) }
            if pb != pc { pts.append(crossing(b, sb, c, sc)) }
            if pc != pa { pts.append(crossing(c, sc, a, sa)) }
            if pts.count == 2 {
                let len = distance(pts[0], pts[1])
                if len > 1.0e-9 { segments.append((pts[0], pts[1])) }
            }
        }
        return stitchLoops(segments)
    }

    private static func stitchLoops(_ segments: [(Vec3, Vec3)]) -> [[Vec3]] {
        guard !segments.isEmpty else { return [] }
        var adjacency: [VKey: [Int]] = [:]
        for (i, seg) in segments.enumerated() {
            adjacency[VKey(seg.0), default: []].append(i)
            adjacency[VKey(seg.1), default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Vec3]] = []

        for start in segments.indices where !used[start] {
            used[start] = true
            var loop: [Vec3] = [segments[start].0, segments[start].1]
            var currentKey = VKey(segments[start].1)
            let startKey = VKey(segments[start].0)
            var closed = false
            var guardCount = 0
            while guardCount <= segments.count {
                guardCount += 1
                guard let candidates = adjacency[currentKey] else { break }
                var advanced = false
                for segIndex in candidates where !used[segIndex] {
                    let seg = segments[segIndex]
                    let k0 = VKey(seg.0), k1 = VKey(seg.1)
                    let nextPoint: Vec3
                    if k0 == currentKey {
                        nextPoint = seg.1
                        currentKey = k1
                    } else if k1 == currentKey {
                        nextPoint = seg.0
                        currentKey = k0
                    } else {
                        continue
                    }
                    used[segIndex] = true
                    advanced = true
                    if currentKey == startKey {
                        closed = true
                    } else {
                        loop.append(nextPoint)
                    }
                    break
                }
                if closed || !advanced { break }
            }
            if closed, loop.count >= 3 {
                loops.append(loop)
            }
        }
        return loops
    }

    // MARK: - Capping

    /// Triangulated caps for the given on-plane loops. `outwardPositive == true`
    /// orients faces with normal `+n` (the cap for the piece on the `<= d` side,
    /// whose cut face looks toward `+n`); `false` orients `-n`.
    static func capLoops(
        _ loops: [[Vec3]],
        plane: PlaneEq,
        outwardPositive: Bool
    ) -> [(Vec3, Vec3, Vec3)] {
        let (u, v) = basis(plane.n)
        let origin = Vec3(x: plane.n.x * plane.d, y: plane.n.y * plane.d, z: plane.n.z * plane.d)
        var tris: [(Vec3, Vec3, Vec3)] = []
        for loop in loops where loop.count >= 3 {
            let pts2D = loop.map { project($0, origin: origin, u: u, v: v) }
            for (i, j, k) in ViewportSliceSolidRenderData.triangulate(pts2D) {
                guard loop.indices.contains(i), loop.indices.contains(j), loop.indices.contains(k) else { continue }
                if outwardPositive {
                    tris.append((loop[i], loop[j], loop[k]))
                } else {
                    tris.append((loop[i], loop[k], loop[j]))
                }
            }
        }
        return tris
    }

    // MARK: - Island classification (outer boundary + contained holes)

    /// One cross-section region: an outer boundary loop plus the loops nested
    /// directly inside it (holes/voids to preserve).
    struct Island: Equatable {
        var outer: [Vec3]
        var holes: [[Vec3]]
    }

    /// Group section loops into outer-with-holes islands by even/odd containment
    /// depth in the plane's 2D basis, so hollow/tubular sections keep their voids
    /// instead of being capped solid. Loops nested two deep (an island inside a
    /// void) become their own outer island.
    static func islands(from loops: [[Vec3]], plane: PlaneEq) -> [Island] {
        guard !loops.isEmpty else { return [] }
        let (u, v) = basis(plane.n)
        let origin = Vec3(x: plane.n.x * plane.d, y: plane.n.y * plane.d, z: plane.n.z * plane.d)
        let polys = loops.map { loop in loop.map { project($0, origin: origin, u: u, v: v) } }

        func representative(_ poly: [Vec2]) -> Vec2 { poly.first ?? Vec2(x: 0, y: 0) }

        var depth = [Int](repeating: 0, count: loops.count)
        for i in loops.indices {
            let rep = representative(polys[i])
            var d = 0
            for j in loops.indices where j != i {
                if pointInPolygon2D(rep, polys[j]) { d += 1 }
            }
            depth[i] = d
        }

        var result: [Island] = []
        for i in loops.indices where depth[i] % 2 == 0 {
            var holes: [[Vec3]] = []
            for h in loops.indices where h != i && depth[h] == depth[i] + 1 {
                if pointInPolygon2D(representative(polys[h]), polys[i]) {
                    holes.append(loops[h])
                }
            }
            result.append(Island(outer: loops[i], holes: holes))
        }
        return result
    }

    static func pointInPolygon2D(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let pi = poly[i], pj = poly[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let slope = (p.y - pi.y) / (pj.y - pi.y)
                if p.x < pi.x + slope * (pj.x - pi.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Plane basis / projection

    /// Orthonormal in-plane basis with `u × v == n`, so a CCW polygon in (u, v)
    /// has 3D normal `+n`.
    static func basis(_ n: Vec3) -> (u: Vec3, v: Vec3) {
        let helper: Vec3 = abs(n.x) < 0.9 ? Vec3(x: 1, y: 0, z: 0) : Vec3(x: 0, y: 1, z: 0)
        let u = normalized(cross(helper, n))
        let v = cross(n, u)
        return (u, v)
    }

    static func project(_ p: Vec3, origin: Vec3, u: Vec3, v: Vec3) -> Vec2 {
        let rel = Vec3(x: p.x - origin.x, y: p.y - origin.y, z: p.z - origin.z)
        return Vec2(x: dot(rel, u), y: dot(rel, v))
    }

    static func unproject(_ p: Vec2, origin: Vec3, u: Vec3, v: Vec3) -> Vec3 {
        Vec3(
            x: origin.x + u.x * p.x + v.x * p.y,
            y: origin.y + u.y * p.x + v.y * p.y,
            z: origin.z + u.z * p.x + v.z * p.y
        )
    }

    // MARK: - Mesh assembly

    static func flatShadedMesh(_ triangles: [(Vec3, Vec3, Vec3)]) -> ViewportFlatShadedMesh {
        ViewportSliceSolidRenderData.flatShadedMesh(from: triangles)
    }

    static func geometry(_ triangles: [(Vec3, Vec3, Vec3)]) -> MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        vertices.reserveCapacity(triangles.count * 3)
        indices.reserveCapacity(triangles.count * 3)
        for tri in triangles {
            for p in [tri.0, tri.1, tri.2] {
                indices.append(Int32(vertices.count))
                vertices.append(p)
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    // MARK: - Plane / vector primitives

    static func signed(_ p: Vec3, _ plane: PlaneEq) -> Double {
        dot(p, plane.n) - plane.d
    }

    private static func inside(_ s: Double, _ keepPositive: Bool) -> Bool {
        keepPositive ? s >= 0 : s <= 0
    }

    /// Direction-independent crossing point where the segment p0→p1 meets the
    /// plane (`s0`, `s1` are signed distances). Canonical vertex ordering makes
    /// the result identical no matter which side calls it.
    static func crossing(_ p0: Vec3, _ s0: Double, _ p1: Vec3, _ s1: Double) -> Vec3 {
        if before(p1, p0) {
            return crossingOrdered(p1, s1, p0, s0)
        }
        return crossingOrdered(p0, s0, p1, s1)
    }

    private static func crossingOrdered(_ a: Vec3, _ sa: Double, _ b: Vec3, _ sb: Double) -> Vec3 {
        let denom = sa - sb
        let t = abs(denom) < 1.0e-15 ? 0.0 : sa / denom
        return Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    private static func before(_ a: Vec3, _ b: Vec3) -> Bool {
        if a.x != b.x { return a.x < b.x }
        if a.y != b.y { return a.y < b.y }
        return a.z < b.z
    }

    static func add(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func scale(_ a: Vec3, _ s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }

    static func length(_ a: Vec3) -> Double { dot(a, a).squareRoot() }

    static func distance(_ a: Vec3, _ b: Vec3) -> Double { length(subtract(a, b)) }

    static func normalized(_ a: Vec3) -> Vec3 {
        let len = length(a)
        guard len > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: a.x / len, y: a.y / len, z: a.z / len)
    }
}

/// Position key matching MeshPreflight's 1e-6 weld tolerance, so stitched loop
/// endpoints merge exactly as the preflight will weld the exported mesh.
private struct VKey: Hashable, Comparable {
    let x: Int64
    let y: Int64
    let z: Int64
    init(_ p: Vec3) {
        x = Int64((p.x / 1.0e-6).rounded())
        y = Int64((p.y / 1.0e-6).rounded())
        z = Int64((p.z / 1.0e-6).rounded())
    }

    static func < (lhs: VKey, rhs: VKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

// MARK: - Attributed scoped cuts

extension PartitionGeometry {
    struct AttributedSplit: Equatable {
        var negative: AttributedMesh
        var positive: AttributedMesh
    }

    enum AttributedSplitError: LocalizedError, Equatable {
        case incompleteProvenance
        case coordinateOutsideSupportedRange
        case planeDoesNotSplit
        case sectionIsNotClosed
        case capTriangulationFailed
        case vertexGrazing
        case childIsNotClosed(
            side: PartitionCutSide,
            boundaryEdges: Int,
            degenerateTriangles: Int
        )

        var errorDescription: String? {
            switch self {
            case .incompleteProvenance:
                return "The target region contains incomplete or non-finite provenance."
            case .coordinateOutsideSupportedRange:
                return "The target region exceeds the supported coordinate magnitude for deterministic clipping."
            case .planeDoesNotSplit:
                return "The cut plane does not split the target region into two non-empty sides."
            case .sectionIsNotClosed:
                return "The cut plane did not produce a closed section on the target region."
            case .capTriangulationFailed:
                return "The target region's cut section could not be capped."
            case .vertexGrazing:
                return "The cut plane passes through a target-region vertex within the linear weld tolerance. Adjust the plane before replay."
            case .childIsNotClosed(let side, let boundaryEdges, let degenerateTriangles):
                return "The cut produced a \(side.rawValue)-side child with \(boundaryEdges) boundary edges and \(degenerateTriangles) degenerate triangles."
            }
        }
    }

    /// Boundary-edge count with every triangle's edges included — degenerate
    /// slivers too, counted by welded-edge parity. `MeshPreflight` skips
    /// degenerate triangles before counting edges, so a benign sub-µm² clip
    /// sliver makes its closed neighborhood read as boundary there. Closure
    /// per R4 is "no open edges", not "no slivers": an edge with odd use
    /// count is a genuine hole; even counts (pairs, welded self-contact)
    /// close.
    static func openEdgeCount(_ triangles: [AttributedTriangle]) -> Int {
        openEdgeCount(triangles.lazy.map { ($0.a, $0.b, $0.c) })
    }

    static func openEdgeCount(_ geometry: MeshGeometryData) -> Int {
        var soup: [(Vec3, Vec3, Vec3)] = []
        soup.reserveCapacity(geometry.triangleIndices.count / 3)
        for indices in stride(from: 0, to: geometry.triangleIndices.count - 2, by: 3) {
            let a = Int(geometry.triangleIndices[indices])
            let b = Int(geometry.triangleIndices[indices + 1])
            let c = Int(geometry.triangleIndices[indices + 2])
            guard a >= 0, b >= 0, c >= 0,
                  a < geometry.vertices.count,
                  b < geometry.vertices.count,
                  c < geometry.vertices.count else { continue }
            soup.append((geometry.vertices[a], geometry.vertices[b], geometry.vertices[c]))
        }
        return openEdgeCount(soup)
    }

    private struct WeldedEdgeKey: Hashable {
        let a: VKey
        let b: VKey
    }

    private static func openEdgeCount<S: Sequence>(
        _ soup: S
    ) -> Int where S.Element == (Vec3, Vec3, Vec3) {
        var counts: [WeldedEdgeKey: Int] = [:]
        for (a, b, c) in soup {
            let keys = [VKey(a), VKey(b), VKey(c)]
            for index in 0..<3 {
                let k0 = keys[index]
                let k1 = keys[(index + 1) % 3]
                guard k0 != k1 else { continue }
                let key = k0 < k1
                    ? WeldedEdgeKey(a: k0, b: k1)
                    : WeldedEdgeKey(a: k1, b: k0)
                counts[key, default: 0] += 1
            }
        }
        return counts.values.filter { $0 % 2 == 1 }.count
    }

    /// New provenance-preserving splitter for Split by Undercuts. Existing
    /// tuple-soup entry points above remain unchanged for Fit Printer.
    static func splitAttributed(
        _ mesh: AttributedMesh,
        plane: CanonicalPlane,
        cutNodeID: PartitionCutNodeID
    ) throws -> AttributedSplit {
        guard mesh.hasCompleteProvenance else {
            throw AttributedSplitError.incompleteProvenance
        }
        guard mesh.hasSupportedCoordinates else {
            throw AttributedSplitError.coordinateOutsideSupportedRange
        }
        let equation = PlaneEq(normal: plane.normal, offset: plane.offset)
        let vertexDistances = mesh.sourceReferencedVertices.map { signed($0, equation) }
        let linearTolerance = UndercutSplitTolerancePolicy.current.linearWeldMM
        let crossesInterior = vertexDistances.contains { $0 < -linearTolerance }
            && vertexDistances.contains { $0 > linearTolerance }
        if crossesInterior,
           vertexDistances.contains(where: { abs($0) <= linearTolerance }) {
            throw AttributedSplitError.vertexGrazing
        }
        let negativeSurface = clipAttributedHalfSpace(
            mesh.triangles,
            plane: equation,
            keepPositive: false
        )
        let positiveSurface = clipAttributedHalfSpace(
            mesh.triangles,
            plane: equation,
            keepPositive: true
        )
        guard !negativeSurface.isEmpty, !positiveSurface.isEmpty else {
            throw AttributedSplitError.planeDoesNotSplit
        }

        func assemble(using loops: [[Vec3]]) throws -> AttributedSplit {
            guard !loops.isEmpty else { throw AttributedSplitError.sectionIsNotClosed }
            let groupedIslands = islands(from: loops, plane: equation)
            guard !groupedIslands.isEmpty else {
                throw AttributedSplitError.sectionIsNotClosed
            }

            var noKeys = PartitionKeySettings.defaultValue
            noKeys.type = .none
            let caps = PartitionKeys.capInterface(
                islands: groupedIslands,
                plane: equation,
                key: noKeys,
                maleSoup: negativeSurface.map { ($0.a, $0.b, $0.c) },
                femaleSoup: positiveSurface.map { ($0.a, $0.b, $0.c) }
            )
            if ProcessInfo.processInfo.environment["UNDERCUT_SPLIT_CAP_DEBUG"] == "1" {
                print(
                    "UNDERCUT_CAP_SHAPE loopSizes=\(loops.map(\.count)) "
                        + "islands=\(groupedIslands.map { ($0.outer.count, $0.holes.map(\.count)) }) "
                        + "capCounts=\(caps.male.count),\(caps.female.count)"
                )
            }
            guard !caps.male.isEmpty, !caps.female.isEmpty else {
                throw AttributedSplitError.capTriangulationFailed
            }

            let negativeCaps = caps.male.map {
                AttributedTriangle(
                    a: $0.0,
                    b: $0.1,
                    c: $0.2,
                    provenance: .cut(nodeID: cutNodeID, side: .negative)
                )
            }
            let positiveCaps = caps.female.map {
                AttributedTriangle(
                    a: $0.0,
                    b: $0.1,
                    c: $0.2,
                    provenance: .cut(nodeID: cutNodeID, side: .positive)
                )
            }
            let negative = AttributedMesh(
                triangles: negativeSurface + negativeCaps,
                sourceGeometryFingerprint: mesh.sourceGeometryFingerprint,
                sourceReferencedVertices: mesh.sourceReferencedVertices.filter {
                    signed($0, equation) <= linearTolerance
                },
                omittedDegenerateSourceFaceIDs: mesh.omittedDegenerateSourceFaceIDs
            )
            let positive = AttributedMesh(
                triangles: positiveSurface + positiveCaps,
                sourceGeometryFingerprint: mesh.sourceGeometryFingerprint,
                sourceReferencedVertices: mesh.sourceReferencedVertices.filter {
                    signed($0, equation) >= -linearTolerance
                },
                omittedDegenerateSourceFaceIDs: mesh.omittedDegenerateSourceFaceIDs
            )
            for (side, child) in [(PartitionCutSide.negative, negative), (.positive, positive)] {
                let preflight = MeshPreflight.analyze(geometry: child.geometry)
                // Closure by welded-edge parity including degenerate slivers
                // (R4: closed = no open edges, not sliver-free — see
                // `openEdgeCount`). Preflight facts still describe honestly.
                let openEdges = openEdgeCount(child.triangles)
                if preflight.invalidTriangleReferenceCount != 0 || openEdges != 0 {
                    if ProcessInfo.processInfo.environment["UNDERCUT_SPLIT_CAP_DEBUG"] == "1" {
                        print(
                            "UNDERCUT_CAP_DEBUG side=\(side.rawValue) "
                                + "plane=(\(plane.normal.x),\(plane.normal.y),\(plane.normal.z),\(plane.offset)) "
                                + "loops=\(loops.count) "
                                + cutFailureFacts(child, plane: equation)
                        )
                    }
                    throw AttributedSplitError.childIsNotClosed(
                        side: side,
                        boundaryEdges: openEdges,
                        degenerateTriangles: preflight.degenerateTriangleCount
                    )
                }
            }
            return AttributedSplit(negative: negative, positive: positive)
        }

        let sourceSoup = mesh.triangles.map { ($0.a, $0.b, $0.c) }
        let ordinaryLoops = sectionLoops(sourceSoup, plane: equation)
        do {
            return try assemble(using: ordinaryLoops)
        } catch let ordinaryError {
            // A healed scan may be boundary-closed while two sheets touch at a
            // welded vertex. `sectionLoops` intentionally follows the first
            // unused segment, which is ambiguous at that valence-four contact
            // and can join the wrong contours. Reconstruct only the generated
            // planar cut boundary, pairing its branches by straightest
            // continuation. Source-derived triangles remain byte-for-byte
            // unchanged; only the failed cut cap is replaced.
            let fallbackLoops = cutBoundaryLoops(
                from: negativeSurface,
                plane: equation
            )
            guard !fallbackLoops.isEmpty else { throw ordinaryError }
            return try assemble(using: fallbackLoops)
        }
    }

    /// Clips only the existing surface. Every generated fragment retains its
    /// input triangle provenance; the caller adds newly attributed cut caps.
    static func clipAttributedHalfSpace(
        _ triangles: [AttributedTriangle],
        plane: PlaneEq,
        keepPositive: Bool
    ) -> [AttributedTriangle] {
        var output: [AttributedTriangle] = []
        output.reserveCapacity(triangles.count)
        for triangle in triangles {
            let vertices = [triangle.a, triangle.b, triangle.c]
            let distances = vertices.map { signed($0, plane) }
            let membership = distances.map { keepPositive ? $0 >= 0 : $0 <= 0 }
            if membership.allSatisfy({ $0 }) {
                output.append(triangle)
                continue
            }
            if membership.allSatisfy({ !$0 }) { continue }

            var polygon: [Vec3] = []
            for index in 0..<3 {
                let previousIndex = (index + 2) % 3
                let currentInside = membership[index]
                let previousInside = membership[previousIndex]
                if currentInside {
                    if !previousInside {
                        polygon.append(
                            crossing(
                                vertices[previousIndex], distances[previousIndex],
                                vertices[index], distances[index]
                            )
                        )
                    }
                    polygon.append(vertices[index])
                } else if previousInside {
                    polygon.append(
                        crossing(
                            vertices[previousIndex], distances[previousIndex],
                            vertices[index], distances[index]
                        )
                    )
                }
            }
            guard polygon.count >= 3 else { continue }
            for index in 1..<(polygon.count - 1) {
                output.append(
                    AttributedTriangle(
                        a: polygon[0],
                        b: polygon[index],
                        c: polygon[index + 1],
                        provenance: triangle.provenance
                    )
                )
            }
        }
        return output
    }

    /// Recover the cut contours directly from a clipped surface. Since
    /// `splitAttributed` rejects vertex-grazing planes, every surface edge with
    /// both endpoints on the plane was authored by clipping and belongs to the
    /// cap boundary. A closed source yields an even-degree planar multigraph.
    /// At benign self-contact vertices the degree can exceed two; pairing the
    /// incident segments by straightest continuation deterministically keeps
    /// touching contours separate without moving source geometry.
    private static func cutBoundaryLoops(
        from surface: [AttributedTriangle],
        plane: PlaneEq
    ) -> [[Vec3]] {
        struct Segment {
            var a: VKey
            var b: VKey
        }

        let onPlaneTolerance = UndercutSplitTolerancePolicy.current.linearWeldMM * 4
        var points: [VKey: Vec3] = [:]
        var segments: [Segment] = []
        segments.reserveCapacity(surface.count / 4)

        func append(_ a: Vec3, _ b: Vec3) {
            guard abs(signed(a, plane)) <= onPlaneTolerance,
                  abs(signed(b, plane)) <= onPlaneTolerance else { return }
            let ka = VKey(a)
            let kb = VKey(b)
            guard ka != kb, distance(a, b) > 1.0e-9 else { return }
            if points[ka] == nil { points[ka] = a }
            if points[kb] == nil { points[kb] = b }
            segments.append(Segment(a: ka, b: kb))
        }

        for triangle in surface {
            append(triangle.a, triangle.b)
            append(triangle.b, triangle.c)
            append(triangle.c, triangle.a)
        }
        guard !segments.isEmpty else { return [] }

        segments.sort {
            let lhsLow = min($0.a, $0.b)
            let rhsLow = min($1.a, $1.b)
            if lhsLow != rhsLow { return lhsLow < rhsLow }
            let lhsHigh = max($0.a, $0.b)
            let rhsHigh = max($1.a, $1.b)
            if lhsHigh != rhsHigh { return lhsHigh < rhsHigh }
            if $0.a != $1.a { return $0.a < $1.a }
            return $0.b < $1.b
        }

        var adjacency: [VKey: [Int]] = [:]
        for index in segments.indices {
            adjacency[segments[index].a, default: []].append(index)
            adjacency[segments[index].b, default: []].append(index)
        }
        for key in adjacency.keys {
            adjacency[key]?.sort()
        }

        func otherEndpoint(_ segment: Segment, from key: VKey) -> VKey? {
            if segment.a == key { return segment.b }
            if segment.b == key { return segment.a }
            return nil
        }

        func continuationScore(previous: VKey, current: VKey, next: VKey) -> Double {
            guard let p = points[previous], let c = points[current], let n = points[next] else {
                return -.greatestFiniteMagnitude
            }
            let incoming = normalized(subtract(c, p))
            let outgoing = normalized(subtract(n, c))
            return dot(incoming, outgoing)
        }

        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Vec3]] = []
        for startIndex in segments.indices where !used[startIndex] {
            let startSegment = segments[startIndex]
            let start = min(startSegment.a, startSegment.b)
            guard let first = otherEndpoint(startSegment, from: start) else { continue }
            used[startIndex] = true
            var loopKeys = [start]
            var previous = start
            var current = first
            var closed = false

            while loopKeys.count <= segments.count {
                if current == start {
                    closed = true
                    break
                }
                loopKeys.append(current)
                let candidates = (adjacency[current] ?? []).compactMap { index -> (Int, VKey)? in
                    guard !used[index],
                          let next = otherEndpoint(segments[index], from: current) else { return nil }
                    return (index, next)
                }
                guard !candidates.isEmpty else { break }

                let viable = candidates.filter { candidate in
                    !(candidate.1 == start && loopKeys.count < 3 && candidates.count > 1)
                }
                let pool = viable.isEmpty ? candidates : viable
                let selected = pool.sorted { lhs, rhs in
                    let leftScore = continuationScore(
                        previous: previous,
                        current: current,
                        next: lhs.1
                    )
                    let rightScore = continuationScore(
                        previous: previous,
                        current: current,
                        next: rhs.1
                    )
                    if leftScore != rightScore { return leftScore > rightScore }
                    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                    return lhs.0 < rhs.0
                }[0]
                used[selected.0] = true
                previous = current
                current = selected.1
            }

            if closed, loopKeys.count >= 3 {
                let loop = loopKeys.compactMap { points[$0] }
                if loop.count == loopKeys.count { loops.append(loop) }
            }
        }
        return loops
    }

    private static func cutFailureFacts(
        _ mesh: AttributedMesh,
        plane: PlaneEq
    ) -> String {
        struct Edge: Hashable {
            var a: VKey
            var b: VKey

            init(_ lhs: VKey, _ rhs: VKey) {
                if lhs < rhs { a = lhs; b = rhs } else { a = rhs; b = lhs }
            }
        }
        var edgeCounts: [Edge: Int] = [:]
        var edgePoints: [VKey: Vec3] = [:]
        var degenerateSource = 0
        var degenerateCut = 0
        for triangle in mesh.triangles {
            let ab = subtract(triangle.b, triangle.a)
            let ac = subtract(triangle.c, triangle.a)
            let normal = cross(ab, ac)
            if dot(normal, normal) <= 1.0e-10 {
                switch triangle.provenance {
                case .source: degenerateSource += 1
                case .cut, .joinery: degenerateCut += 1
                }
                continue
            }
            for (a, b) in [
                (triangle.a, triangle.b),
                (triangle.b, triangle.c),
                (triangle.c, triangle.a),
            ] {
                let ka = VKey(a)
                let kb = VKey(b)
                edgePoints[ka] = edgePoints[ka] ?? a
                edgePoints[kb] = edgePoints[kb] ?? b
                edgeCounts[Edge(ka, kb), default: 0] += 1
            }
        }
        let boundary = edgeCounts.filter { $0.value == 1 }.map(\.key)
        let maximumOffPlane = boundary.reduce(0.0) { current, edge in
            let distances = [edgePoints[edge.a], edgePoints[edge.b]].compactMap { $0 }.map {
                abs(signed($0, plane))
            }
            return max(current, distances.max() ?? 0)
        }
        var degree: [VKey: Int] = [:]
        for edge in boundary {
            degree[edge.a, default: 0] += 1
            degree[edge.b, default: 0] += 1
        }
        let degrees = Dictionary(grouping: degree.values, by: { $0 }).mapValues(\.count)
        return "boundary=\(boundary.count) maxBoundaryOffPlane=\(maximumOffPlane) "
            + "degreeHistogram=\(degrees) degenerateSource=\(degenerateSource) "
            + "degenerateCut=\(degenerateCut)"
    }
}
