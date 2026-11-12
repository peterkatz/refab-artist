import Foundation
import Testing
@testable import RefabArtist

/// The one-time settings carry-over from the earlier app domain. Every test
/// uses throwaway domains, never the real ones.
struct LegacySettingsMigrationTests {
    /// A legacy and a new suite, removed again by `clear()`.
    ///
    /// Each suite is named by an absolute path in a throwaway directory, so
    /// the preferences system keeps it in `<path>.plist` there and never in
    /// ~/Library/Preferences. (A plain suite name lands there, and the
    /// preferences daemon writes an empty plist back some time after the
    /// domain is removed, whatever the test deletes.)
    private struct Suites {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "refabartist-settings-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let legacyName: String
        let targetName: String
        let legacy: UserDefaults
        let target: UserDefaults

        init() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            legacyName = directory.appending(path: "legacy").path
            targetName = directory.appending(path: "target").path
            legacy = UserDefaults(suiteName: legacyName)!
            target = UserDefaults(suiteName: targetName)!
        }

        /// Removes both suites' persistent domains and their plists (the
        /// whole throwaway directory).
        func clear() {
            legacy.removePersistentDomain(forName: legacyName)
            target.removePersistentDomain(forName: targetName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test
    func copiesEverySettingUnderItsNewName() throws {
        let suites = Suites()
        defer { suites.clear() }
        let materials = Data("[{\"name\":\"Birch ply\"}]".utf8)
        let appearance = Data("{\"material\":\"toon\"}".utf8)
        let windowKey = "NSWindow Frame SwiftUI.ModifiedContent<SlicerRebuildApp.ContentView, SwiftUI._FlexFrameLayout>-1-AppWindow-1"
        suites.legacy.set(true, forKey: "neoslicer.experimentalFeatures")
        suites.legacy.set("manufacturing,modifyForm", forKey: "neoslicer.collapsedSections")
        suites.legacy.set(2, forKey: "neoslicer.sectionDefaultsVersion")
        suites.legacy.set(0.8, forKey: "neoslicer.spaceMouseSpeed")
        suites.legacy.set(0.3, forKey: "neoslicer.spaceMouseSmoothing")
        suites.legacy.set(false, forKey: "neoslicer.showIssueMarkers")
        suites.legacy.set(true, forKey: "neoslicer.motherMold.pourVentsExpanded")
        suites.legacy.set(materials, forKey: CustomMaterialStore.defaultsKey)
        suites.legacy.set(appearance, forKey: ViewportAppearanceStore.defaultsKey)
        suites.legacy.set("inches", forKey: "manufacturingDisplayUnit")
        suites.legacy.set("10 20 1200 800 0 0 1440 875 ", forKey: windowKey)

        let written = LegacySettingsMigration.migrateIfNeeded(into: suites.target, legacyDomain: suites.legacyName)

        let target = suites.target
        #expect(target.bool(forKey: AppSettingsKey.experimentalFeatures))
        #expect(target.string(forKey: "refabartist.collapsedSections") == "manufacturing,modifyForm")
        #expect(target.integer(forKey: "refabartist.sectionDefaultsVersion") == 2)
        #expect(target.double(forKey: "refabartist.spaceMouseSpeed") == 0.8)
        #expect(target.double(forKey: "refabartist.spaceMouseSmoothing") == 0.3)
        #expect(target.object(forKey: "refabartist.showIssueMarkers") as? Bool == false)
        #expect(target.bool(forKey: "refabartist.motherMold.pourVentsExpanded"))
        #expect(target.data(forKey: CustomMaterialStore.defaultsKey) == materials)
        #expect(target.data(forKey: ViewportAppearanceStore.defaultsKey) == appearance)
        #expect(target.string(forKey: "manufacturingDisplayUnit") == "inches")
        #expect(target.string(forKey: "NSWindow Frame SwiftUI.ModifiedContent<RefabArtist.ContentView, SwiftUI._FlexFrameLayout>-1-AppWindow-1")
            == "10 20 1200 800 0 0 1440 875 ")
        #expect(target.bool(forKey: LegacySettingsMigration.markerKey))
        #expect(written.count == 11)
        #expect(!written.contains { $0.hasPrefix("neoslicer.") || $0.contains("SlicerRebuildApp.") })

        // The earlier domain is left exactly as it was.
        let legacyAfter = try #require(suites.legacy.persistentDomain(forName: suites.legacyName))
        #expect(legacyAfter.count == 11)
        #expect(legacyAfter["neoslicer.experimentalFeatures"] as? Bool == true)
        #expect(legacyAfter[windowKey] as? String == "10 20 1200 800 0 0 1440 875 ")
    }

    @Test
    func runsOnlyOnceAndNeverOverwritesNewSettings() {
        let suites = Suites()
        defer { suites.clear() }
        suites.legacy.set(0.8, forKey: "neoslicer.spaceMouseSpeed")
        suites.legacy.set("inches", forKey: "manufacturingDisplayUnit")
        suites.target.set("millimeters", forKey: "manufacturingDisplayUnit")

        let first = LegacySettingsMigration.migrateIfNeeded(into: suites.target, legacyDomain: suites.legacyName)
        #expect(first == ["refabartist.spaceMouseSpeed"])
        #expect(suites.target.string(forKey: "manufacturingDisplayUnit") == "millimeters")

        // A later change in either domain is not copied again.
        suites.target.set(0.4, forKey: "refabartist.spaceMouseSpeed")
        suites.legacy.set(true, forKey: "neoslicer.showIssueMarkers")
        let second = LegacySettingsMigration.migrateIfNeeded(into: suites.target, legacyDomain: suites.legacyName)
        #expect(second.isEmpty)
        #expect(suites.target.double(forKey: "refabartist.spaceMouseSpeed") == 0.4)
        #expect(suites.target.object(forKey: "refabartist.showIssueMarkers") == nil)
    }

    @Test
    func marksTheCopyDoneWhenThereIsNoEarlierDomain() {
        let suites = Suites()
        defer { suites.clear() }

        let written = LegacySettingsMigration.migrateIfNeeded(into: suites.target, legacyDomain: suites.legacyName)

        #expect(written.isEmpty)
        #expect(suites.target.bool(forKey: LegacySettingsMigration.markerKey))
        #expect((suites.legacy.persistentDomain(forName: suites.legacyName) ?? [:]).isEmpty)
    }

    @Test
    func testSuitesStayOutOfTheUsersPreferencesFolder() throws {
        let suites = Suites()
        defer { suites.clear() }
        suites.legacy.set(true, forKey: "neoslicer.experimentalFeatures")
        _ = LegacySettingsMigration.migrateIfNeeded(into: suites.target, legacyDomain: suites.legacyName)

        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences", directoryHint: .isDirectory).path
        for name in [suites.legacyName, suites.targetName] {
            #expect(name.hasPrefix("/"))
            #expect(!name.hasPrefix(preferences))
        }
        // The values live in the throwaway directory.
        #expect(suites.target.bool(forKey: AppSettingsKey.experimentalFeatures))
        #expect(suites.legacy.persistentDomain(forName: suites.legacyName)?["neoslicer.experimentalFeatures"] as? Bool == true)
    }

    @Test
    func appSettingsUseTheNewPrefix() {
        #expect(AppSettingsKey.experimentalFeatures == "refabartist.experimentalFeatures")
        #expect(LegacySettingsMigration.migratedKey(for: "neoslicer.experimentalFeatures") == AppSettingsKey.experimentalFeatures)
        #expect(LegacySettingsMigration.migratedKey(for: "customMaterials") == "customMaterials")
        #expect(LegacySettingsMigration.migratedKey(for: "NSOSPLastRootDirectory") == "NSOSPLastRootDirectory")
    }
}
