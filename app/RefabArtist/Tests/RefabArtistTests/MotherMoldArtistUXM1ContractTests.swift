import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistUXM1ContractTests {
    @Test
    func newSessionDefaultsToCastCopies() {
        let settings = MotherMoldSettings.defaultValue

        #expect(settings.subtype == .siliconeJacket)
        #expect(settings.toolingContractVersion == 2)
        #expect(settings.packaging == .separateZip)
        #expect(MotherMoldUIContract.goal(for: settings) == .castCopies)
    }

    @Test
    func goalGateHasTheRequiredArtistChoices() {
        #expect(MotherMoldGoal.allCases.map(\.label) == [
            "Cast copies",
            "Rigid mold",
            "Production tooling",
        ])
        #expect(MotherMoldGoal.castCopies.help == "A flexible silicone mold inside a rigid printed shell. Best for detailed sculpture and multiple copies in resin, plaster, or wax.")
        #expect(MotherMoldGoal.rigidMold.help == "A hard printed mold whose cavity is the exact shape of your model. Best for simple shapes and materials that release easily.")
        #expect(MotherMoldGoal.productionTooling.help == "Reusable factory-style tooling with a printed master, hold-down hardware, and process records. For repeated production runs.")
    }

    @Test
    func savedSettingsDeriveTheGoalWithoutANewStoredField() {
        #expect(MotherMoldUIContract.goal(for: MotherMoldSettings(
            subtype: .siliconeJacket,
            toolingContractVersion: 3
        )) == .productionTooling)
        #expect(MotherMoldUIContract.goal(for: MotherMoldSettings(
            subtype: .siliconeJacket,
            toolingContractVersion: 2
        )) == .castCopies)
        #expect(MotherMoldUIContract.goal(for: MotherMoldSettings(
            subtype: .slipShell,
            toolingContractVersion: 3
        )) == .rigidMold)
        #expect(MotherMoldUIContract.goal(for: MotherMoldSettings(
            subtype: .slipShell,
            toolingContractVersion: 2
        )) == .rigidMold)
    }

    @Test
    func changingGoalsPreservesHiddenProductionSettings() {
        var original = MotherMoldSettings(
            subtype: .siliconeJacket,
            packaging: .manufacturingZip,
            toolingContractVersion: 3
        )
        original.masterPreparation.manualPoint = Vec3Codable(x: 11, y: 22, z: 33)
        original.masterPreparation.postWidth = 27
        original.linerRegistration.buttonsPerPart = 7
        original.productionFlow.mode = .manual
        original.productionFlow.manualGatePoint = Vec3Codable(x: 4, y: 5, z: 6)
        original.toolingSupport.mode = .manual
        original.toolingSupport.minimumSupportMargin = 17
        original.manufacturingProfile = ToolingManufacturingProfileRef(
            printerProfileID: "saved-printer",
            materialProfileID: "saved-material",
            profileSnapshotSHA256: "saved-profile"
        )
        original.approvedModificationSignature = "saved-approval"

        var castExpected = original
        castExpected.subtype = .siliconeJacket
        castExpected.toolingContractVersion = 2
        castExpected.packaging = .separateZip
        #expect(MotherMoldUIContract.applying(.castCopies, to: original) == castExpected)

        var rigidExpected = original
        rigidExpected.subtype = .slipShell
        rigidExpected.toolingContractVersion = 2
        rigidExpected.packaging = .separateZip
        #expect(MotherMoldUIContract.applying(.rigidMold, to: original) == rigidExpected)

        var productionExpected = original
        productionExpected.subtype = .siliconeJacket
        productionExpected.toolingContractVersion = 3
        productionExpected.packaging = .manufacturingZip
        #expect(MotherMoldUIContract.applying(.productionTooling, to: original) == productionExpected)
    }

    @Test
    func castCopiesPrimarySurfaceStaysWithinSixteenControls() {
        var worstCase = MotherMoldUIContract.applying(.castCopies, to: .defaultValue)
        worstCase.parts = .four
        worstCase.parting.mode = .manual
        worstCase.parting.planes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 12, isManual: true),
            PartitionPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: -8, isManual: true),
        ]
        worstCase.floor = true

        #expect(MotherMoldUIContract.visiblePrimaryControlCount(for: worstCase) <= 16)
        #expect(!MotherMoldUIContract.showsProductionSections(for: worstCase))
        #expect(MotherMoldUIContract.showsLegacyMountControls(for: worstCase))

        let production = MotherMoldUIContract.applying(.productionTooling, to: worstCase)
        #expect(MotherMoldUIContract.showsProductionSections(for: production))
        #expect(!MotherMoldUIContract.showsLegacyMountControls(for: production))
    }

    @Test
    func unfinishedManualProductionModesAreDisabledWithTheRequiredHint() {
        let hint = "Manual placement needs the click-to-place editor — coming with the placement gizmo."

        #expect(!MotherMoldUIContract.supportsManualProductionFlowPlacement)
        #expect(!MotherMoldUIContract.supportsManualToolingSupportPlacement)
        #expect(MotherMoldUIContract.manualProductionPlacementDisabledReason == hint)
        #expect(MotherMoldUIContract.manualMountPlacementLabel == "Pick on model")
    }

    @Test
    func projectDocumentsRoundTripAndDeriveGoals() throws {
        let legacyJacket = try JSONDecoder().decode(
            MotherMoldSettings.self,
            from: Data(#"{"subtype":"siliconeJacket","parts":"two"}"#.utf8)
        )
        let cases: [(MotherMoldSettings?, MotherMoldGoal)] = [
            (MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 3), .productionTooling),
            (MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 2), .castCopies),
            (legacyJacket, .castCopies),
            (MotherMoldSettings(subtype: .slipShell, toolingContractVersion: 3), .rigidMold),
            (nil, .castCopies),
        ]

        for (savedMotherMold, expectedGoal) in cases {
            let document = SlicerProjectDocument(
                modelPath: "/fixtures/legacy-mothermold.obj",
                settings: projectSettings(motherMoldSettings: savedMotherMold)
            )
            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
            let loadedSettings = decoded.settings.motherMoldSettings ?? .defaultValue
            #expect(MotherMoldUIContract.goal(for: loadedSettings) == expectedGoal)
        }
    }

    private func projectSettings(motherMoldSettings: MotherMoldSettings?) -> SlicerProjectSettings {
        SlicerProjectSettings(
            constructionMode: .motherMold,
            sliceAxis: .z,
            secondarySliceAxis: .x,
            materialThickness: 3,
            slotClearance: 0.15,
            slotAngleDegrees: 0,
            radialSliceCount: 12,
            curveSliceCount: 8,
            curveAmplitude: 5,
            materialPreset: .plywood3mm,
            slotReliefEnabled: false,
            slotReliefDiameter: 3,
            dowelsEnabled: false,
            dowelDiameter: 4,
            dowelInset: 8,
            exportFormat: .stl,
            exportLayoutSettings: .defaultValue,
            modelScaleFactor: 1,
            importUnit: .millimeters,
            customSliceDistributionEnabled: false,
            customSliceCount: 12,
            motherMoldSettings: motherMoldSettings
        )
    }
}
