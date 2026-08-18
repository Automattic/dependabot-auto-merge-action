package main

// Ports of the bats coverage, refusal and template tests, plus the three
// yaml.v3-era tests that replace the two bats tests of the deleted YAML
// backend shim.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// merge mirrors the bats helper: detect a tree and merge against an existing
// config, in --dry-run mode.
func merge(t *testing.T, tree, cfg string, extra ...string) (int, string) {
	t.Helper()
	args := append([]string{
		"acme/widgets",
		"--paths-from-file", "testdata/trees/" + tree + ".paths",
		"--existing-config", "testdata/dependabot/" + cfg,
		"--dry-run",
	}, extra...)
	return execute(t, args...)
}

func refuteContains(t *testing.T, output, fragment string) {
	t.Helper()
	if strings.Contains(output, fragment) {
		t.Errorf("output must not contain %q\noutput:\n%s", fragment, output)
	}
}

// --- coverage of an existing config -----------------------------------------

func TestAFullyCoveringSingularEntryProducesNoChanges(t *testing.T) {
	code, out := merge(t, "composer-single", "covered-singular.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, "already covers every detected directory")
	assertContains(t, out, "0 would change")
}

func TestAnExistingGlobCoversTheDirectoriesItExpandsTo(t *testing.T) {
	code, out := merge(t, "composer-siblings", "covered-glob.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, "already mapped")
	refuteContains(t, out, "+  - package-ecosystem")
}

func TestATargetBranchEntryDoesNotCountAsCoverage(t *testing.T) {
	// Dependabot's security updates ignore target-branch entries, so
	// counting one as coverage would reintroduce the very bug this tool
	// exists to fix.
	code, out := merge(t, "composer-single", "target-branch.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+  - package-ecosystem: "composer"`)
}

func TestPartialCoverageAppendsOnlyTheGapAndDegradesTheGlob(t *testing.T) {
	code, out := merge(t, "composer-siblings", "partial-commented.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, "would overlap")
	assertContains(t, out, `directory: "/projects/plugins/b"`)
	assertContains(t, out, `directory: "/projects/plugins/c"`)
	// Overlapping entries are what make Dependabot reject a config outright.
	refuteContains(t, out, `"/projects/plugins/*"`)
}

func TestAnExistingEntryWeDetectedNothingForIsReportedNotRemoved(t *testing.T) {
	code, out := merge(t, "composer-single", "stale-entry.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, "matches nothing we detected")
	refuteContains(t, out, "-  - package-ecosystem")
}

func TestCommentsAndKeyOrderOutsideTheAppendedRegionArePreserved(t *testing.T) {
	code, out := merge(t, "composer-siblings", "partial-commented.yml")
	assertExit(t, code, 0, out)
	// An append-only text splice: nothing in the original may show as
	// removed.
	refuteContains(t, out, "-# Managed by the platform team")
	refuteContains(t, out, "-  # the first plugin only")
}

func TestTheFilesOwnIndentationIsMatchedNotOurs(t *testing.T) {
	code, out := merge(t, "composer-single", "four-space-indent.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+    - package-ecosystem: "composer"`)
	assertContains(t, out, `+      directory: "/"`)
}

func TestAnUpdatesKeyWithNoItemsIsAValidAppendTarget(t *testing.T) {
	code, out := merge(t, "composer-single", "empty-updates.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+  - package-ecosystem: "composer"`)
}

func TestAFollowingTopLevelKeyIsNotSwallowedByTheAppend(t *testing.T) {
	code, out := merge(t, "composer-single", "registries-after.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+  - package-ecosystem: "composer"`)
	refuteContains(t, out, "-registries:")
}

// --- refusals ---------------------------------------------------------------

func TestInlineUpdatesFormIsRefused(t *testing.T) {
	code, out := merge(t, "composer-single", "inline-updates.yml")
	assertExit(t, code, 1, out)
	assertContains(t, out, "inline form")
}

func TestTabIndentationIsRefused(t *testing.T) {
	code, out := merge(t, "composer-single", "tab-indent.yml")
	assertExit(t, code, 1, out)
	assertContains(t, out, "tabs")
}

func TestAnchorsAndAliasesAreRefused(t *testing.T) {
	code, out := merge(t, "composer-single", "anchors.yml")
	assertExit(t, code, 1, out)
	assertContains(t, out, "anchors")
}

func TestAnUnparseableConfigStopsTheRunRatherThanAppendingBlindly(t *testing.T) {
	broken := filepath.Join(t.TempDir(), "broken.yml")
	if err := os.WriteFile(broken, []byte("version: 2\nupdates:\n  - [oops\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out := execute(t, "acme/widgets",
		"--paths-from-file", "testdata/trees/composer-single.paths",
		"--existing-config", broken, "--dry-run")
	assertExit(t, code, 1, out)
	// Never fall through to "nothing is covered, append everything".
	refuteContains(t, out, "+  - package-ecosystem")
}

// --- entry template ---------------------------------------------------------

func TestEntriesDefaultToSecurityOnly(t *testing.T) {
	_, out := merge(t, "composer-single", "empty-updates.yml")
	assertContains(t, out, "open-pull-requests-limit: 0")
	refuteContains(t, out, "groups:")
}

func TestEnableVersionUpdatesSwapsInTheFullHouseTemplate(t *testing.T) {
	_, out := merge(t, "composer-single", "empty-updates.yml", "--enable-version-updates")
	assertContains(t, out, "open-pull-requests-limit: 10")
	assertContains(t, out, "composer-minor-patch:")
	assertContains(t, out, "composer-major:")
}

func TestGeneratedEntriesCarryTheHouseCooldown(t *testing.T) {
	_, out := merge(t, "composer-single", "empty-updates.yml")
	assertContains(t, out, "cooldown:")
	assertContains(t, out, "default-days: 7")
}

// --- yaml.v3-era replacements for the backend-shim tests --------------------

func TestCRLFLineEndingsSurviveTheSpliceByteForByte(t *testing.T) {
	// The splice splits on \n alone, so the \r bytes of a CRLF file ride
	// along unchanged — the diff's context lines prove it.
	code, out := merge(t, "composer-single", "crlf.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+  - package-ecosystem: "composer"`)
	assertContains(t, out, "directory: \"/somewhere/else\"\r\n")
	assertContains(t, out, "matches nothing we detected")
}

func TestAMissingTrailingNewlineIsNormalizedNotDuplicated(t *testing.T) {
	code, out := merge(t, "composer-single", "no-trailing-newline.yml")
	assertExit(t, code, 0, out)
	assertContains(t, out, `+  - package-ecosystem: "composer"`)
	// Both diff inputs end in exactly one newline, so diff never marks one.
	refuteContains(t, out, "No newline")
}

func TestDuplicateMappingKeysAreRefused(t *testing.T) {
	// The bash shim's backends silently took the last value; yaml.v3
	// refuses, which is the fail-closed direction the spec demands.
	dup := filepath.Join(t.TempDir(), "dup.yml")
	if err := os.WriteFile(dup, []byte("version: 2\nversion: 3\nupdates:\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out := execute(t, "acme/widgets",
		"--paths-from-file", "testdata/trees/composer-single.paths",
		"--existing-config", dup, "--dry-run")
	assertExit(t, code, 1, out)
	assertContains(t, out, "cannot parse")
	refuteContains(t, out, "+  - package-ecosystem")
}
