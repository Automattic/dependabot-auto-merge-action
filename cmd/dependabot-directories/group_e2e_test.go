package main

// Ports of the bats grouping, guard, awkward-path and sanity-cap tests.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
