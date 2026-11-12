import Foundation

/// Top-level Structures sub-category. The "Structures" construction mode turns an
/// imported mesh into 3D-printer-style internal geometry clipped exactly to the
/// model skin. There are three sub-categories:
///
/// - `.infill` — fill the interior with printer-style lattices and TPMS sheets
///   booleaned against the source solid.
/// - `.support` — grow organic standalone sculpture supports; printable scaffold
///   supports are a later support mode.
/// - `.skin` — replace the model surface with a hollow strut/perforated skin.
enum StructureCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case infill
    case support
    case skin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .infill: return "Infill"
        case .support: return "Supports"
        case .skin: return "Skin"
        }
    }

    /// Whether an engine backs this sub-category in the current build.
    var isImplemented: Bool {
        switch self {
        case .infill, .support, .skin: return true
        }
    }

    var help: String {
        switch self {
        case .infill:
            return "Fill the model with a 3D-printer infill lattice clipped to its skin."
        case .support:
            return "Grow organic sculpture supports whose tips reform a selected model surface."
        case .skin:
            return "Replace the model surface with a hollow Voronoi-style strut skin."
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StructureCategory(rawValue: raw) ?? .infill
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Interior infill pattern, mirroring the owner's reference infill chart. Only
/// `.triangle` is fully engine-backed in this phase; every other case is part of
/// the schema (so saved projects and the UI accept it without a migration) and
/// is wired to a named `WallSolidGenerator` that is filled in pattern-by-pattern
/// in later phases.
///
/// The cases group into three families, surfaced as such in the UI picker:
/// - PLANAR: extruded 2D line families (triangle, grid, tri-hexagon, cross,
///   concentric).
/// - LATTICE: 3D strut networks across the bbox (cubic, octet, quarter cubic,
///   cubic subdivision, cross 3D).
/// - TPMS: gyroid minimal-surface sheets built from 2D per-layer contours +
///   extrude + Manifold union + smoothing (Lofted, Tiled) — NO 3D marching cubes.
///
/// New rawValues that an OLD project can never contain decode-fail to
/// `.triangle` (see `StructureSettings.init(from:)`), so persistence stays
/// backward-compatible.
enum InfillPattern: String, CaseIterable, Identifiable, Codable, Sendable {
    // PLANAR
    case triangle
    case grid
    case triHexagon
    case cross
    case concentric
    // LATTICE
    case cubic
    case octet
    case quarterCubic
    case cubicSubdivision
    case cross3D
    // TPMS — two non-marching-cubes gyroid generators the owner can compare
    // in-app and keep whichever (or both). Both build the gyroid SHEET from 2D
    // per-layer contours + extrude + union + smooth (NO 3D marching cubes).
    case gyroidLofted
    case gyroidTiled
    case gyroidNetwork
    case gradedGyroid
    // OP ART — two artist-named PLANAR wall patterns: full-height vertical walls
    // whose XY footprint is a warped thin ribbon, extruded the full model height.
    // Flat-shaded like the other planar families (not curved).
    case stanczak
    case vasarely
    case rileySquares
    case gradedRings
    case waveGrating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .triangle: return "Triangle"
        case .grid: return "Grid"
        case .triHexagon: return "Tri-Hexagon"
        case .cross: return "Cross"
        case .concentric: return "Concentric"
        case .cubic: return "Cubic"
        case .octet: return "Octet"
        case .quarterCubic: return "Quarter Cubic"
        case .cubicSubdivision: return "Cubic Subdivision"
        case .cross3D: return "Cross 3D"
        case .gyroidLofted: return "Gyroid · Lofted"
        case .gyroidTiled: return "Gyroid · Marching Cubes"
        case .gyroidNetwork: return "Gyroid · Network"
        case .gradedGyroid: return "Graded Gyroid"
        case .stanczak: return "Stanczak"
        case .vasarely: return "Vasarely"
        case .rileySquares: return "Riley Movement-in-Squares"
        case .gradedRings: return "Graded Rings"
        case .waveGrating: return "Wave Grating"
        }
    }

    /// Whether a real geometry generator backs this pattern in the current build.
    /// During the staged rollout only `.triangle` is fully implemented; the other
    /// cases are wired to named generator stubs that throw `patternNotImplemented`
    /// until their phase lands. The UI gates Generate (and shows a hint) on this,
    /// since every pattern now returns a non-nil generator. Flip a case to `true`
    /// in the phase that implements it.
    var isImplemented: Bool {
        switch self {
        case .triangle, .grid, .triHexagon, .cross, .concentric: return true
        case .cubic, .octet, .quarterCubic, .cubicSubdivision, .cross3D: return true
        case .gyroidLofted, .gyroidTiled, .gyroidNetwork, .gradedGyroid: return true
        case .stanczak, .vasarely, .rileySquares, .gradedRings, .waveGrating: return true
        }
    }

    /// The reference-chart family this pattern belongs to. Used to group the UI
    /// picker.
    enum Family: String, CaseIterable, Identifiable {
        case planar
        case lattice
        case tpms
        case opArt

        var id: String { rawValue }

        var label: String {
            switch self {
            case .planar: return "Planar"
            case .lattice: return "Lattice"
            case .tpms: return "TPMS"
            case .opArt: return "Op Art"
            }
        }
    }

    var family: Family {
        switch self {
        case .triangle, .grid, .triHexagon, .cross, .concentric:
            return .planar
        case .cubic, .octet, .quarterCubic, .cubicSubdivision, .cross3D:
            return .lattice
        case .gyroidLofted, .gyroidTiled, .gyroidNetwork, .gradedGyroid:
            return .tpms
        case .stanczak, .vasarely, .rileySquares, .gradedRings, .waveGrating:
            return .opArt
        }
    }

    /// All patterns in a given family, in declared order.
    static func patterns(in family: Family) -> [InfillPattern] {
        allCases.filter { $0.family == family }
    }

    var supportsVariableDensity: Bool {
        switch self {
        case .triangle, .grid, .triHexagon, .cross, .cubicSubdivision, .cross3D,
             .gradedGyroid, .rileySquares, .gradedRings, .waveGrating:
            return true
        case .concentric, .cubic, .octet, .quarterCubic,
             .gyroidLofted, .gyroidTiled, .gyroidNetwork, .stanczak, .vasarely:
            return false
        }
    }
}

enum StructureDensitySource: String, CaseIterable, Identifiable, Codable, Sendable {
    case uniform
    case image
    case attractors
    case nearSurface

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uniform: return "Uniform"
        case .image: return "Image"
        case .attractors: return "Attractors"
        case .nearSurface: return "Near Surface"
        }
    }

    var isEngineBacked: Bool {
        switch self {
        case .uniform, .image, .attractors, .nearSurface: return true
        }
    }
}

enum StructureAttractorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case center
    case top
    case bottom
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: return "Center"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .custom: return "Custom"
        }
    }
}

extension DensityImageProjection: CaseIterable, Identifiable, Codable, Hashable {
    static var allCases: [DensityImageProjection] { [.xy, .xz, .yz] }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .xy: return "xy"
        case .xz: return "xz"
        case .yz: return "yz"
        }
    }

    var label: String { rawValue.uppercased() }

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "xy": self = .xy
        case "xz": self = .xz
        case "yz": self = .yz
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DensityImageProjection(rawValue: raw) ?? .xy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static func == (lhs: DensityImageProjection, rhs: DensityImageProjection) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

struct StructureDensitySettings: Codable, Equatable, Sendable {
    var source: StructureDensitySource = .uniform
    var minCellMm: Double = 9.0
    var maxCellMm: Double = 9.0
    var imagePath: String?
    var imageProjection: DensityImageProjection = .xy
    var invertImage: Bool = false
    var attractorPreset: StructureAttractorPreset = .center
    var customAttractorPoint: Vec3 = Vec3(x: 0, y: 0, z: 0)
    var falloffMm: Double = 50.0
    var nearSurfaceBandMm: Double = 10.0

    static let defaultValue = StructureDensitySettings()

    init(
        source: StructureDensitySource = .uniform,
        minCellMm: Double = 9.0,
        maxCellMm: Double = 9.0,
        imagePath: String? = nil,
        imageProjection: DensityImageProjection = .xy,
        invertImage: Bool = false,
        attractorPreset: StructureAttractorPreset = .center,
        customAttractorPoint: Vec3 = Vec3(x: 0, y: 0, z: 0),
        falloffMm: Double = 50.0,
        nearSurfaceBandMm: Double = 10.0
    ) {
        self.source = source
        self.minCellMm = minCellMm
        self.maxCellMm = maxCellMm
        self.imagePath = imagePath
        self.imageProjection = imageProjection
        self.invertImage = invertImage
        self.attractorPreset = attractorPreset
        self.customAttractorPoint = customAttractorPoint
        self.falloffMm = falloffMm
        self.nearSurfaceBandMm = nearSurfaceBandMm
    }

    enum CodingKeys: String, CodingKey {
        case source
        case densitySource
        case minCellMm
        case maxCellMm
        case imagePath
        case imageProjection
        case invertImage
        case attractorPreset
        case customAttractorPoint
        case falloffMm
        case nearSurfaceBandMm
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        let d = StructureDensitySettings.defaultValue
        let rawSource = ((try? c?.decodeIfPresent(String.self, forKey: .source)) ?? nil)
            ?? ((try? c?.decodeIfPresent(String.self, forKey: .densitySource)) ?? nil)
        source = rawSource.flatMap { StructureDensitySource(rawValue: $0) } ?? d.source
        minCellMm = (try? c?.decodeIfPresent(Double.self, forKey: .minCellMm)) ?? d.minCellMm
        maxCellMm = (try? c?.decodeIfPresent(Double.self, forKey: .maxCellMm)) ?? d.maxCellMm
        let rawPath = (try? c?.decodeIfPresent(String.self, forKey: .imagePath)) ?? d.imagePath
        imagePath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : rawPath
        imageProjection = ((try? c?.decodeIfPresent(DensityImageProjection.self, forKey: .imageProjection)) ?? nil) ?? d.imageProjection
        invertImage = (try? c?.decodeIfPresent(Bool.self, forKey: .invertImage)) ?? d.invertImage
        attractorPreset = ((try? c?.decodeIfPresent(StructureAttractorPreset.self, forKey: .attractorPreset)) ?? nil) ?? d.attractorPreset
        customAttractorPoint = ((try? c?.decodeIfPresent(Vec3.self, forKey: .customAttractorPoint)) ?? nil) ?? d.customAttractorPoint
        falloffMm = (try? c?.decodeIfPresent(Double.self, forKey: .falloffMm)) ?? d.falloffMm
        nearSurfaceBandMm = (try? c?.decodeIfPresent(Double.self, forKey: .nearSurfaceBandMm)) ?? d.nearSurfaceBandMm
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .densitySource)
        try c.encode(minCellMm, forKey: .minCellMm)
        try c.encode(maxCellMm, forKey: .maxCellMm)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        try c.encode(imageProjection, forKey: .imageProjection)
        try c.encode(invertImage, forKey: .invertImage)
        try c.encode(attractorPreset, forKey: .attractorPreset)
        try c.encode(customAttractorPoint, forKey: .customAttractorPoint)
        try c.encode(falloffMm, forKey: .falloffMm)
        try c.encode(nearSurfaceBandMm, forKey: .nearSurfaceBandMm)
    }

    func sanitized(defaultCellSizeMm: Double) -> StructureDensitySettings {
        var s = self
        let safeCell = Self.clampedCell(defaultCellSizeMm)
        let lo = Self.clampedCell(minCellMm)
        let hi = Self.clampedCell(maxCellMm)
        s.minCellMm = min(lo, hi)
        s.maxCellMm = max(lo, hi)
        if s.source == .uniform {
            s.minCellMm = safeCell
            s.maxCellMm = safeCell
        }
        if let path = s.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            s.imagePath = path
        } else {
            s.imagePath = nil
        }
        s.falloffMm = min(max(s.falloffMm.isFinite ? s.falloffMm : 50.0, 5.0), 500.0)
        s.nearSurfaceBandMm = min(max(s.nearSurfaceBandMm.isFinite ? s.nearSurfaceBandMm : 10.0, 1.0), 100.0)
        if !s.customAttractorPoint.x.isFinite || !s.customAttractorPoint.y.isFinite || !s.customAttractorPoint.z.isFinite {
            s.customAttractorPoint = .init(x: 0, y: 0, z: 0)
        }
        return s
    }

    var effectiveEngineSource: StructureDensitySource {
        source.isEngineBacked ? source : .uniform
    }

    var engineFallbackNotice: String? {
        switch source {
        case .uniform, .image, .attractors, .nearSurface:
            return nil
        }
    }

    private static func clampedCell(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 9.0, 1.0), 200.0)
    }
}

extension StructureSettings {
    var effectiveDensitySource: StructureDensitySource {
        let safe = sanitized
        guard safe.density.source != .uniform else { return .uniform }
        guard safe.category == .skin || safe.pattern.supportsVariableDensity else { return .uniform }
        // Near-Surface density is meaningless for a SKIN: every point of a skin
        // is at distance ~0 from the surface, so it pins every cell to Min Cell
        // and the Cell slider goes dead. Fall back honestly.
        if safe.category == .skin, safe.density.effectiveEngineSource == .nearSurface { return .uniform }
        return safe.density.effectiveEngineSource
    }

    var densityEngineNotice: String? {
        let safe = sanitized
        if safe.category != .skin, safe.density.source != .uniform, !safe.pattern.supportsVariableDensity {
            return "\(safe.pattern.label) does not honor variable density yet; generation falls back to uniform density."
        }
        if safe.category == .skin, safe.density.source == .nearSurface {
            return "Near Surface drives interior infill; a skin is entirely at the surface, so Uniform density is used — try Image or Attractors to vary cells spatially."
        }
        return safe.density.engineFallbackNotice
    }
}

/// Numeric parameters shared across infill patterns. Each pattern reads only the
/// fields it needs (triangle uses `cellSizeMm` + `wallThicknessMm`; gyroid uses
/// `cellSizeMm` + `wallThicknessMm` + `gyroidBand`). `seed` is reserved for future
/// stochastic patterns and has no effect on the deterministic generators.
///
/// Hand-written `init(from:)`/`encode(to:)` decode each scalar with
/// `decodeIfPresent ?? default` so old or partial payloads never throw.
struct InfillParameters: Codable, Equatable, Sendable {
    /// Triangle line spacing / gyroid period, in millimetres.
    var cellSizeMm: Double = 9.0
    /// Triangle perpendicular wall thickness (~2–4 nozzle widths), in millimetres.
    var wallThicknessMm: Double = 1.6
    /// Gyroid sheet half-thickness in field units (legacy; unused by current engine).
    var gyroidBand: Double = 0.6
    /// Gyroid·Lofted horizontal slice (layer) height in mm — the terrace size of
    /// the layered loft. Smaller = finer/smoother but slower. Lofted only.
    var loftSliceMm: Double = 0.8
    /// Marching-cubes gyroids only: run the feature-preserving de-speckle
    /// post-process that removes the isolated triangular dimples MC scatters
    /// across the smooth sheet, leaving the curves and rail edges untouched.
    var polishSurface: Bool = true
    /// Reserved for future stochastic patterns; no effect on triangle/gyroid.
    var seed: UInt64 = 1

    static let defaultValue = InfillParameters()

    init(
        cellSizeMm: Double = 9.0,
        wallThicknessMm: Double = 1.6,
        gyroidBand: Double = 0.6,
        loftSliceMm: Double = 0.8,
        polishSurface: Bool = true,
        seed: UInt64 = 1
    ) {
        self.cellSizeMm = cellSizeMm
        self.wallThicknessMm = wallThicknessMm
        self.gyroidBand = gyroidBand
        self.loftSliceMm = loftSliceMm
        self.polishSurface = polishSurface
        self.seed = seed
    }

    enum CodingKeys: String, CodingKey {
        case cellSizeMm
        case wallThicknessMm
        case gyroidBand
        case loftSliceMm
        case polishSurface
        case seed
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        let d = InfillParameters.defaultValue
        cellSizeMm = (try? c?.decodeIfPresent(Double.self, forKey: .cellSizeMm)) ?? d.cellSizeMm
        wallThicknessMm = (try? c?.decodeIfPresent(Double.self, forKey: .wallThicknessMm)) ?? d.wallThicknessMm
        gyroidBand = (try? c?.decodeIfPresent(Double.self, forKey: .gyroidBand)) ?? d.gyroidBand
        loftSliceMm = (try? c?.decodeIfPresent(Double.self, forKey: .loftSliceMm)) ?? d.loftSliceMm
        polishSurface = (try? c?.decodeIfPresent(Bool.self, forKey: .polishSurface)) ?? d.polishSurface
        seed = (try? c?.decodeIfPresent(UInt64.self, forKey: .seed)) ?? d.seed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cellSizeMm, forKey: .cellSizeMm)
        try c.encode(wallThicknessMm, forKey: .wallThicknessMm)
        try c.encode(gyroidBand, forKey: .gyroidBand)
        try c.encode(loftSliceMm, forKey: .loftSliceMm)
        try c.encode(polishSurface, forKey: .polishSurface)
        try c.encode(seed, forKey: .seed)
    }
}

enum SupportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case sculpture
    case scaffold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sculpture: return "Sculpture"
        case .scaffold: return "Scaffold"
        }
    }
}

enum SupportTargetSurface: String, CaseIterable, Identifiable, Codable, Sendable {
    case upFacing
    case downFacing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upFacing: return "Up Facing"
        case .downFacing: return "Down Facing"
        }
    }
}

enum SupportRestPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case plateOnly
    case plateAndModel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plateOnly: return "Plate Only"
        case .plateAndModel: return "Plate + Model"
        }
    }
}

struct SupportSettings: Codable, Equatable, Sendable {
    var supportMode: SupportMode = .sculpture
    var targetSurface: SupportTargetSurface = .upFacing
    var surfaceAngleDeg: Double = 40.0
    var tipSpacingMm: Double = 4.0
    var tipDiameterMm: Double = 1.2
    var branchDiameterMm: Double = 5.0
    var diameterAngleDeg: Double = 2.0
    var preferredAngleDeg: Double = 25.0
    var maxAngleDeg: Double = 40.0
    var stepMm: Double = 1.0
    var xyClearanceMm: Double = 0.8
    var contactOffsetMm: Double = 0.3
    var restPreference: SupportRestPreference = .plateOnly
    /// 0 = deterministic shortest-path growth (synthetic look); 1 = strong
    /// seeded wander so branches snake organically. Same seed, same forest.
    var variationPct: Double = 0.35

    static let defaultValue = SupportSettings()

    enum CodingKeys: String, CodingKey {
        case supportMode
        case targetSurface
        case surfaceAngleDeg
        case tipSpacingMm
        case tipDiameterMm
        case branchDiameterMm
        case diameterAngleDeg
        case preferredAngleDeg
        case maxAngleDeg
        case stepMm
        case xyClearanceMm
        case contactOffsetMm
        case restPreference
        case variationPct
    }

    /// Field-tolerant decode (mirrors StructureDensitySettings): a partial or
    /// extended payload keeps every recognizable field instead of silently
    /// resetting ALL support settings to defaults on the first unknown value.
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        let d = SupportSettings.defaultValue
        supportMode = ((try? c?.decodeIfPresent(SupportMode.self, forKey: .supportMode)) ?? nil) ?? d.supportMode
        targetSurface = ((try? c?.decodeIfPresent(SupportTargetSurface.self, forKey: .targetSurface)) ?? nil) ?? d.targetSurface
        surfaceAngleDeg = ((try? c?.decodeIfPresent(Double.self, forKey: .surfaceAngleDeg)) ?? nil) ?? d.surfaceAngleDeg
        tipSpacingMm = ((try? c?.decodeIfPresent(Double.self, forKey: .tipSpacingMm)) ?? nil) ?? d.tipSpacingMm
        tipDiameterMm = ((try? c?.decodeIfPresent(Double.self, forKey: .tipDiameterMm)) ?? nil) ?? d.tipDiameterMm
        branchDiameterMm = ((try? c?.decodeIfPresent(Double.self, forKey: .branchDiameterMm)) ?? nil) ?? d.branchDiameterMm
        diameterAngleDeg = ((try? c?.decodeIfPresent(Double.self, forKey: .diameterAngleDeg)) ?? nil) ?? d.diameterAngleDeg
        preferredAngleDeg = ((try? c?.decodeIfPresent(Double.self, forKey: .preferredAngleDeg)) ?? nil) ?? d.preferredAngleDeg
        maxAngleDeg = ((try? c?.decodeIfPresent(Double.self, forKey: .maxAngleDeg)) ?? nil) ?? d.maxAngleDeg
        stepMm = ((try? c?.decodeIfPresent(Double.self, forKey: .stepMm)) ?? nil) ?? d.stepMm
        xyClearanceMm = ((try? c?.decodeIfPresent(Double.self, forKey: .xyClearanceMm)) ?? nil) ?? d.xyClearanceMm
        contactOffsetMm = ((try? c?.decodeIfPresent(Double.self, forKey: .contactOffsetMm)) ?? nil) ?? d.contactOffsetMm
        restPreference = ((try? c?.decodeIfPresent(SupportRestPreference.self, forKey: .restPreference)) ?? nil) ?? d.restPreference
        variationPct = ((try? c?.decodeIfPresent(Double.self, forKey: .variationPct)) ?? nil) ?? d.variationPct
    }

    init(
        supportMode: SupportMode = .sculpture,
        targetSurface: SupportTargetSurface = .upFacing,
        surfaceAngleDeg: Double = 40.0,
        tipSpacingMm: Double = 4.0,
        tipDiameterMm: Double = 1.2,
        branchDiameterMm: Double = 5.0,
        diameterAngleDeg: Double = 2.0,
        preferredAngleDeg: Double = 25.0,
        maxAngleDeg: Double = 40.0,
        stepMm: Double = 1.0,
        xyClearanceMm: Double = 0.8,
        contactOffsetMm: Double = 0.3,
        restPreference: SupportRestPreference = .plateOnly,
        variationPct: Double = 0.35
    ) {
        self.supportMode = supportMode
        self.targetSurface = targetSurface
        self.surfaceAngleDeg = surfaceAngleDeg
        self.tipSpacingMm = tipSpacingMm
        self.tipDiameterMm = tipDiameterMm
        self.branchDiameterMm = branchDiameterMm
        self.diameterAngleDeg = diameterAngleDeg
        self.preferredAngleDeg = preferredAngleDeg
        self.maxAngleDeg = maxAngleDeg
        self.stepMm = stepMm
        self.xyClearanceMm = xyClearanceMm
        self.contactOffsetMm = contactOffsetMm
        self.restPreference = restPreference
        self.variationPct = variationPct
    }

    var sanitized: SupportSettings {
        var s = self
        s.surfaceAngleDeg = Self.clamp(s.surfaceAngleDeg, 5.0, 89.0, 40.0)
        s.tipSpacingMm = Self.clamp(s.tipSpacingMm, 1.0, 50.0, 4.0)
        s.tipDiameterMm = Self.clamp(s.tipDiameterMm, 0.4, 10.0, 1.2)
        s.branchDiameterMm = Self.clamp(s.branchDiameterMm, s.tipDiameterMm, 40.0, 5.0)
        s.diameterAngleDeg = Self.clamp(s.diameterAngleDeg, 0.0, 15.0, 2.0)
        s.preferredAngleDeg = Self.clamp(s.preferredAngleDeg, 5.0, 60.0, 25.0)
        s.maxAngleDeg = Self.clamp(s.maxAngleDeg, 5.0, 75.0, 40.0)
        if s.preferredAngleDeg > s.maxAngleDeg {
            s.preferredAngleDeg = s.maxAngleDeg
        }
        s.stepMm = Self.clamp(s.stepMm, 0.25, 5.0, 1.0)
        s.xyClearanceMm = Self.clamp(s.xyClearanceMm, 0.2, 5.0, 0.8)
        s.variationPct = Self.clamp(s.variationPct, 0.0, 2.0, 0.35)
        s.contactOffsetMm = Self.clamp(s.contactOffsetMm, 0.05, 2.0, 0.3)
        return s
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
        min(max(value.isFinite ? value : fallback, lo), hi)
    }
}

enum SkinStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case struts
    case perforated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .struts: return "Struts"
        case .perforated: return "Perforated"
        }
    }
}

enum SkinPattern: String, CaseIterable, Identifiable, Codable, Sendable {
    case voronoi
    case hex
    case triangles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .voronoi: return "Voronoi"
        case .hex: return "Hex"
        case .triangles: return "Triangles"
        }
    }
}

/// How the strut cage relates to the model surface. Struts are centered on the
/// surface by construction; clipping keeps only one side of it.
enum SkinClip: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case inside
    case outside

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .inside: return "Inside"
        case .outside: return "Outside"
        }
    }
}

struct SkinSettings: Codable, Equatable, Sendable {
    var skinStyle: SkinStyle = .struts
    var skinPattern: SkinPattern = .voronoi
    var strutDiameterMm: Double = 2.0
    var ribWidthMm: Double = 2.0
    var skinClip: SkinClip = .none
    /// 0 = perfectly regular cells; 1 = strongly varied cell sizes (the organic
    /// Voronoi-helmet look). Seeded — same seed, same layout.
    var variationPct: Double = 0.4
    /// Strut THICKNESS variation: a continuous position-based field (slow seeded
    /// noise + junction swell), so thickness drifts smoothly ALONG each strut —
    /// never one whole strut fat and its neighbor thin.
    var strutVariationPct: Double = 0.4

    static let defaultValue = SkinSettings()

    enum CodingKeys: String, CodingKey {
        case skinStyle
        case skinPattern
        case strutDiameterMm
        case ribWidthMm
        case skinClip
        case variationPct
        case strutVariationPct
    }

    init(
        skinStyle: SkinStyle = .struts,
        skinPattern: SkinPattern = .voronoi,
        strutDiameterMm: Double = 2.0,
        ribWidthMm: Double = 2.0,
        skinClip: SkinClip = .none,
        variationPct: Double = 0.4,
        strutVariationPct: Double = 0.4
    ) {
        self.skinStyle = skinStyle
        self.skinPattern = skinPattern
        self.strutDiameterMm = strutDiameterMm
        self.ribWidthMm = ribWidthMm
        self.skinClip = skinClip
        self.variationPct = variationPct
        self.strutVariationPct = strutVariationPct
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        let d = SkinSettings.defaultValue
        skinStyle = ((try? c?.decodeIfPresent(SkinStyle.self, forKey: .skinStyle)) ?? nil) ?? d.skinStyle
        skinPattern = ((try? c?.decodeIfPresent(SkinPattern.self, forKey: .skinPattern)) ?? nil) ?? d.skinPattern
        strutDiameterMm = ((try? c?.decodeIfPresent(Double.self, forKey: .strutDiameterMm)) ?? nil) ?? d.strutDiameterMm
        ribWidthMm = ((try? c?.decodeIfPresent(Double.self, forKey: .ribWidthMm)) ?? nil) ?? d.ribWidthMm
        skinClip = ((try? c?.decodeIfPresent(SkinClip.self, forKey: .skinClip)) ?? nil) ?? d.skinClip
        variationPct = ((try? c?.decodeIfPresent(Double.self, forKey: .variationPct)) ?? nil) ?? d.variationPct
        strutVariationPct = ((try? c?.decodeIfPresent(Double.self, forKey: .strutVariationPct)) ?? nil) ?? d.strutVariationPct
    }

    var sanitized: SkinSettings {
        var s = self
        s.strutDiameterMm = Self.clamp(s.strutDiameterMm, 0.5, 10.0, 2.0)
        s.ribWidthMm = Self.clamp(s.ribWidthMm, 0.5, 10.0, 2.0)
        s.variationPct = Self.clamp(s.variationPct, 0.0, 1.0, 0.4)
        s.strutVariationPct = Self.clamp(s.strutVariationPct, 0.0, 1.0, 0.4)
        return s
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
        min(max(value.isFinite ? value : fallback, lo), hi)
    }
}

/// Persisted Structures configuration. Decodes both the new schema and the OLD
/// façade schema without throwing:
///
/// - The legacy schema stored `intent`, `placementMode`, `family`,
///   `supportClass`, `presetID`, `includeSourceMesh`, `sourceMeshRole`,
///   `shellRelationship`, and a `pattern` whose rawValues (`honeycomb`,
///   `gyroidSheet`, `triangles`, …) do NOT map onto the new `InfillPattern`.
///   None of those keys are read; they are silently ignored.
/// - The new schema persists `category`, `patternV2` (a deliberately renamed key
///   so an old `pattern == "honeycomb"` can never fail-map), and `parameters`.
///
/// Any missing/unrecognized field falls back to a sane default (`.infill`,
/// `.triangle`, `InfillParameters.defaultValue`), so old saved projects open
/// without crashing.
struct StructureSettings: Codable, Equatable, Sendable {
    var category: StructureCategory = .infill
    var pattern: InfillPattern = .triangle
    var parameters: InfillParameters = .defaultValue
    var density: StructureDensitySettings = .defaultValue
    var support: SupportSettings = .defaultValue
    var skin: SkinSettings = .defaultValue

    static let defaultValue = StructureSettings()

    init(
        category: StructureCategory = .infill,
        pattern: InfillPattern = .triangle,
        parameters: InfillParameters = .defaultValue,
        density: StructureDensitySettings = .defaultValue,
        support: SupportSettings = .defaultValue,
        skin: SkinSettings = .defaultValue
    ) {
        self.category = category
        self.pattern = pattern
        self.parameters = parameters
        self.density = density
        self.support = support
        self.skin = skin
    }

    /// Clamp parameters into engine-safe ranges. Called by the document's
    /// `sanitized` copy so out-of-range saved/old values never reach the engine.
    var sanitized: StructureSettings {
        var s = self
        s.parameters.cellSizeMm = min(max(s.parameters.cellSizeMm, 1.0), 200.0)
        s.parameters.wallThicknessMm = min(max(s.parameters.wallThicknessMm, 0.2), 10.0)
        s.parameters.gyroidBand = min(max(s.parameters.gyroidBand, 0.1), 2.0)
        s.parameters.loftSliceMm = min(max(s.parameters.loftSliceMm, 0.2), 5.0)
        s.density = density.sanitized(defaultCellSizeMm: s.parameters.cellSizeMm)
        s.support = support.sanitized
        s.skin = skin.sanitized
        return s
    }

    enum CodingKeys: String, CodingKey {
        case category
        case parameters
        /// NEW key. The legacy `pattern` key (rawValues honeycomb/gyroidSheet/…)
        /// is intentionally NOT read so its values can never fail-map.
        case patternV2
        case density
        case support
        case skin
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        category = ((try? c?.decodeIfPresent(StructureCategory.self, forKey: .category)) ?? nil) ?? .infill
        if let raw = (try? c?.decodeIfPresent(String.self, forKey: .patternV2)) ?? nil {
            // Migrate the retired single "gyroid" (3D marching-cubes) rawValue to
            // the new Lofted generator so saved projects keep a working TPMS infill.
            if raw == "gyroid" {
                pattern = .gyroidLofted
            } else if let p = InfillPattern(rawValue: raw) {
                pattern = p
            } else {
                pattern = .triangle
            }
        } else {
            pattern = .triangle
        }
        parameters = ((try? c?.decodeIfPresent(InfillParameters.self, forKey: .parameters)) ?? nil) ?? .defaultValue
        density = ((try? c?.decodeIfPresent(StructureDensitySettings.self, forKey: .density)) ?? nil) ?? .defaultValue
        support = ((try? c?.decodeIfPresent(SupportSettings.self, forKey: .support)) ?? nil) ?? .defaultValue
        skin = ((try? c?.decodeIfPresent(SkinSettings.self, forKey: .skin)) ?? nil) ?? .defaultValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(category, forKey: .category)
        try c.encode(pattern.rawValue, forKey: .patternV2)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(density, forKey: .density)
        try c.encode(support, forKey: .support)
        try c.encode(skin, forKey: .skin)
    }
}
