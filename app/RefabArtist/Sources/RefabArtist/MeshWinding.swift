import Foundation

/// Which way a mesh's triangles face, made to agree where they do not, and
/// made to face out.
///
/// Radial and Curve Slices turn every section loop so the model's material
/// lies on its left, as the triangles the loop was cut from face. On a mesh
/// whose triangles wind both ways (two triangles that share an edge and run
/// it the same way), or wind wholly inside out, a loop can then be turned
/// the wrong way, and a hole filled or a solid emptied. `flips` says which
/// triangles to read the other way round: across every edge two triangles
/// share, their windings are made to agree, and on each connected patch the
/// way most of its triangles already wind wins; then, if the mesh so read
/// encloses a negative volume (it faces inward, as an inside-out export
/// does), every triangle is read the other way round. A mesh whose
/// triangles all agree and face out gets nothing flipped. The callers only
/// ask when a section's loops do not come out turned as their nesting says,
/// so every other mesh is cut exactly as before.
final class MeshWinding {
    let triangles: [(Vec3, Vec3, Vec3)]
    private var computed = false
    private var cached: [Bool]?

    init(triangles: [(Vec3, Vec3, Vec3)]) {
        self.triangles = triangles
    }

    /// Per triangle, whether to read it the other way round; nil when every
    /// two triangles that share an edge already run it opposite ways and the
    /// mesh faces out. Worked out once, the first time it is asked for.
    var flips: [Bool]? {
        if !computed {
            cached = Self.consistentFlips(triangles)
            computed = true
        }
        return cached
    }

    private struct EdgeKey: Hashable {
        var low: Int
        var high: Int
    }

    /// See `flips`. Corners at the same position are one vertex; edges used
    /// by one triangle (cracks, holes) or by more than two (non-manifold) do
    /// not link triangles.
    static func consistentFlips(_ triangles: [(Vec3, Vec3, Vec3)]) -> [Bool]? {
        var flip = agreeingFlips(triangles) ?? Array(repeating: false, count: triangles.count)
        // Read so, the mesh must face out: a negative enclosed volume means
        // it faces inward (wound inside out), so every triangle is read the
        // other way round.
        if signedVolume(triangles, flips: flip) < 0 {
            flip = flip.map { !$0 }
        }
        return flip.contains(true) ? flip : nil
    }

    /// The volume the triangles enclose (positive when they face out), with
    /// the triangles `flips` marks read the other way round. Exact for a
    /// closed surface; close to it for one with small cracks.
    static func signedVolume(_ triangles: [(Vec3, Vec3, Vec3)], flips: [Bool]? = nil) -> Double {
        var volume = 0.0
        for (index, triangle) in triangles.enumerated() {
            let (a, b, c) = triangle
            // a · (b × c) / 6: the signed volume of the tetrahedron the
            // triangle spans with the origin.
            let cross = Vec3(
                x: b.y * c.z - b.z * c.y,
                y: b.z * c.x - b.x * c.z,
                z: b.x * c.y - b.y * c.x
            )
            let term = (a.x * cross.x + a.y * cross.y + a.z * cross.z) / 6
            volume += (flips.map { index < $0.count && $0[index] } ?? false) ? -term : term
        }
        return volume
    }

    /// Per triangle, whether to read it the other way round so that every two
    /// triangles sharing an edge agree (on each connected patch the way most
    /// of its triangles wind wins); nil when they all agree already.
    private static func agreeingFlips(_ triangles: [(Vec3, Vec3, Vec3)]) -> [Bool]? {
        var ids: [Vec3: Int] = [:]
        func id(_ point: Vec3) -> Int {
            if let known = ids[point] { return known }
            let next = ids.count
            ids[point] = next
            return next
        }
        // Per edge, the triangles using it and whether each runs it from its
        // lower vertex id to its higher.
        var users: [EdgeKey: [(triangle: Int, forward: Bool)]] = [:]
        for (index, triangle) in triangles.enumerated() {
            let corners = [id(triangle.0), id(triangle.1), id(triangle.2)]
            for k in 0..<3 {
                let (from, to) = (corners[k], corners[(k + 1) % 3])
                guard from != to else { continue }
                users[EdgeKey(low: min(from, to), high: max(from, to)), default: []].append((index, from < to))
            }
        }
        var neighbours = Array(repeating: [(triangle: Int, same: Bool)](), count: triangles.count)
        var mixed = false
        for pair in users.values where pair.count == 2 && pair[0].triangle != pair[1].triangle {
            // Agreeing triangles run their shared edge opposite ways.
            let same = pair[0].forward == pair[1].forward
            mixed = mixed || same
            neighbours[pair[0].triangle].append((pair[1].triangle, same))
            neighbours[pair[1].triangle].append((pair[0].triangle, same))
        }
        guard mixed else { return nil }

        var flip = Array(repeating: false, count: triangles.count)
        var seen = Array(repeating: false, count: triangles.count)
        for seed in triangles.indices where !seen[seed] {
            seen[seed] = true
            var patch = [seed]
            var cursor = 0
            while cursor < patch.count {
                let triangle = patch[cursor]
                cursor += 1
                for (neighbour, same) in neighbours[triangle] where !seen[neighbour] {
                    seen[neighbour] = true
                    // Running the shared edge the same way, the neighbour is
                    // read the other way round from this triangle.
                    flip[neighbour] = same ? !flip[triangle] : flip[triangle]
                    patch.append(neighbour)
                }
            }
            // The way most of the patch's triangles wind wins.
            let flipped = patch.filter { flip[$0] }.count
            if flipped * 2 > patch.count {
                for triangle in patch {
                    flip[triangle].toggle()
                }
            }
        }
        return flip
    }

    /// Whether every loop is turned as its nesting says: counter-clockwise
    /// when it lies inside an even number of the others (an outer
    /// boundary), clockwise when odd (a hole). Loops whose triangles all
    /// agree are always turned so unless shells overlap or nest.
    static func followsNesting(_ loops: [[Vec2]]) -> Bool {
        loops.indices.allSatisfy { index in
            let loop = loops[index]
            guard let probe = loop.first else { return true }
            let depth = loops.indices.filter { other in
                other != index && CutSheetLayoutBuilder.contains(loops[other], point: probe)
            }.count
            return (depth % 2 == 0) == (CutSheetLayoutBuilder.signedArea(loop) > 0)
        }
    }
}
