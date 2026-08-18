package main

// Byte-level parity with the bash script. The transcripts under
// testdata/golden/ were captured from scripts/dependabot-directories.sh
// before its deletion (see the manifest.tsv beside them for each exact
// invocation); an implementation that reproduces them against the same
// fixtures is, for report purposes, that script. The line-by-line assertions
// elsewhere in this suite cannot see ordering or spacing — these can.
//
// Deliberately absent: weird-paths (its '|' handling changed with the record
// format's retirement) and anything printing usage (help text belongs to the
// implementation).

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGoldenTranscripts(t *testing.T) {
	tree := func(name string) string { return filepath.Join("testdata", "trees", name+".paths") }
	cfg := func(name string) string { return filepath.Join("testdata", "dependabot", name+".yml") }

	cases := []struct {
		golden string
		args   []string
		exit   int
	}{
		{"detect-root-npm", []string{"--paths-from-file", tree("root-npm"), "--detect-only"}, 0},
		{"detect-yarn-workspaces", []string{"--paths-from-file", tree("yarn-workspaces"), "--detect-only"}, 0},
		{"detect-pnpm", []string{"--paths-from-file", tree("pnpm"), "--detect-only"}, 0},
		{"detect-mixed-monorepo", []string{"--paths-from-file", tree("mixed-monorepo"), "--detect-only"}, 0},
		{"detect-composer-siblings-lockless", []string{"--paths-from-file", tree("composer-siblings-lockless"), "--detect-only"}, 0},
		{"detect-top-level-siblings", []string{"--paths-from-file", tree("top-level-siblings"), "--detect-only"}, 0},
		{"detect-excluded", []string{"--paths-from-file", tree("excluded"), "--detect-only"}, 0},
		{"detect-deferred-ecosystems", []string{"--paths-from-file", tree("deferred-ecosystems"), "--detect-only"}, 0},
		{"merge-composer-siblings-partial-commented", []string{"--paths-from-file", tree("composer-siblings"), "--existing-config", cfg("partial-commented"), "--dry-run"}, 0},
		{"merge-composer-single-four-space-indent", []string{"--paths-from-file", tree("composer-single"), "--existing-config", cfg("four-space-indent"), "--dry-run"}, 0},
		{"merge-composer-single-empty-updates-version-updates", []string{"--paths-from-file", tree("composer-single"), "--existing-config", cfg("empty-updates"), "--dry-run", "--enable-version-updates"}, 0},
	}

	for _, c := range cases {
		t.Run(c.golden, func(t *testing.T) {
			want, err := os.ReadFile(filepath.Join("testdata", "golden", c.golden+".txt"))
			if err != nil {
				t.Fatal(err)
			}
			code, out := execute(t, append([]string{"acme/widgets"}, c.args...)...)
			if code != c.exit {
				t.Errorf("exit code = %d, want %d", code, c.exit)
			}
			if out != string(want) {
				t.Errorf("output diverges from the bash transcript:\n%s", firstDivergence(string(want), out))
			}
		})
	}
}

// firstDivergence renders the first differing line with context, which reads
// far better than two full transcripts side by side.
func firstDivergence(want, got string) string {
	wantLines := strings.Split(want, "\n")
	gotLines := strings.Split(got, "\n")
	n := max(len(wantLines), len(gotLines))
	for i := 0; i < n; i++ {
		w, g := "<missing>", "<missing>"
		if i < len(wantLines) {
			w = wantLines[i]
		}
		if i < len(gotLines) {
			g = gotLines[i]
		}
		if w != g {
			return fmt.Sprintf("line %d:\n  bash: %q\n  go:   %q\n\nfull go output:\n%s", i+1, w, g, got)
		}
	}
	return "outputs differ only in trailing bytes\nfull go output:\n" + got
}
