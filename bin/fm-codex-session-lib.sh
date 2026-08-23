#!/usr/bin/env bash
# fm-codex-session-lib.sh - backend-neutral exact Codex session bindings.
#
# This is the single owner of the resumable-Codex persisted-state contract.
# The feature is opt-in through fm-control.sh (`exit --resumable` and
# `relaunch --resume`); fresh spawn, ordinary exit, and ordinary relaunch do
# not create or consume these records.
#
# A task binding is state/<task-id>.codex-session.  The same bytes are indexed
# by exact session UUID at state/codex-sessions/<session-id>.owner.  Both are
# mode 0600 regular files beneath a mode 0700 real directory.  Each v1 record
# contains exactly these identity fields:
#
#   version task_id session_id harness worktree backend endpoint spawn_gen
#   herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id state updated_at
#
# `worktree` is physical/canonical.  tmux identity is the exact recorded
# endpoint.  Herdr additionally requires the exact recorded named session,
# workspace, tab, and pane ids.  `spawn_gen` binds the conversation to one
# agent incarnation.  Lifecycle states are parked, resuming, live, uncertain,
# and retired; uncertain is deliberately not resumable.
#
# Every mutation serializes on state/.codex-session-index.lock after the
# caller's task lifecycle lock.  The UUID owner is published before the task
# sidecar, and the task sidecar is removed before its owner, so a crash can
# leave a conservative orphan that blocks reuse but can never make one session
# available to two task ids.  Any missing, malformed, duplicated, stale, or
# mismatched field refuses instead of being repaired by inference.
#
# Codex 0.149.0-alpha.4.1 prints this exact post-exit line:
#   To continue this session, run codex resume <canonical-lowercase-UUID>
# fm_codex_session_parse_new_banner compares bounded captures from immediately
# before and after /quit and accepts exactly one newly-added exact line.  It
# never scans arbitrary UUIDs, accepts a name, uses --last, or infers from cwd.

FM_CODEX_SESSION_PREFIX='To continue this session, run codex resume '

fm_codex_session_uuid_valid() {  # <session-id>
  local value=${1-} a b c d e extra
  case "$value" in *[!0-9a-f-]*|'') return 1 ;; esac
  IFS=- read -r a b c d e extra <<EOF
$value
EOF
  [ -z "${extra:-}" ] \
    && [ "${#a}" -eq 8 ] && [ "${#b}" -eq 4 ] \
    && [ "${#c}" -eq 4 ] && [ "${#d}" -eq 4 ] \
    && [ "${#e}" -eq 12 ]
}

fm_codex_session_task_valid() {  # <task-id>
  case "${1-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_codex_session_parse_new_banner() {  # <before-capture> <after-capture>
  local before=${1-} after=${2-}
  [ -f "$before" ] && [ -f "$after" ] || return 1
  awk -v before_name="$before" -v prefix="$FM_CODEX_SESSION_PREFIX" '
    function uuid_valid(value, parts, count) {
      if (value == "" || value ~ /[^0-9a-f-]/) return 0
      count = split(value, parts, "-")
      return count == 5 && length(parts[1]) == 8 && length(parts[2]) == 4 \
        && length(parts[3]) == 4 && length(parts[4]) == 4 \
        && length(parts[5]) == 12
    }
    FILENAME == before_name {
      if (index($0, prefix) == 1) {
        value = substr($0, length(prefix) + 1)
        if (uuid_valid(value)) before[value]++
      }
      next
    }
    index($0, prefix) > 0 {
      value = substr($0, length(prefix) + 1)
      if (index($0, prefix) != 1 || !uuid_valid(value)) malformed = 1
      else after[value]++
    }
    END {
      if (malformed) exit 2
      total = 0
      selected = ""
      for (value in after) {
        delta = after[value] - before[value]
        while (delta > 0) {
          selected = value
          total++
          delta--
        }
      }
      if (total != 1) exit 1
      print selected
    }
  ' "$before" "$after"
}

fm_codex_session_task_path() {  # <state-dir> <task-id>
  printf '%s/%s.codex-session' "$1" "$2"
}

fm_codex_session_owner_dir() {  # <state-dir>
  printf '%s/codex-sessions' "$1"
}

fm_codex_session_owner_path() {  # <state-dir> <session-id>
  printf '%s/codex-sessions/%s.owner' "$1" "$2"
}

fm_codex_session_field() {  # <record> <key>
  awk -F= -v key="$2" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

fm_codex_session_meta_field() {  # <meta> <key>
  fm_codex_session_field "$1" "$2"
}

fm_codex_session_file_mode() {  # <path>
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

fm_codex_session_record_regular() {  # <record>
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(fm_codex_session_file_mode "$1")" = 600 ]
}

fm_codex_session_record_schema_valid() {  # <record>
  awk -F= '
    BEGIN {
      expected[1] = "version"
      expected[2] = "task_id"
      expected[3] = "session_id"
      expected[4] = "harness"
      expected[5] = "worktree"
      expected[6] = "backend"
      expected[7] = "endpoint"
      expected[8] = "spawn_gen"
      expected[9] = "herdr_session"
      expected[10] = "herdr_workspace_id"
      expected[11] = "herdr_tab_id"
      expected[12] = "herdr_pane_id"
      expected[13] = "state"
      expected[14] = "updated_at"
    }
    {
      line++
      if (line > 14 || $1 != expected[line]) bad = 1
    }
    END { exit bad || line != 14 }
  ' "$1"
}

fm_codex_session_backend_of_meta() {  # <meta>
  local backend
  backend=$(fm_codex_session_meta_field "$1" backend 2>/dev/null || true)
  printf '%s' "${backend:-tmux}"
}

fm_codex_session_canonical_worktree() {  # <path>
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_codex_session_record_write() {  # <path> <task> <session> <meta> <state> [updated-at]
  local path=$1 task=$2 session=$3 meta=$4 lifecycle=$5 updated_at=${6:-}
  local wt backend endpoint spawn_gen harness hs hw ht hp tmp old_umask
  fm_codex_session_uuid_valid "$session" || return 1
  fm_codex_session_task_valid "$task" || return 1
  case "$lifecycle" in parked|resuming|live|uncertain|retired) ;; *) return 1 ;; esac
  [ -n "$updated_at" ] || updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  harness=$(fm_codex_session_meta_field "$meta" harness 2>/dev/null || true)
  [ "$harness" = codex ] || return 1
  wt=$(fm_codex_session_meta_field "$meta" worktree 2>/dev/null || true)
  wt=$(fm_codex_session_canonical_worktree "$wt") || return 1
  backend=$(fm_codex_session_backend_of_meta "$meta")
  case "$backend" in tmux|herdr) ;; *) return 1 ;; esac
  endpoint=$(fm_codex_session_meta_field "$meta" window 2>/dev/null || true)
  spawn_gen=$(fm_codex_session_meta_field "$meta" spawn_gen 2>/dev/null || true)
  [ -n "$endpoint" ] && [ -n "$spawn_gen" ] || return 1
  hs=; hw=; ht=; hp=
  if [ "$backend" = herdr ]; then
    hs=$(fm_codex_session_meta_field "$meta" herdr_session 2>/dev/null || true)
    hw=$(fm_codex_session_meta_field "$meta" herdr_workspace_id 2>/dev/null || true)
    ht=$(fm_codex_session_meta_field "$meta" herdr_tab_id 2>/dev/null || true)
    hp=$(fm_codex_session_meta_field "$meta" herdr_pane_id 2>/dev/null || true)
    [ -n "$hs" ] && [ -n "$hw" ] && [ -n "$ht" ] && [ -n "$hp" ] || return 1
    [ "$endpoint" = "$hs:$hp" ] || return 1
  fi
  tmp="$path.tmp.${BASHPID:-$$}.$RANDOM"
  old_umask=$(umask)
  umask 077
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$task"
    printf 'session_id=%s\n' "$session"
    printf 'harness=codex\n'
    printf 'worktree=%s\n' "$wt"
    printf 'backend=%s\n' "$backend"
    printf 'endpoint=%s\n' "$endpoint"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'herdr_session=%s\n' "$hs"
    printf 'herdr_workspace_id=%s\n' "$hw"
    printf 'herdr_tab_id=%s\n' "$ht"
    printf 'herdr_pane_id=%s\n' "$hp"
    printf 'state=%s\n' "$lifecycle"
    printf 'updated_at=%s\n' "$updated_at"
  } > "$tmp" || { umask "$old_umask"; rm -f "$tmp"; return 1; }
  umask "$old_umask"
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

fm_codex_session_prepare_owner_dir() {  # <state-dir>
  local dir
  dir=$(fm_codex_session_owner_dir "$1")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir -p "$dir" || return 1
  fi
  chmod 700 "$dir" || return 1
}

fm_codex_session_index_lock_acquire() {  # <state-dir>
  FM_CODEX_SESSION_INDEX_LOCK="$1/.codex-session-index.lock"
  fm_lock_try_acquire "$FM_CODEX_SESSION_INDEX_LOCK"
}

fm_codex_session_index_lock_release() {
  fm_lock_release "$FM_CODEX_SESSION_INDEX_LOCK"
  FM_CODEX_SESSION_INDEX_LOCK=
}

fm_codex_session_validate_locked() {  # <state> <task> <meta> <allowed-state...>
  local state_dir=$1 task=$2 meta=$3 side session owner field actual expected allowed=0 want
  shift 3
  fm_codex_session_task_valid "$task" || return 1
  side="$state_dir/$task.codex-session"
  fm_codex_session_record_regular "$side" || return 1
  fm_codex_session_record_schema_valid "$side" || return 1
  session=$(fm_codex_session_field "$side" session_id 2>/dev/null || true)
  fm_codex_session_uuid_valid "$session" || return 1
  owner=$(fm_codex_session_owner_path "$state_dir" "$session")
  fm_codex_session_record_regular "$owner" || return 1
  fm_codex_session_record_schema_valid "$owner" || return 1
  cmp -s "$side" "$owner" || return 1
  [ "$(fm_codex_session_field "$side" version 2>/dev/null || true)" = 1 ] || return 1
  [ "$(fm_codex_session_field "$side" task_id 2>/dev/null || true)" = "$task" ] || return 1
  [ "$(fm_codex_session_field "$side" harness 2>/dev/null || true)" = codex ] || return 1
  for want in "$@"; do
    [ "$(fm_codex_session_field "$side" state 2>/dev/null || true)" != "$want" ] || allowed=1
  done
  [ "$allowed" = 1 ] || return 1
  for field in worktree spawn_gen; do
    actual=$(fm_codex_session_field "$side" "$field" 2>/dev/null || true)
    expected=$(fm_codex_session_meta_field "$meta" "$field" 2>/dev/null || true)
    if [ "$field" = worktree ]; then
      expected=$(fm_codex_session_canonical_worktree "$expected") || return 1
    fi
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || return 1
  done
  expected=$(fm_codex_session_backend_of_meta "$meta")
  [ "$(fm_codex_session_field "$side" backend 2>/dev/null || true)" = "$expected" ] || return 1
  expected=$(fm_codex_session_meta_field "$meta" window 2>/dev/null || true)
  [ -n "$expected" ] && [ "$(fm_codex_session_field "$side" endpoint 2>/dev/null || true)" = "$expected" ] || return 1
  [ "$(fm_codex_session_meta_field "$meta" harness 2>/dev/null || true)" = codex ] || return 1
  if [ "$(fm_codex_session_backend_of_meta "$meta")" = herdr ]; then
    for field in herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
      actual=$(fm_codex_session_field "$side" "$field" 2>/dev/null || true)
      expected=$(fm_codex_session_meta_field "$meta" "$field" 2>/dev/null || true)
      [ -n "$expected" ] && [ "$actual" = "$expected" ] || return 1
    done
  fi
  printf '%s\n' "$session"
}

fm_codex_session_validate() {  # <state> <task> <meta> <allowed-state...>
  local state_dir=$1 result status
  shift
  fm_codex_session_index_lock_acquire "$state_dir" || return 1
  if result=$(fm_codex_session_validate_locked "$state_dir" "$@"); then
    status=0
  else
    status=$?
  fi
  fm_codex_session_index_lock_release || return 1
  [ "$status" -eq 0 ] || return "$status"
  printf '%s' "$result"
}

fm_codex_session_publish() {  # <state> <task> <meta> <session> <state>
  local state_dir=$1 task=$2 meta=$3 session=$4 lifecycle=$5 side owner existing owner_task status=0 updated_at
  fm_codex_session_task_valid "$task" || return 1
  fm_codex_session_uuid_valid "$session" || return 1
  fm_codex_session_prepare_owner_dir "$state_dir" || return 1
  fm_codex_session_index_lock_acquire "$state_dir" || return 1
  side=$(fm_codex_session_task_path "$state_dir" "$task")
  owner=$(fm_codex_session_owner_path "$state_dir" "$session")
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    if ! fm_codex_session_record_regular "$owner" \
       || ! fm_codex_session_record_schema_valid "$owner"; then
      status=1
    else
      owner_task=$(fm_codex_session_field "$owner" task_id 2>/dev/null || true)
      [ "$owner_task" = "$task" ] || status=1
    fi
  fi
  if [ "$status" -eq 0 ] && { [ -e "$side" ] || [ -L "$side" ]; }; then
    if ! fm_codex_session_record_regular "$side" \
       || ! fm_codex_session_record_schema_valid "$side"; then
      status=1
    else
      existing=$(fm_codex_session_field "$side" session_id 2>/dev/null || true)
      [ "$existing" = "$session" ] || status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fm_codex_session_record_write "$owner" "$task" "$session" "$meta" "$lifecycle" "$updated_at" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_codex_session_record_write "$side" "$task" "$session" "$meta" "$lifecycle" "$updated_at" || status=1
  fi
  fm_codex_session_index_lock_release || status=1
  return "$status"
}

fm_codex_session_transition() {  # <state> <task> <meta> <expected> <new>
  local state_dir=$1 task=$2 meta=$3 expected=$4 lifecycle=$5 session side owner status=0 updated_at
  fm_codex_session_task_valid "$task" || return 1
  fm_codex_session_index_lock_acquire "$state_dir" || return 1
  session=$(fm_codex_session_validate_locked "$state_dir" "$task" "$meta" "$expected" 2>/dev/null) || status=1
  side=$(fm_codex_session_task_path "$state_dir" "$task")
  owner=$(fm_codex_session_owner_path "$state_dir" "$session")
  if [ "$status" -eq 0 ]; then
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fm_codex_session_record_write "$owner" "$task" "$session" "$meta" "$lifecycle" "$updated_at" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_codex_session_record_write "$side" "$task" "$session" "$meta" "$lifecycle" "$updated_at" || status=1
  fi
  fm_codex_session_index_lock_release || status=1
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$session"
}

fm_codex_session_rebind() {  # <state> <task> <old-meta> <new-meta> <expected> <new>
  local state_dir=$1 task=$2 old_meta=$3 new_meta=$4 expected=$5 lifecycle=$6
  local session side owner status=0 old_endpoint new_endpoint old_wt new_wt updated_at
  local old_backend new_backend old_gen new_gen field old_value new_value
  fm_codex_session_task_valid "$task" || return 1
  fm_codex_session_index_lock_acquire "$state_dir" || return 1
  session=$(fm_codex_session_validate_locked "$state_dir" "$task" "$old_meta" "$expected" 2>/dev/null) || status=1
  old_endpoint=$(fm_codex_session_meta_field "$old_meta" window 2>/dev/null || true)
  new_endpoint=$(fm_codex_session_meta_field "$new_meta" window 2>/dev/null || true)
  old_wt=$(fm_codex_session_meta_field "$old_meta" worktree 2>/dev/null || true)
  new_wt=$(fm_codex_session_meta_field "$new_meta" worktree 2>/dev/null || true)
  old_backend=$(fm_codex_session_backend_of_meta "$old_meta")
  new_backend=$(fm_codex_session_backend_of_meta "$new_meta")
  old_gen=$(fm_codex_session_meta_field "$old_meta" spawn_gen 2>/dev/null || true)
  new_gen=$(fm_codex_session_meta_field "$new_meta" spawn_gen 2>/dev/null || true)
  [ "$old_endpoint" = "$new_endpoint" ] \
    && [ "$old_wt" = "$new_wt" ] \
    && [ "$old_backend" = "$new_backend" ] \
    && [ -n "$old_gen" ] && [ -n "$new_gen" ] \
    && [ "$old_gen" != "$new_gen" ] || status=1
  if [ "$status" -eq 0 ] && [ "$old_backend" = herdr ]; then
    for field in herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
      old_value=$(fm_codex_session_meta_field "$old_meta" "$field" 2>/dev/null || true)
      new_value=$(fm_codex_session_meta_field "$new_meta" "$field" 2>/dev/null || true)
      [ -n "$old_value" ] && [ "$old_value" = "$new_value" ] || status=1
    done
  fi
  side=$(fm_codex_session_task_path "$state_dir" "$task")
  owner=$(fm_codex_session_owner_path "$state_dir" "$session")
  if [ "$status" -eq 0 ]; then
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fm_codex_session_record_write "$owner" "$task" "$session" "$new_meta" "$lifecycle" "$updated_at" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_codex_session_record_write "$side" "$task" "$session" "$new_meta" "$lifecycle" "$updated_at" || status=1
  fi
  fm_codex_session_index_lock_release || status=1
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$session"
}

fm_codex_session_retire() {  # <state> <task>
  local state_dir=$1 task=$2 side session owner owner_task status=0
  fm_codex_session_task_valid "$task" || return 1
  side=$(fm_codex_session_task_path "$state_dir" "$task")
  # Callers hold the task lifecycle lock, so an absent task sidecar cannot
  # appear concurrently for this task. Keep the overwhelmingly common
  # disposable path free of the global exact-session index lock.
  if [ ! -e "$side" ] && [ ! -L "$side" ]; then
    return 0
  fi
  fm_codex_session_index_lock_acquire "$state_dir" || return 1
  if [ ! -e "$side" ] && [ ! -L "$side" ]; then
    fm_codex_session_index_lock_release
    return 0
  fi
  if ! fm_codex_session_record_regular "$side" \
     || ! fm_codex_session_record_schema_valid "$side"; then
    status=1
  else
    session=$(fm_codex_session_field "$side" session_id 2>/dev/null || true)
    fm_codex_session_uuid_valid "$session" || status=1
  fi
  owner=$(fm_codex_session_owner_path "$state_dir" "$session")
  if [ "$status" -eq 0 ] && { [ -e "$owner" ] || [ -L "$owner" ]; }; then
    if ! fm_codex_session_record_regular "$owner" \
       || ! fm_codex_session_record_schema_valid "$owner"; then
      status=1
    else
      owner_task=$(fm_codex_session_field "$owner" task_id 2>/dev/null || true)
      [ "$owner_task" = "$task" ] && cmp -s "$side" "$owner" || status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    rm -f "$side" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    rm -f "$owner" || status=1
  fi
  fm_codex_session_index_lock_release || status=1
  return "$status"
}
