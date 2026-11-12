import Foundation

/// Per-part validation gate run at the end of the pipeline: watertightness
/// (`MeshPreflight.isWatertight`), finite coordinates, non-empty AABB, and a
/// keyability / undercut summary. Stamps each part's `isWatertight` + `bounds`
/// and emits diagnostics for any part that fails a check.
enum MotherMoldValidation {
    /// Final topology repair may simplify boolean slivers, but never at or above
    /// the default 0.2 mm key clearance that the artist is relying on.
    static let maximumRepairSimplificationMM = 0.05
    private struct PrintableNormalization {
        var geometry: MeshGeometryData
        var diagnostic: String
    }

    private struct StrictCandidate {
        var geometry: MeshGeometryData
        var droppedDebrisCount: Int
        var droppedDebrisVolume: Double
    }

    private struct ContactSeparation {
        var geometry: MeshGeometryData
        var movedGroupCount: Int
    }

    /// Validation outcome: the parts with `isWatertight`/`bounds` populated, plus
    /// diagnostics and an overall pass flag.
    struct ValidationResult: Equatable {
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]
        var allPartsWatertight: Bool
        /// Final per-feature retention/void evidence, when reusable-tooling
        /// stages supplied a typed audit set.
        var protectedAudit: ProtectedToolingAuditSet.AuditResult? = nil

        var passes: Bool {
            allPartsWatertight && (protectedAudit?.passes ?? true)
        }

        static let empty = ValidationResult(parts: [], diagnostics: [], allPartsWatertight: true)
    }

    /// Validate every part. Populates `isWatertight` and `bounds` on each part
    /// and returns diagnostics for non-watertight / non-finite / empty parts.
    static func validate(parts: [MotherMoldPart]) -> ValidationResult {
        var validated: [MotherMoldPart] = []
        validated.reserveCapacity(parts.count)
        var diagnostics: [MoldDiagnostic] = []
        var allWatertight = true

        for part in parts {
            var p = part

            // Gate 1: finite coordinates.
            guard hasFiniteCoordinates(part.geometry) else {
                allWatertight = false
                p.isWatertight = false
                diagnostics.append(
                    MoldDiagnostic(.error,
                        "Part \"\(part.name)\" contains non-finite (NaN/Inf) coordinates.")
                )
                validated.append(p)
                continue
            }

            // Gate 2: non-empty geometry.
            guard !part.geometry.vertices.isEmpty,
                  part.geometry.triangleIndices.count >= 3 else {
                allWatertight = false
                p.isWatertight = false
                diagnostics.append(
                    MoldDiagnostic(.error, "Part \"\(part.name)\" is empty (no triangles).")
                )
                validated.append(p)
                continue
            }

            // Gate 3: tight AABB — compute even if it was already set (the
            // cylinder subtraction may have changed the geometry).
            p.bounds = boundsOf(part.geometry)

            // Gate 4: non-degenerate AABB (all three dimensions > epsilon).
            if let b = p.bounds {
                let eps = 1.0e-6
                let dx = b.max.x - b.min.x
                let dy = b.max.y - b.min.y
                let dz = b.max.z - b.min.z
                if dx < eps || dy < eps || dz < eps {
                    diagnostics.append(
                        MoldDiagnostic(.warning,
                            "Part \"\(part.name)\" is effectively flat or degenerate (extent < \(eps) mm in at least one axis).")
                    )
                }
            }

            // Gate 5: final mold parts must pass the strict import preflight.
            // Manifold validation is intentionally enough for a closed healed
            // master to enter the pipeline, but it is not enough for serialized
            // output: edge-touching self-contact remains non-manifold in STL.
            // Regularize those solids, then require the real import gate.
            let preflight = MeshPreflight.analyze(geometry: part.geometry)
            if preflight.isWatertight {
                p.isWatertight = true
            } else if let normalized = printableNormalizedGeometry(part.geometry) {
                p.geometry = normalized.geometry
                p.bounds = boundsOf(normalized.geometry)
                p.isWatertight = true
                diagnostics.append(MoldDiagnostic(
                    .info,
                    "Part \"\(part.name)\" \(normalized.diagnostic)"
                ))
            } else {
                allWatertight = false
                p.isWatertight = false
                let closure = Self.surfaceClosure(part.geometry)
                diagnostics.append(
                    MoldDiagnostic(.error,
                        "Part \"\(part.name)\" is not watertight. " +
                        "Import boundary edges: \(preflight.boundaryEdgeCount), " +
                        "non-manifold edges: \(preflight.nonManifoldEdgeCount), " +
                        "degenerate triangles: \(preflight.degenerateTriangleCount); " +
                        "closure boundary edges: \(closure.boundary), " +
                        "closure non-manifold edges: \(closure.nonManifold).")
                )
            }

            validated.append(p)
        }

        return ValidationResult(
            parts: validated,
            diagnostics: diagnostics,
            allPartsWatertight: allWatertight
        )
    }

    /// Final topology normalization followed by the independent protected
    /// tooling audit. The audit intentionally receives the normalized parts so
    /// repair cannot silently consume a required collar, receiver, flange, or
    /// registration profile.
    static func validate(
        parts: [MotherMoldPart],
        protectedAuditSet: ProtectedToolingAuditSet?
    ) -> ValidationResult {
        var result = validate(parts: parts)
        guard let protectedAuditSet else { return result }
        let audit = protectedAuditSet.audit(
            finalParts: result.parts,
            stage: .finalNormalization
        )
        result.protectedAudit = audit
        result.diagnostics.append(contentsOf: audit.diagnostics.map { MoldDiagnostic(.error, $0) })
        return result
    }

    /// Closed-surface test that matches Manifold's topology: weld vertices on the
    /// requested grid, then count undirected edges over ALL triangles (do NOT skip
    /// zero-area slivers — they are real faces of the closed surface). The surface
    /// is closed iff every edge is shared by exactly two triangles. Triangles
    /// whose three vertices don't weld to three distinct points contribute no
    /// edges. A part `ManifoldEngine.make` accepts reads `closed == true` here.
    static func surfaceClosure(
        _ geometry: MeshGeometryData,
        weldTolerance: Double = 1.0e-6
    ) -> (closed: Bool, boundary: Int, nonManifold: Int) {
        guard weldTolerance.isFinite, weldTolerance > 0 else {
            return (false, 0, 0)
        }
        struct Key: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        @inline(__always) func key(_ v: Vec3) -> Key {
            Key(x: Int64((v.x / weldTolerance).rounded()),
                y: Int64((v.y / weldTolerance).rounded()),
                z: Int64((v.z / weldTolerance).rounded()))
        }
        var ids: [Key: Int] = [:]
        var vid = [Int](repeating: -1, count: geometry.vertices.count)
        for (i, v) in geometry.vertices.enumerated() {
            let k = key(v)
            if let id = ids[k] { vid[i] = id } else { let id = ids.count; ids[k] = id; vid[i] = id }
        }
        @inline(__always) func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
            (UInt64(max(a, b)) << 32) | UInt64(min(a, b))
        }
        var counts: [UInt64: Int] = [:]
        let idx = geometry.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            if vid.indices.contains(a), vid.indices.contains(b), vid.indices.contains(c) {
                let ia = vid[a], ib = vid[b], ic = vid[c]
                if ia != ib, ib != ic, ia != ic {
                    counts[edgeKey(ia, ib), default: 0] += 1
                    counts[edgeKey(ib, ic), default: 0] += 1
                    counts[edgeKey(ic, ia), default: 0] += 1
                }
            }
            t += 3
        }
        guard !counts.isEmpty else { return (false, 0, 0) }
        var boundary = 0, nonManifold = 0
        for v in counts.values where v != 2 {
            if v == 1 { boundary += 1 } else { nonManifold += 1 }
        }
        return (boundary == 0 && nonManifold == 0, boundary, nonManifold)
    }

    /// Whether all coordinates in a part are finite.
    static func hasFiniteCoordinates(_ geometry: MeshGeometryData) -> Bool {
        for v in geometry.vertices where !(v.x.isFinite && v.y.isFinite && v.z.isFinite) {
            return false
        }
        return true
    }

    /// Run the real import preflight, extending only its non-manifold verdict
    /// when Manifold independently proves the mesh is a closed solid. Boundary
    /// edges, invalid references, and degenerate faces always remain failures.
    static func printablePreflight(_ geometry: MeshGeometryData) -> MeshPreflightReport {
        var preflight = MeshPreflight.analyze(geometry: geometry)
        guard !preflight.isWatertight,
              preflight.invalidTriangleReferenceCount == 0,
              preflight.degenerateTriangleCount == 0,
              preflight.boundaryEdgeCount == 0,
              preflight.nonManifoldEdgeCount > 0,
              let validated = try? ManifoldEngine.make(from: geometry) else {
            return preflight
        }
        withExtendedLifetime(validated) {}
        preflight.manifoldValidated = true
        return preflight
    }

    private static func printableNormalizedGeometry(
        _ geometry: MeshGeometryData
    ) -> PrintableNormalization? {
        guard let handle = try? ManifoldEngine.make(from: geometry) else { return nil }
        defer { withExtendedLifetime(handle) {} }

        func accepted(
            _ candidate: MeshGeometryData,
            diagnostic: String
        ) -> PrintableNormalization? {
            guard let strict = strictSingleComponentCandidate(candidate) else { return nil }
            var message = diagnostic
            if strict.droppedDebrisCount > 0 {
                message += String(
                    format: " Removed %d tiny disconnected debris component(s) (%.3f mm^3).",
                    strict.droppedDebrisCount,
                    strict.droppedDebrisVolume
                )
            }
            return PrintableNormalization(geometry: strict.geometry, diagnostic: message)
        }

        if let readback = try? ManifoldEngine.toMesh(handle) {
            if let normalized = accepted(
                readback,
                diagnostic: "was regularized through Manifold before export."
            ) {
                return normalized
            }

            let separation = 1.0e-4
            let contactSeparation = separatingPositionalSelfContacts(
                readback,
                separation: separation,
                axis: Vec3(x: 1, y: 0, z: 0)
            )
            if contactSeparation.movedGroupCount > 0,
               let normalized = accepted(
                contactSeparation.geometry,
                diagnostic: String(
                    format: "had positional self-contact separated by %.4f mm before export.",
                    separation
                )
            ) {
                return normalized
            }

            for expansion in [1.0e-4, 1.0e-3, 1.0e-2] {
                let expanded = expandingDegenerateTriangles(
                    contactSeparation.geometry,
                    displacement: expansion
                )
                let diagnostic = contactSeparation.movedGroupCount > 0
                    ? String(
                        format: "had positional self-contact separated by %.4f mm and sliver vertices iteratively adjusted in %.4f mm steps before export.",
                        separation,
                        expansion
                    )
                    : String(
                        format: "had sliver vertices iteratively adjusted in %.4f mm steps before export.",
                        expansion
                    )
                if let normalized = accepted(
                    expanded,
                    diagnostic: diagnostic
                ) {
                    return normalized
                }
            }
        }

        for tolerance in [1.0e-3, 1.0e-2, maximumRepairSimplificationMM] {
            guard let simplified = try? ManifoldEngine.simplify(handle, tolerance: tolerance),
                  let readback = try? ManifoldEngine.toMesh(simplified) else {
                continue
            }
            withExtendedLifetime(simplified) {}
            for candidate in [readback, MoldMeshSealer.seal(readback)] {
                if let normalized = accepted(
                    candidate,
                    diagnostic: String(
                        format: "was normalized at %.3f mm to remove boolean slivers before export.",
                        tolerance
                    )
                ) {
                    return normalized
                }
            }
        }
        return nil
    }

    /// Manifold's index topology can distinguish two closed sheets whose vertices
    /// fall in the same positional weld cell. STL cannot encode that distinction,
    /// so move only those distinct contact vertices apart by a microscopic,
    /// deterministic amount and let the strict preflight decide whether the
    /// result is printable. Shared indexed vertices are never moved independently.
    private static func separatingPositionalSelfContacts(
        _ geometry: MeshGeometryData,
        separation: Double,
        axis: Vec3
    ) -> ContactSeparation {
        struct ContactKey: Hashable {
            var x: Int64
            var y: Int64
            var z: Int64
        }

        var groups: [ContactKey: [Int]] = [:]
        for (index, vertex) in geometry.vertices.enumerated() {
            let key = ContactKey(
                x: Int64((vertex.x / 1.0e-6).rounded()),
                y: Int64((vertex.y / 1.0e-6).rounded()),
                z: Int64((vertex.z / 1.0e-6).rounded())
            )
            groups[key, default: []].append(index)
        }

        var vertices = geometry.vertices
        var movedGroupCount = 0
        for indices in groups.values where indices.count > 1 {
            movedGroupCount += 1
            let ordered = indices.sorted()
            let midpoint = Double(ordered.count - 1) * 0.5
            for (rank, index) in ordered.enumerated() {
                let offset = (Double(rank) - midpoint) * separation
                vertices[index].x += axis.x * offset
                vertices[index].y += axis.y * offset
                vertices[index].z += axis.z * offset
            }
        }
        return ContactSeparation(
            geometry: MeshGeometryData(vertices: vertices, triangleIndices: geometry.triangleIndices),
            movedGroupCount: movedGroupCount
        )
    }

    /// Expand only triangles below MeshPreflight's printable-area threshold by
    /// moving the vertex opposite their longest edge within the triangle plane.
    /// Index topology is unchanged, and every candidate still faces the strict
    /// topology gate before it can replace a mold part.
    private static func expandingDegenerateTriangles(
        _ geometry: MeshGeometryData,
        displacement: Double
    ) -> MeshGeometryData {
        struct EdgeChoice {
            var lengthSquared: Double
            var start: Int
            var end: Int
            var moving: Int
        }

        func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
            Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
        }
        func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
            lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
        }
        func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
            Vec3(
                x: lhs.y * rhs.z - lhs.z * rhs.y,
                y: lhs.z * rhs.x - lhs.x * rhs.z,
                z: lhs.x * rhs.y - lhs.y * rhs.x
            )
        }
        func normalized(_ vector: Vec3) -> Vec3? {
            let lengthSquared = dot(vector, vector)
            guard lengthSquared > 1.0e-24 else { return nil }
            let scale = 1 / lengthSquared.squareRoot()
            return Vec3(x: vector.x * scale, y: vector.y * scale, z: vector.z * scale)
        }

        let indices = geometry.triangleIndices
        var expanded = geometry.vertices
        for _ in 0..<8 {
            var changed = false
            var offset = 0
            while offset + 2 < indices.count {
                let ia = Int(indices[offset])
                let ib = Int(indices[offset + 1])
                let ic = Int(indices[offset + 2])
                guard expanded.indices.contains(ia),
                      expanded.indices.contains(ib),
                      expanded.indices.contains(ic) else {
                    offset += 3
                    continue
                }

                let a = expanded[ia]
                let b = expanded[ib]
                let c = expanded[ic]
                let ab = subtract(b, a)
                let ac = subtract(c, a)
                let normalVector = cross(ab, ac)
                guard dot(normalVector, normalVector) <= 1.0e-10 else {
                    offset += 3
                    continue
                }

                let bc = subtract(c, b)
                var choice = EdgeChoice(lengthSquared: dot(ab, ab), start: ia, end: ib, moving: ic)
                let candidates = [
                    EdgeChoice(lengthSquared: dot(bc, bc), start: ib, end: ic, moving: ia),
                    EdgeChoice(lengthSquared: dot(ac, ac), start: ia, end: ic, moving: ib),
                ]
                for candidate in candidates where candidate.lengthSquared > choice.lengthSquared {
                    choice = candidate
                }

                guard let edge = normalized(subtract(expanded[choice.end], expanded[choice.start])) else {
                    offset += 3
                    continue
                }
                let normal = normalized(normalVector)
                    ?? normalized(cross(edge, abs(edge.x) < 0.8
                        ? Vec3(x: 1, y: 0, z: 0)
                        : Vec3(x: 0, y: 1, z: 0)))
                guard let normal,
                      var inPlane = normalized(cross(normal, edge)) else {
                    offset += 3
                    continue
                }
                let currentHeight = dot(
                    subtract(expanded[choice.moving], expanded[choice.start]),
                    inPlane
                )
                if currentHeight < 0 || (abs(currentHeight) < 1.0e-15 && choice.moving % 2 == 1) {
                    inPlane = Vec3(x: -inPlane.x, y: -inPlane.y, z: -inPlane.z)
                }
                expanded[choice.moving].x += inPlane.x * displacement
                expanded[choice.moving].y += inPlane.y * displacement
                expanded[choice.moving].z += inPlane.z * displacement
                changed = true
                offset += 3
            }
            if !changed { break }
        }
        return MeshGeometryData(vertices: expanded, triangleIndices: indices)
    }

    private static func strictSingleComponentCandidate(
        _ geometry: MeshGeometryData
    ) -> StrictCandidate? {
        let preflight = MeshPreflight.analyze(geometry: geometry)
        guard preflight.isWatertight else { return nil }

        let tinyFiltered = MoldComponentFilter.dropFaceDisconnectedTinyDebris(geometry)
        if tinyFiltered.droppedCount > 0 {
            guard MeshPreflight.analyze(geometry: tinyFiltered.geometry).isWatertight else { return nil }
        }
        let remaining = MoldComponentFilter.dropFaceDisconnectedDebris(tinyFiltered.geometry)
        guard remaining.droppedCount == 0 else { return nil }
        return StrictCandidate(
            geometry: tinyFiltered.geometry,
            droppedDebrisCount: tinyFiltered.droppedCount,
            droppedDebrisVolume: tinyFiltered.droppedVolume
        )
    }

    // MARK: - Private helpers

    /// Recompute the tight AABB from only the vertices referenced by triangles.
    private static func boundsOf(_ geometry: MeshGeometryData) -> Bounds3D? {
        var minV = Vec3(x: Double.infinity, y: .infinity, z: .infinity)
        var maxV = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
        var found = false
        for idx in geometry.triangleIndices {
            let i = Int(idx)
            guard geometry.vertices.indices.contains(i) else { continue }
            let v = geometry.vertices[i]
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { continue }
            minV.x = Swift.min(minV.x, v.x)
            minV.y = Swift.min(minV.y, v.y)
            minV.z = Swift.min(minV.z, v.z)
            maxV.x = Swift.max(maxV.x, v.x)
            maxV.y = Swift.max(maxV.y, v.y)
            maxV.z = Swift.max(maxV.z, v.z)
            found = true
        }
        return found ? Bounds3D(min: minV, max: maxV) : nil
    }
}
