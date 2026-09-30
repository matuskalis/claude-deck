import Foundation
import Testing

@testable import ClaudeDeck

/// Demo mode points the app at invented data, so what it must never do is run against the
/// real one by mistake, or spend plan usage while pretending.
extension DeckTests {
    @Suite struct DemoModeTests {
        init() throws {
            try Hermetic.reset()
            unsetenv("CLAUDE_DECK_DEMO_HOME")
            unsetenv("CLAUDE_DECK_SNAPSHOT")
        }

        private static func inDemo(home: String, _ body: () async throws -> Void) async throws {
            setenv("CLAUDE_DECK_DEMO_HOME", home, 1)
            defer { unsetenv("CLAUDE_DECK_DEMO_HOME") }
            try await body()
        }

        @Test("nothing is a demo unless the variable is set and not empty")
        func offByDefault() {
            #expect(!Demo.isActive)
            setenv("CLAUDE_DECK_DEMO_HOME", "", 1)
            defer { unsetenv("CLAUDE_DECK_DEMO_HOME") }
            #expect(!Demo.isActive)
        }

        @Test("a snapshot is only ever taken inside a demo")
        func snapshotNeedsADemo() async throws {
            setenv("CLAUDE_DECK_SNAPSHOT", "/tmp/somewhere", 1)
            defer { unsetenv("CLAUDE_DECK_SNAPSHOT") }
            #expect(Demo.snapshotDirectory == nil)

            try await Self.inDemo(home: Hermetic.root.path) {
                #expect(Demo.snapshotDirectory == "/tmp/somewhere")
            }
        }

        @Test("the redirect check passes for the home the app sees, and for nothing else")
        func redirectCheck() async throws {
            // Outside a demo there is nothing to check.
            #expect(Demo.homeIsRedirected)

            try await Self.inDemo(home: Hermetic.root.path) {
                #expect(Demo.homeIsRedirected)
            }
            // A symlinked spelling of the same folder is the same home.
            let link = Hermetic.root.deletingLastPathComponent().appending(path: "claude-deck-link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Hermetic.root)
            defer { try? FileManager.default.removeItem(at: link) }
            try await Self.inDemo(home: link.path) {
                #expect(Demo.homeIsRedirected)
            }
            // Anywhere else means CFFIXED_USER_HOME did not take, and the app must quit.
            try await Self.inDemo(home: "/definitely/not/the/home") {
                #expect(!Demo.homeIsRedirected)
            }
        }

        @Test("in a demo the Wi-Fi link and the free disk space are invented, not the machine's")
        func machineReadingsAreInvented() async throws {
            try await Self.inDemo(home: Hermetic.root.path) {
                let wifi = WifiStatus.read()
                #expect(wifi == Demo.wifi)
                #expect(wifi.present && wifi.connected)
                #expect(wifi.label == "good")

                let machine = await ActivityReader().sample(sessions: [])
                #expect(machine.freeBytes == Demo.freeBytes)
            }
        }

        @Test("outside a demo the free disk space is measured")
        func machineReadingsAreMeasured() async {
            let machine = await ActivityReader().sample(sessions: [])
            #expect(machine.freeBytes > 0)
            #expect(machine.freeBytes != Demo.freeBytes)
        }

        @Test("the tab a snapshot renders is set in the argument domain, which overrides what is saved")
        func tabOverrideDoesNotNeedSaving() {
            let defaults = UserDefaults.standard
            // removeVolatileDomain does not clear the argument domain; an empty one does.
            defaults.setVolatileDomain(["menu.tab": "usage"], forName: UserDefaults.argumentDomain)
            defer { defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain) }
            #expect(defaults.string(forKey: "menu.tab") == "usage")

            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            #expect(defaults.string(forKey: "menu.tab") == nil)
        }

        @Test("the news refresh refuses in a demo, before it goes looking for claude")
        func newsRefreshIsOffInADemo() async throws {
            try await Self.inDemo(home: Hermetic.root.path) {
                await #expect(throws: NewsStore.RefreshError.self) {
                    try await NewsStore().refresh(generatedAt: Date())
                }
            }
        }
    }
}
