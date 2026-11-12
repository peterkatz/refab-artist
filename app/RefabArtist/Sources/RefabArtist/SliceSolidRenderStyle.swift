import AppKit

/// Visual render style for the slice-solid preview in the 3D viewport, one
/// of three material modes:
///
/// - `cardboard`: tan/warm-brown face + opaque edges, drawn with a warm PBR
///   tint (roughness 0.88 — matte corrugated surface).
///   Chosen values: baseColor ≈ (0.72, 0.56, 0.36) — standard brown-kraft
///   cardboard; slightly desaturated so it reads clearly against the viewport
///   background even under the warm key light.
///
/// - `plywood`: lighter wood-birch face + opaque edges, drawn with a
///   lighter warm tint (roughness 0.82 — smooth sanded surface).
///   Chosen values: baseColor ≈ (0.82, 0.70, 0.50) — birch-ply light face
///   grain; close to the existing `fabricationPanelTint` warm blend but
///   less tinted toward the per-family hue so it reads as material, not
///   assignment.
///
/// - `plastic`: RGBA (1, 0.27, 0, 0.2) face + (1, 0.27, 0, 1) edge —
///   orange, 20% alpha faces with opaque edges, like translucent acrylic.
///   No PBR roughness dodge: the face is transparent orange with opaque
///   orange edges, drawn as transparent blended PBR.
///
/// The style is orthogonal to per-family color: in `.cardboard` / `.plywood`
/// mode the family hue tints the base material color (so different families
/// still read as different slices), scaled back so the material reads clearly.
/// In `.plastic` mode every family uses the same single orange.
enum SliceSolidRenderStyle: String, CaseIterable, Identifiable, Codable {
    case cardboard
    case plywood
    case plastic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cardboard: return "Cardboard"
        case .plywood: return "Plywood"
        case .plastic: return "Plastic"
        }
    }

    // MARK: - PBR parameters

    /// Face base color tint for the NORMAL (non-selected, non-future) state,
    /// blended toward the per-family hue by `familyBlend`. The family hue is
    /// NSColor from solidPalette; this returns the material base without it.
    var materialBaseColor: NSColor {
        switch self {
        case .cardboard:
            // Kraft-brown, warm, matte
            return NSColor(calibratedRed: 0.72, green: 0.56, blue: 0.36, alpha: 1.0)
        case .plywood:
            // Birch-ply light face — warm but lighter than cardboard
            return NSColor(calibratedRed: 0.82, green: 0.70, blue: 0.50, alpha: 1.0)
        case .plastic:
            // (1, 0.27, 0) — orange, 20% alpha face
            return NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.0, alpha: 0.20)
        }
    }

    /// How strongly the per-family palette hue bleeds through the material color.
    /// Plastic = 0 (single orange, no per-family tint).
    /// Wood modes = 0.22 (enough to distinguish families without washing out the wood look).
    var familyBlend: CGFloat {
        switch self {
        case .cardboard, .plywood: return 0.22
        case .plastic: return 0.0
        }
    }

    var roughness: Float {
        switch self {
        case .cardboard: return 0.88
        case .plywood: return 0.82
        case .plastic: return 0.30
        }
    }

    var isTransparent: Bool {
        switch self {
        case .plastic: return true
        case .cardboard, .plywood: return false
        }
    }

    /// The face alpha for a non-selected, normal-state solid.
    var faceAlpha: CGFloat {
        switch self {
        case .cardboard, .plywood: return 1.0
        case .plastic: return 0.20
        }
    }
}
