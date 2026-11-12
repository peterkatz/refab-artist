import Foundation

enum ViewportSceneBounds {
    static func bounds(
        modelBounds: Bounds3D?,
        foldedPanelPlan: FoldedPanelPlan?,
        inflatablePlan: InflatablesPlan? = nil,
        materialThickness: Double
    ) -> Bounds3D? {
        var combined = modelBounds

        // The folded preview renders the panels at their true 3D position on
        // the (simplified) mesh surface — the assembled, folded-up shape —
        // so the scene already lives within the model's own bounds. Folding
        // the surface points in keeps the camera framing exact even when the
        // simplified hull pokes slightly past the full-resolution bounds.
        if let foldedPanelPlan {
            for surface in foldedPanelPlan.surfaces3D {
                for point in surface {
                    combined = include(point, in: combined)
                }
            }
        }

        if let mesh = inflatablePlan?.preview?.inflatedMesh {
            for point in mesh.vertices {
                combined = include(point, in: combined)
            }
        }

        return combined
    }

    private static func include(_ point: Vec3, in bounds: Bounds3D?) -> Bounds3D {
        guard let bounds else {
            return Bounds3D(min: point, max: point)
        }
        return Bounds3D(
            min: Vec3(
                x: min(bounds.min.x, point.x),
                y: min(bounds.min.y, point.y),
                z: min(bounds.min.z, point.z)
            ),
            max: Vec3(
                x: max(bounds.max.x, point.x),
                y: max(bounds.max.y, point.y),
                z: max(bounds.max.z, point.z)
            )
        )
    }
}
