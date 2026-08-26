#!/usr/bin/env bash
# Shared presentation identity contract.
#
# Authoritative fields stay separate:
#   callsign       persistent human worker identity
#   project_code   stable acronym registered for the project/workspace
#   task_label     explicit intake label of one or two words
#
# Task ids and harness session UUIDs are deliberately absent. The canonical
# Unicode rendering is:
#
#   <Callsign> · <ProjectCode> · <TaskLabel>
#
# A surface that cannot render Unicode may explicitly request the ASCII fallback
# `<Callsign> - <ProjectCode> - <TaskLabel>`. Optional width limiting preserves
# callsign and project code, truncating only the task-label segment. A requested
# width shorter than those fixed segments is a soft limit: the fixed identity is
# retained and the task segment becomes only the truncation marker.
#
# Brief metadata is explicit intake data, never inferred from prose or task ids:
#   Firstmate project code: <ProjectCode>
#   Firstmate task label: <TaskLabel>
# Only the pre-`# Task` header is read. Both absent is the legacy-compatible
# state; partial, duplicate, or malformed metadata is corruption and is refused.
# Runtime task metadata carries the same values as project_code= and task_label=.
# A persistent secondmate uses the same field ordering with a role marker rather
# than a routed task label: `<Callsign> · <ContextCode> · 2M`, falling back to
# `<Callsign> · 2M` when no stable registered context code is available.

fm_display_value_safe() {
  case "${1:-}" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

fm_display_project_code_valid() {  # <project-code>
  local code=${1:-} LC_ALL=C
  [ "${#code}" -ge 2 ] && [ "${#code}" -le 8 ] || return 1
  case "$code" in
    [A-Z]*) ;;
    *) return 1 ;;
  esac
  case "$code" in *[!A-Z0-9]*) return 1 ;; esac
}

fm_display_task_label_valid() {  # <task-label>
  local label=${1:-} words
  fm_display_value_safe "$label" || return 1
  case "$label" in
    ' '*|*' '|*'  '*|*'·'*) return 1 ;;
  esac
  words=$(printf '%s\n' "$label" | awk '{ print NF }') || return 1
  [ "$words" -ge 1 ] && [ "$words" -le 2 ]
}

fm_display_callsign_valid() {  # <callsign>
  local callsign=${1:-}
  fm_display_value_safe "$callsign" || return 1
  case "$callsign" in *'·'*|*' - '*) return 1 ;; esac
}

fm_display_title() {  # <callsign> <project-code> <task-label> [unicode|ascii] [max-chars]
  local callsign=${1:-} code=${2:-} label=${3:-} style=${4:-unicode} max=${5:-}
  local separator marker prefix full available marker_len keep
  fm_display_callsign_valid "$callsign" || return 1
  fm_display_project_code_valid "$code" || return 1
  fm_display_task_label_valid "$label" || return 1
  case "$style" in
    unicode) separator=' · '; marker='…' ;;
    ascii) separator=' - '; marker='...' ;;
    *) return 1 ;;
  esac
  prefix="${callsign}${separator}${code}${separator}"
  full="${prefix}${label}"
  if [ -z "$max" ]; then
    printf '%s' "$full"
    return 0
  fi
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  [ "$max" -gt 0 ] || return 1
  [ "${#full}" -gt "$max" ] || { printf '%s' "$full"; return 0; }
  available=$((max - ${#prefix}))
  marker_len=${#marker}
  if [ "$available" -le 0 ]; then
    printf '%s%s' "$prefix" "$marker"
  elif [ "$available" -le "$marker_len" ]; then
    printf '%s%s' "$prefix" "${label:0:$available}"
  else
    keep=$((available - marker_len))
    printf '%s%s%s' "$prefix" "${label:0:$keep}" "$marker"
  fi
}

fm_display_secondmate_title() {  # <callsign> [context-code] [unicode|ascii]
  local callsign=${1:-} code=${2:-} style=${3:-unicode} separator
  fm_display_callsign_valid "$callsign" || return 1
  [ -z "$code" ] || fm_display_project_code_valid "$code" || return 1
  case "$style" in
    unicode) separator=' · ' ;;
    ascii) separator=' - ' ;;
    *) return 1 ;;
  esac
  if [ -n "$code" ]; then
    printf '%s%s%s%s2M' "$callsign" "$separator" "$code" "$separator"
  else
    printf '%s%s2M' "$callsign" "$separator"
  fi
}

fm_display_workspace_context_code_derive() {  # <registered-workspace-id>
  local workspace=${1:-} part code='' first=1 LC_ALL=C
  fm_display_value_safe "$workspace" || return 1
  case "$workspace" in ''|-*|*-|*--*|*[!A-Za-z0-9-]*) return 1 ;; esac
  while [ -n "$workspace" ]; do
    part=${workspace%%-*}
    [ -n "$part" ] || return 1
    code=$code${part:0:1}
    case "$workspace" in
      *-*) workspace=${workspace#*-}; first=0 ;;
      *) workspace= ;;
    esac
  done
  [ "$first" -eq 0 ] || return 1
  code=$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')
  fm_display_project_code_valid "$code" || return 1
  printf '%s' "$code"
}

fm_display_workspace_context_code() {  # <registered-workspace-id> <newline-delimited-registered-workspace-ids>
  local workspace=${1:-} registered=${2:-} code id candidate matches=0 found=0
  [ -n "$registered" ] || return 1
  code=$(fm_display_workspace_context_code_derive "$workspace") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$workspace" ] || found=$((found + 1))
    candidate=$(fm_display_workspace_context_code_derive "$id" 2>/dev/null) || continue
    [ "$candidate" != "$code" ] || matches=$((matches + 1))
  done <<EOF
$registered
EOF
  [ "$found" -eq 1 ] && [ "$matches" -eq 1 ] || return 1
  printf '%s' "$code"
}

fm_display_secondmate_metadata_read() {  # <meta>; sets FM_DISPLAY_CONTEXT_CODE
  local meta=$1 count context_code
  FM_DISPLAY_CONTEXT_CODE=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    printf 'error: secondmate task metadata is missing or not a regular file: %s\n' "$meta" >&2
    return 1
  }
  count=$(awk -F= '$1 == "context_code" { n++ } END { print n+0 }' "$meta") || return 1
  [ "$count" -le 1 ] || {
    printf 'error: secondmate task metadata has duplicate context_code= fields\n' >&2
    return 1
  }
  [ "$count" -eq 1 ] || return 0
  context_code=$(awk -F= '$1 == "context_code" { sub(/^[^=]*=/, ""); print; exit }' "$meta") || return 1
  fm_display_project_code_valid "$context_code" || {
    printf "error: invalid context_code '%s' in secondmate task metadata\n" "$context_code" >&2
    return 1
  }
  # shellcheck disable=SC2034 # output global is consumed by the sourcing caller.
  FM_DISPLAY_CONTEXT_CODE=$context_code
}

fm_display_brief_metadata_read() {  # <brief>; sets FM_DISPLAY_* globals
  local brief=$1 project_count label_count project_code task_label
  FM_DISPLAY_METADATA_STATE=absent
  FM_DISPLAY_PROJECT_CODE=
  FM_DISPLAY_TASK_LABEL=
  [ -f "$brief" ] && [ ! -L "$brief" ] || {
    printf 'error: display metadata brief is missing or not a regular file: %s\n' "$brief" >&2
    return 1
  }
  project_count=$(awk '/^# Task$/ { exit } /^Firstmate project code: / { n++ } END { print n+0 }' "$brief") || return 1
  label_count=$(awk '/^# Task$/ { exit } /^Firstmate task label: / { n++ } END { print n+0 }' "$brief") || return 1
  if [ "$project_count" -eq 0 ] && [ "$label_count" -eq 0 ]; then
    return 0
  fi
  if [ "$project_count" -ne 1 ] || [ "$label_count" -ne 1 ]; then
    printf 'error: brief display metadata requires exactly one project code and one task label before # Task\n' >&2
    return 1
  fi
  project_code=$(awk '/^# Task$/ { exit } /^Firstmate project code: / { sub(/^Firstmate project code: /, ""); print; exit }' "$brief") || return 1
  task_label=$(awk '/^# Task$/ { exit } /^Firstmate task label: / { sub(/^Firstmate task label: /, ""); print; exit }' "$brief") || return 1
  fm_display_project_code_valid "$project_code" || {
    printf "error: invalid Firstmate project code '%s' in brief; expected 2-8 uppercase ASCII letters/digits beginning with a letter\n" "$project_code" >&2
    return 1
  }
  fm_display_task_label_valid "$task_label" || {
    printf "error: invalid Firstmate task label '%s' in brief; expected one or two words with no surrounding/repeated spaces or middle dots\n" "$task_label" >&2
    return 1
  }
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_METADATA_STATE=present
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_PROJECT_CODE=$project_code
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_TASK_LABEL=$task_label
}

fm_display_task_metadata_read() {  # <meta>; sets FM_DISPLAY_* globals
  local meta=$1 project_count label_count project_code task_label
  FM_DISPLAY_METADATA_STATE=absent
  FM_DISPLAY_PROJECT_CODE=
  FM_DISPLAY_TASK_LABEL=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    printf 'error: task metadata is missing or not a regular file: %s\n' "$meta" >&2
    return 1
  }
  project_count=$(awk -F= '$1 == "project_code" { n++ } END { print n+0 }' "$meta") || return 1
  label_count=$(awk -F= '$1 == "task_label" { n++ } END { print n+0 }' "$meta") || return 1
  if [ "$project_count" -eq 0 ] && [ "$label_count" -eq 0 ]; then
    return 0
  fi
  if [ "$project_count" -ne 1 ] || [ "$label_count" -ne 1 ]; then
    printf 'error: task display metadata requires exactly one project_code= and one task_label= field\n' >&2
    return 1
  fi
  project_code=$(awk -F= '$1 == "project_code" { sub(/^[^=]*=/, ""); print; exit }' "$meta") || return 1
  task_label=$(awk -F= '$1 == "task_label" { sub(/^[^=]*=/, ""); print; exit }' "$meta") || return 1
  fm_display_project_code_valid "$project_code" || {
    printf "error: invalid project_code '%s' in task metadata\n" "$project_code" >&2
    return 1
  }
  fm_display_task_label_valid "$task_label" || {
    printf "error: invalid task_label '%s' in task metadata\n" "$task_label" >&2
    return 1
  }
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_METADATA_STATE=present
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_PROJECT_CODE=$project_code
  # shellcheck disable=SC2034 # output globals are consumed by the sourcing caller.
  FM_DISPLAY_TASK_LABEL=$task_label
}
