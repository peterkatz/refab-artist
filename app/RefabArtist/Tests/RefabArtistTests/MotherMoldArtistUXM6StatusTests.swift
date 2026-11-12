import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistUXM6StatusTests {
    @Test
    func statusResolverUsesTheFiveArtistStatesInPrecedenceOrder() {
        let building = MotherMoldUIContract.buildStatus(
            preflight: Self.openPreflight,
            isBuilding: true,
            buildStage: .buildingShell,
            isStale: true,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(building.kind == .building)
        #expect(building.title == "Building…")
        #expect(building.action == .cancelBuild)

        let repair = MotherMoldUIContract.buildStatus(
            preflight: Self.openPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(repair.kind == .needsRepair)

        let stale = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: true,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(stale.kind == .readyToBuild)

        var blockedPlan = Self.readyPlan
        blockedPlan.diagnostics = [MoldDiagnostic(.error, "Auto could not place a sealed funnel on one mold part.")]
        let blocked = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: blockedPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(blocked.kind == .blocked)

        let ready = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(ready.kind == .readyToPrint)
    }

    @Test
    func needsRepairUsesExactCopyPlainCountsAndMakeWatertight() {
        let status = MotherMoldUIContract.buildStatus(
            preflight: Self.openPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: nil,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )

        #expect(status.title == "Needs repair")
        #expect(status.summary == "This model has open edges.")
        #expect(status.details == [
            "4 open edges.",
            "3 edges shared by too many faces.",
            "2 zero-area triangles.",
        ])
        #expect(status.action == .makeWatertight)
        #expect(status.tone == .orange)
    }

    @Test
    func staleAndCancelledBuildsAreReadyToBuildNotBlocked() {
        let stale = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: true,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(stale.title == "Ready to build")
        #expect(stale.summary == "Settings changed since the last build.")
        #expect(stale.action == .buildMold)

        let cancelled = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: nil,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: "Build cancelled."
        )
        #expect(cancelled.kind == .readyToBuild)
        #expect(cancelled.summary == "Build cancelled.")
        #expect(cancelled.action == .buildMold)
    }

    @Test
    func readyPlanIsGreenAndBlockedPlanHasOnePlainCauseAndOneAction() {
        let ready = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: Self.readyPlan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(ready.title == "Ready to print")
        #expect(ready.summary == "The mold passed its printability checks.")
        #expect(ready.tone == .green)
        #expect(ready.action == nil)

        let raw = "Pour path needs attention. Refab Artist could not place a sealed funnel and fill channel on one mold part."
        var plan = Self.readyPlan
        plan.diagnostics = [MoldDiagnostic(.error, raw)]
        let blocked = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: plan,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(blocked.title == "Blocked")
        #expect(blocked.summary == "The mold can't be built as configured.")
        #expect(blocked.details == ["The pour hole does not fit entirely on one mold part."])
        #expect(blocked.action == .placeSpoutManually)
        #expect(blocked.rawDetails == [raw])
        #expect(blocked.tone == .red)
    }

    @Test
    func structuredRecoveryMetadataBeatsLocalizedMessageText() {
        let diagnostic = MoldDiagnostic(
            .error,
            "The funnel message is deliberately misleading.",
            subsystem: .holdDown,
            code: .externalFixtureEvidenceRequired,
            recoveryActions: [.defineExternalFixture]
        )
        #expect(MotherMoldUIContract.recoveryAction(for: diagnostic) == .useExternalFixture)
    }

    @Test
    func legacyKeyFunnelHolderAndUnknownFailuresMapToHonestActions() {
        let cases: [(String, MotherMoldUIContract.RecoveryAction)] = [
            ("No key site survived the requested key pattern.", .useFewerOrSmallerKeys),
            ("Auto could not place a sealed funnel and fill channel.", .placeSpoutManually),
            ("The printed master socket did not produce a stable locator.", .useExternalFixture),
            ("Opaque validation family 947 failed.", .reviewBuildDetails),
        ]

        for (message, expected) in cases {
            let diagnostic = MoldDiagnostic(.error, message)
            #expect(MotherMoldUIContract.recoveryAction(for: diagnostic) == expected)
        }
        #expect(MotherMoldUIContract.RecoveryAction.useFewerOrSmallerKeys.label == "Use fewer/smaller keys")
    }

    @Test
    func reviewBuildDetailsPreservesTheFailureItNeedsToDisclose() throws {
        #expect(!MotherMoldUIContract.clearsBuildFailure(whenPerforming: .reviewBuildDetails))
        // "Choose how to make it watertight…" only opens the Issues choices.
        #expect(!MotherMoldUIContract.clearsBuildFailure(whenPerforming: .makeWatertight))
        #expect(MotherMoldUIContract.clearsBuildFailure(whenPerforming: .placeSpoutManually))

        let source = try String(
            contentsOf: Self.repoRoot()
                .appending(path: "app/RefabArtist/Sources/RefabArtist/ContentView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("if MotherMoldUIContract.clearsBuildFailure(whenPerforming: action)"))
        #expect(source.contains("case .reviewBuildDetails:\n            motherMoldBuildDetailsExpanded = true"))
        #expect(source.contains("if status.kind != .building"))
    }

    @Test
    func buildButtonUsesTheStatusActionCopyWithoutPreviewSuffixes() {
        let ready = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: nil,
            settings: .defaultValue,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(MotherMoldUIContract.buildButtonLabel(
            isBuilding: false,
            hasBuilt: true,
            status: ready
        ) == "Build mold")
        #expect(MotherMoldUIContract.buildButtonLabel(
            isBuilding: true,
            hasBuilt: false,
            status: ready
        ) == "Cancel build")
    }

    @Test
    func preparedMasterApprovalUsesTheDisplayedSignature() {
        var plan = Self.readyPlan
        plan.toolingContractVersion = 3
        plan.masterModificationRegions = [MasterModificationRegion(
            id: "anchor-01",
            kind: .anchorAndGateRoot,
            center: Vec3Codable(),
            surfaceArea: 42,
            boundary: [],
            purpose: "hold-down root"
        )]
        plan.masterPreparation = MasterPreparationSummary(
            state: .approved,
            retentionEvidence: .preparedPostGeometryOnly,
            approvalSignature: "displayed-signature",
            modificationRegionIDs: ["anchor-01"]
        )

        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.toolingContractVersion = 3
        settings.approvedModificationSignature = "old-signature"

        let status = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: plan,
            settings: settings,
            buildFailure: nil,
            buildMessage: nil
        )
        #expect(status.kind == .blocked)
        #expect(status.details == ["Prepared-master changes still need approval."])
        #expect(status.action == .approvePreparedMaster("displayed-signature"))
    }

    @Test
    func thrownPlannerFailureKeepsRawDetailOutOfArtistCopy() {
        let raw = "fixture shell requires four clampable interfaces; protected void flange-bore-1 is 84.76% clear"
        let failure = MotherMoldUIContract.buildFailurePresentation(
            MotherMoldPlannerError.partitionFailed(raw)
        )
        let status = MotherMoldUIContract.buildStatus(
            preflight: Self.watertightPreflight,
            isBuilding: false,
            buildStage: nil,
            isStale: false,
            plan: nil,
            settings: .defaultValue,
            buildFailure: failure,
            buildMessage: nil
        )

        #expect(status.kind == .blocked)
        #expect(status.summary == "The mold can't be built as configured.")
        #expect(status.details == ["The clamping rim or bolt holes could not be completed safely."])
        #expect(status.action == .disableClampingRim)
        #expect(status.rawDetails == [MotherMoldPlannerError.partitionFailed(raw).localizedDescription])
        #expect(!status.summary.contains("flange-bore"))
    }

    @Test
    func cardAndIssuesReceiveTheSameStatusAndRawDetailsStayDisclosed() throws {
        let source = try String(
            contentsOf: Self.repoRoot()
                .appending(path: "app/RefabArtist/Sources/RefabArtist/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("status: motherMoldBuildStatus"))
        #expect(source.contains("motherMoldStatus: constructionMode == .motherMold ? motherMoldBuildStatus : nil"))
        #expect(!source.contains("motherMoldConstructionIssue"))
        #expect(source.contains("DisclosureGroup(\"Build details\", isExpanded: $buildDetailsExpanded)"))
        #expect(source.contains("Text(isMotherMold ? \"Build Status\" : \"Global Errors\")"))
    }

    private static let watertightPreflight = MeshPreflightReport(
        uniqueVertexCount: 8,
        duplicateVertexObservationCount: 0,
        invalidTriangleReferenceCount: 0,
        degenerateTriangleCount: 0,
        boundaryEdgeCount: 0,
        nonManifoldEdgeCount: 0
    )

    private static let openPreflight = MeshPreflightReport(
        uniqueVertexCount: 8,
        duplicateVertexObservationCount: 0,
        invalidTriangleReferenceCount: 0,
        degenerateTriangleCount: 2,
        boundaryEdgeCount: 4,
        nonManifoldEdgeCount: 3
    )

    private static var readyPlan: MotherMoldPlan {
        var plan = MotherMoldPlan.empty
        plan.parts = [MotherMoldPart(
            name: "mold-part-A",
            geometry: MeshGeometryData(vertices: [], triangleIndices: []),
            isWatertight: true
        )]
        return plan
    }

    private static func repoRoot() -> URL {
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
