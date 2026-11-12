import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistUXM5ProgressTests {
    @Test
    func stagesUseTheExactArtistOrderAndElapsedFormatting() {
        #expect(MoldBuildStage.allCases.map(\.label) == [
            "Preparing master",
            "Building cavity",
            "Building shell",
            "Splitting",
            "Keys & rim",
            "Pour hole & vents",
            "Checking watertightness",
            "Packaging",
        ])
        #expect(MoldBuildStage.buildingShell.ordinal == 3)
        #expect(MotherMoldBuildProgressPresentation.elapsedText(seconds: 0) == "0:00")
        #expect(MotherMoldBuildProgressPresentation.elapsedText(seconds: 102.9) == "1:42")
        #expect(MotherMoldBuildProgressPresentation.statusLine(
            stage: .buildingShell,
            elapsedSeconds: 102.9
        ) == "Building shell… 3 of 8 · 1:42 elapsed")
    }

    @Test
    func cancellationBeforeStageOneEmitsNoProgress() {
        let recorder = StageRecorder()

        do {
            _ = try MotherMoldPlanner.planThrowing(
                model: Self.cubeSummary(),
                settings: Self.fastSettings(),
                progress: { recorder.append($0) },
                isCancelled: { true }
            )
            Issue.record("Expected cancellation before the first stage")
        } catch {
            #expect(error as? MotherMoldPlannerError == .cancelled)
        }
        #expect(recorder.snapshot().isEmpty)
    }

    @Test
    func cancellationFromFirstProgressCallbackStopsBeforeCavity() {
        let recorder = StageRecorder()
        let cancellation = CancellationLatch()

        do {
            _ = try MotherMoldPlanner.planThrowing(
                model: Self.cubeSummary(),
                settings: Self.fastSettings(),
                progress: {
                    recorder.append($0)
                    cancellation.cancel()
                },
                isCancelled: { cancellation.isCancelled }
            )
            Issue.record("Expected cancellation before cavity work")
        } catch {
            #expect(error as? MotherMoldPlannerError == .cancelled)
        }
        #expect(recorder.snapshot() == [.preparingMaster])
    }

    @Test
    func reusableToolingPathHonorsTheSameStageCancellationHook() {
        let recorder = StageRecorder()
        let cancellation = CancellationLatch()
        var settings = Self.fastSettings()
        settings.subtype = .siliconeJacket
        settings.toolingContractVersion = 3
        settings.packaging = .manufacturingZip

        do {
            _ = try MotherMoldPlanner.planThrowing(
                model: Self.cubeSummary(),
                settings: settings,
                progress: { stage in
                    recorder.append(stage)
                    if stage == .buildingCavity {
                        cancellation.cancel()
                    }
                },
                isCancelled: { cancellation.isCancelled }
            )
            Issue.record("Expected reusable tooling cancellation before shell work")
        } catch {
            let failure = error as? MotherMoldPlannerError
            #expect(failure == .cancelled)
        }
        #expect(recorder.snapshot() == [.preparingMaster, .buildingCavity])
    }

    @Test
    func validCubeEmitsEveryStageExactlyOnceInOrder() throws {
        let recorder = StageRecorder()

        let plan = try MotherMoldPlanner.planThrowing(
            model: Self.cubeSummary(),
            settings: Self.fastSettings(),
            progress: { recorder.append($0) },
            isCancelled: { false }
        )

        #expect(!plan.parts.isEmpty)
        #expect(recorder.snapshot() == MoldBuildStage.allCases)
    }

    @Test
    func cancellationHasTheExactArtistFacingMessage() {
        #expect(MotherMoldUIContract.buildFailureMessage(MotherMoldPlannerError.cancelled) == "Build cancelled.")
    }

    @Test
    func contentViewStoresTheTaskRelayAndShowsCancelableProgress() throws {
        let source = try String(contentsOf: Self.contentViewURL, encoding: .utf8)

        #expect(source.contains("motherMoldBuildTask"))
        #expect(source.contains("MotherMoldBuildRelay"))
        #expect(source.contains("motherMoldBuildStartedAt"))
        #expect(source.contains("Cancel build"))
        #expect(source.contains("Build cancelled."))
        #expect(source.contains("TimelineView"))
    }

    private static var contentViewURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RefabArtist/ContentView.swift")
    }

    private static func fastSettings() -> MotherMoldSettings {
        var settings = MotherMoldSettings.defaultValue
        settings.subtype = .slipShell
        settings.parts = .two
        settings.key.type = .none
        settings.flange.enabled = false
        settings.floor = false
        settings.spout = SpoutSettings(
            mode: .auto,
            spoutDiameter: 0,
            ventCount: 0,
            ventDiameter: 0.5,
            manualSpoutX: 0,
            manualSpoutY: 0,
            manualSpoutZ: 0
        )
        return settings
    }

    private static func cubeSummary(side: Double = 20) -> MeshSummary {
        let geometry = cubeGeometry(side: side)
        return MeshSummary(
            name: "m5-stage-cube",
            path: "/tmp/m5-stage-cube.stl",
            format: "stl",
            byteCount: 0,
            vertexObservationCount: geometry.vertices.count,
            faceCount: geometry.triangleIndices.count / 3,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: Bounds3D(
                min: Vec3(x: 0, y: 0, z: 0),
                max: Vec3(x: side, y: side, z: side)
            ),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    private static func cubeGeometry(side: Double) -> MeshGeometryData {
        let s = side
        return MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: s, y: 0, z: 0),
                Vec3(x: s, y: s, z: 0),
                Vec3(x: 0, y: s, z: 0),
                Vec3(x: 0, y: 0, z: s),
                Vec3(x: s, y: 0, z: s),
                Vec3(x: s, y: s, z: s),
                Vec3(x: 0, y: s, z: s),
            ],
            triangleIndices: [
                0, 2, 1, 0, 3, 2,
                4, 5, 6, 4, 6, 7,
                0, 1, 5, 0, 5, 4,
                3, 6, 2, 3, 7, 6,
                0, 4, 7, 0, 7, 3,
                1, 2, 6, 1, 6, 5,
            ]
        )
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [MoldBuildStage] = []

    func append(_ stage: MoldBuildStage) {
        lock.lock()
        stages.append(stage)
        lock.unlock()
    }

    func snapshot() -> [MoldBuildStage] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }
}

private final class CancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
