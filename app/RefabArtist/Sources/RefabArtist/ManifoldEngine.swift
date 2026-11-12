import CManifold
import Foundation

/// Errors surfaced by the Manifold geometry backend. Maps the `ManifoldError`
/// C enum (`manifold_status`) plus a few bridge-side preconditions to typed
/// Swift errors with user-facing messages.
enum ManifoldEngineError: Error, Equatable {
    case nonFiniteVertex
    case notManifold
    case vertexIndexOutOfBounds
    case propertiesWrongLength
    case invalidConstruction
    case resultTooLarge
    case emptyResult
    case unknown(Int32)

    /// Map a non-zero `manifold_status` value to a typed error.
    static func from(status: ManifoldError) -> ManifoldEngineError {
        switch status {
        case MANIFOLD_NON_FINITE_VERTEX: return .nonFiniteVertex
        case MANIFOLD_NOT_MANIFOLD: return .notManifold
        case MANIFOLD_VERTEX_INDEX_OUT_OF_BOUNDS: return .vertexIndexOutOfBounds
        case MANIFOLD_PROPERTIES_WRONG_LENGTH: return .propertiesWrongLength
        case MANIFOLD_INVALID_CONSTRUCTION: return .invalidConstruction
        case MANIFOLD_RESULT_TOO_LARGE: return .resultTooLarge
        default: return .unknown(Int32(status.rawValue))
        }
    }

    var userMessage: String {
        switch self {
        case .nonFiniteVertex:
            return "The mesh contains non-finite (NaN/Inf) vertex coordinates."
        case .notManifold:
            return "The mesh has open holes we could not treat as a watertight solid."
        case .vertexIndexOutOfBounds:
            return "A triangle references a vertex index outside the vertex array."
        case .propertiesWrongLength:
            return "Vertex property data length does not match the declared stride."
        case .invalidConstruction:
            return "Manifold could not construct a valid solid from the input."
        case .resultTooLarge:
            return "The boolean result exceeded Manifold's size limits."
        case .emptyResult:
            return "The operation produced an empty mesh."
        case .unknown(let code):
            return "Manifold reported an unexpected error (status \(code))."
        }
    }
}

/// RAII owner of a single `ManifoldManifold*`. The C API places the constructed
/// object inside a caller-provided `mem` arena sized by `manifold_manifold_size()`;
/// we own that raw buffer and free both the object and the buffer on `deinit`.
///
/// `@unchecked Sendable`: the underlying pointer must never cross an isolation
/// boundary concurrently. A single owning `Task` is expected to drive a handle
/// from creation to teardown (see plan §1e). This conformance only lets the
/// handle be captured by that one task.
final class ManifoldHandle: @unchecked Sendable {
    /// Arena holding the ManifoldManifold object (also the `ManifoldManifold*`).
    private let mem: UnsafeMutableRawPointer
    /// Typed view of the same arena; valid for the handle's lifetime.
    let manifold: OpaquePointer

    init(adopting mem: UnsafeMutableRawPointer, manifold: OpaquePointer) {
        self.mem = mem
        self.manifold = manifold
    }

    deinit {
        // The object was placement-new'd into our own `mem` arena (e.g. by
        // manifold_cube / manifold_intersection). Destruct in place — call the
        // C++ destructor only — then free the arena WE allocated. Using
        // manifold_delete_manifold here would `delete` (free) our arena pointer,
        // which malloc did not vend, and abort with a double/bad free.
        manifold_destruct_manifold(manifold)
        mem.deallocate()
    }
}

/// Lightweight value describing an axis-aligned box for `ManifoldEngine.box`.
struct ManifoldBoxSpec: Equatable {
    var center: Vec3
    var extents: Vec3   // full edge lengths along x/y/z
}

/// Minimal Swift wrapper over the vendored `manifoldc` plain-C API. Handles all
/// arena allocation, the Double<->Float MeshGL marshalling, and status checks.
enum ManifoldEngine {
    private static let manifoldArenaSize = manifold_manifold_size()
    private static let manifoldVecArenaSize = manifold_manifold_vec_size()
    private static let meshGLArenaSize = manifold_meshgl_size()
    private static let meshGL64ArenaSize = manifold_meshgl64_size()
    private static let polygonsArenaSize = manifold_polygons_size()

    /// Allocate an aligned arena for one ManifoldManifold object.
    private static func allocManifoldArena() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: manifoldArenaSize, alignment: 16)
    }

    /// Allocate an aligned arena for one ManifoldManifoldVec object.
    private static func allocManifoldVecArena() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: manifoldVecArenaSize, alignment: 16)
    }

    /// Allocate an aligned arena for one ManifoldPolygons object.
    private static func allocPolygonsArena() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: polygonsArenaSize, alignment: 16)
    }

    /// Canonicalize slice loops by dropping duplicate and collinear boundary points
    /// emitted from triangulated faces, preserving only geometric corners.
    private static func canonicalizeSlicePolygon(_ polygon: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard polygon.count > 2 else { return polygon }
        let epsilon = 1e-9

        func isNear(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            abs(a.x - b.x) <= epsilon && abs(a.y - b.y) <= epsilon
        }

        var cleaned: [SIMD2<Double>] = []
        cleaned.reserveCapacity(polygon.count)
        for point in polygon {
            if let last = cleaned.last, isNear(last, point) { continue }
            cleaned.append(point)
        }
        if cleaned.count > 1, let first = cleaned.first, let last = cleaned.last, isNear(first, last) {
            cleaned.removeLast()
        }

        guard cleaned.count > 2 else { return cleaned }

        var changed = true
        while changed && cleaned.count > 2 {
            changed = false
            var index = 0
            while index < cleaned.count {
                let prev = cleaned[(index - 1 + cleaned.count) % cleaned.count]
                let current = cleaned[index]
                let next = cleaned[(index + 1) % cleaned.count]

                let ax = current.x - prev.x
                let ay = current.y - prev.y
                let bx = next.x - current.x
                let by = next.y - current.y
                let cross = ax * by - ay * bx
                if abs(cross) <= epsilon {
                    cleaned.remove(at: index)
                    changed = true
                    if cleaned.count <= 2 { break }
                    continue
                }
                index += 1
            }
        }

        return cleaned
    }

    /// Wrap a freshly-constructed `ManifoldManifold*` (which lives inside `mem`),
    /// checking its status and adopting ownership. On a non-OK status the arena
    /// is freed and the mapped error is thrown. `ManifoldManifold` is an opaque
    /// C struct, so the C API imports its pointer as `OpaquePointer?`.
    private static func adopt(
        _ raw: OpaquePointer?,
        mem: UnsafeMutableRawPointer
    ) throws -> ManifoldHandle {
        guard let raw else {
            mem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        let status = manifold_status(raw)
        if status != MANIFOLD_NO_ERROR {
            // The object is constructed-but-errored; destruct in place (it lives
            // in our arena) then free the arena and surface the error.
            manifold_destruct_manifold(raw)
            mem.deallocate()
            throw ManifoldEngineError.from(status: status)
        }
        return ManifoldHandle(adopting: mem, manifold: raw)
    }

    // MARK: Construction

    /// Build a watertight box manifold from a center + full extents.
    static func box(_ spec: ManifoldBoxSpec) throws -> ManifoldHandle {
        // manifold_cube builds an axis-aligned box of the given dimensions; with
        // `center=1` it is centered on the origin, so we translate to `center`.
        let cubeMem = allocManifoldArena()
        let cube = manifold_cube(
            cubeMem,
            spec.extents.x, spec.extents.y, spec.extents.z,
            1
        )
        let cubeHandle = try adopt(cube, mem: cubeMem)

        // Translate is a fresh manifold in its own arena.
        let outMem = allocManifoldArena()
        let moved = manifold_translate(
            outMem,
            cubeHandle.manifold,
            spec.center.x, spec.center.y, spec.center.z
        )
        // cubeHandle is no longer needed once translate has produced the copy.
        let result = try adopt(moved, mem: outMem)
        withExtendedLifetime(cubeHandle) {}
        return result
    }

    /// Build a manifold from app mesh geometry. Double vertices are down-cast to
    /// float32 and Int32 indices widened to UInt32 to match MeshGL's layout.
    static func make(from geometry: MeshGeometryData) throws -> ManifoldHandle {
        let vertexCount = geometry.vertices.count
        let triCount = geometry.triangleIndices.count / 3
        precondition(
            geometry.triangleIndices.count % 3 == 0,
            "triangleIndices length must be a multiple of 3"
        )

        var props = [Float]()
        props.reserveCapacity(vertexCount * 3)
        for v in geometry.vertices {
            props.append(Float(v.x))
            props.append(Float(v.y))
            props.append(Float(v.z))
        }
        var tris = geometry.triangleIndices.map { UInt32(bitPattern: $0) }

        // Build a MeshGL, convert to a Manifold, then free the MeshGL arena.
        let meshMem = UnsafeMutableRawPointer.allocate(
            byteCount: meshGLArenaSize, alignment: 16
        )
        let mesh: OpaquePointer? = props.withUnsafeMutableBufferPointer { vp in
            tris.withUnsafeMutableBufferPointer { tp in
                manifold_meshgl(
                    meshMem,
                    vp.baseAddress, vertexCount, 3,
                    tp.baseAddress, triCount
                )
            }
        }
        guard let mesh else {
            meshMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }

        // Weld coincident vertices before constructing the manifold.
        //
        // `manifold_of_meshgl` performs a STRICT 2-manifold check that pairs
        // half-edges by vertex index. A tessellated watertight surface emitted
        // from float coordinates (e.g. a UV sphere, or any mesh round-tripped
        // through `toMesh`) can have multiple coincident-but-distinct vertices
        // at shared seams/poles, which leaves boundary half-edges unpaired and
        // makes the construct fail with `notManifold` even though the surface
        // is closed. `manifold_meshgl_merge` computes the merge vectors that
        // weld those coincident vertices, recovering a valid 2-manifold. This
        // is the Manifold-recommended import step for externally authored
        // meshes and changes no geometry (it only fuses coincident points).
        //
        // On a clean already-indexed mesh (cube, L-prism) the merge is a no-op,
        // so this is safe for every caller. If merge returns null we fall back
        // to constructing directly from the un-merged MeshGL.
        let mergeMem = UnsafeMutableRawPointer.allocate(
            byteCount: meshGLArenaSize, alignment: 16
        )
        let merged = manifold_meshgl_merge(mergeMem, mesh)

        let outMem = allocManifoldArena()
        let m: OpaquePointer?
        if let merged {
            m = manifold_of_meshgl(outMem, merged)
            manifold_destruct_meshgl(merged)
        } else {
            m = manifold_of_meshgl(outMem, mesh)
        }
        mergeMem.deallocate()
        // mesh was placement-new'd into meshMem: destruct in place, free arena.
        manifold_destruct_meshgl(mesh)
        meshMem.deallocate()
        return try adopt(m, mem: outMem)
    }

    /// Build a manifold from app mesh geometry through the 64-bit MeshGL path:
    /// vertices stay DOUBLE, so every triangle Manifold does not cut comes
    /// back from `toMesh` with bit-identical corner positions (`make(from:)`
    /// downcasts to float32 and changes every vertex). Coincident vertices are
    /// merged exactly as in `make(from:)`.
    static func make64(from geometry: MeshGeometryData) throws -> ManifoldHandle {
        let vertexCount = geometry.vertices.count
        let triCount = geometry.triangleIndices.count / 3
        guard geometry.triangleIndices.count % 3 == 0 else { throw ManifoldEngineError.invalidConstruction }
        var props = [Double]()
        props.reserveCapacity(vertexCount * 3)
        for v in geometry.vertices {
            props.append(v.x); props.append(v.y); props.append(v.z)
        }
        var tris = [UInt64]()
        tris.reserveCapacity(geometry.triangleIndices.count)
        for i in geometry.triangleIndices {
            guard i >= 0, Int(i) < vertexCount else { throw ManifoldEngineError.vertexIndexOutOfBounds }
            tris.append(UInt64(i))
        }
        let meshMem = UnsafeMutableRawPointer.allocate(byteCount: meshGL64ArenaSize, alignment: 16)
        let mesh: OpaquePointer? = props.withUnsafeMutableBufferPointer { vp in
            tris.withUnsafeMutableBufferPointer { tp in
                manifold_meshgl64(meshMem, vp.baseAddress, vertexCount, 3, tp.baseAddress, triCount)
            }
        }
        guard let mesh else {
            meshMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        let mergeMem = UnsafeMutableRawPointer.allocate(byteCount: meshGL64ArenaSize, alignment: 16)
        let merged = manifold_meshgl64_merge(mergeMem, mesh)
        let outMem = allocManifoldArena()
        let m: OpaquePointer?
        if let merged {
            m = manifold_of_meshgl64(outMem, merged)
            manifold_destruct_meshgl64(merged)
        } else {
            m = manifold_of_meshgl64(outMem, mesh)
        }
        mergeMem.deallocate()
        manifold_destruct_meshgl64(mesh)
        meshMem.deallocate()
        return try adopt(m, mem: outMem)
    }

    /// Put disjoint solids into one manifold WITHOUT a boolean (Manifold's
    /// `compose`: no geometry is touched). Callers must pass non-overlapping
    /// parts (e.g. components from `decompose`).
    static func compose(_ handles: [ManifoldHandle]) throws -> ManifoldHandle {
        guard let first = handles.first else { throw ManifoldEngineError.emptyResult }
        if handles.count == 1 { return first }
        let vecMem = allocManifoldVecArena()
        guard let vec = manifold_manifold_vec(vecMem, handles.count) else {
            vecMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        defer {
            manifold_destruct_manifold_vec(vec)
            vecMem.deallocate()
        }
        for (i, h) in handles.enumerated() { manifold_manifold_vec_set(vec, i, h.manifold) }
        let mem = allocManifoldArena()
        let r = manifold_compose(mem, vec)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(handles) {}
        return result
    }

    // MARK: Level set (isosurface)

    /// Box of `[lo, hi]` the level-set is evaluated over, in world units.
    struct LevelSetBounds: Equatable {
        var lo: Vec3
        var hi: Vec3
    }

    /// Context object boxed behind a `void*` and handed to the C trampoline.
    /// Holds the Swift SDF closure for the duration of one `manifold_level_set`
    /// call. We pass an `Unmanaged` pointer to it as the C `ctx` and reconstruct
    /// the closure inside the @convention(c) trampoline below.
    private final class SdfContext {
        let sdf: (Double, Double, Double) -> Double
        init(_ sdf: @escaping (Double, Double, Double) -> Double) { self.sdf = sdf }
    }

    /// Extract an isosurface from a scalar field via Manifold's `level_set`.
    ///
    /// `sdf(x,y,z)` is a *signed* field: the surface is the `level` isocontour
    /// (default 0). Manifold's convention is that the solid is where the field is
    /// **positive** (> level). For a true signed-distance field where inside is
    /// negative (standard SDF), pass the NEGATED distance, or set `level` so the
    /// positive region is the interior. The healer below uses
    /// `gwnSign * -distance` so the interior reads positive.
    ///
    /// `edgeLength` is the target mesh edge / voxel pitch — smaller = finer
    /// surface but O(1/edge^3) field evaluations. `bounds` must enclose the whole
    /// surface; level_set only samples inside it.
    ///
    /// The closure is invoked synchronously by Manifold while sampling the grid.
    /// When `parallel` is true Manifold may call it from multiple worker threads
    /// at once, so the closure MUST be thread-safe (read-only captured state, no
    /// shared mutation). The healer's SDF only reads immutable BVH/grid structures,
    /// so it opts into the parallel entry point; the default stays sequential.
    static func levelSet(
        bounds: LevelSetBounds,
        edgeLength: Double,
        level: Double = 0.0,
        tolerance: Double = -1.0,
        parallel: Bool = false,
        _ sdf: @escaping (Double, Double, Double) -> Double
    ) throws -> ManifoldHandle {
        // Box arena for the bounds argument.
        let boxMem = UnsafeMutableRawPointer.allocate(
            byteCount: manifold_box_size(), alignment: 16
        )
        let box = manifold_box(
            boxMem,
            bounds.lo.x, bounds.lo.y, bounds.lo.z,
            bounds.hi.x, bounds.hi.y, bounds.hi.z
        )
        defer {
            manifold_destruct_box(box)
            boxMem.deallocate()
        }

        let context = SdfContext(sdf)
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()

        // @convention(c) trampoline: reconstruct the SdfContext from ctx and call
        // the Swift closure. Must be a non-capturing C function pointer.
        let trampoline: @convention(c) (Double, Double, Double, UnsafeMutableRawPointer?) -> Double = {
            x, y, z, ctx in
            guard let ctx else { return 0 }
            let context = Unmanaged<SdfContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.sdf(x, y, z)
        }

        let outMem = allocManifoldArena()
        let m = parallel
            ? manifold_level_set(
                outMem, trampoline, box, edgeLength, level, tolerance, ctxPtr)
            : manifold_level_set_seq(
                outMem, trampoline, box, edgeLength, level, tolerance, ctxPtr)
        let result = try adopt(m, mem: outMem)
        // Keep the context alive until level_set has finished sampling.
        withExtendedLifetime(context) {}
        return result
    }

    // MARK: Transforms

    /// Rotate a manifold about the origin. Angles are Euler degrees per axis,
    /// matching Manifold's `manifold_rotate` convention. Returns a fresh handle.
    static func rotate(_ h: ManifoldHandle, degreesX: Double, degreesY: Double, degreesZ: Double) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_rotate(mem, h.manifold, degreesX, degreesY, degreesZ)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(h) {}
        return result
    }

    /// Translate a manifold by (x, y, z). Returns a fresh handle.
    static func translate(_ h: ManifoldHandle, x: Double, y: Double, z: Double) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_translate(mem, h.manifold, x, y, z)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(h) {}
        return result
    }

    // MARK: Booleans

    static func intersect(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_intersection(mem, a.manifold, b.manifold)
        return try adopt(r, mem: mem)
    }

    static func union(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_union(mem, a.manifold, b.manifold)
        return try adopt(r, mem: mem)
    }

    /// Subtract `b` from `a` (`a - b`). The right tool for clean cylindrical
    /// bores (spout/vent channels) and flange bolt holes. Returns a fresh handle;
    /// inputs are kept alive across the C call.
    static func difference(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_difference(mem, a.manifold, b.manifold)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(a) {}
        withExtendedLifetime(b) {}
        return result
    }

    /// Minkowski sum of `a` with `b`. Used for the silicone-jacket smooth outward
    /// offset (sum the decimated master with a small sphere) — NOT marching cubes.
    /// Expensive on dense meshes; decimate `a` first. Returns a fresh handle.
    static func minkowskiSum(_ a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_minkowski_sum(mem, a.manifold, b.manifold)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(a) {}
        withExtendedLifetime(b) {}
        return result
    }

    /// Collapse sub-tolerance features via Manifold's edge-collapse simplify.
    /// A plane split through a dense curved shell can leave sub-micron sliver
    /// triangles at the cut (and at the cut-cut corner of a 4-part mold) that are
    /// geometrically negligible but trip MeshPreflight's degenerate-triangle
    /// check. Simplifying each piece collapses them while staying a valid
    /// 2-manifold; pass a tolerance well below printable resolution so the mold
    /// shape is unchanged. Returns a fresh handle.
    static func simplify(_ h: ManifoldHandle, tolerance: Double) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_simplify(mem, h.manifold, tolerance)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(h) {}
        return result
    }

    /// Geodesic sphere of `radius` (Manifold's closed-form tessellation — NOT a
    /// level set / NOT marching cubes). Used as the Minkowski summand for robust
    /// outward offsets (silicone cavity, shell wall).
    static func sphere(radius: Double, segments: Int32 = 24) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_sphere(mem, radius, segments)
        return try adopt(r, mem: mem)
    }

    // MARK: Hull / decompose / slice

    /// Convex hull of a solid's vertices, built by Manifold's exact hull op.
    static func convexHull(_ solid: ManifoldHandle) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_hull(mem, solid.manifold)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(solid) {}
        return result
    }

    /// Convex hull of raw 3D points, packed directly into the C API's Vec3 layout.
    static func convexHull(of points: [Vec3]) throws -> ManifoldHandle {
        let hullPoints = points.map { ManifoldVec3(x: $0.x, y: $0.y, z: $0.z) }
        let mem = allocManifoldArena()
        let r: OpaquePointer? = hullPoints.withUnsafeBufferPointer { buffer in
            return manifold_hull_pts(mem, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count)
        }
        return try adopt(r, mem: mem)
    }

    /// Convex hull joining two solids. Used as the capsule primitive for branch edges.
    static func convexHull(joining a: ManifoldHandle, _ b: ManifoldHandle) throws -> ManifoldHandle {
        let vecMem = allocManifoldVecArena()
        guard let solids = manifold_manifold_vec(vecMem, 2) else {
            vecMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        defer {
            manifold_destruct_manifold_vec(solids)
            vecMem.deallocate()
        }
        manifold_manifold_vec_set(solids, 0, a.manifold)
        manifold_manifold_vec_set(solids, 1, b.manifold)

        let mem = allocManifoldArena()
        let r = manifold_batch_hull(mem, solids)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(a) {}
        withExtendedLifetime(b) {}
        return result
    }

    /// Split a manifold into connected components.
    static func decompose(_ solid: ManifoldHandle) throws -> [ManifoldHandle] {
        let vecMem = allocManifoldVecArena()
        guard let components = manifold_decompose(vecMem, solid.manifold) else {
            vecMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        defer {
            manifold_destruct_manifold_vec(components)
            vecMem.deallocate()
        }

        let count = Int(manifold_manifold_vec_length(components))
        var result: [ManifoldHandle] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let componentMem = allocManifoldArena()
            let raw = manifold_manifold_vec_get(componentMem, components, index)
            result.append(try adopt(raw, mem: componentMem))
        }
        withExtendedLifetime(solid) {}
        return result
    }

    /// Slice the solid at a world-space Z and return closed XY polygons.
    static func slice(_ solid: ManifoldHandle, atZ z: Double) throws -> [[SIMD2<Double>]] {
        let polygonsMem = allocPolygonsArena()
        guard let polygons = manifold_slice(polygonsMem, solid.manifold, z) else {
            polygonsMem.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        defer {
            manifold_destruct_polygons(polygons)
            polygonsMem.deallocate()
        }

        let polygonCount = Int(manifold_polygons_length(polygons))
        var result: [[SIMD2<Double>]] = []
        result.reserveCapacity(polygonCount)
        for polygonIndex in 0..<polygonCount {
            let pointCount = Int(manifold_polygons_simple_length(polygons, polygonIndex))
            var polygon: [SIMD2<Double>] = []
            polygon.reserveCapacity(pointCount)
            for pointIndex in 0..<pointCount {
                let p = manifold_polygons_get_point(polygons, polygonIndex, pointIndex)
                polygon.append(SIMD2<Double>(p.x, p.y))
            }
            result.append(canonicalizeSlicePolygon(polygon))
        }
        withExtendedLifetime(solid) {}
        return result
    }

    // MARK: Half-space clip / split

    /// Keep the half-space side of the plane `dot(p, normal) >= offset`.
    /// Manifold's `trim_by_plane` removes everything on the negative side of
    /// the plane, keeping the side the normal points toward.
    /// Use for trimming the shell against the open/pour plane. Returns a fresh
    /// handle (which may be empty if the plane removes everything).
    static func trimByPlane(_ h: ManifoldHandle, normal: Vec3, offset: Double) throws -> ManifoldHandle {
        let mem = allocManifoldArena()
        let r = manifold_trim_by_plane(mem, h.manifold, normal.x, normal.y, normal.z, offset)
        let result = try adopt(r, mem: mem)
        withExtendedLifetime(h) {}
        return result
    }

    /// Split a solid by a plane into two pieces. The first element is the
    /// positive half-space `dot(p, normal) >= offset`; the second is the
    /// negative half-space `dot(p, normal) <= offset`. Either piece may be
    /// empty. Wraps the C `ManifoldManifoldPair` returned by
    /// `manifold_split_by_plane`.
    static func splitByPlane(_ h: ManifoldHandle, normal: Vec3, offset: Double) throws -> (ManifoldHandle, ManifoldHandle) {
        let firstMem = allocManifoldArena()
        let secondMem = allocManifoldArena()
        let pair = manifold_split_by_plane(
            firstMem, secondMem, h.manifold,
            normal.x, normal.y, normal.z, offset
        )
        // `pair.first` / `pair.second` are `ManifoldManifold*`, imported as
        // `OpaquePointer?`, each placement-new'd into the arena we passed.
        let first = try adopt(pair.first, mem: firstMem)
        // adopt frees its own arena on throw, so if the second adopt fails the
        // first piece still owns firstMem; nothing else to release here.
        do {
            let second = try adopt(pair.second, mem: secondMem)
            withExtendedLifetime(h) {}
            return (first, second)
        } catch {
            withExtendedLifetime(first) {}
            throw error
        }
    }

    /// Tree-reduce union — avoids the O(n) deep-CSG cost of sequential folding.
    /// (manifold_batch_boolean segfaulted on large/complex slab sets, so we fold.)
    static func union(_ handles: [ManifoldHandle]) throws -> ManifoldHandle {
        precondition(!handles.isEmpty, "union requires at least one handle")
        var level = handles
        while level.count > 1 {
            var next: [ManifoldHandle] = []
            next.reserveCapacity((level.count + 1) / 2)
            var i = 0
            while i < level.count {
                if i + 1 < level.count {
                    next.append(try union(level[i], level[i + 1]))
                    i += 2
                } else {
                    next.append(level[i])
                    i += 1
                }
            }
            level = next
        }
        return level[0]
    }

    // MARK: Queries

    /// Signed volume of the solid (negative if inverted; non-zero implies content).
    static func volume(_ h: ManifoldHandle) -> Double {
        manifold_volume(h.manifold)
    }

    static func isEmpty(_ h: ManifoldHandle) -> Bool {
        manifold_is_empty(h.manifold) != 0
    }

    static func triangleCount(_ h: ManifoldHandle) -> Int {
        Int(manifold_num_tri(h.manifold))
    }

    /// Topological genus of the solid (number of handles). A through-channel
    /// drilled from a cavity to the exterior adds a handle, raising the genus —
    /// used to verify the spout/vent actually pierce the shell.
    static func genus(_ h: ManifoldHandle) -> Int {
        Int(manifold_genus(h.manifold))
    }

    static func vertexCount(_ h: ManifoldHandle) -> Int {
        Int(manifold_num_vert(h.manifold))
    }

    /// Axis-aligned bounding box of the solid, read back from Manifold.
    static func bounds(_ h: ManifoldHandle) -> Bounds3D {
        let boxMem = UnsafeMutableRawPointer.allocate(
            byteCount: manifold_box_size(), alignment: 16
        )
        let box = manifold_bounding_box(boxMem, h.manifold)
        defer {
            manifold_destruct_box(box)
            boxMem.deallocate()
        }
        let lo = manifold_box_min(box)
        let hi = manifold_box_max(box)
        return Bounds3D(
            min: Vec3(x: lo.x, y: lo.y, z: lo.z),
            max: Vec3(x: hi.x, y: hi.y, z: hi.z)
        )
    }

    /// A non-empty Manifold solid is, by construction, watertight: Manifold only
    /// ever holds 2-manifold (closed, orientable) geometry, so a non-empty,
    /// error-free handle is watertight. We expose this as an explicit query so
    /// callers can gate on it without reaching into the C API.
    static func isWatertight(_ h: ManifoldHandle) -> Bool {
        manifold_status(h.manifold) == MANIFOLD_NO_ERROR && !isEmpty(h)
    }

    // MARK: Mesh readback

    /// Extract the result mesh as app geometry. Float32 props are widened back to
    /// Double and UInt32 indices narrowed to Int32.
    static func toMesh(_ h: ManifoldHandle) throws -> MeshGeometryData {
        // Read back in DOUBLE precision (meshgl64). Manifold computes in double;
        // the 32-bit MeshGL export downcasts to float, which can merge near-
        // coincident cut vertices into sub-micron sliver triangles. On a curved
        // shell split by two planes (a 4-part mold) those slivers trip
        // MeshPreflight's degenerate-triangle check and wrongly fail an
        // otherwise-watertight part. Double readback avoids the lossy downcast.
        let meshMem = UnsafeMutableRawPointer.allocate(
            byteCount: meshGL64ArenaSize, alignment: 16
        )
        guard let mesh = manifold_get_meshgl64(meshMem, h.manifold) else {
            meshMem.deallocate()
            throw ManifoldEngineError.emptyResult
        }
        defer {
            // mesh lives in our meshMem arena: destruct in place, free arena.
            manifold_destruct_meshgl64(mesh)
            meshMem.deallocate()
        }

        let nProps = manifold_meshgl64_num_prop(mesh)
        let nVerts = manifold_meshgl64_num_vert(mesh)
        let nTris = manifold_meshgl64_num_tri(mesh)
        let propsLen = manifold_meshgl64_vert_properties_length(mesh)
        let triLen = manifold_meshgl64_tri_length(mesh)

        // Read vertex properties (stride = nProps, first 3 are x/y/z).
        var vertices = [Vec3]()
        vertices.reserveCapacity(Int(nVerts))
        if propsLen > 0 {
            let buf = UnsafeMutableRawPointer.allocate(
                byteCount: Int(propsLen) * MemoryLayout<Double>.stride, alignment: 16
            )
            defer { buf.deallocate() }
            let typed = buf.bindMemory(to: Double.self, capacity: Int(propsLen))
            _ = manifold_meshgl64_vert_properties(buf, mesh)
            let stride = Int(nProps)
            var i = 0
            while i + 2 < Int(propsLen) {
                vertices.append(Vec3(
                    x: typed[i],
                    y: typed[i + 1],
                    z: typed[i + 2]
                ))
                i += stride
            }
        }

        // Read triangle indices (64-bit; truncated to Int32 — part meshes are far
        // below 2^31 vertices).
        var indices = [Int32]()
        indices.reserveCapacity(Int(triLen))
        if triLen > 0 {
            let buf = UnsafeMutableRawPointer.allocate(
                byteCount: Int(triLen) * MemoryLayout<UInt64>.stride, alignment: 16
            )
            defer { buf.deallocate() }
            let typed = buf.bindMemory(to: UInt64.self, capacity: Int(triLen))
            _ = manifold_meshgl64_tri_verts(buf, mesh)
            for k in 0..<Int(triLen) {
                indices.append(Int32(truncatingIfNeeded: typed[k]))
            }
        }

        precondition(indices.count == Int(nTris) * 3,
                     "tri index count mismatch (\(indices.count) vs \(Int(nTris) * 3))")
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }
}
