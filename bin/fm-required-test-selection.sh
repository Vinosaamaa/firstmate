#!/usr/bin/env bash
# Select the captain fork's small required behavior-test surface from changed
# paths. This is intentionally an explicit policy table, not a dependency graph.

set -u

usage() {
  cat <<'EOF'
usage: fm-required-test-selection.sh [--all]

With --all, print the complete 15-test required allowlist. Otherwise read
changed repository paths from stdin and print the corresponding owner tests.
Documentation-only input prints nothing; unknown non-documentation paths fail
safe to the complete allowlist.
EOF
}

all_required_tests() {
  cat <<'EOF'
tests/fm-backend-herdr.test.sh
tests/fm-codex-session.test.sh
tests/fm-control-relaunch.test.sh
tests/fm-display-title.test.sh
tests/fm-identity.test.sh
tests/fm-secondmate-lifecycle-e2e.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-workspace.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-control-herdr-smoke.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
EOF
}

case "${1:-}" in
  --all)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    all_required_tests
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

selected=''
full_required=0

add_test() {
  local test_path=$1
  case $'\n'"$selected"$'\n' in
    *$'\n'"$test_path"$'\n'*) ;;
    *) selected="${selected}${selected:+$'\n'}${test_path}" ;;
  esac
}

while IFS= read -r path; do
  [ -n "$path" ] || continue

  case "$path" in
    *.md|docs/*|.github/ISSUE_TEMPLATE/*|LICENSE|LICENSE.*)
      continue
      ;;
  esac

  case "$path" in
    .github/actions/*|.github/workflows/ci.yml|.github/workflows/compatibility-advisory.yml|\
    bin/fm-required-test-selection.sh|bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh|\
    tests/lib/*|tests/fixtures/*|tests/fm-test-*.test.sh|tests/fm-lint-workflows.test.sh|\
    bin/fm-backend.sh|bin/fm-spawn.sh)
      full_required=1
      ;;

    tests/fm-backend-herdr.test.sh)
      add_test tests/fm-backend-herdr.test.sh
      ;;
    tests/fm-codex-session.test.sh)
      add_test tests/fm-codex-session.test.sh
      ;;
    tests/fm-control-relaunch.test.sh)
      add_test tests/fm-control-relaunch.test.sh
      ;;
    tests/fm-display-title.test.sh)
      add_test tests/fm-display-title.test.sh
      ;;
    tests/fm-identity.test.sh)
      add_test tests/fm-identity.test.sh
      ;;
    tests/fm-secondmate-lifecycle-e2e.test.sh)
      add_test tests/fm-secondmate-lifecycle-e2e.test.sh
      ;;
    tests/fm-supervision-instructions.test.sh)
      add_test tests/fm-supervision-instructions.test.sh
      ;;
    tests/fm-teardown-endpoint-safety.test.sh)
      add_test tests/fm-teardown-endpoint-safety.test.sh
      ;;
    tests/fm-teardown.test.sh)
      add_test tests/fm-teardown.test.sh
      ;;
    tests/fm-watch-recovery-loop.test.sh)
      add_test tests/fm-watch-recovery-loop.test.sh
      ;;
    tests/fm-watcher-lock.test.sh)
      add_test tests/fm-watcher-lock.test.sh
      ;;
    tests/fm-workspace.test.sh)
      add_test tests/fm-workspace.test.sh
      ;;
    tests/fm-backend-herdr-presentation-e2e.test.sh)
      add_test tests/fm-backend-herdr-presentation-e2e.test.sh
      ;;
    tests/fm-control-herdr-smoke.test.sh)
      add_test tests/fm-control-herdr-smoke.test.sh
      ;;
    tests/fm-herdr-session-cleanup-e2e.test.sh)
      add_test tests/fm-herdr-session-cleanup-e2e.test.sh
      ;;

    bin/fm-backend-herdr*|bin/fm-herdr-*)
      add_test tests/fm-backend-herdr.test.sh
      add_test tests/fm-backend-herdr-presentation-e2e.test.sh
      add_test tests/fm-control-herdr-smoke.test.sh
      add_test tests/fm-herdr-session-cleanup-e2e.test.sh
      ;;
    bin/fm-codex-*)
      add_test tests/fm-codex-session.test.sh
      add_test tests/fm-control-relaunch.test.sh
      ;;
    bin/fm-control.sh)
      add_test tests/fm-control-relaunch.test.sh
      ;;
    bin/fm-watch*|bin/fm-wake-*|bin/fm-supervision-*)
      add_test tests/fm-supervision-instructions.test.sh
      add_test tests/fm-watch-recovery-loop.test.sh
      add_test tests/fm-watcher-lock.test.sh
      ;;
    bin/fm-workspace*)
      add_test tests/fm-workspace.test.sh
      ;;
    bin/fm-secondmate-*)
      add_test tests/fm-secondmate-lifecycle-e2e.test.sh
      ;;
    bin/fm-identity-*|bin/fm-name.sh|bin/fm-display-title-*)
      add_test tests/fm-display-title.test.sh
      add_test tests/fm-identity.test.sh
      ;;
    bin/fm-teardown.sh|bin/fm-cleanup-identity.sh)
      add_test tests/fm-teardown-endpoint-safety.test.sh
      add_test tests/fm-teardown.test.sh
      ;;
    *)
      full_required=1
      ;;
  esac
done

if [ "$full_required" -eq 1 ]; then
  all_required_tests
  exit 0
fi

while IFS= read -r test_path; do
  case $'\n'"$selected"$'\n' in
    *$'\n'"$test_path"$'\n'*) printf '%s\n' "$test_path" ;;
  esac
done < <(all_required_tests)
