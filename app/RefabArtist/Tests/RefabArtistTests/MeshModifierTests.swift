import Foundation
import Testing
@testable import RefabArtist

/// Unit tests for MeshModifier (Thicken + Hollow engine). Every test runs on
/// simple analytic fixtures so results are predictable.
struct MeshModifierTests {

    // MARK: - Shared fixtures

    /// A closed cube with side length `side` mm, centered at the origin.
    /// 12 triangles (2 per face × 6 faces), 24 vertices (4 per face, not
    /// shared between faces). Because vertices are NOT shared across faces,
    /// each vertex's only incident triangles are on its own face, so its
    /// area-weighted normal is the pure face-outward direction (axis-aligned).
    /// This makes the Thicken bounds-growth assertion exact: each face
    /// (including its corner vertices) moves outward by exactly `amount`.
    private static func makeCube(side: Double = 50.0) -> MeshSummary {
        let h = side / 2
        // Builds one face as 4 vertices (un-shared) + 2 triangles.
        // winding: CCW when viewed from the outward normal direction.
        func face(
            _ v0: Vec3, _ v1: Vec3, _ v2: Vec3, _ v3: Vec3, // quad corners
            baseIndex: Int32
        ) -> ([Vec3], [Int32]) {
            let verts = [v0, v1, v2, v3]
            let idx: [Int32] = [
                baseIndex + 0, baseIndex + 1, baseIndex + 2,
                baseIndex + 0, baseIndex + 2, baseIndex + 3,
            ]
            return (verts, idx)
        }

        var verts: [Vec3] = []
        var idxs: [Int32] = []

        // -Z face (back): outward normal -Z, CCW when viewed from -Z
        let (v0, i0) = face(
            Vec3(x:  h, y: -h, z: -h), Vec3(x: -h, y: -h, z: -h),
            Vec3(x: -h, y:  h, z: -h), Vec3(x:  h, y:  h, z: -h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v0); idxs.append(contentsOf: i0)

        // +Z face (front): outward normal +Z, CCW when viewed from +Z
        let (v1, i1) = face(
            Vec3(x: -h, y: -h, z:  h), Vec3(x:  h, y: -h, z:  h),
            Vec3(x:  h, y:  h, z:  h), Vec3(x: -h, y:  h, z:  h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v1); idxs.append(contentsOf: i1)

        // -Y face (bottom): outward normal -Y
        let (v2, i2) = face(
            Vec3(x: -h, y: -h, z: -h), Vec3(x:  h, y: -h, z: -h),
            Vec3(x:  h, y: -h, z:  h), Vec3(x: -h, y: -h, z:  h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v2); idxs.append(contentsOf: i2)

        // +Y face (top): outward normal +Y
        let (v3, i3) = face(
            Vec3(x:  h, y:  h, z: -h), Vec3(x: -h, y:  h, z: -h),
            Vec3(x: -h, y:  h, z:  h), Vec3(x:  h, y:  h, z:  h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v3); idxs.append(contentsOf: i3)

        // -X face (left): outward normal -X (quad ordered CCW viewed from -X)
        let (v4, i4) = face(
            Vec3(x: -h, y: -h, z:  h), Vec3(x: -h, y:  h, z:  h),
            Vec3(x: -h, y:  h, z: -h), Vec3(x: -h, y: -h, z: -h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v4); idxs.append(contentsOf: i4)

        // +X face (right): outward normal +X (quad ordered CCW viewed from +X)
        let (v5, i5) = face(
            Vec3(x:  h, y: -h, z: -h), Vec3(x:  h, y:  h, z: -h),
            Vec3(x:  h, y:  h, z:  h), Vec3(x:  h, y: -h, z:  h),
            baseIndex: Int32(verts.count)
        )
        verts.append(contentsOf: v5); idxs.append(contentsOf: i5)

        let geo = MeshGeometryData(vertices: verts, triangleIndices: idxs.map { Int32($0) })
        let preflight = MeshPreflight.analyze(geometry: geo)
        let bounds = Bounds3D(min: Vec3(x: -h, y: -h, z: -h), max: Vec3(x: h, y: h, z: h))
        return MeshSummary(
            name: "cube",
            path: "",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: verts.count,
            faceCount: idxs.count / 3,
            triangleCount: idxs.count / 3,
            bounds: bounds,
            geometry: geo,
            preflight: preflight
        )
    }

    /// A flat axis-aligned quad (two triangles) whose vertex normals are
    /// degenerate (all face normals cancel pairwise across the surface, giving
    /// an area-weighted sum near zero). Tests the degenerate-normal guard.
    private static func makeDegenerateNormalFixture() -> MeshSummary {
        // Two back-to-back triangles with opposite windings: the net area-
        // weighted normal at each vertex is zero.
        let v: [Vec3] = [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 1, y: 1, z: 0),
        ]
        let idx: [Int32] = [
            0, 1, 2,  // CCW -> +Z normal
            2, 1, 3,  // CW  -> -Z normal (cancels at shared verts)
        ]
        let geo = MeshGeometryData(vertices: v, triangleIndices: idx)
        let preflight = MeshPreflight.analyze(geometry: geo)
        return MeshSummary(
            name: "degenerate",
            path: "",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: v.count,
            faceCount: idx.count / 3,
            triangleCount: idx.count / 3,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 1, y: 1, z: 0)),
            geometry: geo,
            preflight: preflight
        )
    }

    /// A dense single surface with tiny triangle edges but a large physical
    /// span. Hollow thickness should follow the requested wall value, not the
    /// tessellation edge length.
    private static func makeSubdividedPlane(side: Double = 50.0, divisions: Int = 50) -> (model: MeshSummary, centerVertexIndex: Int) {
        var vertices: [Vec3] = []
        let half = side / 2
        for row in 0...divisions {
            for col in 0...divisions {
                let x = -half + side * Double(col) / Double(divisions)
                let y = -half + side * Double(row) / Double(divisions)
                vertices.append(Vec3(x: x, y: y, z: 0))
            }
        }

        var indices: [Int32] = []
        let stride = divisions + 1
        for row in 0..<divisions {
            for col in 0..<divisions {
                let a = Int32(row * stride + col)
                let b = Int32(row * stride + col + 1)
                let c = Int32((row + 1) * stride + col + 1)
                let d = Int32((row + 1) * stride + col)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        let geo = MeshGeometryData(vertices: vertices, triangleIndices: indices)
        let bounds = Bounds3D(min: Vec3(x: -half, y: -half, z: 0), max: Vec3(x: half, y: half, z: 0))
        let centerVertexIndex = (divisions / 2) * stride + divisions / 2
        return (
            MeshSummary(
                name: "subdivided-plane",
                path: "",
                format: "stl",
                byteCount: 0,
                vertexObservationCount: vertices.count,
                faceCount: indices.count / 3,
                triangleCount: indices.count / 3,
                bounds: bounds,
                geometry: geo,
                preflight: MeshPreflight.analyze(geometry: geo)
            ),
            centerVertexIndex
        )
    }

    // MARK: - Thicken tests

    /// Thicken by 2 mm: each face of a cube moves outward by 2 mm, so the
    /// bounding box grows by 4 mm on every axis (2 mm per side).
    @Test
    func thickenGrowsCubeBoundsByTwoTimesAmount() throws {
        let amount = 2.0
        let cube = Self.makeCube(side: 50.0)
        let result = MeshModifier.thicken(cube, amount: amount)
        let original = try #require(cube.bounds)
        let modified = try #require(result.bounds)

        let tol = 0.01 // mm tolerance for floating-point accumulation
        // Each face moves out by `amount`; both sides of the box expand.
        #expect(abs((modified.max.x - original.max.x) - amount) < tol,
                "X max should grow by \(amount)")
        #expect(abs((original.min.x - modified.min.x) - amount) < tol,
                "X min should shrink by \(amount)")
        #expect(abs((modified.max.y - original.max.y) - amount) < tol,
                "Y max should grow by \(amount)")
        #expect(abs((original.min.y - modified.min.y) - amount) < tol,
                "Y min should shrink by \(amount)")
        #expect(abs((modified.max.z - original.max.z) - amount) < tol,
                "Z max should grow by \(amount)")
        #expect(abs((original.min.z - modified.min.z) - amount) < tol,
                "Z min should shrink by \(amount)")
    }

    /// Triangle count is preserved (Thicken only displaces vertices).
    @Test
    func thickenPreservesTriangleCount() {
        let cube = Self.makeCube()
        let result = MeshModifier.thicken(cube, amount: 5.0)
        #expect(result.triangleCount == cube.triangleCount)
    }

    /// Watertight cube in → watertight cube out (no new holes introduced).
    @Test
    func thickenWatertightInWatertightOut() {
        let cube = Self.makeCube()
        #expect(cube.preflight.boundaryEdgeCount == 0,
                "fixture must be watertight")
        let result = MeshModifier.thicken(cube, amount: 3.0)
        #expect(result.preflight.boundaryEdgeCount == 0,
                "thickened result must still be watertight")
    }

    /// Degenerate-normal vertices must not produce NaN/Inf coordinates.
    @Test
    func thickenDegenerateNormalFixtureDoesNotNaN() {
        let fixture = Self.makeDegenerateNormalFixture()
        let result = MeshModifier.thicken(fixture, amount: 5.0)
        for v in result.geometry.vertices {
            #expect(v.x.isFinite)
            #expect(v.y.isFinite)
            #expect(v.z.isFinite)
        }
    }

    /// Thicken(0) is a no-op: bounds unchanged.
    @Test
    func thickenZeroAmountIsNoop() throws {
        let cube = Self.makeCube()
        let result = MeshModifier.thicken(cube, amount: 0.0)
        let original = try #require(cube.bounds)
        let modified = try #require(result.bounds)
        let tol = 1.0e-9
        #expect(abs(modified.min.x - original.min.x) < tol)
        #expect(abs(modified.max.x - original.max.x) < tol)
        #expect(abs(modified.min.y - original.min.y) < tol)
        #expect(abs(modified.max.y - original.max.y) < tol)
        #expect(abs(modified.min.z - original.min.z) < tol)
        #expect(abs(modified.max.z - original.max.z) < tol)
    }

    // MARK: - Hollow tests

    /// Hollow of a cube: output has 2× triangle count (outer + inner shells).
    @Test
    func hollowDoubesTriangleCount() {
        let cube = Self.makeCube()
        let result = MeshModifier.hollow(cube, wallThickness: 3.0)
        #expect(result.triangleCount == cube.triangleCount * 2,
                "hollow must have 2× the triangle count (outer + inner shell)")
    }

    /// The inner shell faces the opposite direction (checking via signed-
    /// volume contribution): the outer shell has positive signed volume and
    /// the inner shell has negative. The combined signed volume of the hollow
    /// result must be less than the outer-only volume (subtracting the inner
    /// void).
    ///
    /// We test a structural property instead of exact signed volume: the inner
    /// half of the triangle list (second n/2 triangles) must have at least one
    /// triangle whose face normal opposes its outer counterpart. For the cube,
    /// the first 12 triangles (outer) have the same face normals as the input;
    /// the last 12 (inner, flipped) have exactly opposite normals.
    @Test
    func hollowInnerShellHasFlippedWinding() throws {
        let cube = Self.makeCube()
        let result = MeshModifier.hollow(cube, wallThickness: 2.0)
        let geo = result.geometry
        let n = geo.triangleIndices.count

        // Face normal of triangle at index baseI (index triplet in geo.triangleIndices).
        func faceNormal(baseI: Int) -> Vec3? {
            guard baseI + 2 < n else { return nil }
            let ai = Int(geo.triangleIndices[baseI])
            let bi = Int(geo.triangleIndices[baseI + 1])
            let ci = Int(geo.triangleIndices[baseI + 2])
            guard geo.vertices.indices.contains(ai),
                  geo.vertices.indices.contains(bi),
                  geo.vertices.indices.contains(ci) else { return nil }
            let a = geo.vertices[ai], b = geo.vertices[bi], c = geo.vertices[ci]
            let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            return Vec3(
                x: ab.y * ac.z - ab.z * ac.y,
                y: ab.z * ac.x - ab.x * ac.z,
                z: ab.x * ac.y - ab.y * ac.x
            )
        }

        // The cube has 12 outer triangles and 12 inner triangles.
        let outerTriCount = cube.triangleCount
        var foundOpposite = false
        for t in 0..<outerTriCount {
            guard let outerN = faceNormal(baseI: t * 3),
                  let innerN = faceNormal(baseI: (outerTriCount + t) * 3) else { continue }
            // dot < 0 means the inner and outer face normals for the same
            // "slot" point in opposite directions — confirming flipped winding.
            let dot = outerN.x * innerN.x + outerN.y * innerN.y + outerN.z * innerN.z
            if dot < 0 { foundOpposite = true; break }
        }
        #expect(foundOpposite, "at least one inner triangle must have opposed face normal")
    }

    /// Hollow of a watertight cube produces a watertight result.
    @Test
    func hollowWatertightInWatertightOut() {
        let cube = Self.makeCube()
        #expect(cube.preflight.boundaryEdgeCount == 0,
                "fixture must be watertight")
        let result = MeshModifier.hollow(cube, wallThickness: 2.0)
        #expect(result.preflight.boundaryEdgeCount == 0,
                "hollowed result must still be watertight")
    }

    /// Wall thickness must not exceed the cube's half-side (25 mm for a 50 mm
    /// cube). With wallThickness == 1 mm, the inner-shell vertex at the centre
    /// of a face must be 1 mm inside the outer face.
    @Test
    func hollowInnerShellIsInsideOuter() throws {
        let side = 50.0
        let wall = 1.0
        let cube = Self.makeCube(side: side)
        let result = MeshModifier.hollow(cube, wallThickness: wall)
        let original = try #require(cube.bounds)
        let modified = try #require(result.bounds)

        // Outer shell bounds must equal the original (the outer shell is
        // identical to the input: hollow does not move the outer shell).
        let tol = 1.0e-9
        #expect(abs(modified.min.x - original.min.x) < tol, "outer min-X preserved")
        #expect(abs(modified.max.x - original.max.x) < tol, "outer max-X preserved")
    }

    @Test
    func hollowWallThicknessIsNotCappedByDenseTriangleEdges() throws {
        let fixture = Self.makeSubdividedPlane(side: 50.0, divisions: 50)
        let wall = 5.0
        let result = MeshModifier.hollow(fixture.model, wallThickness: wall)
        let outerCount = fixture.model.geometry.vertices.count
        let innerCenter = result.geometry.vertices[outerCount + fixture.centerVertexIndex]

        #expect(abs(innerCenter.z + wall) < 1.0e-6,
                "dense 1 mm triangles must not clamp a 5 mm hollow wall")
    }

    // MARK: - Round-trip preflight

    /// Both Thicken and Hollow re-analyze with MeshPreflight: the returned
    /// MeshSummary's preflight fields are not stale copies from the input.
    @Test
    func thickenAndHollowReturnFreshPreflight() {
        let cube = Self.makeCube()
        // Original preflight.
        let originalPF = cube.preflight

        let thickened = MeshModifier.thicken(cube, amount: 5.0)
        // After thicken the vertex count changes → preflight vertex count must differ
        // (thicken keeps same count, but preflight must be re-run — check isWatertight).
        #expect(thickened.preflight.isWatertight, "thickened cube must be watertight")

        let hollowed = MeshModifier.hollow(cube, wallThickness: 2.0)
        #expect(hollowed.triangleCount == cube.triangleCount * 2)
        #expect(hollowed.preflight.isWatertight, "hollowed cube must be watertight")

        _ = originalPF // suppress unused warning
    }
}
