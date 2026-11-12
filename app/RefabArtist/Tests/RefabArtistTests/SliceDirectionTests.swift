import Foundation
import Testing
@testable import RefabArtist

struct SliceDirectionTests {
    @Test
    func tiltAxesAreTheTwoPerpendicularAxesInXYZOrder() {
        #expect(SliceDirection.tiltAxes(for: .x) == (.y, .z))
        #expect(SliceDirection.tiltAxes(for: .y) == (.x, .z))
        #expect(SliceDirection.tiltAxes(for: .z) == (.x, .y))
    }

    @Test
    func meshRotationPlacesTiltsInThePerpendicularEulerSlots() {
        #expect(SliceDirection.meshRotationDegrees(axis: .z, tiltFirst: 10, tiltSecond: -5) == Vec3(x: 10, y: -5, z: 0))
        #expect(SliceDirection.meshRotationDegrees(axis: .x, tiltFirst: 10, tiltSecond: -5) == Vec3(x: 0, y: 10, z: -5))
        #expect(SliceDirection.meshRotationDegrees(axis: .y, tiltFirst: 10, tiltSecond: -5) == Vec3(x: 10, y: 0, z: -5))
    }

    @Test
    func tiltsClampInsideNinetyDegreesAndRejectNonFinite() {
        #expect(SliceDirection.sanitized(120) == 89)
        #expect(SliceDirection.sanitized(-120) == -89)
        #expect(SliceDirection.sanitized(.nan) == 0)
        #expect(SliceDirection.sanitized(.infinity) == 0)
        #expect(SliceDirection.isIdentity(tiltFirst: 0, tiltSecond: 0))
        #expect(!SliceDirection.isIdentity(tiltFirst: 0.5, tiltSecond: 0))
    }

    /// End-to-end through the real machinery: a 50 mm cube sliced along Z
    /// spans 50 mm; tilted 45° about X its Z-extent grows to 50·√2 ≈ 70.7 mm,
    /// so the stacked plan must produce ~√2× the slices. This is the same
    /// MeshScaler pre-rotation path the GUI's planningModel and the headless
    /// --slice-tilt flags use.
    @Test
    func tiltedCubeNeedsMoreStackedSlices() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cube = try MeshInspector.inspect(
            url: root.appending(path: "tests/fixtures/primitives/cube_50mm_binary.stl")
        )
        let flat = try #require(StackedSlicePlanner.plan(model: cube, axis: .z, materialThickness: 3))

        let rotation = SliceDirection.meshRotationDegrees(axis: .z, tiltFirst: 45, tiltSecond: 0)
        let tilted = MeshScaler.transformed(cube, scale: Vec3(x: 1, y: 1, z: 1), rotationDegrees: rotation)
        let tiltedPlan = try #require(StackedSlicePlanner.plan(model: tilted, axis: .z, materialThickness: 3))

        let ratio = Double(tiltedPlan.sliceCount) / Double(flat.sliceCount)
        #expect(ratio > 1.3 && ratio < 1.55, "expected ~\u{221A}2 slice growth, got \(flat.sliceCount) -> \(tiltedPlan.sliceCount)")

        // Zero tilt is the identity: same instance semantics, same plan.
        let identity = MeshScaler.transformed(
            cube,
            scale: Vec3(x: 1, y: 1, z: 1),
            rotationDegrees: SliceDirection.meshRotationDegrees(axis: .z, tiltFirst: 0, tiltSecond: 0)
        )
        let identityPlan = try #require(StackedSlicePlanner.plan(model: identity, axis: .z, materialThickness: 3))
        #expect(identityPlan.sliceCount == flat.sliceCount)
    }
}
