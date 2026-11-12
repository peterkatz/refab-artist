import Foundation
import Testing
@testable import RefabArtist

struct ViewportAppearanceSettingsTests {
    @Test
    func signatureChangesWithMaterialColorAndBackdrop() {
        let base = ViewportAppearanceSettings.defaultLook
        var other = base
        other.material = .glossy
        other.objectColor = WorkspaceRGBA(red: 0.1, green: 0.5, blue: 0.6)
        other.backdrop = .graphite

        #expect(base.signature != other.signature)
        // Material and colour are part of the identity used to rebuild the scene.
        var colorOnly = base
        colorOnly.objectColor = WorkspaceRGBA(red: 0.9, green: 0.2, blue: 0.2)
        #expect(colorOnly.signature != base.signature)
    }

    @Test
    func eachMaterialMapsToADistinctCapture() {
        let names = ViewportAppearanceSettings.ObjectMaterial.allCases.map(\.captureName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("matcap_") })
    }

    @Test
    func defaultLookIsClayPlasterOnCoolBackdrop() {
        let look = ViewportAppearanceSettings.defaultLook
        #expect(look.material == .clay)
        #expect(look.backdrop == .cool)
        #expect(look.groundShadow == 0.50)
        #expect(look.vignette == 0.40)
        // Slice lighting rig preserved (model is MatCap-shaded and ignores it).
        #expect(look.keyLight >= 0.70)
        #expect(look.edgeStrength == 0)
    }

    @Test
    func clampKeepsViewportSlidersInRange() {
        #expect(ViewportAppearanceSettings.clamped01(-4) == 0)
        #expect(ViewportAppearanceSettings.clamped01(0.42) == 0.42)
        #expect(ViewportAppearanceSettings.clamped01(12) == 1)
    }

    @Test
    func storeRoundTripsMaterialAndCustomColor() throws {
        let suite = ThrowawayDefaults("refabartist-viewport-appearance-test")
        defer { suite.remove() }
        #expect(suite.staysOutOfUserPreferences)
        let defaults = suite.defaults
        // Nothing stored → the default look.
        #expect(ViewportAppearanceStore.load(from: defaults) == .defaultLook)

        var custom = ViewportAppearanceSettings.defaultLook
        custom.material = .toon
        custom.objectColor = WorkspaceRGBA(red: 0.13, green: 0.52, blue: 0.55)
        custom.backdrop = .graphite
        ViewportAppearanceStore.save(custom, to: defaults)

        #expect(ViewportAppearanceStore.load(from: defaults) == custom)
    }
}
