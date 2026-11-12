import Foundation

/// Resolves the parting plane(s) and splits the shell into 2 or 4 watertight,
/// capped parts using ManifoldEngine.splitByPlane.
///
/// This type provides the silhouette-ranked initial auto candidate and honors
/// supplied manual planes. `MotherMoldPlanner` then evaluates primary candidates
/// using measured undercuts and connectivity before accepting the final planes.
///
/// Manifold's split is watertight by construction — it caps the open cross-
/// section automatically. The split is therefore correct on CONCAVE / multi-loop
/// cross-sections without any extra island-grouping step on the Swift side.
enum MoldPartitioner {
    /// Diagonal parting is allowed, but it must beat the best eligible
    /// axis-aligned candidate by more than this ratio. Axis seams print and key
    /// more reliably, so small diagonal score wins are treated as noise.
    private static let diagonalWinRatio = 1.15
    private static let scoreTolerance = 1.0e-6

    /// Result of the partition stage: the resolved planes plus the raw part
    /// solids (before keys/flanges/features). Part names are assigned here.
    struct PartitionResult: Equatable {
        var planes: [PartitionPlane]
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]

        static let empty = PartitionResult(planes: [], parts: [], diagnostics: [])
    }

    // MARK: - Plane resolution

    /// Resolve parting plane(s) for the shell, honoring manual planes or running
    /// the auto heuristic. Equivalent planes are normalized, sign-canonicalized,
    /// and sorted before partitioning so order or reversed normals cannot change
    /// part identity and downstream male/female key ownership.
    static func resolvePlanes(
        shell: MeshGeometryData,
        reference: MeshGeometryData? = nil,
        settings: MotherMoldSettings,
        requiredSplitLine: (point: Vec3, direction: Vec3)? = nil
    ) -> [PartitionPlane] {
        if settings.parting.mode == .manual {
            return canonicalizedPlanes(settings.parting.planes) ?? []
        }

        let needed = settings.parts.planeCount

        // Auto initial candidate: score the manufactured shell silhouette, but place the planes
        // through the closed cavity/master reference. Slip shells are trimmed
        // open before partitioning, so using their vertex centroid shifts the
        // split away from the master's center and can create artificial locks on
        // otherwise convex geometry.
        let centroid = meshCentroid(reference ?? shell)
        let axes = candidateAxes()
        let scored = axes.enumerated().map {
            ScoredAxis(
                index: $0.offset,
                axis: $0.element,
                score: axisScore(shell, axis: $0.element),
                axisRank: axisRank($0.element)
            )
        }

        var chosen: [Vec3] = []
        while chosen.count < needed {
            let eligible = scored.filter { candidate in
                chosen.allSatisfy { existing in
                    let absDot = abs(dot(existing, candidate.axis))
                    return absDot < 0.9
                }
            }
            guard let candidate = preferredAxis(from: eligible) else { break }
            chosen.append(candidate.axis)
        }

        // An incomplete measured search is a real planning failure. Do not
        // silently substitute unrelated canonical planes; callers turn the
        // empty result into an actionable parting error.
        guard chosen.count == needed else { return [] }

        if let requiredSplitLine {
            guard let aligned = axesContainingRequiredLine(
                Array(chosen.prefix(needed)),
                direction: requiredSplitLine.direction
            ) else {
                return []
            }
            chosen = aligned
        }

        // The first auto plane owns any required fixture split and therefore
        // passes through that line. Remaining planes pass through the reference
        // centroid. Stable IDs keep downstream handoffs deterministic.
        let resolved = chosen.prefix(needed).enumerated().map { index, axis in
            let point = index == 0 ? (requiredSplitLine?.point ?? centroid) : centroid
            return PartitionPlane(
                id: autoPlaneID(index),
                normal: axis,
                offset: dot(axis, point),
                isManual: false
            )
        }
        return canonicalizedPlanes(resolved) ?? []
    }

    // MARK: - Partition

    /// Split the shell into 2 or 4 capped, watertight parts along the resolved
    /// planes. Manifold's split produces watertight closed solids with flat caps
    /// on both halves — correct on concave sections automatically.
    static func partition(
        shell: MeshGeometryData,
        planes: [PartitionPlane],
        settings: MotherMoldSettings
    ) throws -> PartitionResult {
        guard !planes.isEmpty else {
            return PartitionResult(
                planes: [],
                parts: [MotherMoldPart(name: "mold-part-A", geometry: shell)],
                diagnostics: [MoldDiagnostic(.warning, "No parting planes supplied; emitting whole shell as single part.")]
            )
        }

        var diagnostics: [MoldDiagnostic] = []

        // Convert the shell to a ManifoldHandle.
        let shellHandle = try ManifoldEngine.make(from: shell)

        // Apply planes sequentially. Each plane splits every current piece into
        // at most two pieces, so after N planes we have at most 2^N pieces.
        // For our cases: 1 plane → 2 parts, 2 planes → 4 parts.
        var pieces: [ManifoldHandle] = [shellHandle]

        for plane in planes {
            var next: [ManifoldHandle] = []
            for piece in pieces {
                if ManifoldEngine.isEmpty(piece) { continue }
                do {
                    let (above, below) = try ManifoldEngine.splitByPlane(
                        piece,
                        normal: plane.normal,
                        offset: plane.offset
                    )
                    if !ManifoldEngine.isEmpty(above) { next.append(above) }
                    if !ManifoldEngine.isEmpty(below) { next.append(below) }
                } catch {
                    diagnostics.append(MoldDiagnostic(
                        .warning,
                        "Plane split produced an error for one piece (\(error.localizedDescription)); skipping."
                    ))
                    next.append(piece) // keep the unsplit piece rather than losing geometry
                }
            }
            pieces = next
        }

        // Convert each piece back to app geometry and assign stable names.
        let partLabels = partNameLabels(count: pieces.count)
        var parts: [MotherMoldPart] = []
        for (index, handle) in pieces.enumerated() {
            do {
                // Collapse the sub-micron sliver triangles a plane split leaves at
                // cut (and cut-cut) seams on dense curved shells, which would
                // otherwise fail the watertight gate. Tolerance is far below
                // printable resolution, so the mold shape is unchanged.
                let cleaned = try ManifoldEngine.simplify(handle, tolerance: 1.0e-3)
                let geometry = try ManifoldEngine.toMesh(cleaned)
                let bounds = boundsOf(geometry)
                let name = partLabels[index]
                parts.append(MotherMoldPart(name: name, geometry: geometry, isWatertight: false, bounds: bounds))
            } catch {
                diagnostics.append(MoldDiagnostic(
                    .error,
                    "Part \(partLabels[index]): mesh readback failed — \(error.localizedDescription)"
                ))
            }
        }

        if parts.isEmpty {
            throw MotherMoldPlannerError.partitionFailed("All split pieces were empty or failed to read back.")
        }

        return PartitionResult(planes: planes, parts: parts, diagnostics: diagnostics)
    }

    // MARK: - Helpers

    private static func canonicalizedPlanes(_ planes: [PartitionPlane]) -> [PartitionPlane]? {
        var result: [PartitionPlane] = []
        result.reserveCapacity(planes.count)
        for plane in planes {
            let raw = plane.normal
            let length = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
            guard length.isFinite, length > 1.0e-9, plane.offset.isFinite else { return nil }

            var normal = Vec3(x: raw.x / length, y: raw.y / length, z: raw.z / length)
            var offset = plane.offset / length
            let firstSignificant = [normal.x, normal.y, normal.z]
                .first { abs($0) > 1.0e-12 } ?? 0
            if firstSignificant < 0 {
                normal = Vec3(x: -normal.x, y: -normal.y, z: -normal.z)
                offset = -offset
            }
            result.append(PartitionPlane(
                id: plane.id,
                normal: normal,
                offset: offset,
                isManual: plane.isManual
            ))
        }

        return result.sorted { lhs, rhs in
            let left = quantizedPlane(lhs)
            let right = quantizedPlane(rhs)
            if left != right { return left.lexicographicallyPrecedes(right) }
            return [lhs.normal.x, lhs.normal.y, lhs.normal.z, lhs.offset]
                .lexicographicallyPrecedes([rhs.normal.x, rhs.normal.y, rhs.normal.z, rhs.offset])
        }
    }

    private static func quantizedPlane(_ plane: PartitionPlane) -> [Int64] {
        [plane.normal.x, plane.normal.y, plane.normal.z, plane.offset].map {
            Int64(($0 * 1_000_000_000).rounded())
        }
    }

    private static func autoPlaneID(_ index: Int) -> UUID {
        let suffix = String(format: "%012d", index + 1)
        return UUID(uuidString: "4d4f4c44-4155-544f-0000-\(suffix)")!
    }

    private static func axesContainingRequiredLine(
        _ axes: [Vec3],
        direction: Vec3
    ) -> [Vec3]? {
        let length = sqrt(dot(direction, direction))
        guard length.isFinite, length > 1.0e-9, !axes.isEmpty else { return nil }
        let line = scale(direction, 1 / length)
        let preferredIndex = axes.indices.min { lhs, rhs in
            abs(dot(axes[lhs], line)) < abs(dot(axes[rhs], line))
        } ?? 0
        let preferred = axes[preferredIndex]
        let projected = subtract(preferred, scale(line, dot(preferred, line)))
        let gateNormal = dot(projected, projected) > 1.0e-12
            ? normalized(projected)
            : stablePerpendicular(to: line)
        var result = [gateNormal]

        for index in axes.indices where index != preferredIndex {
            let orthogonal = subtract(axes[index], scale(gateNormal, dot(axes[index], gateNormal)))
            let normal = dot(orthogonal, orthogonal) > 1.0e-12
                ? normalized(orthogonal)
                : stablePerpendicular(to: gateNormal)
            if result.allSatisfy({ abs(dot($0, normal)) < 0.9 }) {
                result.append(normal)
            }
        }
        while result.count < axes.count {
            let normal = stablePerpendicular(to: result.last ?? gateNormal)
            guard result.allSatisfy({ abs(dot($0, normal)) < 0.9 }) else { return nil }
            result.append(normal)
        }
        return Array(result.prefix(axes.count))
    }

    private static func stablePerpendicular(to direction: Vec3) -> Vec3 {
        let basis: Vec3
        let values = [abs(direction.x), abs(direction.y), abs(direction.z)]
        switch values.firstIndex(of: values.min() ?? values[0]) ?? 0 {
        case 0: basis = Vec3(x: 1, y: 0, z: 0)
        case 1: basis = Vec3(x: 0, y: 1, z: 0)
        default: basis = Vec3(x: 0, y: 0, z: 1)
        }
        return normalized(cross(direction, basis))
    }

    /// Generate a set of candidate normal directions to score as parting planes.
    /// Includes the three primary axes plus 45-degree diagonals in each plane —
    /// enough to capture the dominant silhouette direction of typical organic forms.
    private static func candidateAxes() -> [Vec3] {
        let s = (2.0).squareRoot() / 2.0
        return [
            // Primary axes. Tie-break order is X, then Y, then Z.
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 0, y: 0, z: 1),
            // XY diagonals
            Vec3(x: s, y: s, z: 0),
            Vec3(x: s, y: -s, z: 0),
            // XZ diagonals
            Vec3(x: s, y: 0, z: s),
            Vec3(x: s, y: 0, z: -s),
            // YZ diagonals
            Vec3(x: 0, y: s, z: s),
            Vec3(x: 0, y: s, z: -s),
        ]
    }

    private struct ScoredAxis {
        var index: Int
        var axis: Vec3
        var score: Double
        /// 0=X, 1=Y, 2=Z for primary axes; nil for diagonals.
        var axisRank: Int?
    }

    private static func preferredAxis(from candidates: [ScoredAxis]) -> ScoredAxis? {
        guard let bestOverall = candidates.max(by: scoreSortAscending) else { return nil }
        guard let bestAxis = candidates
            .filter({ $0.axisRank != nil })
            .max(by: scoreSortAscending)
        else {
            return bestOverall
        }
        if bestOverall.axisRank == nil,
           bestOverall.score <= bestAxis.score * diagonalWinRatio + scoreTolerance {
            return bestAxis
        }
        return bestOverall
    }

    private static func scoreSortAscending(_ a: ScoredAxis, _ b: ScoredAxis) -> Bool {
        if abs(a.score - b.score) > scoreTolerance { return a.score < b.score }
        switch (a.axisRank, b.axisRank) {
        case let (la?, lb?):
            return la > lb
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        case (nil, nil):
            return a.index > b.index
        }
    }

    private static func axisRank(_ axis: Vec3) -> Int? {
        let ax = abs(axis.x), ay = abs(axis.y), az = abs(axis.z)
        if ax > 0.999, ay < 1.0e-6, az < 1.0e-6 { return 0 }
        if ay > 0.999, ax < 1.0e-6, az < 1.0e-6 { return 1 }
        if az > 0.999, ax < 1.0e-6, ay < 1.0e-6 { return 2 }
        return nil
    }

    /// Score an axis as a parting direction: projected convex-hull area. The
    /// earlier projected bounding-box score over-rewarded 45-degree candidates
    /// on organic heads because a rotated rectangle's AABB grows even when the
    /// real silhouette does not.
    private static func axisScore(_ mesh: MeshGeometryData, axis: Vec3) -> Double {
        guard !mesh.vertices.isEmpty else { return 0 }
        // Build a tangent pair orthogonal to the axis.
        let t1 = perpendicularTo(axis)
        let t2 = cross(axis, t1)
        var points: [Vec2] = []
        points.reserveCapacity(mesh.vertices.count)
        for v in mesh.vertices {
            points.append(Vec2(x: dot(v, t1), y: dot(v, t2)))
        }
        // Unit diagonals mix two world axes, which inflates scan silhouettes
        // compared with primary-axis candidates. Normalize by L1 length so the
        // 1.15 diagonal win rule compares useful split quality rather than
        // coordinate-mixing area.
        let axisMix = max(1.0, abs(axis.x) + abs(axis.y) + abs(axis.z))
        return convexHullArea(points) / axisMix
    }

    private static func convexHullArea(_ input: [Vec2]) -> Double {
        guard input.count >= 3 else { return 0 }
        let points = input.sorted {
            if abs($0.x - $1.x) > 1.0e-9 { return $0.x < $1.x }
            return $0.y < $1.y
        }
        func turn(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Vec2] = []
        lower.reserveCapacity(points.count)
        for p in points {
            while lower.count >= 2,
                  turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 1.0e-9 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Vec2] = []
        upper.reserveCapacity(points.count)
        for p in points.reversed() {
            while upper.count >= 2,
                  turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 1.0e-9 {
                upper.removeLast()
            }
            upper.append(p)
        }
        let hull = lower.dropLast() + upper.dropLast()
        guard hull.count >= 3 else { return 0 }
        var twiceArea = 0.0
        for i in hull.indices {
            let a = hull[i]
            let b = hull[hull.index(after: i) == hull.endIndex ? hull.startIndex : hull.index(after: i)]
            twiceArea += a.x * b.y - a.y * b.x
        }
        return abs(twiceArea) / 2.0
    }

    /// Compute the centroid of mesh vertices (arithmetic mean, ignoring triangle
    /// area — fast enough for plane placement).
    private static func meshCentroid(_ mesh: MeshGeometryData) -> Vec3 {
        guard !mesh.vertices.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        var sx = 0.0, sy = 0.0, sz = 0.0
        for v in mesh.vertices {
            sx += v.x; sy += v.y; sz += v.z
        }
        let n = Double(mesh.vertices.count)
        return Vec3(x: sx / n, y: sy / n, z: sz / n)
    }

    /// Compute a vector perpendicular to `v` (stable for any non-zero v).
    private static func perpendicularTo(_ v: Vec3) -> Vec3 {
        // Choose a reference direction not parallel to v.
        let ref: Vec3
        if abs(v.x) <= abs(v.y) && abs(v.x) <= abs(v.z) {
            ref = Vec3(x: 1, y: 0, z: 0)
        } else if abs(v.y) <= abs(v.z) {
            ref = Vec3(x: 0, y: 1, z: 0)
        } else {
            ref = Vec3(x: 0, y: 0, z: 1)
        }
        return normalized(cross(v, ref))
    }

    /// Stable part name labels for up to 4 parts, e.g. "mold-part-A".
    private static func partNameLabels(count: Int) -> [String] {
        let letters = ["A", "B", "C", "D"]
        return (0..<count).map { i in
            i < letters.count ? "mold-part-\(letters[i])" : "mold-part-\(i + 1)"
        }
    }

    /// Axis-aligned bounding box for geometry (nil if empty).
    private static func boundsOf(_ geometry: MeshGeometryData) -> Bounds3D? {
        guard !geometry.vertices.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, minZ = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
        for v in geometry.vertices {
            minX = min(minX, v.x); minY = min(minY, v.y); minZ = min(minZ, v.z)
            maxX = max(maxX, v.x); maxY = max(maxY, v.y); maxZ = max(maxZ, v.z)
        }
        return Bounds3D(min: Vec3(x: minX, y: minY, z: minZ),
                        max: Vec3(x: maxX, y: maxY, z: maxZ))
    }

    // MARK: - Vec3 math (file-private, no global pollution)

    @inline(__always) private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inline(__always) private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y,
             y: a.z * b.x - a.x * b.z,
             z: a.x * b.y - a.y * b.x)
    }

    @inline(__always) private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    @inline(__always) private static func scale(_ value: Vec3, _ factor: Double) -> Vec3 {
        Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor)
    }

    @inline(__always) private static func normalized(_ v: Vec3) -> Vec3 {
        let len = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard len > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: v.x / len, y: v.y / len, z: v.z / len)
    }
}
