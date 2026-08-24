#!/usr/bin/env bats
# Tests for the label steps of the reusable workflow. The review and pending
# labels are mutually exclusive states: every transition must add one and
# remove the other in a single `gh pr edit`. The step scripts are pulled out
# of the YAML and run as-is against the gh stub, so these tests exercise the
# shipped code rather than a copy that can drift from it.
#
# One edit is not the same as one atomic call. gh sends the add and the
# remove as two concurrent mutations with no rollback, so these tests assert
# the shape of the call, not that both labels always land together.

load helpers

# Extraction is per-file, not per-test: the scripts under test only change
# when the YAML does.
setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export REVIEW_STEP="$BATS_FILE_TMPDIR/label-review.sh"
    export PENDING_STEP="$BATS_FILE_TMPDIR/label-pending.sh"
    export MERGE_STEP="$BATS_FILE_TMPDIR/scheduled-merge.sh"
    extract_run label-review >"$REVIEW_STEP"
    extract_run label-pending >"$PENDING_STEP"
    extract_run scheduled-merge >"$MERGE_STEP"
    # Guard the extractor: an empty or half-dedented script would pass every
    # assertion below — parse each script and check for a landmark.
    for step in "$REVIEW_STEP" "$PENDING_STEP"; do
        [ -s "$step" ]
        bash -n "$step"
        grep -q -- '--remove-label' "$step"
    done
    grep -q 'pr comment' "$REVIEW_STEP"
    [ -s "$MERGE_STEP" ]
    bash -n "$MERGE_STEP"
    grep -q 'fromdateiso8601' "$MERGE_STEP"
}

setup() {
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/stub"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
    export PR_URL="https://github.com/acme/widgets/pull/6715"
}

# Run the extracted step in $1 with the flags a plain `run:` step expands to
# in Actions: bash --noprofile --norc -e (no pipefail — only steps declaring
# `shell: bash` get that).
run_step() {
    bash --noprofile --norc -e "$1"
}

# --- pass -> review -------------------------------------------------------

@test "routing to review sheds the pending label in the same edit" {
    METADATA_AVAILABLE=false REPORTED_CVSS='' REVIEW_TEAM='' \
        REVIEW_LABEL=sirt-review-required PENDING_LABEL=auto-merge-pending \
        run_step "$REVIEW_STEP"
    # One edit carrying both flags. gh is not atomic about it, but two
    # separate calls widen the window in which a failure on the second leaves
    # the PR in the both-labels state.
    [ "$(log_count 'pr edit')" -eq 1 ]
    log_has_call 'pr edit' "$PR_URL" \
        '--add-label sirt-review-required' '--remove-label auto-merge-pending'
    [ "$(log_count 'pr comment')" -eq 1 ]
}

@test "the review notification posts even when the edit fails" {
    echo "GraphQL: Resource not accessible by integration" >"$GH_STUB_DIR/pr_edit.err"
    METADATA_AVAILABLE=false REPORTED_CVSS='' REVIEW_TEAM=security \
        REVIEW_LABEL=sirt-review-required PENDING_LABEL=auto-merge-pending \
        run bash --noprofile --norc -e "$REVIEW_STEP"
    # The step still fails so the labelling failure is not swallowed, but
    # the comment goes out first, so a human sees the PR was routed to review
    # even when the label never lands.
    [ "$status" -eq 1 ]
    [ "$(log_count 'pr comment')" -eq 1 ]
    log_has_call 'pr comment' 'routed to the security-review path' 'cc @security'
}

# --- review -> pass -------------------------------------------------------

@test "marking pending sheds the review label in the same edit" {
    REVIEW_LABEL=sirt-review-required PENDING_LABEL=auto-merge-pending \
        run_step "$PENDING_STEP"
    [ "$(log_count 'pr edit')" -eq 1 ]
    log_has_call 'pr edit' "$PR_URL" \
        '--add-label auto-merge-pending' '--remove-label sirt-review-required'
}

# --- custom label names ---------------------------------------------------

@test "custom label names pass through to the edit" {
    REVIEW_LABEL=needs-security-review PENDING_LABEL=dependabot-approved \
        run_step "$PENDING_STEP"
    log_has_call 'pr edit' '--add-label dependabot-approved' \
        '--remove-label needs-security-review'
}

# --- scheduled merge ------------------------------------------------------

# Env the merge step reads. The pr_list fixture uses fixed 2020 dates for
# PRs meant to be past the age gate and `date -u` now for the one that
# isn't — no date arithmetic, which does not spell the same on BSD and GNU.
merge_env() {
    export GITHUB_REPOSITORY=acme/widgets
    export PENDING_LABEL=auto-merge-pending
    export REVIEW_LABEL=sirt-review-required
    export AGE_DAYS=7
    export MERGE_METHOD=squash
}

mixed_pr_list_fixture() {
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$GH_STUB_DIR/pr_list" <<EOF
[
  {"number": 101, "createdAt": "2020-01-01T00:00:00Z",
   "labels": [{"name": "auto-merge-pending"}]},
  {"number": 102, "createdAt": "2020-01-01T00:00:00Z",
   "labels": [{"name": "auto-merge-pending"}, {"name": "sirt-review-required"}]},
  {"number": 103, "createdAt": "$NOW",
   "labels": [{"name": "auto-merge-pending"}]}
]
EOF
}

@test "scheduled merge skips PRs that also carry the review label" {
    merge_env
    mixed_pr_list_fixture
    run_step "$MERGE_STEP"
    # 101 (pending only, old) merges; 102 is the ticket case — past the age
    # gate and still carrying a stale pending label, but routed to review —
    # and 103 is too young.
    [ "$(log_count 'pr merge 101')" -eq 1 ]
    [ "$(log_count 'pr merge 102')" -eq 0 ]
    [ "$(log_count 'pr merge 103')" -eq 0 ]
    [ "$(log_count 'pr merge')" -eq 1 ]
    [ "$(log_count '--label auto-merge-pending')" -eq 1 ]
}

# One old, pending-labelled PR that also carries $1 as its review label.
review_labelled_pr_fixture() {
    jq -n --arg review "$1" \
        '[{number: 201, createdAt: "2020-01-01T00:00:00Z",
           labels: [{name: "auto-merge-pending"}, {name: $review}]}]' \
        >"$GH_STUB_DIR/pr_list"
}

# Every other label comparison in the chain ignores case, so a caller whose
# `review-label` input differs in case from the repository label must not
# find the cron merging a PR that was routed to review. Both directions,
# because either half of the comparison can be the one carrying the casing.

@test "scheduled merge skips a review label whose casing differs on the PR" {
    merge_env
    review_labelled_pr_fixture SIRT-Review-Required
    run_step "$MERGE_STEP"
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "scheduled merge skips a review label whose casing differs in the input" {
    merge_env
    export REVIEW_LABEL=SIRT-Review-Required
    review_labelled_pr_fixture sirt-review-required
    run_step "$MERGE_STEP"
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "a merge failure still fails the step" {
    merge_env
    mixed_pr_list_fixture
    echo "GraphQL: Pull request is in clean status" >"$GH_STUB_DIR/pr_merge.err"
    run bash --noprofile --norc -e "$MERGE_STEP"
    [ "$status" -eq 1 ]
    # grep rather than [[ ]]: under macOS bash 3.2 a failed [[ ]] mid-test
    # cannot fail a bats test (errexit/ERR fire only for simple commands).
    grep -qF '::error::Failed to enable auto-merge on PR #101' <<<"$output"
}
