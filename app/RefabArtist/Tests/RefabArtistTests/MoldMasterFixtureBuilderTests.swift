import XCTest
@testable import RefabArtist

final class MoldMasterFixtureBuilderTests: XCTestCase {
    func testTwoAndFourPartPlanesBuildDeterministicSplitCollars() throws {
        let two = try standardInput(planes: [plane(.x, offset: 0)])
        let four = try standardInput(planes: [plane(.x, offset: 0), plane(.y, offset: 0)])

        let first = try MoldMasterFixtureBuilder.build(two)
        let second = try MoldMasterFixtureBuilder.build(two)
        let fourPart = try MoldMasterFixtureBuilder.build(four)

        XCTAssertEqual(first.kind, .fixture)
        XCTAssertEqual(first.status, .geometryOnly)
        XCTAssertEqual(first.collarHalves.count, 2)
        XCTAssertEqual(first.collarHalves, second.collarHalves)
        XCTAssertEqual(fourPart.collarHalves.count, 2)
        XCTAssertTrue(fourPart.collarHalves.allSatisfy { MotherMoldValidation.printablePreflight($0).isWatertight })
    }

    func testPlaneThatDoesNotCrossCollarFailsWithActionableError() throws {
        let input = try standardInput(planes: [plane(.z, offset: 100)])
        XCTAssertThrowsError(try MoldMasterFixtureBuilder.build(input)) { error in
            XCTAssertEqual(error as? MoldMasterFixtureBuilder.Error, .collarIsNotSplit)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("splits the collar") == true)
        }
    }

    func testCollarSplitFailurePrecedesNominalShellWallConsumption() throws {
        var input = try standardInput(planes: [plane(.z, offset: 100)])
        input.wholeShell = try shellWithoutDryPostPath(sourceExtent: 54)

        XCTAssertThrowsError(try MoldMasterFixtureBuilder.build(input)) { error in
            XCTAssertEqual(error as? MoldMasterFixtureBuilder.Error, .collarIsNotSplit)
        }
    }

    func testReceiverRejectsUnreservedNominalShellWall() throws {
        var input = try standardInput()
        input.wholeShell = try shellWithoutDryPostPath(sourceExtent: 54)

        XCTAssertThrowsError(try MoldMasterFixtureBuilder.build(input)) { error in
            guard case .protectedGeometryConsumed(let message) = error as? MoldMasterFixtureBuilder.Error else {
                return XCTFail("Expected protected nominal-shell-wall rejection, got \(error)")
            }
            XCTAssertTrue(message.contains("nominal shell wall"))
        }
    }

    func testDryPostReservationMakesUnreservedShellBuildableAndIsIdempotent() throws {
        var input = try standardInput()
        // The source is 40 mm and the requested liner is 6 mm per side. Keep
        // the synthetic cavity outside that envelope so this test isolates the
        // dry-post reservation instead of introducing an unrelated collision.
        input.wholeShell = try shellWithoutDryPostPath(sourceExtent: 54)

        let first = try MoldMasterFixtureBuilder.reserveDryPostPath(
            wholeShell: input.wholeShell,
            preparedMaster: input.preparedMaster,
            settings: input.settings
        )
        let second = try MoldMasterFixtureBuilder.reserveDryPostPath(
            wholeShell: first.wholeShell,
            preparedMaster: input.preparedMaster,
            settings: input.settings
        )

        XCTAssertEqual(first.wholeShell, second.wholeShell)
        XCTAssertEqual(first.path, second.path)
        XCTAssertTrue(MeshPreflight.analyze(geometry: first.wholeShell).isWatertight)
        XCTAssertTrue(MeshPreflight.analyze(geometry: first.path.geometry).isWatertight)
        let shell = try ManifoldEngine.make(from: first.wholeShell)
        let path = try ManifoldEngine.make(from: first.path.geometry)
        XCTAssertEqual(try ManifoldEngine.decompose(shell).count, 1)
        XCTAssertLessThanOrEqual(
            abs(ManifoldEngine.volume(try ManifoldEngine.intersect(shell, path))),
            0.01
        )

        input.wholeShell = first.wholeShell
        let result = try MoldMasterFixtureBuilder.build(input)
        XCTAssertEqual(result.kind, .fixture)
        XCTAssertNotNil(result.wholeShellWithCollar)
    }

    func testRoundedDReceiverAndCrossPinConstrainFixture() throws {
        let result = try MoldMasterFixtureBuilder.build(try standardInput())
        let receiver = try XCTUnwrap(result.receiver)
        let motion = try XCTUnwrap(result.motion)
        let yoke = try XCTUnwrap(result.yoke)
        let pin = try XCTUnwrap(result.crossPin)

        XCTAssertNotEqual(receiver.profile.widthMillimeters, receiver.profile.thicknessMillimeters, "The receiver must retain the rounded-D anti-rotation profile.")
        XCTAssertTrue(motion.crossPinThroughEarPostEar)
        XCTAssertTrue(motion.yokeSideEscapeBlocked)
        XCTAssertTrue(MotherMoldValidation.printablePreflight(yoke.geometry).isWatertight)
        XCTAssertEqual(pin.kind, .removableCrossPin)
        XCTAssertEqual(pin.quantity, 1)
        XCTAssertTrue(pin.uses.contains(.preparedMasterHoldDown))
        XCTAssertTrue(pin.uses.contains(.castingFunnelRetention))
        XCTAssertTrue(pin.matchesFixtureRequirement())
        XCTAssertTrue(pin.specification.contains("do not print"))
        XCTAssertEqual(receiver.pin.id, "ear-post-ear-cross-pin")
    }

    func testMeasuredClearanceAndSixDegreeOfFreedomLimitsAreReported() throws {
        let input = try standardInput()
        let result = try MoldMasterFixtureBuilder.build(input)
        let clearance = try XCTUnwrap(result.clearance)
        let collisions = try XCTUnwrap(result.collisions)
        let motion = try XCTUnwrap(result.motion)

        XCTAssertEqual(clearance.measuredWidthMillimeters, input.settings.masterPreparation.fitClearance, accuracy: 0.05)
        XCTAssertEqual(clearance.measuredThicknessMillimeters, input.settings.masterPreparation.fitClearance, accuracy: 0.05)
        XCTAssertTrue(clearance.passes)
        XCTAssertTrue(collisions.passes)
        XCTAssertLessThanOrEqual(collisions.shellAndCollarCubicMillimeters, collisions.toleranceCubicMillimeters)
        XCTAssertLessThanOrEqual(motion.maximumTranslationMillimeters, clearance.configuredMillimeters + 0.05)
        XCTAssertLessThanOrEqual(motion.maximumAngularPlayDegrees, 1)
        XCTAssertTrue(motion.translationsPass)
        XCTAssertTrue(motion.angularPlayPass)
    }

    func testProductionGateHandoffUsesPreparedMasterAxialStations() throws {
        let input = try standardInput()
        let result = try MoldMasterFixtureBuilder.build(input)
        let gate = try XCTUnwrap(result.productionGate)
        let dimensions = try XCTUnwrap(input.preparedMaster.fixtureDimensions)
        let mount = try XCTUnwrap(input.preparedMaster.selectedMount)
        let axis = gate.receiverAxis
        let root = mount.point

        func axialStation(of point: Vec3Codable) -> Double {
            (point.x - root.x) * axis.x + (point.y - root.y) * axis.y + (point.z - root.z) * axis.z
        }

        XCTAssertEqual(axialStation(of: gate.linerSealPoint), dimensions.axialStations.siliconeOuterMillimeters, accuracy: 0.000_001)
        XCTAssertEqual(axialStation(of: gate.rigidStopContactPoint), dimensions.axialStations.shellOuterMillimeters, accuracy: 0.000_001)
        XCTAssertLessThan(axialStation(of: gate.linerSealPoint), axialStation(of: gate.rigidStopContactPoint))
        XCTAssertLessThan(axialStation(of: gate.rigidStopContactPoint), axialStation(of: gate.collarExteriorPoint))

        let registrationDatum = try MoldLinerRegistrationGateLipDatum(fixture: result)
        XCTAssertEqual(registrationDatum.linerSealPoint, gate.linerSealPoint)
        XCTAssertEqual(registrationDatum.rigidStopContactPoint, gate.rigidStopContactPoint)
    }

    func testReleaseOrderAndSealLandAreExplicit() throws {
        let input = try standardInput()
        let result = try MoldMasterFixtureBuilder.build(input)
        let release = try XCTUnwrap(result.release)
        let receiver = try XCTUnwrap(result.receiver)

        XCTAssertTrue(release.wrongOrderPinThenShellFails)
        XCTAssertTrue(release.pinRemovalAllowsYokeRemoval)
        XCTAssertTrue(release.yokeRemovalAllowsCollarHalfRelease)
        XCTAssertFalse(release.fullMasterReleaseProved, "This bounded pre-partition stage must not claim final master release.")
        XCTAssertEqual(receiver.stop.widthMillimeters, max(8, input.settings.siliconeGap + input.settings.wallThickness, input.settings.masterPreparation.sealLandWidth), accuracy: 0.001)
        XCTAssertTrue(result.retention.allSatisfy { $0.retainedFraction >= $0.requiredFraction })
    }

    func testSocketAndExternalModesReturnHonestNoArtifactStates() throws {
        var socket = try standardInput()
        socket.settings.masterPreparation.sourceMode = .existingPhysical
        socket.settings.masterPreparation.retentionMode = .flatBaseSocket
        let socketResult = try MoldMasterFixtureBuilder.build(socket)
        XCTAssertEqual(socketResult.kind, .notApplicable)
        XCTAssertNil(socketResult.yoke)
        XCTAssertNil(socketResult.wholeShellWithCollar)

        var external = try standardInput()
        external.settings.masterPreparation.retentionMode = .externalFixture
        let externalResult = try MoldMasterFixtureBuilder.build(external)
        XCTAssertEqual(externalResult.kind, .external)
        XCTAssertEqual(externalResult.status, .externalResponsibility)
        XCTAssertNil(externalResult.yoke)
        XCTAssertTrue(externalResult.diagnostics.joined(separator: " ").contains("no fake collar"))
    }

    func testOrganicPreparedPositiveHasTopologyValidProtectedFixtureGeometry() throws {
        let source = try organicPositive()
        let settings = settings()
        let prepared = try PreparedMasterBuilder.build(source: source, settings: settings)
        let shell = try reservedShell(for: prepared, sourceExtent: 50)
        let input = MoldMasterFixtureBuilder.Input(
            wholeShell: shell,
            preparedMaster: prepared,
            settings: settings,
            cavityVolumes: [],
            protectedVolumes: [],
            proposedPartingPlanes: [plane(.y, offset: 0)]
        )
        let result = try MoldMasterFixtureBuilder.build(input)

        XCTAssertEqual(result.status, .geometryOnly)
        XCTAssertTrue(result.protectedAdditives.allSatisfy { MotherMoldValidation.printablePreflight($0.geometry).isWatertight })
        XCTAssertTrue(result.protectedSubtractives.allSatisfy { MotherMoldValidation.printablePreflight($0.geometry).isWatertight })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Casting funnel geometry is intentionally absent") })
    }

    private enum Axis { case x, y, z }

    private func standardInput(planes: [PartitionPlane]? = nil) throws -> MoldMasterFixtureBuilder.Input {
        let source = cube(side: 40)
        let settings = settings()
        let prepared = try PreparedMasterBuilder.build(source: source, settings: settings)
        return MoldMasterFixtureBuilder.Input(
            wholeShell: try reservedShell(for: prepared, sourceExtent: 50),
            preparedMaster: prepared,
            settings: settings,
            cavityVolumes: [],
            protectedVolumes: [],
            proposedPartingPlanes: planes ?? [plane(.x, offset: 0)]
        )
    }

    private func settings() -> MotherMoldSettings {
        var value = MotherMoldSettings.defaultValue
        value.subtype = .siliconeJacket
        value.toolingContractVersion = 3
        value.wallThickness = 4
        value.siliconeGap = 6
        value.masterPreparation = MasterPreparationSettings(
            sourceMode: .preparedPrint,
            retentionMode: .preparedPost,
            placementMode: .manual,
            manualPoint: Vec3Codable(x: 0, y: 0, z: -20),
            manualAxis: Vec3Codable(x: 0, y: 0, z: -1),
            postWidth: 18,
            postThickness: 13.5,
            postFreeLength: 20,
            crossPinDiameter: 4,
            fitClearance: 0.25,
            sealLandWidth: 5
        )
        value.productionFlow.gateDiameter = 12
        return value
    }

    /// A closed whole shell whose existing cavity has a dry-post exit wider
    /// than the receiver, leaving only exterior material for the additive collar bridge.
    private func reservedShell(for prepared: PreparedMasterBuilder.Result, sourceExtent: Double) throws -> MeshGeometryData {
        let outer = try ManifoldEngine.box(ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 90, y: 90, z: 90)))
        let cavity = try ManifoldEngine.box(ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: sourceExtent, y: sourceExtent, z: sourceExtent)))
        // The channel exits the bottom and is wider than the D receiver, but
        // narrower than the collar exterior so the exterior bridge is real.
        let dryPostChannel = try ManifoldEngine.box(ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: -38), extents: Vec3(x: 20, y: 20, z: 32)))
        let shell = try ManifoldEngine.difference(try ManifoldEngine.difference(outer, cavity), dryPostChannel)
        return try ManifoldEngine.toMesh(shell)
    }

    /// A closed shell one wall thick around a cubic cavity, with no dry-post
    /// path cut through it. The cavity must be at least 52 mm (the 40 mm source
    /// plus the 6 mm silicone gap per side): the collar starts 1 mm inside the
    /// configured shell outer face, so a thinner synthetic shell never reaches it.
    private func shellWithoutDryPostPath(sourceExtent: Double) throws -> MeshGeometryData {
        let outerExtent = sourceExtent + 2 * settings().wallThickness
        let outer = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: outerExtent, y: outerExtent, z: outerExtent)
        ))
        let cavity = try ManifoldEngine.box(ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: sourceExtent, y: sourceExtent, z: sourceExtent)))
        return try ManifoldEngine.toMesh(try ManifoldEngine.difference(outer, cavity))
    }

    private func plane(_ axis: Axis, offset: Double) -> PartitionPlane {
        let normal: Vec3
        switch axis {
        case .x: normal = Vec3(x: 1, y: 0, z: 0)
        case .y: normal = Vec3(x: 0, y: 1, z: 0)
        case .z: normal = Vec3(x: 0, y: 0, z: 1)
        }
        return PartitionPlane(normal: normal, offset: offset, isManual: true)
    }

    private func cube(side: Double) -> MeshGeometryData {
        let half = side / 2
        let vertices = [
            Vec3(x: -half, y: -half, z: -half), Vec3(x: half, y: -half, z: -half),
            Vec3(x: half, y: half, z: -half), Vec3(x: -half, y: half, z: -half),
            Vec3(x: -half, y: -half, z: half), Vec3(x: half, y: -half, z: half),
            Vec3(x: half, y: half, z: half), Vec3(x: -half, y: half, z: half),
        ]
        return MeshGeometryData(vertices: vertices, triangleIndices: [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6,
            0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
        ])
    }

    private func organicPositive() throws -> MeshGeometryData {
        let base = try ManifoldEngine.box(ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: -12), extents: Vec3(x: 40, y: 40, z: 16)))
        let sphere = try ManifoldEngine.translate(try ManifoldEngine.sphere(radius: 18, segments: 48), x: 0, y: 0, z: 0)
        return try ManifoldEngine.toMesh(try ManifoldEngine.union(base, sphere))
    }
}
