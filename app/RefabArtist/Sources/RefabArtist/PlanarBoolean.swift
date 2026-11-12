import CManifold
import Foundation

/// Boolean operations on flat part outlines, through Manifold's 2D
/// `CrossSection` (Clipper2) API.
enum PlanarBoolean {
    /// The material left when every disc in `discs` is cut out of the region
    /// bounded by `outline`. Each returned loop is closed (no repeated first
    /// point); outer boundaries wind counter-clockwise and holes clockwise.
    /// Returns nil when Manifold rejects the input.
    ///
    /// Discs are polygons of `segments` sides with their vertices on the
    /// circle.
    static func subtractingDiscs(
        _ discs: [(center: Vec2, radius: Double)],
        from outline: [Vec2],
        segments: Int = 64
    ) -> [[Vec2]]? {
        guard outline.count >= 3 else { return nil }
        let rings = discs.filter { $0.radius > 0 }.map { disc in
            (0..<segments).map { k -> Vec2 in
                let angle = Double(k) * 2 * .pi / Double(segments)
                return Vec2(
                    x: disc.center.x + disc.radius * cos(angle),
                    y: disc.center.y + disc.radius * sin(angle)
                )
            }
        }
        guard !rings.isEmpty else { return [outline] }
        return difference(of: [outline], minus: rings)
    }

    /// The material left when every polygon in `cuts` is cut out of the
    /// region bounded by `rings`: outer boundaries counter-clockwise and holes
    /// clockwise (the region is their non-zero fill). The cuts may overlap one
    /// another and wind either way. Where two cuts come closer than
    /// `bridging`, the strip between them is cut away too, so no web of
    /// material thinner than that is left between them; the cuts' own edges
    /// and corners stay where they are. Loops come back as from
    /// `subtractingDiscs`. Returns nil when Manifold rejects the input.
    static func subtracting(_ cuts: [[Vec2]], from rings: [[Vec2]], bridging: Double = 0) -> [[Vec2]]? {
        guard rings.contains(where: { $0.count >= 3 }) else { return nil }
        let counterClockwiseCuts = cuts.filter { $0.count >= 3 }.map { cut in
            signedArea(cut) < 0 ? Array(cut.reversed()) : cut
        }
        guard !counterClockwiseCuts.isEmpty else { return difference(of: rings, minus: []) }
        return difference(of: rings, minus: counterClockwiseCuts, closingBy: max(0, bridging) / 2)
    }

    /// The union of `rings` (non-zero fill, so they may overlap), closed by
    /// `closingBy` (grown by that much and shrunk back, which joins rings
    /// that touch along an edge but were rounded apart), then opened by
    /// `openingBy` (shrunk and grown back, which drops material narrower
    /// than twice that), less the union of `cuts`. Loops come back as from
    /// `subtractingDiscs`. Returns nil when Manifold rejects the input.
    static func joining(_ rings: [[Vec2]], closingBy: Double, openingBy: Double = 0, minus cuts: [[Vec2]] = []) -> [[Vec2]]? {
        guard var material = crossSection(of: rings.filter { $0.count >= 3 }) else { return nil }
        defer { material.release() }
        if closingBy > 0 {
            guard let grown = offset(material, by: closingBy) else { return nil }
            defer { grown.release() }
            guard let closed = offset(grown, by: -closingBy) else { return nil }
            material.release()
            material = closed
        }
        if openingBy > 0 {
            // Shrunk and grown back: material narrower than twice this goes.
            // Mitred corners can grow back a hair past where they were, so
            // what is kept is also cut to the material before.
            guard let shrunk = offset(material, by: -openingBy) else { return nil }
            defer { shrunk.release() }
            guard let opened = offset(shrunk, by: openingBy) else { return nil }
            defer { opened.release() }
            let memory = arena(crossSectionArenaSize)
            guard let kept = manifold_cross_section_intersection(memory, material.section, opened.section) else {
                memory.deallocate()
                return nil
            }
            material.release()
            material = OwnedSection(section: kept, memory: memory)
        }
        let counterClockwiseCuts = cuts.filter { $0.count >= 3 }.map { cut in
            signedArea(cut) < 0 ? Array(cut.reversed()) : cut
        }
        guard !counterClockwiseCuts.isEmpty else { return loops(of: material.section) }
        guard let cutSection = crossSection(of: counterClockwiseCuts) else { return nil }
        defer { cutSection.release() }
        let resultMem = arena(crossSectionArenaSize)
        guard let result = manifold_cross_section_difference(resultMem, material.section, cutSection.section) else {
            resultMem.deallocate()
            return nil
        }
        defer {
            manifold_destruct_cross_section(result)
            resultMem.deallocate()
        }
        return loops(of: result)
    }

    /// Where the non-zero fills of `lhs` and `rhs` overlap. Loops come back
    /// as from `subtractingDiscs`. Returns nil when Manifold rejects the
    /// input.
    static func intersecting(_ lhs: [[Vec2]], _ rhs: [[Vec2]]) -> [[Vec2]]? {
        guard let a = crossSection(of: lhs.filter { $0.count >= 3 }) else { return nil }
        defer { a.release() }
        guard let b = crossSection(of: rhs.filter { $0.count >= 3 }) else { return nil }
        defer { b.release() }
        let memory = arena(crossSectionArenaSize)
        guard let result = manifold_cross_section_intersection(memory, a.section, b.section) else {
            memory.deallocate()
            return nil
        }
        defer {
            manifold_destruct_cross_section(result)
            memory.deallocate()
        }
        return loops(of: result)
    }

    /// The region `rings` enclose counted even-odd (a point inside an odd
    /// number of them is inside), as clean loops: outer boundaries
    /// counter-clockwise and holes clockwise, none crossing or touching
    /// another. Rings may wind either way, overlap or cross themselves.
    /// With `closingBy`, the region is grown by that much and shrunk back,
    /// which fills notches and holes narrower than twice it. Returns nil
    /// when Manifold rejects the input.
    static func evenOddRegion(_ rings: [[Vec2]], closingBy: Double = 0) -> [[Vec2]]? {
        guard var section = crossSection(of: rings, fillRule: MANIFOLD_FILL_RULE_EVEN_ODD) else { return nil }
        defer { section.release() }
        if closingBy > 0 {
            guard let grown = offset(section, by: closingBy) else { return nil }
            defer { grown.release() }
            guard let closed = offset(grown, by: -closingBy) else { return nil }
            section.release()
            section = closed
        }
        return loops(of: section.section)
    }

    /// The non-zero fill of `material` minus the union of `cuts`, that union
    /// first closed (grown then shrunk back) by `closingBy`.
    private static func difference(of material: [[Vec2]], minus cuts: [[Vec2]], closingBy: Double = 0) -> [[Vec2]]? {
        guard let materialSection = crossSection(of: material) else { return nil }
        defer { materialSection.release() }
        guard !cuts.isEmpty else { return loops(of: materialSection.section) }
        guard var cutSection = crossSection(of: cuts) else { return nil }
        defer { cutSection.release() }
        if closingBy > 0 {
            guard let grown = offset(cutSection, by: closingBy) else { return nil }
            defer { grown.release() }
            guard let closed = offset(grown, by: -closingBy) else { return nil }
            cutSection.release()
            cutSection = closed
        }

        let resultMem = arena(crossSectionArenaSize)
        guard let result = manifold_cross_section_difference(resultMem, materialSection.section, cutSection.section) else {
            resultMem.deallocate()
            return nil
        }
        defer {
            manifold_destruct_cross_section(result)
            resultMem.deallocate()
        }
        return loops(of: result)
    }

    /// `section` grown by `delta` (shrunk when negative) with mitred corners,
    /// so square corners come back square.
    private static func offset(_ section: OwnedSection, by delta: Double) -> OwnedSection? {
        let memory = arena(crossSectionArenaSize)
        guard let result = manifold_cross_section_offset(memory, section.section, delta, MANIFOLD_JOIN_TYPE_MITER, 4, 0) else {
            memory.deallocate()
            return nil
        }
        return OwnedSection(section: result, memory: memory)
    }

    private static func signedArea(_ ring: [Vec2]) -> Double {
        var area = 0.0
        for index in ring.indices {
            let next = ring[(index + 1) % ring.count]
            area += ring[index].x * next.y - next.x * ring[index].y
        }
        return area / 2
    }

    // MARK: - Manifold plumbing

    private static let simplePolygonArenaSize = manifold_simple_polygon_size()
    private static let polygonsArenaSize = manifold_polygons_size()
    private static let crossSectionArenaSize = manifold_cross_section_size()

    private static func arena(_ size: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    }

    /// A cross-section and the memory it lives in.
    private struct OwnedSection {
        var section: OpaquePointer
        var memory: UnsafeMutableRawPointer

        func release() {
            manifold_destruct_cross_section(section)
            memory.deallocate()
        }
    }

    /// The union of `rings` (non-zero fill unless `fillRule` says
    /// otherwise), or nil when Manifold rejects them.
    private static func crossSection(of rings: [[Vec2]], fillRule: ManifoldFillRule = MANIFOLD_FILL_RULE_NON_ZERO) -> OwnedSection? {
        var simple: [OpaquePointer?] = []
        var simpleMemory: [UnsafeMutableRawPointer] = []
        defer {
            for (index, polygon) in simple.enumerated() {
                if let polygon { manifold_destruct_simple_polygon(polygon) }
                simpleMemory[index].deallocate()
            }
        }
        for ring in rings where ring.count >= 3 {
            var points = ring.map { ManifoldVec2(x: $0.x, y: $0.y) }
            let memory = arena(simplePolygonArenaSize)
            let polygon = points.withUnsafeMutableBufferPointer { buffer in
                manifold_simple_polygon(memory, buffer.baseAddress, buffer.count)
            }
            guard polygon != nil else {
                memory.deallocate()
                continue
            }
            simple.append(polygon)
            simpleMemory.append(memory)
        }
        guard !simple.isEmpty else { return nil }

        let polygonsMemory = arena(polygonsArenaSize)
        guard let polygons = simple.withUnsafeMutableBufferPointer({ buffer in
            manifold_polygons(polygonsMemory, buffer.baseAddress, buffer.count)
        }) else {
            polygonsMemory.deallocate()
            return nil
        }
        defer {
            manifold_destruct_polygons(polygons)
            polygonsMemory.deallocate()
        }

        let memory = arena(crossSectionArenaSize)
        guard let section = manifold_cross_section_of_polygons(memory, polygons, fillRule) else {
            memory.deallocate()
            return nil
        }
        return OwnedSection(section: section, memory: memory)
    }

    private static func loops(of section: OpaquePointer) -> [[Vec2]]? {
        guard manifold_cross_section_is_empty(section) == 0 else { return [] }
        let memory = arena(polygonsArenaSize)
        guard let polygons = manifold_cross_section_to_polygons(memory, section) else {
            memory.deallocate()
            return nil
        }
        defer {
            manifold_destruct_polygons(polygons)
            memory.deallocate()
        }
        var loops: [[Vec2]] = []
        for polygonIndex in 0..<manifold_polygons_length(polygons) {
            let count = manifold_polygons_simple_length(polygons, polygonIndex)
            guard count >= 3 else { continue }
            loops.append((0..<count).map { pointIndex in
                let point = manifold_polygons_get_point(polygons, polygonIndex, pointIndex)
                return Vec2(x: point.x, y: point.y)
            })
        }
        return loops
    }
}
