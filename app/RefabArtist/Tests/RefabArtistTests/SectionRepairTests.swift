import Foundation
import Testing
@testable import RefabArtist

/// Sections of meshes as real scans and exports come: cracked open, wound
/// both ways or inside out, and pieces meeting at a corner. Every outline
/// Curve, Radial and Stacked cut from a cracked mesh, or from pieces that
/// meet at a corner, is a simple loop (no outline touching itself), and a
/// mesh whose triangles disagree about which way they face, or all face
/// inward, is cut as if they agreed and faced out.
struct SectionRepairTests {
    // MARK: - Mixed winding

    /// A mesh whose triangles agree and face out gets nothing flipped; one
    /// whose triangles disagree gets the ones fewer of its triangles agree
    /// with flipped; one wound wholly inside out gets every triangle flipped.
    @Test
    func meshWindingFlipsOnlyTheTrianglesThatDisagree() throws {
        let torus = try Self.model("primitives/torus_R30_r10mm.stl")
        #expect(MeshWinding.consistentFlips(CurveSliceContourer.meshTriangles(torus)) == nil)
        #expect(MeshWinding.signedVolume(CurveSliceContourer.meshTriangles(torus)) > 0)
        // Wound wholly inside out: they agree with each other but face in.
        let inverted = try Self.model("pathological/torus_inverted.stl")
        let invertedTriangles = CurveSliceContourer.meshTriangles(inverted)
        #expect(MeshWinding.signedVolume(invertedTriangles) < 0)
        let all = try #require(MeshWinding.consistentFlips(invertedTriangles))
        #expect(all.allSatisfy { $0 })
        // Two thirds wound inward: the patch's majority faces in, so after
        // the triangles are made to agree the whole mesh is turned to face
        // out, and exactly the inward ones are flipped.
        let reference = CurveSliceContourer.meshTriangles(torus)
        let mostlyInward = reference.enumerated().map { index, triangle in
            index % 3 == 0 ? triangle : (triangle.0, triangle.2, triangle.1)
        }
        let turned = try #require(MeshWinding.consistentFlips(mostlyInward))
        #expect(turned.enumerated().allSatisfy { index, flip in flip == (index % 3 != 0) })

        let mixed = try Self.model("pathological/torus_mixed_winding.stl")
        let triangles = CurveSliceContourer.meshTriangles(mixed)
        let flips = try #require(MeshWinding.consistentFlips(triangles))
        #expect(flips.filter { $0 }.count == 600)
        // Exactly the triangles wound inward are flipped.
        for index in triangles.indices {
            let turned = triangles[index].1 != reference[index].1
            #expect(flips[index] == turned, "triangle \(index)")
        }
    }

    /// Radial and Curve cut the same parts from the torus whose inner third
    /// is wound inward, and from the torus wound wholly inside out, as from
    /// the torus: rings and first-axis ribs keep their hole.
    @Test(arguments: [
        ("pathological/torus_mixed_winding.stl", 3.0), ("pathological/torus_mixed_winding.stl", 5.0),
        ("pathological/torus_inverted.stl", 3.0), ("pathological/torus_inverted.stl", 5.0)
    ])
    func aMeshWoundBothWaysIsCutAsTheConsistentOne(_ fixture: String, _ thickness: Double) throws {
        let torus = try Self.model("primitives/torus_R30_r10mm.stl")
        let mixed = try Self.model(fixture)

        func radialParts(_ model: MeshSummary) throws -> [String: (Double, Int)] {
            let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: thickness))
            let document = CutSheetLayoutBuilder.document(radial: plan, model: model, settings: .defaultValue, revision: 1)
            return Self.areas(document)
        }
        func curveParts(_ model: MeshSummary) throws -> [String: (Double, Int)] {
            let plan = try #require(CurveSlicePlanner.plan(
                model: model, primaryAxis: .z, materialThickness: thickness, firstAxisCount: 7,
                curveSliceCount: 12, amplitude: 10, slotWidth: thickness, slotAngleDegrees: 0
            ))
            let document = CutSheetLayoutBuilder.document(curve: plan, model: model, settings: .defaultValue, revision: 1)
            return Self.areas(document)
        }
        for (name, expected, cut) in [
            ("radial", try radialParts(torus), try radialParts(mixed)),
            ("curve", try curveParts(torus), try curveParts(mixed))
        ] {
            #expect(Set(cut.keys) == Set(expected.keys), "\(name)")
            for (label, part) in expected {
                let other = try #require(cut[label], "\(name) \(label)")
                #expect(abs(other.0 - part.0) < 0.01 && other.1 == part.1, "\(name) \(label): \(other) vs \(part)")
            }
            // Every ring is an annulus, and some first-axis rib keeps its hole.
            let rings = cut.filter { $0.key.hasPrefix("Z-") }
            #expect(name == "radial" ? rings.allSatisfy { $0.value.1 == 2 } : rings.contains { $0.value.1 == 2 }, "\(name)")
        }
    }

    // MARK: - Outlines that touch themselves

    /// An outline that touches itself at a point is split into the lobes on
    /// either side; a simple outline, or one whose lobe is a hole touching
    /// the edge, comes back as it is.
    @Test
    func pinchedOutlinesAreSplitIntoTheirLobes() throws {
        // Two unit squares meeting at the corner (1, 1), walked as one loop.
        let figureEight = [
            Vec2(x: 0, y: 0), Vec2(x: 1, y: 0), Vec2(x: 1, y: 1), Vec2(x: 2, y: 1),
            Vec2(x: 2, y: 2), Vec2(x: 1, y: 2), Vec2(x: 1, y: 1), Vec2(x: 0, y: 1)
        ]
        let lobes = CutSheetLayoutBuilder.separatingPinches(figureEight)
        #expect(lobes.count == 2)
        #expect(lobes.allSatisfy { abs(CutSheetLayoutBuilder.signedArea($0) - 1) < 1.0e-9 })
        // A section that pinches so is cut as two pieces, each a part of its
        // own; a slot into one leaves both simple.
        let large = figureEight.map { Vec2(x: $0.x * 10, y: $0.y * 10) }
        let islands = CutSheetLayoutBuilder.islandize(paths: [SlicePath2D(points: large + [large[0]], closed: true)])
        #expect(islands.count == 2)
        #expect(islands.allSatisfy { $0.loops.count == 1 && abs(CutSheetLayoutBuilder.signedArea($0.loops[0])) > 99.9 })
        let slot = [Vec2(x: 4, y: 5), Vec2(x: 6, y: 5), Vec2(x: 6, y: 12), Vec2(x: 4, y: 12)]
        for island in islands {
            for piece in CutSheetLayoutBuilder.slottedPieces([slot], from: island, keepingEveryPiece: true) {
                #expect(piece.loops.allSatisfy { CutSheetLayoutBuilder.separatingPinches($0).count == 1 })
            }
        }
        // A lobe whose corner rests on another stretch of the outline (a
        // T-touch, the way a cut leaves it).
        let tee = [
            Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 1), Vec2(x: 3, y: 1),
            Vec2(x: 2, y: 1), Vec2(x: 2.5, y: 2), Vec2(x: 1.5, y: 2), Vec2(x: 2, y: 1.000001),
            Vec2(x: 1, y: 1), Vec2(x: 0, y: 1)
        ]
        let teeLobes = CutSheetLayoutBuilder.separatingPinches(tee)
        #expect(teeLobes.count == 2)
        #expect(abs(teeLobes.map { CutSheetLayoutBuilder.signedArea($0) }.reduce(0, +) - CutSheetLayoutBuilder.signedArea(tee)) < 1.0e-5)
        // A square is left alone, point for point.
        let square = [Vec2(x: 0, y: 0), Vec2(x: 3, y: 0), Vec2(x: 3, y: 3), Vec2(x: 0, y: 3)]
        #expect(CutSheetLayoutBuilder.separatingPinches(square) == [square])
        // A hole that touches the edge stays part of its outline.
        let keyhole = [
            Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 4), Vec2(x: 2, y: 4),
            Vec2(x: 1, y: 3), Vec2(x: 3, y: 3), Vec2(x: 2, y: 4), Vec2(x: 0, y: 4)
        ]
        #expect(CutSheetLayoutBuilder.separatingPinches(keyhole) == [keyhole])
        // A figure of eight that crosses over at the touch turns its lobes
        // opposite ways; both are material, so both come back turned like
        // the larger (counter-clockwise here), neither starting at the touch.
        let crossing = [
            Vec2(x: 5, y: 10), Vec2(x: 2, y: 2), Vec2(x: 2, y: 0), Vec2(x: 0, y: 0),
            Vec2(x: 0, y: 2), Vec2(x: 2, y: 2), Vec2(x: 6, y: 3), Vec2(x: 6, y: 10)
        ]
        let crossingLobes = CutSheetLayoutBuilder.separatingPinches(crossing)
        #expect(crossingLobes.count == 2)
        #expect(crossingLobes.allSatisfy { CutSheetLayoutBuilder.signedArea($0) > 0 })
        #expect(crossingLobes.allSatisfy { $0.first != Vec2(x: 2, y: 2) })
        let crossingArea: Double = crossingLobes.map { CutSheetLayoutBuilder.signedArea($0) }.reduce(0, +)
        #expect(abs(crossingArea - 22) < 1.0e-9)
        #expect(crossingLobes.allSatisfy { !Self.pinches($0) })
    }

    /// Two blocks that meet along one edge: every Stacked section is two
    /// pieces touching at a corner, which the contourer joins into one
    /// figure of eight. The layers Stacked cuts (`closingCracks`: the cut
    /// sheet, the row-layout DXF, the meshes, the dowels) hold the two
    /// pieces, and no outline cut pinches.
    @Test(arguments: [3.0, 5.0])
    func piecesMeetingAtACornerAreCutApart(_ thickness: Double) throws {
        let model = try Self.model("pathological/blocks_touching_at_corner.stl")
        let plan = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: thickness))
        func pinched(_ contours: StackedSliceContours) -> Int {
            contours.layers.flatMap(\.paths).filter { path in
                Self.pinches(path.points.first == path.points.last ? Array(path.points.dropLast()) : path.points)
            }.count
        }
        let sliced = StackedSliceContourer.generate(model: model, plan: plan)
        // As sliced, every section is drawn as a figure of eight.
        #expect(pinched(sliced) == plan.sliceCount)
        let contours = StackedSliceContourer.closingCracks(sliced)
        #expect(pinched(contours) == 0)
        #expect(contours.layers.allSatisfy { $0.paths.count == 2 && $0.paths.allSatisfy(\.closed) })
        let document = CutSheetLayoutBuilder.document(stacked: contours, settings: .defaultValue, dowels: nil, revision: 1)
        let parts = document.sheets.flatMap(\.parts)
        #expect(parts.count == 2 * plan.sliceCount)
        for part in parts {
            for loop in part.cutLoops {
                let points = loop.first == loop.last ? Array(loop.dropLast()) : loop
                #expect(!Self.pinches(points), "\(part.label)")
            }
        }
        // The square block's and the kite's areas, a piece each.
        let areas = parts.map { abs(CutSheetLayoutBuilder.signedArea($0.cutLoops[0])) }.sorted()
        #expect(areas.filter { abs($0 - 400) < 1.0e-6 }.count == plan.sliceCount)
        #expect(areas.filter { abs($0 - 300) < 1.0e-6 }.count == plan.sliceCount)
    }

    /// The lumpy blob cracked open at its poles: every outline Curve, Radial
    /// and Stacked cut from it, in 3 and 5 mm, is simple.
    @Test(arguments: [3.0, 5.0])
    func everyOutlineCutFromACrackedMeshIsSimple(_ thickness: Double) throws {
        let model = try Self.model("pathological/lumpy_blob_open_poles.stl")
        var documents: [(String, CutSheetDocument)] = []
        for axis in [SliceAxis.z, .y] {
            let curve = try #require(CurveSlicePlanner.plan(
                model: model, primaryAxis: axis, materialThickness: thickness, firstAxisCount: 7,
                curveSliceCount: 12, amplitude: 10, slotWidth: thickness, slotAngleDegrees: 0
            ))
            documents.append(("curve \(axis)", CutSheetLayoutBuilder.document(curve: curve, model: model, settings: .defaultValue, revision: 1)))
        }
        let radial = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: thickness))
        documents.append(("radial", CutSheetLayoutBuilder.document(radial: radial, model: model, settings: .defaultValue, revision: 1)))
        let stacked = try #require(StackedSlicePlanner.plan(model: model, axis: .z, materialThickness: thickness))
        // As the exports cut it: closed across the cracks.
        documents.append(("stacked", CutSheetLayoutBuilder.document(
            stacked: StackedSliceContourer.closingCracks(StackedSliceContourer.generate(model: model, plan: stacked)),
            settings: .defaultValue, dowels: nil, revision: 1
        )))
        for (name, document) in documents {
            let parts = document.sheets.flatMap(\.parts)
            #expect(!parts.isEmpty, "\(name)")
            for part in parts {
                for loop in part.cutLoops {
                    let points = loop.first == loop.last ? Array(loop.dropLast()) : loop
                    // Checked independently of `separatingPinches`, which
                    // made them.
                    #expect(!Self.pinches(points), "\(name) \(part.label)")
                    #expect(!Self.crossesItself(points), "\(name) \(part.label)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Per part label, the material area and the number of loops.
    private static func areas(_ document: CutSheetDocument) -> [String: (Double, Int)] {
        var out: [String: (Double, Int)] = [:]
        for part in document.sheets.flatMap(\.parts) {
            let areas = part.cutLoops.map { abs(CutSheetLayoutBuilder.signedArea($0)) }
            out[part.label] = ((areas.first ?? 0) - areas.dropFirst().reduce(0, +), part.cutLoops.count)
        }
        return out
    }

    /// Whether `loop` pinches: a corner lies on another stretch of the same
    /// loop, and the two lobes either side lie outside each other, so they
    /// are pieces held only at that point (a hole touching the edge, a lobe
    /// inside the other, is not a pinch). Written apart from
    /// `CutSheetLayoutBuilder.separatingPinches`, so a fault there cannot
    /// hide here.
    private static func pinches(_ loop: [Vec2]) -> Bool {
        let n = loop.count
        guard n >= 4 else { return false }
        func area(_ points: [Vec2]) -> Double {
            var sum = 0.0
            for i in points.indices {
                let (a, b) = (points[i], points[(i + 1) % points.count])
                sum += a.x * b.y - b.x * a.y
            }
            return sum / 2
        }
        func inside(_ point: Vec2, _ polygon: [Vec2]) -> Bool {
            var odd = false
            var j = polygon.count - 1
            for i in polygon.indices {
                let (a, b) = (polygon[i], polygon[j])
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    odd.toggle()
                }
                j = i
            }
            return odd
        }
        for corner in 0..<n {
            let p = loop[corner]
            for edge in 0..<n {
                let next = (edge + 1) % n
                guard edge != corner, next != corner else { continue }
                let (a, b) = (loop[edge], loop[next])
                let ab = Vec2(x: b.x - a.x, y: b.y - a.y)
                let length = ab.x * ab.x + ab.y * ab.y
                let s = length > 0 ? min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length)) : 0
                let dx = p.x - (a.x + ab.x * s), dy = p.y - (a.y + ab.y * s)
                guard dx * dx + dy * dy <= 1.0e-8 else { continue }
                var first: [Vec2] = []
                var k = corner
                while true {
                    first.append(loop[k])
                    if k == edge { break }
                    k = (k + 1) % n
                }
                var second: [Vec2] = [p]
                k = next
                while k != corner {
                    second.append(loop[k])
                    k = (k + 1) % n
                }
                guard first.count >= 3, second.count >= 3, abs(area(first)) > 1.0e-6, abs(area(second)) > 1.0e-6 else { continue }
                let probeFirst = Vec2(x: (first[1].x + first[2].x) / 2, y: (first[1].y + first[2].y) / 2)
                let probeSecond = Vec2(x: (second[1].x + second[2].x) / 2, y: (second[1].y + second[2].y) / 2)
                if !inside(probeFirst, second), !inside(probeSecond, first) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether two edges of `loop` that share no corner cross.
    private static func crossesItself(_ loop: [Vec2]) -> Bool {
        let n = loop.count
        guard n >= 4 else { return false }
        func orientation(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        for i in 0..<n {
            let (a, b) = (loop[i], loop[(i + 1) % n])
            for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                let (c, d) = (loop[j], loop[(j + 1) % n])
                let d1 = orientation(a, b, c), d2 = orientation(a, b, d)
                let d3 = orientation(c, d, a), d4 = orientation(c, d, b)
                if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
                    return true
                }
            }
        }
        return false
    }

    private static func model(_ fixture: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/\(fixture)"))
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
