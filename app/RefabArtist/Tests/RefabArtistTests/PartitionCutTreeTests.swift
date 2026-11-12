import XCTest
@testable import RefabArtist

final class PartitionCutTreeTests: XCTestCase {
    func testPrePurposeSettingsDecodeAsFitPrinterWithoutUndercutSettings() throws {
        let json = """
        {
          "mode": "manual",
          "manualPlanes": [],
          "packaging": "combinedObj"
        }
        """

        let settings = try JSONDecoder().decode(PartitionSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.purpose, .fitPrinter)
        XCTAssertNil(settings.undercutSplit)
        XCTAssertEqual(settings.mode, .manual)
        XCTAssertEqual(settings.packaging, .combinedObj)
    }

    func testPurposeSettingsRoundTripWithoutMutatingFitPrinterFields() throws {
        var settings = PartitionSettings.defaultValue
        settings.purpose = .splitByUndercuts
        settings.mode = .manual
        settings.manualPlanes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 12, isManual: true)
        ]
        settings.key.type = .dovetail
        var split = UndercutSplitSettings.defaultValue
        split.planningMode = .manual
        split.undercutToleranceMM = 3.25
        split.maxPieces = 7
        split.seamKeys = .pins(.defaultValue)
        settings.undercutSplit = split

        let decoded = try JSONDecoder().decode(
            PartitionSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.manualPlanes, settings.manualPlanes)
        XCTAssertEqual(decoded.key.type, .dovetail)
        XCTAssertEqual(decoded.undercutSplit?.undercutToleranceMM, 3.25)
    }

    func testAutomaticIDsAreStableForEquivalentCanonicalPlanes() throws {
        let a = try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 5))
        let b = try XCTUnwrap(CanonicalPlane(normal: Vec3(x: -2, y: 0, z: 0), offset: -10))
        let parent = PartitionRegionID.root(sourceGeometryFingerprint: "fixture-v1")

        let first = PartitionCutNode.automatic(
            plannerVersion: 4,
            targetRegionID: parent,
            plane: a,
            siblingOrdinal: 2,
            isLocked: false
        )
        let second = PartitionCutNode.automatic(
            plannerVersion: 4,
            targetRegionID: parent,
            plane: b,
            siblingOrdinal: 2,
            isLocked: false
        )

        XCTAssertEqual(a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.negativeChildID, .child(of: first.id, side: .negative))
        XCTAssertEqual(first.positiveChildID, .child(of: first.id, side: .positive))
    }

    func testSourceFingerprintUsesOrderedTriangleSoupAndSurvivesScopedCuts() throws {
        let indexed = boxGeometry()
        let source = try SourceFaceMap.attributedMesh(from: indexed)
        XCTAssertEqual(
            source.sourceGeometryFingerprint,
            SourceFaceMap.geometryFingerprint(of: indexed)
        )
        XCTAssertEqual(
            source.sourceGeometryFingerprint,
            SourceFaceMap.geometryFingerprint(of: source.geometry),
            "index sharing and unused vertices must not change effective source identity"
        )

        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.sourceGeometryFingerprint)
        let cut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "fingerprint-cut"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            isLocked: true
        )
        let replay = try PartitionCutTree(rootRegionID: root, nodes: [cut]).replay(source: source)
        XCTAssertTrue(replay.leaves.allSatisfy {
            $0.mesh.sourceGeometryFingerprint == source.sourceGeometryFingerprint
        })
    }

    func testSourceFaceMapRejectsFiniteCoordinatesOutsideSupportedQuantizationRange() {
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 1.0e20, y: 0, z: 0),
                Vec3(x: 1.0e20, y: 1, z: 0),
                Vec3(x: 1.0e20, y: 0, z: 1),
            ],
            triangleIndices: [0, 1, 2]
        )

        XCTAssertThrowsError(try SourceFaceMap.attributedMesh(from: geometry)) { error in
            XCTAssertTrue(error.localizedDescription.contains("supported coordinate magnitude"))
        }
    }

    func testDirectReplayRejectsTreeRootBoundToDifferentSource() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let wrongRoot = PartitionRegionID.root(
            sourceGeometryFingerprint: "different-source"
        )

        XCTAssertThrowsError(
            try PartitionCutTree(rootRegionID: wrongRoot, nodes: []).replay(source: source)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("root"))
            XCTAssertTrue(error.localizedDescription.contains("source"))
        }
    }

    func testStructuralValidationAcceptsEitherDepthFirstSubtreeOrderAndRejectsInterleaving() throws {
        let root = PartitionRegionID(rawValue: "root")
        let rootCut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "cut-root"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            isLocked: true
        )
        let negativeCut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "cut-negative"),
            targetRegionID: rootCut.negativeChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 0)),
            isLocked: true
        )
        let positiveCut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "cut-positive"),
            targetRegionID: rootCut.positiveChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 0)),
            isLocked: true
        )
        let negativeGrandchildCut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "cut-negative-grandchild"),
            targetRegionID: negativeCut.negativeChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 1, z: 0), offset: 0)),
            isLocked: true
        )

        let negativeFirst = PartitionCutTree(
            rootRegionID: root,
            nodes: [rootCut, negativeCut, negativeGrandchildCut, positiveCut]
        )
        XCTAssertFalse(negativeFirst.structuralValidationIssues.contains { issue in
            if case .notDepthFirst = issue { return true }
            return false
        })

        let positiveFirst = PartitionCutTree(
            rootRegionID: root,
            nodes: [rootCut, positiveCut, negativeCut, negativeGrandchildCut]
        )
        XCTAssertFalse(positiveFirst.structuralValidationIssues.contains { issue in
            if case .notDepthFirst = issue { return true }
            return false
        })

        let interleaved = PartitionCutTree(
            rootRegionID: root,
            nodes: [rootCut, negativeCut, positiveCut, negativeGrandchildCut]
        )
        XCTAssertTrue(interleaved.structuralValidationIssues.contains { issue in
            if case .notDepthFirst = issue { return true }
            return false
        })

        let duplicate = PartitionCutTree(rootRegionID: root, nodes: [rootCut, rootCut])
        XCTAssertTrue(duplicate.structuralValidationIssues.contains { issue in
            if case .duplicateNodeID = issue { return true }
            return false
        })
    }

    func testCorruptAuthoredTreeIsQuarantinedWithoutBreakingProjectDecode() throws {
        let json = """
        {
          "purpose": "splitByUndercuts",
          "undercutSplit": {
            "planningMode": "manual",
            "authoredCutTree": {
              "schemaVersion": 1,
              "sourceGeometryFingerprint": "fixture-v1",
              "rawTree": {"rootRegionID": "root", "nodes": "not-an-array"}
            }
          }
        }
        """

        let settings = try JSONDecoder().decode(PartitionSettings.self, from: Data(json.utf8))
        let envelope = try XCTUnwrap(settings.undercutSplit?.authoredCutTree)

        XCTAssertTrue(envelope.isQuarantined)
        XCTAssertNil(envelope.typedTree)
        XCTAssertFalse(envelope.diagnostics.isEmpty)
        XCTAssertEqual(
            envelope.rawTree,
            .object([
                "rootRegionID": .string("root"),
                "nodes": .string("not-an-array")
            ])
        )

        let roundTrip = try JSONDecoder().decode(
            PartitionSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(roundTrip.undercutSplit?.authoredCutTree?.rawTree, envelope.rawTree)
        XCTAssertTrue(roundTrip.undercutSplit?.authoredCutTree?.isQuarantined == true)
    }

    func testAuthoredTreeEnvelopeReplacementReresolvesTypedStateAtomically() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let tree = PartitionCutTree(
            rootRegionID: .root(sourceGeometryFingerprint: source.geometryFingerprint),
            nodes: []
        )
        let original = try PersistedCutTreeEnvelope(
            tree: tree,
            sourceGeometryFingerprint: source.geometryFingerprint
        )
        let corruptTree: JSONValue = .object([
            "rootRegionID": .string(tree.rootRegionID.rawValue),
            "nodes": .string("not-an-array"),
        ])

        let replacement = original.replacing(rawTree: corruptTree)

        XCTAssertNotNil(original.typedTree)
        XCTAssertFalse(original.isQuarantined)
        XCTAssertEqual(original.sourceGeometryFingerprint, source.geometryFingerprint)
        XCTAssertEqual(replacement.rawTree, corruptTree)
        XCTAssertNil(replacement.typedTree)
        XCTAssertTrue(replacement.isQuarantined)
        XCTAssertFalse(replacement.diagnostics.isEmpty)

        let decoded = try JSONDecoder().decode(
            PersistedCutTreeEnvelope.self,
            from: JSONEncoder().encode(replacement)
        )
        XCTAssertEqual(decoded, replacement)

        let missingFingerprint = PersistedCutTreeEnvelope(
            sourceGeometryFingerprint: "",
            rawTree: original.rawTree
        )
        XCTAssertTrue(missingFingerprint.isQuarantined)
        XCTAssertNil(missingFingerprint.typedTree)
        XCTAssertTrue(missingFingerprint.diagnostics.contains { $0.contains("fingerprint") })
        XCTAssertEqual(
            try JSONDecoder().decode(
                PersistedCutTreeEnvelope.self,
                from: JSONEncoder().encode(missingFingerprint)
            ),
            missingFingerprint
        )
    }

    func testOversizedAuthoredTreeIsQuarantinedBeforeWalkingItsPayload() throws {
        let root = PartitionRegionID(rawValue: "oversized-root")
        let plane = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0
        ))
        let tree = PartitionCutTree(
            rootRegionID: root,
            nodes: (0..<256).map { index in
                PartitionCutNode.manual(
                    id: PartitionCutNodeID(rawValue: "oversized-\(index)"),
                    targetRegionID: root,
                    plane: plane,
                    isLocked: true
                )
            }
        )
        let rawTree = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(tree)
        )

        let envelope = PersistedCutTreeEnvelope(
            sourceGeometryFingerprint: "fixture-v1",
            rawTree: rawTree
        )

        XCTAssertTrue(envelope.isQuarantined)
        XCTAssertNil(envelope.typedTree)
        XCTAssertEqual(
            envelope.diagnostics,
            ["Cut tree has 256 nodes; Split by Undercuts supports at most 31."]
        )
    }

    func testScopedReplayLeavesUntargetedSiblingByteIdenticalAndBuildsSeamAdjacency() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
        let rootCut = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            siblingOrdinal: 0,
            isLocked: false
        )
        let nestedCut = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: rootCut.negativeChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 0.2)),
            siblingOrdinal: 0,
            isLocked: false
        )

        let firstReplay = try PartitionCutTree(rootRegionID: root, nodes: [rootCut]).replay(source: source)
        let siblingBefore = try XCTUnwrap(firstReplay.leaf(rootCut.positiveChildID))
        let fullReplay = try PartitionCutTree(rootRegionID: root, nodes: [rootCut, nestedCut]).replay(source: source)
        let siblingAfter = try XCTUnwrap(fullReplay.leaf(rootCut.positiveChildID))

        XCTAssertEqual(fullReplay.leaves.count, 3)
        XCTAssertEqual(siblingAfter, siblingBefore)
        XCTAssertEqual(siblingAfter.stableFingerprint, siblingBefore.stableFingerprint)
        XCTAssertTrue(fullReplay.leaves.allSatisfy(\.mesh.hasCompleteProvenance))

        let rootSeam = try XCTUnwrap(fullReplay.seams.first { $0.cutNodeID == rootCut.id })
        XCTAssertEqual(rootSeam.negativePieceRegionIDs.count, 2)
        XCTAssertEqual(rootSeam.positivePieceRegionIDs, [rootCut.positiveChildID])
    }

    func testNestedCutsPreserveEverySourceFaceAndCapProvenance() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
        let first = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            siblingOrdinal: 0,
            isLocked: false
        )
        let second = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: first.negativeChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 0.2)),
            siblingOrdinal: 0,
            isLocked: false
        )
        let third = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: first.positiveChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 0.2)),
            siblingOrdinal: 0,
            isLocked: false
        )

        let replay = try PartitionCutTree(rootRegionID: root, nodes: [first, second, third]).replay(source: source)
        let sourceProvenanceArea = replay.leaves.reduce(0.0) { partial, leaf in
            partial + leaf.mesh.surfaceArea { provenance in
                if case .source = provenance { return true }
                return false
            }
        }
        let cutIDs = Set(replay.leaves.flatMap { leaf in
            leaf.mesh.triangles.compactMap { triangle -> PartitionCutNodeID? in
                if case .cut(let nodeID, _) = triangle.provenance { return nodeID }
                return nil
            }
        })
        let originalByFace = Dictionary(uniqueKeysWithValues: source.triangles.compactMap {
            triangle -> (SourceFaceID, AttributedTriangle)? in
            guard case .source(let faceID) = triangle.provenance else { return nil }
            return (faceID, triangle)
        })
        var fragmentAreaByFace: [SourceFaceID: Double] = [:]
        for fragment in replay.leaves.flatMap(\.mesh.triangles) {
            guard case .source(let faceID) = fragment.provenance,
                  let original = originalByFace[faceID] else { continue }
            fragmentAreaByFace[faceID, default: 0] += fragment.area
            for point in [fragment.a, fragment.b, fragment.c] {
                XCTAssertTrue(
                    self.point(point, liesOnOrInside: original, tolerance: 1.0e-8),
                    "source fragment \(faceID.rawValue) displaced off its original triangle"
                )
            }
        }

        XCTAssertTrue(replay.leaves.allSatisfy(\.mesh.hasCompleteProvenance))
        XCTAssertEqual(sourceProvenanceArea, source.surfaceArea(), accuracy: 1.0e-8)
        XCTAssertEqual(Set(fragmentAreaByFace.keys), Set(originalByFace.keys))
        for (faceID, original) in originalByFace {
            let fragmentArea = try XCTUnwrap(fragmentAreaByFace[faceID])
            XCTAssertEqual(
                fragmentArea,
                original.area,
                accuracy: 1.0e-8,
                "source face \(faceID.rawValue) area changed during clipping"
            )
        }
        XCTAssertEqual(cutIDs, Set([first.id, second.id, third.id]))
    }

    func testGrazingCheckOnlyConsidersSourceVerticesRetainedByTargetRegion() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
        let first = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "scope-first"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            isLocked: true
        )
        // This plane passes through source vertex (1,-1,-1), which belongs to
        // the untouched positive sibling, but crosses the negative target
        // without touching any source vertex retained by that target.
        let second = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "scope-second"),
            targetRegionID: first.negativeChildID,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0.1, y: 1, z: 0.3), offset: -1.2)),
            isLocked: true
        )

        let replay = try PartitionCutTree(rootRegionID: root, nodes: [first, second]).replay(source: source)
        XCTAssertEqual(replay.leaves.count, 3)
    }

    func testSourceBoundValidationChecksFingerprintLocksConstraintsAndActualSplit() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
        let cut = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "manual-1"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0)),
            isLocked: true
        )
        let tree = PartitionCutTree(rootRegionID: root, nodes: [cut])
        let envelope = try PersistedCutTreeEnvelope(
            tree: tree,
            sourceGeometryFingerprint: source.geometryFingerprint
        )

        let valid = envelope.validateSourceBound(
            source: source,
            sourceGeometryFingerprint: source.geometryFingerprint,
            faceConstraints: PartitionFaceConstraints(
                noCutSourceFaceIDs: [SourceFaceID(rawValue: 0)],
                preferredSeamFaces: []
            ),
            lockedPullDirections: [cut.negativeChildID: Vec3(x: 0, y: 0, z: 1)]
        )
        XCTAssertTrue(valid.isValid, valid.diagnostics.joined(separator: "\n"))
        XCTAssertNotNil(valid.replay)

        let overActivePieceBound = envelope.validateSourceBound(
            source: source,
            sourceGeometryFingerprint: source.geometryFingerprint,
            faceConstraints: .empty,
            lockedPullDirections: [:],
            maxPieces: 1
        )
        XCTAssertFalse(overActivePieceBound.isValid)
        XCTAssertTrue(overActivePieceBound.diagnostics.contains { $0.contains("maximum piece") })

        let wrongSource = envelope.validateSourceBound(
            source: source,
            sourceGeometryFingerprint: "different-source",
            faceConstraints: .empty,
            lockedPullDirections: [:]
        )
        XCTAssertFalse(wrongSource.isValid)
        XCTAssertTrue(wrongSource.diagnostics.contains { $0.contains("fingerprint") })

        let badReferences = envelope.validateSourceBound(
            source: source,
            sourceGeometryFingerprint: source.geometryFingerprint,
            faceConstraints: PartitionFaceConstraints(
                noCutSourceFaceIDs: [SourceFaceID(rawValue: 999)],
                preferredSeamFaces: []
            ),
            lockedPullDirections: [PartitionRegionID(rawValue: "missing"): Vec3(x: 0, y: 0, z: 1)]
        )
        XCTAssertFalse(badReferences.isValid)
        XCTAssertTrue(badReferences.diagnostics.contains { $0.contains("source face") })
        XCTAssertTrue(badReferences.diagnostics.contains { $0.contains("locked pull") })

        let misses = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "misses"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 99)),
            isLocked: true
        )
        XCTAssertThrowsError(
            try PartitionCutTree(rootRegionID: root, nodes: [misses]).replay(source: source)
        )

        let arbitraryRoot = PartitionRegionID(rawValue: "arbitrary-root")
        let wrongRootTree = PartitionCutTree(rootRegionID: arbitraryRoot, nodes: [])
        let wrongRootEnvelope = try PersistedCutTreeEnvelope(
            tree: wrongRootTree,
            sourceGeometryFingerprint: source.geometryFingerprint
        )
        let wrongRoot = wrongRootEnvelope.validateSourceBound(
            source: source,
            sourceGeometryFingerprint: source.geometryFingerprint,
            faceConstraints: .empty,
            lockedPullDirections: [:]
        )
        XCTAssertFalse(wrongRoot.isValid)
        XCTAssertTrue(wrongRoot.diagnostics.contains { $0.contains("root") })
    }

    func testVertexGrazingScopedPlaneIsRejectedDeterministically() throws {
        let source = try SourceFaceMap.attributedMesh(from: boxGeometry())
        let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
        let grazing = PartitionCutNode.manual(
            id: PartitionCutNodeID(rawValue: "grazing"),
            targetRegionID: root,
            plane: try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 1, y: 1, z: 0), offset: 0)),
            isLocked: true
        )
        let tree = PartitionCutTree(rootRegionID: root, nodes: [grazing])

        for _ in 0..<2 {
            XCTAssertThrowsError(try tree.replay(source: source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("vertex"))
            }
        }
    }

    func testAttributedSplitsConserveConcaveAndHollowFixtureVolumes() throws {
        for (name, geometry, plane) in [
            (
                "concave",
                lPrismGeometry(),
                try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 5))
            ),
            (
                "hollow",
                try squareTubeGeometry(),
                try XCTUnwrap(CanonicalPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 5))
            )
        ] {
            let source = try SourceFaceMap.attributedMesh(from: geometry)
            let root = PartitionRegionID.root(sourceGeometryFingerprint: source.geometryFingerprint)
            let cut = PartitionCutNode.manual(
                id: PartitionCutNodeID(rawValue: "\(name)-cut"),
                targetRegionID: root,
                plane: plane,
                isLocked: true
            )
            let replay = try PartitionCutTree(rootRegionID: root, nodes: [cut]).replay(source: source)
            let pieceVolume = replay.leaves.reduce(0.0) { $0 + abs($1.mesh.signedVolume) }

            XCTAssertEqual(pieceVolume, abs(source.signedVolume), accuracy: 1.0e-7, name)
            XCTAssertTrue(replay.leaves.allSatisfy { MeshPreflight.analyze(geometry: $0.mesh.geometry).isWatertight }, name)

            let sourceSolid = try validatedManifold(source.geometry, fixture: "\(name)-source")
            let pieceSolids = try replay.leaves.map {
                try validatedManifold($0.mesh.geometry, fixture: "\(name)-\($0.regionID.rawValue)")
            }
            let union = try ManifoldEngine.union(pieceSolids)
            let sourceVolume = abs(ManifoldEngine.volume(sourceSolid))
            let volumeTolerance = max(
                UndercutSplitTolerancePolicy.current.absoluteVolumeMM3,
                sourceVolume * UndercutSplitTolerancePolicy.current.relativeVolumeFraction
            )
            let missing = try ManifoldEngine.difference(sourceSolid, union)
            let excess = try ManifoldEngine.difference(union, sourceSolid)
            XCTAssertLessThanOrEqual(abs(ManifoldEngine.volume(missing)), volumeTolerance, "\(name) missing volume")
            XCTAssertLessThanOrEqual(abs(ManifoldEngine.volume(excess)), volumeTolerance, "\(name) excess volume")
            for left in pieceSolids.indices {
                for right in pieceSolids.indices where right > left {
                    let overlap = try ManifoldEngine.intersect(pieceSolids[left], pieceSolids[right])
                    XCTAssertLessThanOrEqual(
                        abs(ManifoldEngine.volume(overlap)),
                        volumeTolerance,
                        "\(name) piece-interior overlap"
                    )
                }
            }
        }
    }

    // MARK: - Fixtures

    private func boxGeometry() -> MeshGeometryData {
        let v: [Vec3] = [
            Vec3(x: -1, y: -1, z: -1), Vec3(x: 1, y: -1, z: -1),
            Vec3(x: 1, y: 1, z: -1), Vec3(x: -1, y: 1, z: -1),
            Vec3(x: -1, y: -1, z: 1), Vec3(x: 1, y: -1, z: 1),
            Vec3(x: 1, y: 1, z: 1), Vec3(x: -1, y: 1, z: 1)
        ]
        let faces = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
            (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5)
        ]
        return geometry(vertices: v, faces: faces)
    }

    private func lPrismGeometry() -> MeshGeometryData {
        let poly: [Vec2] = [
            Vec2(x: 0, y: 0), Vec2(x: 20, y: 0), Vec2(x: 20, y: 8),
            Vec2(x: 8, y: 8), Vec2(x: 8, y: 20), Vec2(x: 0, y: 20)
        ]
        var triangles: [(Vec3, Vec3, Vec3)] = []
        for (i, j, k) in ViewportSliceSolidRenderData.triangulate(poly) {
            triangles.append((point(poly[i], 0), point(poly[k], 0), point(poly[j], 0)))
            triangles.append((point(poly[i], 10), point(poly[j], 10), point(poly[k], 10)))
        }
        for index in poly.indices {
            let next = (index + 1) % poly.count
            let a0 = point(poly[index], 0), b0 = point(poly[next], 0)
            let a1 = point(poly[index], 10), b1 = point(poly[next], 10)
            triangles.append((a0, b0, b1))
            triangles.append((a0, b1, a1))
        }
        return PartitionGeometry.geometry(triangles)
    }

    private func squareTubeGeometry() throws -> MeshGeometryData {
        let outer = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 5),
                extents: Vec3(x: 20, y: 20, z: 10)
            )
        )
        let throughBore = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 5),
                extents: Vec3(x: 8, y: 8, z: 12)
            )
        )
        return try ManifoldEngine.toMesh(
            ManifoldEngine.difference(outer, throughBore)
        )
    }

    private func point(_ p: Vec2, _ z: Double) -> Vec3 {
        Vec3(x: p.x, y: p.y, z: z)
    }

    private func point(
        _ point: Vec3,
        liesOnOrInside triangle: AttributedTriangle,
        tolerance: Double
    ) -> Bool {
        let edge0 = subtract(triangle.b, triangle.a)
        let edge1 = subtract(triangle.c, triangle.a)
        let relative = subtract(point, triangle.a)
        let normal = cross(edge0, edge1)
        let normalLength = sqrt(dot(normal, normal))
        guard normalLength > tolerance else { return false }
        guard abs(dot(relative, normal)) / normalLength <= tolerance else { return false }

        let d00 = dot(edge0, edge0)
        let d01 = dot(edge0, edge1)
        let d11 = dot(edge1, edge1)
        let d20 = dot(relative, edge0)
        let d21 = dot(relative, edge1)
        let denominator = d00 * d11 - d01 * d01
        guard abs(denominator) > tolerance * tolerance else { return false }
        let v = (d11 * d20 - d01 * d21) / denominator
        let w = (d00 * d21 - d01 * d20) / denominator
        let u = 1 - v - w
        return u >= -tolerance && v >= -tolerance && w >= -tolerance
            && u <= 1 + tolerance && v <= 1 + tolerance && w <= 1 + tolerance
    }

    private func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private func geometry(vertices: [Vec3], faces: [(Int, Int, Int)]) -> MeshGeometryData {
        MeshGeometryData(
            vertices: vertices,
            triangleIndices: faces.flatMap { [Int32($0.0), Int32($0.1), Int32($0.2)] }
        )
    }

    private func validatedManifold(
        _ geometry: MeshGeometryData,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ManifoldHandle {
        XCTAssertTrue(geometry.triangleIndices.count.isMultiple(of: 3), fixture, file: file, line: line)
        XCTAssertTrue(
            geometry.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
            fixture,
            file: file,
            line: line
        )
        XCTAssertTrue(
            geometry.triangleIndices.allSatisfy {
                $0 >= 0 && Int($0) < geometry.vertices.count
            },
            fixture,
            file: file,
            line: line
        )
        guard geometry.triangleIndices.count.isMultiple(of: 3),
              geometry.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              geometry.triangleIndices.allSatisfy({ $0 >= 0 && Int($0) < geometry.vertices.count }) else {
            throw SourceFaceMapError.incompleteTriangleIndices
        }
        return try ManifoldEngine.make(from: geometry)
    }
}
