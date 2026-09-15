#!/usr/bin/env bats
# Tests for the step that records evaluate-pr's verdict as a commit status,
# run against the gh stub in tests/stubs/. The step script is pulled out of
# the YAML and run as-is.
#
# The status is the evidence the scheduled merge requires, because labels
# are not evidence: a triage user can apply the pending label or remove the
# review label. A status is bound to the commit it was written for, and
# creating one takes statuses: write, which a triage user does not have.
# tests/scheduled-merge.bats covers the reading side.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export RECORD_STEP="$BATS_FILE_TMPDIR/record-eligibility.sh"
    extract_run record-eligibility >"$RECORD_STEP"
    # Guard the extractor: an empty script would pass the no-status
    # assertions below for the wrong reason.
    [ -s "$RECORD_STEP" ]
    bash -n "$RECORD_STEP"
    grep -q 'statuses/' "$RECORD_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    : >"$GITHUB_OUTPUT"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

HEAD=1111111111111111111111111111111111111111

# Run the record step for $HEAD with Gate 2's pass output as $1, Gate 3's
# conclusion as $2 and Gate 3's pass output as $3. The flags match what the
# step's `shell: bash` expands to in Actions.
record() {
    HEAD_SHA=$HEAD RUN_URL=https://example.test/run \
        GATE2_PASS="$1" GATE3_CONCLUSION="$2" GATE3_PASS="${3:-}" \
        bash --noprofile --norc -e -o pipefail "$RECORD_STEP"
}

status_post_key() {
    echo "POST_repos_acme_widgets_statuses_$HEAD"
}

@test "a PR that clears the gates records success on its head commit" {
    : >"$GH_STUB_DIR/$(status_post_key)"
    for gate3 in 'skipped:' 'success:true'; do
        : >"$GH_STUB_LOG"
        : >"$GITHUB_OUTPUT"
        record true "${gate3%%:*}" "${gate3#*:}"
        log_has_call 'api' '-X POST' "statuses/$HEAD" 'state=success' \
            'context=dependabot-auto-merge/eligibility'
        [ "$(out eligible)" = "true" ]
    done
}

@test "a PR that fails the gates withdraws success recorded for the same commit" {
    : >"$GH_STUB_DIR/$(status_post_key)"
    statuses_fixture "$HEAD" "$(commit_status success 'github-actions[bot]')"
    for verdict in 'true:success:false' 'false:skipped:' ':skipped:' 'true:failure:'; do
        : >"$GH_STUB_LOG"
        : >"$GITHUB_OUTPUT"
        IFS=: read -r gate2 gate3 gate3_pass <<<"$verdict"
        record "$gate2" "$gate3" "$gate3_pass"
        log_has_call '-X POST' "statuses/$HEAD" 'state=failure'
        [ "$(log_count 'state=success')" -eq 0 ]
        [ "$(out eligible)" = "false" ]
    done
}

@test "a routine update with no evidence gets no status" {
    # Writing failure on every ineligible commit would put a red status on
    # every routine Dependabot PR. There is nothing to withdraw here.
    statuses_fixture "$HEAD" "$(commit_status success 'github-actions[bot]' ci/build)"
    record false skipped
    [ "$(log_count '-X POST')" -eq 0 ]
    [ "$(out eligible)" = "false" ]
}

@test "withdrawal ignores a success status someone else wrote" {
    statuses_fixture "$HEAD" "$(commit_status success trina)"
    record false skipped
    [ "$(log_count '-X POST')" -eq 0 ]
}

@test "a status lookup failure withdraws anyway" {
    : >"$GH_STUB_DIR/$(status_post_key)"
    echo "gh: HTTP 403" >"$GH_STUB_DIR/GET_repos_acme_widgets_commits_${HEAD}_statuses_per_page_100.err"
    run record false skipped
    [ "$status" -eq 0 ]
    grep -qF '::warning::' <<<"$output"
    log_has_call '-X POST' "statuses/$HEAD" 'state=failure'
}

@test "a status write failure fails the step" {
    # No POST fixture: the stub answers 404. No verdict is written either,
    # so revoke-auto-merge treats the PR as not eligible.
    run record true skipped
    [ "$status" -ne 0 ]
    [ "$(out eligible)" = "" ]
}
