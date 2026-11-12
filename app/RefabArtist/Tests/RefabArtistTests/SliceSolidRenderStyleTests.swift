import Foundation
import Testing
@testable import RefabArtist

/// Tests for the slice-solid render style — material tint mapping and
/// project-document round-trip for the `sliceSolidRenderStyle` field.
struct SliceSolidRenderStyleTests {

    // MARK: - Style identity and label

    @Test
    func allCasesHaveDistinctRawValuesAndLabels() {
        let rawValues = SliceSolidRenderStyle.allCases.map(\.rawValue)
        let labels = SliceSolidRenderStyle.allCases.map(\.label)
        #expect(Set(rawValues).count == SliceSolidRenderStyle.allCases.count)
        #expect(Set(labels).count == SliceSolidRenderStyle.allCases.count)
    }

    @Test
    func rawValueRoundTripsForAllCases() {
        for style in SliceSolidRenderStyle.allCases {
            let decoded = SliceSolidRenderStyle(rawValue: style.rawValue)
            #expect(decoded == style)
        }
    }

    // MARK: - Tint mapping per material mode

    /// Plastic: (1, 0.27, 0, 0.2) — face alpha 0.20, opaque
    /// roughness lower than wood modes (polished surface).
    @Test
    func plasticHasCorrectAlphaAndRoughness() {
        let style = SliceSolidRenderStyle.plastic
        #expect(abs(style.faceAlpha - 0.20) < 0.001)
        #expect(style.roughness < SliceSolidRenderStyle.cardboard.roughness)
        #expect(style.roughness < SliceSolidRenderStyle.plywood.roughness)
        #expect(style.isTransparent)
    }

    /// Plastic uses no per-family hue blend — single orange.
    @Test
    func plasticHasZeroFamilyBlend() {
        #expect(SliceSolidRenderStyle.plastic.familyBlend == 0.0)
    }

    /// Wood modes (cardboard/plywood) are opaque and blend some per-family hue.
    @Test
    func woodModesAreOpaqueAndHavePositiveFamilyBlend() {
        for style in [SliceSolidRenderStyle.cardboard, .plywood] {
            #expect(style.faceAlpha == 1.0)
            #expect(!style.isTransparent)
            #expect(style.familyBlend > 0.0)
        }
    }

    /// Cardboard is warmer/darker than plywood (lower red + green component
    /// on the material base color — kraft brown vs birch light face).
    @Test
    func cardboardIsDarkerThanPlywood() {
        let cardboard = SliceSolidRenderStyle.cardboard.materialBaseColor
        let plywood = SliceSolidRenderStyle.plywood.materialBaseColor
        // Plywood birch face is lighter overall — higher component values.
        guard let cRgb = cardboard.usingColorSpace(.deviceRGB),
              let pRgb = plywood.usingColorSpace(.deviceRGB) else {
            Issue.record("Color space conversion failed")
            return
        }
        #expect(cRgb.redComponent < pRgb.redComponent)
        #expect(cRgb.greenComponent < pRgb.greenComponent)
    }

    // MARK: - Project-document round-trip

    @Test
    func projectDocumentRoundTripsSliceSolidRenderStyle() throws {
        var settings = SlicerProjectSettings.sampleForRenderStyleTest
        settings.sliceSolidRenderStyle = SliceSolidRenderStyle.plywood.rawValue

        let document = SlicerProjectDocument(modelPath: "/tmp/cube.stl", settings: settings)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)

        #expect(decoded.settings.sliceSolidRenderStyle == "plywood")
        #expect(SliceSolidRenderStyle(rawValue: decoded.settings.sliceSolidRenderStyle ?? "") == .plywood)
    }

    @Test
    func projectDocumentRoundTripsAllThreeStyles() throws {
        for style in SliceSolidRenderStyle.allCases {
            var settings = SlicerProjectSettings.sampleForRenderStyleTest
            settings.sliceSolidRenderStyle = style.rawValue
            let document = SlicerProjectDocument(modelPath: "/tmp/cube.stl", settings: settings)
            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
            #expect(decoded.settings.sliceSolidRenderStyle == style.rawValue)
        }
    }

    /// Legacy project files without `sliceSolidRenderStyle` decode to nil
    /// (the caller defaults to .cardboard).
    @Test
    func legacyProjectFilesDecodeRenderStyleAsNil() throws {
        let encoded = """
        {
          "constructionMode": "stacked",
          "sliceAxis": "z",
          "secondarySliceAxis": "x",
          "materialThickness": 3,
          "slotClearance": 0.15,
          "slotAngleDegrees": 12,
          "radialSliceCount": 16,
          "curveSliceCount": 10,
          "curveAmplitude": 8,
          "materialPreset": "plywood3mm",
          "slotReliefEnabled": false,
          "slotReliefDiameter": 3,
          "dowelsEnabled": false,
          "dowelDiameter": 4,
          "dowelInset": 8,
          "exportFormat": "dxf",
          "exportLayoutSettings": {
            "partSpacing": 5,
            "pageMargin": 10,
            "sheetWidth": 600,
            "sheetHeight": 300
          },
          "modelScaleFactor": 1.0,
          "importUnit": "millimeters",
          "customSliceDistributionEnabled": false,
          "customSliceCount": 12
        }
        """
        let decoded = try JSONDecoder().decode(SlicerProjectSettings.self, from: Data(encoded.utf8))
        // No key present → nil → caller defaults to .cardboard
        #expect(decoded.sliceSolidRenderStyle == nil)
        let style = decoded.sliceSolidRenderStyle.flatMap(SliceSolidRenderStyle.init(rawValue:)) ?? .cardboard
        #expect(style == .cardboard)
    }

    /// Unknown raw values are dropped to nil by sanitize (forward-compat).
    @Test
    func unknownRenderStyleRawValueSanitizesToNil() {
        var settings = SlicerProjectSettings.sampleForRenderStyleTest
        settings.sliceSolidRenderStyle = "crystal"
        let sanitized = settings.sanitized
        #expect(sanitized.sliceSolidRenderStyle == nil)
    }

    /// Known raw values survive sanitize unchanged.
    @Test
    func knownRenderStyleRawValueSurvivesSanitize() {
        for style in SliceSolidRenderStyle.allCases {
            var settings = SlicerProjectSettings.sampleForRenderStyleTest
            settings.sliceSolidRenderStyle = style.rawValue
            let sanitized = settings.sanitized
            #expect(sanitized.sliceSolidRenderStyle == style.rawValue)
        }
    }
}

// MARK: - Test fixture

private extension SlicerProjectSettings {
    /// Minimal valid settings for render-style tests — values chosen so
    /// `.sanitized` doesn't alter them, preventing false failures.
    static let sampleForRenderStyleTest = SlicerProjectSettings(
        constructionMode: .stacked,
        sliceAxis: .z,
        secondarySliceAxis: .x,
        materialThickness: 3.0,
        threeDSliceDepth: 10.0,
        slotClearance: 0.15,
        slotAngleDegrees: 12.0,
        radialSliceCount: 16,
        curveSliceCount: 10,
        curveAmplitude: 8.0,
        materialPreset: .plywood3mm,
        slotReliefEnabled: false,
        slotReliefDiameter: 3.0,
        dowelsEnabled: false,
        dowelDiameter: 4.0,
        dowelInset: 8.0,
        exportFormat: .dxf,
        exportLayoutSettings: .defaultValue,
        modelScaleFactor: 1.0,
        importUnit: .millimeters,
        customSliceDistributionEnabled: false,
        customSliceCount: 12
    )
}
