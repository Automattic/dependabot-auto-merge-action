#!/usr/bin/env bats
# Tests for the `if:` wiring of the reusable workflow. Several of its
# security boundaries are step conditions rather than scripts: a step that
# stops checking the output it depends on runs every script test green and
# still merges what it should refuse. These tests read the conditions out of
# the YAML so a change to that wiring has to change a test too.

load helpers

setup_file() {
    export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    # Guard the extractor against a silent miss. Gate 2's condition is
    # stable and folded, so it exercises the block form.
    grep -qF "steps.cvss.outputs.available == 'true'" <<<"$(extract_if gate2)"
}

# --- fast-track detection (QAO-765) ---------------------------------------

@test "the fast-track detection runs on every evaluation" {
    # extract_if prints nothing for a missing id as well as for a missing
    # condition, so check the step exists first.
    grep -q '^ *id: fast-track$' "$WORKFLOW"
    [ -z "$(extract_if fast-track)" ]
}

@test "the audit comment follows a detected fast-track only" {
    run extract_if fast-track-audit
    [ "$status" -eq 0 ]
    [ "$output" = "steps.fast-track.outputs.active == 'true'" ]
}

@test "the gates run unless a person enabled auto-merge" {
    grep -qF "steps.fast-track.outputs.active != 'true'" <<<"$(extract_if gate1)"
}

@test "nothing authorizes the fast-track label any more" {
    # The label is a marker. A condition that keys on it would hand merge
    # power back to anyone who can apply a label.
    ! grep -q 'fast-track-auth' "$WORKFLOW"
    ! grep -qF 'contains(github.event.pull_request.labels.*.name, inputs.fast-track-label)' "$WORKFLOW"
}

@test "the documented caller subscribes to auto-merge being enabled" {
    grep -qF 'types: [opened, synchronize, reopened, labeled, auto_merge_enabled]' "$REPO_ROOT/README.md"
}
