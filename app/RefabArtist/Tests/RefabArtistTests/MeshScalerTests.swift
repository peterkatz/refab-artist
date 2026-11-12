import Foundation
import Testing
@testable import RefabArtist

struct MeshScalerTests {
    @Test
    func scalingUpdatesGeometryAndBoundsWithoutChangingTopologyCounts() {
        let model = Self.model()

        let scaled = MeshScaler.scaled(model, factor: 2.5)

        #expect(scaled.name == model.name)
        #expect(scaled.path == model.path)
        #expect(scaled.format == model.format)
        #expect(scaled.vertexObservationCount == model.vertexObservationCount)
        #expect(scaled.faceCount == model.faceCount)
        #expect(scaled.triangleCount == model.triangleCount)
        #expect(scaled.geometry.triangleIndices == model.geometry.triangleIndices)
        #expect(scaled.geometry.vertices[1] == Vec3(x: 25, y: 0, z: 0))
        #expect(scaled.geometry.vertices[2] == Vec3(x: 0, y: -12.5, z: 5))
        #expect(scaled.bounds?.min == Vec3(x: 0, y: -12.5, z: 0))
        #expect(scaled.bounds?.max == Vec3(x: 25, y: 0, z: 5))
    }

    @Test
    func identityScaleReturnsEquivalentModel() {
        let model = Self.model()

        let scaled = MeshScaler.scaled(model, factor: 1.0)

        #expect(scaled == model)
    }

    @Test
    func invalidScaleFactorsAreClamped() {
        #expect(MeshScaler.sanitizedFactor(.nan) == 1.0)
        #expect(MeshScaler.sanitizedFactor(0.0) == 0.01)
        #expect(MeshScaler.sanitizedFactor(-4.0) == 0.01)
        #expect(MeshScaler.sanitizedFactor(200.0) == 100.0)
    }

    @Test
    func unitPresetsExposeMillimeterScaleFactors() {
        #expect(ImportUnitPreset.millimeters.millimetersPerUnit == 1.0)
        #expect(ImportUnitPreset.centimeters.millimetersPerUnit == 10.0)
        #expect(ImportUnitPreset.meters.millimetersPerUnit == 1_000.0)
        #expect(ImportUnitPreset.inches.millimetersPerUnit == 25.4)
    }

    @Test
    func combinedFactorAppliesImportUnitsAndUserScale() {
        #expect(MeshScaler.combinedFactor(unit: .millimeters, userScale: 2.0) == 2.0)
        #expect(MeshScaler.combinedFactor(unit: .centimeters, userScale: 2.0) == 20.0)
        #expect(MeshScaler.combinedFactor(unit: .inches, userScale: 0.5) == 12.7)
        // The unit conversion applies in FULL — only the user scale clamps.
        // (The old assertion of 100.0 codified the clamp bug that imported
        // meter-authored models at a tenth of their size.)
        #expect(MeshScaler.combinedFactor(unit: .meters, userScale: 2.0) == 2_000.0)
        #expect(MeshScaler.combinedFactor(unit: .meters, userScale: 1_000.0) == 100_000.0)
        #expect(MeshScaler.combinedFactor(unit: .millimeters, userScale: 0.0001) == MeshScaler.minimumFactor)
    }

    @Test
    func dimensionsAreDerivedFromBounds() {
        let dimensions = MeshScaler.dimensions(for: Self.model().bounds)

        #expect(dimensions == MeshDimensions(width: 10, depth: 5, height: 2))
        #expect(MeshScaler.dimensions(for: nil) == nil)
    }

    @Test
    func targetDimensionAdjustsUniformScaleFromCurrentDimension() {
        #expect(MeshScaler.factorByResizing(currentFactor: 1.0, currentDimension: 20.0, targetDimension: 50.0) == 2.5)
        #expect(MeshScaler.factorByResizing(currentFactor: 2.0, currentDimension: 20.0, targetDimension: 10.0) == 1.0)
        #expect(MeshScaler.factorByResizing(currentFactor: 1.0, currentDimension: 0.0, targetDimension: 50.0) == 1.0)
        #expect(MeshScaler.factorByResizing(currentFactor: 1.0, currentDimension: 20.0, targetDimension: -10.0) == 1.0)
        #expect(MeshScaler.factorByResizing(currentFactor: 90.0, currentDimension: 10.0, targetDimension: 20.0) == 100.0)
    }

    @Test
    func scaledModelChangesSlicePlanRange() {
        let model = Self.model()

        let originalPlan = StackedSlicePlanner.plan(model: model, axis: .x, materialThickness: 5.0)
        let scaledPlan = StackedSlicePlanner.plan(model: MeshScaler.scaled(model, factor: 2.0), axis: .x, materialThickness: 5.0)

        #expect(originalPlan?.rangeMax == 10)
        #expect(originalPlan?.sliceCount == 2)
        #expect(scaledPlan?.rangeMax == 20)
        #expect(scaledPlan?.sliceCount == 4)
    }

    @Test
    func targetWidthScaleChangesSlicePlanRange() {
        let model = Self.model()
        let currentWidth = MeshScaler.dimensions(for: model.bounds)?.width ?? 0
        let scale = MeshScaler.factorByResizing(currentFactor: 1.0, currentDimension: currentWidth, targetDimension: 25.0)

        let plan = StackedSlicePlanner.plan(model: MeshScaler.scaled(model, factor: scale), axis: .x, materialThickness: 5.0)

        #expect(scale == 2.5)
        #expect(plan?.rangeMax == 25)
        #expect(plan?.sliceCount == 5)
    }

    @Test
    func importUnitScaleChangesSlicePlanRange() {
        let model = Self.model()
        let scale = MeshScaler.combinedFactor(unit: .centimeters, userScale: 1.0)

        let plan = StackedSlicePlanner.plan(model: MeshScaler.scaled(model, factor: scale), axis: .x, materialThickness: 5.0)

        #expect(scale == 10)
        #expect(plan?.rangeMax == 100)
        #expect(plan?.sliceCount == 20)
    }

    /// `unrotating` takes every vertex of the turned model back to where it
    /// sits in the model, for a turn about each axis and all three at once,
    /// and is the identity with no turn.
    @Test(arguments: [
        Vec3(x: 20, y: 10, z: 0),
        Vec3(x: 0, y: 35, z: 0),
        Vec3(x: 0, y: 0, z: -50),
        Vec3(x: 15, y: -25, z: 40)
    ])
    func unrotatingTakesTheTurnedModelBack(_ rotation: Vec3) {
        let model = Self.model()
        let turned = MeshScaler.transformed(model, scale: Vec3(x: 1, y: 1, z: 1), rotationDegrees: rotation)
        let back = MeshScaler.unrotating(model, rotationDegrees: rotation)
        for (original, moved) in zip(model.geometry.vertices, turned.geometry.vertices) {
            let point = back(moved)
            let error = abs(point.x - original.x) + abs(point.y - original.y) + abs(point.z - original.z)
            #expect(error < 1.0e-9, "\(rotation): \(original) came back as \(point)")
        }
        // The turn moves the model, so going back is not the identity.
        #expect(zip(model.geometry.vertices, turned.geometry.vertices).contains { $0 != $1 })
        let none = MeshScaler.unrotating(model, rotationDegrees: Vec3(x: 0, y: 0, z: 0))
        #expect(model.geometry.vertices.allSatisfy { none($0) == $0 })
    }

    private static func model() -> MeshSummary {
        let geometry = MeshGeometryData(
            vertices: [
                Vec3(x: 0, y: 0, z: 0),
                Vec3(x: 10, y: 0, z: 0),
                Vec3(x: 0, y: -5, z: 2)
            ],
            triangleIndices: [0, 1, 2]
        )
        return MeshSummary(
            name: "triangle.obj",
            path: "/tmp/triangle.obj",
            format: "obj",
            byteCount: 42,
            vertexObservationCount: 3,
            faceCount: 1,
            triangleCount: 1,
            bounds: Bounds3D(min: Vec3(x: 0, y: -5, z: 0), max: Vec3(x: 10, y: 0, z: 2)),
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }
}
