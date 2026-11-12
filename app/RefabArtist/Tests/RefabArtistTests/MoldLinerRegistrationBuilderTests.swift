import XCTest
@testable import RefabArtist

final class MoldLinerRegistrationBuilderTests: XCTestCase {
    func testAutomaticButtonsHaveExactPerPartCountsAndFormulaDimensions() throws {
        var input = try twoPartInput()
        input.settings = LinerRegistrationSettings(mode: .automatic, buttonsPerPart: 2, gateLipEnabled: false)
        let result = try MoldLinerRegistrationBuilder.build(input)

        XCTAssertEqual(result.sites.count, 4)
        XCTAssertEqual(Dictionary(grouping: result.sites, by: \.shellPartID).mapValues(\.count), [ToolingArtifactID("left"): 2, ToolingArtifactID("right"): 2])
        XCTAssertTrue(result.sites.allSatisfy { $0.diameterMillimeters == 15 && $0.depthMillimeters == 3.6 })
        XCTAssertTrue(result.sites.allSatisfy { abs($0.center.z) < 0.000_001 }, "Buttons must start on the supplied nominal liner surface, not a guessed offset from it.")
        XCTAssertEqual(result.summary.state, .geometryVerified)
        XCTAssertEqual(result.siliconeAdditives.filter { $0.purpose.contains("registration") }.count, 4)
    }

    func testSitesAreOwnedSpacedDistributedAndClearReservedFeatures() throws {
        let input = try twoPartInput(reservedCenter: true)
        let result = try MoldLinerRegistrationBuilder.build(input)
        let sites = result.sites
        for first in sites.indices {
            for second in sites.indices where second > first {
                XCTAssertGreaterThanOrEqual(distance(sites[first].center, sites[second].center), 22.5 - 0.001)
            }
        }
        XCTAssertTrue(sites.allSatisfy { abs($0.center.x) > 18 })
        for partID in [ToolingArtifactID("left"), ToolingArtifactID("right")] {
            let local = sites.filter { $0.shellPartID == partID }
            XCTAssertGreaterThanOrEqual((local.map(\.center.x).max() ?? 0) - (local.map(\.center.x).min() ?? 0), 30)
            XCTAssertGreaterThanOrEqual((local.map(\.center.y).max() ?? 0) - (local.map(\.center.y).min() ?? 0), 30)
        }
    }

    func testHousingRecessAndConfiguredBackingSurvive() throws {
        let input = try twoPartInput()
        let result = try MoldLinerRegistrationBuilder.build(input)
        XCTAssertTrue(result.shellParts.allSatisfy { $0.part.isWatertight })
        assertPartIdentity(result.shellParts, matches: input.finalShellParts)
        assertStrictlyPrintable(result.shellParts)
        XCTAssertTrue(result.protectedRegions.allSatisfy { $0.purpose == .registration })
        XCTAssertNotEqual(result.shellParts.map(\.part.geometry), input.finalShellParts.map(\.part.geometry))
    }

    func testCapturedGateLipIsSplitAndHasReleaseSealDatum() throws {
        var input = try twoPartInput()
        let plane = try XCTUnwrap(input.partingPlanes.first)
        input.settings = LinerRegistrationSettings(mode: .buttonsAndGateLip, buttonsPerPart: 1, gateLipEnabled: true)
        input.gateLipDatum = MoldLinerRegistrationGateLipDatum(
            collarSolid: try box(center: Vec3(x: 0, y: 0, z: 4), extents: Vec3(x: 24, y: 24, z: 8)),
            linerSealPoint: Vec3Codable(x: 0, y: 0, z: 0),
            rigidStopContactPoint: Vec3Codable(x: 0, y: 0, z: 4),
            axis: Vec3Codable(x: 0, y: 0, z: 1),
            gateDiameter: 8, splitPartingPlaneID: plane.id
        )
        let result = try MoldLinerRegistrationBuilder.build(input)
        let lip = try XCTUnwrap(result.gateLip)
        XCTAssertEqual(lip.splitPlaneID, plane.id)
        XCTAssertEqual(lip.lipSegments.count, 2)
        XCTAssertGreaterThan(lip.funnelSeal.bead.vertices.count, 0)
        XCTAssertEqual(lip.funnelSeal.releaseAxis, Vec3Codable(x: 0, y: 0, z: 1))
        XCTAssertEqual(lip.funnelSeal.sealContactPoint, Vec3Codable(x: 0, y: 0, z: 0))
        XCTAssertEqual(lip.funnelSeal.stopContactPoint, Vec3Codable(x: 0, y: 0, z: 4))
        XCTAssertLessThan(lip.funnelSeal.sealContactPoint.z, lip.funnelSeal.stopContactPoint.z)
        XCTAssertEqual(axialMaximum(of: lip.funnelSeal.bead), lip.funnelSeal.sealContactPoint.z, accuracy: 0.000_001)
        XCTAssertEqual(axialMinimum(of: lip.funnelSeal.compressionStop), lip.funnelSeal.sealContactPoint.z, accuracy: 0.000_001)
        XCTAssertEqual(axialMaximum(of: lip.funnelSeal.compressionStop), lip.funnelSeal.stopContactPoint.z, accuracy: 0.000_001)
        assertPartIdentity(result.shellParts, matches: input.finalShellParts)
        assertStrictlyPrintable(result.shellParts)
        assertNoPositiveVolumeOverlap(result.shellParts)
    }

    func testOrganicFacetedSurfaceIsDeterministicAndSupportsExplicitOverride() throws {
        var input = try twoPartInput(surface: organicSurface())
        input.buttonOverride = MoldLinerRegistrationButtonDimensions(diameter: 12, depth: 4, draftDegrees: 12)
        let first = try MoldLinerRegistrationBuilder.build(input)
        let second = try MoldLinerRegistrationBuilder.build(input)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.sites.allSatisfy { $0.diameterMillimeters == 12 && $0.depthMillimeters == 4 })
    }

    func testDisabledModeLeavesPartsUntouched() throws {
        var input = try twoPartInput()
        input.settings = LinerRegistrationSettings(mode: .none, gateLipEnabled: false)
        let result = try MoldLinerRegistrationBuilder.build(input)
        XCTAssertEqual(result.shellParts, input.finalShellParts)
        XCTAssertEqual(result.summary.state, .disabled)
        XCTAssertTrue(result.sites.isEmpty)
    }

    func testUnplaceablePartRollsBackEntireTransaction() throws {
        var input = try twoPartInput()
        input.settings = LinerRegistrationSettings(mode: .automatic, buttonsPerPart: 2, gateLipEnabled: false)
        input.reservedGeometry = MoldLinerRegistrationReservedGeometry(
            collar: [MoldLinerRegistrationReservedFeature(id: "block-right", kind: .collar, solid: try box(center: Vec3(x: 30, y: 0, z: 1), extents: Vec3(x: 55, y: 120, z: 20)))]
        )
        let original = input.finalShellParts
        XCTAssertThrowsError(try MoldLinerRegistrationBuilder.build(input)) { error in
            XCTAssertEqual(error as? MoldLinerRegistrationBuilderError, .requestedButtonsUnplaceable(partID: ToolingArtifactID("right"), requested: 2, placed: 0))
        }
        XCTAssertEqual(input.finalShellParts, original)
    }

    func testEnabledLipWithoutTypedDatumBlocks() throws {
        var input = try twoPartInput()
        input.settings = LinerRegistrationSettings(mode: .buttonsAndGateLip, buttonsPerPart: 0, gateLipEnabled: true)
        XCTAssertThrowsError(try MoldLinerRegistrationBuilder.build(input)) { error in
            XCTAssertEqual(error as? MoldLinerRegistrationBuilderError, .missingGateLipDatum)
        }
    }

    private func twoPartInput(surface: MeshGeometryData? = nil, reservedCenter: Bool = false) throws -> MoldLinerRegistrationInput {
        let left = try shell(id: "left", minimum: Vec3(x: -70, y: -60, z: 0), maximum: Vec3(x: 0, y: 60, z: 3))
        let right = try shell(id: "right", minimum: Vec3(x: 0, y: -60, z: 0), maximum: Vec3(x: 70, y: 60, z: 3))
        let reserved = reservedCenter ? MoldLinerRegistrationReservedGeometry(
            collar: [MoldLinerRegistrationReservedFeature(id: "collar", kind: .collar, solid: try box(center: Vec3(x: 0, y: 0, z: 2), extents: Vec3(x: 20, y: 120, z: 12)))]
        ) : MoldLinerRegistrationReservedGeometry()
        return MoldLinerRegistrationInput(
            finalShellParts: [left, right], nominalLinerSurface: surface ?? gridSurface(), totalLinerOffset: 6,
            settings: LinerRegistrationSettings(mode: .automatic, buttonsPerPart: 2, gateLipEnabled: false), wallThickness: 4,
            partingPlanes: [PartitionPlane(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, normal: Vec3(x: 1, y: 0, z: 0), offset: 0, isManual: false)],
            reservedGeometry: reserved
        )
    }

    private func shell(id: String, minimum: Vec3, maximum: Vec3) throws -> MoldLinerRegistrationShellPart {
        let geometry = try box(minimum: minimum, maximum: maximum)
        return MoldLinerRegistrationShellPart(id: ToolingArtifactID(id), part: MotherMoldPart(name: id, geometry: geometry, isWatertight: true), demoldAxis: Vec3Codable(x: 0, y: 0, z: 1))
    }

    private func gridSurface() -> MeshGeometryData {
        let values: [Double] = [-55, -35, -25, 15, 25, 35, 55]
        var vertices: [Vec3] = []
        for y in values { for x in values { vertices.append(Vec3(x: x, y: y, z: 0)) } }
        var indices: [Int32] = []
        for y in 0..<(values.count - 1) {
            for x in 0..<(values.count - 1) {
                let a = y * values.count + x, b = a + 1, c = a + values.count, d = c + 1
                indices += [Int32(a), Int32(b), Int32(c), Int32(b), Int32(d), Int32(c)]
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private func organicSurface() -> MeshGeometryData {
        var surface = gridSurface()
        surface.vertices = surface.vertices.map { vertex in
            Vec3(x: vertex.x, y: vertex.y, z: 1.5 * sin(vertex.x / 18) * cos(vertex.y / 23))
        }
        return surface
    }

    private func box(minimum: Vec3, maximum: Vec3) throws -> MeshGeometryData {
        try box(center: Vec3(x: (minimum.x + maximum.x) / 2, y: (minimum.y + maximum.y) / 2, z: (minimum.z + maximum.z) / 2), extents: Vec3(x: maximum.x - minimum.x, y: maximum.y - minimum.y, z: maximum.z - minimum.z))
    }

    private func box(center: Vec3, extents: Vec3) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(ManifoldEngine.box(ManifoldBoxSpec(center: center, extents: extents)))
    }

    private func distance(_ a: Vec3Codable, _ b: Vec3Codable) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func axialMinimum(of mesh: MeshGeometryData) -> Double {
        mesh.vertices.map(\.z).min() ?? .infinity
    }

    private func axialMaximum(of mesh: MeshGeometryData) -> Double {
        mesh.vertices.map(\.z).max() ?? -.infinity
    }

    private func assertStrictlyPrintable(_ parts: [MoldLinerRegistrationShellPart]) {
        for shellPart in parts {
            let preflight = MeshPreflight.analyze(geometry: shellPart.part.geometry)
            XCTAssertTrue(preflight.isWatertight, shellPart.id.rawValue)
            XCTAssertEqual(preflight.degenerateTriangleCount, 0, shellPart.id.rawValue)
            XCTAssertEqual(preflight.nonManifoldEdgeCount, 0, shellPart.id.rawValue)
            XCTAssertEqual(preflight.boundaryEdgeCount, 0, shellPart.id.rawValue)
        }
    }

    private func assertNoPositiveVolumeOverlap(_ parts: [MoldLinerRegistrationShellPart]) {
        for firstIndex in parts.indices {
            for secondIndex in parts.indices where secondIndex > firstIndex {
                do {
                    let first = try ManifoldEngine.make(from: parts[firstIndex].part.geometry)
                    let second = try ManifoldEngine.make(from: parts[secondIndex].part.geometry)
                    let overlap = try ManifoldEngine.intersect(first, second)
                    XCTAssertLessThanOrEqual(
                        abs(ManifoldEngine.volume(overlap)),
                        0.01,
                        "\(parts[firstIndex].id.rawValue)/\(parts[secondIndex].id.rawValue)"
                    )
                } catch {
                    XCTFail("Could not measure shell overlap: \(error)")
                }
            }
        }
    }

    private func assertPartIdentity(
        _ actual: [MoldLinerRegistrationShellPart],
        matches expected: [MoldLinerRegistrationShellPart]
    ) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id))
        XCTAssertEqual(actual.map(\.demoldAxis), expected.map(\.demoldAxis))
    }
}
