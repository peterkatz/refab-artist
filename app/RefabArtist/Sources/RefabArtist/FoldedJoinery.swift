import Foundation

/// How the stock of two panels meets at a cut seam once the nets are folded
/// up.
///
/// Folded Panels puts the stock on the inside of the model surface: each
/// panel's net is the outside face of its piece, and the piece is
/// `thickness` deep behind it. At a seam, seen in section across the seam
/// line, the two pieces are two strips of stock that leave the seam point in
/// their own directions. Extended past their edges, the strips cross in a
/// parallelogram that touches the seam point. The band measures that
/// parallelogram from each panel's edge line, positive into the panel:
///
///   * `maleNear` … `maleFar`: where the male panel's strip runs through
///     the female panel's stock, measured across the seam in the male panel;
///   * `femaleNear` … `femaleFar`: the same in the female panel.
///
/// `plainTrim` is how far the male copy must be cut back so that its stock
/// clears the female panel's stock: the farthest point, measured in the
/// male panel, of the part of the parallelogram that lies inside the female
/// piece. For a square seam it is the stock thickness, so the male panel's
/// end rests on the female panel's inside face (a butt joint with a closed
/// corner); flatter seams need less, sharper seams more, and an inside
/// corner (where the two strips part) none.
struct FoldedSeamBand: Equatable {
    var maleNear: Double
    var maleFar: Double
    var femaleNear: Double
    var femaleFar: Double
    var plainTrim: Double

    /// The band for a seam, from each panel's direction into the panel
    /// across the seam (`maleInPlane`, `femaleInPlane`) and its inward
    /// normal (from the outside face into the stock), all unit vectors
    /// across the seam line. Nil when the two panels lie in one plane.
    init?(maleInPlane am: Vec3, maleInward nm: Vec3, femaleInPlane af: Vec3, femaleInward nf: Vec3, thickness t: Double) {
        // The section across the seam, with the male panel's direction into
        // the panel as x and its inward normal as y.
        let afx = Self.dot(af, am), afy = Self.dot(af, nm)
        let nfx = Self.dot(nf, am), nfy = Self.dot(nf, nm)
        guard abs(afy) > 1.0e-9, t > 0 else {
            return nil
        }
        // A point h deep in the male stock and hf deep in the female stock:
        // s across the male panel, sf across the female panel.
        func male(_ h: Double, _ hf: Double) -> (s: Double, sf: Double) {
            let sf = (h - hf * nfy) / afy
            return (sf * afx + hf * nfx, sf)
        }
        let corners = [male(0, 0), male(t, 0), male(0, t), male(t, t)]
        maleNear = corners.map(\.s).min() ?? 0
        maleFar = corners.map(\.s).max() ?? 0
        femaleNear = corners.map(\.sf).min() ?? 0
        femaleFar = corners.map(\.sf).max() ?? 0
        // The part of the parallelogram inside the female piece (sf >= 0):
        // its corners there, and where its sides cross the female edge line.
        var farthest = 0.0
        for corner in corners where corner.sf >= -1.0e-9 {
            farthest = max(farthest, corner.s)
        }
        for hf in [0.0, t] {
            let h = hf * nfy
            if h >= -1.0e-12, h <= t + 1.0e-12 {
                farthest = max(farthest, hf * nfx)
            }
        }
        if abs(nfy) > 1.0e-12 {
            for h in [0.0, t] {
                let hf = h / nfy
                if hf >= -1.0e-12, hf <= t + 1.0e-12 {
                    farthest = max(farthest, hf * nfx)
                }
            }
        }
        plainTrim = farthest
    }

    init(maleNear: Double, maleFar: Double, femaleNear: Double, femaleFar: Double, plainTrim: Double) {
        self.maleNear = maleNear
        self.maleFar = maleFar
        self.femaleNear = femaleNear
        self.femaleFar = femaleFar
        self.plainTrim = plainTrim
    }

    /// The band of a square seam in stock `t` (a cube edge).
    static func square(thickness t: Double) -> FoldedSeamBand {
        FoldedSeamBand(maleNear: 0, maleFar: t, femaleNear: 0, femaleFar: t, plainTrim: t)
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}

/// Per-joinery-type 2D feature geometry, applied to the mating cut-edge
/// pairs of the unfolded nets: features on the male copy of an edge, the
/// receiving cut on the female copy (or matching features on both).
///
/// Every seam is a butt joint: the female copy keeps its edge on the model
/// surface and the male copy is cut back (`maleTrim`) so its stock rests on
/// the female panel's inside face without passing into it. The joints are
/// built around the place where the male panel's plane runs through the
/// female panel's stock (`FoldedSeamBand`):
///
///   * Tab, Diamond, Multitab, Tongue and Rivet (through-slot joints): the
///     male protrusion runs from its cut-back edge through that band and on
///     past the female panel's outside face. The female copy gets a slot
///     covering the band and a lug that steps out of its edge around the
///     slot, keeping `slotBridge` of material on every side, so the slot is
///     a closed hole. The male copy is cut back past the whole band, clear
///     of the lug. Rivet's tab is longer and carries a pin hole just past
///     the female panel's outside face, for a rivet, pin, split pin or
///     cable tie that locks it.
///   * Gear and Puzzle (through-notch joints): fingers (Gear) or a neck with
///     a round head (Puzzle) pass through open notches cut into the female
///     copy's edge. Gear fingers fill the corner between the female
///     panel's own fingers, standing `toothScale × tickSpace` proud of its
///     outside face; Puzzle's head sits on the female panel's outside face
///     and holds it against the male panel.
///   * Ticked: matching V-notches on both copies' edges, to line the edges
///     up for gluing or taping.
///   * Laced: matching holes along both copies' edges, for a cord or wire
///     laced across the seam.
///
/// Joints go only where `featureWidth × 3 < edge length`, where both halves
/// fit their nets (the planner's fit check), and, for joints that pass
/// through the female panel's stock, where the panels meet at
/// `flattestSlotAngle` or more.
///
/// Conventions (in each copy's edge frame, the panel's outline running
/// counter-clockwise):
///   u — along the edge, from the segment start;
///   v — outward normal (right of travel), measured from the copy's edge
///       line on the model surface: +v protrudes past the edge, −v runs
///       into the panel. The male copy's cut-back edge is at v = −trim.
struct FoldedJoineryGeometry {
    let parameters: JoineryParameters
    let thickness: Double
    /// Extra width added to every slot and notch (the Slot Offset), so the
    /// protrusions fit after the cutter's kerf.
    var slotClearance: Double = 0

    init(parameters: JoineryParameters, thickness: Double, slotClearance: Double = 0) {
        self.parameters = parameters
        self.thickness = thickness
        self.slotClearance = max(0, slotClearance.isFinite ? slotClearance : 0)
    }

    /// The flattest seam that takes a joint passing through the other
    /// panel's stock. A protrusion in one panel's plane cannot pass through
    /// a panel lying within this angle of that plane without a slot and lug
    /// several thicknesses long, so flatter seams stay plain.
    static let flattestSlotAngle = Double.pi / 6

    enum Family {
        /// No joint: plain edges.
        case plain
        /// A protrusion through a closed slot on a lug.
        case throughSlot
        /// Fingers or a neck through open notches.
        case throughNotch
        /// Matching holes on both copies.
        case holes
        /// Matching V-notches on both copies.
        case ticks
    }

    var family: Family {
        Self.family(of: parameters.type)
    }

    static func family(of type: JoineryType) -> Family {
        switch type {
        case .tab, .diamond, .multitab, .tongue, .rivet:
            return .throughSlot
        case .gear, .puzzle:
            return .throughNotch
        case .laced:
            return .holes
        case .ticked:
            return .ticks
        case .seam, .trivial:
            return .plain
        }
    }

    /// Whether the joint cuts a slot or open notch for a protrusion to pass
    /// through, the only cuts the Slot Offset widens. Laced holes, Ticked
    /// V-notches and plain edges never read it.
    static func readsSlotClearance(_ type: JoineryType) -> Bool {
        switch family(of: type) {
        case .throughSlot, .throughNotch:
            return true
        case .plain, .holes, .ticks:
            return false
        }
    }

    var decoratesEdges: Bool {
        family != .plain
    }

    /// Whether the male protrusion passes through a slot in the female copy.
    var usesThroughSlots: Bool {
        family == .throughSlot
    }

    /// Whether the joint passes a protrusion through the female panel's
    /// stock, and so needs a seam at least `flattestSlotAngle` steep.
    var needsSteepSeam: Bool {
        family == .throughSlot || family == .throughNotch
    }

    /// The along-edge extent of one joinery feature. The size gate
    /// (`featureWidth × 3 < edge length`) is applied per mating pair for
    /// every type.
    var featureWidth: Double {
        switch parameters.type {
        case .tab, .diamond, .tongue, .puzzle:
            // A 6.35 mm tab (Puzzle: head) with the presets.
            return 4 * parameters.tickRadius
        case .multitab:
            return parameters.jointSpace * parameters.tabFraction
        case .rivet:
            // The pin hole with tickRadius of material either side.
            return 2 * (parameters.holeRadius + parameters.tickRadius)
        case .gear:
            return parameters.tickSpace / 2
        case .ticked:
            return parameters.seamRadius
        case .laced:
            return 2 * parameters.holeRadius
        case .seam, .trivial:
            return 0
        }
    }

    /// Material a lug keeps around its slot, and every hole or notch keeps
    /// to the other cuts of its panel.
    var slotBridge: Double {
        parameters.tickRadius
    }

    /// How far the male copy of a seam with this joint is cut back from the
    /// model surface: clear of the female piece, and, for a through-slot
    /// joint, clear of the whole band (where the female copy's lug sits).
    func maleTrim(band: FoldedSeamBand) -> Double {
        usesThroughSlots ? max(band.plainTrim, band.maleFar) : band.plainTrim
    }

    // MARK: - Features

    struct LocalPoint: Equatable {
        var u: Double
        var v: Double
    }

    /// One copy's joint features in its edge frame.
    struct LocalFeatures {
        /// Polygons that stand out of the panel: tabs, ticks, tongues,
        /// fingers, necks, lugs.
        var outward: [[LocalPoint]] = []
        /// Notches cut into the panel's edge.
        var inward: [[LocalPoint]] = []
        /// Closed holes: slots, lace holes, pin holes.
        var holes: [[LocalPoint]] = []
        /// Holes cut into an outward feature (pin holes), not the panel.
        var holesInFeatures: Set<Int> = []
        /// Where each outward feature meets its panel: u range at line v.
        var bases: [(u0: Double, u1: Double, v: Double)] = []

        var isEmpty: Bool {
            outward.isEmpty && inward.isEmpty && holes.isEmpty
        }
    }

    /// The joint centres along an edge of `edgeLength`, kept only where the
    /// whole joint (with its lug) fits on the edge. Both copies of an edge
    /// have the same length and band, so they keep the same joints, at the
    /// same places along the seam.
    func centers(edgeLength: Double, band: FoldedSeamBand) -> [Double] {
        let mid = edgeLength / 2
        switch parameters.type {
        case .tab, .diamond, .tongue:
            let reach = slotHalfLength(band: band) + slotBridge
            return mid - reach > 1.0e-9 ? [mid] : []
        case .multitab, .rivet:
            let reach = slotHalfLength(band: band) + slotBridge
            return centeredFeatureCenters(edgeLength: edgeLength, spacing: parameters.jointSpace, halfWidth: reach)
        case .puzzle:
            let reach = featureWidth / 2
            return mid - reach > 1.0e-9 ? [mid] : []
        case .gear:
            return centeredFeatureCenters(edgeLength: edgeLength, spacing: parameters.tickSpace, halfWidth: featureWidth / 2 + slotClearance / 2)
        case .ticked:
            return centeredFeatureCenters(edgeLength: edgeLength, spacing: parameters.tickSpace, halfWidth: featureWidth / 2)
        case .laced:
            return centeredFeatureCenters(edgeLength: edgeLength, spacing: parameters.jointSpace, halfWidth: parameters.holeRadius)
        case .seam, .trivial:
            return []
        }
    }

    /// Half the along-edge length of a through-slot: the protrusion's width
    /// plus the clearance, and for the rounded Tongue slot its round ends.
    private func slotHalfLength(band: FoldedSeamBand) -> Double {
        let half = featureWidth / 2 + slotClearance / 2
        return parameters.type == .tongue ? half + slotHalfHeight(band: band) : half
    }

    /// Half the across-seam width of a through-slot: the band plus the
    /// clearance.
    private func slotHalfHeight(band: FoldedSeamBand) -> Double {
        (band.femaleFar - band.femaleNear) / 2 + slotClearance / 2
    }

    /// One copy's features: the male copy (cut back by `trim`) or the
    /// female copy (on the model surface).
    func features(
        role: FoldedPanelPlanner.JoineryRole,
        edgeLength: Double,
        band: FoldedSeamBand,
        trim: Double
    ) -> LocalFeatures {
        let centers = centers(edgeLength: edgeLength, band: band)
        guard !centers.isEmpty else {
            return LocalFeatures()
        }
        var result = LocalFeatures()
        let tick = parameters.tickRadius
        let clearance = slotClearance
        switch (family, role) {
        case (.throughSlot, .male):
            // From the cut-back edge through the band, then out past the
            // female panel's outside face.
            let base = -trim
            let pastFarFace = -band.maleNear
            switch parameters.type {
            case .diamond:
                let half = featureWidth / 2
                for center in centers {
                    result.outward.append([
                        LocalPoint(u: center - half, v: base),
                        LocalPoint(u: center, v: pastFarFace + 2 * tick),
                        LocalPoint(u: center + half, v: base)
                    ])
                    result.bases.append((center - half, center + half, base))
                }
            case .tongue:
                let half = featureWidth / 2
                for center in centers {
                    result.outward.append(tonguePoints(center: center, halfWidth: half, base: base, straightTo: pastFarFace + tick))
                    result.bases.append((center - half, center + half, base))
                }
            case .rivet:
                // A tab long enough to carry a pin hole whose inner edge is
                // on the far face, with tickRadius of material beyond it.
                let half = featureWidth / 2
                let hole = parameters.holeRadius
                for center in centers {
                    result.outward.append(rectangle(u0: center - half, u1: center + half, v0: base, v1: pastFarFace + 2 * hole + tick))
                    result.bases.append((center - half, center + half, base))
                    result.holesInFeatures.insert(result.holes.count)
                    result.holes.append(circlePoints(center: LocalPoint(u: center, v: pastFarFace + hole), radius: hole))
                }
            default:
                // Tab, Multitab: rectangular tabs tickRadius past the far
                // face; touching tabs run together into one.
                for span in mergedSpans(centers: centers, halfWidth: featureWidth / 2) {
                    result.outward.append(rectangle(u0: span.lo, u1: span.hi, v0: base, v1: pastFarFace + tick))
                    result.bases.append((span.lo, span.hi, base))
                }
            }
        case (.throughSlot, .female):
            // The slot covers the band; the lug carries its outer part.
            let lugTop = -band.femaleNear + clearance / 2 + slotBridge
            if parameters.type == .tongue {
                let halfHeight = slotHalfHeight(band: band)
                let middle = -(band.femaleFar + band.femaleNear) / 2
                let straight = featureWidth / 2
                for center in centers {
                    result.holes.append(obround(center: LocalPoint(u: center, v: middle), straightHalfLength: straight, radius: halfHeight))
                }
                let reach = slotHalfLength(band: band) + slotBridge
                for span in mergedSpans(centers: centers, halfWidth: reach) {
                    result.outward.append(rectangle(u0: span.lo, u1: span.hi, v0: 0, v1: lugTop))
                    result.bases.append((span.lo, span.hi, 0))
                }
            } else {
                let half = featureWidth / 2 + clearance / 2
                for span in mergedSpans(centers: centers, halfWidth: half) {
                    result.holes.append(rectangle(u0: span.lo, u1: span.hi, v0: -band.femaleFar - clearance / 2, v1: -band.femaleNear + clearance / 2))
                }
                for span in mergedSpans(centers: centers, halfWidth: half + slotBridge) {
                    result.outward.append(rectangle(u0: span.lo, u1: span.hi, v0: 0, v1: lugTop))
                    result.bases.append((span.lo, span.hi, 0))
                }
            }
        case (.throughNotch, .male):
            let base = -trim
            let pastFarFace = -band.maleNear
            if parameters.type == .gear {
                let half = featureWidth / 2
                let proud = max(parameters.toothScale * parameters.tickSpace, 0)
                for center in centers {
                    result.outward.append(rectangle(u0: center - half, u1: center + half, v0: base, v1: pastFarFace + proud))
                    result.bases.append((center - half, center + half, base))
                }
            } else {
                for center in centers {
                    result.outward.append(puzzlePoints(center: center, base: base, farFace: pastFarFace))
                    result.bases.append((center - tick, center + tick, base))
                }
            }
        case (.throughNotch, .female):
            // Open notches through the female copy's stock where the male
            // fingers or necks pass, a hair past the edge so they open.
            let half = (parameters.type == .gear ? featureWidth / 2 : tick) + clearance / 2
            for center in centers {
                result.inward.append(rectangle(u0: center - half, u1: center + half, v0: -band.femaleFar - clearance / 2, v1: Self.openingOvershoot))
            }
        case (.ticks, _):
            let base = role == .male ? -trim : 0
            let half = featureWidth / 2
            for center in centers {
                result.inward.append([
                    LocalPoint(u: center - half, v: base + Self.openingOvershoot),
                    LocalPoint(u: center - half, v: base),
                    LocalPoint(u: center, v: base - parameters.seamRadius),
                    LocalPoint(u: center + half, v: base),
                    LocalPoint(u: center + half, v: base + Self.openingOvershoot)
                ])
            }
        case (.holes, _):
            let base = role == .male ? -trim : 0
            let hole = parameters.holeRadius
            for center in centers {
                result.holes.append(circlePoints(center: LocalPoint(u: center, v: base - tick - hole), radius: hole))
            }
        case (.plain, _):
            break
        }
        return result
    }

    /// How far an open notch reaches past its edge, so cutting it away from
    /// the panel opens the edge cleanly.
    static let openingOvershoot = 1.0e-3

    // MARK: - Primitive shapes (local edge frame, counter-clockwise)

    private func rectangle(u0: Double, u1: Double, v0: Double, v1: Double) -> [LocalPoint] {
        [
            LocalPoint(u: u0, v: v0),
            LocalPoint(u: u1, v: v0),
            LocalPoint(u: u1, v: v1),
            LocalPoint(u: u0, v: v1)
        ]
    }

    /// Rounded tongue: straight sides from `base` to `straightTo`, capped by
    /// a semicircle of radius `halfWidth` (8 chords).
    private func tonguePoints(center: Double, halfWidth: Double, base: Double, straightTo: Double) -> [LocalPoint] {
        var points = [LocalPoint(u: center - halfWidth, v: base), LocalPoint(u: center + halfWidth, v: base)]
        let segments = 8
        for index in 0...segments {
            let theta = Double.pi * Double(index) / Double(segments)
            points.append(LocalPoint(u: center + halfWidth * cos(theta), v: straightTo + halfWidth * sin(theta)))
        }
        return points
    }

    /// Puzzle neck and head: a neck tickRadius either side of `center` from
    /// `base` to where it meets a round head of radius 2 × tickRadius whose
    /// nearest point is on the far face, so the whole head sits past it
    /// (12 chords round the head).
    private func puzzlePoints(center: Double, base: Double, farFace: Double) -> [LocalPoint] {
        let neck = parameters.tickRadius
        let radius = 2 * parameters.tickRadius
        let headCenter = farFace + radius
        let drop = (radius * radius - neck * neck).squareRoot()
        var points = [LocalPoint(u: center - neck, v: base), LocalPoint(u: center + neck, v: base)]
        // From the right junction round the far side to the left junction.
        let start = atan2(-drop, neck)
        let end = atan2(-drop, -neck) + 2 * Double.pi
        let segments = 12
        for index in 0...segments {
            let theta = start + (end - start) * Double(index) / Double(segments)
            points.append(LocalPoint(u: center + radius * cos(theta), v: headCenter + radius * sin(theta)))
        }
        return points
    }

    /// Obround (stadium) slot: straight sides `straightHalfLength` either
    /// side of the centre, round ends of `radius` (4 chords each, meeting
    /// the straight sides at their ends).
    private func obround(center: LocalPoint, straightHalfLength: Double, radius: Double) -> [LocalPoint] {
        var points: [LocalPoint] = []
        let segments = 4
        for index in 0...segments {
            let theta = -Double.pi / 2 + Double.pi * Double(index) / Double(segments)
            points.append(LocalPoint(u: center.u + straightHalfLength + radius * cos(theta), v: center.v + radius * sin(theta)))
        }
        for index in 0...segments {
            let theta = Double.pi / 2 + Double.pi * Double(index) / Double(segments)
            points.append(LocalPoint(u: center.u - straightHalfLength + radius * cos(theta), v: center.v + radius * sin(theta)))
        }
        return points
    }

    /// 16-gon circle for lace and pin holes.
    private func circlePoints(center: LocalPoint, radius: Double) -> [LocalPoint] {
        let segments = 16
        return (0..<segments).map { index in
            let theta = 2 * Double.pi * Double(index) / Double(segments)
            return LocalPoint(u: center.u + radius * cos(theta), v: center.v + radius * sin(theta))
        }
    }

    /// Spans `center ± halfWidth`, with spans that touch or overlap merged
    /// (Multitab tabs as wide as their pitch run together into one).
    private func mergedSpans(centers: [Double], halfWidth: Double) -> [(lo: Double, hi: Double)] {
        var spans: [(lo: Double, hi: Double)] = []
        for center in centers {
            if let last = spans.last, center - halfWidth <= last.hi + 1.0e-9 {
                spans[spans.count - 1].hi = center + halfWidth
            } else {
                spans.append((center - halfWidth, center + halfWidth))
            }
        }
        return spans
    }

    /// Feature centres along an edge: max(1, ⌊length / spacing⌋) features at
    /// `spacing` pitch, centred on the edge midpoint; features that would
    /// poke past either end of the edge are dropped.
    private func centeredFeatureCenters(edgeLength: Double, spacing: Double, halfWidth: Double) -> [Double] {
        guard spacing > 1.0e-9 else {
            return [edgeLength / 2]
        }
        let count = max(1, Int(edgeLength / spacing))
        let mid = edgeLength / 2
        return (0..<count)
            .map { mid + (Double($0) - Double(count - 1) / 2) * spacing }
            .filter { $0 - halfWidth > 1.0e-9 && $0 + halfWidth < edgeLength - 1.0e-9 }
    }
}

/// A copy of a cut edge in its net: from `start` to `end` with its panel on
/// the left, so +v (right of travel) points out of the panel.
struct FoldedEdgeFrame {
    var start: Vec2
    var unit: Vec2
    var outward: Vec2
    var length: Double

    init?(start: Vec2, end: Vec2) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1.0e-9 else {
            return nil
        }
        self.start = start
        self.unit = Vec2(x: dx / length, y: dy / length)
        self.outward = Vec2(x: dy / length, y: -dx / length)
        self.length = length
    }

    func world(_ point: FoldedJoineryGeometry.LocalPoint) -> Vec2 {
        Vec2(
            x: start.x + unit.x * point.u + outward.x * point.v,
            y: start.y + unit.y * point.u + outward.y * point.v
        )
    }

    func local(_ point: Vec2) -> FoldedJoineryGeometry.LocalPoint {
        let dx = point.x - start.x
        let dy = point.y - start.y
        return FoldedJoineryGeometry.LocalPoint(u: dx * unit.x + dy * unit.y, v: dx * outward.x + dy * outward.y)
    }
}
