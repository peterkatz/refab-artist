import Foundation

/// Adds a MoldBoxer-style flared flange plate along each parting seam so the
/// parts clamp shut against pour pressure without the whole mold going blocky:
/// the mold body stays a conformal shell, and only the connection surface
/// flares out into a flat plate.
///
/// Construction per seam (all real Manifold booleans — watertight by
/// construction):
///   1. Sample the shell cross-section at the parting plane (the seam band).
///   2. Take its 2-D convex hull and offset it outward by `flange.width`
///      (exact Minkowski sum with a 16-gon disc → rounded plate outline).
///   3. Extrude the outline ±thickness/2 along the plane normal into a plate.
///   4. Subtract the cavity solid, which cuts the model-silhouette hole so the
///      plate never seals the cavity at the seam.
///   5. Split and quadrant-trim the plate into the two pieces that will actually
///      be attached, then accept only a complete bolt pattern that removes
///      material from both pieces at every bore.
///   6. Union every original part with all of its immutable-input contributions
///      once, clear only generated flange material across mating seams, restore
///      immutable input material, and commit only after assembly-wide proofs.
///
/// Bolt placement is deterministic from `seed`, and mating parts share the same
/// bores (one plate, split at the plane) so clamped holes always align.
enum MoldFlangeBuilder {
    /// Manifold intersections of independently normalized mating faces can leave
    /// sub-0.01 mm^3 contact noise. This matches the external geometry auditor;
    /// larger positive overlap remains a hard transactional rollback.
    private static let maximumNumericalOverlapMM3 = 0.01
    private static let normalizedSeamClearanceMM = 0.01
    private static let minimumNovelMaterialRetention = 0.98
    private static let minimumImmutableMaterialRetention = 0.999

    /// Result of the flange stage.
    struct FlangeResult: Equatable {
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]
        /// Complete per-feature evidence after the committed flange transaction.
        var protectedAudit: ProtectedToolingAuditSet.AuditResult? = nil
        /// Caller records plus exact generated flange plate and bolt-bore profiles.
        /// The planner carries this forward into keying and final normalization.
        var protectedAuditSet: ProtectedToolingAuditSet? = nil
        /// Physical mating interfaces that actually received a flange plate (for loud-failure
        /// reporting and the assembly guide's conditional clamp step).
        var flangedSeamCount: Int = 0
        /// Number of part-side flange plates that survived attachment and validation.
        var flangePlatesPlaced: Int = 0
        /// Number of bolt bores that survived on a flange seam retained in the result.
        var effectiveBoltHoleCount: Int = 0
        /// Lowest retained fraction of any counted part-side contribution's
        /// novel material after final seam clearance and normalization.
        var minimumNovelMaterialRetention: Double = 0
        static let empty = FlangeResult(parts: [], diagnostics: [])
    }

    private struct StablePlacementKey: Hashable, Comparable {
        var components: [Int64]

        static func < (lhs: StablePlacementKey, rhs: StablePlacementKey) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }

    private struct InterfaceWork {
        var interface: MoldPartingInterfaces.Interface
        var placementKey: StablePlacementKey
        var label: String
    }

    private struct PartSideContribution {
        var partIndex: Int
        var interfaceLabel: String
        var piece: ManifoldHandle
        var survivalProbe: ManifoldHandle
        var novelVolume: Double
    }

    private struct BuiltInterface {
        var label: String
        var contributions: [PartSideContribution]
        var boltHoleCount: Int
        var boltBores: [BoreProfile]
    }

    private struct BoreProfile {
        var positive: MeshGeometryData
        var negative: MeshGeometryData
    }

    private struct BoredPieces {
        var positive: ManifoldHandle
        var negative: ManifoldHandle
        var bores: [BoreProfile]
    }

    private struct PlaneSideConstraint {
        var plane: PartitionPlane
        var positive: Bool
    }

    private struct FinalizedAssembly {
        var parts: [MotherMoldPart]
        var diagnostics: [MoldDiagnostic]
        var minimumNovelMaterialRetention: Double
        var protectedLocatorRetention: Double?
    }

    /// Audits geometry introduced before stage 6 without allowing this stage to
    /// normalize, trim, or otherwise launder it away as part of flange cleanup.
    private struct ProtectedGeometryAudit {
        var handle: ManifoldHandle
        var volume: Double

        init?(geometry: MeshGeometryData) {
            guard let handle = try? ManifoldEngine.make(from: geometry) else { return nil }
            let volume = abs(ManifoldEngine.volume(handle))
            guard volume > 1.0e-6 else {
                withExtendedLifetime(handle) {}
                return nil
            }
            self.handle = handle
            self.volume = volume
        }

        func retainedFraction(in parts: [MotherMoldPart]) -> Double? {
            do {
                var retainedVolume = 0.0
                for part in parts {
                    let partHandle = try ManifoldEngine.make(from: part.geometry)
                    let intersection = try ManifoldEngine.intersect(handle, partHandle)
                    retainedVolume += abs(ManifoldEngine.volume(intersection))
                    withExtendedLifetime(partHandle) {}
                    withExtendedLifetime(intersection) {}
                }
                return min(1, retainedVolume / volume)
            } catch {
                return nil
            }
        }
    }

    private struct FlangeBuildFailure: Error {
        var message: String
    }

    /// Add flange plates and bolt holes along every seam.
    /// No-op when `flange.enabled == false`.
    /// `cavity` is the mold cavity solid (master for slip shell, offset master
    /// for silicone jacket) — subtracted so the plate keeps the seam open.
    static func applyFlanges(
        parts: [MotherMoldPart],
        planes: [PartitionPlane],
        flange: FlangeSettings,
        cavity: MeshGeometryData,
        seed: Int,
        protectedLocator: MeshGeometryData? = nil,
        protectedAuditSet: ProtectedToolingAuditSet? = nil
    ) throws -> FlangeResult {
        guard flange.enabled, !planes.isEmpty, parts.count >= 2 else {
            return FlangeResult(parts: parts, diagnostics: [])
        }

        let f = flange.sanitized
        var diagnostics: [MoldDiagnostic] = []
        func rolledBack(_ message: String) -> FlangeResult {
            var failureDiagnostics = diagnostics
            failureDiagnostics.append(.init(.error, message))
            return FlangeResult(parts: parts, diagnostics: failureDiagnostics)
        }

        if let protectedAuditSet {
            let inputAudit = protectedAuditSet.audit(finalParts: parts, stage: .flange)
            guard inputAudit.passes else {
                return rolledBack(inputAudit.diagnostics.joined(separator: " "))
            }
        }

        let protectedLocatorAudit = protectedLocator.flatMap(ProtectedGeometryAudit.init(geometry:))
        let initialProtectedLocatorRetention: Double?
        if protectedLocator != nil, protectedLocatorAudit == nil {
            return rolledBack("The generated locator could not be measured before flanging. The complete flange set was rolled back.")
        }
        if let protectedLocatorAudit,
           let initialRetention = protectedLocatorAudit.retainedFraction(in: parts) {
            guard initialRetention >= minimumNovelMaterialRetention else {
                return rolledBack(
                    String(
                        format: "The generated locator entered flanging at only %.2f%% retention (required at least %.2f%%). The complete flange set was rolled back.",
                        initialRetention * 100,
                        minimumNovelMaterialRetention * 100
                    )
                )
            }
            initialProtectedLocatorRetention = initialRetention
        } else if protectedLocatorAudit != nil {
            return rolledBack("The generated locator could not be measured in the immutable flange input. The complete flange set was rolled back.")
        } else {
            initialProtectedLocatorRetention = nil
        }

        guard let canonicalPlanes = canonicalizedPlanes(planes) else {
            return rolledBack("Flanging received a non-finite or degenerate parting plane. The complete flange set was rolled back.")
        }
        guard parts.count.isMultiple(of: 2) else {
            return rolledBack("Flanging requires an even set of mating parts. The complete flange set was rolled back.")
        }
        let expectedInterfaceCount = canonicalPlanes.count * max(1, parts.count / 2)
        let resolvedInterfaces = MoldPartingInterfaces.resolve(parts: parts, planes: canonicalPlanes)
        guard resolvedInterfaces.count == expectedInterfaceCount else {
            return rolledBack(
                "Flanging could identify only \(resolvedInterfaces.count) of \(expectedInterfaceCount) requested physical mating interfaces. The complete flange set was rolled back."
            )
        }

        var work: [InterfaceWork] = []
        work.reserveCapacity(resolvedInterfaces.count)
        for interface in resolvedInterfaces {
            guard let placementKey = placementKey(for: interface, parts: parts) else {
                return rolledBack(
                    "Flanging could not derive a stable geometric placement key for every requested interface. The complete flange set was rolled back."
                )
            }
            work.append(InterfaceWork(interface: interface, placementKey: placementKey, label: ""))
        }
        guard Set(work.map(\.placementKey)).count == work.count else {
            return rolledBack(
                "Flanging resolved duplicate physical interfaces instead of a complete unique interface set. The complete flange set was rolled back."
            )
        }
        work.sort { $0.placementKey < $1.placementKey }
        for index in work.indices {
            work[index].label = "\(index + 1)"
        }

        let cavityHandle: ManifoldHandle?
        if cavity.vertices.isEmpty {
            cavityHandle = nil
        } else {
            do {
                cavityHandle = try ManifoldEngine.make(from: cavity)
            } catch {
                return rolledBack(
                    "The cavity solid could not be loaded for flange trimming (\(error)). The complete flange set was rolled back."
                )
            }
        }

        var builtInterfaces: [BuiltInterface] = []
        builtInterfaces.reserveCapacity(work.count)
        for item in work {
            do {
                builtInterfaces.append(try buildInterface(
                    item,
                    originalParts: parts,
                    planes: canonicalPlanes,
                    flange: f,
                    cavity: cavityHandle,
                    seed: seed
                ))
            } catch let failure as FlangeBuildFailure {
                return rolledBack(failure.message)
            } catch {
                return rolledBack(
                    "Interface \(item.label): flange geometry failed (\(error)). The complete flange set was rolled back."
                )
            }
        }

        let contributions = builtInterfaces.flatMap(\.contributions)
        guard builtInterfaces.count == expectedInterfaceCount,
              contributions.count == expectedInterfaceCount * 2,
              builtInterfaces.allSatisfy({ $0.boltHoleCount == f.boltHoleCount }) else {
            return rolledBack(
                "Flanging did not complete every two-sided plate and requested bolt pattern. The complete flange set was rolled back."
            )
        }

        do {
            let combined = try combineOriginalPartsOnce(parts, contributions: contributions)
            let finalized = try finalizeAssembly(
                combined,
                originalParts: parts,
                planes: canonicalPlanes,
                contributions: contributions,
                protectedLocatorAudit: protectedLocatorAudit,
                initialProtectedLocatorRetention: initialProtectedLocatorRetention
            )
            diagnostics.append(contentsOf: finalized.diagnostics)
            let protectedClearedParts = try clearProtectedVoids(
                from: finalized.parts,
                auditSet: protectedAuditSet
            )
            for built in builtInterfaces {
                diagnostics.append(.init(
                    .info,
                    "Interface \(built.label): flared flange added (width \(fmt(f.width)) mm, \(built.boltHoleCount) bolt hole\(built.boltHoleCount == 1 ? "" : "s"))."
                ))
            }
            let generatedRecords = try flangeAuditRecords(
                builtInterfaces: builtInterfaces,
                finalParts: protectedClearedParts
            )
            let completeAuditSet = try (protectedAuditSet ?? ProtectedToolingAuditSet(records: []))
                .appending(generatedRecords)
            let protectedAudit = completeAuditSet.audit(finalParts: protectedClearedParts, stage: .flange)
            guard protectedAudit.passes else {
                return rolledBack(protectedAudit.diagnostics.joined(separator: " "))
            }
            return FlangeResult(
                parts: protectedClearedParts,
                diagnostics: diagnostics,
                protectedAudit: protectedAudit,
                protectedAuditSet: completeAuditSet,
                flangedSeamCount: builtInterfaces.count,
                flangePlatesPlaced: contributions.count,
                effectiveBoltHoleCount: builtInterfaces.reduce(0) { $0 + $1.boltHoleCount },
                minimumNovelMaterialRetention: finalized.minimumNovelMaterialRetention
            )
        } catch let failure as FlangeBuildFailure {
            return rolledBack(failure.message)
        } catch {
            return rolledBack(
                "The complete flange set could not be combined and validated (\(error)). All flange geometry and counts were rolled back."
            )
        }
    }

    /// Flange plates are generated after fixture bores exist. Trim only the
    /// new assembled result around those typed voids, then revalidate the exact
    /// parts. The pre-transaction audit above proves these profiles were already
    /// clear in the immutable input, so this operation cannot legitimize a
    /// missing receiver by cutting unrelated source material.
    private static func clearProtectedVoids(
        from parts: [MotherMoldPart],
        auditSet: ProtectedToolingAuditSet?
    ) throws -> [MotherMoldPart] {
        guard let auditSet else { return parts }
        let voids = auditSet.records.filter { $0.behavior == .subtractive }
        guard !voids.isEmpty else { return parts }

        var cleared = parts
        for index in cleared.indices {
            var handle = try ManifoldEngine.make(from: cleared[index].geometry)
            for record in voids {
                let applies: Bool
                switch record.ownership {
                case .assembly:
                    applies = true
                case .singlePart(let name):
                    applies = name == cleared[index].name
                case .parts(let names):
                    applies = names.contains(cleared[index].name)
                }
                guard applies else { continue }
                let profile = try ManifoldEngine.make(from: record.geometry)
                handle = try ManifoldEngine.difference(handle, profile)
            }
            guard ManifoldEngine.isWatertight(handle), !ManifoldEngine.isEmpty(handle) else {
                throw FlangeBuildFailure(
                    message: "Clearing protected fixture paths made \(cleared[index].name) empty or non-watertight. The complete flange set was rolled back."
                )
            }
            cleared[index].geometry = try ManifoldEngine.toMesh(handle)
            cleared[index].bounds = ManifoldEngine.bounds(handle)
        }
        let validation = MotherMoldValidation.validate(parts: cleared)
        guard validation.allPartsWatertight,
              validation.parts.map(\.name) == parts.map(\.name) else {
            throw FlangeBuildFailure(
                message: "Protected fixture-path clearance did not serialize as the original ordered printable flange parts. The complete flange set was rolled back."
            )
        }
        return validation.parts
    }

    private static func buildInterface(
        _ work: InterfaceWork,
        originalParts: [MotherMoldPart],
        planes: [PartitionPlane],
        flange: FlangeSettings,
        cavity: ManifoldHandle?,
        seed: Int
    ) throws -> BuiltInterface {
        let interface = work.interface
        let plane = interface.plane
        let (u, v) = planeBasis(plane.normal)
        let origin = scale(plane.normal, plane.offset)
        let band = max(0.75, flange.thickness / 2)
        var samples: [Vec2] = []
        for partIndex in [interface.positivePartIndex, interface.negativePartIndex] {
            collectSeamSamples(
                geometry: originalParts[partIndex].geometry,
                plane: plane,
                band: band,
                origin: origin,
                u: u,
                v: v,
                into: &samples
            )
        }
        let hull = convexHull2D(samples)
        guard hull.count >= 3, polygonArea(hull) > 1.0 else {
            throw FlangeBuildFailure(
                message: "Interface \(work.label): the immutable input parts produced a degenerate seam footprint. The complete flange set was rolled back."
            )
        }

        let outline = offsetConvexPolygon(hull, by: flange.width)
        let attachmentDepth = min(max(1.0, flange.thickness / 3), flange.width / 2)
        guard let innerOutline = insetConvexPolygon(hull, by: attachmentDepth) else {
            throw FlangeBuildFailure(
                message: "Interface \(work.label): the seam footprint could not support a connected flange attachment band. The complete flange set was rolled back."
            )
        }
        let outerPlate = try ManifoldEngine.make(from: prismGeometry(
            polygon: outline,
            origin: origin,
            u: u,
            v: v,
            normal: plane.normal,
            halfThickness: flange.thickness / 2
        ))
        let innerCutout = try ManifoldEngine.make(from: prismGeometry(
            polygon: innerOutline,
            origin: origin,
            u: u,
            v: v,
            normal: plane.normal,
            halfThickness: flange.thickness
        ))
        var plate = try ManifoldEngine.difference(outerPlate, innerCutout)
        if let cavity {
            plate = try ManifoldEngine.difference(plate, cavity)
        }
        guard !ManifoldEngine.isEmpty(plate), ManifoldEngine.isWatertight(plate) else {
            throw FlangeBuildFailure(
                message: "Interface \(work.label): cavity trimming removed or invalidated the flange plate. The complete flange set was rolled back."
            )
        }

        let halves = try ManifoldEngine.splitByPlane(
            plate,
            normal: plane.normal,
            offset: plane.offset
        )
        var positivePiece = try trimInterfacePiece(
            halves.0,
            for: interface.positivePartIndex,
            excludingPlaneAt: interface.planeIndex,
            originalParts: originalParts,
            planes: planes
        )
        var negativePiece = try trimInterfacePiece(
            halves.1,
            for: interface.negativePartIndex,
            excludingPlaneAt: interface.planeIndex,
            originalParts: originalParts,
            planes: planes
        )
        guard !ManifoldEngine.isEmpty(positivePiece), !ManifoldEngine.isEmpty(negativePiece) else {
            throw FlangeBuildFailure(
                message: "Interface \(work.label): flange generation did not produce material for both mating parts. The complete flange set was rolled back."
            )
        }

        var boltBores: [BoreProfile] = []
        if flange.boltHoleCount > 0 {
            let boltRadius = flange.boltDiameter / 2
            guard flange.width / 2 >= boltRadius + 1.0 else {
                let requiredWidth = 2 * (boltRadius + 1.0)
                throw FlangeBuildFailure(
                    message: "Interface \(work.label): the requested Ø\(fmt(flange.boltDiameter)) mm bolt pattern needs a flange at least \(fmt(requiredWidth)) mm wide. The complete flange set was rolled back."
                )
            }
            let maximumRingOffset = max(
                flange.width / 2,
                flange.width - boltRadius - 1.0
            )
            var constraints: [PlaneSideConstraint] = []
            for (planeIndex, otherPlane) in planes.enumerated()
                where planeIndex != interface.planeIndex {
                let positiveSide = partIsOnPositiveSide(
                    originalParts[interface.positivePartIndex],
                    of: otherPlane
                )
                let negativeSide = partIsOnPositiveSide(
                    originalParts[interface.negativePartIndex],
                    of: otherPlane
                )
                guard positiveSide == negativeSide else {
                    throw FlangeBuildFailure(
                        message: "Interface \(work.label): mating parts did not share a stable neighboring-plane segment. The complete flange set was rolled back."
                    )
                }
                constraints.append(PlaneSideConstraint(
                    plane: otherPlane,
                    positive: positiveSide
                ))
            }
            let patterns = boltCentreCandidatePatterns(
                hull: hull,
                count: flange.boltHoleCount,
                ringOffsets: [
                    flange.width / 2,
                    min(flange.width * 0.7, maximumRingOffset),
                    maximumRingOffset,
                ],
                boltRadius: boltRadius,
                plateThickness: flange.thickness,
                constrainedBy: constraints,
                origin: origin,
                u: u,
                v: v,
                seed: seed,
                placementKey: work.placementKey
            )
            var completePattern: BoredPieces?
            for pattern in patterns {
                if let bored = try? boreCompletePattern(
                    pattern,
                    positivePiece: positivePiece,
                    negativePiece: negativePiece,
                    origin: origin,
                    u: u,
                    v: v,
                    normal: plane.normal,
                    thickness: flange.thickness,
                    boltRadius: boltRadius
                ) {
                    completePattern = bored
                    break
                }
            }
            guard let completePattern else {
                throw FlangeBuildFailure(
                    message: "Interface \(work.label): no deterministic complete pattern made all \(flange.boltHoleCount) requested bolt bores effective on both mating plate pieces. The complete flange set was rolled back."
                )
            }
            positivePiece = completePattern.positive
            negativePiece = completePattern.negative
            boltBores = completePattern.bores
        }

        let positive = try makeContribution(
            piece: positivePiece,
            partIndex: interface.positivePartIndex,
            interfaceLabel: work.label,
            originalParts: originalParts
        )
        let negative = try makeContribution(
            piece: negativePiece,
            partIndex: interface.negativePartIndex,
            interfaceLabel: work.label,
            originalParts: originalParts
        )
        return BuiltInterface(
            label: work.label,
            contributions: [positive, negative],
            boltHoleCount: flange.boltHoleCount,
            boltBores: boltBores
        )
    }

    private static func trimInterfacePiece(
        _ half: ManifoldHandle,
        for partIndex: Int,
        excludingPlaneAt excludedPlaneIndex: Int,
        originalParts: [MotherMoldPart],
        planes: [PartitionPlane]
    ) throws -> ManifoldHandle {
        var piece = half
        for (planeIndex, plane) in planes.enumerated() where planeIndex != excludedPlaneIndex {
            let onPositive = partIsOnPositiveSide(originalParts[partIndex], of: plane)
            piece = try ManifoldEngine.trimByPlane(
                piece,
                normal: onPositive ? plane.normal : scale(plane.normal, -1),
                offset: onPositive ? plane.offset : -plane.offset
            )
        }
        return piece
    }

    private static func boreCompletePattern(
        _ centres: [Vec2],
        positivePiece: ManifoldHandle,
        negativePiece: ManifoldHandle,
        origin: Vec3,
        u: Vec3,
        v: Vec3,
        normal: Vec3,
        thickness: Double,
        boltRadius: Double
    ) throws -> BoredPieces {
        var positive = positivePiece
        var negative = negativePiece
        var bores: [BoreProfile] = []
        for centre in centres {
            let centre3D = add(add(origin, scale(u, centre.x)), scale(v, centre.y))
            let bore = try ManifoldEngine.make(from: triSoupToGeometry(cylinderTriSoup(
                base: add(centre3D, scale(normal, -thickness * 0.7)),
                axis: scale(normal, thickness * 1.4),
                radius: boltRadius,
                segments: 24
            )))
            let positiveBefore = abs(ManifoldEngine.volume(positive))
            let negativeBefore = abs(ManifoldEngine.volume(negative))
            let nextPositive = try ManifoldEngine.difference(positive, bore)
            let nextNegative = try ManifoldEngine.difference(negative, bore)
            let positiveRemovedHandle = try ManifoldEngine.intersect(positive, bore)
            let negativeRemovedHandle = try ManifoldEngine.intersect(negative, bore)
            let positiveRemoved = abs(ManifoldEngine.volume(positiveRemovedHandle))
            let negativeRemoved = abs(ManifoldEngine.volume(negativeRemovedHandle))
            let positiveTolerance = max(1.0e-4, positiveBefore * 1.0e-10)
            let negativeTolerance = max(1.0e-4, negativeBefore * 1.0e-10)
            guard positiveRemoved > positiveTolerance,
                  negativeRemoved > negativeTolerance,
                  !ManifoldEngine.isEmpty(nextPositive),
                  !ManifoldEngine.isEmpty(nextNegative),
                  ManifoldEngine.isWatertight(nextPositive),
                  ManifoldEngine.isWatertight(nextNegative) else {
                throw FlangeBuildFailure(message: "Bolt bore did not remove measurable material from both mating plate pieces.")
            }
            bores.append(BoreProfile(
                positive: try ManifoldEngine.toMesh(positiveRemovedHandle),
                negative: try ManifoldEngine.toMesh(negativeRemovedHandle)
            ))
            withExtendedLifetime(positiveRemovedHandle) {}
            withExtendedLifetime(negativeRemovedHandle) {}
            positive = nextPositive
            negative = nextNegative
        }
        return BoredPieces(positive: positive, negative: negative, bores: bores)
    }

    private static func flangeAuditRecords(
        builtInterfaces: [BuiltInterface],
        finalParts: [MotherMoldPart]
    ) throws -> [ProtectedToolingAuditSet.Record] {
        var records: [ProtectedToolingAuditSet.Record] = []
        for built in builtInterfaces {
            for contribution in built.contributions {
                let partName = finalParts[contribution.partIndex].name
                let finalPart = try ManifoldEngine.make(from: finalParts[contribution.partIndex].geometry)
                let retainedPiece = try ManifoldEngine.intersect(contribution.piece, finalPart)
                guard ManifoldEngine.isWatertight(retainedPiece),
                      !ManifoldEngine.isEmpty(retainedPiece),
                      abs(ManifoldEngine.volume(retainedPiece)) > ProtectedToolingAuditSet.minimumMeasurableVolumeMM3 else {
                    throw FlangeBuildFailure(
                        message: "Interface \(built.label): no measurable final flange contribution survived on \(partName)."
                    )
                }
                let id = "flange-\(built.label)-\(partName)"
                let geometry = try normalizedAuditGeometry(
                    try ManifoldEngine.toMesh(retainedPiece),
                    id: id
                )
                records.append(.init(
                    id: id,
                    kind: .flange,
                    behavior: .additive,
                    ownership: .singlePart(partName),
                    geometry: geometry,
                    requiredRetention: minimumNovelMaterialRetention,
                    provenance: [.flange]
                ))
            }
            for (index, bore) in built.boltBores.enumerated() {
                for (side, rawGeometry) in [("positive", bore.positive), ("negative", bore.negative)] {
                    let contribution = built.contributions[side == "positive" ? 0 : 1]
                    let id = "flange-bore-\(built.label)-\(index + 1)-\(side)"
                    let geometry = try normalizedAuditGeometry(rawGeometry, id: id)
                    records.append(.init(
                        id: id,
                        kind: .flangeBoltBore,
                        behavior: .subtractive,
                        ownership: .singlePart(finalParts[contribution.partIndex].name),
                        geometry: geometry,
                        requiredRetention: 1,
                        requiredClearance: minimumNovelMaterialRetention,
                        provenance: [.flange]
                    ))
                }
            }
        }
        return records
    }

    /// The audit set accepts only geometry that is closed after a position
    /// weld. Raw Manifold output of an organic intersection can keep
    /// positional self-contact or slivers that the weld collapses, so each
    /// generated witness goes through the same printable validation as the
    /// parts before it is recorded.
    private static func normalizedAuditGeometry(
        _ geometry: MeshGeometryData,
        id: String
    ) throws -> MeshGeometryData {
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: id,
            geometry: geometry
        )])
        guard validation.allPartsWatertight,
              let normalized = validation.parts.first?.geometry,
              MeshPreflight.analyze(geometry: normalized).isWatertight else {
            throw FlangeBuildFailure(
                message: "Flange evidence '\(id)' did not serialize as closed printable geometry. The complete flange set was rolled back."
            )
        }
        return normalized
    }

    private static func makeContribution(
        piece: ManifoldHandle,
        partIndex: Int,
        interfaceLabel: String,
        originalParts: [MotherMoldPart]
    ) throws -> PartSideContribution {
        guard ManifoldEngine.isWatertight(piece), !ManifoldEngine.isEmpty(piece) else {
            throw FlangeBuildFailure(
                message: "Interface \(interfaceLabel): a mating plate piece was empty or non-watertight. The complete flange set was rolled back."
            )
        }
        let pieceGeometry = try ManifoldEngine.toMesh(piece)
        guard MotherMoldValidation.hasFiniteCoordinates(pieceGeometry) else {
            throw FlangeBuildFailure(
                message: "Interface \(interfaceLabel): a mating plate piece contained non-finite coordinates. The complete flange set was rolled back."
            )
        }

        let original = try ManifoldEngine.make(from: originalParts[partIndex].geometry)
        let originalVolume = abs(ManifoldEngine.volume(original))
        let novel = try ManifoldEngine.difference(piece, original)
        let novelVolume = abs(ManifoldEngine.volume(novel))
        let combined = try ManifoldEngine.union(original, piece)
        let addedVolume = abs(ManifoldEngine.volume(combined)) - originalVolume
        let minimumNovelVolume = max(0.01, originalVolume * 1.0e-9)
        guard novelVolume > minimumNovelVolume, addedVolume > minimumNovelVolume else {
            throw FlangeBuildFailure(
                message: "Interface \(interfaceLabel): generated flange material added no measurable novel volume to \(originalParts[partIndex].name). The complete flange set was rolled back."
            )
        }
        return PartSideContribution(
            partIndex: partIndex,
            interfaceLabel: interfaceLabel,
            piece: piece,
            survivalProbe: novel,
            novelVolume: novelVolume
        )
    }

    private static func combineOriginalPartsOnce(
        _ originalParts: [MotherMoldPart],
        contributions: [PartSideContribution]
    ) throws -> [MotherMoldPart] {
        var contributionsByPart = [[PartSideContribution]](repeating: [], count: originalParts.count)
        for contribution in contributions {
            guard contributionsByPart.indices.contains(contribution.partIndex) else {
                throw FlangeBuildFailure(message: "A flange contribution referenced an invalid part index. The complete flange set was rolled back.")
            }
            contributionsByPart[contribution.partIndex].append(contribution)
        }

        var combinedParts: [MotherMoldPart] = []
        combinedParts.reserveCapacity(originalParts.count)
        for partIndex in originalParts.indices {
            guard !contributionsByPart[partIndex].isEmpty else {
                throw FlangeBuildFailure(
                    message: "\(originalParts[partIndex].name) received no flange contribution. The complete flange set was rolled back."
                )
            }
            let original = try ManifoldEngine.make(from: originalParts[partIndex].geometry)
            let handles = [original] + contributionsByPart[partIndex].map(\.piece)
            let combined = try ManifoldEngine.union(handles)
            guard ManifoldEngine.isWatertight(combined), !ManifoldEngine.isEmpty(combined) else {
                throw FlangeBuildFailure(
                    message: "The aggregate flange union for \(originalParts[partIndex].name) was empty or non-watertight. The complete flange set was rolled back."
                )
            }
            var part = originalParts[partIndex]
            part.geometry = try ManifoldEngine.toMesh(combined)
            part.bounds = nil
            combinedParts.append(part)
        }
        return combinedParts
    }

    private static func finalizeAssembly(
        _ combinedParts: [MotherMoldPart],
        originalParts: [MotherMoldPart],
        planes: [PartitionPlane],
        contributions: [PartSideContribution],
        protectedLocatorAudit: ProtectedGeometryAudit?,
        initialProtectedLocatorRetention: Double?
    ) throws -> FinalizedAssembly {
        var clearedParts: [MotherMoldPart] = []
        clearedParts.reserveCapacity(combinedParts.count)
        var cleanupDiagnostics: [MoldDiagnostic] = []
        let halfClearance = normalizedSeamClearanceMM * 0.5

        for partIndex in combinedParts.indices {
            var handle = try ManifoldEngine.make(from: combinedParts[partIndex].geometry)
            for plane in planes {
                let onPositive = partIsOnPositiveSide(originalParts[partIndex], of: plane)
                handle = try ManifoldEngine.trimByPlane(
                    handle,
                    normal: onPositive ? plane.normal : scale(plane.normal, -1),
                    offset: onPositive
                        ? plane.offset + halfClearance
                        : -plane.offset + halfClearance
                )
            }
            // Clearance belongs to the generated flange transaction, not to
            // pre-existing mold material. Restoring the exact immutable input
            // keeps locator and shell geometry intact while retaining the
            // clearance that prevents added flange plates from interfering.
            let original = try ManifoldEngine.make(from: originalParts[partIndex].geometry)
            handle = try ManifoldEngine.union([handle, original])
            guard ManifoldEngine.isWatertight(handle), !ManifoldEngine.isEmpty(handle) else {
                throw FlangeBuildFailure(
                    message: "Final flange assembly left \(combinedParts[partIndex].name) empty or non-watertight. The complete flange set was rolled back."
                )
            }
            let geometry = try ManifoldEngine.toMesh(handle)
            guard MotherMoldValidation.hasFiniteCoordinates(geometry) else {
                throw FlangeBuildFailure(
                    message: "Final flange assembly left \(combinedParts[partIndex].name) with non-finite coordinates. The complete flange set was rolled back."
                )
            }
            // Boolean unions at crossing flange planes can leave microscopic
            // zero-volume face islands. Remove only components that satisfy the
            // tiny-debris policy; materially positive components remain and
            // force rollback below. Immutable-input retention is proved again
            // after this cleanup, so it cannot erase legitimate source material.
            let tinyFiltered = MoldComponentFilter.dropFaceDisconnectedTinyDebris(geometry)
            if tinyFiltered.droppedCount > 0 {
                cleanupDiagnostics.append(.init(
                    .info,
                    String(
                        format: "Removed %d microscopic generated flange fragment(s) (%.6f mm^3) from %@ before final validation.",
                        tinyFiltered.droppedCount,
                        tinyFiltered.droppedVolume,
                        combinedParts[partIndex].name
                    )
                ))
            }
            let candidateGeometry = tinyFiltered.geometry
            let disconnected = MoldComponentFilter.dropFaceDisconnectedDebris(candidateGeometry)
            guard disconnected.droppedCount == 0 else {
                let originalDisconnected = MoldComponentFilter.dropFaceDisconnectedDebris(
                    originalParts[partIndex].geometry
                )
                let contributionComponents = contributions
                    .filter { $0.partIndex == partIndex }
                    .map { contribution -> String in
                        guard let pieceGeometry = try? ManifoldEngine.toMesh(contribution.piece) else {
                            return "interface \(contribution.interfaceLabel): unreadable"
                        }
                        let audit = MoldComponentFilter.dropFaceDisconnectedDebris(pieceGeometry)
                        return "interface \(contribution.interfaceLabel): \(audit.droppedCount) dropped candidate component(s), \(String(format: "%.3f", audit.droppedVolume)) mm^3"
                    }
                    .joined(separator: "; ")
                throw FlangeBuildFailure(
                    message: String(
                        format: "Final flange geometry for %@ contained %d disconnected component(s) totaling %.3f mm^3; the immutable input had %d totaling %.3f mm^3. Contribution audit: %@. No cleanup was committed; the complete flange set was rolled back.",
                        combinedParts[partIndex].name,
                        disconnected.droppedCount,
                        disconnected.droppedVolume,
                        originalDisconnected.droppedCount,
                        originalDisconnected.droppedVolume,
                        contributionComponents
                    )
                )
            }
            var part = combinedParts[partIndex]
            part.geometry = candidateGeometry
            part.bounds = nil
            clearedParts.append(part)
        }

        let validation = MotherMoldValidation.validate(parts: clearedParts)
        guard validation.allPartsWatertight,
              validation.parts.count == originalParts.count,
              validation.parts.map(\.name) == originalParts.map(\.name) else {
            throw FlangeBuildFailure(
                message: "Final flange normalization did not produce the original ordered set of printable parts. The complete flange set was rolled back."
            )
        }

        var finalHandles: [ManifoldHandle] = []
        finalHandles.reserveCapacity(validation.parts.count)
        for part in validation.parts {
            guard MotherMoldValidation.hasFiniteCoordinates(part.geometry),
                  MeshPreflight.analyze(geometry: part.geometry).isWatertight,
                  MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry).droppedCount == 0 else {
                throw FlangeBuildFailure(
                    message: "Final flange normalization left \(part.name) non-printable or face-disconnected. The complete flange set was rolled back."
                )
            }
            let handle = try ManifoldEngine.make(from: part.geometry)
            guard ManifoldEngine.isWatertight(handle), !ManifoldEngine.isEmpty(handle) else {
                throw FlangeBuildFailure(
                    message: "Final flange normalization left \(part.name) empty or non-watertight. The complete flange set was rolled back."
                )
            }
            finalHandles.append(handle)
        }

        for partIndex in originalParts.indices {
            let original = try ManifoldEngine.make(from: originalParts[partIndex].geometry)
            let originalVolume = abs(ManifoldEngine.volume(original))
            let survived = try ManifoldEngine.intersect(original, finalHandles[partIndex])
            let survivedVolume = abs(ManifoldEngine.volume(survived))
            let retention = min(1, survivedVolume / originalVolume)
            guard retention >= minimumImmutableMaterialRetention else {
                throw FlangeBuildFailure(
                    message: String(
                        format: "Immutable input %@ retained %.3f of %.3f mm^3 (%.2f%%; required at least %.2f%%). The complete flange set was rolled back.",
                        originalParts[partIndex].name,
                        survivedVolume,
                        originalVolume,
                        retention * 100,
                        minimumImmutableMaterialRetention * 100
                    )
                )
            }
        }

        var protectedLocatorRetention: Double?
        if let protectedLocatorAudit {
            guard let retention = protectedLocatorAudit.retainedFraction(in: validation.parts) else {
                throw FlangeBuildFailure(
                    message: "The generated locator could not be measured after flanging. The complete flange set was rolled back."
                )
            }
            protectedLocatorRetention = retention
            guard retention >= minimumNovelMaterialRetention else {
                throw FlangeBuildFailure(
                    message: String(
                        format: "Generated locator retention fell to %.2f%% after flanging (required at least %.2f%%). The complete flange set was rolled back.",
                        retention * 100,
                        minimumNovelMaterialRetention * 100
                    )
                )
            }
        }

        for firstIndex in finalHandles.indices {
            for secondIndex in finalHandles.indices where secondIndex > firstIndex {
                let intersection = try ManifoldEngine.intersect(
                    finalHandles[firstIndex],
                    finalHandles[secondIndex]
                )
                let overlap = abs(ManifoldEngine.volume(intersection))
                guard overlap <= maximumNumericalOverlapMM3 else {
                    throw FlangeBuildFailure(
                        message: String(
                            format: "Final flange parts %@ and %@ overlap by %.4f mm^3. The complete flange set was rolled back.",
                            validation.parts[firstIndex].name,
                            validation.parts[secondIndex].name,
                            overlap
                        )
                    )
                }
            }
        }

        var minimumMeasuredRetention = 1.0
        for contribution in contributions {
            let survived = try ManifoldEngine.intersect(
                finalHandles[contribution.partIndex],
                contribution.survivalProbe
            )
            let survivedVolume = abs(ManifoldEngine.volume(survived))
            let retention = min(1, survivedVolume / contribution.novelVolume)
            minimumMeasuredRetention = min(minimumMeasuredRetention, retention)
            guard retention >= minimumNovelMaterialRetention else {
                throw FlangeBuildFailure(
                    message: String(
                        format: "Interface %@: %@ retained %.3f of %.3f mm^3 counted novel flange material (%.2f%%; required at least %.2f%%). The complete flange set was rolled back.",
                        contribution.interfaceLabel,
                        validation.parts[contribution.partIndex].name,
                        survivedVolume,
                        contribution.novelVolume,
                        retention * 100,
                        minimumNovelMaterialRetention * 100
                    )
                )
            }
        }

        var finalDiagnostics = cleanupDiagnostics
        finalDiagnostics.append(contentsOf: validation.diagnostics.filter { $0.severity != .error })
        finalDiagnostics.append(.init(
            .info,
            String(
                format: "Flange survival proof retained at least %.2f%% of every counted part-side contribution's novel material.",
                minimumMeasuredRetention * 100
            )
        ))
        if let protectedLocatorRetention,
           let initialProtectedLocatorRetention {
            finalDiagnostics.append(.init(
                .info,
                String(
                    format: "Generated locator retention through the flange transaction: %.2f%% before, %.2f%% after.",
                    initialProtectedLocatorRetention * 100,
                    protectedLocatorRetention * 100
                )
            ))
        }
        return FinalizedAssembly(
            parts: validation.parts,
            diagnostics: finalDiagnostics,
            minimumNovelMaterialRetention: minimumMeasuredRetention,
            protectedLocatorRetention: protectedLocatorRetention
        )
    }

    private static func canonicalizedPlanes(
        _ planes: [PartitionPlane]
    ) -> [PartitionPlane]? {
        var canonical: [PartitionPlane] = []
        canonical.reserveCapacity(planes.count)
        for plane in planes {
            let raw = plane.normal
            let length = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
            guard length.isFinite,
                  length > 1.0e-9,
                  plane.offset.isFinite else { return nil }
            var normal = scale(raw, 1 / length)
            var offset = plane.offset / length
            let firstSignificant = [normal.x, normal.y, normal.z]
                .first { abs($0) > 1.0e-12 } ?? 0
            if firstSignificant < 0 {
                normal = scale(normal, -1)
                offset = -offset
            }
            canonical.append(PartitionPlane(
                id: plane.id,
                normal: normal,
                offset: offset,
                isManual: plane.isManual
            ))
        }
        return canonical.sorted { lhs, rhs in
            let left = quantizedPlaneComponents(lhs)
            let right = quantizedPlaneComponents(rhs)
            if left != right { return left.lexicographicallyPrecedes(right) }
            let leftExact = [lhs.normal.x, lhs.normal.y, lhs.normal.z, lhs.offset]
            let rightExact = [rhs.normal.x, rhs.normal.y, rhs.normal.z, rhs.offset]
            return leftExact.lexicographicallyPrecedes(rightExact)
        }
    }

    private static func placementKey(
        for interface: MoldPartingInterfaces.Interface,
        parts: [MotherMoldPart]
    ) -> StablePlacementKey? {
        guard parts.indices.contains(interface.positivePartIndex),
              parts.indices.contains(interface.negativePartIndex),
              let positive = areaWeightedCentroid(parts[interface.positivePartIndex].geometry),
              let negative = areaWeightedCentroid(parts[interface.negativePartIndex].geometry) else {
            return nil
        }
        let midpoint = scale(add(positive, negative), 0.5)
        let values = [midpoint.x, midpoint.y, midpoint.z]
        guard values.allSatisfy(\.isFinite) else { return nil }
        return StablePlacementKey(components:
            quantizedPlaneComponents(interface.plane) + [
                quantize(midpoint.x, scale: 10_000),
                quantize(midpoint.y, scale: 10_000),
                quantize(midpoint.z, scale: 10_000),
            ]
        )
    }

    private static func quantizedPlaneComponents(_ plane: PartitionPlane) -> [Int64] {
        [
            quantize(plane.normal.x, scale: 1_000_000),
            quantize(plane.normal.y, scale: 1_000_000),
            quantize(plane.normal.z, scale: 1_000_000),
            quantize(plane.offset, scale: 1_000_000),
        ]
    }

    private static func quantize(_ value: Double, scale: Double) -> Int64 {
        Int64((value * scale).rounded())
    }

    // MARK: - Seam sampling

    /// Collect 2-D samples of the seam band: vertices within `band` of the
    /// plane, plus the exact crossing points of triangle edges that straddle it.
    private static func collectSeamSamples(
        geometry: MeshGeometryData,
        plane: PartitionPlane,
        band: Double,
        origin: Vec3, u: Vec3, v: Vec3,
        into pts2D: inout [Vec2]
    ) {
        let verts = geometry.vertices
        var exact: [Vec2] = []
        var nearby: [Vec2] = []
        for p in verts {
            let distance = abs(dot(p, plane.normal) - plane.offset)
            if distance <= 1.0e-6 {
                exact.append(project(p, origin: origin, u: u, v: v))
            } else if distance <= band {
                nearby.append(project(p, origin: origin, u: u, v: v))
            }
        }
        let idx = geometry.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            let tri = [Int(idx[t]), Int(idx[t + 1]), Int(idx[t + 2])]
            t += 3
            for e in 0..<3 {
                let ia = tri[e], ib = tri[(e + 1) % 3]
                guard verts.indices.contains(ia), verts.indices.contains(ib) else { continue }
                let a = verts[ia], b = verts[ib]
                let da = dot(a, plane.normal) - plane.offset
                let db = dot(b, plane.normal) - plane.offset
                guard (da > 0) != (db > 0), abs(da - db) > 1.0e-12 else { continue }
                let s = da / (da - db)
                let x = Vec3(x: a.x + (b.x - a.x) * s,
                             y: a.y + (b.y - a.y) * s,
                             z: a.z + (b.z - a.z) * s)
                exact.append(project(x, origin: origin, u: u, v: v))
            }
        }
        let exactHull = convexHull2D(exact)
        if exactHull.count >= 3, polygonArea(exactHull) > 1.0 {
            pts2D.append(contentsOf: exact)
        } else {
            pts2D.append(contentsOf: exact + nearby)
        }
    }

    // MARK: - 2-D polygon machinery

    /// Andrew's monotone-chain convex hull, CCW winding.
    static func convexHull2D(_ points: [Vec2]) -> [Vec2] {
        let quantised = points.map { QuantisedPoint($0) }
        let unique = Array(Set(quantised))
        let pts = unique.map { $0.point }
            .sorted { lhs, rhs in
                lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y
            }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Vec2] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Vec2] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Hashable grid-quantised point so the hull input can be de-duplicated
    /// deterministically (1 µm grid).
    private struct QuantisedPoint: Hashable {
        let qx: Int64
        let qy: Int64
        let point: Vec2
        init(_ p: Vec2) {
            qx = Int64((p.x / 1.0e-3).rounded())
            qy = Int64((p.y / 1.0e-3).rounded())
            point = Vec2(x: Double(qx) * 1.0e-3, y: Double(qy) * 1.0e-3)
        }
        static func == (a: QuantisedPoint, b: QuantisedPoint) -> Bool { a.qx == b.qx && a.qy == b.qy }
        func hash(into h: inout Hasher) { h.combine(qx); h.combine(qy) }
    }

    /// Exact Minkowski sum of a convex polygon with a regular 16-gon disc of
    /// radius `by` — the flared, rounded plate outline.
    static func offsetConvexPolygon(_ hull: [Vec2], by radius: Double) -> [Vec2] {
        guard radius > 0 else { return hull }
        var swollen: [Vec2] = []
        swollen.reserveCapacity(hull.count * 16)
        for p in hull {
            for k in 0..<16 {
                let theta = Double(k) / 16.0 * 2 * Double.pi
                swollen.append(Vec2(x: p.x + radius * cos(theta),
                                    y: p.y + radius * sin(theta)))
            }
        }
        return convexHull2D(swollen)
    }

    /// Inset a convex CCW polygon by intersecting its inward-shifted edge
    /// lines. Returns nil when the requested attachment band consumes the
    /// footprint or numerical parallelism prevents a valid convex result.
    private static func insetConvexPolygon(
        _ hull: [Vec2],
        by distance: Double
    ) -> [Vec2]? {
        guard hull.count >= 3, distance > 0 else { return nil }
        struct OffsetLine {
            var point: Vec2
            var direction: Vec2
        }
        var lines: [OffsetLine] = []
        lines.reserveCapacity(hull.count)
        for index in hull.indices {
            let point = hull[index]
            let next = hull[(index + 1) % hull.count]
            let dx = next.x - point.x
            let dy = next.y - point.y
            let length = hypot(dx, dy)
            guard length > 1.0e-9 else { return nil }
            let direction = Vec2(x: dx / length, y: dy / length)
            let inward = Vec2(x: -direction.y, y: direction.x)
            lines.append(OffsetLine(
                point: Vec2(
                    x: point.x + inward.x * distance,
                    y: point.y + inward.y * distance
                ),
                direction: direction
            ))
        }

        func cross2D(_ lhs: Vec2, _ rhs: Vec2) -> Double {
            lhs.x * rhs.y - lhs.y * rhs.x
        }
        var inset: [Vec2] = []
        inset.reserveCapacity(hull.count)
        for index in lines.indices {
            let previous = lines[(index + lines.count - 1) % lines.count]
            let current = lines[index]
            let denominator = cross2D(previous.direction, current.direction)
            guard abs(denominator) > 1.0e-12 else { return nil }
            let delta = Vec2(
                x: current.point.x - previous.point.x,
                y: current.point.y - previous.point.y
            )
            let parameter = cross2D(delta, current.direction) / denominator
            inset.append(Vec2(
                x: previous.point.x + previous.direction.x * parameter,
                y: previous.point.y + previous.direction.y * parameter
            ))
        }
        let normalized = convexHull2D(inset)
        guard normalized.count >= 3,
              polygonArea(normalized) > 1.0 else { return nil }
        return normalized
    }

    /// Signed area of a CCW polygon.
    static func polygonArea(_ poly: [Vec2]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<poly.count {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// Extrude a convex CCW polygon (in the plane's u/v basis at `origin`) into
    /// a prism spanning ±`halfThickness` along `normal`. Convex → fan caps.
    private static func prismGeometry(
        polygon: [Vec2], origin: Vec3, u: Vec3, v: Vec3,
        normal: Vec3, halfThickness: Double
    ) -> MeshGeometryData {
        let n = polygon.count
        let lift = { (p: Vec2, w: Double) -> Vec3 in
            add(add(add(origin, scale(u, p.x)), scale(v, p.y)), scale(normal, w))
        }
        let bottom = polygon.map { lift($0, -halfThickness) }
        let top = polygon.map { lift($0, halfThickness) }
        var tris: [(Vec3, Vec3, Vec3)] = []
        // Caps: polygon is CCW in (u,v); with normal = u × v the top cap keeps
        // CCW seen from +normal, the bottom cap is reversed.
        for i in 1..<(n - 1) {
            tris.append((top[0], top[i], top[i + 1]))
            tris.append((bottom[0], bottom[i + 1], bottom[i]))
        }
        for i in 0..<n {
            let j = (i + 1) % n
            tris.append((bottom[i], bottom[j], top[j]))
            tris.append((bottom[i], top[j], top[i]))
        }
        return triSoupToGeometry(tris)
    }

    // MARK: - Bolt placement

    /// Build whole-pattern alternatives from stable global ring/phase choices.
    /// The caller evaluates each pattern from the same unbored two-sided pieces
    /// and commits only after every bore removes material from both pieces.
    private static func boltCentreCandidatePatterns(
        hull: [Vec2], count: Int,
        ringOffsets: [Double], boltRadius: Double,
        plateThickness: Double,
        constrainedBy constraints: [PlaneSideConstraint],
        origin: Vec3, u: Vec3, v: Vec3,
        seed: Int, placementKey: StablePlacementKey
    ) -> [[Vec2]] {
        guard count > 0 else { return [] }

        // Each neighbouring parting plane carries its own flange plate,
        // `plateThickness` thick and centred on that plane, and the same part
        // receives it. A bore closer to that plane than half the plate plus
        // its radius would be filled again by the neighbouring plate when the
        // part's flanges are combined, so keep a 1 mm ligament past it.
        let planeClearance = boltRadius + max(2.0, plateThickness / 2 + 1.0)
        func isSafe(_ p2: Vec2) -> Bool {
            let p3 = add(add(origin, scale(u, p2.x)), scale(v, p2.y))
            for constraint in constraints {
                let signedDistance = dot(p3, constraint.plane.normal)
                    - constraint.plane.offset
                if constraint.positive {
                    if signedDistance < planeClearance { return false }
                } else if signedDistance > -planeClearance {
                    return false
                }
            }
            return true
        }

        struct Candidate {
            var point: Vec2
            var phase: Double
            var sampleIndex: Int
        }

        func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
            let direct = abs(lhs - rhs)
            return min(direct, 1 - direct)
        }

        var uniqueOffsets: [Double] = []
        var seenOffsets = Set<Int64>()
        for offset in ringOffsets {
            let quantized = Int64((offset * 1_000).rounded())
            if seenOffsets.insert(quantized).inserted {
                uniqueOffsets.append(Double(quantized) / 1_000)
            }
        }

        let alternativeCount = max(48, count * 12)
        let sampleCount = max(192, count * 64)
        let basePhase = stablePhase(seed: seed, placementKey: placementKey)
        let minimumSpacing = 2 * boltRadius + 2.0
        var patterns: [[Vec2]] = []
        for ringOffset in uniqueOffsets {
            let ring = offsetConvexPolygon(hull, by: ringOffset)
            guard ring.count >= 3 else { continue }
            var lengths: [Double] = [0]
            for index in ring.indices {
                let point = ring[index]
                let next = ring[(index + 1) % ring.count]
                lengths.append(lengths[index] + hypot(next.x - point.x, next.y - point.y))
            }
            let total = lengths.last ?? 0
            guard total > 1.0e-6 else { continue }

            func pointAt(phase: Double) -> Vec2 {
                let wrapped = phase - floor(phase)
                let target = wrapped * total
                for index in ring.indices where lengths[index + 1] >= target {
                    let segment = lengths[index + 1] - lengths[index]
                    let fraction = segment > 1.0e-12
                        ? (target - lengths[index]) / segment
                        : 0
                    let point = ring[index]
                    let next = ring[(index + 1) % ring.count]
                    return Vec2(
                        x: point.x + (next.x - point.x) * fraction,
                        y: point.y + (next.y - point.y) * fraction
                    )
                }
                return ring[0]
            }

            let pool: [Candidate] = (0..<sampleCount).compactMap { sample in
                let phase = Double(sample) / Double(sampleCount)
                let point = pointAt(phase: phase)
                guard isSafe(point) else { return nil }
                return Candidate(point: point, phase: phase, sampleIndex: sample)
            }
            guard pool.count >= count else { continue }

            for alternative in 0..<alternativeCount {
                let phase = basePhase
                    + Double(alternative) / Double(alternativeCount * count)
                let candidateLists: [[Candidate]] = (0..<count).map { slot in
                    let target = phase + Double(slot) / Double(count)
                    let wrappedTarget = target - floor(target)
                    return Array(pool.sorted { lhs, rhs in
                        let leftDistance = circularDistance(lhs.phase, wrappedTarget)
                        let rightDistance = circularDistance(rhs.phase, wrappedTarget)
                        if abs(leftDistance - rightDistance) > 1.0e-12 {
                            return leftDistance < rightDistance
                        }
                        if abs(lhs.point.x - rhs.point.x) > 1.0e-9 {
                            return lhs.point.x < rhs.point.x
                        }
                        return lhs.point.y < rhs.point.y
                    }.prefix(48))
                }

                var chosen: [Candidate] = []
                var usedSamples = Set<Int>()
                func complete(_ slot: Int) -> Bool {
                    guard slot < count else { return true }
                    for candidate in candidateLists[slot] {
                        guard !usedSamples.contains(candidate.sampleIndex),
                              chosen.allSatisfy({ existing in
                                  hypot(
                                      existing.point.x - candidate.point.x,
                                      existing.point.y - candidate.point.y
                                  ) >= minimumSpacing
                              }) else { continue }
                        chosen.append(candidate)
                        usedSamples.insert(candidate.sampleIndex)
                        if complete(slot + 1) { return true }
                        usedSamples.remove(candidate.sampleIndex)
                        chosen.removeLast()
                    }
                    return false
                }
                if complete(0) {
                    let pattern = chosen.map(\.point)
                    if !patterns.contains(where: { existing in
                        guard existing.count == pattern.count else { return false }
                        return zip(existing, pattern).allSatisfy { pair in
                            let (lhs, rhs) = pair
                            return abs(lhs.x - rhs.x) <= 1.0e-6
                                && abs(lhs.y - rhs.y) <= 1.0e-6
                        }
                    }) {
                        patterns.append(pattern)
                    }
                }
            }
        }
        return patterns
    }

    private static func stablePhase(
        seed: Int,
        placementKey: StablePlacementKey
    ) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        hash ^= UInt64(bitPattern: Int64(seed))
        hash &*= 1_099_511_628_211
        for component in placementKey.components {
            hash ^= UInt64(bitPattern: component)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 1_000_003) / 1_000_003.0
    }

    // MARK: - Primitive geometry builders

    /// Build a cylinder as a triangle soup oriented along `axis` from `base`.
    /// `axis` is the full height vector. Outward-facing CCW winding.
    private static func cylinderTriSoup(base: Vec3, axis: Vec3, radius: Double, segments: Int) -> [(Vec3, Vec3, Vec3)] {
        let axLen = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        guard axLen > 1.0e-9, radius > 0, segments >= 3 else { return [] }
        let axN = scale(axis, 1.0 / axLen)
        let helper: Vec3 = abs(axN.x) < 0.9 ? Vec3(x: 1, y: 0, z: 0) : Vec3(x: 0, y: 1, z: 0)
        let sideA = normalizedVec(cross(axN, helper))
        let sideB = cross(axN, sideA)

        var bottomRing: [Vec3] = []
        var topRing: [Vec3] = []
        let top = add(base, axis)
        for i in 0..<segments {
            let theta = Double(i) / Double(segments) * 2 * Double.pi
            let r = add(scale(sideA, radius * cos(theta)), scale(sideB, radius * sin(theta)))
            bottomRing.append(add(base, r))
            topRing.append(add(top, r))
        }

        var tris: [(Vec3, Vec3, Vec3)] = []
        for i in 0..<segments {
            let j = (i + 1) % segments
            tris.append((bottomRing[i], bottomRing[j], topRing[j]))
            tris.append((bottomRing[i], topRing[j], topRing[i]))
            tris.append((base, bottomRing[j], bottomRing[i]))
            tris.append((top, topRing[i], topRing[j]))
        }
        return tris
    }

    /// Convert a flat triangle soup to `MeshGeometryData` (`ManifoldEngine.make`
    /// welds coincident vertices before construction).
    private static func triSoupToGeometry(_ tris: [(Vec3, Vec3, Vec3)]) -> MeshGeometryData {
        var verts: [Vec3] = []
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

    // MARK: - Part classification

    private static func partIsOnPositiveSide(_ part: MotherMoldPart, of plane: PartitionPlane) -> Bool {
        guard let c = areaWeightedCentroid(part.geometry) else { return true }
        return dot(c, plane.normal) - plane.offset >= 0
    }

    /// Classify parts by the SIGNED DISTANCE of their AREA-WEIGHTED centroid to
    /// the plane (not raw vertex-count majority, which is tessellation-sensitive
    /// and mis-assigns parts that straddle the seam).
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

    /// Area-weighted centroid of a triangle mesh (triangle centroids weighted by
    /// area). Returns nil for empty geometry; falls back to the vertex mean if
    /// all triangles are degenerate.
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
            let e1 = Vec3(x: vb.x - va.x, y: vb.y - va.y, z: vb.z - va.z)
            let e2 = Vec3(x: vc.x - va.x, y: vc.y - va.y, z: vc.z - va.z)
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
            var m = Vec3(x: 0, y: 0, z: 0)
            for v in verts { m = add(m, v) }
            let count = Double(verts.count)
            return Vec3(x: m.x / count, y: m.y / count, z: m.z / count)
        }
        return scale(sum, 1.0 / totalArea)
    }

    // MARK: - Vector helpers

    private static func fmt(_ v: Double) -> String { String(format: "%.0f", v) }

    private static func dot(_ a: Vec3, _ b: Vec3)     -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func add(_ a: Vec3, _ b: Vec3)     -> Vec3   { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func scale(_ a: Vec3, _ s: Double) -> Vec3   { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y,
             y: a.z * b.x - a.x * b.z,
             z: a.x * b.y - a.y * b.x)
    }
    private static func normalizedVec(_ a: Vec3) -> Vec3 {
        let len = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        guard len > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return scale(a, 1.0 / len)
    }

    private static func project(_ p: Vec3, origin: Vec3, u: Vec3, v: Vec3) -> Vec2 {
        let rel = Vec3(x: p.x - origin.x, y: p.y - origin.y, z: p.z - origin.z)
        return Vec2(x: dot(rel, u), y: dot(rel, v))
    }

    private static func planeBasis(_ n: Vec3) -> (u: Vec3, v: Vec3) {
        let helper: Vec3 = abs(n.x) < 0.9 ? Vec3(x: 1, y: 0, z: 0) : Vec3(x: 0, y: 1, z: 0)
        let u = normalizedVec(cross(helper, n))
        let v = cross(n, u)
        return (u, v)
    }
}
