import XCTest
@testable import RefabArtist

/// RENDER-phase export harness. Generates EVERY infill pattern headlessly on the
/// 50mm cube and the hand model, writes one STL per (pattern,model) under
/// `structures_patterns/` in the temporary directory (or the folder named by
/// `STRUCTURES_PATTERNS_OUT`), and emits a `manifest.json` with per-pattern
/// triangle count + watertight status for the Python contact-sheet renderer to
/// consume. The hand joins the sweep only with `STRUCTURES_PATTERNS_HAND=1`. Run with:
/// `STRUCTURES_PATTERNS_HAND=1 swift test -c release --filter StructurePatternExport`.
final class StructurePatternExportTests: XCTestCase {

    private static let outDir: URL = {
        if let path = ProcessInfo.processInfo.environment["STRUCTURES_PATTERNS_OUT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appending(path: "structures_patterns", directoryHint: .isDirectory)
    }()

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Re-derive watertightness from the EXPORTED mesh geometry (weld + Manifold),
    /// which is the property that actually matters for a printable solid.
    private func watertight(_ mesh: ViewportFlatShadedMesh) -> Bool {
        let geo = MeshGeometryData(vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
        let welded = StructureClipEngine.welded(geo)
        guard let handle = try? ManifoldEngine.make(from: welded) else { return false }
        return ManifoldEngine.isWatertight(handle)
    }

    /// Weld coincident vertices at a tolerance matched to Manifold's Float32
    /// output precision (~2e-6 at cube scale), so vertices that differ only by
    /// float-32 round-off collapse instead of leaving phantom sliver triangles.
    /// `StructureClipEngine.welded` quantizes at 1e-6 — FINER than Float32 noise —
    /// which can split a single shared vertex into two and orphan an edge; for an
    /// edge-manifoldness audit we must measure at the real precision floor. Returns
    /// (boundaryEdges, nonManifoldEdges, weldedVertexCount).
    private func edgeAudit(_ mesh: ViewportFlatShadedMesh, tolerance: Double = 1e-5) -> (open: Int, nonManifold: Int, verts: Int) {
        let scale = 1.0 / tolerance
        struct Key: Hashable { var x: Int64; var y: Int64; var z: Int64 }
        func key(_ v: Vec3) -> Key {
            Key(x: Int64((v.x * scale).rounded()),
                y: Int64((v.y * scale).rounded()),
                z: Int64((v.z * scale).rounded()))
        }
        var indexByKey: [Key: Int] = [:]
        func idx(_ v: Vec3) -> Int {
            let k = key(v)
            if let e = indexByKey[k] { return e }
            let n = indexByKey.count
            indexByKey[k] = n
            return n
        }
        struct EdgeKey: Hashable { var a: Int; var b: Int }
        var edgeUse: [EdgeKey: Int] = [:]
        let tris = mesh.triangleIndices
        var t = 0
        while t + 2 < tris.count {
            let a = idx(mesh.vertices[Int(tris[t])])
            let b = idx(mesh.vertices[Int(tris[t + 1])])
            let c = idx(mesh.vertices[Int(tris[t + 2])])
            guard a != b, b != c, a != c else { t += 3; continue }
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let e = u < v ? EdgeKey(a: u, b: v) : EdgeKey(a: v, b: u)
                edgeUse[e, default: 0] += 1
            }
            t += 3
        }
        return (
            open: edgeUse.values.filter { $0 == 1 }.count,
            nonManifold: edgeUse.values.filter { $0 > 2 }.count,
            verts: indexByKey.count
        )
    }

    func testExportAllPatterns() throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.outDir, withIntermediateDirectories: true)

        struct Target { let key: String; let path: String }
        var targets: [Target] = [
            Target(key: "cube", path: Self.repoRoot().appending(path: "tests/fixtures/primitives/cube_50mm.obj").path)
        ]
        // Every pattern on the full hand scan takes about 20 minutes, so the
        // hand joins the sweep only when asked for (the contact-sheet render).
        if ProcessInfo.processInfo.environment["STRUCTURES_PATTERNS_HAND"] != nil {
            targets.append(Target(key: "hand", path: Self.repoRoot().appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj").path))
        } else {
            NSLog("SKIP hand: set STRUCTURES_PATTERNS_HAND=1 to add the hand scan (about 20 minutes)")
        }

        var manifest: [[String: Any]] = []

        for target in targets {
            let url = URL(fileURLWithPath: target.path)
            guard fm.fileExists(atPath: target.path) else {
                NSLog("SKIP missing model \(target.path)")
                continue
            }
            let model = try MeshInspector.inspect(url: url)

            for pattern in InfillPattern.allCases {
                let settings = StructureSettings(category: .infill, pattern: pattern, parameters: .defaultValue)
                let label = pattern.rawValue
                let stlURL = Self.outDir.appending(path: "\(target.key)_\(label).stl")

                var tris = 0
                var wt = false
                var ok = false
                do {
                    if let plan = try StructurePlanner.planThrowing(model: model, settings: settings) {
                        let meshes = plan.layers.map(\.mesh)
                        try StlExporter.write(meshes: meshes, to: stlURL, solidName: "refabartist_\(label)")
                        tris = plan.triangleCount
                        wt = meshes.allSatisfy { watertight($0) }
                        ok = true
                    }
                } catch {
                    NSLog("FAIL \(target.key)/\(label): \(error)")
                }

                manifest.append([
                    "model": target.key,
                    "pattern": label,
                    "family": pattern.family.rawValue,
                    "label": pattern.label,
                    "stl": stlURL.path,
                    "tris": tris,
                    "watertight": wt,
                    "ok": ok
                ])
                NSLog("EXPORT \(target.key)/\(label) tris=\(tris) wt=\(wt) ok=\(ok)")
            }
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.outDir.appending(path: "manifest.json"))
        XCTAssertFalse(manifest.isEmpty)
    }

    /// The 6 reworked generators (Cross 2D + the 5 lattices) must each clip to a
    /// NON-EMPTY, WATERTIGHT solid on the cube — 0 boundary edges, 0 non-manifold
    /// edges — with bounds inside the source, and must be visibly DISTINCT from one
    /// another (here proxied by a distinct triangle-count fingerprint so two
    /// generators can never silently collapse to identical geometry again).
    func testReworkedGeneratorsAreWatertightAndDistinctOnCube() throws {
        let url = Self.repoRoot().appending(path: "tests/fixtures/cube_ascii.stl")
        let model = try MeshInspector.inspect(url: url)
        let source = try XCTUnwrap(model.bounds)

        let reworked: [InfillPattern] = [.cross, .cubic, .quarterCubic, .octet, .cubicSubdivision, .cross3D]
        var fingerprints: [String: Int] = [:]

        for pattern in reworked {
            let settings = StructureSettings(category: .infill, pattern: pattern, parameters: .defaultValue)
            let plan = try XCTUnwrap(
                StructurePlanner.planThrowing(model: model, settings: settings),
                "\(pattern.label) produced no plan"
            )
            let mesh = try XCTUnwrap(plan.layers.first?.mesh, "\(pattern.label) has no layer")

            // Non-empty.
            XCTAssertFalse(mesh.vertices.isEmpty, "\(pattern.label) is empty")
            XCTAssertGreaterThan(plan.triangleCount, 0, "\(pattern.label) has no triangles")

            // Manifold (the printable gate) must accept the solid as watertight.
            XCTAssertTrue(self.watertight(mesh), "\(pattern.label) is not watertight per Manifold")
            // Edge audit at the Float32 precision floor: 0 open, 0 non-manifold.
            let audit = edgeAudit(mesh)
            NSLog("VERIFY \(pattern.label): tris=\(plan.triangleCount) open=\(audit.open) nm=\(audit.nonManifold) verts=\(audit.verts)")
            XCTAssertEqual(audit.open, 0, "\(pattern.label) has \(audit.open) open edges")
            XCTAssertEqual(audit.nonManifold, 0, "\(pattern.label) has \(audit.nonManifold) non-manifold edges")

            // Bounds within source (small epsilon for float).
            let b = try XCTUnwrap(plan.bounds, "\(pattern.label) has no bounds")
            let eps = 1e-3
            XCTAssertGreaterThanOrEqual(b.min.x, source.min.x - eps, "\(pattern.label) x underflows source")
            XCTAssertGreaterThanOrEqual(b.min.y, source.min.y - eps, "\(pattern.label) y underflows source")
            XCTAssertGreaterThanOrEqual(b.min.z, source.min.z - eps, "\(pattern.label) z underflows source")
            XCTAssertLessThanOrEqual(b.max.x, source.max.x + eps, "\(pattern.label) x overflows source")
            XCTAssertLessThanOrEqual(b.max.y, source.max.y + eps, "\(pattern.label) y overflows source")
            XCTAssertLessThanOrEqual(b.max.z, source.max.z + eps, "\(pattern.label) z overflows source")

            fingerprints[pattern.rawValue] = plan.triangleCount
            NSLog("BOUNDS \(pattern.label): \(b)")
        }

        // Distinctness: no two reworked patterns share a triangle-count fingerprint
        // (a coarse but effective guard against the "all cubics look identical"
        // regression).
        let counts = Array(fingerprints.values)
        XCTAssertEqual(Set(counts).count, counts.count, "two reworked generators share a triangle count: \(fingerprints)")
    }
}
