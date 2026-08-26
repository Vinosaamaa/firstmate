#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id or persistent callsign.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit [--resumable]
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         [--resume]
#                                         (--note <text> | --note-file <path>)
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent).
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. With no explicit axis, a secondmate re-resolves its
#              durable config/secondmate-harness pin (harness plus its optional
#              model and effort tokens) exactly as any other respawn does, while
#              a ship or scout keeps the exact adapter already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# Exact Codex conversation resume is an opt-in specialization of the existing
# verbs, not another verb. `exit --resumable` captures the one exact session id
# printed by Codex after /quit. `relaunch --resume` consumes only that task's
# exact parked binding through the same transaction and endpoint/worktree
# checks as ordinary relaunch. Both flags are Codex ship-task only. Ordinary
# exit/relaunch, fresh spawn, scouts, secondmates, and every other harness keep
# the disposable brief-plus-note behavior above.
#
# Targeting is EXACT: a persistent callsign resolves through the home-owned
# identity registry to exactly one task id before endpoint validation. A bare
# task id remains supported. Missing, ambiguous, archived-only, conflicting,
# explicit session:window, and bare window targets are refused.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
#   FM_CONTROL_CODEX_CAPTURE_LINES bounded before/after exit capture (400)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-identity-lib.sh
. "$SCRIPT_DIR/fm-identity-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-codex-session-lib.sh
. "$SCRIPT_DIR/fm-codex-session-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}
CODEX_CAPTURE_LINES=${FM_CONTROL_CODEX_CAPTURE_LINES:-400}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts a callsign or exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
  fm-*)
    if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
      die "'$RAW_ID' is a legacy window label, not a callsign or exact task id; pass the exact task id '${RAW_ID#fm-}' or that task's callsign"
    fi
    ;;
esac
# A supervision lease is keyed by the exact task id, so check it before
# selector resolution can reject an unregistered-but-live task id. Restrict
# this early probe to canonical ids so arbitrary selector text never becomes a
# filesystem path.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if fm_task_id_creation_valid "$RAW_ID" \
  && { [ -e "$STATE/.lease-$RAW_ID" ] || [ -L "$STATE/.lease-$RAW_ID" ]; }; then
  fm_lease_guard "$RAW_ID" "lifecycle control (fm-control)"
fi
ID=$(fm_identity_resolve_selector "$STATE" "$RAW_ID") || exit 1
CALLSIGN=$(fm_identity_display_callsign "$ID")

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: resume resolved $CALLSIGN ($ID), but exact-thread resume is not installed for this task. Use 'relaunch' for a fresh replacement, or the resumable-crewmate command when that opt-in capability owns the recorded harness session."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
RESUMABLE_EXIT=0
RESUME_RELAUNCH=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) die "--$want_value requires a value" ;;
    esac
    case "$want_value" in
      harness) NEW_HARNESS=$a; HARNESS_SET=1 ;;
      model) NEW_MODEL=$a; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$a; EFFORT_SET=1 ;;
      note) NOTE=$a; NOTE_SET=1 ;;
      note-file)
        [ -f "$a" ] || die "--note-file '$a' is not a readable file"
        NOTE=$(cat "$a")
        NOTE_SET=1
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --harness) want_value=harness ;;
    --harness=*) NEW_HARNESS=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) NEW_MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) NEW_EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --note) want_value=note ;;
    --note=*) NOTE=${a#--note=}; NOTE_SET=1 ;;
    --note-file) want_value=note-file ;;
    --note-file=*)
      [ -f "${a#--note-file=}" ] || die "--note-file '${a#--note-file=}' is not a readable file"
      NOTE=$(cat "${a#--note-file=}")
      NOTE_SET=1
      ;;
    --resumable) RESUMABLE_EXIT=1 ;;
    --resume) RESUME_RELAUNCH=1 ;;
    *) die "unexpected argument '$a'" ;;
  esac
done
[ -z "$want_value" ] || die "--$want_value requires a value"

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, and --note apply to 'relaunch' only"
fi
[ "$RESUMABLE_EXIT" = 0 ] || [ "$VERB" = exit ] \
  || die "--resumable applies to 'exit' only"
[ "$RESUME_RELAUNCH" = 0 ] || [ "$VERB" = relaunch ] \
  || die "--resume applies to 'relaunch' only"
[ "$RESUMABLE_EXIT" = 0 ] || [ "$RESUME_RELAUNCH" = 0 ] \
  || die "--resumable and --resume cannot be combined"
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) die "--effort must be one of low, medium, high, xhigh, max" ;;
esac

# --- exact task identity resolution ----------------------------------------

if ! fm_task_id_creation_valid "$ID"; then
  die "resolved task id '$ID' is invalid"
fi
if [ ! -f "$(fm_identity_task_record "$ID")" ]; then
  CALLSIGN=$(fm_identity_display_callsign "$ID")
fi
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  die "no active task for $CALLSIGN ($ID) in $STATE"
fi
# Herdr control is also the recovery boundary for pre-callsign Herdr tasks.
# Allocate the persistent identity only after the lifecycle lock is held, while
# preserving exact-id compatibility for ordinary legacy workers.
if [ ! -f "$(fm_identity_task_record "$ID")" ] \
  && [ "$(fm_meta_get "$META" backend)" = herdr ]; then
  CALLSIGN=$(fm_identity_ensure_task_from_meta "$META" "$ID" legacy) \
    || die "could not publish the Herdr identity binding for task $ID"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

require_current_task_route() {
  local verified
  verified=$(fm_backend_target_of_meta "$META") \
    || die "task $ID's saved live-route identity no longer matches its endpoint; refusing lifecycle delivery"
  [ -n "$verified" ] && [ "$verified" = "$T" ] \
    || die "task $ID's saved live-route identity no longer matches its endpoint; refusing lifecycle delivery"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  require_current_task_route
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  if [ -f "$STATE/$ID.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped` or `stopped`.
do_exit() {
  local state cmd verdict cancel interrupt_result=not-needed
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing) die "task $ID's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action" ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  require_current_task_route
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  require_current_task_route
  cmd=$(fm_control_exit_command "$HARNESS")
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

codex_resume_supported_task() {
  [ "$HARNESS" = codex ] \
    || die "resumable lifecycle is available only for a task recorded on the exact verified codex adapter (task $ID records '${RECORDED_HARNESS:-none}')"
  [ "$KIND" = ship ] \
    || die "resumable lifecycle is available only for Codex ship tasks; $ID is kind=$KIND"
  [ -n "$(fm_meta_get "$META" spawn_gen)" ] \
    || die "task $ID has no recorded spawn_gen, so a Codex session cannot be bound to an exact agent incarnation"
}

# Capture only the bounded endpoint output immediately surrounding /quit.
# The parser accepts one newly-added exact Codex banner and rejects a stale,
# malformed, truncated, absent, or multiply-added candidate.
do_resumable_codex_exit() {
  local before after state result session status
  codex_resume_supported_task
  state=$(agent_state)
  if [ "$state" = dead ]; then
    session=$(fm_codex_session_validate "$STATE" "$ID" "$META" parked 2>/dev/null) \
      || die "task $ID is already stopped but has no exact parked Codex session binding for this task, endpoint, worktree, and spawn incarnation"
    printf 'already-parked session=%s' "$session"
    return 0
  fi
  [ "$state" = alive ] \
    || die "task $ID's endpoint reads '$state'; refusing to capture a Codex session from an unattributed endpoint"
  require_current_task_route
  before="$STATE/.$ID.codex-exit-before.${BASHPID:-$$}"
  after="$STATE/.$ID.codex-exit-after.${BASHPID:-$$}"
  rm -f "$before" "$after"
  if ! fm_backend_capture "$BACKEND" "$T" "$CODEX_CAPTURE_LINES" "$LABEL" > "$before"; then
    rm -f "$before" "$after"
    die "task $ID's bounded pre-exit Codex capture could not be read; the agent was left running"
  fi
  result=$(do_exit)
  if ! fm_backend_capture "$BACKEND" "$T" "$CODEX_CAPTURE_LINES" "$LABEL" > "$after"; then
    rm -f "$before" "$after"
    die "task $ID stopped, but its bounded post-exit Codex capture could not be read; no resumable binding was published"
  fi
  if session=$(fm_codex_session_parse_new_banner "$before" "$after"); then
    status=0
  else
    status=$?
  fi
  rm -f "$before" "$after"
  if [ "$status" -ne 0 ] || ! fm_codex_session_uuid_valid "$session"; then
    die "task $ID stopped, but Codex did not add exactly one authoritative canonical session-id banner; no resumable binding was published"
  fi
  fm_codex_session_publish "$STATE" "$ID" "$META" "$session" parked \
    || die "task $ID stopped, but its exact Codex session $session could not be claimed without conflicting with another task or binding; no resumable binding was published"
  printf '%s session=%s' "$result" "$session"
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
RELAUNCH_RESUME_SESSION=
RELAUNCH_RESUME_ATTEMPT=
RELAUNCH_RESUME_LAUNCH_UNCERTAIN=0
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state binding
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  if [ "$RESUME_RELAUNCH" = 1 ]; then
    case "$RELAUNCH_PHASE" in
      checkpoint|noted)
        if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
          cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
        fi
        journal_write "failed:$RELAUNCH_PHASE" "rollback=resume-prelaunch" || true
        echo "error: resumable relaunch of $ID failed before an exact resume launch was prepared; its prior instructions and binding were preserved" >&2
        return 0
        ;;
      stopping)
        if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
          cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
        fi
        state=$(agent_state 2>/dev/null || printf unknown)
        binding=$(fm_codex_session_validate "$STATE" "$ID" "$META" parked 2>/dev/null || true)
        if [ -n "$binding" ]; then
          journal_write "failed:$RELAUNCH_PHASE" "rollback=resume-parked-agent-state-$state" || true
          echo "error: resumable relaunch of $ID failed while stopping or capturing the old agent; no exact resume launch was attempted, agent-state=$state, and exact session $binding remains parked" >&2
        else
          journal_write "failed:$RELAUNCH_PHASE" "rollback=resume-none-agent-state-$state" || true
          echo "error: resumable relaunch of $ID failed while stopping or capturing the old agent; no exact resume launch was attempted, agent-state=$state, and no valid parked binding was published" >&2
        fi
        return 0
        ;;
      exited)
        journal_write "failed:$RELAUNCH_PHASE" "rollback=resume-parked" || true
        echo "error: $ID's Codex session was parked, but relaunch did not reach replacement launch; the exact binding remains parked" >&2
        return 0
        ;;
      launching)
        if [ "$RELAUNCH_RESUME_LAUNCH_UNCERTAIN" = 1 ]; then
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-resume-uncertain" || true
          echo "error: exact Codex resume launch for $ID may have started but was not confirmed; the binding is uncertain and speculative retry is refused" >&2
        else
          journal_write "failed:$RELAUNCH_PHASE" "rollback=resume-parked-before-launch" || true
          echo "error: exact Codex resume launch for $ID failed before launch bytes were sent; the parked binding was preserved" >&2
        fi
        return 0
        ;;
    esac
  fi
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state'; the durable record and progress note were retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    [ -d "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    find "$WT/state" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1 \
      || die "secondmate $ID's child records cannot be traversed; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

# Reconcile a prior process crash at the exact-session launch boundary before
# starting a new lifecycle transaction. Only a dead endpoint with an absent or
# merely prepared attempt is provably pre-launch and may return to parked. Once
# launch bytes may have been sent, or the endpoint is not positively dead, the
# binding becomes uncertain and no caller may speculate by launching it again.
codex_resume_reconcile_prior_attempt() {
  local session='' binding_meta='' attempt="$JOURNAL.resume-attempt" attempt_phase state
  if session=$(fm_codex_session_validate "$STATE" "$ID" "$META" resuming 2>/dev/null); then
    binding_meta=$META
  elif [ -f "$META_PRIOR" ] \
       && session=$(fm_codex_session_validate "$STATE" "$ID" "$META_PRIOR" resuming 2>/dev/null); then
    binding_meta=$META_PRIOR
  else
    if fm_codex_session_validate "$STATE" "$ID" "$META" uncertain >/dev/null 2>&1 \
       || { [ -f "$META_PRIOR" ] \
            && fm_codex_session_validate "$STATE" "$ID" "$META_PRIOR" uncertain >/dev/null 2>&1; }; then
      die "task $ID has an uncertain exact Codex resume binding from a prior launch; speculative retry is refused"
    fi
    return 0
  fi

  attempt_phase=$(cat "$attempt" 2>/dev/null || true)
  state=$(agent_state)
  case "$state:$attempt_phase" in
    dead:|dead:prepared)
      if [ "$binding_meta" = "$META_PRIOR" ]; then
        cp -p "$META_PRIOR" "$META" \
          || die "task $ID has a safely recoverable pre-launch Codex resume, but its prior task record could not be restored"
        binding_meta=$META
      fi
      fm_codex_session_transition "$STATE" "$ID" "$binding_meta" resuming parked >/dev/null \
        || die "task $ID has a pre-launch Codex resume record that could not be restored to parked safely"
      rm -f "$attempt"
      ;;
    *)
      fm_codex_session_transition "$STATE" "$ID" "$binding_meta" resuming uncertain >/dev/null \
        || die "task $ID has an in-flight Codex resume record that could not be marked uncertain safely"
      die "prior exact Codex resume launch for task $ID is uncertain (attempt=${attempt_phase:-absent}, agent-state=$state); speculative retry is refused"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line attempt_phase current_tx
  local -a spawn_args

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  if [ "$RESUME_RELAUNCH" = 1 ]; then
    codex_resume_supported_task
    [ "$TARGET_HARNESS" = codex ] \
      || die "--resume cannot switch task $ID away from Codex; exact-session resume requires both the recorded and target harness to be codex"
    codex_resume_reconcile_prior_attempt
  fi

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  if [ "$RESUME_RELAUNCH" = 1 ]; then
    exit_result=$(do_resumable_codex_exit)
    RELAUNCH_RESUME_SESSION=${exit_result##*session=}
    fm_codex_session_uuid_valid "$RELAUNCH_RESUME_SESSION" \
      || die "task $ID did not produce an exact resumable Codex session id"
  else
    exit_result=$(do_exit)
    if [ -e "$STATE/$ID.codex-session" ] || [ -L "$STATE/$ID.codex-session" ]; then
      fm_codex_session_retire "$STATE" "$ID" \
        || die "task $ID stopped, but its prior Codex session binding could not be retired safely before disposable relaunch"
    fi
  fi
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result" \
    "resume_session=${RELAUNCH_RESUME_SESSION:-none}"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  if [ "$RESUME_RELAUNCH" = 1 ]; then
    RELAUNCH_RESUME_SESSION=$(fm_codex_session_transition \
      "$STATE" "$ID" "$META" parked resuming) \
      || die "task $ID's parked Codex session binding changed before resume launch; refusing"
    RELAUNCH_RESUME_ATTEMPT="$JOURNAL.resume-attempt"
    rm -f "$RELAUNCH_RESUME_ATTEMPT"
  fi
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX" \
    "resume_session=${RELAUNCH_RESUME_SESSION:-none}"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if [ "$RESUME_RELAUNCH" = 1 ]; then
    spawn_args+=(--resume-codex-session "$RELAUNCH_RESUME_SESSION" \
      --resume-note-file "$NOTE_FILE")
  fi
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      FM_CONTROL_CODEX_RESUME_ATTEMPT="$RELAUNCH_RESUME_ATTEMPT" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    if [ "$RESUME_RELAUNCH" = 1 ]; then
      attempt_phase=$(cat "$RELAUNCH_RESUME_ATTEMPT" 2>/dev/null || true)
      current_tx=$(fm_meta_get "$META" control_relaunch_tx)
      case "$attempt_phase" in
        launching|submitted)
          RELAUNCH_RESUME_LAUNCH_UNCERTAIN=1
          if [ "$current_tx" = "$RELAUNCH_TX" ]; then
            fm_codex_session_rebind "$STATE" "$ID" "$META_PRIOR" "$META" resuming uncertain >/dev/null 2>&1 || true
          else
            fm_codex_session_transition "$STATE" "$ID" "$META_PRIOR" resuming uncertain >/dev/null 2>&1 || true
          fi
          ;;
        *)
          if [ "$current_tx" = "$RELAUNCH_TX" ]; then
            fm_codex_session_rebind "$STATE" "$ID" "$META_PRIOR" "$META" resuming parked >/dev/null 2>&1 || {
              RELAUNCH_RESUME_LAUNCH_UNCERTAIN=1
            }
          else
            fm_codex_session_transition "$STATE" "$ID" "$META_PRIOR" resuming parked >/dev/null 2>&1 || {
              RELAUNCH_RESUME_LAUNCH_UNCERTAIN=1
            }
          fi
          ;;
      esac
    fi
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    if [ "$RESUME_RELAUNCH" = 1 ]; then
      RELAUNCH_RESUME_LAUNCH_UNCERTAIN=1
      fm_codex_session_rebind "$STATE" "$ID" "$META_PRIOR" "$META" resuming uncertain >/dev/null 2>&1 || true
    fi
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  if [ "$RESUME_RELAUNCH" = 1 ]; then
    if ! fm_codex_session_rebind "$STATE" "$ID" "$META_PRIOR" "$META" resuming live >/dev/null; then
      RELAUNCH_RESUME_LAUNCH_UNCERTAIN=1
      fm_codex_session_rebind "$STATE" "$ID" "$META_PRIOR" "$META" resuming uncertain >/dev/null 2>&1 || true
      die "the exact Codex session for $ID is running, but its new spawn incarnation could not be published; the binding is uncertain and speculative retry is refused"
    fi
  fi

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result" \
    "resume_session=${RELAUNCH_RESUME_SESSION:-none}"
  RELAUNCH_ACTIVE=0
  rm -f "$RELAUNCH_RESUME_ATTEMPT"
  if [ "$RESUME_RELAUNCH" = 1 ]; then
    echo "resumed $CALLSIGN ($ID) session=$RELAUNCH_RESUME_SESSION harness=codex model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
  else
    echo "relaunched $CALLSIGN ($ID) harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
  fi
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $CALLSIGN ($ID) harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    if [ "$RESUMABLE_EXIT" = 1 ]; then
      result=$(do_resumable_codex_exit)
    else
      result=$(do_exit)
      if [ -e "$STATE/$ID.codex-session" ] || [ -L "$STATE/$ID.codex-session" ]; then
        fm_codex_session_retire "$STATE" "$ID" \
          || die "task $ID stopped, but its prior Codex session binding could not be retired safely"
      fi
    fi
    echo "$result $CALLSIGN ($ID) harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
esac
