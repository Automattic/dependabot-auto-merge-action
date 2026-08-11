#!/usr/bin/env bats
# Offline tests for scripts/dependabot-directories.sh.
#
# Every test here drives the script through --paths-from-file (and, where an
# existing config matters, --existing-config), so the detection heuristics and
# the append-only merge run with no network and no gh stub at all. That is the
# point of those two flags: the seam is only worth having if the tests use it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/dependabot-directories.sh"
    TREES="$REPO_ROOT/tests/fixtures/trees"
    CONFIGS="$REPO_ROOT/tests/fixtures/dependabot"
}

# Detect a fixture tree and return the report.
detect() {
    run "$SCRIPT" acme/widgets --paths-from-file "$TREES/$1.paths" --detect-only "${@:2}"
}

# Detect plus merge against an existing config.
merge() {
    run "$SCRIPT" acme/widgets --paths-from-file "$TREES/$1.paths" \
        --existing-config "$CONFIGS/$2" --dry-run "${@:3}"
}

# The "Detected mappings:" block, one "<eco>: <dir>" per line.
mappings() {
    printf '%s\n' "$output" | sed -n '/^Detected mappings:/,/^$/p' | grep -E '^   ' | sed 's/^   //'
}

# grep rather than [[ ]]: under macOS bash 3.2 a failed [[ ]] mid-test cannot
# fail a bats test (errexit/ERR fire only for simple commands).
assert_mapping() {
    mappings | grep -qFx "$1"
}

refute_mapping() {
    ! mappings | grep -qF "$1"
}

# High-volume findings are reported as a count plus indented examples, so assert
# on the example line rather than on a per-directory sentence.
assert_noted() {
    printf '%s\n' "$output" | grep -qFx "     $1"
}

refute_noted() {
    ! printf '%s\n' "$output" | grep -qFx "     $1"
}

mapping_count() {
    mappings | grep -c . || true
}

# --- argument validation --------------------------------------------------

@test "no arguments exits 2 with usage" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ $output == *"missing required argument"* ]]
    [[ $output == *"Usage:"* ]]
}

@test "repo without a slash is rejected" {
    run "$SCRIPT" widgets --detect-only
    [ "$status" -eq 2 ]
    [[ $output == *"invalid repository"* ]]
}

@test "literal gh api placeholders are rejected" {
    run "$SCRIPT" '{owner}/{repo}' --detect-only
    [ "$status" -eq 2 ]
    [[ $output == *"invalid repository"* ]]
}

@test "unknown option exits 2" {
    run "$SCRIPT" acme/widgets --frobnicate
    [ "$status" -eq 2 ]
    [[ $output == *"unknown option: --frobnicate"* ]]
}

@test "--include does not swallow a following option" {
    run "$SCRIPT" acme/widgets --include --dry-run
    [ "$status" -eq 2 ]
    [[ $output == *"--include needs a value"* ]]
}

@test "--include=<dir> form is accepted" {
    run "$SCRIPT" acme/widgets --include=examples \
        --paths-from-file "$TREES/excluded.paths" --detect-only
    [ "$status" -eq 0 ]
}

@test "a plain run refuses to proceed while the write path is unimplemented" {
    run "$SCRIPT" acme/widgets --paths-from-file "$TREES/root-npm.paths"
    [ "$status" -eq 2 ]
    [[ $output == *"--dry-run"* ]]
}

@test "--paths-from-file with a missing file exits 2" {
    run "$SCRIPT" acme/widgets --paths-from-file /nonexistent/nope.paths --detect-only
    [ "$status" -eq 2 ]
    [[ $output == *"no such file"* ]]
}

# --- npm detection --------------------------------------------------------

@test "root npm repo maps the root once" {
    detect root-npm
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    assert_mapping "github-actions: /"
    [ "$(mapping_count)" -eq 2 ]
}

@test "yarn workspaces map only the root, not every package" {
    detect yarn-workspaces
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    # The rule that prevents per-package entry spam in hoisted monorepos.
    refute_mapping "/packages/a"
}

@test "a workspace-covered package with its own lockfile is reported, not mapped" {
    detect yarn-workspaces
    refute_mapping "/packages/b"
    [[ $output == *"shadowed by the workspace"* ]]
    assert_noted "/packages/b"
}

@test "an uncovered manifest with no lockfile is reported, not mapped" {
    detect yarn-workspaces
    refute_mapping "/tools/helper"
    [[ $output == *"no lockfile and no workspace covering them"* ]]
    assert_noted "/tools/helper"
}

@test "yarn v1 object-form workspaces are parsed" {
    detect workspaces-object-form
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    [ "$(mapping_count)" -eq 1 ]
    # Parsed means covered: neither package may surface as an entry or a finding.
    refute_noted "/packages/a"
    refute_noted "/packages/b"
}

@test "a negated workspace pattern leaves that package to fend for itself" {
    detect workspaces-negation
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    # Excluded from the workspace and holding its own lockfile, so it needs an entry.
    assert_mapping "npm: /packages/legacy"
}

@test "globstar covers the zero-segment case" {
    detect workspaces-globstar
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    # apps/**/web must match apps/web as well as apps/deep/nested/web.
    refute_noted "/apps/web"
    refute_noted "/apps/deep/nested/web"
    # Outside the pattern, so it is still reported.
    assert_noted "/other/thing"
}

@test "an unrecognised workspaces shape is reported rather than assumed absent" {
    detect workspaces-unknown-shape
    [ "$status" -eq 0 ]
    [[ $output == *"not a shape we recognise"* ]]
    assert_mapping "npm: /"
}

@test "pnpm-workspace.yaml packages are honoured" {
    detect pnpm
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    [ "$(mapping_count)" -eq 1 ]
}

@test "a pnpm workspace with no packages key is reported" {
    detect pnpm-no-packages-key
    [ "$status" -eq 0 ]
    [[ $output == *"declares no 'packages:'"* ]]
    assert_mapping "npm: /"
}

# --- composer detection ---------------------------------------------------

@test "composer needs both a manifest and a lock" {
    detect composer-single
    [ "$status" -eq 0 ]
    assert_mapping "composer: /"
}

@test "sibling composer packages collapse into one glob" {
    detect composer-siblings
    [ "$status" -eq 0 ]
    assert_mapping "composer: /projects/plugins/* (glob)"
    [ "$(mapping_count)" -eq 1 ]
}

# --- the two glob guards --------------------------------------------------

@test "Guard 2: a glob that would sweep an unmapped sibling degrades to singulars" {
    detect composer-siblings-lockless
    [ "$status" -eq 0 ]
    refute_mapping "*"
    assert_mapping "composer: /projects/plugins/a"
    assert_mapping "composer: /projects/plugins/b"
    assert_mapping "composer: /projects/plugins/c"
    [[ $output == *"did not map"* ]]
    # d has a manifest but no lock, so it is reported and never mapped.
    refute_mapping "/projects/plugins/d"
}

@test "Guard 1: top-level siblings never produce a '/*' glob" {
    detect top-level-siblings
    [ "$status" -eq 0 ]
    refute_mapping "*"
    assert_mapping "composer: /a"
    assert_mapping "composer: /b"
    [[ $output == *"repository root"* ]]
}

# --- exclusions -----------------------------------------------------------

@test "hard-excluded directories are dropped silently" {
    detect excluded
    [ "$status" -eq 0 ]
    refute_mapping "node_modules"
    refute_mapping "vendor"
    [[ $output != *"node_modules"* ]]
}

@test "soft-excluded directories are dropped with a note" {
    detect excluded
    refute_mapping "examples"
    [[ $output == *"soft-excluded"* ]]
}

@test "--include re-admits a soft-excluded directory" {
    detect excluded --include examples
    [ "$status" -eq 0 ]
    assert_mapping "composer: /examples/demo"
}

# --- deferred ecosystems --------------------------------------------------

@test "deferred-ecosystem lockfiles are reported so partial coverage is not silent" {
    detect deferred-ecosystems
    [ "$status" -eq 0 ]
    [[ $output == *"Gemfile.lock"* ]]
    [[ $output == *"go.sum"* ]]
    [[ $output == *"Cargo.lock"* ]]
    [[ $output == *"poetry.lock"* ]]
    [[ $output == *"uv.lock"* ]]
    assert_mapping "composer: /"
}

# --- awkward paths --------------------------------------------------------

@test "paths with regex metacharacters and unicode survive translation" {
    detect weird-paths
    [ "$status" -eq 0 ]
    assert_mapping "composer: /my dir"
    assert_mapping "composer: /p+kg"
    assert_mapping "composer: /br[ack]et"
    assert_mapping "composer: /uni_café"
}

@test "a path containing the record delimiter is skipped with a note" {
    detect weird-paths
    [[ $output == *"containing '|'"* ]]
    refute_mapping "bad|pipe"
}

# --- mixed and empty ------------------------------------------------------

@test "a mixed monorepo maps the pnpm root and globs the composer plugins" {
    detect mixed-monorepo
    [ "$status" -eq 0 ]
    assert_mapping "npm: /"
    assert_mapping "composer: /projects/plugins/* (glob)"
    assert_mapping "github-actions: /"
}

@test "a repo with no manifests reports and exits clean" {
    detect no-manifests
    [ "$status" -eq 0 ]
    [[ $output == *"no npm, composer or github-actions manifests"* ]]
}

@test "workflows alone map github-actions at the root" {
    detect actions-only
    [ "$status" -eq 0 ]
    assert_mapping "github-actions: /"
    [ "$(mapping_count)" -eq 1 ]
}

# --- coverage of an existing config ---------------------------------------

@test "a fully covering singular entry produces no changes" {
    merge composer-single covered-singular.yml
    [ "$status" -eq 0 ]
    [[ $output == *"already covers every detected directory"* ]]
    [[ $output != *"would change"*[1-9]* ]]
}

@test "an existing glob covers the directories it expands to" {
    merge composer-siblings covered-glob.yml
    [ "$status" -eq 0 ]
    [[ $output == *"already mapped"* ]]
    [[ $output != *"+  - package-ecosystem"* ]]
}

@test "a target-branch entry does not count as coverage" {
    # Dependabot's security updates ignore target-branch entries, so counting
    # one as coverage would reintroduce the very bug this script exists to fix.
    merge composer-single target-branch.yml
    [ "$status" -eq 0 ]
    [[ $output == *'+  - package-ecosystem: "composer"'* ]]
}

@test "partial coverage appends only the gap and degrades the glob" {
    merge composer-siblings partial-commented.yml
    [ "$status" -eq 0 ]
    [[ $output == *"would overlap"* ]]
    [[ $output == *'directory: "/projects/plugins/b"'* ]]
    [[ $output == *'directory: "/projects/plugins/c"'* ]]
    # Overlapping entries are what make Dependabot reject a config outright.
    [[ $output != *'"/projects/plugins/*"'* ]]
}

@test "an existing entry we detected nothing for is reported, not removed" {
    merge composer-single stale-entry.yml
    [ "$status" -eq 0 ]
    [[ $output == *"matches nothing we detected"* ]]
    [[ $output != *"-  - package-ecosystem"* ]]
}

@test "comments and key order outside the appended region are preserved" {
    merge composer-siblings partial-commented.yml
    [ "$status" -eq 0 ]
    # An append-only text splice: nothing in the original may show as removed.
    [[ $output != *"-# Managed by the platform team"* ]]
    [[ $output != *"-  # the first plugin only"* ]]
}

@test "the file's own indentation is matched, not ours" {
    merge composer-single four-space-indent.yml
    [ "$status" -eq 0 ]
    [[ $output == *'+    - package-ecosystem: "composer"'* ]]
    [[ $output == *'+      directory: "/"'* ]]
}

@test "an updates key with no items is a valid append target" {
    merge composer-single empty-updates.yml
    [ "$status" -eq 0 ]
    [[ $output == *'+  - package-ecosystem: "composer"'* ]]
}

@test "a following top-level key is not swallowed by the append" {
    merge composer-single registries-after.yml
    [ "$status" -eq 0 ]
    [[ $output == *'+  - package-ecosystem: "composer"'* ]]
    [[ $output != *"-registries:"* ]]
}

# --- refusals -------------------------------------------------------------

@test "inline updates form is refused" {
    merge composer-single inline-updates.yml
    [ "$status" -eq 1 ]
    [[ $output == *"inline form"* ]]
}

@test "tab indentation is refused" {
    merge composer-single tab-indent.yml
    [ "$status" -eq 1 ]
    [[ $output == *"tabs"* ]]
}

@test "anchors and aliases are refused" {
    merge composer-single anchors.yml
    [ "$status" -eq 1 ]
    [[ $output == *"anchors"* ]]
}

@test "an unparseable config stops the run rather than appending blindly" {
    printf 'version: 2\nupdates:\n  - [oops\n' >"$BATS_TEST_TMPDIR/broken.yml"
    run "$SCRIPT" acme/widgets --paths-from-file "$TREES/composer-single.paths" \
        --existing-config "$BATS_TEST_TMPDIR/broken.yml" --dry-run
    [ "$status" -eq 1 ]
    # Never fall through to "nothing is covered, append everything".
    [[ $output != *"+  - package-ecosystem"* ]]
}

# --- entry template -------------------------------------------------------

@test "entries default to security-only" {
    merge composer-single empty-updates.yml
    [[ $output == *"open-pull-requests-limit: 0"* ]]
    [[ $output != *"groups:"* ]]
}

@test "--enable-version-updates swaps in the full house template" {
    merge composer-single empty-updates.yml --enable-version-updates
    [[ $output == *"open-pull-requests-limit: 10"* ]]
    [[ $output == *"composer-minor-patch:"* ]]
    [[ $output == *"composer-major:"* ]]
}

@test "generated entries carry the house cooldown" {
    merge composer-single empty-updates.yml
    [[ $output == *"cooldown:"* ]]
    [[ $output == *"default-days: 7"* ]]
}

# --- the YAML backend shim ------------------------------------------------

@test "every YAML backend available here agrees on the same file" {
    local backends=(
        "yq -o=json -I=0 ."
        "ruby -ryaml -rjson -e \"puts JSON.generate(YAML.safe_load(STDIN.read))\""
        "python3 -c \"import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin) or {}, sys.stdout)\""
    )
    local backend ran=0
    for backend in "${backends[@]}"; do
        printf 'a: [1, "x"]\n' | eval "$backend" >/dev/null 2>&1 || continue
        ran=$((ran + 1))
        DEPENDABOT_DIRS_YAML_CMD="$backend" run "$SCRIPT" acme/widgets \
            --paths-from-file "$TREES/composer-siblings.paths" \
            --existing-config "$CONFIGS/covered-glob.yml" --dry-run
        [ "$status" -eq 0 ]
        [[ $output == *"already mapped"* ]]
    done
    [ "$ran" -ge 1 ]
}

@test "an unusable YAML backend is rejected rather than silently ignored" {
    DEPENDABOT_DIRS_YAML_CMD="cat" run "$SCRIPT" acme/widgets \
        --paths-from-file "$TREES/composer-single.paths" \
        --existing-config "$CONFIGS/covered-singular.yml" --dry-run
    [ "$status" -eq 2 ]
    [[ $output == *"no working YAML reader"* ]]
}

# --- sanity cap -----------------------------------------------------------

@test "an implausible number of mappings stops the run unless forced" {
    local i
    : >"$BATS_TEST_TMPDIR/many.paths"
    for i in $(seq 1 60); do
        printf 'pkg%s/composer.json\npkg%s/composer.lock\n' "$i" "$i" \
            >>"$BATS_TEST_TMPDIR/many.paths"
    done
    run "$SCRIPT" acme/widgets --paths-from-file "$BATS_TEST_TMPDIR/many.paths" --detect-only
    [ "$status" -eq 1 ]
    [[ $output == *"sanity cap"* ]]

    run "$SCRIPT" acme/widgets --paths-from-file "$BATS_TEST_TMPDIR/many.paths" --detect-only --force
    [ "$status" -eq 0 ]
}
