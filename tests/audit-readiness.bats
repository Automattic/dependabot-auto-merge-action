#!/usr/bin/env bats
# Tests for scripts/audit-readiness.sh, run against the gh stub in tests/stubs/.
#
# The contract these tests exist to defend: a check the caller's token cannot
# see is reported `unknown`, never `fail`. Calling a repo broken when we simply
# could not look is the failure mode that costs trust with the teams who own
# these repos, so most of what follows is about that distinction.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/audit-readiness.sh"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    OUT="$BATS_TEST_TMPDIR/out"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

fixture() {
    cat >"$GH_STUB_DIR/$1"
}

mutation_count() {
    grep -cE -- '-X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG" || true
}

log_count() {
    grep -cF -- "$1" "$GH_STUB_LOG" || true
}

# The caller workflow exactly as the eight onboarded repos ship it.
good_caller() {
    cat <<'EOF'
name: Dependabot auto-merge
on:
  pull_request_target:
    types: [opened, synchronize, reopened, labeled]
  schedule:
    - cron: '0 9 * * *'
permissions:
  pull-requests: write
  contents: write
  security-events: read
jobs:
  dependabot-auto-merge:
    uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@8143c95d871e96dc12cb448aa1dde9c2abae694e # v1.5
    permissions:
      pull-requests: write
      contents: write
      security-events: read
    with:
      event-name: ${{ github.event_name }}
    secrets:
      token: ${{ secrets.QUALITYOPS_DEPENDABOT_ALERTS_TOKEN }}
EOF
}

# Repo and organisation secret listings for repo $2, acme/widgets by default.
# Values are never readable through the API; names are, which is all the check
# needs.
secrets_fixture() {
    local names=${1:-QUALITYOPS_DEPENDABOT_ALERTS_TOKEN} key
    key=${2:-acme/widgets}
    key=${key//\//_}
    jq -cn --arg n "$names" '{secrets: ($n | split(",") | map(select(length > 0) | {name: .}))}' \
        | fixture "GET_repos_${key}_actions_secrets_per_page_100"
    fixture "GET_repos_${key}_actions_organization_secrets_per_page_100" <<<'{"secrets":[]}'
}

# A repo where every check passes. Tests patch this with a jq expression to
# break exactly one thing, so a failure names its own cause.
base_node() {
    jq -n --arg caller "$(good_caller)" '{
      nameWithOwner: "acme/widgets",
      isArchived: false, isFork: false, isPrivate: false, isDisabled: false, isEmpty: false,
      pushedAt: "2026-09-01T00:00:00Z",
      autoMergeAllowed: true, squashMergeAllowed: true,
      mergeCommitAllowed: true, rebaseMergeAllowed: true,
      viewerPermission: "ADMIN", hasVulnerabilityAlertsEnabled: true,
      openAlerts: {totalCount: 0}, everAlerts: {totalCount: 5},
      latestRelease: null,
      defaultBranchRef: {
        name: "main",
        target: {committedDate: "2026-09-01T00:00:00Z", history: {totalCount: 100}},
        branchProtectionRule: null,
        rules: {totalCount: 1, nodes: [{
          type: "REQUIRED_STATUS_CHECKS",
          parameters: {
            __typename: "RequiredStatusChecksParameters",
            strictRequiredStatusChecksPolicy: false,
            requiredStatusChecks: [{context: "ci"}]
          },
          repositoryRuleset: {name: "Main rules", enforcement: "ACTIVE"}
        }]}
      },
      ft:   {nodes: [{name: "security-fast-track",  color: "0075ca", description: "x"}]},
      pend: {nodes: [{name: "auto-merge-pending",   color: "e4e669", description: "x"}]},
      sirt: {nodes: [{name: "sirt-review-required", color: "d93f0b", description: "x"}]},
      depYml: {byteSize: 100}, depYaml: null,
      caller: {byteSize: 559, isTruncated: false, text: $caller},
      root: {entries: [{name: "composer.json", type: "blob"}, {name: "package.json", type: "blob"}]}
    }'
}

# Always needed: the script probes GraphQL reachability before anything else.
viewer_fixture() {
    fixture graphql_Viewer <<<'{"data":{"viewer":{"login":"tester"},"rateLimit":{"remaining":4999}}}'
}

# Write a RepoSet response (the --repo path) from base_node patched by $1.
repo_set() {
    local patch=${1:-.}
    viewer_fixture
    secrets_fixture
    base_node | jq --argjson rl '{"cost":1,"remaining":4999,"resetAt":null}' \
        "{data: {rateLimit: \$rl, r_0: ($patch)}}" | fixture graphql_RepoSet
}

# Write a RepoSet response holding several nodes; each argument is a jq patch.
repo_set_many() {
    viewer_fixture
    secrets_fixture
    local out i=0 patch
    out=$(jq -n '{data: {rateLimit: {cost: 1, remaining: 4999, resetAt: null}}}')
    for patch in "$@"; do
        out=$(base_node | jq --argjson acc "$out" \
            "\$acc * {data: {r_$i: ($patch)}}")
        i=$((i + 1))
    done
    printf '%s' "$out" | fixture graphql_RepoSet
}

run_audit() {
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl "$@"
}

# Read a jq path out of the single record the run produced.
rec() {
    jq -r "$1" "$OUT/repos.jsonl"
}

# --- argument validation ------------------------------------------------------

@test "no arguments exits 2 with usage" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ $output == *"missing required argument"* ]]
    [[ $output == *"Usage:"* ]]
}

@test "no arguments makes no API call" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [ ! -s "$GH_STUB_LOG" ]
}

@test "invalid repository is refused" {
    run "$SCRIPT" --repo widgets
    [ "$status" -eq 2 ]
    [[ $output == *"invalid repository"* ]]
}

@test "a literal placeholder repo never reaches gh" {
    run "$SCRIPT" --repo '{owner}/{repo}'
    [ "$status" -eq 2 ]
    [ ! -s "$GH_STUB_LOG" ]
}

@test "--org and --repo together are refused" {
    run "$SCRIPT" --org acme --repo acme/widgets
    [ "$status" -eq 2 ]
    [[ $output == *"mutually exclusive"* ]]
}

@test "unknown option names itself" {
    run "$SCRIPT" --repo acme/widgets --frobnicate
    [ "$status" -eq 2 ]
    [[ $output == *"unknown option: --frobnicate"* ]]
}

@test "an option swallowing the next flag is refused before anything runs" {
    run "$SCRIPT" --repo acme/widgets --team --format
    [ "$status" -eq 2 ]
    [ ! -s "$GH_STUB_LOG" ]
}

@test "invalid --format, --status, --wave, --jobs and --merge-method are each refused" {
    run "$SCRIPT" --repo acme/widgets --format bogus
    [ "$status" -eq 2 ]
    run "$SCRIPT" --repo acme/widgets --status bogus
    [ "$status" -eq 2 ]
    run "$SCRIPT" --repo acme/widgets --wave 9
    [ "$status" -eq 2 ]
    run "$SCRIPT" --repo acme/widgets --jobs 0
    [ "$status" -eq 2 ]
    run "$SCRIPT" --repo acme/widgets --merge-method bogus
    [ "$status" -eq 2 ]
}

@test "the equals form of an option is accepted" {
    repo_set
    run "$SCRIPT" --repo=acme/widgets --out-dir="$OUT" --format=jsonl --merge-method=squash
    [ "$status" -eq 0 ]
    [ "$(rec .checks.merge_method.status)" = "pass" ]
}

# --- read-only discipline -----------------------------------------------------

@test "a full run issues no mutation" {
    repo_set
    run_audit
    [ "$status" -eq 0 ]
    [ "$(mutation_count)" -eq 0 ]
    [ "$(log_count 'gh pr')" -eq 0 ]
}

@test "--from-jsonl re-renders with no API call at all" {
    repo_set
    run_audit
    [ "$status" -eq 0 ]
    : >"$GH_STUB_LOG"
    run "$SCRIPT" --from-jsonl "$OUT/repos.jsonl" --format summary
    [ "$status" -eq 0 ]
    [ ! -s "$GH_STUB_LOG" ]
    [[ $output == *"Repositories audited: 1"* ]]
}

# --- the taxonomy -------------------------------------------------------------

@test "a fully configured repo is ready" {
    repo_set
    run_audit
    [ "$status" -eq 0 ]
    [ "$(rec .verdict)" = "ready" ]
    [ "$(rec '.blockers | length')" -eq 0 ]
    [ "$(rec '.unknowns | length')" -eq 0 ]
}

@test "auto-merge off blocks, and --exit-code turns that into exit 1" {
    repo_set '. * {autoMergeAllowed: false}'
    run_audit
    [ "$status" -eq 0 ]
    [ "$(rec .verdict)" = "blocked" ]
    [ "$(rec '.blockers | index("auto_merge") != null')" = "true" ]
    repo_set '. * {autoMergeAllowed: false}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --exit-code
    [ "$status" -eq 1 ]
}

@test "a GraphQL error on one field reports unknown, not fail" {
    viewer_fixture
    secrets_fixture
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            r_0: (. * {hasVulnerabilityAlertsEnabled: null})},
                     errors: [{message: "Resource not accessible",
                               path: ["r_0", "hasVulnerabilityAlertsEnabled"]}]}' \
        | fixture graphql_RepoSet
    run_audit
    [ "$status" -eq 0 ]
    [ "$(rec .checks.vuln_alerts.status)" = "unknown" ]
    [ "$(rec .verdict)" = "unknown" ]
    [ "$(rec '.blockers | length')" -eq 0 ]
}

@test "a fail outranks an unknown in the verdict" {
    viewer_fixture
    secrets_fixture
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            r_0: (. * {autoMergeAllowed: false,
                                       hasVulnerabilityAlertsEnabled: null})},
                     errors: [{message: "nope", path: ["r_0", "hasVulnerabilityAlertsEnabled"]}]}' \
        | fixture graphql_RepoSet
    run_audit
    [ "$(rec .verdict)" = "blocked" ]
    [ "$(rec '.blockers | length')" -eq 1 ]
    [ "$(rec '.unknowns | length')" -eq 1 ]
}

@test "one broken node does not lose the others in the same page" {
    repo_set_many '. * {nameWithOwner: "acme/one"}' \
                  '. * {nameWithOwner: "acme/two", autoMergeAllowed: false}' \
                  '. * {nameWithOwner: "acme/three"}'
    run "$SCRIPT" --repo acme/one --repo acme/two --repo acme/three \
        --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 3 ]
}

# --- required checks: parity with the workflow's preflight job ----------------

@test "a ruleset with checks passes without any REST call" {
    repo_set
    run_audit
    [ "$(rec .checks.required_checks.status)" = "pass" ]
    [ "$(rec .checks.required_checks.path)" = "ruleset" ]
    [ "$(log_count 'branches')" -eq 0 ]
}

@test "classic protection visible in the bulk sweep passes without a REST call" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []},
                                      branchProtectionRule: {requiresStatusChecks: true,
                                                             requiredStatusCheckContexts: ["ci"],
                                                             requiredApprovingReviewCount: 0}}}'
    run_audit
    [ "$(rec .checks.required_checks.status)" = "pass" ]
    [ "$(rec .checks.required_checks.path)" = "classic" ]
    [ "$(log_count 'branches')" -eq 0 ]
}

@test "an unprotected default branch fails" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":false}'
    run_audit
    [ "$(rec .checks.required_checks.status)" = "fail" ]
    [ "$(rec .verdict)" = "blocked" ]
}

@test "protected with required checks passes via the classic fallback" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":true}'
    fixture GET_repos_acme_widgets_branches_main_protection <<<'{"required_status_checks":{"contexts":["ci"]}}'
    run_audit
    [ "$(rec .checks.required_checks.status)" = "pass" ]
}

@test "protected with no required checks fails" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":true}'
    fixture GET_repos_acme_widgets_branches_main_protection <<<'{"required_status_checks":null}'
    run_audit
    [ "$(rec .checks.required_checks.status)" = "fail" ]
}

@test "protected but unreadable protection is unknown, matching preflight's warn" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":true}'
    # No protection fixture: the stub 404s, exactly as the admin-only endpoint
    # does for a token without admin.
    run_audit
    [ "$(rec .checks.required_checks.status)" = "unknown" ]
    [ "$(rec .verdict)" = "unknown" ]
    [[ "$(rec .checks.required_checks.detail)" == *"admin token"* ]]
}

@test "an unreadable branch is unknown, never fail" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main.err <<<'gh: Not Found (HTTP 404)'
    run_audit
    [ "$(rec .checks.required_checks.status)" = "unknown" ]
}

@test "a branch name with URL-significant characters is encoded" {
    repo_set '. * {defaultBranchRef: {name: "feature/x#1",
                                      rules: {totalCount: 0, nodes: []},
                                      branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_feature_2Fx_231 <<<'{"protected":false}'
    run_audit
    [ "$(log_count 'feature%2Fx%231')" -ge 1 ]
}

# --- labels -------------------------------------------------------------------

@test "all three labels present passes" {
    repo_set
    run_audit
    [ "$(rec .checks.labels.status)" = "pass" ]
}

@test "a missing label fails and names itself" {
    repo_set '. * {pend: {nodes: []}}'
    run_audit
    [ "$(rec .checks.labels.status)" = "fail" ]
    [[ "$(rec .checks.labels.detail)" == *"auto-merge-pending"* ]]
}

@test "labels differing only in case pass, because the runtime is case-insensitive" {
    repo_set '. * {ft: {nodes: [{name: "Security-Fast-Track", color: "0075ca", description: "x"}]}}'
    run_audit
    [ "$(rec .checks.labels.status)" = "pass" ]
}

@test "fuzzy label search results are not counted as a match" {
    # labels(query:) is a substring search that returns junk; only an exact
    # (case-insensitive) name may satisfy the check.
    repo_set '. * {sirt: {nodes: [{name: "forge", color: "ffffff", description: "x"}]}}'
    run_audit
    [ "$(rec .checks.labels.status)" = "fail" ]
    [[ "$(rec .checks.labels.detail)" == *"sirt-review-required"* ]]
}

@test "a custom label name is sent in the query and checked" {
    repo_set '. * {ft: {nodes: [{name: "fast-track", color: "0075ca", description: "x"}]}}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --fast-track-label fast-track
    [ "$status" -eq 0 ]
    [ "$(rec .checks.labels.status)" = "pass" ]
}

@test "a label whose colour drifted still passes, as a risk" {
    repo_set '. * {ft: {nodes: [{name: "security-fast-track", color: "123456", description: "x"}]}}'
    run_audit
    [ "$(rec .checks.labels.status)" = "pass" ]
    [ "$(rec '.risks | map(.id) | index("label_drift") != null')" = "true" ]
}

# --- dependabot config --------------------------------------------------------

@test "a .yaml config fails, because Dependabot only reads .yml" {
    repo_set '. * {depYml: null, depYaml: {byteSize: 50}}'
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "fail" ]
    [[ "$(rec .checks.dependabot_config.detail)" == *".yml"* ]]
}

@test "no manifest anywhere is n/a, not a failure" {
    repo_set '. * {depYml: null, depYaml: null, caller: null,
                   root: {entries: [{name: "README.md", type: "blob"}]}}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"README.md"},{"type":"blob","path":"src/thing.php"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "na" ]
    [ "$(rec .verdict)" = "na" ]
    [ "$(rec .wave.band)" = "null" ]
}

@test "manifests only in subdirectories are found, not read as no dependencies" {
    # Keying manifest detection on the root tree alone dropped these repos out
    # of the rollout entirely while reporting them as having nothing to scan.
    repo_set '. * {depYml: null, depYaml: null,
                   root: {entries: [{name: "README.md", type: "blob"}]}}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"README.md"},{"type":"blob","path":"packages/a/package.json"},{"type":"blob","path":"packages/b/composer.json"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "fail" ]
    [ "$(rec .verdict)" != "na" ]
    [[ "$(rec .checks.dependabot_config.detail)" == *"packages/a/package.json"* ]]
}

@test "no config passes when every manifest is at the root" {
    # Dependabot's security updates cover default paths without a config, so
    # requiring one here would fail a repo that is actually fine.
    repo_set '. * {depYml: null, depYaml: null}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"composer.json"},{"type":"blob","path":"package.json"},{"type":"blob","path":"src/Thing.php"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "pass" ]
    [ "$(rec .verdict)" = "ready" ]
}

@test "no config fails when a manifest sits outside the root" {
    repo_set '. * {depYml: null, depYaml: null}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"package.json"},{"type":"blob","path":"packages/thing/package.json"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "fail" ]
    [[ "$(rec .checks.dependabot_config.detail)" == *"packages/thing/package.json"* ]]
}

@test "vendored and fixture manifests do not count as needing a mapping" {
    # Matches the hard and soft exclusion lists in docs/directory-mapping.md.
    repo_set '. * {depYml: null, depYaml: null}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"composer.json"},{"type":"blob","path":"vendor/acme/lib/composer.json"},{"type":"blob","path":"node_modules/x/package.json"},{"type":"blob","path":"utils/__tests__/fixtures/test-package/package.json"},{"type":"blob","path":"dist/package.json"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "pass" ]
}

@test "an unreadable file tree is not reported as having no dependencies" {
    # "no manifest found" and "could not look" are different answers, and
    # calling the second one not-applicable drops the repo from the rollout.
    repo_set '. * {depYml: null, depYaml: null, caller: null,
                   root: {entries: [{name: "README.md", type: "blob"}]}}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":true,"tree":[]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "unknown" ]
    [ "$(rec .verdict)" = "unknown" ]
}

@test "a truncated file tree is unknown, never a verdict" {
    # Deciding on an incomplete list is the exact failure this check exists to
    # catch, so it refuses rather than guessing.
    repo_set '. * {depYml: null, depYaml: null}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":true,"tree":[{"type":"blob","path":"package.json"}]}
EOF
    run_audit
    [ "$(rec .checks.dependabot_config.status)" = "unknown" ]
    [[ "$(rec .checks.dependabot_config.detail)" == *"truncated"* ]]
}

# --- caller workflow ----------------------------------------------------------

@test "the shipped caller shape passes and reports its pin" {
    repo_set
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "pass" ]
    [ "$(rec .caller.ref_kind)" = "sha" ]
    [ "$(rec .caller.version_comment)" = "v1.5" ]
}

@test "a tag pin fails, because the org requires SHA pinning" {
    repo_set '.caller.text |= sub("@8143c95d871e96dc12cb448aa1dde9c2abae694e"; "@v1.5")'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "fail" ]
    [[ "$(rec .checks.caller_workflow.detail)" == *"commit SHA"* ]]
}

@test "types without labeled fails, because fast-track cannot work" {
    repo_set '.caller.text |= sub("\\[opened, synchronize, reopened, labeled\\]"; "[opened, synchronize]")'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "fail" ]
    [[ "$(rec .checks.caller_workflow.detail)" == *"labeled"* ]]
}

@test "a missing schedule trigger fails, because the age gate never fires" {
    repo_set '.caller.text |= sub("  schedule:\n    - cron: .0 9 \\* \\* \\*.\n"; "")'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "fail" ]
    [[ "$(rec .checks.caller_workflow.detail)" == *"age gate"* ]]
}

@test "permissions present in only one block fails" {
    repo_set '.caller.text |= sub("    permissions:\n      pull-requests: write\n      contents: write\n      security-events: read\n"; "")'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "fail" ]
    [[ "$(rec .checks.caller_workflow.detail)" == *"permissions"* ]]
}

@test "a caller we cannot parse is unknown, never fail" {
    repo_set '.caller.text = "on:\n\tpull_request_target:\n\t\ttypes: [labeled]\n"'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "unknown" ]
    [[ "$(rec .caller.shape)" == unrecognized* ]]
    [ "$(rec .verdict)" = "unknown" ]
}

@test "a repo that has not adopted yet is not reported as broken" {
    # Adding the caller workflow is the step this audit exists to plan. A repo
    # without one is the normal case, not a fault.
    repo_set '. * {caller: null}'
    run_audit
    [ "$(rec .checks.caller_workflow.status)" = "na" ]
    [ "$(rec .adoption)" = "not-adopted" ]
    [ "$(rec '.blockers | index("caller_workflow")')" = "null" ]
}

@test "a caller workflow that is present and malformed is a blocker" {
    repo_set '.caller.text |= sub("@8143c95d871e96dc12cb448aa1dde9c2abae694e"; "@v1.5")'
    run_audit
    [ "$(rec .adoption)" = "adopted-broken" ]
    [ "$(rec '.blockers | index("caller_workflow") != null')" = "true" ]
}

@test "a well-formed caller workflow reports as adopted" {
    repo_set
    run_audit
    [ "$(rec .adoption)" = "adopted" ]
}

# --- alerts token -------------------------------------------------------------

@test "the alerts token passes when the secret the caller names exists" {
    repo_set
    run_audit
    [ "$(rec .checks.alerts_token.status)" = "pass" ]
    [ "$(rec .checks.alerts_token.secret)" = "QUALITYOPS_DEPENDABOT_ALERTS_TOKEN" ]
}

@test "a missing alerts token blocks, because GITHUB_TOKEN cannot read that API" {
    repo_set
    secrets_fixture "SOME_OTHER_SECRET"
    run_audit
    [ "$(rec .checks.alerts_token.status)" = "fail" ]
    [ "$(rec '.blockers | index("alerts_token") != null')" = "true" ]
    [[ "$(rec .checks.alerts_token.detail)" == *"GITHUB_TOKEN cannot read"* ]]
}

@test "an organisation secret satisfies the alerts token check" {
    repo_set
    secrets_fixture ""
    fixture GET_repos_acme_widgets_actions_organization_secrets_per_page_100 \
        <<<'{"secrets":[{"name":"QUALITYOPS_DEPENDABOT_ALERTS_TOKEN"}]}'
    run_audit
    [ "$(rec .checks.alerts_token.status)" = "pass" ]
}

@test "the secret name is read from the caller rather than assumed" {
    repo_set '.caller.text |= sub("QUALITYOPS_DEPENDABOT_ALERTS_TOKEN"; "MY_OWN_TOKEN")'
    secrets_fixture "MY_OWN_TOKEN"
    run_audit
    [ "$(rec .checks.alerts_token.status)" = "pass" ]
    [ "$(rec .checks.alerts_token.secret)" = "MY_OWN_TOKEN" ]
}

@test "a caller with no secrets block falls back to the configured name" {
    repo_set '.caller.text |= sub("\n    secrets:\n      token: \\$\\{\\{ secrets.QUALITYOPS_DEPENDABOT_ALERTS_TOKEN \\}\\}"; "")'
    secrets_fixture "QUALITYOPS_DEPENDABOT_ALERTS_TOKEN"
    run_audit
    [ "$(rec .checks.alerts_token.secret)" = "QUALITYOPS_DEPENDABOT_ALERTS_TOKEN" ]
    [ "$(rec .checks.alerts_token.status)" = "pass" ]
}

@test "--alerts-token-secret changes the name looked for" {
    repo_set '.caller.text |= sub("\n    secrets:\n      token: \\$\\{\\{ secrets.QUALITYOPS_DEPENDABOT_ALERTS_TOKEN \\}\\}"; "")'
    secrets_fixture "WOO_ALERTS_TOKEN"
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --alerts-token-secret WOO_ALERTS_TOKEN
    [ "$status" -eq 0 ]
    [ "$(rec .checks.alerts_token.status)" = "pass" ]
}

@test "secrets we cannot list are unknown, not a missing token" {
    # Listing repository secrets needs admin, so a lead without it must not be
    # told their repo is broken.
    repo_set
    rm -f "$GH_STUB_DIR/GET_repos_acme_widgets_actions_secrets_per_page_100"
    fixture GET_repos_acme_widgets_actions_secrets_per_page_100.err <<<'gh: Not Found (HTTP 404)'
    run_audit
    [ "$(rec .checks.alerts_token.status)" = "unknown" ]
    [ "$(rec '.blockers | index("alerts_token")')" = "null" ]
}

@test "the alerts token is not something bootstrap.sh can fix" {
    repo_set
    secrets_fixture "NOTHING_USEFUL"
    run_audit
    [ "$(rec '.remediation.needs_work | index("alerts_token") != null')" = "true" ]
    [ "$(rec '.remediation.bootstrap_fixes | index("alerts_token")')" = "null" ]
}

# --- merge method and risks ---------------------------------------------------

@test "squash disabled fails under the default merge method" {
    repo_set '. * {squashMergeAllowed: false}'
    run_audit
    [ "$(rec .checks.merge_method.status)" = "fail" ]
}

@test "--merge-method merge checks the merge-commit setting instead" {
    repo_set '. * {squashMergeAllowed: false, mergeCommitAllowed: true}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --merge-method merge
    [ "$status" -eq 0 ]
    [ "$(rec .checks.merge_method.status)" = "pass" ]
}

@test "a strict required-status-checks policy is a risk, not a blocker" {
    repo_set '.defaultBranchRef.rules.nodes[0].parameters.strictRequiredStatusChecksPolicy = true'
    run_audit
    [ "$(rec .verdict)" = "ready" ]
    [ "$(rec '.risks | map(.id) | index("strict_required_status_checks") != null')" = "true" ]
}

@test "an approval rule is a risk, because a bot PR can never satisfy it" {
    repo_set '.defaultBranchRef.rules.nodes += [{type: "PULL_REQUEST",
        parameters: {__typename: "PullRequestParameters", requiredApprovingReviewCount: 1},
        repositoryRuleset: {name: "Main rules", enforcement: "ACTIVE"}}]'
    run_audit
    [ "$(rec '.risks | map(.id) | index("approval_rule") != null')" = "true" ]
}

@test "a ruleset that is not active is a risk" {
    repo_set '.defaultBranchRef.rules.nodes[0].repositoryRuleset.enforcement = "EVALUATE"'
    run_audit
    [ "$(rec '.risks | map(.id) | index("ruleset_not_active") != null')" = "true" ]
}

@test "alerts on with none ever seen is the stub-lockfile risk" {
    repo_set '. * {everAlerts: {totalCount: 0}}'
    run_audit
    [ "$(rec '.risks | map(.id) | index("alerts_enabled_no_alerts_ever") != null')" = "true" ]
}

@test "the stub-lockfile risk is suppressed when the alert counts cannot be trusted" {
    # A low-access viewer gets a silent 0 rather than an error, so an untrusted
    # zero must not be reported as a finding.
    repo_set '. * {everAlerts: {totalCount: 0}, viewerPermission: "READ"}'
    run_audit
    [ "$(rec .activity.alert_counts_trusted)" = "false" ]
    [ "$(rec '.risks | map(.id) | index("alerts_enabled_no_alerts_ever")')" = "null" ]
}

# --- ownership ----------------------------------------------------------------

# Minimal --org fixture set: one page of repos, a team list, and per-team repos.
org_fixtures() {
    viewer_fixture
    fixture graphql_OrgProbe <<<'{"data":{"organization":{"login":"acme"}}}'
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            organization: {repositories: {
                              pageInfo: {hasNextPage: false, endCursor: null},
                              totalCount: 1, nodes: [.]}}}}' \
        | fixture graphql_RepoPage
    fixture graphql_DependabotPRs <<<'{"data":{"rateLimit":{"cost":1,"remaining":4999},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
}

# $1 is a jq array of {slug,size}; $2 maps slug -> permission for acme/widgets.
team_fixtures() {
    fixture graphql_TeamList <<EOF
{"data":{"rateLimit":{"cost":1,"remaining":4999},"organization":{"teams":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":$(jq -c 'map({slug: .slug, repositories: {totalCount: .size}})' <<<"$1")}}}}
EOF
    # One sequenced TeamRepos response per surviving team, in team-decisions order.
    local i=0 slug
    for slug in $(jq -r '.[].slug' <<<"$1"); do
        i=$((i + 1))
        jq -cn --arg s "$slug" --arg p "$(jq -r --arg s "$slug" '.[$s] // "ADMIN"' <<<"$2")" '
          {data: {rateLimit: {cost: 1, remaining: 4999},
                  organization: {team: {slug: $s, repositories: {
                    pageInfo: {hasNextPage: false, endCursor: null},
                    edges: [{permission: $p, node: {nameWithOwner: "acme/widgets"}}]}}}}}' \
            | fixture "graphql_TeamRepos.$i"
    done
}

@test "the smallest candidate team with admin wins" {
    org_fixtures
    team_fixtures '[{"slug":"small","size":3},{"slug":"big","size":40}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "small" ]
    [ "$(rec .owner.source)" = "team-index" ]
}

@test "an org-wide team is dropped by size" {
    org_fixtures
    team_fixtures '[{"slug":"squad","size":3},{"slug":"everyone","size":900}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "squad" ]
    [ "$(rec '.owner.candidates | index("everyone")')" = "null" ]
}

@test "a bot team is dropped by name even though it is small" {
    org_fixtures
    team_fixtures '[{"slug":"squad","size":9},{"slug":"woo-eng-bot","size":2}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "squad" ]
}

@test "a team with only pull access is not an owner" {
    org_fixtures
    team_fixtures '[{"slug":"squad","size":3}]' '{"squad":"READ"}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "null" ]
    [ "$(rec .owner.source)" = "unmapped" ]
}

@test "a widely shared repo is reported as shared rather than assigned" {
    # Smallest-wins is actively wrong here: it picks whichever team happens to
    # own fewest repos overall, which is the least likely owner.
    org_fixtures
    team_fixtures '[{"slug":"tiny","size":1},{"slug":"b","size":5},{"slug":"c","size":6},{"slug":"d","size":7}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100
    [ "$status" -eq 0 ]
    [ "$(rec .owner.source)" = "ambiguous" ]
    [ "$(rec .owner.team)" = "null" ]
    [ "$(rec '.owner.candidates | length')" -eq 4 ]
}

@test "--max-owner-candidates raises the threshold" {
    org_fixtures
    team_fixtures '[{"slug":"tiny","size":1},{"slug":"b","size":5},{"slug":"c","size":6},{"slug":"d","size":7}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100 --max-owner-candidates 4
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "tiny" ]
}

@test "an override wins over the heuristic" {
    org_fixtures
    team_fixtures '[{"slug":"small","size":3}]' '{}'
    printf '# comment\n\nacme/widgets\tchosen-team\tbecause I said so\n' >"$BATS_TEST_TMPDIR/ov.tsv"
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl --max-team-size 100 \
        --team-overrides "$BATS_TEST_TMPDIR/ov.tsv"
    [ "$status" -eq 0 ]
    [ "$(rec .owner.team)" = "chosen-team" ]
    [ "$(rec .owner.source)" = "override" ]
}

@test "--explain-owners reports why each team was kept or dropped" {
    org_fixtures
    team_fixtures '[{"slug":"squad","size":3},{"slug":"everyone","size":900}]' '{}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format summary --max-team-size 100 --explain-owners
    [ "$status" -eq 0 ]
    [[ $output == *"squad"* ]]
    [[ $output == *"everyone"* ]]
}

# --- sweep reconciliation -----------------------------------------------------

@test "a repo the sweep silently dropped is still reported, as unknown" {
    # A partial GraphQL error nulls a node and `select(. != null)` drops it
    # without trace. Observed live: google-listings-and-ads was present in one
    # run and gone from the next, both reporting a plausible total. A repo that
    # vanishes from a rollout is the worst thing this tool can do.
    viewer_fixture
    secrets_fixture
    fixture graphql_OrgProbe <<<'{"data":{"organization":{"login":"acme"}}}'
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            organization: {repositories: {
                              pageInfo: {hasNextPage: false, endCursor: null},
                              totalCount: 2, nodes: [.]}}}}'         | fixture graphql_RepoPage
    fixture graphql_RepoNames <<'EOF'
{"data":{"rateLimit":{"cost":1,"remaining":4999},"organization":{"repositories":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"nameWithOwner":"acme/widgets"},{"nameWithOwner":"acme/vanished"}]}}}}
EOF
    fixture graphql_DependabotPRs <<<'{"data":{"rateLimit":{"cost":1,"remaining":4999},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 2 ]
    run jq -r 'select(.repo == "acme/vanished") | "\(.verdict) \(.sweep_incomplete)"' "$OUT/repos.jsonl"
    [ "$output" = "unknown true" ]
}

@test "a repo the sweep dropped is not accused of failing checks nobody read" {
    # The placeholder is all nulls and a null boolean is falsy, so every
    # GraphQL-derived check would otherwise read as a confident failure.
    viewer_fixture
    secrets_fixture
    fixture graphql_OrgProbe <<<'{"data":{"organization":{"login":"acme"}}}'
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            organization: {repositories: {
                              pageInfo: {hasNextPage: false, endCursor: null},
                              totalCount: 2, nodes: [.]}}}}'         | fixture graphql_RepoPage
    fixture graphql_RepoNames <<'EOF'
{"data":{"rateLimit":{"cost":1,"remaining":4999},"organization":{"repositories":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"nameWithOwner":"acme/widgets"},{"nameWithOwner":"acme/vanished"}]}}}}
EOF
    fixture graphql_DependabotPRs <<<'{"data":{"rateLimit":{"cost":1,"remaining":4999},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    run jq -r 'select(.repo == "acme/vanished")
               | [.checks.auto_merge.status, .checks.vuln_alerts.status, .checks.labels.status]
               | join(",")' "$OUT/repos.jsonl"
    [ "$output" = "unknown,unknown,unknown" ]
    run jq -r 'select(.repo == "acme/vanished") | .blockers | length' "$OUT/repos.jsonl"
    [ "$output" = "0" ]
}

@test "run.json records what the sweep expected against what it got" {
    viewer_fixture
    secrets_fixture
    fixture graphql_OrgProbe <<<'{"data":{"organization":{"login":"acme"}}}'
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            organization: {repositories: {
                              pageInfo: {hasNextPage: false, endCursor: null},
                              totalCount: 2, nodes: [.]}}}}'         | fixture graphql_RepoPage
    fixture graphql_RepoNames <<'EOF'
{"data":{"rateLimit":{"cost":1,"remaining":4999},"organization":{"repositories":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"nameWithOwner":"acme/widgets"},{"nameWithOwner":"acme/vanished"}]}}}}
EOF
    fixture graphql_DependabotPRs <<<'{"data":{"rateLimit":{"cost":1,"remaining":4999},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(jq -r .org_total "$OUT/run.json")" = "2" ]
    [ "$(jq -r .swept "$OUT/run.json")" = "1" ]
    [ "$(jq -r .sweep_missing "$OUT/run.json")" = "1" ]
}

@test "a complete sweep costs no extra listing call" {
    viewer_fixture
    secrets_fixture
    fixture graphql_OrgProbe <<<'{"data":{"organization":{"login":"acme"}}}'
    base_node | jq '{data: {rateLimit: {cost: 1, remaining: 4999},
                            organization: {repositories: {
                              pageInfo: {hasNextPage: false, endCursor: null},
                              totalCount: 1, nodes: [.]}}}}'         | fixture graphql_RepoPage
    fixture graphql_DependabotPRs <<<'{"data":{"rateLimit":{"cost":1,"remaining":4999},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
    run "$SCRIPT" --org acme --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(jq -r .sweep_missing "$OUT/run.json")" = "0" ]
    # No RepoNames fixture exists, so reconciliation must not have run at all.
    [ "$(grep -c RepoNames "$GH_STUB_LOG" || true)" -eq 0 ]
}

# --- scope, output and concurrency --------------------------------------------

@test "an n/a repo is kept out of the wave bands" {
    # A repo that cannot produce a Dependabot PR is the worst pilot candidate,
    # and being dormant sorts it to the front of the queue.
    repo_set '. * {depYml: null, depYaml: null, caller: null,
                   root: {entries: [{name: "README.md", type: "blob"}]}}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"README.md"}]}
EOF
    run_audit
    [ "$(rec .wave.band)" = "null" ]
    [ "$(rec '.wave.score | type')" = "number" ]
}

@test "a security-advisory temporary fork is excluded by default" {
    # GitHub creates these per advisory and does not mark them as forks, so the
    # fork filter misses them and they land in rollout waves.
    repo_set_many '. * {nameWithOwner: "acme/widgets-ghsa-6wvr-47ff-m546"}'
    run "$SCRIPT" --repo acme/widgets-ghsa-6wvr-47ff-m546 --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 0 ]

    repo_set_many '. * {nameWithOwner: "acme/widgets-ghsa-6wvr-47ff-m546"}'
    run "$SCRIPT" --repo acme/widgets-ghsa-6wvr-47ff-m546 --out-dir "$OUT" --format jsonl --include-advisory-forks
    [ "$status" -eq 0 ]
    [ "$(rec .scope.advisory_fork)" = "true" ]
}

@test "a repo that merely contains ghsa in its name is not excluded" {
    repo_set_many '. * {nameWithOwner: "acme/ghsa-tooling"}'
    run "$SCRIPT" --repo acme/ghsa-tooling --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 1 ]
    [ "$(rec .scope.advisory_fork)" = "false" ]
}

@test "archived repos are excluded by default and included on request" {
    repo_set '. * {isArchived: true}'
    run_audit
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 0 ]

    repo_set '. * {isArchived: true}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --include-archived
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 1 ]
    [ "$(rec .scope.archived)" = "true" ]
}

@test "the jsonl artifact is one valid object per line" {
    repo_set_many '. * {nameWithOwner: "acme/one"}' '. * {nameWithOwner: "acme/two"}'
    run "$SCRIPT" --repo acme/one --repo acme/two --out-dir "$OUT" --format jsonl
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 2 ]
    run jq -e -c . "$OUT/repos.jsonl"
    [ "$status" -eq 0 ]
}

@test "a not-applicable repo is not listed as having blockers to fix" {
    # Its settings really are missing, but Dependabot has nothing to scan there,
    # so listing them implies work that does not need doing.
    repo_set '. * {depYml: null, depYaml: null, caller: null, autoMergeAllowed: false,
                   root: {entries: [{name: "README.md", type: "blob"}]}}'
    fixture GET_repos_acme_widgets_git_trees_main_recursive_1 <<'EOF'
{"truncated":false,"tree":[{"type":"blob","path":"README.md"}]}
EOF
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format table
    [ "$status" -eq 0 ]
    [[ $output == *"no dependencies to scan"* ]]
    [[ $output != *"auto_merge"* ]]
    # And the wave column reads as blank rather than the literal "wnull".
    [[ $output != *"wnull"* ]]
}

@test "--format csv emits the documented header" {
    repo_set
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format csv
    [ "$status" -eq 0 ]
    [[ $output == *"repo,verdict,team,wave_band,wave_score"* ]]
}

@test "--status filters the rendered view without changing the artifact" {
    repo_set_many '. * {nameWithOwner: "acme/one"}' \
                  '. * {nameWithOwner: "acme/two", autoMergeAllowed: false}'
    # acme/one needs its token secret listed, or it reads unknown, not ready.
    secrets_fixture QUALITYOPS_DEPENDABOT_ALERTS_TOKEN acme/one
    run "$SCRIPT" --repo acme/one --repo acme/two --out-dir "$OUT" --format table --status ready
    [ "$status" -eq 0 ]
    [[ $output == *"acme/one"* ]]
    [[ $output != *"acme/two "* ]]
    [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "--has-dependabot-config narrows the view to repos that have one" {
    repo_set_many '. * {nameWithOwner: "acme/one"}' \
                  '. * {nameWithOwner: "acme/two", depYml: null}'
    run "$SCRIPT" --repo acme/one --repo acme/two --out-dir "$OUT" --format table --has-dependabot-config
    [ "$status" -eq 0 ]
    [[ $output == *"acme/one"* ]]
    [[ $output != *"acme/two "* ]]
}

@test "every call carries the cache flag, and --no-cache removes it" {
    repo_set
    run_audit
    [ "$(log_count '--cache=1h')" -ge 1 ]

    : >"$GH_STUB_LOG"
    repo_set
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --no-cache
    [ "$status" -eq 0 ]
    [ "$(log_count '--cache')" -eq 0 ]
}

@test "--jobs does not change the output bytes" {
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":false}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --jobs 1
    [ "$status" -eq 0 ]
    one=$(jq -S 'del(.audited_at)' "$OUT/repos.jsonl")

    rm -f "$GH_STUB_DIR"/.seq_* 2>/dev/null || true
    repo_set '. * {defaultBranchRef: {rules: {totalCount: 0, nodes: []}, branchProtectionRule: null}}'
    fixture GET_repos_acme_widgets_branches_main <<<'{"protected":false}'
    run "$SCRIPT" --repo acme/widgets --out-dir "$OUT" --format jsonl --jobs 4
    [ "$status" -eq 0 ]
    four=$(jq -S 'del(.audited_at)' "$OUT/repos.jsonl")

    [ "$one" = "$four" ]
}

@test "an anonymous GraphQL document is a stub error, so every operation stays named" {
    viewer_fixture
    run bash -c 'gh api graphql -f query="query { viewer { login } }"'
    [ "$status" -eq 64 ]
    [[ $output == *"anonymous graphql document"* ]]
}

# --- enterprise host ----------------------------------------------------------

@test "GH_HOST scopes the auth check to the target host" {
    repo_set
    GH_HOST=ghe.example.com run_audit
    [ "$(log_count 'ghe.example.com')" -ge 1 ]
}

# --- parse failures -----------------------------------------------------------

@test "the run fails loudly rather than reporting a confident verdict when the sweep cannot be read" {
    viewer_fixture
    fixture graphql_RepoSet <<<'{"data":null,"errors":[{"message":"boom"}]}'
    run_audit
    [ "$status" -ne 0 ] || [ "$(wc -l <"$OUT/repos.jsonl" | tr -d ' ')" -eq 0 ]
}
