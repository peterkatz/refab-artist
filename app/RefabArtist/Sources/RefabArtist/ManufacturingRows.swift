import Foundation

/// How a Manufacturing Settings row shows for the current construction mode.
enum ManufacturingRowState: Equatable {
    /// The mode reads the value.
    case active
    /// The mode reads the value, but another setting stops it mattering for
    /// now: the row is greyed out with this caption under it.
    case overridden(String)
    /// The mode never reads the value: the row is left out.
    case hidden

    var isShown: Bool { self != .hidden }
    var isEnabled: Bool { self == .active }

    var caption: String? {
        if case .overridden(let caption) = self { return caption }
        return nil
    }
}

/// Which Manufacturing Settings rows each construction mode reads. A row a
/// mode never reads is left out; a row another setting overrides is greyed
/// out with a caption saying which.
enum ManufacturingRows {
    static let notchWidthCaption = "Notch width sets the slot width, so Slot Offset is not used."

    /// Slot Offset is added to the stock for the slot width in Interlocked,
    /// Radial and Curve, and to every slot and open notch a Folded joint
    /// passes a protrusion through. Folded's Laced, Ticked and None joints
    /// cut no such slot (`FoldedJoineryGeometry.readsSlotClearance`), so
    /// there it is greyed out. Stacked and 3D Slices cut no slots.
    /// `foldedJoint` is the Folded Joint Type (nil: not known, read as one
    /// that cuts slots).
    static func slotOffset(
        mode: ConstructionMode,
        notchWidthOn: Bool,
        foldedJoint: JoineryType? = nil
    ) -> ManufacturingRowState {
        switch mode {
        case .interlocked, .curve:
            return notchWidthOn ? .overridden(notchWidthCaption) : .active
        case .radial:
            return .active
        case .foldedPanels:
            guard let foldedJoint, !FoldedJoineryGeometry.readsSlotClearance(foldedJoint) else {
                return .active
            }
            return .overridden(foldedNoSlotCaption(foldedJoint))
        case .stacked, .threeD, .inflatables, .structures, .partition, .motherMold:
            return .hidden
        }
    }

    /// The caption under a greyed-out Slot Offset for a Folded joint that
    /// cuts no slot.
    static func foldedNoSlotCaption(_ joint: JoineryType) -> String {
        if FoldedJoineryGeometry.family(of: joint) == .plain {
            return "Joint Type None cuts no slots, so Slot Offset is not used."
        }
        return "\(joint.label) joints fit nothing into a slot, so Slot Offset is not used."
    }

    /// Tool Dia. sizes the slot relief, which only Interlocked (Slot relief)
    /// and Radial (Relief Type) cut.
    static func toolDiameter(
        mode: ConstructionMode,
        slotReliefOn: Bool,
        radialReliefType: RadialReliefType
    ) -> ManufacturingRowState {
        switch mode {
        case .interlocked:
            return slotReliefOn ? .active : .overridden("Sizes Slot relief, which is off.")
        case .radial:
            return radialReliefType.requiresToolDiameter
                ? .active
                : .overridden("Square relief cuts no circles, so the tool size is not used.")
        case .stacked, .curve, .threeD, .foldedPanels, .inflatables, .structures, .partition, .motherMold:
            return .hidden
        }
    }
}
