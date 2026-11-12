import CManifold
import Foundation

/// Adds the pour spout / reservoir (a fill port through the wall at the topmost
/// cavity region, or a manual override location) and air vents at high points.
/// Spout and vents are built as channel/bore geometry: a cylinder through the
/// wall connecting the cavity to the outside, subtracted via a Manifold
/// difference (the right tool for clean cylindrical bores).
///
/// Auto placement must handle arbitrary orientation; the "topmost" region is
/// taken along the open-plane normal. Manual override is always available.
/// Vent placement is deterministic from `settings.seed`.
enum MoldFeatureBuilder {
    /// The fixture integrity gate checked again after all final mold operations.
    /// Candidate bores use this same threshold so late feature placement cannot
    /// make an otherwise exportable generated locator fail the final gate.
    static let minimumProtectedLocatorRetention = 0.98
    /// High-resolution cavity meshes can contain tens of thousands of vertices.
    /// Keep Auto retry deterministic without allowing unbounded Manifold booleans.
    private static let autoSpoutCandidateLimit = 256

    /// Result of the feature stage: parts with spout + vent bores applied, plus
    /// the resolved spout/vent locations and diagnostics.
    struct FeatureResult: Equatable {
        var parts: [MotherMoldPart]
        /// Resolved spout entry point (model space).
        var spoutLocation: Vec3?
        /// Resolved vent entry points (model space).
        var ventLocations: [Vec3]
        var diagnostics: [MoldDiagnostic]
        /// True when the spout bore actually pierced at least one part.
        var spoutBored: Bool = false
        /// Vents whose bore pierced at least one part.
        var ventsBoredCount: Int = 0

        static let empty = FeatureResult(parts: [], spoutLocation: nil, ventLocations: [], diagnostics: [])
    }

    private struct BoreResult {
        var parts: [MotherMoldPart]
        var boredPartIndices: [Int]
        var removedVolume: Double
        var rejectedFaceConnectedComponentCount: Int? = nil
    }

    private struct FunnelResult {
        var parts: [MotherMoldPart]
        var ownerIndex: Int?
        var addedVolume: Double
    }

    private struct BoreSegment {
        var center: Vec3
        var length: Double
    }

    /// Reuses the protected locator Manifold through all candidate booleans in
    /// one feature pass. Candidate parts still receive fresh handles because
    /// each accepted bore changes their geometry.
    private struct ProtectedLocatorAudit {
        let locatorHandle: ManifoldHandle
        let locatorVolume: Double

        init?(locator: MeshGeometryData) {
            guard let handle = try? ManifoldEngine.make(from: locator) else { return nil }
            let volume = abs(ManifoldEngine.volume(handle))
            guard volume > 1.0e-6 else {
                withExtendedLifetime(handle) {}
                return nil
            }
            locatorHandle = handle
            locatorVolume = volume
        }

        func retainedFraction(in parts: [MotherMoldPart]) -> Double? {
            do {
                var retainedVolume = 0.0
                for part in parts {
                    let partHandle = try ManifoldEngine.make(from: part.geometry)
                    let intersection = try ManifoldEngine.intersect(locatorHandle, partHandle)
                    retainedVolume += abs(ManifoldEngine.volume(intersection))
                    withExtendedLifetime(partHandle) {}
                    withExtendedLifetime(intersection) {}
                }
                return min(1, retainedVolume / locatorVolume)
            } catch {
                return nil
            }
        }
    }

    /// Bore the spout and vents through the parts.
    /// - Parameters:
    ///   - cavity: cavity surface used to anchor auto placement (topmost region).
    ///   - openPlane: the pour/open plane whose normal defines "up".
    static func applyFeatures(
        parts: [MotherMoldPart],
        cavity: MeshGeometryData,
        openPlane: PartitionPlane,
        settings: MotherMoldSettings,
        seed: Int,
        partingPlanes: [PartitionPlane] = [],
        protectedLocator: MeshGeometryData? = nil
    ) throws -> FeatureResult {
        guard !parts.isEmpty else {
            return FeatureResult(parts: parts, spoutLocation: nil, ventLocations: [], diagnostics: [])
        }

        var diagnostics: [MoldDiagnostic] = []
        let spout = settings.spout
        let normal = normalized(openPlane.normal)
        let wall = max(0.1, settings.wallThickness)
        let protectedLocatorAudit = protectedLocator.flatMap(ProtectedLocatorAudit.init(locator:))
        let initialProtectedLocatorRetention = protectedLocatorAudit?.retainedFraction(in: parts)
        // Do not let an already-damaged incoming locator be further reduced by
        // features. The final 98% export gate remains unchanged and identifies
        // the earlier failing stage instead of blaming the pour system.
        let minimumCandidateProtectedRetention = initialProtectedLocatorRetention.map {
            min(minimumProtectedLocatorRetention, $0)
        }

        var updatedParts = parts
        var spoutBored = false
        var resolvedSpoutLocation: Vec3?
        var rejectedProtectedSpoutCandidates = 0

        // Bore the jacket shell before adding the funnel. This prevents a detached
        // funnel from being mistaken for a fill channel merely because its own
        // throat was subtracted successfully.
        do {
            let spoutRadius = max(0.05, spout.spoutDiameter / 2.0)
            let candidates = resolvedSpoutCandidates(
                cavity: cavity,
                openPlane: openPlane,
                settings: spout,
                partingPlanes: partingPlanes,
                seamPlateHalfThickness: settings.flange.enabled
                    ? settings.flange.sanitized.thickness / 2
                    : 0
            )
            for (candidateIndex, spoutCenter) in candidates.enumerated() {
                let segment = oneSidedBoreSegment(
                    entry: spoutCenter,
                    axis: normal,
                    cavity: cavity,
                    settings: settings
                )
                let genusBeforeSpout = try manifoldGenus(of: parts)
                var candidateDiagnostics: [MoldDiagnostic] = []
                do {
                    let boredShell = try boreCylinder(
                        into: parts,
                        center: segment.center,
                        axis: normal,
                        radius: spoutRadius,
                        length: segment.length,
                        diagnostics: &candidateDiagnostics,
                        label: "spout"
                    )
                    guard boredShell.boredPartIndices.count == 1 else {
                        if spout.mode == .manual {
                            diagnostics.append(contentsOf: candidateDiagnostics.filter { $0.severity != .info })
                            if boredShell.rejectedFaceConnectedComponentCount == nil {
                                diagnostics.append(MoldDiagnostic(
                                    .warning,
                                    "The manual spout did not form one safe channel. Move it away from the seam and onto a clear upper surface of one mold part."
                                ))
                            }
                        }
                        continue
                    }

                    let funnelLength = 12.0
                    let attachmentOverlap = min(0.75, wall * 0.5)
                    let funnelRadiusLow = spoutRadius + 2.0
                    let nominalExitProjection = dot(spoutCenter, normal) + wall
                    let measuredExitProjection = try outerFunnelFootprintProjection(
                        parts: parts,
                        eligiblePartIndices: boredShell.boredPartIndices,
                        probeCenter: segment.center,
                        axis: normal,
                        outerRadius: funnelRadiusLow,
                        innerRadius: spoutRadius,
                        length: segment.length
                    )
                    let exitProjection = measuredExitProjection ?? nominalExitProjection
                    let centerOffset = exitProjection - dot(spoutCenter, normal)
                        + funnelLength / 2.0 - attachmentOverlap
                    let funnelCenter = add(spoutCenter, scale(normal, centerOffset))
                    let funnel = try attachUniqueFunnel(
                        to: boredShell.parts,
                        eligibleOwnerIndices: boredShell.boredPartIndices,
                        center: funnelCenter,
                        axis: normal,
                        radiusLow: funnelRadiusLow,
                        radiusHigh: spout.spoutDiameter * 1.5,
                        length: funnelLength,
                        boreCenter: segment.center,
                        boreRadius: spoutRadius,
                        boreLength: segment.length,
                        diagnostics: &candidateDiagnostics
                    )
                    guard let ownerIndex = funnel.ownerIndex else {
                        if spout.mode == .manual {
                            diagnostics.append(contentsOf: candidateDiagnostics.filter { $0.severity != .info })
                            diagnostics.append(MoldDiagnostic(
                                .warning,
                                "The manual funnel cannot fit entirely on one mold part at this location. Move it farther from the seam or reduce its diameter."
                            ))
                        }
                        continue
                    }

                    let genusAfterSpout = try manifoldGenus(of: funnel.parts)
                    guard genusAfterSpout == genusBeforeSpout + 1 else {
                        if spout.mode == .manual {
                            diagnostics.append(MoldDiagnostic(
                                .warning,
                                "The manual spout would create an unintended extra opening. Move it onto a clear upper surface of one mold part and rebuild."
                            ))
                        }
                        continue
                    }

                    if protectedLocator != nil {
                        guard let minimumCandidateProtectedRetention,
                              let retention = protectedLocatorAudit?.retainedFraction(in: funnel.parts) else {
                            rejectedProtectedSpoutCandidates += 1
                            if spout.mode == .manual {
                                diagnostics.append(MoldDiagnostic(
                                    .warning,
                                    "The manual spout cannot be verified without compromising the generated locator. Move it away from the base fixture and rebuild."
                                ))
                            }
                            continue
                        }
                        guard retention + 1.0e-6 >= minimumCandidateProtectedRetention else {
                            rejectedProtectedSpoutCandidates += 1
                            if spout.mode == .manual {
                                diagnostics.append(MoldDiagnostic(
                                    .warning,
                                    String(
                                        format: "The manual spout would leave only %.1f%% of the generated locator. Move it away from the base fixture and rebuild.",
                                        retention * 100
                                    )
                                ))
                            }
                            continue
                        }
                    }

                    updatedParts = funnel.parts
                    spoutBored = true
                    resolvedSpoutLocation = spoutCenter
                    diagnostics.append(contentsOf: candidateDiagnostics.filter { $0.severity == .info })
                    if spout.mode == .auto, candidateIndex > 0 {
                        diagnostics.append(MoldDiagnostic(
                            .info,
                            "Auto moved the funnel away from the top-center seam so the complete pour channel belongs to one mold part."
                        ))
                    }
                    if spout.mode == .auto, rejectedProtectedSpoutCandidates > 0 {
                        diagnostics.append(MoldDiagnostic(
                            .info,
                            "Auto skipped \(rejectedProtectedSpoutCandidates) spout location(s) that would compromise the generated locator."
                        ))
                    }
                    diagnostics.append(MoldDiagnostic(
                        .info,
                        "Built a sealed funnel and round fill channel on \"\(updatedParts[ownerIndex].name)\"."
                    ))
                    break
                } catch {
                    if spout.mode == .manual {
                        diagnostics.append(MoldDiagnostic(
                            .warning,
                            "The manual spout could not be built at this location. Move it onto a clear upper surface and rebuild."
                        ))
                    }
                }
            }
            if !spoutBored, spout.mode == .auto {
                let exhaustion = candidates.count >= autoSpoutCandidateLimit
                    ? " after exhausting the bounded search of \(candidates.count) candidate locations"
                    : " after evaluating all \(candidates.count) candidate location(s)"
                diagnostics.append(MoldDiagnostic(
                    .warning,
                    "Auto could not place a sealed funnel entirely on one mold part\(exhaustion). Switch Spout to Manual, move it away from seams, and rebuild."
                ))
            }
        }

        let ventCandidates = spout.ventCount > 0 ? resolveVentCandidates(
            cavity: cavity,
            openNormal: normal,
            excludedCenter: resolvedSpoutLocation,
            ventCount: spout.ventCount,
            minSeparation: spout.spoutDiameter * 2.0,
            seed: seed
        ) : []

        var ventsBored = 0
        var ventRemovedVolume = 0.0
        var ventLocations: [Vec3] = []
        var rejectedVentCandidates = 0
        var ventAttemptCount = 0
        for ventCenter in ventCandidates {
            if ventsBored >= spout.ventCount { break }
            ventAttemptCount += 1
            let segment = oneSidedBoreSegment(
                entry: ventCenter,
                axis: normal,
                cavity: cavity,
                settings: settings
            )
            let genusBeforeVent = try manifoldGenus(of: updatedParts)
            var candidateDiagnostics: [MoldDiagnostic] = []
            do {
                let boredVent = try boreCylinder(
                    into: updatedParts,
                    center: segment.center,
                    axis: normal,
                    radius: max(0.025, spout.ventDiameter / 2.0),
                    length: segment.length,
                    diagnostics: &candidateDiagnostics,
                    label: "vent-\(ventAttemptCount)"
                )
                if boredVent.boredPartIndices.isEmpty {
                    rejectedVentCandidates += 1
                    continue
                }
                let genusAfterVent = try manifoldGenus(of: boredVent.parts)
                guard genusAfterVent == genusBeforeVent + 1 else {
                    rejectedVentCandidates += 1
                    continue
                }
                if protectedLocator != nil {
                    guard let minimumCandidateProtectedRetention,
                          let retention = protectedLocatorAudit?.retainedFraction(in: boredVent.parts) else {
                        rejectedVentCandidates += 1
                        continue
                    }
                    guard retention + 1.0e-6 >= minimumCandidateProtectedRetention else {
                        rejectedVentCandidates += 1
                        continue
                    }
                }
                updatedParts = boredVent.parts
                ventsBored += 1
                ventLocations.append(ventCenter)
                ventRemovedVolume += boredVent.removedVolume
                diagnostics.append(contentsOf: candidateDiagnostics.filter { $0.severity == .info })
            } catch {
                rejectedVentCandidates += 1
            }
        }

        let ventSummary = "Bored \(ventsBored) of \(spout.ventCount) requested one-sided vents"
            + " (\(formatVolume(ventRemovedVolume)) mm^3 removed)."
            + (ventsBored < spout.ventCount
                ? " Reduce Vent diameter or Vent count, or reorient the model, then rebuild."
                : "")
        if spout.ventCount > 0 {
            diagnostics.append(MoldDiagnostic(.info, ventSummary))
            if ventsBored == spout.ventCount, rejectedVentCandidates > 0 {
                diagnostics.append(MoldDiagnostic(
                    .info,
                    "Auto skipped \(rejectedVentCandidates) unsafe vent location(s) and placed every requested vent."
                ))
            }
        }

        return FeatureResult(
            parts: updatedParts,
            spoutLocation: resolvedSpoutLocation,
            ventLocations: ventLocations,
            diagnostics: diagnostics,
            spoutBored: spoutBored,
            ventsBoredCount: ventsBored
        )
    }

    // MARK: - Private helpers

    static func retainedProtectedLocatorFraction(
        locator: MeshGeometryData,
        in parts: [MotherMoldPart]
    ) -> Double? {
        ProtectedLocatorAudit(locator: locator)?.retainedFraction(in: parts)
    }

    private static func resolvedSpoutCandidates(
        cavity: MeshGeometryData,
        openPlane: PartitionPlane,
        settings: SpoutSettings,
        partingPlanes: [PartitionPlane],
        seamPlateHalfThickness: Double = 0
    ) -> [Vec3] {
        switch settings.mode {
        case .manual:
            return [settings.manualSpout]
        case .auto:
            let first = topmostCentroid(
                of: cavity,
                along: openPlane.normal,
                openPlaneOffset: openPlane.offset
            )
            guard !cavity.vertices.isEmpty else { return [first] }

            let normal = normalized(openPlane.normal)
            let projections = cavity.vertices.map { dot($0, normal) }
            guard let minimum = projections.min(), let maximum = projections.max() else {
                return [first]
            }
            let searchDepth = max(6.0, (maximum - minimum) * 0.75)
            let minimumProjection = maximum - searchDepth
            func seamClearance(_ point: Vec3) -> Double {
                partingPlanes.map { abs(dot(point, normalized($0.normal)) - $0.offset) }.min()
                    ?? Double.greatestFiniteMagnitude
            }
            let ordered = cavity.vertices
                .filter { dot($0, normal) >= minimumProjection }
                .sorted { lhs, rhs in
                    let lhsProjection = dot(lhs, normal)
                    let rhsProjection = dot(rhs, normal)
                    let lhsScore = seamClearance(lhs) - (maximum - lhsProjection) * 0.25
                    let rhsScore = seamClearance(rhs) - (maximum - rhsProjection) * 0.25
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    if lhsProjection != rhsProjection { return lhsProjection > rhsProjection }
                    if lhs.x != rhs.x { return lhs.x < rhs.x }
                    if lhs.y != rhs.y { return lhs.y < rhs.y }
                    return lhs.z < rhs.z
                }

            let requiredSeamClearance = settings.spoutDiameter * 1.5 + 0.5
            var candidates: [Vec3] = []
            if partingPlanes.isEmpty || seamClearance(first) >= requiredSeamClearance {
                candidates.append(first)
            }
            let separation = max(2.0, settings.spoutDiameter * 0.75)
            for vertex in ordered {
                let separated = candidates.allSatisfy {
                    perpendicularDistance(vertex, $0, axis: normal) >= separation
                }
                if separated { candidates.append(vertex) }
                if candidates.count >= autoSpoutCandidateLimit { break }
            }

            // A flat or low-poly top has no vertices inside its faces, so the
            // probes above can only offer its centre (often on a seam) and its
            // rim (where a bore cuts the side walls). Step the top centre off
            // each seam and drop it onto the cavity's upper surface: the
            // nearest points a funnel can own. The funnel's rim (1.5 spout
            // diameters across) must also clear the flange plate standing on
            // the seam, or the two fuse into an extra opening.
            for point in seamClearedTopCandidates(
                from: first,
                cavity: cavity,
                normal: normal,
                partingPlanes: partingPlanes,
                clearance: settings.spoutDiameter * 1.5 + max(0, seamPlateHalfThickness) + 0.75
            ) {
                if candidates.count >= autoSpoutCandidateLimit { break }
                guard seamClearance(point) >= requiredSeamClearance,
                      !candidates.contains(where: { distance(point, $0) < 0.01 }) else { continue }
                candidates.append(point)
            }

            // Sparse and low-poly artwork may have no safe channel at the few
            // widely separated probes above. Fill the remaining bounded search
            // pool with deterministic upper-surface vertices so Auto can find a
            // valid location between those coarse probes without relaxing any
            // bore, topology, interface, or locator acceptance gate.
            if candidates.count < autoSpoutCandidateLimit {
                for vertex in ordered {
                    if candidates.count >= autoSpoutCandidateLimit { break }
                    let alreadyChosen = candidates.contains {
                        distance(vertex, $0) < 0.01
                    }
                    if !alreadyChosen { candidates.append(vertex) }
                }
            }
            return candidates
        }
    }

    /// Points on the cavity's upper surface reached by moving `centre` away from
    /// the parting planes until it is `clearance` from each, in every
    /// combination of sides. Each point is dropped onto the highest cavity
    /// triangle below it along `normal`; points over no triangle are skipped.
    private static func seamClearedTopCandidates(
        from centre: Vec3,
        cavity: MeshGeometryData,
        normal: Vec3,
        partingPlanes: [PartitionPlane],
        clearance: Double
    ) -> [Vec3] {
        let planes = partingPlanes.prefix(2).compactMap { plane -> (Vec3, Double, Vec3, Double)? in
            let planeNormal = normalized(plane.normal)
            let lateral = add(planeNormal, scale(normal, -dot(planeNormal, normal)))
            let lateralLength = (dot(lateral, lateral)).squareRoot()
            // A parting plane parallel to the top cannot be stepped away from
            // by moving across the top.
            guard lateralLength > 0.1 else { return nil }
            return (planeNormal, plane.offset, scale(lateral, 1 / lateralLength), lateralLength)
        }
        guard !planes.isEmpty else { return [] }

        var points: [Vec3] = []
        let signCombinations = planes.count == 1
            ? [[1.0], [-1.0]]
            : [[1.0, 1.0], [1.0, -1.0], [-1.0, 1.0], [-1.0, -1.0]]
        for signs in signCombinations {
            var point = centre
            for (index, plane) in planes.enumerated() {
                let signedDistance = dot(point, plane.0) - plane.1
                let target = signs[index] * clearance
                point = add(point, scale(plane.2, (target - signedDistance) / plane.3))
            }
            if let surfacePoint = highestCavityPoint(above: point, cavity: cavity, normal: normal) {
                points.append(surfacePoint)
            }
        }
        return points
    }

    /// The highest point of `cavity` on the line through `point` along `normal`.
    private static func highestCavityPoint(
        above point: Vec3,
        cavity: MeshGeometryData,
        normal: Vec3
    ) -> Vec3? {
        var best: Double?
        let indices = cavity.triangleIndices
        var t = 0
        while t + 2 < indices.count {
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            t += 3
            guard cavity.vertices.indices.contains(ia),
                  cavity.vertices.indices.contains(ib),
                  cavity.vertices.indices.contains(ic) else { continue }
            let a = cavity.vertices[ia], b = cavity.vertices[ib], c = cavity.vertices[ic]
            // Moller-Trumbore with the line through `point` along `normal`.
            let e1 = add(b, scale(a, -1)), e2 = add(c, scale(a, -1))
            let p = Vec3(
                x: normal.y * e2.z - normal.z * e2.y,
                y: normal.z * e2.x - normal.x * e2.z,
                z: normal.x * e2.y - normal.y * e2.x
            )
            let determinant = dot(e1, p)
            guard abs(determinant) > 1.0e-12 else { continue }
            let inverse = 1 / determinant
            let s = add(point, scale(a, -1))
            let u = dot(s, p) * inverse
            guard u >= 0, u <= 1 else { continue }
            let q = Vec3(
                x: s.y * e1.z - s.z * e1.y,
                y: s.z * e1.x - s.x * e1.z,
                z: s.x * e1.y - s.y * e1.x
            )
            let v = dot(normal, q) * inverse
            guard v >= 0, u + v <= 1 else { continue }
            let along = dot(e2, q) * inverse
            if best.map({ along > $0 }) ?? true { best = along }
        }
        return best.map { add(point, scale(normal, $0)) }
    }

    /// The segment begins just inside the cavity-facing surface and extends only
    /// toward the exterior. Limiting the inward reach to a fraction of the cavity
    /// depth keeps even a thin cavity from being drilled through its far wall.
    private static func oneSidedBoreSegment(
        entry: Vec3,
        axis: Vec3,
        cavity: MeshGeometryData,
        settings: MotherMoldSettings
    ) -> BoreSegment {
        var minProjection = Double.infinity
        var maxProjection = -Double.infinity
        for vertex in cavity.vertices {
            let projection = dot(vertex, axis)
            minProjection = min(minProjection, projection)
            maxProjection = max(maxProjection, projection)
        }
        let cavityDepth = minProjection.isFinite && maxProjection.isFinite
            ? max(0, maxProjection - minProjection)
            : 0
        let insideDepth = min(2.0, max(0.05, cavityDepth * 0.25))
        let outsideReach = max(0.1, settings.wallThickness)
            + max(0, settings.siliconeGap)
            + max(0, settings.smoothing)
            + 25.0
        let length = insideDepth + outsideReach
        return BoreSegment(
            center: add(entry, scale(axis, (outsideReach - insideDepth) / 2.0)),
            length: length
        )
    }

    /// Return the centroid of the topmost layer of cavity vertices (the ones
    /// with the highest projection along `along`). "Topmost layer" = all vertices
    /// within a thin band at the maximum projection value.
    private static func topmostCentroid(
        of cavity: MeshGeometryData,
        along normal: Vec3,
        openPlaneOffset: Double
    ) -> Vec3 {
        guard !cavity.vertices.isEmpty else {
            // Fall back to the point on the open plane itself at the origin.
            return Vec3(
                x: normal.x * openPlaneOffset,
                y: normal.y * openPlaneOffset,
                z: normal.z * openPlaneOffset
            )
        }

        // Project every vertex.
        var maxProj = -Double.infinity
        for v in cavity.vertices {
            let p = dot(v, normal)
            if p > maxProj { maxProj = p }
        }

        // Gather the topmost band (within 1 mm of the peak).
        let bandTolerance = 1.0
        var sumX = 0.0, sumY = 0.0, sumZ = 0.0, count = 0
        for v in cavity.vertices {
            if dot(v, normal) >= maxProj - bandTolerance {
                sumX += v.x; sumY += v.y; sumZ += v.z; count += 1
            }
        }
        guard count > 0 else {
            return cavity.vertices[0]
        }
        let d = Double(count)
        return Vec3(x: sumX / d, y: sumY / d, z: sumZ / d)
    }

    /// Deterministic vent placement: sort cavity vertices by projection descending,
    /// walk with a stride derived from `seed`, and spread candidates from each
    /// other and from the resolved sacrificial fill gate.
    private static func resolveVentCandidates(
        cavity: MeshGeometryData,
        openNormal: Vec3,
        excludedCenter: Vec3?,
        ventCount: Int,
        minSeparation: Double,
        seed: Int
    ) -> [Vec3] {
        guard !cavity.vertices.isEmpty, ventCount > 0 else { return [] }

        let sorted = cavity.vertices.sorted { lhs, rhs in
            let lhsProjection = dot(lhs, openNormal)
            let rhsProjection = dot(rhs, openNormal)
            if lhsProjection != rhsProjection { return lhsProjection > rhsProjection }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }

        // Stride offset from seed to spread candidates deterministically.
        let stride = Swift.max(1, (sorted.count / (ventCount * 4 + 1)) + (seed % 3))
        let poolLimit = min(32, sorted.count)

        var chosen: [Vec3] = []
        var i = stride % sorted.count   // offset start by seed-derived stride
        var attempts = 0
        while chosen.count < poolLimit, attempts < sorted.count {
            let candidate = sorted[i % sorted.count]
            let farEnoughFromSpout = excludedCenter.map {
                distance(candidate, $0) >= minSeparation
            } ?? true
            let farEnoughFromOthers = chosen.allSatisfy { distance(candidate, $0) >= minSeparation }
            if farEnoughFromSpout && farEnoughFromOthers {
                chosen.append(candidate)
            }
            i += stride
            attempts += 1
        }

        // If we didn't find enough candidates with full separation, relax and
        // just take the next highest vertices we haven't picked yet.
        if chosen.count < poolLimit {
            for v in sorted {
                if chosen.count >= poolLimit { break }
                let alreadyChosen = chosen.contains(where: { distance($0, v) < 0.01 })
                let duplicatesSpout = excludedCenter.map { distance($0, v) < 0.01 } ?? false
                if !alreadyChosen && !duplicatesSpout {
                    chosen.append(v)
                }
            }
        }

        return chosen
    }

    /// Subtract a cylindrical tool from every geometrically intersecting part.
    /// AABB intersection only schedules the exact boolean; a part counts as bored
    /// only when the tool has positive solid intersection and accepted output has
    /// measurably less volume.
    private static func boreCylinder(
        into parts: [MotherMoldPart],
        center: Vec3,
        axis: Vec3,
        radius: Double,
        length: Double,
        diagnostics: inout [MoldDiagnostic],
        label: String
    ) throws -> BoreResult {
        guard radius > 0, length > 0 else {
            return BoreResult(parts: parts, boredPartIndices: [], removedVolume: 0)
        }

        // Build the cylinder tool solid: a Manifold cylinder of the given radius
        // and length, then rotate + translate to align with `axis` through `center`.
        let cylinder = try buildCylinderAlongAxis(
            center: center,
            axis: axis,
            radius: radius,
            length: length
        )

        // Subtract from each part that has a bounding volume (skip empty parts).
        var result: [MotherMoldPart] = []
        result.reserveCapacity(parts.count)
        var boredPartIndices: [Int] = []
        var removedVolume = 0.0
        for (partIndex, part) in parts.enumerated() {
            guard !part.geometry.vertices.isEmpty else {
                result.append(part)
                continue
            }
            do {
                let partHandle = try ManifoldEngine.make(from: part.geometry)
                // Only subtract if bores intersect the part's bounds at all
                // (cheap bounds check: project center onto the part's AABB).
                let partBounds = ManifoldEngine.bounds(partHandle)
                guard boreSegmentIntersectsBounds(
                    bounds: partBounds, center: center, axis: axis,
                    length: length, radius: radius
                ) else {
                    result.append(part)
                    continue
                }
                let beforeVolume = abs(ManifoldEngine.volume(partHandle))
                let toolIntersection = try ManifoldEngine.intersect(partHandle, cylinder)
                let intersectionVolume = abs(ManifoldEngine.volume(toolIntersection))
                guard intersectionVolume > positiveVolumeTolerance(referenceVolume: beforeVolume) else {
                    result.append(part)
                    continue
                }

                let toolIntersectionGeometry = try ManifoldEngine.toMesh(toolIntersection)
                let intersectionComponentCount = positiveFaceConnectedComponentCount(of: toolIntersectionGeometry)
                guard intersectionComponentCount <= 1 else {
                    diagnostics.append(MoldDiagnostic(.warning,
                        "\(label.capitalized) crosses \(intersectionComponentCount) separate wall regions in part \"\(part.name)\". Move it to a clearer surface so it cannot drill through the far wall."))
                    return BoreResult(
                        parts: parts,
                        boredPartIndices: [],
                        removedVolume: 0,
                        rejectedFaceConnectedComponentCount: intersectionComponentCount
                    )
                }

                let bored = try ManifoldEngine.difference(partHandle, cylinder)
                let afterVolume = abs(ManifoldEngine.volume(bored))
                let partRemovedVolume = max(0, beforeVolume - afterVolume)
                guard partRemovedVolume > positiveVolumeTolerance(referenceVolume: beforeVolume) else {
                    diagnostics.append(MoldDiagnostic(.warning,
                        "\(label.capitalized) intersected part \"\(part.name)\" but removed no measurable volume; skipped on this part."))
                    return BoreResult(parts: parts, boredPartIndices: [], removedVolume: 0)
                }

                let boredGeometry = try ManifoldEngine.toMesh(bored)
                var candidatePart = part
                candidatePart.geometry = boredGeometry
                candidatePart.bounds = ManifoldEngine.bounds(bored)
                let validation = MotherMoldValidation.validate(parts: [candidatePart])
                guard validation.allPartsWatertight,
                      let acceptedPart = validation.parts.first,
                      MoldComponentFilter.dropFaceDisconnectedDebris(acceptedPart.geometry).droppedCount == 0 else {
                    diagnostics.append(MoldDiagnostic(.warning,
                        "\(label.capitalized) bore would make part \"\(part.name)\" non-printable; skipped on this part."))
                    return BoreResult(parts: parts, boredPartIndices: [], removedVolume: 0)
                }
                let beforeGenus = try manifoldGenus(of: part.geometry)
                let afterGenus = try manifoldGenus(of: acceptedPart.geometry)
                guard afterGenus == beforeGenus + 1 else {
                    diagnostics.append(MoldDiagnostic(.warning,
                        "\(label.capitalized) bore would change part \"\(part.name)\" genus from \(beforeGenus) to \(afterGenus); skipped."))
                    return BoreResult(
                        parts: parts,
                        boredPartIndices: [],
                        removedVolume: 0,
                        rejectedFaceConnectedComponentCount: nil
                    )
                }
                diagnostics.append(contentsOf: validation.diagnostics.filter { $0.severity == .info })

                result.append(acceptedPart)
                boredPartIndices.append(partIndex)
                removedVolume += partRemovedVolume
                withExtendedLifetime(bored) {}
            } catch {
                diagnostics.append(MoldDiagnostic(.warning,
                    "Could not bore \(label) through part \"\(part.name)\": \(error.localizedDescription)"))
                return BoreResult(parts: parts, boredPartIndices: [], removedVolume: 0)
            }
        }
        return BoreResult(
            parts: result,
            boredPartIndices: boredPartIndices,
            removedVolume: removedVolume
        )
    }

    /// Attach exactly one hollow funnel to one deterministically selected part.
    /// A funnel that touches a neighboring part is rejected. Carving clearance
    /// into another half creates an unsealed opening when the mold is assembled.
    private static func attachUniqueFunnel(
        to parts: [MotherMoldPart],
        eligibleOwnerIndices: [Int],
        center: Vec3,
        axis: Vec3,
        radiusLow: Double,
        radiusHigh: Double,
        length: Double,
        boreCenter: Vec3,
        boreRadius: Double,
        boreLength: Double,
        diagnostics: inout [MoldDiagnostic],
    ) throws -> FunnelResult {
        guard radiusLow > 0, radiusHigh > 0, length > 0 else {
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }
        let frustum = try buildFrustumAlongAxis(
            center: center,
            axis: axis,
            radiusLow: radiusLow,
            radiusHigh: radiusHigh,
            length: length
        )
        let bore = try buildCylinderAlongAxis(
            center: boreCenter,
            axis: axis,
            radius: boreRadius,
            length: boreLength
        )
        let hollowFunnel = try ManifoldEngine.difference(frustum, bore)
        guard !ManifoldEngine.isEmpty(hollowFunnel) else {
            diagnostics.append(MoldDiagnostic(.warning,
                "The funnel became empty after opening its throat."))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }
        var ownerIndex: Int?
        var bestAttachmentVolume = 0.0
        for index in eligibleOwnerIndices.sorted() where parts.indices.contains(index) {
            let partHandle = try ManifoldEngine.make(from: parts[index].geometry)
            let attachment = try ManifoldEngine.intersect(partHandle, hollowFunnel)
            let attachmentVolume = abs(ManifoldEngine.volume(attachment))
            if attachmentVolume > bestAttachmentVolume {
                bestAttachmentVolume = attachmentVolume
                ownerIndex = index
            }
        }
        guard let ownerIndex,
              bestAttachmentVolume > positiveVolumeTolerance(referenceVolume: ManifoldEngine.volume(hollowFunnel)) else {
            diagnostics.append(MoldDiagnostic(.warning,
                "The funnel did not have positive attachment volume with any shell part."))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }

        var result = parts
        let funnelVolume = abs(ManifoldEngine.volume(hollowFunnel))
        for index in parts.indices where index != ownerIndex && !parts[index].geometry.vertices.isEmpty {
            let other = try ManifoldEngine.make(from: parts[index].geometry)
            let overlap = try ManifoldEngine.intersect(other, hollowFunnel)
            let overlapVolume = abs(ManifoldEngine.volume(overlap))
            guard overlapVolume > positiveVolumeTolerance(referenceVolume: funnelVolume) else { continue }
            diagnostics.append(MoldDiagnostic(
                .warning,
                "The funnel crosses the seam into \"\(parts[index].name)\". Move the spout farther onto one mold part."
            ))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }

        let owner = try ManifoldEngine.make(from: parts[ownerIndex].geometry)
        let ownerVolume = abs(ManifoldEngine.volume(owner))
        let united = try ManifoldEngine.union(owner, hollowFunnel)
        let unitedVolume = abs(ManifoldEngine.volume(united))
        let addedVolume = max(0, unitedVolume - ownerVolume)
        guard addedVolume > positiveVolumeTolerance(referenceVolume: ownerVolume) else {
            diagnostics.append(MoldDiagnostic(.warning,
                "The funnel union added no measurable material to \"\(parts[ownerIndex].name)\"."))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }

        let geometry = try ManifoldEngine.toMesh(united)
        let disconnected = MoldComponentFilter.dropFaceDisconnectedDebris(geometry)
        guard disconnected.droppedCount == 0 else {
            diagnostics.append(MoldDiagnostic(.warning,
                "The funnel union would leave \"\(parts[ownerIndex].name)\" with disconnected solids."))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }
        let closure = MotherMoldValidation.surfaceClosure(geometry)
        let acceptedGeometry: MeshGeometryData
        let acceptedHandle: ManifoldHandle
        if closure.closed {
            acceptedGeometry = geometry
            acceptedHandle = united
        } else if let validated = try? ManifoldEngine.make(from: geometry),
                  let readback = try? ManifoldEngine.toMesh(validated) {
            acceptedGeometry = readback
            acceptedHandle = validated
        } else {
            diagnostics.append(MoldDiagnostic(.warning,
                "The funnel union made part \"\(parts[ownerIndex].name)\" non-watertight."))
            return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
        }

        result[ownerIndex].geometry = acceptedGeometry
        result[ownerIndex].bounds = ManifoldEngine.bounds(acceptedHandle)

        for index in result.indices where index != ownerIndex && !result[index].geometry.vertices.isEmpty {
            let other = try ManifoldEngine.make(from: result[index].geometry)
            let beforeOwner = try ManifoldEngine.make(from: parts[ownerIndex].geometry)
            let beforeOther = try ManifoldEngine.make(from: parts[index].geometry)
            let beforeOverlap = try ManifoldEngine.intersect(beforeOwner, beforeOther)
            let afterOverlap = try ManifoldEngine.intersect(acceptedHandle, other)
            let beforeVolume = abs(ManifoldEngine.volume(beforeOverlap))
            let afterVolume = abs(ManifoldEngine.volume(afterOverlap))
            let tolerance = positiveVolumeTolerance(referenceVolume: unitedVolume)
            guard afterVolume <= beforeVolume + tolerance else {
                diagnostics.append(MoldDiagnostic(.warning,
                    "The funnel would add \(formatVolume(afterVolume - beforeVolume)) mm^3 of overlap with \"\(parts[index].name)\"."))
                return FunnelResult(parts: parts, ownerIndex: nil, addedVolume: 0)
            }
        }

        return FunnelResult(parts: result, ownerIndex: ownerIndex, addedVolume: addedVolume)
    }

    /// Locate the actual outer shell surface under the hollow funnel footprint.
    /// Organic peaks are not guaranteed to place the exterior exactly one nominal
    /// wall thickness above the cavity point, especially after Minkowski offset
    /// and multi-plane partitioning. Intersecting the pre-bore shell with the
    /// annular footprint gives the outermost projection the funnel must overlap.
    private static func outerFunnelFootprintProjection(
        parts: [MotherMoldPart],
        eligiblePartIndices: [Int],
        probeCenter: Vec3,
        axis: Vec3,
        outerRadius: Double,
        innerRadius: Double,
        length: Double
    ) throws -> Double? {
        guard outerRadius > innerRadius, innerRadius > 0, length > 0 else { return nil }
        let outer = try buildCylinderAlongAxis(
            center: probeCenter,
            axis: axis,
            radius: outerRadius,
            length: length
        )
        let inner = try buildCylinderAlongAxis(
            center: probeCenter,
            axis: axis,
            radius: innerRadius,
            length: length
        )
        let footprint = try ManifoldEngine.difference(outer, inner)
        var outermost: Double?
        for index in eligiblePartIndices.sorted() where parts.indices.contains(index) {
            let part = try ManifoldEngine.make(from: parts[index].geometry)
            let intersection = try ManifoldEngine.intersect(part, footprint)
            guard !ManifoldEngine.isEmpty(intersection),
                  let geometry = try? ManifoldEngine.toMesh(intersection) else {
                continue
            }
            for vertex in geometry.vertices {
                let projection = dot(vertex, axis)
                outermost = max(outermost ?? projection, projection)
            }
        }
        return outermost
    }

    /// Build a cylinder solid aligned along `axis` through `center`.
    /// The cylinder is built along +Z in Manifold's local frame, then rotated to
    /// align with `axis`, then translated to `center`.
    ///
    /// Uses `manifold_cylinder` from the C API (height, low radius, high radius,
    /// circular segments, center flag). We use 24 segments for a smooth bore.
    private static func buildCylinderAlongAxis(
        center: Vec3,
        axis: Vec3,
        radius: Double,
        length: Double
    ) throws -> ManifoldHandle {
        // manifold_cylinder is available in the C API. We call it inline.
        // Signature (from manifoldc.h):
        //   ManifoldManifold* manifold_cylinder(void* mem, double height,
        //     double radius_low, double radius_high, int circular_segments, int center)
        let mem = UnsafeMutableRawPointer.allocate(
            byteCount: manifold_manifold_size(), alignment: 16
        )
        let raw = manifold_cylinder(mem, length, radius, radius, 24, 1)
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
        let cylinderHandle = ManifoldHandle(adopting: mem, manifold: raw)

        // The cylinder is built along +Z with center at origin.
        // Rotate to align with `axis` (which is a unit normal).
        let rotated = try rotateCylinderToAxis(cylinderHandle, targetAxis: axis)

        // Translate to `center`.
        let translated = try ManifoldEngine.translate(rotated, x: center.x, y: center.y, z: center.z)
        withExtendedLifetime(rotated) {}
        return translated
    }

    /// Build a conical frustum solid aligned along `axis` through `center`.
    private static func buildFrustumAlongAxis(
        center: Vec3,
        axis: Vec3,
        radiusLow: Double,
        radiusHigh: Double,
        length: Double
    ) throws -> ManifoldHandle {
        let mem = UnsafeMutableRawPointer.allocate(
            byteCount: manifold_manifold_size(), alignment: 16
        )
        let raw = manifold_cylinder(mem, length, radiusLow, radiusHigh, 32, 1)
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
        let frustumHandle = ManifoldHandle(adopting: mem, manifold: raw)
        let rotated = try rotateCylinderToAxis(frustumHandle, targetAxis: axis)
        let translated = try ManifoldEngine.translate(rotated, x: center.x, y: center.y, z: center.z)
        withExtendedLifetime(rotated) {}
        return translated
    }

    /// Rotate a cylinder built along +Z to align with `targetAxis` using the
    /// minimal rotation (axis-angle) decomposed into Manifold's XYZ Euler angles.
    private static func rotateCylinderToAxis(
        _ h: ManifoldHandle,
        targetAxis: Vec3
    ) throws -> ManifoldHandle {
        // If the axis is already +Z, no rotation needed.
        let zAxis = Vec3(x: 0, y: 0, z: 1)
        let dot_ = dot(targetAxis, zAxis)   // cos θ
        if dot_ > 1.0 - 1.0e-9 {
            return h
        }
        if dot_ < -1.0 + 1.0e-9 {
            // Flip 180° around X.
            return try ManifoldEngine.rotate(h, degreesX: 180, degreesY: 0, degreesZ: 0)
        }

        // Cross product gives the rotation axis.
        let rx = zAxis.y * targetAxis.z - zAxis.z * targetAxis.y
        let ry = zAxis.z * targetAxis.x - zAxis.x * targetAxis.z
        let rz = zAxis.x * targetAxis.y - zAxis.y * targetAxis.x
        let rLen = (rx * rx + ry * ry + rz * rz).squareRoot()
        guard rLen > 1.0e-12 else { return h }
        let rnx = rx / rLen, rny = ry / rLen, rnz = rz / rLen
        let angleDeg = acos(Swift.max(-1, Swift.min(1, dot_))) * (180.0 / .pi)

        // Decompose axis-angle into Manifold XYZ Euler angles.
        // Manifold applies R_z * R_y * R_x (intrinsic XYZ Euler). We approximate
        // via a 3×3 rotation matrix from axis-angle (Rodrigues) then extract
        // the Euler angles assuming Manifold's convention.
        let (ex, ey, ez) = eulerXYZFromAxisAngle(
            nx: rnx, ny: rny, nz: rnz, angleDeg: angleDeg
        )
        let rotated = try ManifoldEngine.rotate(h, degreesX: ex, degreesY: ey, degreesZ: ez)
        withExtendedLifetime(h) {}
        return rotated
    }

    /// Rodrigues → rotation matrix → Manifold XYZ Euler extraction.
    /// Manifold's `manifold_rotate(mem, m, rx, ry, rz)` applies:
    ///   R = Rz(rz) * Ry(ry) * Rx(rx)   (extrinsic-XYZ = intrinsic-ZYX)
    /// We extract from the column of the rotation matrix.
    private static func eulerXYZFromAxisAngle(
        nx: Double, ny: Double, nz: Double, angleDeg: Double
    ) -> (Double, Double, Double) {
        let θ = angleDeg * (.pi / 180.0)
        let c = cos(θ), s = sin(θ), t = 1 - c

        // Rodrigues rotation matrix (row-major).
        let m00 = t*nx*nx + c;    let _ = t*nx*ny - s*nz;   let _ = t*nx*nz + s*ny
        let m10 = t*nx*ny + s*nz; let m11 = t*ny*ny + c;    let m12 = t*ny*nz - s*nx
        let m20 = t*nx*nz - s*ny; let m21 = t*ny*nz + s*nx; let m22 = t*nz*nz + c

        // Extract extrinsic-XYZ (= intrinsic-ZYX) Euler angles.
        // ry from m02, then rx and rz.
        let ry = asin(-Swift.max(-1, Swift.min(1, m20)))
        let rx: Double
        let rz: Double
        if abs(cos(ry)) > 1.0e-9 {
            rx = atan2(m21, m22)
            rz = atan2(m10, m00)
        } else {
            rx = atan2(-m12, m11)
            rz = 0
        }

        let toDeg = 180.0 / .pi
        return (rx * toDeg, ry * toDeg, rz * toDeg)
    }

    /// Correct segment-vs-AABB (slab) intersection test for the bore. The bore is
    /// the cylinder segment from `center - axis·(length/2)` to
    /// `center + axis·(length/2)`; the AABB is expanded by the bore `radius` so a
    /// cylinder grazing a face still counts. Returns true iff the segment
    /// overlaps the (expanded) box. This replaces the old center-to-center
    /// `maxHalf + radius` heuristic, which was neither a point-in-AABB nor a
    /// line-vs-AABB test and could both falsely skip a part the bore pierces and
    /// falsely bore one it misses.
    private static func boreSegmentIntersectsBounds(
        bounds: Bounds3D,
        center: Vec3,
        axis: Vec3,
        length: Double,
        radius: Double
    ) -> Bool {
        let half = length / 2.0
        let p0 = Vec3(x: center.x - axis.x * half,
                      y: center.y - axis.y * half,
                      z: center.z - axis.z * half)
        let d = Vec3(x: axis.x * length, y: axis.y * length, z: axis.z * length)

        // Expand the box by the bore radius (the cylinder has thickness).
        let minB = Vec3(x: bounds.min.x - radius, y: bounds.min.y - radius, z: bounds.min.z - radius)
        let maxB = Vec3(x: bounds.max.x + radius, y: bounds.max.y + radius, z: bounds.max.z + radius)

        // Slab method over the parametric segment p0 + t·d, t ∈ [0, 1].
        var tEnter = 0.0
        var tExit = 1.0
        let eps = 1.0e-12

        func slab(_ p: Double, _ dir: Double, _ lo: Double, _ hi: Double) -> Bool {
            if abs(dir) < eps {
                // Segment parallel to this slab: reject if origin is outside it.
                return p >= lo && p <= hi
            }
            var t0 = (lo - p) / dir
            var t1 = (hi - p) / dir
            if t0 > t1 { swap(&t0, &t1) }
            tEnter = Swift.max(tEnter, t0)
            tExit = Swift.min(tExit, t1)
            return tEnter <= tExit
        }

        guard slab(p0.x, d.x, minB.x, maxB.x) else { return false }
        guard slab(p0.y, d.y, minB.y, maxB.y) else { return false }
        guard slab(p0.z, d.z, minB.z, maxB.z) else { return false }
        return tEnter <= tExit
    }

    // MARK: - Math primitives

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard length > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func perpendicularDistance(_ lhs: Vec3, _ rhs: Vec3, axis: Vec3) -> Double {
        let delta = Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
        let along = dot(delta, axis)
        let perpendicular = Vec3(
            x: delta.x - axis.x * along,
            y: delta.y - axis.y * along,
            z: delta.z - axis.z * along
        )
        return (perpendicular.x * perpendicular.x
            + perpendicular.y * perpendicular.y
            + perpendicular.z * perpendicular.z).squareRoot()
    }

    private static func positiveVolumeTolerance(referenceVolume: Double) -> Double {
        max(1.0e-7, abs(referenceVolume) * 1.0e-10)
    }

    private static func positiveFaceConnectedComponentCount(of geometry: MeshGeometryData) -> Int {
        guard !geometry.vertices.isEmpty, !geometry.triangleIndices.isEmpty else { return 0 }
        let disconnected = MoldComponentFilter.dropFaceDisconnectedDebris(geometry)
        return disconnected.droppedCount > 0 ? disconnected.droppedCount + 1 : 1
    }

    private static func manifoldGenus(of geometry: MeshGeometryData) throws -> Int {
        try ManifoldEngine.genus(ManifoldEngine.make(from: geometry))
    }

    private static func manifoldGenus(of parts: [MotherMoldPart]) throws -> Int {
        var total = 0
        for part in parts {
            total += try manifoldGenus(of: part.geometry)
        }
        return total
    }

    private static func formatVolume(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    private static func scale(_ a: Vec3, _ s: Double) -> Vec3 {
        Vec3(x: a.x * s, y: a.y * s, z: a.z * s)
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
