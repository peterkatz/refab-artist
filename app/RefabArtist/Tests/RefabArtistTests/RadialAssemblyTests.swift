import Foundation
import Testing
@testable import RefabArtist

/// How Radial Slices plans its rings and pieces so that what it cuts can be
/// assembled: rings never closer than their stock, sections taken as the
/// solid the model shows (shells that touch or overlap are one piece), every
/// notch filled by the fin it was cut for, pieces that cannot be locked in
/// marked, relief at the notch corners, and the export's counts.
struct RadialAssemblyTests {
    // MARK: - Ring spacing

    @Test
    func ringsNeverStandCloserThanTheirStock() throws {
        let torus = try Self.model("primitives/torus_R30_r10mm.stl")
        for thickness in [3.0, 5.0] {
            let plan = try #require(RadialSlicePlanner.plan(model: torus, nRadial: 12, materialThickness: thickness))
            let positions = try #require(plan.primary?.positions)
            for index in positions.indices.dropFirst() {
                #expect(positions[index] - positions[index - 1] >= thickness - 1.0e-9)
            }
            // The torus is 19.9 mm tall: 6 rings fit in 3 mm stock, 3 in 5 mm.
            #expect(positions.count == (thickness == 3 ? 6 : 3))
            #expect(plan.requestedRingCount == 10)
            let note = try #require(plan.ringCountNote)
            #expect(note.hasPrefix("Only \(positions.count) rings fit along this model in \(Int(thickness)) mm stock (10 asked for)"))
        }

        // The cube's ten rings stand exactly a stock thickness apart: all fit.
        let cube = try Self.model("primitives/cube_50mm_binary.stl")
        let cubePlan = try #require(RadialSlicePlanner.plan(model: cube, nRadial: 12, materialThickness: 5))
        #expect(cubePlan.primary?.sliceCount == 10)
        #expect(cubePlan.requestedRingCount == nil && cubePlan.ringCountNote == nil)

        // The slot offset is the gap the rings keep: 5.5 mm apart, so 9 fit.
        let loose = try #require(RadialSlicePlanner.plan(model: cube, nRadial: 12, materialThickness: 5, slotClearance: 0.5))
        #expect(loose.minimumRingSpacing == 5.5)
        #expect(loose.primary?.sliceCount == 9)

        // By Distance: rings asked for 2 mm apart in 5 mm stock stand 5 mm apart.
        let spaced = try #require(RadialSlicePlanner.plan(
            model: torus, nRadial: 12, materialThickness: 5, firstAxisSpacingOverride: 2
        ))
        let spacedPositions = try #require(spaced.primary?.positions)
        #expect(spacedPositions.count >= 2)
        for index in spacedPositions.indices.dropFirst() {
            #expect(abs(spacedPositions[index] - spacedPositions[index - 1] - 5) < 1.0e-9)
        }
        #expect(spaced.requestedRingSpacing == 2)
        #expect(spaced.ringCountNote?.hasPrefix("Rings stand 5 mm apart in 5 mm stock (2 mm asked for)") == true)
        #expect(spaced.primary?.materialThickness == 5)
    }

    @Test
    func ringsKeepOffFlatFacesOfTheModel() throws {
        // The head's neck ends where its head begins, at z = 15: the tenth
        // part of its 60 mm. The third of ten rings would lie in that face.
        let model = try Self.model("organic/low_poly_head.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 12, materialThickness: 5))
        let positions = try #require(plan.primary?.positions)
        #expect(positions.count == 10)
        #expect(abs(positions[2] - (15 - RadialSlicePlanner.flatFaceClearance)) < 1.0e-9)
        for (index, position) in positions.enumerated() where index != 2 {
            #expect(abs(position - (3 + 6 * Double(index))) < 1.0e-9)
        }
    }

    // MARK: - Sections and joints

    @Test(arguments: [
        ("organic/low_poly_head.stl", 12, 5.0),
        ("organic/low_poly_head.stl", 8, 3.0),
        ("pathological/cube_self_intersecting.stl", 6, 3.0),
        ("pathological/cube_self_intersecting.stl", 12, 5.0),
        ("real-world/simple_chair.stl", 12, 5.0),
        ("organic/lumpy_blob.stl", 12, 5.0),
    ])
    func everyNotchHoldsTheFinItWasCutFor(_ fixture: String, _ fins: Int, _ thickness: Double) throws {
        let model = try Self.model(fixture)
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: fins, materialThickness: thickness))
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let bounds = try #require(model.bounds)
        let center = RadialPartBuilder.boxCenter(bounds)
        let axis = try #require(plan.primary?.axis)
        #expect(!assembly.joints.isEmpty)
        var checked = 0
        for joint in assembly.joints {
            let rings = assembly.disks.filter { $0.sliceIndex == joint.ringLayer }
            let finParts = assembly.wedges.filter { $0.sliceIndex == joint.fin }
            let ringFrame = RadialPartBuilder.diskFrame(axis: axis, position: rings.first?.position ?? 0)
            let finFrame = RadialPartBuilder.wedgeFrame(center: center, axis: axis, angle: finParts.first?.position ?? 0)
            // Along the joint's stretch, wherever the line runs through the
            // model, the ring holds it up to the meeting point and a fin
            // piece from there on: the ring's notch always has the fin's
            // stock in it, and the slots meet.
            let inside = Self.modelSpans(model, origin: joint.origin, direction: joint.direction)
            let steps = 40
            for step in 1..<steps {
                let u = joint.start + (joint.end - joint.start) * Double(step) / Double(steps)
                guard abs(u - joint.meet) > 0.05,
                      !inside.contains(where: { abs(u - $0.0) < 0.05 || abs(u - $0.1) < 0.05 }) else { continue }
                let inModel = inside.contains { $0.0 < u && u < $0.1 }
                let point = joint.point(at: u)
                let ringHolds = rings.contains { Self.holds($0, Self.planPoint(point, ringFrame)) }
                let finHolds = finParts.contains { Self.holds($0, Self.planPoint(point, finFrame)) }
                let at = "\(fixture) ring \(joint.ringLayer + 1) / fin \(joint.fin + 1) at u=\(u) (meet \(joint.meet))"
                #expect(ringHolds == (inModel && u < joint.meet), "\(at)")
                #expect(finHolds == (inModel && u > joint.meet), "\(at)")
                checked += inModel ? 1 : 0
            }
        }
        // (A joint whose stock meets only off the crossing line itself, at
        // a corner of the beam, has nothing on the line to check.)
        #expect(checked > assembly.joints.count * 10)
    }

    @Test
    func shellsThatTouchOrOverlapAreCutAsOne() throws {
        // The chair's back stands on its seat: each fin that crosses both is
        // one piece, not two.
        let chair = try Self.model("real-world/simple_chair.stl")
        let chairPlan = try #require(RadialSlicePlanner.plan(model: chair, nRadial: 12, materialThickness: 5))
        let chairParts = RadialPartBuilder.assembly(plan: chairPlan, model: chair)
        #expect(chairParts.wedges.count == 12)
        #expect(chairParts.wedges.allSatisfy { $0.componentIndex == 0 })

        // Two cubes run into each other: a ring through both is the outline
        // of the two together, with no hole where they overlap.
        let cubes = try Self.model("pathological/cube_self_intersecting.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: cubes, nRadial: 12, materialThickness: 5))
        let disks = RadialPartBuilder.assembly(plan: plan, model: cubes).disks
        let overlapping = disks.filter { $0.position > -5 && $0.position < 25 }
        #expect(!overlapping.isEmpty)
        for disk in overlapping {
            #expect(disk.holes.isEmpty && disk.componentIndex == 0)
            let xs = disk.loop.map(\.x)
            #expect(abs((xs.min() ?? 0) + 25) < 1.0e-6 && abs((xs.max() ?? 0) - 45) < 1.0e-6)
        }
        #expect(Set(overlapping.map(\.sliceIndex)).count == overlapping.count)
    }

    @Test
    func piecesNoJointCanLockInAreMarkedNotDropped() throws {
        // A cup with a post in the middle: every line out from the hub runs
        // through the post, then through the wall. The joint sits in the
        // wall, so the fins are slotted clean through the post and the rings'
        // post discs are not locked to any fin.
        let model = try Self.revolved(
            profile: [(0, 0), (25, 0), (25, 40), (17, 40), (17, 4), (8, 4), (8, 40), (0, 40)],
            name: "post-in-cup"
        )
        let plan = try #require(RadialSlicePlanner.plan(model: model, nRadial: 6, materialThickness: 3))
        let assembly = RadialPartBuilder.assembly(plan: plan, model: model)
        let posts = assembly.disks.filter { disk in disk.loop.allSatisfy { ($0.x * $0.x + $0.y * $0.y).squareRoot() < 8.5 } }
        // Every ring above the floor keeps its post disc, marked.
        #expect(posts.count == 9)
        #expect(posts.allSatisfy { !$0.joined })
        #expect(assembly.unjoined.count == posts.count)
        // Everything else holds a joint.
        #expect(assembly.disks.filter { $0.joined }.count == 10)
        #expect(assembly.wedges.allSatisfy { $0.joined })

        let document = CutSheetLayoutBuilder.document(radial: plan, model: model, settings: .defaultValue, revision: 1)
        let detached = document.sheets.flatMap(\.parts).filter(\.isDetached).map(\.label).sorted()
        #expect(detached == RadialPartBuilder.unjoinedLabels(assembly, axisLetter: "Z").sorted())
        #expect(detached.count == 9 && detached.allSatisfy { $0.hasPrefix("Z-") && $0.hasSuffix("-2") })
        let note = RadialPartBuilder.unjoinedNote(labels: detached)
        #expect(note.hasPrefix("9 parts are not locked to any ring or fin (Z-10-2, Z-2-2, Z-3-2, Z-4-2, Z-5-2, Z-6-2, …)"))

        // On models where every line crosses the model once, nothing is marked.
        let sphere = try Self.model("primitives/sphere_d50mm.stl")
        let spherePlan = try #require(RadialSlicePlanner.plan(model: sphere, nRadial: 12, materialThickness: 5))
        #expect(RadialPartBuilder.assembly(plan: spherePlan, model: sphere).unjoined.isEmpty)
    }

    // MARK: - Slivers, thin parts and pieces left out

    /// Hairlines the cuts leave (material narrower than the 1 mm web past
    /// the last slot, beside a notch) are not cut, unless they hold a joint
    /// or join two parts of a piece; those stay, and the part is named as
    /// narrower than the stock, whatever the relief: the 0.67 mm strip a fin
    /// at 0° keeps through the low-poly head's neck (the hub inset takes
    /// 9.33 of its 10 mm), which the neck rings are notched for.
    @Test
    func hairlinesAreNotCutAndThinPartsAreNamed() throws {
        let head = try Self.model("organic/low_poly_head.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: head, nRadial: 12, materialThickness: 5))
        #expect(plan.reliefNote == nil)
        let assembly = RadialPartBuilder.assembly(plan: plan, model: head)
        // No part keeps a hairline unless it is named thin.
        for part in assembly.disks + assembly.wedges {
            let rings = [part.loop] + part.holes
            let opened = try #require(PlanarBoolean.joining(rings, closingBy: 0, openingBy: 0.45))
            let lost = rings.reduce(0.0) { $0 + CutSheetLayoutBuilder.signedArea($1) }
                - opened.reduce(0.0) { $0 + CutSheetLayoutBuilder.signedArea($1) }
            #expect(lost < 0.5 || part.thin, "slice \(part.sliceIndex) lost \(lost)")
        }
        // The fin at 0° keeps its strip through the neck, and is named.
        let finAtZero = try #require(assembly.wedges.first { $0.sliceIndex == 0 })
        #expect(finAtZero.loop.contains { $0.y < 14 })
        #expect(finAtZero.thin)
        let thin = RadialPartBuilder.thinLabels(assembly, axisLetter: "Z")
        #expect(thin.contains("R-1"))
        let notes = RadialPartBuilder.notes(assembly, axisLetter: "Z")
        #expect(notes.contains { $0.hasPrefix("Parts \(thin[0])") && $0.contains("narrower than the stock in places") })
        let document = CutSheetLayoutBuilder.document(radial: plan, model: head, settings: .defaultValue, revision: 1)
        #expect(document.notes == notes)
        #expect(HeadlessExportCommand.radialNotes(plan: plan, model: head).suffix(notes.count) == notes[...])

        // On the torus the wedge of fin each fin kept past its outermost
        // ring's slot (under 1 mm) is gone, and no fin is thin.
        let torus = try Self.model("primitives/torus_R30_r10mm.stl")
        let torusPlan = try #require(RadialSlicePlanner.plan(model: torus, nRadial: 12, materialThickness: 5))
        let fins = RadialPartBuilder.assembly(plan: torusPlan, model: torus).wedges
        #expect(!fins.isEmpty)
        for fin in fins {
            let opened = try #require(PlanarBoolean.joining([fin.loop], closingBy: 0, openingBy: 0.45))
            let lost = CutSheetLayoutBuilder.signedArea(fin.loop) - opened.reduce(0.0) { $0 + CutSheetLayoutBuilder.signedArea($1) }
            #expect(lost < 0.5 && !fin.thin, "fin \(fin.sliceIndex) lost \(lost)")
        }
    }

    /// Ring pieces no fin reaches are left out by name, on the cut sheet,
    /// the CLI and in the measurement: the simple chair's legs.
    @Test
    func ringPiecesNoFinReachesAreNamed() throws {
        let chair = try Self.model("real-world/simple_chair.stl")
        let plan = try #require(RadialSlicePlanner.plan(model: chair, nRadial: 12, materialThickness: 5))
        let assembly = RadialPartBuilder.assembly(plan: plan, model: chair)
        // Rings 1 to 5 cut the four legs and nothing else.
        #expect(Set(assembly.uncrossedRings) == Set(0..<5))
        #expect(assembly.uncrossedRings.count == 20)
        #expect(!assembly.disks.contains { $0.sliceIndex < 5 })
        let labels = RadialPartBuilder.leftOutLabels(assembly, axisLetter: "Z")
        #expect(labels.count == 20 && labels.first == "Z-1" && labels.last == "Z-5")
        let notes = RadialPartBuilder.notes(assembly, axisLetter: "Z")
        #expect(notes.first == "Z-1, Z-2, Z-3, Z-4 and Z-5 cross no fin and are left out: nothing would hold them in place.")
    }

    // MARK: - Relief

    @Test(arguments: [RadialReliefType.dogBone, .horizontal, .vertical])
    func reliefClearsTheInsideCornersOfEveryNotch(_ type: RadialReliefType) throws {
        let model = try Self.model("primitives/cylinder_d40_h80mm.stl")
        let tool = 2.0
        let plan = try #require(RadialSlicePlanner.plan(
            model: model, nRadial: 6, materialThickness: 5, reliefType: type, toolDiameter: tool
        ))
        let plain = try #require(RadialSlicePlanner.plan(model: model, nRadial: 6, materialThickness: 5))
        #expect(plan.reliefNote == nil)
        let relieved = RadialPartBuilder.assembly(plan: plan, model: model)
        let square = RadialPartBuilder.assembly(plan: plain, model: model)
        #expect(relieved.joints == square.joints)
        let bounds = try #require(model.bounds)
        let center = RadialPartBuilder.boxCenter(bounds)
        let r = tool / 2
        let w = plan.slotWidth
        // Where each relief digs, in a slot's own terms: `along` past its
        // bottom toward its mouth (negative: beyond the bottom), `across`
        // from its middle.
        let dug: (along: Double, across: Double)
        switch type {
        case .dogBone: dug = (along: -0.1 * r, across: w / 2 - 0.3 * r)
        case .horizontal: dug = (along: -0.5 * r, across: w / 2 - r)
        case .vertical: dug = (along: r, across: w / 2 + 0.5 * r)
        case .square: dug = (along: 0, across: 0)
        }
        for joint in relieved.joints {
            let ring = try #require(relieved.disks.first { $0.sliceIndex == joint.ringLayer })
            let squareRing = try #require(square.disks.first { $0.sliceIndex == joint.ringLayer })
            let fin = try #require(relieved.wedges.first { $0.sliceIndex == joint.fin })
            let squareFin = try #require(square.wedges.first { $0.sliceIndex == joint.fin })
            let ringFrame = RadialPartBuilder.diskFrame(axis: .z, position: ring.position)
            let finFrame = RadialPartBuilder.wedgeFrame(center: center, axis: .z, angle: fin.position)
            let side = Self.unit(Self.cross(Vec3(x: 0, y: 0, z: 1), joint.direction))
            for sign in [-1.0, 1.0] {
                // The ring's notch opens away from the hub, the fin's slot
                // toward it.
                let ringPoint = Self.offset(joint.point(at: joint.meet + dug.along), side, sign * dug.across)
                #expect(!Self.holds(ring, Self.planPoint(ringPoint, ringFrame)))
                #expect(Self.holds(squareRing, Self.planPoint(ringPoint, ringFrame)))
                let finPoint = Self.offset(joint.point(at: joint.meet - dug.along), Vec3(x: 0, y: 0, z: 1), sign * dug.across)
                #expect(!Self.holds(fin, Self.planPoint(finPoint, finFrame)))
                #expect(Self.holds(squareFin, Self.planPoint(finPoint, finFrame)))
            }
            // The middle of the joint is untouched: the parts still meet.
            let middle = joint.point(at: joint.meet - 0.3)
            #expect(Self.holds(ring, Self.planPoint(middle, ringFrame)))
            #expect(Self.holds(fin, Self.planPoint(joint.point(at: joint.meet + 0.3), finFrame)))
        }

        // Without a tool diameter, or with Square relief, nothing changes.
        for (relief, diameter) in [(type, 0.0), (RadialReliefType.square, tool)] {
            let unchanged = try #require(RadialSlicePlanner.plan(
                model: model, nRadial: 6, materialThickness: 5, reliefType: relief, toolDiameter: diameter
            ))
            let parts = RadialPartBuilder.assembly(plan: unchanged, model: model)
            #expect(parts.disks.map(\.loop) == square.disks.map(\.loop))
            #expect(parts.wedges.map(\.loop) == square.wedges.map(\.loop))
        }
    }

    @Test
    func reliefTooBigForTheNotchesIsCalledOut() throws {
        let model = try Self.model("primitives/cylinder_d40_h80mm.stl")
        func note(_ type: RadialReliefType, _ tool: Double, _ thickness: Double) throws -> String? {
            try #require(RadialSlicePlanner.plan(
                model: model, nRadial: 6, materialThickness: thickness, reliefType: type, toolDiameter: tool
            )).reliefNote
        }
        // In 5 mm notches Dog Bone relief keeps a 1 mm web past the notch
        // bottom up to a 2.83 mm tool, Horizontal relief up to 2 mm.
        #expect(try note(.dogBone, 2.5, 5) == nil)
        #expect(try note(.dogBone, 3.175, 5)?.contains("Use a tool up to 2.83 mm") == true)
        #expect(try note(.horizontal, 2, 5) == nil)
        #expect(try note(.horizontal, 3.175, 5)?.hasPrefix("With a 3.18 mm tool, Horizontal relief digs past the middle") == true)
        #expect(try note(.dogBone, 2.5, 3)?.contains("Use a tool up to 1.41 mm") == true)
        // The cylinder's rings stand 8 mm apart: its fins keep 3 mm between
        // two 5 mm slots. Vertical relief for a 1/8" bit digs 3.175 mm of
        // that away and cuts the fins apart; up to 2 mm it leaves 1 mm.
        let webNote = try note(.vertical, 3.175, 5)
        #expect(webNote?.hasPrefix("With a 3.18 mm tool, Vertical relief leaves less than 1 mm of the 3 mm of fin between neighbouring slots") == true)
        #expect(try note(.vertical, 2, 5) == nil)
        // A tool wider than the notch cannot cut it.
        #expect(try note(.vertical, 6, 5)?.hasPrefix("A 6 mm tool is wider than the 5 mm notches") == true)
        #expect(try note(.square, 6, 5) == nil)
    }

    // MARK: - Export counts

    @Test
    func noFinsReportsTheInterlockedPartsItExports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-radial-n0-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "radial-n0.dxf")
        let measurement = directory.appending(path: "radial-n0.json")
        try HeadlessExportCommand.run(arguments: [
            "--headless-export",
            "--mode", "radial",
            "--n-radial", "0",
            "--format", "dxf",
            "--fixture", Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl").path,
            "--output", output.path,
            "--measurement", measurement.path
        ])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: measurement)) as? [String: Any])
        let radial = try #require(json["radial_slices"] as? [String: Any])
        #expect(radial["radial_count"] as? Int == 0)
        #expect(radial["radial_part_count"] as? Int == 0)
        #expect(radial["first_axis_count"] as? Int == 10)
        #expect(radial["plank_count"] as? Int == 1)
        #expect(radial["total_part_count"] as? Int == 11)
        // The DXF holds those eleven parts: ten rings and one plank.
        let text = try String(contentsOf: output, encoding: .utf8)
        let rows = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let layers = Set(zip(rows, rows.dropFirst()).filter { $0.0 == "8" }.map(\.1)).filter { $0 != "sheet_boundary" }
        #expect(layers.count == 11)
    }

    // MARK: - Helpers

    private static func model(_ fixture: String) throws -> MeshSummary {
        try MeshInspector.inspect(url: repoRoot().appending(path: "tests/fixtures/\(fixture)"))
    }

    /// A solid of revolution about Z of a closed (radius, height) profile,
    /// walked counter-clockwise, in 48 steps, read back from a binary STL.
    private static func revolved(profile: [(Double, Double)], name: String) throws -> MeshSummary {
        let steps = 48
        func point(_ r: Double, _ z: Double, _ k: Int) -> Vec3 {
            let angle = 2 * Double.pi * Double(k) / Double(steps)
            return Vec3(x: r * cos(angle), y: r * sin(angle), z: z)
        }
        var triangles: [(Vec3, Vec3, Vec3)] = []
        for index in profile.indices {
            let (r0, z0) = profile[index]
            let (r1, z1) = profile[(index + 1) % profile.count]
            for k in 0..<steps {
                if r0 > 0 { triangles.append((point(r0, z0, k), point(r1, z1, k), point(r0, z0, k + 1))) }
                if r1 > 0 { triangles.append((point(r0, z0, k + 1), point(r1, z1, k), point(r1, z1, k + 1))) }
            }
        }
        var data = Data(count: 80)
        var count = UInt32(triangles.count).littleEndian
        data.append(Data(bytes: &count, count: 4))
        for triangle in triangles {
            var values: [Float32] = [0, 0, 0]
            for corner in [triangle.0, triangle.1, triangle.2] {
                values += [Float32(corner.x), Float32(corner.y), Float32(corner.z)]
            }
            values.withUnsafeBytes { data.append(contentsOf: $0) }
            data.append(contentsOf: [0, 0])
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString).stl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MeshInspector.inspect(url: url)
    }

    /// Where the line `origin + u · direction` runs inside the model, as
    /// spans of `u`: it enters where it meets a triangle's outside and
    /// leaves where it meets one's inside, so overlapping shells count once.
    /// The line is nudged a hair so it misses edges and vertices.
    private static func modelSpans(_ model: MeshSummary, origin: Vec3, direction: Vec3) -> [(Double, Double)] {
        let o = Vec3(x: origin.x + 1.37e-4 * direction.y, y: origin.y - 1.37e-4 * direction.x, z: origin.z + 0.91e-4)
        let vertices = model.geometry.vertices
        let indices = model.geometry.triangleIndices.map(Int.init)
        var hits: [(Double, Int)] = []
        var index = 0
        while index + 2 < indices.count {
            let a = vertices[indices[index]], b = vertices[indices[index + 1]], c = vertices[indices[index + 2]]
            index += 3
            let e1 = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
            let e2 = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
            let p = cross(direction, e2)
            let det = dot(e1, p)
            guard abs(det) > 1.0e-12 else { continue }
            let t = Vec3(x: o.x - a.x, y: o.y - a.y, z: o.z - a.z)
            let u = dot(t, p) / det
            let q = cross(t, e1)
            let v = dot(direction, q) / det
            guard u >= 0, v >= 0, u + v <= 1 else { continue }
            hits.append((dot(e2, q) / det, det > 0 ? 1 : -1))
        }
        hits.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var spans: [(Double, Double)] = []
        var winding = 0
        var start = 0.0
        for (at, step) in hits {
            let before = winding
            winding += step
            if before == 0, winding != 0 { start = at }
            if before != 0, winding == 0 { spans.append((start, at)) }
        }
        return spans
    }

    /// Whether the part has material at a point of its plane.
    private static func holds(_ part: RadialPartBuilder.ModelPart, _ point: Vec2) -> Bool {
        CutSheetLayoutBuilder.contains(part.loop, point: point)
            && !part.holes.contains { CutSheetLayoutBuilder.contains($0, point: point) }
    }

    private static func planPoint(_ point: Vec3, _ frame: PartPlaneFrame) -> Vec2 {
        let offset = Vec3(x: point.x - frame.origin.x, y: point.y - frame.origin.y, z: point.z - frame.origin.z)
        return Vec2(x: dot(offset, frame.xAxis), y: dot(offset, frame.yAxis))
    }

    private static func offset(_ point: Vec3, _ direction: Vec3, _ distance: Double) -> Vec3 {
        Vec3(x: point.x + direction.x * distance, y: point.y + direction.y * distance, z: point.z + direction.z * distance)
    }

    private static func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func unit(_ v: Vec3) -> Vec3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return Vec3(x: v.x / length, y: v.y / length, z: v.z / length)
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
