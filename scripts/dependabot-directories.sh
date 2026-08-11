#!/usr/bin/env bash
# Detect where dependency manifests and lockfiles actually live in a repository
# and map them into .github/dependabot.yml.
#
# Dependabot only updates a lockfile it has been pointed at. Where the lockfile
# is not at the default path — workspaces, monorepos, any non-root lockfile —
# security PRs ship without the lockfile update, CI stays red, and auto-merge
# never fires. See docs/directory-mapping.md for the full spec.
#
# This revision computes and reports the mapping. Writing it back (branch,
# Contents API, pull request) lands in a follow-up, so --dry-run is required.
set -euo pipefail

# comm(1) requires the same collation as the sort that produced its inputs.
# Without this the set math is wrong on some machines and right on others.
export LC_ALL=C

CONFIG_PATH=".github/dependabot.yml"

# A repo yielding more than this many entries is a heuristic failure, not a
# real configuration. Overridable with --force.
MAX_PAIRS=50

HARD_EXCLUDES=(node_modules vendor bower_components .git)
SOFT_EXCLUDES=(fixtures __fixtures__ testdata examples example dist build .next coverage)

NPM_LOCKFILES=(package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml)

# lockfile|ecosystem — recognizable ecosystems deferred to v1.1. Seeing one is
# reported so that partial coverage is never silent.
DEFERRED_LOCKFILES=(
    "Gemfile.lock|bundler"
    "go.sum|gomod"
    "Cargo.lock|cargo"
    "poetry.lock|pip"
    "uv.lock|pip"
)

usage() {
    cat <<'EOF'
Usage: scripts/dependabot-directories.sh <owner/repo> [options]

Detect manifest and lockfile locations in a repository and report the
.github/dependabot.yml directory mappings needed to cover them.

Detection is remote — the git trees API, plus a handful of Contents API reads
for workspace declarations. No full clone.

Options:
  --dry-run                Report the mapping and print a unified diff of the
                           proposed .github/dependabot.yml. Currently required:
                           the write path lands in a follow-up.
  --detect-only            Print the detected mappings and exit, before any
                           API call. Useful for "what would you map?".
  --include <dir>          Treat a soft-excluded directory name (examples,
                           dist, fixtures, ...) as real. Repeatable.
  --enable-version-updates Emit the full house template (open-pull-requests-limit
                           10 plus minor/patch grouping) instead of the
                           security-only default of 0.
  --force                  Proceed past the sanity cap of 50 mapped pairs.
  --paths-from-file <f>    Read the repository file list from <f>, one path per
                           line, instead of calling the API. Blob contents are
                           read from <f-without-extension>.blobs/<path>.
                           Offline testing seam.
  --existing-config <f>    Read the current .github/dependabot.yml from <f>
                           instead of the API. Offline testing seam.
  -h, --help               Show this help.

Authentication:
  Uses the gh CLI's credentials (gh auth login, or the GH_TOKEN env var).
  GH_TOKEN/GITHUB_TOKEN apply to github.com and ghe.com; for GitHub Enterprise
  Server set GH_HOST and GH_ENTERPRISE_TOKEN (or GITHUB_ENTERPRISE_TOKEN).
  Detection is read-only; a fine-grained PAT scoped to the repo needs:
    - Contents: Read        (file list and file contents)
    - Metadata: Read        (implied)

YAML:
  Reading an existing config needs one of yq (https://github.com/mikefarah/yq),
  python-yq, ruby, or python3 with PyYAML. Candidates are probed by running
  them, not by looking them up on PATH. Override with DEPENDABOT_DIRS_YAML_CMD.
EOF
}

die() {
    local code=$1
    shift
    printf 'error: %s\n' "$*" >&2
    exit "$code"
}

die_usage() {
    printf 'error: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

# --- output helpers -----------------------------------------------------------

COUNT_OK=0
COUNT_CHANGED=0
COUNT_NOTES=0
COUNT_FAILED=0

ok()       { printf '\342\234\223  %s\n' "$1"; COUNT_OK=$((COUNT_OK + 1)); }
would()    { printf '\342\206\222  %s\n' "$1"; COUNT_CHANGED=$((COUNT_CHANGED + 1)); }
note()     { printf '!  %s\n' "$1"; COUNT_NOTES=$((COUNT_NOTES + 1)); }
fail()     { printf '\342\234\227  %s\n' "$1" >&2; COUNT_FAILED=$((COUNT_FAILED + 1)); }
# Informational detection lines: they describe findings, not actions, so they
# stay out of the summary counters.
detected() { printf '   %s\n' "$1"; }

# One note for a whole class of findings, with a few examples.
#
# Real monorepos produce these by the hundred — a jetpack run emitted 270
# "manifest without lockfile" lines, which is a wall of text nobody reads and
# so reports nothing. Collapse to a count plus the first few, never to silence.
NOTE_SAMPLE=5
note_group() {
    local file=$1 summary=$2 n shown
    [[ -s $file ]] || return 0
    n=$(grep -c . <"$file" || true)
    [[ $n -eq 0 ]] && return 0
    note "$n $(plural "$n" directory directories) $summary"
    shown=0
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        shown=$((shown + 1))
        [[ $shown -gt $NOTE_SAMPLE ]] && break
        printf '     %s\n' "$line"
    done <"$file"
    if [[ $n -gt $NOTE_SAMPLE ]]; then
        printf '     ... and %d more\n' "$((n - NOTE_SAMPLE))"
    fi
}

# --- small utilities ----------------------------------------------------------

plural() {
    if [[ $1 -eq 1 ]]; then
        printf '%s' "$2"
    else
        printf '%s' "$3"
    fi
}

in_list() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# Escape a literal string for use inside an extended regular expression.
ere_quote() {
    printf '%s' "$1" | sed 's/[].[^$()*+?{}|\\]/\\&/g'
}

# Build an alternation of regex-escaped literals: a|b|c
alt_regex() {
    local out="" item
    for item in "$@"; do
        [[ -n $out ]] && out+="|"
        out+=$(ere_quote "$item")
    done
    printf '%s' "$out"
}

# "" / "." -> "/" ; ensure a leading slash; drop trailing slashes.
normalize_dir() {
    local d=$1
    d=${d#./}
    if [[ -z $d || $d == "." ]]; then
        printf '/\n'
        return 0
    fi
    [[ $d == /* ]] || d="/$d"
    while [[ $d == */ && $d != "/" ]]; do
        d=${d%/}
    done
    printf '%s\n' "$d"
}

# /a/b -> /a ; /a -> / ; / -> "" (sentinel: no parent)
parent_dir() {
    local d=$1
    [[ $d == "/" ]] && { printf '\n'; return 0; }
    d=${d%/*}
    [[ -z $d ]] && d="/"
    printf '%s\n' "$d"
}

# Map a stream of repo-relative file paths to their normalized directories.
paths_to_dirs() {
    sed -e 's#[^/]*$##' -e 's#/$##' -e 's#^#/#' | sort -u
}

# Select the paths whose basename is one of the given names.
select_basenames() {
    local re
    re="(^|/)($(alt_regex "$@"))\$"
    grep -E -- "$re" || true
}

# --- YAML backend -------------------------------------------------------------

YAML_CMD=""

# Probe candidates by RUNNING them. Presence on PATH proves nothing: python3 is
# routinely installed without PyYAML, and mikefarah's yq and python-yq share a
# binary name with incompatible command lines.
detect_yaml_tool() {
    [[ -n $YAML_CMD ]] && return 0

    local canary='a: [1, "x"]' expected='{"a":[1,"x"]}' candidate out
    local candidates=(
        "yq -o=json -I=0 ."
        "yq -j ."
        "ruby -ryaml -rjson -e \"puts JSON.generate(YAML.safe_load(STDIN.read))\""
        "python3 -c \"import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin) or {}, sys.stdout)\""
    )
    [[ -n ${DEPENDABOT_DIRS_YAML_CMD:-} ]] && candidates=("$DEPENDABOT_DIRS_YAML_CMD")

    for candidate in "${candidates[@]}"; do
        out=$(printf '%s\n' "$canary" | eval "$candidate" 2>/dev/null) || continue
        out=$(printf '%s' "$out" | jq -c . 2>/dev/null) || continue
        if [[ $out == "$expected" ]]; then
            YAML_CMD=$candidate
            return 0
        fi
    done
    return 1
}

yaml_to_json() {
    eval "$YAML_CMD"
}

# --- exclusions ---------------------------------------------------------------

HARD_RE=""
SOFT_RE=""

build_exclusion_regexes() {
    HARD_RE="(^|/)($(alt_regex "${HARD_EXCLUDES[@]}"))/"

    local effective=() name
    for name in "${SOFT_EXCLUDES[@]}"; do
        in_list "$name" ${INCLUDE_DIRS[@]+"${INCLUDE_DIRS[@]}"} && continue
        effective+=("$name")
    done
    if [[ ${#effective[@]} -eq 0 ]]; then
        SOFT_RE=""
    else
        SOFT_RE="(^|/)($(alt_regex "${effective[@]}"))/"
    fi
}

# --- glob translation ---------------------------------------------------------

# Translate a workspace glob into an anchored ERE.
#
# There is no working tree to glob against — only a path list — and bash 3.2 has
# no globstar, so shell globbing is not an option in either direction.
#
#   packages/*   ->  ^packages/[^/]*$
#   packages/**  ->  ^packages/.*$
#   a/**/b       ->  ^a/(.*/)?b$      (matches a/b as well as a/z/b)
#
# Characters are escaped as they are consumed; a later escaping pass would also
# escape the metacharacters this function just emitted.
glob_to_ere() {
    local pat=$1 out="" len i c next
    len=${#pat}
    i=0
    while [[ $i -lt $len ]]; do
        c=${pat:i:1}
        case $c in
            '*')
                next=${pat:i+1:1}
                if [[ $next == '*' ]]; then
                    i=$((i + 2))
                    if [[ ${pat:i:1} == '/' ]]; then
                        # The zero-segment case is the one everyone gets wrong:
                        # a/**/b must match a/b.
                        out+='(.*/)?'
                        i=$((i + 1))
                    else
                        out+='.*'
                    fi
                    continue
                fi
                out+='[^/]*'
                ;;
            '?') out+='[^/]' ;;
            [A-Za-z0-9_/-]) out+=$c ;;
            *) out+="\\$c" ;;
        esac
        i=$((i + 1))
    done
    printf '^%s$\n' "$out"
}

# Split workspace patterns into anchored positive and negative ERE files,
# resolved against the workspace root.
build_pattern_files() {
    local root=$1 pos=$2 neg=$3
    shift 3
    local pat target prefix
    : >"$pos"
    : >"$neg"
    prefix=${root%/}

    for pat in "$@"; do
        pat=${pat#./}
        while [[ $pat == */ && ${#pat} -gt 1 ]]; do
            pat=${pat%/}
        done
        [[ -z $pat ]] && continue
        case $pat in
            *'['*)
                note "workspace pattern '$pat' uses a character class, which is matched literally"
                ;;
        esac
        if [[ $pat == '!'* ]]; then
            target=$neg
            pat=${pat#!}
            [[ -z $pat ]] && continue
        else
            target=$pos
        fi
        glob_to_ere "$prefix/${pat#/}" >>"$target"
    done
}

# Positive matches minus negative matches, over a candidate directory list.
expand_patterns() {
    local pos=$1 neg=$2 cands=$3 out=$4
    : >"$out"
    # grep exits 1 on no match, which is fatal under errexit, so every call is
    # guarded and the result judged by whether the output file is empty.
    [[ -s $pos ]] || return 0
    if [[ -s $neg ]]; then
        # grep -Ev -f with an EMPTY pattern file matches nothing rather than
        # everything, which would silently empty the covered set. Hence the
        # explicit branch rather than always piping through the second grep.
        grep -E -f "$pos" -- "$cands" | grep -Ev -f "$neg" >"$out" || true
    else
        grep -E -f "$pos" -- "$cands" >"$out" || true
    fi
}

# --- blob reading -------------------------------------------------------------

# Detection never calls gh directly; it calls through this variable. That is the
# seam --paths-from-file swaps out, so the heuristics are genuinely testable
# offline rather than only nominally so. (bash 3.2 has no name references.)
FETCH_BLOB_FN="read_blob_api"

read_blob_api() {
    local path=$1 enc
    enc=$(jq -rn --arg s "$path" '$s | @uri')
    gh api "repos/$REPO/contents/$enc?ref=$ENC_BRANCH" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null
}

read_blob_local() {
    local path=$1
    [[ -f "$BLOB_DIR/$path" ]] || return 1
    cat -- "$BLOB_DIR/$path"
}

# --- file list ----------------------------------------------------------------

list_paths() {
    local out=$1 tree

    if [[ -n $PATHS_FROM_FILE ]]; then
        # Accept ./x and /x in hand-written fixtures.
        sed -e 's#^\./##' -e 's#^/##' -e '/^[[:space:]]*$/d' \
            <"$PATHS_FROM_FILE" | sort -u >"$out"
        return 0
    fi

    if ! tree=$(gh api "repos/$REPO/git/trees/$ENC_BRANCH?recursive=1" 2>&1); then
        fail "cannot read the file tree: $(head -c 300 <<<"$tree")"
        return 1
    fi
    if [[ $(jq -r '.truncated' <<<"$tree" 2>/dev/null) == true ]]; then
        # Never proceed on a partial list: a silently incomplete file list is
        # precisely the failure mode this script exists to prevent.
        fail "the git trees API truncated its response for $REPO — the blobless-clone fallback lands with the write path"
        return 1
    fi
    jq -r '.tree[] | select(.type == "blob") | .path' <<<"$tree" | sort -u >"$out" || {
        fail "cannot parse the file tree for $REPO"
        return 1
    }
}

# --- detection ----------------------------------------------------------------

WORKDIR=""
PAIRS=""

# Reject paths that would corrupt the |-delimited record format below.
sanity_filter() {
    local in=$1 out=$2 bad
    bad=$(grep -c '|' -- "$in" || true)
    if [[ $bad -gt 0 ]]; then
        note "skipped $bad path(s) containing '|', which the internal record format reserves"
    fi
    grep -v '|' -- "$in" >"$out" || true
}

apply_exclusions() {
    local in=$1 kept=$2 soft=$3
    grep -Ev -- "$HARD_RE" "$in" >"$WORKDIR/after_hard.txt" || true
    if [[ -n $SOFT_RE ]]; then
        grep -E -- "$SOFT_RE" "$WORKDIR/after_hard.txt" >"$soft" || true
        grep -Ev -- "$SOFT_RE" "$WORKDIR/after_hard.txt" >"$kept" || true
    else
        : >"$soft"
        cp "$WORKDIR/after_hard.txt" "$kept"
    fi

    if [[ -s $soft ]]; then
        local n
        n=$(wc -l <"$soft" | tr -d ' ')
        note "skipped $n path(s) under a soft-excluded directory (dist, examples, fixtures, ...) — use --include <dir> to keep one"
    fi
}

# Workspace readers return their patterns in a global rather than on stdout.
# Capturing a function's stdout makes any diagnostic it prints part of the data:
# a warning would be read straight back as if it were a workspace pattern.
WS_PATTERNS=()
WS_DECLARED=false

# Read a package.json's workspace patterns, in both shapes yarn and npm accept.
load_npm_workspaces() {
    local dir=$1 rel body shape line
    rel=${dir#/}
    [[ -n $rel ]] && rel="$rel/"
    body=$("$FETCH_BLOB_FN" "${rel}package.json" 2>/dev/null) || return 0

    shape=$(jq -r '.workspaces | type' <<<"$body" 2>/dev/null) || return 0
    case $shape in
        'null') return 0 ;;
        'array')
            WS_DECLARED=true
            while IFS= read -r line; do
                [[ -n $line ]] && WS_PATTERNS+=("$line")
            done < <(jq -r '.workspaces[] | select(type == "string")' <<<"$body" 2>/dev/null)
            ;;
        'object')
            # yarn v1 object form: {"packages": [...], "nohoist": [...]}
            WS_DECLARED=true
            while IFS= read -r line; do
                [[ -n $line ]] && WS_PATTERNS+=("$line")
            done < <(jq -r '.workspaces.packages[]? | select(type == "string")' <<<"$body" 2>/dev/null)
            ;;
        *)
            # Treating an unrecognised shape as "no workspaces" is what produces
            # per-package entry spam, so say so rather than guess.
            WS_DECLARED=true
            note "package.json at $dir declares 'workspaces' as a $shape, which is not a shape we recognise — treating it as covering nothing"
            ;;
    esac
    return 0
}

load_pnpm_workspaces() {
    local dir=$1 rel body json line before
    rel=${dir#/}
    [[ -n $rel ]] && rel="$rel/"
    body=$("$FETCH_BLOB_FN" "${rel}pnpm-workspace.yaml" 2>/dev/null) || return 0
    WS_DECLARED=true

    # "Could not parse it" and "it declares nothing" are different facts, and
    # conflating them sends people looking for a missing key that is right
    # there. WooCommerce's file is the live example: it declares packages: on
    # line 72, and every YAML parser rejects the file over a tab on line 4.
    if ! json=$(printf '%s\n' "$body" | yaml_to_json 2>/dev/null); then
        note "cannot parse pnpm-workspace.yaml at $dir — treating it as covering nothing (a tab character in the indentation is the usual cause)"
        return 0
    fi

    before=${#WS_PATTERNS[@]}
    while IFS= read -r line; do
        [[ -n $line ]] && WS_PATTERNS+=("$line")
    done < <(printf '%s' "$json" | jq -r '.packages[]? | select(type == "string")' 2>/dev/null)
    if [[ ${#WS_PATTERNS[@]} -eq $before ]]; then
        note "pnpm-workspace.yaml at $dir declares no 'packages:' — treating it as covering nothing"
    fi
    return 0
}

detect_npm() {
    local kept=$WORKDIR/kept.txt
    local m=$WORKDIR/m_npm.txt l=$WORKDIR/l_npm.txt

    select_basenames package.json <"$kept" | paths_to_dirs >"$m"
    select_basenames "${NPM_LOCKFILES[@]}" <"$kept" | paths_to_dirs >"$l"
    [[ -s $m ]] || return 0

    comm -12 "$l" "$m" >"$WORKDIR/npm_cands.txt"

    : >"$WORKDIR/npm_roots.txt"
    : >"$WORKDIR/npm_covered.txt"

    local idx=0 dir rel
    while IFS= read -r dir; do
        [[ -z $dir ]] && continue
        WS_PATTERNS=()
        WS_DECLARED=false

        rel=${dir#/}
        [[ -n $rel ]] && rel="$rel/"
        if grep -Fxq -- "${rel}pnpm-workspace.yaml" "$kept"; then
            load_pnpm_workspaces "$dir"
        fi
        load_npm_workspaces "$dir"

        [[ $WS_DECLARED == true ]] || continue

        printf '%s\n' "$dir" >>"$WORKDIR/npm_roots.txt"
        [[ ${#WS_PATTERNS[@]} -eq 0 ]] && continue

        build_pattern_files "$dir" "$WORKDIR/pos.$idx" "$WORKDIR/neg.$idx" "${WS_PATTERNS[@]}"
        expand_patterns "$WORKDIR/pos.$idx" "$WORKDIR/neg.$idx" "$m" "$WORKDIR/covered.$idx"
        # A root never covers itself.
        grep -Fxv -- "$dir" "$WORKDIR/covered.$idx" >"$WORKDIR/covered.$idx.tmp" || true
        mv "$WORKDIR/covered.$idx.tmp" "$WORKDIR/covered.$idx"
        cat "$WORKDIR/covered.$idx" >>"$WORKDIR/npm_covered.txt"
        idx=$((idx + 1))
    done <"$WORKDIR/npm_cands.txt"

    sort -u "$WORKDIR/npm_roots.txt" -o "$WORKDIR/npm_roots.txt"
    sort -u "$WORKDIR/npm_covered.txt" -o "$WORKDIR/npm_covered.txt"

    # emit = roots union (locks no root covers)
    comm -23 "$l" "$WORKDIR/npm_covered.txt" >"$WORKDIR/npm_uncovered_locks.txt"
    while IFS= read -r dir; do
        [[ -n $dir ]] && printf 'npm|%s|root\n' "$dir" >>"$PAIRS"
    done <"$WORKDIR/npm_roots.txt"

    comm -23 "$WORKDIR/npm_uncovered_locks.txt" "$WORKDIR/npm_roots.txt" >"$WORKDIR/npm_lock_only.txt"
    while IFS= read -r dir; do
        [[ -n $dir ]] && printf 'npm|%s|lock\n' "$dir" >>"$PAIRS"
    done <"$WORKDIR/npm_lock_only.txt"

    # A covered package with its own lockfile: hoisted installs ignore it, and
    # PRs against it would churn a file CI never reads.
    comm -12 "$l" "$WORKDIR/npm_covered.txt" |
        comm -23 - "$WORKDIR/npm_roots.txt" >"$WORKDIR/npm_shadowed.txt"
    note_group "$WORKDIR/npm_shadowed.txt" \
        "with a lockfile shadowed by the workspace covering them — hoisted installs ignore those, so no entry was emitted:"

    # A manifest nobody covers and with no lockfile of its own.
    comm -23 "$m" "$l" | comm -23 - "$WORKDIR/npm_covered.txt" >"$WORKDIR/npm_lockless.txt"
    note_group "$WORKDIR/npm_lockless.txt" \
        "with a package.json but no lockfile and no workspace covering them — no entry was emitted:"
}

detect_composer() {
    local kept=$WORKDIR/kept.txt
    local m=$WORKDIR/m_composer.txt l=$WORKDIR/l_composer.txt

    select_basenames composer.json <"$kept" | paths_to_dirs >"$m"
    select_basenames composer.lock <"$kept" | paths_to_dirs >"$l"
    [[ -s $m ]] || return 0

    local dir
    comm -12 "$m" "$l" >"$WORKDIR/composer_both.txt"
    while IFS= read -r dir; do
        [[ -n $dir ]] && printf 'composer|%s|lock\n' "$dir" >>"$PAIRS"
    done <"$WORKDIR/composer_both.txt"

    comm -23 "$m" "$l" >"$WORKDIR/composer_lockless.txt"
    note_group "$WORKDIR/composer_lockless.txt" \
        "with a composer.json but no composer.lock — no entry was emitted:"
}

detect_actions() {
    if grep -Eq '^\.github/workflows/[^/]+\.ya?ml$' "$WORKDIR/kept.txt"; then
        printf 'github-actions|/|actions\n' >>"$PAIRS"
    fi
}

detect_deferred() {
    local entry name eco found
    for entry in "${DEFERRED_LOCKFILES[@]}"; do
        IFS='|' read -r name eco <<<"$entry"
        found=$(select_basenames "$name" <"$WORKDIR/kept.txt" | head -n 3)
        [[ -z $found ]] && continue
        note "found $name ($eco is deferred to v1.1) — those directories are not mapped"
    done
}

# --- grouping into blocks -----------------------------------------------------

# blocks.txt records: eco|directory|is_glob
group_into_blocks() {
    local blocks=$WORKDIR/blocks.txt
    : >"$blocks"

    # Workspace roots and github-actions are never grouped: the root lockfile
    # already absorbs packages added later, so a glob has nothing to gain.
    grep -v '|root$' "$PAIRS" | grep -v '^github-actions|' >"$WORKDIR/groupable.txt" || true
    grep -e '|root$' -e '^github-actions|' "$PAIRS" >"$WORKDIR/ungroupable.txt" || true

    local eco dir parent key member
    : >"$WORKDIR/keyed.txt"
    : >"$WORKDIR/glob_map.txt"
    while IFS='|' read -r eco dir _; do
        [[ -z $eco ]] && continue
        parent=$(parent_dir "$dir")
        printf '%s|%s|%s\n' "$eco" "$parent" "$dir" >>"$WORKDIR/keyed.txt"
    done <"$WORKDIR/groupable.txt"
    sort -u "$WORKDIR/keyed.txt" -o "$WORKDIR/keyed.txt"

    : >"$WORKDIR/globbed_members.txt"
    if [[ -s $WORKDIR/keyed.txt ]]; then
        cut -d'|' -f1,2 "$WORKDIR/keyed.txt" | sort -u >"$WORKDIR/keys.txt"
        while IFS='|' read -r eco parent; do
            [[ -z $eco ]] && continue
            key="$eco|$parent|"
            grep -F -- "$key" "$WORKDIR/keyed.txt" | cut -d'|' -f3 | sort -u >"$WORKDIR/group.txt"
            local count
            count=$(wc -l <"$WORKDIR/group.txt" | tr -d ' ')
            [[ $count -lt 2 ]] && continue

            # Guard 1: a parent of / would emit "/*" and sweep every top-level
            # directory in the repository.
            if [[ -z $parent || $parent == "/" ]]; then
                note "$eco: $count directories sit at the repository root — keeping singular entries rather than globbing '/*'"
                continue
            fi

            # Guard 2: the glob must not re-admit what we excluded. Measured
            # against the UNFILTERED manifest list, because the glob GitHub
            # expands knows nothing about our exclusions.
            if ! glob_is_exact "$eco" "$parent" "$WORKDIR/group.txt"; then
                note "$eco: '$parent/*' would also match sibling directories this run did not map — keeping singular entries"
                continue
            fi

            printf '%s|%s/*|1\n' "$eco" "$parent" >>"$blocks"
            cat "$WORKDIR/group.txt" >>"$WORKDIR/globbed_members.txt"
            # Remember which directories a glob stands for, so the coverage pass
            # can degrade it to singular entries when only some are already
            # mapped — emitting the glob then would overlap the existing entry.
            while IFS= read -r member; do
                [[ -n $member ]] && printf '%s|%s/*|%s\n' "$eco" "$parent" "$member" >>"$WORKDIR/glob_map.txt"
            done <"$WORKDIR/group.txt"
        done <"$WORKDIR/keys.txt"
    fi

    sort -u "$WORKDIR/globbed_members.txt" -o "$WORKDIR/globbed_members.txt"
    while IFS='|' read -r eco parent dir; do
        [[ -z $eco ]] && continue
        grep -Fxq -- "$dir" "$WORKDIR/globbed_members.txt" && continue
        printf '%s|%s|0\n' "$eco" "$dir" >>"$blocks"
    done <"$WORKDIR/keyed.txt"

    while IFS='|' read -r eco dir _; do
        [[ -z $eco ]] && continue
        printf '%s|%s|0\n' "$eco" "$dir" >>"$blocks"
    done <"$WORKDIR/ungroupable.txt"

    sort -u "$blocks" -o "$blocks"
}

# Does <parent>/* match exactly the directories in the group, and nothing more?
glob_is_exact() {
    local eco=$1 parent=$2 group=$3 raw dir
    case $eco in
        npm) raw=$WORKDIR/m_npm_raw.txt ;;
        composer) raw=$WORKDIR/m_composer_raw.txt ;;
        *) return 1 ;;
    esac
    [[ -f $raw ]] || return 1

    # Direct children of parent holding a manifest, exclusions ignored.
    local pre
    pre=$(ere_quote "$parent")
    grep -E -- "^$pre/[^/]+\$" "$raw" >"$WORKDIR/glob_targets.txt" || true

    while IFS= read -r dir; do
        [[ -z $dir ]] && continue
        grep -Fxq -- "$dir" "$group" || return 1
    done <"$WORKDIR/glob_targets.txt"
    return 0
}

# --- rendering ----------------------------------------------------------------

render_block() {
    local eco=$1 dir=$2 is_glob=$3 item=$4 child=$5 gname

    printf '%s- package-ecosystem: "%s"\n' "$item" "$eco"
    if [[ $is_glob == 1 ]]; then
        printf '%sdirectories:\n' "$child"
        printf '%s  - "%s"\n' "$child" "$dir"
    else
        printf '%sdirectory: "%s"\n' "$child" "$dir"
    fi
    printf '%sschedule:\n' "$child"
    printf '%s  interval: "weekly"\n' "$child"
    printf '%s  day: "monday"\n' "$child"
    if [[ $ENABLE_VERSION_UPDATES == true ]]; then
        gname=$eco
        printf '%sopen-pull-requests-limit: 10\n' "$child"
        printf '%sgroups:\n' "$child"
        printf '%s  %s-minor-patch:\n' "$child" "$gname"
        printf '%s    patterns:\n' "$child"
        printf '%s      - "*"\n' "$child"
        printf '%s    update-types:\n' "$child"
        printf '%s      - "minor"\n' "$child"
        printf '%s      - "patch"\n' "$child"
        printf '%s  %s-major:\n' "$child" "$gname"
        printf '%s    patterns:\n' "$child"
        printf '%s      - "*"\n' "$child"
        printf '%s    update-types:\n' "$child"
        printf '%s      - "major"\n' "$child"
    else
        # Security updates need the directory mapping; version-update PRs are
        # noise the repo owner did not ask for. --enable-version-updates opts in.
        printf '%sopen-pull-requests-limit: 0\n' "$child"
    fi
    printf '%scooldown:\n' "$child"
    printf '%s  default-days: 7\n' "$child"
}

# --- existing configuration ---------------------------------------------------

EXISTING_RAW=""
EXISTING_PRESENT=false
ITEM_INDENT="  "
CHILD_INDENT="    "

read_existing_config() {
    if [[ -n $EXISTING_CONFIG_FILE ]]; then
        if [[ -f $EXISTING_CONFIG_FILE ]]; then
            EXISTING_RAW=$(cat -- "$EXISTING_CONFIG_FILE")
            EXISTING_PRESENT=true
        fi
        return 0
    fi
    [[ -n $PATHS_FROM_FILE ]] && return 0

    local alt
    if EXISTING_RAW=$(gh api "repos/$REPO/contents/.github%2Fdependabot.yml?ref=$ENC_BRANCH" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
        EXISTING_PRESENT=true
        return 0
    fi
    # Dependabot reads .yml only. A .yaml sitting there is a trap: we would
    # create a second file and the repo would keep obeying neither.
    if alt=$(gh api "repos/$REPO/contents/.github%2Fdependabot.yaml?ref=$ENC_BRANCH" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
        [[ -n $alt ]] && {
            fail ".github/dependabot.yaml exists but Dependabot reads .github/dependabot.yml — rename it first"
            return 1
        }
    fi
    return 0
}

# Refuse to text-splice a file whose structure we cannot reason about.
check_config_shape() {
    [[ $EXISTING_PRESENT == true ]] || return 0

    if printf '%s\n' "$EXISTING_RAW" | grep -qE '^[[:space:]]*[^[:space:]#].*$' &&
        printf '%s\n' "$EXISTING_RAW" | grep -qE '^	| 	|	 '; then
        fail "$CONFIG_PATH indents with tabs, which YAML forbids — fix it by hand"
        return 1
    fi
    if printf '%s\n' "$EXISTING_RAW" | grep -qE '^(---|\.\.\.)[[:space:]]*$' &&
        [[ $(printf '%s\n' "$EXISTING_RAW" | grep -cE '^(---|\.\.\.)[[:space:]]*$') -gt 1 ]]; then
        fail "$CONFIG_PATH holds more than one YAML document — fix it by hand"
        return 1
    fi
    if printf '%s\n' "$EXISTING_RAW" | grep -qE '(^|[[:space:]])[&*][A-Za-z0-9_-]+|<<:'; then
        fail "$CONFIG_PATH uses YAML anchors, aliases or merge keys — an append-only text edit cannot reason about those"
        return 1
    fi
    if printf '%s\n' "$EXISTING_RAW" | grep -qE '^updates:[[:space:]]*[[{]'; then
        fail "$CONFIG_PATH declares updates in inline form — convert it to a block sequence first"
        return 1
    fi
    if ! printf '%s\n' "$EXISTING_RAW" | grep -qE '^updates:[[:space:]]*(#.*)?$'; then
        fail "$CONFIG_PATH has no top-level 'updates:' key — fix it by hand"
        return 1
    fi
    return 0
}

# Match the file's own indentation rather than imposing ours.
detect_indentation() {
    [[ $EXISTING_PRESENT == true ]] || return 0

    local line item gap sub
    item=$(printf '%s\n' "$EXISTING_RAW" |
        sed -n '/^updates:/,$p' |
        grep -m1 -E '^[[:space:]]*-[[:space:]]+package-ecosystem:' || true)
    if [[ -z $item ]]; then
        # An updates: key with no items is still a safe append target.
        return 0
    fi
    line=${item%%-*}
    ITEM_INDENT=$line
    gap=${item#*-}
    gap=${gap%%[![:space:]]*}
    CHILD_INDENT="$ITEM_INDENT $(printf '%*s' ${#gap} '')"

    # Prefer what the file actually does over what the dash implies.
    sub=$(printf '%s\n' "$EXISTING_RAW" |
        sed -n '/^updates:/,$p' |
        grep -m1 -E '^[[:space:]]+(schedule|directory|directories|open-pull-requests-limit|cooldown|groups|target-branch):' || true)
    if [[ -n $sub ]]; then
        CHILD_INDENT=${sub%%[![:space:]]*}
    fi
}

# eco|dir records already present in the file, ignoring target-branch entries.
parse_existing_coverage() {
    local out=$WORKDIR/existing.txt
    : >"$out"
    [[ $EXISTING_PRESENT == true ]] || return 0

    local json
    if ! json=$(printf '%s\n' "$EXISTING_RAW" | yaml_to_json 2>/dev/null); then
        fail "cannot parse $CONFIG_PATH as YAML — refusing to guess at what it already covers"
        return 1
    fi
    if [[ $(jq -r 'if (.updates == null) then "null" elif (.updates | type) == "array" then "array" else "other" end' <<<"$json" 2>/dev/null) == "other" ]]; then
        fail "$CONFIG_PATH has an 'updates' key that is not a list — fix it by hand"
        return 1
    fi
    # Entries carrying target-branch are invisible to Dependabot's security
    # updates, so counting one as coverage would reintroduce the exact bug this
    # script exists to fix.
    jq -r '
        .updates[]? | . as $u
        | select($u["target-branch"] == null)
        | (($u.directories // []) + (if $u.directory then [$u.directory] else [] end))[]
        | "\($u["package-ecosystem"] // "?")|\(.)"
    ' <<<"$json" >"$out" 2>/dev/null || {
        fail "cannot read the update entries in $CONFIG_PATH"
        return 1
    }
    return 0
}

# Is (eco, dir) already mapped? An existing glob counts.
is_covered() {
    local eco=$1 dir=$2 line ex_eco ex_dir re
    [[ -s $WORKDIR/existing.txt ]] || return 1
    while IFS='|' read -r ex_eco ex_dir; do
        [[ -z $ex_eco ]] && continue
        [[ $ex_eco == "$eco" ]] || continue
        ex_dir=$(normalize_dir "$ex_dir")
        [[ $ex_dir == "$dir" ]] && return 0
        case $ex_dir in
            *'*'* | *'?'*)
                re=$(glob_to_ere "$ex_dir")
                printf '%s\n' "$dir" | grep -Eq -- "$re" && return 0
                ;;
        esac
    done <"$WORKDIR/existing.txt"
    return 1
}

# Existing entries pointing at directories we found no manifest in. Compared
# against the detected pairs rather than the rendered blocks: a directory folded
# into a glob is still very much detected.
report_stale_entries() {
    [[ -s $WORKDIR/existing.txt ]] || return 0
    local ex_eco ex_dir
    cut -d'|' -f1,2 "$PAIRS" | sort -u >"$WORKDIR/detected_pairs.txt"
    while IFS='|' read -r ex_eco ex_dir; do
        [[ -z $ex_eco ]] && continue
        case $ex_dir in
            *'*'* | *'?'*) continue ;;
        esac
        ex_dir=$(normalize_dir "$ex_dir")
        grep -Fxq -- "$ex_eco|$ex_dir" "$WORKDIR/detected_pairs.txt" && continue
        note "existing entry ($ex_eco, $ex_dir) matches nothing we detected — left alone"
    done <"$WORKDIR/existing.txt"
}

# Decide what is missing, one detected block at a time.
#
# A glob whose members are only PARTLY mapped already is degraded to singular
# entries for the unmapped members: emitting the glob would overlap the existing
# entry, and overlapping entries are exactly what makes Dependabot reject a
# config file outright.
plan_missing() {
    local eco dir is_glob member covered_n uncovered_n
    : >"$WORKDIR/missing.txt"
    while IFS='|' read -r eco dir is_glob; do
        [[ -z $eco ]] && continue

        if [[ $is_glob != 1 ]]; then
            if is_covered "$eco" "$dir"; then
                ok "$eco $dir: already mapped"
            else
                printf '%s|%s|0\n' "$eco" "$dir" >>"$WORKDIR/missing.txt"
            fi
            continue
        fi

        if is_covered "$eco" "$dir"; then
            ok "$eco $dir: already mapped"
            continue
        fi

        grep -F -- "$eco|$dir|" "$WORKDIR/glob_map.txt" | cut -d'|' -f3 >"$WORKDIR/members.txt" || true
        : >"$WORKDIR/members_uncovered.txt"
        covered_n=0
        while IFS= read -r member; do
            [[ -z $member ]] && continue
            if is_covered "$eco" "$member"; then
                covered_n=$((covered_n + 1))
            else
                printf '%s\n' "$member" >>"$WORKDIR/members_uncovered.txt"
            fi
        done <"$WORKDIR/members.txt"

        uncovered_n=$(wc -l <"$WORKDIR/members_uncovered.txt" | tr -d ' ')
        if [[ $uncovered_n -eq 0 ]]; then
            ok "$eco $dir: already mapped"
        elif [[ $covered_n -eq 0 ]]; then
            printf '%s|%s|1\n' "$eco" "$dir" >>"$WORKDIR/missing.txt"
        else
            note "$eco: '$dir' would overlap $covered_n $(plural "$covered_n" entry entries) already in the file — adding the $uncovered_n unmapped $(plural "$uncovered_n" directory directories) singly instead"
            while IFS= read -r member; do
                [[ -n $member ]] && printf '%s|%s|0\n' "$eco" "$member" >>"$WORKDIR/missing.txt"
            done <"$WORKDIR/members_uncovered.txt"
        fi
    done <"$WORKDIR/blocks.txt"
}

# --- proposal -----------------------------------------------------------------

# Build the proposed file bytes by appending missing blocks to the original.
build_proposal() {
    local missing=$WORKDIR/missing.txt
    local rendered=$WORKDIR/rendered.txt
    : >"$rendered"

    local eco dir is_glob shown
    while IFS='|' read -r eco dir is_glob; do
        [[ -z $eco ]] && continue
        shown=$dir
        render_block "$eco" "$dir" "$is_glob" "$ITEM_INDENT" "$CHILD_INDENT" >>"$rendered"
        would "map $eco -> $shown"
    done <"$missing"

    if [[ $EXISTING_PRESENT == false ]]; then
        {
            printf 'version: 2\n'
            printf 'updates:\n'
            cat "$rendered"
        } >"$WORKDIR/proposed.txt"
        return 0
    fi

    local total insert
    printf '%s\n' "$EXISTING_RAW" >"$WORKDIR/current.txt"
    total=$(wc -l <"$WORKDIR/current.txt" | tr -d ' ')
    insert=$(find_insertion_line "$WORKDIR/current.txt")

    {
        sed -n "1,${insert}p" "$WORKDIR/current.txt"
        cat "$rendered"
        if [[ $insert -lt $total ]]; then
            sed -n "$((insert + 1)),\$p" "$WORKDIR/current.txt"
        fi
    } >"$WORKDIR/proposed.txt"
}

# Last line of the updates: block — the next top-level key ends it.
find_insertion_line() {
    local file=$1
    awk '
        /^updates:[[:space:]]*(#.*)?$/ && !seen { seen = 1; last = NR; next }
        seen {
            if ($0 ~ /^[[:space:]]*$/) { next }
            if ($0 ~ /^[[:space:]]*#/) { last = NR; next }
            if ($0 ~ /^[^[:space:]]/) { exit }
            last = NR
        }
        END { print last }
    ' "$file"
}

# --- main ---------------------------------------------------------------------

REPO=""
DRY_RUN=false
DETECT_ONLY=false
ENABLE_VERSION_UPDATES=false
FORCE=false
PATHS_FROM_FILE=""
EXISTING_CONFIG_FILE=""
BLOB_DIR=""
INCLUDE_DIRS=()
DEFAULT_BRANCH=""
ENC_BRANCH=""

cleanup() {
    [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf -- "$WORKDIR"
}

require_value() {
    [[ $2 -ge 2 ]] || die_usage "$1 needs a value"
    [[ $3 != -* ]] || die_usage "$1 needs a value, got option '$3' — use $1='$3' for a value that begins with a dash"
    [[ -n $3 ]] || die_usage "$1 needs a value"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help)
            usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --detect-only)
            DETECT_ONLY=true
            shift
            ;;
        --enable-version-updates)
            ENABLE_VERSION_UPDATES=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --include)
            require_value --include $# "${2:-}"
            INCLUDE_DIRS+=("$2")
            shift 2
            ;;
        --include=*)
            [[ -n ${1#--include=} ]] || die_usage "--include needs a value"
            INCLUDE_DIRS+=("${1#--include=}")
            shift
            ;;
        --paths-from-file)
            require_value --paths-from-file $# "${2:-}"
            PATHS_FROM_FILE=$2
            shift 2
            ;;
        --paths-from-file=*)
            PATHS_FROM_FILE=${1#--paths-from-file=}
            [[ -n $PATHS_FROM_FILE ]] || die_usage "--paths-from-file needs a value"
            shift
            ;;
        --existing-config)
            require_value --existing-config $# "${2:-}"
            EXISTING_CONFIG_FILE=$2
            shift 2
            ;;
        --existing-config=*)
            EXISTING_CONFIG_FILE=${1#--existing-config=}
            [[ -n $EXISTING_CONFIG_FILE ]] || die_usage "--existing-config needs a value"
            shift
            ;;
        -*)
            die_usage "unknown option: $1"
            ;;
        *)
            [[ -z $REPO ]] || die_usage "unexpected argument: $1"
            REPO=$1
            shift
            ;;
    esac
done

[[ -n $REPO ]] || die_usage "missing required argument: owner/repo"
# Strict charsets so gh api cannot expand a literal '{owner}/{repo}' into a
# different repository from GH_REPO or the current checkout.
[[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$ ]] ||
    die_usage "invalid repository '$REPO' — expected owner/repo"

if [[ -n $PATHS_FROM_FILE ]]; then
    [[ -f $PATHS_FROM_FILE ]] || die 2 "--paths-from-file: no such file: $PATHS_FROM_FILE"
    FETCH_BLOB_FN=read_blob_local
    BLOB_DIR="${PATHS_FROM_FILE%.*}.blobs"
fi
if [[ -n $EXISTING_CONFIG_FILE && ! -f $EXISTING_CONFIG_FILE ]]; then
    die 2 "--existing-config: no such file: $EXISTING_CONFIG_FILE"
fi

if [[ $DRY_RUN == false && $DETECT_ONLY == false ]]; then
    die 2 "this revision only reports — re-run with --dry-run (or --detect-only). The write path lands in a follow-up."
fi

command -v jq >/dev/null 2>&1 || die 2 "jq not found — install it from https://jqlang.org"
if [[ -z $PATHS_FROM_FILE ]]; then
    command -v gh >/dev/null 2>&1 || die 2 "gh not found — install it from https://cli.github.com"
    gh auth status --hostname "${GH_HOST:-github.com}" >/dev/null 2>&1 ||
        die 2 "gh is not authenticated to ${GH_HOST:-github.com} — run 'gh auth login' or set GH_TOKEN"
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/dependabot-dirs.XXXXXX")
trap cleanup EXIT
PAIRS=$WORKDIR/pairs.txt
: >"$PAIRS"

if [[ -z $PATHS_FROM_FILE ]]; then
    REPO_JSON=$(gh api "repos/$REPO" 2>&1) ||
        die 2 "cannot read repos/$REPO: $(head -c 300 <<<"$REPO_JSON")"
    FULL_NAME=$(jq -r '.full_name' <<<"$REPO_JSON")
    # A renamed or transferred repo redirects, so the response can describe a
    # different repository than the one named on the command line.
    if [[ $(tr '[:upper:]' '[:lower:]' <<<"$FULL_NAME") != "$(tr '[:upper:]' '[:lower:]' <<<"$REPO")" ]]; then
        die 2 "repos/$REPO resolved to '$FULL_NAME' (renamed or transferred?) — re-run with the canonical name"
    fi
    DEFAULT_BRANCH=$(jq -r '.default_branch' <<<"$REPO_JSON")
    ENC_BRANCH=$(jq -rn --arg s "$DEFAULT_BRANCH" '$s | @uri')
fi

printf 'Scanning %s\n\n' "$REPO"

build_exclusion_regexes
list_paths "$WORKDIR/paths_raw.txt" || exit 1
sanity_filter "$WORKDIR/paths_raw.txt" "$WORKDIR/paths.txt"

# Guard 2 compares against the UNFILTERED manifest list: the glob GitHub expands
# knows nothing about our exclusions.
select_basenames package.json <"$WORKDIR/paths.txt" | paths_to_dirs >"$WORKDIR/m_npm_raw.txt"
select_basenames composer.json <"$WORKDIR/paths.txt" | paths_to_dirs >"$WORKDIR/m_composer_raw.txt"

apply_exclusions "$WORKDIR/paths.txt" "$WORKDIR/kept.txt" "$WORKDIR/soft.txt"

if [[ -z $PATHS_FROM_FILE ]] || detect_yaml_tool; then
    detect_yaml_tool || true
fi

detect_npm
detect_composer
detect_actions
detect_deferred

sort -u "$PAIRS" -o "$PAIRS"
group_into_blocks

if [[ ! -s $WORKDIR/blocks.txt ]]; then
    note "no npm, composer or github-actions manifests detected in $REPO"
    printf '\nSummary: %d ok, %d would change, %d notes, %d failed\n' \
        "$COUNT_OK" "$COUNT_CHANGED" "$COUNT_NOTES" "$COUNT_FAILED"
    exit 0
fi

PAIR_COUNT=$(wc -l <"$WORKDIR/blocks.txt" | tr -d ' ')
if [[ $PAIR_COUNT -gt $MAX_PAIRS && $FORCE == false ]]; then
    fail "detected $PAIR_COUNT mappings, past the sanity cap of $MAX_PAIRS — this is far more likely a detection bug than a real layout. Re-run with --force to proceed."
    printf '\nSummary: %d ok, %d would change, %d notes, %d failed\n' \
        "$COUNT_OK" "$COUNT_CHANGED" "$COUNT_NOTES" "$COUNT_FAILED"
    exit 1
fi

printf 'Detected mappings:\n'
while IFS='|' read -r eco dir is_glob; do
    [[ -z $eco ]] && continue
    if [[ $is_glob == 1 ]]; then
        detected "$eco: $dir (glob)"
    else
        detected "$eco: $dir"
    fi
done <"$WORKDIR/blocks.txt"
printf '\n'

if [[ $DETECT_ONLY == true ]]; then
    printf 'Summary: %d ok, %d would change, %d notes, %d failed\n' \
        "$COUNT_OK" "$COUNT_CHANGED" "$COUNT_NOTES" "$COUNT_FAILED"
    [[ $COUNT_FAILED -gt 0 ]] && exit 1
    exit 0
fi

detect_yaml_tool ||
    die 2 "no working YAML reader found — install yq (https://github.com/mikefarah/yq), or provide ruby or python3 with PyYAML"

read_existing_config || exit 1
check_config_shape || exit 1
detect_indentation
parse_existing_coverage || exit 1

plan_missing
report_stale_entries

if [[ ! -s $WORKDIR/missing.txt ]]; then
    ok "$CONFIG_PATH already covers every detected directory"
else
    build_proposal
    printf '\n'
    if [[ $EXISTING_PRESENT == true ]]; then
        diff -u --label "a/$CONFIG_PATH" --label "b/$CONFIG_PATH" \
            "$WORKDIR/current.txt" "$WORKDIR/proposed.txt" || true
    else
        diff -u --label "a/$CONFIG_PATH" --label "b/$CONFIG_PATH" \
            /dev/null "$WORKDIR/proposed.txt" || true
    fi
fi

printf '\nSummary: %d ok, %d would change, %d notes, %d failed\n' \
    "$COUNT_OK" "$COUNT_CHANGED" "$COUNT_NOTES" "$COUNT_FAILED"

[[ $COUNT_FAILED -gt 0 ]] && exit 1
exit 0
