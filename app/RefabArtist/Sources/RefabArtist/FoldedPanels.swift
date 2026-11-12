import Foundation

/// The kind of joinery applied to the mating edges of adjacent folded
/// panels. The engine default is `tab`.
///
/// The CLI, project document and planner all thread this value end-to-end;
/// `FoldedJoineryGeometry` turns each type into edge features.
enum JoineryType: String, Codable, CaseIterable, Equatable {
    case tab
    case diamond
    case puzzle
    case seam
    case ticked
    case gear
    case multitab
    case tongue
    case rivet
    case laced
    case trivial

    /// Parse a CLI value (any case, hyphens or underscores allowed) into a
    /// JoineryType. `none` is plain edges (the menu's None). The older
    /// spellings `trivial` and `seam` are still accepted and also mean None,
    /// as a saved Seam does (`JoineryParameters.sanitized`). Returns nil for
    /// unknown values so callers can surface a clean error rather than
    /// silently defaulting.
    static func cliValue(_ raw: String) -> JoineryType? {
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "none", "trivial", "seam":
            return .trivial
        default:
            return JoineryType(rawValue: normalized)
        }
    }

    /// The CLI spelling of the type: `none` for plain edges, otherwise the
    /// raw value.
    var cliName: String {
        self == .trivial ? "none" : rawValue
    }

    /// The Joint Type menu order: None (plain edges), then alphabetical:
    /// Diamond, Gear, Laced, Multitab, Puzzle, Rivet, Tab, Ticked, Tongue.
    /// `seam` is not offered: it cut nothing of its own, so it is None
    /// (`sanitized` turns a saved Seam into None).
    static let menuOrder: [JoineryType] = [
        .trivial, .diamond, .gear, .laced, .multitab, .puzzle,
        .rivet, .tab, .ticked, .tongue
    ]

    var label: String {
        switch self {
        case .tab: return "Tab"
        case .diamond: return "Diamond"
        case .puzzle: return "Puzzle"
        case .seam: return "Seam"
        case .ticked: return "Ticked"
        case .gear: return "Gear"
        case .multitab: return "Multitab"
        case .tongue: return "Tongue"
        case .rivet: return "Rivet"
        case .laced: return "Laced"
        case .trivial: return "None"
        }
    }
}

/// The per-type joinery parameters behind each Joint Type preset. The
/// defaults are round inch values; Refab Artist is mm-native, so they are
/// stored converted at ×25.4.
///
/// Shared preset values (identical across all 10 built-in presets):
///   holeRadius 0.0625″ = 1.5875 mm, tickRadius 0.0625″ = 1.5875 mm,
///   toothRadius 0.1″ = 2.54 mm, seamRadius 0.1″ = 2.54 mm,
///   toothScale 0.1 (fraction), tickSpace 1.0″ = 25.4 mm,
///   tabFraction 0.45 (fraction), jointSpace 1.0″ = 25.4 mm — except the
///   Multitab / Puzzle / Seam presets where jointSpace = 0.5″ = 12.7 mm.
struct JoineryParameters: Equatable, Codable {
    var type: JoineryType
    /// Distance between neighbouring pinned tabs (Rivet), lace holes and
    /// Multitab tabs (mm).
    var jointSpace: Double = 25.4
    /// Fraction of each `jointSpace` taken by a Multitab tab.
    var tabFraction: Double = 0.45
    /// How far Gear fingers stand proud of the other panel's outside face,
    /// as a fraction of the finger pitch (`tickSpace`).
    var toothScale: Double = 0.1
    /// Rivet pin hole and lace hole radius (mm).
    var holeRadius: Double = 1.5875
    /// Tick radius (mm): the size driver for Tab, Diamond, Tongue and Puzzle
    /// (a tab is 4 × tickRadius wide, 6.35 mm, and stands tickRadius past
    /// the far face of the panel it passes through), the material a lug
    /// keeps round its slot, and the material between a hole and the edge.
    var tickRadius: Double = 1.5875
    /// No longer used: Gear fingers pass through open notches where the
    /// stock meets. Kept so saved projects load unchanged.
    var toothRadius: Double = 2.54
    /// Ticked notch width and depth (mm).
    var seamRadius: Double = 2.54
    /// Distance between Ticked notches and Gear fingers (mm).
    var tickSpace: Double = 25.4
    /// Fold-line perforation toggle (default true). When on, fold lines are
    /// dashes to cut through (a perforated crease); off, full lines to score.
    var perforate: Bool = true

    init(type: JoineryType) {
        self.type = type
    }

    /// The built-in preset for a joint type, in mm.
    static func preset(for type: JoineryType) -> JoineryParameters {
        var parameters = JoineryParameters(type: type)
        switch type {
        case .multitab, .puzzle, .seam:
            parameters.jointSpace = 12.7
        default:
            break
        }
        return parameters
    }

    private enum CodingKeys: String, CodingKey {
        case type, jointSpace, tabFraction, toothScale, holeRadius
        case tickRadius, toothRadius, seamRadius, tickSpace, perforate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedType = try container.decode(JoineryType.self, forKey: .type)
        self.init(type: decodedType)
        let defaults = JoineryParameters.preset(for: decodedType)
        jointSpace = try container.decodeIfPresent(Double.self, forKey: .jointSpace) ?? defaults.jointSpace
        tabFraction = try container.decodeIfPresent(Double.self, forKey: .tabFraction) ?? defaults.tabFraction
        toothScale = try container.decodeIfPresent(Double.self, forKey: .toothScale) ?? defaults.toothScale
        holeRadius = try container.decodeIfPresent(Double.self, forKey: .holeRadius) ?? defaults.holeRadius
        tickRadius = try container.decodeIfPresent(Double.self, forKey: .tickRadius) ?? defaults.tickRadius
        toothRadius = try container.decodeIfPresent(Double.self, forKey: .toothRadius) ?? defaults.toothRadius
        seamRadius = try container.decodeIfPresent(Double.self, forKey: .seamRadius) ?? defaults.seamRadius
        tickSpace = try container.decodeIfPresent(Double.self, forKey: .tickSpace) ?? defaults.tickSpace
        perforate = try container.decodeIfPresent(Bool.self, forKey: .perforate) ?? defaults.perforate
    }

    /// Clamp every numeric field to a sane positive range so a hand-edited
    /// project file cannot produce degenerate joinery geometry.
    var sanitized: JoineryParameters {
        var copy = self
        // Seam left the edges plain, which is what None does.
        if copy.type == .seam {
            copy.type = .trivial
        }
        copy.jointSpace = min(max(jointSpace.isFinite ? jointSpace : 25.4, 0.1), 500.0)
        copy.tabFraction = min(max(tabFraction.isFinite ? tabFraction : 0.45, 0.01), 1.0)
        copy.toothScale = min(max(toothScale.isFinite ? toothScale : 0.1, 0.01), 1.0)
        copy.holeRadius = min(max(holeRadius.isFinite ? holeRadius : 1.5875, 0.01), 100.0)
        copy.tickRadius = min(max(tickRadius.isFinite ? tickRadius : 1.5875, 0.01), 100.0)
        copy.toothRadius = min(max(toothRadius.isFinite ? toothRadius : 2.54, 0.01), 100.0)
        copy.seamRadius = min(max(seamRadius.isFinite ? seamRadius : 2.54, 0.01), 100.0)
        copy.tickSpace = min(max(tickSpace.isFinite ? tickSpace : 25.4, 0.1), 500.0)
        return copy
    }
}

/// A user-added seam: the 3D mesh edge (model coordinates) that must become
/// a CUT in the unfolded net instead of a fold candidate, added or removed
/// by clicking a mesh edge — adding a seam separates large panels into
/// smaller ones. (Project persistence flattens
/// these to [ax, ay, az, bx, by, bz] doubles — Vec3 itself is not Codable.)
struct FoldedSeamEdge: Equatable {
    var a: Vec3
    var b: Vec3
}

struct FoldedPanelPlan: Equatable {
    var panels: [FoldedPanel]
    /// The full joinery configuration (type + per-type parameters). The
    /// engine default remains the `tab` preset, so headless output is
    /// unchanged; the GUI passes the user's Joint Type selection (GUI
    /// default: Diamond).
    var joinery: JoineryParameters
    /// The material thickness the joinery slots were sized with, kept on the
    /// plan so exporters (perforation dash length, slot heights) need no
    /// side-channel.
    var materialThickness: Double

    var joineryType: JoineryType { joinery.type }

    /// The single connected outline of the unfolded panel net, in true-mm
    /// coordinates (a hinge unfold makes the panels meet edge-to-edge). This
    /// is the `boundary`-layer silhouette consumed ONLY by the DXF Folded
    /// exporter; it is `nil` when a connected net could not be assembled
    /// (non-cube / non-developable meshes), in which case the DXF exporter
    /// falls back to the legacy per-panel emission. The outline is a closed
    /// ring whose consecutive segment endpoints coincide exactly so the
    /// comparator chains it into one polygon.
    var netOutline: [Vec2]?

    /// The interior fold-edge segments (one full-length segment per shared
    /// hinge edge) in the same true-mm coordinate frame as `netOutline`. For
    /// the cube there are exactly 5 (the spanning-tree fold edges of 6 faces).
    /// Consumed only by the DXF `fold-line` layer; `nil`/empty otherwise.
    var foldEdges: [FoldedNetFoldEdge]?

    /// The multi-net unfold: EVERY panel is reached by exactly one net, with
    /// a new net started whenever hinge-unfolding the next panel would
    /// overlap material already placed in the current net (or exceed the
    /// caller's usable sheet extent). Non-developable meshes therefore split
    /// into several flat, cuttable nets instead of degrading to the loose
    /// per-panel scatter. The single-net `netOutline`/`foldEdges` pair above
    /// is the DXF writer's fallback when no nets were assembled.
    var nets: [FoldedNet]

    /// The coplanar panels in their ORIGINAL 3D position on the mesh surface
    /// — i.e. the shape the flat net folds back up into. Each entry is one
    /// panel group's ordered 3D boundary polygon, in the model's own
    /// coordinate space. This is what the 3D viewport renders (the assembled,
    /// faceted "papercraft" object); the flat `nets` belong to the cut sheet.
    var surfaces3D: [[Vec3]]

    /// How many of the nets' cut edges got the joint, and why the rest stay
    /// plain; nil for joint types that add nothing to the edges.
    var jointCensus: FoldedJointCensus?

    /// How many panels the stock leaves out or cuts back by more than half.
    var stockCensus = FoldedStockCensus()

    /// The panels the stock leaves out (indices into `panels`): all their
    /// stock is where other pieces' stock is, so no net holds them and they
    /// have no assembly step.
    var leftOutPanels: [Int] = []

    init(
        panels: [FoldedPanel],
        joinery: JoineryParameters = .preset(for: .tab),
        materialThickness: Double = 3.0,
        netOutline: [Vec2]? = nil,
        foldEdges: [FoldedNetFoldEdge]? = nil,
        nets: [FoldedNet] = [],
        surfaces3D: [[Vec3]] = [],
        jointCensus: FoldedJointCensus? = nil,
        stockCensus: FoldedStockCensus = FoldedStockCensus(),
        leftOutPanels: [Int] = []
    ) {
        self.panels = panels
        self.joinery = joinery
        self.materialThickness = materialThickness
        self.netOutline = netOutline
        self.foldEdges = foldEdges
        self.nets = nets
        self.surfaces3D = surfaces3D
        self.jointCensus = jointCensus
        self.stockCensus = stockCensus
        self.leftOutPanels = leftOutPanels
    }

    var panelCount: Int {
        panels.count
    }
}

/// The cut edges of a Folded Panels unfold and the joints they got. Every
/// model edge the unfold cuts into two outline copies (a seam, glued or
/// joined when the net is folded up) either gets the chosen joint or stays a
/// plain edge, for one of three reasons.
struct FoldedJointCensus: Equatable {
    /// Cut edges: model edges cut into two outline copies.
    var cutEdges = 0
    /// Cut edges that got the joint.
    var joined = 0
    /// Cut edges too short for the joint (not over three features long).
    var tooShort = 0
    /// Cut edges whose panels meet too flat for a joint that passes through
    /// a slot (`FoldedJoineryGeometry.flattestSlotAngle`).
    var tooFlat = 0
    /// Cut edges where the joint does not fit the net: it would run into a
    /// panel or another joint, break through its panel, or leave too little
    /// material around a hole.
    var noRoom = 0
    /// Cut edges at an inside corner, where the female panel's stock does
    /// not reach the place an open-notch joint (Gear, Puzzle) passes through.
    var insideCorner = 0

    /// Cut edges left plain, to glue.
    var plain: Int { cutEdges - joined }

    /// What the joint did to the cut edges, in words, for the Folded panel
    /// and the CLI: how many got it, and why the others stay plain.
    func summary(joint: String) -> String {
        guard cutEdges > 0 else {
            return "The net has no cut edges to join."
        }
        guard plain > 0 else {
            return cutEdges == 1 ? "\(joint) joint on the 1 cut edge." : "\(joint) joints on all \(cutEdges) cut edges."
        }
        var reasons: [String] = []
        if tooShort > 0 {
            reasons.append("\(tooShort) too short for it")
        }
        if tooFlat > 0 {
            reasons.append("\(tooFlat) where the panels meet too flat for a slot")
        }
        if noRoom > 0 {
            reasons.append("\(noRoom) with no room for it on the net")
        }
        if insideCorner > 0 {
            reasons.append("\(insideCorner) at an inside corner, where an open notch has nothing to hold")
        }
        let why = reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))"
        if joined == 0 {
            let all = cutEdges == 1 ? "the 1 cut edge stays a plain edge" : "all \(cutEdges) cut edges stay plain edges"
            return "No \(joint) joints on this model: \(all) to glue\(why)."
        }
        let rest = plain == 1 ? "the other 1 stays a plain edge" : "the other \(plain) stay plain edges"
        return "\(joint) joints on \(joined) of \(cutEdges) cut edges; \(rest) to glue\(why)."
    }
}

/// What the stock does to the panels: each panel is cut back where its
/// stock would pass into a neighbouring piece's, and a panel (a sliver
/// between bigger panels, or a face of a part of the model thinner than
/// twice the stock) can lose most or all of itself that way.
struct FoldedStockCensus: Equatable {
    /// Panels placed in the nets.
    var panels = 0
    /// Panels left out: all their stock is where other pieces' stock is.
    var leftOut = 0
    /// Panels kept but cut back to less than half their area.
    var cutBackByHalf = 0

    /// What the stock did to the panels, in words, for the Folded panel and
    /// the CLI; nil when every panel keeps at least half its area.
    func summary(thickness: Double) -> String? {
        guard leftOut > 0 || cutBackByHalf > 0 else {
            return nil
        }
        let stock = "\(thickness.formatted(.number.precision(.fractionLength(0...2)))) mm stock"
        var parts: [String] = []
        if leftOut > 0 {
            parts.append(leftOut == 1 ? "1 of \(panels) panels is left out" : "\(leftOut) of \(panels) panels are left out")
        }
        if cutBackByHalf > 0 {
            parts.append(cutBackByHalf == 1 ? "1 panel is cut back to less than half its size" : "\(cutBackByHalf) panels are cut back to less than half their size")
        }
        return parts.joined(separator: " and ")
            + ": in \(stock) they sit where their neighbours' stock already is. Thinner stock, or a lower Detail for bigger panels, keeps more of them."
    }
}

/// One connected, non-overlapping piece of the multi-net unfold, in true mm.
/// `outline` is the closed CCW cut silhouette with the joints' tabs, lugs
/// and notches already in it; `slotHoles` are the joints' holes (slots,
/// lace and pin holes); `foldEdges` are this net's fold lines; and
/// `panelOutlines` are the placed panels, each cut back where its stock
/// meets a neighbouring piece (empty for a panel the stock leaves no room
/// for). For each entry of `panelOutlines`, `panelFrames` gives where the
/// panel sits on the model once the net is folded up (nil for a panel too
/// thin to fix a plane), `panelInward` the direction from its outside face
/// into its stock, and `panelFeatures` the joint features that stand out of
/// it. `hinges` lists the panels joined by a fold line, which are one piece
/// of stock bent there. `outlineHoles` are loops the outline encloses that
/// are not joints (a net that closes round a gap).
struct FoldedNet: Equatable {
    var outline: [Vec2]
    var foldEdges: [FoldedNetFoldEdge]
    var slotHoles: [[Vec2]]
    var panelOutlines: [[Vec2]]
    var panelFrames: [PartPlaneFrame?] = []
    var panelInward: [Vec3] = []
    var panelFeatures: [[[Vec2]]] = []
    var hinges: [FoldedNetHinge] = []
    var outlineHoles: [[Vec2]] = []

    var bounds: FoldedPanelBounds {
        var points = outline.isEmpty ? panelOutlines.flatMap { $0 } : outline
        for hole in slotHoles {
            points.append(contentsOf: hole)
        }
        guard let first = points.first else {
            return FoldedPanelBounds(min: Vec2(x: 0, y: 0), max: Vec2(x: 0, y: 0))
        }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        return FoldedPanelBounds(min: Vec2(x: minX, y: minY), max: Vec2(x: maxX, y: maxY))
    }
}

/// One interior fold (hinge) segment of the unfolded net, in the same true-mm
/// 2D frame as `FoldedPanelPlan.netOutline`. A tuple would not satisfy
/// `Equatable` synthesis for the plan, so this is a named struct.
struct FoldedNetFoldEdge: Equatable {
    var start: Vec2
    var end: Vec2
}

/// Two panels of a net (indices into `FoldedNet.panelOutlines`) joined by a
/// fold line.
struct FoldedNetHinge: Equatable {
    var a: Int
    var b: Int
}

struct FoldedPanel: Equatable {
    var points: [Vec2]
    var bounds: FoldedPanelBounds
    var sourceTriangleIndex: Int
}

struct FoldedPanelBounds: Equatable {
    var min: Vec2
    var max: Vec2
}

enum FoldedPanelPlanner {
    static func plan(
        model: MeshSummary,
        joinery: JoineryParameters = .preset(for: .tab),
        materialThickness: Double = 3.0,
        slotClearance: Double = 0,
        maxNetExtent: Vec2? = nil,
        seamEdges: [FoldedSeamEdge] = []
    ) -> FoldedPanelPlan {
        let triangles = consistentlyWound(triangleRecords(from: model.geometry))
        let (panels, panelComponents) = groupedCoplanarPanels(from: triangles)
        let seamKeys = seamEdgeKeys(for: seamEdges)
        let net = assembleNet(from: triangles, seamKeys: seamKeys)
        let (nets, jointCensus, stockCensus, leftOutComponents) = assembleNets(
            from: triangles,
            joinery: joinery,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            maxExtent: maxNetExtent,
            seamKeys: seamKeys
        )
        let surfaces3D = panelGroups(from: triangles).map(\.boundary3D)
        return FoldedPanelPlan(
            panels: panels,
            joinery: joinery,
            materialThickness: materialThickness,
            netOutline: net?.outline,
            foldEdges: net?.foldEdges,
            nets: nets,
            surfaces3D: surfaces3D,
            jointCensus: jointCensus,
            stockCensus: stockCensus,
            leftOutPanels: panelComponents.indices.filter { leftOutComponents.contains(panelComponents[$0]) }
        )
    }

    /// Canonical mesh-edge keys for the user's seam edges, using the same
    /// rounded point-key scheme the panel adjacency uses so a seam edge
    /// matches its mesh edge exactly.
    private static func seamEdgeKeys(for seamEdges: [FoldedSeamEdge]) -> Set<BoundaryEdge> {
        var keys = Set<BoundaryEdge>()
        for seam in seamEdges {
            let ka = pointKey(seam.a)
            let kb = pointKey(seam.b)
            keys.insert(ka < kb ? BoundaryEdge(a: ka, b: kb) : BoundaryEdge(a: kb, b: ka))
        }
        return keys
    }

    private struct TriangleRecord {
        var sourceTriangleIndex: Int
        var vertices: [Vec3]
        var planeKey: String
        var normal: Vec3
        /// The triangle's normal from its vertex order (the model's outside
        /// for a consistently wound mesh), scaled by twice its area.
        var winding: Vec3
    }

    private struct BoundaryEdge: Hashable {
        var a: String
        var b: String
    }

    private static func triangleRecords(from geometry: MeshGeometryData) -> [TriangleRecord] {
        geometry.triangleIndices.chunked(into: 3).enumerated().compactMap { triangleIndex, indices -> TriangleRecord? in
            guard indices.count == 3 else { return nil }
            let vertexIndices = indices.map(Int.init)
            guard vertexIndices.allSatisfy({ geometry.vertices.indices.contains($0) }) else {
                return nil
            }
            let vertices = vertexIndices.map { geometry.vertices[$0] }
            guard let normal = canonicalNormal(a: vertices[0], b: vertices[1], c: vertices[2]) else {
                return nil
            }
            let offset = dot(normal, vertices[0])
            return TriangleRecord(
                sourceTriangleIndex: triangleIndex,
                vertices: vertices,
                planeKey: "\(rounded(normal.x)):\(rounded(normal.y)):\(rounded(normal.z)):\(rounded(offset))",
                normal: normal,
                winding: cross(subtract(vertices[1], vertices[0]), subtract(vertices[2], vertices[0]))
            )
        }
    }

    /// The triangles with their windings made to agree: across every edge two
    /// triangles share, they run it in opposite directions, and each
    /// connected piece of the mesh faces out (encloses a positive volume).
    /// Which side of a panel is the model's outside, and so where its stock
    /// goes, rests on this, and a mesh with some faces wound the wrong way
    /// round would otherwise put their stock outside the model.
    private static func consistentlyWound(_ triangles: [TriangleRecord]) -> [TriangleRecord] {
        let keys = triangles.map { $0.vertices.map(pointKey) }
        // The triangles using each undirected edge, and in which direction.
        var users: [BoundaryEdge: [(triangle: Int, forward: Bool)]] = [:]
        for (index, triangleKeys) in keys.enumerated() {
            for (a, b) in [(triangleKeys[0], triangleKeys[1]), (triangleKeys[1], triangleKeys[2]), (triangleKeys[2], triangleKeys[0])] {
                let edge = a < b ? BoundaryEdge(a: a, b: b) : BoundaryEdge(a: b, b: a)
                users[edge, default: []].append((index, a < b))
            }
        }
        var flip = [Bool](repeating: false, count: triangles.count)
        var seen = [Bool](repeating: false, count: triangles.count)
        var neighbours: [[(other: Int, sameDirection: Bool)]] = Array(repeating: [], count: triangles.count)
        for list in users.values where list.count == 2 {
            let same = list[0].forward == list[1].forward
            neighbours[list[0].triangle].append((list[1].triangle, same))
            neighbours[list[1].triangle].append((list[0].triangle, same))
        }
        var result = triangles
        for start in triangles.indices where !seen[start] {
            seen[start] = true
            var component = [start]
            var queue = [start]
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for (other, same) in neighbours[current] where !seen[other] {
                    seen[other] = true
                    // Two triangles running a shared edge the same way are
                    // wound against each other.
                    flip[other] = flip[current] != same
                    component.append(other)
                    queue.append(other)
                }
            }
            var volume = 0.0
            for index in component {
                let v = triangles[index].vertices
                volume += (flip[index] ? -1 : 1) * dot(v[0], cross(v[1], v[2]))
            }
            for index in component where flip[index] != (volume < 0) {
                let w = triangles[index].winding
                result[index].winding = Vec3(x: -w.x, y: -w.y, z: -w.z)
            }
        }
        return result
    }

    /// The panels' triangles: triangles in one plane, facing the same way,
    /// that are joined edge to edge form one panel (two separate faces in
    /// the same plane, or two faces back to back, are two panels), ordered
    /// by their lowest source-triangle index.
    private static func coplanarComponents(_ triangles: [TriangleRecord]) -> [[TriangleRecord]] {
        var components: [[TriangleRecord]] = []
        let byPlane = Dictionary(grouping: triangles) { triangle in
            "\(triangle.planeKey):\(dot(triangle.winding, triangle.normal) < 0 ? "-" : "+")"
        }
        for group in byPlane.values {
            var parent = Array(group.indices)
            func find(_ index: Int) -> Int {
                var root = index
                while parent[root] != root {
                    parent[root] = parent[parent[root]]
                    root = parent[root]
                }
                return root
            }
            var firstOwner: [BoundaryEdge: Int] = [:]
            for (index, triangle) in group.enumerated() {
                let keys = triangle.vertices.map(pointKey)
                for (a, b) in [(keys[0], keys[1]), (keys[1], keys[2]), (keys[2], keys[0])] {
                    let edge = a < b ? BoundaryEdge(a: a, b: b) : BoundaryEdge(a: b, b: a)
                    if let other = firstOwner[edge] {
                        parent[find(index)] = find(other)
                    } else {
                        firstOwner[edge] = index
                    }
                }
            }
            var byRoot: [Int: [TriangleRecord]] = [:]
            for index in group.indices {
                byRoot[find(index), default: []].append(group[index])
            }
            components.append(contentsOf: byRoot.values)
        }
        return components.sorted { ($0.map(\.sourceTriangleIndex).min() ?? 0) < ($1.map(\.sourceTriangleIndex).min() ?? 0) }
    }

    /// One panel per coplanar component of the mesh that unfolds, and the
    /// index of the component (`coplanarComponents`) each came from.
    private static func groupedCoplanarPanels(from triangles: [TriangleRecord]) -> (panels: [FoldedPanel], components: [Int]) {
        var panels: [FoldedPanel] = []
        var components: [Int] = []
        for (index, component) in coplanarComponents(triangles).enumerated() {
            if let unfolded = panel(from: component) {
                panels.append(unfolded)
                components.append(index)
            }
        }
        return (panels, components)
    }

    private static func panel(from triangles: [TriangleRecord]) -> FoldedPanel? {
        guard let first = triangles.first else {
            return nil
        }
        let boundary = boundaryLoop(for: triangles)
        if boundary.count >= 3,
           let unfolded = unfoldPolygon(boundary, normal: first.normal, sourceTriangleIndex: first.sourceTriangleIndex) {
            return unfolded
        }
        return unfoldTriangle(
            a: first.vertices[0],
            b: first.vertices[1],
            c: first.vertices[2],
            sourceTriangleIndex: first.sourceTriangleIndex
        )
    }

    // MARK: - Spanning-tree (hinge) net assembly
    //
    // Produces ONE connected outline + the interior fold-edge segments by
    // unfolding the coplanar panel groups about their shared 3D mesh edges, so
    // every shared edge becomes coincident (edge-to-edge) in 2D: each child
    // panel is merged into its parent across the shared fold edge, walking a
    // spanning tree of the panel adjacency graph. It is independent of the
    // per-panel `panels` array the other exporters consume.
    //
    // Coordinates are kept at true mm (50-unit cube faces); NO page-fit scale
    // or skew is introduced.

    /// A coplanar panel group with its ordered 3D boundary polygon and a stable
    /// ordering cost (lowest source-triangle index — deterministic for the
    /// congruent-square cube where all costs would otherwise tie).
    private struct PanelGroup {
        var groupIndex: Int
        /// The coplanar component (`coplanarComponents`) it was built from.
        var component: Int
        var cost: Int
        var normal: Vec3
        var boundary3D: [Vec3]
        var boundaryKeys: [String]
        /// The direction from the panel's outside face into the stock (the
        /// stock lies inside the model surface).
        var inward: Vec3
        /// The panel's triangles on the model.
        var triangles: [[Vec3]]
    }

    /// An undirected adjacency between two panel groups that share a 3D mesh
    /// edge, with the two endpoint point-keys of that shared edge.
    private struct PanelAdjacency {
        var other: Int
        var edgeKeyA: String
        var edgeKeyB: String
    }

    private struct AssembledNet {
        var outline: [Vec2]
        var foldEdges: [FoldedNetFoldEdge]
    }

    private static func assembleNet(
        from triangles: [TriangleRecord],
        seamKeys: Set<BoundaryEdge> = []
    ) -> AssembledNet? {
        let groups = panelGroups(from: triangles)
        guard groups.count >= 2 else {
            return nil
        }

        let adjacency = panelAdjacency(groups: groups, seamKeys: seamKeys)
        // Spanning tree must reach every panel; otherwise the net is not a
        // single connected developable surface and we leave the DXF fallback.
        guard let tree = spanningTree(groupCount: groups.count, adjacency: adjacency) else {
            return nil
        }

        // 1. Local isometric 2D embedding of each panel's boundary polygon,
        //    keyed by point-key so shared edges can be aligned by key.
        var localByGroup: [[String: Vec2]] = Array(repeating: [:], count: groups.count)
        for group in groups {
            guard let local = localEmbedding(of: group) else {
                return nil
            }
            localByGroup[group.groupIndex] = local
        }

        // 2. Place panels in world-2D by hinge-unfolding along the spanning
        //    tree: the root is placed directly; each child is rigidly aligned
        //    so its copy of the shared edge coincides with the parent's.
        var worldByGroup: [[String: Vec2]] = Array(repeating: [:], count: groups.count)
        var placed = [Bool](repeating: false, count: groups.count)
        worldByGroup[tree.root] = localByGroup[tree.root]
        placed[tree.root] = true

        for childIndex in tree.order {
            guard let parentEdge = tree.parentEdge[childIndex] else {
                continue
            }
            let parentWorld = worldByGroup[parentEdge.parent]
            let childLocal = localByGroup[childIndex]
            guard
                let parentA = parentWorld[parentEdge.edgeKeyA],
                let parentB = parentWorld[parentEdge.edgeKeyB],
                let childA = childLocal[parentEdge.edgeKeyA],
                let childB = childLocal[parentEdge.edgeKeyB]
            else {
                return nil
            }
            guard let placedChild = placeChild(
                childLocal: childLocal,
                childEdgeStart: childA,
                childEdgeEnd: childB,
                parentEdgeStart: parentA,
                parentEdgeEnd: parentB,
                parentInteriorCentroid: centroid(of: parentWorld)
            ) else {
                return nil
            }
            worldByGroup[childIndex] = placedChild
            placed[childIndex] = true
        }

        guard placed.allSatisfy({ $0 }) else {
            return nil
        }

        // 3. Classify panel edges. A panel edge is a FOLD (hinge) edge iff it is
        //    a spanning-tree edge — only those are actually folded; the rest of
        //    the cube's shared mesh edges become CUTS in the net and form its
        //    outer boundary. (In 3D every cube edge is shared by two faces, so
        //    mesh-key adjacency over-counts folds; the tree is the ground truth
        //    for which 5 are creases.)
        var foldEdgeKeys = Set<BoundaryEdge>()
        for (_, parentEdge) in tree.parentEdge {
            let a = parentEdge.edgeKeyA
            let b = parentEdge.edgeKeyB
            foldEdgeKeys.insert(a < b ? BoundaryEdge(a: a, b: b) : BoundaryEdge(a: b, b: a))
        }

        // Outer-boundary segments: every panel boundary edge that is NOT a tree
        // fold edge. Each cut cube-edge contributes TWO such segments (one per
        // incident face), placed at possibly-different world positions because
        // the two faces unfolded along different tree paths — so the outline is
        // chained by world POSITION (epsilon), not by mesh-vertex key.
        var outerSegments: [(a: Vec2, b: Vec2)] = []
        for group in groups {
            let world = worldByGroup[group.groupIndex]
            let keys = group.boundaryKeys
            for index in keys.indices {
                let ka = keys[index]
                let kb = keys[(index + 1) % keys.count]
                let canonical = ka < kb ? BoundaryEdge(a: ka, b: kb) : BoundaryEdge(a: kb, b: ka)
                if foldEdgeKeys.contains(canonical) {
                    continue
                }
                guard let pa = world[ka], let pb = world[kb] else {
                    continue
                }
                outerSegments.append((a: pa, b: pb))
            }
        }

        guard let outline = chainOuterSegments(outerSegments) else {
            return nil
        }

        // Fold-line segments: the world-2D position of each tree fold edge,
        // taken from the child panel's placed copy (coincident with the parent).
        var foldEdges: [FoldedNetFoldEdge] = []
        for childIndex in tree.order {
            guard let parentEdge = tree.parentEdge[childIndex] else {
                continue
            }
            let world = worldByGroup[childIndex]
            guard let pa = world[parentEdge.edgeKeyA], let pb = world[parentEdge.edgeKeyB] else {
                continue
            }
            foldEdges.append(FoldedNetFoldEdge(start: pa, end: pb))
        }
        guard !foldEdges.isEmpty else {
            return nil
        }

        return AssembledNet(outline: outline, foldEdges: foldEdges)
    }

    // MARK: - Multi-net (spanning forest) assembly
    //
    // Generalizes the single-net hinge unfold to arbitrary meshes: panels are
    // hinge-unfolded greedily (same placeChild math), and a panel that would
    // OVERLAP material already placed in the current net — or push the net
    // past the caller's usable sheet extent — is deferred and seeds/joins a
    // later net. Every panel lands in exactly one net, so non-developable
    // meshes split into several flat cuttable pieces instead of degrading to
    // the loose per-panel scatter: panel sets split wherever unfolding would
    // overlap.

    private struct PlacedPanel {
        var groupIndex: Int
        var polygon: [Vec2]
        var world: [String: Vec2]
    }

    /// Which copy of a mating cut edge a segment is: the male copy is cut
    /// back clear of the female panel's stock and gets the protruding
    /// geometry (tab, finger, neck); the female copy keeps its edge on the
    /// model surface and gets the receiving slot (with its lug) or notch.
    /// Symmetric joinery types (Ticked, Laced) decorate both copies alike.
    enum JoineryRole {
        case male
        case female
    }

    private struct NetAccumulator {
        var placed: [PlacedPanel] = []
        var slotByGroup: [Int: Int] = [:]
        var foldEdges: [FoldedNetFoldEdge] = []
        /// For each fold edge, the two placed panels (indices into `placed`)
        /// it joins.
        var foldPanels: [(Int, Int)] = []
        var treeEdgeKeys = Set<BoundaryEdge>()
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        mutating func include(_ polygon: [Vec2]) {
            for point in polygon {
                minX = Swift.min(minX, point.x)
                minY = Swift.min(minY, point.y)
                maxX = Swift.max(maxX, point.x)
                maxY = Swift.max(maxY, point.y)
            }
        }

        func extentWith(_ polygon: [Vec2]) -> (width: Double, height: Double) {
            var lowX = minX, lowY = minY, highX = maxX, highY = maxY
            for point in polygon {
                lowX = Swift.min(lowX, point.x)
                lowY = Swift.min(lowY, point.y)
                highX = Swift.max(highX, point.x)
                highY = Swift.max(highY, point.y)
            }
            return (highX - lowX, highY - lowY)
        }
    }

    private static func assembleNets(
        from triangles: [TriangleRecord],
        joinery: JoineryParameters,
        materialThickness: Double,
        slotClearance: Double,
        maxExtent: Vec2?,
        seamKeys: Set<BoundaryEdge> = []
    ) -> (nets: [FoldedNet], census: FoldedJointCensus?, stock: FoldedStockCensus, leftOutComponents: Set<Int>) {
        let groups = panelGroups(from: triangles)
        guard !groups.isEmpty else {
            return ([], nil, FoldedStockCensus(), [])
        }
        let adjacency = panelAdjacency(groups: groups, seamKeys: seamKeys)
        let locals: [[String: Vec2]?] = groups.map(localEmbedding)

        var assigned = [Bool](repeating: false, count: groups.count)
        var accumulators: [NetAccumulator] = []

        while let rootIndex = assigned.firstIndex(of: false) {
            assigned[rootIndex] = true
            var net = NetAccumulator()

            guard let rootLocal = locals[rootIndex] else {
                // No valid plane frame even after the fallback axes: the
                // panel is sub-tolerance dust (every boundary edge < 1e-7 mm)
                // with no physical material to cut. Drop it.
                continue
            }

            let rootPolygon = orderedWorldPolygon(group: groups[rootIndex], world: rootLocal)
            net.placed.append(PlacedPanel(groupIndex: rootIndex, polygon: rootPolygon, world: rootLocal))
            net.slotByGroup[rootIndex] = 0
            net.include(rootPolygon)

            // Each placement appends that panel's (pre-sorted) adjacency
            // list once, so the queue is bounded by 2×edge-count — a child
            // that fails against one parent is retried automatically when a
            // different neighbouring panel lands later in this net.
            var queue: [(parent: Int, adj: PanelAdjacency)] = adjacency[rootIndex].map { (rootIndex, $0) }
            var head = 0
            while head < queue.count {
                let (parentIndex, adj) = queue[head]
                head += 1
                let childIndex = adj.other
                guard !assigned[childIndex], let childLocal = locals[childIndex] else {
                    continue
                }
                guard let parentSlot = net.slotByGroup[parentIndex] else {
                    continue
                }
                let parentWorld = net.placed[parentSlot].world
                guard
                    let parentA = parentWorld[adj.edgeKeyA],
                    let parentB = parentWorld[adj.edgeKeyB],
                    let childA = childLocal[adj.edgeKeyA],
                    let childB = childLocal[adj.edgeKeyB],
                    let placedWorld = placeChild(
                        childLocal: childLocal,
                        childEdgeStart: childA,
                        childEdgeEnd: childB,
                        parentEdgeStart: parentA,
                        parentEdgeEnd: parentB,
                        parentInteriorCentroid: centroid(of: parentWorld)
                    )
                else {
                    continue
                }
                let polygon = orderedWorldPolygon(group: groups[childIndex], world: placedWorld)

                var collides = false
                for placed in net.placed {
                    if polygonsOverlap(polygon, placed.polygon) {
                        collides = true
                        break
                    }
                }
                if collides {
                    continue
                }
                if let maxExtent {
                    let extent = net.extentWith(polygon)
                    if extent.width > maxExtent.x + 1.0e-6 || extent.height > maxExtent.y + 1.0e-6 {
                        continue
                    }
                }

                assigned[childIndex] = true
                net.slotByGroup[childIndex] = net.placed.count
                net.foldPanels.append((parentSlot, net.placed.count))
                net.placed.append(PlacedPanel(groupIndex: childIndex, polygon: polygon, world: placedWorld))
                net.include(polygon)
                net.foldEdges.append(FoldedNetFoldEdge(start: parentA, end: parentB))
                let canonical = adj.edgeKeyA < adj.edgeKeyB
                    ? BoundaryEdge(a: adj.edgeKeyA, b: adj.edgeKeyB)
                    : BoundaryEdge(a: adj.edgeKeyB, b: adj.edgeKeyA)
                net.treeEdgeKeys.insert(canonical)
                queue.append(contentsOf: adjacency[childIndex].map { (childIndex, $0) })
            }

            accumulators.append(net)
        }

        return finalizeNets(
            accumulators,
            groups: groups,
            joinery: joinery,
            materialThickness: materialThickness,
            slotClearance: slotClearance,
            maxExtent: maxExtent
        )
    }

    private static func orderedWorldPolygon(group: PanelGroup, world: [String: Vec2]) -> [Vec2] {
        var polygon = group.boundaryKeys.compactMap { world[$0] }
        if signedArea(polygon) < 0 {
            polygon.reverse()
        }
        return polygon
    }

    // MARK: - Stock and joints
    //
    // Each panel is a piece of stock `materialThickness` deep, its net on
    // the model surface and the stock behind it, inside the model. Panels
    // joined by a fold line are one piece bent there. Where the net is cut
    // (a seam), the two pieces would pass into each other near the seam, so
    // one copy of every cut edge (the male) is cut back until its stock
    // clears the other (a butt joint). Pieces that meet only at a corner of
    // the model (a pyramid's apex) and still pass into each other there have
    // the corner of one cut away. The joints are then built around the cut
    // back edges (FoldedJoineryGeometry), and each net's outline is the
    // union of its cut-back panels and joint features.

    /// A placed panel, with what the stock and the joints need to know
    /// about it.
    private struct NetPanel {
        var net: Int
        var slot: Int
        var group: Int
        /// The placed polygon, counter-clockwise, and the mesh vertex key of
        /// each corner.
        var polygon: [Vec2]
        var keys: [String]
        var frame: PartPlaneFrame?
        var inward: Vec3
    }

    /// One copy of a cut edge: edge `edge` of panel `panel`, from `start` to
    /// `end` with the panel on the left.
    private struct EdgeCopy {
        var panel: Int
        var edge: Int
        var start: Vec2
        var end: Vec2

        var length: Double {
            FoldedPanelPlanner.length2(FoldedPanelPlanner.subtract2(end, start))
        }
    }

    /// The two copies of a cut model edge, and how their stock meets.
    private struct MatingPair {
        var male: EdgeCopy
        var female: EdgeCopy
        var band: FoldedSeamBand?
        var planeAngle: Double?
    }

    /// One copy's joint features, placed in its net.
    private struct PlacedCuts {
        var outward: [[Vec2]] = []
        var inward: [[Vec2]] = []
        var holes: [[Vec2]] = []

        var all: [[Vec2]] { outward + inward + holes }

        mutating func add(_ other: PlacedCuts) {
            outward += other.outward
            inward += other.inward
            holes += other.holes
        }
    }

    /// Why a mating pair has no joint, before its features are tried.
    private enum JointGate {
        case tryJoint
        case tooShort
        case tooFlat
        case insideCorner
        case none
    }

    /// The least material, in mm, left between a joint feature that stands
    /// out of a panel and anything else in its net, so a cut separates them.
    private static let featureGap = 0.5

    /// How far apart, in mm, two pieces of a net may have been rounded along
    /// an edge they share and still be joined into one outline.
    private static let joinTolerance = 1.0e-3

    /// The thinnest web of stock, in mm, a net keeps: about a cut's width.
    /// Narrower webs (where cut-back panels nearly meet) are cut away.
    private static let thinnestWeb = 0.2

    /// Stock, joints and outlines for every accumulated net. Joinery pairs
    /// mate across nets, so this runs after the forest is complete. Also
    /// counts the cut edges that got the joint and why the others stay plain
    /// (nil when the joint type decorates no edges).
    private static func finalizeNets(
        _ accumulators: [NetAccumulator],
        groups: [PanelGroup],
        joinery: JoineryParameters,
        materialThickness: Double,
        slotClearance: Double,
        maxExtent: Vec2?
    ) -> (nets: [FoldedNet], census: FoldedJointCensus?, stock: FoldedStockCensus, leftOutComponents: Set<Int>) {
        let populated = accumulators.filter { !$0.placed.isEmpty }
        let geometry = FoldedJoineryGeometry(parameters: joinery.sanitized, thickness: materialThickness, slotClearance: slotClearance)
        let thickness = max(materialThickness, 0)

        // Every placed panel, numbered across the nets.
        var panels: [NetPanel] = []
        var panelIndex: [[Int]] = []
        for (netIndex, net) in populated.enumerated() {
            var row: [Int] = []
            for (slot, placed) in net.placed.enumerated() {
                let group = groups[placed.groupIndex]
                var keys = group.boundaryKeys.filter { placed.world[$0] != nil }
                var polygon = keys.compactMap { placed.world[$0] }
                if signedArea(polygon) < 0 {
                    polygon.reverse()
                    keys.reverse()
                }
                row.append(panels.count)
                panels.append(NetPanel(
                    net: netIndex,
                    slot: slot,
                    group: placed.groupIndex,
                    polygon: polygon,
                    keys: keys,
                    frame: panelFrame(group: group, world: placed.world),
                    inward: group.inward
                ))
            }
            panelIndex.append(row)
        }

        // Panels joined by fold lines: one piece of stock, bent.
        var hinged = Set<[Int]>()
        var hingeSegments: [(a: Int, b: Int, segment: FoldedNetFoldEdge)] = []
        for (netIndex, net) in populated.enumerated() {
            for (index, pair) in net.foldPanels.enumerated() where net.foldEdges.indices.contains(index) {
                let a = panelIndex[netIndex][pair.0]
                let b = panelIndex[netIndex][pair.1]
                hinged.insert([min(a, b), max(a, b)])
                hingeSegments.append((a, b, net.foldEdges[index]))
            }
        }

        // The cut edges: every panel edge that is not a fold of its net.
        var copies: [BoundaryEdge: [EdgeCopy]] = [:]
        for (index, panel) in panels.enumerated() {
            let folds = populated[panel.net].treeEdgeKeys
            for edge in panel.keys.indices {
                let ka = panel.keys[edge]
                let kb = panel.keys[(edge + 1) % panel.keys.count]
                let canonical = ka < kb ? BoundaryEdge(a: ka, b: kb) : BoundaryEdge(a: kb, b: ka)
                guard !folds.contains(canonical) else {
                    continue
                }
                copies[canonical, default: []].append(EdgeCopy(
                    panel: index,
                    edge: edge,
                    start: panel.polygon[edge],
                    end: panel.polygon[(edge + 1) % panel.polygon.count]
                ))
            }
        }

        // Mating pairs: a model edge cut into exactly two copies. The first
        // copy (in net, then panel order) is male.
        var pairs: [MatingPair] = []
        for (_, list) in copies.sorted(by: { $0.key.a < $1.key.a || ($0.key.a == $1.key.a && $0.key.b < $1.key.b) }) where list.count == 2 {
            let male = list[0]
            let female = list[1]
            pairs.append(MatingPair(
                male: male,
                female: female,
                band: seamBand(male: male, female: female, panels: panels, thickness: thickness),
                planeAngle: planeAngle(between: groups[panels[male.panel].group].normal, and: groups[panels[female.panel].group].normal)
            ))
        }

        // Which pairs try the joint, and how far each male copy is cut back.
        let gates: [JointGate] = pairs.map { pair in
            guard geometry.decoratesEdges else {
                return .none
            }
            guard geometry.featureWidth * 3 < pair.male.length, geometry.featureWidth * 3 < pair.female.length else {
                return .tooShort
            }
            if geometry.needsSteepSeam {
                guard let band = pair.band, (pair.planeAngle ?? Double.pi / 2) >= FoldedJoineryGeometry.flattestSlotAngle else {
                    return .tooFlat
                }
                if geometry.family == .throughNotch, band.femaleFar <= 1.0e-6 {
                    return .insideCorner
                }
            }
            return .tryJoint
        }
        var trims: [Double] = pairs.indices.map { index in
            guard let band = pairs[index].band else {
                return 0
            }
            return gates[index] == .tryJoint ? geometry.maleTrim(band: band) : band.plainTrim
        }

        // Pieces whose stock still passes into each other where no seam's
        // cut-back clears it (at a corner of the model, past the ends of a
        // seam, across a hollow): that part of one is cut away, the male
        // copy's for a seam's two panels, else the later panel's.
        var (trimmed, liveHinges) = cutBackPanels(panels: panels, pairs: pairs, trims: trims, hinges: hingeSegments, thickness: thickness)
        // Where the cut-back pieces' stock is, for joint features to clear.
        let conflicts = StockConflicts(panels: panels, shapes: trimmed, thickness: thickness)

        // The joints, in model-edge order, where both halves fit.
        var census = FoldedJointCensus()
        var accepted: [Int: (male: PlacedCuts, female: PlacedCuts, maleBases: [FoldedJoineryGeometry.LocalFeatures], frames: [FoldedEdgeFrame])] = [:]
        var taken: [PlacedCuts] = Array(repeating: PlacedCuts(), count: populated.count)
        // Each net's extent with the features placed so far: a joint whose
        // features would push its net past the sheet does not fit.
        var netBoxes: [(minX: Double, minY: Double, maxX: Double, maxY: Double)] = populated.map {
            ($0.minX, $0.minY, $0.maxX, $0.maxY)
        }
        func fitsSheet(_ cuts: PlacedCuts, net: Int, also extra: PlacedCuts? = nil) -> Bool {
            guard let maxExtent else {
                return true
            }
            var box = netBoxes[net]
            for point in (cuts.outward + (extra?.outward ?? [])).flatMap({ $0 }) {
                box = (min(box.minX, point.x), min(box.minY, point.y), max(box.maxX, point.x), max(box.maxY, point.y))
            }
            return box.maxX - box.minX <= maxExtent.x + 1.0e-6 && box.maxY - box.minY <= maxExtent.y + 1.0e-6
        }
        func grow(_ net: Int, by cuts: PlacedCuts) {
            for point in cuts.outward.flatMap({ $0 }) {
                let box = netBoxes[net]
                netBoxes[net] = (min(box.minX, point.x), min(box.minY, point.y), max(box.maxX, point.x), max(box.maxY, point.y))
            }
        }
        for (index, pair) in pairs.enumerated() where gates[index] != .none {
            census.cutEdges += 1
            switch gates[index] {
            case .tooShort:
                census.tooShort += 1
                continue
            case .tooFlat:
                census.tooFlat += 1
                continue
            case .insideCorner:
                census.insideCorner += 1
                continue
            case .none, .tryJoint:
                break
            }
            guard let band = pair.band,
                  let maleFrame = FoldedEdgeFrame(start: pair.male.start, end: pair.male.end),
                  let femaleFrame = FoldedEdgeFrame(start: pair.female.start, end: pair.female.end) else {
                census.noRoom += 1
                continue
            }
            let maleLocal = geometry.features(role: .male, edgeLength: maleFrame.length, band: band, trim: trims[index])
            let femaleLocal = geometry.features(role: .female, edgeLength: femaleFrame.length, band: band, trim: 0)
            let maleCuts = place(maleLocal, frame: maleFrame)
            let femaleCuts = place(femaleLocal, frame: femaleFrame)
            let maleNet = panels[pair.male.panel].net
            let femaleNet = panels[pair.female.panel].net
            var femaleTaken = taken[femaleNet]
            if femaleNet == maleNet {
                femaleTaken.add(maleCuts)
            }
            guard !maleLocal.isEmpty || !femaleLocal.isEmpty,
                  maleNet == femaleNet
                      ? fitsSheet(maleCuts, net: maleNet, also: femaleCuts)
                      : fitsSheet(maleCuts, net: maleNet) && fitsSheet(femaleCuts, net: femaleNet),
                  jointFits(
                      maleLocal, cuts: maleCuts, frame: maleFrame, edgeLine: -trims[index],
                      panel: pair.male.panel, partner: pair.female.panel, trimmed: trimmed, panels: panels,
                      netPanels: panelIndex[maleNet], taken: taken[maleNet], conflicts: conflicts,
                      bridge: geometry.slotBridge
                  ),
                  jointFits(
                      femaleLocal, cuts: femaleCuts, frame: femaleFrame, edgeLine: 0,
                      panel: pair.female.panel, partner: pair.male.panel, trimmed: trimmed, panels: panels,
                      netPanels: panelIndex[femaleNet], taken: femaleTaken, conflicts: conflicts,
                      bridge: geometry.slotBridge
                  ) else {
                census.noRoom += 1
                continue
            }
            census.joined += 1
            taken[maleNet].add(maleCuts)
            taken[femaleNet].add(femaleCuts)
            grow(maleNet, by: maleCuts)
            grow(femaleNet, by: femaleCuts)
            accepted[index] = (maleCuts, femaleCuts, [maleLocal, femaleLocal], [maleFrame, femaleFrame])
        }

        // A pair left plain needs only the plain cut-back; its panel grows
        // back to it. A grown-back panel only adds stock near its own seam,
        // so the joints already placed still fit, but check their bases.
        for index in pairs.indices where accepted[index] == nil {
            if let band = pairs[index].band, trims[index] > band.plainTrim + 1.0e-12 {
                trims[index] = band.plainTrim
            }
        }

        // The nets' outlines. A fold the outline does not keep (the stock
        // left too little either side of it) joins nothing after all: its
        // two panels must then keep clear of each other like any two
        // pieces, so the panels are cut back again without it.
        var nets: [FoldedNet] = []
        var brokenHinges = Set<[Int]>()
        for _ in 0..<3 {
            (trimmed, liveHinges) = cutBackPanels(
                panels: panels, pairs: pairs, trims: trims,
                hinges: hingeSegments.filter { !brokenHinges.contains([min($0.a, $0.b), max($0.a, $0.b)]) },
                thickness: thickness
            )
            for index in accepted.keys.sorted() {
                guard let joint = accepted[index] else {
                    continue
                }
                let pair = pairs[index]
                let maleOK = basesOnPanel(joint.maleBases[0], frame: joint.frames[0], polygon: trimmed[pair.male.panel])
                    && cutsInPanel(joint.maleBases[0], frame: joint.frames[0], edgeLine: -trims[index], polygon: trimmed[pair.male.panel], others: [], bridge: geometry.slotBridge)
                let femaleOK = basesOnPanel(joint.maleBases[1], frame: joint.frames[1], polygon: trimmed[pair.female.panel])
                    && cutsInPanel(joint.maleBases[1], frame: joint.frames[1], edgeLine: 0, polygon: trimmed[pair.female.panel], others: [], bridge: geometry.slotBridge)
                if !maleOK || !femaleOK {
                    accepted[index] = nil
                    census.joined -= 1
                    census.noRoom += 1
                }
            }

            // The features each panel carries, and each net's cuts.
            var outwardByPanel: [[[Vec2]]] = Array(repeating: [], count: panels.count)
            var inwardByNet: [[[Vec2]]] = Array(repeating: [], count: populated.count)
            var holesByNet: [[[Vec2]]] = Array(repeating: [], count: populated.count)
            for index in accepted.keys.sorted() {
                guard let joint = accepted[index] else {
                    continue
                }
                let pair = pairs[index]
                outwardByPanel[pair.male.panel] += joint.male.outward
                outwardByPanel[pair.female.panel] += joint.female.outward
                inwardByNet[panels[pair.male.panel].net] += joint.male.inward
                inwardByNet[panels[pair.female.panel].net] += joint.female.inward
                holesByNet[panels[pair.male.panel].net] += joint.male.holes
                holesByNet[panels[pair.female.panel].net] += joint.female.holes
            }

            nets = []
            var dropped = Set<[Int]>()
            for netIndex in populated.indices {
                let assembled = assembleOutlines(
                    members: panelIndex[netIndex],
                    panels: panels,
                    trimmed: trimmed,
                    features: outwardByPanel,
                    notches: inwardByNet[netIndex],
                    holes: holesByNet[netIndex],
                    hinges: hingeSegments.filter { panels[$0.a].net == netIndex && liveHinges.contains([min($0.a, $0.b), max($0.a, $0.b)]) }
                )
                nets += assembled.nets
                dropped.formUnion(assembled.droppedHinges)
            }
            // Every hole keeps tickRadius of stock to the finished outline;
            // a joint whose hole ended up nearer (the outline steps in beside
            // it where a neighbouring panel was cut back) is left out.
            var crowded: [Int] = []
            for index in accepted.keys.sorted() {
                guard let joint = accepted[index] else {
                    continue
                }
                for hole in joint.male.holes + joint.female.holes {
                    guard let probe = interiorPoint(of: hole),
                          let net = nets.first(where: { pointInPolygon(probe, $0.outline) }) else {
                        continue
                    }
                    let edges = loopEdges(net.outline) + net.outlineHoles.flatMap(loopEdges)
                    if clearance([hole], edges) < geometry.slotBridge - 1.0e-6 {
                        crowded.append(index)
                        break
                    }
                }
            }
            for index in crowded {
                accepted[index] = nil
                census.joined -= 1
                census.noRoom += 1
                if let band = pairs[index].band {
                    trims[index] = band.plainTrim
                }
            }
            guard !dropped.isEmpty || !crowded.isEmpty else {
                break
            }
            brokenHinges.formUnion(dropped)
        }
        var stock = FoldedStockCensus(panels: panels.count)
        var leftOutComponents = Set<Int>()
        for (index, panel) in panels.enumerated() {
            let kept = trimmed[index].count >= 3 ? abs(signedArea(trimmed[index])) : 0
            if kept <= 1.0e-9 {
                stock.leftOut += 1
                leftOutComponents.insert(groups[panel.group].component)
            } else if kept < 0.5 * abs(signedArea(panel.polygon)) {
                stock.cutBackByHalf += 1
            }
        }
        return (nets, geometry.decoratesEdges ? census : nil, stock, leftOutComponents)
    }

    /// How the stock of a mating pair's two panels meets, folded up.
    private static func seamBand(male: EdgeCopy, female: EdgeCopy, panels: [NetPanel], thickness: Double) -> FoldedSeamBand? {
        guard let maleFrame = panels[male.panel].frame,
              let femaleFrame = panels[female.panel].frame,
              let maleInPlane = inPlaneInward(of: male, frame: maleFrame),
              let femaleInPlane = inPlaneInward(of: female, frame: femaleFrame) else {
            return nil
        }
        return FoldedSeamBand(
            maleInPlane: maleInPlane,
            maleInward: panels[male.panel].inward,
            femaleInPlane: femaleInPlane,
            femaleInward: panels[female.panel].inward,
            thickness: thickness
        )
    }

    /// The model direction from a copy of an edge into its panel, across the
    /// edge.
    private static func inPlaneInward(of copy: EdgeCopy, frame: PartPlaneFrame) -> Vec3? {
        let direction = subtract2(copy.end, copy.start)
        let length = length2(direction)
        guard length > 1.0e-12 else {
            return nil
        }
        let left = Vec2(x: -direction.y / length, y: direction.x / length)
        return normalized(Vec3(
            x: frame.xAxis.x * left.x + frame.yAxis.x * left.y,
            y: frame.xAxis.y * left.x + frame.yAxis.y * left.y,
            z: frame.xAxis.z * left.x + frame.yAxis.z * left.y
        ))
    }

    /// Each panel cut back: the strip along every male copy's edge, as deep
    /// as its trim, then the parts of its stock that still pass into another
    /// piece's (`cornerConflicts`). A panel the cuts leave no material in
    /// comes back empty. Panels joined by a fold whose fold the cuts take
    /// away are two pieces after all, which must keep clear of each other
    /// too; the hinges that keep a fold come back with the panels.
    private static func cutBackPanels(
        panels: [NetPanel],
        pairs: [MatingPair],
        trims: [Double],
        hinges: [(a: Int, b: Int, segment: FoldedNetFoldEdge)],
        thickness: Double
    ) -> (panels: [[Vec2]], hinged: Set<[Int]>) {
        var strips: [Int: [[Vec2]]] = [:]
        for (index, pair) in pairs.enumerated() where trims[index] > 1.0e-9 {
            if let strip = trimStrip(polygon: panels[pair.male.panel].polygon, edge: pair.male.edge, depth: trims[index]) {
                strips[pair.male.panel, default: []].append(strip)
            }
        }
        let seamCut: [[Vec2]] = panels.indices.map { index in
            let polygon = panels[index].polygon
            guard let cuts = strips[index], !cuts.isEmpty else {
                return polygon
            }
            guard let loops = PlanarBoolean.subtracting(cuts, from: [polygon]) else {
                return polygon
            }
            return largestOuterLoop(loops) ?? []
        }
        let conflicts = StockConflicts(panels: panels, shapes: seamCut, thickness: thickness)
        var hinged = Set(hinges.map { [min($0.a, $0.b), max($0.a, $0.b)] })
        var result = seamCut
        for _ in 0..<3 {
            let cornerCuts = cornerConflicts(panels: panels, pairs: pairs, hinged: hinged, conflicts: conflicts)
            result = seamCut.indices.map { index in
                let shape = seamCut[index]
                guard let corners = cornerCuts[index], !corners.isEmpty, shape.count >= 3 else {
                    return shape
                }
                guard let loops = PlanarBoolean.subtracting(corners, from: [shape]) else {
                    return shape
                }
                // A panel whose stock is all where other pieces' stock already
                // is comes back empty: it is left out (`FoldedStockCensus`).
                // Stock cut away inside a panel leaves a hole in it.
                let after = largestOuterLoopKeepingHoles(loops) ?? []
                return abs(signedArea(shape)) - abs(signedArea(after)) > 1.0e-6 ? after : shape
            }.map(withoutThinWebs)
            // A fold too short to hold, or one the cuts took away, joins
            // nothing.
            let broken = hinges.filter { hinge in
                let key = [min(hinge.a, hinge.b), max(hinge.a, hinge.b)]
                guard hinged.contains(key) else {
                    return false
                }
                let kept = commonCoverage(hinge.segment, panels[hinge.a].polygon, result[hinge.a], panels[hinge.b].polygon, result[hinge.b])
                return kept.reduce(0) { $0 + length2(subtract2($1.end, $1.start)) } < thinnestWeb
            }
            guard !broken.isEmpty else {
                break
            }
            for hinge in broken {
                hinged.remove([min(hinge.a, hinge.b), max(hinge.a, hinge.b)])
            }
        }
        return (result, hinged)
    }

    /// A cut-back panel without the parts of it narrower than `thinnestWeb`
    /// (empty when that is all of it).
    private static func withoutThinWebs(_ shape: [Vec2]) -> [Vec2] {
        guard shape.count >= 3 else {
            return shape
        }
        guard let loops = PlanarBoolean.joining([shape], closingBy: 0, openingBy: thinnestWeb / 2) else {
            return shape
        }
        return largestOuterLoop(loops) ?? []
    }

    /// The strip of a panel within `depth` of one of its edges: between the
    /// edge and its offset into the panel, ended by the lines of the two
    /// neighbouring edges (or square across where a neighbour runs on in
    /// line).
    private static func trimStrip(polygon: [Vec2], edge: Int, depth: Double) -> [Vec2]? {
        let count = polygon.count
        guard count >= 3 else {
            return nil
        }
        let a = polygon[edge]
        let b = polygon[(edge + 1) % count]
        let previous = polygon[(edge - 1 + count) % count]
        let next = polygon[(edge + 2) % count]
        let direction = subtract2(b, a)
        let length = length2(direction)
        guard length > 1.0e-12 else {
            return nil
        }
        let unit = Vec2(x: direction.x / length, y: direction.y / length)
        let inward = Vec2(x: -unit.y, y: unit.x)
        // The strip reaches a hair past the panel's edges, so cutting it
        // away leaves no sliver along them.
        let margin = stripMargin
        func pushedOut(_ p: Vec2, _ q: Vec2) -> Vec2 {
            // `p` moved off the line p→q (the panel's neighbouring edge, run
            // with the panel on its left) to the panel's outside.
            let d = subtract2(q, p)
            let l = length2(d)
            guard l > 1.0e-12 else { return p }
            return Vec2(x: p.x + d.y / l * margin, y: p.y - d.x / l * margin)
        }
        let edgeA = Vec2(x: a.x - inward.x * margin, y: a.y - inward.y * margin)
        let edgeB = Vec2(x: b.x - inward.x * margin, y: b.y - inward.y * margin)
        let offsetA = Vec2(x: a.x + inward.x * depth, y: a.y + inward.y * depth)
        let offsetB = Vec2(x: b.x + inward.x * depth, y: b.y + inward.y * depth)
        let previousOut = pushedOut(previous, a)
        let nextOut = pushedOut(b, next)
        let endA = lineIntersection(offsetA, unit, previousOut, subtract2(a, previous)) ?? Vec2(x: offsetA.x - unit.x * margin, y: offsetA.y - unit.y * margin)
        let endB = lineIntersection(offsetB, unit, nextOut, subtract2(next, b)) ?? Vec2(x: offsetB.x + unit.x * margin, y: offsetB.y + unit.y * margin)
        let baseA = lineIntersection(edgeA, unit, previousOut, subtract2(a, previous)) ?? Vec2(x: edgeA.x - unit.x * margin, y: edgeA.y - unit.y * margin)
        let baseB = lineIntersection(edgeB, unit, nextOut, subtract2(next, b)) ?? Vec2(x: edgeB.x + unit.x * margin, y: edgeB.y + unit.y * margin)
        return [baseA, baseB, endB, endA]
    }

    /// How far, in mm, a strip cut back from a panel reaches past the
    /// panel's edges.
    private static let stripMargin = 1.0e-5

    /// How far, in mm, one piece of stock may reach into another and still
    /// count as only touching it.
    private static let touchTolerance = 1.0e-6

    /// Where the line through `p` along `r` meets the line through `q` along
    /// `s`, or nil when they run (nearly) parallel.
    private static func lineIntersection(_ p: Vec2, _ r: Vec2, _ q: Vec2, _ s: Vec2) -> Vec2? {
        let denominator = r.x * s.y - r.y * s.x
        let scale = length2(r) * length2(s)
        guard scale > 1.0e-18, abs(denominator) > 1.0e-9 * scale else {
            return nil
        }
        let qp = subtract2(q, p)
        let t = (qp.x * s.y - qp.y * s.x) / denominator
        guard t.isFinite, abs(t) < 1.0e6 else {
            return nil
        }
        return Vec2(x: p.x + r.x * t, y: p.y + r.y * t)
    }

    /// The outer loop of largest area among Manifold's loops (outer loops
    /// wind counter-clockwise), or nil when there is none.
    private static func largestOuterLoop(_ loops: [[Vec2]]) -> [Vec2]? {
        loops.map(withoutSpikes).filter { signedArea($0) > 1.0e-12 }.max { signedArea($0) < signedArea($1) }
    }

    /// The outer loop of largest area among `loops`, keeping the holes that
    /// lie inside it: each is opened to the loop's edge, where it comes
    /// nearest, by a slit `joinTolerance` wide, so the panel stays one loop.
    /// Joining the net's outline closes the slit again, and the hole is cut
    /// as a hole.
    private static func largestOuterLoopKeepingHoles(_ loops: [[Vec2]]) -> [Vec2]? {
        guard let outer = largestOuterLoop(loops) else {
            return nil
        }
        let holes = loops.filter { $0.count >= 3 && signedArea($0) < -1.0e-9 }.filter { hole in
            interiorPoint(of: Array(hole.reversed())).map { pointInPolygon($0, outer) } ?? false
        }
        guard !holes.isEmpty else {
            return outer
        }
        let edges = loopEdges(outer)
        var slits: [[Vec2]] = []
        for hole in holes {
            var best: (distance: Double, from: Vec2, to: Vec2, edge: Vec2)?
            for point in hole {
                for (a, b) in edges {
                    let ab = subtract2(b, a)
                    let lengthSquared = ab.x * ab.x + ab.y * ab.y
                    guard lengthSquared > 1.0e-18 else {
                        continue
                    }
                    let ap = subtract2(point, a)
                    let t = min(max((ap.x * ab.x + ap.y * ab.y) / lengthSquared, 0), 1)
                    let nearest = Vec2(x: a.x + ab.x * t, y: a.y + ab.y * t)
                    let distance = length2(subtract2(nearest, point))
                    if distance < (best?.distance ?? .infinity) {
                        best = (distance, point, nearest, ab)
                    }
                }
            }
            guard let best else {
                continue
            }
            // Straight out to the nearest point of the edge; a hole that
            // touches the edge there goes straight out across it.
            let edgeLength = length2(best.edge)
            let unit = best.distance > 1.0e-6
                ? Vec2(x: (best.to.x - best.from.x) / best.distance, y: (best.to.y - best.from.y) / best.distance)
                : Vec2(x: best.edge.y / edgeLength, y: -best.edge.x / edgeLength)
            let half = Vec2(x: -unit.y * joinTolerance / 2, y: unit.x * joinTolerance / 2)
            let start = Vec2(x: best.from.x - unit.x * joinTolerance, y: best.from.y - unit.y * joinTolerance)
            let end = Vec2(x: best.to.x + unit.x * joinTolerance, y: best.to.y + unit.y * joinTolerance)
            slits.append([
                Vec2(x: start.x - half.x, y: start.y - half.y),
                Vec2(x: end.x - half.x, y: end.y - half.y),
                Vec2(x: end.x + half.x, y: end.y + half.y),
                Vec2(x: start.x + half.x, y: start.y + half.y)
            ])
        }
        guard let opened = PlanarBoolean.subtracting(holes + slits, from: [outer]) else {
            return outer
        }
        return largestOuterLoop(opened) ?? outer
    }

    /// A loop without the hairline spikes cutting can leave where two cuts
    /// meet along a line: corners where the loop doubles straight back, and
    /// repeated points.
    private static func withoutSpikes(_ loop: [Vec2]) -> [Vec2] {
        var points = loop
        var changed = true
        while changed, points.count >= 3 {
            changed = false
            var index = 0
            while index < points.count, points.count >= 3 {
                let previous = points[(index - 1 + points.count) % points.count]
                let point = points[index]
                let next = points[(index + 1) % points.count]
                let incoming = subtract2(point, previous)
                let outgoing = subtract2(next, point)
                let lengthIn = length2(incoming)
                let lengthOut = length2(outgoing)
                let turn = incoming.x * outgoing.y - incoming.y * outgoing.x
                let doublesBack = incoming.x * outgoing.x + incoming.y * outgoing.y < 0
                if lengthIn < 1.0e-9 || lengthOut < 1.0e-9
                    || (doublesBack && abs(turn) <= 1.0e-7 * max(lengthIn, lengthOut)) {
                    points.remove(at: index)
                    changed = true
                } else {
                    index += 1
                }
            }
        }
        return points
    }

    /// Where the pieces' stock meets, worked out as asked for and kept: for
    /// a panel and another piece, the regions of the panel's net where its
    /// stock, extended across its plane, meets the other piece's stock.
    private final class StockConflicts {
        let panels: [NetPanel]
        let thickness: Double
        /// Each piece's shape on the model, in triangles.
        let triangles: [[[Vec3]]]
        /// Each piece's box in the model: its shape and the stock behind it.
        let boxes: [(lo: Vec3, hi: Vec3)?]
        private var known: [[Int]: [[Vec2]]] = [:]

        /// The pieces as `shapes` (net coordinates, one per panel) cut them.
        init(panels: [NetPanel], shapes: [[Vec2]], thickness: Double) {
            self.panels = panels
            self.thickness = thickness
            let pieces: [[[Vec3]]] = panels.indices.map { index in
                guard let frame = panels[index].frame else {
                    return []
                }
                return FoldedPanelPlanner.triangulate(shapes[index]).map { $0.map(frame.modelPoint) }
            }
            triangles = pieces
            boxes = panels.indices.map { index in
                let points = pieces[index].flatMap { $0 }
                return FoldedPanelPlanner.box(points + points.map { FoldedPanelPlanner.add($0, FoldedPanelPlanner.scale(panels[index].inward, thickness)) })
            }
        }

        func regions(of panel: Int, with other: Int) -> [[Vec2]] {
            if let regions = known[[panel, other]] {
                return regions
            }
            let regions = thickness > 0
                ? FoldedPanelPlanner.stockConflicts(of: panels[panel], with: triangles[other], inward: panels[other].inward, thickness: thickness)
                : []
            known[[panel, other]] = regions
            return regions
        }

        /// The pieces whose boxes meet `box`.
        func pieces(meeting box: (lo: Vec3, hi: Vec3), except excluded: Set<Int>) -> [Int] {
            boxes.indices.filter { index in
                guard !excluded.contains(index), let other = boxes[index] else {
                    return false
                }
                return other.lo.x <= box.hi.x && other.hi.x >= box.lo.x
                    && other.lo.y <= box.hi.y && other.hi.y >= box.lo.y
                    && other.lo.z <= box.hi.z && other.hi.z >= box.lo.z
            }
        }

        /// The box of a polygon of panel `panel`'s net and the stock behind
        /// it, in the model.
        func box(of polygon: [Vec2], panel: Int) -> (lo: Vec3, hi: Vec3)? {
            guard let frame = panels[panel].frame else {
                return nil
            }
            let points = polygon.map(frame.modelPoint)
            return FoldedPanelPlanner.box(points + points.map { FoldedPanelPlanner.add($0, FoldedPanelPlanner.scale(panels[panel].inward, thickness)) })
        }
    }

    /// A simple polygon's triangles, by ear clipping (a convex polygon
    /// fans).
    private static func triangulate(_ polygon: [Vec2]) -> [[Vec2]] {
        var points = signedArea(polygon) < 0 ? Array(polygon.reversed()) : polygon
        guard points.count >= 3 else {
            return []
        }
        func turn(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var triangles: [[Vec2]] = []
        var guardCount = 0
        while points.count > 3, guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for index in points.indices {
                let a = points[(index - 1 + points.count) % points.count]
                let b = points[index]
                let c = points[(index + 1) % points.count]
                guard turn(a, b, c) > 1.0e-12 else {
                    continue
                }
                let others = points.indices.filter { $0 != index && $0 != (index - 1 + points.count) % points.count && $0 != (index + 1) % points.count }
                let blocked = others.contains { k in
                    let p = points[k]
                    return turn(a, b, p) >= 0 && turn(b, c, p) >= 0 && turn(c, a, p) >= 0
                }
                if !blocked {
                    triangles.append([a, b, c])
                    points.remove(at: index)
                    clipped = true
                    break
                }
            }
            if !clipped {
                // Degenerate leftovers: fan what remains.
                for index in 1..<(points.count - 1) {
                    triangles.append([points[0], points[index], points[index + 1]])
                }
                return triangles
            }
        }
        if points.count == 3 {
            triangles.append(points)
        }
        return triangles
    }

    private static func box(_ points: [Vec3]) -> (lo: Vec3, hi: Vec3)? {
        guard let first = points.first else {
            return nil
        }
        var lo = first, hi = first
        for point in points {
            lo = Vec3(x: min(lo.x, point.x), y: min(lo.y, point.y), z: min(lo.z, point.z))
            hi = Vec3(x: max(hi.x, point.x), y: max(hi.y, point.y), z: max(hi.z, point.z))
        }
        return (lo, hi)
    }

    /// For each panel that must give way, the regions (net coordinates) of
    /// its stock that pass into another piece's stock that a seam's cut-back
    /// did not clear: at a corner of the model, past the ends of a seam, or
    /// across a hollow of it. For every pair of pieces whose stock meets and
    /// that no fold joins, the one that gives way (the male copy's panel for
    /// a seam's two panels, else the later panel) is tested against the
    /// whole of the other.
    private static func cornerConflicts(
        panels: [NetPanel],
        pairs: [MatingPair],
        hinged: Set<[Int]>,
        conflicts: StockConflicts
    ) -> [Int: [[Vec2]]] {
        var maleOf: [[Int]: Int] = [:]
        for pair in pairs {
            let key = [min(pair.male.panel, pair.female.panel), max(pair.male.panel, pair.female.panel)]
            if maleOf[key] == nil {
                maleOf[key] = pair.male.panel
            }
        }
        var cuts: [Int: [[Vec2]]] = [:]
        for i in panels.indices {
            guard let box = conflicts.boxes[i] else {
                continue
            }
            for j in conflicts.pieces(meeting: box, except: [i]) where j > i && !hinged.contains([i, j]) {
                let yielder = maleOf[[i, j]] ?? j
                let keeper = yielder == i ? j : i
                let regions = conflicts.regions(of: yielder, with: keeper)
                if !regions.isEmpty {
                    cuts[yielder, default: []] += regions
                }
            }
        }
        return cuts
    }

    /// The regions of panel `panel`'s net (convex, one per triangle of the
    /// other piece) where a column through its stock meets the other
    /// piece's stock: the part of each of its triangle prisms inside
    /// `panel`'s slab, seen square-on to `panel`. Stock that only touches
    /// `panel`'s faces (a piece resting on it) does not count.
    private static func stockConflicts(of panel: NetPanel, with otherTriangles: [[Vec3]], inward otherInward: Vec3, thickness: Double) -> [[Vec2]] {
        guard let frame = panel.frame, let corner = panel.polygon.first else {
            return []
        }
        let origin = frame.modelPoint(corner)
        let inward = panel.inward
        let low = touchTolerance
        let high = thickness - touchTolerance
        guard high > low else {
            return []
        }
        var regions: [[Vec2]] = []
        let edges = [(0, 1), (1, 2), (2, 0), (3, 4), (4, 5), (5, 3), (0, 3), (1, 4), (2, 5)]
        for triangle in otherTriangles where triangle.count == 3 {
            let deep = triangle.map { add($0, scale(otherInward, thickness)) }
            let corners = triangle + deep
            let heights = corners.map { dot(subtract($0, origin), inward) }
            var points: [Vec3] = []
            for (index, height) in heights.enumerated() where height >= low && height <= high {
                points.append(corners[index])
            }
            for (i, j) in edges {
                for level in [low, high] {
                    let hi = heights[i] - level
                    let hj = heights[j] - level
                    if hi * hj < 0 {
                        let f = hi / (hi - hj)
                        points.append(add(corners[i], scale(subtract(corners[j], corners[i]), f)))
                    }
                }
            }
            guard points.count >= 3 else {
                continue
            }
            let hull = convexHull(points.map { netPoint($0, frame: frame) })
            if hull.count >= 3, abs(signedArea(hull)) > 1.0e-9 {
                regions.append(hull)
            }
        }
        return regions
    }

    /// The net coordinates of a model point, through a panel's frame (whose
    /// axes are orthonormal: the unfold moves panels rigidly).
    private static func netPoint(_ point: Vec3, frame: PartPlaneFrame) -> Vec2 {
        let relative = subtract(point, frame.origin)
        let xx = max(dot(frame.xAxis, frame.xAxis), 1.0e-18)
        let yy = max(dot(frame.yAxis, frame.yAxis), 1.0e-18)
        return Vec2(x: dot(relative, frame.xAxis) / xx, y: dot(relative, frame.yAxis) / yy)
    }

    /// Convex hull (counter-clockwise), monotone chain.
    private static func convexHull(_ points: [Vec2]) -> [Vec2] {
        // On a nanometre grid first: points a rounding error apart in x
        // would otherwise sort out of turn, and the near-collinear test
        // could then drop a true corner of the hull.
        let snapped = points.map { Vec2(x: ($0.x * 1.0e6).rounded() / 1.0e6, y: ($0.y * 1.0e6).rounded() / 1.0e6) }
        let sorted = snapped.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard sorted.count >= 3 else {
            return sorted
        }
        func turn(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Vec2] = []
        for point in sorted {
            while lower.count >= 2, turn(lower[lower.count - 2], lower[lower.count - 1], point) <= 1.0e-12 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [Vec2] = []
        for point in sorted.reversed() {
            while upper.count >= 2, turn(upper[upper.count - 2], upper[upper.count - 1], point) <= 1.0e-12 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A copy's features in net coordinates, each polygon counter-clockwise.
    private static func place(_ local: FoldedJoineryGeometry.LocalFeatures, frame: FoldedEdgeFrame) -> PlacedCuts {
        func placed(_ polygon: [FoldedJoineryGeometry.LocalPoint]) -> [Vec2] {
            let points = polygon.map(frame.world)
            return signedArea(points) < 0 ? Array(points.reversed()) : points
        }
        return PlacedCuts(
            outward: local.outward.map(placed),
            inward: local.inward.map(placed),
            holes: local.holes.map(placed)
        )
    }

    /// Whether one copy's joint fits its net: what stands out of the panel
    /// meets no other panel of the net, no joint already there and not its
    /// own cut-back panel, and keeps `featureGap` from them, and, folded up,
    /// runs into no piece's stock but its mate's; it meets its panel along
    /// its base; and what is cut into the panel (notches, slot, holes) lies
    /// inside the cut-back panel with `bridge` of material to the panel's
    /// other edges and to the other joints.
    private static func jointFits(
        _ local: FoldedJoineryGeometry.LocalFeatures,
        cuts: PlacedCuts,
        frame: FoldedEdgeFrame,
        edgeLine: Double,
        panel: Int,
        partner: Int,
        trimmed: [[Vec2]],
        panels: [NetPanel],
        netPanels: [Int],
        taken: PlacedCuts,
        conflicts: StockConflicts,
        bridge: Double
    ) -> Bool {
        let own = trimmed[panel]
        guard own.count >= 3 else {
            return false
        }
        // Folded up, what stands out of the panel meets no piece's stock but
        // its mate's, which is cut for it.
        for feature in cuts.outward {
            guard let box = conflicts.box(of: feature, panel: panel) else {
                continue
            }
            for other in conflicts.pieces(meeting: box, except: [panel, partner])
            where conflicts.regions(of: panel, with: other).contains(where: { polygonsOverlap(feature, $0) }) {
                return false
            }
        }
        let others = netPanels.filter { $0 != panel }.map { panels[$0].polygon }
        for feature in cuts.outward {
            if polygonsOverlap(feature, own) || others.contains(where: { polygonsOverlap(feature, $0) }) {
                return false
            }
        }
        for cut in cuts.all where taken.all.contains(where: { polygonsOverlap(cut, $0) }) {
            return false
        }
        if !cuts.outward.isEmpty,
           clearance(cuts.outward, others.flatMap(loopEdges) + taken.outward.flatMap(loopEdges)) < featureGap - 1.0e-9 {
            return false
        }
        let takenInner = taken.inward + taken.holes
        return basesOnPanel(local, frame: frame, polygon: own)
            && cutsInPanel(local, frame: frame, edgeLine: edgeLine, polygon: own, others: taken.all, bridge: bridge)
            && clearance(cuts.outward, takenInner.flatMap(loopEdges)) >= bridge - 1.0e-9
    }

    /// Whether what a copy cuts into its panel (notches, slot, holes) lies
    /// inside the cut-back panel with `bridge` of material to the panel's
    /// edges (other than the copy's own edge line, at v = `edgeLine`) and to
    /// the `others` cuts.
    private static func cutsInPanel(
        _ local: FoldedJoineryGeometry.LocalFeatures,
        frame: FoldedEdgeFrame,
        edgeLine: Double,
        polygon: [Vec2],
        others: [[Vec2]],
        bridge: Double
    ) -> Bool {
        var inPanel = local.inward
        for (index, hole) in local.holes.enumerated() where !local.holesInFeatures.contains(index) {
            inPanel.append(hole)
        }
        guard !inPanel.isEmpty else {
            return true
        }
        guard polygon.count >= 3 else {
            return false
        }
        for cut in inPanel {
            for point in cut where point.v < edgeLine - 1.0e-6 {
                if !pointInPolygon(frame.world(point), polygon) {
                    return false
                }
            }
        }
        // The panel's edges other than the copy's own edge line.
        let otherEdges = loopEdges(polygon).filter { edge in
            let a = frame.local(edge.0)
            let b = frame.local(edge.1)
            return !(abs(a.v - edgeLine) < 1.0e-6 && abs(b.v - edgeLine) < 1.0e-6)
        }
        let placedInPanel = inPanel.map { $0.map(frame.world) }
        return clearance(placedInPanel, otherEdges + others.flatMap(loopEdges)) >= bridge - 1.0e-9
    }

    /// Whether every feature of a copy that stands out of its panel meets
    /// the cut-back panel along its whole base.
    private static func basesOnPanel(_ local: FoldedJoineryGeometry.LocalFeatures, frame: FoldedEdgeFrame, polygon: [Vec2]) -> Bool {
        guard !local.bases.isEmpty else {
            return true
        }
        guard polygon.count >= 3 else {
            return false
        }
        let inset = 1.0e-4
        for base in local.bases {
            for u in [base.u0 + inset, (base.u0 + base.u1) / 2, base.u1 - inset] {
                if !pointInPolygon(frame.world(.init(u: u, v: base.v - inset)), polygon) {
                    return false
                }
            }
        }
        return true
    }

    /// One net's pieces: its cut-back panels joined with the features that
    /// stand out of them, less its notches; its holes; and its fold lines,
    /// where the panels either side both still have stock. A net the stock
    /// cuts in two comes back as two.
    private static func assembleOutlines(
        members: [Int],
        panels: [NetPanel],
        trimmed: [[Vec2]],
        features: [[[Vec2]]],
        notches: [[Vec2]],
        holes: [[Vec2]],
        hinges: [(a: Int, b: Int, segment: FoldedNetFoldEdge)]
    ) -> (nets: [FoldedNet], droppedHinges: Set<[Int]>) {
        func counterClockwise(_ loop: [Vec2]) -> [Vec2] {
            signedArea(loop) < 0 ? Array(loop.reversed()) : loop
        }
        var rings = members.map { trimmed[$0] }.filter { $0.count >= 3 }.map(counterClockwise)
        for member in members {
            rings += features[member].map(counterClockwise)
        }
        // Each panel and feature was cut on its own, so edges they share may
        // have been rounded a hair apart: closing the union joins them. Webs
        // of stock thinner than a cut is wide, where cut-back panels nearly
        // meet, go.
        guard !rings.isEmpty,
              var loops = PlanarBoolean.joining(rings, closingBy: joinTolerance, openingBy: thinnestWeb / 2, minus: notches.map(counterClockwise)) else {
            return ([], [])
        }
        loops = loops.map(withoutSpikes).filter { $0.count >= 3 }
        // Where outlines meet at a point (panels of the net that touch only
        // at a corner, or round a gap), a little stock is cut away so each
        // cut runs round on its own, never touching itself or another.
        // Cutting it away can make new places where cuts meet, so the result
        // is joined again (hairline gaps closed) and checked again, a few
        // rounds at most.
        for _ in 0..<reliefRounds {
            let pinches = pinchPoints(loops) + nearTouches(loops)
            guard !pinches.isEmpty,
                  let relieved = PlanarBoolean.subtracting(pinches.map { reliefSquare(at: $0.point, size: $0.size) }, from: loops),
                  let rejoined = PlanarBoolean.joining(relieved, closingBy: joinTolerance) else {
                break
            }
            loops = rejoined.map(withoutSpikes).filter { $0.count >= 3 }
        }
        // Cuts shorter than the join tolerance are noise from the boolean
        // operations, and readers take their ends for one point.
        loops = loops.map { withoutSpikes(withoutShortEdges($0)) }.filter { $0.count >= 3 }
        let outers = loops.filter { signedArea($0) > 1.0e-9 }
        let gaps = loops.filter { signedArea($0) < -1.0e-9 }
        guard !outers.isEmpty else {
            return ([], [])
        }
        func inMaterial(_ point: Vec2) -> Bool {
            outers.contains { pointInPolygon(point, $0) } && !gaps.contains { pointInPolygon(point, $0) }
        }
        func piece(containing point: Vec2) -> Int? {
            outers.indices.filter { pointInPolygon(point, outers[$0]) }.min { abs(signedArea(outers[$0])) < abs(signedArea(outers[$1])) }
        }

        // Which piece each panel ended up in.
        var pieceOf: [Int: Int] = [:]
        for member in members where trimmed[member].count >= 3 {
            if let point = interiorPoint(of: trimmed[member]), let index = piece(containing: point) {
                pieceOf[member] = index
            }
        }
        // Fold lines: where both panels still have stock along the fold.
        var folds: [(a: Int, b: Int, segments: [FoldedNetFoldEdge])] = []
        for hinge in hinges {
            let along = commonCoverage(hinge.segment, panels[hinge.a].polygon, trimmed[hinge.a], panels[hinge.b].polygon, trimmed[hinge.b])
            guard !along.isEmpty else {
                continue
            }
            folds.append((hinge.a, hinge.b, along))
            // A panel the stock left empty goes with its hinge partner.
            if pieceOf[hinge.a] == nil, let other = pieceOf[hinge.b] {
                pieceOf[hinge.a] = other
            }
            if pieceOf[hinge.b] == nil, let other = pieceOf[hinge.a] {
                pieceOf[hinge.b] = other
            }
        }

        var nets: [FoldedNet] = []
        var dropped = Set<[Int]>()
        for (pieceIndex, outer) in outers.enumerated() {
            let pieceMembers = members.filter { (pieceOf[$0] ?? 0) == pieceIndex }
            guard !pieceMembers.isEmpty || pieceIndex == 0 else {
                continue
            }
            let local = Dictionary(uniqueKeysWithValues: pieceMembers.enumerated().map { ($0.element, $0.offset) })
            var net = FoldedNet(
                outline: outer,
                foldEdges: [],
                slotHoles: holes.filter { hole in
                    interiorPoint(of: hole).flatMap(piece(containing:)) == pieceIndex
                },
                panelOutlines: pieceMembers.map { trimmed[$0] },
                panelFrames: pieceMembers.map { panels[$0].frame },
                panelInward: pieceMembers.map { panels[$0].inward },
                panelFeatures: pieceMembers.map { features[$0] },
                hinges: [],
                outlineHoles: gaps.filter { gap in
                    interiorPoint(of: gap).flatMap { point in
                        outers.indices.filter { pointInPolygon(point, outers[$0]) }.min { abs(signedArea(outers[$0])) < abs(signedArea(outers[$1])) }
                    } == pieceIndex
                }
            )
            for fold in folds {
                guard let a = local[fold.a] else {
                    continue
                }
                let key = [min(fold.a, fold.b), max(fold.a, fold.b)]
                guard let b = local[fold.b] else {
                    // The fold's panels ended up in different pieces.
                    dropped.insert(key)
                    continue
                }
                let kept = fold.segments.filter { segment in
                    inMaterial(Vec2(x: (segment.start.x + segment.end.x) / 2, y: (segment.start.y + segment.end.y) / 2))
                }
                guard !kept.isEmpty else {
                    dropped.insert(key)
                    continue
                }
                net.foldEdges += kept
                net.hinges.append(FoldedNetHinge(a: a, b: b))
            }
            nets.append(net)
        }
        return (nets, dropped)
    }

    /// Where a gap in a net (a clockwise loop) comes nearer than
    /// `thinnestWeb` to another loop: the middle of the nearest approach,
    /// and how big a square cut there opens the gap into the other loop.
    private static func nearTouches(_ loops: [[Vec2]]) -> [(point: Vec2, size: Double)] {
        var touches: [(point: Vec2, size: Double)] = []
        for (gapIndex, gap) in loops.enumerated() where signedArea(gap) < 0 {
            for (otherIndex, other) in loops.enumerated() where otherIndex != gapIndex {
                var best: (distance: Double, a: Vec2, b: Vec2)?
                func consider(_ point: Vec2, _ edges: [(Vec2, Vec2)]) {
                    for edge in edges {
                        let ab = subtract2(edge.1, edge.0)
                        let lengthSquared = ab.x * ab.x + ab.y * ab.y
                        let ap = subtract2(point, edge.0)
                        let t = lengthSquared > 0 ? min(max((ap.x * ab.x + ap.y * ab.y) / lengthSquared, 0), 1) : 0
                        let nearest = Vec2(x: edge.0.x + ab.x * t, y: edge.0.y + ab.y * t)
                        let distance = length2(subtract2(point, nearest))
                        if distance < (best?.distance ?? .infinity) {
                            best = (distance, point, nearest)
                        }
                    }
                }
                let gapEdges = loopEdges(gap)
                let otherEdges = loopEdges(other)
                for point in gap {
                    consider(point, otherEdges)
                }
                for point in other {
                    consider(point, gapEdges)
                }
                if let best, best.distance > 1.0e-6, best.distance < thinnestWeb {
                    touches.append((
                        Vec2(x: (best.a.x + best.b.x) / 2, y: (best.a.y + best.b.y) / 2),
                        thinnestWeb + best.distance
                    ))
                }
            }
        }
        return touches
    }

    /// Points where two loops meet, or one loop meets itself away from its
    /// neighbouring corners.
    private static func pinchPoints(_ loops: [[Vec2]]) -> [(point: Vec2, size: Double)] {
        // Corners within `pinchDistance` of each other meet. They are found
        // through a grid of cells that size, looking in each corner's cell
        // and the eight around it, so two corners either side of a cell
        // boundary are found too.
        struct Cell: Hashable { let x: Int, y: Int }
        func cell(_ point: Vec2) -> Cell {
            Cell(x: Int((point.x / pinchDistance).rounded(.down)), y: Int((point.y / pinchDistance).rounded(.down)))
        }
        var grid: [Cell: [(loop: Int, index: Int)]] = [:]
        for (loopIndex, loop) in loops.enumerated() {
            for (index, point) in loop.enumerated() {
                grid[cell(point), default: []].append((loopIndex, index))
            }
        }
        var pinches: [Vec2] = []
        for (loopIndex, loop) in loops.enumerated() {
            for (index, point) in loop.enumerated() {
                let home = cell(point)
                let meets = (-1...1).contains { dx in
                    (-1...1).contains { dy in
                        (grid[Cell(x: home.x + dx, y: home.y + dy)] ?? []).contains { other in
                            guard (other.loop, other.index) > (loopIndex, index) else {
                                return false
                            }
                            if other.loop == loopIndex {
                                let gap = abs(other.index - index)
                                guard min(gap, loop.count - gap) > 1 else {
                                    return false
                                }
                            }
                            return length2(subtract2(loops[other.loop][other.index], point)) <= pinchDistance
                        }
                    }
                }
                if meets {
                    pinches.append(point)
                }
            }
        }
        return pinches.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }.map { ($0, thinnestWeb) }
    }

    /// How near, in mm, two corners of outlines are to count as meeting.
    private static let pinchDistance = 1.0e-5

    /// How many times outlines are relieved where they meet, at most.
    private static let reliefRounds = 4

    /// A loop without edges shorter than `joinTolerance`: a point that
    /// close to the one kept before it is dropped.
    private static func withoutShortEdges(_ loop: [Vec2]) -> [Vec2] {
        var points: [Vec2] = []
        for point in loop {
            if let last = points.last, length2(subtract2(point, last)) < joinTolerance {
                continue
            }
            points.append(point)
        }
        while points.count >= 2, length2(subtract2(points[0], points[points.count - 1])) < joinTolerance {
            points.removeLast()
        }
        return points
    }

    /// The little square of stock cut away where outlines meet, or nearly.
    private static func reliefSquare(at point: Vec2, size: Double) -> [Vec2] {
        let r = size / 2
        return [
            Vec2(x: point.x - r, y: point.y - r),
            Vec2(x: point.x + r, y: point.y - r),
            Vec2(x: point.x + r, y: point.y + r),
            Vec2(x: point.x - r, y: point.y + r)
        ]
    }

    /// A point inside a polygon: its vertex average if that is inside, else
    /// a point just inside one of its edges.
    private static func interiorPoint(of polygon: [Vec2]) -> Vec2? {
        guard polygon.count >= 3 else {
            return nil
        }
        let average = interiorPoint(polygon)
        if pointInPolygon(average, polygon) {
            return average
        }
        let sign: Double = signedArea(polygon) >= 0 ? 1 : -1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let direction = subtract2(b, a)
            let length = length2(direction)
            guard length > 1.0e-9 else {
                continue
            }
            let step = min(1.0e-3, length / 4)
            let point = Vec2(
                x: (a.x + b.x) / 2 - sign * direction.y / length * step,
                y: (a.y + b.y) / 2 + sign * direction.x / length * step
            )
            if pointInPolygon(point, polygon) {
                return point
            }
        }
        return nil
    }

    /// The parts of a fold where both panels still have stock along it,
    /// each panel tested just inside its own side of the fold.
    private static func commonCoverage(
        _ fold: FoldedNetFoldEdge,
        _ placedA: [Vec2], _ cutA: [Vec2],
        _ placedB: [Vec2], _ cutB: [Vec2]
    ) -> [FoldedNetFoldEdge] {
        let a = coverage(of: fold, by: cutA, placed: placedA)
        let b = coverage(of: fold, by: cutB, placed: placedB)
        var segments: [FoldedNetFoldEdge] = []
        let direction = subtract2(fold.end, fold.start)
        for spanA in a {
            for spanB in b {
                let lo = max(spanA.0, spanB.0)
                let hi = min(spanA.1, spanB.1)
                if (hi - lo) * length2(direction) > 1.0e-6 {
                    segments.append(FoldedNetFoldEdge(
                        start: Vec2(x: fold.start.x + direction.x * lo, y: fold.start.y + direction.y * lo),
                        end: Vec2(x: fold.start.x + direction.x * hi, y: fold.start.y + direction.y * hi)
                    ))
                }
            }
        }
        return segments
    }

    /// The spans (fractions of the fold) along which `polygon` has stock on
    /// the side of the fold where its uncut panel `placed` lies.
    private static func coverage(of fold: FoldedNetFoldEdge, by polygon: [Vec2], placed: [Vec2]) -> [(Double, Double)] {
        guard polygon.count >= 3 else {
            return []
        }
        let direction = subtract2(fold.end, fold.start)
        let lengthSquared = direction.x * direction.x + direction.y * direction.y
        guard lengthSquared > 1.0e-18 else {
            return []
        }
        let length = lengthSquared.squareRoot()
        var normal = Vec2(x: -direction.y / length, y: direction.x / length)
        let middle = Vec2(x: (fold.start.x + fold.end.x) / 2, y: (fold.start.y + fold.end.y) / 2)
        if !pointInPolygon(Vec2(x: middle.x + normal.x * 1.0e-5, y: middle.y + normal.y * 1.0e-5), placed) {
            normal = Vec2(x: -normal.x, y: -normal.y)
        }
        // Where the polygon's corners lie on the fold and its edges cross it.
        var cuts: [Double] = [0, 1]
        for index in polygon.indices {
            let p = polygon[index]
            let q = polygon[(index + 1) % polygon.count]
            let rp = subtract2(p, fold.start)
            let side = (rp.x * normal.x + rp.y * normal.y)
            if abs(side) < 1.0e-6 {
                cuts.append((rp.x * direction.x + rp.y * direction.y) / lengthSquared)
            }
            let rq = subtract2(q, fold.start)
            let sideQ = (rq.x * normal.x + rq.y * normal.y)
            if side * sideQ < 0 {
                let f = side / (side - sideQ)
                let crossing = Vec2(x: rp.x + (rq.x - rp.x) * f, y: rp.y + (rq.y - rp.y) * f)
                cuts.append((crossing.x * direction.x + crossing.y * direction.y) / lengthSquared)
            }
        }
        let sorted = cuts.filter { $0 >= 0 && $0 <= 1 }.sorted()
        var spans: [(Double, Double)] = []
        for (lo, hi) in zip(sorted, sorted.dropFirst()) where hi - lo > 1.0e-12 {
            let t = (lo + hi) / 2
            let probe = Vec2(
                x: fold.start.x + direction.x * t + normal.x * 1.0e-5,
                y: fold.start.y + direction.y * t + normal.y * 1.0e-5
            )
            guard pointInPolygon(probe, polygon) else {
                continue
            }
            if let last = spans.last, abs(last.1 - lo) < 1.0e-12 {
                spans[spans.count - 1].1 = hi
            } else {
                spans.append((lo, hi))
            }
        }
        return spans
    }

    private static func loopEdges(_ loop: [Vec2]) -> [(Vec2, Vec2)] {
        loop.indices.map { (loop[$0], loop[($0 + 1) % loop.count]) }
    }

    /// The least distance between the loops and the segments: from a loop
    /// corner to a segment, or from a segment end to a loop edge.
    private static func clearance(_ loops: [[Vec2]], _ segments: [(Vec2, Vec2)]) -> Double {
        var least = Double.infinity
        for loop in loops {
            let edges = loopEdges(loop)
            for segment in segments {
                for point in loop {
                    least = min(least, pointSegmentDistance(point, segment.0, segment.1))
                }
                for edge in edges {
                    least = min(least, pointSegmentDistance(segment.0, edge.0, edge.1))
                    least = min(least, pointSegmentDistance(segment.1, edge.0, edge.1))
                }
            }
        }
        return least
    }

    private static func pointSegmentDistance(_ point: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = subtract2(b, a)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        let ap = subtract2(point, a)
        let t = lengthSquared > 0 ? min(max((ap.x * ab.x + ap.y * ab.y) / lengthSquared, 0), 1) : 0
        return length2(Vec2(x: ap.x - ab.x * t, y: ap.y - ab.y * t))
    }

    /// The angle between two panels' planes (0 for parallel planes, π/2 for
    /// a square seam), or nil when either normal is unknown.
    private static func planeAngle(between lhs: Vec3?, and rhs: Vec3?) -> Double? {
        guard let lhs, let rhs else {
            return nil
        }
        return acos(min(abs(dot(lhs, rhs)), 1))
    }

    /// Where a placed panel's net coordinates sit on the model. The unfold
    /// moves each panel rigidly (mirrored when it had to be flipped over its
    /// hinge), so three of its corners, as placed in the net and as they sit
    /// on the mesh, fix the map.
    private static func panelFrame(group: PanelGroup, world: [String: Vec2]) -> PartPlaneFrame? {
        let corners = zip(group.boundaryKeys, group.boundary3D).compactMap { key, point in
            world[key].map { (net: $0, model: point) }
        }
        guard let base = corners.first else {
            return nil
        }
        // The corner farthest from the base, then the one spanning the
        // largest triangle with both, keep the solve well conditioned.
        guard let far = corners.max(by: {
            length2(subtract2($0.net, base.net)) < length2(subtract2($1.net, base.net))
        }) else {
            return nil
        }
        let d1 = subtract2(far.net, base.net)
        func span(_ corner: (net: Vec2, model: Vec3)) -> Double {
            let d2 = subtract2(corner.net, base.net)
            return d1.x * d2.y - d1.y * d2.x
        }
        guard let third = corners.max(by: { abs(span($0)) < abs(span($1)) }) else {
            return nil
        }
        let det = span(third)
        guard abs(det) > 1.0e-9 else {
            return nil
        }
        let d2 = subtract2(third.net, base.net)
        let e1 = subtract(far.model, base.model)
        let e2 = subtract(third.model, base.model)
        // e1 = d1.x X + d1.y Y and e2 = d2.x X + d2.y Y, solved for X and Y.
        func combine(_ a: Vec3, _ ka: Double, _ b: Vec3, _ kb: Double) -> Vec3 {
            Vec3(x: (a.x * ka + b.x * kb) / det, y: (a.y * ka + b.y * kb) / det, z: (a.z * ka + b.z * kb) / det)
        }
        let xAxis = combine(e1, d2.y, e2, -d1.y)
        let yAxis = combine(e2, d1.x, e1, -d2.x)
        let origin = Vec3(
            x: base.model.x - xAxis.x * base.net.x - yAxis.x * base.net.y,
            y: base.model.y - xAxis.y * base.net.x - yAxis.y * base.net.y,
            z: base.model.z - xAxis.z * base.net.x - yAxis.z * base.net.y
        )
        return PartPlaneFrame(origin: origin, xAxis: xAxis, yAxis: yAxis)
    }

    // MARK: - 2D overlap tests (multi-net placement)

    private static func polygonsOverlap(_ p: [Vec2], _ q: [Vec2]) -> Bool {
        guard p.count >= 3, q.count >= 3 else {
            return false
        }
        var pMinX = Double.infinity, pMinY = Double.infinity, pMaxX = -Double.infinity, pMaxY = -Double.infinity
        for point in p {
            pMinX = Swift.min(pMinX, point.x); pMinY = Swift.min(pMinY, point.y)
            pMaxX = Swift.max(pMaxX, point.x); pMaxY = Swift.max(pMaxY, point.y)
        }
        var qMinX = Double.infinity, qMinY = Double.infinity, qMaxX = -Double.infinity, qMaxY = -Double.infinity
        for point in q {
            qMinX = Swift.min(qMinX, point.x); qMinY = Swift.min(qMinY, point.y)
            qMaxX = Swift.max(qMaxX, point.x); qMaxY = Swift.max(qMaxY, point.y)
        }
        if pMaxX < qMinX - 1.0e-9 || qMaxX < pMinX - 1.0e-9 || pMaxY < qMinY - 1.0e-9 || qMaxY < pMinY - 1.0e-9 {
            return false
        }

        for i in p.indices {
            let a = p[i]
            let b = p[(i + 1) % p.count]
            for j in q.indices {
                let c = q[j]
                let d = q[(j + 1) % q.count]
                if properCrossing(a, b, c, d) {
                    return true
                }
            }
        }
        if pointInPolygon(interiorPoint(p), q) || pointInPolygon(interiorPoint(q), p) {
            return true
        }
        return false
    }

    /// Strict interior-interior segment crossing. Parallel (incl. collinear
    /// shared-fold contact) and endpoint touches are NOT crossings, which is
    /// what allows panels to sit edge-to-edge and vertex-to-vertex.
    private static func properCrossing(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let r = subtract2(b, a)
        let s = subtract2(d, c)
        let denom = r.x * s.y - r.y * s.x
        let lengths = length2(r) * length2(s)
        guard lengths > 1.0e-18, abs(denom) > 1.0e-9 * lengths else {
            return false
        }
        let ca = subtract2(c, a)
        let t = (ca.x * s.y - ca.y * s.x) / denom
        let u = (ca.x * r.y - ca.y * r.x) / denom
        let eps = 1.0e-7
        return t > eps && t < 1 - eps && u > eps && u < 1 - eps
    }

    private static func interiorPoint(_ polygon: [Vec2]) -> Vec2 {
        var sumX = 0.0, sumY = 0.0
        for point in polygon {
            sumX += point.x
            sumY += point.y
        }
        return Vec2(x: sumX / Double(polygon.count), y: sumY / Double(polygon.count))
    }

    private static func pointInPolygon(_ point: Vec2, _ polygon: [Vec2]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let crossX = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < crossX {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    private static func panelGroups(from triangles: [TriangleRecord]) -> [PanelGroup] {
        // The triangles are wound outward (`consistentlyWound`).
        let grouped = coplanarComponents(triangles)

        var groups: [PanelGroup] = []
        for (index, groupTriangles) in grouped.enumerated() {
            guard let first = groupTriangles.first else {
                continue
            }
            let boundary = boundaryLoop(for: groupTriangles)
            guard boundary.count >= 3 else {
                continue
            }
            // The outside is the side the triangles' winding points to; the
            // stock lies on the other side.
            var facing = 0.0
            for triangle in groupTriangles {
                facing += dot(triangle.winding, first.normal)
            }
            let outward = facing >= 0 ? 1.0 : -1.0
            groups.append(
                PanelGroup(
                    groupIndex: index,
                    component: index,
                    cost: groupTriangles.map(\.sourceTriangleIndex).min() ?? index,
                    normal: first.normal,
                    boundary3D: boundary,
                    boundaryKeys: boundary.map(pointKey),
                    inward: Vec3(x: -outward * first.normal.x, y: -outward * first.normal.y, z: -outward * first.normal.z),
                    triangles: groupTriangles.map(\.vertices)
                )
            )
        }
        // Re-key groupIndex to a dense 0..<n after any dropped groups so the
        // adjacency/tree arrays index cleanly.
        for i in groups.indices {
            groups[i].groupIndex = i
        }
        return groups
    }

    private static func panelAdjacency(
        groups: [PanelGroup],
        seamKeys: Set<BoundaryEdge> = []
    ) -> [[PanelAdjacency]] {
        // Map each undirected boundary edge (sorted point-key pair) to the
        // groups that carry it. A shared mesh edge belongs to exactly two
        // coplanar groups (the two faces meeting at that cube edge).
        var edgeOwners: [BoundaryEdge: [Int]] = [:]
        for group in groups {
            let keys = group.boundaryKeys
            for index in keys.indices {
                let a = keys[index]
                let b = keys[(index + 1) % keys.count]
                let edge = a < b ? BoundaryEdge(a: a, b: b) : BoundaryEdge(a: b, b: a)
                edgeOwners[edge, default: []].append(group.groupIndex)
            }
        }

        var adjacency: [[PanelAdjacency]] = Array(repeating: [], count: groups.count)
        for (edge, owners) in edgeOwners where owners.count == 2 {
            // A user seam removes this mesh edge from the fold candidates:
            // the spanning forest must CUT here, so the edge becomes a
            // mating cut-pair (and receives joinery like any other cut).
            if seamKeys.contains(edge) {
                continue
            }
            let lhs = owners[0]
            let rhs = owners[1]
            guard lhs != rhs else {
                continue
            }
            adjacency[lhs].append(PanelAdjacency(other: rhs, edgeKeyA: edge.a, edgeKeyB: edge.b))
            adjacency[rhs].append(PanelAdjacency(other: lhs, edgeKeyA: edge.a, edgeKeyB: edge.b))
        }
        // Deterministic neighbour order (by other-group index) so the BFS and
        // resulting net are reproducible run-to-run.
        for i in adjacency.indices {
            adjacency[i].sort { $0.other < $1.other }
        }
        return adjacency
    }

    private struct ParentEdge {
        var parent: Int
        var edgeKeyA: String
        var edgeKeyB: String
    }

    private struct SpanningTree {
        var root: Int
        var order: [Int]
        var parentEdge: [Int: ParentEdge]
    }

    private static func spanningTree(
        groupCount: Int,
        adjacency: [[PanelAdjacency]]
    ) -> SpanningTree? {
        guard groupCount > 0 else {
            return nil
        }
        // Deterministic root: lowest group index (groups are already ordered by
        // stable source-triangle cost), so the unfold is deterministic.
        let root = 0
        var visited = [Bool](repeating: false, count: groupCount)
        var order: [Int] = []
        var parentEdge: [Int: ParentEdge] = [:]
        var queue: [Int] = [root]
        visited[root] = true

        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for adj in adjacency[current] where !visited[adj.other] {
                visited[adj.other] = true
                parentEdge[adj.other] = ParentEdge(
                    parent: current,
                    edgeKeyA: adj.edgeKeyA,
                    edgeKeyB: adj.edgeKeyB
                )
                order.append(adj.other)
                queue.append(adj.other)
            }
        }

        guard visited.allSatisfy({ $0 }) else {
            return nil
        }
        return SpanningTree(root: root, order: order, parentEdge: parentEdge)
    }

    /// Isometric 2D embedding of a panel's 3D boundary polygon using its plane
    /// frame (origin = vertex0, x along edge0, y = normal × x). Distances are
    /// preserved so shared edges have identical lengths across panels, letting
    /// the unfold align them exactly.
    private static func localEmbedding(of group: PanelGroup) -> [String: Vec2]? {
        let vertices = group.boundary3D
        guard vertices.count >= 3 else {
            return nil
        }
        let origin = vertices[0]
        // Sliver panels can make vertex 1 coincide with vertex 0 to within
        // tolerance; any other boundary vertex serves equally as the frame's
        // x-axis seed (the embedding is isometric regardless).
        var frameAxis: Vec3?
        for vertex in vertices.dropFirst() {
            if let axis = normalized(subtract(vertex, origin)) {
                frameAxis = axis
                break
            }
        }
        guard let xAxis = frameAxis,
              let yAxis = normalized(cross(group.normal, xAxis)) else {
            return nil
        }
        var result: [String: Vec2] = [:]
        for (index, vertex) in vertices.enumerated() {
            let relative = subtract(vertex, origin)
            result[group.boundaryKeys[index]] = Vec2(x: dot(relative, xAxis), y: dot(relative, yAxis))
        }
        return result
    }

    /// Rigidly map a child panel's local-2D vertices so its copy of the shared
    /// edge (childEdgeStart→childEdgeEnd) lands exactly on the parent's placed
    /// edge (parentEdgeStart→parentEdgeEnd). If the rigid (rotation-only)
    /// placement would drop the child on the SAME side of the fold edge as the
    /// parent's interior (overlap), the child is reflected across the edge so
    /// the panels lie edge-to-edge without overlapping — the developable
    /// unfold.
    private static func placeChild(
        childLocal: [String: Vec2],
        childEdgeStart: Vec2,
        childEdgeEnd: Vec2,
        parentEdgeStart: Vec2,
        parentEdgeEnd: Vec2,
        parentInteriorCentroid: Vec2
    ) -> [String: Vec2]? {
        let childDir = subtract2(childEdgeEnd, childEdgeStart)
        let parentDir = subtract2(parentEdgeEnd, parentEdgeStart)
        let childLen = length2(childDir)
        let parentLen = length2(parentDir)
        guard childLen > 1.0e-7, parentLen > 1.0e-7 else {
            return nil
        }

        // Rigid transform: rotation aligning childDir→parentDir, then translate
        // childEdgeStart→parentEdgeStart. No scale (lengths already match to
        // floating tolerance because the unfold is isometric).
        let cu = Vec2(x: childDir.x / childLen, y: childDir.y / childLen)
        let pu = Vec2(x: parentDir.x / parentLen, y: parentDir.y / parentLen)
        let cosA = cu.x * pu.x + cu.y * pu.y
        let sinA = cu.x * pu.y - cu.y * pu.x

        func rigid(_ point: Vec2) -> Vec2 {
            let rel = subtract2(point, childEdgeStart)
            let rotated = Vec2(
                x: rel.x * cosA - rel.y * sinA,
                y: rel.x * sinA + rel.y * cosA
            )
            return Vec2(x: rotated.x + parentEdgeStart.x, y: rotated.y + parentEdgeStart.y)
        }

        var placed: [String: Vec2] = [:]
        for (key, point) in childLocal {
            placed[key] = rigid(point)
        }

        // Reflect across the fold edge if the child centroid ended up on the
        // same side as the parent interior (would overlap the parent).
        let childCentroid = centroid(of: placed)
        if sideOfLine(point: childCentroid, a: parentEdgeStart, b: parentEdgeEnd)
            * sideOfLine(point: parentInteriorCentroid, a: parentEdgeStart, b: parentEdgeEnd) > 0 {
            for (key, point) in placed {
                placed[key] = reflectAcrossLine(point: point, a: parentEdgeStart, b: parentEdgeEnd)
            }
        }
        return placed
    }

    // Endpoint-coincidence tolerance for chaining outer-boundary segments by
    // 2D position. Mirrors the comparator's `_CHAIN_EPS` (1e-4 DXF units); the
    // candidate emits at true mm with exact arithmetic on integer-valued cube
    // vertices, so coincident endpoints agree far inside this bound.
    private static let netChainEpsilon = 1.0e-6

    /// Chain the outer-boundary segments (each `(a, b)` in world-2D) into a
    /// single ordered closed loop by greedy position matching — the same
    /// head-to-tail walk the comparator's `_find_boundary_chain` performs. The
    /// outer boundary of the unfolded net is one simple closed polygon, so a
    /// greedy single-chain walk recovers it. Returns the ordered vertices
    /// (CCW), or nil if the segments do not form one closed ring.
    private static func chainOuterSegments(_ segments: [(a: Vec2, b: Vec2)]) -> [Vec2]? {
        guard segments.count >= 3 else {
            return nil
        }
        let remaining = segments
        var used = [Bool](repeating: false, count: remaining.count)

        // Deterministic start: the segment whose start point is lexicographically
        // smallest, so the assembled outline is reproducible run-to-run.
        let startIndex = remaining.indices.min { lhs, rhs in
            (remaining[lhs].a.x, remaining[lhs].a.y) < (remaining[rhs].a.x, remaining[rhs].a.y)
        } ?? 0

        var loop: [Vec2] = [remaining[startIndex].a, remaining[startIndex].b]
        used[startIndex] = true
        var head = remaining[startIndex].b
        let anchor = remaining[startIndex].a

        func coincident(_ lhs: Vec2, _ rhs: Vec2) -> Bool {
            abs(lhs.x - rhs.x) < netChainEpsilon && abs(lhs.y - rhs.y) < netChainEpsilon
        }

        var progressed = true
        while progressed {
            progressed = false
            for index in remaining.indices where !used[index] {
                let seg = remaining[index]
                if coincident(seg.a, head) {
                    loop.append(seg.b)
                    head = seg.b
                    used[index] = true
                    progressed = true
                    break
                } else if coincident(seg.b, head) {
                    loop.append(seg.a)
                    head = seg.a
                    used[index] = true
                    progressed = true
                    break
                }
            }
        }

        // Require a fully closed single cycle that consumed every outer segment
        // (no dangling chain, no second component) — otherwise the net outline
        // is not a clean simple polygon and we fall back to per-panel emission.
        guard used.allSatisfy({ $0 }) else {
            return nil
        }
        guard coincident(head, anchor) else {
            return nil
        }
        // Drop the duplicated closing vertex (first == last).
        if loop.count >= 2, coincident(loop[loop.count - 1], loop[0]) {
            loop.removeLast()
        }
        guard loop.count >= 3 else {
            return nil
        }
        if signedArea(loop) < 0 {
            loop.reverse()
        }
        return loop
    }

    // MARK: - 2D vector helpers (net assembly)

    private static func subtract2(_ lhs: Vec2, _ rhs: Vec2) -> Vec2 {
        Vec2(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    private static func length2(_ vector: Vec2) -> Double {
        sqrt(vector.x * vector.x + vector.y * vector.y)
    }

    private static func centroid(of points: [String: Vec2]) -> Vec2 {
        guard !points.isEmpty else {
            return Vec2(x: 0, y: 0)
        }
        var sumX = 0.0
        var sumY = 0.0
        for point in points.values {
            sumX += point.x
            sumY += point.y
        }
        let count = Double(points.count)
        return Vec2(x: sumX / count, y: sumY / count)
    }

    /// Signed side of point relative to the directed line a→b (>0 left, <0 right).
    private static func sideOfLine(point: Vec2, a: Vec2, b: Vec2) -> Double {
        (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
    }

    private static func reflectAcrossLine(point: Vec2, a: Vec2, b: Vec2) -> Vec2 {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denom = dx * dx + dy * dy
        guard denom > 1.0e-12 else {
            return point
        }
        // Project point onto the line, then mirror through the projection.
        let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / denom
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return Vec2(x: 2 * projX - point.x, y: 2 * projY - point.y)
    }

    private static func boundaryLoop(for triangles: [TriangleRecord]) -> [Vec3] {
        var edgeCounts: [BoundaryEdge: Int] = [:]
        var pointsByKey: [String: Vec3] = [:]

        for triangle in triangles {
            for vertex in triangle.vertices {
                pointsByKey[pointKey(vertex)] = vertex
            }
            let keys = triangle.vertices.map(pointKey)
            for edge in [(keys[0], keys[1]), (keys[1], keys[2]), (keys[2], keys[0])] {
                let key = edge.0 < edge.1 ? BoundaryEdge(a: edge.0, b: edge.1) : BoundaryEdge(a: edge.1, b: edge.0)
                edgeCounts[key, default: 0] += 1
            }
        }

        let boundaryEdges = edgeCounts.filter { $0.value == 1 }.map(\.key)
        guard boundaryEdges.count >= 3 else {
            return []
        }

        var adjacency: [String: [String]] = [:]
        for edge in boundaryEdges {
            adjacency[edge.a, default: []].append(edge.b)
            adjacency[edge.b, default: []].append(edge.a)
        }
        guard let start = adjacency.keys.sorted().first else {
            return []
        }

        var loopKeys = [start]
        var previous: String?
        var current = start
        for _ in 0...boundaryEdges.count {
            let neighbors = (adjacency[current] ?? []).sorted()
            guard let next = neighbors.first(where: { $0 != previous }) else {
                break
            }
            if next == start {
                break
            }
            loopKeys.append(next)
            previous = current
            current = next
        }

        guard loopKeys.count >= 3 else {
            return []
        }
        return loopKeys.compactMap { pointsByKey[$0] }
    }

    private static func unfoldPolygon(_ vertices: [Vec3], normal: Vec3, sourceTriangleIndex: Int) -> FoldedPanel? {
        guard vertices.count >= 3 else {
            return nil
        }
        let origin = vertices[0]
        guard let xAxis = normalized(subtract(vertices[1], origin)) else {
            return nil
        }
        guard let yAxis = normalized(cross(normal, xAxis)) else {
            return nil
        }
        var points = vertices.map { vertex in
            let relative = subtract(vertex, origin)
            return Vec2(x: dot(relative, xAxis), y: dot(relative, yAxis))
        }
        if signedArea(points) < 0 {
            points.reverse()
        }
        points.append(points[0])
        return FoldedPanel(points: points, bounds: bounds(for: points), sourceTriangleIndex: sourceTriangleIndex)
    }

    private static func unfoldTriangle(a: Vec3, b: Vec3, c: Vec3, sourceTriangleIndex: Int) -> FoldedPanel? {
        let ab = distance(a, b)
        let ac = distance(a, c)
        let bc = distance(b, c)
        guard ab > 1.0e-7, ac > 1.0e-7, bc > 1.0e-7 else {
            return nil
        }

        let cX = (ac * ac + ab * ab - bc * bc) / (2 * ab)
        let cY2 = max(0, ac * ac - cX * cX)
        guard cY2 > 1.0e-10 else {
            return nil
        }
        let points = [
            Vec2(x: 0, y: 0),
            Vec2(x: ab, y: 0),
            Vec2(x: cX, y: sqrt(cY2)),
            Vec2(x: 0, y: 0)
        ]
        return FoldedPanel(points: points, bounds: bounds(for: points), sourceTriangleIndex: sourceTriangleIndex)
    }

    private static func bounds(for points: [Vec2]) -> FoldedPanelBounds {
        var minX = points[0].x
        var minY = points[0].y
        var maxX = points[0].x
        var maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return FoldedPanelBounds(min: Vec2(x: minX, y: minY), max: Vec2(x: maxX, y: maxY))
    }

    private static func distance(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private static func canonicalNormal(a: Vec3, b: Vec3, c: Vec3) -> Vec3? {
        guard var normal = normalized(cross(subtract(b, a), subtract(c, a))) else {
            return nil
        }
        if normal.x < -1.0e-7
            || (abs(normal.x) <= 1.0e-7 && normal.y < -1.0e-7)
            || (abs(normal.x) <= 1.0e-7 && abs(normal.y) <= 1.0e-7 && normal.z < -1.0e-7) {
            normal = Vec3(x: -normal.x, y: -normal.y, z: -normal.z)
        }
        return normal
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    private static func scale(_ vector: Vec3, _ factor: Double) -> Vec3 {
        Vec3(x: vector.x * factor, y: vector.y * factor, z: vector.z * factor)
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func normalized(_ vector: Vec3) -> Vec3? {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard length > 1.0e-7 else {
            return nil
        }
        return Vec3(x: vector.x / length, y: vector.y / length, z: vector.z / length)
    }

    private static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count >= 3 else {
            return 0
        }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }

    private static func pointKey(_ point: Vec3) -> String {
        "\(rounded(point.x)):\(rounded(point.y)):\(rounded(point.z))"
    }

    private static func rounded(_ value: Double) -> Double {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return abs(rounded) <= 1.0e-9 ? 0 : rounded
    }
}

/// Fold-line perforation: when `perforate` is on, fold lines are emitted as
/// dash cuts that weaken the material along the crease. Dash length equals
/// the material thickness; dash centers are spaced 2 × dash apart.
enum FoldedPerforation {
    static func dashes(
        start: Vec2,
        end: Vec2,
        materialThickness: Double
    ) -> [FoldedNetFoldEdge] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        let dash = max(materialThickness, 0.1)
        // Edges too short to carry at least one dash + gap stay full cuts.
        guard length > 1.0e-9, length > dash * 2 else {
            return [FoldedNetFoldEdge(start: start, end: end)]
        }
        let ux = dx / length
        let uy = dy / length
        var result: [FoldedNetFoldEdge] = []
        var t = 0.0
        while t < length - 1.0e-9 {
            let tEnd = Swift.min(t + dash, length)
            result.append(FoldedNetFoldEdge(
                start: Vec2(x: start.x + ux * t, y: start.y + uy * t),
                end: Vec2(x: start.x + ux * tEnd, y: start.y + uy * tEnd)
            ))
            t += dash * 2
        }
        return result
    }
}

extension FoldedPanelPlan {
    /// The fold segments the cut-sheet and default consumers (GUI cut sheet,
    /// SVG / PDF / EPS, default DXF) draw: perforation dashes when
    /// `joinery.perforate` is on (the default), full-length hinge segments
    /// otherwise. The single-net DXF fallback does NOT use this — it emits
    /// `plan.foldEdges` unchanged.
    func displayFoldSegments(_ foldEdges: [FoldedNetFoldEdge]) -> [FoldedNetFoldEdge] {
        guard joinery.perforate else {
            return foldEdges
        }
        return foldEdges.flatMap {
            FoldedPerforation.dashes(start: $0.start, end: $0.end, materialThickness: materialThickness)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
