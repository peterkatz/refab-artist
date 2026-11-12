import Testing
@testable import RefabArtist

struct ViewportMeshRenderDataTests {
    @Test
    func ghostedReferenceMeshNeverDrawsFeatureEdgeCracksThroughTheMold() {
        #expect(ViewportMeshRenderData.shouldRenderFeatureEdges(
            triangleCount: 100,
            ghosted: false
        ))
        #expect(!ViewportMeshRenderData.shouldRenderFeatureEdges(
            triangleCount: 100,
            ghosted: true
        ))
    }

    @Test
    func flatShadedMeshDuplicatesVerticesAndAssignsFaceNormals() {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0)
            ],
            triangleIndices: [0, 1, 2]
        )

        let renderMesh = ViewportMeshRenderData.flatShadedMesh(from: mesh)

        #expect(renderMesh.vertices.count == 3)
        #expect(renderMesh.normals == [
            Vec3(x: 0, y: 0, z: 1),
            Vec3(x: 0, y: 0, z: 1),
            Vec3(x: 0, y: 0, z: 1)
        ])
        #expect(renderMesh.triangleIndices == [0, 1, 2])
    }

    @Test
    func featureEdgesSuppressCoplanarTriangulationLines() {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 1, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0)
            ],
            triangleIndices: [
                0, 1, 2,
                0, 2, 3
            ]
        )

        let edges = ViewportMeshRenderData.featureEdges(from: mesh)

        #expect(edges.count == 4)
        #expect(!edges.contains { edge in
            Set([edge.startIndex, edge.endIndex]) == Set([0, 2])
        })
    }

    @Test
    func featureEdgesKeepCubeCreasesWithoutFaceDiagonals() {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: -1, y: -1, z: -1),
                Vec3(x: 1, y: -1, z: -1),
                Vec3(x: 1, y: 1, z: -1),
                Vec3(x: -1, y: 1, z: -1),
                Vec3(x: -1, y: -1, z: 1),
                Vec3(x: 1, y: -1, z: 1),
                Vec3(x: 1, y: 1, z: 1),
                Vec3(x: -1, y: 1, z: 1)
            ],
            triangleIndices: [
                0, 2, 1, 0, 3, 2,
                4, 5, 6, 4, 6, 7,
                0, 1, 5, 0, 5, 4,
                1, 2, 6, 1, 6, 5,
                2, 3, 7, 2, 7, 6,
                3, 0, 4, 3, 4, 7
            ]
        )

        let edges = ViewportMeshRenderData.featureEdges(from: mesh)

        #expect(edges.count == 12)
    }

    @Test
    func featureEdgesHandleTriangleLocalVertexObservationsFromSTL() {
        let mesh = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 1, y: 1, z: 0),
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 1, z: 0),
                Vec3(x: 0, y: 1, z: 0)
            ],
            triangleIndices: [
                0, 1, 2,
                3, 4, 5
            ]
        )

        let edges = ViewportMeshRenderData.featureEdges(from: mesh)

        #expect(edges.count == 4)
        #expect(!edges.contains { edge in
            let a = mesh.vertices[Int(edge.startIndex)]
            let b = mesh.vertices[Int(edge.endIndex)]
            return sameUndirectedEdge(
                a,
                b,
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 1, z: 0)
            )
        })
    }

    @Test
    func sliceSolidRenderDataExtrudesClosedContourPath() throws {
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 10,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 2, y: 0),
                                Vec2(x: 2, y: 1),
                                Vec2(x: 0, y: 1),
                                Vec2(x: 0, y: 0)
                            ],
                            closed: true
                        )
                    ]
                )
            ]
        )

        let mesh = try #require(ViewportSliceSolidRenderData.mesh(contours: contours, layerIndex: 0, materialThickness: 4))

        #expect(mesh.vertices.count == 36)
        #expect(mesh.normals.count == 36)
        #expect(mesh.triangleIndices.count == 36)
        #expect(mesh.vertices.contains(Vec3(x: 0, y: 0, z: 8)))
        #expect(mesh.vertices.contains(Vec3(x: 2, y: 1, z: 12)))
    }

    @Test
    func sliceSolidRenderDataIgnoresOpenContourPath() {
        let contours = StackedSliceContours(
            axis: .z,
            layers: [
                SliceContourLayer(
                    position: 10,
                    paths: [
                        SlicePath2D(
                            points: [
                                Vec2(x: 0, y: 0),
                                Vec2(x: 2, y: 0),
                                Vec2(x: 2, y: 1)
                            ],
                            closed: false
                        )
                    ]
                )
            ]
        )

        #expect(ViewportSliceSolidRenderData.mesh(contours: contours, layerIndex: 0, materialThickness: 4) == nil)
    }

    @Test
    func sliceSolidRenderDataExtrudesCustomScenePathAlongNormal() throws {
        let path = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: 2, y: 0),
                Vec2(x: 2, y: 1),
                Vec2(x: 0, y: 1),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )

        let mesh = try #require(ViewportSliceSolidRenderData.mesh(
            paths: [path],
            materialThickness: 4,
            scenePoint: { Vec3(x: $0.x, y: 10, z: $0.y) },
            normal: Vec3(x: 0, y: 2, z: 0)
        ))

        #expect(mesh.vertices.count == 36)
        #expect(mesh.normals.count == 36)
        #expect(mesh.triangleIndices.count == 36)
        #expect(mesh.vertices.contains(Vec3(x: 0, y: 8, z: 0)))
        #expect(mesh.vertices.contains(Vec3(x: 2, y: 12, z: 1)))
    }

    @Test
    func sliceSolidRenderDataExtrudesTriangularPanelPath() throws {
        let path = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: 4, y: 0),
                Vec2(x: 1, y: 3),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )

        let mesh = try #require(ViewportSliceSolidRenderData.mesh(
            paths: [path],
            materialThickness: 2,
            scenePoint: { Vec3(x: 10 + $0.x, y: 20 + $0.y, z: -5) },
            normal: Vec3(x: 0, y: 0, z: 1)
        ))

        #expect(mesh.vertices.count == 24)
        #expect(mesh.normals.count == 24)
        #expect(mesh.triangleIndices.count == 24)
        #expect(mesh.vertices.contains(Vec3(x: 10, y: 20, z: -6)))
        #expect(mesh.vertices.contains(Vec3(x: 14, y: 20, z: -4)))
        #expect(mesh.vertices.contains(Vec3(x: 11, y: 23, z: -4)))
    }

    @Test
    func sliceSolidRenderDataCutsRectangularSlotsOutOfPanelMesh() throws {
        let outer = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: 10, y: 0),
                Vec2(x: 10, y: 10),
                Vec2(x: 0, y: 10),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let slot = SlicePath2D(
            points: [
                Vec2(x: 4, y: 5),
                Vec2(x: 6, y: 5),
                Vec2(x: 6, y: 10),
                Vec2(x: 4, y: 10),
                Vec2(x: 4, y: 5)
            ],
            closed: true
        )

        let mesh = try #require(ViewportSliceSolidRenderData.meshWithRectangularCutouts(
            outerPaths: [outer],
            cutoutPaths: [slot],
            materialThickness: 2,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        ))

        #expect(mesh.vertices.count > 36)
        #expect(!triangleCenters(mesh).contains { center in
            center.x > 4 && center.x < 6 && center.y > 5 && center.y < 10
        })
    }

    @Test
    func sliceSolidRenderDataCutsAngledNotchSlotsOutOfPanelMesh() throws {
        let outer = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: 10, y: 0),
                Vec2(x: 10, y: 10),
                Vec2(x: 0, y: 10),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let flaredSlot = SlicePath2D(
            points: [
                Vec2(x: 4.5, y: 2),
                Vec2(x: 5.5, y: 2),
                Vec2(x: 7, y: 10),
                Vec2(x: 3, y: 10),
                Vec2(x: 4.5, y: 2)
            ],
            closed: true
        )

        let mesh = try #require(ViewportSliceSolidRenderData.meshWithRectangularCutouts(
            outerPaths: [outer],
            cutoutPaths: [flaredSlot],
            materialThickness: 2,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        ))

        #expect(mesh.vertices.count > 36)
        #expect(!capTriangleCenters(mesh).contains { center in
            contains(Vec2(x: center.x, y: center.y), in: flaredSlot)
        })
        #expect(mesh.vertices.contains { vertex in
            abs(vertex.x - 3) < 1.0e-7 && abs(vertex.y - 10) < 1.0e-7
        })
        #expect(mesh.vertices.contains { vertex in
            abs(vertex.x - 7) < 1.0e-7 && abs(vertex.y - 10) < 1.0e-7
        })
    }

    @Test
    func sliceSolidRenderDataKeepsNestedContourAsHole() throws {
        let outer = SlicePath2D(
            points: [
                Vec2(x: 0, y: 0),
                Vec2(x: 12, y: 0),
                Vec2(x: 12, y: 12),
                Vec2(x: 0, y: 12),
                Vec2(x: 0, y: 0)
            ],
            closed: true
        )
        let inner = SlicePath2D(
            points: [
                Vec2(x: 4, y: 4),
                Vec2(x: 8, y: 4),
                Vec2(x: 8, y: 8),
                Vec2(x: 4, y: 8),
                Vec2(x: 4, y: 4)
            ],
            closed: true
        )

        let mesh = try #require(ViewportSliceSolidRenderData.mesh(
            paths: [outer, inner],
            materialThickness: 2,
            scenePoint: { Vec3(x: $0.x, y: $0.y, z: 0) },
            normal: Vec3(x: 0, y: 0, z: 1)
        ))

        #expect(!capTriangleCenters(mesh).contains { center in
            contains(Vec2(x: center.x, y: center.y), in: inner)
        })
        #expect(mesh.vertices.contains { vertex in
            abs(vertex.x - 4) < 1.0e-7 && vertex.y >= 4 && vertex.y <= 8
        })
    }

    private func sameUndirectedEdge(_ a: Vec3, _ b: Vec3, _ expectedA: Vec3, _ expectedB: Vec3) -> Bool {
        (a == expectedA && b == expectedB) || (a == expectedB && b == expectedA)
    }

    private func triangleCenters(_ mesh: ViewportFlatShadedMesh) -> [Vec3] {
        stride(from: 0, to: mesh.vertices.count - 2, by: 3).map { index in
            Vec3(
                x: (mesh.vertices[index].x + mesh.vertices[index + 1].x + mesh.vertices[index + 2].x) / 3,
                y: (mesh.vertices[index].y + mesh.vertices[index + 1].y + mesh.vertices[index + 2].y) / 3,
                z: (mesh.vertices[index].z + mesh.vertices[index + 1].z + mesh.vertices[index + 2].z) / 3
            )
        }
    }

    private func capTriangleCenters(_ mesh: ViewportFlatShadedMesh) -> [Vec3] {
        stride(from: 0, to: mesh.vertices.count - 2, by: 3).compactMap { index in
            let vertices = [mesh.vertices[index], mesh.vertices[index + 1], mesh.vertices[index + 2]]
            guard vertices.allSatisfy({ abs($0.z - vertices[0].z) < 1.0e-7 }) else {
                return nil
            }
            return Vec3(
                x: vertices.map(\.x).reduce(0, +) / 3,
                y: vertices.map(\.y).reduce(0, +) / 3,
                z: vertices[0].z
            )
        }
    }

    private func contains(_ point: Vec2, in path: SlicePath2D) -> Bool {
        var inside = false
        let points = path.points.dropLast()
        guard points.count >= 3 else {
            return false
        }
        var previous = points[points.index(before: points.endIndex)]
        for current in points {
            if ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x) {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}
