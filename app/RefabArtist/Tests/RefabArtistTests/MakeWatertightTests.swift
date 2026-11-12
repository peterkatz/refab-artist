import Foundation
import Testing
@testable import RefabArtist

/// Tests for the Modify Form "Make Watertight" tool (`MeshModifier.shrinkwrap`),
/// rewired to the GWN signed-distance MeshHealer. The defining property — the
/// OPPOSITE of the retired voxel shrinkwrap — is that healing a non-watertight
/// mesh yields a watertight solid whose BOUNDS are NOT inflated (≈ source within
/// a small tolerance). All fixtures are analytic; the one real-mesh case is
/// gated behind an env var like the Structures heal tests.
struct MakeWatertightTests {

    // MARK: - Fixtures

    private static func summary(name: String, vertices: [Vec3], indices: [Int32]) -> MeshSummary {
        let geo = MeshGeometryData(vertices: vertices, triangleIndices: indices)
        let preflight = MeshPreflight.analyze(geometry: geo)
        var minV = vertices.first ?? Vec3(x: 0, y: 0, z: 0)
        var maxV = minV
        for v in vertices {
            minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
            maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
        }
        return MeshSummary(
            name: name,
            path: "",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: vertices.count,
            faceCount: indices.count / 3,
            triangleCount: indices.count / 3,
            bounds: vertices.isEmpty ? nil : Bounds3D(min: minV, max: maxV),
            geometry: geo,
            preflight: preflight
        )
    }

    /// Axis-aligned cube [0,side]^3 with the top (+z) face omitted -> an OPEN,
    /// non-watertight mesh (5 faces, outward winding). Mirrors the open-cube
    /// fixture used by MeshHealerTests so the engine sees a genuinely holey input.
    private static func makeOpenCube(side s: Double = 20.0) -> MeshSummary {
        let v: [Vec3] = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0),
            Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s),
            Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s),
        ]
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
        return summary(name: "open-cube", vertices: v, indices: idx)
    }

    private static func extents(_ b: Bounds3D) -> Vec3 {
        Vec3(x: b.max.x - b.min.x, y: b.max.y - b.min.y, z: b.max.z - b.min.z)
    }

    // MARK: - The core invariant: watertight, bounds NOT inflated

    /// Healing an OPEN cube must close it into a watertight solid whose AABB
    /// stays within a couple of voxels of the source on every face. This is the
    /// opposite of the retired voxel shrinkwrap, which pushed the surface OUT
    /// ~1–2 voxels and grew the bounds.
    @Test
    func makeWatertightClosesOpenMeshWithoutInflating() throws {
        let side = 20.0
        let open = Self.makeOpenCube(side: side)
        #expect(open.preflight.boundaryEdgeCount > 0,
                "fixture must start with an open boundary")

        let result = MeshModifier.shrinkwrap(open, detail: 0.5)

        // Closed + 2-manifold.
        #expect(result.preflight.isWatertight, "heal must emit a watertight solid")
        #expect(result.preflight.boundaryEdgeCount == 0, "no open edges after heal")
        #expect(result.preflight.nonManifoldEdgeCount == 0, "no non-manifold edges after heal")
        #expect(result.triangleCount > 12, "heal must produce a real remeshed surface")

        // Bounds ≈ source on every face: NOT inflated. The source is [0,side]^3.
        let healed = try #require(result.bounds)
        // Heal edge ≈ side·√3 / divisions; allow ~2.5 voxels of slack per face.
        let diag = side * 3.0.squareRoot()
        let edge = min(max(diag / (45.0 + 0.5 * 115.0), 0.3), 4.0)
        let tol = edge * 2.5

        #expect(healed.min.x >= 0 - tol && healed.max.x <= side + tol, "X face inflated")
        #expect(healed.min.y >= 0 - tol && healed.max.y <= side + tol, "Y face inflated")
        #expect(healed.min.z >= 0 - tol && healed.max.z <= side + tol, "Z face inflated")

        // And it must actually fill the body, not collapse: extents within ~12%.
        let oe = Vec3(x: side, y: side, z: side)
        let he = Self.extents(healed)
        #expect(abs(he.x - oe.x) < oe.x * 0.12, "X extent off")
        #expect(abs(he.y - oe.y) < oe.y * 0.12, "Y extent off")
        #expect(abs(he.z - oe.z) < oe.z * 0.12, "Z extent off")
    }

    /// Detail clamps gracefully and higher detail resolves a finer (more
    /// triangles) surface; degenerate (no-geometry) input passes through.
    @Test
    func makeWatertightDetailClampAndDegenerateInput() {
        let empty = Self.summary(name: "empty", vertices: [], indices: [])
        let unchanged = MeshModifier.shrinkwrap(empty, detail: 0.5)
        #expect(unchanged.triangleCount == 0)
        #expect(unchanged.geometry == empty.geometry)

        let cube = Self.makeOpenCube(side: 30.0)
        let low = MeshModifier.shrinkwrap(cube, detail: -2.0)   // clamps to 0 (coarse)
        let high = MeshModifier.shrinkwrap(cube, detail: 5.0)   // clamps to 1 (fine)
        #expect(low.preflight.isWatertight)
        #expect(high.preflight.isWatertight)
        #expect(high.triangleCount > low.triangleCount,
                "higher detail must resolve a finer surface")
    }

    /// A closed cube [0,s]^3 with outward winding, offset by `origin`. Used to
    /// compose a self-intersecting union (two interpenetrating closed solids whose
    /// faces cross through each other).
    private static func closedCube(side s: Double, origin o: Vec3) -> ([Vec3], [Int32]) {
        let v: [Vec3] = [
            Vec3(x: o.x,     y: o.y,     z: o.z),
            Vec3(x: o.x + s, y: o.y,     z: o.z),
            Vec3(x: o.x + s, y: o.y + s, z: o.z),
            Vec3(x: o.x,     y: o.y + s, z: o.z),
            Vec3(x: o.x,     y: o.y,     z: o.z + s),
            Vec3(x: o.x + s, y: o.y,     z: o.z + s),
            Vec3(x: o.x + s, y: o.y + s, z: o.z + s),
            Vec3(x: o.x,     y: o.y + s, z: o.z + s),
        ]
        // Outward-facing quads (CCW seen from outside).
        let q: [(Int, Int, Int, Int)] = [
            (0, 3, 2, 1),  // bottom (-z)
            (4, 5, 6, 7),  // top (+z)
            (0, 1, 5, 4),  // -y
            (1, 2, 6, 5),  // +x
            (2, 3, 7, 6),  // +y
            (3, 0, 4, 7),  // -x
        ]
        var idx: [Int32] = []
        for (a, b, c, d) in q {
            idx += [Int32(a), Int32(b), Int32(c), Int32(a), Int32(c), Int32(d)]
        }
        return (v, idx)
    }

    /// A closed cube with an extra interior partition wall whose four edges are
    /// shared with the cube's side faces: every wall edge is now used by THREE
    /// triangles (the two side-face triangles + the wall), so the mesh has
    /// NON-MANIFOLD edges and a buried interior face — a deliberately broken,
    /// non-2-manifold soup (the failure shape real self-intersecting scans
    /// exhibit). This is exactly the case where MeshPreflight's position-weld
    /// fabricates phantom non-manifold edges on the HEALED output unless closure
    /// is read from Manifold's own topology. Locks broken -> watertight via the
    /// public Make-Watertight path. Small + fast (coarse detail, no fixture load).
    @Test
    func makeWatertightClosesNonManifoldSoup() throws {
        let s = 60.0
        var (v, idx) = Self.closedCube(side: s, origin: Vec3(x: 0, y: 0, z: 0))
        // Interior wall at y = s/2, spanning the full x/z cross-section. Its
        // corners coincide with the side-face edges (x and z extremes), so the
        // welded edge analysis sees edges used by 3 triangles -> non-manifold.
        let base = Int32(v.count)
        v += [
            Vec3(x: 0, y: s / 2, z: 0),
            Vec3(x: s, y: s / 2, z: 0),
            Vec3(x: s, y: s / 2, z: s),
            Vec3(x: 0, y: s / 2, z: s),
        ]
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        let soup = Self.summary(name: "cube+wall", vertices: v, indices: idx)

        // The raw soup is NOT a clean 2-manifold: the buried interior wall adds
        // dangling faces, so the surface is no longer a single closed shell.
        #expect((soup.preflight.boundaryEdgeCount + soup.preflight.nonManifoldEdgeCount) > 0,
                "fixture must start with broken (open / non-manifold) edges")
        #expect(!soup.preflight.isWatertight,
                "broken fixture must start non-watertight")

        // Coarse detail keeps the heal grid small -> fast locking test.
        let result = MeshModifier.shrinkwrap(soup, detail: 0.0)

        // The contract is a CLOSED, USABLE solid — not strict 2-manifoldness.
        // The heal must close every hole (boundaryEdgeCount == 0) and Manifold
        // must validate the result (manifoldValidated). Residual non-manifold
        // edges, when present, are benign surface self-contacts and must NOT fail
        // the verdict — so we assert isWatertight, NOT nonManifoldEdgeCount == 0.
        #expect(result.preflight.isWatertight,
                "heal must turn a non-manifold soup into a watertight (closed, usable) solid")
        #expect(result.preflight.boundaryEdgeCount == 0,
                "heal must close every hole — no boundary edges remain")
        #expect(result.preflight.manifoldValidated,
                "heal output must be validated by Manifold's own topology")
        #expect(result.triangleCount > 12, "heal must produce a real remeshed surface")

        // The healed solid must fill the cube body (the interior wall is gone).
        let healed = try #require(result.bounds)
        #expect(healed.min.x <= 3 && healed.min.y <= 3 && healed.min.z <= 3,
                "healed solid must reach the cube's near corner")
        #expect(healed.max.x >= s - 3 && healed.max.y >= s - 3 && healed.max.z >= s - 3,
                "healed solid must reach the cube's far corner")
    }

    /// Locks the watertight DEFINITION (the core of the broken-scan fix): a CLOSED
    /// solid (no boundary holes) that Manifold validated reads watertight even with
    /// residual self-contact non-manifold edges, while an un-validated report with
    /// the same counts (a raw mesh) stays "needs repair". Cheap — no heal.
    @Test
    func manifoldValidatedClosedSolidReadsWatertight() {
        // A closed solid with self-contact (0 holes, 8 non-manifold edges).
        var healed = MeshPreflightReport(
            uniqueVertexCount: 100, duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 0, degenerateTriangleCount: 0,
            boundaryEdgeCount: 0, nonManifoldEdgeCount: 8)

        // Without Manifold's validation (a raw mesh) those edges fail the verdict.
        #expect(!healed.isWatertight, "raw mesh with non-manifold edges is not watertight")
        #expect(healed.statusLabel == "Needs repair")

        // With Manifold's validation (the heal output) the SAME counts pass — the
        // self-contact is benign and the count is preserved honestly for display.
        healed.manifoldValidated = true
        #expect(healed.isWatertight, "Manifold-validated closed solid is watertight")
        #expect(healed.nonManifoldEdgeCount == 8, "honest self-contact count is preserved, not zeroed")
        #expect(healed.statusLabel == "Watertight (closed solid)")

        // But a real HOLE (boundary edge) still fails, even Manifold-validated:
        // closure is non-negotiable.
        var leaky = healed
        leaky.boundaryEdgeCount = 4
        #expect(!leaky.isWatertight, "boundary holes always fail, regardless of Manifold validation")
    }

    // MARK: - Real organic mesh (slow, opt-in)

    /// The non-watertight ZBrush hand through the public Make Watertight path:
    /// heal -> watertight, bounds ≈ source (NOT inflated). Skipped unless
    /// MAKE_WATERTIGHT_HAND is set (the hand scan is committed under
    /// app/RefabArtist/Tests/Fixtures/hand-scans/).
    @Test
    func makeWatertightHandIsWatertightNotInflated() throws {
        guard ProcessInfo.processInfo.environment["MAKE_WATERTIGHT_HAND"] != nil else {
            return  // opt-in only; the analytic cases cover the invariant in-suite.
        }
        let url = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let model = try MeshInspector.inspect(url: url)
        let source = try #require(model.bounds)

        let result = MeshModifier.shrinkwrap(model, detail: 0.5)
        #expect(result.preflight.isWatertight, "healed hand not watertight")

        let healed = try #require(result.bounds)
        // No inflation: every face within ~10% of the source span.
        let se = Self.extents(source)
        let he = Self.extents(healed)
        #expect(abs(he.x - se.x) < se.x * 0.10, "x extent inflated/collapsed")
        #expect(abs(he.y - se.y) < se.y * 0.10, "y extent inflated/collapsed")
        #expect(abs(he.z - se.z) < se.z * 0.10, "z extent inflated/collapsed")
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
