import Foundation

// MARK: - Build volume

/// Usable interior build volume of a printer, in millimetres.
struct PrinterVolume: Codable, Equatable {
    var width: Double   // X
    var depth: Double   // Y
    var height: Double  // Z

    static let defaultValue = PrinterVolume(width: 256, depth: 256, height: 256)

    var sanitized: PrinterVolume {
        PrinterVolume(
            width: PrinterVolume.clamp(width),
            depth: PrinterVolume.clamp(depth),
            height: PrinterVolume.clamp(height)
        )
    }

    func extent(forAxis axis: Int) -> Double {
        switch axis {
        case 0: return width
        case 1: return depth
        default: return height
        }
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 50 }
        return Swift.min(Swift.max(value, 10), 5000)
    }
}

/// Starter list of common consumer printers. `custom` keeps the user-entered
/// build volume; every other case supplies a fixed volume but stays fully
/// editable (selecting one seeds the W/D/H fields, which the user can override).
enum PartitionPrinterPreset: String, CaseIterable, Identifiable, Codable {
    case bambuX1C
    case bambuA1
    case bambuA1Mini
    case prusaMK4
    case enderV3
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bambuX1C: return "Bambu Lab X1C — 256 × 256 × 256"
        case .bambuA1: return "Bambu Lab A1 — 256 × 256 × 256"
        case .bambuA1Mini: return "Bambu Lab A1 mini — 180 × 180 × 180"
        case .prusaMK4: return "Prusa MK4 — 250 × 210 × 220"
        case .enderV3: return "Creality Ender-3 — 220 × 220 × 250"
        case .custom: return "Custom…"
        }
    }

    /// Fixed volume for the named printers, `nil` for `.custom`.
    var volume: PrinterVolume? {
        switch self {
        case .bambuX1C: return PrinterVolume(width: 256, depth: 256, height: 256)
        case .bambuA1: return PrinterVolume(width: 256, depth: 256, height: 256)
        case .bambuA1Mini: return PrinterVolume(width: 180, depth: 180, height: 180)
        case .prusaMK4: return PrinterVolume(width: 250, depth: 210, height: 220)
        case .enderV3: return PrinterVolume(width: 220, depth: 220, height: 250)
        case .custom: return nil
        }
    }
}

// MARK: - Cut planes

/// One arbitrary cut plane, stored as a unit normal plus an offset: the plane is
/// `{ p : dot(p, normal) == offset }` in model space. Axis-aligned grid cuts are
/// just planes whose normal is a basis vector — the engine treats them all the
/// same. `isManual` tags planes the user placed by hand so re-running Auto-fit
/// can preserve them.
struct PartitionPlane: Codable, Equatable, Identifiable {
    var id: UUID
    var normalX: Double
    var normalY: Double
    var normalZ: Double
    var offset: Double
    var isManual: Bool

    init(id: UUID = UUID(), normal: Vec3, offset: Double, isManual: Bool) {
        let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
        if length > 1.0e-9 {
            self.normalX = normal.x / length
            self.normalY = normal.y / length
            self.normalZ = normal.z / length
            self.offset = offset / length
        } else {
            self.normalX = 0
            self.normalY = 0
            self.normalZ = 1
            self.offset = offset
        }
        self.id = id
        self.isManual = isManual
    }

    var normal: Vec3 { Vec3(x: normalX, y: normalY, z: normalZ) }

    /// Axis index 0/1/2 when the plane is (near) axis-aligned, else nil.
    var axisAligned: Int? {
        let ax = abs(normalX), ay = abs(normalY), az = abs(normalZ)
        if ax > 0.999 { return 0 }
        if ay > 0.999 { return 1 }
        if az > 0.999 { return 2 }
        return nil
    }
}

// MARK: - Registration keys

enum PartitionKeyType: String, CaseIterable, Identifiable, Codable {
    case none
    case pins
    case dovetail

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None — butt joint / glue"
        case .pins: return "Locating pins (pin + socket)"
        case .dovetail: return "Wedge key (rectangular, anti-rotation)"
        }
    }

    var hasImplementedEngine: Bool {
        true
    }

    static var userVisibleOptions: [PartitionKeyType] {
        allCases.filter(\.hasImplementedEngine)
    }
}

struct PartitionKeySettings: Codable, Equatable {
    var type: PartitionKeyType
    var pinDiameter: Double
    var pinLength: Double
    var tolerance: Double
    var pinsPerSeam: Int
    var edgeMargin: Double

    static let defaultValue = PartitionKeySettings(
        type: .pins,
        pinDiameter: 6.0,
        pinLength: 8.0,
        tolerance: 0.2,
        pinsPerSeam: 2,
        edgeMargin: 3.0
    )

    /// Extra room a male pin needs beyond the cut plane, used to shrink the
    /// Auto-fit target box so a keyed piece still fits the bed.
    var allowance: Double {
        guard type != .none else { return 0 }
        return pinLength + tolerance + 0.5
    }

    var sanitized: PartitionKeySettings {
        PartitionKeySettings(
            type: type,
            pinDiameter: PartitionKeySettings.clamp(pinDiameter, 1, 40),
            pinLength: PartitionKeySettings.clamp(pinLength, 1, 60),
            tolerance: PartitionKeySettings.clamp(tolerance, 0, 2),
            pinsPerSeam: Swift.min(Swift.max(pinsPerSeam, 1), 6),
            edgeMargin: PartitionKeySettings.clamp(edgeMargin, 0, 40)
        )
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}

// MARK: - Mode / strategy / output enums

enum PartitionMode: String, CaseIterable, Identifiable, Codable {
    case autoFit
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoFit: return "Auto-fit"
        case .manual: return "Manual"
        }
    }
}

enum PartitionAutoStrategy: String, CaseIterable, Identifiable, Codable {
    case fewestParts
    case evenSizes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fewestParts: return "Strategy — fewest parts"
        case .evenSizes: return "Strategy — even part sizes"
        }
    }
}

enum PartitionPackaging: String, CaseIterable, Identifiable, Codable {
    case separateZip
    case combinedObj
    case laidOutPlate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .separateZip: return "Separate files in a .zip"
        case .combinedObj: return "One file, named parts"
        case .laidOutPlate: return "Laid out on one plate"
        }
    }
}

enum PartitionNaming: String, CaseIterable, Identifiable, Codable {
    case gridLabels
    case sequential

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gridLabels: return "Grid labels (A1, B2…)"
        case .sequential: return "Sequential (part-01…)"
        }
    }
}

// MARK: - Settings

struct PartitionSettings: Codable, Equatable {
    var purpose: PartitionPurpose
    var mode: PartitionMode
    var printerPreset: PartitionPrinterPreset
    var buildVolume: PrinterVolume
    var bedMargin: Double
    var autoStrategy: PartitionAutoStrategy
    /// User-placed cut planes (Manual mode). Auto-fit computes its own planes
    /// from the build volume and ignores these; the "Populate from Auto-fit"
    /// action seeds this list so the user can then tweak individual planes.
    var manualPlanes: [PartitionPlane]
    var key: PartitionKeySettings
    var packaging: PartitionPackaging
    var includeAssemblyMap: Bool
    var naming: PartitionNaming
    /// Viewport-only: how far apart to pull the pieces in the preview (0…1).
    /// Never affects exported coordinates.
    var explodePreview: Double
    /// Purpose-specific settings remain optional so old project documents
    /// migrate without manufacturing a new payload until this purpose is used.
    var undercutSplit: UndercutSplitSettings?

    static let defaultValue = PartitionSettings(
        mode: .autoFit,
        printerPreset: .bambuX1C,
        buildVolume: .defaultValue,
        bedMargin: 2.0,
        autoStrategy: .fewestParts,
        manualPlanes: [],
        key: .defaultValue,
        packaging: .separateZip,
        includeAssemblyMap: true,
        naming: .gridLabels,
        explodePreview: 0.35,
        purpose: .fitPrinter,
        undercutSplit: nil
    )

    var sanitized: PartitionSettings {
        var copy = self
        copy.buildVolume = buildVolume.sanitized
        copy.bedMargin = bedMargin.isFinite ? Swift.min(Swift.max(bedMargin, 0), 100) : 0
        copy.key = key.sanitized
        copy.explodePreview = explodePreview.isFinite ? Swift.min(Swift.max(explodePreview, 0), 1) : 0
        copy.undercutSplit = undercutSplit?.sanitized
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case printerPreset
        case buildVolume
        case bedMargin
        case autoStrategy
        case manualPlanes
        case key
        case packaging
        case includeAssemblyMap
        case naming
        case explodePreview
        case purpose
        case undercutSplit
    }

    init(
        mode: PartitionMode,
        printerPreset: PartitionPrinterPreset,
        buildVolume: PrinterVolume,
        bedMargin: Double,
        autoStrategy: PartitionAutoStrategy,
        manualPlanes: [PartitionPlane],
        key: PartitionKeySettings,
        packaging: PartitionPackaging,
        includeAssemblyMap: Bool,
        naming: PartitionNaming,
        explodePreview: Double,
        purpose: PartitionPurpose = .fitPrinter,
        undercutSplit: UndercutSplitSettings? = nil
    ) {
        self.purpose = purpose
        self.mode = mode
        self.printerPreset = printerPreset
        self.buildVolume = buildVolume
        self.bedMargin = bedMargin
        self.autoStrategy = autoStrategy
        self.manualPlanes = manualPlanes
        self.key = key
        self.packaging = packaging
        self.includeAssemblyMap = includeAssemblyMap
        self.naming = naming
        self.explodePreview = explodePreview
        self.undercutSplit = undercutSplit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PartitionSettings.defaultValue
        purpose = try container.decodeIfPresent(PartitionPurpose.self, forKey: .purpose) ?? fallback.purpose
        mode = try container.decodeIfPresent(PartitionMode.self, forKey: .mode) ?? fallback.mode
        printerPreset = try container.decodeIfPresent(PartitionPrinterPreset.self, forKey: .printerPreset) ?? fallback.printerPreset
        buildVolume = try container.decodeIfPresent(PrinterVolume.self, forKey: .buildVolume) ?? fallback.buildVolume
        bedMargin = try container.decodeIfPresent(Double.self, forKey: .bedMargin) ?? fallback.bedMargin
        autoStrategy = try container.decodeIfPresent(PartitionAutoStrategy.self, forKey: .autoStrategy) ?? fallback.autoStrategy
        manualPlanes = try container.decodeIfPresent([PartitionPlane].self, forKey: .manualPlanes) ?? fallback.manualPlanes
        key = try container.decodeIfPresent(PartitionKeySettings.self, forKey: .key) ?? fallback.key
        packaging = try container.decodeIfPresent(PartitionPackaging.self, forKey: .packaging) ?? fallback.packaging
        includeAssemblyMap = try container.decodeIfPresent(Bool.self, forKey: .includeAssemblyMap) ?? fallback.includeAssemblyMap
        naming = try container.decodeIfPresent(PartitionNaming.self, forKey: .naming) ?? fallback.naming
        explodePreview = try container.decodeIfPresent(Double.self, forKey: .explodePreview) ?? fallback.explodePreview
        undercutSplit = try container.decodeIfPresent(UndercutSplitSettings.self, forKey: .undercutSplit)
    }
}

// MARK: - CLI parsing

extension PartitionMode {
    static func cliValue(_ value: String) -> PartitionMode? {
        switch partitionNormalizedCLIValue(value) {
        case "autofit", "auto": return .autoFit
        case "manual": return .manual
        default: return nil
        }
    }
}

extension PartitionPrinterPreset {
    static func cliValue(_ value: String) -> PartitionPrinterPreset? {
        let normalized = partitionNormalizedCLIValue(value)
        return allCases.first { partitionNormalizedCLIValue($0.rawValue) == normalized }
    }
}

extension PartitionAutoStrategy {
    static func cliValue(_ value: String) -> PartitionAutoStrategy? {
        switch partitionNormalizedCLIValue(value) {
        case "fewestparts", "fewest": return .fewestParts
        case "evensizes", "even": return .evenSizes
        default: return nil
        }
    }
}

extension PartitionKeyType {
    static func cliValue(_ value: String) -> PartitionKeyType? {
        switch partitionNormalizedCLIValue(value) {
        case "none", "butt", "glue": return .none
        case "pins", "pin": return .pins
        case "dovetail", "wedge": return .dovetail
        default: return nil
        }
    }
}

extension PartitionPackaging {
    static func cliValue(_ value: String) -> PartitionPackaging? {
        switch partitionNormalizedCLIValue(value) {
        case "separatezip", "separate", "zip": return .separateZip
        case "combinedobj", "combined", "named": return .combinedObj
        case "laidoutplate", "laidout", "plate": return .laidOutPlate
        default: return nil
        }
    }
}

extension PartitionNaming {
    static func cliValue(_ value: String) -> PartitionNaming? {
        switch partitionNormalizedCLIValue(value) {
        case "gridlabels", "grid": return .gridLabels
        case "sequential", "seq": return .sequential
        default: return nil
        }
    }
}

private func partitionNormalizedCLIValue(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
}
