import XCTest
@testable import RefabArtist

final class MoldLinerStateBuilderTests: XCTestCase {
    func testShellMinusPositiveVolumeIsExactAndReferenceOnly() throws {
        let result = try MoldLinerStateBuilder.build(try baseInput())

        XCTAssertEqual(result.volumeDeltas.cavityMinusPositiveCubicMillimeters, 936, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.asPouredLinerCubicMillimeters, 936, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.productionLinerCubicMillimeters, 936, accuracy: 1.0e-6)
        XCTAssertEqual(result.referenceArtifacts.map(\.id.rawValue), ["AS-POURED LINER", "PRODUCTION LINER"])
        XCTAssertEqual(result.referenceArtifacts.map(\.role), [.referenceAsPouredLiner, .referenceProductionLiner])
        XCTAssertTrue(result.referenceArtifacts.allSatisfy { $0.qualification == .referenceOnly })
    }

    func testAsPouredAndProductionStatesDifferAfterSacrificialTrim() throws {
        let result = try MoldLinerStateBuilder.build(try inputWithSacrificialNub())

        XCTAssertEqual(result.volumeDeltas.asPouredLinerCubicMillimeters, 940, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.productionLinerCubicMillimeters, 936, accuracy: 1.0e-6)
        XCTAssertNotEqual(result.asPouredLiner.geometry, result.productionLiner.geometry)
    }

    func testTrimMapAccountsForExactRequestedAndRemovedVolumes() throws {
        let result = try MoldLinerStateBuilder.build(try inputWithSacrificialNub())
        let trim = try XCTUnwrap(result.trimMap.first)

        XCTAssertEqual(trim.id, "liner-fill-nub-01")
        XCTAssertEqual(trim.purpose, "remove one-time liner-fill nub")
        XCTAssertEqual(trim.requestedVolumeCubicMillimeters, 4, accuracy: 1.0e-6)
        XCTAssertEqual(trim.removedVolumeCubicMillimeters, 4, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.trimDeltaCubicMillimeters, 4, accuracy: 1.0e-6)
        XCTAssertEqual(trim.bounds.minimum.x, 5, accuracy: 1.0e-6)
        XCTAssertEqual(trim.bounds.maximum.x, 6, accuracy: 1.0e-6)
    }

    func testInputSourceAndCavityRemainUnchanged() throws {
        let input = try inputWithSacrificialNub()
        let originalCavity = input.cavitySolid
        let originalPositive = input.oneTimePourPositive
        let originalAdditive = input.verifiedLinerFillAdditives

        _ = try MoldLinerStateBuilder.build(input)

        XCTAssertEqual(input.cavitySolid, originalCavity)
        XCTAssertEqual(input.oneTimePourPositive, originalPositive)
        XCTAssertEqual(input.verifiedLinerFillAdditives, originalAdditive)
    }

    func testDestructiveTrimIsRejected() throws {
        var input = try baseInput()
        input.trimOperations = [MoldLinerTrimOperation(
            id: "destroy-liner",
            purpose: "invalid full removal",
            solid: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 30, y: 30, z: 30))
        )]

        XCTAssertThrowsError(try MoldLinerStateBuilder.build(input)) { error in
            XCTAssertEqual(error as? MoldLinerStateBuilderError, .trimDestroysLiner("destroy-liner"))
        }
    }

    func testDisconnectingTrimIsRejected() throws {
        var input = try baseInput()
        input.trimOperations = [MoldLinerTrimOperation(
            id: "split-liner",
            purpose: "invalid split through the liner",
            solid: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 30, y: 30, z: 2))
        )]

        XCTAssertThrowsError(try MoldLinerStateBuilder.build(input)) { error in
            XCTAssertEqual(
                error as? MoldLinerStateBuilderError,
                .trimBreaksComponentContract(trimID: "split-liner", expected: 1, actual: 2)
            )
        }
    }

    func testProtectedRegistrationOrProductionFlowVolumeCannotBeTrimmed() throws {
        var input = try inputWithSacrificialNub()
        let protectedNub = try box(center: Vec3(x: 5.5, y: 0, z: 0), extents: Vec3(x: 1, y: 2, z: 2))
        input.protectedRegions = [MoldLinerProtectedRegion(
            id: "registration-boss-01",
            purpose: .registration,
            solid: protectedNub
        )]

        XCTAssertThrowsError(try MoldLinerStateBuilder.build(input)) { error in
            XCTAssertEqual(
                error as? MoldLinerStateBuilderError,
                .protectedRegionIntersected(trimID: "liner-fill-nub-01", protectedID: "registration-boss-01")
            )
        }
    }

    func testPersistentProductionVoidIsRetainedInBothReferenceStates() throws {
        var input = try baseInput()
        input.persistentProductionVoids = [MoldLinerPersistentVoid(
            id: "production-gate-01",
            kind: .productionGate,
            purpose: "permanent production gate",
            solid: try box(center: Vec3(x: -5, y: 0, z: 0), extents: Vec3(x: 2, y: 2, z: 2))
        )]

        let result = try MoldLinerStateBuilder.build(input)
        XCTAssertEqual(result.volumeDeltas.persistentVoidDeltaCubicMillimeters, 4, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.asPouredLinerCubicMillimeters, 932, accuracy: 1.0e-6)
        XCTAssertEqual(result.volumeDeltas.productionLinerCubicMillimeters, 932, accuracy: 1.0e-6)
    }

    func testTopologyMetricsMeetOneComponentWatertightContract() throws {
        let result = try MoldLinerStateBuilder.build(try inputWithSacrificialNub())

        for (artifact, metrics) in zip(
            result.referenceArtifacts,
            [result.asPouredTopology, result.productionTopology]
        ) {
            XCTAssertTrue(MeshPreflight.analyze(geometry: artifact.geometry).isWatertight)
            XCTAssertEqual(metrics.connectedComponentCount, 1)
            XCTAssertTrue(metrics.isWatertight)
            XCTAssertTrue(metrics.hasFiniteCoordinates)
            XCTAssertGreaterThan(metrics.vertexCount, 0)
            XCTAssertGreaterThan(metrics.triangleCount, 0)
            XCTAssertGreaterThan(metrics.volumeCubicMillimeters, 0)
        }
    }

    func testReferenceNormalizationRejectsMaterialAlterationBeyondBound() throws {
        let exact = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 10, y: 10, z: 10)
        ))
        let altered = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 1, y: 0, z: 0),
            extents: Vec3(x: 10, y: 10, z: 10)
        ))
        defer {
            withExtendedLifetime(exact) {}
            withExtendedLifetime(altered) {}
        }

        let difference = try MoldLinerStateBuilder.symmetricDifferenceVolume(exact, altered)
        XCTAssertGreaterThan(
            difference,
            MoldLinerStateBuilder.maximumNormalizationSymmetricDifferenceCubicMillimeters
        )
        XCTAssertThrowsError(try MoldLinerStateBuilder.requireSafeNormalization(
            exact: exact,
            normalized: altered,
            label: "test liner"
        )) { error in
            guard case .referenceNormalizationMateriallyAltered(let label, let measured) = error as? MoldLinerStateBuilderError else {
                return XCTFail("expected typed material-alteration failure, got \(error)")
            }
            XCTAssertEqual(label, "test liner")
            XCTAssertEqual(measured, difference, accuracy: 1.0e-6)
        }
    }

    func testOutputIsDeterministic() throws {
        let input = try inputWithSacrificialNub()
        let first = try MoldLinerStateBuilder.build(input)
        let second = try MoldLinerStateBuilder.build(input)

        XCTAssertEqual(first, second)
    }

    private func baseInput() throws -> MoldLinerStateInput {
        MoldLinerStateInput(
            cavitySolid: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 10, y: 10, z: 10)),
            oneTimePourPositive: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 4, y: 4, z: 4))
        )
    }

    private func inputWithSacrificialNub() throws -> MoldLinerStateInput {
        var input = try baseInput()
        input.verifiedLinerFillAdditives = [MoldLinerFillAdditiveVolume(
            id: "liner-fill-nub-01",
            purpose: "one-time liner-fill nub",
            solid: try box(center: Vec3(x: 5, y: 0, z: 0), extents: Vec3(x: 2, y: 2, z: 2))
        )]
        input.trimOperations = [MoldLinerTrimOperation(
            id: "liner-fill-nub-01",
            purpose: "remove one-time liner-fill nub",
            solid: try box(center: Vec3(x: 5.5, y: 0, z: 0), extents: Vec3(x: 1, y: 2, z: 2))
        )]
        return input
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        let solid = try ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents))
        return try ManifoldEngine.toMesh(solid)
    }
}
