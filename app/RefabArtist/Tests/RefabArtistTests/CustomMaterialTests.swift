import Foundation
import Testing
@testable import RefabArtist

struct CustomMaterialTests {
    @Test
    func storeRoundTripsMaterials() {
        let suite = ThrowawayDefaults("refabartist-custom-material-test")
        defer { suite.remove() }
        #expect(suite.staysOutOfUserPreferences)
        let defaults = suite.defaults

        #expect(CustomMaterialStore.load(from: defaults).isEmpty)

        let materials = [
            CustomMaterial(name: "Baltic Birch 6 mm", thickness: 6.0, slotClearance: 0.1, sheetWidth: 600, sheetHeight: 300),
            CustomMaterial(name: "Luan 5.2 mm", thickness: 5.2, slotClearance: 0.15, sheetWidth: 1220, sheetHeight: 2440)
        ]
        CustomMaterialStore.save(materials, to: defaults)
        let loaded = CustomMaterialStore.load(from: defaults)
        #expect(loaded == materials)
    }

    @Test
    func matchingIsExactOnAllFourValues() {
        let material = CustomMaterial(name: "m", thickness: 6, slotClearance: 0.1, sheetWidth: 600, sheetHeight: 300)
        #expect(material.matches(thickness: 6, slotClearance: 0.1, sheetWidth: 600, sheetHeight: 300))
        #expect(!material.matches(thickness: 6.5, slotClearance: 0.1, sheetWidth: 600, sheetHeight: 300))
        #expect(!material.matches(thickness: 6, slotClearance: 0.1, sheetWidth: 600, sheetHeight: 299))
    }

    // MARK: - NEO-105 new field backward-compat

    @Test
    func legacyJsonMissingNewFieldsDecodesWithDefaults() throws {
        // Legacy JSON has only the original 4 fields.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Old","thickness":6.0,"slotClearance":0.1,"sheetWidth":600,"sheetHeight":300}
        """
        let m = try JSONDecoder().decode(CustomMaterial.self, from: Data(json.utf8))
        #expect(m.name == "Old")
        #expect(m.thickness == 6.0)
        // New-field defaults: kerf=0.254 (0.01"), toolDiameter=0, margins=0.254
        #expect(m.kerf == 0.254)
        #expect(m.toolDiameter == 0.0)
        #expect(m.horizontalMargin == 0.254)
        #expect(m.verticalMargin == 0.254)
    }

    @Test
    func fullRoundTripPreservesAllEightFields() throws {
        let m = CustomMaterial(
            name: "Full",
            thickness: 4.5,
            slotClearance: 0.2,
            sheetWidth: 384,
            sheetHeight: 384,
            kerf: 0.3,
            toolDiameter: 3.175,
            horizontalMargin: 5.08,
            verticalMargin: 5.08
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(CustomMaterial.self, from: data)
        #expect(decoded == m)
    }

    // MARK: - NEO-105 Built-in presets

    @Test
    func builtInPresetsCount14() {
        #expect(BuiltInMaterialPreset.allCases.count == 14)
    }

    @Test
    func letterPresetValuesMatchUSLetterSheet() {
        let m = BuiltInMaterialPreset.letter.material
        // US Letter: width=8.5", height=11.0", depth=0.1772", margins=0.2"
        // kerf=0.01"=0.254mm, toolDiameter=0
        #expect(abs(m.sheetWidth  - 8.5  * 25.4) < 0.001)
        #expect(abs(m.sheetHeight - 11.0 * 25.4) < 0.001)
        #expect(abs(m.thickness   - 0.1772 * 25.4) < 0.001)
        #expect(abs(m.horizontalMargin - 0.2 * 25.4) < 0.001)
        #expect(abs(m.verticalMargin   - 0.2 * 25.4) < 0.001)
        #expect(abs(m.kerf - 0.254) < 0.001)
        #expect(m.toolDiameter == 0.0)
    }

    @Test
    func p2PresetHasZeroMargins() {
        // P2 is the ONLY preset with zero margins
        let m = BuiltInMaterialPreset.p2.material
        #expect(m.horizontalMargin == 0.0)
        #expect(m.verticalMargin   == 0.0)
        #expect(abs(m.sheetWidth  - 384.0) < 0.001)
        #expect(abs(m.sheetHeight - 384.0) < 0.001)
        #expect(abs(m.thickness   -   4.5) < 0.001)
    }

    @Test
    func pSeriesPresetsAreMm() {
        // P-series: native mm values
        let p1 = BuiltInMaterialPreset.p1.material
        #expect(abs(p1.sheetWidth  - 181.0) < 0.001)
        #expect(abs(p1.sheetHeight - 181.0) < 0.001)
        #expect(abs(p1.thickness   -   4.5) < 0.001)
        #expect(abs(p1.horizontalMargin - 0.2) < 0.001)

        let p3 = BuiltInMaterialPreset.p3.material
        #expect(abs(p3.sheetWidth  - 384.0) < 0.001)
        #expect(abs(p3.sheetHeight - 790.0) < 0.001)
    }

    @Test
    func b1PresetDimensionsMatchISOB1() {
        // ISO B1: 27.83" x 39.37"
        let m = BuiltInMaterialPreset.b1.material
        #expect(abs(m.sheetWidth  - 27.83 * 25.4) < 0.01)
        #expect(abs(m.sheetHeight - 39.37 * 25.4) < 0.01)
    }

    @Test
    func allBuiltInPresetsHaveNonEmptyLabel() {
        for preset in BuiltInMaterialPreset.allCases {
            #expect(!preset.label.isEmpty)
        }
    }

    @Test
    func builtInPresetsCarryKerfIntoSlotGeometryField() {
        // NEO-116: Slot Offset (kerf) IS the slot-geometry field. A built-in
        // preset must put its kerf into slotClearance, not just the mirror —
        // otherwise picking it applies a zero offset and slots come out at
        // exactly material thickness (every built-in carries 0.254 mm).
        let kerfMm = 0.01 * 25.4   // 0.254 mm
        for preset in BuiltInMaterialPreset.allCases {
            let m = preset.material
            #expect(abs(m.slotClearance - kerfMm) < 0.001)
            #expect(abs(m.slotClearance - m.kerf) < 0.001)
        }
    }
}
