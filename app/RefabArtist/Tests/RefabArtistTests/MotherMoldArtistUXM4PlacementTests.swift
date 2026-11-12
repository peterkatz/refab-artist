import Foundation
import simd
import Testing
@testable import RefabArtist

@Suite
struct MotherMoldArtistUXM4PlacementTests {
    @Test
    func rayPickerReturnsTheVisibleSurfacePointAndNormal() throws {
        let ray = ViewportPickRay(
            origin: Vec3(x: 100, y: 0, z: 0),
            direction: Vec3(x: -1, y: 0, z: 0)
        )
        let hit = try #require(ViewportDowelRayPicker.intersectMeshSurface(
            ray: ray,
            geometry: Self.xFacingTriangle
        ))

        #expect(abs(hit.point.x - 10) < 1.0e-9)
        #expect(abs(hit.point.y) < 1.0e-9)
        #expect(abs(hit.point.z) < 1.0e-9)
        #expect(hit.normal == Vec3(x: 1, y: 0, z: 0))
    }

    @Test
    func composedModelSpinIsRemovedBeforeWritingModelSpaceSettings() throws {
        let quarterTurn = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let sceneRay = ViewportPickRay(
            origin: Vec3(x: 0, y: 100, z: 0),
            direction: Vec3(x: 0, y: -1, z: 0)
        )
        let hit = try #require(MotherMoldSurfacePlacement.hit(
            sceneRay: sceneRay,
            geometry: Self.xFacingTriangle,
            bounds: Bounds3D(
                min: Vec3(x: -10, y: -10, z: -10),
                max: Vec3(x: 10, y: 10, z: 10)
            ),
            modelSpin: quarterTurn
        ))

        #expect(abs(hit.point.x - 10) < 1.0e-5)
        #expect(abs(hit.point.y) < 1.0e-5)
        #expect(hit.normal.x > 0.999)
        #expect(abs(hit.normal.y) < 1.0e-5)
    }

    @Test
    func syntheticPicksUpdatePourAndMasterSettingsWithFineAdjustValues() {
        let hit = MotherMoldSurfacePlacement.Hit(
            point: Vec3(x: 7.5, y: -4.25, z: 12),
            normal: Vec3(x: 0, y: 1, z: 0)
        )

        let pour = MotherMoldSurfacePlacement.applying(
            hit,
            target: .pourHole,
            to: MotherMoldSettings.defaultValue
        )
        #expect(pour.spout.mode == .manual)
        #expect(pour.spout.manualSpout == hit.point)

        let production = MotherMoldSurfacePlacement.applying(
            hit,
            target: .masterMount,
            to: MotherMoldUIContract.applying(
                .productionTooling,
                to: MotherMoldSettings.defaultValue
            )
        )
        #expect(production.masterPreparation.placementMode == .manual)
        #expect(production.masterPreparation.manualPoint == Vec3Codable(x: 7.5, y: -4.25, z: 12))
        #expect(production.masterPreparation.manualAxis == Vec3Codable(x: 0, y: 1, z: 0))
    }

    @Test
    func clickPlacementDoesNotChangeManualPartingPlanes() {
        var original = MotherMoldSettings.defaultValue
        original.parts = .four
        original.parting.mode = .manual
        original.parting.planes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: -2, isManual: true),
            PartitionPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 6, isManual: true),
        ]
        let expectedParting = original.parting
        let hit = MotherMoldSurfacePlacement.Hit(
            point: Vec3(x: 5, y: 4, z: 3),
            normal: Vec3(x: 0, y: 0, z: 1)
        )

        let pour = MotherMoldSurfacePlacement.applying(hit, target: .pourHole, to: original)
        let mount = MotherMoldSurfacePlacement.applying(hit, target: .masterMount, to: original)
        #expect(pour.parting == expectedParting)
        #expect(mount.parting == expectedParting)
    }

    @Test
    func pickedMasterGetsASettingsDrivenViewportMarker() throws {
        let hit = MotherMoldSurfacePlacement.Hit(
            point: Vec3(x: 10, y: 2, z: 3),
            normal: Vec3(x: 1, y: 0, z: 0)
        )
        let settings = MotherMoldSurfacePlacement.applying(
            hit,
            target: .masterMount,
            to: MotherMoldUIContract.applying(
                .productionTooling,
                to: MotherMoldSettings.defaultValue
            )
        )
        let overlay = try #require(MotherMoldPrebuildOverlay.make(
            model: Self.model,
            settings: settings,
            planeResolver: { _, _, _ in [] }
        ))

        #expect(overlay.masterMountMarker?.point == hit.point)
        #expect(overlay.masterMountMarker?.axis == hit.normal)
        #expect(MotherMoldUIContract.manualMountPlacementLabel == "Pick on model")
        #expect(!MotherMoldUIContract.supportsManualProductionFlowPlacement)
        #expect(!MotherMoldUIContract.supportsManualToolingSupportPlacement)
    }

    private static let xFacingTriangle = MeshGeometryData(
        vertices: [
            Vec3(x: 10, y: -10, z: -10),
            Vec3(x: 10, y: 10, z: -10),
            Vec3(x: 10, y: 0, z: 10),
        ],
        triangleIndices: [0, 1, 2]
    )

    private static let model: MeshSummary = {
        let bounds = Bounds3D(
            min: Vec3(x: -10, y: -10, z: -10),
            max: Vec3(x: 10, y: 10, z: 10)
        )
        return MeshSummary(
            name: "m4-triangle",
            path: "/tmp/m4-triangle.stl",
            format: "STL",
            byteCount: 0,
            vertexObservationCount: xFacingTriangle.vertices.count,
            faceCount: 1,
            triangleCount: 1,
            bounds: bounds,
            geometry: xFacingTriangle,
            preflight: MeshPreflight.analyze(geometry: xFacingTriangle)
        )
    }()
}
