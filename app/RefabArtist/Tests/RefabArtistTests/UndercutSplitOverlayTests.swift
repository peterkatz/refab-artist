import XCTest
@testable import RefabArtist

final class UndercutSplitOverlayTests: XCTestCase {
    func testOverlayUsesMeasuredToleranceAndAreaForRegionSeverity() throws {
        let fixture = try makeFixture()
        var settings = UndercutSplitSettings.defaultValue
        settings.undercutToleranceMM = 2
        settings.minRegionAreaMM2 = 4

        let overlay = UndercutSplitOverlay.make(plan: fixture.plan, settings: settings)
        let measured = try XCTUnwrap(overlay.regions.first { $0.id.contains("measured") })
        XCTAssertEqual(measured.severity, .overTolerance)
        XCTAssertEqual(measured.depthMM, 3)
        XCTAssertEqual(measured.areaMM2, 5)
        XCTAssertEqual(measured.renderMesh?.triangleIndices.count, 3)

        settings.undercutToleranceMM = 3
        let atTolerance = UndercutSplitOverlay.make(plan: fixture.plan, settings: settings)
        XCTAssertEqual(
            atTolerance.regions.first { $0.id.contains("measured") }?.severity,
            .withinToleranceNonzero
        )

        settings.undercutToleranceMM = 0
        settings.minRegionAreaMM2 = 6
        let filteredByArea = UndercutSplitOverlay.make(plan: fixture.plan, settings: settings)
        XCTAssertEqual(
            filteredByArea.regions.first { $0.id.contains("measured") }?.severity,
            .withinToleranceNonzero
        )
    }

    func testFreshFinalMeasurementControlsGreenStateAndStaleClearsIt() throws {
        let fixture = try makeFixture()
        let fresh = UndercutSplitOverlay.make(
            plan: fixture.plan,
            settings: .defaultValue,
            isStale: false
        )
        XCTAssertEqual(
            fresh.pieces.first(where: { $0.regionID == fixture.positiveRegion })?.finalMeasurementPasses,
            true
        )

        let stale = UndercutSplitOverlay.make(
            plan: fixture.plan,
            settings: .defaultValue,
            isStale: true
        )
        XCTAssertFalse(stale.pieces.contains(where: \.finalMeasurementPasses))
    }

    func testStablePieceColorDoesNotDependOnPlanArrayOrder() throws {
        let fixture = try makeFixture()
        let original = UndercutSplitOverlay.make(plan: fixture.plan, settings: .defaultValue)
        var reversedPlan = fixture.plan
        reversedPlan.pieces.reverse()
        let reversed = UndercutSplitOverlay.make(plan: reversedPlan, settings: .defaultValue)

        for piece in original.pieces {
            XCTAssertEqual(
                reversed.pieces.first(where: { $0.regionID == piece.regionID })?.colorIndex,
                piece.colorIndex
            )
        }
    }

    func testTreeExplodeMovesPositiveSubtreeAndKeepsNegativeSibling() throws {
        let fixture = try makeFixture()
        let overlay = UndercutSplitOverlay.make(plan: fixture.plan, settings: .defaultValue)
        let negative = try XCTUnwrap(overlay.pieces.first { $0.regionID == fixture.negativeRegion })
        let positive = try XCTUnwrap(overlay.pieces.first { $0.regionID == fixture.positiveRegion })

        XCTAssertEqual(negative.explodeVector, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(positive.explodeVector, Vec3(x: 1, y: 0, z: 0))
    }

    func testCutSurfaceUsesOneCapSideAndLowDraftUsesSourceFaces() throws {
        let fixture = try makeFixture()
        let overlay = UndercutSplitOverlay.make(
            plan: fixture.plan,
            settings: .defaultValue,
            selectedCutNodeID: fixture.node.id
        )
        let cut = try XCTUnwrap(overlay.cutSurfaces.first)
        XCTAssertTrue(cut.isSelected)
        XCTAssertEqual(cut.renderMesh?.triangleIndices.count, 3)

        let draft = try XCTUnwrap(overlay.regions.first { $0.severity == .draftAdvisory })
        XCTAssertEqual(draft.pieceRegionID, fixture.positiveRegion)
        XCTAssertEqual(draft.renderMesh?.triangleIndices.count, 3)
    }

    func testInteractionTransformPreviewsAuthoredPlaneByStableNodeID() throws {
        let fixture = try makeFixture()
        let base = UndercutSplitOverlay.make(plan: fixture.plan, settings: .defaultValue)
        let movedPlane = try XCTUnwrap(
            CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0.25)
        )
        var movedNode = fixture.node
        movedNode.plane = movedPlane
        movedNode.isLocked = true
        movedNode.source = .manual
        let authored = PartitionCutTree(
            rootRegionID: fixture.plan.cutTree.rootRegionID,
            nodes: [movedNode]
        )
        let measuredRegionID = try XCTUnwrap(base.regions.first { $0.id.contains("measured") }?.id)

        let transformed = base.applying(
            authoredTree: authored,
            selectedCutNodeID: movedNode.id,
            hoveredCutNodeID: movedNode.id,
            isolatedPieceRegionID: fixture.negativeRegion,
            hoveredRegionID: measuredRegionID,
            isStale: true
        )

        let cut = try XCTUnwrap(transformed.cutSurfaces.first)
        XCTAssertEqual(cut.nodeID, movedNode.id)
        XCTAssertEqual(cut.plane, movedPlane)
        XCTAssertTrue(cut.isLocked)
        XCTAssertTrue(cut.isSelected)
        XCTAssertTrue(cut.isHovered)
        XCTAssertNil(cut.renderMesh, "A moved authored plane must not render the retained measured cap as if it moved.")
        XCTAssertEqual(transformed.isolatedPieceRegionID, fixture.negativeRegion)
        XCTAssertEqual(transformed.hoveredRegionID, measuredRegionID)
        XCTAssertTrue(transformed.isStale)
        XCTAssertFalse(transformed.pieces.contains(where: \.finalMeasurementPasses))
        XCTAssertEqual(
            transformed.cutNodeID(
                rayOrigin: Vec3(x: -3, y: 0.2, z: 0.2),
                rayDirection: Vec3(x: 1, y: 0, z: 0)
            ),
            movedNode.id
        )
    }

    func testMissingMeasurementNeverProducesGreenOrZeroResolution() throws {
        let fixture = try makeFixture()
        var plan = fixture.plan
        plan.pieces[0].measurement = nil
        let overlay = UndercutSplitOverlay.make(plan: plan, settings: .defaultValue)

        XCTAssertFalse(
            overlay.pieces.first(where: { $0.regionID == fixture.negativeRegion })?.finalMeasurementPasses ?? true
        )
        XCTAssertEqual(overlay.effectiveResolutionMM, 0.4, "Only the attached piece measurement contributes resolution.")

        plan.pieces[1].measurement = nil
        let unavailable = UndercutSplitOverlay.make(plan: plan, settings: .defaultValue)
        XCTAssertNil(unavailable.effectiveResolutionMM)
        XCTAssertFalse(unavailable.pieces.contains(where: \.finalMeasurementPasses))
    }

    func testSourceFacePaintUsesAttributedIDsAndCpuTrianglePicking() throws {
        let fixture = try makeFixture()
        let base = UndercutSplitOverlay.make(plan: fixture.plan, settings: .defaultValue)
        let picked = base.sourceFaceID(
            rayOrigin: Vec3(x: -3, y: 0.2, z: 0.2),
            rayDirection: Vec3(x: 1, y: 0, z: 0),
            explodeAmount: 0
        )
        XCTAssertEqual(picked, SourceFaceID(rawValue: 0))
        XCTAssertEqual(
            base.measuredRegionID(
                rayOrigin: Vec3(x: -3, y: 0.2, z: 0.2),
                rayDirection: Vec3(x: 1, y: 0, z: 0),
                explodeAmount: 0
            ),
            base.regions.first(where: { $0.id.contains("measured") })?.id
        )
        XCTAssertEqual(
            base.cutNodeID(
                rayOrigin: Vec3(x: -3, y: 0.2, z: 0.2),
                rayDirection: Vec3(x: 1, y: 0, z: 0)
            ),
            fixture.node.id
        )

        let painted = base.applying(
            authoredTree: nil,
            selectedCutNodeID: nil,
            hoveredCutNodeID: nil,
            isolatedPieceRegionID: nil,
            hoveredRegionID: nil,
            isStale: true,
            faceConstraints: PartitionFaceConstraints(
                noCutSourceFaceIDs: [SourceFaceID(rawValue: 0)],
                preferredSeamFaces: [
                    PreferredSeamFace(sourceFaceID: SourceFaceID(rawValue: 1), weight: 1)
                ]
            ),
            facePaintMode: .noCut
        )
        XCTAssertEqual(painted.paintPatches.count, 2)
        XCTAssertEqual(
            painted.paintPatches.first(where: { $0.mode == .noCut })?.renderMesh.triangleIndices.count,
            3
        )
        XCTAssertEqual(
            painted.paintPatches.first(where: { $0.mode == .preferredSeam })?.renderMesh.triangleIndices.count,
            3
        )
        XCTAssertEqual(painted.facePaintMode, .noCut)
        XCTAssertFalse(painted.facePaintFingerprint.isEmpty)
    }

    private struct Fixture {
        var plan: UndercutSplitPlan
        var node: PartitionCutNode
        var negativeRegion: PartitionRegionID
        var positiveRegion: PartitionRegionID
    }

    private func makeFixture() throws -> Fixture {
        let sourceFingerprint = "overlay-fixture"
        let root = PartitionRegionID.root(sourceGeometryFingerprint: sourceFingerprint)
        let plane = try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0))
        let node = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: root,
            plane: plane,
            siblingOrdinal: 0,
            isLocked: false
        )

        let measuredTriangle = AttributedTriangle(
            a: Vec3(x: -1, y: 0, z: 0),
            b: Vec3(x: -1, y: 1, z: 0),
            c: Vec3(x: -1, y: 0, z: 1),
            provenance: .source(SourceFaceID(rawValue: 0))
        )
        let negativeCap = AttributedTriangle(
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 1, z: 0),
            c: Vec3(x: 0, y: 0, z: 1),
            provenance: .cut(nodeID: node.id, side: .negative)
        )
        let lowDraftTriangle = AttributedTriangle(
            a: Vec3(x: 1, y: 0, z: 0),
            b: Vec3(x: 2, y: 0, z: 0),
            c: Vec3(x: 1, y: 0, z: 1),
            provenance: .source(SourceFaceID(rawValue: 1))
        )
        let positiveCap = AttributedTriangle(
            a: Vec3(x: 0, y: 0, z: 0),
            b: Vec3(x: 0, y: 0, z: 1),
            c: Vec3(x: 0, y: 1, z: 0),
            provenance: .cut(nodeID: node.id, side: .positive)
        )

        let negativeMesh = AttributedMesh(
            triangles: [measuredTriangle, negativeCap],
            sourceGeometryFingerprint: sourceFingerprint,
            sourceReferencedVertices: [],
            omittedDegenerateSourceFaceIDs: []
        )
        let positiveMesh = AttributedMesh(
            triangles: [lowDraftTriangle, positiveCap],
            sourceGeometryFingerprint: sourceFingerprint,
            sourceReferencedVertices: [],
            omittedDegenerateSourceFaceIDs: []
        )
        let measuredRegion = UndercutRegionClusterer.Region(
            id: "measured",
            faceIDs: [0],
            areaMM2: 5,
            depthMM: 3,
            centroid: Vec3(x: -1, y: 0.3, z: 0.3),
            suggestedEscapeDirections: [Vec3(x: 1, y: 0, z: 0)]
        )
        let negativeMeasurement = DirectionalAccessibilityAnalyzer.Result(
            pullAxis: Vec3(x: 1, y: 0, z: 0),
            regions: [measuredRegion],
            baseResolutionMM: 0.4,
            effectiveResolutionMM: 0.4,
            sampleCount: 10,
            maximumSamples: 100,
            violatingColumnCount: 1,
            sampleBudgetExhausted: false,
            discardedDegenerateTriangleCount: 0,
            nearVerticalWallAreaMM2: 0
        )
        let positiveMeasurement = DirectionalAccessibilityAnalyzer.Result(
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            regions: [],
            baseResolutionMM: 0.4,
            effectiveResolutionMM: 0.4,
            sampleCount: 10,
            maximumSamples: 100,
            violatingColumnCount: 0,
            sampleBudgetExhausted: false,
            discardedDegenerateTriangleCount: 0,
            nearVerticalWallAreaMM2: lowDraftTriangle.area
        )
        let attributedRegion = UndercutAttributedRegion(
            id: "measured",
            measurementFaceIDs: [0],
            sourceFaceIDs: [SourceFaceID(rawValue: 0)],
            containsCutSurface: false,
            containsJoinerySurface: false,
            areaMM2: 5,
            depthMM: 3,
            centroid: measuredRegion.centroid,
            suggestedEscapeDirections: measuredRegion.suggestedEscapeDirections
        )
        let pieces = [
            UndercutSplitPiece(
                regionID: node.negativeChildID,
                mesh: negativeMesh,
                pullAxis: negativeMeasurement.pullAxis,
                measurement: negativeMeasurement,
                attributedRegions: [attributedRegion],
                draftAdvisoryAreaMM2: 0
            ),
            UndercutSplitPiece(
                regionID: node.positiveChildID,
                mesh: positiveMesh,
                pullAxis: positiveMeasurement.pullAxis,
                measurement: positiveMeasurement,
                attributedRegions: [],
                draftAdvisoryAreaMM2: lowDraftTriangle.area
            ),
        ]
        let plan = UndercutSplitPlan(
            status: .splitExceedsTolerance,
            cutTree: PartitionCutTree(rootRegionID: root, nodes: [node]),
            pieces: pieces,
            statusMessage: "Measured result fixture.",
            fullResolutionFinalized: true,
            deterministicFingerprint: "overlay-plan"
        )
        return Fixture(
            plan: plan,
            node: node,
            negativeRegion: node.negativeChildID,
            positiveRegion: node.positiveChildID
        )
    }
}
