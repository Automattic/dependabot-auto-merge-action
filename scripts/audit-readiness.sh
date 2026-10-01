#!/usr/bin/env bash
# Audit repositories for dependabot-auto-merge readiness.
# Read-only: this script never issues a non-GET request. It is the inverse of
# scripts/bootstrap.sh — bootstrap changes a repo, this one only reports.
#
# A check the caller's token cannot see is reported `unknown`, never `fail`.
# Calling a repo broken when we simply could not look is the one failure mode
# that costs trust with the teams who own these repos.
set -euo pipefail

# Absolute, because the probe workers are exec'd by xargs, which cannot run a
# bare name like "audit-readiness.sh" from the current directory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Teams that exist to hold automation, not to own repositories. Size-based
# exclusion catches the org-wide teams on its own; these are small enough to
# survive it, so they need naming.
DEFAULT_EXCLUDE_TEAMS="woo-eng-bot canonical-extensions-testing-bot fueledbotaccess mailpoet-ci scrutinizer-auto-fixer wordpress-deploy-script-push bot"

usage() {
    cat <<'EOF'
Usage: scripts/audit-readiness.sh (--org <org> | --repo <owner/repo>...) [options]

Report which repositories are ready for the dependabot-auto-merge reusable
workflow, and what each one is missing.

Read-only. This script never issues a non-GET request, so it is safe to hand
to anyone who wants to check their own repositories.

Every check reports one of four states:
  pass      configured
  fail      positively observed as not configured
  unknown   your token cannot see it — NOT the same as fail
  na        the repo has no npm or Composer manifest, so the check cannot apply

A repo is `ready` only when nothing failed and nothing is unknown.

Scope:
  --org <login>              Audit every repository in the organisation.
  --repo <owner/repo>        Audit one repository. Repeatable, and usable
                             without organisation read access — this is the
                             form a team lead runs.
  --include-archived         Include archived repositories.
  --include-forks            Include forks.
  --include-advisory-forks   Include the private <repo>-ghsa-xxxx-xxxx-xxxx
                             repositories GitHub creates for security
                             advisories. They are not marked as forks, so they
                             are excluded by name instead.
  --has-dependabot-config    Only repositories that already have
                             .github/dependabot.yml.
  --team <slug>              Only repositories owned by this team. Repeatable.
  --status <s>               Filter output: ready|blocked|unknown|na. Repeatable.
  --wave <n>                 Filter output to wave band n (1-4). Repeatable.
                             Bands are quantiles of the current run, so they
                             only mean something relative to the other repos
                             audited alongside. wave.score is the stable
                             number.

Expectations:
  --merge-method <m>         squash|merge|rebase (default squash). Which repo
                             merge setting the audit requires.
  --fast-track-label <name>  Default security-fast-track.
  --pending-label <name>     Default auto-merge-pending.
  --review-label <name>      Default sirt-review-required.
  --alerts-token-secret <n>  Secret name to look for when a caller workflow does
                             not name one itself. Default
                             QUALITYOPS_DEPENDABOT_ALERTS_TOKEN, the name
                             already in use in the Automattic org.
  --expect-ref <sha>         Caller workflows are compared against this ref.
                             Unresolvable means unknown, never fail.
  --team-overrides <file>    Default scripts/audit-team-overrides.tsv.
  --exclude-team <slug>      Repeatable; adds to the bot-team defaults.
  --max-team-size <n|pct>    Teams larger than this are treated as org-wide and
                             ignored for ownership. Default 25%.
  --max-owner-candidates <n> A repo with more than this many candidate teams is
                             reported as shared rather than assigned to one.
                             Default 3.

Output:
  --format <f>               jsonl|table|team|summary|csv (default table).
                             Repeatable. jsonl is always written to --out-dir.
  --out-dir <dir>            Default .audit
  --from-jsonl <file>        Re-render from a previous run. Issues no API call.
  --explain-owners           Show why each team was kept or dropped.
  --exit-code                Exit 1 when any repository is blocked.

Fetching:
  --jobs <n>                 Concurrency for the per-repo phase (default 8).
  --cache-ttl <dur>          Passed to gh as --cache=<dur> (default 1h).
  --no-cache                 Bypass the gh response cache.
  --rate-floor <n>           Stop when remaining core quota drops below this
                             (default 200). The run still writes everything it
                             already gathered.
  -h, --help                 Show this help.

Authentication:
  Uses the gh CLI's credentials (gh auth login, or the GH_TOKEN env var).
  GH_TOKEN/GITHUB_TOKEN apply to github.com and ghe.com; for GitHub Enterprise
  Server set GH_HOST and GH_ENTERPRISE_TOKEN (or GITHUB_ENTERPRISE_TOKEN).
  Read access is enough. Checks you cannot see report `unknown`, so a run with
  a low-privilege token is still useful — it just answers less.

Exit codes:
  0  the audit ran
  1  the audit could not complete (rate limit, org unreadable), or --exit-code
     was given and at least one repository is blocked
  2  usage or authentication refusal
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

API_ERR_FILE=$(mktemp)
WORK=""
WORK_OWNED=false
cleanup() {
    rm -f "$API_ERR_FILE"
    # Workers share $WORK with the parent, so only its creator removes it.
    [[ $WORK_OWNED == true && -n $WORK ]] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT INT TERM

# --- output helpers -----------------------------------------------------------

COUNT_OK=0
COUNT_FAILED=0
COUNT_UNKNOWN=0
COUNT_NOTES=0

ok()      { printf '\342\234\223  %s\n' "$1"; COUNT_OK=$((COUNT_OK + 1)); }
note()    { printf '!  %s\n' "$1"; COUNT_NOTES=$((COUNT_NOTES + 1)); }
unknown() { printf '?  %s\n' "$1"; COUNT_UNKNOWN=$((COUNT_UNKNOWN + 1)); }
fail()    { printf '\342\234\227  %s\n' "$1" >&2; COUNT_FAILED=$((COUNT_FAILED + 1)); }

# --- read-only api funnel -----------------------------------------------------

# api <api-path-or-graphql> [extra gh args...]
# The ONLY place that invokes gh. It can issue GET and graphql and nothing
# else, which is what makes "this script never writes" a one-line assertion in
# the test suite — the same role --dry-run plays in bootstrap.sh.
#
# On failure it returns 1 and leaves the error in $API_ERR_FILE, which
# api_err reads. A plain variable cannot be used: every caller wraps this in a
# command substitution, and that subshell would discard the assignment.
# Callers decide whether a failure means `fail` or `unknown`; this funnel never
# decides that for them.
api() {
    local path=$1
    shift
    local -a args
    args=("$path" "$@")
    [[ $NO_CACHE == true ]] || args+=("--cache=$CACHE_TTL")

    : >"$API_ERR_FILE"
    gh api "${args[@]}" 2>"$API_ERR_FILE"
}

# REST variant. Reads the rate-limit headers in band, because `gh api
# rate_limit` reports a stale snapshot: it said 5000 remaining / 0 used in the
# same second a real response header said 4848 / 152.
api_rest() {
    local path=$1
    shift
    local -a args
    args=("$path" "-i" "$@")
    [[ $NO_CACHE == true ]] || args+=("--cache=$CACHE_TTL")

    : >"$API_ERR_FILE"
    local raw remaining
    raw=$(gh api "${args[@]}" 2>"$API_ERR_FILE") || return 1

    remaining=$(printf '%s\n' "$raw" | grep -i '^x-ratelimit-remaining:' | head -1 | tr -d '\r' | awk '{print $2}')
    if [[ -n $remaining ]]; then
        check_brake "$remaining" || true
    fi

    # Drop the header block: everything up to and including the first blank
    # line. A CRLF-only line counts as blank.
    printf '%s\n' "$raw" | awk 'seen { print; next } /^[[:space:]]*$/ { seen = 1 }'
}

api_err() { head -c 300 "$API_ERR_FILE" 2>/dev/null || true; }
api_err_matches() { grep -qE "$1" "$API_ERR_FILE" 2>/dev/null; }

# Trip the brake when the remaining quota runs low. Reads the rateLimit block
# GraphQL returns in-band; `gh api rate_limit` cannot be used here because it
# reports a stale snapshot (observed 5000/used 0 in the same second a real
# response header reported 4848/used 152).
check_brake() {
    local remaining=$1
    [[ -n $remaining && $remaining != null ]] || return 0
    if [[ $remaining -lt $RATE_FLOOR ]]; then
        : >"$WORK/brake"
        return 1
    fi
    return 0
}

braked() { [[ -f $WORK/brake ]]; }

# --- graphql documents --------------------------------------------------------
#
# Every operation is named. The test stub keys its fixtures on the operation
# name, so an anonymous document is untestable.

# JSON-escape a value for interpolation into a GraphQL document.
gql_str() { jq -n --arg s "$1" '$s' 2>/dev/null || printf '""'; }

repo_fields() {
    cat <<EOF
    nameWithOwner isArchived isFork isPrivate isDisabled isEmpty pushedAt
    autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
    viewerPermission hasVulnerabilityAlertsEnabled
    openAlerts: vulnerabilityAlerts(first: 0, states: OPEN) { totalCount }
    everAlerts: vulnerabilityAlerts(first: 0) { totalCount }
    latestRelease { publishedAt }
    defaultBranchRef {
      name
      target { ... on Commit { committedDate history(first: 0) { totalCount } } }
      branchProtectionRule {
        requiresStatusChecks
        requiredStatusCheckContexts
        requiredApprovingReviewCount
      }
      rules(first: 25) {
        totalCount
        nodes {
          type
          parameters {
            __typename
            ... on RequiredStatusChecksParameters {
              strictRequiredStatusChecksPolicy
              requiredStatusChecks { context }
            }
            ... on PullRequestParameters { requiredApprovingReviewCount }
          }
          repositoryRuleset { name enforcement }
        }
      }
    }
    ft:   labels(first: 20, query: $(gql_str "$FAST_TRACK_LABEL")) { nodes { name color description } }
    pend: labels(first: 20, query: $(gql_str "$PENDING_LABEL"))    { nodes { name color description } }
    sirt: labels(first: 20, query: $(gql_str "$REVIEW_LABEL"))     { nodes { name color description } }
    depYml:  object(expression: "HEAD:.github/dependabot.yml")  { ... on Blob { byteSize } }
    depYaml: object(expression: "HEAD:.github/dependabot.yaml") { ... on Blob { byteSize } }
    caller:  object(expression: "HEAD:.github/workflows/dependabot-auto-merge.yml") {
      ... on Blob { byteSize isTruncated text }
    }
    root: object(expression: "HEAD:") { ... on Tree { entries { name type } } }
EOF
}

query_repo_page() {
    cat <<EOF
query RepoPage(\$org: String!, \$endCursor: String) {
  rateLimit { cost remaining resetAt }
  organization(login: \$org) {
    repositories(first: $PAGE_SIZE, after: \$endCursor, orderBy: {field: PUSHED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      totalCount
      nodes {
$(repo_fields)
      }
    }
  }
}
EOF
}

# One aliased selection per repo, so --repo mode touches no organization node
# and works for a caller with no org read at all.
# REPOS[$1] up to but not including REPOS[$2]. The alias carries the index
# into REPOS, so an error on r_N always names REPOS[N].
query_repo_set() {
    local i=$1 end=$2 r owner name
    printf 'query RepoSet {\n  rateLimit { cost remaining resetAt }\n'
    while [[ $i -lt $end ]]; do
        r=${REPOS[$i]}
        owner=${r%%/*}
        name=${r#*/}
        printf '  r_%d: repository(owner: %s, name: %s) {\n%s\n  }\n' \
            "$i" "$(gql_str "$owner")" "$(gql_str "$name")" "$(repo_fields)"
        i=$((i + 1))
    done
    printf '}\n'
}

query_repo_names() {
    cat <<'EOF'
query RepoNames($org: String!, $endCursor: String) {
  rateLimit { cost remaining }
  organization(login: $org) {
    repositories(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { nameWithOwner }
    }
  }
}
EOF
}

query_team_list() {
    cat <<'EOF'
query TeamList($org: String!, $endCursor: String) {
  rateLimit { cost remaining resetAt }
  organization(login: $org) {
    teams(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { slug repositories { totalCount } }
    }
  }
}
EOF
}

query_team_repos() {
    cat <<'EOF'
query TeamRepos($org: String!, $slug: String!, $endCursor: String) {
  rateLimit { cost remaining resetAt }
  organization(login: $org) {
    team(slug: $slug) {
      slug
      repositories(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        edges { permission node { nameWithOwner } }
      }
    }
  }
}
EOF
}

query_dependabot_prs() {
    cat <<'EOF'
query DependabotPRs($q: String!, $endCursor: String) {
  rateLimit { cost remaining resetAt }
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { repository { nameWithOwner } } }
  }
}
EOF
}

# --- preflight ----------------------------------------------------------------

preflight() {
    command -v gh >/dev/null 2>&1 || die 2 "gh not found — install it from https://cli.github.com"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found — install it from https://jqlang.org"
    # Scope to the target host: plain 'gh auth status' fails if ANY configured
    # host is unreachable, even when the relevant one is fine.
    gh auth status --hostname "${GH_HOST:-github.com}" >/dev/null 2>&1 ||
        die 2 "gh is not authenticated to ${GH_HOST:-github.com} — run 'gh auth login' or set GH_TOKEN"

    local probe
    probe=$(api graphql -f query='query Viewer { viewer { login } rateLimit { remaining } }') ||
        die 2 "cannot reach the GraphQL API: $(api_err)"
    jq -e '.data.viewer.login' >/dev/null 2>&1 <<<"$probe" ||
        die 2 "GraphQL returned no viewer — check the token's scopes"

    if [[ -n $ORG ]]; then
        api graphql -f query='query OrgProbe($org: String!) { organization(login: $org) { login } }' -f org="$ORG" >/dev/null ||
            die 2 "cannot read organisation '$ORG': $(api_err)"
    fi
}

# --- phase 1: bulk repository sweep -------------------------------------------

# Attribute a GraphQL error to the repo and field it came from. A settings
# boolean is Boolean!, so a permission failure cannot arrive as null — it
# arrives here, nulling its node. Unattributed, one repo in a page of 25 would
# vanish silently.
#
# Errors are matched to repos by name, never by position: nulled nodes are
# dropped before the records are built, so a position would land on the next
# repo. In --repo mode the alias r_N names REPOS[N], passed as $2. In an org
# page the error names a node index, and the name is read from that node. A
# nulled node has no name to read, and the reconcile phase reports it as
# unknown instead.
record_graphql_errors() {
    local body=$1 names=${2:-[]}
    jq -c --argjson names "$names" '
        . as $body
        | (.errors // [])[]
        | select(.path != null)
        | . as $e
        | ($e.path | map(select(type == "string") | capture("^r_(?<n>[0-9]+)$") | .n | tonumber) | first) as $alias
        | ($e.path | map(select(type == "number")) | first) as $pos
        | (if $alias != null then $names[$alias]
           elif $pos != null then ($body.data.organization.repositories.nodes[$pos].nameWithOwner // null)
           else null end) as $repo
        | ($e.path | map(select(type == "string")) | last) as $field
        | select($repo != null)
        | {repo: $repo, field: $field, reason: ($e.message // "graphql error")}
    ' <<<"$body" >>"$WORK/errors.jsonl" 2>/dev/null || true
}

# Print the secret the caller passes as `token` to the reusable workflow,
# nothing when the calling job passes none, or "?" when that job cannot be
# found. Only the job that calls dependabot-auto-merge.yml counts, since a
# `token:` in another job does not reach it, and the value may be quoted.
# The job is the nearest line above `uses:` indented less than it, and runs
# until the next line indented no more than the job key.
caller_token_secret() {
    awk '
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) if (line[i] ~ /dependabot-auto-merge\.yml@/) { u = i; break }
            if (!u) { print "?"; exit }
            ui = match(line[u], /[^ ]/) - 1
            for (i = u - 1; i >= 1; i--) {
                if (line[i] ~ /^[ ]*(#|$)/) continue
                ji = match(line[i], /[^ ]/) - 1
                if (ji < ui) { j = i; break }
            }
            if (!j) { print "?"; exit }
            for (i = j + 1; i <= NR; i++) {
                if (line[i] ~ /^[ ]*(#|$)/) continue
                if (match(line[i], /[^ ]/) - 1 <= ji) break
                if (line[i] ~ /^[ ]*token[ ]*:[ ]*["\047]?\$\{\{[ ]*secrets\.[A-Za-z0-9_]+/) {
                    s = line[i]
                    sub(/.*secrets\./, "", s)
                    sub(/[^A-Za-z0-9_].*/, "", s)
                    print s
                    exit
                }
            }
        }'
}

# Whether the secrets list on stdin names $1.
secret_listed() { jq -e --arg n "$1" '(.secrets // []) | any(.name == $n)' >/dev/null 2>&1; }

# Whether the secrets list on stdin is one page of a longer list.
secret_list_partial() { jq -e '(.total_count // 0) > ((.secrets // []) | length)' >/dev/null 2>&1; }

# A node for a repository nothing could be read from. It keeps the repo visible
# and lets every check resolve to unknown, which is the honest answer.
placeholder_node() {
    jq -cn --arg r "$1" '{
        nameWithOwner: $r,
        isArchived: false, isFork: false, isDisabled: false, isEmpty: null,
        isPrivate: null, pushedAt: null,
        autoMergeAllowed: null, squashMergeAllowed: null,
        mergeCommitAllowed: null, rebaseMergeAllowed: null,
        viewerPermission: null, hasVulnerabilityAlertsEnabled: null,
        sweep_incomplete: true
    }'
}

phase_repos() {
    local body cursor="" page=0 has_next=true remaining degraded

    if [[ ${#REPOS[@]} -gt 0 ]]; then
        local doc names i start=0 end
        names=$(printf '%s\n' "${REPOS[@]}" | jq -R . | jq -sc .)
        # In chunks of PAGE_SIZE, because one query over every repo is refused
        # with a 502 at around 16 repositories, the same limit the org sweep
        # pages around.
        while [[ $start -lt ${#REPOS[@]} ]]; do
            end=$((start + PAGE_SIZE))
            [[ $end -le ${#REPOS[@]} ]] || end=${#REPOS[@]}
            doc=$(query_repo_set "$start" "$end")
            # gh exits non-zero when any alias errors, but still prints the
            # data for the rest, so the body is kept and judged on its own.
            body=$(api graphql -f query="$doc") || true
            if ! jq -e '.data | type == "object"' >/dev/null 2>&1 <<<"$body"; then
                if [[ $PAGE_SIZE -gt 3 ]]; then
                    PAGE_SIZE=$((PAGE_SIZE / 2))
                    note "GraphQL query was refused; retrying with $PAGE_SIZE repositories per query"
                    continue
                fi
                die 1 "repository sweep failed: $(api_err)"
            fi
            record_graphql_errors "$body" "$names"
            # A repo that does not exist or cannot be read nulls its alias. It
            # is reported as unknown rather than dropped from the report.
            i=$start
            while [[ $i -lt $end ]]; do
                if jq -e --arg k "r_$i" '.data[$k] != null' >/dev/null 2>&1 <<<"$body"; then
                    jq -c --arg k "r_$i" '.data[$k]' <<<"$body" >>"$WORK/nodes.jsonl"
                else
                    placeholder_node "${REPOS[$i]}" >>"$WORK/nodes.jsonl"
                fi
                i=$((i + 1))
            done
            start=$end
            remaining=$(jq -r '.data.rateLimit.remaining // empty' <<<"$body")
            check_brake "$remaining" || { note "rate limit floor reached during the repository sweep"; break; }
        done
        return 0
    fi

    while [[ $has_next == true ]]; do
        local doc
        doc=$(query_repo_page)
        # gh exits non-zero when any repo in the page cannot be read, but
        # still prints the others. Keep the body and judge it below, or one
        # unreadable repo would shrink the page until the sweep gave up.
        if [[ -z $cursor ]]; then
            body=$(api graphql -f query="$doc" -f org="$ORG") || true
        else
            body=$(api graphql -f query="$doc" -f org="$ORG" -f endCursor="$cursor") || true
        fi

        # Too large a page fails two ways and only one of them is loud. With
        # this field set, first:25 returns 502; first:20 returns HTTP 200 with
        # a null rateLimit and no nodes at all. Treating the quiet one as
        # success would drop a whole page of repositories without saying so.
        degraded=false
        if [[ -z $body ]]; then
            degraded=true
        elif ! jq -e '.data.organization.repositories.nodes | type == "array"' >/dev/null 2>&1 <<<"$body"; then
            degraded=true
        fi

        if [[ $degraded == true ]]; then
            if [[ $PAGE_SIZE -gt 3 ]]; then
                PAGE_SIZE=$((PAGE_SIZE / 2))
                note "GraphQL page was refused or truncated; retrying with page size $PAGE_SIZE"
                continue
            fi
            die 1 "repository sweep failed even at page size $PAGE_SIZE: $(api_err)"
        fi

        record_graphql_errors "$body"
        jq -c '.data.organization.repositories.nodes[] | select(. != null)' <<<"$body" >>"$WORK/nodes.jsonl"

        page=$((page + 1))
        has_next=$(jq -r '.data.organization.repositories.pageInfo.hasNextPage' <<<"$body")
        cursor=$(jq -r '.data.organization.repositories.pageInfo.endCursor' <<<"$body")
        remaining=$(jq -r '.data.rateLimit.remaining // empty' <<<"$body")
        check_brake "$remaining" || { note "rate limit floor reached during the repository sweep"; break; }
    done
}

# --- phase 1b: reconcile the sweep against the org's own list ----------------

# Compares names, not counts. Paging can repeat a repo and skip another while
# the counts still agree, and totalCount can change between pages. So the
# sweep is deduplicated by name, and every name in the org's own listing that
# the sweep did not return becomes a placeholder reported as unknown. If that
# listing cannot be read to the end, the run stops rather than report a sweep
# it cannot vouch for.
phase_reconcile() {
    [[ -n $ORG ]] || return 0

    jq -c -s 'unique_by(.nameWithOwner)[]' "$WORK/nodes.jsonl" >"$WORK/nodes.dedup" &&
        mv "$WORK/nodes.dedup" "$WORK/nodes.jsonl"
    jq -r '.nameWithOwner' "$WORK/nodes.jsonl" | sort -u >"$WORK/have-names"
    wc -l <"$WORK/have-names" | tr -d ' ' >"$WORK/received-count"

    local body cursor="" has_next=true
    : >"$WORK/all-names"
    while [[ $has_next == true ]]; do
        if [[ -z $cursor ]]; then
            body=$(api graphql -f query="$(query_repo_names)" -f org="$ORG") ||
                die 1 "cannot list the organisation's repositories to check the sweep: $(api_err)"
        else
            body=$(api graphql -f query="$(query_repo_names)" -f org="$ORG" -f endCursor="$cursor") ||
                die 1 "cannot list the organisation's repositories to check the sweep: $(api_err)"
        fi
        jq -e '.data.organization.repositories.nodes | type == "array"' >/dev/null 2>&1 <<<"$body" ||
            die 1 "cannot list the organisation's repositories to check the sweep: $(api_err)"
        jq -r '.data.organization.repositories.nodes[]?.nameWithOwner' <<<"$body" >>"$WORK/all-names"
        has_next=$(jq -r '.data.organization.repositories.pageInfo.hasNextPage' <<<"$body")
        cursor=$(jq -r '.data.organization.repositories.pageInfo.endCursor' <<<"$body")
    done

    sort -u "$WORK/all-names" >"$WORK/want-names"
    wc -l <"$WORK/want-names" | tr -d ' ' >"$WORK/total-count"

    local missing=0 r
    while read -r r; do
        [[ -n $r ]] || continue
        placeholder_node "$r" >>"$WORK/nodes.jsonl"
        missing=$((missing + 1))
    done < <(comm -23 "$WORK/want-names" "$WORK/have-names")

    printf '%s' "$missing" >"$WORK/missing-count"
    [[ $missing -eq 0 ]] || note "$missing repositories were not returned by the sweep and are reported as unknown"
}

# --- phase 2: team ownership --------------------------------------------------

phase_teams() {
    printf '{}' >"$WORK/teams.json"
    [[ -n $ORG ]] || return 0

    local body cursor="" has_next=true
    : >"$WORK/team-sizes.tsv"
    while [[ $has_next == true ]]; do
        if [[ -z $cursor ]]; then
            body=$(api graphql -f query="$(query_team_list)" -f org="$ORG") || return 0
        else
            body=$(api graphql -f query="$(query_team_list)" -f org="$ORG" -f endCursor="$cursor") || return 0
        fi
        jq -r '.data.organization.teams.nodes[] | [.slug, .repositories.totalCount] | @tsv' \
            <<<"$body" >>"$WORK/team-sizes.tsv"
        has_next=$(jq -r '.data.organization.teams.pageInfo.hasNextPage' <<<"$body")
        cursor=$(jq -r '.data.organization.teams.pageInfo.endCursor' <<<"$body")
    done

    # Size threshold: a percentage of the in-scope repo count, so a new
    # org-wide team is excluded automatically rather than needing a code change.
    local in_scope threshold
    in_scope=$(wc -l <"$WORK/nodes.jsonl" | tr -d ' ')
    case $MAX_TEAM_SIZE in
        *%) threshold=$(( in_scope * ${MAX_TEAM_SIZE%\%} / 100 )) ;;
        *)  threshold=$MAX_TEAM_SIZE ;;
    esac
    [[ $threshold -gt 0 ]] || threshold=1

    : >"$WORK/team-decisions.tsv"
    local slug size keep
    while IFS=$'\t' read -r slug size; do
        [[ -n $slug ]] || continue
        keep=yes
        case " $EXCLUDE_TEAMS " in *" $slug "*) keep="no (bot team)" ;; esac
        if [[ $keep == yes && $size -gt $threshold ]]; then
            keep="no (size $size > $threshold)"
        fi
        printf '%s\t%s\t%s\n' "$slug" "$size" "$keep" >>"$WORK/team-decisions.tsv"
    done <"$WORK/team-sizes.tsv"

    if [[ $EXPLAIN_OWNERS == true ]]; then
        printf '\nTeam ownership decisions (threshold %d repos):\n' "$threshold"
        sort -t$'\t' -k2 -rn "$WORK/team-decisions.tsv" | while IFS=$'\t' read -r slug size keep; do
            printf '  %-40s %5s  %s\n' "$slug" "$size" "$keep"
        done
        printf '\n'
    fi

    : >"$WORK/team-edges.jsonl"
    while IFS=$'\t' read -r slug size keep; do
        [[ $keep == yes ]] || continue
        cursor=""
        has_next=true
        while [[ $has_next == true ]]; do
            if [[ -z $cursor ]]; then
                body=$(api graphql -f query="$(query_team_repos)" -f org="$ORG" -f slug="$slug") || break
            else
                body=$(api graphql -f query="$(query_team_repos)" -f org="$ORG" -f slug="$slug" -f endCursor="$cursor") || break
            fi
            jq -c --arg slug "$slug" --argjson size "$size" '
                .data.organization.team.repositories.edges[]
                | {repo: .node.nameWithOwner, team: $slug, size: $size, permission: .permission}
            ' <<<"$body" >>"$WORK/team-edges.jsonl"
            has_next=$(jq -r '.data.organization.team.repositories.pageInfo.hasNextPage' <<<"$body")
            cursor=$(jq -r '.data.organization.team.repositories.pageInfo.endCursor' <<<"$body")
        done
    done <"$WORK/team-decisions.tsv"

    # Smallest remaining team holding ADMIN or MAINTAIN wins; ties break on
    # slug so the result is deterministic across runs.
    #
    # Except when a repo has many candidate teams, where "smallest" is
    # actively wrong: a widely shared repo picks up whichever team happens to
    # own fewest repos overall, which is the least likely owner rather than
    # the most. The WooCommerce monorepo has 19 candidates and this rule chose
    # a one-repo payments team. Above the threshold the audit reports the repo
    # as shared and names the candidates instead of guessing, which is the
    # same refusal it makes everywhere else it cannot see clearly.
    jq -s --argjson max_candidates "$MAX_OWNER_CANDIDATES" '
        map(select(.permission == "ADMIN" or .permission == "MAINTAIN"))
        | group_by(.repo)
        | map({
            key: .[0].repo,
            value: (sort_by(.size, .team) as $ranked
              | (map(.team) | unique) as $candidates
              | if ($candidates | length) > $max_candidates then
                  {team: null, permission: null, candidates: $candidates, source: "ambiguous"}
                else
                  {team: $ranked[0].team, permission: $ranked[0].permission,
                   candidates: $candidates, source: "team-index"}
                end)
          })
        | from_entries
    ' "$WORK/team-edges.jsonl" >"$WORK/teams.json" 2>/dev/null || printf '{}' >"$WORK/teams.json"

    # Overrides win over everything the heuristic decided.
    if [[ -n $TEAM_OVERRIDES && -f $TEAM_OVERRIDES ]]; then
        jq -R -s --slurpfile base <(cat "$WORK/teams.json") '
            split("\n")
            | map(select(length > 0 and (startswith("#") | not)))
            | map(split("\t"))
            | map(select(length >= 2))
            | map({key: .[0], value: {team: .[1], permission: null, candidates: [.[1]], source: "override"}})
            | from_entries
            | ($base[0] // {}) + .
        ' "$TEAM_OVERRIDES" >"$WORK/teams.override.json" 2>/dev/null &&
            mv "$WORK/teams.override.json" "$WORK/teams.json"
    fi
}

# --- phase 3: activity --------------------------------------------------------

phase_activity() {
    printf '{}' >"$WORK/activity.json"
    local q body cursor="" has_next=true
    if [[ -n $ORG ]]; then
        q="org:$ORG is:pr is:open author:app/dependabot"
    else
        q="is:pr is:open author:app/dependabot"
        local r
        for r in "${REPOS[@]}"; do q="$q repo:$r"; done
    fi

    : >"$WORK/prs.jsonl"
    while [[ $has_next == true ]]; do
        if [[ -z $cursor ]]; then
            body=$(api graphql -f query="$(query_dependabot_prs)" -f q="$q") || break
        else
            body=$(api graphql -f query="$(query_dependabot_prs)" -f q="$q" -f endCursor="$cursor") || break
        fi
        jq -r '.data.search.nodes[]? | select(.repository != null) | .repository.nameWithOwner' \
            <<<"$body" >>"$WORK/prs.jsonl"
        has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$body")
        cursor=$(jq -r '.data.search.pageInfo.endCursor' <<<"$body")
    done

    jq -R -s 'split("\n") | map(select(length > 0)) | group_by(.) | map({key: .[0], value: length}) | from_entries' \
        "$WORK/prs.jsonl" >"$WORK/activity.json" 2>/dev/null || printf '{}' >"$WORK/activity.json"
}

# --- phase 4: classic branch protection, per repo -----------------------------
#
# Only reached for repos the bulk sweep leaves undecided. Follows preflight's
# chain exactly (branches/{b} -> .protected -> branches/{b}/protection ->
# .required_status_checks != null), not bootstrap's, so the audit's verdict
# can never contradict the job it exists to predict.

probe_repo() {
    local repo=$1 node branch enc out
    local checks_status="" checks_detail="" config_status="" config_detail="" manifest_count=""
    local token_status="" token_detail=""

    node=$(jq -c --arg r "$repo" 'select(.nameWithOwner == $r)' "$AUDIT_WORK/nodes.jsonl" | head -1)
    if [[ -z $node ]]; then
        jq -cn --arg r "$repo" '{repo: $r}'
        return 0
    fi
    branch=$(jq -r '.defaultBranchRef.name // empty' <<<"$node")

    # --- required status checks, classic fallback -----------------------------
    #
    # Only for repos the bulk sweep could not answer. Follows preflight's chain
    # so the audit can never contradict the job it exists to predict.
    if [[ $(jq -r 'if ((.defaultBranchRef.rules.nodes // []) | map(select(.type == "REQUIRED_STATUS_CHECKS")) | length) == 0
                      and (.defaultBranchRef.branchProtectionRule // null) == null
                      and .defaultBranchRef != null
                   then "yes" else "no" end' <<<"$node") == yes ]]; then
        if [[ -z $branch ]]; then
            checks_status=unknown
            checks_detail="no default branch"
        else
            # Branch names may contain URL-significant characters ('#' starts a
            # fragment); encode exactly as preflight does.
            enc=$(printf '%s' "$branch" | jq -sRr '@uri')
            if ! out=$(api_rest "repos/$repo/branches/$enc"); then
                checks_status=unknown
                checks_detail="cannot read branch '$branch': $(api_err)"
            elif [[ $(jq -r '.protected' <<<"$out" 2>/dev/null) != true ]]; then
                checks_status=fail
                checks_detail="default branch '$branch' is not protected and has no ruleset checks"
            elif ! out=$(api_rest "repos/$repo/branches/$enc/protection"); then
                # Admin-only endpoint. Preflight warns and continues here; so do we.
                checks_status=unknown
                checks_detail="branch '$branch' is protected but its protection details need an admin token"
            elif [[ $(jq -r '.required_status_checks | if . == null then "null" else "set" end' <<<"$out" 2>/dev/null) == set ]]; then
                checks_status=pass
                checks_detail="classic branch protection requires status checks on '$branch'"
            else
                checks_status=fail
                checks_detail="branch '$branch' is protected but requires no status checks"
            fi
        fi
    fi

    # --- does this repo actually need a dependabot.yml? -----------------------
    #
    # Exclusions match docs/directory-mapping.md: the hard list that is never
    # mapped, and the soft list that is skipped with a warning. A repo whose
    # only nested manifests are fixtures or build output needs no mapping, so
    # counting them would fail a repo that is fine.
    #
    # Security updates do not require a config when every manifest sits at
    # Dependabot's default path. A config is needed when one does not, which is
    # the failure mode docs/directory-mapping.md exists for: the repo passes
    # preflight, its security PRs ship without lockfile updates, CI stays red
    # and auto-merge never fires. So the question is not "is there a config"
    # but "is there a manifest the defaults would miss".
    # Runs for any repo without a config, not just ones with a root manifest.
    # Keying it on the root tree missed repos whose manifests live only in
    # subdirectories: they read as having no dependencies at all and dropped out
    # of the rollout silently, which is the exact shape of failure this audit
    # exists to surface.
    if [[ $(jq -r 'if .depYml == null and .depYaml == null then "yes" else "no" end' <<<"$node") == yes ]]; then
        if [[ -z $branch ]]; then
            config_status=unknown
            config_detail="no default branch"
        elif ! out=$(api_rest "repos/$repo/git/trees/$branch?recursive=1"); then
            config_status=unknown
            config_detail="cannot read the file tree: $(api_err)"
        elif [[ $(jq -r '.truncated' <<<"$out" 2>/dev/null) == true ]]; then
            # Never decide on a truncated list. A silently incomplete file list
            # is exactly the failure this check exists to catch.
            config_status=unknown
            config_detail="the file tree is truncated; run bin/dependabot-directories to map this repo"
        else
            local manifests nested
            manifests=$(jq -r '
                [.tree[]
                 | select(.type == "blob")
                 | select(.path | test("(^|/)(package|composer)\\.json$"))
                 | select(.path | test("(^|/)(node_modules|vendor|bower_components|\\.git)/") | not)
                 | select(.path | test("(^|/)(fixtures|__fixtures__|testdata|examples|example|dist|build|\\.next|coverage)/") | not)
                 | .path]
                | length' <<<"$out" 2>/dev/null)
            nested=$(jq -r '
                [.tree[]
                 | select(.type == "blob")
                 | select(.path | test("/(package|composer)\\.json$"))
                 | select(.path | test("(^|/)(node_modules|vendor|bower_components|\\.git)/") | not)
                 | select(.path | test("(^|/)(fixtures|__fixtures__|testdata|examples|example|dist|build|\\.next|coverage)/") | not)
                 | .path]
                | .[0:3] | join(", ")' <<<"$out" 2>/dev/null)
            manifest_count=${manifests:-0}
            if [[ ${manifests:-0} -eq 0 ]]; then
                config_status=na
                config_detail="no npm or Composer manifest anywhere in the repository"
            elif [[ -n $nested ]]; then
                config_status=fail
                config_detail="manifests outside the root need explicit directory mappings (e.g. $nested); run bin/dependabot-directories"
            else
                config_status=pass
                config_detail="no config needed; every manifest is at the root, which Dependabot covers by default"
            fi
        fi
    fi

    # --- is an alerts token actually wired up? --------------------------------
    #
    # GITHUB_TOKEN cannot read the Dependabot alerts API under any
    # configuration, so a repo without this secret loses every
    # indirect-dependency security PR. Secret *values* are never readable;
    # names are, which is enough to tell "wired" from "not wired".
    local want_secret repo_secrets org_secrets caller_text
    caller_text=$(jq -r '.caller.text // empty' <<<"$node" 2>/dev/null)
    if [[ -n $caller_text ]]; then
        want_secret=$(caller_token_secret <<<"$caller_text")
    else
        # Not adopted yet. Check for the secret the rollout will wire up.
        want_secret=$ALERTS_TOKEN_SECRET
    fi

    if [[ $want_secret == "?" ]]; then
        token_status=unknown
        token_detail="cannot find the job that calls the workflow in the caller, so cannot tell which secret it passes"
    elif [[ -z $want_secret ]]; then
        token_status=fail
        token_detail="the caller passes no token secret, so the workflow falls back to GITHUB_TOKEN, which cannot read the Dependabot alerts API"
    elif ! repo_secrets=$(api_rest "repos/$repo/actions/secrets?per_page=100"); then
        # Listing repository secrets needs admin. Not knowing is not a failure.
        token_status=unknown
        token_detail="cannot list repository secrets (needs admin); could not confirm '$want_secret'"
    elif secret_listed "$want_secret" <<<"$repo_secrets"; then
        token_status=pass
        token_detail="secret '$want_secret' exists"
    elif secret_list_partial <<<"$repo_secrets"; then
        token_status=unknown
        token_detail="the repository has more than 100 secrets and only the first 100 were read; could not confirm '$want_secret'"
    elif ! org_secrets=$(api_rest "repos/$repo/actions/organization-secrets?per_page=100"); then
        # The secret may be shared from the organisation. Without that list
        # its absence is not known, so this is not a failure either.
        token_status=unknown
        token_detail="no repository secret named '$want_secret', and cannot list the organisation secrets shared with it; could not confirm one"
    elif secret_listed "$want_secret" <<<"$org_secrets"; then
        token_status=pass
        token_detail="organisation secret '$want_secret' is shared with this repository"
    elif secret_list_partial <<<"$org_secrets"; then
        token_status=unknown
        token_detail="more than 100 organisation secrets are shared with this repository and only the first 100 were read; could not confirm '$want_secret'"
    else
        token_status=fail
        token_detail="no secret named '$want_secret'; GITHUB_TOKEN cannot read the Dependabot alerts API, so every indirect-dependency security PR will fail"
    fi

    jq -cn --arg r "$repo" \
        --arg ts "$token_status" --arg td "$token_detail" --arg tn "$want_secret" \
        --arg cs "$checks_status" --arg cd "$checks_detail" \
        --arg gs "$config_status" --arg gd "$config_detail" --arg mc "$manifest_count" \
        '{repo: $r}
         + (if $cs == "" then {} else {required_checks: {status: $cs, detail: $cd, source: "rest"}} end)
         + (if $gs == "" then {} else
              {dependabot_config: {status: $gs, detail: $gd, source: "rest",
                                   manifest_count: (if $mc == "" then null else ($mc | tonumber) end)}}
            end)
         + (if $ts == "" then {} else
              {alerts_token: {status: $ts, detail: $td, source: "rest", secret: $tn}}
            end)'
}

phase_narrow() {
    : >"$WORK/narrow.jsonl"

    # Undecided means: no ruleset status-check rule, and no classic rule
    # visible in the bulk sweep. Everything else was already answered for free.
    # Every in-scope repo is probed, because the alerts-token check applies to
    # all of them. The probe decides which of its three REST questions a given
    # repo actually needs, so one the bulk sweep already answered stays cheap.
    #
    # The scope matches the in_scope rule in assemble, so a repo brought in by
    # --include-archived or --include-forks is probed like any other.
    jq -r --argjson ia "$INCLUDE_ARCHIVED" --argjson ifk "$INCLUDE_FORKS" --argjson iaf "$INCLUDE_ADVISORY_FORKS" '
        select(.isDisabled != true)
        | select($ia or .isArchived != true)
        | select($ifk or .isFork != true)
        | select($iaf or (.nameWithOwner | test("-ghsa-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}$") | not))
        | .nameWithOwner
    ' "$WORK/nodes.jsonl" | sort -u >"$WORK/todo"

    local count
    count=$(wc -l <"$WORK/todo" | tr -d ' ')
    [[ $count -gt 0 ]] || return 0

    mkdir -p "$WORK/probes"
    # The worker is a fresh process that only receives --probe-repo, so every
    # setting its REST calls depend on has to travel by environment.
    export AUDIT_WORK="$WORK"
    export AUDIT_CACHE_TTL="$CACHE_TTL"
    export AUDIT_NO_CACHE="$NO_CACHE"
    export AUDIT_RATE_FLOOR="$RATE_FLOOR"
    export AUDIT_ALERTS_TOKEN_SECRET="$ALERTS_TOKEN_SECRET"

    if [[ $JOBS -le 1 ]]; then
        local r
        while read -r r; do
            braked && break
            probe_repo "$r" >>"$WORK/narrow.jsonl"
        done <"$WORK/todo"
    else
        # Each worker writes its own file rather than stdout: a record can
        # exceed PIPE_BUF, and interleaved stdout writes are not atomic.
        # The parent concatenates in sorted order, so --jobs never changes
        # the output bytes.
        # A worker that fails leaves no record. The summary counts those as
        # unprobed and the run fails, so its stderr is kept for diagnosis.
        xargs -P "$JOBS" -n 1 "$SELF" --probe-repo <"$WORK/todo" >/dev/null 2>>"$WORK/probe-errors.log" || true
        cat "$WORK"/probes/*.json 2>/dev/null >>"$WORK/narrow.jsonl" || true
    fi
}

# --- assembly -----------------------------------------------------------------

assemble() {
    local expect_ref=$ASSEMBLE_EXPECT_REF
    jq -c -n \
        --slurpfile nodes "$WORK/nodes.jsonl" \
        --slurpfile narrow "$WORK/narrow.jsonl" \
        --slurpfile errs "$WORK/errors.jsonl" \
        --slurpfile teams_in "$WORK/teams.json" \
        --slurpfile activity_in "$WORK/activity.json" \
        --arg merge_method "$MERGE_METHOD" \
        --arg ft "$FAST_TRACK_LABEL" \
        --arg pend "$PENDING_LABEL" \
        --arg sirt "$REVIEW_LABEL" \
        --arg expect_ref "$expect_ref" \
        --argjson include_archived "$INCLUDE_ARCHIVED" \
        --argjson include_forks "$INCLUDE_FORKS" \
        --argjson include_advisory_forks "$INCLUDE_ADVISORY_FORKS" \
        --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '
        # Read from files rather than passed as arguments: on a large org
        # either one outgrows the 128 KB Linux allows a single argument.
        $teams_in[0] as $teams
        | $activity_in[0] as $activity
        | def narrow_for($repo): ($narrow | map(select(.repo == $repo)) | first);
        def err_fields($repo): ($errs | map(select(.repo == $repo) | .field) | unique);

        def has_label($set; $want):
            (($set.nodes // []) | map(.name | ascii_downcase) | index($want | ascii_downcase)) != null;

        def label_entry($set; $want):
            (($set.nodes // []) | map(select((.name | ascii_downcase) == ($want | ascii_downcase))) | first);

        # Merge method the repo must allow for the configured --merge-method.
        def merge_allowed($n):
            if   $merge_method == "squash" then $n.squashMergeAllowed
            elif $merge_method == "merge"  then $n.mergeCommitAllowed
            else $n.rebaseMergeAllowed end;

        def manifests($n):
            (($n.root.entries // []) | map(select(.type == "blob") | .name));

        def has_manifest($n):
            (manifests($n) | any(. == "package.json" or . == "composer.json"));

        # Caller workflow. Refuse to reason about a shape we cannot see, and
        # name the refusal, rather than calling an unparsed file broken.
        def caller_shape($t):
            if   ($t | test("\\t"))            then "unrecognized: tab indentation"
            elif ($t | test("(^|\\n)\\s*\\S+\\s*:\\s*&\\S"))  then "unrecognized: yaml anchor"
            elif ($t | test("(^|\\n)\\s*<<\\s*:"))            then "unrecognized: merge key"
            elif (($t | [match("(^|\\n)---"; "g")] | length) > 1) then "unrecognized: multiple documents"
            else "recognized" end;

        def caller_info($n):
            ($n.caller.text // "") as $t
            | if ($n.caller == null) then {present: false}
              else
                (caller_shape($t)) as $shape
                | ($t | capture("dependabot-auto-merge\\.yml@(?<ref>[0-9A-Za-z._-]+)") // {}) as $m
                | ($t | capture("dependabot-auto-merge\\.yml@[0-9A-Za-z._-]+\\s*#\\s*(?<v>[A-Za-z0-9._-]+)") // {}) as $vc
                | {
                    present: true,
                    shape: $shape,
                    ref: ($m.ref // null),
                    ref_kind: (if ($m.ref // "") | test("^[0-9a-f]{40}$") then "sha" else "tag" end),
                    version_comment: ($vc.v // null),
                    ref_is_expected: (if $expect_ref == "" then null else ($m.ref == $expect_ref) end),
                    triggers: {
                      pull_request_target: ($t | test("(^|\\n)\\s*pull_request_target\\s*:")),
                      schedule: ($t | test("(^|\\n)\\s*schedule\\s*:")),
                      has_labeled: ($t | test("types\\s*:\\s*\\[[^\\]]*labeled"))
                    },
                    permissions: {
                      # Both the workflow-level and job-level blocks must carry
                      # every permission, so each must appear at least twice.
                      complete: (
                        ([$t | match("pull-requests\\s*:\\s*write"; "g")] | length >= 2) and
                        ([$t | match("contents\\s*:\\s*write"; "g")] | length >= 2) and
                        ([$t | match("security-events\\s*:\\s*read"; "g")] | length >= 2)
                      )
                    }
                  }
              end;

        def check($status; $detail; $source): {status: $status, detail: $detail, source: $source};

        def days_since($ts):
            if $ts == null then null
            else ((now - ($ts | fromdateiso8601)) / 86400 | floor) end;

        [ $nodes
          | to_entries[]
          | .value as $n
          | select($n != null)
          | ($n.nameWithOwner) as $repo
          | err_fields($repo) as $errfields
          | ($n.viewerPermission // "READ") as $perm
          | (["ADMIN","MAINTAIN","WRITE"] | index($perm)) as $write_access
          | ($write_access != null) as $trusted
          | narrow_for($repo) as $nr_early
          | (has_manifest($n)
             or (($nr_early.dependabot_config.manifest_count // 0) > 0)) as $manifest
          | (($n.depYml != null) or ($n.depYaml != null)) as $any_config
          | ($manifest or $any_config) as $applicable
          | (($n.defaultBranchRef.rules.nodes // [])
              | map(select(.type == "REQUIRED_STATUS_CHECKS"))) as $rsc
          | ($n.defaultBranchRef.branchProtectionRule) as $bpr
          | narrow_for($repo) as $nr

          # GitHub creates a private repo per security advisory when a
          # temporary private fork is opened, named <repo>-ghsa-xxxx-xxxx-xxxx.
          # The API does not mark them as forks, so they survive the fork
          # filter and land in rollout waves as if they were real repos.
          | ($repo | test("-ghsa-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}$")) as $advisory_fork

          | {
              schema_version: 1,
              audited_at: $audited_at,
              repo: $repo,
              default_branch: ($n.defaultBranchRef.name // null),
              scope: {
                in_scope: ((($include_archived or ($n.isArchived | not)))
                           and (($include_forks or ($n.isFork | not)))
                           and ($include_advisory_forks or ($advisory_fork | not))
                           and ($n.isDisabled | not)),
                advisory_fork: $advisory_fork,
                archived: $n.isArchived, fork: $n.isFork, disabled: $n.isDisabled,
                empty: $n.isEmpty, visibility: (if $n.isPrivate then "PRIVATE" else "PUBLIC" end)
              },
              access: {viewer_permission: $perm, write_access: $trusted},
              sweep_incomplete: (($n.sweep_incomplete // false) == true),
              owner: ($teams[$repo] // {team: null, source: "unmapped", candidates: []}),
              ecosystems: {
                npm: (manifests($n) | any(. == "package.json")),
                composer: (manifests($n) | any(. == "composer.json")),
                manifests: (manifests($n) | map(select(
                    . == "package.json" or . == "composer.json" or
                    . == "package-lock.json" or . == "yarn.lock" or
                    . == "pnpm-lock.yaml" or . == "composer.lock")))
              },
              checks: {
                auto_merge: (
                  if ($errfields | index("autoMergeAllowed")) then
                    check("unknown"; "your token cannot see the auto-merge setting"; "graphql_error")
                  elif $n.autoMergeAllowed then check("pass"; "Allow auto-merge is enabled"; "graphql")
                  else check("fail"; "Allow auto-merge is disabled (Settings > General > Pull Requests)"; "graphql")
                  end),

                required_checks: (
                  if ($rsc | length) > 0 then
                    ($rsc | first) as $r
                    | ($r.parameters.requiredStatusChecks // []) as $ctx
                    | check("pass";
                        "ruleset \($r.repositoryRuleset.name // "?") requires \($ctx | length) check(s)";
                        "graphql")
                      + {contexts: ($ctx | map(.context)), path: "ruleset"}
                  elif ($bpr != null and $bpr.requiresStatusChecks == true) then
                    check("pass"; "classic branch protection requires status checks"; "graphql")
                      + {contexts: ($bpr.requiredStatusCheckContexts // []), path: "classic"}
                  elif ($nr.required_checks != null) then
                    check($nr.required_checks.status; $nr.required_checks.detail; "rest") + {path: "classic"}
                  elif ($n.defaultBranchRef == null) then
                    check("unknown"; "repository has no default branch"; "graphql")
                  else
                    check("unknown"; "required status checks could not be determined"; "graphql")
                  end),

                labels: (
                  [{want: $ft, set: $n.ft}, {want: $pend, set: $n.pend}, {want: $sirt, set: $n.sirt}] as $wanted
                  | ($wanted | map(select(has_label(.set; .want) | not) | .want)) as $missing
                  | if ($n.ft == null and $n.pend == null and $n.sirt == null) then
                      check("unknown"; "labels could not be read"; "graphql_error")
                    elif ($missing | length) == 0 then
                      check("pass"; "all three labels exist"; "graphql")
                    else
                      check("fail"; "missing label(s): \($missing | join(", "))"; "graphql")
                        + {missing: $missing}
                    end),

                vuln_alerts: (
                  if ($errfields | index("hasVulnerabilityAlertsEnabled")) then
                    check("unknown"; "your token cannot see the vulnerability alerts setting"; "graphql_error")
                  elif $n.hasVulnerabilityAlertsEnabled then
                    check("pass"; "Dependabot vulnerability alerts are enabled"; "graphql")
                  else
                    check("fail"; "Dependabot vulnerability alerts are disabled (Settings > Advanced Security)"; "graphql")
                  end),

                dependabot_config: (
                  if ($n.depYml != null) then
                    check("pass"; ".github/dependabot.yml present (\($n.depYml.byteSize) bytes)"; "graphql")
                  elif ($n.depYaml != null) then
                    check("fail"; ".github/dependabot.yaml present but Dependabot only reads .yml — rename it"; "graphql")
                  elif ($nr.dependabot_config != null) then
                    check($nr.dependabot_config.status; $nr.dependabot_config.detail; "rest")
                  else
                    # The probe answers this for every repo without a config,
                    # so no answer means it never ran here: the rate brake,
                    # a failed worker, or a repo outside the probe scope. Not
                    # finding a manifest in the root says nothing about the
                    # subdirectories, so this is unknown, never na.
                    check("unknown"; "this repository was not probed, so nested manifests were not looked for"; "graphql")
                  end),

                caller_workflow: (
                  caller_info($n) as $c
                  | if ($c.present | not) then
                      check("na"; "not adopted yet; this is the step the audit exists to plan"; "graphql")
                    elif ($c.shape != "recognized") then
                      check("unknown"; "caller workflow \($c.shape) — not parsed, check it by hand"; "graphql")
                    else
                      ([ (if $c.ref_kind != "sha" then "pinned to \($c.ref) rather than a commit SHA" else empty end),
                         (if ($c.triggers.pull_request_target | not) then "no pull_request_target trigger" else empty end),
                         (if ($c.triggers.schedule | not) then "no schedule trigger, so the age gate never fires" else empty end),
                         (if ($c.triggers.has_labeled | not) then "types: is missing `labeled`, so fast-track cannot work" else empty end),
                         (if ($c.permissions.complete | not) then "permissions incomplete in the workflow-level or job-level block" else empty end)
                       ]) as $problems
                      | if ($problems | length) == 0 then
                          check("pass"; "pinned \($c.ref) \(if $c.version_comment then "(# \($c.version_comment))" else "" end)"; "graphql")
                        else
                          check("fail"; ($problems | join("; ")); "graphql")
                        end
                    end),

                alerts_token: (
                  if ($nr.alerts_token == null) then
                    check("unknown"; "the alerts-token secret was not checked"; "rest")
                  else
                    check($nr.alerts_token.status; $nr.alerts_token.detail; "rest")
                      + {secret: $nr.alerts_token.secret}
                  end),

                merge_method: (
                  if (merge_allowed($n) == null) then
                    check("unknown"; "your token cannot see the merge settings"; "graphql_error")
                  elif merge_allowed($n) then
                    check("pass"; "\($merge_method) merging is allowed"; "graphql")
                  else
                    check("fail"; "\($merge_method) merging is disabled, so `gh pr merge --auto --\($merge_method)` will fail"; "graphql")
                  end)
              },

              caller: caller_info($n),

              risks: ([
                ($rsc | first | select(. != null) | select(.parameters.strictRequiredStatusChecksPolicy == true)
                  | {id: "strict_required_status_checks", severity: "high",
                     detail: "ruleset \(.repositoryRuleset.name // "?") sets strict required status checks; queued Dependabot PRs will loop on update-branch"}),
                ($rsc | first | select(. != null) | select((.parameters.requiredStatusChecks // []) | length == 0)
                  | {id: "checks_rule_enforces_nothing", severity: "medium",
                     detail: "a required-status-checks rule exists with no contexts, so it enforces nothing"}),
                ($rsc | first | select(. != null) | select(.repositoryRuleset.enforcement != null and .repositoryRuleset.enforcement != "ACTIVE")
                  | {id: "ruleset_not_active", severity: "high",
                     detail: "ruleset \(.repositoryRuleset.name // "?") is in \(.repositoryRuleset.enforcement) mode and enforces nothing"}),
                (($n.defaultBranchRef.rules.nodes // [])[]
                  | select(.type == "PULL_REQUEST")
                  | select((.parameters.requiredApprovingReviewCount // 0) > 0)
                  | {id: "approval_rule", severity: "high",
                     detail: "the default branch requires \(.parameters.requiredApprovingReviewCount) approval(s); a queued bot PR will wait indefinitely"}),
                ($bpr | select(. != null) | select((.requiredApprovingReviewCount // 0) > 0)
                  | {id: "approval_rule", severity: "high",
                     detail: "classic protection requires \(.requiredApprovingReviewCount) approval(s); a queued bot PR will wait indefinitely"}),
                (select($trusted and $n.hasVulnerabilityAlertsEnabled == true and ($n.everAlerts.totalCount // 0) == 0 and $manifest)
                  | {id: "alerts_enabled_no_alerts_ever", severity: "medium",
                     detail: "alerts are on but none have ever been raised; a stub or unresolvable lockfile silences Dependabot exactly like this"}),
                # Colours must stay in sync with the LABELS array in scripts/bootstrap.sh.
                ([{want: $ft, set: $n.ft, color: "0075ca"},
                  {want: $pend, set: $n.pend, color: "e4e669"},
                  {want: $sirt, set: $n.sirt, color: "d93f0b"}]
                  | map(label_entry(.set; .want) as $e | select($e != null and $e.color != .color) | .want)
                  | select(length > 0)
                  | {id: "label_drift", severity: "low",
                     detail: "label colour differs from the documented default: \(join(", "))"})
              ] | map(select(. != null))),

              activity: {
                pushed_at: $n.pushedAt,
                days_since_push: days_since($n.pushedAt),
                commits: ($n.defaultBranchRef.target.history.totalCount // null),
                latest_release: ($n.latestRelease.publishedAt // null),
                open_dependabot_prs: ($activity[$repo] // 0),
                open_alerts: ($n.openAlerts.totalCount // 0),
                alerts_ever: ($n.everAlerts.totalCount // 0),
                alert_counts_trusted: $trusted
              }
            }

          # A placeholder node carries nulls, and a null boolean is falsy, so
          # every GraphQL-derived check would read `fail` for a repository the
          # sweep never returned. Only what the REST probe found is real here,
          # so the rest go back to unknown before blockers are derived.
          | (if .sweep_incomplete then
               .checks |= with_entries(
                 if (.value.source // "" | startswith("graphql"))
                 then .value = {status: "unknown",
                                detail: "the sweep never returned this repository, so nothing could be read",
                                source: "sweep_incomplete"}
                 else . end)
             else . end)

          # Verdict, in this order so `unknown` can never be laundered into `fail`.
          | . as $rec
          | ([$rec.checks | to_entries[] | select(.value.status == "fail") | .key]) as $blockers
          | ([$rec.checks | to_entries[] | select(.value.status == "unknown") | .key]) as $unknowns
          # bootstrap.sh fixes these four. The alerts token is deliberately not
          # among them: it is one central secret, not per-repo work.
          | (["auto_merge", "labels", "vuln_alerts", "required_checks"]) as $bootstrappable
          | $rec + {
              adoption: (
                if ($rec.caller.present | not) then "not-adopted"
                elif $rec.checks.caller_workflow.status == "unknown" then "unparsed"
                elif $rec.checks.caller_workflow.status == "fail" then "adopted-broken"
                else "adopted" end),
              blockers: $blockers,
              unknowns: $unknowns,
              remediation: {
                bootstrap_fixes: ($blockers | map(select(. as $b | $bootstrappable | index($b)))),
                needs_work: ($blockers | map(select(. as $b | $bootstrappable | index($b) | not)))
              },
              # Applicability is decided first, because a repo with no
              # dependencies should not be reported as blocked on labels. But
              # "no manifest found" and "could not read the file tree" are not
              # the same answer, and calling the second one not-applicable
              # would quietly drop a repo we never managed to look at.
              verdict: (
                if $rec.sweep_incomplete then "unknown"
                elif (($applicable | not) and ($rec.checks.dependabot_config.status == "unknown")) then "unknown"
                elif ($applicable | not) then "na"
                elif ($blockers | length) > 0 then "blocked"
                elif ($unknowns | length) > 0 then "unknown"
                else "ready" end),
              preflight: {
                verdict: (
                  [$rec.checks.auto_merge.status, $rec.checks.required_checks.status] as $p
                  | if ($p | index("fail")) then "fail"
                    elif ($p | index("unknown")) then "warn"
                    else "pass" end)
              }
            }

          # Wave band. Low score first: quiet repos with few gaps lead the
          # rollout, busy monorepos bring up the rear.
          | . as $rec
          | (
              (if $rec.activity.alert_counts_trusted and $rec.activity.open_alerts > 0 then 12 else 0 end)
              + (if ($rec.risks | map(.id) | index("alerts_enabled_no_alerts_ever")) then 10 else 0 end)
              + (if ($rec.risks | map(.id) | index("strict_required_status_checks")) then 8 else 0 end)
              + (if ($rec.risks | map(.id) | index("approval_rule")) then 6 else 0 end)
              + (if $rec.checks.required_checks.status == "fail" then 10 else 0 end)
            ) as $risk
          | (
              (25 - ((($rec.activity.days_since_push // 365) / 365) | if . > 1 then 1 else . end) * 25 | floor)
              + (if ($rec.activity.commits // 0) > 5000 then 10 else 0 end)
              + (if ($rec.activity.latest_release != null and days_since($rec.activity.latest_release) < 90) then 5 else 0 end)
            ) as $activity_score
          | (($rec.blockers | length) * 4) as $effort
          | ($risk + $activity_score + $effort) as $score
          | $rec + {
              wave: {
                score: $score,
                confidence: (if $rec.activity.alert_counts_trusted then "high" else "low" end),
                inputs: {risk: $risk, activity: $activity_score, effort: $effort}
              }
            }
        ]
        | map(select(.scope.in_scope))

        # Bands are quantiles of this run, not absolute scores. A small pilot
        # first, then widening waves. `score` is the stable number; `band` only
        # means anything relative to the other repos in the same run.
        | . as $recs
        | ($recs | map(select(.verdict != "na") | .wave.score) | sort) as $sorted
        | ($sorted | length) as $n
        | (if $n == 0 then 0 else $sorted[((($n - 1) * 10) / 100) | floor] end) as $t1
        | (if $n == 0 then 0 else $sorted[((($n - 1) * 40) / 100) | floor] end) as $t2
        | (if $n == 0 then 0 else $sorted[((($n - 1) * 75) / 100) | floor] end) as $t3
        | $recs
        | map(.wave.band = (
              if .verdict == "na" then null
              elif .wave.score <= $t1 then 1
              elif .wave.score <= $t2 then 2
              elif .wave.score <= $t3 then 3
              else 4 end))
        | sort_by(.wave.score, .repo)
        | .[]
        '
}

# --- rendering ----------------------------------------------------------------

apply_filters() {
    jq -c \
        --argjson teams "$(printf '%s\n' "$FILTER_TEAMS" | jq -R 'split(" ") | map(select(length > 0))')" \
        --argjson statuses "$(printf '%s\n' "$FILTER_STATUS" | jq -R 'split(" ") | map(select(length > 0))')" \
        --argjson waves "$(printf '%s\n' "$FILTER_WAVE" | jq -R 'split(" ") | map(select(length > 0) | tonumber)')" \
        --argjson need_config "$HAS_DEPENDABOT_CONFIG" \
        '
        . as $r
        | select(($teams | length) == 0 or ($teams | index($r.owner.team // "")) != null)
        | select(($statuses | length) == 0 or ($statuses | index($r.verdict)) != null)
        | select(($waves | length) == 0 or ($waves | index($r.wave.band)) != null)
        | select(($need_config | not) or ($r.checks.dependabot_config.status == "pass"))
        '
}

render_table() {
    # A not-applicable repo still has settings that are technically missing, but
    # listing them implies work that does not need doing: Dependabot has nothing
    # to scan there. Say that instead, or the longest column in the report is
    # made of findings nobody should act on.
    jq -r '
        [.repo,
         .verdict,
         (.owner.team // "(unassigned)"),
         (if .wave.band == null then "-" else ("w" + (.wave.band | tostring)) end),
         (if .verdict == "na" then "no dependencies to scan"
          elif (.blockers | length) > 0 then (.blockers | join(","))
          elif (.unknowns | length) > 0 then ("?" + (.unknowns | join(",")))
          else "-" end)]
        | @tsv
    ' | {
        printf '%-58s %-8s %-22s %-4s %s\n' "REPOSITORY" "VERDICT" "TEAM" "WAVE" "BLOCKERS"
        while IFS=$'\t' read -r repo verdict team wave blockers; do
            printf '%-58s %-8s %-22s %-4s %s\n' "$repo" "$verdict" "$team" "$wave" "$blockers"
        done
    }
}

render_team() {
    jq -s -r '
        group_by(.owner.team // "(unassigned)")
        | sort_by(.[0].owner.team // "zzz")
        | .[]
        | ("\n## " + (.[0].owner.team // "(unassigned)")
           + "  (" + (length | tostring) + " repos, "
           + (map(select(.verdict == "ready")) | length | tostring) + " ready)"),
          (.[] | "  " + (.verdict | (. + "        ")[0:8]) + "  w" + (.wave.band | tostring) + "  " + .repo
                 + (if (.blockers | length) > 0 then "  [" + (.blockers | join(", ")) + "]" else "" end))
    '
}

render_summary() {
    jq -s -r '
        . as $all
        | "Repositories audited: \($all | length)",
          "",
          "  ready    \($all | map(select(.verdict == "ready")) | length)",
          "  blocked  \($all | map(select(.verdict == "blocked")) | length)",
          "  unknown  \($all | map(select(.verdict == "unknown")) | length)",
          "  n/a      \($all | map(select(.verdict == "na")) | length)",
          "",
          "Ownership:",
          ($all | group_by(.owner.source) | sort_by(-length) | .[]
                | "  \(length | tostring | (. + "    ")[0:4]) \(.[0].owner.source)"),
          "",
          "Adoption:",
          ($all | group_by(.adoption) | sort_by(-length) | .[]
                | "  \(length | tostring | (. + "    ")[0:4]) \(.[0].adoption)"),
          "",
          # The alerts token is one central secret, not per-repo work, so
          # counting it as work makes this number 0 everywhere and useless.
          # Report both: what a team can finish alone, and what it can finish
          # once the token is in place centrally.
          "  bootstrap.sh finishes           \($all | map(select(.verdict == "blocked" and (.remediation.needs_work | length) == 0)) | length)",
          "  bootstrap.sh plus the token     \($all | map(select(.verdict == "blocked" and ((.remediation.needs_work - ["alerts_token"]) | length) == 0)) | length)",
          "",
          "Most common blockers:",
          ($all | map(.blockers[]) | group_by(.) | map({k: .[0], n: length})
                | sort_by(-.n) | .[] | "  \(.n | tostring | (. + "    ")[0:4]) \(.k)"),
          "",
          "Risks:",
          ($all | map(.risks[].id) | group_by(.) | map({k: .[0], n: length})
                | sort_by(-.n) | .[] | "  \(.n | tostring | (. + "    ")[0:4]) \(.k)"),
          "",
          "Wave bands (roll out lowest first; n/a repos are excluded):",
          ($all | map(select(.wave.band != null)) | group_by(.wave.band) | .[]
                | "  band \(.[0].wave.band)  \(length) repos")
    '
}

render_csv() {
    printf 'repo,verdict,team,wave_band,wave_score,auto_merge,required_checks,labels,vuln_alerts,dependabot_config,caller_workflow,merge_method,blockers,risks\n'
    jq -r '
        [.repo, .verdict, (.owner.team // ""), .wave.band, .wave.score,
         .checks.auto_merge.status, .checks.required_checks.status, .checks.labels.status,
         .checks.vuln_alerts.status, .checks.dependabot_config.status,
         .checks.caller_workflow.status, .checks.merge_method.status,
         (.blockers | join(" ")), (.risks | map(.id) | join(" "))]
        | @csv
    '
}

render() {
    local src=$1 fmt
    for fmt in $FORMATS; do
        case $fmt in
            jsonl)   cat "$src" ;;
            table)   apply_filters <"$src" | render_table ;;
            team)    apply_filters <"$src" | render_team ;;
            summary) apply_filters <"$src" | render_summary ;;
            csv)     apply_filters <"$src" | render_csv ;;
        esac
        printf '\n'
    done
}

# --- main ---------------------------------------------------------------------

ORG=""
REPOS=()
INCLUDE_ARCHIVED=false
INCLUDE_FORKS=false
INCLUDE_ADVISORY_FORKS=false
HAS_DEPENDABOT_CONFIG=false
FILTER_TEAMS=""
FILTER_STATUS=""
FILTER_WAVE=""
MERGE_METHOD="squash"
FAST_TRACK_LABEL="security-fast-track"
PENDING_LABEL="auto-merge-pending"
REVIEW_LABEL="sirt-review-required"
EXPECT_REF=""
ALERTS_TOKEN_SECRET="QUALITYOPS_DEPENDABOT_ALERTS_TOKEN"
TEAM_OVERRIDES=""
EXCLUDE_TEAMS="$DEFAULT_EXCLUDE_TEAMS"
MAX_TEAM_SIZE="25%"
MAX_OWNER_CANDIDATES=3
FORMATS=""
OUT_DIR=".audit"
FROM_JSONL=""
EXPLAIN_OWNERS=false
EXIT_CODE=false
JOBS=8
CACHE_TTL="1h"
NO_CACHE=false
RATE_FLOOR=200
# Measured against woocommerce with the full field set: first:15 returns
# cleanly, first:20 returns a degraded 200 carrying no nodes, first:25 returns 502.
PAGE_SIZE=15
PROBE_REPO=""

need_value() {
    [[ $2 -ge 2 ]] || die_usage "$1 needs a value"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --probe-repo)
            need_value "$1" $#
            PROBE_REPO=$2
            shift 2
            ;;
        --org)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--org needs a value, got option '$2' — use --org=<login>"
            ORG=$2; shift 2 ;;
        --org=*) ORG=${1#--org=}; [[ -n $ORG ]] || die_usage "--org needs a value"; shift ;;
        --repo)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--repo needs a value, got option '$2' — use --repo=<owner/repo>"
            REPOS+=("$2"); shift 2 ;;
        --repo=*) REPOS+=("${1#--repo=}"); shift ;;
        --include-archived) INCLUDE_ARCHIVED=true; shift ;;
        --include-forks) INCLUDE_FORKS=true; shift ;;
        --include-advisory-forks) INCLUDE_ADVISORY_FORKS=true; shift ;;
        --has-dependabot-config) HAS_DEPENDABOT_CONFIG=true; shift ;;
        --team)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--team needs a value, got option '$2' — use --team=<slug>"
            FILTER_TEAMS="$FILTER_TEAMS $2"; shift 2 ;;
        --team=*) FILTER_TEAMS="$FILTER_TEAMS ${1#--team=}"; shift ;;
        --status)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--status needs a value, got option '$2' — use --status=<s>"
            FILTER_STATUS="$FILTER_STATUS $2"; shift 2 ;;
        --status=*) FILTER_STATUS="$FILTER_STATUS ${1#--status=}"; shift ;;
        --wave)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--wave needs a value, got option '$2' — use --wave=<n>"
            FILTER_WAVE="$FILTER_WAVE $2"; shift 2 ;;
        --wave=*) FILTER_WAVE="$FILTER_WAVE ${1#--wave=}"; shift ;;
        --merge-method)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--merge-method needs a value, got option '$2'"
            MERGE_METHOD=$2; shift 2 ;;
        --merge-method=*) MERGE_METHOD=${1#--merge-method=}; shift ;;
        --fast-track-label)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--fast-track-label needs a value, got option '$2' — use --fast-track-label='$2'"
            FAST_TRACK_LABEL=$2; shift 2 ;;
        --fast-track-label=*) FAST_TRACK_LABEL=${1#--fast-track-label=}; shift ;;
        --pending-label)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--pending-label needs a value, got option '$2' — use --pending-label='$2'"
            PENDING_LABEL=$2; shift 2 ;;
        --pending-label=*) PENDING_LABEL=${1#--pending-label=}; shift ;;
        --review-label)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--review-label needs a value, got option '$2' — use --review-label='$2'"
            REVIEW_LABEL=$2; shift 2 ;;
        --review-label=*) REVIEW_LABEL=${1#--review-label=}; shift ;;
        --expect-ref)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--expect-ref needs a value, got option '$2'"
            EXPECT_REF=$2; shift 2 ;;
        --expect-ref=*) EXPECT_REF=${1#--expect-ref=}; shift ;;
        --alerts-token-secret)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--alerts-token-secret needs a value, got option '$2'"
            ALERTS_TOKEN_SECRET=$2; shift 2 ;;
        --alerts-token-secret=*) ALERTS_TOKEN_SECRET=${1#--alerts-token-secret=}; shift ;;
        --team-overrides)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--team-overrides needs a value, got option '$2'"
            TEAM_OVERRIDES=$2; shift 2 ;;
        --team-overrides=*) TEAM_OVERRIDES=${1#--team-overrides=}; shift ;;
        --exclude-team)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--exclude-team needs a value, got option '$2'"
            EXCLUDE_TEAMS="$EXCLUDE_TEAMS $2"; shift 2 ;;
        --exclude-team=*) EXCLUDE_TEAMS="$EXCLUDE_TEAMS ${1#--exclude-team=}"; shift ;;
        --max-team-size)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--max-team-size needs a value, got option '$2'"
            MAX_TEAM_SIZE=$2; shift 2 ;;
        --max-team-size=*) MAX_TEAM_SIZE=${1#--max-team-size=}; shift ;;
        --max-owner-candidates)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--max-owner-candidates needs a value, got option '$2'"
            MAX_OWNER_CANDIDATES=$2; shift 2 ;;
        --max-owner-candidates=*) MAX_OWNER_CANDIDATES=${1#--max-owner-candidates=}; shift ;;
        --format)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--format needs a value, got option '$2'"
            FORMATS="$FORMATS $2"; shift 2 ;;
        --format=*) FORMATS="$FORMATS ${1#--format=}"; shift ;;
        --out-dir)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--out-dir needs a value, got option '$2'"
            OUT_DIR=$2; shift 2 ;;
        --out-dir=*) OUT_DIR=${1#--out-dir=}; shift ;;
        --from-jsonl)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--from-jsonl needs a value, got option '$2'"
            FROM_JSONL=$2; shift 2 ;;
        --from-jsonl=*) FROM_JSONL=${1#--from-jsonl=}; shift ;;
        --explain-owners) EXPLAIN_OWNERS=true; shift ;;
        --exit-code) EXIT_CODE=true; shift ;;
        --jobs)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--jobs needs a value, got option '$2'"
            JOBS=$2; shift 2 ;;
        --jobs=*) JOBS=${1#--jobs=}; shift ;;
        --cache-ttl)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--cache-ttl needs a value, got option '$2'"
            CACHE_TTL=$2; shift 2 ;;
        --cache-ttl=*) CACHE_TTL=${1#--cache-ttl=}; shift ;;
        --no-cache) NO_CACHE=true; shift ;;
        --rate-floor)
            need_value "$1" $#
            [[ $2 != -* ]] || die_usage "--rate-floor needs a value, got option '$2'"
            RATE_FLOOR=$2; shift 2 ;;
        --rate-floor=*) RATE_FLOOR=${1#--rate-floor=}; shift ;;
        -*) die_usage "unknown option: $1" ;;
        *)  die_usage "unexpected argument: $1" ;;
    esac
done

# The concurrent worker. Runs before any other validation so it stays cheap,
# and writes to its own file because a record can exceed PIPE_BUF.
if [[ -n $PROBE_REPO ]]; then
    : "${AUDIT_WORK:?--probe-repo is internal and needs AUDIT_WORK}"
    WORK=$AUDIT_WORK
    CACHE_TTL=${AUDIT_CACHE_TTL:-$CACHE_TTL}
    NO_CACHE=${AUDIT_NO_CACHE:-$NO_CACHE}
    RATE_FLOOR=${AUDIT_RATE_FLOOR:-$RATE_FLOOR}
    ALERTS_TOKEN_SECRET=${AUDIT_ALERTS_TOKEN_SECRET:-$ALERTS_TOKEN_SECRET}
    braked && exit 75
    probe_repo "$PROBE_REPO" >"$WORK/probes/$(printf '%s' "$PROBE_REPO" | tr -c 'A-Za-z0-9' '_').json"
    exit 0
fi

[[ -n $FORMATS ]] || FORMATS="table"
for f in $FORMATS; do
    case $f in
        jsonl | table | team | summary | csv) ;;
        *) die_usage "invalid --format '$f' — expected jsonl, table, team, summary or csv" ;;
    esac
done
for s in $FILTER_STATUS; do
    case $s in
        ready | blocked | unknown | na) ;;
        *) die_usage "invalid --status '$s' — expected ready, blocked, unknown or na" ;;
    esac
done
for w in $FILTER_WAVE; do
    [[ $w =~ ^[1-4]$ ]] || die_usage "invalid --wave '$w' — expected 1, 2, 3 or 4"
done
case $MERGE_METHOD in
    squash | merge | rebase) ;;
    *) die_usage "invalid --merge-method '$MERGE_METHOD' — expected squash, merge or rebase" ;;
esac
[[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 && $JOBS -le 16 ]] ||
    die_usage "invalid --jobs '$JOBS' — expected an integer between 1 and 16"
[[ $RATE_FLOOR =~ ^[0-9]+$ ]] || die_usage "invalid --rate-floor '$RATE_FLOOR' — expected an integer"
[[ $MAX_TEAM_SIZE =~ ^[0-9]+%?$ ]] || die_usage "invalid --max-team-size '$MAX_TEAM_SIZE' — expected a number or a percentage"
[[ $MAX_OWNER_CANDIDATES =~ ^[0-9]+$ ]] || die_usage "invalid --max-owner-candidates '$MAX_OWNER_CANDIDATES' — expected an integer"

# --- re-render path: issues no API call at all --------------------------------

if [[ -n $FROM_JSONL ]]; then
    [[ -f $FROM_JSONL ]] || die 2 "no such file: $FROM_JSONL"
    render "$FROM_JSONL"
    if [[ $EXIT_CODE == true ]] && jq -e -s 'any(.verdict == "blocked")' <"$FROM_JSONL" >/dev/null; then
        exit 1
    fi
    exit 0
fi

if [[ -n $ORG && ${#REPOS[@]} -gt 0 ]]; then
    die_usage "--org and --repo are mutually exclusive"
fi
if [[ -z $ORG && ${#REPOS[@]} -eq 0 ]]; then
    die_usage "missing required argument: --org <org> or --repo <owner/repo>"
fi
# Strict charsets so gh api can't expand a literal '{owner}/{repo}' (or other
# placeholder text) into a different repository from GH_REPO/the current checkout.
for r in "${REPOS[@]:-}"; do
    [[ -z $r ]] && continue
    [[ $r =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$ ]] ||
        die_usage "invalid repository '$r' — expected owner/repo"
done
if [[ -n $ORG ]]; then
    [[ $ORG =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
        die_usage "invalid organisation '$ORG'"
fi

if [[ -z $TEAM_OVERRIDES ]]; then
    default_overrides="$(cd "$(dirname "$SELF")" && pwd)/audit-team-overrides.tsv"
    [[ -f $default_overrides ]] && TEAM_OVERRIDES=$default_overrides
fi

preflight

WORK=$(mktemp -d)
WORK_OWNED=true
: >"$WORK/nodes.jsonl"
: >"$WORK/errors.jsonl"
: >"$WORK/narrow.jsonl"
printf '{}' >"$WORK/teams.json"
printf '{}' >"$WORK/activity.json"

if [[ -n $ORG ]]; then
    printf 'Auditing %s\n' "$ORG"
else
    printf 'Auditing %d repositor%s\n' "${#REPOS[@]}" "$([[ ${#REPOS[@]} -eq 1 ]] && printf 'y' || printf 'ies')"
fi

phase_repos
phase_reconcile
phase_teams
phase_activity
phase_narrow

ASSEMBLE_EXPECT_REF=$EXPECT_REF
mkdir -p "$OUT_DIR"
assemble >"$OUT_DIR/repos.jsonl"

RECORDS=$(wc -l <"$OUT_DIR/repos.jsonl" | tr -d ' ')
# Every repo in todo should have a probe record. Counted whether or not the
# brake tripped, because a worker can also fail without leaving one.
UNPROBED=$(comm -23 <(sort -u "$WORK/todo" 2>/dev/null) \
    <(jq -r '.repo' "$WORK/narrow.jsonl" 2>/dev/null | sort -u) | grep -c . || true)

jq -n \
    --arg org "$ORG" \
    --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson records "$RECORDS" \
    --argjson unprobed "$UNPROBED" \
    --argjson expected "$(cat "$WORK/total-count" 2>/dev/null || echo null)" \
    --argjson swept "$(cat "$WORK/received-count" 2>/dev/null || echo null)" \
    --argjson sweep_missing "$(cat "$WORK/missing-count" 2>/dev/null || echo 0)" \
    --argjson braked "$(braked && echo true || echo false)" \
    --arg page_size "$PAGE_SIZE" \
    '{org: $org, audited_at: $audited_at, records: $records,
      rate_limited: $braked, unprobed: $unprobed, page_size: ($page_size | tonumber),
      org_total: $expected, swept: $swept, sweep_missing: $sweep_missing}' \
    >"$OUT_DIR/run.json"

printf '\n'
render "$OUT_DIR/repos.jsonl"
printf 'Wrote %s/repos.jsonl (%s records) and %s/run.json\n' "$OUT_DIR" "$RECORDS" "$OUT_DIR"

if braked; then
    printf 'rate limit floor reached — %d repositories were not probed; re-run to complete them\n' "$UNPROBED" >&2
    exit 1
fi

if [[ $UNPROBED -gt 0 ]]; then
    cp "$WORK/probe-errors.log" "$OUT_DIR/probe-errors.log" 2>/dev/null || : >"$OUT_DIR/probe-errors.log"
    printf '%d repositories could not be probed and are reported unknown; worker errors are in %s/probe-errors.log\n' \
        "$UNPROBED" "$OUT_DIR" >&2
    exit 1
fi

if [[ $EXIT_CODE == true ]] && jq -e -s 'any(.verdict == "blocked")' <"$OUT_DIR/repos.jsonl" >/dev/null; then
    exit 1
fi
exit 0
