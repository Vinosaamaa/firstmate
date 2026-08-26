#!/usr/bin/env bash
# Codex adapter for assigning the current conversation's display title.
#
# Codex's supported interactive `/rename <name>` command renames the loaded
# conversation without changing its UUID. Firstmate launches a metadata-bearing
# Codex task (or exact `codex resume <UUID>`) without an immediate prompt, waits
# for the real composer, submits `/rename`, and only then submits the original
# operational input. This prevents the first model turn from racing the title.
#
# The shared carrier stays harness-neutral: project_code= and task_label= live in
# task metadata, callsign lives in the identity record, and the exact Codex UUID
# remains exclusively in fm-codex-session-lib.sh's binding. This adapter combines
# those presentation fields only at delivery time. It never writes a Herdr/tab
# title; Herdr already reflects Codex's conversation title.

FM_CODEX_TITLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-display-title-lib.sh
. "$FM_CODEX_TITLE_LIB_DIR/fm-display-title-lib.sh"

fm_codex_title_wait_ready() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected=${3:-} attempt=0
  local max=${FM_CODEX_TITLE_READY_POLLS:-60} interval=${FM_CODEX_TITLE_POLL_INTERVAL:-0.5}
  while [ "$attempt" -lt "$max" ]; do
    if [ "$(fm_backend_composer_state "$backend" "$target" "$expected" 2>/dev/null)" = empty ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$max" ] || sleep "$interval"
  done
  printf 'error: Codex did not show a verified empty composer before conversation naming\n' >&2
  return 1
}

fm_codex_title_submit() {  # <backend> <target> <text> [expected-label]
  local backend=$1 target=$2 payload=$3 expected=${4:-} verdict
  verdict=$(fm_backend_send_text_submit \
    "$backend" "$target" "$payload" \
    "${FM_CODEX_TITLE_SUBMIT_RETRIES:-3}" \
    "${FM_CODEX_TITLE_POLL_INTERVAL:-0.5}" \
    "${FM_CODEX_TITLE_SUBMIT_SETTLE:-0}" "$expected") || return 1
  [ "$verdict" = empty ] || {
    printf "error: Codex input delivery was not confirmed (verdict=%s)\n" "$verdict" >&2
    return 1
  }
}

fm_codex_title_deliver() {  # <backend> <target> <expected-label> <callsign> <context-code> <task-label> <launch-brief|resume-note> <input-file> [task|secondmate]
  local backend=$1 target=$2 expected=$3 callsign=$4 code=$5 label=$6 input_kind=$7 input_file=$8 role=${9:-task}
  local title input opinput
  case "$role" in
    task) title=$(fm_display_title "$callsign" "$code" "$label" unicode) ;;
    secondmate) title=$(fm_display_secondmate_title "$callsign" "$code" unicode) ;;
    *) return 1 ;;
  esac || {
    printf 'error: refused malformed Codex display identity\n' >&2
    return 1
  }
  case "$input_kind" in launch-brief|resume-note) ;; *) return 1 ;; esac
  [ -f "$input_file" ] && [ ! -L "$input_file" ] || {
    printf 'error: Codex operational input file is missing or not a regular file: %s\n' "$input_file" >&2
    return 1
  }
  opinput="${FM_ROOT:-$(cd "$FM_CODEX_TITLE_LIB_DIR/.." && pwd)}/bin/fm-operational-input.sh"
  input=$("$opinput" encode "$input_kind" < "$input_file") || return 1
  fm_codex_title_wait_ready "$backend" "$target" "$expected" || return 1
  fm_codex_title_submit "$backend" "$target" "/rename $title" "$expected" || return 1
  fm_codex_title_submit "$backend" "$target" "$input" "$expected" || return 1
}
