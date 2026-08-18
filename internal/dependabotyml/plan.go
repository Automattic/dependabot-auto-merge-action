package dependabotyml

import (
	"fmt"
	"strings"

	"github.com/Automattic/dependabot-auto-merge-action/internal/detect"
	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

// PlanMissing decides what is missing, one detected block at a time. A glob
// whose members are only PARTLY mapped already is degraded to singular
// entries for the unmapped members: emitting the glob would overlap the
// existing entry, and overlapping entries are exactly what makes Dependabot
// reject a config file outright.
func PlanMissing(blocks []detect.Block, entries []CoverageEntry, rep *report.Reporter) []detect.Block {
	var missing []detect.Block
	for _, b := range blocks {
		if Covers(entries, b.Eco, b.Dir) {
			rep.OK(fmt.Sprintf("%s %s: already mapped", b.Eco, b.Dir))
			continue
		}
		if !b.IsGlob {
			missing = append(missing, b)
			continue
		}

		coveredN := 0
		var uncovered []string
		for _, m := range b.Members {
			if Covers(entries, b.Eco, m) {
				coveredN++
			} else {
				uncovered = append(uncovered, m)
			}
		}
		switch {
		case len(uncovered) == 0:
			rep.OK(fmt.Sprintf("%s %s: already mapped", b.Eco, b.Dir))
		case coveredN == 0:
			missing = append(missing, b)
		default:
			rep.Note(fmt.Sprintf("%s: '%s' would overlap %d %s already in the file — adding the %d unmapped %s singly instead",
				b.Eco, b.Dir, coveredN, report.Plural(coveredN, "entry", "entries"),
				len(uncovered), report.Plural(len(uncovered), "directory", "directories")))
			for _, m := range uncovered {
				missing = append(missing, detect.Block{Eco: b.Eco, Dir: m})
			}
		}
	}
	return missing
}

// BuildProposal renders the missing blocks, reports each as a would-change,
// and splices them into the existing file after the last line of the
// updates: block. The returned current is nil when no file exists — the
// diff's "a" side is /dev/null then. Normalization mirrors the bash
// $(cat)/printf pair: all trailing newlines collapse to exactly one, and
// nothing else changes — CR bytes included.
func BuildProposal(raw string, present bool, missing []detect.Block, item, child string, versionUpdates bool, rep *report.Reporter) (current *string, proposed string) {
	var rendered strings.Builder
	for _, b := range missing {
		rendered.WriteString(RenderBlock(b, item, child, versionUpdates))
		rep.Would(fmt.Sprintf("map %s -> %s", b.Eco, b.Dir))
	}

	if !present {
		return nil, "version: 2\nupdates:\n" + rendered.String()
	}

	normalized := strings.TrimRight(raw, "\n") + "\n"
	// Split on \n alone, never a \r-trimming scanner: CRLF files must come
	// through the splice byte-identical outside the appended region.
	lines := strings.Split(normalized, "\n")
	insert := InsertionLine(lines)

	var out strings.Builder
	for i := 0; i < insert; i++ {
		out.WriteString(lines[i])
		out.WriteString("\n")
	}
	out.WriteString(rendered.String())
	for i := insert; i < len(lines)-1; i++ { // len-1 skips the final split artifact
		out.WriteString(lines[i])
		out.WriteString("\n")
	}
	return &normalized, out.String()
}

// InsertionLine returns the 1-based number of the last line of the updates:
// block — the line new entries are appended after. Blank lines do not extend
// the block (a trailing gap belongs to whatever follows), comments inside it
// do, and the next top-level key ends it.
func InsertionLine(lines []string) int {
	last := 0
	seen := false
	for n, line := range lines {
		if !seen {
			if updatesKeyRe.MatchString(line) {
				seen = true
				last = n + 1
			}
			continue
		}
		switch {
		case strings.TrimSpace(line) == "":
			// blank: skip without advancing
		case strings.HasPrefix(strings.TrimLeft(line, " \t"), "#"):
			last = n + 1
		case len(line) > 0 && line[0] != ' ' && line[0] != '\t':
			return last
		default:
			last = n + 1
		}
	}
	return last
}

// RenderBlock renders one update entry in the repo's house style, matching
// the indentation detected from the existing file.
func RenderBlock(b detect.Block, item, child string, versionUpdates bool) string {
	var out strings.Builder
	// Values are spliced into the quotes verbatim, as the bash printf did —
	// %q would escape Go-style and drift from the transcripts.
	fmt.Fprintf(&out, "%s- package-ecosystem: \"%s\"\n", item, b.Eco)
	if b.IsGlob {
		fmt.Fprintf(&out, "%sdirectories:\n", child)
		fmt.Fprintf(&out, "%s  - \"%s\"\n", child, b.Dir)
	} else {
		fmt.Fprintf(&out, "%sdirectory: \"%s\"\n", child, b.Dir)
	}
	fmt.Fprintf(&out, "%sschedule:\n", child)
	fmt.Fprintf(&out, "%s  interval: \"weekly\"\n", child)
	fmt.Fprintf(&out, "%s  day: \"monday\"\n", child)
	if versionUpdates {
		fmt.Fprintf(&out, "%sopen-pull-requests-limit: 10\n", child)
		fmt.Fprintf(&out, "%sgroups:\n", child)
		fmt.Fprintf(&out, "%s  %s-minor-patch:\n", child, b.Eco)
		fmt.Fprintf(&out, "%s    patterns:\n", child)
		fmt.Fprintf(&out, "%s      - \"*\"\n", child)
		fmt.Fprintf(&out, "%s    update-types:\n", child)
		fmt.Fprintf(&out, "%s      - \"minor\"\n", child)
		fmt.Fprintf(&out, "%s      - \"patch\"\n", child)
		fmt.Fprintf(&out, "%s  %s-major:\n", child, b.Eco)
		fmt.Fprintf(&out, "%s    patterns:\n", child)
		fmt.Fprintf(&out, "%s      - \"*\"\n", child)
		fmt.Fprintf(&out, "%s    update-types:\n", child)
		fmt.Fprintf(&out, "%s      - \"major\"\n", child)
	} else {
		// Security updates need the directory mapping; version-update PRs
		// are noise the repo owner did not ask for.
		fmt.Fprintf(&out, "%sopen-pull-requests-limit: 0\n", child)
	}
	fmt.Fprintf(&out, "%scooldown:\n", child)
	fmt.Fprintf(&out, "%s  default-days: 7\n", child)
	return out.String()
}
