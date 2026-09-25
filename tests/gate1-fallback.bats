#!/usr/bin/env bats
# Tests for the "Gate 1 fallback — Dependabot alerts API" step of the
# reusable workflow, run against the gh stub in tests/stubs/. The step's
# script is pulled out of the YAML and run as-is, so these tests exercise
# the shipped code rather than a copy that can drift.
#
# The step serves two paths, distinguished by GATE1_PASS:
#   - PR metadata named no advisory (GATE1_PASS != true): the API is the
#     only advisory source, so an API error fails the job;
#   - PR metadata named an advisory with an unusable CVSS (GATE1_PASS =
#     true): the call is a best-effort enrichment, so an error degrades to
#     "no better score available" and the job stays green.
#
# The paths also match differently. A known advisory pins the lookup to
# that GHSA ID. With no advisory known, any open alert that applies to an
# updated dependency counts. On both paths an alert applies only when it
# names the same package in the same ecosystem, sits on a manifest in the
# updated directory, and is fixed by the version the PR moves to.

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
    # Most tests use a single-dependency PR, lodash 4.17.20 -> 4.17.21 in
    # the repository root.
    LODASH="$(dependencies "$(dependency)")"
}

# The step's API path, mapped to the stub's fixture key.
ALERTS_KEY="GET_repos_acme_widgets_dependabot_alerts_state_open_per_page_100"

# Serve the given alert objects as the alerts response. `gh api --paginate
# --slurp` emits an array of pages, each page an array of alerts, and the
# step's jq iterates `.[][]` accordingly, so the fixture must be [[...]],
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

# One open alert in the alerts API shape. The defaults apply to $LODASH, so
# each test overrides only the field it is about, e.g.
# `alert ecosystem=pip` or `alert score:=null`. `patched:=null` is an
# advisory with no fixed release.
alert() {
    jq_named '
        ({name: "lodash", ghsa: "GHSA-aaaa-bbbb-cccc", score: 9.8,
          ecosystem: "npm", manifest: "package-lock.json", patched: "4.17.21"}
         + $ARGS.named) as $a
        | {security_advisory: {ghsa_id: $a.ghsa, cvss: {score: $a.score}},
           security_vulnerability: {
               package: {ecosystem: $a.ecosystem, name: $a.name},
               first_patched_version:
                   (if $a.patched == null then null else {identifier: $a.patched} end)},
           dependency: {
               package: {ecosystem: $a.ecosystem, name: $a.name},
               manifest_path: $a.manifest}}' "$@"
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

# Run the step with $1 as GATE1_PASS, $2 as updated-dependencies-json and
# $3 as the advisory PR metadata named, empty when it named none. The flags
# match what the step's `shell: bash` expands to in Actions.
fallback() {
    GATE1_PASS="$1" UPDATED_DEPENDENCIES="$2" GHSA_ID="${3:-}" \
        bash --noprofile --norc -e -o pipefail "$STEP"
}

# Assert the step found no applicable alert.
no_match() {
    [ "$status" -eq 0 ]
    [ "$(out pass)" = "false" ]
    [ "$(out cvss)" = "" ]
}

# --- no advisory in PR metadata: the API is the only source -----------------

@test "no advisory: an API error fails the job" {
    api_403
    run fallback false "$LODASH"
    [ "$status" -eq 1 ]
    grep -qF '::error::' <<<"$output"
    [ ! -s "$GITHUB_OUTPUT" ]
}

@test "a multi-line API error stays on one annotation line" {
    for gate1_pass in true false; do
        : >"$GITHUB_OUTPUT"
        api_403
        run fallback "$gate1_pass" "$LODASH"
        [ "$(grep -c . <<<"$output")" -eq 1 ]
        grep -qF 'Learn more at' <<<"$output"
    done
}

@test "no advisory: a matching scored alert passes with its score" {
    alerts_fixture "$(alert score:=9.8)"
    fallback false "$LODASH"
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.8" ]
}

@test "no advisory: no matching alert is a routine version update" {
    alerts_fixture
    run fallback false "$LODASH"
    no_match
    grep -qF 'routine version update' <<<"$output"
}

# --- advisory in PR metadata: enrichment degrades, never fails --------------

@test "advisory known: an API error degrades to no-better-score and stays green" {
    api_403
    run fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
    no_match
    grep -qF '::warning::' <<<"$output"
    grep -qF 'HTTP 403' <<<"$output"
}

@test "advisory known: a matching scored alert recovers a real score" {
    alerts_fixture "$(alert score:=9.8)"
    fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.8" ]
}

@test "advisory known: no matching alert reports no better score" {
    alerts_fixture "$(alert name=unrelated-pkg ghsa=GHSA-dddd-eeee-ffff score:=9.9)"
    run fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
    no_match
    grep -qF 'no better score available' <<<"$output"
}

# --- the score has to come from the advisory the PR fixes -------------------

@test "advisory known: another advisory on the same package is not borrowed" {
    # The PR fixes the unscored advisory. The package also has an open alert
    # for an unrelated 9.1. Taking that 9.1 would pass Gate 2 on evidence
    # about a vulnerability this PR does not fix, so the step must report no
    # better score and leave the PR for human review.
    alerts_fixture \
        "$(alert ghsa=GHSA-aaaa-bbbb-cccc score:=0)" \
        "$(alert ghsa=GHSA-gggg-hhhh-iiii score:=9.1)"
    run fallback true "$LODASH" GHSA-jjjj-kkkk-llll
    no_match
    grep -qF 'no better score available' <<<"$output"
}

@test "advisory known: the PR's own advisory wins over a higher-scored neighbour" {
    alerts_fixture \
        "$(alert ghsa=GHSA-gggg-hhhh-iiii score:=9.1)" \
        "$(alert ghsa=GHSA-aaaa-bbbb-cccc score:=4.3)"
    fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "4.3" ]
}

# --- an alert has to apply to the updated dependency ------------------------

@test "an alert for a same-named package in another ecosystem does not qualify" {
    # A PyPI lodash, say. Same name, different package.
    for gate1_pass in true false; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert ecosystem=pip)"
        run fallback "$gate1_pass" "$LODASH" GHSA-aaaa-bbbb-cccc
        no_match
    done
}

@test "an alert on a manifest outside the updated directory does not qualify" {
    alerts_fixture "$(alert manifest=packages/api/package-lock.json)"
    run fallback false "$LODASH"
    no_match

    # The reverse too. A root alert is not fixed by an update to a nested
    # lockfile. A prefix match would let `/` claim every manifest in the repo.
    : >"$GITHUB_OUTPUT"
    alerts_fixture "$(alert manifest=package-lock.json)"
    run fallback false "$(dependencies "$(dependency directory=/packages/api)")"
    no_match
}

@test "an alert on a manifest in the updated directory qualifies" {
    for dir in /packages/api /packages/api/ packages/api; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert manifest=packages/api/package-lock.json)"
        fallback false "$(dependencies "$(dependency directory="$dir")")"
        [ "$(out pass)" = "true" ]
    done
}

@test "an alert the new version does not fix does not qualify" {
    alerts_fixture "$(alert patched=4.17.21)"
    run fallback false "$(dependencies "$(dependency newVersion=4.17.20)")"
    no_match
}

@test "versions compare numerically, component by component" {
    # 1.10.0 sorts before 1.9.2 as a string. 1.2 and 1.2.0 are the same
    # release, so a missing component counts as zero.
    for pair in 1.10.0:1.9.2 1.2:1.2.0 1.2.0:1.2 v1.2.3:1.2.3 2.0.0:v1.9 4.17.21:4.17.21; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert patched="${pair#*:}")"
        fallback false "$(dependencies "$(dependency newVersion="${pair%%:*}")")"
        [ "$(out pass)" = "true" ]
    done
}

@test "a version the step cannot compare fails closed" {
    # Pre-release and qualifier ordering differs by ecosystem (4.18.0-beta.1
    # sorts before 4.18.0 in semver, 1.0.post1 after 1.0 in PEP 440), so
    # anything beyond dotted numbers is undecidable here. So is an advisory
    # with no patched release, or a dependency with no recorded version.
    for pair in 4.18.0-beta.1:4.17.21 32.1.0-jre:32.0.0 2.0.0:1.0.post1 5.0.0:null :1.0.0 1.x:1.0; do
        : >"$GITHUB_OUTPUT"
        patched="patched=${pair#*:}"
        [ "${pair#*:}" = null ] && patched='patched:=null'
        alerts_fixture "$(alert "$patched")"
        run fallback false "$(dependencies "$(dependency newVersion="${pair%%:*}")")"
        no_match
    done
}

@test "Dependabot package managers map to alerts API ecosystems" {
    # Left of the colon, what fetch-metadata reports as packageEcosystem (the
    # Dependabot branch segment). Right, the alerts API's
    # dependency.package.ecosystem.
    for pair in npm_and_yarn:npm bun:npm bundler:rubygems pip:pip uv:pip \
        composer:composer go_modules:go maven:maven gradle:maven sbt:maven \
        nuget:nuget cargo:rust hex:erlang pub:pub swift:swift; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert ecosystem="${pair#*:}")"
        fallback false "$(dependencies "$(dependency packageEcosystem="${pair%%:*}")")"
        [ "$(out pass)" = "true" ]
    done
}

@test "a package manager with no alerts ecosystem never matches" {
    for pair in docker:other terraform:other npm_and_yarn:null; do
        : >"$GITHUB_OUTPUT"
        eco="ecosystem=${pair#*:}"
        [ "${pair#*:}" = null ] && eco='ecosystem:=null'
        alerts_fixture "$(alert "$eco")"
        run fallback false "$(dependencies "$(dependency packageEcosystem="${pair%%:*}")")"
        no_match
    done
}

@test "a GitHub Actions alert on a workflow file under the directory qualifies" {
    # Dependabot's `/` for github-actions means `.github/workflows`, and the
    # alert's manifest is the workflow file itself.
    alerts_fixture "$(alert name=actions/checkout ecosystem=actions \
        manifest=.github/workflows/ci.yml patched=4.0.1)"
    fallback false "$(dependencies "$(dependency dependencyName=actions/checkout \
        packageEcosystem=github_actions newVersion=4.1.0)")"
    [ "$(out pass)" = "true" ]
}

@test "an alert with no manifest path does not qualify" {
    for manifest in 'manifest=' 'manifest:=null'; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert "$manifest")"
        run fallback false "$LODASH"
        no_match
    done
}

# --- grouped updates --------------------------------------------------------

@test "grouped: each dependency is checked against its own version" {
    # minimist stays vulnerable at 1.2.5, so its 9.9 is not evidence for this
    # PR. lodash's 7.5 is.
    alerts_fixture \
        "$(alert score:=7.5)" \
        "$(alert name=minimist ghsa=GHSA-mmmm-nnnn-oooo score:=9.9 patched=1.2.6)"
    fallback false "$(dependencies \
        "$(dependency)" \
        "$(dependency dependencyName=minimist prevVersion=1.2.0 newVersion=1.2.5)")"
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "7.5" ]
}

@test "grouped: an alert on a later dependency qualifies" {
    # fetch-metadata's top-level outputs describe the first dependency only.
    alerts_fixture "$(alert name=minimist ghsa=GHSA-mmmm-nnnn-oooo score:=8.1 patched=1.2.6)"
    fallback false "$(dependencies \
        "$(dependency dependencyName=left-pad newVersion=1.3.0)" \
        "$(dependency dependencyName=minimist newVersion=1.2.6)")"
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "8.1" ]
}

@test "grouped: a dependency's version is not lent to another package" {
    # lodash moves to 4.17.21, but the alert is on minimist, which moves to
    # 1.2.5 and stays vulnerable.
    alerts_fixture "$(alert name=minimist patched=1.2.6)"
    run fallback false "$(dependencies \
        "$(dependency)" \
        "$(dependency dependencyName=minimist newVersion=1.2.5)")"
    no_match
}

# --- score selection and malformed input ------------------------------------

@test "an alert scored zero or null still passes with that zero" {
    # The resolver classifies the recovered 0 as unusable and fails closed.
    # A zero recovered from the API must never fail open through Gate 2.
    for score in 0 null; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert score:="$score")"
        fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
        [ "$(out pass)" = "true" ]
        [ "$(out cvss)" = "0" ]
    done
}

@test "advisory known: the scored record of the advisory wins across manifests" {
    # The same advisory can be open against several manifests in the updated
    # directory, one of them unscored. This ordering is what makes recovery
    # useful.
    alerts_fixture \
        "$(alert score:=0)" \
        "$(alert manifest=package.json score:=9.1)"
    fallback true "$LODASH" GHSA-aaaa-bbbb-cccc
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.1" ]
}

@test "no advisory: the highest-scored alert wins over an unscored one" {
    # No advisory is known, so the filter stays open and the best score among
    # the applicable alerts is the only evidence available.
    alerts_fixture \
        "$(alert score:=0)" \
        "$(alert ghsa=GHSA-gggg-hhhh-iiii score:=9.1)"
    fallback false "$LODASH"
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "9.1" ]
}

@test "a malformed API response degrades to no-match on both paths" {
    for gate1_pass in true false; do
        : >"$GITHUB_OUTPUT"
        echo 'not json' >"$GH_STUB_DIR/$ALERTS_KEY"
        run fallback "$gate1_pass" "$LODASH"
        no_match
        grep -qF '::warning::' <<<"$output"
    done
}

@test "unreadable updated-dependencies-json degrades to no-match" {
    # Without per-dependency metadata nothing can be matched safely, even
    # though an alert for a package of the same name is open.
    for deps in '' 'not json' '{}' 'null'; do
        : >"$GITHUB_OUTPUT"
        alerts_fixture "$(alert)"
        run fallback false "$deps"
        no_match
        grep -qF '::warning::' <<<"$output"
    done
}
