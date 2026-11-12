import Foundation
import simd
import Testing
@testable import RefabArtist

/// `OpeningCapper` closes the openings of an open skin (a vessel mouth, a
/// tube's two ends, a pinhole) without re-meshing it: every kept triangle's
/// corner positions stay bit-identical, only the boundary loops get capped.
///
/// These tests build small synthetic meshes in code — a finely tessellated
/// open-top cylinder cup (a vertical wall plus a triangulated, outward-wound
/// bottom disk) — rather than loading fixtures, so the topology of each case
/// (a clean opening, a pinhole, a doubled flap, a loose fragment, a genuine
/// non-manifold edge, an inside-out shell) is exactly known.
struct OpeningCapperTests {

    // MARK: - Synthetic mesh builders

    /// A vertical cylindrical wall (`rings` horizontal rings, `segments`
    /// vertices per ring, consistently wound outward) from z = 0 to
    /// z = `height`, optionally capped at the bottom by a triangulated disk
    /// fan made of `capRings` concentric rings (1 = a plain rim-to-center
    /// fan; more = a finer mesh near the center). `capRings == nil` leaves
    /// the bottom open too, producing a tube open at both ends.
    ///
    /// Vertex layout (load-bearing for the tests below, which reference wall
    /// vertices by ring/segment): wall rings are appended first, ring-major
    /// then segment-minor (ring `k`, segment `i` -> vertex index
    /// `k * segments + i`), so the wall's vertex indices are stable and
    /// independent of `capRings`. Cap-only vertices (extra concentric rings,
    /// then the center point last) are appended afterward.
    private static func openCup(
        radius: Double = 20,
        height: Double = 30,
        segments: Int = 48,
        rings: Int = 6,
        capRings: Int? = 1
    ) -> MeshGeometryData {
        precondition(rings >= 2 && segments >= 8)
        var vertices: [Vec3] = []
        var indices: [Int32] = []

        // Wall rings, z = 0 ... height.
        var wall: [[Int32]] = []
        for k in 0..<rings {
            let z = height * Double(k) / Double(rings - 1)
            var ring: [Int32] = []
            ring.reserveCapacity(segments)
            for i in 0..<segments {
                let theta = 2.0 * Double.pi * Double(i) / Double(segments)
                ring.append(Int32(vertices.count))
                vertices.append(Vec3(x: radius * cos(theta), y: radius * sin(theta), z: z))
            }
            wall.append(ring)
        }

        // Wall quads (A, B, C) + (A, C, D), A = ring k seg i, outward wound
        // (verified analytically: for P(theta, z) = (r cos theta, r sin
        // theta, z), d/dtheta x d/dz = r * (cos theta, sin theta, 0), the
        // outward radial direction).
        for k in 0..<(rings - 1) {
            for i in 0..<segments {
                let iN = (i + 1) % segments
                let a = wall[k][i], b = wall[k][iN], c = wall[k + 1][iN], d = wall[k + 1][i]
                indices.append(contentsOf: [a, b, c])
                indices.append(contentsOf: [a, c, d])
            }
        }

        guard let capRings, capRings >= 1 else {
            return MeshGeometryData(vertices: vertices, triangleIndices: indices)
        }

        // Concentric cap rings, radius r * (capRings - k) / capRings for
        // k = 0 (rim, reuses the wall's bottom ring) ... capRings - 1
        // (innermost, closest to center).
        var cap: [[Int32]] = [wall[0]]
        for k in 1..<capRings {
            let rho = radius * Double(capRings - k) / Double(capRings)
            var ring: [Int32] = []
            ring.reserveCapacity(segments)
            for i in 0..<segments {
                let theta = 2.0 * Double.pi * Double(i) / Double(segments)
                ring.append(Int32(vertices.count))
                vertices.append(Vec3(x: rho * cos(theta), y: rho * sin(theta), z: 0))
            }
            cap.append(ring)
        }

        // Cap bands: outward (downward) wound. A/B sit on the ring CLOSER to
        // the center (index k + 1, smaller radius), C/D on the ring FARTHER
        // out (index k, larger radius) — going inner -> outer is "increasing
        // rho", which by the same tangent-cross-product argument as the wall
        // (d/dtheta x d/drho = (0, 0, -rho), pointing down/outward for the
        // bottom cap) makes (A, B, C) + (A, C, D) outward wound. Verified by
        // direct cross-product computation on a concrete example.
        for k in 0..<(capRings - 1) {
            for i in 0..<segments {
                let iN = (i + 1) % segments
                let a = cap[k + 1][i], b = cap[k + 1][iN], c = cap[k][iN], d = cap[k][i]
                indices.append(contentsOf: [a, b, c])
                indices.append(contentsOf: [a, c, d])
            }
        }

        // Fan from the innermost cap ring to the center point (appended
        // last). Direct computation shows (inner_i, center, inner_{i+1}) is
        // outward (downward) wound, not (inner_i, inner_{i+1}, center).
        let center = Int32(vertices.count)
        vertices.append(Vec3(x: 0, y: 0, z: 0))
        let inner = cap[capRings - 1]
        for i in 0..<segments {
            let iN = (i + 1) % segments
            indices.append(contentsOf: [inner[i], center, inner[iN]])
        }

        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// Vertex index of wall ring `k`, angular segment `i`, for a mesh built
    /// by `openCup` with the given `segments` (see the layout note there).
    private static func wallVertex(ring k: Int, seg i: Int, segments: Int = 48) -> Int32 {
        Int32(k * segments + i)
    }

    /// Reverses every triangle's winding (swap the last two corners).
    private static func flippedWinding(_ g: MeshGeometryData) -> MeshGeometryData {
        var idx = g.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            idx.swapAt(t + 1, t + 2)
            t += 3
        }
        return MeshGeometryData(vertices: g.vertices, triangleIndices: idx)
    }

    /// Removes the first triangle that uses `vertexIndex` as a corner.
    private static func removingTriangle(_ g: MeshGeometryData, containing vertexIndex: Int32) -> MeshGeometryData {
        var idx = g.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            if idx[t] == vertexIndex || idx[t + 1] == vertexIndex || idx[t + 2] == vertexIndex {
                idx.removeSubrange(t..<(t + 3))
                break
            }
            t += 3
        }
        return MeshGeometryData(vertices: g.vertices, triangleIndices: idx)
    }

    /// A closed, outward-wound tetrahedron with edge length `scale`, offset
    /// by `offset` — used as a tiny closed body far from the cup.
    private static func closedTetrahedron(scale: Double, offset: Vec3) -> MeshGeometryData {
        func p(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
            Vec3(x: offset.x + x * scale, y: offset.y + y * scale, z: offset.z + z * scale)
        }
        let vertices = [p(0, 0, 0), p(1, 0, 0), p(0, 1, 0), p(0, 0, 1)]
        let indices: [Int32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// A closed, outward-wound cube, side `side`.
    private static func closedCube(side: Double = 10) -> MeshGeometryData {
        let s = side
        let vertices = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0), Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s), Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s)
        ]
        let indices: [Int32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5,
            2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7
        ]
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// Concatenates two geometries, offsetting `b`'s indices past `a`'s.
    private static func union(_ a: MeshGeometryData, _ b: MeshGeometryData) -> MeshGeometryData {
        let offset = Int32(a.vertices.count)
        let shifted = b.triangleIndices.map { $0 + offset }
        return MeshGeometryData(vertices: a.vertices + b.vertices, triangleIndices: a.triangleIndices + shifted)
    }

    private static func summary(for geometry: MeshGeometryData, name: String = "cup.obj") -> MeshSummary {
        MeshSummary(
            name: name,
            path: "/tmp/\(name)",
            format: "obj",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: nil,
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    /// Signed volume via the divergence theorem: sum(dot(a, cross(b, c))) / 6,
    /// positive for an outward-wound closed surface.
    private static func signedVolume(_ g: MeshGeometryData) -> Double {
        var v = 0.0
        var t = 0
        let idx = g.triangleIndices
        while t + 2 < idx.count {
            let a = g.vertices[Int(idx[t])], b = g.vertices[Int(idx[t + 1])], c = g.vertices[Int(idx[t + 2])]
            v += (a.x * (b.y * c.z - b.z * c.y)
                  - a.y * (b.x * c.z - b.z * c.x)
                  + a.z * (b.x * c.y - b.y * c.x)) / 6.0
            t += 3
        }
        return v
    }

    /// Each triangle's 3 corner positions as an order-independent key, so
    /// "is this original triangle still present" survives re-triangulation
    /// elsewhere in the mesh or incidental winding differences.
    private static func triangleCornerKeys(_ g: MeshGeometryData) -> Set<[Double]> {
        var result = Set<[Double]>()
        var t = 0
        let idx = g.triangleIndices
        while t + 2 < idx.count {
            let corners = [g.vertices[Int(idx[t])], g.vertices[Int(idx[t + 1])], g.vertices[Int(idx[t + 2])]]
                .sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
            result.insert(corners.flatMap { [$0.x, $0.y, $0.z] })
            t += 3
        }
        return result
    }

    // MARK: - 1. Open cup, flat cap

    @Test
    func openCupFlatCapClosesToTheCylinderVolume() throws {
        let cup = Self.openCup()
        let originalKeys = Self.triangleCornerKeys(cup)

        let result = try OpeningCapper.close(cup, topHeight: 0)

        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(result.openingsClosed == 1)
        #expect(result.untouchedFraction == 1.0)
        #expect(originalKeys.isSubset(of: Self.triangleCornerKeys(result.geometry)))

        let volume = Self.signedVolume(result.geometry)
        let expected = Double.pi * 20 * 20 * 30
        #expect(volume > 0)
        #expect(abs(volume - expected) / expected < 0.05)
    }

    // MARK: - 2. Dome / dish

    @Test
    func domeAndDishChangeEnclosedVolumeAsExpected() throws {
        let flat = try OpeningCapper.close(Self.openCup(), topHeight: 0)
        let dome = try OpeningCapper.close(Self.openCup(), topHeight: 8)
        let dish = try OpeningCapper.close(Self.openCup(), topHeight: -8)

        let flatVolume = Self.signedVolume(flat.geometry)
        let domeVolume = Self.signedVolume(dome.geometry)
        let dishVolume = Self.signedVolume(dish.geometry)

        #expect(domeVolume > flatVolume)
        #expect(dishVolume < flatVolume)
        // The height is measured on the finished cap (root-finding on the
        // level, stopped within 0.1% of the target), not assumed.
        #expect(abs(dome.appliedTopHeight - 8) < 0.05)
        #expect(abs(dish.appliedTopHeight + 8) < 0.05)
        #expect(dome.capIntersections == 0)
        #expect(dish.capIntersections == 0)
    }

    // MARK: - 3. Inverted cup

    @Test
    func invertedCupIsFlippedRightSideOut() throws {
        let inverted = Self.flippedWinding(Self.openCup())

        let result = try OpeningCapper.close(inverted, topHeight: 0)

        #expect(result.flippedInsideOut == true)
        #expect(Self.signedVolume(result.geometry) > 0)
    }

    // MARK: - 4. Tube open at both ends

    @Test
    func tubeOpenAtBothEndsClosesBothOpenings() throws {
        let tube = Self.openCup(capRings: nil)

        let result = try OpeningCapper.close(tube, topHeight: 0)

        #expect(result.openingsClosed == 2)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
    }

    // MARK: - 5. Pinhole

    @Test
    func pinholeIsDiagnosedAndFilledSeparatelyFromTheMainOpening() throws {
        // A finely tessellated bottom (12 concentric rings) so the innermost
        // fan triangle near the center is small relative to the model.
        let fineCup = Self.openCup(capRings: 12)
        let centerVertex = Int32(fineCup.vertices.count - 1)
        let withPinhole = Self.removingTriangle(fineCup, containing: centerVertex)

        let diagnosis = try #require(OpeningCapper.diagnose(withPinhole))
        #expect(diagnosis.pinholes == 1)
        #expect(diagnosis.openings.count == 1)

        let result = try OpeningCapper.close(withPinhole, topHeight: 0)
        #expect(result.pinholesFilled >= 1)
        #expect(result.openingsClosed == 1)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
    }

    // MARK: - 6. Doubled ("back-to-back") triangle flap

    @Test
    func doubledTriangleFlapOnTheWallIsRemovedAndTheCupStillCloses() throws {
        var cup = Self.openCup()
        // An interior wall triangle (ring 1 -> ring 2, segment 0), safely
        // away from the open top rim.
        let a = Self.wallVertex(ring: 1, seg: 0)
        let b = Self.wallVertex(ring: 1, seg: 1)
        let c = Self.wallVertex(ring: 2, seg: 1)
        // Two extra copies on the same 3 corners: one matching winding, one
        // reversed — the "back-to-back doubled flap".
        cup.triangleIndices.append(contentsOf: [a, b, c])
        cup.triangleIndices.append(contentsOf: [a, c, b])

        let diagnosis = try #require(OpeningCapper.diagnose(cup))
        #expect(diagnosis.doubledTrianglesRemoved > 0)

        let result = try OpeningCapper.close(cup, topHeight: 0)
        #expect(result.openingsClosed == 1)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.boundaryEdgeCount == 0)
    }

    // MARK: - 7. Loose fragment

    @Test
    func looseOpenFragmentFarFromTheCupIsRemoved() throws {
        let strayVertices = [
            Vec3(x: 200, y: 0, z: 0), Vec3(x: 200.1, y: 0, z: 0), Vec3(x: 200, y: 0.1, z: 0)
        ]
        var cup = Self.openCup()
        let offset = Int32(cup.vertices.count)
        cup.vertices.append(contentsOf: strayVertices)
        cup.triangleIndices.append(contentsOf: [offset, offset + 1, offset + 2])

        let diagnosis = try #require(OpeningCapper.diagnose(cup))
        #expect(diagnosis.looseFragments == 1)

        let result = try OpeningCapper.close(cup, topHeight: 0)
        #expect(result.openingsClosed == 1)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
    }

    // MARK: - 8. Small closed body is never removed (intent guard)

    @Test
    func smallClosedTetrahedronIsKeptNotTreatedAsALooseFragment() throws {
        let tetra = Self.closedTetrahedron(scale: 1, offset: Vec3(x: 200, y: 0, z: 0))
        let combined = Self.union(Self.openCup(), tetra)
        let tetraKeys = Self.triangleCornerKeys(tetra)

        let diagnosis = try #require(OpeningCapper.diagnose(combined))
        #expect(diagnosis.looseFragments == 0)

        let result = try OpeningCapper.close(combined, topHeight: 0)
        #expect(tetraKeys.isSubset(of: Self.triangleCornerKeys(result.geometry)))
    }

    // MARK: - 9. Closed mesh: nothing to close

    @Test
    func closedCubeHasNothingToClose() {
        let cube = Self.closedCube()

        do {
            _ = try OpeningCapper.close(cube, topHeight: 0)
            Issue.record("Expected OpeningCapper.close to throw .nothingToClose on a closed cube")
        } catch OpeningCapper.CapError.nothingToClose {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func makeWatertightCloseOpeningsLeavesAClosedModelUnchangedWithAMessage() {
        let model = Self.summary(for: Self.closedCube())

        let (updated, message) = MeshModifier.makeWatertight(model, method: .closeOpenings, detail: 1.0, topHeight: 0)

        #expect(updated == model)
        #expect(message != nil)
    }

    // MARK: - 10. Genuine non-manifold edge (not a doubled flap)

    @Test
    func genuineNonManifoldEdgeIsReportedAndBlocksClose() {
        // Three triangles fanning off one shared edge (u, v) with three
        // distinct apexes — a "book" with 3 pages, not a doubled flap (the
        // three triangles do not share all 3 corners with each other).
        let u = Vec3(x: 0, y: 0, z: 0)
        let v = Vec3(x: 10, y: 0, z: 0)
        let w1 = Vec3(x: 5, y: 10, z: 0)
        let w2 = Vec3(x: 5, y: -10, z: 0)
        let w3 = Vec3(x: 5, y: 0, z: 10)
        let mesh = MeshGeometryData(
            vertices: [u, v, w1, w2, w3],
            triangleIndices: [0, 1, 2, 0, 1, 3, 0, 1, 4]
        )

        let diagnosis = OpeningCapper.diagnose(mesh)
        #expect((diagnosis?.nonManifoldEdges ?? 0) > 0)
        #expect(diagnosis?.canCloseOpenings == false)

        do {
            _ = try OpeningCapper.close(mesh, topHeight: 0)
            Issue.record("Expected OpeningCapper.close to throw .needsRebuild on a non-manifold edge")
        } catch OpeningCapper.CapError.needsRebuild(_) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 11. Diagnosis sentence

    @Test
    func diagnosisSentenceMentionsOneOpening() {
        let diagnosis = OpeningCapper.diagnose(Self.openCup())

        #expect(diagnosis?.sentence.contains("1 opening") == true)
    }

    // MARK: - Fix in place (near-solid scans)

    /// A closed, outward-wound UV sphere: north pole (index 0), then
    /// `rings - 1` latitude rings of `segments` vertices (ring k, segment i ->
    /// index 1 + (k - 1) * segments + i), then the south pole (last).
    private static func uvSphere(radius: Double = 20, segments: Int = 32, rings: Int = 16,
                                 center: Vec3 = Vec3(x: 0, y: 0, z: 0)) -> MeshGeometryData {
        var vertices = [Vec3(x: center.x, y: center.y, z: center.z + radius)]
        for k in 1..<rings {
            let phi = Double.pi * Double(k) / Double(rings)
            for i in 0..<segments {
                let theta = 2 * Double.pi * Double(i) / Double(segments)
                vertices.append(Vec3(x: center.x + radius * sin(phi) * cos(theta),
                                     y: center.y + radius * sin(phi) * sin(theta),
                                     z: center.z + radius * cos(phi)))
            }
        }
        let south = Int32(vertices.count)
        vertices.append(Vec3(x: center.x, y: center.y, z: center.z - radius))
        func v(_ k: Int, _ i: Int) -> Int32 { Int32(1 + (k - 1) * segments + (i % segments)) }
        var indices: [Int32] = []
        for i in 0..<segments { indices += [0, v(1, i), v(1, i + 1)] }
        for k in 1..<(rings - 1) {
            for i in 0..<segments {
                let a = v(k, i), b = v(k, i + 1), c = v(k + 1, i + 1), d = v(k + 1, i)
                indices += [a, d, c, a, c, b]
            }
        }
        for i in 0..<segments { indices += [v(rings - 1, i), south, v(rings - 1, i + 1)] }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private static func sphereVertex(ring k: Int, seg i: Int, segments: Int = 32) -> Int32 {
        Int32(1 + (k - 1) * segments + i)
    }

    /// Adds a one-triangle "fin" on edge (u, v), sticking out from the
    /// surface — a third sheet on that edge (a 3-page "book").
    private static func addingFin(_ g: MeshGeometryData, on u: Int32, _ v: Int32, reach: Double = 1.3) -> MeshGeometryData {
        var out = g
        let p = g.vertices[Int(u)], q = g.vertices[Int(v)]
        let apex = Vec3(x: (p.x + q.x) / 2 * reach, y: (p.y + q.y) / 2 * reach, z: (p.z + q.z) / 2 * reach)
        let w = Int32(out.vertices.count)
        out.vertices.append(apex)
        out.triangleIndices += [u, v, w]
        return out
    }

    /// Vertices where the triangles form more than one separate fan
    /// (a pinch / bow-tie), by index topology.
    private static func pinchVertexCount(_ g: MeshGeometryData) -> Int {
        let idx = g.triangleIndices.map(Int.init)
        let faceCount = idx.count / 3
        var edgeFaces: [[Int]: [Int]] = [:]
        for f in 0..<faceCount {
            let c = [idx[3 * f], idx[3 * f + 1], idx[3 * f + 2]]
            for (u, v) in [(c[0], c[1]), (c[1], c[2]), (c[2], c[0])] { edgeFaces[[min(u, v), max(u, v)], default: []].append(f) }
        }
        var pinches = 0
        var facesOf: [Int: [Int]] = [:]
        for f in 0..<faceCount { for k in 0..<3 { facesOf[idx[3 * f + k], default: []].append(f) } }
        for (v, faces) in facesOf where faces.count > 1 {
            var parent = Dictionary(uniqueKeysWithValues: faces.map { ($0, $0) })
            func find(_ x: Int) -> Int { var r = x; while parent[r]! != r { r = parent[r]! }; return r }
            for f in faces {
                for k in 0..<3 where idx[3 * f + k] != v {
                    let n = idx[3 * f + k]
                    let shared = edgeFaces[[min(v, n), max(v, n)]] ?? []
                    if shared.count == 2 { parent[find(shared[0])] = find(shared[1]) }
                }
            }
            if Set(faces.map(find)).count > 1 { pinches += 1 }
        }
        return pinches
    }

    @Test
    func closedSphereWithThreeSheetBookEdgeHealsToAClosedSolid() throws {
        let sphere = Self.uvSphere()
        let u = Self.sphereVertex(ring: 8, seg: 3), v = Self.sphereVertex(ring: 8, seg: 4)
        let broken = Self.addingFin(sphere, on: u, v)
        let originalCount = broken.triangleIndices.count / 3

        let diagnosis = try #require(OpeningCapper.diagnose(broken))
        #expect(diagnosis.nonManifoldEdges == 1)
        #expect(diagnosis.damagedSpots == 1)
        #expect(diagnosis.canCloseOpenings)
        #expect(diagnosis.openings.isEmpty)
        #expect(diagnosis.sentence.contains("fixed in place"))

        let result = try OpeningCapper.close(broken, topHeight: 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(result.spotsHealed == 1)
        #expect(result.trianglesReplaced == 3)       // the fin + the two sphere faces on its edge
        #expect(result.openingsClosed == 0)          // a healed spot is not an opening
        #expect(Double(originalCount - 3) / Double(originalCount) == result.untouchedFraction)
        #expect(result.receipt.hasPrefix("Healed 1 non-manifold spot (replaced 3 triangles)"))
        #expect(Self.pinchVertexCount(result.geometry) == 0)
        // Every sphere triangle away from the spot is still there, bit-identical
        // (the refill may even re-create the two cut sphere faces).
        let untouchedKeys = Self.triangleCornerKeys(sphere)
        let kept = untouchedKeys.intersection(Self.triangleCornerKeys(result.geometry)).count
        #expect(kept >= untouchedKeys.count - 2)
        #expect(Self.signedVolume(result.geometry) > 0)
    }

    @Test
    func twoSpheresKissingAlongOneEdgeHealIntoTwoSeparateClosedSolids() throws {
        // Sphere B is sphere A mirrored across the plane that touches A along
        // one equator edge (u, v): the two share exactly that edge, so it has
        // four triangles, and u and v become pinches once they're cut away.
        let a = Self.uvSphere()
        let ui = Int(Self.sphereVertex(ring: 8, seg: 0)), vi = Int(Self.sphereVertex(ring: 8, seg: 1))
        let pu = a.vertices[ui], pv = a.vertices[vi]
        var n = (x: pu.x + pv.x, y: pu.y + pv.y, z: pu.z + pv.z)
        let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        n = (n.x / len, n.y / len, n.z / len)
        let d = pu.x * n.x + pu.y * n.y + pu.z * n.z
        var b = a
        for (i, p) in a.vertices.enumerated() {
            let s = 2 * (p.x * n.x + p.y * n.y + p.z * n.z - d)
            b.vertices[i] = Vec3(x: p.x - s * n.x, y: p.y - s * n.y, z: p.z - s * n.z)
        }
        b.vertices[ui] = pu   // exactly shared corners
        b.vertices[vi] = pv
        b = Self.flippedWinding(b)   // a mirror image is inside-out
        let kissing = Self.union(a, b)
        let total = kissing.triangleIndices.count / 3

        let diagnosis = try #require(OpeningCapper.diagnose(kissing))
        #expect(diagnosis.nonManifoldEdges == 1)
        #expect(diagnosis.canCloseOpenings)

        let result = try OpeningCapper.close(kissing, topHeight: 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(Self.pinchVertexCount(result.geometry) == 0)   // the kiss is cut apart, not left pinched
        #expect(result.untouchedFraction >= 0.95)
        #expect(result.trianglesReplaced > 4)
        #expect(result.trianglesReplaced < total / 20)
        let sphereVolume = Self.signedVolume(a)
        #expect(abs(Self.signedVolume(result.geometry) - 2 * sphereVolume) / (2 * sphereVolume) < 0.01)
    }

    @Test
    func loneBowTieOnAClosedSolidIsLeftAlone() {
        // Two closed cubes touching at one corner: a pinch vertex on an
        // otherwise closed, valid solid. Informational — nothing to fix.
        let a = Self.closedCube(side: 10)
        var b = Self.closedCube(side: 10)
        b.vertices = b.vertices.map { Vec3(x: $0.x + 10, y: $0.y + 10, z: $0.z + 10) }
        let touching = Self.union(a, b)

        let diagnosis = OpeningCapper.diagnose(touching)
        #expect(diagnosis?.isNothingToFix == true)
        #expect(diagnosis?.canCloseOpenings == false)
        #expect(diagnosis?.sentence == "Closed solid — nothing to fix.")
        do {
            _ = try OpeningCapper.close(touching, topHeight: 0)
            Issue.record("Expected nothingToClose for a lone bow-tie on a closed solid")
        } catch OpeningCapper.CapError.nothingToClose {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let (unchanged, message) = MeshModifier.makeWatertight(Self.summary(for: touching), method: .closeOpenings, detail: 1, topHeight: 0)
        #expect(unchanged.geometry == touching)
        #expect(message?.hasPrefix("Nothing to fix") == true)
    }

    /// A fine sphere (edges ~2 mm on a 20 mm radius) so a missing triangle is
    /// a pinhole, and the index of one triangle holding `vertex` plus the
    /// incident triangles.
    private static func fineSphereFaces(at vertex: Int32) -> (MeshGeometryData, [Int]) {
        let sphere = uvSphere(radius: 20, segments: 64, rings: 32)
        let idx = sphere.triangleIndices
        let faces = (0..<(idx.count / 3)).filter { idx[3 * $0] == vertex || idx[3 * $0 + 1] == vertex || idx[3 * $0 + 2] == vertex }
        return (sphere, faces)
    }

    private static func removingFaces(_ g: MeshGeometryData, _ drop: Set<Int>) -> MeshGeometryData {
        var out = g
        out.triangleIndices = []
        let idx = g.triangleIndices
        for f in 0..<(idx.count / 3) where !drop.contains(f) { out.triangleIndices += idx[(3 * f)..<(3 * f + 3)] }
        return out
    }

    @Test
    func twoPinholesMeetingAtOneCornerAreFilledWithoutCuttingAnything() throws {
        // Two triangles sharing only one corner go missing: a figure-eight
        // hole pinched at that corner. The loop is split there, and the two
        // caps knit the corner's fans back into one disk — nothing is cut.
        let pinch = Self.sphereVertex(ring: 16, seg: 5, segments: 64)
        let (sphere, faces) = Self.fineSphereFaces(at: pinch)
        let idx = sphere.triangleIndices
        let first = faces[0]
        let firstCorners = Set(idx[(3 * first)..<(3 * first + 3)])
        let opposite = try #require(faces.first { f in
            f != first && Set(idx[(3 * f)..<(3 * f + 3)]).intersection(firstCorners) == [pinch]
        })
        let holed = Self.removingFaces(sphere, [first, opposite])
        #expect(Self.pinchVertexCount(holed) == 1)

        let diagnosis = try #require(OpeningCapper.diagnose(holed))
        #expect(diagnosis.canCloseOpenings)
        #expect(diagnosis.openings.isEmpty)
        #expect(diagnosis.pinholes == 2)

        let result = try OpeningCapper.close(holed, topHeight: 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(Self.pinchVertexCount(result.geometry) == 0)
        #expect(result.trianglesReplaced == 0)
        #expect(result.pinholesFilled == 2)
        #expect(result.untouchedFraction == 1.0)
        #expect(Self.triangleCornerKeys(result.geometry) == Self.triangleCornerKeys(sphere))
    }

    @Test
    func pinholeCornerTouchingASmallClosedBodyIsCutFromTheSurfaceNotTheBody() throws {
        // A pinhole whose corner is also a corner of a small closed
        // tetrahedron sitting outside the sphere: capping alone would leave a
        // pinch (the tetra's fan is closed). The open sphere fan is cut back
        // instead and refilled; the tetrahedron — a real body — is untouched.
        let pinch = Self.sphereVertex(ring: 16, seg: 5, segments: 64)
        let (sphere, faces) = Self.fineSphereFaces(at: pinch)
        let holed = Self.removingFaces(sphere, [faces[0]])
        let p = sphere.vertices[Int(pinch)]
        let len = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        let out = Vec3(x: p.x / len, y: p.y / len, z: p.z / len)
        // Tetra with one corner exactly at the pinch, the rest pointing outward.
        var tetra = Self.closedTetrahedron(scale: 1, offset: Vec3(x: 0, y: 0, z: 0))
        tetra.vertices = [
            p,
            Vec3(x: p.x + out.x + 0.5, y: p.y + out.y, z: p.z + out.z),
            Vec3(x: p.x + out.x, y: p.y + out.y + 0.5, z: p.z + out.z),
            Vec3(x: p.x + 1.5 * out.x, y: p.y + 1.5 * out.y, z: p.z + 1.5 * out.z + 0.5)
        ]
        if Self.signedVolume(tetra) < 0 { tetra = Self.flippedWinding(tetra) }
        var combined = Self.union(holed, tetra)
        // Share the corner by index too (not just by position).
        let tetraCorner = Int32(holed.vertices.count)
        combined.triangleIndices = combined.triangleIndices.map { $0 == tetraCorner ? pinch : $0 }
        #expect(Self.pinchVertexCount(combined) == 1)

        let diagnosis = try #require(OpeningCapper.diagnose(combined))
        #expect(diagnosis.canCloseOpenings)
        #expect(diagnosis.openings.isEmpty)

        let result = try OpeningCapper.close(combined, topHeight: 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(Self.pinchVertexCount(result.geometry) == 0)
        #expect(Self.triangleCornerKeys(tetra).isSubset(of: Self.triangleCornerKeys(result.geometry)))
        #expect(result.trianglesReplaced > 0)
        #expect(result.untouchedFraction >= 0.99)
    }

    @Test
    func smallFlippedPatchIsTurnedBackWithoutCuttingAnything() throws {
        // Two adjacent sphere triangles wound the wrong way round.
        let sphere = Self.uvSphere()
        var flipped = sphere
        let quad = 32 + (6 * 32 + 10) * 2   // after the 32-triangle north cap: band 7, segment 10
        for f in [quad, quad + 1] { flipped.triangleIndices.swapAt(3 * f + 1, 3 * f + 2) }
        let total = sphere.triangleIndices.count / 3

        let diagnosis = try #require(OpeningCapper.diagnose(flipped))
        #expect(diagnosis.orientationConflicts > 0)
        #expect(diagnosis.flippedTriangles == 2)
        #expect(diagnosis.damagedSpots == 0)
        #expect(diagnosis.canCloseOpenings)

        let result = try OpeningCapper.close(flipped, topHeight: 0)
        #expect(result.trianglesFlipped == 2)
        #expect(result.trianglesReplaced == 0)
        #expect(result.untouchedFraction == Double(total - 2) / Double(total))
        #expect(Self.triangleCornerKeys(result.geometry) == Self.triangleCornerKeys(sphere))
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(abs(Self.signedVolume(result.geometry) - Self.signedVolume(sphere)) < 1.0e-9)
    }

    @Test
    func widespreadDamageIsNotFixedInPlace() {
        // Fins on 60 separate equator-band edges: ~18% of the surface would
        // have to be cut out — that is a rebuild, not a local fix.
        var broken = Self.uvSphere()
        for k in stride(from: 3, to: 14, by: 2) {
            for i in stride(from: 0, to: 30, by: 3) {
                broken = Self.addingFin(broken, on: Self.sphereVertex(ring: k, seg: i), Self.sphereVertex(ring: k, seg: i + 1))
            }
        }
        let diagnosis = OpeningCapper.diagnose(broken)
        #expect(diagnosis?.canCloseOpenings == false)
        #expect(diagnosis?.blockingReason?.contains("Rebuild as solid") == true)
        #expect(diagnosis?.sentence.contains("Rebuild as solid") == true)
        do {
            _ = try OpeningCapper.close(broken, topHeight: 0)
            Issue.record("Expected needsRebuild for widespread damage")
        } catch OpeningCapper.CapError.needsRebuild(let why) {
            #expect(why.contains("%"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Weld only where a seam needs it

    @Test
    func nearlyTouchingInteriorVerticesAreNotWelded() throws {
        // A closed ball whose surface nearly touches an interior wall vertex
        // of the cup (1 µm away): both vertices are already fully connected,
        // so welding them would only move corners and pinch the surfaces.
        let cup = Self.openCup()
        let wallPoint = cup.vertices[Int(Self.wallVertex(ring: 2, seg: 0))]   // (20, 0, 12)
        let ball = Self.uvSphere(radius: 3, segments: 16, rings: 8,
                                 center: Vec3(x: wallPoint.x + 3 + 1.0e-6, y: 0, z: wallPoint.z))
        // Ring 4 segment 8 of the ball is its -x equator point, facing the wall.
        let combined = Self.union(cup, ball)

        let result = try OpeningCapper.close(combined, topHeight: 0)
        #expect(result.untouchedFraction == 1.0)
        #expect(Self.triangleCornerKeys(ball).isSubset(of: Self.triangleCornerKeys(result.geometry)))
        #expect(Self.pinchVertexCount(result.geometry) == 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
    }

    @Test
    func nearDuplicateSeamOnOpenEdgesIsWeldedShut() throws {
        // Cut the cup wall along segment 0 and give one side its own copies
        // of the seam vertices, 0.1 µm away: an unwelded seam (a crack).
        var cup = Self.openCup()
        let segments = 48, rings = 6
        var copy: [Int32: Int32] = [:]
        for k in 0..<rings {
            let original = Self.wallVertex(ring: k, seg: 0)
            let p = cup.vertices[Int(original)]
            copy[original] = Int32(cup.vertices.count)
            cup.vertices.append(Vec3(x: p.x + 1.0e-7, y: p.y, z: p.z))
        }
        // Wall quads of column 0 (segment 0 -> 1) use the copies.
        for k in 0..<(rings - 1) {
            let base = (k * segments + 0) * 6
            for j in base..<(base + 6) {
                if let c = copy[cup.triangleIndices[j]] { cup.triangleIndices[j] = c }
            }
        }
        let diagnosis = try #require(OpeningCapper.diagnose(cup))
        #expect(diagnosis.openings.count == 1)
        #expect(diagnosis.pinholes == 0)

        let result = try OpeningCapper.close(cup, topHeight: 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(result.openingsClosed == 1)
    }

    // MARK: - Seam stitching (cracks between surface pieces)

    /// A tube wall (open at both ends, 48 segments) plus a SEPARATE flat
    /// bottom disk with its own `diskSegments` rim corners on the same
    /// circle, rotated so no corner coincides with a wall corner: the disk
    /// meets the wall only in T-junctions (each corner lies on the other
    /// piece's rim edge, within the chord sag — under 2% of the edge), like
    /// a CAD cap sheet on a lofted wall. `diskWoundUp` winds the disk +z,
    /// the same way round as the wall's rim (a flipped patch).
    private static func wallWithSeparateDisk(diskSegments: Int = 30, diskWoundUp: Bool) -> MeshGeometryData {
        var g = openCup(capRings: nil)
        let center = Int32(g.vertices.count)
        g.vertices.append(Vec3(x: 0, y: 0, z: 0))
        let first = Int32(g.vertices.count)
        for j in 0..<diskSegments {
            let theta = 2.0 * Double.pi * (Double(j) + 0.37) / Double(diskSegments)
            g.vertices.append(Vec3(x: 20 * cos(theta), y: 20 * sin(theta), z: 0))
        }
        for j in 0..<diskSegments {
            let a = first + Int32(j), b = first + Int32((j + 1) % diskSegments)
            g.triangleIndices += diskWoundUp ? [center, a, b] : [center, b, a]
        }
        return g
    }

    @Test
    func twoPatchSurfaceWithTJunctionSeamAndFlippedPatchIsStitchedAndClosed() throws {
        let surface = Self.wallWithSeparateDisk(diskWoundUp: true)
        // Wall triangles away from the seam (rings 1...5) must survive
        // bit-identical.
        let farFromSeam = MeshGeometryData(
            vertices: surface.vertices,
            triangleIndices: Array(surface.triangleIndices[(48 * 6)..<(48 * 6 * 5)]))

        let diagnosis = try #require(OpeningCapper.diagnose(surface))
        #expect(diagnosis.seams == 1)
        #expect(diagnosis.piecesReversed == 1)
        #expect(diagnosis.openings.count == 1)   // only the real top opening
        #expect(diagnosis.pinholes == 0)
        #expect(diagnosis.sentence.contains("1 open seam"))
        #expect(diagnosis.canCloseOpenings)

        let result = try OpeningCapper.close(surface, topHeight: 0)
        #expect(result.seamsStitched == 1)
        #expect(result.piecesReversed == 1)
        #expect(result.openingsClosed == 1)
        #expect(result.pinholesFilled == 0)
        #expect(result.receipt.contains("Stitched 1 seam"))
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.degenerateTriangleCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(Self.triangleCornerKeys(farFromSeam).isSubset(of: Self.triangleCornerKeys(result.geometry)))
        // The disk became the bottom (no new area at the seam): the volume is
        // the cylinder's, positive.
        let volume = Self.signedVolume(result.geometry)
        let expected = Double.pi * 20 * 20 * 30
        #expect(volume > 0)
        #expect(abs(volume - expected) / expected < 0.05)
    }

    @Test
    func twoPatchSeamWithMatchingWindingNeedsNoPieceTurned() throws {
        let surface = Self.wallWithSeparateDisk(diskWoundUp: false)
        let result = try OpeningCapper.close(surface, topHeight: 0)
        #expect(result.seamsStitched == 1)
        #expect(result.piecesReversed == 0)
        #expect(result.flippedInsideOut == false)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
        #expect(Self.signedVolume(result.geometry) > 0)
    }

    @Test
    func zeroWidthSlitInsideOneSheetIsZippedNotCapped() throws {
        // A closed-bottom cup whose wall is cut open along segment 0 into a
        // zero-width slit: the far side of the cut gets its own column of
        // corners at DIFFERENT heights (0, 7.5, 15, 22.5, 30 vs the wall's
        // 0, 6, ..., 30) — every corner lies on the opposite side's edge
        // (T-junctions), and the two columns meet only at the ends. The slit
        // must be zipped (no cap, no new area), the top opening capped.
        var cup = Self.openCup()
        let segments = 48, rings = 6
        let zs = [0.0, 7.5, 15.0, 22.5, 30.0]
        var column: [Int32] = []
        for z in zs {
            column.append(Int32(cup.vertices.count))
            cup.vertices.append(Vec3(x: 20, y: 0, z: z))
        }
        // Drop the wall strip between segment 47 and segment 0 ...
        var kept: [Int32] = []
        var t = 0
        while t + 2 < cup.triangleIndices.count {
            let tri = Array(cup.triangleIndices[t..<(t + 3)])
            let segs = Set(tri.compactMap { $0 < Int32(segments * rings) ? Int($0) % segments : nil })
            let inWall = tri.allSatisfy { $0 < Int32(segments * rings) }
            if !(inWall && segs == [47, 0]) { kept += tri }
            t += 3
        }
        cup.triangleIndices = kept
        // ... and rebuild it against the new column (same winding as a wall
        // quad: left = segment 47, right = the new column at theta = 2π).
        let left = (0..<rings).map { Self.wallVertex(ring: $0, seg: 47) }
        let leftZ = (0..<rings).map { 30.0 * Double($0) / Double(rings - 1) }
        var i = 0, j = 0
        while i < rings - 1 || j < zs.count - 1 {
            let advanceRight = i == rings - 1 || (j < zs.count - 1 && zs[j + 1] <= leftZ[i + 1])
            if advanceRight {
                cup.triangleIndices += [left[i], column[j], column[j + 1]]
                j += 1
            } else {
                cup.triangleIndices += [left[i], column[j], left[i + 1]]
                i += 1
            }
        }
        // The column's end corners sit exactly on the wall's segment-0
        // corners at z = 0 and z = 30; the bottom one is shared with the
        // disk, so reuse it (the top one stays a separate corner on the rim).
        cup.triangleIndices = cup.triangleIndices.map { $0 == column[0] ? Self.wallVertex(ring: 0, seg: 0) : $0 }

        let before = OpeningCapper.topologyReport(cup)
        #expect(before.boundaryEdgeCount > 48)   // the rim plus the slit

        let diagnosis = try #require(OpeningCapper.diagnose(cup))
        #expect(diagnosis.seams == 1)
        #expect(diagnosis.openings.count == 1)
        #expect(diagnosis.pinholes == 0)

        let result = try OpeningCapper.close(cup, topHeight: 0)
        #expect(result.seamsStitched == 1)
        #expect(result.openingsClosed == 1)
        #expect(result.pinholesFilled == 0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.degenerateTriangleCount == 0)
        #expect(report.manifoldValidated == true)
        let volume = Self.signedVolume(result.geometry)
        let expected = Double.pi * 20 * 20 * 30
        #expect(abs(volume - expected) / expected < 0.05)
    }

    @Test
    func openingsThatAreMerelyCloseAreNotStitched() throws {
        // Two tubes side by side, walls 0.5 mm apart (a fifth of an edge):
        // four real openings, no seam.
        let a = Self.openCup(capRings: nil)
        var b = Self.openCup(capRings: nil)
        b.vertices = b.vertices.map { Vec3(x: $0.x + 40.5, y: $0.y, z: $0.z) }
        let both = Self.union(a, b)

        let diagnosis = try #require(OpeningCapper.diagnose(both))
        #expect(diagnosis.seams == 0)
        #expect(diagnosis.openings.count == 4)
        let result = try OpeningCapper.close(both, topHeight: 0)
        #expect(result.seamsStitched == 0)
        #expect(result.openingsClosed == 4)
        #expect(result.untouchedFraction == 1.0)
    }

    @Test
    func makeWatertightCloseOpeningsStitchesSeamsThroughMeshModifier() throws {
        let surface = Self.wallWithSeparateDisk(diskWoundUp: true)
        let (closed, result) = try MeshModifier.closeOpenings(Self.summary(for: surface), topHeight: 0)
        #expect(result.remainingOpenEdges == 0)
        #expect(result.remainingNonManifoldEdges == 0)
        #expect(result.seamsStitched == 1)
        #expect(closed.preflight.manifoldValidated == true)
        #expect(!result.receipt.contains("Not fully closed"))
    }

    // MARK: - Level-set caps (crossing-free)

    /// A cup (closed bottom) topped by `leaves` leaves that overlap in plan
    /// view like a pineapple crown: even leaves lean in steeply and twist one
    /// way, odd leaves lean in gently and twist the other way, so each odd
    /// leaf passes OVER its even neighbours. The rim crosses itself seen from
    /// above, while the skin never touches itself (wherever two leaves cover
    /// the same spot seen from above, the gentler odd leaf is higher).
    private static func crownCup(leaves: Int = 8, twist: Double = 0.56) -> MeshGeometryData {
        let radius = 20.0, height = 20.0, leafHeight = 12.0
        let steep = 6.0, gentle = 2.0
        let across = 8, up = 10, bodyRings = 6
        let delta = 2 * Double.pi / Double(leaves)
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        func add(_ x: Double, _ y: Double, _ z: Double) -> Int32 {
            vertices.append(Vec3(x: x, y: y, z: z))
            return Int32(vertices.count - 1)
        }
        let segments = leaves * across
        func angle(_ i: Int) -> Double { -delta / 2 + Double(i) * delta / Double(across) }
        var body: [[Int32]] = []
        for m in 0...bodyRings {
            let z = height * Double(m) / Double(bodyRings)
            body.append((0..<segments).map { add(radius * cos(angle($0)), radius * sin(angle($0)), z) })
        }
        for m in 0..<bodyRings {
            for i in 0..<segments {
                let j = (i + 1) % segments
                indices += [body[m][i], body[m][j], body[m + 1][j], body[m][i], body[m + 1][j], body[m + 1][i]]
            }
        }
        let center = add(0, 0, 0)
        for i in 0..<segments { indices += [body[0][i], center, body[0][(i + 1) % segments]] }
        let ring = body[bodyRings]
        for k in 0..<leaves {
            let even = k % 2 == 0
            let lean = even ? steep : gentle
            let turn = even ? twist : -twist
            var grid = [[Int32]](repeating: [], count: up + 1)
            for fi in 0...up {
                let f = Double(fi) / Double(up)
                let halfWidth = delta / 2 * (1 - 0.9 * f)
                for ui in 0...across {
                    if fi == 0 { grid[fi].append(ring[(k * across + ui) % segments]); continue }
                    let u = -1 + 2 * Double(ui) / Double(across)
                    let theta = Double(k) * delta + turn * f * f + u * halfWidth
                    let r = radius - lean * f * f
                    grid[fi].append(add(r * cos(theta), r * sin(theta), height + leafHeight * f))
                }
            }
            for fi in 0..<up {
                for ui in 0..<across {
                    let a = grid[fi][ui], b = grid[fi][ui + 1], c = grid[fi + 1][ui + 1], d = grid[fi + 1][ui]
                    indices += [a, b, c, a, c, d]
                }
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// Open edges of `g` as vertex pairs.
    private static func openEdges(_ g: MeshGeometryData) -> [(Int, Int)] {
        var uses: [SIMD2<Int>: Int] = [:]
        var t = 0
        let idx = g.triangleIndices
        while t + 2 < idx.count {
            for (u, v) in [(idx[t], idx[t + 1]), (idx[t + 1], idx[t + 2]), (idx[t + 2], idx[t])] {
                uses[SIMD2(Int(min(u, v)), Int(max(u, v))), default: 0] += 1
            }
            t += 3
        }
        return uses.filter { $0.value == 1 }.map { ($0.key.x, $0.key.y) }
    }

    /// Times the rim crosses itself seen from above (plan view, xy).
    private static func planViewSelfCrossings(_ g: MeshGeometryData) -> Int {
        let edges = openEdges(g)
        func side(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double { (c.x - a.x) * (b.y - a.y) - (b.x - a.x) * (c.y - a.y) }
        var crossings = 0
        for i in edges.indices {
            for j in (i + 1)..<edges.count {
                let (a, b) = edges[i], (c, d) = edges[j]
                if a == c || a == d || b == c || b == d { continue }
                let p1 = g.vertices[a], p2 = g.vertices[b], p3 = g.vertices[c], p4 = g.vertices[d]
                if side(p3, p4, p1) * side(p3, p4, p2) < 0 && side(p1, p2, p3) * side(p1, p2, p4) < 0 { crossings += 1 }
            }
        }
        return crossings
    }

    /// Independent check (not the capper's own): cap triangles (from
    /// `keptTriangleCount` on) that cross a kept triangle they don't share a
    /// corner with — an edge of one passing through the other's interior.
    private static func capCrossings(_ result: OpeningCapper.Result) -> Int {
        let g = result.geometry
        let p = g.vertices.map { SIMD3<Double>($0.x, $0.y, $0.z) }
        let idx = g.triangleIndices.map { Int($0) }
        let count = idx.count / 3
        func tri(_ t: Int) -> (Int, Int, Int) { (idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]) }
        func box(_ t: Int) -> (SIMD3<Double>, SIMD3<Double>) {
            let (a, b, c) = tri(t)
            return (pointwiseMin(pointwiseMin(p[a], p[b]), p[c]), pointwiseMax(pointwiseMax(p[a], p[b]), p[c]))
        }
        func pierces(_ s: SIMD3<Double>, _ e: SIMD3<Double>, _ v0: SIMD3<Double>, _ v1: SIMD3<Double>, _ v2: SIMD3<Double>) -> Bool {
            let dir = e - s, e1 = v1 - v0, e2 = v2 - v0
            let h = simd_cross(dir, e2), det = simd_dot(e1, h)
            if abs(det) <= 1.0e-12 * simd_length(e1) * simd_length(e2) * simd_length(dir) { return false }
            let q = s - v0, u = simd_dot(q, h) / det
            if u <= 1.0e-9 || u >= 1 - 1.0e-9 { return false }
            let qv = simd_cross(q, e1), v = simd_dot(dir, qv) / det
            if v <= 1.0e-9 || u + v >= 1 - 1.0e-9 { return false }
            let t = simd_dot(e2, qv) / det
            return t > 1.0e-9 && t < 1 - 1.0e-9
        }
        let kept = result.keptTriangleCount
        let keptBoxes = (0..<kept).map(box)
        var crossing = 0
        for c in kept..<count {
            let (a, b, d) = tri(c)
            let (lo, hi) = box(c)
            for s in 0..<kept {
                let (slo, shi) = keptBoxes[s]
                if any(slo .> hi) || any(lo .> shi) { continue }
                let (x, y, z) = tri(s)
                if Set([a, b, d]).isDisjoint(with: [x, y, z]) == false { continue }
                let capEdges = [(p[a], p[b]), (p[b], p[d]), (p[d], p[a])]
                let skinEdges = [(p[x], p[y]), (p[y], p[z]), (p[z], p[x])]
                if capEdges.contains(where: { pierces($0.0, $0.1, p[x], p[y], p[z]) })
                    || skinEdges.contains(where: { pierces($0.0, $0.1, p[a], p[b], p[d]) }) {
                    crossing += 1
                    break
                }
            }
        }
        return crossing
    }

    @Test
    func crownRimThatOverlapsItselfInPlanViewGetsACapThatNeverCrossesTheLeaves() throws {
        let crown = Self.crownCup()
        // The fixture is what it claims: the rim crosses itself seen from
        // above (leaves overlap), and the skin is one clean open surface.
        #expect(Self.planViewSelfCrossings(crown) >= 4)
        let preflight = OpeningCapper.importedTopologyReport(crown)
        #expect(preflight.nonManifoldEdgeCount == 0)

        let result = try OpeningCapper.close(crown, topHeight: 0)
        #expect(result.openingsClosed == 1)
        #expect(result.capIntersections == 0)
        #expect(Self.capCrossings(result) == 0)
        #expect(result.untouchedFraction == 1.0)
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(report.manifoldValidated == true)
    }

    @Test
    func planarRimGetsAFlatCapThatDomesAndDishesWithoutCrossing() throws {
        // The open cup's rim is the circle z = 30: the level set w = 0.5 of
        // the skin is exactly the flat disk there.
        let flat = try OpeningCapper.close(Self.openCup(), topHeight: 0)
        let g = flat.geometry
        var deviation = 0.0
        var capCorners = 0
        var usedByKept = Set<Int32>()
        for i in 0..<(3 * flat.keptTriangleCount) { usedByKept.insert(g.triangleIndices[i]) }
        for i in (3 * flat.keptTriangleCount)..<g.triangleIndices.count where !usedByKept.contains(g.triangleIndices[i]) {
            deviation = max(deviation, abs(g.vertices[Int(g.triangleIndices[i])].z - 30))
            capCorners += 1
        }
        #expect(capCorners > 0)
        #expect(deviation < 0.01)
        #expect(Self.capCrossings(flat) == 0)

        // Dome / dish: the peak moves the requested height off the flat cap.
        for height in [8.0, -8.0] {
            let shaped = try OpeningCapper.close(Self.openCup(), topHeight: height)
            #expect(abs(shaped.appliedTopHeight - height) < 0.05)
            #expect(shaped.capIntersections == 0)
            #expect(Self.capCrossings(shaped) == 0)
            // Cap corners only (the cup's own floor sits at z = 0).
            let sg = shaped.geometry
            var kept = Set<Int32>()
            for i in 0..<(3 * shaped.keptTriangleCount) { kept.insert(sg.triangleIndices[i]) }
            let capZ = sg.triangleIndices[(3 * shaped.keptTriangleCount)...]
                .filter { !kept.contains($0) }.map { sg.vertices[Int($0)].z - 30 }
            if height > 0 { #expect(abs((capZ.max() ?? 0) - height) < 0.05) }
            else { #expect(abs((capZ.min() ?? 0) - height) < 0.05) }
        }
    }
}

// MARK: - Problem sites (viewport issue markers)

/// `Diagnosis.sites`: one entry per problem spot, located where the passes
/// found it, in the coordinates of the geometry passed to `diagnose`.
extension OpeningCapperTests {
    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }

    private static func centroid(_ g: MeshGeometryData, _ ids: [Int32]) -> Vec3 {
        var c = Vec3(x: 0, y: 0, z: 0)
        for i in ids { let p = g.vertices[Int(i)]; c = Vec3(x: c.x + p.x, y: c.y + p.y, z: c.z + p.z) }
        let n = Double(ids.count)
        return Vec3(x: c.x / n, y: c.y / n, z: c.z / n)
    }

    @Test
    func sitesLocateTheOpeningPinholeDoubledFlapAndLooseFragment() throws {
        let fineCup = Self.openCup(capRings: 12)
        var cup = Self.removingTriangle(fineCup, containing: Int32(fineCup.vertices.count - 1))
        let a = Self.wallVertex(ring: 1, seg: 0), b = Self.wallVertex(ring: 1, seg: 1), c = Self.wallVertex(ring: 2, seg: 1)
        cup.triangleIndices += [a, b, c, a, c, b]
        let stray = Int32(cup.vertices.count)
        cup.vertices += [Vec3(x: 200, y: 0, z: 0), Vec3(x: 200.3, y: 0, z: 0), Vec3(x: 200, y: 0.3, z: 0)]
        cup.triangleIndices += [stray, stray + 1, stray + 2]

        let diagnosis = try #require(OpeningCapper.diagnose(cup))
        let sites = diagnosis.sites
        #expect(sites.map(\.kind) == [.opening, .pinhole, .doubledTriangles, .looseFragment])
        #expect(sites.map(\.id) == ["opening-1", "pinhole-1", "doubledTriangles-1", "looseFragment-1"])
        #expect(diagnosis.sitesOmitted == 0)
        #expect(sites.count == diagnosis.openings.count + diagnosis.pinholes + 1 + diagnosis.looseFragments)

        // The opening: the rim at z = 30, 40 mm across.
        let opening = sites[0]
        #expect(Self.distance(opening.position, Vec3(x: 0, y: 0, z: 30)) < 1.0e-9)
        #expect(abs(opening.sizeMM - 40) < 1.0e-9)
        #expect(opening.elementCount == 48)
        #expect(opening.title == "Opening 1 — 40 mm, top")
        #expect(opening.fixDescription.contains("Make Watertight"))
        // The pinhole: at the bottom's centre, small.
        let pinhole = sites[1]
        #expect(Self.distance(pinhole.position, Vec3(x: 0, y: 0, z: 0)) < 2)
        #expect(pinhole.sizeMM < 4)
        #expect(pinhole.fixDescription.contains("Fix in place"))
        // The doubled flap: on its three corners; count = triangles removed.
        let doubled = sites[2]
        #expect(Self.distance(doubled.position, Self.centroid(cup, [a, b, c])) < 1.0e-9)
        #expect(doubled.elementCount == diagnosis.doubledTrianglesRemoved)
        // The loose fragment: where it was, one triangle.
        let loose = sites[3]
        #expect(Self.distance(loose.position, Vec3(x: 200.1, y: 0.1, z: 0)) < 1.0e-9)
        #expect(loose.elementCount == 1)
        #expect(sites.allSatisfy { $0.fixableInPlace })
    }

    @Test
    func sitesAreStableAcrossDiagnoses() throws {
        let fineCup = Self.openCup(capRings: 12)
        let cup = Self.removingTriangle(fineCup, containing: Int32(fineCup.vertices.count - 1))
        let first = try #require(OpeningCapper.diagnose(cup)).sites
        let second = try #require(OpeningCapper.diagnose(cup)).sites
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test
    func nonManifoldFinIsOneNonManifoldSpotSite() throws {
        let sphere = Self.uvSphere()
        let u = Self.sphereVertex(ring: 8, seg: 3), v = Self.sphereVertex(ring: 8, seg: 4)
        let broken = Self.addingFin(sphere, on: u, v)
        let diagnosis = try #require(OpeningCapper.diagnose(broken))
        #expect(diagnosis.sites.count == 1)
        let site = try #require(diagnosis.sites.first)
        #expect(site.kind == .nonManifoldSpot)
        #expect(site.title == "Non-manifold spot")
        #expect(site.elementCount == diagnosis.trianglesToReplace)
        #expect(site.fixableInPlace)
        // Centred on the damaged edge (within the cut triangles' extent).
        let edgeMid = Self.centroid(broken, [u, v])
        #expect(Self.distance(site.position, edgeMid) < site.sizeMM)
        #expect(site.sizeMM > 0 && site.sizeMM < 12)
    }

    @Test
    func flippedPatchIsOneFlippedSiteOnThoseTriangles() throws {
        let sphere = Self.uvSphere()
        var flipped = sphere
        let quad = 32 + (6 * 32 + 10) * 2
        for f in [quad, quad + 1] { flipped.triangleIndices.swapAt(3 * f + 1, 3 * f + 2) }
        let diagnosis = try #require(OpeningCapper.diagnose(flipped))
        #expect(diagnosis.sites.map(\.kind) == [.flippedPiece])
        let site = try #require(diagnosis.sites.first)
        #expect(site.elementCount == 2)
        let corners = Array(Set((0..<6).map { flipped.triangleIndices[3 * quad + $0] })).sorted()
        #expect(Self.distance(site.position, Self.centroid(flipped, corners)) < 1.0e-9)
        #expect(site.title == "2 flipped triangles")
    }

    @Test
    func stitchedSeamAndReversedPieceAreSites() throws {
        let surface = Self.wallWithSeparateDisk(diskWoundUp: true)
        let diagnosis = try #require(OpeningCapper.diagnose(surface))
        #expect(diagnosis.sites.map(\.kind) == [.opening, .seam, .flippedPiece])
        let seam = try #require(diagnosis.sites.first { $0.kind == .seam })
        // The crack runs round the whole bottom rim: centred on the axis at
        // z = 0, the rim's diameter across.
        #expect(Self.distance(seam.position, Vec3(x: 0, y: 0, z: 0)) < 0.5)
        #expect(abs(seam.sizeMM - 40) < 0.5)
        let piece = try #require(diagnosis.sites.first { $0.kind == .flippedPiece })
        #expect(piece.title.hasPrefix("Inside-out surface piece"))
    }

    @Test
    func closedSolidHasNoSites() throws {
        let diagnosis = try #require(OpeningCapper.diagnose(Self.closedCube()))
        #expect(diagnosis.sites.isEmpty)
        #expect(diagnosis.sitesOmitted == 0)
    }

    @Test
    func widespreadDamageSitesSayRebuild() throws {
        var broken = Self.uvSphere()
        for k in stride(from: 3, to: 14, by: 2) {
            for i in stride(from: 0, to: 30, by: 3) {
                broken = Self.addingFin(broken, on: Self.sphereVertex(ring: k, seg: i), Self.sphereVertex(ring: k, seg: i + 1))
            }
        }
        let diagnosis = try #require(OpeningCapper.diagnose(broken))
        #expect(diagnosis.canCloseOpenings == false)
        let spots = diagnosis.sites.filter { $0.kind == .nonManifoldSpot }
        #expect(!spots.isEmpty)
        #expect(diagnosis.sites.allSatisfy { !$0.fixableInPlace && $0.fixDescription.contains("Rebuild as solid") })
    }

    @Test
    func manyHolesAreCappedPerKindAndCountedAsOmitted() throws {
        // Single missing triangles in every other band, every third segment:
        // none share a corner, so each is its own hole.
        var drop = Set<Int>()
        for band in stride(from: 1, to: 14, by: 2) {
            for seg in stride(from: 0, to: 30, by: 3) {
                drop.insert(32 + (band * 32 + seg) * 2)
            }
        }
        let holed = Self.removingFaces(Self.uvSphere(), drop)
        let diagnosis = try #require(OpeningCapper.diagnose(holed))
        let holes = diagnosis.openings.count + diagnosis.pinholes
        #expect(holes == drop.count)
        let listed = diagnosis.sites.filter { $0.kind == .opening || $0.kind == .pinhole }
        #expect(listed.count + diagnosis.sitesOmitted == holes)
        for kind in OpeningCapper.Site.Kind.allCases {
            #expect(diagnosis.sites.filter { $0.kind == kind }.count <= OpeningCapper.maxSitesPerKind)
        }
        #expect(diagnosis.sitesOmitted > 0)
        #expect(Set(diagnosis.sites.map(\.id)).count == diagnosis.sites.count)
    }

    // MARK: - Per-opening choices

    /// Openings carry an outward normal and a plain placement (+Z up); the
    /// tube's openings are ordered bottom (z = 0) then top (z = 30) — equal
    /// size, ties broken by centre.
    @Test
    func openingsCarryOutwardNormalsAndPlacement() throws {
        let tube = Self.openCup(capRings: nil)
        let diagnosis = try #require(OpeningCapper.diagnose(tube))
        #expect(diagnosis.openings.count == 2)
        let bottom = diagnosis.openings[0], top = diagnosis.openings[1]
        #expect(abs(bottom.center.z) < 1.0e-9 && abs(top.center.z - 30) < 1.0e-9)
        #expect(abs(bottom.normal.z + 1) < 1.0e-9)
        #expect(abs(top.normal.z - 1) < 1.0e-9)
        #expect(bottom.label(number: 1) == "Opening 1 — 40 mm, bottom")
        #expect(top.label(number: 2) == "Opening 2 — 40 mm, top")
        // The same order and numbers as the viewport's opening markers.
        #expect(diagnosis.sites.filter { $0.kind == .opening }.map(\.title)
                == ["Opening 1 — 40 mm, bottom", "Opening 2 — 40 mm, top"])
        // Inside-out input: the normals still point out of the solid.
        let flipped = try #require(OpeningCapper.diagnose(Self.flippedWinding(tube)))
        for opening in flipped.openings {
            #expect(abs(opening.normal.z - (opening.center.z > 15 ? 1 : -1)) < 1.0e-9)
        }
    }

    /// Choices find their opening by signature, not by array position: after
    /// the mesh is rebuilt with its triangles and vertices in a different
    /// order, and nudged by 0.3 mm, a choice saved for the top still lands on
    /// the top. A choice for an opening that isn't there matches nothing.
    @Test
    func choicesMatchOpeningsBySignatureNotIndex() throws {
        let tube = Self.openCup(capRings: nil)
        let before = try #require(OpeningCapper.diagnose(tube))
        let topChoice = OpeningCapper.OpeningChoice(signature: before.openings[1].signature, leaveOpen: true)
        let elsewhere = OpeningCapper.OpeningChoice(
            signature: OpeningCapper.OpeningSignature(center: Vec3(x: 0, y: 0, z: 80), diameter: 40, normal: Vec3(x: 0, y: 0, z: 1)),
            leaveOpen: true)

        // Reverse the vertex array and the triangle order, shift by 0.3 mm.
        let n = tube.vertices.count
        let moved = tube.vertices.reversed().map { Vec3(x: $0.x + 0.3, y: $0.y, z: $0.z) }
        var tris: [Int32] = []
        var t = tube.triangleIndices.count - 3
        while t >= 0 {
            for c in 0..<3 { tris.append(Int32(n - 1) - tube.triangleIndices[t + c]) }
            t -= 3
        }
        let shuffled = MeshGeometryData(vertices: Array(moved), triangleIndices: tris)
        let after = try #require(OpeningCapper.diagnose(shuffled))

        let (byOpening, unmatched) = OpeningCapper.matchChoices([elsewhere, topChoice], to: after.openings)
        #expect(byOpening.count == 2)
        // (Which index the top has after the rebuild is down to rounding in
        // two equal diameters — exactly why index can't be the identity.)
        let topIndex = try #require(after.openings.firstIndex { $0.center.z > 15 })
        #expect(byOpening[topIndex] == topChoice)
        #expect(byOpening[1 - topIndex] == nil)
        #expect(unmatched == [elsewhere])

        // One to one: two choices for the same opening — only the closer wins.
        var near = topChoice
        near.signature.center.z += 0.1
        near.leaveOpen = false
        near.topHeight = 3
        let pair = OpeningCapper.matchChoices([near, topChoice], to: before.openings)
        #expect(pair.byOpening[1] == topChoice)
        #expect(pair.unmatched == [near])
        // Facing the other way is a different opening.
        var reversedNormal = topChoice
        reversedNormal.signature.normal = Vec3(x: 0, y: 0, z: -1)
        #expect(OpeningCapper.matchChoices([reversedNormal], to: [before.openings[1]]).unmatched.count == 1)
    }

    /// Leave open: that opening's rim stays open ON PURPOSE — the receipt
    /// says so, the topology report stays honest (its rim edges are open),
    /// and the other opening is capped as usual.
    @Test
    func leavingOneOpeningOpenIsReportedAsYourChoice() throws {
        let tube = Self.openCup(capRings: nil)
        let diagnosis = try #require(OpeningCapper.diagnose(tube))
        let choice = OpeningCapper.OpeningChoice(signature: diagnosis.openings[1].signature, leaveOpen: true)
        let (summary, result) = try MeshModifier.closeOpenings(Self.summary(for: tube), topHeight: 0, choices: [choice])

        #expect(result.openingsClosed == 1)
        #expect(result.openingsLeftOpen == 1)
        #expect(result.leftOpenRimEdges == 48)
        #expect(result.openingOutcomes.map(\.leftOpen) == [false, true])
        #expect(result.receipt.contains("1 opening left open (your choice)"))
        #expect(result.receipt.contains("Closed opening 1 (flat)"))
        #expect(!result.receipt.contains("Not fully closed"))
        #expect(!result.flippedInsideOut)
        #expect(result.untouchedFraction == 1)
        // Honest topology: exactly the left-open rim is open, not watertight.
        #expect(summary.preflight.boundaryEdgeCount == 48)
        #expect(summary.preflight.nonManifoldEdgeCount == 0)
        #expect(!summary.preflight.isWatertight)
        #expect(result.remainingOpenEdges == 48)
        // The open rim is the top one (z = 30); the bottom got a cap.
        #expect(result.openingCapRangeByOpening.keys.sorted() == [0])

        // Every opening left open and nothing else to fix: say so, change nothing.
        let both = diagnosis.openings.map { OpeningCapper.OpeningChoice(signature: $0.signature, leaveOpen: true) }
        #expect(throws: OpeningCapper.CapError.everythingLeftOpen(2)) {
            _ = try OpeningCapper.close(tube, topHeight: 0, choices: both)
        }
        let model = Self.summary(for: tube)
        let (unchanged, message) = MeshModifier.makeWatertight(model, method: .closeOpenings, detail: 0.5, topHeight: 0,
                                                               openingChoices: both)
        #expect(unchanged.geometry == model.geometry)
        #expect(message?.contains("Leave open") == true)
    }

    /// Each opening can have its own top shape: the tube's bottom dished
    /// 5 mm (inward = up), the top domed 5 mm (outward = up), in one run.
    @Test
    func eachOpeningGetsItsOwnTopShape() throws {
        let tube = Self.openCup(capRings: nil)
        let diagnosis = try #require(OpeningCapper.diagnose(tube))
        let choices = [
            OpeningCapper.OpeningChoice(signature: diagnosis.openings[0].signature, topHeight: -5),
            OpeningCapper.OpeningChoice(signature: diagnosis.openings[1].signature, topHeight: 5),
        ]
        let result = try OpeningCapper.close(tube, topHeight: 0, choices: choices)
        #expect(result.openingsClosed == 2)
        #expect(result.capIntersections == 0)
        let outcomes = result.openingOutcomes
        #expect(outcomes.map(\.requestedHeight) == [-5, 5])
        #expect(abs(outcomes[0].appliedHeight + 5) < 0.1)
        #expect(abs(outcomes[1].appliedHeight - 5) < 0.1)
        #expect(result.receipt.contains("opening 1 dished 5.0 mm"))
        #expect(result.receipt.contains("opening 2 domed 5.0 mm"))
        let report = OpeningCapper.topologyReport(result.geometry)
        #expect(report.boundaryEdgeCount == 0 && report.manifoldValidated)

        // Both caps bulge up: the bottom's interior rises to ~z = 5, the top's to ~z = 35.
        var bottomPeak = -Double.infinity, topPeak = -Double.infinity
        for r in result.openingCapTriangleRanges {
            for f in r {
                for c in 0..<3 {
                    let v = result.geometry.vertices[Int(result.geometry.triangleIndices[3 * f + c])]
                    if v.z < 15 { bottomPeak = max(bottomPeak, v.z) } else { topPeak = max(topPeak, v.z) }
                }
            }
        }
        #expect(abs(bottomPeak - 5) < 0.1)
        #expect(abs(topPeak - 35) < 0.1)
    }

    /// A saved choice whose opening is gone is dropped — and the receipt says
    /// so — while every opening is capped as usual.
    @Test
    func unmatchedChoiceIsDroppedAndReported() throws {
        let tube = Self.openCup(capRings: nil)
        let gone = OpeningCapper.OpeningChoice(
            signature: OpeningCapper.OpeningSignature(center: Vec3(x: 100, y: 0, z: 0), diameter: 12, normal: Vec3(x: 1, y: 0, z: 0)),
            leaveOpen: true)
        let result = try OpeningCapper.close(tube, topHeight: 0, choices: [gone])
        #expect(result.openingsClosed == 2)
        #expect(result.openingsLeftOpen == 0)
        #expect(result.droppedChoices == 1)
        #expect(result.receipt.contains("1 saved opening choice no longer matches any opening"))
    }
}
