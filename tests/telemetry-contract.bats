#!/usr/bin/env bats
# Tests for the telemetry event contract in docs/telemetry/. The validator is
# the thing under test in both directions: the declared examples must pass,
# and each fixture in tests/telemetry-contract/ must be rejected for its own
# reason. Asserting the exact message matters. A fixture that starts failing
# for some other reason has stopped testing what it was written to test.
#
# The contract is checked here rather than in a lint job of its own so the
# existing bats job covers it. node is preinstalled on ubuntu-latest.

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export VALIDATE="$REPO_ROOT/docs/telemetry/validate.mjs"
    export FIXTURES="$REPO_ROOT/tests/telemetry-contract"
    [ -f "$VALIDATE" ]
    [ -d "$FIXTURES" ]
}

# Run the validator over fixture $1 and leave the output in $output.
reject() {
    run node "$VALIDATE" "$FIXTURES/$1.json"
    [ "$status" -eq 1 ]
}

# Succeed when the run reported exactly one problem, and it contains $1.
# The count guards against a fixture that trips several checks at once, where
# a passing assertion would say nothing about which check did the work.
only_problem() {
    [ "$(grep -c '^  - ' <<<"$output")" -eq 1 ]
    grep -qF -- "$1" <<<"$output"
}

# --- the declared contract holds ------------------------------------------

@test "every declared example passes the contract" {
    run node "$VALIDATE"
    [ "$status" -eq 0 ]
    grep -q 'No problems found.' <<<"$output"
}

@test "every declared outcome has an example" {
    run node "$VALIDATE"
    [ "$status" -eq 0 ]
    # The validator reports this as a coverage problem, so a pass means the
    # count it prints is the count that was actually exercised.
    grep -qE 'Checked [0-9]+ example payloads against [0-9]+ declared outcomes' <<<"$output"
}

@test "no example body approaches the endpoint's body cap" {
    run node "$VALIDATE"
    [ "$status" -eq 0 ]
    largest=$(sed -n 's/^Largest body \([0-9]*\) bytes.*/\1/p' <<<"$output")
    [ -n "$largest" ]
    # Well under 8192. A payload near the cap means a field is carrying
    # something unbounded, which the endpoint would answer with a 413.
    [ "$largest" -lt 4096 ]
}

# --- type collisions in the shared Elasticsearch index --------------------

@test "an integer pr is rejected, since ai_review maps it as a string" {
    reject pr-as-integer
    # Two problems here on purpose: the schema type and the shared-index
    # collision. Both are the same mistake seen from two directions.
    grep -qF 'field pr is integer, schema says string' <<<"$output"
    grep -qF 'but string in feature:ai_review, which shares this index' <<<"$output"
}

# --- fields the endpoint allowlist would refuse ---------------------------

@test "a field outside the schema is rejected rather than silently dropped" {
    reject unknown-field
    only_problem 'field pr_author_email is not in the schema'
}

# --- invariants a payload builder can break silently ----------------------

@test "an unusable CVSS never carries an effective score" {
    reject cvss-unavailable-with-effective
    only_problem 'outcome cvss_unavailable must never carry cvss_effective'
}

@test "a fast-tracked PR never carries gate fields" {
    reject fast-track-with-gate-fields
    only_problem 'outcome fast_track must never carry cvss_reported'
}

@test "a zero compatibility score is rejected as missing data" {
    reject compat-score-zero
    only_problem 'field compat_score value 0 is below minimum 1'
}

# --- outcome bookkeeping --------------------------------------------------

@test "an outcome missing its required reason code is rejected" {
    reject missing-fail-reason
    only_problem 'outcome preflight_fail requires fail_reason'
}

@test "an outcome attributed to the wrong job is rejected" {
    reject wrong-job-for-outcome
    only_problem 'outcome pending belongs to job evaluate_pr'
}

@test "a reason code not declared for its outcome is rejected" {
    reject undeclared-fail-reason
    only_problem 'is not declared for scheduled_merge_failed'
}

# --- the endpoint's body cap ----------------------------------------------

@test "a body over the endpoint's cap is rejected before it is sent" {
    reject oversize-body
    only_problem 'over the 8192 cap'
}
