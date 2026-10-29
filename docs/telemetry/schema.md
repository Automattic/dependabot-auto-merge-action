# Telemetry contract

Machine-checked. `node docs/telemetry/validate.mjs` validates every example in `examples.json` against `event-schema.json`, against the log2logstash whitelist, and against the field types `feature:ai_review` already writes into the same index. The bats suite runs it in both directions, so `bats tests/telemetry-contract.bats` is the shorter command.

```
Checked 18 example payloads against 17 declared outcomes.
Largest body 780 bytes, cap 8192.
No problems found.
```

Sources read rather than assumed, both on GHES:

- `wpcom` at `wp-content/lib/log2logstash/log2logstash.php` for the allowed parameters and the type casts.
- `wpcom` at `wp-content/rest-api-plugins/endpoints/ai-review-telemetry.php`, added in PR 219949, for the existing field types in the shared index.

## Request

```
POST https://public-api.wordpress.com/wpcom/v2/ci-telemetry
Content-Type: application/json
X-CI-Telemetry-Token: <token>
```

One event per job, and one per PR from the scheduled job. Body cap 8 KiB, and the largest example is 780 bytes. Responses are 200 for an accepted event including one reporting a failure, 400 for a validation error, 403 for a bad token, 413 over the cap.

A passing example, the case where every gate cleared:

```json
{
  "feature": "dependabot_auto_merge",
  "source": "dependabot-auto-merge",
  "outcome": "pending",
  "job": "evaluate_pr",
  "repo": "Automattic/some-repo",
  "github_host": "github.com",
  "ci_provider": "github_actions",
  "build_url": "https://github.com/Automattic/some-repo/actions/runs/1234567897",
  "event_action": "opened",
  "duration": 15.8,
  "pr": "487",
  "pr_head_sha": "5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
  "ghsa_id": "GHSA-gggg-hhhh-iiii",
  "gate1_source": "pr_metadata",
  "dependency_names": "webpack",
  "dependency_type": "direct:production",
  "cvss_reported": "9.8",
  "cvss_effective": 9.8,
  "cvss_threshold": 7.0,
  "compat_score": 94,
  "compat_threshold": 80,
  "compat_dependency": "webpack"
}
```

## Outcomes

Seventeen, each pinned to one job.

- Preflight: `preflight_pass`, `preflight_warn`, `preflight_fail`
- Evaluation: `fast_track`, `no_advisory`, `cvss_unavailable`, `below_cvss_threshold`, `compat_unavailable`, `below_compat_threshold`, `pending`, `evaluate_error`
- Scheduled merge: `scheduled_merge_enabled`, `scheduled_merge_skipped`, `scheduled_merge_revoked`, `scheduled_merge_failed`, `scheduled_merge_evidence_unreadable`, `scheduled_merge_revoke_failed`

`success` is false for five of them, `preflight_fail`, `evaluate_error`, `scheduled_merge_failed`, `scheduled_merge_evidence_unreadable` and `scheduled_merge_revoke_failed`. A PR routed to human review is the action working correctly, so every gate outcome stays `success: true` and `severity: info`. That keeps a review-routing spike out of any failure alert, and `cvss_unavailable` gets its own panel and its own alert instead.

## Six outcomes the gate sequence does not suggest

The first eleven outcomes came from reading the workflow on `main`. These six come from the QAO-765 to QAO-768 stack, which adds decision points the original list could not describe.

- **`compat_unavailable`.** Gate 3 fails closed when no direct dependency carries a usable score, which is a different signal from a score below the threshold. fetch-metadata writes `0` both when the lookup is off and when Dependabot has no score, so `0` is missing data rather than a 0% score. This counts the unscored, exactly as `cvss_unavailable` does for advisories. Neither is measurable until QAO-767 turns `alert-lookup` and `compat-lookup` on.
- **`evaluate_error`.** The emitter runs under `always()`, so it fires on a run that errored before reaching a verdict. Without its own outcome those runs are either lost or miscounted as a gate decision.
- **`scheduled_merge_skipped`.** A candidate whose head commit carries no passing eligibility status. The job warns and moves on, so this is the action working, not a failure. It is also the panel that shows how often a hand-applied pending label is being caught.
- **`scheduled_merge_revoked`.** An evaluation withdrew the eligibility evidence while auto-merge was being enabled, so the job disabled it again. Rare, and worth counting because it means two jobs raced.
- **`scheduled_merge_evidence_unreadable`** and **`scheduled_merge_revoke_failed`.** Both are API failures that stop a PR merging or leave one queued that should not be. Both fail the job today, so both are `success: false`.

A refused fast-track is deliberately not an outcome. The authorization check falls through to the normal gates when it refuses, so the run still ends in a gate outcome and the refusal rides along as `fast_track_refused` with `fast_track_refusal_reason`. Making it an outcome would mean either losing the gate verdict or emitting two events for one decision. `refused_fast_track_below_cvss` in `examples.json` is that case.

## What the endpoint sends onward

log2logstash drops any top-level key outside `log2logstash_allowed_parameters()`, with no error. The validator checks the transform against that list, so the event uses only allowed top-level keys and everything else goes into `properties`.

```json
{
  "feature": "dependabot_auto_merge",
  "message": "gates_passed",
  "severity": "info",
  "success": "true",
  "duration": 15.8,
  "commit": "5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
  "url": "https://github.com/Automattic/some-repo/actions/runs/1234567897",
  "properties": { "...": "everything else" },
  "index": "log2logstash",
  "es_retention": "3m"
}
```

## Three things validation changed

**`pr` is a string, not an integer.** `ai_review` already maps `properties.pr` as a string in this index. Sending an integer collides with a mapping that exists. The validator fails on it, and there is a negative fixture for it.

**`cvss_reported` is a string, `cvss_effective` is a number.** The reported field exists to carry what GitHub actually sent, which includes `""`, `0.0`, `00`, `.00` and values that are not numbers at all. Typing it as a number destroys the exact signal it exists to capture. The effective field is a number with a minimum of 0.1, and the schema forbids it appearing at all on a `cvss_unavailable` event, because an unusable score never becomes the effective score.

**`success` is the string `"true"` or `"false"`.** log2logstash casts a PHP bool to `"1"` or `""`, but `ai_review` passes it through `wp_json_encode()` first, which yields `"true"` and `"false"`. Matching the strings that are already in the index matters more than matching the cast.

The string rule stops at the top level. `properties` is JSON encoded before it reaches Elasticsearch, and `ai_review` already maps `properties.is_followup` as a boolean, so `fast_track_refused` and `auto_merge_revoked` are real booleans.

## Two corrections the open stack forced

**`dependency_type` is not a direct or indirect pair.** fetch-metadata emits `direct:production`, `direct:development`, `indirect` or `unknown`, and reports the most direct type across every updated dependency. So `indirect` means nothing in the PR is direct. The enum now carries the four real values, and the emitter normalises empty to `unknown`.

**`event_action` gains `unlabeled`.** QAO-768 adds it as a caller trigger, because removing the fast-track label has to re-evaluate. A withdrawn override otherwise leaves a queued auto-merge standing.

## Storage

`es_retention` is `3m`. Confirmed, and the comment in the log2logstash source listing only `1d`, `1w`, `1m` and `6m` is stale. A [three month retention was granted in 2022](https://systemsrequests.wordpress.com/2022/11/24/requesting-3-months-log-retention-for-card-testing-analysis/) and `ai_review` ships `3m` today.

Long term trend data does not live here. Logstash retention caps at six months, so year over year numbers belong in MC Stats or in Hadoop through Tracks events.

## Negative fixtures

`validate.mjs` takes an optional path to an alternative examples file, which is how `tests/telemetry-contract/` is driven. Nine fixtures, one deliberate defect each, asserted by `tests/telemetry-contract.bats` on the exact message the validator produces. A fixture that starts failing for a different reason has stopped testing what it was written to test, so the assertion counts the problems as well as matching them.

The coverage check that every declared outcome has an example runs only over `examples.json`. Over a fixture it would report all seventeen outcomes as uncovered, and those errors alone would keep the run red after the defect the fixture exists to catch was fixed.
