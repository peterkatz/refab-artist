import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistUXDefaultsTests {
    @Test
    func untouchedCastCopiesDefaultsBuildHealedHandReadyToPrint() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot()
                .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )

        // Selecting Cast copies is the only user action. Every remaining value
        // must be the product default exercised by the Build button.
        let settings = MotherMoldSettings(subtype: .siliconeJacket)
        #expect(
            settings.toolingContractVersion == 2,
            "Cast copies must use the one-off tooling path, not production tooling."
        )

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        let detail = Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | "))

        #expect(settings.parts == .two)
        #expect(plan.parts.count == 2, detail)
        #expect(plan.parts.allSatisfy { $0.isWatertight }, detail)
        #expect(!plan.diagnostics.contains { $0.severity == .error }, detail)
        #expect(MotherMoldUIContract.blockingExportReason(for: plan, settings: settings) == nil, detail)
    }

    @Test
    func untouchedRigidMoldDefaultsBuildBundledCubeReadyToPrint() {
        // Expected red: see the M1 "Rigid-default automatic-funnel debt"
        // entry in docs/reports/mothermold-artist-ux-2026-07-15.md.
        withKnownIssue("Pre-existing engine debt: the default 12 mm sealed fill gate cannot fit on one centrally parted 50 mm cube mold part (a 10 mm one does).") {
            let model = try MeshInspector.inspect(
                url: Self.repoRoot()
                    .appending(path: "tests/fixtures/cube_ascii.stl")
            )
            let settings = MotherMoldUIContract.applying(
                .rigidMold,
                to: MotherMoldSettings.defaultValue
            )

            #expect(settings.subtype == .slipShell)
            #expect(settings.parts == .two)
            #expect(settings.spout == .defaultValue)

            let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
            let detail = Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | "))

            #expect(plan.parts.count == 2, detail)
            #expect(plan.spoutBored, detail)
            #expect(plan.ventsBoredCount == settings.spout.ventCount, detail)
            #expect(!plan.diagnostics.contains { $0.severity == .error }, detail)
            #expect(MotherMoldUIContract.blockingExportReason(for: plan, settings: settings) == nil, detail)
        }
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
