#!/usr/bin/env bats
# Tests for the "Gate 1 — security advisory check" step of the reusable
# workflow. The step's script is pulled out of the YAML and run as-is, so
# these tests exercise the shipped code rather than a copy that can drift.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export STEP="$BATS_FILE_TMPDIR/gate1.sh"
    extract_run gate1 >"$STEP"
    # Guard the extractor the same way cvss.bats does: an empty or
    # half-dedented script would pass every assertion below.
    [ -s "$STEP" ]
    bash -n "$STEP"
    grep -q 'is_unusable()' "$STEP"
    grep -q 'GHSA_ID' "$STEP"
}

setup() {
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
}

# Run the step with $1 as the GHSA ID and $2 as the CVSS from fetch-metadata.
# The flags match what the step's `shell: bash` expands to in Actions.
gate1() {
    : >"$GITHUB_OUTPUT"
    GHSA_ID="$1" CVSS="$2" \
        bash --noprofile --norc -e -o pipefail "$STEP"
}

@test "a GHSA with a usable score passes and needs no fallback" {
    gate1 GHSA-xxxx-yyyy-zzzz 7.5
    [ "$(out pass)" = "true" ]
    [ "$(out cvss)" = "7.5" ]
    [ "$(out cvss-usable)" = "true" ]
}

@test "a GHSA with an unusable score passes but flags the fallback" {
    for score in '' 0 0.0 00 .00 N/A 11; do
        gate1 GHSA-xxxx-yyyy-zzzz "$score"
        [ "$(out pass)" = "true" ]
        [ "$(out cvss)" = "$score" ]
        [ "$(out cvss-usable)" = "false" ]
    done
}

@test "no GHSA fails the gate and writes no score outputs" {
    gate1 '' 7.5
    [ "$(out pass)" = "false" ]
    ! grep -q '^cvss' "$GITHUB_OUTPUT"
}

# Steps cannot share functions and callers never check this repo out, so the
# classifier is duplicated between this step and the resolver. The two copies
# deciding differently would break the fallback contract: a score Gate 1
# calls usable must never be one the resolver refuses to gate on.
@test "the is_unusable copies in gate1 and the resolver are identical" {
    slice() {
        sed -n '/^is_unusable() {/,/^}/p' <<<"$1"
    }
    gate1_copy=$(slice "$(cat "$STEP")")
    resolver_copy=$(slice "$(extract_run cvss)")
    [ -n "$gate1_copy" ]
    [ -n "$resolver_copy" ]
    [ "$gate1_copy" = "$resolver_copy" ]
}
