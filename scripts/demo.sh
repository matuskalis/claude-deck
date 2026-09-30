#!/bin/bash
# Runs Claude Deck against invented sessions, so it can be tried, or photographed, without a
# Claude Code history and without touching a real ~/.claude.
#
#   scripts/demo.sh                     start the demo; look for the terminal icon in the menu bar
#   scripts/demo.sh --snapshot docs/img render the panels to PNG files in that folder, then quit
#
# Everything lives in a throwaway home directory that is deleted when the script ends. The app
# is pointed at it with CFFIXED_USER_HOME, which is what moves NSHomeDirectory() on macOS
# (HOME does not), and CLAUDE_DECK_DEMO_HOME, which makes the app refuse to start if the
# redirect did not take. A demo posts no notifications and never starts claude.
#
# CFFIXED_USER_HOME does not move saved preferences, so the copy of the app that runs here
# gets a bundle identifier of its own. Its preferences and its launch-at-login state are
# then separate from an installed Claude Deck's, and the script deletes them when it stops.
#
# The sessions are real processes (sleep), because the app checks that a session's pid is
# alive and that its start time matches the session file. The names, prompts, token counts,
# plan limits, Wi-Fi link and free disk space are invented. The Machine row is measured, from
# those sleep processes.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP_SRC="$ROOT/dist/Claude Deck.app"
SNAPSHOT_DIR=""

case "${1:-}" in
  "") ;;
  --snapshot)
    [ -n "${2:-}" ] || { echo "usage: scripts/demo.sh [--snapshot <folder>]" >&2; exit 2; }
    mkdir -p "$2"
    SNAPSHOT_DIR=$(cd "$2" && pwd)
    ;;
  *) echo "usage: scripts/demo.sh [--snapshot <folder>]" >&2; exit 2 ;;
esac

[ -x "$APP_SRC/Contents/MacOS/ClaudeDeck" ] || { echo "No build found. Run: make build" >&2; exit 1; }

DEMO_HOME=$(mktemp -d "${TMPDIR:-/tmp}/claude-deck-demo.XXXXXX")
CLAUDE="$DEMO_HOME/.claude"
PIDS=""
APP_PID=""

DEMO_ID=com.matuskalis.claude-deck.demo

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  # Only what the demo copy saved, under its own identifier. Never the installed app's.
  defaults delete "$DEMO_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEMO_ID.plist"
  case "$DEMO_HOME" in */claude-deck-demo.*) rm -rf "$DEMO_HOME" ;; esac
}
trap cleanup EXIT INT TERM

mkdir -p "$CLAUDE"/{sessions,projects,jobs,cache,claude-deck} "$DEMO_HOME/Applications" "$DEMO_HOME/projects"

# ---- time helpers -----------------------------------------------------------------------

NOW=$(date +%s)
MIDNIGHT=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s)
ms_ago()  { echo $(( (NOW - $1) * 1000 )); }
iso_ago() { date -u -r $(( NOW - $1 )) +%Y-%m-%dT%H:%M:%S.000Z; }
iso_in()  { date -u -r $(( NOW + $1 )) +%Y-%m-%dT%H:%M:%S.000000+00:00; }
# Keeps a timestamp on today's side of midnight, so "today" has something in it at any hour.
today_age() { local limit=$(( NOW - MIDNIGHT - 30 )); [ "$limit" -lt 0 ] && limit=0; [ "$1" -gt "$limit" ] && echo "$limit" || echo "$1"; }

# ---- sessions ---------------------------------------------------------------------------

# Sets SPAWNED rather than printing the pid: a command substitution would run in a subshell,
# and the pid would never reach PIDS for cleanup.
spawn() {
  sleep 7200 &
  SPAWNED=$!
  PIDS="$PIDS $SPAWNED"
  disown "$SPAWNED"
}

proc_start() { TZ=UTC ps -o lstart= -p "$1" | sed -E 's/^ +//; s/ +/ /g'; }

# session <id> <name> <status> <status-age-seconds> <started-age-seconds> [kind] [jobId]
session() {
  local id=$1 name=$2 status=$3 status_age=$4 started_age=$5 kind=${6:-interactive} job=${7:-}
  spawn
  local pid=$SPAWNED
  local extra=""; [ -n "$job" ] && extra=",\"jobId\":\"$job\""
  cat > "$CLAUDE/sessions/$pid.json" <<EOF
{"pid":$pid,"sessionId":"$id","cwd":"$DEMO_HOME/projects/$name","startedAt":$(ms_ago "$started_age"),"procStart":"$(proc_start "$pid")","version":"2.1.220","kind":"$kind","name":"$name","status":"$status","updatedAt":$(ms_ago "$status_age"),"statusUpdatedAt":$(ms_ago "$status_age")$extra}
EOF
}

# transcript <id> <project> <model> <messages> <final-context-tokens>
# One assistant message every seven minutes, the last a minute ago, context growing to the last figure.
transcript() {
  local id=$1 project=$2 model=$3 messages=$4 final=$5
  local dir="$CLAUDE/projects/-demo-$project"; mkdir -p "$dir"
  local i age cache_read
  : > "$dir/$id.jsonl"
  for i in $(seq 1 "$messages"); do
    age=$(today_age $(( (messages - i) * 420 + 60 )))
    cache_read=$(( (final - 6000) * i / messages ))
    printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"msg_%s_%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
      "$(iso_ago "$age")" "$DEMO_HOME/projects/$project" "${id: -12}" "$i" "$model" 40 $(( 600 + i * 90 )) 4000 "$cache_read" >> "$dir/$id.jsonl"
    # The first message is written twice, the way Claude Code writes a message of several blocks.
    if [ "$i" -eq 1 ]; then
      printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"msg_%s_%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
        "$(iso_ago "$age")" "$DEMO_HOME/projects/$project" "${id: -12}" "$i" "$model" 40 $(( 600 + i * 90 )) 4000 "$cache_read" >> "$dir/$id.jsonl"
    fi
  done
}

prompt() { printf '{"display":"%s","sessionId":"%s","timestamp":%s}\n' "$2" "$1" "$(ms_ago "$3")" >> "$CLAUDE/history.jsonl"; }

HARBOR=11111111-0000-4000-8000-000000000001
LEDGER=11111111-0000-4000-8000-000000000002
MOBILE=11111111-0000-4000-8000-000000000003
DOCS=11111111-0000-4000-8000-000000000004

session $HARBOR harbor-api idle 95 14000
session $LEDGER ledger-web busy 160 9000
session $MOBILE mobile-sync busy 252 12000
session $DOCS docs-site idle 3100 20000
# Two tabs left open for days: idle for more than twelve hours, so they fold into one row.
for n in 1 2; do
  session "22222222-0000-4000-8000-00000000000$n" "scratch-$n" idle $(( 26 * 3600 * n )) $(( 27 * 3600 * n ))
done

transcript $HARBOR harbor-api claude-opus-5 9 144000
transcript $LEDGER ledger-web claude-opus-5 7 82000
transcript $MOBILE mobile-sync claude-sonnet-5 8 184000
transcript $DOCS docs-site claude-opus-5 6 152000

prompt $HARBOR "add retry with backoff to the webhook sender" 1500
prompt $LEDGER "the invoice table should sort by due date, not created date" 700
prompt $MOBILE "why does the offline queue replay twice after a reconnect" 900
prompt $DOCS "draft the migration guide for the new auth flow" 4200

# ---- background jobs --------------------------------------------------------------------

JOB_A=job-migrate-invoices
JOB_B=job-nightly-audit
session 33333333-0000-4000-8000-000000000001 migrate-invoices working 300 7000 bg $JOB_A
session 33333333-0000-4000-8000-000000000002 nightly-audit working 120 5000 bg $JOB_B

mkdir -p "$CLAUDE/jobs/$JOB_A" "$CLAUDE/jobs/$JOB_B"
cat > "$CLAUDE/jobs/$JOB_A/state.json" <<EOF
{"name":"migrate-invoices","state":"working","tempo":"blocked","detail":"Backfilling invoice totals into the new schema","needs":"Waiting for a decision on the legacy rows","block":{"questions":[{"question":"43 invoices predate the new schema. Migrate them, skip them, or flag them for review?","options":[{"label":"Migrate"},{"label":"Skip"},{"label":"Flag for review"}]}]},"cwd":"$DEMO_HOME/projects/harbor-api","tokens":1900000,"sessionId":"33333333-0000-4000-8000-000000000001","updatedAt":"$(iso_ago 300)","inFlight":{"tasks":0,"queued":0}}
EOF
cat > "$CLAUDE/jobs/$JOB_B/state.json" <<EOF
{"name":"nightly-audit","state":"working","tempo":"steady","detail":"Running the integration suite while a subagent reviews the auth diff","cwd":"$DEMO_HOME/projects/ledger-web","tokens":640000,"sessionId":"33333333-0000-4000-8000-000000000002","updatedAt":"$(iso_ago 120)","inFlight":{"tasks":2,"queued":1},"fan":[{"id":"t1","kind":"shell","label":"npm run test:integration","startedAt":$(ms_ago 581)},{"id":"t2","kind":"agent","label":"review the auth diff","startedAt":$(ms_ago 120)}]}
EOF
cat > "$CLAUDE/jobs/$JOB_A/timeline.jsonl" <<EOF
{"at":"$(iso_ago 1800)","state":"working","detail":"Read 1,204 invoices, 43 have no currency field"}
{"at":"$(iso_ago 300)","state":"blocked","detail":"Stopped before writing: the 43 legacy rows need a decision"}
EOF

# ---- plan limits and what they are doing ------------------------------------------------

cat > "$DEMO_HOME/.claude.json" <<EOF
{"cachedUsageUtilization":{"fetched_at_ms":$(ms_ago 40),"utilization":{"limits":[
{"kind":"session","group":"session","percent":24.3,"severity":"normal","resets_at":"$(iso_in 14520)","is_active":true},
{"kind":"weekly_all","group":"weekly","percent":82.1,"severity":"warning","resets_at":"$(iso_in 214000)","is_active":true},
{"kind":"weekly_scoped","group":"weekly","percent":12.0,"severity":"normal","resets_at":"$(iso_in 214000)","scope":{"model":{"display_name":"Opus"}},"is_active":false}
]}}}
EOF
# Earlier readings of the weekly limit, two points every two hours, so the forecast has a line to fit.
{
  for k in 4 3 2 1; do
    printf '{"at":%s,"kind":"weekly_all","percent":%s}\n' "$(( NOW - k * 7200 ))" "$(( 82 - k * 4 ))"
  done
} > "$CLAUDE/claude-deck/usage-history.jsonl"

# ---- lifetime figures, settings and the hooks -------------------------------------------

LAST_COMPUTED=$(date -j -v-9d +%Y-%m-%d)
cat > "$CLAUDE/stats-cache.json" <<EOF
{"lastComputedDate":"$LAST_COMPUTED","totalSessions":239,"modelUsage":{
"claude-opus-5":{"inputTokens":4100000,"outputTokens":21000000,"cacheReadInputTokens":5100000000,"cacheCreationInputTokens":410000000},
"claude-sonnet-5":{"inputTokens":1200000,"outputTokens":6000000,"cacheReadInputTokens":800000000,"cacheCreationInputTokens":60000000}},
"dailyModelTokens":[
{"date":"$(date -j -v-15d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":310000,"claude-sonnet-5":90000}},
{"date":"$(date -j -v-14d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":520000,"claude-sonnet-5":110000}},
{"date":"$(date -j -v-13d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":280000,"claude-sonnet-5":60000}},
{"date":"$(date -j -v-12d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":700000,"claude-sonnet-5":150000}},
{"date":"$(date -j -v-11d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":640000,"claude-sonnet-5":120000}},
{"date":"$(date -j -v-10d +%Y-%m-%d)","tokensByModel":{"claude-opus-5":410000,"claude-sonnet-5":80000}},
{"date":"$LAST_COMPUTED","tokensByModel":{"claude-opus-5":590000,"claude-sonnet-5":130000}}]}
EOF

# Every hook the installer writes, with the exact commands, so the footer reads "Hooks installed".
hook() { printf '"%s":[{"hooks":[{"type":"command","command":"\\"$HOME/.claude/claude-deck/spool\\" %s %s","timeout":5}]}]' "$1" "$2" "$1"; }
{
  echo '{"model":"claude-opus-5","hooks":{'
  echo "$(hook Notification events),$(hook Stop events),$(hook StopFailure events),$(hook UserPromptSubmit events),$(hook SessionEnd events),$(hook PreToolUse tools),$(hook PostToolUse tools)"
  echo '}}'
} > "$CLAUDE/settings.json"

# ---- start ------------------------------------------------------------------------------

# Copied in as if installed, so the footer does not offer to install it, with a bundle identifier
# of its own (and signed again, since the identifier is part of the signature).
DEMO_APP="$DEMO_HOME/Applications/Claude Deck.app"
ditto "$APP_SRC" "$DEMO_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$DEMO_APP/Contents/Info.plist"
signing=$(codesign --force --sign - "$DEMO_APP" 2>&1) || { echo "$signing" >&2; exit 1; }

export CFFIXED_USER_HOME="$DEMO_HOME" CLAUDE_DECK_DEMO_HOME="$DEMO_HOME"
[ -n "$SNAPSHOT_DIR" ] && export CLAUDE_DECK_SNAPSHOT="$SNAPSHOT_DIR"
"$DEMO_APP/Contents/MacOS/ClaudeDeck" &
APP_PID=$!

# Hook events only count when they arrive after the app has started, as they do for real.
sleep 3
printf '{"hook_event_name":"Notification","session_id":"%s","message":"Claude needs your permission to run Bash"}\n' "$HARBOR" >> "$CLAUDE/claude-deck/events.jsonl"
printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Edit"}\n' "$LEDGER" >> "$CLAUDE/claude-deck/tools.jsonl"
printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash"}\n' "$MOBILE" >> "$CLAUDE/claude-deck/tools.jsonl"

if [ -n "$SNAPSHOT_DIR" ]; then
  wait "$APP_PID" || true
  APP_PID=""
  ls "$SNAPSHOT_DIR"
else
  echo "Claude Deck is running on demo data. Click the terminal icon in the menu bar."
  echo "Ctrl-C here stops it and deletes the demo data."
  wait "$APP_PID" || true
  APP_PID=""
fi
