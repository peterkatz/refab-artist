import XCTest
@testable import RefabArtist

final class MotherMoldReusableToolingPlannerIntegrationTests: XCTestCase {
    func testReusableJacketPlanContainsMeasuredToolingInsteadOfPlaceholderState() throws {
        let model = try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: reusableSettings())

        let prepared = try XCTUnwrap(plan.preparedMaster)
        let yoke = try XCTUnwrap(plan.fixtureArtifacts.first { $0.role == .holdDownYoke })
        let funnel = try XCTUnwrap(plan.fixtureArtifacts.first { $0.role == .castingFunnel })
        let asPoured = try XCTUnwrap(plan.asPouredLiner)
        let production = try XCTUnwrap(plan.productionLiner)
        for artifact in [prepared, yoke, funnel, asPoured, production] {
            XCTAssertTrue(MeshPreflight.analyze(geometry: artifact.geometry).isWatertight, artifact.name)
            XCTAssertFalse(artifact.geometry.vertices.isEmpty, artifact.name)
            XCTAssertFalse(artifact.geometry.triangleIndices.isEmpty, artifact.name)
        }
        XCTAssertTrue(plan.hardwareItems.contains { $0.isPreparedMasterHoldDownCrossPin && $0.matchesFixtureRequirement() })
        XCTAssertFalse(plan.holdDownWrenchEnvelope.loadCases.isEmpty)
        XCTAssertTrue(plan.holdDownWrenchEnvelope.loadCases.allSatisfy { $0.phase == .linerFill })
        XCTAssertEqual(plan.linerRegistration.state, .geometryVerified)
        XCTAssertEqual(plan.linerFillPath.state, .geometryVerified)
        XCTAssertEqual(plan.productionCastingPath.state, .geometryVerified)
        XCTAssertTrue(plan.productionCastingVents.allSatisfy { $0.state == .geometryVerified })
        XCTAssertGreaterThan(try XCTUnwrap(plan.linerFillPath.measuredMinimumDiameterMillimeters), 0)
        XCTAssertGreaterThan(try XCTUnwrap(plan.productionCastingPath.measuredMinimumDiameterMillimeters), 0)
        XCTAssertFalse(plan.masterModificationRegions.isEmpty)
        XCTAssertFalse(plan.masterPreparation.approvalSignature?.isEmpty ?? true)
        XCTAssertEqual(prepared.id.rawValue, "PREPARED MASTER")
        XCTAssertFalse(plan.masterPreparation.preparedGeometrySHA256?.isEmpty ?? true)
        XCTAssertEqual(plan.toolingContractVersion, 3)
        XCTAssertEqual(plan.requestedPackaging, .manufacturingZip)
        XCTAssertFalse(plan.toolingExportContract.blockingReasons.contains {
            $0.contains("have not been generated") || $0.contains("have not been evaluated")
        })
    }

    func testReusableJacketDoesNotReportLegacySocketOrLegacySpoutAsToolingProof() throws {
        let model = try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: reusableSettings())

        XCTAssertNotEqual(plan.masterMount.mode, .flatBaseSocket)
        XCTAssertEqual(plan.linerFillPath.id, "liner-fill-01")
        XCTAssertEqual(plan.productionCastingPath.id, "production-gate-01")
        XCTAssertNotEqual(plan.linerFillPath.id, "liner-fill-gate")
        XCTAssertNotEqual(plan.productionCastingPath.id, "production-casting-gate")
    }

    private func reusableSettings() -> MotherMoldSettings {
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .two
        settings.packaging = .manufacturingZip
        settings.toolingContractVersion = 3
        settings.masterPreparation = .defaultValue
        settings.linerRegistration = .defaultValue
        settings.productionFlow = .defaultValue
        settings.toolingSupport = .defaultValue
        return settings
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: "docs/PRD.md").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
