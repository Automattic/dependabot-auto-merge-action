package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// --- the existing dependabot.yml --------------------------------------------
//
// Reading what the file already covers, deciding what is missing, and
// rendering the append. The merge is an append-only text splice — never a
// YAML round-trip, which would destroy comments and reorder keys — so
// parsing here is read-only and the structural shape checks stay text-level.

// configPath is where Dependabot reads its configuration. Nowhere else — a .yaml
// sibling is a trap the caller checks for separately.
const configPath = ".github/dependabot.yml"

// CoverageEntry is one (ecosystem, directory) an existing config maps. The
// directory is verbatim from the file; Covers normalizes when matching.
type CoverageEntry struct {
	Eco, Dir string
}

// The five structural refusals, as line-oriented patterns like the greps
// they replace. Line-oriented matters: (?m) anchors interact with \r and
// final newlines differently than grep does.
var (
	contentLineRe = regexp.MustCompile(`^[[:space:]]*[^[:space:]#]`)
	tabIndentRe   = regexp.MustCompile(`^\t| \t|\t `)
	docMarkerRe   = regexp.MustCompile(`^(---|\.\.\.)[[:space:]]*$`)
	anchorRe      = regexp.MustCompile(`(^|[[:space:]])[&*][A-Za-z0-9_-]+|<<:`)
	inlineRe      = regexp.MustCompile(`^updates:[[:space:]]*[\[{]`)
	updatesKeyRe  = regexp.MustCompile(`^updates:[[:space:]]*(#.*)?$`)

	itemLineRe  = regexp.MustCompile(`^[[:space:]]*-[[:space:]]+package-ecosystem:`)
	childKeyRe  = regexp.MustCompile(`^[[:space:]]+(schedule|directory|directories|open-pull-requests-limit|cooldown|groups|target-branch):`)
	globCharsRe = regexp.MustCompile(`[*?]`)
)

// CheckShape refuses to text-splice a file whose structure cannot be
// reasoned about. Each refusal names the fix; none of them is guessed
// around.
func CheckShape(raw string) error {
	all := strings.Split(raw, "\n")

	hasContent, hasTabIndent := false, false
	docMarkers := 0
	for _, line := range all {
		if contentLineRe.MatchString(line) {
			hasContent = true
		}
		if tabIndentRe.MatchString(line) {
			hasTabIndent = true
		}
		if docMarkerRe.MatchString(line) {
			docMarkers++
		}
	}
	if hasContent && hasTabIndent {
		return fmt.Errorf("%s indents with tabs, which YAML forbids — fix it by hand", configPath)
	}
	if docMarkers > 1 {
		return fmt.Errorf("%s holds more than one YAML document — fix it by hand", configPath)
	}
	for _, line := range all {
		if anchorRe.MatchString(line) {
			return fmt.Errorf("%s uses YAML anchors, aliases or merge keys — an append-only text edit cannot reason about those", configPath)
		}
	}
	hasUpdates := false
	for _, line := range all {
		if inlineRe.MatchString(line) {
			return fmt.Errorf("%s declares updates in inline form — convert it to a block sequence first", configPath)
		}
		if updatesKeyRe.MatchString(line) {
			hasUpdates = true
		}
	}
	if !hasUpdates {
		return fmt.Errorf("%s has no top-level 'updates:' key — fix it by hand", configPath)
	}
	return nil
}

// DetectIndentation matches the file's own indentation rather than imposing
// ours: the item indent from the first entry's dash, the child indent from
// the first child key when there is one — prefer what the file actually does
// over what the dash implies.
func DetectIndentation(raw string) (item, child string) {
	item, child = "  ", "    "

	afterUpdates := false
	itemFound := false
	for _, line := range strings.Split(raw, "\n") {
		if !afterUpdates {
			afterUpdates = strings.HasPrefix(line, "updates:")
			continue
		}
		if !itemFound && itemLineRe.MatchString(line) {
			itemFound = true
			item = leadingSpace(line)
			rest := line[len(item)+1:] // past the dash
			gap := leadingSpace(rest)
			child = item + " " + strings.Repeat(" ", len(gap))
		}
		if itemFound && childKeyRe.MatchString(line) {
			child = leadingSpace(line)
			break
		}
	}
	return item, child
}

func leadingSpace(line string) string {
	return line[:len(line)-len(strings.TrimLeft(line, " \t"))]
}

// ParseCoverage lists the (ecosystem, directory) records the file already
// maps. Entries carrying target-branch are skipped: Dependabot's security
// updates ignore them, so counting one as coverage would reintroduce the
// exact bug this tool exists to fix.
func ParseCoverage(raw string) ([]CoverageEntry, error) {
	var doc any
	if yaml.Unmarshal([]byte(raw), &doc) != nil {
		return nil, fmt.Errorf("cannot parse %s as YAML — refusing to guess at what it already covers", configPath)
	}

	var updates any
	switch m := doc.(type) {
	case nil:
		return nil, nil
	case map[string]any:
		updates = m["updates"]
	default:
		return nil, fmt.Errorf("cannot read the update entries in %s", configPath)
	}

	var list []any
	switch u := updates.(type) {
	case nil:
		return nil, nil
	case []any:
		list = u
	default:
		return nil, fmt.Errorf("%s has an 'updates' key that is not a list — fix it by hand", configPath)
	}

	var entries []CoverageEntry
	for _, item := range list {
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("cannot read the update entries in %s", configPath)
		}
		if entry["target-branch"] != nil {
			continue
		}
		eco := "?"
		if v := entry["package-ecosystem"]; v != nil {
			eco = fmt.Sprint(v)
		}
		if dirs, ok := entry["directories"].([]any); ok {
			for _, d := range dirs {
				entries = append(entries, CoverageEntry{Eco: eco, Dir: fmt.Sprint(d)})
			}
		}
		if d := entry["directory"]; d != nil {
			entries = append(entries, CoverageEntry{Eco: eco, Dir: fmt.Sprint(d)})
		}
	}
	return entries, nil
}

// Covers reports whether (eco, dir) is already mapped. An existing glob
// entry counts: matching it beats emitting a duplicate Dependabot would
// reject the config over.
func Covers(entries []CoverageEntry, eco, dir string) bool {
	for _, e := range entries {
		if e.Eco != eco {
			continue
		}
		exDir := NormalizeDir(e.Dir)
		if exDir == dir {
			return true
		}
		if globCharsRe.MatchString(exDir) && GlobToRegexp(exDir).MatchString(dir) {
			return true
		}
	}
	return false
}

// StaleNotes reports existing entries pointing at directories detection
// found no manifest in. Compared against the detected pairs rather than the
// rendered blocks: a directory folded into a glob is still very much
// detected. Glob entries are never called stale.
func StaleNotes(entries []CoverageEntry, pairs []Pair) []string {
	if len(entries) == 0 {
		return nil
	}
	detected := make(map[string]bool, len(pairs))
	for _, p := range pairs {
		detected[p.Eco+"|"+p.Dir] = true
	}
	var notes []string
	for _, e := range entries {
		if globCharsRe.MatchString(e.Dir) {
			continue
		}
		dir := NormalizeDir(e.Dir)
		if !detected[e.Eco+"|"+dir] {
			notes = append(notes, fmt.Sprintf("existing entry (%s, %s) matches nothing we detected — left alone", e.Eco, dir))
		}
	}
	return notes
}

// PlanMissing decides what is missing, one detected block at a time. A glob
// whose members are only PARTLY mapped already is degraded to singular
// entries for the unmapped members: emitting the glob would overlap the
// existing entry, and overlapping entries are exactly what makes Dependabot
// reject a config file outright.
func PlanMissing(blocks []Block, entries []CoverageEntry, rep *Reporter) []Block {
	var missing []Block
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
				b.Eco, b.Dir, coveredN, Plural(coveredN, "entry", "entries"),
				len(uncovered), Plural(len(uncovered), "directory", "directories")))
			for _, m := range uncovered {
				missing = append(missing, Block{Eco: b.Eco, Dir: m})
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
func BuildProposal(raw string, present bool, missing []Block, item, child string, versionUpdates bool, rep *Reporter) (current *string, proposed string) {
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
func RenderBlock(b Block, item, child string, versionUpdates bool) string {
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

// UnifiedDiff shows current vs proposed through diff -u, the same rendering
// the bash script used — matching another implementation's hunk headers and
// context selection byte-for-byte is exactly the risk exec avoids. Both
// sides always end in one newline (BuildProposal normalizes), so diff never
// emits "\ No newline at end of file" markers. A missing current diffs
// against /dev/null. Exit status 1 is "differences found"; any real failure
// has already written to stderr, matching the script's `|| true`.
func UnifiedDiff(current *string, proposed string, stdout, stderr io.Writer) {
	dir, err := os.MkdirTemp("", "dependabot-directories")
	if err != nil {
		io.WriteString(stderr, "cannot create a temp dir for diff: "+err.Error()+"\n")
		return
	}
	defer os.RemoveAll(dir)

	aPath := os.DevNull
	if current != nil {
		aPath = filepath.Join(dir, "current.txt")
		if err := os.WriteFile(aPath, []byte(*current), 0o600); err != nil {
			io.WriteString(stderr, "cannot write the diff input: "+err.Error()+"\n")
			return
		}
	}
	bPath := filepath.Join(dir, "proposed.txt")
	if err := os.WriteFile(bPath, []byte(proposed), 0o600); err != nil {
		io.WriteString(stderr, "cannot write the diff input: "+err.Error()+"\n")
		return
	}

	cmd := exec.Command("diff", "-u",
		"--label", "a/"+configPath, "--label", "b/"+configPath, aPath, bPath)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	_ = cmd.Run()
}
