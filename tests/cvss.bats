#!/usr/bin/env bats
# Tests for the "Resolve effective CVSS" step of the reusable workflow. The
# step's script is pulled out of the YAML and run as-is, so these tests
# exercise the shipped code rather than a copy that can drift from it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    STEP="$BATS_TEST_TMPDIR/resolve-cvss.sh"
    extract_run cvss >"$STEP"
    # Guard the extractor: an empty script would pass every assertion below.
    [ -s "$STEP" ]
    grep -q 'GATE1_FALLBACK_CVSS' "$STEP"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
}

# Print the `run:` block of the step whose id is $1, dedented to column 0.
extract_run() {
    awk -v id="$1" '
        $0 ~ "^ +id: " id "$" { found = 1; next }
        found && !inrun && $0 ~ /^ +run: \|$/ {
            inrun = 1
            match($0, /^ +/)
            base = RLENGTH
            next
        }
        inrun {
            if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            match($0, /^ +/)
            if (RLENGTH <= base) exit
            if (!ind) ind = RLENGTH
            print substr($0, ind + 1)
        }
    ' "$WORKFLOW"
}

# Run the step with $1 as the Gate 1 CVSS and $2 as the Gate 1 fallback CVSS.
# The flags match the shell GitHub Actions uses for `run:` blocks.
resolve() {
    : >"$GITHUB_OUTPUT"
    GATE1_CVSS="$1" GATE1_FALLBACK_CVSS="$2" bash -e -o pipefail "$STEP"
}

# Print the value the step wrote to $GITHUB_OUTPUT under key $1.
out() {
    sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# --- a usable score comes through untouched -------------------------------

@test "a real score from PR metadata is used as-is" {
    resolve 8.8 ''
    [ "$(out value)" = "8.8" ]
    [ "$(out available)" = "true" ]
}

@test "empty PR metadata falls back to the alerts API score" {
    resolve '' 9.1
    [ "$(out value)" = "9.1" ]
    [ "$(out available)" = "true" ]
}

@test "PR metadata wins when both sources have a usable score" {
    # Guards the precedence: every other usable-score case passes an empty
    # fallback, so swapping the two sources would slip past them.
    resolve 8.8 9.1
    [ "$(out value)" = "8.8" ]
    [ "$(out available)" = "true" ]
}

@test "scores that merely contain zeros stay available" {
    for score in 10.0 7.0 0.1 0.05 .5 9.8; do
        resolve "$score" ''
        [ "$(out value)" = "$score" ]
        [ "$(out available)" = "true" ]
    done
}

# --- zero-like values are unavailable metadata, not low scores ------------

@test "CVSS 0.0 from PR metadata falls back to the alerts API score" {
    resolve 0.0 7.5
    [ "$(out value)" = "7.5" ]
    [ "$(out available)" = "true" ]
}

@test "a non-numeric CVSS from PR metadata falls back to the alerts API score" {
    resolve null 7.5
    [ "$(out value)" = "7.5" ]
    [ "$(out available)" = "true" ]
}

@test "CVSS 0.0 from both sources is unavailable metadata" {
    resolve 0.0 0.0
    [ "$(out value)" = "0.0" ]
    [ "$(out available)" = "false" ]
}

@test "CVSS 0 from both sources is unavailable metadata" {
    resolve 0 0
    [ "$(out value)" = "0" ]
    [ "$(out available)" = "false" ]
}

@test "empty CVSS from both sources is unavailable metadata" {
    resolve '' ''
    [ "$(out value)" = "" ]
    [ "$(out available)" = "false" ]
}

@test "a zero-like score with no fallback resolves to the empty fallback" {
    resolve 0.0 ''
    [ "$(out value)" = "" ]
    [ "$(out available)" = "false" ]
}

@test "every other spelling of numeric zero is unavailable metadata" {
    for score in 00 0.00 .0 0.0000 000.000; do
        resolve "$score" "$score"
        [ "$(out available)" = "false" ]
    done
}

@test "a non-numeric CVSS is unavailable metadata" {
    for score in null unknown N/A - 7.5.1 1e3 -3.2; do
        resolve "$score" "$score"
        [ "$(out available)" = "false" ]
    done
}

@test "the step reports the unusable value it saw" {
    run resolve 0.0 0.0
    [ "$status" -eq 0 ]
    # grep rather than [[ ]]: under macOS bash 3.2 a failed [[ ]] mid-test
    # cannot fail a bats test (errexit/ERR fire only for simple commands).
    grep -qF 'failing closed' <<<"$output"
    grep -qF "'0.0'" <<<"$output"
}
