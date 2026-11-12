import XCTest
@testable import RefabArtist

/// Headless geometry tests for the triangle infill engine on WATERTIGHT
/// fixtures. Asserts every generated plan is non-empty, watertight (via the
/// Manifold solid), has finite coordinates, and its bounds stay within / ≈ the
/// source bounds (the lattice clipped to the skin can never exceed it).
final class StructureInfillEngineTests: XCTestCase {

    // MARK: - Fixtures

    private static func model(_ relative: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/\(relative)"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let fixtures = ["cube_50mm.obj", "sphere_d50mm.stl", "torus_R30_r10mm.stl"]

    private static var fastHandFixtureURL: URL {
        repoRoot().appending(path: "app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj")
    }

    private static func exactModel(name: String, solid: ManifoldHandle) throws -> MeshSummary {
        let geometry = try ManifoldEngine.toMesh(solid)
        var preflight = MeshPreflight.analyze(geometry: geometry)
        preflight.manifoldValidated = true
        return MeshSummary(
            name: name,
            path: name,
            format: "generated",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: ManifoldEngine.bounds(solid),
            geometry: geometry,
            preflight: preflight
        )
    }

    private static func scaffoldOverhangModel() throws -> MeshSummary {
        let slab = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 25),
            extents: Vec3(x: 50, y: 50, z: 6)
        ))
        let post = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 10),
            extents: Vec3(x: 8, y: 8, z: 20)
        ))
        let solid = try ManifoldEngine.union(slab, post)
        let model = try exactModel(name: "generated-overhang", solid: solid)
        withExtendedLifetime(slab) {}
        withExtendedLifetime(post) {}
        withExtendedLifetime(solid) {}
        return model
    }

    // MARK: - Shared assertions

    private func assertFinite(_ mesh: ViewportFlatShadedMesh, _ fixture: String) {
        for v in mesh.vertices {
            XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite,
                          "\(fixture): non-finite vertex \(v)")
        }
    }

    private func reversedWinding(_ model: MeshSummary) -> MeshSummary {
        var reversed = model
        var indices: [Int32] = []
        indices.reserveCapacity(model.geometry.triangleIndices.count)
        for i in stride(from: 0, to: model.geometry.triangleIndices.count - 2, by: 3) {
            indices.append(model.geometry.triangleIndices[i])
            indices.append(model.geometry.triangleIndices[i + 2])
            indices.append(model.geometry.triangleIndices[i + 1])
        }
        reversed.geometry.triangleIndices = indices
        return reversed
    }

    /// The clipped infill bounds must be inside the source bounds (plus a small
    /// tolerance for the wall over-run in Z that the clip closes against the
    /// skin and for floating point).
    private func assertBoundsWithinSource(
        infill: Bounds3D,
        source: Bounds3D,
        fixture: String
    ) {
        let tol = 0.05
        XCTAssertGreaterThanOrEqual(infill.min.x, source.min.x - tol, "\(fixture): min.x escapes source")
        XCTAssertGreaterThanOrEqual(infill.min.y, source.min.y - tol, "\(fixture): min.y escapes source")
        XCTAssertGreaterThanOrEqual(infill.min.z, source.min.z - tol, "\(fixture): min.z escapes source")
        XCTAssertLessThanOrEqual(infill.max.x, source.max.x + tol, "\(fixture): max.x escapes source")
        XCTAssertLessThanOrEqual(infill.max.y, source.max.y + tol, "\(fixture): max.y escapes source")
        XCTAssertLessThanOrEqual(infill.max.z, source.max.z + tol, "\(fixture): max.z escapes source")
    }

    // MARK: - Per-fixture engine test

    func testTriangleInfillOnWatertightFixtures() throws {
        for fixture in Self.fixtures {
            let model = try Self.model(fixture)
            let source = try XCTUnwrap(model.bounds, "\(fixture): source has no bounds")

            let settings = StructureSettings(category: .infill, pattern: .triangle)
            let plan = try XCTUnwrap(
                StructurePlanner.planThrowing(model: model, settings: settings),
                "\(fixture): planThrowing returned nil"
            )

            // Non-empty.
            XCTAssertFalse(plan.layers.isEmpty, "\(fixture): no layers")
            XCTAssertGreaterThan(plan.triangleCount, 0, "\(fixture): zero triangles")
            let layer = try XCTUnwrap(plan.layers.first)
            XCTAssertFalse(layer.mesh.vertices.isEmpty, "\(fixture): empty vertices")
            XCTAssertFalse(layer.mesh.triangleIndices.isEmpty, "\(fixture): empty indices")

            // Finite coords.
            assertFinite(layer.mesh, fixture)

            // Bounds within / ≈ the source (clipped to skin).
            let infillBounds = try XCTUnwrap(plan.bounds, "\(fixture): plan has no bounds")
            assertBoundsWithinSource(infill: infillBounds, source: source, fixture: fixture)
        }
    }

    /// Re-builds the clipped solid through Manifold and asserts it is watertight
    /// (the plan stores a render mesh; this proves the underlying boolean result
    /// is a closed solid, not just non-empty triangles).
    func testTriangleInfillIsWatertightSolid() throws {
        for fixture in Self.fixtures {
            let model = try Self.model(fixture)
            let bounds = try XCTUnwrap(model.bounds)

            let sourceSolid = try ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))
            XCTAssertTrue(ManifoldEngine.isWatertight(sourceSolid), "\(fixture): source not watertight")

            let gen = TriangleWallSolidGenerator()
            let wallSolid = try gen.makeWallSolid(
                bounds: bounds,
                params: StructureSettings.defaultValue.sanitized.parameters,
                engine: ManifoldEngine.self
            )
            let clipped = try ManifoldEngine.intersect(wallSolid, sourceSolid)

            XCTAssertFalse(ManifoldEngine.isEmpty(clipped), "\(fixture): clipped infill is empty")
            XCTAssertTrue(ManifoldEngine.isWatertight(clipped), "\(fixture): clipped infill not watertight")
            XCTAssertGreaterThan(ManifoldEngine.volume(clipped), 0, "\(fixture): non-positive volume")
            // The clipped lattice volume must be a fraction of the solid model.
            XCTAssertLessThan(
                ManifoldEngine.volume(clipped),
                ManifoldEngine.volume(sourceSolid),
                "\(fixture): infill volume should be less than the solid model"
            )

            withExtendedLifetime(sourceSolid) {}
            withExtendedLifetime(wallSolid) {}
            withExtendedLifetime(clipped) {}
        }
    }

    // MARK: - Planar patterns (Grid / Tri-Hexagon / Cross / Concentric)

    /// The implemented PLANAR patterns. Each must plan to a non-empty mesh whose
    /// bounds stay within the source, and whose underlying boolean is a watertight
    /// solid with positive sub-model volume — same contract as Triangle.
    private static let planarPatterns: [InfillPattern] = [.grid, .triHexagon, .cross, .concentric]

    func testPlanarPatternsPlanWithinSourceBounds() throws {
        for pattern in Self.planarPatterns {
            for fixture in Self.fixtures {
                let model = try Self.model(fixture)
                let source = try XCTUnwrap(model.bounds, "\(fixture): no bounds")
                let settings = StructureSettings(category: .infill, pattern: pattern)
                let plan = try XCTUnwrap(
                    StructurePlanner.planThrowing(model: model, settings: settings),
                    "\(pattern.rawValue)/\(fixture): planThrowing returned nil"
                )
                XCTAssertGreaterThan(plan.triangleCount, 0, "\(pattern.rawValue)/\(fixture): zero triangles")
                let layer = try XCTUnwrap(plan.layers.first)
                XCTAssertFalse(layer.mesh.vertices.isEmpty, "\(pattern.rawValue)/\(fixture): empty vertices")
                assertFinite(layer.mesh, "\(pattern.rawValue)/\(fixture)")
                let infill = try XCTUnwrap(plan.bounds, "\(pattern.rawValue)/\(fixture): no bounds")
                assertBoundsWithinSource(infill: infill, source: source, fixture: "\(pattern.rawValue)/\(fixture)")
            }
        }
    }

    func testPlanarPatternsAreWatertightSolids() throws {
        for pattern in Self.planarPatterns {
            let model = try Self.model("cube_50mm.obj")
            let bounds = try XCTUnwrap(model.bounds)
            let sourceSolid = try ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))

            let gen = try XCTUnwrap(StructurePlanner.generator(for: pattern))
            let wallSolid = try gen.makeWallSolid(
                bounds: bounds,
                params: StructureSettings.defaultValue.sanitized.parameters,
                engine: ManifoldEngine.self
            )
            let clipped = try ManifoldEngine.intersect(wallSolid, sourceSolid)

            XCTAssertFalse(ManifoldEngine.isEmpty(clipped), "\(pattern.rawValue): clipped infill empty")
            XCTAssertTrue(ManifoldEngine.isWatertight(clipped), "\(pattern.rawValue): clipped infill not watertight")
            XCTAssertGreaterThan(ManifoldEngine.volume(clipped), 0, "\(pattern.rawValue): non-positive volume")
            XCTAssertLessThan(
                ManifoldEngine.volume(clipped), ManifoldEngine.volume(sourceSolid),
                "\(pattern.rawValue): infill volume should be less than the solid model"
            )
            withExtendedLifetime(sourceSolid) {}
            withExtendedLifetime(wallSolid) {}
            withExtendedLifetime(clipped) {}
        }
    }

    func testGridInfill() throws {
        let model = try Self.model("cube_50mm.obj")
        let source = try XCTUnwrap(model.bounds)
        let settings = StructureSettings(category: .infill, pattern: .grid)
        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))

        XCTAssertGreaterThan(plan.triangleCount, 0)
        let bounds = try XCTUnwrap(plan.bounds)
        assertBoundsWithinSource(infill: bounds, source: source, fixture: "grid/cube_50mm.obj")
        let layer = try XCTUnwrap(plan.layers.first)
        let solid = try ManifoldEngine.make(from: StructureClipEngine.welded(MeshGeometryData(
            vertices: layer.mesh.vertices,
            triangleIndices: layer.mesh.triangleIndices
        )))
        XCTAssertTrue(ManifoldEngine.isWatertight(solid))
        XCTAssertGreaterThan(ManifoldEngine.volume(solid), 0)
        withExtendedLifetime(solid) {}
    }

    func testAttractorDensityGridDiffersFromUniformAndStaysWatertight() throws {
        let model = try Self.model("cube_50mm.obj")
        let parameters = InfillParameters(cellSizeMm: 12, wallThicknessMm: 1.2)
        let uniform = try XCTUnwrap(StructurePlanner.planThrowing(
            model: model,
            settings: StructureSettings(category: .infill, pattern: .grid, parameters: parameters)
        ))
        let attractor = try XCTUnwrap(StructurePlanner.planThrowing(
            model: model,
            settings: StructureSettings(
                category: .infill,
                pattern: .grid,
                parameters: parameters,
                density: StructureDensitySettings(
                    source: .attractors,
                    minCellMm: 6,
                    maxCellMm: 18,
                    attractorPreset: .center,
                    falloffMm: 40
                )
            )
        ))

        func solidVolume(_ plan: StructureMeshPlan) throws -> Double {
            let layer = try XCTUnwrap(plan.layers.first)
            let solid = try ManifoldEngine.make(from: StructureClipEngine.welded(MeshGeometryData(
                vertices: layer.mesh.vertices,
                triangleIndices: layer.mesh.triangleIndices
            )))
            XCTAssertTrue(ManifoldEngine.isWatertight(solid))
            let volume = ManifoldEngine.volume(solid)
            withExtendedLifetime(solid) {}
            return volume
        }

        let uniformVolume = try solidVolume(uniform)
        let attractorVolume = try solidVolume(attractor)
        XCTAssertGreaterThan(abs(attractorVolume - uniformVolume), 1.0)
        XCTAssertNil(attractor.settings.densityEngineNotice)
        XCTAssertEqual(attractor.settings.effectiveDensitySource, .attractors)
    }

    // MARK: - Lattice patterns (Cubic / Octet / Quarter Cubic / Cubic Subdivision / Cross 3D)

    /// The implemented LATTICE patterns. Each is a union of 3D struts clipped to
    /// the skin: must plan non-empty, finite, bounds within source, and the
    /// underlying boolean a watertight positive-volume sub-model solid.
    private static let latticePatterns: [InfillPattern] = [
        .cubic, .octet, .quarterCubic, .cubicSubdivision, .cross3D
    ]

    func testLatticePatternsPlanWithinSourceBounds() throws {
        for pattern in Self.latticePatterns {
            for fixture in Self.fixtures {
                let model = try Self.model(fixture)
                let source = try XCTUnwrap(model.bounds, "\(fixture): no bounds")
                let settings = StructureSettings(category: .infill, pattern: pattern)
                let plan = try XCTUnwrap(
                    StructurePlanner.planThrowing(model: model, settings: settings),
                    "\(pattern.rawValue)/\(fixture): planThrowing returned nil"
                )
                XCTAssertGreaterThan(plan.triangleCount, 0, "\(pattern.rawValue)/\(fixture): zero triangles")
                let layer = try XCTUnwrap(plan.layers.first)
                XCTAssertFalse(layer.mesh.vertices.isEmpty, "\(pattern.rawValue)/\(fixture): empty vertices")
                assertFinite(layer.mesh, "\(pattern.rawValue)/\(fixture)")
                let infill = try XCTUnwrap(plan.bounds, "\(pattern.rawValue)/\(fixture): no bounds")
                assertBoundsWithinSource(infill: infill, source: source, fixture: "\(pattern.rawValue)/\(fixture)")
            }
        }
    }

    func testLatticePatternsAreWatertightSolids() throws {
        for pattern in Self.latticePatterns {
            let model = try Self.model("cube_50mm.obj")
            let bounds = try XCTUnwrap(model.bounds)
            let sourceSolid = try ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))

            let gen = try XCTUnwrap(StructurePlanner.generator(for: pattern))
            let wallSolid = try gen.makeWallSolid(
                bounds: bounds,
                params: StructureSettings.defaultValue.sanitized.parameters,
                engine: ManifoldEngine.self
            )
            let clipped = try ManifoldEngine.intersect(wallSolid, sourceSolid)

            XCTAssertFalse(ManifoldEngine.isEmpty(clipped), "\(pattern.rawValue): clipped infill empty")
            XCTAssertTrue(ManifoldEngine.isWatertight(clipped), "\(pattern.rawValue): clipped infill not watertight")
            XCTAssertGreaterThan(ManifoldEngine.volume(clipped), 0, "\(pattern.rawValue): non-positive volume")
            XCTAssertLessThan(
                ManifoldEngine.volume(clipped), ManifoldEngine.volume(sourceSolid),
                "\(pattern.rawValue): infill volume should be less than the solid model"
            )
            withExtendedLifetime(sourceSolid) {}
            withExtendedLifetime(wallSolid) {}
            withExtendedLifetime(clipped) {}
        }
    }

    // MARK: - Heal-then-clip on a real non-watertight organic source

    /// End-to-end on the real ZBrush hand: the infill pipeline must produce a
    /// non-empty, watertight triangle infill whose bounds ≈ the source (not
    /// inflated). Whether the welded source happens to satisfy Manifold's fast
    /// path or needs the GWN heal, `solidify` must reach a watertight solid and
    /// clip it. (The heal path itself is proven independently in MeshHealerTests
    /// — including the explicit non-inflation + sign checks.) Skipped if the
    /// committed hand scan is absent.
    func testTriangleInfillHealsAndClipsHand() throws {
        // Slow (GWN heal of a 59k-face mesh). Opt-in only — the fast heal branch is
        // covered by MeshHealerTests.testSolidifyHealsOpenCube in the normal suite.
        guard ProcessInfo.processInfo.environment["STRUCTURE_HEAL_HAND"] != nil else {
            throw XCTSkip("set STRUCTURE_HEAL_HAND=1 to run the slow real-hand heal+clip test")
        }
        let url = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("hand fixture not present at \(url.path)")
        }
        let model = try MeshInspector.inspect(url: url)
        let source = try XCTUnwrap(model.bounds)

        // solidify must yield a watertight solid for the hand (fast path or heal).
        let solidified = try StructureClipEngine.solidify(source: model.geometry)
        XCTAssertTrue(ManifoldEngine.isWatertight(solidified),
                      "hand: solidify did not produce a watertight solid")

        let settings = StructureSettings(category: .infill, pattern: .triangle,
                                         parameters: InfillParameters(cellSizeMm: 9, wallThicknessMm: 1.6))
        let plan = try XCTUnwrap(
            StructurePlanner.planThrowing(model: model, settings: settings),
            "hand: planThrowing returned nil"
        )
        XCTAssertGreaterThan(plan.triangleCount, 0, "hand: zero infill triangles")
        let layer = try XCTUnwrap(plan.layers.first)
        XCTAssertFalse(layer.mesh.vertices.isEmpty)
        assertFinite(layer.mesh, "hand")

        // Infill bounds ≈ within the source (clipped to the healed skin; the heal
        // is non-inflated so a small voxel tolerance suffices).
        let infill = try XCTUnwrap(plan.bounds)
        let tol = 2.0
        XCTAssertGreaterThanOrEqual(infill.min.x, source.min.x - tol)
        XCTAssertGreaterThanOrEqual(infill.min.y, source.min.y - tol)
        XCTAssertGreaterThanOrEqual(infill.min.z, source.min.z - tol)
        XCTAssertLessThanOrEqual(infill.max.x, source.max.x + tol)
        XCTAssertLessThanOrEqual(infill.max.y, source.max.y + tol)
        XCTAssertLessThanOrEqual(infill.max.z, source.max.z + tol)

        // The clipped infill is a watertight solid with positive volume.
        let geom = MeshGeometryData(vertices: layer.mesh.vertices,
                                    triangleIndices: layer.mesh.triangleIndices)
        let solid = try ManifoldEngine.make(from: StructureClipEngine.welded(geom))
        XCTAssertTrue(ManifoldEngine.isWatertight(solid), "hand: clipped infill not watertight")
        XCTAssertGreaterThan(ManifoldEngine.volume(solid), 0, "hand: non-positive infill volume")
    }

    func testRegenerateHandStandEx3Healed50kFixture() throws {
        guard ProcessInfo.processInfo.environment["STRUCTURES_REGENERATE_FAST_FIXTURE"] != nil else {
            throw XCTSkip("set STRUCTURES_REGENERATE_FAST_FIXTURE=1 to regenerate the fast Structures hand fixture")
        }
        let sourceURL = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("hand fixture not present at \(sourceURL.path)")
        }
        let model = try MeshInspector.inspect(url: sourceURL)
        let healed = try MeshHealer.heal(model.geometry, maxCells: 50_000)
        let geometry = try ManifoldEngine.toMesh(healed.handle)
        let mesh = ViewportMeshRenderData.flatShadedMesh(from: geometry)
        let output = Self.fastHandFixtureURL
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ObjExporter.write(
            meshLayers: [SliceMeshExportLayer(name: "handStand_ex3_healed_50k", mesh: mesh)],
            to: output,
            title: "handStand_ex3_healed_50k"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Negative / contract paths

    func testScaffoldSupportsAvoidModelAndCoverDownFacingOverhang() throws {
        let model = try Self.scaffoldOverhangModel()
        let settings = StructureSettings(
            category: .support,
            parameters: InfillParameters(seed: 42),
            support: SupportSettings(
                supportMode: .scaffold,
                targetSurface: .downFacing,
                surfaceAngleDeg: 25,
                tipSpacingMm: 22,
                tipDiameterMm: 2.0,
                branchDiameterMm: 7,
                diameterAngleDeg: 5,
                preferredAngleDeg: 22,
                maxAngleDeg: 40,
                stepMm: 5,
                xyClearanceMm: 0.8,
                contactOffsetMm: 0.3
            )
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let support = try XCTUnwrap(plan.supportAudit)
        XCTAssertGreaterThan(plan.triangleCount, 0)
        XCTAssertGreaterThan(support.targetSampleCount, 0)
        XCTAssertGreaterThanOrEqual(support.overhangCoverage, 0.98)
        XCTAssertLessThanOrEqual(support.modelIntersectionVolume, 1.0e-6)
        XCTAssertEqual(support.restOnModelCount, 0)
        XCTAssertLessThanOrEqual(support.maxSlopeDeg, settings.support.maxAngleDeg + 2.0)

        let audit = try StructureAuditMetrics.componentAudit(layers: plan.layers)
        XCTAssertTrue(audit.watertight)
    }

    func testScaffoldAuditMetricsReadFailingValuesOnBadInputs() throws {
        let targets = [
            SupportSurfaceSample(position: Vec3(x: 0, y: 0, z: 10), normal: Vec3(x: 0, y: 0, z: -1)),
            SupportSurfaceSample(position: Vec3(x: 20, y: 0, z: 10), normal: Vec3(x: 0, y: 0, z: -1))
        ]
        let tips = [
            SupportSurfaceSample(position: Vec3(x: 0, y: 0, z: 9.7), normal: Vec3(x: 0, y: 0, z: -1))
        ]
        XCTAssertLessThan(
            SupportAuditMetrics.surfaceCoverage(targets: targets, tips: tips, maxDistance: 2.0),
            1.0,
            "anti-tautology: overhang coverage must read below 1.0 when a target is uncovered"
        )

        let model = try ManifoldEngine.box(ManifoldBoxSpec(
            center: Vec3(x: 0, y: 0, z: 0),
            extents: Vec3(x: 20, y: 20, z: 20)
        ))
        let badSupport = try ManifoldEngine.sphere(radius: 3, segments: 16)
        let intersection = try ManifoldEngine.intersect(model, badSupport)
        XCTAssertGreaterThan(
            abs(ManifoldEngine.volume(intersection)),
            0,
            "anti-tautology: model-intersection metric must read positive on a support inside the model"
        )
        withExtendedLifetime(model) {}
        withExtendedLifetime(badSupport) {}
        withExtendedLifetime(intersection) {}
    }

    func testScaffoldContactOffsetIsClampedAndPersisted() throws {
        let settings = SupportSettings(
            supportMode: .scaffold,
            contactOffsetMm: 20
        )
        XCTAssertEqual(settings.sanitized.contactOffsetMm, 2.0)

        let encoded = try JSONEncoder().encode(SupportSettings(
            supportMode: .scaffold,
            contactOffsetMm: 0.7
        ))
        let decoded = try JSONDecoder().decode(SupportSettings.self, from: encoded)
        XCTAssertEqual(decoded.supportMode, .scaffold)
        XCTAssertEqual(decoded.contactOffsetMm, 0.7)
    }

    func testSkinStrutsGenerateWatertightVoronoiOnSphere() throws {
        let sphere = try ManifoldEngine.sphere(radius: 30, segments: 24)
        let model = try Self.exactModel(name: "skin-sphere", solid: sphere)
        let settings = StructureSettings(
            category: .skin,
            parameters: InfillParameters(cellSizeMm: 15, seed: 11),
            skin: SkinSettings(skinStyle: .struts, skinPattern: .voronoi, strutDiameterMm: 2.0)
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let skin = try XCTUnwrap(plan.skinAudit)
        XCTAssertGreaterThan(plan.triangleCount, 0)
        XCTAssertGreaterThan(skin.seedCount, 4)
        XCTAssertGreaterThan(skin.segmentCount, 0)
        XCTAssertEqual(skin.componentCount, 1)
        XCTAssertGreaterThan(skin.genus, 0)
        // Band tolerant of the default Variation (log-uniform per-seed jitter
        // deliberately mixes small and large cells around the 15mm target).
        XCTAssertGreaterThan(skin.meanSpacing, 9.0)
        XCTAssertLessThan(skin.meanSpacing, 21.0)

        let audit = try StructureAuditMetrics.componentAudit(layers: plan.layers)
        XCTAssertTrue(audit.watertight)
        XCTAssertEqual(audit.componentCount, 1)
        XCTAssertGreaterThan(audit.totalVolume, 0)
        withExtendedLifetime(sphere) {}
    }

    /// The 2026-07-02 dust bug: past the capsule budget, coarsening SUBSAMPLED
    /// segments (dropping 5 of 6) and shattered the owner's real-hand Voronoi
    /// skin into 858 disconnected beads. Fine cells on a sphere exercise the
    /// same over-budget path; the network must stay one connected cage.
    func testSkinVoronoiFineCellsStaysConnectedPastTheCapsuleBudget() throws {
        let sphere = try ManifoldEngine.sphere(radius: 30, segments: 48)
        let model = try Self.exactModel(name: "skin-sphere-fine", solid: sphere)
        let settings = StructureSettings(
            category: .skin,
            parameters: InfillParameters(cellSizeMm: 4.0, seed: 3),
            skin: SkinSettings(skinStyle: .struts, skinPattern: .voronoi, strutDiameterMm: 1.6)
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let skin = try XCTUnwrap(plan.skinAudit)
        XCTAssertGreaterThan(skin.segmentCount, 2_000, "fixture too coarse to exercise the chaining path")
        XCTAssertEqual(
            skin.componentCount, 1,
            "skin cage fragmented into \(skin.componentCount) components — coarsening must merge segments, never drop them"
        )
        XCTAssertGreaterThan(skin.genus, 0)
        let audit = try StructureAuditMetrics.componentAudit(layers: plan.layers)
        XCTAssertTrue(audit.watertight)
        withExtendedLifetime(sphere) {}
    }

    func testSkinSurfaceSamplerHonorsTwoToOneDensityRamp() throws {
        let sphere = try ManifoldEngine.sphere(radius: 30, segments: 40)
        let mesh = try ManifoldEngine.toMesh(sphere)
        let ramp = DensityField.linearDensityRamp(
            axis: .x,
            lo: -30,
            hi: 30,
            startDensity: 1.0 / 24.0,
            endDensity: 1.0 / 12.0
        )

        let seeds = SurfaceSampler.seeds(onSurfaceOf: mesh, density: ramp, seed: 17, maxSeeds: 500)
        let sparse = nearestNeighborDistances(seeds.filter { $0.position.x < -5 })
        let dense = nearestNeighborDistances(seeds.filter { $0.position.x > 5 })
        XCTAssertGreaterThan(sparse.count, 4)
        XCTAssertGreaterThan(dense.count, 4)
        let ratio = mean(sparse) / mean(dense)
        XCTAssertGreaterThan(ratio, 1.5)
        XCTAssertLessThan(ratio, 2.5)
        withExtendedLifetime(sphere) {}
    }

    func testSkinTrianglePatternGeneratesSeedAdjacencyStruts() throws {
        let sphere = try ManifoldEngine.sphere(radius: 30, segments: 20)
        let model = try Self.exactModel(name: "skin-triangle-sphere", solid: sphere)
        let settings = StructureSettings(
            category: .skin,
            parameters: InfillParameters(cellSizeMm: 18, seed: 13),
            skin: SkinSettings(skinStyle: .struts, skinPattern: .triangles, strutDiameterMm: 1.6)
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let skin = try XCTUnwrap(plan.skinAudit)
        XCTAssertGreaterThan(plan.triangleCount, 0)
        XCTAssertGreaterThan(skin.segmentCount, 0)
        XCTAssertEqual(plan.settings.category, .skin)
        withExtendedLifetime(sphere) {}
    }

    private func nearestNeighborDistances(_ seeds: [SurfaceSeed]) -> [Double] {
        guard seeds.count > 1 else { return [] }
        return seeds.enumerated().map { index, seed in
            seeds.enumerated()
                .filter { $0.offset != index }
                .map { self.distance(seed.position, $0.element.position) }
                .min() ?? 0
        }
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    func testPlanFailSoftReturnsPlanForScaffoldSupport() throws {
        let model = try Self.scaffoldOverhangModel()
        XCTAssertNotNil(StructurePlanner.plan(
            model: model,
            settings: StructureSettings(
                category: .support,
                pattern: .triangle,
                support: SupportSettings(
                    supportMode: .scaffold,
                    targetSurface: .downFacing,
                    tipSpacingMm: 22,
                    tipDiameterMm: 2,
                    branchDiameterMm: 7,
                    stepMm: 5
                )
            )
        ))
    }

    /// A cube on the plate has no overhang: its only down-facing face is its
    /// base. Scaffold says so instead of growing stubs under the base (or
    /// failing with the unrelated "no measurable bounds" message).
    func testDefaultScaffoldSupportOnCubeReportsNothingToSupport() throws {
        let model = try Self.model("cube_50mm.obj")
        let settings = StructureSettings(
            category: .support,
            pattern: .triangle,
            support: SupportSettings(supportMode: .scaffold)
        )
        XCTAssertNil(StructurePlanner.plan(model: model, settings: settings))
        XCTAssertThrowsError(try StructurePlanner.planThrowing(model: model, settings: settings)) { error in
            XCTAssertEqual(error as? StructureEngineError, .nothingToSupport)
        }
    }

    func testScaffoldSupportModeNoLongerThrowsNotImplemented() throws {
        let model = try Self.scaffoldOverhangModel()
        let settings = StructureSettings(
            category: .support,
            pattern: .triangle,
            support: SupportSettings(supportMode: .scaffold)
        )
        XCTAssertNoThrow(try StructurePlanner.planThrowing(model: model, settings: settings))
    }

    // MARK: - TPMS (Gyroid · Lofted / Tiled)

    /// Both non-MC gyroid generators plan to a non-empty mesh whose bounds stay
    /// within the source on every watertight fixture — same contract as the
    /// planar/lattice patterns.
    func testGyroidPlansWithinSourceBounds() throws {
        for pattern in [InfillPattern.gyroidLofted, .gyroidTiled] {
            for fixture in Self.fixtures {
                let model = try Self.model(fixture)
                let source = try XCTUnwrap(model.bounds, "\(fixture): no bounds")
                let settings = StructureSettings(category: .infill, pattern: pattern)
                let tag = "\(pattern.rawValue)/\(fixture)"
                let plan = try XCTUnwrap(
                    StructurePlanner.planThrowing(model: model, settings: settings),
                    "\(tag): planThrowing returned nil"
                )
                XCTAssertGreaterThan(plan.triangleCount, 0, "\(tag): zero triangles")
                let layer = try XCTUnwrap(plan.layers.first)
                XCTAssertFalse(layer.mesh.vertices.isEmpty, "\(tag): empty vertices")
                assertFinite(layer.mesh, tag)
                let infill = try XCTUnwrap(plan.bounds, "\(tag): no bounds")
                assertBoundsWithinSource(infill: infill, source: source, fixture: tag)
            }
        }
    }

    /// Each gyroid sheet, clipped to the cube, is a watertight positive-volume
    /// sub-model solid. A flowing sheet (not a thin ribbon) is verified by the
    /// render gate; here we assert the topology and a non-trivial member count.
    func testGyroidIsWatertightSolid() throws {
        for pattern in [InfillPattern.gyroidLofted, .gyroidTiled] {
            let model = try Self.model("cube_50mm.obj")
            let bounds = try XCTUnwrap(model.bounds)
            let sourceSolid = try ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))

            let gen = try XCTUnwrap(StructurePlanner.generator(for: pattern))
            let wallSolid = try gen.makeWallSolid(
                bounds: bounds,
                params: StructureSettings.defaultValue.sanitized.parameters,
                engine: ManifoldEngine.self
            )
            let clipped = try ManifoldEngine.intersect(wallSolid, sourceSolid)
            let tag = pattern.rawValue

            XCTAssertFalse(ManifoldEngine.isEmpty(clipped), "\(tag): clipped infill empty")
            XCTAssertTrue(ManifoldEngine.isWatertight(clipped), "\(tag): clipped infill not watertight")
            XCTAssertGreaterThan(ManifoldEngine.volume(clipped), 0, "\(tag): non-positive volume")
            XCTAssertLessThan(
                ManifoldEngine.volume(clipped), ManifoldEngine.volume(sourceSolid),
                "\(tag): infill volume should be less than the solid model"
            )
            // A flowing gyroid sheet across a 50mm cube has many triangles — guard
            // against a degenerate few-triangle ribbon.
            let mesh = try ManifoldEngine.toMesh(clipped)
            XCTAssertGreaterThan(mesh.triangleIndices.count / 3, 2_000,
                                 "\(tag): too few triangles to be a flowing sheet")
            withExtendedLifetime(sourceSolid) {}
            withExtendedLifetime(wallSolid) {}
            withExtendedLifetime(clipped) {}
        }
    }

    func testGyroidTiledPostClipComponentFloorRejectsSpeckles() throws {
        guard ProcessInfo.processInfo.environment["STRUCTURE_SPECKLE_HAND"] != nil else {
            throw XCTSkip("set STRUCTURE_SPECKLE_HAND=1 to run the real-hand gyroid speckle honesty gate")
        }
        let fast = Self.fastHandFixtureURL
        let fallback = Self.repoRoot()
            .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj")
        let url = FileManager.default.fileExists(atPath: fast.path) ? fast : fallback
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("hand fixture not present at \(fast.path) or \(fallback.path)")
        }

        let model = try MeshInspector.inspect(url: url)
        let params = InfillParameters(
            cellSizeMm: 12,
            wallThicknessMm: 0.8,
            gyroidBand: InfillParameters.defaultValue.gyroidBand,
            loftSliceMm: InfillParameters.defaultValue.loftSliceMm,
            polishSurface: true
        )
        let bounds = try XCTUnwrap(model.bounds)
        let generator = try XCTUnwrap(StructurePlanner.generator(for: .gyroidTiled))
        let clipResult = try StructureClipEngine.clippedInfillResult(
            source: model.geometry,
            bounds: bounds,
            params: params,
            generator: generator
        )
        let audit = try StructureAuditMetrics.componentAudit(mesh: clipResult.mesh)
        let smallCount = audit.subFloorComponentCount(wallThicknessMm: params.wallThicknessMm)

        // M1b: the hand grid is budget-coarsened past a 0.8mm wall — that MUST
        // surface as a notice (auto-thickened wall), never run silent.
        XCTAssertNotNil(
            clipResult.wallSolidNotice,
            "M1b gate: coarsened/under-resolved gyroid must surface a notice"
        )
        XCTAssertTrue(audit.watertight, "M1 gate: post-filter hand infill must remain watertight")
        XCTAssertEqual(
            smallCount,
            0,
            "M1 gate: \(smallCount) post-filter sub-floor/sliver components remain; volumes=\(audit.componentVolumes.prefix(20)); dropped=\(clipResult.postClipDroppedCount)/\(clipResult.postClipDroppedVolume)"
        )
        // M1b: the sheet must be ONE coherent body — 3,187 above-floor crumbs
        // passing the speck floor was the original green-but-shattered failure.
        let totalVolume = audit.componentVolumes.reduce(0, +)
        let largestShare = totalVolume > 0 ? (audit.componentVolumes.max() ?? 0) / totalVolume : 0
        XCTAssertGreaterThanOrEqual(
            largestShare,
            0.9,
            "M1b gate: largest component is \(Int(largestShare * 100))% of total across \(audit.componentVolumes.count) components — a shattered sheet is still a failure even with zero sub-floor specks"
        )
    }

    func testGradedGyroidPhaseIntegralKnownAnswer() throws {
        let bounds = Bounds3D(
            min: Vec3(x: 0, y: 0, z: 0),
            max: Vec3(x: 100, y: 100, z: 100)
        )
        let density = DensityField.linearDensityRamp(
            axis: .x,
            lo: 0,
            hi: 100,
            startDensity: 1.0 / 20.0,
            endDensity: 1.0 / 10.0
        )
        let phase = GyroidPhaseTable(bounds: bounds, axis: .x, density: density)
        let expectedPhase = 7.5 * 2.0 * Double.pi

        XCTAssertEqual(phase.totalPhase, expectedPhase, accuracy: 0.02)
        XCTAssertLessThanOrEqual(abs(phase.zeroCrossingCount - 15), 1)
    }

    func testGradedGyroidProducesWatertightClippedSheetOnCube() throws {
        let model = try Self.model("cube_50mm.obj")
        let bounds = try XCTUnwrap(model.bounds)
        let sourceSolid = try ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))
        let params = InfillParameters(cellSizeMm: 20, wallThicknessMm: 1.2)
        let density = DensityField.linearDensityRamp(
            axis: .x,
            lo: bounds.min.x,
            hi: bounds.max.x,
            startDensity: 1.0 / 20.0,
            endDensity: 1.0 / 10.0
        )
        let generator = GradedGyroidWallSolidGenerator()
        let wallSolid = try generator.makeWallSolid(WallSolidContext(
            bounds: bounds,
            params: params,
            engine: ManifoldEngine.self,
            density: density,
            sourceVertices: model.geometry.vertices
        ))
        let components = try ManifoldEngine.decompose(wallSolid)
        XCTAssertGreaterThan(components.count, 0, "graded gyroid pre-clip wall solid should not be empty")
        XCTAssertLessThanOrEqual(components.count, 16, "graded gyroid sheet should not shatter into speckles")
        XCTAssertTrue(ManifoldEngine.isWatertight(wallSolid), "graded gyroid pre-clip wall solid must be watertight")

        let clipped = try ManifoldEngine.intersect(wallSolid, sourceSolid)
        XCTAssertFalse(ManifoldEngine.isEmpty(clipped), "graded gyroid clipped infill is empty")
        XCTAssertTrue(ManifoldEngine.isWatertight(clipped), "graded gyroid clipped infill must remain watertight")
        XCTAssertGreaterThan(ManifoldEngine.volume(clipped), 0)
        XCTAssertLessThan(ManifoldEngine.volume(clipped), ManifoldEngine.volume(sourceSolid))
        withExtendedLifetime(sourceSolid) {}
        withExtendedLifetime(wallSolid) {}
        withExtendedLifetime(clipped) {}
    }

    func testM3OpArtPresetsAreNonEmptyWatertightOnCube() throws {
        let model = try Self.model("cube_50mm.obj")
        let patterns: [InfillPattern] = [.rileySquares, .gradedRings, .waveGrating]
        var triangleCounts: [InfillPattern: Int] = [:]

        for pattern in patterns {
            let plan = try XCTUnwrap(StructurePlanner.planThrowing(
                model: model,
                settings: StructureSettings(
                    category: .infill,
                    pattern: pattern,
                    parameters: InfillParameters(cellSizeMm: 10, wallThicknessMm: 1.0)
                )
            ), "\(pattern.label) produced no plan")
            let layer = try XCTUnwrap(plan.layers.first, "\(pattern.label) has no layer")
            XCTAssertGreaterThan(plan.triangleCount, 0, "\(pattern.label) has no triangles")
            XCTAssertFalse(layer.mesh.vertices.isEmpty, "\(pattern.label) has no vertices")
            assertFinite(layer.mesh, pattern.rawValue)

            let solid = try ManifoldEngine.make(from: StructureClipEngine.welded(MeshGeometryData(
                vertices: layer.mesh.vertices,
                triangleIndices: layer.mesh.triangleIndices
            )))
            XCTAssertTrue(ManifoldEngine.isWatertight(solid), "\(pattern.label) is not watertight")
            XCTAssertGreaterThan(ManifoldEngine.volume(solid), 0, "\(pattern.label) volume is not positive")
            triangleCounts[pattern] = plan.triangleCount
            withExtendedLifetime(solid) {}
        }

        XCTAssertEqual(
            Set(triangleCounts.values).count,
            triangleCounts.count,
            "M3 Op-Art presets should not collapse to identical geometry: \(triangleCounts)"
        )
    }

    func testSculptureSupportsCoverUpFacingCubeSurfaceAndReachPlate() throws {
        let model = try Self.model("cube_50mm.obj")
        let source = try XCTUnwrap(model.bounds)
        let settings = StructureSettings(
            category: .support,
            parameters: InfillParameters(seed: 42),
            support: SupportSettings(
                supportMode: .sculpture,
                targetSurface: .upFacing,
                surfaceAngleDeg: 25,
                tipSpacingMm: 18,
                tipDiameterMm: 1.4,
                branchDiameterMm: 4,
                diameterAngleDeg: 5,
                preferredAngleDeg: 20,
                maxAngleDeg: 40,
                stepMm: 5
            )
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let support = try XCTUnwrap(plan.supportAudit)
        XCTAssertGreaterThan(plan.triangleCount, 0)
        XCTAssertGreaterThan(support.targetSampleCount, 0)
        XCTAssertGreaterThanOrEqual(support.tipCoverage, 0.95)
        XCTAssertLessThanOrEqual(support.maxSlopeDeg, settings.support.maxAngleDeg + 2.0)
        XCTAssertGreaterThan(support.branchCount, 0)
        // M4b anti-nails gate: a forest of ≥3 tips must actually MERGE into
        // trunks — zero merges means parallel pillars, not an organic tree.
        XCTAssertGreaterThanOrEqual(support.tipCount, 3, "fixture should seed enough tips to exercise merging")
        XCTAssertGreaterThanOrEqual(support.mergeCount, 1, "M4b gate: no branch merges — bed-of-nails output")
        XCTAssertLessThan(
            support.plateRootCount,
            support.tipCount,
            "M4b gate: every tip reaching the plate as its own root means no trunk formation"
        )

        let audit = try StructureAuditMetrics.componentAudit(layers: plan.layers)
        XCTAssertTrue(audit.watertight)
        XCTAssertGreaterThan(audit.componentCount, 0)
        for component in audit.components {
            XCTAssertLessThanOrEqual(component.bounds.min.z, source.min.z + 0.1)
        }

        let repeatPlan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        XCTAssertEqual(repeatPlan.supportAudit, plan.supportAudit)
        XCTAssertEqual(repeatPlan.triangleCount, plan.triangleCount)
    }

    func testSculptureSupportsUseUpFacingSurfaceWithReversedWinding() throws {
        let original = try Self.model("cube_50mm.obj")
        let model = reversedWinding(original)
        let source = try XCTUnwrap(original.bounds)
        let settings = StructureSettings(
            category: .support,
            parameters: InfillParameters(seed: 7),
            support: SupportSettings(
                supportMode: .sculpture,
                targetSurface: .upFacing,
                surfaceAngleDeg: 25,
                tipSpacingMm: 18,
                tipDiameterMm: 1.4,
                branchDiameterMm: 4,
                diameterAngleDeg: 5,
                preferredAngleDeg: 20,
                maxAngleDeg: 40,
                stepMm: 5
            )
        )

        let plan = try XCTUnwrap(StructurePlanner.planThrowing(model: model, settings: settings))
        let support = try XCTUnwrap(plan.supportAudit)
        let supportBounds = try XCTUnwrap(plan.bounds)
        XCTAssertGreaterThan(support.targetSampleCount, 0)
        XCTAssertGreaterThanOrEqual(support.tipCoverage, 0.95)
        XCTAssertGreaterThan(
            supportBounds.max.z,
            source.max.z - settings.support.tipDiameterMm,
            "up-facing support tips should stay on the top surface even when source triangle winding is reversed"
        )
    }

    /// Visual gate helper: exports the generated triangle infill + source to STL
    /// for each fixture so the geometry can be rendered and inspected. Skipped
    /// unless STRUCTURE_INFILL_DUMP is set; never runs in the normal suite.
    func testDumpInfillSTLForRenderGate() throws {
        guard let dir = ProcessInfo.processInfo.environment["STRUCTURE_INFILL_DUMP"] else {
            throw XCTSkip("set STRUCTURE_INFILL_DUMP=<dir> to dump STL for the render gate")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        let patterns: [InfillPattern] = [
            .triangle, .grid, .triHexagon, .cross, .concentric,
            .cubic, .octet, .quarterCubic, .cubicSubdivision, .cross3D,
            .gyroidLofted, .gyroidTiled
        ]
        for pattern in patterns {
            for fixture in Self.fixtures {
                let model = try Self.model(fixture)
                let plan = try XCTUnwrap(StructurePlanner.planThrowing(
                    model: model,
                    settings: StructureSettings(category: .infill, pattern: pattern)
                ))
                let stem = (fixture as NSString).deletingPathExtension
                try StlExporter.write(
                    meshes: plan.layers.map(\.mesh),
                    to: out.appending(path: "infill_\(pattern.rawValue)_\(stem).stl"),
                    solidName: "infill_\(pattern.rawValue)_\(stem)"
                )
            }
        }
        // Source cube for side-by-side comparison.
        let model = try Self.model("cube_50mm.obj")
        let src = ViewportMeshRenderData.flatShadedMesh(from: model.geometry)
        try StlExporter.write(
            meshes: [src],
            to: out.appending(path: "source_cube_50mm.stl"),
            solidName: "source_cube_50mm"
        )
    }

}
