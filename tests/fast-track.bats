#!/usr/bin/env bats
# Tests for the fast-track detection and audit steps of the reusable
# workflow, run against the gh stub in tests/stubs/. The step scripts are
# pulled out of the YAML and run as-is, so these tests exercise the shipped
# code rather than a copy that can drift.
#
# A person fast-tracks a PR by enabling auto-merge on it themselves. GitHub
# checks that they can merge, so the workflow only reads who enabled it. A
# person bypasses the gates; this workflow's own scheduled merge, which
# enables auto-merge as github-actions[bot], does not.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export DETECT_STEP="$BATS_FILE_TMPDIR/fast-track.sh"
    export AUDIT_STEP="$BATS_FILE_TMPDIR/fast-track-audit.sh"
    extract_run fast-track >"$DETECT_STEP"
    extract_run fast-track-audit >"$AUDIT_STEP"
    # Guard the extractor: an empty or half-dedented script would pass the
    # no-output assertions below for the wrong reason.
    for step in "$DETECT_STEP" "$AUDIT_STEP"; do
        [ -s "$step" ]
        bash -n "$step"
    done
    grep -q 'active=' "$DETECT_STEP"
    grep -q 'pr comment' "$AUDIT_STEP"
    grep -q 'add-label' "$AUDIT_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    export PR_NUMBER=42
    export PR_URL="https://github.com/acme/widgets/pull/42"
    export FAST_TRACK_LABEL=security-fast-track
    export RUN_URL=https://example.test/run
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    : >"$GITHUB_OUTPUT"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

PULL_KEY="GET_repos_acme_widgets_pulls_42"
COMMENTS_KEY="GET_repos_acme_widgets_issues_42_comments_per_page_100"

# The PR as the pulls API returns it, with auto-merge enabled by $1, or not
# enabled at all when $1 is empty. The same shape tests/revoke.bats uses.
pull_fixture() {
    if [ -n "$1" ]; then
        jq -n --arg by "$1" '{auto_merge: {enabled_by: {login: $by}, merge_method: "squash"}}'
    else
        jq -n '{auto_merge: null}'
    fi >"$GH_STUB_DIR/$PULL_KEY"
}

# The flags match what the steps' `shell: bash` expands to in Actions.
detect() {
    bash --noprofile --norc -e -o pipefail "$DETECT_STEP"
}

audit() {
    bash --noprofile --norc -e -o pipefail "$AUDIT_STEP"
}

# --- what counts as a fast-track ------------------------------------------

@test "an auto-merge a person enabled is a fast-track" {
    pull_fixture ada
    detect
    [ "$(out active)" = "true" ]
    [ "$(out enabled-by)" = "ada" ]
}

@test "an auto-merge this workflow queued is not" {
    pull_fixture 'github-actions[bot]'
    detect
    [ "$(out active)" = "false" ]
    [ -z "$(out enabled-by)" ]
}

@test "a PR with no auto-merge queued is not" {
    pull_fixture ''
    detect
    [ "$(out active)" = "false" ]
    [ -z "$(out enabled-by)" ]
}

@test "an auto-merge with no readable enabler is not" {
    # Fail closed: a bypass needs a person to attribute it to.
    jq -n '{auto_merge: {enabled_by: null, merge_method: "squash"}}' >"$GH_STUB_DIR/$PULL_KEY"
    run detect
    [ "$status" -eq 0 ]
    [ "$(out active)" = "false" ]
    grep -qF 'no readable enabler' <<<"$output"
}

@test "a failed read fails the step and writes no verdict" {
    echo "gh: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/$PULL_KEY.err"
    run detect
    [ "$status" -ne 0 ]
    [ -z "$(out active)" ]
    grep -qF '::error::' <<<"$output"
    grep -qF 'HTTP 403' <<<"$output"
}

# --- audit ----------------------------------------------------------------

@test "the audit comment names the person who enabled auto-merge and marks the PR" {
    echo '[]' >"$GH_STUB_DIR/$COMMENTS_KEY"
    ENABLED_BY=ada audit
    [ "$(log_count 'pr comment')" -eq 1 ]
    [ "$(log_count '@ada')" -eq 1 ]
    log_has_call 'pr edit' '--add-label' 'security-fast-track'
}

@test "an existing audit comment is neither re-posted nor relabelled" {
    jq -n '[{body: "<!-- dependabot-auto-merge:fast-track-audit -->\n**Fast-track audit.**"}, {body: "unrelated"}]' \
        >"$GH_STUB_DIR/$COMMENTS_KEY"
    ENABLED_BY=ada audit
    [ "$(log_count 'pr comment')" -eq 0 ]
    [ "$(log_count 'pr edit')" -eq 0 ]
}

@test "a failed comments read fails the step before it posts" {
    echo "gh: HTTP 500: Server Error" >"$GH_STUB_DIR/$COMMENTS_KEY.err"
    ENABLED_BY=ada run audit
    [ "$status" -ne 0 ]
    [ "$(log_count 'pr comment')" -eq 0 ]
    [ "$(log_count 'pr edit')" -eq 0 ]
    grep -qF '::error::' <<<"$output"
}
