import Testing
@testable import RefabArtist

struct MaterialPresetTests {
    @Test
    func materialPresetsExposeConservativeThicknessAndKerfDefaults() {
        #expect(MaterialPreset.custom.values == nil)
        #expect(MaterialPreset.cardboard3mm.values == .init(thickness: 3.0, slotClearance: 0.15))
        #expect(MaterialPreset.plywood3mm.values == .init(thickness: 3.0, slotClearance: 0.10))
        #expect(MaterialPreset.plywood6mm.values == .init(thickness: 6.0, slotClearance: 0.15))
        #expect(MaterialPreset.acrylic3mm.values == .init(thickness: 3.0, slotClearance: 0.20))
    }

    @Test
    func applyingPresetUpdatesEditableMaterialSettings() {
        var settings = MaterialSettings(thickness: 2.0, slotClearance: -0.05)

        settings.apply(.plywood6mm)

        #expect(settings.thickness == 6.0)
        #expect(settings.slotClearance == 0.15)

        settings.apply(.custom)

        #expect(settings.thickness == 6.0)
        #expect(settings.slotClearance == 0.15)
    }

    @Test
    func stockSheetPresetsExposeStandardManufacturingSizes() {
        #expect(StockSheetPreset.custom.size == nil)
        #expect(StockSheetPreset.letter.size == .init(width: 215.9, height: 279.4))
        #expect(StockSheetPreset.a4.size == .init(width: 210.0, height: 297.0))
        #expect(StockSheetPreset.twelveByTwelve.size == .init(width: 304.8, height: 304.8))
        #expect(StockSheetPreset.twentyFourByTwelve.size == .init(width: 609.6, height: 304.8))
        #expect(StockSheetPreset.twentyFourByTwentyFour.size == .init(width: 609.6, height: 609.6))
    }

    @Test
    func stockSheetPresetMatchingFallsBackToCustom() {
        #expect(StockSheetPreset.matching(width: 215.9, height: 279.4) == .letter)
        #expect(StockSheetPreset.matching(width: 215.905, height: 279.395) == .letter)
        #expect(StockSheetPreset.matching(width: 600, height: 300) == .custom)
    }
}
