import Foundation

/// Exact, feature-by-feature geometry protection for reusable tooling stages.
/// A feature is never credited by a combined volume: each record measures its
/// own additive material or subtractive void against the final owned geometry.
struct ProtectedToolingAuditSet: Equatable {
    static let minimumMeasurableVolumeMM3 = 1.0e-6

    enum SemanticKind: String, Codable, CaseIterable, Sendable {
        case preparedPost
        case postReceiver
        case collar
        case sealLand
        case linerHousing
        case linerRecess
        case linerFillPath
        case linerVentPath
        case productionGate
        case productionVentLanding
        case productionVentSleeve
        case castingFunnelReceiver
        case flange
        case flangeBoltBore
        case shellKeyBoss
        case shellKeyPocket
    }

    enum Behavior: String, Codable, Sendable {
        case additive
        case subtractive
    }

    enum Ownership: Equatable, Codable, Sendable {
        /// Feature is measured over the final assembly. Use only where no one
        /// rigid shell part owns the feature (for example, a through-bore).
        case assembly
        case singlePart(String)
        case parts([String])

        var requiredPartNames: [String] {
            switch self {
            case .assembly: []
            case .singlePart(let name): [name]
            case .parts(let names): names
            }
        }
    }

    enum Stage: String, Codable, CaseIterable, Comparable, Sendable {
        case fixture
        case linerRegistration
        case flow
        case flange
        case key
        case finalNormalization

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Record: Equatable, Sendable {
        var id: String
        var kind: SemanticKind
        var behavior: Behavior
        var ownership: Ownership
        var geometry: MeshGeometryData
        /// Additive material that must remain in the owned final part(s).
        var requiredRetention: Double
        /// Subtractive void that must remain unoccupied in the final assembly.
        var requiredClearance: Double?
        var provenance: Set<Stage>

        init(
            id: String,
            kind: SemanticKind,
            behavior: Behavior,
            ownership: Ownership,
            geometry: MeshGeometryData,
            requiredRetention: Double = 0.98,
            requiredClearance: Double? = nil,
            provenance: Set<Stage>
        ) {
            self.id = id
            self.kind = kind
            self.behavior = behavior
            self.ownership = ownership
            self.geometry = geometry
            self.requiredRetention = requiredRetention
            self.requiredClearance = requiredClearance
            self.provenance = provenance
        }
    }

    struct Evidence: Equatable, Sendable {
        var id: String
        var kind: SemanticKind
        var behavior: Behavior
        var ownership: Ownership
        var stage: Stage
        var baselineVolumeMM3: Double
        var finalRetainedVolumeMM3: Double?
        var finalVoidVolumeMM3: Double?
        var finalVoidFraction: Double?
        var retainedFraction: Double
        var passes: Bool
        var failure: String?
    }

    struct AuditResult: Equatable, Sendable {
        var evidence: [Evidence]
        var diagnostics: [String]

        var passes: Bool { evidence.allSatisfy(\.passes) }
    }

    enum Error: LocalizedError, Equatable {
        case duplicateID(String)
        case invalidID(String)
        case invalidOwnership(String)
        case invalidRequirement(String)
        case invalidGeometry(String)

        var errorDescription: String? {
            switch self {
            case .duplicateID(let id):
                "Protected tooling audit has duplicate feature id '\(id)'. Every protected feature needs one stable unique id."
            case .invalidID(let id):
                "Protected tooling audit feature id '\(id)' is empty or unstable."
            case .invalidOwnership(let id):
                "Protected tooling audit feature '\(id)' has no valid owning shell part."
            case .invalidRequirement(let id):
                "Protected tooling audit feature '\(id)' has an invalid retention or clearance requirement."
            case .invalidGeometry(let id):
                "Protected tooling audit feature '\(id)' is not a finite, non-empty watertight solid."
            }
        }
    }

    let records: [Record]

    init(records: [Record]) throws {
        var ids = Set<String>()
        for record in records {
            let normalizedID = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, normalizedID == record.id else {
                throw Error.invalidID(record.id)
            }
            guard ids.insert(record.id).inserted else { throw Error.duplicateID(record.id) }
            guard !record.provenance.isEmpty,
                  record.requiredRetention.isFinite,
                  record.requiredRetention >= 0,
                  record.requiredRetention <= 1,
                  record.requiredClearance.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true,
                  record.behavior == .additive || record.requiredClearance != nil else {
                throw Error.invalidRequirement(record.id)
            }
            let owners = record.ownership.requiredPartNames
            guard record.ownership == .assembly || (!owners.isEmpty && Set(owners).count == owners.count && owners.allSatisfy { !$0.isEmpty }) else {
                throw Error.invalidOwnership(record.id)
            }
            guard Self.isSolid(record.geometry) else { throw Error.invalidGeometry(record.id) }
        }
        self.records = records.sorted { $0.id < $1.id }
    }

    func appending(_ additional: [Record]) throws -> ProtectedToolingAuditSet {
        try ProtectedToolingAuditSet(records: records + additional)
    }

    /// Re-baselines additive witnesses only where an exact, measured flow cut
    /// removed material. The cut records remain in the set as protected voids,
    /// so later stages must preserve both the surviving material and each port.
    func authorizingSubtractiveCuts(_ cuts: [Record]) throws -> ProtectedToolingAuditSet {
        guard cuts.allSatisfy({ $0.behavior == .subtractive }) else {
            throw Error.invalidRequirement("authorized-cut-set")
        }
        guard !cuts.isEmpty else { return self }

        var rebased: [Record] = []
        rebased.reserveCapacity(records.count + cuts.count)
        for record in records {
            guard record.behavior == .additive else {
                rebased.append(record)
                continue
            }
            var retained = try ManifoldEngine.make(from: record.geometry)
            for cut in cuts {
                retained = try ManifoldEngine.difference(
                    retained,
                    try ManifoldEngine.make(from: cut.geometry)
                )
            }
            guard !ManifoldEngine.isEmpty(retained),
                  ManifoldEngine.isWatertight(retained),
                  abs(ManifoldEngine.volume(retained)) > Self.minimumMeasurableVolumeMM3 else {
                throw Error.invalidGeometry(record.id)
            }
            var updated = record
            updated.geometry = try Self.normalizedWitness(
                try ManifoldEngine.toMesh(retained),
                id: record.id
            )
            updated.provenance.insert(.flow)
            rebased.append(updated)
        }
        return try ProtectedToolingAuditSet(records: rebased + cuts)
    }

    /// Measures every record independently. Additive evidence intersects only
    /// its owned parts. Subtractive evidence also measures its owned part(s),
    /// unless it is explicitly assembly-owned (a through-bore); this keeps a
    /// mating key boss from being mistaken for material blocking its receiver.
    func audit(finalParts: [MotherMoldPart], stage: Stage) -> AuditResult {
        let partsByName = Dictionary(grouping: finalParts, by: \.name)
        var evidence: [Evidence] = []
        var diagnostics: [String] = []
        evidence.reserveCapacity(records.count)

        for record in records {
            let baseline: Double
            do {
                baseline = try Self.solidVolume(record.geometry)
            } catch {
                let failure = "Protected feature '\(record.id)' could not be remeasured at \(stage.rawValue): \(error). Rebuild the tooling stage."
                evidence.append(Evidence(
                    id: record.id, kind: record.kind, behavior: record.behavior,
                    ownership: record.ownership, stage: stage, baselineVolumeMM3: 0,
                    finalRetainedVolumeMM3: nil, finalVoidVolumeMM3: nil,
                    finalVoidFraction: nil, retainedFraction: 0, passes: false, failure: failure
                ))
                diagnostics.append(failure)
                continue
            }

            let missingOwners = record.ownership.requiredPartNames.filter { partsByName[$0] == nil }
            guard missingOwners.isEmpty else {
                let failure = "Protected feature '\(record.id)' ownership is missing final part(s): \(missingOwners.sorted().joined(separator: ", ")). Rebuild the owning tooling component."
                evidence.append(Evidence(
                    id: record.id, kind: record.kind, behavior: record.behavior,
                    ownership: record.ownership, stage: stage, baselineVolumeMM3: baseline,
                    finalRetainedVolumeMM3: nil, finalVoidVolumeMM3: nil,
                    finalVoidFraction: nil, retainedFraction: 0, passes: false, failure: failure
                ))
                diagnostics.append(failure)
                continue
            }

            let ownedParts: [MotherMoldPart]
            switch record.ownership {
            case .assembly:
                ownedParts = finalParts
            case .singlePart(let name):
                ownedParts = partsByName[name] ?? []
            case .parts(let names):
                ownedParts = names.flatMap { partsByName[$0] ?? [] }
            }

            do {
                switch record.behavior {
                case .additive:
                    let retained = try Self.intersectionVolume(record.geometry, with: ownedParts)
                    let fraction = min(1, retained / baseline)
                    let passes = fraction + 1.0e-9 >= record.requiredRetention
                    let failure = passes ? nil : String(
                        format: "Protected additive '%@' retained %.2f%% of %.6f mm3 (required %.2f%%) after %@. Restore the owned %@ geometry before continuing.",
                        record.id, fraction * 100, baseline, record.requiredRetention * 100,
                        stage.rawValue, record.kind.rawValue
                    )
                    evidence.append(Evidence(
                        id: record.id, kind: record.kind, behavior: record.behavior,
                        ownership: record.ownership, stage: stage, baselineVolumeMM3: baseline,
                        finalRetainedVolumeMM3: retained, finalVoidVolumeMM3: nil,
                        finalVoidFraction: nil, retainedFraction: fraction,
                        passes: passes, failure: failure
                    ))
                    if let failure { diagnostics.append(failure) }
                case .subtractive:
                    let occupancyParts: [MotherMoldPart]
                    if record.ownership == .assembly {
                        occupancyParts = finalParts
                    } else {
                        occupancyParts = ownedParts
                    }
                    let occupied = try Self.intersectionVolume(record.geometry, with: occupancyParts)
                    let voidVolume = max(0, baseline - occupied)
                    let voidFraction = min(1, voidVolume / baseline)
                    let required = record.requiredClearance ?? record.requiredRetention
                    let passes = voidFraction + 1.0e-9 >= required
                    let failure = passes ? nil : String(
                        format: "Protected void '%@' is %.2f%% clear (%.6f mm3 occupied of %.6f mm3) after %@; required %.2f%%. Remove the blocking %@ material.",
                        record.id, voidFraction * 100, occupied, baseline,
                        stage.rawValue, required * 100, record.kind.rawValue
                    )
                    evidence.append(Evidence(
                        id: record.id, kind: record.kind, behavior: record.behavior,
                        ownership: record.ownership, stage: stage, baselineVolumeMM3: baseline,
                        finalRetainedVolumeMM3: nil, finalVoidVolumeMM3: voidVolume,
                        finalVoidFraction: voidFraction, retainedFraction: voidFraction,
                        passes: passes, failure: failure
                    ))
                    if let failure { diagnostics.append(failure) }
                }
            } catch {
                let failure = "Protected feature '\(record.id)' could not be measured after \(stage.rawValue): \(error). Roll back this tooling transaction."
                evidence.append(Evidence(
                    id: record.id, kind: record.kind, behavior: record.behavior,
                    ownership: record.ownership, stage: stage, baselineVolumeMM3: baseline,
                    finalRetainedVolumeMM3: nil, finalVoidVolumeMM3: nil,
                    finalVoidFraction: nil, retainedFraction: 0, passes: false, failure: failure
                ))
                diagnostics.append(failure)
            }
        }
        return AuditResult(evidence: evidence, diagnostics: diagnostics)
    }

    private static func isSolid(_ geometry: MeshGeometryData) -> Bool {
        guard MotherMoldValidation.hasFiniteCoordinates(geometry),
              MotherMoldValidation.surfaceClosure(geometry).closed,
              let handle = try? ManifoldEngine.make(from: geometry),
              ManifoldEngine.isWatertight(handle),
              abs(ManifoldEngine.volume(handle)) > minimumMeasurableVolumeMM3 else {
            return false
        }
        withExtendedLifetime(handle) {}
        return true
    }

    private static func normalizedWitness(
        _ geometry: MeshGeometryData,
        id: String
    ) throws -> MeshGeometryData {
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: id,
            geometry: geometry
        )])
        guard validation.allPartsWatertight,
              let normalized = validation.parts.first,
              MeshPreflight.analyze(geometry: normalized.geometry).isWatertight else {
            throw Error.invalidGeometry(id)
        }
        return normalized.geometry
    }

    private static func solidVolume(_ geometry: MeshGeometryData) throws -> Double {
        let handle = try ManifoldEngine.make(from: geometry)
        defer { withExtendedLifetime(handle) {} }
        let volume = abs(ManifoldEngine.volume(handle))
        guard volume > minimumMeasurableVolumeMM3 else { throw Error.invalidGeometry("measurement") }
        return volume
    }

    private static func intersectionVolume(_ geometry: MeshGeometryData, with parts: [MotherMoldPart]) throws -> Double {
        let feature = try ManifoldEngine.make(from: geometry)
        defer { withExtendedLifetime(feature) {} }
        var total = 0.0
        for part in parts {
            let partHandle = try ManifoldEngine.make(from: part.geometry)
            let intersection = try ManifoldEngine.intersect(feature, partHandle)
            total += abs(ManifoldEngine.volume(intersection))
            withExtendedLifetime(partHandle) {}
            withExtendedLifetime(intersection) {}
        }
        return total
    }
}
