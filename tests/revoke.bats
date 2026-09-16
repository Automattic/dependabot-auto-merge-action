#!/usr/bin/env bats
# Tests for the step that withdraws a queued auto-merge once the latest
# evaluation no longer supports it, run against the gh stub in tests/stubs/.
# The step script is pulled out of the YAML and run as-is.
#
# Routing a PR to review, or removing the fast-track label, used to change
# labels and comments only. An auto-merge this workflow had already queued
# stayed queued and merged the PR anyway. GitHub disables auto-merge on
# some head changes, but not reliably enough to count on.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export REVOKE_STEP="$BATS_FILE_TMPDIR/revoke-auto-merge.sh"
    extract_run revoke-auto-merge >"$REVOKE_STEP"
    # Guard the extractor: an empty script would pass the no-disable
    # assertions below for the wrong reason.
    [ -s "$REVOKE_STEP" ]
    bash -n "$REVOKE_STEP"
    grep -q -- '--disable-auto' "$REVOKE_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    export PR_NUMBER=42
    export PR_URL="https://github.com/acme/widgets/pull/42"
    export HEAD_SHA=1111111111111111111111111111111111111111
    export AGE_DAYS=7
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

OLD="2020-01-01T00:00:00Z"

PULL_KEY="GET_repos_acme_widgets_pulls_42"

# The PR as the pulls API returns it, with auto-merge queued by $1, or not
# queued at all when $1 is empty.
pull_fixture() {
    if [ -n "$1" ]; then
        jq -n --arg by "$1" '{auto_merge: {enabled_by: {login: $by}, merge_method: "squash"}}'
    else
        jq -n '{auto_merge: null}'
    fi >"$GH_STUB_DIR/$PULL_KEY"
}

# Run the step with record-eligibility's verdict as $1 (empty when that step
# wrote none) and the PR's creation time as $2. The flags match what the
# step's `shell: bash` expands to in Actions.
revoke() {
    ELIGIBLE="$1" PR_CREATED_AT="$2" \
        bash --noprofile --norc -e -o pipefail "$REVOKE_STEP"
}

now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- revoking ---------------------------------------------------------------

@test "a queued auto-merge is disabled when a later evaluation rejects the PR" {
    # The cron queued it, then a rebase matched a lower-scored advisory.
    pull_fixture 'github-actions[bot]'
    run revoke false "$OLD"
    [ "$status" -eq 0 ]
    log_has_call 'pr merge' '--disable-auto' "$PR_URL"
    [ "$(log_count 'pr comment')" -eq 1 ]
}

@test "removing the fast-track label disables the auto-merge it queued" {
    # The label came off a young PR that passes the gates. Without the
    # override it waits for the age gate like any other PR.
    pull_fixture 'github-actions[bot]'
    revoke true "$(now)"
    log_has_call 'pr merge' '--disable-auto' "$PR_URL"
}

@test "an evaluation that errored before a verdict disables the auto-merge" {
    pull_fixture 'github-actions[bot]'
    revoke '' "$OLD"
    log_has_call 'pr merge' '--disable-auto'
}

@test "a PR lookup failure disables the auto-merge anyway" {
    echo "gh: HTTP 502" >"$GH_STUB_DIR/$PULL_KEY.err"
    run revoke false "$OLD"
    [ "$status" -eq 0 ]
    grep -qF '::warning::' <<<"$output"
    log_has_call 'pr merge' '--disable-auto'
}

@test "a failed disable fails the step" {
    pull_fixture 'github-actions[bot]'
    echo "GraphQL: Something went wrong" >"$GH_STUB_DIR/pr_merge.err"
    run revoke false "$OLD"
    [ "$status" -ne 0 ]
}

# --- preserving valid approvals -------------------------------------------

@test "a PR past the gates and the age gate keeps its queued auto-merge" {
    # Exactly what the cron would queue, so a re-evaluation (a label added,
    # say) must not withdraw it.
    pull_fixture 'github-actions[bot]'
    revoke true "$OLD"
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "a PR with no queued auto-merge is left alone" {
    pull_fixture ''
    revoke false "$OLD"
    [ "$(log_count 'pr merge')" -eq 0 ]
    [ "$(log_count 'pr comment')" -eq 0 ]
}

@test "an auto-merge a person enabled is left alone" {
    # Only users with write access can enable auto-merge by hand, and that
    # is their own authorization, not this workflow's.
    pull_fixture ada
    revoke false "$OLD"
    [ "$(log_count 'pr merge')" -eq 0 ]
}
