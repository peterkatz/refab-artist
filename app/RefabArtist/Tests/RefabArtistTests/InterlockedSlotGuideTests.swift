import Foundation
import Testing
@testable import RefabArtist

struct InterlockedSlotGuideTests {
    @Test
    func guidesExposeOneClosedPathPerInterlockedSlot() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 25,
            slotClearance: 0
        ))

        let guides = InterlockedSlotGuideGenerator.guides(for: plan)

        #expect(guides.count == plan.slotCount)
        #expect(guides.allSatisfy { $0.points.count == 5 })
        #expect(guides.allSatisfy { $0.points.first == $0.points.last })
        #expect(guides.filter { $0.familyIndex == 0 }.count == plan.primary.sliceCount * plan.secondary.sliceCount)
        #expect(guides.filter { $0.familyIndex == 1 }.count == plan.secondary.sliceCount * plan.primary.sliceCount)
    }

    @Test
    func guideCoordinatesSitOnTheirSlicePlane() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 25
        ))

        let guides = InterlockedSlotGuideGenerator.guides(for: plan)
        let primaryGuide = try #require(guides.first { $0.familyIndex == 0 && $0.layerIndex == 0 })
        let secondaryGuide = try #require(guides.first { $0.familyIndex == 1 && $0.layerIndex == 0 })

        #expect(primaryGuide.points.allSatisfy { $0.z == plan.primary.positions[0] })
        #expect(secondaryGuide.points.allSatisfy { $0.x == plan.secondary.positions[0] })
    }

    @Test
    func angledGuidesWidenSlotMouth() throws {
        let model = try Self.cubeModel()
        let straightPlan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 25,
            notchWidthOverride: 4,
            slotAngleDegrees: 0
        ))
        let angledPlan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 25,
            notchWidthOverride: 4,
            slotAngleDegrees: 30
        ))

        let straight = try #require(InterlockedSlotGuideGenerator.guides(for: straightPlan).first)
        let angled = try #require(InterlockedSlotGuideGenerator.guides(for: angledPlan).first)

        #expect(width(of: angled) > width(of: straight))
    }

    private func width(of guide: InterlockedSlotGuide) -> Double {
        let xs = guide.points.map(\.x)
        return (xs.max() ?? 0) - (xs.min() ?? 0)
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
