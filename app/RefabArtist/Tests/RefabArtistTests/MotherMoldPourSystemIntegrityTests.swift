import XCTest
@testable import RefabArtist

final class MotherMoldPourSystemIntegrityTests: XCTestCase {
    private struct SplitShellFixture {
        var parts: [MotherMoldPart]
        var cavity: MeshGeometryData
        var openPlane: PartitionPlane
    }

    private struct MultiWallFixture {
        var parts: [MotherMoldPart]
        var cavity: MeshGeometryData
        var openPlane: PartitionPlane
    }

    func testManualSpoutOnASeamIsRejectedWithoutCarvingEitherMoldPart() throws {
        let fixture = try makeSplitShellFixture()
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 6,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 10
        )

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 7
        )

        XCTAssertFalse(result.spoutBored, "A seam-centered funnel must not open a neighboring mold half.")
        XCTAssertEqual(result.parts, fixture.parts, "Rejected placement must roll back every bore and funnel change.")
        XCTAssertTrue(
            result.diagnostics.contains {
                $0.message.localizedCaseInsensitiveContains("seam")
                    || $0.message.localizedCaseInsensitiveContains("neighbor")
            },
            "The artist needs a plain explanation that the spout must move away from the seam."
        )
    }

    func testManualSpoutAwayFromTheSeamBuildsOneNonOverlappingFunnelAndOneSidedBore() throws {
        let fixture = try makeSplitShellFixture()
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 2,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: -7,
            manualSpoutY: 0,
            manualSpoutZ: 10
        )

        let bottomProbe = ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: -11),
            extents: Vec3(x: 30, y: 30, z: 2)
        )
        let bottomBefore = try materialVolume(of: fixture.parts, inside: bottomProbe)

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 7
        )

        XCTAssertTrue(result.spoutBored, "A valid one-part placement must reach the cavity.")
        XCTAssertEqual(result.parts.count, 2)
        XCTAssertGreaterThan(result.parts.flatMap(\.geometry.vertices).map(\.z).max() ?? 0, 20)
        XCTAssertLessThanOrEqual(try pairwisePositiveOverlapVolume(result.parts), 1.0e-5)

        let throatProbe = ManifoldBoxSpec(
            center: Vec3(x: -7, y: 0, z: 15),
            extents: Vec3(x: 0.5, y: 0.5, z: 12)
        )
        XCTAssertLessThanOrEqual(
            try materialVolume(of: result.parts, inside: throatProbe),
            1.0e-5,
            "The funnel throat must remain open from the cavity to the exterior."
        )

        XCTAssertEqual(
            try materialVolume(of: result.parts, inside: bottomProbe),
            bottomBefore,
            accuracy: 1.0e-5,
            "A one-sided spout must not remove material from the far wall or mold floor."
        )
    }

    func testManualSpoutRejectsAMultiWallCylinderAndLeavesGeometryUnchanged() throws {
        let fixture = try makeMultiWallFixture()
        XCTAssertEqual(
            faceConnectedComponentCount(of: fixture.parts[0].geometry),
            1,
            "The regression fixture must begin as one connected solid."
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 4,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 16
        )

        let beforeVolume = try materialVolume(of: fixture.parts)
        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 11
        )

        XCTAssertFalse(result.spoutBored, "A cylinder that spans two wall regions must be rejected.")
        XCTAssertEqual(result.parts, fixture.parts, "Rejected geometry must roll back every bore attempt.")
        XCTAssertEqual(try materialVolume(of: result.parts), beforeVolume, accuracy: 1.0e-6)
        XCTAssertTrue(
            result.diagnostics.contains {
                $0.severity == .warning
                    && $0.message.localizedCaseInsensitiveContains("2 separate wall regions")
            },
            "The rejection must explain the measured wall count in artist-facing language."
        )
    }

    func testRigidShellUsesAControlledFillGateAndDoesNotOpenTheFarWall() throws {
        let fixture = try makeSplitShellFixture()
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 2,
            ventCount: 2,
            ventDiameter: 2,
            manualSpoutX: -7,
            manualSpoutY: 0,
            manualSpoutZ: 10
        )

        let bottomProbe = ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: -11),
            extents: Vec3(x: 30, y: 30, z: 2)
        )
        let bottomBefore = try materialVolume(of: fixture.parts, inside: bottomProbe)

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 0
        )

        XCTAssertNotNil(result.spoutLocation)
        XCTAssertTrue(result.spoutBored, "Rigid shells need a controlled sacrificial fill gate instead of a cavity-sized opening.")
        XCTAssertEqual(result.ventLocations.count, 2)
        XCTAssertEqual(result.ventsBoredCount, 2, "Both requested vents remove real shell volume.")
        XCTAssertFalse(result.diagnostics.contains { $0.message.localizedCaseInsensitiveContains("open pour face") })

        let bottomAfter = try materialVolume(of: result.parts, inside: bottomProbe)
        XCTAssertEqual(
            bottomAfter,
            bottomBefore,
            accuracy: 1.0e-5,
            "The fill gate and vents must not continue through the far wall or mold floor."
        )
    }

    func testVentCountIgnoresAABBOnlyIntersection() throws {
        let part = try makeGappedPart()
        let ventSurface = MeshGeometryData(
            vertices: [Vec3(x: 0, y: 0, z: 0)],
            triangleIndices: []
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .auto,
            spoutDiameter: 2,
            ventCount: 1,
            ventDiameter: 2,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 0
        )
        let openPlane = PartitionPlane(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: 0,
            isManual: false
        )
        let volumeBefore = try materialVolume(of: [part])

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: [part],
            cavity: ventSurface,
            openPlane: openPlane,
            settings: settings,
            seed: 0
        )

        XCTAssertTrue(result.ventLocations.isEmpty, "A failed vent candidate must not be surfaced as a guide location.")
        XCTAssertEqual(
            result.ventsBoredCount,
            0,
            "A bounds hit without positive removed volume is not a bored vent."
        )
        XCTAssertEqual(try materialVolume(of: result.parts), volumeBefore, accuracy: 1.0e-6)
        XCTAssertTrue(
            result.diagnostics.contains { $0.severity == .info && $0.message.localizedCaseInsensitiveContains("Bored 0 of 1 requested one-sided vents") },
            "An unresolved requested vent must be reported for the planner's blocking export decision."
        )
    }

    func testAutomaticVentsKeepSearchingAfterFailedCandidates() throws {
        let fixture = try makeMultiWallVentFixture()
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 4,
            ventCount: 1,
            ventDiameter: 2.5,
            manualSpoutX: 20,
            manualSpoutY: 0,
            manualSpoutZ: 16
        )

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 2
        )

        XCTAssertFalse(result.spoutBored, "The far-away manual spout should not change this vent retry case.")
        XCTAssertEqual(result.ventLocations.count, 1, "Only the successfully bored vent may be surfaced as a guide location.")
        XCTAssertEqual(result.ventsBoredCount, 1, "A later safe vent candidate must still be counted.")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .info && $0.message.localizedCaseInsensitiveContains("Bored 1 of 1 requested one-sided vents") })
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .info && $0.message.localizedCaseInsensitiveContains("skipped 1 unsafe vent") })
        XCTAssertFalse(
            result.diagnostics.contains {
                $0.severity == .warning && $0.message.localizedCaseInsensitiveContains("vent")
            },
            "Recovered Auto candidates must not leave the artist with a false warning state."
        )
    }

    func testSpoutCountRejectsDisconnectedFunnelThatNeverBoresShell() throws {
        let part = try makeGappedPart()
        let cavity = MeshGeometryData(
            vertices: [Vec3(x: 0, y: 0, z: 0)],
            triangleIndices: []
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 2,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 0
        )
        let openPlane = PartitionPlane(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: 0,
            isManual: false
        )
        let volumeBefore = try materialVolume(of: [part])

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: [part],
            cavity: cavity,
            openPlane: openPlane,
            settings: settings,
            seed: 0
        )

        XCTAssertFalse(
            result.spoutBored,
            "A detached funnel inside the part AABB is not a fill channel into the cavity."
        )
        XCTAssertEqual(try materialVolume(of: result.parts), volumeBefore, accuracy: 1.0e-6)
        XCTAssertTrue(
            result.diagnostics.contains { $0.severity == .warning && $0.message.localizedCaseInsensitiveContains("spout") },
            "A spout that removes no shell volume must be diagnosed."
        )
    }

    func testManualSpoutRejectsCandidateThatWouldCompromiseGeneratedLocator() throws {
        let fixture = try makeSplitShellFixture()
        let locator = try generatedLocator(center: Vec3(x: -7, y: 0, z: 11))
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .manual,
            spoutDiameter: 2,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: -7,
            manualSpoutY: 0,
            manualSpoutZ: 10
        )

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: fixture.cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 7,
            protectedLocator: locator
        )

        XCTAssertFalse(result.spoutBored)
        XCTAssertEqual(result.parts, fixture.parts)
        XCTAssertTrue(result.diagnostics.contains {
            $0.severity == .warning
                && $0.message.localizedCaseInsensitiveContains("generated locator")
                && $0.message.localizedCaseInsensitiveContains("move")
        })
    }

    func testAutoSpoutKeepsSearchingAfterProtectedLocatorCandidateIsRejected() throws {
        let fixture = try makeSplitShellFixture()
        let locator = try generatedLocator(center: Vec3(x: -7, y: 0, z: 11))
        let cavity = MeshGeometryData(
            vertices: [
                Vec3(x: -7, y: 0, z: 10),
                Vec3(x: 7, y: 0, z: 10),
            ],
            triangleIndices: []
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 2
        settings.siliconeGap = 0
        settings.smoothing = 0
        settings.spout = SpoutSettings(
            mode: .auto,
            spoutDiameter: 2,
            ventCount: 0,
            ventDiameter: 2,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 0
        )

        let result = try MoldFeatureBuilder.applyFeatures(
            parts: fixture.parts,
            cavity: cavity,
            openPlane: fixture.openPlane,
            settings: settings,
            seed: 7,
            protectedLocator: locator
        )

        XCTAssertTrue(result.spoutBored)
        XCTAssertEqual(result.spoutLocation, Vec3(x: 7, y: 0, z: 10))
        XCTAssertTrue(result.diagnostics.contains {
            $0.severity == .info && $0.message.localizedCaseInsensitiveContains("generated locator")
        })
        XCTAssertFalse(result.diagnostics.contains {
            $0.severity == .warning && $0.message.localizedCaseInsensitiveContains("generated locator")
        })
    }

    func testHealedHandFourPartJacketBuildsConnectedFillChannel() throws {
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .four

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        XCTAssertTrue(plan.spoutBored, "Every jacket matrix build needs a real cavity-to-exterior fill channel.")
        XCTAssertFalse(plan.diagnostics.contains {
            $0.severity == .error && $0.message.localizedCaseInsensitiveContains("no fill channel")
        })
        for part in plan.parts {
            XCTAssertTrue(MeshPreflight.analyze(geometry: part.geometry).isWatertight, part.name)
            XCTAssertEqual(MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry).droppedCount, 0, part.name)
        }
    }

    private func makeSplitShellFixture() throws -> SplitShellFixture {
        let outer = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: 24, y: 24, z: 24)
            )
        )
        let cavityHandle = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: 20, y: 20, z: 20)
            )
        )
        let shell = try ManifoldEngine.difference(outer, cavityHandle)
        let (left, right) = try ManifoldEngine.splitByPlane(
            shell,
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0
        )
        let cavity = try ManifoldEngine.toMesh(cavityHandle)
        let parts = try [left, right].enumerated().map { index, handle in
            MotherMoldPart(
                name: index == 0 ? "mold-part-A" : "mold-part-B",
                geometry: try ManifoldEngine.toMesh(handle),
                isWatertight: true,
                bounds: ManifoldEngine.bounds(handle)
            )
        }
        return SplitShellFixture(
            parts: parts,
            cavity: cavity,
            openPlane: PartitionPlane(
                normal: Vec3(x: 0, y: 0, z: 1),
                offset: 10,
                isManual: false
            )
        )
    }

    private func makeMultiWallFixture() throws -> MultiWallFixture {
        let leftSlab = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: -2.5, y: 0, z: 8),
                extents: Vec3(x: 1.5, y: 5, z: 16)
            )
        )
        let rightSlab = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 2.5, y: 0, z: 8),
                extents: Vec3(x: 1.5, y: 5, z: 16)
            )
        )
        let bridge = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 2),
                extents: Vec3(x: 8, y: 2, z: 4)
            )
        )
        let upperPair = try ManifoldEngine.union(leftSlab, rightSlab)
        let combined = try ManifoldEngine.union(upperPair, bridge)
        let geometry = try ManifoldEngine.toMesh(combined)
        return MultiWallFixture(
            parts: [
                MotherMoldPart(
                    name: "multi-wall-solid",
                    geometry: geometry,
                    isWatertight: true,
                    bounds: ManifoldEngine.bounds(combined)
                )
            ],
            cavity: geometry,
            openPlane: PartitionPlane(
                normal: Vec3(x: 0, y: 0, z: 1),
                offset: 16,
                isManual: false
            )
        )
    }

    private func faceConnectedComponentCount(of geometry: MeshGeometryData) -> Int {
        let disconnected = MoldComponentFilter.dropFaceDisconnectedDebris(geometry)
        return disconnected.droppedCount > 0 ? disconnected.droppedCount + 1 : (geometry.triangleIndices.isEmpty ? 0 : 1)
    }

    private func makeMultiWallVentFixture() throws -> MultiWallFixture {
        let outer = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: 10, y: 10, z: 10)
            )
        )
        let inner = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: 8, y: 8, z: 8)
            )
        )
        let combined = try ManifoldEngine.difference(outer, inner)
        let geometry = try ManifoldEngine.toMesh(combined)
        return MultiWallFixture(
            parts: [
                MotherMoldPart(
                    name: "vent-retry-shell",
                    geometry: geometry,
                    isWatertight: true,
                    bounds: ManifoldEngine.bounds(combined)
                )
            ],
            cavity: MeshGeometryData(
                vertices: [
                    Vec3(x: 12, y: 0, z: 0),
                    Vec3(x: 0, y: 0, z: 0)
                ],
                triangleIndices: []
            ),
            openPlane: PartitionPlane(
                normal: Vec3(x: 1, y: 0, z: 0),
                offset: 10,
                isManual: false
            )
        )
    }

    private func makeGappedPart() throws -> MotherMoldPart {
        let left = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: -5, y: 0, z: 1),
                extents: Vec3(x: 4, y: 4, z: 4)
            )
        )
        let right = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 5, y: 0, z: 1),
                extents: Vec3(x: 4, y: 4, z: 4)
            )
        )
        let combined = try ManifoldEngine.union(left, right)
        return MotherMoldPart(
            name: "gapped-part",
            geometry: try ManifoldEngine.toMesh(combined),
            isWatertight: true,
            bounds: ManifoldEngine.bounds(combined)
        )
    }

    private func generatedLocator(center: Vec3) throws -> MeshGeometryData {
        let locator = try ManifoldEngine.box(
            ManifoldBoxSpec(center: center, extents: Vec3(x: 4, y: 4, z: 2))
        )
        return try ManifoldEngine.toMesh(locator)
    }

    private func materialVolume(of parts: [MotherMoldPart]) throws -> Double {
        try parts.reduce(into: 0.0) { total, part in
            let handle = try ManifoldEngine.make(from: part.geometry)
            total += abs(ManifoldEngine.volume(handle))
        }
    }

    private func materialVolume(
        of parts: [MotherMoldPart],
        inside probeSpec: ManifoldBoxSpec
    ) throws -> Double {
        let probe = try ManifoldEngine.box(probeSpec)
        return try parts.reduce(into: 0.0) { total, part in
            let handle = try ManifoldEngine.make(from: part.geometry)
            let intersection = try ManifoldEngine.intersect(handle, probe)
            total += abs(ManifoldEngine.volume(intersection))
        }
    }

    private func pairwisePositiveOverlapVolume(_ parts: [MotherMoldPart]) throws -> Double {
        guard parts.count > 1 else { return 0 }
        var total = 0.0
        for firstIndex in 0..<(parts.count - 1) {
            let first = try ManifoldEngine.make(from: parts[firstIndex].geometry)
            for secondIndex in (firstIndex + 1)..<parts.count {
                let second = try ManifoldEngine.make(from: parts[secondIndex].geometry)
                let intersection = try ManifoldEngine.intersect(first, second)
                total += abs(ManifoldEngine.volume(intersection))
            }
        }
        return total
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: "docs/PRD.md").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
