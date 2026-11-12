import XCTest
@testable import RefabArtist

/// Diagnostic harness for the M2 feasibility question: does a ≤ maxPieces
/// planar decomposition of the healed hand exist where every piece measures
/// within tolerance under §3.2? Runs only with UNDERCUT_FEASIBILITY_PROBE=1;
/// it is an evidence generator (PRD §11.3 / §14), not a regression test.
final class UndercutFeasibilityProbeTests: XCTestCase {
    private struct CutSpec {
        let target: String
        let normal: Vec3
        let offset: Double
    }

    private struct ProbeLeaf {
        let label: String
        let mesh: AttributedMesh
    }

    private let toleranceMM = 2.0
    private let minRegionAreaMM2 = 4.0

    /// Edit this list between runs. Each cut targets a leaf by label: the root
    /// is "R"; a cut of leaf L creates "L-" (negative side) and "L+".
    private var cuts: [CutSpec] {
        [
            CutSpec(
                target: "R",
                normal: Vec3(x: 0.8665007, y: 0.0111591, z: 0.4990511),
                offset: 122.3128
            ),
            CutSpec(
                target: "R+",
                normal: Vec3(x: 0.32683059182914964, y: -0.06474145075606239, z: -0.9428628260773717),
                offset: -66.346
            ),
            CutSpec(
                target: "R+-",
                normal: Vec3(x: 0.25989191300775444, y: -0.43388856455269487, z: -0.8626684804161864),
                offset: -114.185
            ),
            CutSpec(
                target: "R++",
                normal: Vec3(x: 0.85065080835204, y: 0.0, z: -0.5257311121191336),
                offset: 47.036
            ),
            CutSpec(
                target: "R+++",
                normal: Vec3(x: 0.32683059182914925, y: -0.06474145075606264, z: -0.9428628260773719),
                offset: -50.15
            ),
            CutSpec(
                target: "R++-",
                normal: Vec3(x: 0.9097421974394094, y: -0.3797837254983625, z: -0.16773030747214043),
                offset: 50.10
            ),
            CutSpec(
                target: "R+-+",
                normal: Vec3(x: 0.24674587313696347, y: 0.02806666579659417, z: -0.9686736996331322),
                offset: -90.75
            ),
            CutSpec(
                target: "R++-+",
                normal: Vec3(x: 0.0, y: 1.0, z: 0.0),
                offset: 59.72
            ),
            CutSpec(
                target: "R+++-",
                normal: Vec3(x: 0.5, y: 0.3090169943749474, z: 0.8090169943749475),
                offset: 181.29
            ),
            CutSpec(
                target: "R+-+-",
                normal: Vec3(x: 0.28899141040229315, y: -0.09747161989929999, z: -0.9523566810958486),
                offset: -97.70
            ),
            CutSpec(
                target: "R++++",
                normal: Vec3(x: 0.4930568322915584, y: -0.019723760599304897, z: -0.8697734954563948),
                offset: -9.74
            ),
            CutSpec(
                target: "R+-++",
                normal: Vec3(x: 0.5677641340545615, y: 0.8195970913411382, z: 0.07684071802384358),
                offset: 131.59
            ),
        ]
    }

    private var coarse: DirectionalAccessibilityAnalyzer.Configuration {
        let policy = UndercutSplitTolerancePolicy.current
        return DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: 2,
            gridDivisor: 128,
            refinementPasses: 0,
            maximumSamples: 40_000,
            linearWeldMM: policy.linearWeldMM,
            rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: 1
        )
    }

    /// Mirrors the production full-resolution finalization configuration.
    private var confirm: DirectionalAccessibilityAnalyzer.Configuration {
        let policy = UndercutSplitTolerancePolicy.current
        return DirectionalAccessibilityAnalyzer.Configuration(
            targetGridStepMM: nil,
            gridDivisor: 512,
            refinementPasses: 3,
            maximumSamples: 120_000,
            linearWeldMM: policy.linearWeldMM,
            rayHitCoincidenceMM: policy.rayHitCoincidenceMM,
            minimumTriangleAreaMM2: policy.minimumTriangleAreaMM2,
            draftAdvisoryDegrees: 1
        )
    }

    func testHandFeasibilityProbe() throws {
        guard ProcessInfo.processInfo.environment["UNDERCUT_FEASIBILITY_PROBE"] == "1" else {
            throw XCTSkip("Feasibility diagnostic; run with UNDERCUT_FEASIBILITY_PROBE=1")
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handStand_ex3_healed_50k.obj")
        let geometry = try MeshInspector.inspect(url: url).geometry
        let attributed = try SourceFaceMap.attributedMesh(from: geometry)
        print("PROBE source volume=\(abs(attributed.signedVolume))")

        var leaves = [ProbeLeaf(label: "R", mesh: attributed)]
        for cut in cuts {
            guard let index = leaves.firstIndex(where: { $0.label == cut.target }) else {
                XCTFail("PROBE no leaf labeled \(cut.target); have \(leaves.map(\.label))")
                return
            }
            let parent = leaves[index]
            let plane = try XCTUnwrap(CanonicalPlane(normal: cut.normal, offset: cut.offset))
            let split = try PartitionGeometry.splitAttributed(
                parent.mesh,
                plane: plane,
                cutNodeID: PartitionCutNodeID(rawValue: "probe-\(cut.target)")
            )
            print("PROBE cut \(cut.target) normal=\(cut.normal) offset=\(cut.offset) volumes=\(abs(split.negative.signedVolume))+\(abs(split.positive.signedVolume))")
            leaves.remove(at: index)
            leaves.append(ProbeLeaf(label: "\(cut.target)-", mesh: split.negative))
            leaves.append(ProbeLeaf(label: "\(cut.target)+", mesh: split.positive))
        }
        leaves.sort { $0.label < $1.label }
        print("PROBE leaves=\(leaves.count) labels=\(leaves.map(\.label))")

        var failing: [String] = []
        for leaf in leaves {
            if sweep(leaf: leaf) == false {
                failing.append(leaf.label)
                try miniSearch(leaf: leaf)
            }
        }
        print("PROBE summary pieces=\(leaves.count) failing=\(failing)")
    }

    // MARK: - Plain sweep (pass/fail for a settled leaf)

    @discardableResult
    private func sweep(leaf: ProbeLeaf) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let directions = PullDirectionCandidates.generate(
            geometry: leaf.mesh.geometry,
            icosphereVertexCount: 162
        )
        var best: (axis: Vec3, result: DirectionalAccessibilityAnalyzer.Result)?
        var passed: (axis: Vec3, result: DirectionalAccessibilityAnalyzer.Result)?
        var evaluated = 0
        for direction in directions.prefix(140) {
            guard let result = try? DirectionalAccessibilityAnalyzer.analyze(
                geometry: leaf.mesh.geometry,
                pullAxis: direction,
                configuration: coarse
            ) else { continue }
            evaluated += 1
            if best == nil || result.worstDepthMM < best!.result.worstDepthMM {
                best = (direction, result)
            }
            if result.status(toleranceMM: toleranceMM, minRegionAreaMM2: minRegionAreaMM2) == .withinTolerance,
               let confirmed = try? DirectionalAccessibilityAnalyzer.analyze(
                geometry: leaf.mesh.geometry,
                pullAxis: direction,
                configuration: confirm
               ),
               confirmed.status(toleranceMM: toleranceMM, minRegionAreaMM2: minRegionAreaMM2) == .withinTolerance {
                passed = (direction, confirmed)
                break
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let volume = abs(leaf.mesh.signedVolume)
        if let passed {
            print("PROBE leaf=\(leaf.label) PASS axis=\(passed.axis) depth=\(passed.result.worstDepthMM) resolution=\(passed.result.effectiveResolutionMM) volume=\(volume) evaluated=\(evaluated) elapsed=\(String(format: "%.1f", elapsed))s")
            return true
        }
        print("PROBE leaf=\(leaf.label) FAIL bestAxis=\(String(describing: best?.axis)) bestDepth=\(best?.result.worstDepthMM ?? .nan) volume=\(volume) evaluated=\(evaluated) elapsed=\(String(format: "%.1f", elapsed))s")
        return false
    }

    // MARK: - Candidate-battery mini-search (best single cut for a leaf)

    private struct Candidate {
        let normal: Vec3
        let offset: Double
        let note: String
    }

    private func miniSearch(leaf: ProbeLeaf) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let parentVolume = abs(leaf.mesh.signedVolume)

        // Regions from the leaf's best quick axis guide the candidates.
        let scanDirections = PullDirectionCandidates.generate(
            geometry: leaf.mesh.geometry,
            icosphereVertexCount: 42
        )
        var guide: (axis: Vec3, result: DirectionalAccessibilityAnalyzer.Result)?
        for direction in scanDirections.prefix(32) {
            guard let result = try? DirectionalAccessibilityAnalyzer.analyze(
                geometry: leaf.mesh.geometry,
                pullAxis: direction,
                configuration: coarse
            ) else { continue }
            if guide == nil || result.worstDepthMM < guide!.result.worstDepthMM {
                guide = (direction, result)
            }
        }
        guard let guide else {
            print("PROBE search leaf=\(leaf.label) no measurable direction")
            return
        }
        let regions = guide.result.regions
            .filter { $0.areaMM2 >= minRegionAreaMM2 && $0.depthMM > toleranceMM }
            .sorted { $0.depthMM > $1.depthMM }
        print("PROBE search leaf=\(leaf.label) volume=\(parentVolume) guideAxis=\(guide.axis) guideDepth=\(guide.result.worstDepthMM) regions=\(regions.prefix(4).map { ($0.depthMM, $0.centroid) })")

        var candidates: [Candidate] = []
        for region in regions.prefix(4) {
            for escape in region.suggestedEscapeDirections.prefix(2) {
                let base = dot(region.centroid, escape)
                for shift in [0.0, 2.0, -2.0, 5.0, -5.0] {
                    candidates.append(Candidate(
                        normal: escape,
                        offset: base + shift,
                        note: "unhook d=\(String(format: "%.1f", region.depthMM)) s=\(shift)"
                    ))
                }
            }
        }
        if regions.count >= 2 {
            for i in 0..<min(3, regions.count) {
                for j in (i + 1)..<min(4, regions.count) {
                    let a = regions[i].centroid
                    let b = regions[j].centroid
                    let axis = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
                    let length = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
                    guard length > 5 else { continue }
                    let normal = Vec3(x: axis.x / length, y: axis.y / length, z: axis.z / length)
                    let midpoint = Vec3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: (a.z + b.z) / 2)
                    for shift in [0.0, 3.0, -3.0] {
                        candidates.append(Candidate(
                            normal: normal,
                            offset: dot(midpoint, normal) + shift,
                            note: "separator \(i)-\(j) s=\(shift)"
                        ))
                    }
                }
            }
        }
        for region in regions.prefix(2) {
            for axis in [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 0, z: 1)] {
                candidates.append(Candidate(
                    normal: axis,
                    offset: dot(region.centroid, axis),
                    note: "world@region"
                ))
            }
        }

        var seen = Set<String>()
        var scored: [(candidate: Candidate, worst: Double, detail: String)] = []
        for candidate in candidates {
            let key = "\(Int((candidate.normal.x * 20).rounded())),\(Int((candidate.normal.y * 20).rounded())),\(Int((candidate.normal.z * 20).rounded())),\(Int((candidate.offset * 2).rounded()))"
            guard seen.insert(key).inserted else { continue }
            guard let plane = CanonicalPlane(normal: candidate.normal, offset: candidate.offset) else { continue }
            guard let split = try? PartitionGeometry.splitAttributed(
                leaf.mesh,
                plane: plane,
                cutNodeID: PartitionCutNodeID(rawValue: "search-\(leaf.label)")
            ) else { continue }
            let negativeVolume = abs(split.negative.signedVolume)
            let positiveVolume = abs(split.positive.signedVolume)
            guard negativeVolume > parentVolume * 0.03, positiveVolume > parentVolume * 0.03 else { continue }
            guard let negative = quickBestDepth(split.negative.geometry, parentAxis: guide.axis),
                  let positive = quickBestDepth(split.positive.geometry, parentAxis: guide.axis) else { continue }
            let worst = max(negative.depth, positive.depth)
            scored.append((
                candidate,
                worst,
                "n=\(candidate.normal) o=\(String(format: "%.2f", candidate.offset)) [\(candidate.note)] -> neg(v=\(Int(negativeVolume)) d=\(String(format: "%.2f", negative.depth)) a=\(negative.axis)) pos(v=\(Int(positiveVolume)) d=\(String(format: "%.2f", positive.depth)) a=\(positive.axis))"
            ))
        }
        scored.sort { $0.worst < $1.worst }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("PROBE search leaf=\(leaf.label) evaluated=\(scored.count) candidates elapsed=\(String(format: "%.1f", elapsed))s")
        for entry in scored.prefix(5) {
            print("PROBE   best worst=\(String(format: "%.3f", entry.worst)) \(entry.detail)")
        }
    }

    /// Cheap minimum best-depth over a small direction battery; early exits
    /// well below tolerance since candidate ranking only needs the ordering.
    private func quickBestDepth(
        _ geometry: MeshGeometryData,
        parentAxis: Vec3
    ) -> (depth: Double, axis: Vec3)? {
        var directions: [Vec3] = [parentAxis]
        directions.append(contentsOf: PullDirectionCandidates.generate(
            geometry: geometry,
            icosphereVertexCount: 12
        ))
        var best: (depth: Double, axis: Vec3)?
        var tried = 0
        for direction in directions {
            if tried >= 18 { break }
            guard let result = try? DirectionalAccessibilityAnalyzer.analyze(
                geometry: geometry,
                pullAxis: direction,
                configuration: coarse
            ) else { continue }
            tried += 1
            if best == nil || result.worstDepthMM < best!.depth {
                best = (result.worstDepthMM, direction)
            }
            if let best, best.depth < 1.2 { return best }
        }
        return best
    }

    private func dot(_ a: Vec3, _ b: Vec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
