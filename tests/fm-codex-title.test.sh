#!/usr/bin/env bash
# Codex conversation-title adapter tests at the backend integration seam.
# Both tmux and Herdr use the same supported `/rename` path; the adapter never
# writes a backend/tab/header title of its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-title-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-title)
INPUT="$TMP_ROOT/input.md"
LOG="$TMP_ROOT/submits.log"
READY_FILE="$TMP_ROOT/ready-count"
printf '%s\n' 'Continue the exact assigned task.' > "$INPUT"

fm_backend_composer_state() {
  local count
  count=$(cat "$READY_FILE" 2>/dev/null || printf 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$READY_FILE"
  [ "$count" -ge 2 ] && printf empty || printf unknown
}

fm_backend_send_text_submit() {
  local backend=$1 target=$2 payload=$3 retries=$4 sleep_s=$5 settle=$6 expected=${7:-}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$backend" "$target" "$retries" "$sleep_s" "$settle" "$expected" "$payload" >> "$LOG"
  printf '%s' "${FM_FAKE_SUBMIT_VERDICT:-empty}"
}

run_backend_case() {  # <tmux|herdr> <target>
  local backend=$1 target=$2 first second
  : > "$LOG"
  printf '0\n' > "$READY_FILE"
  FM_CODEX_TITLE_POLL_INTERVAL=0 FM_ROOT="$ROOT" \
    fm_codex_title_deliver "$backend" "$target" task-label Darwin FM 'External workspace' resume-note "$INPUT" \
    || fail "$backend title delivery failed"
  first=$(sed -n '1p' "$LOG")
  second=$(sed -n '2p' "$LOG")
  assert_contains "$first" "$backend" "$backend adapter call lost its backend"
  assert_contains "$first" "$target" "$backend adapter call lost its exact target"
  assert_contains "$first" $'/rename Darwin · FM · External workspace' \
    "$backend did not rename the actual Codex conversation first"
  assert_contains "$second" 'Continue the exact assigned task.' \
    "$backend did not deliver the original resume note after naming"
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] \
    || fail "$backend adapter submitted an unexpected duplicate input"
}

test_tmux_and_herdr_share_codex_contract() {
  run_backend_case tmux '%42'
  run_backend_case herdr 'fm-lab-safe:w1:p2'
  pass "Codex title adapter: tmux and Herdr rename the conversation before one input delivery"
}

test_failed_rename_never_delivers_task_input() {
  local out
  : > "$LOG"
  printf '10\n' > "$READY_FILE"
  out=$(FM_FAKE_SUBMIT_VERDICT=unknown FM_CODEX_TITLE_POLL_INTERVAL=0 FM_ROOT="$ROOT" \
    fm_codex_title_deliver tmux '%42' task-label Darwin FM 'External workspace' launch-brief "$INPUT" 2>&1) \
    && fail "unconfirmed Codex rename was accepted"
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] \
    || fail "task input was delivered after an unconfirmed rename"
  assert_contains "$out" 'delivery was not confirmed' \
    "unconfirmed rename refusal lost its diagnostic"
  pass "Codex title adapter: failed naming does not race or duplicate the task prompt"
}

test_secondmate_role_title_uses_same_supported_rename_path() {
  local first second
  : > "$LOG"
  printf '10\n' > "$READY_FILE"
  FM_CODEX_TITLE_POLL_INTERVAL=0 FM_ROOT="$ROOT" \
    fm_codex_title_deliver herdr 'fm-lab-safe:w1:p3' fm-sm Kepler IP '' \
      launch-brief "$INPUT" secondmate \
    || fail "secondmate Codex title delivery failed"
  first=$(sed -n '1p' "$LOG")
  second=$(sed -n '2p' "$LOG")
  assert_contains "$first" $'/rename Kepler · IP · 2M' \
    "secondmate did not use the role-aware conversation title"
  assert_contains "$second" 'Continue the exact assigned task.' \
    "secondmate task input was not delivered after naming"
  pass "Codex title adapter: secondmates use the role-aware title on the supported rename path"
}

test_tmux_and_herdr_share_codex_contract
test_failed_rename_never_delivers_task_input
test_secondmate_role_title_uses_same_supported_rename_path
echo "# all fm-codex-title tests passed"
