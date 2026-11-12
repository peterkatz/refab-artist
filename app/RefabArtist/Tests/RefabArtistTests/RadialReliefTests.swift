import Foundation
import Testing
@testable import RefabArtist

// MARK: - NEO-106 Radial Relief Type parity tests

struct RadialReliefTypeTests {

    // MARK: - Enum cases and labels

    @Test
    func fourCasesExist() {
        let cases = RadialReliefType.allCases
        #expect(cases.count == 4)
        #expect(cases.contains(.square))
        #expect(cases.contains(.horizontal))
        #expect(cases.contains(.vertical))
        #expect(cases.contains(.dogBone))
    }

    @Test
    func labelsMatchMenuText() {
        #expect(RadialReliefType.square.label   == "Square")
        #expect(RadialReliefType.horizontal.label == "Horizontal")
        #expect(RadialReliefType.vertical.label   == "Vertical")
        #expect(RadialReliefType.dogBone.label    == "Dog Bone")
    }

    @Test
    func squareIsDefault() {
        // The plan's stored default must be .square so existing projects that
        // lack a radialReliefType key decode to no-op (byte-stable).
        let plan = RadialSlicePlan(center: Vec3(x: 0, y: 0, z: 0), radius: 10, angles: [])
        #expect(plan.reliefType == .square)
    }

    @Test
    func onlySquareDoesNotRequireToolDiameter() {
        #expect(!RadialReliefType.square.requiresToolDiameter)
        #expect(RadialReliefType.horizontal.requiresToolDiameter)
        #expect(RadialReliefType.vertical.requiresToolDiameter)
        #expect(RadialReliefType.dogBone.requiresToolDiameter)
    }

    @Test
    func legacyRawValueHorizontalDecodesCorrectly() throws {
        // Legacy saved projects stored "horizontal"; after adding .square as
        // the new default the raw value must still decode.
        let raw = "horizontal"
        let decoded = RadialReliefType(rawValue: raw)
        #expect(decoded == .horizontal)
    }

    // MARK: - RadialSlicePlan toolDiameter

    @Test
    func plannerPreservesToolDiameter() {
        // RadialSlicePlanner.plan passes toolDiameter through to the plan.
        // Use a trivial model summary with a 10mm cube so the planner succeeds.
        let bounds = Bounds3D(
            min: Vec3(x: -5, y: -5, z: -5),
            max: Vec3(x:  5, y:  5, z:  5)
        )
        let geometry = MeshGeometryData(vertices: [], triangleIndices: [])
        let preflight = MeshPreflightReport(
            uniqueVertexCount: 0, duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 0, degenerateTriangleCount: 0,
            boundaryEdgeCount: 0, nonManifoldEdgeCount: 0
        )
        let model = MeshSummary(
            name: "cube", path: "", format: "stl",
            byteCount: 0, vertexObservationCount: 0,
            faceCount: 0, triangleCount: 0, bounds: bounds,
            geometry: geometry, preflight: preflight
        )
        let plan = RadialSlicePlanner.plan(
            model: model,
            nRadial: 4,
            materialThickness: 5.0,
            toolDiameter: 3.175
        )
        #expect(plan != nil)
        if let plan {
            #expect(abs(plan.toolDiameter - 3.175) < 1e-9)
        }
    }

    @Test
    func plannerZeroToolDiameterIsPreserved() {
        let bounds = Bounds3D(
            min: Vec3(x: -5, y: -5, z: -5),
            max: Vec3(x:  5, y:  5, z:  5)
        )
        let geometry = MeshGeometryData(vertices: [], triangleIndices: [])
        let preflight = MeshPreflightReport(
            uniqueVertexCount: 0, duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 0, degenerateTriangleCount: 0,
            boundaryEdgeCount: 0, nonManifoldEdgeCount: 0
        )
        let model = MeshSummary(
            name: "cube", path: "", format: "stl",
            byteCount: 0, vertexObservationCount: 0,
            faceCount: 0, triangleCount: 0, bounds: bounds,
            geometry: geometry, preflight: preflight
        )
        let plan = RadialSlicePlanner.plan(
            model: model,
            nRadial: 4,
            materialThickness: 5.0,
            toolDiameter: 0.0
        )
        #expect(plan?.toolDiameter == 0.0)
    }
}
