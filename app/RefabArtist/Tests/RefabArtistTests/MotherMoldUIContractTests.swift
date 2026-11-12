import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldUIContractTests {
    @Test
    func subtypeAndManualSpoutAvailabilityStayHonest() {
        #expect(MotherMoldUIContract.showsSpoutControls(for: .slipShell))
        #expect(MotherMoldUIContract.showsSpoutControls(for: .siliconeJacket))
        #expect(MotherMoldUIContract.supportsManualSpoutPlacement)

        var jacket = MotherMoldSettings.defaultValue
        jacket.subtype = .siliconeJacket
        jacket.spout.mode = .manual
        #expect(MotherMoldUIContract.manualSpoutDisabledReason(for: jacket) == nil)

        var slip = jacket
        slip.subtype = .slipShell
        #expect(MotherMoldUIContract.manualSpoutDisabledReason(for: slip) == nil)

        let seed = MotherMoldUIContract.manualSpoutSeed(for: Bounds3D(
            min: Vec3(x: 40, y: -20, z: 10),
            max: Vec3(x: 80, y: 30, z: 90)
        ))
        #expect(seed == Vec3(x: 60, y: 5, z: 90))
    }

    @Test
    func everyMotherMoldControlAndChoiceHasHoverHelp() {
        #expect(MotherMoldHelp.Field.allCases.count >= 50)
        for field in MotherMoldHelp.Field.allCases {
            #expect(!field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        for subtype in MoldSubtype.allCases {
            #expect(!MotherMoldHelp.option(subtype).isEmpty)
        }
        for partCount in MoldPartCount.allCases {
            #expect(!MotherMoldHelp.option(partCount).isEmpty)
        }
        for fixture in MasterMountMode.allCases {
            #expect(!MotherMoldHelp.option(fixture).isEmpty)
        }
        for mode in PartingMode.allCases {
            #expect(!MotherMoldHelp.option(mode).isEmpty)
        }
        for key in PartitionKeyType.allCases {
            #expect(!MotherMoldHelp.option(key).isEmpty)
        }
        for spout in MoldSpoutMode.allCases {
            #expect(!MotherMoldHelp.option(spout).isEmpty)
        }
        for packaging in MoldPackaging.allCases {
            #expect(!MotherMoldHelp.option(packaging).isEmpty)
        }
        for source in [MasterSourceMode.preparedPrint, .existingPhysical] {
            #expect(!MotherMoldHelp.option(source).isEmpty)
        }
        for retention in [MasterRetentionMode.preparedPost, .flatBaseSocket, .externalFixture] {
            #expect(!MotherMoldHelp.option(retention).isEmpty)
        }
        for registration in [LinerRegistrationMode.automatic, .buttons, .buttonsAndGateLip, .none] {
            #expect(!MotherMoldHelp.option(registration).isEmpty)
        }
        for flow in [ProductionFlowMode.automatic, .manual] {
            #expect(!MotherMoldHelp.option(flow).isEmpty)
        }
        for profile in [CastingProcessProfile.gravityResin, .gravityPlaster, .customGravity] {
            #expect(!MotherMoldHelp.option(profile).isEmpty)
        }
        for support in [ToolingSupportMode.automatic, .manual] {
            #expect(!MotherMoldHelp.option(support).isEmpty)
        }
        for axis in ["X", "Y", "Z"] {
            #expect(!MotherMoldHelp.axisOption(axis).isEmpty)
        }
    }

    @Test
    func preparedMasterApprovalMustMatchTheDisplayedPlanSignature() {
        var plan = MotherMoldPlan.empty
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
        settings.approvedModificationSignature = "displayed-signature"
        #expect(MotherMoldUIContract.preparedMasterApprovalIsFresh(plan: plan, settings: settings))

        settings.approvedModificationSignature = "old-signature"
        #expect(!MotherMoldUIContract.preparedMasterApprovalIsFresh(plan: plan, settings: settings))
        if case .blocked(let reason) = MotherMoldUIContract.packageReadiness(for: plan, settings: settings) {
            #expect(reason.localizedCaseInsensitiveContains("approval"))
        } else {
            Issue.record("A mismatched approval signature must block the package.")
        }
    }

    @Test
    func artistViewportLayerInventoryHasStableNamesColorsAndHelp() {
        #expect(MotherMoldPreviewLayer.allCases.count == 8)
        for layer in MotherMoldPreviewLayer.allCases {
            #expect(!layer.id.isEmpty)
            #expect(!layer.label.isEmpty)
            #expect(!layer.help.isEmpty)
            #expect(!layer.stableColorName.isEmpty)
        }
        #expect(MotherMoldArtistViewMode.allCases.map(\.label) == ["Master", "Mold", "Assembly"])
    }

    @Test
    func exportRequiresTheNonStaleDisplayedPlanAndItsSettingsSnapshot() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]

        var generatedSettings = MotherMoldSettings.defaultValue
        generatedSettings.wallThickness = 9.5
        let signature = MotherMoldInputSignature(
            modelPath: "/tmp/master.stl",
            modelTriangleCount: 12,
            modelBounds: "bounds",
            settings: generatedSettings
        )

        #expect(
            MotherMoldUIContract.exportSnapshot(
                nonStaleDisplayedPlan: nil,
                generatedSignature: signature
            ) == nil
        )
        #expect(
            MotherMoldUIContract.exportSnapshot(
                nonStaleDisplayedPlan: .empty,
                generatedSignature: signature
            ) == nil
        )

        let export = MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: plan,
            generatedSignature: signature
        )
        #expect(export?.plan == plan)
        #expect(export?.settings == generatedSettings)

        var outputOnlyChange = generatedSettings
        outputOnlyChange.packaging = .combinedObj
        outputOnlyChange.includeAssemblyMap = false
        #expect(outputOnlyChange.generationInputs == generatedSettings.generationInputs)
        #expect(MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: plan,
            generatedSignature: signature,
            currentOutputSettings: outputOnlyChange
        )?.settings == outputOnlyChange)
    }

    @Test
    func errorDiagnosticOverridesBuiltPartsSuccessMessage() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(.error, "No fill channel was built.")]

        let message = MotherMoldUIContract.buildMessage(for: plan)
        #expect(message.hasPrefix("Mold needs attention before export."))
        #expect(message.localizedCaseInsensitiveContains("manual"))
        #expect(MotherMoldUIContract.recoveryAction(for: plan) == .placeSpoutManually)

        let signature = MotherMoldInputSignature(
            modelPath: "/tmp/master.stl",
            modelTriangleCount: 12,
            modelBounds: "bounds",
            settings: .defaultValue
        )
        #expect(MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: plan,
            generatedSignature: signature
        ) == nil)

        plan.diagnostics = []
        #expect(MotherMoldUIContract.buildMessage(for: plan) == "Mold ready: 1 printable part.")
    }

    @Test
    func finalGeneratedPartOverlapIsAnInternalHardwareLayoutFailure() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(
            .error,
            "The flange and generated part overlap after final keying: mold-part-A / mold-part-B did not produce printable topology (boundary 4, non-manifold 0, degenerate 4)."
        )]

        let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
        #expect(reason.localizedCaseInsensitiveContains("internal") && reason.localizedCaseInsensitiveContains("hardware-layout"))
        #expect(reason.localizedCaseInsensitiveContains("nothing is wrong with your model"))
        #expect(reason.localizedCaseInsensitiveContains("adjust Clamping rim Width or key settings and rebuild"))
        #expect(!reason.localizedCaseInsensitiveContains("printable topology"))
        #expect(!reason.localizedCaseInsensitiveContains("boundary 4"))
        #expect(!reason.localizedCaseInsensitiveContains("non-manifold 0"))
        #expect(!reason.localizedCaseInsensitiveContains("degenerate 4"))
        #expect(!reason.localizedCaseInsensitiveContains("simpl"))
        #expect(!reason.localizedCaseInsensitiveContains("reorient"))
        #expect(!reason.localizedCaseInsensitiveContains("change your model"))
        #expect(MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: plan,
            generatedSignature: Self.signature
        ) == nil)
    }

    @Test
    func historicalMasterSocketTopologyFailureIsAnInternalFixtureFailure() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(
            .error,
            "The generated master socket joined the shell but did not produce printable topology (boundary 4, non-manifold 0, degenerate 4)."
        )]

        let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
        #expect(reason.localizedCaseInsensitiveContains("internal automatic master-holder failure"))
        #expect(reason.localizedCaseInsensitiveContains("nothing is wrong with your model"))
        #expect(reason.localizedCaseInsensitiveContains("hold it myself"))
        #expect(reason.localizedCaseInsensitiveContains("socket depth"))
        #expect(reason.localizedCaseInsensitiveContains("rebuild"))
        #expect(!reason.localizedCaseInsensitiveContains("broader base"))
        #expect(!reason.localizedCaseInsensitiveContains("make watertight"))
    }

    @Test
    func keyPatternErrorsExposeOnlyKeyHardwareControls() {
        for diagnostic in [
            "No valid key site could be retained after final validation.",
            "The key pattern could not be placed without interference.",
            "The deterministic key search exhausted its 16384-node budget before proving a complete 4-key pattern."
        ] {
            var plan = MotherMoldPlan.empty
            plan.parts = [Self.part]
            plan.diagnostics = [MoldDiagnostic(.error, diagnostic)]

            let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
            #expect(reason.localizedCaseInsensitiveContains("increase rim width"))
            #expect(reason.localizedCaseInsensitiveContains("reduce keys per seam or key size"))
            #expect(reason.localizedCaseInsensitiveContains("choose none"))
            #expect(!reason.localizedCaseInsensitiveContains("simpl"))
            #expect(!reason.localizedCaseInsensitiveContains("reorient"))
            #expect(!reason.localizedCaseInsensitiveContains("change your model"))
        }
    }

    @Test
    func overlapBeatsFlangeCompletionFailures() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(
            .error,
            "The mating flange and generated part overlap during final keying, and the clamping flange could not be completed."
        )]

        let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
        #expect(reason.localizedCaseInsensitiveContains("internal automatic hardware-layout failure"))
        #expect(reason.localizedCaseInsensitiveContains("adjust Clamping rim Width or key settings and rebuild"))
        #expect(!reason.localizedCaseInsensitiveContains("increase width, reduce bolts"))
        #expect(!reason.localizedCaseInsensitiveContains("turn off mating flange"))
        #expect(reason.localizedCaseInsensitiveContains("nothing is wrong with your model"))
    }

    @Test
    func disconnectedTopologyRemainsSeparateFromHardwareOverlap() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(
            .error,
            "MotherMold produced disconnected debris inside part-A and did not produce printable topology (boundary 4)."
        )]

        let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
        #expect(reason.localizedCaseInsensitiveContains("generated assembly failed"))
        #expect(reason.localizedCaseInsensitiveContains("auto parting"))
        #expect(reason.localizedCaseInsensitiveContains("fewer parts"))
        #expect(reason.localizedCaseInsensitiveContains("seam features"))
        #expect(reason.localizedCaseInsensitiveContains("rebuild"))
        #expect(!reason.localizedCaseInsensitiveContains("hardware-layout"))
        #expect(!reason.localizedCaseInsensitiveContains("model"))
    }

    @Test
    func incompleteVentPlacementNamesOnlyArtistFacingRecoveryControls() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part]
        plan.diagnostics = [MoldDiagnostic(
            .error,
            "Requested 2 one-sided vents, but only 1 survived the protected-geometry and topology gates."
        )]

        let reason = MotherMoldUIContract.blockingExportReason(for: plan)!
        #expect(reason.localizedCaseInsensitiveContains("every requested air vent"))
        #expect(reason.localizedCaseInsensitiveContains("reduce vent diameter or vent count"))
        #expect(reason.localizedCaseInsensitiveContains("reorient"))
        #expect(reason.localizedCaseInsensitiveContains("rebuild"))
        #expect(!reason.localizedCaseInsensitiveContains("topology"))
        #expect(!reason.localizedCaseInsensitiveContains("protected-geometry"))
    }

    @Test
    func liveArtistWorkflowCoversSealClampPourAndDemold() {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part, Self.part]
        plan.masterMount = MoldMasterMountBuilder.Summary(
            mode: .flatBaseSocket,
            isResolved: true,
            contactAreaMM2: 400,
            socketDepthMM: 5,
            fitClearanceMM: 0.25,
            sealLandWidthMM: 10,
            requiresSealant: true,
            locatorVolumeMM3: 500,
            finalLocatorRetention: 1
        )
        plan.spoutBored = true
        plan.flangePlatesPlaced = 2
        plan.effectiveBoltHoleCount = 4
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket

        let steps = MotherMoldWorkflow.steps(plan: plan, settings: settings)
        let text = steps.map { "\($0.title) \($0.detail)" }.joined(separator: " ").lowercased()

        #expect(steps.count == 5)
        #expect(text.contains("locator, not a liquid seal"))
        #expect(text.contains("tapered key"))
        #expect(text.contains("bolt holes"))
        #expect(text.contains("pour mixed silicone"))
        #expect(text.contains("demold directions"))

        plan.diagnostics = [MoldDiagnostic(.error, "No fill channel was built.")]
        let blocked = MotherMoldWorkflow.steps(plan: plan, settings: settings)
        #expect(blocked.count == 1)
        #expect(blocked[0].detail.contains("Do not print or pour"))
    }

    @Test
    func thrownPlannerFailuresBecomePlainRecoveryInstructions() {
        let split = MotherMoldUIContract.buildFailureMessage(
            MotherMoldPlannerError.incorrectPartCount(requested: 4, produced: 2)
        )
        #expect(split.contains("2 of 4"))
        #expect(split.contains("Auto"))
        #expect(!split.localizedCaseInsensitiveContains("incorrectPartCount"))

        let topology = MotherMoldUIContract.buildFailureMessage(
            MotherMoldPlannerError.partsNotWatertight(["part-A (boundary 4)"])
        )
        #expect(topology.localizedCaseInsensitiveContains("printability"))
        #expect(!topology.localizedCaseInsensitiveContains("boundary 4"))

        let disconnected = MotherMoldUIContract.buildFailureMessage(
            MotherMoldPlannerError.disconnectedParts([])
        )
        #expect(disconnected.localizedCaseInsensitiveContains("generated assembly failed"))
        #expect(disconnected.localizedCaseInsensitiveContains("auto parting"))
        #expect(disconnected.localizedCaseInsensitiveContains("rebuild"))

        let manual = MotherMoldUIContract.buildFailureMessage(MotherMoldPlannerError.partitionFailed(
            "Manual parting requires exactly 2 plane(s), but 1 was supplied. The build was blocked before partitioning instead of falling back to Auto."
        ))
        #expect(manual.localizedCaseInsensitiveContains("requires exactly 2 plane"))
        #expect(manual.localizedCaseInsensitiveContains("add the required manual plane"))
        #expect(manual.localizedCaseInsensitiveContains("switch parting to auto"))
        #expect(manual.localizedCaseInsensitiveContains("rebuild"))

        let flow = MotherMoldUIContract.buildFailureMessage(MotherMoldPlannerError.partitionFailed(
            "flow proposal stage failed: LINER FILL only touches the liner and has no positive-volume root. Action: rebuild the generated port."
        ))
        #expect(flow.localizedCaseInsensitiveContains("positive-volume root"))
        #expect(flow.localizedCaseInsensitiveContains("rebuild the generated port"))
        #expect(!flow.localizedCaseInsensitiveContains("selected split"))
    }

    private static let part = MotherMoldPart(
        name: "mold-part-A",
        geometry: MeshGeometryData(vertices: [], triangleIndices: [])
    )

    private static let signature = MotherMoldInputSignature(
        modelPath: "/tmp/master.stl",
        modelTriangleCount: 12,
        modelBounds: "bounds",
        settings: .defaultValue
    )
}
