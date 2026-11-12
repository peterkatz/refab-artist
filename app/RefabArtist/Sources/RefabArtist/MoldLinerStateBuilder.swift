import Foundation

/// A verified additive silicone volume present during the one-time liner pour.
/// This is intentionally distinct from a subtractive flow former and from a
/// trim operation so the resulting reference states preserve process meaning.
struct MoldLinerFillAdditiveVolume: Codable, Equatable {
    var id: String
    var purpose: String
    var solid: MeshGeometryData

    init(id: String, purpose: String, solid: MeshGeometryData) {
        self.id = id
        self.purpose = purpose
        self.solid = solid
    }
}

/// A permanent void used by repeated production casting. It is subtracted from
/// both reference states and must never be represented as a one-time trim.
enum MoldLinerPersistentVoidKind: String, Codable, Equatable {
    case productionGate
    case productionVent
}

struct MoldLinerPersistentVoid: Codable, Equatable {
    var id: String
    var kind: MoldLinerPersistentVoidKind
    var purpose: String
    var solid: MeshGeometryData

    init(id: String, kind: MoldLinerPersistentVoidKind, purpose: String, solid: MeshGeometryData) {
        self.id = id
        self.kind = kind
        self.purpose = purpose
        self.solid = solid
    }
}

/// A sacrificial liner-fill nub, liner-fill vent nub, or post flash removed
/// after cure. The concrete closed solid is the trim region shown in the guide.
struct MoldLinerTrimOperation: Codable, Equatable {
    var id: String
    var purpose: String
    var solid: MeshGeometryData

    init(id: String, purpose: String, solid: MeshGeometryData) {
        self.id = id
        self.purpose = purpose
        self.solid = solid
    }
}

enum MoldLinerProtectedPurpose: String, Codable, Equatable {
    case registration
    case gateLip
    case funnelSeal
    case productionGate
    case productionVent
}

/// Exact material that a liner trim may not consume. Production flow voids are
/// accompanied by their protected lip/seal material where that is the feature
/// at risk; a void alone has no silicone volume to protect.
struct MoldLinerProtectedRegion: Codable, Equatable {
    var id: String
    var purpose: MoldLinerProtectedPurpose
    var solid: MeshGeometryData

    init(id: String, purpose: MoldLinerProtectedPurpose, solid: MeshGeometryData) {
        self.id = id
        self.purpose = purpose
        self.solid = solid
    }
}

/// Inputs for the two exact reference-only silicone states. `cavitySolid` is
/// the closed pour envelope; `oneTimePourPositive` is the exact prepared master
/// or physical source occupied while silicone is poured.
struct MoldLinerStateInput: Equatable {
    var cavitySolid: MeshGeometryData
    var oneTimePourPositive: MeshGeometryData
    var verifiedLinerFillAdditives: [MoldLinerFillAdditiveVolume]
    var trimOperations: [MoldLinerTrimOperation]
    var persistentProductionVoids: [MoldLinerPersistentVoid]
    var protectedRegions: [MoldLinerProtectedRegion]
    var expectedComponentCount: Int

    init(
        cavitySolid: MeshGeometryData,
        oneTimePourPositive: MeshGeometryData,
        verifiedLinerFillAdditives: [MoldLinerFillAdditiveVolume] = [],
        trimOperations: [MoldLinerTrimOperation] = [],
        persistentProductionVoids: [MoldLinerPersistentVoid] = [],
        protectedRegions: [MoldLinerProtectedRegion] = [],
        expectedComponentCount: Int = 1
    ) {
        self.cavitySolid = cavitySolid
        self.oneTimePourPositive = oneTimePourPositive
        self.verifiedLinerFillAdditives = verifiedLinerFillAdditives
        self.trimOperations = trimOperations
        self.persistentProductionVoids = persistentProductionVoids
        self.protectedRegions = protectedRegions
        self.expectedComponentCount = expectedComponentCount
    }
}

struct MoldLinerTopologyMetrics: Codable, Equatable {
    var vertexCount: Int
    var triangleCount: Int
    var connectedComponentCount: Int
    var genus: Int
    var volumeCubicMillimeters: Double
    var isWatertight: Bool
    var hasFiniteCoordinates: Bool
    var bounds: ToolingBounds
}

struct MoldLinerTrimEvidence: Codable, Equatable {
    var id: String
    var purpose: String
    var bounds: ToolingBounds
    var requestedVolumeCubicMillimeters: Double
    var removedVolumeCubicMillimeters: Double
}

struct MoldLinerVolumeDeltas: Codable, Equatable {
    var cavityMinusPositiveCubicMillimeters: Double
    var verifiedAdditiveDeltaCubicMillimeters: Double
    var persistentVoidDeltaCubicMillimeters: Double
    var asPouredLinerCubicMillimeters: Double
    var trimDeltaCubicMillimeters: Double
    var productionLinerCubicMillimeters: Double
}

struct MoldLinerStateBuilderResult: Equatable {
    /// Always ordered AS-POURED LINER, PRODUCTION LINER and always reference-only.
    var referenceArtifacts: [ToolingArtifact]
    var trimMap: [MoldLinerTrimEvidence]
    var volumeDeltas: MoldLinerVolumeDeltas
    var asPouredTopology: MoldLinerTopologyMetrics
    var productionTopology: MoldLinerTopologyMetrics
    var diagnostics: [MoldDiagnostic]

    var asPouredLiner: ToolingArtifact { referenceArtifacts[0] }
    var productionLiner: ToolingArtifact { referenceArtifacts[1] }
}

enum MoldLinerStateBuilderError: Error, Equatable, LocalizedError {
    case invalidInput(String)
    case invalidSolid(String)
    case duplicateID(String)
    case protectedRegionIntersected(trimID: String, protectedID: String)
    case trimHasNoEffect(String)
    case trimDestroysLiner(String)
    case trimBreaksComponentContract(trimID: String, expected: Int, actual: Int)
    case productionEscapesAsPoured(Double)
    case referenceNormalizationFailed(String)
    case referenceNormalizationMateriallyAltered(label: String, symmetricDifference: Double)
    case normalizedTrimWasLost(Double)
    case normalizedNoTrimStatesDiverged(Double)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let reason):
            return "Invalid liner-state input: \(reason). Action: correct the declared reference geometry."
        case .invalidSolid(let label):
            return "\(label) must be finite, watertight, and have positive volume. Action: repair or replace that exact solid."
        case .duplicateID(let id):
            return "Liner-state ID \(id) is not unique. Action: assign stable unique IDs before generating the trim map."
        case .protectedRegionIntersected(let trimID, let protectedID):
            return "Trim \(trimID) intersects protected geometry \(protectedID). Action: move the trim guide away from registration or production-flow material."
        case .trimHasNoEffect(let id):
            return "Trim \(id) removes no liner material. Action: correct its exact trim volume or remove the stale trim instruction."
        case .trimDestroysLiner(let id):
            return "Trim \(id) destroys the liner. Action: reduce or relocate the trim volume."
        case .trimBreaksComponentContract(let trimID, let expected, let actual):
            return "Trim \(trimID) leaves \(actual) liner components; expected \(expected). Action: keep the liner connected."
        case .productionEscapesAsPoured(let volume):
            return "Production liner escapes the as-poured liner by \(volume) mm3. Action: inspect boolean inputs and trim ordering."
        case .referenceNormalizationFailed(let label):
            return "\(label) could not be normalized into strict serialized geometry. Action: correct the boolean inputs or remove the sliver-producing contact."
        case .referenceNormalizationMateriallyAltered(let label, let difference):
            return "\(label) normalization changed \(difference) mm3, exceeding the bounded repair allowance. Action: correct the source boolean contact instead of accepting altered liner geometry."
        case .normalizedTrimWasLost(let volume):
            return "Production-liner normalization lost the declared trim effect (\(volume) mm3). Action: correct the trim or sliver-producing contact."
        case .normalizedNoTrimStatesDiverged(let volume):
            return "AS-POURED and PRODUCTION LINER diverged by \(volume) mm3 despite no declared trim. Action: inspect normalization determinism and boolean inputs."
        }
    }
}

/// Builds exact, process-specific liner reference states using only Manifold
/// booleans. It never repairs, voxelizes, or substitutes bounding-box slabs for
/// an input solid; every operation retains the declared source geometry intact.
enum MoldLinerStateBuilder {
    static let containmentToleranceCubicMillimeters = 0.01
    /// The project permits repairs no larger than 0.05 mm. This stricter volume
    /// gate prevents that local repair from silently altering a liner reference.
    static let maximumNormalizationSymmetricDifferenceCubicMillimeters = 0.01
    private static let volumeToleranceCubicMillimeters = 1.0e-8

    static func build(_ input: MoldLinerStateInput) throws -> MoldLinerStateBuilderResult {
        guard input.expectedComponentCount > 0 else {
            throw MoldLinerStateBuilderError.invalidInput("expected component count must be positive")
        }
        try validateIDs(input.verifiedLinerFillAdditives.map(\.id))
        try validateIDs(input.trimOperations.map(\.id))
        try validateIDs(input.persistentProductionVoids.map(\.id))
        try validateIDs(input.protectedRegions.map(\.id))

        let cavity = try handle(for: input.cavitySolid, label: "closed cavity solid")
        let positive = try handle(for: input.oneTimePourPositive, label: "one-time pour positive")
        let baseLiner = try ManifoldEngine.difference(cavity, positive)
        let baseSnapshot = try snapshot(baseLiner, label: "cavity minus one-time pour positive", expectedComponents: input.expectedComponentCount)

        var afterAdditives = baseLiner
        for additive in input.verifiedLinerFillAdditives.sorted(by: stableOrder) {
            let additiveSolid = try handle(for: additive.solid, label: "liner-fill additive \(additive.id)")
            afterAdditives = try ManifoldEngine.union(afterAdditives, additiveSolid)
        }
        let additiveSnapshot = try snapshot(afterAdditives, label: "as-poured liner before persistent voids", expectedComponents: input.expectedComponentCount)

        var asPoured = afterAdditives
        for void in input.persistentProductionVoids.sorted(by: stableOrder) {
            let voidSolid = try handle(for: void.solid, label: "persistent \(void.kind.rawValue) void \(void.id)")
            asPoured = try ManifoldEngine.difference(asPoured, voidSolid)
        }
        let asPouredExactSnapshot = try snapshot(asPoured, label: "as-poured liner", expectedComponents: input.expectedComponentCount)

        let protectedSolids = try input.protectedRegions
            .sorted(by: stableOrder)
            .map { region in (region, try handle(for: region.solid, label: "protected \(region.purpose.rawValue) region \(region.id)")) }

        var production = asPoured
        var trimMap: [MoldLinerTrimEvidence] = []
        for trim in input.trimOperations.sorted(by: stableOrder) {
            let trimSolid = try handle(for: trim.solid, label: "trim volume \(trim.id)")
            for persistentVoid in input.persistentProductionVoids.sorted(by: stableOrder) {
                let voidSolid = try handle(
                    for: persistentVoid.solid,
                    label: "persistent \(persistentVoid.kind.rawValue) void \(persistentVoid.id)"
                )
                let overlap = try ManifoldEngine.intersect(trimSolid, voidSolid)
                if abs(ManifoldEngine.volume(overlap)) > volumeToleranceCubicMillimeters {
                    throw MoldLinerStateBuilderError.protectedRegionIntersected(
                        trimID: trim.id,
                        protectedID: persistentVoid.id
                    )
                }
            }
            for (protectedRegion, protectedSolid) in protectedSolids {
                let overlap = try ManifoldEngine.intersect(trimSolid, protectedSolid)
                if abs(ManifoldEngine.volume(overlap)) > volumeToleranceCubicMillimeters {
                    throw MoldLinerStateBuilderError.protectedRegionIntersected(
                        trimID: trim.id,
                        protectedID: protectedRegion.id
                    )
                }
            }

            let before = abs(ManifoldEngine.volume(production))
            let candidate = try ManifoldEngine.difference(production, trimSolid)
            let after = abs(ManifoldEngine.volume(candidate))
            let removed = before - after
            guard removed > volumeToleranceCubicMillimeters else {
                throw MoldLinerStateBuilderError.trimHasNoEffect(trim.id)
            }
            guard !ManifoldEngine.isEmpty(candidate), after > volumeToleranceCubicMillimeters else {
                throw MoldLinerStateBuilderError.trimDestroysLiner(trim.id)
            }

            let candidateSnapshot = try snapshot(candidate, label: "production liner after trim \(trim.id)", expectedComponents: nil)
            guard candidateSnapshot.metrics.connectedComponentCount == input.expectedComponentCount else {
                throw MoldLinerStateBuilderError.trimBreaksComponentContract(
                    trimID: trim.id,
                    expected: input.expectedComponentCount,
                    actual: candidateSnapshot.metrics.connectedComponentCount
                )
            }
            trimMap.append(MoldLinerTrimEvidence(
                id: trim.id,
                purpose: trim.purpose,
                bounds: bounds(of: trimSolid),
                requestedVolumeCubicMillimeters: abs(ManifoldEngine.volume(trimSolid)),
                removedVolumeCubicMillimeters: removed
            ))
            production = candidate
        }
        let productionExactSnapshot = try snapshot(production, label: "production liner", expectedComponents: input.expectedComponentCount)

        let escapedProduction = try ManifoldEngine.difference(production, asPoured)
        let escapedVolume = abs(ManifoldEngine.volume(escapedProduction))
        guard escapedVolume <= containmentToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.productionEscapesAsPoured(escapedVolume)
        }

        // Preserve exact boolean handles for process evidence; normalize only
        // the two serialized references through the established bounded path.
        let asPouredSnapshot = try normalizedReferenceSnapshot(
            asPoured,
            label: "AS-POURED LINER",
            expectedComponents: input.expectedComponentCount
        )
        let productionSnapshot = try normalizedReferenceSnapshot(
            production,
            label: "PRODUCTION LINER",
            expectedComponents: input.expectedComponentCount
        )
        try verifyNormalizedReferenceSemantics(
            asPoured: asPouredSnapshot,
            production: productionSnapshot,
            hasTrim: !trimMap.isEmpty
        )

        let artifacts = [
            ToolingArtifact(
                id: ToolingArtifactID("AS-POURED LINER"),
                name: "AS-POURED LINER",
                role: .referenceAsPouredLiner,
                geometry: asPouredSnapshot.geometry,
                qualification: .referenceOnly,
                materialHint: "silicone reference only"
            ),
            ToolingArtifact(
                id: ToolingArtifactID("PRODUCTION LINER"),
                name: "PRODUCTION LINER",
                role: .referenceProductionLiner,
                geometry: productionSnapshot.geometry,
                qualification: .referenceOnly,
                materialHint: "silicone reference only"
            ),
        ]

        let trimDelta = abs(ManifoldEngine.volume(asPoured)) - abs(ManifoldEngine.volume(production))
        var diagnostics = [
            MoldDiagnostic(
                .info,
                "AS-POURED LINER is an exact reference state with \(asPouredSnapshot.metrics.connectedComponentCount) component(s).",
                subsystem: .linerFill,
                code: MoldDiagnosticCode(rawValue: "liner.asPouredReference"),
                recoveryActions: [.reorientLinerFill]
            ),
            MoldDiagnostic(
                .info,
                "PRODUCTION LINER is contained in AS-POURED LINER within \(containmentToleranceCubicMillimeters) mm3.",
                subsystem: .productionCasting,
                code: MoldDiagnosticCode(rawValue: "liner.productionReference"),
                recoveryActions: [.reviewAssemblyGuide]
            ),
        ]
        if trimMap.isEmpty {
            diagnostics.append(MoldDiagnostic(
                .info,
                "No sacrificial liner trim is declared; AS-POURED LINER and PRODUCTION LINER intentionally match.",
                subsystem: .linerFill,
                code: MoldDiagnosticCode(rawValue: "liner.noTrimRequired"),
                recoveryActions: [.reviewAssemblyGuide]
            ))
        } else {
            diagnostics.append(MoldDiagnostic(
                .info,
                "Applied \(trimMap.count) deterministic one-time trim operation(s), removing \(trimDelta) mm3.",
                subsystem: .linerFill,
                code: MoldDiagnosticCode(rawValue: "liner.trimMapApplied"),
                recoveryActions: [.reviewAssemblyGuide]
            ))
        }

        return MoldLinerStateBuilderResult(
            referenceArtifacts: artifacts,
            trimMap: trimMap,
            volumeDeltas: MoldLinerVolumeDeltas(
                cavityMinusPositiveCubicMillimeters: baseSnapshot.metrics.volumeCubicMillimeters,
                verifiedAdditiveDeltaCubicMillimeters: additiveSnapshot.metrics.volumeCubicMillimeters - baseSnapshot.metrics.volumeCubicMillimeters,
                persistentVoidDeltaCubicMillimeters: additiveSnapshot.metrics.volumeCubicMillimeters - asPouredExactSnapshot.metrics.volumeCubicMillimeters,
                asPouredLinerCubicMillimeters: asPouredExactSnapshot.metrics.volumeCubicMillimeters,
                trimDeltaCubicMillimeters: trimDelta,
                productionLinerCubicMillimeters: productionExactSnapshot.metrics.volumeCubicMillimeters
            ),
            asPouredTopology: asPouredSnapshot.metrics,
            productionTopology: productionSnapshot.metrics,
            diagnostics: diagnostics
        )
    }

    private struct Snapshot {
        var geometry: MeshGeometryData
        var metrics: MoldLinerTopologyMetrics
        var solid: ManifoldHandle
    }

    private static func handle(for geometry: MeshGeometryData, label: String) throws -> ManifoldHandle {
        guard !geometry.vertices.isEmpty,
              geometry.triangleIndices.count >= 3,
              geometry.triangleIndices.count.isMultiple(of: 3),
              geometry.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              geometry.triangleIndices.allSatisfy({ geometry.vertices.indices.contains(Int($0)) }),
              MoldComponentFilter.signedVolume(geometry) > volumeToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.invalidSolid(label)
        }
        do {
            let solid = try ManifoldEngine.make(from: geometry)
            guard !ManifoldEngine.isEmpty(solid),
                  ManifoldEngine.isWatertight(solid),
                  ManifoldEngine.volume(solid) > volumeToleranceCubicMillimeters else {
                throw MoldLinerStateBuilderError.invalidSolid(label)
            }
            return solid
        } catch let error as MoldLinerStateBuilderError {
            throw error
        } catch {
            throw MoldLinerStateBuilderError.invalidSolid(label)
        }
    }

    private static func snapshot(
        _ solid: ManifoldHandle,
        label: String,
        expectedComponents: Int?
    ) throws -> Snapshot {
        guard !ManifoldEngine.isEmpty(solid),
              ManifoldEngine.isWatertight(solid),
              ManifoldEngine.volume(solid) > volumeToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.invalidSolid(label)
        }
        let geometry = try ManifoldEngine.toMesh(solid)
        guard geometry.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MoldLinerStateBuilderError.invalidSolid(label)
        }
        let componentCount = materialComponentCount(geometry)
        if let expectedComponents, componentCount != expectedComponents {
            throw MoldLinerStateBuilderError.invalidInput("\(label) has \(componentCount) components; expected \(expectedComponents)")
        }
        return Snapshot(
            geometry: geometry,
            metrics: MoldLinerTopologyMetrics(
                vertexCount: ManifoldEngine.vertexCount(solid),
                triangleCount: ManifoldEngine.triangleCount(solid),
                connectedComponentCount: componentCount,
                genus: ManifoldEngine.genus(solid),
                volumeCubicMillimeters: ManifoldEngine.volume(solid),
                isWatertight: ManifoldEngine.isWatertight(solid),
                hasFiniteCoordinates: true,
                bounds: bounds(of: solid)
            ),
            solid: solid
        )
    }

    private static func normalizedReferenceSnapshot(
        _ exactSolid: ManifoldHandle,
        label: String,
        expectedComponents: Int
    ) throws -> Snapshot {
        let exactGeometry = try ManifoldEngine.toMesh(exactSolid)
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: label,
            geometry: exactGeometry
        )])
        guard validation.allPartsWatertight,
              let normalizedPart = validation.parts.first,
              MeshPreflight.analyze(geometry: normalizedPart.geometry).isWatertight else {
            throw MoldLinerStateBuilderError.referenceNormalizationFailed(label)
        }

        let normalizedSolid: ManifoldHandle
        do {
            normalizedSolid = try ManifoldEngine.make(from: normalizedPart.geometry)
        } catch {
            throw MoldLinerStateBuilderError.referenceNormalizationFailed(label)
        }
        guard !ManifoldEngine.isEmpty(normalizedSolid),
              ManifoldEngine.isWatertight(normalizedSolid),
              ManifoldEngine.volume(normalizedSolid) > volumeToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.referenceNormalizationFailed(label)
        }
        let difference = try symmetricDifferenceVolume(exactSolid, normalizedSolid)
        guard difference <= maximumNormalizationSymmetricDifferenceCubicMillimeters else {
            let preflight = MeshPreflight.analyze(geometry: exactGeometry)
            let normalization = validation.diagnostics.map(\.message).joined(separator: " ")
            throw MoldLinerStateBuilderError.referenceNormalizationMateriallyAltered(
                label: "\(label) [boundary \(preflight.boundaryEdgeCount), non-manifold \(preflight.nonManifoldEdgeCount), degenerate \(preflight.degenerateTriangleCount); \(normalization)]",
                symmetricDifference: difference
            )
        }
        var result = try snapshot(
            normalizedSolid,
            label: label,
            expectedComponents: expectedComponents
        )
        // `normalizedPart.geometry` is the independently preflighted serialized
        // representation. Converting its Manifold handle back to a mesh can
        // recreate the exact positional sliver that normalization separated.
        result.geometry = normalizedPart.geometry
        result.metrics.vertexCount = normalizedPart.geometry.vertices.count
        result.metrics.triangleCount = normalizedPart.geometry.triangleIndices.count / 3
        return result
    }

    private static func verifyNormalizedReferenceSemantics(
        asPoured: Snapshot,
        production: Snapshot,
        hasTrim: Bool
    ) throws {
        let escaped = try ManifoldEngine.difference(production.solid, asPoured.solid)
        let escapedVolume = abs(ManifoldEngine.volume(escaped))
        guard escapedVolume <= containmentToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.productionEscapesAsPoured(escapedVolume)
        }
        guard !hasTrim || production.metrics.volumeCubicMillimeters
            < asPoured.metrics.volumeCubicMillimeters - volumeToleranceCubicMillimeters else {
            throw MoldLinerStateBuilderError.normalizedTrimWasLost(
                asPoured.metrics.volumeCubicMillimeters - production.metrics.volumeCubicMillimeters
            )
        }
        if !hasTrim {
            let difference = try symmetricDifferenceVolume(asPoured.solid, production.solid)
            guard difference <= containmentToleranceCubicMillimeters else {
                throw MoldLinerStateBuilderError.normalizedNoTrimStatesDiverged(difference)
            }
        }
    }

    static func requireSafeNormalization(
        exact: ManifoldHandle,
        normalized: ManifoldHandle,
        label: String
    ) throws {
        let difference = try symmetricDifferenceVolume(exact, normalized)
        guard difference <= maximumNormalizationSymmetricDifferenceCubicMillimeters else {
            throw MoldLinerStateBuilderError.referenceNormalizationMateriallyAltered(
                label: label,
                symmetricDifference: difference
            )
        }
    }

    static func symmetricDifferenceVolume(
        _ lhs: ManifoldHandle,
        _ rhs: ManifoldHandle
    ) throws -> Double {
        let lhsOnly = try ManifoldEngine.difference(lhs, rhs)
        let rhsOnly = try ManifoldEngine.difference(rhs, lhs)
        defer {
            withExtendedLifetime(lhsOnly) {}
            withExtendedLifetime(rhsOnly) {}
        }
        return abs(ManifoldEngine.volume(lhsOnly)) + abs(ManifoldEngine.volume(rhsOnly))
    }

    private static func bounds(of solid: ManifoldHandle) -> ToolingBounds {
        let box = ManifoldEngine.bounds(solid)
        return ToolingBounds(
            minimum: Vec3Codable(x: box.min.x, y: box.min.y, z: box.min.z),
            maximum: Vec3Codable(x: box.max.x, y: box.max.y, z: box.max.z)
        )
    }

    private static func validateIDs(_ ids: [String]) throws {
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MoldLinerStateBuilderError.invalidInput("every declared additive, void, trim, and protected region needs a stable ID")
        }
        guard Set(ids).count == ids.count else {
            throw MoldLinerStateBuilderError.duplicateID(ids.sorted().first(where: { id in ids.filter { $0 == id }.count > 1 }) ?? "unknown")
        }
    }

    private static func stableOrder<T>(_ lhs: T, _ rhs: T) -> Bool where T: IdentifiedLinerVolume {
        lhs.id < rhs.id
    }

    /// A hollow liner has one positive outer boundary and one or more negative
    /// cavity boundaries. Surface-island counting therefore overstates physical
    /// liners; count only positive closed boundary shells after deterministic
    /// triangle connectivity instead.
    private static func materialComponentCount(_ geometry: MeshGeometryData) -> Int {
        MoldComponentFilter.positiveMaterialComponentCount(
            geometry,
            volumeTolerance: volumeToleranceCubicMillimeters
        )
    }
}

private protocol IdentifiedLinerVolume {
    var id: String { get }
}

extension MoldLinerFillAdditiveVolume: IdentifiedLinerVolume {}
extension MoldLinerPersistentVoid: IdentifiedLinerVolume {}
extension MoldLinerTrimOperation: IdentifiedLinerVolume {}
extension MoldLinerProtectedRegion: IdentifiedLinerVolume {}
