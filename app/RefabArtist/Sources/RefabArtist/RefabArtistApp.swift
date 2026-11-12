import AppKit
import Darwin
import SwiftUI

@main
struct RefabArtistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--folded-audit") {
            do {
                try FoldedAuditCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("folded audit failed: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--radial-audit") {
            do {
                try RadialAuditCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("radial audit failed: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--mesh-audit") {
            do {
                try MeshAuditCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("mesh audit failed: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--dowel-audit") {
            do {
                try DowelAuditCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("dowel audit failed: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.contains("--assembly-audit") {
            do {
                try AssemblyAuditCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
                exit(EXIT_SUCCESS)
            } catch {
                let message = "assembly audit failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(EXIT_FAILURE)
            }
        }
        guard CommandLine.arguments.contains("--headless-export") else {
            // Before any view reads its @AppStorage settings.
            LegacySettingsMigration.migrateIfNeeded()
            return
        }

        do {
            try HeadlessExportCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
            exit(EXIT_SUCCESS)
        } catch {
            let message = "headless export failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Floor raised so the left rail (≥300) + viewport (≥480) can't
                // be squeezed into an unusable strip on launch.
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
        // First-launch size — roomy enough that the rail opens at its ideal
        // width, not its minimum.
        .defaultSize(width: 1600, height: 1000)
        .commands {
            SlicerAppCommands()
        }

        Settings {
            AppSettingsView()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if NSApp.windows.isEmpty {
                self?.showMainWindow()
            }
            self?.normalizeWindowsOnLaunch()
        }
    }

    /// Two launch fixes in one pass:
    ///   1. GROW a too-small restored window to a comfortable default. The
    ///      frame autosave can persist a tiny size from an earlier session, and
    ///      the old code only ever shrank — so it opened cramped and the rail
    ///      got starved (the window opened small, with the left panel too small
    ///      for its contents before anything was done).
    ///   2. CLAMP fully onto the visible screen (autosave can restore a frame
    ///      from a different display arrangement, leaving it partly offscreen).
    /// Both are capped to the visible frame, so this never makes a window
    /// larger than the screen.
    private func normalizeWindowsOnLaunch() {
        for window in NSApp.windows where window.isVisible {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let visible = screen.visibleFrame
            var frame = window.frame

            // 1. Grow to the comfortable default if smaller (capped to screen).
            let target = NSSize(width: min(1600, visible.width * 0.92), height: min(1000, visible.height * 0.92))
            if frame.width < target.width - 1 { frame.size.width = target.width }
            if frame.height < target.height - 1 { frame.size.height = target.height }

            // 2. Clamp into the visible frame and pull fully on-screen.
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)

            if frame != window.frame {
                window.setFrame(frame, display: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Open at a roomy fraction of the screen so the left rail reaches its
        // ideal width and the long MotherMold panel isn't cramped. Capped to a
        // sane max and to the visible screen.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let initialWidth = min(1600, visible.width * 0.92)
        let initialHeight = min(1000, visible.height * 0.92)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Refab Artist"
        window.minSize = NSSize(width: 920, height: 620)
        window.contentViewController = NSHostingController(rootView: ContentView().frame(minWidth: 920, minHeight: 620))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
