import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldReusableToolingCompatibilityRedTests {
    @Test
    func explicitV3JacketSettingsUseTheReusableToolingContract() {
        let settings = MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 3)

        #expect(settings.toolingContractVersion == 3)
        #expect(settings.packaging == .manufacturingZip)
        #expect(settings.masterPreparation.sourceMode == .preparedPrint)
        #expect(settings.masterPreparation.retentionMode == .preparedPost)
        #expect(settings.linerRegistration.mode == .automatic)
        #expect(settings.material.upliftSafetyFactor == 3)
    }

    @Test
    func presentUnknownRequiredMasterMountEnumThrowsInsteadOfUsingLegacyDefault() {
        let data = Data("""
        {
          "mode": "unsupported-v3-mount",
          "socketDepth": 5,
          "fitClearance": 0.25
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MasterMountSettings.self, from: data)
        }
    }

    @Test
    func legacyMotherMoldJSONWithoutNewKeysStillDecodes() throws {
        let data = Data("""
        {
          "subtype": "siliconeJacket",
          "parts": "two",
          "wallThickness": 4,
          "siliconeGap": 6,
          "smoothing": 0,
          "floor": false,
          "floorThickness": 4,
          "draftAngle": 0,
          "packaging": "separateZip",
          "includeAssemblyMap": true,
          "seed": 0
        }
        """.utf8)

        let settings = try JSONDecoder().decode(MotherMoldSettings.self, from: data)
        #expect(settings.subtype == .siliconeJacket)
        #expect(settings.masterMount == .defaultValue)
        #expect(settings.toolingContractVersion == 2)
        #expect(settings.packaging == .separateZip)
        #expect(settings.masterPreparation.sourceMode == .existingPhysical)
        #expect(settings.masterPreparation.retentionMode == .flatBaseSocket)
        #expect(settings.linerRegistration.mode == .none)
    }

    @Test
    func externalFixtureCapacityRoundTripsWithoutBecomingQualification() throws {
        var settings = MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 3)
        settings.masterPreparation.sourceMode = .existingPhysical
        settings.masterPreparation.retentionMode = .externalFixture
        settings.masterPreparation.externalFixtureCapacityNewtons = 125

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MotherMoldSettings.self, from: data)

        #expect(decoded.masterPreparation.externalFixtureCapacityNewtons == 125)
        #expect(decoded.masterPreparation.retentionMode == .externalFixture)
    }

    @Test
    func motherMoldHeadlessRejectsUnknownFlag() {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "unknown-mothermold-flag-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(throws: HeadlessExportError.self) {
            try HeadlessExportCommand.run(arguments: Self.headlessArguments(
                output: output,
                extra: ["--unknown-mothermold-v3-flag", "required-value"]
            ))
        }
    }

    @Test
    func reusableJacketHeadlessRejectsLegacyPackagingBeforePlanning() {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "legacy-v3-packaging-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: output) }

        for packaging in ["plate", "combined-obj", "separate-zip"] {
            do {
                try HeadlessExportCommand.run(arguments: Self.headlessArguments(
                    output: output,
                    extra: ["--packaging", packaging]
                ))
                Issue.record("Reusable jacket tooling must not use the \(packaging) headless package route.")
            } catch let error as HeadlessExportError {
                #expect(error.localizedDescription.contains("manufacturing-zip"))
            } catch {
                Issue.record("Expected HeadlessExportError, got \(error)")
            }
        }
    }

    @Test
    func motherMoldHeadlessDefaultsV3JacketToManufacturingZip() {
        #expect(
            HeadlessExportCommand.defaultMotherMoldPackaging(
                format: .stl,
                requiresManufacturingZip: true
            ) == .manufacturingZip
        )
        #expect(
            HeadlessExportCommand.defaultMotherMoldPackaging(
                format: .obj,
                requiresManufacturingZip: false
            ) == .combinedObj
        )
        #expect(
            HeadlessExportCommand.defaultMotherMoldPackaging(
                format: .stl,
                requiresManufacturingZip: false
            ) == .laidOutPlate
        )
    }

    @Test
    func headlessApprovalRequirementReturnsExactSignatureAndSortedChangeSet() throws {
        let empty = MeshGeometryData(vertices: [], triangleIndices: [])
        var plan = MotherMoldPlan(
            parts: [],
            partingPlanes: [],
            cavity: empty,
            master: empty,
            diagnostics: []
        )
        plan.toolingContractVersion = 3
        plan.masterModificationRegions = [
            MasterModificationRegion(
                id: "vent-z",
                kind: .productionVentLanding,
                center: Vec3Codable(x: 1, y: 2, z: 3),
                surfaceArea: 4,
                boundary: [],
                purpose: "vent"
            ),
            MasterModificationRegion(
                id: "anchor-a",
                kind: .anchorAndGateRoot,
                center: Vec3Codable(),
                surfaceArea: 5,
                boundary: [],
                purpose: "anchor"
            ),
        ]
        plan.masterPreparation.approvalSignature = "exact-signature"
        plan.masterPreparation.state = .approvalRequired
        var settings = MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 3)

        let requirement = try #require(
            HeadlessExportCommand.reusableToolingApprovalRequirement(
                settings: settings,
                plan: plan
            )
        )
        #expect(requirement.signature == "exact-signature")
        #expect(requirement.regions.map(\.id) == ["anchor-a", "vent-z"])

        settings.approvedModificationSignature = "exact-signature"
        plan.masterPreparation.state = .approved
        #expect(
            HeadlessExportCommand.reusableToolingApprovalRequirement(
                settings: settings,
                plan: plan
            ) == nil
        )
    }

    private static func headlessArguments(
        output: URL,
        extra: [String] = []
    ) -> [String] {
        var arguments = [
            "--headless-export",
            "--mode", "mothermold",
            "--format", "stl",
            "--subtype", "siliconeJacket",
            "--fixture", repoRoot().appending(path: "tests/fixtures/organic/low_poly_head.stl").path,
            "--output", output.path,
        ]
        return arguments + extra
    }

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
