import Foundation
import Testing
@testable import RefabArtist

/// `OpeningCapper.importedTopologyReport` — the truthful, unit-independent
/// topology report the GUI gives the imported model in place of
/// `MeshPreflight.analyze`'s raw report (absolute tolerances in the file's own
/// units, zero-area triangles skipped when counting edges).
struct ImportedTopologyReportTests {

    // MARK: - Synthetic

    /// A closed, outward-wound UV sphere (`segments` × `rings`), indexed.
    private static func sphere(radius: Double = 1, segments: Int = 24, rings: Int = 12) -> MeshGeometryData {
        var vertices: [Vec3] = [Vec3(x: 0, y: 0, z: radius)]
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            for s in 0..<segments {
                let theta = 2 * Double.pi * Double(s) / Double(segments)
                vertices.append(Vec3(x: radius * sin(phi) * cos(theta), y: radius * sin(phi) * sin(theta), z: radius * cos(phi)))
            }
        }
        vertices.append(Vec3(x: 0, y: 0, z: -radius))
        let south = Int32(vertices.count - 1)
        func ring(_ r: Int, _ s: Int) -> Int32 { Int32(1 + (r - 1) * segments + (s % segments)) }
        var idx: [Int32] = []
        for s in 0..<segments { idx += [0, ring(1, s), ring(1, s + 1)] }
        for r in 1..<(rings - 1) {
            for s in 0..<segments {
                idx += [ring(r, s), ring(r + 1, s), ring(r + 1, s + 1)]
                idx += [ring(r, s), ring(r + 1, s + 1), ring(r, s + 1)]
            }
        }
        for s in 0..<segments { idx += [south, ring(rings - 1, s + 1), ring(rings - 1, s)] }
        return MeshGeometryData(vertices: vertices, triangleIndices: idx)
    }

    private static func scaled(_ g: MeshGeometryData, _ f: Double) -> MeshGeometryData {
        MeshGeometryData(vertices: g.vertices.map { Vec3(x: $0.x * f, y: $0.y * f, z: $0.z * f) }, triangleIndices: g.triangleIndices)
    }

    /// Triangle soup (every triangle its own three vertices), like an STL.
    private static func soup(_ g: MeshGeometryData) -> MeshGeometryData {
        var v: [Vec3] = []
        var i: [Int32] = []
        for k in g.triangleIndices {
            i.append(Int32(v.count))
            v.append(g.vertices[Int(k)])
        }
        return MeshGeometryData(vertices: v, triangleIndices: i)
    }

    @Test
    func closedSolidReportsTheSameTopologyInEveryUnit() {
        // A 2 cm sphere expressed in inches, millimetres, a unit box and
        // metres-as-kilometres: small triangles in small units are what the
        // raw preflight misreads as degenerate.
        let base = Self.soup(Self.sphere(radius: 1, segments: 96, rings: 48))
        var reports: [MeshPreflightReport] = []
        for factor in [0.0005, 1.0 / 25.4, 1.0, 20.0, 1000.0] {
            let report = OpeningCapper.importedTopologyReport(Self.scaled(base, factor))
            #expect(report.boundaryEdgeCount == 0, "factor \(factor)")
            #expect(report.nonManifoldEdgeCount == 0, "factor \(factor)")
            #expect(report.degenerateTriangleCount == 0, "factor \(factor)")
            #expect(report.isWatertight, "factor \(factor)")
            #expect(report.manifoldValidated, "factor \(factor)")
            reports.append(report)
        }
        #expect(Set(reports.map(\.uniqueVertexCount)).count == 1)
        // The raw preflight really does misread the small-unit copy (the bug
        // this report exists for).
        let rawSmall = MeshPreflight.analyze(geometry: Self.scaled(base, 0.0005))
        #expect(rawSmall.boundaryEdgeCount > 0 || rawSmall.degenerateTriangleCount > 0)
    }

    @Test
    func zeroAreaSliverInsideAClosedSurfaceClosesItsNeighbours() {
        // Split one sphere triangle's edge at its midpoint: the neighbour
        // across that edge becomes a T-junction fixed by a collinear sliver.
        var g = Self.sphere(radius: 10, segments: 24, rings: 12)
        let a = g.triangleIndices[0], b = g.triangleIndices[1], c = g.triangleIndices[2]
        // Find the other triangle on edge (b, c).
        var other = -1
        for t in 1..<(g.triangleIndices.count / 3) {
            let tri = Array(g.triangleIndices[(3 * t)..<(3 * t + 3)])
            for k in 0..<3 where tri[k] == c && tri[(k + 1) % 3] == b { other = t }
        }
        #expect(other >= 0)
        guard other >= 0 else { return }
        let pb = g.vertices[Int(b)], pc = g.vertices[Int(c)]
        let m = Int32(g.vertices.count)
        g.vertices.append(Vec3(x: (pb.x + pc.x) / 2, y: (pb.y + pc.y) / 2, z: (pb.z + pc.z) / 2))
        // Triangle 0 (a, b, c) -> (a, b, m) + (a, m, c), so its side of the
        // edge is now b→m, m→c while the neighbour still has c→b. The
        // collinear sliver (b, c, m) pairs all three: b→c with c→b, c→m with
        // m→c, m→b with b→m.
        g.triangleIndices.replaceSubrange(0..<3, with: [a, b, m, a, m, c])
        g.triangleIndices += [b, c, m]
        let report = OpeningCapper.importedTopologyReport(g)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        let topology = OpeningCapper.importedTopology(g)
        #expect(topology.zeroAreaSurfaceTriangles == 1)
        #expect(topology.debrisTriangles == 0)
        #expect(report.degenerateTriangleCount == 0)
    }

    @Test
    func isolatedZeroAreaTriangleIsDebrisNotBoundary() {
        var g = Self.sphere(radius: 10)
        let n = Int32(g.vertices.count)
        g.vertices += [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0), Vec3(x: 2, y: 0, z: 0)]
        g.triangleIndices += [n, n + 1, n + 2]
        let topology = OpeningCapper.importedTopology(g)
        #expect(topology.report.boundaryEdgeCount == 0)
        #expect(topology.report.nonManifoldEdgeCount == 0)
        #expect(topology.debrisTriangles == 1)
        #expect(topology.report.degenerateTriangleCount == 1)
    }

    @Test
    func openCupStillReportsItsOpening() {
        // Remove the north cap fan: a real opening.
        var g = Self.sphere(radius: 10, segments: 24, rings: 12)
        g.triangleIndices.removeFirst(24 * 3)
        let report = OpeningCapper.importedTopologyReport(Self.scaled(g, 1.0 / 25.4))
        #expect(report.boundaryEdgeCount == 24)
        #expect(!report.isWatertight)
    }

    // MARK: - Repo fixtures

    @Test(arguments: [
        "tests/fixtures/real-world/spur_gear_T20_M2.stl",
        "tests/fixtures/pathological/cube_zero_area_face.stl",
    ])
    func fixtureReportsClosed(_ path: String) throws {
        let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: path))
        let topology = OpeningCapper.importedTopology(model.geometry)
        print("TRUTHFUL \(path): raw=\(model.preflight) truthful=\(topology)")
        #expect(topology.report.boundaryEdgeCount == 0)
        #expect(topology.report.nonManifoldEdgeCount == 0)
        // The stored raw report is untouched (headless gates read it).
        #expect(model.preflight == MeshPreflight.analyze(geometry: model.geometry))
    }

    // MARK: - Real models

    /// The hand scan is committed (`app/RefabArtist/Tests/Fixtures/hand-scans/`).
    /// The two other models are not part of the repository: each test runs
    /// only when its environment variable names a copy of the file.
    static let handStand = repoRoot()
        .appending(path: "app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex3.obj").path
    /// A large relief in inch units (about 890k triangles): REFAB_SARDINIERS_OBJ=<path to Sardiniers6.obj>.
    static let sardiniers = externalModelPath("REFAB_SARDINIERS_OBJ")
    /// An open cup scan in inch units: REFAB_PINEAPPLE_CUP_OBJ=<path to pineapple_cup.obj>.
    static let pineappleCup = externalModelPath("REFAB_PINEAPPLE_CUP_OBJ")

    private static func externalModelPath(_ variable: String) -> String {
        ProcessInfo.processInfo.environment[variable] ?? ""
    }

    /// The model as the GUI builds it (`ContentView.scaledModel`): imported,
    /// unit-scaled through the viewport cache, carrying the truthful report
    /// measured on the imported model.
    private static func guiModel(_ path: String, unit: ImportUnitPreset) throws -> (raw: MeshSummary, gui: MeshSummary, topology: OpeningCapper.ImportedTopology, seconds: Double) {
        let raw = try MeshInspector.inspect(url: URL(fileURLWithPath: path))
        let start = Date()
        let measured = ContentView.ImportedTopologyReport.measure(raw)
        let seconds = Date().timeIntervalSince(start)
        let f = MeshScaler.combinedFactor(unit: unit, userScale: 1)
        let scaled = ViewportGeometryCache.shared.transformedModel(
            for: raw, scale: Vec3(x: f, y: f, z: f), rotationDegrees: Vec3(x: 0, y: 0, z: 0)
        )
        // Until the truthful report lands the GUI shows the raw one.
        #expect(scaled.preflight == raw.preflight)
        let gui = measured.applied(to: scaled, importedFrom: raw)
        let topology = OpeningCapper.importedTopology(raw.geometry)
        #expect(gui.preflight == topology.report)
        #expect(gui.geometry == scaled.geometry)
        return (raw, gui, topology, seconds)
    }

    @Test
    func splitByUndercutsSourceGateTrustsASuppliedReport() async throws {
        // A closed 0.1-radius sphere: its polar triangles fall under the raw
        // preflight's absolute area floor, so the raw report opens phantom
        // holes around them.
        let tiny = Self.soup(Self.sphere(radius: 0.1, segments: 96, rings: 48))
        let raw = MeshPreflight.analyze(geometry: tiny)
        #expect(raw.boundaryEdgeCount > 0)
        let truthful = OpeningCapper.importedTopologyReport(tiny)
        #expect(truthful.boundaryEdgeCount == 0)
        #expect(truthful.isWatertight)

        let measuredHere = try await UndercutSplitPlanner.plan(geometry: tiny, settings: .defaultValue)
        #expect(measuredHere.statusMessage.contains("open boundary edges"))
        let supplied = try await UndercutSplitPlanner.plan(geometry: tiny, settings: .defaultValue, sourcePreflight: truthful)
        #expect(!supplied.statusMessage.contains("open boundary edges"))
        print("TRUTHFUL undercut gate: raw=\(raw) measured-here: \(measuredHere.status) '\(measuredHere.statusMessage)' supplied: \(supplied.status) '\(supplied.statusMessage)'")
    }

    @Test
    func truthfulReportOnlyAttachesToTheModelItWasMeasuredOn() {
        let sphere = Self.soup(Self.sphere(radius: 1, segments: 48, rings: 24))
        func summary(_ g: MeshGeometryData, path: String) -> MeshSummary {
            MeshSummary(
                name: path, path: path, format: "stl-binary", byteCount: 0,
                vertexObservationCount: g.vertices.count, faceCount: g.triangleIndices.count / 3,
                triangleCount: g.triangleIndices.count / 3,
                bounds: Bounds3D(min: Vec3(x: -1, y: -1, z: -1), max: Vec3(x: 1, y: 1, z: 1)),
                geometry: g, preflight: MeshPreflight.analyze(geometry: g)
            )
        }
        let small = summary(Self.scaled(sphere, 1.0 / 25.4), path: "/a.stl")
        let other = summary(Self.scaled(sphere, 1.0 / 25.4), path: "/b.stl")
        let measured = ContentView.ImportedTopologyReport.measure(small)
        #expect(measured.report.isWatertight)
        let scaled = MeshScaler.scaled(small, factor: 25.4)
        #expect(measured.applied(to: scaled, importedFrom: small).preflight == measured.report)
        // A report measured on another model is never attached.
        let otherScaled = MeshScaler.scaled(other, factor: 25.4)
        #expect(measured.applied(to: otherScaled, importedFrom: other).preflight == other.preflight)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sardiniers), "set REFAB_SARDINIERS_OBJ to a Sardiniers6.obj to run"))
    func sardiniersInInchesIsAClosedSolid() throws {
        let (raw, gui, topology, seconds) = try Self.guiModel(Self.sardiniers, unit: .inches)
        print("TRUTHFUL Sardiniers6 (\(raw.triangleCount) tris, \(String(format: "%.1f", seconds)) s): raw=\(raw.preflight) truthful=\(topology)")
        // The raw report is the bug: it calls this valid solid open.
        #expect(raw.preflight.boundaryEdgeCount > 0)
        #expect(gui.preflight.boundaryEdgeCount == 0)
        #expect(gui.preflight.nonManifoldEdgeCount == 0)
        #expect(gui.preflight.isWatertight)
        // Same answer measured on the scaled (mm) geometry.
        #expect(OpeningCapper.importedTopologyReport(gui.geometry) == gui.preflight)
        // What the Split-by-Undercuts source gate measured on the mm geometry
        // before (raw analyze), and the welded-parity count Directional
        // Accessibility gates on.
        let rawOnScaled = MeshPreflight.analyze(geometry: gui.geometry)
        let parityOpen = PartitionGeometry.openEdgeCount(gui.geometry)
        print("TRUTHFUL Sardiniers6 mm geometry: raw analyze=\(rawOnScaled) welded-parity open=\(parityOpen)")
        #expect(parityOpen == 0)
        // The GUI master gates no longer refuse it for open geometry.
        #expect(MotherMoldUIContract.openGeometryDisabledReason(preflight: gui.preflight) == nil)
        #expect(MotherMoldUIContract.openGeometryDisabledReason(preflight: raw.preflight) != nil)
        let accepted = try MotherMoldPlanner.validateMaster(gui)
        print("TRUTHFUL Sardiniers6 master gate diagnostics: \(accepted.map(\.message))")
        #expect(throws: MotherMoldPlannerError.self) { try MotherMoldPlanner.validateMaster(Self.withRawPreflight(gui, raw)) }
        let status = MotherMoldUIContract.buildStatus(
            preflight: gui.preflight, isBuilding: false, buildStage: nil, isStale: false, plan: nil,
            settings: MotherMoldSettings.defaultValue.sanitized, buildFailure: nil, buildMessage: nil
        )
        #expect(status.kind != .needsRepair)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: pineappleCup), "set REFAB_PINEAPPLE_CUP_OBJ to a pineapple_cup.obj to run"))
    func pineappleCupIsStillOpenAndRefused() throws {
        let (raw, gui, topology, seconds) = try Self.guiModel(Self.pineappleCup, unit: .inches)
        print("TRUTHFUL pineapple_cup (\(raw.triangleCount) tris, \(String(format: "%.1f", seconds)) s): raw=\(raw.preflight) truthful=\(topology)")
        #expect(gui.preflight.boundaryEdgeCount > 0)
        #expect(!gui.preflight.isWatertight)
        #expect(MotherMoldUIContract.openGeometryDisabledReason(preflight: gui.preflight) != nil)
        #expect(throws: MotherMoldPlannerError.self) { try MotherMoldPlanner.validateMaster(gui) }
        let status = MotherMoldUIContract.buildStatus(
            preflight: gui.preflight, isBuilding: false, buildStage: nil, isStale: false, plan: nil,
            settings: MotherMoldSettings.defaultValue.sanitized, buildFailure: nil, buildMessage: nil
        )
        #expect(status.kind == .needsRepair)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: handStand)))
    func handStandShowsItsRealNonManifoldEdgesAndNoPhantomOpenEdges() throws {
        let (raw, gui, topology, seconds) = try Self.guiModel(Self.handStand, unit: .millimeters)
        let diagnosis = OpeningCapper.diagnose(gui.geometry)
        print("TRUTHFUL handStand_ex3 (\(raw.triangleCount) tris, \(String(format: "%.1f", seconds)) s): raw=\(raw.preflight) truthful=\(topology) diagnosis: open=\(diagnosis?.boundaryEdges ?? -1) nonManifold=\(diagnosis?.nonManifoldEdges ?? -1) — \(diagnosis?.sentence ?? "nil")")
        #expect(gui.preflight.boundaryEdgeCount == 0)
        #expect(gui.preflight.nonManifoldEdgeCount > 0)
    }

    private static func withRawPreflight(_ gui: MeshSummary, _ raw: MeshSummary) -> MeshSummary {
        var copy = gui
        copy.preflight = raw.preflight
        return copy
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
