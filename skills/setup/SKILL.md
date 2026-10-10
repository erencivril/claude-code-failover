---
name: setup
description: Configure the failover plugin - choose the fallback agent command and turn on Claude Code's built-in recovery settings. Runs only when the user invokes it.
disable-model-invocation: true
---

# Set up failover

Walk the user through the steps below. Ask before writing each file, and merge into existing files instead of replacing them.

## 1. Check the requirement

Run `command -v jq`. If jq is missing, tell the user how to install it (`brew install jq`, `apt install jq`) and stop: every script in this plugin needs it.

## 2. Choose the fallback agent

Check which agent CLIs are installed (`command -v codex gemini aider opencode claude`) and ask the user which one should take over a stopped task. The command must run without prompting, read the task brief from stdin (or from the file named by `$FAILOVER_BRIEF_FILE`), and be allowed to edit files in the working directory. Starting points, which the user should confirm against `--help` for their installed version:

| Agent | Command |
| --- | --- |
| Codex CLI | `codex exec --sandbox workspace-write -` |
| Claude Code on another model | `claude -p --model sonnet --permission-mode acceptEdits` |
| Gemini CLI | `gemini --yolo -p "$(cat)"` |
| Aider | `aider --yes-always --message-file "$FAILOVER_BRIEF_FILE"` |
| opencode | `opencode run "$(cat)"` |

Any other command works too, including a wrapper script of the user's own.

## 3. Write the config

Ask whether the handoff should start automatically when a turn dies (`"auto": true`), or only when the user runs `/failover:handoff`. Make clear that automatic mode sends the recent conversation to the chosen agent without asking each time, on that agent's account and cost.

Write `~/.claude/failover.json` (use `$CLAUDE_CONFIG_DIR` instead of `~/.claude` if it is set):

```json
{
  "command": "<the chosen command>",
  "auto": true,
  "on": ["policy", "rate_limit", "overloaded", "server_error"]
}
```

## 4. Offer the built-in recovery settings

These are Claude Code settings, not part of this plugin, and they recover without leaving the session. Offer to merge them into the user's `~/.claude/settings.json`, explaining each one, and only add the ones the user agrees to:

- `"switchModelsOnFlag": true` - when a safety classifier flags a request, re-run it on the fallback Claude model instead of pausing to ask.
- `"fallbackModel": ["sonnet"]` - when the primary model is overloaded or unavailable, serve the turn from another model.
- `"autoContinueAtUsageLimit": true` - when a usage limit stops the session, wait for the reset and continue.

## 5. Confirm

Run a dry check and show the user the output:

```bash
echo "Reply with the single word OK. Do not create or modify any files." | "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" --reason setup-check
```

Tell the user that events are logged to `~/.claude/failover/events.jsonl`.
