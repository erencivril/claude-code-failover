#!/bin/bash
# Entry point for every hook event the failover plugin registers:
#   UserPromptSubmit  remember the request; deliver results of a finished handoff
#   Stop              remember the reply; nudge past a refusal that halted the task
#   StopFailure       log the error, run the handoff when configured, then wake the session
#   PostModelSwitch   after an automatic model fallback, tell Claude to keep going
set -u

# Debugging aid: FAILOVER_TRACE=/path/to/file appends a shell trace of every hook run.
if [[ -n "${FAILOVER_TRACE:-}" ]]; then exec 2>>"$FAILOVER_TRACE"; set -x; fi

command -v jq >/dev/null 2>&1 || exit 0
# Set while a handoff command runs, so an agent launched by this plugin
# (including a nested `claude -p`) never triggers another handoff.
[[ -n "${FAILOVER_ACTIVE:-}" ]] && exit 0

# No subprocesses until the StopFailure branch below has detached its worker:
# headless Claude Code exits within milliseconds of an API error and kills its hooks.
here="${BASH_SOURCE[0]%/*}"
[[ "$here" == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

if [[ -n "${FAILOVER_PAYLOAD:-}" ]]; then
  # Detached worker for StopFailure: the hook input arrives in the environment.
  input=$FAILOVER_PAYLOAD
  unset FAILOVER_PAYLOAD
else
  IFS= read -r -d '' input || true
  if [[ "$input" == *'"StopFailure"'* ]]; then
    # Two processes handle this event. The detached worker does the real work, so it
    # survives a headless session exiting. This process, registered with asyncRewake,
    # waits for the worker: when a handoff finishes it prints the result to stderr
    # and exits 2, which makes an interactive session start a new turn by itself.
    # The wake file lives in the plugin's own owner-only directory, never in a shared
    # temp directory where another local user could plant or redirect it.
    export FAILOVER_WAKE_FILE="$FAILOVER_HOME/tmp/wake.$$.$RANDOM$RANDOM"
    trap '' TERM HUP   # cover the instant between the fork and the worker's setsid
    FAILOVER_PAYLOAD="$input" detach "${BASH_SOURCE[0]}"
    trap - TERM HUP

    [[ "$(cfg wake true)" == "true" ]] || exit 0
    limit=$(cfg timeout 1800)
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=1800
    deadline=$((SECONDS + limit + 120))
    while [[ ! -s "$FAILOVER_WAKE_FILE" ]]; do
      (( SECONDS < deadline )) || exit 0
      sleep 0.5
    done
    result=$(cat "$FAILOVER_WAKE_FILE"); rm -f "$FAILOVER_WAKE_FILE"
    # "none" means nothing was handed off. Anything else must be a pending result
    # written by handoff.sh inside the state directory; its text goes to Claude.
    case "$result" in
      "$FAILOVER_HOME"/sessions/*/pending/*.md) ;;
      *) exit 0 ;;
    esac
    [[ "$result" != *..* && -f "$result" && ! -L "$result" ]] || exit 0
    sdir=$(dirname "$(dirname "$result")")
    cat "$result" >&2
    mkdir -p "$sdir/delivered" && mv "$result" "$sdir/delivered/"
    # If the woken turn dies too, stop there instead of handing off in a loop.
    date +%s >"$sdir/woke"
    exit 2
  fi
fi

event=$(jq -r '.hook_event_name // empty' <<<"$input")
sid=$(safe_id "$(jq -r '.session_id // empty' <<<"$input")")
cwd=$(jq -r '.cwd // empty' <<<"$input")
sdir="$FAILOVER_HOME/sessions/$sid"

remember() { # remember <role> <text> — rolling per-session history used to brief the next agent
  [[ -n "$2" ]] || return 0
  mkdir -p "$sdir"
  jq -cn --arg role "$1" --arg text "${2:0:4000}" '{role: $role, text: $text}' >>"$sdir/history.jsonl"
  tail -n 40 "$sdir/history.jsonl" >"$sdir/history.tmp" && mv "$sdir/history.tmp" "$sdir/history.jsonl"
}

case "$event" in
  UserPromptSubmit)
    prompt=$(jq -r '.prompt // empty' <<<"$input")
    # Turns Claude Code starts by itself (a wake-up, a background task finishing)
    # arrive here too; they are not requests from the user.
    if [[ "$prompt" != "<task-notification>"* ]]; then
      remember user "$prompt"
      rm -f "$sdir/woke"
    fi
    context=""
    if handoff_running "$sdir"; then
      context="A handoff to the fallback agent started by the failover plugin is still running in this working directory. Avoid editing the same files until it finishes; its result will be delivered when it does."$'\n\n'
    fi
    for f in "$sdir"/pending/*.md; do
      [[ -f "$f" ]] || continue
      context+="$(cat "$f")"$'\n\n'
      mkdir -p "$sdir/delivered" && mv "$f" "$sdir/delivered/"
    done
    if [[ -n "$context" ]]; then
      jq -n --arg c "$context" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    fi
    ;;

  Stop)
    rm -f "$sdir/woke"
    msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
    remember assistant "$msg"
    [[ "$(cfg nudge true)" == "true" ]] || exit 0
    [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]] && exit 0
    # Only short messages: a long reply that mentions a skipped part has already carried on.
    (( ${#msg} > 0 && ${#msg} < 1200 )) || exit 0
    refusal="I( am|'m|’m)? ?(can't|can’t|cannot|won't|won’t|not able to|unable to) (help|assist|provide|comply)"
    grep -Eiq "$refusal" <<<"$msg" || exit 0
    log_event "$(jq -n --arg s "$sid" --arg m "${msg:0:300}" '{event: "refusal_nudge", session_id: $s, message: $m}')"
    jq -n '{decision: "block", reason: "Your last message looks like it declined the request and stopped. If it was not a refusal, ignore this and finish normally. If the declined part is only one piece of the task, do not stop there: leave that piece untouched, carry on with the rest of the work, and finish with a short list of what you left out so the user can decide whether to hand it to another agent with /failover:handoff. If the whole request is something you will not do, say so in one sentence and stop."}'
    ;;

  StopFailure)
    # Runs in the detached worker started above, so everything here is a side effect.
    ensure_home
    prune
    error=$(jq -r '.error // "unknown"' <<<"$input")
    text=$(jq -r '[.last_assistant_message, .error_details] | map(. // "") | join(" ")' <<<"$input")
    kind="$error"
    grep -Eiq "$POLICY_RE" <<<"$text" && kind="policy"

    action="logged"
    command_line=$(cfg command "")
    if in_list "$kind" "$(cfg on "$DEFAULT_ON")"; then
      if [[ -f "$sdir/woke" ]]; then
        action="stopped_again_after_resume"
        notify "Claude Code stopped again ($kind)" "The turn after the handoff failed too. Rewind (Esc Esc) or send a message to continue."
      elif [[ "$(cfg auto false)" == "true" && -n "$command_line" ]]; then
        if handoff_running "$sdir"; then
          action="handoff_already_running"
        else
          action="handoff_started"
          # handoff.sh reports back through FAILOVER_WAKE_FILE when it ends.
          detach "$here/handoff.sh" --auto --session "$sid" --cwd "$cwd" --reason "$kind"
          notify "Claude Code stopped ($kind)" "Handing the task to your fallback agent. The session resumes by itself when it's done."
        fi
      else
        action="notified"
        notify "Claude Code stopped ($kind)" "Run /failover:handoff <task> to pass the work to another agent."
      fi
    fi
    if [[ "$action" != "handoff_started" && -n "${FAILOVER_WAKE_FILE:-}" ]]; then
      echo none >"$FAILOVER_WAKE_FILE"
    fi
    log_event "$(jq -n --arg s "$sid" --arg c "$cwd" --arg e "$error" --arg k "$kind" --arg a "$action" --arg m "${text:0:300}" \
      '{event: "stop_failure", session_id: $s, cwd: $c, error: $e, kind: $k, action: $a, message: $m}')"
    ;;

  PostModelSwitch)
    [[ "$(jq -r '.source // empty' <<<"$input")" == "auto" ]] || exit 0
    from=$(jq -r '.from_model // "?"' <<<"$input")
    to=$(jq -r '.to_model // "?"' <<<"$input")
    log_event "$(jq -n --arg s "$sid" --arg f "$from" --arg t "$to" '{event: "auto_model_switch", session_id: $s, from_model: $f, to_model: $t}')"
    notify "Claude Code switched models" "$from → $to. Use /model to switch back."
    # Plain stdout on exit 0 is delivered to Claude with the next request.
    cat <<EOF
Claude Code automatically switched this session's model from $from to $to. Keep working on the user's task. If one specific part of it can't be done, leave that part out, finish everything else, and end with a short list of what was left out so the user can decide whether to hand it to another agent with /failover:handoff. Tell the user once that the session is now on $to and that /model switches back.
EOF
    ;;
esac
exit 0
