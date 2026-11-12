import Foundation
import Testing
@testable import RefabArtist

/// Model Repair, Agent A: the fast lattice field (output-identical to the
/// per-sample path), the honest Rebuild (inside-out flip, errors surfaced),
/// and Make walls (thicken an open skin inward, outside exact, rim open).
struct ModelRepairWallsTests {

    // MARK: - Synthetic meshes

    /// Open-top cylinder cup: wall (outward wound) + bottom fan disk.
    static func openCup(radius r: Double = 20, height: Double = 30, segments: Int = 64, rings: Int = 8) -> MeshGeometryData {
        var v: [Vec3] = []
        var idx: [Int32] = []
        for k in 0..<rings {
            let z = height * Double(k) / Double(rings - 1)
            for i in 0..<segments {
                let a = 2 * Double.pi * Double(i) / Double(segments)
                v.append(Vec3(x: r * cos(a), y: r * sin(a), z: z))
            }
        }
        func w(_ k: Int, _ i: Int) -> Int32 { Int32(k * segments + (i % segments)) }
        for k in 0..<(rings - 1) {
            for i in 0..<segments {
                idx += [w(k, i), w(k, i + 1), w(k + 1, i + 1)]
                idx += [w(k, i), w(k + 1, i + 1), w(k + 1, i)]
            }
        }
        let c = Int32(v.count)
        v.append(Vec3(x: 0, y: 0, z: 0))
        for i in 0..<segments { idx += [w(0, i), c, w(0, i + 1)] }
        return MeshGeometryData(vertices: v, triangleIndices: idx)
    }

    static func reversed(_ g: MeshGeometryData) -> MeshGeometryData {
        var idx = g.triangleIndices
        var t = 0
        while t + 2 < idx.count { idx.swapAt(t + 1, t + 2); t += 3 }
        return MeshGeometryData(vertices: g.vertices, triangleIndices: idx)
    }

    static func summary(_ g: MeshGeometryData, name: String = "synthetic") -> MeshSummary {
        var lo = g.vertices[0], hi = g.vertices[0]
        for p in g.vertices {
            lo = Vec3(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
            hi = Vec3(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
        }
        return MeshSummary(
            name: name, path: "/tmp/\(name)", format: "obj", byteCount: 0,
            vertexObservationCount: g.vertices.count,
            faceCount: g.triangleIndices.count / 3,
            triangleCount: g.triangleIndices.count / 3,
            bounds: Bounds3D(min: lo, max: hi),
            geometry: g,
            preflight: MeshPreflight.analyze(geometry: g)
        )
    }

    static func signedVolume(_ g: MeshGeometryData) -> Double {
        var vol = 0.0
        var t = 0
        let i = g.triangleIndices
        while t + 2 < i.count {
            let a = g.vertices[Int(i[t])], b = g.vertices[Int(i[t + 1])], c = g.vertices[Int(i[t + 2])]
            vol += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)
            t += 3
        }
        return vol / 6
    }

    // MARK: - Part 1: lattice field is output-identical

    @Test
    func narrowBandDistanceMatchesUnboundedBelowTheBand() {
        let soup = TriangleSoup(Self.openCup())
        let grid = TriangleGrid(soup, targetCell: 3)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let p = Vec3(x: Double.random(in: -30...30, using: &rng),
                         y: Double.random(in: -30...30, using: &rng),
                         z: Double.random(in: -10...40, using: &rng))
            let exact = grid.nearestDistance(to: p)
            let banded = grid.nearestDistance(to: p, maxDistance: 4)
            if banded < 4 { #expect(banded == exact) } else { #expect(exact >= 4) }
        }
    }

    /// The prefilled, narrow-band, refined table must give Manifold exactly
    /// the surface the direct per-sample exact field gives — on an OPEN cup,
    /// whose winding "lid" crosses 0.5 far from any triangle (the case the
    /// exact refinement exists for).
    @Test
    func prefilledHealFieldExtractsTheIdenticalSurface() throws {
        let soup = TriangleSoup(Self.openCup(radius: 15, height: 20, segments: 40, rings: 5))
        let edge = 1.3
        let b = soup.bounds
        let lo = Vec3(x: b.min.x - 3 * edge, y: b.min.y - 3 * edge, z: b.min.z - 3 * edge)
        let hi = Vec3(x: b.max.x + 3 * edge, y: b.max.y + 3 * edge, z: b.max.z + 3 * edge)
        let grid = TriangleGrid(soup, targetCell: 2 * edge)
        let fwn = FastWindingTree(soup)
        let exact: @Sendable (Vec3) -> Double = { p in
            let d = grid.nearestDistance(to: p)
            return fwn.windingNumber(at: p) > 0.5 ? d : -d
        }
        let direct = try ManifoldEngine.toMesh(ManifoldEngine.levelSet(
            bounds: .init(lo: lo, hi: hi), edgeLength: edge, level: 0) { x, y, z in exact(Vec3(x: x, y: y, z: z)) })

        let band = 4 * edge
        let table = PrefilledField(
            lattice: LevelSetLattice(lo: lo, hi: hi, edgeLength: edge),
            field: { p in
                let d = grid.nearestDistance(to: p, maxDistance: band)
                return fwn.windingNumber(at: p) > 0.5 ? d : -d
            },
            fallback: exact)
        let refined = table.refineCrossings(needsExact: { abs($0) >= band }, exact: exact)
        let viaTable = try ManifoldEngine.toMesh(table.levelSet())

        #expect(refined > 0, "the open lid should need exact refinement")
        #expect(table.misses == 0)
        #expect(table.hits == table.lattice.sampleCount)
        #expect(viaTable == direct)
    }

    // MARK: - Part 2: honest Rebuild

    @Test
    func rebuildTurnsAnInsideOutCupRightSideOut() throws {
        let inverted = Self.reversed(Self.openCup(radius: 15, height: 20, segments: 40, rings: 5))
        let (rebuilt, receipt) = try MeshModifier.rebuildAsSolid(Self.summary(inverted), detail: 0.3)
        #expect(receipt.contains("inside-out"))
        #expect(rebuilt.triangleCount > 0)
        #expect(rebuilt.preflight.boundaryEdgeCount == 0)
        #expect(rebuilt.preflight.manifoldValidated)
        #expect(Self.signedVolume(rebuilt.geometry) > 0)
    }

    @Test
    func makeWatertightRebuildReportsWhyInsteadOfSilentNoOp() {
        // A single triangle has no inside in either orientation.
        let sheet = MeshGeometryData(
            vertices: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 10, y: 0, z: 0), Vec3(x: 0, y: 10, z: 0)],
            triangleIndices: [0, 1, 2])
        let model = Self.summary(sheet)
        let (out, message) = MeshModifier.makeWatertight(model, method: .rebuild, detail: 0.5, topHeight: 0)
        #expect(out.geometry == model.geometry)
        #expect(message?.hasPrefix("Can't rebuild") == true)
    }

    // MARK: - Part 3: Make walls

    @Test
    func wallsTurnAnOpenCupIntoAWalledVessel() throws {
        let r = 20.0, h = 30.0, t = 2.0
        let cup = Self.openCup(radius: r, height: h)
        let (walled, result) = try MeshModifier.makeWallsDetailed(Self.summary(cup), thickness: t)
        let report = walled.preflight

        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated)
        #expect(result.components == 1)
        #expect(result.openingsKeptOpen == 1)
        #expect(result.capInteriorTriangles == 0)
        #expect(result.untouchedFraction >= 0.99)
        #expect(result.innerWithinBandFraction >= 0.95)

        // Open top: nothing of the temporary lid remains inside the rim band.
        let idx = walled.geometry.triangleIndices
        var t0 = 0, lidTriangles = 0
        while t0 + 2 < idx.count {
            let ps = (0..<3).map { walled.geometry.vertices[Int(idx[t0 + $0])] }
            if ps.allSatisfy({ abs($0.z - h) < 1e-6 && ($0.x * $0.x + $0.y * $0.y).squareRoot() < r - 1.5 * t }) {
                lidTriangles += 1
            }
            t0 += 3
        }
        #expect(lidTriangles == 0)

        // Volume ≈ wall ring + floor (polygon areas: 64-gon, not a circle).
        let n = 64.0
        func area(_ rr: Double) -> Double { 0.5 * n * rr * rr * sin(2 * Double.pi / n) }
        let expected = (area(r) - area(r - t)) * h + area(r - t) * t
        let volume = Self.signedVolume(walled.geometry)
        #expect(abs(volume - expected) / expected < 0.10, "volume \(volume) vs expected \(expected)")
    }

    @Test
    func wallsRefuseAClosedSolidAndABadThickness() throws {
        let cup = Self.openCup(radius: 10, height: 10, segments: 24, rings: 3)
        let closed = try OpeningCapper.close(cup, topHeight: 0).geometry
        #expect(throws: WallMaker.WallError.noOpenings) {
            _ = try MeshModifier.makeWalls(Self.summary(closed), thickness: 1)
        }
        #expect(throws: WallMaker.WallError.badThickness) {
            _ = try MeshModifier.makeWalls(Self.summary(cup), thickness: 0)
        }
        #expect(throws: WallMaker.WallError.wallTooThick) {
            _ = try MeshModifier.makeWalls(Self.summary(cup), thickness: 50)
        }
    }

    /// A tube open at both ends (wall only, outward wound).
    static func openTube(radius r: Double = 20, height: Double = 30, segments: Int = 64, rings: Int = 8) -> MeshGeometryData {
        let cup = openCup(radius: r, height: height, segments: segments, rings: rings)
        // Drop the bottom fan (the last `segments` triangles) and its centre.
        let wallTriangles = (rings - 1) * segments * 2
        return MeshGeometryData(vertices: Array(cup.vertices.dropLast()),
                                triangleIndices: Array(cup.triangleIndices.prefix(3 * wallTriangles)))
    }

    /// Make walls with one opening Closed: the tube becomes a cup whose
    /// closed end is a floor as thick as the wall (the closed cap is part of
    /// the skin the wall is measured from), one closed solid, the other rim
    /// still open.
    @Test
    func closedOpeningGetsAFloorOfTheWallThickness() throws {
        let r = 20.0, h = 30.0, t = 2.0
        let tube = Self.openTube(radius: r, height: h)
        let diagnosis = try #require(OpeningCapper.diagnose(tube))
        #expect(diagnosis.openings.map(\.placement) == ["bottom", "top"])
        let closeBottom = OpeningCapper.OpeningChoice(signature: diagnosis.openings[0].signature, closedInWalls: true)
        let (walled, result) = try MeshModifier.makeWallsDetailed(Self.summary(tube), thickness: t, choices: [closeBottom])
        let report = walled.preflight

        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated)
        #expect(result.components == 1)
        #expect(result.openingsKeptOpen == 1)
        #expect(result.closedOpenings.count == 1)
        let floor = try #require(result.closedOpenings.first)
        #expect(floor.number == 1 && floor.partName == "floor")
        let measured = try #require(floor.measuredThickness)
        #expect(abs(measured - t) < 0.1 * t, "floor \(measured) mm")
        #expect(result.receipt.contains("opening 1 closed with a"))
        #expect(result.untouchedFraction >= 0.99)

        // Same solid as walls on the open-top cup: wall ring + floor.
        let n = 64.0
        func area(_ rr: Double) -> Double { 0.5 * n * rr * rr * sin(2 * Double.pi / n) }
        let expected = (area(r) - area(r - t)) * h + area(r - t) * t
        let volume = Self.signedVolume(walled.geometry)
        #expect(abs(volume - expected) / expected < 0.10, "volume \(volume) vs expected \(expected)")

        // Every opening closed would seal the model: refused with the reason.
        let closeBoth = diagnosis.openings.map { OpeningCapper.OpeningChoice(signature: $0.signature, closedInWalls: true) }
        #expect(throws: WallMaker.WallError.allOpeningsClosed) {
            _ = try MeshModifier.makeWalls(Self.summary(tube), thickness: t, choices: closeBoth)
        }
    }
}
