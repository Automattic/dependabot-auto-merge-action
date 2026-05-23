# dependabot-auto-merge-action

A reusable GitHub Actions workflow that automatically merges Dependabot security PRs after they clear a set of configurable gates.

## Gates

| # | Gate | Default | Notes |
|---|------|---------|-------|
| 1 | Security advisory (GHSA ID) | required | PR must be a security fix, not a routine bump. Falls back to Dependabot Alerts API for indirect deps. |
| 2 | CVSS severity | ≥ 7.0 | High or critical. Configurable via `cvss-threshold`. |
| 3 | Compatibility score | ≥ 80% | Direct deps only; indirect deps skip this gate since fetch-metadata can't provide a score. |
| 4 | Age gate | 7 days | Scheduled job merges passing PRs after `age-days` days. |

PRs that fail any gate are labelled `sirt-review-required` (or your custom label) and routed for human review. A `security-fast-track` label on any PR bypasses all gates immediately.

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
        uses: asahasrabuddhe/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@v1
        permissions:
            pull-requests: write
            contents: write
            security-events: read
        with:
            event-name: ${{ github.event_name }}
```

That's it. All inputs have defaults that match the original P2 configuration, so no extra config is needed unless you want to customize behaviour.

### 2. Create the required labels

The workflow needs three labels to exist in your repo. Create them once:

```bash
gh label create "security-fast-track" --color "0075ca" --description "Bypass all gates and enable auto-merge immediately"
gh label create "auto-merge-pending"  --color "e4e669" --description "Passed all gates; awaiting age gate"
gh label create "sirt-review-required" --color "d93f0b" --description "Requires human security review"
```

### 3. Enable auto-merge on the repo

Auto-merge must be allowed in your repo settings:

> **Settings → General → Pull Requests → Allow auto-merge** ✓

### 4. Branch protection

Your default branch needs a branch protection rule (or ruleset) with at least one required status check. Without it, GitHub won't queue an auto-merge.

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

## How it works

### `evaluate-pr` job (triggers on `pull_request_target`)

Runs on every opened/updated/labelled Dependabot PR:

1. **Fast-track check** — if the `fast-track-label` is present, enable auto-merge immediately and exit.
2. **Gate 1** — use `dependabot/fetch-metadata` to extract the GHSA ID. If missing (indirect dep), fall back to the Dependabot Alerts API and match open security alerts against the updated packages.
3. **Gate 2** — require CVSS ≥ `cvss-threshold`.
4. **Gate 3** — require compatibility score ≥ `compatibility-threshold`% (skipped for indirect deps).
5. Apply `review-label` if any gate fails; apply `pending-label` if all pass.

### `scheduled-merge` job (triggers on `schedule`)

Runs on the cron you define in the caller. Finds open PRs labelled `pending-label` that are older than `age-days` days and enables auto-merge on each.

## Security notes

- The workflow only acts on PRs authored by `app/dependabot`.
- The `pull_request_target` trigger gives the workflow write access to the base repo; acting on trusted bot authors only is the standard mitigation.
- `security-events: read` is required to call the Dependabot Alerts API for indirect dependency lookups.
