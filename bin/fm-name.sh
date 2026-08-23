#!/usr/bin/env bash
# Inspect and rename persistent Firstmate and task identities.
#
# Usage:
#   fm-name.sh home
#   fm-name.sh rename-home <new-name>
#   fm-name.sh rename <task-id-or-callsign> <new-callsign>
#   fm-name.sh resolve <task-id-or-callsign>
#   fm-name.sh history
#
# Output keeps names first while retaining the exact task id in parentheses.
# resolve and rename accept callsigns case-insensitively within the explicit
# FM_HOME. Missing, ambiguous, archived-only, historical, conflicting, or unsafe
# matches refuse instead of guessing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in -h|--help|help|'') usage; exit 0 ;; esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-name refuses to resolve an identity without an explicit Firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
mkdir -p "$STATE" "$DATA"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-identity-lib.sh
. "$SCRIPT_DIR/fm-identity-lib.sh"

command=$1
shift
case "$command" in
  home)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    name=$(fm_identity_ensure_home)
    printf '%s (Firstmate home)\n' "$name"
    ;;
  rename-home)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    name=$(fm_identity_rename_home "$1")
    printf '%s (Firstmate home)\n' "$name"
    ;;
  rename)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    result=$(fm_identity_rename_task "$STATE" "$1" "$2")
    callsign=${result%%$'\t'*}
    id=${result#*$'\t'}
    printf '%s (%s)\n' "$callsign" "$id"
    ;;
  resolve)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$(fm_identity_resolve_selector "$STATE" "$1")
    callsign=$(fm_identity_display_callsign "$id")
    printf '%s (%s)\n' "$callsign" "$id"
    ;;
  history)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    fm_identity_history | while IFS=$'\t' read -r callsign id status; do
      if [ "$callsign" = UNSAFE ]; then
        printf 'UNSAFE (%s) %s\n' "$id" "$status"
      else
        printf '%s (%s) %s\n' "$callsign" "$id" "$status"
      fi
    done
    ;;
  *) usage >&2; exit 2 ;;
esac
