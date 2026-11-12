import Foundation
import simd

/// Closes the openings of an open skin — a vessel mouth, the ends of a tube,
/// a pinhole in a scan — WITHOUT re-meshing it. Every original triangle is
/// kept (positions bit-identical); the only changes are:
///   - near-duplicate vertices welded (relative tolerance, sub-micron on a
///     100 mm model),
///   - collapsed triangles, doubled ("back-to-back") triangle groups and tiny
///     loose fragments removed,
///   - "fix in place" for near-solid scans: the few triangles at each damaged
///     spot (non-manifold edges, pinches next to them, twisted winding) are
///     cut out and triangles wound against their neighbours are turned over
///     (see `healLocalDefects`),
///   - each boundary loop capped — openings, pinholes and the holes left by
///     the cut-out spots alike.
///
/// Small loops (pinholes, slits) get a minimum-weight triangulation. Large
/// openings get Liepa's hole fill (2003): a minimum-weight triangulation that
/// minimises the worst dihedral angle then area, refined to the density of the
/// surrounding mesh, then faired as a membrane with the rim held fixed. An
/// opening's cap is then moved onto a level set of the generalized winding
/// number of the skin, which never passes through the skin — flat (the rim's
/// plane, for a planar rim) at level 0.5; a signed `topHeight` (mm) picks the
/// level whose peak sits that far outward (dome, > 0) or inward (dish, < 0),
/// clamped where the level sets would run into the skin (see
/// `LevelSetShaper`).
///
/// This is the precise alternative to `MeshHealer` (which rebuilds the whole
/// surface through a voxel field and fills vessel cavities solid).
enum OpeningCapper {

    // MARK: - Public types

    struct Opening: Equatable {
        var edgeCount: Int
        var diameter: Double
        var center: Vec3
        /// Outward normal (unit): the way a cap over this opening faces.
        /// Zero when it can't be told (a rim with no area).
        var normal: Vec3 = Vec3(x: 0, y: 0, z: 0)
        /// Where it sits on the model, +Z up: "top", "bottom", "side", "side,
        /// near the top", "side, near the bottom".
        var placement: String = ""

        /// Geometric identity, for per-opening choices that must survive a
        /// re-diagnosis (array order is not identity).
        var signature: OpeningSignature {
            OpeningSignature(center: center, diameter: diameter, normal: normal)
        }

        /// "Opening 1 — 93 mm, top" (`number` is 1-based).
        func label(number: Int) -> String {
            let size = OpeningCapper.formatMM(diameter)
            return placement.isEmpty ? "Opening \(number) — \(size)" : "Opening \(number) — \(size), \(placement)"
        }
    }

    /// Identifies an opening by where it is, how big it is and which way it
    /// faces (coordinates of the diagnosed geometry, mm) — NOT by its index,
    /// so a saved choice still finds its opening after the mesh is diagnosed
    /// again.
    struct OpeningSignature: Codable, Equatable, Hashable {
        var center: Vec3
        var diameter: Double
        var normal: Vec3

        /// How far `other` is from this signature (0 = identical), or nil
        /// when it can't be the same opening: centres more than a quarter of
        /// the larger diameter apart, diameters more than 25% apart, or
        /// normals more than 60° apart (ignored when either is zero).
        func distance(to other: OpeningSignature) -> Double? {
            let size = max(diameter, other.diameter)
            guard size.isFinite, size > 0 else { return nil }
            let dc = SIMD3(center.x - other.center.x, center.y - other.center.y, center.z - other.center.z)
            let offset = simd_length(dc) / size
            let resize = abs(diameter - other.diameter) / size
            guard offset <= 0.25, resize <= 0.25 else { return nil }
            let a = SIMD3(normal.x, normal.y, normal.z), b = SIMD3(other.normal.x, other.normal.y, other.normal.z)
            var turn = 0.0
            if simd_length_squared(a) > 0, simd_length_squared(b) > 0 {
                let dot = simd_dot(simd_normalize(a), simd_normalize(b))
                guard dot >= 0.5 else { return nil }
                turn = 1 - dot
            }
            return offset + resize + 0.5 * turn
        }
    }

    /// What to do with one opening (the defaults are today's behaviour:
    /// Fix in place caps it at the global Top shape; Make walls keeps it open).
    struct OpeningChoice: Codable, Equatable, Hashable {
        var signature: OpeningSignature
        /// Fix in place: leave this opening open (the result is then not
        /// watertight — by choice, and the receipt says so).
        var leaveOpen: Bool = false
        /// Fix in place: this opening's top shape, mm (0 flat, > 0 dome,
        /// < 0 dish); nil follows the global Top shape.
        var topHeight: Double? = nil
        /// Make walls: close this opening with a floor / lid of the wall
        /// thickness instead of leaving its rim open.
        var closedInWalls: Bool = false

        /// True when this choice asks for nothing beyond the defaults.
        var isDefault: Bool { !leaveOpen && topHeight == nil && !closedInWalls }
    }

    /// Pairs saved choices with the diagnosed openings by signature (one to
    /// one, closest first). Returns, per opening in `openings` order, its
    /// choice (nil = defaults), and the choices that match no opening — the
    /// caller drops those and says so.
    static func matchChoices(_ choices: [OpeningChoice], to openings: [Opening])
        -> (byOpening: [OpeningChoice?], unmatched: [OpeningChoice]) {
        var byOpening = [OpeningChoice?](repeating: nil, count: openings.count)
        guard !choices.isEmpty else { return (byOpening, []) }
        var pairs: [(score: Double, choice: Int, opening: Int)] = []
        for (c, choice) in choices.enumerated() {
            for (o, opening) in openings.enumerated() {
                if let d = choice.signature.distance(to: opening.signature) { pairs.append((d, c, o)) }
            }
        }
        pairs.sort { ($0.score, $0.choice, $0.opening) < ($1.score, $1.choice, $1.opening) }
        var usedChoice = Set<Int>()
        for pair in pairs where !usedChoice.contains(pair.choice) && byOpening[pair.opening] == nil {
            byOpening[pair.opening] = choices[pair.choice]
            usedChoice.insert(pair.choice)
        }
        let unmatched = choices.indices.filter { !usedChoice.contains($0) }.map { choices[$0] }
        return (byOpening, unmatched)
    }

    /// One opening's outcome in a Fix in place run.
    struct OpeningOutcome: Equatable {
        /// 1-based, in diagnosis order.
        var number: Int
        var diameter: Double
        var placement: String
        var leftOpen: Bool
        /// Requested / achieved top shape, mm (0 for a left-open opening).
        var requestedHeight: Double
        var appliedHeight: Double
    }

    /// One problem spot the diagnosis found, for the viewport's issue markers
    /// and the Issues panel list (Meshmixer Inspector pattern). Positions are
    /// in the coordinates of the geometry passed to `diagnose` (the app passes
    /// the scaled / rotated model, so millimetres in the viewport's model
    /// frame).
    struct Site: Equatable, Identifiable {
        enum Kind: String, CaseIterable, Equatable {
            case opening
            case pinhole
            case seam
            case nonManifoldSpot
            case doubledTriangles
            case looseFragment
            case flippedPiece
        }

        /// Stable for the same mesh: kind + rank within the kind (largest
        /// first, ties by position).
        var id: String
        var kind: Kind
        /// Centroid of the spot (an opening's or pinhole's rim centre).
        var position: Vec3
        /// Across, mm (an opening's diameter; a spot's extent).
        var sizeMM: Double
        /// Short plain-language name.
        var title: String
        /// One line: what Fix in place (or the right tool) will do here.
        var fixDescription: String
        /// Triangles involved (rim edges for openings, pinholes and seams).
        var elementCount: Int
        /// False when Fix in place can't handle this spot (the damage is too
        /// widespread — Rebuild as solid is the answer).
        var fixableInPlace: Bool = true
    }

    /// Most sites listed per kind (the largest); the rest are counted in
    /// `Diagnosis.sitesOmitted` so nothing disappears silently.
    static let maxSitesPerKind = 50

    /// A size for display: whole mm from 10 mm, else 1–2 decimals.
    static func formatMM(_ d: Double) -> String {
        if d >= 10 { return String(format: "%.0f mm", d) }
        if d >= 1 { return String(format: "%.1f mm", d) }
        return String(format: "%.2f mm", d)
    }

    struct Diagnosis: Equatable {
        var openings: [Opening]
        var pinholes: Int
        var collapsedTriangles: Int
        /// Groups of triangles on the same three corners (resolved by removal).
        var doubledTriangleGroups: Int
        /// Triangles those groups lose.
        var doubledTrianglesRemoved: Int
        var looseFragments: Int
        /// Edges used by more than two triangles after the cleanup above, as
        /// found (before "fix in place" heals them).
        var nonManifoldEdges: Int
        /// Edges whose two triangles run the same direction (flipped patches),
        /// as found.
        var orientationConflicts: Int
        /// Open edges as found (before any damaged spot is cut out).
        var boundaryEdges: Int
        /// Fix in place: separate damaged spots (non-manifold edges, pinches
        /// next to them, twisted patches) that get cut out and refilled.
        var damagedSpots: Int = 0
        /// Triangles those spots lose; the refill replaces them.
        var trianglesToReplace: Int = 0
        /// Triangles wound against their neighbours that get turned over.
        var flippedTriangles: Int = 0
        /// Why this mesh can't be fixed in place (nil when it can, or when
        /// there is nothing to fix).
        var blockingReason: String? = nil
        /// Seams: zero-width cracks between surface pieces whose shared edges
        /// don't share corners (CAD patches, loft halves). They get zipped
        /// shut, not capped.
        var seams: Int = 0
        /// Boundary corners those seams join to the opposite side.
        var seamCornersJoined: Int = 0
        /// Surface pieces wound opposite to the piece they are stitched to
        /// (turned over as a whole).
        var piecesReversed: Int = 0
        /// Every problem spot as a place on the model (see `Site`), grouped by
        /// kind in `Site.Kind` order.
        var sites: [Site] = []
        /// Spots found but not listed in `sites` (beyond `maxSitesPerKind`).
        var sitesOmitted: Int = 0

        /// Something `close` would change: an opening or pinhole to cap, a
        /// damaged spot to heal, doubled / loose / flipped triangles to tidy.
        var hasFixableProblems: Bool {
            !openings.isEmpty || hasFixableProblemsBesidesOpenings
        }

        /// Something `close` would change even with every opening left open.
        var hasFixableProblemsBesidesOpenings: Bool {
            pinholes > 0 || damagedSpots > 0 || doubledTrianglesRemoved > 0
                || looseFragments > 0 || flippedTriangles > 0 || seams > 0 || piecesReversed > 0
        }

        /// Whether `close` can handle this mesh: everything wrong with it is
        /// local — openings, pinholes and small damaged spots that can be cut
        /// out and refilled without re-meshing the rest.
        var canCloseOpenings: Bool {
            blockingReason == nil && hasFixableProblems
        }

        /// A closed solid with nothing to change (collapsed zero-area triangles
        /// alone are harmless and left as they are). `close` throws
        /// `nothingToClose` exactly when this is true.
        var isNothingToFix: Bool {
            blockingReason == nil && !hasFixableProblems && boundaryEdges == 0
        }

        /// One plain-language line for the Issues panel.
        var sentence: String {
            var parts: [String] = []
            if !openings.isEmpty {
                let sizes = openings.prefix(3).map { "\(Int($0.diameter.rounded())) mm" }.joined(separator: ", ")
                let more = openings.count > 3 ? ", …" : ""
                parts.append(openings.count == 1
                    ? "1 opening (\(sizes) across)"
                    : "\(openings.count) openings (\(sizes)\(more) across)")
            }
            if pinholes > 0 { parts.append(pinholes == 1 ? "1 pinhole" : "\(pinholes) pinholes") }
            if seams > 0 {
                parts.append(seams == 1 ? "1 open seam (a zero-width crack)" : "\(seams) open seams (zero-width cracks)")
            }
            if piecesReversed > 0 {
                parts.append(piecesReversed == 1 ? "1 surface piece wound inside out" : "\(piecesReversed) surface pieces wound inside out")
            }
            if nonManifoldEdges > 0 {
                parts.append(nonManifoldEdges == 1 ? "1 non-manifold edge" : "\(nonManifoldEdges) non-manifold edges")
            }
            if orientationConflicts > 0 { parts.append("\(orientationConflicts) flipped edges") }
            if openings.isEmpty && pinholes == 0 && boundaryEdges > 0 {
                parts.append(boundaryEdges == 1 ? "1 open edge" : "\(boundaryEdges) open edges")
            }
            if doubledTrianglesRemoved > 0 {
                parts.append(doubledTrianglesRemoved == 1 ? "1 doubled-up triangle" : "\(doubledTrianglesRemoved) doubled-up triangles")
            }
            if looseFragments > 0 {
                parts.append(looseFragments == 1 ? "1 loose fragment" : "\(looseFragments) loose fragments")
            }
            if isNothingToFix {
                guard collapsedTriangles > 0 else { return "Closed solid — nothing to fix." }
                return collapsedTriangles == 1
                    ? "Closed solid — nothing to fix (1 collapsed triangle is harmless and left as-is)."
                    : "Closed solid — nothing to fix (\(collapsedTriangles) collapsed triangles are harmless and left as-is)."
            }
            if collapsedTriangles > 0 {
                parts.append(collapsedTriangles == 1 ? "1 collapsed triangle" : "\(collapsedTriangles) collapsed triangles")
            }
            guard !parts.isEmpty else { return "Closed solid — nothing to fix." }
            let kind: String
            if !openings.isEmpty { kind = "Open surface" }
            else if canCloseOpenings { kind = "Solid with small problems" }
            else { kind = "Needs repair" }
            var text = "\(kind): " + parts.joined(separator: ", ")
            if let blockingReason {
                text += ". " + blockingReason
            } else if damagedSpots > 0 {
                text += damagedSpots == 1
                    ? " — 1 damaged spot can be fixed in place."
                    : " — \(damagedSpots) damaged spots can be fixed in place."
            } else {
                text += "."
            }
            return text
        }
    }

    struct Result {
        var geometry: MeshGeometryData
        var openingsClosed: Int
        var pinholesFilled: Int
        /// Removed during cleanup (collapsed + doubled + loose triangles).
        var trianglesRemoved: Int
        /// Original triangles kept with bit-identical corner positions.
        var untouchedFraction: Double
        /// Edges still open / shared by more than two triangles after capping
        /// (0 and 0 for a clean result).
        var remainingOpenEdges = 0
        var remainingNonManifoldEdges = 0
        /// The dome/dish height actually used (after clamping), mm.
        var appliedTopHeight: Double
        var requestedTopHeight: Double
        /// Opening-cap triangles that still cut through the surrounding
        /// surface (0 = clean) — counted on the finished caps.
        var capIntersections: Int
        var flippedInsideOut: Bool
        /// Fix in place: damaged spots cut out and refilled, how many
        /// non-manifold edges they held, the triangles cut out, and the refill
        /// patches that replaced them.
        var spotsHealed = 0
        var nonManifoldEdgesHealed = 0
        var trianglesReplaced = 0
        var healPatches = 0
        /// Refill triangles that cross nearby surface (an existing fold in the
        /// scan next to the spot); informational.
        var healPatchIntersections = 0
        /// Triangles turned over to match their neighbours.
        var trianglesFlipped = 0
        /// Seams zipped shut (cracks between surface pieces), the boundary
        /// corners joined across them, and the surface pieces turned over to
        /// match the piece they were stitched to.
        var seamsStitched = 0
        var seamCornersJoined = 0
        var piecesReversed = 0
        /// Output triangles `0 ..< keptTriangleCount` are the kept original
        /// triangles (in input order, minus removed ones); cap triangles follow.
        var keptTriangleCount = 0
        /// Output triangle ranges of each cap that closes an OPENING (not a
        /// pinhole) — what Make walls re-opens.
        var openingCapTriangleRanges: [Range<Int>] = []
        /// Output triangle ranges of each pinhole fill.
        var pinholeCapTriangleRanges: [Range<Int>] = []
        /// The openings as diagnosed (diagnosis order), and the output
        /// triangle range of each capped one, keyed by its index there.
        var openings: [Opening] = []
        var openingCapRangeByOpening: [Int: Range<Int>] = [:]
        /// Per opening (diagnosis order): capped at what height, or left open.
        var openingOutcomes: [OpeningOutcome] = []
        /// Openings left open by the user's choice, and their rim edges (open
        /// edges in the result on purpose).
        var openingsLeftOpen = 0
        var leftOpenRimEdges = 0
        /// Saved per-opening choices that matched no opening (dropped).
        var droppedChoices = 0

        /// Capped openings share one requested height (the plain receipt).
        private var cappedHeightsUniform: Bool {
            let requested = openingOutcomes.filter { !$0.leftOpen }.map(\.requestedHeight)
            guard let first = requested.first else { return true }
            return requested.allSatisfy { abs($0 - first) <= 0.05 }
        }

        private static func shapeText(_ height: Double) -> String {
            if abs(height) < 0.05 { return "flat" }
            return height > 0 ? String(format: "domed %.1f mm", height) : String(format: "dished %.1f mm", -height)
        }

        var receipt: String {
            var bits: [String] = []
            if seamsStitched > 0 {
                bits.append(seamsStitched == 1
                    ? "stitched 1 seam shut"
                    : "stitched \(seamsStitched) seams shut")
            }
            if piecesReversed > 0 {
                bits.append(piecesReversed == 1
                    ? "turned 1 inside-out surface piece to match its neighbour"
                    : "turned \(piecesReversed) inside-out surface pieces to match their neighbours")
            }
            if spotsHealed > 0 {
                let what = nonManifoldEdgesHealed > 0 ? "non-manifold" : "damaged"
                bits.append(spotsHealed == 1
                    ? "healed 1 \(what) spot (replaced \(trianglesReplaced) triangles)"
                    : "healed \(spotsHealed) \(what) spots (replaced \(trianglesReplaced) triangles)")
            }
            let uniform = cappedHeightsUniform
            if openingsClosed > 0 {
                if uniform {
                    let shape = Self.shapeText(appliedTopHeight)
                    if openingsLeftOpen > 0, let only = openingOutcomes.first(where: { !$0.leftOpen }), openingsClosed == 1 {
                        bits.append("closed opening \(only.number) (\(shape))")
                    } else {
                        bits.append(openingsClosed == 1 ? "closed the opening (\(shape))" : "closed \(openingsClosed) openings (\(shape))")
                    }
                } else {
                    let each = openingOutcomes.filter { !$0.leftOpen }
                        .map { "opening \($0.number) \(Self.shapeText($0.appliedHeight))" }
                        .joined(separator: ", ")
                    bits.append("closed \(openingsClosed) openings (\(each))")
                }
            }
            if openingsLeftOpen > 0 {
                bits.append(openingsLeftOpen == 1
                    ? "1 opening left open (your choice)"
                    : "\(openingsLeftOpen) openings left open (your choice)")
            }
            if pinholesFilled > 0 { bits.append(pinholesFilled == 1 ? "filled 1 pinhole" : "filled \(pinholesFilled) pinholes") }
            if trianglesFlipped > 0 {
                bits.append(trianglesFlipped == 1
                    ? "turned 1 flipped triangle the right way"
                    : "turned \(trianglesFlipped) flipped triangles the right way")
            }
            if trianglesRemoved > 0 { bits.append("removed \(trianglesRemoved) broken triangles") }
            if flippedInsideOut { bits.append("turned the surface right side out") }
            var text = bits.joined(separator: ", ")
            text = text.prefix(1).uppercased() + text.dropFirst()
            text += String(format: ". %.1f%% of your surface is untouched.", untouchedFraction * 100)
            if uniform {
                if abs(appliedTopHeight - requestedTopHeight) > 0.05 {
                    text += String(format: " Height limited to %.1f mm so the cap doesn't cut into the model.", appliedTopHeight)
                }
            } else {
                for o in openingOutcomes where !o.leftOpen && abs(o.appliedHeight - o.requestedHeight) > 0.05 {
                    text += String(format: " Opening %d's height limited to %.1f mm so the cap doesn't cut into the model.", o.number, o.appliedHeight)
                }
            }
            if openingsLeftOpen > 0 {
                text += openingsLeftOpen == 1
                    ? " Not watertight by choice: the opening you left open keeps its open rim."
                    : " Not watertight by choice: the openings you left open keep their open rims."
            }
            if droppedChoices > 0 {
                text += droppedChoices == 1
                    ? " 1 saved opening choice no longer matches any opening (the model changed) and was dropped."
                    : " \(droppedChoices) saved opening choices no longer match any opening (the model changed) and were dropped."
            }
            if capIntersections > 0 {
                text += " Note: the new top crosses the surface in \(capIntersections) small places (where the rim folds over itself)."
            }
            if healPatchIntersections > 0 {
                text += healPatchIntersections == 1
                    ? " Note: 1 refill triangle touches a fold in the scan next to a healed spot (harmless for slicing)."
                    : " Note: \(healPatchIntersections) refill triangles touch folds in the scan next to healed spots (harmless for slicing)."
            }
            if remainingOpenEdges > leftOpenRimEdges || remainingNonManifoldEdges > 0 {
                text += " Not fully closed: \(remainingOpenEdges - leftOpenRimEdges) open\(leftOpenRimEdges > 0 ? " (besides the rims you left open)" : "") and \(remainingNonManifoldEdges) non-manifold edges remain (seams between surface pieces) — use Rebuild as solid for this model."
            }
            return text
        }
    }

    enum CapError: Error, Equatable, LocalizedError {
        case noSurface
        case nothingToClose
        case needsRebuild(String)
        /// Every opening is set to Leave open and nothing else needs fixing.
        case everythingLeftOpen(Int)

        var errorDescription: String? {
            switch self {
            case .noSurface: return "There is no surface to repair."
            case .nothingToClose: return "Nothing to fix — the surface is already a closed solid."
            case .needsRebuild(let why): return "Can't fix this in place: \(why)"
            case .everythingLeftOpen(let n):
                return n == 1
                    ? "Nothing to do — the only opening is set to Leave open and nothing else needs fixing. The model is unchanged."
                    : "Nothing to do — all \(n) openings are set to Leave open and nothing else needs fixing. The model is unchanged."
            }
        }
    }

    // MARK: - Entry points

    static func diagnose(_ geometry: MeshGeometryData) -> Diagnosis? {
        guard let prepared = Prepared(geometry) else { return nil }
        return prepared.diagnosis()
    }

    /// Close every opening and pinhole and heal small damaged spots in place.
    /// `topHeight` (mm): 0 = flat membrane, > 0 dome outward, < 0 dish inward
    /// (openings only; healed spots and pinholes are always filled flush).
    ///
    /// `choices` (optional) handle openings one by one — leave one open, or
    /// give it its own top shape. They are matched to the diagnosed openings
    /// by `OpeningSignature`; a choice that matches nothing is dropped and
    /// the receipt says so. With no choices every opening is capped at
    /// `topHeight` (unchanged behaviour).
    static func close(_ geometry: MeshGeometryData, topHeight: Double, choices: [OpeningChoice] = []) throws -> Result {
        guard let prepared = Prepared(geometry) else { throw CapError.noSurface }
        let diagnosis = prepared.diagnosis()
        if let reason = diagnosis.blockingReason { throw CapError.needsRebuild(reason) }
        if !diagnosis.hasFixableProblems {
            if diagnosis.boundaryEdges > 0 {
                throw CapError.needsRebuild("\(diagnosis.boundaryEdges) open edges don't form holes that can be traced and filled — use Rebuild as solid.")
            }
            throw CapError.nothingToClose
        }
        let (byOpening, unmatched) = matchChoices(choices, to: diagnosis.openings)
        let heights: [Double?] = byOpening.map { choice in
            if choice?.leaveOpen == true { return nil }
            return choice?.topHeight ?? topHeight
        }
        if !diagnosis.openings.isEmpty, heights.allSatisfy({ $0 == nil }), !diagnosis.hasFixableProblemsBesidesOpenings {
            throw CapError.everythingLeftOpen(diagnosis.openings.count)
        }
        var result = prepared.capAll(heights: heights, topHeight: topHeight, diagnosis: diagnosis)
        result.droppedChoices = unmatched.count
        return result
    }

    /// Topology report for a mesh `close` produced, counted over EVERY
    /// triangle by index. (`MeshPreflight.analyze` skips near-zero-area
    /// triangles when counting edges, which reports phantom holes around the
    /// microscopic but real slivers scans carry; this output is already welded,
    /// so index topology is the truth.) `manifoldValidated` is Manifold's own
    /// verdict on the returned geometry.
    static func topologyReport(_ geometry: MeshGeometryData) -> MeshPreflightReport {
        var uses: [UInt64: Int] = [:]
        let idx = geometry.triangleIndices
        var zeroArea = 0
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        let pts = geometry.vertices.map { SIMD3<Double>($0.x, $0.y, $0.z) }
        for p in pts { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let diag2 = pts.isEmpty ? 0 : simd_length_squared(hi - lo)
        let limit = 1.0e-12 * diag2
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let key = (UInt64(min(u, v)) << 32) | UInt64(max(u, v))
                uses[key, default: 0] += 1
            }
            if simd_length(simd_cross(pts[b] - pts[a], pts[c] - pts[a])) <= limit { zeroArea += 1 }
            t += 3
        }
        var manifoldOK = false
        if let handle = try? ManifoldEngine.make(from: geometry) {
            manifoldOK = ManifoldEngine.isWatertight(handle)
        }
        return MeshPreflightReport(
            uniqueVertexCount: geometry.vertices.count,
            duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 0,
            degenerateTriangleCount: zeroArea,
            boundaryEdgeCount: uses.values.filter { $0 == 1 }.count,
            nonManifoldEdgeCount: uses.values.filter { $0 > 2 }.count,
            manifoldValidated: manifoldOK
        )
    }

    /// What `importedTopology` measured: the report plus the zero-area
    /// breakdown behind its counts.
    struct ImportedTopology: Equatable {
        var report: MeshPreflightReport
        /// Triangles whose corners weld together (or reference a missing
        /// vertex): no area and no edges, so they are not counted anywhere.
        var collapsedTriangles: Int
        /// Zero-area triangles (relative to the diagonal) that are part of the
        /// surface — their edges are shared with real triangles and counted.
        var zeroAreaSurfaceTriangles: Int
        /// Zero-area triangles connected (by edges) only to other zero-area
        /// triangles — loose debris, not surface; their edges are not counted.
        var debrisTriangles: Int
    }

    /// Truthful, unit-independent topology report for an IMPORTED mesh — what
    /// the GUI shows and gates on in place of `MeshPreflight.analyze`, whose
    /// ABSOLUTE tolerances (a 1e-6 weld grid, a 1e-10 area floor) are measured
    /// in the file's raw units and skip near-zero-area triangles when counting
    /// edges: on a valid inch or unit-box model hundreds of thousands of small
    /// but real triangles read as degenerate and every edge next to them as
    /// open.
    ///
    /// Here every tolerance is relative to the bounding-box diagonal, so the
    /// same surface reports the same topology in any unit:
    ///  - vertices are welded with the capper's relative weld (`relativeWeld`);
    ///  - triangles whose corners weld together are collapsed (no edges);
    ///  - edges are counted over EVERY other triangle, zero-area slivers
    ///    included (a sliver's edges close its neighbours' edges);
    ///  - a triangle is zero-area when twice its area is ≤ 1e-12 × diagonal²;
    ///    zero-area triangles connected only to other zero-area triangles are
    ///    debris, not boundary, and their edges are not counted;
    ///  - `manifoldValidated` is Manifold's own verdict on the geometry (the
    ///    64-bit, double-precision path).
    /// `degenerateTriangleCount` is the debris only: collapsed triangles and
    /// zero-area slivers inside a closed surface are harmless (they neither
    /// open it nor stop Manifold — see `Diagnosis.isNothingToFix`).
    static func importedTopology(_ geometry: MeshGeometryData) -> ImportedTopology {
        let raw = geometry.vertices.map { P3($0.x, $0.y, $0.z) }
        let idx = geometry.triangleIndices
        let triCount = idx.count / 3
        var lo = P3(repeating: .infinity), hi = P3(repeating: -.infinity)
        for p in raw { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let diagonal = raw.isEmpty ? 0 : simd_length(hi - lo)
        guard triCount > 0, diagonal.isFinite, diagonal > 0 else {
            // Nothing to measure relative to (no triangles, or every vertex at
            // one point): the raw report is as truthful as anything.
            return ImportedTopology(
                report: MeshPreflight.analyze(geometry: geometry),
                collapsedTriangles: 0, zeroAreaSurfaceTriangles: 0, debrisTriangles: 0
            )
        }

        let rep = Prepared.relativeWeld(raw, idx, diagonal: diagonal)
        // A trailing partial triangle is an invalid reference, as in
        // `MeshPreflight.analyze`.
        var invalid = idx.count % 3 == 0 ? 0 : 1
        var collapsed = 0
        var faces: [Tri] = []
        var zeroArea: [Bool] = []
        faces.reserveCapacity(triCount)
        zeroArea.reserveCapacity(triCount)
        let areaLimit = 1.0e-12 * diagonal * diagonal
        for t in 0..<triCount {
            let i0 = Int(idx[3 * t]), i1 = Int(idx[3 * t + 1]), i2 = Int(idx[3 * t + 2])
            guard raw.indices.contains(i0), raw.indices.contains(i1), raw.indices.contains(i2) else {
                invalid += 1
                continue
            }
            let a = rep[i0], b = rep[i1], c = rep[i2]
            if a == b || b == c || c == a { collapsed += 1; continue }
            faces.append(Tri(a: a, b: b, c: c))
            zeroArea.append(simd_length(simd_cross(raw[b] - raw[a], raw[c] - raw[a])) <= areaLimit)
        }

        // Debris: edge-connected pieces made only of zero-area triangles.
        var debris = [Bool](repeating: false, count: faces.count)
        if zeroArea.contains(true) {
            var parent = Array(0..<faces.count)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                var y = x
                while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
                return r
            }
            var firstFace: [UInt64: Int] = [:]
            firstFace.reserveCapacity(faces.count * 2)
            for (f, t) in faces.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let key = (UInt64(min(u, v)) << 32) | UInt64(max(u, v))
                    if let other = firstFace[key] {
                        let ra = find(f), rb = find(other)
                        if ra != rb { parent[ra] = rb }
                    } else {
                        firstFace[key] = f
                    }
                }
            }
            var hasArea = Set<Int>()
            for f in faces.indices where !zeroArea[f] { hasArea.insert(find(f)) }
            for f in faces.indices where zeroArea[f] && !hasArea.contains(find(f)) { debris[f] = true }
        }

        var uses: [UInt64: Int32] = [:]
        uses.reserveCapacity(faces.count * 2)
        for (f, t) in faces.enumerated() where !debris[f] {
            for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                uses[(UInt64(min(u, v)) << 32) | UInt64(max(u, v)), default: 0] += 1
            }
        }
        var boundary = 0, nonManifold = 0
        for n in uses.values {
            if n == 1 { boundary += 1 } else if n > 2 { nonManifold += 1 }
        }
        let debrisCount = debris.lazy.filter { $0 }.count
        let zeroAreaCount = zeroArea.lazy.filter { $0 }.count

        var manifoldOK = false
        if invalid == 0, let handle = try? ManifoldEngine.make64(from: geometry) {
            manifoldOK = ManifoldEngine.isWatertight(handle)
        }
        let unique = Set(rep).count
        return ImportedTopology(
            report: MeshPreflightReport(
                uniqueVertexCount: unique,
                duplicateVertexObservationCount: raw.count - unique,
                invalidTriangleReferenceCount: invalid,
                degenerateTriangleCount: debrisCount,
                boundaryEdgeCount: boundary,
                nonManifoldEdgeCount: nonManifold,
                manifoldValidated: manifoldOK
            ),
            collapsedTriangles: collapsed,
            zeroAreaSurfaceTriangles: zeroAreaCount - debrisCount,
            debrisTriangles: debrisCount
        )
    }

    /// `importedTopology(_:).report`.
    static func importedTopologyReport(_ geometry: MeshGeometryData) -> MeshPreflightReport {
        importedTopology(geometry).report
    }

    /// Enclosed volume (mm³ for mm geometry) by the divergence theorem;
    /// positive for a closed surface wound outward.
    static func signedVolume(_ geometry: MeshGeometryData) -> Double {
        let idx = geometry.triangleIndices
        let v = geometry.vertices
        var total = 0.0
        var t = 0
        while t + 2 < idx.count {
            let a = v[Int(idx[t])], b = v[Int(idx[t + 1])], c = v[Int(idx[t + 2])]
            total += simd_dot(SIMD3(a.x, a.y, a.z), simd_cross(SIMD3(b.x, b.y, b.z), SIMD3(c.x, c.y, c.z))) / 6
            t += 3
        }
        return total
    }

    // MARK: - Preparation (weld + cleanup + loops)

    fileprivate typealias P3 = SIMD3<Double>

    fileprivate struct Tri { var a: Int; var b: Int; var c: Int }

    private struct Prepared {
        let originalTriangleCount: Int
        /// Welded vertex positions (representatives keep their exact position).
        var points: [P3]
        var triangles: [Tri]
        /// Parallel to `triangles`: true when every corner was already the
        /// representative of its weld cluster (position bit-identical).
        var exact: [Bool]
        let diagonal: Double
        var collapsed = 0
        var doubledGroups = 0
        var doubledRemoved = 0
        var looseFragments = 0
        var looseRemoved = 0
        /// Rim slivers folded flat back onto their neighbour (removed).
        var foldedFlaps = 0
        /// Current topology (after any healing).
        var nonManifoldEdges = 0
        var orientationConflicts = 0
        var boundaryEdgeCount = 0
        /// Topology as found, after the cleanup but before fix-in-place.
        var foundNonManifoldEdges = 0
        var foundOrientationConflicts = 0
        var foundBoundaryEdges = 0
        /// Fix in place (see `healLocalDefects`).
        var healSites = 0
        var trianglesStripped = 0
        var trianglesFlipped = 0
        /// Corners of every triangle cut out (for counting separate spots).
        var strippedCorners: [Tri] = []
        /// Undirected edges that were open before any damaged spot was cut
        /// out (see `isHealLoop`).
        var preexistingBoundary: Set<UInt64>? = nil
        var blockingReason: String?
        /// Closed boundary loops, as vertex sequences along boundary half-edges.
        var loops: [[Int]] = []
        /// Loops traced through a pinch vertex, split into simple loops there.
        var pinchSplits = 0
        /// Seam stitching (see `stitchSeams`): separate cracks zipped shut,
        /// boundary corners joined onto the opposite side (welded to a
        /// matching corner or set into the opposite edge), and surface
        /// pieces turned over to match the piece they were stitched to.
        var seamsStitched = 0
        var seamCornersJoined = 0
        var patchesReversed = 0
        /// Where each problem was found, recorded as the passes find it (for
        /// `Diagnosis.sites`). Vertex ids are stable (welding keeps the
        /// representative's index and position), so corners recorded before a
        /// triangle is removed still locate it.
        /// Doubled groups resolved: the group's corners and triangles removed.
        var doubledSeeds: [(corners: Tri, removed: Int)] = []
        /// Loose fragments dropped: their corners and triangle counts.
        var looseSeeds: [(vertices: [Int], triangles: Int)] = []
        /// Seams stitched: the corners along each.
        var seamSeeds: [[Int]] = []
        /// Surface pieces turned over whole after stitching: their corners and
        /// triangle counts.
        var reversedPieceSeeds: [(vertices: [Int], triangles: Int)] = []
        /// Triangles turned over by fix-in-place (corners).
        var flippedCorners: [Tri] = []
        /// Corners at non-manifold edges (to name a damaged spot).
        var nonManifoldVertices = Set<Int>()
        /// Damage fix-in-place found but could not take on (too widespread):
        /// the triangles it would have cut out.
        var unfixableCorners: [Tri] = []

        init?(_ geometry: MeshGeometryData) {
            let raw = geometry.vertices.map { P3($0.x, $0.y, $0.z) }
            let rawCount = geometry.triangleIndices.count / 3
            guard !raw.isEmpty, rawCount > 0 else { return nil }
            originalTriangleCount = rawCount
            var lo = raw[0], hi = raw[0]
            for p in raw { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
            diagonal = simd_length(hi - lo)
            guard diagonal.isFinite, diagonal > 0 else { return nil }

            // 1. Weld within 5e-7 of the diagonal (sub-micron at 100 mm).
            let idx = geometry.triangleIndices
            let rep = Self.relativeWeld(raw, idx, diagonal: diagonal)
            points = raw
            triangles = []
            exact = []
            triangles.reserveCapacity(rawCount)
            for t in 0..<rawCount {
                let i0 = Int(idx[3 * t]), i1 = Int(idx[3 * t + 1]), i2 = Int(idx[3 * t + 2])
                guard raw.indices.contains(i0), raw.indices.contains(i1), raw.indices.contains(i2) else {
                    collapsed += 1
                    continue
                }
                let a = rep[i0], b = rep[i1], c = rep[i2]
                if a == b || b == c || c == a { collapsed += 1; continue }
                triangles.append(Tri(a: a, b: b, c: c))
                // Untouched = every corner still sits at its exact original
                // position (true for exact duplicates welded together too).
                exact.append(raw[a] == raw[i0] && raw[b] == raw[i1] && raw[c] == raw[i2])
            }

            removeDoubledGroups()
            removeLooseFragments()
            removeFoldedRimFlaps()
            measureTopology()
            // Seams: surface pieces (CAD patches, loft halves) whose shared
            // edges don't share vertices leave zero-width cracks. Zip them
            // shut before anything is traced as a hole to cap.
            if boundaryEdgeCount > 0, stitchSeams() {
                measureTopology()
            }
            foundNonManifoldEdges = nonManifoldEdges
            foundOrientationConflicts = orientationConflicts
            foundBoundaryEdges = boundaryEdgeCount
            // Fix in place: only when something blocks loop tracing. A clean
            // closed solid (even one with a lone pinch vertex) never gets here.
            if nonManifoldEdges > 0 || orientationConflicts > 0 {
                healLocalDefects(pinchSeeds: [])
                if blockingReason == nil {
                    measureTopology()
                    if nonManifoldEdges > 0 || orientationConflicts > 0 {
                        blockingReason = "\(nonManifoldEdges) non-manifold and \(orientationConflicts) flipped edges are still left after healing the damaged spots — use Rebuild as solid."
                    }
                }
            }
            // A pinch (bow-tie corner) on a small hole — a pinhole or a healed
            // spot — that capping would NOT knit back together is cut away
            // too, so the refilled surface is a true 2-manifold there.
            // Pinches on an opening's rim are kept (the loop is split there
            // instead) so the rim the user sees is never trimmed; a pinch
            // away from every hole is informational.
            if blockingReason == nil, !loops.isEmpty {
                let seeds = pinchVerticesOnSmallHoles()
                if !seeds.isEmpty {
                    let before = triangles.count
                    healLocalDefects(pinchSeeds: seeds)
                    // Optional tidy-up: if it would cut too much it was
                    // reverted, and the split loops still cap fine.
                    blockingReason = nil
                    unfixableCorners = []
                    if triangles.count != before { measureTopology() }
                    if blockingReason == nil, nonManifoldEdges > 0 || orientationConflicts > 0 {
                        blockingReason = "\(nonManifoldEdges) non-manifold and \(orientationConflicts) flipped edges are still left after healing the damaged spots — use Rebuild as solid."
                    }
                }
            }
        }

        /// Corners of small holes (pinholes, healed spots) that would STILL be
        /// pinches after capping. Each time a loop passes a corner, its cap
        /// adds a wedge joining the fan the loop arrives through to the fan it
        /// leaves through; the corner ends up a proper disk only if fans and
        /// wedges form ONE cycle around it. Two holes meeting at a corner of
        /// one sheet pass that test (the caps knit the fans back together)
        /// and are left alone; a sheet touching another sheet or a closed fan
        /// at one corner does not.
        private func pinchVerticesOnSmallHoles() -> [Int] {
            var smallVertices = Set<Int>()
            for loop in loops where isPinhole(loop) || isHealLoop(loop) { smallVertices.formUnion(loop) }
            guard !smallVertices.isEmpty else { return [] }
            var facesAt: [Int: [Int]] = [:]
            for (f, t) in triangles.enumerated() {
                for v in [t.a, t.b, t.c] where smallVertices.contains(v) { facesAt[v, default: []].append(f) }
            }
            // Per corner: fan id of each incident face, and of each directed
            // boundary edge leaving / entering the corner.
            var fanOfFace: [Int: [Int: Int]] = [:]
            var fanCount: [Int: Int] = [:]
            for v in smallVertices {
                let faces = facesAt[v] ?? []
                var parent = Array(faces.indices)
                func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
                var firstWith: [Int: Int] = [:]
                for (local, f) in faces.enumerated() {
                    let t = triangles[f]
                    for n in [t.a, t.b, t.c] where n != v {
                        if let other = firstWith[n] {
                            let ra = find(local), rb = find(other)
                            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                        } else {
                            firstWith[n] = local
                        }
                    }
                }
                var map: [Int: Int] = [:]
                for (local, f) in faces.enumerated() { map[f] = find(local) }
                fanOfFace[v] = map
                fanCount[v] = Set(map.values).count
            }
            func faceWith(_ u: Int, _ w: Int, at v: Int) -> Int? {
                for f in facesAt[v] ?? [] {
                    let t = triangles[f]
                    if (t.a == u && t.b == w) || (t.b == u && t.c == w) || (t.c == u && t.a == w) { return f }
                }
                return nil
            }
            // Wedges each cap will add, as fan-to-fan links per corner.
            var links: [Int: [(Int, Int)]] = [:]
            for loop in loops {
                let n = loop.count
                for i in 0..<n where smallVertices.contains(loop[i]) {
                    let v = loop[i], prev = loop[(i + n - 1) % n], next = loop[(i + 1) % n]
                    guard (fanCount[v] ?? 1) > 1,
                          let fin = faceWith(prev, v, at: v), let fout = faceWith(v, next, at: v),
                          let a = fanOfFace[v]?[fin], let b = fanOfFace[v]?[fout] else { continue }
                    links[v, default: []].append((a, b))
                }
            }
            var seeds: [Int] = []
            for v in smallVertices where (fanCount[v] ?? 1) > 1 {
                let fans = Set(fanOfFace[v]!.values)
                var parent: [Int: Int] = Dictionary(uniqueKeysWithValues: fans.map { ($0, $0) })
                func find(_ x: Int) -> Int { var r = x; while parent[r]! != r { r = parent[r]! }; return r }
                for (a, b) in links[v] ?? [] {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[ra] = rb }
                }
                if Set(fans.map(find)).count > 1 { seeds.append(v) }
            }
            return seeds.sorted()
        }

        /// The capper's weld, relative to the bounding-box `diagonal` (so it
        /// means the same thing in inches, millimetres or a unit box): within
        /// 5e-7 of the diagonal (sub-micron at 100 mm). Exact duplicates always
        /// merge; a near-duplicate (different position) only when both
        /// vertices sit on an open edge — a seam or crack that needs closing.
        /// Interior vertices are already connected; snapping them would only
        /// move corners. Returns each vertex's cluster representative.
        static func relativeWeld(_ raw: [P3], _ idx: [Int32], diagonal: Double) -> [Int] {
            let rawCount = idx.count / 3
            return weld(raw, tolerance: 5.0e-7 * diagonal) {
                var uses: [UInt64: Int32] = [:]
                uses.reserveCapacity(rawCount * 2)
                for t in 0..<rawCount {
                    let c = [Int(idx[3 * t]), Int(idx[3 * t + 1]), Int(idx[3 * t + 2])]
                    guard c.allSatisfy({ raw.indices.contains($0) }) else { continue }
                    for (u, v) in [(c[0], c[1]), (c[1], c[2]), (c[2], c[0])] where u != v {
                        uses[undirectedKey(u, v), default: 0] += 1
                    }
                }
                var open = [Bool](repeating: false, count: raw.count)
                for (key, n) in uses where n == 1 {
                    let u = Int(key >> 32), v = Int(key & 0xffff_ffff)
                    if u < open.count { open[u] = true }
                    if v < open.count { open[v] = true }
                }
                return open
            }
        }

        /// Hash-grid weld; each cluster maps to its lowest index. `openVertices`
        /// (computed only if a near-duplicate turns up) flags vertices on an
        /// open edge; near-duplicates weld only when both are flagged.
        private static func weld(_ pts: [P3], tolerance: Double, openVertices: () -> [Bool]) -> [Int] {
            struct Cell: Hashable { var x: Int64; var y: Int64; var z: Int64 }
            let inv = 1.0 / tolerance
            func cell(_ p: P3) -> Cell {
                Cell(x: Int64((p.x * inv).rounded(.down)), y: Int64((p.y * inv).rounded(.down)), z: Int64((p.z * inv).rounded(.down)))
            }
            var grid: [Cell: [Int]] = [:]
            grid.reserveCapacity(pts.count)
            var rep = Array(0..<pts.count)
            let tol2 = tolerance * tolerance
            var open: [Bool]? = nil
            for (i, p) in pts.enumerated() {
                let c = cell(p)
                var found = -1
                search: for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    guard let bucket = grid[Cell(x: c.x + Int64(dx), y: c.y + Int64(dy), z: c.z + Int64(dz))] else { continue }
                    for j in bucket where simd_length_squared(pts[j] - p) <= tol2 {
                        if pts[j] != p {
                            if open == nil { open = openVertices() }
                            guard open![i], open![j] else { continue }
                        }
                        found = j
                        break search
                    }
                } } }
                if found >= 0 {
                    rep[i] = found
                } else {
                    grid[c, default: []].append(i)
                }
            }
            return rep
        }

        private static func undirectedKey(_ u: Int, _ v: Int) -> UInt64 {
            let lo = UInt64(min(u, v)), hi = UInt64(max(u, v))
            return (lo << 32) | hi
        }

        private static func directedKey(_ u: Int, _ v: Int) -> UInt64 {
            (UInt64(u) << 32) | UInt64(v)
        }

        private func edgeUseCounts() -> [UInt64: Int] {
            var uses: [UInt64: Int] = [:]
            uses.reserveCapacity(triangles.count * 2)
            for t in triangles {
                uses[Self.undirectedKey(t.a, t.b), default: 0] += 1
                uses[Self.undirectedKey(t.b, t.c), default: 0] += 1
                uses[Self.undirectedKey(t.c, t.a), default: 0] += 1
            }
            return uses
        }

        /// Triangles on the same three corners. If removing the whole group
        /// leaves each of its edges with 0 or 2 users, the group is an extra
        /// zero-volume flap (remove all). If each edge has exactly one other
        /// user, keep the single triangle that pairs with them.
        private mutating func removeDoubledGroups() {
            var groups: [SIMD3<Int>: [Int]] = [:]
            for (i, t) in triangles.enumerated() {
                var s = [t.a, t.b, t.c]; s.sort()
                groups[SIMD3(s[0], s[1], s[2]), default: []].append(i)
            }
            let multi = groups.values.filter { $0.count > 1 }
            guard !multi.isEmpty else { return }
            let uses = edgeUseCounts()
            var directed: [UInt64: Int] = [:]
            for t in triangles {
                directed[Self.directedKey(t.a, t.b), default: 0] += 1
                directed[Self.directedKey(t.b, t.c), default: 0] += 1
                directed[Self.directedKey(t.c, t.a), default: 0] += 1
            }
            var remove = Set<Int>()
            for group in multi {
                let t = triangles[group[0]]
                let k = group.count
                let external = [
                    (uses[Self.undirectedKey(t.a, t.b)] ?? 0) - k,
                    (uses[Self.undirectedKey(t.b, t.c)] ?? 0) - k,
                    (uses[Self.undirectedKey(t.c, t.a)] ?? 0) - k,
                ]
                // Every edge left with 0 or 2 users: the group is a zero-volume
                // flap folded onto (or floating off) the surface — remove it all
                // without opening a hole.
                if external.allSatisfy({ $0 == 0 || $0 == 2 }) {
                    remove.formUnion(group)
                    doubledGroups += 1
                    doubledSeeds.append((t, group.count))
                } else if external.allSatisfy({ $0 == 1 }) {
                    // Keep the member whose edges run opposite to its neighbours'.
                    var groupDirected: [UInt64: Int] = [:]
                    for f in group {
                        let g = triangles[f]
                        groupDirected[Self.directedKey(g.a, g.b), default: 0] += 1
                        groupDirected[Self.directedKey(g.b, g.c), default: 0] += 1
                        groupDirected[Self.directedKey(g.c, g.a), default: 0] += 1
                    }
                    func externalReverse(_ u: Int, _ v: Int) -> Int {
                        (directed[Self.directedKey(v, u)] ?? 0) - (groupDirected[Self.directedKey(v, u)] ?? 0)
                    }
                    let best = group.max { lhs, rhs in
                        let l = triangles[lhs], r = triangles[rhs]
                        let ls = externalReverse(l.a, l.b) + externalReverse(l.b, l.c) + externalReverse(l.c, l.a)
                        let rs = externalReverse(r.a, r.b) + externalReverse(r.b, r.c) + externalReverse(r.c, r.a)
                        return ls < rs
                    } ?? group[0]
                    remove.formUnion(group.filter { $0 != best })
                    doubledGroups += 1
                    doubledSeeds.append((t, group.count - 1))
                }
            }
            guard !remove.isEmpty else { return }
            doubledRemoved = remove.count
            filterTriangles { !remove.contains($0) }
        }

        /// Drop tiny edge-connected fragments that are open or enclose no
        /// volume (loose triangles, specks). Closed bodies with real volume are
        /// never removed, however small (an i-dot, a jump ring).
        private mutating func removeLooseFragments() {
            guard triangles.count > 1 else { return }
            var parent = Array(0..<triangles.count)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                var y = x
                while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
                return r
            }
            var firstFaceOfEdge: [UInt64: Int] = [:]
            for (i, t) in triangles.enumerated() {
                for key in [Self.undirectedKey(t.a, t.b), Self.undirectedKey(t.b, t.c), Self.undirectedKey(t.c, t.a)] {
                    if let other = firstFaceOfEdge[key] {
                        let ra = find(i), rb = find(other)
                        if ra != rb { parent[ra] = rb }
                    } else {
                        firstFaceOfEdge[key] = i
                    }
                }
            }
            let uses = edgeUseCounts()
            var area: [Int: Double] = [:]
            var volume: [Int: Double] = [:]
            var open: Set<Int> = []
            for (i, t) in triangles.enumerated() {
                let r = find(i)
                let p0 = points[t.a], p1 = points[t.b], p2 = points[t.c]
                area[r, default: 0] += 0.5 * simd_length(simd_cross(p1 - p0, p2 - p0))
                volume[r, default: 0] += simd_dot(p0, simd_cross(p1, p2)) / 6
                if uses[Self.undirectedKey(t.a, t.b)] == 1 || uses[Self.undirectedKey(t.b, t.c)] == 1
                    || uses[Self.undirectedKey(t.c, t.a)] == 1 {
                    open.insert(r)
                }
            }
            guard area.count > 1, let main = area.max(by: { $0.value < $1.value })?.key else { return }
            let mainArea = area[main] ?? 0
            let tinyVolume = 1.0e-9 * diagonal * diagonal * diagonal
            var drop = Set<Int>()
            for (root, a) in area where root != main && a < 1.0e-3 * mainArea {
                if open.contains(root) || abs(volume[root] ?? 0) <= tinyVolume {
                    drop.insert(root)
                }
            }
            guard !drop.isEmpty else { return }
            looseFragments += drop.count
            let before = triangles.count
            var keepFlags = [Bool](repeating: true, count: triangles.count)
            var fragmentCorners: [Int: (vertices: Set<Int>, triangles: Int)] = [:]
            for i in triangles.indices {
                let r = find(i)
                guard drop.contains(r) else { continue }
                keepFlags[i] = false
                let t = triangles[i]
                fragmentCorners[r, default: ([], 0)].vertices.formUnion([t.a, t.b, t.c])
                fragmentCorners[r, default: ([], 0)].triangles += 1
            }
            for root in fragmentCorners.keys.sorted() {
                let fragment = fragmentCorners[root]!
                looseSeeds.append((fragment.vertices.sorted(), fragment.triangles))
            }
            filterTriangles { keepFlags[$0] }
            looseRemoved += before - triangles.count
        }

        /// A rim sliver folded flat back onto the triangle across its one
        /// shared edge: two of its edges are open, its tip lies over that
        /// shared edge within 2% of the edge's length, and it faces the
        /// opposite way to its neighbour (a zero-volume flap lying on the
        /// surface). The opening's rim runs out along the flap and straight
        /// back, so any cap has to squeeze between the flap and the surface
        /// under it; removing the flap leaves the rim on the shared edge.
        private mutating func removeFoldedRimFlaps() {
            var facesOfEdge: [UInt64: [Int]] = [:]
            facesOfEdge.reserveCapacity(triangles.count * 2)
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    facesOfEdge[Self.undirectedKey(u, v), default: []].append(i)
                }
            }
            var remove = Set<Int>()
            for (i, t) in triangles.enumerated() {
                var shared: (Int, Int, Int)? = nil   // (base u, base v, apex)
                var open = 0
                for (u, v, w) in [(t.a, t.b, t.c), (t.b, t.c, t.a), (t.c, t.a, t.b)] {
                    let n = facesOfEdge[Self.undirectedKey(u, v)]?.count ?? 0
                    if n == 1 { open += 1 } else if n == 2 { shared = (u, v, w) }
                }
                guard open == 2, let (u, v, apex) = shared,
                      let across = facesOfEdge[Self.undirectedKey(u, v)]?.first(where: { $0 != i }),
                      !remove.contains(across) else { continue }
                let a = points[u], b = points[v], p = points[apex]
                let base = b - a
                let length = simd_length(base)
                guard length > 0 else { continue }
                let along = simd_dot(p - a, base) / (length * length)
                let height = simd_length(simd_cross(base, p - a)) / length
                guard along > 0, along < 1, height < 0.02 * length else { continue }
                let o = triangles[across]
                let n1 = simd_cross(points[t.b] - points[t.a], points[t.c] - points[t.a])
                let n2 = simd_cross(points[o.b] - points[o.a], points[o.c] - points[o.a])
                let l1 = simd_length(n1), l2 = simd_length(n2)
                guard l1 > 0, l2 > 0, simd_dot(n1, n2) < -0.9 * l1 * l2 else { continue }
                remove.insert(i)
            }
            guard !remove.isEmpty else { return }
            foldedFlaps = remove.count
            filterTriangles { !remove.contains($0) }
        }

        private mutating func filterTriangles(_ keep: (Int) -> Bool) {
            var t2: [Tri] = [], e2: [Bool] = []
            t2.reserveCapacity(triangles.count)
            e2.reserveCapacity(triangles.count)
            for i in triangles.indices where keep(i) {
                t2.append(triangles[i])
                e2.append(exact[i])
            }
            triangles = t2
            exact = e2
        }

        /// Non-manifold / orientation counts and boundary loops. Loops are
        /// traced along boundary half-edges by walking the triangle fan around
        /// each vertex, so a pinched rim (two loops meeting at one vertex)
        /// splits into separate simple loops.
        private mutating func measureTopology() {
            let uses = edgeUseCounts()
            var faceOfDirected: [UInt64: Int] = [:]
            faceOfDirected.reserveCapacity(triangles.count * 3)
            var duplicatedDirected = Set<UInt64>()
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let k = Self.directedKey(u, v)
                    if faceOfDirected[k] != nil { duplicatedDirected.insert(k) } else { faceOfDirected[k] = i }
                }
            }
            nonManifoldEdges = uses.values.filter { $0 > 2 }.count
            orientationConflicts = 0
            for k in duplicatedDirected {
                let u = Int(k >> 32), v = Int(k & 0xffff_ffff)
                if uses[Self.undirectedKey(u, v)] == 2 { orientationConflicts += 1 }
            }
            boundaryEdgeCount = uses.values.filter { $0 == 1 }.count
            guard boundaryEdgeCount > 0, nonManifoldEdges == 0, orientationConflicts == 0 else {
                loops = []
                return
            }

            func third(_ t: Tri, _ u: Int, _ v: Int) -> Int {
                if t.a != u && t.a != v { return t.a }
                if t.b != u && t.b != v { return t.b }
                return t.c
            }
            func isBoundary(_ u: Int, _ v: Int) -> Bool { uses[Self.undirectedKey(u, v)] == 1 }

            var visited = Set<UInt64>()
            var found: [[Int]] = []
            var splits = 0
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] where isBoundary(u, v) {
                    let startKey = Self.directedKey(u, v)
                    if visited.contains(startKey) { continue }
                    var loop: [Int] = []
                    var cu = u, cv = v, cf = i
                    var ok = true
                    while true {
                        visited.insert(Self.directedKey(cu, cv))
                        loop.append(cu)
                        // Rotate around cv from face cf until the next boundary edge.
                        var f = cf
                        var w = third(triangles[f], cu, cv)   // edge cv -> w in face f
                        var guardSteps = 0
                        while !isBoundary(cv, w) {
                            guard let g = faceOfDirected[Self.directedKey(w, cv)] else { ok = false; break }
                            f = g
                            w = third(triangles[g], w, cv)
                            guardSteps += 1
                            if guardSteps > 10_000 { ok = false; break }
                        }
                        if !ok { break }
                        cu = cv; cv = w; cf = f
                        if Self.directedKey(cu, cv) == startKey { break }
                        if visited.contains(Self.directedKey(cu, cv)) { ok = false; break }
                        if loop.count > boundaryEdgeCount { ok = false; break }
                    }
                    if ok, loop.count >= 3 {
                        let simple = Self.splitAtRepeatedVertices(loop)
                        if simple.count > 1 { splits += simple.count - 1 }
                        found.append(contentsOf: simple)
                    }
                }
            }
            loops = found
            pinchSplits = splits
        }

        /// A traced loop that passes through the same vertex twice (a pinch:
        /// two holes, or two lobes of one hole, meeting at a single corner) is
        /// split there into simple loops, each capped on its own. Capping the
        /// figure-eight as one polygon would make zero-length chords and
        /// collapsed triangles at the pinch.
        static func splitAtRepeatedVertices(_ loop: [Int]) -> [[Int]] {
            var out: [[Int]] = []
            var stack: [Int] = []
            var position: [Int: Int] = [:]
            for v in loop {
                if let j = position[v] {
                    let sub = Array(stack[j...])
                    for w in stack[(j + 1)...] { position[w] = nil }
                    stack.removeSubrange((j + 1)...)
                    if sub.count >= 3 { out.append(sub) }
                } else {
                    position[v] = stack.count
                    stack.append(v)
                }
            }
            if stack.count >= 3 { out.append(stack) }
            return out
        }

        // MARK: Seam stitching (zip cracks between surface pieces)

        /// A boundary corner counts as lying ON another boundary edge when it
        /// is within this fraction of that edge's length (and ON another
        /// boundary corner within this fraction of the shorter open edge at
        /// either corner). Cracks in real exports sit ~10× inside this
        /// (Cupping and TeaPot1: ≤ 0.011 of the edge length), and the
        /// matches found don't change between 0.05 and 0.1.
        static let seamTolerance = 0.1
        /// A corner only joins an edge that runs along one of its own open
        /// edges (|cos| of the angle between them at least this).
        static let seamAlignment = 0.7
        static let maxSeamRounds = 12

        /// Closes zero-width cracks between surface pieces whose shared edges
        /// don't share corners (CAD patches meeting in T-junctions, loft
        /// halves with slit seams), ignoring winding:
        ///  1. a boundary corner lying on another boundary corner (not already
        ///     joined to it by an edge) is welded to it;
        ///  2. a boundary corner lying on another boundary edge is set INTO
        ///     that edge: the edge's triangle is split at the corner (the
        ///     corner keeps its exact position), so both sides of the crack
        ///     end up with the same corners and the crack closes with no new
        ///     area.
        /// Repeated until nothing is left to join. Never a large weld: every
        /// match is relative to the local edge length. Afterwards, surface
        /// pieces whose winding disagrees with the piece they were stitched to
        /// are turned over as a whole (`orientStitchedPatches`). Untouched
        /// triangles keep their exact corners; split triangles and triangles
        /// on a welded corner are counted as touched. Returns true if
        /// anything changed.
        private mutating func stitchSeams() -> Bool {
            // Surface pieces before stitching: triangles joined across edges
            // shared by exactly two triangles.
            let usesBefore = edgeUseCounts()
            var patch = patchLabels(usesBefore)
            var openBefore = Set<Int>()
            for (key, n) in usesBefore where n == 1 {
                openBefore.insert(Int(key >> 32)); openBefore.insert(Int(key & 0xffff_ffff))
            }
            var changed = false
            let f = Self.seamTolerance

            for _ in 0..<Self.maxSeamRounds {
                var uses = edgeUseCounts()
                // Boundary half-edges in their triangle's winding order.
                var eU: [Int] = [], eV: [Int] = [], eFace: [Int] = [], eThird: [Int] = []
                for (i, t) in triangles.enumerated() {
                    for (u, v, w) in [(t.a, t.b, t.c), (t.b, t.c, t.a), (t.c, t.a, t.b)]
                    where uses[Self.undirectedKey(u, v)] == 1 {
                        eU.append(u); eV.append(v); eFace.append(i); eThird.append(w)
                    }
                }
                guard !eU.isEmpty else { break }
                var openEdgesAt: [Int: [Int]] = [:]
                var lengths = [Double](repeating: 0, count: eU.count)
                for e in eU.indices {
                    lengths[e] = simd_length(points[eV[e]] - points[eU[e]])
                    openEdgesAt[eU[e], default: []].append(e)
                    openEdgesAt[eV[e], default: []].append(e)
                }
                /// Shortest open edge at a boundary corner.
                func shortestOpen(_ v: Int) -> Double {
                    (openEdgesAt[v] ?? []).map { lengths[$0] }.min() ?? 0
                }

                // Hash grid of open edges, each inflated by its own tolerance.
                let sorted = lengths.sorted()
                let median = sorted[sorted.count / 2]
                let cellSize = max(median, (sorted.last ?? 0) / 8, 1.0e-9 * diagonal)
                struct Cell: Hashable { var x: Int64; var y: Int64; var z: Int64 }
                func cell(_ p: P3) -> Cell {
                    Cell(x: Int64((p.x / cellSize).rounded(.down)), y: Int64((p.y / cellSize).rounded(.down)),
                         z: Int64((p.z / cellSize).rounded(.down)))
                }
                var grid: [Cell: [Int]] = [:]
                for e in eU.indices where lengths[e] > 0 {
                    let pad = P3(repeating: f * lengths[e])
                    let lo = cell(pointwiseMin(points[eU[e]], points[eV[e]]) - pad)
                    let hi = cell(pointwiseMax(points[eU[e]], points[eV[e]]) + pad)
                    for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z {
                        grid[Cell(x: x, y: y, z: z), default: []].append(e)
                    } } }
                }

                var welds: [(Int, Int)] = []
                var inserts: [Int: [(t: Double, v: Int)]] = [:]   // open edge -> corners to set into it
                for (w, own) in openEdgesAt.sorted(by: { $0.key < $1.key }) {
                    let p = points[w]
                    let wShort = shortestOpen(w)
                    guard wShort > 0 else { continue }
                    var bestWeld: (d: Double, x: Int)? = nil
                    var bestSplit: (d: Double, e: Int, t: Double)? = nil
                    for e in grid[cell(p)] ?? [] {
                        let u = eU[e], v = eV[e]
                        if u == w || v == w || eThird[e] == w { continue }
                        // 1. Corner on corner.
                        for x in [u, v] where uses[Self.undirectedKey(w, x)] == nil {
                            let d = simd_length(points[x] - p)
                            if d <= f * min(wShort, shortestOpen(x)), bestWeld.map({ d < $0.d || (d == $0.d && x < $0.x) }) ?? true {
                                bestWeld = (d, x)
                            }
                        }
                        // 2. Corner on the inside of an edge that runs along
                        //    one of the corner's own open edges.
                        let a = points[u], ab = points[v] - a
                        let len = lengths[e]
                        guard len > 0 else { continue }
                        let t = simd_dot(p - a, ab) / (len * len)
                        guard t > 0, t < 1 else { continue }
                        let d = simd_length(p - (a + t * ab))
                        guard d <= f * len, d < t * len, d < (1 - t) * len else { continue }
                        let dir = ab / len
                        var aligned = false
                        for o in own {
                            let other = eU[o] == w ? eV[o] : eU[o]
                            let od = points[other] - p
                            let ol = simd_length(od)
                            if ol > 0, abs(simd_dot(od / ol, dir)) >= Self.seamAlignment { aligned = true; break }
                        }
                        guard aligned else { continue }
                        if bestSplit.map({ d < $0.d }) ?? true { bestSplit = (d, e, t) }
                    }
                    if let weld = bestWeld {
                        welds.append((w, weld.x))
                    } else if let split = bestSplit {
                        inserts[split.e, default: []].append((split.t, w))
                    }
                }

                // Apply one join at a time, each only if the surface stays
                // clean: no edge may end up with more than two triangles and
                // no two triangles may sit on the same three corners. Both
                // sides of a real crack always pass; a flap or fold that
                // merely touches itself does not, and is left alone.
                func edgeKeys(_ t: Tri) -> [UInt64] {
                    [Self.undirectedKey(t.a, t.b), Self.undirectedKey(t.b, t.c), Self.undirectedKey(t.c, t.a)]
                }
                func cornerKey(_ t: Tri) -> SIMD3<Int> {
                    let lo = min(t.a, t.b, t.c), hi = max(t.a, t.b, t.c)
                    return SIMD3(lo, t.a + t.b + t.c - lo - hi, hi)
                }
                /// Edge-use changes from replacing `old` by `new` triangles,
                /// if no edge ends up over two users.
                func usesDelta(removing old: [Tri], adding new: [Tri]) -> [UInt64: Int]? {
                    var delta: [UInt64: Int] = [:]
                    for t in old { for k in edgeKeys(t) { delta[k, default: 0] -= 1 } }
                    for t in new { for k in edgeKeys(t) { delta[k, default: 0] += 1 } }
                    for (k, d) in delta where d > 0 && (uses[k] ?? 0) + d > 2 { return nil }
                    return delta
                }
                func commit(_ delta: [UInt64: Int]) {
                    for (k, d) in delta where d != 0 {
                        let n = (uses[k] ?? 0) + d
                        uses[k] = n > 0 ? n : nil
                    }
                }
                var involved = Set<Int>()
                for (a, b) in welds { involved.insert(a); involved.insert(b) }
                var facesAt: [Int: [Int]] = [:]
                var cornerSets = Set<SIMD3<Int>>()
                cornerSets.reserveCapacity(triangles.count)
                for (i, t) in triangles.enumerated() {
                    cornerSets.insert(cornerKey(t))
                    for v in [t.a, t.b, t.c] where involved.contains(v) { facesAt[v, default: []].append(i) }
                }

                // 1. Corner on corner: weld (the lower index keeps its position).
                var alias: [Int: Int] = [:]
                func resolve(_ x: Int) -> Int {
                    var r = x
                    while let n = alias[r] { r = n }
                    return r
                }
                var welded = 0
                for (a0, b0) in welds {
                    let a = resolve(a0), b = resolve(b0)
                    guard a != b else { continue }
                    let keep = min(a, b), drop = max(a, b)
                    let faces = facesAt[drop] ?? []
                    var replaced: [Tri] = []
                    var newKeys = Set<SIMD3<Int>>()
                    var ok = true
                    for f in faces {
                        let t = triangles[f]
                        let n = Tri(a: t.a == drop ? keep : t.a, b: t.b == drop ? keep : t.b, c: t.c == drop ? keep : t.c)
                        // Both corners on one triangle (joined by an edge) or
                        // a triangle that already exists: not a crack.
                        if n.a == n.b || n.b == n.c || n.c == n.a || cornerSets.contains(cornerKey(n))
                            || !newKeys.insert(cornerKey(n)).inserted {
                            ok = false
                            break
                        }
                        replaced.append(n)
                    }
                    guard ok, let delta = usesDelta(removing: faces.map { triangles[$0] }, adding: replaced) else { continue }
                    for (f, n) in zip(faces, replaced) {
                        cornerSets.remove(cornerKey(triangles[f]))
                        cornerSets.insert(cornerKey(n))
                        triangles[f] = n
                        exact[f] = false
                    }
                    commit(delta)
                    facesAt[keep, default: []] += faces
                    facesAt[drop] = nil
                    alias[drop] = keep
                    welded += 1
                }
                if welded > 0 {
                    seamCornersJoined += welded
                    changed = true
                    continue   // re-measure before setting corners into edges
                }

                // 2. Corner on edge: split the edge's triangle at the corners
                //    set into it (the corners keep their exact positions).
                var didSplit = false
                for e in inserts.keys.sorted() {
                    let face = eFace[e]
                    let u = eU[e], v = eV[e], apex = eThird[e]
                    let t = triangles[face]
                    // Skip a triangle already split this round (next round).
                    guard (t.a == u && t.b == v && t.c == apex) || (t.b == u && t.c == v && t.a == apex)
                            || (t.c == u && t.a == v && t.b == apex) else { continue }
                    var seen = Set<Int>()
                    let corners = inserts[e]!.sorted { $0.t < $1.t }.map(\.v)
                        .filter { $0 != u && $0 != v && $0 != apex && seen.insert($0).inserted }
                    guard !corners.isEmpty else { continue }
                    let chain = [u] + corners + [v]
                    let pieces = (0..<(chain.count - 1)).map { Tri(a: chain[$0], b: chain[$0 + 1], c: apex) }
                    let keys = pieces.map(cornerKey)
                    guard Set(keys).count == keys.count, !keys.contains(where: cornerSets.contains),
                          let delta = usesDelta(removing: [t], adding: pieces) else { continue }
                    cornerSets.remove(cornerKey(t))
                    for k in keys { cornerSets.insert(k) }
                    triangles[face] = pieces[0]
                    exact[face] = false
                    for piece in pieces.dropFirst() {
                        triangles.append(piece)
                        exact.append(false)
                        patch.append(patch[face])
                    }
                    commit(delta)
                    seamCornersJoined += corners.count
                    didSplit = true
                }
                guard didSplit else { break }
                changed = true
            }
            guard changed else { return false }
            orientStitchedPatches(patch)
            // Two sides of a crack that were each other's mirror can leave a
            // doubled pair; tidy it like the first cleanup did.
            let doubledBefore = doubledRemoved
            doubledRemoved = 0
            removeDoubledGroups()
            doubledRemoved += doubledBefore
            // Separate seams = connected runs of edges the stitch closed
            // (now shared by two triangles, between corners that were open).
            var parent: [Int: Int] = [:]
            func find(_ x: Int) -> Int {
                var r = x
                while let p = parent[r], p != r { r = p }
                return r
            }
            for (key, n) in edgeUseCounts() where n == 2 && usesBefore[key] != 2 {
                let a = Int(key >> 32), b = Int(key & 0xffff_ffff)
                guard openBefore.contains(a), openBefore.contains(b) else { continue }
                if parent[a] == nil { parent[a] = a }
                if parent[b] == nil { parent[b] = b }
                let ra = find(a), rb = find(b)
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
            seamsStitched = Set(parent.keys.map(find)).count
            var seamCorners: [Int: [Int]] = [:]
            for v in parent.keys.sorted() { seamCorners[find(v), default: []].append(v) }
            seamSeeds = seamCorners.keys.sorted().map { seamCorners[$0]! }
            return true
        }

        /// Surface pieces: triangles joined across edges with exactly two users.
        private func patchLabels(_ uses: [UInt64: Int]) -> [Int] {
            var parent = Array(triangles.indices)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                var y = x
                while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
                return r
            }
            var firstFace: [UInt64: Int] = [:]
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let key = Self.undirectedKey(u, v)
                    guard uses[key] == 2 else { continue }
                    if let other = firstFace[key] {
                        let ra = find(i), rb = find(other)
                        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                    } else {
                        firstFace[key] = i
                    }
                }
            }
            return triangles.indices.map(find)
        }

        /// After stitching: walk the stitched pieces outward from the
        /// largest one; a piece whose winding disagrees with the piece it was
        /// stitched to is turned over as a whole. (The whole surface is turned
        /// right side out later, from the enclosed volume.) Pieces that
        /// disagree with themselves are left to fix-in-place.
        private mutating func orientStitchedPatches(_ patch: [Int]) {
            let uses = edgeUseCounts()
            var firstUse: [UInt64: (face: Int, forward: Bool)] = [:]
            var links: [Int: [(other: Int, flip: Bool)]] = [:]
            var disagreements = 0
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let key = Self.undirectedKey(u, v)
                    guard uses[key] == 2 else { continue }
                    let forward = u < v
                    if let first = firstUse[key] {
                        let p = patch[i], q = patch[first.face]
                        guard p != q else { continue }
                        // Same direction on the shared edge = opposite winding.
                        let flip = first.forward == forward
                        if flip { disagreements += 1 }
                        links[p, default: []].append((q, flip))
                        links[q, default: []].append((p, flip))
                    } else {
                        firstUse[key] = (i, forward)
                    }
                }
            }
            guard disagreements > 0 else { return }
            var area: [Int: Double] = [:]
            for (i, t) in triangles.enumerated() {
                area[patch[i], default: 0] += simd_length(simd_cross(points[t.b] - points[t.a], points[t.c] - points[t.a]))
            }
            var parity: [Int: Bool] = [:]
            for seed in area.keys.sorted(by: { area[$0]! != area[$1]! ? area[$0]! > area[$1]! : $0 < $1 })
            where parity[seed] == nil && links[seed] != nil {
                parity[seed] = false
                var queue = [seed]
                var head = 0
                while head < queue.count {
                    let p = queue[head]; head += 1
                    for link in links[p] ?? [] where parity[link.other] == nil {
                        parity[link.other] = parity[p]! != link.flip
                        queue.append(link.other)
                    }
                }
            }
            let reverse = Set(parity.filter { $0.value }.map(\.key))
            guard !reverse.isEmpty else { return }
            var pieceCorners: [Int: (vertices: Set<Int>, triangles: Int)] = [:]
            for i in triangles.indices where reverse.contains(patch[i]) {
                let t = triangles[i]
                triangles[i] = Tri(a: t.a, b: t.c, c: t.b)
                pieceCorners[patch[i], default: ([], 0)].vertices.formUnion([t.a, t.b, t.c])
                pieceCorners[patch[i], default: ([], 0)].triangles += 1
            }
            patchesReversed = reverse.count
            reversedPieceSeeds = pieceCorners.keys.sorted().map {
                (pieceCorners[$0]!.vertices.sorted(), pieceCorners[$0]!.triangles)
            }
        }

        // MARK: Fix in place (cut out damaged spots; the capper refills them)

        /// Most of the surface fix-in-place may cut out before the damage
        /// counts as widespread — then Rebuild as solid is the honest answer.
        static let maxStripFraction = 0.05
        /// Rounds of pinch clean-up / orientation repair before giving up.
        static let maxHealRounds = 16

        /// Cuts out the triangles at each damaged spot so the loop tracer and
        /// the capper can refill the holes, instead of rebuilding the surface:
        ///  1. every triangle on an edge shared by three or more triangles;
        ///  2. at every corner of a cut-out triangle (and every `pinchSeeds`
        ///     corner) that is a pinch — several separate triangle fans meet
        ///     there — AND touches a hole: every open fan except the one kept.
        ///     A closed fan is kept if there is one (it is intact surface,
        ///     maybe a whole small body touching at that corner); otherwise
        ///     the largest open fan. Repeated until no such pinch is left, so
        ///     the healed surface is a true 2-manifold there. (Cutting fans
        ///     was chosen over splitting the vertex per fan: a split leaves two
        ///     coincident corners that the refill joins with zero-length
        ///     edges, and a position-welding consumer sees the pinch again.)
        ///     Pinches away from any hole — a lone bow-tie on an otherwise
        ///     closed solid — are left alone;
        ///  3. triangles wound against their neighbours are turned over (per
        ///     connected piece, the smaller-area side flips); triangles where
        ///     the winding can't be made consistent (a twist) are cut out.
        /// Tiny pieces left floating are dropped by the loose-fragment pass.
        /// Self-intersections are never touched. Every triangle not cut out
        /// keeps its exact corners. If more than `maxStripFraction` of the
        /// surface would go, nothing is changed and `blockingReason` says why.
        private mutating func healLocalDefects(pinchSeeds: [Int]) {
            let count = triangles.count
            guard count > 0 else { return }
            let savedTriangles = triangles
            let savedExact = exact
            let savedLooseFragments = looseFragments
            let savedLooseRemoved = looseRemoved
            let savedFlipped = trianglesFlipped
            let savedLooseSeeds = looseSeeds
            let savedFlippedCorners = flippedCorners

            var uses = edgeUseCounts()
            if preexistingBoundary == nil {
                preexistingBoundary = Set(uses.lazy.filter { $0.value == 1 }.map(\.key))
            }
            var active = [Bool](repeating: true, count: count)
            var strippedFaces: [Int] = []
            func strip(_ f: Int) {
                guard active[f] else { return }
                active[f] = false
                strippedFaces.append(f)
                let t = triangles[f]
                uses[Self.undirectedKey(t.a, t.b), default: 1] -= 1
                uses[Self.undirectedKey(t.b, t.c), default: 1] -= 1
                uses[Self.undirectedKey(t.c, t.a), default: 1] -= 1
            }

            // 1. Triangles on non-manifold edges (marked first, then cut, so
            //    every user of such an edge goes).
            var onNonManifold: [Int] = []
            var nonManifoldCorners = Set<Int>()
            for (f, t) in triangles.enumerated() {
                var hit = false
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] where (uses[Self.undirectedKey(u, v)] ?? 0) > 2 {
                    nonManifoldCorners.insert(u); nonManifoldCorners.insert(v)
                    hit = true
                }
                if hit { onNonManifold.append(f) }
            }
            for f in onNonManifold { strip(f) }

            // Vertex -> incident triangles (CSR), for the pinch clean-up.
            var start = [Int](repeating: 0, count: points.count + 1)
            for t in triangles { start[t.a + 1] += 1; start[t.b + 1] += 1; start[t.c + 1] += 1 }
            for v in 0..<points.count { start[v + 1] += start[v] }
            var incident = [Int32](repeating: 0, count: start[points.count])
            var cursor = start
            for (f, t) in triangles.enumerated() {
                for v in [t.a, t.b, t.c] { incident[cursor[v]] = Int32(f); cursor[v] += 1 }
            }

            func corners(of faces: [Int]) -> [Int] {
                var set = Set<Int>()
                for f in faces { let t = triangles[f]; set.insert(t.a); set.insert(t.b); set.insert(t.c) }
                return set.sorted()
            }

            /// Cut every fan but the largest at pinch corners that touch a hole.
            func resolvePinches(around seeds: [Int], extraVertices: [Int] = []) {
                var candidates = Array(Set(corners(of: seeds)).union(extraVertices)).sorted()
                for _ in 0..<Self.maxHealRounds {
                    guard !candidates.isEmpty else { return }
                    var cutThisRound: [Int] = []
                    for v in candidates {
                        var faces: [Int] = []
                        for s in start[v]..<start[v + 1] where active[Int(incident[s])] { faces.append(Int(incident[s])) }
                        guard faces.count >= 2 else { continue }
                        var parent = Array(0..<faces.count)
                        func find(_ x: Int) -> Int {
                            var r = x
                            while parent[r] != r { r = parent[r] }
                            return r
                        }
                        var firstWith: [Int: Int] = [:]
                        var openFace = [Bool](repeating: false, count: faces.count)
                        for (local, f) in faces.enumerated() {
                            let t = triangles[f]
                            for n in [t.a, t.b, t.c] where n != v {
                                let u = uses[Self.undirectedKey(v, n)] ?? 0
                                if u == 1 { openFace[local] = true }
                                guard u == 2 else { continue }
                                if let other = firstWith[n] {
                                    let ra = find(local), rb = find(other)
                                    if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                                } else {
                                    firstWith[n] = local
                                }
                            }
                        }
                        guard openFace.contains(true) else { continue }   // lone closed bow-tie: leave it
                        var fanSize: [Int: Int] = [:]
                        var fanOpen: [Int: Bool] = [:]
                        for local in faces.indices {
                            let r = find(local)
                            fanSize[r, default: 0] += 1
                            if openFace[local] { fanOpen[r] = true }
                        }
                        guard fanSize.count > 1 else { continue }
                        // Keep a closed fan if there is one (it belongs to
                        // intact surface — possibly a whole small body), else
                        // the largest open fan (ties: the one holding the
                        // lowest-numbered triangle, for determinism).
                        let closedFans = fanSize.filter { fanOpen[$0.key] != true }
                        let pool = closedFans.isEmpty ? fanSize : closedFans
                        let keep = pool.max { lhs, rhs in
                            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
                        }!.key
                        for (local, f) in faces.enumerated() where find(local) != keep {
                            strip(f)
                            cutThisRound.append(f)
                        }
                    }
                    candidates = corners(of: cutThisRound)
                }
            }

            /// Make the winding consistent across every manifold edge. Returns
            /// the triangles at twists (edges where it can't be consistent).
            func orientConsistently() -> [Int] {
                var mate = [Int32](repeating: -1, count: 3 * count)
                var firstHalf: [UInt64: Int32] = [:]
                for f in 0..<count where active[f] {
                    let t = triangles[f]
                    let e = [(t.a, t.b), (t.b, t.c), (t.c, t.a)]
                    for i in 0..<3 {
                        let key = Self.undirectedKey(e[i].0, e[i].1)
                        guard uses[key] == 2 else { continue }
                        let h = Int32(3 * f + i)
                        if let g = firstHalf[key] { mate[Int(h)] = g; mate[Int(g)] = h } else { firstHalf[key] = h }
                    }
                }
                func tail(_ h: Int) -> Int {
                    let t = triangles[h / 3]
                    switch h % 3 { case 0: return t.a; case 1: return t.b; default: return t.c }
                }
                var parity = [Int8](repeating: -1, count: count)
                var twisted = Set<Int>()
                var queue: [Int] = []
                for seed in 0..<count where active[seed] && parity[seed] < 0 {
                    parity[seed] = 0
                    queue.removeAll(keepingCapacity: true)
                    queue.append(seed)
                    var head = 0
                    var area: [Double] = [0, 0]
                    while head < queue.count {
                        let f = queue[head]; head += 1
                        let t = triangles[f]
                        area[Int(parity[f])] += simd_length(simd_cross(points[t.b] - points[t.a], points[t.c] - points[t.a]))
                        for i in 0..<3 {
                            let g = Int(mate[3 * f + i])
                            guard g >= 0 else { continue }
                            // Same direction on the shared edge = opposite winding.
                            let same = tail(3 * f + i) == tail(g)
                            let want: Int8 = parity[f] ^ (same ? 1 : 0)
                            let gf = g / 3
                            if parity[gf] < 0 {
                                parity[gf] = want
                                queue.append(gf)
                            } else if parity[gf] != want {
                                twisted.insert(f); twisted.insert(gf)
                            }
                        }
                    }
                    // Turn over the smaller-area side of this piece.
                    let flipSide: Int8 = area[1] <= area[0] ? 1 : 0
                    for f in queue where parity[f] == flipSide && !twisted.contains(f) {
                        let t = triangles[f]
                        triangles[f] = Tri(a: t.a, b: t.c, c: t.b)
                        exact[f] = false
                        trianglesFlipped += 1
                        flippedCorners.append(t)
                    }
                    for f in queue { parity[f] = 2 }   // done; never revisit
                }
                return twisted.sorted()
            }

            resolvePinches(around: strippedFaces, extraVertices: pinchSeeds)
            var rounds = 0
            while true {
                let twisted = orientConsistently()
                if twisted.isEmpty { break }
                rounds += 1
                if rounds > Self.maxHealRounds { break }
                for f in twisted { strip(f) }
                resolvePinches(around: twisted)
            }

            let cut = strippedFaces.count
            let newCorners = strippedFaces.map { triangles[$0] }
            if cut > 0 { filterTriangles { active[$0] } }
            // Pieces the cuts left floating (open, tiny) go with the loose pass.
            if cut > 0 { removeLooseFragments() }
            let removed = trianglesStripped + cut + (looseRemoved - savedLooseRemoved)
            if removed > Int(Self.maxStripFraction * Double(originalTriangleCount)) || triangles.isEmpty {
                let share = 100.0 * Double(removed) / Double(max(originalTriangleCount, 1))
                triangles = savedTriangles
                exact = savedExact
                looseFragments = savedLooseFragments
                looseRemoved = savedLooseRemoved
                trianglesFlipped = savedFlipped
                looseSeeds = savedLooseSeeds
                flippedCorners = savedFlippedCorners
                unfixableCorners = newCorners
                nonManifoldVertices.formUnion(nonManifoldCorners)
                blockingReason = String(format: "The damage is spread over %.1f%% of the surface — too much to fix in place. Use Rebuild as solid.", share)
                return
            }
            trianglesStripped += cut
            strippedCorners.append(contentsOf: newCorners)
            nonManifoldVertices.formUnion(nonManifoldCorners)
            healSites = Self.countSpots(strippedCorners)
        }

        /// Clusters of cut-out triangles that share a corner = separate spots.
        static func countSpots(_ faces: [Tri]) -> Int {
            var spotOfVertex: [Int: Int] = [:]
            var parent = Array(faces.indices)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                return r
            }
            for (id, t) in faces.enumerated() {
                for v in [t.a, t.b, t.c] {
                    if let other = spotOfVertex[v] {
                        let ra = find(id), rb = find(other)
                        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                    } else {
                        spotOfVertex[v] = id
                    }
                }
            }
            return Set(faces.indices.map(find)).count
        }

        func loopDiameter(_ loop: [Int]) -> (diameter: Double, center: P3) {
            var c = P3(0, 0, 0)
            for v in loop { c += points[v] }
            c /= Double(loop.count)
            var r = 0.0
            for v in loop { r = max(r, simd_length(points[v] - c)) }
            return (2 * r, c)
        }

        /// A loop is a pinhole when it is both short (≤ 12 edges) and small
        /// relative to the model; anything else is an opening.
        func isPinhole(_ loop: [Int]) -> Bool {
            loop.count <= 12 && loopDiameter(loop).diameter <= 0.05 * diagonal
        }

        /// A loop left by cutting out a damaged spot: at least one of its
        /// edges only opened because of the cut, and what was open before is
        /// at most pinhole-sized (≤ 12 edges). Refilled flush, never counted
        /// as an opening; an opening a spot merged into stays an opening.
        func isHealLoop(_ loop: [Int]) -> Bool {
            guard trianglesStripped > 0, let preexisting = preexistingBoundary else { return false }
            var old = 0
            for i in loop.indices {
                let key = Self.undirectedKey(loop[i], loop[(i + 1) % loop.count])
                if preexisting.contains(key) { old += 1 }
            }
            return old < loop.count && old <= 12
        }

        /// Splits an opening's rim where it touches itself: two corners that
        /// are not neighbours on the loop but lie within 0.5% of the shorter
        /// rim edge at either (sub-micron to a few microns on real scans).
        /// The stretch of the loop between the two corners becomes its own
        /// lobe (closed across the tiny gap between them); the rest of the
        /// loop carries on. Returns the loop unchanged when it touches
        /// nowhere.
        func splitAtRimContacts(_ loop: [Int]) -> [[Int]] {
            let n = loop.count
            guard n >= 6 else { return [loop] }
            var tol = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let a = simd_length(points[loop[i]] - points[loop[(i + n - 1) % n]])
                let b = simd_length(points[loop[(i + 1) % n]] - points[loop[i]])
                tol[i] = 5.0e-3 * min(a, b)
            }
            guard let cellSize = tol.max(), cellSize > 0 else { return [loop] }
            struct Cell: Hashable { var x: Int64; var y: Int64; var z: Int64 }
            func cell(_ p: P3) -> Cell {
                Cell(x: Int64((p.x / cellSize).rounded(.down)), y: Int64((p.y / cellSize).rounded(.down)),
                     z: Int64((p.z / cellSize).rounded(.down)))
            }
            var grid: [Cell: [Int]] = [:]
            for i in 0..<n { grid[cell(points[loop[i]]), default: []].append(i) }
            // Contact classes (union-find over loop positions).
            var parent = Array(0..<n)
            func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
            var touched = false
            for i in 0..<n {
                let p = points[loop[i]]
                let c = cell(p)
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    for j in grid[Cell(x: c.x + Int64(dx), y: c.y + Int64(dy), z: c.z + Int64(dz))] ?? [] where j > i {
                        let gap = j - i
                        if gap <= 1 || gap >= n - 1 { continue }
                        if simd_length(points[loop[j]] - p) <= min(tol[i], tol[j]) {
                            let ri = find(i), rj = find(j)
                            if ri != rj { parent[max(ri, rj)] = min(ri, rj); touched = true }
                        }
                    }
                } } }
            }
            guard touched else { return [loop] }
            // Walk the loop; when a contact class comes round again, cut the
            // stretch since its last visit off as a lobe, including the
            // corner that closes it.
            var out: [[Int]] = []
            var stack: [Int] = []            // loop positions
            var position: [Int: Int] = [:]   // contact class -> index in stack
            for i in 0..<n {
                let r = find(i)
                if let j = position[r] {
                    let lobe = stack[j...].map { loop[$0] } + [loop[i]]
                    for w in stack[(j + 1)...] { position[find(w)] = nil }
                    stack.removeSubrange((j + 1)...)
                    stack.append(i)
                    position[r] = stack.count - 1
                    if lobe.count >= 3 { out.append(lobe) }
                } else {
                    position[r] = stack.count
                    stack.append(i)
                }
            }
            if stack.count >= 3 { out.append(stack.map { loop[$0] }) }
            return out.isEmpty ? [loop] : out
        }

        /// Indices into `loops` of the openings (not pinholes, not healed
        /// spots), largest first, ties by centre x, y, z — the order of
        /// `Diagnosis.openings` and of the "opening-N" problem sites.
        func openingLoopIndices() -> [Int] {
            var found: [(index: Int, d: Double, c: P3)] = []
            for (i, loop) in loops.enumerated() where !isHealLoop(loop) && !isPinhole(loop) {
                let (d, c) = loopDiameter(loop)
                found.append((i, d, c))
            }
            found.sort { l, r in
                if l.d != r.d { return l.d > r.d }
                if l.c.x != r.c.x { return l.c.x < r.c.x }
                if l.c.y != r.c.y { return l.c.y < r.c.y }
                return l.c.z < r.c.z
            }
            return found.map(\.index)
        }

        /// +1 when the surface is wound outward (positive volume once every
        /// loop is closed with a fan wound like the caps), else −1.
        func outwardSign() -> Double {
            var volume = 0.0
            for t in triangles { volume += simd_dot(points[t.a], simd_cross(points[t.b], points[t.c])) / 6 }
            for loop in loops {
                let n = loop.count
                guard n >= 3 else { continue }
                var c = P3(0, 0, 0)
                for v in loop { c += points[v] }
                c /= Double(n)
                for i in 0..<n {
                    // Caps are wound opposite to the loop.
                    volume += simd_dot(points[loop[(i + 1) % n]], simd_cross(points[loop[i]], c)) / 6
                }
            }
            return volume < 0 ? -1 : 1
        }

        /// Outward unit normal of the cap over `loop` (caps run opposite to
        /// the loop; `sign` from `outwardSign`). Zero for a rim with no area.
        func outwardNormal(_ loop: [Int], sign: Double) -> P3 {
            var area = P3(0, 0, 0)
            let n = loop.count
            for i in 0..<n { area += simd_cross(points[loop[i]], points[loop[(i + 1) % n]]) }
            guard simd_length(area) > 0 else { return P3(0, 0, 0) }
            return -sign * simd_normalize(area)
        }

        /// Plain position of an opening on the model, +Z up.
        static func placement(center: P3, normal: P3, zRange: (lo: Double, hi: Double)) -> String {
            if normal.z >= 0.6 { return "top" }
            if normal.z <= -0.6 { return "bottom" }
            let (lo, hi) = zRange
            guard hi > lo else { return "side" }
            let f = (center.z - lo) / (hi - lo)
            if f >= 2.0 / 3.0 { return "side, near the top" }
            if f <= 1.0 / 3.0 { return "side, near the bottom" }
            return "side"
        }

        /// The openings in diagnosis order (see `openingLoopIndices`).
        func openingList() -> [Opening] {
            let order = openingLoopIndices()
            guard !order.isEmpty else { return [] }
            let sign = outwardSign()
            var lo = Double.infinity, hi = -Double.infinity
            for t in triangles {
                for v in [t.a, t.b, t.c] { lo = min(lo, points[v].z); hi = max(hi, points[v].z) }
            }
            return order.map { i in
                let loop = loops[i]
                let (d, c) = loopDiameter(loop)
                let nrm = outwardNormal(loop, sign: sign)
                return Opening(edgeCount: loop.count, diameter: d, center: Vec3(x: c.x, y: c.y, z: c.z),
                               normal: Vec3(x: nrm.x, y: nrm.y, z: nrm.z),
                               placement: Self.placement(center: c, normal: nrm, zRange: (lo, hi)))
            }
        }

        func diagnosis() -> Diagnosis {
            let openings = openingList()
            var pinholes = 0
            for loop in loops where !isHealLoop(loop) && isPinhole(loop) { pinholes += 1 }
            let (sites, omitted) = problemSites()
            return Diagnosis(
                openings: openings,
                pinholes: pinholes,
                collapsedTriangles: collapsed,
                doubledTriangleGroups: doubledGroups + foldedFlaps,
                doubledTrianglesRemoved: doubledRemoved + foldedFlaps,
                looseFragments: looseFragments,
                nonManifoldEdges: foundNonManifoldEdges,
                orientationConflicts: foundOrientationConflicts,
                boundaryEdges: foundBoundaryEdges,
                damagedSpots: healSites,
                trianglesToReplace: trianglesStripped,
                flippedTriangles: trianglesFlipped,
                blockingReason: blockingReason,
                seams: seamsStitched,
                seamCornersJoined: seamCornersJoined,
                piecesReversed: patchesReversed,
                sites: sites,
                sitesOmitted: omitted
            )
        }

        // MARK: Problem sites (where each thing the diagnosis found sits)

        /// Mean position of `vertices` and their extent across (twice the
        /// farthest corner from the mean, like `loopDiameter`).
        func spread(_ vertices: [Int]) -> (center: P3, size: Double) {
            guard !vertices.isEmpty else { return (P3(0, 0, 0), 0) }
            var c = P3(0, 0, 0)
            for v in vertices { c += points[v] }
            c /= Double(vertices.count)
            var r = 0.0
            for v in vertices { r = max(r, simd_length(points[v] - c)) }
            return (c, 2 * r)
        }

        /// Groups of `faces` (indices) that share a corner, directly or
        /// through other faces in the list — the separate spots.
        static func cornerClusters(_ faces: [Tri]) -> [[Int]] {
            var spotOfVertex: [Int: Int] = [:]
            var parent = Array(faces.indices)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                var y = x
                while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
                return r
            }
            for (id, t) in faces.enumerated() {
                for v in [t.a, t.b, t.c] {
                    if let other = spotOfVertex[v] {
                        let ra = find(id), rb = find(other)
                        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                    } else {
                        spotOfVertex[v] = id
                    }
                }
            }
            var groups: [Int: [Int]] = [:]
            for id in faces.indices { groups[find(id), default: []].append(id) }
            return groups.keys.sorted().map { groups[$0]! }
        }

        static func corners(_ faces: [Tri], _ ids: [Int]) -> [Int] {
            var set = Set<Int>()
            for id in ids { let t = faces[id]; set.insert(t.a); set.insert(t.b); set.insert(t.c) }
            return set.sorted()
        }

        static func formatMM(_ d: Double) -> String { OpeningCapper.formatMM(d) }

        /// Every problem the passes recorded, as places on the model, grouped
        /// by kind (in `Site.Kind` order), largest first within a kind, at
        /// most `maxSitesPerKind` each. Returns the sites and how many were
        /// left out.
        func problemSites() -> (sites: [Site], omitted: Int) {
            struct Raw {
                var kind: Site.Kind
                var center: P3
                var size: Double
                var title: String
                var fix: String
                var count: Int
                var fixable = true
            }
            var raw: [Raw] = []
            func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : "\(n) \(many)" }

            // Openings and pinholes: the boundary loops, as `diagnosis` sorts them.
            for loop in loops where !isHealLoop(loop) && isPinhole(loop) {
                let (d, c) = loopDiameter(loop)
                raw.append(Raw(
                    kind: .pinhole, center: c, size: d,
                    title: "Pinhole, \(Self.formatMM(d)) across",
                    fix: "Fix in place fills it flush with the surrounding surface.",
                    count: loop.count))
            }
            // Openings in diagnosis order, so site "opening-N" is
            // `Diagnosis.openings[N - 1]` and carries the same label.
            for (i, opening) in openingList().enumerated() {
                raw.append(Raw(
                    kind: .opening, center: P3(opening.center.x, opening.center.y, opening.center.z), size: opening.diameter,
                    title: opening.label(number: i + 1),
                    fix: "Fix in place caps it with a new top. To leave it open, give it its own top shape (dome or dish), or give it real walls to make a cup, see Make Watertight's choices and options.",
                    count: opening.edgeCount))
            }
            for seam in seamSeeds {
                let (c, d) = spread(seam)
                raw.append(Raw(
                    kind: .seam, center: c, size: d,
                    title: "Open seam, \(Self.formatMM(d)) across",
                    fix: "Fix in place zips this zero-width crack shut — no new surface is added.",
                    count: seam.count))
            }
            for cluster in Self.cornerClusters(strippedCorners) {
                let vertices = Self.corners(strippedCorners, cluster)
                let (c, d) = spread(vertices)
                let nonManifold = vertices.contains { nonManifoldVertices.contains($0) }
                raw.append(Raw(
                    kind: .nonManifoldSpot, center: c, size: d,
                    title: nonManifold ? "Non-manifold spot" : "Damaged spot (pinched or twisted)",
                    fix: "Fix in place cuts out \(plural(cluster.count, "the broken triangle", "broken triangles")) here and refills the hole flush.",
                    count: cluster.count))
            }
            for cluster in Self.cornerClusters(unfixableCorners) {
                let vertices = Self.corners(unfixableCorners, cluster)
                let (c, d) = spread(vertices)
                let nonManifold = vertices.contains { nonManifoldVertices.contains($0) }
                raw.append(Raw(
                    kind: .nonManifoldSpot, center: c, size: d,
                    title: nonManifold ? "Non-manifold spot" : "Damaged spot (pinched or twisted)",
                    fix: "Part of damage too widespread to fix in place — Make Watertight's Rebuild as solid can close it, but it replaces the whole surface.",
                    count: cluster.count, fixable: false))
            }
            let doubledFaces = doubledSeeds.map(\.corners)
            for cluster in Self.cornerClusters(doubledFaces) {
                let (c, d) = spread(Self.corners(doubledFaces, cluster))
                let removed = cluster.reduce(0) { $0 + doubledSeeds[$1].removed }
                raw.append(Raw(
                    kind: .doubledTriangles, center: c, size: d,
                    title: removed == 1 ? "Doubled-up triangle" : "\(removed) doubled-up triangles",
                    fix: "Fix in place removes the extra copies; no hole is left.",
                    count: removed))
            }
            for fragment in looseSeeds {
                let (c, d) = spread(fragment.vertices)
                raw.append(Raw(
                    kind: .looseFragment, center: c, size: d,
                    title: "Loose fragment (\(plural(fragment.triangles, "1 triangle", "triangles")))",
                    fix: "Fix in place deletes this stray piece.",
                    count: fragment.triangles))
            }
            for piece in reversedPieceSeeds {
                let (c, d) = spread(piece.vertices)
                raw.append(Raw(
                    kind: .flippedPiece, center: c, size: d,
                    title: "Inside-out surface piece (\(plural(piece.triangles, "1 triangle", "triangles")))",
                    fix: "Fix in place turns the whole piece over to match the piece it joins.",
                    count: piece.triangles))
            }
            for cluster in Self.cornerClusters(flippedCorners) {
                let (c, d) = spread(Self.corners(flippedCorners, cluster))
                raw.append(Raw(
                    kind: .flippedPiece, center: c, size: d,
                    title: cluster.count == 1 ? "Flipped triangle" : "\(cluster.count) flipped triangles",
                    fix: "Fix in place turns \(cluster.count == 1 ? "it" : "them") over to face the same way as the neighbours.",
                    count: cluster.count))
            }

            let blocked = blockingReason != nil
            var sites: [Site] = []
            var omitted = 0
            for kind in Site.Kind.allCases {
                let ofKind = raw.filter { $0.kind == kind }.sorted { l, r in
                    if l.size != r.size { return l.size > r.size }
                    if l.center.x != r.center.x { return l.center.x < r.center.x }
                    if l.center.y != r.center.y { return l.center.y < r.center.y }
                    return l.center.z < r.center.z
                }
                omitted += max(0, ofKind.count - OpeningCapper.maxSitesPerKind)
                for (rank, item) in ofKind.prefix(OpeningCapper.maxSitesPerKind).enumerated() {
                    let fixable = item.fixable && !blocked
                    sites.append(Site(
                        id: "\(kind.rawValue)-\(rank + 1)",
                        kind: kind,
                        position: Vec3(x: item.center.x, y: item.center.y, z: item.center.z),
                        sizeMM: item.size,
                        title: item.title,
                        fixDescription: fixable || !item.fixable
                            ? item.fix
                            : "This model can't be fixed in place (see the Issues panel) — use Rebuild as solid (Object → Modify Form → Make Watertight).",
                        elementCount: item.count,
                        fixableInPlace: fixable
                    ))
                }
            }
            return (sites, omitted)
        }

        // MARK: Capping

        /// `heights`: per opening in diagnosis order, its top shape (mm), or
        /// nil to leave it open. `topHeight` is the global request.
        func capAll(heights: [Double?], topHeight: Double, diagnosis: Diagnosis) -> Result {
            // Mean incident edge length per vertex (Liepa's density σ).
            var edgeSum = [Double](repeating: 0, count: points.count)
            var edgeCount = [Int](repeating: 0, count: points.count)
            for t in triangles {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let l = simd_length(points[u] - points[v])
                    edgeSum[u] += l; edgeCount[u] += 1
                    edgeSum[v] += l; edgeCount[v] += 1
                }
            }
            func sigma(_ v: Int) -> Double { edgeCount[v] > 0 ? edgeSum[v] / Double(edgeCount[v]) : 0 }

            // The mesh face across each boundary half-edge, for dihedral weights.
            var faceOfDirected: [UInt64: Int] = [:]
            for (i, t) in triangles.enumerated() {
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] { faceOfDirected[Self.directedKey(u, v)] = i }
            }
            func faceNormal(_ f: Int) -> P3 {
                let t = triangles[f]
                return safeNormalize(simd_cross(points[t.b] - points[t.a], points[t.c] - points[t.a]))
            }

            var caps: [CapPatch] = []
            var isOpening: [Bool] = []
            /// Larger than a pinhole: refined to the surrounding density and
            /// faired (openings and bigger healed spots).
            var needsRefine: [Bool] = []
            var isHeal: [Bool] = []
            var pinholesFilled = 0
            var openingsClosed = 0
            var healPatches = 0
            // An opening whose rim touches itself (two rim corners within
            // microns: a leaf tip folded onto the rim, a zero-width spike) is
            // capped as separate lobes that meet at the contact, like a pinch
            // at a shared corner — one cap squeezed through the contact would
            // have to cross the skin there.
            var capLoops: [(loop: [Int], opening: Bool, heal: Bool, large: Bool)] = []
            /// Per cap: which opening it belongs to (lobes of one opening
            /// share it; -1 for pinholes and healed spots).
            var openingOf: [Int] = []
            let openingOrder = openingLoopIndices()
            var openingIndexOfLoop: [Int: Int] = [:]
            for (o, li) in openingOrder.enumerated() { openingIndexOfLoop[li] = o }
            var leftOpen = Set<Int>()
            var leftOpenRimEdges = 0
            for (li, loop) in loops.enumerated() {
                let heal = isHealLoop(loop)
                let large = !isPinhole(loop)
                if large && !heal {
                    let o = openingIndexOfLoop[li] ?? -1
                    if o >= 0, heights.indices.contains(o), heights[o] == nil {
                        leftOpen.insert(o)
                        leftOpenRimEdges += loop.count
                        continue
                    }
                    openingsClosed += 1
                    for lobe in splitAtRimContacts(loop) {
                        capLoops.append((lobe, true, false, !isPinhole(lobe)))
                        openingOf.append(o)
                    }
                } else {
                    capLoops.append((loop, false, heal, large))
                    openingOf.append(-1)
                }
            }
            for (loop, opening, heal, large) in capLoops {
                let n = loop.count
                var rimNormals: [P3] = []
                rimNormals.reserveCapacity(n)
                for i in 0..<n {
                    let f = faceOfDirected[Self.directedKey(loop[i], loop[(i + 1) % n])]
                    rimNormals.append(f.map(faceNormal) ?? P3(0, 0, 0))
                }
                let rim = loop.map { points[$0] }
                var patch = CapPatch(rimGlobal: loop, positions: rim, sigma: loop.map(sigma))
                // Rim-to-rim edges the surface already has: the cap must not
                // reuse them (that would put three triangles on one edge).
                var local: [Int: Int] = [:]
                for (i, v) in loop.enumerated() { local[v] = i }
                for t in triangles {
                    for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                        if let i = local[u], let k = local[v] { patch.meshChords.insert(CapPatch.key(i, k)) }
                    }
                }
                patch.triangulate(rimNormals: rimNormals)
                if heal { healPatches += 1 } else if !opening { pinholesFilled += 1 }
                caps.append(patch)
                isOpening.append(opening)
                needsRefine.append(large)
                isHeal.append(heal)
            }

            // Orientation (outward = positive enclosed volume), from the
            // triangulated caps before any refinement.
            var orientationVolume = 0.0
            for t in triangles {
                orientationVolume += simd_dot(points[t.a], simd_cross(points[t.b], points[t.c])) / 6
            }
            for patch in caps {
                for t in patch.triangles {
                    let a = patch.positions[t.a], b = patch.positions[t.b], c = patch.positions[t.c]
                    orientationVolume += simd_dot(a, simd_cross(b, c)) / 6
                }
            }
            // Openings left open still count, closed with a fan wound like a
            // cap, so leaving one open never flips which side is out.
            for o in leftOpen {
                let loop = loops[openingOrder[o]]
                let n = loop.count
                var c = P3(0, 0, 0)
                for v in loop { c += points[v] }
                c /= Double(n)
                for i in 0..<n {
                    orientationVolume += simd_dot(points[loop[(i + 1) % n]], simd_cross(points[loop[i]], c)) / 6
                }
            }
            let outwardSign: Double = orientationVolume < 0 ? -1 : 1

            // Openings: refine to the surrounding density and fair as a
            // membrane. (Where the rim folds over itself — crown leaves that
            // overlap seen from above — the cap can still cross a leaf; those
            // places are counted and reported, not hidden.)
            for k in caps.indices where needsRefine[k] {
                if isOpening[k] {
                    // An opening's cap gets at least ~16 triangles across,
                    // even under a coarse rim, so it has corners to shape.
                    let across = loopDiameter(caps[k].rimGlobal).diameter / 16
                    if across > 0 { caps[k].sigma = caps[k].sigma.map { min($0, across) } }
                }
                caps[k].refine()
                caps[k].fairPositions(pinned: [])
                if isOpening[k] { caps[k].computeBulge() }
            }

            // Openings: shape each cap on the level set {w = 0.5} of the
            // generalized winding number of the skin plus the other caps
            // (see `LevelSetShaper`) — flat for a planar rim, and never
            // through the skin where the rim folds over itself.
            let trace = ProcessInfo.processInfo.environment["REFAB_CAP_TRACE"] == "1"
            let skinChecker = CollisionChecker(points: points, triangles: triangles)
            let levelCaps = caps.indices.filter { isOpening[$0] && caps[$0].positions.count > caps[$0].rimCount }
            func windingField(excluding k: Int) -> WindingLevelField {
                var corners: [(P3, P3, P3)] = []
                corners.reserveCapacity(triangles.count + caps.reduce(0) { $0 + $1.triangles.count })
                let flip = outwardSign < 0
                for t in triangles {
                    corners.append(flip ? (points[t.a], points[t.c], points[t.b]) : (points[t.a], points[t.b], points[t.c]))
                }
                for (j, patch) in caps.enumerated() where j != k {
                    let q = patch.positions
                    for t in patch.triangles {
                        corners.append(flip ? (q[t.a], q[t.c], q[t.b]) : (q[t.a], q[t.b], q[t.c]))
                    }
                }
                // Far-field opening angle 0.2: measured on UMesh (151 mm
                // planar rims) the flat cap stays within 0.01 mm of the rim
                // plane (0.35 left 0.053 mm); the field's own error falls as
                // beta² – beta³.
                return WindingLevelField(corners: corners, beta: 0.2)
            }
            func log(_ k: Int, _ what: String, _ report: LevelSetReport, _ seconds: Double) {
                guard trace else { return }
                FileHandle.standardError.write(Data(String(
                    format: "cap %d %@: level %.4f interior %d suspects %d unconverged %d crossings %d refined %d (%.2fs: %@)\n",
                    k, what, report.level, report.interior, report.suspects, report.unconverged, report.crossings,
                    report.refinedTriangles, seconds, report.timingText).utf8))
            }
            for k in levelCaps {
                let started = Date()
                let shaper = LevelSetShaper(field: windingField(excluding: k))
                let report = caps[k].shapeOnLevel(0.5, shaper: shaper, checker: skinChecker)
                log(k, "flat", report, Date().timeIntervalSince(started))
            }

            // Dome / dish: each opening's cap moves to the level set whose
            // peak displacement from the flat cap along the opening's
            // outward normal is the requested height (clamped, and measured,
            // where the level sets would run into the skin first).
            func requestedHeight(_ o: Int) -> Double {
                heights.indices.contains(o) ? (heights[o] ?? 0) : topHeight
            }
            var resolvedHeights: [Double] = []
            var achievedByOpening: [Int: Double] = [:]
            for k in levelCaps {
                let wanted = requestedHeight(openingOf[k])
                guard wanted != 0 else { continue }
                let started = Date()
                let shaper = LevelSetShaper(field: windingField(excluding: k))
                let outward = caps[k].windingNormal() * outwardSign
                let (achieved, report) = caps[k].shapeToHeight(wanted, outward: outward, shaper: shaper, checker: skinChecker)
                resolvedHeights.append(achieved)
                // Lobes of one opening: the smallest height reached counts.
                if let prior = achievedByOpening[openingOf[k]], abs(prior) <= abs(achieved) {} else {
                    achievedByOpening[openingOf[k]] = achieved
                }
                log(k, String(format: "height %.3f", achieved), report, Date().timeIntervalSince(started))
            }
            let appliedHeight = resolvedHeights.min(by: { abs($0) < abs($1) }) ?? 0
            let cappedOpenings = diagnosis.openings.indices.filter { !leftOpen.contains($0) }
            let requestedHeights = cappedOpenings.map(requestedHeight)
            let uniformRequest = requestedHeights.allSatisfy { abs($0 - (requestedHeights.first ?? 0)) <= 0.05 }
            let outcomes: [OpeningOutcome] = diagnosis.openings.enumerated().map { o, opening in
                let open = leftOpen.contains(o)
                return OpeningOutcome(
                    number: o + 1, diameter: opening.diameter, placement: opening.placement, leftOpen: open,
                    requestedHeight: open ? 0 : requestedHeight(o),
                    appliedHeight: open ? 0 : (achievedByOpening[o] ?? 0))
            }
            // Opening caps that still cross the surface are counted and
            // reported, never hidden.
            var intersections = 0
            for k in caps.indices where isOpening[k] {
                intersections += skinChecker.crossingCapTriangles(caps[k]).count
            }

            var outPoints = points
            // Assemble, then orient outward (positive volume).
            var capGlobal: [[Int]] = []   // per cap: local -> global vertex index
            for patch in caps {
                var map = patch.rimGlobal
                for i in patch.rimGlobal.count..<patch.positions.count {
                    map.append(outPoints.count)
                    outPoints.append(patch.positions[i])
                }
                capGlobal.append(map)
            }
            var allTriangles = triangles
            for (k, patch) in caps.enumerated() {
                for t in patch.triangles {
                    allTriangles.append(Tri(a: capGlobal[k][t.a], b: capGlobal[k][t.b], c: capGlobal[k][t.c]))
                }
            }
            let flipped = outwardSign < 0
            if flipped {
                for i in allTriangles.indices { let t = allTriangles[i]; allTriangles[i] = Tri(a: t.a, b: t.c, c: t.b) }
            }
            var capTriangleRanges: [Range<Int>] = []
            var start = triangles.count
            for patch in caps {
                capTriangleRanges.append(start..<(start + patch.triangles.count))
                start += patch.triangles.count
            }
            // Healed spots: count refill triangles that cross nearby surface
            // (a fold already in the scan next to the spot) — reported, not hidden.
            var healIntersections = 0
            for k in caps.indices where isHeal[k] {
                healIntersections += skinChecker.crossingCapTriangles(caps[k]).count
            }

            // Emit.
            var used = [Int](repeating: -1, count: outPoints.count)
            var vertices: [Vec3] = []
            var indices: [Int32] = []
            indices.reserveCapacity(allTriangles.count * 3)
            for t in allTriangles {
                for v in [t.a, t.b, t.c] {
                    if used[v] < 0 {
                        used[v] = vertices.count
                        let p = outPoints[v]
                        vertices.append(Vec3(x: p.x, y: p.y, z: p.z))
                    }
                    indices.append(Int32(used[v]))
                }
            }
            let untouched = exact.filter { $0 }.count
            // An opening's lobes were capped one after another, so their
            // triangles form one contiguous range (loop order).
            var openingRanges: [(opening: Int, range: Range<Int>)] = []
            for k in caps.indices where isOpening[k] {
                if let last = openingRanges.last, last.opening == openingOf[k], last.range.upperBound == capTriangleRanges[k].lowerBound {
                    openingRanges[openingRanges.count - 1].range = last.range.lowerBound..<capTriangleRanges[k].upperBound
                } else {
                    openingRanges.append((openingOf[k], capTriangleRanges[k]))
                }
            }
            return Result(
                geometry: MeshGeometryData(vertices: vertices, triangleIndices: indices),
                openingsClosed: openingsClosed,
                pinholesFilled: pinholesFilled,
                trianglesRemoved: collapsed + doubledRemoved + looseRemoved + foldedFlaps,
                untouchedFraction: Double(untouched) / Double(max(originalTriangleCount, 1)),
                appliedTopHeight: openingsClosed > 0 ? appliedHeight : 0,
                requestedTopHeight: openingsClosed > 0 ? (uniformRequest ? (requestedHeights.first ?? topHeight) : topHeight) : 0,
                capIntersections: intersections,
                flippedInsideOut: flipped,
                spotsHealed: healSites,
                nonManifoldEdgesHealed: trianglesStripped > 0 ? foundNonManifoldEdges : 0,
                trianglesReplaced: trianglesStripped,
                healPatches: healPatches,
                healPatchIntersections: healIntersections,
                trianglesFlipped: trianglesFlipped,
                seamsStitched: seamsStitched,
                seamCornersJoined: seamCornersJoined,
                piecesReversed: patchesReversed,
                keptTriangleCount: triangles.count,
                openingCapTriangleRanges: openingRanges.map(\.range),
                pinholeCapTriangleRanges: caps.indices.filter { !isOpening[$0] }.map { capTriangleRanges[$0] },
                openings: diagnosis.openings,
                openingCapRangeByOpening: Dictionary(uniqueKeysWithValues: openingRanges.filter { $0.opening >= 0 }.map { ($0.opening, $0.range) }),
                openingOutcomes: outcomes,
                openingsLeftOpen: leftOpen.count,
                leftOpenRimEdges: leftOpenRimEdges
            )
        }
    }

    // MARK: - Cap patch (triangulate, refine, fair)

    /// One cap. Local vertices 0..<rimCount are the loop (fixed); later ones
    /// are inserted during refinement.
    fileprivate struct CapPatch {
        let rimGlobal: [Int]
        var positions: [P3]
        var sigma: [Double]
        var triangles: [Tri] = []
        /// Rim-to-rim edges (local keys) already present in the surrounding
        /// surface; the cap may not create them.
        var meshChords = Set<UInt64>()
        /// Per local vertex: dome/dish displacement profile (0 on the rim,
        /// 1 at the highest interior point). Empty for pinholes.
        var bulge: [Double] = []

        init(rimGlobal: [Int], positions: [P3], sigma: [Double]) {
            self.rimGlobal = rimGlobal
            self.positions = positions
            self.sigma = sigma
        }

        var rimCount: Int { rimGlobal.count }

        /// Liepa's minimum-weight triangulation: minimise the largest dihedral
        /// angle, then the total area. Cap triangles are wound opposite to the
        /// loop so each rim edge pairs with its mesh face.
        mutating func triangulate(rimNormals: [P3]) {
            triangles = []
            let n = rimCount
            if n == 3 { triangles = [Tri(a: 2, b: 1, c: 0)]; return }
            if n > 700 { triangulateFan(); return }
            let p = positions
            func normalOf(_ i: Int, _ m: Int, _ k: Int) -> P3 {
                safeNormalize(simd_cross(p[m] - p[k], p[i] - p[k]))   // winding (k, m, i)
            }
            func dihedral(_ a: P3, _ b: P3) -> Double {
                if simd_length_squared(a) == 0 || simd_length_squared(b) == 0 { return 0 }
                return acos(max(-1, min(1, simd_dot(a, b))))
            }
            let inf = Double.infinity
            var wAngle = [Double](repeating: inf, count: n * n)
            var wArea = [Double](repeating: inf, count: n * n)
            var split = [Int32](repeating: -1, count: n * n)
            var topNormal = [P3](repeating: P3(0, 0, 0), count: n * n)
            for i in 0..<(n - 1) { wAngle[i * n + i + 1] = 0; wArea[i * n + i + 1] = 0 }
            for d in 2..<n {
                for i in 0..<(n - d) {
                    let k = i + d
                    if !(i == 0 && k == n - 1), meshChords.contains(Self.key(i, k)) { continue }
                    var bestA = inf, bestS = inf, bestM = -1
                    var bestN = P3(0, 0, 0)
                    for m in (i + 1)..<k {
                        let aL = wAngle[i * n + m], aR = wAngle[m * n + k]
                        if aL == inf || aR == inf { continue }
                        let nt = normalOf(i, m, k)
                        let area = 0.5 * simd_length(simd_cross(p[m] - p[i], p[k] - p[i]))
                        var angle = max(aL, aR)
                        angle = max(angle, dihedral(nt, m == i + 1 ? rimNormals[i] : topNormal[i * n + m]))
                        angle = max(angle, dihedral(nt, k == m + 1 ? rimNormals[m] : topNormal[m * n + k]))
                        if i == 0 && k == n - 1 { angle = max(angle, dihedral(nt, rimNormals[n - 1])) }
                        let s = wArea[i * n + m] + wArea[m * n + k] + area
                        if angle < bestA - 1.0e-9 || (abs(angle - bestA) <= 1.0e-9 && s < bestS) {
                            bestA = angle; bestS = s; bestM = m; bestN = nt
                        }
                    }
                    wAngle[i * n + k] = bestA
                    wArea[i * n + k] = bestS
                    split[i * n + k] = Int32(bestM)
                    topNormal[i * n + k] = bestN
                }
            }
            var out: [Tri] = []
            var stack: [(Int, Int)] = [(0, n - 1)]
            while let (i, k) = stack.popLast() {
                let m = Int(split[i * n + k])
                guard m > i else { triangles = []; triangulateFan(); return }
                out.append(Tri(a: k, b: m, c: i))
                if m - i >= 2 { stack.append((i, m)) }
                if k - m >= 2 { stack.append((m, k)) }
            }
            triangles = out
        }

        /// Fallback for very long loops: fan from the loop's centroid.
        mutating func triangulateFan() {
            let n = rimCount
            var c = P3(0, 0, 0)
            for i in 0..<n { c += positions[i] }
            c /= Double(n)
            let center = positions.count
            positions.append(c)
            sigma.append(sigma.prefix(n).reduce(0, +) / Double(n))
            triangles = (0..<n).map { Tri(a: ($0 + 1) % n, b: $0, c: center) }
        }

        // Refinement: Liepa's centroid splits + Delaunay-style edge relaxation.

        static func key(_ u: Int, _ v: Int) -> UInt64 {
            (UInt64(min(u, v)) << 32) | UInt64(max(u, v))
        }

        mutating func refine() {
            var edgeFaces: [UInt64: [Int]] = [:]
            func addFace(_ f: Int) {
                let t = triangles[f]
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] { edgeFaces[Self.key(u, v), default: []].append(f) }
            }
            func removeFace(_ f: Int) {
                let t = triangles[f]
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    edgeFaces[Self.key(u, v)]?.removeAll { $0 == f }
                }
            }
            for f in triangles.indices { addFace(f) }
            let rim = rimCount

            func isRimEdge(_ u: Int, _ v: Int) -> Bool {
                guard u < rim, v < rim else { return false }
                let d = abs(u - v)
                return d == 1 || d == rim - 1
            }
            func angle(at c: P3, _ a: P3, _ b: P3) -> Double {
                let x = safeNormalize(a - c), y = safeNormalize(b - c)
                return acos(max(-1, min(1, simd_dot(x, y))))
            }
            /// Flip edge (u,v) if the two opposite angles sum past π.
            func relax(_ u: Int, _ v: Int) -> Bool {
                if isRimEdge(u, v) { return false }
                guard let faces = edgeFaces[Self.key(u, v)], faces.count == 2 else { return false }
                let f1 = faces[0], f2 = faces[1]
                let t1 = triangles[f1], t2 = triangles[f2]
                // Orient so t1 contains a->b and t2 contains b->a.
                func directed(_ t: Tri, _ a: Int, _ b: Int) -> Bool {
                    (t.a == a && t.b == b) || (t.b == a && t.c == b) || (t.c == a && t.a == b)
                }
                let (a, b) = directed(t1, u, v) ? (u, v) : (v, u)
                func other(_ t: Tri) -> Int { [t.a, t.b, t.c].first { $0 != a && $0 != b }! }
                let c = other(t1), d = other(t2)
                if c == d { return false }
                if let existing = edgeFaces[Self.key(c, d)], !existing.isEmpty { return false }
                if c < rim, d < rim, meshChords.contains(Self.key(c, d)) { return false }
                let pa = positions[a], pb = positions[b], pc = positions[c], pd = positions[d]
                guard angle(at: pc, pa, pb) + angle(at: pd, pa, pb) > Double.pi + 1.0e-9 else { return false }
                // Don't fold: new triangles must face the same way as the old pair.
                let before = simd_cross(pb - pa, pc - pa) + simd_cross(pa - pb, pd - pb)
                let n1 = simd_cross(pd - pa, pc - pa), n2 = simd_cross(pb - pd, pc - pd)
                guard simd_dot(n1, before) > 0, simd_dot(n2, before) > 0 else { return false }
                removeFace(f1); removeFace(f2)
                triangles[f1] = Tri(a: a, b: d, c: c)
                triangles[f2] = Tri(a: d, b: b, c: c)
                addFace(f1); addFace(f2)
                return true
            }
            func relaxAll(maxPasses: Int) {
                for _ in 0..<maxPasses {
                    var flips = 0
                    for f in triangles.indices {
                        let t = triangles[f]
                        for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] where relax(u, v) { flips += 1 }
                    }
                    if flips == 0 { return }
                }
            }

            relaxAll(maxPasses: 20)
            let alpha = 2.0.squareRoot()
            for _ in 0..<60 {
                var didSplit = false
                let count = triangles.count
                for f in 0..<count {
                    let t = triangles[f]
                    let pc = (positions[t.a] + positions[t.b] + positions[t.c]) / 3
                    let sc = (sigma[t.a] + sigma[t.b] + sigma[t.c]) / 3
                    var split = true
                    for m in [t.a, t.b, t.c] {
                        let d = alpha * simd_length(pc - positions[m])
                        if d <= sc || d <= sigma[m] { split = false; break }
                    }
                    guard split else { continue }
                    let v = positions.count
                    positions.append(pc)
                    sigma.append(sc)
                    removeFace(f)
                    triangles[f] = Tri(a: t.a, b: t.b, c: v)
                    triangles.append(Tri(a: t.b, b: t.c, c: v))
                    triangles.append(Tri(a: t.c, b: t.a, c: v))
                    addFace(f); addFace(triangles.count - 2); addFace(triangles.count - 1)
                    _ = relax(t.a, t.b); _ = relax(t.b, t.c); _ = relax(t.c, t.a)
                    didSplit = true
                    if triangles.count > 400_000 { break }
                }
                relaxAll(maxPasses: 20)
                if !didSplit || triangles.count > 400_000 { break }
            }
        }

        /// Membrane fairing: free interior vertices solve the uniform Laplace
        /// equation with the rim (and any `pinned` vertices) held fixed.
        mutating func fairPositions(pinned: Set<Int>) {
            let solver = LaplaceSystem(patch: self, fixed: pinned)
            guard solver.unknowns.count > 0 else { return }
            for axis in 0..<3 {
                let b = solver.rows.map { $0.fixedSum[axis] }
                let guess = solver.unknowns.map { positions[$0][axis] }
                let x = solver.solve(b, guess: guess)
                for (i, v) in solver.unknowns.enumerated() { positions[v][axis] = x[i] }
            }
        }

        /// Dome/dish profile: the unit-pressure response of the membrane with
        /// the rim fixed, normalised to 1 at its peak.
        mutating func computeBulge() {
            bulge = [Double](repeating: 0, count: positions.count)
            let solver = LaplaceSystem(patch: self, fixed: [])
            guard solver.unknowns.count > 0 else { bulge = []; return }
            let n = solver.rows.count
            let phi = solver.solve([Double](repeating: 1, count: n), guess: [Double](repeating: 0, count: n))
            let peak = phi.max() ?? 0
            guard peak > 0 else { bulge = []; return }
            for (i, v) in solver.unknowns.enumerated() { bulge[v] = phi[i] / peak }
        }

        /// Area-weighted normal of the cap as wound (not yet oriented).
        func windingNormal() -> P3 {
            var n = P3(0, 0, 0)
            for t in triangles {
                n += simd_cross(positions[t.b] - positions[t.a], positions[t.c] - positions[t.a])
            }
            return safeNormalize(n)
        }
    }

    /// Uniform-Laplacian system over a cap's free vertices, solved by
    /// conjugate gradients (symmetric positive definite with the rim fixed).
    fileprivate struct LaplaceSystem {
        let unknowns: [Int]
        let rows: [(degree: Double, inner: [Int], fixedSum: P3)]

        init(patch: CapPatch, fixed: Set<Int>) {
            let count = patch.positions.count
            var neighbors = [Set<Int>](repeating: [], count: count)
            for t in patch.triangles {
                neighbors[t.a].insert(t.b); neighbors[t.a].insert(t.c)
                neighbors[t.b].insert(t.a); neighbors[t.b].insert(t.c)
                neighbors[t.c].insert(t.a); neighbors[t.c].insert(t.b)
            }
            let free = (patch.rimCount..<count).filter { !fixed.contains($0) && !neighbors[$0].isEmpty }
            let slot = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($1, $0) })
            unknowns = free
            rows = free.map { v in
                var inner: [Int] = []
                var fixedSum = P3(0, 0, 0)
                for u in neighbors[v] {
                    if let s = slot[u] { inner.append(s) } else { fixedSum += patch.positions[u] }
                }
                return (Double(neighbors[v].count), inner, fixedSum)
            }
        }

        func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            for (i, row) in rows.enumerated() {
                var s = row.degree * x[i]
                for j in row.inner { s -= x[j] }
                y[i] = s
            }
            return y
        }

        func solve(_ b: [Double], guess: [Double]) -> [Double] {
            var x = guess
            var r = zip(b, apply(x)).map { $0 - $1 }
            var p = r
            var rr = r.reduce(0) { $0 + $1 * $1 }
            let tol = max(1.0e-24, 1.0e-24 * b.reduce(0) { $0 + $1 * $1 })
            for _ in 0..<(4 * rows.count + 200) {
                if rr <= tol { break }
                let ap = apply(p)
                let pap = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
                guard pap > 0 else { break }
                let alpha = rr / pap
                for i in x.indices { x[i] += alpha * p[i]; r[i] -= alpha * ap[i] }
                let rrNew = r.reduce(0) { $0 + $1 * $1 }
                let beta = rrNew / rr
                for i in p.indices { p[i] = r[i] + beta * p[i] }
                rr = rrNew
            }
            return x
        }
    }

    // MARK: - Collision check (cap vs surrounding surface)

    fileprivate struct CollisionChecker {
        struct Cell: Hashable { var x: Int32; var y: Int32; var z: Int32 }
        let triangles: [Tri]
        /// Positions of the surface triangles' corners (fixed).
        let surface: [P3]
        let cellSize: Double
        let origin: P3
        var grid: [Cell: [Int]] = [:]

        init(points: [P3], triangles: [Tri]) {
            self.triangles = triangles
            self.surface = points
            var lo = P3(repeating: .infinity), hi = P3(repeating: -.infinity)
            var edgeTotal = 0.0
            for t in triangles {
                for v in [t.a, t.b, t.c] { lo = pointwiseMin(lo, points[v]); hi = pointwiseMax(hi, points[v]) }
                edgeTotal += simd_length(points[t.b] - points[t.a])
            }
            origin = lo
            let meanEdge = triangles.isEmpty ? 1 : edgeTotal / Double(triangles.count)
            let span = simd_reduce_max(hi - lo)
            cellSize = max(meanEdge * 4, span / 256, 1.0e-9)
            for (i, t) in triangles.enumerated() {
                let (a, b) = Self.cellRange(points[t.a], points[t.b], points[t.c], origin: origin, size: cellSize)
                for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z {
                    grid[Cell(x: x, y: y, z: z), default: []].append(i)
                } } }
            }
        }

        static func cellRange(_ p: P3, _ q: P3, _ r: P3, origin: P3, size: Double) -> (Cell, Cell) {
            let lo = (pointwiseMin(pointwiseMin(p, q), r) - origin) / size
            let hi = (pointwiseMax(pointwiseMax(p, q), r) - origin) / size
            return (Cell(x: Int32(lo.x.rounded(.down)), y: Int32(lo.y.rounded(.down)), z: Int32(lo.z.rounded(.down))),
                    Cell(x: Int32(hi.x.rounded(.down)), y: Int32(hi.y.rounded(.down)), z: Int32(hi.z.rounded(.down))))
        }

        /// Where the segment p → q first passes through a surface triangle
        /// (as a fraction of the way), ignoring triangles on corner `skip`.
        func firstHit(from p: P3, to q: P3, skipping skip: Int) -> Double? {
            guard simd_reduce_max(simd_abs(p)).isFinite, simd_reduce_max(simd_abs(q)).isFinite else { return nil }
            let (a, b) = Self.cellRange(p, q, q, origin: origin, size: cellSize)
            var seen = Set<Int>()
            var best: Double? = nil
            for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z {
                guard let bucket = grid[Cell(x: x, y: y, z: z)] else { continue }
                for s in bucket where seen.insert(s).inserted {
                    let t = triangles[s]
                    if t.a == skip || t.b == skip || t.c == skip { continue }
                    if let hit = segmentHitParameter(p, q, surface[t.a], surface[t.b], surface[t.c]),
                       best.map({ hit < $0 }) ?? true {
                        best = hit
                    }
                }
            } } }
            return best
        }

        /// Triangles (local indices) of a cap patch that cross a surface
        /// triangle they don't share a corner with.
        func crossingCapTriangles(_ patch: CapPatch) -> [Int] {
            crossing(patch, among: Array(patch.triangles.indices))
        }

        /// Which of `candidates` (cap triangle indices) cross the surface,
        /// checked in parallel.
        func crossing(_ patch: CapPatch, among candidates: [Int]) -> [Int] {
            guard !candidates.isEmpty else { return [] }
            var flags = [Bool](repeating: false, count: candidates.count)
            let chunk = max(16, candidates.count / (ProcessInfo.processInfo.activeProcessorCount * 4))
            let chunks = (candidates.count + chunk - 1) / chunk
            flags.withUnsafeMutableBufferPointer { buf in
                let out = SendablePointer(buf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                    let lo = ch * chunk, hi = min(candidates.count, lo + chunk)
                    guard lo < hi else { return }
                    for j in lo..<hi { out.base[j] = crosses(patch, triangle: candidates[j]) }
                }
            }
            return candidates.indices.filter { flags[$0] }.map { candidates[$0] }
        }

        /// Whether cap triangle `f` of `patch` crosses a surface triangle it
        /// doesn't share a corner with (a non-finite corner counts as a
        /// crossing).
        func crosses(_ patch: CapPatch, triangle f: Int) -> Bool {
            let cap = patch.triangles[f]
            let rim = patch.rimCount
            let p0 = patch.positions[cap.a], p1 = patch.positions[cap.b], p2 = patch.positions[cap.c]
            guard simd_reduce_max(simd_abs(p0)).isFinite, simd_reduce_max(simd_abs(p1)).isFinite,
                  simd_reduce_max(simd_abs(p2)).isFinite else { return true }
            let ga = cap.a < rim ? patch.rimGlobal[cap.a] : -1
            let gb = cap.b < rim ? patch.rimGlobal[cap.b] : -1
            let gc = cap.c < rim ? patch.rimGlobal[cap.c] : -1
            let (a, b) = Self.cellRange(p0, p1, p2, origin: origin, size: cellSize)
            var seen = Set<Int>()
            for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z {
                guard let bucket = grid[Cell(x: x, y: y, z: z)] else { continue }
                for s in bucket where seen.insert(s).inserted {
                    let t = triangles[s]
                    if t.a == ga || t.a == gb || t.a == gc || t.b == ga || t.b == gb || t.b == gc
                        || t.c == ga || t.c == gb || t.c == gc { continue }
                    if trianglesCross(p0, p1, p2, surface[t.a], surface[t.b], surface[t.c]) { return true }
                }
            } } }
            return false
        }
    }
}

// MARK: - Level-set caps (generalized winding number)

extension OpeningCapper {

    /// Shapes an opening's cap on a level set {w = c} of the generalized
    /// winding number w of the skin (and every OTHER cap), keeping the cap's
    /// triangles (Liepa + refinement) and moving only its interior vertices.
    ///
    /// Across the skin w jumps by exactly 1, so for 0 < c < 1 the level set
    /// is a smooth surface bounded by the rim that never passes through the
    /// skin (Jacobson et al. 2013). c = 0.5 is the flat cap: when the rim is
    /// planar the flat disk is exactly {w = 0.5} (a point on the disk sees
    /// skin + disk as a closed surface, 0.5, and the disk subtends nothing
    /// from its own plane). Smaller c bulges outward (dome), larger c inward
    /// (dish); the level sets are nested and all crossing-free.
    fileprivate struct LevelSetShaper: Sendable {
        let field: WindingLevelField

        /// Newton steps x ← x − (w − c)·∇w/|∇w|², each at most `maxStep`
        /// long, with backtracking: a step is taken only if |w − c| shrinks
        /// and w changed as the gradient predicts (a jump of ~1 means the
        /// step went through the skin, which is never allowed).
        func newton(_ start: P3, c: Double, maxStep: Double, tolerance: Double, iterations: Int) -> (P3, Bool) {
            var x = start
            var (w, g) = field.evaluate(x)
            for _ in 0..<iterations {
                let r = w - c
                let g2 = simd_length_squared(g)
                guard g2 > 0, g2.isFinite, r.isFinite else { return (x, false) }
                let dist = abs(r) / g2.squareRoot()
                if dist <= tolerance { return (x, true) }
                var step = g * (-r / g2)
                if dist > maxStep { step *= maxStep / dist }
                var t = 1.0
                var accepted = false
                for _ in 0..<8 {
                    let xn = x + t * step
                    let (wn, gn) = field.evaluate(xn)
                    let predicted = t * simd_dot(g, step)
                    if abs(wn - c) < abs(r), abs((wn - w) - predicted) < 0.5 {
                        x = xn; w = wn; g = gn
                        accepted = true
                        break
                    }
                    t *= 0.5
                }
                // No step helps: the far-field approximation's own noise
                // (clusters switching between near and far as x moves) sets
                // a floor on |w − c|. Close to the level set that is fine.
                if !accepted { return (x, dist <= 10 * tolerance) }
            }
            let g2 = simd_length_squared(g)
            return (x, g2 > 0 && abs(w - c) / g2.squareRoot() <= 10 * tolerance)
        }

        /// Newton for `vertices` of `positions` in parallel; returns which
        /// converged.
        func project(_ positions: inout [P3], _ vertices: [Int], c: Double, levels: [Double]? = nil, maxStep: [Double],
                     tolerance: [Double], iterations: Int) -> [Bool] {
            var ok = [Bool](repeating: false, count: vertices.count)
            guard !vertices.isEmpty else { return ok }
            let chunk = max(4, vertices.count / (ProcessInfo.processInfo.activeProcessorCount * 6))
            let chunks = (vertices.count + chunk - 1) / chunk
            positions.withUnsafeMutableBufferPointer { pbuf in
                ok.withUnsafeMutableBufferPointer { obuf in
                    let p = SendablePointer(pbuf.baseAddress!), o = SendablePointer(obuf.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                        let lo = ch * chunk, hi = min(vertices.count, lo + chunk)
                        guard lo < hi else { return }
                        for j in lo..<hi {
                            let v = vertices[j]
                            let (x, good) = newton(p.base[v], c: levels?[v] ?? c, maxStep: maxStep[v],
                                                   tolerance: tolerance[v], iterations: iterations)
                            p.base[v] = x
                            o.base[j] = good
                        }
                    }
                }
            }
            return ok
        }

        /// w and ∇w at `vertices` of `positions`, in parallel.
        func evaluate(_ positions: [P3], _ vertices: [Int]) -> [(w: Double, gradient: P3)] {
            var out = [(w: Double, gradient: P3)](repeating: (0, .zero), count: vertices.count)
            guard !vertices.isEmpty else { return out }
            let chunk = max(4, vertices.count / (ProcessInfo.processInfo.activeProcessorCount * 6))
            let chunks = (vertices.count + chunk - 1) / chunk
            out.withUnsafeMutableBufferPointer { obuf in
                let o = SendablePointer(obuf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                    let lo = ch * chunk, hi = min(vertices.count, lo + chunk)
                    guard lo < hi else { return }
                    for j in lo..<hi { o.base[j] = field.evaluate(positions[vertices[j]]) }
                }
            }
            return out
        }
    }

    /// What shaping one cap did (for the trace and the receipt).
    fileprivate struct LevelSetReport {
        var level = 0.5
        var interior = 0
        var suspects = 0
        var unconverged = 0
        var crossings = 0
        var refinedTriangles = 0
        /// The level set couldn't be followed; the plain membrane was kept.
        var usedMembrane = false
        /// Seconds spent per phase (trace only).
        var timings: [(String, Double)] = []
        var timingText: String { timings.map { String(format: "%@ %.2fs", $0.0, $0.1) }.joined(separator: ", ") }
    }
}

extension OpeningCapper.CapPatch {
    typealias P3 = SIMD3<Double>

    func vertexNeighbors() -> [[Int]] {
        var sets = [Set<Int>](repeating: [], count: positions.count)
        for t in triangles {
            sets[t.a].insert(t.b); sets[t.a].insert(t.c)
            sets[t.b].insert(t.a); sets[t.b].insert(t.c)
            sets[t.c].insert(t.a); sets[t.c].insert(t.b)
        }
        return sets.map { $0.sorted() }
    }

    /// Interior vertices that belong to at least one triangle.
    func interiorVertices() -> [Int] {
        var used = [Bool](repeating: false, count: positions.count)
        for t in triangles { used[t.a] = true; used[t.b] = true; used[t.c] = true }
        return (rimCount..<positions.count).filter { used[$0] }
    }

    /// Moves every interior vertex onto {w = c} (see `LevelSetShaper`),
    /// using the membrane only as a guide (steps 1–3, `placeOnLevel`), then
    /// a light tangential smoothing (moves along the level set only) evens
    /// out the triangles (step 4) and whatever still crosses the skin is
    /// refined or nudged (`resolveCrossings`). If crossings are left, the
    /// other placement strategy is tried too and the better cap kept.
    fileprivate mutating func shapeOnLevel(_ c: Double, shaper: OpeningCapper.LevelSetShaper,
                                           checker: OpeningCapper.CollisionChecker) -> OpeningCapper.LevelSetReport {
        let start = (positions: positions, triangles: triangles, sigma: sigma, bulge: bulge)
        let membraneCrossings = checker.crossingCapTriangles(self).count
        var best = shapeOnLevel(c, shaper: shaper, checker: checker, ringByRing: false)
        if best.crossings > 0 || best.unconverged > 0 {
            let first = (positions: positions, triangles: triangles, sigma: sigma, bulge: bulge)
            positions = start.positions; triangles = start.triangles; sigma = start.sigma; bulge = start.bulge
            let second = shapeOnLevel(c, shaper: shaper, checker: checker, ringByRing: true)
            if (second.crossings, second.unconverged) < (best.crossings, best.unconverged) {
                best = second
            } else {
                positions = first.positions; triangles = first.triangles; sigma = first.sigma; bulge = first.bulge
            }
        }
        // Where the level set can't be followed (a rim so tangled that its
        // level sets run into the leaves), never do worse than the plain
        // membrane: keep that and say so.
        if best.crossings > membraneCrossings {
            positions = start.positions; triangles = start.triangles; sigma = start.sigma; bulge = start.bulge
            var fallback = OpeningCapper.LevelSetReport(level: c)
            fallback.interior = best.interior
            fallback.crossings = membraneCrossings
            fallback.usedMembrane = true
            return fallback
        }
        return best
    }

    fileprivate mutating func shapeOnLevel(_ c: Double, shaper: OpeningCapper.LevelSetShaper,
                                           checker: OpeningCapper.CollisionChecker,
                                           ringByRing: Bool) -> OpeningCapper.LevelSetReport {
        var report = OpeningCapper.LevelSetReport(level: c)
        let interior = interiorVertices()
        report.interior = interior.count
        guard !interior.isEmpty else { return report }
        let neighbors = vertexNeighbors()
        let step = sigma.map { max($0, 1.0e-12) }
        let tolerance = step.map { 1.0e-4 * $0 }
        var clock = Date()
        func mark(_ name: String) {
            let now = Date()
            report.timings.append((name, now.timeIntervalSince(clock)))
            clock = now
        }
        let failed = ringByRing
            ? placeRingByRing(c, interior: interior, neighbors: neighbors, shaper: shaper, checker: checker,
                              step: step, tolerance: tolerance)
            : placeFromMembrane(c, interior: interior, shaper: shaper, step: step, tolerance: tolerance,
                                report: &report)
        report.unconverged = failed.count
        mark(ringByRing ? "rings" : "membrane")

        // 4. Tangential smoothing, each move kept only if the vertex projects
        //    back onto the level set (a move that slipped through the skin
        //    can't: Newton never crosses it back).
        do {
            let values = shaper.evaluate(positions, interior)
            let before = positions
            var moved = positions
            for (j, v) in interior.enumerated() where !failed.contains(v) {
                let nb = neighbors[v]
                guard !nb.isEmpty else { continue }
                var m = P3.zero
                for u in nb { m += before[u] }
                var d = m / Double(nb.count) - before[v]
                let g = values[j].gradient
                let g2 = simd_length_squared(g)
                if g2 > 0 { d -= g * (simd_dot(d, g) / g2) }
                moved[v] = before[v] + 0.5 * d
            }
            positions = moved
            let back = shaper.project(&positions, interior, c: c, maxStep: step, tolerance: tolerance, iterations: 12)
            for (j, v) in interior.enumerated() where !back[j] { positions[v] = before[v] }
        }

        mark("smooth")
        var noLevels: [Double]? = nil
        resolveCrossings(c, levels: &noLevels, shaper: shaper, checker: checker, report: &report)
        mark("refine+nudge")
        return report
    }

    /// Steps 1–3, from the membrane: every corner starts where the membrane
    /// put it; corners whose w there is far from c (on the far side of a
    /// leaf the membrane cut through) are re-placed harmonically from their
    /// settled neighbours and projected again. Returns the corners that did
    /// not converge.
    fileprivate mutating func placeFromMembrane(_ c: Double, interior: [Int], shaper: OpeningCapper.LevelSetShaper,
                                                step: [Double], tolerance: [Double],
                                                report: inout OpeningCapper.LevelSetReport) -> Set<Int> {
        let start = shaper.evaluate(positions, interior)
        var suspect = Set<Int>()
        for (j, v) in interior.enumerated() where !(abs(start[j].w - c) <= 0.45) { suspect.insert(v) }
        report.suspects = suspect.count
        let settled = interior.filter { !suspect.contains($0) }
        let ok = shaper.project(&positions, settled, c: c, maxStep: step, tolerance: tolerance, iterations: 40)
        for (j, v) in settled.enumerated() where !ok[j] { suspect.insert(v) }
        for _ in 0..<4 where !suspect.isEmpty {
            fairPositions(pinned: Set(interior).subtracting(suspect))
            let list = suspect.sorted()
            let again = shaper.project(&positions, list, c: c, maxStep: step, tolerance: tolerance, iterations: 40)
            suspect = Set(zip(list, again).filter { !$0.1 }.map { $0.0 })
        }
        return suspect
    }

    /// Steps 1–3, ring by ring from the rim inwards: each corner starts
    /// where the membrane puts it relative to its already placed
    /// neighbours, pulled back short of the skin if the way there from its
    /// nearest placed neighbour would pass through a leaf; Newton then never
    /// crosses the skin either, so every corner lands on the level set on
    /// the same side of the skin as the corners it hangs from. Returns the
    /// corners that did not converge.
    fileprivate mutating func placeRingByRing(_ c: Double, interior: [Int], neighbors: [[Int]],
                                              shaper: OpeningCapper.LevelSetShaper,
                                              checker: OpeningCapper.CollisionChecker,
                                              step: [Double], tolerance: [Double]) -> Set<Int> {
        let membrane = positions
        var placed = [Bool](repeating: false, count: positions.count)
        for i in 0..<rimCount { placed[i] = true }
        var layers: [[Int]] = []
        var seen = Set<Int>()
        var layer = interior.filter { v in neighbors[v].contains { $0 < rimCount } }
        seen.formUnion(layer)
        while !layer.isEmpty {
            layers.append(layer)
            var next: [Int] = []
            for v in layer {
                for u in neighbors[v] where u >= rimCount && !seen.contains(u) {
                    seen.insert(u)
                    next.append(u)
                }
            }
            layer = next
        }
        let unreached = interior.filter { !seen.contains($0) }
        if !unreached.isEmpty { layers.append(unreached) }
        var failed = Set<Int>()
        let rimGlobalIDs = rimGlobal
        let rim = rimCount
        for layer in layers {
            var starts = [P3](repeating: .zero, count: layer.count)
            let settled = placed
            let current = positions
            starts.withUnsafeMutableBufferPointer { buf in
                let out = SendablePointer(buf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: layer.count) { j in
                    let v = layer[j]
                    var guess = P3.zero
                    var count = 0.0
                    var base = -1
                    var baseDistance = Double.infinity
                    for u in neighbors[v] where settled[u] {
                        guess += current[u] + (membrane[v] - membrane[u])
                        count += 1
                        let d = simd_length_squared(membrane[v] - membrane[u])
                        if d < baseDistance { baseDistance = d; base = u }
                    }
                    guard base >= 0 else { out.base[j] = membrane[v]; return }
                    guess /= count
                    let from = current[base]
                    let skip = base < rim ? rimGlobalIDs[base] : -1
                    if let t = checker.firstHit(from: from, to: guess, skipping: skip) {
                        guess = from + (0.8 * t) * (guess - from)
                    }
                    out.base[j] = guess
                }
            }
            for (j, v) in layer.enumerated() { positions[v] = starts[j] }
            let ok = shaper.project(&positions, layer, c: c, maxStep: step, tolerance: tolerance, iterations: 40)
            for (j, v) in layer.enumerated() {
                placed[v] = true
                if !ok[j] { failed.insert(v) }
            }
        }
        return failed
    }

    /// Steps 5–6 of shaping: where a cap triangle still crosses the skin,
    /// refine there and put the new corners on the level set; what is left
    /// after that gets the micro-nudge. Updates `report.crossings`.
    fileprivate mutating func resolveCrossings(_ c: Double, levels: inout [Double]?, shaper: OpeningCapper.LevelSetShaper,
                                               checker: OpeningCapper.CollisionChecker,
                                               report: inout OpeningCapper.LevelSetReport,
                                               giveUpAbove: Int = Int.max) {
        // 5. Where a triangle still crosses the skin it is too coarse to
        //    follow the level set there (typically a chord between two rim
        //    corners across a fold): split its longest inner edge, put the
        //    new corner on the level set, and check again.
        var bad = checker.crossingCapTriangles(self)
        if bad.count > giveUpAbove {
            report.crossings = bad.count
            return
        }
        var rounds = 0
        let budget = max(64, triangles.count)
        var spent = 0
        // Splitting a crossing triangle can leave two crossing halves: keep
        // the state with the fewest crossings seen, never a worse one.
        var bestState = (positions: positions, triangles: triangles, sigma: sigma, bulge: bulge,
                         levels: levels, bad: bad, refined: report.refinedTriangles, unconverged: report.unconverged)
        while !bad.isEmpty, rounds < 12, spent < budget {
            rounds += 1
            var edges: [(Int, Int)] = []
            var chosen = Set<UInt64>()
            for f in bad {
                let t = triangles[f]
                var best: (Int, Int)? = nil
                var bestLength = 0.0
                // A chord between two rim corners can't move onto the level
                // set; it is split first. Otherwise the longest inner edge.
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] where !isRimBoundaryEdge(u, v) {
                    var l = simd_length(positions[u] - positions[v])
                    if u < rimCount && v < rimCount { l += 1.0e300 }
                    if l > bestLength { bestLength = l; best = (u, v) }
                }
                if let (u, v) = best, chosen.insert(Self.key(u, v)).inserted { edges.append((u, v)) }
            }
            guard !edges.isEmpty else { break }
            let splits = splitEdges(edges)
            let added = splits.map { $0.vertex }
            if var lv = levels {
                // A new corner's level is the mean of its edge's ends (the
                // rim's own level is 0.5, where every level set meets).
                for (m, u, v) in splits {
                    let lu = u < rimCount ? 0.5 : lv[u], lw = v < rimCount ? 0.5 : lv[v]
                    while lv.count <= m { lv.append(c) }
                    lv[m] = 0.5 * (lu + lw)
                }
                levels = lv
            }
            report.refinedTriangles += added.count
            spent += added.count
            let addedStep = sigma.map { max($0, 1.0e-12) }
            let ok = shaper.project(&positions, added, c: c, levels: levels, maxStep: addedStep,
                                    tolerance: addedStep.map { 1.0e-4 * $0 }, iterations: 40)
            report.unconverged += ok.filter { !$0 }.count
            // Only triangles around the new corners changed.
            let fresh = Set(added)
            let touched = triangles.indices.filter { f in
                let t = triangles[f]
                return fresh.contains(t.a) || fresh.contains(t.b) || fresh.contains(t.c)
            }
            let stillBad = Set(bad).subtracting(touched)
            bad = Array(stillBad.union(checker.crossing(self, among: touched))).sorted()
            if bad.count < bestState.bad.count {
                bestState = (positions, triangles, sigma, bulge, levels, bad, report.refinedTriangles, report.unconverged)
            }
        }

        // 6. What is left are contacts far below the mesh's own scale: a
        //    skin vertex sitting (within microns) on a rim edge, where the
        //    rim touches the skin. The flat triangle on that edge can't
        //    follow the level set around it; nudge its free corner by a few
        //    microns off the level set, keeping a move only if it lowers the
        //    number of crossing triangles around that corner. (Many
        //    crossings left are not micro contacts; nudging them one by one
        //    would only burn time.)
        func nudged(_ bad: [Int]) -> Int {
            bad.isEmpty ? 0 : (bad.count <= 32 ? nudgeCrossings(bad, checker: checker) : bad.count)
        }
        report.crossings = nudged(bad)
        if report.crossings > bestState.bad.count {
            // An earlier refinement round had fewer crossings: try it too.
            let last = (positions, triangles, sigma, bulge, levels, report)
            (positions, triangles, sigma, bulge, levels) =
                (bestState.positions, bestState.triangles, bestState.sigma, bestState.bulge, bestState.levels)
            report.refinedTriangles = bestState.refined
            report.unconverged = bestState.unconverged
            report.crossings = nudged(bestState.bad)
            if report.crossings >= last.5.crossings {
                (positions, triangles, sigma, bulge, levels, report) = last
            }
        }

    }

    /// Dome / dish: moves the (already flat, c = 0.5) cap onto the level set
    /// {w = c} whose peak displacement from the flat cap along the opening's
    /// outward normal `outward` is `height` (mm; > 0 dome outward, < 0 dish
    /// inward). Smaller c bulges outward, larger c inward; c is found by
    /// root-finding on the peak displacement.
    ///
    /// Where the rim runs close along the skin (a crown valley whose skin
    /// leaves the rim almost in the cap's own plane), every level set leaves
    /// the rim at an angle set by c, so a level far from 0.5 runs into the
    /// skin right at the rim long before the middle reaches the height. Then
    /// the level is graded instead: each corner moves to its own level
    /// c = 0.5 ∓ a·b, with b the membrane's pressure profile (0 at the rim,
    /// 1 at the top) — the cap leaves the rim like the flat cap and rises in
    /// the middle. Each corner still sits on a level set, so none is ever
    /// inside the skin. Whichever reaches more of the height without
    /// crossing the skin is kept; a height neither can reach is clamped.
    /// Returns the height actually achieved (signed) — measured on the
    /// finished cap, never assumed.
    fileprivate mutating func shapeToHeight(_ height: Double, outward: P3, shaper: OpeningCapper.LevelSetShaper,
                                            checker: OpeningCapper.CollisionChecker)
        -> (achieved: Double, report: OpeningCapper.LevelSetReport) {
        var report = OpeningCapper.LevelSetReport(level: 0.5)
        let interior = interiorVertices()
        report.interior = interior.count
        guard height != 0, !interior.isEmpty, simd_length_squared(outward) > 0 else { return (0, report) }
        let flatState = (positions: positions, triangles: triangles, sigma: sigma, bulge: bulge)
        let flat = positions
        let sign: Double = height > 0 ? 1 : -1
        let target = abs(height)
        let step = sigma.map { 2 * max($0, 1.0e-12) }
        let tolerance = sigma.map { 1.0e-4 * max($0, 1.0e-12) }
        let trace = ProcessInfo.processInfo.environment["REFAB_CAP_TRACE"] == "1"
        func note(_ text: String) {
            if trace { FileHandle.standardError.write(Data(("    " + text + "\n").utf8)) }
        }
        func peak(_ pos: [P3], _ verts: [Int]) -> Double {
            verts.reduce(-Double.infinity) { max($0, sign * simd_dot(pos[$1] - flat[$1], outward)) }
        }
        // The peak sits where the membrane's pressure profile does: probe
        // with the corners near the top of that profile only.
        var profile = [Double](repeating: 0, count: positions.count)
        var probe = interior
        let top = interior.map { bulge.indices.contains($0) ? bulge[$0] : 0 }.max() ?? 0
        if top > 0 {
            for v in interior { profile[v] = max(0, bulge[v] / top) }
            let ranked = interior.filter { profile[$0] >= 0.8 }.sorted { profile[$0] > profile[$1] }
            probe = Array(ranked.prefix(64))
        } else {
            for v in interior { profile[v] = 1 }
        }
        func levels(_ a: Double, graded: Bool) -> [Double] {
            var lv = [Double](repeating: 0.5, count: positions.count)
            for v in interior { lv[v] = 0.5 - sign * a * (graded ? profile[v] : 1) }
            return lv
        }

        struct Outcome {
            var amplitude: Double
            var achieved: Double
            var state: (positions: [P3], triangles: [OpeningCapper.Tri], sigma: [Double], bulge: [Double])
            var report: OpeningCapper.LevelSetReport
        }

        /// Largest amplitude a (levels 0.5 ∓ a, or 0.5 ∓ a·b graded) whose
        /// probe peak does not pass the target.
        func search(graded: Bool, from start: Double = 0.03) -> Double {
            var warm = flat
            func probeAt(_ a: Double) -> Double? {
                let ok = shaper.project(&warm, probe, c: 0.5, levels: levels(a, graded: graded), maxStep: step,
                                        tolerance: tolerance, iterations: 40)
                let result = ok.allSatisfy { $0 } ? peak(warm, probe) : nil
                note(String(format: "%@ probe a=%.4f -> %@", graded ? "graded" : "uniform", a,
                            result.map { String(format: "%.3f", $0) } ?? "unreachable"))
                return result
            }
            var lower = (a: 0.0, peak: 0.0)
            var upper: (a: Double, peak: Double?)? = nil
            var a = min(max(start, 1.0e-3), 0.48)
            while true {
                let p = probeAt(a)
                if let p, p < target {
                    lower = (a, p)
                    if a >= 0.48 { break }
                    a = min(a * 1.6, 0.48)
                } else {
                    upper = (a, p)
                    break
                }
            }
            guard var up = upper else { return lower.a }
            var side = 0
            for _ in 0..<30 {
                var x: Double
                if let pu = up.peak {
                    var fl = lower.peak - target, fu = pu - target
                    if side == -1 { fu *= 0.5 } else if side == 1 { fl *= 0.5 }
                    x = lower.a + (up.a - lower.a) * (fl / (fl - fu))
                    if !x.isFinite || x <= lower.a || x >= up.a { x = 0.5 * (lower.a + up.a) }
                } else {
                    x = 0.5 * (lower.a + up.a)
                }
                let p = probeAt(x)
                if let p, p <= target {
                    lower = (x, p)
                    side = -1
                    if target - p <= 1.0e-3 * target { break }
                } else {
                    up = (x, p)
                    side = 1
                    if let p, p - target <= 1.0e-3 * target { return x }
                }
                if up.a - lower.a < 1.0e-7 { break }
            }
            return lower.a
        }

        /// The whole cap at amplitude a, crossings resolved; nil if it
        /// doesn't converge everywhere or still crosses the skin.
        func attempt(_ a: Double, graded: Bool) -> Outcome? {
            positions = flatState.positions
            triangles = flatState.triangles
            sigma = flatState.sigma
            bulge = flatState.bulge
            var lv: [Double]? = levels(a, graded: graded)
            let ok = shaper.project(&positions, interior, c: 0.5, levels: lv, maxStep: step,
                                    tolerance: tolerance, iterations: 40)
            let measured = peak(positions, interior)
            var trial = OpeningCapper.LevelSetReport(level: 0.5 - sign * a)
            trial.interior = interior.count
            trial.unconverged = ok.filter { !$0 }.count
            var result: Outcome? = nil
            if trial.unconverged == 0 {
                // Many crossings mean the level set runs into the skin, not a
                // discretisation miss: don't try to refine that away.
                resolveCrossings(0.5 - sign * a, levels: &lv, shaper: shaper, checker: checker, report: &trial,
                                 giveUpAbove: 40)
                if trial.crossings == 0 && trial.unconverged == 0 {
                    result = Outcome(amplitude: a, achieved: sign * measured,
                                     state: (positions, triangles, sigma, bulge), report: trial)
                }
            }
            note(String(format: "%@ full a=%.4f peak %.3f unconverged %d crossings %d -> %@", graded ? "graded" : "uniform",
                        a, measured, trial.unconverged, trial.crossings, result == nil ? "rejected" : "ok"))
            return result
        }

        // The plain level set first; if it can't reach the height, the
        // graded one (from the same amplitude); if that can't either, the
        // largest graded amplitude that works (bisection towards flat).
        let uniformAmplitude = search(graded: false)
        var best = attempt(uniformAmplitude, graded: false)
        if (best?.achieved).map({ abs($0) < 0.98 * target }) ?? true {
            let a = search(graded: true, from: uniformAmplitude)
            var graded = attempt(a, graded: true)
            if graded == nil {
                var lo = 0.0, hi = a
                for _ in 0..<5 {
                    let mid = 0.5 * (lo + hi)
                    if let hit = attempt(mid, graded: true) { graded = hit; lo = mid } else { hi = mid }
                }
            }
            if let graded, abs(graded.achieved) > abs(best?.achieved ?? 0) { best = graded }
        }
        guard let best else {
            positions = flatState.positions
            triangles = flatState.triangles
            sigma = flatState.sigma
            bulge = flatState.bulge
            return (0, report)
        }
        positions = best.state.positions
        triangles = best.state.triangles
        sigma = best.state.sigma
        bulge = best.state.bulge
        return (best.achieved, best.report)
    }

    /// Local search: for each free corner of a crossing triangle, try small
    /// moves along the triangle's normal and the corner's normal; keep the
    /// move that most reduces the crossing triangles around the corner.
    /// Returns the crossings left.
    fileprivate mutating func nudgeCrossings(_ start: [Int], checker: OpeningCapper.CollisionChecker) -> Int {
        var incident = [[Int]](repeating: [], count: positions.count)
        for (f, t) in triangles.enumerated() {
            incident[t.a].append(f); incident[t.b].append(f); incident[t.c].append(f)
        }
        func normal(_ f: Int) -> P3 {
            let t = triangles[f]
            let n = simd_cross(positions[t.b] - positions[t.a], positions[t.c] - positions[t.a])
            let l = simd_length(n)
            return l > 0 ? n / l : .zero
        }
        func crossingCount(around v: Int) -> Int {
            incident[v].reduce(0) { $0 + (checker.crosses(self, triangle: $1) ? 1 : 0) }
        }
        var bad = Set(start)
        for _ in 0..<6 where !bad.isEmpty {
            var improved = false
            for f in bad.sorted() {
                let t = triangles[f]
                for v in [t.a, t.b, t.c] where v >= rimCount {
                    let base = crossingCount(around: v)
                    guard base > 0 else { continue }
                    var vn = P3.zero
                    for g in incident[v] { vn += normal(g) }
                    let l = simd_length(vn)
                    let dirs = [normal(f), l > 0 ? vn / l : .zero].filter { $0 != .zero }
                    let origin = positions[v]
                    let scale = max(sigma[v], 1.0e-12)
                    var best = (count: base, move: 0.0, pos: origin)
                    for d in dirs {
                        for m in [1.0e-5, 3.0e-5, 1.0e-4, 3.0e-4, 1.0e-3, 3.0e-3, 1.0e-2, 3.0e-2, 0.1] {
                            for sign in [1.0, -1.0] {
                                positions[v] = origin + (sign * m * scale) * d
                                let n = crossingCount(around: v)
                                if n < best.count || (n == best.count && n < base && m < best.move) {
                                    best = (n, m, positions[v])
                                }
                            }
                        }
                    }
                    positions[v] = best.pos
                    if best.count < base { improved = true }
                }
            }
            bad = Set(checker.crossingCapTriangles(self))
            if !improved { break }
        }
        return bad.count
    }

    /// True for an edge between consecutive rim corners (shared with the
    /// surface; it can't be split).
    func isRimBoundaryEdge(_ u: Int, _ v: Int) -> Bool {
        let rim = rimCount
        guard u < rim, v < rim else { return false }
        let d = abs(u - v)
        return d == 1 || d == rim - 1
    }

    /// Splits each inner edge at its midpoint (both triangles on it are
    /// halved, winding kept). Returns the new vertices.
    mutating func splitEdges(_ edges: [(Int, Int)]) -> [(vertex: Int, u: Int, v: Int)] {
        var added: [(vertex: Int, u: Int, v: Int)] = []
        for (u, v) in edges {
            let faces = triangles.indices.filter { f in
                let t = triangles[f]
                let cs = [t.a, t.b, t.c]
                return cs.contains(u) && cs.contains(v)
            }
            guard !faces.isEmpty else { continue }
            let m = positions.count
            positions.append(0.5 * (positions[u] + positions[v]))
            sigma.append(0.5 * (sigma[u] + sigma[v]))
            if !bulge.isEmpty { bulge.append(0.5 * (bulge[u] + bulge[v])) }
            for f in faces {
                let t = triangles[f]
                // Rotate so the split edge is (a, b) in winding order.
                let r: OpeningCapper.Tri
                if (t.a == u && t.b == v) || (t.a == v && t.b == u) { r = t }
                else if (t.b == u && t.c == v) || (t.b == v && t.c == u) { r = OpeningCapper.Tri(a: t.b, b: t.c, c: t.a) }
                else { r = OpeningCapper.Tri(a: t.c, b: t.a, c: t.b) }
                triangles[f] = OpeningCapper.Tri(a: r.a, b: m, c: r.c)
                triangles.append(OpeningCapper.Tri(a: m, b: r.b, c: r.c))
            }
            added.append((m, u, v))
        }
        return added
    }
}

// MARK: - Small vector helpers

private func safeNormalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let l = simd_length(v)
    return l > 0 ? v / l : SIMD3<Double>(0, 0, 0)
}

/// True if either triangle has an edge passing through the other's interior.
private func trianglesCross(_ a0: SIMD3<Double>, _ a1: SIMD3<Double>, _ a2: SIMD3<Double>,
                            _ b0: SIMD3<Double>, _ b1: SIMD3<Double>, _ b2: SIMD3<Double>) -> Bool {
    segmentHitsTriangle(a0, a1, b0, b1, b2) || segmentHitsTriangle(a1, a2, b0, b1, b2)
        || segmentHitsTriangle(a2, a0, b0, b1, b2) || segmentHitsTriangle(b0, b1, a0, a1, a2)
        || segmentHitsTriangle(b1, b2, a0, a1, a2) || segmentHitsTriangle(b2, b0, a0, a1, a2)
}

/// Möller–Trumbore: where along p → q (0 … 1) the segment passes through
/// the triangle, if it does.
private func segmentHitParameter(_ p: SIMD3<Double>, _ q: SIMD3<Double>,
                                 _ v0: SIMD3<Double>, _ v1: SIMD3<Double>, _ v2: SIMD3<Double>) -> Double? {
    let dir = q - p
    let e1 = v1 - v0, e2 = v2 - v0
    let h = simd_cross(dir, e2)
    let det = simd_dot(e1, h)
    let scale = simd_length(e1) * simd_length(e2) * simd_length(dir)
    if abs(det) <= 1.0e-12 * scale { return nil }
    let inv = 1 / det
    let s = p - v0
    let u = inv * simd_dot(s, h)
    if u < 0 || u > 1 { return nil }
    let qv = simd_cross(s, e1)
    let v = inv * simd_dot(dir, qv)
    if v < 0 || u + v > 1 { return nil }
    let t = inv * simd_dot(e2, qv)
    return t >= 0 && t <= 1 ? t : nil
}

/// Möller–Trumbore restricted to the open segment p→q.
private func segmentHitsTriangle(_ p: SIMD3<Double>, _ q: SIMD3<Double>,
                                 _ v0: SIMD3<Double>, _ v1: SIMD3<Double>, _ v2: SIMD3<Double>) -> Bool {
    let dir = q - p
    let e1 = v1 - v0, e2 = v2 - v0
    let h = simd_cross(dir, e2)
    let det = simd_dot(e1, h)
    let scale = simd_length(e1) * simd_length(e2) * simd_length(dir)
    if abs(det) <= 1.0e-12 * scale { return false }
    let inv = 1 / det
    let s = p - v0
    let u = inv * simd_dot(s, h)
    if u <= 1.0e-9 || u >= 1 - 1.0e-9 { return false }
    let qv = simd_cross(s, e1)
    let v = inv * simd_dot(dir, qv)
    if v <= 1.0e-9 || u + v >= 1 - 1.0e-9 { return false }
    let t = inv * simd_dot(e2, qv)
    return t > 1.0e-9 && t < 1 - 1.0e-9
}
