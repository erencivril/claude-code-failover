#!/bin/bash
# End-to-end tests for the hook and handoff scripts, using synthetic hook
# payloads and a stub fallback agent. Needs bash, jq and git. Run: bash tests/test.sh
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$root/scripts/hook.sh"
handoff="$root/scripts/handoff.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export FAILOVER_HOME="$tmp/state"
export FAILOVER_CONFIG="$tmp/failover.json"
unset FAILOVER_ACTIVE FAILOVER_DETACHED FAILOVER_WAKE_FILE
events="$FAILOVER_HOME/events.jsonl"

pass=0 fail=0
check() { # check <name> <command...>
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; fi
}
contains() { grep -Fq -- "$2" <<<"$1"; }
empty() { [[ -z "$1" ]]; }
wait_for() { # wait_for <file glob> — up to 10s
  local i
  for i in $(seq 1 50); do compgen -G "$1" >/dev/null && return 0; sleep 0.2; done
  return 1
}
wait_grep() { # wait_grep <pattern> <file> — up to 10s; StopFailure is handled in a detached process
  local i
  for i in $(seq 1 50); do grep -q -- "$1" "$2" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
config() { printf '%s\n' "$1" >"$FAILOVER_CONFIG"; }
payload() { jq -cn --arg cwd "$repo" "$1 + {cwd: \$cwd}"; }
# fire <payload expr> — runs the hook; sets $out (stdout), $err (stderr), $rc
fire() {
  out=$("$hook" <<<"$(payload "$1")" 2>"$tmp/stderr"); rc=$?
  err=$(cat "$tmp/stderr")
}
prompt() { fire "{hook_event_name: \"UserPromptSubmit\", session_id: \"$1\", prompt: \"$2\"}"; }
stop_failure() { fire "{hook_event_name: \"StopFailure\", session_id: \"$1\", error: \"$2\", last_assistant_message: \"$3\"}"; }
runs() { find "$FAILOVER_HOME/runs" -name brief.md 2>/dev/null | wc -l | tr -d ' '; }

# A stub agent: records the brief it was given, edits one file, creates another.
repo="$tmp/repo"
mkdir -p "$repo" && cd "$repo" || exit 1
git init -q && git config user.email t@example.com && git config user.name t
echo one >tracked.txt && echo two >dirty.txt && git add . && git commit -qm init
echo "two, edited before the handoff" >dirty.txt
cat >"$tmp/agent.sh" <<EOF
#!/bin/bash
cat >"$tmp/brief-seen.md"
echo "active=\${FAILOVER_ACTIVE:-} file=\${FAILOVER_BRIEF_FILE:+set}" >"$tmp/env-seen"
echo "edited by the stub agent" >>dirty.txt
echo new >created.txt
echo "stub agent finished the task"
EOF
chmod +x "$tmp/agent.sh"
auto_config="{\"command\": \"$tmp/agent.sh\", \"auto\": true, \"notify\": false}"

# --- no config: nothing leaves the machine -----------------------------------
rm -f "$FAILOVER_CONFIG"
stop_failure s0 overloaded "API Error: Overloaded"
check "StopFailure without config prints nothing" empty "$out$err"
check "StopFailure without config does not wake the session" test "$rc" -eq 0
check "StopFailure without config is logged" wait_grep '"action":"notified"' "$events"
out=$(echo task | "$handoff" 2>&1); rc=$?
check "manual handoff without config exits 78" test "$rc" -eq 78

# --- conversation history and the refusal nudge -------------------------------
config "$auto_config"
prompt s1 "Add a retry to the uploader"
fire '{hook_event_name: "Stop", session_id: "s1", stop_hook_active: false, last_assistant_message: "Done. I added the retry and the tests pass."}'
check "normal Stop is not blocked" empty "$out"
check "history holds the request and the reply" test "$(wc -l <"$FAILOVER_HOME/sessions/s1/history.jsonl")" -eq 2
prompt s1 "<task-notification>\\n<summary>Stop hook feedback</summary>"
check "turns Claude Code starts itself are not recorded as requests" test "$(wc -l <"$FAILOVER_HOME/sessions/s1/history.jsonl")" -eq 2

fire '{hook_event_name: "Stop", session_id: "s1", stop_hook_active: false, last_assistant_message: "I can’t help with that part."}'
check "refusal Stop is nudged to continue" contains "$out" '"decision": "block"'
fire '{hook_event_name: "Stop", session_id: "s1", stop_hook_active: true, last_assistant_message: "I cannot help with that."}'
check "refusal is nudged only once" empty "$out"
fire '{hook_event_name: "Stop", session_id: "s1", stop_hook_active: false, last_assistant_message: "I can'"'"'t reproduce the flaky test locally."}'
check "ordinary can't is not treated as a refusal" empty "$out"

# --- automatic handoff that wakes the session (interactive) ---------------------
prompt s2 "Refactor the parser module"
stop_failure s2 rate_limit "API Error: Rate limit reached"
check "hook exits 2 to wake the session after the handoff" test "$rc" -eq 2
check "StopFailure prints nothing on stdout" empty "$out"
check "wake message carries the handoff result" contains "$err" "Failover handoff result"
check "result lists a newly created file" contains "$err" "created.txt"
check "result lists a file that was already dirty" contains "$err" "dirty.txt"
check "result carries the agent's output" contains "$err" "stub agent finished the task"
check "agent received the user's request" grep -q "Refactor the parser module" "$tmp/brief-seen.md"
check "agent was told why the session stopped" grep -q "reason: rate_limit" "$tmp/brief-seen.md"
check "agent ran with the loop guard and brief file" grep -q "active=1 file=set" "$tmp/env-seen"
check "delivered result is no longer pending" test -z "$(compgen -G "$FAILOVER_HOME/sessions/s2/pending/*.md")"

# The woken turn dies as well: stop there instead of handing off in a loop.
before=$(runs)
stop_failure s2 rate_limit "API Error: Rate limit reached"
check "a second failure right after the wake does not wake again" test "$rc" -eq 0
check "a second failure right after the wake is not handed off" test "$(runs)" -eq "$before"
check "the repeat is logged as such" wait_grep '"action":"stopped_again_after_resume"' "$events"
# A real message from the user re-arms it.
prompt s2 "try again please"
stop_failure s2 rate_limit "API Error: Rate limit reached"
check "a new user message re-arms the handoff" test "$rc" -eq 2

# --- automatic handoff when the hook is killed (headless) ----------------------
prompt s3 "Analyse the binary"
"$hook" <<<"$(payload '{hook_event_name: "StopFailure", session_id: "s3", error: "unknown", last_assistant_message: "API Error: 400 unable to respond to this request, which appears to violate our Usage Policy"}')" >/dev/null 2>&1 &
hook_pid=$!
sleep 0.3; kill "$hook_pid" 2>/dev/null; wait "$hook_pid" 2>/dev/null
check "handoff survives the hook being killed" wait_for "$FAILOVER_HOME/sessions/s3/pending/*.md"
check "policy text is classified as policy" wait_grep '"session_id":"s3".*"kind":"policy","action":"handoff_started"' "$events"
prompt s3 "continue"
check "next prompt receives the pending result" contains "$out" "Failover handoff result"
prompt s3 "thanks"
check "result is delivered only once" empty "$out"

# --- filters and switches ---------------------------------------------------------
prompt s4 "x"
stop_failure s4 authentication_failed "API Error: Invalid API key"
check "errors outside the on list do not wake" test "$rc" -eq 0
check "errors outside the on list are only logged" wait_grep '"session_id":"s4".*"action":"logged"' "$events"

config "{\"command\": \"$tmp/agent.sh\", \"auto\": false, \"notify\": false}"
prompt s5 "x"
before=$(runs)
stop_failure s5 overloaded "API Error: Overloaded"
wait_grep '"session_id":"s5".*"action":"notified"' "$events"
check "auto off never starts a handoff" test "$(runs)" -eq "$before" -a "$rc" -eq 0

config "{\"command\": \"$tmp/agent.sh\", \"auto\": true, \"wake\": false, \"notify\": false}"
prompt s6 "Update the docs"
stop_failure s6 overloaded "API Error: Overloaded"
check "wake off returns immediately without waking" test "$rc" -eq 0
check "wake off leaves the result for the next prompt" wait_for "$FAILOVER_HOME/sessions/s6/pending/*.md"

# --- loop guard, model switch, manual handoff ---------------------------------
config "$auto_config"
out=$(FAILOVER_ACTIVE=1 "$hook" <<<"$(payload '{hook_event_name: "Stop", session_id: "s7", stop_hook_active: false, last_assistant_message: "I cannot help with that."}')")
check "hooks stay silent inside a handoff" empty "$out"

fire '{hook_event_name: "PostModelSwitch", session_id: "s1", from_model: "model-a", to_model: "model-b", source: "auto"}'
check "automatic model switch adds guidance" contains "$out" "from model-a to model-b"
fire '{hook_event_name: "PostModelSwitch", session_id: "s1", from_model: "model-a", to_model: "model-b", source: "command"}'
check "manual model switch adds nothing" empty "$out"

out=$(echo "Write the changelog entry" | "$handoff" --session s1 --reason manual 2>&1); rc=$?
check "manual handoff succeeds" test "$rc" -eq 0
check "manual handoff prints the result" contains "$out" "stub agent finished the task"
check "manual handoff prints no shell job noise" test -z "$(grep -i terminated <<<"$out")"
check "manual brief includes the session history" grep -q "Add a retry to the uploader" "$tmp/brief-seen.md"
# Two sessions share the directory: the caller is the one whose last request
# carries the handed-off text, not the one that happened to type last.
prompt s8 "Make the uploader log every retry"; prompt s8 "/failover:handoff Finish the uploader"; sleep 1
prompt s9 "Unrelated session that mentions: Finish the uploader, used last"
out=$(cd "$repo" && echo "Finish the uploader (see src/upload.py)" | "$handoff" 2>&1); rc=$?
check "manual handoff without --session picks the session that invoked it" grep -q "log every retry" "$tmp/brief-seen.md"
check "manual handoff without --session never takes another session's history" test -z "$(grep "used last" "$tmp/brief-seen.md")"
out=$(cd "$repo" && echo "Finish" | "$handoff" 2>&1); rc=$?
check "a task shorter than the recorded request does not match" test -z "$(grep "Recent conversation" "$tmp/brief-seen.md")"
out=$(cd "$repo" && echo "Something no session asked for" | "$handoff" 2>&1); rc=$?
check "manual handoff with no matching session sends no history" test -z "$(grep "Recent conversation" "$tmp/brief-seen.md")"
check "manual handoff with no matching session says so" contains "$out" "no conversation history"
out=$(printf '   \n' | "$handoff" 2>&1); rc=$?
check "empty task exits 64" test "$rc" -eq 64

# --- self-test after a version change -----------------------------------------
# A fake `claude` that reports a new version and fires no hooks: the self-test
# must record a failure, and the next session start must warn about it once.
if command -v python3 >/dev/null 2>&1; then
  printf '#!/bin/bash\n[[ "$1" == "--version" ]] && { echo "9.9.9 (Claude Code)"; exit 0; }\ncurl -s -X POST -d "{}" "$ANTHROPIC_BASE_URL/v1/messages" >/dev/null\nexit 1\n' >"$tmp/fake-claude"
  chmod +x "$tmp/fake-claude"
  export CLAUDE_CODE_EXECPATH="$tmp/fake-claude"
  fire '{hook_event_name: "SessionStart", session_id: "s8", source: "startup"}'
  check "first session start after an update prints nothing" empty "$out"
  wait_for "$FAILOVER_HOME/selftest.json"; wait_for "$FAILOVER_HOME/selftest.json"   # the self-test takes a while on a cold machine
  wait_grep '"ok": false' "$FAILOVER_HOME/selftest.json"
  check "self-test runs and records a failure for the new version" wait_grep '"ok": false' "$FAILOVER_HOME/selftest.json"
  check "the failure names the version it was found on" grep -q '9.9.9' "$FAILOVER_HOME/selftest.json"
  echo "     (self-test detail: $(jq -r '.detail' "$FAILOVER_HOME/selftest.json" 2>/dev/null))"
  fire '{hook_event_name: "SessionStart", session_id: "s8", source: "startup"}'
  check "next session start warns the user" contains "$out" "self-test failed on 9.9.9"
  fire '{hook_event_name: "SessionStart", session_id: "s8", source: "startup"}'
  check "the warning is shown once a day, not every session" empty "$out"
  out=$(FAILOVER_SELFTEST=1 "$hook" <<<"$(payload '{hook_event_name: "SessionStart", session_id: "s8", source: "startup"}')")
  check "the self-test's own session does not start another self-test" empty "$out"
  unset CLAUDE_CODE_EXECPATH
fi

check "nothing in the state directory is readable by other users" test -z "$(find "$FAILOVER_HOME" -perm -004 -print -quit)$(find "$FAILOVER_HOME" -perm -040 -print -quit)"

config "{\"command\": \"sleep 30\", \"timeout\": 1, \"notify\": false}"
start=$SECONDS
echo "slow task" | "$handoff" >/dev/null 2>&1
check "a hung agent is stopped at the timeout" test $((SECONDS - start)) -lt 10

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
