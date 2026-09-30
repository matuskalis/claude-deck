# Hooks and privacy

Permission prompts and tool activity need hooks. This page says what the hooks record, how the installer edits a file you own, and everything the app reads and writes.

## Why hooks

Nothing on disk changes when Claude Code blocks on a permission prompt: the session's status stays `busy`. The only signal is a hook. **Install hooks** in the footer merges seven entries into `~/.claude/settings.json`.

| Hook | For |
|---|---|
| `Notification` | permission prompts |
| `Stop` | a finished turn |
| `StopFailure` | a turn killed by an API error |
| `UserPromptSubmit`, `SessionEnd` | clearing the above |
| `PreToolUse`, `PostToolUse` | the tool a session is inside |

All seven call one shell helper, `~/.claude/claude-deck/spool`, with the event name as an argument. Tool events go to `tools.jsonl`, which is high volume, and the rest to `events.jsonl`.

The footer says already-running sessions report nothing until they are restarted. Claude Code's hook documentation (read on 30 Sep 2026) says that direct edits to hooks in settings files are normally picked up by a file watcher. Which of the two holds for the Claude Code you run was not tested here. If a session does not report, restart it.

## What it records

Hook payloads carry everything: your prompt, the full `tool_input` (on a `Write`, a whole file) and the tool result. Spooling that raw would put a second copy of your source and your secrets on disk, in the clear, for a menu bar app. So the helper keeps only this.

| Kept | Why |
|---|---|
| `session_id` | to attribute the event to a row |
| `tool_name`, on tool events | the label on the row |
| `message`, on `Notification` and `StopFailure` only | the text the row and the banner show, written by Claude Code, for example "Claude needs your permission to run Bash" |

**Your prompts, tool inputs and tool results are read and thrown away.** A test pushes a payload containing an API token and a private path through the real helper and asserts that neither appears in what it wrote.

Fields come out with `plutil` rather than a regular expression, because `tool_input` is arbitrary JSON and any pattern over it eventually matches the wrong thing. `session_id` and `tool_name` are a UUID and an identifier, so neither can carry a quote and both go in as they are. If that ever stops being true the line fails to parse and is dropped on read, which fails safe. The one free-text field is flattened, stripped of control characters, capped at 200 characters and escaped.

Spools are written under `umask 077` into a `0700` directory, capped at 256 KB and trimmed to 64 KB. The app also deletes an `events.jsonl` over 5 MB at launch. **Clear data** in the menu deletes the spools and the usage samples, and **Remove** takes the hooks out entirely.

**The helper has no `set -e` and always exits 0.** A `PreToolUse` hook that exits with code 2 blocks the tool call it fired for, and any other failure prints a notice. Nothing a menu bar app wants is worth either. Rotation replaces the file, so the directory watcher is what re-arms the file watcher onto the new inode. The rewind that follows replays the tail, which is harmless because a replayed `PreToolUse` only sets a label the next `PostToolUse` clears. Parallel tool calls can interleave a very large line into one that will not parse. Those lines are dropped on read, and a missed tool label is not worth a lock.

## How the installer edits settings.json

- **A backup first.** Before writing, the file is copied to `settings.json.bak-claude-deck-<timestamp>` beside it.
- **A text splice, not a rewrite.** A hook is added to the existing `hooks` object, or to an existing event array if you already have hooks under that name, for instance an `afplay` on `Stop`. It goes inside the same array rather than becoming a second key, because a duplicate key would be resolved differently by Node and by the app. Every other byte of the file is left as it was, so `diff` against the backup shows only the added lines.
- **Checked before it is written.** The result has to parse, and every event has to appear exactly once.
- **Idempotent.** Installing twice changes nothing the second time.
- **Reversible.** **Remove** takes out only what this app wrote: a matcher that carries a command mentioning the app's directory, then an event array and `hooks` itself if removal left them empty. Hooks you wrote yourself are never touched, in either direction. Install followed by remove leaves a normally formatted file (two-space, four-space or tab indentation, line feeds) byte-identical, which tests assert. A minified file, a file with Windows line endings or an empty `{}` comes back as valid JSON with the same content and some whitespace left over. An empty `hooks` object or event array that was there before the install is dropped. The backup beside the file is the exact original in every case.
- **Upgrades replace.** **Reinstall** removes before installing, so a new version does not run beside the old one. Hooks left by versions 1.2 and 1.3 spooled raw payloads, so they are reported as needing an update instead of counting as installed.
- **It refuses what it does not understand.** If the file is not a JSON object, or `hooks` is present but not an object, or an event is not an array, nothing is written and the menu says why.
- **Symlinks are followed.** `settings.json` is resolved through symlinks first, so a dotfiles symlink keeps pointing at its target.
- **No file yet.** One is created, and there is nothing to back up.
- **The timeout is 5 seconds.** The field is in seconds. Until this was fixed the installer wrote 5000, which is about 83 minutes. It never mattered, because the helper returns in milliseconds and a timed-out command hook does not block the tool call. The installer compares commands, not timeouts, so an existing install keeps what it has until you press Reinstall.

`HookInstallerTests`, `HookInstallerEdgeTests`, `HookInstallerShapesTests` and `HookHelperTests` cover all of it. The helper tests feed it quotes, backslashes, line breaks, escape sequences, a 300 character message, a prompt and a tool input riding along with a notification, and a payload that is not JSON.

## What it reads and writes

Everything except `~/.claude/settings.json` (hook install) and `~/.claude/claude-deck/` (its own spools, samples, helper and caches) is read-only. The app itself opens no network connection. The News tab starts the `claude` you already have, which does.

"Read-only" is not quite the promise worth making, though, because the app installs itself on request and can end a dormant process. The line that matters is this one:

> **Claude Deck never sends commands, answers questions, or approves tool use inside a Claude session on your behalf.**

Starting a session, focusing its window and ending an abandoned one are lifecycle controls you asked for by clicking. Speaking into a session as you is a different thing, and this app does not do it. Nothing in the code opens a socket.

| Path | Used for |
|---|---|
| `~/.claude/sessions/<pid>.json` | the session list: name, directory, status, start time |
| `~/.claude/projects/*/<sessionId>.jsonl` | model and context usage from the newest assistant message, and today's token totals |
| `~/.claude/history.jsonl` | the last prompt shown under each row, and which sessions prompted today |
| `~/.claude/settings.json` | whether the configured model is a 1M-context one, and hook install state (**written** on install and remove) |
| `~/.claude/stats-cache.json` | lifetime sessions and per-model tokens |
| `~/.claude/jobs/<jobId>/state.json` | a background job's state, what it needs, its fan-out and token count |
| `~/.claude/jobs/<jobId>/timeline.jsonl` | the last three progress notes, read from the end |
| `~/.claude/cache/changelog.md` | the Changelog tab |
| `~/.claude.json` | `cachedUsageUtilization` only: plan-limit percentages, severities and reset times |
| `~/.claude` (size only) | the Machine row, via `du`, at most every five minutes |
| `~/.claude/claude-deck/events.jsonl`, `tools.jsonl` | hook events, minimised as above, written by the helper |
| `~/.claude/claude-deck/spool` | the helper script (**written** on install) |
| `~/.claude/claude-deck/usage-history.jsonl` | plan-limit samples for the forecast (**written**) |
| `~/.claude/claude-deck/prices.json` | token prices for the cost estimate (**written** with defaults, then yours) |
| `~/.claude/claude-deck/news.json`, `news-topics.txt` | the News cache, and who it follows (**written**) |
| `~/Applications/Claude Deck.app` | only when you press **Install** in the footer (**written**) |

## Removing it

Press **Remove** in the footer to take the hooks out of `settings.json` (the backups stay beside it), quit the app, delete `Claude Deck.app`, and delete `~/.claude/claude-deck`, which holds the spools, prices, news cache and the helper. **Clear data** empties the spools and usage samples but keeps your prices, the news cache and the topics file.
