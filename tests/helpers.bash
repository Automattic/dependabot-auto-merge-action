# shellcheck shell=bash
# Shared helpers for the bats suites. Every suite pulls the shipped `run:`
# scripts straight out of the workflow YAML, so the tests exercise the code
# that ships rather than a copy of it that can drift.

# Print the `run:` block of the step whose id is $1, dedented to column 0.
# Reads $WORKFLOW. Extraction, rather than a sourced scripts/ file, because
# caller repos never check this repo out — the workflow YAML is the only
# artifact they consume, so the shipped scripts have to live inline in it.
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

# Count the lines of $GH_STUB_LOG containing the fixed string $1. `|| true`
# because callers compare the count with `[ ]`: grep's no-match exit status
# would otherwise abort the test before the comparison runs.
log_count() {
    grep -cF -- "$1" "$GH_STUB_LOG" || true
}

# Succeed if one logged gh call contains every fixed string in $@. Each
# needle is matched independently, so an assertion stays true when flags are
# reordered in the YAML, which changes nothing about what the call does.
# Keep needles to flags and other unquoted words. The log is shell-quoted,
# and `printf %q` spells whitespace inside a value differently across bash
# versions, so a needle reaching into one matches on some platforms only.
log_has_call() {
    local lines needle
    lines=$(cat "$GH_STUB_LOG")
    for needle in "$@"; do
        lines=$(grep -F -- "$needle" <<<"$lines") || return 1
    done
    [ -n "$lines" ]
}

# Print the value a step wrote to $GITHUB_OUTPUT under key $1. Handles both
# forms Actions accepts: bare `key=value` and the `key<<DELIM` heredoc the
# cvss step uses for values that might contain a newline.
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
