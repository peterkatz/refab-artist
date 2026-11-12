import XCTest
@testable import RefabArtist

final class UndercutSplitExportTests: XCTestCase {
    func testExceedsToleranceAndStalePlanStillWriteCompleteSTLPackage() throws {
        let fixture = try makeFixture()
        var settings = UndercutSplitSettings.defaultValue
        settings.undercutToleranceMM = 2
        settings.minRegionAreaMM2 = 4
        let output = temporaryURL(extension: "zip")
        defer { try? FileManager.default.removeItem(at: output) }

        let report = try PartitionExporter.write(
            undercutPlan: fixture.plan,
            settings: settings,
            sourceGeometry: fixture.sourceGeometry,
            modelName: "artist scan.obj",
            output: .separateSTLZip,
            additionalWarnings: ["Settings changed after this measurement; measurements are stale."],
            to: output
        )

        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(2)), Array("PK".utf8))
        XCTAssertEqual(report.overallStatus, .splitExceedsTolerance)
        XCTAssertTrue(report.warnings.contains(report.overallStatusMessage))
        XCTAssertTrue(report.warnings.contains { $0.contains("stale") })

        let entries = try PartitionExporter.undercutZipEntries(
            plan: fixture.plan,
            report: report,
            modelName: "artist scan.obj",
            output: .separateSTLZip
        )
        XCTAssertEqual(entries.filter { $0.name.hasSuffix(".stl") }.count, 2)
        XCTAssertTrue(entries.contains { $0.name == "artist-scan-piece-A.stl" })
        XCTAssertTrue(entries.contains { $0.name == "artist-scan-piece-B.stl" })
        XCTAssertTrue(entries.contains { $0.name == "assembly-guide.txt" })
        XCTAssertTrue(entries.contains { $0.name == "undercut-report.json" })
    }

    func testAnalysisErrorRootPieceExportsWithNullMeasurementFields() throws {
        let fixture = try makeFixture()
        let rootPiece = UndercutSplitPiece(
            regionID: fixture.root,
            mesh: fixture.plan.pieces.flatMap(\.mesh.triangles).isEmpty
                ? fixture.plan.pieces[0].mesh
                : AttributedMesh(
                    triangles: fixture.plan.pieces.flatMap(\.mesh.triangles),
                    sourceGeometryFingerprint: fixture.sourceFingerprint,
                    sourceReferencedVertices: [],
                    omittedDegenerateSourceFaceIDs: []
                ),
            pullAxis: Vec3(x: 0, y: 0, z: 1),
            measurement: nil
        )
        let errorPlan = UndercutSplitPlan(
            status: .analysisError,
            cutTree: PartitionCutTree(rootRegionID: fixture.root, nodes: []),
            pieces: [rootPiece],
            statusMessage: "Analysis failed at interval construction on Piece A. Pieces can still be exported; no undercut measurement is attached.",
            warnings: ["Source measurement unavailable."]
        )
        let report = UndercutSplitReport.make(
            plan: errorPlan,
            settings: .defaultValue,
            sourceGeometry: fixture.sourceGeometry,
            appVersion: "test"
        )

        XCTAssertEqual(report.pieces.count, 1)
        XCTAssertEqual(report.pieces[0].status, "measurementUnavailable")
        XCTAssertNil(report.pieces[0].measuredAtResolutionMM)
        XCTAssertTrue(report.pieces[0].regions.isEmpty)
        XCTAssertTrue(report.warnings.contains(errorPlan.statusMessage))

        let output = temporaryURL(extension: "zip")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertNoThrow(try PartitionExporter.write(
            undercutPlan: errorPlan,
            settings: .defaultValue,
            sourceGeometry: fixture.sourceGeometry,
            modelName: "scan",
            output: .namedObjectOBJZip,
            to: output
        ))
    }

    func testReportSchemaContainsEveryRegionFilteredFlagsAndDeterministicFacts() throws {
        let fixture = try makeFixture()
        var settings = UndercutSplitSettings.defaultValue
        settings.undercutToleranceMM = 2
        settings.minRegionAreaMM2 = 4
        settings.tolerancePolicyVersion = 7
        let first = UndercutSplitReport.make(
            plan: fixture.plan,
            settings: settings,
            sourceGeometry: fixture.sourceGeometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )
        let second = UndercutSplitReport.make(
            plan: fixture.plan,
            settings: settings,
            sourceGeometry: fixture.sourceGeometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.encodedJSON(), try second.encodedJSON())
        let reopenedSettings = try JSONDecoder().decode(
            UndercutSplitSettings.self,
            from: JSONEncoder().encode(settings)
        )
        let reopened = UndercutSplitReport.make(
            plan: fixture.plan,
            settings: reopenedSettings,
            sourceGeometry: fixture.sourceGeometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(first.schemaVersion, 1)
        XCTAssertEqual(first.versions.planner, settings.plannerVersion)
        XCTAssertEqual(first.versions.tolerancePolicy, settings.tolerancePolicyVersion)
        XCTAssertEqual(first.settings.output, .namedObjectOBJZip)
        XCTAssertEqual(first.source.fingerprint, fixture.sourceFingerprint)
        XCTAssertEqual(first.source.units, "millimeters")
        XCTAssertEqual(
            first.source.preflight.sourceGeometryFingerprint,
            fixture.sourceFingerprint
        )
        XCTAssertEqual(first.cutTree, fixture.plan.cutTree)
        XCTAssertEqual(first.seamAdjacency.count, 1)
        XCTAssertEqual(first.assemblySteps.count, 1)
        XCTAssertEqual(first.pieces.flatMap(\.regions).count, 2)

        let filtered = try XCTUnwrap(first.pieces.flatMap(\.regions).first { $0.id == "filtered" })
        XCTAssertTrue(filtered.filteredByArea)
        XCTAssertEqual(filtered.relationToTolerance, "overTolerance")
        XCTAssertEqual(filtered.faceCount, 1)
        XCTAssertTrue(first.pieces.allSatisfy { !$0.meshHash.isEmpty })
    }

    func testToleranceStatusesUseOneMeasurementDecisionPathIncludingStrictZero() throws {
        let fixture = try makeFixture()
        func report(tolerance: Double) -> UndercutSplitReport {
            var settings = UndercutSplitSettings.defaultValue
            settings.undercutToleranceMM = tolerance
            settings.minRegionAreaMM2 = 4
            return UndercutSplitReport.make(
                plan: fixture.plan,
                settings: settings,
                sourceGeometry: fixture.sourceGeometry,
                appVersion: "test"
            )
        }

        let strict = report(tolerance: 0)
        let defaultTolerance = report(tolerance: 2)
        let relaxed = report(tolerance: 3)
        XCTAssertEqual(
            strict.pieces.first(where: { !$0.regions.isEmpty })?.status,
            "exceedsTolerance"
        )
        XCTAssertEqual(strict.overallStatus, .splitExceedsTolerance)
        XCTAssertTrue(strict.overallStatusMessage.contains("measured at 0.4 mm grid"))
        XCTAssertTrue(strict.overallStatusMessage.contains("max 8 pieces"))

        XCTAssertEqual(
            defaultTolerance.pieces.first(where: { !$0.regions.isEmpty })?.status,
            "exceedsTolerance"
        )
        XCTAssertEqual(defaultTolerance.overallStatus, .splitExceedsTolerance)
        XCTAssertTrue(defaultTolerance.warnings.contains(defaultTolerance.overallStatusMessage))

        XCTAssertEqual(
            relaxed.pieces.first(where: { !$0.regions.isEmpty })?.status,
            "withinTolerance"
        )
        XCTAssertEqual(relaxed.overallStatus, .splitWithinTolerance)
        XCTAssertTrue(relaxed.overallStatusMessage.contains("3 mm undercut tolerance"))
        XCTAssertFalse(relaxed.overallStatusMessage.contains("2 mm undercut tolerance"))
        XCTAssertFalse(relaxed.warnings.contains(fixture.plan.statusMessage))
    }

    func testNamedObjectPackageAndAssemblyGuideListEveryPieceSeamAndStep() throws {
        let fixture = try makeFixture()
        let report = UndercutSplitReport.make(
            plan: fixture.plan,
            settings: .defaultValue,
            sourceGeometry: fixture.sourceGeometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )
        let entries = try PartitionExporter.undercutZipEntries(
            plan: fixture.plan,
            report: report,
            modelName: "hook",
            output: .namedObjectOBJZip
        )
        let obj = try XCTUnwrap(entries.first { $0.name == "hook-undercut-split.obj" })
        let objText = String(decoding: obj.data, as: UTF8.self)
        XCTAssertEqual(objText.components(separatedBy: "\no ").count - 1, report.pieces.count)
        for piece in report.pieces {
            XCTAssertTrue(objText.contains(piece.name.lowercased().replacingOccurrences(of: " ", with: "-")))
        }

        let guideEntry = try XCTUnwrap(entries.first { $0.name == "assembly-guide.txt" })
        let guide = String(decoding: guideEntry.data, as: UTF8.self)
        for piece in report.pieces {
            XCTAssertTrue(guide.contains(piece.name))
            XCTAssertTrue(guide.contains(piece.color))
        }
        for seam in report.seamAdjacency { XCTAssertTrue(guide.contains(seam.seamID)) }
        XCTAssertTrue(guide.contains("Assembly steps:"))
        XCTAssertTrue(guide.contains("measured for undercuts at 0.4 mm grid"))
        XCTAssertTrue(guide.contains("material behavior, shrinkage, and mold construction are not simulated"))
    }

    func testHeadlessSplitPurposeRejectsUnknownFlagBeforePlanning() throws {
        let output = temporaryURL(extension: "zip")
        XCTAssertThrowsError(try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "partition",
            "--format", "stl",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
            "--partition-purpose", "split-by-undercuts",
            "--undercut-mystery", "1",
        ])) { error in
            guard case HeadlessExportError.unconsumedPartitionArguments(let arguments) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(arguments, ["--undercut-mystery", "1"])
        }
    }

    func testHeadlessPartitionWithoutPurposeKeepsFitPrinterExportPath() throws {
        let output = temporaryURL(extension: "obj")
        defer { try? FileManager.default.removeItem(at: output) }
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "partition",
            "--format", "obj",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
        ])

        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Refab Artist"))
        XCTAssertTrue(text.contains("\no "))
        XCTAssertTrue(text.contains("\nf "))
    }

    func testHeadlessSplitPurposeRunsPlannerWritesPackageReportAndFacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "refabartist-undercut-headless-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "cube-undercut-split.zip")
        let measurement = directory.appending(path: "undercut-report.json")

        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "partition",
            "--format", "stl",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl").path,
            "--output", output.path,
            "--measurement", measurement.path,
            "--partition-purpose", "split-by-undercuts",
            "--undercut-tolerance-mm", "2",
            "--undercut-quality", "quick",
            "--undercut-max-pieces", "1",
            "--undercut-pull", "z",
            "--undercut-priority", "fewer",
            "--undercut-seed", "42",
            "--undercut-output", "separate-stl-zip",
        ])

        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(2)), Array("PK".utf8))
        let report = try JSONDecoder().decode(
            UndercutSplitReport.self,
            from: Data(contentsOf: measurement)
        )
        XCTAssertEqual(report.overallStatus, .wholeModelWithinTolerance)
        XCTAssertEqual(report.pieces.count, 1)
        XCTAssertEqual(report.settings.seed, 42)
        XCTAssertEqual(report.settings.pullPolicy, .fixed)
        XCTAssertEqual(report.settings.output, .separateSTLZip)
        XCTAssertEqual(report.source.preflight.basis, .planTimeSource)
        XCTAssertEqual(report.source.preflight.manifoldValidated, false)
        let stdout = HeadlessExportCommand.undercutStdoutText(
            report: report,
            reportPath: measurement.path
        )
        XCTAssertTrue(stdout.contains("status=wholeModelWithinTolerance"))
        XCTAssertTrue(stdout.contains("pieces=1"))
        XCTAssertTrue(stdout.contains("measuredAtGridMM="))
        XCTAssertTrue(stdout.contains("pulls=Piece A="))
        XCTAssertTrue(stdout.contains("report=\(measurement.path)"))
    }

    func testHeadlessShallowBeadRunsThreeTolerancesThroughSamePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "refabartist-undercut-tolerance-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "shallow-bead.obj")
        try objData(try shallowBeadGeometry()).write(to: fixture, options: .atomic)

        var statuses: [UndercutSplitPlanStatus] = []
        for tolerance in [2.0, 1.0, 0.0] {
            let suffix = String(format: "%.0f", tolerance)
            let output = directory.appending(path: "shallow-bead-T\(suffix).zip")
            let reportURL = directory.appending(path: "shallow-bead-T\(suffix).json")
            try HeadlessExportCommand.run(arguments: [
                "--headless-export",
                "--mode", "partition",
                "--format", "stl",
                "--fixture", fixture.path,
                "--output", output.path,
                "--measurement", reportURL.path,
                "--partition-purpose", "split-by-undercuts",
                "--undercut-tolerance-mm", String(tolerance),
                "--undercut-quality", "quick",
                "--undercut-max-pieces", "1",
                "--undercut-pull", "z",
                "--undercut-priority", "fewer",
                "--undercut-seed", "7",
                "--undercut-output", "separate-stl-zip",
            ])
            let report = try JSONDecoder().decode(
                UndercutSplitReport.self,
                from: Data(contentsOf: reportURL)
            )
            XCTAssertEqual(report.settings.undercutToleranceMM, tolerance)
            XCTAssertNotNil(report.effectiveMeasurementResolutionMM)
            statuses.append(report.overallStatus)
        }

        XCTAssertEqual(statuses, [
            .wholeModelWithinTolerance,
            .splitExceedsTolerance,
            .splitExceedsTolerance,
        ])
    }

    func testHealedHandReportPreservesHonestNonzeroPreflightCounts() throws {
        let fixtureURL = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
        let model = try MeshInspector.inspect(url: fixtureURL)
        let attributed = try SourceFaceMap.attributedMesh(from: model.geometry)
        let root = PartitionRegionID.root(
            sourceGeometryFingerprint: attributed.sourceGeometryFingerprint
        )
        let plan = UndercutSplitPlan(
            status: .analysisError,
            cutTree: PartitionCutTree(rootRegionID: root, nodes: []),
            pieces: [UndercutSplitPiece(
                regionID: root,
                mesh: attributed,
                pullAxis: Vec3(x: 0, y: 0, z: 1),
                measurement: nil
            )],
            statusMessage: "Analysis failed before an undercut measurement was attached. Pieces can still be exported."
        )

        let report = UndercutSplitReport.make(
            plan: plan,
            settings: .defaultValue,
            sourceGeometry: model.geometry,
            appVersion: "test"
        )
        let facts = report.source.preflight
        XCTAssertEqual(facts.basis, .suppliedSourceAtExport)
        XCTAssertEqual(facts.sourceGeometryFingerprint, attributed.sourceGeometryFingerprint)
        XCTAssertEqual(facts.triangleCount, 16_158)
        XCTAssertEqual(facts.invalidTriangleReferenceCount, 0)
        XCTAssertEqual(facts.degenerateTriangleCount, 2)
        XCTAssertEqual(facts.boundaryEdgeCount, 0)
        XCTAssertEqual(facts.nonManifoldEdgeCount, 4)
        XCTAssertEqual(facts.uniqueVertexCount, model.preflight.uniqueVertexCount)
        XCTAssertEqual(
            facts.duplicateVertexObservationCount,
            model.preflight.duplicateVertexObservationCount
        )
        XCTAssertNil(facts.manifoldValidated)
        XCTAssertFalse(report.warnings.contains { $0.contains("fingerprint differs") })
    }

    func testInjectedStdoutSinkReceivesTheExactEmittedLine() throws {
        let fixture = try makeFixture()
        let report = UndercutSplitReport.make(
            plan: fixture.plan,
            settings: .defaultValue,
            sourceGeometry: fixture.sourceGeometry,
            output: .separateSTLZip,
            appVersion: "test"
        )
        var writes: [Data] = []
        let reportPath = "/tmp/undercut-report.json"
        HeadlessExportCommand.writeUndercutStdout(
            report: report,
            reportPath: reportPath,
            sink: { writes.append($0) }
        )

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(
            String(decoding: writes[0], as: UTF8.self),
            HeadlessExportCommand.undercutStdoutText(
                report: report,
                reportPath: reportPath
            ) + "\n"
        )
    }

    func testSavedProjectReopensAndRegeneratesIdenticalReportFacts() async throws {
        let geometry = try ManifoldEngine.toMesh(try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 5, y: 5, z: 5),
            extents: Vec3(x: 10, y: 10, z: 10)
        )))
        var split = UndercutSplitSettings.defaultValue
        split.quality = .quick
        split.maxPieces = 1
        split.pullPolicy = .fixed
        split.fixedPullDirection = Vec3(x: 0, y: 0, z: 1)
        split.seed = 42
        var partition = PartitionSettings.defaultValue
        partition.purpose = .splitByUndercuts
        partition.undercutSplit = split
        let saved = SlicerProjectDocument(
            modelPath: "/fixtures/cube.stl",
            settings: projectSettings(partition: partition)
        )

        let firstPlan = try await UndercutSplitPlanner.plan(
            geometry: geometry,
            settings: split
        )
        let reopened = try JSONDecoder().decode(
            SlicerProjectDocument.self,
            from: JSONEncoder().encode(saved)
        )
        let reopenedPartition = try XCTUnwrap(reopened.settings.partitionSettings)
        XCTAssertEqual(reopenedPartition.purpose, .splitByUndercuts)
        let reopenedSplit = try XCTUnwrap(reopenedPartition.undercutSplit)
        let regeneratedPlan = try await UndercutSplitPlanner.plan(
            geometry: geometry,
            settings: reopenedSplit
        )

        let firstReport = UndercutSplitReport.make(
            plan: firstPlan,
            settings: split,
            sourceGeometry: geometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )
        let regeneratedReport = UndercutSplitReport.make(
            plan: regeneratedPlan,
            settings: reopenedSplit,
            sourceGeometry: geometry,
            output: .namedObjectOBJZip,
            appVersion: "test"
        )
        XCTAssertEqual(firstPlan.cutTree, regeneratedPlan.cutTree)
        XCTAssertEqual(
            firstReport.pieces.map { "\($0.id):\($0.meshHash)" },
            regeneratedReport.pieces.map { "\($0.id):\($0.meshHash)" }
        )
        XCTAssertEqual(try firstReport.encodedJSON(), try regeneratedReport.encodedJSON())
    }

    private struct Fixture {
        var plan: UndercutSplitPlan
        var sourceGeometry: MeshGeometryData
        var sourceFingerprint: String
        var root: PartitionRegionID
    }

    private func makeFixture() throws -> Fixture {
        let negativeTriangle = AttributedTriangle(
            a: Vec3(x: -1, y: 0, z: 0),
            b: Vec3(x: -1, y: 1, z: 0),
            c: Vec3(x: -1, y: 0, z: 1),
            provenance: .source(SourceFaceID(rawValue: 0))
        )
        let positiveTriangle = AttributedTriangle(
            a: Vec3(x: 1, y: 0, z: 0),
            b: Vec3(x: 1, y: 0, z: 1),
            c: Vec3(x: 1, y: 1, z: 0),
            provenance: .source(SourceFaceID(rawValue: 1))
        )
        let sourceGeometry = MeshGeometryData(
            vertices: [
                negativeTriangle.a, negativeTriangle.b, negativeTriangle.c,
                positiveTriangle.a, positiveTriangle.b, positiveTriangle.c,
            ],
            triangleIndices: [0, 1, 2, 3, 4, 5]
        )
        let sourceFingerprint = SourceFaceMap.geometryFingerprint(of: sourceGeometry)
        let root = PartitionRegionID.root(sourceGeometryFingerprint: sourceFingerprint)
        let plane = try XCTUnwrap(CanonicalPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0
        ))
        let node = PartitionCutNode.automatic(
            plannerVersion: 1,
            targetRegionID: root,
            plane: plane,
            siblingOrdinal: 0,
            isLocked: false
        )
        let negativeMesh = AttributedMesh(
            triangles: [negativeTriangle],
            sourceGeometryFingerprint: sourceFingerprint,
            sourceReferencedVertices: [],
            omittedDegenerateSourceFaceIDs: []
        )
        let positiveMesh = AttributedMesh(
            triangles: [positiveTriangle],
            sourceGeometryFingerprint: sourceFingerprint,
            sourceReferencedVertices: [],
            omittedDegenerateSourceFaceIDs: []
        )
        let regions = [
            UndercutRegionClusterer.Region(
                id: "measured",
                faceIDs: [0],
                areaMM2: 5,
                depthMM: 3,
                centroid: Vec3(x: -1, y: 0.3, z: 0.3),
                suggestedEscapeDirections: [Vec3(x: 1, y: 0, z: 0)]
            ),
            UndercutRegionClusterer.Region(
                id: "filtered",
                faceIDs: [0],
                areaMM2: 2,
                depthMM: 9,
                centroid: Vec3(x: -1, y: 0.4, z: 0.4),
                suggestedEscapeDirections: [Vec3(x: 1, y: 0, z: 0)]
            ),
        ]
        let negativeMeasurement = measurement(
            axis: Vec3(x: 1, y: 0, z: 0),
            regions: regions
        )
        let positiveMeasurement = measurement(
            axis: Vec3(x: 0, y: 0, z: 1),
            regions: []
        )
        let plan = UndercutSplitPlan(
            status: .splitExceedsTolerance,
            cutTree: PartitionCutTree(rootRegionID: root, nodes: [node]),
            pieces: [
                UndercutSplitPiece(
                    regionID: node.negativeChildID,
                    mesh: negativeMesh,
                    pullAxis: negativeMeasurement.pullAxis,
                    measurement: negativeMeasurement,
                    draftAdvisoryAreaMM2: 1.25
                ),
                UndercutSplitPiece(
                    regionID: node.positiveChildID,
                    mesh: positiveMesh,
                    pullAxis: positiveMeasurement.pullAxis,
                    measurement: positiveMeasurement,
                    draftAdvisoryAreaMM2: 0
                ),
            ],
            statusMessage: "Piece A has measured undercut regions deeper than the 2 mm tolerance (measured at 0.4 mm grid). The pieces can still be exported.",
            warnings: ["A measured advisory from the inspector."],
            fullResolutionFinalized: true,
            conservation: UndercutSplitConservation(
                missingVolumeMM3: 0,
                excessVolumeMM3: 0,
                pairwiseOverlapVolumeMM3: 0,
                toleranceMM3: 0.001
            ),
            deterministicFingerprint: "export-plan"
        )
        return Fixture(
            plan: plan,
            sourceGeometry: sourceGeometry,
            sourceFingerprint: sourceFingerprint,
            root: root
        )
    }

    private func measurement(
        axis: Vec3,
        regions: [UndercutRegionClusterer.Region]
    ) -> DirectionalAccessibilityAnalyzer.Result {
        DirectionalAccessibilityAnalyzer.Result(
            pullAxis: axis,
            regions: regions,
            baseResolutionMM: 0.4,
            effectiveResolutionMM: 0.4,
            sampleCount: 10,
            maximumSamples: 100,
            violatingColumnCount: regions.count,
            sampleBudgetExhausted: false,
            discardedDegenerateTriangleCount: 0,
            nearVerticalWallAreaMM2: 0
        )
    }

    private func shallowBeadGeometry() throws -> MeshGeometryData {
        let solid = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 5, y: 5, z: 5),
            extents: Vec3(x: 10, y: 10, z: 10)
        ))
        let cutter = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 5, y: 3.25, z: 2.75),
            extents: Vec3(x: 5, y: 8.5, z: 2.5)
        ))
        return try ManifoldEngine.toMesh(try ManifoldEngine.difference(solid, cutter))
    }

    private func objData(_ geometry: MeshGeometryData) -> Data {
        var text = "# shallow bead fixture\n"
        for vertex in geometry.vertices {
            text += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
        }
        var cursor = 0
        while cursor + 2 < geometry.triangleIndices.count {
            text += "f \(geometry.triangleIndices[cursor] + 1) "
                + "\(geometry.triangleIndices[cursor + 1] + 1) "
                + "\(geometry.triangleIndices[cursor + 2] + 1)\n"
            cursor += 3
        }
        return Data(text.utf8)
    }

    private func projectSettings(partition: PartitionSettings) -> SlicerProjectSettings {
        SlicerProjectSettings(
            constructionMode: .partition,
            sliceAxis: .z,
            secondarySliceAxis: .x,
            materialThickness: 3,
            slotClearance: 0.15,
            slotAngleDegrees: 0,
            radialSliceCount: 12,
            curveSliceCount: 8,
            curveAmplitude: 4,
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
            partitionSettings: partition
        )
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "refabartist-undercut-export-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
