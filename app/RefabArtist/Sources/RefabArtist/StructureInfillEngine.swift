import AppKit
import Foundation

/// The result of planning a Structures generation: the chosen settings plus the
/// generated geometry as one or more export layers. `bounds` is COMPUTED from the
/// layer vertices, so the "result fits inside the source" invariant
/// (`bounds ⊆ source`) is checkable directly from the plan.
///
/// Shape is intentionally minimal and shared with the RealityKit viewport and the
/// STL/OBJ exporters — they consume `layers` unchanged.
struct StructureMeshPlan: Equatable {
    var settings: StructureSettings
    var layers: [SliceMeshExportLayer]
    var coarseningNotice: String?
    var preClipDroppedCount: Int
    var preClipDroppedVolume: Double
    var postClipDroppedCount: Int
    var postClipDroppedVolume: Double
    var supportAudit: SupportAudit?
    var skinAudit: SkinAudit?

    init(
        settings: StructureSettings,
        layers: [SliceMeshExportLayer],
        coarseningNotice: String? = nil,
        preClipDroppedCount: Int = 0,
        preClipDroppedVolume: Double = 0,
        postClipDroppedCount: Int = 0,
        postClipDroppedVolume: Double = 0,
        supportAudit: SupportAudit? = nil,
        skinAudit: SkinAudit? = nil
    ) {
        self.settings = settings
        self.layers = layers
        self.coarseningNotice = coarseningNotice
        self.preClipDroppedCount = preClipDroppedCount
        self.preClipDroppedVolume = preClipDroppedVolume
        self.postClipDroppedCount = postClipDroppedCount
        self.postClipDroppedVolume = postClipDroppedVolume
        self.supportAudit = supportAudit
        self.skinAudit = skinAudit
    }

    /// Total triangle count across all layers.
    var triangleCount: Int {
        layers.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 }
    }

    /// Axis-aligned bounds of all layer vertices, or nil when there is no
    /// geometry yet (e.g. the engine is not implemented for this sub-category).
    var bounds: Bounds3D? {
        var lo: Vec3?
        var hi: Vec3?
        for layer in layers {
            for v in layer.mesh.vertices {
                if let l = lo, let h = hi {
                    lo = Vec3(x: Swift.min(l.x, v.x), y: Swift.min(l.y, v.y), z: Swift.min(l.z, v.z))
                    hi = Vec3(x: Swift.max(h.x, v.x), y: Swift.max(h.y, v.y), z: Swift.max(h.z, v.z))
                } else {
                    lo = v
                    hi = v
                }
            }
        }
        guard let lo, let hi else { return nil }
        return Bounds3D(min: lo, max: hi)
    }
}

/// Pluggable wall-solid generator seam. Each infill pattern provides ONE
/// generator that emits a full-height wall solid for the model's bounds; the
/// shared clip backend (`StructureClipEngine`) then booleans it against the
/// healed source. Adding a pattern later = one generator + one `InfillPattern`
/// case + one UI row, with zero changes to the clip backend.
/// Reference-typed sink so value-typed generators can surface user-visible
/// coarsening/resolvability notices to the plan (never silent, per R12).
final class WallSolidNoticeCollector {
    private(set) var items: [String] = []
    func add(_ notice: String) { items.append(notice) }
    var combined: String? { items.isEmpty ? nil : items.joined(separator: " ") }
}

struct WallSolidContext {
    let bounds: Bounds3D
    let params: InfillParameters
    let engine: ManifoldEngine.Type
    let density: DensityField
    let sourceVertices: [Vec3]
    let notices = WallSolidNoticeCollector()
}

protocol WallSolidGenerator {
    func makeWallSolid(
        bounds: Bounds3D,
        params: InfillParameters,
        engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle

    /// MC-sampled wall solids can carry boundary-seal debris even when the source
    /// is watertight; those generators opt in to the pre-clip speck filter.
    var wallSolidMayCarrySpecks: Bool { get }
}

extension WallSolidGenerator {
    var wallSolidMayCarrySpecks: Bool { false }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        try makeWallSolid(
            bounds: context.bounds,
            params: context.params,
            engine: context.engine
        )
    }

    func uniformContext(
        bounds: Bounds3D,
        params: InfillParameters,
        engine: ManifoldEngine.Type
    ) -> WallSolidContext {
        WallSolidContext(
            bounds: bounds,
            params: params,
            engine: engine,
            density: .uniform(cellSizeMm: params.cellSizeMm),
            sourceVertices: []
        )
    }
}

/// Triangle infill: three families of parallel, full-height vertical walls at
/// 0°, 60°, and 120°. Each family is a set of long thin boxes (long along the
/// family direction, thin = wall thickness across it, tall = full model height +
/// margin), spaced `cellSizeMm` apart across the bounds. All boxes are unioned
/// into one wall solid; the shared clip backend then intersects it with the
/// source so the lattice is cut exactly to the model skin.
///
/// Mirrors the proven Python POC (`infill_poc.py`): build axis-aligned boxes
/// centered on the origin, rotate each about Z to the family angle, translate to
/// the line offset, union, then INTERSECT with the source.
struct TriangleWallSolidGenerator: WallSolidGenerator {
    /// The three wall directions that form triangular cells.
    static let familyAnglesDegrees: [Double] = [0.0, 60.0, 120.0]

    func makeWallSolid(
        bounds: Bounds3D,
        params: InfillParameters,
        engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let engine = context.engine
        let lo = bounds.min
        let hi = bounds.max
        let center = Vec3(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)

        let dx = hi.x - lo.x
        let dy = hi.y - lo.y
        let dz = hi.z - lo.z
        let diag = (dx * dx + dy * dy + dz * dz).squareRoot()

        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.001)

        // Full height + margin so walls run cleanly past the top/bottom skin and
        // the clip closes them with the model's own surface.
        let zLen = dz + 4.0
        // Long enough to span the body in any in-plane direction.
        let length = diag * 1.4 + cell

        // Number of parallel lines each side of center to cover the bbox.
        let nLines = Int((diag / cell).rounded(.up)) + 3

        var boxes: [ManifoldHandle] = []
        boxes.reserveCapacity(Self.familyAnglesDegrees.count * (2 * nLines + 1))

        for angleDeg in Self.familyAnglesDegrees {
            if !context.density.isUniform {
                boxes.append(contentsOf: try PlanarWallBuilder.densityParallelFamily(
                    angleDeg: angleDeg,
                    spacing: cell,
                    phase: 0,
                    thickness: wall,
                    frame: PlanarWallBuilder.frame(bounds),
                    density: context.density,
                    engine: engine
                ))
                continue
            }
            let theta = angleDeg * .pi / 180.0
            // Offset direction perpendicular to the wall run, in the XY plane.
            let perpX = -sin(theta)
            let perpY = cos(theta)

            for k in -nLines...nLines {
                let d = Double(k) * cell
                let posX = center.x + perpX * d
                let posY = center.y + perpY * d

                // Axis-aligned box: long(X) x thin(Y) x tall(Z), centered at origin.
                let base = try engine.box(
                    ManifoldBoxSpec(
                        center: Vec3(x: 0, y: 0, z: 0),
                        extents: Vec3(x: length, y: wall, z: zLen)
                    )
                )
                // Aim along theta, then move to the line position (center Z).
                let aimed = try engine.rotate(base, degreesX: 0, degreesY: 0, degreesZ: angleDeg)
                let placed = try engine.translate(aimed, x: posX, y: posY, z: center.z)
                boxes.append(placed)
            }
        }

        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

// MARK: - Pattern generator stubs (SCAFFOLD phase)
//
// Every reference-chart pattern routes to its OWN named generator here, so
// `StructurePlanner.generator(for:)` dispatch is fully wired and the picker is
// live. The generators below are compiling STUBS: their `makeWallSolid` throws
// `.patternNotImplemented(pattern)` until the real geometry lands in a later
// phase. Routing-through-a-real-generator (vs. returning nil) means the typed
// "not implemented" reason is raised from one place and the UI/CLI surface it
// identically to today. Each stub gets its own type so the later phase fills in
// the body without touching the dispatch table.

/// Shared helpers for the PLANAR generators. A planar pattern is a union of
/// full-height vertical wall boxes (long in-plane, thin = wall thickness, tall =
/// model height + margin) whose XY layout encodes a 2D tiling. Building one
/// `wallBox` is identical across Grid/Tri-Hexagon/Cross/Triangle — only the set
/// of (center, angle) placements differs.
enum PlanarWallBuilder {
    /// Geometry of the bbox the wall lattice must fill.
    struct Frame {
        var center: Vec3
        var dx: Double
        var dy: Double
        var dz: Double
        /// In-plane diagonal of the section (for line-run length).
        var diag2D: Double { (dx * dx + dy * dy).squareRoot() }
        /// Full Z extent + margin so walls overrun the skin and the clip closes them.
        var zLen: Double { dz + 4.0 }
    }

    static func frame(_ bounds: Bounds3D) -> Frame {
        let lo = bounds.min, hi = bounds.max
        return Frame(
            center: Vec3(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2),
            dx: hi.x - lo.x, dy: hi.y - lo.y, dz: hi.z - lo.z
        )
    }

    /// One full-height wall box of the given in-plane length and thickness,
    /// rotated `angleDeg` about Z and placed at (posX, posY, centerZ).
    static func wallBox(
        length: Double, thickness: Double, frame: Frame,
        angleDeg: Double, posX: Double, posY: Double,
        engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let base = try engine.box(
            ManifoldBoxSpec(
                center: Vec3(x: 0, y: 0, z: 0),
                extents: Vec3(x: length, y: thickness, z: frame.zLen)
            )
        )
        let aimed = try engine.rotate(base, degreesX: 0, degreesY: 0, degreesZ: angleDeg)
        return try engine.translate(aimed, x: posX, y: posY, z: frame.center.z)
    }

    /// A family of parallel full-height walls at `angleDeg`, spaced `spacing`
    /// apart and phase-shifted by `phase` (in mm along the perpendicular), enough
    /// to cover the whole section. Reuses the Triangle recipe.
    static func parallelFamily(
        angleDeg: Double, spacing: Double, phase: Double,
        thickness: Double, frame: Frame,
        engine: ManifoldEngine.Type
    ) throws -> [ManifoldHandle] {
        let theta = angleDeg * .pi / 180.0
        let perpX = -sin(theta), perpY = cos(theta)
        let length = frame.diag2D * 1.4 + spacing
        let nLines = Int((frame.diag2D / spacing).rounded(.up)) + 3
        var boxes: [ManifoldHandle] = []
        boxes.reserveCapacity(2 * nLines + 1)
        for k in -nLines...nLines {
            let d = Double(k) * spacing + phase
            let posX = frame.center.x + perpX * d
            let posY = frame.center.y + perpY * d
            boxes.append(try wallBox(
                length: length, thickness: thickness, frame: frame,
                angleDeg: angleDeg, posX: posX, posY: posY, engine: engine
            ))
        }
        return boxes
    }

    static func densityParallelFamily(
        angleDeg: Double,
        spacing: Double,
        phase: Double,
        thickness: Double,
        frame: Frame,
        density: DensityField,
        engine: ManifoldEngine.Type
    ) throws -> [ManifoldHandle] {
        guard !density.isUniform else {
            return try parallelFamily(
                angleDeg: angleDeg,
                spacing: spacing,
                phase: phase,
                thickness: thickness,
                frame: frame,
                engine: engine
            )
        }

        let theta = angleDeg * .pi / 180.0
        let perpX = -sin(theta), perpY = cos(theta)
        let length = frame.diag2D * 1.4 + max(spacing, 0.001)
        let halfDiag = frame.diag2D / 2.0 + max(spacing, 0.001) * 3.0
        let centerU = perpX * frame.center.x + perpY * frame.center.y
        let lo = centerU - halfDiag + phase
        let hi = centerU + halfDiag + phase
        let positions = VariableSpacing.linePositions(
            field: density,
            axis: .x,
            lo: lo,
            hi: hi
        ) { u in
            let delta = u - centerU
            return SIMD3<Double>(
                frame.center.x + perpX * delta,
                frame.center.y + perpY * delta,
                frame.center.z
            )
        }

        var boxes: [ManifoldHandle] = []
        boxes.reserveCapacity(positions.count)
        for u in positions {
            let d = u - centerU
            boxes.append(try wallBox(
                length: length,
                thickness: thickness,
                frame: frame,
                angleDeg: angleDeg,
                posX: frame.center.x + perpX * d,
                posY: frame.center.y + perpY * d,
                engine: engine
            ))
        }
        return boxes
    }
}

/// PLANAR — Grid: two orthogonal wall families at 0° and 90°. Reads as a square
/// grid of cells. Same recipe as Triangle, two families instead of three.
struct GridWallSolidGenerator: WallSolidGenerator {
    static let familyAnglesDegrees: [Double] = [0.0, 90.0]

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let engine = context.engine
        let frame = PlanarWallBuilder.frame(bounds)
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.001)
        var boxes: [ManifoldHandle] = []
        for angle in Self.familyAnglesDegrees {
            if context.density.isUniform {
                boxes.append(contentsOf: try PlanarWallBuilder.parallelFamily(
                    angleDeg: angle, spacing: cell, phase: 0,
                    thickness: wall, frame: frame, engine: engine
                ))
            } else {
                boxes.append(contentsOf: try PlanarWallBuilder.densityParallelFamily(
                    angleDeg: angle, spacing: cell, phase: 0,
                    thickness: wall, frame: frame, density: context.density, engine: engine
                ))
            }
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// PLANAR — Tri-Hexagon: a honeycomb of hexagon outlines tiled across the
/// section. Each hexagon is six full-height wall segments forming its perimeter;
/// neighbouring hexagons share edges and the wedge-shaped gaps between them read
/// as the triangles of the trihexagonal tiling (hexagons + triangles). Tiling
/// hexagon RINGS — rather than three crossing line families, which only ever
/// produce a plain triangular grid — is what makes this unmistakably tri-hex.
struct TriHexagonWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let engine = context.engine
        let frame = PlanarWallBuilder.frame(bounds)
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.001)

        if !context.density.isUniform {
            let lo = bounds.min, hi = bounds.max
            let margin = cell * 2.0
            let rowPositions = VariableSpacing.linePositions(
                field: context.density,
                axis: .y,
                lo: lo.y - margin,
                hi: hi.y + margin
            ) { y in
                SIMD3<Double>(frame.center.x, y, frame.center.z)
            }
            var boxes: [ManifoldHandle] = []

            func emitHex(cx: Double, cy: Double, radius: Double) throws {
                let R = max(radius, 0.001)
                var verts: [(Double, Double)] = []
                for i in 0..<6 {
                    let a = (Double(i) * 60.0 + 30.0) * .pi / 180.0
                    verts.append((cx + R * cos(a), cy + R * sin(a)))
                }
                for i in 0..<6 {
                    let (x0, y0) = verts[i]
                    let (x1, y1) = verts[(i + 1) % 6]
                    let dx = x1 - x0, dy = y1 - y0
                    let segLen = (dx * dx + dy * dy).squareRoot()
                    boxes.append(try PlanarWallBuilder.wallBox(
                        length: segLen + wall,
                        thickness: wall,
                        frame: frame,
                        angleDeg: atan2(dy, dx) * 180.0 / .pi,
                        posX: (x0 + x1) / 2,
                        posY: (y0 + y1) / 2,
                        engine: engine
                    ))
                }
            }

            for (row, cy) in rowPositions.enumerated() {
                let localCell = context.density.cellSize(at: SIMD3<Double>(frame.center.x, cy, frame.center.z))
                let xShift = row.isMultiple(of: 2) ? 0.0 : localCell * 0.5
                let colPositions = VariableSpacing.linePositions(
                    field: context.density,
                    axis: .x,
                    lo: lo.x - margin + xShift,
                    hi: hi.x + margin + xShift
                ) { x in
                    SIMD3<Double>(x, cy, frame.center.z)
                }
                for cx in colPositions {
                    let radius = context.density.cellSize(at: SIMD3<Double>(cx, cy, frame.center.z))
                    try emitHex(cx: cx, cy: cy, radius: radius)
                }
            }
            guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
            return try engine.union(boxes)
        }

        // Hexagon circumradius = cell; edge length also = cell (regular hexagon).
        // Pointy-top hex grid spacing: horizontal pitch = sqrt(3)*R, vertical = 1.5*R.
        let R = cell
        let edge = R
        let hPitch = (3.0).squareRoot() * R
        let vPitch = 1.5 * R
        let lo = bounds.min, hi = bounds.max
        let nCol = Int(((hi.x - lo.x) / hPitch).rounded(.up)) + 2
        let nRow = Int(((hi.y - lo.y) / vPitch).rounded(.up)) + 2

        // The six edge segments of one pointy-top hexagon centered at origin: each
        // edge is a wall box of length `edge`, placed at the edge midpoint, rotated
        // to lie along the edge. Vertices at angles 90,150,210,270,330,30 deg.
        func hexEdges(cx: Double, cy: Double) throws -> [ManifoldHandle] {
            var verts: [(Double, Double)] = []
            for i in 0..<6 {
                let a = (Double(i) * 60.0 + 30.0) * .pi / 180.0
                verts.append((cx + R * cos(a), cy + R * sin(a)))
            }
            var segs: [ManifoldHandle] = []
            // Slightly over-length so adjacent edges fuse at the corners.
            let segLen = edge + wall
            for i in 0..<6 {
                let (x0, y0) = verts[i]
                let (x1, y1) = verts[(i + 1) % 6]
                let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
                let ang = atan2(y1 - y0, x1 - x0) * 180.0 / .pi
                segs.append(try PlanarWallBuilder.wallBox(
                    length: segLen, thickness: wall, frame: frame,
                    angleDeg: ang, posX: mx, posY: my, engine: engine
                ))
            }
            return segs
        }

        var boxes: [ManifoldHandle] = []
        var row = -nRow
        while row <= nRow {
            // Offset alternate rows by half the horizontal pitch to interlock.
            let xOffset = (abs(row) % 2 == 1) ? hPitch / 2 : 0.0
            var col = -nCol
            while col <= nCol {
                let cx = frame.center.x + Double(col) * hPitch + xOffset
                let cy = frame.center.y + Double(row) * vPitch
                boxes.append(contentsOf: try hexEdges(cx: cx, cy: cy))
                col += 1
            }
            row += 1
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// PLANAR — Cross: the owner's reference fretwork, extracted directly from his
/// `crossesB.svg`. The motif is a flared Greek cross whose four arm tips notch
/// into chevrons; the crosses tile on a square lattice and a small connector
/// motif at each cell corner closes the X-shaped voids between them. Both motifs
/// are 2D centre-line segments (normalised to the cell) that we stroke to the
/// wall-thickness slider, extrude the full model height, and let the shared
/// backend clip to the skin — exactly the SVG → extrude → thickness → clip
/// workflow. Four-fold symmetric, so it can NEVER form the swastika shapes a
/// chiral pinwheel tiling does.
struct CrossWallSolidGenerator: WallSolidGenerator {
    // Centre-line segments of one cross, relative to its centre, in cell units
    // (x,y are fractions of the lattice period; y is up).
    static let crossSegs: [(Double, Double, Double, Double)] = [
        (-0.2588, 0.4915, -0.0964, 0.3276),
        (-0.0964, 0.3276, -0.0979, 0.0950),
        (-0.0979, 0.0950, -0.3427, 0.0936),
        (-0.3427, 0.0936, -0.5009, 0.2532),
        (0.4959, 0.2512, 0.3389, 0.0945),
        (0.3389, 0.0945, 0.0968, 0.0966),
        (0.0968, 0.0966, 0.0949, 0.3278),
        (0.0949, 0.3278, 0.2542, 0.4911),
        (0.2542, -0.5045, 0.0938, -0.3415),
        (0.0938, -0.3415, 0.0966, -0.0959),
        (0.0966, -0.0959, 0.3363, -0.0951),
        (0.3363, -0.0951, 0.4934, -0.2602),
        (-0.5034, -0.2581, -0.3329, -0.0939),
        (-0.3329, -0.0939, -0.0956, -0.0956),
        (-0.0956, -0.0956, -0.0938, -0.3325),
        (-0.0938, -0.3325, -0.2588, -0.5041),
    ]
    // Connector segments that close the X-void, relative to the cell corner.
    static let connSegs: [(Double, Double, Double, Double)] = [
        (0.2558, -0.5040, -0.0018, -0.2446),
        (-0.0065, 0.2399, 0.1768, 0.4138),
        (0.4162, 0.1751, 0.2511, 0.0035),
        (0.2511, 0.0035, 0.5093, -0.2570),
    ]

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let engine = context.engine
        let cell = max(params.cellSizeMm, 0.001)        // lattice period (cross spacing)
        let wall = max(params.wallThicknessMm, 0.05)    // stroked wall thickness
        let frame = PlanarWallBuilder.frame(bounds)
        let lo = bounds.min, hi = bounds.max
        let cX = (lo.x + hi.x) / 2, cY = (lo.y + hi.y) / 2

        if !context.density.isUniform {
            let margin = cell
            let yCenters = VariableSpacing.linePositions(
                field: context.density,
                axis: .y,
                lo: lo.y - margin,
                hi: hi.y + margin
            ) { y in
                SIMD3<Double>(cX, y, frame.center.z)
            }
            var boxes: [ManifoldHandle] = []

            func emit(
                _ segs: [(Double, Double, Double, Double)],
                _ ox: Double,
                _ oy: Double,
                _ localCell: Double
            ) throws {
                for (x0, y0, x1, y1) in segs {
                    let ax = ox + x0 * localCell, ay = oy + y0 * localCell
                    let bx = ox + x1 * localCell, by = oy + y1 * localCell
                    let dx = bx - ax, dy = by - ay
                    let segLen = (dx * dx + dy * dy).squareRoot()
                    if segLen < 1e-6 { continue }
                    let angle = atan2(dy, dx) * 180.0 / .pi
                    boxes.append(try PlanarWallBuilder.wallBox(
                        length: segLen + wall,
                        thickness: wall,
                        frame: frame,
                        angleDeg: angle,
                        posX: (ax + bx) / 2,
                        posY: (ay + by) / 2,
                        engine: engine
                    ))
                }
            }

            for cy in yCenters {
                let xCenters = VariableSpacing.linePositions(
                    field: context.density,
                    axis: .x,
                    lo: lo.x - margin,
                    hi: hi.x + margin
                ) { x in
                    SIMD3<Double>(x, cy, frame.center.z)
                }
                for cx in xCenters {
                    let localCell = context.density.cellSize(at: SIMD3<Double>(cx, cy, frame.center.z))
                    try emit(Self.crossSegs, cx, cy, localCell)
                    try emit(Self.connSegs, cx + localCell * 0.5, cy + localCell * 0.5, localCell)
                }
            }
            guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
            return try engine.union(boxes)
        }

        let margin = cell
        let iLo = Int(((lo.x - margin - cX) / cell).rounded(.down))
        let iHi = Int(((hi.x + margin - cX) / cell).rounded(.up))
        let jLo = Int(((lo.y - margin - cY) / cell).rounded(.down))
        let jHi = Int(((hi.y + margin - cY) / cell).rounded(.up))

        var boxes: [ManifoldHandle] = []
        boxes.reserveCapacity((iHi - iLo + 1) * (jHi - jLo + 1) * 20)

        func emit(_ segs: [(Double, Double, Double, Double)], _ ox: Double, _ oy: Double) throws {
            for (x0, y0, x1, y1) in segs {
                let ax = ox + x0 * cell, ay = oy + y0 * cell
                let bx = ox + x1 * cell, by = oy + y1 * cell
                let dx = bx - ax, dy = by - ay
                let segLen = (dx * dx + dy * dy).squareRoot()
                if segLen < 1e-6 { continue }
                let angle = atan2(dy, dx) * 180.0 / .pi
                boxes.append(try PlanarWallBuilder.wallBox(
                    length: segLen + wall, thickness: wall, frame: frame,
                    angleDeg: angle, posX: (ax + bx) / 2, posY: (ay + by) / 2, engine: engine))
            }
        }
        for i in iLo...iHi {
            for j in jLo...jHi {
                try emit(Self.crossSegs, cX + Double(i) * cell, cY + Double(j) * cell)
                try emit(Self.connSegs, cX + (Double(i) + 0.5) * cell, cY + (Double(j) + 0.5) * cell)
            }
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// PLANAR — Concentric: nested inward offsets of the model's section outline.
/// Implemented as nested rectangular RING frames inset from the bbox section by
/// `cellSizeMm` each (the PRD-sanctioned "offset the model bbox section"). Each
/// ring is four full-height wall boxes forming the rectangle perimeter; unioned
/// they read as concentric rings, and the final clip trims them to the true
/// silhouette so the outer rings hug the actual model skin. Union-only (no
/// difference op needed).
struct ConcentricWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let frame = PlanarWallBuilder.frame(bounds)
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.001)

        // Number of rings until the inset collapses to nothing in the shorter axis.
        let shortSide = Swift.min(frame.dx, frame.dy)
        let maxRings = Swift.max(Int((shortSide / (2 * cell)).rounded(.down)), 1)

        var boxes: [ManifoldHandle] = []
        for r in 0...maxRings {
            let inset = Double(r) * cell
            let halfW = frame.dx / 2 - inset
            let halfH = frame.dy / 2 - inset
            if halfW <= wall || halfH <= wall { break }
            // Four perimeter walls of this rectangular ring. Top/bottom run full
            // width (incl. corners); left/right run the interior height to avoid a
            // double-thick corner overlap.
            let cx = frame.center.x, cy = frame.center.y
            let fullW = halfW * 2
            let innerH = Swift.max(halfH * 2 - 2 * wall, wall)
            // Top wall.
            boxes.append(try PlanarWallBuilder.wallBox(
                length: fullW, thickness: wall, frame: frame,
                angleDeg: 0, posX: cx, posY: cy + halfH - wall / 2, engine: engine
            ))
            // Bottom wall.
            boxes.append(try PlanarWallBuilder.wallBox(
                length: fullW, thickness: wall, frame: frame,
                angleDeg: 0, posX: cx, posY: cy - halfH + wall / 2, engine: engine
            ))
            // Right wall.
            boxes.append(try PlanarWallBuilder.wallBox(
                length: innerH, thickness: wall, frame: frame,
                angleDeg: 90, posX: cx + halfW - wall / 2, posY: cy, engine: engine
            ))
            // Left wall.
            boxes.append(try PlanarWallBuilder.wallBox(
                length: innerH, thickness: wall, frame: frame,
                angleDeg: 90, posX: cx - halfW + wall / 2, posY: cy, engine: engine
            ))
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// LATTICE — Cubic: the REAL slicer "Cubic" infill (as printed by CuraEngine).
/// Per layer it is three families of straight parallel lines at plan angles 0°,
/// 120°, 240°, with a per-layer horizontal shift of (z / √2). Stacking the
/// shifted lines turns each line into a thin planar WALL that is SHEARED with
/// height: moving up by dz moves the wall sideways by dz/√2, i.e. each wall is
/// tilted about its own line axis by α = atan(1/√2) ≈ 35.264°.
///
/// We reproduce that geometrically with the SAME line-family → thin-wall recipe
/// the planar patterns use, but with only three families AND each wall tilted by
/// α about its line axis (instead of vertical):
///   1. build a thin box (thin along X = wall thickness, long along Y, tall in Z),
///   2. rotate about Y by α so it shears in X-with-Z (tilt about the line axis),
///   3. rotate about Z by the plan angle θ to aim the line,
///   4. translate to each spaced offset (perpendicular to the line) covering the
///      padded bounds.
/// Union all walls across the three families into one solid; the shared clip
/// backend then intersects it with the model skin (the clip is NOT changed here).
struct CubicWallSolidGenerator: WallSolidGenerator {
    /// The three plan-angle line directions of Cura's cubic infill.
    static let familyAnglesDegrees: [Double] = [0.0, 120.0, 240.0]

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.05)
        return try Self.cubicSlabs(bounds: bounds, cell: cell, wall: wall, engine: engine)
    }

    /// REUSABLE crisp-Cubic generator — EXACT FLAT TILTED WALL SLABS, resolution
    /// INDEPENDENT real CSG. Shared by `CubicWallSolidGenerator` and the
    /// per-level fill of `CubicSubdivisionWallSolidGenerator`.
    ///
    /// CuraEngine Cubic = three line families at plan angles 0°/120°/240°, each
    /// layer's lines shifted sideways by z/√2. Stacking the shifted lines turns
    /// every line into a thin planar WALL sheared with height: the wall is the
    /// locus `s = k·cell` of the sheared coordinate
    ///   s(p) = -sin(a)·x + cos(a)·y - (1/√2)·z.
    /// Each such locus is a FLAT PLANE. Rather than sampling a field and meshing
    /// it with marching cubes (coarse/stepped on big models), we build every wall
    /// as ONE thin box rotated so its faces lie exactly on that plane.
    ///
    /// The wall planes are anchored at `s = k·cell` for integer `k` in WORLD
    /// coordinates (the phase is global, independent of `bounds`). This is what
    /// makes different cell sizes NEST: a slab at level L (size `cell`) and one at
    /// 2·cell share the planes where `k` is even, so the subdivision lattice's
    /// coarse and fine walls align instead of drifting.
    static func cubicSlabs(
        bounds: Bounds3D, cell: Double, wall: Double, engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let lo = bounds.min
        let hi = bounds.max
        let center = Vec3(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)

        let dx = hi.x - lo.x
        let dy = hi.y - lo.y
        let dz = hi.z - lo.z
        let diag = (dx * dx + dy * dy + dz * dz).squareRoot()

        let invSqrt2 = 1.0 / (2.0).squareRoot()
        // |∇s|² = sin²+cos²+(1/√2)² = 1.5. Moving a point along G = ∇s by `t`
        // changes s by t·|G|² = t·1.5.
        let gradSq = 1.5

        // The eight bbox corners — used to bracket which wall planes (s = k·cell)
        // actually cross the body for each family.
        let corners: [Vec3] = [
            Vec3(x: lo.x, y: lo.y, z: lo.z), Vec3(x: hi.x, y: lo.y, z: lo.z),
            Vec3(x: lo.x, y: hi.y, z: lo.z), Vec3(x: hi.x, y: hi.y, z: lo.z),
            Vec3(x: lo.x, y: lo.y, z: hi.z), Vec3(x: hi.x, y: lo.y, z: hi.z),
            Vec3(x: lo.x, y: hi.y, z: hi.z), Vec3(x: hi.x, y: hi.y, z: hi.z),
        ]

        var boxes: [ManifoldHandle] = []

        for angleDeg in Self.familyAnglesDegrees {
            let a = angleDeg * Double.pi / 180.0
            let sa = sin(a)
            let ca = cos(a)
            // Gradient of the sheared coordinate; unit normal of the wall plane.
            let gx = -sa
            let gy = ca
            let gz = -invSqrt2
            let gMag = gradSq.squareRoot()
            let ny = gy / gMag
            let nz = gz / gMag

            // s(p) = -sin(a)·x + cos(a)·y - (1/√2)·z.
            func s(_ p: Vec3) -> Double { -sa * p.x + ca * p.y - invSqrt2 * p.z }

            // Bracket k so walls span the whole body. `k` is a GLOBAL world index
            // (s = k·cell) — not relative to center — so different cell sizes nest.
            var minS = Double.greatestFiniteMagnitude
            var maxS = -Double.greatestFiniteMagnitude
            for c in corners {
                let sc = s(c)
                if sc < minS { minS = sc }
                if sc > maxS { maxS = sc }
            }
            let kmin = Int((minS / cell).rounded(.down))
            let kmax = Int((maxS / cell).rounded(.up))

            // Rotation that maps local +Z onto the wall's unit normal nHat.
            // phi tilts +Z down toward the XY plane; psi spins it to the right azimuth.
            let nxComp = gx / gMag
            let phiDeg = acos(nz) * 180.0 / Double.pi
            let psiDeg = atan2(ny, nxComp) * 180.0 / Double.pi

            for k in kmin...kmax {
                // One thin slab: huge in its own plane (X,Y = diag·2), wall-thin in Z.
                let base = try engine.box(
                    ManifoldBoxSpec(
                        center: Vec3(x: 0, y: 0, z: 0),
                        extents: Vec3(x: diag * 2.0, y: diag * 2.0, z: wall)
                    )
                )
                let rotated = try engine.rotate(base, degreesX: 0, degreesY: phiDeg, degreesZ: psiDeg)
                // Anchor the slab so its plane sits at the GLOBAL world locus
                // s = k·cell. Start from `center` and slide along G:
                // Δs = t·|G|² ⇒ t = (k·cell − s(center)) / 1.5.
                let t = (Double(k) * cell - s(center)) / gradSq
                let cx = center.x + t * gx
                let cy = center.y + t * gy
                let cz = center.z + t * gz
                let placed = try engine.translate(rotated, x: cx, y: cy, z: cz)
                boxes.append(placed)
            }
        }

        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// LATTICE — Octet (CuraEngine `generateTetrahedralInfill`): TWO perpendicular line
/// families (plan angles 0°/90°) whose per-layer sideways offset is a TRIANGLE WAVE
/// in Z. The zigzag offset is what turns the two crossed wall-sheets into stacked
/// tetrahedra. Reimplemented cleanly as an implicit half-tetrahedral PLANE FIELD,
/// meshed by the generic field-MC core — exactly like `CubicWallSolidGenerator`.
struct OctetWallSolidGenerator: WallSolidGenerator {
    /// (plan angle, Z-phase) per line family. Octet keeps both families in phase.
    /// 45°/135° (Cura's default 45° fill rotation) so the crossed truss reads as the
    /// reference's DIAGONAL diamond X — not an axis-aligned square grid.
    static let families: [(angleDeg: Double, phase: Double)] = [
        (angleDeg: 45.0, phase: 0.0),
        (angleDeg: 135.0, phase: 0.0),
    ]

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let solid = try HalfTetrahedralField.makeWallSolid(
            families: Self.families, bounds: bounds, params: params, engine: engine
        )
        return solid
    }
}

/// LATTICE — Quarter Cubic: made STRUCTURALLY distinct from Octet (not the
/// near-invisible phase-shift twin). Octet is TWO perpendicular triangle-wave wall
/// families; Quarter Cubic is THREE families at 0°/60°/120° (phase-staggered), so
/// the tetrahedra interlock into a denser, hexagonal-triangular truss that reads
/// obviously different from Octet's square diamond X. Same implicit half-
/// tetrahedral PLANE FIELD core.
struct QuarterCubicWallSolidGenerator: WallSolidGenerator {
    /// (plan angle, Z-phase) per family — THREE families at 60° spacing, staggered.
    static let families: [(angleDeg: Double, phase: Double)] = [
        (angleDeg: 0.0, phase: 0.0),
        (angleDeg: 60.0, phase: 0.5),
        (angleDeg: 120.0, phase: 0.0),
    ]

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let solid = try HalfTetrahedralField.makeWallSolid(
            families: Self.families, bounds: bounds, params: params, engine: engine
        )
        return solid
    }
}

/// Shared half-tetrahedral plane-field recipe for Octet / Quarter-Cubic.
///
/// Each family is a set of evenly-spaced parallel walls (period `cell` in the
/// perpendicular offset coordinate `u = -sin(a)·x + cos(a)·y`) whose offset slides
/// with height as a TRIANGLE WAVE — `shift(z)` ramps up and down between the walls,
/// so stacking the per-layer crossed lines builds tetrahedra. The local wall slope
/// is 1/√2, hence |∇| = √1.5 and the perpendicular SPATIAL distance to the nearest
/// wall is `ds · (1/√1.5)`. The field is `halfWall − min-over-families(spatial)`:
/// POSITIVE inside a wall slab. The Cura clamp keeps walls from fusing at the
/// zigzag apex.
///
/// Built from the same ribbon-extrusion convention and Manifold union path as
/// `CubicWallSolidGenerator` — the only thing that differs is the zigzag closure.
enum HalfTetrahedralField {
    /// CRISP, resolution-INDEPENDENT half-tetrahedral walls — NO marching cubes.
    ///
    /// Each family's wall is a flat ZIGZAG (triangle-wave) sheet: a 2D zigzag
    /// RIBBON profile (a closed loop tracing the wall's top edge up the zigzag and
    /// its bottom edge back down) is EXTRUDED along the line direction with the
    /// proven `GyroidManifold.extrudeSlab`, then oriented so the profile's offset
    /// axis maps to the family's in-plane perpendicular and the profile's Y maps to
    /// world Z. The triangle wave is piecewise-linear, so the ribbon needs only one
    /// vertex per Z breakpoint (every `cell·√2` in z) — exact at any model size.
    static func makeWallSolid(
        families: [(angleDeg: Double, phase: Double)],
        bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.05)

        let lo = bounds.min
        let hi = bounds.max
        let C = Vec3(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x
        let dy = hi.y - lo.y
        let dz = hi.z - lo.z
        let diag = (dx * dx + dy * dy + dz * dz).squareRoot()

        let invSqrt2 = 1.0 / (2.0).squareRoot()
        let periodS = 2.0 * cell
        // Horizontal half-width so the perpendicular (true) wall thickness == wall.
        let halfBand = wall * (1.5).squareRoot() / 2.0

        // Triangle-wave offset of the wall center at the given absolute z, clamped at
        // the apex exactly like Cura so neighbouring walls never fuse. Returns a value
        // in roughly [0, cell].
        func triangleShift(_ zAbs: Double, _ phase: Double) -> Double {
            let raw = invSqrt2 * (zAbs + phase * periodS * 2.0)
            let s = raw - (raw / periodS).rounded(.down) * periodS
            let tri = Swift.min(s, periodS - s)
            return Swift.min(Swift.max(tri, wall / 2.0), cell - wall / 2.0)
        }

        let bboxCorners: [Vec3] = [
            Vec3(x: lo.x, y: lo.y, z: lo.z), Vec3(x: hi.x, y: lo.y, z: lo.z),
            Vec3(x: lo.x, y: hi.y, z: lo.z), Vec3(x: hi.x, y: hi.y, z: lo.z),
            Vec3(x: lo.x, y: lo.y, z: hi.z), Vec3(x: hi.x, y: lo.y, z: hi.z),
            Vec3(x: lo.x, y: hi.y, z: hi.z), Vec3(x: hi.x, y: hi.y, z: hi.z),
        ]

        var familySolids: [ManifoldHandle] = []

        for (angleDeg, phase) in families {
            let a = angleDeg * Double.pi / 180.0
            // perp = wall-offset axis, d = line / extrude direction (both horizontal).
            let perp = SIMD2<Double>(-sin(a), cos(a))
            let perpDotC = perp.x * C.x + perp.y * C.y

            // Z breakpoints (triangle wave is piecewise-linear; breakpoints every
            // cell·√2 in z) over [-(dz/2+2), +(dz/2+2)] LOCAL z, inclusive of the top.
            let zStep = cell * (2.0).squareRoot()
            let zStart = -(dz / 2.0 + 2.0)
            let zEnd = dz / 2.0 + 2.0
            var zLocs: [Double] = []
            var zl = zStart
            while zl < zEnd {
                zLocs.append(zl)
                zl += zStep
            }
            zLocs.append(zEnd)

            // k range covering the bbox in the perp direction.
            var uMinPerp = Double.greatestFiniteMagnitude
            var uMaxPerp = -Double.greatestFiniteMagnitude
            for c in bboxCorners {
                let pv = perp.x * c.x + perp.y * c.y
                if pv < uMinPerp { uMinPerp = pv }
                if pv > uMaxPerp { uMaxPerp = pv }
            }
            let uMin = uMinPerp - perpDotC
            let uMax = uMaxPerp - perpDotC
            let kLo = Int((uMin / cell).rounded(.down)) - 1
            let kHi = Int((uMax / cell).rounded(.up)) + 1

            var loops: [[SIMD2<Double>]] = []
            loops.reserveCapacity(kHi - kLo + 1)
            for k in kLo...kHi {
                // Wall center in LOCAL profile coords (X = perp-offset relative to C,
                // Y = local z).
                let centers: [(uc: Double, y: Double)] = zLocs.map { zl in
                    let zAbs = zl + C.z
                    let uc = Double(k) * cell + triangleShift(zAbs, phase) - perpDotC
                    return (uc, zl)
                }
                var loop: [SIMD2<Double>] = []
                loop.reserveCapacity(centers.count * 2)
                for c in centers {                       // top edge up
                    loop.append(SIMD2(c.uc + halfBand, c.y))
                }
                for c in centers.reversed() {            // bottom edge down -> closed ribbon
                    loop.append(SIMD2(c.uc - halfBand, c.y))
                }
                loops.append(loop)
            }

            // Extrude the ribbons along +Z by the line length, centered.
            let lineLen = diag * 1.5
            guard let prism = GyroidManifold.extrudeSlab(
                loops: loops, height: lineLen, baseZ: -lineLen / 2.0
            ) else { continue }

            // Orient: profile X(perp-offset) -> perp, profile Y(local z) -> world Z,
            // extrude Z(line) -> d. This is rotateX(90) then rotateZ(90+angleDeg).
            let aimed = try engine.rotate(prism, degreesX: 90, degreesY: 0, degreesZ: 90 + angleDeg)
            let placed = try engine.translate(aimed, x: C.x, y: C.y, z: C.z)
            familySolids.append(placed)
        }

        guard !familySolids.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(familySolids)
    }
}

/// LATTICE — Cubic Subdivision (CuraEngine `SubDivCube`): a multi-scale OCTREE of
/// cubic cells. Big cubic cells fill the deep interior; cells recursively HALVE
/// toward the model surface so they are small near the skin. Each cell is rendered
/// as the crisp Cubic pattern (the three tilted wall planes) AT THAT CELL'S SIZE,
/// so the nesting reads as Cubic-that-gets-finer-near-the-shell — clearly distinct
/// from plain Cubic and from every other pattern.
///
/// Construction (LEVEL-BASED — no winding test; the shared clip removes exterior):
///  - Three sizes nest on the global `s = k·cell·2^L` grid: finest s_0 = cell,
///    s_1 = 2·cell, s_2 = 4·cell (coarsest). The crisp Cubic planes at every level
///    therefore align where their `k` indices coincide.
///  - An octree tiles the model bbox with coarsest (s_2) root cubes. A cube at
///    level L subdivides into 8 half-size (level L-1) children IFF L > 0 AND the
///    cube is NEAR THE SURFACE (any model vertex lies within the cube expanded by
///    s_L on each side). Deep-interior and exterior cubes — and all level-0 cubes —
///    are LEAVES at their level.
///  - Per level L with leaves: regionL = union(box per leaf cube); slabsL =
///    cubicSlabs(modelBounds, s_L); levelGeom = intersect(slabsL, regionL). Union
///    all levels → the subdivision lattice. The unchanged clip backend then
///    intersects with the model skin.
///
/// `sourceVertices` is the model's surface vertices, threaded through
/// `WallSolidContext`. When absent/empty there is no surface to refine toward, so
/// the whole bbox stays coarse → plain coarse Cubic, which still clips to a valid
/// watertight sub-model (keeps the protocol contract).
struct CubicSubdivisionWallSolidGenerator: WallSolidGenerator {
    /// Coarsest octree level index (3 levels: 0 = finest, 2 = coarsest).
    static let maxLevelIndex = 2
    /// Skip subdividing further if it would blow past this many FINEST cells.
    static let finestCellCap = 20_000

    /// One octree cube: integer min-corner index on the level-L lattice plus level.
    /// World min-corner = origin + (ix,iy,iz)·s_L.
    private struct Cube { var ix: Int; var iy: Int; var iz: Int; var level: Int }

    /// Three families of AXIS-ALIGNED wall slabs (perpendicular to X, Y, Z) at
    /// spacing `cell`, planes anchored to the global grid (x/y/z = k·cell), so
    /// coarse and fine levels NEST exactly. Each slab is a thin box of thickness
    /// `wall`. Unlike the tilted Cubic walls, these cut cleanly against the
    /// axis-aligned octree cells — no diagonal slivers.
    static func axisGridSlabs(
        bounds: Bounds3D, cell: Double, wall: Double, engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let c = Vec3(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2, z: (lo.z + hi.z) / 2)
        let m = cell  // overrun so walls span past the bbox; clip trims to skin
        let spanX = (hi.x - lo.x) + 2 * m
        let spanY = (hi.y - lo.y) + 2 * m
        let spanZ = (hi.z - lo.z) + 2 * m
        var boxes: [ManifoldHandle] = []
        // Walls perpendicular to X (vary x = k·cell).
        var k = Int((lo.x / cell).rounded(.down)) - 1
        let kxHi = Int((hi.x / cell).rounded(.up)) + 1
        while k <= kxHi {
            boxes.append(try engine.box(ManifoldBoxSpec(
                center: Vec3(x: Double(k) * cell, y: c.y, z: c.z),
                extents: Vec3(x: wall, y: spanY, z: spanZ))))
            k += 1
        }
        // Walls perpendicular to Y.
        k = Int((lo.y / cell).rounded(.down)) - 1
        let kyHi = Int((hi.y / cell).rounded(.up)) + 1
        while k <= kyHi {
            boxes.append(try engine.box(ManifoldBoxSpec(
                center: Vec3(x: c.x, y: Double(k) * cell, z: c.z),
                extents: Vec3(x: spanX, y: wall, z: spanZ))))
            k += 1
        }
        // Walls perpendicular to Z.
        k = Int((lo.z / cell).rounded(.down)) - 1
        let kzHi = Int((hi.z / cell).rounded(.up)) + 1
        while k <= kzHi {
            boxes.append(try engine.box(ManifoldBoxSpec(
                center: Vec3(x: c.x, y: c.y, z: Double(k) * cell),
                extents: Vec3(x: spanX, y: spanY, z: wall))))
            k += 1
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let engine = context.engine
        let sourceVertices = context.sourceVertices
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.05)

        // Level sizes: s_L = cell · 2^L.
        func size(_ level: Int) -> Double { cell * Double(1 << level) }
        let coarse = size(Self.maxLevelIndex)

        let lo = bounds.min
        let hi = bounds.max
        // Octree origin: snap to the global coarse grid so cubes nest with the
        // crisp-Cubic world phase. (Cube min-corners are origin + index·s_L.)
        func snapDown(_ v: Double) -> Double { (v / coarse).rounded(.down) * coarse }
        let origin = Vec3(x: snapDown(lo.x), y: snapDown(lo.y), z: snapDown(lo.z))

        // Spatial hash of the surface vertices, quantized to the FINEST cell, so the
        // near-surface query is an O(1)-ish set lookup over a small neighbourhood.
        struct Key: Hashable { var x: Int; var y: Int; var z: Int }
        var occ = Set<Key>()
        occ.reserveCapacity(sourceVertices.count)
        @inline(__always) func bucket(_ v: Vec3) -> Key {
            Key(x: Int(((v.x - origin.x) / cell).rounded(.down)),
                y: Int(((v.y - origin.y) / cell).rounded(.down)),
                z: Int(((v.z - origin.z) / cell).rounded(.down)))
        }
        for v in sourceVertices { occ.insert(bucket(v)) }

        // NEAR-SURFACE: does any surface vertex fall inside the cube expanded by s_L
        // on each side? Test the expanded world box against the (finest-cell) hash
        // by scanning the covered buckets — coarse cubes cover more buckets but there
        // are far fewer of them, so total work stays bounded.
        func nearSurface(_ cube: Cube) -> Bool {
            if occ.isEmpty { return false }
            let s = size(cube.level)
            let minX = origin.x + Double(cube.ix) * s - s
            let minY = origin.y + Double(cube.iy) * s - s
            let minZ = origin.z + Double(cube.iz) * s - s
            let maxX = minX + 3.0 * s   // cube (s) + s pad each side
            let maxY = minY + 3.0 * s
            let maxZ = minZ + 3.0 * s
            let bxLo = Int(((minX - origin.x) / cell).rounded(.down))
            let byLo = Int(((minY - origin.y) / cell).rounded(.down))
            let bzLo = Int(((minZ - origin.z) / cell).rounded(.down))
            let bxHi = Int(((maxX - origin.x) / cell).rounded(.down))
            let byHi = Int(((maxY - origin.y) / cell).rounded(.down))
            let bzHi = Int(((maxZ - origin.z) / cell).rounded(.down))
            for bz in bzLo...bzHi {
                for by in byLo...byHi {
                    for bx in bxLo...bxHi {
                        if occ.contains(Key(x: bx, y: by, z: bz)) { return true }
                    }
                }
            }
            return false
        }

        func cubeCenter(_ cube: Cube) -> SIMD3<Double> {
            let s = size(cube.level)
            return SIMD3<Double>(
                origin.x + (Double(cube.ix) + 0.5) * s,
                origin.y + (Double(cube.iy) + 0.5) * s,
                origin.z + (Double(cube.iz) + 0.5) * s
            )
        }

        func shouldSubdivide(_ cube: Cube) -> Bool {
            if context.density.isUniform {
                return nearSurface(cube)
            }
            return context.density.cellSize(at: cubeCenter(cube)) < size(cube.level) - 1.0e-9
        }

        // Root cubes tile the (snapped) bbox at the coarsest size.
        let nRootX = Swift.max(1, Int(((hi.x - origin.x) / coarse).rounded(.up)))
        let nRootY = Swift.max(1, Int(((hi.y - origin.y) / coarse).rounded(.up)))
        let nRootZ = Swift.max(1, Int(((hi.z - origin.z) / coarse).rounded(.up)))

        // Recurse, collecting leaves grouped by level. Cap the FINEST-leaf count so
        // a tiny cell on a big body can't explode into millions of boolean inputs.
        var leavesByLevel = [[Cube]](repeating: [], count: Self.maxLevelIndex + 1)
        var finestLeafCount = 0
        var capped = false

        func subdivide(_ cube: Cube) {
            if cube.level > 0 && shouldSubdivide(cube) {
                // Would 8 children at the finest level overrun the cap?
                if cube.level == 1 && finestLeafCount + 8 > Self.finestCellCap {
                    capped = true
                    leavesByLevel[cube.level].append(cube)   // keep coarse instead
                    return
                }
                let cs = cube.level - 1
                for dz in 0..<2 {
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            subdivide(Cube(
                                ix: cube.ix * 2 + dx,
                                iy: cube.iy * 2 + dy,
                                iz: cube.iz * 2 + dz,
                                level: cs
                            ))
                        }
                    }
                }
            } else {
                leavesByLevel[cube.level].append(cube)
                if cube.level == 0 { finestLeafCount += 1 }
            }
        }

        for iz in 0..<nRootZ {
            for iy in 0..<nRootY {
                for ix in 0..<nRootX {
                    subdivide(Cube(ix: ix, iy: iy, iz: iz, level: Self.maxLevelIndex))
                }
            }
        }
        if capped {
            FileHandle.standardError.write(Data(
                "CubicSubdivision: finest-cell cap (\(Self.finestCellCap)) hit; coarsened near-surface cells.\n".utf8
            ))
        }

        // Per level: union the leaf cubes into a region, intersect with that level's
        // crisp Cubic slabs, then union all levels.
        var levelGeoms: [ManifoldHandle] = []
        for level in 0...Self.maxLevelIndex {
            let leaves = leavesByLevel[level]
            if leaves.isEmpty { continue }
            let s = size(level)
            var cubes: [ManifoldHandle] = []
            cubes.reserveCapacity(leaves.count)
            for c in leaves {
                let cx = origin.x + (Double(c.ix) + 0.5) * s
                let cy = origin.y + (Double(c.iy) + 0.5) * s
                let cz = origin.z + (Double(c.iz) + 0.5) * s
                cubes.append(try engine.box(ManifoldBoxSpec(
                    center: Vec3(x: cx, y: cy, z: cz),
                    extents: Vec3(x: s, y: s, z: s)
                )))
            }
            let region = try engine.union(cubes)
            // AXIS-ALIGNED grid walls (not tilted Cubic): tilted walls cut against
            // the axis-aligned octree cells shatter into diagonal slivers. Axis grid
            // walls cut cleanly and nest exactly across the power-of-two levels.
            let slabs = try Self.axisGridSlabs(
                bounds: bounds, cell: s, wall: wall, engine: engine
            )
            levelGeoms.append(try engine.intersect(slabs, region))
        }

        guard !levelGeoms.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(levelGeoms)
    }
}

/// LATTICE — Cross 3D: Cura's Cross 3D is a SIERPINSKI / VICSEK space-filling
/// fractal of nested cross/plus shapes that pulses along Z — a multi-scale
/// fretwork, NOT a strut truss. This generator builds it as CRISP, axis-aligned,
/// flat-walled geometry (no marching cubes, no rounding), watertight, so the
/// shared `StructureClipEngine` can clip it to the skin unchanged.
///
/// Construction:
///  1. VICSEK / PLUS FRACTAL in XY. Tile the section bbox with base cells of size
///     `cell·2^maxLevel`. Recursively split each kept cell into a 3×3 grid and
///     KEEP only the 5 'plus' sub-cells (centre + 4 edge-centres), discarding the
///     4 corners; recurse to the finest size `cell`. The kept finest cells form a
///     nested-plus fractal whose voids are crosses-within-crosses.
///  2. WALLS. Each kept finest cell contributes its 4 boundary wall segments
///     (thin upright boxes, full local height). Adjacent kept cells share walls in
///     the union, leaving the plus-shaped openings — a fretwork of nested crosses.
///  3. Z PULSE. Split Z into bands ~`cell` tall; alternate bands shift the whole
///     fractal by half a base cell in X and Y, so stacking the bands interlocks
///     the crosses vertically (Cura's pulse) instead of a constant extrusion.
///  4. Levels and cell count are capped so it stays responsive; logs if capped.
struct Cross3DWallSolidGenerator: WallSolidGenerator {
    /// Fractal subdivision levels beyond the finest. Kept at 1 so the base cell is
    /// `cell·3` (finest = `cell`, walls never merge) and the plus motif TILES densely
    /// across the body — at level 2 the base cell is `cell·9`, larger than the whole
    /// model, which collapses the whole pattern into a single giant cross.
    static let maxLevel = 1
    /// Hard cap on the number of finest kept cells across ALL Z bands, so a tiny
    /// cell on a big body can't explode into millions of boolean inputs.
    static let keptCellCap = 30_000

    /// An axis-aligned rectangle in the XY plane (a kept finest cell).
    private struct CellRect { var minX: Double; var minY: Double; var size: Double }

    /// Recursively collect the kept finest cells of the Vicsek plus-fractal that
    /// starts at a base cell of `baseSize` whose min corner is (x0,y0).
    /// `level` counts down: at level 0 the cell is finest and is emitted.
    private static func collectKept(
        x0: Double, y0: Double, size: Double, level: Int, into out: inout [CellRect]
    ) {
        if level == 0 {
            out.append(CellRect(minX: x0, minY: y0, size: size))
            return
        }
        let s = size / 3.0
        // 3×3 grid columns/rows 0..2; KEEP the plus: centre (1,1) + edge-centres
        // (1,0),(0,1),(2,1),(1,2). DISCARD the 4 corners (0,0),(2,0),(0,2),(2,2).
        let keep: [(Int, Int)] = [(1, 1), (1, 0), (0, 1), (2, 1), (1, 2)]
        for (cx, cy) in keep {
            collectKept(
                x0: x0 + Double(cx) * s, y0: y0 + Double(cy) * s,
                size: s, level: level - 1, into: &out
            )
        }
    }

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        try makeWallSolid(
            bounds: context.bounds,
            params: context.params,
            density: context.density,
            engine: context.engine
        )
    }

    private func makeWallSolid(
        bounds: Bounds3D,
        params: InfillParameters,
        density: DensityField,
        engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let center = SIMD3<Double>(
            (lo.x + hi.x) / 2,
            (lo.y + hi.y) / 2,
            (lo.z + hi.z) / 2
        )
        let cell = max(density.isUniform ? params.cellSizeMm : density.cellSize(at: center), 0.001)
        let wall = max(params.wallThicknessMm, 0.05)

        // Base cell = finest cell scaled up by 3^maxLevel (each level is a 3×3
        // split, so the plus fractal nests on a power-of-three lattice).
        var level = Self.maxLevel
        var baseSize = cell * pow(3.0, Double(level))

        // Tile the section bbox (plus a one-base-cell margin) with base cells,
        // snapping the tiling origin DOWN to the base lattice so bands nest.
        func tileGrid(_ base: Double) -> (ox: Double, oy: Double, nx: Int, ny: Int) {
            let ox = (lo.x / base).rounded(.down) * base - base
            let oy = (lo.y / base).rounded(.down) * base - base
            let nx = Int(((hi.x - ox) / base).rounded(.up)) + 2
            let ny = Int(((hi.y - oy) / base).rounded(.up)) + 2
            return (ox, oy, max(1, nx), max(1, ny))
        }

        // Z bands: ~one finest cell tall, with margin so walls overrun the skin.
        let bandH = cell
        let zLo = lo.z - cell
        let zHi = hi.z + cell
        let nBands = max(1, Int(((zHi - zLo) / bandH).rounded(.up)))

        // Estimate kept-cell count = (kept-per-base = 5^level) × baseCells × bands.
        // Drop a level (and recompute the base) until it fits the cap, so a tiny
        // cell on a big body stays responsive. Log if we had to coarsen.
        var capped = false
        func keptEstimate(_ lvl: Int, _ base: Double) -> Int {
            let grid = tileGrid(base)
            let perBase = Int(pow(5.0, Double(lvl)).rounded())
            return perBase * grid.nx * grid.ny * nBands
        }
        while level > 0 && keptEstimate(level, baseSize) > Self.keptCellCap {
            level -= 1
            baseSize = cell * pow(3.0, Double(level))
            capped = true
        }
        if capped {
            FileHandle.standardError.write(Data(
                "Cross3D: kept-cell cap (\(Self.keptCellCap)) hit; reduced fractal to \(level + 1) scale(s).\n".utf8
            ))
        }

        let grid = tileGrid(baseSize)

        // Collect the kept finest cells for ONE Z band's fractal (origin at 0,0;
        // the band's actual placement is applied via an XY offset below).
        var keptUnit: [CellRect] = []
        keptUnit.reserveCapacity(max(16, keptEstimate(level, baseSize) / max(1, nBands)))
        for iy in 0..<grid.ny {
            for ix in 0..<grid.nx {
                Self.collectKept(
                    x0: grid.ox + Double(ix) * baseSize,
                    y0: grid.oy + Double(iy) * baseSize,
                    size: baseSize, level: level, into: &keptUnit
                )
            }
        }
        guard !keptUnit.isEmpty else { throw StructureEngineError.missingBounds }

        // Build each Z band: emit the 4 boundary walls of every kept finest cell,
        // bounded to that band's Z range, then alternate bands shift the fractal by
        // half a finest cell in X and Y so the crosses interlock vertically (the
        // pulse). Wall boxes overrun by `wall` at each corner so the 4 segments of
        // a cell fuse into a closed square ring and neighbours weld in the union.
        let half = cell * 0.5
        var boxes: [ManifoldHandle] = []
        boxes.reserveCapacity(keptUnit.count * 4 * nBands)

        for b in 0..<nBands {
            let bz = zLo + (Double(b) + 0.5) * bandH
            // Overrun the band by half a wall on each Z face so consecutive bands
            // weld into one watertight solid rather than just touching.
            let zExt = bandH + wall
            let pulse = (b % 2 == 1)
            let shiftX = pulse ? half : 0.0
            let shiftY = pulse ? half : 0.0

            for r in keptUnit {
                let x0 = r.minX + shiftX
                let y0 = r.minY + shiftY
                let s = r.size
                let cx = x0 + s * 0.5
                let cy = y0 + s * 0.5
                // Horizontal walls (run along X): bottom and top edges of the cell.
                // Length = s + wall so the corners overlap the vertical walls.
                for ey in [y0, y0 + s] {
                    boxes.append(try engine.box(ManifoldBoxSpec(
                        center: Vec3(x: cx, y: ey, z: bz),
                        extents: Vec3(x: s + wall, y: wall, z: zExt)
                    )))
                }
                // Vertical walls (run along Y): left and right edges of the cell.
                for ex in [x0, x0 + s] {
                    boxes.append(try engine.box(ManifoldBoxSpec(
                        center: Vec3(x: ex, y: cy, z: bz),
                        extents: Vec3(x: wall, y: s + wall, z: zExt)
                    )))
                }
            }
        }

        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// Shared gyroid sizing. Both non-MC gyroid generators open the period up the same
/// fixed amount (the gyroid reads best as an OPEN, flowing sheet, larger than the
/// planar/lattice patterns want at the same `cellSizeMm`) and derive the field band
/// from the same wall-thickness mapping, so Lofted and Tiled stay comparable.
private enum GyroidSizing {
    /// Effective period = the cell control, honored literally (no hidden ×1.6).
    static func cell(_ params: InfillParameters) -> Double {
        max(params.cellSizeMm, 0.001)
    }
    static func band(_ params: InfillParameters) -> Double {
        GyroidField.band(
            cell: cell(params),
            wallMm: max(params.wallThicknessMm, 0.001),
            floor: params.gyroidBand
        )
    }
}

/// TPMS — Gyroid · Lofted: the owner's slicer/loft recipe, made robust. For fine Z
/// layers we trace the 2D wall region `{ |g(x,y,z_i)| < band }` as polygon contours
/// with 2D MARCHING SQUARES (NOT 3D marching cubes), extrude each layer by the
/// layer height so the slabs abut, and UNION every layer with Manifold (which
/// auto-handles where channels merge or split — no fragile manual skinning). The
/// unioned solid is then refined + Taubin/Laplacian-SMOOTHED (`manifold_smooth_out`)
/// to round out the small Z-terraces into the flowing minimal-surface look. The
/// shared clip backend then INTERSECTS the result with the solidified source.
struct GyroidLoftedWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(
        bounds: Bounds3D,
        params: InfillParameters,
        engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let cell = GyroidSizing.cell(params)
        let k = 2.0 * Double.pi / cell

        // Pad so the sheet runs past the skin; the clip closes it on the surface.
        let pad = cell * 0.5
        let oLo = Vec3(x: lo.x - pad, y: lo.y - pad, z: lo.z - pad)
        let spanX = (hi.x - lo.x) + 2 * pad
        let spanY = (hi.y - lo.y) + 2 * pad
        let spanZ = (hi.z - lo.z) + 2 * pad

        // The wall is an IN-PLANE feature: each layer's sheet contour is an annulus
        // ~wall wide. Sample fine enough to resolve THAT (~2.5 samples across the
        // wall), bounded by a grid cap. If the requested wall is too thin to resolve
        // within the cap, raise the effective wall to the thinnest resolvable — so
        // the wall is HONORED down to a body-relative limit, decoupled from cell
        // (no more giant slabs from a cell-scaled band floor). Always resolving the
        // wall also keeps contours non-degenerate, avoiding the Manifold crash.
        let maxGrid2D = 360.0
        var stepXY = max(params.wallThicknessMm, 0.05) / 2.5
        let rawN = Swift.max(spanX, spanY) / stepXY
        if rawN > maxGrid2D { stepXY *= rawN / maxGrid2D }
        let wallMm = Swift.max(params.wallThicknessMm, stepXY * 2.5)
        let band = k * wallMm / 2.0
        let nx = max(2, Int((spanX / stepXY).rounded(.up)) + 1)
        let ny = max(2, Int((spanY / stepXY).rounded(.up)) + 1)
        let dx = spanX / Double(nx - 1)
        let dy = spanY / Double(ny - 1)

        // Slice (layer) height is USER-CONTROLLED (the "Slice" slider) — this is
        // the terrace size of the layered loft. Smaller = finer/smoother, slower.
        let layerHeight = max(params.loftSliceMm, 0.2)

        // MEMORY GUARD. The self-intersection crash is fixed in extrudeSlab (the
        // cross-section normalisation), so the slab union is now robust — but a
        // DENSE cell AND a FINE slice together still build a huge solid (layer
        // count × in-plane gyroid cells worth of geometry), and peak union memory
        // can run into many GB. Bound that product to a budget by raising the
        // slice height so a dense-cell + fine-slice request stays within a few GB
        // (the GUI also holds the source mesh + RealityKit scene on top). Coarse/
        // normal cells keep the full slice range; only the dense + fine extreme is
        // coarsened. ~10k peak-RSS'd around 3 GB on the hand here.
        let inPlaneCells = Swift.max((spanX / cell) * (spanY / cell), 1.0)
        let complexityBudget = 10_000.0
        let layersByBudget = Swift.max(1, Int(complexityBudget / inPlaneCells))
        let maxLayers = Swift.min(1200, layersByBudget)
        var lh = layerHeight
        if spanZ / lh > Double(maxLayers) { lh = spanZ / Double(maxLayers) }
        let layerCount = Swift.min(maxLayers, Swift.max(1, Int((spanZ / lh).rounded(.up))))

        var slabs: [ManifoldHandle] = []
        slabs.reserveCapacity(layerCount)

        // Per-layer: sample the SIGNED sheet field `band - |g|` (positive INSIDE
        // the sheet) on the 2D grid at the layer's mid-Z, trace the |g|=band
        // contour via marching squares, extrude the region by the layer height.
        for li in 0..<layerCount {
            let baseZ = oLo.z + Double(li) * lh
            let midZ = baseZ + lh * 0.5
            let kz = k * midZ
            let sinKz = sin(kz), cosKz = cos(kz)

            var field = [Double](repeating: 0, count: nx * ny)
            field.withUnsafeMutableBufferPointer { buf in
                var off = 0
                for iy in 0..<ny {
                    let y = oLo.y + Double(iy) * dy
                    let ky = k * y
                    let sinKy = sin(ky), cosKy = cos(ky)
                    for ix in 0..<nx {
                        let x = oLo.x + Double(ix) * dx
                        let kx = k * x
                        let sinKx = sin(kx), cosKx = cos(kx)
                        let g = sinKx * cosKy + sinKy * cosKz + sinKz * cosKx
                        // Positive inside the sheet so the marching-squares
                        // "value > iso" convention traces the sheet boundary.
                        buf[off] = band - abs(g)
                        off += 1
                    }
                }
            }

            let loops = MarchingSquares.contours(
                values: field, nx: nx, ny: ny,
                originX: oLo.x, originY: oLo.y, dx: dx, dy: dy, iso: 0.0
            )
            if let slab = GyroidManifold.extrudeSlab(loops: loops, height: lh, baseZ: baseZ) {
                slabs.append(slab)
            }
        }

        guard !slabs.isEmpty else { throw StructureEngineError.missingBounds }
        let unioned = try engine.union(slabs)
        // No refine+smooth: refine:2 quadrupled the triangle count and the smooth
        // pass mangled thin walls into the shattered mess. Fine layers already keep
        // the terracing small; the owner is fine with the per-layer character.
        return unioned
    }
}

/// Shared marching-cubes core for the field-based gyroid options (owner-approved).
/// Samples `solidField(g)` (positive INSIDE the solid) on a padded 3D grid, SEALS
/// the boundary so the surface closes into a watertight solid, extracts it with our
/// watertight marching cubes, and returns the Manifold handle. The shared clip
/// backend then INTERSECTS it with the source.
private enum GyroidMC {
    struct Resolution {
        var step: Double
        var coarsened: Bool
    }

    /// The exact step `solid`/`solidWithField` will sample at for these inputs —
    /// including the cell-budget coarsening. Generators call this FIRST so a step
    /// too coarse for the requested wall can be handled (thicken + notice), never
    /// silently shattered.
    static func resolution(bounds: Bounds3D, cell: Double, wallMm: Double) -> Resolution {
        let lo = bounds.min, hi = bounds.max
        let pad = cell * 0.5
        let spanX = (hi.x - lo.x) + 2 * pad
        let spanY = (hi.y - lo.y) + 2 * pad
        let spanZ = (hi.z - lo.z) + 2 * pad
        var step = max(min(max(wallMm, 0.05) * 0.5, cell / 16.0), 0.30)
        let cellBudget = 2_500_000.0
        let estCells = (spanX / step) * (spanY / step) * (spanZ / step)
        let coarsened = estCells > cellBudget
        if coarsened { step *= pow(estCells / cellBudget, 1.0 / 3.0) }
        return Resolution(step: step, coarsened: coarsened)
    }

    static func solid(
        bounds: Bounds3D,
        cell: Double,
        wallMm: Double,
        polish: Bool,
        engine: ManifoldEngine.Type,
        solidField: (Double) -> Double
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let k = 2.0 * Double.pi / cell
        let pad = cell * 0.5
        let oLo = Vec3(x: lo.x - pad, y: lo.y - pad, z: lo.z - pad)
        let spanX = (hi.x - lo.x) + 2 * pad
        let spanY = (hi.y - lo.y) + 2 * pad
        let spanZ = (hi.z - lo.z) + 2 * pad

        // Grid step fine enough to resolve the feature (a few samples across the
        // wall), bounded by a cell budget so a big body / thin wall stays responsive.
        // Kept in sync with `resolution(bounds:cell:wallMm:)` above.
        let step = resolution(bounds: bounds, cell: cell, wallMm: wallMm).step
        let cx = max(2, Int((spanX / step).rounded(.up)) + 1)
        let cy = max(2, Int((spanY / step).rounded(.up)) + 1)
        let cz = max(2, Int((spanZ / step).rounded(.up)) + 1)
        let dxg = spanX / Double(cx - 1)
        let dyg = spanY / Double(cy - 1)
        let dzg = spanZ / Double(cz - 1)

        var field = [Double](repeating: 0, count: cx * cy * cz)
        var off = 0
        for iz in 0..<cz {
            let z = oLo.z + Double(iz) * dzg
            let kz = k * z; let sinKz = sin(kz), cosKz = cos(kz)
            let edgeZ = (iz == 0 || iz == cz - 1)
            for iy in 0..<cy {
                let y = oLo.y + Double(iy) * dyg
                let ky = k * y; let sinKy = sin(ky), cosKy = cos(ky)
                let edgeYZ = edgeZ || iy == 0 || iy == cy - 1
                for ix in 0..<cx {
                    if edgeYZ || ix == 0 || ix == cx - 1 {
                        field[off] = -1.0  // seal boundary OUTSIDE the solid
                    } else {
                        let kx = k * (oLo.x + Double(ix) * dxg)
                        let g = sin(kx) * cosKy + sinKy * cosKz + sinKz * cos(kx)
                        field[off] = solidField(g)
                    }
                    off += 1
                }
            }
        }

        let scalar = MarchingCubes.ScalarField(
            cx: cx, cy: cy, cz: cz, origin: oLo,
            dx: dxg, dy: dyg, dz: dzg, values: field
        )
        var surface = MarchingCubes.surface(scalar, iso: 0.0)
        guard surface.triangleIndices.count >= 3 else { throw StructureEngineError.missingBounds }
        // Follow-up pass (does NOT touch the MC algorithm): flatten the isolated
        // triangular dimples MC scatters across the smooth sheet, leaving the
        // curves and sharp rail edges intact. Positions only → still watertight.
        if polish {
            surface = SurfaceDespeckle.polished(surface)
        }
        return try engine.make(from: surface)
    }

    static func solidWithField(
        bounds: Bounds3D,
        cell: Double,
        wallMm: Double,
        polish: Bool,
        engine: ManifoldEngine.Type,
        solidFieldAt: (Double, Double, Double) -> Double
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let pad = cell * 0.5
        let oLo = Vec3(x: lo.x - pad, y: lo.y - pad, z: lo.z - pad)
        let spanX = (hi.x - lo.x) + 2 * pad
        let spanY = (hi.y - lo.y) + 2 * pad
        let spanZ = (hi.z - lo.z) + 2 * pad

        let step = resolution(bounds: bounds, cell: cell, wallMm: wallMm).step
        let cx = max(2, Int((spanX / step).rounded(.up)) + 1)
        let cy = max(2, Int((spanY / step).rounded(.up)) + 1)
        let cz = max(2, Int((spanZ / step).rounded(.up)) + 1)
        let dxg = spanX / Double(cx - 1)
        let dyg = spanY / Double(cy - 1)
        let dzg = spanZ / Double(cz - 1)

        var field = [Double](repeating: 0, count: cx * cy * cz)
        var off = 0
        for iz in 0..<cz {
            let z = oLo.z + Double(iz) * dzg
            let edgeZ = (iz == 0 || iz == cz - 1)
            for iy in 0..<cy {
                let y = oLo.y + Double(iy) * dyg
                let edgeYZ = edgeZ || iy == 0 || iy == cy - 1
                for ix in 0..<cx {
                    if edgeYZ || ix == 0 || ix == cx - 1 {
                        field[off] = -1.0
                    } else {
                        field[off] = solidFieldAt(oLo.x + Double(ix) * dxg, y, z)
                    }
                    off += 1
                }
            }
        }

        let scalar = MarchingCubes.ScalarField(
            cx: cx, cy: cy, cz: cz, origin: oLo,
            dx: dxg, dy: dyg, dz: dzg, values: field
        )
        var surface = MarchingCubes.surface(scalar, iso: 0.0)
        guard surface.triangleIndices.count >= 3 else { throw StructureEngineError.missingBounds }
        if polish {
            surface = SurfaceDespeckle.polished(surface)
        }
        return try engine.make(from: surface)
    }
}

/// A wall thinner than ~2 sampling steps cannot be resolved by the MC grid — the
/// sheet disintegrates into confetti (the 2026-07-02 hand-shatter bug). Resolve
/// the FINAL step (incl. budget coarsening) first; if the requested wall is too
/// thin for it, raise the effective wall and say so in a user-visible notice.
private enum GyroidResolvability {
    struct Outcome {
        var wallMm: Double
        var notice: String?
    }

    static func resolve(bounds: Bounds3D, cell: Double, requestedWallMm: Double) -> Outcome {
        let res = GyroidMC.resolution(bounds: bounds, cell: cell, wallMm: requestedWallMm)
        var wall = requestedWallMm
        var clauses: [String] = []
        if res.coarsened {
            clauses.append(String(
                format: "Gyroid sampling grid coarsened to %.2f mm to stay within the cell budget.",
                res.step
            ))
        }
        if requestedWallMm < 2.0 * res.step {
            wall = (res.step * 2.05 * 100).rounded() / 100
            clauses.append(String(
                format: "Wall raised %.2f → %.2f mm so the sheet stays resolvable at this model size.",
                requestedWallMm, wall
            ))
        }
        return Outcome(wallMm: wall, notice: clauses.isEmpty ? nil : clauses.joined(separator: " "))
    }
}

/// TPMS — Gyroid · Marching Cubes: the smooth minimal-SHEET form (`|g| < band`),
/// the reference look. Wall honored via band ≈ k·wall/2.
struct GyroidTiledWallSolidGenerator: WallSolidGenerator {
    var wallSolidMayCarrySpecks: Bool { true }

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let params = context.params
        let cell = GyroidSizing.cell(params)
        let outcome = GyroidResolvability.resolve(
            bounds: context.bounds,
            cell: cell,
            requestedWallMm: max(params.wallThicknessMm, 0.05)
        )
        if let notice = outcome.notice { context.notices.add(notice) }
        let band = GyroidField.band(cell: cell, wallMm: outcome.wallMm, floor: params.gyroidBand)
        return try GyroidMC.solid(bounds: context.bounds, cell: cell, wallMm: outcome.wallMm, polish: params.polishSurface, engine: context.engine) { g in
            band - abs(g)
        }
    }
}

/// TPMS — Gyroid · Network: the solid double-network form (`g < level`) — one of the
/// two interpenetrating gyroid labyrinths, a chunkier strut look vs the sheet. The
/// wall control sets strut girth (more wall → level nearer 0 → thicker network).
struct GyroidNetworkWallSolidGenerator: WallSolidGenerator {
    var wallSolidMayCarrySpecks: Bool { true }

    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let params = context.params
        let cell = GyroidSizing.cell(params)
        let outcome = GyroidResolvability.resolve(
            bounds: context.bounds,
            cell: cell,
            requestedWallMm: max(params.wallThicknessMm, 0.05)
        )
        if let notice = outcome.notice { context.notices.add(notice) }
        let band = GyroidField.band(cell: cell, wallMm: outcome.wallMm, floor: params.gyroidBand)
        let level = Swift.min(Swift.max(-1.4 + band * 1.8, -1.3), -0.1)
        return try GyroidMC.solid(bounds: context.bounds, cell: cell, wallMm: outcome.wallMm, polish: params.polishSurface, engine: context.engine) { g in
            level - g
        }
    }
}

/// TPMS — Graded Gyroid: one-axis density grading via phase integration. The X
/// term uses `φ(x)=∫k(t)dt`; Y/Z stay at the base period so the sheet remains a
/// regular gyroid family while cell frequency increases across the graded axis.
struct GradedGyroidWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    var wallSolidMayCarrySpecks: Bool { true }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let params = context.params
        let baseCell = GyroidSizing.cell(params)
        let outcome = GyroidResolvability.resolve(
            bounds: bounds,
            cell: baseCell,
            requestedWallMm: max(params.wallThicknessMm, 0.05)
        )
        if let notice = outcome.notice { context.notices.add(notice) }
        let wall = outcome.wallMm
        let density: DensityField
        if context.density.isUniform {
            density = .linearDensityRamp(
                axis: .x,
                lo: bounds.min.x,
                hi: bounds.max.x,
                startDensity: 1.0 / baseCell,
                endDensity: 1.0 / max(baseCell * 0.5, 1.0)
            )
        } else {
            density = context.density
        }
        let phase = GyroidPhaseTable(bounds: bounds, axis: .x, density: density)
        let kYZ = 2.0 * Double.pi / baseCell
        let band = GyroidField.band(cell: baseCell, wallMm: wall, floor: params.gyroidBand)

        return try GyroidMC.solidWithField(
            bounds: bounds,
            cell: baseCell,
            wallMm: wall,
            polish: params.polishSurface,
            engine: context.engine
        ) { x, y, z in
            let px = phase.phase(at: x)
            let ky = kYZ * y
            let kz = kYZ * z
            let g = sin(px) * cos(ky) + sin(ky) * cos(kz) + sin(kz) * cos(px)
            return band - abs(g)
        }
    }
}

/// Shared clip backend: turn a source mesh into a Manifold solid, build the
/// pattern's wall solid for the source bounds, INTERSECT, and read the result
/// back as a watertight grouped mesh. Pattern-agnostic — every infill pattern
/// reuses this; only the `WallSolidGenerator` differs.
enum StructureClipEngine {
    private static let speckleRelativeFloor = 1.0e-4
    private static let structuresHealMaxCells = 150_000

    struct SolidifyResult {
        let solid: ManifoldHandle
        let clipFidelityNotice: String?
    }

    struct ClippedInfillResult {
        let mesh: MeshGeometryData
        let clipFidelityNotice: String?
        /// Generator-side notice (MC coarsening / wall auto-thicken) — surfaced,
        /// never silent.
        let wallSolidNotice: String?
        let preClipDroppedCount: Int
        let preClipDroppedVolume: Double
        let postClipDroppedCount: Int
        let postClipDroppedVolume: Double
    }

    /// Weld coincident vertices by quantized position and rebuild the index
    /// array. STL fixtures store per-triangle (unshared) vertices, which Manifold
    /// rejects as non-manifold even when the mesh is a closed solid; welding
    /// reconnects shared edges WITHOUT changing topology (this is index
    /// reconstruction, not a winding-number heal). OBJ meshes that already share
    /// vertices are unaffected.
    static func welded(_ mesh: MeshGeometryData) -> MeshGeometryData {
        // Quantize to 1e-6 mm so floating-point-equal vertices collapse.
        struct Key: Hashable { var x: Int64; var y: Int64; var z: Int64 }
        let scale = 1_000_000.0
        func key(_ v: Vec3) -> Key {
            Key(x: Int64((v.x * scale).rounded()),
                y: Int64((v.y * scale).rounded()),
                z: Int64((v.z * scale).rounded()))
        }

        var indexByKey: [Key: Int32] = [:]
        var vertices: [Vec3] = []
        vertices.reserveCapacity(mesh.vertices.count)
        var remap = [Int32](repeating: -1, count: mesh.vertices.count)

        func weldedIndex(for original: Int32) -> Int32 {
            let i = Int(original)
            if remap[i] >= 0 { return remap[i] }
            let v = mesh.vertices[i]
            let k = key(v)
            if let existing = indexByKey[k] {
                remap[i] = existing
                return existing
            }
            let new = Int32(vertices.count)
            vertices.append(v)
            indexByKey[k] = new
            remap[i] = new
            return new
        }

        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangleIndices.count)
        var t = 0
        while t + 2 < mesh.triangleIndices.count {
            let a = weldedIndex(for: mesh.triangleIndices[t])
            let b = weldedIndex(for: mesh.triangleIndices[t + 1])
            let c = weldedIndex(for: mesh.triangleIndices[t + 2])
            // Drop degenerate triangles (two welded corners collapsed together);
            // they would make the result non-manifold.
            if a != b && b != c && a != c {
                indices.append(a); indices.append(b); indices.append(c)
            }
            t += 3
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// Turn a source mesh into a watertight Manifold solid. Already-watertight
    /// meshes (cube/sphere/torus and other closed solids) take the no-heal FAST
    /// path: weld shared vertices and hand straight to Manifold. Only when that
    /// fails — a non-watertight organic mesh with holes/handles (e.g. the hand) —
    /// do we fall back to the GWN-signed-distance heal, which rebuilds a
    /// watertight solid WITHOUT inflating bounds or bridging thin features.
    ///
    /// - Throws `StructureEngineError.needsHealing` only when BOTH the fast path
    ///   and the heal fail to yield a watertight solid.
    static func solidify(
        source: MeshGeometryData,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> ManifoldHandle {
        try solidifyResult(source: source, engine: engine).solid
    }

    static func solidifyResult(
        source: MeshGeometryData,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> SolidifyResult {
        // Fast path: closed solids go straight through.
        if let direct = try? engine.make(from: welded(source)),
           engine.isWatertight(direct) {
            return SolidifyResult(solid: direct, clipFidelityNotice: nil)
        }
        // Heal path: organic / non-watertight source.
        do {
            // The healed mesh here is a THROWAWAY clip boundary (the infill
            // pattern is what the user sees), so a coarse/fast heal is strictly
            // better — cap the field grid at ~150k cells.
            let result = try MeshHealer.heal(source, maxCells: structuresHealMaxCells, engine: engine)
            guard engine.isWatertight(result.handle) else {
                throw StructureEngineError.needsHealing
            }
            return SolidifyResult(
                solid: result.handle,
                clipFidelityNotice:
                    "Structures clip boundary healed with maxCells=\(structuresHealMaxCells); this path does not reuse a cached full-resolution Make Watertight mesh."
            )
        } catch {
            throw StructureEngineError.needsHealing
        }
    }

    /// Generate clipped infill geometry for the given source. Watertight sources
    /// clip directly; non-watertight sources are healed (GWN signed distance ->
    /// level_set) into a watertight solid first, then clipped unchanged.
    ///
    /// - Throws `StructureEngineError.needsHealing` when the source cannot be made
    ///   watertight even after healing.
    /// - Throws `StructureEngineError.missingBounds` when there are no bounds.
    static func clippedInfill(
        source: MeshGeometryData,
        bounds: Bounds3D,
        params: InfillParameters,
        generator: WallSolidGenerator,
        density: DensityField? = nil,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> MeshGeometryData {
        try clippedInfillResult(
            source: source,
            bounds: bounds,
            params: params,
            generator: generator,
            density: density,
            engine: engine
        ).mesh
    }

    static func clippedInfillResult(
        source: MeshGeometryData,
        bounds: Bounds3D,
        params: InfillParameters,
        generator: WallSolidGenerator,
        density: DensityField? = nil,
        engine: ManifoldEngine.Type = ManifoldEngine.self
    ) throws -> ClippedInfillResult {
        let solidified = try solidifyResult(source: source, engine: engine)
        let sourceSolid = solidified.solid

        // Clip against the HEALED solid's actual bounds — for a healed mesh the
        // discretized bounds can differ from the raw source bounds by a voxel, so
        // building the wall lattice over the solid's own bounds keeps the lattice
        // fully covering the body.
        let clipBounds = engine.bounds(sourceSolid)

        let minWall = max(params.wallThicknessMm, 0.001)
        let wallFloor = minWall * minWall * minWall
        let minDiagonal = 2.0 * minWall

        let context = WallSolidContext(
            bounds: clipBounds,
            params: params,
            engine: engine,
            density: density ?? .uniform(cellSizeMm: params.cellSizeMm),
            sourceVertices: source.vertices
        )
        let wallSolid = try generator.makeWallSolid(context)
        let filteredWall: (ManifoldHandle, droppedCount: Int, droppedVolume: Double)
        // Pre-clip filtering matters when the wall solid itself can carry debris
        // (MC boundary-seal fragments) or when the clip boundary is a coarse heal.
        if solidified.clipFidelityNotice == nil && !generator.wallSolidMayCarrySpecks {
            filteredWall = (wallSolid, 0, 0)
        } else {
            filteredWall = try ComponentFilter.filterSpecks(
                wallSolid,
                engine: engine,
                relFloor: speckleRelativeFloor,
                absFloorMm3: wallFloor,
                minBBoxDiagonal: minDiagonal
            )
        }
        let clipped = try engine.intersect(filteredWall.0, sourceSolid)
        let filteredClipped = try ComponentFilter.filterSpecks(
            clipped,
            engine: engine,
            relFloor: speckleRelativeFloor,
            absFloorMm3: wallFloor,
            minBBoxDiagonal: minDiagonal
        )
        var finalClipped = filteredClipped.0
        var postClipDroppedCount = filteredClipped.droppedCount
        var postClipDroppedVolume = filteredClipped.droppedVolume
        // The audit consumes exported mesh, not the raw Manifold handle. Run one
        // export-shaped sanitation pass so mesh round-tripping cannot reintroduce
        // a borderline crumb after the documented post-clip filter acts. Runs
        // unconditionally: a round-trip-only crumb can appear even when the first
        // filter dropped nothing.
        do {
            let auditShapedMesh = try engine.toMesh(filteredClipped.0)
            if let auditShapedSolid = try? engine.make(from: welded(auditShapedMesh)) {
                let auditShapedFilter = try ComponentFilter.filterSpecks(
                    auditShapedSolid,
                    engine: engine,
                    relFloor: speckleRelativeFloor,
                    absFloorMm3: wallFloor,
                    minBBoxDiagonal: minDiagonal
                )
                postClipDroppedCount += auditShapedFilter.droppedCount
                postClipDroppedVolume += auditShapedFilter.droppedVolume
                finalClipped = auditShapedFilter.0
                withExtendedLifetime(auditShapedSolid) {}
                withExtendedLifetime(auditShapedFilter.0) {}
            }
        }
        let mesh = try engine.toMesh(finalClipped)
        withExtendedLifetime(sourceSolid) {}
        withExtendedLifetime(wallSolid) {}
        withExtendedLifetime(filteredWall.0) {}
        withExtendedLifetime(clipped) {}
        withExtendedLifetime(filteredClipped.0) {}
        withExtendedLifetime(finalClipped) {}
        return ClippedInfillResult(
            mesh: mesh,
            clipFidelityNotice: solidified.clipFidelityNotice,
            wallSolidNotice: context.notices.combined,
            preClipDroppedCount: filteredWall.droppedCount,
            preClipDroppedVolume: filteredWall.droppedVolume,
            postClipDroppedCount: postClipDroppedCount,
            postClipDroppedVolume: postClipDroppedVolume
        )
    }
}

struct ComponentFilter {
    static func filterSpecks(
        _ solid: ManifoldHandle,
        engine: ManifoldEngine.Type,
        relFloor: Double,
        absFloorMm3: Double,
        minBBoxDiagonal: Double
    ) throws -> (ManifoldHandle, droppedCount: Int, droppedVolume: Double) {
        let components = try engine.decompose(solid)
        guard components.count > 1 else {
            return (solid, 0, 0)
        }

        struct EvaluatedComponent {
            let handle: ManifoldHandle
            let volume: Double
            let bboxDiagonal: Double
        }

        func bboxDiagonal(of bounds: Bounds3D) -> Double {
            let dx = bounds.max.x - bounds.min.x
            let dy = bounds.max.y - bounds.min.y
            let dz = bounds.max.z - bounds.min.z
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        let evaluated = components.map { component in
            EvaluatedComponent(
                handle: component,
                volume: abs(engine.volume(component)),
                bboxDiagonal: bboxDiagonal(of: engine.bounds(component))
            )
        }
        let totalVolume = evaluated.reduce(0.0) { $0 + $1.volume }
        let volumeFloor = max(max(relFloor, 0) * totalVolume, max(absFloorMm3, 0))
        let diagonalFloor = max(minBBoxDiagonal, 0)

        var kept: [EvaluatedComponent] = []
        var droppedCount = 0
        var droppedVolume = 0.0
        kept.reserveCapacity(evaluated.count)

        for component in evaluated {
            let keep = component.volume >= volumeFloor && component.bboxDiagonal >= diagonalFloor
            if keep {
                kept.append(component)
            } else {
                droppedCount += 1
                droppedVolume += component.volume
            }
        }

        guard droppedCount > 0 else {
            return (solid, 0, 0)
        }

        if kept.isEmpty, let largest = evaluated.max(by: { $0.volume < $1.volume }) {
            droppedCount -= 1
            droppedVolume -= largest.volume
            return (largest.handle, max(droppedCount, 0), max(droppedVolume, 0))
        }

        let keptHandles = kept.map(\.handle)
        let keptSolid = keptHandles.count == 1 ? keptHandles[0] : try engine.union(keptHandles)
        return (keptSolid, droppedCount, droppedVolume)
    }
}

/// Errors specific to Structures planning (separate from `ManifoldEngineError`).
enum StructureEngineError: Error, Equatable {
    /// The selected sub-category has no engine in this build (e.g. Supports).
    case categoryNotImplemented(StructureCategory)
    /// The selected pattern has no generator wired yet.
    case patternNotImplemented(InfillPattern)
    /// The source mesh has no bounds (empty geometry).
    case missingBounds
    /// The source is not watertight and healing is a later workflow.
    case needsHealing
    /// Image density was selected without an image path.
    case missingDensityImagePath
    /// Image density was selected but AppKit/CoreGraphics could not decode it.
    case densityImageLoadFailed(String)
    /// The pattern generated no geometry at the current settings (typically a
    /// cell size larger than the model).
    case emptyPattern
    /// Scaffold supports found no overhang: every down-facing surface rests on
    /// the build plate.
    case nothingToSupport

    var userMessage: String {
        switch self {
        case .categoryNotImplemented(let c):
            return "\(c.label) generation is not yet available in this build."
        case .patternNotImplemented(let p):
            return "The \(p.label) infill pattern is not yet implemented."
        case .missingBounds:
            return "The model has no measurable bounds to fill."
        case .emptyPattern:
            return "These settings produced no geometry — Cell (or Min Cell) is likely larger than the model; reduce it and regenerate."
        case .nothingToSupport:
            return "Nothing on this model needs support: every down-facing surface already rests on the build plate."
        case .needsHealing:
            return "This model is not watertight; healing it for infill is not yet available."
        case .missingDensityImagePath:
            return "Image density needs a density image path."
        case .densityImageLoadFailed(let path):
            return "Could not load density image: \(path)"
        }
    }
}

// MARK: - OP ART (planar) generators
//
// Both Op-Art patterns are full-height VERTICAL walls whose XY footprint is a
// warped thin ribbon, extruded the full model height. Each wall is built from a
// centerline polyline by offsetting ±(wall/2) along the local 2D normal (the
// normal of the tangent estimated from neighbouring samples), forming a closed
// ribbon loop: the forward edge (centerline + half·normal) followed by the
// reverse edge (centerline − half·normal). The ribbons are extruded up Z by the
// full model height via `GyroidManifold.extrudeSlab` and unioned; the shared
// `StructureClipEngine` then clips the union to the model skin (unchanged).

/// Shared ribbon helpers for the Op-Art wall generators.
enum OpArtWallBuilder {
    /// Build a closed ribbon loop (XY) of constant width `wall` around a
    /// centerline polyline. The local normal at sample i is the perpendicular of
    /// the tangent estimated from neighbours (i-1, i+1). Returns nil for loops
    /// too short to extrude.
    static func ribbonLoop(centerline pts: [SIMD2<Double>], wall: Double) -> [SIMD2<Double>]? {
        guard pts.count >= 2 else { return nil }
        let half = wall / 2.0
        let n = pts.count
        var normals: [SIMD2<Double>] = []
        normals.reserveCapacity(n)
        for i in 0..<n {
            let prev = pts[max(i - 1, 0)]
            let next = pts[min(i + 1, n - 1)]
            var tan = SIMD2<Double>(next.x - prev.x, next.y - prev.y)
            let len = (tan.x * tan.x + tan.y * tan.y).squareRoot()
            if len < 1e-12 {
                tan = SIMD2<Double>(1, 0)
            } else {
                tan = SIMD2<Double>(tan.x / len, tan.y / len)
            }
            // normal = (-tangent.y, tangent.x)
            normals.append(SIMD2<Double>(-tan.y, tan.x))
        }
        var loop: [SIMD2<Double>] = []
        loop.reserveCapacity(n * 2)
        // Forward edge: centerline + half·normal.
        for i in 0..<n {
            loop.append(SIMD2<Double>(pts[i].x + half * normals[i].x,
                                      pts[i].y + half * normals[i].y))
        }
        // Reverse edge: centerline − half·normal (back down to close the ribbon).
        for i in stride(from: n - 1, through: 0, by: -1) {
            loop.append(SIMD2<Double>(pts[i].x - half * normals[i].x,
                                      pts[i].y - half * normals[i].y))
        }
        return loop
    }

    /// Extrude all ribbon loops the full model height and union them into one
    /// wall solid. `bounds` provides the Z extent (height = dz + 4, baseZ = lo.z − 2).
    static func extrudeAndUnion(
        ribbons: [[SIMD2<Double>]], bounds: Bounds3D, engine: ManifoldEngine.Type
    ) throws -> ManifoldHandle {
        let lo = bounds.min, hi = bounds.max
        let dz = hi.z - lo.z
        let height = dz + 4.0
        let baseZ = lo.z - 2.0
        var solids: [ManifoldHandle] = []
        solids.reserveCapacity(ribbons.count)
        for ribbon in ribbons where ribbon.count >= 3 {
            guard let prism = GyroidManifold.extrudeSlab(
                loops: [ribbon], height: height, baseZ: baseZ
            ) else { continue }
            solids.append(prism)
        }
        guard !solids.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(solids)
    }
}

/// OP ART — Stanczak ("double Focus"): straight vertical lines, each a thin
/// continuous spine carrying short raised dashes (beads). The dashes' vertical
/// PHASE sweeps across the field as a sine wave, so their alignment rolls in and
/// out of two focus bands — the optical vibration of Stanczak's line paintings.
/// The spine keeps every column welded; the dash phase is the op-art. Drawn as
/// full-height walls, clipped to the skin.
struct StanczakWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let frame = PlanarWallBuilder.frame(bounds)
        let lo = bounds.min, hi = bounds.max
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.05)
        let C = SIMD2<Double>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
        let width = hi.x - lo.x
        let ySpan = (hi.y - lo.y) + 2 * cell

        let dashPeriod = cell                      // one dash per cell up the column
        let beadLen = cell * 0.52                  // dash height (gaps between)
        let beadWidth = max(wall * 2.4, wall + 0.6) // dash sticks out past the spine
        let beadAmp = cell * 0.45                  // vertical phase swing
        let waveLen = max(width * 0.92, cell)      // ~one wave -> two focus turns

        let margin = cell
        let iLo = Int(((lo.x - margin - C.x) / cell).rounded(.down))
        let iHi = Int(((hi.x + margin - C.x) / cell).rounded(.up))
        let kLo = Int(((lo.y - margin - C.y) / dashPeriod).rounded(.down)) - 1
        let kHi = Int(((hi.y + margin - C.y) / dashPeriod).rounded(.up)) + 1

        var boxes: [ManifoldHandle] = []
        for i in iLo...iHi {
            let x = C.x + Double(i) * cell
            // thin continuous spine (keeps the column connected)
            boxes.append(try PlanarWallBuilder.wallBox(
                length: ySpan, thickness: wall, frame: frame,
                angleDeg: 90, posX: x, posY: C.y, engine: engine))
            // raised dashes, vertical phase waving across X
            let phase = beadAmp * sin(2 * Double.pi * (x - C.x) / waveLen)
            for k in kLo...kHi {
                let y = C.y + phase + Double(k) * dashPeriod
                boxes.append(try PlanarWallBuilder.wallBox(
                    length: beadLen, thickness: beadWidth, frame: frame,
                    angleDeg: 90, posX: x, posY: y, engine: engine))
            }
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// OP ART — Vasarely (Vega): the artist's signature sphere-bulge. A square grid
/// whose CELL SIZES swell toward a centre and compress around it — a radial
/// magnification that reads as a sphere pushing through the plane — with a circle
/// in every cell that grows and shrinks with its cell. The varying cell size IS
/// the illusion (not a uniform grid, not the AXO-3 cube). Grid lines + circles are
/// stroked to the wall slider, extruded full height, clipped to the skin.
struct VasarelyWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        let frame = PlanarWallBuilder.frame(bounds)
        let lo = bounds.min, hi = bounds.max
        let cell = max(params.cellSizeMm, 0.001)
        let wall = max(params.wallThicknessMm, 0.05)
        let C = SIMD2<Double>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)

        // Spherical (hemisphere) radial map: project the flat grid onto a dome of
        // half-angle θmax and back. Cells are LARGEST at the centre and shrink
        // smoothly toward the corners (which stay pinned), with no folding — the
        // signature Vega sphere-bulge. Bigger θmax = stronger bulge.
        let R = 0.5 * ((hi.x - lo.x) * (hi.x - lo.x) + (hi.y - lo.y) * (hi.y - lo.y)).squareRoot()
        let thetaMax = 1.43
        let sinTm = sin(thetaMax)
        @inline(__always) func mag(_ r: Double) -> Double {       // local cell scale = F'(r)
            (thetaMax / sinTm) * cos(min(r, R) / R * thetaMax)
        }
        @inline(__always) func scale(_ r: Double) -> Double {     // F(r)/r
            if r < 1e-6 { return thetaMax / sinTm }
            return R * sin(min(r, R) / R * thetaMax) / sinTm / r
        }
        @inline(__always) func warp(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let d = p - C
            return C + d * scale((d.x * d.x + d.y * d.y).squareRoot())
        }

        // Grid spans the section plus a couple cells so the clip trims cleanly.
        let nx = Int((max(hi.x - lo.x, hi.y - lo.y) / cell).rounded(.up)) + 4
        let step = cell / 6.0     // sample fine; the warp curves the lines
        var boxes: [ManifoldHandle] = []

        @inline(__always) func segment(_ a: SIMD2<Double>, _ b: SIMD2<Double>) throws {
            let dx = b.x - a.x, dy = b.y - a.y
            let L = (dx * dx + dy * dy).squareRoot()
            if L < 1e-6 { return }
            boxes.append(try PlanarWallBuilder.wallBox(
                length: L + wall, thickness: wall, frame: frame,
                angleDeg: atan2(dy, dx) * 180 / .pi, posX: (a.x + b.x) / 2, posY: (a.y + b.y) / 2, engine: engine))
        }

        // Warped grid: vertical lines x = C.x + i*cell, horizontal y = C.y + j*cell.
        for i in -nx...nx {
            let gx = C.x + Double(i) * cell
            var prev = warp(SIMD2<Double>(gx, C.y - Double(nx) * cell))
            var t = -Double(nx) * cell + step
            while t <= Double(nx) * cell {
                let cur = warp(SIMD2<Double>(gx, C.y + t)); try segment(prev, cur); prev = cur; t += step
            }
        }
        for j in -nx...nx {
            let gy = C.y + Double(j) * cell
            var prev = warp(SIMD2<Double>(C.x - Double(nx) * cell, gy))
            var t = -Double(nx) * cell + step
            while t <= Double(nx) * cell {
                let cur = warp(SIMD2<Double>(C.x + t, gy)); try segment(prev, cur); prev = cur; t += step
            }
        }

        // A circle in every cell, scaled by the local magnification so it bulges
        // with its cell. Radius ~0.47*localSpacing touches the grid (stays welded).
        let sides = 14
        for i in -nx...nx {
            for j in -nx...nx {
                let cn = SIMD2<Double>(C.x + (Double(i) + 0.5) * cell, C.y + (Double(j) + 0.5) * cell)
                let d = cn - C
                let m = mag((d.x * d.x + d.y * d.y).squareRoot())
                let center = warp(cn)
                let radius = 0.36 * cell * m
                var prev = SIMD2<Double>(center.x + radius, center.y)
                for s in 1...sides {
                    let ang = 2 * Double.pi * Double(s) / Double(sides)
                    let cur = SIMD2<Double>(center.x + radius * cos(ang), center.y + radius * sin(ang))
                    try segment(prev, cur); prev = cur
                }
            }
        }

        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try engine.union(boxes)
    }
}

/// OP ART — Riley Movement-in-Squares: a checker field whose column widths are
/// placed by cumulative-integral spacing. The default preset grades left-to-right;
/// image/attractor/near-surface density can override the column spacing.
struct RileySquaresWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let frame = PlanarWallBuilder.frame(bounds)
        let lo = bounds.min, hi = bounds.max
        let cell = max(context.params.cellSizeMm, 0.001)
        let wall = max(context.params.wallThicknessMm, 0.05)
        let margin = cell
        let density = context.density.isUniform
            ? DensityField.linearDensityRamp(
                axis: .x,
                lo: lo.x - margin,
                hi: hi.x + margin,
                startDensity: 1.0 / (cell * 1.6),
                endDensity: 1.0 / max(cell * 0.65, 1.0)
            )
            : context.density

        let xStops = VariableSpacing.linePositions(
            field: density,
            axis: .x,
            lo: lo.x - margin,
            hi: hi.x + margin
        ) { x in
            SIMD3<Double>(x, frame.center.y, frame.center.z)
        }
        var xEdges = [lo.x - margin] + xStops + [hi.x + margin]
        xEdges.sort()

        let yStart = lo.y - margin
        let yEnd = hi.y + margin
        let rowCount = max(1, Int(((yEnd - yStart) / cell).rounded(.up)))
        let rowHeight = (yEnd - yStart) / Double(rowCount)
        let gap = max(wall, min(cell * 0.16, rowHeight * 0.35))

        var boxes: [ManifoldHandle] = []
        for col in 0..<(xEdges.count - 1) {
            let x0 = xEdges[col]
            let x1 = xEdges[col + 1]
            let width = x1 - x0
            guard width > gap * 1.5 else { continue }
            let shift = sin(Double(col) * 0.72) * rowHeight * 0.35
            for row in 0..<rowCount where (row + col).isMultiple(of: 2) {
                let y0 = yStart + Double(row) * rowHeight + shift
                let y1 = y0 + rowHeight
                let w = max(width - gap, wall)
                let h = max(rowHeight - gap, wall)
                boxes.append(try context.engine.box(ManifoldBoxSpec(
                    center: Vec3(x: (x0 + x1) * 0.5, y: (y0 + y1) * 0.5, z: frame.center.z),
                    extents: Vec3(x: w, y: h, z: frame.zLen)
                )))
            }
        }
        guard !boxes.isEmpty else { throw StructureEngineError.missingBounds }
        return try context.engine.union(boxes)
    }
}

/// OP ART — Graded Rings: concentric circular ribbons with radii placed by the
/// same cumulative-integral rule as variable line families.
struct GradedRingsWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let frame = PlanarWallBuilder.frame(bounds)
        let cell = max(context.params.cellSizeMm, 0.001)
        let wall = max(context.params.wallThicknessMm, 0.05)
        let center = SIMD2<Double>(frame.center.x, frame.center.y)
        let maxRadius = frame.diag2D * 0.62 + cell
        let density = context.density.isUniform
            ? DensityField.linearDensityRamp(
                axis: .x,
                lo: wall,
                hi: maxRadius,
                startDensity: 1.0 / (cell * 1.5),
                endDensity: 1.0 / max(cell * 0.55, 1.0)
            )
            : context.density

        let radii = VariableSpacing.linePositions(
            field: density,
            axis: .x,
            lo: max(wall, cell * 0.35),
            hi: maxRadius
        ) { r in
            SIMD3<Double>(center.x + r, center.y, frame.center.z)
        }

        var ribbons: [[SIMD2<Double>]] = []
        ribbons.reserveCapacity(radii.count)
        for r in radii where r > wall {
            let sides = min(160, max(32, Int((2.0 * Double.pi * r / max(wall * 2.0, 1.0)).rounded(.up))))
            var line: [SIMD2<Double>] = []
            line.reserveCapacity(sides + 1)
            for i in 0...sides {
                let a = 2.0 * Double.pi * Double(i) / Double(sides)
                line.append(SIMD2<Double>(center.x + r * cos(a), center.y + r * sin(a)))
            }
            if let ribbon = OpArtWallBuilder.ribbonLoop(centerline: line, wall: wall) {
                ribbons.append(ribbon)
            }
        }
        return try OpArtWallBuilder.extrudeAndUnion(ribbons: ribbons, bounds: bounds, engine: context.engine)
    }
}

/// OP ART — Wave Grating: variable-spaced vertical ribbons with sinusoidal
/// transverse displacement.
struct WaveGratingWallSolidGenerator: WallSolidGenerator {
    func makeWallSolid(bounds: Bounds3D, params: InfillParameters, engine: ManifoldEngine.Type) throws -> ManifoldHandle {
        try makeWallSolid(uniformContext(bounds: bounds, params: params, engine: engine))
    }

    func makeWallSolid(_ context: WallSolidContext) throws -> ManifoldHandle {
        let bounds = context.bounds
        let frame = PlanarWallBuilder.frame(bounds)
        let lo = bounds.min, hi = bounds.max
        let cell = max(context.params.cellSizeMm, 0.001)
        let wall = max(context.params.wallThicknessMm, 0.05)
        let margin = cell * 1.5
        let density = context.density.isUniform
            ? DensityField.uniform(cellSizeMm: cell)
            : context.density
        let xPositions = VariableSpacing.linePositions(
            field: density,
            axis: .x,
            lo: lo.x - margin,
            hi: hi.x + margin
        ) { x in
            SIMD3<Double>(x, frame.center.y, frame.center.z)
        }

        let y0 = lo.y - margin
        let y1 = hi.y + margin
        let samples = max(20, Int(((y1 - y0) / max(cell / 5.0, wall)).rounded(.up)))
        let amplitude = min(cell * 0.42, max(frame.dx, frame.dy) * 0.12)
        let waveLength = max(cell * 3.0, frame.dy * 0.72)
        var ribbons: [[SIMD2<Double>]] = []
        ribbons.reserveCapacity(xPositions.count)
        for (i, xBase) in xPositions.enumerated() {
            let phase = Double(i).truncatingRemainder(dividingBy: 4.0) * Double.pi / 3.0
            var line: [SIMD2<Double>] = []
            line.reserveCapacity(samples + 1)
            for s in 0...samples {
                let t = Double(s) / Double(samples)
                let y = y0 + (y1 - y0) * t
                let x = xBase + amplitude * sin(2.0 * Double.pi * (y - y0) / waveLength + phase)
                line.append(SIMD2<Double>(x, y))
            }
            if let ribbon = OpArtWallBuilder.ribbonLoop(centerline: line, wall: wall) {
                ribbons.append(ribbon)
            }
        }
        return try OpArtWallBuilder.extrudeAndUnion(ribbons: ribbons, bounds: bounds, engine: context.engine)
    }
}

/// Entry point kept stable across the rebuild. The flat-modes / viewport / CLI
/// all call `StructurePlanner.plan(model:settings:)`. It delegates to the
/// pluggable generators below.
///
/// The triangle infill engine is wired here: `.infill` + `.triangle` builds the
/// wall lattice, clips it to the source skin, and returns a watertight grouped
/// mesh. Other categories/patterns surface a typed "not implemented" reason.
enum StructurePlanner {
    /// Map a pattern to its wall-solid generator, or nil when none is wired.
    static func generator(for pattern: InfillPattern) -> WallSolidGenerator? {
        switch pattern {
        // PLANAR
        case .triangle: return TriangleWallSolidGenerator()
        case .grid: return GridWallSolidGenerator()
        case .triHexagon: return TriHexagonWallSolidGenerator()
        case .cross: return CrossWallSolidGenerator()
        case .concentric: return ConcentricWallSolidGenerator()
        // LATTICE
        case .cubic: return CubicWallSolidGenerator()
        case .octet: return OctetWallSolidGenerator()
        case .quarterCubic: return QuarterCubicWallSolidGenerator()
        case .cubicSubdivision: return CubicSubdivisionWallSolidGenerator()
        case .cross3D: return Cross3DWallSolidGenerator()
        // TPMS
        case .gyroidLofted: return GyroidLoftedWallSolidGenerator()
        case .gyroidTiled: return GyroidTiledWallSolidGenerator()
        case .gyroidNetwork: return GyroidNetworkWallSolidGenerator()
        case .gradedGyroid: return GradedGyroidWallSolidGenerator()
        // OP ART
        case .stanczak: return StanczakWallSolidGenerator()
        case .vasarely: return VasarelyWallSolidGenerator()
        case .rileySquares: return RileySquaresWallSolidGenerator()
        case .gradedRings: return GradedRingsWallSolidGenerator()
        case .waveGrating: return WaveGratingWallSolidGenerator()
        }
    }

    /// Build a Structures plan, or return `nil` when nothing can be generated.
    ///
    /// Fail-soft: any engine error is mapped to `nil` (surfaced to the UI banner
    /// / CLI by the caller) rather than crashing or emitting a bad mesh.
    static func plan(model: MeshSummary, settings: StructureSettings) -> StructureMeshPlan? {
        do {
            return try planThrowing(model: model, settings: settings)
        } catch {
            return nil
        }
    }

    /// Throwing core so callers that want the typed reason (UI banner / CLI
    /// message) can catch it. Returns nil only when there is legitimately no
    /// geometry to make.
    static func planThrowing(model: MeshSummary, settings: StructureSettings) throws -> StructureMeshPlan? {
        guard settings.category.isImplemented else {
            throw StructureEngineError.categoryNotImplemented(settings.category)
        }
        guard let bounds = model.bounds else {
            throw StructureEngineError.missingBounds
        }
        if settings.category == .support {
            return try supportPlan(model: model, bounds: bounds, settings: settings.sanitized)
        }
        if settings.category == .skin {
            return try skinPlan(model: model, bounds: bounds, settings: settings.sanitized)
        }
        guard let generator = generator(for: settings.pattern) else {
            throw StructureEngineError.patternNotImplemented(settings.pattern)
        }

        let safe = settings.sanitized
        let density = try densityField(
            for: safe,
            bounds: bounds,
            sourceVertices: model.geometry.vertices
        )
        let clipResult = try StructureClipEngine.clippedInfillResult(
            source: model.geometry,
            bounds: bounds,
            params: safe.parameters,
            generator: generator,
            density: density
        )
        let mesh = clipResult.mesh
        guard !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty else {
            // The model HAS bounds (we clipped against them) — the PATTERN came
            // out empty, which is a settings problem, not a model problem.
            throw StructureEngineError.emptyPattern
        }

        // Curved surfaces (gyroid TPMS sheets AND the round-strut lattices, both
        // built from implicit fields) MUST be smooth-shaded: per-face flat normals
        // make a smooth surface look chaotically faceted even though the geometry
        // is smooth. Planar wall patterns (Grid/Triangle/…) keep flat shading; they
        // have genuine sharp edges. The boolean clip provides crisp model-skin
        // boundaries either way.
        let curved = safe.pattern.family == .tpms || safe.pattern.family == .lattice
        let render = curved
            ? ViewportMeshRenderData.smoothShadedMesh(from: mesh)
            : ViewportMeshRenderData.flatShadedMesh(from: mesh)
        let layer = SliceMeshExportLayer(
            name: "\(safe.pattern.label) Infill",
            mesh: render
        )
        let combinedNotice = [clipResult.wallSolidNotice, clipResult.clipFidelityNotice]
            .compactMap { $0 }
            .joined(separator: " ")
        return StructureMeshPlan(
            settings: safe,
            layers: [layer],
            coarseningNotice: combinedNotice.isEmpty ? nil : combinedNotice,
            preClipDroppedCount: clipResult.preClipDroppedCount,
            preClipDroppedVolume: clipResult.preClipDroppedVolume,
            postClipDroppedCount: clipResult.postClipDroppedCount,
            postClipDroppedVolume: clipResult.postClipDroppedVolume
        )
    }

    private static func supportPlan(
        model: MeshSummary,
        bounds: Bounds3D,
        settings: StructureSettings
    ) throws -> StructureMeshPlan {
        var supportSettings = settings.support.sanitized
        if supportSettings.supportMode == .scaffold {
            supportSettings.targetSurface = .downFacing
        }
        // Sample targets from the SOLIDIFIED mesh whenever possible: Manifold
        // guarantees outward winding, so up/down-facing classification needs no
        // convex-centric orientation heuristic (which misclassifies overhang
        // undersides — they face the model interior by definition).
        let orientationSolid = try? ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))
        let orientedGeometry = orientationSolid
            .flatMap { try? ManifoldEngine.toMesh($0) }
            .map { SupportSurfaceSampler.ensureOutwardWinding($0) }
        var samples = SupportSurfaceSampler.samples(
            on: orientedGeometry ?? model.geometry,
            settings: supportSettings,
            seed: settings.parameters.seed,
            trustWinding: orientedGeometry != nil
        )
        guard !samples.isEmpty else { throw StructureEngineError.missingBounds }
        if supportSettings.supportMode == .scaffold {
            // A down-facing surface closer to the plate than a tip and its
            // contact gap rests on the plate: there is no room under it for a
            // support, so it is not an overhang (a cube's base, a stand's foot).
            let plateClearance = supportSettings.contactOffsetMm + supportSettings.tipDiameterMm
            samples.removeAll { $0.position.z - bounds.min.z < plateClearance }
            guard !samples.isEmpty else { throw StructureEngineError.nothingToSupport }
        }
        let buildSamples: [SupportSurfaceSample]
        if supportSettings.supportMode == .scaffold {
            // contactOffset is a SURFACE-to-surface gap: displace the tip CENTER
            // by offset + tip radius, otherwise the tip sphere penetrates the
            // overhang by (radius − offset) and the intersection metric can
            // never honestly read ~0.
            let standoff = supportSettings.contactOffsetMm + supportSettings.tipDiameterMm * 0.5
            buildSamples = samples.map {
                SupportSurfaceSample(
                    position: Vec3(
                        x: $0.position.x,
                        y: $0.position.y,
                        z: $0.position.z - standoff
                    ),
                    normal: $0.normal
                )
            }
        } else {
            buildSamples = samples
        }
        let sourceSolid: ManifoldHandle?
        if supportSettings.supportMode == .scaffold {
            sourceSolid = try orientationSolid
                ?? ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry))
        } else {
            sourceSolid = nil
        }
        let avoidance = sourceSolid.map {
            AvoidanceVolumes(solid: $0, stepMm: supportSettings.stepMm)
        }
        let build = SupportTreeBuilder.build(
            samples: buildSamples,
            bounds: bounds,
            settings: supportSettings,
            seed: settings.parameters.seed,
            avoidance: avoidance
        )
        let solidified = try SupportSolidifier.solidify(nodes: build.nodes, settings: supportSettings)
        var solid = solidified.solid
        let simplifyNotice = solidified.notice
        var supportAudit = build.audit
        var tunnelNotice: String?
        if supportSettings.supportMode == .scaffold, let sourceSolid {
            // HONESTY ORDER MATTERS: measure the planner's model intersection on
            // the RAW branch solid BEFORE the difference clip — measuring after
            // (as shipped 2026-07-02) is a tautology that reads ~0 no matter how
            // badly branches tunnel through the model.
            let rawIntersection = try ManifoldEngine.intersect(solid, sourceSolid)
            supportAudit.modelIntersectionVolume = abs(ManifoldEngine.volume(rawIntersection))
            withExtendedLifetime(rawIntersection) {}

            let trimmed = try? ManifoldEngine.difference(solid, sourceSolid)
            if let trimmed, !ManifoldEngine.isEmpty(trimmed) {
                solid = trimmed
            }

            supportAudit.overhangCoverage = SupportAuditMetrics.surfaceCoverage(
                targets: samples,
                tips: build.tips,
                maxDistance: supportSettings.contactOffsetMm + supportSettings.tipDiameterMm + 0.01
            )

            // Solid-derived rest accounting: the graph's blocked-chain counter
            // misses chains the clip severed (they tunneled through the model).
            // The exported SOLID is the truth — count its non-plate components.
            let graphRests = supportAudit.restOnModelCount
            let components = (try? ManifoldEngine.decompose(solid)) ?? []
            let plateTolerance = max(supportSettings.stepMm * 0.5, 0.5)
            let plateComponents = components.filter {
                ManifoldEngine.bounds($0).min.z <= bounds.min.z + plateTolerance
            }.count
            let solidRests = max(components.count - plateComponents, 0)
            if solidRests > graphRests {
                tunnelNotice = "\(solidRests - graphRests) branch chain(s) were severed by the model and rest on its surface — the planner routed them through solid geometry."
            }
            supportAudit.restOnModelCount = max(graphRests, solidRests)
        }
        let mesh = try ManifoldEngine.toMesh(solid)
        guard !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty else {
            throw StructureEngineError.missingBounds
        }
        let render = ViewportMeshRenderData.smoothShadedMesh(from: mesh)
        let layer = SliceMeshExportLayer(
            name: supportSettings.supportMode == .scaffold ? "Organic Scaffold Supports" : "Organic Sculpture Supports",
            mesh: render
        )
        let restNotice = supportAudit.restOnModelCount > 0
            ? "Scaffold rested \(supportAudit.restOnModelCount) branch chain(s) on the model."
            : nil
        let combinedNotice = [build.coarseningNotice, simplifyNotice, restNotice, tunnelNotice].compactMap { $0 }.joined(separator: " ")
        var finalSettings = settings
        finalSettings.support = supportSettings
        return StructureMeshPlan(
            settings: finalSettings,
            layers: [layer],
            coarseningNotice: combinedNotice.isEmpty ? nil : combinedNotice,
            supportAudit: supportAudit
        )
    }

    private static func skinPlan(
        model: MeshSummary,
        bounds: Bounds3D,
        settings: StructureSettings
    ) throws -> StructureMeshPlan {
        let safe = settings.sanitized
        guard safe.skin.skinStyle == .struts else {
            throw StructureEngineError.categoryNotImplemented(.skin)
        }
        let density = try densityField(
            for: safe,
            bounds: bounds,
            sourceVertices: model.geometry.vertices
        )
        let seeds = SurfaceSampler.seeds(
            onSurfaceOf: model.geometry,
            density: density,
            seed: safe.parameters.seed,
            variation: safe.skin.variationPct
        )
        guard seeds.count > 1 else { throw StructureEngineError.missingBounds }
        let network: [Polyline3D]
        switch safe.skin.skinPattern {
        case .triangles:
            network = SurfaceCellNetwork.delaunayEdges(mesh: model.geometry, seeds: seeds)
        case .voronoi, .hex:
            network = SurfaceCellNetwork.voronoiEdges(mesh: model.geometry, seeds: seeds)
        }
        guard !network.isEmpty else { throw StructureEngineError.missingBounds }
        let built = try SkinShellBuilder.buildStruts(
            network: network,
            settings: safe.skin,
            seed: safe.parameters.seed,
            meanCellMm: safe.parameters.cellSizeMm
        )
        // Optional clip: struts are centered on the surface; Inside keeps the
        // embedded half (flush cage), Outside keeps the protruding half (jacket).
        var skinSolid = built.solid
        var clipNotice: String?
        if safe.skin.skinClip != .none {
            if let sourceSolid = try? ManifoldEngine.make(from: StructureClipEngine.welded(model.geometry)) {
                let clipped: ManifoldHandle? = safe.skin.skinClip == .inside
                    ? try? ManifoldEngine.intersect(skinSolid, sourceSolid)
                    : try? ManifoldEngine.difference(skinSolid, sourceSolid)
                if let clipped, !ManifoldEngine.isEmpty(clipped) {
                    skinSolid = clipped
                } else {
                    clipNotice = "Skin clip produced no geometry; showing the unclipped cage."
                }
                withExtendedLifetime(sourceSolid) {}
            } else {
                clipNotice = "Skin clip skipped: the model could not be solidified (repair it first)."
            }
        }
        // Broken scans (open edges/degenerate triangles) can strand a few tiny
        // strut clusters off the main cage — drop sub-1% debris so the skin
        // exports as one printable piece. Genuinely disjoint model parts keep
        // their cages (each is far above the relative floor).
        let strutRadius = max(safe.skin.strutDiameterMm * 0.5, 0.05)
        let capsuleVolume = (4.0 / 3.0) * Double.pi * strutRadius * strutRadius * strutRadius
        let filtered = try ComponentFilter.filterSpecks(
            skinSolid,
            engine: ManifoldEngine.self,
            relFloor: 0.01,
            absFloorMm3: capsuleVolume * 4.0,
            minBBoxDiagonal: safe.skin.strutDiameterMm * 2.0
        )
        let mesh = try ManifoldEngine.toMesh(filtered.0)
        guard !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty else {
            throw StructureEngineError.missingBounds
        }
        let debrisNotice: String? = filtered.droppedCount > 0
            ? String(format: "Removed %d stray skin fragment(s) (%.1f mm³) near open-edge regions.",
                     filtered.droppedCount, filtered.droppedVolume)
            : nil
        let render = ViewportMeshRenderData.smoothShadedMesh(from: mesh)
        let spacing = meanNearestSeedSpacing(seeds)
        let audit = SkinAudit(
            seedCount: seeds.count,
            cellCount: seeds.count,
            segmentCount: network.count,
            meanSpacing: spacing,
            componentCount: (try? ManifoldEngine.decompose(filtered.0).count) ?? 0,
            genus: ManifoldEngine.genus(filtered.0)
        )
        let combinedNotice = [built.notice, clipNotice, debrisNotice].compactMap { $0 }.joined(separator: " ")
        return StructureMeshPlan(
            settings: safe,
            layers: [SliceMeshExportLayer(name: "\(safe.skin.skinPattern.label) Skin", mesh: render)],
            coarseningNotice: combinedNotice.isEmpty ? nil : combinedNotice,
            skinAudit: audit
        )
    }

    private static func meanNearestSeedSpacing(_ seeds: [SurfaceSeed]) -> Double {
        guard seeds.count > 1 else { return 0 }
        var total = 0.0
        for (index, seed) in seeds.enumerated() {
            var best = Double.greatestFiniteMagnitude
            for (otherIndex, other) in seeds.enumerated() where otherIndex != index {
                let dx = seed.position.x - other.position.x
                let dy = seed.position.y - other.position.y
                let dz = seed.position.z - other.position.z
                best = min(best, (dx * dx + dy * dy + dz * dz).squareRoot())
            }
            total += best
        }
        return total / Double(seeds.count)
    }

    private static func densityField(
        for settings: StructureSettings,
        bounds: Bounds3D,
        sourceVertices: [Vec3]
    ) throws -> DensityField {
        let density = settings.density
        switch settings.effectiveDensitySource {
        case .uniform:
            return .uniform(cellSizeMm: settings.parameters.cellSizeMm)
        case .image:
            guard let imagePath = density.imagePath, !imagePath.isEmpty else {
                throw StructureEngineError.missingDensityImagePath
            }
            let url = URL(fileURLWithPath: imagePath)
            guard let image = NSImage(contentsOf: url) else {
                throw StructureEngineError.densityImageLoadFailed(imagePath)
            }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let field = DensityField.image(
                    cgImage,
                    bounds: bounds,
                    projection: density.imageProjection,
                    minCellMm: density.minCellMm,
                    maxCellMm: density.maxCellMm,
                    invert: density.invertImage
                  ) else {
                throw StructureEngineError.densityImageLoadFailed(imagePath)
            }
            return field
        case .attractors:
            return .attractor(
                point: attractorPoint(for: density.attractorPreset, custom: density.customAttractorPoint, bounds: bounds),
                falloffMm: density.falloffMm,
                minCellMm: density.minCellMm,
                maxCellMm: density.maxCellMm
            )
        case .nearSurface:
            return .nearSurface(
                sourceVertices: sourceVertices,
                bandMm: density.nearSurfaceBandMm,
                minCellMm: density.minCellMm,
                maxCellMm: density.maxCellMm
            )
        }
    }

    private static func attractorPoint(
        for preset: StructureAttractorPreset,
        custom: Vec3,
        bounds: Bounds3D
    ) -> Vec3 {
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        switch preset {
        case .center:
            return center
        case .top:
            return Vec3(x: center.x, y: center.y, z: bounds.max.z)
        case .bottom:
            return Vec3(x: center.x, y: center.y, z: bounds.min.z)
        case .custom:
            return custom
        }
    }
}
