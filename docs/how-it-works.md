# How it works

The app is one SwiftPM executable target, SwiftUI `MenuBarExtra` on top, a `SessionStore` in the middle and a set of small readers underneath. Each reader owns one file format and knows how to read it cheaply. The list of files is in [Hooks and privacy](hooks-and-privacy.md#what-it-reads-and-writes).

## Is this session alive?

Session files are not always removed when a session dies, so a file is not proof of a session. Each pid is checked with `kill(pid, 0)` and then by matching the file's `procStart` against `ps -o lstart=`, because pids get reused.

Claude Code writes `procStart` in UTC, in `ctime` format (`Tue Jul 28 00:39:41 2026`), so `ps` runs with `TZ=UTC`. Without that the two never match and every session looks dead. `ctime` pads a single-digit day with an extra space, so runs of blanks are collapsed before comparing. A process owned by another user still counts as responding (the signal check returns `EPERM`). A session file that records no start time falls back to the signal check alone, which is exactly why **Quit all** refuses to act on one.

## Reading transcripts without reading them

Transcripts reach tens of megabytes, and the only thing the session list needs from one is the newest assistant message. The reader seeks backwards from the end of the file in 64 KB chunks, reassembles a line that a chunk boundary cut in two, stops at the first assistant message it can decode, and gives up after 2 MB. Results are cached per session and invalidated by file size. Reads happen when the menu opens, when a session's status changes, or on a `Stop` event.

The two readers that run repeatedly over large files, this one and the token scan, use `pread` into a reused buffer instead of `FileHandle`. The author measured `FileHandle.read(upToCount:)` growing the process footprint by roughly the number of bytes it returned and never giving it back: +28 MB per pass over a 29 MB transcript, cumulative across passes. That is invisible in a short-lived tool and fatal in a menu bar app that reads transcripts all day. The history and spool tails still use `FileHandle`. They read a couple of megabytes once at launch and only appended bytes afterwards, so the cost is bounded.

Context percentage is `(input + cache writes + cache reads) / window`. [Sessions](sessions.md#session-rows) has the window rules.

## What refreshes when

- **A 3 second timer rescans `~/.claude/sessions/`, and it is the only thing that delivers status changes.** Claude Code rewrites `<pid>.json` in place instead of writing a temporary file and renaming it, and a write watcher on a directory does not fire for an in-place rewrite of a file inside it, only for creates, deletes and atomic replaces. So every busy and idle flip, the start of a busy timer and every status-triggered transcript read arrives on the timer, within 3 seconds. The timer is also what makes a `kill -9`'d session disappear, since its file is never updated again.
- **A directory watcher on `~/.claude/sessions/`**, debounced to 200 ms, which for the same reason only reacts to sessions starting and exiting. Watching each file individually would buy sub-second status updates, and 3 seconds is fine for a menu bar app.
- **Watchers on `events.jsonl` and `tools.jsonl`**, plus one on their directory to re-arm them after either is recreated. A directory watcher never sees appends either, and the helper rotates `tools.jsonl` by replacing it. Hook events therefore land in well under a second, and the timer drains both spools as a backstop.
- **A 15 second timer** for the cheap meters: the read of `~/.claude.json`, the pass over `~/.claude/jobs/`, the Wi-Fi query and the machine sample. All of them also run when the menu opens, so what you see on open is current rather than up to 15 seconds old. Files are read only when their size or modification time changed.
- **A 60 second timer** for the token counts, which read only the bytes appended to each transcript since the last scan.
- **Countdowns** (busy durations, limit resets) tick inside the open menu through a one second `TimelineView`. The Changelog and News caches are loaded when the menu opens.

## When Claude Code changes

Everything under `~/.claude`, and `cachedUsageUtilization` in `~/.claude.json`, is an undocumented internal format that can change without notice. So every field is decoded as optional, and anything unrecognised degrades to "unknown" instead of dropping a row or crashing. If a future version renames these files, the app shows an empty list rather than misbehaves. `utilization.limits` is read as a list rather than by picking out the session and weekly entries by name, so a limit kind added later appears on its own.

The project was developed against Claude Code 2.1.220 and checked against 2.1.226 in August 2026. It has not been checked against a newer release since.
