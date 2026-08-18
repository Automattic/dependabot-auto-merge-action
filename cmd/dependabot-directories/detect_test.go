package main

// Ports of the bats detection tests, one for one, driving the real CLI over
// the tree fixtures in --detect-only mode.

import (
	"fmt"
	"os"
	"path/filepath"
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

// Ports of the bats grouping, guard, awkward-path and sanity-cap tests.

func TestSiblingComposerPackagesCollapseIntoOneGlob(t *testing.T) {
	code, out := detectFixture(t, "composer-siblings")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "composer: /projects/plugins/* (glob)")
	if n := mappingCount(out); n != 1 {
		t.Errorf("mapping count = %d, want 1\noutput:\n%s", n, out)
	}
}

func TestGuard2AGlobThatWouldSweepAnUnmappedSiblingDegradesToSingulars(t *testing.T) {
	code, out := detectFixture(t, "composer-siblings-lockless")
	assertExit(t, code, 0, out)
	refuteMapping(t, out, "*")
	assertMapping(t, out, "composer: /projects/plugins/a")
	assertMapping(t, out, "composer: /projects/plugins/b")
	assertMapping(t, out, "composer: /projects/plugins/c")
	assertContains(t, out, "did not map")
	// d has a manifest but no lock, so it is reported and never mapped.
	refuteMapping(t, out, "/projects/plugins/d")
}

func TestGuard1TopLevelSiblingsNeverProduceARootGlob(t *testing.T) {
	code, out := detectFixture(t, "top-level-siblings")
	assertExit(t, code, 0, out)
	refuteMapping(t, out, "*")
	assertMapping(t, out, "composer: /a")
	assertMapping(t, out, "composer: /b")
	assertContains(t, out, "repository root")
}

// --- awkward paths ----------------------------------------------------------

func TestPathsWithRegexMetacharactersAndUnicodeSurviveTranslation(t *testing.T) {
	code, out := detectFixture(t, "weird-paths")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "composer: /my dir")
	assertMapping(t, out, "composer: /p+kg")
	assertMapping(t, out, "composer: /br[ack]et")
	assertMapping(t, out, "composer: /uni_café")
}

func TestAPathContainingAPipeIsProcessedLikeAnyOther(t *testing.T) {
	// The bash script skipped these paths to protect its '|'-delimited
	// record format and said so with a note. The record format is gone, so
	// the pipe directory flows through detection like any other: it holds
	// a composer.json with no lock, which lands it in that note group.
	_, out := detectFixture(t, "weird-paths")
	if strings.Contains(out, "containing '|'") {
		t.Errorf("the record-format skip note must be gone\noutput:\n%s", out)
	}
	refuteMapping(t, out, "bad|pipe")
	assertNoted(t, out, "/bad|pipe")
}

// --- mixed ------------------------------------------------------------------

func TestAMixedMonorepoMapsThePnpmRootAndGlobsTheComposerPlugins(t *testing.T) {
	code, out := detectFixture(t, "mixed-monorepo")
	assertExit(t, code, 0, out)
	assertMapping(t, out, "npm: /")
	assertMapping(t, out, "composer: /projects/plugins/* (glob)")
	assertMapping(t, out, "github-actions: /")
}

// --- sanity cap -------------------------------------------------------------

func TestAnImplausibleNumberOfMappingsStopsTheRunUnlessForced(t *testing.T) {
	var tree strings.Builder
	for i := 1; i <= 60; i++ {
		fmt.Fprintf(&tree, "pkg%d/composer.json\npkg%d/composer.lock\n", i, i)
	}
	pathsFile := filepath.Join(t.TempDir(), "many.paths")
	if err := os.WriteFile(pathsFile, []byte(tree.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	code, out := execute(t, "acme/widgets", "--paths-from-file", pathsFile, "--detect-only")
	assertExit(t, code, 1, out)
	assertContains(t, out, "sanity cap")

	code, out = execute(t, "acme/widgets", "--paths-from-file", pathsFile, "--detect-only", "--force")
	assertExit(t, code, 0, out)
}
