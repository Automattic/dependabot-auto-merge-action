package dependabotyml

import (
	"fmt"
	"strings"

	"github.com/Automattic/dependabot-auto-merge-action/internal/detect"
)

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
