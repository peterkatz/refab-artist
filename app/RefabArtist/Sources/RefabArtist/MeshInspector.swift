import Foundation

struct Vec3: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    var display: String {
        "\(Self.format(x)), \(Self.format(y)), \(Self.format(z))"
    }

    static func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}

struct Bounds3D: Equatable {
    var min: Vec3
    var max: Vec3
}

struct MeshGeometryData: Codable, Equatable {
    var vertices: [Vec3]
    var triangleIndices: [Int32]
}

struct MeshSummary: Equatable {
    var name: String
    var path: String
    var format: String
    var byteCount: Int
    var vertexObservationCount: Int
    var faceCount: Int
    var triangleCount: Int
    var bounds: Bounds3D?
    var geometry: MeshGeometryData
    var preflight: MeshPreflightReport
}

enum MeshInspectorError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableFile
    case invalidBinarySTL

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported mesh format: \(ext)"
        case .unreadableFile:
            return "The selected file could not be read."
        case .invalidBinarySTL:
            return "The binary STL file is malformed."
        }
    }
}

enum MeshInspector {
    static func inspect(url: URL) throws -> MeshSummary {
        guard url.startAccessingSecurityScopedResource() else {
            return try inspectUnlocked(url: url)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try inspectUnlocked(url: url)
    }

    private static func inspectUnlocked(url: URL) throws -> MeshSummary {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "obj":
            return inspectOBJ(url: url, data: data)
        case "stl":
            return try inspectSTL(url: url, data: data)
        default:
            throw MeshInspectorError.unsupportedFormat(ext.isEmpty ? "none" : ext)
        }
    }

    private static func inspectOBJ(url: URL, data: Data) -> MeshSummary {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var vertices: [Vec3] = []
        var triangleIndices: [Int32] = []
        var faceCount = 0
        var bounds = BoundsAccumulator()

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let tag = parts.first else { continue }
            if tag == "v", parts.count >= 4,
               let x = Double(parts[1]),
               let y = Double(parts[2]),
               let z = Double(parts[3]) {
                let vertex = Vec3(x: x, y: y, z: z)
                vertices.append(vertex)
                bounds.include(vertex)
            } else if tag == "f" {
                faceCount += 1
                let face = parts.dropFirst().compactMap { parseOBJIndex($0, vertexCount: vertices.count) }
                if face.count >= 3 {
                    for index in 1..<(face.count - 1) {
                        triangleIndices.append(Int32(face[0]))
                        triangleIndices.append(Int32(face[index]))
                        triangleIndices.append(Int32(face[index + 1]))
                    }
                }
            }
        }

        let rawGeometry = MeshGeometryData(vertices: vertices, triangleIndices: triangleIndices)
        return summary(
            name: url.lastPathComponent,
            path: url.path,
            format: "obj",
            byteCount: data.count,
            vertexObservationCount: vertices.count,
            faceCount: faceCount,
            rawGeometry: rawGeometry,
            rawBounds: bounds.value
        )
    }

    private static func parseOBJIndex(_ token: Substring, vertexCount: Int) -> Int? {
        guard let raw = token.split(separator: "/").first, let index = Int(raw) else {
            return nil
        }
        if index > 0 {
            return index - 1
        }
        if index < 0 {
            return vertexCount + index
        }
        return nil
    }

    private static func inspectSTL(url: URL, data: Data) throws -> MeshSummary {
        if let text = String(data: data, encoding: .utf8), text.lowercased().hasPrefix("solid"), text.contains("vertex") {
            return inspectASCIISTL(url: url, text: text, byteCount: data.count)
        }
        return try inspectBinarySTL(url: url, data: data)
    }

    private static func inspectASCIISTL(url: URL, text: String, byteCount: Int) -> MeshSummary {
        var vertexCount = 0
        var triangleCount = 0
        var bounds = BoundsAccumulator()
        var vertices: [Vec3] = []
        var triangleIndices: [Int32] = []

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let tag = parts.first else { continue }
            if tag == "facet" {
                triangleCount += 1
            } else if tag == "vertex", parts.count >= 4,
                      let x = Double(parts[1]),
                      let y = Double(parts[2]),
                      let z = Double(parts[3]) {
                vertexCount += 1
                let vertex = Vec3(x: x, y: y, z: z)
                vertices.append(vertex)
                triangleIndices.append(Int32(vertices.count - 1))
                bounds.include(vertex)
            }
        }

        let rawGeometry = MeshGeometryData(vertices: vertices, triangleIndices: triangleIndices)
        return summary(
            name: url.lastPathComponent,
            path: url.path,
            format: "stl-ascii",
            byteCount: byteCount,
            vertexObservationCount: vertexCount,
            faceCount: triangleCount,
            rawGeometry: rawGeometry,
            rawBounds: bounds.value
        )
    }

    private static func inspectBinarySTL(url: URL, data: Data) throws -> MeshSummary {
        guard data.count >= 84 else { throw MeshInspectorError.invalidBinarySTL }
        let triangleCount = Int(data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian
        })
        let expectedSize = 84 + triangleCount * 50
        guard data.count == expectedSize else { throw MeshInspectorError.invalidBinarySTL }

        var bounds = BoundsAccumulator()
        var vertices: [Vec3] = []
        var triangleIndices: [Int32] = []
        var vertexCount = 0
        data.withUnsafeBytes { raw in
            for triangle in 0..<triangleCount {
                let record = 84 + triangle * 50
                for vertex in 0..<3 {
                    let offset = record + 12 + vertex * 12
                    let x = Double(raw.loadUnaligned(fromByteOffset: offset, as: Float32.self))
                    let y = Double(raw.loadUnaligned(fromByteOffset: offset + 4, as: Float32.self))
                    let z = Double(raw.loadUnaligned(fromByteOffset: offset + 8, as: Float32.self))
                    let point = Vec3(x: x, y: y, z: z)
                    vertexCount += 1
                    vertices.append(point)
                    triangleIndices.append(Int32(vertices.count - 1))
                    bounds.include(point)
                }
            }
        }

        let rawGeometry = MeshGeometryData(vertices: vertices, triangleIndices: triangleIndices)
        return summary(
            name: url.lastPathComponent,
            path: url.path,
            format: "stl-binary",
            byteCount: data.count,
            vertexObservationCount: vertexCount,
            faceCount: triangleCount,
            rawGeometry: rawGeometry,
            rawBounds: bounds.value
        )
    }

    /// Shared post-parse finalizer for every importer. Runs the make-manifold
    /// repair on the parsed geometry, then derives `bounds`, `geometry`, and
    /// `preflight` from the REPAIRED mesh so all three reflect the real solid.
    /// When the repair is a no-op (no winged sliver to strip — the case for
    /// every well-formed mesh) the geometry and bounds are byte-for-byte the
    /// originally parsed values, so unaffected fixtures are untouched.
    private static func summary(
        name: String,
        path: String,
        format: String,
        byteCount: Int,
        vertexObservationCount: Int,
        faceCount: Int,
        rawGeometry: MeshGeometryData,
        rawBounds: Bounds3D?
    ) -> MeshSummary {
        let geometry = MeshManifoldRepair.repaired(rawGeometry)
        let repaired = geometry != rawGeometry
        let bounds = repaired ? boundsOf(geometry) : rawBounds
        return MeshSummary(
            name: name,
            path: path,
            format: format,
            byteCount: byteCount,
            vertexObservationCount: vertexObservationCount,
            faceCount: faceCount,
            triangleCount: geometry.triangleIndices.count / 3,
            bounds: bounds,
            geometry: geometry,
            preflight: MeshPreflight.analyze(geometry: geometry)
        )
    }

    /// Recompute the axis-aligned bounding box from the vertices actually
    /// referenced by the (repaired) triangles, so a stripped sliver's dangling
    /// tip no longer inflates the box.
    private static func boundsOf(_ geometry: MeshGeometryData) -> Bounds3D? {
        var accumulator = BoundsAccumulator()
        for index in geometry.triangleIndices {
            let i = Int(index)
            guard geometry.vertices.indices.contains(i) else { continue }
            accumulator.include(geometry.vertices[i])
        }
        return accumulator.value
    }
}

private struct BoundsAccumulator {
    private(set) var value: Bounds3D?

    mutating func include(_ point: Vec3) {
        guard var current = value else {
            value = Bounds3D(min: point, max: point)
            return
        }
        current.min.x = min(current.min.x, point.x)
        current.min.y = min(current.min.y, point.y)
        current.min.z = min(current.min.z, point.z)
        current.max.x = max(current.max.x, point.x)
        current.max.y = max(current.max.y, point.y)
        current.max.z = max(current.max.z, point.z)
        value = current
    }
}
