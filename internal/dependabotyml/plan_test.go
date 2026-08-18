package dependabotyml

import (
	"strings"
	"testing"

	"github.com/Automattic/dependabot-auto-merge-action/internal/detect"
)

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
	got := RenderBlock(detect.Block{Eco: "composer", Dir: "/"}, "  ", "    ", false)
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
	got := RenderBlock(detect.Block{Eco: "composer", Dir: "/plugins/*", IsGlob: true}, "  ", "    ", false)
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
	got := RenderBlock(detect.Block{Eco: "npm", Dir: "/"}, "  ", "    ", true)
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
	got := RenderBlock(detect.Block{Eco: "composer", Dir: "/"}, "    ", "      ", false)
	if !strings.Contains(got, "    - package-ecosystem: \"composer\"\n") ||
		!strings.Contains(got, "      directory: \"/\"\n") {
		t.Errorf("RenderBlock did not honour the file's indentation:\n%s", got)
	}
}
