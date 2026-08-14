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
                           no required status checks exist yet. Use the
                           --required-check=<name> form for names that begin
                           with a dash.
  --dry-run                Print every mutation (method, path, payload) without
                           executing anything. Read-only calls still run, so the
                           output matches what a real run would decide.
  -h, --help               Show this help.

Authentication:
  Uses the gh CLI's credentials (gh auth login, or the GH_TOKEN env var).
  GH_TOKEN/GITHUB_TOKEN apply to github.com and ghe.com; for GitHub Enterprise
  Server set GH_HOST and GH_ENTERPRISE_TOKEN (or GITHUB_ENTERPRISE_TOKEN).
  Settings mutations need administrative access to the target repo. Two token
  types work:

  - A fine-grained PAT with the repo role admin, and:
      - Administration: Read & write   (auto-merge setting, rulesets, vulnerability alerts)
      - Contents: Read & write         (reading merge-related settings such as allow_auto_merge)
      - Issues: Read & write           (labels — a 403 in the labels step means this is missing)
      - Metadata: Read                 (implied by the above)

  - A GitHub App installation token (GH_TOKEN=ghs_...). App tokens carry no
    repo role — GitHub reports permissions.admin: false even for a fully
    capable app, so preflight checks administration access directly instead
    (see the source). Grant the app:
      - Administration: Read & write
      - Contents: Read & write
      - Pull requests: Read & write    (confirmed sufficient for labels in
                                         production; Issues was not granted)
      - Metadata: Read

Finding the exact check name:
  The required check must match the check-run name exactly as it appears on a
  PR's Checks tab (for GitHub Actions, the job's name). To list check names on
  a recent commit:
    gh api --paginate repos/OWNER/REPO/commits/COMMIT_SHA/check-runs --jq '.check_runs[].name'
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
            # The formatter is cosmetic — its failure must not hide the payload
            # (the whole point of dry-run), so fall back to the raw JSON.
            local pretty
            if pretty=$(jq . <<<"$payload" | sed 's/^/     /'); then
                printf '%s\n' "$pretty"
            else
                printf '     %s\n' "$payload"
            fi
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

    local err full_name
    if ! REPO_JSON=$(gh api "repos/$REPO" 2>&1); then
        err=$REPO_JSON
        die 2 "cannot read repos/$REPO: $(head -c 300 <<<"$err")"
    fi

    # A renamed or transferred repo redirects, so the response can describe a
    # different repository than the one named on the command line. Refuse to
    # mutate anything unless they match (owner/repo names are case-insensitive).
    full_name=$(jq -r '.full_name' <<<"$REPO_JSON")
    # tr rather than ${var,,}: macOS ships bash 3.2, which lacks case expansion.
    if [[ $(tr '[:upper:]' '[:lower:]' <<<"$full_name") != "$(tr '[:upper:]' '[:lower:]' <<<"$REPO")" ]]; then
        die 2 "repos/$REPO resolved to '$full_name' (renamed or transferred?) — re-run with the canonical name"
    fi

    DEFAULT_BRANCH=$(jq -r '.default_branch' <<<"$REPO_JSON")
    # Branch names may contain URL-significant characters ('#' starts a
    # fragment); encode once for use as a path segment in branch endpoints.
    ENC_BRANCH=$(jq -rn --arg s "$DEFAULT_BRANCH" '$s | @uri')

    # allow_auto_merge is only present in the response when the token can view
    # merge-related settings (Contents: Read & write on a fine-grained PAT);
    # PATs return no scope headers, so probing the response shape is the only
    # reliable capability check before we start mutating.
    if [[ $(jq 'has("allow_auto_merge")' <<<"$REPO_JSON") != true ]]; then
        die 2 "token cannot view merge settings on $REPO — it needs Contents: Read & write (see --help)"
    fi

    # .permissions reports the token owner's repo role, which only user tokens
    # have: a GitHub App installation token gets the map rendered all-false
    # even when the app holds Administration: write. When the role probe
    # fails, prove administration access directly against an endpoint gated on
    # Administration read — vulnerability-alerts answers 204/404 to tokens
    # that hold it and 403 to everything else. A token that slips past this
    # gate still fails per-step with a clear message.
    if [[ $(jq '.permissions.admin == true' <<<"$REPO_JSON") != true ]]; then
        local alerts_probe
        if ! alerts_probe=$(gh api "repos/$REPO/vulnerability-alerts" 2>&1) &&
            ! grep -q "HTTP 404" <<<"$alerts_probe"; then
            die 2 "token lacks admin access to $REPO — a fine-grained PAT needs Administration: Read & write, a GitHub App installation token an app with the same permission (see --help)"
        fi
    fi
}

# --- steps --------------------------------------------------------------------

step_auto_merge() {
    # Capture and guard: a failed jq must not fall through to the "disabled"
    # branch and PATCH the repo on the strength of a parse error.
    local enabled
    if ! enabled=$(jq -r '.allow_auto_merge' <<<"$REPO_JSON"); then
        fail "allow auto-merge: cannot parse repository settings"
        return 1
    fi
    if [[ $enabled == true ]]; then
        ok "allow auto-merge: already enabled"
    else
        mutate "allow auto-merge: enable" PATCH "repos/$REPO" '{"allow_auto_merge":true}'
    fi
}

step_ruleset() {
    local branch_rules classic_out ruleset_checks="" classic_checks="" existing payload names

    # Aggregated rules from all *active* rulesets that apply to the default
    # branch (the rulesets list endpoint omits each ruleset's rules array).
    # --paginate: the endpoint returns 30 rules per page by default.
    if ! branch_rules=$(gh api --paginate "repos/$REPO/rules/branches/$ENC_BRANCH" 2>&1); then
        fail "required checks: cannot read rules for branch '$DEFAULT_BRANCH': $(head -c 300 <<<"$branch_rules")"
        return 1
    fi
    # jq applies the filter to each page's array, so --paginate output parses as-is.
    ruleset_checks=$(jq -r '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' <<<"$branch_rules") || {
        fail "required checks: cannot parse rules for branch '$DEFAULT_BRANCH'"
        return 1
    }

    # Classic branch protection: 200 = required checks configured, 404 = branch not protected.
    if classic_out=$(gh api "repos/$REPO/branches/$ENC_BRANCH/protection/required_status_checks" 2>&1); then
        classic_checks=$(jq -r '([.checks[]?.context] + (.contexts // [])) | unique | .[]' <<<"$classic_out") || {
            fail "required checks: cannot parse classic branch protection"
            return 1
        }
    elif ! grep -q "HTTP 404" <<<"$classic_out"; then
        fail "required checks: cannot read classic branch protection: $(head -c 300 <<<"$classic_out")"
        return 1
    fi

    existing=$(printf '%s\n%s\n' "$ruleset_checks" "$classic_checks" | sed '/^$/d' | sort -u) || {
        fail "required checks: cannot merge check lists"
        return 1
    }

    if [[ -n $existing ]]; then
        names=$(paste -sd, - <<<"$existing" | sed 's/,/, /g') || names=$existing
        ok "required checks: already present on '$DEFAULT_BRANCH' ($names) — leaving existing protection alone"
        if [[ -n $REQUIRED_CHECK ]] && ! grep -Fxq -- "$REQUIRED_CHECK" <<<"$existing"; then
            note "named check '$REQUIRED_CHECK' is not among the existing required checks; existing protection was not modified"
        fi
        return 0
    fi

    # A ruleset with our name may exist but not be enforcing anything (e.g.
    # enforcement: disabled — such rulesets don't appear in the branch rules
    # above). Creating another one with the same name would fail, so surface it.
    local existing_names
    # includes_parents=false: org-level rulesets are listed by default and
    # could shadow-match our repo-level ruleset name.
    if ! existing_names=$(gh api --paginate "repos/$REPO/rulesets?includes_parents=false" --jq '.[].name' 2>&1); then
        fail "required checks: cannot list rulesets: $(head -c 300 <<<"$existing_names")"
        return 1
    fi
    if grep -Fxq -- "$RULESET_NAME" <<<"$existing_names"; then
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
    }') || {
        fail "required checks: cannot build ruleset payload"
        return 1
    }
    mutate "ruleset: create '$RULESET_NAME' requiring check '$REQUIRED_CHECK' on the default branch" \
        POST "repos/$REPO/rulesets" "$payload"
}

step_labels() {
    local rc=0 entry name color desc enc cur cur_color cur_desc payload
    for entry in "${LABELS[@]}"; do
        IFS='|' read -r name color desc <<<"$entry"
        enc=$(jq -rn --arg s "$name" '$s | @uri') || {
            fail "label '$name': cannot encode name"
            rc=1
            continue
        }
        if cur=$(gh api "repos/$REPO/labels/$enc" 2>&1); then
            if ! cur_color=$(jq -r '.color // "" | ascii_downcase' <<<"$cur") ||
                ! cur_desc=$(jq -r '.description // ""' <<<"$cur"); then
                fail "label '$name': cannot parse existing label"
                rc=1
                continue
            fi
            if [[ $cur_color == "$color" && $cur_desc == "$desc" ]]; then
                ok "label '$name': already correct"
            else
                payload=$(jq -n --arg color "$color" --arg desc "$desc" '{color: $color, description: $desc}') || {
                    fail "label '$name': cannot build update payload"
                    rc=1
                    continue
                }
                mutate "label '$name': update color/description" PATCH "repos/$REPO/labels/$enc" "$payload" || rc=1
            fi
        elif grep -q "HTTP 404" <<<"$cur"; then
            payload=$(jq -n --arg name "$name" --arg color "$color" --arg desc "$desc" \
                '{name: $name, color: $color, description: $desc}') || {
                fail "label '$name': cannot build create payload"
                rc=1
                continue
            }
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
            # An option-like next token is almost always a forgotten value
            # (e.g. --required-check --dry-run would silently disable dry-run).
            [[ $2 != -* ]] || die_usage "--required-check needs a value, got option '$2' — use --required-check='$2' for a check name that begins with a dash"
            [[ -n $2 ]] || die_usage "--required-check needs a value"
            REQUIRED_CHECK=$2
            shift 2
            ;;
        --required-check=*)
            REQUIRED_CHECK=${1#--required-check=}
            [[ -n $REQUIRED_CHECK ]] || die_usage "--required-check needs a value"
            shift
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
# Strict charsets so gh api can't expand a literal '{owner}/{repo}' (or other
# placeholder text) into a different repository from GH_REPO/the current checkout.
[[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$ ]] ||
    die_usage "invalid repository '$REPO' — expected owner/repo"

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
