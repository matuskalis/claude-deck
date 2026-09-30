# Sessions

The Sessions tab, the menu bar icon, and the notifications that come with them. Everything here is read from `~/.claude` (see [How it works](how-it-works.md)); the parts that depend on hooks say so.

## The menu bar icon

macOS draws a status item as a template image, so colour is not available and state has to be carried by the symbol and a small badge. The first row that matches wins.

| Symbol | Shown when |
|---|---|
| `exclamationmark.bubble.fill` | a session is blocked on a permission prompt |
| `bolt.slash.fill` | a turn was killed by an API error |
| `pause.circle.fill` | a background job is blocked on a question |
| `wifi.slash` | the Wi-Fi association dropped |
| `exclamationmark.triangle.fill` | a plan limit is in its critical band |
| `terminal.fill` | at least one session is busy |
| `terminal` | none of the above |

The badge is the number of busy sessions, then the tightest plan limit once it reaches warning or above, joined with a dot: `2·82%`. Colour lives in the menu itself, which is an ordinary SwiftUI window and under no such constraint.

## Session rows

Each row shows a dot (pulsing while the session is busy), the session name, a short model tag (`opus`, `sonnet`), a `parked` tag when the session has backgrounded a job and is waiting on it, a `stale` tag where it applies, what the session is doing, a context ring with its percentage, the working directory (with `~` for home), and the last prompt in quotes.

What it is doing reads `<tool> <time>` while busy (`Bash 4m12s`), `waiting: <message>` when blocked on a permission prompt, `stopped: <message>` after a turn killed by an API error, and `idle` otherwise. The tool name and the waiting state come from hooks. Without them a busy session just reads `busy`.

Rows sort waiting first, then stopped, busy and idle, each group by name. Six are shown and the overflow is counted. A filter box appears when there are more than six sessions in all, dormant ones included.

The ring is `(input + cache writes + cache reads) / window` from the newest assistant message in the transcript. The window is 200k unless `~/.claude/settings.json` names a `[1m]` model or usage has already passed 200k, because transcripts never carry the `[1m]` suffix. Colour follows one shared scale, used for the rings, the plan-limit meters and the signal bars: normal below 75%, warning from 75%, critical from 90%.

A session is marked **stale** when it has been idle for more than 30 minutes while holding at least 70% of its context. That is one to finish or restart on purpose, rather than discover at 100% in the middle of a task.

## Focus a running session

Clicking a row brings the terminal window that session runs in to the front. The match is on the tty: the session's process is read with `ps -o tty=` and compared with the `tty` of every iTerm session and every Terminal tab, so it selects the exact split pane rather than just raising the app.

Both terminals are addressed by bundle id behind an `is running` guard. Telling an application by name launches it, which would leave a stray empty window every time a session is somewhere unreachable. A session under tmux, in an IDE terminal or detached is reported as not found. iTerm is only tried when `/Applications/iTerm.app` exists. Focus goes through the same Automation consent as quick launch.

## Quick launch

**Launch Claude in...** is a folder picker and nothing more. There used to be a recent-projects list with New and Continue buttons. It went unused and cost more vertical space than everything below it.

The window is opened by driving iTerm through `osascript`, falling back to Terminal.app when iTerm is not installed. The command is `cd '<folder>' && claude`. The folder is quoted for the shell and then escaped again for the AppleScript string it sits in, and the tests run the generated command through `/bin/sh` with folder names holding apostrophes, double quotes, backslashes, `$`, backticks and a `'; touch pwned; echo '` payload.

The first launch triggers the macOS Automation prompt. If it is denied, `osascript` fails with error `-1743` and the app names the System Settings pane to fix rather than doing nothing.

## Dormant sessions

A machine used for a week collects terminal tabs with a live but long-abandoned `claude` in them. On the author's machine one day it was 14 live sessions, 2 of them doing anything, 9 untouched for more than three days. Left alone the list is mostly noise and the two that matter get pushed off the top.

Anything idle for more than 12 hours folds into a single collapsed row. Twelve hours rather than "not touched today", which would collapse the whole list the moment midnight passed and bring it back at breakfast.

**Quit all** on that row sends `SIGTERM`, never `SIGKILL`, to the dormant sessions only, after a confirmation that lists them. Each one gets to write out its transcript and remove its session file, so the conversation is still there under `claude -c` in the same directory. Busy sessions, sessions waiting on a permission prompt, stopped sessions and background jobs are never included.

Two rules make that safe to click.

**Dormant requires `status` to say `idle`**, not merely to not say `busy`. A session file with no status, or one written by a future version using a status this build has never heard of, decodes as not busy, and "I do not recognise this state" must not become "safe to terminate".

**A pid is not an identity.** The list behind the button was read up to a refresh interval earlier, and in that gap a session can exit and have its pid handed to something unrelated. Each process is re-proven against its recorded `procStart` at the moment of quitting, by the same check the session scan uses. Anything that cannot be proven, because it is already gone or because its session file records no start time, is skipped and reported ("Quit 2 of 3"), never signalled on the strength of a number.

Both rules are covered by tests: `SessionSafetyTests` for what counts as dormant, `ProcessIdentityTests` for the identity check.

## Background jobs

Background sessions used to be filtered out of the scan entirely, which meant the sessions nobody is sitting in front of were the only ones the app did not show. They are not listed as sessions, since there is no window to go back to, but their jobs are, read from `~/.claude/jobs/<jobId>/state.json`. That file says far more than a session file: what the job is doing in a sentence, the sub-agents and shell commands it has fanned out and how long each has run, how many are in flight or queued, and how many tokens it has spent. Beside it, `timeline.jsonl` holds progress notes, and the last three can be opened from the job, read from the end of the file.

A blocked job is the background equivalent of a permission prompt: nothing moves until it is answered, and no window anywhere shows that it is waiting. Blocked jobs sort first, in amber, and notify.

**`state` alone does not detect that.** A job can hold an unanswered question in `block.questions` while still reporting `working`, so a job is blocked when any of `state`, `tempo` or a pending question says so. The question and its options are printed verbatim, which is more use than the prose paraphrase in `needs`.

Job directories outlive the processes that wrote them, so liveness comes from joining `jobId` against the live background session files. A job still claiming `working` with no process behind it shows as **not running**, in red, rather than being hidden, since that is the failure worth seeing. Finished jobs, and anything untouched for a day, are dropped. Two jobs are shown and the rest are counted.

## Notifications

On first launch the app asks for notification permission. If macOS has already recorded a denial for the bundle id, `requestAuthorization` fails silently with "Notifications are not allowed for this application" and no banner will ever appear, so the menu detects that state and offers an **Open Settings** button.

| Trigger | Notification |
|---|---|
| a session blocks on a permission prompt | `<project> needs you`, replaced per session, repeats within 5 s suppressed, removed once the session moves on |
| a session finishes after being busy for at least 10 s | `<name> finished` |
| a turn ends on an API error | `<name> stopped`, with the reason |
| a background job blocks on a question | `<name> is blocked`, with the question, keyed on the question so a new one alerts and a re-read does not |
| a session passes 85% of its context | `<name> is at <n>% context`, armed again once it drops below 70% |
| a plan limit passes 80% or 95% | `<limit> usage at <n>%`, once per threshold per window, so it fires again after the window resets |
| the Wi-Fi association drops | `Wi-Fi dropped`, withdrawn when the link comes back |

The app puts a small symbol in front of some of these titles. The 10 second floor exists so that two-second replies do not produce banner noise. Banners about a session carry its pid and a **Focus** button, so one can take you to the window rather than only tell you about it. The permission, finished and stopped banners need [hooks](hooks-and-privacy.md).
