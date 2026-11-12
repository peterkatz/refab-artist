import XCTest
@testable import RefabArtist

final class DensityFieldTests: XCTestCase {
    func testLinearDensityRampProducesKnownAnswerLineCount() throws {
        let field = DensityField.linearDensityRamp(
            axis: .x,
            lo: 0,
            hi: 200,
            startDensity: 1.0 / 10.0,
            endDensity: 1.0 / 20.0
        )

        let positions = VariableSpacing.linePositions(
            field: field,
            axis: .x,
            lo: 0,
            hi: 200
        ) { x in
            SIMD3<Double>(x, 0, 0)
        }

        XCTAssertEqual(positions.count, 15)
        XCTAssertEqual(try XCTUnwrap(positions.last), 200, accuracy: 1.0e-6)
    }

    func testLinearDensityRampEndSpacingRatioIsTwo() {
        let field = DensityField.linearDensityRamp(
            axis: .x,
            lo: 0,
            hi: 200,
            startDensity: 1.0 / 10.0,
            endDensity: 1.0 / 20.0
        )

        let startCell = field.cellSize(at: SIMD3<Double>(0, 0, 0))
        let endCell = field.cellSize(at: SIMD3<Double>(200, 0, 0))

        XCTAssertEqual(endCell / startCell, 2.0, accuracy: 0.05 * 2.0)
    }

    func testUniformVariableSpacingMatchesCellSize() {
        let field = DensityField.uniform(cellSizeMm: 10)
        let positions = VariableSpacing.linePositions(
            field: field,
            axis: .x,
            lo: 0,
            hi: 50
        ) { x in
            SIMD3<Double>(x, 0, 0)
        }

        XCTAssertEqual(positions.count, 5)
        for (actual, expected) in zip(positions, [10.0, 20.0, 30.0, 40.0, 50.0]) {
            XCTAssertEqual(actual, expected, accuracy: 1.0e-9)
        }
    }

    func testAttractorDensityUsesMinCellAtAttractorAndMaxOutsideFalloff() {
        let field = DensityField.attractor(
            point: Vec3(x: 0, y: 0, z: 0),
            falloffMm: 20,
            minCellMm: 5,
            maxCellMm: 15
        )

        XCTAssertEqual(field.cellSize(at: SIMD3<Double>(0, 0, 0)), 5, accuracy: 1.0e-9)
        XCTAssertEqual(field.cellSize(at: SIMD3<Double>(40, 0, 0)), 15, accuracy: 1.0e-9)
        XCTAssertLessThan(field.cellSize(at: SIMD3<Double>(10, 0, 0)), 15)
        XCTAssertGreaterThan(field.cellSize(at: SIMD3<Double>(10, 0, 0)), 5)
    }

    func testNearSurfaceDensityUsesSourceVertexDistanceBand() {
        let field = DensityField.nearSurface(
            sourceVertices: [Vec3(x: 0, y: 0, z: 0)],
            bandMm: 10,
            minCellMm: 4,
            maxCellMm: 12
        )

        XCTAssertEqual(field.cellSize(at: SIMD3<Double>(0, 0, 0)), 4, accuracy: 1.0e-9)
        XCTAssertEqual(field.cellSize(at: SIMD3<Double>(20, 0, 0)), 12, accuracy: 1.0e-9)
        XCTAssertLessThan(field.cellSize(at: SIMD3<Double>(5, 0, 0)), 12)
        XCTAssertGreaterThan(field.cellSize(at: SIMD3<Double>(5, 0, 0)), 4)
    }

    func testDensitySourcesAreEngineBacked() {
        XCTAssertTrue(StructureDensitySource.attractors.isEngineBacked)
        XCTAssertTrue(StructureDensitySource.nearSurface.isEngineBacked)
    }
}
