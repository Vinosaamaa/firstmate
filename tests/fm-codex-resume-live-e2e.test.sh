#!/usr/bin/env bash
# Opt-in credentialed Codex regression for exact persisted-session continuity.
# It parses only Codex's structured thread.started id, resumes that exact id in
# a disposable clone, and never uses --last, a label, cwd-most-recent lookup,
# or a terminal UUID scrape. The interactive exit-banner/`codex resume <ID>`
# spelling consumed by fm-control has a separate pinned empirical receipt in
# docs/verification/runtime-backends.md and hermetic parser/launch tests.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the exact Codex resume regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-session-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
CODEX_VERSION=$(codex --version 2>/dev/null) || fail "codex --version failed"
case "$CODEX_VERSION" in
  codex-cli\ 0.149.*) ;;
  *) fail "this pinned verification requires installed Codex 0.149, got '$CODEX_VERSION'" ;;
esac

LAB="$ROOT/.codex-resume-live-e2e.$$"
PROJECT="$LAB/project"
FIRST_TRANSCRIPT="$LAB/first.jsonl"
SECOND_TRANSCRIPT="$LAB/second.jsonl"
FIRST_ERROR="$LAB/first.stderr"
SECOND_ERROR="$LAB/second.stderr"
FIRST_OUTPUT="$LAB/first-output.txt"
SECOND_OUTPUT="$LAB/second-output.txt"
MEMORY_TOKEN="EXACT_MEMORY_$$_$RANDOM"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT" || fail "could not create disposable Codex resume clone"
(
  cd "$PROJECT" || exit 1
  codex exec --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox --ignore-rules --json \
    --output-last-message "$FIRST_OUTPUT" \
    "Remember the exact marker $MEMORY_TOKEN. Reply only READY."
) > "$FIRST_TRANSCRIPT" 2> "$FIRST_ERROR" \
  || fail "fresh credentialed Codex turn failed: $(tail -20 "$FIRST_ERROR") $(tail -20 "$FIRST_TRANSCRIPT")"

SESSION_IDS=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' \
  "$FIRST_TRANSCRIPT" 2>/dev/null) || fail "could not parse Codex structured thread.started output"
[ "$(printf '%s\n' "$SESSION_IDS" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] \
  || fail "fresh Codex turn did not emit exactly one structured session id"
SESSION_ID=$SESSION_IDS
fm_codex_session_uuid_valid "$SESSION_ID" \
  || fail "Codex structured session id '$SESSION_ID' is not a canonical lowercase UUID"

(
  cd "$PROJECT" || exit 1
  codex exec resume --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox --ignore-rules --json \
    --output-last-message "$SECOND_OUTPUT" "$SESSION_ID" \
    "Reply with the exact marker I asked you to remember, and nothing else."
) > "$SECOND_TRANSCRIPT" 2> "$SECOND_ERROR" \
  || fail "exact credentialed Codex resume failed: $(tail -20 "$SECOND_ERROR") $(tail -20 "$SECOND_TRANSCRIPT")"
grep -Fx "$MEMORY_TOKEN" "$SECOND_OUTPUT" >/dev/null \
  || fail "exact session $SESSION_ID did not preserve the first turn's marker: $(cat "$SECOND_OUTPUT")"

printf 'ok - %s resumed exact structured session %s in a disposable clone\n' \
  "$CODEX_VERSION" "$SESSION_ID"
