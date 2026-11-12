import Foundation
import Testing
@testable import RefabArtist

/// Curve Slices parts join with half-lap slots wherever a first-axis rib and
/// a curve rib cross. These tests put the cut-sheet parts back in the model
/// (through their plane frames) and check every joint: along the crossing
/// line the two parts' material meets without overlapping, and each slot is
/// wide enough for the other part's stock. Curve ribs that would run into each
/// other stop short.
struct CurveJointTests {
    /// First axis and amplitude: the spline bows toward +y (curve ribs cut
    /// short on their -n side) or toward -y (cut short on their +n side, so
    /// with first axis Z they slide in the other way). With first axis X the
    /// spline runs along Y.
    static let layouts: [(SliceAxis, Double)] = [(.z, 10), (.y, 10), (.z, -10), (.y, -10), (.x, 10)]

    @Test(arguments: layouts)
    func everyCrossingOnTheSphereIsAMatingHalfLap(axis: SliceAxis, amplitude: Double) throws {
        let model = try Self.sphereModel()
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: 3, amplitude: amplitude))
        let joints = Self.joints(model: model, plan: plan)
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let parts = document.sheets.flatMap(\.parts)

        #expect(joints.count > 2 * plan.sliceCount)
        #expect(parts.allSatisfy { !$0.isError })
        // Every rib crosses another, so every part has slots cut into it: its
        // outline encloses less than its plain section.
        let primarySections = CurveSliceContourer.firstAxisContours(model: model, plan: plan).layers
        let curveSections = CurveSliceContourer.generate(model: model, plan: plan).layers
        let letter = CutSheetLayoutBuilder.axisLetter(plan.primary.axis)
        #expect(parts.count == primarySections.count + curveSections.count)
        for part in parts {
            let index = try #require(Int(part.label.split(separator: "-")[1])) - 1
            let section = part.label.hasPrefix("C-") ? curveSections[index].paths : primarySections[index].paths
            let plain = section.map { abs(CutSheetLayoutBuilder.signedArea($0.points)) }.max() ?? 0
            let slotted = abs(CutSheetLayoutBuilder.signedArea(part.cutLoops[0]))
            #expect(slotted < plain - 1, "\(part.label) has no slots")
        }

        for joint in joints {
            let primary = try #require(document.part(labeled: "\(letter)-\(joint.primaryLayer + 1)"))
            let curve = try #require(document.part(labeled: "C-\(joint.curveLayer + 1)"))
            let length = Self.distance(joint.start, joint.end)
            let meetAt = Self.distance(joint.start, joint.meet)
            let section = primarySections[joint.primaryLayer].paths.map(\.points)
            let frame = try #require(primary.planeFrame)
            // Along the line, wherever it runs through the model: the
            // first-axis part holds it before the meeting point and the curve
            // part after it, never both. (The joint's span covers the whole
            // beam, so the line itself can leave the model near its ends.)
            for step in 1..<40 {
                let along = length * Double(step) / 40
                guard abs(along - meetAt) > 0.05 else { continue }
                let point = Self.lerp(joint.start, joint.end, along / length)
                let inModel = section.filter { CutSheetLayoutBuilder.contains($0, point: Self.planPoint(point, frame)) }.count % 2 == 1
                let inPrimary = Self.holds(primary, point)
                let inCurve = Self.holds(curve, point)
                let at = "\(primary.label)/\(curve.label) at \(along) of \(length)"
                #expect(inPrimary == (inModel && along < meetAt), "\(at)")
                #expect(inCurve == (inModel && along > meetAt), "\(at)")
            }
        }
    }

    @Test(arguments: layouts)
    func slotsClearTheCrossingStock(axis: SliceAxis, amplitude: Double) throws {
        let model = try Self.sphereModel()
        let thickness = 3.0
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: thickness, amplitude: amplitude))
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let letter = CutSheetLayoutBuilder.axisLetter(plan.primary.axis)
        var checked = 0
        for joint in Self.joints(model: model, plan: plan) {
            let primary = try #require(document.part(labeled: "\(letter)-\(joint.primaryLayer + 1)"))
            let curve = try #require(document.part(labeled: "C-\(joint.curveLayer + 1)"))
            let primaryNormal = try #require(primary.planeFrame).normal
            let curveNormal = try #require(curve.planeFrame).normal
            // Within the beam where both parts' stock overlaps (half the
            // stock either side of both planes), each part leaves its slot
            // half empty: the first-axis part past the meeting point, the
            // curve part before it.
            for (part, toward) in [(primary, joint.end), (curve, joint.start)] {
                let base = Self.lerp(joint.meet, toward, 0.5)
                for a in [-0.49, 0.49] {
                    for b in [-0.49, 0.49] {
                        let shift = try #require(Self.solve(primaryNormal, curveNormal, Self.direction(joint),
                                                            a * thickness, b * thickness))
                        let point = Vec3(x: base.x + shift.x, y: base.y + shift.y, z: base.z + shift.z)
                        #expect(!Self.holds(part, point), "\(part.label) blocks the crossing stock")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 0)
        // A slanted crossing needs a wider slot than a square one.
        let widths = Self.joints(model: model, plan: plan).map(\.width)
        #expect(widths.allSatisfy { $0 >= plan.slotWidth - 1.0e-9 })
        if axis == .z {
            #expect(widths.allSatisfy { abs($0 - plan.slotWidth) < 1.0e-9 })
        } else {
            #expect(widths.contains { $0 > plan.slotWidth + 0.1 })
        }
    }

    @Test(arguments: layouts)
    func curveRibsStopShortOfEachOther(axis: SliceAxis, amplitude: Double) throws {
        let model = try Self.sphereModel()
        let thickness = 3.0
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: thickness, amplitude: amplitude))
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let ribs = (1...plan.sliceCount).compactMap { document.part(labeled: "C-\($0)") }
        #expect(ribs.count == plan.sliceCount)

        // Ribs along a bowed spline fan in on its concave side: some are cut
        // short there, none on the convex side.
        let reach = CurveJointPlanner.slots(
            plan: plan,
            primary: CurveSliceContourer.firstAxisContours(model: model, plan: plan),
            curve: CurveSliceContourer.generate(model: model, plan: plan)
        ).curveReach
        let concaveIsLow = amplitude > 0
        #expect(reach.contains { concaveIsLow ? $0.lo > -25 : $0.hi < 25 })
        #expect(reach.allSatisfy { concaveIsLow ? $0.hi == .infinity : $0.lo == -.infinity })

        try Self.expectRibsClearEachOther(ribs, thickness: thickness)
    }

    /// In 5 mm stock twelve curve ribs would stand 4.6 mm apart along the
    /// spline, too close for a stock-thick web between their slots: as many
    /// as stand far enough apart are cut instead (five with first axis Z,
    /// about 11 mm apart; three with first axis X or Y, whose slanted
    /// crossings need wider slots), and none passes through another.
    @Test(arguments: layouts)
    func curveRibsInThickStockAreAsManyAsStandApart(axis: SliceAxis, amplitude: Double) throws {
        let model = try Self.sphereModel()
        let thickness = 5.0
        let plan = try #require(Self.plan(model: model, axis: axis, thickness: thickness, amplitude: amplitude))
        #expect(plan.requestedSliceCount == 12)
        #expect(plan.sliceCount == (axis == .z ? 5 : 3))
        #expect(CurveJointPlanner.ribLayout(plan: plan).standsClear)
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
        let ribs = (1...plan.sliceCount).compactMap { document.part(labeled: "C-\($0)") }
        #expect(ribs.count == plan.sliceCount)
        #expect(document.sheets.flatMap(\.parts).allSatisfy { !$0.isError })
        try Self.expectRibsClearEachOther(ribs, thickness: thickness)
    }

    @Test
    func theCurveRibCountFollowsTheStockThickness() throws {
        let model = try Self.sphereModel()
        // 3 mm: eight of the twelve stand far enough apart for a 3 mm web
        // between their slots.
        let thin = try #require(Self.plan(model: model, axis: .z, thickness: 3))
        #expect(thin.sliceCount == 8)
        #expect(thin.requestedSliceCount == 12)
        // Six ribs fit with the count left as asked.
        let few = try #require(CurveSlicePlanner.plan(
            model: model, primaryAxis: .z, materialThickness: 3, firstAxisCount: 7,
            curveSliceCount: 6, amplitude: 10, slotWidth: 3, slotAngleDegrees: 0
        ))
        #expect(few.sliceCount == 6)
        #expect(few.requestedSliceCount == nil)
        #expect(few.curveCountNote == nil)
        // Whatever the stock, every two ribs kept stand apart, and one more
        // would not.
        for thickness in [3.0, 4.0, 5.0, 8.0, 12.0] {
            let plan = try #require(Self.plan(model: model, axis: .z, thickness: thickness))
            let stations = (0..<plan.sliceCount).map {
                CurveJointPlanner.RibStation(center: plan.centers[$0], direction: plan.directions[$0], normal: plan.normals[$0])
            }
            for i in stations.indices {
                for j in stations.indices where j > i {
                    #expect(CurveJointPlanner.ribsStandApart(stations[i], stations[j], thickness: thickness, slotWidth: thickness),
                            "\(thickness) mm: C-\(i + 1) and C-\(j + 1)")
                }
            }
            if plan.sliceCount < 12 {
                #expect(plan.requestedSliceCount == 12)
                let more = try #require(CurveSlicePlanner.plan(
                    model: model, primaryAxis: .z, materialThickness: thickness, firstAxisCount: 7,
                    curveSliceCount: plan.sliceCount + 1, amplitude: 10, slotWidth: thickness, slotAngleDegrees: 0
                ))
                #expect(more.sliceCount == plan.sliceCount, "\(thickness) mm")
            }
            // The parts still come out, down to a single curve rib.
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            #expect(document.part(labeled: "C-\(plan.sliceCount)") != nil, "\(thickness) mm")
        }
        // Stock thicker than half the curve is long leaves room for one rib.
        let thickest = try #require(Self.plan(model: model, axis: .z, thickness: 30))
        #expect(thickest.sliceCount == 1)
        #expect(thickest.requestedSliceCount == 12)
    }

    @Test
    func parallelRibsOnAStraightCurveStandTheirStockAndAGapApart() throws {
        let model = try Self.sphereModel()
        // A straight 50 mm spline: the ribs are parallel, 50 / n apart.
        let straight = { (count: Int, thickness: Double) in
            CurveSlicePlanner.plan(
                model: model, primaryAxis: .z, materialThickness: thickness, firstAxisCount: 7,
                curveSliceCount: count, splineControlPoints: [Vec2(x: -25, y: 0), Vec2(x: 25, y: 0)],
                slotWidth: thickness, slotAngleDegrees: 0
            )
        }
        // Ten ribs 5 mm apart in 2.5 mm stock leave a 2.5 mm web between
        // their slots; in 2.6 mm stock the web would be 2.4 mm, thinner than
        // the stock, and nine (5.56 mm apart) are cut.
        #expect(try #require(straight(10, 2.5)).sliceCount == 10)
        let tight = try #require(straight(10, 2.6))
        #expect(tight.sliceCount == 9)
        #expect(tight.requestedSliceCount == 10)
    }

    @Test
    func aSlotThatCutsOffAJointsMaterialFlagsThePartAndACutOverItAllLeavesNothing() {
        let square = [Vec2(x: 0, y: 0), Vec2(x: 10, y: 0), Vec2(x: 10, y: 10), Vec2(x: 0, y: 10)]
        let island = CutSheetLayoutBuilder.Island(loops: [square], openPaths: [])
        // A slot right across the part, leaving a 3 mm strip that gets dropped.
        let slot = [Vec2(x: -1, y: 3), Vec2(x: 11, y: 3), Vec2(x: 11, y: 5), Vec2(x: -1, y: 5)]
        let keepsTheWiderPiece = CutSheetLayoutBuilder.cuttingSlots([slot], from: island, keeping: [Vec2(x: 5, y: 8)])
        #expect(!keepsTheWiderPiece.isError)
        let keepsTheDroppedStrip = CutSheetLayoutBuilder.cuttingSlots([slot], from: island, keeping: [Vec2(x: 5, y: 1)])
        #expect(keepsTheDroppedStrip.isError)
        // A cut over the whole part leaves nothing, not the part untouched;
        // unless the part holds a joint's material: then it is flagged.
        let over = [Vec2(x: -1, y: -1), Vec2(x: 11, y: -1), Vec2(x: 11, y: 11), Vec2(x: -1, y: 11)]
        let cutAway = CutSheetLayoutBuilder.cuttingSlots([over], from: island)
        #expect(cutAway.loops.isEmpty && cutAway.openPaths.isEmpty)
        let cutAwayFromAJoint = CutSheetLayoutBuilder.cuttingSlots([over], from: island, keeping: [Vec2(x: 5, y: 5)])
        #expect(cutAwayFromAJoint.isError && cutAwayFromAJoint.loops == [square])
    }

    @Test
    func theMeetingPointStaysInTheMiddleUnlessASlotWouldRunIntoAHole() {
        let span = CurveJointPlanner.Span(lo: 0, hi: 10)
        #expect(CurveJointPlanner.meetingPoint(of: span, forwardGaps: [], backwardGaps: []) == 5)
        // A hole in the rib slotted toward larger u, past the middle: its slot
        // starts beyond it.
        #expect(CurveJointPlanner.meetingPoint(
            of: span, forwardGaps: [CurveJointPlanner.Span(lo: 5, hi: 6.5)], backwardGaps: []
        ) == 7.5)
        // A hole in the rib slotted toward smaller u, below the middle: its
        // slot stops short of it.
        #expect(CurveJointPlanner.meetingPoint(
            of: span, forwardGaps: [], backwardGaps: [CurveJointPlanner.Span(lo: 3, hi: 4)]
        ) == 2)
        // Both cannot be met: the middle.
        #expect(CurveJointPlanner.meetingPoint(
            of: span, forwardGaps: [CurveJointPlanner.Span(lo: 6, hi: 7)], backwardGaps: [CurveJointPlanner.Span(lo: 3, hi: 4)]
        ) == 5)
    }

    @Test
    func partFramesPutEveryCurvePartBackOnItsPlane() throws {
        let model = try Self.sphereModel()
        let plan = try #require(Self.plan(model: model, axis: .z, thickness: 3))
        let settings = ExportLayoutSettings.defaultValue
        let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: settings, revision: 1)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-curve-frames-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try CutSheetDocumentExporter.writePartFrames(document: document, settings: settings, to: url)

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let frames = try #require(json["parts"] as? [[String: Any]])
        #expect(frames.count == document.partCount)
        for (index, sheet) in document.sheets.enumerated() {
            let top = CutSheetDocumentExporter.dxfY(sheetIndex: index, sheetHeight: settings.sanitized.sheetHeight)
            for part in sheet.parts {
                let entry = try #require(frames.first { $0["label"] as? String == part.label })
                let rows = try #require(entry["dxfToModel"] as? [[Double]])
                // Every outline point, where the DXF puts it, lands on the
                // sphere's surface or inside it (slot corners), and on the
                // part's plane.
                for p in part.cutLoops[0] {
                    let x = p.x, y = top - p.y
                    let point = Vec3(
                        x: rows[0][0] * x + rows[0][1] * y + rows[0][2],
                        y: rows[1][0] * x + rows[1][1] * y + rows[1][2],
                        z: rows[2][0] * x + rows[2][1] * y + rows[2][2]
                    )
                    let radius = (point.x * point.x + point.y * point.y + point.z * point.z).squareRoot()
                    #expect(radius <= 25.0 + 1.0e-6, "\(part.label)")
                    let frame = try #require(part.planeFrame)
                    let offset = Vec3(x: point.x - frame.origin.x, y: point.y - frame.origin.y, z: point.z - frame.origin.z)
                    #expect(abs(Self.dot(offset, frame.normal)) < 1.0e-6, "\(part.label)")
                }
            }
        }
    }

    @Test
    func meshAndEpsOutputsCarryTheSameSlots() throws {
        let model = try Self.sphereModel()
        let plan = try #require(Self.plan(model: model, axis: .z, thickness: 3))
        let primary = CurveSliceContourer.firstAxisContours(model: model, plan: plan)
        let curve = CurveSliceContourer.generate(model: model, plan: plan)
        let slots = CurveJointPlanner.slots(plan: plan, primary: primary, curve: curve)
        let slotted = slots.primaryPaths
        for (layer, paths) in zip(primary.layers, slotted) {
            let plain = layer.paths.map { abs(CutSheetLayoutBuilder.signedArea($0.points)) }.reduce(0, +)
            let cut = paths.map { abs(CutSheetLayoutBuilder.signedArea($0.points)) }.reduce(0, +)
            #expect(cut < plain - 1)
        }
    }

    // MARK: - Helpers

    private static func plan(model: MeshSummary, axis: SliceAxis, thickness: Double, amplitude: Double = 10) -> CurveSlicePlan? {
        CurveSlicePlanner.plan(
            model: model,
            primaryAxis: axis,
            materialThickness: thickness,
            firstAxisCount: 7,
            curveSliceCount: 12,
            amplitude: amplitude,
            slotWidth: thickness,
            slotAngleDegrees: 0
        )
    }

    private static func joints(model: MeshSummary, plan: CurveSlicePlan) -> [CurveJointPlanner.Joint] {
        CurveJointPlanner.slots(
            plan: plan,
            primary: CurveSliceContourer.firstAxisContours(model: model, plan: plan),
            curve: CurveSliceContourer.generate(model: model, plan: plan)
        ).joints
    }

    /// No model point lies in the stock of two curve ribs: sample the beam
    /// where each pair's stock could overlap, all the way up the sphere.
    private static func expectRibsClearEachOther(_ ribs: [CutSheetPart], thickness: Double) throws {
        var sampled = 0
        for (i, a) in ribs.enumerated() {
            let frameA = try #require(a.planeFrame)
            // Each rib keeps its middle, where it leaves the spline (between
            // the slots at the first-axis ribs' heights).
            let middle = Vec3(x: frameA.origin.x, y: frameA.origin.y, z: 3.5)
            #expect(holds(a, middle), "\(a.label) lost its middle")
            for b in ribs[(i + 1)...] {
                let frameB = try #require(b.planeFrame)
                let up = Vec3(x: 0, y: 0, z: 1)
                for p in stride(from: -0.5, through: 0.5, by: 0.25) {
                    for q in stride(from: -0.5, through: 0.5, by: 0.25) {
                        guard let shift = solve(frameA.normal, frameB.normal, up, p * thickness, q * thickness),
                              let base = solve(frameA.normal, frameB.normal, up,
                                               dot(frameA.origin, frameA.normal),
                                               dot(frameB.origin, frameB.normal)) else { continue }
                        for z in stride(from: -24.5, through: 24.5, by: 1.0) {
                            let point = Vec3(x: base.x + shift.x, y: base.y + shift.y, z: z)
                            guard (point.x * point.x + point.y * point.y + z * z).squareRoot() < 25 else { continue }
                            sampled += 1
                            #expect(!(holds(a, point) && holds(b, point)),
                                    "\(a.label) and \(b.label) collide at \(point)")
                        }
                    }
                }
            }
        }
        #expect(sampled > 0)
    }

    /// Whether the cut part has material at the model point (projected onto
    /// its plane), counting its cut loops even-odd.
    private static func holds(_ part: CutSheetPart, _ point: Vec3) -> Bool {
        guard let frame = part.planeFrame else { return false }
        let plan = planPoint(point, frame)
        let local = Vec2(x: plan.x - part.planMin.x, y: plan.y - part.planMin.y)
        let sheet: Vec2
        if part.rotatedOnSheet {
            let localHeight = part.bounds.max.x - part.bounds.min.x
            sheet = Vec2(x: part.bounds.min.x + localHeight - local.y, y: part.bounds.min.y + local.x)
        } else {
            sheet = Vec2(x: part.bounds.min.x + local.x, y: part.bounds.min.y + local.y)
        }
        return part.cutLoops.filter { CutSheetLayoutBuilder.contains($0, point: sheet) }.count % 2 == 1
    }

    private static func planPoint(_ point: Vec3, _ frame: PartPlaneFrame) -> Vec2 {
        let offset = Vec3(x: point.x - frame.origin.x, y: point.y - frame.origin.y, z: point.z - frame.origin.z)
        return Vec2(x: dot(offset, frame.xAxis), y: dot(offset, frame.yAxis))
    }

    private static func direction(_ joint: CurveJointPlanner.Joint) -> Vec3 {
        let length = distance(joint.start, joint.end)
        return Vec3(x: (joint.end.x - joint.start.x) / length,
                    y: (joint.end.y - joint.start.y) / length,
                    z: (joint.end.z - joint.start.z) / length)
    }

    /// The vector `w` with `n1 · w = a`, `n2 · w = b`, `d · w = 0`.
    private static func solve(_ n1: Vec3, _ n2: Vec3, _ d: Vec3, _ a: Double, _ b: Double) -> Vec3? {
        let c2d = cross(n2, d), cd1 = cross(d, n1)
        let det = dot(n1, c2d)
        guard abs(det) > 1.0e-12 else { return nil }
        return Vec3(x: (a * c2d.x + b * cd1.x) / det, y: (a * c2d.y + b * cd1.y) / det, z: (a * c2d.z + b * cd1.z) / det)
    }

    private static func lerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    private static func distance(_ a: Vec3, _ b: Vec3) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
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

private extension PartPlaneFrame {
    var normal: Vec3 {
        Vec3(
            x: xAxis.y * yAxis.z - xAxis.z * yAxis.y,
            y: xAxis.z * yAxis.x - xAxis.x * yAxis.z,
            z: xAxis.x * yAxis.y - xAxis.y * yAxis.x
        )
    }
}
