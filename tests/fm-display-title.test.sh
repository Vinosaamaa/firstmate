#!/usr/bin/env bash
# Shared display-identity contract and metadata compatibility tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-display-title-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-display-title)

test_exact_formats_and_task_last_truncation() {
  local title prefix max
  title=$(fm_display_title Darwin FM 'External workspace' unicode) \
    || fail "canonical Unicode title did not render"
  [ "$title" = 'Darwin · FM · External workspace' ] \
    || fail "canonical Unicode title changed: $title"
  title=$(fm_display_title Darwin FM 'External workspace' ascii) \
    || fail "ASCII fallback title did not render"
  [ "$title" = 'Darwin - FM - External workspace' ] \
    || fail "ASCII fallback title changed: $title"

  prefix='Darwin · FM · '
  max=$((${#prefix} + 8))
  title=$(fm_display_title Darwin FM 'External workspace' unicode "$max") \
    || fail "narrow Unicode title did not render"
  [ "$title" = 'Darwin · FM · Externa…' ] \
    || fail "narrow title did not truncate only TaskLabel: $title"
  pass "display title: canonical, fallback, and task-last truncation formats are exact"
}

test_secondmate_role_title_and_workspace_context() {
  local title code
  title=$(fm_display_secondmate_title Kepler IP unicode) \
    || fail "secondmate ContextCode title did not render"
  [ "$title" = 'Kepler · IP · 2M' ] \
    || fail "secondmate ContextCode title changed: $title"
  title=$(fm_display_secondmate_title Kepler '' unicode) \
    || fail "secondmate fallback title did not render"
  [ "$title" = 'Kepler · 2M' ] \
    || fail "secondmate fallback title changed: $title"
  title=$(fm_display_secondmate_title Kepler IP ascii) \
    || fail "secondmate ASCII title did not render"
  [ "$title" = 'Kepler - IP - 2M' ] \
    || fail "secondmate ASCII title changed: $title"
  code=$(fm_display_workspace_context_code interview-prep) \
    || fail "registered workspace id did not produce a ContextCode"
  [ "$code" = IP ] || fail "workspace ContextCode changed: $code"
  fm_display_workspace_context_code interviewprep >/dev/null 2>&1 \
    && fail "an unstructured workspace id invented a ContextCode"
  pass "display title: secondmates use stable role-aware context and fallback shapes"
}

test_validation_keeps_fields_explicit() {
  fm_display_project_code_valid MST || fail "valid registered acronym was refused"
  fm_display_project_code_valid IP || fail "valid two-character acronym was refused"
  fm_display_project_code_valid fm && fail "lowercase ProjectCode was accepted"
  fm_display_project_code_valid FIRSTMATE9 && fail "overlong ProjectCode was accepted"
  fm_display_task_label_valid 'Fix sidebar' || fail "valid two-word TaskLabel was refused"
  fm_display_task_label_valid 'Flatten workspace' || fail "valid two-word TaskLabel was refused"
  fm_display_task_label_valid 'fix the sidebar' && fail "three-word TaskLabel was accepted"
  fm_display_task_label_valid 'Fix  sidebar' && fail "repeated-space TaskLabel was accepted"
  fm_display_task_label_valid 'Fix · sidebar' && fail "embedded separator was accepted"
  pass "display title: ProjectCode and TaskLabel remain strict separate intake fields"
}

test_brief_and_meta_legacy_or_strict_pair() {
  local brief="$TMP_ROOT/brief.md" meta="$TMP_ROOT/task.meta" out
  printf '%s\n' 'You are a crewmate.' '' '# Task' 'Do it.' > "$brief"
  fm_display_brief_metadata_read "$brief" || fail "legacy brief was refused"
  [ "$FM_DISPLAY_METADATA_STATE" = absent ] || fail "legacy brief did not report absent metadata"

  printf '%s\n' \
    'You are a crewmate.' \
    'Firstmate project code: FM' \
    'Firstmate task label: External workspace' \
    '' '# Task' 'Do it.' > "$brief"
  fm_display_brief_metadata_read "$brief" || fail "valid brief metadata was refused"
  [ "$FM_DISPLAY_METADATA_STATE:$FM_DISPLAY_PROJECT_CODE:$FM_DISPLAY_TASK_LABEL" = 'present:FM:External workspace' ] \
    || fail "brief metadata fields drifted"

  printf '%s\n' 'project=/tmp/project' 'project_code=FM' 'task_label=External workspace' \
    'endpoint_task_id=opaque-internal-id' > "$meta"
  fm_display_task_metadata_read "$meta" || fail "valid task metadata was refused"
  [ "$FM_DISPLAY_PROJECT_CODE:$FM_DISPLAY_TASK_LABEL" = 'FM:External workspace' ] \
    || fail "task metadata fields drifted"

  printf '%s\n' 'project_code=FM' > "$meta"
  out=$(fm_display_task_metadata_read "$meta" 2>&1) && fail "partial metadata was accepted"
  assert_contains "$out" 'exactly one project_code= and one task_label=' \
    "partial metadata refusal did not explain the paired contract"
  printf '%s\n' 'kind=secondmate' 'context_code=IP' > "$meta"
  fm_display_secondmate_metadata_read "$meta" || fail "valid secondmate ContextCode metadata was refused"
  [ "$FM_DISPLAY_CONTEXT_CODE" = IP ] || fail "secondmate ContextCode metadata drifted"
  printf '%s\n' 'kind=secondmate' > "$meta"
  fm_display_secondmate_metadata_read "$meta" || fail "secondmate fallback metadata was refused"
  [ -z "$FM_DISPLAY_CONTEXT_CODE" ] || fail "secondmate fallback metadata invented a ContextCode"
  pass "display metadata: legacy absence falls back while partial identity refuses"
}

test_exact_formats_and_task_last_truncation
test_secondmate_role_title_and_workspace_context
test_validation_keeps_fields_explicit
test_brief_and_meta_legacy_or_strict_pair
echo "# all fm-display-title tests passed"
