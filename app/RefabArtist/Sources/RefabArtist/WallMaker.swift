import Foundation
import simd

/// Make walls: thicken an open skin (a vessel, a tube) INWARD into a walled
/// shell whose outside is the original surface, untouched, and whose
/// openings stay open — the owner's "make it a cup".
///
/// Construction (PRD `docs/prd-model-repair.md`, "Make walls construction"):
///  1. V = the skin with every opening capped flat (`OpeningCapper.close`,
///     topHeight 0). Pinholes stay filled; they are part of the skin.
///  2. Inner solid I = { f > 0 },
///       f(x) = min( s_V(x) + 2h,  d_S(x) − t )
///     where s_V is the signed distance to V (inside positive; sign from the
///     winding number of V, which is closed so the winding is ~0/1), d_S is
///     the unsigned distance to the SKIN only (the caps of the openings that
///     stay open excluded; an opening the user set to Closed keeps its cap in
///     the skin, which makes it a floor / lid of thickness t) and
///     h is the lattice pitch. `d_S − t > 0` keeps I a wall-thickness `t`
///     inside the skin; the `+2h` lets I poke 2h through the temporary cap,
///     so `V − I` re-opens the rim instead of leaving a film over it (without
///     it the difference leaves ~2,000 film fragments over the opening).
///  3. W = V − I with Manifold, V imported through the 64-bit path so every
///     skin triangle the boolean does not cut keeps bit-identical corners.
///
/// The field is sampled on Manifold's own level-set lattice in parallel
/// (`PrefilledField`), with narrow-band distances.
enum WallMaker {

    enum WallError: Error, Equatable {
        case badThickness
        /// The surface has no opening to leave open (already a closed solid,
        /// or only pinholes) — Hollow is the tool for a closed solid.
        case noOpenings
        /// Close openings could not cap it (and says why).
        case cannotCap(String)
        /// The wall is at least as thick as the model: nothing to hollow.
        case wallTooThick
        /// Every opening is set to Closed: that is a sealed hollow, not a
        /// vessel (Hollow is the tool for it).
        case allOpeningsClosed
        case engine(String)

        var userMessage: String {
            switch self {
            case .badThickness: return "Can't make walls: the wall thickness must be more than 0 mm."
            case .noOpenings: return "Can't make walls: this surface has no opening to keep open (it is already closed). Use Hollow for a closed solid."
            case .cannotCap(let why): return "Can't make walls: \(why)"
            case .wallTooThick: return "Can't make walls: the wall is as thick as the model itself — it would come out solid. Try a thinner wall."
            case .allOpeningsClosed: return "Can't make walls: every opening is set to Closed, which would seal the model into a hollow shell. Leave at least one opening open, or use Hollow for a sealed shell."
            case .engine(let why): return "Can't make walls: \(why)"
            }
        }
    }

    struct Result {
        var geometry: MeshGeometryData
        /// Manifold's verdict on the returned geometry.
        var manifoldValidated: Bool
        var components: Int
        var thickness: Double
        /// Lattice pitch actually used (≈ thickness / 2, coarsened only to
        /// stay under the sample budget).
        var latticePitch: Double
        var samples: Int
        var latticeMisses: Int
        /// Original skin triangles present in the output with bit-identical
        /// corner positions, over the input triangle count.
        var untouchedFraction: Double
        /// New (inner-wall) vertices whose distance to the skin is within
        /// [0.9 t, 1.3 t], and those closer than 0.9 t (thin places in the
        /// skin, e.g. leaf tips, where the wall cannot be full thickness).
        var innerWithinBandFraction: Double
        var innerThinnerFraction: Double
        var innerVertexCount: Int
        /// Output triangles that still lie on a temporary cap farther than
        /// 1.3 t from the skin (0 = the openings are open).
        var capInteriorTriangles: Int
        var openingsKeptOpen: Int
        /// Openings closed by the user's choice: which (1-based, diagnosis
        /// order), where, and the floor / lid thickness measured on the
        /// result straight through the middle of the closed opening (nil when
        /// the measuring ray found no inner wall).
        var closedOpenings: [ClosedOpening] = []
        /// Saved per-opening choices that matched no opening (dropped).
        var droppedChoices = 0
        var pinholesFilled: Int
        var trianglesRemoved: Int
        var elapsed: TimeInterval

        struct ClosedOpening: Equatable {
            var number: Int
            var placement: String
            var measuredThickness: Double?

            /// "floor" at the bottom, "lid" at the top, else "cap".
            var partName: String {
                if placement == "bottom" { return "floor" }
                if placement == "top" { return "lid" }
                return "cap"
            }
        }

        var receipt: String {
            var text: String
            if closedOpenings.isEmpty {
                text = openingsKeptOpen == 1
                    ? String(format: "Made %.1f mm walls inside the surface; the opening stays open", thickness)
                    : String(format: "Made %.1f mm walls inside the surface; all %d openings stay open", thickness, openingsKeptOpen)
            } else {
                text = String(format: "Made %.1f mm walls inside the surface; ", thickness)
                text += openingsKeptOpen == 1 ? "1 opening stays open" : "\(openingsKeptOpen) openings stay open"
                for c in closedOpenings {
                    let measured = c.measuredThickness.map { String(format: "%.1f mm", $0) } ?? String(format: "%.1f mm", thickness)
                    text += ", opening \(c.number) closed with a \(measured) \(c.partName)"
                }
            }
            if pinholesFilled > 0 { text += pinholesFilled == 1 ? ", 1 pinhole filled" : ", \(pinholesFilled) pinholes filled" }
            if trianglesRemoved > 0 { text += ", \(trianglesRemoved) broken triangles removed" }
            text += "."
            text += String(format: " %.1f%% of your outside surface is untouched.", untouchedFraction * 100)
            if innerThinnerFraction > 0.005 {
                text += String(format: " %.1f%% of the inner wall is thinner than requested where the surface itself is thinner than two walls.", innerThinnerFraction * 100)
            }
            if components > 1 { text += " Note: the result is \(components) separate pieces." }
            if capInteriorTriangles > 0 { text += " Note: \(capInteriorTriangles) triangles of the temporary cap remain." }
            if !manifoldValidated { text += " Warning: the result did not validate as a closed solid." }
            if droppedChoices > 0 {
                text += droppedChoices == 1
                    ? " 1 saved opening choice no longer matches any opening (the model changed) and was dropped."
                    : " \(droppedChoices) saved opening choices no longer match any opening (the model changed) and were dropped."
            }
            return text
        }
    }

    /// Hard cap on lattice samples (both sub-lattices); the pitch is
    /// coarsened past thickness/2 only to stay under it.
    static let maxSamples = 4_000_000

    /// `choices`: per-opening Open / Closed (`OpeningChoice.closedInWalls`),
    /// matched by signature; unmatched choices are dropped and reported.
    /// A closed opening keeps its flat cap as part of the skin, so the inner
    /// solid stays `t` away from it: a floor / lid of the wall thickness.
    static func make(_ geometry: MeshGeometryData, thickness t: Double,
                     choices: [OpeningCapper.OpeningChoice] = []) throws -> Result {
        let started = Date()
        let trace = ProcessInfo.processInfo.environment["REFAB_HEAL_TRACE"] == "1"
        func phase(_ name: String) {
            if trace { FileHandle.standardError.write(Data(String(format: "walls %@ @ %.2fs\n", name, Date().timeIntervalSince(started)).utf8)) }
        }
        guard t.isFinite, t > 0 else { throw WallError.badThickness }

        // 1. V: flat caps on every opening.
        let capped: OpeningCapper.Result
        do {
            capped = try OpeningCapper.close(geometry, topHeight: 0)
        } catch OpeningCapper.CapError.needsRebuild(let why) {
            throw WallError.cannotCap(why)
        } catch OpeningCapper.CapError.nothingToClose {
            throw WallError.noOpenings
        } catch {
            throw WallError.cannotCap("there is no surface to work on.")
        }
        guard !capped.openingCapTriangleRanges.isEmpty else { throw WallError.noOpenings }
        let V = capped.geometry
        phase("cap")

        // Closed openings: their caps join the skin S (the wall distance is
        // measured to them too); only the open ones' caps are temporary.
        let (byOpening, unmatched) = OpeningCapper.matchChoices(choices, to: capped.openings)
        let closedIndices = byOpening.indices.filter { byOpening[$0]?.closedInWalls == true }
        let openRanges = capped.openingCapRangeByOpening.filter { !closedIndices.contains($0.key) }.map(\.value)
        guard !openRanges.isEmpty else { throw WallError.allOpeningsClosed }
        var isCap = [Bool](repeating: false, count: V.triangleIndices.count / 3)
        for r in openRanges { for i in r { isCap[i] = true } }
        func sub(_ keep: (Int) -> Bool) -> MeshGeometryData {
            var idx: [Int32] = []
            for f in 0..<isCap.count where keep(f) {
                idx.append(V.triangleIndices[3 * f]); idx.append(V.triangleIndices[3 * f + 1]); idx.append(V.triangleIndices[3 * f + 2])
            }
            return MeshGeometryData(vertices: V.vertices, triangleIndices: idx)
        }
        let skinSoup = TriangleSoup(sub { !isCap[$0] })
        let capSoup = TriangleSoup(sub { isCap[$0] })
        let solidSoup = TriangleSoup(V)
        let vb = solidSoup.bounds
        let span = Vec3(x: vb.max.x - vb.min.x, y: vb.max.y - vb.min.y, z: vb.max.z - vb.min.z)
        let diag = (span.x * span.x + span.y * span.y + span.z * span.z).squareRoot()
        guard t < 0.5 * min(span.x, min(span.y, span.z)) else { throw WallError.wallTooThick }

        // 2. Lattice pitch ≈ t/2, coarsened to the sample budget.
        var h = t / 2
        func lattice(_ h: Double) -> LevelSetLattice {
            let pad = 5 * h
            return LevelSetLattice(
                lo: Vec3(x: vb.min.x - pad, y: vb.min.y - pad, z: vb.min.z - pad),
                hi: Vec3(x: vb.max.x + pad, y: vb.max.y + pad, z: vb.max.z + pad),
                edgeLength: h)
        }
        var L = lattice(h)
        while L.sampleCount > maxSamples {
            h *= pow(Double(L.sampleCount) / Double(maxSamples), 1.0 / 3.0) * 1.01
            L = lattice(h)
        }

        let cell = max(2 * h, diag / 128)
        let skinGrid = TriangleGrid(skinSoup, targetCell: cell)
        let capGrid = TriangleGrid(capSoup, targetCell: cell)
        let winding = FastWindingTree(solidSoup)
        let band = t + 4 * h
        phase("grids")
        let far = 2 * max(L.spacing.x, max(L.spacing.y, L.spacing.z))
        let overshoot = 2 * h
        // Exact field (used only for any Manifold query off the lattice).
        let exactField: @Sendable (Vec3) -> Double = { p in
            let dS = skinGrid.nearestDistance(to: p)
            let dV = min(dS, capGrid.nearestDistance(to: p))
            let sV = winding.windingNumber(at: p) > 0.5 ? dV : -dV
            return min(sV + overshoot, dS - t)
        }

        // Pass 1 (parallel): narrow-band distances to the skin and the caps.
        let dist = L.sampleAll(initial: SIMD2<Double>(0, 0)) { _, _, p in
            SIMD2(skinGrid.nearestDistance(to: p, maxDistance: band),
                  capGrid.nearestDistance(to: p, maxDistance: band))
        }
        // Pass 2: inside/outside of V for samples at least `band` from V's
        // surface is constant along lattice edges between them (an edge is
        // shorter than the band, so it cannot cross the surface): flood-fill
        // those "far" samples into connected regions and evaluate the winding
        // number once per region instead of once per sample.
        phase("dist")
        let region = farRegions(L, far: dist.map { min($0.x, $0.y) >= band })
        let regionInside: [Bool] = {
            var out = [Bool](repeating: false, count: region.representatives.count)
            let reps = region.representatives
            out.withUnsafeMutableBufferPointer { buf in
                let ptr = SendablePointer(buf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: reps.count) { r in
                    ptr.base[r] = winding.windingNumber(at: L.position(combined: reps[r])) > 0.5
                }
            }
            return out
        }()
        phase("regions")
        // Pass 3 (parallel): the field.
        let values = L.sampleAll(initial: 0.0) { _, n, p in
            let dS = dist[n].x
            let wallTerm = dS - t
            // Deep inside the wall band f ≤ wallTerm < −2 pitch: this sample
            // cannot sit on a sign change, so its sign is all that matters.
            if wallTerm < -far { return wallTerm }
            let dV = min(dS, dist[n].y)
            let r = region.label[n]
            let inside = r >= 0 ? regionInside[Int(r)] : winding.windingNumber(at: p) > 0.5
            return min((inside ? dV : -dV) + overshoot, wallTerm)
        }
        let table = PrefilledField(lattice: L, values: values, fallback: exactField)
        phase("field")
        let inner: ManifoldHandle
        do {
            inner = try table.levelSet(level: 0)
        } catch let e as ManifoldEngineError {
            throw WallError.engine(e.userMessage)
        }
        if ManifoldEngine.isEmpty(inner) { throw WallError.wallTooThick }

        phase("levelset")
        // 3. W = V − I (64-bit V so the untouched skin stays bit-identical).
        let walled: ManifoldHandle
        let out: MeshGeometryData
        let parts: Int
        do {
            let solid = try ManifoldEngine.make64(from: V)
            let simplifiedInner = (try? ManifoldEngine.simplify(inner, tolerance: 0.05 * h)).flatMap {
                ManifoldEngine.isWatertight($0) ? $0 : nil
            } ?? inner
            walled = try ManifoldEngine.difference(solid, simplifiedInner)
            guard !ManifoldEngine.isEmpty(walled) else { throw ManifoldEngineError.emptyResult }
            out = try ManifoldEngine.toMesh(walled)
            parts = try ManifoldEngine.decompose(walled).count
        } catch let e as ManifoldEngineError {
            throw WallError.engine(e.userMessage)
        }

        phase("difference")
        // Measurements on the geometry actually returned.
        let untouched = untouchedFraction(original: geometry, output: out)
        var vSet = Set<Vec3>(); vSet.reserveCapacity(V.vertices.count)
        for v in V.vertices { vSet.insert(v) }
        var inner0 = 0, within = 0, thinner = 0
        for v in out.vertices where !vSet.contains(v) {
            inner0 += 1
            let d = skinGrid.nearestDistance(to: v)
            if d >= 0.9 * t && d <= 1.3 * t { within += 1 } else if d < 0.9 * t { thinner += 1 }
        }
        var capLeft = 0
        let eps = 1.0e-6 * diag
        var f = 0
        while f + 2 < out.triangleIndices.count {
            let a = out.vertices[Int(out.triangleIndices[f])]
            let b = out.vertices[Int(out.triangleIndices[f + 1])]
            let c = out.vertices[Int(out.triangleIndices[f + 2])]
            let g = Vec3(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3, z: (a.z + b.z + c.z) / 3)
            if capGrid.nearestDistance(to: g, maxDistance: 10 * eps) <= eps,
               skinGrid.nearestDistance(to: g, maxDistance: 2 * t) > 1.3 * t {
                capLeft += 1
            }
            f += 3
        }

        // Floor / lid thickness of each closed opening, measured on the
        // result along the opening's inward normal through its centre.
        let closedOpenings: [Result.ClosedOpening] = closedIndices.map { o in
            let opening = capped.openings[o]
            return Result.ClosedOpening(
                number: o + 1, placement: opening.placement,
                measuredThickness: wallThickness(out, at: opening.center, outward: opening.normal))
        }

        phase("measure")
        return Result(
            geometry: out,
            manifoldValidated: ManifoldEngine.isWatertight(walled),
            components: parts,
            thickness: t,
            latticePitch: h,
            samples: L.sampleCount,
            latticeMisses: table.misses,
            untouchedFraction: untouched,
            innerWithinBandFraction: inner0 > 0 ? Double(within) / Double(inner0) : 0,
            innerThinnerFraction: inner0 > 0 ? Double(thinner) / Double(inner0) : 0,
            innerVertexCount: inner0,
            capInteriorTriangles: capLeft,
            openingsKeptOpen: openRanges.count,
            closedOpenings: closedOpenings,
            droppedChoices: unmatched.count,
            pinholesFilled: capped.pinholesFilled,
            trianglesRemoved: capped.trianglesRemoved,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// Thickness of the solid `mesh` straight through `center` along
    /// −`outward`: the gap between the surface crossing nearest `center` and
    /// the next crossing inward. nil when there is no such pair.
    static func wallThickness(_ mesh: MeshGeometryData, at center: Vec3, outward: Vec3) -> Double? {
        let o = SIMD3(center.x, center.y, center.z)
        var d = -SIMD3(outward.x, outward.y, outward.z)
        guard simd_length_squared(d) > 0 else { return nil }
        d = simd_normalize(d)
        var hits: [Double] = []
        let idx = mesh.triangleIndices
        let v = mesh.vertices.map { SIMD3($0.x, $0.y, $0.z) }
        var f = 0
        while f + 2 < idx.count {
            let a = v[Int(idx[f])], b = v[Int(idx[f + 1])], c = v[Int(idx[f + 2])]
            f += 3
            // Möller–Trumbore, both sides, along the whole line.
            let e1 = b - a, e2 = c - a
            let p = simd_cross(d, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1.0e-18 { continue }
            let inv = 1 / det
            let s = o - a
            let u = simd_dot(s, p) * inv
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let w = simd_dot(d, q) * inv
            if w < 0 || u + w > 1 { continue }
            hits.append(simd_dot(e2, q) * inv)
        }
        guard let first = hits.min(by: { abs($0) < abs($1) }) else { return nil }
        let eps = 1.0e-9 * max(1, abs(first))
        guard let next = hits.filter({ $0 > first + eps }).min() else { return nil }
        return next - first
    }

    /// Connected regions of "far" samples (6-neighbour corners plus the
    /// corner–centre diagonals, the level-set lattice's own adjacency).
    /// `label[n]` is the region of sample `n` (−1 when not far);
    /// `representatives[r]` is one sample of region `r`.
    static func farRegions(_ L: LevelSetLattice, far: [Bool]) -> (label: [Int32], representatives: [Int]) {
        let n = L.sampleCount
        var parent = [Int32](repeating: -1, count: n)
        for i in 0..<n where far[i] { parent[i] = Int32(i) }
        func find(_ x: Int) -> Int {
            var r = x
            while Int(parent[r]) != r { r = Int(parent[r]) }
            var y = x
            while Int(parent[y]) != r { let next = Int(parent[y]); parent[y] = Int32(r); y = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = Int32(min(ra, rb)) }
        }
        let nc = L.cornerCount
        for k in 0..<L.gz { for j in 0..<L.gy { for i in 0..<L.gx {
            let a = L.cornerIndex(i, j, k)
            guard far[a] else { continue }
            if i + 1 < L.gx, far[L.cornerIndex(i + 1, j, k)] { union(a, L.cornerIndex(i + 1, j, k)) }
            if j + 1 < L.gy, far[L.cornerIndex(i, j + 1, k)] { union(a, L.cornerIndex(i, j + 1, k)) }
            if k + 1 < L.gz, far[L.cornerIndex(i, j, k + 1)] { union(a, L.cornerIndex(i, j, k + 1)) }
            for dk in 0...1 { for dj in 0...1 { for di in 0...1 {
                let c = nc + L.centreIndex(i + di, j + dj, k + dk)
                if far[c] { union(a, c) }
            } } }
        } } }
        var label = [Int32](repeating: -1, count: n)
        var reps: [Int] = []
        var regionOfRoot = [Int32](repeating: -1, count: n)
        for i in 0..<n where far[i] {
            let r = find(i)
            if regionOfRoot[r] < 0 {
                regionOfRoot[r] = Int32(reps.count)
                reps.append(i)
            }
            label[i] = regionOfRoot[r]
        }
        return (label, reps)
    }

    /// Fraction of `original`'s triangles found in `output` with the same
    /// three corner positions, bit for bit (either orientation).
    static func untouchedFraction(original: MeshGeometryData, output: MeshGeometryData) -> Double {
        struct Key: Hashable { var a: Vec3; var b: Vec3; var c: Vec3 }
        func key(_ p: Vec3, _ q: Vec3, _ r: Vec3) -> Key {
            var s = [p, q, r]
            s.sort { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
            return Key(a: s[0], b: s[1], c: s[2])
        }
        var have = Set<Key>()
        var i = 0
        let o = output.triangleIndices
        while i + 2 < o.count {
            have.insert(key(output.vertices[Int(o[i])], output.vertices[Int(o[i + 1])], output.vertices[Int(o[i + 2])]))
            i += 3
        }
        let n = original.triangleIndices.count / 3
        guard n > 0 else { return 0 }
        var hit = 0
        let s = original.triangleIndices
        let vs = original.vertices
        for t in 0..<n {
            let a = Int(s[3 * t]), b = Int(s[3 * t + 1]), c = Int(s[3 * t + 2])
            guard vs.indices.contains(a), vs.indices.contains(b), vs.indices.contains(c) else { continue }
            if have.contains(key(vs[a], vs[b], vs[c])) { hit += 1 }
        }
        return Double(hit) / Double(n)
    }
}
