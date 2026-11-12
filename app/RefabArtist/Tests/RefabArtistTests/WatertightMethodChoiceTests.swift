import Foundation
import Testing
@testable import RefabArtist

/// Make Watertight must never run a method the user did not pick or the UI
/// does not show, and Rebuild as solid (the destructive whole-surface re-mesh)
/// must never be a silent default. These tests pin the pure rules in
/// `WatertightMethod` (ModifyFormPanel.swift) that decide:
///
///   - `offered`: the buttons the Issues panel shows (there is no default
///     beyond Fix in place — Rebuild only ever runs when picked by name),
///   - `unavailableReason`: a method that can't change anything is disabled,
///   - `restored` / `shouldPersist`: what undo, redo and reopening a project
///     bring back (a saved active Make Watertight never reopens as a
///     different method than the one that produced its result),
///
/// against both hand-built `Diagnosis` values and `OpeningCapper.diagnose` on
/// small synthetic meshes, plus the `SlicerProjectSettings` JSON round trip.
struct WatertightMethodChoiceTests {

    // MARK: - Builders

    /// A diagnosis with every count at zero and no openings; tests set the
    /// fields they care about. Built through the memberwise initializer, so
    /// it describes a state without needing a mesh that produces it.
    private static func diagnosis(
        openings: [OpeningCapper.Opening] = [],
        pinholes: Int = 0,
        boundaryEdges: Int = 0,
        damagedSpots: Int = 0,
        nonManifoldEdges: Int = 0,
        blockingReason: String? = nil
    ) -> OpeningCapper.Diagnosis {
        OpeningCapper.Diagnosis(
            openings: openings,
            pinholes: pinholes,
            collapsedTriangles: 0,
            doubledTriangleGroups: 0,
            doubledTrianglesRemoved: 0,
            looseFragments: 0,
            nonManifoldEdges: nonManifoldEdges,
            orientationConflicts: 0,
            boundaryEdges: boundaryEdges,
            damagedSpots: damagedSpots,
            blockingReason: blockingReason
        )
    }

    private static let oneOpening = OpeningCapper.Opening(
        edgeCount: 24, diameter: 40, center: Vec3(x: 0, y: 0, z: 30),
        normal: Vec3(x: 0, y: 0, z: 1), placement: "top"
    )

    /// Fixable, with an opening: Fix in place, Make walls and Rebuild all fit.
    private static var fixableWithOpening: OpeningCapper.Diagnosis {
        diagnosis(openings: [oneOpening], boundaryEdges: 24)
    }

    /// Fixable, no opening: a local damaged spot on an otherwise closed skin.
    private static var fixableWithoutOpening: OpeningCapper.Diagnosis {
        diagnosis(damagedSpots: 1)
    }

    /// Damage too widespread to fix in place: only Rebuild fits.
    private static var blocked: OpeningCapper.Diagnosis {
        diagnosis(
            nonManifoldEdges: 40,
            blockingReason: "The damage is spread over 31.0% of the surface — too much to fix in place. Use Rebuild as solid."
        )
    }

    /// A closed solid with nothing to change.
    private static var nothingToFix: OpeningCapper.Diagnosis { diagnosis() }

    /// Open edges that do not form traceable holes: nothing fixable, nothing
    /// blocking, boundary edges left. `OpeningCapper.close` throws
    /// `needsRebuild` for exactly this shape.
    private static var untraceableOpenEdges: OpeningCapper.Diagnosis {
        diagnosis(boundaryEdges: 6)
    }

    /// A vertical open-top cup: a cylinder wall plus a triangulated bottom
    /// disk (rim-ring to centre fan), everything wound outward. One opening
    /// (the mouth), nothing else wrong — the shape of the pineapple cup.
    private static func openCup(radius: Double = 20, height: Double = 30, segments: Int = 32, rings: Int = 4) -> MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        var wall: [[Int32]] = []
        for k in 0..<rings {
            let z = height * Double(k) / Double(rings - 1)
            var ring: [Int32] = []
            for i in 0..<segments {
                let theta = 2.0 * Double.pi * Double(i) / Double(segments)
                ring.append(Int32(vertices.count))
                vertices.append(Vec3(x: radius * cos(theta), y: radius * sin(theta), z: z))
            }
            wall.append(ring)
        }
        for k in 0..<(rings - 1) {
            for i in 0..<segments {
                let iN = (i + 1) % segments
                let a = wall[k][i], b = wall[k][iN], c = wall[k + 1][iN], d = wall[k + 1][i]
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        let center = Int32(vertices.count)
        vertices.append(Vec3(x: 0, y: 0, z: 0))
        for i in 0..<segments {
            let iN = (i + 1) % segments
            indices.append(contentsOf: [wall[0][i], center, wall[0][iN]])
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// A closed, outward-wound cube (12 triangles), `size` mm on a side.
    private static func closedCube(size: Double = 10) -> MeshGeometryData {
        let s = size
        let vertices = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0), Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s), Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s),
        ]
        let indices: [Int32] = [
            0, 2, 1, 0, 3, 2,   // bottom (-z)
            4, 5, 6, 4, 6, 7,   // top (+z)
            0, 1, 5, 0, 5, 4,   // front (-y)
            3, 7, 6, 3, 6, 2,   // back (+y)
            0, 4, 7, 0, 7, 3,   // left (-x)
            1, 2, 6, 1, 6, 5,   // right (+x)
        ]
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    // MARK: - offered

    @Test
    func noDiagnosisOffersNothing() {
        #expect(WatertightMethod.offered(for: nil) == [])
    }

    @Test
    func blockedDiagnosisOffersOnlyRebuild() {
        #expect(WatertightMethod.offered(for: Self.blocked) == [.rebuild])
    }

    @Test
    func fixableWithOpeningsOffersAllThreeBestFirst() {
        #expect(WatertightMethod.offered(for: Self.fixableWithOpening) == [.closeOpenings, .walls, .rebuild])
    }

    @Test
    func fixableWithoutOpeningsSkipsMakeWalls() {
        let offered = WatertightMethod.offered(for: Self.fixableWithoutOpening)
        #expect(offered == [.closeOpenings, .rebuild])
        #expect(!offered.contains(.walls))
    }

    @Test
    func rebuildIsNeverFirstUnlessItIsTheOnlyChoice() {
        let diagnoses: [OpeningCapper.Diagnosis?] = [
            nil, Self.fixableWithOpening, Self.fixableWithoutOpening, Self.blocked,
            Self.nothingToFix, Self.untraceableOpenEdges,
        ]
        for diagnosis in diagnoses {
            let offered = WatertightMethod.offered(for: diagnosis)
            if offered.first == .rebuild {
                #expect(offered == [.rebuild])
            }
            // Each method appears at most once (the Issues panel keys its
            // ForEach on the method).
            #expect(Set(offered).count == offered.count)
        }
    }

    @Test
    func closedSolidOffersNothingToFixInPlace() {
        // Characterization: with nothing to fix, no in-place method is
        // offered (the only thing left is the destructive re-mesh, which the
        // Issues panel does not list for a closed solid in the first place
        // — see ModelIssuesPanel.showsRepairSection).
        #expect(WatertightMethod.offered(for: Self.nothingToFix) == [])
    }

    // MARK: - unavailableReason

    /// A method that is known to change nothing is never runnable: its
    /// button is disabled and the reason is its hint.
    @Test
    func fixInPlaceIsUnavailableOnlyWhenItCannotChangeAnything() {
        #expect(WatertightMethod.closeOpenings.unavailableReason(nil) == nil)
        #expect(WatertightMethod.closeOpenings.unavailableReason(Self.fixableWithOpening) == nil)
        #expect(WatertightMethod.closeOpenings.unavailableReason(Self.fixableWithoutOpening) == nil)
        #expect(WatertightMethod.closeOpenings.unavailableReason(Self.nothingToFix) != nil)
        #expect(WatertightMethod.closeOpenings.unavailableReason(Self.blocked) == Self.blocked.blockingReason)
        #expect(WatertightMethod.closeOpenings.unavailableReason(Self.untraceableOpenEdges) != nil)
    }

    @Test
    func fixInPlaceWithEveryOpeningLeftOpenAndNothingElseIsUnavailable() {
        let d = Self.fixableWithOpening
        let leaveAll = d.openings.map { OpeningCapper.OpeningChoice(signature: $0.signature, leaveOpen: true) }
        #expect(WatertightMethod.closeOpenings.unavailableReason(d, choices: leaveAll) != nil)
        // Something else to fix: leaving the openings open still heals it.
        var withDamage = d
        withDamage.damagedSpots = 1
        #expect(WatertightMethod.closeOpenings.unavailableReason(withDamage, choices: leaveAll) == nil)
    }

    @Test
    func makeWallsNeedsAnOpenRimOnAnUndamagedSurface() {
        #expect(WatertightMethod.walls.unavailableReason(nil) == nil)
        #expect(WatertightMethod.walls.unavailableReason(Self.fixableWithOpening) == nil)
        #expect(WatertightMethod.walls.unavailableReason(Self.fixableWithoutOpening) != nil)
        #expect(WatertightMethod.walls.unavailableReason(Self.nothingToFix) != nil)
        var blockedWithOpening = Self.fixableWithOpening
        blockedWithOpening.blockingReason = "too damaged"
        #expect(WatertightMethod.walls.unavailableReason(blockedWithOpening) != nil)
        let closeAll = Self.fixableWithOpening.openings.map {
            OpeningCapper.OpeningChoice(signature: $0.signature, closedInWalls: true)
        }
        #expect(WatertightMethod.walls.unavailableReason(Self.fixableWithOpening, choices: closeAll) != nil)
    }

    @Test
    func rebuildIsAlwaysRunnableWhenPickedByName() {
        for d in [Self.fixableWithOpening, Self.fixableWithoutOpening, Self.blocked, Self.nothingToFix, Self.untraceableOpenEdges] {
            #expect(WatertightMethod.rebuild.unavailableReason(d) == nil)
        }
    }

    /// Every offered method can actually run (no offered button is a no-op).
    @Test
    func everyOfferedMethodIsRunnable() {
        for d in [Self.fixableWithOpening, Self.fixableWithoutOpening, Self.blocked, Self.nothingToFix, Self.untraceableOpenEdges] {
            for method in WatertightMethod.offered(for: d) {
                #expect(method.unavailableReason(d) == nil, "\(method) offered but unavailable: \(d.sentence)")
            }
        }
    }

    // MARK: - restored

    @Test
    func savedMethodRestoresWhateverElseIsSaved() {
        let cases: [(String, WatertightMethod)] = [
            ("walls", .walls), ("closeOpenings", .closeOpenings), ("rebuild", .rebuild),
        ]
        for (raw, method) in cases {
            for tool in [nil, ModifyFormTool.hollow, .thicken, .shrinkwrap] as [ModifyFormTool?] {
                for topHeight in [nil, 0, 5] as [Double?] {
                    #expect(
                        WatertightMethod.restored(saved: raw, activeTool: tool, savedTopHeight: topHeight) == method,
                        "\(raw), tool \(String(describing: tool)), topHeight \(String(describing: topHeight))"
                    )
                }
            }
        }
    }

    @Test
    func legacyMakeWatertightWithoutAMethodOrTopHeightRestoresAsRebuild() {
        // Saved before Fix in place existed: the only method was the
        // whole-surface rebuild.
        #expect(WatertightMethod.restored(saved: nil, activeTool: .shrinkwrap, savedTopHeight: nil) == .rebuild)
    }

    @Test
    func newerMakeWatertightWithoutAMethodLetsTheDiagnosisDecide() {
        // A top-height key means the project post-dates Fix in place; a
        // missing method then means "not chosen", never "Rebuild".
        #expect(WatertightMethod.restored(saved: nil, activeTool: .shrinkwrap, savedTopHeight: 0) == nil)
        #expect(WatertightMethod.restored(saved: nil, activeTool: .shrinkwrap, savedTopHeight: 12) == nil)
        #expect(WatertightMethod.restored(saved: nil, activeTool: .shrinkwrap, savedTopHeight: -3) == nil)
    }

    @Test
    func noActiveToolWithoutAMethodRestoresNothing() {
        #expect(WatertightMethod.restored(saved: nil, activeTool: nil, savedTopHeight: nil) == nil)
        #expect(WatertightMethod.restored(saved: nil, activeTool: nil, savedTopHeight: 0) == nil)
        // Another tool being active is not Make Watertight, whatever the
        // top-height key says.
        #expect(WatertightMethod.restored(saved: nil, activeTool: .hollow, savedTopHeight: nil) == nil)
        #expect(WatertightMethod.restored(saved: nil, activeTool: .thicken, savedTopHeight: nil) == nil)
    }

    @Test
    func garbageMethodStringIsIgnoredNotTurnedIntoRebuild() {
        #expect(WatertightMethod.restored(saved: "bogus", activeTool: .shrinkwrap, savedTopHeight: 5) == nil)
        #expect(WatertightMethod.restored(saved: "", activeTool: .shrinkwrap, savedTopHeight: 0) == nil)
        #expect(WatertightMethod.restored(saved: "Rebuild", activeTool: nil, savedTopHeight: nil) == nil)
        #expect(WatertightMethod.restored(saved: "REBUILD", activeTool: .shrinkwrap, savedTopHeight: 5) == nil)
    }

    @Test
    func rawValuesAreStableBecauseTheyArePersisted() {
        #expect(WatertightMethod.closeOpenings.rawValue == "closeOpenings")
        #expect(WatertightMethod.walls.rawValue == "walls")
        #expect(WatertightMethod.rebuild.rawValue == "rebuild")
    }

    // MARK: - shouldPersist

    @Test
    func shouldPersistTruthTable() {
        // chosen, activeTool, preprocessEnabled -> persisted
        let rows: [(Bool, ModifyFormTool?, Bool, Bool)] = [
            (false, nil, false, false),
            (false, .hollow, false, false),
            (false, .thicken, false, false),
            (false, .shrinkwrap, false, true),
            (false, nil, true, true),
            (false, .hollow, true, true),
            (false, .shrinkwrap, true, true),
            (true, nil, false, true),
            (true, .hollow, false, true),
            (true, .thicken, false, true),
            (true, .shrinkwrap, false, true),
            (true, nil, true, true),
            (true, .shrinkwrap, true, true),
        ]
        for (chosen, tool, preprocess, expected) in rows {
            #expect(
                WatertightMethod.shouldPersist(chosen: chosen, activeTool: tool, preprocessEnabled: preprocess) == expected,
                "chosen \(chosen), tool \(String(describing: tool)), preprocess \(preprocess)"
            )
        }
    }

    @Test
    func anActiveMakeWatertightIsAlwaysPersisted() {
        // The fix for undo / redo / reopen: a diagnosis-default method (never
        // chosen) that produced the result in use is still saved.
        for chosen in [false, true] {
            for preprocess in [false, true] {
                #expect(WatertightMethod.shouldPersist(chosen: chosen, activeTool: .shrinkwrap, preprocessEnabled: preprocess))
            }
        }
    }

    // MARK: - persist then restore never changes the method

    @Test
    func aPersistedMethodAlwaysRestoresAsItself() {
        // Mirrors projectSettings / applyProjectSettings: whenever the method
        // is written it must come back as the same method, so undo, redo and
        // reopen reproduce the result on screen and never a different method
        // (above all never Rebuild for a Fix in place result).
        for method in WatertightMethod.allCases {
            for chosen in [false, true] {
                for tool in [nil, ModifyFormTool.hollow, .thicken, .shrinkwrap] as [ModifyFormTool?] {
                    for preprocess in [false, true] {
                        let saved = WatertightMethod.shouldPersist(chosen: chosen, activeTool: tool, preprocessEnabled: preprocess)
                            ? method.rawValue : nil
                        let restored = WatertightMethod.restored(saved: saved, activeTool: tool, savedTopHeight: 0)
                        if saved != nil {
                            #expect(restored == method, "\(method), chosen \(chosen), tool \(String(describing: tool)), preprocess \(preprocess)")
                        } else {
                            // Nothing saved and nothing active: the diagnosis decides.
                            #expect(restored == nil, "\(method), chosen \(chosen), tool \(String(describing: tool)), preprocess \(preprocess)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Real diagnoses

    @Test
    func openCupDiagnosesAsFixableWithOneOpening() throws {
        let diagnosis = try #require(OpeningCapper.diagnose(Self.openCup()))
        #expect(diagnosis.openings.count == 1)
        #expect(diagnosis.blockingReason == nil)
        #expect(diagnosis.canCloseOpenings)
        #expect(!diagnosis.isNothingToFix)

        // The pineapple-cup case: Fix in place first, every method runnable.
        #expect(WatertightMethod.offered(for: diagnosis) == [.closeOpenings, .walls, .rebuild])
        #expect(WatertightMethod.offered(for: diagnosis).first == .closeOpenings)
    }

    @Test
    func closedCubeDiagnosesAsNothingToFix() throws {
        let diagnosis = try #require(OpeningCapper.diagnose(Self.closedCube()))
        #expect(diagnosis.isNothingToFix)
        #expect(diagnosis.openings.isEmpty)
        #expect(WatertightMethod.offered(for: diagnosis) == [])
    }

    @Test
    func realNonManifoldDamageIsNeverOfferedAnInPlaceMethod() throws {
        // Three triangles sharing one edge: a genuine non-manifold edge that
        // cannot be fixed in place (OpeningCapperTests pins close() throwing
        // needsRebuild for this mesh).
        let u = Vec3(x: 0, y: 0, z: 0), v = Vec3(x: 10, y: 0, z: 0)
        let mesh = MeshGeometryData(
            vertices: [u, v, Vec3(x: 5, y: 8, z: 0), Vec3(x: 5, y: -4, z: 7), Vec3(x: 5, y: -4, z: -7)],
            triangleIndices: [0, 1, 2, 0, 1, 3, 0, 1, 4]
        )
        let diagnosis = try #require(OpeningCapper.diagnose(mesh))
        #expect(!diagnosis.canCloseOpenings)
        let offered = WatertightMethod.offered(for: diagnosis)
        #expect(offered == [.rebuild])
        #expect(WatertightMethod.closeOpenings.unavailableReason(diagnosis) != nil)
    }

    // MARK: - Project settings round trip

    private static func baseSettings() -> SlicerProjectSettings {
        SlicerProjectSettings(
            constructionMode: .stacked,
            sliceAxis: .z,
            secondarySliceAxis: .x,
            materialThickness: 3.0,
            slotClearance: 0.15,
            slotAngleDegrees: 12.0,
            radialSliceCount: 16,
            curveSliceCount: 10,
            curveAmplitude: 8.0,
            materialPreset: .plywood3mm,
            slotReliefEnabled: true,
            slotReliefDiameter: 3.0,
            dowelsEnabled: true,
            dowelDiameter: 4.0,
            dowelInset: 8.0,
            exportFormat: .svg,
            exportLayoutSettings: .defaultValue,
            modelScaleFactor: 1.25,
            importUnit: .centimeters,
            customSliceDistributionEnabled: true,
            customSliceCount: 18
        )
    }

    private func roundTrip(_ settings: SlicerProjectSettings) throws -> SlicerProjectSettings {
        let document = SlicerProjectDocument(modelPath: "/fixtures/pineapple_cup.obj", settings: settings)
        let data = try JSONEncoder().encode(document)
        return try JSONDecoder().decode(SlicerProjectDocument.self, from: data).settings
    }

    @Test
    func savedFixInPlaceReopensAsFixInPlace() throws {
        var settings = Self.baseSettings()
        settings.modifyTool = ModifyFormTool.shrinkwrap.rawValue
        settings.modifyWatertightMethod = WatertightMethod.closeOpenings.rawValue
        settings.modifyWatertightTopHeightMm = 0

        let decoded = try roundTrip(settings)
        #expect(decoded.modifyTool == "shrinkwrap")
        #expect(decoded.modifyWatertightMethod == "closeOpenings")
        #expect(decoded.modifyWatertightTopHeightMm == 0)

        let restored = WatertightMethod.restored(
            saved: decoded.modifyWatertightMethod,
            activeTool: decoded.modifyTool.flatMap(ModifyFormTool.init(rawValue:)),
            savedTopHeight: decoded.modifyWatertightTopHeightMm
        )
        #expect(restored == .closeOpenings)
    }

    @Test
    func everyMethodSurvivesTheProjectFileRoundTrip() throws {
        for method in WatertightMethod.allCases {
            var settings = Self.baseSettings()
            settings.modifyTool = ModifyFormTool.shrinkwrap.rawValue
            settings.modifyWatertightMethod = method.rawValue
            settings.modifyWatertightTopHeightMm = 0
            let decoded = try roundTrip(settings)
            let restored = WatertightMethod.restored(
                saved: decoded.modifyWatertightMethod,
                activeTool: decoded.modifyTool.flatMap(ModifyFormTool.init(rawValue:)),
                savedTopHeight: decoded.modifyWatertightTopHeightMm
            )
            #expect(restored == method)
        }
    }

    @Test
    func legacyProjectWithMakeWatertightOnRestoresAsRebuild() throws {
        // A file saved before Fix in place existed: Make Watertight active,
        // no method key, no top-height key.
        var settings = Self.baseSettings()
        settings.modifyTool = ModifyFormTool.shrinkwrap.rawValue
        settings.modifyWatertightMethod = WatertightMethod.closeOpenings.rawValue
        settings.modifyWatertightTopHeightMm = 0
        let document = SlicerProjectDocument(modelPath: "/fixtures/pineapple_cup.obj", settings: settings)
        let data = try JSONEncoder().encode(document)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settingsJSON = try #require(json["settings"] as? [String: Any])
        #expect(settingsJSON["modifyWatertightMethod"] != nil)
        settingsJSON.removeValue(forKey: "modifyWatertightMethod")
        settingsJSON.removeValue(forKey: "modifyWatertightTopHeightMm")
        json["settings"] = settingsJSON
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: stripped).settings
        #expect(decoded.modifyTool == "shrinkwrap")
        #expect(decoded.modifyWatertightMethod == nil)
        #expect(decoded.modifyWatertightTopHeightMm == nil)
        let restored = WatertightMethod.restored(
            saved: decoded.modifyWatertightMethod,
            activeTool: decoded.modifyTool.flatMap(ModifyFormTool.init(rawValue:)),
            savedTopHeight: decoded.modifyWatertightTopHeightMm
        )
        #expect(restored == .rebuild)
    }

    @Test
    func newProjectWithMakeWatertightOffAndNoPickRestoresNothing() throws {
        // Tool off, method not persisted (shouldPersist false), top height
        // always written by projectSettings: nothing restored, so the
        // diagnosis decides on the next load.
        var settings = Self.baseSettings()
        settings.modifyTool = nil
        settings.modifyWatertightMethod = nil
        settings.modifyWatertightTopHeightMm = 0
        let decoded = try roundTrip(settings)
        let restored = WatertightMethod.restored(
            saved: decoded.modifyWatertightMethod,
            activeTool: decoded.modifyTool.flatMap(ModifyFormTool.init(rawValue:)),
            savedTopHeight: decoded.modifyWatertightTopHeightMm
        )
        #expect(restored == nil)
    }

    @Test
    func makeWatertightUnderHollowSurvivesTheProjectFileRoundTrip() throws {
        // Hollow applied on top of Make Watertight: the base flag and its
        // method are saved, so reopening (and undo) runs Hollow on the same
        // fixed surface, not on the raw open mesh.
        var settings = Self.baseSettings()
        settings.modifyTool = ModifyFormTool.hollow.rawValue
        settings.modifyWatertightBase = true
        settings.modifyWatertightMethod = WatertightMethod.walls.rawValue
        settings.modifyWatertightTopHeightMm = 0
        let decoded = try roundTrip(settings)
        #expect(decoded.modifyWatertightBase == true)
        #expect(WatertightMethod.restored(
            saved: decoded.modifyWatertightMethod,
            activeTool: decoded.modifyTool.flatMap(ModifyFormTool.init(rawValue:)),
            savedTopHeight: decoded.modifyWatertightTopHeightMm
        ) == .walls)

        // Older files have no base key: Hollow alone.
        var plain = Self.baseSettings()
        plain.modifyTool = ModifyFormTool.hollow.rawValue
        #expect(try roundTrip(plain).modifyWatertightBase == nil)
    }
}
