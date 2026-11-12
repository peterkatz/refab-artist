import Foundation

/// A UserDefaults suite for one test, removed again by `remove()`.
///
/// The suite is named by an absolute path in a throwaway directory, so the
/// preferences system keeps it in `<path>.plist` there and never in
/// ~/Library/Preferences. (A plain suite name lands there, and the
/// preferences daemon writes an empty plist back some time after the domain
/// is removed, whatever the test deletes.)
struct ThrowawayDefaults {
    let directory: URL
    let name: String
    let defaults: UserDefaults

    init(_ label: String) {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        name = directory.appending(path: "defaults").path
        defaults = UserDefaults(suiteName: name)!
    }

    /// Whether the suite's plist stays out of the user's Preferences folder.
    var staysOutOfUserPreferences: Bool {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences", directoryHint: .isDirectory).path
        return name.hasPrefix("/") && !name.hasPrefix(preferences)
    }

    /// Removes the suite's persistent domain and its plist (the whole
    /// throwaway directory).
    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
}
