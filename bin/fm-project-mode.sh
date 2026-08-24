#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                  -> legacy: no-mistakes off, no code
#   - <name> [<mode>] [code=<CODE>] - <desc> (added <date>)            -> <mode> off, stable code
#   - <name> [<mode> +yolo] [code=<CODE>] - <desc> (added <date>)      -> <mode> on, stable code
# ProjectCode is a unique 2-8 character uppercase ASCII acronym beginning with a
# letter. It is explicit project identity, not derived from the project name.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# --code prints the registered ProjectCode only. A missing registry, project,
# code, malformed code, or duplicate code is an error: presentation identity is
# never guessed. Legacy posture resolution remains compatible and unchanged.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw|--code] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
CODE=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --code) CODE=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--code] <project-name>}

# shellcheck source=bin/fm-display-title-lib.sh
. "$SCRIPT_DIR/fm-display-title-lib.sh"

if [ "$CODE" -eq 1 ]; then
  [ -f "$REG" ] || { echo "error: no project registry at $REG; cannot resolve a stable ProjectCode for $NAME" >&2; exit 1; }
  project_line=$(awk -v n="$NAME" '$1 == "-" && $2 == n { print; found=1; exit } END { if (!found) exit 1 }' "$REG") || {
    echo "error: project \"$NAME\" is not registered; cannot resolve its stable ProjectCode" >&2
    exit 1
  }
  project_code=$(printf '%s\n' "$project_line" | awk '
    {
      for (i=3; i<=NF; i++) {
        if ($i ~ /^\[code=[^]]+\]$/) {
          value=$i; sub(/^\[code=/, "", value); sub(/\]$/, "", value)
          count++; code=value
        }
      }
    }
    END { if (count == 1) print code; else exit 1 }
  ') || {
    echo "error: project \"$NAME\" has no single [code=<CODE>] annotation in $REG" >&2
    exit 1
  }
  fm_display_project_code_valid "$project_code" || {
    echo "error: project \"$NAME\" has invalid ProjectCode '$project_code'; expected 2-8 uppercase ASCII letters/digits beginning with a letter" >&2
    exit 1
  }
  duplicates=$(awk -v wanted="[code=$project_code]" '
    $1 == "-" {
      for (i=3; i<=NF; i++) if ($i == wanted) { n++; names = names (names ? ", " : "") $2 }
    }
    END { if (n > 1) print names }
  ' "$REG")
  [ -z "$duplicates" ] || {
    echo "error: ProjectCode '$project_code' is not unique in $REG (projects: $duplicates)" >&2
    exit 1
  }
  printf '%s\n' "$project_code"
  exit 0
fi

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
