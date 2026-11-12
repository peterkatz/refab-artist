import Foundation
import CryptoKit
import XCTest
@testable import RefabArtist

final class MotherMoldToolingPackageWriterTests: XCTestCase {
    func testWriterResultReportsTheActualPublishedArchiveAndTypedInventory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-tooling-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("tooling.zip")
        let result = try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: try completePlan(includeReferences: false),
            modelName: "Actual archive evidence",
            destination: destination
        )

        let archive = try Data(contentsOf: destination)
        let actualArchiveHash = SHA256.hash(data: archive)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(result.archiveSHA256, actualArchiveHash)

        let manifestBytes = try archiveMember("manifest.json", in: destination)
        XCTAssertEqual(manifestBytes, try result.manifest.deterministicJSON(prettyPrinted: true))
        let archiveMemberPaths = try archiveMembers(destination)
        XCTAssertEqual(result.manifest.members.count + 1, archiveMemberPaths.count)
        XCTAssertTrue(archiveMemberPaths.contains("print/mold-part-A.stl"))
        XCTAssertTrue(archiveMemberPaths.contains("print/mold-part-B.stl"))
        XCTAssertEqual(
            result.manifest.members.filter { $0.member.content == .geometry }.count,
            result.manifest.members.filter { $0.geometry != nil }.count
        )
        XCTAssertEqual(
            Set(result.manifest.members.compactMap { $0.member.toolingRole }),
            [.moldPart, .preparedMaster, .holdDownYoke, .castingFunnel]
        )
        XCTAssertEqual(result.manifest.hardwareItems.count, 1)
        XCTAssertEqual(result.manifest.hardwareItems[0].kind, .removableCrossPin)
    }

    func testHeadlessPackageMeasurementUsesPublishedArchiveEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-headless-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try completePlan(includeReferences: false)
        let destination = directory.appendingPathComponent("tooling.zip")
        let result = try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: plan,
            modelName: "Headless evidence",
            destination: destination
        )
        var settings = MotherMoldSettings(subtype: .siliconeJacket, toolingContractVersion: 3)
        settings.packaging = .manufacturingZip

        let contract = try HeadlessExportCommand.reusableToolingPackageContract(
            settings: settings,
            plan: plan,
            outputFormat: .stl,
            packageResult: result,
            outputURL: destination
        )

        let actualArchive = try Data(contentsOf: destination)
        let actualArchiveHash = SHA256.hash(data: actualArchive)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(contract["authoritative_v3_package_written"] as? Bool, true)
        XCTAssertEqual(contract["package_archive_sha256"] as? String, actualArchiveHash)
        XCTAssertEqual(contract["package_byte_count"] as? Int, actualArchive.count)
        XCTAssertEqual(contract["manifest_member_count"] as? Int, result.manifest.members.count)
        XCTAssertEqual(contract["manifest_geometry_member_count"] as? Int, 5)
        XCTAssertEqual(contract["manifest_hardware_item_count"] as? Int, 1)
        XCTAssertEqual(
            contract["manifest_typed_artifact_counts"] as? [String: Int],
            [
                ToolingArtifactRole.moldPart.rawValue: 2,
                ToolingArtifactRole.preparedMaster.rawValue: 1,
                ToolingArtifactRole.holdDownYoke.rawValue: 1,
                ToolingArtifactRole.castingFunnel.rawValue: 1,
            ]
        )
        XCTAssertEqual(
            contract["manifest_typed_hardware_counts"] as? [String: Int],
            [ToolingHardwareKind.removableCrossPin.rawValue: 1]
        )
    }

    func testValidatedPackageIsDeterministicAndSelfDescribing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-tooling-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = try completePlan(includeReferences: false)
        let first = directory.appendingPathComponent("first.zip")
        let second = directory.appendingPathComponent("second.zip")
        let firstResult = try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: plan,
            modelName: "T\u{00EA}te pr\u{00E9}par\u{00E9}e",
            destination: first
        )
        let secondResult = try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: plan,
            modelName: "T\u{00EA}te pr\u{00E9}par\u{00E9}e",
            destination: second
        )

        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertEqual(firstResult.archiveSHA256, secondResult.archiveSHA256)
        XCTAssertEqual(firstResult.manifest, secondResult.manifest)

        let members = try archiveMembers(first)
        XCTAssertTrue(members.contains("manifest.json"))
        XCTAssertTrue(members.contains("README.txt"))
        XCTAssertTrue(members.contains("print/prepared-master.stl"))
        XCTAssertTrue(members.contains("print/master-hold-down-yoke.stl"))
        XCTAssertTrue(members.contains("print/production-casting-funnel.stl"))
        XCTAssertTrue(members.contains("guide/assembly-and-reuse.html"))
        XCTAssertTrue(members.contains("guide/hardware.csv"))
        XCTAssertFalse(members.contains { $0.hasPrefix("reference/") })

        let manifestData = try archiveMember("manifest.json", in: first)
        let manifest = try JSONDecoder().decode(MotherMoldToolingManifest.self, from: manifestData)
        XCTAssertEqual(manifest.schema, MotherMoldToolingContract.schema)
        XCTAssertEqual(
            Set(manifest.members.map { $0.member.path }),
            Set(members).subtracting(["manifest.json"])
        )
        XCTAssertTrue(manifest.members.filter { $0.member.content == .geometry }.allSatisfy {
            $0.member.geometryMetrics?.isWatertight == true
                && $0.member.geometryMetrics?.connectedComponentCount == 1
                && $0.member.geometryMetrics?.hasConsistentWinding == true
        })
        XCTAssertTrue(manifest.members.filter { $0.member.content != .geometry }.allSatisfy {
            $0.member.geometryMetrics == nil
        })
        XCTAssertEqual(manifest.hardwareItems, plan.hardwareItems)
        XCTAssertEqual(manifest.exportContract.state, .geometryOnly)
        XCTAssertEqual(manifest.hardwareItems[0].qualification, .geometryOnly)
        let hardwareIDs = Set(manifest.hardwareItems.map(\.id.rawValue))
        let printableIDs = Set(manifest.members.compactMap { member in
            member.member.content == .geometry ? member.geometry?.artifactID.rawValue : nil
        })
        XCTAssertTrue(hardwareIDs.isDisjoint(with: printableIDs))

        let hardwareCSV = String(decoding: try archiveMember("guide/hardware.csv", in: first), as: UTF8.self)
        XCTAssertTrue(hardwareCSV.contains("MASTER HOLD-DOWN CROSS PIN"))
        XCTAssertTrue(hardwareCSV.contains("removableCrossPin"))
        XCTAssertFalse(hardwareCSV.contains("PREPARED MASTER"))
    }

    func testPreparedPostHoldDownRequiresExactlyOneMatchingRemovableCrossPin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-tooling-hardware-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var missing = try completePlan(includeReferences: false)
        missing.hardwareItems = []
        XCTAssertThrowsError(try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: missing,
            modelName: "Missing pin",
            destination: directory.appendingPathComponent("missing.zip")
        )) { error in
            XCTAssertEqual(error as? MotherMoldToolingPackageWriter.Error, .missingArtifacts(["missing required removable hold-down cross-pin hardware"]))
        }

        var duplicate = try completePlan(includeReferences: false)
        var secondPin = duplicate.hardwareItems[0]
        secondPin.id = ToolingHardwareItemID("MASTER HOLD-DOWN CROSS PIN SPARE")
        duplicate.hardwareItems.append(secondPin)
        XCTAssertThrowsError(try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: duplicate,
            modelName: "Duplicate pin",
            destination: directory.appendingPathComponent("duplicate.zip")
        )) { error in
            XCTAssertEqual(error as? MotherMoldToolingPackageWriter.Error, .missingArtifacts(["expected exactly one removable hold-down cross-pin hardware"]))
        }

        var incompatible = try completePlan(includeReferences: false)
        incompatible.hardwareItems[0].fixtureRequirement = ToolingHardwareFixtureRequirement(
            crossPinDiameterMillimeters: 5,
            minimumCrossPinLengthMillimeters: 32
        )
        XCTAssertThrowsError(try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: incompatible,
            modelName: "Wrong pin",
            destination: directory.appendingPathComponent("wrong.zip")
        )) { error in
            XCTAssertEqual(error as? MotherMoldToolingPackageWriter.Error, .missingArtifacts(["removable hold-down cross-pin hardware does not match its declared fixture requirement"]))
        }
    }

    func testReferenceMeshesAreIncludedOnlyWhenRequested() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-tooling-references-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("references.zip")
        let plan = try completePlan(includeReferences: true)
        _ = try MotherMoldToolingPackageWriter.validateAndWrite(
            plan: plan,
            modelName: "Reference test",
            destination: destination
        )

        let members = try archiveMembers(destination)
        XCTAssertTrue(members.contains("reference/active-source-master.obj"))
        XCTAssertTrue(members.contains("reference/as-poured-silicone-liner.obj"))
        XCTAssertTrue(members.contains("reference/production-silicone-liner.obj"))
    }

    private func completePlan(includeReferences: Bool) throws -> MotherMoldPlan {
        let source = try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 8, y: 8, z: 8))
        let partA = try box(center: Vec3(x: -15, y: 0, z: 0), extents: Vec3(x: 8, y: 10, z: 10))
        let partB = try box(center: Vec3(x: 15, y: 0, z: 0), extents: Vec3(x: 8, y: 10, z: 10))
        var plan = MotherMoldPlan(
            parts: [
                MotherMoldPart(name: "mold-part-A", geometry: partA, isWatertight: true),
                MotherMoldPart(name: "mold-part-B", geometry: partB, isWatertight: true),
            ],
            partingPlanes: [PartitionPlane(
                normal: Vec3(x: 1, y: 0, z: 0),
                offset: 0,
                isManual: false
            )],
            cavity: source,
            master: source,
            diagnostics: [],
            spoutBored: true
        )
        plan.toolingContractVersion = 3
        plan.requestedPackaging = .manufacturingZip
        plan.includeReferenceMeshes = includeReferences
        plan.masterPreparation = MasterPreparationSummary(
            state: .approved,
            retentionEvidence: .preparedPostGeometryOnly
        )
        plan.hardwareItems = [
            ToolingHardwareItem(
                id: ToolingHardwareItemID("MASTER HOLD-DOWN CROSS PIN"),
                kind: .removableCrossPin,
                description: "Removable cross-pin for the prepared-master hold-down yoke.",
                specification: "Load-rated smooth cross-pin or bolt; do not print.",
                quantity: 1,
                materialOrStandardHint: "Stainless steel, M4 nominal",
                requiredDimensions: [
                    ToolingHardwareDimension(
                        kind: .crossPinDiameter,
                        nominalMillimeters: 4,
                        tolerancePlusMinusMillimeters: 0.1
                    ),
                    ToolingHardwareDimension(
                        kind: .crossPinMinimumLength,
                        nominalMillimeters: 32,
                        tolerancePlusMinusMillimeters: nil
                    ),
                ],
                phases: [.linerFill, .demold],
                uses: [.preparedMasterHoldDown],
                responsibility: .shopSupplied,
                qualification: .geometryOnly,
                fixtureRequirement: ToolingHardwareFixtureRequirement(
                    crossPinDiameterMillimeters: 4,
                    minimumCrossPinLengthMillimeters: 32
                )
            ),
        ]
        plan.preparedMaster = ToolingArtifact(
            id: ToolingArtifactID("PREPARED MASTER"),
            name: "Prepared master",
            role: .preparedMaster,
            geometry: try box(center: Vec3(x: 0, y: 0, z: 20), extents: Vec3(x: 8, y: 8, z: 12)),
            qualification: .topologyValid
        )
        plan.fixtureArtifacts = [
            ToolingArtifact(
                id: ToolingArtifactID("YOKE"),
                name: "Master hold-down yoke",
                role: .holdDownYoke,
                geometry: try box(center: Vec3(x: 0, y: 18, z: 20), extents: Vec3(x: 14, y: 4, z: 8)),
                qualification: .topologyValid
            ),
            ToolingArtifact(
                id: ToolingArtifactID("CAST FUNNEL"),
                name: "Production casting funnel",
                role: .castingFunnel,
                geometry: try box(center: Vec3(x: 0, y: -18, z: 20), extents: Vec3(x: 10, y: 4, z: 10)),
                qualification: .topologyValid
            ),
        ]
        if includeReferences {
            plan.asPouredLiner = ToolingArtifact(
                id: ToolingArtifactID("AS-POURED LINER"),
                name: "As-poured liner",
                role: .referenceAsPouredLiner,
                geometry: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 10, y: 10, z: 10)),
                qualification: .referenceOnly
            )
            plan.productionLiner = ToolingArtifact(
                id: ToolingArtifactID("PRODUCTION LINER"),
                name: "Production liner",
                role: .referenceProductionLiner,
                geometry: try box(center: Vec3(x: 0, y: 0, z: 0), extents: Vec3(x: 9, y: 9, z: 9)),
                qualification: .referenceOnly
            )
        }
        plan.toolingExportContract = MotherMoldToolingContract(
            toolingContractVersion: 3,
            state: .geometryOnly,
            qualification: .physicalEvidenceRequired,
            requiredArtifactRoles: [.moldPart, .preparedMaster, .holdDownYoke, .castingFunnel],
            warnings: ["Physical evidence remains required."]
        )
        return plan
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        let handle = try ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents))
        return try ManifoldEngine.toMesh(handle)
    }

    private func archiveMembers(_ archive: URL) throws -> [String] {
        let data = try runUnzip(["-Z1", archive.path])
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func archiveMember(_ path: String, in archive: URL) throws -> Data {
        try runUnzip(["-p", archive.path, path])
    }

    private func runUnzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }
}
