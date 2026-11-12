import Foundation
import XCTest
@testable import RefabArtist

final class MotherMoldFlangeIntegrityTests: XCTestCase {
    private struct FlangeFixture {
        var parts: [MotherMoldPart]
        var planes: [PartitionPlane]
        var cavity: MeshGeometryData
    }

    func testFourPartOrganicQuadrantFlangesRemainDisjointAndDeterministic() throws {
        let fixture = try organicFixture(parts: .four)
        let first = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )
        let second = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )

        let interfaces = MoldPartingInterfaces.resolve(parts: fixture.parts, planes: fixture.planes)
        XCTAssertEqual(interfaces.count, 4)

        XCTAssertEqual(
            first.flangedSeamCount,
            interfaces.count,
            "Every physical mating interface needs its own clampable flange segment. Diagnostics: \(diagnosticText(first))"
        )
        XCTAssertEqual(first.flangePlatesPlaced, interfaces.count * 2)
        XCTAssertEqual(first.parts.map(\.name), fixture.parts.map(\.name), "Flanging must preserve stable part ordering.")
        XCTAssertEqual(first.parts, second.parts, "Identical flange inputs must produce byte-for-byte deterministic parts.")
        XCTAssertGreaterThan(
            try totalVolume(first.parts),
            try totalVolume(fixture.parts) + 1.0,
            "The integrity check must exercise actual flange additions."
        )
        assertMinimumNovelMaterialRetention(first)

        try assertWatertight(first.parts)
        try assertNoPositiveVolumeOverlap(first.parts)
    }

    func testFourPartFlangesAreInvariantToReversedPlaneList() throws {
        let fixture = try organicFixture(parts: .four)
        let forward = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 37
        )
        let reversed = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes.reversed(),
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 37
        )

        XCTAssertEqual(forward.flangedSeamCount, 4, diagnosticText(forward))
        XCTAssertEqual(reversed.flangedSeamCount, forward.flangedSeamCount, diagnosticText(reversed))
        XCTAssertEqual(reversed.flangePlatesPlaced, forward.flangePlatesPlaced, diagnosticText(reversed))
        XCTAssertEqual(reversed.effectiveBoltHoleCount, forward.effectiveBoltHoleCount, diagnosticText(reversed))
        assertMinimumNovelMaterialRetention(forward)
        assertMinimumNovelMaterialRetention(reversed)
        try assertEquivalentPartMeasurements(forward.parts, reversed.parts)
        try assertWatertight(reversed.parts)
        try assertNoPositiveVolumeOverlap(reversed.parts)
    }

    func testFourPartFlangesAreInvariantToEquivalentReversedPlaneNormals() throws {
        let fixture = try organicFixture(parts: .four)
        let forward = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 41
        )
        let equivalentPlanes = fixture.planes.map { plane in
            PartitionPlane(
                normal: Vec3(x: -plane.normal.x, y: -plane.normal.y, z: -plane.normal.z),
                offset: -plane.offset,
                isManual: plane.isManual
            )
        }
        let reversedNormals = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: equivalentPlanes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 41
        )

        XCTAssertEqual(forward.flangedSeamCount, 4, diagnosticText(forward))
        XCTAssertEqual(reversedNormals.flangedSeamCount, forward.flangedSeamCount, diagnosticText(reversedNormals))
        XCTAssertEqual(reversedNormals.flangePlatesPlaced, forward.flangePlatesPlaced, diagnosticText(reversedNormals))
        XCTAssertEqual(reversedNormals.effectiveBoltHoleCount, forward.effectiveBoltHoleCount, diagnosticText(reversedNormals))
        assertMinimumNovelMaterialRetention(forward)
        assertMinimumNovelMaterialRetention(reversedNormals)
        try assertEquivalentPartMeasurements(forward.parts, reversedNormals.parts)
        try assertWatertight(reversedNormals.parts)
        try assertNoPositiveVolumeOverlap(reversedNormals.parts)
    }

    func testOneImpossibleRequestedInterfaceRollsBackTheEntireFlangeSet() throws {
        let fixture = try boxFixture()
        let impossiblePlane = PartitionPlane(
            normal: fixture.planes[0].normal,
            offset: 1_000,
            isManual: true
        )
        let result = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes + [impossiblePlane],
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )

        assertRolledBack(result, to: fixture.parts)
    }

    func testDisconnectedGeneratedPlateCannotManufactureFlangeSuccess() throws {
        let fixture = try disconnectedPlateIslandFixture()
        var flange = FlangeSettings.defaultValue
        flange.boltHoleCount = 0
        let result = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: flange,
            cavity: fixture.cavity,
            seed: 0
        )

        assertRolledBack(result, to: fixture.parts)
    }

    func testDisconnectedImmutableInputRollsBackWithoutDeletingTheIsland() throws {
        var fixture = try boxFixture()
        let main = try ManifoldEngine.make(from: fixture.parts[0].geometry)
        let island = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 30, y: 0, z: 0),
            extents: Vec3(x: 4, y: 4, z: 4)
        ))
        let disconnected = try ManifoldEngine.union(main, island)
        fixture.parts[0].geometry = try ManifoldEngine.toMesh(disconnected)
        let originalParts = fixture.parts

        let result = try MoldFlangeBuilder.applyFlanges(
            parts: originalParts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )

        assertRolledBack(result, to: originalParts)
        XCTAssertTrue(
            result.diagnostics.contains {
                $0.severity == .error && $0.message.localizedCaseInsensitiveContains("immutable input")
            },
            diagnosticText(result)
        )
        withExtendedLifetime(main) {}
        withExtendedLifetime(island) {}
        withExtendedLifetime(disconnected) {}
    }

    func testProtectedLocatorSurvivesFlangeTransactionWithoutWholePartSeamTrimming() throws {
        let fixture = try boxFixture()
        let locatorHandle = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 0.2, y: 6, z: 6)
        ))
        let locator = try ManifoldEngine.toMesh(locatorHandle)
        let result = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0,
            protectedLocator: locator
        )

        let retained = try XCTUnwrap(
            MoldFeatureBuilder.retainedProtectedLocatorFraction(locator: locator, in: result.parts)
        )
        XCTAssertEqual(result.flangedSeamCount, 1, diagnosticText(result))
        XCTAssertGreaterThanOrEqual(retained, 0.98, diagnosticText(result))
        XCTAssertTrue(
            result.diagnostics.contains { $0.message.contains("Generated locator retention through the flange transaction") },
            diagnosticText(result)
        )
        assertMinimumNovelMaterialRetention(result)
        try assertWatertight(result.parts)
        try assertNoPositiveVolumeOverlap(result.parts)
        withExtendedLifetime(locatorHandle) {}
    }

    func testDefaultOrganicBoltBoresRemoveMaterialAndAreReported() throws {
        let fixture = try organicFixture(parts: .two)
        var noBoltSettings = FlangeSettings.defaultValue
        noBoltSettings.boltHoleCount = 0

        let unbored = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: noBoltSettings,
            cavity: fixture.cavity,
            seed: 0
        )
        let bored = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )

        XCTAssertEqual(unbored.flangedSeamCount, 1)
        XCTAssertEqual(bored.flangedSeamCount, 1)
        let removedVolume = try totalVolume(unbored.parts) - totalVolume(bored.parts)
        let boreSegments = 24.0
        let boreRadius = FlangeSettings.defaultValue.boltDiameter / 2
        let polygonalBoreArea = 0.5 * boreSegments * boreRadius * boreRadius
            * sin(2 * Double.pi / boreSegments)
        let expectedRemovedVolume = polygonalBoreArea
            * FlangeSettings.defaultValue.thickness
            * Double(FlangeSettings.defaultValue.boltHoleCount)
        XCTAssertEqual(
            removedVolume,
            expectedRemovedVolume,
            accuracy: expectedRemovedVolume * 0.02,
            "The measured removal must match four complete 24-sided bolt tunnels, not merely be nonzero. Diagnostics: \(diagnosticText(bored))"
        )
        XCTAssertEqual(
            try totalGenus(bored.parts) - totalGenus(unbored.parts),
            FlangeSettings.defaultValue.boltHoleCount * 2,
            "Every physical bolt bore must add one tunnel to each of the two mating parts."
        )
        XCTAssertTrue(
            bored.diagnostics.contains { $0.severity == .info && $0.message.contains("4 bolt holes") },
            "The successful organic seam must report all four effective default bores. Diagnostics: \(diagnosticText(bored))"
        )
        XCTAssertFalse(
            bored.diagnostics.contains { $0.message.contains("placed") && $0.message.contains("of 4 bolt holes") },
            "A fully feasible default organic seam must not emit a partial-placement warning."
        )
        assertMinimumNovelMaterialRetention(bored)
        try assertWatertight(bored.parts)
        try assertNoPositiveVolumeOverlap(bored.parts)
    }

    func testNoOpBoltCandidatesAreRelocatedUntilThePatternIsComplete() throws {
        let fixture = try preBoredBoxFixture()
        let result = try MoldFlangeBuilder.applyFlanges(
            parts: fixture.parts,
            planes: fixture.planes,
            flange: .defaultValue,
            cavity: fixture.cavity,
            seed: 0
        )

        XCTAssertEqual(result.flangedSeamCount, 1, "Pre-existing clearance must not prevent the flange itself from attaching.")
        XCTAssertEqual(result.effectiveBoltHoleCount, 4)
        XCTAssertTrue(
            result.diagnostics.contains { $0.severity == .info && $0.message.contains("4 bolt holes") },
            "No-op candidate positions must be replaced by alternate holes that remove real plate material."
        )
        XCTAssertFalse(
            result.diagnostics.contains { $0.message.contains("only") && $0.message.contains("requested bolt holes") },
            "A recovered pattern must not retain a partial-placement failure."
        )
        assertMinimumNovelMaterialRetention(result)
        try assertWatertight(result.parts)
        try assertNoPositiveVolumeOverlap(result.parts)
    }

    func testHealedHandFourPartJacketRetainsAClampingFlange() throws {
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .four

        let plan = try MotherMoldPlanner.planThrowing(model: model, settings: settings)

        XCTAssertGreaterThan(
            plan.flangedSeamCount,
            0,
            "An enabled four-part jacket needs at least one surviving clamping flange. Diagnostics: \(plan.diagnostics.map(\.message))"
        )
        XCTAssertFalse(plan.diagnostics.contains {
            $0.severity == .error && $0.message.localizedCaseInsensitiveContains("no way to clamp")
        })
        for part in plan.parts {
            XCTAssertTrue(MeshPreflight.analyze(geometry: part.geometry).isWatertight, part.name)
        }
    }

    func testHealedHandYZJacketBuildsEveryCompleteFlangeInterface() throws {
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_ui_healed.obj")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .siliconeJacket
        settings.parts = .four
        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: model.geometry, settings: settings)
        let mounted = MoldMasterMountBuilder.apply(
            shell: shell.solid,
            master: model.geometry,
            settings: settings
        )
        let center = vertexMean(cavity)
        let planes = [
            PartitionPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: center.y, isManual: true),
            PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: center.z, isManual: true),
        ]
        let partition = try MoldPartitioner.partition(
            shell: mounted.solid,
            planes: planes,
            settings: settings
        )
        let result = try MoldFlangeBuilder.applyFlanges(
            parts: partition.parts,
            planes: partition.planes,
            flange: settings.flange,
            cavity: cavity,
            seed: settings.seed
        )
        let interfaces = MoldPartingInterfaces.resolve(parts: partition.parts, planes: planes)

        XCTAssertEqual(result.flangedSeamCount, interfaces.count, diagnosticText(result))
        XCTAssertEqual(result.flangePlatesPlaced, interfaces.count * 2, diagnosticText(result))
        XCTAssertEqual(
            result.effectiveBoltHoleCount,
            interfaces.count * settings.flange.boltHoleCount,
            diagnosticText(result)
        )
        XCTAssertFalse(result.diagnostics.contains { $0.severity == .error }, diagnosticText(result))
        assertMinimumNovelMaterialRetention(result)
        try assertWatertight(result.parts)
        try assertNoPositiveVolumeOverlap(result.parts)
    }

    private func organicFixture(parts: MoldPartCount) throws -> FlangeFixture {
        let model = try MeshInspector.inspect(
            url: repoRoot().appending(path: "tests/fixtures/organic/low_poly_head.stl")
        )
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = parts
        settings.key.type = .none

        let cavity = try MoldCavityBuilder.buildCavity(master: model.geometry, settings: settings)
        let shell = try MoldShellBuilder.buildShell(cavity: cavity, master: model.geometry, settings: settings)
        let center = vertexMean(cavity)
        let axes = [
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 0, y: 0, z: 1),
        ]
        let planeOffset: (Vec3) -> Double = { axis in
            axis.x * center.x + axis.y * center.y + axis.z * center.z
        }
        var candidates: [[PartitionPlane]] = [
            MoldPartitioner.resolvePlanes(shell: shell.solid, reference: cavity, settings: settings)
        ]
        if parts == .two {
            candidates.append(contentsOf: axes.map { axis in
                [PartitionPlane(normal: axis, offset: planeOffset(axis), isManual: false)]
            })
        } else {
            candidates.append(contentsOf: [
                [axes[0], axes[1]],
                [axes[0], axes[2]],
                [axes[1], axes[2]],
            ].map { pair in
                pair.map { axis in
                    PartitionPlane(normal: axis, offset: planeOffset(axis), isManual: false)
                }
            })
        }

        for planes in candidates {
            let partition = try MoldPartitioner.partition(
                shell: shell.solid,
                planes: planes,
                settings: settings
            )
            let expectedCount = parts == .four ? 4 : 2
            let isConnected = partition.parts.allSatisfy {
                MoldComponentFilter.dropFaceDisconnectedDebris($0.geometry).droppedCount == 0
            }
            if partition.parts.count == expectedCount, isConnected {
                return FlangeFixture(parts: partition.parts, planes: partition.planes, cavity: cavity)
            }
        }

        throw NSError(
            domain: "MotherMoldFlangeIntegrityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No connected organic partition fixture was available for \(parts.rawValue)."]
        )
    }

    private func boxFixture(cavity: MeshGeometryData? = nil) throws -> FlangeFixture {
        let plane = PartitionPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0,
            isManual: false
        )
        let whole = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 20, z: 20)
        ))
        let halves = try ManifoldEngine.splitByPlane(whole, normal: plane.normal, offset: plane.offset)
        let geometries = [try ManifoldEngine.toMesh(halves.0), try ManifoldEngine.toMesh(halves.1)]
        let parts = geometries.enumerated().map { index, geometry in
            MotherMoldPart(
                name: "mold-part-\(index == 0 ? "A" : "B")",
                geometry: geometry,
                bounds: bounds(of: geometry)
            )
        }
        withExtendedLifetime(whole) {}
        withExtendedLifetime(halves) {}
        return FlangeFixture(
            parts: parts,
            planes: [plane],
            cavity: cavity ?? MeshGeometryData(vertices: [], triangleIndices: [])
        )
    }

    private func disconnectedPlateIslandFixture() throws -> FlangeFixture {
        let cutter = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 24, z: 24)
        ))
        let cavity = try ManifoldEngine.toMesh(cutter)
        withExtendedLifetime(cutter) {}
        return try boxFixture(cavity: cavity)
    }

    private func vertexMean(_ geometry: MeshGeometryData) -> Vec3 {
        let sum = geometry.vertices.reduce(Vec3(x: 0, y: 0, z: 0)) {
            Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        let count = Double(max(1, geometry.vertices.count))
        return Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
    }

    /// The cavity already contains clearance boxes around every deterministic
    /// bolt candidate. Subtracting the later cylinders is therefore a true
    /// boolean no-op while the surrounding flange remains connected.
    private func preBoredBoxFixture() throws -> FlangeFixture {
        let plane = PartitionPlane(
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 0,
            isManual: false
        )
        let whole = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 20, z: 20)
        ))
        let halves = try ManifoldEngine.splitByPlane(whole, normal: plane.normal, offset: plane.offset)
        let geometries = [try ManifoldEngine.toMesh(halves.0), try ManifoldEngine.toMesh(halves.1)]
        let parts = geometries.enumerated().map { index, geometry in
            MotherMoldPart(
                name: "mold-part-\(index == 0 ? "A" : "B")",
                geometry: geometry,
                bounds: bounds(of: geometry)
            )
        }

        let hull = MoldFlangeBuilder.convexHull2D([
            Vec2(x: -10, y: -10), Vec2(x: 10, y: -10),
            Vec2(x: 10, y: 10), Vec2(x: -10, y: 10),
        ])
        let ring = MoldFlangeBuilder.offsetConvexPolygon(hull, by: FlangeSettings.defaultValue.width / 2)
        let centres = equallySpacedPerimeterPoints(ring, count: FlangeSettings.defaultValue.boltHoleCount)
        let clearanceBoxes = try centres.map { centre in
            // For n=+X, MoldFlangeBuilder's basis is u=-Z and v=+Y.
            try ManifoldEngine.box(ManifoldBoxSpec(
                center: Vec3(x: 0, y: centre.y, z: -centre.x),
                extents: Vec3(x: 20, y: 6, z: 6)
            ))
        }
        let clearance = try ManifoldEngine.union(clearanceBoxes)
        let cavity = try ManifoldEngine.toMesh(clearance)
        withExtendedLifetime(whole) {}
        withExtendedLifetime(halves) {}
        withExtendedLifetime(clearanceBoxes) {}
        withExtendedLifetime(clearance) {}
        return FlangeFixture(parts: parts, planes: [plane], cavity: cavity)
    }

    private func equallySpacedPerimeterPoints(_ polygon: [Vec2], count: Int) -> [Vec2] {
        var cumulative: [Double] = [0]
        for index in polygon.indices {
            let point = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            cumulative.append(cumulative[index] + hypot(next.x - point.x, next.y - point.y))
        }
        let total = cumulative.last ?? 0
        return (0..<count).map { pointIndex in
            let target = total * Double(pointIndex) / Double(count)
            for index in polygon.indices where cumulative[index + 1] >= target {
                let segment = cumulative[index + 1] - cumulative[index]
                let fraction = segment > 1.0e-12 ? (target - cumulative[index]) / segment : 0
                let point = polygon[index]
                let next = polygon[(index + 1) % polygon.count]
                return Vec2(
                    x: point.x + (next.x - point.x) * fraction,
                    y: point.y + (next.y - point.y) * fraction
                )
            }
            return polygon[0]
        }
    }

    private func assertWatertight(
        _ parts: [MotherMoldPart],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for part in parts {
            let handle = try ManifoldEngine.make(from: part.geometry)
            XCTAssertTrue(
                ManifoldEngine.isWatertight(handle),
                "\(part.name) must remain watertight after flange attachment.",
                file: file,
                line: line
            )
            withExtendedLifetime(handle) {}
        }
    }

    private func assertRolledBack(
        _ result: MoldFlangeBuilder.FlangeResult,
        to originalParts: [MotherMoldPart],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.parts, originalParts, "A failed flange transaction must return the original parts.", file: file, line: line)
        XCTAssertEqual(result.flangedSeamCount, 0, file: file, line: line)
        XCTAssertEqual(result.flangePlatesPlaced, 0, file: file, line: line)
        XCTAssertEqual(result.effectiveBoltHoleCount, 0, file: file, line: line)
        XCTAssertEqual(result.minimumNovelMaterialRetention, 0, file: file, line: line)
        XCTAssertTrue(
            result.diagnostics.contains { $0.severity == .error },
            "A rolled-back flange transaction must report at least one error. Diagnostics: \(diagnosticText(result))",
            file: file,
            line: line
        )
    }

    private func assertMinimumNovelMaterialRetention(
        _ result: MoldFlangeBuilder.FlangeResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            result.minimumNovelMaterialRetention,
            0.98,
            "Every counted part-side flange must retain at least 98% of its novel material after finalization. Measured minimum: \(result.minimumNovelMaterialRetention * 100)%. Diagnostics: \(diagnosticText(result))",
            file: file,
            line: line
        )
    }

    private func assertEquivalentPartMeasurements(
        _ lhs: [MotherMoldPart],
        _ rhs: [MotherMoldPart],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(lhs.map(\.name), rhs.map(\.name), file: file, line: line)
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for index in lhs.indices {
            let left = try ManifoldEngine.make(from: lhs[index].geometry)
            let right = try ManifoldEngine.make(from: rhs[index].geometry)
            let leftVolume = abs(ManifoldEngine.volume(left))
            let rightVolume = abs(ManifoldEngine.volume(right))
            XCTAssertEqual(
                leftVolume,
                rightVolume,
                accuracy: max(1.0e-3, leftVolume * 1.0e-8),
                "\(lhs[index].name) volume changed under an equivalent plane representation.",
                file: file,
                line: line
            )
            let leftBounds = try XCTUnwrap(bounds(of: lhs[index].geometry), file: file, line: line)
            let rightBounds = try XCTUnwrap(bounds(of: rhs[index].geometry), file: file, line: line)
            for (leftValue, rightValue) in [
                (leftBounds.min.x, rightBounds.min.x),
                (leftBounds.min.y, rightBounds.min.y),
                (leftBounds.min.z, rightBounds.min.z),
                (leftBounds.max.x, rightBounds.max.x),
                (leftBounds.max.y, rightBounds.max.y),
                (leftBounds.max.z, rightBounds.max.z),
            ] {
                XCTAssertEqual(leftValue, rightValue, accuracy: 1.0e-4, file: file, line: line)
            }
            withExtendedLifetime(left) {}
            withExtendedLifetime(right) {}
        }
    }

    private func assertNoPositiveVolumeOverlap(
        _ parts: [MotherMoldPart],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for firstIndex in parts.indices {
            for secondIndex in parts.indices where secondIndex > firstIndex {
                let first = try ManifoldEngine.make(from: parts[firstIndex].geometry)
                let second = try ManifoldEngine.make(from: parts[secondIndex].geometry)
                let intersection = try ManifoldEngine.intersect(first, second)
                let overlap = abs(ManifoldEngine.volume(intersection))
                XCTAssertLessThanOrEqual(
                    overlap,
                    1.0e-4,
                    "\(parts[firstIndex].name) and \(parts[secondIndex].name) overlap by \(overlap) mm^3.",
                    file: file,
                    line: line
                )
                withExtendedLifetime(first) {}
                withExtendedLifetime(second) {}
                withExtendedLifetime(intersection) {}
            }
        }
    }

    private func totalVolume(_ parts: [MotherMoldPart]) throws -> Double {
        var total = 0.0
        for part in parts {
            let handle = try ManifoldEngine.make(from: part.geometry)
            total += abs(ManifoldEngine.volume(handle))
            withExtendedLifetime(handle) {}
        }
        return total
    }

    private func totalGenus(_ parts: [MotherMoldPart]) throws -> Int {
        var total = 0
        for part in parts {
            let handle = try ManifoldEngine.make(from: part.geometry)
            total += ManifoldEngine.genus(handle)
            withExtendedLifetime(handle) {}
        }
        return total
    }

    private func diagnosticText(_ result: MoldFlangeBuilder.FlangeResult) -> String {
        result.diagnostics.map { "[\($0.severity.rawValue)] \($0.message)" }.joined(separator: " | ")
    }

    private func bounds(of geometry: MeshGeometryData) -> Bounds3D? {
        guard var minimum = geometry.vertices.first else { return nil }
        var maximum = minimum
        for vertex in geometry.vertices.dropFirst() {
            minimum.x = min(minimum.x, vertex.x)
            minimum.y = min(minimum.y, vertex.y)
            minimum.z = min(minimum.z, vertex.z)
            maximum.x = max(maximum.x, vertex.x)
            maximum.y = max(maximum.y, vertex.y)
            maximum.z = max(maximum.z, vertex.z)
        }
        return Bounds3D(min: minimum, max: maximum)
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
