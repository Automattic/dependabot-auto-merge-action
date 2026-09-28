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

@test "a recorded pass depends on the job status" {
    # The script checks JOB_STATUS, so it has to be wired to job.status.
    grep -qF 'JOB_STATUS: ${{ job.status }}' "$WORKFLOW"
}

@test "the scheduled merge runs under pipefail" {
    grep -A4 '^ *id: scheduled-merge$' "$WORKFLOW" | grep -q '^ *shell: bash$'
}

@test "the workflow token can write commit statuses" {
    grep -qx '    statuses: write' "$WORKFLOW"
}

# --- merge boundary (QAO-768) --------------------------------------------

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

@test "nothing in the workflow enables or disables auto-merge" {
    # The scheduled merge merges directly. Only a person turns auto-merge on.
    # Only real calls count. Preflight's messages still name `--auto`,
    # because a person's fast-track needs the repository setting.
    grep -qE 'gh pr merge "' "$WORKFLOW"
    ! grep -E 'gh pr merge "' "$WORKFLOW" | grep -qE -- '--auto|--disable-auto'
}
