import Foundation

/// A finite, normalized, sign-canonical plane equation.
///
/// The plane is `dot(point, normal) == offset`. Reversed equations compare
/// equal because normalization flips the offset with the normal. This is a new
/// Partition-owned implementation of the ordering rule previously local to
/// `MoldPartitioner`; it deliberately does not call or modify mold code.
struct CanonicalPlane: Codable, Equatable, Hashable, Comparable, @unchecked Sendable {
    let normal: Vec3
    let offset: Double

    init?(normal rawNormal: Vec3, offset rawOffset: Double) {
        guard rawNormal.x.isFinite,
              rawNormal.y.isFinite,
              rawNormal.z.isFinite,
              rawOffset.isFinite else {
            return nil
        }
        let squaredLength = rawNormal.x * rawNormal.x
            + rawNormal.y * rawNormal.y
            + rawNormal.z * rawNormal.z
        guard squaredLength.isFinite, squaredLength > 1.0e-24 else { return nil }
        let inverseLength = 1.0 / sqrt(squaredLength)
        var normalized = Vec3(
            x: rawNormal.x * inverseLength,
            y: rawNormal.y * inverseLength,
            z: rawNormal.z * inverseLength
        )
        var normalizedOffset = rawOffset * inverseLength

        let firstSignificant = [normalized.x, normalized.y, normalized.z]
            .first { abs($0) > 1.0e-12 } ?? 0
        if firstSignificant < 0 {
            normalized = Vec3(x: -normalized.x, y: -normalized.y, z: -normalized.z)
            normalizedOffset = -normalizedOffset
        }

        guard normalized.x.isFinite,
              normalized.y.isFinite,
              normalized.z.isFinite,
              normalizedOffset.isFinite else {
            return nil
        }

        self.normal = normalized
        self.offset = normalizedOffset
    }

    func signedDistance(to point: Vec3) -> Double {
        point.x * normal.x + point.y * normal.y + point.z * normal.z - offset
    }

    static func < (lhs: CanonicalPlane, rhs: CanonicalPlane) -> Bool {
        let left = [lhs.normal.x, lhs.normal.y, lhs.normal.z, lhs.offset]
        let right = [rhs.normal.x, rhs.normal.y, rhs.normal.z, rhs.offset]
        let leftQuantized = left.map(quantizedForOrdering)
        let rightQuantized = right.map(quantizedForOrdering)
        if leftQuantized != rightQuantized {
            return leftQuantized.lexicographicallyPrecedes(rightQuantized)
        }
        return left.lexicographicallyPrecedes(right)
    }

    private static func quantizedForOrdering(_ value: Double) -> Int64 {
        let scale = 1_000_000_000.0
        let upper = Double(Int64.max) / scale
        let lower = Double(Int64.min) / scale
        if value >= upper { return Int64.max }
        if value <= lower { return Int64.min }
        return Int64((value * scale).rounded())
    }

    private enum CodingKeys: String, CodingKey {
        case normal
        case offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let normal = try container.decode(Vec3.self, forKey: .normal)
        let offset = try container.decode(Double.self, forKey: .offset)
        guard let canonical = CanonicalPlane(normal: normal, offset: offset) else {
            throw DecodingError.dataCorruptedError(
                forKey: .normal,
                in: container,
                debugDescription: "Plane normal and offset must be finite and the normal must be nonzero."
            )
        }
        self = canonical
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normal, forKey: .normal)
        try container.encode(offset, forKey: .offset)
    }
}
