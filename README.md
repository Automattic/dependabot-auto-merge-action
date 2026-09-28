# dependabot-auto-merge-action

A reusable GitHub Actions workflow that automatically merges Dependabot security PRs after they clear a set of configurable gates.

## Gates

| # | Gate | Default | Notes |
|---|------|---------|-------|
| 1 | Security advisory (GHSA ID) | required | PR must be a security fix, not a routine bump. Falls back to the Dependabot alerts API when PR metadata names no advisory. An alert counts only when its package, ecosystem, manifest directory and patched version all match the update. |
| 2 | CVSS severity | ≥ 7.0 | High or critical. Configurable via `cvss-threshold`. A zero-like or out-of-range score means GitHub has no usable CVSS data, so the PR goes to human review instead. |
| 3 | Compatibility score | ≥ 80% | Direct deps only, going by fetch-metadata's `dependency-type`. Every direct dependency in the PR needs a score, and the lowest one counts. A missing score sends the PR to human review. |
| 4 | Age gate | 7 days | Scheduled job merges passing PRs after `age-days` days. |

PRs that fail any gate are labelled `sirt-review-required` (or your custom label) and routed for human review. A person who can merge bypasses all gates by enabling auto-merge on the PR with GitHub's own button. The workflow then posts a one-time audit comment recording who enabled it, when, and a link to the workflow run, and applies the `security-fast-track` label as a marker.

`sirt-review-required` and `auto-merge-pending` are mutually exclusive workflow states: every evaluation applies one and removes the other, so a re-evaluated PR — say after Dependabot rewrites the branch — never carries both.

## Usage

### 1. Create the caller workflow in your repo

```yaml
# .github/workflows/dependabot-auto-merge.yml
name: Dependabot auto-merge

on:
    pull_request_target:
        types: [opened, synchronize, reopened, labeled, auto_merge_enabled]
    schedule:
        - cron: '0 9 * * *'

permissions:
    pull-requests: write
    contents: write
    vulnerability-alerts: read
    statuses: write

jobs:
    dependabot-auto-merge:
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@<sha> # v1.6
        permissions:
            pull-requests: write
            contents: write
            vulnerability-alerts: read
            statuses: write
        with:
            event-name: ${{ github.event_name }}
```

Pin to the commit SHA a release tag points at, with the tag in a trailing comment — the same way this repo pins third-party actions. Tags name releases; they are not pinning targets, and none of them float. Resolve the SHA with:

```bash
gh api repos/Automattic/dependabot-auto-merge-action/commits/v1.6 --jq .sha
```

That's it. All inputs have defaults that match the original P2 configuration, so no extra config is needed unless you want to customize behaviour.

Callers pinned at v1.6 or earlier: the `security-fast-track` label no longer enables auto-merge. Enable auto-merge on the PR instead, with the button or `gh pr merge --auto`. Add `auto_merge_enabled` to `types` when you re-pin, so the audit comment posts on that event rather than on the PR's next push.

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

Preflight only confirms a token can view repo settings. It can't confirm Administration write for either token type, because no read-only check reliably proves it. A probe against `vulnerability-alerts` doesn't work either. That endpoint returns a 404 both when alerts are genuinely disabled and when the token simply lacks access, confirmed live against a repo we don't administer. On GitHub Enterprise Server it 404s for every token while Dependabot is disabled instance-wide, regardless of role. And even a clean success only proves Administration read, not write, so an app granted read-only access would still pass and then fail on every write call. `gh` CLI, `terraform-provider-github`, and `create-pull-request` all handle this the same way. They skip the probe and let each step's own mutating call refuse with its real error. A token that lacks write access fails at the first admin-scoped step with a clear 403, not at preflight.

`--required-check` must match the check-run name exactly as it appears on a PR's Checks tab (for GitHub Actions, the job's name). To list check names on a recent commit: `gh api --paginate repos/OWNER/REPO/commits/COMMIT_SHA/check-runs --jq '.check_runs[].name'`. If the default branch already has required status checks (ruleset or classic branch protection), the script leaves them alone.

If you use custom label names (see the inputs below), create those labels manually instead — the script only manages the default set. The manual equivalents of each step follow.

### 3. Map Dependabot to your lockfiles

Dependabot only updates a lockfile it has been pointed at. Where a lockfile is not at the default path — npm/yarn/pnpm workspaces, composer monorepos, anything outside the repository root — `.github/dependabot.yml` needs an explicit `directory` mapping. Without one the repo passes every check above, and then its security PRs ship without the lockfile update, CI stays red, and auto-merge never fires.

`dependabot-directories` works out where the manifests and lockfiles actually are and proposes the mapping as a pull request. The default branch is never written to directly. It needs `php` (8.2 or newer) and `gh`.

Run it from a checkout of this repo:

```bash
composer install
php bin/dependabot-directories owner/repo --dry-run
php bin/dependabot-directories owner/repo
```

From the next tagged release onward it is also attached to the [release](https://github.com/Automattic/dependabot-auto-merge-action/releases) as a single `dependabot-directories.phar`, alongside its `sha256`. That drops the Composer step:

```bash
gh release download v1.6 --pattern 'dependabot-directories.phar*'
shasum -a 256 -c dependabot-directories.phar.sha256
chmod +x dependabot-directories.phar
./dependabot-directories.phar owner/repo --dry-run
```

v1.5 predates the tool and carries no such asset.

Start with `--dry-run`: it prints the detected mappings, a unified diff of the proposed `.github/dependabot.yml`, and every call a real run would make — without making any of them. `--detect-only` is shorter still, stopping after the report.

Detection is remote. It reads the file list from the git trees API plus a handful of file contents for workspace declarations, falling back to a blobless shallow clone on the repositories big enough to truncate that API.

| Option | Effect |
|--------|--------|
| `--dry-run` | Report and diff, write nothing |
| `--detect-only` | Report the mappings and stop |
| `--include <dir>` | Treat a soft-excluded directory name (`examples`, `dist`, `fixtures`, …) as real. Repeatable |
| `--enable-version-updates` | Emit the full house template instead of the security-only default |
| `--allow-full-clone` | Permit a full clone when the server refuses a blobless one |
| `--force` | Proceed past the sanity cap of 50 mappings |

Generated entries carry `open-pull-requests-limit: 0` by default. That gives Dependabot's **security** updates the directory mapping they need while raising no scheduled version-update PRs — the mapping is the point, the noise is not. `--enable-version-updates` opts in to the full template.

The tool only ever appends. Existing update blocks are never modified or removed, the file's own indentation and comments are preserved, and an entry that already covers a detected directory (including via a `directories:` glob) is left alone. Re-running a mapped repo reports `already covers every detected directory` and writes nothing.

A fine-grained PAT scoped to the repo needs:

| Permission | Level | Used for |
|------------|-------|----------|
| Contents | Read & write | File list, file contents, creating the branch and commit |
| Pull requests | Read & write | Opening and updating the pull request |
| Metadata | Read | Implied by the above |

`--dry-run` needs only the read halves.

See [docs/directory-mapping.md](docs/directory-mapping.md) for the detection rules, the workspace algorithm, and what the tool deliberately refuses to touch.

### 4. Create the required labels (manual alternative)

The workflow needs three labels to exist in your repo. Create them once:

```bash
gh label create "security-fast-track" --color "0075ca" --description "Marks a PR where a person enabled auto-merge, bypassing the gates"
gh label create "auto-merge-pending"  --color "e4e669" --description "Passed all gates; awaiting age gate"
gh label create "sirt-review-required" --color "d93f0b" --description "Requires human security review"
```

### 5. Enable auto-merge on the repo (manual alternative)

Auto-merge must be allowed in your repo settings:

> **Settings → General → Pull Requests → Allow auto-merge** ✓

The workflow's preflight job verifies this at runtime and fails with an error pointing back here if it's disabled.

### 6. Branch protection (manual alternative)

Your default branch needs a branch protection rule (or ruleset) with at least one required status check. Without it, GitHub won't queue an auto-merge.

Prefer a **ruleset** (Settings → Rules → Rulesets): the preflight job can fully verify ruleset-based required status checks with the default `GITHUB_TOKEN`. Classic branch protection details are only readable by admin tokens, so with classic protection the preflight can confirm the branch is protected but only warns that it cannot verify the checks themselves. If neither is configured, preflight fails with an error pointing back here. (`scripts/bootstrap.sh` creates a ruleset, so bootstrapped repos are fully verifiable by preflight.)

Dependabot vulnerability alerts must also be enabled (**Settings → Advanced Security**). Gate 1 reads them twice, once through fetch-metadata's alert lookup and again through the Dependabot alerts API when that lookup names no advisory or an unscored one. In practice the second read finds the advisory: fetch-metadata v3.1.0 matches an alert only when its vulnerable requirement reads `= <version>`, and GitHub now reports the bare version, so the lookup names nothing and the fallback carries the gate.

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `event-name` | string | **required** | Pass `${{ github.event_name }}` — routes jobs to the correct trigger. |
| `cvss-threshold` | string | `'7.0'` | Minimum CVSS score for Gate 2. Float string, e.g. `'6.5'`. |
| `compatibility-threshold` | number | `80` | Minimum compatibility score % for Gate 3 (direct deps only). |
| `age-days` | number | `7` | Days a PR must be open before the scheduled job merges it. |
| `merge-method` | string | `'squash'` | `squash`, `merge`, or `rebase`. |
| `fast-track-label` | string | `'security-fast-track'` | Marker label applied when a person enables auto-merge on a PR. Applying it by hand does nothing. |
| `review-label` | string | `'sirt-review-required'` | Label applied when a PR fails a gate. |
| `pending-label` | string | `'auto-merge-pending'` | Label applied when a PR passes all gates and is waiting for the age gate. |
| `review-team` | string | `''` | Optional. GitHub team slug (`org/team`) @-mentioned in review-required comments. |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `token` | No | Token used to read Dependabot alerts, both by `dependabot/fetch-metadata` (its alert lookup, which also lists the PR's commits) and by the Gate 1 fallback. Defaults to `GITHUB_TOKEN`, which reads them once the job grants `vulnerability-alerts: read`. Pass a PAT or fine-grained token only where that permission is unavailable. A fine-grained token needs **Dependabot alerts: Read** and, from v1.6, **Pull requests: Read**. |

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
    pull-requests: write   # label and comment on PRs, read auto-merge state
    contents: write        # enable auto-merge
    vulnerability-alerts: read  # read Dependabot alerts
    statuses: write        # record and read eligibility evidence
```

These are the minimum required. The fast-track check reads the PR's auto-merge state through the pulls API, which `pull-requests` covers. If your repo uses a restrictive default permissions policy, set them explicitly on the job as shown in the usage example above.

**`statuses: write` and `vulnerability-alerts: read` are breaking changes for callers pinned at v1.5 or earlier.** Add both to both `permissions` blocks when you re-pin, and drop `security-events: read`, which the workflow no longer requests. Without them GitHub refuses to start the reusable workflow, because a called workflow cannot hold a permission its caller did not grant. The workflow writes a `dependabot-auto-merge/eligibility` commit status when a PR passes the gates, and the scheduled merge will not act on a PR without one. See [How it works](#scheduled-merge-job-triggers-on-schedule) for why a label is not enough.

### When the token cannot read Dependabot alerts

`security-events: read` does not grant Dependabot alerts. A `GITHUB_TOKEN` without `vulnerability-alerts: read` gets a 403 from the alerts API, and the GraphQL field fetch-metadata's alert lookup uses returns an empty list instead of an error. So the `dependabot/fetch-metadata` step passes with no advisory named, and the Gate 1 fallback step fails the job with `Resource not accessible by integration`. The fix is to grant `vulnerability-alerts: read` on the caller job and at the top of the caller workflow, as in the usage example.

Where that permission is unavailable, pass a token instead.

If the lookup succeeds but the later Dependabot alerts API call fails, what happens depends on why the API was called:

- **PR metadata named no advisory.** The API is the only advisory source, so the Gate 1 fallback step fails the job.
- **PR metadata named an unscored advisory.** The API call is a best-effort attempt to recover a real score, so a failure only logs a warning and the PR goes to human review, exactly as if the API had never been consulted. The job stays green.

Create a PAT, or a fine-grained token with **Dependabot alerts: Read** and **Pull requests: Read** on the target repo, and pass it as a secret. A token scoped to alerts alone fails the `dependabot/fetch-metadata` step with `Resource not accessible by personal access token` when it lists the PR's commits:

```yaml
jobs:
    dependabot-auto-merge:
        uses: Automattic/dependabot-auto-merge-action/.github/workflows/dependabot-auto-merge.yml@<sha> # v1.6
        permissions:
            pull-requests: write
            contents: write
            vulnerability-alerts: read
            statuses: write
        with:
            event-name: ${{ github.event_name }}
        secrets:
            token: ${{ secrets.DEPENDABOT_ALERTS_TOKEN }}
```

Store the PAT as a repository or organisation secret named `DEPENDABOT_ALERTS_TOKEN` (or any name you prefer) and reference it in `secrets.token`.

## Troubleshooting

### A PR was routed for review with "advisory metadata (CVSS) was unavailable"

GitHub sometimes returns `0.0` as the CVSS score for a matched advisory. That is not a severity rating — it means the advisory carries no CVSS v3 vector, usually because it was published recently and has not been scored yet. Branch rewrites can also rematch a PR against a newer, unscored advisory.

The workflow treats as missing metadata every zero-like score (empty, `0`, `0.0`, `00`, `.00`), every value it cannot parse as a number, and anything above `10`. From v1.6 it first tries to recover a real score. An unscored advisory in PR metadata sends the PR through the Dependabot alerts API, which often holds a score for the same advisory before it reaches PR metadata. Only that advisory counts, never another open alert on the same package. Only when that finds nothing better, because no applicable open alert exists for the advisory or the call failed (expect one warning annotation per such PR), does the PR fail closed. It gets `review-label` and a comment naming the score GitHub reported, where there was one. It never reads `0.0` as "below the threshold", because that would describe an unscored advisory as a safe one. Failing closed ships from v1.5 (v1.4 and earlier described an unscored advisory as below-threshold); the recovery attempt ships from v1.6.

What to do: check the advisory yourself. If it is a real high-severity fix, enable auto-merge on the PR; the workflow records who did so in an audit comment. Nothing re-evaluates a PR when an advisory is scored later — the gates only re-run on a new PR event, so a stalled PR needs either auto-merge enabled by hand or a push.

### I enabled auto-merge but no audit comment appeared

The workflow posts the comment when it next runs on the PR. It runs at once only if the caller workflow lists `auto_merge_enabled` under the `pull_request_target` types, as the template above does. Without it, the comment and the marker label arrive on the PR's next event, such as a Dependabot rebase. The auto-merge itself is GitHub's and does not wait for the workflow.

If a run did happen and its evaluation job reports "Cannot read the auto-merge state", it stopped before acting on anything. Re-run it once the API is reachable.

### Auto-merge was disabled on a PR

The workflow leaves a comment naming the reason and the commit it evaluated. It withdraws an auto-merge it queued itself when the latest evaluation finds the PR fails the gates, or passes them but is younger than `age-days`. An auto-merge a person enabled is never touched.

What to do: if the PR should merge now, have someone with write access or higher enable auto-merge on it. Otherwise nothing. A PR that passes the gates is queued again by the scheduled merge once it clears the age gate.

### The scheduled job skips a PR labelled `auto-merge-pending`

The run shows a warning naming the PR and its head commit. The scheduled merge needs a `success` status in the `dependabot-auto-merge/eligibility` context on the PR's current head, and the label alone is not enough. Common causes:

- The pending label was applied by hand. That is expected to be refused.
- Dependabot pushed a new commit and that commit's evaluation has not passed, or failed before it finished. Check the evaluation run for that push.
- The PR was labelled pending before you upgraded to a version that records evidence, so no status exists yet.

What to do: trigger a fresh evaluation. Any new PR event does it, such as applying a label or asking Dependabot to rebase. If the gates pass, the status is written and the next scheduled run merges the PR.

### A PR was routed for review with "the compatibility score for ... was unavailable"

Dependabot publishes a compatibility score only for updates it has enough CI data on, and fetch-metadata reports a missing score as `0`. The workflow treats `0`, and anything that is not a whole number from 1 to 100, as no score, so the PR goes to review rather than reading as a 0% score. In a grouped update every direct dependency needs a score, and the comment names the first one without.

Before v1.6 the compatibility lookup was never enabled and Gate 3 never ran, so direct-dependency PRs went to `pending-label` with no compatibility check. Expect more reviews of this kind after upgrading.

What to do: check the update yourself, and apply the `fast-track-label` if it is safe to merge.

### A security PR got no label at all

The workflow found no open Dependabot alert that applies to the update, so it treated the PR as a routine version update. An alert applies only when all of these match an updated dependency:

- **Package name**, exactly.
- **Ecosystem.** Dependabot's package manager (`npm_and_yarn`, `go_modules`, `gradle`) is mapped to the alerts API ecosystem (`npm`, `go`, `maven`). Managers with no advisory database ecosystem, such as `docker` or `terraform`, never match.
- **Manifest directory.** The alert's manifest sits directly in the directory Dependabot updated. For GitHub Actions, workflow files under that directory's `.github/workflows` count too.
- **Version.** The new version is at or above the advisory's first patched version. Only plain dotted numbers such as `4.17.21` are compared. A pre-release or qualified version (`4.18.0-beta.1`, `32.1.0-jre`, `1.0.post1`), or an advisory with no patched release, cannot be compared across ecosystems reliably, so it does not match.

The Gate 1 fallback step log says how many open alerts named an updated package without applying to it. Review those PRs by hand.

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

Runs on every opened/updated/labelled Dependabot PR, and when a person enables auto-merge on one, after preflight passes. Evaluations of the same PR run one at a time. A newer event waits for the running one rather than cancelling it part-way.

1. **Fast-track check** — read the PR's auto-merge state. If a person (any login other than `github-actions[bot]`) has enabled auto-merge, GitHub has already checked that they can merge, so the workflow posts a one-time audit comment (who enabled it, UTC timestamp, workflow-run link), applies the `fast-track-label` as a marker, and exits. The comment is deduplicated via a hidden HTML marker, so repeated PR events never re-post it. An auto-merge the scheduled job queued, or one with no readable enabler, goes through the gates below. A failed read fails the run rather than guessing.
2. **Gate 1.** `dependabot/fetch-metadata` runs with `alert-lookup` and `compat-lookup` on, and reports the GHSA ID and CVSS of the alert matching the first updated dependency. The Dependabot alerts API is consulted as a fallback in two cases. Either the GHSA ID is missing, because the lookup matched no alert, or it is present but the CVSS is unusable, because the advisory is unscored and the API may hold a real score for it. Open alerts count only when they apply to an updated dependency, by package name, ecosystem, manifest directory and patched version (see [A security PR got no label at all](#a-security-pr-got-no-label-at-all)). When PR metadata named an advisory, only that advisory counts, so a package with several open alerts cannot lend a score from a vulnerability this PR leaves in place.
3. **Resolve the effective CVSS** — prefer the fetch-metadata score, then the alerts-API score. A score that is empty, non-numeric, numerically zero (`0`, `0.0`, `00`, `.00`), or above `10` is treated as missing metadata: the PR skips Gate 2 and goes straight to `review-label`, and the comment names the score GitHub reported.
4. **Gate 2** — require CVSS ≥ `cvss-threshold`.
5. **Gate 3.** Require compatibility score ≥ `compatibility-threshold`% for every direct dependency in the PR. Whether a PR has any is read from fetch-metadata's `dependency-type`, never from which Gate 1 path found the advisory. A PR of only indirect dependencies passes this gate, since fetch-metadata cannot score them. A missing score routes the PR to `review-label`.
6. Apply `review-label` and remove `pending-label` if any gate fails; apply `pending-label` and remove `review-label` if all pass. The two labels are mutually exclusive states — a re-evaluated PR always ends up with exactly one.
7. **Record the verdict on the head commit.** A pass writes a `success` commit status with the context `dependabot-auto-merge/eligibility` on the commit just evaluated. Any other outcome, including a run that errored before Gate 2 reported, writes `failure` over an earlier `success` on the same commit. A commit with no earlier `success` gets no status at all, so routine updates do not show a red status.
8. **Revoke a queued auto-merge the verdict no longer supports.** If this workflow queued an auto-merge, it stays queued only when the PR clears the gates and is older than `age-days`, which is what the scheduled merge would queue anyway. Otherwise it is disabled with `gh pr merge --disable-auto` and a comment says why. That covers a PR routed to review after its merge was queued and a run that errored before a verdict. An auto-merge a person enabled by hand is left alone, since only users with write access can do that. GitHub disables auto-merge on some head changes by itself, but the workflow does not rely on it.

The scheduled merge pins the merge to the head commit whose evidence it just checked with `--match-head-commit`, so a commit pushed in between makes GitHub refuse the merge. It also skips any PR whose auto-merge is already enabled, so a person's fast-track is never queued again under this workflow's name.

### `scheduled-merge` job (triggers on `schedule`)

Runs on the cron you define in the caller, after preflight passes. Finds open PRs labelled `pending-label` that are older than `age-days` days and enables auto-merge on each — excluding any that also carry `review-label`, so a stale pending label can never put a human-review PR back in the merge set. That exclusion ignores case, matching how Actions, `gh pr edit` and `gh pr list --label` compare labels, so a `review-label` input whose casing differs from the repository label still excludes the PR.

The labels only choose candidates. They are not proof a PR passed, because a triage user can apply `pending-label` or remove `review-label`, and evaluation never touches the labels of a routine version update. Each candidate merges only when the latest `dependabot-auto-merge/eligibility` status from `github-actions[bot]` on its current head commit is `success`. That status comes from evaluate-pr alone. Creating one takes `statuses: write`, which triage users do not have, and it belongs to one commit, so evidence for an earlier head does not carry over to a new one. A candidate with no evidence, or withdrawn evidence, is skipped with a warning. A failed status lookup skips the PR and fails the job, as a failed merge does.

After queueing a merge the job checks the evidence again and disables the merge if it is gone. An evaluation withdraws evidence before it disables auto-merge, so this closes the window where the scheduled merge could re-queue a merge an evaluation had just revoked.

Two other designs were considered. A check run from a dedicated job would need `checks: read` to read back on private repos, a new permission all the same, and its name carries the caller's job name as a prefix that this workflow cannot know. Re-running the gates in the scheduled job is not possible, because `dependabot/fetch-metadata` only runs on a pull request event.

Limits of the evidence: any other workflow in your repo that holds `statuses: write` and uses `GITHUB_TOKEN` also writes as `github-actions[bot]`, so it could write this context. Only people who can already change workflows can set that up.

## Security notes

- The workflow only acts on PRs authored by `app/dependabot`.
- The fast-track label never enables auto-merge. A person bypasses the gates by enabling auto-merge themselves, which GitHub allows only for write, maintain, or admin and records on the PR timeline.
- Every fast-track leaves an audit comment on the PR as well, so gate bypasses are attributable after the fact.
- The scheduled merge trusts a commit status on the PR's current head, not its labels. Triage users can change labels but cannot write statuses.
- A queued auto-merge is withdrawn when a later evaluation rejects the PR, and the scheduled merge refuses a head commit that was not the one evaluated.
- The `pull_request_target` trigger gives the workflow write access to the base repo; acting on trusted bot authors only is the standard mitigation.
- `vulnerability-alerts: read` is required to read Dependabot alerts, both in fetch-metadata's alert lookup and in the Gate 1 fallback. Where `GITHUB_TOKEN` cannot hold that permission, pass `secrets.token`.
- The `token` secret reaches `dependabot/fetch-metadata`, a pinned third-party action, as well as the workflow's own `gh` calls. Scope it to Dependabot alerts and pull requests, read only.
