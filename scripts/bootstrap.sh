#!/usr/bin/env bash
# Bootstrap a repository's prerequisites for the dependabot-auto-merge workflow.
# All steps are idempotent: re-runs report what is already correct and change nothing.
set -euo pipefail

RULESET_NAME="dependabot-auto-merge-required-checks"

# name|color|description — must stay in sync with the defaults documented in the README
LABELS=(
    "security-fast-track|0075ca|Bypass all gates and enable auto-merge immediately"
    "auto-merge-pending|e4e669|Passed all gates; awaiting age gate"
    "sirt-review-required|d93f0b|Requires human security review"
)

usage() {
    cat <<'EOF'
Usage: scripts/bootstrap.sh <owner/repo> [options]

Configure a repository's prerequisites for the dependabot-auto-merge reusable
workflow. Every step is idempotent — re-runs are safe and report what is
already correct.

Steps:
  1. Enable "Allow auto-merge" in the repo settings
  2. Ensure the default branch has a required status check
     (creates ruleset "dependabot-auto-merge-required-checks" only when no
     required checks exist and --required-check is given; existing branch
     protection or rulesets are never modified)
  3. Create or update the three labels the workflow depends on
  4. Enable Dependabot vulnerability alerts

Options:
  --required-check <name>  Check-run name to require on the default branch when
                           no required status checks exist yet.
  --dry-run                Print every mutation (method, path, payload) without
                           executing anything. Read-only calls still run, so the
                           output matches what a real run would decide.
  -h, --help               Show this help.

Authentication:
  Uses the gh CLI's credentials (gh auth login, or the GH_TOKEN env var).
  Settings mutations require an admin role on the target repo. A fine-grained
  PAT scoped to the repo needs:
    - Administration: Read & write   (auto-merge setting, rulesets, vulnerability alerts)
    - Issues: Read & write           (labels — a 403 in the labels step means this is missing)
    - Metadata: Read                 (implied by the above)

Finding the exact check name:
  The required check must match the check-run name exactly as it appears on a
  PR's Checks tab (for GitHub Actions, the job's name). To list check names on
  a recent commit:
    gh api repos/OWNER/REPO/commits/COMMIT_SHA/check-runs --jq '.check_runs[].name'
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

ok()      { printf '\342\234\223  %s\n' "$1"; COUNT_OK=$((COUNT_OK + 1)); }
would()   { printf '\342\206\222  %s\n' "$1"; COUNT_CHANGED=$((COUNT_CHANGED + 1)); }
changed() { printf '+  %s\n' "$1"; COUNT_CHANGED=$((COUNT_CHANGED + 1)); }
note()    { printf '!  %s\n' "$1"; COUNT_NOTES=$((COUNT_NOTES + 1)); }
fail()    { printf '\342\234\227  %s\n' "$1" >&2; COUNT_FAILED=$((COUNT_FAILED + 1)); }

# --- mutation funnel ----------------------------------------------------------

# mutate <description> <METHOD> <api-path> [json-payload]
# The ONLY place that reads DRY_RUN and the only place that issues a
# non-GET gh api call — steps must never call gh api -X directly.
mutate() {
    local desc=$1 method=$2 path=$3 payload=${4:-} err
    if [[ $DRY_RUN == true ]]; then
        would "$desc (dry-run)"
        printf '     gh api -X %s %s\n' "$method" "$path"
        if [[ -n $payload ]]; then
            jq . <<<"$payload" | sed 's/^/     /'
        fi
        return 0
    fi
    if [[ -n $payload ]]; then
        err=$(printf '%s' "$payload" | gh api -X "$method" "$path" --input - 2>&1 >/dev/null) || {
            fail "$desc: $(head -c 300 <<<"$err")"
            return 1
        }
    else
        err=$(gh api -X "$method" "$path" 2>&1 >/dev/null) || {
            fail "$desc: $(head -c 300 <<<"$err")"
            return 1
        }
    fi
    changed "$desc"
}

# --- preflight ----------------------------------------------------------------

preflight() {
    command -v gh >/dev/null 2>&1 || die 2 "gh not found — install it from https://cli.github.com"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found — install it from https://jqlang.org"
    # Scope to the target host: plain 'gh auth status' fails if ANY configured
    # host is unreachable, even when the relevant one is fine.
    gh auth status --hostname "${GH_HOST:-github.com}" >/dev/null 2>&1 ||
        die 2 "gh is not authenticated to ${GH_HOST:-github.com} — run 'gh auth login' or set GH_TOKEN"

    local err
    if ! REPO_JSON=$(gh api "repos/$REPO" 2>&1); then
        err=$REPO_JSON
        die 2 "cannot read repos/$REPO: $(head -c 300 <<<"$err")"
    fi
    DEFAULT_BRANCH=$(jq -r '.default_branch' <<<"$REPO_JSON")

    # allow_auto_merge is only present in the response when the token has admin
    # access; fine-grained PATs return no scope headers, so probing the response
    # shape is the only reliable admin check before we start mutating.
    if [[ $(jq 'has("allow_auto_merge")' <<<"$REPO_JSON") != true ]] ||
        [[ $(jq '.permissions.admin == true' <<<"$REPO_JSON") != true ]]; then
        die 2 "token lacks admin access to $REPO — a fine-grained PAT needs Administration: Read & write (see --help)"
    fi
}

# --- steps --------------------------------------------------------------------

step_auto_merge() {
    if [[ $(jq -r '.allow_auto_merge' <<<"$REPO_JSON") == true ]]; then
        ok "allow auto-merge: already enabled"
    else
        mutate "allow auto-merge: enable" PATCH "repos/$REPO" '{"allow_auto_merge":true}'
    fi
}

step_ruleset() {
    local branch_rules classic_out ruleset_checks="" classic_checks="" existing payload names

    # Aggregated rules from all *active* rulesets that apply to the default
    # branch (the rulesets list endpoint omits each ruleset's rules array).
    if ! branch_rules=$(gh api "repos/$REPO/rules/branches/$DEFAULT_BRANCH" 2>&1); then
        fail "required checks: cannot read rules for branch '$DEFAULT_BRANCH': $(head -c 300 <<<"$branch_rules")"
        return 1
    fi
    ruleset_checks=$(jq -r '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' <<<"$branch_rules")

    # Classic branch protection: 200 = required checks configured, 404 = branch not protected.
    if classic_out=$(gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection/required_status_checks" 2>&1); then
        classic_checks=$(jq -r '([.checks[]?.context] + (.contexts // [])) | unique | .[]' <<<"$classic_out")
    elif ! grep -q "HTTP 404" <<<"$classic_out"; then
        fail "required checks: cannot read classic branch protection: $(head -c 300 <<<"$classic_out")"
        return 1
    fi

    existing=$(printf '%s\n%s\n' "$ruleset_checks" "$classic_checks" | sed '/^$/d' | sort -u)

    if [[ -n $existing ]]; then
        names=$(paste -sd, - <<<"$existing" | sed 's/,/, /g')
        ok "required checks: already present on '$DEFAULT_BRANCH' ($names) — leaving existing protection alone"
        if [[ -n $REQUIRED_CHECK ]] && ! grep -Fxq "$REQUIRED_CHECK" <<<"$existing"; then
            note "named check '$REQUIRED_CHECK' is not among the existing required checks; existing protection was not modified"
        fi
        return 0
    fi

    # A ruleset with our name may exist but not be enforcing anything (e.g.
    # enforcement: disabled — such rulesets don't appear in the branch rules
    # above). Creating another one with the same name would fail, so surface it.
    local existing_names
    if ! existing_names=$(gh api --paginate "repos/$REPO/rulesets" --jq '.[].name' 2>&1); then
        fail "required checks: cannot list rulesets: $(head -c 300 <<<"$existing_names")"
        return 1
    fi
    if grep -Fxq "$RULESET_NAME" <<<"$existing_names"; then
        note "ruleset '$RULESET_NAME' already exists but enforces no required checks on '$DEFAULT_BRANCH' — fix or delete it manually"
        return 0
    fi

    if [[ -z $REQUIRED_CHECK ]]; then
        note "no required status checks on '$DEFAULT_BRANCH' and no --required-check given — GitHub will not queue auto-merge without one"
        return 0
    fi

    # strict_required_status_checks_policy stays false: "require branches to be
    # up to date" would force endless update-branch loops on queued PRs.
    # integration_id is omitted so the check counts regardless of which app
    # reports it.
    payload=$(jq -n --arg name "$RULESET_NAME" --arg ctx "$REQUIRED_CHECK" '{
        name: $name,
        target: "branch",
        enforcement: "active",
        conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
        rules: [{
            type: "required_status_checks",
            parameters: {
                strict_required_status_checks_policy: false,
                required_status_checks: [{ context: $ctx }]
            }
        }]
    }')
    mutate "ruleset: create '$RULESET_NAME' requiring check '$REQUIRED_CHECK' on the default branch" \
        POST "repos/$REPO/rulesets" "$payload"
}

step_labels() {
    local rc=0 entry name color desc enc cur cur_color cur_desc payload
    for entry in "${LABELS[@]}"; do
        IFS='|' read -r name color desc <<<"$entry"
        enc=$(jq -rn --arg s "$name" '$s | @uri')
        if cur=$(gh api "repos/$REPO/labels/$enc" 2>&1); then
            cur_color=$(jq -r '.color // "" | ascii_downcase' <<<"$cur")
            cur_desc=$(jq -r '.description // ""' <<<"$cur")
            if [[ $cur_color == "$color" && $cur_desc == "$desc" ]]; then
                ok "label '$name': already correct"
            else
                payload=$(jq -n --arg color "$color" --arg desc "$desc" '{color: $color, description: $desc}')
                mutate "label '$name': update color/description" PATCH "repos/$REPO/labels/$enc" "$payload" || rc=1
            fi
        elif grep -q "HTTP 404" <<<"$cur"; then
            payload=$(jq -n --arg name "$name" --arg color "$color" --arg desc "$desc" \
                '{name: $name, color: $color, description: $desc}')
            mutate "label '$name': create" POST "repos/$REPO/labels" "$payload" || rc=1
        else
            fail "label '$name': $(head -c 300 <<<"$cur")"
            rc=1
        fi
    done
    return "$rc"
}

step_vuln_alerts() {
    local out
    # 204 (gh exit 0) = enabled, 404 = disabled.
    if out=$(gh api "repos/$REPO/vulnerability-alerts" 2>&1); then
        ok "dependabot vulnerability alerts: already enabled"
    elif grep -q "HTTP 404" <<<"$out"; then
        mutate "dependabot vulnerability alerts: enable" PUT "repos/$REPO/vulnerability-alerts"
    else
        fail "dependabot vulnerability alerts: $(head -c 300 <<<"$out")"
        return 1
    fi
}

# --- main ---------------------------------------------------------------------

REPO=""
REQUIRED_CHECK=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help)
            usage
            exit 0
            ;;
        --required-check)
            [[ $# -ge 2 ]] || die_usage "--required-check needs a value"
            REQUIRED_CHECK=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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
[[ $REPO =~ ^[^/]+/[^/]+$ ]] || die_usage "invalid repository '$REPO' — expected owner/repo"

preflight

if [[ $DRY_RUN == true ]]; then
    printf 'Bootstrapping %s (dry-run — no mutations will be executed)\n\n' "$REPO"
else
    printf 'Bootstrapping %s\n\n' "$REPO"
fi

FAILED_STEPS=""
step_auto_merge || FAILED_STEPS="$FAILED_STEPS auto-merge"
step_ruleset || FAILED_STEPS="$FAILED_STEPS required-checks"
step_labels || FAILED_STEPS="$FAILED_STEPS labels"
step_vuln_alerts || FAILED_STEPS="$FAILED_STEPS vulnerability-alerts"

if [[ $DRY_RUN == true ]]; then
    CHANGED_LABEL="would change"
else
    CHANGED_LABEL="changed"
fi
printf '\nSummary: %d ok, %d %s, %d notes, %d failed\n' \
    "$COUNT_OK" "$COUNT_CHANGED" "$CHANGED_LABEL" "$COUNT_NOTES" "$COUNT_FAILED"

if [[ -n $FAILED_STEPS ]]; then
    printf 'Failed steps:%s\n' "$FAILED_STEPS" >&2
    exit 1
fi
