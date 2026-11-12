import Foundation
import Testing
@testable import RefabArtist

/// Radial Slices parts join with half-lap joints wherever a ring and a fin
/// cross. These tests put the cut-sheet parts back in the model (through their
/// plane frames) and check every joint: along the crossing line the ring holds
/// the model up to the meeting point and the fin from there out, never both;
/// around the line each part leaves the other's stock room; both cuts are the
/// slot width wide. Fins start far enough from the hub axis to clear each
/// other.
struct RadialJointTests {
    struct Case: CustomStringConvertible, Sendable {
        var fixture: String
        var fins: Int
        var thickness: Double
        var description: String { "\(fixture) n\(fins) t\(thickness)" }
    }

    static let cases: [Case] = [
        Case(fixture: "primitives/sphere_d50mm.stl", fins: 12, thickness: 5),
        Case(fixture: "primitives/sphere_d50mm.stl", fins: 6, thickness: 3),
        Case(fixture: "primitives/cylinder_d40_h80mm.stl", fins: 12, thickness: 5),
        Case(fixture: "primitives/cylinder_d40_h80mm.stl", fins: 4, thickness: 3),
        Case(fixture: "primitives/cube_50mm_binary.stl", fins: 12, thickness: 5),
        Case(fixture: "primitives/torus_R30_r10mm.stl", fins: 8, thickness: 3),
    ]

    @Test(arguments: cases)
    func everyCrossingIsAMatingHalfLap(_ testCase: Case) throws {
        let model = try Self.model(testCase.fixture)
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: testCase.fins, materialThickness: testCase.thickness))
        let primary = try #require(plan.primary)
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let document = CutSheetLayoutBuilder.document(radial: plan, model: model, settings: .defaultValue, revision: 1)
        let parts = document.sheets.flatMap(\.parts)
        let sections = StackedSliceContourer.generate(model: model, plan: primary).layers

        #expect(parts.allSatisfy { !$0.isError }, "a joint cut severed a part")
        // On these models every ring meets every fin once.
        #expect(assembly.joints.count == sections.count * RadialPartBuilder.wedgeCount(plan: plan))

        for joint in assembly.joints {
            let ring = try #require(document.part(labeled: "Z-\(joint.ringLayer + 1)"))
            let fin = try #require(document.part(labeled: "R-\(joint.fin + 1)"))
            #expect(abs(joint.width - plan.slotWidth) < 1.0e-12)
            #expect(joint.start < joint.meet && joint.meet < joint.end)
            let section = sections[joint.ringLayer].paths.map(\.points)
            let ringFrame = try #require(ring.planeFrame)
            // Along the line, wherever it runs through the model: the ring
            // holds it up to the meeting point and the fin after it, never
            // both, so the two slot depths add up to the crossing.
            let steps = 60
            for step in 1..<steps {
                let u = joint.inner + (joint.end - joint.inner) * Double(step) / Double(steps)
                guard abs(u - joint.meet) > 0.05, abs(u - joint.start) > 0.05 else { continue }
                let point = joint.point(at: u)
                let inModel = section.filter { CutSheetLayoutBuilder.contains($0, point: Self.planPoint(point, ringFrame)) }.count % 2 == 1
                let at = "\(ring.label)/\(fin.label) at u=\(u) (meet \(joint.meet))"
                #expect(Self.holds(ring, point) == (inModel && u < joint.meet), "\(at)")
                #expect(Self.holds(fin, point) == (inModel && u > joint.meet && u >= joint.start), "\(at)")
            }
        }
    }

    @Test(arguments: cases)
    func notchesAndSlotsTakeTheOtherPartsStock(_ testCase: Case) throws {
        let model = try Self.model(testCase.fixture)
        let thickness = testCase.thickness
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: testCase.fins, materialThickness: thickness))
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let document = CutSheetLayoutBuilder.document(radial: plan, model: model, settings: .defaultValue, revision: 1)
        var checked = 0
        for joint in assembly.joints {
            let ring = try #require(document.part(labeled: "Z-\(joint.ringLayer + 1)"))
            let fin = try #require(document.part(labeled: "R-\(joint.fin + 1)"))
            let ringNormal = try #require(ring.planeFrame).normal
            let finNormal = try #require(fin.planeFrame).normal
            // Within the beam where both parts' stock overlaps (half the stock
            // either side of both planes), each part leaves the other's half
            // of the crossing empty: the ring past the meeting point, the fin
            // before it.
            for (part, toward) in [(ring, joint.end), (fin, joint.start)] {
                let base = joint.point(at: (joint.meet + toward) / 2)
                for a in [-0.49, 0, 0.49] {
                    for b in [-0.49, 0, 0.49] {
                        let point = Vec3(
                            x: base.x + ringNormal.x * a * thickness + finNormal.x * b * thickness,
                            y: base.y + ringNormal.y * a * thickness + finNormal.y * b * thickness,
                            z: base.z + ringNormal.z * a * thickness + finNormal.z * b * thickness
                        )
                        #expect(!Self.holds(part, point), "\(part.label) blocks the crossing stock of \(ring.label)/\(fin.label)")
                        checked += 1
                    }
                }
            }
            // The ring's notch is exactly the slot width: material just past
            // either side of it, none inside.
            let across = joint.point(at: (joint.meet + joint.end) / 2)
            let ringEdge = Self.distanceToStock(ring, from: across, along: finNormal, limit: plan.slotWidth)
            #expect(abs(ringEdge - plan.slotWidth / 2) < 1.0e-6 || ringEdge.isInfinite,
                    "\(ring.label) notch half-width \(ringEdge)")
        }
        #expect(checked > 0)
    }

    @Test(arguments: cases)
    func finsStartWhereTheyClearTheirNeighbours(_ testCase: Case) throws {
        let model = try Self.model(testCase.fixture)
        let thickness = testCase.thickness
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: testCase.fins, materialThickness: thickness))
        let count = RadialPartBuilder.wedgeCount(plan: plan)
        let inset = RadialPartBuilder.hubInset(plan: plan)
        #expect(abs(inset - thickness / 2 / tan(.pi / Double(count))) < 1.0e-12)
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        for wedge in assembly.wedges {
            let minX = (wedge.loop + wedge.holes.flatMap { $0 }).map(\.x).min() ?? 0
            #expect(minX >= inset - 1.0e-6, "R-\(wedge.sliceIndex + 1) starts at \(minX), inside \(inset)")
        }

        // No model point lies in the stock of two fins: sample the space
        // around the hub axis, all the way up the model.
        let document = CutSheetLayoutBuilder.document(radial: plan, model: model, settings: .defaultValue, revision: 1)
        let fins = document.sheets.flatMap(\.parts).filter { $0.label.hasPrefix("R-") }
        let bounds = try #require(model.bounds)
        let center = RadialPartBuilder.boxCenter(bounds)
        let reach = inset + thickness * 2
        var sampled = 0
        for z in stride(from: bounds.min.z + 0.5, to: bounds.max.z, by: 4.0) {
            for x in stride(from: -reach, through: reach, by: 0.5) {
                for y in stride(from: -reach, through: reach, by: 0.5) where x * x + y * y <= reach * reach {
                    let point = Vec3(x: center.x + x, y: center.y + y, z: z)
                    let holding = fins.filter { fin in
                        guard let frame = fin.planeFrame else { return false }
                        let depth = Self.dot(Self.minus(point, frame.origin), frame.normal)
                        guard abs(depth) < thickness / 2 - 0.01 else { return false }
                        let onPlane = Vec3(x: point.x - frame.normal.x * depth,
                                           y: point.y - frame.normal.y * depth,
                                           z: point.z - frame.normal.z * depth)
                        return Self.holds(fin, onPlane)
                    }
                    sampled += 1
                    #expect(holding.count <= 1, "\(holding.map(\.label)) overlap at \(point)")
                }
            }
        }
        #expect(sampled > 0)
    }

    @Test
    func oneOrTwoFinsRunToTheHubAxis() throws {
        let model = try Self.model("primitives/sphere_d50mm.stl")
        for fins in [1, 2] {
            let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: fins, materialThickness: 5))
            #expect(RadialPartBuilder.hubInset(plan: plan) == 0)
        }
    }

    @Test
    func theNotchFactorNoLongerNarrowsTheJoints() throws {
        let model = try Self.model("primitives/sphere_d50mm.stl")
        let reference = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3))
        let referenceParts = RadialPartBuilder.assembly(plan: reference, model: model)
        for factor in [0.1, 2.0] {
            let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3, notchFactor: factor))
            let parts = RadialPartBuilder.assembly(plan: plan, model: model)
            #expect(parts.disks.map(\.loop) == referenceParts.disks.map(\.loop))
            #expect(parts.wedges.map(\.loop) == referenceParts.wedges.map(\.loop))
        }
        // The slot offset and the notch-width override do set the width.
        let offset = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3, slotClearance: 0.25))
        #expect(RadialPartBuilder.assembly(plan: offset, model: model).joints.allSatisfy { abs($0.width - 3.25) < 1.0e-12 })
        let override = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3, notchWidthOverride: 3.6))
        #expect(RadialPartBuilder.assembly(plan: override, model: model).joints.allSatisfy { abs($0.width - 3.6) < 1.0e-12 })
    }

    @Test
    func hollowSectionsKeepTheirHoles() throws {
        // The torus's rings are annuli: one part each, with its hole, not a
        // ring and a disc filling the hole.
        let model = try Self.model("primitives/torus_R30_r10mm.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 3))
        let disks = RadialPartBuilder.assembly(plan: plan, model: model).disks
        #expect(disks.count == plan.primary?.positions.count)
        #expect(disks.allSatisfy { $0.holes.count == 1 && $0.componentIndex == 0 })
    }

    @Test
    func radialDxfPartFramesPutEveryPartBackWhereItCameFrom() throws {
        // A narrow sheet turns the chair's long parts a quarter to fit it;
        // their frames must undo that too.
        let model = try Self.model("real-world/simple_chair.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5))
        let primary = try #require(plan.primary)
        let settings = ExportLayoutSettings(partSpacing: 10, pageMargin: 10, sheetWidth: 120, sheetHeight: 3000)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dxfURL = directory.appending(path: "parts.dxf")
        let framesURL = directory.appending(path: "parts.frames.json")
        try DxfExporter.write(radial: plan, model: model, to: dxfURL, layoutSettings: settings)
        try DxfExporter.writePartFrames(radial: plan, model: model, to: framesURL, layoutSettings: settings)

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: framesURL)) as? [String: Any])
        let frames = try #require(json["parts"] as? [[String: Any]])
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let families = [("first_axis", assembly.disks), ("radial", assembly.wedges)]
        #expect(frames.count == assembly.disks.count + assembly.wedges.count)
        let lines = Self.dxfLines(try String(contentsOf: dxfURL, encoding: .utf8))
        let center = RadialPartBuilder.boxCenter(try #require(model.bounds))
        var turned = 0
        for (prefix, parts) in families {
            for (index, part) in parts.enumerated() {
                let label = String(format: "\(prefix)_%03d", index + 1)
                let entry = try #require(frames.first { $0["label"] as? String == label })
                let rows = try #require(entry["dxfToModel"] as? [[Double]])
                let frame = prefix == "radial"
                    ? RadialPartBuilder.wedgeFrame(center: center, axis: primary.axis, angle: part.position)
                    : RadialPartBuilder.diskFrame(axis: primary.axis, position: part.position)
                if abs(rows[0][0] - frame.xAxis.x) + abs(rows[1][0] - frame.xAxis.y) + abs(rows[2][0] - frame.xAxis.z) > 1.0e-9 {
                    turned += 1
                }
                // Every drawn corner, taken back through the frame, is a
                // corner of the part.
                let corners = part.loop + part.holes.flatMap { $0 }
                let drawn = try #require(lines[label])
                #expect(drawn.count == corners.count)
                for point in drawn {
                    let modelPoint = Vec3(
                        x: rows[0][0] * point.x + rows[0][1] * point.y + rows[0][2],
                        y: rows[1][0] * point.x + rows[1][1] * point.y + rows[1][2],
                        z: rows[2][0] * point.x + rows[2][1] * point.y + rows[2][2]
                    )
                    let plan = Self.planPoint(modelPoint, frame)
                    #expect(abs(Self.dot(Self.minus(modelPoint, frame.origin), frame.normal)) < 1.0e-6, "\(label)")
                    #expect(corners.contains { abs($0.x - plan.x) < 1.0e-4 && abs($0.y - plan.y) < 1.0e-4 },
                            "\(label) corner \(plan) is not on the part")
                }
            }
        }
        #expect(turned > 0)
    }

    // MARK: - Helpers

    private static func model(_ fixture: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/\(fixture)"))
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

    /// How far from `point` (inside a notch) the part's material starts, both
    /// ways along `direction`, when the two agree; infinity when there is no
    /// material within `limit` either way (the notch runs off the part).
    private static func distanceToStock(_ part: CutSheetPart, from point: Vec3, along direction: Vec3, limit: Double) -> Double {
        func edge(_ sign: Double) -> Double? {
            guard !holds(part, point) else { return 0 }
            var lo = 0.0
            var hi = limit
            let at = { (d: Double) in
                Vec3(x: point.x + direction.x * d * sign, y: point.y + direction.y * d * sign, z: point.z + direction.z * d * sign)
            }
            guard holds(part, at(hi)) else { return nil }
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                if holds(part, at(mid)) { hi = mid } else { lo = mid }
            }
            return hi
        }
        guard let plus = edge(1), let minus = edge(-1) else { return .infinity }
        return abs(plus - minus) < 1.0e-6 ? plus : -1
    }

    /// LINE start points per layer of a DXF: each closed loop's corners.
    private static func dxfLines(_ text: String) -> [String: [Vec2]] {
        let rows = text.components(separatedBy: "\n")
        var result: [String: [Vec2]] = [:]
        var index = 0
        while index + 1 < rows.count {
            if rows[index].trimmingCharacters(in: .whitespaces) == "0", rows[index + 1] == "LINE" {
                var layer = ""
                var x = 0.0
                var y = 0.0
                var cursor = index + 2
                while cursor + 1 < rows.count, rows[cursor].trimmingCharacters(in: .whitespaces) != "0" {
                    let code = rows[cursor].trimmingCharacters(in: .whitespaces)
                    let value = rows[cursor + 1]
                    if code == "8" { layer = value }
                    if code == "10" { x = Double(value) ?? 0 }
                    if code == "20" { y = Double(value) ?? 0 }
                    cursor += 2
                }
                result[layer, default: []].append(Vec2(x: x, y: y))
                index = cursor
            } else {
                index += 2
            }
        }
        return result
    }

    private static func planPoint(_ point: Vec3, _ frame: PartPlaneFrame) -> Vec2 {
        let offset = minus(point, frame.origin)
        return Vec2(x: dot(offset, frame.xAxis), y: dot(offset, frame.yAxis))
    }

    private static func minus(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
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
