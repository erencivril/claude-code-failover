#!/bin/bash
# Hands a task to the fallback agent configured in ~/.claude/failover.json.
#
#   handoff.sh [--session ID] [--cwd DIR] [--reason TEXT] < task.txt   manual: prints the result
#   handoff.sh --auto --session ID --cwd DIR --reason TEXT             from the StopFailure hook:
#       takes the task from the session's recorded history, leaves the result as
#       pending for that session, and reports its path through FAILOVER_WAKE_FILE
#
# The configured command runs in DIR with the brief on stdin. It also gets
# FAILOVER_BRIEF_FILE (path to the same brief), FAILOVER_REASON and FAILOVER_SESSION_ID.
set -u

command -v jq >/dev/null 2>&1 || { echo "failover: jq is required" >&2; exit 69; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

auto=false sid="" cwd="$PWD" reason="manual"
while (( $# )); do
  case "$1" in
    --auto) auto=true ;;
    --session) sid=${2:-}; shift ;;
    --cwd) cwd=${2:-}; shift ;;
    --reason) reason=${2:-}; shift ;;
    *) echo "failover: unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
sid=$(safe_id "$sid")

# The StopFailure hook waits on this file to learn how an automatic handoff ended:
# the path of the pending result, or "none" when nothing was handed off.
wake_file="${FAILOVER_WAKE_FILE:-}"
unset FAILOVER_WAKE_FILE
report_wake() {
  [[ -n "$wake_file" && ! -s "$wake_file" ]] && printf '%s' "$1" >"$wake_file"
  return 0
}
$auto && trap 'report_wake none' EXIT
sdir="$FAILOVER_HOME/sessions/$sid"
history="$sdir/history.jsonl"

command_line=$(cfg command "")
if [[ -z "$command_line" ]]; then
  echo "failover: no handoff command configured. Set \"command\" in $FAILOVER_CONFIG (see the README)." >&2
  exit 78
fi
cd "$cwd" 2>/dev/null || { echo "failover: cannot enter $cwd" >&2; exit 66; }

if $auto; then
  mkdir -p "$sdir"
  handoff_running "$sdir" && exit 0
  echo $$ >"$sdir/handoff.pid"
  trap 'rm -f "$sdir/handoff.pid"; report_wake none' EXIT
  task=""
  [[ -f "$history" ]] && task=$(jq -rs 'map(select(.role == "user")) | last | .text // empty' "$history" 2>/dev/null)
else
  task=$(cat)
fi
if [[ -z "${task//[[:space:]]/}" ]]; then
  echo "failover: nothing to hand off (empty task)" >&2
  $auto && log_event "$(jq -n --arg s "$sid" '{event: "handoff_skipped", session_id: $s, why: "no request recorded for this session"}')"
  exit 64
fi

run="$FAILOVER_HOME/runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run"
brief="$run/brief.md"
{
  echo "You are taking over a coding task from another AI coding agent whose session stopped before it could finish (reason: $reason)."
  echo "Work in the current directory. It already contains whatever the previous agent changed, so check the current state before editing. Finish the task below, then end with a short summary of what you did and anything you left undone."
  echo
  echo "## Task"
  echo
  printf '%s\n' "$task"
  turns=$(cfg history 6)
  if [[ -f "$history" && "$turns" =~ ^[0-9]+$ && "$turns" -gt 0 ]]; then
    echo
    echo "## Recent conversation in the stopped session (oldest first)"
    echo
    jq -rs --argjson n "$turns" '
      .[-$n:] | map((if .role == "user" then "User" else "Previous agent" end) + ": " + .text[0:2000]) | join("\n\n")' "$history" 2>/dev/null
  fi
} >"$brief"

before=$(snapshot)
SECONDS=0
FAILOVER_ACTIVE=1 FAILOVER_BRIEF_FILE="$brief" FAILOVER_REASON="$reason" FAILOVER_SESSION_ID="$sid" \
  bash -c "$command_line" <"$brief" >"$run/stdout.log" 2>"$run/stderr.log" &
agent=$!
limit=$(cfg timeout 1800)
[[ "$limit" =~ ^[0-9]+$ ]] || limit=1800
# stderr of the watchdog is discarded so the shell's "Terminated" notice for
# its sleep never reaches the caller.
( sleep "$limit"; kill -TERM "$agent" ) 2>/dev/null &
watchdog=$!
wait "$agent"
rc=$?
{ pkill -P "$watchdog"; kill "$watchdog"; wait "$watchdog"; } 2>/dev/null
after=$(snapshot)

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changed=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | cut -d' ' -f2- | sed 's/^/- /')
  [[ -n "$changed" ]] || changed="(none)"
else
  changed="(not a git repository, so changes were not tracked)"
fi
if [[ -s "$run/stdout.log" ]]; then
  output=$(tail -n 60 "$run/stdout.log")
else
  output=$(tail -n 20 "$run/stderr.log")
fi

result="$run/result.md"
{
  echo "## Failover handoff result"
  echo
  echo "The failover plugin passed a task to the user's configured fallback agent (reason: $reason). It ran in $cwd for ${SECONDS}s and exited with code $rc. Full logs: $run"
  echo
  echo "Task that was handed off:"
  echo
  printf '%s\n' "${task:0:600}" | sed 's/^/> /'
  echo
  echo "Files it changed:"
  echo "$changed"
  echo
  echo "End of the agent's output:"
  echo
  printf '%s\n' "${output:0:4000}" | sed 's/^/    /'
} >"$result"

log_event "$(jq -n --arg s "$sid" --arg r "$reason" --arg d "$run" --argjson rc "$rc" --argjson auto "$auto" \
  '{event: "handoff_finished", session_id: $s, reason: $r, auto: $auto, exit_code: $rc, run: $d}')"

if $auto; then
  mkdir -p "$sdir/pending"
  {
    cat "$result"
    echo
    echo "Treat this as work that already happened in the working directory: check it rather than redoing it, tell the user what the fallback agent did, then continue with whatever is still open."
  } >"$sdir/pending/$(basename "$run").md"
  report_wake "$sdir/pending/$(basename "$run").md"
  if [[ -n "$wake_file" && "$(cfg wake true)" == "true" ]]; then
    notify "Failover handoff finished (exit $rc)" "An open Claude Code session resumes by itself. If you closed it, reopen it and send any message."
  else
    notify "Failover handoff finished (exit $rc)" "Go back to Claude Code and send any message (for example: continue) to pick up the result."
  fi
else
  cat "$result"
fi
exit "$rc"
