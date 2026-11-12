import XCTest
@testable import RefabArtist

/// PR-1 gate: proves the vendored static Manifold C API is linked and callable
/// from Swift (default mode, no C++ interop), and that the Double<->Float /
/// Int32<->UInt32 MeshGL marshalling round-trips correctly.
final class ManifoldEngineTests: XCTestCase {
    private func polygonArea(_ polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var twiceArea = 0.0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            let current = polygon[index]
            twiceArea += current.x * next.y - next.x * current.y
        }
        return abs(twiceArea) * 0.5
    }

    /// cube(2) centered at origin ∩ cube(2) centered at (1,1,1).
    /// Overlap is the unit cube [0,1]^3 → volume 1.0.
    func testCubeIntersectionVolume() throws {
        let a = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0),
                            extents: Vec3(x: 2, y: 2, z: 2))
        )
        let b = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 1, y: 1, z: 1),
                            extents: Vec3(x: 2, y: 2, z: 2))
        )

        let result = try ManifoldEngine.intersect(a, b)

        // Non-empty, watertight solid.
        XCTAssertFalse(ManifoldEngine.isEmpty(result), "intersection is empty")
        XCTAssertTrue(ManifoldEngine.isWatertight(result), "intersection is not watertight")
        XCTAssertGreaterThan(ManifoldEngine.triangleCount(result), 0,
                             "intersection has no triangles")

        // Volume ≈ 1.0 (±5%).
        let volume = ManifoldEngine.volume(result)
        XCTAssertEqual(volume, 1.0, accuracy: 0.05,
                       "intersection volume \(volume) != 1.0 (±5%)")
    }

    /// Read the intersection mesh back into Swift and assert it is non-empty,
    /// all coordinates finite, and lives inside the expected [0,1]^3 region.
    func testMeshReadbackIsFiniteAndBounded() throws {
        let a = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0),
                            extents: Vec3(x: 2, y: 2, z: 2))
        )
        let b = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 1, y: 1, z: 1),
                            extents: Vec3(x: 2, y: 2, z: 2))
        )
        let result = try ManifoldEngine.intersect(a, b)
        let mesh = try ManifoldEngine.toMesh(result)

        XCTAssertFalse(mesh.vertices.isEmpty, "no vertices read back")
        XCTAssertFalse(mesh.triangleIndices.isEmpty, "no triangle indices read back")
        XCTAssertEqual(mesh.triangleIndices.count % 3, 0, "tri index count not multiple of 3")
        XCTAssertEqual(mesh.triangleIndices.count / 3,
                       ManifoldEngine.triangleCount(result),
                       "tri count mismatch between handle and readback")

        let tol = 1e-3
        for v in mesh.vertices {
            XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite,
                          "non-finite vertex \(v.display)")
            XCTAssertGreaterThanOrEqual(v.x, 0 - tol)
            XCTAssertGreaterThanOrEqual(v.y, 0 - tol)
            XCTAssertGreaterThanOrEqual(v.z, 0 - tol)
            XCTAssertLessThanOrEqual(v.x, 1 + tol)
            XCTAssertLessThanOrEqual(v.y, 1 + tol)
            XCTAssertLessThanOrEqual(v.z, 1 + tol)
        }

        // Every index references a valid vertex.
        let n = Int32(mesh.vertices.count)
        for idx in mesh.triangleIndices {
            XCTAssertTrue(idx >= 0 && idx < n, "index \(idx) out of range 0..<\(n)")
        }
    }

    /// Verify the level_set C-callback bridge against a known analytic SDF: a
    /// sphere of radius 10 centered at origin. The field reads POSITIVE inside
    /// (radius - |p|), so the level-0 isosurface is the sphere surface. Asserts
    /// the extracted solid is watertight, its bounds ≈ [-10, 10]^3, and its
    /// volume ≈ 4/3 π r^3.
    func testLevelSetSphereSDF() throws {
        let r = 10.0
        let pad = 1.0
        let solid = try ManifoldEngine.levelSet(
            bounds: ManifoldEngine.LevelSetBounds(
                lo: Vec3(x: -r - pad, y: -r - pad, z: -r - pad),
                hi: Vec3(x: r + pad, y: r + pad, z: r + pad)
            ),
            edgeLength: 0.5,
            level: 0.0
        ) { x, y, z in
            // Positive inside the sphere, negative outside.
            r - (x * x + y * y + z * z).squareRoot()
        }

        XCTAssertFalse(ManifoldEngine.isEmpty(solid), "level_set produced empty solid")
        XCTAssertTrue(ManifoldEngine.isWatertight(solid), "level_set solid not watertight")

        let expected = 4.0 / 3.0 * Double.pi * r * r * r
        let vol = ManifoldEngine.volume(solid)
        XCTAssertEqual(vol, expected, accuracy: expected * 0.02,
                       "sphere volume \(vol) != \(expected) (±2%)")

        let b = ManifoldEngine.bounds(solid)
        let tol = 0.6  // ~ one edge length of discretization
        XCTAssertEqual(b.min.x, -r, accuracy: tol)
        XCTAssertEqual(b.min.y, -r, accuracy: tol)
        XCTAssertEqual(b.min.z, -r, accuracy: tol)
        XCTAssertEqual(b.max.x, r, accuracy: tol)
        XCTAssertEqual(b.max.y, r, accuracy: tol)
        XCTAssertEqual(b.max.z, r, accuracy: tol)
    }

    /// make(from:) -> toMesh round-trips a cube through the float/uint marshalling
    /// and yields the same solid volume (locks the Double<->Float stride).
    func testMakeFromGeometryRoundTrips() throws {
        let cube = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 0, y: 0, z: 0),
                            extents: Vec3(x: 2, y: 2, z: 2))
        )
        let mesh = try ManifoldEngine.toMesh(cube)
        let rebuilt = try ManifoldEngine.make(from: mesh)

        XCTAssertTrue(ManifoldEngine.isWatertight(rebuilt))
        XCTAssertEqual(ManifoldEngine.volume(rebuilt), 8.0, accuracy: 0.05,
                       "cube(2) volume should be 8")
    }

    func testConvexHullJoiningMatchesCapsuleVolume() throws {
        let radius = 2.0
        let distance = 10.0
        let segments: Int32 = 32

        let a = try ManifoldEngine.sphere(radius: radius, segments: segments)
        let b = try ManifoldEngine.translate(a, x: distance, y: 0, z: 0)
        let capsule = try ManifoldEngine.convexHull(joining: a, b)

        let expected = Double.pi * radius * radius * distance
            + 4.0 / 3.0 * Double.pi * radius * radius * radius
        XCTAssertTrue(ManifoldEngine.isWatertight(capsule))
        XCTAssertEqual(
            ManifoldEngine.volume(capsule),
            expected,
            accuracy: expected * 0.03,
            "capsule volume should match analytic hull volume"
        )
    }

    func testDecomposeSplitsDisjointSphereUnion() throws {
        let radius = 2.0
        let expectedVolume = 4.0 / 3.0 * Double.pi * radius * radius * radius

        let a = try ManifoldEngine.sphere(radius: radius, segments: 32)
        let translated = try ManifoldEngine.translate(a, x: 10, y: 0, z: 0)
        let union = try ManifoldEngine.union(a, translated)
        let components = try ManifoldEngine.decompose(union)

        XCTAssertEqual(components.count, 2, "disjoint union should decompose into 2 components")
        for component in components {
            XCTAssertTrue(ManifoldEngine.isWatertight(component))
            XCTAssertEqual(
                ManifoldEngine.volume(component),
                expectedVolume,
                accuracy: expectedVolume * 0.03,
                "component volume should match sphere volume"
            )
        }
    }

    func testSliceCubeReturnsSingleSquarePolygon() throws {
        let cube = try ManifoldEngine.box(
            ManifoldBoxSpec(center: Vec3(x: 25, y: 25, z: 25),
                            extents: Vec3(x: 50, y: 50, z: 50))
        )

        let polygons = try ManifoldEngine.slice(cube, atZ: 25)

        XCTAssertEqual(polygons.count, 1, "mid-slice of cube should be one polygon")
        XCTAssertEqual(polygons[0].count, 4, "mid-slice of cube should be a quad")
        XCTAssertEqual(polygonArea(polygons[0]), 2500.0, accuracy: 1e-6)
    }

    /// Locks the C wrapper's measured half-space ordering: the first split
    /// result is dot(p, normal) >= offset and the second is <= offset.
    func testPlaneSplitReturnsPositiveThenNegativeHalfSpace() throws {
        let box = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 2, y: 0, z: 0),
                extents: Vec3(x: 6, y: 2, z: 2)
            )
        )
        let halves = try ManifoldEngine.splitByPlane(
            box,
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 1
        )
        let firstBounds = ManifoldEngine.bounds(halves.0)
        let secondBounds = ManifoldEngine.bounds(halves.1)

        XCTAssertEqual(firstBounds.min.x, 1, accuracy: 1.0e-6)
        XCTAssertEqual(firstBounds.max.x, 5, accuracy: 1.0e-6)
        XCTAssertEqual(secondBounds.min.x, -1, accuracy: 1.0e-6)
        XCTAssertEqual(secondBounds.max.x, 1, accuracy: 1.0e-6)
    }

    /// Locks trim_by_plane's measured convention: it keeps the positive
    /// half-space dot(p, normal) >= offset.
    func testTrimByPlaneKeepsPositiveHalfSpace() throws {
        let box = try ManifoldEngine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 2, y: 0, z: 0),
                extents: Vec3(x: 6, y: 2, z: 2)
            )
        )
        let trimmed = try ManifoldEngine.trimByPlane(
            box,
            normal: Vec3(x: 1, y: 0, z: 0),
            offset: 1
        )
        let trimmedBounds = ManifoldEngine.bounds(trimmed)

        XCTAssertEqual(trimmedBounds.min.x, 1, accuracy: 1.0e-6)
        XCTAssertEqual(trimmedBounds.max.x, 5, accuracy: 1.0e-6)
    }
}
