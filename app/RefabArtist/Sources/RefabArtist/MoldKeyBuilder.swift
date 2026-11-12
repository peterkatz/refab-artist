import Foundation

/// Adds tapered round or tapered bar registration bosses and pockets at each
/// physical mating interface.
///
/// Key geometry is built as closed prism solids and applied with Manifold
/// booleans. The male piece gets a unioned boss; the female gets a cut pocket.
/// Depth is ray-probed against the actual wall (Möller–Trumbore) so a key never
/// punches through a thin wall; seams that cannot support the requested key
/// pattern fail the whole operation with an error instead of leaving partial
/// keys behind. Concave / multi-loop seams are handled
/// correctly: key centres are placed via a clearance-sampled grid over the seam's
/// 2-D footprint. Everything is deterministic — no stochastic decisions.
enum MoldKeyBuilder {
    private static let embed = 0.6
    private static let probeInset = 1.0e-3
    private static let probeStartOffset = 0.05
    private static let seamHitTolerance = 0.12
    // Candidate face selection must cover every surface that the later backing
    // probe accepts as a seam hit. A narrower projection band can erase a valid
    // mating footprint on an otherwise equivalent axis orientation.
    private static let seamFaceTolerance = seamHitTolerance
    private static let taperSlopeNominal = tan(8.0 * Double.pi / 180)
    private static let maximumNumericalOverlapMM3 = 0.01
    /// Deterministic per-interface DFS budget. Requested key counts are
    /// sanitized to at most six, so this is intentionally generous while still
    /// bounding the search if the candidate set explodes.
    private static let maximumSearchNodesPerInterface = 16_384

    struct RegistrationKeySite: Equatable {
        var center: Vec3
        var normal: Vec3
        var malePartName: String
        var femalePartName: String
        var pinLength: Double
        var probeRadius: Double
        var pocketDepth: Double
        var bossBaseHalfW: Double
        var bossBaseHalfH: Double
        var bossTipHalfW: Double
        var bossTipHalfH: Double
        var pocketMouthHalfW: Double
        var pocketMouthHalfH: Double
        var pocketFloorHalfW: Double
        var pocketFloorHalfH: Double
        var isRectangular: Bool
    }

    /// Result of keying the seams.
    struct KeyResult: Equatable {
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]
        /// Complete per-feature evidence after the committed key transaction.
        var protectedAudit: ProtectedToolingAuditSet.AuditResult? = nil
        /// Caller records plus exact generated boss and pocket profiles.
        var protectedAuditSet: ProtectedToolingAuditSet? = nil
        /// Number of mating key pairs whose boss and pocket booleans both succeeded.
        var registrationKeysPlaced: Int = 0
        var sites: [RegistrationKeySite] = []
        static let empty = KeyResult(parts: [], diagnostics: [])
    }

    private enum InterfacePlacementOutcome {
        case success(parts: [MotherMoldPart], sites: [RegistrationKeySite])
        case infeasible(message: String)
        case budgetExceeded(message: String)
    }

    /// Bounded per-interface evidence for a rejected pattern. Candidate input is
    /// capped before probing, so these counts cannot grow with mesh complexity.
    private struct InterfacePlacementMetrics {
        var projectedCandidates = 0
        var missingMaleBacking = 0
        var missingFemaleBacking = 0
        var insufficientBacking = 0
        var candidateGridSummary = ""

        var backingSummary: String {
            "\(candidateGridSummary), candidates=\(projectedCandidates), male backing misses=\(missingMaleBacking), female backing misses=\(missingFemaleBacking), shallow backing=\(insufficientBacking)"
        }
    }

    struct CompletePatternSearchMetrics: Equatable {
        var nodesVisited: Int
        var backtracks: Int
    }

    enum CompletePatternSearchResult<State> {
        case success(
            state: State,
            selectedIndices: [Int],
            metrics: CompletePatternSearchMetrics
        )
        case infeasible(metrics: CompletePatternSearchMetrics)
        case budgetExceeded(metrics: CompletePatternSearchMetrics)
    }

    /// Apply seam registration keys to every part pair sharing a parting plane.
    /// Passthrough when `key.type == .none`.
    static func applyKeys(
        parts: [MotherMoldPart],
        planes: [PartitionPlane],
        key: PartitionKeySettings,
        protectedAuditSet: ProtectedToolingAuditSet? = nil
    ) throws -> KeyResult {
        guard key.type != .none, !planes.isEmpty, parts.count >= 2 else {
            return KeyResult(parts: parts, diagnostics: [])
        }

        if let protectedAuditSet {
            let inputAudit = protectedAuditSet.audit(finalParts: parts, stage: .key)
            guard inputAudit.passes else {
                return KeyResult(
                    parts: parts,
                    diagnostics: [.init(.error, inputAudit.diagnostics.joined(separator: " "))]
                )
            }
        }

        let s = key.sanitized
        let interfaces = MoldPartingInterfaces.resolve(parts: parts, planes: planes)
        let expectedInterfaceCount = planes.count * max(1, parts.count / 2)
        if interfaces.count != expectedInterfaceCount {
            return KeyResult(
                parts: parts,
                diagnostics: [.init(
                .error,
                "Registration could identify only \(interfaces.count) of \(expectedInterfaceCount) physical mating interfaces. The mold is inspection-only."
                )],
                registrationKeysPlaced: 0,
                sites: []
            )
        }

        var workingParts = parts
        var diagnostics: [MoldDiagnostic] = []
        var registrationKeysPlaced = 0
        var placedSites: [RegistrationKeySite] = []

        for interface in interfaces {
            switch try placeInterfaceKeys(
                in: workingParts,
                interface: interface,
                settings: s
            ) {
            case .success(let updatedParts, let sites):
                workingParts = updatedParts
                placedSites.append(contentsOf: sites)
                registrationKeysPlaced += sites.count
                diagnostics.append(.init(
                    .info,
                    "Seam \(interface.label): placed \(sites.count) \(s.type == .dovetail ? "tapered bar" : "tapered round") key\(sites.count == 1 ? "" : "s")."
                ))
            case .infeasible(let message), .budgetExceeded(let message):
                return KeyResult(
                    parts: parts,
                    diagnostics: [.init(.error, message)],
                    registrationKeysPlaced: 0,
                    sites: []
                )
            }
        }

        let generatedRecords = keyAuditRecords(for: placedSites)
        let completeAuditSet = try (protectedAuditSet ?? ProtectedToolingAuditSet(records: []))
            .appending(generatedRecords)
        let protectedAudit = completeAuditSet.audit(finalParts: workingParts, stage: .key)
        guard protectedAudit.passes else {
            return KeyResult(
                parts: parts,
                diagnostics: [.init(.error, protectedAudit.diagnostics.joined(separator: " "))]
            )
        }

        return KeyResult(
            parts: workingParts,
            diagnostics: diagnostics,
            protectedAudit: protectedAudit,
            protectedAuditSet: completeAuditSet,
            registrationKeysPlaced: registrationKeysPlaced,
            sites: placedSites
        )
    }

    /// Deterministically searches ordered candidates for one complete pattern.
    /// `applyCandidate` returns a new branch state only when the candidate's
    /// coupled operations succeed; discarded states provide transactional
    /// backtracking for production geometry and a focused test seam for DFS.
    static func searchCompletePattern<State>(
        candidateCount: Int,
        requestedCount: Int,
        nodeBudget: Int,
        initialState: State,
        isCompatible: (_ selectedIndices: [Int], _ candidateIndex: Int) -> Bool,
        applyCandidate: (_ state: State, _ candidateIndex: Int) -> State?
    ) -> CompletePatternSearchResult<State> {
        precondition(candidateCount >= 0)
        precondition(requestedCount > 0)
        precondition(nodeBudget > 0)

        var nodesVisited = 0
        var backtracks = 0

        func metrics() -> CompletePatternSearchMetrics {
            CompletePatternSearchMetrics(
                nodesVisited: nodesVisited,
                backtracks: backtracks
            )
        }

        func search(
            from startIndex: Int,
            selectedIndices: [Int],
            state: State
        ) -> CompletePatternSearchResult<State> {
            guard nodesVisited < nodeBudget else {
                return .budgetExceeded(metrics: metrics())
            }
            nodesVisited += 1

            let remainingNeeded = requestedCount - selectedIndices.count
            if remainingNeeded == 0 {
                return .success(
                    state: state,
                    selectedIndices: selectedIndices,
                    metrics: metrics()
                )
            }
            guard candidateCount - startIndex >= remainingNeeded else {
                return .infeasible(metrics: metrics())
            }

            for candidateIndex in startIndex..<candidateCount {
                guard isCompatible(selectedIndices, candidateIndex),
                      let updatedState = applyCandidate(state, candidateIndex) else {
                    continue
                }

                switch search(
                    from: candidateIndex + 1,
                    selectedIndices: selectedIndices + [candidateIndex],
                    state: updatedState
                ) {
                case .success(let finalState, let finalIndices, _):
                    return .success(
                        state: finalState,
                        selectedIndices: finalIndices,
                        metrics: metrics()
                    )
                case .budgetExceeded:
                    return .budgetExceeded(metrics: metrics())
                case .infeasible:
                    backtracks += 1
                }
            }

            return .infeasible(metrics: metrics())
        }

        return search(from: 0, selectedIndices: [], state: initialState)
    }

    private static func placeInterfaceKeys(
        in parts: [MotherMoldPart],
        interface: MoldPartingInterfaces.Interface,
        settings s: PartitionKeySettings
    ) throws -> InterfacePlacementOutcome {
        let plane = interface.plane
        let seamLabel = interface.label
        // Match PartitionKeys.capInterface: the negative half is male and its
        // boss protrudes along +normal into a pocket in the positive half.
        let maleSide = [interface.negativePartIndex]
        let femaleSide = [interface.positivePartIndex]

        // Project the REAL mating-face triangles onto the seam plane. This
        // preserves the flange's cavity opening, bolt holes, outer boundary,
        // and multi-island topology; a point-cloud AABB cannot represent any of
        // those constraints.
        let (u, v) = planeBasis(plane.normal)
        let origin3 = Vec3(x: plane.normal.x * plane.offset,
                           y: plane.normal.y * plane.offset,
                           z: plane.normal.z * plane.offset)
        let maleFaces = seamFaceTriangles(
            for: maleSide,
            in: parts,
            plane: plane,
            origin: origin3,
            u: u,
            v: v
        )
        let femaleFaces = seamFaceTriangles(
            for: femaleSide,
            in: parts,
            plane: plane,
            origin: origin3,
            u: u,
            v: v
        )

        guard !maleFaces.isEmpty, !femaleFaces.isEmpty else {
            return .infeasible(message: "Seam \(seamLabel): no seam geometry survived the interface resolution, so no complete key pattern can be placed. No keys were placed.")
        }

        // Place key centres in 2-D using clearance-sampled grid.
        let base   = s.pinDiameter / 2
        let isRect = s.type == .dovetail
        let halfW  = isRect ? base * 1.4 : base
        let halfH  = isRect ? base * 0.7 : base
        let clearRadius = (halfW * halfW + halfH * halfH).squareRoot() + s.tolerance

        let requestedCount = max(1, s.pinsPerSeam)
        let requiredSeparation = 2 * clearRadius + s.edgeMargin
        let candidateGrid = keyCentreCandidates(
            maleFaces: maleFaces,
            femaleFaces: femaleFaces,
            clearance: clearRadius + s.edgeMargin,
            candidateSpacing: max(1.0, clearRadius * 0.55),
            maximumCount: max(32, requestedCount * 24)
        )
        var placementMetrics = InterfacePlacementMetrics(
            projectedCandidates: candidateGrid.points.count,
            candidateGridSummary: candidateGrid.summary
        )
        let centres2D = candidateGrid.points

        guard !centres2D.isEmpty else {
            return .infeasible(message: "Seam \(seamLabel): no valid key site survived the wall-depth and spacing checks for the requested \(requestedCount)-key pattern (\(placementMetrics.backingSummary)). No keys were placed.")
        }

        struct KeyedSite {
            var c2: Vec2
            var c3: Vec3
            var pinLength: Double
            var pocketDepth: Double
            var taperSlope: Double
            var malePartIndex: Int
            var femalePartIndex: Int
        }

        var sites: [KeyedSite] = []
        for c2 in centres2D {
            let c3 = unproject(c2, origin: origin3, u: u, v: v)
            guard let maleProbe = probePart(
                at: c3,
                inward: scale(plane.normal, -1),
                candidateIndices: maleSide,
                parts: parts
            ) else {
                placementMetrics.missingMaleBacking += 1
                continue
            }
            guard let femaleProbe = probePart(
                at: c3,
                inward: plane.normal,
                candidateIndices: femaleSide,
                parts: parts
            ) else {
                placementMetrics.missingFemaleBacking += 1
                continue
            }

            let pocketLip = 0.5
            let pocketClearanceDepth = s.tolerance + pocketLip
            let maxPocket = max(0, 0.8 * femaleProbe.depth)
            let minimumProfileHalfExtent = 0.4
            let minimumHalfExtent = min(halfW, halfH)
            let maxPinLengthFromBossTaper =
                (minimumHalfExtent - minimumProfileHalfExtent) / Self.taperSlopeNominal
            let maxPinLengthFromPocketTaper =
                (minimumHalfExtent + s.tolerance - minimumProfileHalfExtent) / Self.taperSlopeNominal
                - pocketClearanceDepth
            let pinLength = min(
                s.pinLength,
                maxPocket - pocketClearanceDepth,
                maxPinLengthFromBossTaper,
                maxPinLengthFromPocketTaper
            )
            let pocketDepth = pinLength + pocketClearanceDepth
            guard pocketDepth >= 2.0,
                  pinLength >= 1.0,
                  maleProbe.depth >= Self.embed + 1.0 else {
                placementMetrics.insufficientBacking += 1
                continue
            }
            sites.append(KeyedSite(
                c2: c2,
                c3: c3,
                pinLength: pinLength,
                pocketDepth: pocketDepth,
                taperSlope: Self.taperSlopeNominal,
                malePartIndex: maleProbe.index,
                femalePartIndex: femaleProbe.index
            ))
        }

        guard !sites.isEmpty else {
            return .infeasible(message: "Seam \(seamLabel): no valid key site survived the backing-depth probes for the requested \(requestedCount)-key pattern (\(placementMetrics.backingSummary)). No keys were placed.")
        }

        let pocketLip = 0.5
        let searchBudget = Self.maximumSearchNodesPerInterface

        func placeCandidate(
            _ site: KeyedSite,
            in parts: [MotherMoldPart]
        ) -> [MotherMoldPart]? {
            var bossTris: [(Vec3, Vec3, Vec3)] = []
            var pocketTris: [(Vec3, Vec3, Vec3)] = []
            let c2 = site.c2
            let bossBase = ring2D(
                center: c2,
                halfW: halfW + site.taperSlope * Self.embed,
                halfH: halfH + site.taperSlope * Self.embed,
                rect: isRect,
                clockwise: false
            )
            let bossTip = ring2D(
                center: c2,
                halfW: halfW - site.taperSlope * site.pinLength,
                halfH: halfH - site.taperSlope * site.pinLength,
                rect: isRect,
                clockwise: false
            )
            let pocketMouth = ring2D(
                center: c2,
                halfW: halfW + s.tolerance + site.taperSlope * pocketLip,
                halfH: halfH + s.tolerance + site.taperSlope * pocketLip,
                rect: isRect,
                clockwise: false
            )
            let pocketFloor = ring2D(
                center: c2,
                halfW: halfW + s.tolerance - site.taperSlope * site.pocketDepth,
                halfH: halfH + s.tolerance - site.taperSlope * site.pocketDepth,
                rect: isRect,
                clockwise: false
            )

            // The negative-side male embeds along -n and protrudes along +n.
            let bossBottom = liftRing(bossBase, origin: origin3, u: u, v: v, normal: plane.normal, offset: -Self.embed)
            let bossTop    = liftRing(bossTip, origin: origin3, u: u, v: v, normal: plane.normal, offset: site.pinLength)
            appendClosedPrism(bottom: bossBottom, top: bossTop, into: &bossTris, capBottomCW: true, capTopCW: false)

            // The positive-side pocket starts outside the female part along
            // -n and cuts inward along +n. Expanding the lip by taper*lip
            // leaves exactly `tolerance` clearance at the seam and at depth.
            let pocketOutside = liftRing(pocketMouth, origin: origin3, u: u, v: v, normal: plane.normal, offset: -pocketLip)
            let pocketInside = liftRing(pocketFloor, origin: origin3, u: u, v: v, normal: plane.normal, offset: site.pocketDepth)
            appendClosedPrism(bottom: pocketOutside, top: pocketInside, into: &pocketTris, capBottomCW: true, capTopCW: false)

            do {
                let keyedMale = try combine(
                    parts[site.malePartIndex].geometry,
                    with: bossTris,
                    op: .union
                )
                let keyedFemale = try combine(
                    parts[site.femalePartIndex].geometry,
                    with: pocketTris,
                    op: .difference
                )
                var candidateParts = parts
                candidateParts[site.malePartIndex].geometry = keyedMale
                candidateParts[site.femalePartIndex].geometry = keyedFemale
                guard try novelMaleDeltaIsDisjoint(
                    originalMale: parts[site.malePartIndex].geometry,
                    keyedMale: keyedMale,
                    malePartIndex: site.malePartIndex,
                    in: candidateParts
                ) else {
                    return nil
                }
                return candidateParts
            } catch {
                return nil
            }
        }

        let searchResult = searchCompletePattern(
            candidateCount: sites.count,
            requestedCount: requestedCount,
            nodeBudget: searchBudget,
            initialState: parts,
            isCompatible: { selectedIndices, candidateIndex in
                let candidate = sites[candidateIndex]
                return selectedIndices.allSatisfy { selectedIndex in
                    let selected = sites[selectedIndex]
                    return hypot(
                        selected.c2.x - candidate.c2.x,
                        selected.c2.y - candidate.c2.y
                    ) >= requiredSeparation
                }
            },
            applyCandidate: { workingParts, candidateIndex in
                placeCandidate(sites[candidateIndex], in: workingParts)
            }
        )

        switch searchResult {
        case .success(let parts, let selectedIndices, _):
            return .success(
                parts: parts,
                sites: selectedIndices.map { selectedIndex in
                    let site = sites[selectedIndex]
                    return RegistrationKeySite(
                        center: site.c3,
                        normal: plane.normal,
                        malePartName: parts[site.malePartIndex].name,
                        femalePartName: parts[site.femalePartIndex].name,
                        pinLength: site.pinLength,
                        probeRadius: max(0.03, min(0.15, s.tolerance * 0.25)),
                        pocketDepth: site.pocketDepth,
                        bossBaseHalfW: halfW + site.taperSlope * Self.embed,
                        bossBaseHalfH: halfH + site.taperSlope * Self.embed,
                        bossTipHalfW: halfW - site.taperSlope * site.pinLength,
                        bossTipHalfH: halfH - site.taperSlope * site.pinLength,
                        pocketMouthHalfW: halfW + s.tolerance + site.taperSlope * pocketLip,
                        pocketMouthHalfH: halfH + s.tolerance + site.taperSlope * pocketLip,
                        pocketFloorHalfW: halfW + s.tolerance - site.taperSlope * site.pocketDepth,
                        pocketFloorHalfH: halfH + s.tolerance - site.taperSlope * site.pocketDepth,
                        isRectangular: isRect
                    )
                }
            )
        case .infeasible:
            return .infeasible(
                message: "Seam \(seamLabel): the deterministic search proved that no complete requested \(requestedCount)-key pattern could be retained while satisfying spacing, mating booleans, and all-part interference checks. No keys were placed and no partial geometry was retained."
            )
        case .budgetExceeded(let metrics):
            return .budgetExceeded(
                message: "Seam \(seamLabel): the deterministic key search exhausted its \(searchBudget)-node budget after visiting \(metrics.nodesVisited) nodes before proving a complete requested \(requestedCount)-key pattern. No keys were placed and no partial geometry was retained."
            )
        }
    }

    /// Re-measure the complete expected boss and pocket profiles against the
    /// FINAL post-feature, post-cleanup parts. Centreline probes can miss a
    /// removed side, tip, or pocket perimeter, so retained and clear profile
    /// volumes are the evidence used for export-facing key survival.
    static func survivingSites(
        _ sites: [RegistrationKeySite],
        in parts: [MotherMoldPart]
    ) -> [RegistrationKeySite] {
        let byName = Dictionary(uniqueKeysWithValues: parts.map { ($0.name, $0) })
        return sites.filter { site in
            guard let male = byName[site.malePartName],
                  let female = byName[site.femalePartName] else { return false }
            do {
                let maleHandle = try ManifoldEngine.make(from: male.geometry)
                let femaleHandle = try ManifoldEngine.make(from: female.geometry)
                let bossProfile = try ManifoldEngine.make(from: expectedBossProfile(for: site))
                let pocketProfile = try ManifoldEngine.make(from: expectedPocketProfile(for: site))
                let bossVolume = abs(ManifoldEngine.volume(bossProfile))
                let pocketVolume = abs(ManifoldEngine.volume(pocketProfile))
                let retainedBoss = try ManifoldEngine.intersect(maleHandle, bossProfile)
                let remainingPocket = try ManifoldEngine.intersect(femaleHandle, pocketProfile)
                let retainedBossVolume = abs(ManifoldEngine.volume(retainedBoss))
                let remainingPocketVolume = abs(ManifoldEngine.volume(remainingPocket))
                withExtendedLifetime(bossProfile) {}
                withExtendedLifetime(pocketProfile) {}
                withExtendedLifetime(retainedBoss) {}
                withExtendedLifetime(remainingPocket) {}
                guard bossVolume > 1.0e-6,
                      pocketVolume > 1.0e-6,
                      retainedBossVolume >= bossVolume * 0.95,
                      remainingPocketVolume <= pocketVolume * 0.05 else {
                    withExtendedLifetime(maleHandle) {}
                    withExtendedLifetime(femaleHandle) {}
                    return false
                }
                withExtendedLifetime(maleHandle) {}
                withExtendedLifetime(femaleHandle) {}
                return true
            } catch {
                return false
            }
        }
    }

    private static func expectedBossProfile(for site: RegistrationKeySite) -> MeshGeometryData {
        let (u, v) = planeBasis(site.normal)
        let base = ring2D(
            center: Vec2(x: 0, y: 0),
            halfW: site.bossBaseHalfW,
            halfH: site.bossBaseHalfH,
            rect: site.isRectangular,
            clockwise: false
        )
        let tip = ring2D(
            center: Vec2(x: 0, y: 0),
            halfW: site.bossTipHalfW,
            halfH: site.bossTipHalfH,
            rect: site.isRectangular,
            clockwise: false
        )
        let bottom = liftRing(base, origin: site.center, u: u, v: v, normal: site.normal, offset: -Self.embed)
        let top = liftRing(tip, origin: site.center, u: u, v: v, normal: site.normal, offset: site.pinLength)
        var triangles: [(Vec3, Vec3, Vec3)] = []
        appendClosedPrism(bottom: bottom, top: top, into: &triangles, capBottomCW: true, capTopCW: false)
        return triSoupToGeometry(triangles)
    }

    private static func expectedPocketProfile(for site: RegistrationKeySite) -> MeshGeometryData {
        let (u, v) = planeBasis(site.normal)
        let mouth = ring2D(
            center: Vec2(x: 0, y: 0),
            halfW: site.pocketMouthHalfW,
            halfH: site.pocketMouthHalfH,
            rect: site.isRectangular,
            clockwise: false
        )
        let floor = ring2D(
            center: Vec2(x: 0, y: 0),
            halfW: site.pocketFloorHalfW,
            halfH: site.pocketFloorHalfH,
            rect: site.isRectangular,
            clockwise: false
        )
        let outside = liftRing(mouth, origin: site.center, u: u, v: v, normal: site.normal, offset: -0.5)
        let inside = liftRing(floor, origin: site.center, u: u, v: v, normal: site.normal, offset: site.pocketDepth)
        var triangles: [(Vec3, Vec3, Vec3)] = []
        appendClosedPrism(bottom: outside, top: inside, into: &triangles, capBottomCW: true, capTopCW: false)
        return triSoupToGeometry(triangles)
    }

    private static func keyAuditRecords(
        for sites: [RegistrationKeySite]
    ) -> [ProtectedToolingAuditSet.Record] {
        sites.enumerated().flatMap { index, site in
            [
                ProtectedToolingAuditSet.Record(
                    id: "shell-key-boss-\(index + 1)-\(site.malePartName)-\(site.femalePartName)",
                    kind: .shellKeyBoss,
                    behavior: .additive,
                    ownership: .singlePart(site.malePartName),
                    geometry: expectedBossProfile(for: site),
                    requiredRetention: 0.98,
                    provenance: [.key]
                ),
                ProtectedToolingAuditSet.Record(
                    id: "shell-key-pocket-\(index + 1)-\(site.malePartName)-\(site.femalePartName)",
                    kind: .shellKeyPocket,
                    behavior: .subtractive,
                    ownership: .singlePart(site.femalePartName),
                    geometry: expectedPocketProfile(for: site),
                    requiredRetention: 1,
                    requiredClearance: 0.98,
                    provenance: [.key]
                ),
            ]
        }
    }

    // MARK: - Part classification

    /// Indices of parts that lie on the positive (positive=true) or negative side
    /// of the plane, classified by the SIGNED DISTANCE of the part's
    /// AREA-WEIGHTED centroid to the plane — not by raw vertex-count majority.
    /// Vertex-count majority is sensitive to tessellation density (a finely
    /// triangulated lobe can outvote the part's actual bulk) and mis-assigns a
    /// part that straddles the seam; the area-weighted centroid tracks where the
    /// part's surface mass actually sits, which is the side it demolds toward.
    private static func partIndicesOnSide(
        of plane: PartitionPlane,
        parts: [MotherMoldPart],
        positive: Bool
    ) -> [Int] {
        var result: [Int] = []
        for (i, part) in parts.enumerated() {
            guard let c = areaWeightedCentroid(part.geometry) else { continue }
            let signed = dot(c, plane.normal) - plane.offset
            let onSide = positive ? signed >= 0 : signed < 0
            if onSide { result.append(i) }
        }
        return result
    }

    /// Area-weighted centroid of a triangle mesh (each triangle's centroid
    /// weighted by its area). Falls back to nil for empty / degenerate geometry.
    private static func areaWeightedCentroid(_ geo: MeshGeometryData) -> Vec3? {
        let verts = geo.vertices
        let idx = geo.triangleIndices
        guard !verts.isEmpty, idx.count >= 3 else { return nil }
        var sum = Vec3(x: 0, y: 0, z: 0)
        var totalArea = 0.0
        var j = 0
        while j + 2 < idx.count {
            let a = Int(idx[j]), b = Int(idx[j + 1]), c = Int(idx[j + 2])
            j += 3
            guard verts.indices.contains(a), verts.indices.contains(b), verts.indices.contains(c) else { continue }
            let va = verts[a], vb = verts[b], vc = verts[c]
            let e1 = subtract(vb, va), e2 = subtract(vc, va)
            let n = cross(e1, e2)
            let area = 0.5 * (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            guard area > 1.0e-12 else { continue }
            let tc = Vec3(x: (va.x + vb.x + vc.x) / 3,
                          y: (va.y + vb.y + vc.y) / 3,
                          z: (va.z + vb.z + vc.z) / 3)
            sum = add(sum, scale(tc, area))
            totalArea += area
        }
        guard totalArea > 1.0e-12 else {
            // Degenerate areas: fall back to vertex mean.
            var m = Vec3(x: 0, y: 0, z: 0)
            for v in verts { m = add(m, v) }
            let n = Double(verts.count)
            return Vec3(x: m.x / n, y: m.y / n, z: m.z / n)
        }
        return scale(sum, 1.0 / totalArea)
    }

    /// Build a flat triangle soup from all parts at the given indices.
    private static func soup(for indices: [Int], in parts: [MotherMoldPart]) -> [(Vec3, Vec3, Vec3)] {
        var out: [(Vec3, Vec3, Vec3)] = []
        for i in indices {
            let g = parts[i].geometry
            var j = 0
            while j + 2 < g.triangleIndices.count {
                let a = g.triangleIndices[j], b = g.triangleIndices[j + 1], c = g.triangleIndices[j + 2]
                guard Int(a) < g.vertices.count, Int(b) < g.vertices.count, Int(c) < g.vertices.count else { j += 3; continue }
                out.append((g.vertices[Int(a)], g.vertices[Int(b)], g.vertices[Int(c)]))
                j += 3
            }
        }
        return out
    }

    /// Find the exact part whose cut face contains this site and measure finite
    /// backing depth into it. Requiring the near seam-face hit rejects AABB-grid
    /// candidates that land in holes or between disconnected seam islands.
    private static func probePart(
        at seamPoint: Vec3,
        inward: Vec3,
        candidateIndices: [Int],
        parts: [MotherMoldPart]
    ) -> (index: Int, depth: Double)? {
        var best: (index: Int, depth: Double)?

        for index in candidateIndices {
            let triangles = soup(for: [index], in: parts)
            // Start in the assembly gap and ray INTO the candidate part. The
            // flange validator deliberately leaves 0.01 mm total clearance, so
            // assuming the seam face is exactly at the mathematical plane starts
            // outside the solid and misses it.
            let searchOrigin = add(seamPoint, scale(inward, -Self.probeStartOffset))
            guard let seamHit = rayFirstHit(origin: searchOrigin, dir: inward, triangles: triangles),
                  seamHit <= Self.seamHitTolerance,
                  let backingHit = rayFirstHit(
                    origin: add(searchOrigin, scale(inward, seamHit + Self.probeInset)),
                    dir: inward,
                    triangles: triangles
                  ) else {
                continue
            }
            let depth = backingHit + Self.probeInset
            if best == nil || depth < best!.depth {
                best = (index: index, depth: depth)
            }
        }
        return best
    }

    // MARK: - 2-D key placement

    private struct SeamFaceTriangle {
        var a: Vec2
        var b: Vec2
        var c: Vec2
    }

    private struct KeyCentreCandidateGrid {
        var points: [Vec2] = []
        var maleFaceCount = 0
        var femaleFaceCount = 0
        var maleBoundaryCount = 0
        var femaleBoundaryCount = 0
        var sampledPoints = 0
        var sharedFootprintPoints = 0
        var clearancePoints = 0

        var summary: String {
            "male faces=\(maleFaceCount), female faces=\(femaleFaceCount), male boundary=\(maleBoundaryCount), female boundary=\(femaleBoundaryCount), sampled=\(sampledPoints), shared footprint=\(sharedFootprintPoints), clearance-valid=\(clearancePoints)"
        }
    }

    private struct QuantizedPoint: Hashable, Comparable {
        var x: Int64
        var y: Int64

        init(_ point: Vec2) {
            x = Int64((point.x * 1_000).rounded())
            y = Int64((point.y * 1_000).rounded())
        }

        static func < (lhs: QuantizedPoint, rhs: QuantizedPoint) -> Bool {
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
    }

    private struct EdgeKey: Hashable {
        var first: QuantizedPoint
        var second: QuantizedPoint

        init(_ a: Vec2, _ b: Vec2) {
            let qa = QuantizedPoint(a)
            let qb = QuantizedPoint(b)
            if qa < qb {
                first = qa
                second = qb
            } else {
                first = qb
                second = qa
            }
        }
    }

    private static func seamFaceTriangles(
        for indices: [Int],
        in parts: [MotherMoldPart],
        plane: PartitionPlane,
        origin: Vec3,
        u: Vec3,
        v: Vec3
    ) -> [SeamFaceTriangle] {
        var faces: [SeamFaceTriangle] = []
        for index in indices {
            let geometry = parts[index].geometry
            var triangleIndex = 0
            while triangleIndex + 2 < geometry.triangleIndices.count {
                let ia = Int(geometry.triangleIndices[triangleIndex])
                let ib = Int(geometry.triangleIndices[triangleIndex + 1])
                let ic = Int(geometry.triangleIndices[triangleIndex + 2])
                triangleIndex += 3
                guard geometry.vertices.indices.contains(ia),
                      geometry.vertices.indices.contains(ib),
                      geometry.vertices.indices.contains(ic) else { continue }
                let a3 = geometry.vertices[ia]
                let b3 = geometry.vertices[ib]
                let c3 = geometry.vertices[ic]
                let distances = [a3, b3, c3].map { abs(dot($0, plane.normal) - plane.offset) }
                guard distances.max() ?? .infinity <= Self.seamFaceTolerance else { continue }
                let a = project(a3, origin: origin, u: u, v: v)
                let b = project(b3, origin: origin, u: u, v: v)
                let c = project(c3, origin: origin, u: u, v: v)
                guard abs(cross2D(a, b, c)) > 1.0e-8 else { continue }
                faces.append(SeamFaceTriangle(a: a, b: b, c: c))
            }
        }
        return faces
    }

    /// Sample the overlap of the two REAL flange mating faces and retain points
    /// whose entire key footprint clears every outer edge and hole boundary.
    private static func keyCentreCandidates(
        maleFaces: [SeamFaceTriangle],
        femaleFaces: [SeamFaceTriangle],
        clearance: Double,
        candidateSpacing: Double,
        maximumCount: Int
    ) -> KeyCentreCandidateGrid {
        var result = KeyCentreCandidateGrid(
            maleFaceCount: maleFaces.count,
            femaleFaceCount: femaleFaces.count
        )
        let points = (maleFaces + femaleFaces).flatMap { [$0.a, $0.b, $0.c] }
        guard let first = points.first else { return result }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let spanX = maxX - minX
        let spanY = maxY - minY
        guard spanX > 1.0e-6, spanY > 1.0e-6 else { return result }

        let span = max(spanX, spanY)
        let steps = min(96, max(20, Int(span / max(clearance * 0.35, 0.5))))
        let maleBoundary = boundarySegments(maleFaces)
        let femaleBoundary = boundarySegments(femaleFaces)
        result.maleBoundaryCount = maleBoundary.count
        result.femaleBoundaryCount = femaleBoundary.count
        guard !maleBoundary.isEmpty, !femaleBoundary.isEmpty else { return result }

        struct Candidate { var point: Vec2; var clearance: Double }
        var candidates: [Candidate] = []
        for ix in 0...steps {
            for iy in 0...steps {
                result.sampledPoints += 1
                let x = minX + spanX * Double(ix) / Double(steps)
                let y = minY + spanY * Double(iy) / Double(steps)
                let p = Vec2(x: x, y: y)
                guard contains(p, in: maleFaces), contains(p, in: femaleFaces) else { continue }
                result.sharedFootprintPoints += 1
                let minDist = min(
                    distanceToBoundary(p, segments: maleBoundary),
                    distanceToBoundary(p, segments: femaleBoundary)
                )
                if minDist >= clearance {
                    candidates.append(Candidate(point: p, clearance: minDist))
                    result.clearancePoints += 1
                }
            }
        }
        guard !candidates.isEmpty else { return result }
        candidates.sort {
            if abs($0.clearance - $1.clearance) > 1.0e-9 {
                return $0.clearance > $1.clearance
            }
            if abs($0.point.x - $1.point.x) > 1.0e-9 { return $0.point.x < $1.point.x }
            return $0.point.y < $1.point.y
        }

        var chosen: [Vec2] = []
        for cand in candidates {
            if chosen.allSatisfy({ p in
                let dx = p.x - cand.point.x, dy = p.y - cand.point.y
                return (dx * dx + dy * dy).squareRoot() >= candidateSpacing
            }) {
                chosen.append(cand.point)
                if chosen.count >= maximumCount { break }
            }
        }
        result.points = chosen
        return result
    }

    /// Tests only the material introduced by a successful male-key union.
    /// The embedded tool base is already inside the pre-candidate male solid,
    /// so intersecting the full tool would reject harmless contact. The final
    /// whole-part planner validation remains the backstop for pre-existing
    /// assembled overlap.
    static func novelMaleDeltaIsDisjoint(
        originalMale: MeshGeometryData,
        keyedMale: MeshGeometryData,
        malePartIndex: Int,
        in parts: [MotherMoldPart]
    ) throws -> Bool {
        let original = try ManifoldEngine.make(from: originalMale)
        let keyed = try ManifoldEngine.make(from: keyedMale)
        let novelDelta = try ManifoldEngine.difference(keyed, original)
        defer {
            withExtendedLifetime(original) {}
            withExtendedLifetime(keyed) {}
            withExtendedLifetime(novelDelta) {}
        }
        for otherIndex in parts.indices where otherIndex != malePartIndex {
            let other = try ManifoldEngine.make(from: parts[otherIndex].geometry)
            let intersection = try ManifoldEngine.intersect(novelDelta, other)
            let overlap = abs(ManifoldEngine.volume(intersection))
            withExtendedLifetime(other) {}
            withExtendedLifetime(intersection) {}
            if overlap > maximumNumericalOverlapMM3 { return false }
        }
        return true
    }

    private static func boundarySegments(_ faces: [SeamFaceTriangle]) -> [(Vec2, Vec2)] {
        var edges: [EdgeKey: (count: Int, a: Vec2, b: Vec2)] = [:]
        for face in faces {
            for (a, b) in [(face.a, face.b), (face.b, face.c), (face.c, face.a)] {
                let key = EdgeKey(a, b)
                if var existing = edges[key] {
                    existing.count += 1
                    edges[key] = existing
                } else {
                    edges[key] = (1, a, b)
                }
            }
        }
        return edges.values.filter { $0.count == 1 }.map { ($0.a, $0.b) }
    }

    private static func contains(_ point: Vec2, in faces: [SeamFaceTriangle]) -> Bool {
        faces.contains { face in
            let c1 = cross2D(face.a, face.b, point)
            let c2 = cross2D(face.b, face.c, point)
            let c3 = cross2D(face.c, face.a, point)
            let hasNegative = c1 < -1.0e-8 || c2 < -1.0e-8 || c3 < -1.0e-8
            let hasPositive = c1 > 1.0e-8 || c2 > 1.0e-8 || c3 > 1.0e-8
            return !(hasNegative && hasPositive)
        }
    }

    private static func distanceToBoundary(_ point: Vec2, segments: [(Vec2, Vec2)]) -> Double {
        segments.reduce(Double.greatestFiniteMagnitude) { current, segment in
            min(current, distance(point, to: segment))
        }
    }

    private static func distance(_ point: Vec2, to segment: (Vec2, Vec2)) -> Double {
        let dx = segment.1.x - segment.0.x
        let dy = segment.1.y - segment.0.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1.0e-12 else {
            return hypot(point.x - segment.0.x, point.y - segment.0.y)
        }
        let t = min(1, max(0,
            ((point.x - segment.0.x) * dx + (point.y - segment.0.y) * dy) / lengthSquared
        ))
        return hypot(point.x - (segment.0.x + t * dx), point.y - (segment.0.y + t * dy))
    }

    private static func cross2D(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    // MARK: - Prism / tube / disk builders

    private static func ring2D(center: Vec2, halfW: Double, halfH: Double, rect: Bool, clockwise: Bool) -> [Vec2] {
        if rect {
            let ccw = [
                Vec2(x: center.x - halfW, y: center.y - halfH),
                Vec2(x: center.x + halfW, y: center.y - halfH),
                Vec2(x: center.x + halfW, y: center.y + halfH),
                Vec2(x: center.x - halfW, y: center.y + halfH)
            ]
            return clockwise ? ccw.reversed() : ccw
        } else {
            let segments = 24
            var pts: [Vec2] = []
            for i in 0..<segments {
                let t = Double(i) / Double(segments) * 2 * Double.pi
                let angle = clockwise ? -t : t
                pts.append(Vec2(x: center.x + halfW * cos(angle),
                                y: center.y + halfW * sin(angle)))
            }
            return pts
        }
    }

    private static func liftRing(_ poly: [Vec2], origin: Vec3, u: Vec3, v: Vec3, normal: Vec3, offset: Double) -> [Vec3] {
        poly.map { p in
            let base = add(add(origin, scale(u, p.x)), scale(v, p.y))
            return add(base, scale(normal, offset))
        }
    }

    private static func appendClosedPrism(
        bottom: [Vec3], top: [Vec3],
        into tris: inout [(Vec3, Vec3, Vec3)],
        capBottomCW: Bool, capTopCW: Bool
    ) {
        appendTube(outer: top, inner: bottom, into: &tris)
        appendDisk(ring: bottom, center: centroid(bottom), into: &tris, clockwise: capBottomCW)
        appendDisk(ring: top,    center: centroid(top),    into: &tris, clockwise: capTopCW)
    }

    /// Side walls: quads between `outer` (far from seam) and `inner` (at seam).
    private static func appendTube(outer: [Vec3], inner: [Vec3], into tris: inout [(Vec3, Vec3, Vec3)]) {
        guard outer.count == inner.count, outer.count >= 3 else { return }
        let n = outer.count
        for i in 0..<n {
            let j = (i + 1) % n
            tris.append((outer[i], inner[i], inner[j]))
            tris.append((outer[i], inner[j], outer[j]))
        }
    }

    private static func appendDisk(ring: [Vec3], center: Vec3, into tris: inout [(Vec3, Vec3, Vec3)], clockwise: Bool) {
        guard ring.count >= 3 else { return }
        let n = ring.count
        for i in 0..<n {
            let j = (i + 1) % n
            if clockwise {
                tris.append((center, ring[j], ring[i]))
            } else {
                tris.append((center, ring[i], ring[j]))
            }
        }
    }

    private static func centroid(_ ring: [Vec3]) -> Vec3 {
        guard !ring.isEmpty else { return Vec3(x: 0, y: 0, z: 0) }
        var sx = 0.0, sy = 0.0, sz = 0.0
        for p in ring { sx += p.x; sy += p.y; sz += p.z }
        let n = Double(ring.count)
        return Vec3(x: sx / n, y: sy / n, z: sz / n)
    }

    // MARK: - Boolean combination

    private enum BoolOp { case union, difference }

    /// Combine a part with a closed key solid (given as triangle soup) via a real
    /// Manifold boolean. `.union` welds a male boss into the part; `.difference`
    /// carves a female pocket out of it. Both keep the part watertight (a raw
    /// triangle concatenation would leave free boundary edges at the seam). The
    /// soup must describe a CLOSED solid (it does — `appendClosedPrism`).
    private static func combine(
        _ base: MeshGeometryData,
        with toolTris: [(Vec3, Vec3, Vec3)],
        op: BoolOp
    ) throws -> MeshGeometryData {
        let toolGeo = triSoupToGeometry(toolTris)
        let baseHandle = try ManifoldEngine.make(from: base)
        let toolHandle = try ManifoldEngine.make(from: toolGeo)
        let result: ManifoldHandle
        switch op {
        case .union:      result = try ManifoldEngine.union(baseHandle, toolHandle)
        case .difference: result = try ManifoldEngine.difference(baseHandle, toolHandle)
        }
        withExtendedLifetime(baseHandle) {}
        withExtendedLifetime(toolHandle) {}
        let geo = try ManifoldEngine.toMesh(result)
        withExtendedLifetime(result) {}
        return geo
    }

    /// Convert a flat triangle soup into `MeshGeometryData` (one fresh vertex
    /// triple per triangle; Manifold welds on import).
    private static func triSoupToGeometry(_ tris: [(Vec3, Vec3, Vec3)]) -> MeshGeometryData {
        var verts:   [Vec3]  = []
        var indices: [Int32] = []
        verts.reserveCapacity(tris.count * 3)
        indices.reserveCapacity(tris.count * 3)
        for tri in tris {
            let offset = Int32(verts.count)
            verts.append(tri.0); verts.append(tri.1); verts.append(tri.2)
            indices.append(offset); indices.append(offset + 1); indices.append(offset + 2)
        }
        return MeshGeometryData(vertices: verts, triangleIndices: indices)
    }

    // MARK: - Ray / vector helpers (Möller–Trumbore, no external dependencies)

    private static func rayFirstHit(origin: Vec3, dir: Vec3, triangles: [(Vec3, Vec3, Vec3)]) -> Double? {
        var best: Double?
        for tri in triangles {
            let e1 = subtract(tri.1, tri.0)
            let e2 = subtract(tri.2, tri.0)
            let h  = cross(dir, e2)
            let det = dot(e1, h)
            if abs(det) < 1.0e-12 { continue }
            let f  = 1.0 / det
            let s  = subtract(origin, tri.0)
            let uu = f * dot(s, h)
            if uu < -1.0e-9 || uu > 1.0 + 1.0e-9 { continue }
            let q  = cross(s, e1)
            let vv = f * dot(dir, q)
            if vv < -1.0e-9 || uu + vv > 1.0 + 1.0e-9 { continue }
            let t = f * dot(e2, q)
            if t > 1.0e-6 {
                if best == nil || t < best! { best = t }
            }
        }
        return best
    }

    private static func dot(_ a: Vec3, _ b: Vec3)     -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3  { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func add(_ a: Vec3, _ b: Vec3)      -> Vec3  { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func scale(_ a: Vec3, _ s: Double)  -> Vec3  { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y,
             y: a.z * b.x - a.x * b.z,
             z: a.x * b.y - a.y * b.x)
    }

    private static func project(_ p: Vec3, origin: Vec3, u: Vec3, v: Vec3) -> Vec2 {
        let rel = subtract(p, origin)
        return Vec2(x: dot(rel, u), y: dot(rel, v))
    }

    private static func unproject(_ p: Vec2, origin: Vec3, u: Vec3, v: Vec3) -> Vec3 {
        add(add(origin, scale(u, p.x)), scale(v, p.y))
    }

    /// Build an orthonormal in-plane basis for the given unit normal.
    private static func planeBasis(_ n: Vec3) -> (u: Vec3, v: Vec3) {
        let helper: Vec3 = abs(n.x) < 0.9 ? Vec3(x: 1, y: 0, z: 0) : Vec3(x: 0, y: 1, z: 0)
        let u = normalized(cross(helper, n))
        let v = cross(n, u)
        return (u, v)
    }

    private static func normalized(_ a: Vec3) -> Vec3 {
        let len = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        guard len > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return scale(a, 1.0 / len)
    }
}
