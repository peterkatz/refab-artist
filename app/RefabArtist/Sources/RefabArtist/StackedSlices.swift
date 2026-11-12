import Foundation

enum SliceAxis: String, CaseIterable, Identifiable, Codable {
    case x
    case y
    case z

    var id: String { rawValue }

    var label: String {
        rawValue.uppercased()
    }
}

struct StackedSlicePlan: Equatable {
    var axis: SliceAxis
    var materialThickness: Double
    var rangeMin: Double
    var rangeMax: Double
    var positions: [Double]
    /// When non-nil, these are user-supplied exact positions that override the
    /// automatic distribution. They are sorted, clamped to [rangeMin, rangeMax],
    /// and deduplicated at a 1e-6 mm tolerance before use.
    var positionsOverride: [Double]?

    var sliceCount: Int {
        positions.count
    }
}

enum StackedSlicePlanner {
    static let maxOverrideCount: Int = 240

    /// Per-family slice count the interlocked ("waffle") page-fit generator
    /// uses when the caller does not pass an explicit override. Design
    /// default: each interlocked registration family contributes a
    /// fixed ten slices, distributed evenly across the model's extent along its
    /// axis, regardless of the model's object-space size. (The cube's 50 mm /
    /// 10 = 5.0 mm pitch and the cylinder's 40 mm / 10 = 4.0 mm pitch are the
    /// same by-count rule, not a shared object-space depth.)
    static let interlockedDefaultFamilyCount: Int = 10

    static let indexRangeEpsilon: Double = 0.1

    // Slice-plane index-range guards used by the Letter reslice (see
    // `planLetterReslice`). That rule positions the slice grid
    // asymmetrically about the projected-axis midpoint and then clamps the
    // kept plane indices with a pair of tiny opposite-sign epsilons (±1e-4):
    // the lower (ceil) bound subtracts the guard
    // so a plane sitting essentially on `lo` is kept, and the upper (floor)
    // bound adds it so a plane essentially on `hi` is kept. These guard the
    // extreme polar planes against floating-point round-off without ever
    // admitting an extra out-of-range plane.
    static let indexRangeCeilGuard: Double = -1.0e-4
    static let indexRangeFloorGuard: Double = 1.0e-4

    static func plan(
        model: MeshSummary,
        axis: SliceAxis,
        materialThickness: Double,
        sliceDepth: Double? = nil,
        sliceCountOverride: Int? = nil,
        positionsOverride: [Double]? = nil
    ) -> StackedSlicePlan? {
        guard let bounds = model.bounds,
              materialThickness.isFinite,
              materialThickness > 0 else {
            return nil
        }
        let resolvedSliceDepth = sliceDepth ?? materialThickness
        guard resolvedSliceDepth.isFinite, resolvedSliceDepth > 0 else {
            return nil
        }
        let (lo, hi) = axisExtent(bounds: bounds, axis: axis)
        let positions: [Double]
        let resolvedOverride: [Double]?
        if let raw = positionsOverride, !raw.isEmpty {
            // Sort, clamp to model extent, deduplicate at 1e-6 mm tolerance.
            let sorted = raw.sorted()
            var clamped: [Double] = []
            for pos in sorted {
                let c = min(hi, max(lo, pos))
                if let last = clamped.last, abs(c - last) < 1.0e-6 { continue }
                clamped.append(c)
            }
            if clamped.isEmpty { return nil }
            positions = clamped
            resolvedOverride = clamped
        } else if let overrideCount = sliceCountOverride {
            let count = max(1, min(overrideCount, maxOverrideCount))
            positions = distributeEvenly(lo: lo, hi: hi, count: count)
            resolvedOverride = nil
        } else {
            positions = automaticPositions(lo: lo, hi: hi, sliceDepth: resolvedSliceDepth)
            resolvedOverride = nil
        }
        return StackedSlicePlan(
            axis: axis,
            materialThickness: materialThickness,
            rangeMin: lo,
            rangeMax: hi,
            positions: positions,
            positionsOverride: resolvedOverride
        )
    }

    private static func axisExtent(bounds: Bounds3D, axis: SliceAxis) -> (Double, Double) {
        let lo: Double
        let hi: Double
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
        return (min(lo, hi), max(lo, hi))
    }

    private static func distributeEvenly(lo: Double, hi: Double, count: Int) -> [Double] {
        let span = max(hi - lo, 0)
        guard span > 0, count >= 1 else {
            return [lo]
        }
        return (0..<count).map { index in
            lo + span * (Double(index) + 0.5) / Double(count)
        }
    }

    private static func automaticPositions(lo: Double, hi: Double, sliceDepth d: Double) -> [Double] {
        let span = max(hi - lo, 0)
        guard span > 0, d > 0 else {
            return []
        }
        let internalCount = max(1, Int(floor(span / d)))
        let midpoint = (lo + hi) * 0.5
        let localOffsetBase = midpoint - (Double(internalCount) + 0.5) * d * 0.5
        let iStart = Int(ceil((lo - localOffsetBase) / d + indexRangeEpsilon))
        let iEnd = Int(floor((hi - localOffsetBase) / d + indexRangeEpsilon))
        guard iEnd >= iStart else { return [] }
        return (iStart...iEnd).map { Double($0) * d + localOffsetBase }
    }

    /// Build a slice plan for one interlocked ("waffle") registration family.
    /// Without an explicit override the family always contributes a fixed
    /// `interlockedDefaultFamilyCount` (= 10) slices, distributed evenly across
    /// the model's extent along this axis at centres
    /// `lo + span·(i+0.5)/N`. The two registration families mate on a grid
    /// whose slot centres land at these positions — the geometry
    /// `InterlockedPartBuilder` cuts.
    ///
    /// This is the by-count rule, not an object-space depth count: a 50 mm
    /// extent yields a 5.0 mm pitch and a 40 mm extent a 4.0 mm pitch from the
    /// SAME `N = 10`. (For a symmetric model whose extent is an exact multiple
    /// of the material thickness — e.g. the 50 mm cube at a 5 mm thickness —
    /// the resulting centres `[-22.5 … 22.5]` are identical to the earlier
    /// fixed-step `lo + d·(i+0.5)` distribution, so that case is unchanged.)
    /// It is kept separate from the default `automaticPositions` (which centres
    /// the grid asymmetrically about the midpoint for the Stacked stock/Letter
    /// reslice) so the Stacked path is untouched.
    static func planInterlockedFamily(
        model: MeshSummary,
        axis: SliceAxis,
        materialThickness: Double,
        sliceCountOverride: Int? = nil
    ) -> StackedSlicePlan? {
        guard let bounds = model.bounds,
              materialThickness.isFinite,
              materialThickness > 0 else {
            return nil
        }
        let (lo, hi) = axisExtent(bounds: bounds, axis: axis)
        let count = max(1, min(sliceCountOverride ?? interlockedDefaultFamilyCount, maxOverrideCount))
        let positions = distributeEvenly(lo: lo, hi: hi, count: count)
        return StackedSlicePlan(
            axis: axis,
            materialThickness: materialThickness,
            rangeMin: lo,
            rangeMax: hi,
            positions: positions
        )
    }

    /// Build a plan using By Distance: spacing in mm → derive count from model
    /// extent. `slice_depth` semantics: count = floor(span/spacing).
    /// Returns nil for degenerate inputs.
    static func planByDistance(
        model: MeshSummary,
        axis: SliceAxis,
        materialThickness: Double,
        spacingMm: Double,
        positionsOverride: [Double]? = nil
    ) -> StackedSlicePlan? {
        guard let bounds = model.bounds,
              materialThickness.isFinite, materialThickness > 0,
              spacingMm.isFinite, spacingMm > 0 else {
            return nil
        }
        let (lo, hi) = axisExtent(bounds: bounds, axis: axis)
        let span = max(hi - lo, 0)
        guard span > 0 else { return nil }
        let count = max(1, min(Int(floor(span / spacingMm)), maxOverrideCount))
        let positions = distributeEvenly(lo: lo, hi: hi, count: count)
        return StackedSlicePlan(
            axis: axis,
            materialThickness: materialThickness,
            rangeMin: lo,
            rangeMax: hi,
            positions: positions,
            positionsOverride: positionsOverride
        )
    }

    /// Build a slice plan using the Letter reslice auto-position rule, used
    /// by Radial "By Distance" rings.
    /// This is kept separate from `plan`/`automaticPositions` so the other
    /// modes (3D, curve, interlocked, default DXF/SVG/EPS/STL/OBJ) keep
    /// their slice counts. The rule:
    ///   intervalCount = ceil((hi-lo)/d)          (CEIL, not floor)
    ///   base = midpoint - (intervalCount+0.5)·d/2
    ///   keep i in [ceil((lo-base)/d - 1e-4) … floor((hi-base)/d + 1e-4)]
    ///   plane z_i = i·d + base
    static func planLetterReslice(
        model: MeshSummary,
        axis: SliceAxis,
        sliceDepth d: Double
    ) -> StackedSlicePlan? {
        guard let bounds = model.bounds, d.isFinite, d > 0 else { return nil }
        let (lo, hi) = axisExtent(bounds: bounds, axis: axis)
        let span = max(hi - lo, 0)
        guard span > 0 else { return nil }
        let intervalCount = max(1, Int(ceil(span / d)))
        let midpoint = (lo + hi) * 0.5
        let base = midpoint - (Double(intervalCount) + 0.5) * d * 0.5
        let iStart = Int(ceil((lo - base) / d + indexRangeCeilGuard))
        let iEnd = Int(floor((hi - base) / d + indexRangeFloorGuard))
        guard iEnd >= iStart else { return nil }
        let positions = (iStart...iEnd).map { Double($0) * d + base }
        return StackedSlicePlan(
            axis: axis,
            materialThickness: d,
            rangeMin: lo,
            rangeMax: hi,
            positions: positions
        )
    }
}
