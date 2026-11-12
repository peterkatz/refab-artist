import SwiftUI

enum AppSettingsKey {
    /// Show experimental construction modes (Inflatables) in the technique
    /// chooser. Off by default.
    static let experimentalFeatures = "refabartist.experimentalFeatures"
}

/// App menu → Settings… (⌘,).
struct AppSettingsView: View {
    @AppStorage(AppSettingsKey.experimentalFeatures) private var experimentalFeaturesEnabled = false

    var body: some View {
        Form {
            Section("Experimental Features") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show experimental modes", isOn: $experimentalFeaturesEnabled)
                    Text("Inflatables is still in development and may not produce usable parts. Turning this off hides it from the technique list; a project already open in Inflatables keeps it until you pick another technique.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
