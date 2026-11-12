import XCTest
@testable import RefabArtist

final class UndercutSplitPlannerTests: XCTestCase {
    func testZeroCutFastPathAlwaysBeatsASeamedState() async throws {
        let source = try box(
            min: Vec3(x: -10, y: -8, z: -6),
            max: Vec3(x: 10, y: 8, z: 6)
        )
        var settings = UndercutSplitSettings.defaultValue
        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 0
        settings.quality = .quick

        let result = try await UndercutSplitPlanner.plan(geometry: source, settings: settings)

        XCTAssertEqual(result.status, .wholeModelWithinTolerance)
        XCTAssertEqual(result.cutTree.nodes.count, 0)
        XCTAssertEqual(result.pieces.count, 1)
        XCTAssertEqual(result.pieces[0].measurement?.status(
            toleranceMM: 0,
            minRegionAreaMM2: 0
        ), .withinTolerance)
        XCTAssertTrue(result.statusMessage.contains("measured at"))
    }

    func testOrthogonalDoubleHookRecoversCenterCutAndPerPieceAxes() async throws {
        let source = try orthogonalDoubleHook()
        var settings = UndercutSplitSettings.defaultValue
        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 0
        settings.quality = .standard
        settings.maxPieces = 2
        settings.minimumPieceVolumeFraction = 0.001
        settings.minimumSeamAreaMM2 = 1

        let result = try await UndercutSplitPlanner.plan(geometry: source, settings: settings)

        XCTAssertEqual(result.status, .splitWithinTolerance)
        XCTAssertEqual(result.pieces.count, 2)
        XCTAssertEqual(result.cutTree.nodes.count, 1)
        XCTAssertEqual(result.cutTree.nodes[0].plane.normal, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(result.cutTree.nodes[0].plane.offset, 0, accuracy: 1.0e-4)
        let axes = result.pieces.map(\.pullAxis)
        XCTAssertTrue(axes.contains { abs($0.x) > 1 - 1.0e-8 })
        XCTAssertTrue(axes.contains { abs($0.y) > 1 - 1.0e-8 })
        XCTAssertTrue(result.pieces.allSatisfy {
            $0.measurement?.status(toleranceMM: 0, minRegionAreaMM2: 0) == .withinTolerance
        })
    }

    func testToleranceKeysDominateEveryPriorityProfile() {
        let withinTolerance = UndercutSplitObjective(
            exceedingPieceCount: 0,
            totalExcessDepthMM: 0,
            totalOverToleranceAreaMM2: 0,
            pieceCount: 8,
            sliverPenalty: 100,
            seamDetailPenalty: 100,
            totalSeamAreaMM2: 100,
            pieceVolumeVariance: 100,
            deterministicTieBreak: "z"
        )
        let prettierButExceeding = UndercutSplitObjective(
            exceedingPieceCount: 1,
            totalExcessDepthMM: 0.001,
            totalOverToleranceAreaMM2: 0.001,
            pieceCount: 1,
            sliverPenalty: 0,
            seamDetailPenalty: 0,
            totalSeamAreaMM2: 0,
            pieceVolumeVariance: 0,
            deterministicTieBreak: "a"
        )

        for priority in UndercutSplitPriority.allCases {
            XCTAssertTrue(withinTolerance.isBetter(than: prettierButExceeding, priority: priority))
            XCTAssertFalse(prettierButExceeding.isBetter(than: withinTolerance, priority: priority))
        }
    }

    func testStrictToleranceUsesTheSameObjectivePath() {
        let atTolerance = UndercutSplitObjective.measurementKeys(
            measurements: [syntheticMeasurement(depth: 1.5, area: 10)],
            toleranceMM: 1.5,
            minRegionAreaMM2: 0
        )
        let strict = UndercutSplitObjective.measurementKeys(
            measurements: [syntheticMeasurement(depth: 1.5, area: 10)],
            toleranceMM: 0,
            minRegionAreaMM2: 0
        )

        XCTAssertEqual(atTolerance.exceedingPieceCount, 0)
        XCTAssertEqual(strict.exceedingPieceCount, 1)
        XCTAssertEqual(strict.totalExcessDepthMM, 1.5, accuracy: 1.0e-12)
        XCTAssertEqual(strict.totalOverToleranceAreaMM2, 10, accuracy: 1.0e-12)
    }


    func testFixedAxisIsMeasuredAndSearchMissWordingIsHonest() async throws {
        let source = try blindSideHoleBlock()
        var settings = UndercutSplitSettings.defaultValue
        settings.pullPolicy = .fixed
        settings.fixedPullDirection = Vec3(x: 0, y: 0, z: 1)
        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 0
        settings.maxPieces = 1
        settings.quality = .quick

        let result = try await UndercutSplitPlanner.plan(geometry: source, settings: settings)

        XCTAssertEqual(result.status, .splitExceedsTolerance)
        XCTAssertEqual(result.pieces.count, 1)
        XCTAssertEqual(result.pieces[0].pullAxis, Vec3(x: 0, y: 0, z: 1))
        XCTAssertEqual(result.pieces[0].measurement?.status(
            toleranceMM: 0,
            minRegionAreaMM2: 0
        ), .exceedsTolerance)
        XCTAssertTrue(result.statusMessage.contains("measured at"))
        XCTAssertTrue(result.statusMessage.contains("No split within tolerance was found in this search"))
        XCTAssertFalse(result.statusMessage.localizedCaseInsensitiveContains("impossible"))
        XCTAssertTrue(result.isExportable)
    }

    func testNoCutPaintIsHardAndConflictIsReported() async throws {
        let source = try blindSideHoleBlock()
        let attributed = try SourceFaceMap.attributedMesh(from: source)
        var settings = UndercutSplitSettings.defaultValue
        settings.pullPolicy = .fixed
        settings.fixedPullDirection = Vec3(x: 0, y: 0, z: 1)
        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 0
        settings.quality = .quick
        settings.maxPieces = 3
        settings.faceConstraints.noCutSourceFaceIDs = attributed.sourceFaceIDs.sorted()

        let result = try await UndercutSplitPlanner.plan(geometry: source, settings: settings)

        XCTAssertEqual(result.cutTree.nodes.count, 0)
        XCTAssertEqual(result.status, .splitExceedsTolerance)
        XCTAssertTrue(result.candidateRejections.contains { $0.reason == .crossesNoCutFace })
        XCTAssertTrue(result.warnings.contains { $0.localizedCaseInsensitiveContains("no-cut") })
    }

    func testSliverSeamAndDisconnectedPrefiltersAreObservable() async throws {
        let source = try blindSideHoleBlock()
        var sliverSettings = UndercutSplitSettings.defaultValue
        sliverSettings.pullPolicy = .fixed
        sliverSettings.fixedPullDirection = Vec3(x: 0, y: 0, z: 1)
        sliverSettings.undercutToleranceMM = 0
        sliverSettings.minRegionAreaMM2 = 0
        sliverSettings.quality = .quick
        sliverSettings.maxPieces = 2
        sliverSettings.minimumPieceVolumeFraction = 0.49
        sliverSettings.minimumSeamAreaMM2 = 10_000

        let rejected = try await UndercutSplitPlanner.plan(
            geometry: source,
            settings: sliverSettings
        )
        XCTAssertEqual(rejected.cutTree.nodes.count, 0)
        XCTAssertTrue(rejected.candidateRejections.contains {
            $0.reason == .minimumPieceVolume || $0.reason == .minimumSeamArea
        })

        let twoObjects = try disjointEqualBoxes()
        let blocked = try await UndercutSplitPlanner.plan(
            geometry: twoObjects,
            settings: .defaultValue
        )
        XCTAssertEqual(blocked.status, .analysisError)
        XCTAssertTrue(blocked.statusMessage.contains("separate the objects first"))
        XCTAssertTrue(blocked.isExportable)
    }

    func testProxySearchFinalizesOnOriginalAtThoroughWithFidelityAndCrossCheck() async throws {
        let source = try denseOrthogonalDoubleHook(minimumTriangleCount: 150_001)
        XCTAssertGreaterThan(source.triangleIndices.count / 3, 150_000)
        let sourceFingerprint = SourceFaceMap.geometryFingerprint(of: source)
        var settings = UndercutSplitSettings.defaultValue
        settings.quality = .quick
        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 0

        let result = try await UndercutSplitPlanner.plan(geometry: source, settings: settings)
        XCTAssertTrue(result.searchUsedProxy)
        XCTAssertLessThanOrEqual(result.searchTriangleCount, 150_000)
        XCTAssertEqual(result.sourceTriangleCount, source.triangleIndices.count / 3)
        XCTAssertTrue(result.fullResolutionFinalized)
        XCTAssertEqual(result.finalMeasurementQuality, .thorough)
        XCTAssertEqual(result.cutTree.rootRegionID, .root(sourceGeometryFingerprint: sourceFingerprint))
        XCTAssertTrue(result.pieces.allSatisfy { $0.mesh.sourceGeometryFingerprint == sourceFingerprint })
        // Closure per R4 = welded-edge parity over all triangles (benign
        // slivers admitted); preflight's boundary count skips degenerate
        // triangles' edges and can report phantom boundaries next to them.
        XCTAssertTrue(result.pieces.allSatisfy { PartitionGeometry.openEdgeCount($0.mesh.geometry) == 0 })
        XCTAssertTrue(result.pieces.allSatisfy(\.isOutwardOriented))
        XCTAssertGreaterThan(result.cutTree.nodes.count, 0, "The proxy cross-check gate must exercise a real cut")
        XCTAssertTrue(result.manifoldCrossCheckPassed)
        XCTAssertEqual(result.crossCheckedCutCount, result.cutTree.nodes.count)
        XCTAssertLessThanOrEqual(result.conservation.missingVolumeMM3, result.conservation.toleranceMM3)
        XCTAssertLessThanOrEqual(result.conservation.excessVolumeMM3, result.conservation.toleranceMM3)
        XCTAssertLessThanOrEqual(result.conservation.pairwiseOverlapVolumeMM3, result.conservation.toleranceMM3)
    }

    func testAnalyzerFaceIndicesRemapToDurableProvenanceAfterNestedCuts() throws {
        let source = indexedBox(halfExtent: 10)
        let attributed = try SourceFaceMap.attributedMesh(from: source)
        let root = PartitionRegionID.root(sourceGeometryFingerprint: attributed.sourceGeometryFingerprint)
        let firstPlane = try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0))
        let first = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: root,
            plane: firstPlane,
            siblingOrdinal: 0,
            isLocked: false
        )
        let secondPlane = try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 2))
        let second = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: first.negativeChildID,
            plane: secondPlane,
            siblingOrdinal: 1,
            isLocked: false
        )
        let replay = try PartitionCutTree(rootRegionID: root, nodes: [first, second]).replay(source: attributed)
        let leaf = try XCTUnwrap(replay.leaves.first { $0.regionID == second.positiveChildID })
        let sourceIndex = try XCTUnwrap(leaf.mesh.triangles.indices.first {
            if case .source = leaf.mesh.triangles[$0].provenance { return true }
            return false
        })
        let capIndex = try XCTUnwrap(leaf.mesh.triangles.indices.first {
            if case .cut = leaf.mesh.triangles[$0].provenance { return true }
            return false
        })
        let raw = syntheticMeasurement(
            regions: [UndercutRegionClusterer.Region(
                id: "mixed",
                faceIDs: [sourceIndex, capIndex],
                areaMM2: 12,
                depthMM: 3,
                centroid: Vec3(x: 1, y: 1, z: 1),
                suggestedEscapeDirections: []
            )]
        )

        let mapped = try UndercutSplitPlanner.remapMeasurementRegions(raw, on: leaf.mesh)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertFalse(mapped[0].sourceFaceIDs.isEmpty)
        XCTAssertTrue(mapped[0].containsCutSurface)
        XCTAssertTrue(mapped[0].sourceFaceIDs.allSatisfy(attributed.sourceFaceIDs.contains))
        XCTAssertEqual(leaf.mesh.geometry.triangleIndices.count / 3, leaf.mesh.triangles.count)
    }

    func testDraftAdvisoryExcludesCutAndJoineryTriangles() {
        let source = AttributedTriangle(
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 2, z: 0),
            c: Vec3(x: 0, y: 0, z: 2),
            provenance: .source(SourceFaceID(rawValue: 4))
        )
        let cap = AttributedTriangle(
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 20, y: 0, z: 0),
            c: Vec3(x: 0, y: 20, z: 0),
            provenance: .cut(nodeID: PartitionCutNodeID(rawValue: "cut"), side: .negative)
        )
        let joinery = AttributedTriangle(
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 30, z: 0),
            c: Vec3(x: 0, y: 0, z: 30),
            provenance: .joinery(seamID: "seam", featureID: "pin")
        )
        let mesh = AttributedMesh(
            triangles: [source, cap, joinery],
            sourceGeometryFingerprint: "source",
            sourceReferencedVertices: [source.a, source.b, source.c],
            omittedDegenerateSourceFaceIDs: []
        )

        let area = UndercutSplitPlanner.correctedDraftAdvisoryArea(
            mesh: mesh,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            draftAdvisoryDegrees: 1
        )
        XCTAssertEqual(area, source.area, accuracy: 1.0e-12)
    }

    func testCancellationAndStaleStatePreservePriorExportablePlanAtomically() async throws {
        let source = try box(
            min: Vec3(x: -10, y: -10, z: -10),
            max: Vec3(x: 10, y: 10, z: 10)
        )
        let prior = try await UndercutSplitPlanner.plan(
            geometry: source,
            settings: .defaultValue
        )
        let oldSignature = PartitionInputSignature(
            effectiveSourceFingerprint: SourceFaceMap.geometryFingerprint(of: source),
            settings: .defaultValue
        )
        var changedSettings = PartitionSettings.defaultValue
        changedSettings.purpose = .splitByUndercuts
        changedSettings.undercutSplit = .defaultValue
        changedSettings.undercutSplit?.undercutToleranceMM = 1
        let changedSignature = PartitionInputSignature(
            effectiveSourceFingerprint: SourceFaceMap.geometryFingerprint(of: source),
            settings: changedSettings
        )
        var state = PartitionUndercutGenerationState(
            plan: prior,
            generatedSignature: oldSignature
        )
        let token = state.begin()
        state.cancel(token: token)

        XCTAssertEqual(state.plan, prior)
        XCTAssertNotNil(state.exportablePlan)
        XCTAssertTrue(state.isStale(comparedWith: changedSignature))
        XCTAssertNotNil(state.inspectablePlan(comparedWith: changedSignature))

        let errorToken = state.begin()
        state.fail(
            message: "Analysis failed at interval construction on Piece B.",
            token: errorToken
        )
        XCTAssertEqual(state.plan, prior)
        XCTAssertNotNil(state.exportablePlan)
        XCTAssertEqual(
            state.failureMessage,
            "Analysis failed at interval construction on Piece B."
        )

        let staleToken = state.begin()
        let otherToken = state.begin()
        XCTAssertFalse(state.commit(prior, signature: changedSignature, token: staleToken))
        XCTAssertTrue(state.commit(prior, signature: changedSignature, token: otherToken))
        XCTAssertEqual(state.generatedSignature, changedSignature)

        let counter = CancellationCounter(cancelAfter: 5)
        await XCTAssertThrowsErrorAsync(try await UndercutSplitPlanner.plan(
            geometry: try blindSideHoleBlock(),
            settings: .defaultValue,
            shouldCancel: { counter.shouldCancel() }
        )) { error in
            XCTAssertEqual(error as? UndercutSplitPlanner.Error, .cancelled)
        }
    }

    func testPurposeRoutingKeepsFitPrinterAndUndercutPipelinesSeparate() {
        XCTAssertEqual(PartitionGenerationRoute(purpose: .fitPrinter), .fitPrinter)
        XCTAssertEqual(PartitionGenerationRoute(purpose: .splitByUndercuts), .splitByUndercuts)
    }

    func testPurposeCoordinatorExecutesOnlySelectedPipelineAndContentUsesIt() async throws {
        let recorder = PartitionRouteRecorder()
        let fitResult: PartitionGenerationRoute = await PartitionGenerationCoordinator.run(
            purpose: .fitPrinter,
            fitPrinter: {
                await recorder.record(.fitPrinter)
                return .fitPrinter
            },
            splitByUndercuts: {
                await recorder.record(.splitByUndercuts)
                return .splitByUndercuts
            }
        )
        XCTAssertEqual(fitResult, .fitPrinter)
        let fitCalls = await recorder.snapshot()
        XCTAssertEqual(fitCalls, [.fitPrinter])

        await recorder.reset()
        let splitResult: PartitionGenerationRoute = await PartitionGenerationCoordinator.run(
            purpose: .splitByUndercuts,
            fitPrinter: {
                await recorder.record(.fitPrinter)
                return .fitPrinter
            },
            splitByUndercuts: {
                await recorder.record(.splitByUndercuts)
                return .splitByUndercuts
            }
        )
        XCTAssertEqual(splitResult, .splitByUndercuts)
        let splitCalls = await recorder.snapshot()
        XCTAssertEqual(splitCalls, [.splitByUndercuts])

        let contentViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RefabArtist/ContentView.swift")
        let contentViewSource = try String(contentsOf: contentViewURL, encoding: .utf8)
        XCTAssertTrue(
            contentViewSource.contains("PartitionGenerationCoordinator.run"),
            "ContentView Generate must call the tested purpose coordinator; a standalone routing enum is a facade."
        )
    }

    func testDeterministicDoubleRunUsesRealActorCache() async throws {
        let source = try blindSideHoleBlock()
        var settings = UndercutSplitSettings.defaultValue
        settings.pullPolicy = .fixed
        settings.fixedPullDirection = Vec3(x: 0, y: 0, z: 1)
        settings.undercutToleranceMM = 2
        settings.minRegionAreaMM2 = 0
        settings.maxPieces = 3
        settings.quality = .quick
        settings.seed = 8675309
        let cache = UndercutSplitPlannerCache(maximumEntryCount: 64)

        let first = try await UndercutSplitPlanner.plan(
            geometry: source,
            settings: settings,
            cache: cache
        )
        let firstStats = await cache.statistics
        let second = try await UndercutSplitPlanner.plan(
            geometry: source,
            settings: settings,
            cache: cache
        )
        let secondStats = await cache.statistics

        XCTAssertEqual(first.cutTree, second.cutTree)
        XCTAssertEqual(first.deterministicFingerprint, second.deterministicFingerprint)
        XCTAssertEqual(first.pieces.map(\.mesh.stableFingerprint), second.pieces.map(\.mesh.stableFingerprint))
        XCTAssertEqual(first.pieces.map(\.measurement), second.pieces.map(\.measurement))
        XCTAssertGreaterThan(secondStats.hitCount, firstStats.hitCount)
        XCTAssertGreaterThan(firstStats.missCount, 0)
    }

    func testCacheKeyIncludesGeometryAxisAndEveryAnalyzerInputVersion() {
        let baseline = DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: 0.5,
            gridDivisor: 128,
            refinementPasses: 1,
            maximumSamples: 100,
            linearWeldMM: 1.0e-6,
            rayHitCoincidenceMM: 1.0e-7,
            minimumTriangleAreaMM2: 1.0e-12,
            draftAdvisoryDegrees: 1
        )
        let key = UndercutSplitPlannerCache.Key(
            measurementGeometryFingerprint: "geometry-a",
            pullAxis: Vec3(x: 1, y: 0, z: 0),
            configuration: baseline,
            plannerVersion: 1,
            tolerancePolicyVersion: 1
        )
        let reversedAxis = UndercutSplitPlannerCache.Key(
            measurementGeometryFingerprint: "geometry-a",
            pullAxis: Vec3(x: -1, y: 0, z: 0),
            configuration: baseline,
            plannerVersion: 1,
            tolerancePolicyVersion: 1
        )
        XCTAssertEqual(key, reversedAxis, "d and -d are the same undirected cache axis")
        let mutations: [UndercutSplitPlannerCache.Key] = [
            .init(measurementGeometryFingerprint: "geometry-b", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: baseline, plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 0, y: 1, z: 0), configuration: baseline, plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, targetGridStepMM: 0.75), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, gridDivisor: 256), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, refinementPasses: 2), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, maximumSamples: 101), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, linearWeldMM: 2.0e-6), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, rayHitCoincidenceMM: 2.0e-7), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, minimumTriangleAreaMM2: 2.0e-12), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: changed(baseline, draftAdvisoryDegrees: 2), plannerVersion: 1, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: baseline, plannerVersion: 2, tolerancePolicyVersion: 1),
            .init(measurementGeometryFingerprint: "geometry-a", pullAxis: Vec3(x: 1, y: 0, z: 0), configuration: baseline, plannerVersion: 1, tolerancePolicyVersion: 2),
        ]
        for mutation in mutations { XCTAssertNotEqual(key, mutation) }
    }

    func testAsyncCacheIsBoundedLRUAndReportsHitsMissesAndEvictions() async {
        let cache = UndercutSplitPlannerCache(maximumEntryCount: 2)
        let configuration = DirectionalAccessibilityAnalyzer.Configuration(quality: .quick)
        func key(_ id: String) -> UndercutSplitPlannerCache.Key {
            .init(
                measurementGeometryFingerprint: id,
                pullAxis: Vec3(x: 0, y: 0, z: 1),
                configuration: configuration,
                plannerVersion: 1,
                tolerancePolicyVersion: UndercutSplitTolerancePolicy.current.version
            )
        }
        let first = key("first")
        let second = key("second")
        let third = key("third")
        let value = syntheticMeasurement(depth: 0, area: 0)

        await cache.insert(value, for: first)
        await cache.insert(value, for: second)
        let firstRead = await cache.value(for: first)
        XCTAssertNotNil(firstRead, "Reading first makes it most-recently used")
        await cache.insert(value, for: third)

        let entryCount = await cache.entryCount
        let retainedFirst = await cache.value(for: first)
        let evictedSecond = await cache.value(for: second)
        let retainedThird = await cache.value(for: third)
        let statistics = await cache.statistics
        XCTAssertEqual(entryCount, 2)
        XCTAssertNotNil(retainedFirst)
        XCTAssertNil(evictedSecond)
        XCTAssertNotNil(retainedThird)
        XCTAssertGreaterThanOrEqual(statistics.hitCount, 3)
        XCTAssertGreaterThanOrEqual(statistics.missCount, 1)
        XCTAssertEqual(statistics.evictionCount, 1)
    }

    func testEveryCandidatePrefilterHasAnExactObservableReason() {
        var settings = UndercutSplitSettings.defaultValue
        settings.minimumPieceVolumeFraction = 0.005
        settings.minimumPieceVolumeMM3 = 1
        settings.minimumSeamAreaMM2 = 4
        settings.faceConstraints.noCutSourceFaceIDs = [SourceFaceID(rawValue: 7)]

        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(splitsLeaf: false),
            settings: settings
        ).contains(.doesNotSplitLeaf))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(childVolumesMM3: [0.5, 999.5]),
            settings: settings
        ).contains(.minimumPieceVolume))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(crossedNoCutSourceFaceIDs: [SourceFaceID(rawValue: 7)]),
            settings: settings
        ).contains(.crossesNoCutFace))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(seamAreaMM2: 3.9),
            settings: settings
        ).contains(.minimumSeamArea))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(
                inputComponentCount: 5,
                crossedInputComponentCount: 1,
                outputComponentCount: 7
            ),
            settings: settings
        ).contains(.unrequestedDisconnectedFragments))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(childrenAreClosed: false),
            settings: settings
        ).contains(.childrenNotClosed))
        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(
                conservationMissingVolumeMM3: 0.02,
                conservationToleranceMM3: 0.01
            ),
            settings: settings
        ).contains(.volumeConservation))

        XCTAssertTrue(UndercutSplitPlanner.prefilterRejections(
            for: prefilterFacts(
                inputComponentCount: 5,
                crossedInputComponentCount: 1,
                outputComponentCount: 6
            ),
            settings: settings
        ).isEmpty, "Inherited healed-scan components are not new cut fragments")
    }

    func testComponentAdmissionRetainsTinyHealedShellsButBlocksTwoMacroBodies() {
        let healedScan = UndercutSplitPlanner.classifyInputComponents(
            signedVolumesMM3: [303_720.108, -0.234, -0.075, -1.264, -0.240],
            settings: .defaultValue
        )
        XCTAssertEqual(healedScan.macroscopicComponentIndices, [0])
        XCTAssertEqual(healedScan.retainedMinorComponentIndices, [1, 2, 3, 4])
        XCTAssertFalse(healedScan.blocksPlanning)

        let separateObjects = UndercutSplitPlanner.classifyInputComponents(
            signedVolumesMM3: [1_000, 1_000],
            settings: .defaultValue
        )
        XCTAssertEqual(separateObjects.macroscopicComponentIndices, [0, 1])
        XCTAssertTrue(separateObjects.blocksPlanning)
    }

    func testAlternativeSelectionDeduplicatesTreesAndCapsProfilesAtThree() throws {
        let a = try oneCutTree(offset: -1)
        let b = try oneCutTree(offset: 0)
        let c = try oneCutTree(offset: 1)
        let candidates = [
            UndercutSplitPlanner.AlternativeCandidate(
                priority: .fewerPieces,
                cutTree: a,
                objective: objective(excessDepthMM: 3),
                deterministicFingerprint: "a"
            ),
            UndercutSplitPlanner.AlternativeCandidate(
                priority: .balanced,
                cutTree: b,
                objective: objective(excessDepthMM: 2),
                deterministicFingerprint: "b"
            ),
            UndercutSplitPlanner.AlternativeCandidate(
                priority: .cleanerSeams,
                cutTree: c,
                objective: objective(excessDepthMM: 1),
                deterministicFingerprint: "c"
            ),
            UndercutSplitPlanner.AlternativeCandidate(
                priority: .balanced,
                cutTree: a,
                objective: objective(excessDepthMM: 4),
                deterministicFingerprint: "duplicate-a"
            ),
        ]

        let selected = UndercutSplitPlanner.selectAlternatives(
            candidates,
            maximumCount: 3
        )
        XCTAssertEqual(selected.count, 3)
        for index in selected.indices {
            for other in selected.indices where other > index {
                XCTAssertNotEqual(selected[index].cutTree, selected[other].cutTree)
            }
        }
        XCTAssertEqual(Set(selected.map { $0.priority.rawValue }).count, selected.count)
    }

    func testCoordinateDescentRefinementNeverRegressesToleranceKeys() throws {
        let initial = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0.75
        ))
        let refined = UndercutSplitPlanner.refinePlane(
            initial,
            resolutionMM: 0.25,
            maximumPasses: 4,
            priority: .balanced
        ) { plane in
            self.objective(excessDepthMM: abs(plane.offset))
        }

        XCTAssertLessThan(abs(refined.plane.offset), abs(initial.offset))
        XCTAssertFalse(refined.acceptedSteps.isEmpty)
        for step in refined.acceptedSteps {
            XCTAssertLessThanOrEqual(
                step.after.exceedingPieceCount,
                step.before.exceedingPieceCount
            )
            XCTAssertLessThanOrEqual(
                step.after.totalExcessDepthMM,
                step.before.totalExcessDepthMM
            )
            XCTAssertLessThanOrEqual(
                step.after.totalOverToleranceAreaMM2,
                step.before.totalOverToleranceAreaMM2
            )
            XCTAssertTrue(step.after.isBetter(than: step.before, priority: .balanced))
        }
    }

    func testMeasurementAndFinalizationFailuresUseMeasuredExportSafeWording() {
        let measurement = UndercutSplitPlanner.failurePresentation(
            .measurement(stage: "interval construction", pieceLabel: "Piece B")
        )
        XCTAssertEqual(measurement.status, .analysisError)
        XCTAssertFalse(measurement.measurementAttached)
        XCTAssertTrue(measurement.isExportable)
        XCTAssertTrue(measurement.message.contains("Analysis failed at interval construction on Piece B"))
        XCTAssertTrue(measurement.message.contains("can still be exported"))

        let finalization = UndercutSplitPlanner.failurePresentation(
            .fullResolutionFinalization(
                stage: "volume conservation",
                detail: "missing volume exceeded tolerance"
            )
        )
        XCTAssertEqual(finalization.status, .analysisError)
        XCTAssertTrue(finalization.isExportable)
        XCTAssertTrue(finalization.message.contains("Full-resolution finalization failed"))
        XCTAssertTrue(finalization.message.contains("volume conservation"))
        for forbidden in ["proven", "guaranteed", "impossible", "cannot export", "export disabled"] {
            XCTAssertFalse(finalization.message.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testUndercutSignatureIncludesPurposeAndEveryPlanningInput() throws {
        let fingerprint = "effective-source"
        var base = PartitionSettings.defaultValue
        base.purpose = .splitByUndercuts
        base.undercutSplit = .defaultValue
        let baseline = PartitionInputSignature(
            effectiveSourceFingerprint: fingerprint,
            settings: base
        )
        var mutations: [PartitionSettings] = []
        func append(_ mutation: (inout UndercutSplitSettings) -> Void) {
            var settings = base
            var split = settings.undercutSplit ?? .defaultValue
            mutation(&split)
            settings.undercutSplit = split
            mutations.append(settings)
        }
        append { $0.planningMode = .manual }
        append { $0.pullPolicy = .fixed }
        append { $0.fixedPullDirection = Vec3(x: 1, y: 0, z: 0) }
        append { $0.undercutToleranceMM = 3 }
        append { $0.minRegionAreaMM2 = 5 }
        append { $0.quality = .thorough }
        append { $0.maxPieces = 7 }
        append { $0.priority = .cleanerSeams }
        append { $0.draftAdvisoryDegrees = 2 }
        append { $0.minimumPieceVolumeFraction = 0.006 }
        append { $0.minimumPieceVolumeMM3 = 2 }
        append { $0.minimumSeamAreaMM2 = 5 }
        append {
            var pins = PartitionKeySettings.defaultValue
            pins.type = .pins
            $0.seamKeys = .pins(pins)
        }
        append {
            $0.faceConstraints.noCutSourceFaceIDs = [SourceFaceID(rawValue: 1)]
        }
        append {
            $0.lockedPullDirections = [
                PartitionRegionID(rawValue: "region"): Vec3(x: 0, y: 1, z: 0),
            ]
        }
        append { $0.seed = 1 }
        append { $0.plannerVersion = 2 }
        append { $0.tolerancePolicyVersion = 2 }

        let root = PartitionRegionID.root(sourceGeometryFingerprint: fingerprint)
        var authored = base
        authored.undercutSplit?.authoredCutTree = try PersistedCutTreeEnvelope(
            tree: PartitionCutTree(rootRegionID: root, nodes: []),
            sourceGeometryFingerprint: fingerprint
        )
        mutations.append(authored)
        var fitPrinter = base
        fitPrinter.purpose = .fitPrinter
        mutations.append(fitPrinter)

        for mutation in mutations {
            XCTAssertNotEqual(
                baseline,
                PartitionInputSignature(
                    effectiveSourceFingerprint: fingerprint,
                    settings: mutation
                )
            )
        }
        XCTAssertNotEqual(
            baseline,
            PartitionInputSignature(
                effectiveSourceFingerprint: "different-source",
                settings: base
            )
        )
    }

    func testEffectiveFingerprintDetectsInteriorChangeWithSamePathCountAndBounds() throws {
        var first = try box(
            min: Vec3(x: -5, y: -5, z: -5),
            max: Vec3(x: 5, y: 5, z: 5)
        )
        let originalIndex = Int(first.triangleIndices[0])
        first.vertices.append(first.vertices[originalIndex])
        first.triangleIndices[0] = Int32(first.vertices.count - 1)
        var changed = first
        let duplicatedX = changed.vertices[changed.vertices.count - 1].x
        changed.vertices[changed.vertices.count - 1].x += duplicatedX > 0 ? -0.25 : 0.25
        XCTAssertEqual(first.triangleIndices.count, changed.triangleIndices.count)
        XCTAssertEqual(bounds(of: first), bounds(of: changed))

        let settings = PartitionSettings.defaultValue
        let lhs = PartitionInputSignature(
            effectiveSourceFingerprint: SourceFaceMap.geometryFingerprint(of: first),
            settings: settings
        )
        let rhs = PartitionInputSignature(
            effectiveSourceFingerprint: SourceFaceMap.geometryFingerprint(of: changed),
            settings: settings
        )
        XCTAssertNotEqual(lhs, rhs)
    }

    func testDebugHealedHandMedianCuts() throws {
        guard ProcessInfo.processInfo.environment["UNDERCUT_SPLIT_CAP_DEBUG"] == "1" else {
            throw XCTSkip("Temporary cap diagnostic")
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handStand_ex3_healed_50k.obj")
        let geometry = try MeshInspector.inspect(url: url).geometry
        let attributed = try SourceFaceMap.attributedMesh(from: geometry)
        let modelBounds = try XCTUnwrap(bounds(of: geometry))
        let axes = [
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 0, y: 0, z: 1),
        ]
        for (ordinal, axis) in axes.enumerated() {
            let lower = axis.x != 0 ? modelBounds.min.x : (axis.y != 0 ? modelBounds.min.y : modelBounds.min.z)
            let upper = axis.x != 0 ? modelBounds.max.x : (axis.y != 0 ? modelBounds.max.y : modelBounds.max.z)
            let plane = try XCTUnwrap(CanonicalPlane(
                normal: axis,
                offset: (lower + upper) / 2 + 0.00005
            ))
            let node = PartitionCutNode.automatic(
                plannerVersion: 1,
                targetRegionID: .root(sourceGeometryFingerprint: attributed.sourceGeometryFingerprint),
                plane: plane,
                siblingOrdinal: ordinal,
                isLocked: false
            )
            do {
                let split = try PartitionGeometry.splitAttributed(
                    attributed,
                    plane: plane,
                    cutNodeID: node.id
                )
                print("UNDERCUT_CAP_DEBUG success axis=\(axis) volumes=\(split.negative.signedVolume),\(split.positive.signedVolume)")
                if ordinal == 0 {
                    let policy = UndercutSplitTolerancePolicy.current
                    let configuration = DirectionalAccessibilityAnalyzer.Configuration(
                        targetGridStepMM: 1,
                        gridDivisor: 128,
                        refinementPasses: 0,
                        maximumSamples: 60_000,
                        linearWeldMM: policy.linearWeldMM,
                        rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
                        minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
                        draftAdvisoryDegrees: 1
                    )
                    for (side, mesh) in [("negative", split.negative), ("positive", split.positive)] {
                        for pull in axes {
                            let result = try DirectionalAccessibilityAnalyzer.analyze(
                                geometry: mesh.geometry,
                                pullAxis: pull,
                                configuration: configuration
                            )
                            print("UNDERCUT_CAP_DEBUG measure side=\(side) pull=\(pull) depth=\(result.worstDepthMM) status=\(result.status(toleranceMM: 2, minRegionAreaMM2: 4))")
                        }
                    }
                }
            } catch {
                print("UNDERCUT_CAP_DEBUG failed axis=\(axis) error=\(error.localizedDescription)")
            }
        }

        let sourcePolicy = UndercutSplitTolerancePolicy.current
        let sourceConfiguration = DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: 1,
            gridDivisor: 128,
            refinementPasses: 0,
            maximumSamples: 60_000,
            linearWeldMM: sourcePolicy.linearWeldMM,
            rayHitCoincidenceMM: sourcePolicy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: sourcePolicy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: 1
        )
        let sourceMeasurement = try DirectionalAccessibilityAnalyzer.analyze(
            geometry: attributed.geometry,
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            configuration: sourceConfiguration
        )
        let worstRegions = sourceMeasurement.regions
            .filter { $0.areaMM2 >= 4 && $0.depthMM > 2 }
            .sorted {
                if $0.depthMM != $1.depthMM { return $0.depthMM > $1.depthMM }
                return $0.id < $1.id
            }
        print("UNDERCUT_SOURCE_REGIONS \(worstRegions.prefix(12).map { ($0.depthMM, $0.areaMM2, $0.centroid, $0.suggestedEscapeDirections) })")
        for (regionIndex, region) in worstRegions.prefix(5).enumerated() {
            var candidateSplit: PartitionGeometry.AttributedSplit?
            for perturbation in [0.00005, 0.01, -0.01, 0.1, -0.1, 0.5, -0.5] {
                let plane = try XCTUnwrap(CanonicalPlane(
                    normal: Vec3(x: 0, y: 0, z: 1),
                    offset: region.centroid.z + perturbation
                ))
                if let split = try? PartitionGeometry.splitAttributed(
                    attributed,
                    plane: plane,
                    cutNodeID: PartitionCutNodeID(rawValue: "debug-region-\(regionIndex)")
                ) {
                    candidateSplit = split
                    break
                }
            }
            guard let candidateSplit else { continue }
            for (side, mesh) in [("negative", candidateSplit.negative), ("positive", candidateSplit.positive)] {
                let results = try axes.map { axis in
                    try DirectionalAccessibilityAnalyzer.analyze(
                        geometry: mesh.geometry,
                        pullAxis: axis,
                        configuration: sourceConfiguration
                    )
                }
                print("UNDERCUT_REGION_CUT region=\(regionIndex) z=\(region.centroid.z) side=\(side) volume=\(abs(mesh.signedVolume)) depths=\(results.map(\.worstDepthMM))")
            }
        }

        var octants = [attributed]
        for (axisIndex, axis) in axes.enumerated() {
            var next: [AttributedMesh] = []
            for (leafIndex, leaf) in octants.enumerated() {
                let leafBounds = try XCTUnwrap(bounds(of: leaf.geometry))
                let lower = axis.x != 0 ? leafBounds.min.x : (axis.y != 0 ? leafBounds.min.y : leafBounds.min.z)
                let upper = axis.x != 0 ? leafBounds.max.x : (axis.y != 0 ? leafBounds.max.y : leafBounds.max.z)
                var earnedSplit: PartitionGeometry.AttributedSplit?
                for perturbation in [0.00005, 0.01, -0.01, 0.1, -0.1, 0.5, -0.5] {
                    let plane = try XCTUnwrap(CanonicalPlane(
                        normal: axis,
                        offset: (lower + upper) / 2 + perturbation
                    ))
                    if let split = try? PartitionGeometry.splitAttributed(
                        leaf,
                        plane: plane,
                        cutNodeID: PartitionCutNodeID(rawValue: "debug-octant-\(axisIndex)-\(leafIndex)")
                    ) {
                        earnedSplit = split
                        break
                    }
                }
                let split = try XCTUnwrap(earnedSplit)
                next.append(contentsOf: [split.negative, split.positive])
            }
            octants = next
        }
        let policy = UndercutSplitTolerancePolicy.current
        let octantConfiguration = DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: 1,
            gridDivisor: 128,
            refinementPasses: 0,
            maximumSamples: 60_000,
            linearWeldMM: policy.linearWeldMM,
            rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: 1
        )
        for (index, leaf) in octants.enumerated() {
            let measurements = try axes.map { axis in
                try DirectionalAccessibilityAnalyzer.analyze(
                    geometry: leaf.geometry,
                    pullAxis: axis,
                    configuration: octantConfiguration
                )
            }
            print("UNDERCUT_OCTANT index=\(index) volume=\(abs(leaf.signedVolume)) depths=\(measurements.map(\.worstDepthMM))")
        }

        let center = Vec3(
            x: (modelBounds.min.x + modelBounds.max.x) / 2,
            y: (modelBounds.min.y + modelBounds.max.y) / 2,
            z: (modelBounds.min.z + modelBounds.max.z) / 2
        )
        func debugSplit(
            _ leaves: [AttributedMesh],
            normal: (AttributedMesh) -> Vec3,
            label: String
        ) throws -> [AttributedMesh] {
            var result: [AttributedMesh] = []
            for (index, leaf) in leaves.enumerated() {
                let axis = normal(leaf)
                let baseOffset = axis.x * center.x + axis.y * center.y + axis.z * center.z
                var earned: PartitionGeometry.AttributedSplit?
                for delta in [0.00005, 0.01, -0.01, 0.1, -0.1, 0.5, -0.5] {
                    let plane = try XCTUnwrap(CanonicalPlane(
                        normal: axis,
                        offset: baseOffset + delta
                    ))
                    if let split = try? PartitionGeometry.splitAttributed(
                        leaf,
                        plane: plane,
                        cutNodeID: PartitionCutNodeID(rawValue: "debug-wedge-\(label)-\(index)")
                    ) {
                        earned = split
                        break
                    }
                }
                let split = try XCTUnwrap(earned)
                result.append(contentsOf: [split.negative, split.positive])
            }
            return result
        }
        var wedges = try debugSplit(
            [attributed],
            normal: { _ in Vec3(x: 1, y: 0, z: 0) },
            label: "x"
        )
        wedges = try debugSplit(
            wedges,
            normal: { _ in Vec3(x: 0, y: 1, z: 0) },
            label: "y"
        )
        wedges = try debugSplit(
            wedges,
            normal: { leaf in
                let bounds = self.bounds(of: leaf.geometry)!
                let sx = ((bounds.min.x + bounds.max.x) / 2) - center.x
                let sy = ((bounds.min.y + bounds.max.y) / 2) - center.y
                return sx * sy >= 0
                    ? Vec3(x: 1, y: -1, z: 0)
                    : Vec3(x: 1, y: 1, z: 0)
            },
            label: "diagonal"
        )
        for (index, leaf) in wedges.enumerated() {
            let leafBounds = try XCTUnwrap(bounds(of: leaf.geometry))
            let radial = Vec3(
                x: (leafBounds.min.x + leafBounds.max.x) / 2 - center.x,
                y: (leafBounds.min.y + leafBounds.max.y) / 2 - center.y,
                z: 0
            )
            let pulls = axes + [radial]
            let measurements = try pulls.map { axis in
                try DirectionalAccessibilityAnalyzer.analyze(
                    geometry: leaf.geometry,
                    pullAxis: axis,
                    configuration: octantConfiguration
                )
            }
            print("UNDERCUT_WEDGE index=\(index) volume=\(abs(leaf.signedVolume)) depths=\(measurements.map(\.worstDepthMM))")
        }
    }

    // MARK: - Helpers

    private func prefilterFacts(
        splitsLeaf: Bool = true,
        childVolumesMM3: [Double] = [500, 500],
        crossedNoCutSourceFaceIDs: [SourceFaceID] = [],
        seamAreaMM2: Double = 100,
        inputComponentCount: Int = 1,
        crossedInputComponentCount: Int = 1,
        outputComponentCount: Int = 2,
        childrenAreClosed: Bool = true,
        conservationMissingVolumeMM3: Double = 0,
        conservationExcessVolumeMM3: Double = 0,
        conservationToleranceMM3: Double = 0.01
    ) -> UndercutSplitPlanner.CandidatePrefilterFacts {
        .init(
            splitsLeaf: splitsLeaf,
            childVolumesMM3: childVolumesMM3,
            sourceVolumeMM3: childVolumesMM3.reduce(0, +),
            crossedNoCutSourceFaceIDs: crossedNoCutSourceFaceIDs,
            seamAreaMM2: seamAreaMM2,
            inputComponentCount: inputComponentCount,
            crossedInputComponentCount: crossedInputComponentCount,
            outputComponentCount: outputComponentCount,
            childrenAreClosed: childrenAreClosed,
            conservationMissingVolumeMM3: conservationMissingVolumeMM3,
            conservationExcessVolumeMM3: conservationExcessVolumeMM3,
            conservationToleranceMM3: conservationToleranceMM3
        )
    }

    private func objective(excessDepthMM: Double) -> UndercutSplitObjective {
        UndercutSplitObjective(
            exceedingPieceCount: excessDepthMM > 0 ? 1 : 0,
            totalExcessDepthMM: excessDepthMM,
            totalOverToleranceAreaMM2: excessDepthMM > 0 ? 10 : 0,
            pieceCount: 2,
            sliverPenalty: 0,
            seamDetailPenalty: 0,
            totalSeamAreaMM2: 10,
            pieceVolumeVariance: 0,
            deterministicTieBreak: String(format: "%.9f", excessDepthMM)
        )
    }

    private func oneCutTree(offset: Double) throws -> PartitionCutTree {
        let root = PartitionRegionID(rawValue: "root")
        let plane = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: offset
        ))
        return PartitionCutTree(
            rootRegionID: root,
            nodes: [PartitionCutNode.automatic(
                plannerVersion: 1,
                targetRegionID: root,
                plane: plane,
                siblingOrdinal: 0,
                isLocked: false
            )]
        )
    }

    private func changed(
        _ value: DirectionalAccessibilityAnalyzer.Configuration,
        targetGridStepMM: Double? = nil,
        gridDivisor: Double? = nil,
        refinementPasses: Int? = nil,
        maximumSamples: Int? = nil,
        linearWeldMM: Double? = nil,
        rayHitCoincidenceMM: Double? = nil,
        minimumTriangleAreaMM2: Double? = nil,
        draftAdvisoryDegrees: Double? = nil
    ) -> DirectionalAccessibilityAnalyzer.Configuration {
        .init(
            targetGridStepMM: targetGridStepMM ?? value.targetGridStepMM,
            gridDivisor: gridDivisor ?? value.gridDivisor,
            refinementPasses: refinementPasses ?? value.refinementPasses,
            maximumSamples: maximumSamples ?? value.maximumSamples,
            linearWeldMM: linearWeldMM ?? value.linearWeldMM,
            rayHitCoincidenceMM: rayHitCoincidenceMM ?? value.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: minimumTriangleAreaMM2 ?? value.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: draftAdvisoryDegrees ?? value.draftAdvisoryDegrees
        )
    }

    private func syntheticMeasurement(
        depth: Double,
        area: Double
    ) -> DirectionalAccessibilityAnalyzer.Result {
        syntheticMeasurement(regions: depth > 0 ? [UndercutRegionClusterer.Region(
            id: "synthetic",
            faceIDs: [0],
            areaMM2: area,
            depthMM: depth,
            centroid: Vec3(x: 0, y: 0, z: 0),
            suggestedEscapeDirections: [Vec3(x: 0, y: 0, z: 1)]
        )] : [])
    }

    private func syntheticMeasurement(
        regions: [UndercutRegionClusterer.Region]
    ) -> DirectionalAccessibilityAnalyzer.Result {
        .init(
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            regions: regions,
            baseResolutionMM: 0.5,
            effectiveResolutionMM: 0.5,
            sampleCount: 1,
            maximumSamples: 1,
            violatingColumnCount: regions.isEmpty ? 0 : 1,
            sampleBudgetExhausted: false,
            discardedDegenerateTriangleCount: 0,
            nearVerticalWallAreaMM2: 0
        )
    }

    private func blindSideHoleBlock() throws -> MeshGeometryData {
        let solid = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 20, z: 20)
        ))
        let cutter = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: -3, z: 0),
            extents: Vec3(x: 10, y: 16, z: 4)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.difference(solid, cutter))
    }

    private func orthogonalDoubleHook() throws -> MeshGeometryData {
        func hookedBlock(openingAlongX: Bool, centerX: Double) throws -> ManifoldHandle {
            let body = try ManifoldEngine.box(ManifoldBoxSpec(
                center: Vec3(x: centerX, y: 0, z: 0),
                extents: Vec3(x: 20, y: 20, z: 20)
            ))
            let cutterCenter = openingAlongX
                ? Vec3(x: centerX - 3, y: 0, z: 0)
                : Vec3(x: centerX, y: -3, z: 0)
            let cutterExtents = openingAlongX
                ? Vec3(x: 16, y: 10, z: 4)
                : Vec3(x: 10, y: 16, z: 4)
            let cutter = try ManifoldEngine.box(ManifoldBoxSpec(
                center: cutterCenter,
                extents: cutterExtents
            ))
            return try ManifoldEngine.difference(body, cutter)
        }
        let left = try hookedBlock(openingAlongX: true, centerX: -12)
        let right = try hookedBlock(openingAlongX: false, centerX: 12)
        let bridge = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 6, z: -6),
            extents: Vec3(x: 8, y: 6, z: 6)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.union([left, right, bridge]))
    }

    private func disjointEqualBoxes() throws -> MeshGeometryData {
        let left = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: -15, y: 0, z: 0),
            extents: Vec3(x: 10, y: 10, z: 10)
        ))
        let right = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 15, y: 0, z: 0),
            extents: Vec3(x: 10, y: 10, z: 10)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.union([left, right]))
    }

    private func denseOrthogonalDoubleHook(
        minimumTriangleCount: Int
    ) throws -> MeshGeometryData {
        let source = try orthogonalDoubleHook()
        let sourceTriangleCount = source.triangleIndices.count / 3
        let divisions = max(
            1,
            Int(ceil(sqrt(Double(minimumTriangleCount) / Double(sourceTriangleCount))))
        )
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        vertices.reserveCapacity(sourceTriangleCount * divisions * divisions * 3)
        indices.reserveCapacity(sourceTriangleCount * divisions * divisions * 3)

        func interpolated(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ i: Int, _ j: Int) -> Vec3 {
            let u = Double(i) / Double(divisions)
            let v = Double(j) / Double(divisions)
            return Vec3(
                x: a.x + (b.x - a.x) * u + (c.x - a.x) * v,
                y: a.y + (b.y - a.y) * u + (c.y - a.y) * v,
                z: a.z + (b.z - a.z) * u + (c.z - a.z) * v
            )
        }
        func appendTriangle(_ a: Vec3, _ b: Vec3, _ c: Vec3) {
            let base = Int32(vertices.count)
            vertices += [a, b, c]
            indices += [base, base + 1, base + 2]
        }

        for face in 0..<sourceTriangleCount {
            let offset = face * 3
            let a = source.vertices[Int(source.triangleIndices[offset])]
            let b = source.vertices[Int(source.triangleIndices[offset + 1])]
            let c = source.vertices[Int(source.triangleIndices[offset + 2])]
            for i in 0..<divisions {
                for j in 0..<(divisions - i) {
                    let p00 = interpolated(a, b, c, i, j)
                    let p10 = interpolated(a, b, c, i + 1, j)
                    let p01 = interpolated(a, b, c, i, j + 1)
                    appendTriangle(p00, p10, p01)
                    if j < divisions - i - 1 {
                        let p11 = interpolated(a, b, c, i + 1, j + 1)
                        appendTriangle(p10, p11, p01)
                    }
                }
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private func box(min: Vec3, max: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(
                x: (min.x + max.x) / 2,
                y: (min.y + max.y) / 2,
                z: (min.z + max.z) / 2
            ),
            extents: Vec3(
                x: max.x - min.x,
                y: max.y - min.y,
                z: max.z - min.z
            )
        )))
    }

    private func indexedBox(halfExtent h: Double) -> MeshGeometryData {
        let vertices: [Vec3] = [
            Vec3(x: -h, y: -h, z: -h), Vec3(x: h, y: -h, z: -h),
            Vec3(x: h, y: h, z: -h), Vec3(x: -h, y: h, z: -h),
            Vec3(x: -h, y: -h, z: h), Vec3(x: h, y: -h, z: h),
            Vec3(x: h, y: h, z: h), Vec3(x: -h, y: h, z: h),
        ]
        let faces: [(Int32, Int32, Int32)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
            (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5),
        ]
        return MeshGeometryData(
            vertices: vertices,
            triangleIndices: faces.flatMap { [$0.0, $0.1, $0.2] }
        )
    }

    private func bounds(of geometry: MeshGeometryData) -> Bounds3D? {
        guard var minimum = geometry.vertices.first, var maximum = geometry.vertices.first else {
            return nil
        }
        for point in geometry.vertices.dropFirst() {
            minimum = Vec3(x: min(minimum.x, point.x), y: min(minimum.y, point.y), z: min(minimum.z, point.z))
            maximum = Vec3(x: max(maximum.x, point.x), y: max(maximum.y, point.y), z: max(maximum.z, point.z))
        }
        return Bounds3D(min: minimum, max: maximum)
    }
}

private actor PartitionRouteRecorder {
    private var calls: [PartitionGenerationRoute] = []

    func record(_ route: PartitionGenerationRoute) {
        calls.append(route)
    }

    func snapshot() -> [PartitionGenerationRoute] {
        calls
    }

    func reset() {
        calls.removeAll(keepingCapacity: true)
    }
}

private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var count = 0

    init(cancelAfter: Int) { self.cancelAfter = cancelAfter }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count >= cancelAfter
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
