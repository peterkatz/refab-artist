import Foundation
import Testing
@testable import RefabArtist

@Suite
struct MotherMoldArtistUXM3OverlayTests {
    @Test
    func autoOverlayUsesOnlyTheCheapResolverAndBuildsAllThreeArtistGuides() throws {
        let model = Self.cubeModel
        var settings = MotherMoldSettings.defaultValue
        settings.parts = .two
        settings.parting.mode = .auto
        settings.spout.mode = .auto
        settings.masterMount.mode = .flatBaseSocket

        var resolverCalls = 0
        let overlay = try #require(MotherMoldPrebuildOverlay.make(
            model: model,
            settings: settings,
            planeResolver: { shell, reference, liveSettings in
                resolverCalls += 1
                #expect(shell == model.geometry)
                #expect(reference == model.geometry)
                #expect(liveSettings == settings.sanitized)
                return [
                    PartitionPlane(
                        normal: Vec3(x: 1, y: 0, z: 0),
                        offset: 0,
                        isManual: false
                    )
                ]
            }
        ))

        #expect(resolverCalls == 1)
        #expect(overlay.partingPlanes.count == 1)
        #expect(overlay.partingPlanes[0].axisLabel == "X")
        #expect(overlay.partingPlanes[0].label == "Seam 1 — X @ 0.0 mm")
        #expect(abs(overlay.partingPlanes[0].width - 24.0) < 1.0e-9)
        #expect(abs(overlay.partingPlanes[0].height - 24.0) < 1.0e-9)
        #expect(overlay.pourHoleMarker.point == Vec3(x: 0, y: 0, z: 10))
        #expect(overlay.pourHoleMarker.axis == Vec3(x: 0, y: 0, z: 1))
        #expect(overlay.masterHolderFootprint != nil)
        #expect(overlay.masterHolderFootprint?.center.z == -10)
        #expect(overlay.masterHolderFootprint?.width == 40.5)
        #expect(overlay.masterHolderFootprint?.height == 40.5)
    }

    @Test
    func manualOffsetMovesThePlaneWithoutCallingAnyPlanner() throws {
        var settings = MotherMoldSettings.defaultValue
        settings.parting.mode = .manual
        settings.parting.planes = [
            PartitionPlane(
                normal: Vec3(x: 0, y: 1, z: 0),
                offset: -3,
                isManual: true
            )
        ]
        settings.spout.mode = .manual
        settings.spout.manualSpoutX = 2
        settings.spout.manualSpoutY = 3
        settings.spout.manualSpoutZ = 4

        let first = try #require(MotherMoldPrebuildOverlay.make(
            model: Self.cubeModel,
            settings: settings
        ))
        settings.parting.planes[0] = PartitionPlane(
            id: settings.parting.planes[0].id,
            normal: Vec3(x: 0, y: 1, z: 0),
            offset: 7.5,
            isManual: true
        )
        let moved = try #require(MotherMoldPrebuildOverlay.make(
            model: Self.cubeModel,
            settings: settings
        ))

        #expect(first.partingPlanes[0].center.y == -3)
        #expect(moved.partingPlanes[0].center.y == 7.5)
        #expect(first.fingerprint != moved.fingerprint)
        #expect(moved.pourHoleMarker.point == Vec3(x: 2, y: 3, z: 4))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RefabArtist/MotherMoldPrebuildOverlay.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("MotherMoldPlanner"))
        #expect(source.contains("MoldPartitioner.resolvePlanes"))
    }

    @Test
    func visibilityAndDebounceMatchTheMilestoneContract() {
        #expect(MotherMoldPrebuildOverlay.debounceNanoseconds == 16_000_000)
        #expect(MotherMoldPrebuildOverlay.shouldDisplay(
            isMotherMoldActive: true,
            hasGeneratedPlan: false,
            isGeneratedPlanStale: false
        ))
        #expect(MotherMoldPrebuildOverlay.shouldDisplay(
            isMotherMoldActive: true,
            hasGeneratedPlan: true,
            isGeneratedPlanStale: true
        ))
        #expect(!MotherMoldPrebuildOverlay.shouldDisplay(
            isMotherMoldActive: true,
            hasGeneratedPlan: true,
            isGeneratedPlanStale: false
        ))
        #expect(!MotherMoldPrebuildOverlay.shouldDisplay(
            isMotherMoldActive: false,
            hasGeneratedPlan: false,
            isGeneratedPlanStale: false
        ))
    }

    private static let cubeModel: MeshSummary = {
        let min = Vec3(x: -10, y: -10, z: -10)
        let max = Vec3(x: 10, y: 10, z: 10)
        let vertices = [
            Vec3(x: min.x, y: min.y, z: min.z),
            Vec3(x: max.x, y: min.y, z: min.z),
            Vec3(x: min.x, y: max.y, z: min.z),
            Vec3(x: max.x, y: max.y, z: min.z),
            Vec3(x: min.x, y: min.y, z: max.z),
            Vec3(x: max.x, y: min.y, z: max.z),
            Vec3(x: min.x, y: max.y, z: max.z),
            Vec3(x: max.x, y: max.y, z: max.z)
        ]
        return MeshSummary(
            name: "cube",
            path: "/tmp/m3-cube.stl",
            format: "STL",
            byteCount: 0,
            vertexObservationCount: vertices.count,
            faceCount: 0,
            triangleCount: 0,
            bounds: Bounds3D(min: min, max: max),
            geometry: MeshGeometryData(vertices: vertices, triangleIndices: []),
            preflight: MeshPreflight.analyze(
                geometry: MeshGeometryData(vertices: vertices, triangleIndices: [])
            )
        )
    }()
}
