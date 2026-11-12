import Foundation

enum MaterialMode: String, CaseIterable, Codable, Identifiable {
    case rigidMembrane
    case stretchCloth
    case paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rigidMembrane: return "Rigid membrane"
        case .stretchCloth: return "Stretch cloth"
        case .paper: return "Paper"
        }
    }
}

enum JoinMethod: String, CaseIterable, Codable, Identifiable {
    case tape
    case weld
    case sew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tape: return "Tape"
        case .weld: return "Weld"
        case .sew: return "Sew"
        }
    }
}

enum InflatablesViewMode: String, CaseIterable, Codable, Identifiable {
    case target
    case panels
    case inflated
    case compare

    var id: String { rawValue }

    var label: String {
        switch self {
        case .target: return "Target"
        case .panels: return "Panels"
        case .inflated: return "Inflated"
        case .compare: return "Compare"
        }
    }
}

struct EdgeRef: Codable, Hashable {
    var a: Int32
    var b: Int32
}

struct PlaneEq: Codable, Equatable {
    var normal: Vec3
    var offset: Double

    init(normal: Vec3 = Vec3(x: 0, y: 0, z: 1), offset: Double = 0) {
        let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
        if length > 1.0e-9 {
            self.normal = Vec3(x: normal.x / length, y: normal.y / length, z: normal.z / length)
            self.offset = offset / length
        } else {
            self.normal = Vec3(x: 0, y: 0, z: 1)
            self.offset = offset
        }
    }

    func signedDistance(to point: Vec3) -> Double {
        normal.x * point.x + normal.y * point.y + normal.z * point.z - offset
    }
}

struct SeamEdit: Codable, Equatable {
    enum Kind: String, Codable {
        case add
        case move
        case delete
    }

    var id: String
    var kind: Kind
    var edge: EdgeRef?
    var from: Vec3?
    var to: Vec3?
}

struct BaffleSpec: Codable, Equatable {
    var id: String
    var plane: PlaneEq
    var inset: Double
}

struct PortSpec: Codable, Equatable {
    var id: String
    var center: Vec3
    var radiusMM: Double
}

struct InflatablesSettings: Codable, Equatable {
    var material: MaterialMode = .rigidMembrane
    var targetPanelWidthMM: Double = 120
    var maxPanelCount: Int = 64
    var seamAllowanceMM: Double = 8
    var joinMethod: JoinMethod = .weld
    var rollWidthMM: Double? = nil
    var symmetryEnabled: Bool = false
    var symmetryPlane: PlaneEq? = nil
    var freeBoundaryEdges: [EdgeRef] = []
    var ports: [PortSpec] = []
    var baffles: [BaffleSpec] = []
    var seamOverrides: [SeamEdit] = []

    static let defaultValue = InflatablesSettings()

    var sanitized: InflatablesSettings {
        var copy = self
        copy.targetPanelWidthMM = Self.clamp(targetPanelWidthMM, 10, 1000)
        copy.maxPanelCount = min(max(maxPanelCount, 1), 512)
        copy.seamAllowanceMM = Self.clamp(seamAllowanceMM, 0, 80)
        if let roll = rollWidthMM {
            copy.rollWidthMM = Self.clamp(roll, 25, 5000)
        }
        copy.baffles = baffles.filter { $0.inset.isFinite }
        copy.ports = ports.filter { $0.radiusMM.isFinite && $0.radiusMM > 0 }
        return copy
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

struct RegistrationMark: Codable, Equatable {
    var at: Vec2
    var pairId: String
}

struct FlatPanel: Codable, Equatable {
    var id: String
    var cutOutline2D: [Vec2]
    var seamLine2D: [Vec2]
    var sourceFaceIDs: [Int]
    var registration: [RegistrationMark]
    var labelAnchor: Vec2
    var isBaffle: Bool
    var baffleAttachLines2D: [[Vec2]]
    var mirrored: Bool
}

struct SeamPair: Codable, Equatable {
    var id: String
    var panelA: String
    var edgeA: Int
    var panelB: String
    var edgeB: Int
}

struct PlanDiagnostic: Codable, Equatable {
    var kind: String
    var message: String
    var at: Vec3?
    var panelID: String? = nil
}

struct InflationPreviewResult: Codable, Equatable {
    var inflatedMesh: MeshGeometryData
    var maxDeviationMM: Double
    var meanDeviationMM: Double
    var deviationByVertex: [Double]
    var panelErrorMM: [String: Double]

    static let empty = InflationPreviewResult(
        inflatedMesh: MeshGeometryData(vertices: [], triangleIndices: []),
        maxDeviationMM: 0,
        meanDeviationMM: 0,
        deviationByVertex: [],
        panelErrorMM: [:]
    )
}

struct InflatablesPlan {
    var panels: [FlatPanel]
    var seams: [SeamPair]
    var preview: InflationPreviewResult?
    var cutSheet: CutSheetDocument
    var diagnostics: [PlanDiagnostic]

    static let empty = InflatablesPlan(
        panels: [],
        seams: [],
        preview: nil,
        cutSheet: InflatablesCutPattern.emptyDocument(revision: 0),
        diagnostics: []
    )
}

enum InflatablesPlannerError: LocalizedError, Equatable {
    case notWatertight
    case emptyAfterClean
    case segmentationFailed

    var errorDescription: String? {
        switch self {
        case .notWatertight:
            return "Inflatables needs a watertight source mesh. Repair the model, then generate the panels."
        case .emptyAfterClean:
            return "The inflatable pre-clean produced no usable geometry."
        case .segmentationFailed:
            return "The inflatable panel segmentation failed."
        }
    }
}
