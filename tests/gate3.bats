#!/usr/bin/env bats
# Tests for the "Gate 3 — compatibility score" step of the reusable
# workflow. The step's script is pulled out of the YAML and run as-is, so
# these tests exercise the shipped code rather than a copy that can drift.
#
# Whether the gate applies comes from fetch-metadata's dependency-type, not
# from whether PR metadata named an advisory. With the alert lookup on, an
# indirect dependency can carry a GHSA ID and a direct one can arrive
# without one, so the old inference skipped the check for exactly the direct
# dependencies the alerts fallback recovered.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export STEP="$BATS_FILE_TMPDIR/gate3.sh"
    extract_run gate3 >"$STEP"
    # Guard the extractor the same way cvss.bats does. An empty or
    # half-dedented script would pass every assertion below.
    [ -s "$STEP" ]
    bash -n "$STEP"
    grep -q 'THRESHOLD' "$STEP"
    grep -q 'UPDATED_DEPENDENCIES' "$STEP"
}

setup() {
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    : >"$GITHUB_OUTPUT"
}

# Run the step with $1 as dependency-type, $2 as updated-dependencies-json
# and $3 as the threshold (default 80). The flags match what the step's
# `shell: bash` expands to in Actions.
gate3() {
    DEPENDENCY_TYPE="$1" UPDATED_DEPENDENCIES="$2" THRESHOLD="${3:-80}" \
        bash --noprofile --norc -e -o pipefail "$STEP"
}

# --- which PRs the gate applies to ------------------------------------------

@test "an indirect-only PR passes without a compatibility score" {
    # fetch-metadata cannot score transitive dependencies. The age gate is
    # their timing safeguard.
    gate3 indirect "$(dependencies "$(dependency dependencyType=indirect compatScore:=0)")"
    [ "$(out pass)" = "true" ]
}

@test "direct dependencies get the check" {
    for type in direct:production direct:development; do
        : >"$GITHUB_OUTPUT"
        gate3 "$type" "$(dependencies "$(dependency dependencyType="$type" compatScore:=0)")"
        [ "$(out pass)" = "false" ]
    done
}

@test "an unknown or missing dependency type still gets the check" {
    # fetch-metadata reports `unknown` when it cannot classify. Failing to
    # classify a PR must not be a way around the gate.
    for type in unknown ''; do
        : >"$GITHUB_OUTPUT"
        gate3 "$type" "$(dependencies "$(dependency dependencyType="$type" compatScore:=0)")"
        [ "$(out pass)" = "false" ]
        [ "$(out available)" = "false" ]
    done
}

# --- the threshold ----------------------------------------------------------

@test "a direct dependency at or above the threshold passes" {
    for score in 80 95 100; do
        : >"$GITHUB_OUTPUT"
        gate3 direct:production "$(dependencies "$(dependency compatScore:="$score")")"
        [ "$(out pass)" = "true" ]
        [ "$(out available)" = "true" ]
    done
}

@test "a direct dependency below the threshold fails with its score" {
    run gate3 direct:production "$(dependencies "$(dependency compatScore:=79)")"
    [ "$status" -eq 0 ]
    [ "$(out pass)" = "false" ]
    [ "$(out available)" = "true" ]
    [ "$(out score)" = "79" ]
    [ "$(out dependency)" = "lodash" ]
}

@test "the threshold input is honoured" {
    gate3 direct:production "$(dependencies "$(dependency compatScore:=60)")" 50
    [ "$(out pass)" = "true" ]
}

# --- unavailable scores fail closed -----------------------------------------

@test "an unavailable compatibility score fails closed" {
    # fetch-metadata reports 0 both when the lookup is off and when
    # Dependabot has no score, so 0 is missing data, not a 0% score. The
    # rest are values no real score can take.
    for score in 0 null '"80"' 101 85.5 -5; do
        : >"$GITHUB_OUTPUT"
        run gate3 direct:production "$(dependencies "$(dependency compatScore:="$score")")"
        [ "$status" -eq 0 ]
        [ "$(out pass)" = "false" ]
        [ "$(out available)" = "false" ]
        [ "$(out dependency)" = "lodash" ]
    done
}

@test "unreadable updated-dependencies-json fails closed" {
    for deps in '' 'not json' '{}' '[]'; do
        : >"$GITHUB_OUTPUT"
        run gate3 direct:production "$deps"
        [ "$status" -eq 0 ]
        [ "$(out pass)" = "false" ]
        [ "$(out available)" = "false" ]
    done
}

# --- grouped updates --------------------------------------------------------

@test "grouped: the lowest direct score gates the PR" {
    # The top-level compatibility-score output describes the first dependency
    # only, so a later low score would slip through on it.
    gate3 direct:production "$(dependencies \
        "$(dependency compatScore:=95)" \
        "$(dependency dependencyName=minimist compatScore:=60)")"
    [ "$(out pass)" = "false" ]
    [ "$(out score)" = "60" ]
    [ "$(out dependency)" = "minimist" ]
}

@test "grouped: an unscored direct member fails closed behind a scored first" {
    gate3 direct:production "$(dependencies \
        "$(dependency compatScore:=95)" \
        "$(dependency dependencyName=minimist compatScore:=0)")"
    [ "$(out pass)" = "false" ]
    [ "$(out available)" = "false" ]
    [ "$(out dependency)" = "minimist" ]
}

@test "grouped: indirect members do not need a score" {
    gate3 direct:production "$(dependencies \
        "$(dependency compatScore:=90)" \
        "$(dependency dependencyName=minimist dependencyType=indirect compatScore:=0)")"
    [ "$(out pass)" = "true" ]
    [ "$(out score)" = "90" ]
}

# --- wiring -----------------------------------------------------------------

@test "Gate 3 runs for every PR that clears Gate 2" {
    # Keyed on gate1.pass, the gate skipped a direct dependency whose
    # advisory came from the alerts fallback. Keyed on a non-empty score, it
    # skipped exactly the PRs with no score, and a skipped Gate 3 counts as
    # passed for the pending label.
    cond=$(extract_key gate3 if)
    grep -qF "steps.gate2.outputs.pass == 'true'" <<<"$cond"
    [ "$(grep -cF 'gate1' <<<"$cond")" -eq 0 ]
    [ "$(grep -cF 'compatibility-score' <<<"$cond")" -eq 0 ]
}

@test "a PR goes pending only when Gate 3 actually passed" {
    cond=$(extract_key label-pending if)
    grep -qF "steps.gate3.outputs.pass == 'true'" <<<"$cond"
    [ "$(grep -cF "steps.gate3.conclusion == 'skipped'" <<<"$cond")" -eq 0 ]
}

@test "the review label step takes the score from Gate 3, not the first dependency" {
    env=$(extract_key label-review env)
    grep -qF 'steps.gate3.outputs.score' <<<"$env"
    grep -qF 'steps.gate3.outputs.available' <<<"$env"
    [ "$(grep -cF 'steps.meta.outputs.compatibility-score' <<<"$env")" -eq 0 ]
}
