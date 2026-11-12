import Foundation
import Testing
@testable import RefabArtist

/// Manual dowel placement: clicking the cut sheet maps back to PLAN
/// coordinates (undoing the packer's translation/rotation), manual positions
/// override automatic placement, and they survive a project save/load.
struct DowelPlacementEditingTests {
    private static func square(at origin: Vec2, size: Double) -> SlicePath2D {
        SlicePath2D(
            points: [
                Vec2(x: origin.x, y: origin.y),
                Vec2(x: origin.x + size, y: origin.y),
                Vec2(x: origin.x + size, y: origin.y + size),
                Vec2(x: origin.x, y: origin.y + size),
                Vec2(x: origin.x, y: origin.y)
            ],
            closed: true
        )
    }

    private static func rectangle(width: Double, height: Double) -> SlicePath2D {
        SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: width, y: 0),
                Vec2(x: width, y: height),
                Vec2(x: 0, y: height),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )
    }

    // MARK: - Sheet click -> plan position (planPoint inverse)

    @Test
    func dowelCircleOnSheetMapsBackToManualPlanPosition() {
        // Two stacked squares, one manual rod at plan (10, 10). The packer
        // translates each part onto the sheet; the drawn hole circle must map
        // back to the rod's plan position through planPoint(fromSheetPoint:).
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)]),
                SliceContourLayer(position: 3, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)])
            ]
        )
        let dowels = DxfExporter.DowelSettings(
            enabled: true,
            diameter: 4,
            inset: 2,
            manualPositions: [Vec2(x: 10, y: 10)]
        )
        let settings = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 100, sheetHeight: 100)
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: settings, dowels: dowels, revision: 1)

        let parts = document.sheets.flatMap(\.parts)
        #expect(parts.count == 2)
        for part in parts {
            #expect(part.circles.count == 1)
            guard let circle = part.circles.first else { continue }
            let plan = part.planPoint(fromSheetPoint: circle.center)
            #expect(abs(plan.x - 10) < 1e-9)
            #expect(abs(plan.y - 10) < 1e-9)
        }
    }

    @Test
    func planPointInvertsRotatedPlacement() {
        // An 80x20 part on a 30-wide sheet only fits rotated, so this pins
        // the rotated branch of the inverse transform.
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [Self.rectangle(width: 80, height: 20)]),
                SliceContourLayer(position: 3, paths: [Self.rectangle(width: 80, height: 20)])
            ]
        )
        let dowels = DxfExporter.DowelSettings(
            enabled: true,
            diameter: 4,
            inset: 2,
            manualPositions: [Vec2(x: 12, y: 7)]
        )
        let settings = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 30, sheetHeight: 90)
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: settings, dowels: dowels, revision: 1)

        let parts = document.sheets.flatMap(\.parts)
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.rotatedOnSheet })
        for part in parts {
            #expect(part.circles.count == 1)
            guard let circle = part.circles.first else { continue }
            let plan = part.planPoint(fromSheetPoint: circle.center)
            #expect(abs(plan.x - 12) < 1e-9)
            #expect(abs(plan.y - 7) < 1e-9)
        }
    }

    // MARK: - Manual positions override automatic placement

    @Test
    func manualPositionsOverrideAutomaticAndSpanCoveredLayers() {
        let layers = [
            SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)]),
            SliceContourLayer(position: 3, paths: [Self.square(at: Vec2(x: 50, y: 0), size: 20)]),
            SliceContourLayer(position: 6, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)])
        ]
        let settings = DxfExporter.DowelSettings(
            enabled: true,
            diameter: 4,
            inset: 2,
            manualPositions: [
                Vec2(x: 10, y: 10),   // covered by layers 0 and 2
                Vec2(x: 55, y: 5),    // covered only by layer 1
                Vec2(x: 200, y: 200)  // covered by nothing -> dropped
            ]
        )
        let placements = DowelLayout.placements(layers: layers, settings: settings)
        #expect(placements.count == 2)
        #expect(placements[0].position == Vec2(x: 10, y: 10))
        #expect(placements[0].firstLayer == 0)
        #expect(placements[0].lastLayer == 2)
        #expect(placements[1].position == Vec2(x: 55, y: 5))
        #expect(placements[1].firstLayer == 1)
        #expect(placements[1].lastLayer == 1)
    }

    @Test
    func automaticCountStandsThatManySeparatedRods() {
        let layers = [
            SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 100)]),
            SliceContourLayer(position: 3, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 100)])
        ]
        for count in [1, 3, 4, 6] {
            var settings = DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 2)
            settings.automaticCount = count
            let placements = DowelLayout.placements(layers: layers, settings: settings)
            #expect(placements.count == count)
            // All distinct positions.
            for i in placements.indices {
                for j in placements.indices where j > i {
                    let dx = placements[i].position.x - placements[j].position.x
                    let dy = placements[i].position.y - placements[j].position.y
                    #expect((dx * dx + dy * dy).squareRoot() > 1.0)
                }
            }
        }
        // Default stays 2 (existing fixtures depend on it).
        let defaults = DowelLayout.placements(
            layers: layers,
            settings: DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 2)
        )
        #expect(defaults.count == 2)
    }

    @Test
    func emptyManualListMeansZeroRodsAndNilMeansAutomatic() {
        // NEO-113: an EMPTY manual list is "the user deleted every rod" and
        // must stay empty — the old fallback to automatic resurrected deleted
        // dowels. Automatic placement is requested with nil.
        let layers = [
            SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 40)]),
            SliceContourLayer(position: 3, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 40)])
        ]
        var settings = DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 2)
        settings.manualPositions = []
        let deletedAll = DowelLayout.placements(layers: layers, settings: settings)
        #expect(deletedAll.isEmpty)

        settings.manualPositions = nil
        let automatic = DowelLayout.placements(layers: layers, settings: settings)
        #expect(!automatic.isEmpty)
    }

    // MARK: - Persistence

    @Test
    func projectSettingsRoundTripManualDowelPositions() throws {
        var settings = SlicerProjectSettings(
            constructionMode: .stacked,
            sliceAxis: .z,
            secondarySliceAxis: .x,
            materialThickness: 3,
            slotClearance: 0.1,
            slotAngleDegrees: 0,
            radialSliceCount: 12,
            curveSliceCount: 7,
            curveAmplitude: 10,
            materialPreset: .custom,
            slotReliefEnabled: false,
            slotReliefDiameter: 2,
            dowelsEnabled: true,
            dowelDiameter: 6,
            dowelInset: 8,
            exportFormat: .dxf,
            exportLayoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 600, sheetHeight: 400),
            modelScaleFactor: 1,
            importUnit: .millimeters,
            customSliceDistributionEnabled: false,
            customSliceCount: 10
        )
        settings.dowelManualPositions = [10, 20, 30.5, 40.25]
        settings.dowelAutomaticCount = 5
        settings.dowelUseAutomatic = false

        let decoded = try JSONDecoder().decode(
            SlicerProjectSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.dowelManualPositions == [10, 20, 30.5, 40.25])
        #expect(decoded.dowelAutomaticCount == 5)
        #expect(decoded.dowelUseAutomatic == false)
        // Out-of-range counts clamp on sanitize; legacy nils stay nil.
        settings.dowelAutomaticCount = 99
        #expect(settings.sanitized.dowelAutomaticCount == 12)

        // Legacy documents without the key keep decoding (nil -> automatic).
        var legacy = settings
        legacy.dowelManualPositions = nil
        let legacyDecoded = try JSONDecoder().decode(
            SlicerProjectSettings.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(legacyDecoded.dowelManualPositions == nil)
    }

    @Test
    func sanitizedDropsUnpairedAndNonFinitePositions() {
        var settings = SlicerProjectSettings(
            constructionMode: .stacked,
            sliceAxis: .z,
            secondarySliceAxis: .x,
            materialThickness: 3,
            slotClearance: 0.1,
            slotAngleDegrees: 0,
            radialSliceCount: 12,
            curveSliceCount: 7,
            curveAmplitude: 10,
            materialPreset: .custom,
            slotReliefEnabled: false,
            slotReliefDiameter: 2,
            dowelsEnabled: true,
            dowelDiameter: 6,
            dowelInset: 8,
            exportFormat: .dxf,
            exportLayoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 600, sheetHeight: 400),
            modelScaleFactor: 1,
            importUnit: .millimeters,
            customSliceDistributionEnabled: false,
            customSliceCount: 10
        )
        settings.dowelManualPositions = [10, 20, .infinity, 5, 30, 40, 99]
        #expect(settings.sanitized.dowelManualPositions == [10, 20, 30, 40])

        settings.dowelManualPositions = [.nan, 1]
        #expect(settings.sanitized.dowelManualPositions == nil)
    }
}
