# Changelog and News

Two tabs about what is changing around you. One reads a file that is already on disk. The other is the only place the app reaches past the disk, and it says plainly what that costs.

## Changelog

The tab reads the changelog Claude Code already keeps at `~/.claude/cache/changelog.md`. On the author's machine that was 360 releases and 4318 entries. No network, no key, no summarising: the entries are already written, one line each, by the people who made the change. The release you are running is tagged **yours**, taken from the newest version among your live sessions.

It is master and detail. Seven releases are listed and the selected one is written out beneath, up to seven entries with the overflow counted. There are two sliders.

**Detail** has three steps: Highlights, Notable, Everything. The step a line sits at comes from its leading verb, which Claude Code's changelog uses consistently. Of those 4318 entries, 53% begin "Fixed" and another 9% "Improved".

| Step | Shows |
|---|---|
| Highlights | `Added`, `Changed`, `Removed`, and lines that do not start with a known verb |
| Notable | and `Improved` or `Reduced` |
| Everything | and `Fixed` |

Whatever a step holds back is counted beside the version number. Over twenty releases Highlights is 146 lines instead of 488 (the author's count). Only the exact verb counts: a line that starts "Fixes" is a note, not a fix.

**How far back** moves the window of seven through all the releases and is captioned with the oldest release it reaches. It counts releases rather than days because the changelog carries no dates, only version headings, so a "last 24 hours" control would be inventing information the source does not have.

The parse is gated on the file's size and modification time and only runs when the menu is opened. Half a megabyte is not worth re-reading on a timer when nothing about it changes while nobody is looking.

## News

What changed across the other AI coding tools and the people building them. Refresh asks the Claude Code already installed and logged in on this machine to do the reading, so **the app never holds a credential**. It starts a separate headless `claude -p` session with the web search and fetch tools allowed and a cap of 30 turns, which reads the vendors' own release notes and blogs, and the result is cached in `~/.claude/claude-deck/news.json`.

It is master and detail again. Up to six headlines are listed and the selected one is written out beneath. There are two sliders.

**Detail** has three steps: Plain, Balanced, Technical. All three summaries are written in the same run and stored per item, so moving the slider costs nothing: the model is asked once and answers three times. Plain carries no jargon, Balanced names the feature and its consequence, Technical keeps version numbers, limits and benchmarks. A cache written before Balanced existed still loads, and its Balanced step shows Plain.

**How far back** runs from 24 hours to 90 days, a day at a time. The cache holds ninety days of dated items, so every cut-off in that span is a real one and none of them triggers a fetch.

### What it costs

Four things, stated plainly because they are the cost of the feature.

- **It spends your plan usage.** The author measured one run at 20 turns, 143 seconds and $0.88. The panel prints what the last run cost. Refresh is a button, never a timer and never on launch.
- **It refuses when a limit is already critical.** The rest of this app exists to show how close those limits are, and a news panel is not what the last of a weekly allowance is for.
- **It does not speak into any session of yours.** A fresh `claude -p` is its own conversation.
- **The summaries are a model's reading of pages it fetched**, not a publisher's feed. Every item carries its primary-source URL, so click through for anything that matters.

### Who it follows

People as well as tools. The list lives in `~/.claude/claude-deck/news-topics.txt`, written with defaults on first use (five vendors and tools, and a handful of named engineers) and never rewritten after that, so adding or dropping a name does not mean rebuilding the app. Blank lines and lines starting with `#` are ignored, and an emptied file falls back to "Anthropic and Claude Code" rather than sending a prompt with no subject.

Two kinds of source count and nothing else: an organisation's own publishing, or a named person's own words (their blog, talk, repository or post), not somebody's write-up of what they said. No aggregators, no reporting on the reporting, no "reportedly". For a person the prompt prefers something they wrote or built over a personnel announcement, because where someone works is rarely the interesting part. Items must carry a working URL and a publication date, and the prompt drops anything that cannot supply both.

### How the run is made to work

A GUI app inherits no useful `PATH`, so `claude` is found by looking: the native installer's location, the older local install, the npm-global, bun, volta and yarn prefixes, both Homebrew prefixes, and the node version directories of nvm and fnm. A login shell's `command -v claude` is the last resort, because on the author's machine it does not dependably work: the `PATH` entry that finds `claude` is only added for interactive shells.

The process inherits the app's environment instead of getting a hand-built one. A tidy environment of `HOME` and `PATH` alone broke login: the account is stored in the Keychain and looked up by `$USER`, so the CLI reported "Not logged in" and exited having spent nothing. A test pins that.

Sonnet is asked for first, since this is summarising pages and it is the user's plan being spent. A rejected model id fails immediately and costs nothing, so the run is retried once on whatever the user has configured. The run has a seven minute deadline. The author's measured run took about two and a half.

Models wrap JSON in prose and code fences however firmly they are told not to, so the list is taken from the first bracket to the last. If what comes back is not the list that was asked for, the panel says so.

The tests cover the prompt (the topics and the source rules survive edits to the prose around them), the topics file, the environment, pulling the array out of prose and fences, and loading old or broken caches. They do not run the refresh, since that spends plan usage. In [demo mode](demo.md) the refresh is switched off.
