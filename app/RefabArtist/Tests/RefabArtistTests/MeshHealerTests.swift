import XCTest
@testable import RefabArtist

/// Tests for the GWN-signed-distance MeshHealer. Validates (a) the fast winding
/// number gives the right inside/outside sign on a known closed mesh, and (b)
/// healing a watertight fixture and the real non-watertight hand both produce a
/// watertight solid whose bounds ≈ the source (NOT inflated) in reasonable time.
final class MeshHealerTests: XCTestCase {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func fixture(_ relative: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/\(relative)"))
    }

    // MARK: - Fast winding number sign correctness

    /// On the closed sphere fixture, the EXACT winding number must read +1 inside
    /// (this locks the leaf solid-angle sign / triangle orientation), and the
    /// fast Barnes-Hut winding must agree with it in SIGN at every test point —
    /// the heal only depends on `w > 0.5` inside vs outside being correct, so the
    /// sign agreement (not the deep-interior magnitude) is the real invariant.
    func testWindingNumberSignOnClosedSphere() throws {
        let mesh = try Self.fixture("sphere_d50mm.stl").geometry
        let soup = TriangleSoup(mesh)
        let tree = FastWindingTree(soup)

        let c = Vec3(
            x: (soup.bounds.min.x + soup.bounds.max.x) / 2,
            y: (soup.bounds.min.y + soup.bounds.max.y) / 2,
            z: (soup.bounds.min.z + soup.bounds.max.z) / 2
        )
        let r = (soup.bounds.max.x - soup.bounds.min.x) / 2

        // Exact winding is +1 at the center (outward orientation locked).
        XCTAssertEqual(tree.exactWindingNumber(at: c), 1.0, accuracy: 0.05,
                       "exact winding at center should be +1 (outward normals)")

        // Sign agreement across interior + exterior probes.
        let interior: [Vec3] = [
            c,
            Vec3(x: c.x + r * 0.5, y: c.y, z: c.z),
            Vec3(x: c.x, y: c.y - r * 0.6, z: c.z),
            Vec3(x: c.x + r * 0.3, y: c.y + r * 0.3, z: c.z + r * 0.3),
        ]
        for p in interior {
            XCTAssertGreaterThan(tree.windingNumber(at: p), 0.5,
                                 "BH winding should be > 0.5 inside at \(p)")
        }
        let exterior: [Vec3] = [
            Vec3(x: c.x + r * 100, y: c.y, z: c.z),
            Vec3(x: c.x, y: c.y + r * 3, z: c.z),
            Vec3(x: c.x - r * 2, y: c.y - r * 2, z: c.z),
        ]
        for p in exterior {
            XCTAssertLessThan(tree.windingNumber(at: p), 0.5,
                              "BH winding should be < 0.5 outside at \(p)")
        }
    }

    // MARK: - solidify routes an OPEN mesh through the heal branch

    /// A cube with one face removed is NOT watertight, so it must fail Manifold's
    /// fast path; `solidify` then heals it (GWN -> level_set) into a watertight
    /// solid of ≈ the same bounds. This proves the integration heal branch fires
    /// for a genuinely open mesh (cheap, no large model needed).
    func testSolidifyHealsOpenCube() throws {
        let open = Self.openCube(side: 20)

        // Fast path must reject (open boundary -> not a closed manifold).
        let fast = try? ManifoldEngine.make(from: StructureClipEngine.welded(open))
        if let fast {
            XCTAssertFalse(ManifoldEngine.isWatertight(fast),
                           "open cube unexpectedly watertight on fast path")
        }

        // solidify recovers a watertight solid via the heal.
        let solid = try StructureClipEngine.solidify(source: open)
        XCTAssertTrue(ManifoldEngine.isWatertight(solid), "open cube not healed watertight")

        let b = ManifoldEngine.bounds(solid)
        // ≈ [0,20]^3, within a couple of voxels (heal default edge ≈ side/90·√3).
        let tol = 2.0
        XCTAssertEqual(b.min.x, 0, accuracy: tol); XCTAssertEqual(b.max.x, 20, accuracy: tol)
        XCTAssertEqual(b.min.y, 0, accuracy: tol); XCTAssertEqual(b.max.y, 20, accuracy: tol)
        XCTAssertEqual(b.min.z, 0, accuracy: tol); XCTAssertEqual(b.max.z, 20, accuracy: tol)
    }

    /// Axis-aligned cube [0,side]^3 with the top (+z) face omitted -> open mesh.
    private static func openCube(side s: Double) -> MeshGeometryData {
        let v: [Vec3] = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0),
            Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s),
            Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s),
        ]
        // 5 faces (bottom + 4 sides), top omitted; outward winding.
        let q: [(Int, Int, Int, Int)] = [
            (0, 3, 2, 1),  // bottom (-z)
            (0, 1, 5, 4),  // -y
            (1, 2, 6, 5),  // +x
            (2, 3, 7, 6),  // +y
            (3, 0, 4, 7),  // -x
        ]
        var idx: [Int32] = []
        for (a, b, c, d) in q {
            idx += [Int32(a), Int32(b), Int32(c), Int32(a), Int32(c), Int32(d)]
        }
        return MeshGeometryData(vertices: v, triangleIndices: idx)
    }

    // MARK: - Heal a watertight fixture (sanity; bounds ≈ source)

    func testHealWatertightSphereBoundsNotInflated() throws {
        let model = try Self.fixture("sphere_d50mm.stl")
        let result = try MeshHealer.heal(model.geometry)

        XCTAssertTrue(ManifoldEngine.isWatertight(result.handle), "healed sphere not watertight")

        // Bounds ≈ source: each face within ~1.5 voxels (no inflation).
        let tol = result.edgeLength * 1.5
        assertBoundsClose(result.healedBounds, result.sourceBounds, tol: tol)
    }

    // MARK: - Real organic hand (the gate)

    /// The non-watertight ZBrush hand: heal -> watertight, bounds ≈ source (NOT
    /// inflated), and finishes well under a minute. Skipped if the file is absent
    /// (it is committed under app/RefabArtist/Tests/Fixtures/hand-scans/).
    func testHealHandIsWatertightNotInflatedAndFast() throws {
        // Slow (GWN heal of a 59k-face mesh). Opt-in only — the non-inflation + sign
        // checks run fast on the sphere/open-cube fixtures in the normal suite.
        guard ProcessInfo.processInfo.environment["STRUCTURE_HEAL_HAND"] != nil else {
            throw XCTSkip("set STRUCTURE_HEAL_HAND=1 to run the slow real-hand heal test")
        }
        let url = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("hand fixture not present at \(url.path)")
        }
        let model = try MeshInspector.inspect(url: url)
        let source = try XCTUnwrap(model.bounds)

        let result = try MeshHealer.heal(model.geometry)

        XCTAssertTrue(ManifoldEngine.isWatertight(result.handle),
                      "healed hand not watertight")
        XCTAssertLessThan(result.elapsed, 60.0,
                          "heal took \(result.elapsed)s (target < 60s)")

        // Bounds must NOT be inflated: the healed AABB stays within a couple of
        // voxels of the source on every face. An unsigned "band" heal would push
        // every face out by ~half a voxel AND grow thin features — this asserts
        // we did neither.
        let tol = max(result.edgeLength * 2.0, source.max.x * 0)  // ~2 voxels
        XCTAssertGreaterThanOrEqual(result.healedBounds.min.x, source.min.x - tol)
        XCTAssertGreaterThanOrEqual(result.healedBounds.min.y, source.min.y - tol)
        XCTAssertGreaterThanOrEqual(result.healedBounds.min.z, source.min.z - tol)
        XCTAssertLessThanOrEqual(result.healedBounds.max.x, source.max.x + tol)
        XCTAssertLessThanOrEqual(result.healedBounds.max.y, source.max.y + tol)
        XCTAssertLessThanOrEqual(result.healedBounds.max.z, source.max.z + tol)

        // And it must actually fill the body, not collapse to a sliver: the
        // healed extents are within ~10% of the source extents on each axis.
        let se = extent(source), he = extent(result.healedBounds)
        XCTAssertEqual(he.x, se.x, accuracy: se.x * 0.1, "x extent off")
        XCTAssertEqual(he.y, se.y, accuracy: se.y * 0.1, "y extent off")
        XCTAssertEqual(he.z, se.z, accuracy: se.z * 0.1, "z extent off")
    }

    /// Render-gate helper: dumps the SOURCE and HEALED hand to STL so they can be
    /// rendered and visually compared (no inflation, fingers preserved). Skipped
    /// unless MESH_HEAL_DUMP=<dir> is set.
    func testDumpHealedHandForRenderGate() throws {
        guard let dir = ProcessInfo.processInfo.environment["MESH_HEAL_DUMP"] else {
            throw XCTSkip("set MESH_HEAL_DUMP=<dir> to dump healed STL for the render gate")
        }
        let url = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("hand fixture not present")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        let model = try MeshInspector.inspect(url: url)

        let result = try MeshHealer.heal(model.geometry)
        let healedMesh = try ManifoldEngine.toMesh(result.handle)
        try StlExporter.write(
            meshes: [ViewportMeshRenderData.flatShadedMesh(from: healedMesh)],
            to: out.appending(path: "heal_hand_healed.stl"),
            solidName: "heal_hand_healed"
        )
        try StlExporter.write(
            meshes: [ViewportMeshRenderData.flatShadedMesh(from: model.geometry)],
            to: out.appending(path: "heal_hand_source.stl"),
            solidName: "heal_hand_source"
        )
    }

    // MARK: - Helpers

    private func extent(_ b: Bounds3D) -> Vec3 {
        Vec3(x: b.max.x - b.min.x, y: b.max.y - b.min.y, z: b.max.z - b.min.z)
    }

    private func assertBoundsClose(_ a: Bounds3D, _ b: Bounds3D, tol: Double) {
        XCTAssertEqual(a.min.x, b.min.x, accuracy: tol)
        XCTAssertEqual(a.min.y, b.min.y, accuracy: tol)
        XCTAssertEqual(a.min.z, b.min.z, accuracy: tol)
        XCTAssertEqual(a.max.x, b.max.x, accuracy: tol)
        XCTAssertEqual(a.max.y, b.max.y, accuracy: tol)
        XCTAssertEqual(a.max.z, b.max.z, accuracy: tol)
    }
}
