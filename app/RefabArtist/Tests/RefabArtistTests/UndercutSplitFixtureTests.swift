import XCTest
@testable import RefabArtist

final class UndercutSplitFixtureTests: XCTestCase {
    func testCommittedHealedHandMeetsManifestPlannerGateDeterministically() async throws {
        let entry = try XCTUnwrap(try loadManifest().entry("handStand_ex3_healed_50k.obj"))
        guard entry.m2SplitExpectation != nil else {
            throw XCTSkip(
                "M2 SEC-11.3 hand expectation not yet earned: m2SplitExpectation is null. "
                    + "Run the planner twice and record the earned numbers in the manifest; "
                    + "never fabricate them (R9)."
            )
        }
        let model = try MeshInspector.inspect(url: fixtureURL(entry.fileName))
        XCTAssertEqual(model.preflight.boundaryEdgeCount, entry.rawPreflight.boundaryEdgeCount)

        let cache = UndercutSplitPlannerCache(maximumEntryCount: 512)
        let started = ProcessInfo.processInfo.systemUptime
        let first = try await UndercutSplitPlanner.plan(
            geometry: model.geometry,
            settings: entry.plannerSettings,
            cache: cache
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let second = try await UndercutSplitPlanner.plan(
            geometry: model.geometry,
            settings: entry.plannerSettings,
            cache: cache
        )
        print(first.fixtureGateLine(fileName: entry.fileName, elapsedSeconds: elapsed))
        print("UNDERCUT_SPLIT_DETAIL \(first.statusMessage) axes=\(first.pieces.map(\.pullAxis)) depths=\(first.pieces.map { $0.measurement?.worstDepthMM ?? .nan })")
        print("UNDERCUT_SPLIT_REJECTIONS \(first.candidateRejections.map { "\($0.reason.rawValue):\($0.detail)" }.prefix(40))")
        let expectation = try XCTUnwrap(
            entry.m2SplitExpectation,
            "M2 must record the earned result and cold runtime in the manifest without weakening §11.3."
        )

        XCTAssertEqual(first.status.rawValue, expectation.expectedOverallStatus)
        XCTAssertTrue(expectation.allowedPieceCount.contains(first.pieces.count))
        XCTAssertLessThanOrEqual(first.pieces.count, entry.plannerSettings.maxPieces)
        XCTAssertTrue(first.pieces.allSatisfy { piece in
            piece.measurement?.status(
                toleranceMM: entry.plannerSettings.undercutToleranceMM,
                minRegionAreaMM2: entry.plannerSettings.minRegionAreaMM2
            ) == .withinTolerance
        })
        XCTAssertLessThanOrEqual(first.worstMeasuredDepthMM, expectation.maximumWorstDepthMM)
        XCTAssertLessThanOrEqual(
            expectation.maximumWorstDepthMM,
            entry.plannerSettings.undercutToleranceMM
        )
        XCTAssertTrue(first.fullResolutionFinalized)
        XCTAssertEqual(first.finalMeasurementQuality, .thorough)
        XCTAssertTrue(first.manifoldCrossCheckPassed)
        XCTAssertEqual(first.deterministicFingerprint, second.deterministicFingerprint)
        XCTAssertEqual(first.pieces.map(\.mesh.stableFingerprint), second.pieces.map(\.mesh.stableFingerprint))
        XCTAssertLessThanOrEqual(elapsed, expectation.maximumRuntimeSeconds)
        XCTAssertLessThanOrEqual(expectation.maximumRuntimeSeconds, 30)
        XCTAssertTrue(expectation.measuredColdRuntimeSeconds.isFinite)
        XCTAssertGreaterThan(expectation.measuredColdRuntimeSeconds, 0)
        XCTAssertLessThanOrEqual(
            expectation.measuredColdRuntimeSeconds,
            expectation.maximumRuntimeSeconds
        )
        XCTAssertFalse(
            expectation.justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        let stats = await cache.statistics
        XCTAssertGreaterThan(stats.hitCount, 0)
    }

    func testOpenMaskRequiresExplicitHealThenMeetsPlannerGate() async throws {
        let entry = try XCTUnwrap(try loadManifest().entry("open_hemisphere_mask.obj"))
        guard entry.m2SplitExpectation != nil else {
            throw XCTSkip(
                "M2 SEC-11.3 mask expectation not yet earned: m2SplitExpectation is null. "
                    + "Earn it with two consecutive runs; never fabricate (R9)."
            )
        }
        let raw = try MeshInspector.inspect(url: fixtureURL(entry.fileName))
        XCTAssertEqual(raw.preflight.boundaryEdgeCount, entry.rawPreflight.boundaryEdgeCount)

        let openResult = try await UndercutSplitPlanner.plan(
            geometry: raw.geometry,
            settings: entry.plannerSettings
        )
        XCTAssertEqual(openResult.status, .analysisError)
        XCTAssertTrue(openResult.statusMessage.contains("Make Watertight"))
        XCTAssertTrue(openResult.isExportable)

        // Explicit existing user flow. The planner must never silently heal.
        let healed = MeshModifier.shrinkwrap(raw, detail: 0.0)
        XCTAssertEqual(healed.preflight.boundaryEdgeCount, 0)
        XCTAssertEqual(
            SourceFaceMap.geometryFingerprint(of: healed.geometry),
            entry.effectiveGeometryFingerprint
        )

        let cache = UndercutSplitPlannerCache(maximumEntryCount: 128)
        let started = ProcessInfo.processInfo.systemUptime
        let first = try await UndercutSplitPlanner.plan(
            geometry: healed.geometry,
            settings: entry.plannerSettings,
            cache: cache
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let second = try await UndercutSplitPlanner.plan(
            geometry: healed.geometry,
            settings: entry.plannerSettings,
            cache: cache
        )
        print(first.fixtureGateLine(fileName: entry.fileName, elapsedSeconds: elapsed))
        print("UNDERCUT_SPLIT_DETAIL \(first.statusMessage) axes=\(first.pieces.map(\.pullAxis)) depths=\(first.pieces.map { $0.measurement?.worstDepthMM ?? .nan })")
        let expectation = try XCTUnwrap(
            entry.m2SplitExpectation,
            "M2 must record the earned result and cold runtime in the manifest without weakening §11.3."
        )

        XCTAssertEqual(first.status.rawValue, expectation.expectedOverallStatus)
        XCTAssertTrue(expectation.allowedPieceCount.contains(first.pieces.count))
        XCTAssertLessThanOrEqual(first.pieces.count, 2)
        XCTAssertTrue(first.pieces.allSatisfy { piece in
            piece.measurement?.status(
                toleranceMM: entry.plannerSettings.undercutToleranceMM,
                minRegionAreaMM2: entry.plannerSettings.minRegionAreaMM2
            ) == .withinTolerance
        })
        XCTAssertLessThanOrEqual(first.worstMeasuredDepthMM, expectation.maximumWorstDepthMM)
        XCTAssertLessThanOrEqual(
            expectation.maximumWorstDepthMM,
            entry.plannerSettings.undercutToleranceMM
        )
        XCTAssertTrue(first.fullResolutionFinalized)
        XCTAssertEqual(first.finalMeasurementQuality, .thorough)
        XCTAssertTrue(first.manifoldCrossCheckPassed)
        XCTAssertEqual(first.deterministicFingerprint, second.deterministicFingerprint)
        XCTAssertEqual(first.pieces.map(\.mesh.stableFingerprint), second.pieces.map(\.mesh.stableFingerprint))
        XCTAssertLessThanOrEqual(elapsed, expectation.maximumRuntimeSeconds)
        XCTAssertLessThanOrEqual(expectation.maximumRuntimeSeconds, 10)
        XCTAssertTrue(expectation.measuredColdRuntimeSeconds.isFinite)
        XCTAssertGreaterThan(expectation.measuredColdRuntimeSeconds, 0)
        XCTAssertLessThanOrEqual(
            expectation.measuredColdRuntimeSeconds,
            expectation.maximumRuntimeSeconds
        )
        XCTAssertFalse(
            expectation.justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: fixtureURL("undercut-split-expectations.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private struct Manifest: Decodable {
        let realScanBaselines: [Entry]

        func entry(_ fileName: String) -> Entry? {
            realScanBaselines.first { $0.fileName == fileName }
        }
    }

    private struct Entry: Decodable {
        let fileName: String
        let effectiveGeometryFingerprint: String
        let settings: PlannerInput
        let rawPreflight: Preflight
        let m2SplitExpectation: M2SplitExpectation?

        var plannerSettings: UndercutSplitSettings {
            var value = UndercutSplitSettings.defaultValue
            value.undercutToleranceMM = settings.undercutToleranceMM
            value.minRegionAreaMM2 = settings.minRegionAreaMM2
            value.quality = UndercutSearchQuality(rawValue: settings.quality) ?? .standard
            value.maxPieces = settings.maxPieces
            value.seed = settings.seed
            return value
        }
    }

    private struct PlannerInput: Decodable {
        let undercutToleranceMM: Double
        let minRegionAreaMM2: Double
        let quality: String
        let maxPieces: Int
        let seed: Int64
    }

    private struct Preflight: Decodable {
        let boundaryEdgeCount: Int
    }

    private struct M2SplitExpectation: Decodable {
        let expectedOverallStatus: String
        let minimumPieceCount: Int
        let maximumPieceCount: Int
        let maximumWorstDepthMM: Double
        let maximumRuntimeSeconds: Double
        let measuredColdRuntimeSeconds: Double
        let justification: String

        var allowedPieceCount: ClosedRange<Int> {
            minimumPieceCount...maximumPieceCount
        }
    }
}
