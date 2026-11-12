import Foundation

/// The six dowel cross-sections (the Shape dropdown: Square, Pencil, Round,
/// Cross, Horizontal Slot, Vertical Slot). One
/// outline definition feeds every consumer — DXF, cut-sheet document
/// (preview/SVG/PDF), OBJ/STL hole carving, and the 3D rod pins — so the
/// hole you see is the hole that cuts.
///
/// `diameter` is the overall extent for every shape. The non-round shapes
/// use a hexagonal pencil and d/3 cross arms and slot widths.
enum DowelShape: String, CaseIterable, Codable, Identifiable, Equatable {
    case square
    case pencil
    case round
    case cross
    case horizontalSlot
    case verticalSlot

    var id: String { rawValue }

    /// Display names, in dropdown order.
    var label: String {
        switch self {
        case .square: return "Square"
        case .pencil: return "Pencil"
        case .round: return "Round"
        case .cross: return "Cross"
        case .horizontalSlot: return "Horizontal Slot"
        case .verticalSlot: return "Vertical Slot"
        }
    }

    /// Real-world default size (mm) applied when the shape is selected, so a
    /// Pencil IS pencil-sized out of the box (owner call, 2026-06-11):
    /// a standard hex pencil measures ~7.5 mm across its flats; round/square
    /// stock defaults to the ubiquitous 1/4-inch (6.35 mm) hardware dowel.
    var defaultDiameter: Double {
        switch self {
        case .pencil: return 7.5
        case .round, .square, .cross, .horizontalSlot, .verticalSlot: return 6.35
        }
    }

    /// Closed CLOCKWISE outline (hole winding, matching the mesh builder's
    /// circle polygon), or nil for `.round` — round holes stay true circles
    /// so the existing DXF/SVG circle output is byte-stable.
    func outline(center: Vec2, diameter: Double) -> [Vec2]? {
        let h = diameter / 2
        let t = diameter / 6 // half-width of cross arms and slots
        func at(_ points: [(Double, Double)]) -> [Vec2] {
            points.map { Vec2(x: center.x + $0.0, y: center.y + $0.1) }
        }
        switch self {
        case .round:
            return nil
        case .square:
            return at([(h, h), (h, -h), (-h, -h), (-h, h)])
        case .pencil:
            // Regular hexagon (a pencil's cross-section). Pencils are
            // measured ACROSS FLATS — a "7.5 mm pencil" slides into a hex
            // hole whose flats are 7.5 mm apart — so `diameter` = across
            // flats and the vertices sit at h·2/√3, with a flat facing +x.
            let vertexRadius = h * 2.0 / 3.0.squareRoot()
            return (0..<6).map { index in
                let angle = -(2.0 * Double.pi * Double(index) / 6.0 + Double.pi / 6.0)
                return Vec2(x: center.x + vertexRadius * cos(angle), y: center.y + vertexRadius * sin(angle))
            }
        case .cross:
            return at([
                (t, h), (t, t), (h, t), (h, -t), (t, -t), (t, -h),
                (-t, -h), (-t, -t), (-h, -t), (-h, t), (-t, t), (-t, h)
            ])
        case .horizontalSlot:
            return at([(h, t), (h, -t), (-h, -t), (-h, t)])
        case .verticalSlot:
            return at([(t, h), (t, -h), (-t, -h), (-t, h)])
        }
    }
}
