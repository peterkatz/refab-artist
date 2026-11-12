import XCTest
@testable import RefabArtist

final class MoldFlowPathBuilderTests: XCTestCase {
    func testProposalAndFinalizeAreExplicitAndPhaseSeparated() throws {
        let proposal = try MoldFlowPathBuilder.propose(try fixture())

        XCTAssertFalse(proposal.pendingSummaries.isEmpty)
        XCTAssertTrue(proposal.pendingSummaries.allSatisfy { $0.state == .pendingMeasurement })
        XCTAssertTrue(proposal.pendingSummaries.allSatisfy { $0.measuredMinimumDiameterMillimeters == nil })
        XCTAssertEqual(proposal.pendingSummaries.first { $0.id == "liner-fill-01" }?.phase, .linerFill)
        let fillAdditive = try XCTUnwrap(proposal.linerFillAdditives.first { $0.id == "liner-fill-nub-01" })
        let fillTrim = try XCTUnwrap(proposal.trimOperations.first { $0.id == "liner-fill-nub-01" })
        XCTAssertGreaterThan(try overlap(fillAdditive.solid, proposal.baseLiner), 0.01)
        XCTAssertLessThanOrEqual(try overlap(fillTrim.solid, proposal.baseLiner), 0.01)
        XCTAssertEqual(proposal.pendingSummaries.first { $0.id == "production-gate-01" }?.phase, .casting)

        let liners = try MoldLinerStateBuilder.build(MoldFlowPathBuilder.linerStateInput(for: proposal))
        let result = try MoldFlowPathBuilder.finalize(.init(
            proposal: proposal,
            asPouredLiner: liners.asPouredLiner.geometry,
            productionLiner: liners.productionLiner.geometry
        ))

        XCTAssertTrue(result.summaries.allSatisfy { $0.state == .geometryVerified })
        XCTAssertEqual(result.linerFillSummary.label, "LINER FILL")
        XCTAssertEqual(result.castingGateSummary.label, "CAST HERE")
        XCTAssertTrue(result.linerFillSummary.notes.joined().contains("excluded from production"))
        XCTAssertEqual(result.fixtureArtifacts.first { $0.role == .castingFunnel }?.id, ToolingArtifactID("CAST FUNNEL"))
    }

    func testStalePreFlowLinersAreRejected() throws {
        let input = try fixture()
        let proposal = try MoldFlowPathBuilder.propose(input)
        let stale = try MoldLinerStateBuilder.build(MoldLinerStateInput(
            cavitySolid: input.cavityEnvelope,
            oneTimePourPositive: input.oneTimePourPositive,
            verifiedLinerFillAdditives: input.verifiedLinerAdditives
        ))

        XCTAssertThrowsError(try MoldFlowPathBuilder.finalize(.init(
            proposal: proposal,
            asPouredLiner: stale.asPouredLiner.geometry,
            productionLiner: stale.productionLiner.geometry
        ))) { error in
            guard case .staleLinerState = error as? MoldFlowPathBuilder.Error else {
                return XCTFail("expected stale-liner rejection, got \(error)")
            }
        }
    }

    func testIndependentLinerAxisPlacesRequestedHighVentWithoutCastingCredit() throws {
        var input = try fixture()
        input.linerFillUpAxis = Vec3(x: 1, y: 0, z: 0)
        input.settings.requestedLinerVentCount = 1

        let result = try build(input)

        XCTAssertEqual(result.linerVentSummaries.count, 1)
        XCTAssertEqual(result.linerFillSummary.gravityUpAxis, Vec3Codable(x: 1, y: 0, z: 0))
        XCTAssertEqual(result.linerVentSummaries[0].gravityUpAxis, Vec3Codable(x: 1, y: 0, z: 0))
        XCTAssertEqual(result.castingGateSummary.gravityUpAxis, Vec3Codable(x: 0, y: 0, z: 1))
        XCTAssertTrue(result.linerVentSummaries[0].notes.joined().contains("excluded from production"))
        XCTAssertTrue(result.productionVentSummaries.isEmpty)
        XCTAssertEqual(
            result.persistentMaximaEvidence.gateServedPeakIDs.count,
            result.persistentMaximaEvidence.qualifyingBasinCount
        )
    }

    func testFinalSummariesUseMeasuredAndRoundTrippedBores() throws {
        let result = try build(try fixture())

        XCTAssertEqual(result.measurements.count, result.summaries.count)
        for measurement in result.measurements {
            XCTAssertTrue(measurement.connectivityVerified)
            XCTAssertGreaterThanOrEqual(
                measurement.inMemoryMinimumDiameterMillimeters + MoldFlowPathBuilder.boreTolerance,
                measurement.configuredDiameterMillimeters
            )
            XCTAssertGreaterThanOrEqual(
                measurement.roundTripMinimumDiameterMillimeters + MoldFlowPathBuilder.boreTolerance,
                measurement.configuredDiameterMillimeters
            )
            let summary = try XCTUnwrap(result.summaries.first { $0.id == measurement.pathID })
            let measuredMinimum = try XCTUnwrap(summary.measuredMinimumDiameterMillimeters)
            XCTAssertEqual(
                measuredMinimum,
                min(measurement.inMemoryMinimumDiameterMillimeters, measurement.roundTripMinimumDiameterMillimeters),
                accuracy: 1.0e-9
            )
        }
    }

    func testCompressionFractionChangesActualInterferenceAndAbsentDatumBlocks() throws {
        var fivePercent = try fixture()
        fivePercent.settings.sealBeadCompressionFraction = 0.05
        var eightPercent = fivePercent
        eightPercent.settings.sealBeadCompressionFraction = 0.08

        let first = try MoldFlowPathBuilder.propose(fivePercent)
        let second = try MoldFlowPathBuilder.propose(eightPercent)

        XCTAssertEqual(first.funnelEvidence.measuredCompressionFraction, 0.05, accuracy: 0.002)
        XCTAssertEqual(second.funnelEvidence.measuredCompressionFraction, 0.08, accuracy: 0.002)
        XCTAssertNotEqual(
            first.fixtureArtifacts.first { $0.role == .castingFunnel }?.geometry,
            second.fixtureArtifacts.first { $0.role == .castingFunnel }?.geometry
        )

        var absent = fivePercent
        absent.funnelInterface = nil
        XCTAssertThrowsError(try MoldFlowPathBuilder.propose(absent)) { error in
            guard case .funnelDatumRequired = error as? MoldFlowPathBuilder.Error else {
                return XCTFail("expected missing-datum block, got \(error)")
            }
        }
    }

    func testTrimCannotConsumeProtectedRegistrationOrProductionMaterial() throws {
        let baseline = try fixture()
        let first = try MoldFlowPathBuilder.propose(baseline)
        let fillTrim = try XCTUnwrap(first.trimOperations.first { $0.id == "liner-fill-nub-01" })
        var blocked = baseline
        blocked.protectedLinerRegions.append(MoldLinerProtectedRegion(
            id: "registration-protected-test",
            purpose: .registration,
            solid: fillTrim.solid
        ))

        XCTAssertThrowsError(try MoldFlowPathBuilder.propose(blocked)) { error in
            XCTAssertEqual(
                error as? MoldFlowPathBuilder.Error,
                .protectedTrimOverlap(trimID: "liner-fill-nub-01", protectedID: "registration-protected-test")
            )
        }
    }

    func testReverseOutletTraversalDescendsAcrossAsymmetricMultiPeakSurface() throws {
        let cavity = try steppedFacetedSource()
        let outlet = Vec3(x: 8, y: 0, z: 14)
        let served = try MoldFlowPathBuilder.outletServedVertexIDs(
            cavity: cavity,
            outletPoint: outlet,
            axis: Vec3(x: 0, y: 0, z: 1)
        )
        let outletHeight = cavity.vertices[nearestVertex(to: outlet, in: cavity.vertices)].z

        XCTAssertTrue(served.contains { cavity.vertices[$0].z < outletHeight - 1 })
        XCTAssertGreaterThan(served.count, cavity.vertices.filter { abs($0.z - outletHeight) < 1.0e-9 }.count)

        let gateOnly = try MoldFlowPathBuilder.analyzePersistentMaxima(
            cavity: cavity,
            gatePoint: Vec3(x: -7, y: 0, z: 4),
            ventPoints: [],
            axis: Vec3(x: 0, y: 0, z: 1)
        )
        XCTAssertGreaterThan(gateOnly.evidence.qualifyingBasinCount, 1)
        XCTAssertFalse(gateOnly.evidence.unservedPeakIDs.isEmpty)

        let reordered = MeshGeometryData(
            vertices: cavity.vertices,
            triangleIndices: stride(from: 0, to: cavity.triangleIndices.count, by: 3)
                .map { Array(cavity.triangleIndices[$0..<($0 + 3)]) }
                .reversed()
                .flatMap { $0 }
        )
        let reorderedAnalysis = try MoldFlowPathBuilder.analyzePersistentMaxima(
            cavity: reordered,
            gatePoint: Vec3(x: -7, y: 0, z: 4),
            ventPoints: [],
            axis: Vec3(x: 0, y: 0, z: 1)
        )
        XCTAssertEqual(reorderedAnalysis.evidence, gateOnly.evidence)
    }

    func testFacetedPersistentMaximumBuildsSeparateRodLandingSleeveAndVoid() throws {
        let source = try steppedFacetedSource()
        let input = try fixture(
            source: source,
            cavityHalfExtent: 30,
            shellHalfExtent: 30.5,
            gateRoot: Vec3(x: -7, y: 0, z: 4)
        )
        let proposal = try MoldFlowPathBuilder.propose(input)

        XCTAssertFalse(proposal.ventFormers.isEmpty)
        XCTAssertEqual(
            proposal.preparedMasterUpdate.effectivePreparedGeometry,
            proposal.effectiveOneTimePositive
        )
        let expectedEffective = try union(
            [proposal.preparedMasterUpdate.basePreparedGeometry]
                + proposal.preparedMasterUpdate.additions.map(\.solid)
        )
        XCTAssertLessThanOrEqual(
            try outside(expectedEffective, proposal.effectiveOneTimePositive)
                + outside(proposal.effectiveOneTimePositive, expectedEffective),
            MoldFlowPathBuilder.geometryTolerance
        )
        XCTAssertLessThanOrEqual(
            try outside(proposal.preparedMasterUpdate.basePreparedGeometry, proposal.effectiveOneTimePositive),
            MoldFlowPathBuilder.geometryTolerance
        )
        XCTAssertEqual(
            proposal.ventFormers.count,
            proposal.fixtureArtifacts.filter { $0.role == .productionVentFormer }.count
        )
        for addition in proposal.preparedMasterUpdate.additions {
            XCTAssertEqual(addition.region.kind, .productionVentLanding)
            XCTAssertGreaterThan(try overlap(addition.solid, source), MoldFlowPathBuilder.geometryTolerance)
            XCTAssertEqual(
                polygonArea(of: addition.region),
                addition.region.surfaceArea,
                accuracy: 1.0e-6
            )
            XCTAssertLessThanOrEqual(
                try outside(addition.solid, proposal.effectiveOneTimePositive),
                MoldFlowPathBuilder.geometryTolerance
            )
            XCTAssertTrue(proposal.preparedMasterAdditions.contains(addition))
        }
        for former in proposal.ventFormers {
            let artifact = try XCTUnwrap(proposal.fixtureArtifacts.first { $0.id == former.id })
            XCTAssertGreaterThan(try overlap(former.landing.solid, source), 0)
            XCTAssertLessThanOrEqual(try overlap(artifact.geometry, source), MoldFlowPathBuilder.geometryTolerance)
            XCTAssertLessThanOrEqual(
                try overlap(artifact.geometry, proposal.effectiveOneTimePositive),
                MoldFlowPathBuilder.geometryTolerance
            )
            for part in proposal.shellParts {
                XCTAssertLessThanOrEqual(
                    try overlap(former.removalSweep, part.geometry),
                    MoldFlowPathBuilder.geometryTolerance
                )
            }
            XCTAssertTrue(MotherMoldValidation.surfaceClosure(former.shellSleeve).closed)
            XCTAssertTrue(MotherMoldValidation.surfaceClosure(former.linerVoid).closed)
            XCTAssertTrue(MotherMoldValidation.surfaceClosure(former.removalSweep).closed)
            XCTAssertGreaterThan(try volume(former.exteriorGrip), 0)
        }
        let rodArtifacts = proposal.fixtureArtifacts.filter { $0.role == .productionVentFormer }
        for first in rodArtifacts.indices {
            for second in rodArtifacts.indices where second > first {
                XCTAssertLessThanOrEqual(
                    try overlap(rodArtifacts[first].geometry, rodArtifacts[second].geometry),
                    MoldFlowPathBuilder.geometryTolerance
                )
            }
        }

        let result = try build(input)
        XCTAssertTrue(result.persistentMaximaEvidence.unservedPeakIDs.isEmpty)
        XCTAssertEqual(result.productionVentSummaries.count, result.ventFormers.count)
        XCTAssertGreaterThan(result.persistentMaximaEvidence.ventServedPeakIDs.count, 0)
    }

    func testZeroVentClaimCarriesCompleteGateServiceEvidence() throws {
        let result = try build(try fixture())

        XCTAssertTrue(result.productionVentSummaries.isEmpty)
        XCTAssertEqual(
            result.persistentMaximaEvidence.gateServedPeakIDs.count,
            result.persistentMaximaEvidence.qualifyingBasinCount
        )
        XCTAssertTrue(result.persistentMaximaEvidence.unservedPeakIDs.isEmpty)
        XCTAssertTrue(result.castingGateSummary.notes.joined().contains("qualifying basin"))
    }

    func testPreparedMasterFinalizationConsumesFlowLandingsAndChangesApprovalSignature() throws {
        let source = try preparedIntegrationSource()
        let settings = preparedMasterSettings()
        let base = try PreparedMasterBuilder.build(source: source, settings: settings)
        let baseGeometry = try XCTUnwrap(base.artifact?.geometry)
        let input = try fixture(
            source: source,
            oneTimePourPositive: baseGeometry,
            cavityHalfExtent: 50,
            shellHalfExtent: 50.5,
            gateRoot: Vec3(x: -10, y: 0, z: 5)
        )
        let proposal = try MoldFlowPathBuilder.propose(input)

        XCTAssertFalse(proposal.preparedMasterAdditions.isEmpty)
        let finalized = try PreparedMasterBuilder.finalize(
            base: base,
            source: source,
            settings: settings,
            additions: proposal.preparedMasterAdditions
        )
        let finalizedGeometry = try XCTUnwrap(finalized.artifact?.geometry)
        XCTAssertLessThanOrEqual(
            try outside(finalizedGeometry, proposal.effectiveOneTimePositive)
                + outside(proposal.effectiveOneTimePositive, finalizedGeometry),
            MoldFlowPathBuilder.geometryTolerance
        )
        XCTAssertNotEqual(finalized.approvalSignature, base.approvalSignature)
        XCTAssertEqual(
            Set(finalized.additionGeometrySHA256ByRegionID.keys),
            Set(proposal.preparedMasterAdditions.map(\.region.id))
        )
        XCTAssertTrue(
            Set(finalized.modificationRegions.map(\.id))
                .isSuperset(of: proposal.preparedMasterAdditions.map(\.region.id))
        )
    }

    func testFunnelHasMeasuredStopPinRoundedThroatAndRemovalEvidence() throws {
        let result = try build(try fixture())
        let evidence = result.funnelEvidence

        XCTAssertEqual(evidence.declaredCompressionFraction, evidence.measuredCompressionFraction, accuracy: 0.002)
        XCTAssertLessThanOrEqual(evidence.rigidStopContactGapMillimeters, MoldFlowPathBuilder.boreTolerance)
        XCTAssertGreaterThan(evidence.pinBoreOverlapCubicMillimeters, 0)
        XCTAssertGreaterThan(evidence.roundedThroatRadiusMillimeters, 0)
        XCTAssertTrue(evidence.removalSweepClear)
        XCTAssertEqual(evidence.removalAxis, Vec3(x: 0, y: 0, z: 1))
    }

    func testOneShotBuildRequiresExplicitLinerCallbackAndIsDeterministic() throws {
        let input = try fixture()
        var callbackCount = 0
        let first = try MoldFlowPathBuilder.build(input) { recipe in
            callbackCount += 1
            return try MoldLinerStateBuilder.build(recipe)
        }
        let second = try build(input)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(first, second)
    }

    func testShellSeamOwnershipFailureRollsBackProposal() throws {
        var input = try fixture()
        input.shellParts = [
            MotherMoldPart(
                name: "mold-part-A",
                geometry: try box(center: Vec3(x: -10.25, y: 0, z: 0), extents: Vec3(x: 20.5, y: 41, z: 41))
            ),
            MotherMoldPart(
                name: "mold-part-B",
                geometry: try box(center: Vec3(x: 10.25, y: 0, z: 0), extents: Vec3(x: 20.5, y: 41, z: 41))
            ),
        ]

        XCTAssertThrowsError(try MoldFlowPathBuilder.propose(input)) { error in
            guard case .finalVerificationFailed(let message) = error as? MoldFlowPathBuilder.Error else {
                return XCTFail("expected one-part rollback, got \(error)")
            }
            XCTAssertTrue(message.contains("exactly one"))
        }
    }

    private func build(_ input: MoldFlowPathBuilder.ProposalInput) throws -> MoldFlowPathBuilder.Result {
        try MoldFlowPathBuilder.build(input, linerBuilder: MoldLinerStateBuilder.build)
    }

    private func fixture(
        source: MeshGeometryData? = nil,
        oneTimePourPositive: MeshGeometryData? = nil,
        cavityHalfExtent: Double = 20,
        shellHalfExtent: Double = 20.5,
        gateRoot: Vec3 = Vec3(x: 0, y: 0, z: 5)
    ) throws -> MoldFlowPathBuilder.ProposalInput {
        let source = try source ?? box(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 10, y: 10, z: 10)
        )
        let cavity = try box(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: cavityHalfExtent * 2, y: cavityHalfExtent * 2, z: cavityHalfExtent * 2)
        )
        let shellOuter = try box(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: shellHalfExtent * 2, y: shellHalfExtent * 2, z: shellHalfExtent * 2)
        )
        let shell = try difference(shellOuter, cavity)
        let throat = Vec3(x: gateRoot.x, y: gateRoot.y, z: shellHalfExtent)
        let pinCenter = Vec3(x: gateRoot.x - 9.7, y: gateRoot.y, z: shellHalfExtent - 5)
        let centralReceiver = try cylinder(
            from: Vec3(x: gateRoot.x, y: gateRoot.y, z: gateRoot.z - 0.25),
            to: Vec3(x: gateRoot.x, y: gateRoot.y, z: shellHalfExtent + 0.5),
            radius: 8
        )
        let lugPocketLow = pinCenter.z - 3.5
        let lugPocketHigh = shellHalfExtent + 4
        let lugPocket = try box(
            center: Vec3(
                x: pinCenter.x,
                y: pinCenter.y,
                z: (lugPocketLow + lugPocketHigh) / 2
            ),
            extents: Vec3(
                x: 7,
                y: 17,
                z: lugPocketHigh - lugPocketLow
            )
        )
        let receiverBore = try union([centralReceiver, lugPocket])
        let rawReceiverMaterial = try annulus(
            from: Vec3(x: gateRoot.x, y: gateRoot.y, z: shellHalfExtent - 2),
            to: throat,
            innerRadius: 8,
            outerRadius: 12
        )
        let receiverMaterial = try difference(rawReceiverMaterial, lugPocket)
        let bead = try annulus(
            from: Vec3(x: gateRoot.x, y: gateRoot.y, z: shellHalfExtent - 1),
            to: throat,
            innerRadius: 7.25,
            outerRadius: 7.75
        )
        let rigidStop = try annulus(
            from: Vec3(x: gateRoot.x, y: gateRoot.y, z: shellHalfExtent - 1),
            to: throat,
            innerRadius: 8,
            outerRadius: 11
        )
        let receiverPinBore = try cylinder(
            from: Vec3(x: pinCenter.x, y: pinCenter.y - 7.5, z: pinCenter.z),
            to: Vec3(x: pinCenter.x, y: pinCenter.y + 7.5, z: pinCenter.z),
            radius: 2
        )
        return MoldFlowPathBuilder.ProposalInput(
            shellParts: [MotherMoldPart(name: "mold-part-A", geometry: shell)],
            immutableSource: source,
            cavityEnvelope: cavity,
            oneTimePourPositive: oneTimePourPositive ?? source,
            preparedPost: MoldFlowPathBuilder.PreparedPostDatum(
                gateRootPoint: gateRoot,
                collarExteriorPoint: throat,
                receiverAxis: Vec3(x: 0, y: 0, z: 1),
                receiverDiameter: 16,
                isRound: true,
                receiverBore: receiverBore,
                receiverMaterial: receiverMaterial
            ),
            funnelInterface: MoldFlowPathBuilder.FunnelInterfaceDatum(
                sealBead: bead,
                rigidStop: rigidStop,
                rigidStopContactPoint: throat,
                sealBeadInnerRadius: 7.25,
                sealBeadOuterRadius: 7.75,
                sealBeadHeight: 1,
                rigidStopInnerRadius: 8,
                rigidStopOuterRadius: 11,
                receiverPinBore: receiverPinBore,
                pinCenter: pinCenter,
                pinAxis: Vec3(x: 0, y: 1, z: 0),
                pinDiameter: 4,
                removalAxis: Vec3(x: 0, y: 0, z: 1),
                roundedThroatRadius: 1
            ),
            linerFillUpAxis: Vec3(x: 0, y: 0, z: 1),
            castingUpAxis: Vec3(x: 0, y: 0, z: 1),
            verifiedLinerAdditives: [MoldLinerFillAdditiveVolume(
                id: "funnel-seal-bead",
                purpose: "registration-stage funnel seal bead",
                solid: bead
            )],
            protectedLinerRegions: [MoldLinerProtectedRegion(
                id: "funnel-seal-bead-protected",
                purpose: .funnelSeal,
                solid: bead
            )],
            seed: 17
        )
    }

    private func preparedMasterSettings() -> MotherMoldSettings {
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.toolingContractVersion = 3
        settings.masterPreparation = MasterPreparationSettings(
            sourceMode: .preparedPrint,
            retentionMode: .preparedPost,
            placementMode: .manual,
            postWidth: 18,
            postThickness: 13.5,
            postFreeLength: 20,
            crossPinDiameter: 4,
            fitClearance: 0.25,
            sealLandWidth: 5
        )
        settings.masterPreparation.manualPoint = Vec3Codable(x: 0, y: 0, z: -5)
        settings.masterPreparation.manualAxis = Vec3Codable(x: 0, y: 0, z: -1)
        settings.productionFlow.gateDiameter = 12
        return settings
    }

    private func steppedFacetedSource() throws -> MeshGeometryData {
        let low = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: -7, y: 0, z: -3),
            extents: Vec3(x: 14, y: 14, z: 14)
        ))
        let bridge = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: -4),
            extents: Vec3(x: 12, y: 10, z: 6)
        ))
        let high = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 8, y: 0, z: 5),
            extents: Vec3(x: 12, y: 14, z: 18)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.union([low, bridge, high]))
    }

    private func preparedIntegrationSource() throws -> MeshGeometryData {
        let base = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 40, y: 40, z: 10)
        ))
        let highTower = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 10, y: 0, z: 10),
            extents: Vec3(x: 12, y: 12, z: 20)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.union([base, highTower]))
    }

    private func annulus(
        from start: Vec3,
        to end: Vec3,
        innerRadius: Double,
        outerRadius: Double
    ) throws -> MeshGeometryData {
        try difference(
            cylinder(from: start, to: end, radius: outerRadius),
            cylinder(
                from: add(start, scale(normalize(subtract(start, end)), 0.1)),
                to: add(end, scale(normalize(subtract(end, start)), 0.1)),
                radius: innerRadius
            )
        )
    }

    private func cylinder(from start: Vec3, to end: Vec3, radius: Double, sides: Int = 96) throws -> MeshGeometryData {
        let direction = normalize(subtract(end, start))
        let reference = abs(direction.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 0, y: 1, z: 0)
        let u = normalize(cross(direction, reference))
        let v = cross(direction, u)
        var vertices: [Vec3] = []
        for center in [start, end] {
            for index in 0..<sides {
                let angle = Double(index) * 2 * .pi / Double(sides)
                vertices.append(add(center, add(scale(u, cos(angle) * radius), scale(v, sin(angle) * radius))))
            }
        }
        vertices += [start, end]
        let startCenter = Int32(sides * 2), endCenter = startCenter + 1
        var indices: [Int32] = []
        for index in 0..<sides {
            let next = (index + 1) % sides
            let low = Int32(index), lowNext = Int32(next)
            let high = Int32(index + sides), highNext = Int32(next + sides)
            indices += [low, lowNext, high, lowNext, highNext, high]
            indices += [startCenter, lowNext, low]
            indices += [endCenter, high, highNext]
        }
        return try ManifoldEngine.toMesh(try ManifoldEngine.make(from: MeshGeometryData(vertices: vertices, triangleIndices: indices)))
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents)))
    }

    private func union(_ geometries: [MeshGeometryData]) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.union(try geometries.map { try ManifoldEngine.make(from: $0) }))
    }

    private func difference(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.difference(
            try ManifoldEngine.make(from: lhs),
            try ManifoldEngine.make(from: rhs)
        ))
    }

    private func overlap(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> Double {
        abs(ManifoldEngine.volume(try ManifoldEngine.intersect(
            try ManifoldEngine.make(from: lhs),
            try ManifoldEngine.make(from: rhs)
        )))
    }

    private func outside(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> Double {
        abs(ManifoldEngine.volume(try ManifoldEngine.difference(
            try ManifoldEngine.make(from: lhs),
            try ManifoldEngine.make(from: rhs)
        )))
    }

    private func volume(_ geometry: MeshGeometryData) throws -> Double {
        abs(ManifoldEngine.volume(try ManifoldEngine.make(from: geometry)))
    }

    private func nearestVertex(to point: Vec3, in vertices: [Vec3]) -> Int {
        vertices.indices.min { distance(vertices[$0], point) < distance(vertices[$1], point) } ?? 0
    }

    private func polygonArea(of region: MasterModificationRegion) -> Double {
        let center = Vec3(x: region.center.x, y: region.center.y, z: region.center.z)
        let points = region.boundary.map { Vec3(x: $0.x, y: $0.y, z: $0.z) }
        guard points.count >= 3 else { return 0 }
        var areaVector = Vec3(x: 0, y: 0, z: 0)
        for index in points.indices {
            let next = (index + 1) % points.count
            areaVector = add(
                areaVector,
                cross(subtract(points[index], center), subtract(points[next], center))
            )
        }
        return length(areaVector) / 2
    }

    private func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
    private func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
    private func scale(_ value: Vec3, _ factor: Double) -> Vec3 { Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor) }
    private func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double { lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z }
    private func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 { Vec3(x: lhs.y * rhs.z - lhs.z * rhs.y, y: lhs.z * rhs.x - lhs.x * rhs.z, z: lhs.x * rhs.y - lhs.y * rhs.x) }
    private func length(_ value: Vec3) -> Double { dot(value, value).squareRoot() }
    private func normalize(_ value: Vec3) -> Vec3 { scale(value, 1 / length(value)) }
    private func distance(_ lhs: Vec3, _ rhs: Vec3) -> Double { length(subtract(lhs, rhs)) }
}
