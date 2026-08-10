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

    /// Brings the terminal window a session is already running in to the front, matched on
    /// the tty its process is attached to.
    static func focus(pid: Int32, name: String) {
        let iTerm = iTermPath
        Task.detached(priority: .userInitiated) {
            guard let tty = tty(of: pid) else {
                await MainActor.run { notFound(name) }
                return
            }

            var last = Outcome.launched
            for script in focusScripts(tty: tty, iTermPath: iTerm) {
                let (outcome, output) = runCapturing(script)
                if outcome == .launched, output == "ok" { return }
                if outcome != .launched { last = outcome }
            }

            await MainActor.run {
                if last == .launched { notFound(name) } else { present(last) }
            }
        }
    }

    private static func notFound(_ name: String) {
        alert(
            "Could not find the window for \(name)",
            "No iTerm or Terminal window is attached to that session's tty. It is probably running inside tmux, an IDE terminal, or a detached process."
        )
    }

    /// `ps` prints the device without its `/dev/` prefix, and pads the column.
    private nonisolated static func tty(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard !text.isEmpty, text != "??" else { return nil }
        return text.hasPrefix("/dev/") ? text : "/dev/" + text
    }

    private nonisolated static func focusScripts(tty: String, iTermPath: String) -> [String] {
        // Both blocks are addressed by bundle id behind an `is running` guard: telling a
        // terminal by name would launch it, and a session running under tmux or an IDE
        // would then leave a stray empty window behind.
        var scripts: [String] = []
        if FileManager.default.fileExists(atPath: iTermPath) {
            scripts.append("""
            tell application id "com.googlecode.iterm2"
              if it is running then
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is "\(tty)" then
                        activate
                        select w
                        select t
                        select s
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end if
            end tell
            return "notfound"
            """)
        }
        scripts.append("""
        tell application id "com.apple.Terminal"
          if it is running then
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "\(tty)" then
                  activate
                  set frontmost of w to true
                  set selected of t to true
                  return "ok"
                end if
              end repeat
            end repeat
          end if
        end tell
        return "notfound"
        """)
        return scripts
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
        runCapturing(script).outcome
    }

    nonisolated static func runCapturing(_ script: String) -> (outcome: Outcome, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            return (.failed(error.localizedDescription), "")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return (.launched, text) }
        // -1743 is the Automation consent denial.
        let outcome: Outcome = message.contains("-1743")
            ? .automationDenied
            : .failed(message.isEmpty ? "osascript exited with status \(process.terminationStatus)" : message)
        return (outcome, text)
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
