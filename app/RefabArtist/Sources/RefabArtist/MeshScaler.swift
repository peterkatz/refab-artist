import Foundation

struct MeshDimensions: Equatable {
    var width: Double
    var depth: Double
    var height: Double
}

enum ImportUnitPreset: String, CaseIterable, Identifiable, Codable {
    case millimeters
    case centimeters
    case meters
    case inches

    var id: String { rawValue }

    var label: String {
        switch self {
        case .millimeters:
            return "mm"
        case .centimeters:
            return "cm"
        case .meters:
            return "m"
        case .inches:
            return "in"
        }
    }

    var millimetersPerUnit: Double {
        switch self {
        case .millimeters:
            return 1.0
        case .centimeters:
            return 10.0
        case .meters:
            return 1_000.0
        case .inches:
            return 25.4
        }
    }
}

enum MeshScaler {
    static let minimumFactor = 0.01
    static let maximumFactor = 100.0

    static func sanitizedFactor(_ factor: Double) -> Double {
        guard factor.isFinite else {
            return 1.0
        }
        return min(max(factor, minimumFactor), maximumFactor)
    }

    static func dimensions(for bounds: Bounds3D?) -> MeshDimensions? {
        guard let bounds else {
            return nil
        }
        return MeshDimensions(
            width: bounds.max.x - bounds.min.x,
            depth: bounds.max.y - bounds.min.y,
            height: bounds.max.z - bounds.min.z
        )
    }

    static func factorByResizing(currentFactor: Double, currentDimension: Double, targetDimension: Double) -> Double {
        let baseFactor = sanitizedFactor(currentFactor)
        guard currentDimension.isFinite, currentDimension > 0,
              targetDimension.isFinite, targetDimension > 0 else {
            return baseFactor
        }
        return sanitizedFactor(baseFactor * targetDimension / currentDimension)
    }

    static func combinedFactor(unit: ImportUnitPreset, userScale: Double) -> Double {
        // Clamp only the USER scale. The unit conversion must apply in full:
        // clamping the product to 100x silently broke the meters unit
        // (x1000), importing meter-authored models at a tenth of their size
        // and wedging the Object Size fields against the cap.
        unit.millimetersPerUnit * sanitizedFactor(userScale)
    }

    /// A model's longest dimension should land in a plausible fabrication size.
    static let plausibleImportSpanMM = 10.0 ... 3_000.0
    static let preferredImportSpanMM = 150.0

    /// Picks an import unit so a freshly imported model's longest dimension is a
    /// plausible cuttable size (~10–3000 mm), biased toward ~150 mm. Returns
    /// `.millimeters` whenever the model is already a sensible size in mm, so a
    /// correctly-authored mm model is never rescaled. Predicts the *effective*
    /// size (combinedFactor clamps at 100×), so the chosen unit reflects what
    /// the viewport will actually show. UI import default only — the
    /// headless path always passes an explicit unit.
    static func bestFitUnit(forLongestDimension longest: Double) -> ImportUnitPreset {
        guard longest.isFinite, longest > 0 else { return .millimeters }
        func effectiveMM(_ unit: ImportUnitPreset) -> Double {
            longest * combinedFactor(unit: unit, userScale: 1.0)
        }
        if plausibleImportSpanMM.contains(effectiveMM(.millimeters)) {
            return .millimeters
        }
        let inRange = ImportUnitPreset.allCases.filter { plausibleImportSpanMM.contains(effectiveMM($0)) }
        let pool = inRange.isEmpty ? ImportUnitPreset.allCases : inRange
        return pool.min {
            abs(effectiveMM($0) - preferredImportSpanMM) < abs(effectiveMM($1) - preferredImportSpanMM)
        } ?? .millimeters
    }

    /// Full owner-facing transform: per-axis scale (about the model centre)
    /// followed by a rotation in degrees about X, then Y, then Z (also about
    /// the centre). Identity inputs return the model untouched.
    static func transformed(_ model: MeshSummary, scale: Vec3, rotationDegrees: Vec3) -> MeshSummary {
        let sx = sanitizedFactor(scale.x)
        let sy = sanitizedFactor(scale.y)
        let sz = sanitizedFactor(scale.z)
        let isIdentityScale = sx == 1.0 && sy == 1.0 && sz == 1.0
        let isIdentityRotation = rotationDegrees.x == 0 && rotationDegrees.y == 0 && rotationDegrees.z == 0
        guard !(isIdentityScale && isIdentityRotation) else { return model }
        guard let bounds = model.bounds else { return model }
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )

        let rx = rotationDegrees.x * .pi / 180
        let ry = rotationDegrees.y * .pi / 180
        let rz = rotationDegrees.z * .pi / 180
        let (cx, sxr) = (cos(rx), sin(rx))
        let (cy, syr) = (cos(ry), sin(ry))
        let (cz, szr) = (cos(rz), sin(rz))

        func transform(_ v: Vec3) -> Vec3 {
            var p = Vec3(x: (v.x - center.x) * sx, y: (v.y - center.y) * sy, z: (v.z - center.z) * sz)
            if !isIdentityRotation {
                // X axis
                p = Vec3(x: p.x, y: p.y * cx - p.z * sxr, z: p.y * sxr + p.z * cx)
                // Y axis
                p = Vec3(x: p.x * cy + p.z * syr, y: p.y, z: -p.x * syr + p.z * cy)
                // Z axis
                p = Vec3(x: p.x * cz - p.y * szr, y: p.x * szr + p.y * cz, z: p.z)
            }
            return Vec3(x: p.x + center.x, y: p.y + center.y, z: p.z + center.z)
        }

        let vertices = model.geometry.vertices.map(transform)
        var newBounds: Bounds3D?
        if let first = vertices.first {
            var minV = first
            var maxV = first
            for v in vertices {
                minV = Vec3(x: min(minV.x, v.x), y: min(minV.y, v.y), z: min(minV.z, v.z))
                maxV = Vec3(x: max(maxV.x, v.x), y: max(maxV.y, v.y), z: max(maxV.z, v.z))
            }
            newBounds = Bounds3D(min: minV, max: maxV)
        }
        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: model.vertexObservationCount,
            faceCount: model.faceCount,
            triangleCount: model.triangleCount,
            bounds: newBounds,
            geometry: MeshGeometryData(vertices: vertices, triangleIndices: model.geometry.triangleIndices),
            preflight: model.preflight
        )
    }

    /// The map back from `transformed(model, scale: (1, 1, 1),
    /// rotationDegrees:)` to `model`: a point of the turned model to where it
    /// sits in `model`, the rotation undone (Z, then Y, then X) about the
    /// same centre, `model`'s bounds centre. The identity when there is no
    /// rotation or no bounds, as `transformed` returns the model untouched.
    static func unrotating(_ model: MeshSummary, rotationDegrees: Vec3) -> (Vec3) -> Vec3 {
        guard rotationDegrees.x != 0 || rotationDegrees.y != 0 || rotationDegrees.z != 0,
              let bounds = model.bounds else { return { $0 } }
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        let rx = rotationDegrees.x * .pi / 180
        let ry = rotationDegrees.y * .pi / 180
        let rz = rotationDegrees.z * .pi / 180
        let (cx, sx) = (cos(rx), sin(rx))
        let (cy, sy) = (cos(ry), sin(ry))
        let (cz, sz) = (cos(rz), sin(rz))
        return { v in
            var p = Vec3(x: v.x - center.x, y: v.y - center.y, z: v.z - center.z)
            // Z axis, back
            p = Vec3(x: p.x * cz + p.y * sz, y: -p.x * sz + p.y * cz, z: p.z)
            // Y axis, back
            p = Vec3(x: p.x * cy - p.z * sy, y: p.y, z: p.x * sy + p.z * cy)
            // X axis, back
            p = Vec3(x: p.x, y: p.y * cx + p.z * sx, z: -p.y * sx + p.z * cx)
            return Vec3(x: p.x + center.x, y: p.y + center.y, z: p.z + center.z)
        }
    }

    static func scaled(_ model: MeshSummary, factor rawFactor: Double) -> MeshSummary {
        let factor = sanitizedFactor(rawFactor)
        guard factor != 1.0 else {
            return model
        }

        let geometry = MeshGeometryData(
            vertices: model.geometry.vertices.map { scaled($0, factor: factor) },
            triangleIndices: model.geometry.triangleIndices
        )

        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: model.vertexObservationCount,
            faceCount: model.faceCount,
            triangleCount: model.triangleCount,
            bounds: model.bounds.map { bounds in
                Bounds3D(
                    min: scaled(bounds.min, factor: factor),
                    max: scaled(bounds.max, factor: factor)
                )
            },
            geometry: geometry,
            preflight: model.preflight
        )
    }

    private static func scaled(_ value: Vec3, factor: Double) -> Vec3 {
        Vec3(x: value.x * factor, y: value.y * factor, z: value.z * factor)
    }
}
