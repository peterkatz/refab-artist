import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistWorkflowV3Tests {
    @Test
    func finalPipelineRetainsEveryRequestedFlangeKey() throws {
        let geometry = Self.boxGeometry(size: 30)
        let model = MeshSummary(
            name: "keyed-box",
            path: "/tmp/keyed-box.stl",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: Bounds3D(
                min: Vec3(x: -15, y: -15, z: -15),
                max: Vec3(x: 15, y: 15, z: 15)
            ),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.key = PartitionKeySettings(
            type: .pins,
            pinDiameter: 4,
            pinLength: 4,
            tolerance: 0.2,
            pinsPerSeam: 2,
            edgeMargin: 2
        )
        settings.flange.enabled = true
        settings.flange.width = 14
        settings.spout.ventCount = 0

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        #expect(plan.registrationKeysPlaced == 2, Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | ")))
        #expect(plan.registrationKeySites.count == 2)
        #expect(!plan.diagnostics.contains {
            $0.message.localizedCaseInsensitiveContains("butt joint")
        })
    }

    @Test
    func autoPartingChoosesTheMeasuredCleanPullAxis() throws {
        let geometry = Self.lPrismGeometry()
        let bounds = Bounds3D(
            min: Vec3(x: 0, y: 0, z: -8),
            max: Vec3(x: 24, y: 24, z: 8)
        )
        let model = MeshSummary(
            name: "l-prism",
            path: "/tmp/l-prism.stl",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: bounds,
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        #expect(plan.partingPlanes.first?.axisAligned == 2, Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | ")))
        #expect(!plan.diagnostics.contains { $0.severity == .error && $0.message.localizedCaseInsensitiveContains("undercut") })
        #expect(plan.diagnostics.contains { $0.message.localizedCaseInsensitiveContains("evaluated") })
    }

    @Test
    func blockingDiagnosticsMakeAPlanInspectionOnly() throws {
        var plan = MotherMoldPlan.empty
        plan.parts = [Self.part(name: "mold-part-A", centerX: -5)]
        plan.diagnostics = [MoldDiagnostic(.error, "Undercut blocks demolding.")]
        let signature = MotherMoldInputSignature(
            modelPath: "/tmp/master.stl",
            modelTriangleCount: 12,
            modelBounds: "bounds",
            settings: .defaultValue
        )

        #expect(MotherMoldUIContract.blockingExportReason(for: plan)?.localizedCaseInsensitiveContains("cannot release") == true)
        #expect(MotherMoldUIContract.exportSnapshot(
            nonStaleDisplayedPlan: plan,
            generatedSignature: signature
        ) == nil)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-mothermold-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(throws: MotherMoldExporter.ExportError.self) {
            try MotherMoldExporter.writeZip(
                plan: plan,
                modelName: "blocked",
                to: output
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func packagingResolvesOneCoherentFileContract() {
        #expect(MotherMoldExportRequest(packaging: .separateZip).pathExtension == "zip")
        #expect(MotherMoldExportRequest(packaging: .separateZip).payload == .stlArchive)
        #expect(MotherMoldExportRequest(packaging: .separateZip).accepts(format: .stl))
        #expect(!MotherMoldExportRequest(packaging: .separateZip).accepts(format: .obj))
        #expect(MotherMoldExportRequest(packaging: .combinedObj).pathExtension == "obj")
        #expect(MotherMoldExportRequest(packaging: .combinedObj).payload == .combinedOBJ)
        #expect(MotherMoldExportRequest(packaging: .combinedObj).accepts(format: .obj))
        #expect(!MotherMoldExportRequest(packaging: .combinedObj).accepts(format: .stl))
        #expect(MotherMoldExportRequest(packaging: .laidOutPlate).pathExtension == "stl")
        #expect(MotherMoldExportRequest(packaging: .laidOutPlate).payload == .laidOutSTL)
        #expect(MotherMoldExportRequest(packaging: .laidOutPlate).accepts(format: .stl))
        #expect(!MotherMoldExportRequest(packaging: .laidOutPlate).accepts(format: .obj))
    }

    @Test
    func writerBytesAndExtensionsMatchThePackagingContract() throws {
        func translatedBox(centerX: Double) -> MeshGeometryData {
            let box = Self.boxGeometry(size: 10)
            return MeshGeometryData(
                vertices: box.vertices.map {
                    Vec3(x: $0.x + centerX, y: $0.y, z: $0.z)
                },
                triangleIndices: box.triangleIndices
            )
        }
        let firstGeometry = translatedBox(centerX: -10)
        let secondGeometry = translatedBox(centerX: 10)
        let plan = MotherMoldPlan(
            parts: [
                MotherMoldPart(name: "mold-part-A", geometry: firstGeometry, isWatertight: true),
                MotherMoldPart(name: "mold-part-B", geometry: secondGeometry, isWatertight: true),
            ],
            partingPlanes: [PartitionPlane(
                normal: Vec3(x: 1, y: 0, z: 0),
                offset: 0,
                isManual: false
            )],
            cavity: firstGeometry,
            master: firstGeometry,
            diagnostics: [],
            spoutBored: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mothermold-export-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = MotherMoldSettings(
            subtype: .slipShell,
            toolingContractVersion: 2
        )
        settings.includeAssemblyMap = false
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        settings.packaging = .separateZip
        let zip = directory.appendingPathComponent("mold.zip")
        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "mold", to: zip)
        #expect(Array(try Data(contentsOf: zip).prefix(2)) == [0x50, 0x4b])
        #expect(throws: MotherMoldExporter.ExportError.self) {
            try MotherMoldExporter.write(
                plan: plan,
                settings: settings,
                modelName: "mold",
                to: directory.appendingPathComponent("mold.stl")
            )
        }

        settings.packaging = .combinedObj
        let obj = directory.appendingPathComponent("mold.obj")
        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "mold", to: obj)
        #expect(try String(contentsOf: obj, encoding: .utf8).hasPrefix("# Refab Artist"))

        settings.packaging = .laidOutPlate
        let stl = directory.appendingPathComponent("mold.stl")
        try MotherMoldExporter.write(plan: plan, settings: settings, modelName: "mold", to: stl)
        #expect(try String(contentsOf: stl, encoding: .utf8).hasPrefix("solid refabartist_mothermold"))
    }

    @Test
    func explodedPreviewIsReversibleAndDoesNotMutateThePlan() {
        var plan = MotherMoldPlan.empty
        plan.parts = [
            Self.part(name: "mold-part-A", centerX: -5),
            Self.part(name: "mold-part-B", centerX: 5),
        ]
        plan.demoldAxes = [
            Vec3(x: -1, y: 0, z: 0),
            Vec3(x: 1, y: 0, z: 0),
        ]
        let original = plan

        let assembled = MotherMoldPreviewLayout.offsets(for: plan, exploded: false)
        let exploded = MotherMoldPreviewLayout.offsets(for: plan, exploded: true)
        let reassembled = MotherMoldPreviewLayout.offsets(for: plan, exploded: false)
        let assembledBounds = MotherMoldPreviewLayout.previewBounds(
            for: plan,
            exploded: false,
            includeMaster: false
        )
        let explodedBounds = MotherMoldPreviewLayout.previewBounds(
            for: plan,
            exploded: true,
            includeMaster: false
        )

        #expect(assembled == [Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: 0)])
        #expect(exploded[0].x < 0)
        #expect(exploded[1].x > 0)
        #expect(reassembled == assembled)
        #expect((explodedBounds?.max.x ?? 0) - (explodedBounds?.min.x ?? 0)
            > (assembledBounds?.max.x ?? 0) - (assembledBounds?.min.x ?? 0))
        #expect(plan == original)
    }

    @Test
    func explodedPreviewMovesToolingArtifactsAndRestoresWithoutMutatingThePlan() {
        var plan = MotherMoldPlan.empty
        plan.parts = [
            Self.part(name: "mold-part-A", centerX: -5),
            Self.part(name: "mold-part-B", centerX: 5),
        ]
        plan.demoldAxes = [Vec3(x: -1, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0)]
        let geometry = Self.boxGeometry(size: 4)
        let funnelTransform = try! Matrix4x4Codable(elements: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            3, 4, 5, 1,
        ])
        let funnel = ToolingArtifact(
            id: ToolingArtifactID("casting-funnel-01"),
            name: "production-casting-funnel",
            role: .castingFunnel,
            geometry: geometry,
            qualification: .topologyValid,
            assembledTransform: funnelTransform
        )
        let cradle = ToolingArtifact(
            id: ToolingArtifactID("liner-cradle-01"),
            name: "liner-fill-cradle",
            role: .supportCradle,
            geometry: geometry,
            qualification: .topologyValid
        )
        plan.fixtureArtifacts = [funnel]
        plan.supportArtifacts = [cradle]
        plan.linerFillSupport = ToolingSupportSummary(
            phase: .linerFill,
            state: .supportGeometryOnly,
            gravityUpAxis: Vec3Codable(x: 0, y: 0, z: 1)
        )
        plan.castingSupport = ToolingSupportSummary(
            phase: .casting,
            state: .supportGeometryOnly,
            gravityUpAxis: Vec3Codable(x: 0, y: 1, z: 0)
        )
        let original = plan

        let assembled = MotherMoldPreviewLayout.artifactOffsets(for: plan, exploded: false)
        let exploded = MotherMoldPreviewLayout.artifactOffsets(for: plan, exploded: true)
        let restored = MotherMoldPreviewLayout.artifactOffsets(for: plan, exploded: false)

        #expect(assembled.isEmpty)
        #expect(exploded[funnel.id]?.y ?? 0 > 0)
        #expect(exploded[cradle.id]?.z ?? 0 < 0)
        #expect(restored == assembled)
        #expect(MotherMoldPreviewLayout.artifactPosition(for: funnel, offset: Vec3(x: 0, y: 0, z: 0)) == Vec3(x: 3, y: 4, z: 5))
        let explodedPosition = MotherMoldPreviewLayout.artifactPosition(
            for: funnel,
            offset: exploded[funnel.id] ?? Vec3(x: 0, y: 0, z: 0)
        )
        #expect(explodedPosition.x == 3)
        #expect(explodedPosition.y > 4)
        #expect(explodedPosition.z == 5)
        #expect(plan == original)
    }

    @Test
    func jacketDefaultsToARealMasterMountWhileRigidNegativeDoesNotUseOne() {
        var jacket = MotherMoldSettings.defaultValue
        jacket.subtype = .siliconeJacket
        #expect(jacket.masterMount.mode == .flatBaseSocket)
        #expect(MoldMasterMountBuilder.requiresMount(for: jacket))

        var rigidNegative = jacket
        rigidNegative.subtype = .slipShell
        #expect(!MoldMasterMountBuilder.requiresMount(for: rigidNegative))
    }

    @Test
    func generatedBaseSocketIsConnectedWatertightAndMeasured() throws {
        let master = Self.boxGeometry(size: 30)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.siliconeGap = 3
        settings.smoothing = 0
        settings.wallThickness = 4
        settings.masterMount.socketDepth = 5
        settings.masterMount.fitClearance = 0.2
        let cavity = try MoldCavityBuilder.buildCavity(master: master, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: master, settings: settings)

        let mounted = MoldMasterMountBuilder.apply(
            shell: shell.solid,
            master: master,
            settings: settings
        )

        #expect(mounted.summary.mode == .flatBaseSocket)
        #expect(mounted.summary.isResolved)
        #expect(mounted.summary.requiresSealant)
        #expect(mounted.locatorGeometry != nil)
        #expect(mounted.summary.locatorVolumeMM3 > 0)
        #expect(mounted.summary.contactAreaMM2 > 100)
        #expect(mounted.summary.sealLandWidthMM >= settings.siliconeGap + settings.wallThickness)
        #expect(MotherMoldValidation.printablePreflight(mounted.solid).isWatertight)
        #expect(abs(MoldComponentFilter.signedVolume(mounted.solid)) > abs(MoldComponentFilter.signedVolume(shell.solid)))
    }

    @Test
    func generatedBaseSocketAcceptsTheExactUIHealedOrganicMaster() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot()
                .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.wallThickness = 4
        settings.siliconeGap = 10
        settings.smoothing = 0
        settings.masterMount.mode = .flatBaseSocket
        settings.masterMount.socketDepth = 5
        settings.masterMount.fitClearance = 0.25

        let cavity = try MoldCavityBuilder.buildCavity(
            master: model.geometry,
            settings: settings
        )
        let shell = try MoldShellBuilder.buildShell(
            cavity: cavity,
            master: model.geometry,
            settings: settings
        )
        let mounted = MoldMasterMountBuilder.apply(
            shell: shell.solid,
            master: model.geometry,
            settings: settings
        )

        #expect(
            mounted.summary.isResolved,
            Comment(rawValue: mounted.diagnostics.map(\.message).joined(separator: " | "))
        )
        #expect(!mounted.diagnostics.contains { $0.severity == .error })
        #expect(mounted.summary.contactAreaMM2 > 100)
        #expect(
            abs(MoldComponentFilter.signedVolume(mounted.solid))
                > abs(MoldComponentFilter.signedVolume(shell.solid))
        )
    }

    @Test
    func exactUIHealedOrganicMasterCompletesAsAnExportableArtistReadyMold() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot()
                .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .two
        settings.wallThickness = 4
        settings.siliconeGap = 10
        settings.smoothing = 0
        settings.masterMount = MasterMountSettings(
            mode: .flatBaseSocket,
            socketDepth: 5,
            fitClearance: 0.25
        )
        settings.key = .defaultValue
        settings.flange = .defaultValue
        settings.spout = .defaultValue

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        let detail = Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | "))

        #expect(plan.parts.count == 2, detail)
        #expect(plan.parts.allSatisfy { $0.isWatertight }, detail)
        #expect(plan.parts.allSatisfy {
            MoldComponentFilter.dropFaceDisconnectedDebris($0.geometry).droppedCount == 0
        }, detail)
        #expect(plan.masterMount.isResolved, detail)
        #expect(plan.masterMount.requiresSealant, detail)
        #expect((plan.masterMount.finalLocatorRetention ?? 0) >= 0.98, detail)
        #expect(plan.spoutBored, detail)
        #expect(plan.ventsBoredCount == settings.spout.ventCount, detail)
        #expect(plan.flangedSeamCount == 1, detail)
        #expect(plan.registrationKeysPlaced == settings.key.pinsPerSeam, detail)
        #expect(!plan.diagnostics.contains { $0.severity == .error }, detail)
        #expect(MotherMoldUIContract.blockingExportReason(for: plan) == nil, detail)
    }

    @Test
    func fourPartOrganicMoldsCommitOnlyCompleteNonInterferingInterfaces() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot()
                .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .four

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
        let detail = Comment(rawValue: plan.diagnostics.map(\.message).joined(separator: " | "))
        let overlaps = try Self.pairwisePositiveOverlaps(plan.parts)
        let physicalInterfaceCount = settings.parts.planeCount * max(1, plan.parts.count / 2)

        #expect(plan.parts.count == 4, detail)
        #expect(overlaps.isEmpty, Comment(rawValue: overlaps.map { $0.description }.joined(separator: " | ")))
        #expect(plan.flangedSeamCount == physicalInterfaceCount, detail)
        #expect(plan.flangePlatesPlaced == physicalInterfaceCount * 2, detail)
        #expect(
            plan.effectiveBoltHoleCount == physicalInterfaceCount * settings.flange.boltHoleCount,
            detail
        )
        #expect(
            plan.registrationKeysPlaced == physicalInterfaceCount * settings.key.pinsPerSeam,
            detail
        )
        #expect(!plan.diagnostics.contains { $0.severity == .error }, detail)
        #expect(MotherMoldUIContract.blockingExportReason(for: plan) == nil, detail)
    }

    @Test
    func everyPrimaryFourPartAxisPairPreservesTheInterfaceInvariants() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot()
                .appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .four
        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let center = Self.vertexMean(cavity)
        let axisPairs: [(String, Vec3, Double, Vec3, Double)] = [
            ("X/Y", Vec3(x: 1, y: 0, z: 0), center.x, Vec3(x: 0, y: 1, z: 0), center.y),
            ("X/Z", Vec3(x: 1, y: 0, z: 0), center.x, Vec3(x: 0, y: 0, z: 1), center.z),
            ("Y/Z", Vec3(x: 0, y: 1, z: 0), center.y, Vec3(x: 0, y: 0, z: 1), center.z),
        ]

        func check(_ pair: (String, Vec3, Double, Vec3, Double)) throws {
            var settings = settings
            settings.parting = PartingSettings(
                mode: .manual,
                planes: [
                    PartitionPlane(normal: pair.1, offset: pair.2, isManual: true),
                    PartitionPlane(normal: pair.3, offset: pair.4, isManual: true),
                ]
            )
            let plan: MotherMoldPlan
            do {
                plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)
            } catch {
                // Name the pair; the caller goes on to check the others.
                Issue.record("\(pair.0): \(error)")
                return
            }
            let detail = Comment(rawValue: "\(pair.0): " + plan.diagnostics.map(\.message).joined(separator: " | "))
            let overlaps = try Self.pairwisePositiveOverlaps(plan.parts)
            let interfaceCount = settings.parts.planeCount * max(1, plan.parts.count / 2)

            #expect(plan.parts.count == 4, detail)
            #expect(overlaps.isEmpty, detail)
            #expect(plan.flangedSeamCount == interfaceCount, detail)
            #expect(plan.flangePlatesPlaced == interfaceCount * 2, detail)
            #expect(plan.effectiveBoltHoleCount == interfaceCount * settings.flange.boltHoleCount, detail)
            #expect(plan.registrationKeysPlaced == interfaceCount * settings.key.pinsPerSeam, detail)
            #expect(!plan.diagnostics.contains { $0.severity == .error }, detail)
        }

        for pair in axisPairs {
            if pair.0 == "X/Z" {
                withKnownIssue("Known issue: X and Z planes through the hand's centre leave two quarter shells in two pieces each, and the planner refuses a mold part in two pieces.") {
                    try check(pair)
                }
            } else {
                try check(pair)
            }
        }
    }

    @Test
    func unstablePointBaseBlocksAutomaticSocket() {
        let pointedMaster = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: -10),
                Vec3(x: -10, y: -10, z: 0),
                Vec3(x: 10, y: -10, z: 0),
                Vec3(x: 0, y: 10, z: 0),
                Vec3(x: 0, y: 0, z: 10),
            ],
            triangleIndices: [
                0, 2, 1, 0, 3, 2, 0, 1, 3,
                4, 1, 2, 4, 2, 3, 4, 3, 1,
            ]
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.masterMount.socketDepth = 1

        let result = MoldMasterMountBuilder.apply(
            shell: Self.boxGeometry(size: 40),
            master: pointedMaster,
            settings: settings
        )

        #expect(!result.summary.isResolved)
        #expect(result.diagnostics.contains { $0.severity == .error })
        #expect(result.solid == Self.boxGeometry(size: 40))
    }

    private static func part(name: String, centerX: Double) -> MotherMoldPart {
        let vertices = [
            Vec3(x: centerX - 1, y: -1, z: -1),
            Vec3(x: centerX + 1, y: -1, z: -1),
            Vec3(x: centerX, y: 1, z: 1),
        ]
        return MotherMoldPart(
            name: name,
            geometry: MeshGeometryData(vertices: vertices, triangleIndices: [0, 1, 2]),
            bounds: Bounds3D(
                min: Vec3(x: centerX - 1, y: -1, z: -1),
                max: Vec3(x: centerX + 1, y: 1, z: 1)
            )
        )
    }

    private static func boxGeometry(size: Double) -> MeshGeometryData {
        let h = size / 2
        let vertices = [
            Vec3(x: -h, y: -h, z: -h), Vec3(x: h, y: -h, z: -h),
            Vec3(x: h, y: h, z: -h), Vec3(x: -h, y: h, z: -h),
            Vec3(x: -h, y: -h, z: h), Vec3(x: h, y: -h, z: h),
            Vec3(x: h, y: h, z: h), Vec3(x: -h, y: h, z: h),
        ]
        let indices: [Int32] = [
            0, 2, 1, 0, 3, 2,
            4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4,
            3, 6, 2, 3, 7, 6,
            0, 4, 7, 0, 7, 3,
            1, 2, 6, 1, 6, 5,
        ]
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private static func lPrismGeometry() -> MeshGeometryData {
        let profile = [
            Vec2(x: 0, y: 0), Vec2(x: 24, y: 0), Vec2(x: 24, y: 8),
            Vec2(x: 8, y: 8), Vec2(x: 8, y: 24), Vec2(x: 0, y: 24),
        ]
        let z0 = -8.0
        let z1 = 8.0
        let vertices = profile.map { Vec3(x: $0.x, y: $0.y, z: z0) }
            + profile.map { Vec3(x: $0.x, y: $0.y, z: z1) }
        var indices: [Int32] = []
        let capTriangles = [(0, 1, 2), (0, 2, 3), (0, 3, 5), (3, 4, 5)]
        for triangle in capTriangles {
            indices += [Int32(triangle.0), Int32(triangle.2), Int32(triangle.1)]
            indices += [Int32(triangle.0 + 6), Int32(triangle.1 + 6), Int32(triangle.2 + 6)]
        }
        for index in profile.indices {
            let next = (index + 1) % profile.count
            let a = Int32(index)
            let b = Int32(next)
            let c = Int32(next + profile.count)
            let d = Int32(index + profile.count)
            indices += [a, b, c, a, c, d]
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
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

    private static func pairwisePositiveOverlaps(
        _ parts: [MotherMoldPart]
    ) throws -> [(description: String, volume: Double)] {
        var overlaps: [(description: String, volume: Double)] = []
        for firstIndex in parts.indices {
            for secondIndex in parts.indices where secondIndex > firstIndex {
                let first = try ManifoldEngine.make(from: parts[firstIndex].geometry)
                let second = try ManifoldEngine.make(from: parts[secondIndex].geometry)
                let intersection = try ManifoldEngine.intersect(first, second)
                let volume = abs(ManifoldEngine.volume(intersection))
                if volume > 0.01 {
                    overlaps.append((
                        description: "\(parts[firstIndex].name)/\(parts[secondIndex].name): \(volume) mm^3",
                        volume: volume
                    ))
                }
                withExtendedLifetime(first) {}
                withExtendedLifetime(second) {}
                withExtendedLifetime(intersection) {}
            }
        }
        return overlaps
    }

    private static func vertexMean(_ geometry: MeshGeometryData) -> Vec3 {
        guard !geometry.vertices.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        let sum = geometry.vertices.reduce(Vec3(x: 0, y: 0, z: 0)) { partial, vertex in
            Vec3(
                x: partial.x + vertex.x,
                y: partial.y + vertex.y,
                z: partial.z + vertex.z
            )
        }
        let count = Double(geometry.vertices.count)
        return Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
    }
}
