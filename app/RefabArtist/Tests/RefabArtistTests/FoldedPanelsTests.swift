import Foundation
import Testing
@testable import RefabArtist

struct FoldedPanelsTests {
    @Test
    func foldedPanelPlannerMergesCubeTrianglesIntoFacePanels() throws {
        let model = try Self.cubeModel()
        let plan = FoldedPanelPlanner.plan(model: model)

        #expect(plan.panelCount == 6)
        #expect(plan.panels.allSatisfy { $0.points.count == 5 })
        #expect(plan.panels.allSatisfy { panel in
            panel.bounds.max.x - panel.bounds.min.x == 50
            && panel.bounds.max.y - panel.bounds.min.y == 50
        })
    }

    @Test
    func foldedPanelPlannerAssemblesConnectedCubeNet() throws {
        let model = try Self.cubeModel()
        let plan = FoldedPanelPlanner.plan(model: model)

        // The hinge unfold of the model surface: ONE connected outline + the
        // spanning-tree fold edges, alongside the per-panel `panels` array.
        let outline = try #require(plan.netOutline)
        let folds = try #require(plan.foldEdges)
        // 6 squares edge-to-edge: a 14-vertex cross enclosing 6 × 50 × 50.
        #expect(outline.count == 14)
        #expect(abs(Self.signedArea(outline)) == 15000)
        #expect(folds.count == 5)
        #expect(folds.allSatisfy { abs(Self.length($0.start, $0.end) - 50) < 1.0e-6 })
        #expect(plan.panels.count == 6)
    }

    @Test
    func facesInOnePlaneThatShareNoEdgeAreSeparatePanels() throws {
        // The chair is a set of boxes: four legs, a seat and a back. Their
        // faces in one plane (the legs' outer faces, the seat's sides) share
        // no edge, and the back's underside lies back to back on the seat's
        // top: each is a panel of its own. 4 legs × 6 + seat 6 + back 6, less
        // 1 for the seat side and back face that meet edge to edge in one
        // plane: 35.
        let chair = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/real-world/simple_chair.stl"))
        let plan = FoldedPanelPlanner.plan(model: chair, maxNetExtent: Vec2(x: 580, y: 280))
        #expect(plan.panelCount == 35)
        #expect(plan.nets.reduce(0) { $0 + $1.panelOutlines.count } == 35)
    }

    @Test
    func theStockGoesInsideEvenWhereFacesAreWoundTheWrongWay() throws {
        // The box fixture's top and bottom faces are wound against its sides;
        // every panel's stock must still lie inside the box.
        let box = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/rectangular_prism_ascii.stl"))
        let plan = FoldedPanelPlanner.plan(model: box, materialThickness: 3)
        let center = Vec3(x: 0, y: 0, z: 0)
        for net in plan.nets {
            for (index, polygon) in net.panelOutlines.enumerated() where polygon.count >= 3 {
                let frame = try #require(net.panelFrames[index])
                let point = frame.modelPoint(polygon[0])
                let toCenter = Vec3(x: center.x - point.x, y: center.y - point.y, z: center.z - point.z)
                let inward = net.panelInward[index]
                #expect(toCenter.x * inward.x + toCenter.y * inward.y + toCenter.z * inward.z > 0)
            }
        }
    }

    @Test
    func foldedPanelPreviewLayoutPlacesCubePanelsAsConnectedNet() throws {
        let plan = try Self.cubePlan(.tab, thickness: 3)
        let layout = FoldedPanelPreviewLayouter.layout(plan: plan, spacing: 6)

        // ONE net: six panels (each at most 50 × 50, the male copies cut back
        // by the stock), five folds, seven slots.
        #expect(layout.nets.count == 1)
        let net = layout.nets[0]
        #expect(net.panelOutlines.count == 6)
        #expect(plan.nets[0].hinges.count == 5)
        #expect(net.slotHoles.count == 7)
        #expect(layout.paths.count == 1)
        #expect(layout.paths[0].points.first == layout.paths[0].points.last)
        for polygon in net.panelOutlines {
            let xs = polygon.map(\.x)
            let ys = polygon.map(\.y)
            #expect(xs.max()! - xs.min()! <= 50 + 1.0e-6)
            #expect(ys.max()! - ys.min()! <= 50 + 1.0e-6)
        }
    }

    @Test
    func perforationDashesCoverFoldEdgeEndpoints() throws {
        let dashes = FoldedPerforation.dashes(
            start: Vec2(x: 0, y: 0),
            end: Vec2(x: 50, y: 0),
            materialThickness: 3.0
        )
        // 50mm hinge, 3mm dash + 3mm gap: dashes start at 0, 6, ..., 48.
        #expect(dashes.count == 9)
        #expect(dashes.first?.start == Vec2(x: 0, y: 0))
        #expect(dashes.last?.end == Vec2(x: 50, y: 0))
        for dash in dashes {
            #expect(dash.end.x - dash.start.x <= 3.0 + 1.0e-9)
            #expect(dash.end.x > dash.start.x)
        }
        // A hinge shorter than one dash + gap stays a single full cut.
        let short = FoldedPerforation.dashes(
            start: Vec2(x: 0, y: 0),
            end: Vec2(x: 5, y: 0),
            materialThickness: 3.0
        )
        #expect(short == [FoldedNetFoldEdge(start: Vec2(x: 0, y: 0), end: Vec2(x: 5, y: 0))])
    }

    @Test
    func foldedPlannerSplitsNetsToFitUsableSheetExtent() throws {
        let model = try Self.cubeModel()
        let plan = FoldedPanelPlanner.plan(model: model, maxNetExtent: Vec2(x: 110, y: 110))

        // A 110 mm ceiling cannot hold the 200 × 150 cross: the unfold must
        // split, every face panel must land in exactly one net, and every
        // net, joints and all, must fit within the ceiling.
        #expect(plan.nets.count >= 2)
        #expect(plan.nets.reduce(0) { $0 + $1.panelOutlines.count } == 6)
        #expect(plan.nets.allSatisfy { $0.outline.count >= 3 })
        for net in plan.nets {
            let bounds = net.bounds
            #expect(bounds.max.x - bounds.min.x <= 110 + 1.0e-6)
            #expect(bounds.max.y - bounds.min.y <= 110 + 1.0e-6)
        }
    }

    // MARK: - Joint types on the cube (ONE net, 6 panels, 5 folds, 7 seams)

    @Test(arguments: [
        (JoineryType.tab, 7), (.diamond, 7), (.tongue, 7), (.multitab, 21),
        (.rivet, 14), (.laced, 14), (.gear, 0), (.puzzle, 0), (.ticked, 0),
    ])
    func everyCuttingJointTypeCutsAllSevenCubeSeams(type: JoineryType, holes: Int) throws {
        for thickness in [0.5, 3.0, 5.0] {
            let plan = try Self.cubePlan(type, thickness: thickness)
            #expect(plan.nets.count == 1)
            let net = try #require(plan.nets.first)
            #expect(plan.jointCensus == FoldedJointCensus(cutEdges: 7, joined: 7), "\(type) \(thickness)")
            // Tab, Diamond, Tongue: a slot per seam; Multitab three; Rivet a
            // slot and a pin hole per seam; Laced a hole on each copy; Gear,
            // Puzzle and Ticked notch the edges instead.
            #expect(net.slotHoles.count == holes, "\(type) \(thickness)")
            // Every joint but Laced's holes changes the outline itself.
            let plain = try Self.cubePlan(.trivial, thickness: thickness)
            #expect((net.outline != plain.nets[0].outline) == (type != .laced), "\(type) \(thickness)")
        }
    }

    @Test
    func noneAndSeamLeavePlainEdges() throws {
        let none = try Self.cubePlan(.trivial, thickness: 3)
        let seam = try Self.cubePlan(.seam, thickness: 3)
        // Seam had no geometry of its own; it is None now.
        #expect(JoineryParameters.preset(for: .seam).sanitized.type == .trivial)
        #expect(!JoineryType.menuOrder.contains(.seam))
        #expect(JoineryType.menuOrder.first == .trivial)
        for plan in [none, seam] {
            let net = try #require(plan.nets.first)
            #expect(net.slotHoles.isEmpty)
            let featureCount = net.panelFeatures.reduce(0) { $0 + $1.count }
            #expect(featureCount == 0)
            #expect(plan.jointCensus == nil)
        }
    }

    @Test
    func diamondTickProtrudesFartherThanTheTab() throws {
        let tabBounds = try #require(try Self.cubePlan(.tab, thickness: 3).nets.first).bounds
        let diamondBounds = try #require(try Self.cubePlan(.diamond, thickness: 3).nets.first).bounds
        // Both clear the stock first: tab tickRadius past the far face,
        // diamond apex 2 × tickRadius past it.
        let tabSpan = (tabBounds.max.x - tabBounds.min.x) + (tabBounds.max.y - tabBounds.min.y)
        let diamondSpan = (diamondBounds.max.x - diamondBounds.min.x) + (diamondBounds.max.y - diamondBounds.min.y)
        #expect(diamondSpan > tabSpan + 1.0e-6)
    }

    @Test
    func slotOffsetWidensEverySlot() throws {
        let model = try Self.cubeModel()
        let tight = FoldedPanelPlanner.plan(model: model, joinery: .preset(for: .tab), materialThickness: 3)
        let eased = FoldedPanelPlanner.plan(model: model, joinery: .preset(for: .tab), materialThickness: 3, slotClearance: 0.25)
        let tightAreas = tight.nets[0].slotHoles.map { abs(Self.signedArea($0)) }.sorted()
        let easedAreas = eased.nets[0].slotHoles.map { abs(Self.signedArea($0)) }.sorted()
        #expect(tightAreas.count == 7 && easedAreas.count == 7)
        // A 6.35 × 3 mm slot becomes 6.6 × 3.25 mm.
        for (tightArea, easedArea) in zip(tightAreas, easedAreas) {
            #expect(abs(tightArea - 6.35 * 3) < 1.0e-6)
            #expect(abs(easedArea - 6.6 * 3.25) < 1.0e-6)
        }
    }

    @Test
    func laceHolesFaceEachOtherAcrossTheSeam() throws {
        // Each hole sits tickRadius + holeRadius in from its own copy's edge
        // (the male copy's cut-back edge), and its partner across the seam
        // sits at the same place along it.
        let plan = try Self.cubePlan(.laced, thickness: 3)
        let net = try #require(plan.nets.first)
        let parameters = plan.joinery
        var centers: [Vec3] = []
        for hole in net.slotHoles {
            let center = Vec2(x: hole.map(\.x).reduce(0, +) / Double(hole.count), y: hole.map(\.y).reduce(0, +) / Double(hole.count))
            let panel = try #require(net.panelOutlines.indices.first { Self.contains(net.panelOutlines[$0], center) })
            let polygon = net.panelOutlines[panel]
            let inset = polygon.indices.map { Self.distanceToSegment(center, polygon[$0], polygon[($0 + 1) % polygon.count]) }.min() ?? 0
            #expect(abs(inset - (parameters.tickRadius + parameters.holeRadius)) < 1.0e-6)
            centers.append(try #require(net.panelFrames[panel]).modelPoint(center))
        }
        // Holes pair up: each one's nearest hole on the model is its partner,
        // the stock's depth apart or less.
        for (index, center) in centers.enumerated() {
            let nearest = centers.indices.filter { $0 != index }.map { Self.distance(center, centers[$0]) }.min() ?? .infinity
            #expect(nearest < 2 * (parameters.tickRadius + parameters.holeRadius) + plan.materialThickness + 1.0e-6)
        }
    }

    @Test
    func theJointSummaryNamesEachReasonAnEdgeStaysPlain() {
        let census = FoldedJointCensus(cutEdges: 12, joined: 3, tooShort: 5, tooFlat: 2, noRoom: 2)
        #expect(census.summary(joint: "Diamond")
                == "Diamond joints on 3 of 12 cut edges; the other 9 stay plain edges to glue "
                + "(5 too short for it, 2 where the panels meet too flat for a slot, 2 with no room for it on the net).")
        #expect(FoldedJointCensus(cutEdges: 4, joined: 3, noRoom: 1).summary(joint: "Tab")
                == "Tab joints on 3 of 4 cut edges; the other 1 stays a plain edge to glue (1 with no room for it on the net).")
        #expect(FoldedJointCensus(cutEdges: 2, tooShort: 2).summary(joint: "Rivet")
                == "No Rivet joints on this model: all 2 cut edges stay plain edges to glue (2 too short for it).")
        #expect(FoldedJointCensus(cutEdges: 3, joined: 2, insideCorner: 1).summary(joint: "Gear")
                == "Gear joints on 2 of 3 cut edges; the other 1 stays a plain edge to glue (1 at an inside corner, where an open notch has nothing to hold).")
    }

    @Test
    func aCurvedModelThatTakesNoJointSaysSo() throws {
        // At the app's 250-face detail the cylinder's sides meet too flat for
        // a slot and its cap edges are too short: the panel says so rather
        // than the picker silently doing nothing.
        var cylinder = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl"))
        cylinder = try #require(FoldedMeshPrecleaner.preclean(cylinder, targetFaceCount: 250))
        let census = try #require(FoldedPanelPlanner.plan(model: cylinder, joinery: .preset(for: .tab), materialThickness: 3).jointCensus)
        #expect(census.joined == 0)
        #expect(census.joined + census.tooShort + census.tooFlat + census.noRoom + census.insideCorner == census.cutEdges)
        #expect(census.summary(joint: "Tab").hasPrefix("No Tab joints on this model: all \(census.cutEdges) cut edges stay plain edges to glue ("))
    }

    // MARK: - Seam edges

    @Test
    func seamEdgesForceCutsAndSplitSeamedFaceIntoItsOwnNet() throws {
        let model = try Self.cubeModel()
        // Seam all 4 edges of the +Z face: it can no longer fold to any
        // neighbour, so it must land in its own net.
        let corners = [
            Vec3(x: -25, y: -25, z: 25),
            Vec3(x: 25, y: -25, z: 25),
            Vec3(x: 25, y: 25, z: 25),
            Vec3(x: -25, y: 25, z: 25)
        ]
        let seams = (0..<4).map { FoldedSeamEdge(a: corners[$0], b: corners[($0 + 1) % 4]) }
        let plan = FoldedPanelPlanner.plan(model: model, seamEdges: seams)

        #expect(plan.nets.count == 2)
        #expect(plan.nets.map(\.panelOutlines.count).sorted() == [1, 5])
        // 6 panels across 2 nets → 4 folds; 12 cube edges − 4 folds = 8 seams
        // → 8 tab slots (default tab joinery).
        #expect(plan.nets.reduce(0) { $0 + $1.hinges.count } == 4)
        #expect(plan.nets.reduce(0) { $0 + $1.slotHoles.count } == 8)
        #expect(plan.netOutline == nil)
    }

    @Test
    func seamEdgesDefaultEmptyKeepsSingleCubeNet() throws {
        let plan = FoldedPanelPlanner.plan(model: try Self.cubeModel(), seamEdges: [])
        #expect(plan.nets.count == 1)
        #expect(plan.netOutline != nil)
    }

    // MARK: - The cut sheet (the one DXF, SVG, PDF and EPS pipeline)

    @Test
    func foldLinesGoOnTheirOwnLayerAndEveryCutCloses() throws {
        let plan = try Self.cubePlan(.tab, thickness: 3)
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 600, sheetHeight: 300)
        let source = FlatPartExport.Source.foldedPanels(plan)
        let model = try Self.cubeModel()
        let document = FlatPartExport.cutSheetDocument(for: source, model: model, settings: settings, revision: 1)
        let part = try #require(document.sheets.first?.parts.first)
        // Fold lines are not cuts of the part: no open cuts, fold lines apart.
        #expect(part.openCuts.isEmpty)
        #expect(part.guideLines.isEmpty)
        #expect(!part.foldLines.isEmpty)
        #expect(part.foldsArePerforated)
        // The outline and 7 slots.
        #expect(part.cutLoops.count == 8)

        let url = FileManager.default.temporaryDirectory.appending(path: "folded-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FlatPartExport.write(source, format: .dxf, model: model, settings: settings, to: url)
        #expect(writer == .cutSheet)
        let dxf = try String(contentsOf: url, encoding: .utf8)
        // Every segment on the part's layer belongs to a closed loop: each
        // end point is shared by exactly two segments.
        let cuts = Self.layerSegments(layer: part.label, in: dxf)
        #expect(!cuts.isEmpty)
        var degree: [String: Int] = [:]
        for seg in cuts {
            for (x, y) in [(seg.x1, seg.y1), (seg.x2, seg.y2)] {
                degree["\((x * 1.0e4).rounded()):\((y * 1.0e4).rounded())", default: 0] += 1
            }
        }
        #expect(degree.values.allSatisfy { $0 == 2 })
        // Every fold dash is on the fold layer.
        #expect(Self.layerSegments(layer: CutSheetDocumentExporter.foldLayer, in: dxf).count == part.foldLines.count)
    }

    @Test
    func foldLinesAreCutAsDashesOrScoredFull() throws {
        var joinery = JoineryParameters.preset(for: .tab)
        let model = try Self.cubeModel()
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 600, sheetHeight: 300)
        for perforate in [true, false] {
            joinery.perforate = perforate
            let plan = FoldedPanelPlanner.plan(model: model, joinery: joinery, materialThickness: 3)
            let url = FileManager.default.temporaryDirectory.appending(path: "folded-\(UUID().uuidString).svg")
            defer { try? FileManager.default.removeItem(at: url) }
            try FlatPartExport.write(.foldedPanels(plan), format: .svg, model: model, settings: settings, to: url)
            let svg = try String(contentsOf: url, encoding: .utf8)
            // Perforation dashes are cut (blue); full fold lines are scored
            // (red). The 5 folds: each 50 mm, 3 mm dashes every 6 mm, less
            // where a neighbouring panel is cut back.
            let red = svg.components(separatedBy: "stroke=\"#FF0000\"").count - 1
            if perforate {
                #expect(red == 0)
            } else {
                #expect(red == plan.nets[0].foldEdges.count)
            }
        }
    }

    @Test
    func thePartFramesPutEveryFoldedPanelOnTheModel() throws {
        let plan = try Self.cubePlan(.tab, thickness: 3)
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 600, sheetHeight: 300)
        let model = try Self.cubeModel()
        let document = FlatPartExport.cutSheetDocument(for: .foldedPanels(plan), model: model, settings: settings, revision: 1)
        let url = FileManager.default.temporaryDirectory.appending(path: "folded-\(UUID().uuidString).frames.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try CutSheetDocumentExporter.writePartFrames(document: document, settings: settings, to: url)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let folds = try #require(json["folds"] as? [[String: Any]])
        #expect(folds.count == 1)
        let panels = try #require(folds[0]["panels"] as? [[String: Any]])
        #expect(panels.count == 6)
        #expect((folds[0]["hinges"] as? [[Int]])?.count == 5)
        // Each panel's outline, through its DXF-to-model map, lies on a face
        // of the cube (one coordinate at ±25).
        for panel in panels {
            let matrix = try #require(panel["dxfToModel"] as? [[Double]])
            let region = try #require(panel["region"] as? [[Double]])
            for point in region {
                let model = (0..<3).map { matrix[$0][0] * point[0] + matrix[$0][1] * point[1] + matrix[$0][2] }
                #expect(model.contains { abs(abs($0) - 25) < 1.0e-6 })
                #expect(model.allSatisfy { abs($0) <= 25 + 1.0e-6 })
            }
        }
    }

    @Test
    func everyChairNetFitsItsSheet() throws {
        let chair = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/real-world/simple_chair.stl"))
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 600, sheetHeight: 300)
        for type: JoineryType in [.trivial, .tab, .gear, .rivet] {
            let plan = FoldedPanelPlanner.plan(model: chair, joinery: .preset(for: type), materialThickness: 5, maxNetExtent: Vec2(x: 580, y: 280))
            let document = FlatPartExport.cutSheetDocument(for: .foldedPanels(plan), model: chair, settings: settings, revision: 1)
            #expect(document.overflowingPartCount == 0, "\(type)")
            #expect(document.partCount == plan.nets.count, "\(type)")
            for sheet in document.sheets {
                for part in sheet.parts {
                    #expect(part.bounds.min.x >= 10 - 1.0e-6 && part.bounds.min.y >= 10 - 1.0e-6, "\(type)")
                    #expect(part.bounds.max.x <= 590 + 1.0e-6 && part.bounds.max.y <= 290 + 1.0e-6, "\(type)")
                }
            }
        }
    }

    @Test
    func aPartTallerThanEverySheetGetsItsOwnSheetInsteadOfHangingThePacker() throws {
        // 100 × 700 mm on a 600 × 300 sheet fits neither way round: it goes on
        // a sheet of its own, flagged, and packing finishes.
        let tall = [Vec2(x: 0, y: 0), Vec2(x: 100, y: 0), Vec2(x: 100, y: 700), Vec2(x: 0, y: 700)]
        let net = FoldedNet(outline: tall, foldEdges: [], slotHoles: [], panelOutlines: [tall])
        let plan = FoldedPanelPlan(panels: [], nets: [net])
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 600, sheetHeight: 300)
        let document = CutSheetLayoutBuilder.document(folded: plan, settings: settings, revision: 1)
        #expect(document.partCount == 1)
        #expect(document.overflowingPartCount == 1)
    }

    // MARK: - Helpers

    private static func cubePlan(_ type: JoineryType, thickness: Double) throws -> FoldedPanelPlan {
        FoldedPanelPlanner.plan(model: try cubeModel(), joinery: .preset(for: type), materialThickness: thickness)
    }

    private static func cubeModel() throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/cube_ascii.stl"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    struct Seg: Equatable {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
    }

    /// All LINE entities on a DXF layer.
    private static func layerSegments(layer: String, in dxf: String) -> [Seg] {
        let lines = dxf.components(separatedBy: "\n")
        var segments: [Seg] = []
        var index = 0
        while index < lines.count {
            if lines[index] == "0", index + 1 < lines.count, lines[index + 1] == "LINE" {
                var cursor = index + 2
                var entityLayer: String?
                var values: [String: Double] = [:]
                while cursor + 1 < lines.count, lines[cursor] != "0" {
                    let code = lines[cursor]
                    let raw = lines[cursor + 1]
                    if code == "8" { entityLayer = raw }
                    if ["10", "20", "11", "21"].contains(code), let v = Double(raw) {
                        values[code] = v
                    }
                    cursor += 2
                }
                if entityLayer == layer,
                   let x1 = values["10"], let y1 = values["20"],
                   let x2 = values["11"], let y2 = values["21"] {
                    segments.append(Seg(x1: x1, y1: y1, x2: x2, y2: y2))
                }
                index = cursor
            } else {
                index += 1
            }
        }
        return segments
    }

    private static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }

    private static func length(_ a: Vec2, _ b: Vec2) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }

    private static func contains(_ polygon: [Vec2], _ point: Vec2) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func distanceToSegment(_ point: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
