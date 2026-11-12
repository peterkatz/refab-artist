import Foundation
import Testing
@testable import RefabArtist

struct ImportUnitDetectionTests {
    @Test
    func keepsMillimetersForPlausibleModel() {
        // Correctly-authored mm models must never be rescaled.
        #expect(MeshScaler.bestFitUnit(forLongestDimension: 50) == .millimeters)
        #expect(MeshScaler.bestFitUnit(forLongestDimension: 200) == .millimeters)
        #expect(MeshScaler.bestFitUnit(forLongestDimension: 500) == .millimeters)
    }

    @Test
    func rescalesTinyModelIntoCuttableRange() {
        // A ~2-unit export (meters/unitless) is 2 mm as-mm — a useless speck.
        // Detection must pick a unit that lands it in a plausible cuttable size.
        for longest in [2.0, 1.0, 0.5] {
            let unit = MeshScaler.bestFitUnit(forLongestDimension: longest)
            #expect(unit != .millimeters)
            let spanMM = longest * MeshScaler.combinedFactor(unit: unit, userScale: 1.0)
            #expect(MeshScaler.plausibleImportSpanMM.contains(spanMM))
        }
    }

    @Test
    func degenerateInputsKeepMillimeters() {
        #expect(MeshScaler.bestFitUnit(forLongestDimension: 0) == .millimeters)
        #expect(MeshScaler.bestFitUnit(forLongestDimension: -5) == .millimeters)
        #expect(MeshScaler.bestFitUnit(forLongestDimension: .nan) == .millimeters)
    }
}
