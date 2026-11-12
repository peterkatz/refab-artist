import Foundation
import XCTest
@testable import RefabArtist

final class MotherMoldReusableToolingPackageRedTests: XCTestCase {
    func testSiliconeJacketZipHasExactV3ToolingInventoryDeclaredByManifest() throws {
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "tests/fixtures/organic/low_poly_head.stl")
        )
        var settings = MotherMoldSettings(
            subtype: .siliconeJacket,
            toolingContractVersion: 3
        )
        settings.parts = .two
        settings.packaging = .manufacturingZip
        settings.includeAssemblyMap = false

        let approvalPlan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        settings.approvedModificationSignature = try XCTUnwrap(
            approvalPlan.masterPreparation.approvalSignature
        )
        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        XCTAssertEqual(plan.masterPreparation.state, .approved)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-v3-tooling-\(UUID().uuidString)", isDirectory: true)
        let zip = outputDirectory.appendingPathComponent("jacket-tooling.zip")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "head", to: zip)

        let expectedPrintMembers = Set(plan.parts.map { "print/\($0.name).stl" }).union([
            "print/prepared-master.stl",
            "print/master-hold-down-yoke.stl",
            "print/production-casting-funnel.stl",
        ])
        let expectedGuideMembers: Set<String> = [
            "guide/assembly-and-reuse.html",
            "guide/assembly-overview.svg",
            "guide/liner-fill-setup.svg",
            "guide/casting-setup.svg",
            "guide/trim-map.svg",
            "guide/hardware.csv",
        ]
        try assertV3ToolingContract(
            in: zip,
            requiredMembers: expectedPrintMembers.union(expectedGuideMembers)
        )
    }

    func testPublicWriteZipRejectsIncompletePlanInsteadOfBypassingAuthoritativeContract() throws {
        let cube = try MeshInspector.inspect(
            url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl")
        ).geometry
        var incompletePlan = MotherMoldPlan(
            parts: [MotherMoldPart(name: "mold-part-A", geometry: cube, isWatertight: true)],
            partingPlanes: [],
            cavity: cube,
            master: cube,
            diagnostics: []
        )
        incompletePlan.toolingContractVersion = 3
        incompletePlan.requestedPackaging = .manufacturingZip
        incompletePlan.toolingExportContract = MotherMoldToolingContract(
            toolingContractVersion: 3,
            state: .incomplete,
            qualification: .blocked,
            requiredArtifactRoles: [.moldPart, .preparedMaster, .holdDownYoke, .castingFunnel],
            blockingReasons: ["Prepared positive and fixture tooling are missing."]
        )
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-direct-bypass-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertThrowsError(
            try MotherMoldExporter.writeZip(plan: incompletePlan, modelName: "cube", to: zip),
            "The former direct writeZip(plan:) route must use the same authoritative v3 validator and reject an incomplete tooling plan."
        )
    }

    private func assertV3ToolingContract(in zip: URL, requiredMembers: Set<String>) throws {
        let directory = zip.deletingLastPathComponent().appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zip.path, "-d", directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "The tooling archive must be readable.")

        let members = try archiveMembers(in: directory)
        XCTAssertTrue(members.contains("manifest.json"), "v3 tooling ZIP requires manifest.json at its root.")
        XCTAssertTrue(
            requiredMembers.isSubset(of: members),
            "Silicone-jacket tooling ZIP is missing required package members: \(requiredMembers.subtracting(members).sorted())"
        )
        guard members.contains("manifest.json") else { return }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            "manifest.json must be a JSON object."
        )
        XCTAssertEqual(manifest["schema"] as? String, "refabartist.mothermold.tooling/v3")
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)

        let records = try XCTUnwrap(
            manifest["members"] as? [[String: Any]],
            "The v3 manifest must declare one PackageMember record for every non-manifest archive member."
        )
        let declared = Set(records.compactMap { $0["path"] as? String })
        XCTAssertEqual(
            declared,
            members.subtracting(["manifest.json"]),
            "The manifest inventory must exactly declare the archive inventory: no missing, extra, or undeclared members."
        )
    }

    private func archiveMembers(in directory: URL) throws -> Set<String> {
        let enumerator = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        return Set(enumerator.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.appending(path: path).path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        })
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
