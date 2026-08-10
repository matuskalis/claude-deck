# Claude Deck

A macOS menu bar app that shows every running Claude Code CLI session, what it is doing
right now, how full its context window is, what today has cost, and notifies you when a
session finishes or blocks on a permission prompt. It also starts new sessions for you.

```
┌──────────────────────────────────────────┐
│ Claude Deck                    2 busy    │
│ ◐ shiftfix        waiting: Bash approval │
│ ● fix-shorts-watermark…   busy 4m12s 72% │
│   ~/projects/shorts-engine  "fix the…"   │
│ ○ matuskalis-4d              idle    31% │
│──────────────────────────────────────────│
│ Today  6 sessions · 1.2M tok · ~$4.10 est│
│ Lifetime 239 sessions · 6.8B  Jul 20+live│
│──────────────────────────────────────────│
│ Launch Claude in…                        │
│   shorts-engine          [New] [Continue]│
│   Browse folder…                         │
│──────────────────────────────────────────│
│ ✓ Hooks installed        [Reinstall]     │
│ Launch at login ☐              Quit ⌘Q   │
└──────────────────────────────────────────┘
```

Swift 6.2, SwiftUI `MenuBarExtra`, one SwiftPM executable target, no external dependencies.

## Build and run

```sh
make build     # swift build -c release, then assemble dist/Claude Deck.app
make run       # build + open "dist/Claude Deck.app"
make install   # build + ditto to ~/Applications/Claude Deck.app
make clean
```

Always launch the app bundle, never `.build/release/ClaudeDeck` directly:
`UNUserNotificationCenter` requires a real bundle identifier and traps in a bare SwiftPM
binary. The Makefile assembles the `.app` (Info.plist, PkgInfo, ad-hoc code signature)
around the built binary.

The app is `LSUIElement`, so it has no Dock icon or window; everything lives in the
menu bar item.

## Notifications

On first launch the app asks for notification permission. If macOS has already recorded
a denial for the bundle id, `requestAuthorization` fails silently with
"Notifications are not allowed for this application" and no banner will ever appear. The
menu detects that state and shows an "Open Settings" button that jumps to
System Settings › Notifications.

| Trigger | Notification |
|---|---|
| a session blocks on a permission prompt | `⏸ <project> needs you`, replaced per session, repeats suppressed within 5s, removed once the session moves on |
| a session finishes after being busy ≥ 10s | `✅ <name> finished` |

The 10 second floor exists so that two-second replies do not produce banner noise.

## Quick launch

The launcher lists the last eight project directories from `~/.claude/history.jsonl`,
plus a folder picker. **New** runs `claude`, **Continue** runs `claude -c`, which resumes
the most recent conversation in that directory.

The window is opened by driving iTerm through `osascript`, falling back to Terminal.app
when `/Applications/iTerm.app` is not present. The first launch triggers the macOS
Automation consent prompt; if it is denied, `osascript` fails with error `-1743` and the
app says which System Settings pane to fix rather than doing nothing.

Directory paths are quoted for the shell and then escaped again for the AppleScript string
literal they sit inside, so a project called `it's a test` launches correctly.

## Stats

Two sources, with different freshness, both labelled in the menu:

- **Today** is live. The app tails every transcript modified today, remembers a byte
  offset per file, and only reads what was appended since. Broken out into input, output,
  cache write and cache read in the breakdown.
- **Lifetime** is `~/.claude/stats-cache.json` plus a transcript top-up. Claude Code only
  recomputes that file when you open its own stats screen, so it can be days or weeks
  stale and a model released since then is missing from it entirely. The days it does
  cover are taken from the file; everything after its `lastComputedDate` is read from
  transcripts, and the label becomes "Jul 20 + live" to say so. Its `costUSD` fields are
  always zero and are ignored.

**Today is counted once per request; the two Claude Code figures are not.** Claude Code
writes one transcript line per content block of an assistant message and repeats the
identical `usage` on each, so adding lines up double-counts — 1.84× on a measured day
here. Today is therefore deduplicated by `message.id`, keeping the last line of each
message because `output_tokens` grows as blocks stream in. The API bills once per request,
so this is the basis a cost estimate needs. `stats-cache.json` sums per line, and its
`dailyModelTokens` also excludes cache tokens entirely, which is why the "recent days"
rows are labelled `input + output only` and are numerically much smaller than today.

**Lifetime therefore mixes two bases**: the cache half counts per content block, the
topped-up half counts per request. The alternative — recomputing the whole of lifetime
from transcripts — is not available, because old transcripts get deleted. With no cache
to build on the lifetime row stays empty rather than reporting a few days of transcripts
as a lifetime.

One scan serves both figures. The tail starts at the day after `lastComputedDate` instead
of at midnight, and today is the subset of what it finds whose timestamp is past the start
of the local day. The window only moves when Claude Code recomputes its cache, so the
per-file offsets survive midnight and the first scan after launch is the only expensive
one — around 500 MB here, on a background task, so the menu shows the previous figures
until it lands rather than blocking.

Cost is computed here, from `~/.claude/claude-deck/prices.json`, which is written with
defaults on first run and re-read whenever it changes. Cache reads are charged at 0.1× the
input rate and cache writes at 1.25×; the 1-hour-TTL write rate of 2× is not modelled
because transcripts do not reliably distinguish the two. A model with no entry is left out
of the total and reported as "n models unpriced" rather than guessed at.

These are first-party API list prices. **A Max or Pro subscription is not billed per
token**, so the figure is a usage-equivalent estimate, not a bill, and is always shown
with "est".

## Launch at login

`SMAppService.mainApp` behind a checkbox. It only registers when the app is running from
`/Applications` or `~/Applications`; from `dist/` it explains that you need `make install`
first, because registering a path that moves on the next build would silently start a
stale copy at login.

## Permission prompts need hooks

Nothing on disk changes when Claude Code blocks on a permission prompt: the session
status stays `busy`. The only signal is a hook. **Install hooks** in the menu merges four
entries (`Notification`, `Stop`, `UserPromptSubmit`, `SessionEnd`) into
`~/.claude/settings.json`; each one appends the hook's stdin to
`~/.claude/claude-deck/events.jsonl`, which the app tails.

Before writing, the installer copies `settings.json` to
`settings.json.bak-claude-deck-<timestamp>`. The edit is a text splice that leaves every
other byte of the file untouched, so `diff` against the backup shows only the added lines.
If you already have a hook under one of those four names — an `afplay` on `Stop`, say — the
command is added alongside it inside the same array rather than as a second key, because a
duplicate key would be resolved differently by Node and by the app. Installing twice is a
no-op. If `hooks` is present but is not an object, the installer refuses and says so
instead of guessing. `settings.json` is resolved through symlinks first, so a dotfiles
symlink keeps pointing at its target.

**Claude Code snapshots hooks when a session starts**, so sessions that are already
running will not emit events until they are restarted.

## What it reads

Everything except `~/.claude/settings.json` (hook install) and `~/.claude/claude-deck/`
(its own spool) is read-only.

| Path | Used for |
|---|---|
| `~/.claude/sessions/<pid>.json` | the session list, `name`, `cwd`, `status`, `statusUpdatedAt` |
| `~/.claude/projects/*/<sessionId>.jsonl` | model and context usage from the newest assistant message; today's token totals |
| `~/.claude/history.jsonl` | the last prompt shown under each row, the recent project list, today's session ids |
| `~/.claude/settings.json` | whether the configured model is a 1M-context one; hook install state |
| `~/.claude/stats-cache.json` | lifetime sessions and per-model tokens |
| `~/.claude/claude-deck/events.jsonl` | hook events |
| `~/.claude/claude-deck/prices.json` | token prices for the cost estimate (written with defaults, then yours) |

Session files are not always removed when a session dies, so each PID is validated with
`kill(pid, 0)` **and** an exact match of the file's `procStart` against
`ps -o lstart=`. Note that Claude Code writes `procStart` in **UTC**, so `ps` is invoked
with `TZ=UTC`; without that the two never match and every session looks dead.

Transcripts reach tens of megabytes, so they are read by seeking backwards from EOF in
64 KB chunks, stopping at the first assistant message and giving up after 2 MB. Results
are cached per session and invalidated by file size, and reads only happen when the menu
opens, when a session's status changes, or on a `Stop` event.

Transcript reads — the two that run repeatedly and over large files — use `pread` into a
reused buffer rather than `FileHandle`. `FileHandle.read(upToCount:)` grows the process
footprint by roughly the number of bytes it returns and never releases it, measured at
+28 MB per pass over a 29 MB transcript and cumulative across passes. That is invisible in
a short-lived tool and fatal in a menu bar app that re-reads transcripts all day. The
history and spool tails still use `FileHandle`; they read a couple of megabytes once at
launch and only appended bytes afterwards, so the cost is bounded and one-shot.

Context percentage is `(input + cache_creation + cache_read) / window`, the same formula
the built-in status line uses. Transcript model strings never carry the `[1m]` suffix, so
the window is taken as 1M when `settings.json`'s `model` contains `[1m]` or usage already
exceeds 200k, and 200k otherwise.

## Refresh model

- **A 3 s timer re-scans `~/.claude/sessions/`, and it is the only thing that delivers
  status changes.** Claude Code rewrites `<pid>.json` in place instead of writing a temp
  file and renaming it, and a `.write` `DispatchSourceFileSystemObject` on a directory fd
  does not fire for an in-place rewrite of a file it contains — only for creates, deletes
  and atomic replaces. So every busy↔idle flip, busy-timer start and status-triggered
  transcript read arrives on the timer, within 3 s. The timer is also what makes a
  `kill -9`'d session disappear, since its file is never updated again.
- A `DispatchSource` watcher on `~/.claude/sessions/`, debounced 200 ms, which for the
  same reason only reacts to sessions starting and exiting. Watching each file
  individually would buy sub-second status updates; 3 s is fine for a menu bar app.
- A watcher on `~/.claude/claude-deck/events.jsonl` itself, plus one on its directory to
  re-arm after the file is recreated — a directory watcher never sees appends either.
  Hook events therefore land in well under a second, and the timer drains the spool as a
  backstop.
- Busy durations tick inside the open menu via `TimelineView`; nothing polls while it is closed.

## Compatibility

Developed against **Claude Code 2.1.220** on macOS 26 (arm64). Everything under
`~/.claude` other than `settings.json` is an undocumented internal format and can change
without notice, so every field is decoded as optional and anything unrecognised degrades
to "unknown" rather than dropping a row or crashing. If a future version renames these
files, the app will show an empty list rather than misbehave.
