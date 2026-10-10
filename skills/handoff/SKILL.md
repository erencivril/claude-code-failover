---
name: handoff
description: Hand one piece of work to the fallback agent configured for the failover plugin and report what it did. Runs only when the user invokes it.
disable-model-invocation: true
argument-hint: <task to hand off>
---

# Hand off to the fallback agent

The user wants this piece of work done by their configured fallback agent instead of in this session:

$ARGUMENTS

## Steps

1. If the text above is empty, ask the user what to hand off and stop.
2. Run the handoff from the project's working directory, passing the user's text verbatim as the task. Do not rewrite, expand, or add detail to it; the only thing you may append is a list of file paths the user already named in this conversation. The script finds this session's recorded conversation by matching your verbatim text against the request it recorded, which is why the text must not be changed; do not pass `--session`.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" <<'FAILOVER_TASK'
   <the user's text, verbatim>
   FAILOVER_TASK
   ```

   Agent runs can take several minutes, so start the command in the background and wait for it to finish.
3. Report what the script printed: the exit code, the files it changed, and the end of the agent's output. If the exit code is non-zero, say so and point to the log directory; do not retry on your own. Exit code 78 means no handoff command is configured: tell the user to run `/failover:setup`.
4. Do not open or review the files the agent changed unless the user asks. If this session stopped on that content once, reading it back in can stop it again.
5. Carry on with whatever part of the user's task is still open in this session.
