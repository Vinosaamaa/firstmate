#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-cursor-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_pane_identity: resolve one exact pane directly and publish its
# stable pane id and tty for spawn-time metadata binding.
fm_backend_tmux_pane_identity() {  # <target>
  local target=$1 observed pane tty
  FM_BACKEND_TMUX_PANE_ID=
  FM_BACKEND_TMUX_PANE_TTY=
  observed=$(tmux display-message -p -t "$target" '#{pane_id}|#{pane_tty}' 2>/dev/null) || return 1
  pane=${observed%%|*}
  tty=${observed#*|}
  case "$pane:$tty" in
    %*[0-9]:/dev/*) ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2034 # Output globals are consumed by fm-spawn.sh.
  FM_BACKEND_TMUX_PANE_ID=$pane
  # shellcheck disable=SC2034 # Output globals are consumed by fm-spawn.sh.
  FM_BACKEND_TMUX_PANE_TTY=$tty
}

# fm_backend_tmux_process_sample: sample one saved pid directly.
# The fixed-width lstart fields make the result portable across macOS and Linux.
fm_backend_tmux_process_sample() {  # <pid>
  local wanted=$1 out pid start tty comm args argv0
  FM_BACKEND_TMUX_AGENT_PID=
  FM_BACKEND_TMUX_AGENT_START=
  FM_BACKEND_TMUX_AGENT_TTY=
  FM_BACKEND_TMUX_AGENT_COMM=
  FM_BACKEND_TMUX_AGENT_ARGV0=
  case "$wanted" in ''|*[!0-9]*) return 1 ;; esac
  out=$(LC_ALL=C ps -p "$wanted" -o pid=,lstart=,tty=,comm= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  # shellcheck disable=SC2086 # ps fields are intentionally split into positional fields.
  set -- $out
  [ "$#" -ge 8 ] || return 1
  pid=$1
  start="$2 $3 $4 $5 $6"
  tty=$7
  shift 7
  comm=$*
  [ "$pid" = "$wanted" ] && [ -n "$tty" ] && [ -n "$comm" ] || return 1
  args=$(LC_ALL=C ps -p "$wanted" -o args= 2>/dev/null) || return 1
  args=${args#"${args%%[![:space:]]*}"}
  if [ -r "/proc/$wanted/cmdline" ]; then
    argv0=$(LC_ALL=C tr '\0' '\n' < "/proc/$wanted/cmdline" 2>/dev/null | sed -n '1p')
  else
    case "$args" in
      "$comm"|"$comm "*) argv0=$comm ;;
      *) argv0=${args%%[[:space:]]*} ;;
    esac
  fi
  [ -n "$argv0" ] || return 1
  # shellcheck disable=SC2034 # Output globals are consumed by binding/verification callers.
  FM_BACKEND_TMUX_AGENT_PID=$pid
  # shellcheck disable=SC2034 # Output globals are consumed by binding/verification callers.
  FM_BACKEND_TMUX_AGENT_START=$start
  # shellcheck disable=SC2034 # Output globals are consumed by binding/verification callers.
  FM_BACKEND_TMUX_AGENT_TTY=$tty
  # shellcheck disable=SC2034 # Output globals are consumed by binding/verification callers.
  FM_BACKEND_TMUX_AGENT_COMM=$comm
  # shellcheck disable=SC2034 # Output globals are consumed by binding/verification callers.
  FM_BACKEND_TMUX_AGENT_ARGV0=$argv0
}

# fm_backend_tmux_discover_agent_identity: one spawn-time process discovery on
# the exact pane tty.
# Normal routing never calls this function: it queries only the saved pid.
fm_backend_tmux_discover_agent_identity() {  # <target>
  local target=$1 rows pid pgid tpgid comm argv0 candidate=
  fm_backend_tmux_pane_identity "$target" || return 1
  rows=$(LC_ALL=C ps -t "${FM_BACKEND_TMUX_PANE_TTY#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null) || return 1
  while read -r pid pgid tpgid; do
    [ -n "$pid" ] && [ "$pgid" = "$tpgid" ] || continue
    fm_backend_tmux_process_sample "$pid" || continue
    comm=$FM_BACKEND_TMUX_AGENT_COMM
    argv0=$FM_BACKEND_TMUX_AGENT_ARGV0
    if [ "$(fm_backend_tmux_classify_process_name "$comm" "$argv0")" != agent ]; then
      continue
    fi
    candidate=$pid
    [ "$pid" = "$pgid" ] && return 0
  done <<EOF
$rows
EOF
  [ -n "$candidate" ] || return 1
  fm_backend_tmux_process_sample "$candidate"
}

# fm_backend_tmux_verify_task_identity: constant-time live-route verification.
# It resolves the saved pane id directly, then the saved pid directly; it never
# scans tmux windows, discovers another process, mutates metadata, or launches.
fm_backend_tmux_verify_task_identity() {  # <meta-file>
  local meta=$1 id pane tty pid start comm argv0 observed saved_ps_tty
  id=$(fm_meta_get "$meta" endpoint_task_id)
  pane=$(fm_backend_meta_exact_value "$meta" tmux_pane_id) || pane=
  tty=$(fm_backend_meta_exact_value "$meta" tmux_pane_tty) || tty=
  pid=$(fm_backend_meta_exact_value "$meta" tmux_agent_pid) || pid=
  start=$(fm_backend_meta_exact_value "$meta" tmux_agent_start) || start=
  comm=$(fm_backend_meta_exact_value "$meta" tmux_agent_comm) || comm=
  argv0=$(fm_backend_meta_exact_value "$meta" tmux_agent_argv0) || argv0=
  case "$pane:$tty:$pid" in
    %*[0-9]:/dev/*:[0-9]*) ;;
    *) echo "error: tmux live-route identity for task ${id:-unknown} is incomplete or malformed" >&2; return 1 ;;
  esac
  observed=$(tmux display-message -p -t "$pane" '#{pane_id}|#{pane_tty}' 2>/dev/null) || {
    echo "error: tmux live-route identity for task ${id:-unknown} is lost: saved pane $pane is missing" >&2
    return 1
  }
  [ "$observed" = "$pane|$tty" ] || {
    echo "error: tmux live-route identity for task ${id:-unknown} is lost: pane tty changed" >&2
    return 1
  }
  fm_backend_tmux_process_sample "$pid" || {
    echo "error: tmux live-route identity for task ${id:-unknown} is lost: saved agent pid $pid is missing" >&2
    return 1
  }
  saved_ps_tty=${tty#/dev/}
  if [ "$FM_BACKEND_TMUX_AGENT_START" != "$start" ] \
     || [ "$FM_BACKEND_TMUX_AGENT_TTY" != "$saved_ps_tty" ] \
     || [ "$FM_BACKEND_TMUX_AGENT_COMM" != "$comm" ] \
     || [ "$FM_BACKEND_TMUX_AGENT_ARGV0" != "$argv0" ] \
     || [ "$(fm_backend_tmux_classify_process_name "$FM_BACKEND_TMUX_AGENT_COMM" "$FM_BACKEND_TMUX_AGENT_ARGV0")" != agent ]; then
    echo "error: tmux live-route identity for task ${id:-unknown} is lost: saved pid/start-time/tty/agent identity no longer matches" >&2
    return 1
  fi
  printf '%s' "$pane"
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
  case "$target" in
    %*[0-9])
      [ "$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)" = "$target" ] || return 0
      tmux kill-pane -t "$target" 2>/dev/null || true
      return 0
      ;;
  esac
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal below - `agent` for a verified
# harness, `shell` for an idle login/interactive shell, `other` for anything
# else. Keeping one classifier means the two independent name sources can never
# drift into disagreeing about what a given name means.
fm_backend_tmux_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers above fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status observed observed_pane
  local foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    %*[0-9])
      # Read the pane id together with its tty so this exact-target probe also
      # works with tmux implementations that only expose a stable pane
      # identity through a compound format. The first field remains the sole
      # membership proof; a fallback active pane can never satisfy it.
      observed=$(tmux display-message -p -t "$target" '#{pane_id}|#{pane_tty}' 2>/dev/null) || {
        printf 'missing'
        return 0
      }
      observed_pane=${observed%%|*}
      [ "$observed_pane" = "$target" ] || { printf 'unreadable'; return 0; }
      ;;
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if [ "${target#%}" = "$target" ]; then
    session=${target%%:*}
    window=${target#*:}
    if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
      inventory_status=0
    else
      inventory_status=$?
    fi
    if [ "$inventory_status" -ne 0 ]; then
      case "$windows" in
        *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
          printf 'missing'
          ;;
        *)
          printf 'unreadable'
          ;;
      esac
      return 0
    fi
    if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
      printf 'missing'
      return 0
    fi
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_backend_tmux_classify_process_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_backend_tmux_classify_process_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_tmux_classify_process_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
