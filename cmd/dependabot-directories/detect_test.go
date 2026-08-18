package main

// Ports of the bats detection tests, one for one, driving the real CLI over
// the tree fixtures in --detect-only mode.

import (
	"strings"
	"testing"
)

// --- npm detection ----------------------------------------------------------

func TestRootNpmRepoMapsTheRootOnce(t *testing.T) {
	code, out := detectFixture(t, "root-npm")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	assertMapping(t, out, "github-actions: /")
	if n := mappingCount(out); n != 2 {
		t.Errorf("mapping count = %d, want 2\noutput:\n%s", n, out)
	}
}

func TestYarnWorkspacesMapOnlyTheRootNotEveryPackage(t *testing.T) {
	code, out := detectFixture(t, "yarn-workspaces")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	// The rule that prevents per-package entry spam in hoisted monorepos.
	refuteMapping(t, out, "/packages/a")
}

func TestAWorkspaceCoveredPackageWithItsOwnLockfileIsReportedNotMapped(t *testing.T) {
	_, out := detectFixture(t, "yarn-workspaces")
	refuteMapping(t, out, "/packages/b")
	assertContains(t, out, "shadowed by the workspace")
	assertNoted(t, out, "/packages/b")
}

func TestAnUncoveredManifestWithNoLockfileIsReportedNotMapped(t *testing.T) {
	_, out := detectFixture(t, "yarn-workspaces")
	refuteMapping(t, out, "/tools/helper")
	assertContains(t, out, "no lockfile and no workspace covering them")
	assertNoted(t, out, "/tools/helper")
}

func TestYarnV1ObjectFormWorkspacesAreParsed(t *testing.T) {
	code, out := detectFixture(t, "workspaces-object-form")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	if n := mappingCount(out); n != 1 {
		t.Errorf("mapping count = %d, want 1\noutput:\n%s", n, out)
	}
	// Parsed means covered: neither package may surface as an entry or a
	// finding.
	refuteNoted(t, out, "/packages/a")
	refuteNoted(t, out, "/packages/b")
}

func TestANegatedWorkspacePatternLeavesThatPackageToFendForItself(t *testing.T) {
	code, out := detectFixture(t, "workspaces-negation")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	// Excluded from the workspace and holding its own lockfile, so it
	// needs an entry.
	assertMapping(t, out, "npm: /packages/legacy")
}

func TestGlobstarCoversTheZeroSegmentCase(t *testing.T) {
	code, out := detectFixture(t, "workspaces-globstar")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	// apps/**/web must match apps/web as well as apps/deep/nested/web.
	refuteNoted(t, out, "/apps/web")
	refuteNoted(t, out, "/apps/deep/nested/web")
	// Outside the pattern, so it is still reported.
	assertNoted(t, out, "/other/thing")
}

func TestAnUnrecognisedWorkspacesShapeIsReportedRatherThanAssumedAbsent(t *testing.T) {
	code, out := detectFixture(t, "workspaces-unknown-shape")
	assertExit(t, code, 0, out)
	assertContains(t, out, "not a shape we recognise")
	assertMapping(t, out, "npm: /")
}

func TestPnpmWorkspaceYamlPackagesAreHonoured(t *testing.T) {
	code, out := detectFixture(t, "pnpm")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	if n := mappingCount(out); n != 1 {
		t.Errorf("mapping count = %d, want 1\noutput:\n%s", n, out)
	}
}

func TestAPnpmWorkspaceWithNoPackagesKeyIsReported(t *testing.T) {
	code, out := detectFixture(t, "pnpm-no-packages-key")
	assertExit(t, code, 0, out)
	assertContains(t, out, "declares no 'packages:'")
	assertMapping(t, out, "npm: /")
}

// --- composer detection -----------------------------------------------------

func TestComposerNeedsBothAManifestAndALock(t *testing.T) {
	code, out := detectFixture(t, "composer-single")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "composer: /")
}

// --- exclusions -------------------------------------------------------------

func TestHardExcludedDirectoriesAreDroppedSilently(t *testing.T) {
	code, out := detectFixture(t, "excluded")
	assertExit(t, code, 0, out)
	refuteMapping(t, out, "node_modules")
	refuteMapping(t, out, "vendor")
	if strings.Contains(out, "node_modules") {
		t.Errorf("hard exclusions must be silent\noutput:\n%s", out)
	}
}

func TestSoftExcludedDirectoriesAreDroppedWithANote(t *testing.T) {
	_, out := detectFixture(t, "excluded")
	refuteMapping(t, out, "examples")
	assertContains(t, out, "soft-excluded")
}

func TestIncludeReadmitsASoftExcludedDirectory(t *testing.T) {
	code, out := detectFixture(t, "excluded", "--include", "examples")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "composer: /examples/demo")
}

func TestIncludeEqualsFormIsAccepted(t *testing.T) {
	code, out := detectFixture(t, "excluded", "--include=examples")
	assertExit(t, code, 0, out)
}

// --- deferred ecosystems ----------------------------------------------------

func TestDeferredEcosystemLockfilesAreReported(t *testing.T) {
	code, out := detectFixture(t, "deferred-ecosystems")
	assertExit(t, code, 0, out)
	for _, lock := range []string{"Gemfile.lock", "go.sum", "Cargo.lock", "poetry.lock", "uv.lock"} {
		assertContains(t, out, lock)
	}
	assertMapping(t, out, "composer: /")
}

// --- mixed and empty --------------------------------------------------------

func TestARepoWithNoManifestsReportsAndExitsClean(t *testing.T) {
	code, out := detectFixture(t, "no-manifests")
	assertExit(t, code, 0, out)
	assertContains(t, out, "no npm, composer or github-actions manifests")
}

func TestWorkflowsAloneMapGithubActionsAtTheRoot(t *testing.T) {
	code, out := detectFixture(t, "actions-only")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "github-actions: /")
	if n := mappingCount(out); n != 1 {
		t.Errorf("mapping count = %d, want 1\noutput:\n%s", n, out)
	}
}
