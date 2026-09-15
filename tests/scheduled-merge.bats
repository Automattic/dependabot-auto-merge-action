#!/usr/bin/env bats
# Tests for the evidence check in the scheduled merge, run against the gh
# stub in tests/stubs/. The step script is pulled out of the YAML and run
# as-is. tests/labels.bats covers the label selection this check sits on.
#
# Labels are not evidence. A triage user can apply the pending label or
# remove the review label, and evaluation never touches the labels of a
# routine update. The cron therefore merges only a PR whose current head
# commit carries a success eligibility status from github-actions[bot],
# which evaluate-pr writes and tests/eligibility.bats covers.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export MERGE_STEP="$BATS_FILE_TMPDIR/scheduled-merge.sh"
    extract_run scheduled-merge >"$MERGE_STEP"
    # Guard the extractor: an empty script would pass every no-merge
    # assertion below.
    [ -s "$MERGE_STEP" ]
    bash -n "$MERGE_STEP"
    grep -q 'fromdateiso8601' "$MERGE_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    export PENDING_LABEL=auto-merge-pending
    export REVIEW_LABEL=sirt-review-required
    export AGE_DAYS=7
    export MERGE_METHOD=squash
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

HEAD=1111111111111111111111111111111111111111
OLD_HEAD=0000000000000000000000000000000000000000

# One old, pending-labelled PR 301 whose head is $1.
pending_pr_fixture() {
    jq -n --arg head "$1" \
        '[{number: 301, createdAt: "2020-01-01T00:00:00Z", headRefOid: $head,
           labels: [{name: "auto-merge-pending"}]}]' \
        >"$GH_STUB_DIR/pr_list"
}

merge_step() {
    bash --noprofile --norc -e "$MERGE_STEP"
}

@test "a forged pending label with no evidence does not merge" {
    pending_pr_fixture "$HEAD"
    statuses_fixture "$HEAD"
    run merge_step
    [ "$status" -eq 0 ]
    [ "$(log_count 'pr merge')" -eq 0 ]
    grep -qF '::warning::' <<<"$output"
}

@test "a routine update's pending label does not merge on other passing statuses" {
    # Evaluation never touches the labels of a routine update, so a pending
    # label a triage user applied survives it. CI passing is not evidence,
    # and neither is a context that merely starts with the right name.
    pending_pr_fixture "$HEAD"
    statuses_fixture "$HEAD" \
        "$(commit_status success 'github-actions[bot]' ci/build)" \
        "$(commit_status success 'github-actions[bot]' dependabot-auto-merge/eligibility-extra)"
    run merge_step
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "an eligibility status from another creator does not merge" {
    pending_pr_fixture "$HEAD"
    statuses_fixture "$HEAD" "$(commit_status success trina)"
    run merge_step
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "evidence for an earlier head commit does not merge the current one" {
    pending_pr_fixture "$HEAD"
    statuses_fixture "$OLD_HEAD" "$(commit_status success 'github-actions[bot]')"
    statuses_fixture "$HEAD"
    run merge_step
    [ "$(log_count 'pr merge')" -eq 0 ]
    [ "$(log_count "commits/$OLD_HEAD")" -eq 0 ]
}

@test "withdrawn evidence does not merge" {
    # Newest first: a later evaluation of the same commit failed.
    pending_pr_fixture "$HEAD"
    statuses_fixture "$HEAD" \
        "$(commit_status failure 'github-actions[bot]')" \
        "$(commit_status success 'github-actions[bot]')"
    run merge_step
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "an evidence lookup failure blocks the merge and fails the step" {
    pending_pr_fixture "$HEAD"
    echo "gh: HTTP 403: Resource not accessible by integration" \
        >"$GH_STUB_DIR/GET_repos_acme_widgets_commits_${HEAD}_statuses_per_page_100.err"
    run merge_step
    [ "$status" -eq 1 ]
    [ "$(log_count 'pr merge')" -eq 0 ]
    grep -qF '::error::' <<<"$output"
}

@test "a legitimately eligible PR merges" {
    # Newest first: the latest evaluation passed after an earlier failure.
    pending_pr_fixture "$HEAD"
    statuses_fixture "$HEAD" \
        "$(commit_status success 'github-actions[bot]')" \
        "$(commit_status failure 'github-actions[bot]')"
    merge_step
    [ "$(log_count 'pr merge 301')" -eq 1 ]
    log_has_call 'pr list' '--author app/dependabot' '--label auto-merge-pending'
}

@test "evidence does not bypass the age gate" {
    jq -n --arg head "$HEAD" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '[{number: 302, createdAt: $now, headRefOid: $head,
           labels: [{name: "auto-merge-pending"}]}]' \
        >"$GH_STUB_DIR/pr_list"
    statuses_fixture "$HEAD" "$(commit_status success 'github-actions[bot]')"
    merge_step
    [ "$(log_count 'pr merge')" -eq 0 ]
}
