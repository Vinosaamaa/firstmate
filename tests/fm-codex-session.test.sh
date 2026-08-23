#!/usr/bin/env bash
# Backend-neutral exact Codex session parser, identity binding, lifecycle, and
# duplicate-resume fencing. These tests execute the persisted-state interface
# directly; they never inspect implementation source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-session-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-session) || exit 1
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

SID1=01a02b1e-c95e-7a92-9e37-b0862d93e5e0
SID2=01a02b1f-aaaa-7bbb-8ccc-0123456789ab

write_meta() {  # <path> <task> <worktree> <spawn-gen> [harness] [backend]
  local path=$1 task=$2 wt=$3 gen=$4 harness=${5:-codex} backend=${6:-tmux}
  {
    if [ "$backend" = herdr ]; then
      printf 'window=fm-lab-resume:pane:%s\n' "$task"
    else
      printf 'window=fmses:fm-%s\n' "$task"
    fi
    printf 'endpoint_task_id=%s\n' "$task"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s/project\n' "$TMP_ROOT"
    printf 'harness=%s\n' "$harness"
    printf 'kind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'spawn_gen=%s\n' "$gen"
    if [ "$backend" = herdr ]; then
      printf 'backend=herdr\n'
      printf 'herdr_session=fm-lab-resume\n'
      printf 'herdr_workspace_id=workspace:%s\n' "$task"
      printf 'herdr_tab_id=tab:%s\n' "$task"
      printf 'herdr_pane_id=pane:%s\n' "$task"
    fi
  } > "$path"
}

test_parser_accepts_one_new_exact_banner() {
  local before="$TMP_ROOT/before" after="$TMP_ROOT/after" got
  printf 'old output\n%s%s\n' "$FM_CODEX_SESSION_PREFIX" "$SID2" > "$before"
  printf 'old output\n%s%s\n%s%s\n' \
    "$FM_CODEX_SESSION_PREFIX" "$SID2" \
    "$FM_CODEX_SESSION_PREFIX" "$SID1" > "$after"
  got=$(fm_codex_session_parse_new_banner "$before" "$after") \
    || fail "one newly-added exact Codex banner should parse"
  [ "$got" = "$SID1" ] || fail "parser returned '$got', expected '$SID1'"

  printf '%s%s\n' "$FM_CODEX_SESSION_PREFIX" "$SID1" > "$before"
  printf '%s%s\n%s%s\n' "$FM_CODEX_SESSION_PREFIX" "$SID1" \
    "$FM_CODEX_SESSION_PREFIX" "$SID1" > "$after"
  got=$(fm_codex_session_parse_new_banner "$before" "$after") \
    || fail "a second occurrence of the same exact session banner should be the one new capture"
  [ "$got" = "$SID1" ] || fail "repeated-session delta returned '$got'"
  pass "Codex session parser accepts exactly one newly-added authoritative banner"
}

test_parser_rejects_absent_stale_multiple_malformed_and_truncated() {
  local before="$TMP_ROOT/reject-before" after="$TMP_ROOT/reject-after"
  printf '%s%s\n' "$FM_CODEX_SESSION_PREFIX" "$SID1" > "$before"
  cp "$before" "$after"
  if fm_codex_session_parse_new_banner "$before" "$after" >/dev/null 2>&1; then
    fail "a stale banner present before exit must not parse as new"
  fi
  : > "$before"
  : > "$after"
  if fm_codex_session_parse_new_banner "$before" "$after" >/dev/null 2>&1; then
    fail "an absent banner must refuse"
  fi
  printf '%s%s\n%s%s\n' "$FM_CODEX_SESSION_PREFIX" "$SID1" \
    "$FM_CODEX_SESSION_PREFIX" "$SID2" > "$after"
  if fm_codex_session_parse_new_banner "$before" "$after" >/dev/null 2>&1; then
    fail "multiple newly-added banners must refuse"
  fi
  printf '%snot-a-uuid\n' "$FM_CODEX_SESSION_PREFIX" > "$after"
  if fm_codex_session_parse_new_banner "$before" "$after" >/dev/null 2>&1; then
    fail "a malformed banner must refuse"
  fi
  printf '%s01a02b1e-c95e-7a92-9e37-\n' "$FM_CODEX_SESSION_PREFIX" > "$after"
  if fm_codex_session_parse_new_banner "$before" "$after" >/dev/null 2>&1; then
    fail "a truncated banner must refuse"
  fi
  pass "Codex session parser rejects absent, stale, multiple, malformed, and truncated captures"
}

test_binding_requires_exact_task_worktree_harness_spawn_and_backend_identity() {
  local state="$TMP_ROOT/identity-state" wt="$TMP_ROOT/identity-wt" meta="$TMP_ROOT/identity.meta"
  local changed="$TMP_ROOT/changed.meta" replacement="$TMP_ROOT/replacement.meta" got
  mkdir -p "$state" "$wt"
  write_meta "$meta" task1 "$wt" gen-1 codex herdr
  fm_codex_session_publish "$state" task1 "$meta" "$SID1" parked \
    || fail "exact Herdr binding should publish"
  got=$(fm_codex_session_validate "$state" task1 "$meta" parked) \
    || fail "exact Herdr binding should validate"
  [ "$got" = "$SID1" ] || fail "validated session id mismatch"
  [ "$(fm_codex_session_file_mode "$state/task1.codex-session")" = 600 ] \
    || fail "task sidecar must be mode 0600"

  cp "$meta" "$changed"; sed -i.bak 's/spawn_gen=gen-1/spawn_gen=gen-2/' "$changed"; rm -f "$changed.bak"
  if fm_codex_session_validate "$state" task1 "$changed" parked >/dev/null 2>&1; then
    fail "wrong spawn_gen must refuse"
  fi
  cp "$meta" "$changed"; sed -i.bak 's/harness=codex/harness=claude/' "$changed"; rm -f "$changed.bak"
  if fm_codex_session_validate "$state" task1 "$changed" parked >/dev/null 2>&1; then
    fail "wrong harness must refuse"
  fi
  cp "$meta" "$changed"; sed -i.bak 's/herdr_tab_id=tab:task1/herdr_tab_id=tab:foreign/' "$changed"; rm -f "$changed.bak"
  if fm_codex_session_validate "$state" task1 "$changed" parked >/dev/null 2>&1; then
    fail "wrong Herdr tab id must refuse"
  fi
  mkdir -p "$TMP_ROOT/other-wt"
  cp "$meta" "$changed"; sed -i.bak "s|worktree=$wt|worktree=$TMP_ROOT/other-wt|" "$changed"; rm -f "$changed.bak"
  if fm_codex_session_validate "$state" task1 "$changed" parked >/dev/null 2>&1; then
    fail "wrong canonical worktree must refuse"
  fi
  if fm_codex_session_validate "$state" task2 "$meta" parked >/dev/null 2>&1; then
    fail "wrong task id must refuse"
  fi
  fm_codex_session_transition "$state" task1 "$meta" parked resuming >/dev/null \
    || fail "Herdr identity fixture should enter resuming"
  if fm_codex_session_rebind "$state" task1 "$meta" "$meta" resuming live >/dev/null 2>&1; then
    fail "a rebind must advance to a distinct spawn_gen"
  fi
  write_meta "$replacement" task1 "$wt" gen-2 codex herdr
  cp "$replacement" "$changed"; sed -i.bak 's/herdr_tab_id=tab:task1/herdr_tab_id=tab:foreign/' "$changed"; rm -f "$changed.bak"
  if fm_codex_session_rebind "$state" task1 "$meta" "$changed" resuming live >/dev/null 2>&1; then
    fail "Herdr rebind must preserve the exact session/workspace/tab/pane ids"
  fi
  fm_codex_session_rebind "$state" task1 "$meta" "$replacement" resuming live >/dev/null \
    || fail "exact Herdr endpoint identity with a new spawn_gen should rebind"
  pass "Codex session binding requires exact task, worktree, harness, spawn incarnation, and Herdr endpoint ids"
}

test_binding_rejects_malformed_or_ambiguous_record_schema() {
  local state="$TMP_ROOT/schema-state" wt="$TMP_ROOT/schema-wt" meta="$TMP_ROOT/schema.meta"
  local side owner
  mkdir -p "$state" "$wt"
  write_meta "$meta" schema1 "$wt" gen-schema
  fm_codex_session_publish "$state" schema1 "$meta" "$SID1" parked \
    || fail "schema fixture should publish"
  side="$state/schema1.codex-session"
  owner="$state/codex-sessions/$SID1.owner"
  printf 'state=parked\n' >> "$side"
  printf 'state=parked\n' >> "$owner"
  if fm_codex_session_validate "$state" schema1 "$meta" parked >/dev/null 2>&1; then
    fail "duplicate keys in otherwise byte-identical records must refuse"
  fi
  fm_codex_session_retire "$state" schema1 >/dev/null 2>&1 \
    && fail "retirement must refuse malformed records rather than unlinking by ambiguity"
  if fm_codex_session_publish "$state" '../escape' "$meta" "$SID2" parked >/dev/null 2>&1; then
    fail "an unsafe task id must not become a sidecar path"
  fi
  pass "Codex session state rejects duplicate, extra, and unsafe record identities"
}

test_lifecycle_rebinds_to_new_incarnation_and_uncertain_never_resumes() {
  local state="$TMP_ROOT/lifecycle-state" wt="$TMP_ROOT/lifecycle-wt"
  local old="$TMP_ROOT/lifecycle-old.meta" new="$TMP_ROOT/lifecycle-new.meta"
  mkdir -p "$state" "$wt"
  write_meta "$old" task3 "$wt" gen-old
  write_meta "$new" task3 "$wt" gen-new
  fm_codex_session_publish "$state" task3 "$old" "$SID1" parked || fail "park publish failed"
  fm_codex_session_transition "$state" task3 "$old" parked resuming >/dev/null \
    || fail "parked -> resuming failed"
  fm_codex_session_rebind "$state" task3 "$old" "$new" resuming live >/dev/null \
    || fail "resuming -> live rebind failed"
  fm_codex_session_validate "$state" task3 "$new" live >/dev/null \
    || fail "live binding should follow new spawn incarnation"
  if fm_codex_session_validate "$state" task3 "$old" live >/dev/null 2>&1; then
    fail "old spawn incarnation must become stale"
  fi
  fm_codex_session_transition "$state" task3 "$new" live uncertain >/dev/null \
    || fail "live -> uncertain failed"
  if fm_codex_session_validate "$state" task3 "$new" parked >/dev/null 2>&1; then
    fail "uncertain binding must never validate as parked"
  fi
  pass "Codex session lifecycle rebinds exact spawn incarnation and keeps uncertain state non-resumable"
}

test_cross_task_duplicate_session_is_fenced_and_retirement_releases_owner() {
  local state="$TMP_ROOT/duplicate-state" wt1="$TMP_ROOT/dup-wt1" wt2="$TMP_ROOT/dup-wt2"
  local meta1="$TMP_ROOT/dup1.meta" meta2="$TMP_ROOT/dup2.meta" rc1 rc2 successes
  mkdir -p "$state" "$wt1" "$wt2"
  write_meta "$meta1" dup1 "$wt1" gen-1
  write_meta "$meta2" dup2 "$wt2" gen-2
  fm_codex_session_publish "$state" dup1 "$meta1" "$SID1" parked & p1=$!
  fm_codex_session_publish "$state" dup2 "$meta2" "$SID1" parked & p2=$!
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?
  successes=0
  [ "$rc1" -ne 0 ] || successes=$((successes + 1))
  [ "$rc2" -ne 0 ] || successes=$((successes + 1))
  [ "$successes" -eq 1 ] || fail "exactly one cross-task claim should succeed (rc1=$rc1 rc2=$rc2)"
  if [ "$rc1" -eq 0 ]; then
    fm_codex_session_retire "$state" dup1 || fail "winning owner retirement failed"
    fm_codex_session_publish "$state" dup2 "$meta2" "$SID1" parked \
      || fail "session owner should be reusable only after exact retirement"
  else
    fm_codex_session_retire "$state" dup2 || fail "winning owner retirement failed"
    fm_codex_session_publish "$state" dup1 "$meta1" "$SID1" parked \
      || fail "session owner should be reusable only after exact retirement"
  fi
  pass "Codex session index fences concurrent cross-task duplication and releases only on exact retirement"
}

test_parser_accepts_one_new_exact_banner
test_parser_rejects_absent_stale_multiple_malformed_and_truncated
test_binding_requires_exact_task_worktree_harness_spawn_and_backend_identity
test_binding_rejects_malformed_or_ambiguous_record_schema
test_lifecycle_rebinds_to_new_incarnation_and_uncertain_never_resumes
test_cross_task_duplicate_session_is_fenced_and_retirement_releases_owner
