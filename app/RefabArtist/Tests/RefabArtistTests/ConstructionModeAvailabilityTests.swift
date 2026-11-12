import Testing
@testable import RefabArtist

struct ConstructionModeAvailabilityTests {
    @Test
    func onlyInflatablesIsExperimental() {
        let experimental = ConstructionMode.allCases.filter(\.isExperimental)

        #expect(experimental == [.inflatables])
    }

    @Test
    func chooserHidesExperimentalModesWhenSwitchIsOff() {
        let modes = ConstructionMode.chooserModes(showingExperimental: false, current: nil)

        #expect(modes == ConstructionMode.allCases.filter { $0 != .inflatables })
    }

    @Test
    func chooserOffersEveryModeInOrderWhenSwitchIsOn() {
        let modes = ConstructionMode.chooserModes(showingExperimental: true, current: nil)

        #expect(modes == ConstructionMode.allCases)
    }

    @Test
    func currentExperimentalModeStaysListedWhenSwitchIsOff() {
        // A project saved in Inflatables, or the switch turned off while in it.
        let modes = ConstructionMode.chooserModes(showingExperimental: false, current: .inflatables)

        #expect(modes == ConstructionMode.allCases)
    }

    @Test
    func experimentalModeDropsOutOnceAnotherModeIsCurrent() {
        for mode in ConstructionMode.allCases where !mode.isExperimental {
            let modes = ConstructionMode.chooserModes(showingExperimental: false, current: mode)

            #expect(!modes.contains(.inflatables))
            #expect(modes.contains(mode))
        }
    }
}
