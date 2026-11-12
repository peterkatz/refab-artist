import Foundation
import simd

/// The generalized winding number w(x) of a triangle set AND its gradient,
/// accurate enough to put points ON a level set {w = c} (Jacobson et al.
/// 2013). `OpeningCapper` shapes each opening's cap on such a level set of
/// the skin: across the skin w jumps by exactly 1, so a level set with
/// 0 < c < 1 bounded by the rim never passes through the skin.
///
/// Same octree as `FastWindingTree`, with two changes for accuracy near the
/// level set:
///  - a cluster is approximated only when the ball holding every corner of
///    its triangles (not just their centroids) looks small from the query
///    point (`extent / distance < beta`);
///  - the far field is second order: the dipole term plus the first-moment
///    correction Σ (cᵢ − c) ⊗ nᵢ, so the error falls as (extent/distance)²
///    instead of linearly.
/// Leaves that are opened are summed exactly, with the gradient of each
/// triangle's solid angle in closed form (the Biot–Savart field of its three
/// edges).
final class WindingLevelField: @unchecked Sendable {
    typealias P = SIMD3<Double>

    private let center: [P]
    private let normalSum: [P]
    /// Σ (cᵢ − center) nᵢᵀ over the node's triangles (nᵢ area-weighted).
    private let moment: [simd_double3x3]
    private let extent: [Double]
    private let firstChild: [Int32]
    private let childCount: [Int32]
    private let children: [Int32]
    private let leafStart: [Int32]
    private let leafCount: [Int32]
    /// Triangle corners in octree order (leaf ranges index these).
    private let ta: [P]
    private let tb: [P]
    private let tc: [P]
    let beta: Double

    var triangleCount: Int { ta.count }

    init(_ soup: TriangleSoup, beta: Double = 0.35) {
        self.beta = beta
        let tree = FastWindingTree(soup)
        let nodes = tree.nodes
        let order = tree.order
        func v(_ q: Vec3) -> P { P(q.x, q.y, q.z) }
        let a = order.map { v(soup.a[Int($0)]) }
        let b = order.map { v(soup.b[Int($0)]) }
        let c = order.map { v(soup.c[Int($0)]) }
        let count = nodes.count
        var centers = [P](repeating: .zero, count: count)
        var normals = [P](repeating: .zero, count: count)
        var moments = [simd_double3x3](repeating: simd_double3x3(0), count: count)
        var extents = [Double](repeating: 0, count: count)
        var first = [Int32](repeating: 0, count: count)
        var childN = [Int32](repeating: 0, count: count)
        var childList: [Int32] = []
        var starts = [Int32](repeating: 0, count: count)
        var counts = [Int32](repeating: 0, count: count)
        for (i, node) in nodes.enumerated() {
            centers[i] = v(node.center)
            normals[i] = v(node.normalSum)
            first[i] = Int32(childList.count)
            childN[i] = Int32(node.children.count)
            childList.append(contentsOf: node.children.map { Int32($0) })
            starts[i] = Int32(node.triStart)
            counts[i] = Int32(node.triCount)
        }
        // Children are created after their parent, so a reverse pass sees
        // every child before its parent.
        for i in stride(from: count - 1, through: 0, by: -1) {
            let o = centers[i]
            var m = simd_double3x3(0)
            var e = 0.0
            if childN[i] == 0 {
                for k in Int(starts[i])..<Int(starts[i] + counts[i]) {
                    let n = 0.5 * simd_cross(b[k] - a[k], c[k] - a[k])
                    let d = (a[k] + b[k] + c[k]) / 3 - o
                    m += simd_double3x3(columns: (d * n.x, d * n.y, d * n.z))
                    e = max(e, simd_length(a[k] - o), simd_length(b[k] - o), simd_length(c[k] - o))
                }
            } else {
                for j in Int(first[i])..<Int(first[i] + childN[i]) {
                    let ch = Int(childList[j])
                    let d = centers[ch] - o
                    let n = normals[ch]
                    m += moments[ch] + simd_double3x3(columns: (d * n.x, d * n.y, d * n.z))
                    e = max(e, extents[ch] + simd_length(d))
                }
            }
            moments[i] = m
            extents[i] = e
        }
        ta = a; tb = b; tc = c
        center = centers
        normalSum = normals
        moment = moments
        extent = extents
        firstChild = first
        childCount = childN
        children = childList
        leafStart = starts
        leafCount = counts
    }

    /// Triangles given directly (corner positions; wound as they should
    /// count: outward for w ≈ 1 inside).
    convenience init(corners: [(P, P, P)], beta: Double = 0.35) {
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        vertices.reserveCapacity(corners.count * 3)
        indices.reserveCapacity(corners.count * 3)
        for (a, b, c) in corners {
            for q in [a, b, c] {
                indices.append(Int32(vertices.count))
                vertices.append(Vec3(x: q.x, y: q.y, z: q.z))
            }
        }
        self.init(TriangleSoup(MeshGeometryData(vertices: vertices, triangleIndices: indices)), beta: beta)
    }

    /// w(p) and ∇w(p): w ≈ 1 inside an outward-wound closed surface and 0
    /// outside, jumping by 1 across the surface.
    func evaluate(_ p: P) -> (w: Double, gradient: P) {
        guard !center.isEmpty else { return (0, .zero) }
        var omega = 0.0
        var grad = P.zero
        var stack: [Int32] = [0]
        stack.reserveCapacity(96)
        let beta2 = beta * beta
        while let top = stack.popLast() {
            let i = Int(top)
            let childN = Int(childCount[i])
            if childN > 0 {
                let r = center[i] - p
                let d2 = simd_length_squared(r)
                let e = extent[i]
                if e * e < beta2 * d2 {
                    let d = d2.squareRoot()
                    let inv3 = 1 / (d2 * d), inv5 = inv3 / d2, inv7 = inv5 / d2
                    let n = normalSum[i]
                    let m = moment[i]
                    let nr = simd_dot(n, r)
                    let mr = m * r
                    let mtr = m.transpose * r
                    let rmr = simd_dot(r, mr)
                    let tr = m[0][0] + m[1][1] + m[2][2]
                    omega += (nr + tr) * inv3 - 3 * rmr * inv5
                    // ∇_p = −∇_r with r = center − p.
                    let radial: Double = 3 * nr * inv5 - 15 * rmr * inv7 + 3 * tr * inv5
                    let sym: P = mr + mtr
                    grad += radial * r
                    grad -= n * inv3
                    grad += (3 * inv5) * sym
                    continue
                }
                let f = Int(firstChild[i])
                for j in f..<(f + childN) { stack.append(children[j]) }
                continue
            }
            let s = Int(leafStart[i])
            for k in s..<(s + Int(leafCount[i])) {
                let a = ta[k] - p, b = tb[k] - p, c = tc[k] - p
                let la = simd_length(a), lb = simd_length(b), lc = simd_length(c)
                if la == 0 || lb == 0 || lc == 0 { continue }
                let num = simd_dot(a, simd_cross(b, c))
                let den = la * lb * lc + simd_dot(a, b) * lc + simd_dot(b, c) * la + simd_dot(c, a) * lb
                omega += 2 * atan2(num, den)
                grad += Self.edgeField(a, la, b, lb) + Self.edgeField(b, lb, c, lc) + Self.edgeField(c, lc, a, la)
            }
        }
        let scale = 1 / (4 * Double.pi)
        return (omega * scale, grad * scale)
    }

    /// Gradient (w.r.t. the query point) of the solid angle of the straight
    /// edge u → v (both relative to the query point).
    @inline(__always) private static func edgeField(_ u: P, _ lu: Double, _ v: P, _ lv: Double) -> P {
        let uv = simd_cross(u, v)
        let n2 = simd_length_squared(uv)
        if n2 <= 1e-30 * lu * lu * lv * lv { return .zero }
        let d = v - u
        return uv * (simd_dot(d, v / lv - u / lu) / n2)
    }

    /// Exact w (every triangle summed): for tests and accuracy checks.
    func exactValue(_ p: P) -> Double {
        var omega = 0.0
        for k in ta.indices {
            let a = ta[k] - p, b = tb[k] - p, c = tc[k] - p
            let la = simd_length(a), lb = simd_length(b), lc = simd_length(c)
            if la == 0 || lb == 0 || lc == 0 { continue }
            let num = simd_dot(a, simd_cross(b, c))
            let den = la * lb * lc + simd_dot(a, b) * lc + simd_dot(b, c) * la + simd_dot(c, a) * lb
            omega += 2 * atan2(num, den)
        }
        return omega / (4 * Double.pi)
    }
}
