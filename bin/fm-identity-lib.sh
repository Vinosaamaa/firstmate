#!/usr/bin/env bash
# Shared persistent human identity for one Firstmate home and its tasks.
#
# data/firstmate.identity owns the home's human-friendly name.
# data/crew-identities/<task-id>.identity owns a task's callsign binding and is
# retained after teardown as the historical non-rebinding tombstone.
# Task ids remain the internal identity. Callsigns are case-insensitive selectors
# within exactly one canonical FM_HOME and never replace backend endpoint checks.
#
# A fresh spawn reserves its callsign before creating an endpoint, then publishes
# the exact worktree/backend/endpoint binding before launching the agent. A retry
# of the same interrupted provisioning reuses that reservation. An archived task
# id is never silently reused for a fresh task.
#
# Records are line-oriented key=value files. Values must contain no control
# characters. Repeated retired_callsign= lines preserve every prior task name so
# none can be assigned again. Known harness conversation metadata is copied as
# harness_session_id= when available; endpoint_session_id= separately records the
# tmux or Herdr container session. Unknown future meta fields remain untouched.

FM_IDENTITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_IDENTITY_DEFAULT_ROOT="$(cd "$FM_IDENTITY_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_IDENTITY_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_IDENTITY_STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_IDENTITY_HOME="${FM_IDENTITY_HOME_OVERRIDE:-$FM_HOME}"
if [ -n "${FM_STATE_OVERRIDE:-}" ] && [ -z "${FM_IDENTITY_HOME_OVERRIDE:-}" ] \
   && [ "${FM_STATE_OVERRIDE##*/}" = state ]; then
  # Test/recovery callers routinely redirect only state/. Treat its parent as
  # the logical home for identity too, so an isolated lifecycle probe cannot
  # leak durable callsigns into the code checkout's private data directory.
  FM_IDENTITY_HOME=${FM_STATE_OVERRIDE%/state}
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_IDENTITY_DATA=$FM_DATA_OVERRIDE
elif [ -n "${FM_STATE_OVERRIDE:-}" ] && [ "${FM_STATE_OVERRIDE##*/}" = state ]; then
  FM_IDENTITY_DATA=${FM_STATE_OVERRIDE%/state}/data
else
  FM_IDENTITY_DATA=${DATA:-$FM_IDENTITY_HOME/data}
fi
FM_IDENTITY_DIR="$FM_IDENTITY_DATA/crew-identities"
FM_IDENTITY_HOME_RECORD="$FM_IDENTITY_DATA/firstmate.identity"
FM_IDENTITY_LOCK="$FM_IDENTITY_DATA/.identity.lock"

FM_IDENTITY_CALLSIGN_POOL="Ada Bell Burnell Carson Curie Darwin Edison Euler Faraday Franklin Galileo Hamilton Hedy Hopper Joule Kepler Lamarr Lovelace Maxwell Mendeleev Newton Noether Pascal Raman Sagan Tesla Turing Verne Watt Wilkins"
FM_IDENTITY_HOME_POOL="Aurora Beagle Calypso Discovery Endeavour Horizon Intrepid Nautilus Odyssey Polaris Resolute Venture Voyager"

fm_identity_error() {
  printf 'error: %s\n' "$*" >&2
}

fm_identity_now() {
  printf '%s\n' "${FM_IDENTITY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

fm_identity_canonical_dir() {  # <directory>
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_identity_home_path() {
  fm_identity_canonical_dir "$FM_IDENTITY_HOME"
}

fm_identity_fold() {
  local value=$1 folded='' char i LC_ALL=C
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      A) char=a ;; B) char=b ;; C) char=c ;; D) char=d ;; E) char=e ;;
      F) char=f ;; G) char=g ;; H) char=h ;; I) char=i ;; J) char=j ;;
      K) char=k ;; L) char=l ;; M) char=m ;; N) char=n ;; O) char=o ;;
      P) char=p ;; Q) char=q ;; R) char=r ;; S) char=s ;; T) char=t ;;
      U) char=u ;; V) char=v ;; W) char=w ;; X) char=x ;; Y) char=y ;;
      Z) char=z ;;
    esac
    folded=$folded$char
  done
  printf '%s' "$folded"
}

fm_identity_value_safe() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*|'') return 1 ;;
  esac
}

fm_identity_name_valid() {  # <name>
  local name=${1:-}
  [ "${#name}" -ge 2 ] && [ "${#name}" -le 32 ] || return 1
  case "$name" in
    [A-Za-z]* ) ;;
    *) return 1 ;;
  esac
  case "$name" in *[!A-Za-z0-9-]*|*-) return 1 ;; esac
}

fm_identity_task_id_valid() {  # <task-id>
  local id=${1:-} LC_ALL=C
  [ "${#id}" -le 64 ] || return 1
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_identity_name_reserved() {  # <name>
  local folded
  folded=$(fm_identity_fold "$1")
  case "$folded" in
    captain|firstmate|first-mate|mate|crew|crewmate|secondmate|second-mate|scout|ship|default|unknown|unnamed|archived|active|provisioning|fm-*) return 0 ;;
  esac
  return 1
}

fm_identity_validate_name() {  # <name>
  fm_identity_name_valid "$1" || {
    fm_identity_error "callsign '$1' must be 2-32 characters, start with a letter, and contain only letters, digits, or single hyphens"
    return 1
  }
  fm_identity_name_reserved "$1" && {
    fm_identity_error "callsign '$1' is reserved"
    return 1
  }
  return 0
}

fm_identity_record_value() {  # <record> <key>
  local record=$1 key=$2 count=0 value='' line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) count=$((count + 1)); value=${line#*=} ;;
    esac
  done < "$record"
  [ "$count" -eq 1 ] || return 1
  fm_identity_value_safe "$value" || return 1
  printf '%s' "$value"
}

fm_identity_task_record() {  # <task-id>
  fm_identity_task_id_valid "$1" || return 1
  printf '%s/%s.identity' "$FM_IDENTITY_DIR" "$1"
}

fm_identity_source_lock_helpers() {
  declare -F fm_lock_acquire_wait >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_IDENTITY_LIB_DIR/fm-wake-lib.sh"
}

fm_identity_prepare_dirs() {
  mkdir -p "$FM_IDENTITY_DATA" || return 1
  if [ -e "$FM_IDENTITY_DIR" ] || [ -L "$FM_IDENTITY_DIR" ]; then
    [ -d "$FM_IDENTITY_DIR" ] && [ ! -L "$FM_IDENTITY_DIR" ] || {
      fm_identity_error "identity registry '$FM_IDENTITY_DIR' is not a real directory"
      return 1
    }
  else
    mkdir "$FM_IDENTITY_DIR" || return 1
  fi
  chmod 700 "$FM_IDENTITY_DIR" || return 1
}

fm_identity_lock_acquire() {
  fm_identity_prepare_dirs || return 1
  fm_identity_source_lock_helpers || return 1
  fm_lock_acquire_wait "$FM_IDENTITY_LOCK"
}

fm_identity_lock_release() {
  fm_lock_release "$FM_IDENTITY_LOCK"
}

fm_identity_checksum() {
  local value=$1 i code sum=5381 LC_ALL=C
  for ((i = 0; i < ${#value}; i++)); do
    printf -v code '%d' "'${value:i:1}"
    sum=$(((sum * 33 + code) % 2147483647))
  done
  printf '%s' "$sum"
}

fm_identity_pool_at() {  # <space-delimited-pool> <index>
  local pool=$1 wanted=$2 item i=0
  for item in $pool; do
    [ "$i" -eq "$wanted" ] && { printf '%s' "$item"; return 0; }
    i=$((i + 1))
  done
  return 1
}

fm_identity_pool_size() {  # <space-delimited-pool>
  local pool=$1 item n=0
  for item in $pool; do n=$((n + 1)); done
  printf '%s' "$n"
}

fm_identity_all_names() {
  local record
  if [ -f "$FM_IDENTITY_HOME_RECORD" ] && [ ! -L "$FM_IDENTITY_HOME_RECORD" ]; then
    sed -n -e 's/^name=//p' -e 's/^previous_name=//p' "$FM_IDENTITY_HOME_RECORD"
  fi
  for record in "$FM_IDENTITY_DIR"/*.identity; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    sed -n -e 's/^callsign=//p' -e 's/^retired_callsign=//p' "$record"
  done
}

fm_identity_human_name_matches_any() {  # <name> [record-to-ignore]
  local wanted ignore=${2:-} record value line
  wanted=$(fm_identity_fold "$1")
  if [ "$FM_IDENTITY_HOME_RECORD" != "$ignore" ] && [ -f "$FM_IDENTITY_HOME_RECORD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in name=*|previous_name=*) value=${line#*=} ;; *) continue ;; esac
      [ "$(fm_identity_fold "$value")" = "$wanted" ] && return 0
    done < "$FM_IDENTITY_HOME_RECORD"
  fi
  for record in "$FM_IDENTITY_DIR"/*.identity; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    [ "$record" = "$ignore" ] && continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in callsign=*|retired_callsign=*) value=${line#*=} ;; *) continue ;; esac
      [ "$(fm_identity_fold "$value")" = "$wanted" ] && return 0
    done < "$record"
  done
  return 1
}

fm_identity_name_matches_any() {  # <name> [record-to-ignore]
  local wanted ignore=${2:-} id_path id
  wanted=$(fm_identity_fold "$1")
  fm_identity_human_name_matches_any "$1" "$ignore" && return 0
  for id_path in "$FM_IDENTITY_DIR"/*.identity "$FM_IDENTITY_STATE"/*.meta; do
    [ -e "$id_path" ] || continue
    id=${id_path##*/}
    id=${id%.identity}
    id=${id%.meta}
    [ "$(fm_identity_fold "$id")" = "$wanted" ] && return 0
  done
  return 1
}

fm_identity_choose_home_name() {
  local home checksum size index name suffix=2
  home=$(fm_identity_home_path) || return 1
  checksum=$(fm_identity_checksum "$home") || return 1
  size=$(fm_identity_pool_size "$FM_IDENTITY_HOME_POOL")
  index=$((checksum % size))
  name=$(fm_identity_pool_at "$FM_IDENTITY_HOME_POOL" "$index") || return 1
  while fm_identity_name_matches_any "$name"; do
    case "$name" in *-[0-9]*) name=${name%-*}-$suffix ;; *) name=$name-$suffix ;; esac
    suffix=$((suffix + 1))
  done
  printf '%s' "$name"
}

fm_identity_choose_fresh_callsign() {  # <task-id>
  local id=$1 home checksum size start offset index candidate suffix=2
  home=$(fm_identity_home_path) || return 1
  checksum=$(fm_identity_checksum "$home:$id") || return 1
  size=$(fm_identity_pool_size "$FM_IDENTITY_CALLSIGN_POOL")
  start=$((checksum % size))
  offset=0
  while [ "$offset" -lt "$size" ]; do
    index=$(((start + offset) % size))
    candidate=$(fm_identity_pool_at "$FM_IDENTITY_CALLSIGN_POOL" "$index") || return 1
    if [ "$(fm_identity_fold "$candidate")" != "$(fm_identity_fold "$id")" ] \
       && ! fm_identity_name_matches_any "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    offset=$((offset + 1))
  done
  candidate=$(fm_identity_pool_at "$FM_IDENTITY_CALLSIGN_POOL" "$start") || return 1
  while [ "$(fm_identity_fold "$candidate-$suffix")" = "$(fm_identity_fold "$id")" ] \
     || fm_identity_name_matches_any "$candidate-$suffix"; do
    suffix=$((suffix + 1))
  done
  printf '%s-%s' "$candidate" "$suffix"
}

fm_identity_legacy_callsign() {  # <task-id>, deterministic read-only fallback
  local id=$1 home checksum size base tag
  home=$(fm_identity_home_path 2>/dev/null || printf '%s' "$FM_IDENTITY_HOME")
  checksum=$(fm_identity_checksum "$home:$id:legacy") || return 1
  size=$(fm_identity_pool_size "$FM_IDENTITY_CALLSIGN_POOL")
  base=$(fm_identity_pool_at "$FM_IDENTITY_CALLSIGN_POOL" "$((checksum % size))") || return 1
  tag=$((checksum % 100000))
  if [ "$(fm_identity_fold "$base-L$tag")" = "$(fm_identity_fold "$id")" ]; then
    tag="${tag}1"
  fi
  printf '%s-L%s' "$base" "$tag"
}

fm_identity_write_home_record() {  # <name> <created> [previous-name-lines-file]
  local name=$1 created=$2 previous_file=${3:-} home tmp
  home=$(fm_identity_home_path) || return 1
  tmp=$(mktemp "$FM_IDENTITY_DATA/.firstmate.identity.XXXXXXXX") || return 1
  {
    printf 'schema=fm-firstmate-identity.v1\n'
    printf 'home=%s\n' "$home"
    printf 'name=%s\n' "$name"
    printf 'created_at=%s\n' "$created"
    printf 'updated_at=%s\n' "$(fm_identity_now)"
    [ -n "$previous_file" ] && [ -f "$previous_file" ] && cat "$previous_file"
    true
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FM_IDENTITY_HOME_RECORD"
}

fm_identity_ensure_home_locked() {
  local home name created schema recorded_home
  home=$(fm_identity_home_path) || { fm_identity_error "Firstmate home '$FM_IDENTITY_HOME' is not a readable directory"; return 1; }
  if [ -e "$FM_IDENTITY_HOME_RECORD" ] || [ -L "$FM_IDENTITY_HOME_RECORD" ]; then
    schema=$(fm_identity_record_value "$FM_IDENTITY_HOME_RECORD" schema 2>/dev/null || true)
    recorded_home=$(fm_identity_record_value "$FM_IDENTITY_HOME_RECORD" home 2>/dev/null || true)
    name=$(fm_identity_record_value "$FM_IDENTITY_HOME_RECORD" name 2>/dev/null || true)
    if [ "$schema" != fm-firstmate-identity.v1 ] || [ "$recorded_home" != "$home" ] \
       || ! fm_identity_validate_name "$name" >/dev/null 2>&1 \
       || fm_identity_name_matches_any "$name" "$FM_IDENTITY_HOME_RECORD"; then
      fm_identity_error "Firstmate identity record '$FM_IDENTITY_HOME_RECORD' is malformed or belongs to another home; refusing to guess"
      return 1
    fi
    printf '%s' "$name"
    return 0
  fi
  name=$(fm_identity_choose_home_name) || return 1
  created=$(fm_identity_now)
  fm_identity_write_home_record "$name" "$created" || return 1
  printf '%s' "$name"
}

fm_identity_ensure_home() {
  local name
  fm_identity_lock_acquire || return 1
  name=$(fm_identity_ensure_home_locked) || { fm_identity_lock_release; return 1; }
  fm_identity_lock_release
  printf '%s' "$name"
}

fm_identity_meta_value() {  # <meta> <key>
  local meta=$1 key=$2 line value=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) value=${line#*=} ;; esac
  done < "$meta"
  printf '%s' "$value"
}

fm_identity_backend_of_meta() {
  local remote
  remote=$(fm_identity_meta_value "$1" remote_host)
  if [ -n "$remote" ]; then
    fm_identity_meta_value "$1" remote_backend
    return
  fi
  if declare -F fm_backend_of_meta >/dev/null 2>&1; then
    fm_backend_of_meta "$1"
  else
    local backend
    backend=$(fm_identity_meta_value "$1" backend)
    printf '%s' "${backend:-tmux}"
  fi
}

fm_identity_target_of_meta() {
  local remote
  remote=$(fm_identity_meta_value "$1" remote_host)
  if [ -n "$remote" ]; then
    fm_identity_meta_value "$1" remote_target
    return
  fi
  if declare -F fm_backend_target_of_meta >/dev/null 2>&1; then
    fm_backend_target_of_meta "$1"
  else
    local terminal window
    terminal=$(fm_identity_meta_value "$1" terminal)
    window=$(fm_identity_meta_value "$1" window)
    printf '%s' "${terminal:-$window}"
  fi
}

fm_identity_worktree_of_meta() {
  local value
  value=$(fm_identity_meta_value "$1" worktree)
  [ -n "$value" ] || return 1
  fm_identity_canonical_dir "$value" 2>/dev/null || printf '%s' "$value"
}

fm_identity_endpoint_session_of_meta() {
  local meta=$1 backend target remote
  remote=$(fm_identity_meta_value "$meta" remote_host)
  if [ -n "$remote" ]; then
    fm_identity_meta_value "$meta" remote_herdr_session
    return
  fi
  backend=$(fm_identity_backend_of_meta "$meta")
  case "$backend" in
    herdr) fm_identity_meta_value "$meta" herdr_session ;;
    tmux)
      target=$(fm_identity_target_of_meta "$meta")
      case "$target" in *:*) printf '%s' "${target%%:*}" ;; esac
      ;;
    *) return 0 ;;
  esac
}

fm_identity_harness_session_of_meta() {
  local meta=$1 key value found=
  for key in harness_session_id codex_session_id codex_thread_id thread_id session_id; do
    value=$(fm_identity_meta_value "$meta" "$key")
    [ -n "$value" ] || continue
    fm_identity_value_safe "$value" || return 1
    if [ -n "$found" ] && [ "$found" != "$value" ]; then
      fm_identity_error "task metadata carries conflicting harness thread/session identifiers"
      return 1
    fi
    found=$value
  done
  printf '%s' "$found"
}

fm_identity_validate_meta_endpoint_ownership() {  # <meta> <task-id>
  local meta=$1 id=$2 remote binding backend target
  remote=$(fm_identity_meta_value "$meta" remote_host)
  if [ -n "$remote" ]; then
    binding=$(fm_identity_meta_value "$meta" endpoint_task_id)
    backend=$(fm_identity_meta_value "$meta" remote_backend)
    target=$(fm_identity_meta_value "$meta" remote_target)
    [ "$binding" = "$id" ] && [ -n "$backend" ] && [ -n "$target" ] \
      && fm_identity_value_safe "$backend" && fm_identity_value_safe "$target"
    return
  fi
  declare -F fm_backend_validate_task_endpoint >/dev/null 2>&1 || {
    fm_identity_error "shared backend endpoint validation is unavailable for task $id"
    return 1
  }
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1
}

fm_identity_write_task_record() {  # <record> <id> <callsign> <status> <meta|empty> <created> [retired-file]
  local record=$1 id=$2 callsign=$3 status=$4 meta=$5 created=$6 retired_file=${7:-}
  local home worktree='' backend='' endpoint='' endpoint_session='' harness_session='' spawn_gen='' value tmp
  fm_identity_task_id_valid "$id" && fm_identity_validate_name "$callsign" >/dev/null 2>&1 || return 1
  home=$(fm_identity_home_path) || return 1
  if [ -n "$meta" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    fm_identity_validate_meta_endpoint_ownership "$meta" "$id" || return 1
    worktree=$(fm_identity_worktree_of_meta "$meta") || return 1
    backend=$(fm_identity_backend_of_meta "$meta")
    endpoint=$(fm_identity_target_of_meta "$meta")
    endpoint_session=$(fm_identity_endpoint_session_of_meta "$meta")
    harness_session=$(fm_identity_harness_session_of_meta "$meta") || return 1
    spawn_gen=$(fm_identity_meta_value "$meta" spawn_gen)
    fm_identity_value_safe "$worktree" && fm_identity_value_safe "$backend" \
      && fm_identity_value_safe "$endpoint" || return 1
    for value in "$endpoint_session" "$harness_session" "$spawn_gen"; do
      [ -z "$value" ] || fm_identity_value_safe "$value" || return 1
    done
  fi
  tmp=$(mktemp "$FM_IDENTITY_DIR/.$id.identity.XXXXXXXX") || return 1
  {
    printf 'schema=fm-crew-identity.v1\n'
    printf 'home=%s\n' "$home"
    printf 'task_id=%s\n' "$id"
    printf 'callsign=%s\n' "$callsign"
    printf 'status=%s\n' "$status"
    printf 'worktree=%s\n' "$worktree"
    printf 'backend=%s\n' "$backend"
    printf 'endpoint=%s\n' "$endpoint"
    printf 'endpoint_session_id=%s\n' "$endpoint_session"
    printf 'harness_session_id=%s\n' "$harness_session"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'created_at=%s\n' "$created"
    printf 'updated_at=%s\n' "$(fm_identity_now)"
    [ -n "$retired_file" ] && [ -f "$retired_file" ] && cat "$retired_file"
    true
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record"
}

fm_identity_record_core_valid() {  # <record> <id>
  local record=$1 id=$2 schema home task callsign status expected_home
  expected_home=$(fm_identity_home_path) || return 1
  schema=$(fm_identity_record_value "$record" schema 2>/dev/null || true)
  home=$(fm_identity_record_value "$record" home 2>/dev/null || true)
  task=$(fm_identity_record_value "$record" task_id 2>/dev/null || true)
  callsign=$(fm_identity_record_value "$record" callsign 2>/dev/null || true)
  status=$(fm_identity_record_value "$record" status 2>/dev/null || true)
  [ "$schema" = fm-crew-identity.v1 ] && [ "$home" = "$expected_home" ] \
    && [ "$task" = "$id" ] && fm_identity_validate_name "$callsign" >/dev/null 2>&1 \
    && case "$status" in provisioning|active|archived) true ;; *) false ;; esac
}

fm_identity_reserve_fresh_task() {  # <task-id>
  local id=$1 record callsign created status
  fm_identity_task_id_valid "$id" || { fm_identity_error "task id '$id' is invalid for a persistent callsign binding"; return 1; }
  record=$(fm_identity_task_record "$id")
  fm_identity_lock_acquire || return 1
  # Reserve home and task identity under one critical section. This keeps a
  # direct pre-session-start spawn atomic without adding a second lifecycle
  # lock round trip to every ordinary spawn.
  fm_identity_ensure_home_locked >/dev/null || { fm_identity_lock_release; return 1; }
  if [ -e "$record" ] || [ -L "$record" ]; then
    if ! fm_identity_record_core_valid "$record" "$id"; then
      fm_identity_lock_release
      fm_identity_error "identity record for task $id is malformed or unsafe; refusing a fresh assignment"
      return 1
    fi
    status=$(fm_identity_record_value "$record" status)
    callsign=$(fm_identity_record_value "$record" callsign)
    if [ "$status" = provisioning ] && [ ! -e "$FM_IDENTITY_STATE/$id.meta" ]; then
      fm_identity_lock_release
      printf '%s' "$callsign"
      return 0
    fi
    fm_identity_lock_release
    if [ "$status" = archived ]; then
      fm_identity_error "task id '$id' is historical callsign $callsign; use a new task id for a fresh crewmate"
    else
      fm_identity_error "task '$id' already owns callsign $callsign; refusing a second fresh assignment"
    fi
    return 1
  fi
  if fm_identity_human_name_matches_any "$id"; then
    fm_identity_lock_release
    fm_identity_error "task id '$id' collides with an active or historical human name in this Firstmate home"
    return 1
  fi
  callsign=$(fm_identity_choose_fresh_callsign "$id") || { fm_identity_lock_release; return 1; }
  created=$(fm_identity_now)
  fm_identity_write_task_record "$record" "$id" "$callsign" provisioning "" "$created" \
    || { fm_identity_lock_release; return 1; }
  fm_identity_lock_release
  printf '%s' "$callsign"
}

fm_identity_activate_reserved_task_from_meta() {  # <meta> <task-id>
  local meta=$1 id=$2 record callsign status created retired line
  fm_identity_task_id_valid "$id" || return 1
  record=$(fm_identity_task_record "$id") || return 1
  fm_identity_record_core_valid "$record" "$id" || {
    fm_identity_error "reserved identity record for task $id is malformed or unsafe"
    return 1
  }
  status=$(fm_identity_record_value "$record" status)
  callsign=$(fm_identity_record_value "$record" callsign)
  [ "$status" = provisioning ] || {
    fm_identity_error "task $id is not a fresh provisioning; refusing lock-free activation of $callsign"
    return 1
  }
  created=$(fm_identity_record_value "$record" created_at 2>/dev/null || fm_identity_now)
  retired=$(mktemp "${TMPDIR:-/tmp}/fm-identity-retired.XXXXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in retired_callsign=*) printf '%s\n' "$line" ;; esac
  done < "$record" > "$retired"
  if ! fm_identity_write_task_record "$record" "$id" "$callsign" active "$meta" "$created" "$retired"; then
    rm -f "$retired"
    return 1
  fi
  rm -f "$retired"
  printf '%s' "$callsign"
}

fm_identity_ensure_task_from_meta() {  # <meta> <task-id> [legacy|rebind]
  local meta=$1 id=$2 mode=${3:-0} legacy=0 legacy_compat=0 rebinding=0 worktree_reclaim=0
  local record callsign status created retired old_worktree new_worktree target
  case "$mode" in
    1|legacy) legacy=1; legacy_compat=1 ;;
    rebind) legacy=1; rebinding=1 ;;
    reclaim) legacy=1; rebinding=1; worktree_reclaim=1 ;;
  esac
  fm_identity_task_id_valid "$id" || { fm_identity_error "task id '$id' is invalid for a persistent callsign binding"; return 1; }
  record=$(fm_identity_task_record "$id")
  fm_identity_lock_acquire || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    if ! fm_identity_record_core_valid "$record" "$id"; then
      fm_identity_lock_release
      fm_identity_error "identity record for task $id is malformed or belongs to another home; refusing to guess"
      return 1
    fi
    status=$(fm_identity_record_value "$record" status)
    callsign=$(fm_identity_record_value "$record" callsign)
    created=$(fm_identity_record_value "$record" created_at 2>/dev/null || fm_identity_now)
    if [ "$status" = archived ]; then
      if [ "$legacy_compat" -eq 1 ]; then
        fm_identity_lock_release
        printf '%s' "$callsign"
        return 0
      fi
      fm_identity_lock_release
      fm_identity_error "task $id is archived as $callsign; refusing to reactivate a historical identity"
      return 1
    fi
    if [ "$status" = active ]; then
      if [ "$legacy_compat" -eq 1 ]; then
        fm_identity_lock_release
        printf '%s' "$callsign"
        return 0
      fi
      old_worktree=$(fm_identity_record_value "$record" worktree 2>/dev/null || true)
      new_worktree=$(fm_identity_worktree_of_meta "$meta" 2>/dev/null || true)
      if [ -n "$old_worktree" ] && [ "$old_worktree" != "$new_worktree" ] \
        && [ "$worktree_reclaim" -ne 1 ]; then
        fm_identity_lock_release
        fm_identity_error "task $id's callsign $callsign is bound to worktree '$old_worktree', not '$new_worktree'; refusing to rebind it"
        return 1
      fi
      if [ "$rebinding" -ne 1 ]; then
        if ! fm_identity_validate_active_binding "$record" "$meta" "$id"; then
          fm_identity_lock_release
          fm_identity_error "task $id's callsign $callsign conflicts with its recorded endpoint or session identity; only an explicit relaunch/resume continuation may update that binding"
          return 1
        fi
        fm_identity_lock_release
        printf '%s' "$callsign"
        return 0
      fi
    fi
  else
    if fm_identity_human_name_matches_any "$id"; then
      fm_identity_lock_release
      fm_identity_error "task id '$id' collides with an active or historical human name in this Firstmate home"
      return 1
    fi
    if [ "$legacy" = 1 ]; then
      callsign=$(fm_identity_legacy_callsign "$id") || { fm_identity_lock_release; return 1; }
      if fm_identity_name_matches_any "$callsign"; then
        callsign=$(fm_identity_choose_fresh_callsign "$id") || { fm_identity_lock_release; return 1; }
      fi
    else
      callsign=$(fm_identity_choose_fresh_callsign "$id") || { fm_identity_lock_release; return 1; }
    fi
    created=$(fm_identity_now)
  fi
  retired=$(mktemp "${TMPDIR:-/tmp}/fm-identity-retired.XXXXXXXX") || { fm_identity_lock_release; return 1; }
  [ -f "$record" ] && grep '^retired_callsign=' "$record" > "$retired" 2>/dev/null || true
  new_worktree=$(fm_identity_worktree_of_meta "$meta" 2>/dev/null || true)
  target=$(fm_identity_target_of_meta "$meta")
  if [ "$legacy" = 1 ] && { [ -z "$new_worktree" ] || [ -z "$target" ]; }; then
    if ! fm_identity_write_task_record "$record" "$id" "$callsign" provisioning "" "$created" "$retired"; then
      rm -f "$retired"
      fm_identity_lock_release
      fm_identity_error "could not reserve the migration-compatible callsign for incomplete legacy task $id"
      return 1
    fi
    rm -f "$retired"
    fm_identity_lock_release
    printf '%s' "$callsign"
    return 0
  fi
  if ! fm_identity_write_task_record "$record" "$id" "$callsign" active "$meta" "$created" "$retired"; then
    rm -f "$retired"
    fm_identity_lock_release
    fm_identity_error "could not publish the exact identity binding for task $id"
    return 1
  fi
  rm -f "$retired"
  fm_identity_lock_release
  printf '%s' "$callsign"
}

fm_identity_ensure_legacy_archive() {  # <task-id>
  local id=$1 record callsign created
  record=$(fm_identity_task_record "$id")
  fm_identity_lock_acquire || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_identity_record_core_valid "$record" "$id" || {
      fm_identity_lock_release
      fm_identity_error "legacy identity record for task $id is malformed; refusing migration"
      return 1
    }
    callsign=$(fm_identity_record_value "$record" callsign)
    fm_identity_lock_release
    printf '%s' "$callsign"
    return 0
  fi
  callsign=$(fm_identity_legacy_callsign "$id") || { fm_identity_lock_release; return 1; }
  if fm_identity_name_matches_any "$callsign"; then
    callsign=$(fm_identity_choose_fresh_callsign "$id") || { fm_identity_lock_release; return 1; }
  fi
  created=$(fm_identity_now)
  fm_identity_write_task_record "$record" "$id" "$callsign" archived "" "$created" \
    || { fm_identity_lock_release; return 1; }
  fm_identity_lock_release
  printf '%s' "$callsign"
}

fm_identity_archive_task() {  # <meta> <task-id>
  local meta=$1 id=$2 record callsign created retired status
  record=$(fm_identity_task_record "$id")
  [ -f "$record" ] || fm_identity_ensure_task_from_meta "$meta" "$id" 1 >/dev/null || return 1
  fm_identity_lock_acquire || return 1
  fm_identity_record_core_valid "$record" "$id" || {
    fm_identity_lock_release
    fm_identity_error "identity record for task $id is unsafe; retaining task metadata instead of losing name history"
    return 1
  }
  callsign=$(fm_identity_record_value "$record" callsign)
  status=$(fm_identity_record_value "$record" status)
  if [ "$status" = archived ]; then
    fm_identity_lock_release
    printf '%s' "$callsign"
    return 0
  fi
  if [ "$status" = active ] && ! fm_identity_validate_active_binding "$record" "$meta" "$id"; then
    fm_identity_lock_release
    fm_identity_error "task $id's callsign binding conflicts with its cleanup metadata; refusing historical rebinding"
    return 1
  fi
  created=$(fm_identity_record_value "$record" created_at 2>/dev/null || fm_identity_now)
  retired=$(mktemp "${TMPDIR:-/tmp}/fm-identity-retired.XXXXXXXX") || { fm_identity_lock_release; return 1; }
  grep '^retired_callsign=' "$record" > "$retired" 2>/dev/null || true
  fm_identity_write_task_record "$record" "$id" "$callsign" archived "$meta" "$created" "$retired" \
    || { rm -f "$retired"; fm_identity_lock_release; return 1; }
  rm -f "$retired"
  fm_identity_lock_release
  printf '%s' "$callsign"
}

fm_identity_display_callsign() {  # <task-id>
  local id=$1 record callsign
  record=$(fm_identity_task_record "$id")
  if fm_identity_record_core_valid "$record" "$id" 2>/dev/null; then
    callsign=$(fm_identity_record_value "$record" callsign)
    printf '%s' "$callsign"
  else
    fm_identity_legacy_callsign "$id"
  fi
}

fm_identity_validate_active_binding() {  # <record> <meta> <task-id>
  local record=$1 meta=$2 id=$3 status worktree backend endpoint endpoint_session harness_session spawn_gen
  local expected_worktree expected_backend expected_endpoint expected_endpoint_session expected_harness_session expected_spawn_gen
  fm_identity_record_core_valid "$record" "$id" || return 1
  fm_identity_validate_meta_endpoint_ownership "$meta" "$id" || return 1
  status=$(fm_identity_record_value "$record" status)
  [ "$status" = active ] || return 1
  worktree=$(fm_identity_record_value "$record" worktree 2>/dev/null || true)
  backend=$(fm_identity_record_value "$record" backend 2>/dev/null || true)
  endpoint=$(fm_identity_record_value "$record" endpoint 2>/dev/null || true)
  endpoint_session=$(fm_identity_record_value "$record" endpoint_session_id 2>/dev/null || true)
  harness_session=$(fm_identity_record_value "$record" harness_session_id 2>/dev/null || true)
  spawn_gen=$(fm_identity_record_value "$record" spawn_gen 2>/dev/null || true)
  expected_worktree=$(fm_identity_worktree_of_meta "$meta") || return 1
  expected_backend=$(fm_identity_backend_of_meta "$meta")
  expected_endpoint=$(fm_identity_target_of_meta "$meta")
  expected_endpoint_session=$(fm_identity_endpoint_session_of_meta "$meta")
  expected_harness_session=$(fm_identity_harness_session_of_meta "$meta") || return 1
  expected_spawn_gen=$(fm_identity_meta_value "$meta" spawn_gen)
  [ "$worktree" = "$expected_worktree" ] && [ "$backend" = "$expected_backend" ] \
    && [ "$endpoint" = "$expected_endpoint" ] \
    && [ "$endpoint_session" = "$expected_endpoint_session" ] \
    && [ "$harness_session" = "$expected_harness_session" ] \
    && [ "$spawn_gen" = "$expected_spawn_gen" ]
}

fm_identity_selector_conflicts_with_other_record() {  # <selector> <resolved-task-id>
  local raw=$1 resolved_id=$2 wanted record id value
  wanted=$(fm_identity_fold "$raw")
  for record in "$FM_IDENTITY_DIR"/*.identity; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    id=${record##*/}; id=${id%.identity}
    [ "$id" = "$resolved_id" ] && continue
    while IFS= read -r value; do
      [ "$(fm_identity_fold "$value")" = "$wanted" ] && return 0
    done < <(sed -n -e 's/^callsign=//p' -e 's/^retired_callsign=//p' "$record")
  done
  return 1
}

fm_identity_exact_task_record_routes() {  # <record> <meta> <task-id>
  local record=$1 meta=$2 id=$3 status key
  fm_identity_record_core_valid "$record" "$id" || return 1
  status=$(fm_identity_record_value "$record" status) || return 1
  case "$status" in
    active) fm_identity_validate_active_binding "$record" "$meta" "$id" ;;
    provisioning)
      # Legacy metadata may not yet carry a worktree or endpoint. Its reserved
      # fallback callsign is deliberately not routable, but an exact task-id
      # selector remains deterministic and keeps the pre-feature data-plane
      # compatibility. Only the canonical empty provisioning shape qualifies.
      for key in worktree backend endpoint endpoint_session_id harness_session_id spawn_gen; do
        [ "$(grep -c "^$key=$" "$record" 2>/dev/null || true)" -eq 1 ] || return 1
      done
      ;;
    *) return 1 ;;
  esac
}

fm_identity_resolve_selector() {  # <state-dir> <task-id-or-callsign>
  local state=$1 raw=$2 id record callsign status current_count=0 retired_count=0 match_id='' match_record=''
  if ! fm_identity_task_id_valid "$raw"; then
    fm_identity_error "selector '$raw' is unsafe; use a callsign or exact task id from this Firstmate home"
    return 2
  fi
  id=$raw
  if [ -f "$state/$id.meta" ]; then
    if fm_identity_selector_conflicts_with_other_record "$raw" "$id"; then
      fm_identity_error "selector '$raw' conflicts with another task's current or historical callsign; refusing to guess"
      return 2
    fi
    record=$(fm_identity_task_record "$id")
    # Exact task ids are the pre-callsign compatibility route. A stale or
    # archived callsign record must not shadow the canonical live metadata;
    # callsign selectors below still require a fully exact active binding.
    printf '%s' "$id"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      if [ -f "$state/$id.meta" ]; then
        if fm_identity_selector_conflicts_with_other_record "$raw" "$id"; then
          fm_identity_error "selector '$raw' conflicts with another task's current or historical callsign; refusing to guess"
          return 2
        fi
        record=$(fm_identity_task_record "$id")
        printf '%s' "$id"
        return 0
      fi
      ;;
  esac
  for record in "$FM_IDENTITY_DIR"/*.identity; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    id=${record##*/}; id=${id%.identity}
    if ! fm_identity_record_core_valid "$record" "$id"; then
      if grep -qi "^callsign=$raw$\|^retired_callsign=$raw$" "$record" 2>/dev/null; then
        fm_identity_error "callsign '$raw' matches a malformed identity record; refusing to guess"
        return 2
      fi
      continue
    fi
    callsign=$(fm_identity_record_value "$record" callsign)
    if [ "$(fm_identity_fold "$callsign")" = "$(fm_identity_fold "$raw")" ]; then
      current_count=$((current_count + 1)); match_id=$id; match_record=$record
    fi
    while IFS= read -r callsign; do
      if [ "$(fm_identity_fold "$callsign")" = "$(fm_identity_fold "$raw")" ]; then
        retired_count=$((retired_count + 1))
      fi
    done < <(sed -n 's/^retired_callsign=//p' "$record")
  done
  if [ "$current_count" -gt 1 ]; then
    fm_identity_error "callsign '$raw' is ambiguous across $current_count identity records; refusing to guess"
    return 2
  fi
  if [ "$current_count" -eq 1 ] && [ "$retired_count" -gt 0 ]; then
    fm_identity_error "callsign '$raw' conflicts with historical name history; refusing to rebind or guess"
    return 2
  fi
  if [ "$current_count" -eq 0 ]; then
    if [ "$retired_count" -gt 0 ]; then
      fm_identity_error "callsign '$raw' is historical after a rename and cannot be rebound or routed"
      return 5
    else
      fm_identity_error "no callsign or task '$raw' exists in this Firstmate home"
      return 3
    fi
  fi
  status=$(fm_identity_record_value "$match_record" status)
  if [ "$status" = archived ] || [ ! -f "$state/$match_id.meta" ]; then
    fm_identity_error "callsign '$raw' is archived-only for task $match_id; no live task can be routed"
    return 4
  fi
  if [ "$status" != active ] || ! fm_identity_validate_active_binding "$match_record" "$state/$match_id.meta" "$match_id"; then
    fm_identity_error "callsign '$raw' has conflicting or unsafe active identity; refusing to route"
    return 2
  fi
  printf '%s' "$match_id"
}

fm_identity_rename_task() {  # <state-dir> <selector> <new-callsign>
  local state=$1 selector=$2 new=$3 id record old created retired meta
  fm_identity_validate_name "$new" || return 1
  id=$(fm_identity_resolve_selector "$state" "$selector") || return 1
  meta="$state/$id.meta"
  record=$(fm_identity_task_record "$id")
  if [ ! -f "$record" ]; then
    fm_identity_ensure_task_from_meta "$meta" "$id" legacy >/dev/null || {
      fm_identity_error "legacy task $id could not receive a persistent callsign before rename"
      return 1
    }
  fi
  fm_identity_lock_acquire || return 1
  fm_identity_validate_active_binding "$record" "$meta" "$id" || {
    fm_identity_lock_release
    fm_identity_error "task $id changed while its rename was being prepared; retry after reconciling it"
    return 1
  }
  old=$(fm_identity_record_value "$record" callsign)
  if [ "$old" = "$new" ]; then
    fm_identity_lock_release
    printf '%s\t%s' "$old" "$id"
    return 0
  fi
  if [ "$(fm_identity_fold "$old")" = "$(fm_identity_fold "$new")" ]; then
    created=$(fm_identity_record_value "$record" created_at 2>/dev/null || fm_identity_now)
    retired=$(mktemp "${TMPDIR:-/tmp}/fm-identity-retired.XXXXXXXX") || { fm_identity_lock_release; return 1; }
    grep '^retired_callsign=' "$record" > "$retired" 2>/dev/null || true
    fm_identity_write_task_record "$record" "$id" "$new" active "$meta" "$created" "$retired" \
      || { rm -f "$retired"; fm_identity_lock_release; return 1; }
    rm -f "$retired"
    fm_identity_lock_release
    printf '%s\t%s' "$new" "$id"
    return 0
  fi
  if fm_identity_name_matches_any "$new"; then
    fm_identity_lock_release
    fm_identity_error "callsign '$new' is already active, historical, or reserved by this home's Firstmate identity"
    return 1
  fi
  created=$(fm_identity_record_value "$record" created_at 2>/dev/null || fm_identity_now)
  retired=$(mktemp "${TMPDIR:-/tmp}/fm-identity-retired.XXXXXXXX") || { fm_identity_lock_release; return 1; }
  grep '^retired_callsign=' "$record" > "$retired" 2>/dev/null || true
  printf 'retired_callsign=%s\n' "$old" >> "$retired"
  fm_identity_write_task_record "$record" "$id" "$new" active "$meta" "$created" "$retired" \
    || { rm -f "$retired"; fm_identity_lock_release; return 1; }
  rm -f "$retired"
  fm_identity_lock_release
  printf '%s\t%s' "$new" "$id"
}

fm_identity_rename_home() {  # <new-name>
  local new=$1 old created previous
  fm_identity_validate_name "$new" || return 1
  fm_identity_ensure_home >/dev/null || return 1
  fm_identity_lock_acquire || return 1
  old=$(fm_identity_record_value "$FM_IDENTITY_HOME_RECORD" name) || { fm_identity_lock_release; return 1; }
  if [ "$(fm_identity_fold "$old")" = "$(fm_identity_fold "$new")" ]; then
    fm_identity_lock_release
    printf '%s' "$new"
    return 0
  fi
  if fm_identity_name_matches_any "$new"; then
    fm_identity_lock_release
    fm_identity_error "name '$new' is already active or historical in this Firstmate home"
    return 1
  fi
  created=$(fm_identity_record_value "$FM_IDENTITY_HOME_RECORD" created_at 2>/dev/null || fm_identity_now)
  previous=$(mktemp "${TMPDIR:-/tmp}/fm-identity-previous.XXXXXXXX") || { fm_identity_lock_release; return 1; }
  grep '^previous_name=' "$FM_IDENTITY_HOME_RECORD" > "$previous" 2>/dev/null || true
  printf 'previous_name=%s\n' "$old" >> "$previous"
  fm_identity_write_home_record "$new" "$created" "$previous" \
    || { rm -f "$previous"; fm_identity_lock_release; return 1; }
  rm -f "$previous"
  fm_identity_lock_release
  printf '%s' "$new"
}

fm_identity_migrate_home() {
  local meta id status
  fm_identity_ensure_home >/dev/null || return 1
  for meta in "$FM_IDENTITY_STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_identity_ensure_task_from_meta "$meta" "$id" 1 >/dev/null || return 1
  done
  for status in "$FM_IDENTITY_STATE"/*.status; do
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    id=${status##*/}; id=${id%.status}
    [ -f "$FM_IDENTITY_STATE/$id.meta" ] && continue
    fm_identity_ensure_legacy_archive "$id" >/dev/null || return 1
  done
}

fm_identity_history() {
  local record id callsign status
  for record in "$FM_IDENTITY_DIR"/*.identity; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    id=${record##*/}; id=${id%.identity}
    fm_identity_record_core_valid "$record" "$id" || {
      printf 'UNSAFE\t%s\t%s\n' "$id" "$record"
      continue
    }
    callsign=$(fm_identity_record_value "$record" callsign)
    status=$(fm_identity_record_value "$record" status)
    printf '%s\t%s\t%s\n' "$callsign" "$id" "$status"
  done | LC_ALL=C sort -f
}
