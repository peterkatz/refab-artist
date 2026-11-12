enum InspectorPanelSection: String, CaseIterable, Identifiable {
    case actions
    case model
    case viewport
    case manufacturing
    case scale
    /// Modify Form: Hollow / Thicken / Shrinkwrap (whole-model mesh ops).
    /// Sits after Object Size, before Construction Technique.
    case modifyForm
    case construction
    /// Structures (Manifold infill) parameters — shown only in Structures mode,
    /// directly below Construction Technique.
    case structures
    /// MotherMold (casting-mold) parameters — shown only in MotherMold mode,
    /// directly below Construction Technique.
    case motherMold
    case constructionSettings
    case sliceDirection
    /// Dowels — its own pane (Stacked only), after Slice Direction so the cut
    /// direction is chosen before placing rods.
    case dowels
    case assembly
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions:
            return "Actions"
        case .model:
            return "Model"
        case .viewport:
            return "Viewport Look"
        case .manufacturing:
            return "Manufacturing Settings"
        case .scale:
            return "Object Size"
        case .modifyForm:
            return "Modify Form"
        case .construction:
            return "Construction Technique"
        case .structures:
            return "Structures"
        case .motherMold:
            return "MotherMold"
        case .constructionSettings:
            return "Technique Settings"
        case .sliceDirection:
            return "Slice Direction"
        case .dowels:
            return "Dowels"
        case .assembly:
            return "Assembly"
        case .export:
            return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .actions:
            return "bolt.horizontal"
        case .model:
            return "shippingbox"
        case .viewport:
            return "camera.aperture"
        case .manufacturing:
            return "gearshape"
        case .scale:
            return "arrow.up.left.and.arrow.down.right"
        case .modifyForm:
            return "wand.and.stars"
        case .construction:
            return "square.stack.3d.up"
        case .structures:
            return "cube.transparent"
        case .motherMold:
            return "shippingbox.and.arrow.backward"
        case .constructionSettings:
            return "slider.horizontal.3"
        case .sliceDirection:
            return "scope"
        case .dowels:
            return "cylinder"
        case .assembly:
            return "list.bullet.rectangle"
        case .export:
            return "square.and.arrow.up"
        }
    }

    var accessibilityLabel: String {
        "\(title) inspector section"
    }

    static let emptyModelOrder: [InspectorPanelSection] = [
        .actions,
        .model,
    ]

    // Left control rail (model stats now live in a separate right-side panel).
    static let loadedModelOrder: [InspectorPanelSection] = [
        .actions,
        .construction,
        .structures,
        .motherMold,
        .manufacturing,
        .constructionSettings,
        .sliceDirection,
        .dowels,
        .assembly,
        .export,
    ]
}
