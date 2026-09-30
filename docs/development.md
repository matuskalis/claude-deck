# Development

## Layout

```
Sources/ClaudeDeck/
  ClaudeDeckApp.swift        app entry and the menu bar item
  SessionStore.swift         the one observable store the UI reads
  Models.swift               session files, hook events, the Session value
  ProcessCheck.swift         is this pid the process the file says it is
  TranscriptTail.swift       newest assistant message, read from the end
  Stats.swift                token counts, prices, lifetime top-up
  Usage.swift                plan limits and the forecast
  Jobs.swift                 background jobs
  Activity.swift             CPU, memory and disk for the Machine row
  Changelog.swift, News.swift, Wifi.swift
  EventsSpool.swift          tails for hook events and for history.jsonl
  HookInstaller.swift        the settings.json splice and the spool helper
  Launcher.swift, Installer.swift, Notifier.swift, DirWatcher.swift
  Demo.swift                 demo mode and the panel renderer
  UI/                        MenuContent and one file per section
Tests/ClaudeDeckTests/       Swift Testing, one suite per area
Support/Info.plist           bundle identifier and version
scripts/demo.sh              demo mode, see demo.md
```

## Build and run

```sh
swift build          # debug build
swift test           # 192 tests, 3 seconds on CI
make build           # release build, assembles dist/Claude Deck.app, signs it ad hoc
make install         # build, then copy to ~/Applications/Claude Deck.app with ditto
make clean
```

Launch the app bundle, never `.build/release/ClaudeDeck` directly. `UNUserNotificationCenter` needs a real bundle identifier, and a bare SwiftPM binary exits at launch with `bundleProxyForCurrentProcess is nil` from `SessionStore.init` (checked on 30 Sep 2026). The Makefile assembles the `.app` (`Info.plist`, `PkgInfo`, an ad-hoc signature) around the built binary. The app is `LSUIElement`, so it has no Dock icon or window.

`make install` uses `ditto` because it is the copy that reliably preserves the code signature, and a broken signature means macOS refuses to launch the result. Run into a throwaway home on 30 Sep 2026 it produced a bundle with a valid signature, version 1.11.0, and no quarantine attribute, which is why a locally built copy is not stopped by Gatekeeper.

**`make run` runs `pkill -x ClaudeDeck` first.** That stops every running instance, including an installed copy. Quit the one you want to keep, or use `scripts/demo.sh`, which starts a separate instance.

There is no signed download and none is planned. The bundle is ad-hoc signed, which is enough for local use and not enough to distribute.

## Tests

192 tests in 21 suites, written with Swift Testing. They are about the parts that would be wrong without anyone noticing.

| Area | What is pinned |
|---|---|
| Cost | each token kind's rate, cache multipliers, model id matching, the price file, the burn rate and its floor |
| Transcripts | one count per request, forks, lines with no id, partial lines, rewrites, the lifetime top-up, the backwards context scan with a line cut by a chunk boundary and the 2 MB give-up |
| Plan limits | parsing, dates with six, three and no fractional digits, severity, every condition under which the forecast stays silent, the history file |
| Jobs, changelog, spools, history | what counts as blocked, ordering, what is dropped, where each cursor is after a partial line, a truncation or a rotation |
| Safety | what is dormant, pid identity against the recorded start time, launcher quoting run through `/bin/sh` |
| Hooks | the splice across layouts (exact in the usual ones, lossless in all), refusals, symlinks, the backup, the timeout, and what the helper does with hostile text: escaping, the 200 character cap, control characters, fields it must never keep, rotation |
| News | the prompt, the topics file, the environment, pulling the list out of prose, old caches |
| Machine | the mach-tick conversion against the wall clock, CPU against `getrusage`, the footprint |
| Demo mode | what counts as a demo, the redirect check, the refresh switch |

Not covered: the SwiftUI views (they are looked at, see [Demo mode](demo.md)), `SessionStore` (its notifier talks to `UNUserNotificationCenter`, which needs an app bundle), the actual `osascript` calls, the notification banners, `Installer`, and the `claude -p` run behind News, which spends plan usage.

### A home directory of their own

The app reads `NSHomeDirectory()/.claude`, and several readers cache that path in a static the first time they use it. So a test that writes fixtures has to move the home, and on macOS `HOME` does not do it. `CFFIXED_USER_HOME` does, and it is read on every call.

Each suite that writes fixtures calls `Hermetic.reset()` from its `init`, which Swift Testing runs before every test. It points `NSHomeDirectory()` at a temporary directory, empties it, points `EventsSpool.directory` and `HookInstaller.settingsURL` into it, and throws before the test body runs if the redirect did not take. The directory is deleted when the run ends. Nothing a test does can reach your real `~/.claude`.

Suites that redirect those two process-global paths sit under `DeckTests`, which is serialized. Swift Testing runs suites in parallel with each other even when each is serialized inside, so two of them pointing the paths at their own folders would interleave.

A custom `SuiteTrait` would be the tidier way to apply the redirect to a whole tree, but the Swift 6.4 toolchain's test runner traps while planning any custom suite trait (checked with a trait that does nothing), so the call is explicit.

### Checked by breaking the code

Passing tests prove little until they have failed once. On 30 Sep 2026 three behaviours were broken on purpose and the intended tests failed each time: keeping the first line of a message instead of the last, billing cache reads at the full input rate, and reading mach ticks as nanoseconds.

The CPU test compares the reader against `getrusage` over the same window instead of asserting a fixed percentage. A busy loop is given only as much of the machine as the machine has to spare, and on a loaded laptop that was 8%.

## CI

`.github/workflows/build.yml` runs on pushes to `main` and on pull requests, on `macos-latest`. It selects the newest Xcode on the image, because the package needs Swift 6.2, then runs `swift test`, `make build`, and checks that the bundle came out whole: the executable, the `Info.plist`, and `codesign --verify`.

## Releases

Releases are GitHub releases on tags named `vX.Y.Z` (v1.1.0 to v1.11.0 so far), each with notes and no attached binary. The version in the panel header is read from `CFBundleShortVersionString` in `Support/Info.plist`, so it cannot drift from the bundle.
