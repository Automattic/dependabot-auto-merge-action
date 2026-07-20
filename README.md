# dependabot-auto-merge-action

A reusable GitHub Actions workflow that automatically merges Dependabot security PRs after they clear a set of configurable gates.

## Gates

| # | Gate | Default | Notes |
|---|------|---------|-------|
| 1 | Security advisory (GHSA ID) | required | PR must be a security fix, not a routine bump. Falls back to Dependabot Alerts API for indirect deps. |
| 2 | CVSS severity | ≥ 7.0 | High or critical. Configurable via `cvss-threshold`. |
| 3 | Compatibility score | ≥ 80% | Direct deps only; indirect deps skip this gate since fetch-metadata can't provide a score. |
| 4 | Age gate | 7 days | Scheduled job merges passing PRs after `age-days` days. |

PRs that fail any gate are labelled `sirt-review-required` (or your custom label) and routed for human review. A `security-fast-track` label on any PR bypasses all gates immediately. When a PR is fast-tracked, a one-time audit comment is posted recording who applied the label, when, and a link to the workflow run.

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
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@v1
        permissions:
            pull-requests: write
            contents: write
            security-events: read
        with:
            event-name: ${{ github.event_name }}
```

That's it. All inputs have defaults that match the original P2 configuration, so no extra config is needed unless you want to customize behaviour.

### 2. Bootstrap the repo prerequisites

[`scripts/bootstrap.sh`](scripts/bootstrap.sh) configures everything else the workflow needs — auto-merge allowed, a required status check on the default branch, the three labels, and Dependabot vulnerability alerts. Every step is idempotent: re-runs are safe and report what is already correct.

```bash
./scripts/bootstrap.sh owner/repo --required-check "your-check-name" --dry-run
./scripts/bootstrap.sh owner/repo --required-check "your-check-name"
```

Start with `--dry-run` — it prints every mutation (method, path, payload) without executing anything.

The script uses the gh CLI's credentials (`gh auth login` or `GH_TOKEN`). Settings mutations need an **admin** role on the target repo; a fine-grained PAT scoped to the repo needs:

| Permission | Level | Used for |
|------------|-------|----------|
| Administration | Read & write | Auto-merge setting, rulesets, vulnerability alerts |
| Issues | Read & write | Labels |
| Metadata | Read | Implied by the above |

`--required-check` must match the check-run name exactly as it appears on a PR's Checks tab (for GitHub Actions, the job's name). To list check names on a recent commit: `gh api repos/OWNER/REPO/commits/COMMIT_SHA/check-runs --jq '.check_runs[].name'`. If the default branch already has required status checks (ruleset or classic branch protection), the script leaves them alone.

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

Dependabot vulnerability alerts must also be enabled (**Settings → Advanced Security**) — the Gate 1 fallback for indirect dependencies queries the Dependabot Alerts API.

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
| `token` | No | Token used to call the Dependabot alerts API (Gate 1 fallback for indirect deps). Defaults to `GITHUB_TOKEN`. Pass a PAT or fine-grained token when `GITHUB_TOKEN` lacks `security-events: read` access — common in orgs with restricted default permissions. |

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

Some organisations restrict `GITHUB_TOKEN` so it cannot read security events, even when `security-events: read` is declared. In that case the Gate 1 fallback step will fail with a 403. The fix is to create a PAT (or a fine-grained token with **Security events → Read** on the target repo) and pass it as a secret:

```yaml
jobs:
    dependabot-auto-merge:
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@v1
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
2. **Gate 1** — use `dependabot/fetch-metadata` to extract the GHSA ID. If missing (indirect dep), fall back to the Dependabot Alerts API and match open security alerts against the updated packages.
3. **Gate 2** — require CVSS ≥ `cvss-threshold`.
4. **Gate 3** — require compatibility score ≥ `compatibility-threshold`% (skipped for indirect deps).
5. Apply `review-label` if any gate fails; apply `pending-label` if all pass.

### `scheduled-merge` job (triggers on `schedule`)

Runs on the cron you define in the caller, after preflight passes. Finds open PRs labelled `pending-label` that are older than `age-days` days and enables auto-merge on each.

## Security notes

- The workflow only acts on PRs authored by `app/dependabot`.
- The fast-track path leaves an audit comment on the PR, so gate bypasses are attributable after the fact.
- The `pull_request_target` trigger gives the workflow write access to the base repo; acting on trusted bot authors only is the standard mitigation.
- `security-events: read` is required to call the Dependabot Alerts API for indirect dependency lookups.
