import Foundation

/// Stack-global dowel placement. Dowels are RODS passing through the whole
/// stack, so every slice's hole must sit at the SAME world XY — the old
/// per-slice placement put holes at each slice's own bounding-box corners,
/// which only line up on prisms; on an organic stack the rod could never
/// thread. Positions are the four inset corners of the UNION of all slice
/// bounds (identical to the old per-slice corners on prisms, so the cube
/// fixtures stay byte-stable), and a slice only gets a hole where its
/// material actually covers the position.
enum DowelLayout {
    /// One dowel rod: where it stands and which layers it threads.
    struct Placement: Equatable {
        var position: Vec2
        var firstLayer: Int
        var lastLayer: Int
    }

    /// Coverage-scored placement: rods stand where they pass through the MOST
    /// slices' material (with edge clearance), not at bounding-box corners —
    /// an organic model doesn't occupy its bbox corners, so corner rods stood
    /// in thin air touching nothing. Returns up to `automaticCount`
    /// well-separated rods (greedy best-coverage-first; the separation
    /// requirement relaxes if the model can't fit the requested count).
    static func placements(layers: [SliceContourLayer], settings: DxfExporter.DowelSettings?) -> [Placement] {
        guard let settings, settings.enabled, settings.diameter > 0, layers.count >= 2 else {
            return []
        }
        // Manual placement wins: the user clicked these spots on the sheet.
        // An empty manual list means ZERO rods (the user deleted them all) —
        // falling back to automatic here resurrected deleted dowels.
        if let manual = settings.manualPositions {
            return manual.compactMap { position in
                var first = -1
                var last = -1
                for (index, layer) in layers.enumerated() {
                    if positionsCovered(by: layer, positions: [position]).isEmpty { continue }
                    if first < 0 { first = index }
                    last = index
                }
                guard first >= 0 else { return nil }
                return Placement(position: position, firstLayer: first, lastLayer: last)
            }
        }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var decimated: [[[Vec2]]] = []
        for layer in layers {
            var loops: [[Vec2]] = []
            for path in layer.paths where path.closed {
                let points = decimate(path.points, maxPoints: 160)
                loops.append(points)
                for p in points {
                    minX = min(minX, p.x)
                    minY = min(minY, p.y)
                    maxX = max(maxX, p.x)
                    maxY = max(maxY, p.y)
                }
            }
            decimated.append(loops)
        }
        guard minX < maxX, minY < maxY else { return [] }

        let radius = settings.diameter / 2
        func insideMaterial(_ p: Vec2, _ loops: [[Vec2]]) -> Bool {
            var depth = 0
            for loop in loops where contains(loop, point: p) {
                depth += 1
            }
            return depth % 2 == 1
        }
        func coverage(_ p: Vec2, clearance: Double) -> (count: Int, first: Int, last: Int) {
            let probes = [
                p,
                Vec2(x: p.x + clearance, y: p.y),
                Vec2(x: p.x - clearance, y: p.y),
                Vec2(x: p.x, y: p.y + clearance),
                Vec2(x: p.x, y: p.y - clearance)
            ]
            var count = 0
            var first = -1
            var last = -1
            for (index, loops) in decimated.enumerated() where !loops.isEmpty {
                if probes.allSatisfy({ insideMaterial($0, loops) }) {
                    count += 1
                    if first < 0 { first = index }
                    last = index
                }
            }
            return (count, first, last)
        }

        func candidates(clearance: Double) -> [(score: Int, placement: Placement)] {
            let grid = 26
            var found: [(Int, Placement)] = []
            for yi in 0..<grid {
                for xi in 0..<grid {
                    let p = Vec2(
                        x: minX + (maxX - minX) * (Double(xi) + 0.5) / Double(grid),
                        y: minY + (maxY - minY) * (Double(yi) + 0.5) / Double(grid)
                    )
                    let c = coverage(p, clearance: clearance)
                    if c.count >= max(2, layers.count / 4), c.first >= 0 {
                        found.append((c.count, Placement(position: p, firstLayer: c.first, lastLayer: c.last)))
                    }
                }
            }
            return found.sorted { $0.0 > $1.0 }
        }

        var ranked = candidates(clearance: radius + max(settings.inset, 1))
        if ranked.isEmpty {
            // Nothing satisfies the requested inset — relax to bare clearance
            // so the feature still works on slender models.
            ranked = candidates(clearance: radius + 0.5)
        }
        guard !ranked.isEmpty else { return [] }

        func distance(_ a: Vec2, _ b: Vec2) -> Double {
            let dx = a.x - b.x
            let dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }

        let target = min(max(settings.automaticCount, 1), 16)
        let span = max(maxX - minX, maxY - minY)
        var separation = span * 0.3
        var result: [Placement] = []
        // Greedy: best coverage first, each next rod keeping its distance
        // from the ones already standing. If the model can't fit the
        // requested count at this spacing, relax the spacing and fill.
        while result.count < target, separation > span * 0.04 {
            for entry in ranked where result.count < target {
                if result.allSatisfy({ distance($0.position, entry.placement.position) >= separation }) {
                    result.append(entry.placement)
                }
            }
            separation *= 0.6
        }
        return result
    }

    private static func decimate(_ loop: [Vec2], maxPoints: Int) -> [Vec2] {
        guard loop.count > maxPoints else { return loop }
        let stride = Double(loop.count) / Double(maxPoints)
        return (0..<maxPoints).map { loop[min(loop.count - 1, Int(Double($0) * stride))] }
    }

    /// Compatibility wrapper: just the rod positions.
    static func globalPositions(layers: [SliceContourLayer], settings: DxfExporter.DowelSettings?) -> [Vec2] {
        placements(layers: layers, settings: settings).map(\.position)
    }

    /// Even-odd point-in-polygon, for "does this slice's material cover the
    /// dowel position".
    static func contains(_ loop: [Vec2], point p: Vec2) -> Bool {
        var inside = false
        var j = loop.count - 1
        for i in loop.indices {
            let a = loop[i]
            let b = loop[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Positions covered by the material of a slice layer (inside an outer
    /// boundary; holes ignored — a dowel through a hole simply gets no hole
    /// drilled in that slice anyway since the material is absent).
    static func positionsCovered(by layer: SliceContourLayer, positions: [Vec2]) -> [Vec2] {
        let loops = layer.paths.filter(\.closed).map(\.points)
        guard !loops.isEmpty else { return [] }
        return positions.filter { p in
            var depth = 0
            for loop in loops where contains(loop, point: p) {
                depth += 1
            }
            return depth % 2 == 1
        }
    }
}
