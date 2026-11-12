import Foundation
import SwiftUI

struct ViewportAppearanceSettings: Equatable, Codable {
    /// The MatCap *style* — the surface character (how light plays across it),
    /// baked as a neutral grayscale lit-sphere. The object colour is applied on
    /// top in-shader, so any style works in any colour.
    enum ObjectMaterial: String, CaseIterable, Identifiable, Codable {
        case clay
        case satin
        case glossy
        case toon

        var id: String { rawValue }

        var label: String {
            switch self {
            case .clay: return "Clay"
            case .satin: return "Satin"
            case .glossy: return "Glossy"
            case .toon: return "Toon"
            }
        }

        /// Bundled neutral lit-sphere capture for this style.
        var captureName: String { "matcap_\(rawValue)" }
    }

    /// A few one-tap object colours; users can pick any colour via the well.
    static let quickColors: [WorkspaceRGBA] = [
        WorkspaceRGBA(red: 0.80, green: 0.77, blue: 0.72), // plaster
        WorkspaceRGBA(red: 0.80, green: 0.45, blue: 0.30), // terracotta
        WorkspaceRGBA(red: 0.62, green: 0.66, blue: 0.70), // slate
        WorkspaceRGBA(red: 0.13, green: 0.52, blue: 0.55), // teal
        WorkspaceRGBA(red: 0.85, green: 0.83, blue: 0.80), // porcelain
        WorkspaceRGBA(red: 0.30, green: 0.32, blue: 0.36)  // graphite
    ]

    enum Backdrop: String, CaseIterable, Identifiable, Codable {
        case light
        case cool
        case paper
        case graphite

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Light"
            case .cool: return "Cool"
            case .paper: return "Paper"
            case .graphite: return "Graphite"
            }
        }

        func color(for colorScheme: ColorScheme) -> WorkspaceRGBA {
            switch (self, colorScheme) {
            case (.light, .dark):
                return WorkspaceRGBA(red: 0.14, green: 0.15, blue: 0.16)
            case (.light, _):
                return WorkspaceRGBA(red: 0.74, green: 0.77, blue: 0.77)
            case (.cool, .dark):
                return WorkspaceRGBA(red: 0.12, green: 0.15, blue: 0.17)
            case (.cool, _):
                return WorkspaceRGBA(red: 0.58, green: 0.65, blue: 0.68)
            case (.paper, .dark):
                return WorkspaceRGBA(red: 0.15, green: 0.14, blue: 0.13)
            case (.paper, _):
                return WorkspaceRGBA(red: 0.78, green: 0.76, blue: 0.70)
            case (.graphite, _):
                return WorkspaceRGBA(red: 0.24, green: 0.26, blue: 0.26)
            }
        }
    }

    var material: ObjectMaterial
    var objectColor: WorkspaceRGBA
    var edgeStrength: Double
    var keyLight: Double
    var fillLight: Double
    var rimLight: Double
    var backdrop: Backdrop
    var groundShadow: Double
    var vignette: Double

    /// The out-of-the-box look: the soft clay plaster sculpt on a cool backdrop.
    static let defaultLook = ViewportAppearanceSettings(
        material: .clay,
        objectColor: WorkspaceRGBA(red: 0.80, green: 0.77, blue: 0.72),
        edgeStrength: 0.00,
        // The imported MODEL is MatCap-shaded (see ViewportMatcapMaterial) and
        // ignores these lights; the directional rig lights the SLICE/panel solids.
        keyLight: 0.75,
        fillLight: 0.10,
        rimLight: 0.54,
        backdrop: .cool,
        groundShadow: 0.50,
        vignette: 0.40
    )

    var signature: String {
        [
            material.rawValue,
            Self.format(objectColor.red),
            Self.format(objectColor.green),
            Self.format(objectColor.blue),
            Self.format(edgeStrength),
            Self.format(keyLight),
            Self.format(fillLight),
            Self.format(rimLight),
            backdrop.rawValue,
            Self.format(groundShadow),
            Self.format(vignette)
        ].joined(separator: ":")
    }

    static func clamped01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// Persists the viewport appearance so a user's tweaks (backdrop, shadow,
/// vignette, tint, lighting…) come back on the next launch. Falls back to the
/// Sculpt default when nothing is stored or a stored blob predates a schema
/// change (a failed decode must not wipe the viewport).
enum ViewportAppearanceStore {
    static let defaultsKey = "viewportAppearance"

    static func load(from defaults: UserDefaults = .standard) -> ViewportAppearanceSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ViewportAppearanceSettings.self, from: data) else {
            return .defaultLook
        }
        return decoded
    }

    static func save(_ settings: ViewportAppearanceSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
