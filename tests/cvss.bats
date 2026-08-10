#!/usr/bin/env bats
# Tests for the "Resolve effective CVSS" step of the reusable workflow. The
# step's script is pulled out of the YAML and run as-is, so these tests
# exercise the shipped code rather than a copy that can drift from it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    STEP="$BATS_TEST_TMPDIR/resolve-cvss.sh"
    extract_run cvss >"$STEP"
    # Guard the extractor: an empty or half-dedented script would pass every
    # assertion below. The dedent width comes from the first body line, so a
    # botched extraction can chop characters off shallower lines and still
    # look plausible — parse it and check for both landmarks.
    [ -s "$STEP" ]
    bash -n "$STEP"
    grep -q 'is_unusable()' "$STEP"
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

# Print the value the step wrote to $GITHUB_OUTPUT under key $1. Handles both
# forms Actions accepts: bare `key=value` and the `key<<DELIM` heredoc the step
# uses for values that might contain a newline.
out() {
    awk -v k="$1" '
        !inblock && index($0, k "<<") == 1 {
            delim = substr($0, length(k) + 3)
            inblock = 1
            next
        }
        inblock && $0 == delim { inblock = 0; next }
        inblock { print; next }
        !inblock && index($0, k "=") == 1 { print substr($0, length(k) + 2) }
    ' "$GITHUB_OUTPUT"
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
    # fallback, so swapping the two sources would slip past them. Like the
    # zero-like pair cases below, this state is defence in depth — the
    # workflow only ever populates one source.
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

# The next three cases populate both sources at once. The workflow cannot
# actually produce that: gate1 writes its `cvss` output only when it passes,
# and gate1-fallback runs only when gate1 fails, so exactly one is ever set.
# They are kept as defence in depth — if that wiring ever changes, precedence
# and fallback should still behave — not as claims about real inputs.

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

# The direct-dependency shape, and the one the ticket was filed about: Gate 1
# matched an advisory but GitHub scored it 0.0, so there is no fallback to fall
# back to. The score must not survive as the effective value — but it must
# survive as `reported`, or the review comment cannot name what GitHub sent.
@test "a zero-like score with no fallback still reports what GitHub sent" {
    for score in 0 0.0 00 .00; do
        resolve "$score" ''
        [ "$(out value)" = "" ]
        [ "$(out reported)" = "$score" ]
        [ "$(out available)" = "false" ]
    done
}

@test "a non-numeric score with no fallback still reports what GitHub sent" {
    resolve 'N/A' ''
    [ "$(out reported)" = "N/A" ]
    [ "$(out available)" = "false" ]
}

@test "an unusable score from the alerts API is reported too" {
    resolve '' 0.0
    [ "$(out reported)" = "0.0" ]
    [ "$(out available)" = "false" ]
}

@test "no score from either source reports nothing" {
    resolve '' ''
    [ "$(out reported)" = "" ]
    [ "$(out available)" = "false" ]
}

# --- implausible scores fail closed, same as zero -------------------------

@test "a score above the CVSS range is unavailable metadata" {
    for score in 99.9 11 10.1 1000; do
        resolve "$score" ''
        [ "$(out reported)" = "$score" ]
        [ "$(out available)" = "false" ]
    done
}

@test "the top of the CVSS range is still usable" {
    resolve 10 ''
    [ "$(out value)" = "10" ]
    [ "$(out available)" = "true" ]
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

@test "the step logs the unusable value it saw" {
    # No fallback, so this is the direct-dep shape: the log must still name
    # 0.0 rather than the empty string the score resolves to.
    run resolve 0.0 ''
    [ "$status" -eq 0 ]
    # grep rather than [[ ]]: under macOS bash 3.2 a failed [[ ]] mid-test
    # cannot fail a bats test (errexit/ERR fire only for simple commands).
    grep -qF 'failing closed' <<<"$output"
    grep -qF "'0.0'" <<<"$output"
}
