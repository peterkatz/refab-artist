import Foundation

// MARK: - CustomMaterial

/// A named manufacturing material bundle — "add your own stock for later
/// use" (a named set of sheet + CNC parameters, app-wide across sessions)
/// PLUS the built-in standard sheet presets.
///
/// ## Field semantics
/// - `thickness`       — stock depth (mm)
/// - `slotClearance`   — "Slot Offset", the kerf (default 0.01″ = 0.254 mm):
///                       the cutting tool's width, added to every slot so
///                       parts fit. This IS the geometry field: `slotWidth =
///                       materialThickness + slotClearance` (InterlockedSlices,
///                       InterlockedPartBuilder) (NEO-116).
/// - `kerf`            — persisted MIRROR of `slotClearance` for the separate
///                       "Slot Offset" settings field and JSON back-compat.
///                       Always kept equal to `slotClearance`; the generators
///                       read `slotClearance`. (A dogbone corner-relief use
///                       of kerf when toolDiameter > 0 is unimplemented;
///                       tracked separately.)
/// - `toolDiameter`    — cutter (router bit) diameter (mm): Tool Dia., the
///                       one tool diameter. It sizes Interlocked Slot relief
///                       and Radial relief; 0 means no relief.
/// - `sheetWidth`      — sheet stock width (mm)
/// - `sheetHeight`     — sheet stock height (mm)
/// - `horizontalMargin`— page margin (mm); applying the material sets the
///                       packer's one `pageMargin` from it.
/// - `verticalMargin`  — kept for JSON compatibility; the packer has a single
///                       margin, so it is saved equal to `horizontalMargin`
///                       and otherwise unused.
///
/// ## Backward compatibility
/// `kerf`, `toolDiameter`, `horizontalMargin`, `verticalMargin` are optional
/// in the stored JSON (legacy records lack them; decode defaults below).
struct CustomMaterial: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var thickness: Double
    var slotClearance: Double
    var sheetWidth: Double
    var sheetHeight: Double
    // Fields added for NEO-105 — optional so legacy JSON still decodes.
    var kerf: Double                // default 0.254 mm (0.01″)
    var toolDiameter: Double        // default 0.0 (no relief)
    var horizontalMargin: Double    // default 0.254 mm (0.01″)
    var verticalMargin: Double      // default 0.254 mm (0.01″)

    // MARK: - Convenience init (legacy 4-field call sites, new fields get defaults)
    init(
        id: UUID = UUID(),
        name: String,
        thickness: Double,
        slotClearance: Double,
        sheetWidth: Double,
        sheetHeight: Double,
        kerf: Double = 0.254,
        toolDiameter: Double = 0.0,
        horizontalMargin: Double = 0.254,
        verticalMargin: Double = 0.254
    ) {
        self.id = id
        self.name = name
        self.thickness = thickness
        self.slotClearance = slotClearance
        self.sheetWidth = sheetWidth
        self.sheetHeight = sheetHeight
        self.kerf = kerf
        self.toolDiameter = toolDiameter
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
    }

    // MARK: - Codable — optional new fields for legacy-compat

    enum CodingKeys: String, CodingKey {
        case id, name, thickness, slotClearance, sheetWidth, sheetHeight
        case kerf, toolDiameter, horizontalMargin, verticalMargin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name              = try c.decode(String.self, forKey: .name)
        thickness         = try c.decode(Double.self, forKey: .thickness)
        slotClearance     = try c.decode(Double.self, forKey: .slotClearance)
        sheetWidth        = try c.decode(Double.self, forKey: .sheetWidth)
        sheetHeight       = try c.decode(Double.self, forKey: .sheetHeight)
        kerf              = try c.decodeIfPresent(Double.self, forKey: .kerf) ?? 0.254
        toolDiameter      = try c.decodeIfPresent(Double.self, forKey: .toolDiameter) ?? 0.0
        horizontalMargin  = try c.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? 0.254
        verticalMargin    = try c.decodeIfPresent(Double.self, forKey: .verticalMargin) ?? 0.254
    }

    // MARK: - Matching

    func matches(
        thickness: Double,
        slotClearance: Double,
        sheetWidth: Double,
        sheetHeight: Double
    ) -> Bool {
        self.thickness == thickness
            && self.slotClearance == slotClearance
            && self.sheetWidth == sheetWidth
            && self.sheetHeight == sheetHeight
    }

    /// Whether the live manufacturing values still match this material. The
    /// packer has one page margin, which a material stores as its horizontal
    /// margin (applying a material sets the page margin from it).
    func matches(
        thickness: Double,
        slotClearance: Double,
        sheetWidth: Double,
        sheetHeight: Double,
        kerf: Double,
        toolDiameter: Double,
        pageMargin: Double
    ) -> Bool {
        self.thickness == thickness
            && self.slotClearance == slotClearance
            && self.sheetWidth == sheetWidth
            && self.sheetHeight == sheetHeight
            && self.kerf == kerf
            && self.toolDiameter == toolDiameter
            && self.horizontalMargin == pageMargin
    }
}

// MARK: - BuiltInMaterialPreset

/// The 14 built-in sheet presets: standard ISO A/B, US Letter/Legal and
/// common laser-bed (P-series) sheet sizes. Built-ins are not deletable;
/// duplicating one creates a new custom entry.
///
/// Inch-sized presets are converted × 25.4; all dimensions are stored in
/// **mm** here.
enum BuiltInMaterialPreset: String, CaseIterable, Identifiable {
    // A-series (inches × 25.4)
    case a4
    case a3
    case a2
    case a1
    // NA Letter/Legal
    case letter
    case legal
    // B-series (inches × 25.4)
    case b5
    case b4
    case b3
    case b2
    case b1
    // P-series (native mm)
    case p1
    case p2
    case p3

    var id: String { rawValue }

    // MARK: - Display name

    var label: String {
        switch self {
        case .a4:     return "A4 8.27\" x 11.69\" x 0.1772\""
        case .a3:     return "A3 11.69\" x 16.54\" x 0.1772\""
        case .a2:     return "A2 16.54\" x 23.39\" x 0.1772\""
        case .a1:     return "A1 23.39\" x 33.11\" x 0.1772\""
        case .letter: return "Letter 8.5\" x 11\" x 0.1772\""
        case .legal:  return "Legal 8.5\" x 14\" x 0.1772\""
        case .b5:     return "B5 6.93\" x 9.84\" x 0.1772\""
        case .b4:     return "B4 9.84\" x 13.90\" x 0.1772\""
        case .b3:     return "B3 13.90\" x 19.69\" x 0.1772\""
        case .b2:     return "B2 19.69\" x 27.83\" x 0.1772\""
        case .b1:     return "B1 27.83\" x 39.37\" x 0.1772\""
        case .p1:     return "P1 181mm x 181mm x 4.5mm"
        case .p2:     return "P2 384mm x 384mm x 4.5mm"
        case .p3:     return "P3 384mm x 790mm x 4.5mm"
        }
    }

    // MARK: - Preset values (all stored in mm)
    // All built-ins: kerf=0.01″=0.254mm, toolDiameter=0.0
    // Inch presets: 1 in = 25.4 mm; depth 0.1772 in = 4.500888 mm ≈ 4.5009 mm
    // P-series: native mm, depth 4.5 mm
    // Margins: 0.2 in the preset's own unit — 0.2 in = 5.08 mm for inch
    // presets, 0.2 mm for mm presets. P2 is 0.0.

    private static let inchDepth = 0.1772 * 25.4   // 4.50088 mm
    private static let kerfMm    = 0.01   * 25.4   // 0.254 mm
    private static let marginInch = 0.2  * 25.4    // 5.08 mm
    private static let marginMm   = 0.2            // 0.2 mm

    var material: CustomMaterial {
        let (w, h, depth, hm, vm) = dimensions
        return CustomMaterial(
            name: label,
            // Slot Offset/kerf IS the slot-geometry field; a
            // built-in preset must carry it here, not just in the mirror, or
            // picking the preset would apply zero offset (NEO-116).
            thickness: depth,
            slotClearance: Self.kerfMm,
            sheetWidth: w,
            sheetHeight: h,
            kerf: Self.kerfMm,
            toolDiameter: 0.0,
            horizontalMargin: hm,
            verticalMargin: vm
        )
    }

    /// (width, height, depth, hMargin, vMargin) in mm
    private var dimensions: (Double, Double, Double, Double, Double) {
        let d = Self.inchDepth
        let k = Self.kerfMm
        _ = k  // kerf stored on CustomMaterial.kerf; not in dimensions tuple
        let mi = Self.marginInch
        let mm = Self.marginMm
        switch self {
        case .a4:     return (8.27 * 25.4, 11.69 * 25.4, d,          mi, mi)
        case .a3:     return (11.69 * 25.4, 16.54 * 25.4, d,         mi, mi)
        case .a2:     return (16.54 * 25.4, 23.39 * 25.4, d,         mi, mi)
        case .a1:     return (23.39 * 25.4, 33.11 * 25.4, d,         mi, mi)
        case .letter: return (8.5 * 25.4, 11.0 * 25.4, d,            mi, mi)
        case .legal:  return (8.5 * 25.4, 14.0 * 25.4, d,            mi, mi)
        case .b5:     return (6.93 * 25.4, 9.84 * 25.4, d,           mi, mi)
        case .b4:     return (9.84 * 25.4, 13.90 * 25.4, d,          mi, mi)
        case .b3:     return (13.90 * 25.4, 19.69 * 25.4, d,         mi, mi)
        case .b2:     return (19.69 * 25.4, 27.83 * 25.4, d,         mi, mi)
        case .b1:     return (27.83 * 25.4, 39.37 * 25.4, d,         mi, mi)
        case .p1:     return (181.0, 181.0, 4.5,                      mm, mm)
        case .p2:     return (384.0, 384.0, 4.5,                      0.0, 0.0)  // P2 only: zero margins
        case .p3:     return (384.0, 790.0, 4.5,                      mm, mm)
        }
    }
}

// MARK: - CustomMaterialStore

enum CustomMaterialStore {
    static let defaultsKey = "customMaterials"

    static func load(from defaults: UserDefaults = .standard) -> [CustomMaterial] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CustomMaterial].self, from: data)) ?? []
    }

    static func save(_ materials: [CustomMaterial], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(materials) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
