import XCTest
@testable import RefabArtist

final class MotherMoldKeyIntegrityTests: XCTestCase {
    private let seamZ = 0.0
    private let centerX = 20.0
    private let centerY = 20.0

    func testFourPartKeysCoverEveryPhysicalMatingInterface() throws {
        let parts = try fourQuadrantParts()
        let planes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0, isManual: false),
            PartitionPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 0, isManual: false),
        ]
        let interfaces = MoldPartingInterfaces.resolve(parts: parts, planes: planes)
        XCTAssertEqual(interfaces.count, 4, "Two orthogonal planes create four physical mating interfaces.")

        var key = keySettings()
        key.pinDiameter = 4
        key.pinLength = 4
        key.pinsPerSeam = 1
        key.edgeMargin = 2
        let result = try MoldKeyBuilder.applyKeys(parts: parts, planes: planes, key: key)

        XCTAssertEqual(
            result.registrationKeysPlaced,
            interfaces.count,
            "Per seam means one key on each physical part pair, not one key per infinite split plane. Diagnostics: \(result.diagnostics.map(\.message))"
        )
        let pairs = Set(result.sites.map { "\($0.malePartName)|\($0.femalePartName)" })
        XCTAssertEqual(pairs.count, 4)
        for part in parts {
            let incidence = result.sites.filter {
                $0.malePartName == part.name || $0.femalePartName == part.name
            }.count
            XCTAssertEqual(incidence, 2, "Every quadrant must register to both of its physical neighbors.")
        }
        try assertNoPositiveVolumeOverlap(result.parts)
    }

    func testFourPartKeysCoverEveryPhysicalMatingInterfaceAcrossPrimaryAxisPairs() throws {
        let axisPairs: [(Vec3, Vec3)] = [
            (Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0)),
            (Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 0, z: 1)),
            (Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1)),
        ]

        var key = keySettings()
        key.pinDiameter = 4
        key.pinLength = 4
        key.pinsPerSeam = 1
        key.edgeMargin = 2

        for (first, second) in axisPairs {
            let parts = fourPartParts(firstNormal: first, secondNormal: second)
            let planes = [
                PartitionPlane(normal: first, offset: 0, isManual: false),
                PartitionPlane(normal: second, offset: 0, isManual: false),
            ]
            let interfaces = MoldPartingInterfaces.resolve(parts: parts, planes: planes)
            let result = try MoldKeyBuilder.applyKeys(parts: parts, planes: planes, key: key)

            XCTAssertEqual(result.registrationKeysPlaced, interfaces.count, "Axis pair \(first), \(second) must retain every physical interface. Diagnostics: \(result.diagnostics.map(\.message))")
            XCTAssertEqual(result.sites.count, interfaces.count)
            try assertNoPositiveVolumeOverlap(result.parts)
        }
    }

    func testNovelMaleDeltaIgnoresEmbeddedContactButRejectsAddedBossInterference() throws {
        let originalMale = boxGeometry(
            minimum: Vec3(x: 0, y: 0, z: -12),
            maximum: Vec3(x: 40, y: 40, z: 0)
        )
        let keyedMale = try unionedGeometry(
            originalMale,
            boxGeometry(
                minimum: Vec3(x: 18, y: 18, z: -0.6),
                maximum: Vec3(x: 22, y: 22, z: 4)
            )
        )
        let keyedPart = part(name: "keyed", geometry: keyedMale)
        let embeddedContact = part(
            name: "embedded-contact",
            geometry: boxGeometry(
                minimum: Vec3(x: 18.5, y: 18.5, z: -0.5),
                maximum: Vec3(x: 21.5, y: 21.5, z: -0.1)
            )
        )
        let novelBossContact = part(
            name: "novel-boss-contact",
            geometry: boxGeometry(
                minimum: Vec3(x: 18.5, y: 18.5, z: 1),
                maximum: Vec3(x: 21.5, y: 21.5, z: 2)
            )
        )

        XCTAssertTrue(
            try MoldKeyBuilder.novelMaleDeltaIsDisjoint(
                originalMale: originalMale,
                keyedMale: keyedMale,
                malePartIndex: 0,
                in: [keyedPart, embeddedContact]
            ),
            "Contact confined to material that existed before the key union must not reject the candidate."
        )
        XCTAssertFalse(
            try MoldKeyBuilder.novelMaleDeltaIsDisjoint(
                originalMale: originalMale,
                keyedMale: keyedMale,
                malePartIndex: 0,
                in: [keyedPart, novelBossContact]
            ),
            "A crossing part that intersects the new boss protrusion must reject the candidate."
        )
    }

    func testPinAndPocketSharePartitionOrientationLengthTaperAndClearance() throws {
        let negative = part(name: "negative", xLo: 0, xHi: 40, zLo: -12, zHi: seamZ)
        let positive = part(name: "positive", xLo: 0, xHi: 40, zLo: seamZ, zHi: 12)
        let plane = PartitionPlane(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: seamZ,
            isManual: false
        )
        let key = keySettings()

        let first = try MoldKeyBuilder.applyKeys(
            parts: [positive, negative],
            planes: [plane],
            key: key
        )
        let second = try MoldKeyBuilder.applyKeys(
            parts: [positive, negative],
            planes: [plane],
            key: key
        )

        XCTAssertEqual(first, second, "Key geometry and diagnostics must be deterministic.")
        XCTAssertEqual(successDiagnostics(in: first).count, 1)

        let male = try XCTUnwrap(first.parts.first { $0.name == negative.name })
        let female = try XCTUnwrap(first.parts.first { $0.name == positive.name })
        let pinTipZ = try XCTUnwrap(featureVertices(in: male.geometry).map(\.z).max())

        XCTAssertEqual(
            pinTipZ - seamZ,
            key.pinLength,
            accuracy: 0.05,
            "A nominal 6 mm pin must protrude by its usable length, not only the 0.6 mm embed."
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(female.geometry.vertices.map(\.z).min()),
            seamZ - 1.0e-5,
            "The positive-side pocket must not create geometry across the seam."
        )

        let pinBaseRadius = try XCTUnwrap(ringRadius(in: male.geometry, at: seamZ))
        let pinTipRadius = try XCTUnwrap(ringRadius(in: male.geometry, at: pinTipZ))
        XCTAssertGreaterThan(
            pinBaseRadius - pinTipRadius,
            0.5,
            "The male key must narrow toward its protruding tip."
        )

        let pocketVertices = featureVertices(in: female.geometry)
        let pocketFloorZ = try XCTUnwrap(pocketVertices.map(\.z).max())
        let pocketMouthRadius = try XCTUnwrap(ringRadius(in: female.geometry, at: seamZ))
        let pocketFloorRadius = try XCTUnwrap(ringRadius(in: female.geometry, at: pocketFloorZ))
        XCTAssertGreaterThan(
            pocketFloorZ,
            pinTipZ + key.tolerance,
            "The pocket must extend beyond the usable pin tip."
        )
        XCTAssertEqual(
            pocketMouthRadius - pinBaseRadius,
            key.tolerance,
            accuracy: 0.04,
            "The pocket mouth must preserve the requested lateral clearance."
        )

        let pocketRadiusAtPinTip = pocketMouthRadius
            + (pocketFloorRadius - pocketMouthRadius) * ((pinTipZ - seamZ) / (pocketFloorZ - seamZ))
        XCTAssertEqual(
            pocketRadiusAtPinTip - pinTipRadius,
            key.tolerance,
            accuracy: 0.04,
            "Boss and pocket must shrink at the same rate so clearance remains constant."
        )

        for keyedPart in first.parts {
            let preflight = MeshPreflight.analyze(geometry: keyedPart.geometry)
            XCTAssertTrue(
                preflight.isWatertight,
                "\(keyedPart.name) must remain watertight (boundary=\(preflight.boundaryEdgeCount), nonManifold=\(preflight.nonManifoldEdgeCount))."
            )
        }
    }

    func testSurvivingSitesRejectsBossSideTipAndPocketPerimeterLossOutsideTheCenterline() throws {
        let negative = part(name: "negative", xLo: 0, xHi: 40, zLo: -12, zHi: seamZ)
        let positive = part(name: "positive", xLo: 0, xHi: 40, zLo: seamZ, zHi: 12)
        let plane = PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: seamZ, isManual: false)
        let result = try MoldKeyBuilder.applyKeys(parts: [positive, negative], planes: [plane], key: keySettings())
        let site = try XCTUnwrap(result.sites.first)
        let male = try XCTUnwrap(result.parts.first { $0.name == negative.name })
        let female = try XCTUnwrap(result.parts.first { $0.name == positive.name })

        XCTAssertEqual(MoldKeyBuilder.survivingSites([site], in: result.parts), [site])

        let sideRemoved = try subtractedGeometry(
            male.geometry,
            boxGeometry(
                minimum: Vec3(x: site.center.x + 0.6, y: site.center.y - 4, z: -0.1),
                maximum: Vec3(x: site.center.x + 4, y: site.center.y + 4, z: site.pinLength + 0.1)
            )
        )
        XCTAssertTrue(
            MoldKeyBuilder.survivingSites(
                [site],
                in: replacingPart(named: male.name, geometry: sideRemoved, in: result.parts)
            ).isEmpty,
            "Removing a boss side away from the centerline must invalidate the full-profile evidence."
        )

        let tipRemoved = try subtractedGeometry(
            male.geometry,
            boxGeometry(
                minimum: Vec3(x: site.center.x - 4, y: site.center.y - 4, z: site.pinLength * 0.92),
                maximum: Vec3(x: site.center.x + 4, y: site.center.y + 4, z: site.pinLength + 0.1)
            )
        )
        XCTAssertTrue(
            MoldKeyBuilder.survivingSites(
                [site],
                in: replacingPart(named: male.name, geometry: tipRemoved, in: result.parts)
            ).isEmpty,
            "Removing the final boss tip beyond the old 90% centerline sample must invalidate the full-profile evidence."
        )

        let blockedPocket = try unionedGeometry(
            female.geometry,
            boxGeometry(
                minimum: Vec3(x: site.center.x + 0.6, y: site.center.y - 2, z: -0.1),
                maximum: Vec3(x: site.center.x + 4, y: site.center.y + 2, z: site.pocketDepth + 0.1)
            )
        )
        XCTAssertTrue(
            MoldKeyBuilder.survivingSites(
                [site],
                in: replacingPart(named: female.name, geometry: blockedPocket, in: result.parts)
            ).isEmpty,
            "Restoring material along a pocket perimeter away from the centerline must invalidate clearance evidence."
        )
    }

    func testRoundAndTaperedBarKeepNominalEightDegreeTaperAtDepthBoundary() throws {
        let negative = part(name: "negative", xLo: 0, xHi: 40, zLo: -12, zHi: seamZ)
        let positive = part(name: "positive", xLo: 0, xHi: 40, zLo: seamZ, zHi: 12)
        let plane = PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: seamZ, isManual: false)
        let nominalSlope = tan(8.0 * Double.pi / 180)

        for type in [PartitionKeyType.pins, .dovetail] {
            var key = keySettings()
            key.type = type
            key.pinDiameter = 2
            key.pinLength = 6
            let result = try MoldKeyBuilder.applyKeys(parts: [positive, negative], planes: [plane], key: key)
            let site = try XCTUnwrap(result.sites.first, "\(type) must retain a feasible shortened key.")
            let male = try XCTUnwrap(result.parts.first { $0.name == negative.name })
            let female = try XCTUnwrap(result.parts.first { $0.name == positive.name })
            let profileHalfExtent: (MeshGeometryData, Double) -> Double? = { geometry, z in
                if type == .dovetail {
                    return self.ringHalfWidth(in: geometry, at: z)
                }
                return self.ringRadius(in: geometry, at: z)
            }
            let bossBase = try XCTUnwrap(profileHalfExtent(male.geometry, seamZ))
            let bossTip = try XCTUnwrap(profileHalfExtent(male.geometry, site.pinLength))
            let pocketMouth = try XCTUnwrap(profileHalfExtent(female.geometry, seamZ))
            let pocketFloor = try XCTUnwrap(profileHalfExtent(female.geometry, site.pocketDepth))

            XCTAssertLessThan(site.pinLength, key.pinLength, "\(type) must shorten an infeasible requested depth instead of flattening taper.")
            XCTAssertEqual((bossBase - bossTip) / site.pinLength, nominalSlope, accuracy: 0.03)
            XCTAssertEqual((pocketMouth - pocketFloor) / site.pocketDepth, nominalSlope, accuracy: 0.03)
        }
    }

    func testMissingBackingHitsRejectSiteOutsideRealSeamGeometry() throws {
        let negativeGeometry = mergedGeometry([
            boxGeometry(xLo: 0, xHi: 12, zLo: -12, zHi: seamZ),
            boxGeometry(xLo: 28, xHi: 40, zLo: -12, zHi: seamZ),
        ])
        let positiveGeometry = mergedGeometry([
            boxGeometry(xLo: 0, xHi: 12, zLo: seamZ, zHi: 12),
            boxGeometry(xLo: 28, xHi: 40, zLo: seamZ, zHi: 12),
        ])
        let inputs = [
            part(name: "positive-gap", geometry: positiveGeometry),
            part(name: "negative-gap", geometry: negativeGeometry),
        ]
        let plane = PartitionPlane(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: seamZ,
            isManual: false
        )

        let result = try MoldKeyBuilder.applyKeys(
            parts: inputs,
            planes: [plane],
            key: keySettings()
        )

        XCTAssertEqual(result.parts, inputs, "A candidate in the gap must leave the mold unchanged.")
        XCTAssertEqual(result.registrationKeysPlaced, 0, "An inspection-only failure must not keep partial key counts.")
        XCTAssertTrue(result.sites.isEmpty, "An inspection-only failure must not keep partial key sites.")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .error })
        XCTAssertTrue(
            result.diagnostics.contains { $0.severity == .error && !$0.message.localizedCaseInsensitiveContains("butt joint") },
            "Rejected seam sites must now fail honestly instead of falling back to a butt joint."
        )
    }

    func testFailedMatingBooleanRollsBackAndDoesNotReportPlacedKey() throws {
        let negative = part(name: "negative-valid", xLo: 0, xHi: 40, zLo: -12, zHi: seamZ)
        var openPositiveGeometry = boxGeometry(xLo: 0, xHi: 40, zLo: seamZ, zHi: 12)
        openPositiveGeometry.triangleIndices.removeLast(6)
        let positive = part(name: "positive-open", geometry: openPositiveGeometry, isWatertight: false)
        let inputs = [positive, negative]
        let plane = PartitionPlane(
            normal: Vec3(x: 0, y: 0, z: 1),
            offset: seamZ,
            isManual: false
        )

        let result = try MoldKeyBuilder.applyKeys(
            parts: inputs,
            planes: [plane],
            key: keySettings()
        )

        XCTAssertEqual(result.parts, inputs, "A boss must not survive when its mating pocket fails.")
        XCTAssertEqual(result.registrationKeysPlaced, 0, "An incomplete requested key pattern must report zero placed keys.")
        XCTAssertTrue(result.sites.isEmpty, "An incomplete requested key pattern must retain zero placed sites.")
        XCTAssertTrue(successDiagnostics(in: result).isEmpty)
        XCTAssertTrue(
            result.diagnostics.contains {
                let message = $0.message.localizedLowercase
                let reportsNoRetainedKeys = message.contains("no keys were placed")
                    || message.contains("no partial keys")
                    || message.contains("no partial geometry")
                return $0.severity == .error
                    && message.contains("complete")
                    && message.contains("key pattern")
                    && reportsNoRetainedKeys
            },
            "The incomplete requested key pattern must report a clear error and retain no partial keys."
        )
    }

    func testBacktrackingFindsLaterCompleteArrangementAfterEarlyDeadEnd() {
        var attemptedPaths: [[Int]] = []
        let result = MoldKeyBuilder.searchCompletePattern(
            candidateCount: 4,
            requestedCount: 2,
            nodeBudget: 32,
            initialState: [Int](),
            isCompatible: { _, _ in true },
            applyCandidate: { selected, candidateIndex in
                let attemptedPath = selected + [candidateIndex]
                attemptedPaths.append(attemptedPath)
                // Candidate zero is locally viable, but every possible second
                // operation on that branch fails. The later [1, 2] branch is
                // the first complete pattern in deterministic candidate order.
                return selected == [0] ? nil : attemptedPath
            }
        )

        guard case .success(let selected, let selectedIndices, let metrics) = result else {
            return XCTFail("The complete alternate pattern must be found after the first branch dead-ends.")
        }
        XCTAssertEqual(selected, [1, 2])
        XCTAssertEqual(selectedIndices, [1, 2])
        XCTAssertEqual(metrics.backtracks, 1, "The locally viable [0] branch must be discarded exactly once.")
        XCTAssertEqual(metrics.nodesVisited, 4)
        XCTAssertEqual(
            attemptedPaths,
            [[0], [0, 1], [0, 2], [0, 3], [1], [1, 2]],
            "The regression must prove the early candidate was tried before the complete alternate path."
        )
    }

    func testLaterInterfaceFailureRollsBackEarlierSuccesses() throws {
        let parts = try fourQuadrantParts()
        var openUpperRightGeometry = parts[3].geometry
        openUpperRightGeometry.triangleIndices.removeLast(6)
        let inputs = [
            part(name: "A", geometry: parts[0].geometry),
            part(name: "B", geometry: parts[1].geometry),
            part(name: "C", geometry: parts[2].geometry),
            part(name: "D-open", geometry: openUpperRightGeometry, isWatertight: false),
        ]
        let planes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0, isManual: false),
            PartitionPlane(normal: Vec3(x: 0, y: 1, z: 0), offset: 0, isManual: false),
        ]

        var key = keySettings()
        key.pinDiameter = 4
        key.pinLength = 4
        key.pinsPerSeam = 1
        key.edgeMargin = 2

        let result = try MoldKeyBuilder.applyKeys(
            parts: inputs,
            planes: planes,
            key: key
        )

        XCTAssertEqual(result.parts, inputs, "A later interface failure must roll back earlier committed interfaces.")
        XCTAssertEqual(result.registrationKeysPlaced, 0, "Rolled-back interfaces must not contribute to the final count.")
        XCTAssertTrue(result.sites.isEmpty, "Rolled-back interfaces must not leave any reported sites.")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .error })
    }

    private func keySettings() -> PartitionKeySettings {
        PartitionKeySettings(
            type: .pins,
            pinDiameter: 6,
            pinLength: 6,
            tolerance: 0.2,
            pinsPerSeam: 1,
            edgeMargin: 3
        )
    }

    private func successDiagnostics(in result: MoldKeyBuilder.KeyResult) -> [MoldDiagnostic] {
        result.diagnostics.filter { $0.severity == .info && $0.message.contains("placed") }
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
                    0.01,
                    "Generated keys made \(parts[firstIndex].name) overlap \(parts[secondIndex].name) by \(overlap) mm^3.",
                    file: file,
                    line: line
                )
                withExtendedLifetime(first) {}
                withExtendedLifetime(second) {}
                withExtendedLifetime(intersection) {}
            }
        }
    }

    private func featureVertices(in geometry: MeshGeometryData) -> [Vec3] {
        geometry.vertices.filter {
            let radius = hypot($0.x - centerX, $0.y - centerY)
            return radius > 0.1 && radius < 5
        }
    }

    private func ringRadius(in geometry: MeshGeometryData, at z: Double) -> Double? {
        featureVertices(in: geometry)
            .filter { abs($0.z - z) < 0.03 }
            .map { hypot($0.x - centerX, $0.y - centerY) }
            .max()
    }

    private func ringHalfWidth(in geometry: MeshGeometryData, at z: Double) -> Double? {
        featureVertices(in: geometry)
            .filter { abs($0.z - z) < 0.03 }
            .map { abs($0.x - centerX) }
            .max()
    }

    private func part(
        name: String,
        xLo: Double,
        xHi: Double,
        zLo: Double,
        zHi: Double
    ) -> MotherMoldPart {
        part(name: name, geometry: boxGeometry(xLo: xLo, xHi: xHi, zLo: zLo, zHi: zHi))
    }

    private func part(
        name: String,
        geometry: MeshGeometryData,
        isWatertight: Bool = true
    ) -> MotherMoldPart {
        let minX = geometry.vertices.map(\.x).min() ?? 0
        let maxX = geometry.vertices.map(\.x).max() ?? 0
        let minY = geometry.vertices.map(\.y).min() ?? 0
        let maxY = geometry.vertices.map(\.y).max() ?? 0
        let minZ = geometry.vertices.map(\.z).min() ?? 0
        let maxZ = geometry.vertices.map(\.z).max() ?? 0
        return MotherMoldPart(
            name: name,
            geometry: geometry,
            isWatertight: isWatertight,
            bounds: Bounds3D(
                min: Vec3(x: minX, y: minY, z: minZ),
                max: Vec3(x: maxX, y: maxY, z: maxZ)
            )
        )
    }

    private func boxGeometry(
        xLo: Double,
        xHi: Double,
        zLo: Double,
        zHi: Double
    ) -> MeshGeometryData {
        let yLo = 0.0
        let yHi = 40.0
        let vertices = [
            Vec3(x: xLo, y: yLo, z: zLo), Vec3(x: xHi, y: yLo, z: zLo),
            Vec3(x: xHi, y: yHi, z: zLo), Vec3(x: xLo, y: yHi, z: zLo),
            Vec3(x: xLo, y: yLo, z: zHi), Vec3(x: xHi, y: yLo, z: zHi),
            Vec3(x: xHi, y: yHi, z: zHi), Vec3(x: xLo, y: yHi, z: zHi),
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

    private func mergedGeometry(_ geometries: [MeshGeometryData]) -> MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        for geometry in geometries {
            let offset = Int32(vertices.count)
            vertices.append(contentsOf: geometry.vertices)
            indices.append(contentsOf: geometry.triangleIndices.map { $0 + offset })
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private func fourQuadrantParts() throws -> [MotherMoldPart] {
        let specs: [(String, Double, Double)] = [
            ("A", -10, -10), ("B", 10, -10),
            ("C", -10, 10), ("D", 10, 10),
        ]
        return try specs.map { name, x, y in
            let handle = try ManifoldEngine.box(ManifoldBoxSpec(
                center: Vec3(x: x, y: y, z: 0),
                extents: Vec3(x: 20, y: 20, z: 20)
            ))
            let geometry = try ManifoldEngine.toMesh(handle)
            withExtendedLifetime(handle) {}
            return part(name: name, geometry: geometry)
        }
    }

    private func fourPartParts(
        firstNormal: Vec3,
        secondNormal: Vec3
    ) -> [MotherMoldPart] {
        let firstAxis = axisIndex(for: firstNormal)
        let secondAxis = axisIndex(for: secondNormal)
        let remainingAxis = Set(0...2).subtracting([firstAxis, secondAxis]).first!
        var parts: [MotherMoldPart] = []
        for firstSign in [-1.0, 1.0] {
            for secondSign in [-1.0, 1.0] {
                var minimum = Vec3(x: -10, y: -10, z: -10)
                var maximum = Vec3(x: 10, y: 10, z: 10)
                setAxis(firstAxis, sign: firstSign, minimum: &minimum, maximum: &maximum)
                setAxis(secondAxis, sign: secondSign, minimum: &minimum, maximum: &maximum)
                setAxis(remainingAxis, sign: 0, minimum: &minimum, maximum: &maximum)
                let geometry = boxGeometry(minimum: minimum, maximum: maximum)
                let firstLabel = firstSign > 0 ? "+" : "-"
                let secondLabel = secondSign > 0 ? "+" : "-"
                parts.append(part(
                    name: "\(firstAxis)\(firstLabel)-\(secondAxis)\(secondLabel)",
                    geometry: geometry
                ))
            }
        }
        return parts
    }

    private func axisIndex(for normal: Vec3) -> Int {
        if abs(normal.x) == 1 { return 0 }
        if abs(normal.y) == 1 { return 1 }
        return 2
    }

    private func setAxis(
        _ axis: Int,
        sign: Double,
        minimum: inout Vec3,
        maximum: inout Vec3
    ) {
        let low = sign < 0 ? -20.0 : (sign > 0 ? 0.0 : -10.0)
        let high = sign < 0 ? 0.0 : (sign > 0 ? 20.0 : 10.0)
        switch axis {
        case 0: minimum.x = low; maximum.x = high
        case 1: minimum.y = low; maximum.y = high
        default: minimum.z = low; maximum.z = high
        }
    }

    private func boxGeometry(minimum: Vec3, maximum: Vec3) -> MeshGeometryData {
        let vertices = [
            Vec3(x: minimum.x, y: minimum.y, z: minimum.z), Vec3(x: maximum.x, y: minimum.y, z: minimum.z),
            Vec3(x: maximum.x, y: maximum.y, z: minimum.z), Vec3(x: minimum.x, y: maximum.y, z: minimum.z),
            Vec3(x: minimum.x, y: minimum.y, z: maximum.z), Vec3(x: maximum.x, y: minimum.y, z: maximum.z),
            Vec3(x: maximum.x, y: maximum.y, z: maximum.z), Vec3(x: minimum.x, y: maximum.y, z: maximum.z),
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

    private func unionedGeometry(
        _ first: MeshGeometryData,
        _ second: MeshGeometryData
    ) throws -> MeshGeometryData {
        let firstHandle = try ManifoldEngine.make(from: first)
        let secondHandle = try ManifoldEngine.make(from: second)
        let union = try ManifoldEngine.union(firstHandle, secondHandle)
        let geometry = try ManifoldEngine.toMesh(union)
        withExtendedLifetime(firstHandle) {}
        withExtendedLifetime(secondHandle) {}
        withExtendedLifetime(union) {}
        return geometry
    }

    private func subtractedGeometry(
        _ base: MeshGeometryData,
        _ tool: MeshGeometryData
    ) throws -> MeshGeometryData {
        let baseHandle = try ManifoldEngine.make(from: base)
        let toolHandle = try ManifoldEngine.make(from: tool)
        let difference = try ManifoldEngine.difference(baseHandle, toolHandle)
        let geometry = try ManifoldEngine.toMesh(difference)
        withExtendedLifetime(baseHandle) {}
        withExtendedLifetime(toolHandle) {}
        withExtendedLifetime(difference) {}
        return geometry
    }

    private func replacingPart(
        named name: String,
        geometry: MeshGeometryData,
        in parts: [MotherMoldPart]
    ) -> [MotherMoldPart] {
        parts.map { part in
            part.name == name ? self.part(name: name, geometry: geometry) : part
        }
    }
}
