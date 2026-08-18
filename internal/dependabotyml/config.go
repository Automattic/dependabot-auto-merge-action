// Package dependabotyml reads an existing .github/dependabot.yml, decides
// what it already covers, and renders the missing entries. The merge is an
// append-only text splice — never a YAML round-trip, which would destroy
// comments and reorder keys — so parsing here is read-only and the structural
// shape checks stay text-level.
package dependabotyml

import (
	"fmt"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/Automattic/dependabot-auto-merge-action/internal/detect"
)

// Path is where Dependabot reads its configuration. Nowhere else — a .yaml
// sibling is a trap the caller checks for separately.
const Path = ".github/dependabot.yml"

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
		return fmt.Errorf("%s indents with tabs, which YAML forbids — fix it by hand", Path)
	}
	if docMarkers > 1 {
		return fmt.Errorf("%s holds more than one YAML document — fix it by hand", Path)
	}
	for _, line := range all {
		if anchorRe.MatchString(line) {
			return fmt.Errorf("%s uses YAML anchors, aliases or merge keys — an append-only text edit cannot reason about those", Path)
		}
	}
	hasUpdates := false
	for _, line := range all {
		if inlineRe.MatchString(line) {
			return fmt.Errorf("%s declares updates in inline form — convert it to a block sequence first", Path)
		}
		if updatesKeyRe.MatchString(line) {
			hasUpdates = true
		}
	}
	if !hasUpdates {
		return fmt.Errorf("%s has no top-level 'updates:' key — fix it by hand", Path)
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
		return nil, fmt.Errorf("cannot parse %s as YAML — refusing to guess at what it already covers", Path)
	}

	var updates any
	switch m := doc.(type) {
	case nil:
		return nil, nil
	case map[string]any:
		updates = m["updates"]
	default:
		return nil, fmt.Errorf("cannot read the update entries in %s", Path)
	}

	var list []any
	switch u := updates.(type) {
	case nil:
		return nil, nil
	case []any:
		list = u
	default:
		return nil, fmt.Errorf("%s has an 'updates' key that is not a list — fix it by hand", Path)
	}

	var entries []CoverageEntry
	for _, item := range list {
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("cannot read the update entries in %s", Path)
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
		exDir := detect.NormalizeDir(e.Dir)
		if exDir == dir {
			return true
		}
		if globCharsRe.MatchString(exDir) && detect.GlobToRegexp(exDir).MatchString(dir) {
			return true
		}
	}
	return false
}

// StaleNotes reports existing entries pointing at directories detection
// found no manifest in. Compared against the detected pairs rather than the
// rendered blocks: a directory folded into a glob is still very much
// detected. Glob entries are never called stale.
func StaleNotes(entries []CoverageEntry, pairs []detect.Pair) []string {
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
		dir := detect.NormalizeDir(e.Dir)
		if !detected[e.Eco+"|"+dir] {
			notes = append(notes, fmt.Sprintf("existing entry (%s, %s) matches nothing we detected — left alone", e.Eco, dir))
		}
	}
	return notes
}
