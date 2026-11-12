import Foundation
import Testing
@testable import RefabArtist

/// Tests for the GUI cut-sheet document: part labeling
/// (slice / slice-piece), island splitting, and shelf packing.
struct CutSheetDocumentTests {
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

    private static let settings = ExportLayoutSettings(partSpacing: 5, pageMargin: 5, sheetWidth: 100, sheetHeight: 100)

    // MARK: - Island splitting (a slice with multiple pieces)

    @Test
    func disconnectedPiecesBecomeSeparateLabeledParts() {
        // One slice containing two disconnected squares -> two parts labeled
        // "1-1" and "1-2" (slice number, then a piece number when the slice
        // has several pieces).
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [
                    Self.square(at: Vec2(x: 0, y: 0), size: 20),
                    Self.square(at: Vec2(x: 50, y: 0), size: 12)
                ])
            ]
        )
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        let labels = document.sheets.flatMap(\.parts).map(\.label).sorted()
        #expect(labels == ["1-1", "1-2"])
        // Both pieces share the slice's assembly step.
        #expect(Set(document.sheets.flatMap(\.parts).compactMap(\.stepIndex)) == [1])
    }

    @Test
    func singlePieceSliceKeepsPlainSliceNumberLabel() {
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)]),
                SliceContourLayer(position: 5, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)])
            ]
        )
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        let labels = document.sheets.flatMap(\.parts).map(\.label).sorted()
        #expect(labels == ["1", "2"])
    }

    @Test
    func holesStayWithTheirContainingPiece() {
        // A square with a hole plus a separate small square: the hole must
        // ride with the big square's part, not become its own part.
        let outer = Self.square(at: Vec2(x: 0, y: 0), size: 30)
        let hole = Self.square(at: Vec2(x: 10, y: 10), size: 8)
        let lone = Self.square(at: Vec2(x: 60, y: 0), size: 10)
        let islands = CutSheetLayoutBuilder.islandize(paths: [outer, hole, lone])

        #expect(islands.count == 2)
        let bigIsland = islands.first { $0.loops.count == 2 }
        #expect(bigIsland != nil)
    }

    // MARK: - Packing (issue: "minimize the amount of material used")

    @Test
    func multiplePartsShareASheetWhenTheyFit() {
        // Four 20mm squares easily co-fit a 100x100 sheet -> 1 sheet, not 4.
        let layers = (0..<4).map { index in
            SliceContourLayer(position: Double(index), paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)])
        }
        let contours = StackedSliceContours(axis: .z, layers: layers)
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        #expect(document.sheets.count == 1)
        #expect(document.sheets[0].parts.count == 4)
    }

    @Test
    func partsStayInsideSheetContentBounds() {
        let layers = (0..<9).map { index in
            SliceContourLayer(position: Double(index), paths: [Self.square(at: Vec2(x: 0, y: 0), size: 28)])
        }
        let contours = StackedSliceContours(axis: .z, layers: layers)
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        for sheet in document.sheets {
            for part in sheet.parts {
                #expect(part.bounds.min.x >= Self.settings.pageMargin - 1.0e-9)
                #expect(part.bounds.min.y >= Self.settings.pageMargin - 1.0e-9)
                #expect(part.bounds.max.x <= Self.settings.sheetWidth - Self.settings.pageMargin + 1.0e-9)
                #expect(part.bounds.max.y <= Self.settings.sheetHeight - Self.settings.pageMargin + 1.0e-9)
                #expect(!part.overflowsSheet)
            }
        }
    }

    @Test
    func partsOnTheSameSheetDoNotOverlap() {
        let layers = (0..<6).map { index in
            SliceContourLayer(position: Double(index), paths: [Self.square(at: Vec2(x: 0, y: 0), size: 25 + Double(index))])
        }
        let contours = StackedSliceContours(axis: .z, layers: layers)
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        for sheet in document.sheets {
            let parts = sheet.parts
            for i in parts.indices {
                for j in parts.indices where j > i {
                    let a = parts[i].bounds
                    let b = parts[j].bounds
                    let separated = a.max.x <= b.min.x + 1.0e-9
                        || b.max.x <= a.min.x + 1.0e-9
                        || a.max.y <= b.min.y + 1.0e-9
                        || b.max.y <= a.min.y + 1.0e-9
                    #expect(separated, "parts \(parts[i].label) and \(parts[j].label) overlap")
                }
            }
        }
    }

    @Test
    func oversizedPartIsFlaggedNotDropped() {
        let contours = StackedSliceContours(
            axis: .z,
            layers: [SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 150)])]
        )
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        #expect(document.partCount == 1)
        #expect(document.overflowingPartCount == 1)
    }

    // MARK: - Interlocked (real slotted loops, axis labels)

    @Test
    func interlockedDocumentUsesAxisSliceLabelsAndRealLoops() throws {
        let model = try Self.cubeModel()
        let plan = try #require(InterlockedSlicePlanner.plan(
            model: model,
            primaryAxis: .z,
            secondaryAxis: .x,
            materialThickness: 5,
            slotClearance: 0
        ))
        let document = CutSheetLayoutBuilder.document(
            interlocked: plan,
            model: model,
            settings: Self.settings,
            revision: 1
        )

        let parts = document.sheets.flatMap(\.parts)
        #expect(!parts.isEmpty)
        // Labels follow the "Axis-slice" scheme for both families.
        #expect(parts.allSatisfy { $0.label.hasPrefix("Z-") || $0.label.hasPrefix("X-") })
        // Every part is a real boundary loop (not slot stripes): one closed
        // loop with enough vertices to carry spliced slots.
        for part in parts {
            #expect(part.cutLoops.count == 1)
            #expect((part.cutLoops.first?.count ?? 0) >= 4)
        }
        // Loops are true-mm: a 50mm cube part's outer span must be ~50mm,
        // not page-fit inches (~8).
        let spans = parts.map { $0.bounds.max.x - $0.bounds.min.x }
        #expect(spans.allSatisfy { $0 > 25 })
    }

    @Test
    func interlockedSlotReliefCutsDogBonesIntoTheInsideCorners() throws {
        let model = try Self.cubeModel()
        func document(relief: SlotReliefSettings) throws -> CutSheetDocument {
            let plan = try #require(InterlockedSlicePlanner.plan(
                model: model,
                primaryAxis: .z,
                secondaryAxis: .x,
                materialThickness: 3,
                slotRelief: relief
            ))
            return CutSheetLayoutBuilder.document(interlocked: plan, model: model, settings: .defaultValue, revision: 1)
        }
        let plain = try document(relief: .disabled)
        let relieved = try document(relief: SlotReliefSettings(enabled: true, diameter: 3))
        func area(_ part: CutSheetPart) -> Double {
            abs(CutSheetLayoutBuilder.signedArea(part.cutLoops[0]))
        }
        let plainParts = Dictionary(uniqueKeysWithValues: plain.sheets.flatMap(\.parts).map { ($0.label, $0) })
        let relievedParts = relieved.sheets.flatMap(\.parts)
        #expect(relievedParts.count == plainParts.count)

        // Each slot (bottom at x = 0, walls at y = 0 and y = 3, open toward
        // +x) gets a 3 mm disc at both inside corners, centred 1.5 mm from the
        // corner on the diagonal into the slot. Every part has ten slots, so
        // it loses ten times the discs' area outside the slot.
        let offset = 1.5 / 2.0.squareRoot()
        let centers = [Vec2(x: offset, y: offset), Vec2(x: offset, y: 3 - offset)]
        var removedPerSlot = 0.0
        let samples = 500
        let cell = (4.0 / Double(samples)) * (5.0 / Double(samples))
        for i in 0..<samples {
            for j in 0..<samples {
                let x = -1 + 4 * (Double(i) + 0.5) / Double(samples)
                let y = -1 + 5 * (Double(j) + 0.5) / Double(samples)
                let inDisc = centers.contains { (x - $0.x) * (x - $0.x) + (y - $0.y) * (y - $0.y) <= 1.5 * 1.5 }
                let inSlot = x >= 0 && y >= 0 && y <= 3
                if inDisc && !inSlot { removedPerSlot += cell }
            }
        }
        for part in relievedParts {
            #expect(part.cutLoops.count == 1)
            #expect(!part.isError)
            let removed = try area(#require(plainParts[part.label])) - area(part)
            #expect(abs(removed - 10 * removedPerSlot) < 0.05 * 10 * removedPerSlot)
        }
    }

    @Test
    func radialDocumentPacksRingsAndFinsFromTheSharedGenerator() throws {
        let model = try Self.sphereModel()
        let plan = try #require(RadialSlicePlanner.plan(
            model: model,
            nRadial: 8,
            materialThickness: 5
        ))
        let document = CutSheetLayoutBuilder.document(
            radial: plan,
            model: model,
            settings: Self.settings,
            revision: 1
        )

        // The sheet carries the SAME part population the disk+wedge generator
        // emits: every ring and every fin, nothing else.
        let disks = RadialPartBuilder.diskPartsModel(plan: plan, model: model)
        let wedges = RadialPartBuilder.wedgePartsModel(plan: plan, model: model)
        let parts = document.sheets.flatMap(\.parts)
        #expect(!disks.isEmpty)
        #expect(!wedges.isEmpty)
        #expect(parts.count == disks.count + wedges.count)

        let ringLabels = parts.filter { $0.label.hasPrefix("Z-") }
        let finLabels = parts.filter { $0.label.hasPrefix("R-") }
        #expect(ringLabels.count == disks.count)
        #expect(finLabels.count == wedges.count)

        // Real notched loops, no severed/detached flags (the legacy bbox-slot
        // failures), and assembly steps disks-first then fins.
        #expect(parts.allSatisfy { !$0.isError && !$0.isDetached })
        #expect(parts.allSatisfy { $0.cutLoops.count == 1 && ($0.cutLoops.first?.count ?? 0) >= 4 })
        let diskStepCount = try #require(plan.primary?.positions.count)
        #expect(document.part(labeled: "Z-1")?.stepIndex == 1)
        #expect(document.part(labeled: "R-1")?.stepIndex == diskStepCount + 1)

        // True-mm geometry: the 50mm sphere's equator ring must span ~50mm,
        // not page-fit inches (~8).
        let spans = parts.map { $0.bounds.max.x - $0.bounds.min.x }
        #expect((spans.max() ?? 0) > 40)
    }

    @Test
    func radialDocumentDegradesToInterlockedAtZeroRadialCount() throws {
        let model = try Self.cubeModel()
        let plan = try #require(RadialSlicePlanner.plan(
            model: model,
            nRadial: 0,
            materialThickness: 5
        ))
        let document = CutSheetLayoutBuilder.document(
            radial: plan,
            model: model,
            settings: Self.settings,
            revision: 1
        )

        let parts = document.sheets.flatMap(\.parts)
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.label.hasPrefix("Z-") || $0.label.hasPrefix("Y-") })
    }

    // MARK: - Stacked scored guides

    @Test
    func stackedGuidesAppearWhenNextSliceShrinks() {
        // A big square below a smaller square set well inside it: the lower
        // slice gets guide lines showing where the upper one sits.
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 40)]),
                SliceContourLayer(position: 5, paths: [Self.square(at: Vec2(x: 10, y: 10), size: 20)])
            ]
        )
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)

        let lower = document.sheets.flatMap(\.parts).first { $0.label == "1" }
        #expect(lower != nil)
        #expect(!(lower?.guideLines.isEmpty ?? true), "expected scored guides on the lower slice")
    }

    // MARK: - Document identity

    @Test
    func documentEqualityIsRevisionBased() {
        let contours = StackedSliceContours(
            axis: .z,
            layers: [SliceContourLayer(position: 0, paths: [Self.square(at: Vec2(x: 0, y: 0), size: 20)])]
        )
        let a = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1)
        let b = CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 2)
        #expect(a != b)
        #expect(a == CutSheetLayoutBuilder.document(stacked: contours, settings: Self.settings, dowels: nil, revision: 1))
    }

    // MARK: - Fixtures

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func sphereModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl"))
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
