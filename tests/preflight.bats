#!/usr/bin/env bats
# Tests for the preflight job's repo checks, run against the gh stub in
# tests/stubs/. The step script is pulled out of the YAML and run as-is.
#
# The branch endpoint reports .protected for a ruleset as well as for classic
# protection, so a ruleset that names no check once read as protected and
# passed with a warning. Its .protection summary is classic protection only,
# names its checks, and needs no admin token, so preflight reads that first.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export PREFLIGHT_STEP="$BATS_FILE_TMPDIR/preflight.sh"
    extract_run preflight-checks >"$PREFLIGHT_STEP"
    # Guard the extractor: an empty script would pass every test that
    # expects exit 0.
    [ -s "$PREFLIGHT_STEP" ]
    bash -n "$PREFLIGHT_STEP"
    grep -q 'RULESET_CHECKS' "$PREFLIGHT_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_REPOSITORY="acme/widgets"
    export GITHUB_SERVER_URL="https://github.com"
    export MERGE_MODE=unattended
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$REPO_ROOT/tests/stubs:$PATH"

    printf '%s' '{"allow_auto_merge":true,"default_branch":"main"}' >"$GH_STUB_DIR/GET_repos_acme_widgets"
    rules_fixture '[]'
    # GITHUB_TOKEN gets a 403 from the admin-only endpoint.
    printf '%s\n' 'gh: Resource not accessible by integration (HTTP 403)' \
        >"$GH_STUB_DIR/GET_repos_acme_widgets_branches_main_protection.err"
}

RULES_KEY=GET_repos_acme_widgets_rules_branches_main_per_page_100
BRANCH_KEY=GET_repos_acme_widgets_branches_main

rules_fixture() {
    printf '%s' "$1" >"$GH_STUB_DIR/$RULES_KEY"
}

branch_fixture() {
    printf '%s' "$1" >"$GH_STUB_DIR/$BRANCH_KEY"
}

# A required_status_checks rule naming the checks in $@, none when empty.
ruleset_rule() {
    jq -nc '[{type: "required_status_checks",
              parameters: {strict_required_status_checks_policy: false,
                           required_status_checks: ($ARGS.positional | map({context: .}))}}]' \
        --args "$@"
}

# The branch endpoint's response, shaped as github.com returns it to
# GITHUB_TOKEN: $1 = .protected, $2 = .protection.enabled, then the
# contexts classic protection names.
branch_with_summary() {
    local protected=$1 enabled=$2
    shift 2
    jq -nc --argjson p "$protected" --argjson e "$enabled" '
        {name: "main", protected: $p,
         protection: {enabled: $e,
                      required_status_checks: {
                          enforcement_level: (if $e and ($ARGS.positional | length) > 0 then "non_admins" else "off" end),
                          contexts: $ARGS.positional,
                          checks: ($ARGS.positional | map({context: ., app_id: null}))}}}' \
        --args "$@"
}

# The flags match what the step's `shell: bash` expands to in Actions.
preflight_step() {
    bash --noprofile --norc -e -o pipefail "$PREFLIGHT_STEP"
}

@test "a ruleset that names a check passes" {
    rules_fixture "$(ruleset_rule sandbox-ci)"
    run preflight_step
    [ "$status" -eq 0 ]
    [[ $output == *"1 ruleset-based required status check(s)"* ]]
    [ "$(log_count 'branches/main ')" -eq 0 ]
}

@test "a ruleset that names no check, with no classic protection, fails" {
    # What github.com returned on asahasrabuddhe/dama-v171-fixture for an
    # active ruleset with an empty check list: protected, but no classic
    # protection.
    rules_fixture "$(ruleset_rule)"
    branch_fixture "$(branch_with_summary true false)"
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"::error::"*"no ruleset-based required status checks and no classic branch protection rule"* ]]
    [[ $output != *"::warning::"* ]]
}

@test "classic protection that names a check passes from the branch summary" {
    branch_fixture "$(branch_with_summary true true sandbox-ci)"
    run preflight_step
    [ "$status" -eq 0 ]
    [[ $output == *"OK: classic branch protection on 'main' requires status checks."* ]]
    [[ $output != *"::warning::"* ]]
    [ "$(log_count 'branches/main/protection')" -eq 0 ]
}

@test "classic protection that names no check fails from the branch summary" {
    branch_fixture "$(branch_with_summary true true)"
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"::error::Preflight: branch protection on 'main' has no required status checks"* ]]
    [ "$(log_count 'branches/main/protection')" -eq 0 ]
}

@test "an unprotected branch with no ruleset checks fails" {
    branch_fixture "$(branch_with_summary false false)"
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"::error::"*"no classic branch protection rule"* ]]
}

@test "without a summary, a protected branch falls back to the admin endpoint and warns" {
    # A host whose branch response carries no .protection summary.
    branch_fixture '{"name":"main","protected":true}'
    run preflight_step
    [ "$status" -eq 0 ]
    [[ $output == *"::warning::Preflight: 'main' has classic branch protection, but this token cannot read its details"* ]]
    [ "$(log_count 'branches/main/protection')" -eq 1 ]
}

@test "without a summary, a readable admin endpoint decides" {
    branch_fixture '{"name":"main","protected":true}'
    rm "$GH_STUB_DIR/GET_repos_acme_widgets_branches_main_protection.err"
    printf '%s' '{"required_status_checks":{"contexts":[],"checks":[]}}' \
        >"$GH_STUB_DIR/GET_repos_acme_widgets_branches_main_protection"
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"has no required status checks"* ]]
}

@test "auto-merge turned off fails" {
    printf '%s' '{"allow_auto_merge":false,"default_branch":"main"}' >"$GH_STUB_DIR/GET_repos_acme_widgets"
    rules_fixture "$(ruleset_rule sandbox-ci)"
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"::error::Preflight: 'Allow auto-merge' is disabled"* ]]
}

# --- merge mode (QAO-697) ---------------------------------------------------

# A human-only repo merges nothing on its own, and a person sees CI before
# merging. Failing preflight there would also stop the gates and the review
# routing, which a human-only repo still wants.

@test "human-only warns, rather than fails, when auto-merge is off" {
    export MERGE_MODE=human-only
    printf '%s' '{"allow_auto_merge":false,"default_branch":"main"}' >"$GH_STUB_DIR/GET_repos_acme_widgets"
    rules_fixture "$(ruleset_rule sandbox-ci)"
    run preflight_step
    [ "$status" -eq 0 ]
    [[ $output == *"::warning::Preflight: 'Allow auto-merge' is disabled"* ]]
    [[ $output != *"::error::"* ]]
}

@test "human-only warns, rather than fails, when no check is required" {
    export MERGE_MODE=human-only
    branch_with_summary false false >"$GH_STUB_DIR/$BRANCH_KEY"
    run preflight_step
    [ "$status" -eq 0 ]
    [[ $output == *"::warning::Preflight: default branch 'main' has no ruleset-based required status checks"* ]]
    [[ $output != *"::error::"* ]]
}

@test "an unrecognised merge mode fails before any API call" {
    export MERGE_MODE=human_only
    run preflight_step
    [ "$status" -eq 1 ]
    [[ $output == *"::error::Preflight: merge-mode is 'human_only'. Expected unattended or human-only."* ]]
    [ ! -s "$GH_STUB_LOG" ]
}
