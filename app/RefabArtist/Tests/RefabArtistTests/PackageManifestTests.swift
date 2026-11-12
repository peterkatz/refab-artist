import Foundation
import Testing

struct PackageManifestTests {
    @Test
    func packageRequiresMacOS15ForRealityKitViewport() throws {
        let manifest = try String(contentsOf: Self.repoRoot().appending(path: "Package.swift"), encoding: .utf8)

        #expect(manifest.contains(".macOS(.v15)"))
    }

    @Test
    func packageScriptCopiesSwiftPMResourceBundle() throws {
        let script = try String(
            contentsOf: Self.repoRoot()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "tools/package_app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("RefabArtist_RefabArtist.bundle"))
        #expect(script.contains("Contents/Resources/RefabArtist_RefabArtist.bundle"))
        #expect(script.contains("codesign --verify --deep --strict"))
    }

    /// The settings carry-over (LegacySettingsMigration) writes to the domain
    /// of the packaged app, so its bundle identifier must not drift.
    @Test
    func packageScriptNamesTheAppRefabArtist() throws {
        let script = try String(
            contentsOf: Self.repoRoot()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "tools/package_app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("APP_DIR=\"$BUILD_DIR/Refab Artist.app\""))
        #expect(script.contains("<key>CFBundleIdentifier</key>\n  <string>com.refabartist.app</string>"))
        #expect(script.contains("<key>CFBundleName</key>\n  <string>Refab Artist</string>"))
        #expect(script.contains("<key>CFBundleDisplayName</key>\n  <string>Refab Artist</string>"))
        #expect(script.contains("<key>CFBundleExecutable</key>\n  <string>RefabArtist</string>"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
