import Foundation

/// Carries the user's settings over from the app's earlier name.
///
/// Before Refab Artist the app was NeoSlicer: it kept its settings in the
/// `com.neoslicer.app` defaults domain, with `neoslicer.`-prefixed keys for
/// its own settings, and its module was `SlicerRebuildApp`. Refab Artist
/// keeps them in its own domain (`com.refabartist.app`) under the
/// `refabartist.` prefix.
///
/// On the first launch of the renamed app every key of the earlier domain is
/// copied into the new one, once:
/// - `neoslicer.<name>` becomes `refabartist.<name>` (experimental features,
///   collapsed sections, SpaceMouse speed and smoothing, issue markers, the
///   MotherMold section states, ...);
/// - unprefixed settings (`customMaterials`, `viewportAppearance`,
///   `manufacturingDisplayUnit`, the open-panel location, ...) keep their
///   names;
/// - window and split-view state saved under the earlier module name
///   (`SlicerRebuildApp.ContentView`) moves to `RefabArtist.ContentView`.
///
/// A key the new domain already answers is never overwritten, the earlier
/// domain is never changed or deleted, and a marker in the new domain makes
/// the copy run only once, whether or not there was anything to copy.
enum LegacySettingsMigration {
    static let legacyDomain = "com.neoslicer.app"
    static let legacyKeyPrefix = "neoslicer."
    static let keyPrefix = "refabartist."
    static let legacyModulePrefix = "SlicerRebuildApp."
    static let modulePrefix = "RefabArtist."
    /// Set in the new domain once the copy has run.
    static let markerKey = "refabartist.legacySettingsMigrated"

    /// Copies the earlier domain's settings into `defaults` unless the marker
    /// says that already happened. Returns the keys written to `defaults`.
    @discardableResult
    static func migrateIfNeeded(
        into defaults: UserDefaults = .standard,
        legacyDomain: String = legacyDomain
    ) -> [String] {
        guard !defaults.bool(forKey: markerKey) else { return [] }
        let legacyValues = UserDefaults(suiteName: legacyDomain)?
            .persistentDomain(forName: legacyDomain) ?? [:]
        let written = migrate(legacyValues: legacyValues, into: defaults)
        defaults.set(true, forKey: markerKey)
        return written
    }

    /// The key a setting stored under `legacyKey` takes in the new domain.
    static func migratedKey(for legacyKey: String) -> String {
        var key = legacyKey
        if key.hasPrefix(legacyKeyPrefix) {
            key = keyPrefix + key.dropFirst(legacyKeyPrefix.count)
        }
        return key.replacingOccurrences(of: legacyModulePrefix, with: modulePrefix)
    }

    /// Writes every legacy value into `defaults` under its new key, skipping
    /// keys `defaults` already answers. Returns the keys written, sorted.
    static func migrate(legacyValues: [String: Any], into defaults: UserDefaults) -> [String] {
        var written: [String] = []
        for (legacyKey, value) in legacyValues {
            let key = migratedKey(for: legacyKey)
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            written.append(key)
        }
        return written.sorted()
    }
}
