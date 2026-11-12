import Foundation
import Testing
@testable import RefabArtist

struct AssemblyGuideExporterTests {
    @Test
    func documentIncludesModeMaterialAndSteps() {
        let context = AssemblyGuideContext(
            modelName: "cube-50mm.stl",
            constructionMode: .interlocked,
            materialThickness: 3.0,
            slotClearance: 0.15,
            slotAngleDegrees: 12.5,
            dowelsEnabled: true,
            dowelDiameter: 4.0,
            dowelInset: 8.0
        )
        let steps = [
            AssemblyStep(index: 1, title: "Place primary_001", detail: "Z family at -10 mm."),
            AssemblyStep(index: 2, title: "Insert secondary_001", detail: "X family at 0 mm; mesh through matching primary slots.")
        ]

        let document = AssemblyGuideExporter.document(context: context, steps: steps)

        #expect(document.contains("Refab Artist Assembly Guide"))
        #expect(document.contains("Model: cube-50mm.stl"))
        #expect(document.contains("Mode: Interlocked"))
        #expect(document.contains("Material thickness: 3 mm"))
        #expect(document.contains("Slot clearance: 0.15 mm"))
        #expect(document.contains("Slot angle: 12.5 degrees"))
        // Dowels are a Stacked feature.
        #expect(!document.contains("Dowels"))
        #expect(document.contains("Step count: 2"))
        #expect(document.contains("1. Place primary_001"))
        #expect(document.contains("   Z family at -10 mm."))
        #expect(document.hasSuffix("\n"))
    }

    @Test
    func documentHandlesEmptySteps() {
        let context = AssemblyGuideContext(
            modelName: "empty.obj",
            constructionMode: .foldedPanels,
            materialThickness: 6.0,
            slotClearance: 0.0,
            slotAngleDegrees: 0.0,
            dowelsEnabled: false,
            dowelDiameter: 3.0,
            dowelInset: 6.0
        )

        let document = AssemblyGuideExporter.document(context: context, steps: [])

        #expect(document.contains("Mode: Folded"))
        #expect(document.contains("Slot clearance: 0 mm"))
        #expect(!document.contains("Slot angle"))
        #expect(!document.contains("Dowels"))
        #expect(document.contains("Step count: 0"))
        #expect(document.contains("No assembly steps available."))
    }

    @Test
    func eachModePrintsOnlyTheSettingsItCutsWith() {
        func lines(_ mode: ConstructionMode, notchWidth: Double? = nil, relief: String? = nil, dowels: Bool = true) -> [String] {
            AssemblyGuideExporter.settingLines(context: AssemblyGuideContext(
                modelName: "m.stl",
                constructionMode: mode,
                materialThickness: 3,
                slotClearance: 0.2,
                notchWidth: notchWidth,
                slotAngleDegrees: 45,
                relief: relief,
                dowelsEnabled: dowels,
                dowelDiameter: 6,
                dowelInset: 5
            ))
        }
        #expect(lines(.stacked) == ["Dowels: 6 mm diameter, 5 mm inset"])
        #expect(lines(.stacked, dowels: false) == ["Dowels: disabled"])
        #expect(lines(.interlocked) == ["Slot clearance: 0.2 mm", "Slot angle: 45 degrees"])
        #expect(lines(.interlocked, notchWidth: 3.4, relief: "dog bone, 3 mm tool")
            == ["Notch width: 3.4 mm", "Slot angle: 45 degrees", "Slot relief: dog bone, 3 mm tool"])
        #expect(lines(.radial) == ["Slot clearance: 0.2 mm"])
        #expect(lines(.radial, relief: "Dog Bone, 3 mm tool") == ["Slot clearance: 0.2 mm", "Slot relief: Dog Bone, 3 mm tool"])
        #expect(lines(.curve) == ["Slot clearance: 0.2 mm"])
        #expect(lines(.curve, notchWidth: 3.5) == ["Notch width: 3.5 mm"])
        #expect(lines(.foldedPanels) == ["Slot clearance: 0.2 mm"])
        #expect(lines(.threeD).isEmpty)
        for mode in ConstructionMode.allCases where mode != .interlocked {
            #expect(!lines(mode).contains { $0.hasPrefix("Slot angle") }, "\(mode)")
        }
    }

    @Test
    func foldedGuideLeavesTheClearanceOutForJointsWithoutSlots() {
        func lines(_ joint: JoineryType) -> [String] {
            AssemblyGuideExporter.settingLines(context: AssemblyGuideContext(
                modelName: "m.stl",
                constructionMode: .foldedPanels,
                materialThickness: 3,
                slotClearance: 0.2,
                slotAngleDegrees: 0,
                dowelsEnabled: false,
                dowelDiameter: 6,
                dowelInset: 5,
                foldedJoint: joint
            ))
        }
        for joint in [JoineryType.tab, .diamond, .multitab, .tongue, .rivet, .gear, .puzzle] {
            #expect(lines(joint) == ["Slot clearance: 0.2 mm"], "\(joint)")
        }
        for joint in [JoineryType.laced, .ticked, .trivial] {
            #expect(lines(joint).isEmpty, "\(joint)")
        }
    }

    @Test
    func threeDGuidePrintsTheSliceDepthNotTheHiddenThickness() {
        func document(depth: Double?, count: Int?) -> String {
            AssemblyGuideExporter.document(context: AssemblyGuideContext(
                modelName: "m.stl",
                constructionMode: .threeD,
                materialThickness: 3,
                slotClearance: 0.2,
                slotAngleDegrees: 0,
                dowelsEnabled: false,
                dowelDiameter: 6,
                dowelInset: 5,
                threeDSliceDepth: depth,
                threeDLayerCount: count
            ), steps: [])
        }
        let byDepth = document(depth: 10, count: nil)
        #expect(byDepth.contains("Slice depth: 10 mm"))
        #expect(!byDepth.contains("Material thickness"))
        let byCount = document(depth: 10, count: 12)
        #expect(byCount.contains("Distribute count: 12 layers"))
        #expect(!byCount.contains("Slice depth"))
        #expect(!byCount.contains("Material thickness"))
        // Every other mode still starts with the stock.
        for mode in ConstructionMode.allCases where mode != .threeD {
            let lines = AssemblyGuideExporter.stockLines(context: AssemblyGuideContext(
                modelName: "m.stl",
                constructionMode: mode,
                materialThickness: 3,
                slotClearance: 0,
                slotAngleDegrees: 0,
                dowelsEnabled: false,
                dowelDiameter: 6,
                dowelInset: 5,
                threeDSliceDepth: 10
            ))
            #expect(lines == ["Material thickness: 3 mm"], "\(mode)")
        }
    }

    @Test
    func writePersistsUtf8Text() throws {
        let context = AssemblyGuideContext(
            modelName: "radial.obj",
            constructionMode: .radial,
            materialThickness: 3.0,
            slotClearance: 0.0,
            slotAngleDegrees: 0.0,
            dowelsEnabled: false,
            dowelDiameter: 3.0,
            dowelInset: 6.0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try AssemblyGuideExporter.write(
            context: context,
            steps: [AssemblyStep(index: 1, title: "Place radial_001", detail: "Radial plane 0 degrees.")],
            to: url
        )

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("Mode: Radial"))
        #expect(written.contains("1. Place radial_001"))
    }
}
