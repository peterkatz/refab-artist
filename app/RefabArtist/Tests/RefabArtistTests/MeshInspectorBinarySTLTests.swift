import Foundation
import Testing
@testable import RefabArtist

struct MeshInspectorBinarySTLTests {
    @Test
    func binarySTLImportReportsGeometryBoundsAndPreflight() throws {
        let url = try Self.writeTemporarySTL(data: Self.binaryTriangleSTL())
        defer { try? FileManager.default.removeItem(at: url) }

        let model = try MeshInspector.inspect(url: url)

        #expect(model.format == "stl-binary")
        #expect(model.byteCount == 134)
        #expect(model.vertexObservationCount == 3)
        #expect(model.faceCount == 1)
        #expect(model.triangleCount == 1)
        #expect(model.bounds?.min == Vec3(x: 0, y: 0, z: 0))
        #expect(model.bounds?.max == Vec3(x: 10, y: 10, z: 0))
        #expect(model.geometry.vertices.count == 3)
        #expect(model.geometry.triangleIndices == [0, 1, 2])
        #expect(model.preflight.degenerateTriangleCount == 0)
        #expect(model.preflight.boundaryEdgeCount == 3)
    }

    @Test
    func truncatedBinarySTLThrowsInvalidBinarySTL() throws {
        var data = Self.binaryTriangleSTL()
        data.removeLast(8)
        let url = try Self.writeTemporarySTL(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try MeshInspector.inspect(url: url)
            Issue.record("Expected truncated binary STL to fail")
        } catch MeshInspectorError.invalidBinarySTL {
        }
    }

    @Test
    func binarySTLWithTrailingBytesThrowsInvalidBinarySTL() throws {
        var data = Self.binaryTriangleSTL()
        data.append(contentsOf: [0, 1, 2, 3])
        let url = try Self.writeTemporarySTL(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try MeshInspector.inspect(url: url)
            Issue.record("Expected binary STL with trailing bytes to fail")
        } catch MeshInspectorError.invalidBinarySTL {
        }
    }

    private static func binaryTriangleSTL() -> Data {
        var data = Data(repeating: 0, count: 80)
        append(UInt32(1), to: &data)
        append(Float32(0), to: &data)
        append(Float32(0), to: &data)
        append(Float32(1), to: &data)
        appendVertex(x: 0, y: 0, z: 0, to: &data)
        appendVertex(x: 10, y: 0, z: 0, to: &data)
        appendVertex(x: 0, y: 10, z: 0, to: &data)
        append(UInt16(0), to: &data)
        return data
    }

    private static func appendVertex(x: Float32, y: Float32, z: Float32, to data: inout Data) {
        append(x, to: &data)
        append(y, to: &data)
        append(z, to: &data)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: Float32, to data: inout Data) {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func writeTemporarySTL(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slicer-rebuild-binary-stl-\(UUID().uuidString).stl")
        try data.write(to: url)
        return url
    }
}
