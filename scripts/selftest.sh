#!/bin/bash
# Checks that this plugin still works with the installed Claude Code.
#
# Runs one headless Claude Code session against a local mock API that rejects
# the request, with a stub fallback agent, and verifies each step of the chain:
# the plugin loads, the prompt is captured, the StopFailure hook fires and can
# read the error, and the detached handoff runs. Costs no tokens and sends
# nothing off the machine.
#
#   selftest.sh           run only if Claude Code or the plugin changed since the last check
#   selftest.sh --force   run now and print the result
set -u

command -v jq >/dev/null 2>&1 || { echo "failover: jq is required" >&2; exit 69; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

force=false
[[ "${1:-}" == "--force" ]] && force=true
ensure_home
status="$FAILOVER_HOME/selftest.json"

claude_bin="${CLAUDE_CODE_EXECPATH:-claude}"
command -v "$claude_bin" >/dev/null 2>&1 || claude_bin=claude
cc_version=$("$claude_bin" --version 2>/dev/null | head -n 1)
plugin_version=$(jq -r '.version // "unknown"' "$here/../.claude-plugin/plugin.json" 2>/dev/null)
key="$cc_version | plugin $plugin_version"

if ! $force && [[ -f "$status" && "$(jq -r '.key // empty' "$status" 2>/dev/null)" == "$key" ]]; then
  exit 0
fi

lock="$FAILOVER_HOME/tmp/selftest.lock"
[[ -d "$lock" && -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
mkdir "$lock" 2>/dev/null || exit 0   # another session is already checking
work=""
mock=""
cleanup() {
  [[ -n "$mock" ]] && { kill "$mock"; wait "$mock"; } 2>/dev/null
  [[ -n "$work" ]] && { rm -rf "$work" || { sleep 1; rm -rf "$work"; }; } 2>/dev/null
  rmdir "$lock" 2>/dev/null
}
trap cleanup EXIT

finish() { # finish <ok: true|false|null> <detail>
  jq -n --arg key "$key" --arg cc "$cc_version" --arg pv "$plugin_version" --arg d "$2" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ok "$1" \
    '{key: $key, cc_version: $cc, plugin_version: $pv, ok: $ok, detail: $d, checked_at: $at}' >"$status"
  log_event "$(jq -n --arg cc "$cc_version" --arg d "$2" --argjson ok "$1" '{event: "selftest", cc_version: $cc, ok: $ok, detail: $d}')"
  case "$1" in
    true) echo "failover self-test passed on $cc_version (plugin $plugin_version)." ;;
    false)
      echo "failover self-test FAILED on $cc_version (plugin $plugin_version): $2"
      echo "Log: $FAILOVER_HOME/selftest.log"
      notify "failover: self-test failed" "The plugin may not work with $cc_version. Run /failover:selftest in Claude Code for details."
      ;;
    *) echo "failover self-test skipped: $2" ;;
  esac
  [[ "$1" != "false" ]]
  exit $?
}

[[ -n "$cc_version" ]] || finish null "could not run the claude command"
command -v python3 >/dev/null 2>&1 || finish null "python3 is needed for the local mock API"

work=$(mktemp -d "$FAILOVER_HOME/tmp/selftest.XXXXXX") || finish null "could not create a working directory"
mkdir "$work/cwd"
token="failover-selftest-$$-$RANDOM"
printf '#!/bin/bash\ncat >"%s/brief"\n' "$work" >"$work/agent.sh"
chmod +x "$work/agent.sh"
jq -n --arg c "$work/agent.sh" '{command: $c, auto: true, wake: false, notify: false, selftest: false}' >"$work/failover.json"

python3 "$here/selftest_mock.py" "$work/port" "$work/hits" >"$work/mock.log" 2>&1 &
mock=$!
for _ in $(seq 1 150); do [[ -s "$work/port" ]] && break; sleep 0.1; done   # a cold python3 can be slow
[[ -s "$work/port" ]] || finish null "the local mock API did not start: $(tail -n 2 "$work/mock.log" 2>/dev/null | tr '\n' ' ')"

(
  cd "$work/cwd" || exit 1
  exec env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
    -u FAILOVER_ACTIVE -u FAILOVER_TRACE -u FAILOVER_PAYLOAD -u FAILOVER_WAKE_FILE \
    FAILOVER_SELFTEST=1 FAILOVER_HOME="$work/state" FAILOVER_CONFIG="$work/failover.json" \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$work/port")" ANTHROPIC_AUTH_TOKEN=failover-selftest \
    "$claude_bin" -p "$token" --model sonnet --setting-sources project --no-session-persistence \
    --plugin-dir "$here/.." </dev/null >"$work/claude.log" 2>&1
) &
session=$!
( sleep 90; kill -TERM "$session"; sleep 5; kill -KILL "$session" ) 2>/dev/null &
watchdog=$!
wait "$session" 2>/dev/null
{ pkill -P "$watchdog"; kill "$watchdog"; wait "$watchdog"; } 2>/dev/null

# The handoff runs detached from the session, so give it a moment to land, but
# stop waiting early when the StopFailure hook never fired at all.
for i in $(seq 1 50); do
  [[ -s "$work/brief" ]] && break
  (( i > 15 )) && ! grep -qs '"event":"stop_failure"' "$work/state/events.jsonl" && break
  sleep 0.2
done
# Let the detached handoff finish writing before its files are checked and removed.
for _ in $(seq 1 25); do
  [[ ! -s "$work/brief" ]] && break
  grep -qs '"event":"handoff_finished"' "$work/state/events.jsonl" && break
  sleep 0.2
done

failed=""
grep -qs "$token" "$work"/state/sessions/*/history.jsonl || failed+="the prompt was not captured (UserPromptSubmit hook); "
grep -qs '"event":"stop_failure"' "$work/state/events.jsonl" || failed+="the StopFailure hook did not fire; "
grep -qs '"kind":"policy"' "$work/state/events.jsonl" || failed+="the error text was not readable from the hook input; "
grep -qs "$token" "$work/brief" || failed+="the fallback agent was not started with the request; "

if [[ -n "$failed" ]]; then
  {
    echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) $key"
    echo "failed: $failed"
    echo "-- claude output"; tail -n 30 "$work/claude.log" 2>/dev/null
    echo "-- plugin events"; cat "$work/state/events.jsonl" 2>/dev/null
  } >"$FAILOVER_HOME/selftest.log"
  # If Claude Code never reached the mock, the environment got in the way (a proxy,
  # another provider, an older CLI) and the run says nothing about the plugin.
  [[ -s "$work/hits" ]] || finish null "Claude Code did not reach the local mock API, so nothing could be checked"
  finish false "${failed%; }"
fi
finish true "all checks passed"
