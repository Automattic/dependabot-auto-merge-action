#!/usr/bin/env bats
# Tests for the `if:` wiring of the reusable workflow. Several of its
# security boundaries are step conditions rather than scripts: a step that
# stops checking the output it depends on runs every script test green and
# still merges what it should refuse. These tests read the conditions out of
# the YAML so a change to that wiring has to change a test too.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    # Guard the extractor against a silent miss. Gate 2's condition is
    # stable and folded, so it exercises the block form.
    grep -qF "steps.cvss.outputs.available == 'true'" <<<"$(extract_if gate2)"
}

# --- fast-track authorization (QAO-765) -----------------------------------

@test "the fast-track merge runs only on a verified authorization" {
    run extract_if fast-track
    [ "$status" -eq 0 ]
    # Exact match, so a condition that ORs the old label check back in
    # cannot pass.
    [ "$output" = "steps.fast-track-auth.outputs.authorized == 'true'" ]
}

@test "the authorization check runs whenever the fast-track label is present" {
    run extract_if fast-track-auth
    [ "$output" = "contains(github.event.pull_request.labels.*.name, inputs.fast-track-label)" ]
}

@test "the gates still run when the override is refused" {
    # A refused override leaves the fast-track step skipped, and the gates
    # key on exactly that, so the PR falls through to normal evaluation.
    grep -qF "steps.fast-track.conclusion == 'skipped'" <<<"$(extract_if gate1)"
}

# --- eligibility evidence (QAO-766) ---------------------------------------

@test "every evaluation that did not fast-track records its verdict" {
    # always(), so an evaluation that errors part-way still withdraws
    # evidence an earlier run recorded for the same commit.
    run extract_if record-eligibility
    [ "$output" = "always() && steps.fast-track.conclusion != 'success'" ]
}

@test "the workflow token can write commit statuses" {
    grep -qx '    statuses: write' "$WORKFLOW"
}
