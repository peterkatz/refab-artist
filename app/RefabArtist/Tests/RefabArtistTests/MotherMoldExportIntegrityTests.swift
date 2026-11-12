import XCTest
@testable import RefabArtist

final class MotherMoldExportIntegrityTests: XCTestCase {
    func testExporterRejectsDisconnectedPartInsteadOfDeletingGeometry() throws {
        let large = cube(side: 20, origin: Vec3(x: 0, y: 0, z: 0))
        let secondary = cube(side: 10, origin: Vec3(x: 30, y: 0, z: 0))
        let disconnected = combined(large, secondary)
        let part = MotherMoldPart(
            name: "mold-part-A",
            geometry: disconnected,
            isWatertight: true,
            bounds: nil
        )
        let plan = MotherMoldPlan(
            parts: [part],
            partingPlanes: [],
            cavity: large,
            master: large,
            diagnostics: [],
            printedPlasticCC: abs(MoldComponentFilter.signedVolume(disconnected)) / 1_000
        )
        var settings = MotherMoldSettings(
            subtype: .slipShell,
            toolingContractVersion: 2
        )
        settings.packaging = .laidOutPlate
        settings.includeAssemblyMap = false
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-disconnected-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertThrowsError(
            try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "disconnected", to: output),
            "A printable mold part must be one connected solid; export must not silently keep only the largest component."
        )
    }

    func testExporterRejectsPairwiseOverlapAtFinalBoundary() throws {
        let firstGeometry = cube(side: 20, origin: Vec3(x: 0, y: 0, z: 0))
        let secondGeometry = cube(side: 20, origin: Vec3(x: 10, y: 0, z: 0))
        let first = MotherMoldPart(
            name: "mold-part-A",
            geometry: firstGeometry,
            isWatertight: true,
            bounds: nil
        )
        let second = MotherMoldPart(
            name: "mold-part-B",
            geometry: secondGeometry,
            isWatertight: true,
            bounds: nil
        )
        let plan = MotherMoldPlan(
            parts: [first, second],
            partingPlanes: [],
            cavity: firstGeometry,
            master: firstGeometry,
            diagnostics: [],
            printedPlasticCC: (abs(MoldComponentFilter.signedVolume(firstGeometry))
                + abs(MoldComponentFilter.signedVolume(secondGeometry))) / 1_000
        )
        var settings = MotherMoldSettings(
            subtype: .slipShell,
            toolingContractVersion: 2
        )
        settings.packaging = .separateZip
        settings.includeAssemblyMap = false
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-overlap-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertThrowsError(
            try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "overlap", to: output)
        ) { error in
            guard case let .generatedPartsNotPairwiseDisjoint(reasons)? = error as? MotherMoldExporter.ExportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reasons.count, 1)
            XCTAssertTrue(reasons[0].contains("mold-part-A/mold-part-B overlap"))
            XCTAssertTrue(error.localizedDescription.contains("generated mold parts that overlap"))
            XCTAssertTrue(error.localizedDescription.contains("internal build failure"))
        }
    }

    func testExporterRejectsEveryMissingRequestedMoldProofEvenWithoutDiagnostics() throws {
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.packaging = .laidOutPlate
        settings.includeAssemblyMap = false
        let sanitized = settings.sanitized
        let firstGeometry = cube(side: 10, origin: Vec3(x: 0, y: 0, z: 0))
        let secondGeometry = cube(side: 10, origin: Vec3(x: 20, y: 0, z: 0))
        let parts = [
            MotherMoldPart(name: "mold-part-A", geometry: firstGeometry, isWatertight: true),
            MotherMoldPart(name: "mold-part-B", geometry: secondGeometry, isWatertight: true),
        ]
        let expectedInterfaces = sanitized.parts.planeCount * max(1, parts.count / 2)
        let validMount = MoldMasterMountBuilder.Summary(
            mode: .flatBaseSocket,
            isResolved: true,
            contactAreaMM2: 100,
            socketDepthMM: 5,
            fitClearanceMM: 0.25,
            sealLandWidthMM: 10,
            requiresSealant: true,
            locatorVolumeMM3: 100,
            finalLocatorRetention: 1
        )
        let baseline = MotherMoldPlan(
            parts: parts,
            partingPlanes: [PartitionPlane(
                normal: Vec3(x: 1, y: 0, z: 0),
                offset: 15,
                isManual: false
            )],
            cavity: firstGeometry,
            master: firstGeometry,
            diagnostics: [],
            masterMount: validMount,
            flangedSeamCount: expectedInterfaces,
            flangePlatesPlaced: expectedInterfaces * 2,
            effectiveBoltHoleCount: expectedInterfaces * sanitized.flange.boltHoleCount,
            registrationKeysPlaced: expectedInterfaces * sanitized.key.pinsPerSeam,
            spoutBored: true,
            ventsBoredCount: sanitized.spout.ventCount
        )

        let cases: [(String, (inout MotherMoldPlan) -> Void)] = [
            ("part count", { $0.parts.removeLast() }),
            ("parting planes", { $0.partingPlanes = [] }),
            ("flanges", { $0.flangedSeamCount = 0 }),
            ("flange plates", { $0.flangePlatesPlaced = 0 }),
            ("bolt holes", { $0.effectiveBoltHoleCount = 0 }),
            ("tapered keys", { $0.registrationKeysPlaced = 0 }),
            ("fill gate", { $0.spoutBored = false }),
            ("air vents", { $0.ventsBoredCount = max(0, sanitized.spout.ventCount - 1) }),
            ("master locator", { $0.masterMount.finalLocatorRetention = 0.95 }),
        ]

        for (label, mutation) in cases {
            var plan = baseline
            mutation(&plan)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("mothermold-contract-\(UUID().uuidString).stl")
            defer { try? FileManager.default.removeItem(at: output) }

            XCTAssertThrowsError(
                try MotherMoldExporter.write(plan: plan, settings: sanitized, modelName: "contract", to: output),
                label
            ) { error in
                guard case .planContractViolation? = error as? MotherMoldExporter.ExportError else {
                    return XCTFail("\(label) produced unexpected error: \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("Rebuild the mold"), label)
            }
        }
    }

    func testFourPartJacketZipContainsOnlyWatertightSTLsMatchingPlanVolumes() throws {
        // Only the recorded liner-registration failure is expected; any other
        // failure in this test still fails the run.
        let knownIssue = XCTExpectedFailure.Options()
        knownIssue.issueMatcher = { issue in
            let text = [
                issue.compactDescription,
                issue.detailedDescription ?? "",
                issue.associatedError.map { String(describing: $0) } ?? "",
            ].joined(separator: " ")
            return text.contains("liner registration stage failed")
                && text.contains("cannot spread its liner buttons over two principal directions")
        }
        XCTExpectFailure(
            "Known issue: a four-part reusable (v3) silicone jacket of the low-poly head stops in liner registration (a quarter shell cannot spread its liner buttons over two directions), so no package is written.",
            options: knownIssue
        )
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "tests/fixtures/organic/low_poly_head.stl")
        )
        var settings = MotherMoldSettings(toolingContractVersion: 3)
        settings.subtype = .siliconeJacket
        settings.parts = .four
        settings.packaging = .separateZip
        settings.includeAssemblyMap = false

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        for part in plan.parts {
            let preflight = MeshPreflight.analyze(geometry: part.geometry)
            XCTAssertTrue(
                preflight.isWatertight,
                "\(part.name) plan geometry must already satisfy the real import gate: boundary=\(preflight.boundaryEdgeCount), nonManifold=\(preflight.nonManifoldEdgeCount), degenerate=\(preflight.degenerateTriangleCount)"
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-export-integrity-\(UUID().uuidString)", isDirectory: true)
        let zip = directory.appendingPathComponent("jacket-four.zip")
        let unzipped = directory.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "head", to: zip)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", zip.path, "-d", unzipped.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)

        let files = try FileManager.default.contentsOfDirectory(
            at: unzipped,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "stl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, plan.parts.count)

        let planByName = Dictionary(uniqueKeysWithValues: plan.parts.map { ($0.name, $0) })
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let exported = try MeshInspector.inspect(url: file)
            XCTAssertTrue(
                exported.preflight.isWatertight,
                "\(name) serialized STL must pass the real import preflight: boundary=\(exported.preflight.boundaryEdgeCount), nonManifold=\(exported.preflight.nonManifoldEdgeCount), degenerate=\(exported.preflight.degenerateTriangleCount)"
            )
            let source = try XCTUnwrap(planByName[name])
            let sourceVolume = abs(MoldComponentFilter.signedVolume(source.geometry))
            let exportedVolume = abs(MoldComponentFilter.signedVolume(exported.geometry))
            XCTAssertEqual(
                exportedVolume,
                sourceVolume,
                accuracy: max(0.01, sourceVolume * 0.000_1),
                "Export must not delete or add geometry after the plan was measured and validated."
            )
        }

        var laidSettings = settings
        laidSettings.packaging = .laidOutPlate
        let laidURL = directory.appendingPathComponent("jacket-four-laid.stl")
        try MotherMoldExporter.write(
            plan: plan,
            settings: laidSettings,
            modelName: "head",
            to: laidURL
        )
        let laid = try MeshInspector.inspect(url: laidURL)
        XCTAssertTrue(
            laid.preflight.isWatertight,
            "Translated laid-out STL must pass the same import gate as separate parts."
        )
        XCTAssertEqual(
            laid.triangleCount,
            plan.parts.map { $0.geometry.triangleIndices.count / 3 }.reduce(0, +),
            "Laid-out export must preserve every validated triangle."
        )
        XCTAssertEqual(
            abs(MoldComponentFilter.signedVolume(laid.geometry)),
            plan.parts.map { abs(MoldComponentFilter.signedVolume($0.geometry)) }.reduce(0, +),
            accuracy: 0.05,
            "Layout translation and serialization must preserve total material volume."
        )
    }

    func testDefaultHeadFourPartSlipPlanPassesStrictTopologyGate() throws {
        try assertStrictSlipFixture(
            name: "head-four",
            fixture: "tests/fixtures/organic/low_poly_head.stl",
            parts: .four
        )
    }

    func testDefaultHandTwoPartSlipPlanPassesStrictTopologyGate() throws {
        try assertStrictSlipFixture(
            name: "hand-two",
            fixture: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj",
            parts: .two
        )
    }

    func testDefaultHandFourPartSlipPlanPassesStrictTopologyGate() throws {
        try assertStrictSlipFixture(
            name: "hand-four",
            fixture: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj",
            parts: .four
        )
    }

    private func assertStrictSlipFixture(
        name: String,
        fixture: String,
        parts: MoldPartCount
    ) throws {
        let model = try MeshInspector.inspect(url: repoRoot().appending(path: fixture))
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = parts

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        let expectedPartCount = parts == .two ? 2 : 4
        XCTAssertEqual(plan.parts.count, expectedPartCount, name)
        for part in plan.parts {
            let strict = MeshPreflight.analyze(geometry: part.geometry)
            XCTAssertTrue(
                strict.isWatertight,
                "\(name) \(part.name) must pass strict final-part topology: boundary=\(strict.boundaryEdgeCount), nonManifold=\(strict.nonManifoldEdgeCount), degenerate=\(strict.degenerateTriangleCount)"
            )
        }
    }

    private func combined(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) -> MeshGeometryData {
        let offset = Int32(lhs.vertices.count)
        return MeshGeometryData(
            vertices: lhs.vertices + rhs.vertices,
            triangleIndices: lhs.triangleIndices + rhs.triangleIndices.map { $0 + offset }
        )
    }

    private func cube(side: Double, origin: Vec3) -> MeshGeometryData {
        let x = origin.x, y = origin.y, z = origin.z, s = side
        let vertices = [
            Vec3(x: x, y: y, z: z), Vec3(x: x + s, y: y, z: z),
            Vec3(x: x + s, y: y + s, z: z), Vec3(x: x, y: y + s, z: z),
            Vec3(x: x, y: y, z: z + s), Vec3(x: x + s, y: y, z: z + s),
            Vec3(x: x + s, y: y + s, z: z + s), Vec3(x: x, y: y + s, z: z + s)
        ]
        let indices: [Int32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6,
            0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5
        ]
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
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
