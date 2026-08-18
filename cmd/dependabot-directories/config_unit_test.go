package main

import (
	"reflect"
	"strings"
	"testing"
)

// --- shape checks -----------------------------------------------------------

func TestCheckShapeRefusals(t *testing.T) {
	cases := []struct {
		name, raw, wantErr string
	}{
		{"tab indentation", "version: 2\nupdates:\n\t- package-ecosystem: \"composer\"\n", "tabs"},
		{"space then tab", "version: 2\nupdates:\n \t- x\n", "tabs"},
		{"multiple documents", "---\na: 1\n---\nb: 2\nupdates:\n", "more than one YAML document"},
		{"anchor", "version: 2\ndefaults: &weekly\n  interval: \"weekly\"\nupdates:\n", "anchors"},
		{"alias", "version: 2\nupdates:\n  - schedule: *weekly\n", "anchors"},
		{"merge key", "version: 2\nupdates:\n  - <<: *base\n", "anchors"},
		{"inline list", "version: 2\nupdates: []\n", "inline form"},
		{"inline map", "version: 2\nupdates: {}\n", "inline form"},
		{"missing updates", "version: 2\n", "no top-level 'updates:'"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := CheckShape(c.raw)
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("CheckShape = %v, want error containing %q", err, c.wantErr)
			}
		})
	}
}

func TestCheckShapeAccepts(t *testing.T) {
	cases := []struct{ name, raw string }{
		{"plain two-space", "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n"},
		// One document marker is a document start, not a second document.
		{"single leading marker", "---\nversion: 2\nupdates:\n"},
		// [[:space:]] matches \r, so CRLF endings pass every per-line check.
		{"crlf", "version: 2\nupdates:\r\n  - package-ecosystem: \"composer\"\r\n    directory: \"/x\"\r\n"},
		{"comment after updates", "version: 2\nupdates: # none yet\n"},
		{"glob directory value", "version: 2\nupdates:\n  - directories:\n      - \"/p/*\"\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := CheckShape(c.raw); err != nil {
				t.Errorf("CheckShape = %v, want nil", err)
			}
		})
	}
}

// --- indentation ------------------------------------------------------------

func TestDetectIndentation(t *testing.T) {
	cases := []struct {
		name, raw, item, child string
	}{
		{"two-space", "version: 2\nupdates:\n  - package-ecosystem: \"x\"\n    directory: \"/\"\n", "  ", "    "},
		{"four-space", "version: 2\nupdates:\n    - package-ecosystem: \"x\"\n      directory: \"/\"\n", "    ", "      "},
		{"empty updates keeps the defaults", "version: 2\nupdates:\n", "  ", "    "},
		// Prefer what the file actually does over what the dash implies.
		{"child key overrides the computed gap", "version: 2\nupdates:\n  - package-ecosystem: \"x\"\n     schedule:\n", "  ", "     "},
		{"crlf", "version: 2\nupdates:\r\n  - package-ecosystem: \"x\"\r\n    directory: \"/\"\r\n", "  ", "    "},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			item, child := DetectIndentation(c.raw)
			if item != c.item || child != c.child {
				t.Errorf("DetectIndentation = (%q, %q), want (%q, %q)", item, child, c.item, c.child)
			}
		})
	}
}

// --- coverage parsing -------------------------------------------------------

func TestParseCoverage(t *testing.T) {
	cases := []struct {
		name, raw string
		want      []CoverageEntry
	}{
		{"singular directory", "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n", []CoverageEntry{{"composer", "/"}}},
		{"directories array", "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directories:\n      - \"/a\"\n      - \"/b\"\n", []CoverageEntry{{"composer", "/a"}, {"composer", "/b"}}},
		{"array and singular together", "version: 2\nupdates:\n  - package-ecosystem: \"npm\"\n    directories:\n      - \"/a\"\n    directory: \"/b\"\n", []CoverageEntry{{"npm", "/a"}, {"npm", "/b"}}},
		// Entries carrying target-branch are invisible to Dependabot's
		// security updates, so they never count as coverage.
		{"target-branch skipped", "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n    target-branch: \"develop\"\n", nil},
		{"empty updates", "version: 2\nupdates:\n", nil},
		{"missing ecosystem becomes ?", "version: 2\nupdates:\n  - directory: \"/\"\n", []CoverageEntry{{"?", "/"}}},
		{"scalar values are stringified", "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: 2025\n", []CoverageEntry{{"composer", "2025"}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ParseCoverage(c.raw)
			if err != nil {
				t.Fatalf("ParseCoverage error %v", err)
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("ParseCoverage = %v, want %v", got, c.want)
			}
		})
	}
}

func TestParseCoverageErrors(t *testing.T) {
	cases := []struct {
		name, raw, wantErr string
	}{
		{"broken yaml", "version: 2\nupdates:\n  - [oops\n", "cannot parse"},
		// yaml.v3 refuses duplicate keys where the bash shim's backends
		// silently took the last value — the fail-closed direction.
		{"duplicate keys", "version: 2\nversion: 3\nupdates:\n", "cannot parse"},
		{"updates not a list", "version: 2\nupdates: 3\n", "not a list"},
		{"scalar entry", "version: 2\nupdates:\n  - just-a-string\n", "cannot read the update entries"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseCoverage(c.raw)
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("ParseCoverage = %v, want error containing %q", err, c.wantErr)
			}
		})
	}
}

// --- coverage matching ------------------------------------------------------

func TestCovers(t *testing.T) {
	entries := []CoverageEntry{
		{"composer", "/"},
		{"npm", "packages/a"}, // no leading slash in the file
		{"composer", "/projects/plugins/*"},
	}
	cases := []struct {
		eco, dir string
		want     bool
	}{
		{"composer", "/", true},
		{"npm", "/", false},
		{"npm", "/packages/a", true},                 // the entry normalizes to /packages/a
		{"composer", "/projects/plugins/b", true},    // existing glob counts
		{"composer", "/projects/plugins/b/c", false}, // * does not cross /
		{"composer", "/other", false},
	}
	for _, c := range cases {
		if got := Covers(entries, c.eco, c.dir); got != c.want {
			t.Errorf("Covers(%s, %s) = %v, want %v", c.eco, c.dir, got, c.want)
		}
	}
}

func TestCoversQuestionMarkGlob(t *testing.T) {
	entries := []CoverageEntry{{"npm", "/pkg?"}}
	if !Covers(entries, "npm", "/pkg1") {
		t.Error("? glob must cover a single character")
	}
	if Covers(entries, "npm", "/pkg12") {
		t.Error("? glob must not cover two characters")
	}
}

// --- stale entries ----------------------------------------------------------

func TestStaleNotes(t *testing.T) {
	entries := []CoverageEntry{
		{"composer", "/gone"},
		{"composer", "/"},
		{"npm", "/p/*"}, // globs are never called stale
	}
	pairs := []Pair{{Eco: "composer", Dir: "/", Kind: "lock"}}
	got := StaleNotes(entries, pairs)
	want := []string{"existing entry (composer, /gone) matches nothing we detected — left alone"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("StaleNotes = %v, want %v", got, want)
	}
}

func TestStaleNotesWithNoEntries(t *testing.T) {
	if got := StaleNotes(nil, []Pair{{Eco: "npm", Dir: "/", Kind: "root"}}); got != nil {
		t.Errorf("StaleNotes = %v, want nil", got)
	}
}

func lines(raw string) []string { return strings.Split(raw, "\n") }

func TestInsertionLine(t *testing.T) {
	cases := []struct {
		name, raw string
		want      int
	}{
		{"empty updates block", "version: 2\nupdates:\n", 2},
		{"entries to the end of file", "version: 2\nupdates:\n  - a: 1\n    b: 2\n", 4},
		// The blank line separates updates from the next key; appending
		// must land before it.
		{"following top-level key", "version: 2\nupdates:\n  - a: 1\n\nregistries:\n  x: 1\n", 3},
		{"blank lines inside the block do not end it", "version: 2\nupdates:\n  - a: 1\n\n  - b: 2\nnext:\n", 5},
		{"comments inside the block advance it", "version: 2\nupdates:\n  # todo\nregistries:\n", 3},
		{"comment after the updates key", "version: 2\nupdates: # none yet\n", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := InsertionLine(lines(c.raw)); got != c.want {
				t.Errorf("InsertionLine = %d, want %d", got, c.want)
			}
		})
	}
}

func TestRenderBlockSecurityDefault(t *testing.T) {
	got := RenderBlock(Block{Eco: "composer", Dir: "/"}, "  ", "    ", false)
	want := `  - package-ecosystem: "composer"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
    open-pull-requests-limit: 0
    cooldown:
      default-days: 7
`
	if got != want {
		t.Errorf("RenderBlock = %q, want %q", got, want)
	}
}

func TestRenderBlockGlob(t *testing.T) {
	got := RenderBlock(Block{Eco: "composer", Dir: "/plugins/*", IsGlob: true}, "  ", "    ", false)
	want := `  - package-ecosystem: "composer"
    directories:
      - "/plugins/*"
    schedule:
      interval: "weekly"
      day: "monday"
    open-pull-requests-limit: 0
    cooldown:
      default-days: 7
`
	if got != want {
		t.Errorf("RenderBlock = %q, want %q", got, want)
	}
}

func TestRenderBlockVersionUpdates(t *testing.T) {
	got := RenderBlock(Block{Eco: "npm", Dir: "/"}, "  ", "    ", true)
	want := `  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
    open-pull-requests-limit: 10
    groups:
      npm-minor-patch:
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
      npm-major:
        patterns:
          - "*"
        update-types:
          - "major"
    cooldown:
      default-days: 7
`
	if got != want {
		t.Errorf("RenderBlock = %q, want %q", got, want)
	}
}

func TestRenderBlockMatchesDetectedIndentation(t *testing.T) {
	got := RenderBlock(Block{Eco: "composer", Dir: "/"}, "    ", "      ", false)
	if !strings.Contains(got, "    - package-ecosystem: \"composer\"\n") ||
		!strings.Contains(got, "      directory: \"/\"\n") {
		t.Errorf("RenderBlock did not honour the file's indentation:\n%s", got)
	}
}
