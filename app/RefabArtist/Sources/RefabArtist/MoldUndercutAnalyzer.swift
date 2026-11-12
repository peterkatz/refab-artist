import Foundation

/// Per-part undercut detection along the demold axis. The planner assigns cavity
/// triangles to the same partition half-spaces as each mold part, then flags
/// owned faces whose outward normals oppose that part's pull direction.
///
/// Enforced for `slipShell` (rigid demold) and informational for
/// `siliconeJacket` (silicone flexes off undercuts). MUST work on genuinely
/// CONCAVE organic masters, not just convex fixtures — undercut detection on
/// concave sections is the project's historical blind spot.
///
/// This ownership step is essential: evaluating the complete closed cavity for
/// every part assigns the opposite hemisphere to both halves and reports false
/// undercuts on convex masters. Standalone callers that provide no planes retain
/// the conservative whole-cavity overhang check used by the original API.
enum MoldUndercutAnalyzer {
    /// One flagged re-entrant region on a part's cavity face.
    struct UndercutRegion: Equatable {
        /// Representative point on the re-entrant surface (model space).
        var point: Vec3
        /// Outward demold direction the part is pulled along.
        var demoldAxis: Vec3
        /// Approximate depth the region is locked by, in mm.
        var depth: Double
    }

    /// Undercut report for a single part.
    struct PartUndercutReport: Equatable {
        var partName: String
        var demoldAxis: Vec3
        var regions: [UndercutRegion]
        var isDemoldable: Bool

        static func clean(partName: String, demoldAxis: Vec3) -> PartUndercutReport {
            PartUndercutReport(partName: partName, demoldAxis: demoldAxis, regions: [], isDemoldable: true)
        }
    }

    /// Whole-build undercut summary.
    struct UndercutSummary: Equatable {
        var reports: [PartUndercutReport]
        /// Diagnostics rendered in the Fit/Warnings panel (error severity for
        /// slip shells with undercuts, info severity for silicone).
        var diagnostics: [MoldDiagnostic]

        static let empty = UndercutSummary(reports: [], diagnostics: [])
    }

    // MARK: - Public API

    /// Analyze every part for re-entrant regions along its demold axis.
    /// `demoldAxes` is parallel to `parts` (one outward axis per part, from the
    /// partitioner). `cavity` is the surface probed against.
    static func analyze(
        parts: [MotherMoldPart],
        demoldAxes: [Vec3],
        cavity: MeshGeometryData,
        settings: MotherMoldSettings,
        planes: [PartitionPlane] = []
    ) -> UndercutSummary {
        guard !parts.isEmpty else { return .empty }

        // Pre-build triangle list once for all parts.
        let triangles = buildTriangleList(cavity)
        guard !triangles.isEmpty else {
            let requiresProof = settings.subtype.enforcesUndercuts
            return UndercutSummary(
                reports: parts.enumerated().map { (i, p) in
                    PartUndercutReport(
                        partName: p.name,
                        demoldAxis: i < demoldAxes.count ? demoldAxes[i] : Vec3(x: 0, y: 0, z: 1),
                        regions: [],
                        isDemoldable: !requiresProof
                    )
                },
                diagnostics: [MoldDiagnostic(
                    requiresProof ? .error : .info,
                    requiresProof
                        ? "Rigid demold verification could not analyze the cavity because it has no usable triangles. Repair the source or use a flexible silicone jacket."
                        : "Cavity has no usable triangles; flexible-jacket undercut guidance is unavailable."
                )]
            )
        }

        var reports: [PartUndercutReport] = []
        var diagnostics: [MoldDiagnostic] = []
        let extractionCavity: ManifoldHandle? = settings.subtype.enforcesUndercuts
            ? try? ManifoldEngine.make(from: cavity)
            : nil
        if settings.subtype.enforcesUndercuts, extractionCavity == nil {
            diagnostics.append(MoldDiagnostic(
                .error,
                "Rigid demold verification could not load the cavity solid. Rebuild after repairing the source mesh or use a flexible silicone jacket."
            ))
        }

        for (index, part) in parts.enumerated() {
            let rawAxis = index < demoldAxes.count ? demoldAxes[index] : inferDemoldAxis(part)
            let axis = normalized(rawAxis)
            let ownedTriangles = planes.isEmpty
                ? triangles
                : trianglesOwned(by: part, from: triangles, planes: planes)
            var report = analyzeOnePart(
                part,
                axis: axis,
                triangles: ownedTriangles,
                hasPartitionOwnership: !planes.isEmpty
            )
            if report.isDemoldable, let extractionCavity {
                switch extractionResult(part: part, cavityHandle: extractionCavity, axis: axis) {
                case .clear:
                    break
                case .collision(let collision):
                    report.regions = [collision]
                    report.isDemoldable = false
                case .failed:
                    diagnostics.append(MoldDiagnostic(
                        .error,
                        "Rigid demold verification failed for \(part.name). Try a simpler split, repair the source, or use a flexible silicone jacket."
                    ))
                }
            }
            reports.append(report)

            if !report.isDemoldable {
                let severity: MoldDiagnosticSeverity = settings.subtype.enforcesUndercuts ? .error : .info
                let depth = report.regions.map(\.depth).max() ?? 0
                let formatted = String(format: "%.2f", depth)
                diagnostics.append(MoldDiagnostic(
                    severity,
                    "\(report.partName): \(report.regions.count) undercut region(s) detected (max depth \(formatted) mm). "
                        + (settings.subtype.enforcesUndercuts
                            ? "Rigid shell requires clean demold — adjust the parting planes, add parts, or redesign."
                            : "Silicone jacket will flex past undercuts.")
                ))
            }
        }
        if let extractionCavity { withExtendedLifetime(extractionCavity) {} }

        return UndercutSummary(reports: reports, diagnostics: diagnostics)
    }

    // MARK: - Per-part analysis

    /// Numerical tolerance for a nominally pull-parallel wall. Backdraft beyond
    /// 0.5 degrees is not silently accepted for a rigid mold.
    static let backdraftDotTolerance = sin(0.5 * Double.pi / 180)
    private static let partingNormalTolerance = backdraftDotTolerance
    private static let overhangNormalThreshold = backdraftDotTolerance

    private static func analyzeOnePart(
        _ part: MotherMoldPart,
        axis: Vec3,
        triangles: [RayTriangle],
        hasPartitionOwnership: Bool
    ) -> PartUndercutReport {
        guard part.bounds != nil, !triangles.isEmpty else {
            return PartUndercutReport.clean(partName: part.name, demoldAxis: axis)
        }

        if hasPartitionOwnership {
            return analyzePartitionOwnedPart(part, axis: axis, triangles: triangles)
        }

        // Global axial extent of the cavity along the pull axis.
        var axMin = Double.infinity, axMax = -Double.infinity
        for tri in triangles {
            for v in [tri.v0, tri.v1, tri.v2] {
                let a = dot(v, axis)
                if a < axMin { axMin = a }
                if a > axMax { axMax = a }
            }
        }
        guard axMax > axMin else {
            return PartUndercutReport.clean(partName: part.name, demoldAxis: axis)
        }
        // Tolerance band (mm) around the global extremes that still counts as the
        // flat parting face: scale with the cavity's axial span.
        let axialBand = max((axMax - axMin) * 0.02, 0.25)

        // A face is an UNDERCUT for a ±axis 2-part demold when its outward normal
        // has a meaningful component ALONG the axis (it faces "up" or "down" the
        // pull, not a vertical side wall) AND it does NOT sit on the matching
        // global parting extreme:
        //   - an UP-facing face (dot(n, axis) > 0) anywhere below the top parting
        //     band is reachable only by the +axis half-mold and, being below the
        //     top, is overhung by material above it → locks the +axis pull;
        //   - a DOWN-facing face (dot(n, axis) < 0) anywhere above the bottom
        //     parting band symmetrically locks the −axis pull.
        // The cube passes: its only up-faces sit in the top band, its only
        // down-face sits in the bottom band, its sides are vertical (no axial
        // normal component). The torus fails on Z (tube flanks are up/down-facing
        // away from the extremes); the L-prism fails on a lateral axis (the notch
        // wall faces along that axis away from the extreme) and passes on its
        // extrusion axis (only flat top/bottom caps have axial normals).
        var undercutRegions: [UndercutRegion] = []
        for tri in triangles {
            let alongAxis = dot(tri.normal, axis)
            guard abs(alongAxis) >= overhangNormalThreshold else { continue } // vertical wall
            let centroid = Vec3(
                x: (tri.v0.x + tri.v1.x + tri.v2.x) / 3,
                y: (tri.v0.y + tri.v1.y + tri.v2.y) / 3,
                z: (tri.v0.z + tri.v1.z + tri.v2.z) / 3
            )
            let aFace = dot(centroid, axis)

            if alongAxis > partingNormalTolerance {
                // Up-facing: clean only on the top parting band.
                if aFace < axMax - axialBand {
                    undercutRegions.append(UndercutRegion(
                        point: centroid, demoldAxis: axis, depth: axMax - aFace
                    ))
                }
            } else if alongAxis < -partingNormalTolerance {
                // Down-facing: clean only on the bottom parting band.
                if aFace > axMin + axialBand {
                    undercutRegions.append(UndercutRegion(
                        point: centroid, demoldAxis: axis, depth: aFace - axMin
                    ))
                }
            }
        }

        // Deduplicate nearby regions (merge regions within 2mm of each other).
        let merged = mergeNearbyRegions(undercutRegions, threshold: 2.0)

        return PartUndercutReport(
            partName: part.name,
            demoldAxis: axis,
            regions: merged,
            isDemoldable: merged.isEmpty
        )
    }

    /// Once a cavity region has been assigned to the same partition half-spaces
    /// as a mold part, a face locks that part only when its outward normal points
    /// back into the mold, opposite the part's pull direction. Analyzing the full
    /// closed cavity for every part incorrectly assigns the opposite hemisphere
    /// to both halves and flags every convex master as undercut.
    private static func analyzePartitionOwnedPart(
        _ part: MotherMoldPart,
        axis: Vec3,
        triangles: [RayTriangle]
    ) -> PartUndercutReport {
        let axMax = triangles.reduce(-Double.infinity) { current, triangle in
            max(current, dot(triangle.v0, axis), dot(triangle.v1, axis), dot(triangle.v2, axis))
        }
        guard axMax.isFinite else {
            return PartUndercutReport.clean(partName: part.name, demoldAxis: axis)
        }

        var regions: [UndercutRegion] = []
        for triangle in triangles {
            let alongAxis = dot(triangle.normal, axis)
            guard alongAxis < -overhangNormalThreshold else { continue }
            let centroid = triangle.centroid
            regions.append(UndercutRegion(
                point: centroid,
                demoldAxis: axis,
                depth: max(0, axMax - dot(centroid, axis))
            ))
        }

        let merged = mergeNearbyRegions(regions, threshold: 2.0)
        return PartUndercutReport(
            partName: part.name,
            demoldAxis: axis,
            regions: merged,
            isDemoldable: merged.isEmpty
        )
    }

    /// Translate a completed rigid mold part along its actual removal axis and
    /// measure positive-volume collision with the cavity solid. A local-normal
    /// test alone can miss nonlocal hooks and coarse-mesh interference.
    static func firstExtractionCollision(
        part: MotherMoldPart,
        cavity: MeshGeometryData,
        axis: Vec3
    ) -> UndercutRegion? {
        guard let cavityHandle = try? ManifoldEngine.make(from: cavity) else { return nil }
        defer { withExtendedLifetime(cavityHandle) {} }
        if case .collision(let region) = extractionResult(
            part: part,
            cavityHandle: cavityHandle,
            axis: normalized(axis)
        ) {
            return region
        }
        return nil
    }

    private enum ExtractionResult {
        case clear
        case collision(UndercutRegion)
        case failed
    }

    private static func extractionResult(
        part: MotherMoldPart,
        cavityHandle: ManifoldHandle,
        axis: Vec3
    ) -> ExtractionResult {
        do {
            let partHandle = try ManifoldEngine.make(from: part.geometry)
            let baselineIntersection = try ManifoldEngine.intersect(partHandle, cavityHandle)
            let baselineVolume = abs(ManifoldEngine.volume(baselineIntersection))
            let cavityVolume = abs(ManifoldEngine.volume(cavityHandle))
            let tolerance = max(1.0e-4, cavityVolume * 1.0e-9)
            withExtendedLifetime(baselineIntersection) {}

            // Real interlocks begin colliding immediately as the touching mold
            // surface moves. Dense early samples catch sub-millimeter backdraft;
            // farther samples catch nonlocal hooks without a costly fine sweep.
            for distance in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0] {
                let moved = try ManifoldEngine.translate(
                    partHandle,
                    x: axis.x * distance,
                    y: axis.y * distance,
                    z: axis.z * distance
                )
                let intersection = try ManifoldEngine.intersect(moved, cavityHandle)
                let overlapVolume = abs(ManifoldEngine.volume(intersection))
                if overlapVolume > baselineVolume + tolerance {
                    let mesh = try ManifoldEngine.toMesh(intersection)
                    let point: Vec3
                    if mesh.vertices.isEmpty {
                        point = part.bounds.map {
                            Vec3(
                                x: ($0.min.x + $0.max.x) / 2,
                                y: ($0.min.y + $0.max.y) / 2,
                                z: ($0.min.z + $0.max.z) / 2
                            )
                        } ?? Vec3(x: 0, y: 0, z: 0)
                    } else {
                        let sum = mesh.vertices.reduce(Vec3(x: 0, y: 0, z: 0)) {
                            Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
                        }
                        let count = Double(mesh.vertices.count)
                        point = Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
                    }
                    withExtendedLifetime(moved) {}
                    withExtendedLifetime(intersection) {}
                    withExtendedLifetime(partHandle) {}
                    return .collision(UndercutRegion(
                        point: point,
                        demoldAxis: axis,
                        depth: distance
                    ))
                }
                withExtendedLifetime(moved) {}
                withExtendedLifetime(intersection) {}
            }
            withExtendedLifetime(partHandle) {}
            return .clear
        } catch {
            return .failed
        }
    }

    // MARK: - Triangle intersection

    /// Pre-built triangle for ray intersection: vertices + pre-computed normal.
    private struct RayTriangle {
        var v0: Vec3
        var v1: Vec3
        var v2: Vec3
        var normal: Vec3 // unit face normal (may be zero for degenerate triangles)

        var centroid: Vec3 {
            Vec3(
                x: (v0.x + v1.x + v2.x) / 3,
                y: (v0.y + v1.y + v2.y) / 3,
                z: (v0.z + v1.z + v2.z) / 3
            )
        }
    }

    /// Build the triangle list from geometry. Degenerate triangles are skipped.
    private static func buildTriangleList(_ geometry: MeshGeometryData) -> [RayTriangle] {
        let verts = geometry.vertices
        let idxs = geometry.triangleIndices
        var out: [RayTriangle] = []
        out.reserveCapacity(idxs.count / 3)
        var i = 0
        while i + 2 < idxs.count {
            let ai = Int(idxs[i]), bi = Int(idxs[i + 1]), ci = Int(idxs[i + 2])
            guard verts.indices.contains(ai),
                  verts.indices.contains(bi),
                  verts.indices.contains(ci) else { i += 3; continue }
            let v0 = verts[ai], v1 = verts[bi], v2 = verts[ci]
            let e1 = Vec3(x: v1.x - v0.x, y: v1.y - v0.y, z: v1.z - v0.z)
            let e2 = Vec3(x: v2.x - v0.x, y: v2.y - v0.y, z: v2.z - v0.z)
            let n = cross(e1, e2)
            let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            if len < 1.0e-12 { i += 3; continue } // degenerate
            let unit = Vec3(x: n.x / len, y: n.y / len, z: n.z / len)
            out.append(RayTriangle(v0: v0, v1: v1, v2: v2, normal: unit))
            i += 3
        }
        return out
    }

    private static func trianglesOwned(
        by part: MotherMoldPart,
        from triangles: [RayTriangle],
        planes: [PartitionPlane]
    ) -> [RayTriangle] {
        let equations = planes.map {
            PartitionGeometry.PlaneEq(normal: $0.normal, offset: $0.offset)
        }
        let positiveSides = equations.map { partKeepsPositive(part, plane: $0) }
        let tolerance = 1.0e-6

        return triangles.filter { triangle in
            let centroid = triangle.centroid
            for (index, plane) in equations.enumerated() {
                let signed = PartitionGeometry.signed(centroid, plane)
                if positiveSides[index] {
                    if signed < -tolerance { return false }
                } else if signed > tolerance {
                    return false
                }
            }
            return true
        }
    }

    private static func partKeepsPositive(
        _ part: MotherMoldPart,
        plane: PartitionGeometry.PlaneEq
    ) -> Bool {
        let tolerance = 1.0e-6
        var positiveCount = 0
        var negativeCount = 0
        var signedSum = 0.0
        for vertex in part.geometry.vertices {
            let signed = PartitionGeometry.signed(vertex, plane)
            signedSum += signed
            if signed > tolerance { positiveCount += 1 }
            if signed < -tolerance { negativeCount += 1 }
        }
        if positiveCount != negativeCount { return positiveCount > negativeCount }
        return signedSum >= 0
    }

    // MARK: - Helpers

    /// Infer a demold axis from the part's position relative to its bounds centre.
    /// Used when the caller passes fewer axes than parts (shouldn't happen in
    /// normal flow, but prevents index-out-of-bounds).
    private static func inferDemoldAxis(_ part: MotherMoldPart) -> Vec3 {
        guard let b = part.bounds else { return Vec3(x: 0, y: 0, z: 1) }
        // Default to the axis with the smallest extent (most likely the seam direction).
        let dx = b.max.x - b.min.x
        let dy = b.max.y - b.min.y
        let dz = b.max.z - b.min.z
        if dz <= dx && dz <= dy { return Vec3(x: 0, y: 0, z: 1) }
        if dx <= dy { return Vec3(x: 1, y: 0, z: 0) }
        return Vec3(x: 0, y: 1, z: 0)
    }

    /// Merge nearby undercut region points so we don't report a thousand tiny
    /// hits for the same physical undercut feature. Uses a simple threshold: if
    /// the representative points of two regions are within `threshold` mm, keep
    /// the deeper one.
    private static func mergeNearbyRegions(
        _ regions: [UndercutRegion],
        threshold: Double
    ) -> [UndercutRegion] {
        guard !regions.isEmpty else { return [] }
        let t2 = threshold * threshold
        var merged: [UndercutRegion] = []
        for region in regions {
            var found = false
            for i in merged.indices {
                let dx = merged[i].point.x - region.point.x
                let dy = merged[i].point.y - region.point.y
                let dz = merged[i].point.z - region.point.z
                if dx * dx + dy * dy + dz * dz < t2 {
                    // Keep the deeper one.
                    if region.depth > merged[i].depth {
                        merged[i] = region
                    }
                    found = true
                    break
                }
            }
            if !found { merged.append(region) }
        }
        return merged
    }

    // MARK: - Vec3 math (file-private)

    @inline(__always) private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inline(__always) private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y,
             y: a.z * b.x - a.x * b.z,
             z: a.x * b.y - a.y * b.x)
    }

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard length > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

}
