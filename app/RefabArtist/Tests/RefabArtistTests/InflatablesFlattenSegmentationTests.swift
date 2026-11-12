import Foundation
import Testing
@testable import RefabArtist

struct InflatablesFlattenSegmentationTests {
    @Test
    func flattenUsesBoundaryLoopInsteadOfConvexHullForConcaveChart() throws {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 2, y: 0, z: 0),
                Vec3(x: 2, y: 1, z: 0),
                Vec3(x: 1, y: 1, z: 0),
                Vec3(x: 1, y: 2, z: 0),
                Vec3(x: 0, y: 2, z: 0)
            ],
            triangleIndices: [
                0, 1, 3,
                1, 2, 3,
                0, 3, 5,
                3, 4, 5
            ]
        )
        let chart = InflatableChart(
            id: "concave",
            mesh: mesh,
            sourceFaceIDs: [0, 1, 2, 3],
            axis: 2,
            angularBin: 0
        )

        let flattened = try #require(LSCM.flatten(chart))

        #expect(flattened.outline2D.count == 6)
        #expect(flattened.uvByVertex.count == mesh.vertices.count)
        #expect(flattened.maxStretch < 1.0001)
    }

    @Test
    func segmentationProducesConnectedNonOverlappingFaceCover() throws {
        let model = try MeshInspector.inspect(
            url: Self.repoRoot().appending(path: "tests/fixtures/primitives/cylinder_d40_h80mm.stl")
        )
        let cleaned = try InflatablesClean.cleanForInflatable(model.geometry)
        let settings = InflatablesSettings(
            material: .rigidMembrane,
            targetPanelWidthMM: 60,
            maxPanelCount: 32,
            seamAllowanceMM: 8,
            joinMethod: .weld
        )
        let charts = DevelopableSegmentation.segment(mesh: cleaned, settings: settings)
        let faceCount = cleaned.triangleIndices.count / 3
        let faceIDs = charts.flatMap(\.sourceFaceIDs)

        #expect(!charts.isEmpty)
        #expect(faceIDs.sorted() == Array(0..<faceCount))
        #expect(Set(faceIDs).count == faceIDs.count)
        #expect(charts.count <= settings.maxPanelCount)
        #expect(charts.allSatisfy { Self.isConnected(faceIDs: $0.sourceFaceIDs, mesh: cleaned) })
    }

    @Test
    func segmentationDoesNotMergeDisconnectedIslandsToSatisfyMaxPanelCount() throws {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 10, y: 10, z: 0),
                Vec3(x: 0, y: 10, z: 0),
                Vec3(x: 30, y: 0, z: 0),
                Vec3(x: 40, y: 0, z: 0),
                Vec3(x: 40, y: 10, z: 0),
                Vec3(x: 30, y: 10, z: 0)
            ],
            triangleIndices: [
                0, 1, 2,
                0, 2, 3,
                4, 5, 6,
                4, 6, 7
            ]
        )
        let settings = InflatablesSettings(
            material: .rigidMembrane,
            targetPanelWidthMM: 1_000,
            maxPanelCount: 1,
            seamAllowanceMM: 8,
            joinMethod: .weld
        )

        let charts = DevelopableSegmentation.segment(mesh: mesh, settings: settings)

        #expect(charts.count == 2)
        #expect(charts.allSatisfy { Self.isConnected(faceIDs: $0.sourceFaceIDs, mesh: mesh) })
    }

    @Test
    func segmentationTreatsCoincidentEdgesAsConnected() throws {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 10, y: 10, z: 0),
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 10, z: 0),
                Vec3(x: 0, y: 10, z: 0)
            ],
            triangleIndices: [
                0, 1, 2,
                3, 4, 5
            ]
        )
        let settings = InflatablesSettings(
            material: .rigidMembrane,
            targetPanelWidthMM: 1_000,
            maxPanelCount: 1,
            seamAllowanceMM: 8,
            joinMethod: .weld
        )

        let charts = DevelopableSegmentation.segment(mesh: mesh, settings: settings)

        #expect(charts.count == 1)
        #expect(charts.first?.sourceFaceIDs.sorted() == [0, 1])
    }

    private static func isConnected(faceIDs: [Int], mesh: MeshGeometryData) -> Bool {
        guard let start = faceIDs.first else { return false }
        let group = Set(faceIDs)
        let adjacency = faceAdjacency(mesh: mesh)
        var seen: Set<Int> = [start]
        var queue = [start]
        while let current = queue.first {
            queue.removeFirst()
            for next in adjacency[current, default: []] where group.contains(next) && !seen.contains(next) {
                seen.insert(next)
                queue.append(next)
            }
        }
        return seen == group
    }

    private static func faceAdjacency(mesh: MeshGeometryData) -> [Int: [Int]] {
        struct EdgeKey: Hashable {
            var a: Int
            var b: Int

            init(_ first: Int, _ second: Int) {
                if first <= second {
                    a = first
                    b = second
                } else {
                    a = second
                    b = first
                }
            }
        }

        var edgeToFaces: [EdgeKey: [Int]] = [:]
        var offset = 0
        while offset + 2 < mesh.triangleIndices.count {
            let faceID = offset / 3
            let tri = [
                Int(mesh.triangleIndices[offset]),
                Int(mesh.triangleIndices[offset + 1]),
                Int(mesh.triangleIndices[offset + 2])
            ]
            for edge in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] {
                edgeToFaces[EdgeKey(edge.0, edge.1), default: []].append(faceID)
            }
            offset += 3
        }

        var result: [Int: Set<Int>] = [:]
        for faces in edgeToFaces.values where faces.count > 1 {
            for face in faces {
                for neighbor in faces where neighbor != face {
                    result[face, default: []].insert(neighbor)
                }
            }
        }
        return result.mapValues { Array($0) }
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
