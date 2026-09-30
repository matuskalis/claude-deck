import AppKit
import SwiftUI

/// Demo mode is how the app is photographed, and how anyone can try it without a Claude Code
/// history on the machine.
///
/// `scripts/demo.sh` builds a throwaway home directory of invented sessions, jobs and usage
/// figures, then starts this app against it. Two variables do that:
///
/// - `CFFIXED_USER_HOME` moves `NSHomeDirectory()`, and with it every path the app reads.
///   `HOME` does not; on macOS only this one does. It does not move saved preferences:
///   cfprefsd ignores it. `scripts/demo.sh` therefore gives the demo copy of the app a
///   bundle identifier of its own, and the snapshot sets its tab where nothing is saved.
/// - `CLAUDE_DECK_DEMO_HOME` says this is a demo, and names the directory the app must see.
///   If `NSHomeDirectory()` is anywhere else the redirect did not take, and the app quits
///   before its store reads a file, rather than show or disturb the real thing.
///
/// A demo run posts no notifications and never starts `claude`, so nothing in it can spend
/// plan usage or interrupt anyone. The two readings that would otherwise come from the
/// machine doing the rendering, the Wi-Fi link and free disk space, are invented values, so
/// a picture of a demo says nothing about anyone's network or disk.
enum Demo {
    static let wifi = WifiStatus(present: true, connected: true, rssi: -58, noise: -92, transmitRate: 780)
    static let freeBytes = 412 * 1_073_741_824

    static var home: String? {
        guard let value = getenv("CLAUDE_DECK_DEMO_HOME") else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    static var isActive: Bool { home != nil }

    /// Where `scripts/demo.sh --snapshot` wants the PNGs, when it does.
    static var snapshotDirectory: String? {
        guard isActive, let value = getenv("CLAUDE_DECK_SNAPSHOT") else { return nil }
        return String(cString: value)
    }

    static var homeIsRedirected: Bool {
        guard let home else { return true }
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        return canonical(NSHomeDirectory()) == canonical(home)
    }
}

extension AppDelegate {
    /// Runs before `applicationDidFinishLaunching`, which is where the store starts reading.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Demo.isActive else { return }
        guard Demo.homeIsRedirected else {
            FileHandle.standardError.write(Data("Claude Deck: demo mode needs CFFIXED_USER_HOME set to CLAUDE_DECK_DEMO_HOME. Quitting before anything is read.\n".utf8))
            exit(EX_CONFIG)
        }
        if let directory = Demo.snapshotDirectory {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Snapshot.settleSeconds))
                do {
                    try await Snapshot.write(store: store, into: URL(fileURLWithPath: directory))
                } catch {
                    FileHandle.standardError.write(Data("Claude Deck: snapshot failed: \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// Renders the real menu panel, bound to the real store, to PNG files. Nothing is shown on
/// screen and nothing is captured from it: each panel is hosted in a window far outside any
/// display and drawn by AppKit into a bitmap, so what is in the picture is the app's own
/// views and nothing behind them.
///
/// The one thing it cannot reproduce is the translucent popover material the system puts
/// behind the panel, which is replaced by a flat colour of roughly the same value.
@MainActor
enum Snapshot {
    static let settleSeconds: Double = getenv("CLAUDE_DECK_SNAPSHOT_DELAY").flatMap { Double(String(cString: $0)) } ?? 8

    private static let scale: CGFloat = 2
    private static let margin: CGFloat = 40
    private static let corner: CGFloat = 12

    private final class OffscreenWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    private struct Look {
        var name: String
        var appearance: NSAppearance.Name
        var panel: NSColor
        var ground: NSColor
    }

    private static let looks = [
        Look(name: "dark", appearance: .darkAqua, panel: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1), ground: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.086, alpha: 1)),
        Look(name: "light", appearance: .aqua, panel: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1), ground: NSColor(srgbRed: 0.878, green: 0.886, blue: 0.902, alpha: 1)),
    ]

    static func write(store: SessionStore, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for look in looks {
            var panels: [NSBitmapImageRep] = []
            for tab in [MenuContent.Tab.sessions, .usage] {
                // The argument domain wins over saved preferences and is never written to disk,
                // so a snapshot cannot change what any copy of the app remembers.
                UserDefaults.standard.setVolatileDomain(["menu.tab": tab.rawValue], forName: UserDefaults.argumentDomain)
                panels.append(await render(store: store, look: look))
            }
            UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            let data = try compose(panels, look: look)
            try data.write(to: directory.appending(path: "hero-\(look.name).png"))
        }
    }

    private static func render(store: SessionStore, look: Look) async -> NSBitmapImageRep {
        let root = MenuContent(store: store).background(Color(nsColor: look.panel))
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: look.appearance)

        let window = OffscreenWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 360, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        // Long enough for onAppear to run and the store's first reads to land.
        try? await Task.sleep(for: .seconds(2))

        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(0.6))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// The panels side by side on a flat ground, each with the rounded corners and hairline
    /// edge the real popover has.
    private static func compose(_ panels: [NSBitmapImageRep], look: Look) throws -> Data {
        let height = panels.map { CGFloat($0.pixelsHigh) }.max() ?? 0
        let width = panels.reduce(margin * scale) { $0 + CGFloat($1.pixelsWide) + margin * scale }
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height + 2 * margin * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        look.ground.setFill()
        NSRect(x: 0, y: 0, width: canvas.pixelsWide, height: canvas.pixelsHigh).fill()

        var x = margin * scale
        for panel in panels {
            let frame = NSRect(x: x, y: margin * scale + (height - CGFloat(panel.pixelsHigh)), width: CGFloat(panel.pixelsWide), height: CGFloat(panel.pixelsHigh))
            let shape = NSBezierPath(roundedRect: frame, xRadius: corner * scale, yRadius: corner * scale)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 18 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
            shadow.set()
            look.panel.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            panel.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()

            (look.name == "dark" ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.14)).setStroke()
            shape.lineWidth = scale * 0.75
            shape.stroke()

            x += CGFloat(panel.pixelsWide) + margin * scale
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = canvas.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
