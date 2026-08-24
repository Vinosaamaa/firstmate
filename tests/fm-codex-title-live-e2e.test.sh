#!/usr/bin/env bash
# Opt-in real Codex + Herdr conversation-title drift guard.
#
# Proves the vendor-dependent surface a stub cannot: a real `/rename` changes
# Codex's loaded conversation name, Herdr's existing header follows without a
# Herdr title mutation, and exact resume plus reassertion keeps one UUID.  The
# authoritative UUID comes from Herdr's Codex agent_session binding; a blank
# generic terminal title in a headless no-focus workspace is only presentation
# masking and is never treated as session identity.
# Every Herdr operation is routed through fm-herdr-lab.sh in a named non-default
# session with the default-fleet tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_CODEX_TITLE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_TITLE_LIVE_E2E=1 to run the real Codex/Herdr title guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_CODEX_TITLE_LIVE_E2E=1 but herdr is not installed"
command -v codex >/dev/null 2>&1 || fail "FM_CODEX_TITLE_LIVE_E2E=1 but Codex is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_CODEX_TITLE_LIVE_E2E=1 but jq is not installed"
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable at $HERDR_LAB_HELPER"

CODEX_BIN=$(command -v codex)
HERDR_ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name codex-title-live-e2e)
# Keep the disposable cwd inside this already-trusted checkout.  An unrelated
# Codex trust-directory prompt in an external temporary root would mask the
# SessionStart hook and prevent the live guard from reaching title delivery.
TMP_ROOT=$(mktemp -d "$ROOT/.fm-codex-title-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
BRIEF="$TMP_ROOT/brief.md"
RESUME_NOTE="$TMP_ROOT/resume-note.md"
mkdir -p "$FAKEBIN" "$PROJECT"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision isolated Herdr title lab"

# Force every adapter-issued Herdr call back through the helper and require its
# trailing explicit --session. The helper itself appends the real trailing flag.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  exit 98
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
shell_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }

CODEX_VERSION=$("$CODEX_BIN" --version 2>/dev/null) || fail "codex --version failed"
case "$CODEX_VERSION" in codex-cli\ 0.149.*) ;; *) fail "title guard is pinned to Codex 0.149, got $CODEX_VERSION" ;; esac
HERDR_STATUS=$(lab status --json 2>/dev/null) || fail "Herdr version probe failed through lab helper"
HERDR_VERSION="herdr $(printf '%s' "$HERDR_STATUS" | jq -er '.client.version')" \
  || fail "Herdr status did not expose a client version"
case "$HERDR_VERSION" in herdr\ 0.8.*) ;; *) fail "title guard is pinned to Herdr 0.8, got $HERDR_VERSION" ;; esac

printf '%s\n' \
  'You are a title verification probe.' \
  'Reply with exactly READY and nothing else.' > "$BRIEF"
printf '%s\n' \
  'Resume the same title verification probe.' \
  'Reply with exactly RESUMED and nothing else.' > "$RESUME_NOTE"

WS_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-codextitle --no-focus) \
  || fail "could not create isolated title workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create returned no pane id"
TARGET="$HERDR_LAB_SESSION:$PANE"
BOOTSTRAP_PROMPT='Reply with exactly BOOTSTRAPPED and nothing else.'
# Codex emits its official SessionStart hook only once a fresh conversation has
# received a user turn.  This diagnostic-only turn gives Herdr the native UUID
# before rename, without deriving identity from the generic terminal title.
COMMAND="$(shell_quote "$CODEX_BIN") --no-alt-screen --dangerously-bypass-approvals-and-sandbox $(shell_quote "$BOOTSTRAP_PROMPT")"
lab pane run "$PANE" "$COMMAND" >/dev/null || fail "could not launch real Codex"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-session-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-title-lib.sh"

EXPECTED_DISPLAY='Darwin · FM · External workspace'
EXPECTED_TERMINAL_TITLE="$EXPECTED_DISPLAY | codex"
EXPECTED_HEADER_SUFFIX="Codex | $EXPECTED_DISPLAY"
agent_json=
pane_json=
pre_terminal_title=
pre_header=
SESSION_ID=
i=0
while [ "$i" -lt 120 ]; do
  agent_json=$(lab agent get "$PANE" 2>/dev/null || true)
  SESSION_ID=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true)
  if [ "$(printf '%s' "$agent_json" | jq -r '.result.agent.agent // empty' 2>/dev/null)" = codex ] \
     && fm_codex_session_uuid_valid "$SESSION_ID"; then
    break
  fi
  i=$((i + 1))
  sleep 0.5
done
if [ "$i" -ge 120 ]; then
  observed_screen=$(lab pane read "$PANE" --source recent --lines 120 2>/dev/null || true)
  fail "real Codex never exposed a canonical agent_session.value in the Herdr lab (agent=$agent_json screen=$observed_screen)"
fi
fm_codex_session_uuid_valid "$SESSION_ID" \
  || fail "Herdr agent_session.value was not a canonical lowercase UUID: $SESSION_ID"
pane_json=$(lab pane get "$PANE" 2>/dev/null || true)
pre_terminal_title=$(printf '%s' "$pane_json" | jq -r '.result.pane.terminal_title // empty' 2>/dev/null || true)
pre_header=$(printf '%s' "$pane_json" | jq -r '.result.pane.title // empty' 2>/dev/null || true)
[ "$pre_terminal_title" != "$EXPECTED_DISPLAY" ] \
  && [ "$pre_terminal_title" != "$EXPECTED_TERMINAL_TITLE" ] \
  || fail "pre-rename Herdr title was already the assigned Firstmate display title"
case "$pre_header" in
  *"$EXPECTED_HEADER_SUFFIX") fail "pre-rename Herdr header was already the assigned Firstmate display title" ;;
esac

FM_CODEX_TITLE_READY_POLLS=120 FM_CODEX_TITLE_POLL_INTERVAL=0.5 FM_ROOT="$ROOT" \
  fm_codex_title_deliver herdr "$TARGET" fm-codextitle Darwin FM 'External workspace' launch-brief "$BRIEF" \
  || fail "Firstmate Codex title adapter failed on real Codex/Herdr"

header=
terminal_title=
after_uuid=
i=0
while [ "$i" -lt 30 ]; do
  agent_json=$(lab agent get "$PANE" 2>/dev/null || true)
  after_uuid=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true)
  pane_json=$(lab pane get "$PANE" 2>/dev/null || true)
  terminal_title=$(printf '%s' "$pane_json" | jq -r '.result.pane.terminal_title // empty' 2>/dev/null || true)
  header=$(printf '%s' "$pane_json" | jq -r '.result.pane.title // empty' 2>/dev/null || true)
  [ "$after_uuid" = "$SESSION_ID" ] \
    || fail "conversation UUID changed during rename (expected $SESSION_ID, got ${after_uuid:-none})"
  case "$header" in *"$EXPECTED_HEADER_SUFFIX") header_matches=true ;; *) header_matches=false ;; esac
  [ "$terminal_title" = "$EXPECTED_TERMINAL_TITLE" ] && [ "$header_matches" = true ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$terminal_title" = "$EXPECTED_TERMINAL_TITLE" ] \
  || fail "Herdr terminal title did not follow the Codex conversation title (got: $terminal_title)"
case "$header" in
  *"$EXPECTED_HEADER_SUFFIX") ;;
  *) fail "Herdr existing header did not follow the Codex conversation title (got: $header)" ;;
esac

# Wait for the short verification turn to return to a real empty composer, then
# exit only the Codex process. This is not a Herdr lifecycle operation and still
# travels through the helper as required.
i=0
while [ "$i" -lt 120 ]; do
  [ "$(fm_backend_composer_state herdr "$TARGET" fm-codextitle 2>/dev/null)" = empty ] && break
  i=$((i + 1))
  sleep 0.5
done
[ "$i" -lt 120 ] || fail "Codex verification turn did not return to an empty composer"
lab pane send-text "$PANE" /quit >/dev/null || fail "could not type /quit through isolated helper"
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit /quit through isolated helper"
i=0
while [ "$i" -lt 40 ]; do
  lab agent get "$PANE" >/dev/null 2>&1 || break
  i=$((i + 1))
  sleep 0.25
done
[ "$i" -lt 40 ] || fail "Codex did not exit before exact resume"

RESUME_COMMAND="$(shell_quote "$CODEX_BIN") resume --no-alt-screen --dangerously-bypass-approvals-and-sandbox $(shell_quote "$SESSION_ID")"
lab pane run "$PANE" "$RESUME_COMMAND" >/dev/null || fail "could not exact-resume UUID $SESSION_ID"

FM_CODEX_TITLE_READY_POLLS=120 FM_CODEX_TITLE_POLL_INTERVAL=0.5 FM_ROOT="$ROOT" \
  fm_codex_title_deliver herdr "$TARGET" fm-codextitle Darwin FM 'External workspace' resume-note "$RESUME_NOTE" \
  || fail "title reassertion failed after exact Codex resume"
after_uuid=
i=0
while [ "$i" -lt 120 ]; do
  agent_json=$(lab agent get "$PANE" 2>/dev/null || true)
  after_uuid=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true)
  [ -z "$after_uuid" ] || [ "$after_uuid" = "$SESSION_ID" ] \
    || fail "exact resume changed the conversation UUID (expected $SESSION_ID, got $after_uuid)"
  pane_json=$(lab pane get "$PANE" 2>/dev/null || true)
  terminal_title=$(printf '%s' "$pane_json" | jq -r '.result.pane.terminal_title // empty' 2>/dev/null || true)
  header=$(printf '%s' "$pane_json" | jq -r '.result.pane.title // empty' 2>/dev/null || true)
  case "$header" in *"$EXPECTED_HEADER_SUFFIX") header_matches=true ;; *) header_matches=false ;; esac
  [ "$after_uuid" = "$SESSION_ID" ] \
    && [ "$terminal_title" = "$EXPECTED_TERMINAL_TITLE" ] \
    && [ "$header_matches" = true ] \
    && break
  i=$((i + 1))
  sleep 0.25
done
[ "$terminal_title" = "$EXPECTED_TERMINAL_TITLE" ] \
  || fail "exact resume terminal title drifted (got: $terminal_title)"
case "$header" in
  *"$EXPECTED_HEADER_SUFFIX") ;;
  *) fail "exact resume Herdr header drifted (got: $header)" ;;
esac
[ "$after_uuid" = "$SESSION_ID" ] \
  || fail "exact resume did not republish the same conversation UUID (expected $SESSION_ID, got ${after_uuid:-none})"

pass "$CODEX_VERSION on $HERDR_VERSION preserved agent_session.value across rename/resume while Herdr followed automatically without terminal_title identity inference"
