import CManifold
import Foundation
import Testing
@testable import RefabArtist

/// Folded Panels nets folded back up with their stock. Each panel's frame
/// puts it where it sits on the model; the stock lies behind its net, inside
/// the model, `materialThickness` deep. Every panel is built as a solid (its
/// cut-back outline and the joint features that stand out of it, less the
/// net's holes) and no two solids may share any volume, except two panels a
/// fold joins, which are one piece bent there. That covers the seams (the
/// male copy cut back clear of the female panel's stock), the corners where
/// several panels meet, and the joints (a tab passes only through the slot
/// cut for it, a lug clears the panel it holds). The joint checks then make
/// sure what passes through a slot or notch comes out past the far face.
struct FoldedStockTests {
    static let cube = "tests/fixtures/cube_ascii.stl"
    static let pyramid = "tests/fixtures/square_pyramid_ascii.stl"
    static let box = "tests/fixtures/rectangular_prism_ascii.stl"
    static let chair = "tests/fixtures/real-world/simple_chair.stl"
    static let curved = [
        "tests/fixtures/primitives/cylinder_d40_h80mm.stl",
        "tests/fixtures/primitives/sphere_d50mm.stl",
        "tests/fixtures/primitives/torus_R30_r10mm.stl",
    ]
    static let thicknesses = [0.5, 3.0, 5.0]
    static let cuttingTypes: [JoineryType] = [.tab, .diamond, .multitab, .tongue, .rivet, .gear, .puzzle, .ticked, .laced]

    @Test(arguments: [cube, pyramid, box, chair], thicknesses)
    func noTwoPanelsStockPassesIntoEachOther(fixture: String, thickness: Double) throws {
        for type in Self.cuttingTypes + [.trivial] {
            let plan = try Self.plan(fixture, type, thickness)
            let check = try FoldedStockCheck(plan: plan)
            #expect(check.problems.isEmpty, "\(fixture) \(type) \(thickness) mm: \(check.problems.prefix(4))")
            #expect(check.collisions.isEmpty, "\(fixture) \(type) \(thickness) mm: \(check.collisions.prefix(4))")
            #expect(check.solids > 0)
        }
    }

    @Test(arguments: curved, thicknesses)
    func curvedModelsAtTheAppsDetailFoldUpClear(fixture: String, thickness: Double) throws {
        for type: JoineryType in [.trivial, .tab, .laced, .puzzle] {
            let plan = try Self.plan(fixture, type, thickness, faces: 250)
            let check = try FoldedStockCheck(plan: plan)
            #expect(check.problems.isEmpty, "\(fixture) \(type) \(thickness) mm: \(check.problems.prefix(4))")
            #expect(check.collisions.isEmpty, "\(fixture) \(type) \(thickness) mm: \(check.collisions.prefix(4))")
            #expect(check.solids > 0)
        }
    }

    @Test(arguments: [cube, pyramid, box], thicknesses)
    func jointsCloseWithTheStockCutBack(fixture: String, thickness: Double) throws {
        for type in Self.cuttingTypes {
            let plan = try Self.plan(fixture, type, thickness)
            let fit = FoldedStockJointFit(plan: plan)
            #expect(fit.problems.isEmpty, "\(fixture) \(type) \(thickness) mm: \(fit.problems.prefix(6))")
            if [.tab, .diamond, .multitab, .tongue, .rivet, .gear, .puzzle].contains(type), plan.jointCensus?.joined ?? 0 > 0 {
                #expect(fit.protrusions > 0, "\(fixture) \(type) \(thickness) mm")
            }
        }
    }

    @Test(arguments: thicknesses)
    func theCubeIsAButtJointedBoxWithEveryJointCut(thickness: Double) throws {
        // Every cube seam is square: the male copy is cut back by exactly the
        // stock, so its end rests on the female panel's inside face, and all
        // 7 cut edges keep their joint.
        for type in Self.cuttingTypes {
            let plan = try Self.plan(Self.cube, type, thickness)
            #expect(plan.jointCensus == FoldedJointCensus(cutEdges: 7, joined: 7), "\(type) \(thickness) mm")
            #expect(plan.nets.count == 1)
            #expect(plan.stockCensus == FoldedStockCensus(panels: 6), "\(type) \(thickness) mm")
        }
        let plain = try Self.plan(Self.cube, .trivial, thickness)
        let net = try #require(plain.nets.first)
        // 3 square panels keep 50 × 50; the 3 cut back on two or three edges
        // lose a stock-wide strip on each of those edges.
        let areas = net.panelOutlines.map { abs(Self.area($0)) }.sorted()
        let full = 50.0 * 50.0
        #expect(areas.filter { abs($0 - full) < 1.0e-3 }.count + areas.filter { $0 < full - 1.0e-3 }.count == 6)
        #expect(areas.allSatisfy { $0 <= full + 1.0e-3 })
        let removed = 6 * full - areas.reduce(0, +)
        // 7 seams, each cut back by the stock along 50 mm, less the overlaps
        // of strips meeting at a panel's corner.
        #expect(removed > 7 * 50 * thickness - 4 * thickness * thickness - 1.0e-3)
        #expect(removed < 7 * 50 * thickness + 1.0e-3)
    }

    @Test(arguments: thicknesses)
    func thinTeethKeepTheirStockApart(thickness: Double) throws {
        // The spur gear's teeth are thinner than the stock is deep, so stock
        // cut back from one flank reaches across the tooth into the panels
        // beyond it, sometimes into the middle of one: that panel gets a
        // hole there, and the folded gear stays clear.
        let plan = try Self.plan("tests/fixtures/real-world/spur_gear_T20_M2.stl", .trivial, thickness)
        let check = try FoldedStockCheck(plan: plan)
        #expect(check.problems.isEmpty, "\(thickness) mm: \(check.problems.prefix(4))")
        #expect(check.collisions.isEmpty, "\(thickness) mm: \(check.collisions.prefix(4))")
        #expect(check.solids > 0)
    }

    @Test(arguments: ["tests/fixtures/primitives/torus_R30_r10mm.stl", "tests/fixtures/organic/lumpy_blob.stl"])
    func fullDetailNetsCutAsSeparateCleanLoops(fixture: String) throws {
        // At full detail in 5 mm stock, curved nets are relieved wherever
        // their cuts meet, again after each relief: no cut touches or
        // crosses itself or another cut of its net, and none is shorter than
        // a thousandth of a millimetre (a reader takes its ends for one point).
        let plan = try Self.plan(fixture, .tab, 5)
        #expect(plan.nets.count > 1)
        for (index, net) in plan.nets.enumerated() {
            let loops: [[Vec2]] = [net.outline] + net.outlineHoles + net.slotHoles
            let shortest = loops.map(FoldedStockJointFit.shortestEdge).min() ?? .infinity
            #expect(shortest >= 1.0e-3, "\(fixture) net \(index): an edge \(shortest) mm long")
            let touch = FoldedStockJointFit.touchingCuts(loops)
            #expect(touch == nil, "\(fixture) net \(index): cuts meet at \(String(describing: touch))")
        }
    }

    @Test
    func panelsLeftAtTheModelSurfaceRunIntoEachOther() throws {
        // The check catches the old geometry: nets planned with no stock keep
        // every panel at the model surface; given 5 mm of stock, every seam
        // of the cube collides.
        var surface = try Self.plan(Self.cube, .trivial, 1.0e-6)
        surface.materialThickness = 5
        let check = try FoldedStockCheck(plan: surface)
        #expect(check.collisions.count == 7, "\(check.collisions)")
        // Cut back for 5 mm, the same cube is clear.
        #expect(try FoldedStockCheck(plan: Self.plan(Self.cube, .trivial, 5)).collisions.isEmpty)
    }

    @Test
    func theStockCensusSaysWhenPanelsAreLeftOut() throws {
        // A torus at the app's detail in 5 mm stock: its tube is 20 mm across
        // and its slivers sit where their neighbours' stock is.
        let torus = try Self.plan(Self.curved[2], .trivial, 5, faces: 250)
        #expect(torus.stockCensus.panels > 0)
        #expect(torus.stockCensus.leftOut > 0)
        let summary = try #require(torus.stockCensus.summary(thickness: 5))
        #expect(summary.contains("of \(torus.stockCensus.panels) panels are left out"))
        #expect(summary.hasSuffix("Thinner stock, or a lower Detail for bigger panels, keeps more of them."))
        // The cube loses nothing.
        #expect(try Self.plan(Self.cube, .trivial, 5).stockCensus.summary(thickness: 5) == nil)
        #expect(FoldedStockCensus(panels: 10, leftOut: 1).summary(thickness: 3)
                == "1 of 10 panels is left out: in 3 mm stock they sit where their neighbours' stock already is. Thinner stock, or a lower Detail for bigger panels, keeps more of them.")
        #expect(FoldedStockCensus(panels: 10, leftOut: 2, cutBackByHalf: 3).summary(thickness: 0.5)
                == "2 of 10 panels are left out and 3 panels are cut back to less than half their size: in 0.5 mm stock they sit where their neighbours' stock already is. Thinner stock, or a lower Detail for bigger panels, keeps more of them.")
    }

    /// The panels the stock leaves out are named on the plan and have no
    /// assembly step; the other steps keep their indices (panel index + 1)
    /// and the guide numbers them 1, 2, … in order.
    @Test
    func panelsTheStockLeavesOutHaveNoStep() throws {
        let torus = try Self.plan(Self.curved[2], .trivial, 5, faces: 250)
        #expect(torus.leftOutPanels.count == torus.stockCensus.leftOut)
        #expect(!torus.leftOutPanels.isEmpty)
        #expect(torus.leftOutPanels == torus.leftOutPanels.sorted())
        #expect(torus.leftOutPanels.allSatisfy { torus.panels.indices.contains($0) })

        let steps = AssemblyStepPlanner.steps(folded: torus)
        #expect(steps.count == torus.panels.count - torus.leftOutPanels.count)
        let leftOutIndices = Set(torus.leftOutPanels.map { $0 + 1 })
        #expect(steps.allSatisfy { !leftOutIndices.contains($0.index) })
        let kept = torus.panels.indices.filter { !torus.leftOutPanels.contains($0) }
        #expect(steps.map(\.index) == kept.map { $0 + 1 })
        #expect(steps.map(\.title) == kept.map { String(format: "Fold folded_panel_%03d", $0 + 1) })

        let guide = AssemblyGuideExporter.document(context: AssemblyGuideContext(
            modelName: "torus", constructionMode: .foldedPanels, materialThickness: 5, slotClearance: 0,
            slotAngleDegrees: 0, dowelsEnabled: false, dowelDiameter: 0, dowelInset: 0, foldedJoint: .trivial
        ), steps: steps)
        #expect(guide.contains("Step count: \(steps.count)\n"))
        #expect(guide.contains("\n\(steps.count). \(steps[steps.count - 1].title)\n"))
        #expect(!guide.contains("\n\(steps.count + 1). "))

        // A cube keeps every panel and every step.
        let cube = try Self.plan(Self.cube, .trivial, 5)
        #expect(cube.leftOutPanels.isEmpty)
        #expect(AssemblyStepPlanner.steps(folded: cube).count == cube.panels.count)
    }

    // MARK: - Fixtures

    static func plan(_ fixture: String, _ type: JoineryType, _ thickness: Double, faces: Int? = nil) throws -> FoldedPanelPlan {
        var model = try MeshInspector.inspect(url: repoURL(fixture))
        if let faces, model.faceCount > faces {
            model = try #require(FoldedMeshPrecleaner.preclean(model, targetFaceCount: faces))
        }
        return FoldedPanelPlanner.plan(model: model, joinery: .preset(for: type), materialThickness: thickness)
    }

    static func repoURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
    }

    static func area(_ polygon: [Vec2]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            sum += polygon[index].x * next.y - next.x * polygon[index].y
        }
        return sum / 2
    }
}

/// A folded plan's panels as solids of stock, and every pair of them that
/// shares volume (two panels a fold joins excepted).
struct FoldedStockCheck: CustomStringConvertible {
    struct Collision: CustomStringConvertible {
        var a: String
        var b: String
        var volume: Double
        var description: String { "\(a) x \(b): \(String(format: "%.4f", volume)) mm³" }
    }

    /// Shared volume below this is rounding, not stock passing into stock.
    static let volumeTolerance = 1.0e-3

    var solids = 0
    var collisions: [Collision] = []
    var problems: [String] = []

    var description: String { "\(solids) solids, \(collisions.count) collisions" }

    init(plan: FoldedPanelPlan, ignoreOutline: Bool = false) throws {
        let thickness = plan.materialThickness
        struct Piece {
            var name: String
            var net: Int
            var panel: Int
            var solid: ManifoldHandle
            var lo: Vec3
            var hi: Vec3
        }
        var pieces: [Piece] = []
        var hinged = Set<[Int]>()
        for (netIndex, net) in plan.nets.enumerated() {
            for hinge in net.hinges {
                hinged.insert([netIndex, min(hinge.a, hinge.b), max(hinge.a, hinge.b)])
            }
            let outline = ignoreOutline ? [] : (PlanarBoolean.subtracting(net.outlineHoles + net.slotHoles, from: [net.outline]) ?? [])
            for (index, region) in net.panelOutlines.enumerated() where region.count >= 3 {
                guard net.panelFrames.indices.contains(index), let frame = net.panelFrames[index],
                      net.panelInward.indices.contains(index) else {
                    problems.append("net \(netIndex) panel \(index) has no frame")
                    continue
                }
                let features = net.panelFeatures.indices.contains(index) ? net.panelFeatures[index] : []
                let own = PlanarBoolean.subtracting([], from: [region] + features) ?? [region]
                let material = ignoreOutline ? own : (PlanarBoolean.intersecting(own, outline) ?? [])
                guard material.contains(where: { $0.count >= 3 && abs(FoldedStockTests.area($0)) > 1.0e-6 }) else {
                    continue
                }
                let inward = net.panelInward[index]
                let solid = try Self.prism(material, thickness: thickness, frame: frame, inward: inward)
                // The solid holds as much stock as its outline encloses.
                let expected = material.reduce(0) { $0 + FoldedStockTests.area($1) } * thickness
                let volume = manifold_volume(solid.manifold)
                if abs(volume - expected) > 1.0e-6 * max(1, expected) + 1.0e-6 {
                    problems.append("net \(netIndex) panel \(index): solid holds \(volume) mm³, outline \(expected) mm³")
                }
                var points: [Vec3] = []
                for loop in material {
                    for point in loop {
                        let surface = frame.modelPoint(point)
                        points.append(surface)
                        points.append(Vec3(x: surface.x + inward.x * thickness, y: surface.y + inward.y * thickness, z: surface.z + inward.z * thickness))
                    }
                }
                let lo = Vec3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0)
                let hi = Vec3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
                pieces.append(Piece(name: "net \(netIndex) panel \(index)", net: netIndex, panel: index, solid: solid, lo: lo, hi: hi))
            }
        }
        solids = pieces.count
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                let a = pieces[i], b = pieces[j]
                if a.net == b.net, hinged.contains([a.net, min(a.panel, b.panel), max(a.panel, b.panel)]) {
                    continue
                }
                guard a.lo.x < b.hi.x, b.lo.x < a.hi.x, a.lo.y < b.hi.y, b.lo.y < a.hi.y, a.lo.z < b.hi.z, b.lo.z < a.hi.z else {
                    continue
                }
                let memory = UnsafeMutableRawPointer.allocate(byteCount: manifold_manifold_size(), alignment: 16)
                guard let shared = manifold_intersection(memory, a.solid.manifold, b.solid.manifold) else {
                    memory.deallocate()
                    problems.append("\(a.name) x \(b.name): no intersection")
                    continue
                }
                let handle = ManifoldHandle(adopting: memory, manifold: shared)
                let volume = manifold_volume(handle.manifold)
                if volume > Self.volumeTolerance {
                    collisions.append(Collision(a: a.name, b: b.name, volume: volume))
                }
            }
        }
    }

    /// A panel's stock: its net loops (outer counter-clockwise, holes
    /// clockwise) extruded `thickness` and put where the frame puts the
    /// panel, the stock along `inward`.
    static func prism(_ loops: [[Vec2]], thickness: Double, frame: PartPlaneFrame, inward: Vec3) throws -> ManifoldHandle {
        var simple: [OpaquePointer?] = []
        var memories: [UnsafeMutableRawPointer] = []
        defer {
            for (index, polygon) in simple.enumerated() {
                if let polygon { manifold_destruct_simple_polygon(polygon) }
                memories[index].deallocate()
            }
        }
        for loop in loops where loop.count >= 3 {
            var points = loop.map { ManifoldVec2(x: $0.x, y: $0.y) }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: manifold_simple_polygon_size(), alignment: 16)
            let polygon = points.withUnsafeMutableBufferPointer { manifold_simple_polygon(memory, $0.baseAddress, $0.count) }
            simple.append(polygon)
            memories.append(memory)
        }
        let polygonsMemory = UnsafeMutableRawPointer.allocate(byteCount: manifold_polygons_size(), alignment: 16)
        defer { polygonsMemory.deallocate() }
        guard let polygons = simple.withUnsafeMutableBufferPointer({ manifold_polygons(polygonsMemory, $0.baseAddress, $0.count) }) else {
            throw ManifoldEngineError.invalidConstruction
        }
        defer { manifold_destruct_polygons(polygons) }
        let extrudedMemory = UnsafeMutableRawPointer.allocate(byteCount: manifold_manifold_size(), alignment: 16)
        guard let extruded = manifold_extrude(extrudedMemory, polygons, thickness, 0, 0, 1, 1) else {
            extrudedMemory.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        let flat = ManifoldHandle(adopting: extrudedMemory, manifold: extruded)
        let placedMemory = UnsafeMutableRawPointer.allocate(byteCount: manifold_manifold_size(), alignment: 16)
        guard let placed = manifold_transform(
            placedMemory, flat.manifold,
            frame.xAxis.x, frame.xAxis.y, frame.xAxis.z,
            frame.yAxis.x, frame.yAxis.y, frame.yAxis.z,
            inward.x, inward.y, inward.z,
            frame.origin.x, frame.origin.y, frame.origin.z
        ) else {
            placedMemory.deallocate()
            throw ManifoldEngineError.invalidConstruction
        }
        return ManifoldHandle(adopting: placedMemory, manifold: placed)
    }
}

/// The joints of a folded plan with its stock: every slot or hole is a
/// closed cut with tickRadius of material round it, every protrusion (tab,
/// tick, tongue, finger, Puzzle neck) runs into exactly one other panel and
/// comes out past that panel's outside face, every pin hole lies wholly past
/// the face its pin bears on, and no outline crosses itself.
struct FoldedStockJointFit {
    var protrusions = 0
    var problems: [String] = []

    init(plan: FoldedPanelPlan) {
        let thickness = plan.materialThickness
        let tick = plan.joinery.sanitized.tickRadius
        struct Panel {
            var net: Int
            var index: Int
            var region: [Vec2]
            var features: [[Vec2]]
            var frame: PartPlaneFrame
            var inward: Vec3
        }
        var panels: [Panel] = []
        for (netIndex, net) in plan.nets.enumerated() {
            if Self.crossesItself(net.outline) {
                problems.append("net \(netIndex) outline crosses itself")
            }
            for hole in net.slotHoles {
                let inside = hole.allSatisfy { Self.contains(net.outline, $0) }
                let clearance = hole.map { Self.distanceToBoundary($0, net.outline) }.min() ?? 0
                if !inside || clearance < tick - 1.0e-6 {
                    problems.append("net \(netIndex) hole at \(Self.average(hole)): inside \(inside), \(clearance) mm from the outline")
                }
            }
            for (index, region) in net.panelOutlines.enumerated() where region.count >= 3 {
                guard let frame = net.panelFrames[index] else { continue }
                panels.append(Panel(net: netIndex, index: index, region: region, features: net.panelFeatures[index], frame: frame, inward: net.panelInward[index]))
            }
        }
        // Every protrusion: a feature holding no slot.
        for panel in panels {
            let holes = plan.nets[panel.net].slotHoles
            for feature in panel.features where !holes.contains(where: { Self.isLug(feature, $0) }) {
                protrusions += 1
                let samples = Self.samples(feature).map(panel.frame.modelPoint)
                // The panel it runs into: the one whose stock it enters most.
                var best: (panel: Int, hits: Int, beyond: Double)?
                for (otherIndex, other) in panels.enumerated() where !(other.net == panel.net && other.index == panel.index) {
                    var hits = 0
                    var beyond = -Double.infinity
                    for depth in [0.02, 0.5, 0.98] {
                        for point in samples {
                            let deep = Vec3(x: point.x + panel.inward.x * thickness * depth, y: point.y + panel.inward.y * thickness * depth, z: point.z + panel.inward.z * thickness * depth)
                            let height = Self.dot(Self.subtract(deep, other.frame.origin), other.inward)
                            let local = Self.netPoint(deep, other.frame)
                            let over = Self.contains(other.region, local) || other.features.contains { Self.contains($0, local) }
                            guard over else { continue }
                            if height > 0, height < thickness {
                                hits += 1
                            }
                            beyond = max(beyond, -height)
                        }
                    }
                    if hits > (best?.hits ?? 0) {
                        best = (otherIndex, hits, beyond)
                    }
                }
                guard let best else {
                    problems.append("net \(panel.net) panel \(panel.index): a protrusion at \(Self.average(feature)) runs into no panel")
                    continue
                }
                if best.beyond < 0.25 * tick {
                    problems.append("net \(panel.net) panel \(panel.index): a protrusion at \(Self.average(feature)) reaches only \(best.beyond) mm past the far face")
                }
                // Pin holes in it lie wholly past the face their pin bears on.
                let other = panels[best.panel]
                for hole in holes where hole.allSatisfy({ Self.contains(feature, $0) }) {
                    for point in hole {
                        let height = Self.dot(Self.subtract(panel.frame.modelPoint(point), other.frame.origin), other.inward)
                        if height > 1.0e-6 {
                            problems.append("net \(panel.net) panel \(panel.index): a pin hole reaches \(height) mm into the panel it locks")
                            break
                        }
                    }
                }
            }
        }
    }

    /// Whether `feature` is a lug: the slot `hole` runs into it or ends on
    /// its edge (a pin hole lies wholly inside its tab instead).
    static func isLug(_ feature: [Vec2], _ hole: [Vec2]) -> Bool {
        let touches = hole.contains { contains(feature, $0) || distanceToBoundary($0, feature) < 1.0e-6 }
        return touches && !hole.allSatisfy { contains(feature, $0) && distanceToBoundary($0, feature) > 1.0e-6 }
    }

    static func samples(_ polygon: [Vec2]) -> [Vec2] {
        let middle = average(polygon)
        var points = polygon.map { Vec2(x: $0.x + (middle.x - $0.x) * 1.0e-4, y: $0.y + (middle.y - $0.y) * 1.0e-4) }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return points }
        let steps = 12
        for i in 0...steps {
            for j in 0...steps {
                let point = Vec2(x: minX + (maxX - minX) * Double(i) / Double(steps), y: minY + (maxY - minY) * Double(j) / Double(steps))
                if contains(polygon, point) { points.append(point) }
            }
        }
        return points
    }

    static func netPoint(_ point: Vec3, _ frame: PartPlaneFrame) -> Vec2 {
        let relative = subtract(point, frame.origin)
        return Vec2(x: dot(relative, frame.xAxis) / dot(frame.xAxis, frame.xAxis), y: dot(relative, frame.yAxis) / dot(frame.yAxis, frame.yAxis))
    }

    static func contains(_ polygon: [Vec2], _ point: Vec2) -> Bool {
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

    static func distanceToBoundary(_ point: Vec2, _ polygon: [Vec2]) -> Double {
        polygon.indices.map { index -> Double in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
        }.min() ?? .infinity
    }

    static func crossesItself(_ loop: [Vec2]) -> Bool {
        func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let n = loop.count
        guard n >= 4 else { return false }
        for i in 0..<(n - 2) {
            let a = loop[i], b = loop[(i + 1) % n]
            for j in (i + 2)..<n where !(i == 0 && j == n - 1) {
                let c = loop[j], d = loop[(j + 1) % n]
                if orient(a, b, c) * orient(a, b, d) < 0, orient(c, d, a) * orient(c, d, b) < 0 {
                    return true
                }
            }
        }
        return false
    }

    static func shortestEdge(_ loop: [Vec2]) -> Double {
        var shortest = Double.infinity
        for index in loop.indices {
            let a = loop[index], b = loop[(index + 1) % loop.count]
            shortest = min(shortest, hypot(b.x - a.x, b.y - a.y))
        }
        return shortest
    }

    /// A point where two cuts of `loops` cross, or where a corner of one
    /// lies on (within a micrometre of) another cut that does not end there.
    static func touchingCuts(_ loops: [[Vec2]]) -> Vec2? {
        func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let edges = loops.enumerated().flatMap { loopIndex, loop in
            loop.indices.map { (loop: loopIndex, index: $0, a: loop[$0], b: loop[($0 + 1) % loop.count]) }
        }
        for (i, e) in edges.enumerated() {
            for f in edges[(i + 1)...] {
                let count = loops[e.loop].count
                let adjacent = e.loop == f.loop && (abs(e.index - f.index) == 1 || abs(e.index - f.index) == count - 1)
                if adjacent {
                    continue
                }
                if orient(e.a, e.b, f.a) * orient(e.a, e.b, f.b) < 0, orient(f.a, f.b, e.a) * orient(f.a, f.b, e.b) < 0 {
                    return e.a
                }
                for point in [f.a, f.b] where distanceToBoundary(point, [e.a, e.b]) < 1.0e-6 {
                    return point
                }
                for point in [e.a, e.b] where distanceToBoundary(point, [f.a, f.b]) < 1.0e-6 {
                    return point
                }
            }
        }
        return nil
    }

    static func average(_ points: [Vec2]) -> Vec2 {
        let n = Double(max(points.count, 1))
        return Vec2(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
