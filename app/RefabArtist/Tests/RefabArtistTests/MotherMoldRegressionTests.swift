import XCTest
@testable import RefabArtist

final class MotherMoldRegressionTests: XCTestCase {
    private struct ComponentMetric: Equatable {
        var triangleCount: Int
        var signedVolume: Double
    }

    func testM0D1HealedHandFixtureDocumentsPreflightAsymmetry() throws {
        let model = try inspect("app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")

        XCTAssertFalse(model.preflight.isWatertight, "Fixture must reproduce D1 before the fix.")
        XCTAssertEqual(model.preflight.boundaryEdgeCount, 0, "The D1 fixture is closed but rejected by the preflight-only v1 gate.")
        XCTAssertGreaterThan(model.preflight.nonManifoldEdgeCount, 0, "The D1 fixture carries residual self-contact edges.")
    }

    func testM1ClosedHealerGradeHandIsNotRejectedAtEntryGate() throws {
        let model = try inspect("app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout = SpoutSettings(mode: .auto, spoutDiameter: 0, ventCount: 0,
                                       ventDiameter: 0.5,
                                       manualSpoutX: 0, manualSpoutY: 0, manualSpoutZ: 0)

        XCTAssertFalse(model.preflight.isWatertight, "Fixture must still exercise the healer-grade import path.")
        XCTAssertEqual(model.preflight.boundaryEdgeCount, 0, "M1 only accepts closed masters; open boundaries must stay rejected.")

        do {
            _ = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        } catch MotherMoldPlannerError.masterNotWatertight {
            XCTFail("Closed healer-grade master reached the old masterNotWatertight entry gate.")
        } catch {
            // Later stages may still fail before their milestones; this test is
            // scoped to the entry gate and should not mask those future gates.
        }
    }

    func testM4JacketHalvesHavePourThroughHole() throws {
        let fixture = "tests/fixtures/organic/low_poly_head.stl"
        let plan = try buildPlan(fixture: fixture, subtype: .siliconeJacket)
        XCTAssertEqual(plan.parts.count, 2, "Baseline fixture should produce the documented 2-part jacket.")

        XCTAssertTrue(plan.spoutBored, "M4 fixed: jacket output should prove a fill channel was bored.")
        let model = try inspect(fixture)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: model.geometry, settings: settings)
        let mounted = MoldMasterMountBuilder.apply(
            shell: shell.solid,
            master: model.geometry,
            settings: settings
        )
        let partition = try MoldPartitioner.partition(
            shell: mounted.solid,
            planes: plan.partingPlanes,
            settings: settings
        )
        let beforeFeatures = try MoldFlangeBuilder.applyFlanges(
            parts: partition.parts,
            planes: partition.planes,
            flange: settings.flange,
            cavity: cavity,
            seed: settings.seed
        )
        XCTAssertEqual(beforeFeatures.flangedSeamCount, plan.flangedSeamCount)

        let genusBeforeFeatures = try beforeFeatures.parts.map { try manifoldGenus(of: $0.geometry) }.reduce(0, +)
        let afterFeatures = try MoldFeatureBuilder.applyFeatures(
            parts: beforeFeatures.parts,
            cavity: cavity,
            openPlane: shell.openPlane,
            settings: settings,
            seed: settings.seed,
            partingPlanes: plan.partingPlanes
        )
        let genusAfterFeatures = try afterFeatures.parts.map { try manifoldGenus(of: $0.geometry) }.reduce(0, +)
        let afterKeys = try MoldKeyBuilder.applyKeys(
            parts: afterFeatures.parts,
            planes: plan.partingPlanes,
            key: settings.key
        )
        let genusAfterKeys = try afterKeys.parts.map { try manifoldGenus(of: $0.geometry) }.reduce(0, +)
        let genusByPart = try plan.parts.map { part in
            try manifoldGenus(of: part.geometry)
        }
        XCTAssertEqual(
            genusAfterFeatures,
            genusBeforeFeatures + 3,
            "The spout and two vents must each add exactly one tunnel. Before features: \(genusBeforeFeatures); after features: \(genusAfterFeatures)."
        )
        XCTAssertEqual(afterFeatures.spoutBored ? 1 : 0, 1, "The fill channel must be bored exactly once.")
        XCTAssertEqual(afterFeatures.ventsBoredCount, 2, "Both requested vents must be bored exactly once.")
        XCTAssertEqual(
            genusAfterKeys,
            genusAfterFeatures,
            "Tapered bosses and blind clearance pockets must not create through-tunnels. After features: \(genusAfterFeatures); after keys: \(genusAfterKeys)."
        )
        XCTAssertEqual(
            genusByPart.reduce(0, +),
            genusAfterKeys,
            "Final printability validation must preserve the measured feature topology. After keys: \(genusAfterKeys); final per-part genus: \(genusByPart)."
        )
    }

    func testM4SlipPreservesCavityAndUsesControlledFillGate() throws {
        let model = try inspect("tests/fixtures/organic/low_poly_head.stl")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: model.geometry, settings: settings)
        let top = try XCTUnwrap(bounds(of: cavity)?.max.z)
        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        XCTAssertEqual(
            shell.openPlane.offset,
            top,
            accuracy: 1.0e-6,
            "The reference plane must stay at the cavity top instead of cutting away artwork."
        )
        XCTAssertTrue(
            plan.spoutBored,
            "Rigid molds need a verified sacrificial funnel and fill channel. Diagnostics: \(plan.diagnostics.map(\.message).joined(separator: " | "))"
        )
    }

    func testM0D6SlipBuildNoLongerContainsFloatingDebris() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell)
        let components = plan.parts.flatMap { connectedComponents(of: $0.geometry) }
        let negative = components.filter { $0.signedVolume < 0 }

        XCTAssertEqual(components.count, plan.parts.count, "D6 fixed: slip build should not include floating debris components.")
        XCTAssertTrue(negative.isEmpty, "D6 fixed: inverted debris components must be absent.")
        XCTAssertFalse(plan.diagnostics.contains { $0.message.contains("Removed 0") && $0.message.contains("debris") },
                       "D6 fixed: debris reporting must be truthful when the revised pipeline creates no fragment to remove.")
    }

    func testM2SlipBuildDropsDebrisComponents() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell)
        let components = plan.parts.flatMap { connectedComponents(of: $0.geometry) }

        XCTAssertEqual(components.count, plan.parts.count, "M2: each exported part should contain exactly one printable component.")
        XCTAssertTrue(components.allSatisfy { $0.signedVolume > 0 }, "M2: inverted debris components must be dropped.")
    }

    func testM0D2AssemblyGuideNoLongerPromisesSpoutUnconditionally() throws {
        let plan = makeGuideOnlyPlan()
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.packaging = .laidOutPlate
        settings.includeAssemblyMap = true
        let guideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-guide-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: guideURL) }

        try MotherMoldExporter.writeAssemblyMap(
            plan: plan,
            settings: settings,
            modelName: "guide",
            to: guideURL
        )
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        XCTAssertFalse(guide.contains("through the spout"), "D2 fixed: guide must not promise a spout when the plan does not prove one exists.")
        XCTAssertTrue(guide.contains("STOP: no verified pour channel"), "The guide must stop the artist when no controlled fill gate was verified.")
    }

    func testM2AssemblyGuideDoesNotPromiseAbsentFeaturesAndPrintsWarnings() throws {
        var plan = makeGuideOnlyPlan()
        plan.diagnostics = [MoldDiagnostic(.warning, "synthetic warning for guide conditioning")]
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.packaging = .laidOutPlate
        settings.includeAssemblyMap = true
        let guideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-guide-m2-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: guideURL) }

        try MotherMoldExporter.writeAssemblyMap(
            plan: plan,
            settings: settings,
            modelName: "guide",
            to: guideURL
        )
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        XCTAssertTrue(guide.contains("[WARN]"), "M2: guide must print warning diagnostics, not only errors.")
        XCTAssertFalse(guide.contains("through the spout"), "M2: guide must not promise a spout unless the plan proves one was bored.")
        XCTAssertFalse(guide.contains("flange bolt holes"), "M2: guide must not promise flange bolt holes unless flanges were built.")
    }

    func testAssemblyGuideUsesActualFeatureCountsAndSubtypeAssembly() throws {
        var slipPlan = makeGuideOnlyPlan()
        slipPlan.parts.append(slipPlan.parts[0])
        slipPlan.registrationKeysPlaced = 0
        slipPlan.flangePlatesPlaced = 0
        slipPlan.effectiveBoltHoleCount = 0
        var slipSettings = MotherMoldSettings.defaultValue
        slipSettings.subtype = .slipShell
        slipSettings.packaging = .laidOutPlate
        slipSettings.includeAssemblyMap = true
        let slipGuideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-guide-counts-slip-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: slipGuideURL) }

        try MotherMoldExporter.writeAssemblyMap(
            plan: slipPlan,
            settings: slipSettings,
            modelName: "guide",
            to: slipGuideURL
        )
        let slipGuide = try String(contentsOf: slipGuideURL, encoding: .utf8)
        XCTAssertTrue(slipGuide.contains("Assemble the rigid negative empty"))
        XCTAssertTrue(slipGuide.contains("original master is not present during casting"))
        XCTAssertFalse(slipGuide.contains("Seat the physical master"), "Rigid-negative guides must not instruct users to place the master.")
        XCTAssertFalse(slipGuide.contains("registration key"), "No-key builds must use plain-seam wording only.")
        XCTAssertTrue(slipGuide.contains("plain seams"))
        XCTAssertFalse(slipGuide.contains("bolts through"))

        var jacketPlan = slipPlan
        jacketPlan.registrationKeysPlaced = 2
        jacketPlan.flangedSeamCount = 1
        jacketPlan.flangePlatesPlaced = 3
        jacketPlan.effectiveBoltHoleCount = 4
        jacketPlan.spoutBored = true
        jacketPlan.masterMount = MoldMasterMountBuilder.Summary(
            mode: .flatBaseSocket,
            isResolved: true,
            contactAreaMM2: 100,
            socketDepthMM: 5,
            fitClearanceMM: 0.25,
            sealLandWidthMM: 10
        )
        var jacketSettings = slipSettings
        jacketSettings.subtype = .siliconeJacket
        let jacketGuideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-guide-counts-jacket-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: jacketGuideURL) }

        try MotherMoldExporter.writeAssemblyMap(
            plan: jacketPlan,
            settings: jacketSettings,
            modelName: "guide",
            to: jacketGuideURL
        )
        let jacketGuide = try String(contentsOf: jacketGuideURL, encoding: .utf8)
        XCTAssertTrue(jacketGuide.contains("Seat the physical master in the generated base socket"))
        XCTAssertTrue(jacketGuide.contains("2 verified tapered key pairs"))
        XCTAssertTrue(jacketGuide.contains("4 verified flange holes"))
        XCTAssertTrue(jacketGuide.contains("through the sacrificial funnel and fill channel"))
        XCTAssertTrue(jacketGuide.contains("remove the master"))
    }

    func testM3OrganicTwoPartBuildHasARealFlangedSeam() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell)

        XCTAssertEqual(plan.parts.count, 2, "M3 gate uses the organic low-poly head as the two-part flange fixture.")
        XCTAssertEqual(plan.flangedSeamCount, 1, "M3: the parting seam must receive a real clampable flange.")
        XCTAssertFalse(plan.diagnostics.contains { $0.severity == .error && $0.message.contains("no way to clamp") },
                       "M3: planner must not return a successful build with no clamp path.")
    }

    func testM4RigidShellPreservesTheCompleteCavityForAControlledGate() throws {
        let model = try inspect("tests/fixtures/organic/low_poly_head.stl")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: model.geometry, settings: settings)
        let top = try XCTUnwrap(bounds(of: cavity)?.max.z)

        XCTAssertGreaterThanOrEqual(
            shell.openPlane.offset,
            top - 1.0e-6,
            "A cavity-sized open face must not cut away the artwork; pouring uses the later sacrificial gate."
        )
    }

    func testM4JacketBuildBoresAOneSidedSpout() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .siliconeJacket)

        XCTAssertEqual(plan.parts.count, 2, "M4 gate uses the organic low-poly head as the two-part jacket fixture.")
        XCTAssertTrue(plan.spoutBored, "M4: silicone-jacket output must have a bored fill channel.")
        XCTAssertTrue(plan.parts.contains { part in
            let chi = eulerCharacteristic(of: part.geometry)
            return max(0, (2 - chi) / 2) > 0
        }, "M4: the bored jacket spout must change the exported topology, not just report that a boolean ran.")
        XCTAssertFalse(plan.diagnostics.contains { $0.severity == .error && $0.message.contains("no fill channel") },
                       "M4: planner must not return a successful jacket with no fill channel.")
    }

    func testM6JacketPlanAndGuideReportMaterialVolumes() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .siliconeJacket)
        let silicone = try XCTUnwrap(plan.estimatedSiliconeCC, "M6: silicone jacket plans must estimate the silicone gap volume.")

        XCTAssertGreaterThan(plan.printedPlasticCC, 0, "M6: printed plastic volume must be measured from exported parts.")
        XCTAssertGreaterThan(silicone, 0, "M6: silicone gap volume must be positive for jacket builds.")
        XCTAssertTrue(plan.diagnostics.contains { $0.severity == .info && $0.message.contains("Printed plastic") },
                      "M6: the Fit/Warnings panel needs an info diagnostic with material estimates.")

        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.includeAssemblyMap = true
        settings.packaging = .laidOutPlate
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-m6-guide-\(UUID().uuidString).stl")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: output.deletingPathExtension().appendingPathExtension("txt"))
        }

        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "low_poly_head", to: output)
        let guide = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        XCTAssertTrue(guide.contains("Material estimates"), "M6: assembly guide header must print the material estimate line.")
        XCTAssertTrue(guide.contains("Printed plastic"), "M6: guide must show printed plastic cc.")
        XCTAssertTrue(guide.contains("Estimated silicone"), "M6: guide must show jacket silicone cc.")
    }

    func testM6HeadAutoPartingPrefersAxisAlignedPlane() throws {
        let planA = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell)
        let planB = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell)
        let first = try XCTUnwrap(planA.partingPlanes.first)
        let second = try XCTUnwrap(planB.partingPlanes.first)

        XCTAssertNotNil(first.axisAligned, "M6: low_poly_head auto parting should choose an axis-aligned primary plane.")
        XCTAssertEqual(first.normalX, second.normalX, accuracy: 1.0e-9, "M6: axis-preferred parting must be deterministic.")
        XCTAssertEqual(first.normalY, second.normalY, accuracy: 1.0e-9, "M6: axis-preferred parting must be deterministic.")
        XCTAssertEqual(first.normalZ, second.normalZ, accuracy: 1.0e-9, "M6: axis-preferred parting must be deterministic.")
    }

    func testM6HeadlessMeasurementsIncludeMaterialVolumes() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-m6-headless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        // A reusable (v3) silicone jacket ships as one manufacturing ZIP.
        let output = outputDirectory.appendingPathComponent("head-jacket.zip")
        let measurement = outputDirectory.appendingPathComponent("head-jacket.json")
        let arguments = [
            "--headless-export",
            "--mode", "motherMold",
            "--format", "stl",
            "--subtype", "siliconeJacket",
            "--fixture", repoRoot().appending(path: "tests/fixtures/organic/low_poly_head.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ]

        // A silicone jacket changes the master (the prepared post's gate
        // root), so the first run only reports the change and its approval
        // signature; the approved rerun writes the package.
        do {
            try HeadlessExportCommand.run(arguments: arguments)
            XCTFail("A prepared-master jacket must ask for approval before it writes a package.")
        } catch HeadlessExportError.motherMoldEngineFailed(let message) {
            XCTAssertTrue(message.contains("--approve-modifications"), message)
        }
        let approval = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: measurement)) as? [String: Any]
        )
        XCTAssertEqual(approval["phase"] as? String, "approval-required")
        XCTAssertEqual(approval["manufacturing_package_written"] as? Bool, false)
        let signature = try XCTUnwrap(approval["approval_signature"] as? String)
        try HeadlessExportCommand.run(arguments: arguments + ["--approve-modifications", signature])

        let data = try Data(contentsOf: measurement)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(json["printed_plastic_cc"] as? Double), 0)
        XCTAssertGreaterThan(try XCTUnwrap(json["estimated_silicone_cc"] as? Double), 0)
        XCTAssertNotNil(json["registration_keys_placed"] as? Int)
        XCTAssertNotNil(json["flange_plate_count"] as? Int)
        XCTAssertNotNil(json["effective_bolt_hole_count"] as? Int)
        XCTAssertFalse(try XCTUnwrap(json["part_metrics"] as? [[String: Any]]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(json["parting_planes"] as? [[String: Any]]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(json["diagnostics"] as? [[String: Any]]).isEmpty)
    }

    func testM7HeadSlipFourDefaultFlangesDoNotLeakParts() throws {
        let plan = try buildPlan(fixture: "tests/fixtures/organic/low_poly_head.stl", subtype: .slipShell, parts: .four)

        XCTAssertEqual(plan.parts.count, 4, "M7 matrix: low_poly_head slip-shell four-part default build should complete.")
        XCTAssertTrue(plan.parts.allSatisfy(\.isWatertight), "M7 matrix: flange fallback must never return a leaky part.")
        XCTAssertTrue(plan.flangedSeamCount > 0, "M7 matrix: at least one seam should retain a real flange when defaults request flanges.")
        if plan.flangedSeamCount < plan.partingPlanes.count {
            XCTAssertTrue(plan.diagnostics.contains { $0.message.contains("flange skipped") || $0.message.contains("Only") },
                          "M7 matrix: any skipped flange seam must be reported loudly.")
        }
    }

    private func buildPlan(
        fixture: String,
        subtype: MoldSubtype,
        parts: MoldPartCount = .two
    ) throws -> MotherMoldPlan {
        let model = try inspect(fixture)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = subtype
        settings.parts = parts
        return try MotherMoldPlanner.planThrowing(model: model, settings: settings)
    }

    private func inspect(_ relativePath: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: relativePath))
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func makeGuideOnlyPlan() -> MotherMoldPlan {
        let cube = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0), Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 10, y: 10, z: 0), Vec3(x: 0, y: 10, z: 0),
                Vec3(x: 0, y: 0, z: 10), Vec3(x: 10, y: 0, z: 10),
                Vec3(x: 10, y: 10, z: 10), Vec3(x: 0, y: 10, z: 10)
            ],
            triangleIndices: [
                0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
                0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6,
                0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5
            ]
        )
        let part = MotherMoldPart(
            name: "mold-part-A",
            geometry: cube,
            isWatertight: true,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        )
        return MotherMoldPlan(parts: [part], partingPlanes: [], cavity: cube, master: cube, diagnostics: [])
    }

    private func manifoldGenus(of geometry: MeshGeometryData) throws -> Int {
        try ManifoldEngine.genus(ManifoldEngine.make(from: geometry))
    }

    private func eulerCharacteristic(of geometry: MeshGeometryData) -> Int {
        let welded = weldedVertexIds(geometry.vertices)
        var vertices = Set<Int>()
        var edges = Set<EdgeKey>()
        var faces = 0
        var i = 0
        while i + 2 < geometry.triangleIndices.count {
            let a = welded[Int(geometry.triangleIndices[i])]
            let b = welded[Int(geometry.triangleIndices[i + 1])]
            let c = welded[Int(geometry.triangleIndices[i + 2])]
            vertices.insert(a); vertices.insert(b); vertices.insert(c)
            edges.insert(EdgeKey(a, b)); edges.insert(EdgeKey(b, c)); edges.insert(EdgeKey(c, a))
            faces += 1
            i += 3
        }
        return vertices.count - edges.count + faces
    }

    private func connectedComponents(of geometry: MeshGeometryData) -> [ComponentMetric] {
        let welded = weldedVertexIds(geometry.vertices)
        let maxId = (welded.max() ?? -1) + 1
        guard maxId > 0 else { return [] }
        var parent = Array(0..<maxId)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func unite(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var triangles: [(Int, Int, Int)] = []
        var i = 0
        while i + 2 < geometry.triangleIndices.count {
            let a = welded[Int(geometry.triangleIndices[i])]
            let b = welded[Int(geometry.triangleIndices[i + 1])]
            let c = welded[Int(geometry.triangleIndices[i + 2])]
            unite(a, b); unite(b, c); unite(c, a)
            triangles.append((Int(geometry.triangleIndices[i]), Int(geometry.triangleIndices[i + 1]), Int(geometry.triangleIndices[i + 2])))
            i += 3
        }

        var byRoot: [Int: [ComponentMetric]] = [:]
        var totals: [Int: (count: Int, volume: Double)] = [:]
        for tri in triangles {
            let root = find(welded[tri.0])
            let a = geometry.vertices[tri.0], b = geometry.vertices[tri.1], c = geometry.vertices[tri.2]
            var value = totals[root] ?? (0, 0)
            value.count += 1
            value.volume += signedTetraVolume(a, b, c)
            totals[root] = value
        }
        for (root, value) in totals {
            byRoot[root] = [ComponentMetric(triangleCount: value.count, signedVolume: value.volume)]
        }
        return byRoot.keys.sorted().flatMap { byRoot[$0] ?? [] }
    }

    private struct EdgeKey: Hashable {
        var a: Int
        var b: Int
        init(_ x: Int, _ y: Int) {
            a = min(x, y)
            b = max(x, y)
        }
    }

    private func weldedVertexIds(_ vertices: [Vec3]) -> [Int] {
        var ids: [VertexKey: Int] = [:]
        var out: [Int] = []
        out.reserveCapacity(vertices.count)
        for v in vertices {
            let key = VertexKey(v)
            if let id = ids[key] {
                out.append(id)
            } else {
                let id = ids.count
                ids[key] = id
                out.append(id)
            }
        }
        return out
    }

    private struct VertexKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
        init(_ v: Vec3) {
            x = Int64((v.x * 1_000_000).rounded())
            y = Int64((v.y * 1_000_000).rounded())
            z = Int64((v.z * 1_000_000).rounded())
        }
    }

    private func signedTetraVolume(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let det = a.x * (b.y * c.z - b.z * c.y)
            - a.y * (b.x * c.z - b.z * c.x)
            + a.z * (b.x * c.y - b.y * c.x)
        return det / 6.0
    }

    private func bounds(of geometry: MeshGeometryData) -> Bounds3D? {
        guard var minV = geometry.vertices.first else { return nil }
        var maxV = minV
        for v in geometry.vertices.dropFirst() {
            minV.x = min(minV.x, v.x); minV.y = min(minV.y, v.y); minV.z = min(minV.z, v.z)
            maxV.x = max(maxV.x, v.x); maxV.y = max(maxV.y, v.y); maxV.z = max(maxV.z, v.z)
        }
        return Bounds3D(min: minV, max: maxV)
    }
}
