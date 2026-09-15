#!/usr/bin/env bats
# Tests for the fast-track authorization and audit steps of the reusable
# workflow, run against the gh stub in tests/stubs/. The step scripts are
# pulled out of the YAML and run as-is, so these tests exercise the shipped
# code rather than a copy that can drift.
#
# The fast-track label bypasses every gate, and a triage user can apply a
# label without being able to enable auto-merge. So the label only counts
# when the user who most recently applied it can merge, and the event that
# happens to be running (a Dependabot `synchronize`, typically) says nothing
# about who that was.

load helpers

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
    export AUTH_STEP="$BATS_FILE_TMPDIR/fast-track-auth.sh"
    export AUDIT_STEP="$BATS_FILE_TMPDIR/fast-track-audit.sh"
    extract_run fast-track-auth >"$AUTH_STEP"
    extract_run fast-track-audit >"$AUDIT_STEP"
    # Guard the extractor: an empty or half-dedented script would pass the
    # refusal assertions below for the wrong reason.
    for step in "$AUTH_STEP" "$AUDIT_STEP"; do
        [ -s "$step" ]
        bash -n "$step"
    done
    grep -q 'collaborators/' "$AUTH_STEP"
    grep -q 'authorized=' "$AUTH_STEP"
    grep -q 'pr comment' "$AUDIT_STEP"
}

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    export GITHUB_REPOSITORY="acme/widgets"
    export GH_STUB_DIR="$BATS_TEST_TMPDIR/fixtures"
    export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
    export PR_NUMBER=42
    export PR_URL="https://github.com/acme/widgets/pull/42"
    export FAST_TRACK_LABEL=security-fast-track
    mkdir -p "$GH_STUB_DIR"
    : >"$GH_STUB_LOG"
    : >"$GITHUB_OUTPUT"
    PATH="$REPO_ROOT/tests/stubs:$PATH"
}

EVENTS_KEY="GET_repos_acme_widgets_issues_42_events_per_page_100"

# One issue event: $1 = id, $2 = labeled|unlabeled, $3 = actor, $4 = label
# name. The timestamp derives from the id so fixtures stay in order without
# date arithmetic.
label_event() {
    printf '{"id":%s,"event":"%s","actor":{"login":"%s"},"label":{"name":"%s","color":"0075ca"},"created_at":"2026-09-01T10:00:%02dZ"}' \
        "$1" "$2" "$3" "$4" "$1"
}

# Serve the given events as the paginated, slurped events response: an array
# of pages, each an array of events.
events_fixture() {
    {
        printf '[['
        local sep=''
        for event in "$@"; do
            printf '%s%s' "$sep" "$event"
            sep=','
        done
        printf ']]'
    } >"$GH_STUB_DIR/$EVENTS_KEY"
}

# $1 = login, $2 = legacy permission, $3 = role name. The API maps maintain
# to write and triage to read, which is exactly the split the step relies on.
permission_fixture() {
    printf '{"permission":"%s","role_name":"%s","user":{"login":"%s"}}' "$2" "$3" "$1" \
        >"$GH_STUB_DIR/GET_repos_acme_widgets_collaborators_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')_permission"
}

# The flags match what the step's `shell: bash` expands to in Actions.
authorize() {
    bash --noprofile --norc -e -o pipefail "$AUTH_STEP"
}

# --- who may authorize ----------------------------------------------------

@test "a triage user's label does not authorize the override" {
    events_fixture "$(label_event 1 labeled trina security-fast-track)"
    permission_fixture trina read triage
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
    grep -qF '::warning::' <<<"$output"
    grep -qF 'triage' <<<"$output"
    [ "$(log_count 'pr merge')" -eq 0 ]
}

@test "write, maintain and admin users authorize the override" {
    for role in write:write maintain:write admin:admin; do
        : >"$GITHUB_OUTPUT"
        events_fixture "$(label_event 1 labeled merger security-fast-track)"
        permission_fixture merger "${role#*:}" "${role%%:*}"
        authorize
        [ "$(out authorized)" = "true" ]
        [ "$(out applied-by)" = "merger" ]
        [ "$(out role)" = "${role%%:*}" ]
    done
}

# --- which label application counts --------------------------------------

@test "a label already on the PR still needs an authorized applier on a later event" {
    # The running event is a Dependabot synchronize, and the only activity
    # since the triage user applied the label is an admin applying a
    # different one. Neither may stand in for the applier.
    export GITHUB_EVENT_NAME=pull_request_target SENDER='dependabot[bot]'
    events_fixture \
        "$(label_event 1 labeled trina security-fast-track)" \
        "$(label_event 2 labeled ada dependencies)"
    permission_fixture trina read triage
    permission_fixture ada admin admin
    run authorize
    [ "$(out authorized)" = "false" ]
    [ "$(log_count 'collaborators/ada')" -eq 0 ]
}

@test "the most recent applier decides after the label is removed and re-applied" {
    events_fixture \
        "$(label_event 1 labeled ada security-fast-track)" \
        "$(label_event 2 unlabeled ada security-fast-track)" \
        "$(label_event 3 labeled trina security-fast-track)"
    permission_fixture ada admin admin
    permission_fixture trina read triage
    run authorize
    [ "$(out authorized)" = "false" ]

    : >"$GITHUB_OUTPUT"
    events_fixture \
        "$(label_event 1 labeled trina security-fast-track)" \
        "$(label_event 2 unlabeled trina security-fast-track)" \
        "$(label_event 3 labeled ada security-fast-track)"
    authorize
    [ "$(out authorized)" = "true" ]
    [ "$(out applied-by)" = "ada" ]
}

@test "events are ordered by time, not by response order" {
    # The newest application arrives first in the response. Taking the last
    # element as-is would credit the triage user's removed application.
    events_fixture \
        "$(label_event 3 labeled ada security-fast-track)" \
        "$(label_event 1 labeled trina security-fast-track)" \
        "$(label_event 2 unlabeled trina security-fast-track)"
    permission_fixture ada admin admin
    permission_fixture trina read triage
    authorize
    [ "$(out authorized)" = "true" ]
    [ "$(out applied-by)" = "ada" ]
}

@test "label names compare case-insensitively" {
    export FAST_TRACK_LABEL=Security-Fast-Track
    events_fixture "$(label_event 1 labeled ada SECURITY-fast-track)"
    permission_fixture ada admin admin
    authorize
    [ "$(out authorized)" = "true" ]
}

@test "a label removed since the event fired does not authorize" {
    events_fixture \
        "$(label_event 1 labeled ada security-fast-track)" \
        "$(label_event 2 unlabeled ada security-fast-track)"
    permission_fixture ada admin admin
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
}

@test "no recorded application of the label does not authorize" {
    events_fixture "$(label_event 1 labeled ada dependencies)"
    permission_fixture ada admin admin
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
}

# --- lookups fail closed --------------------------------------------------

@test "an events lookup failure refuses the override" {
    echo "gh: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/$EVENTS_KEY.err"
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
    grep -qF 'HTTP 403' <<<"$output"
}

@test "a malformed events response refuses the override" {
    echo 'not json' >"$GH_STUB_DIR/$EVENTS_KEY"
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
}

@test "a permission lookup failure refuses the override" {
    # No permission fixture: the stub answers 404, as the API does for a
    # login that is not a collaborator, a bot among them.
    events_fixture "$(label_event 1 labeled 'renovate[bot]' security-fast-track)"
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
    grep -qF '::warning::' <<<"$output"
}

@test "an unrecognised permission value refuses the override" {
    events_fixture "$(label_event 1 labeled ada security-fast-track)"
    printf '{"message":"odd"}' >"$GH_STUB_DIR/GET_repos_acme_widgets_collaborators_ada_permission"
    run authorize
    [ "$status" -eq 0 ]
    [ "$(out authorized)" = "false" ]
}

# --- audit ----------------------------------------------------------------

@test "the audit comment names the verified applier, not the event sender" {
    echo '[]' >"$GH_STUB_DIR/GET_repos_acme_widgets_issues_42_comments_per_page_100"
    APPLIED_BY=ada ROLE=maintain RUN_URL=https://example.test/run \
        bash --noprofile --norc -e "$AUDIT_STEP"
    [ "$(log_count 'pr comment')" -eq 1 ]
    [ "$(log_count '@ada')" -eq 1 ]
    [ "$(log_count 'maintain')" -eq 1 ]
}
