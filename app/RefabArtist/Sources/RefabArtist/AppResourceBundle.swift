import Foundation

enum AppResourceBundle {
    private static let bundleName = "RefabArtist_RefabArtist"

    static let bundle: Bundle = {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("\(bundleName).bundle", isDirectory: true)
        if let packagedURL, let bundle = Bundle(url: packagedURL) {
            return bundle
        }

        // SwiftPM keeps the generated resource bundle beside the executable
        // during development and test runs.
        return Bundle.module
    }()
}
