import Foundation

// MARK: - Plan result

/// One printable piece: a watertight sub-mesh plus its measured size and whether
/// that size fits the configured build volume (under the best axis orientation).
struct PartitionPiece: Equatable {
    var name: String
    var mesh: ViewportFlatShadedMesh
    var bounds: Bounds3D
    var fitsBuildVolume: Bool

    var size: Vec3 {
        Vec3(x: bounds.max.x - bounds.min.x, y: bounds.max.y - bounds.min.y, z: bounds.max.z - bounds.min.z)
    }

    var center: Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }
}

/// One cut interface between two pieces, with its key outcome.
struct PartitionSeam: Equatable {
    var keyed: Bool
    var pinCount: Int
}

/// The planned partition: pieces (in true model coordinates), seams, and any
/// warnings. `layers` exposes the same `[SliceMeshExportLayer]` shape the OBJ/STL
/// exporters and the RealityKit viewport already consume for Structures/3D.
struct PartitionMeshPlan: Equatable {
    var settings: PartitionSettings
    var pieces: [PartitionPiece]
    var seams: [PartitionSeam]
    var warnings: [String]
    var modelBounds: Bounds3D?

    var layers: [SliceMeshExportLayer] {
        pieces.map { SliceMeshExportLayer(name: $0.name, mesh: $0.mesh) }
    }

    var triangleCount: Int {
        pieces.reduce(0) { $0 + $1.mesh.triangleIndices.count / 3 }
    }

    var oversizedCount: Int { pieces.filter { !$0.fitsBuildVolume }.count }
    var keyedSeamCount: Int { seams.filter(\.keyed).count }
    var unkeyableSeamCount: Int { seams.filter { !$0.keyed }.count }

    var bounds: Bounds3D? {
        var lo: Vec3?
        var hi: Vec3?
        for piece in pieces {
            for v in piece.mesh.vertices {
                if let l = lo, let h = hi {
                    lo = Vec3(x: min(l.x, v.x), y: min(l.y, v.y), z: min(l.z, v.z))
                    hi = Vec3(x: max(h.x, v.x), y: max(h.y, v.y), z: max(h.z, v.z))
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

// MARK: - Planner

enum PartitionPlanner {
    static func plan(model: MeshSummary, settings rawSettings: PartitionSettings) -> PartitionMeshPlan? {
        let settings = rawSettings.sanitized
        guard let bounds = model.bounds else { return nil }

        let planeList = effectivePlanes(bounds: bounds, settings: settings)
        let soup = PartitionGeometry.triangleSoup(model)
        guard !soup.isEmpty else { return nil }

        // Nudge each plane off any model vertex it grazes, so a cut that lands
        // exactly on a vertex/edge (sd == 0) can't corrupt the section/cap and
        // produce a non-watertight piece. The shift is sub-micron — invisible.
        let planes = planeList.map { nudgedOffPlaneVertices($0, soup: soup) }

        var workPieces: [[(Vec3, Vec3, Vec3)]] = [soup]
        var seams: [PartitionSeam] = []
        var warnings: [String] = []

        for plane in planes {
            var next: [[(Vec3, Vec3, Vec3)]] = []
            for piece in workPieces {
                guard planeCrosses(piece, plane: plane) else {
                    next.append(piece)
                    continue
                }
                let negative = PartitionGeometry.clipHalfSpace(piece, plane: plane, keepPositive: false)
                let positive = PartitionGeometry.clipHalfSpace(piece, plane: plane, keepPositive: true)
                guard !negative.isEmpty, !positive.isEmpty else {
                    next.append(piece)
                    continue
                }
                let loops = PartitionGeometry.sectionLoops(piece, plane: plane)
                guard !loops.isEmpty else {
                    next.append(piece)
                    continue
                }

                // Classify loops into outer-with-holes islands so hollow/tubular
                // sections keep their voids, then cap (with keys where they fit).
                let islands = PartitionGeometry.islands(from: loops, plane: plane)
                let capped = PartitionKeys.capInterface(
                    islands: islands,
                    plane: plane,
                    key: settings.key,
                    maleSoup: negative,
                    femaleSoup: positive
                )
                let male = negative + capped.male       // `<= d` side, cut face toward +n
                let female = positive + capped.female    // `>= d` side, cut face toward -n
                let pinCount = capped.placements.count

                seams.append(PartitionSeam(keyed: settings.key.type != .none && pinCount > 0, pinCount: pinCount))
                next.append(male)
                next.append(female)
            }
            workPieces = next
        }

        // Grid-label naming needs the per-axis cut positions. Only axis-aligned
        // planes map to a clean grid; if any cut is tilted we fall back.
        var axisCuts: [[Double]] = [[], [], []]
        var hasTiltedCut = false
        for plane in planes {
            if let axis = axisIndex(of: plane.n) {
                axisCuts[axis].append(plane.d)
            } else {
                hasTiltedCut = true
            }
        }
        axisCuts = axisCuts.map { $0.sorted() }

        let effectiveBed = effectiveBedDimensions(settings)
        var pieces: [PartitionPiece] = []
        for (index, triangles) in workPieces.enumerated() {
            guard let pieceBounds = PartitionGeometry.bounds(triangles) else { continue }
            let mesh = PartitionGeometry.flatShadedMesh(triangles)
            let center = Vec3(
                x: (pieceBounds.min.x + pieceBounds.max.x) / 2,
                y: (pieceBounds.min.y + pieceBounds.max.y) / 2,
                z: (pieceBounds.min.z + pieceBounds.max.z) / 2
            )
            let fits = fitsBed(
                size: Vec3(
                    x: pieceBounds.max.x - pieceBounds.min.x,
                    y: pieceBounds.max.y - pieceBounds.min.y,
                    z: pieceBounds.max.z - pieceBounds.min.z
                ),
                bed: effectiveBed
            )
            pieces.append(
                PartitionPiece(
                    name: pieceName(index: index, center: center, settings: settings, axisCuts: axisCuts, hasTiltedCut: hasTiltedCut),
                    mesh: mesh,
                    bounds: pieceBounds,
                    fitsBuildVolume: fits
                )
            )
        }

        if settings.key.type != .none, seams.contains(where: { !$0.keyed }) {
            let count = seams.filter { !$0.keyed }.count
            warnings.append("\(count) seam\(count == 1 ? "" : "s") too thin for a key — those will need glue.")
        }
        let oversized = pieces.filter { !$0.fitsBuildVolume }.count
        if oversized > 0 {
            warnings.append("\(oversized) piece\(oversized == 1 ? "" : "s") still exceed the build volume.")
        }
        if pieces.count == 1 {
            warnings.append("Model already fits — no cuts needed.")
        }

        return PartitionMeshPlan(
            settings: settings,
            pieces: pieces,
            seams: seams,
            warnings: warnings,
            modelBounds: bounds
        )
    }

    // MARK: - Plane sets

    /// The plane set actually applied: Auto-fit computes axis-aligned planes from
    /// the build volume; Manual uses the stored user planes.
    static func effectivePlanes(bounds: Bounds3D, settings: PartitionSettings) -> [PartitionGeometry.PlaneEq] {
        let planes: [PartitionPlane]
        switch settings.mode {
        case .autoFit:
            planes = autoFitPlanes(bounds: bounds, settings: settings)
        case .manual:
            planes = settings.manualPlanes
        }
        return planes.map { PartitionGeometry.PlaneEq(normal: $0.normal, offset: $0.offset) }
    }

    /// Axis-aligned grid planes sized so each cell fits the build volume.
    static func autoFitPlanes(bounds: Bounds3D, settings: PartitionSettings) -> [PartitionPlane] {
        let lo = [bounds.min.x, bounds.min.y, bounds.min.z]
        let hi = [bounds.max.x, bounds.max.y, bounds.max.z]
        let allowance = settings.key.allowance
        let normals = [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1)]
        var planes: [PartitionPlane] = []
        for axis in 0..<3 {
            let span = hi[axis] - lo[axis]
            guard span > 1.0e-6 else { continue }
            let fit = max(5.0, settings.buildVolume.extent(forAxis: axis) - 2 * settings.bedMargin - allowance)
            let count = max(1, Int((span / fit).rounded(.up)))
            guard count > 1 else { continue }
            for i in 1..<count {
                let position: Double
                switch settings.autoStrategy {
                case .evenSizes:
                    position = lo[axis] + span * Double(i) / Double(count)
                case .fewestParts:
                    // Greedy: pack pieces at the bed limit, leaving the remainder last.
                    position = min(lo[axis] + fit * Double(i), hi[axis] - 1.0e-3)
                }
                planes.append(PartitionPlane(normal: normals[axis], offset: position, isManual: false))
            }
        }
        return planes
    }

    // MARK: - Helpers

    private static func planeCrosses(_ triangles: [(Vec3, Vec3, Vec3)], plane: PartitionGeometry.PlaneEq) -> Bool {
        guard let b = PartitionGeometry.bounds(triangles) else { return false }
        var hasPos = false
        var hasNeg = false
        for x in [b.min.x, b.max.x] {
            for y in [b.min.y, b.max.y] {
                for z in [b.min.z, b.max.z] {
                    let s = PartitionGeometry.signed(Vec3(x: x, y: y, z: z), plane)
                    if s > 1.0e-7 { hasPos = true }
                    if s < -1.0e-7 { hasNeg = true }
                }
            }
        }
        return hasPos && hasNeg
    }

    static func effectiveBedDimensions(_ settings: PartitionSettings) -> Vec3 {
        Vec3(
            x: max(1, settings.buildVolume.width - 2 * settings.bedMargin),
            y: max(1, settings.buildVolume.depth - 2 * settings.bedMargin),
            z: max(1, settings.buildVolume.height - 2 * settings.bedMargin)
        )
    }

    /// A piece fits if its sorted dimensions all fit the sorted bed dimensions —
    /// i.e. it fits under the best axis orientation for printing.
    static func fitsBed(size: Vec3, bed: Vec3) -> Bool {
        let s = [size.x, size.y, size.z].sorted(by: >)
        let b = [bed.x, bed.y, bed.z].sorted(by: >)
        return s[0] <= b[0] + 1.0e-6 && s[1] <= b[1] + 1.0e-6 && s[2] <= b[2] + 1.0e-6
    }

    private static func pieceName(
        index: Int,
        center: Vec3,
        settings: PartitionSettings,
        axisCuts: [[Double]],
        hasTiltedCut: Bool
    ) -> String {
        guard settings.naming == .gridLabels else {
            return String(format: "part-%02d", index + 1)
        }
        // Tilted cuts have no clean grid coordinate — fall back to letters.
        guard !hasTiltedCut else { return "part-\(letters(for: index))" }
        let ix = axisCuts[0].filter { $0 < center.x }.count
        let iy = axisCuts[1].filter { $0 < center.y }.count
        let iz = axisCuts[2].filter { $0 < center.z }.count
        var label = "\(letters(for: ix))\(iy + 1)"
        if !axisCuts[2].isEmpty {
            label += "-L\(iz + 1)"
        }
        return label
    }

    /// Shift a plane's offset so no model vertex lies within a sub-micron band of
    /// it (avoids degenerate vertex/edge-grazing cuts). Returns the plane
    /// unchanged when it already clears every vertex.
    private static func nudgedOffPlaneVertices(_ plane: PartitionGeometry.PlaneEq, soup: [(Vec3, Vec3, Vec3)]) -> PartitionGeometry.PlaneEq {
        // 10µm: below print resolution, but large enough that the corner slivers
        // a grazing cut leaves stay above MeshPreflight's degenerate-area floor.
        let tol = 1.0e-2
        var projections: [Double] = []
        projections.reserveCapacity(soup.count * 3)
        for tri in soup {
            projections.append(PartitionGeometry.dot(tri.0, plane.n))
            projections.append(PartitionGeometry.dot(tri.1, plane.n))
            projections.append(PartitionGeometry.dot(tri.2, plane.n))
        }
        func clears(_ d: Double) -> Bool {
            projections.allSatisfy { abs($0 - d) >= tol }
        }
        if clears(plane.d) { return plane }
        for k in 1...32 {
            let up = plane.d + Double(k) * tol
            if clears(up) { return PartitionGeometry.PlaneEq(normal: plane.n, offset: up) }
            let down = plane.d - Double(k) * tol
            if clears(down) { return PartitionGeometry.PlaneEq(normal: plane.n, offset: down) }
        }
        return PartitionGeometry.PlaneEq(normal: plane.n, offset: plane.d + tol)
    }

    private static func axisIndex(of normal: Vec3) -> Int? {
        if abs(normal.x) > 0.999 { return 0 }
        if abs(normal.y) > 0.999 { return 1 }
        if abs(normal.z) > 0.999 { return 2 }
        return nil
    }

    /// Spreadsheet-style letters: A, B, …, Z, AA, AB, …
    private static func letters(for index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            let r = n % 26
            result = String(UnicodeScalar(UInt8(65 + r))) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }
}
