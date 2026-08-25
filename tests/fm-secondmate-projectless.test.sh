#!/usr/bin/env bash
# Focused executable-interface coverage for project-less secondmate launch.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-projectless)

test_projectless_seed_and_spawn() {
  local home sub sub_abs fakebin log meta projects_value out err
  home="$TMP_ROOT/parent-home"
  sub="$TMP_ROOT/projectless-home"
  mkdir -p "$home/data" "$home/projects" "$home/state"
  fakebin=$(make_fake_tmux "$TMP_ROOT/fake")
  log="$TMP_ROOT/fake/tmux.log"
  err="$TMP_ROOT/spawn.err"

  out=$(FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-home-seed.sh" fdev "$sub" --no-projects) \
    || fail "project-less seed failed"
  sub_abs=$(cd "$sub" && pwd -P)
  assert_contains "$out" "home=$sub_abs" "project-less seed did not report the canonical home"
  assert_grep 'projects: ;' "$home/data/secondmates.md" \
    "project-less seed did not persist an empty project list"
  assert_present "$sub/data/charter.md" "project-less seed did not copy the charter"
  [ -z "$(find "$sub/projects" -mindepth 1 -maxdepth 1 -print)" ] \
    || fail "project-less seed created a project clone"

  : > "$log"
  if ! PATH="$fakebin:$PATH" FM_BACKEND=tmux FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" fdev "$sub" codex --secondmate > /dev/null 2>"$err"; then
    fail "project-less secondmate spawn failed: $(sed -n '1,12p' "$err")"
  fi
  meta="$home/state/fdev.meta"
  [ -f "$meta" ] || fail "project-less spawn did not publish $meta"
  grep -F 'kind=secondmate' "$meta" >/dev/null \
    || fail "project-less spawn lost its secondmate kind: $(sed -n '1,18p' "$meta")"
  grep -F "home=$sub_abs" "$meta" >/dev/null \
    || fail "project-less spawn lost its canonical home: $(sed -n '1,18p' "$meta")"
  projects_value=$(sed -n 's/^projects=//p' "$meta")
  [ -z "$projects_value" ] || fail "project-less spawn recorded projects='$projects_value'"
  pass "secondmate project-less: empty project routing remains launch-compatible"
}

test_projectless_seed_and_spawn
printf 'All fm-secondmate project-less tests passed.\n'
