import Foundation
import Testing
@testable import RefabArtist

/// The viewport's Stacked dowel rods, edit markers and the automatic
/// positions manual editing starts from are the placements the exports
/// drill: on a cracked scan, through the layers closed across the cracks.
struct StackedViewportDowelTests {
    @Test(arguments: [3.0, 5.0])
    func viewportDowelsSitWhereTheExportsDrill(_ thickness: Double) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try MeshInspector.inspect(url: root.appending(path: "tests/fixtures/pathological/lumpy_blob_open_poles.stl"))
        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: thickness))
        for count in [2, 4] {
            let settings = DxfExporter.DowelSettings(
                enabled: true, diameter: DowelShape.round.defaultDiameter, inset: 6,
                manualPositions: nil, shape: .round, automaticCount: count
            )
            // What the cut sheet and every export drill.
            let drilled = DowelLayout.placements(
                layers: StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan)).layers,
                settings: settings
            )
            let shown = ViewportGeometryCache.shared.dowelPlacements(model: model, plan: plan, settings: settings)
            #expect(shown == drilled, "\(thickness) mm, \(count) rods")
            #expect(!shown.isEmpty)
            if thickness == 3 {
                // Here the open sections would place the rods elsewhere, so
                // this is the cracked case and not a coincidence.
                let open = DowelLayout.placements(
                    layers: ViewportGeometryCache.shared.stackedContours(model: model, plan: plan).layers,
                    settings: settings
                )
                #expect(open != drilled, "\(count) rods")
            }
        }
    }

    /// The slice solids the viewport shows are the layers the cut sheet and
    /// every export cut: on a cracked scan, closed across the cracks.
    @Test(arguments: [3.0, 5.0])
    func viewportSlicesAreTheLayersTheExportsCut(_ thickness: Double) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try MeshInspector.inspect(url: root.appending(path: "tests/fixtures/pathological/lumpy_blob_open_poles.stl"))
        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: thickness))
        // What the cut sheet and every export cut (`FlatPartExport`,
        // `StackedSliceContourer.closingCracks`).
        let cut = StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: plan))
        let shown = ViewportGeometryCache.shared.stackedSolidMeshes(model: model, plan: plan)
        #expect(shown.map(\.layerIndex) == Array(cut.layers.indices).filter {
            ViewportSliceSolidRenderData.mesh(contours: cut, layerIndex: $0, materialThickness: thickness) != nil
        })
        for (layerIndex, mesh) in shown {
            #expect(mesh == ViewportSliceSolidRenderData.mesh(contours: cut, layerIndex: layerIndex, materialThickness: thickness),
                    "\(thickness) mm layer \(layerIndex)")
        }
        // The open sections would show other solids on the cracked layers,
        // so this is the cracked case and not a coincidence.
        let open = StackedSliceContourer.generate(model: model, plan: plan)
        let differing = shown.filter { layerIndex, mesh in
            mesh != ViewportSliceSolidRenderData.mesh(contours: open, layerIndex: layerIndex, materialThickness: thickness)
        }
        #expect(!differing.isEmpty, "\(thickness) mm")
        // The pick test and the slice profile read the same closed layers.
        #expect(ViewportGeometryCache.shared.stackedClosedContours(model: model, plan: plan) == cut)
    }
}
