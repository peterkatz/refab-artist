import XCTest
@testable import RefabArtist

final class ProtectedToolingAuditSetTests: XCTestCase {
    func testOneDamagedAdditiveFailsEvenWhenCombinedRetentionPasses() throws {
        let retained = try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let damaged = try cube(min: Vec3(x: 20, y: 0, z: 0), max: Vec3(x: 30, y: 10, z: 10))
        let set = try ProtectedToolingAuditSet(records: [
            additive(id: "collar", geometry: retained),
            additive(id: "liner-housing", geometry: damaged),
        ])
        let finalParts = [part("shell-A", retained)]

        let result = set.audit(finalParts: finalParts, stage: .finalNormalization)

        XCTAssertFalse(result.passes)
        XCTAssertEqual(result.evidence.count, 2)
        XCTAssertTrue(result.evidence.contains { $0.id == "collar" && $0.passes })
        XCTAssertTrue(result.evidence.contains { $0.id == "liner-housing" && !$0.passes })
        XCTAssertTrue(result.diagnostics.joined(separator: " ").contains("liner-housing"))
    }

    func testSubtractiveReceiverBlockageFailsIndependently() throws {
        let receiver = try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let blockingPart = part("shell-A", try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 5, y: 10, z: 10)))
        let set = try ProtectedToolingAuditSet(records: [
            .init(
                id: "post-receiver",
                kind: .postReceiver,
                behavior: .subtractive,
                ownership: .singlePart("shell-A"),
                geometry: receiver,
                requiredRetention: 1,
                requiredClearance: 0.98,
                provenance: [.fixture]
            ),
        ])

        let result = set.audit(finalParts: [blockingPart], stage: .finalNormalization)

        XCTAssertFalse(result.passes)
        let evidence = try XCTUnwrap(result.evidence.first)
        XCTAssertEqual(evidence.finalVoidFraction ?? -1, 0.5, accuracy: 0.01)
        XCTAssertFalse(evidence.passes)
        XCTAssertTrue(evidence.failure?.contains("occupied") == true)
    }

    func testOwnershipMismatchFailsEvenWhenGeometrySurvives() throws {
        let collar = try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let set = try ProtectedToolingAuditSet(records: [
            .init(
                id: "collar",
                kind: .collar,
                behavior: .additive,
                ownership: .singlePart("shell-A"),
                geometry: collar,
                requiredRetention: 0.98,
                provenance: [.fixture]
            ),
        ])

        let result = set.audit(finalParts: [part("shell-B", collar)], stage: .finalNormalization)

        XCTAssertFalse(result.passes)
        XCTAssertTrue(result.evidence[0].failure?.contains("ownership") == true)
    }

    func testUndamagedFeaturesSurviveFlangeKeyAndFinalNormalization() throws {
        let whole = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 20, z: 20)
        ))
        let plane = PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 0, isManual: false)
        let halves = try ManifoldEngine.splitByPlane(whole, normal: plane.normal, offset: plane.offset)
        let parts = try [halves.0, halves.1].enumerated().map { index, handle in
            part("shell-\(index)", try ManifoldEngine.toMesh(handle))
        }
        defer {
            withExtendedLifetime(whole) {}
            withExtendedLifetime(halves) {}
        }
        let additiveGeometry = try cube(min: Vec3(x: -8, y: -2, z: -2), max: Vec3(x: -4, y: 2, z: 2))
        let voidGeometry = try cube(min: Vec3(x: 10, y: 0, z: 0), max: Vec3(x: 14, y: 4, z: 4))
        let set = try ProtectedToolingAuditSet(records: [
            .init(
                id: "fixture-collar",
                kind: .collar,
                behavior: .additive,
                ownership: .assembly,
                geometry: additiveGeometry,
                requiredRetention: 0.98,
                provenance: [.fixture]
            ),
            .init(
                id: "key-pocket",
                kind: .shellKeyPocket,
                behavior: .subtractive,
                ownership: .assembly,
                geometry: voidGeometry,
                requiredRetention: 1,
                requiredClearance: 0.98,
                provenance: [.key]
            ),
        ])
        let flanged = try MoldFlangeBuilder.applyFlanges(
            parts: parts,
            planes: [plane],
            flange: .defaultValue,
            cavity: MeshGeometryData(vertices: [], triangleIndices: []),
            seed: 0,
            protectedAuditSet: set
        )
        XCTAssertFalse(flanged.diagnostics.contains { $0.severity == .error }, flanged.diagnostics.map(\.message).joined(separator: " | "))
        let keyed = try MoldKeyBuilder.applyKeys(
            parts: flanged.parts,
            planes: [plane],
            key: .defaultValue,
            protectedAuditSet: try XCTUnwrap(flanged.protectedAuditSet)
        )
        XCTAssertFalse(keyed.diagnostics.contains { $0.severity == .error }, keyed.diagnostics.map(\.message).joined(separator: " | "))
        let result = MotherMoldValidation.validate(
            parts: keyed.parts,
            protectedAuditSet: try XCTUnwrap(keyed.protectedAuditSet)
        )

        XCTAssertTrue(result.passes, result.diagnostics.map(\.message).joined(separator: " | "))
        XCTAssertTrue(result.protectedAudit?.evidence.allSatisfy { $0.stage == .finalNormalization } == true)
    }

    func testAuthorizedFlowCutRebasesOnlyItsExactRemovedProfile() throws {
        let original = try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let authorized = try cube(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 2, y: 10, z: 10))
        let unauthorized = try cube(min: Vec3(x: 8, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let initial = try ProtectedToolingAuditSet(records: [additive(id: "collar", geometry: original)])
        let cut = ProtectedToolingAuditSet.Record(
            id: "liner-fill-port",
            kind: .linerFillPath,
            behavior: .subtractive,
            ownership: .singlePart("shell-A"),
            geometry: authorized,
            requiredRetention: 1,
            requiredClearance: 0.98,
            provenance: [.flow]
        )
        let rebased = try initial.authorizingSubtractiveCuts([cut])
        let authorizedFinal = try difference(original, authorized)
        XCTAssertTrue(rebased.audit(finalParts: [part("shell-A", authorizedFinal)], stage: .flow).passes)

        let damagedFinal = try difference(authorizedFinal, unauthorized)
        let damagedAudit = rebased.audit(finalParts: [part("shell-A", damagedFinal)], stage: .finalNormalization)
        XCTAssertFalse(damagedAudit.passes)
        XCTAssertTrue(damagedAudit.diagnostics.joined(separator: " ").contains("collar"))
    }

    private func additive(
        id: String,
        geometry: MeshGeometryData,
        provenance: Set<ProtectedToolingAuditSet.Stage> = [.fixture]
    ) -> ProtectedToolingAuditSet.Record {
        .init(
            id: id,
            kind: .collar,
            behavior: .additive,
            ownership: .singlePart("shell-A"),
            geometry: geometry,
            requiredRetention: 0.98,
            provenance: provenance
        )
    }

    private func part(_ name: String, _ geometry: MeshGeometryData) -> MotherMoldPart {
        MotherMoldPart(name: name, geometry: geometry, isWatertight: true)
    }

    private func cube(min: Vec3, max: Vec3) throws -> MeshGeometryData {
        let handle = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: (min.x + max.x) / 2, y: (min.y + max.y) / 2, z: (min.z + max.z) / 2),
            extents: Vec3(x: max.x - min.x, y: max.y - min.y, z: max.z - min.z)
        ))
        defer { withExtendedLifetime(handle) {} }
        return try ManifoldEngine.toMesh(handle)
    }

    private func difference(_ lhs: MeshGeometryData, _ rhs: MeshGeometryData) throws -> MeshGeometryData {
        try ManifoldEngine.toMesh(try ManifoldEngine.difference(
            try ManifoldEngine.make(from: lhs),
            try ManifoldEngine.make(from: rhs)
        ))
    }
}
