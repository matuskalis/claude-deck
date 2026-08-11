# Claude Deck

[![build](https://github.com/matuskalis/claude-deck/actions/workflows/build.yml/badge.svg)](https://github.com/matuskalis/claude-deck/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)
![dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A macOS menu bar app that shows every running Claude Code CLI session, which tool it is
inside right now, how full its context window is, how close you are to your plan limits,
and what today has cost. It watches background jobs, which have no window to look at,
notifies you when a session finishes, blocks, or dies on a rate limit, takes you back to
the terminal a session is running in, and starts new ones.

Four tabs, all the same height, none of them scrolling:

| | |
|---|---|
| **Sessions** | what is running, what is waiting on you, background jobs |
| **Usage** | plan limits, Wi-Fi, what the machine is spending, today's tokens |
| **Changelog** | what changed in Claude Code, from the file it already keeps on disk |
| **News** | what changed across the other AI coding tools, summarised on demand |

**Nothing scrolls.** A page that does not fit its box is a page trying to be two pages, so
the deck was split rather than made scrollable: sessions and jobs on one tab, everything
about cost on another. The two list-shaped tabs are master and detail — headlines above, the
selected one written out below — because 360 releases and eight articles were never going to
fit a fixed panel, and paging through them by dragging would have been worse than reading
them. Sessions cap at six and jobs at two, with the overflow counted; hitting either cap
means something is worth attending to, not that the panel is too small.

```
┌────────────────────────────────────────────┐
│ Claude Deck v1.9.0  1 waiting 1 blocked 2 ▮│
│  (Sessions)  Usage   Changelog   News      │
│────────────────────────────────────────────│
│ ◐ shiftfix   opus    waiting: Bash approval│
│ ● fix-shorts-water…  Bash 4m12s  ◕ 72%     │
│   ~/projects/shorts-engine  "fix the…"     │
│ ○ matuskalis-4d  stale  idle     ◔ 31%     │
│ ▸ 12 dormant  idle over 12h      [Quit all]│
│────────────────────────────────────────────│
│ Background jobs                          2 │
│ ● fix-shorts-watermark…  blocked     1.9M  │
│   V rade je 44 starých klipov. Kam s 43?   │
│   Odložiť staré · Miešať · Pridať za staré │
│   ✦ Normalize collapse loudness      9m41s │
│────────────────────────────────────────────│
│ Launch Claude in…          [Browse folder…]│
│────────────────────────────────────────────│
│ ✓ Hooks installed  [Remove] [Reinstall]    │
│ Stores session ids…           [Clear data] │
│ Launch at login ☐                Quit ⌘Q   │
└────────────────────────────────────────────┘
```

The Usage tab, same box, same footer:

```
┌────────────────────────────────────────────┐
│ Plan limits                ▂▄▆█ good 162Mb │
│ Session         resets in 4h02m        24% │
│ ▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ Weekly          resets in 11h29m       82% │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░ │
│ on course to hit 100% Tue 03:04            │
│────────────────────────────────────────────│
│ Machine        fix-shorts-water… busiest   │
│ CPU    Memory   ~/.claude   Free           │
│ 38%    1.4 GB   1.2 GB      589 GB         │
│────────────────────────────────────────────│
│ Today 6 sessions · 1.2M tok · ~$4.10 · $0.9│
│ Lifetime 239 sessions · 6.8B  Jul 20+live  │
│      ╭─╮      ╭──╮                         │
│ ╭────╯ ╰──────╯  ╰─╮   ╭───                │
└────────────────────────────────────────────┘
```

News and Changelog are master and detail, sliders on top:

```
┌────────────────────────────────────────────┐
│ Detail                          Balanced   │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓●───────────────────────   │
│ How far back                     30 days   │
│ ▓▓▓▓▓▓▓▓▓▓▓●───────────────────────────    │
│────────────────────────────────────────────│
│ Anthropic launches self-hosted…  2026-08-06│
│ OpenAI to retire GPT-5.4 in Codex 2026-07-31│
│ Cursor 3.11 adds side chats      2026-07-10│
│────────────────────────────────────────────│
│ claude.com ↗                               │
│ Claude Code can now run on your own servers│
│ instead of Anthropic's cloud, keeping code │
│ and secrets inside your network.           │
│────────────────────────────────────────────│
│ as of 10:33  last cost $0.88     [Refresh] │
└────────────────────────────────────────────┘
```

The other two tabs are the same panel with two sliders at the top of it:

```
┌────────────────────────────────────────────┐
│      Deck    Changelog   ( News )          │
│────────────────────────────────────────────│
│ Detail                          Balanced   │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓●───────────────────────   │
│ How far back                     30 days   │
│ ▓▓▓▓▓▓▓▓▓▓▓●───────────────────────────    │
│────────────────────────────────────────────│
│ Anthropic launches self-hosted environments│
│ claude.com · 2026-08-06                    │
│ Claude Code can now run on your own servers│
│ instead of Anthropic's cloud, keeping code │
│ and secrets inside your network.           │
│────────────────────────────────────────────│
│ as of 10:33  last cost $0.88     [Refresh] │
└────────────────────────────────────────────┘
```

Swift 6.2, SwiftUI `MenuBarExtra`, one SwiftPM executable target, no external dependencies.

## Build and run

```sh
make build     # swift build -c release, then assemble dist/Claude Deck.app
make run       # build + open "dist/Claude Deck.app"
make install   # build + ditto to ~/Applications/Claude Deck.app
make clean
swift test     # hook install/uninstall splicing, and what may be terminated
```

Always launch the app bundle, never `.build/release/ClaudeDeck` directly:
`UNUserNotificationCenter` requires a real bundle identifier and traps in a bare SwiftPM
binary. The Makefile assembles the `.app` (Info.plist, PkgInfo, ad-hoc code signature)
around the built binary.

The app is `LSUIElement`, so it has no Dock icon or window; everything lives in the
menu bar item.

There is no signed download, and there will not be one: this is built from source. Because
you build it locally the bundle carries no quarantine attribute, so Gatekeeper does not
stand in the way — `make install` and open it. It is ad-hoc signed, which is enough for
local use and not enough to distribute, which is fine, because it is not distributed.

## Dormant sessions

A machine that has been used for a week accumulates terminal tabs with a live but
long-abandoned `claude` in them. Measured here: 14 live sessions, 2 of them doing anything,
9 untouched for more than three days. Left alone, the list is mostly noise and the two that
matter are pushed off the top of it.

Anything idle for more than 12 hours is therefore folded into a single collapsed row.
Twelve hours rather than "not touched today", which would collapse the whole list the
moment midnight passed and put it back at breakfast.

**Quit all** on that row sends `SIGTERM` — never `SIGKILL` — to the dormant sessions only,
after a confirmation listing them. Each one gets to write out its transcript and remove its
session file, so the conversation is still there under `claude -c` in the same directory.
Busy sessions, sessions waiting on a permission prompt, and background jobs are never
included, whatever the list is filtered to.

Two things make that safe to click:

**Dormant requires `status` to say `idle`**, not merely to not say `busy`. A session file
with no status, or one written by a future version using a status this build has never
heard of, decodes as not-busy — and "I do not recognise this state" must not become "safe
to terminate". One session on the machine this was written on is exactly that case: no
status field, idle for a fortnight, and previously in the Quit all set.

**A pid is not an identity.** The list backing that button was read up to a refresh
interval earlier, and in that gap a session can exit and have its pid handed to something
unrelated. Every process is re-proven against its recorded `procStart` at the moment of
quitting, by the same check the session scan uses. Anything that cannot be proven — already
gone, or a session file with no recorded start time — is skipped and reported, never
signalled on the strength of a number.

## The menu bar item

macOS renders a status item as a template image, so colour is not available there and state
has to be carried by the symbol and a compact badge:

| Shown | Means |
|---|---|
| `terminal` | sessions exist, none busy |
| `terminal.fill` + `2` | two sessions busy |
| `exclamationmark.bubble.fill` | at least one session is blocked on a permission prompt |
| `bolt.slash.fill` | a turn was killed by an API error |
| `pause.circle.fill` | a background job is waiting on an answer |
| `wifi.slash` | the Wi-Fi association dropped |
| `exclamationmark.triangle.fill` + `82%` | a plan limit reached its critical band |

Colour lives in the menu itself, which is an ordinary SwiftUI window and under no such
constraint.

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
| a turn ends on an API error | `⚠ <name> stopped` with the reason |
| a background job blocks on a question | `⏸ <name> is blocked` with the question, keyed on the question so a new one alerts and a re-read does not |
| a session passes 85% context | `<name> is at <n>% context`, re-armed once it drops below 70% |
| a plan limit passes 80% or 95% | `<limit> usage at <n>%`, once per threshold per window, so it fires again after the window resets |
| the Wi-Fi association drops | `Wi-Fi dropped`, withdrawn when the link comes back |

The 10 second floor exists so that two-second replies do not produce banner noise.

Banners about a session carry its pid and a **Focus** button, so one can take you to the
window rather than only telling you about it.

## Focus a running session

Clicking a row brings the terminal window that session is running in to the front. The
match is on the tty its process is attached to, read with `ps -o tty=` and compared against
the `tty` of every iTerm session and every Terminal tab, so it selects the exact split pane
rather than just raising the app.

Both terminals are addressed by bundle id behind an `is running` guard. Telling one by name
launches it, which would leave a stray empty window every time a session is somewhere
unreachable — under tmux, in an IDE terminal, or detached — and that case is reported
instead. Focus goes through the same Automation consent as quick launch.

## Quick launch

A folder picker, and that is deliberately all of it. There was a recent-projects list with
New and Continue buttons per row; it went unused and cost more vertical space than every
section below it.

The window is opened by driving iTerm through `osascript`, falling back to Terminal.app
when `/Applications/iTerm.app` is not present. The first launch triggers the macOS
Automation consent prompt; if it is denied, `osascript` fails with error `-1743` and the
app says which System Settings pane to fix rather than doing nothing.

Directory paths are quoted for the shell and then escaped again for the AppleScript string
literal they sit inside, so a project called `it's a test` launches correctly.

## Background jobs

Background sessions used to be filtered out of the scan entirely, which meant the sessions
nobody is sitting in front of were the only ones the app did not show. They are read from
`~/.claude/jobs/<jobId>/state.json`, which says considerably more than a session file does:
what it is doing in a sentence, what it has fanned out to subagents and shell commands, how
many tokens it has spent, and — beside it — a `timeline.jsonl` it appends progress notes to,
of which the last three are shown.

A blocked job is the background equivalent of a permission prompt: nothing moves until it
is answered, and there is no window anywhere showing that it is waiting. Those sort first,
colour amber, and notify.

**`state` alone does not detect that.** A job can hold an unanswered question in
`block.questions` while still reporting `working`, so blocked means any of `state`, `tempo`,
or a pending question. The question and its options are printed verbatim, which is more use
than the prose paraphrase in `needs`.

Job directories outlive the processes that wrote them, so liveness comes from joining
`jobId` against the live background session files. A job still claiming `working` with no
process behind it shows as **not running** rather than being hidden, since that is the
failure worth seeing. Finished jobs, and anything untouched for a day, are dropped.

## What it records

Hook payloads carry everything: your prompt, the full `tool_input` — which on a `Write` is
a whole file — and the tool result. Spooling that raw would put a second copy of your
source and your secrets on disk, in the clear, for a menu bar app.

So every hook goes through `~/.claude/claude-deck/spool`, which keeps only:

| Kept | Why |
|---|---|
| `session_id` | to attribute the event to a row |
| `tool_name` | the label on the row |
| `message`, on `Notification` and `StopFailure` only | the text the row and the banner show, written by Claude Code — "Claude needs your permission to run Bash" |

**Your prompts, tool inputs and tool results are read and thrown away.** A test pushes a
payload containing an API token and a private path through the real helper and asserts that
neither appears in what it wrote.

Fields come out with `plutil` rather than a regular expression: `tool_input` is arbitrary
JSON and any pattern over it eventually matches the wrong thing. `session_id` and
`tool_name` are a UUID and an identifier, so neither can carry a quote and both go in as
they are; if that ever stops being true the line fails to parse and is dropped on read,
which fails safe. The one free-text field is flattened, stripped of control characters,
capped at 200 characters and escaped.

Spools are written under `umask 077` into a `0700` directory, capped at 256 KB and trimmed
to 64 KB. **Clear data** in the menu deletes them and the usage samples; **Remove** takes
the hooks out entirely.

**The helper has no `set -e` and always exits 0.** A `PreToolUse` hook that exits non-zero
blocks the tool call it fired for, and nothing a menu bar app wants is worth stopping
someone's Bash call. Rotation replaces the file, so the directory watcher is what re-arms
the file watcher onto the new inode; the rewind that follows replays the tail, which is
harmless because a replayed `PreToolUse` only re-sets a label the next `PostToolUse` clears.

## Plan limits

Claude Code fetches your plan utilisation from its usage endpoint and caches the result in
`~/.claude.json` under `cachedUsageUtilization`. That cache is the only local copy of the
numbers behind its `/usage` screen, and it is what this section renders: one meter per
entry in `utilization.limits`, which is currently the rolling session window, the weekly
all-model window, and a weekly window scoped to one model.

**The figures are only as fresh as Claude Code's last fetch**, which is why the fetch time
is printed under them. Nothing here calls the API; the app has no credentials and does not
want any. If you have never run a version that writes the key, the section says so rather
than showing zeroes.

`resets_at` carries six fractional digits, which `ISO8601DateFormatter` rejects outright,
so the fraction is cut to the three it accepts before parsing. The file is rewritten in
place by Claude Code while the app may be reading it, so a failed decode keeps the previous
snapshot instead of blanking the section, and the read is skipped entirely unless size or
mtime changed.

Severity comes from the API's own `severity` field rather than from a threshold picked
here, because the thresholds are Anthropic's. The colour scale is shared with the context
rings and the signal bars, so a colour means the same thing everywhere in the menu.

### Forecast

The limits arrive as percentages with no token denominator behind them, so the only rate
that can be measured is **percent per hour**, and the only way to measure it is to watch
them move. Samples go to `~/.claude/claude-deck/usage-history.jsonl`, capped at 400.

Only samples since the last reset count — a percentage that fell is a new window, and
averaging across the boundary would halve every rate. They are sorted before the fit rather
than trusted in file order, because a sample landing out of order reads as a reset to that
test and silently truncates the window.

Nothing is shown until three samples span an hour, and nothing is shown for a limit that
resets before it would fill. Silence early on is the honest answer, not an extrapolation
from two readings.

## Wi-Fi

`CWInterface` reports RSSI, noise and transmit rate with no entitlement and no Location
permission. SSID and BSSID do require one, so they are not read — the interface name is
never shown and no location data is touched.

Bars follow the usual 802.11 thresholds: -55 dBm excellent, -67 the floor for sustained
throughput, -75 the floor for a usable link. A powered-on interface that is not associated
reports an RSSI of exactly 0, which is what "offline" is detected from. The whole section
is hidden on a machine with no Wi-Fi hardware.

It earns its place next to the plan limits because it is the other reason a long agent run
stops mid-tool-call, and the one you cannot see from inside Claude Code.

## Machine

What the sessions cost the machine, as opposed to what they cost the plan: CPU, resident
memory, the size of `~/.claude`, and free disk. The busiest session is named when it is
doing anything worth naming.

**`ps -o %cpu` is not usable for this.** It reports CPU averaged over the entire life of the
process, so a session open for a fortnight reads 0.1% while it is pinning a core. CPU comes
instead from the cumulative CPU time in `ps -o time`, differenced against the previous
sample — which is the whole reason the reader holds state between calls, and why the first
reading after opening the menu is blank.

CPU is measured against **one** core, not all of them, because that is the ceiling a single
session's main thread can hit. `~/.claude` is measured with `du` at most every five minutes;
it is around a gigabyte of transcripts on a well-used machine and grows without anyone
deciding that it should.

**Energy and network are deliberately absent.** Both were tried and both were measured:
`top -stats power` costs about 1.5 seconds per sample and reports `0.0` without a sampling
window, and `nettop` costs 5 seconds and returns nothing useful without privileges this app
has no business holding. A slow, fake-precise number is worse than no number.

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

Today's tokens are also split by project inside the breakdown. The directory name under
`~/.claude/projects` has `/` replaced by `-`, which is ambiguous to undo — `shorts-engine`
and `shorts/engine` encode identically — so the project name comes from each transcript's
own `cwd` field instead.

The `$/h` beside today's estimate is measured from the day's first assistant message rather
than from midnight, so a day that started at 14:00 does not report a quarter of its real
rate.

## Changelog

This tab reads the changelog Claude Code already keeps at
`~/.claude/cache/changelog.md` — 360 releases and 4318 entries on this machine, refreshed by
Claude Code itself. **No network, no key, no summarising:** the entries are already written,
one line each, by the people who made the change. The release you are running is tagged.

Master and detail: seven releases listed, the selected one written out beneath. Two
sliders.

**Detail** — Highlights, Notable, Everything. Of those 4318 entries, 53% begin "Fixed" and
another 9% "Improved". Highlights keeps only what changes how you work: Added, Changed,
Removed, and lines that do not start with a verb. Notable adds the improvements, Everything
adds the fixes, and whatever is held back is counted beside the version number. Over twenty
releases Highlights is 146 lines instead of 488.

**How far back** — moves the window of seven through all 360 releases, and is captioned
with the oldest release it reaches. Releases rather than days because **the changelog
carries no dates**, only version headings, so a "last 24 hours" control would be inventing
information the source does not have.

The parse is stat-gated and only runs when the menu is opened: half a megabyte is not worth
re-reading on a timer when nothing about it changes while nobody is looking.

## News

The one place the app reaches past the disk — and it does so **without ever holding a
credential**, by asking the Claude Code already installed and logged in on this machine.
Refresh runs a separate headless `claude -p` session that reads the vendors' own release
notes and blogs, and caches what it finds.

Master and detail: up to six headlines, the selected one written out beneath. Two sliders.

**Detail** — Plain, Balanced, Technical. All three summaries are written in the same run and
stored per item, so moving the slider costs nothing: the model is asked once and answers
three times, rather than being asked again. Plain carries no jargon, Balanced names the
feature and its consequence, Technical keeps version numbers, limits and benchmarks.

**How far back** — continuous, 24 hours to 90 days. Continuous rather than stepped because
the cache holds ninety days of dated items, so every cut-off in that span is a real one and
none of them triggers a fetch.

Four things stated plainly, because they are the cost of the feature:

- **It spends your plan usage.** A measured run: 20 turns, 143 seconds, **$0.88**. The
  panel prints what the last one cost, and refresh is a button — never a timer, never on
  launch.
- **It refuses when a limit is already critical.** The rest of this app exists to show how
  close those limits are; a news panel is not what the last of a weekly allowance is for.
- **It does not speak into any session of yours.** A fresh `claude -p` is its own
  conversation. The boundary below still holds.
- **The summaries are a model's reading of pages it fetched**, not a publisher's feed.
  Every item carries its primary-source URL; click through for anything that matters.

Items are required to carry a working URL and a publication date, and the prompt says to
drop anything that cannot supply both. Sources are restricted to vendor blogs, changelogs,
model cards and papers — no aggregators.

## Launch at login

`SMAppService.mainApp` behind a checkbox. It only registers when the app is running from
`/Applications` or `~/Applications`, because registering a path that moves on the next
build would silently start a stale copy at login.

Running from `dist/` the footer says so and offers **Install**, which `ditto`s the bundle
to `~/Applications`, starts the copy and quits itself. `ditto` rather than a file copy,
matching the Makefile: it is the copy that reliably preserves the code signature, and a
broken signature means macOS refuses to launch the result. Until that has happened the app
does not survive a reboot at all, which was worth a button rather than a terminal step.

## Permission prompts need hooks

Nothing on disk changes when Claude Code blocks on a permission prompt: the session
status stays `busy`. The only signal is a hook. **Install hooks** in the menu merges seven
entries into `~/.claude/settings.json`:

| Hook | For |
|---|---|
| `Notification` | permission prompts |
| `Stop` | a finished turn |
| `StopFailure` | a turn killed by an API error |
| `UserPromptSubmit`, `SessionEnd` | clearing the above |
| `PreToolUse`, `PostToolUse` | the tool a session is inside |

All seven go through `~/.claude/claude-deck/spool`, which records only the fields listed in
[What it records](#what-it-records).

Before writing, the installer copies `settings.json` to
`settings.json.bak-claude-deck-<timestamp>`, and **Remove** puts it back: uninstalling
after installing leaves the file byte-identical to what it was, which is what the test
asserts. Hooks you wrote yourself are never touched by either direction.

Reinstall removes before installing, so upgrading replaces the old hooks rather than
running both. Hooks left by 1.2 or 1.3 spooled raw payloads, so they are reported as
**needing an update** rather than counting as installed.

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
(its own spools, samples, helper and news cache) is read-only. The app itself opens no
network connection; the News tab shells out to the `claude` you already have, which does.

"Read-only" is not quite the promise worth making, though, because the app does install
itself and can end a dormant process. The line that actually matters is this one:

> **Claude Deck never sends commands, answers questions, or approves tool use inside a
> Claude session on your behalf.**

Starting a session, focusing its window, and ending an abandoned one are lifecycle controls
you asked for by clicking. Speaking into a session as you is a different thing, and this
app does not do it. There is a messaging socket at `/tmp/cc-socks/<pid>.sock` that would
allow it; it is deliberately untouched.

| Path | Used for |
|---|---|
| `~/.claude/sessions/<pid>.json` | the session list, `name`, `cwd`, `status`, `statusUpdatedAt` |
| `~/.claude/projects/*/<sessionId>.jsonl` | model and context usage from the newest assistant message; today's token totals |
| `~/.claude/history.jsonl` | the last prompt shown under each row, the recent project list, today's session ids |
| `~/.claude/settings.json` | whether the configured model is a 1M-context one; hook install state |
| `~/.claude/stats-cache.json` | lifetime sessions and per-model tokens |
| `~/.claude/jobs/<jobId>/state.json` | a background job's state, what it needs, its fan-out and token count |
| `~/.claude/jobs/<jobId>/timeline.jsonl` | the last three progress notes, read from the end |
| `~/.claude/claude-deck/events.jsonl` | hook events, minimised — see [What it records](#what-it-records) |
| `~/.claude/claude-deck/tools.jsonl` | tool hook events, same, written and rotated by the spool helper |
| `~/.claude/claude-deck/usage-history.jsonl` | plan limit samples for the forecast (written) |
| `~/.claude/claude-deck/prices.json` | token prices for the cost estimate (written with defaults, then yours) |
| `~/.claude/cache/changelog.md` | the Changelog tab, parsed when the menu opens |
| `~/.claude` (size only) | the Machine row, via `du`, at most every five minutes |
| `~/.claude/claude-deck/news.json` | the News tab's cache (written) |
| `~/.claude.json` | `cachedUsageUtilization` only: plan limit percentages, severities and reset times |

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
- A watcher on each of `events.jsonl` and `tools.jsonl`, plus one on their directory to
  re-arm after either is recreated — a directory watcher never sees appends either, and
  rotation replaces `tools.jsonl` outright. Hook events therefore land in well under a
  second, and the timer drains both spools as a backstop.
- A 15 s timer for the cheap meters: the stat-gated read of `~/.claude.json`, the
  stat-gated pass over `~/.claude/jobs/`, and the `CWInterface` query. All three also run
  when the menu opens, so what you see on open is current rather than up to 15 s old.
- Busy durations and limit reset countdowns tick inside the open menu via `TimelineView`;
  nothing polls while it is closed.

## Compatibility

Developed against **Claude Code 2.1.220**, verified against **2.1.226**, on macOS 26
(arm64). Everything under `~/.claude`, plus `cachedUsageUtilization` in `~/.claude.json`,
is an undocumented internal format and can change without notice, so every field is decoded
as optional and anything unrecognised degrades to "unknown" rather than dropping a row or
crashing. If a future version renames these files, the app will show an empty list rather
than misbehave.

`utilization.limits` is read as a list rather than by picking out `five_hour` and
`seven_day` by name, so a limit kind added later shows up on its own with a generated
title instead of needing a code change.
