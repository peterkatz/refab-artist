import XCTest
@testable import RefabArtist

final class MoldFixtureRegistrationFlowHandoffTests: XCTestCase {
    func testPreparedFixtureRegistrationHandoffFeedsFlowProposalAndRoundTrip() throws {
        let pipeline = try pipeline()
        let handoff = try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
            fixture: pipeline.fixture,
            registration: pipeline.registration
        )

        let fixtureDatum = try XCTUnwrap(pipeline.fixture.productionGate)
        let seal = try XCTUnwrap(pipeline.registration.gateLip).funnelSeal
        XCTAssertEqual(handoff.preparedPost.selectedSplitPlaneID, fixtureDatum.selectedSplitPlaneID)
        XCTAssertEqual(handoff.funnelInterface.selectedSplitPlaneID, fixtureDatum.selectedSplitPlaneID)
        XCTAssertEqual(handoff.preparedPost.productionGateBore, fixtureDatum.roundProductionGateBore)
        XCTAssertEqual(handoff.funnelInterface.receiverPinBore, fixtureDatum.receiverPinBore)
        XCTAssertGreaterThan(seal.beadInnerRadiusMillimeters, fixtureDatum.productionGateDiameterMillimeters / 2)
        XCTAssertGreaterThan(seal.beadHeightMillimeters, 0)
        XCTAssertGreaterThan(
            axial(seal.stopContactPoint, along: fixtureDatum.receiverAxis),
            axial(seal.sealContactPoint, along: fixtureDatum.receiverAxis)
        )

        let proposal = try MoldFlowPathBuilder.propose(flowInput(pipeline: pipeline, handoff: handoff))
        XCTAssertEqual(proposal.preparedPost.productionGateBore, fixtureDatum.roundProductionGateBore)
        XCTAssertEqual(proposal.funnelInterface.receiverPinBore, fixtureDatum.receiverPinBore)

        let liners = try MoldLinerStateBuilder.build(MoldFlowPathBuilder.linerStateInput(for: proposal))
        let finalized = try MoldFlowPathBuilder.finalize(.init(
            proposal: proposal,
            asPouredLiner: liners.asPouredLiner.geometry,
            productionLiner: liners.productionLiner.geometry
        ))
        XCTAssertTrue(finalized.measurements.allSatisfy { $0.connectivityVerified })
    }

    func testAdapterRejectsMissingFixtureRegistrationAndMismatchedProvenance() throws {
        let pipeline = try pipeline()
        let disabled = MoldMasterFixtureBuilder.Result(
            kind: .notApplicable,
            status: .notApplicable,
            wholeShellWithCollar: nil,
            collarAdditive: nil,
            collarHalves: [],
            productionGate: nil,
            yoke: nil,
            crossPin: nil,
            receiver: nil,
            clearance: nil,
            collisions: nil,
            motion: nil,
            release: nil,
            protectedAdditives: [],
            protectedSubtractives: [],
            retention: [],
            diagnostics: []
        )
        XCTAssertThrowsError(try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
            fixture: disabled,
            registration: pipeline.registration
        )) { XCTAssertEqual($0 as? MoldFlowPathBuilder.Error, .fixtureDatumMissing) }

        var missing = pipeline.registration
        missing.gateLip = nil
        XCTAssertThrowsError(try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
            fixture: pipeline.fixture,
            registration: missing
        )) { XCTAssertEqual($0 as? MoldFlowPathBuilder.Error, .registrationDatumMissing) }

        var stale = pipeline.registration
        stale.gateLip?.funnelSeal.fixtureHandoffID = "obsolete-fixture"
        XCTAssertThrowsError(try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
            fixture: pipeline.fixture,
            registration: stale
        )) { XCTAssertEqual($0 as? MoldFlowPathBuilder.Error, .staleFixtureRegistrationHandoff) }

        var mismatched = pipeline.registration
        mismatched.gateLip?.splitPlaneID = UUID()
        XCTAssertThrowsError(try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
            fixture: pipeline.fixture,
            registration: mismatched
        )) { error in
            guard case .handoffPlaneMismatch = error as? MoldFlowPathBuilder.Error else {
                return XCTFail("expected plane mismatch, got \(error)")
            }
        }
    }

    private struct Pipeline {
        var source: MeshGeometryData
        var preparedPositive: MeshGeometryData
        var cavity: MeshGeometryData
        var settings: MotherMoldSettings
        var fixture: MoldMasterFixtureBuilder.Result
        var registration: MoldLinerRegistrationResult
        var plane: PartitionPlane
    }

    private func pipeline() throws -> Pipeline {
        let source = try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 40, y: 40, z: 40))
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.toolingContractVersion = 3
        settings.wallThickness = 4
        settings.siliconeGap = 6
        settings.productionFlow.gateDiameter = 12
        settings.masterPreparation = MasterPreparationSettings(
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
        let prepared = try PreparedMasterBuilder.build(source: source, settings: settings)
        let preparedPositive = try XCTUnwrap(prepared.artifact).geometry
        let cavity = try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 52, y: 52, z: 52))
        let outer = try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 60, y: 60, z: 60))
        let dryPostChannel = try box(center: Vec3(x: 0, y: 0, z: -38), extents: Vec3(x: 20, y: 20, z: 32))
        let shell = try ManifoldEngine.toMesh(try ManifoldEngine.difference(
            try ManifoldEngine.difference(try ManifoldEngine.make(from: outer), try ManifoldEngine.make(from: cavity)),
            try ManifoldEngine.make(from: dryPostChannel)
        ))
        let plane = PartitionPlane(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 7.5,
            isManual: true
        )
        let fixture = try MoldMasterFixtureBuilder.build(.init(
            wholeShell: shell,
            preparedMaster: prepared,
            settings: settings,
            proposedPartingPlanes: [plane]
        ))
        let shellWithCollar = try XCTUnwrap(fixture.wholeShellWithCollar)
        let shellHalves = try ManifoldEngine.splitByPlane(
            try ManifoldEngine.make(from: shellWithCollar),
            normal: plane.normal,
            offset: plane.offset
        )
        let shellParts = try [shellHalves.0, shellHalves.1].enumerated().map { index, handle in
            let geometry = try ManifoldEngine.toMesh(handle)
            return MoldLinerRegistrationShellPart(
                id: ToolingArtifactID("flow-owner-\(index == 0 ? "A" : "B")"),
                part: MotherMoldPart(name: "flow-owner-\(index == 0 ? "A" : "B")", geometry: geometry, isWatertight: true),
                demoldAxis: Vec3Codable(x: index == 0 ? -1 : 1, y: 0, z: 0)
            )
        }
        let registration = try MoldLinerRegistrationBuilder.build(.init(
            finalShellParts: shellParts,
            nominalLinerSurface: source,
            totalLinerOffset: settings.siliconeGap,
            settings: LinerRegistrationSettings(mode: .buttonsAndGateLip, buttonsPerPart: 0, gateLipEnabled: true),
            wallThickness: settings.wallThickness,
            partingPlanes: [plane],
            reservedGeometry: .init(),
            gateLipDatum: try MoldLinerRegistrationGateLipDatum(fixture: fixture)
        ))
        return Pipeline(source: source, preparedPositive: preparedPositive, cavity: cavity, settings: settings, fixture: fixture, registration: registration, plane: plane)
    }

    private func flowInput(
        pipeline: Pipeline,
        handoff: MoldFlowPathBuilder.ExactFixtureRegistrationHandoff
    ) -> MoldFlowPathBuilder.ProposalInput {
        MoldFlowPathBuilder.ProposalInput(
            shellParts: pipeline.registration.shellParts.map(\.part),
            immutableSource: pipeline.source,
            cavityEnvelope: pipeline.cavity,
            oneTimePourPositive: pipeline.preparedPositive,
            partingPlanes: [pipeline.plane],
            preparedPost: handoff.preparedPost,
            funnelInterface: handoff.funnelInterface,
            linerFillUpAxis: Vec3(x: 0, y: 0, z: 1),
            castingUpAxis: Vec3(x: 0, y: 0, z: -1),
            settings: .init(productionGateDiameter: pipeline.settings.productionFlow.gateDiameter),
            verifiedLinerAdditives: pipeline.registration.siliconeAdditives,
            protectedLinerRegions: pipeline.registration.protectedRegions,
            seed: 31
        )
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents)))
    }

    private func axial(_ point: Vec3Codable, along axis: Vec3Codable) -> Double {
        point.x * axis.x + point.y * axis.y + point.z * axis.z
    }
}
