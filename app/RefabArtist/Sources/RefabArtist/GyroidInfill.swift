import CManifold
import Foundation

// MARK: - Gyroid field

/// The gyroid implicit field and its band → physical-thickness mapping, shared by
/// both non-MC gyroid generators (Lofted + Tiled). This is the ONLY definition of
/// the field; neither generator touches 3D marching cubes.
enum GyroidField {
    /// g(p) = sin(kx)cos(ky) + sin(ky)cos(kz) + sin(kz)cos(kx), k = 2π / cell.
    /// Zero level set is the gyroid minimal surface; `{ |g| < band }` is the
    /// printable sheet solid.
    @inline(__always)
    static func value(_ x: Double, _ y: Double, _ z: Double, k: Double) -> Double {
        let kx = k * x, ky = k * y, kz = k * z
        return sin(kx) * cos(ky) + sin(ky) * cos(kz) + sin(kz) * cos(kx)
    }

    /// Map the shared wall-thickness control to a field band. Near the surface `g`
    /// grows ≈ linearly with slope `k` along the normal, so a physical wall of
    /// `wallMm` corresponds to a band ≈ `k · wallMm / 2`. HONOR the wall control
    /// directly — no thick floor/clamp (the old [0.30, 0.85] window ignored the
    /// slider and forced ~5 mm walls). Only a tiny floor to avoid a degenerate
    /// zero-width sheet.
    static func band(cell: Double, wallMm: Double, floor: Double) -> Double {
        let k = 2.0 * Double.pi / cell
        let fromWall = k * wallMm / 2.0
        return Swift.max(fromWall, 0.02)
    }
}

/// 1-D accumulated phase table for graded gyroids. This is the M3 critical path:
/// local frequency is integrated as `φ(u)=∫k(t)dt`, never multiplied as `k(u)*u`.
struct GyroidPhaseTable {
    let lo: Double
    let hi: Double
    private let samples: [Double]

    init(
        lo: Double,
        hi: Double,
        sampleCount requestedSamples: Int = 1024,
        kAt: (Double) -> Double
    ) {
        self.lo = lo
        self.hi = hi
        let count = max(requestedSamples, 2)
        guard hi > lo else {
            self.samples = [0, 0]
            return
        }

        let step = (hi - lo) / Double(count - 1)
        var phases = [Double](repeating: 0, count: count)
        var previous = max(kAt(lo), 1.0e-9)
        for i in 1..<count {
            let u = lo + Double(i) * step
            let current = max(kAt(u), 1.0e-9)
            phases[i] = phases[i - 1] + (previous + current) * 0.5 * step
            previous = current
        }
        self.samples = phases
    }

    init(
        bounds: Bounds3D,
        axis: SpacingAxis,
        density: DensityField,
        sampleCount: Int = 1024
    ) {
        let lo: Double
        let hi: Double
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) * 0.5,
            y: (bounds.min.y + bounds.max.y) * 0.5,
            z: (bounds.min.z + bounds.max.z) * 0.5
        )
        switch axis {
        case .x:
            lo = bounds.min.x
            hi = bounds.max.x
        case .y:
            lo = bounds.min.y
            hi = bounds.max.y
        case .z:
            lo = bounds.min.z
            hi = bounds.max.z
        }
        self.init(lo: lo, hi: hi, sampleCount: sampleCount) { u in
            var p = SIMD3<Double>(center.x, center.y, center.z)
            switch axis {
            case .x: p.x = u
            case .y: p.y = u
            case .z: p.z = u
            }
            return 2.0 * Double.pi * density.lineDensity(at: p)
        }
    }

    var totalPhase: Double {
        samples.last ?? 0
    }

    func phase(at u: Double) -> Double {
        guard hi > lo, samples.count >= 2 else { return 0 }
        let t = min(max((u - lo) / (hi - lo), 0), 1)
        let scaled = t * Double(samples.count - 1)
        let i0 = min(max(Int(scaled.rounded(.down)), 0), samples.count - 1)
        let i1 = min(i0 + 1, samples.count - 1)
        let local = scaled - Double(i0)
        return samples[i0] * (1 - local) + samples[i1] * local
    }

    /// Number of zero-level gyroid-sheet centerline crossings along the graded
    /// axis at y=z=0 for the appendix constant.
    var zeroCrossingCount: Int {
        Int((totalPhase / Double.pi).rounded())
    }
}

// MARK: - 2D marching squares (per-layer contour, NOT 3D marching cubes)

/// Trace the closed contours of a 2D scalar field's `iso` level via marching
/// squares. This is the per-layer 2D slicer step the gyroid recipe calls for: it
/// produces polygon loops {f = iso} for one Z plane, with NO 3D marching cubes
/// anywhere. The loops are handed to Manifold's CrossSection/extrude to build the
/// layer slab.
enum MarchingSquares {
    /// A single closed polyline (sequence of XY points). May not be perfectly
    /// closed numerically; Manifold's CrossSection union tolerates that.
    typealias Loop = [SIMD2<Double>]

    /// Extract iso-contours of a sampled field.
    ///
    /// - `values`: row-major `nx × ny` samples (index = iy*nx + ix).
    /// - `origin`, `dx`, `dy`: world position of sample (0,0) and the spacing.
    /// - `iso`: contour level.
    ///
    /// Returns a set of open segments stitched into closed loops. We keep it
    /// robust rather than topologically perfect: degenerate/short loops are
    /// dropped, and the CrossSection union downstream repairs T-junctions where
    /// channels merge or split.
    static func contours(
        values: [Double], nx: Int, ny: Int,
        originX: Double, originY: Double, dx: Double, dy: Double,
        iso: Double
    ) -> [Loop] {
        guard nx >= 2, ny >= 2, values.count == nx * ny else { return [] }

        @inline(__always) func v(_ ix: Int, _ iy: Int) -> Double { values[iy * nx + ix] }
        @inline(__always) func px(_ ix: Int) -> Double { originX + Double(ix) * dx }
        @inline(__always) func py(_ iy: Int) -> Double { originY + Double(iy) * dy }
        @inline(__always) func lerp(_ a: Double, _ b: Double, _ va: Double, _ vb: Double) -> Double {
            let d = vb - va
            if abs(d) < 1e-12 { return (a + b) * 0.5 }
            let t = (iso - va) / d
            return a + (b - a) * Swift.min(Swift.max(t, 0.0), 1.0)
        }

        // Collect contour segments per cell, then stitch into loops by endpoint
        // matching on a quantized grid.
        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        segments.reserveCapacity(nx * ny)

        for iy in 0..<(ny - 1) {
            for ix in 0..<(nx - 1) {
                let v00 = v(ix, iy)         // bottom-left
                let v10 = v(ix + 1, iy)     // bottom-right
                let v11 = v(ix + 1, iy + 1) // top-right
                let v01 = v(ix, iy + 1)     // top-left
                var idx = 0
                if v00 > iso { idx |= 1 }
                if v10 > iso { idx |= 2 }
                if v11 > iso { idx |= 4 }
                if v01 > iso { idx |= 8 }
                if idx == 0 || idx == 15 { continue }

                let x0 = px(ix), x1 = px(ix + 1)
                let y0 = py(iy), y1 = py(iy + 1)

                // Edge crossing points (only computed where used).
                func bottom() -> SIMD2<Double> { SIMD2(lerp(x0, x1, v00, v10), y0) }
                func right() -> SIMD2<Double> { SIMD2(x1, lerp(y0, y1, v10, v11)) }
                func top() -> SIMD2<Double> { SIMD2(lerp(x0, x1, v01, v11), y1) }
                func left() -> SIMD2<Double> { SIMD2(x0, lerp(y0, y1, v00, v01)) }

                // Marching-squares case table (standard, with saddle resolution
                // by the average value). Each case emits one or two segments.
                func emit(_ a: SIMD2<Double>, _ b: SIMD2<Double>) { segments.append((a, b)) }

                switch idx {
                case 1: emit(left(), bottom())
                case 2: emit(bottom(), right())
                case 3: emit(left(), right())
                case 4: emit(right(), top())
                case 5: // saddle
                    let avg = (v00 + v10 + v11 + v01) * 0.25
                    if avg > iso { emit(left(), top()); emit(bottom(), right()) }
                    else { emit(left(), bottom()); emit(right(), top()) }
                case 6: emit(bottom(), top())
                case 7: emit(left(), top())
                case 8: emit(top(), left())
                case 9: emit(top(), bottom())
                case 10: // saddle
                    let avg = (v00 + v10 + v11 + v01) * 0.25
                    if avg > iso { emit(bottom(), left()); emit(top(), right()) }
                    else { emit(bottom(), right()); emit(top(), left()) }
                case 11: emit(top(), right())
                case 12: emit(right(), left())
                case 13: emit(right(), bottom())
                case 14: emit(bottom(), left())
                default: break
                }
            }
        }

        return stitch(segments, dx: dx, dy: dy)
    }

    /// Stitch directed segments into closed loops by matching endpoints on a
    /// quantized grid (≈ 1/100 of a cell). Robust to small numeric mismatch.
    private static func stitch(
        _ segments: [(SIMD2<Double>, SIMD2<Double>)], dx: Double, dy: Double
    ) -> [Loop] {
        guard !segments.isEmpty else { return [] }
        let q = Swift.max(min(abs(dx), abs(dy)) * 0.01, 1e-9)
        struct Key: Hashable { var x: Int64; var y: Int64 }
        @inline(__always) func key(_ p: SIMD2<Double>) -> Key {
            Key(x: Int64((p.x / q).rounded()), y: Int64((p.y / q).rounded()))
        }

        // Adjacency: from a start key, the list of (segmentIndex, endpoint).
        var startMap: [Key: [Int]] = [:]
        for (i, s) in segments.enumerated() {
            startMap[key(s.0), default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [Loop] = []

        for seed in 0..<segments.count {
            if used[seed] { continue }
            used[seed] = true
            var loop: Loop = [segments[seed].0, segments[seed].1]
            var current = key(segments[seed].1)
            let startKey = key(segments[seed].0)
            var guardCount = 0
            let limit = segments.count + 4
            while current != startKey && guardCount < limit {
                guardCount += 1
                guard let candidates = startMap[current] else { break }
                var advanced = false
                for ci in candidates where !used[ci] {
                    used[ci] = true
                    loop.append(segments[ci].1)
                    current = key(segments[ci].1)
                    advanced = true
                    break
                }
                if !advanced { break }
            }
            if loop.count >= 4 { loops.append(loop) }
        }
        return loops
    }
}

// MARK: - Manifold 2D → 3D bridge for the gyroid (extrude + smooth)

/// Manifold C-API helpers used ONLY by the gyroid generators: build polygons from
/// 2D loops, extrude to a slab, and smooth the unioned solid. Kept here (not in
/// ManifoldEngine) so the gyroid path is self-contained; these all do their own
/// arena allocation and ownership, mirroring `ManifoldEngine`'s conventions.
enum GyroidManifold {
    private static let manifoldArenaSize = manifold_manifold_size()
    private static let polygonsArenaSize = manifold_polygons_size()
    private static let simplePolyArenaSize = manifold_simple_polygon_size()
    private static let crossSectionArenaSize = manifold_cross_section_size()

    private static func arena(_ size: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    }

    /// Extrude a set of 2D loops (one layer's wall region) into a slab of the given
    /// height, then translate it so its base sits at `baseZ`. Returns nil when the
    /// loops are empty/degenerate (Manifold would reject them).
    ///
    /// CRITICAL robustness step: the raw marching-squares loops can self-touch or
    /// overlap (saddle ambiguity, near-coincident walls at small cells). Extruding
    /// such polygons DIRECTLY makes a SELF-INTERSECTING solid that `manifold_extrude`
    /// still reports as "no error" — and then the downstream `manifold_union`, which
    /// assumes valid 2-manifold input, hits undefined behaviour and HARD-CRASHES
    /// (segfault). So we first normalise the loops into a clean, simple region with
    /// a `CrossSection` (even-odd fill resolves self-intersection/overlap/nesting
    /// regardless of loop winding), read the cleaned polygons back, and extrude
    /// THOSE — guaranteeing a valid slab that unions safely.
    static func extrudeSlab(
        loops: [MarchingSquares.Loop], height: Double, baseZ: Double
    ) -> ManifoldHandle? {
        let valid = loops.filter { $0.count >= 3 }
        guard !valid.isEmpty, height > 1e-9 else { return nil }

        // Build one ManifoldSimplePolygon per loop, keeping the backing point
        // buffers alive across the call.
        var pointBuffers: [[ManifoldVec2]] = []
        pointBuffers.reserveCapacity(valid.count)
        var simplePtrs: [OpaquePointer?] = []
        var simpleMems: [UnsafeMutableRawPointer] = []

        for loop in valid {
            var pts = loop.map { ManifoldVec2(x: $0.x, y: $0.y) }
            pointBuffers.append(pts)
            let mem = arena(simplePolyArenaSize)
            let sp: OpaquePointer? = pts.withUnsafeMutableBufferPointer { bp in
                manifold_simple_polygon(mem, bp.baseAddress, bp.count)
            }
            guard let sp else { mem.deallocate(); continue }
            simplePtrs.append(sp)
            simpleMems.append(mem)
        }
        guard !simplePtrs.isEmpty else { return nil }
        defer {
            for (i, p) in simplePtrs.enumerated() {
                if let p { manifold_destruct_simple_polygon(p) }
                simpleMems[i].deallocate()
            }
        }

        let polyMem = arena(polygonsArenaSize)
        let polys: OpaquePointer? = simplePtrs.withUnsafeMutableBufferPointer { bp in
            manifold_polygons(polyMem, bp.baseAddress, bp.count)
        }
        guard let polys else { polyMem.deallocate(); return nil }
        defer {
            manifold_destruct_polygons(polys)
            polyMem.deallocate()
        }

        // Normalise the (possibly self-intersecting/overlapping) loops into a clean
        // simple region, then read back well-formed polygons for extrusion.
        let csMem = arena(crossSectionArenaSize)
        let cs = manifold_cross_section_of_polygons(csMem, polys, MANIFOLD_FILL_RULE_EVEN_ODD)
        guard let cs else { csMem.deallocate(); return nil }
        defer {
            manifold_destruct_cross_section(cs)
            csMem.deallocate()
        }
        guard manifold_cross_section_is_empty(cs) == 0 else { return nil }

        let cleanMem = arena(polygonsArenaSize)
        let cleanPolys = manifold_cross_section_to_polygons(cleanMem, cs)
        guard let cleanPolys else { cleanMem.deallocate(); return nil }
        defer {
            manifold_destruct_polygons(cleanPolys)
            cleanMem.deallocate()
        }

        let exMem = arena(manifoldArenaSize)
        // slices=1, no twist, no scale: a straight prism.
        let extruded = manifold_extrude(exMem, cleanPolys, height, 1, 0.0, 1.0, 1.0)
        guard let extruded, manifold_status(extruded) == MANIFOLD_NO_ERROR,
              manifold_is_empty(extruded) == 0 else {
            if let extruded { manifold_destruct_manifold(extruded) }
            exMem.deallocate()
            return nil
        }
        // manifold_extrude builds the prism with its base at z=0; move to baseZ.
        let mvMem = arena(manifoldArenaSize)
        let moved = manifold_translate(mvMem, extruded, 0, 0, baseZ)
        manifold_destruct_manifold(extruded)
        exMem.deallocate()
        guard let moved, manifold_status(moved) == MANIFOLD_NO_ERROR else {
            if let moved { manifold_destruct_manifold(moved) }
            mvMem.deallocate()
            return nil
        }
        return ManifoldHandle(adopting: mvMem, manifold: moved)
    }

    /// Smooth Z-terracing out of the unioned slab solid. `manifold_refine`
    /// subdivides each triangle so the subsequent `manifold_smooth_out` has the
    /// vertex density to round the stair-steps into the flowing minimal-surface
    /// look, then we simplify lightly to shed redundant coplanar triangles.
    ///
    /// `minSharpAngle` below ~180 keeps genuine creases; we use a high value so the
    /// gently terraced sheet is treated as smooth everywhere and rounded.
    static func smoothed(
        _ h: ManifoldHandle, refine: Int, minSharpAngle: Double, minSmoothness: Double
    ) throws -> ManifoldHandle {
        var current = h
        if refine > 1 {
            let rMem = arena(manifoldArenaSize)
            let refined = manifold_refine(rMem, current.manifold, Int32(refine))
            guard let refined, manifold_status(refined) == MANIFOLD_NO_ERROR else {
                if let refined { manifold_destruct_manifold(refined) }
                rMem.deallocate()
                throw ManifoldEngineError.invalidConstruction
            }
            current = ManifoldHandle(adopting: rMem, manifold: refined)
        }
        let sMem = arena(manifoldArenaSize)
        let smooth = manifold_smooth_out(sMem, current.manifold, minSharpAngle, minSmoothness)
        guard let smooth, manifold_status(smooth) == MANIFOLD_NO_ERROR else {
            if let smooth { manifold_destruct_manifold(smooth) }
            sMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        let result = ManifoldHandle(adopting: sMem, manifold: smooth)
        withExtendedLifetime(current) {}
        return result
    }
}
