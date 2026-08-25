#!/usr/bin/env bash
# Executable-interface tests for clone-free secondmate workspace provisioning.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-workspace)
PARENT="$TMP_ROOT/main-home"
CHILD="$TMP_ROOT/secondmate-home"
OUTER="$TMP_ROOT/Interview Prep"

setup_world() {
  mkdir -p "$PARENT/data" "$PARENT/projects" "$PARENT/state" "$OUTER"
  OUTER=$(cd "$OUTER" && pwd -P)
  mark_firstmate_home "$CHILD"
  mkdir -p "$CHILD/data" "$CHILD/projects" "$CHILD/state" "$CHILD/config"
  fm_git_init_commit "$OUTER/interview-arc"
  fm_git_init_commit "$OUTER/interview-arc-live"
  fm_git_init_commit "$OUTER/interview-arc-voice"
  FM_HOME="$PARENT" "$ROOT/bin/fm-workspace.sh" add interview-prep \
    --root "$OUTER" \
    --scope 'Interview preparation across Arc, Live, and Voice.' \
    --member "arc=$OUTER/interview-arc" \
    --member "live=$OUTER/interview-arc-live" \
    --member "voice=$OUTER/interview-arc-voice" >/dev/null
}

test_workspace_charter_and_seed() {
  local out child_abs
  FM_HOME="$PARENT" \
    FM_SECONDMATE_CHARTER='Coordinate Interview Prep across Arc, Live, and Voice.' \
    FM_SECONDMATE_SCOPE='Interview Prep product and practice work.' \
    "$ROOT/bin/fm-brief.sh" interview-prep --secondmate --workspace interview-prep >/dev/null \
    || fail "workspace-backed secondmate charter scaffold failed"

  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" interview-prep "$CHILD" --workspace interview-prep) \
    || fail "workspace-backed secondmate seed failed"
  child_abs=$(cd "$CHILD" && pwd -P)
  assert_contains "$out" "home=$child_abs" "workspace seed did not report the persistent home"
  assert_present "$PARENT/data/workspaces/interview-prep.workspace" "workspace seed removed the main-home pointer"
  assert_present "$CHILD/data/workspaces/interview-prep.workspace" "workspace seed did not copy the pointer into the secondmate home"
  cmp -s "$PARENT/data/workspaces/interview-prep.workspace" "$CHILD/data/workspaces/interview-prep.workspace" \
    || fail "workspace seed changed the validated pointer bytes"
  assert_grep '# Workspace pointers' "$CHILD/data/charter.md" "workspace charter omitted its pointer section"
  assert_grep '- interview-prep' "$CHILD/data/charter.md" "workspace charter omitted the selected workspace"
  assert_grep 'does not duplicate its member repositories' "$CHILD/data/charter.md" "workspace charter did not preserve the clone-free contract"
  [ -z "$(find "$CHILD/projects" -mindepth 1 -maxdepth 1 -print)" ] \
    || fail "workspace seed created duplicate project clones"
  assert_absent "$CHILD/data/projects.md" "workspace seed created a managed-project registry"
  assert_absent "$CHILD/data/.workspace-copy-receipts" "successful workspace seed retained a copy receipt"
  assert_absent "$CHILD.fm-home-seed.lock" "successful workspace seed retained its target-home claim"
  assert_grep 'projects: ;' "$PARENT/data/secondmates.md" "workspace-backed route claimed project clones"
  [ "$(FM_HOME="$CHILD" "$ROOT/bin/fm-workspace.sh" resolve interview-prep live --path)" = "$OUTER/interview-arc-live" ] \
    || fail "secondmate home did not resolve the copied workspace member"
  FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "secondmate registry rejected the workspace-backed home"
  pass "secondmate workspace: persistent home receives the pointer and no duplicate clones"
}

test_workspace_source_shapes_are_exclusive() {
  local home out rc
  home="$TMP_ROOT/exclusive-home"
  mkdir -p "$home/data" "$home/projects" "$home/state"

  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='bad' \
    "$ROOT/bin/fm-brief.sh" mixed --secondmate --workspace interview-prep extra-project 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace charter must refuse a managed project list"
  assert_contains "$out" "--workspace cannot be combined with a project list" "workspace/project refusal was not actionable"

  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='bad' \
    "$ROOT/bin/fm-home-seed.sh" mixed "$home" --workspace interview-prep --no-projects 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace seed must refuse the project-less mode"
  assert_contains "$out" "--no-projects cannot be combined with --workspace" "workspace/project-less refusal was not actionable"
  assert_absent "$PARENT/data/mixed/brief.md" "failed source-shape validation left a charter brief"
  assert_absent "$PARENT/data/secondmates.md.tmp" "failed source-shape validation left registry staging state"
  pass "secondmate workspace: source modes are explicit and mutually exclusive"
}

test_empty_workspace_ids_fail_before_routing() {
  local home out rc
  home="$TMP_ROOT/empty-workspace-id-home"

  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='empty workspace id fixture' \
    "$ROOT/bin/fm-brief.sh" empty-brief --secondmate --workspace "" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "secondmate brief must reject an empty workspace id"
  assert_contains "$out" "--workspace requires a non-empty value" "empty workspace brief refusal was not actionable"
  assert_absent "$PARENT/data/empty-brief/brief.md" "empty workspace brief created a route artifact"

  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='empty workspace id fixture' \
    "$ROOT/bin/fm-home-seed.sh" empty-seed "$home" --workspace "" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "secondmate seed must reject an empty workspace id"
  assert_contains "$out" "--workspace requires a non-empty value" "empty workspace seed refusal was not actionable"
  assert_absent "$home" "empty workspace seed created a target home"
  assert_absent "$PARENT/data/empty-seed/brief.md" "empty workspace seed created a route artifact"
  pass "secondmate workspace: empty workspace ids fail before routing"
}

test_workspace_seed_refuses_protected_target_before_clone() {
  local target out rc
  target="$OUTER/unsafe-secondmate-home"
  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='unsafe target fixture' \
    "$ROOT/bin/fm-home-seed.sh" unsafe "$target" --workspace interview-prep 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace seed must refuse a target inside the external workspace root"
  assert_contains "$out" "protected workspace root" "workspace seed overlap refusal was not actionable"
  assert_absent "$target" "workspace seed created a protected target before refusal"
  assert_absent "$PARENT/data/unsafe/brief.md" "workspace seed wrote a charter before protected-target refusal"
  assert_present "$PARENT/data/workspaces/interview-prep.workspace" "protected-target refusal removed the source pointer"
  pass "secondmate workspace: protected targets fail before home creation"
}

test_workspace_seed_refuses_symlinked_new_target_before_clone() {
  local alias target out rc
  alias="$TMP_ROOT/dangling-target-alias"
  target="$OUTER/not-yet-created-home-parent"
  ln -s "$target" "$alias"
  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='symlink target fixture' \
    "$ROOT/bin/fm-home-seed.sh" symlinked "$alias/home" --workspace interview-prep 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace seed must reject symlink-bearing new targets before cloning"
  assert_contains "$out" "path contains a symlink" "symlink-bearing target refusal was not actionable"
  assert_absent "$target" "workspace seed cloned through a dangling symlink into the protected workspace"
  assert_absent "$PARENT/data/symlinked/brief.md" "symlink-bearing target refusal left a charter brief"
  assert_present "$PARENT/data/workspaces/interview-prep.workspace" "symlink-bearing target refusal removed the source pointer"
  pass "secondmate workspace: symlink-bearing new targets fail before home creation"
}

test_workspace_seed_refuses_claimed_target() {
  local target claim owner out rc
  target="$TMP_ROOT/claimed-secondmate-home"
  claim="$target.fm-home-seed.lock"
  owner="$claim.owner.fixture"
  mkdir -p "$owner"
  printf '%s\n' "$$" > "$owner/pid"
  ln -s "$owner" "$claim"
  set +e
  out=$(FM_HOME="$PARENT" FM_SECONDMATE_CHARTER='claimed target fixture' \
    "$ROOT/bin/fm-home-seed.sh" claimed "$target" --workspace interview-prep 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace seed must refuse a target claimed by another seed"
  assert_contains "$out" "already being seeded" "claimed-target refusal was not actionable"
  assert_absent "$target" "claimed-target refusal created or removed the target home"
  [ -L "$claim" ] || fail "claimed-target refusal removed another seed's claim"
  assert_absent "$PARENT/data/claimed/brief.md" "claimed-target refusal left a charter brief"
  pass "secondmate workspace: target claims serialize concurrent seeds"
}

setup_world
test_workspace_charter_and_seed
test_workspace_source_shapes_are_exclusive
test_empty_workspace_ids_fail_before_routing
test_workspace_seed_refuses_protected_target_before_clone
test_workspace_seed_refuses_symlinked_new_target_before_clone
test_workspace_seed_refuses_claimed_target

printf 'All secondmate workspace tests passed.\n'
