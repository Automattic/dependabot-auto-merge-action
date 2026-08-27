#!/usr/bin/env bats
# Tests for the "Gate 1 fallback — Dependabot alerts API" step of the
# reusable workflow, run against the gh stub in tests/stubs/. The step's
# script is pulled out of the YAML and run as-is, so these tests exercise
# the shipped code rather than a copy that can drift.
#
# The step serves two paths, distinguished by GATE1_PASS:
#   - indirect deps (GATE1_PASS != true): the API is the only advisory
#     source, so an API error fails the job;
#   - direct deps with an unusable CVSS (GATE1_PASS = true): the call is a
#     best-effort enrichment, so an error degrades to "no better score
#     available" and the job stays green.
#
# The paths also match differently: a direct dep knows the advisory it
# fixes, so the lookup is pinned to that GHSA ID; an indirect dep knows no
# advisory, so any open alert on the package counts.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export STEP="$BATS_FILE_TMPDIR/gate1-fallback.sh"
    extract_run gate1-fallback >"$STEP"
    # Guard the extractor the same way cvss.bats does: an empty or
    # half-dedented script would pass every assertion below.
    [ -s "$STEP" ]
    bash -n "$STEP"
    grep -q 'GATE1_PASS' "$STEP"
    grep -q 'dependabot/alerts' "$STEP"
    grep -q 'GHSA_ID' "$STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    : >"$GITHUB_OUTPUT"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

# The step's API path, mapped to the stub's fixture key.
ALERTS_KEY="GET_repos_acme_widgets_dependabot_alerts_state_open_per_page_100"

# Serve the given alert objects as the alerts response. `gh api --paginate
# --slurp` emits an array of pages, each page an array of alerts, and the
# step's jq iterates `.[][]` accordingly — so the fixture must be [[...]],
# never a flat alert array. A flat array would iterate object values, fail
# in jq, and land every test in the no-match branch, passing for the wrong
# reason.
alerts_fixture() {
    {
        printf '[['
        local sep=''
        for alert in "$@"; do
            printf '%s%s' "$sep" "$alert"
            sep=','
        done
        printf ']]'
    } >"$GH_STUB_DIR/$ALERTS_KEY"
}

# One open alert: $1 = package name, $2 = GHSA ID, $3 = cvss score (a JSON
# literal, so `null` works too).
alert() {
    printf '{"security_advisory":{"ghsa_id":"%s","cvss":{"score":%s}},"dependency":{"package":{"name":"%s"}}}' \
        "$2" "$3" "$1"
}

# A real `gh` 403 spans two lines. The annotations have to fold it onto one:
# the runner reads any following line starting with `::` as a workflow
# command, and the rest of the message would be lost from the annotation.
api_403() {
    cat >"$GH_STUB_DIR/$ALERTS_KEY.err" <<'EOF'
gh: HTTP 403: Resource not accessible by integration (https://api.github.com/repos/acme/widgets/dependabot/alerts)
Learn more at https://docs.github.com/rest/dependabot/alerts
EOF
}

# Run the step with $1 as GATE1_PASS, $2 as the dependency-names list and
# $3 as the advisory the PR fixes — empty for indirect deps, which is what
# fetch-metadata reports for them. The flags match what the step's
# `shell: bash` expands to in Actions.
fallback() {
    GATE1_PASS="$1" DEPENDENCY_NAMES="$2" GHSA_ID="${3:-}" \
        bash --noprofile --norc -e -o pipefail "$STEP"
}

# --- the indirect-dep path keeps its contract ------------------------------

@test "indirect: an API error fails the job" {
    api_403
    run fallback false lodash
    [ "$status" -eq 1 ]
    grep -qF '::error::' <<<"$output"
    [ ! -s "$GITHUB_OUTPUT" ]
}

@test "a multi-line API error stays on one annotation line" {
    for gate1_pass in true false; do
        : >"$GITHUB_OUTPUT"
        api_403
        run fallback "$gate1_pass" lodash
        [ "$(grep -c . <<<"$output")" -eq 1 ]
        grep -qF 'Learn more at' <<<"$output"
    done
}

@test "indirect: a matching scored alert passes with its score" {
    alerts_fixture "$(alert lodash GHSA-aaaa-bbbb-cccc 9.8)"
    fallback false lodash
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.8" ]
}

@test "indirect: no matching alert is a routine version update" {
    alerts_fixture
    run fallback false lodash
    [ "$status" -eq 0 ]
    [ "$(out pass)" = "false" ]
    [ "$(out cvss)" = "" ]
    grep -qF 'routine version update' <<<"$output"
}

# --- the direct-dep enrichment path degrades, never fails ------------------

@test "direct: an API error degrades to no-better-score and stays green" {
    api_403
    run fallback true lodash
    [ "$status" -eq 0 ]
    grep -qF '::warning::' <<<"$output"
    grep -qF 'HTTP 403' <<<"$output"
    [ "$(out pass)" = "false" ]
    [ "$(out cvss)" = "" ]
}

@test "direct: a matching scored alert recovers a real score" {
    alerts_fixture "$(alert lodash GHSA-aaaa-bbbb-cccc 9.8)"
    fallback true lodash GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.8" ]
}

@test "direct: no matching alert reports no better score" {
    alerts_fixture "$(alert unrelated-pkg GHSA-dddd-eeee-ffff 9.9)"
    run fallback true lodash GHSA-aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [ "$(out pass)" = "false" ]
    [ "$(out cvss)" = "" ]
    grep -qF 'no better score available' <<<"$output"
}

# --- the score has to come from the advisory the PR fixes ------------------

@test "direct: another advisory on the same package is not borrowed" {
    # The PR fixes the unscored advisory; the package also has an open alert
    # for an unrelated 9.1. Taking that 9.1 would pass Gate 2 on evidence
    # about a vulnerability this PR does not fix, so the step must report no
    # better score and leave the PR for human review.
    alerts_fixture \
        "$(alert lodash GHSA-aaaa-bbbb-cccc 0)" \
        "$(alert lodash GHSA-gggg-hhhh-iiii 9.1)"
    run fallback true lodash GHSA-jjjj-kkkk-llll
    [ "$status" -eq 0 ]
    [ "$(out pass)" = "false" ]
    [ "$(out cvss)" = "" ]
    grep -qF 'no better score available' <<<"$output"
}

@test "direct: the PR's own advisory wins over a higher-scored neighbour" {
    alerts_fixture \
        "$(alert lodash GHSA-gggg-hhhh-iiii 9.1)" \
        "$(alert lodash GHSA-aaaa-bbbb-cccc 4.3)"
    fallback true lodash GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "4.3" ]
}

# --- score selection and matching ------------------------------------------

@test "an alert scored zero or null still passes with that zero" {
    # The resolver classifies the recovered 0 as unusable and fails closed —
    # a zero recovered from the API must never fail open through Gate 2.
    for score in 0 null; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert lodash GHSA-aaaa-bbbb-cccc "$score")"
        fallback true lodash GHSA-aaaa-bbbb-cccc
        [ "$(out pass)" = "true" ]
        [ "$(out cvss)" = "0" ]
    done
}

@test "direct: the scored record of the advisory wins across manifests" {
    # The same advisory can be open against several manifests, one of them
    # unscored. This ordering is what makes recovery useful.
    alerts_fixture \
        "$(alert lodash GHSA-aaaa-bbbb-cccc 0)" \
        "$(alert lodash GHSA-aaaa-bbbb-cccc 9.1)"
    fallback true lodash GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.1" ]
}

@test "indirect: the highest-scored alert wins over an unscored one" {
    # No advisory is known for an indirect dep, so the filter stays open and
    # the best score on the package is the only evidence available.
    alerts_fixture \
        "$(alert lodash GHSA-aaaa-bbbb-cccc 0)" \
        "$(alert lodash GHSA-gggg-hhhh-iiii 9.1)"
    fallback false lodash
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.1" ]
}

@test "a malformed API response degrades to no-match on both paths" {
    for gate1_pass in true false; do
        : >"$GITHUB_OUTPUT"
        echo 'not json' >"$GH_STUB_DIR/$ALERTS_KEY"
        run fallback "$gate1_pass" lodash
        [ "$status" -eq 0 ]
        grep -qF '::warning::' <<<"$output"
        [ "$(out pass)" = "false" ]
    done
}

@test "matching splits the dependency-names list on comma-space" {
    alerts_fixture "$(alert bar GHSA-aaaa-bbbb-cccc 8.1)"
    fallback false 'foo, bar'
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "8.1" ]
}
