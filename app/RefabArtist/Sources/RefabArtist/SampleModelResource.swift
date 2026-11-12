import Foundation

enum SampleModelResource {
    static let displayName = "Sample Cube"

    static func url() -> URL? {
        AppResourceBundle.bundle.url(forResource: "cube_ascii", withExtension: "stl", subdirectory: "Samples")
            ?? AppResourceBundle.bundle.url(forResource: "cube_ascii", withExtension: "stl")
    }
}
