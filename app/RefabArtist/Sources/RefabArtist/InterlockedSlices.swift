import Foundation

// MARK: - SlotReliefSettings

struct SlotReliefSettings: Equatable {
    static let disabled = SlotReliefSettings(enabled: false, diameter: 3.0)

    var enabled: Bool
    var diameter: Double

    var radius: Double {
        max(0, diameter) / 2
    }
}

struct InterlockedSlicePlan: Equatable {
    var primary: StackedSlicePlan
    var secondary: StackedSlicePlan
    var materialThickness: Double
    var slotClearance: Double
    var slotWidth: Double
    var slotAngleDegrees: Double = 0
    var slotRelief: SlotReliefSettings = .disabled
    var bounds: Bounds3D
    /// The notch width that sets `slotWidth` in place of the thickness plus
    /// the slot offset, when the user overrides it; the slot offset is then
    /// not used at all.
    var notchWidthOverride: Double? = nil

    var sliceCount: Int {
        primary.sliceCount + secondary.sliceCount
    }

    var slotCount: Int {
        primary.sliceCount * secondary.sliceCount * 2
    }

    var normalizedSlotAngleDegrees: Double {
        min(60, max(0, slotAngleDegrees))
    }

    func slotMouthFlare(forDepth depth: Double) -> Double {
        let angle = normalizedSlotAngleDegrees
        guard angle > 0, depth > 0 else {
            return 0
        }
        return depth * tan(angle * .pi / 180)
    }
}

enum InterlockedSlicePlanner {
    private static let minimumSlotWidth = 0.1

    /// Tie tolerance for bbox-axis selection. Mesh tessellation can make
    /// semantically equal axes differ slightly (for example the sampled torus
    /// X/Y diameters differ by ~0.55%). Treat axes within 1% of the maximum as
    /// a top tie.
    private static let axisTieRelativeTolerance = 0.01

    /// Choose the two registration-slicing axes. Both interlocked families
    /// are vertical planks oriented across the model's LONGEST bounding-box
    /// extent, so each family slices one of the two axes PERPENDICULAR to that
    /// longest extent (the longest axis becomes the in-plane depth of every
    /// part, never a slicing direction). When no axis is unambiguously longest
    /// — e.g. a cube or sphere whose three extents tie — the caller's supplied
    /// `(primary, secondary)` pair is returned unchanged, leaving symmetric
    /// models byte-for-byte as before.
    static func selectAxes(
        bounds: Bounds3D,
        givenPrimary: SliceAxis,
        givenSecondary: SliceAxis
    ) -> (primary: SliceAxis, secondary: SliceAxis) {
        automaticAxes(bounds: bounds) ?? (givenPrimary, givenSecondary)
    }

    /// The axes the planner picks itself, across the model's longest
    /// extent; nil when all three extents tie, so the caller's axes are
    /// used. While this is non-nil the Primary and Secondary choices have
    /// no effect.
    static func automaticAxes(bounds: Bounds3D) -> (primary: SliceAxis, secondary: SliceAxis)? {
        let spanX = abs(bounds.max.x - bounds.min.x)
        let spanY = abs(bounds.max.y - bounds.min.y)
        let spanZ = abs(bounds.max.z - bounds.min.z)
        let longest = max(spanX, max(spanY, spanZ))

        // Strict-longest only when exactly one extent reaches the maximum; any
        // tie at the top falls back to the caller's axes.
        let tieTolerance = max(1.0e-6, longest * axisTieRelativeTolerance)
        let nearX = longest - spanX <= tieTolerance
        let nearY = longest - spanY <= tieTolerance
        let nearZ = longest - spanZ <= tieTolerance

        if nearX && nearY && !nearZ {
            return (.x, .y)
        }
        if nearX && nearZ && !nearY {
            return (.x, .z)
        }
        if nearY && nearZ && !nearX {
            return (.y, .z)
        }

        if nearZ && !nearX && !nearY {
            return (.x, .y)
        }
        if nearX && !nearY && !nearZ {
            return (.y, .z)
        }
        if nearY && !nearX && !nearZ {
            return (.x, .z)
        }
        return nil
    }

    static func plan(
        model: MeshSummary,
        primaryAxis: SliceAxis,
        secondaryAxis: SliceAxis,
        materialThickness: Double,
        slotClearance: Double = 0,
        notchWidthOverride: Double? = nil,
        slotAngleDegrees: Double = 0,
        slotRelief: SlotReliefSettings = .disabled,
        sliceCountOverride: Int? = nil
    ) -> InterlockedSlicePlan? {
        guard let bounds = model.bounds else { return nil }
        let axes = selectAxes(bounds: bounds, givenPrimary: primaryAxis, givenSecondary: secondaryAxis)
        guard axes.primary != axes.secondary,
              let primary = StackedSlicePlanner.planInterlockedFamily(model: model, axis: axes.primary, materialThickness: materialThickness, sliceCountOverride: sliceCountOverride),
              let secondary = StackedSlicePlanner.planInterlockedFamily(model: model, axis: axes.secondary, materialThickness: materialThickness, sliceCountOverride: sliceCountOverride) else {
            return nil
        }
        let slotWidth = max(minimumSlotWidth, notchWidthOverride ?? materialThickness + slotClearance)
        return InterlockedSlicePlan(
            primary: primary,
            secondary: secondary,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            slotWidth: slotWidth,
            slotAngleDegrees: slotAngleDegrees,
            slotRelief: slotRelief,
            bounds: bounds,
            notchWidthOverride: notchWidthOverride
        )
    }
}
