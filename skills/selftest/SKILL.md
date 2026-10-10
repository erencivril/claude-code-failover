---
name: selftest
description: Check that the failover plugin still works with the installed Claude Code version. Runs only when the user invokes it.
disable-model-invocation: true
---

# Failover self-test

Run the self-test and report its result to the user:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/selftest.sh" --force
```

It starts one headless Claude Code session against a local mock API with a stub fallback agent, so it costs no tokens and sends nothing off the machine. It takes up to a minute.

- If it passed, say so in one line.
- If it failed, show which steps failed and the log path it printed, and suggest updating the plugin (`/plugin marketplace update claude-code-failover`) or reporting the failure with the log at https://github.com/erencivril/claude-code-failover/issues.
- If it was skipped, say why.

The same check runs by itself in the background the first time a session starts after Claude Code or the plugin changes version. It covers plugin loading, prompt capture, the StopFailure hook and the detached handoff. It cannot cover the automatic wake-up of an interactive session, which only happens with a terminal attached.
