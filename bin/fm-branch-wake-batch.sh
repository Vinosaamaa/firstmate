#!/usr/bin/env bash
# Snapshot, claim, or release one branch-eligible wake batch under the durable
# queue lock.
#
# Output on success:
#   through<TAB><highest sequence>
#   digest<TAB><digest of the exact batch rows>
#   project<TAB><single resolved task-metadata project>
#
# Empty, malformed, fleet-wide, unresolvable, or mixed-project queues fail
# silently so the Pi watcher preserves ordinary delivery to main.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=${1:-offer}
REQUEST_THROUGH=${2:-}
REQUEST_DIGEST=${3:-}
REQUEST_OWNER=${FM_BRANCH_OWNER_PID:-}
case "$REQUEST_OWNER" in ''|*[!0-9]*) REQUEST_OWNER= ;; esac
case "$MODE" in
  offer) [ "$#" -eq 0 ] || { echo "usage: fm-branch-wake-batch.sh [claim SEQUENCE DIGEST | release [SEQUENCE DIGEST]]" >&2; exit 2; } ;;
  claim)
    case "$REQUEST_THROUGH" in ''|0|*[!0-9]*) echo "branch wake batch: invalid sequence" >&2; exit 2 ;; esac
    case "$REQUEST_DIGEST" in sha256:*|cksum:*:*) ;; *) echo "branch wake batch: invalid digest" >&2; exit 2 ;; esac
    [ "$#" -eq 3 ] || { echo "usage: fm-branch-wake-batch.sh claim SEQUENCE DIGEST" >&2; exit 2; }
    ;;
  release)
    if [ "$#" -ne 1 ]; then
      case "$REQUEST_THROUGH" in ''|0|*[!0-9]*) echo "branch wake batch: invalid sequence" >&2; exit 2 ;; esac
      case "$REQUEST_DIGEST" in sha256:*|cksum:*:*) ;; *) echo "branch wake batch: invalid digest" >&2; exit 2 ;; esac
      [ "$#" -eq 3 ] || { echo "usage: fm-branch-wake-batch.sh release [SEQUENCE DIGEST]" >&2; exit 2; }
    fi
    ;;
  recover) [ "$#" -eq 1 ] || { echo "usage: fm-branch-wake-batch.sh recover" >&2; exit 2; } ;;
  *) echo "usage: fm-branch-wake-batch.sh [claim SEQUENCE DIGEST | release [SEQUENCE DIGEST]]" >&2; exit 2 ;;
esac

BATCH_TMP=
BATCH_LOCK_HELD=false
RESERVATION="$STATE/.branch-wake-reservation"

cleanup() {
  local status=$?
  [ -z "$BATCH_TMP" ] || rm -f -- "$BATCH_TMP" 2>/dev/null || true
  if [ "$BATCH_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

metadata_project() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  awk '
    /^project=/ {
      count += 1
      value = substr($0, 9)
    }
    END {
      if (count != 1 || value == "" || value ~ /[\t\r]/) exit 1
      print value
    }
  ' "$file"
}

stale_project() {
  local key=$1 file candidate found=''
  case "$key" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  if [ -f "$STATE/$key.meta" ] && [ ! -L "$STATE/$key.meta" ]; then
    metadata_project "$STATE/$key.meta"
    return
  fi
  for file in "$STATE"/*.meta; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if grep -Fqx "window=$key" "$file" 2>/dev/null; then
      candidate=$(metadata_project "$file") || return 1
      [ -z "$found" ] || return 1
      found=$candidate
    fi
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
BATCH_LOCK_HELD=true

if [ "$MODE" = release ]; then
  [ -f "$RESERVATION" ] && [ ! -L "$RESERVATION" ] || exit 0
  IFS=$(printf '\t') read -r reserved_through reserved_digest reserved_owner extra < "$RESERVATION" || exit 1
  [ -z "${extra:-}" ] && [ -n "$REQUEST_OWNER" ] && [ "$reserved_owner" = "$REQUEST_OWNER" ] || exit 1
  lock_owner=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  [ "$lock_owner" = "$REQUEST_OWNER" ] || exit 1
  if [ "$#" -eq 3 ]; then
    [ "$reserved_through" = "$REQUEST_THROUGH" ] \
      && [ "$reserved_digest" = "$REQUEST_DIGEST" ] || exit 1
  fi
  rm -f -- "$RESERVATION" || exit 1
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  BATCH_LOCK_HELD=false
  exit 0
fi

if [ -e "$RESERVATION" ] || [ -L "$RESERVATION" ]; then
  [ -f "$RESERVATION" ] && [ ! -L "$RESERVATION" ] || exit 1
  IFS=$(printf '\t') read -r reserved_through reserved_digest reserved_owner extra < "$RESERVATION" || exit 1
  case "$reserved_through" in ''|0|*[!0-9]*) exit 1 ;; esac
  case "$reserved_digest" in sha256:*|cksum:*:*) ;; *) exit 1 ;; esac
  case "$reserved_owner" in ''|*[!0-9]*) exit 1 ;; esac
  [ -z "${extra:-}" ] || exit 1
  if [ "$reserved_owner" = "$REQUEST_OWNER" ]; then
    [ "$MODE" = recover ] || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    BATCH_LOCK_HELD=false
    exit 0
  else
    lock_owner=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    [ -n "$REQUEST_OWNER" ] && [ "$lock_owner" = "$REQUEST_OWNER" ] || exit 1
    rm -f -- "$RESERVATION" || exit 1
    if [ "$MODE" = recover ]; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      BATCH_LOCK_HELD=false
      exit 0
    fi
  fi
elif [ "$MODE" = recover ]; then
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  BATCH_LOCK_HELD=false
  exit 0
fi
[ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] && [ -s "$FM_WAKE_QUEUE" ] || exit 1

awk -F '\t' '
  NF != 5 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $2 <= previous ||
    ($3 != "signal" && $3 != "stale") || $4 == "" || $5 == "" { exit 1 }
  { previous = $2 }
' "$FM_WAKE_QUEUE" || exit 1

BATCH_TMP=$(mktemp "$STATE/.branch-wake-batch.XXXXXX") || exit 1
chmod 0600 "$BATCH_TMP" || exit 1
if [ "$MODE" = claim ]; then
  awk -F '\t' -v cutoff="$REQUEST_THROUGH" '$2 <= cutoff { print }' "$FM_WAKE_QUEUE" > "$BATCH_TMP" || exit 1
else
  awk -F '\t' '{ print }' "$FM_WAKE_QUEUE" > "$BATCH_TMP" || exit 1
fi
[ -s "$BATCH_TMP" ] || exit 1

digest=$(fm_file_digest "$BATCH_TMP") || exit 1
if [ "$MODE" = claim ]; then
  lock_owner=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  [ -n "$REQUEST_OWNER" ] && [ "$lock_owner" = "$REQUEST_OWNER" ] || exit 1
  [ "$digest" = "$REQUEST_DIGEST" ] || exit 1
  through=$(awk -F '\t' 'END { print $2 }' "$BATCH_TMP") || exit 1
  [ "$through" = "$REQUEST_THROUGH" ] || exit 1
  reservation_tmp=$(mktemp "$STATE/.branch-wake-reservation.XXXXXX") || exit 1
  if ! printf '%s\t%s\t%s\n' "$REQUEST_THROUGH" "$REQUEST_DIGEST" "$REQUEST_OWNER" > "$reservation_tmp" \
    || ! chmod 0600 "$reservation_tmp" \
    || ! _fm_atomic_replace "$reservation_tmp" "$RESERVATION"; then
    rm -f -- "$reservation_tmp"
    exit 1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  BATCH_LOCK_HELD=false
  exit 0
fi

through=$(awk -F '\t' 'END { print $2 }' "$BATCH_TMP") || exit 1
case "$through" in ''|*[!0-9]*) exit 1 ;; esac

project=''
while IFS=$(printf '\t') read -r _epoch _seq kind key _payload; do
  case "$kind" in
    signal)
      case "$key" in
        *.status) task=${key%.status} ;;
        *.turn-ended) task=${key%.turn-ended} ;;
        *) exit 1 ;;
      esac
      case "$task" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
      candidate=$(metadata_project "$STATE/$task.meta") || exit 1
      ;;
    stale)
      candidate=$(stale_project "$key") || exit 1
      ;;
    *) exit 1 ;;
  esac
  if [ -z "$project" ]; then
    project=$candidate
  elif [ "$project" != "$candidate" ]; then
    exit 1
  fi
done < "$BATCH_TMP"

[ -n "$project" ] || exit 1

fm_lock_release "$FM_WAKE_QUEUE_LOCK"
BATCH_LOCK_HELD=false
printf 'through\t%s\ndigest\t%s\nproject\t%s\n' "$through" "$digest" "$project"
