# Demo mode

Claude Deck can run on invented data. That is how anyone can try it without a Claude Code history on the machine, and how the images in the README are made. It never touches a real `~/.claude`.

```sh
make build
scripts/demo.sh
```

Click the terminal icon in the menu bar. Ctrl-C in the terminal stops the app, ends the stand-in processes and deletes the demo data.

## What is in it

- Four live sessions: one waiting on a permission prompt, two busy inside a tool, one idle with most of its context used (so it reads **stale**).
- Two dormant sessions, folded into one row.
- Two background jobs, one of them blocked on a question with three options.
- Plan limits at 24% and 82% with a forecast for the weekly one, and a week of token history.
- Transcripts for today, so the token count and the estimated cost are computed, not typed in.
- Hooks installed, so the footer reads "Hooks installed".

Every session is backed by a real `sleep` process, because the app checks that a session's pid is alive and that its start time matches the session file. The names, prompts, token counts and limits are made up. The model names and prices are the app's own defaults.

Three things on the Usage tab and the footer come from the machine running the demo, because they are read live: the Wi-Fi link, free disk space, and the **Launch at login** checkbox. The Machine row shows the stand-in processes, so CPU is near zero and memory is a few megabytes, which is what they are.

The script writes hook events after the app has started, the way they arrive for real. The readers only report lines appended after launch, so events written before it would be ignored.

## How it stays away from your real data

Two environment variables, both set by the script.

| Variable | Does |
|---|---|
| `CFFIXED_USER_HOME` | Moves `NSHomeDirectory()`, and with it every path the app reads and every preference it saves. `HOME` does not do this on macOS. |
| `CLAUDE_DECK_DEMO_HOME` | Marks the run as a demo and names the directory the app must see. |

If the two disagree, because the redirect did not take, the app prints why and exits with status 78 before its store reads a file. A test covers the check, and it was also run by hand with mismatched directories.

A demo run also posts no notifications, does not ask for notification permission, and switches off the News refresh, so nothing in it can spend plan usage or interrupt anyone. The script copies the app into the demo home first, so the footer does not offer to install it, and it kills only the processes it started.

## The images

```sh
scripts/demo.sh --snapshot docs/images
```

The app renders its own panels and quits. It hosts the real `MenuContent`, bound to the real `SessionStore` reading the demo home, inside a borderless window placed far outside every display, and draws it into a bitmap at twice the resolution with AppKit. The Sessions tab and the Usage tab are drawn side by side, in a dark and a light version, on a flat ground with the rounded corners and hairline edge the real popover has.

Nothing is captured from the screen, so nothing behind the panel can end up in the picture. The limits of the method:

- The translucent material the system puts behind a menu bar panel is replaced by a flat colour of roughly the same value.
- The window is not active, so the selected segment of the tab picker is drawn the way macOS draws it in an inactive window.
- Each tab is a fixed-height box, so the Usage tab has empty space under its content. The real app looks the same.
- The time-dependent parts (the forecast time, "as of", countdowns) are those of the moment it was rendered.

## Variables

| Variable | Default | |
|---|---|---|
| `CLAUDE_DECK_SNAPSHOT` | unset | Folder to write `hero-dark.png` and `hero-light.png` into. Only honoured in a demo. |
| `CLAUDE_DECK_SNAPSHOT_DELAY` | 8 | Seconds to wait after launch before rendering, so the first reads have landed. |
