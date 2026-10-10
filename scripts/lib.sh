#!/bin/bash
# Shared helpers for the failover plugin. Sourced by hook.sh and handoff.sh.
# Written for bash 3.2 (the macOS default), so no associative arrays or mapfile.

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FAILOVER_HOME="${FAILOVER_HOME:-$CLAUDE_HOME/failover}"
# Only ever read from the user's own config directory: this file names a command
# that runs unattended, so a cloned repository must not be able to supply it.
FAILOVER_CONFIG="${FAILOVER_CONFIG:-$CLAUDE_HOME/failover.json}"

DEFAULT_ON="policy,rate_limit,overloaded,server_error"
POLICY_RE='usage policy|acceptable use|content policy|safety (filter|classifier|system)|flagged|violat'

# cfg <key> <default> — top-level value from the config file; arrays come back comma-joined.
cfg() {
  local value=""
  if [[ -f "$FAILOVER_CONFIG" ]]; then
    value=$(jq -r --arg k "$1" '
      if type == "object" and has($k) and .[$k] != null then .[$k] else empty end
      | if type == "array" then join(",") else tostring end' "$FAILOVER_CONFIG" 2>/dev/null)
  fi
  if [[ -n "$value" ]]; then printf '%s' "$value"; else printf '%s' "$2"; fi
}

# in_list <item> <comma-separated list>
in_list() {
  case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

safe_id() {
  local id
  id=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_-')
  printf '%s' "${id:-unknown}"
}

log_event() { # log_event <json object>
  mkdir -p "$FAILOVER_HOME"
  jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts} + .' <<<"$1" >>"$FAILOVER_HOME/events.jsonl" 2>/dev/null
}

notify() { # notify <title> <body>
  [[ "$(cfg notify true)" == "true" ]] || return 0
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$1" "$2" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1
  fi
  return 0
}

# detach <command...> — run a command in its own session so it outlives the caller.
# Headless Claude Code exits right after an API error and takes its hooks with it.
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >/dev/null 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
}

# handoff_running <session dir> — true while an automatic handoff for the session is alive.
handoff_running() {
  local pid
  [[ -f "$1/handoff.pid" ]] || return 1
  pid=$(cat "$1/handoff.pid" 2>/dev/null)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Content hash of every dirty file in the current git repository, so a file that
# was already modified before the handoff still shows up if it changes again.
snapshot() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git ls-files -m -o -d --exclude-standard | sort -u | while IFS= read -r f; do
    if [[ -f "$f" ]]; then
      printf '%s %s\n' "$(git hash-object -- "$f")" "$f"
    else
      printf 'deleted %s\n' "$f"
    fi
  done
}
