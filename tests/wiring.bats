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

# --- eligibility evidence (QAO-766) ---------------------------------------

@test "every evaluation that did not fast-track records its verdict" {
    # always(), so an evaluation that errors part-way still withdraws
    # evidence an earlier run recorded for the same commit.
    run extract_if record-eligibility
    [ "$output" = "always() && steps.fast-track.outputs.active != 'true'" ]
}

@test "the workflow token can write commit statuses" {
    grep -qx '    statuses: write' "$WORKFLOW"
}

# --- revocation (QAO-768) -------------------------------------------------

# Print the lines of job $1, from its key up to the next job's key.
job_block() {
    awk -v job="$1" '
        $0 ~ "^    " job ":$" { injob = 1; next }
        injob && /^    [A-Za-z0-9_-]+:$/ { exit }
        injob { print }
    ' "$WORKFLOW"
}

@test "no event is filtered on the label it removes" {
    # The fast-track label is a marker, so its removal means nothing and
    # the jobs must not read the removed label at all.
    for job in preflight evaluate-pr; do
        ! grep -qF "github.event.label" <<<"$(job_block "$job")"
    done
}

@test "evaluations of the same PR never run at the same time" {
    block=$(job_block evaluate-pr)
    grep -qE '^        concurrency:$' <<<"$block"
    grep -qF 'group: ' <<<"$block"
    grep -qF 'github.event.pull_request.number' <<<"$(grep -F 'group: ' <<<"$block")"
    # false: a newer evaluation waits for the running one instead of
    # cancelling it half-way through withdrawing evidence.
    grep -qE '^            cancel-in-progress: false$' <<<"$block"
}

@test "every evaluation that did not fast-track can revoke a queued auto-merge" {
    run extract_if revoke-auto-merge
    [ "$output" = "always() && steps.fast-track.outputs.active != 'true'" ]
}

@test "evidence is withdrawn before a queued auto-merge is disabled" {
    # The scheduled merge re-checks evidence after queueing. That only
    # closes the race if evaluation withdraws the evidence first.
    record=$(grep -n '^ *id: record-eligibility$' "$WORKFLOW" | cut -d: -f1)
    revoke=$(grep -n '^ *id: revoke-auto-merge$' "$WORKFLOW" | cut -d: -f1)
    [ -n "$record" ]
    [ -n "$revoke" ]
    [ "$record" -lt "$revoke" ]
}
