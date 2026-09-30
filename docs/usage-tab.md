# Usage tab

Plan limits, the link they depend on, what the sessions cost the machine, and the tokens and dollars behind today. Nothing on this tab calls an API or holds a credential.

## Plan limits

Claude Code fetches your plan utilisation from its usage endpoint and caches the result in `~/.claude.json` under `cachedUsageUtilization`. The panel renders one meter for each entry in `utilization.limits`, up to four: currently the rolling 5 hour session window, the weekly all-model window, and a weekly window scoped to one model. A limit kind added later shows up on its own with a generated title (`monthly_credits` reads "Monthly Credits") instead of needing a code change.

**The figures are only as fresh as Claude Code's last fetch**, which is why the fetch time is printed under them. The app never asks the API, because it has no credentials and does not want any. If the cache is missing, the section says so instead of showing zeroes.

Claude Code rewrites that file in place while the app may be reading it. A read that fails to decode keeps the previous reading instead of blanking the section, and a read is skipped entirely unless the file's size or modification time changed.

`resets_at` carries six fractional digits. The app cuts the fraction to three before parsing, because `ISO8601DateFormatter` has historically rejected longer ones. On macOS 27 it accepts them (checked on 30 Sep 2026), so the trim only matters on older releases, which were not tried. The tests cover six digits, three, none, and an offset other than UTC.

Severity comes from the API's own `severity` field rather than from a threshold picked here, because the thresholds are Anthropic's. `critical` and `exceeded` read as critical, `warning` as warning. A word this build has never seen falls back to the percentage, at 75% and 90%. The same three-step colour scale is used for the context rings and the signal bars, so a colour means the same thing everywhere in the menu.

A limit passing 80% or 95% posts a notification, once per threshold per window, so it fires again after the window resets.

### Forecast

The limits arrive as percentages with no token count behind them, so the only rate that can be measured is percent per hour, and the only way to measure it is to watch the percentages move. Each fetch is recorded to `~/.claude/claude-deck/usage-history.jsonl`, one sample per fetch and at most 400, newest kept.

The line "on course to hit 100% Thu 4:30 AM" appears only when all of this holds:

- Only samples since the last reset count. A percentage that fell is a new window, and averaging across the boundary would halve every rate.
- The samples are sorted before the fit instead of trusted in file order, because one landing out of order would read as a reset and silently cut the window.
- There are at least three samples spanning at least an hour, and the rate is positive.
- The limit is below 100% and would fill before it resets.

Silence early on is the honest answer, not an extrapolation from two readings. Each condition has its own test in `ForecastTests`.

## Wi-Fi

`CWInterface` reports signal strength, noise and transmit rate without an entitlement. The app does not ask for Location permission (its `Info.plist` has no location entry) and does not read the SSID or BSSID, so the interface name is never shown and no location data is touched.

Bars follow the usual 802.11 thresholds: -55 dBm or better is excellent, -67 is the floor for sustained throughput, -75 the floor for a usable link. A powered-on interface that is not associated reports a signal of exactly 0, which is what "offline" is detected from. The section is hidden on a machine with no Wi-Fi hardware. A dropped link posts a notification, withdrawn when it comes back.

It earns its place next to the plan limits because it is the other reason a long agent run stops in the middle of a tool call, and the one you cannot see from inside Claude Code.

## Machine

What the sessions cost the machine, as opposed to the plan: CPU, resident memory, the size of `~/.claude`, and free disk. The busiest session is named when it is using at least 5% of a core. Background jobs are counted too. They are not listed as sessions, but they are processes on this machine and usually the hungriest ones.

Everything but the disk size comes from `proc_pid_rusage`: one system call per process, no subprocess, and the same source Activity Monitor reads. Three things had to be right for the numbers to agree with it, and none of them is obvious.

**Memory is `phys_footprint`, not resident size.** Activity Monitor's Memory column is the footprint, and the two are far apart. The author measured sessions reading 182, 156 and 220 MB resident with footprints of 302, 360 and 523 MB, so resident size reported roughly half: 1.69 GB where Activity Monitor said 3.78.

**`ri_user_time` is in mach ticks, not nanoseconds**, whatever the name suggests. The timebase on Apple silicon is 125/3, so dividing by a billion under-reports CPU by a factor of about forty-two (the author saw 51.7 seconds where `ps` said 2152.6). Re-checked on 30 Sep 2026 on macOS 27: the tick conversion agrees with `getrusage` (0.063 s against 0.066 s over a 0.75 s loop), and two tests keep it honest, one against the wall clock and one against `getrusage`.

**Averaged CPU is useless here.** `ps -o %cpu` covers the whole life of a process, so a session open for a fortnight reads 0.1% while pinning a core. CPU is differenced between samples instead, which is why the reader holds state and the first reading is blank. It is measured against one core, so 250% means two and a half cores busy. Colour turns to warning at 60% and critical at 150%.

The author checked the row against the system on 11 Aug 2026 across twelve live sessions. Not re-run here.

| | Deck | Independent source |
|---|---|---|
| Memory | 3871 MB | 3871 MB, `vmmap` Physical footprint |
| CPU | 18.6% | 20.0%, `ps` cumulative-time delta over 5 s |

Memory was byte-identical. CPU differs by design: the two cover overlapping rather than identical windows, and `ps` rounds cumulative time to hundredths. With the naive nanosecond conversion it would have read 0.4%. Activity Monitor's own total will still read higher, correctly, because it lists the shells, `rg` and build tools a session spawns as separate rows and this counts `claude` itself.

Memory turns to warning at 4 GB and critical at 8 GB. Free disk turns to warning under 30 GB and critical under 10 GB. `~/.claude` is measured with `du` at most every five minutes. The author reports it walks a gigabyte of transcripts in about a tenth of a second, and that it grows without anyone deciding that it should.

**Energy and network are deliberately absent.** The author tried both and measured them: `top -stats power` costs about 1.5 seconds per sample and reports `0.0` without a sampling window, and `nettop` costs 5 seconds and returns nothing useful without privileges this app has no business holding. A slow, falsely precise number is worse than no number.

## Tokens and cost

Two sources, with different freshness, both labelled in the menu.

- **Today** is live. The app tails every transcript modified today, remembers a byte offset per file, and reads only what was appended since. The breakdown splits it into input, output, cache writes and cache reads, by model and by project.
- **Lifetime** is `~/.claude/stats-cache.json` plus a transcript top-up. Claude Code only recomputes that file when you open its own stats screen, so it can be days or weeks stale, and a model released since then is missing from it entirely. The days it covers come from the file. Everything after its `lastComputedDate` is read from transcripts, and the label becomes "Sep 21 + live" to say so. Its `costUSD` fields are not used.

**Today is counted once per request. The two Claude Code figures are not.** Claude Code writes one transcript line per content block of an assistant message and repeats the identical `usage` on each, so adding lines up counts a message several times (1.84 times on one day the author measured). Today is therefore deduplicated by `message.id`, keeping the last line of each message because `output_tokens` grows as blocks stream in. A forked session repeats another transcript's messages verbatim, so the dedupe runs across files too. A line with no message id cannot be folded and counts once. The API bills once per request, so this is the basis a cost estimate needs.

`stats-cache.json` sums per line, and its daily figures leave cache tokens out, which is why the "recent days" rows are labelled `input + output only` and come out much smaller than today.

**Lifetime therefore mixes two bases:** the cached half counts per content block, the topped-up half per request. The alternative, recomputing the whole of it from transcripts, is not available because old transcripts get deleted. With no cache to build on, the lifetime row stays empty rather than reporting a few days of transcripts as a lifetime.

One scan serves both figures. It starts the day after `lastComputedDate` instead of at midnight, and today is the subset it finds that is past the start of the local day. The window only moves when Claude Code recomputes its cache, so the per-file offsets survive midnight. The first scan after launch is the only expensive one (about 500 MB on the author's machine), and it runs on a background task, so the menu shows the previous figures until it lands.

The project for each request comes from the transcript's own `cwd`. The directory name under `~/.claude/projects` has `/` replaced by `-`, which is ambiguous to undo: `shorts-engine` and `shorts/engine` encode identically.

### Cost

Cost is computed here from `~/.claude/claude-deck/prices.json`, which is written with defaults on first run and re-read whenever it changes. Cache reads are charged at 0.1 times the input rate and cache writes at 1.25 times. The 1 hour cache write rate of 2 times is not modelled, because transcripts do not reliably distinguish the two. A model with no entry is left out of the total and reported as "n models unpriced" instead of guessed at.

The default prices are the author's entries for Anthropic's first-party API list prices. They were not re-checked here, and the file is yours to edit. **A Max or Pro subscription is not billed per token**, so the figure is a usage-equivalent estimate, not a bill, and is always shown with "est".

The dollars per hour beside today's estimate are measured from the day's first assistant message rather than from midnight, so a day that started at 14:00 does not report a quarter of its real rate. The divisor is held at a quarter of an hour, so one request in the last minute cannot report a four-figure rate.

Covered by `CostTests` (every multiplier, model id matching, the price file, the burn rate) and `StatsScanTests` (the dedupe, forks, partial lines, the lifetime top-up).
