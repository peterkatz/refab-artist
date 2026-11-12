import Foundation

/// Whole-model mesh modification tools behind the Modify Form panel:
/// Thicken, Hollow, Shrinkwrap.
///
/// All operations are purely functional (no mutation of input), return a new
/// MeshGeometryData, and re-analyze with MeshPreflight before surfacing the
/// result so downstream slicers see accurate manifold/boundary counts.
///
/// Make Watertight (`shrinkwrap`) delegates to MeshHealer — a generalized-
/// winding-number SIGNED distance field fed to Manifold's level_set. It heals a
/// non-watertight mesh into a single closed solid WITHOUT inflating the surface
/// (bounds ≈ source). This replaced the old voxel-occupancy shrinkwrap, which
/// inflated the model by ~1–2 voxels.
///
/// --- Vertex normal computation ---
/// Area-weighted vertex normals are the standard approach for smooth offsets:
/// each incident triangle contributes its face normal scaled by its area, so
/// large triangles influence the smoothed direction more than slivers. This
/// avoids the spike artefacts that appear with simple averaged normals when a
/// high-degree vertex has one dominant large face.
///
/// --- Weld strategy ---
/// The same 1e-6 quantized weld used by MeshManifoldRepair and MeshPreflight
/// is applied to merge co-located vertices before computing normals. This
/// ensures that two vertices at the "same" geometric position accumulate
/// contributions from all their shared triangles, rather than each vertex
/// computing an isolated one-triangle normal.
enum MeshModifier {
    private static let weldTolerance = 1.0e-6

    // MARK: - Vertex key (matches MeshManifoldRepair's VertexKey)

    private struct VertexKey: Hashable {
        let xi: Int64
        let yi: Int64
        let zi: Int64

        init(_ p: Vec3, tolerance: Double) {
            xi = Int64((p.x / tolerance).rounded())
            yi = Int64((p.y / tolerance).rounded())
            zi = Int64((p.z / tolerance).rounded())
        }
    }

    // MARK: - Area-weighted vertex normals

    /// Returns one unit outward normal per VERTEX INDEX (not per unique weld
    /// key). Vertices that share a geometric position after welding accumulate
    /// all incident face normals together, so the returned normal for index i
    /// is the area-weighted average of all faces touching the weld-equivalent
    /// of vertex i.
    ///
    /// A zero result (e.g. isolated vertex with no incident triangles, or
    /// face-normal cancellation on a perfectly flat sheet) is replaced by
    /// Vec3(x:0, y:0, z:1) so offsets never produce NaN coordinates.
    /// Spike guard at very acute creases: a mitre direction longer than this
    /// (in multiples of the offset amount) is scaled back.
    private static let mitreLimit = 3.0

    /// Per-vertex offset DIRECTIONS for plane-true offsetting: displacing a
    /// vertex by `amount × direction` moves EVERY distinct face plane meeting
    /// at it outward by exactly `amount` (the mitre solve — exact for
    /// flat-faced meshes: a cube corner travels amount·√3 diagonally so each
    /// face advances by amount). Averaged vertex normals under-displace the
    /// planes by the corner angle's cosine, which is what made Thicken grow a
    /// cube's bounds by less than the requested amount, unevenly per axis.
    /// Directions are NOT unit length.
    private static func mitreOffsetDirections(
        vertices: [Vec3],
        triangleIndices: [Int32]
    ) -> [Vec3] {
        // Map each vertex index to its canonical weld key.
        let keys = vertices.map { VertexKey($0, tolerance: weldTolerance) }

        // Collect the DISTINCT unit face normals per weld key (deduped, so a
        // cube corner sees exactly its 3 planes regardless of triangulation).
        var distinctNormals: [VertexKey: [Vec3]] = [:]
        var i = 0
        while i + 2 < triangleIndices.count {
            let ai = Int(triangleIndices[i])
            let bi = Int(triangleIndices[i + 1])
            let ci = Int(triangleIndices[i + 2])
            guard vertices.indices.contains(ai),
                  vertices.indices.contains(bi),
                  vertices.indices.contains(ci) else { i += 3; continue }
            let a = vertices[ai], b = vertices[bi], c = vertices[ci]
            let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            let nx = ab.y * ac.z - ab.z * ac.y
            let ny = ab.z * ac.x - ab.x * ac.z
            let nz = ab.x * ac.y - ab.y * ac.x
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            guard len > 1.0e-12 else { i += 3; continue }
            let unit = Vec3(x: nx / len, y: ny / len, z: nz / len)
            for key in [keys[ai], keys[bi], keys[ci]] {
                var list = distinctNormals[key] ?? []
                let known = list.contains { existing in
                    existing.x * unit.x + existing.y * unit.y + existing.z * unit.z > 0.9999
                }
                if !known {
                    list.append(unit)
                    distinctNormals[key] = list
                }
            }
            i += 3
        }

        let fallback = Vec3(x: 0, y: 0, z: 1)
        return vertices.indices.map { idx in
            guard let normals = distinctNormals[keys[idx]], !normals.isEmpty else { return fallback }
            return mitreDirection(for: normals)
        }
    }

    /// Solve for d with d·nᵢ = 1 for every distinct plane normal: exact for
    /// 1 and 2 planes, least-squares for 3+, degenerate sets fall back to the
    /// two-plane mitre. Length capped at `mitreLimit`.
    private static func mitreDirection(for normals: [Vec3]) -> Vec3 {
        func capped(_ d: Vec3) -> Vec3 {
            let len = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            guard len > mitreLimit else { return d }
            let s = mitreLimit / len
            return Vec3(x: d.x * s, y: d.y * s, z: d.z * s)
        }
        guard let first = normals.first else { return Vec3(x: 0, y: 0, z: 1) }
        if normals.count == 1 { return first }
        if normals.count == 2 {
            let n1 = normals[0], n2 = normals[1]
            let c = n1.x * n2.x + n1.y * n2.y + n1.z * n2.z
            guard 1 + c > 1.0e-6 else { return first } // opposing faces: thin sheet, no consistent mitre
            let inv = 1 / (1 + c)
            return capped(Vec3(x: (n1.x + n2.x) * inv, y: (n1.y + n2.y) * inv, z: (n1.z + n2.z) * inv))
        }
        var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, a22 = 0.0
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for n in normals {
            a00 += n.x * n.x; a01 += n.x * n.y; a02 += n.x * n.z
            a11 += n.y * n.y; a12 += n.y * n.z; a22 += n.z * n.z
            b0 += n.x; b1 += n.y; b2 += n.z
        }
        let det = a00 * (a11 * a22 - a12 * a12)
            - a01 * (a01 * a22 - a12 * a02)
            + a02 * (a01 * a12 - a11 * a02)
        guard abs(det) > 1.0e-9 else {
            return mitreDirection(for: [normals[0], normals[normals.count - 1]])
        }
        let dx = b0 * (a11 * a22 - a12 * a12) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a12 - a11 * b2)
        let dy = a00 * (b1 * a22 - a12 * b2) - b0 * (a01 * a22 - a12 * a02) + a02 * (a01 * b2 - b1 * a02)
        let dz = a00 * (a11 * b2 - b1 * a12) - a01 * (a01 * b2 - b1 * a02) + b0 * (a01 * a12 - a11 * a02)
        return capped(Vec3(x: dx / det, y: dy / det, z: dz / det))
    }

    // MARK: - Bounds helper

    private static func computeBounds(_ vertices: [Vec3]) -> Bounds3D? {
        guard let first = vertices.first else { return nil }
        var minV = first, maxV = first
        for v in vertices {
            if v.x < minV.x { minV = Vec3(x: v.x, y: minV.y, z: minV.z) }
            if v.y < minV.y { minV = Vec3(x: minV.x, y: v.y, z: minV.z) }
            if v.z < minV.z { minV = Vec3(x: minV.x, y: minV.y, z: v.z) }
            if v.x > maxV.x { maxV = Vec3(x: v.x, y: maxV.y, z: maxV.z) }
            if v.y > maxV.y { maxV = Vec3(x: maxV.x, y: v.y, z: maxV.z) }
            if v.z > maxV.z { maxV = Vec3(x: maxV.x, y: maxV.y, z: v.z) }
        }
        return Bounds3D(min: minV, max: maxV)
    }

    private static func summaryFromGeometry(_ geo: MeshGeometryData, source: MeshSummary) -> MeshSummary {
        let preflight = MeshPreflight.analyze(geometry: geo)
        return MeshSummary(
            name: source.name,
            path: source.path,
            format: source.format,
            byteCount: source.byteCount,
            vertexObservationCount: geo.vertices.count,
            faceCount: geo.triangleIndices.count / 3,
            triangleCount: geo.triangleIndices.count / 3,
            bounds: computeBounds(geo.vertices),
            geometry: geo,
            preflight: preflight
        )
    }

    // MARK: - Local feature-size heuristic (for hollow clamping)

    /// Approximate minimum feature size at each vertex: smallest distance to
    /// any adjacent (edge-connected) vertex in the source mesh. Used by Hollow
    /// to prevent the inner offset shell from crossing through thin walls.
    ///
    /// Only considers edges within each triangle (O(triangles)), which is
    /// sufficient for the clamping purpose: the shell is pulled inward only as
    /// far as the tightest local edge length allows.
    private static func minimumEdgeLengths(
        vertices: [Vec3],
        triangleIndices: [Int32]
    ) -> [Double] {
        var minLen = [Double](repeating: Double.infinity, count: vertices.count)
        var i = 0
        while i + 2 < triangleIndices.count {
            let ai = Int(triangleIndices[i])
            let bi = Int(triangleIndices[i + 1])
            let ci = Int(triangleIndices[i + 2])
            guard vertices.indices.contains(ai),
                  vertices.indices.contains(bi),
                  vertices.indices.contains(ci) else { i += 3; continue }
            func edgeLen(_ p: Vec3, _ q: Vec3) -> Double {
                let dx = q.x - p.x, dy = q.y - p.y, dz = q.z - p.z
                return (dx * dx + dy * dy + dz * dz).squareRoot()
            }
            let lab = edgeLen(vertices[ai], vertices[bi])
            let lbc = edgeLen(vertices[bi], vertices[ci])
            let lca = edgeLen(vertices[ci], vertices[ai])
            if lab < minLen[ai] { minLen[ai] = lab }
            if lab < minLen[bi] { minLen[bi] = lab }
            if lbc < minLen[bi] { minLen[bi] = lbc }
            if lbc < minLen[ci] { minLen[ci] = lbc }
            if lca < minLen[ci] { minLen[ci] = lca }
            if lca < minLen[ai] { minLen[ai] = lca }
            i += 3
        }
        // Isolated vertices: leave at infinity → they'll be skipped by hollow.
        return minLen
    }

    // MARK: - Public API

    /// Offset every vertex outward along its area-weighted vertex normal by
    /// `amount` mm. This thickens the mesh uniformly, making thin or non-
    /// manifold scans thick enough to yield closed cross-sections when sliced.
    ///
    /// Degenerate normals (computed as the fallback Vec3(0,0,1)) are used as-
    /// is; they produce a valid offset, just in the +Z direction rather than
    /// the true surface normal. This is preferable to NaN/Inf coordinates.
    ///
    /// After offsetting, MeshPreflight re-analyzes the result so callers see
    /// accurate manifold/boundary counts for the modified mesh.
    ///
    /// - Parameters:
    ///   - model: Source mesh (not mutated).
    ///   - amount: Offset distance in mm (positive = outward). Negative amounts
    ///     move vertices inward; no specific guard is applied for inward offsets
    ///     — callers should use Hollow for shell operations.
    /// - Returns: Modified MeshSummary with updated geometry and preflight.
    static func thicken(_ model: MeshSummary, amount: Double) -> MeshSummary {
        let geo = model.geometry
        let directions = mitreOffsetDirections(
            vertices: geo.vertices,
            triangleIndices: geo.triangleIndices
        )
        let newVertices = geo.vertices.indices.map { idx -> Vec3 in
            let v = geo.vertices[idx]
            let d = directions[idx]
            return Vec3(
                x: v.x + d.x * amount,
                y: v.y + d.y * amount,
                z: v.z + d.z * amount
            )
        }
        let newGeo = MeshGeometryData(vertices: newVertices, triangleIndices: geo.triangleIndices)
        return summaryFromGeometry(newGeo, source: model)
    }

    /// Shell the model: return the original surface stitched together with an
    /// inward-offset copy that has reversed winding (flipped face orientation
    /// for a correct inward-facing surface). The two shells are concatenated
    /// without cap triangles — the result has boundary edges at any open
    /// contour of the original, but for a watertight input the combined mesh
    /// is also watertight (inner + outer shells share the same boundary
    /// topology, which cancels).
    ///
    /// The requested wall is capped against the model's physical span, not the
    /// tessellation edge length. Dense scan triangles can be sub-millimeter;
    /// clamping against them made every Hollow value collapse to a paper-thin
    /// shell on real scans.
    ///
    /// - Parameters:
    ///   - model: Source mesh (not mutated).
    ///   - wallThickness: Target wall thickness in mm (must be > 0).
    /// - Returns: Combined outer + inner-shell MeshSummary with updated preflight.
    static func hollow(_ model: MeshSummary, wallThickness: Double) -> MeshSummary {
        guard wallThickness.isFinite, wallThickness > 0 else { return model }
        let requestedWallThickness = min(wallThickness, maximumWallThickness(for: model) ?? wallThickness)
        let geo = model.geometry
        let directions = mitreOffsetDirections(
            vertices: geo.vertices,
            triangleIndices: geo.triangleIndices
        )

        // Outer shell: original geometry (unchanged winding = outward normals).
        let outerVertices = geo.vertices

        // Inner shell: offset inward (negative normal direction).
        let innerVertices: [Vec3] = geo.vertices.indices.map { idx in
            let v = geo.vertices[idx]
            let d = directions[idx]
            // The mitre displacement (wallThickness × d) gives a plane-true
            // wall; its LENGTH can legitimately exceed wallThickness at
            // corners. Do not clamp by triangle edge length: that turns dense
            // triangulation into an invisible wall-thickness cap.
            let move = Vec3(x: d.x * requestedWallThickness, y: d.y * requestedWallThickness, z: d.z * requestedWallThickness)
            return Vec3(
                x: v.x - move.x,
                y: v.y - move.y,
                z: v.z - move.z
            )
        }

        let outerCount = Int32(outerVertices.count)
        let outerIndices = geo.triangleIndices

        // Inner shell: shift indices by outerCount, flip winding (reverse
        // triangle vertex order so face normals point inward).
        var innerIndices = [Int32]()
        innerIndices.reserveCapacity(geo.triangleIndices.count)
        var i = 0
        while i + 2 < geo.triangleIndices.count {
            // Reverse b and c to flip winding.
            innerIndices.append(geo.triangleIndices[i] + outerCount)
            innerIndices.append(geo.triangleIndices[i + 2] + outerCount)
            innerIndices.append(geo.triangleIndices[i + 1] + outerCount)
            i += 3
        }

        let combinedVertices = outerVertices + innerVertices
        let combinedIndices = outerIndices + innerIndices
        let combinedGeo = MeshGeometryData(
            vertices: combinedVertices,
            triangleIndices: combinedIndices
        )
        return summaryFromGeometry(combinedGeo, source: model)
    }

    private static func maximumWallThickness(for model: MeshSummary) -> Double? {
        guard let bounds = model.bounds else { return nil }
        let spans = [
            bounds.max.x - bounds.min.x,
            bounds.max.y - bounds.min.y,
            bounds.max.z - bounds.min.z,
        ].filter { $0.isFinite && $0 > 1.0e-9 }
        guard let shortestSpan = spans.min() else { return nil }
        return shortestSpan * 0.45
    }

    /// Make Watertight: heal the mesh into a single closed, watertight solid that
    /// closes holes and removes internal cavities WITHOUT inflating the surface.
    ///
    /// Engine: MeshHealer — a generalized-winding-number (GWN) SIGNED distance
    /// field fed to Manifold's `level_set` at level 0. The GWN gives a correct
    /// inside/outside sign even on a mesh with holes/handles, so the zero
    /// isocontour sits ON the original surface (bounds ≈ source, thin features
    /// preserved). This replaced the old voxel-occupancy shrinkwrap, whose
    /// conservative voxelization + blur pushed the surface out ~1–2 voxels and
    /// inflated the model.
    ///
    /// - Parameters:
    ///   - model: Source mesh (not mutated).
    ///   - detail: 0…1 (clamped). Maps to the heal's level-set edge length
    ///     (voxel pitch) as a fraction of the bbox diagonal: 0 → coarse
    ///     (diag/45, fast), 1 → fine (diag/160, high fidelity, slower). Higher
    ///     = finer surface detail and slower heal — same UX as before.
    /// - Returns: Healed watertight MeshSummary with fresh preflight. Inputs with
    ///   no usable geometry, or a heal that fails to produce a non-empty solid,
    ///   are returned unchanged.
    static func shrinkwrap(_ model: MeshSummary, detail: Double) -> MeshSummary {
        (try? rebuildAsSolid(model, detail: detail))?.summary ?? model
    }

    /// Why Rebuild as solid could not produce a result.
    enum RebuildError: Error, Equatable {
        case noSize
        case failed(String)

        var userMessage: String {
            switch self {
            case .noSize: return "Can't rebuild: the model has no size."
            case .failed(let why): return "Can't rebuild: \(why) Nothing was changed."
            }
        }
    }

    /// Rebuild as solid (the whole-surface GWN heal) with a plain-language
    /// receipt. Throws `RebuildError` with the reason instead of silently
    /// returning the input. Crumbs — separate pieces under 0.5 % of the
    /// largest piece's volume — are dropped and counted in the receipt.
    static func rebuildAsSolid(_ model: MeshSummary, detail: Double) throws -> (summary: MeshSummary, receipt: String) {
        let started = Date()
        let clamped = min(max(detail, 0.0), 1.0)
        guard let bounds = model.bounds else { throw RebuildError.noSize }
        let dx = bounds.max.x - bounds.min.x
        let dy = bounds.max.y - bounds.min.y
        let dz = bounds.max.z - bounds.min.z
        let diag = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard diag.isFinite, diag > 1.0e-9 else { throw RebuildError.noSize }

        // Finer detail -> more divisions of the diagonal -> smaller edge length.
        // 0 → diag/45 (coarse), 1 → diag/160 (fine). Clamp the absolute edge to
        // a sane mm range so tiny or huge models still heal in bounded time.
        let divisions = 45.0 + clamped * 115.0
        let edge = min(max(diag / divisions, 0.3), 4.0)

        let result: MeshHealer.HealResult
        do {
            result = try MeshHealer.heal(model.geometry, edgeLength: edge)
        } catch let error as MeshHealer.HealError {
            throw RebuildError.failed(error.userMessage)
        } catch let error as ManifoldEngineError {
            throw RebuildError.failed(error.userMessage)
        }

        // The heal handle is, by Manifold's invariant, a valid watertight
        // 2-manifold (level_set emits a crack-free isosurface). Two things
        // still have to happen before the user gets a clean result:
        //
        //  1. Collapse the sub-tolerance sliver triangles marching cubes
        //     emits where the isosurface clips a grid cell. Manifold's
        //     `simplify` edge-collapses them while STAYING a valid
        //     2-manifold; tolerance is a small fraction of the voxel pitch so
        //     the surface shape is unchanged. Without this the meshgl64
        //     readback carries zero-area faces that downstream `make()` and
        //     MeshPreflight choke on.
        //
        //  2. Record that Manifold validated this as a closed solid, so the
        //     watertight VERDICT reflects "closed, usable solid" rather than
        //     "strictly 2-manifold". MeshPreflight.analyze re-derives topology
        //     by welding vertices on a 1e-6 grid; on a healed organic shell
        //     that weld fuses distinct manifold vertices where the surface
        //     SELF-CONTACTS (two sheets within a micron, e.g. webbing between
        //     fingers), counting those self-contacts as non-manifold edges.
        //     Those edges are real (an STL would show them) but benign — the
        //     mesh holds water and Manifold/the mold builder accept it. We keep
        //     the HONEST count for display and set `manifoldValidated` so the
        //     verdict doesn't fail on benign self-contact (see
        //     summaryFromHealedGeometry). We do NOT fabricate the counts to 0.
        let simplifiedHandle: ManifoldHandle
        if let simplified = try? ManifoldEngine.simplify(result.handle, tolerance: edge * 0.05),
           ManifoldEngine.isWatertight(simplified) {
            simplifiedHandle = simplified
        } else {
            simplifiedHandle = result.handle
        }

        // Crumb filter (after simplify, which can pinch a speck off): the GWN field leaves specks where the winding number
        // flickers across 0.5 near thin or open features. Drop pieces under
        // 0.5 % of the largest piece's volume; keep everything else as is.
        var cleaned = simplifiedHandle
        var crumbsDropped = 0
        // (`REFAB_REBUILD_KEEP_CRUMBS=1` skips it — diagnostics only, to
        // compare the heal itself against older builds.)
        let keepCrumbs = ProcessInfo.processInfo.environment["REFAB_REBUILD_KEEP_CRUMBS"] == "1"
        if !keepCrumbs, let parts = try? ManifoldEngine.decompose(simplifiedHandle), parts.count > 1 {
            let volumes = parts.map { abs(ManifoldEngine.volume($0)) }
            let largest = volumes.max() ?? 0
            if ProcessInfo.processInfo.environment["REFAB_HEAL_TRACE"] == "1" {
                let signed = parts.map { ManifoldEngine.volume($0) }.sorted()
                let tris = parts.map { ManifoldEngine.triangleCount($0) }
                FileHandle.standardError.write(Data("rebuild pieces: volumes=\(signed) tris=\(tris)\n".utf8))
            }
            let kept = zip(parts, volumes).filter { $0.1 >= 0.005 * largest }.map(\.0)
            if kept.count < parts.count, let composed = try? ManifoldEngine.compose(kept) {
                crumbsDropped = parts.count - kept.count
                cleaned = composed
            }
        }


        let mesh: MeshGeometryData
        do {
            mesh = try ManifoldEngine.toMesh(cleaned)
        } catch {
            throw RebuildError.failed("the rebuilt solid could not be read back.")
        }
        let geo = SurfaceDespeckle.polished(mesh, normalIterations: 1, vertexIterations: 3)
        let watertight = ManifoldEngine.isWatertight(cleaned)
        let pieces = (try? ManifoldEngine.decompose(cleaned).count) ?? 1
        withExtendedLifetime(result.handle) {}
        withExtendedLifetime(simplifiedHandle) {}
        withExtendedLifetime(cleaned) {}
        guard !geo.vertices.isEmpty, geo.triangleIndices.count >= 3 else {
            throw RebuildError.failed("the rebuild came out empty.")
        }
        let summary = summaryFromHealedGeometry(geo, manifoldWatertight: watertight, source: model)

        var bits: [String] = []
        bits.append(pieces == 1
            ? "Rebuilt the whole surface as one closed solid (\(summary.triangleCount) triangles)"
            : "Rebuilt the whole surface as \(pieces) closed solids (\(summary.triangleCount) triangles)")
        if result.flippedInsideOut { bits.append("the surface was inside-out, so it was turned right side out first") }
        if crumbsDropped > 0 {
            bits.append(crumbsDropped == 1 ? "dropped 1 crumb" : "dropped \(crumbsDropped) crumbs")
        }
        var receipt = bits.joined(separator: "; ") + "."
        receipt += String(format: " Voxel size %.2f mm, %.1f s.", edge, Date().timeIntervalSince(started))
        return (summary, receipt)
    }

    /// Make Watertight, either method, plus a plain-language result line.
    /// Never fails silently: when nothing could be done the model comes back
    /// unchanged WITH a message saying why.
    static func makeWatertight(
        _ model: MeshSummary,
        method: WatertightMethod,
        detail: Double,
        topHeight: Double,
        wallThickness: Double = 2,
        openingChoices: [OpeningCapper.OpeningChoice] = []
    ) -> (MeshSummary, String?) {
        let outcome = makeWatertightOutcome(model, method: method, detail: detail, topHeight: topHeight,
                                            wallThickness: wallThickness, openingChoices: openingChoices)
        return (outcome.summary, outcome.receipt)
    }

    /// `makeWatertight` plus whether the method changed the model at all
    /// (false when it failed or had nothing to do — the model is returned
    /// unchanged and the receipt says why).
    static func makeWatertightOutcome(
        _ model: MeshSummary,
        method: WatertightMethod,
        detail: Double,
        topHeight: Double,
        wallThickness: Double = 2,
        openingChoices: [OpeningCapper.OpeningChoice] = []
    ) -> (summary: MeshSummary, receipt: String?, changed: Bool) {
        switch method {
        case .walls:
            do {
                let (walled, receipt) = try makeWalls(model, thickness: wallThickness, choices: openingChoices)
                return (walled, receipt, true)
            } catch let error as WallMaker.WallError {
                return (model, error.userMessage, false)
            } catch {
                return (model, "Couldn't make walls — nothing was changed.", false)
            }
        case .closeOpenings:
            do {
                let (closed, result) = try closeOpenings(model, topHeight: topHeight, choices: openingChoices)
                return (closed, result.receipt, true)
            } catch OpeningCapper.CapError.everythingLeftOpen(let n) {
                return (model, OpeningCapper.CapError.everythingLeftOpen(n).localizedDescription, false)
            } catch OpeningCapper.CapError.needsRebuild(let why) {
                return (model, "Can't close openings: \(why)", false)
            } catch OpeningCapper.CapError.nothingToClose {
                return (model, "Nothing to fix — the surface is already a closed solid.", false)
            } catch OpeningCapper.CapError.noSurface {
                return (model, "There is no surface to repair — nothing was changed.", false)
            } catch {
                return (model, "Couldn't close the openings (\(error.localizedDescription)) — nothing was changed.", false)
            }
        case .rebuild:
            do {
                let (rebuilt, receipt) = try rebuildAsSolid(model, detail: detail)
                return (rebuilt, receipt, true)
            } catch let error as RebuildError {
                return (model, error.userMessage, false)
            } catch {
                return (model, "Couldn't rebuild the surface — nothing was changed.", false)
            }
        }
    }

    /// Make Watertight → Close openings: cap the openings of an open skin,
    /// heal small damaged spots in place (cut out and refill), and keep every
    /// other original triangle bit-identical (see `OpeningCapper`).
    /// `topHeight` mm: 0 flat, > 0 dome, < 0 dish (openings only). Throws
    /// `needsRebuild(reason)` when the damage is too widespread to fix in
    /// place, `nothingToClose` when there is nothing to fix.
    static func closeOpenings(_ model: MeshSummary, topHeight: Double,
                              choices: [OpeningCapper.OpeningChoice] = []) throws -> (summary: MeshSummary, result: OpeningCapper.Result) {
        var result = try OpeningCapper.close(model.geometry, topHeight: topHeight, choices: choices)
        var summary = summaryFromGeometry(result.geometry, source: model)
        summary.preflight = OpeningCapper.topologyReport(result.geometry)
        result.remainingOpenEdges = summary.preflight.boundaryEdgeCount
        result.remainingNonManifoldEdges = summary.preflight.nonManifoldEdgeCount
        return (summary, result)
    }

    /// Make walls: thicken an open skin INWARD by `thickness` mm into a walled
    /// vessel. The outside surface stays exact and every opening stays open
    /// (see `WallMaker`). Throws `WallMaker.WallError` (with `userMessage`)
    /// when it cannot.
    static func makeWalls(_ model: MeshSummary, thickness: Double,
                          choices: [OpeningCapper.OpeningChoice] = []) throws -> (summary: MeshSummary, receipt: String) {
        let (summary, result) = try makeWallsDetailed(model, thickness: thickness, choices: choices)
        return (summary, result.receipt)
    }

    /// `makeWalls` plus the full measurement record (headless/tests).
    static func makeWallsDetailed(_ model: MeshSummary, thickness: Double,
                                  choices: [OpeningCapper.OpeningChoice] = []) throws -> (summary: MeshSummary, result: WallMaker.Result) {
        let result = try WallMaker.make(model.geometry, thickness: thickness, choices: choices)
        var summary = summaryFromGeometry(result.geometry, source: model)
        summary.preflight = OpeningCapper.topologyReport(result.geometry)
        return (summary, result)
    }

    /// Build a MeshSummary for the output of MeshHealer/Make-Watertight, where the
    /// geometry was extracted from a Manifold handle that Manifold validated as a
    /// closed 2-manifold solid by its own index topology.
    ///
    /// We run the normal position-weld MeshPreflight so the reported counts stay
    /// HONEST (an exported STL would show the same self-contact edges), then set
    /// `manifoldValidated` from Manifold's verdict. That flag means the watertight
    /// verdict reads "closed, usable solid" — residual non-manifold edges from
    /// surface self-contact (e.g. webbing between fingers) no longer fail it, but
    /// genuine holes (boundaryEdgeCount > 0) still do. Non-healed callers use
    /// summaryFromGeometry (manifoldValidated defaults false → strict verdict), so
    /// this relaxed verdict is scoped to the Make-Watertight path only.
    private static func summaryFromHealedGeometry(
        _ geo: MeshGeometryData,
        manifoldWatertight: Bool,
        source: MeshSummary
    ) -> MeshSummary {
        var summary = summaryFromGeometry(geo, source: source)
        summary.preflight.manifoldValidated = manifoldWatertight
        return summary
    }
}
