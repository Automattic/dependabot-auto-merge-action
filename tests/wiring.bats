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

# --- permissions (QAO-767) --------------------------------------------------

# Alerts are read with a token minted from the caller's App, or with
# secrets.token, so the workflow requests no alerts permission. A called workflow cannot hold a permission its caller did not
# grant, so requesting either scope would refuse to start some callers.
@test "the workflow requests no Dependabot alerts permission" {
    block=$(awk '/^permissions:/{p=1; next} p && /^[^ #]/{exit} p' "$WORKFLOW" | grep -v '^ *#')
    ! grep -q 'vulnerability-alerts' <<<"$block"
    ! grep -q 'security-events' <<<"$block"
}

# fetch-metadata's alert lookup is off, so it needs the token only to list
# the PR's commits. GITHUB_TOKEN can, and an alerts-only token cannot on a
# private repo. Handing it the secret broke every Dependabot run on private
# repos whose token was scoped to alerts alone.
@test "fetch-metadata gets GITHUB_TOKEN, never the token secret" {
    run grep -c 'uses: .*fetch-metadata@' "$WORKFLOW"
    [ "$output" -eq 2 ]
    run grep -A4 'uses: .*fetch-metadata@' "$WORKFLOW"
    [ "$(grep -c 'github-token: \${{ github.token }}$' <<<"$output")" -eq 2 ]
    ! grep -q 'secrets.token' <<<"$output"
}

# --- GitHub App alerts token (QAO-477) -------------------------------------

# Print the step whose id is $1, from its `- ` line to the next step.
step_block() {
    awk -v id="$1" '
        /^ +- (name|uses|id|run):/ { if (hit) exit; buf = "" }
        { buf = buf $0 "\n" }
        $0 ~ "^ +id: " id "$" { hit = 1 }
        hit && !printed { printf "%s", buf; printed = 1; next }
        hit { print }
    ' "$WORKFLOW"
}

@test "the App token is minted with the pinned action" {
    run step_block app-token
    grep -qF 'uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0' <<<"$output"
}

@test "the App token reads Dependabot alerts in this repository only" {
    run extract_key app-token with
    [ "$(grep -c 'permission-' <<<"$output")" -eq 1 ]
    grep -qF 'permission-vulnerability-alerts: read' <<<"$output"
    grep -qF 'repositories: ${{ github.event.repository.name }}' <<<"$output"
    grep -qF 'owner: ${{ github.repository_owner }}' <<<"$output"
}

@test "the App token is minted only when both App secrets are passed" {
    grep -qF "APP_CONFIGURED: \${{ secrets.app-client-id != '' && secrets.app-private-key != '' }}" "$WORKFLOW"
    grep -qF "env.APP_CONFIGURED == 'true'" <<<"$(extract_if app-token)"
}

# Minting costs an API call and a token on every evaluation, so it runs only
# when the alerts lookup will.
@test "the App token is minted only when the alerts lookup runs" {
    fallback=$(extract_if gate1-fallback)
    mint=$(extract_if app-token)
    [ -n "$fallback" ] && [ -n "$mint" ]
    while IFS= read -r line; do
        grep -qF "$line" <<<"$mint"
    done <<<"$fallback"
}

@test "the App token is minted before the alerts lookup" {
    mint=$(grep -n '^ *id: app-token$' "$WORKFLOW" | cut -d: -f1)
    fallback=$(grep -n '^ *id: gate1-fallback$' "$WORKFLOW" | cut -d: -f1)
    [ -n "$mint" ] && [ -n "$fallback" ]
    [ "$mint" -lt "$fallback" ]
}

@test "the alerts lookup prefers the App token, then the token secret, then GITHUB_TOKEN" {
    run extract_key gate1-fallback env
    [ "$(grep -cF 'GH_TOKEN: ${{ steps.app-token.outputs.token || secrets.token || github.token }}' <<<"$output")" -eq 1 ]
    [ "$(grep -cF 'GH_ENTERPRISE_TOKEN: ${{ steps.app-token.outputs.token || secrets.token || github.token }}' <<<"$output")" -eq 1 ]
}

@test "only the alerts lookup receives the App token" {
    [ "$(grep -c 'steps.app-token.outputs.token' "$WORKFLOW")" -eq 2 ]
    [ "$(step_block gate1-fallback | grep -c 'steps.app-token.outputs.token')" -eq 2 ]
}

# The token reaches the step as GH_TOKEN, which gh reads without printing.
# A step that echoed it, or wrote it to GITHUB_ENV or GITHUB_OUTPUT, would
# put a live credential in the log or hand it to every later step.
@test "nothing prints or exports the App token" {
    ! grep -qE '(echo|printf).*(GH_TOKEN|GH_ENTERPRISE_TOKEN|app-token)' "$WORKFLOW"
    ! grep -qE '(GH_TOKEN|GH_ENTERPRISE_TOKEN).*>> *"?\$(GITHUB_ENV|GITHUB_OUTPUT)' "$WORKFLOW"
    ! grep -qE 'outputs:.*app-token|: \$\{\{ *steps\.app-token\.outputs\.token *\}\}$' "$WORKFLOW"
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
