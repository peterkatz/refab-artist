import Foundation

enum UndercutSplitUIWording {
    static let staleAdvisory = "Live inputs changed after this retained result was measured; the report records the generating settings, and the pieces remain exportable."
}

enum UndercutFacePaintMode: String, CaseIterable, Identifiable, Equatable, Hashable {
    case none
    case noCut
    case preferredSeam

    var id: String { rawValue }
}

/// Render-only facts derived from an `UndercutSplitPlan`. This keeps measured
/// region meshes, stable region IDs, pull axes, and cut-node IDs intact instead
/// of asking the viewport to infer them from the legacy flat partition plan.
struct UndercutSplitOverlay: Equatable {
    enum RegionSeverity: String, Equatable {
        case overTolerance
        case withinToleranceNonzero
        case draftAdvisory
    }

    struct Piece: Equatable, Identifiable {
        var id: PartitionRegionID { regionID }
        var regionID: PartitionRegionID
        var pullAxis: Vec3
        var center: Vec3
        var colorIndex: Int
        var explodeVector: Vec3
        var finalMeasurementPasses: Bool
    }

    struct MeasuredRegion: Equatable, Identifiable {
        var id: String
        var pieceRegionID: PartitionRegionID
        var depthMM: Double
        var areaMM2: Double
        var centroid: Vec3
        var severity: RegionSeverity
        var renderMesh: ViewportFlatShadedMesh?

        var depthLabel: String {
            String(format: "%.3g mm deep · %.3g mm²", depthMM, areaMM2)
        }
    }

    struct CutSurface: Equatable, Identifiable {
        var id: PartitionCutNodeID { nodeID }
        var nodeID: PartitionCutNodeID
        var targetRegionID: PartitionRegionID
        var plane: CanonicalPlane
        var isLocked: Bool
        var isSelected: Bool
        var isHovered: Bool
        var renderMesh: ViewportFlatShadedMesh?
        var fallbackCenter: Vec3
        var fallbackExtentMM: Double
    }

    struct PaintableFace: Equatable, Identifiable {
        var id: String
        var sourceFaceID: SourceFaceID
        var pieceRegionID: PartitionRegionID
        var triangle: AttributedTriangle
    }

    struct PaintPatch: Equatable, Identifiable {
        var id: String
        var pieceRegionID: PartitionRegionID
        var mode: UndercutFacePaintMode
        var renderMesh: ViewportFlatShadedMesh
    }

    var pieces: [Piece]
    var regions: [MeasuredRegion]
    var cutSurfaces: [CutSurface]
    var paintableFaces: [PaintableFace]
    var paintableFaceIndicesBySourceID: [SourceFaceID: [Int]]
    var paintPatches: [PaintPatch]
    var facePaintMode: UndercutFacePaintMode
    var facePaintFingerprint: String
    var isolatedPieceRegionID: PartitionRegionID?
    var hoveredRegionID: String?
    var isStale: Bool
    var effectiveResolutionMM: Double?
    var sourceGeometryFingerprint: String
    var bounds: Bounds3D?
    var deterministicFingerprint: String

    var hoveredRegion: MeasuredRegion? {
        guard let hoveredRegionID else { return nil }
        return regions.first { $0.id == hoveredRegionID }
    }

    /// Applies lightweight viewport state without rebuilding measured-region
    /// meshes. `make` is intentionally run off-main with the planner result;
    /// selection, hover, isolation, and authored-tree previews then flow through
    /// this value-only transform on the main actor.
    func applying(
        authoredTree: PartitionCutTree?,
        selectedCutNodeID: PartitionCutNodeID?,
        hoveredCutNodeID: PartitionCutNodeID?,
        isolatedPieceRegionID: PartitionRegionID?,
        hoveredRegionID: String?,
        isStale: Bool,
        faceConstraints: PartitionFaceConstraints = .empty,
        facePaintMode: UndercutFacePaintMode = .none
    ) -> UndercutSplitOverlay {
        var copy = self
        copy.isolatedPieceRegionID = pieces.contains(where: { $0.regionID == isolatedPieceRegionID })
            ? isolatedPieceRegionID
            : nil
        copy.hoveredRegionID = regions.contains(where: { $0.id == hoveredRegionID })
            ? hoveredRegionID
            : nil
        copy.facePaintMode = facePaintMode
        copy.paintPatches = Self.paintPatches(
            faces: copy.paintableFaces,
            faceIndicesBySourceID: copy.paintableFaceIndicesBySourceID,
            pieces: copy.pieces,
            constraints: faceConstraints
        )
        copy.facePaintFingerprint = Self.facePaintFingerprint(faceConstraints)
        copy.isStale = isStale
        if isStale {
            for index in copy.pieces.indices {
                copy.pieces[index].finalMeasurementPasses = false
            }
        }

        if let authoredTree {
            let existing = Dictionary(
                uniqueKeysWithValues: copy.cutSurfaces.map { ($0.nodeID, $0) }
            )
            let overlayCenter = copy.bounds.map(Self.center(of:)) ?? Vec3(x: 0, y: 0, z: 0)
            let overlayExtent = copy.bounds.map(Self.maximumExtent(of:)) ?? 1
            copy.cutSurfaces = authoredTree.nodes.map { node in
                if var surface = existing[node.id] {
                    if surface.plane != node.plane {
                        // The retained cap is the last measured result. A moved
                        // authored plane uses the exact planar preview until the
                        // user runs Analyze & Split again.
                        surface.renderMesh = nil
                    }
                    surface.targetRegionID = node.targetRegionID
                    surface.plane = node.plane
                    surface.isLocked = node.isLocked
                    surface.fallbackCenter = Self.pointOnPlaneNear(
                        center: overlayCenter,
                        plane: node.plane
                    )
                    surface.fallbackExtentMM = max(overlayExtent * 1.1, 1)
                    return surface
                }
                return CutSurface(
                    nodeID: node.id,
                    targetRegionID: node.targetRegionID,
                    plane: node.plane,
                    isLocked: node.isLocked,
                    isSelected: false,
                    isHovered: false,
                    renderMesh: nil,
                    fallbackCenter: Self.pointOnPlaneNear(center: overlayCenter, plane: node.plane),
                    fallbackExtentMM: max(overlayExtent * 1.1, 1)
                )
            }
        }

        if !copy.cutSurfaces.contains(where: { $0.nodeID == selectedCutNodeID }) {
            for index in copy.cutSurfaces.indices { copy.cutSurfaces[index].isSelected = false }
        } else {
            for index in copy.cutSurfaces.indices {
                copy.cutSurfaces[index].isSelected = copy.cutSurfaces[index].nodeID == selectedCutNodeID
            }
        }
        for index in copy.cutSurfaces.indices {
            copy.cutSurfaces[index].isHovered = copy.cutSurfaces[index].nodeID == hoveredCutNodeID
        }
        return copy
    }

    /// CPU ray/triangle picker for source-face paint. It consumes the exact
    /// attributed source fragments shown in the current result, so clipping
    /// never loses the stable `SourceFaceID` written into settings.
    func sourceFaceID(
        rayOrigin: Vec3,
        rayDirection: Vec3,
        explodeAmount: Double
    ) -> SourceFaceID? {
        let extent = bounds.map(Self.maximumExtent(of:)) ?? 1
        let explodeScale = min(max(explodeAmount, 0), 1) * extent * 0.348
        let offsets = Dictionary(uniqueKeysWithValues: pieces.map { piece in
            (
                piece.regionID,
                Vec3(
                    x: piece.explodeVector.x * explodeScale,
                    y: piece.explodeVector.y * explodeScale,
                    z: piece.explodeVector.z * explodeScale
                )
            )
        })
        var nearest: (distance: Double, faceID: SourceFaceID, stableID: String)?
        for face in paintableFaces {
            if let isolatedPieceRegionID, face.pieceRegionID != isolatedPieceRegionID { continue }
            let offset = offsets[face.pieceRegionID] ?? Vec3(x: 0, y: 0, z: 0)
            let triangle = face.triangle
            guard let distance = Self.rayTriangleDistance(
                origin: rayOrigin,
                direction: rayDirection,
                a: Self.add(triangle.a, offset),
                b: Self.add(triangle.b, offset),
                c: Self.add(triangle.c, offset)
            ) else { continue }
            if let current = nearest {
                if distance > current.distance + 1.0e-9 { continue }
                if abs(distance - current.distance) <= 1.0e-9,
                   (face.sourceFaceID > current.faceID
                    || (face.sourceFaceID == current.faceID && face.id >= current.stableID)) {
                    continue
                }
            }
            nearest = (distance, face.sourceFaceID, face.id)
        }
        return nearest?.faceID
    }

    /// Picks the rendered cap surface itself (with a bounded-plane fallback
    /// for newly authored or moved cuts), so cut selection is not limited to a
    /// small handle target.
    func cutNodeID(rayOrigin: Vec3, rayDirection: Vec3) -> PartitionCutNodeID? {
        var nearest: (distance: Double, nodeID: PartitionCutNodeID)?
        for cut in cutSurfaces {
            var distance: Double?
            if let mesh = cut.renderMesh {
                var cursor = 0
                while cursor + 2 < mesh.triangleIndices.count {
                    let ia = Int(mesh.triangleIndices[cursor])
                    let ib = Int(mesh.triangleIndices[cursor + 1])
                    let ic = Int(mesh.triangleIndices[cursor + 2])
                    cursor += 3
                    guard mesh.vertices.indices.contains(ia),
                          mesh.vertices.indices.contains(ib),
                          mesh.vertices.indices.contains(ic) else { continue }
                    if let hit = Self.rayTriangleDistance(
                        origin: rayOrigin,
                        direction: rayDirection,
                        a: mesh.vertices[ia],
                        b: mesh.vertices[ib],
                        c: mesh.vertices[ic]
                    ), distance == nil || hit < distance! {
                        distance = hit
                    }
                }
            } else {
                let denominator = Self.dot(cut.plane.normal, rayDirection)
                if abs(denominator) > 1.0e-12 {
                    let hit = (cut.plane.offset - Self.dot(cut.plane.normal, rayOrigin)) / denominator
                    if hit > 1.0e-9 {
                        let point = Vec3(
                            x: rayOrigin.x + rayDirection.x * hit,
                            y: rayOrigin.y + rayDirection.y * hit,
                            z: rayOrigin.z + rayDirection.z * hit
                        )
                        let delta = Self.subtract(point, cut.fallbackCenter)
                        if sqrt(Self.dot(delta, delta)) <= cut.fallbackExtentMM * 0.72 {
                            distance = hit
                        }
                    }
                }
            }
            guard let distance else { continue }
            if let current = nearest,
               (distance > current.distance + 1.0e-9
                || (abs(distance - current.distance) <= 1.0e-9 && cut.nodeID >= current.nodeID)) {
                continue
            }
            nearest = (distance, cut.nodeID)
        }
        return nearest?.nodeID
    }

    func measuredRegionID(
        rayOrigin: Vec3,
        rayDirection: Vec3,
        explodeAmount: Double
    ) -> String? {
        let extent = bounds.map(Self.maximumExtent(of:)) ?? 1
        let explodeScale = min(max(explodeAmount, 0), 1) * extent * 0.348
        let offsets = Dictionary(uniqueKeysWithValues: pieces.map { piece in
            (
                piece.regionID,
                Vec3(
                    x: piece.explodeVector.x * explodeScale,
                    y: piece.explodeVector.y * explodeScale,
                    z: piece.explodeVector.z * explodeScale
                )
            )
        })
        var nearest: (distance: Double, id: String)?
        for region in regions {
            if let isolatedPieceRegionID, region.pieceRegionID != isolatedPieceRegionID { continue }
            let offset = offsets[region.pieceRegionID] ?? Vec3(x: 0, y: 0, z: 0)
            var distance: Double?
            if let mesh = region.renderMesh {
                var cursor = 0
                while cursor + 2 < mesh.triangleIndices.count {
                    let ia = Int(mesh.triangleIndices[cursor])
                    let ib = Int(mesh.triangleIndices[cursor + 1])
                    let ic = Int(mesh.triangleIndices[cursor + 2])
                    cursor += 3
                    guard mesh.vertices.indices.contains(ia),
                          mesh.vertices.indices.contains(ib),
                          mesh.vertices.indices.contains(ic) else { continue }
                    if let hit = Self.rayTriangleDistance(
                        origin: rayOrigin,
                        direction: rayDirection,
                        a: Self.add(mesh.vertices[ia], offset),
                        b: Self.add(mesh.vertices[ib], offset),
                        c: Self.add(mesh.vertices[ic], offset)
                    ), distance == nil || hit < distance! {
                        distance = hit
                    }
                }
            } else {
                let center = Self.add(region.centroid, offset)
                distance = Self.raySphereDistance(
                    origin: rayOrigin,
                    direction: rayDirection,
                    center: center,
                    radius: max(0.8, extent * 0.009)
                )
            }
            guard let distance else { continue }
            if let current = nearest,
               (distance > current.distance + 1.0e-9
                || (abs(distance - current.distance) <= 1.0e-9 && region.id >= current.id)) {
                continue
            }
            nearest = (distance, region.id)
        }
        return nearest?.id
    }

    static func make(
        plan: UndercutSplitPlan,
        settings rawSettings: UndercutSplitSettings,
        isStale: Bool = false,
        selectedCutNodeID: PartitionCutNodeID? = nil,
        hoveredCutNodeID: PartitionCutNodeID? = nil,
        isolatedPieceRegionID: PartitionRegionID? = nil,
        hoveredRegionID: String? = nil
    ) -> UndercutSplitOverlay {
        let settings = rawSettings.sanitized
        let orderedPieces = plan.pieces.sorted { $0.regionID < $1.regionID }
        let combinedBounds = bounds(of: orderedPieces.flatMap { $0.mesh.triangles })
        let overallCenter = combinedBounds.map(center(of:)) ?? Vec3(x: 0, y: 0, z: 0)
        let overallExtent = combinedBounds.map(maximumExtent(of:)) ?? 1
        let explodeVectors = treeExplodeVectors(tree: plan.cutTree)

        let pieces = orderedPieces.map { piece in
            let pieceCenter = bounds(of: piece.mesh.triangles).map(center(of:)) ?? overallCenter
            let passes = !isStale
                && plan.fullResolutionFinalized
                && piece.measurement?.status(
                    toleranceMM: settings.undercutToleranceMM,
                    minRegionAreaMM2: settings.minRegionAreaMM2
                ) == .withinTolerance
            return Piece(
                regionID: piece.regionID,
                pullAxis: normalized(piece.pullAxis),
                center: pieceCenter,
                colorIndex: stableColorIndex(for: piece.regionID),
                explodeVector: explodeVectors[piece.regionID] ?? Vec3(x: 0, y: 0, z: 0),
                finalMeasurementPasses: passes
            )
        }

        var measuredRegions: [MeasuredRegion] = []
        for piece in orderedPieces {
            for region in piece.attributedRegions.sorted(by: { $0.id < $1.id }) where region.depthMM > 0 {
                let severity: RegionSeverity = region.areaMM2 >= settings.minRegionAreaMM2
                    && region.depthMM > settings.undercutToleranceMM
                    ? .overTolerance
                    : .withinToleranceNonzero
                let regionTriangles = region.measurementFaceIDs.compactMap { faceID in
                    piece.mesh.triangles.indices.contains(faceID) ? piece.mesh.triangles[faceID] : nil
                }
                measuredRegions.append(
                    MeasuredRegion(
                        id: "\(piece.regionID.rawValue)|\(region.id)",
                        pieceRegionID: piece.regionID,
                        depthMM: region.depthMM,
                        areaMM2: region.areaMM2,
                        centroid: region.centroid,
                        severity: severity,
                        renderMesh: renderMesh(from: regionTriangles)
                    )
                )
            }
            if piece.draftAdvisoryAreaMM2 > 0 {
                let pieceCenter = bounds(of: piece.mesh.triangles).map(center(of:)) ?? overallCenter
                let draftTriangles = lowDraftTriangles(
                    in: piece.mesh,
                    pullAxis: piece.pullAxis,
                    advisoryDegrees: settings.draftAdvisoryDegrees
                )
                measuredRegions.append(
                    MeasuredRegion(
                        id: "\(piece.regionID.rawValue)|draft",
                        pieceRegionID: piece.regionID,
                        depthMM: 0,
                        areaMM2: piece.draftAdvisoryAreaMM2,
                        centroid: pieceCenter,
                        severity: .draftAdvisory,
                        renderMesh: renderMesh(from: draftTriangles)
                    )
                )
            }
        }

        let cutSurfaces = plan.cutTree.nodes.map { node in
            let capTriangles = orderedPieces.flatMap { piece in
                piece.mesh.triangles.filter { triangle in
                    guard case .cut(let nodeID, let side) = triangle.provenance else { return false }
                    return nodeID == node.id && side == .negative
                }
            }
            return CutSurface(
                nodeID: node.id,
                targetRegionID: node.targetRegionID,
                plane: node.plane,
                isLocked: node.isLocked,
                isSelected: node.id == selectedCutNodeID,
                isHovered: node.id == hoveredCutNodeID,
                renderMesh: renderMesh(from: capTriangles),
                fallbackCenter: pointOnPlaneNear(
                    center: overallCenter,
                    plane: node.plane
                ),
                fallbackExtentMM: max(overallExtent * 1.1, 1)
            )
        }

        var paintableFaces: [PaintableFace] = []
        for piece in orderedPieces {
            for (triangleIndex, triangle) in piece.mesh.triangles.enumerated() {
                guard case .source(let sourceFaceID) = triangle.provenance else { continue }
                paintableFaces.append(
                    PaintableFace(
                        id: "\(piece.regionID.rawValue)|\(sourceFaceID.rawValue)|\(triangleIndex)",
                        sourceFaceID: sourceFaceID,
                        pieceRegionID: piece.regionID,
                        triangle: triangle
                    )
                )
            }
        }

        return UndercutSplitOverlay(
            pieces: pieces,
            regions: measuredRegions.sorted { lhs, rhs in
                if lhs.pieceRegionID != rhs.pieceRegionID {
                    return lhs.pieceRegionID < rhs.pieceRegionID
                }
                return lhs.id < rhs.id
            },
            cutSurfaces: cutSurfaces,
            paintableFaces: paintableFaces,
            paintableFaceIndicesBySourceID: indexPaintableFaces(paintableFaces),
            paintPatches: [],
            facePaintMode: .none,
            facePaintFingerprint: "",
            isolatedPieceRegionID: isolatedPieceRegionID,
            hoveredRegionID: hoveredRegionID,
            isStale: isStale,
            effectiveResolutionMM: plan.effectiveMeasurementResolutionMM,
            sourceGeometryFingerprint: orderedPieces.first?.mesh.sourceGeometryFingerprint ?? "",
            bounds: combinedBounds,
            deterministicFingerprint: plan.deterministicFingerprint
        )
    }

    private static func renderMesh(from triangles: [AttributedTriangle]) -> ViewportFlatShadedMesh? {
        guard !triangles.isEmpty else { return nil }
        return PartitionGeometry.flatShadedMesh(triangles.map { ($0.a, $0.b, $0.c) })
    }

    private static func paintPatches(
        faces: [PaintableFace],
        faceIndicesBySourceID: [SourceFaceID: [Int]],
        pieces: [Piece],
        constraints: PartitionFaceConstraints
    ) -> [PaintPatch] {
        let noCut = Set(constraints.noCutSourceFaceIDs)
        let preferred = Set(constraints.preferredSeamFaces.map(\.sourceFaceID))
        guard !noCut.isEmpty || !preferred.isEmpty else { return [] }
        let selectedFaces = noCut.union(preferred)
            .sorted()
            .flatMap { faceIndicesBySourceID[$0] ?? [] }
            .compactMap { faces.indices.contains($0) ? faces[$0] : nil }
        let facesByPiece = Dictionary(grouping: selectedFaces, by: \.pieceRegionID)
        var result: [PaintPatch] = []
        for piece in pieces.sorted(by: { $0.regionID < $1.regionID }) {
            let pieceFaces = facesByPiece[piece.regionID] ?? []
            for (mode, selectedIDs) in [
                (UndercutFacePaintMode.noCut, noCut),
                (.preferredSeam, preferred),
            ] where !selectedIDs.isEmpty {
                let triangles = pieceFaces
                    .filter { selectedIDs.contains($0.sourceFaceID) }
                    .map(\.triangle)
                guard let renderMesh = renderMesh(from: triangles) else { continue }
                result.append(
                    PaintPatch(
                        id: "\(piece.regionID.rawValue)|\(mode.rawValue)",
                        pieceRegionID: piece.regionID,
                        mode: mode,
                        renderMesh: renderMesh
                    )
                )
            }
        }
        return result
    }

    private static func indexPaintableFaces(
        _ faces: [PaintableFace]
    ) -> [SourceFaceID: [Int]] {
        var result: [SourceFaceID: [Int]] = [:]
        for (index, face) in faces.enumerated() {
            result[face.sourceFaceID, default: []].append(index)
        }
        return result
    }

    private static func facePaintFingerprint(_ constraints: PartitionFaceConstraints) -> String {
        var hasher = PartitionStableHasher()
        hasher.append("undercut-face-paint-v1")
        for faceID in constraints.noCutSourceFaceIDs.sorted() {
            hasher.append("no-cut")
            hasher.append(faceID.rawValue)
        }
        for entry in constraints.preferredSeamFaces.sorted(by: { $0.sourceFaceID < $1.sourceFaceID }) {
            hasher.append("preferred")
            hasher.append(entry.sourceFaceID.rawValue)
            hasher.appendCanonicalFloatingPoint(entry.weight)
        }
        return hasher.finalized
    }

    private static func rayTriangleDistance(
        origin: Vec3,
        direction: Vec3,
        a: Vec3,
        b: Vec3,
        c: Vec3
    ) -> Double? {
        let edge1 = subtract(b, a)
        let edge2 = subtract(c, a)
        let p = cross(direction, edge2)
        let determinant = dot(edge1, p)
        guard determinant.isFinite, abs(determinant) > 1.0e-12 else { return nil }
        let inverse = 1 / determinant
        let translated = subtract(origin, a)
        let u = dot(translated, p) * inverse
        guard u >= -1.0e-10, u <= 1 + 1.0e-10 else { return nil }
        let q = cross(translated, edge1)
        let v = dot(direction, q) * inverse
        guard v >= -1.0e-10, u + v <= 1 + 1.0e-10 else { return nil }
        let distance = dot(edge2, q) * inverse
        return distance.isFinite && distance > 1.0e-9 ? distance : nil
    }

    private static func raySphereDistance(
        origin: Vec3,
        direction: Vec3,
        center: Vec3,
        radius: Double
    ) -> Double? {
        let offset = subtract(origin, center)
        let a = dot(direction, direction)
        let b = 2 * dot(offset, direction)
        let c = dot(offset, offset) - radius * radius
        let discriminant = b * b - 4 * a * c
        guard a > 1.0e-24, discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)
        let near = (-b - root) / (2 * a)
        let far = (-b + root) / (2 * a)
        if near > 1.0e-9 { return near }
        return far > 1.0e-9 ? far : nil
    }

    private static func bounds(of triangles: [AttributedTriangle]) -> Bounds3D? {
        guard let first = triangles.first?.a else { return nil }
        var minimum = first
        var maximum = first
        for triangle in triangles {
            for point in [triangle.a, triangle.b, triangle.c] {
                minimum.x = min(minimum.x, point.x)
                minimum.y = min(minimum.y, point.y)
                minimum.z = min(minimum.z, point.z)
                maximum.x = max(maximum.x, point.x)
                maximum.y = max(maximum.y, point.y)
                maximum.z = max(maximum.z, point.z)
            }
        }
        return Bounds3D(min: minimum, max: maximum)
    }

    private static func center(of bounds: Bounds3D) -> Vec3 {
        Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
    }

    private static func maximumExtent(of bounds: Bounds3D) -> Double {
        max(
            bounds.max.x - bounds.min.x,
            max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        )
    }

    private static func pointOnPlaneNear(center: Vec3, plane: CanonicalPlane) -> Vec3 {
        let distance = plane.signedDistance(to: center)
        return Vec3(
            x: center.x - plane.normal.x * distance,
            y: center.y - plane.normal.y * distance,
            z: center.z - plane.normal.z * distance
        )
    }

    private static func normalized(_ value: Vec3) -> Vec3 {
        let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        guard length.isFinite, length > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func lowDraftTriangles(
        in mesh: AttributedMesh,
        pullAxis: Vec3,
        advisoryDegrees: Double
    ) -> [AttributedTriangle] {
        let axis = normalized(pullAxis)
        let threshold = sin(min(max(advisoryDegrees, 0), 10) * Double.pi / 180)
        return mesh.triangles.filter { triangle in
            guard case .source = triangle.provenance else { return false }
            let ab = subtract(triangle.b, triangle.a)
            let ac = subtract(triangle.c, triangle.a)
            let normal = cross(ab, ac)
            let length = sqrt(dot(normal, normal))
            guard length.isFinite, length > 1.0e-24 else { return false }
            return abs(dot(normal, axis) / length) <= threshold
        }
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func stableColorIndex(for regionID: PartitionRegionID) -> Int {
        var hasher = PartitionStableHasher()
        hasher.append("undercut-piece-color-v1")
        hasher.append(regionID.rawValue)
        let value = UInt64(hasher.finalized, radix: 16) ?? 0
        return Int(value % 6)
    }

    /// Each positive child moves along its own seam normal while its negative
    /// sibling stays in place. Descendant motions accumulate, so the preview
    /// follows the cut-tree disassembly traversal instead of a radial scatter.
    private static func treeExplodeVectors(tree: PartitionCutTree) -> [PartitionRegionID: Vec3] {
        let byTarget = Dictionary(
            tree.nodes.map { ($0.targetRegionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [PartitionRegionID: Vec3] = [:]

        func walk(regionID: PartitionRegionID, accumulated: Vec3) {
            guard let node = byTarget[regionID] else {
                result[regionID] = accumulated
                return
            }
            walk(regionID: node.negativeChildID, accumulated: accumulated)
            walk(
                regionID: node.positiveChildID,
                accumulated: add(accumulated, normalized(node.plane.normal))
            )
        }
        walk(regionID: tree.rootRegionID, accumulated: Vec3(x: 0, y: 0, z: 0))
        return result
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }
}
