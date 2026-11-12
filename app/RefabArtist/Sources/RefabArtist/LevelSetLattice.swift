import Foundation
import Synchronization

/// The exact sample lattice Manifold v3.5.1's `level_set` evaluates, so a
/// signed field can be computed IN PARALLEL in Swift ahead of time and handed
/// to Manifold as a table lookup.
///
/// Why: the vendored Manifold is built with `MANIFOLD_PAR=OFF`, so
/// `level_set` calls the field once per sample on ONE core. Prefilling the
/// lattice with `concurrentPerform` spreads that work over every core; the
/// values are the same doubles the direct call would return, so the extracted
/// surface is identical.
///
/// Lattice (from Manifold v3.5.1 `src/sdf.cpp`, `CreateLevelSet`,
/// `Position`, `BoundedSDF`; re-derived, not copied):
///   - `dim = hi - lo`, `gridSize = Int(dim / edge + 1)` per axis (truncated),
///     `spacing = dim / (gridSize - 1)`, origin = `lo`.
///   - Two interleaved sub-lattices (body-centred cubic):
///       "corner" points at `origin + spacing * i`,          i in 0 ..< gridSize
///       "centre" points at `origin + spacing * (i - 0.5)`,  i in 0 ... gridSize
///   - Samples on the outermost layer are clamped to `min(value, 0)` by
///     Manifold itself (we store the raw field value).
///   - With the default tolerance (≤ 0 → infinite) Manifold never samples the
///     field anywhere else (its root finder does zero refinement steps), so
///     every callback is a lattice hit. Misses fall back to direct evaluation
///     and are counted, so a lattice mismatch can never change the output —
///     only cost time — and shows up in `misses`.
struct LevelSetLattice: Sendable {
    let origin: Vec3
    let spacing: Vec3
    let gx: Int, gy: Int, gz: Int
    /// The box and edge Manifold is called with (kept so the lattice and
    /// the call can never disagree).
    let lo: Vec3, hi: Vec3, edgeLength: Double

    init(lo: Vec3, hi: Vec3, edgeLength: Double) {
        self.lo = lo; self.hi = hi; self.edgeLength = edgeLength
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        gx = Int(dx / edgeLength + 1.0)
        gy = Int(dy / edgeLength + 1.0)
        gz = Int(dz / edgeLength + 1.0)
        origin = lo
        spacing = Vec3(x: dx / Double(gx - 1), y: dy / Double(gy - 1), z: dz / Double(gz - 1))
    }

    /// Samples Manifold evaluates (both sub-lattices).
    var sampleCount: Int { gx * gy * gz + (gx + 1) * (gy + 1) * (gz + 1) }
    var cornerCount: Int { gx * gy * gz }

    /// Evaluate `f(isCorner, combinedIndex, position)` at every sample in
    /// parallel (z-slabs). Combined order: corners (`cornerIndex`), then
    /// centres (`cornerCount + centreIndex`).
    func sampleAll<T>(initial: T, _ f: @Sendable (Bool, Int, Vec3) -> T) -> [T] {
        var out = [T](repeating: initial, count: sampleCount)
        let L = self
        let nc = cornerCount
        out.withUnsafeMutableBufferPointer { buf in
            let ptr = SendablePointer(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: L.gz + L.gz + 1) { s in
                if s < L.gz {
                    let k = s
                    for j in 0..<L.gy { for i in 0..<L.gx {
                        let n = L.cornerIndex(i, j, k)
                        ptr.base[n] = f(true, n, L.position(corner: true, i, j, k))
                    } }
                } else {
                    let k = s - L.gz
                    for j in 0...L.gy { for i in 0...L.gx {
                        let n = nc + L.centreIndex(i, j, k)
                        ptr.base[n] = f(false, n, L.position(corner: false, i, j, k))
                    } }
                }
            }
        }
        return out
    }

    /// Same arithmetic, same order, as Manifold's `Position()`.
    @inline(__always) func position(corner: Bool, _ i: Int, _ j: Int, _ k: Int) -> Vec3 {
        let off = corner ? 0.0 : -0.5
        return Vec3(x: origin.x + spacing.x * (Double(i) + off),
                    y: origin.y + spacing.y * (Double(j) + off),
                    z: origin.z + spacing.z * (Double(k) + off))
    }

    /// Position of a sample given its combined index (see `sampleAll`).
    func position(combined n: Int) -> Vec3 {
        if n < cornerCount {
            let i = n % gx, j = (n / gx) % gy, k = n / (gx * gy)
            return position(corner: true, i, j, k)
        }
        let m = n - cornerCount
        let i = m % (gx + 1), j = (m / (gx + 1)) % (gy + 1), k = m / ((gx + 1) * (gy + 1))
        return position(corner: false, i, j, k)
    }

    @inline(__always) func cornerIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * gy + j) * gx + i }
    @inline(__always) func centreIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * (gy + 1) + j) * (gx + 1) + i }

    /// Grid distance to the lattice boundary as Manifold's `BoundedSDF`
    /// computes it; 0 = outermost layer (value clamped to ≤ 0), < 0 = never
    /// sampled (treated as 0).
    @inline(__always) func boundDistance(corner: Bool, _ i: Int, _ j: Int, _ k: Int) -> Int {
        let lower = Swift.min(i, Swift.min(j, k))
        let upper = Swift.min(gx - i, Swift.min(gy - j, gz - k))
        return Swift.min(lower, upper - (corner ? 1 : 0))
    }
}

/// A field sampled on every point of a `LevelSetLattice`.
final class PrefilledField: @unchecked Sendable {
    let lattice: LevelSetLattice
    /// Raw field values; written only during `init` / `refine` (single
    /// writer per slot), read-only afterwards.
    private(set) var corner: [Double]
    private(set) var centre: [Double]
    private let hitCounter = Atomic<Int>(0)
    private let missCounter = Atomic<Int>(0)
    let fallback: @Sendable (Vec3) -> Double

    var hits: Int { hitCounter.load(ordering: .relaxed) }
    var misses: Int { missCounter.load(ordering: .relaxed) }

    /// Evaluate `field` on every lattice point, in parallel over z-slabs.
    /// `fallback` answers any query that is not a lattice point (it must be
    /// the same field; usually the exact, unclamped version).
    init(lattice: LevelSetLattice,
         field: @Sendable (Vec3) -> Double,
         fallback: @escaping @Sendable (Vec3) -> Double) {
        self.lattice = lattice
        self.fallback = fallback
        corner = [Double](repeating: 0, count: lattice.gx * lattice.gy * lattice.gz)
        centre = [Double](repeating: 0, count: (lattice.gx + 1) * (lattice.gy + 1) * (lattice.gz + 1))
        let L = lattice
        corner.withUnsafeMutableBufferPointer { cbuf in
            centre.withUnsafeMutableBufferPointer { dbuf in
                let c = SendablePointer(cbuf.baseAddress!), d = SendablePointer(dbuf.baseAddress!)
                // One work item per z-slab of either sub-lattice.
                let slabs = L.gz + (L.gz + 1)
                DispatchQueue.concurrentPerform(iterations: slabs) { s in
                    if s < L.gz {
                        let k = s
                        for j in 0..<L.gy { for i in 0..<L.gx {
                            c.base[L.cornerIndex(i, j, k)] = field(L.position(corner: true, i, j, k))
                        } }
                    } else {
                        let k = s - L.gz
                        for j in 0...L.gy { for i in 0...L.gx {
                            d.base[L.centreIndex(i, j, k)] = field(L.position(corner: false, i, j, k))
                        } }
                    }
                }
            }
        }
    }

    /// A table from values already computed per sample, in `LevelSetLattice`
    /// combined order (corners, then centres).
    init(lattice: LevelSetLattice, values: [Double], fallback: @escaping @Sendable (Vec3) -> Double) {
        precondition(values.count == lattice.sampleCount)
        self.lattice = lattice
        self.fallback = fallback
        let nc = lattice.cornerCount
        corner = Array(values[0..<nc])
        centre = Array(values[nc...])
    }

    /// Value Manifold's sign test sees (outermost layer clamped to ≤ 0,
    /// out-of-lattice = 0): true when strictly positive.
    @inline(__always) func positive(corner isCorner: Bool, _ i: Int, _ j: Int, _ k: Int) -> Bool {
        let L = lattice
        let b = L.boundDistance(corner: isCorner, i, j, k)
        guard b > 0 else { return false }
        let v = isCorner ? corner[L.cornerIndex(i, j, k)] : centre[L.centreIndex(i, j, k)]
        return v > 0
    }

    /// Re-evaluate, with `exact`, every sample for which `needsExact(value)`
    /// holds AND whose sign differs from one of its 14 level-set neighbours
    /// (the only samples whose magnitude Manifold ever reads). Returns how
    /// many were re-evaluated. Samples away from any sign change keep their
    /// (sign-correct) cheap value.
    @discardableResult
    func refineCrossings(needsExact: (Double) -> Bool, exact: @Sendable (Vec3) -> Double) -> Int {
        let L = lattice
        var todo: [(Bool, Int, Int, Int)] = []
        func crosses(_ isCorner: Bool, _ i: Int, _ j: Int, _ k: Int) -> Bool {
            let s = positive(corner: isCorner, i, j, k)
            func differs(_ c: Bool, _ a: Int, _ b: Int, _ e: Int) -> Bool {
                let inRange = c ? (a >= 0 && b >= 0 && e >= 0 && a < L.gx && b < L.gy && e < L.gz)
                                : (a >= 0 && b >= 0 && e >= 0 && a <= L.gx && b <= L.gy && e <= L.gz)
                let n = inRange ? positive(corner: c, a, b, e) : false
                return n != s
            }
            // Six axis neighbours on the same sub-lattice.
            if differs(isCorner, i - 1, j, k) || differs(isCorner, i + 1, j, k)
                || differs(isCorner, i, j - 1, k) || differs(isCorner, i, j + 1, k)
                || differs(isCorner, i, j, k - 1) || differs(isCorner, i, j, k + 1) { return true }
            // Eight half-diagonal neighbours on the other sub-lattice.
            let lo = isCorner ? 0 : -1, hi = isCorner ? 1 : 0
            for dk in lo...hi { for dj in lo...hi { for di in lo...hi {
                if differs(!isCorner, i + di, j + dj, k + dk) { return true }
            } } }
            return false
        }
        for k in 0..<L.gz { for j in 0..<L.gy { for i in 0..<L.gx
            where needsExact(corner[L.cornerIndex(i, j, k)]) && crosses(true, i, j, k) {
            todo.append((true, i, j, k))
        } } }
        for k in 0...L.gz { for j in 0...L.gy { for i in 0...L.gx
            where needsExact(centre[L.centreIndex(i, j, k)]) && crosses(false, i, j, k) {
            todo.append((false, i, j, k))
        } } }
        guard !todo.isEmpty else { return 0 }
        var values = [Double](repeating: 0, count: todo.count)
        values.withUnsafeMutableBufferPointer { vbuf in
            let out = SendablePointer(vbuf.baseAddress!)
            let jobs = todo
            DispatchQueue.concurrentPerform(iterations: jobs.count) { n in
                let (c, i, j, k) = jobs[n]
                out.base[n] = exact(L.position(corner: c, i, j, k))
            }
        }
        for (n, job) in todo.enumerated() {
            let (c, i, j, k) = job
            if c { corner[L.cornerIndex(i, j, k)] = values[n] } else { centre[L.centreIndex(i, j, k)] = values[n] }
        }
        return todo.count
    }

    /// The stored value when (x, y, z) is exactly a lattice point, else the
    /// fallback (counted as a miss).
    @inline(__always) func value(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let L = lattice
        let kx = ((x - L.origin.x) / L.spacing.x * 2).rounded()
        let ky = ((y - L.origin.y) / L.spacing.y * 2).rounded()
        let kz = ((z - L.origin.z) / L.spacing.z * 2).rounded()
        if kx.isFinite, ky.isFinite, kz.isFinite, abs(kx) < 1e9, abs(ky) < 1e9, abs(kz) < 1e9 {
            let ix = Int(kx), iy = Int(ky), iz = Int(kz)
            let px = ix & 1, py = iy & 1, pz = iz & 1
            if px == py, py == pz {
                let isCorner = px == 0
                let i = isCorner ? ix >> 1 : (ix + 1) >> 1
                let j = isCorner ? iy >> 1 : (iy + 1) >> 1
                let k = isCorner ? iz >> 1 : (iz + 1) >> 1
                let inRange = isCorner
                    ? (i >= 0 && j >= 0 && k >= 0 && i < L.gx && j < L.gy && k < L.gz)
                    : (i >= 0 && j >= 0 && k >= 0 && i <= L.gx && j <= L.gy && k <= L.gz)
                if inRange {
                    let p = L.position(corner: isCorner, i, j, k)
                    if p.x == x, p.y == y, p.z == z {
                        hitCounter.add(1, ordering: .relaxed)
                        return isCorner ? corner[L.cornerIndex(i, j, k)] : centre[L.centreIndex(i, j, k)]
                    }
                }
            }
        }
        missCounter.add(1, ordering: .relaxed)
        return fallback(Vec3(x: x, y: y, z: z))
    }

    /// Extract the `level` surface with Manifold, answering its samples from
    /// this table. The box and edge are the ones the lattice was built from.
    func levelSet(level: Double = 0, engine: ManifoldEngine.Type = ManifoldEngine.self) throws -> ManifoldHandle {
        try engine.levelSet(
            bounds: ManifoldEngine.LevelSetBounds(lo: lattice.lo, hi: lattice.hi),
            edgeLength: lattice.edgeLength,
            level: level,
            parallel: false
        ) { [self] x, y, z in value(x, y, z) }
    }
}

/// Raw pointer that parallel workers write DISJOINT slots through.
struct SendablePointer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
    init(_ base: UnsafeMutablePointer<T>) { self.base = base }
}

extension PrefilledField {
    /// True when Manifold would see at least one strictly positive sample.
    var hasPositiveSample: Bool {
        let L = lattice
        for k in 0..<L.gz { for j in 0..<L.gy { for i in 0..<L.gx
            where positive(corner: true, i, j, k) { return true } } }
        for k in 0...L.gz { for j in 0...L.gy { for i in 0...L.gx
            where positive(corner: false, i, j, k) { return true } } }
        return false
    }
}
