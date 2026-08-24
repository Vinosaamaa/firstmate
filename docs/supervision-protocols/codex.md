Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Idle entry gate: begin a foreground watcher checkpoint only when this session owns the home lock, away mode is inactive, supervision is actually required, every currently visible captain request is answered or completed, every immediately actionable wake is handled, no useful requested work remains in the current turn, and the session is genuinely about to wait for fleet activity.
   Run `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`; 180 seconds remains the default maximum idle wait, and the command may return earlier on a wake.
4. Never start or restart a checkpoint during an active captain conversation, while a response is owed, while useful requested work remains in the current turn, or merely because the Stop-hook turn-end guard banner appeared.
   The banner warns that supervision would be lost if the turn ended; it does not make a checkpoint a prerequisite for answering the captain.
5. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle every immediately actionable wake and visible captain message, then apply the idle entry gate again before starting another checkpoint.
6. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, handle every immediately actionable wake and visible captain message, then apply the idle entry gate again before starting another checkpoint.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
8. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, handle every immediately actionable wake and visible captain message, then apply the idle entry gate before starting a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
