import Testing
@testable import RefabArtist

/// Which Manufacturing Settings rows each mode reads, and which another
/// setting overrides.
struct ManufacturingRowsTests {
    @Test
    func slotOffsetShowsOnlyWhereSlotsAreCut() {
        for mode in [ConstructionMode.radial, .foldedPanels] {
            #expect(ManufacturingRows.slotOffset(mode: mode, notchWidthOn: false) == .active)
            // Neither mode has a notch-width override.
            #expect(ManufacturingRows.slotOffset(mode: mode, notchWidthOn: true) == .active)
        }
        for mode in [ConstructionMode.interlocked, .curve] {
            #expect(ManufacturingRows.slotOffset(mode: mode, notchWidthOn: false) == .active)
            let overridden = ManufacturingRows.slotOffset(mode: mode, notchWidthOn: true)
            #expect(!overridden.isEnabled && overridden.isShown)
            #expect(overridden.caption == ManufacturingRows.notchWidthCaption)
        }
        for mode in [ConstructionMode.stacked, .threeD] {
            #expect(ManufacturingRows.slotOffset(mode: mode, notchWidthOn: false) == .hidden)
        }
    }

    @Test
    func foldedSlotOffsetIsLiveOnlyForJointsThatCutSlots() {
        // Slots and open notches for a protrusion take the offset.
        for joint in [JoineryType.tab, .diamond, .multitab, .tongue, .rivet, .gear, .puzzle] {
            #expect(FoldedJoineryGeometry.readsSlotClearance(joint), "\(joint)")
            #expect(ManufacturingRows.slotOffset(mode: .foldedPanels, notchWidthOn: false, foldedJoint: joint) == .active, "\(joint)")
        }
        // Lace holes, tick notches and plain edges never read it: greyed
        // out, with a caption naming the joint.
        for joint in [JoineryType.laced, .ticked, .trivial, .seam] {
            #expect(!FoldedJoineryGeometry.readsSlotClearance(joint), "\(joint)")
            let state = ManufacturingRows.slotOffset(mode: .foldedPanels, notchWidthOn: false, foldedJoint: joint)
            #expect(state.isShown && !state.isEnabled, "\(joint)")
            #expect(state.caption == ManufacturingRows.foldedNoSlotCaption(joint))
        }
        #expect(ManufacturingRows.foldedNoSlotCaption(.laced) == "Laced joints fit nothing into a slot, so Slot Offset is not used.")
        #expect(ManufacturingRows.foldedNoSlotCaption(.ticked) == "Ticked joints fit nothing into a slot, so Slot Offset is not used.")
        #expect(ManufacturingRows.foldedNoSlotCaption(.trivial) == "Joint Type None cuts no slots, so Slot Offset is not used.")
        // The joint type only matters in Folded.
        #expect(ManufacturingRows.slotOffset(mode: .radial, notchWidthOn: false, foldedJoint: .laced) == .active)
    }

    @Test
    func toolDiameterShowsOnlyWhereReliefIsCut() {
        #expect(ManufacturingRows.toolDiameter(mode: .interlocked, slotReliefOn: true, radialReliefType: .square) == .active)
        let reliefOff = ManufacturingRows.toolDiameter(mode: .interlocked, slotReliefOn: false, radialReliefType: .dogBone)
        #expect(reliefOff.isShown && !reliefOff.isEnabled && reliefOff.caption != nil)

        #expect(ManufacturingRows.toolDiameter(mode: .radial, slotReliefOn: false, radialReliefType: .dogBone) == .active)
        let square = ManufacturingRows.toolDiameter(mode: .radial, slotReliefOn: true, radialReliefType: .square)
        #expect(square.isShown && !square.isEnabled && square.caption != nil)

        for mode in [ConstructionMode.stacked, .curve, .threeD, .foldedPanels] {
            #expect(ManufacturingRows.toolDiameter(mode: mode, slotReliefOn: true, radialReliefType: .dogBone) == .hidden)
        }
    }

    @Test
    func savedMaterialsMatchOnThePageMargin() {
        let material = CustomMaterial(
            name: "Birch",
            thickness: 6,
            slotClearance: 0.2,
            sheetWidth: 600,
            sheetHeight: 300,
            kerf: 0.2,
            toolDiameter: 3.175,
            horizontalMargin: 5,
            verticalMargin: 7
        )
        #expect(material.matches(thickness: 6, slotClearance: 0.2, sheetWidth: 600, sheetHeight: 300, kerf: 0.2, toolDiameter: 3.175, pageMargin: 5))
        #expect(!material.matches(thickness: 6, slotClearance: 0.2, sheetWidth: 600, sheetHeight: 300, kerf: 0.2, toolDiameter: 3.175, pageMargin: 7))
        #expect(!material.matches(thickness: 6, slotClearance: 0.2, sheetWidth: 600, sheetHeight: 300, kerf: 0.2, toolDiameter: 6, pageMargin: 5))
    }
}
