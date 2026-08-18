package main

import (
	"fmt"
	"io"

	"github.com/Automattic/dependabot-auto-merge-action/internal/dependabotyml"
	"github.com/Automattic/dependabot-auto-merge-action/internal/detect"
	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
	"github.com/Automattic/dependabot-auto-merge-action/internal/source"
)

// maxPairs caps the mappings a single run may emit. A repo yielding more is
// far more likely a detection bug than a real configuration; --force
// overrides.
const maxPairs = 50

// runPipeline is the run itself, after the command line has been validated:
// list paths, exclude, detect, group, report, and (outside --detect-only)
// plan the config change. Returns the process exit code.
func runPipeline(opts options, stdout, stderr io.Writer) int {
	rep := report.New(stdout, stderr)

	// The gh-backed source lands in a later commit; until then the offline
	// seam is the only tree.
	if opts.pathsFromFile == "" {
		fmt.Fprintf(stderr, "error: remote detection is not wired up yet — run with --paths-from-file for now\n")
		return 2
	}
	tree := source.FixtureTree{PathsFile: opts.pathsFromFile}

	fmt.Fprintf(stdout, "Scanning %s\n\n", opts.repo)

	paths, err := tree.ListPaths()
	if err != nil {
		rep.Fail(fmt.Sprintf("cannot read the file list: %v", err))
		return 1
	}

	// Guard 2 compares candidate globs against these UNFILTERED manifest
	// lists: the glob GitHub expands knows nothing about our exclusions.
	rawNpm := detect.DirsOf(detect.WithBasenames(paths, "package.json"))
	rawComposer := detect.DirsOf(detect.WithBasenames(paths, "composer.json"))

	kept, soft := detect.SplitExclusions(paths, opts.include)
	if len(soft) > 0 {
		rep.Note(fmt.Sprintf("skipped %d path(s) under a soft-excluded directory (dist, examples, fixtures, ...) — use --include <dir> to keep one", len(soft)))
	}

	pairs := detect.Npm(kept, tree, rep)
	pairs = append(pairs, detect.Composer(kept, rep)...)
	pairs = append(pairs, detect.Actions(kept)...)
	detect.Deferred(kept, rep)

	blocks := detect.Group(pairs, rawNpm, rawComposer, rep)

	if len(blocks) == 0 {
		rep.Note(fmt.Sprintf("no npm, composer or github-actions manifests detected in %s", opts.repo))
		fmt.Fprintln(stdout)
		rep.Summary()
		return 0
	}

	if len(blocks) > maxPairs && !opts.force {
		rep.Fail(fmt.Sprintf("detected %d mappings, past the sanity cap of %d — this is far more likely a detection bug than a real layout. Re-run with --force to proceed.", len(blocks), maxPairs))
		fmt.Fprintln(stdout)
		rep.Summary()
		return 1
	}

	fmt.Fprintln(stdout, "Detected mappings:")
	for _, b := range blocks {
		if b.IsGlob {
			rep.Detected(fmt.Sprintf("%s: %s (glob)", b.Eco, b.Dir))
		} else {
			rep.Detected(fmt.Sprintf("%s: %s", b.Eco, b.Dir))
		}
	}
	fmt.Fprintln(stdout)

	if opts.detectOnly {
		rep.Summary()
		if rep.FailCount > 0 {
			return 1
		}
		return 0
	}

	// --dry-run from here: read the existing config, plan the gap, print
	// the diff. A structural refusal stops the run without a summary, the
	// same hard stop the bash script made.
	raw, present := "", false
	if opts.existingConfigFile != "" {
		var err error
		raw, present, err = source.FixtureConfig{Path: opts.existingConfigFile}.ReadConfig()
		if err != nil {
			rep.Fail(err.Error())
			return 1
		}
	}
	// Offline runs without --existing-config treat the config as absent;
	// the gh-backed read lands in a later commit.

	item, child := "  ", "    "
	var entries []dependabotyml.CoverageEntry
	if present {
		if err := dependabotyml.CheckShape(raw); err != nil {
			rep.Fail(err.Error())
			return 1
		}
		item, child = dependabotyml.DetectIndentation(raw)
		var err error
		entries, err = dependabotyml.ParseCoverage(raw)
		if err != nil {
			rep.Fail(err.Error())
			return 1
		}
	}

	missing := dependabotyml.PlanMissing(blocks, entries, rep)
	for _, note := range dependabotyml.StaleNotes(entries, pairs) {
		rep.Note(note)
	}

	if len(missing) == 0 {
		rep.OK(dependabotyml.Path + " already covers every detected directory")
	} else {
		current, proposed := dependabotyml.BuildProposal(raw, present, missing, item, child, opts.enableVersionUpdates, rep)
		fmt.Fprintln(stdout)
		dependabotyml.UnifiedDiff(current, proposed, stdout, stderr)
	}

	fmt.Fprintln(stdout)
	rep.Summary()
	if rep.FailCount > 0 {
		return 1
	}
	return 0
}
