import CryptoKit
import XCTest
@testable import RefabArtist

final class DirectionalAccessibilityTests: XCTestCase {
    private let analyticConfiguration = DirectionalAccessibilityAnalyzer.Configuration(
        targetGridStepMM: 0.5,
        refinementPasses: 2,
        maximumSamples: 120_000,
        rayHitCoincidenceMM: 1.0e-5,
        minimumTriangleAreaMM2: 1.0e-10
    )

    func testColumnDepthUsesMinimumEscapeMaterialOnEachSide() {
        let intervals = [
            DirectionalAccessibilityAnalyzer.MaterialInterval(lower: 0, upper: 3),
            DirectionalAccessibilityAnalyzer.MaterialInterval(lower: 5, upper: 9),
            DirectionalAccessibilityAnalyzer.MaterialInterval(lower: 12, upper: 14),
        ]

        XCTAssertEqual(
            DirectionalAccessibilityAnalyzer.columnDepth(for: intervals),
            3,
            accuracy: 1.0e-12
        )
    }

    func testCanonicalPlaneNormalizesSignAndRejectsInvalidInput() throws {
        let positive = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: 2, y: 0, z: 0),
            offset: 6
        ))
        let reversed = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: -2, y: 0, z: 0),
            offset: -6
        ))

        XCTAssertEqual(positive, reversed)
        XCTAssertEqual(positive.normal, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(positive.offset, 3, accuracy: 1.0e-12)
        XCTAssertEqual(
            positive.signedDistance(to: Vec3(x: 5, y: 4, z: 3)),
            2,
            accuracy: 1.0e-12
        )
        XCTAssertNil(CanonicalPlane(normal: Vec3(x: 0, y: 0, z: 0), offset: 0))
        XCTAssertNil(CanonicalPlane(normal: Vec3(x: .nan, y: 0, z: 0), offset: 0))
        XCTAssertNil(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: .infinity))
        XCTAssertNil(CanonicalPlane(
            normal: Vec3(x: 1.0e-6, y: 0, z: 0),
            offset: Double.greatestFiniteMagnitude
        ))
    }

    func testCubeSphereAndTorusAreClearAlongExpectedAxes() throws {
        let cube = try UndercutAnalyticFixtures.box(
            min: Vec3(x: 0, y: 0, z: 0),
            max: Vec3(x: 20, y: 20, z: 20)
        )
        let sphere = UndercutAnalyticFixtures.sphere(radius: 10)
        let torus = UndercutAnalyticFixtures.torus(majorRadius: 12, minorRadius: 4)

        for (fixtureID, geometry) in [("cube", cube), ("sphere", sphere)] {
            for (axisID, axis) in zip(["x", "y", "z"], UndercutAnalyticFixtures.worldAxes) {
                let result = try DirectionalAccessibilityAnalyzer.analyze(
                    geometry: geometry,
                    pullAxis: axis,
                    configuration: analyticConfiguration
                )
                try Self.assertMatchesAnalyticManifest(
                    id: "\(fixtureID)_\(axisID)",
                    result: result
                )
                XCTAssertEqual(result.violatingColumnCount, 0)
                XCTAssertTrue(result.measuredStatus(toleranceMM: 0, minRegionAreaMM2: 0)
                    .contains("measured at"))
            }
        }

        let torusZ = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: torus,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )
        try Self.assertMatchesAnalyticManifest(id: "torus_z", result: torusZ)
        XCTAssertEqual(torusZ.violatingColumnCount, 0)
    }

    func testLPrismIsClearAlongExtrusionAndMeasuredAlongDiagonalLateralAxis() throws {
        let prism = try UndercutAnalyticFixtures.lPrism(leg: 15, height: 20)
        let alongZ = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: prism,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )
        try Self.assertMatchesAnalyticManifest(id: "l_prism_z", result: alongZ)

        let diagonal = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: prism,
            pullAxis: Vec3(x: 1, y: -1, z: 0),
            configuration: analyticConfiguration
        )
        try Self.assertMatchesAnalyticManifest(id: "l_prism_diagonal", result: diagonal)
    }

    func testBlindSideHoleDepthAndClearOpeningAxisMatchAnalyticGeometry() throws {
        let fixture = try UndercutAnalyticFixtures.blindSideHoleBlock(
            side: 20,
            lowerMaterial: 8,
            openingHeight: 4,
            blindDepth: 15
        )

        let alongZ = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: fixture,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )
        try Self.assertMatchesAnalyticManifest(id: "blind_side_hole_z", result: alongZ)

        let throughOpening = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: fixture,
            pullAxis: Vec3(x: 0, y: 1, z: 0),
            configuration: analyticConfiguration
        )
        try Self.assertMatchesAnalyticManifest(
            id: "blind_side_hole_opening_y",
            result: throughOpening
        )
    }

    func testShallowBeadUsesOneToleranceCodePath() throws {
        let fixture = try UndercutAnalyticFixtures.shallowBeadBlock(depthMM: 1.5)
        let result = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: fixture,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )

        try Self.assertMatchesAnalyticManifest(id: "shallow_bead_z", result: result)
        XCTAssertEqual(result.status(toleranceMM: 2, minRegionAreaMM2: 0), .withinTolerance)
        XCTAssertEqual(result.status(toleranceMM: 1, minRegionAreaMM2: 0), .exceedsTolerance)
        XCTAssertEqual(result.status(toleranceMM: 0, minRegionAreaMM2: 0), .exceedsTolerance)
    }

    func testAnalysisAndCandidateOrderingAreDeterministic() throws {
        let fixture = try UndercutAnalyticFixtures.blindSideHoleBlock(
            side: 20,
            lowerMaterial: 8,
            openingHeight: 4,
            blindDepth: 15
        )
        let first = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: fixture,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )
        let second = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: fixture,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )
        XCTAssertEqual(first, second)

        let directionsA = PullDirectionCandidates.generate(
            geometry: fixture,
            icosphereVertexCount: 42
        )
        let directionsB = PullDirectionCandidates.generate(
            geometry: fixture,
            icosphereVertexCount: 42
        )
        XCTAssertEqual(directionsA, directionsB)
        XCTAssertTrue(directionsA.contains(Vec3(x: 1, y: 0, z: 0)))
        XCTAssertTrue(directionsA.contains(Vec3(x: 0, y: 1, z: 0)))
        XCTAssertTrue(directionsA.contains(Vec3(x: 0, y: 0, z: 1)))
        for direction in directionsA {
            let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
            XCTAssertEqual(length, 1, accuracy: 1.0e-10)
            XCTAssertTrue(PullDirectionCandidates.isSignCanonical(direction))
        }
    }

    func testIcosphereBudgetsReportRawVerticesAndUndirectedAxisCollapse() throws {
        let cube = try UndercutAnalyticFixtures.box(
            min: Vec3(x: 0, y: 0, z: 0),
            max: Vec3(x: 10, y: 10, z: 10)
        )
        for (requested, expectedUnique) in [(42, 21), (162, 81), (642, 321)] {
            let generation = PullDirectionCandidates.generateDetailed(
                geometry: cube,
                icosphereVertexCount: requested
            )
            XCTAssertEqual(generation.rawIcosphereVertexCount, requested)
            XCTAssertEqual(generation.uniqueIcosphereAxisCount, expectedUnique)
        }
    }

    func testHugeFiniteCoordinateReturnsNamedFailureBeforePreflightQuantization() throws {
        let huge = MeshGeometryData(
            vertices: [
                Vec3(x: 1.0e20, y: 0, z: 0),
                Vec3(x: 1.0e20, y: 1, z: 0),
                Vec3(x: 1.0e20, y: 0, z: 1),
            ],
            triangleIndices: [0, 1, 2]
        )
        XCTAssertThrowsError(try DirectionalAccessibilityAnalyzer.analyze(
            geometry: huge,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration
        )) { error in
            XCTAssertEqual(
                error as? DirectionalAccessibilityAnalyzer.AnalysisError,
                .coordinateRangeExceeded
            )
        }
    }

    func testCancellationIsCheckedBeforeGridMeasurement() throws {
        let cube = try UndercutAnalyticFixtures.box(
            min: Vec3(x: 0, y: 0, z: 0),
            max: Vec3(x: 20, y: 20, z: 20)
        )
        XCTAssertThrowsError(try DirectionalAccessibilityAnalyzer.analyze(
            geometry: cube,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: analyticConfiguration,
            shouldCancel: { true }
        )) { error in
            XCTAssertEqual(
                error as? DirectionalAccessibilityAnalyzer.AnalysisError,
                .cancelled
            )
        }
    }

    // The hand's piece budget is 13 (PRD partition-split-by-undercuts §11.3,
    // amended 2026-07-13: no planar 8-piece split of this scan meets 2 mm).
    func testRealScanHealedHandMeasurementBaseline() throws {
        try Self.measureClosedFixture("handStand_ex3_healed_50k.obj", maxPieces: 13)
    }

    func testRealScanAlternateHealedHandMeasurementBaseline() throws {
        try Self.measureClosedFixture("handStand_ex3_ui_healed.obj", maxPieces: 13)
    }

    func testRealScanOpenMaskFailsThenExplicitHealMeasures() throws {
        let standard = DirectionalAccessibilityAnalyzer.Configuration(quality: .standard)
        let rawMask = try MeshInspector.inspect(url: Self.fixtureURL("open_hemisphere_mask.obj"))
        XCTAssertEqual(rawMask.preflight.boundaryEdgeCount, 32)
        XCTAssertThrowsError(try DirectionalAccessibilityAnalyzer.analyze(
            geometry: rawMask.geometry,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: standard
        )) { error in
            XCTAssertEqual(
                error as? DirectionalAccessibilityAnalyzer.AnalysisError,
                .openInput(boundaryEdgeCount: 32)
            )
        }

        // This is the explicit user-visible preprocessing path, not analyzer
        // auto-repair. The effective healed mesh becomes the source measured by
        // the analyzer and receives its own geometry fingerprint.
        let healedMask = MeshModifier.shrinkwrap(rawMask, detail: 0.0)
        XCTAssertEqual(healedMask.preflight.boundaryEdgeCount, 0)
        XCTAssertTrue(healedMask.preflight.manifoldValidated)
        let maskResult = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: healedMask.geometry,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: standard
        )
        XCTAssertGreaterThan(maskResult.sampleCount, 0)
        XCTAssertTrue(maskResult.worstDepthMM.isFinite)
        print(Self.baselineLine(
            fileName: "open_hemisphere_mask.obj",
            model: rawMask,
            effectiveGeometry: healedMask.geometry,
            preprocess: "makeWatertight(detail=0.0)",
            result: maskResult
        ))
        try Self.assertMatchesManifest(
            fileName: "open_hemisphere_mask.obj",
            model: rawMask,
            effectiveGeometry: healedMask.geometry,
            preprocessKind: "makeWatertight",
            preprocessDetail: 0.0,
            maxPieces: 8,
            result: maskResult
        )
    }

    private static func measureClosedFixture(_ fileName: String, maxPieces: Int) throws {
        let model = try MeshInspector.inspect(url: fixtureURL(fileName))
        XCTAssertEqual(model.preflight.boundaryEdgeCount, 0)
        let result = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: model.geometry,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: DirectionalAccessibilityAnalyzer.Configuration(quality: .standard)
        )
        XCTAssertGreaterThan(result.sampleCount, 0)
        XCTAssertTrue(result.worstDepthMM.isFinite)
        try assertMatchesManifest(
            fileName: fileName,
            model: model,
            effectiveGeometry: model.geometry,
            preprocessKind: "none",
            preprocessDetail: nil,
            maxPieces: maxPieces,
            result: result
        )
        print(baselineLine(
            fileName: fileName,
            model: model,
            effectiveGeometry: model.geometry,
            preprocess: "none",
            result: result
        ))
    }

    private static func fixtureURL(_ fileName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func manifestURL() -> URL {
        fixtureURL("undercut-split-expectations.json")
    }

    private static func loadManifest() throws -> UndercutExpectationManifest {
        try JSONDecoder().decode(
            UndercutExpectationManifest.self,
            from: Data(contentsOf: manifestURL())
        )
    }

    private static func assertMatchesAnalyticManifest(
        id: String,
        result: DirectionalAccessibilityAnalyzer.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let manifest = try loadManifest()
        let expected = try XCTUnwrap(
            manifest.analyticExpectations.first { $0.id == id },
            "Missing analytic manifest entry for \(id)",
            file: file,
            line: line
        )
        if let expectedRegionCount = expected.expectedRegionCount {
            XCTAssertEqual(
                result.regions.count,
                expectedRegionCount,
                file: file,
                line: line
            )
        }
        if let expectedWorstDepthMM = expected.expectedWorstDepthMM {
            let tolerance = try XCTUnwrap(
                expected.depthToleranceMM,
                "Analytic depth entry \(id) must declare its measurement tolerance",
                file: file,
                line: line
            )
            XCTAssertEqual(
                result.worstDepthMM,
                expectedWorstDepthMM,
                accuracy: tolerance,
                file: file,
                line: line
            )
        } else {
            XCTAssertNil(
                expected.depthToleranceMM,
                "Analytic entry \(id) has no depth, so it must not carry a tolerance",
                file: file,
                line: line
            )
        }
    }

    private static func assertMatchesManifest(
        fileName: String,
        model: MeshSummary,
        effectiveGeometry: MeshGeometryData,
        preprocessKind: String,
        preprocessDetail: Double?,
        maxPieces: Int,
        result: DirectionalAccessibilityAnalyzer.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let manifest = try loadManifest()
        let expected = try XCTUnwrap(
            manifest.realScanBaselines.first { $0.fileName == fileName },
            "Missing manifest entry for \(fileName)",
            file: file,
            line: line
        )
        XCTAssertEqual(manifest.schemaVersion, 1, file: file, line: line)
        XCTAssertTrue(manifest.qualityMappingProvisional, file: file, line: line)

        let bytes = try Data(contentsOf: fixtureURL(fileName))
        let fileSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fileSHA256, expected.sourceFileSHA256, file: file, line: line)
        XCTAssertEqual(
            SourceFaceMap.geometryFingerprint(of: model.geometry),
            expected.rawGeometryFingerprint,
            file: file,
            line: line
        )
        XCTAssertEqual(
            SourceFaceMap.geometryFingerprint(of: effectiveGeometry),
            expected.effectiveGeometryFingerprint,
            file: file,
            line: line
        )
        XCTAssertEqual(expected.preprocess.kind, preprocessKind, file: file, line: line)
        XCTAssertEqual(expected.preprocess.detail, preprocessDetail, file: file, line: line)
        XCTAssertEqual(expected.settings.undercutToleranceMM, 2, file: file, line: line)
        XCTAssertEqual(expected.settings.minRegionAreaMM2, 4, file: file, line: line)
        XCTAssertEqual(expected.settings.quality, "standard", file: file, line: line)
        XCTAssertEqual(expected.settings.maxPieces, maxPieces, file: file, line: line)
        XCTAssertEqual(expected.settings.seed, 0, file: file, line: line)
        assertPreflight(
            model.preflight,
            triangleCount: model.triangleCount,
            equals: expected.rawPreflight,
            file: file,
            line: line
        )
        assertPreflight(
            MeshPreflight.analyze(geometry: effectiveGeometry),
            triangleCount: effectiveGeometry.triangleIndices.count / 3,
            equals: expected.effectivePreflight,
            file: file,
            line: line
        )

        let measurement = expected.measurement
        XCTAssertEqual(measurement.pullAxis, [result.pullAxis.x, result.pullAxis.y, result.pullAxis.z], file: file, line: line)
        XCTAssertEqual(measurement.quality, "standard", file: file, line: line)
        XCTAssertEqual(result.baseResolutionMM, measurement.baseResolutionMM, accuracy: 1.0e-12, file: file, line: line)
        XCTAssertEqual(result.effectiveResolutionMM, measurement.effectiveResolutionMM, accuracy: 1.0e-12, file: file, line: line)
        XCTAssertEqual(result.sampleCount, measurement.sampleCount, file: file, line: line)
        XCTAssertEqual(result.maximumSamples, measurement.maximumSamples, file: file, line: line)
        XCTAssertEqual(result.sampleBudgetExhausted, measurement.sampleBudgetExhausted, file: file, line: line)
        XCTAssertEqual(result.violatingColumnCount, measurement.violatingColumnCount, file: file, line: line)
        XCTAssertEqual(result.regions.count, measurement.regionCount, file: file, line: line)
        XCTAssertEqual(
            result.worstDepthMM,
            measurement.worstDepthMM,
            accuracy: measurement.worstDepthRegressionToleranceMM,
            file: file,
            line: line
        )
        XCTAssertNil(expected.m2SplitExpectation, "M0 must not invent M2 planner outcomes", file: file, line: line)
    }

    private static func assertPreflight(
        _ actual: MeshPreflightReport,
        triangleCount: Int,
        equals expected: ManifestPreflight,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(triangleCount, expected.triangleCount, file: file, line: line)
        XCTAssertEqual(actual.degenerateTriangleCount, expected.degenerateTriangleCount, file: file, line: line)
        XCTAssertEqual(actual.boundaryEdgeCount, expected.boundaryEdgeCount, file: file, line: line)
        XCTAssertEqual(actual.nonManifoldEdgeCount, expected.nonManifoldEdgeCount, file: file, line: line)
        XCTAssertEqual(actual.invalidTriangleReferenceCount, expected.invalidTriangleReferenceCount, file: file, line: line)
    }

    private static func baselineLine(
        fileName: String,
        model: MeshSummary,
        effectiveGeometry: MeshGeometryData,
        preprocess: String,
        result: DirectionalAccessibilityAnalyzer.Result
    ) -> String {
        let raw = model.preflight
        let effective = MeshPreflight.analyze(geometry: effectiveGeometry)
        return "M0_BASELINE file=\(fileName) rawFingerprint=\(SourceFaceMap.geometryFingerprint(of: model.geometry)) "
            + "effectiveFingerprint=\(SourceFaceMap.geometryFingerprint(of: effectiveGeometry)) "
            + "preprocess=\(preprocess) triangles=\(model.triangleCount) degenerate=\(raw.degenerateTriangleCount) "
            + "boundary=\(raw.boundaryEdgeCount) nonManifold=\(raw.nonManifoldEdgeCount) "
            + "effectiveTriangles=\(effectiveGeometry.triangleIndices.count / 3) "
            + "effectiveDegenerate=\(effective.degenerateTriangleCount) "
            + "effectiveBoundary=\(effective.boundaryEdgeCount) "
            + "effectiveNonManifold=\(effective.nonManifoldEdgeCount) "
            + "baseMM=\(result.baseResolutionMM) effectiveMM=\(result.effectiveResolutionMM) "
            + "samples=\(result.sampleCount)/\(result.maximumSamples) budgetExhausted=\(result.sampleBudgetExhausted) "
            + "violatingColumns=\(result.violatingColumnCount) regions=\(result.regions.count) "
            + "worstDepthMM=\(result.worstDepthMM)"
    }

    private struct UndercutExpectationManifest: Decodable {
        let schemaVersion: Int
        let qualityMappingProvisional: Bool
        let analyticExpectations: [ManifestAnalyticExpectation]
        let realScanBaselines: [ManifestRealScanBaseline]
    }

    private struct ManifestAnalyticExpectation: Decodable {
        let id: String
        let expectedRegionCount: Int?
        let expectedWorstDepthMM: Double?
        let depthToleranceMM: Double?
    }

    private struct ManifestRealScanBaseline: Decodable {
        let fileName: String
        let sourceFileSHA256: String
        let rawGeometryFingerprint: String
        let effectiveGeometryFingerprint: String
        let preprocess: ManifestPreprocess
        let settings: ManifestSettings
        let rawPreflight: ManifestPreflight
        let effectivePreflight: ManifestPreflight
        let measurement: ManifestMeasurement
        let m2SplitExpectation: String?
    }

    private struct ManifestPreprocess: Decodable {
        let kind: String
        let detail: Double?
    }

    private struct ManifestSettings: Decodable {
        let undercutToleranceMM: Double
        let minRegionAreaMM2: Double
        let quality: String
        let maxPieces: Int
        let seed: Int64
    }

    private struct ManifestPreflight: Decodable {
        let triangleCount: Int
        let degenerateTriangleCount: Int
        let boundaryEdgeCount: Int
        let nonManifoldEdgeCount: Int
        let invalidTriangleReferenceCount: Int
    }

    private struct ManifestMeasurement: Decodable {
        let pullAxis: [Double]
        let quality: String
        let baseResolutionMM: Double
        let effectiveResolutionMM: Double
        let sampleCount: Int
        let maximumSamples: Int
        let sampleBudgetExhausted: Bool
        let violatingColumnCount: Int
        let regionCount: Int
        let worstDepthMM: Double
        let worstDepthRegressionToleranceMM: Double
    }
}

private enum UndercutAnalyticFixtures {
    static let worldAxes = [
        Vec3(x: 1, y: 0, z: 0),
        Vec3(x: 0, y: 1, z: 0),
        Vec3(x: 0, y: 0, z: 1),
    ]

    static func box(min: Vec3, max: Vec3) throws -> MeshGeometryData {
        let center = Vec3(
            x: (min.x + max.x) / 2,
            y: (min.y + max.y) / 2,
            z: (min.z + max.z) / 2
        )
        let extents = Vec3(x: max.x - min.x, y: max.y - min.y, z: max.z - min.z)
        return try ManifoldEngine.toMesh(try ManifoldEngine.box(
            ManifoldBoxSpec(center: center, extents: extents)
        ))
    }

    static func lPrism(leg: Double, height: Double) throws -> MeshGeometryData {
        let horizontal = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: leg, y: leg / 2, z: height / 2),
            extents: Vec3(x: leg * 2, y: leg, z: height)
        ))
        let vertical = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: leg / 2, y: leg * 1.5, z: height / 2),
            extents: Vec3(x: leg, y: leg * 2, z: height)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.union(horizontal, vertical))
    }

    static func blindSideHoleBlock(
        side: Double,
        lowerMaterial: Double,
        openingHeight: Double,
        blindDepth: Double
    ) throws -> MeshGeometryData {
        let solid = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: side / 2, y: side / 2, z: side / 2),
            extents: Vec3(x: side, y: side, z: side)
        ))
        let cutter = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(
                x: side / 2,
                y: (blindDepth - 1) / 2,
                z: lowerMaterial + openingHeight / 2
            ),
            extents: Vec3(x: side / 2, y: blindDepth + 1, z: openingHeight)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.difference(solid, cutter))
    }

    static func shallowBeadBlock(depthMM: Double) throws -> MeshGeometryData {
        try blindSideHoleBlock(
            side: 10,
            lowerMaterial: depthMM,
            openingHeight: 2.5,
            blindDepth: 7.5
        )
    }

    static func sphere(radius: Double, longitudeSegments: Int = 24, latitudeSegments: Int = 12) -> MeshGeometryData {
        var vertices = [Vec3(x: 0, y: 0, z: radius)]
        var indices: [Int32] = []
        for latitude in 1..<latitudeSegments {
            let phi = Double.pi * Double(latitude) / Double(latitudeSegments)
            for longitude in 0..<longitudeSegments {
                let theta = 2 * Double.pi * Double(longitude) / Double(longitudeSegments)
                vertices.append(Vec3(
                    x: radius * sin(phi) * cos(theta),
                    y: radius * sin(phi) * sin(theta),
                    z: radius * cos(phi)
                ))
            }
        }
        vertices.append(Vec3(x: 0, y: 0, z: -radius))
        let south = Int32(vertices.count - 1)
        for longitude in 0..<longitudeSegments {
            let current = Int32(1 + longitude)
            let next = Int32(1 + (longitude + 1) % longitudeSegments)
            indices += [0, current, next]
        }
        for latitude in 0..<(latitudeSegments - 2) {
            let lower = Int32(1 + latitude * longitudeSegments)
            let upper = Int32(1 + (latitude + 1) * longitudeSegments)
            for longitude in 0..<longitudeSegments {
                let next = (longitude + 1) % longitudeSegments
                let a = lower + Int32(longitude)
                let b = lower + Int32(next)
                let c = upper + Int32(next)
                let d = upper + Int32(longitude)
                indices += [a, c, b, a, d, c]
            }
        }
        let lastRing = Int32(1 + (latitudeSegments - 2) * longitudeSegments)
        for longitude in 0..<longitudeSegments {
            let current = lastRing + Int32(longitude)
            let next = lastRing + Int32((longitude + 1) % longitudeSegments)
            indices += [south, next, current]
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    static func torus(
        majorRadius: Double,
        minorRadius: Double,
        majorSegments: Int = 36,
        minorSegments: Int = 18
    ) -> MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        for major in 0..<majorSegments {
            let theta = 2 * Double.pi * Double(major) / Double(majorSegments)
            for minor in 0..<minorSegments {
                let phi = 2 * Double.pi * Double(minor) / Double(minorSegments)
                vertices.append(Vec3(
                    x: (majorRadius + minorRadius * cos(phi)) * cos(theta),
                    y: (majorRadius + minorRadius * cos(phi)) * sin(theta),
                    z: minorRadius * sin(phi)
                ))
            }
        }
        for major in 0..<majorSegments {
            for minor in 0..<minorSegments {
                let a = Int32(major * minorSegments + minor)
                let b = Int32(((major + 1) % majorSegments) * minorSegments + minor)
                let c = Int32(((major + 1) % majorSegments) * minorSegments + (minor + 1) % minorSegments)
                let d = Int32(major * minorSegments + (minor + 1) % minorSegments)
                indices += [a, b, c, a, c, d]
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }
}
