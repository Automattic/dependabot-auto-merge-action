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

# --- revocation (QAO-768) -------------------------------------------------

# Print the lines of job $1, from its key up to the next job's key.
job_block() {
    awk -v job="$1" '
        $0 ~ "^    " job ":$" { injob = 1; next }
        injob && /^    [A-Za-z0-9_-]+:$/ { exit }
        injob { print }
    ' "$WORKFLOW"
}

@test "removing the fast-track label triggers an evaluation, and removing others does not" {
    for job in preflight evaluate-pr; do
        grep -qF "github.event.action != 'unlabeled' || github.event.label.name == inputs.fast-track-label" \
            <<<"$(job_block "$job")"
    done
}

@test "the documented caller subscribes to label removal" {
    grep -qF 'types: [opened, synchronize, reopened, labeled, unlabeled]' "$REPO_ROOT/README.md"
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
    [ "$output" = "always() && steps.fast-track.conclusion != 'success'" ]
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
