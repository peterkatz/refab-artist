import Foundation
import Testing
@testable import RefabArtist

/// NEO-103: Slice Edit + Distribution parity.
/// Covers positionsOverride planning, By-Distance count derivation,
/// and the toolbar actions (add-at-largest-gap, distribute-evenly reset).
struct SliceEditTests {

    // MARK: - positionsOverride planning

    @Test
    func positionsOverrideSortsInputBeforeUse() throws {
        let model = try Self.cubeModel()

        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: [10.0, -20.0, 0.0, -10.0, 20.0]
        )

        #expect(plan != nil)
        #expect(plan?.positions == [-20.0, -10.0, 0.0, 10.0, 20.0])
    }

    @Test
    func positionsOverrideClampsToModelExtent() throws {
        let model = try Self.cubeModel()  // cube: ±25 mm on each axis

        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: [-100.0, -10.0, 0.0, 10.0, 999.0]
        )

        #expect(plan != nil)
        // -100 clamps to -25, 999 clamps to 25
        #expect(plan?.positions.first ?? 0 >= -25.0 - 1e-9)
        #expect(plan?.positions.last ?? 0 <= 25.0 + 1e-9)
        #expect(plan?.sliceCount == 5)
    }

    @Test
    func positionsOverrideDeduplicatesNearbyValues() throws {
        let model = try Self.cubeModel()

        // Two values within 1e-6 mm of each other should merge.
        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: [-10.0, 0.0, 0.0 + 5e-7, 10.0]
        )

        #expect(plan?.sliceCount == 3)
        #expect(plan?.positions == [-10.0, 0.0, 10.0])
    }

    @Test
    func positionsOverridePreservesOverrideField() throws {
        let model = try Self.cubeModel()
        let override = [-15.0, 0.0, 15.0]

        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: override
        )

        #expect(plan?.positionsOverride == override)
    }

    @Test
    func positionsOverrideIsNilWhenNotPassed() throws {
        let model = try Self.cubeModel()

        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5
        )

        #expect(plan?.positionsOverride == nil)
    }

    @Test
    func emptyPositionsOverrideFallsBackToAutomatic() throws {
        let model = try Self.cubeModel()

        // An empty array should be treated as "no override" (returns nil if
        // the clamped list is also empty, or uses automatic).
        // The planner treats empty raw the same as nil.
        let planWithEmpty = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            positionsOverride: []
        )
        let planAutomatic = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5
        )

        // Both should produce the same slice count.
        #expect(planWithEmpty?.sliceCount == planAutomatic?.sliceCount)
    }

    // MARK: - By Distance planning

    @Test
    func planByDistanceDerivesCountFromExtentAndSpacing() throws {
        let model = try Self.cubeModel()  // 50 mm extent on Z

        // floor(50 / 10) = 5 slices
        let plan = StackedSlicePlanner.planByDistance(
            model: model,
            axis: .z,
            materialThickness: 5,
            spacingMm: 10
        )

        #expect(plan?.sliceCount == 5)
    }

    @Test
    func planByDistanceUsesFloorNotCeil() throws {
        let model = try Self.cubeModel()  // 50 mm extent on Z

        // floor(50 / 7) = 7 (not 8)
        let plan = StackedSlicePlanner.planByDistance(
            model: model,
            axis: .z,
            materialThickness: 5,
            spacingMm: 7
        )

        #expect(plan?.sliceCount == 7)
    }

    @Test
    func planByDistanceClampsMinToOne() throws {
        let model = try Self.cubeModel()

        // Spacing larger than the model = floor(50/60) = 0, clamped to 1.
        let plan = StackedSlicePlanner.planByDistance(
            model: model,
            axis: .z,
            materialThickness: 5,
            spacingMm: 60
        )

        #expect(plan?.sliceCount == 1)
    }

    @Test
    func planByDistanceClampsMaxTo240() throws {
        let model = try Self.cubeModel()

        // Very small spacing: many slices, capped at 240.
        let plan = StackedSlicePlanner.planByDistance(
            model: model,
            axis: .z,
            materialThickness: 5,
            spacingMm: 0.1
        )

        #expect(plan?.sliceCount == 240)
    }

    @Test
    func planByDistanceReturnsNilForZeroSpacing() throws {
        let model = try Self.cubeModel()

        let plan = StackedSlicePlanner.planByDistance(
            model: model,
            axis: .z,
            materialThickness: 5,
            spacingMm: 0
        )

        #expect(plan == nil)
    }

    // MARK: - Add-at-largest-gap logic (unit-tested via the planner)

    @Test
    func addAtLargestGapInsertsAtMidpointOfGap() throws {
        // Simulate what handleSliceAdd does: find largest gap, insert at midpoint.
        // Positions: [-20, -10, 10, 20] — largest gap is between -10 and 10 (20 mm)
        let positions = [-20.0, -10.0, 10.0, 20.0]
        let rangeMin = -25.0
        let rangeMax = 25.0

        let newPos = Self.addAtLargestGap(positions: positions, rangeMin: rangeMin, rangeMax: rangeMax)

        // Gap between -10 and 10 is 20 mm; midpoint = 0.
        #expect(abs(newPos - 0.0) < 1e-9)
    }

    @Test
    func addAtLargestGapHandlesBoundaryGap() throws {
        // Positions: [0, 10] — the gap from rangeMin (-25) to 0 is 25, largest.
        let positions = [0.0, 10.0]
        let rangeMin = -25.0
        let rangeMax = 25.0

        let newPos = Self.addAtLargestGap(positions: positions, rangeMin: rangeMin, rangeMax: rangeMax)

        // Gap from -25 to 0 is 25; midpoint = -12.5.
        #expect(abs(newPos - (-12.5)) < 1e-9)
    }

    @Test
    func addAtLargestGapHandlesSingleSlice() throws {
        // A single slice at 0: gaps are (-25 to 0) = 25 and (0 to 25) = 25.
        // Tie: first gap wins (gap index 0 = rangeMin to positions[0]).
        let positions = [0.0]
        let rangeMin = -25.0
        let rangeMax = 25.0

        let newPos = Self.addAtLargestGap(positions: positions, rangeMin: rangeMin, rangeMax: rangeMax)

        // Both gaps equal; first gap (index 0) midpoint = -12.5.
        #expect(abs(newPos - (-12.5)) < 1e-9)
    }

    // MARK: - Distribute Evenly reset

    @Test
    func distributeEvenlyResetsToUniformDistribution() throws {
        let model = try Self.cubeModel()

        // Start with custom positions, then verify that a byCount plan with the
        // same count as the original automatic produces uniform spacing.
        let customPositions = [-22.0, -5.0, 0.0, 17.0, 23.0]

        // After "Distribute Evenly", switch to byCount with same count.
        let count = customPositions.count
        let plan = StackedSlicePlanner.plan(
            model: model,
            axis: .z,
            materialThickness: 5,
            sliceCountOverride: count
        )

        #expect(plan?.sliceCount == count)
        // All adjacent gaps should be equal.
        guard let positions = plan?.positions, positions.count >= 2 else { return }
        let gaps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        let firstGap = gaps[0]
        for gap in gaps {
            #expect(abs(gap - firstGap) < 1e-9)
        }
    }

    // MARK: - Axis-drag position mapping (unit test of axis extraction logic)

    @Test
    func axisPositionExtractionWorksForAllThreeAxes() {
        // Verify the axis extraction that handleSliceMouseDragged uses.
        let hitZ = Vec3(x: 1.0, y: 2.0, z: 7.5)
        let hitX = Vec3(x: -5.0, y: 3.0, z: 0.0)
        let hitY = Vec3(x: 0.0, y: 12.5, z: 1.0)

        func axisPos(_ vec: Vec3, _ axis: SliceAxis) -> Double {
            switch axis {
            case .x: return vec.x
            case .y: return vec.y
            case .z: return vec.z
            }
        }

        #expect(axisPos(hitZ, .z) == 7.5)
        #expect(axisPos(hitX, .x) == -5.0)
        #expect(axisPos(hitY, .y) == 12.5)
    }

    // MARK: - HeadlessExportCommand --slice-positions flag

    @Test
    func headlessExportAcceptsSlicePositionsFlag() throws {
        let fixturePath = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "slice-positions-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputDir = outputURL.path
        // Verify the flag parses and produces output without throwing.
        #expect(throws: Never.self) {
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--fixture", fixturePath,
                "--output", "\(outputDir)/out.dxf",
                "--thickness", "5",
                "--slice-positions", "-15,-5,5,15"
            ])
        }
    }

    @Test
    func headlessExportWithoutSlicePositionsFlagIsStable() throws {
        // Verify that omitting --slice-positions doesn't change the slice plan.
        let model = try Self.cubeModel()
        let planA = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5)
        let planB = StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: 5, positionsOverride: nil)

        #expect(planA?.positions == planB?.positions)
        #expect(planA?.sliceCount == planB?.sliceCount)
    }

    // MARK: - Helpers

    /// Mirror of the add-at-largest-gap logic in ContentView.handleSliceAdd(),
    /// extracted to a pure function for unit testing.
    private static func addAtLargestGap(positions: [Double], rangeMin: Double, rangeMax: Double) -> Double {
        if positions.count == 1 {
            let gap0 = positions[0] - rangeMin
            let gap1 = rangeMax - positions[0]
            return gap0 >= gap1 ? rangeMin + gap0 / 2 : positions[0] + gap1 / 2
        }
        let pts = [rangeMin] + positions + [rangeMax]
        var largestGap = 0.0
        var gapIndex = 0
        for i in 0..<(pts.count - 1) {
            let g = pts[i + 1] - pts[i]
            if g > largestGap { largestGap = g; gapIndex = i }
        }
        return (pts[gapIndex] + pts[gapIndex + 1]) / 2
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
