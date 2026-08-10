import AppKit

/// Moves the app into ~/Applications and restarts from there.
///
/// The login item can only be registered from a stable location, and a build run out of
/// `dist/` is replaced by the next `make build`, so an app that has never been installed
/// simply does not survive a reboot. This turns that from a terminal step into a button.
@MainActor
enum Installer {
    static var destination: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Applications/Claude Deck.app")
    }

    static var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static func installAndRelaunch() {
        let source = Bundle.main.bundleURL
        guard source.path != destination.path else { return }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        } catch {
            Launcher.alert("Could not install Claude Deck", error.localizedDescription)
            return
        }

        // ditto rather than FileManager.copyItem, matching the Makefile: it is the copy
        // that reliably preserves the bundle's code signature, and a broken signature
        // means macOS refuses to launch the copy.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        do {
            try process.run()
        } catch {
            Launcher.alert("Could not install Claude Deck", error.localizedDescription)
            return
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Launcher.alert("Could not install Claude Deck", "ditto exited with status \(process.terminationStatus)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Launcher.alert("Installed, but could not start the copy", error.localizedDescription)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
