import Foundation
import Testing
@testable import RefabArtist

struct DxfExporterTests {
    @Test
    func stackedExportWritesDowelCirclesOnSliceLayers() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-dowel-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        // Dowels are alignment rods THROUGH the stack: a single-layer stack
        // has nothing to align, so placement requires >= 2 layers.
        // Coverage-based placement puts up to two rods inside the material,
        // and every covered layer drills a hole at the same slice-space
        // position so the rod actually threads (2 rods x 2 layers = 4
        // circles).
        let square = Self.squareContours().layers[0]
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                square,
                SliceContourLayer(position: 5, paths: square.paths)
            ]
        )
        try DxfExporter.write(
            contours: contours,
            to: url,
            dowels: DxfExporter.DowelSettings(enabled: true, diameter: 4, inset: 5)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.components(separatedBy: "\nCIRCLE\n").count - 1 == 4)
        #expect(dxf.contains("\n40\n2.000000\n"))
        #expect(dxf.contains("\n1\nslice_001\n"))
        #expect(dxf.contains("\n1\nslice_002\n"))
    }

    @Test
    func vectorLayoutSettingsOffsetDxfCoordinates() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-layout-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(
            contours: Self.twoSquareContours(),
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 25, pageMargin: 7)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("\n10\n7.000000\n20\n7.000000\n"))
        #expect(dxf.contains("\n11\n27.000000\n21\n7.000000\n"))
        #expect(dxf.contains("\n10\n52.000000\n20\n7.000000\n"))
    }

    @Test
    func sheetLayoutWrapsStackedDxfCoordinates() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-dxf-sheet-wrap-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(
            contours: Self.threeSquareContours(),
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 70)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("\n8\nslice_001\n10\n5.000000\n20\n5.000000\n"))
        #expect(dxf.contains("\n8\nslice_002\n10\n30.000000\n20\n5.000000\n"))
        #expect(dxf.contains("\n8\nslice_003\n10\n5.000000\n20\n37.000000\n"))
    }

    @Test
    func sheetLayoutRotatesWideDxfPartsThatFitWhenTurned() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-dxf-sheet-rotate-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(
            contours: Self.wideRectangleContours(),
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 50, sheetHeight: 100)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("\n8\nslice_001\n10\n5.000000\n20\n75.000000\n"))
        #expect(dxf.contains("\n11\n5.000000\n21\n5.000000\n"))
        #expect(dxf.contains("\n10\n25.000000\n20\n5.000000\n"))
        #expect(!dxf.contains("\n10\n75.000000\n20\n5.000000\n"))
    }

    @Test
    func sheetLayoutPaginatesDxfRowsAcrossStockSheets() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-dxf-sheet-pagination-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(
            contours: Self.threeSquareContours(),
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 60)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("\n8\nslice_001\n10\n5.000000\n20\n5.000000\n"))
        #expect(dxf.contains("\n8\nslice_002\n10\n30.000000\n20\n5.000000\n"))
        #expect(dxf.contains("\n8\nslice_003\n10\n5.000000\n20\n65.000000\n"))
        #expect(dxf.components(separatedBy: "\nsheet_boundary\n").count - 1 == 4)
        #expect(dxf.components(separatedBy: "\nsheet_boundary_2\n").count - 1 == 4)
    }

    @Test
    func sheetLayoutWritesDxfSheetBoundaryWhenConfigured() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-dxf-sheet-boundary-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(
            contours: Self.squareContours(),
            to: url,
            layoutSettings: ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 55, sheetHeight: 70)
        )

        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.components(separatedBy: "\nsheet_boundary\n").count - 1 == 4)
        #expect(dxf.contains("\n8\nsheet_boundary\n10\n0.000000\n20\n0.000000\n"))
        #expect(dxf.contains("\n11\n55.000000\n21\n70.000000\n"))
    }

    @Test
    func radialExportWritesDiskAndWedgeLabelsAndLoops() throws {
        let model = try Self.cubeModel()
        let plan = RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5)!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-label-test-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }

        try DxfExporter.write(radial: plan, model: model, to: url)

        let parts = RadialPartBuilder.diskPartsModel(plan: plan, model: model)
            + RadialPartBuilder.wedgePartsModel(plan: plan, model: model)
        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.components(separatedBy: "\nLINE\n").count - 1 == parts.reduce(0) { $0 + $1.loop.count })
        #expect(dxf.components(separatedBy: "\nTEXT\n").count - 1 == parts.count)
        #expect(dxf.contains("\n1\nfirst_axis_001\n"))
        #expect(dxf.contains("\n1\nradial_001\n"))
        #expect(dxf.contains("\n1\nradial_012\n"))
    }

    @Test
    func interlockedPartLoopsWindCounterclockwiseInsideTheMargin() throws {
        // Every part's boundary loop must wind counter-clockwise (signed
        // area > 0) per the DXF/SVG fill convention.
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 5)!
        let parts = InterlockedPartBuilder.parts(plan: plan, model: model)
        #expect(parts.count == 20)
        for part in parts {
            let loop = part.loop
            var area = 0.0
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                area += a.x * b.y - b.x * a.y
            }
            #expect(area > 0)
            // Each loop starts at or past the 0.2625in page-fit margin.
            #expect((loop.map(\.x).min() ?? 0) >= 0.2625 - 1e-6)
            #expect((loop.map(\.y).min() ?? 0) >= 0.2625 - 1e-6)
        }
    }

    @Test
    func interlockedSlotsAreThePlansSlotWidth() throws {
        // Slots are cut at the plan's slot width — the stock thickness plus the
        // slot offset, or the notch-width override — whatever the fixture.
        let cube = try Self.cubeModel()
        let prism = try Self.rectangularPrismModel()
        let cubePlan = InterlockedSlicePlanner.plan(model: cube, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let prismPlan = InterlockedSlicePlanner.plan(model: prism, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        #expect(InterlockedPartBuilder.slotHalfWidth(plan: cubePlan) == 1.5)
        #expect(InterlockedPartBuilder.slotHalfWidth(plan: prismPlan) == 1.5)
        let offsetPlan = InterlockedSlicePlanner.plan(model: cube, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3, slotClearance: 0.2)!
        #expect(abs(InterlockedPartBuilder.slotHalfWidth(plan: offsetPlan) - 1.6) < 1e-12)
        let notchPlan = InterlockedSlicePlanner.plan(model: cube, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3, notchWidthOverride: 2.5)!
        #expect(InterlockedPartBuilder.slotHalfWidth(plan: notchPlan) == 1.25)
    }

    /// Lengths (model mm) of a part's slot bottoms: edges parallel to the
    /// crossing axis (page y) strictly inside the part's depth span.
    private static func slotBottomLengths(_ part: InterlockedPartBuilder.Part, fit: Double) -> [Double] {
        let loop = part.loop
        let minX = loop.map(\.x).min() ?? 0
        let maxX = loop.map(\.x).max() ?? 0
        var lengths: [Double] = []
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            if abs(a.x - b.x) < 1e-9, a.x > minX + 1e-6, a.x < maxX - 1e-6 {
                lengths.append(abs(b.y - a.y) / fit)
            }
        }
        return lengths
    }

    @Test
    func interlockedCubePartsCarveOneStockWideSlotPerCrossing() throws {
        // 3 mm stock across a 50 mm cube: ten crossings 5 mm apart, so every
        // part carries ten 3 mm slots with 2 mm of material between them.
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let fit = InterlockedPartBuilder.pageFitScale(plan: plan, bounds: try #require(model.bounds))
        let parts = InterlockedPartBuilder.parts(plan: plan, model: model)
        #expect(parts.count == 20)
        for part in parts {
            let bottoms = Self.slotBottomLengths(part, fit: fit)
            #expect(bottoms.count == 10)
            #expect(bottoms.allSatisfy { abs($0 - 3) < 1e-9 })
        }
    }

    @Test
    func interlockedSlotsAsWideAsTheSpacingMergeIntoOneCut() throws {
        // 5 mm stock at a 5 mm crossing spacing: neighbouring slots touch, so
        // the whole slotted half is one cut back to the slot bottom (which
        // becomes the part's edge) instead of ten slots with zero-width
        // material between them.
        let model = try Self.cubeModel()
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 5)!
        let fit = InterlockedPartBuilder.pageFitScale(plan: plan, bounds: try #require(model.bounds))
        let parts = InterlockedPartBuilder.parts(plan: plan, model: model)
        #expect(parts.count == 20)
        for part in parts {
            #expect(Self.slotBottomLengths(part, fit: fit).isEmpty)
            var area = 0.0
            for i in part.loop.indices {
                let a = part.loop[i], b = part.loop[(i + 1) % part.loop.count]
                area += a.x * b.y - b.x * a.y
            }
            let areaMm = area / 2 / (fit * fit)
            #expect(areaMm > 50 * 25 && areaMm < 50 * 25.1)
        }
    }

    @Test
    func interlockedAxisAlignedRectangleIsDetectedAndRoundContourIsNot() {
        // The cube-regression guard hinges on isAxisAlignedRectangle: a square /
        // rectangle (any cube slice) must be detected so it keeps all slots; a
        // round/clipped contour must NOT be, so it takes the chord-clip path.
        let square = [Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 4), Vec2(x: 0, y: 4)]
        #expect(InterlockedPartBuilder.isAxisAlignedRectangle(square))
        // A square with redundant collinear edge midpoints still reduces to a rect.
        let squareWithMidpoints = [
            Vec2(x: 0, y: 0), Vec2(x: 2, y: 0), Vec2(x: 4, y: 0),
            Vec2(x: 4, y: 4), Vec2(x: 0, y: 4)
        ]
        #expect(InterlockedPartBuilder.isAxisAlignedRectangle(squareWithMidpoints))
        // An octagon (faceted circle) is not an axis-aligned rectangle.
        var octagon: [Vec2] = []
        for k in 0..<8 {
            let a = Double(k) * .pi / 4
            octagon.append(Vec2(x: 10 + 10 * Foundation.cos(a), y: 10 + 10 * Foundation.sin(a)))
        }
        #expect(!InterlockedPartBuilder.isAxisAlignedRectangle(octagon))
    }

    @Test
    func interlockedRoundCrossSectionClipsSlotsAndShrinksChordVersusBbox() throws {
        // A real round (cylinder) cross-section produces a per-slice chord that is
        // shorter than the bbox AND fewer carved slots than the bbox rectangle —
        // the entire point of the rework. We slice the cylinder fixture and check
        // that the parts span a real range of chord sizes (not a constant bbox).
        // 3 mm stock: the ten 4 mm-spaced slots keep material between them.
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl")
        )
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 3)!
        let parts = InterlockedPartBuilder.parts(plan: plan, model: model)
        #expect(!parts.isEmpty)
        // The cylinder's long axis (Z, 80 mm) is the in-plane DEPTH of every part
        // (a constant 8.0 in page width); the circular chord across the 40 mm
        // diameter is the part HEIGHT, which shrinks toward the cylinder rim. Find
        // the min/max chord (height) across all parts; the round shape must yield a
        // real spread (not a constant bbox).
        let chordExtents = parts.map { part -> Double in
            let ys = part.loop.map(\.y)
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        let minExtent = chordExtents.min() ?? 0
        let maxExtent = chordExtents.max() ?? 0
        // Pre-rework every part was a constant full-diameter plank; now the narrow
        // rim chord (~1.73 in) is materially smaller than the widest center chord
        // (~3.98 in).
        #expect(maxExtent - minExtent > 1.0)
        #expect(minExtent < 2.5)
        // The constant width (the 80 mm Z depth) is the full 8.0 in page content.
        let widths = parts.map { part -> Double in
            let xs = part.loop.map(\.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) < 1.0e-6)
    }

    @Test
    func interlockedSelfPinchedTorusSectionTracesPeanutNotBbox() throws {
        // A torus tube slice tangent to the hole is a self-pinched figure-8: two
        // lobes joined at a narrow waist, so the part must follow that peanut
        // outline. Regression guard: these sections used to fall back to the bbox
        // builder (the symmetry-bail misfiring on the centre-balanced arcs),
        // emitting a full rectangle — geometrically wrong output a laser cutter
        // would cut solid. The test asserts the pinch directly on the part
        // geometry, using the same plan the interlocked export uses for this
        // fixture: primary Z, secondary X, 5 mm stock.
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/torus_R30_r10mm.stl")
        )
        let plan = InterlockedSlicePlanner.plan(model: model, primaryAxis: .z, secondaryAxis: .x, materialThickness: 5)!
        let parts = InterlockedPartBuilder.parts(plan: plan, model: model)
        #expect(!parts.isEmpty)

        // Solid width of a part's outline at crossing height y (max-x minus min-x
        // of the edge crossings at that height).
        func widthAt(_ loop: [Vec2], _ y: Double) -> Double {
            var xs: [Double] = []
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                if (a.y - y) * (b.y - y) <= 0, abs(b.y - a.y) > 1.0e-9 {
                    let t = (y - a.y) / (b.y - a.y)
                    xs.append(a.x + t * (b.x - a.x))
                }
            }
            guard let lo = xs.min(), let hi = xs.max() else { return 0 }
            return hi - lo
        }

        // The tallest part is a deep figure-8 lobe pair; its waist (mid height)
        // must be far narrower than its lobes (quarter heights). A bbox rectangle
        // would be ~equal at all three; a convex oval would be WIDEST at the
        // middle. Only the real peanut pinches in the centre.
        let tallest = parts.max { lhs, rhs in
            (lhs.bounds.max.y - lhs.bounds.min.y) < (rhs.bounds.max.y - rhs.bounds.min.y)
        }!
        let yLo = tallest.bounds.min.y, yHi = tallest.bounds.max.y
        let waist = widthAt(tallest.loop, yLo + 0.5 * (yHi - yLo))
        let lobe = max(widthAt(tallest.loop, yLo + 0.25 * (yHi - yLo)),
                       widthAt(tallest.loop, yLo + 0.75 * (yHi - yLo)))
        #expect(lobe > 0)
        // Peanut waist measures ~6% of the lobe width here; a bbox/oval regression
        // would push this ratio to ~1.0 or above. 0.5 is a safe separating line.
        #expect(waist < 0.5 * lobe)
    }

    private static func squareContours() -> StackedSliceContours {
        StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 0,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 20, y: 0),
                                Vec2(x: 20, y: 20),
                                Vec2(x: 0, y: 20),
                                Vec2(x: 0, y: 0)
                            ],
                            closed: true
                        )
                    ]
                )
            ]
        )
    }

    private static func twoSquareContours() -> StackedSliceContours {
        var contours = squareContours()
        contours.layers.append(contours.layers[0])
        contours.layers[1].position = 1
        return contours
    }

    private static func threeSquareContours() -> StackedSliceContours {
        var contours = twoSquareContours()
        contours.layers.append(contours.layers[0])
        contours.layers[2].position = 2
        return contours
    }

    private static func wideRectangleContours() -> StackedSliceContours {
        StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 0,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 70, y: 0),
                                Vec2(x: 70, y: 20),
                                Vec2(x: 0, y: 20),
                                Vec2(x: 0, y: 0)
                            ],
                            closed: true
                        )
                    ]
                )
            ]
        )
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func rectangularPrismModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/rectangular_prism_ascii.stl"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
