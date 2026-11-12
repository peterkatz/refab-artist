import XCTest
@testable import RefabArtist

final class PartitionTests: XCTestCase {

    // MARK: - Mode / format wiring

    func testPartitionModeIsMeshOnly() {
        XCTAssertEqual(ExportFormatSupport.availableFormats(for: .partition), [.stl, .obj])
        XCTAssertTrue(ConstructionMode.partition.isMeshOnly)
        XCTAssertEqual(ConstructionMode.partition.label, "Partition")
    }

    // MARK: - Settings codability + project round-trip

    func testSettingsCodableRoundTrip() throws {
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.buildVolume = PrinterVolume(width: 220, depth: 210, height: 250)
        settings.bedMargin = 3
        settings.key.type = .pins
        settings.key.tolerance = 0.25
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 12.5, isManual: true)]
        settings.packaging = .separateZip
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PartitionSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // Project-level persistence round-trip lives in SlicerProjectDocumentTests,
    // where the fully-populated `SlicerProjectSettings.sample` fixture is in scope.

    // MARK: - Auto-fit division math

    func testAutoFitDivisionCount() {
        let bounds = Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 600, y: 100, z: 100))
        var settings = PartitionSettings.defaultValue
        settings.key.type = .none
        settings.bedMargin = 0
        settings.buildVolume = PrinterVolume(width: 200, depth: 200, height: 200)
        let planes = PartitionPlanner.autoFitPlanes(bounds: bounds, settings: settings)
        // 600 / 200 = 3 cells on X → 2 cuts; Y and Z fit in one → no cuts.
        let xCuts = planes.filter { $0.axisAligned == 0 }.count
        let yCuts = planes.filter { $0.axisAligned == 1 }.count
        let zCuts = planes.filter { $0.axisAligned == 2 }.count
        XCTAssertEqual(xCuts, 2)
        XCTAssertEqual(yCuts, 0)
        XCTAssertEqual(zCuts, 0)
    }

    // MARK: - Splitting: watertight + volume conservation

    func testAxisAlignedSplitProducesWatertightHalves() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 5, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "piece \(piece.name) should be watertight")
        }
        let total = plan.pieces.reduce(0.0) { $0 + abs(signedVolume(of: $1.mesh)) }
        XCTAssertEqual(total, 1000, accuracy: 1.0, "two halves should conserve the cube volume")
    }

    func testArbitraryPlaneSplitIsWatertight() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        // A general tilted plane through the centre (5,5,5) that does NOT graze
        // any cube vertex/edge: dot((5,5,5), (1,0.4,0.2)) = 8.
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 1, y: 0.4, z: 0.2), offset: 8, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "tilted-cut piece \(piece.name) should be watertight")
        }
        let total = plan.pieces.reduce(0.0) { $0 + abs(signedVolume(of: $1.mesh)) }
        XCTAssertEqual(total, 1000, accuracy: 1.0)
    }

    func testConcaveSectionCapIsWatertight() {
        // L-shaped prism: cutting it leaves a CONCAVE cross-section — the
        // project's historical blind spot. The ear-clip cap must handle it.
        let model = lPrismModel()
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 5, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "concave piece \(piece.name) should be watertight")
        }
    }

    // MARK: - Keys

    func testPinnedSplitPiecesAreWatertight() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 40, y: 40, z: 40))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key = PartitionKeySettings(type: .pins, pinDiameter: 6, pinLength: 6, tolerance: 0.2, pinsPerSeam: 2, edgeMargin: 3)
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 20, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        XCTAssertEqual(plan.seams.count, 1)
        XCTAssertTrue(plan.seams[0].keyed, "the seam should host pins")
        XCTAssertGreaterThan(plan.seams[0].pinCount, 0)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "keyed piece \(piece.name) should stay watertight")
        }
    }

    func testWedgeKeyPiecesAreWatertight() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 40, y: 40, z: 40))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key = PartitionKeySettings(type: .dovetail, pinDiameter: 8, pinLength: 6, tolerance: 0.2, pinsPerSeam: 1, edgeMargin: 3)
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 20, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        XCTAssertTrue(plan.seams.first?.keyed ?? false, "the wedge seam should host a key")
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "wedge-keyed piece \(piece.name) should stay watertight")
        }
    }

    func testVertexGrazingPlaneIsHandled() {
        // x + y = 10 passes exactly through two cube corner edges. The planner's
        // vertex nudge must keep both pieces watertight.
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 1, y: 1, z: 0), offset: 10, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "vertex-grazing piece \(piece.name) should be watertight after nudge")
        }
    }

    func testGridLabels() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 30, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.naming = .gridLabels
        settings.manualPlanes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 10, isManual: true),
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 20, isManual: true)
        ]
        let plan = PartitionPlanner.plan(model: model, settings: settings)!
        let names = Set(plan.pieces.map(\.name))
        XCTAssertEqual(names, ["A1", "B1", "C1"])
    }

    // MARK: - Fit check

    func testFitCheckFlagsOversizedPiece() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 400, y: 100, z: 100))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.buildVolume = PrinterVolume(width: 200, depth: 200, height: 200)
        settings.bedMargin = 0
        // No cuts: the whole 400mm-long model exceeds the 200mm bed.
        settings.manualPlanes = []
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertEqual(plan?.oversizedCount, 1)
    }

    func testAutoFitResultFitsBed() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 400, y: 100, z: 100))
        var settings = PartitionSettings.defaultValue
        settings.mode = .autoFit
        settings.key.type = .none
        settings.buildVolume = PrinterVolume(width: 200, depth: 200, height: 200)
        settings.bedMargin = 0
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.oversizedCount, 0, "auto-fit should size every piece to the bed")
        XCTAssertGreaterThanOrEqual(plan?.pieces.count ?? 0, 2)
    }

    // MARK: - Packaging

    func testZipPackagingHasOneEntryPerPiece() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 30, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.includeAssemblyMap = true
        settings.manualPlanes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 10, isManual: true),
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 20, isManual: true)
        ]
        let plan = PartitionPlanner.plan(model: model, settings: settings)!
        XCTAssertEqual(plan.pieces.count, 3)
        let entries = PartitionExporter.zipEntries(plan: plan, format: .stl)
        // One STL per piece + the assembly map.
        XCTAssertEqual(entries.filter { $0.name.hasSuffix(".stl") }.count, 3)
        XCTAssertTrue(entries.contains { $0.name == "assembly-map.txt" })
    }

    func testDeterministicPlanning() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 40, y: 40, z: 40))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key = PartitionKeySettings(type: .pins, pinDiameter: 6, pinLength: 6, tolerance: 0.2, pinsPerSeam: 2, edgeMargin: 3)
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 20, isManual: true)]
        let a = PartitionPlanner.plan(model: model, settings: settings)!
        let b = PartitionPlanner.plan(model: model, settings: settings)!
        XCTAssertEqual(a.pieces.count, b.pieces.count)
        for (pa, pb) in zip(a.pieces, b.pieces) {
            XCTAssertEqual(pa.mesh.vertices, pb.mesh.vertices, "identical settings must produce identical geometry")
        }
    }

    // MARK: - Hollow sections (the void-preservation blind spot)

    func testTubeSectionPreservesVoidAndStaysWatertight() {
        // A square tube: cutting it across Z leaves an ANNULAR cross-section. The
        // cap must keep the bore open, not seal it with solid plastic.
        let model = squareTubeModel(outerHalf: 10, innerHalf: 4, z0: 0, z1: 10)
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 5, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(plan.pieces.count, 2)
        for piece in plan.pieces {
            XCTAssertTrue(isWatertight(piece.mesh), "tube half \(piece.name) should be watertight")
            // Void preserved ⇔ no cut-cap triangle (at z≈5) covers the bore axis
            // (0,0). A solid-capped bore would put a triangle over the centre.
            XCTAssertFalse(capCoversBoreAxis(piece.mesh, planeZ: 5), "the bore void must stay open at the cut, not capped solid")
        }
    }

    /// True if any triangle lying on the cut plane (all verts at z≈planeZ) covers
    /// the XY origin — i.e. the bore was sealed.
    private func capCoversBoreAxis(_ mesh: ViewportFlatShadedMesh, planeZ: Double) -> Bool {
        let v = mesh.vertices
        let idx = mesh.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            let a = v[Int(idx[t])], b = v[Int(idx[t + 1])], c = v[Int(idx[t + 2])]
            t += 3
            guard abs(a.z - planeZ) < 1.0e-6, abs(b.z - planeZ) < 1.0e-6, abs(c.z - planeZ) < 1.0e-6 else { continue }
            if pointInTriangleXY(Vec2(x: 0, y: 0), a, b, c) { return true }
        }
        return false
    }

    private func pointInTriangleXY(_ p: Vec2, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Bool {
        func cross(_ ox: Double, _ oy: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
        }
        let d1 = cross(p.x, p.y, a.x, a.y, b.x, b.y)
        let d2 = cross(p.x, p.y, b.x, b.y, c.x, c.y)
        let d3 = cross(p.x, p.y, c.x, c.y, a.x, a.y)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    // MARK: - Output

    func testPlateLayoutDropsPiecesToFloorWithoutOverlap() {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 30, y: 10, z: 10))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key.type = .none
        settings.manualPlanes = [
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 10, isManual: true),
            PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 20, isManual: true)
        ]
        let plan = PartitionPlanner.plan(model: model, settings: settings)!
        let layers = PartitionExporter.laidOutLayers(plan)
        XCTAssertEqual(layers.count, plan.pieces.count)
        var boxes: [Bounds3D] = []
        for layer in layers {
            let b = PartitionGeometry.bounds(layer.mesh.vertices.map { ($0, $0, $0) })!
            XCTAssertEqual(b.min.z, 0, accuracy: 1.0e-6, "each laid-out piece should sit on z=0")
            for other in boxes {
                let overlap = b.min.x < other.max.x - 1.0e-6 && b.max.x > other.min.x + 1.0e-6
                    && b.min.y < other.max.y - 1.0e-6 && b.max.y > other.min.y + 1.0e-6
                XCTAssertFalse(overlap, "laid-out pieces must not overlap in plan")
            }
            boxes.append(b)
        }
    }

    func testAssemblyMapAndZipExport() throws {
        let model = boxModel(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 40, y: 40, z: 40))
        var settings = PartitionSettings.defaultValue
        settings.mode = .manual
        settings.key = PartitionKeySettings(type: .pins, pinDiameter: 6, pinLength: 6, tolerance: 0.2, pinsPerSeam: 2, edgeMargin: 3)
        settings.includeAssemblyMap = true
        settings.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 20, isManual: true)]
        let plan = PartitionPlanner.plan(model: model, settings: settings)!

        let map = PartitionExporter.assemblyMapText(plan)
        XCTAssertTrue(map.contains("Pieces: 2"))
        XCTAssertTrue(map.contains("Seams:"))
        XCTAssertTrue(plan.pieces.allSatisfy { map.contains($0.name) })

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partition-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try PartitionExporter.write(plan: plan, format: .stl, packaging: .separateZip, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), Array("PK".utf8), "zip output should carry the PK magic")
    }

    // MARK: - Fit check

    // MARK: - In-viewport plane gizmo math

    func testHandleLiesOnPlane() {
        let bounds = Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let plane = PartitionPlane(normal: Vec3(x: 1, y: 0.4, z: 0.2), offset: 8, isManual: true)
        let h = PartitionPlaneEditing.handle(for: plane, bounds: bounds)
        let onPlane = h.x * plane.normalX + h.y * plane.normalY + h.z * plane.normalZ
        XCTAssertEqual(onPlane, plane.offset, accuracy: 1.0e-9, "the handle must sit on its plane")
    }

    func testOffsetRangeMatchesBoundsExtent() {
        let bounds = Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let range = PartitionPlaneEditing.offsetRange(normal: Vec3(x: 0, y: 0, z: 1), bounds: bounds)
        XCTAssertEqual(range.min, 0, accuracy: 1.0e-9)
        XCTAssertEqual(range.max, 10, accuracy: 1.0e-9)
    }

    func testDraggedOffsetSlidesAlongNormal() {
        let normal = Vec3(x: 0, y: 0, z: 1)
        let handle = Vec3(x: 5, y: 5, z: 5)
        // A horizontal ray at z=8: the closest point on the z-line through the
        // handle is at z=8 ⇒ offset 8.
        let ray = ViewportPickRay(origin: Vec3(x: 0, y: 5, z: 8), direction: Vec3(x: 1, y: 0, z: 0))
        let offset = PartitionPlaneEditing.draggedOffset(ray: ray, normal: normal, handle: handle, currentOffset: 5, range: (0, 10))
        XCTAssertEqual(offset, 8, accuracy: 1.0e-6)
    }

    func testDraggedOffsetClampsToRange() {
        let ray = ViewportPickRay(origin: Vec3(x: 0, y: 5, z: 99), direction: Vec3(x: 1, y: 0, z: 0))
        let offset = PartitionPlaneEditing.draggedOffset(ray: ray, normal: Vec3(x: 0, y: 0, z: 1), handle: Vec3(x: 5, y: 5, z: 5), currentOffset: 5, range: (0, 10))
        XCTAssertEqual(offset, 10, accuracy: 1.0e-6)
    }

    func testDraggedOffsetParallelRayKeepsOffset() {
        // Ray straight down the normal has no leverage ⇒ offset unchanged.
        let ray = ViewportPickRay(origin: Vec3(x: 5, y: 5, z: 99), direction: Vec3(x: 0, y: 0, z: -1))
        let offset = PartitionPlaneEditing.draggedOffset(ray: ray, normal: Vec3(x: 0, y: 0, z: 1), handle: Vec3(x: 5, y: 5, z: 5), currentOffset: 5, range: (0, 10))
        XCTAssertEqual(offset, 5, accuracy: 1.0e-9)
    }

    func testPickPlaneIndexHitsAndMisses() {
        let bounds = Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 10, y: 10, z: 10))
        let planes = [PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 5, isManual: true)]
        let pose = ViewportCameraPose(position: Vec3(x: 50, y: 5, z: 5), target: Vec3(x: 5, y: 5, z: 5), radius: 45)
        let size = CGSize(width: 400, height: 400)
        // Handle projects to screen centre.
        XCTAssertEqual(PartitionPlaneEditing.pickPlaneIndex(viewPoint: CGPoint(x: 200, y: 200), viewSize: size, pose: pose, planes: planes, bounds: bounds), 0)
        XCTAssertNil(PartitionPlaneEditing.pickPlaneIndex(viewPoint: CGPoint(x: 390, y: 390), viewSize: size, pose: pose, planes: planes, bounds: bounds))
    }

    func testTiltRotatesNormalKeepsPivotAndID() {
        let plane = PartitionPlane(normal: Vec3(x: 1, y: 0, z: 0), offset: 5, isManual: true)
        let pivot = Vec3(x: 5, y: 5, z: 5)
        let tilted = PartitionPlaneEditing.tilted(plane, degrees: 30, pivot: pivot)
        let len = (tilted.normalX * tilted.normalX + tilted.normalY * tilted.normalY + tilted.normalZ * tilted.normalZ).squareRoot()
        XCTAssertEqual(len, 1, accuracy: 1.0e-9, "normal stays unit")
        XCTAssertEqual(tilted.normalX, cos(30 * .pi / 180), accuracy: 1.0e-6, "tilted by the requested angle")
        let onPlane = pivot.x * tilted.normalX + pivot.y * tilted.normalY + pivot.z * tilted.normalZ
        XCTAssertEqual(onPlane, tilted.offset, accuracy: 1.0e-9, "plane still passes through the pivot")
        XCTAssertEqual(tilted.id, plane.id, "identity preserved across a tilt")
        XCTAssertNil(tilted.axisAligned, "a tilted plane is no longer axis-aligned")
    }

    // MARK: - Fixtures & measurement helpers

    private func boxModel(min lo: Vec3, max hi: Vec3) -> MeshSummary {
        let v: [Vec3] = [
            Vec3(x: lo.x, y: lo.y, z: lo.z), Vec3(x: hi.x, y: lo.y, z: lo.z),
            Vec3(x: hi.x, y: hi.y, z: lo.z), Vec3(x: lo.x, y: hi.y, z: lo.z),
            Vec3(x: lo.x, y: lo.y, z: hi.z), Vec3(x: hi.x, y: lo.y, z: hi.z),
            Vec3(x: hi.x, y: hi.y, z: hi.z), Vec3(x: lo.x, y: hi.y, z: hi.z)
        ]
        let faces = [
            (0, 2, 1), (0, 3, 2), // bottom
            (4, 5, 6), (4, 6, 7), // top
            (0, 1, 5), (0, 5, 4), // -y
            (2, 3, 7), (2, 7, 6), // +y
            (0, 4, 7), (0, 7, 3), // -x
            (1, 2, 6), (1, 6, 5)  // +x
        ]
        var indices: [Int32] = []
        for f in faces { indices += [Int32(f.0), Int32(f.1), Int32(f.2)] }
        return summary(MeshGeometryData(vertices: v, triangleIndices: indices), name: "box")
    }

    /// Watertight L-shaped prism extruded along Z, 0…10.
    private func lPrismModel() -> MeshSummary {
        let poly: [Vec2] = [
            Vec2(x: 0, y: 0), Vec2(x: 20, y: 0), Vec2(x: 20, y: 8),
            Vec2(x: 8, y: 8), Vec2(x: 8, y: 20), Vec2(x: 0, y: 20)
        ]
        let z0 = 0.0, z1 = 10.0
        var tris: [(Vec3, Vec3, Vec3)] = []
        let caps = ViewportSliceSolidRenderData.triangulate(poly)
        for (i, j, k) in caps {
            // bottom (-z)
            tris.append((Vec3(x: poly[i].x, y: poly[i].y, z: z0), Vec3(x: poly[k].x, y: poly[k].y, z: z0), Vec3(x: poly[j].x, y: poly[j].y, z: z0)))
            // top (+z)
            tris.append((Vec3(x: poly[i].x, y: poly[i].y, z: z1), Vec3(x: poly[j].x, y: poly[j].y, z: z1), Vec3(x: poly[k].x, y: poly[k].y, z: z1)))
        }
        for e in poly.indices {
            let a = poly[e], b = poly[(e + 1) % poly.count]
            let a0 = Vec3(x: a.x, y: a.y, z: z0), b0 = Vec3(x: b.x, y: b.y, z: z0)
            let a1 = Vec3(x: a.x, y: a.y, z: z1), b1 = Vec3(x: b.x, y: b.y, z: z1)
            tris.append((a0, b0, b1))
            tris.append((a0, b1, a1))
        }
        let geo = PartitionGeometry.geometry(tris)
        return summary(geo, name: "lprism")
    }

    /// Watertight square tube (annular prism) extruded along Z.
    private func squareTubeModel(outerHalf oh: Double, innerHalf ih: Double, z0: Double, z1: Double) -> MeshSummary {
        let o = [Vec2(x: -oh, y: -oh), Vec2(x: oh, y: -oh), Vec2(x: oh, y: oh), Vec2(x: -oh, y: oh)]
        let i = [Vec2(x: -ih, y: -ih), Vec2(x: ih, y: -ih), Vec2(x: ih, y: ih), Vec2(x: -ih, y: ih)]
        func v(_ p: Vec2, _ z: Double) -> Vec3 { Vec3(x: p.x, y: p.y, z: z) }
        var tris: [(Vec3, Vec3, Vec3)] = []
        for k in 0..<4 {
            let a = o[k], b = o[(k + 1) % 4]
            tris.append((v(a, z0), v(b, z0), v(b, z1)))
            tris.append((v(a, z0), v(b, z1), v(a, z1)))
            let c = i[k], d = i[(k + 1) % 4]
            tris.append((v(c, z0), v(c, z1), v(d, z1)))
            tris.append((v(c, z0), v(d, z1), v(d, z0)))
            // top annulus (z1)
            tris.append((v(o[k], z1), v(i[k], z1), v(i[(k + 1) % 4], z1)))
            tris.append((v(o[k], z1), v(i[(k + 1) % 4], z1), v(o[(k + 1) % 4], z1)))
            // bottom annulus (z0)
            tris.append((v(o[k], z0), v(i[(k + 1) % 4], z0), v(i[k], z0)))
            tris.append((v(o[k], z0), v(o[(k + 1) % 4], z0), v(i[(k + 1) % 4], z0)))
        }
        return summary(PartitionGeometry.geometry(tris), name: "tube")
    }

    private func summary(_ geometry: MeshGeometryData, name: String) -> MeshSummary {
        var lo = geometry.vertices[0], hi = geometry.vertices[0]
        for v in geometry.vertices {
            lo = Vec3(x: min(lo.x, v.x), y: min(lo.y, v.y), z: min(lo.z, v.z))
            hi = Vec3(x: max(hi.x, v.x), y: max(hi.y, v.y), z: max(hi.z, v.z))
        }
        return MeshSummary(
            name: name,
            path: "/tmp/\(name).stl",
            format: "test",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: Bounds3D(min: lo, max: hi),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    private func isWatertight(_ mesh: ViewportFlatShadedMesh) -> Bool {
        MeshPreflight.analyze(
            geometry: MeshGeometryData(vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
        ).isWatertight
    }

    private func signedVolume(of mesh: ViewportFlatShadedMesh) -> Double {
        var volume = 0.0
        var t = 0
        let idx = mesh.triangleIndices
        let v = mesh.vertices
        while t + 2 < idx.count {
            let a = v[Int(idx[t])], b = v[Int(idx[t + 1])], c = v[Int(idx[t + 2])]
            volume += (a.x * (b.y * c.z - b.z * c.y)
                       - a.y * (b.x * c.z - b.z * c.x)
                       + a.z * (b.x * c.y - b.y * c.x)) / 6.0
            t += 3
        }
        return volume
    }
}
