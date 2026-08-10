import AppKit

/// Opens a terminal window in a project directory and starts Claude Code in it.
@MainActor
enum Launcher {
    /// Overridden by the verification harness to exercise the Terminal.app fallback.
    static var iTermPath = "/Applications/iTerm.app"

    static func launch(directory: String, resume: Bool) {
        let script = script(directory: directory, resume: resume)
        Task.detached(priority: .userInitiated) {
            let outcome = run(script)
            await MainActor.run { present(outcome) }
        }
    }

    static func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Launch Here"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Script

    static func script(directory: String, resume: Bool) -> String {
        let command = "cd '\(shellEscaped(directory))' && claude\(resume ? " -c" : "")"
        let literal = appleScriptEscaped(command)

        if FileManager.default.fileExists(atPath: iTermPath) {
            return """
            tell application "iTerm"
              activate
              set w to (create window with default profile)
              tell current session of w to write text "\(literal)"
            end tell
            """
        }
        return """
        tell application "Terminal"
          do script "\(literal)"
          activate
        end tell
        """
    }

    /// The path sits in single quotes inside a shell command, which in turn sits inside
    /// an AppleScript string literal, so both layers have to be escaped.
    private static func shellEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Running

    enum Outcome: Sendable, Equatable {
        case launched
        case automationDenied
        case failed(String)
    }

    nonisolated static func run(_ script: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return .launched }
        // -1743 is the Automation consent denial.
        return message.contains("-1743") ? .automationDenied : .failed(message.isEmpty ? "osascript exited with status \(process.terminationStatus)" : message)
    }

    static func present(_ outcome: Outcome) {
        switch outcome {
        case .launched:
            return
        case .automationDenied:
            alert(
                "Claude Deck is not allowed to control your terminal",
                "Open System Settings → Privacy & Security → Automation, expand Claude Deck and switch on iTerm (or Terminal), then try again."
            )
        case .failed(let message):
            alert("Could not open a terminal window", message)
        }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
