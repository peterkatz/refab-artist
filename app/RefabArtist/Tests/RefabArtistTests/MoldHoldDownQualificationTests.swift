import XCTest
@testable import RefabArtist

final class MoldHoldDownQualificationTests: XCTestCase {
    func testAnalyticBoxFullBuoyancyHasExpectedUpwardForce() throws {
        let input = try boxInput()
        let sourceBeforeEvaluation = input.sourceMaster
        let result = try MoldHoldDownQualification.evaluate(input)
        let full = try XCTUnwrap(result.fillStates.last)

        XCTAssertEqual(input.sourceMaster, sourceBeforeEvaluation)
        // 10 mm cubed = 1 cc. At 1 g/cc its buoyant force is 9.80665 mN.
        XCTAssertEqual(full.displacedSiliconeVolumeCubicMillimeters, 1_000, accuracy: 1.0e-6)
        XCTAssertEqual(try XCTUnwrap(full.centerOfBuoyancy).z, 0, accuracy: 1.0e-6)
        XCTAssertEqual(full.measuredWrench.forceNewtons.x, 0, accuracy: 1.0e-9)
        XCTAssertEqual(full.measuredWrench.forceNewtons.y, 0, accuracy: 1.0e-9)
        XCTAssertEqual(full.measuredWrench.forceNewtons.z, 0.00980665, accuracy: 1.0e-8)
    }

    func testOffAxisHoldDownMeasuresMomentArm() throws {
        var input = try boxInput()
        input.holdDownPoint = Vec3Codable(x: 2, y: 0, z: -5)
        let result = try MoldHoldDownQualification.evaluate(input)
        let full = try XCTUnwrap(result.fillStates.last)

        // r = (-2, 0, 5), F = (0, 0, 0.00980665), so r x F has +Y moment.
        XCTAssertEqual(full.measuredWrench.momentNewtonMillimeters.x, 0, accuracy: 1.0e-8)
        XCTAssertEqual(full.measuredWrench.momentNewtonMillimeters.y, 0.0196133, accuracy: 1.0e-8)
        XCTAssertEqual(full.measuredWrench.momentNewtonMillimeters.z, 0, accuracy: 1.0e-8)
    }

    func testFillProgressionIncludesEndpointsAndOneMillimeterInteriorSamples() throws {
        let result = try MoldHoldDownQualification.evaluate(try boxInput())

        XCTAssertEqual(result.fillStates.count, 11)
        XCTAssertEqual(try XCTUnwrap(result.fillStates.first).fillFraction, 0, accuracy: 1.0e-12)
        XCTAssertEqual(try XCTUnwrap(result.fillStates.last).fillFraction, 1, accuracy: 1.0e-12)
        XCTAssertEqual(result.fillStates[5].fillFraction, 0.5, accuracy: 1.0e-12)
        XCTAssertEqual(result.fillStates[5].displacedSiliconeVolumeCubicMillimeters, 500, accuracy: 1.0e-6)
        XCTAssertEqual(result.fillStates.map(\.fillFraction), result.fillStates.map(\.fillFraction).sorted())
    }

    func testCalibratedEnvelopeChoosesDeterministicWorstCombinedCase() throws {
        let capacity = HoldDownCapacityInput(
            evidence: .calibrated,
            envelope: HoldDownCapacityEnvelopeInput(
                profileID: "test-profile",
                ratedAxialForceNewtons: 0.02,
                ratedShearForceNewtons: 1,
                ratedBendingMomentNewtonMillimeters: 1,
                ratedTorsionMomentNewtonMillimeters: 1
            )
        )
        let first = try MoldHoldDownQualification.evaluate(try boxInput(capacity: capacity))
        let second = try MoldHoldDownQualification.evaluate(try boxInput(capacity: capacity))

        XCTAssertEqual(first.wrenchEnvelope, second.wrenchEnvelope)
        XCTAssertEqual(first.wrenchEnvelope.qualification, .qualified)
        XCTAssertEqual(first.wrenchEnvelope.worstCaseID, "liner-fill-0010-handling-0")
        XCTAssertEqual(try XCTUnwrap(first.wrenchEnvelope.maximumUtilization), 0.4903325, accuracy: 1.0e-6)
    }

    func testUndersizedCalibratedEnvelopeIsBlocked() throws {
        let capacity = HoldDownCapacityInput(
            evidence: .calibrated,
            envelope: HoldDownCapacityEnvelopeInput(
                profileID: "undersized-profile",
                ratedAxialForceNewtons: 0.001,
                ratedShearForceNewtons: 1,
                ratedBendingMomentNewtonMillimeters: 1,
                ratedTorsionMomentNewtonMillimeters: 1
            )
        )
        let result = try MoldHoldDownQualification.evaluate(try boxInput(capacity: capacity))

        XCTAssertEqual(result.wrenchEnvelope.qualification, .blocked)
        XCTAssertGreaterThan(try XCTUnwrap(result.wrenchEnvelope.maximumUtilization), 1)
    }

    func testInvalidAxesDensityAndOpenMeshProduceActionableErrors() throws {
        var zeroAxis = try boxInput()
        zeroAxis.linerFillUpAxis = Vec3Codable()
        XCTAssertThrowsError(try MoldHoldDownQualification.evaluate(zeroAxis)) { error in
            XCTAssertEqual(error as? MoldHoldDownQualificationError, .zeroAxis("Liner-fill up axis"))
        }

        var zeroDensity = try boxInput()
        zeroDensity.siliconeDensityGramsPerCC = 0
        XCTAssertThrowsError(try MoldHoldDownQualification.evaluate(zeroDensity)) { error in
            XCTAssertEqual(error as? MoldHoldDownQualificationError, .invalidSiliconeDensity)
        }

        let openMesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 0, y: 0, z: 1),
            ],
            triangleIndices: [0, 1, 2]
        )
        var openInput = try boxInput()
        openInput.sourceMaster = openMesh
        XCTAssertThrowsError(try MoldHoldDownQualification.evaluate(openInput)) { error in
            guard case .sourceNotWatertight(_) = error as? MoldHoldDownQualificationError else {
                return XCTFail("Expected a watertight-source error, got \(error)")
            }
        }
    }

    func testMissingMassOrCapacityNeverClaimsQualification() throws {
        let calibrated = HoldDownCapacityInput(
            evidence: .calibrated,
            envelope: HoldDownCapacityEnvelopeInput(
                profileID: "test-profile",
                ratedAxialForceNewtons: 1,
                ratedShearForceNewtons: 1,
                ratedBendingMomentNewtonMillimeters: 1,
                ratedTorsionMomentNewtonMillimeters: 1
            )
        )
        let missingMass = try MoldHoldDownQualification.evaluate(
            try boxInput(masterMassGrams: nil, masterCenterOfGravity: nil, capacity: calibrated)
        )
        let missingCapacity = try MoldHoldDownQualification.evaluate(
            try boxInput(capacity: HoldDownCapacityInput())
        )

        XCTAssertEqual(missingMass.wrenchEnvelope.qualification, .notMeasured)
        XCTAssertNotEqual(missingMass.wrenchEnvelope.qualification, .qualified)
        XCTAssertEqual(missingCapacity.wrenchEnvelope.qualification, .geometryOnly)
        XCTAssertNotEqual(missingCapacity.wrenchEnvelope.qualification, .qualified)
    }

    func testExternalFixtureIsKeptSeparateFromPrintedQualification() throws {
        let external = HoldDownCapacityInput(evidence: .externalFixture)
        let result = try MoldHoldDownQualification.evaluate(try boxInput(capacity: external))

        XCTAssertEqual(result.wrenchEnvelope.qualification, .external)
        XCTAssertNil(result.wrenchEnvelope.maximumUtilization)
    }

    private func boxInput(
        masterMassGrams: Double? = 0,
        masterCenterOfGravity: Vec3Codable? = Vec3Codable(),
        capacity: HoldDownCapacityInput = HoldDownCapacityInput()
    ) throws -> MoldHoldDownQualificationInput {
        let box = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: 10, y: 10, z: 10)
            )
        )
        return MoldHoldDownQualificationInput(
            sourceMaster: try ManifoldEngine.toMesh(box),
            linerFillUpAxis: Vec3Codable(x: 0, y: 0, z: 1),
            holdDownPoint: Vec3Codable(x: 0, y: 0, z: -5),
            mountAxis: Vec3Codable(x: 0, y: 0, z: 1),
            siliconeDensityGramsPerCC: 1,
            masterMassGrams: masterMassGrams,
            masterCenterOfGravity: masterCenterOfGravity,
            capacity: capacity,
            fluidLoadSafetyFactor: 1,
            handlingForceNewtons: 0
        )
    }
}
