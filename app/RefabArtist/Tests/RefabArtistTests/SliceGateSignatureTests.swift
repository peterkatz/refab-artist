import Testing
@testable import RefabArtist

/// The Slice gate: which changes force a manual re-slice and which don't.
/// Pins two reported problems (2026-06-14): dowel tweaks shouldn't demand a
/// re-slice, and slice direction should reslice rather than wait.
struct SliceGateSignatureTests {
    private static func base() -> SliceInputSignature {
        SliceInputSignature(
            constructionMode: .stacked,
            modelScale: Vec3(x: 1, y: 1, z: 1),
            modelRotationDegrees: Vec3(x: 0, y: 0, z: 0),
            importUnit: .millimeters,
            materialThickness: 3,
            materialPreset: .custom,
            sliceAxis: .z,
            sliceTiltFirst: 0,
            sliceTiltSecond: 0,
            secondarySliceAxis: .x,
            slotClearance: 0.2,
            notchWidth: 3,
            notchWidthOverrideEnabled: false,
            slotAngleDegrees: 0,
            slotReliefEnabled: false,
            toolDiameter: 0,
            radialSliceCount: 6,
            radialFirstAxisByDistance: false,
            radialFirstAxisCount: 10,
            radialFirstAxisSpacing: 15,
            radialNotchFactor: 0.1,
            radialReliefType: .square,
            curvePrimaryAxis: .z,
            curveFirstAxisCount: 10,
            curveSliceCount: 7,
            curveAmplitude: 10,
            threeDSliceDepth: 10,
            dowelsEnabled: true,
            dowelDiameter: 6.35,
            dowelInset: 6,
            dowelShape: .round,
            dowelAutomaticCount: 2,
            foldedDetailFaces: 250,
            foldedJoinery: .preset(for: .diamond),
            foldedSplitPanels: false,
            foldedSeamEdges: [],
            customSliceDistributionEnabled: false,
            customSliceCount: 12,
            sliceDistributionMethod: .automatic,
            sliceByDistanceSpacingMm: 5,
            customSlicePositions: []
        )
    }

    @Test func dowelDiameterChangeDoesNotGate() {
        var changed = Self.base()
        changed.dowelDiameter = 10
        #expect(changed.sameSlicePlanGate(as: Self.base()))
    }

    @Test func dowelCountAndShapeAndInsetDoNotGate() {
        var changed = Self.base()
        changed.dowelAutomaticCount = 7
        changed.dowelShape = .pencil
        changed.dowelInset = 13
        #expect(changed.sameSlicePlanGate(as: Self.base()))
    }

    @Test func sliceDirectionChangeDoesNotGateItAutoReslices() {
        var changed = Self.base()
        changed.sliceTiltFirst = -30.6
        changed.sliceTiltSecond = 45
        #expect(changed.sameSlicePlanGate(as: Self.base()))
    }

    @Test func materialThicknessChangeGates() {
        var changed = Self.base()
        changed.materialThickness = 6
        #expect(!changed.sameSlicePlanGate(as: Self.base()))
    }

    @Test func sliceCountAndAxisChangesGate() {
        var thickened = Self.base()
        thickened.customSliceCount = 30
        #expect(!thickened.sameSlicePlanGate(as: Self.base()))

        var axisChanged = Self.base()
        axisChanged.sliceAxis = .x
        #expect(!axisChanged.sameSlicePlanGate(as: Self.base()))
    }

    @Test func dowelChangeMixedWithThicknessStillGates() {
        // A real plan change alongside dowel edits must NOT be masked away.
        var changed = Self.base()
        changed.dowelDiameter = 10
        changed.materialThickness = 6
        #expect(!changed.sameSlicePlanGate(as: Self.base()))
    }
}
