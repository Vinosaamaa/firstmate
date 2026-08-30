#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No external harness is launched. herdr's `pane report-agent` is the same
# registry the adapter reads, so the basic cases register a synthetic agent on
# a plain shell pane. The resume case launches a local fake Codex process that
# emits the installed Codex banner shape and records its exact resume argv.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
mkdir -p "$SCRATCH/tasktmp"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "tasktmp=$SCRATCH/tasktmp"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 \
    FM_CONTROL_LAUNCH_WAIT=10 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped "*" (hsmoke) "*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered "*" (hsmoke) harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

# --- exact Codex session across a real named-session server restart ---------

CODEX_SESSION_ID=01a02b1e-c95e-7a92-9e37-b0862d93e5e0
FAKE_CODEX_LOG="$SCRATCH/fake-codex.argv"
mkdir -p "$SCRATCH/fakebin"
cat > "$SCRATCH/fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  echo 'codex-cli 0.149.0-alpha.4.1'
  exit 0
fi
: "${HERDR_SESSION:?}"
: "${HERDR_PANE_ID:?}"
: "${FM_FAKE_CODEX_LOG:?}"
: "${FM_FAKE_CODEX_SESSION_ID:?}"
printf '%s\n' "$*" > "$FM_FAKE_CODEX_LOG"
herdr pane report-agent "$HERDR_PANE_ID" --source fm-resume-smoke \
  --agent codex --state idle --agent-session-id "$FM_FAKE_CODEX_SESSION_ID" \
  --session "$HERDR_SESSION" >/dev/null 2>&1
release_agent() {
  herdr pane release-agent "$HERDR_PANE_ID" --source fm-resume-smoke \
    --agent codex --session "$HERDR_SESSION" >/dev/null 2>&1 || true
}
trap release_agent EXIT
sleep 30
SH
chmod +x "$SCRATCH/fakebin/codex"

herdr pane release-agent "$PANE_ID" --source fm-control-smoke \
  --agent fm-control-smoke-agent --seq 1 --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not release the synthetic agent before the Codex resume case"
sed 's/^harness=claude$/harness=codex/' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
printf 'spawn_gen=herdr-initial\n' >> "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-session-lib.sh"
fm_codex_session_publish "$HOME_DIR/state" hsmoke \
  "$HOME_DIR/state/hsmoke.meta" "$CODEX_SESSION_ID" parked \
  || fail "could not publish the exact parked Herdr session fixture"
[ "$(grep '^state=' "$HOME_DIR/state/hsmoke.codex-session")" = state=parked ] \
  || fail "the Herdr exact-session fixture should be parked"
pass "real herdr: a parked Codex session is bound to exact session/workspace/tab/pane identity"

fm_herdr_lab_stop "$SESSION" >/dev/null \
  || fail "could not stop the isolated Herdr lab for restart coverage"
fm_herdr_lab_provision "$SESSION" \
  || fail "could not restart the isolated Herdr lab"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the exact recorded Herdr pane id did not survive the server restart"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" \
  "export PATH='$SCRATCH/fakebin':\$PATH; export FM_FAKE_CODEX_LOG='$FAKE_CODEX_LOG'; export FM_FAKE_CODEX_SESSION_ID='$CODEX_SESSION_ID'" \
  || fail "could not restore the fake harness environment after Herdr restart"

OUT=$(run_control hsmoke relaunch --resume --note "continue after isolated Herdr restart") \
  || fail "exact Codex resume in the recorded Herdr endpoint should succeed: $OUT"
case "$OUT" in
  *"resumed hsmoke session=$CODEX_SESSION_ID"*"backend=herdr endpoint=$SESSION:$PANE_ID"*) : ;;
  *) fail "Herdr exact resume should report its session and exact endpoint, got: $OUT" ;;
esac
grep -F 'resume ' "$FAKE_CODEX_LOG" >/dev/null \
  || fail "the fake Codex argv should record the resume subcommand"
grep -F "$CODEX_SESSION_ID" "$FAKE_CODEX_LOG" >/dev/null \
  || fail "the fake Codex argv should contain the exact persisted session id"
! grep -F -- '--last' "$FAKE_CODEX_LOG" >/dev/null \
  || fail "Herdr exact resume must never use --last"
[ "$(grep '^state=' "$HOME_DIR/state/hsmoke.codex-session")" = state=live ] \
  || fail "confirmed Herdr resume should publish a live exact-session binding"
[ "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/hsmoke.codex-session")" = "herdr_workspace_id=$WORKSPACE_ID" ] \
  || fail "the live binding must preserve the exact Herdr workspace id"
[ "$(grep '^herdr_tab_id=' "$HOME_DIR/state/hsmoke.codex-session")" = "herdr_tab_id=$TAB_ID" ] \
  || fail "the live binding must preserve the exact Herdr tab id"
[ "$(grep '^herdr_pane_id=' "$HOME_DIR/state/hsmoke.codex-session")" = "herdr_pane_id=$PANE_ID" ] \
  || fail "the live binding must preserve the exact Herdr pane id"
pass "real herdr: exact Codex resume reuses recorded session/workspace/tab/pane ids after restart"

herdr pane release-agent "$PANE_ID" --source fm-resume-smoke --agent codex \
  --session "$SESSION" >/dev/null 2>&1 || true
fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
fm_codex_session_retire "$HOME_DIR/state" hsmoke \
  || fail "isolated Herdr fixture should retire its exact-session binding"
[ ! -e "$HOME_DIR/state/hsmoke.codex-session" ] \
  || fail "binding retirement should remove the Herdr task sidecar"
[ ! -e "$HOME_DIR/state/codex-sessions/$CODEX_SESSION_ID.owner" ] \
  || fail "binding retirement should remove the global exact-session owner"
pass "real herdr: exact-session cleanup removes both task and global owner records"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
