import CManifold
import Foundation

/// Builds the cavity surface — the inner face of the mold — from the master,
/// branching on subtype:
///   - `slipShell`: cavity = the master surface, unchanged (conformal, exact).
///   - `siliconeJacket`: cavity = master offset OUTWARD by the silicone gap and
///     smoothed, via a Manifold Minkowski sum with a sphere of the gap/smoothing
///     radius (NOT marching cubes). The master is decimated first since the
///     jacket needs no fine detail. Sub-radius crevices are filled and convex
///     edges rounded to the ball radius — the intended smoothing.
///
/// All offsetting is deterministic from `settings.seed` (none of the current
/// path is stochastic, but the seed is threaded for future tie-breaks).
enum MoldCavityBuilder {
    // MARK: - Private helpers

    /// Build a geodesic-like sphere of radius `r` centered at the origin using
    /// an icosphere subdivided `subdivisions` times. This is used as the
    /// Minkowski summand for the silicone outward offset; it is small (one object
    /// summed with the master), so a moderate resolution is fine.
    ///
    /// Manifold's C API exposes `manifold_sphere(mem, radius, circularSegments)`.
    /// `circularSegments` controls angular resolution; 16 is compact, 24 is
    /// smoother. We use 24 for the jacket offset so the silicone surface is round,
    /// not faceted.
    ///
    /// NO marching cubes, NO level-set: the C API's `manifold_sphere` is a
    /// closed-form geodesic tessellation of the unit sphere scaled by `r`.
    private static func buildSphere(radius: Double, segments: Int32 = 24) throws -> ManifoldHandle {
        // manifold_sphere(mem, radius, circularSegments) → ManifoldManifold*
        let mem = UnsafeMutableRawPointer.allocate(
            byteCount: manifold_manifold_size(), alignment: 16
        )
        let raw = manifold_sphere(mem, radius, segments)
        guard let raw else {
            mem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        let status = manifold_status(raw)
        if status != MANIFOLD_NO_ERROR {
            manifold_destruct_manifold(raw)
            mem.deallocate()
            throw ManifoldEngineError.from(status: status)
        }
        return ManifoldHandle(adopting: mem, manifold: raw)
    }

    /// Decimate the master geometry by sub-sampling vertices before feeding it
    /// to the Minkowski sum. Manifold's `manifold_minkowski_sum` is O(V·W) where
    /// V is the vertex count of the first operand and W the sphere vertex count.
    /// Dense scan meshes (100k–1M+ triangles) would be unusably slow without a
    /// first-pass reduction. We use a stride-based sub-sample of triangles as a
    /// fast O(n) proxy for decimation: keep every `stride`-th triangle (plus any
    /// triangle that includes a vertex not yet covered). This is not a full QEM
    /// decimation but is sufficient for the smooth jacket use case where sub-
    /// millimetre surface detail is absorbed by the offset ball anyway.
    ///
    /// The stride is chosen so the output has at most `targetMaxTriangles`
    /// triangles. If the input is already at or below the target, it is returned
    /// unchanged (the same `MeshGeometryData` value is re-used, no copy).
    private static let targetMaxTrianglesForMinkowski = 8_000

    private static func decimate(_ geometry: MeshGeometryData) -> MeshGeometryData {
        let triCount = geometry.triangleIndices.count / 3
        guard triCount > targetMaxTrianglesForMinkowski else { return geometry }
        let stride = max(1, triCount / targetMaxTrianglesForMinkowski)

        var keptIndices = [Int32]()
        keptIndices.reserveCapacity(targetMaxTrianglesForMinkowski * 3)

        // Record which original vertex indices appear in kept triangles so we
        // can re-map them to a compact vertex array.
        var originalToCompact = [Int: Int32]()
        var compactVertices = [Vec3]()

        var tri = 0
        while tri < triCount {
            let base = tri * 3
            let ai = Int(geometry.triangleIndices[base])
            let bi = Int(geometry.triangleIndices[base + 1])
            let ci = Int(geometry.triangleIndices[base + 2])

            // Validate indices before keeping this triangle.
            guard geometry.vertices.indices.contains(ai),
                  geometry.vertices.indices.contains(bi),
                  geometry.vertices.indices.contains(ci) else {
                tri += stride
                continue
            }

            // Map / allocate compact vertex indices.
            func compact(_ orig: Int) -> Int32 {
                if let existing = originalToCompact[orig] { return existing }
                let newIdx = Int32(compactVertices.count)
                originalToCompact[orig] = newIdx
                compactVertices.append(geometry.vertices[orig])
                return newIdx
            }

            keptIndices.append(compact(ai))
            keptIndices.append(compact(bi))
            keptIndices.append(compact(ci))
            tri += stride
        }

        guard !keptIndices.isEmpty else { return geometry }
        return MeshGeometryData(vertices: compactVertices, triangleIndices: keptIndices)
    }

    // MARK: - Public API

    /// Produce the cavity surface geometry for the given subtype.
    ///
    /// - `slipShell`: returns the master geometry verbatim. The cavity IS the
    ///   master surface; the wall thickener builds outward from it.
    /// - `siliconeJacket`: decimate the master, import it into Manifold, compute
    ///   the Minkowski sum with a sphere of radius `siliconeGap + smoothing`, then
    ///   extract the resulting mesh. The Minkowski sum simultaneously offsets all
    ///   faces outward by the ball radius AND rounds convex edges/corners to that
    ///   radius, giving the smooth, gap-controlled inner jacket face. Sub-radius
    ///   crevices are filled (exactly the desired behaviour for a flex silicone
    ///   liner). NO marching cubes, NO level-set.
    static func buildCavity(
        master: MeshGeometryData,
        settings: MotherMoldSettings
    ) throws -> MeshGeometryData {
        switch settings.subtype {
        case .slipShell:
            // Conformal: cavity == master.
            return master

        case .siliconeJacket:
            // The offset radius = silicone gap + optional extra smoothing.
            // The gap provides demold clearance; the smoothing further rounds any
            // remaining sharp convex features on the jacket cavity face.
            let offsetRadius = settings.siliconeGap + max(0, settings.smoothing)
            guard offsetRadius > 1.0e-6 else {
                // Degenerate: no gap requested, treat as conformal.
                return master
            }

            // 1. Import the FULL master into Manifold, then reduce its triangle
            //    count with Manifold's MANIFOLD-PRESERVING `simplify`. The old
            //    stride-based triangle drop produced a holey, non-manifold mesh
            //    that Manifold rejected as `notManifold`; `make` succeeds on the
            //    (watertight) full master, and `simplify` keeps it a valid
            //    2-manifold while collapsing detail finer than the offset ball,
            //    which the Minkowski sum would absorb anyway.
            let masterHandle = try ManifoldEngine.make(from: master)
            let simplifyTolerance = max(0.25, offsetRadius * 0.2)
            let reducedHandle = (try? ManifoldEngine.simplify(masterHandle, tolerance: simplifyTolerance)) ?? masterHandle

            // 2. Build the offset sphere (NO MC — manifold_sphere is a closed-
            //    form geodesic tessellation).
            let sphereHandle = try buildSphere(radius: offsetRadius)

            // 3. Minkowski sum: every point in the result is master⊕sphere.
            //    For a convex set summed with a ball this is an exact outward
            //    offset; for concave meshes it fills crevices narrower than
            //    `offsetRadius` and rounds convex edges — intended behaviour.
            let cavityHandle = try ManifoldEngine.minkowskiSum(reducedHandle, sphereHandle)
            withExtendedLifetime(masterHandle) {}
            withExtendedLifetime(reducedHandle) {}
            withExtendedLifetime(sphereHandle) {}

            // 5. Extract to app mesh.
            let cavityGeo = try ManifoldEngine.toMesh(cavityHandle)
            withExtendedLifetime(cavityHandle) {}

            guard !cavityGeo.vertices.isEmpty else {
                throw MotherMoldPlannerError.cavityFailed(
                    "Minkowski sum produced an empty mesh (offsetRadius=\(offsetRadius)mm). "
                    + "Check that the master mesh is valid and not degenerate."
                )
            }

            return cavityGeo
        }
    }
}
