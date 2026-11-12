import Foundation
import Testing
@testable import RefabArtist

/// Unit tests for the ImportUpAxis import-frame mapping (NEO-107).
struct ImportUpAxisTests {

    // MARK: - Geometry re-orientation

    /// A Y-up model has its tallest dimension along the Y axis. After applying
    /// the ImportUpAxis.y mapping, the object-size convention is:
    /// old Y → Height, old Z → Width, old X → Length.
    @Test
    func yUpMappingMatchesObjectSizeAxes() {
        // A bar oriented along Y: vertices span 0…100 in Y, flat in XZ.
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 1, y: 0, z: 0),
                Vec3(x: 0, y: 100, z: 0),
                Vec3(x: 1, y: 100, z: 0)
            ],
            triangleIndices: [0, 1, 2, 1, 3, 2]
        )
        let model = MeshSummary(
            name: "bar.obj",
            path: "/tmp/bar.obj",
            format: "obj",
            byteCount: 0,
            vertexObservationCount: 4,
            faceCount: 2,
            triangleCount: 2,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 1, y: 100, z: 0)),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )

        let rotated = ImportUpAxis.y.orientedModel(model)

        guard let bounds = rotated.bounds else {
            Issue.record("rotated model has no bounds")
            return
        }
        let width  = bounds.max.x - bounds.min.x
        let depth  = bounds.max.y - bounds.min.y
        let height = bounds.max.z - bounds.min.z

        #expect(height > 50, "height (\(height)) should be the tall dimension after Y-up rotation")
        #expect(depth < 10,  "depth (\(depth)) should collapse after Y-up rotation")
        #expect(width  < 10, "width (\(width)) should remain narrow")
    }

    /// A Y-up hand scan with raw spans X=92.7631, Y=145.2528, Z=98.1272 maps
    /// to Length, Height, Width respectively.
    @Test
    func yUpMappingPreservesHandStandDimensionOrder() {
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 92.7631, y: 145.2528, z: 98.1272),
                Vec3(x: 0, y: 145.2528, z: 0)
            ],
            triangleIndices: [0, 1, 2]
        )
        let model = MeshSummary(
            name: "handStand3.stl",
            path: "/fixtures/handStand3.stl",
            format: "stl-ascii",
            byteCount: 0,
            vertexObservationCount: 3,
            faceCount: 1,
            triangleCount: 1,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 92.7631, y: 145.2528, z: 98.1272)),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )

        let dimensions = MeshScaler.dimensions(for: ImportUpAxis.y.orientedModel(model).bounds)

        #expect(dimensions?.height == 145.2528)
        #expect(dimensions?.width == 98.1272)
        #expect(dimensions?.depth == 92.7631)
    }

    /// An X-up model has its tallest dimension along X. After the X-up
    /// mapping the tallest dimension must be along Z.
    @Test
    func xUpMappingBringsXAxisIntoZ() {
        // A bar oriented along X: vertices span 0…100 in X, flat in YZ.
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 100, y: 0, z: 0),
                Vec3(x: 0, y: 1, z: 0),
                Vec3(x: 100, y: 1, z: 0)
            ],
            triangleIndices: [0, 1, 2, 1, 3, 2]
        )
        let model = MeshSummary(
            name: "bar.obj",
            path: "/tmp/bar.obj",
            format: "obj",
            byteCount: 0,
            vertexObservationCount: 4,
            faceCount: 2,
            triangleCount: 2,
            bounds: Bounds3D(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 100, y: 1, z: 0)),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )

        let rotated = ImportUpAxis.x.orientedModel(model)

        guard let bounds = rotated.bounds else {
            Issue.record("rotated model has no bounds")
            return
        }
        let width  = bounds.max.x - bounds.min.x
        let depth  = bounds.max.y - bounds.min.y
        let height = bounds.max.z - bounds.min.z

        // The 100-unit span must now be along Z (height), not X (width).
        #expect(height > 50, "height (\(height)) should be the tall dimension after X-up rotation")
        #expect(width  < 10, "width (\(width)) should collapse after X-up rotation")
        #expect(depth  < 10, "depth (\(depth)) should remain narrow")
    }

    // MARK: - Label and identity

    @Test
    func labelsAreHumanReadable() {
        #expect(ImportUpAxis.y.label == "Y")
        #expect(ImportUpAxis.z.label == "Z")
        #expect(ImportUpAxis.x.label == "X")
    }

    @Test
    func allCasesUseYZXImportOrderAndHaveUniqueIds() {
        #expect(ImportUpAxis.allCases == [.y, .z, .x])
        let ids = ImportUpAxis.allCases.map(\.id)
        #expect(Set(ids).count == ImportUpAxis.allCases.count)
    }
}
