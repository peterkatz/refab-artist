import XCTest
@testable import RefabArtist

final class MoldToolingSupportBuilderTests: XCTestCase {
    func testStableBoxIsMeasuredWithoutCradle() throws {
        let result = try MoldToolingSupportBuilder.evaluate(try input())
        XCTAssertEqual(result.qualificationState, .stableWithoutCradle)
        XCTAssertEqual(result.summary.state, .stableWithoutCradle)
        XCTAssertTrue(result.artifacts.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(result.summary.minimumSupportMarginMillimeters), 10)
        XCTAssertFalse(result.contacts.isEmpty)
        XCTAssertTrue(result.contacts.allSatisfy { $0.regionAreaSquareMillimeters > 1 })
        XCTAssertTrue(result.contacts.allSatisfy { $0.role == .gravitySupport })
    }

    func testLiquidShiftMakesBareAssemblyUnstableAndGeneratesPhaseStand() throws {
        var value = try input(rigidMass: 1, rigidCenter: Vec3Codable(x: -4, y: 0, z: 0), liquidCenter: Vec3(x: 8, y: 0, z: 0), liquidExtents: Vec3(x: 40, y: 40, z: 10))
        value.minimumSupportMarginMillimeters = 15
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .blocked)
        XCTAssertTrue(result.artifacts.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(result.massStates.last).liquidVolumeCubicMillimeters, 0)
        XCTAssertNotEqual(result.massStates.first?.centerOfGravity, result.massStates.last?.centerOfGravity)
    }

    func testUnknownMassNeverCallsBareAssemblyStableAndRequiresStrapEvidence() throws {
        var value = try input()
        value.rigidArtifacts[0].massGrams = nil
        value.rigidArtifacts[0].centerOfGravity = nil
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertNotEqual(result.qualificationState, .stableWithoutCradle)
        XCTAssertTrue(result.massIntervals.contains { $0.maximumMassGrams == nil })
        XCTAssertEqual(result.strapClampPoints.count, 3)
        XCTAssertTrue(result.summary.notes.joined(separator: " ").contains("strap/clamp"))
    }

    func testTenDegreeTiltCanFailAFlatButNarrowSupport() throws {
        let value = try input(rigidCenter: Vec3Codable(x: 0, y: 0, z: 50), rigidExtents: Vec3(x: 24, y: 24, z: 50), liquidExtents: Vec3(x: 1, y: 1, z: 1))
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .blocked)
        XCTAssertTrue(result.artifacts.isEmpty)
    }

    func testManualPlanePassesSameMeasuredGate() throws {
        var value = try input()
        value.supportMode = .manual
        value.manualSupportPlane = SupportPlaneSettings(origin: Vec3Codable(x: 0, y: 0, z: -5), normal: Vec3Codable(x: 0, y: 0, z: 1))
        let pass = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(pass.qualificationState, .stableWithoutCradle)

        value.manualSupportPlane = SupportPlaneSettings(origin: Vec3Codable(x: 0, y: 0, z: 0), normal: Vec3Codable(x: 0, y: 0, z: 1))
        let fail = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(fail.qualificationState, .blocked)
        XCTAssertTrue(fail.artifacts.isEmpty)
    }

    func testGeneratedCradleHasFiniteContactsIndependentLateralRestraintAndStrapAttachments() throws {
        var value = try input(rigidMass: nil, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0))
        value.printerEnvelope = MoldToolingSupportPrinterEnvelope(profileID: "P", buildExtentsMillimeters: Vec3Codable(x: 200, y: 200, z: 200), minimumFeatureMillimeters: 0.4)
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .printerFitNotChecked)
        XCTAssertGreaterThanOrEqual(result.contacts.filter { $0.role == .gravitySupport }.count, 3)
        XCTAssertGreaterThanOrEqual(result.contacts.filter { $0.role == .lateralRestraint }.count, 3)
        XCTAssertTrue(result.contacts.allSatisfy { $0.regionAreaSquareMillimeters > 1 })
        XCTAssertGreaterThanOrEqual(result.independentConstraintRank, 3)
        XCTAssertEqual(result.strapClampPoints.count, 3)
        XCTAssertTrue(result.artifacts.allSatisfy { $0.role == .supportCradle })
        XCTAssertTrue(result.artifacts.allSatisfy { $0.qualification == .topologyValid })
        XCTAssertTrue(result.contacts.allSatisfy { $0.tangentGapMillimeters.map { $0 <= 0.05 } == true })
        XCTAssertTrue(result.summary.notes.joined(separator: " ").contains("unique seating"))
        let cradle = try ManifoldEngine.make(from: try XCTUnwrap(result.artifacts.first?.geometry))
        let rigid = try ManifoldEngine.make(from: value.rigidArtifacts[0].geometry)
        let overlap = try ManifoldEngine.intersect(cradle, rigid)
        XCTAssertTrue(ManifoldEngine.isEmpty(overlap) || abs(ManifoldEngine.volume(overlap)) < 1e-6)
        XCTAssertEqual(MoldComponentFilter.dropFaceDisconnectedDebris(try XCTUnwrap(result.artifacts.first?.geometry)).droppedCount, 0)
    }

    func testReservedPortRejectsCradleInsteadOfObstructingIt() throws {
        var value = try input(rigidMass: nil, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0))
        value.reservedVolumes = [MoldToolingSupportReservedVolume(id: "port", purpose: "LINER FILL port", geometry: try box(center: Vec3(x: 0, y: 0, z: -8), extents: Vec3(x: 200, y: 200, z: 20)))]
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .supportGeometryOnly)
        XCTAssertEqual(result.summary.state, .pendingMeasurement)
        XCTAssertTrue(result.artifacts.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("No unobstructed cradle") })
    }

    func testPhasesAreIndependentAndPhaseLabeled() throws {
        let liner = try MoldToolingSupportBuilder.evaluate(try input(phase: .linerFill, rigidMass: nil, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0)))
        let casting = try MoldToolingSupportBuilder.evaluate(try input(phase: .casting, gravity: Vec3Codable(x: 0, y: 1, z: 0), rigidMass: nil, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0)))
        XCTAssertEqual(liner.artifacts.first?.id.rawValue, "LINER FILL STAND")
        XCTAssertEqual(casting.artifacts.first?.id.rawValue, "CASTING STAND")
        XCTAssertNotEqual(liner.summary.gravityUpAxis, casting.summary.gravityUpAxis)
    }

    func testOutputIsDeterministic() throws {
        let value = try input(rigidMass: 100, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0))
        XCTAssertEqual(try MoldToolingSupportBuilder.evaluate(value), try MoldToolingSupportBuilder.evaluate(value))
    }

    func testNoFalseStructuralQualificationWithoutMatchingCalibratedEnvelope() throws {
        var value = try input(rigidMass: nil, rigidCenter: Vec3Codable(x: 12, y: 0, z: 0))
        value.printerEnvelope = MoldToolingSupportPrinterEnvelope(profileID: "P", buildExtentsMillimeters: Vec3Codable(x: 200, y: 200, z: 200), minimumFeatureMillimeters: 0.4)
        value.loadEvidence = MoldToolingSupportLoadEvidence(profileID: "P", cradleGeometryFingerprint: "wrong", envelope: ToolingSupportLoadEnvelope(version: 1, qualification: .qualified, handlingSafetyFactor: 1.5), ratedVerticalNewtons: 1e6, ratedLateralNewtons: 1e6, ratedOverturningNewtonMillimeters: 1e6, ratedContactOrStrapNewtons: 1e6)
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .printerFitNotChecked)
        XCTAssertNotEqual(result.summary.state, .qualified)
        XCTAssertTrue(result.artifacts.allSatisfy { $0.qualification == .topologyValid })
    }

    func testNonArtIneligibilityBlocksInsteadOfTouchingTheArtifact() throws {
        var value = try input(rigidMass: nil)
        value.rigidArtifacts[0].permitsCradleContact = false
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .blocked)
        XCTAssertTrue(result.artifacts.isEmpty)
        XCTAssertEqual(result.independentConstraintRank, 0)
    }

    func testDenseSphereGetsConformalMeasuredCradleInsteadOfBlocking() throws {
        var value = try input(rigidMass: nil)
        value.rigidArtifacts[0].geometry = try ManifoldEngine.toMesh(ManifoldEngine.sphere(radius: 20, segments: 64))
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .printerFitNotChecked)
        XCTAssertEqual(result.summary.state, .supportGeometryOnly)
        XCTAssertEqual(result.artifacts.map(\.role), [.supportCradle])
        XCTAssertGreaterThanOrEqual(result.contacts.filter { $0.role == .gravitySupport }.count, 3)
        XCTAssertGreaterThanOrEqual(result.independentConstraintRank, 3)
        XCTAssertEqual(result.strapClampPoints.count, 3)
        XCTAssertTrue(result.contacts.allSatisfy { $0.regionAreaSquareMillimeters > 1e-4 })
        XCTAssertTrue(result.contacts.allSatisfy { $0.tangentGapMillimeters.map { $0 <= 0.05 } == true })
        let cradle = try ManifoldEngine.make(from: try XCTUnwrap(result.artifacts.first?.geometry))
        let rigid = try ManifoldEngine.make(from: value.rigidArtifacts[0].geometry)
        let overlap = try ManifoldEngine.intersect(cradle, rigid)
        XCTAssertTrue(ManifoldEngine.isEmpty(overlap) || abs(ManifoldEngine.volume(overlap)) < 1e-6)
    }

    func testAsymmetricOrganicShellGetsDeterministicConformalCradle() throws {
        let main = try ManifoldEngine.sphere(radius: 20, segments: 48)
        let lobe = try ManifoldEngine.translate(ManifoldEngine.sphere(radius: 12, segments: 36), x: 13, y: 4, z: 3)
        let organic = try ManifoldEngine.toMesh(ManifoldEngine.union(main, lobe))
        var value = try input(rigidMass: nil)
        value.rigidArtifacts[0].geometry = organic
        let first = try MoldToolingSupportBuilder.evaluate(value)
        let second = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.summary.state, .supportGeometryOnly)
        XCTAssertEqual(first.artifacts.map(\.role), [.supportCradle])
        XCTAssertGreaterThanOrEqual(first.independentConstraintRank, 3)
        XCTAssertTrue(first.contacts.allSatisfy { $0.tangentGapMillimeters.map { $0 <= 0.05 } == true })
    }

    func testHighSidePatchIsReachedByGeneratedGeometryBeforeItIsClaimed() throws {
        let value = try input(rigidMass: nil, rigidExtents: Vec3(x: 40, y: 40, z: 60))
        let minimumHeight = value.rigidArtifacts[0].geometry.vertices.map(\.z).min() ?? 0
        let result = try MoldToolingSupportBuilder.evaluate(value)
        let highContacts = result.contacts.filter { $0.role == .lateralRestraint && $0.point.z - minimumHeight > 8 }
        XCTAssertFalse(highContacts.isEmpty)
        XCTAssertTrue(highContacts.allSatisfy { $0.tangentGapMillimeters.map { $0 <= 0.05 } == true })
        XCTAssertTrue(highContacts.allSatisfy { $0.regionAreaSquareMillimeters > 1e-4 })
    }

    func testPrinterEnvelopeDoesNotClaimFeatureValidationWithoutMeasuredOrientationEvidence() throws {
        var value = try input(rigidMass: nil)
        value.printerEnvelope = MoldToolingSupportPrinterEnvelope(
            profileID: "coarse-profile",
            buildExtentsMillimeters: Vec3Codable(x: 300, y: 300, z: 300),
            minimumFeatureMillimeters: 10
        )
        let result = try MoldToolingSupportBuilder.evaluate(value)
        XCTAssertEqual(result.qualificationState, .printerFitNotChecked)
        XCTAssertEqual(result.artifacts.first?.qualification, .topologyValid)
        XCTAssertTrue(result.summary.notes.joined(separator: " ").contains("profile-unverified"))
    }

    private func input(
        phase: ToolingPhase = .linerFill,
        gravity: Vec3Codable = Vec3Codable(x: 0, y: 0, z: 1),
        rigidMass: Double? = 200,
        rigidCenter: Vec3Codable = Vec3Codable(x: 0, y: 0, z: 0),
        rigidExtents: Vec3 = Vec3(x: 40, y: 40, z: 10),
        liquidCenter: Vec3 = Vec3(x: 0, y: 0, z: 0),
        liquidExtents: Vec3 = Vec3(x: 2, y: 2, z: 2)
    ) throws -> MoldToolingSupportPhaseInput {
        MoldToolingSupportPhaseInput(
            phase: phase,
            gravityUpAxis: gravity,
            rigidArtifacts: [MoldToolingSupportRigidArtifact(id: ToolingArtifactID("shell"), geometry: try box(center: Vec3(x: 0, y: 0, z: 0), extents: rigidExtents), massGrams: rigidMass, centerOfGravity: rigidCenter)],
            liquid: MoldToolingSupportLiquidVolume(id: "liquid", reachableGeometry: try box(center: liquidCenter, extents: liquidExtents), densityGramsPerCC: 1),
            seed: 99
        )
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents)))
    }
}
