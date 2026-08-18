#!/usr/bin/env bats
# Tests for scripts/bootstrap.sh, run against the gh stub in tests/stubs/.
# The stub logs every gh invocation and serves fixture files, so these tests
# exercise the script's real control flow without touching the network.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/bootstrap.sh"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

fixture() {
    cat >"$GH_STUB_DIR/$1"
}

# Repo response fixture; $1 is the allow_auto_merge value.
repo_json() {
    fixture GET_repos_acme_widgets <<EOF
{"full_name":"acme/widgets","default_branch":"main","allow_auto_merge":$1,"permissions":{"admin":true}}
EOF
}

# A repo where every step needs a change: auto-merge off, no rules, no
# rulesets; absent label/protection/vulnerability-alert fixtures read as 404.
fresh_repo_fixtures() {
    repo_json false
    fixture GET_repos_acme_widgets_rules_branches_main <<<'[]'
    fixture GET_repos_acme_widgets_rulesets_includes_parents_false <<<'[]'
}

# A fully configured repo: every step should report ✓ and mutate nothing.
configured_repo_fixtures() {
    repo_json true
    fixture GET_repos_acme_widgets_rules_branches_main <<'EOF'
[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"ci"}]}}]
EOF
    fixture GET_repos_acme_widgets_labels_security_fast_track <<<'{"color":"0075ca","description":"Bypass all gates and enable auto-merge immediately"}'
    fixture GET_repos_acme_widgets_labels_auto_merge_pending <<<'{"color":"e4e669","description":"Passed all gates; awaiting age gate"}'
    fixture GET_repos_acme_widgets_labels_sirt_review_required <<<'{"color":"d93f0b","description":"Requires human security review"}'
    fixture GET_repos_acme_widgets_vulnerability_alerts </dev/null
}

mutation_count() {
    grep -cE -- '-X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG" || true
}

# Install a jq wrapper that fails whenever it is invoked with the given
# filter and delegates every other invocation to the real jq, so a single
# parse step can be forced to fail without disturbing the rest of the script.
break_jq_filter() {
    local real_jq
    real_jq=$(command -v jq)
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/jq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    [[ \$arg == "$1" ]] && exit 1
done
exec "$real_jq" "\$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/jq"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- argument validation --------------------------------------------------

@test "no arguments exits 2 with usage" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ $output == *"missing required argument"* ]]
    [[ $output == *"Usage:"* ]]
}

@test "repo without a slash is rejected" {
    run "$SCRIPT" widgets
    [ "$status" -eq 2 ]
    [[ $output == *"invalid repository"* ]]
}

@test "literal gh api placeholders are rejected" {
    run "$SCRIPT" '{owner}/{repo}'
    [ "$status" -eq 2 ]
    [[ $output == *"invalid repository"* ]]
    [ ! -s "$GH_STUB_LOG" ]
}

@test "unknown option exits 2" {
    run "$SCRIPT" acme/widgets --frobnicate
    [ "$status" -eq 2 ]
    [[ $output == *"unknown option: --frobnicate"* ]]
}

@test "--required-check without a value exits 2" {
    run "$SCRIPT" acme/widgets --required-check
    [ "$status" -eq 2 ]
    [[ $output == *"--required-check needs a value"* ]]
}

@test "--required-check does not swallow a following option" {
    run "$SCRIPT" acme/widgets --required-check --dry-run
    [ "$status" -eq 2 ]
    [[ $output == *"--required-check needs a value"* ]]
    # Parsing fails before any API call — nothing may run with DRY_RUN unset.
    [ ! -s "$GH_STUB_LOG" ]
}

@test "--required-check with an empty value exits 2" {
    run "$SCRIPT" acme/widgets --required-check ""
    [ "$status" -eq 2 ]
    [[ $output == *"--required-check needs a value"* ]]
}

@test "--required-check=<name> form is accepted" {
    configured_repo_fixtures
    run "$SCRIPT" acme/widgets --required-check=ci
    [ "$status" -eq 0 ]
    [[ $output == *"already present on 'main' (ci)"* ]]
}

# --- dry-run --------------------------------------------------------------

@test "--dry-run reports every change but issues no non-GET call" {
    fresh_repo_fixtures
    run "$SCRIPT" acme/widgets --required-check ci --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"allow auto-merge: enable (dry-run)"* ]]
    [[ $output == *"ruleset: create"* ]]
    [[ $output == *"label 'security-fast-track': create (dry-run)"* ]]
    [[ $output == *"dependabot vulnerability alerts: enable (dry-run)"* ]]
    [[ $output == *"would change"* ]]
    [ "$(mutation_count)" -eq 0 ]
}

@test "--dry-run falls back to the raw payload when the formatter fails" {
    fresh_repo_fixtures
    # mutate pretty-prints payloads with 'jq .'; its failure must not swallow
    # the payload — the raw JSON is the dry-run's entire point.
    break_jq_filter '.'
    run "$SCRIPT" acme/widgets --dry-run
    [ "$status" -eq 0 ]
    # grep rather than [[ ]]: under macOS bash 3.2 a failed [[ ]] mid-test
    # cannot fail a bats test (errexit/ERR fire only for simple commands).
    grep -qF -- '{"allow_auto_merge":true}' <<<"$output"
    [ "$(mutation_count)" -eq 0 ]
}

# --- real runs ------------------------------------------------------------

@test "fully configured repo reports ok everywhere and mutates nothing" {
    configured_repo_fixtures
    run "$SCRIPT" acme/widgets --required-check ci
    [ "$status" -eq 0 ]
    [[ $output == *"allow auto-merge: already enabled"* ]]
    [[ $output == *"already present on 'main' (ci)"* ]]
    [[ $output == *"label 'security-fast-track': already correct"* ]]
    [[ $output == *"dependabot vulnerability alerts: already enabled"* ]]
    [[ $output == *"0 failed"* ]]
    [ "$(mutation_count)" -eq 0 ]
}

@test "fresh repo executes each mutation" {
    fresh_repo_fixtures
    fixture PATCH_repos_acme_widgets </dev/null
    fixture POST_repos_acme_widgets_rulesets </dev/null
    fixture POST_repos_acme_widgets_labels </dev/null
    fixture PUT_repos_acme_widgets_vulnerability_alerts </dev/null
    run "$SCRIPT" acme/widgets --required-check ci
    [ "$status" -eq 0 ]
    [[ $output == *"0 failed"* ]]
    grep -q -- '-X PATCH repos/acme/widgets ' "$GH_STUB_LOG"
    grep -q -- '-X POST repos/acme/widgets/rulesets' "$GH_STUB_LOG"
    grep -q -- '-X PUT repos/acme/widgets/vulnerability-alerts' "$GH_STUB_LOG"
    [ "$(grep -c -- '-X POST repos/acme/widgets/labels' "$GH_STUB_LOG")" -eq 3 ]
}

@test "failed step exits 1 and is named, later steps still run" {
    fresh_repo_fixtures
    fixture PATCH_repos_acme_widgets </dev/null
    fixture POST_repos_acme_widgets_labels.err <<<'HTTP 500 Internal Server Error'
    fixture PUT_repos_acme_widgets_vulnerability_alerts </dev/null
    run "$SCRIPT" acme/widgets
    [ "$status" -eq 1 ]
    [[ $output == *"Failed steps: labels"* ]]
    [[ $output == *"HTTP 500"* ]]
    # The failure must not stop the remaining steps.
    grep -q -- '-X PUT repos/acme/widgets/vulnerability-alerts' "$GH_STUB_LOG"
}

@test "auto-merge parse failure fails the step without patching the repo" {
    fresh_repo_fixtures
    fixture POST_repos_acme_widgets_labels </dev/null
    fixture PUT_repos_acme_widgets_vulnerability_alerts </dev/null
    # Force only step_auto_merge's jq invocation to fail: a parse error must
    # not be mistaken for "auto-merge disabled" and trigger a repo PATCH.
    break_jq_filter '.allow_auto_merge'
    run "$SCRIPT" acme/widgets
    [ "$status" -eq 1 ]
    # grep rather than [[ ]]: see the formatter-fallback test above.
    grep -qF -- 'allow auto-merge: cannot parse repository settings' <<<"$output"
    grep -qF -- 'Failed steps: auto-merge' <<<"$output"
    [ "$(grep -c -- '-X PATCH ' "$GH_STUB_LOG" || true)" -eq 0 ]
    # The failure must not stop the remaining steps.
    grep -q -- '-X PUT repos/acme/widgets/vulnerability-alerts' "$GH_STUB_LOG"
}

# --- preflight capability probes -------------------------------------------

# GitHub App installation tokens have no repo role: GET /repos renders the
# permissions map all-false even when the app holds Administration: write
# (observed live against api.github.com). Preflight no longer tries to prove
# Administration access from this — it only gates on allow_auto_merge being
# visible at all, and leaves proving write access to each step's own call.
app_token_repo_json() {
    fixture GET_repos_acme_widgets <<EOF
{"full_name":"acme/widgets","default_branch":"main","allow_auto_merge":$1,"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":false}}
EOF
}

@test "app installation token with permissions.admin false still bootstraps successfully" {
    configured_repo_fixtures
    app_token_repo_json true
    run "$SCRIPT" acme/widgets --required-check ci
    [ "$status" -eq 0 ]
    [[ $output == *"0 failed"* ]]
    [ "$(mutation_count)" -eq 0 ]
}

@test "app installation token performs admin-scoped mutations despite permissions.admin false" {
    fresh_repo_fixtures
    app_token_repo_json false
    fixture PATCH_repos_acme_widgets </dev/null
    fixture POST_repos_acme_widgets_rulesets </dev/null
    fixture POST_repos_acme_widgets_labels </dev/null
    fixture PUT_repos_acme_widgets_vulnerability_alerts </dev/null
    run "$SCRIPT" acme/widgets --required-check ci
    [ "$status" -eq 0 ]
    [[ $output == *"0 failed"* ]]
    grep -q -- '-X PATCH repos/acme/widgets ' "$GH_STUB_LOG"
    grep -q -- '-X POST repos/acme/widgets/rulesets' "$GH_STUB_LOG"
}

# The scenario the removed probe got wrong: a token that can see merge
# settings (has "allow_auto_merge") but isn't actually admin. A repo the
# token doesn't administer 404s on vulnerability-alerts exactly like a
# genuinely disabled one does (confirmed live: gh api repos/cli/cli reports
# permissions.admin false, and -i .../vulnerability-alerts returns a plain
# 404, indistinguishable from "disabled"), so the removed probe would have
# waved this token through. Refusal now happens at the real mutating call.
@test "a token that can view merge settings but lacks Administration write fails at the first admin-scoped step, not preflight" {
    fresh_repo_fixtures
    fixture GET_repos_acme_widgets <<<'{"full_name":"acme/widgets","default_branch":"main","allow_auto_merge":false,"permissions":{"admin":false,"push":true,"maintain":false,"triage":false,"pull":true}}'
    fixture PATCH_repos_acme_widgets.err <<<'HTTP 403: Resource not accessible by integration'
    fixture POST_repos_acme_widgets_labels </dev/null
    fixture PUT_repos_acme_widgets_vulnerability_alerts </dev/null
    run "$SCRIPT" acme/widgets
    [ "$status" -eq 1 ]
    [[ $output == *"Failed steps: auto-merge"* ]]
    [[ $output == *"HTTP 403"* ]]
    # Preflight didn't refuse outright — later steps still ran.
    [ "$(grep -c -- '-X POST repos/acme/widgets/labels' "$GH_STUB_LOG")" -eq 3 ]
    grep -q -- '-X PUT repos/acme/widgets/vulnerability-alerts' "$GH_STUB_LOG"
}

@test "token that cannot view merge settings is refused" {
    fixture GET_repos_acme_widgets <<<'{"full_name":"acme/widgets","default_branch":"main","permissions":{"admin":true}}'
    run "$SCRIPT" acme/widgets
    [ "$status" -eq 2 ]
    [[ $output == *"cannot view merge settings"* ]]
    [ "$(mutation_count)" -eq 0 ]
}

@test "renamed repo is refused before any mutation" {
    fixture GET_repos_acme_old_name <<<'{"full_name":"acme/widgets","default_branch":"main","allow_auto_merge":false,"permissions":{"admin":true}}'
    run "$SCRIPT" acme/old-name
    [ "$status" -eq 2 ]
    [[ $output == *"resolved to 'acme/widgets'"* ]]
    [ "$(mutation_count)" -eq 0 ]
}
