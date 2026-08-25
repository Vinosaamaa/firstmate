#!/usr/bin/env bash
# Register and resolve private external workspace pointers.
#
# A workspace is an organizational directory that may be non-Git and may be
# empty apart from its explicitly registered member repositories. Registration
# writes only one private pointer record under data/workspaces/. It never copies,
# moves, clones, initializes, edits, or deletes the external root, an instruction
# file, or a member repository.
#
# Usage:
#   fm-workspace.sh add <workspace-id> --root <absolute-directory> --scope <text>
#       [--instruction-root <absolute-directory>]...
#       [--member <member-id>=<absolute-git-root>]...
#       [--external-member <member-id>=<absolute-git-root>]...
#   fm-workspace.sh register ...                         # alias for add
#   fm-workspace.sh list
#   fm-workspace.sh show <workspace-id>
#   fm-workspace.sh resolve <workspace-id> <member-id> [--path|--context]
#   fm-workspace.sh copy <workspace-id> --to-home <absolute-firstmate-home> [--check-only]
#   fm-workspace.sh remove <workspace-id> --confirm <workspace-id>
#   fm-workspace.sh unregister ...                       # alias for remove
#
# `--member` requires the canonical Git root to be the workspace root or a
# descendant of it. `--external-member` is the explicit declaration for a Git
# root outside the workspace root and is refused for a contained path. Member
# identities are unique within a workspace; canonical member paths are unique
# across the whole registry so one repository never has two routing owners.
#
# Each `--instruction-root` is an existing canonical directory at or below the
# workspace root, outside every member Git root, with one real AGENTS.md file.
# Roots retain command-line order. The manifest commits the file's SHA-256, and
# every list, show, resolve, or context operation revalidates that hash. A
# changed, missing, symlinked, or relocated instruction file therefore stops
# routing until the workspace is deliberately re-registered. No instruction
# roots is valid and produces an explicit empty outer-context block.
#
# Record format (data/workspaces/<workspace-id>.workspace), one tab-separated
# record per physical line, in this exact order:
#   firstmate-workspace<TAB>1
#   id<TAB><workspace-id>
#   root<TAB><canonical-absolute-directory>
#   scope<TAB><single-line-routing-scope>
#   instruction<TAB><canonical-absolute-directory><TAB><AGENTS.md-sha256>  # zero or more, ordered
#   member<TAB><member-id><TAB><contained|external><TAB><canonical-absolute-git-root>  # one or more
#
# Tabs and newlines are forbidden in every stored value. Records are regular
# non-symlink files named from a validated stable id and published atomically
# with mode 0600. Every read validates the complete registry so malformed,
# duplicate, or drifting records cannot be selected around. Removal is the one
# recovery exception: after an exact repeated-id confirmation it validates only
# the record envelope and removes only that private file, so a drifted external
# path can always be safely unregistered without touching the external tree.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/workspaces"
LOCK="$DATA/.workspaces.lock"
LOCK_HELD=0
TMP_RECORD=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  [ -z "$TMP_RECORD" ] || rm -f -- "$TMP_RECORD" 2>/dev/null || true
  if [ "$LOCK_HELD" -eq 1 ]; then
    LOCK_HELD=0
    rmdir -- "$LOCK" 2>/dev/null || true
  fi
  return "$status"
}
trap cleanup EXIT

valid_id() {
  case "$1" in
    ''|*[!a-z0-9._-]*|[!a-z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

valid_value() {
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$1" ]
}

require_absolute() {
  case "$2" in
    /*) ;;
    *) die "$1 must be an absolute path: $2" ;;
  esac
}

canonical_directory() {
  [ -d "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

canonical_path_for_check() {
  local path=$1 probe tail prefix parent base normalize_path
  case "$path" in
    /*) probe=$path ;;
    *) probe="$(pwd -P)/$path" ;;
  esac
  while [ "$probe" != "/" ] && [ "${probe%/}" != "$probe" ]; do
    probe=${probe%/}
  done
  if [ -e "$probe" ]; then
    if [ -d "$probe" ]; then
      CDPATH='' cd -- "$probe" 2>/dev/null && pwd -P
    else
      parent=$(dirname "$probe")
      base=$(basename "$probe")
      CDPATH='' cd -- "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base"
    fi
    return
  fi
  tail=
  while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
    tail="$(basename "$probe")${tail:+/$tail}"
    probe=$(dirname "$probe")
  done
  if [ -d "$probe" ]; then
    prefix=$(canonical_directory "$probe")
  elif [ -e "$probe" ]; then
    parent=$(dirname "$probe")
    base=$(basename "$probe")
    prefix=$(CDPATH='' cd -- "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
  else
    prefix=/
  fi
  normalize_path="$prefix"
  while [ -n "$tail" ]; do
    base=${tail%%/*}
    if [ "$tail" = "$base" ]; then
      tail=
    else
      tail=${tail#*/}
    fi
    case "$base" in
      ''|.) ;;
      ..)
        if [ "$normalize_path" != "/" ]; then
          normalize_path=${normalize_path%/*}
          [ -n "$normalize_path" ] || normalize_path=/
        fi
        ;;
      *)
        if [ "$normalize_path" = "/" ]; then
          normalize_path="/$base"
        else
          normalize_path="$normalize_path/$base"
        fi
        ;;
    esac
  done
  printf '%s\n' "$normalize_path"
}

path_is_within_or_equal() {
  [ "$1" = "$2" ] && return 0
  case "$2" in
    "$1"/*) return 0 ;;
  esac
  return 1
}

git_root_is_exact() {
  local path=$1 inside top top_real
  inside=$(git -C "$path" rev-parse --is-inside-work-tree 2>/dev/null || true)
  [ "$inside" = true ] || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(canonical_directory "$top") || return 1
  [ "$top_real" = "$path" ]
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

acquire_registry_lock() {
  if [ -L "$DATA" ]; then
    die "data directory must not be a symlink: $DATA"
  fi
  (umask 077; mkdir -p "$DATA") || die "cannot create private data directory: $DATA"
  [ -d "$DATA" ] || die "private data path is not a directory: $DATA"
  if ! mkdir -- "$LOCK" 2>/dev/null; then
    die "external workspace registry is locked by another operation: $LOCK"
  fi
  LOCK_HELD=1
}

ensure_registry_for_write() {
  if [ -L "$REGISTRY" ]; then
    die "external workspace registry must not be a symlink: $REGISTRY"
  fi
  (umask 077; mkdir -p "$REGISTRY") || die "cannot create external workspace registry: $REGISTRY"
  [ -d "$REGISTRY" ] || die "external workspace registry is not a directory: $REGISTRY"
}

registry_is_readable() {
  if [ ! -e "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
    return 1
  fi
  [ ! -L "$REGISTRY" ] || die "external workspace registry must not be a symlink: $REGISTRY"
  [ -d "$REGISTRY" ] || die "external workspace registry is not a directory: $REGISTRY"
  return 0
}

REC_ID=
REC_ROOT=
REC_SCOPE=
REC_INSTRUCTION_PATHS=()
REC_INSTRUCTION_HASHES=()
REC_MEMBER_IDS=()
REC_MEMBER_RELATIONS=()
REC_MEMBER_PATHS=()

record_error() {
  local file=$1 message=$2
  echo "error: invalid external workspace record '$file': $message" >&2
  return 1
}

load_record() {
  local file=$1 line=0 kind a b c extra phase=header expected_name
  local canonical actual_hash idx other_idx
  REC_ID=
  REC_ROOT=
  REC_SCOPE=
  REC_INSTRUCTION_PATHS=()
  REC_INSTRUCTION_HASHES=()
  REC_MEMBER_IDS=()
  REC_MEMBER_RELATIONS=()
  REC_MEMBER_PATHS=()

  [ -f "$file" ] && [ ! -L "$file" ] || record_error "$file" "record must be a regular non-symlink file" || return 1
  # record_error only reports diagnostics; it never writes the record being read.
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r kind a b c extra || [ -n "${kind}${a}${b}${c}${extra}" ]; do
    line=$((line + 1))
    [ -z "$extra" ] || record_error "$file" "line $line has too many fields" || return 1
    case "$phase:$kind" in
      header:firstmate-workspace)
        [ "$a" = 1 ] && [ -z "$b" ] && [ -z "$c" ] \
          || record_error "$file" "line 1 must be the version-1 header" || return 1
        phase=id
        ;;
      id:id)
        [ -z "$b" ] && [ -z "$c" ] && valid_id "$a" \
          || record_error "$file" "line 2 has an invalid workspace id" || return 1
        REC_ID=$a
        phase=root
        ;;
      root:root)
        [ -z "$b" ] && [ -z "$c" ] && valid_value "$a" \
          || record_error "$file" "line 3 has an invalid root" || return 1
        REC_ROOT=$a
        phase=scope
        ;;
      scope:scope)
        [ -z "$b" ] && [ -z "$c" ] && valid_value "$a" \
          || record_error "$file" "line 4 has an invalid scope" || return 1
        REC_SCOPE=$a
        phase=instructions
        ;;
      instructions:instruction)
        [ -n "$a" ] && [ -n "$b" ] && [ -z "$c" ] \
          || record_error "$file" "line $line has an invalid instruction record" || return 1
        REC_INSTRUCTION_PATHS+=("$a")
        REC_INSTRUCTION_HASHES+=("$b")
        ;;
      instructions:member|members:member)
        [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] \
          || record_error "$file" "line $line has an invalid member record" || return 1
        REC_MEMBER_IDS+=("$a")
        REC_MEMBER_RELATIONS+=("$b")
        REC_MEMBER_PATHS+=("$c")
        phase=members
        ;;
      *)
        record_error "$file" "unexpected '$kind' record on line $line" || return 1
        ;;
    esac
  done < "$file"

  [ "$phase" = members ] || record_error "$file" "record is incomplete or has no member repositories" || return 1
  expected_name="$REC_ID.workspace"
  [ "$(basename "$file")" = "$expected_name" ] \
    || record_error "$file" "filename does not match workspace id '$REC_ID'" || return 1
  require_absolute "stored workspace root" "$REC_ROOT"
  canonical=$(canonical_directory "$REC_ROOT") \
    || record_error "$file" "workspace root is missing or not a directory: $REC_ROOT" || return 1
  [ "$canonical" = "$REC_ROOT" ] \
    || record_error "$file" "workspace root drifted from canonical path '$REC_ROOT' to '$canonical'" || return 1

  idx=0
  while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
    valid_id "${REC_MEMBER_IDS[$idx]}" \
      || record_error "$file" "invalid member id '${REC_MEMBER_IDS[$idx]}'" || return 1
    case "${REC_MEMBER_RELATIONS[$idx]}" in
      contained)
        path_is_within_or_equal "$REC_ROOT" "${REC_MEMBER_PATHS[$idx]}" \
          || record_error "$file" "contained member '${REC_MEMBER_IDS[$idx]}' is outside workspace root" || return 1
        ;;
      external)
        ! path_is_within_or_equal "$REC_ROOT" "${REC_MEMBER_PATHS[$idx]}" \
          || record_error "$file" "external member '${REC_MEMBER_IDS[$idx]}' is inside workspace root" || return 1
        ;;
      *) record_error "$file" "member '${REC_MEMBER_IDS[$idx]}' has invalid relation '${REC_MEMBER_RELATIONS[$idx]}'" || return 1 ;;
    esac
    require_absolute "stored member path" "${REC_MEMBER_PATHS[$idx]}"
    canonical=$(canonical_directory "${REC_MEMBER_PATHS[$idx]}") \
      || record_error "$file" "member '${REC_MEMBER_IDS[$idx]}' path is missing or not a directory" || return 1
    [ "$canonical" = "${REC_MEMBER_PATHS[$idx]}" ] \
      || record_error "$file" "member '${REC_MEMBER_IDS[$idx]}' path drifted to '$canonical'" || return 1
    git_root_is_exact "$canonical" \
      || record_error "$file" "member '${REC_MEMBER_IDS[$idx]}' is not an explicit Git worktree root: $canonical" || return 1
    other_idx=$((idx + 1))
    while [ "$other_idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
      [ "${REC_MEMBER_IDS[$idx]}" != "${REC_MEMBER_IDS[$other_idx]}" ] \
        || record_error "$file" "duplicate member id '${REC_MEMBER_IDS[$idx]}'" || return 1
      [ "${REC_MEMBER_PATHS[$idx]}" != "${REC_MEMBER_PATHS[$other_idx]}" ] \
        || record_error "$file" "duplicate member path '${REC_MEMBER_PATHS[$idx]}'" || return 1
      other_idx=$((other_idx + 1))
    done
    idx=$((idx + 1))
  done

  idx=0
  while [ "$idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
    require_absolute "stored instruction root" "${REC_INSTRUCTION_PATHS[$idx]}"
    canonical=$(canonical_directory "${REC_INSTRUCTION_PATHS[$idx]}") \
      || record_error "$file" "instruction root is missing or not a directory: ${REC_INSTRUCTION_PATHS[$idx]}" || return 1
    [ "$canonical" = "${REC_INSTRUCTION_PATHS[$idx]}" ] \
      || record_error "$file" "instruction root drifted to '$canonical'" || return 1
    path_is_within_or_equal "$REC_ROOT" "$canonical" \
      || record_error "$file" "instruction root is outside workspace root: $canonical" || return 1
    other_idx=0
    while [ "$other_idx" -lt "${#REC_MEMBER_PATHS[@]}" ]; do
      ! path_is_within_or_equal "${REC_MEMBER_PATHS[$other_idx]}" "$canonical" \
        || record_error "$file" "instruction root is inside member '${REC_MEMBER_IDS[$other_idx]}'" || return 1
      other_idx=$((other_idx + 1))
    done
    [ -f "$canonical/AGENTS.md" ] && [ ! -L "$canonical/AGENTS.md" ] \
      || record_error "$file" "instruction root has no real AGENTS.md: $canonical" || return 1
    case "${REC_INSTRUCTION_HASHES[$idx]}" in
      *[!0-9a-f]*|'') record_error "$file" "instruction hash is not lowercase SHA-256" || return 1 ;;
    esac
    [ "${#REC_INSTRUCTION_HASHES[$idx]}" -eq 64 ] \
      || record_error "$file" "instruction hash is not 64 hexadecimal characters" || return 1
    actual_hash=$(sha256_file "$canonical/AGENTS.md") \
      || record_error "$file" "cannot hash instruction file: $canonical/AGENTS.md" || return 1
    [ "$actual_hash" = "${REC_INSTRUCTION_HASHES[$idx]}" ] \
      || record_error "$file" "instruction content drifted: $canonical/AGENTS.md" || return 1
    other_idx=$((idx + 1))
    while [ "$other_idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
      [ "$canonical" != "${REC_INSTRUCTION_PATHS[$other_idx]}" ] \
        || record_error "$file" "duplicate instruction root '$canonical'" || return 1
      other_idx=$((other_idx + 1))
    done
    idx=$((idx + 1))
  done
}

registry_files() {
  registry_is_readable || return 0
  find "$REGISTRY" -mindepth 1 -maxdepth 1 -name '*.workspace' -print | LC_ALL=C sort
}

validate_registry() {
  local file idx unexpected seen_ids=() seen_roots=() seen_member_paths=() seen_member_owners=()
  if registry_is_readable; then
    unexpected=$(find "$REGISTRY" -mindepth 1 -maxdepth 1 ! -name '*.workspace' -print | LC_ALL=C sort | head -n 1)
    [ -z "$unexpected" ] || {
      echo "error: invalid external workspace registry entry: $unexpected" >&2
      return 1
    }
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    load_record "$file" || return 1
    idx=0
    while [ "$idx" -lt "${#seen_ids[@]}" ]; do
      [ "$REC_ID" != "${seen_ids[$idx]}" ] \
        || record_error "$file" "duplicate workspace id '$REC_ID'" || return 1
      [ "$REC_ROOT" != "${seen_roots[$idx]}" ] \
        || record_error "$file" "workspace root is already registered by '${seen_ids[$idx]}'" || return 1
      idx=$((idx + 1))
    done
    seen_ids+=("$REC_ID")
    seen_roots+=("$REC_ROOT")
    idx=0
    while [ "$idx" -lt "${#REC_MEMBER_PATHS[@]}" ]; do
      local seen_idx=0
      while [ "$seen_idx" -lt "${#seen_member_paths[@]}" ]; do
        [ "${REC_MEMBER_PATHS[$idx]}" != "${seen_member_paths[$seen_idx]}" ] \
          || record_error "$file" "member path '${REC_MEMBER_PATHS[$idx]}' is already owned by '${seen_member_owners[$seen_idx]}'" || return 1
        seen_idx=$((seen_idx + 1))
      done
      seen_member_paths+=("${REC_MEMBER_PATHS[$idx]}")
      seen_member_owners+=("$REC_ID/${REC_MEMBER_IDS[$idx]}")
      idx=$((idx + 1))
    done
  done <<EOF
$(registry_files)
EOF
}

record_path() {
  printf '%s/%s.workspace\n' "$REGISTRY" "$1"
}

load_named_record() {
  local id=$1 path
  valid_id "$id" || die "invalid workspace id: $id"
  path=$(record_path "$id")
  [ -e "$path" ] || die "external workspace is not registered: $id"
  load_record "$path"
}

find_member_index() {
  local id=$1 idx=0
  valid_id "$id" || return 1
  while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
    if [ "${REC_MEMBER_IDS[$idx]}" = "$id" ]; then
      printf '%s\n' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

print_show() {
  local idx=0
  printf 'workspace: %s\n' "$REC_ID"
  printf 'scope: %s\n' "$REC_SCOPE"
  printf 'root: %s\n' "$REC_ROOT"
  if [ "${#REC_INSTRUCTION_PATHS[@]}" -eq 0 ]; then
    printf 'instruction-roots: none\n'
  else
    printf 'instruction-roots:\n'
    while [ "$idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
      printf -- '- %s (sha256:%s)\n' "${REC_INSTRUCTION_PATHS[$idx]}" "${REC_INSTRUCTION_HASHES[$idx]}"
      idx=$((idx + 1))
    done
  fi
  printf 'members:\n'
  idx=0
  while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
    printf -- '- %s [%s] %s\n' "${REC_MEMBER_IDS[$idx]}" "${REC_MEMBER_RELATIONS[$idx]}" "${REC_MEMBER_PATHS[$idx]}"
    idx=$((idx + 1))
  done
}

print_context() {
  local member_idx=$1 idx=0 instruction_file
  printf '# Registered workspace route\n\n'
  # Backticks are intentional Markdown delimiters in this generated context.
  # shellcheck disable=SC2016
  printf 'Workspace ID: `%s`\n' "$REC_ID"
  printf 'Workspace scope: %s\n' "$REC_SCOPE"
  # shellcheck disable=SC2016
  printf 'External root pointer: `%s`\n' "$REC_ROOT"
  # shellcheck disable=SC2016
  printf 'Selected member repository: `%s`\n' "${REC_MEMBER_IDS[$member_idx]}"
  # shellcheck disable=SC2016
  printf 'Member Git root: `%s`\n\n' "${REC_MEMBER_PATHS[$member_idx]}"
  printf 'The external root is an organizational pointer, not a task worktree.\n'
  printf 'Do not copy, move, initialize, flatten, or mutate it or any member primary checkout.\n'
  printf 'Implementation work uses the ordinary isolated worktree lifecycle for the selected member repository.\n'
  printf 'Cross-repository work must be split into separately linked member tasks.\n\n'
  printf '## Outer instruction context\n\n'
  printf 'Apply registered outer instructions in the listed order as broader workspace context.\n'
  if [ "${#REC_INSTRUCTION_PATHS[@]}" -eq 0 ]; then
    printf 'No outer instruction roots are registered.\n\n'
  else
    while [ "$idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
      instruction_file="${REC_INSTRUCTION_PATHS[$idx]}/AGENTS.md"
      printf '### Outer instruction %s\n\n' "$((idx + 1))"
      # shellcheck disable=SC2016
      printf 'Source: `%s`\n' "$instruction_file"
      # shellcheck disable=SC2016
      printf 'Committed SHA-256: `%s`\n\n' "${REC_INSTRUCTION_HASHES[$idx]}"
      cat "$instruction_file"
      printf '\n'
      idx=$((idx + 1))
    done
  fi
  # Keep the repository-authority boundary after all broader context so an
  # outer file cannot appear to supersede the selected repository's contract.
  # shellcheck disable=SC2016
  printf 'The selected member repository and its nested `AGENTS.md` files remain authoritative on conflict.\n'
}

command_add() {
  local id=${1:-} root='' scope='' want='' arg spec member_id member_path relation
  local root_real idx other_idx instruction_real instruction_hash member_real target
  local instruction_inputs=() member_specs=() member_relations=()
  [ -n "$id" ] || die "add requires a workspace id"
  valid_id "$id" || die "invalid workspace id: $id"
  shift || true
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --root|--scope|--instruction-root|--member|--external-member)
        [ "$#" -gt 0 ] || die "$arg requires a value"
        want=$1
        shift
        ;;
      --root=*|--scope=*|--instruction-root=*|--member=*|--external-member=*)
        want=${arg#*=}
        ;;
      *) die "unknown add option: $arg" ;;
    esac
    case "$arg" in
      --root|--root=*) [ -z "$root" ] || die "--root may be supplied only once"; root=$want ;;
      --scope|--scope=*) [ -z "$scope" ] || die "--scope may be supplied only once"; scope=$want ;;
      --instruction-root|--instruction-root=*) instruction_inputs+=("$want") ;;
      --member|--member=*) member_specs+=("$want"); member_relations+=(contained) ;;
      --external-member|--external-member=*) member_specs+=("$want"); member_relations+=(external) ;;
    esac
  done
  [ -n "$root" ] || die "add requires --root"
  [ -n "$scope" ] || die "add requires --scope"
  valid_value "$scope" || die "scope must be one non-empty line without tabs"
  [ "${#member_specs[@]}" -gt 0 ] || die "add requires at least one --member or --external-member"
  require_absolute "workspace root" "$root"
  root_real=$(canonical_directory "$root") || die "workspace root must be an existing directory: $root"

  REC_ID=$id
  REC_ROOT=$root_real
  REC_SCOPE=$scope
  REC_INSTRUCTION_PATHS=()
  REC_INSTRUCTION_HASHES=()
  REC_MEMBER_IDS=()
  REC_MEMBER_RELATIONS=()
  REC_MEMBER_PATHS=()

  idx=0
  while [ "$idx" -lt "${#member_specs[@]}" ]; do
    spec=${member_specs[$idx]}
    case "$spec" in
      *=*) member_id=${spec%%=*}; member_path=${spec#*=} ;;
      *) die "member must use <member-id>=<absolute-git-root>: $spec" ;;
    esac
    valid_id "$member_id" || die "invalid member id: $member_id"
    valid_value "$member_path" || die "member path must be one non-empty line without tabs"
    require_absolute "member path" "$member_path"
    member_real=$(canonical_directory "$member_path") || die "member path must be an existing directory: $member_path"
    git_root_is_exact "$member_real" || die "member '$member_id' must name an explicit Git worktree root: $member_real"
    relation=${member_relations[$idx]}
    if [ "$relation" = contained ]; then
      path_is_within_or_equal "$root_real" "$member_real" \
        || die "member '$member_id' is outside workspace root; use --external-member to declare it explicitly"
    else
      ! path_is_within_or_equal "$root_real" "$member_real" \
        || die "member '$member_id' is contained by the workspace root; use --member instead of --external-member"
    fi
    other_idx=0
    while [ "$other_idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
      [ "$member_id" != "${REC_MEMBER_IDS[$other_idx]}" ] || die "duplicate member id: $member_id"
      [ "$member_real" != "${REC_MEMBER_PATHS[$other_idx]}" ] || die "duplicate member path: $member_real"
      other_idx=$((other_idx + 1))
    done
    REC_MEMBER_IDS+=("$member_id")
    REC_MEMBER_RELATIONS+=("$relation")
    REC_MEMBER_PATHS+=("$member_real")
    idx=$((idx + 1))
  done

  idx=0
  while [ "$idx" -lt "${#instruction_inputs[@]}" ]; do
    require_absolute "instruction root" "${instruction_inputs[$idx]}"
    instruction_real=$(canonical_directory "${instruction_inputs[$idx]}") \
      || die "instruction root must be an existing directory: ${instruction_inputs[$idx]}"
    path_is_within_or_equal "$root_real" "$instruction_real" \
      || die "instruction root must be contained by workspace root: $instruction_real"
    other_idx=0
    while [ "$other_idx" -lt "${#REC_MEMBER_PATHS[@]}" ]; do
      ! path_is_within_or_equal "${REC_MEMBER_PATHS[$other_idx]}" "$instruction_real" \
        || die "instruction root must be outside member repository '${REC_MEMBER_IDS[$other_idx]}': $instruction_real"
      other_idx=$((other_idx + 1))
    done
    [ -f "$instruction_real/AGENTS.md" ] && [ ! -L "$instruction_real/AGENTS.md" ] \
      || die "instruction root must contain a real AGENTS.md file: $instruction_real"
    other_idx=0
    while [ "$other_idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
      [ "$instruction_real" != "${REC_INSTRUCTION_PATHS[$other_idx]}" ] \
        || die "duplicate instruction root: $instruction_real"
      other_idx=$((other_idx + 1))
    done
    instruction_hash=$(sha256_file "$instruction_real/AGENTS.md") \
      || die "shasum or sha256sum is required to commit instruction context"
    REC_INSTRUCTION_PATHS+=("$instruction_real")
    REC_INSTRUCTION_HASHES+=("$instruction_hash")
    idx=$((idx + 1))
  done

  acquire_registry_lock
  ensure_registry_for_write
  validate_registry || exit 1
  target=$(record_path "$id")
  [ ! -e "$target" ] && [ ! -L "$target" ] || die "external workspace is already registered: $id"
  # Check cross-record ownership before publication. validate_registry already
  # proved every existing record safe, so these reads cannot select around drift.
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    load_record "$target" || exit 1
    [ "$REC_ROOT" != "$root_real" ] || die "workspace root is already registered by '$REC_ID': $root_real"
    idx=0
    while [ "$idx" -lt "${#REC_MEMBER_PATHS[@]}" ]; do
      other_idx=0
      while [ "$other_idx" -lt "${#member_specs[@]}" ]; do
        spec=${member_specs[$other_idx]}
        member_path=${spec#*=}
        member_real=$(canonical_directory "$member_path") || die "member path drifted during registration: $member_path"
        [ "${REC_MEMBER_PATHS[$idx]}" != "$member_real" ] \
          || die "member path is already registered by '$REC_ID/${REC_MEMBER_IDS[$idx]}': $member_real"
        other_idx=$((other_idx + 1))
      done
      idx=$((idx + 1))
    done
  done <<EOF
$(registry_files)
EOF

  # Restore the new record values after inspecting existing records above.
  REC_ID=$id
  REC_ROOT=$root_real
  REC_SCOPE=$scope
  REC_INSTRUCTION_PATHS=()
  REC_INSTRUCTION_HASHES=()
  idx=0
  while [ "$idx" -lt "${#instruction_inputs[@]}" ]; do
    instruction_real=$(canonical_directory "${instruction_inputs[$idx]}") || die "instruction root drifted during registration"
    instruction_hash=$(sha256_file "$instruction_real/AGENTS.md") || die "cannot hash instruction file"
    REC_INSTRUCTION_PATHS+=("$instruction_real")
    REC_INSTRUCTION_HASHES+=("$instruction_hash")
    idx=$((idx + 1))
  done
  REC_MEMBER_IDS=()
  REC_MEMBER_RELATIONS=()
  REC_MEMBER_PATHS=()
  idx=0
  while [ "$idx" -lt "${#member_specs[@]}" ]; do
    spec=${member_specs[$idx]}
    member_id=${spec%%=*}
    member_path=${spec#*=}
    member_real=$(canonical_directory "$member_path") || die "member path drifted during registration"
    REC_MEMBER_IDS+=("$member_id")
    REC_MEMBER_RELATIONS+=("${member_relations[$idx]}")
    REC_MEMBER_PATHS+=("$member_real")
    idx=$((idx + 1))
  done

  TMP_RECORD=$(umask 077; mktemp "$REGISTRY/.${id}.workspace.XXXXXX") \
    || die "cannot stage external workspace record"
  {
    printf 'firstmate-workspace\t1\n'
    printf 'id\t%s\n' "$REC_ID"
    printf 'root\t%s\n' "$REC_ROOT"
    printf 'scope\t%s\n' "$REC_SCOPE"
    idx=0
    while [ "$idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
      printf 'instruction\t%s\t%s\n' "${REC_INSTRUCTION_PATHS[$idx]}" "${REC_INSTRUCTION_HASHES[$idx]}"
      idx=$((idx + 1))
    done
    idx=0
    while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
      printf 'member\t%s\t%s\t%s\n' "${REC_MEMBER_IDS[$idx]}" "${REC_MEMBER_RELATIONS[$idx]}" "${REC_MEMBER_PATHS[$idx]}"
      idx=$((idx + 1))
    done
  } > "$TMP_RECORD"
  chmod 600 "$TMP_RECORD" || die "cannot protect staged external workspace record"
  target=$(record_path "$id")
  mv -- "$TMP_RECORD" "$target" || die "cannot publish external workspace record"
  TMP_RECORD=
  load_record "$target" || die "published external workspace record did not validate"
  printf 'registered workspace %s root=%s members=%s instructions=%s\n' \
    "$REC_ID" "$REC_ROOT" "${#REC_MEMBER_IDS[@]}" "${#REC_INSTRUCTION_PATHS[@]}"
}

command_list() {
  local file members idx
  validate_registry || exit 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    load_record "$file" || exit 1
    members=
    idx=0
    while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
      members="${members}${members:+,}${REC_MEMBER_IDS[$idx]}"
      idx=$((idx + 1))
    done
    printf '%s\t%s\t%s\t%s\n' "$REC_ID" "$REC_ROOT" "$members" "$REC_SCOPE"
  done <<EOF
$(registry_files)
EOF
}

command_show() {
  local id=${1:-}
  [ -n "$id" ] || die "show requires a workspace id"
  [ "$#" -eq 1 ] || die "show accepts exactly one workspace id"
  validate_registry || exit 1
  load_named_record "$id" || exit 1
  print_show
}

command_resolve() {
  local workspace='' member='' format=show arg member_idx
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --path) [ "$format" = show ] || die "resolve accepts only one output format"; format=path ;;
      --context) [ "$format" = show ] || die "resolve accepts only one output format"; format=context ;;
      --*) die "unknown resolve option: $arg" ;;
      *)
        if [ -z "$workspace" ]; then workspace=$arg
        elif [ -z "$member" ]; then member=$arg
        else die "resolve accepts one workspace id and one member id"
        fi
        ;;
    esac
  done
  [ -n "$workspace" ] && [ -n "$member" ] || die "resolve requires a workspace id and member id"
  validate_registry || exit 1
  load_named_record "$workspace" || exit 1
  member_idx=$(find_member_index "$member") || die "workspace '$workspace' has no member '$member'"
  case "$format" in
    path) printf '%s\n' "${REC_MEMBER_PATHS[$member_idx]}" ;;
    context) print_context "$member_idx" ;;
    show)
      printf 'workspace: %s\n' "$REC_ID"
      printf 'member: %s\n' "${REC_MEMBER_IDS[$member_idx]}"
      printf 'relation: %s\n' "${REC_MEMBER_RELATIONS[$member_idx]}"
      printf 'repository: %s\n' "${REC_MEMBER_PATHS[$member_idx]}"
      ;;
  esac
}

reject_copy_target_overlap() {
  local target=$1 protected
  protected=$(canonical_directory "$FM_ROOT") || die "firstmate repo is missing or not a directory: $FM_ROOT"
  if path_is_within_or_equal "$protected" "$target"; then
    die "target firstmate home cannot be equal to or inside protected path '$protected': $target"
  fi
  if path_is_within_or_equal "$REC_ROOT" "$target"; then
    die "target firstmate home cannot be equal to or inside protected workspace root '$REC_ROOT': $target"
  fi
  local idx=0
  while [ "$idx" -lt "${#REC_MEMBER_PATHS[@]}" ]; do
    protected=${REC_MEMBER_PATHS[$idx]}
    if path_is_within_or_equal "$protected" "$target"; then
      die "target firstmate home cannot be equal to or inside protected member repository '$protected': $target"
    fi
    idx=$((idx + 1))
  done
}

command_copy() {
  local id=${1:-} target_home='' check_only=0 arg source_record target_real target_record idx
  local args=()
  [ -n "$id" ] || die "copy requires a workspace id"
  valid_id "$id" || die "invalid workspace id: $id"
  shift || true
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --to-home)
        [ "$#" -gt 0 ] || die "--to-home requires an absolute firstmate home"
        target_home=$1
        shift
        ;;
      --to-home=*) target_home=${arg#--to-home=} ;;
      --check-only) check_only=1 ;;
      *) die "unknown copy option: $arg" ;;
    esac
  done
  [ -n "$target_home" ] || die "copy requires --to-home <absolute-firstmate-home>"
  require_absolute "target firstmate home" "$target_home"
  if [ "$check_only" -eq 1 ]; then
    target_real=$(canonical_path_for_check "$target_home") \
      || die "target firstmate home cannot be resolved: $target_home"
  else
    target_real=$(canonical_directory "$target_home") \
      || die "target firstmate home is missing or not a directory: $target_home"
  fi
  [ "$target_real" != "$(canonical_directory "$FM_HOME")" ] \
    || die "target firstmate home must differ from the active home"

  validate_registry || exit 1
  load_named_record "$id" || exit 1
  reject_copy_target_overlap "$target_real"
  [ "$check_only" -eq 0 ] || return 0
  [ -f "$target_real/AGENTS.md" ] && [ -d "$target_real/bin" ] \
    || die "target is not a firstmate home: $target_real"
  source_record=$(record_path "$id")
  target_record="$target_real/data/workspaces/$id.workspace"
  if [ -e "$target_record" ] || [ -L "$target_record" ]; then
    [ -f "$target_record" ] && [ ! -L "$target_record" ] \
      || die "target workspace record is unsafe: $target_record"
    (
      unset FM_DATA_OVERRIDE FM_ROOT_OVERRIDE
      FM_HOME="$target_real" "$SCRIPT_DIR/fm-workspace.sh" show "$id" >/dev/null
    ) || die "target workspace registry is invalid: $target_real"
    cmp -s "$source_record" "$target_record" \
      || die "target workspace '$id' differs from the active-home pointer: $target_record"
    printf 'workspace %s already matches in %s\n' "$id" "$target_real"
    return 0
  fi

  args=(add "$REC_ID" --root "$REC_ROOT" --scope "$REC_SCOPE")
  idx=0
  while [ "$idx" -lt "${#REC_INSTRUCTION_PATHS[@]}" ]; do
    args+=(--instruction-root "${REC_INSTRUCTION_PATHS[$idx]}")
    idx=$((idx + 1))
  done
  idx=0
  while [ "$idx" -lt "${#REC_MEMBER_IDS[@]}" ]; do
    case "${REC_MEMBER_RELATIONS[$idx]}" in
      contained) args+=(--member "${REC_MEMBER_IDS[$idx]}=${REC_MEMBER_PATHS[$idx]}") ;;
      external) args+=(--external-member "${REC_MEMBER_IDS[$idx]}=${REC_MEMBER_PATHS[$idx]}") ;;
      *) die "workspace '$id' has an unsupported member relation" ;;
    esac
    idx=$((idx + 1))
  done
  (
    unset FM_DATA_OVERRIDE FM_ROOT_OVERRIDE
    FM_HOME="$target_real" "$SCRIPT_DIR/fm-workspace.sh" "${args[@]}" >/dev/null
  ) || die "failed to copy workspace '$id' into $target_real"
  printf 'copied workspace %s to %s; external root and repositories were not touched\n' "$id" "$target_real"
}

command_remove() {
  local id=${1:-} confirm='' expected_record='' arg target first second extra
  [ -n "$id" ] || die "remove requires a workspace id"
  valid_id "$id" || die "invalid workspace id: $id"
  shift || true
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --confirm)
        [ "$#" -gt 0 ] || die "--confirm requires the workspace id"
        confirm=$1
        shift
        ;;
      --confirm=*) confirm=${arg#--confirm=} ;;
      --if-matches)
        [ "$#" -gt 0 ] || die "--if-matches requires a record path"
        expected_record=$1
        shift
        ;;
      --if-matches=*) expected_record=${arg#--if-matches=} ;;
      *) die "unknown remove option: $arg" ;;
    esac
  done
  [ "$confirm" = "$id" ] || die "remove requires --confirm '$id'; unregistering removes only the private pointer record"
  acquire_registry_lock
  registry_is_readable || die "external workspace is not registered: $id"
  target=$(record_path "$id")
  [ -f "$target" ] && [ ! -L "$target" ] || die "external workspace record is missing or unsafe: $target"
  IFS=$'\t' read -r first second extra < "$target" || die "cannot read external workspace record: $target"
  [ "$first" = firstmate-workspace ] && [ "$second" = 1 ] && [ -z "$extra" ] \
    || die "external workspace record has an invalid envelope: $target"
  IFS=$'\t' read -r first second extra < <(sed -n '2p' "$target") \
    || die "cannot read external workspace id: $target"
  [ "$first" = id ] && [ "$second" = "$id" ] && [ -z "$extra" ] \
    || die "external workspace record id does not match '$id': $target"
  if [ -n "$expected_record" ]; then
    [ -f "$expected_record" ] && [ ! -L "$expected_record" ] \
      || die "expected workspace record is missing or unsafe: $expected_record"
    cmp -s "$expected_record" "$target" \
      || die "external workspace record does not match the expected pointer: $target"
  fi
  rm -f -- "$target" || die "cannot remove external workspace pointer record: $target"
  printf 'unregistered workspace %s; external root and repositories were not touched\n' "$id"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  add|register) shift; command_add "$@" ;;
  list) shift; [ "$#" -eq 0 ] || die "list accepts no arguments"; command_list ;;
  show) shift; command_show "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  copy) shift; command_copy "$@" ;;
  remove|unregister) shift; command_remove "$@" ;;
  *) die "unknown command: $1" ;;
esac
