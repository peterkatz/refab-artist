import Foundation

/// The radial "Relief Type" dropdown.
///
/// A round cutter (an end mill) cannot cut a square inside corner: it leaves
/// a fillet of its own radius at the bottom of every ring notch and fin slot,
/// and the square edge of the part that seats there stops on it. A relief is
/// a circle of the tool diameter cut at each of those two corners, placed so
/// that the circle passes through the corner itself
/// (`RadialPartBuilder.reliefCuts`):
///
/// - `square`     — DEFAULT; plain square slot bottom, no relief (a laser or
///                  knife cuts square corners).
/// - `horizontal` — the circle sits on the slot bottom's line and digs past
///                  the bottom, along the slot.
/// - `vertical`   — the circle sits on the slot side's line and digs into the
///                  side, across the slot.
/// - `dogBone`    — the circle sits on the corner's diagonal and digs a little
///                  into both.
///
/// H/V/dogBone require toolDiameter > 0; the UI disables them when it is 0.
/// The raw value is persisted in `SlicerProjectSettings.radialReliefType`.
/// Legacy saved files that stored "horizontal" keep decoding as `.horizontal`.
enum RadialReliefType: String, CaseIterable, Identifiable, Codable {
    case square
    case horizontal
    case vertical
    case dogBone

    var id: String { rawValue }

    /// The CLI's name for it (`--relief-type`).
    var cliValue: String {
        switch self {
        case .square: return "square"
        case .horizontal: return "horizontal"
        case .vertical: return "vertical"
        case .dogBone: return "dog-bone"
        }
    }

    static func cliValue(_ raw: String) -> RadialReliefType? {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        return allCases.first { $0.cliValue == key || $0.rawValue.lowercased() == key }
    }

    var label: String {
        switch self {
        case .square:     return "Square"
        case .horizontal: return "Horizontal"
        case .vertical:   return "Vertical"
        case .dogBone:    return "Dog Bone"
        }
    }

    /// Whether this relief type requires a non-zero tool diameter.
    var requiresToolDiameter: Bool {
        switch self {
        case .square: return false
        case .horizontal, .vertical, .dogBone: return true
        }
    }
}

struct RadialSlicePlan: Equatable {
    var center: Vec3
    var radius: Double
    var angles: [Double]
    var slotWidth: Double
    var slotAngleDegrees: Double

    // --- Disk + wedge ("waffle" radial) data ----------------------------
    // These carry the data `RadialPartBuilder` needs; they default to
    // neutral values so a bare plan stays valid.
    //
    // `nRadial` is the requested angular-wedge count (0 => the radial mode
    // degrades to Interlocked). `primary` is the registration stack that
    // always runs along the Z slice normal. `secondary` is the perpendicular
    // ("Y") Interlocked leg, present only when nRadial == 0.
    // `materialThickness` is the stock the rings and fins are cut from: it
    // sets how far from the hub the fins start. Ring notches and fin slots
    // are `slotWidth` wide.
    var nRadial: Int = 0
    var materialThickness: Double = 5
    var slotClearance: Double = 0
    var primary: StackedSlicePlan? = nil
    var secondary: StackedSlicePlan? = nil
    var bounds: Bounds3D? = nil
    // The radial "Notch Factor", read from older project files and kept with
    // the project. It does not change the joints: a notch narrower than the
    // stock it seats cannot take it, so ring notches and fin slots are always
    // `slotWidth` wide (the stock plus the slot offset, or the notch-width
    // override). Plan call sites default to 1.
    var notchFactor: Double = 1
    /// Relief cut at the inside corners of every ring notch and fin slot.
    var reliefType: RadialReliefType = .square
    /// Diameter (mm) of the tool the relief is cut for. 0 = no relief even if
    /// reliefType is non-square.
    var toolDiameter: Double = 0
    /// The number of rings asked for (By Count), when fewer stand along the
    /// model in the plan's stock without passing through each other; nil
    /// when all of them do.
    var requestedRingCount: Int? = nil
    /// The ring spacing asked for (By Distance), when it is closer than the
    /// rings' stock allows; nil when it is not.
    var requestedRingSpacing: Double? = nil

    init(center: Vec3, radius: Double, angles: [Double], slotWidth: Double = 3, slotAngleDegrees: Double = 0) {
        self.center = center
        self.radius = radius
        self.angles = angles
        self.slotWidth = max(0.1, slotWidth)
        self.slotAngleDegrees = min(60, max(0, slotAngleDegrees))
    }

    var sliceCount: Int {
        angles.count
    }

    /// Rings + fins: the primary stack plus the angular fin positions.
    var totalPartCount: Int {
        (primary?.sliceCount ?? 0) + angles.count
    }

    /// Build the Interlocked-equivalent plan for the `n_radial == 0` fallback
    /// (one Z primary stack + one Y secondary stack). Returns nil unless both
    /// the primary and secondary legs and the bounds have been populated by
    /// `RadialSlicePlanner.plan`.
    func interlockedFallbackPlan() -> InterlockedSlicePlan? {
        guard let primary, let secondary, let bounds else { return nil }
        return InterlockedSlicePlan(
            primary: primary,
            secondary: secondary,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            slotWidth: max(0.1, slotWidth),
            slotAngleDegrees: min(60, max(0, slotAngleDegrees)),
            slotRelief: .disabled,
            bounds: bounds
        )
    }
}

extension RadialSlicePlan {
    /// Whether relief circles are cut at the notch and slot corners.
    var cutsRelief: Bool {
        reliefType.requiresToolDiameter && toolDiameter > 0
    }

    /// The closest two rings stand (mm), centre to centre: a slot width (the
    /// stock plus the slot offset, or the notch-width override), and never
    /// less than the stock, so neighbouring rings' stock never overlaps.
    var minimumRingSpacing: Double {
        RadialSlicePlanner.minimumRingSpacing(materialThickness: materialThickness, slotWidth: slotWidth)
    }

    /// What the app says under 1st Axis, and the CLI notes, when the rings
    /// were set further apart than asked; nil when they were not.
    var ringCountNote: String? {
        let spacing = Self.millimetres(minimumRingSpacing)
        let stock = Self.millimetres(materialThickness)
        if let requested = requestedRingCount {
            let count = primary?.sliceCount ?? 0
            let fit = count == 1 ? "Only 1 ring fits" : "Only \(count) rings fit"
            return "\(fit) along this model in \(stock) mm stock (\(requested) asked for); "
                + "rings closer than \(spacing) mm would pass through each other. Use thinner stock for more."
        }
        if let requested = requestedRingSpacing {
            return "Rings stand \(spacing) mm apart in \(stock) mm stock (\(Self.millimetres(requested)) mm asked for); "
                + "closer rings would pass through each other."
        }
        return nil
    }

    /// The largest tool whose relief leaves the middle of a notch bottom
    /// alone, so the joint stays snug. Past the bottom the two corners'
    /// circles leave `w − 2D` of material between them for Horizontal
    /// relief and `w − √2·D` for Dog Bone (slot width `w`, tool `D`); under
    /// the 1 mm web the cuts keep (`CurveJointPlanner.minimumWeb`) that is
    /// cut away too, and the slot bottom moves. Vertical relief digs only
    /// into the sides. nil without relief.
    var largestSnugReliefTool: Double? {
        guard cutsRelief else { return nil }
        let web = CurveJointPlanner.minimumWeb
        switch reliefType {
        case .square: return nil
        case .horizontal: return (slotWidth - web) / 2
        case .vertical: return slotWidth
        case .dogBone: return (slotWidth - web) / 2.squareRoot()
        }
    }

    /// What the app says under Relief Type, and the CLI notes, when the
    /// relief cannot be cut as asked, would loosen the joints, or would cut
    /// the fins apart between their slots; nil when it is fine.
    var reliefNote: String? {
        guard let limit = largestSnugReliefTool else { return nil }
        let tool = Self.millimetres(toolDiameter)
        let width = Self.millimetres(slotWidth)
        if toolDiameter > slotWidth + 1.0e-9 {
            return "A \(tool) mm tool is wider than the \(width) mm notches, so it cannot cut them. Use a thinner tool."
        }
        if toolDiameter > limit + 1.0e-9 {
            return "With a \(tool) mm tool, \(reliefType.label) relief digs past the middle of each \(width) mm notch bottom, "
                + "so the joints sit loose. Use a tool up to \(Self.millimetres(limit)) mm, or Vertical relief."
        }
        // Between two neighbouring rings a fin keeps a web as tall as the
        // ring spacing less the slot width. Relief that digs into the slot
        // sides takes some of it from either side: all of the tool for
        // Vertical, 1 − 1/√2 of it for Dog Bone. What is left under 1 mm is
        // cut away with the slots, and the fin comes apart there.
        let positions = primary?.positions ?? []
        let spacing = zip(positions, positions.dropFirst()).map { $1 - $0 }.min() ?? .infinity
        let web = spacing - slotWidth
        let dug: Double
        switch reliefType {
        case .vertical: dug = toolDiameter
        case .dogBone: dug = toolDiameter * (1 - 1 / 2.squareRoot())
        case .square, .horizontal: dug = 0
        }
        if web.isFinite, web >= CurveJointPlanner.minimumWeb, dug > web - CurveJointPlanner.minimumWeb + 1.0e-9 {
            return "With a \(tool) mm tool, \(reliefType.label) relief leaves less than 1 mm of the \(Self.millimetres(web)) mm of fin "
                + "between neighbouring slots, so the fins can come apart there. Use a smaller tool, Dog Bone relief, or rings further apart."
        }
        return nil
    }

    fileprivate static func millimetres(_ value: Double) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }
}

struct RadialSliceLayer: Equatable {
    var angle: Double
    var paths: [SlicePath2D]
}

struct RadialSliceContours: Equatable {
    var center: Vec3
    var layers: [RadialSliceLayer]
}

enum RadialSlicePlanner {
    private static let minimumSlotWidth = 0.1
    /// How far (mm) a ring is moved off a flat face of the model that its
    /// plane would run along: there the section is ambiguous (the faces of
    /// two blocks that meet there, or a face and the open air), so the ring
    /// is cut just below it, where the section is the one the slicer takes.
    static let flatFaceClearance = 0.01

    /// The closest two rings may stand, centre to centre: their stock plus
    /// the slot offset (a slot width), and never less than the stock.
    static func minimumRingSpacing(materialThickness: Double, slotWidth: Double) -> Double {
        max(materialThickness, slotWidth)
    }

    /// Build the radial plan: the axial primary ("rings") stack plus the
    /// `nRadial` angular wedge ("fins") positions. This single entry point
    /// serves the GUI cut sheet, viewport and the vector + mesh writers —
    /// they all share the disk+wedge part geometry. It accepts `nRadial == 0` — the
    /// degrade-to-Interlocked case — and populates the axial primary stack
    /// plus, for the fallback, the perpendicular secondary stack.
    ///
    /// Mechanism:
    ///   * The primary registration stack uses the by-count Interlocked
    ///     family along the default Z slice normal, with no more rings than
    ///     stand `minimumRingSpacing` apart (By Distance: no closer), each
    ///     moved off any flat face of the model it would lie in
    ///     (`ringPositions`).
    ///     Do not reuse Interlocked's longest-axis heuristic here: radial's
    ///     first-axis rings are a user-facing choice, and rotating that axis on
    ///     elongated organic imports would make the rings jump to a different
    ///     axis than the one the user picked.
    ///   * The secondary family is the Interlocked secondary on the
    ///     perpendicular (Y) axis: a single central plank for `n_radial == 0`,
    ///     or `max(n_radial, interlockedDefaultFamilyCount)` planks (the
    ///     wedge family) otherwise. `angles` records the uniform `i·2π/nRadial`
    ///     wedge positions for downstream callers; the part geometry itself
    ///     is produced by the part builders from the primary/secondary plans.
    static func plan(
        model: MeshSummary,
        nRadial: Int,
        materialThickness: Double,
        slotClearance: Double = 0,
        notchWidthOverride: Double? = nil,
        slotAngleDegrees: Double = 0,
        firstAxisCountOverride: Int? = nil,
        firstAxisSpacingOverride: Double? = nil,
        notchFactor: Double = 1,
        reliefType: RadialReliefType = .square,
        toolDiameter: Double = 0
    ) -> RadialSlicePlan? {
        guard let bounds = model.bounds, materialThickness.isFinite, materialThickness > 0 else {
            return nil
        }
        let center = Vec3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        let spanX = bounds.max.x - bounds.min.x
        let spanY = bounds.max.y - bounds.min.y
        let radius = max(spanX, spanY) / 2

        // Wedge angular positions: uniform 2π/nRadial spacing about the radial
        // axis. Empty for the n0 fallback.
        let count = max(0, nRadial)
        let angles = count > 0
            ? (0..<count).map { Double($0) * 2.0 * .pi / Double(count) }
            : []

        // Primary registration stack. It uses the symmetric by-count
        // Interlocked family (`distributeEvenly`, NOT the asymmetric Letter
        // reslice) but keeps the radial first-axis normal.
        let primaryAxis: SliceAxis = .z
        let slotWidth = max(minimumSlotWidth, notchWidthOverride ?? materialThickness + slotClearance)
        // Rings are slabs of stock: closer together than their stock they
        // would pass through each other. So they stand at least a slot width
        // apart (`minimumRingSpacing`), and fewer are cut than asked for when
        // more would not fit.
        let ringSpacing = minimumRingSpacing(materialThickness: materialThickness, slotWidth: slotWidth)
        // 1st-axis distribution (the Slice Distribution panel):
        // By Distance reslices with the by-distance rule (slice_depth spaces
        // the rings independent of stock depth — the part thickness stays the
        // material thickness); By Count overrides the family count. Without an
        // override the 10-slice default family stands.
        var primary: StackedSlicePlan?
        var requestedRingCount: Int?
        var requestedRingSpacing: Double?
        if let spacing = firstAxisSpacingOverride, spacing.isFinite, spacing > 0 {
            if spacing < ringSpacing - 1.0e-9 {
                requestedRingSpacing = spacing
            }
            primary = StackedSlicePlanner.planLetterReslice(model: model, axis: primaryAxis, sliceDepth: max(spacing, ringSpacing)).map {
                StackedSlicePlan(
                    axis: $0.axis,
                    materialThickness: materialThickness,
                    rangeMin: $0.rangeMin,
                    rangeMax: $0.rangeMax,
                    positions: $0.positions
                )
            }
        } else {
            let requested = max(1, min(
                firstAxisCountOverride ?? StackedSlicePlanner.interlockedDefaultFamilyCount,
                StackedSlicePlanner.maxOverrideCount
            ))
            let extent = bounds.max.z - bounds.min.z
            // Evenly spread rings stand extent / count apart.
            let fitting = max(1, Int((abs(extent) / ringSpacing + 1.0e-9).rounded(.down)))
            if requested > fitting {
                requestedRingCount = requested
            }
            primary = StackedSlicePlanner.planInterlockedFamily(
                model: model, axis: primaryAxis, materialThickness: materialThickness, sliceCountOverride: min(requested, fitting)
            )
        }
        if var rings = primary {
            rings.positions = ringPositions(rings.positions, model: model, axis: primaryAxis)
            primary = rings
        }
        // Secondary registration family. Two regimes:
        //   * n0 fallback: exactly ONE central Y plank (the "thin Y
        //     secondary") — a single registration slice through the model
        //     centre carrying one mating slot per primary disk.
        //   * n_radial > 0: the radial wedge family. This secondary plan is
        //     retained only for the degenerate fallback guard in the DXF writer;
        //     the real radial path builds wedges from `RadialPartBuilder`
        //     using `RadialPartBuilder.wedgeCount` (n4 → 4, n6 → 6, n8 → 10,
        //     n12 → 12).
        let secondaryCount = count == 0
            ? 1
            : max(count, StackedSlicePlanner.interlockedDefaultFamilyCount)
        let secondary = StackedSlicePlanner.planInterlockedFamily(
            model: model, axis: .y, materialThickness: materialThickness, sliceCountOverride: secondaryCount
        )

        var plan = RadialSlicePlan(
            center: center,
            radius: radius,
            angles: angles,
            slotWidth: slotWidth,
            slotAngleDegrees: min(60, max(0, slotAngleDegrees))
        )
        plan.nRadial = count
        plan.materialThickness = materialThickness
        plan.slotClearance = slotClearance
        plan.primary = primary
        plan.secondary = secondary
        plan.bounds = bounds
        plan.notchFactor = notchFactor.isFinite && notchFactor > 0 ? notchFactor : 1
        plan.reliefType = reliefType
        plan.toolDiameter = max(0, toolDiameter.isFinite ? toolDiameter : 0)
        plan.requestedRingCount = requestedRingCount
        plan.requestedRingSpacing = requestedRingSpacing
        return plan
    }

    /// `positions` with every ring that would lie along a flat face of the
    /// model (a horizontal triangle in its plane) moved just off it
    /// (`flatFaceClearance`): below it, or above it where nothing of the
    /// model lies below.
    static func ringPositions(_ positions: [Double], model: MeshSummary, axis: SliceAxis) -> [Double] {
        let vertices = model.geometry.vertices
        let indices = model.geometry.triangleIndices
        func coordinate(_ point: Vec3) -> Double {
            switch axis {
            case .x: return point.x
            case .y: return point.y
            case .z: return point.z
            }
        }
        var flat: [Double] = []
        var lowest = Double.infinity
        var index = 0
        while index + 2 < indices.count {
            let corners = [indices[index], indices[index + 1], indices[index + 2]].map(Int.init)
            index += 3
            guard corners.allSatisfy(vertices.indices.contains) else { continue }
            let heights = corners.map { coordinate(vertices[$0]) }
            lowest = min(lowest, heights.min() ?? lowest)
            if let low = heights.min(), let high = heights.max(), high - low <= 1.0e-9 {
                flat.append(low)
            }
        }
        guard !flat.isEmpty else { return positions }
        func onFlatFace(_ position: Double) -> Bool {
            flat.contains { abs($0 - position) <= 1.0e-6 }
        }
        return positions.map { position in
            guard onFlatFace(position) else { return position }
            let step = position - flatFaceClearance > lowest ? -flatFaceClearance : flatFaceClearance
            var moved = position + step
            while onFlatFace(moved) {
                moved += step
            }
            return moved
        }
    }
}

enum RadialSliceContourer {
    private static let epsilon = 1.0e-7

    static func generate(model: MeshSummary, plan: RadialSlicePlan) -> RadialSliceContours {
        let triangles = model.geometry.triangleIndices.chunked(into: 3).compactMap { indices -> (Vec3, Vec3, Vec3)? in
            guard indices.count == 3 else { return nil }
            let a = Int(indices[0])
            let b = Int(indices[1])
            let c = Int(indices[2])
            guard model.geometry.vertices.indices.contains(a),
                  model.geometry.vertices.indices.contains(b),
                  model.geometry.vertices.indices.contains(c) else {
                return nil
            }
            return (model.geometry.vertices[a], model.geometry.vertices[b], model.geometry.vertices[c])
        }

        let layers = plan.angles.map { angle in
            let direction = horizontalDirection(angle: angle)
            let normal = Vec2(x: -direction.y, y: direction.x)
            var segments: [Segment2D] = []
            for triangle in triangles {
                if let segment = intersect(triangle: triangle, center: plan.center, direction: direction, normal: normal) {
                    segments.append(segment)
                }
            }
            return RadialSliceLayer(angle: angle, paths: join(segments: segments))
        }
        return RadialSliceContours(center: plan.center, layers: layers)
    }

    static func scenePoint(_ point: Vec2, center: Vec3, angle: Double) -> Vec3 {
        let direction = horizontalDirection(angle: angle)
        return Vec3(
            x: center.x + direction.x * point.x,
            y: center.y + direction.y * point.x,
            z: point.y
        )
    }

    private struct Segment2D {
        var a: Vec2
        var b: Vec2
    }

    private static func horizontalDirection(angle: Double) -> Vec2 {
        Vec2(x: cos(angle), y: sin(angle))
    }

    private static func signedDistance(_ point: Vec3, center: Vec3, normal: Vec2) -> Double {
        (point.x - center.x) * normal.x + (point.y - center.y) * normal.y
    }

    private static func intersect(
        triangle: (Vec3, Vec3, Vec3),
        center: Vec3,
        direction: Vec2,
        normal: Vec2
    ) -> Segment2D? {
        var points: [Vec3] = []
        collectEdgeIntersection(points: &points, start: triangle.0, end: triangle.1, center: center, normal: normal)
        collectEdgeIntersection(points: &points, start: triangle.1, end: triangle.2, center: center, normal: normal)
        collectEdgeIntersection(points: &points, start: triangle.2, end: triangle.0, center: center, normal: normal)
        guard points.count == 2, !samePoint(points[0], points[1]) else {
            return nil
        }
        return Segment2D(
            a: project(points[0], center: center, direction: direction),
            b: project(points[1], center: center, direction: direction)
        )
    }

    private static func project(_ point: Vec3, center: Vec3, direction: Vec2) -> Vec2 {
        Vec2(
            x: (point.x - center.x) * direction.x + (point.y - center.y) * direction.y,
            y: point.z
        )
    }

    private static func collectEdgeIntersection(points: inout [Vec3], start: Vec3, end: Vec3, center: Vec3, normal: Vec2) {
        let startDistance = signedDistance(start, center: center, normal: normal)
        let endDistance = signedDistance(end, center: center, normal: normal)
        if abs(startDistance) <= epsilon, abs(endDistance) <= epsilon {
            return
        }
        if abs(startDistance) <= epsilon {
            appendUnique(start, to: &points)
            return
        }
        if abs(endDistance) <= epsilon {
            appendUnique(end, to: &points)
            return
        }
        if (startDistance < 0 && endDistance > 0) || (startDistance > 0 && endDistance < 0) {
            let t = startDistance / (startDistance - endDistance)
            appendUnique(Vec3(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
                z: start.z + (end.z - start.z) * t
            ), to: &points)
        }
    }

    private static func appendUnique(_ point: Vec3, to points: inout [Vec3]) {
        guard !points.contains(where: { samePoint($0, point) }) else { return }
        points.append(point)
    }

    private static func join(segments: [Segment2D]) -> [SlicePath2D] {
        var used = Array(repeating: false, count: segments.count)
        var paths: [SlicePath2D] = []

        for startIndex in segments.indices where !used[startIndex] {
            var path = SlicePath2D(points: [segments[startIndex].a, segments[startIndex].b], closed: false)
            used[startIndex] = true

            var extended = true
            while extended {
                extended = false
                for index in segments.indices where !used[index] {
                    let segment = segments[index]
                    guard let first = path.points.first, let last = path.points.last else { continue }
                    if samePoint(last, segment.a) {
                        path.points.append(segment.b)
                    } else if samePoint(last, segment.b) {
                        path.points.append(segment.a)
                    } else if samePoint(first, segment.a) {
                        path.points.insert(segment.b, at: 0)
                    } else if samePoint(first, segment.b) {
                        path.points.insert(segment.a, at: 0)
                    } else {
                        continue
                    }
                    used[index] = true
                    extended = true
                }
            }

            if path.points.count > 2, let first = path.points.first, let last = path.points.last, samePoint(first, last) {
                path.closed = true
                path.points[path.points.count - 1] = first
            }
            simplifyCollinear(path: &path)
            paths.append(path)
        }

        return paths
    }

    private static func simplifyCollinear(path: inout SlicePath2D) {
        guard path.points.count >= 3 else { return }
        if path.closed, let first = path.points.first, let last = path.points.last, samePoint(first, last) {
            path.points.removeLast()
        }
        var changed = true
        while changed, path.points.count > (path.closed ? 3 : 2) {
            changed = false
            let count = path.points.count
            for index in 0..<count {
                if !path.closed, (index == 0 || index + 1 == count) {
                    continue
                }
                let previous = path.points[(index + count - 1) % count]
                let current = path.points[index]
                let next = path.points[(index + 1) % count]
                if collinear(previous, current, next) {
                    path.points.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        if path.closed, let first = path.points.first {
            path.points.append(first)
        }
    }

    private static func collinear(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        abs((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) <= epsilon
    }

    private static func samePoint(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private static func samePoint(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon && abs(lhs.z - rhs.z) <= epsilon
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
