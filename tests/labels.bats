#!/usr/bin/env bats
# Tests for the label steps of the reusable workflow. The review and pending
# labels are mutually exclusive states: every transition must add one and
# remove the other in a single `gh pr edit`. The step scripts are pulled out
# of the YAML and run as-is against the gh stub, so these tests exercise the
# shipped code rather than a copy that can drift from it.

load helpers

# Extraction is per-file, not per-test: the scripts under test only change
# when the YAML does.
setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export REVIEW_STEP="$BATS_FILE_TMPDIR/label-review.sh"
    export PENDING_STEP="$BATS_FILE_TMPDIR/label-pending.sh"
    extract_run label-review >"$REVIEW_STEP"
    extract_run label-pending >"$PENDING_STEP"
    # Guard the extractor: an empty or half-dedented script would pass every
    # assertion below — parse each script and check for a landmark.
    for step in "$REVIEW_STEP" "$PENDING_STEP"; do
        [ -s "$step" ]
        bash -n "$step"
        grep -q -- '--remove-label' "$step"
    done
    grep -q 'pr comment' "$REVIEW_STEP"
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
    # One edit carrying both flags: two separate calls would leave the PR in
    # the both-labels state whenever the second one failed.
    [ "$(log_count 'pr edit')" -eq 1 ]
    [ "$(log_count "pr edit $PR_URL --add-label sirt-review-required --remove-label auto-merge-pending")" -eq 1 ]
    [ "$(log_count 'pr comment')" -eq 1 ]
}

# --- review -> pass -------------------------------------------------------

@test "marking pending sheds the review label in the same edit" {
    REVIEW_LABEL=sirt-review-required PENDING_LABEL=auto-merge-pending \
        run_step "$PENDING_STEP"
    [ "$(log_count 'pr edit')" -eq 1 ]
    [ "$(log_count "pr edit $PR_URL --add-label auto-merge-pending --remove-label sirt-review-required")" -eq 1 ]
}

# --- custom label names ---------------------------------------------------

@test "custom label names pass through to the edit" {
    REVIEW_LABEL=needs-security-review PENDING_LABEL=dependabot-approved \
        run_step "$PENDING_STEP"
    [ "$(log_count '--add-label dependabot-approved --remove-label needs-security-review')" -eq 1 ]
}
