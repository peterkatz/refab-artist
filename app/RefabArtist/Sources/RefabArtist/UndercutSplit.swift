import Foundation

enum PartitionPurpose: String, Codable, CaseIterable, Identifiable {
    case fitPrinter
    case splitByUndercuts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitPrinter: return "Fit Printer"
        case .splitByUndercuts: return "Split by Undercuts"
        }
    }
}

enum UndercutPlanningMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case manual

    var id: String { rawValue }
}

enum PullDirectionPolicy: String, Codable, CaseIterable, Identifiable {
    case automatic
    case fixed
    case perPieceLocks

    var id: String { rawValue }
}

enum UndercutSearchQuality: String, Codable, CaseIterable, Identifiable {
    case quick
    case standard
    case thorough

    var id: String { rawValue }
}

enum UndercutSplitPriority: String, Codable, CaseIterable, Identifiable {
    case fewerPieces
    case balanced
    case cleanerSeams

    var id: String { rawValue }
}

/// Versioned geometric coincidence thresholds shared by analysis, replay, and
/// source-fidelity checks. The user's undercut acceptance tolerance is not in
/// this policy; it remains the single user-facing acceptance criterion.
struct UndercutSplitTolerancePolicy: Codable, Equatable {
    let version: Int
    let linearWeldMM: Double
    let rayHitCoincidenceMM: Double
    let angularRadians: Double
    let minimumTriangleAreaMM2: Double
    let absoluteVolumeMM3: Double
    let relativeVolumeFraction: Double

    static let current = UndercutSplitTolerancePolicy(
        version: 1,
        linearWeldMM: 1.0e-6,
        rayHitCoincidenceMM: 1.0e-7,
        angularRadians: 1.0e-8,
        minimumTriangleAreaMM2: 1.0e-12,
        absoluteVolumeMM3: 1.0e-6,
        relativeVolumeFraction: 1.0e-8
    )
}

struct PreferredSeamFace: Codable, Equatable, Hashable {
    var sourceFaceID: SourceFaceID
    var weight: Double
}

struct PartitionFaceConstraints: Codable, Equatable {
    var noCutSourceFaceIDs: [SourceFaceID]
    var preferredSeamFaces: [PreferredSeamFace]

    static let empty = PartitionFaceConstraints(
        noCutSourceFaceIDs: [],
        preferredSeamFaces: []
    )

    init(
        noCutSourceFaceIDs: [SourceFaceID],
        preferredSeamFaces: [PreferredSeamFace]
    ) {
        self.noCutSourceFaceIDs = noCutSourceFaceIDs
        self.preferredSeamFaces = preferredSeamFaces
    }

    private enum CodingKeys: String, CodingKey {
        case noCutSourceFaceIDs
        case preferredSeamFaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noCutSourceFaceIDs = try container.decodeIfPresent(
            [SourceFaceID].self,
            forKey: .noCutSourceFaceIDs
        ) ?? []
        preferredSeamFaces = try container.decodeIfPresent(
            [PreferredSeamFace].self,
            forKey: .preferredSeamFaces
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noCutSourceFaceIDs, forKey: .noCutSourceFaceIDs)
        try container.encode(preferredSeamFaces, forKey: .preferredSeamFaces)
    }

    var sanitized: PartitionFaceConstraints {
        let noCut = Array(Set(noCutSourceFaceIDs)).sorted()
        var preferredByFace: [SourceFaceID: Double] = [:]
        for entry in preferredSeamFaces where entry.weight.isFinite {
            preferredByFace[entry.sourceFaceID] = min(max(entry.weight, 0), 1)
        }
        return PartitionFaceConstraints(
            noCutSourceFaceIDs: noCut,
            preferredSeamFaces: preferredByFace
                .map { PreferredSeamFace(sourceFaceID: $0.key, weight: $0.value) }
                .sorted { $0.sourceFaceID < $1.sourceFaceID }
        )
    }
}

enum UndercutSeamKeySettings: Codable, Equatable {
    case none
    case pins(PartitionKeySettings)

    private enum CodingKeys: String, CodingKey {
        case type
        case settings
    }

    private enum Kind: String, Codable {
        case none
        case pins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .type) ?? .none {
        case .none:
            self = .none
        case .pins:
            var settings = try container.decodeIfPresent(PartitionKeySettings.self, forKey: .settings)
                ?? .defaultValue
            settings.type = .pins
            self = .pins(settings.sanitized)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .type)
        case .pins(let settings):
            try container.encode(Kind.pins, forKey: .type)
            var pins = settings
            pins.type = .pins
            try container.encode(pins, forKey: .settings)
        }
    }

    var sanitized: UndercutSeamKeySettings {
        switch self {
        case .none:
            return .none
        case .pins(var settings):
            settings.type = .pins
            return .pins(settings.sanitized)
        }
    }
}

struct UndercutSplitSettings: Codable, Equatable {
    var planningMode: UndercutPlanningMode
    var pullPolicy: PullDirectionPolicy
    var fixedPullDirection: Vec3?
    var undercutToleranceMM: Double
    var minRegionAreaMM2: Double
    var quality: UndercutSearchQuality
    var maxPieces: Int
    var priority: UndercutSplitPriority
    var draftAdvisoryDegrees: Double
    var minimumPieceVolumeFraction: Double
    var minimumPieceVolumeMM3: Double
    var minimumSeamAreaMM2: Double
    var seamKeys: UndercutSeamKeySettings
    var faceConstraints: PartitionFaceConstraints
    var lockedPullDirections: [PartitionRegionID: Vec3]
    var authoredCutTree: PersistedCutTreeEnvelope?
    var seed: Int64
    var plannerVersion: Int
    var tolerancePolicyVersion: Int

    static let defaultValue = UndercutSplitSettings(
        planningMode: .automatic,
        pullPolicy: .automatic,
        fixedPullDirection: nil,
        undercutToleranceMM: 2,
        minRegionAreaMM2: 4,
        quality: .standard,
        maxPieces: 8,
        priority: .balanced,
        draftAdvisoryDegrees: 1,
        minimumPieceVolumeFraction: 0.005,
        minimumPieceVolumeMM3: 1,
        minimumSeamAreaMM2: 4,
        seamKeys: .none,
        faceConstraints: .empty,
        lockedPullDirections: [:],
        authoredCutTree: nil,
        seed: 0,
        plannerVersion: 1,
        tolerancePolicyVersion: UndercutSplitTolerancePolicy.current.version
    )

    var sanitized: UndercutSplitSettings {
        var copy = self
        copy.fixedPullDirection = Self.unitDirection(fixedPullDirection)
        copy.undercutToleranceMM = Self.clamp(undercutToleranceMM, 0, 10, fallback: 2)
        copy.minRegionAreaMM2 = Self.clamp(minRegionAreaMM2, 0, 100, fallback: 4)
        copy.maxPieces = min(max(maxPieces, 1), 32)
        copy.draftAdvisoryDegrees = Self.clamp(draftAdvisoryDegrees, 0, 10, fallback: 1)
        copy.minimumPieceVolumeFraction = Self.clamp(minimumPieceVolumeFraction, 0, 0.1, fallback: 0.005)
        copy.minimumPieceVolumeMM3 = Self.nonnegative(minimumPieceVolumeMM3, fallback: 1)
        copy.minimumSeamAreaMM2 = Self.nonnegative(minimumSeamAreaMM2, fallback: 4)
        copy.seamKeys = seamKeys.sanitized
        copy.faceConstraints = faceConstraints.sanitized
        copy.lockedPullDirections = Dictionary(
            uniqueKeysWithValues: lockedPullDirections.compactMap { regionID, direction in
                Self.unitDirection(direction).map { (regionID, $0) }
            }
        )
        copy.plannerVersion = max(plannerVersion, 1)
        copy.tolerancePolicyVersion = max(tolerancePolicyVersion, 1)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case planningMode
        case pullPolicy
        case fixedPullDirection
        case undercutToleranceMM
        case minRegionAreaMM2
        case quality
        case maxPieces
        case priority
        case draftAdvisoryDegrees
        case minimumPieceVolumeFraction
        case minimumPieceVolumeMM3
        case minimumSeamAreaMM2
        case seamKeys
        case faceConstraints
        case lockedPullDirections
        case authoredCutTree
        case seed
        case plannerVersion
        case tolerancePolicyVersion
    }

    init(
        planningMode: UndercutPlanningMode,
        pullPolicy: PullDirectionPolicy,
        fixedPullDirection: Vec3?,
        undercutToleranceMM: Double,
        minRegionAreaMM2: Double,
        quality: UndercutSearchQuality,
        maxPieces: Int,
        priority: UndercutSplitPriority,
        draftAdvisoryDegrees: Double,
        minimumPieceVolumeFraction: Double,
        minimumPieceVolumeMM3: Double,
        minimumSeamAreaMM2: Double,
        seamKeys: UndercutSeamKeySettings,
        faceConstraints: PartitionFaceConstraints,
        lockedPullDirections: [PartitionRegionID: Vec3],
        authoredCutTree: PersistedCutTreeEnvelope?,
        seed: Int64,
        plannerVersion: Int,
        tolerancePolicyVersion: Int
    ) {
        self.planningMode = planningMode
        self.pullPolicy = pullPolicy
        self.fixedPullDirection = fixedPullDirection
        self.undercutToleranceMM = undercutToleranceMM
        self.minRegionAreaMM2 = minRegionAreaMM2
        self.quality = quality
        self.maxPieces = maxPieces
        self.priority = priority
        self.draftAdvisoryDegrees = draftAdvisoryDegrees
        self.minimumPieceVolumeFraction = minimumPieceVolumeFraction
        self.minimumPieceVolumeMM3 = minimumPieceVolumeMM3
        self.minimumSeamAreaMM2 = minimumSeamAreaMM2
        self.seamKeys = seamKeys
        self.faceConstraints = faceConstraints
        self.lockedPullDirections = lockedPullDirections
        self.authoredCutTree = authoredCutTree
        self.seed = seed
        self.plannerVersion = plannerVersion
        self.tolerancePolicyVersion = tolerancePolicyVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaultValue
        planningMode = try container.decodeIfPresent(UndercutPlanningMode.self, forKey: .planningMode) ?? fallback.planningMode
        pullPolicy = try container.decodeIfPresent(PullDirectionPolicy.self, forKey: .pullPolicy) ?? fallback.pullPolicy
        fixedPullDirection = try container.decodeIfPresent(Vec3.self, forKey: .fixedPullDirection)
        undercutToleranceMM = try container.decodeIfPresent(Double.self, forKey: .undercutToleranceMM) ?? fallback.undercutToleranceMM
        minRegionAreaMM2 = try container.decodeIfPresent(Double.self, forKey: .minRegionAreaMM2) ?? fallback.minRegionAreaMM2
        quality = try container.decodeIfPresent(UndercutSearchQuality.self, forKey: .quality) ?? fallback.quality
        maxPieces = try container.decodeIfPresent(Int.self, forKey: .maxPieces) ?? fallback.maxPieces
        priority = try container.decodeIfPresent(UndercutSplitPriority.self, forKey: .priority) ?? fallback.priority
        draftAdvisoryDegrees = try container.decodeIfPresent(Double.self, forKey: .draftAdvisoryDegrees) ?? fallback.draftAdvisoryDegrees
        minimumPieceVolumeFraction = try container.decodeIfPresent(Double.self, forKey: .minimumPieceVolumeFraction) ?? fallback.minimumPieceVolumeFraction
        minimumPieceVolumeMM3 = try container.decodeIfPresent(Double.self, forKey: .minimumPieceVolumeMM3) ?? fallback.minimumPieceVolumeMM3
        minimumSeamAreaMM2 = try container.decodeIfPresent(Double.self, forKey: .minimumSeamAreaMM2) ?? fallback.minimumSeamAreaMM2
        seamKeys = try container.decodeIfPresent(UndercutSeamKeySettings.self, forKey: .seamKeys) ?? fallback.seamKeys
        faceConstraints = try container.decodeIfPresent(PartitionFaceConstraints.self, forKey: .faceConstraints) ?? fallback.faceConstraints
        if let records = try? container.decode([PullLockRecord].self, forKey: .lockedPullDirections) {
            lockedPullDirections = Dictionary(
                records.map { ($0.regionID, $0.direction) },
                uniquingKeysWith: { _, latest in latest }
            )
        } else {
            lockedPullDirections = try container.decodeIfPresent([PartitionRegionID: Vec3].self, forKey: .lockedPullDirections) ?? fallback.lockedPullDirections
        }
        authoredCutTree = try container.decodeIfPresent(PersistedCutTreeEnvelope.self, forKey: .authoredCutTree)
        seed = try container.decodeIfPresent(Int64.self, forKey: .seed) ?? fallback.seed
        plannerVersion = try container.decodeIfPresent(Int.self, forKey: .plannerVersion) ?? fallback.plannerVersion
        tolerancePolicyVersion = try container.decodeIfPresent(Int.self, forKey: .tolerancePolicyVersion) ?? fallback.tolerancePolicyVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planningMode, forKey: .planningMode)
        try container.encode(pullPolicy, forKey: .pullPolicy)
        try container.encodeIfPresent(fixedPullDirection, forKey: .fixedPullDirection)
        try container.encode(undercutToleranceMM, forKey: .undercutToleranceMM)
        try container.encode(minRegionAreaMM2, forKey: .minRegionAreaMM2)
        try container.encode(quality, forKey: .quality)
        try container.encode(maxPieces, forKey: .maxPieces)
        try container.encode(priority, forKey: .priority)
        try container.encode(draftAdvisoryDegrees, forKey: .draftAdvisoryDegrees)
        try container.encode(minimumPieceVolumeFraction, forKey: .minimumPieceVolumeFraction)
        try container.encode(minimumPieceVolumeMM3, forKey: .minimumPieceVolumeMM3)
        try container.encode(minimumSeamAreaMM2, forKey: .minimumSeamAreaMM2)
        try container.encode(seamKeys, forKey: .seamKeys)
        try container.encode(faceConstraints, forKey: .faceConstraints)
        let orderedLocks = lockedPullDirections
            .map { PullLockRecord(regionID: $0.key, direction: $0.value) }
            .sorted { $0.regionID < $1.regionID }
        try container.encode(orderedLocks, forKey: .lockedPullDirections)
        try container.encodeIfPresent(authoredCutTree, forKey: .authoredCutTree)
        try container.encode(seed, forKey: .seed)
        try container.encode(plannerVersion, forKey: .plannerVersion)
        try container.encode(tolerancePolicyVersion, forKey: .tolerancePolicyVersion)
    }

    private struct PullLockRecord: Codable {
        var regionID: PartitionRegionID
        var direction: Vec3
    }

    private static func unitDirection(_ value: Vec3?) -> Vec3? {
        guard let value,
              value.x.isFinite,
              value.y.isFinite,
              value.z.isFinite else { return nil }
        let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        guard length.isFinite, length > 1.0e-12 else { return nil }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, lower), upper)
    }

    private static func nonnegative(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return max(value, 0)
    }
}

/// Lossless representation of any JSON payload used to quarantine an authored
/// tree whose typed decode or validation fails. Object key order is immaterial;
/// all values and keys survive a decode/encode cycle.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
