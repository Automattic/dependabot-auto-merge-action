# dependabot-auto-merge-action

A reusable GitHub Actions workflow that automatically merges Dependabot security PRs after they clear a set of configurable gates.

## Gates

| # | Gate | Default | Notes |
|---|------|---------|-------|
| 1 | Security advisory (GHSA ID) | required | PR must be a security fix, not a routine bump. Falls back to Dependabot Alerts API for indirect deps. |
| 2 | CVSS severity | ≥ 7.0 | High or critical. Configurable via `cvss-threshold`. A zero-like or out-of-range score means GitHub has no usable CVSS data, so the PR goes to human review instead. |
| 3 | Compatibility score | ≥ 80% | Direct deps only; indirect deps skip this gate since fetch-metadata can't provide a score. |
| 4 | Age gate | 7 days | Scheduled job merges passing PRs after `age-days` days. |

PRs that fail any gate are labelled `sirt-review-required` (or your custom label) and routed for human review. A `security-fast-track` label on any PR bypasses all gates immediately. When a PR is fast-tracked, a one-time audit comment is posted recording who applied the label, when, and a link to the workflow run.

`sirt-review-required` and `auto-merge-pending` are mutually exclusive workflow states: every evaluation applies one and removes the other, so a re-evaluated PR — say after Dependabot rewrites the branch — never carries both.

## Usage

### 1. Create the caller workflow in your repo

```yaml
# .github/workflows/dependabot-auto-merge.yml
name: Dependabot auto-merge

on:
    pull_request_target:
        types: [opened, synchronize, reopened, labeled]
    schedule:
        - cron: '0 9 * * *'

permissions:
    pull-requests: write
    contents: write
    security-events: read

jobs:
    dependabot-auto-merge:
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@<sha> # v1.6
        permissions:
            pull-requests: write
            contents: write
            security-events: read
        with:
            event-name: ${{ github.event_name }}
```

Pin to the commit SHA a release tag points at, with the tag in a trailing comment — the same way this repo pins third-party actions. Tags name releases; they are not pinning targets, and none of them float. Resolve the SHA with:

```bash
gh api repos/Automattic/dependabot-auto-merge-action/commits/v1.6 --jq .sha
```

That's it. All inputs have defaults that match the original P2 configuration, so no extra config is needed unless you want to customize behaviour.

### 2. Bootstrap the repo prerequisites

[`scripts/bootstrap.sh`](scripts/bootstrap.sh) configures everything else the workflow needs — auto-merge allowed, a required status check on the default branch, the three labels, and Dependabot vulnerability alerts. Every step is idempotent: re-runs are safe and report what is already correct.

```bash
./scripts/bootstrap.sh owner/repo --required-check "your-check-name" --dry-run
./scripts/bootstrap.sh owner/repo --required-check "your-check-name"
```

Start with `--dry-run` — it prints every mutation (method, path, payload) without executing anything.

The script uses the gh CLI's credentials (`gh auth login` or `GH_TOKEN`). `GH_TOKEN`/`GITHUB_TOKEN` apply to github.com and ghe.com; for GitHub Enterprise Server set `GH_HOST` and `GH_ENTERPRISE_TOKEN` (or `GITHUB_ENTERPRISE_TOKEN`). Settings mutations need administrative access to the target repo. Two token types work.

A fine-grained PAT needs the repo role **admin**, plus:

| Permission | Level | Used for |
|------------|-------|----------|
| Administration | Read & write | Auto-merge setting, rulesets, vulnerability alerts |
| Contents | Read & write | Reading merge-related settings such as `allow_auto_merge` |
| Issues | Read & write | Labels |
| Metadata | Read | Implied by the above |

A GitHub App installation token (`GH_TOKEN=ghs_...`) carries no repo role. GitHub reports `permissions.admin: false` even for a fully capable app. Grant the app:

| Permission | Level | Used for |
|------------|-------|----------|
| Administration | Read & write | Auto-merge setting, rulesets, vulnerability alerts |
| Contents | Read & write | Reading merge-related settings such as `allow_auto_merge` |
| Pull requests | Read & write | Labels, confirmed sufficient in production; Issues was not granted |
| Metadata | Read | Implied by the above |

Preflight only confirms a token can view repo settings. It can't confirm Administration write for either token type, because no read-only check reliably proves it. `permissions.admin` reports a repo role that GitHub App installation tokens don't have at all, so it's `false` even for a fully capable app. A probe against `vulnerability-alerts` doesn't work either. That endpoint returns a 404 both when alerts are genuinely disabled and when the token simply lacks access, confirmed live against a repo we don't administer. On GitHub Enterprise Server it 404s for every token while Dependabot is disabled instance-wide, regardless of role. And even a clean success only proves Administration read, not write, so an app granted read-only access would still pass and then fail on every write call. `gh` CLI, `terraform-provider-github`, and `create-pull-request` all handle this the same way. They skip the probe and let each step's own mutating call refuse with its real error. A token that lacks write access fails at the first admin-scoped step with a clear 403, not at preflight.

`--required-check` must match the check-run name exactly as it appears on a PR's Checks tab (for GitHub Actions, the job's name). To list check names on a recent commit: `gh api --paginate repos/OWNER/REPO/commits/COMMIT_SHA/check-runs --jq '.check_runs[].name'`. If the default branch already has required status checks (ruleset or classic branch protection), the script leaves them alone.

If you use custom label names (see the inputs below), create those labels manually instead — the script only manages the default set. The manual equivalents of each step follow.

### 3. Create the required labels (manual alternative)

The workflow needs three labels to exist in your repo. Create them once:

```bash
gh label create "security-fast-track" --color "0075ca" --description "Bypass all gates and enable auto-merge immediately"
gh label create "auto-merge-pending"  --color "e4e669" --description "Passed all gates; awaiting age gate"
gh label create "sirt-review-required" --color "d93f0b" --description "Requires human security review"
```

### 4. Enable auto-merge on the repo (manual alternative)

Auto-merge must be allowed in your repo settings:

> **Settings → General → Pull Requests → Allow auto-merge** ✓

The workflow's preflight job verifies this at runtime and fails with an error pointing back here if it's disabled.

### 5. Branch protection (manual alternative)

Your default branch needs a branch protection rule (or ruleset) with at least one required status check. Without it, GitHub won't queue an auto-merge.

Prefer a **ruleset** (Settings → Rules → Rulesets): the preflight job can fully verify ruleset-based required status checks with the default `GITHUB_TOKEN`. Classic branch protection details are only readable by admin tokens, so with classic protection the preflight can confirm the branch is protected but only warns that it cannot verify the checks themselves. If neither is configured, preflight fails with an error pointing back here. (`scripts/bootstrap.sh` creates a ruleset, so bootstrapped repos are fully verifiable by preflight.)

Dependabot vulnerability alerts must also be enabled (**Settings → Advanced Security**) — the Gate 1 fallback queries the Dependabot Alerts API for indirect dependencies and for unscored advisories on direct ones.

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `event-name` | string | **required** | Pass `${{ github.event_name }}` — routes jobs to the correct trigger. |
| `cvss-threshold` | string | `'7.0'` | Minimum CVSS score for Gate 2. Float string, e.g. `'6.5'`. |
| `compatibility-threshold` | number | `80` | Minimum compatibility score % for Gate 3 (direct deps only). |
| `age-days` | number | `7` | Days a PR must be open before the scheduled job merges it. |
| `merge-method` | string | `'squash'` | `squash`, `merge`, or `rebase`. |
| `fast-track-label` | string | `'security-fast-track'` | Label that bypasses all gates. |
| `review-label` | string | `'sirt-review-required'` | Label applied when a PR fails a gate. |
| `pending-label` | string | `'auto-merge-pending'` | Label applied when a PR passes all gates and is waiting for the age gate. |
| `review-team` | string | `''` | Optional. GitHub team slug (`org/team`) @-mentioned in review-required comments. |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `token` | No | Token used to call the Dependabot alerts API (Gate 1 fallback). Defaults to `GITHUB_TOKEN`. Pass a PAT or fine-grained token when `GITHUB_TOKEN` lacks `security-events: read` access — common in orgs with restricted default permissions. |

## Customisation examples

Lower the CVSS threshold and shorten the age gate:

```yaml
with:
    event-name: ${{ github.event_name }}
    cvss-threshold: '6.5'
    age-days: 3
```

Use a different merge method and tag a review team:

```yaml
with:
    event-name: ${{ github.event_name }}
    merge-method: 'merge'
    review-team: 'my-org/security-team'
```

Use custom label names:

```yaml
with:
    event-name: ${{ github.event_name }}
    fast-track-label: 'fast-track'
    review-label: 'needs-security-review'
    pending-label: 'dependabot-approved'
```

## Permissions

The calling job must declare:

```yaml
permissions:
    pull-requests: write   # label and comment on PRs
    contents: write        # enable auto-merge
    security-events: read  # read Dependabot alerts API
```

These are the minimum required. If your repo uses a restrictive default permissions policy, set them explicitly on the job as shown in the usage example above.

### When GITHUB_TOKEN returns 403 on the Dependabot alerts API

Some organisations restrict `GITHUB_TOKEN` so it cannot read security events, even when `security-events: read` is declared. What a 403 does then depends on why the API was called:

- **Indirect dependency** — the API is the only advisory source, so the Gate 1 fallback step fails the job.
- **Direct dependency with an unscored advisory** — the API call is a best-effort attempt to recover a real score, so a 403 only logs a warning and the PR goes to human review, exactly as if the API had never been consulted. The job stays green.

The fix for both is to create a PAT (or a fine-grained token with **Security events → Read** on the target repo) and pass it as a secret:

```yaml
jobs:
    dependabot-auto-merge:
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@<sha> # v1.6
        permissions:
            pull-requests: write
            contents: write
            security-events: read
        with:
            event-name: ${{ github.event_name }}
        secrets:
            token: ${{ secrets.DEPENDABOT_ALERTS_TOKEN }}
```

Store the PAT as a repository or organisation secret named `DEPENDABOT_ALERTS_TOKEN` (or any name you prefer) and reference it in `secrets.token`.

## Troubleshooting

### A PR was routed for review with "advisory metadata (CVSS) was unavailable"

GitHub sometimes returns `0.0` as the CVSS score for a matched advisory. That is not a severity rating — it means the advisory carries no CVSS v3 vector, usually because it was published recently and has not been scored yet. Branch rewrites can also rematch a PR against a newer, unscored advisory.

The workflow treats as missing metadata every zero-like score — empty, `0`, `0.0`, `00`, `.00` — every value it cannot parse as a number, and anything above `10`. From v1.6 it first tries to recover a real score: an unscored advisory on a direct dependency sends the PR through the Dependabot alerts API, which often holds a score for the same advisory before it reaches PR metadata. Only that advisory counts, never another open alert on the same package. Only when that finds nothing better — no open alert for the advisory, or the call failed (a 403 from a restricted `GITHUB_TOKEN`, typically; expect one warning annotation per such PR) — does the PR fail closed: it gets `review-label` and a comment naming the score GitHub reported, where there was one. It never reads `0.0` as "below the threshold", because that would describe an unscored advisory as a safe one. Failing closed ships from v1.5 (v1.4 and earlier described an unscored advisory as below-threshold); the recovery attempt ships from v1.6.

What to do: check the advisory yourself. If it is a real high-severity fix, apply the `fast-track-label` to merge it; the workflow records who did so in an audit comment. Nothing re-evaluates a PR when an advisory is scored later — the gates only re-run on a new PR event, so a stalled PR needs either the fast-track label or a push.

### A PR carries both `auto-merge-pending` and `sirt-review-required`

The labels are mutually exclusive states, and from v1.6 the workflow enforces that: routing to review removes the pending label, marking pending removes the review label, and the scheduled merge skips any PR carrying the review label even if a stale pending label survives. Callers pinned at the v1.5 SHA or earlier get none of this — a PR that passed the gates and later failed them (a branch rewrite rematching different advisories, typically) keeps both labels, and their scheduled job treats it as an auto-merge candidate. Remove the stale pending label by hand and re-pin.

## How it works

### `preflight` job (runs first on both triggers)

Verifies the repo is actually configured for auto-merge before either merge path runs, and fails fast with actionable errors instead of letting `gh pr merge --auto` fail late (or silently never queue). Two checks:

1. **"Allow auto-merge" is enabled** on the repo. Disabled → the job fails with an error pointing at the setting.
2. **The default branch has required status checks** — ruleset-based checks are verified first; if none, the job falls back to classic branch protection. No ruleset checks and no protection rule → the job fails.

Two cases warn and continue instead of failing, because the condition is unverifiable rather than known-bad:

- The token cannot see the "Allow auto-merge" setting (it's only returned to tokens with push access).
- The branch has classic protection, but the token cannot read its details (the endpoint requires admin — the standard `GITHUB_TOKEN` limitation). Migrating to rulesets makes this fully verifiable.

A red preflight is intentional: it surfaces a repo where auto-merge could never have worked. It adds roughly 10–20 seconds of runner spin-up per Dependabot event.

### `evaluate-pr` job (triggers on `pull_request_target`)

Runs on every opened/updated/labelled Dependabot PR, after preflight passes:

1. **Fast-track check** — if the `fast-track-label` is present, enable auto-merge immediately, post a one-time audit comment (label applier, UTC timestamp, workflow-run link), and exit. The comment is deduplicated via a hidden HTML marker, so repeated PR events never re-post it.
2. **Gate 1** — use `dependabot/fetch-metadata` to extract the GHSA ID and CVSS. The Dependabot Alerts API is consulted as a fallback in two cases: the GHSA ID is missing (indirect dep — fetch-metadata cannot embed advisory data for those), or it is present but the CVSS is unusable (unscored advisory — the API may hold a real score for it). Open security alerts are matched against the updated packages, and on the direct-dep path against the GHSA ID the PR fixes as well, so a package with several open alerts cannot lend a score from a vulnerability this PR leaves in place.
3. **Resolve the effective CVSS** — prefer the fetch-metadata score, then the alerts-API score. A score that is empty, non-numeric, numerically zero (`0`, `0.0`, `00`, `.00`), or above `10` is treated as missing metadata: the PR skips Gate 2 and goes straight to `review-label`, and the comment names the score GitHub reported.
4. **Gate 2** — require CVSS ≥ `cvss-threshold`.
5. **Gate 3** — require compatibility score ≥ `compatibility-threshold`% (skipped for indirect deps).
6. Apply `review-label` and remove `pending-label` if any gate fails; apply `pending-label` and remove `review-label` if all pass. The two labels are mutually exclusive states — a re-evaluated PR always ends up with exactly one.

### `scheduled-merge` job (triggers on `schedule`)

Runs on the cron you define in the caller, after preflight passes. Finds open PRs labelled `pending-label` that are older than `age-days` days and enables auto-merge on each — excluding any that also carry `review-label`, so a stale pending label can never put a human-review PR back in the merge set. That exclusion ignores case, matching how Actions, `gh pr edit` and `gh pr list --label` compare labels, so a `review-label` input whose casing differs from the repository label still excludes the PR.

## Security notes

- The workflow only acts on PRs authored by `app/dependabot`.
- The fast-track path leaves an audit comment on the PR, so gate bypasses are attributable after the fact.
- The `pull_request_target` trigger gives the workflow write access to the base repo; acting on trusted bot authors only is the standard mitigation.
- `security-events: read` is required to call the Dependabot Alerts API — for indirect dependency lookups, and to recover a real score for unscored advisories on direct ones.
