import Foundation

struct SourceFaceID: RawRepresentable, Codable, Equatable, Hashable, Comparable, Identifiable {
    let rawValue: Int

    var id: Int { rawValue }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: SourceFaceID, rhs: SourceFaceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PartitionCutSide: String, Codable, Equatable, Hashable {
    case negative
    case positive
}

enum PartitionTriangleProvenance: Codable, Equatable, Hashable {
    case source(SourceFaceID)
    case cut(nodeID: PartitionCutNodeID, side: PartitionCutSide)
    case joinery(seamID: String, featureID: String)
}

struct AttributedTriangle: Codable, Equatable {
    var a: Vec3
    var b: Vec3
    var c: Vec3
    var provenance: PartitionTriangleProvenance

    var area: Double {
        let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
        let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: c.z - a.z)
        let cross = Vec3(
            x: ab.y * ac.z - ab.z * ac.y,
            y: ab.z * ac.x - ab.x * ac.z,
            z: ab.x * ac.y - ab.y * ac.x
        )
        return 0.5 * sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
    }
}

struct AttributedMesh: Codable, Equatable {
    var triangles: [AttributedTriangle]
    /// Identity of the effective source before any scoped cuts. Every child
    /// inherits it; it is never recomputed from a clipped leaf.
    var sourceGeometryFingerprint: String
    /// Referenced vertices from the effective source, retained so replay can
    /// distinguish a real source-vertex grazing plane from vertices created by
    /// an earlier scoped clip.
    var sourceReferencedVertices: [Vec3]
    /// Zero-area source records omitted from solid operations. Their original
    /// face IDs remain available for honest diagnostics and reporting.
    var omittedDegenerateSourceFaceIDs: [SourceFaceID]

    var geometry: MeshGeometryData {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        vertices.reserveCapacity(triangles.count * 3)
        indices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            for vertex in [triangle.a, triangle.b, triangle.c] {
                indices.append(Int32(vertices.count))
                vertices.append(vertex)
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    /// Provenance is non-optional by construction; this also rejects an
    /// accidentally introduced non-finite triangle before it can masquerade as
    /// an attributed output.
    var hasCompleteProvenance: Bool {
        triangles.allSatisfy { triangle in
            [triangle.a, triangle.b, triangle.c].allSatisfy {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            }
        }
    }

    /// The clipping and preflight paths quantize positions onto a 1e-6 mm
    /// Int64 grid. Reject values outside that representable contract before
    /// either path can perform a trapping floating-point-to-integer conversion.
    var hasSupportedCoordinates: Bool {
        triangles.allSatisfy { triangle in
            [triangle.a, triangle.b, triangle.c].allSatisfy(
                SourceFaceMap.isSupportedCoordinate
            )
        } && sourceReferencedVertices.allSatisfy(SourceFaceMap.isSupportedCoordinate)
    }

    var signedVolume: Double {
        triangles.reduce(0) { volume, triangle in
            let a = triangle.a, b = triangle.b, c = triangle.c
            return volume + (
                a.x * (b.y * c.z - b.z * c.y)
                - a.y * (b.x * c.z - b.z * c.x)
                + a.z * (b.x * c.y - b.y * c.x)
            ) / 6
        }
    }

    var stableFingerprint: String {
        var hasher = PartitionStableHasher()
        hasher.append("attributed-mesh-v1")
        hasher.append(triangles.count)
        for triangle in triangles {
            hasher.append(triangle.a)
            hasher.append(triangle.b)
            hasher.append(triangle.c)
            hasher.append(triangle.provenance.stableDescription)
        }
        return hasher.finalized
    }

    /// Deterministic geometry-only identity used to reject replay against a
    /// different source. This is deliberately a lightweight project identity,
    /// not certificate or package-hash infrastructure.
    var geometryFingerprint: String {
        sourceGeometryFingerprint
    }

    func surfaceArea(where includes: (PartitionTriangleProvenance) -> Bool = { _ in true }) -> Double {
        triangles.reduce(0) { area, triangle in
            area + (includes(triangle.provenance) ? triangle.area : 0)
        }
    }

    var sourceFaceIDs: Set<SourceFaceID> {
        Set(triangles.compactMap { triangle in
            if case .source(let faceID) = triangle.provenance { return faceID }
            return nil
        })
    }
}

enum SourceFaceMapError: LocalizedError, Equatable {
    case incompleteTriangleIndices
    case indexOutOfBounds(triangle: Int, index: Int32)
    case nonFiniteVertex(triangle: Int)
    case coordinateOutsideSupportedRange(triangle: Int, maximumMagnitudeMM: Double)

    var errorDescription: String? {
        switch self {
        case .incompleteTriangleIndices:
            return "The mesh index buffer does not contain complete triangles."
        case .indexOutOfBounds(let triangle, let index):
            return "Source triangle \(triangle) references missing vertex index \(index)."
        case .nonFiniteVertex(let triangle):
            return "Source triangle \(triangle) contains a non-finite vertex."
        case .coordinateOutsideSupportedRange(let triangle, let maximumMagnitudeMM):
            return "Source triangle \(triangle) exceeds the supported coordinate magnitude of \(Vec3.format(maximumMagnitudeMM)) mm."
        }
    }
}

/// Assigns one durable source-face identity to each input triangle. Clipping a
/// triangle one-to-many keeps the same ID on every fragment; cap and joinery
/// triangles use their own provenance cases instead.
struct SourceFaceMap: Codable, Equatable {
    /// 1e12 / 1e-6 = 1e18, leaving more than 9x headroom below Int64.max.
    static let maximumSupportedCoordinateMagnitudeMM = 1.0e12

    var faceIDsByTriangle: [SourceFaceID]

    init(triangleCount: Int) {
        faceIDsByTriangle = (0..<max(0, triangleCount)).map(SourceFaceID.init(rawValue:))
    }

    static func attributedMesh(from geometry: MeshGeometryData) throws -> AttributedMesh {
        guard geometry.triangleIndices.count.isMultiple(of: 3) else {
            throw SourceFaceMapError.incompleteTriangleIndices
        }
        let map = SourceFaceMap(triangleCount: geometry.triangleIndices.count / 3)
        var triangles: [AttributedTriangle] = []
        triangles.reserveCapacity(map.faceIDsByTriangle.count)
        var omittedDegenerateSourceFaceIDs: [SourceFaceID] = []

        for triangleIndex in map.faceIDsByTriangle.indices {
            let base = triangleIndex * 3
            let rawIndices = Array(geometry.triangleIndices[base..<(base + 3)])
            var vertices: [Vec3] = []
            vertices.reserveCapacity(3)
            for rawIndex in rawIndices {
                let index = Int(rawIndex)
                guard geometry.vertices.indices.contains(index) else {
                    throw SourceFaceMapError.indexOutOfBounds(
                        triangle: triangleIndex,
                        index: rawIndex
                    )
                }
                vertices.append(geometry.vertices[index])
            }
            guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                throw SourceFaceMapError.nonFiniteVertex(triangle: triangleIndex)
            }
            guard vertices.allSatisfy(isSupportedCoordinate) else {
                throw SourceFaceMapError.coordinateOutsideSupportedRange(
                    triangle: triangleIndex,
                    maximumMagnitudeMM: maximumSupportedCoordinateMagnitudeMM
                )
            }
            let triangle = AttributedTriangle(
                a: vertices[0],
                b: vertices[1],
                c: vertices[2],
                provenance: .source(map.faceIDsByTriangle[triangleIndex])
            )
            if triangle.area <= UndercutSplitTolerancePolicy.current.minimumTriangleAreaMM2 {
                omittedDegenerateSourceFaceIDs.append(map.faceIDsByTriangle[triangleIndex])
            } else {
                triangles.append(triangle)
            }
        }
        return AttributedMesh(
            triangles: triangles,
            sourceGeometryFingerprint: geometryFingerprint(of: geometry),
            sourceReferencedVertices: triangles.flatMap { [$0.a, $0.b, $0.c] },
            omittedDegenerateSourceFaceIDs: omittedDegenerateSourceFaceIDs
        )
    }

    static func geometryFingerprint(of geometry: MeshGeometryData) -> String {
        var hasher = PartitionStableHasher()
        hasher.append("mesh-triangle-soup-v1")
        hasher.append(geometry.triangleIndices.count / 3)
        var offset = 0
        while offset + 2 < geometry.triangleIndices.count {
            for rawIndex in geometry.triangleIndices[offset...(offset + 2)] {
                let index = Int(rawIndex)
                if geometry.vertices.indices.contains(index) {
                    hasher.append(geometry.vertices[index])
                } else {
                    hasher.append("invalid-index")
                    hasher.append(Int64(rawIndex))
                }
            }
            offset += 3
        }
        if offset != geometry.triangleIndices.count {
            hasher.append("incomplete-index-tail")
            for rawIndex in geometry.triangleIndices[offset...] { hasher.append(Int64(rawIndex)) }
        }
        return hasher.finalized
    }

    static func isSupportedCoordinate(_ point: Vec3) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
            && abs(point.x) <= maximumSupportedCoordinateMagnitudeMM
            && abs(point.y) <= maximumSupportedCoordinateMagnitudeMM
            && abs(point.z) <= maximumSupportedCoordinateMagnitudeMM
    }
}

extension PartitionTriangleProvenance {
    fileprivate var stableDescription: String {
        switch self {
        case .source(let faceID):
            return "source:\(faceID.rawValue)"
        case .cut(let nodeID, let side):
            return "cut:\(nodeID.rawValue):\(side.rawValue)"
        case .joinery(let seamID, let featureID):
            return "joinery:\(seamID):\(featureID)"
        }
    }
}

/// Fixed FNV-1a byte hashing for reproducible local identities. Swift's
/// `Hasher` is intentionally process-randomized and must not be used here.
struct PartitionStableHasher {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ string: String) {
        append(UInt64(string.utf8.count))
        for byte in string.utf8 { append(byte) }
    }

    mutating func append(_ vector: Vec3) {
        append(vector.x.bitPattern)
        append(vector.y.bitPattern)
        append(vector.z.bitPattern)
    }

    mutating func append(_ value: Int) {
        append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes { append(byte) }
        }
    }

    mutating func appendCanonicalFloatingPoint(_ value: Double) {
        append(value == 0 ? UInt64(0) : value.bitPattern)
    }

    private mutating func append(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }

    var finalized: String {
        String(format: "%016llx", value)
    }
}
