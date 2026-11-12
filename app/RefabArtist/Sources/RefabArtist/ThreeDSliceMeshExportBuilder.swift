import Foundation

struct SliceMeshExportLayer: Equatable {
    var name: String
    var mesh: ViewportFlatShadedMesh
}

/// 3D Slices = the model cut into contiguous layers along ONE axis, where each
/// layer PRESERVES the model's true 3D surface. It is Stacked's slicing except
/// the side walls follow the real mesh instead of being a flat extrusion of the
/// cross-section, so stacking the layers reconstructs the original model in
/// peel-apart bands. The output is a printable mesh — 3D Slices exports
/// meshes only and never produces flat laser-cut parts.
///
/// (Earlier this built a three-mutually-perpendicular-family interlocking
/// WAFFLE, which was the wrong product: 3D Slices is a smooth model sliced
/// into horizontal layers.)
enum ThreeDSliceMeshExportBuilder {
    static func layers(plan: ThreeDSlicePlan, model: MeshSummary) -> [SliceMeshExportLayer] {
        // 3D Slices is single-axis like Stacked. The legacy plan carries three
        // families; we slice along the Z family's axis (the default
        // horizontal slicing).
        layers(model: model, slicePlan: plan.z)
    }

    static func layers(model: MeshSummary, slicePlan: StackedSlicePlan) -> [SliceMeshExportLayer] {
        guard let bounds = model.bounds else { return [] }
        let axis = slicePlan.axis
        let positions = slicePlan.positions.sorted()
        guard !positions.isEmpty else { return [] }

        let (modelLo, modelHi) = axisRange(bounds, axis: axis)
        guard modelHi - modelLo > 1.0e-9 else { return [] }

        // Contiguous band boundaries that tile the WHOLE model with no gaps: the
        // interior cut planes are the midpoints between consecutive slice centres,
        // and the two outermost bands run all the way to the model's extremes (so
        // the model's own top/bottom surface closes them). One band per slice.
        var boundaries: [Double] = [modelLo]
        for k in 0..<(positions.count - 1) {
            boundaries.append((positions[k] + positions[k + 1]) / 2)
        }
        boundaries.append(modelHi)

        // Cross-section contours at every boundary plane (for capping interior
        // cuts). Reuse the Stacked contourer at exactly the boundary positions.
        let capPlan = StackedSlicePlan(
            axis: axis,
            materialThickness: slicePlan.materialThickness,
            rangeMin: modelLo,
            rangeMax: modelHi,
            positions: boundaries,
            positionsOverride: nil
        )
        let capLayers = StackedSliceContourer.generate(model: model, plan: capPlan).layers

        let triangles = modelTriangles(model)

        var result: [SliceMeshExportLayer] = []
        for k in 0..<(boundaries.count - 1) {
            let lo = boundaries[k]
            let hi = boundaries[k + 1]
            guard hi - lo > 1.0e-9 else { continue }

            var bandTriangles = clipTrianglesToSlab(triangles, axis: axis, lo: lo, hi: hi)

            // Cap interior cut planes only — the model's own surface already
            // closes the top/bottom extremes.
            if lo > modelLo + 1.0e-6, capLayers.indices.contains(k) {
                appendCap(capLayers[k].paths, axis: axis, depth: lo, facingPositive: false, into: &bandTriangles)
            }
            if hi < modelHi - 1.0e-6, capLayers.indices.contains(k + 1) {
                appendCap(capLayers[k + 1].paths, axis: axis, depth: hi, facingPositive: true, into: &bandTriangles)
            }

            guard !bandTriangles.isEmpty else { continue }
            result.append(
                SliceMeshExportLayer(
                    name: String(format: "three_d_%03d", k + 1),
                    mesh: ViewportSliceSolidRenderData.flatShadedMesh(from: bandTriangles)
                )
            )
        }
        return result
    }

    // MARK: - Triangle band clipping

    private static func modelTriangles(_ model: MeshSummary) -> [(Vec3, Vec3, Vec3)] {
        let verts = model.geometry.vertices
        let idx = model.geometry.triangleIndices
        var tris: [(Vec3, Vec3, Vec3)] = []
        tris.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if verts.indices.contains(a), verts.indices.contains(b), verts.indices.contains(c) {
                tris.append((verts[a], verts[b], verts[c]))
            }
            i += 3
        }
        return tris
    }

    /// All model triangles clipped to the slab `lo <= axisCoord <= hi`, keeping
    /// the true surface inside the band. A triangle straddling a plane is cut and
    /// re-triangulated; one fully outside is dropped.
    private static func clipTrianglesToSlab(
        _ triangles: [(Vec3, Vec3, Vec3)],
        axis: SliceAxis,
        lo: Double,
        hi: Double
    ) -> [(Vec3, Vec3, Vec3)] {
        var out: [(Vec3, Vec3, Vec3)] = []
        for tri in triangles {
            let ca = coord(tri.0, axis), cb = coord(tri.1, axis), cc = coord(tri.2, axis)
            let tmin = min(ca, cb, cc), tmax = max(ca, cb, cc)
            if tmax < lo - 1.0e-9 || tmin > hi + 1.0e-9 { continue }      // outside band
            if tmin >= lo - 1.0e-9 && tmax <= hi + 1.0e-9 {                // fully inside
                out.append(tri)
                continue
            }
            var poly = [tri.0, tri.1, tri.2]
            poly = clipHalfSpace(poly, axis: axis, value: lo, keepGreater: true)
            poly = clipHalfSpace(poly, axis: axis, value: hi, keepGreater: false)
            guard poly.count >= 3 else { continue }
            for k in 1..<(poly.count - 1) {
                out.append((poly[0], poly[k], poly[k + 1]))
            }
        }
        return out
    }

    /// Sutherland–Hodgman clip of a 3D polygon against one axis-aligned plane.
    private static func clipHalfSpace(
        _ poly: [Vec3],
        axis: SliceAxis,
        value: Double,
        keepGreater: Bool
    ) -> [Vec3] {
        guard poly.count >= 2 else { return [] }
        func inside(_ p: Vec3) -> Bool {
            keepGreater ? coord(p, axis) >= value - 1.0e-9 : coord(p, axis) <= value + 1.0e-9
        }
        var out: [Vec3] = []
        for i in poly.indices {
            let cur = poly[i]
            let prev = poly[(i + poly.count - 1) % poly.count]
            let curIn = inside(cur), prevIn = inside(prev)
            if curIn {
                if !prevIn { out.append(intersect(prev, cur, axis: axis, value: value)) }
                out.append(cur)
            } else if prevIn {
                out.append(intersect(prev, cur, axis: axis, value: value))
            }
        }
        return out
    }

    private static func intersect(_ a: Vec3, _ b: Vec3, axis: SliceAxis, value: Double) -> Vec3 {
        let ca = coord(a, axis), cb = coord(b, axis)
        let denom = cb - ca
        let t = abs(denom) < 1.0e-12 ? 0 : (value - ca) / denom
        return Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    // MARK: - Caps

    private static func appendCap(
        _ paths: [SlicePath2D],
        axis: SliceAxis,
        depth: Double,
        facingPositive: Bool,
        into triangles: inout [(Vec3, Vec3, Vec3)]
    ) {
        for path in paths {
            guard path.closed else { continue }
            var pts = path.points
            if pts.count >= 4, let f = pts.first, let l = pts.last,
               abs(f.x - l.x) < 1.0e-9, abs(f.y - l.y) < 1.0e-9 {
                pts.removeLast()
            }
            guard pts.count >= 3 else { continue }
            let scene = pts.map { lift($0, axis: axis, depth: depth) }
            for (a, b, c) in ViewportSliceSolidRenderData.triangulate(pts) {
                if facingPositive {
                    triangles.append((scene[a], scene[b], scene[c]))
                } else {
                    triangles.append((scene[a], scene[c], scene[b]))
                }
            }
        }
    }

    // MARK: - Axis helpers

    private static func coord(_ p: Vec3, _ axis: SliceAxis) -> Double {
        switch axis {
        case .x: return p.x
        case .y: return p.y
        case .z: return p.z
        }
    }

    private static func axisRange(_ bounds: Bounds3D, axis: SliceAxis) -> (Double, Double) {
        switch axis {
        case .x: return (bounds.min.x, bounds.max.x)
        case .y: return (bounds.min.y, bounds.max.y)
        case .z: return (bounds.min.z, bounds.max.z)
        }
    }

    private static func lift(_ point: Vec2, axis: SliceAxis, depth: Double) -> Vec3 {
        switch axis {
        case .x:
            return Vec3(x: depth, y: point.x, z: point.y)
        case .y:
            return Vec3(x: point.x, y: depth, z: point.y)
        case .z:
            return Vec3(x: point.x, y: point.y, z: depth)
        }
    }
}
