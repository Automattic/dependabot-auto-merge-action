package detect

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

// fakeBlobs serves blob contents from a map; anything absent errors, which
// callers must treat as "file missing".
type fakeBlobs map[string]string

func (f fakeBlobs) ReadBlob(path string) ([]byte, error) {
	body, ok := f[path]
	if !ok {
		return nil, errors.New("no such blob")
	}
	return []byte(body), nil
}

func runNpm(t *testing.T, kept []string, blobs fakeBlobs) ([]Pair, string) {
	t.Helper()
	var out bytes.Buffer
	rep := report.New(&out, &out)
	pairs := Npm(kept, blobs, rep)
	return pairs, out.String()
}

func TestNpmWorkspaceShapes(t *testing.T) {
	kept := []string{"package.json", "yarn.lock", "packages/a/package.json"}
	cases := []struct {
		name        string
		packageJSON string
		wantRoot    bool // "/" emitted as a root pair
		wantCovered bool // packages/a absorbed, so no lockless note for it
		wantNote    string
	}{
		{"array", `{"workspaces":["packages/*"]}`, true, true, ""},
		{"yarn v1 object", `{"workspaces":{"packages":["packages/*"]}}`, true, true, ""},
		{"object without packages", `{"workspaces":{"nohoist":["**/x"]}}`, true, false, ""},
		{"string shape", `{"workspaces":"packages/*"}`, true, false, "declares 'workspaces' as a string"},
		{"number shape", `{"workspaces":7}`, true, false, "declares 'workspaces' as a number"},
		{"boolean shape", `{"workspaces":true}`, true, false, "declares 'workspaces' as a boolean"},
		{"null", `{"workspaces":null}`, false, false, ""},
		{"absent", `{"name":"x"}`, false, false, ""},
		{"invalid json", `{"name":`, false, false, ""},
		{"non-string members skipped", `{"workspaces":["packages/*", 7, null]}`, true, true, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pairs, out := runNpm(t, kept, fakeBlobs{"package.json": c.packageJSON})

			isRoot := false
			for _, p := range pairs {
				if p.Dir == "/" && p.Kind == "root" {
					isRoot = true
				}
			}
			if isRoot != c.wantRoot {
				t.Errorf("root emitted = %v, want %v (pairs %v)", isRoot, c.wantRoot, pairs)
			}
			coveredNote := strings.Contains(out, "/packages/a")
			if coveredNote == c.wantCovered {
				t.Errorf("lockless note for /packages/a present = %v, want %v\noutput:\n%s", coveredNote, !c.wantCovered, out)
			}
			if c.wantNote != "" && !strings.Contains(out, c.wantNote) {
				t.Errorf("output missing %q:\n%s", c.wantNote, out)
			}
		})
	}
}

func TestPnpmWorkspaceShapes(t *testing.T) {
	kept := []string{"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "packages/a/package.json"}
	cases := []struct {
		name        string
		yaml        string
		wantCovered bool
		wantNote    string
	}{
		{"packages honoured", "packages:\n  - 'packages/*'\n", true, ""},
		{"no packages key", "onlyBuiltDependencies:\n  - esbuild\n", false, "declares no 'packages:'"},
		{"tab indentation", "packages:\n\t- 'packages/*'\n", false, "cannot parse pnpm-workspace.yaml"},
		{"packages not a list", "packages: everything\n", false, "declares no 'packages:'"},
		{"top level not a map", "- just\n- a\n- list\n", false, "declares no 'packages:'"},
		{"empty file", "", false, "declares no 'packages:'"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pairs, out := runNpm(t, kept, fakeBlobs{
				"package.json":        `{"name":"root"}`,
				"pnpm-workspace.yaml": c.yaml,
			})

			// Reading pnpm-workspace.yaml declares a workspace no matter
			// what is in it, so the root is always emitted.
			if len(pairs) == 0 || pairs[0].Dir != "/" || pairs[0].Kind != "root" {
				t.Fatalf("pairs = %v, want the root", pairs)
			}
			coveredNote := strings.Contains(out, "/packages/a")
			if coveredNote == c.wantCovered {
				t.Errorf("lockless note for /packages/a present = %v, want %v\noutput:\n%s", coveredNote, !c.wantCovered, out)
			}
			if c.wantNote != "" && !strings.Contains(out, c.wantNote) {
				t.Errorf("output missing %q:\n%s", c.wantNote, out)
			}
		})
	}
}

func TestNpmShadowedLockfileIsReportedNotMapped(t *testing.T) {
	kept := []string{
		"package.json", "yarn.lock",
		"packages/a/package.json",
		"packages/b/package.json", "packages/b/package-lock.json",
	}
	pairs, out := runNpm(t, kept, fakeBlobs{"package.json": `{"workspaces":["packages/*"]}`})

	want := []Pair{{Eco: "npm", Dir: "/", Kind: "root"}}
	if !reflect.DeepEqual(pairs, want) {
		t.Errorf("pairs = %v, want %v", pairs, want)
	}
	if !strings.Contains(out, "shadowed by the workspace") || !strings.Contains(out, "     /packages/b\n") {
		t.Errorf("missing shadowed note:\n%s", out)
	}
}

func TestNpmUncoveredLockfileGetsItsOwnEntry(t *testing.T) {
	kept := []string{
		"package.json", "yarn.lock",
		"packages/a/package.json",
		"packages/legacy/package.json", "packages/legacy/yarn.lock",
	}
	pairs, _ := runNpm(t, kept, fakeBlobs{"package.json": `{"workspaces":["packages/*","!packages/legacy"]}`})

	want := []Pair{
		{Eco: "npm", Dir: "/", Kind: "root"},
		{Eco: "npm", Dir: "/packages/legacy", Kind: "lock"},
	}
	if !reflect.DeepEqual(pairs, want) {
		t.Errorf("pairs = %v, want %v", pairs, want)
	}
}

func TestNpmLockfileWithoutManifestListIsSilent(t *testing.T) {
	pairs, out := runNpm(t, []string{"src/main.rs"}, fakeBlobs{})
	if pairs != nil || out != "" {
		t.Errorf("no manifests must mean no pairs and no output, got %v / %q", pairs, out)
	}
}

func TestIntersectAndSubtract(t *testing.T) {
	a := []string{"/a", "/b", "/c"}
	b := []string{"/b", "/d"}
	if got := Intersect(a, b); !reflect.DeepEqual(got, []string{"/b"}) {
		t.Errorf("Intersect = %v", got)
	}
	if got := Subtract(a, b); !reflect.DeepEqual(got, []string{"/a", "/c"}) {
		t.Errorf("Subtract = %v", got)
	}
	if got := Subtract(b, a); !reflect.DeepEqual(got, []string{"/d"}) {
		t.Errorf("Subtract = %v", got)
	}
}
