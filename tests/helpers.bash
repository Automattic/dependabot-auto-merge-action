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

# Print the `if:` condition of the step whose id is $1, one line per line of
# a folded `if: |` block, dedented to column 0. Reads $WORKFLOW. A script
# test cannot notice a step that stops checking the output it depends on,
# and several of the workflow's security boundaries are `if:` expressions
# rather than scripts, so the wiring suite reads the conditions directly.
extract_if() {
    awk -v id="$1" '
        function flush() {
            if (hit) printf "%s", cond
            hit = 0; cond = ""; inif = 0
        }
        /^ +steps:$/ { match($0, /^ +/); stepind = RLENGTH + 4; flush(); next }
        stepind && match($0, /^ +- /) && RLENGTH - 2 == stepind { flush() }
        stepind && $0 ~ "^ +id: " id "$" { hit = 1 }
        inif {
            match($0, /^ */)
            if ($0 !~ /^[[:space:]]*$/ && RLENGTH > ifind) {
                if (!bodyind) bodyind = RLENGTH
                cond = cond substr($0, bodyind + 1) "\n"
                next
            }
            inif = 0
        }
        stepind && match($0, /^ +if: /) && RLENGTH - 4 == stepind + 2 {
            ifind = RLENGTH - 4
            value = substr($0, RLENGTH + 1)
            if (value == "|") { inif = 1; bodyind = 0 } else { cond = value "\n" }
        }
        END { flush() }
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

# One commit status as the statuses API returns it: $1 = state, $2 = the
# creator's login, $3 = context (default: the eligibility context that
# evaluate-pr writes).
commit_status() {
    printf '{"state":"%s","context":"%s","creator":{"login":"%s"}}' \
        "$1" "${3:-dependabot-auto-merge/eligibility}" "$2"
}

# Serve the statuses in $2.. for commit $1 of $GITHUB_REPOSITORY as the
# paginated, slurped response: an array of pages, newest status first, the
# order the API documents. No statuses after $1 serves an empty page.
statuses_fixture() {
    local sha=$1 sep='' status
    shift
    {
        printf '[['
        for status in "$@"; do
            printf '%s%s' "$sep" "$status"
            sep=','
        done
        printf ']]'
    } >"$GH_STUB_DIR/GET_repos_${GITHUB_REPOSITORY//[^A-Za-z0-9]/_}_commits_${sha}_statuses_per_page_100"
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

# Print the value of key $2 (`if`, `with`, ...) on the step whose id is $1,
# one line per line of the value, leading whitespace stripped. Covers both
# the inline form and a `|` block or mapping on the following lines. The
# gate wiring lives in `if:` expressions, which no bats suite can execute,
# so asserting on their text is the only guard against a condition that
# silently skips a gate.
extract_key() {
    awk -v id="$1" -v key="$2" '
        $0 ~ "^ +id: " id "$" {
            found = 1
            match($0, /^ +/)
            base = RLENGTH
            next
        }
        found && !inkey {
            # Blank lines inside a run block would otherwise read as the
            # end of the step. The next step starts shallower than `id:`.
            if ($0 ~ /^[[:space:]]*$/) next
            match($0, /^ +/)
            if (RLENGTH < base) exit
            if ($0 ~ "^ +" key ":") {
                inkey = 1
                sub("^ +" key ": *[|]? *", "")
                if (length($0)) print
            }
            next
        }
        inkey {
            if ($0 ~ /^[[:space:]]*$/) next
            match($0, /^ +/)
            if (RLENGTH <= base) exit
            sub(/^ +/, "")
            print
        }
    ' "$WORKFLOW"
}

# Run `jq -nc` with filter $1, binding each later word as a named argument
# the filter reads from $ARGS.named. `key=value` binds a string and
# `key:=json` binds parsed JSON, so a fixture can override one field at a
# time without restating the rest.
jq_named() {
    local filter=$1 pair
    local args=()
    shift
    for pair in "$@"; do
        case $pair in
            *:=*) args+=(--argjson "${pair%%:=*}" "${pair#*:=}") ;;
            *) args+=(--arg "${pair%%=*}" "${pair#*=}") ;;
        esac
    done
    jq -nc "${args[@]}" "$filter"
}

# One entry of fetch-metadata's `updated-dependencies-json`, carrying the
# keys the steps read. The defaults describe a direct lodash security update
# in the repository root. Override any key, e.g. `dependency newVersion=1.2.3
# compatScore:=90`. `packageEcosystem` holds Dependabot's package manager
# name (`npm_and_yarn`), because that is what fetch-metadata reports, not the
# alerts API ecosystem (`npm`).
dependency() {
    jq_named '{
        dependencyName: "lodash",
        dependencyType: "direct:production",
        directory: "/",
        packageEcosystem: "npm_and_yarn",
        prevVersion: "4.17.20",
        newVersion: "4.17.21",
        compatScore: 0
    } + $ARGS.named' "$@"
}

# The `updated-dependencies-json` array holding the given entries.
dependencies() {
    local IFS=,
    printf '[%s]' "$*"
}
