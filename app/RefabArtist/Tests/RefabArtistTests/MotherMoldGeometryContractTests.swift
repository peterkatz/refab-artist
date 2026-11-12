import XCTest
@testable import RefabArtist

final class MotherMoldGeometryContractTests: XCTestCase {
    func testRigidDemoldToleranceDoesNotIgnoreVisibleBackdraft() {
        XCTAssertEqual(
            MoldUndercutAnalyzer.backdraftDotTolerance,
            sin(0.5 * Double.pi / 180),
            accuracy: 1.0e-9
        )
        XCTAssertLessThan(
            MoldUndercutAnalyzer.backdraftDotTolerance,
            sin(1.0 * Double.pi / 180),
            "A full degree of backdraft must not be treated as a vertical wall."
        )
    }

    func testRigidDemoldSweepMeasuresActualCollisionAlongPullAxis() throws {
        let cavityHandle = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 2, y: 2, z: 2)
        ))
        let cavity = try ManifoldEngine.toMesh(cavityHandle)
        let trapped = try boxPart(name: "trapped", centerX: -2.5)
        let clear = try boxPart(name: "clear", centerX: 2.5)

        XCTAssertNotNil(MoldUndercutAnalyzer.firstExtractionCollision(
            part: trapped,
            cavity: cavity,
            axis: Vec3(x: 1, y: 0, z: 0)
        ))
        XCTAssertNil(MoldUndercutAnalyzer.firstExtractionCollision(
            part: clear,
            cavity: cavity,
            axis: Vec3(x: 1, y: 0, z: 0)
        ))
        withExtendedLifetime(cavityHandle) {}
    }

    func testRigidEmptyCavityBlocksDemoldVerification() throws {
        let part = try boxPart(name: "rigid-part", centerX: 0)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell

        let result = MoldUndercutAnalyzer.analyze(
            parts: [part],
            demoldAxes: [Vec3(x: 1, y: 0, z: 0)],
            cavity: MeshGeometryData(vertices: [], triangleIndices: []),
            settings: settings
        )

        XCTAssertFalse(try XCTUnwrap(result.reports.first).isDemoldable)
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .error })
    }

    func testMeshSealerDoesNotCapARealOneMillimeterOpening() throws {
        let closed = try boxPart(name: "open-box", centerX: 0).geometry
        let top = closed.vertices.map(\.z).max() ?? 0
        var openIndices: [Int32] = []
        for start in stride(from: 0, to: closed.triangleIndices.count - 2, by: 3) {
            let triangle = Array(closed.triangleIndices[start...(start + 2)])
            let isTop = triangle.allSatisfy { abs(closed.vertices[Int($0)].z - top) < 1.0e-9 }
            if !isTop { openIndices.append(contentsOf: triangle) }
        }
        let open = MeshGeometryData(vertices: closed.vertices, triangleIndices: openIndices)
        XCTAssertGreaterThan(MeshPreflight.analyze(geometry: open).boundaryEdgeCount, 0)

        let attempted = MoldMeshSealer.seal(open)

        XCTAssertGreaterThan(
            MeshPreflight.analyze(geometry: attempted).boundaryEdgeCount,
            0,
            "The stitch-crack repair path must not invent a face across a real artistic opening."
        )
    }

    func testFinalRepairCannotSimplifyAcrossDefaultKeyClearance() {
        XCTAssertLessThan(
            MotherMoldValidation.maximumRepairSimplificationMM,
            PartitionKeySettings.defaultValue.tolerance
        )
    }

    func testMeshSealerStillClosesAMicroscopicPlanarStitchCrack() {
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 0.2, y: 0, z: 0),
                Vec3(x: 0, y: 0.2, z: 0),
                Vec3(x: 0.05, y: 0.05, z: 1),
            ],
            triangleIndices: [
                0, 1, 3,
                1, 2, 3,
                2, 0, 3,
            ]
        )
        XCTAssertGreaterThan(MeshPreflight.analyze(geometry: geometry).boundaryEdgeCount, 0)
        XCTAssertTrue(MeshPreflight.analyze(geometry: MoldMeshSealer.seal(geometry)).isWatertight)
    }

    func testRigidShellPreservesTheCompleteMasterInsteadOfCuttingAnApertureThroughIt() throws {
        let master = sphere(radius: 10, longitudeSegments: 64, latitudeSegments: 32)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell

        let shell = try MoldShellBuilder.buildShell(
            cavity: master,
            master: master,
            settings: settings
        )
        let shellTop = try XCTUnwrap(shell.solid.vertices.map(\.z).max())
        XCTAssertEqual(shell.openPlane.offset, 10, accuracy: 0.05)
        XCTAssertGreaterThan(
            shellTop,
            10 + settings.wallThickness * 0.5,
            "The rigid shell must surround the entire intended cavity; a pour opening may not truncate the cast."
        )
        XCTAssertFalse(shell.diagnostics.contains {
            $0.message.localizedCaseInsensitiveContains("aperture")
        })
    }

    func testSmallRigidMasterIsNotRejectedForLackingAFlatTwelveMillimeterOpening() throws {
        let master = sphere(radius: 5, longitudeSegments: 32, latitudeSegments: 16)
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell

        let shell = try MoldShellBuilder.buildShell(
            cavity: master,
            master: master,
            settings: settings
        )

        XCTAssertGreaterThan(try XCTUnwrap(shell.solid.vertices.map(\.z).max()), 5)
        XCTAssertFalse(shell.diagnostics.contains {
            $0.message.localizedCaseInsensitiveContains("aperture")
        })
    }

    func testConvexSphereHalvesAreNotReportedAsUndercut() throws {
        let geometry = sphere(radius: 5, longitudeSegments: 32, latitudeSegments: 16)
        let model = summary(geometry, name: "convex-sphere")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        XCTAssertEqual(
            try XCTUnwrap(plan.partingPlanes.first).offset,
            0,
            accuracy: 0.05,
            "The open shell's shifted vertex centroid must not move a convex master's center split."
        )
        XCTAssertFalse(
            plan.diagnostics.contains {
                $0.severity == .error && $0.message.localizedCaseInsensitiveContains("undercut")
            },
            "A convex sphere split through its center is demoldable; analyzing the opposite hemisphere for each part creates false errors. Planes: \(plan.partingPlanes); parts: \(plan.parts.map { ($0.name, $0.bounds as Any) }); diagnostics: \(plan.diagnostics.map(\.message))"
        )
    }

    func testRequestedPartCountDoesNotFallBackToWholeShell() throws {
        let geometry = sphere(radius: 10, longitudeSegments: 32, latitudeSegments: 16)
        let model = summary(geometry, name: "outside-plane")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.parting = PartingSettings(
            mode: .manual,
            planes: [
                PartitionPlane(
                    normal: Vec3(x: 1, y: 0, z: 0),
                    offset: 1_000,
                    isManual: true
                )
            ]
        )
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        XCTAssertThrowsError(
            try MotherMoldPlanner.planThrowing(model: model, settings: settings),
            "A two-part request must fail when the supplied plane produces only one part."
        )
    }

    func testManualPartingRejectsMissingPlaneCountBeforeAutoFallback() throws {
        let geometry = sphere(radius: 10, longitudeSegments: 32, latitudeSegments: 16)
        let model = summary(geometry, name: "manual-plane-count")
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .four
        settings.parting = PartingSettings(
            mode: .manual,
            planes: [
                PartitionPlane(
                    normal: Vec3(x: 1, y: 0, z: 0),
                    offset: 0,
                    isManual: true
                )
            ]
        )
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        XCTAssertThrowsError(
            try MotherMoldPlanner.planThrowing(model: model, settings: settings),
            "Manual parting with the wrong plane count must fail before partitioning."
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("Manual parting requires exactly 2 plane(s)"), message)
            XCTAssertTrue(message.contains("blocked before partitioning"), message)
        }
    }

    func testEquivalentManualPlaneOrderAndNormalDirectionProduceIdenticalNamedParts() throws {
        let shellHandle = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 30, y: 24, z: 20)
        ))
        let shell = try ManifoldEngine.toMesh(shellHandle)
        var firstSettings = MotherMoldSettings.defaultValue
        firstSettings.parts = .four
        firstSettings.parting = PartingSettings(
            mode: .manual,
            planes: [
                PartitionPlane(normal: Vec3(x: 0, y: -4, z: 0), offset: -8, isManual: true),
                PartitionPlane(normal: Vec3(x: 2, y: 0, z: 0), offset: 6, isManual: true),
            ]
        )
        var equivalentSettings = firstSettings
        equivalentSettings.parting = PartingSettings(
            mode: .manual,
            planes: [
                PartitionPlane(normal: Vec3(x: -3, y: 0, z: 0), offset: -9, isManual: true),
                PartitionPlane(normal: Vec3(x: 0, y: 5, z: 0), offset: 10, isManual: true),
            ]
        )

        let firstPlanes = MoldPartitioner.resolvePlanes(shell: shell, settings: firstSettings)
        let equivalentPlanes = MoldPartitioner.resolvePlanes(shell: shell, settings: equivalentSettings)
        XCTAssertEqual(firstPlanes.count, 2)
        XCTAssertEqual(equivalentPlanes.count, 2)
        for (first, equivalent) in zip(firstPlanes, equivalentPlanes) {
            XCTAssertEqual(first.normal.x, equivalent.normal.x, accuracy: 1.0e-12)
            XCTAssertEqual(first.normal.y, equivalent.normal.y, accuracy: 1.0e-12)
            XCTAssertEqual(first.normal.z, equivalent.normal.z, accuracy: 1.0e-12)
            XCTAssertEqual(first.offset, equivalent.offset, accuracy: 1.0e-12)
        }

        let firstParts = try MoldPartitioner.partition(
            shell: shell,
            planes: firstPlanes,
            settings: firstSettings
        ).parts
        let equivalentParts = try MoldPartitioner.partition(
            shell: shell,
            planes: equivalentPlanes,
            settings: equivalentSettings
        ).parts
        XCTAssertEqual(firstParts.map(\.name), equivalentParts.map(\.name))
        XCTAssertEqual(firstParts.map(\.geometry), equivalentParts.map(\.geometry))
        withExtendedLifetime(shellHandle) {}
    }

    func testHealedHandAutoFourPartChoosesConnectedSplit() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appending(path: "docs/PRD.md").path) {
            root.deleteLastPathComponent()
        }
        let model = try MeshInspector.inspect(
            url: root.appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .four
        settings.key.type = .none
        settings.flange.enabled = false
        settings.spout.ventCount = 0

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        XCTAssertEqual(plan.parts.count, 4)
        XCTAssertEqual(Set(plan.partingPlanes.compactMap(\.axisAligned)), Set([0, 1]))
        XCTAssertTrue(plan.diagnostics.contains {
            $0.severity == .info && $0.message.localizedCaseInsensitiveContains("switched")
        })
        for part in plan.parts {
            let disconnected = MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry)
            XCTAssertEqual(
                disconnected.droppedCount,
                0,
                "\(part.name) must be one printable solid after connectivity-aware auto parting."
            )
            XCTAssertTrue(MotherMoldValidation.printablePreflight(part.geometry).isWatertight)
        }
    }

    private func sectionArea(_ geometry: MeshGeometryData, z: Double) -> Double {
        let plane = PartitionGeometry.PlaneEq(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: z
        )
        let loops = PartitionGeometry.sectionLoops(
            PartitionGeometry.triangleSoup(geometry),
            plane: plane
        )
        let islands = PartitionGeometry.islands(from: loops, plane: plane)
        let (u, v) = PartitionGeometry.basis(plane.n)
        let origin = Vec3(x: 0, y: 0, z: z)
        func loopArea(_ loop: [Vec3]) -> Double {
            let points = loop.map { PartitionGeometry.project($0, origin: origin, u: u, v: v) }
            guard points.count >= 3 else { return 0 }
            var twiceArea = 0.0
            for index in points.indices {
                let next = points[(index + 1) % points.count]
                twiceArea += points[index].x * next.y - next.x * points[index].y
            }
            return abs(twiceArea) * 0.5
        }
        return islands.reduce(0) { total, island in
            total + max(0, loopArea(island.outer) - island.holes.map(loopArea).reduce(0, +))
        }
    }

    private func sphere(
        radius: Double,
        longitudeSegments lon: Int,
        latitudeSegments lat: Int
    ) -> MeshGeometryData {
        var vertices: [Vec3] = [Vec3(x: 0, y: 0, z: radius)]
        var indices: [Int32] = []
        for j in 1..<lat {
            let phi = Double.pi * Double(j) / Double(lat)
            for i in 0..<lon {
                let theta = 2 * Double.pi * Double(i) / Double(lon)
                vertices.append(Vec3(
                    x: radius * sin(phi) * cos(theta),
                    y: radius * sin(phi) * sin(theta),
                    z: radius * cos(phi)
                ))
            }
        }
        let south = Int32(vertices.count)
        vertices.append(Vec3(x: 0, y: 0, z: -radius))
        for i in 0..<lon {
            indices += [0, Int32(1 + i), Int32(1 + (i + 1) % lon)]
        }
        for j in 0..<(lat - 2) {
            let lower = 1 + j * lon
            let upper = lower + lon
            for i in 0..<lon {
                let a = Int32(lower + i)
                let b = Int32(lower + (i + 1) % lon)
                let c = Int32(upper + (i + 1) % lon)
                let d = Int32(upper + i)
                indices += [a, c, b, a, d, c]
            }
        }
        let last = 1 + (lat - 2) * lon
        for i in 0..<lon {
            indices += [south, Int32(last + (i + 1) % lon), Int32(last + i)]
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private func summary(_ geometry: MeshGeometryData, name: String) -> MeshSummary {
        let xs = geometry.vertices.map(\.x)
        let ys = geometry.vertices.map(\.y)
        let zs = geometry.vertices.map(\.z)
        return MeshSummary(
            name: name,
            path: "",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: Bounds3D(
                min: Vec3(x: xs.min() ?? 0, y: ys.min() ?? 0, z: zs.min() ?? 0),
                max: Vec3(x: xs.max() ?? 0, y: ys.max() ?? 0, z: zs.max() ?? 0)
            ),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    private func boxPart(name: String, centerX: Double) throws -> MotherMoldPart {
        let handle = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: centerX, y: 0, z: 0),
            extents: Vec3(x: 1, y: 1, z: 1)
        ))
        let geometry = try ManifoldEngine.toMesh(handle)
        let bounds = ManifoldEngine.bounds(handle)
        withExtendedLifetime(handle) {}
        return MotherMoldPart(
            name: name,
            geometry: geometry,
            isWatertight: true,
            bounds: bounds
        )
    }
}
