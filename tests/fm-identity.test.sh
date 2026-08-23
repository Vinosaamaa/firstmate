#!/usr/bin/env bash
# Focused behavior contract for persistent home/task names. Exercises the shared
# public identity library plus the operator-facing fm-name/fm-send surfaces over
# private tmux- and Herdr-shaped task records. No live backend is contacted.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-identity)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
WT="$TMP_ROOT/worktree"
FAKEBIN="$TMP_ROOT/fakebin"
SEND_LOG="$TMP_ROOT/send.log"
mkdir -p "$STATE" "$DATA" "$WT" "$FAKEBIN"
trap 'rm -rf "$TMP_ROOT"' EXIT

export FM_HOME="$HOME_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-identity-lib.sh
. "$ROOT/bin/fm-identity-lib.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
field() { fm_identity_record_value "$1" "$2"; }

write_tmux_meta() { # <id> <target> [thread]
  local id=$1 target=$2 thread=${3:-}
  {
    printf 'window=%s\n' "$target"
    printf 'worktree=%s\n' "$WT"
    printf 'project=%s\n' "$TMP_ROOT/project"
    printf 'harness=codex\nkind=ship\n'
    printf 'spawn_gen=gen-%s\n' "$id"
    [ -z "$thread" ] || printf 'codex_session_id=%s\n' "$thread"
  } > "$STATE/$id.meta"
}

write_herdr_meta() { # <id> <session:pane> [thread]
  local id=$1 target=$2 thread=${3:-}
  {
    printf 'window=%s\n' "$target"
    printf 'terminal=%s\n' "$target"
    printf 'worktree=%s\n' "$WT"
    printf 'project=%s\n' "$TMP_ROOT/project"
    printf 'harness=codex\nkind=ship\nbackend=herdr\n'
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'spawn_gen=gen-%s\n' "$id"
    printf 'herdr_session=%s\n' "${target%%:*}"
    printf 'herdr_workspace_id=workspace-%s\n' "$id"
    printf 'herdr_tab_id=tab-%s\n' "$id"
    printf 'herdr_pane_id=%s\n' "${target#*:}"
    [ -z "$thread" ] || printf 'codex_session_id=%s\n' "$thread"
  } > "$STATE/$id.meta"
}

HOME_NAME=$(fm_identity_ensure_home)
[ -n "$HOME_NAME" ] || fail "home name was not assigned"
[ "$(fm_identity_ensure_home)" = "$HOME_NAME" ] || fail "home name changed across reads"
[ "$(field "$DATA/firstmate.identity" home)" = "$(cd "$HOME_DIR" && pwd -P)" ] \
  || fail "home identity did not bind the canonical Firstmate home"
pass "one deterministic human name persists for the Firstmate home"

CALL_A=$(fm_identity_reserve_fresh_task task-a)
write_tmux_meta task-a fm-home:fm-task-a thread-a
[ "$(fm_identity_ensure_task_from_meta "$STATE/task-a.meta" task-a)" = "$CALL_A" ] \
  || fail "tmux activation changed the reserved callsign"
REC_A=$(fm_identity_task_record task-a)
[ "$(field "$REC_A" task_id)" = task-a ] || fail "task id binding missing"
[ "$(field "$REC_A" home)" = "$(cd "$HOME_DIR" && pwd -P)" ] || fail "home binding missing"
[ "$(field "$REC_A" worktree)" = "$(cd "$WT" && pwd -P)" ] || fail "canonical worktree binding missing"
[ "$(field "$REC_A" backend)" = tmux ] || fail "tmux backend binding missing"
[ "$(field "$REC_A" endpoint)" = fm-home:fm-task-a ] || fail "tmux endpoint binding missing"
[ "$(field "$REC_A" endpoint_session_id)" = fm-home ] || fail "tmux session binding missing"
[ "$(field "$REC_A" harness_session_id)" = thread-a ] || fail "exact harness thread binding missing"
[ "$(field "$REC_A" spawn_gen)" = gen-task-a ] || fail "spawn incarnation binding missing"
pass "fresh tmux task publishes its full one-to-one identity binding"

CALL_B=$(fm_identity_reserve_fresh_task task-b)
[ "$CALL_A" != "$CALL_B" ] || fail "fresh tasks received the same callsign"
write_herdr_meta task-b fm-lab:pane-b
[ "$(fm_identity_ensure_task_from_meta "$STATE/task-b.meta" task-b)" = "$CALL_B" ] \
  || fail "Herdr activation changed the reserved callsign"
REC_B=$(fm_identity_task_record task-b)
[ "$(field "$REC_B" backend)" = herdr ] || fail "Herdr backend binding missing"
[ "$(field "$REC_B" endpoint)" = fm-lab:pane-b ] || fail "Herdr endpoint binding missing"
[ "$(field "$REC_B" endpoint_session_id)" = fm-lab ] || fail "Herdr session binding missing"
pass "automatic callsigns are unique and backend-neutral"

RENAMED_HOME=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename-home Harbor)
[ "$RENAMED_HOME" = "Harbor (Firstmate home)" ] || fail "home rename was not persisted names-first"
[ "$(field "$DATA/firstmate.identity" name)" = Harbor ] || fail "home rename did not update the durable record"
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$CALL_B" Harbor >/dev/null 2>&1; then
  fail "task rename collided with the Firstmate home name"
fi
pass "explicit Firstmate-home rename shares collision-safe history with task callsigns"

EXPLICIT_A=Hopper
[ "$CALL_A" != Hopper ] || EXPLICIT_A=HopperOne
NAME_OUT=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$CALL_A" "$EXPLICIT_A")
[ "$NAME_OUT" = "$EXPLICIT_A (task-a)" ] || fail "rename was not names-first: $NAME_OUT"
[ "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" resolve "$(fm_identity_fold "$EXPLICIT_A")")" = "$EXPLICIT_A (task-a)" ] \
  || fail "case-insensitive callsign resolution failed"
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$CALL_B" "$EXPLICIT_A" >/dev/null 2>&1; then
  fail "rename silently collided with an active callsign"
fi
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$CALL_B" captain >/dev/null 2>&1; then
  fail "rename accepted a reserved name"
fi
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$CALL_B" task-a >/dev/null 2>&1; then
  fail "rename collided with an existing task id"
fi
if fm_identity_reserve_fresh_task "$(printf '%s' "$EXPLICIT_A" | tr '[:upper:]' '[:lower:]')" >/dev/null 2>&1; then
  fail "fresh task id collided with an existing callsign"
fi
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" resolve "$CALL_A" >/dev/null 2>&1; then
  fail "retired callsign remained routable after rename"
fi
pass "explicit rename validates active, task-id, reserved, and historical collisions"

CASE_ONLY=$(printf '%s' "$EXPLICIT_A" | tr '[:upper:]' '[:lower:]')
NAME_OUT=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename "$EXPLICIT_A" "$CASE_ONLY")
[ "$NAME_OUT" = "$CASE_ONLY (task-a)" ] || fail "case-only rename did not report the persisted spelling"
[ "$(field "$REC_A" callsign)" = "$CASE_ONLY" ] || fail "case-only rename was not persisted"
EXPLICIT_A=$CASE_ONLY
pass "case-only rename persists the requested spelling"

# Process/pane loss does not mutate identity. A replacement endpoint and exact
# thread resume update the binding in place without changing the callsign.
[ "$(fm_identity_resolve_selector "$STATE" "$EXPLICIT_A")" = task-a ] || fail "callsign vanished after simulated process exit"
write_tmux_meta task-a fm-home-restarted:fm-task-a thread-a
[ "$(fm_identity_ensure_task_from_meta "$STATE/task-a.meta" task-a rebind)" = "$EXPLICIT_A" ] \
  || fail "tmux restart changed the callsign"
[ "$(field "$REC_A" endpoint)" = fm-home-restarted:fm-task-a ] || fail "relaunch endpoint was not updated"
[ "$(field "$REC_A" harness_session_id)" = thread-a ] || fail "exact-thread resume id was not preserved"
write_herdr_meta task-b fm-lab:pane-b-restarted thread-b
[ "$(fm_identity_ensure_task_from_meta "$STATE/task-b.meta" task-b rebind)" = "$CALL_B" ] \
  || fail "Herdr restart changed the callsign"
[ "$(field "$REC_B" endpoint)" = fm-lab:pane-b-restarted ] || fail "Herdr replacement endpoint was not updated"
[ "$(field "$REC_B" harness_session_id)" = thread-b ] || fail "Herdr exact-thread id was not recorded"
pass "tmux/Herdr restart, relaunch, and exact-thread resume preserve callsigns"

CALL_C=$(fm_identity_reserve_fresh_task task-c)
[ "$CALL_C" != "$EXPLICIT_A" ] && [ "$CALL_C" != "$CALL_B" ] || fail "fresh task reused a current callsign"
pass "fresh tasks remain distinct from resumed tasks"

# Direct names-first follow-up routing reaches the exact bound tmux endpoint.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in *cursor_y*) printf '1\n' ;; *) printf '%%identity-pane\n' ;; esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_IDENTITY_SEND_LOG" ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
: > "$SEND_LOG"
FM_IDENTITY_SEND_LOG="$SEND_LOG" PATH="$FAKEBIN:$PATH" \
  FM_SEND_SETTLE=0 FM_HOME="$HOME_DIR" "$ROOT/bin/fm-send.sh" "$EXPLICIT_A" "status please" >/dev/null \
  || fail "names-first direct follow-up routing failed"
grep -q 'fm-home-restarted:fm-task-a' "$SEND_LOG" || fail "callsign follow-up did not route to the exact bound endpoint"
pass "names-first follow-up routes to exactly one task"

# Conflicting session identities fail closed without replacing the good record.
cp "$REC_A" "$TMP_ROOT/record-before-conflict"
cat >> "$STATE/task-a.meta" <<'EOF'
thread_id=thread-conflict
EOF
if fm_identity_ensure_task_from_meta "$STATE/task-a.meta" task-a rebind >/dev/null 2>&1; then
  fail "conflicting exact-thread identifiers were accepted"
fi
cmp -s "$REC_A" "$TMP_ROOT/record-before-conflict" || fail "failed relaunch rewrote the prior identity"
write_tmux_meta task-a fm-home-restarted:fm-task-a thread-a
pass "conflicting or unsafe relaunch identity refuses without rebinding"

write_tmux_meta unsafe-legacy fm-home:fm-other
if fm_identity_ensure_task_from_meta "$STATE/unsafe-legacy.meta" unsafe-legacy legacy >/dev/null 2>&1; then
  fail "legacy identity activation accepted another task's tmux endpoint"
fi
[ ! -e "$(fm_identity_task_record unsafe-legacy)" ] || fail "unsafe legacy activation published an identity record"
rm -f "$STATE/unsafe-legacy.meta"
pass "legacy activation validates endpoint ownership before publishing a callsign"

fm_identity_archive_task "$STATE/task-b.meta" task-b >/dev/null
rm -f "$STATE/task-b.meta"
if fm_identity_resolve_selector "$STATE" "$CALL_B" >/dev/null 2>&1; then
  fail "archived-only callsign resolved as live"
fi
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" history | grep -q "^$CALL_B (task-b) archived$" \
  || fail "cleanup history omitted archived names-first identity"
if fm_identity_reserve_fresh_task task-b >/dev/null 2>&1; then
  fail "archived task id was silently rebound"
fi
pass "cleanup retains history and active/historical callsigns never silently rebind"

# Migration gives complete legacy tasks active fallback bindings, incomplete
# records provisioning fallbacks, and status-only history archived tombstones.
write_tmux_meta legacy-live fm-home:fm-legacy-live
printf 'kind=ship\n' > "$STATE/legacy-incomplete.meta"
printf 'done: old task\n' > "$STATE/legacy-gone.status"
fm_identity_migrate_home
LEGACY_LIVE=$(fm_identity_display_callsign legacy-live)
case "$LEGACY_LIVE" in *-L[0-9]*) : ;; *) fail "legacy task did not receive deterministic fallback: $LEGACY_LIVE" ;; esac
[ "$(field "$(fm_identity_task_record legacy-live)" status)" = active ] || fail "complete legacy task was not activated"
[ "$(field "$(fm_identity_task_record legacy-incomplete)" status)" = provisioning ] || fail "incomplete legacy task was guessed active"
[ "$(field "$(fm_identity_task_record legacy-gone)" status)" = archived ] || fail "legacy history did not migrate to a tombstone"
LEGACY_RENAMED=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-name.sh" rename legacy-live LegacyOne)
[ "$LEGACY_RENAMED" = "LegacyOne (legacy-live)" ] || fail "migrated legacy task could not be explicitly renamed"
pass "legacy unnamed tasks migrate deterministically and support explicit rename without endpoint guesses"

# Deliberately corrupt two private fixtures to prove ambiguous and task-id/name
# conflicts refuse; restore them immediately so later history stays valid.
cp "$REC_B" "$TMP_ROOT/record-b-safe"
sed "s/^callsign=.*/callsign=$EXPLICIT_A/" "$REC_B" > "$REC_B.tmp" && mv "$REC_B.tmp" "$REC_B"
if fm_identity_resolve_selector "$STATE" "$EXPLICIT_A" >/dev/null 2>&1; then
  fail "ambiguous duplicate callsign was guessed"
fi
cp "$TMP_ROOT/record-b-safe" "$REC_B"
cp "$(fm_identity_task_record legacy-live)" "$TMP_ROOT/legacy-safe"
sed 's/^callsign=.*/callsign=task-a/' "$(fm_identity_task_record legacy-live)" > "$TMP_ROOT/legacy-conflict"
cp "$TMP_ROOT/legacy-conflict" "$(fm_identity_task_record legacy-live)"
if fm_identity_resolve_selector "$STATE" task-a >/dev/null 2>&1; then
  fail "task-id/current-name conflict was guessed"
fi
cp "$TMP_ROOT/legacy-safe" "$(fm_identity_task_record legacy-live)"
pass "missing, ambiguous, archived-only, conflicting, and unsafe selectors fail closed"

printf 'ok - persistent human identity behavior\n'
