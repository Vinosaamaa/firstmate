#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
CAT_BIN=$(command -v cat) || { echo "skip: cat not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- stable task route across a pane move and window rename -----------------

# This credential-free Codex stand-in is a real foreground process whose
# executable argv[0] is codex and whose stdin remains readable for routing.
ln -s "$CAT_BIN" "$SHIM_DIR/codex"
mkdir -p "$SHIM_DIR/state"
tmux new-window -d -t "$SESSION:" -n route-old -- "$SHIM_DIR/codex" \
  || fail "could not create the stable-route Codex stand-in"
ROUTE_TARGET="$SESSION:route-old"
for _ in $(seq 1 100); do
  fm_backend_tmux_discover_agent_identity "$ROUTE_TARGET" 2>/dev/null && break
  sleep 0.1
done
[ -n "${FM_BACKEND_TMUX_AGENT_PID:-}" ] \
  || fail "spawn-time discovery did not bind the Codex stand-in"
ROUTE_PANE=$FM_BACKEND_TMUX_PANE_ID
ROUTE_TTY=$FM_BACKEND_TMUX_PANE_TTY
ROUTE_PID=$FM_BACKEND_TMUX_AGENT_PID
ROUTE_START=$FM_BACKEND_TMUX_AGENT_START
ROUTE_COMM=$FM_BACKEND_TMUX_AGENT_COMM
ROUTE_ARGV0=$FM_BACKEND_TMUX_AGENT_ARGV0
ROUTE_META="$SHIM_DIR/state/route.meta"
cat > "$ROUTE_META" <<EOF
window=$ROUTE_PANE
endpoint_task_id=route
worktree=$SHIM_DIR
project=$SHIM_DIR
harness=codex
kind=ship
tmux_pane_id=$ROUTE_PANE
tmux_pane_tty=$ROUTE_TTY
tmux_agent_pid=$ROUTE_PID
tmux_agent_start=$ROUTE_START
tmux_agent_comm=$ROUTE_COMM
tmux_agent_argv0=$ROUTE_ARGV0
EOF
fm_backend_validate_task_endpoint "$ROUTE_META" route \
  || fail "stable tmux task metadata did not pass structural validation"
[ "$FM_BACKEND_VALIDATED_TARGET" = "$ROUTE_PANE" ] \
  || fail "stable tmux endpoint validation returned '$FM_BACKEND_VALIDATED_TARGET', expected '$ROUTE_PANE'"

tmux send-keys -t "$ROUTE_PANE" -l stable-route-token
tmux send-keys -t "$ROUTE_PANE" Enter
wait_for_capture_text "$ROUTE_PANE" stable-route-token \
  || fail "Codex stand-in did not receive its pre-move routing token"
tmux new-window -d -t "$SESSION:" -n route-destination -- "$SLEEP_BIN" 900 \
  || fail "could not create the pane-move destination"
tmux move-pane -d -s "$ROUTE_PANE" -t "$SESSION:route-destination" \
  || fail "could not move the live Codex pane"
tmux rename-window -t "$ROUTE_PANE" route-renamed \
  || fail "could not rename the moved pane's window"

[ "$(tmux display-message -p -t "$ROUTE_PANE" '#{pane_id}|#{pane_tty}')" = "$ROUTE_PANE|$ROUTE_TTY" ] \
  || fail "pane id or tty changed across move/rename"
fm_backend_tmux_process_sample "$ROUTE_PID" \
  || fail "saved Codex pid disappeared across move/rename"
[ "$FM_BACKEND_TMUX_AGENT_START" = "$ROUTE_START" ] \
  && [ "$FM_BACKEND_TMUX_AGENT_TTY" = "${ROUTE_TTY#/dev/}" ] \
  && [ "$FM_BACKEND_TMUX_AGENT_COMM" = "$ROUTE_COMM" ] \
  && [ "$FM_BACKEND_TMUX_AGENT_ARGV0" = "$ROUTE_ARGV0" ] \
  || fail "Codex pid/start-time/tty/executable identity changed across move/rename"
[ "$(fm_backend_target_of_meta "$ROUTE_META")" = "$ROUTE_PANE" ] \
  || fail "metadata routing did not resolve the moved pane directly"
peek=$(FM_HOME="$SHIM_DIR" FM_STATE_OVERRIDE="$SHIM_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-peek.sh" route 40 2>/dev/null) \
  || fail "task-addressed fm-peek failed after pane move and window rename"
case "$peek" in
  *stable-route-token*) ;;
  *) fail "task-addressed fm-peek did not capture the moved pane" ;;
esac
[ "$(fm_backend_tmux_process_sample "$ROUTE_PID" && printf '%s' "$FM_BACKEND_TMUX_AGENT_PID")" = "$ROUTE_PID" ] \
  || fail "routing created or rebound to a different worker process"
pass "real tmux: stable pane/task identity survives pane move and window rename without discovery or relaunch"

# Replacing the process in the same pane must fail before fm-send reaches the
# transport, even when the replacement still has a Codex-shaped executable.
sleep 1.1
tmux respawn-pane -k -t "$ROUTE_PANE" "$SHIM_DIR/codex" \
  || fail "could not replace the Codex stand-in in the same pane"
REPLACEMENT_PID=
for _ in $(seq 1 100); do
  if fm_backend_tmux_discover_agent_identity "$ROUTE_PANE" 2>/dev/null \
     && [ "$FM_BACKEND_TMUX_AGENT_PID" != "$ROUTE_PID" ]; then
    REPLACEMENT_PID=$FM_BACKEND_TMUX_AGENT_PID
    REPLACEMENT_START=$FM_BACKEND_TMUX_AGENT_START
    REPLACEMENT_COMM=$FM_BACKEND_TMUX_AGENT_COMM
    REPLACEMENT_ARGV0=$FM_BACKEND_TMUX_AGENT_ARGV0
    break
  fi
  sleep 0.1
done
[ -n "$REPLACEMENT_PID" ] || fail "replacement process did not start in the saved pane"
before_meta=$(cksum "$ROUTE_META")
if FM_HOME="$SHIM_DIR" FM_STATE_OVERRIDE="$SHIM_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" route --key Enter >/dev/null 2>&1; then
  fail "fm-send accepted a replacement process in the saved pane"
fi
[ "$(cksum "$ROUTE_META")" = "$before_meta" ] \
  || fail "replacement refusal mutated task metadata"
pass "real tmux: replacement process in the same pane is refused before fm-send"

# Simulate PID reuse independently by binding the replacement's current pid and
# executable identity with the prior process's start time.
REUSE_META="$SHIM_DIR/state/reuse.meta"
cat > "$REUSE_META" <<EOF
window=$ROUTE_PANE
endpoint_task_id=reuse
worktree=$SHIM_DIR
project=$SHIM_DIR
harness=codex
kind=ship
tmux_pane_id=$ROUTE_PANE
tmux_pane_tty=$ROUTE_TTY
tmux_agent_pid=$REPLACEMENT_PID
tmux_agent_start=$ROUTE_START
tmux_agent_comm=$REPLACEMENT_COMM
tmux_agent_argv0=$REPLACEMENT_ARGV0
EOF
[ "$REPLACEMENT_START" != "$ROUTE_START" ] \
  || fail "PID-reuse simulation is vacuous because the two process start times match"
before_meta=$(cksum "$REUSE_META")
if FM_HOME="$SHIM_DIR" FM_STATE_OVERRIDE="$SHIM_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" reuse --key Enter >/dev/null 2>&1; then
  fail "fm-send accepted a reused pid with a different process start time"
fi
[ "$(cksum "$REUSE_META")" = "$before_meta" ] \
  || fail "PID-reuse refusal mutated task metadata"
pass "real tmux: reused pid with a different start time is refused before fm-send"

cleanup_all
trap - EXIT
