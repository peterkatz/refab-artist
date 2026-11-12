enum ConstructionMode: String, CaseIterable, Identifiable, Codable {
    case stacked
    case interlocked
    case radial
    case curve
    case threeD
    case foldedPanels
    case inflatables
    case structures
    case partition
    case motherMold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stacked:
            return "Stacked"
        case .interlocked:
            return "Interlocked"
        case .radial:
            return "Radial"
        case .curve:
            return "Curve"
        case .threeD:
            return "3D Slices"
        case .foldedPanels:
            return "Folded"
        case .inflatables:
            return "Inflatables"
        case .structures:
            return "Structures"
        case .partition:
            return "Partition"
        case .motherMold:
            return "MotherMold"
        }
    }

    /// Structures (Manifold-backed infill/supports) produces a single watertight
    /// mesh, not laser-cut slices. It does NOT use the Slice/dowel/cut-sheet
    /// plumbing; it has its own explicit Generate action and mesh-only export.
    var isStructures: Bool { self == .structures }

    /// Partition cuts the model into bed-sized watertight pieces with keyed
    /// seams. Like Structures it is mesh-only (STL/OBJ) with its own explicit
    /// Generate action and no laser-cut slice/dowel/cut-sheet plumbing.
    var isPartition: Bool { self == .partition }

    /// Still in development. The technique chooser offers it only when
    /// Settings → "Show experimental modes" is on. The headless CLI and the
    /// audit commands always accept it.
    var isExperimental: Bool { self == .inflatables }

    /// The modes the technique chooser offers, in chooser order. An
    /// experimental mode stays listed while it is the current mode (opened
    /// from a project, or the switch turned off while in it), so it keeps
    /// working until the user picks another mode, and the switch itself never
    /// changes the mode.
    static func chooserModes(showingExperimental: Bool, current: ConstructionMode?) -> [ConstructionMode] {
        allCases.filter { !$0.isExperimental || showingExperimental || $0 == current }
    }

    /// Mesh-output-only construction modes: they emit STL/OBJ solids and bypass the
    /// slice/contour/dowel/cut-sheet/DXF plumbing entirely, with their own
    /// explicit Generate action and a mesh-only export path. Structures builds
    /// an infill solid; Partition cuts bed-sized keyed pieces; MotherMold builds
    /// a multi-part casting mold. Inflatables also has an explicit Generate
    /// action, but it still produces flat vector cut sheets, so it is not here.
    var isMeshOnly: Bool {
        switch self {
        case .structures, .partition, .motherMold:
            return true
        case .stacked, .interlocked, .radial, .curve, .threeD, .foldedPanels, .inflatables:
            return false
        }
    }
}
