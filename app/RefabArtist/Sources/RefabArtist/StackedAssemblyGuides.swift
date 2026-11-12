import CManifold
import Foundation

/// Assembly guides for Stacked cut sheets: the red scored lines on each part
/// that trace where the NEXT layer's outline lands well inside it, so the
/// builder can see where to glue that layer down. Behavior and output shape
/// are specified in docs/specs/stacked.md §3.5.
///
/// Layer i's guide zone is the area its paths enclose (every path taken as a
/// closed ring, holes not subtracted) with every edge moved inward by the
/// clearance. Layer i+1's paths, closed and open, are cut against that zone
/// and the pieces inside are layer i's guides. The last layer has none.
enum StackedAssemblyGuides {
    /// Points this close to the zone's edge count as inside, so an edge that
    /// steps in by exactly the clearance is traced whole instead of breaking
    /// up on rounding noise.
    static let boundaryTolerance = 1.0e-4

    /// How far, in clearances, a concave corner of the zone may reach from
    /// the outline's corner before it is cut square. Two clearances keeps the
    /// sharp corner for any notch opening wider than 60 degrees.
    static let cornerLimit = 2.0

    /// One list of guide polylines per layer, in the layers' plane
    /// coordinates. A next-layer loop that lies wholly inside the zone comes
    /// back closed (first point repeated at the end); anything that leaves
    /// the zone comes back as open pieces that follow the source path's
    /// direction and end on the zone's edge.
    static func guides(for layers: [SliceContourLayer], clearance: Double) -> [[[Vec2]]] {
        var result = Array(repeating: [[Vec2]](), count: layers.count)
        guard layers.count >= 2, clearance.isFinite, clearance > 0 else { return result }
        let inset = max(0, clearance - boundaryTolerance)
        for index in 0..<(layers.count - 1) {
            guard let zone = Zone(enclosedBy: layers[index], shrunkBy: inset) else { continue }
            result[index] = layers[index + 1].paths.flatMap { zone.clip($0) }
        }
        return result
    }

    // MARK: - Guide zone

    /// A layer's guide zone as polygons (outer contours and any holes, read
    /// even-odd), with a bucket grid over the edges so cutting a long path
    /// against a dense contour stays close to linear.
    struct Zone {
        private let edges: [(a: Vec2, b: Vec2)]
        private let minX: Double
        private let minY: Double
        private let maxX: Double
        private let maxY: Double
        private let cellSize: Double
        private let columns: Int
        private let rows: Int
        private let cells: [[Int]]

        /// The area the layer's paths enclose, shrunk by `inset`. Nil when
        /// nothing is left.
        init?(enclosedBy layer: SliceContourLayer, shrunkBy inset: Double) {
            let rings = layer.paths
                .map { Polygon2D.normalizedCCW($0.points) }
                .filter { $0.count >= 3 }
            guard !rings.isEmpty else { return nil }
            self.init(contours: StackedAssemblyGuides.shrunkUnion(of: rings, by: inset))
        }

        /// A zone made of these contours, taken even-odd. Nil when none of
        /// them has three points.
        init?(contours: [[Vec2]]) {
            let usable = contours.filter { $0.count >= 3 }
            var edges: [(a: Vec2, b: Vec2)] = []
            for contour in usable {
                for index in contour.indices {
                    edges.append((contour[index], contour[(index + 1) % contour.count]))
                }
            }
            guard let first = edges.first?.a else { return nil }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for edge in edges {
                minX = min(minX, edge.a.x)
                minY = min(minY, edge.a.y)
                maxX = max(maxX, edge.a.x)
                maxY = max(maxY, edge.a.y)
            }
            let span = max(maxX - minX, maxY - minY, 1.0e-9)
            let divisions = max(1, min(1024, Int(Double(edges.count).squareRoot())))
            let cellSize = span / Double(divisions)
            let columns = Int((maxX - minX) / cellSize) + 1
            let rows = Int((maxY - minY) / cellSize) + 1

            var cells = Array(repeating: [Int](), count: columns * rows)
            for (index, edge) in edges.enumerated() {
                let c0 = Self.cell(min(edge.a.x, edge.b.x), origin: minX, size: cellSize, count: columns)
                let c1 = Self.cell(max(edge.a.x, edge.b.x), origin: minX, size: cellSize, count: columns)
                let r0 = Self.cell(min(edge.a.y, edge.b.y), origin: minY, size: cellSize, count: rows)
                let r1 = Self.cell(max(edge.a.y, edge.b.y), origin: minY, size: cellSize, count: rows)
                for r in r0...r1 {
                    for c in c0...c1 {
                        cells[r * columns + c].append(index)
                    }
                }
            }

            self.edges = edges
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
            self.cellSize = cellSize
            self.columns = columns
            self.rows = rows
            self.cells = cells
        }

        private static func cell(_ value: Double, origin: Double, size: Double, count: Int) -> Int {
            min(count - 1, max(0, Int(((value - origin) / size).rounded(.down))))
        }

        private func column(_ x: Double) -> Int {
            Self.cell(x, origin: minX, size: cellSize, count: columns)
        }

        private func row(_ y: Double) -> Int {
            Self.cell(y, origin: minY, size: cellSize, count: rows)
        }

        /// Edge indices registered in the given cell range, each once.
        private func edgeIndices(columns c0: Int, _ c1: Int, rows r0: Int, _ r1: Int) -> [Int] {
            var indices: [Int] = []
            for r in r0...r1 {
                for c in c0...c1 {
                    indices.append(contentsOf: cells[r * columns + c])
                }
            }
            indices.sort()
            var unique: [Int] = []
            unique.reserveCapacity(indices.count)
            for index in indices where unique.last != index {
                unique.append(index)
            }
            return unique
        }

        /// Even-odd point-in-zone test (a ray cast toward +x).
        func contains(_ p: Vec2) -> Bool {
            guard p.x <= maxX, p.y >= minY, p.y <= maxY else { return false }
            let r = row(p.y)
            var inside = false
            for index in edgeIndices(columns: column(p.x), columns - 1, rows: r, r) {
                let (a, b) = edges[index]
                guard (a.y > p.y) != (b.y > p.y) else { continue }
                let x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if x > p.x {
                    inside.toggle()
                }
            }
            return inside
        }

        /// Parameters in (0, 1), ascending and without near-duplicates, where
        /// the segment a→b crosses or touches a zone edge.
        func crossings(from a: Vec2, to b: Vec2) -> [Double] {
            guard max(a.x, b.x) >= minX, min(a.x, b.x) <= maxX,
                  max(a.y, b.y) >= minY, min(a.y, b.y) <= maxY else {
                return []
            }
            let rx = b.x - a.x, ry = b.y - a.y
            var parameters: [Double] = []
            let candidates = edgeIndices(
                columns: column(min(a.x, b.x)), column(max(a.x, b.x)),
                rows: row(min(a.y, b.y)), row(max(a.y, b.y))
            )
            for index in candidates {
                let (c, d) = edges[index]
                let sx = d.x - c.x, sy = d.y - c.y
                let denominator = rx * sy - ry * sx
                let scale = (rx * rx + ry * ry).squareRoot() * (sx * sx + sy * sy).squareRoot()
                guard abs(denominator) > 1.0e-12 * scale else { continue }  // parallel
                let qx = c.x - a.x, qy = c.y - a.y
                let t = (qx * sy - qy * sx) / denominator
                let u = (qx * ry - qy * rx) / denominator
                guard u >= -1.0e-12, u <= 1 + 1.0e-12, t > 1.0e-12, t < 1 - 1.0e-12 else { continue }
                parameters.append(t)
            }
            parameters.sort()
            var unique: [Double] = []
            for t in parameters where unique.last.map({ t - $0 > 1.0e-12 }) ?? true {
                unique.append(t)
            }
            return unique
        }

        /// The pieces of `path` inside the zone. A closed loop wholly inside
        /// comes back closed; a loop's piece that runs through its first
        /// vertex comes back as one polyline. Paths with fewer than three
        /// distinct points (the single-segment crumbs a broken mesh leaves)
        /// give nothing.
        func clip(_ path: SlicePath2D) -> [[Vec2]] {
            var points = path.points
            var closed = path.closed
            if let first = points.first, let last = points.last, points.count >= 2,
               abs(first.x - last.x) < 1.0e-9, abs(first.y - last.y) < 1.0e-9 {
                points.removeLast()
                closed = true
            }
            guard points.count >= 3 else { return [] }
            let edgeCount = closed ? points.count : points.count - 1

            func point(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 {
                if t <= 0 { return a }
                if t >= 1 { return b }
                return Vec2(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }

            var pieces: [[Vec2]] = []
            var current: [Vec2] = []
            var startsInside: Bool?
            var endsInside = false
            for index in 0..<edgeCount {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                let bounds = [0.0] + crossings(from: a, to: b) + [1.0]
                for step in 0..<(bounds.count - 1) {
                    let t0 = bounds[step], t1 = bounds[step + 1]
                    let inside = contains(point(a, b, (t0 + t1) / 2))
                    if startsInside == nil {
                        startsInside = inside
                    }
                    endsInside = inside
                    if inside {
                        if current.isEmpty {
                            current.append(point(a, b, t0))
                        }
                        current.append(point(a, b, t1))
                    } else if !current.isEmpty {
                        pieces.append(current)
                        current = []
                    }
                }
            }
            if !current.isEmpty {
                pieces.append(current)
            }
            // The piece that ends at the loop's first vertex continues into the
            // piece that starts there.
            if closed, pieces.count >= 2, startsInside == true, endsInside {
                let head = pieces.removeFirst()
                pieces[pieces.count - 1].append(contentsOf: head.dropFirst())
            }
            return pieces.filter(Self.hasLength)
        }

        /// False for a polyline whose points all coincide.
        private static func hasLength(_ polyline: [Vec2]) -> Bool {
            guard let first = polyline.first else { return false }
            return polyline.contains { abs($0.x - first.x) > 1.0e-9 || abs($0.y - first.y) > 1.0e-9 }
        }
    }

    // MARK: - Manifold CrossSection

    private static let simplePolygonArenaSize = manifold_simple_polygon_size()
    private static let polygonsArenaSize = manifold_polygons_size()
    private static let crossSectionArenaSize = manifold_cross_section_size()

    private static func arena(_ size: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    }

    /// Union of the rings' interiors (non-zero fill of counterclockwise rings,
    /// so nested rings fill rather than cut holes), with every edge moved
    /// inward by `inset`. At a concave corner of the outline the moved edges
    /// are extended until they meet, so the zone's corner there is sharp;
    /// where they would meet more than `cornerLimit` clearances from the
    /// corner it is cut square instead. Returns the result's contours; empty
    /// when nothing is left.
    static func shrunkUnion(of rings: [[Vec2]], by inset: Double) -> [[Vec2]] {
        var simplePolygons: [OpaquePointer?] = []
        var simpleArenas: [UnsafeMutableRawPointer] = []
        defer {
            for (index, polygon) in simplePolygons.enumerated() {
                if let polygon { manifold_destruct_simple_polygon(polygon) }
                simpleArenas[index].deallocate()
            }
        }
        for ring in rings {
            var points = ring.map { ManifoldVec2(x: $0.x, y: $0.y) }
            let mem = arena(simplePolygonArenaSize)
            let polygon = points.withUnsafeMutableBufferPointer { buffer in
                manifold_simple_polygon(mem, buffer.baseAddress, buffer.count)
            }
            guard polygon != nil else {
                mem.deallocate()
                continue
            }
            simplePolygons.append(polygon)
            simpleArenas.append(mem)
        }
        guard !simplePolygons.isEmpty else { return [] }

        let polygonsMem = arena(polygonsArenaSize)
        let polygons = simplePolygons.withUnsafeMutableBufferPointer { buffer in
            manifold_polygons(polygonsMem, buffer.baseAddress, buffer.count)
        }
        guard let polygons else {
            polygonsMem.deallocate()
            return []
        }
        defer {
            manifold_destruct_polygons(polygons)
            polygonsMem.deallocate()
        }

        let unionMem = arena(crossSectionArenaSize)
        guard let union = manifold_cross_section_of_polygons(unionMem, polygons, MANIFOLD_FILL_RULE_NON_ZERO) else {
            unionMem.deallocate()
            return []
        }
        defer {
            manifold_destruct_cross_section(union)
            unionMem.deallocate()
        }

        var shrunk = union
        var shrunkMem: UnsafeMutableRawPointer?
        if inset > 0 {
            let mem = arena(crossSectionArenaSize)
            guard let offset = manifold_cross_section_offset(
                mem, union, -inset, MANIFOLD_JOIN_TYPE_MITER, cornerLimit, 0
            ) else {
                mem.deallocate()
                return []
            }
            shrunk = offset
            shrunkMem = mem
        }
        defer {
            if let shrunkMem {
                manifold_destruct_cross_section(shrunk)
                shrunkMem.deallocate()
            }
        }
        guard manifold_cross_section_is_empty(shrunk) == 0 else { return [] }

        let outMem = arena(polygonsArenaSize)
        guard let out = manifold_cross_section_to_polygons(outMem, shrunk) else {
            outMem.deallocate()
            return []
        }
        defer {
            manifold_destruct_polygons(out)
            outMem.deallocate()
        }
        var contours: [[Vec2]] = []
        for polygonIndex in 0..<manifold_polygons_length(out) {
            let count = manifold_polygons_simple_length(out, polygonIndex)
            var contour: [Vec2] = []
            contour.reserveCapacity(count)
            for pointIndex in 0..<count {
                let p = manifold_polygons_get_point(out, polygonIndex, pointIndex)
                contour.append(Vec2(x: p.x, y: p.y))
            }
            contours.append(contour)
        }
        return contours
    }
}
