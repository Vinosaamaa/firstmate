#!/usr/bin/env bash
# Executable-interface tests for external workspace registration and routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workspace)
WORKSPACE="$ROOT/bin/fm-workspace.sh"

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

git_repo() {
  local path=$1
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" config user.email workspace-test@example.invalid
  git -C "$path" config user.name 'Workspace Test'
  printf 'fixture\n' > "$path/README.md"
  git -C "$path" add README.md
  git -C "$path" commit -qm 'fixture: initialize repository'
}

register_three_member_workspace() {
  local home=$1 outer=$2
  FM_HOME="$home" "$WORKSPACE" add interview-prep \
    --root "$outer" \
    --scope 'Interview preparation products and practice tooling.' \
    --member "interview-arc=$outer/interview-arc" \
    --member "interview-arc-live=$outer/interview-arc-live" \
    --member "interview-arc-voice=$outer/interview-arc-voice"
}

test_empty_non_git_outer_with_three_members() {
  local home outer out context
  home=$(new_home three-members)
  outer="$TMP_ROOT/three-members/Interview Prep"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/interview-arc"
  git_repo "$outer/interview-arc-live"
  git_repo "$outer/interview-arc-voice"

  if git -C "$outer" rev-parse --show-toplevel >/dev/null 2>&1; then
    fail "synthetic outer workspace unexpectedly became a Git repository"
  fi
  [ "$(find "$outer" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "synthetic outer workspace must have no outer files"

  out=$(register_three_member_workspace "$home" "$outer")
  assert_contains "$out" "registered workspace interview-prep" "registration did not report the stable workspace id"
  assert_contains "$out" "members=3" "registration did not report all three members"
  assert_contains "$out" "instructions=0" "registration did not accept absent outer instructions"

  out=$(FM_HOME="$home" "$WORKSPACE" list)
  assert_contains "$out" "interview-prep" "list omitted the workspace id"
  assert_contains "$out" "interview-arc,interview-arc-live,interview-arc-voice" "list lost member order or identities"

  out=$(FM_HOME="$home" "$WORKSPACE" show interview-prep)
  assert_contains "$out" "instruction-roots: none" "show did not make absent outer instructions explicit"
  assert_contains "$out" "- interview-arc-voice [contained] $outer/interview-arc-voice" "show omitted a member path"

  out=$(FM_HOME="$home" "$WORKSPACE" resolve interview-prep interview-arc-live --path)
  [ "$out" = "$outer/interview-arc-live" ] || fail "resolve --path returned '$out'"

  context=$(FM_HOME="$home" "$WORKSPACE" resolve interview-prep interview-arc --context)
  assert_contains "$context" "No outer instruction roots are registered." "context did not render the optional-empty instruction state"
  assert_contains "$context" "nested \`AGENTS.md\` files remain authoritative" "context lost member-repository instruction authority"
  assert_contains "$context" "ordinary isolated worktree lifecycle" "context did not route implementation into the existing lifecycle"
  assert_contains "$context" "Cross-repository work must be split into separately linked member tasks." "context invented or allowed a shared multi-repository worktree"
  pass "fm-workspace: empty non-Git outer root routes three explicit Git members"
}

test_instruction_order_and_drift_detection() {
  local home outer out rc
  home=$(new_home instructions)
  outer="$TMP_ROOT/instructions/domain"
  mkdir -p "$outer/context-a" "$outer/context-b"
  outer=$(cd "$outer" && pwd -P)
  printf 'FIRST OUTER RULE\n' > "$outer/context-a/AGENTS.md"
  printf 'SECOND OUTER RULE\n' > "$outer/context-b/AGENTS.md"
  git_repo "$outer/repo"

  FM_HOME="$home" "$WORKSPACE" register docs-domain \
    --root "$outer" \
    --scope 'Documentation workspace.' \
    --instruction-root "$outer/context-b" \
    --instruction-root "$outer/context-a" \
    --member "docs=$outer/repo" >/dev/null

  out=$(FM_HOME="$home" "$WORKSPACE" resolve docs-domain docs --context)
  case "$out" in
    *"SECOND OUTER RULE"*"FIRST OUTER RULE"*) ;;
    *) fail "outer instruction context did not preserve registration order: $out" ;;
  esac
  assert_contains "$out" "Committed SHA-256" "context did not expose its drift commitment"

  printf 'CHANGED OUTER RULE\n' > "$outer/context-b/AGENTS.md"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" resolve docs-domain docs --path 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "instruction-content drift must fail resolution closed"
  assert_contains "$out" "instruction content drifted" "instruction drift refusal was not actionable"
  pass "fm-workspace: ordered outer instruction context is hash-bound and drift-safe"
}

test_invalid_and_drifting_member_paths_fail_closed() {
  local home outer outside out rc
  home=$(new_home invalid-paths)
  outer="$TMP_ROOT/invalid-paths/domain"
  outside="$TMP_ROOT/invalid-paths/outside"
  mkdir -p "$outer/not-a-repo" "$outside"
  outer=$(cd "$outer" && pwd -P)
  outside=$(cd "$outside" && pwd -P)
  git_repo "$outer/member"
  git_repo "$outside/external-repo"

  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" add relative-root --root relative --scope test --member "repo=$outer/member" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "relative outer roots must be refused"
  assert_contains "$out" "must be an absolute path" "relative-root refusal was not actionable"

  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" add non-git --root "$outer" --scope test --member "repo=$outer/not-a-repo" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "non-Git member paths must be refused"
  assert_contains "$out" "explicit Git worktree root" "non-Git refusal did not name the contract"

  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" add undeclared-external --root "$outer" --scope test --member "repo=$outside/external-repo" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "outside members must require explicit declaration"
  assert_contains "$out" "use --external-member" "outside-member refusal did not explain the safe declaration"

  FM_HOME="$home" "$WORKSPACE" add explicit-external \
    --root "$outer" --scope test \
    --member "inside=$outer/member" \
    --external-member "outside=$outside/external-repo" >/dev/null
  [ "$(FM_HOME="$home" "$WORKSPACE" resolve explicit-external outside --path)" = "$outside/external-repo" ] \
    || fail "explicitly declared external member did not resolve"

  mv "$outer/member" "$outer/member-moved"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" show explicit-external 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing or moved member roots must fail all normal reads closed"
  assert_contains "$out" "path is missing" "member-path drift refusal was not actionable"
  pass "fm-workspace: invalid, undeclared, and drifting member paths fail closed"
}

test_duplicate_identities_and_paths_are_refused() {
  local home outer out rc
  home=$(new_home duplicates)
  outer="$TMP_ROOT/duplicates/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/one"
  git_repo "$outer/two"

  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" add duplicate-members \
    --root "$outer" --scope test \
    --member "repo=$outer/one" --member "repo=$outer/two" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate member identities must be refused"
  assert_contains "$out" "duplicate member id" "duplicate identity refusal was not actionable"

  FM_HOME="$home" "$WORKSPACE" add owner-one \
    --root "$outer" --scope test --member "one=$outer/one" >/dev/null
  mkdir -p "$TMP_ROOT/duplicates/other-domain"
  local other_domain
  other_domain=$(cd "$TMP_ROOT/duplicates/other-domain" && pwd -P)
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" add owner-two \
    --root "$other_domain" --scope test \
    --external-member "same-path=$outer/one" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a member path must not have two workspace owners"
  assert_contains "$out" "already registered" "cross-workspace path collision was not actionable"
  pass "fm-workspace: workspace and member routing identities stay unique"
}

test_malformed_registry_fails_closed() {
  local home out rc
  home=$(new_home malformed)
  mkdir -p "$home/data/workspaces"
  printf 'not-a-workspace\t1\n' > "$home/data/workspaces/bad.workspace"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" list 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed records must fail workspace listing closed"
  assert_contains "$out" "invalid external workspace record" "malformed-record refusal was not actionable"

  find "$home/data/workspaces" -depth -delete
  mkdir -p "$home/data/workspaces"
  printf 'unexpected\n' > "$home/data/workspaces/README"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" list 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown registry entries must fail listing closed"
  assert_contains "$out" "invalid external workspace registry entry" "unknown-entry refusal was not actionable"
  pass "fm-workspace: malformed registry state cannot be routed around"
}

test_unregister_removes_only_pointer_even_after_drift() {
  local home outer record out rc
  home=$(new_home unregister)
  outer="$TMP_ROOT/unregister/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/one"
  git_repo "$outer/two"
  git_repo "$outer/three"
  FM_HOME="$home" "$WORKSPACE" add unregister-me \
    --root "$outer" --scope test \
    --member "one=$outer/one" --member "two=$outer/two" --member "three=$outer/three" >/dev/null
  record="$home/data/workspaces/unregister-me.workspace"
  assert_present "$record" "registration did not create the private pointer record"

  mv "$outer/two" "$outer/two-drifted"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" unregister unregister-me --confirm wrong 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unregister must require exact repeated-id confirmation"
  assert_present "$record" "failed confirmation removed the pointer"

  out=$(FM_HOME="$home" "$WORKSPACE" remove unregister-me --confirm unregister-me)
  assert_contains "$out" "external root and repositories were not touched" "remove did not state its pointer-only boundary"
  assert_absent "$record" "remove retained the private pointer record"
  assert_present "$outer" "remove deleted the external root"
  assert_present "$outer/one/.git" "remove deleted the first member repository"
  assert_present "$outer/two-drifted/.git" "remove deleted the drifted member repository"
  assert_present "$outer/three/.git" "remove deleted the third member repository"
  pass "fm-workspace: guarded unregister removes only the private pointer"
}

test_existing_managed_clone_registry_is_unchanged() {
  local home clone out
  home=$(new_home clone-compatibility)
  clone="$home/projects/legacy"
  git_repo "$clone"
  printf '%s\n' '- legacy [direct-PR +yolo] - existing managed clone (added 2026-08-23)' > "$home/data/projects.md"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" legacy)
  [ "$out" = "direct-PR on" ] || fail "external workspace support changed existing clone posture resolution: $out"
  out=$(FM_HOME="$home" "$WORKSPACE" list)
  [ -z "$out" ] || fail "an absent workspace registry should not synthesize records: $out"
  assert_present "$clone/.git" "workspace listing disturbed an existing managed clone"
  pass "fm-workspace: existing projects/ clone behavior remains unchanged"
}

test_brief_propagates_validated_workspace_route() {
  local home outer brief out rc
  home=$(new_home brief-route)
  mkdir -p "$home/state"
  outer="$TMP_ROOT/brief-route/domain"
  mkdir -p "$outer/outer-context"
  outer=$(cd "$outer" && pwd -P)
  printf 'OUTER WORKSPACE RULE\n' > "$outer/outer-context/AGENTS.md"
  git_repo "$outer/member"
  FM_HOME="$home" "$WORKSPACE" add brief-domain \
    --root "$outer" --scope 'Brief route fixture.' \
    --instruction-root "$outer/outer-context" \
    --member "member=$outer/member" >/dev/null

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-route-a1 member \
    --workspace brief-domain --member member --mode direct-PR >/dev/null
  brief="$home/data/brief-route-a1/brief.md"
  assert_grep 'Workspace route: workspace=brief-domain member=member' "$brief" \
    "brief did not record the selected logical workspace and member"
  assert_grep "Workspace repository: $outer/member" "$brief" \
    "brief did not record the canonical member Git root"
  assert_grep 'OUTER WORKSPACE RULE' "$brief" \
    "brief did not snapshot validated outer instruction context"
  # Backticks are literal Markdown from the rendered routing context.
  # shellcheck disable=SC2016
  assert_grep 'nested `AGENTS.md` files remain authoritative' "$brief" \
    "brief did not preserve member-repository instruction authority"

  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-route-b2 wrong-name \
    --workspace brief-domain --member member --mode direct-PR 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "brief intake must select the explicit member identity"
  assert_contains "$out" "must equal the selected workspace member id" "brief member-mismatch refusal was not actionable"

  out=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$out" "--workspace <workspace-id> --member <member-id>" \
    "spawn help did not expose the first-class workspace/member route"

  set +e
  out=$(FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" brief-route-a1 \
    --workspace brief-domain --member member \
    --mode direct-PR --yolo off --harness unsupported-fixture 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "workspace-routed spawn fixture should reach the deliberate unsupported-harness stop"
  assert_contains "$out" "unknown harness 'unsupported-fixture'" \
    "spawn did not accept and resolve the matching workspace/member route before harness selection"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-route-c3 member \
    --workspace brief-domain --member member --mode direct-PR >/dev/null
  set +e
  out=$(FM_HOME="$home" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" brief-route-c3 "$outer/member" \
    --mode direct-PR --yolo off --harness claude 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a route-bearing brief must not launch through the legacy project positional"
  assert_contains "$out" "pass its exact --workspace and --member" \
    "legacy launch refusal did not preserve workspace-route provenance"
  pass "fm-workspace: brief propagation and spawn intake preserve the explicit route"
}

test_copy_preserves_pointer_without_cloning() {
  local home target outer out target_record
  home=$(new_home copy-source)
  target="$TMP_ROOT/copy-target/home"
  mkdir -p "$target/bin" "$target/data" "$target/projects"
  printf '# Firstmate\n' > "$target/AGENTS.md"
  outer="$TMP_ROOT/copy-source/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/member"
  FM_HOME="$home" "$WORKSPACE" add copy-domain \
    --root "$outer" --scope 'Copied pointer fixture.' \
    --member "member=$outer/member" >/dev/null

  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-domain --to-home "$target")
  assert_contains "$out" "copied workspace copy-domain" "copy did not report the pointer transfer"
  assert_contains "$out" "external root and repositories were not touched" "copy did not state its non-mutating boundary"
  target_record="$target/data/workspaces/copy-domain.workspace"
  assert_present "$target_record" "copy did not publish the target-home pointer"
  cmp -s "$home/data/workspaces/copy-domain.workspace" "$target_record" \
    || fail "copy changed the validated pointer bytes"
  [ "$(FM_HOME="$target" "$WORKSPACE" resolve copy-domain member --path)" = "$outer/member" ] \
    || fail "copied pointer did not resolve the canonical member repository"
  [ -z "$(find "$target/projects" -mindepth 1 -maxdepth 1 -print)" ] \
    || fail "copy created a duplicate managed project clone"

  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-domain --to-home "$target")
  assert_contains "$out" "already matches" "copy was not idempotent for identical validated bytes"
  assert_present "$outer/member/.git" "copy disturbed the canonical external repository"
  pass "fm-workspace: copies validated pointers between homes without cloning or mutating repositories"
}

test_copy_refuses_conflicting_or_unsafe_targets() {
  local home target outer source_member target_outer target_member target_record before out rc outside protected_target nested_target
  home=$(new_home copy-safety-source)
  target="$TMP_ROOT/copy-safety-target/home"
  mkdir -p "$target/bin" "$target/data" "$target/projects"
  printf '# Firstmate\n' > "$target/AGENTS.md"

  outer="$TMP_ROOT/copy-safety-source/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  source_member="$outer/member"
  git_repo "$source_member"
  FM_HOME="$home" "$WORKSPACE" add copy-safety \
    --root "$outer" --scope 'Source pointer fixture.' \
    --member "member=$source_member" >/dev/null

  target_outer="$TMP_ROOT/copy-safety-target/domain"
  mkdir -p "$target_outer"
  target_outer=$(cd "$target_outer" && pwd -P)
  target_member="$target_outer/member"
  git_repo "$target_member"
  FM_HOME="$target" "$WORKSPACE" add copy-safety \
    --root "$target_outer" --scope 'Conflicting pointer fixture.' \
    --member "member=$target_member" >/dev/null
  target_record="$target/data/workspaces/copy-safety.workspace"
  before=$(cksum "$target_record")

  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-safety --to-home "$target" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "copy must refuse a conflicting target pointer"
  assert_contains "$out" "differs from the active-home pointer" "conflicting copy refusal was not actionable"
  [ "$(cksum "$target_record")" = "$before" ] || fail "conflicting copy changed the target pointer"
  assert_present "$target_member/.git" "conflicting copy touched the target repository"

  outside="$TMP_ROOT/copy-safety-outside.workspace"
  printf 'outside pointer\n' > "$outside"
  rm -f -- "$target_record"
  ln -s "$outside" "$target_record"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-safety --to-home "$target" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "copy must refuse an unsafe target pointer"
  assert_contains "$out" "target workspace record is unsafe" "unsafe target refusal was not actionable"
  [ -L "$target_record" ] || fail "unsafe target refusal replaced the symlinked pointer"
  [ "$(cat "$outside")" = 'outside pointer' ] || fail "unsafe target refusal changed the outside pointer"

  protected_target="$outer/secondmate-home"
  mkdir -p "$protected_target/bin" "$protected_target/data" "$protected_target/projects"
  printf '# Firstmate\n' > "$protected_target/AGENTS.md"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-safety --to-home "$protected_target" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "copy must refuse a target inside the external workspace root"
  assert_contains "$out" "protected workspace root" "workspace-root overlap refusal was not actionable"
  assert_absent "$protected_target/data/workspaces/copy-safety.workspace" "protected workspace target received a pointer"

  nested_target="$home/nested-home"
  mkdir -p "$nested_target/bin" "$nested_target/data" "$nested_target/projects"
  printf '# Firstmate\n' > "$nested_target/AGENTS.md"
  set +e
  out=$(FM_HOME="$home" "$WORKSPACE" copy copy-safety --to-home "$nested_target" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "copy must refuse a target inside the active firstmate home"
  assert_contains "$out" "inside the active home" "active-home descendant refusal was not actionable"
  assert_absent "$nested_target/data/workspaces/copy-safety.workspace" "active-home descendant received a pointer"
  pass "fm-workspace: conflicting and unsafe pointer targets fail closed"
}

test_copy_receipt_owns_only_its_published_inode() {
  local home target outer target_record receipt replacement out
  home=$(new_home copy-receipt-source)
  target="$TMP_ROOT/copy-receipt-target/home"
  mkdir -p "$target/bin" "$target/data" "$target/projects"
  printf '# Firstmate\n' > "$target/AGENTS.md"
  outer="$TMP_ROOT/copy-receipt-source/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/member"
  FM_HOME="$home" "$WORKSPACE" add receipt-domain \
    --root "$outer" --scope 'Receipt ownership fixture.' \
    --member "member=$outer/member" >/dev/null

  FM_HOME="$home" "$WORKSPACE" copy receipt-domain --to-home "$target" --receipt seed-receipt >/dev/null
  target_record="$target/data/workspaces/receipt-domain.workspace"
  receipt="$target/data/.workspace-copy-receipts/seed-receipt"
  [ "$target_record" -ef "$receipt" ] || fail "copy receipt did not identify the published pointer inode"

  replacement="$target/data/workspaces/replacement.workspace"
  cp "$target_record" "$replacement"
  mv "$replacement" "$target_record"
  out=$(FM_HOME="$target" "$WORKSPACE" _release-copy receipt-domain --receipt seed-receipt --rollback)
  [ "$out" = preserved ] || fail "rollback did not preserve an identical pointer owned by another publication: $out"
  assert_present "$target_record" "receipt rollback removed another publication's identical pointer"
  assert_absent "$receipt" "receipt rollback left its ownership receipt behind"
  cmp -s "$home/data/workspaces/receipt-domain.workspace" "$target_record" \
    || fail "foreign replacement pointer bytes changed during receipt rollback"
  pass "fm-workspace: rollback receipts remove only their owned pointer inode"
}

test_copy_receipt_refuses_commit_without_pointer() {
  local home target outer target_record receipt out rc
  home=$(new_home copy-commit-source)
  target="$TMP_ROOT/copy-commit-target/home"
  mkdir -p "$target/bin" "$target/data" "$target/projects"
  printf '# Firstmate\n' > "$target/AGENTS.md"
  outer="$TMP_ROOT/copy-commit-source/domain"
  mkdir -p "$outer"
  outer=$(cd "$outer" && pwd -P)
  git_repo "$outer/member"
  FM_HOME="$home" "$WORKSPACE" add commit-domain \
    --root "$outer" --scope 'Commit verification fixture.' \
    --member "member=$outer/member" >/dev/null

  FM_HOME="$home" "$WORKSPACE" copy commit-domain --to-home "$target" --receipt seed-commit >/dev/null
  target_record="$target/data/workspaces/commit-domain.workspace"
  receipt="$target/data/.workspace-copy-receipts/seed-commit"
  FM_HOME="$target" "$WORKSPACE" remove commit-domain --confirm commit-domain >/dev/null
  set +e
  out=$(FM_HOME="$target" "$WORKSPACE" _release-copy commit-domain --receipt seed-commit 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "receipt release must refuse to commit a removed pointer"
  assert_contains "$out" "target is missing or unsafe" "missing-pointer commit refusal was not actionable"
  assert_present "$receipt" "failed pointer commit discarded its rollback receipt"
  assert_absent "$target_record" "failed pointer commit recreated the removed target"
  [ "$(FM_HOME="$target" "$WORKSPACE" _release-copy commit-domain --receipt seed-commit --rollback)" = absent ] \
    || fail "rollback did not release the orphaned copy receipt"
  assert_absent "$receipt" "rollback retained the orphaned copy receipt"
  pass "fm-workspace: receipt commit requires the propagated pointer"
}

test_empty_non_git_outer_with_three_members
test_instruction_order_and_drift_detection
test_invalid_and_drifting_member_paths_fail_closed
test_duplicate_identities_and_paths_are_refused
test_malformed_registry_fails_closed
test_unregister_removes_only_pointer_even_after_drift
test_existing_managed_clone_registry_is_unchanged
test_brief_propagates_validated_workspace_route
test_copy_preserves_pointer_without_cloning
test_copy_refuses_conflicting_or_unsafe_targets
test_copy_receipt_owns_only_its_published_inode
test_copy_receipt_refuses_commit_without_pointer

printf 'All fm-workspace tests passed.\n'
