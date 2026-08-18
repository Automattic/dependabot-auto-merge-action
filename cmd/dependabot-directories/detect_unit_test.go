package main

import (
	"bytes"
	"errors"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestNormalizeDir(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "/"},
		{".", "/"},
		{"./", "/"},
		{"a", "/a"},
		{"./a", "/a"},
		{"/a", "/a"},
		{"a/", "/a"},
		{"a//", "/a"},
		{"/", "/"},
		{"a/b", "/a/b"},
		{"packages/*", "/packages/*"},
	}
	for _, c := range cases {
		if got := NormalizeDir(c.in); got != c.want {
			t.Errorf("NormalizeDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParentDir(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/", ""}, // sentinel: the root has no parent
		{"/a", "/"},
		{"/a/b", "/a"},
		{"/a/b/c", "/a/b"},
	}
	for _, c := range cases {
		if got := ParentDir(c.in); got != c.want {
			t.Errorf("ParentDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDirsOf(t *testing.T) {
	got := DirsOf([]string{
		"package.json",
		"a/b/x.txt",
		"a/c.json",
		"a/b/y.txt", // duplicate directory
	})
	want := []string{"/", "/a", "/a/b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("DirsOf = %v, want %v", got, want)
	}
}

func TestWithBasenames(t *testing.T) {
	paths := []string{
		"package.json",
		"sub/package.json",
		"sub/package.json5",
		"docs/composer.lock",
		"yarn.lock",
	}
	got := WithBasenames(paths, "package.json", "yarn.lock")
	want := []string{"package.json", "sub/package.json", "yarn.lock"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("WithBasenames = %v, want %v", got, want)
	}
}

func TestSortedUnique(t *testing.T) {
	got := SortedUnique([]string{"b", "a", "b", "c", "a"})
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("SortedUnique = %v, want %v", got, want)
	}
}

// The report's ordering comes from sorting joined "eco|dir|kind" records, the
// way the bash script sorted its record files under LC_ALL=C. That is not the
// same as sorting field-wise: '|' (0x7C) sorts after every letter, so
// "npm|/packages/legacy|0" orders BEFORE "npm|/|0". Sorting fields first and
// joining after would flip them and silently break output parity.
func TestJoinedRecordOrderingMatchesBash(t *testing.T) {
	records := []string{"npm|/|0", "npm|/packages/legacy|0"}
	sort.Strings(records)
	if records[0] != "npm|/packages/legacy|0" {
		t.Errorf("joined-record sort put %q first; bash sort -u orders the longer path first", records[0])
	}
}

func TestHardExclusionsDropSilently(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"package.json",
		"node_modules/left-pad/package.json",
		"a/vendor/pkg/composer.json",
		".git/config",
		"bower_components/x/bower.json",
	}, nil)
	if want := []string{"package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if len(soft) != 0 {
		t.Errorf("hard-excluded paths must not surface as soft, got %v", soft)
	}
}

func TestAFileNamedLikeAnExcludedDirectorySurvives(t *testing.T) {
	// The exclusion names directories: the bash regex was (^|/)(name)/, so a
	// plain file called vendor is not under a vendor/ directory.
	kept, _ := SplitExclusions([]string{"vendor", "docs/build"}, nil)
	if want := []string{"vendor", "docs/build"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
}

func TestSoftExclusionsAreReturnedSeparately(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"package.json",
		"examples/demo/package.json",
		"dist/package.json",
		"docs/fixtures/tree/package.json",
	}, nil)
	if want := []string{"package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	wantSoft := []string{
		"examples/demo/package.json",
		"dist/package.json",
		"docs/fixtures/tree/package.json",
	}
	if !reflect.DeepEqual(soft, wantSoft) {
		t.Errorf("soft = %v, want %v", soft, wantSoft)
	}
}

func TestIncludeReadmitsASoftExcludedName(t *testing.T) {
	kept, soft := SplitExclusions([]string{
		"examples/demo/package.json",
		"dist/package.json",
	}, []string{"examples"})
	if want := []string{"examples/demo/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if want := []string{"dist/package.json"}; !reflect.DeepEqual(soft, want) {
		t.Errorf("soft = %v, want %v", soft, want)
	}
}

func TestIncludeNeverReadmitsAHardExclusion(t *testing.T) {
	kept, _ := SplitExclusions([]string{"node_modules/x/package.json"}, []string{"node_modules"})
	if len(kept) != 0 {
		t.Errorf("hard exclusions are not negotiable, kept = %v", kept)
	}
}

func TestExampleAndExamplesAreDistinctNames(t *testing.T) {
	// Both are on the soft list; --include of one must not readmit the other.
	kept, soft := SplitExclusions([]string{
		"example/package.json",
		"examples/package.json",
	}, []string{"example"})
	if want := []string{"example/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if want := []string{"examples/package.json"}; !reflect.DeepEqual(soft, want) {
		t.Errorf("soft = %v, want %v", soft, want)
	}
}

func TestSegmentMatchIsExact(t *testing.T) {
	// "distribution" contains "dist" but is not the segment "dist".
	kept, soft := SplitExclusions([]string{"distribution/package.json"}, nil)
	if want := []string{"distribution/package.json"}; !reflect.DeepEqual(kept, want) {
		t.Errorf("kept = %v, want %v", kept, want)
	}
	if len(soft) != 0 {
		t.Errorf("soft = %v, want empty", soft)
	}
}

func TestGlobToRegexp(t *testing.T) {
	cases := []struct {
		pattern string
		match   []string
		reject  []string
	}{
		{"packages/*", []string{"packages/a", "packages/a-b"}, []string{"packages", "packages/a/b", "packagesx/a"}},
		{"a?c", []string{"abc", "a-c"}, []string{"ac", "abbc", "a/c"}},
		// The zero-segment case is the one everyone gets wrong: a/**/b must
		// match a/b as well as a/z/b.
		{"a/**/b", []string{"a/b", "a/z/b", "a/z/y/b"}, []string{"a/zb", "ab"}},
		{"packages/**", []string{"packages/a", "packages/a/b"}, []string{"packages"}},
		{"**x", []string{"x", "ax", "a/bx"}, []string{"xy"}},
		{"p+kg/*", []string{"p+kg/a"}, []string{"ppkg/a", "pkg/a"}},
		{"café/*", []string{"café/a"}, []string{"cafe/a"}},
		// A character class is matched literally, bracket and all.
		{"a[b]c", []string{"a[b]c"}, []string{"abc", "ab"}},
		{"my dir/*", []string{"my dir/a"}, []string{"mydir/a"}},
	}
	for _, c := range cases {
		re := GlobToRegexp(c.pattern)
		for _, s := range c.match {
			if !re.MatchString(s) {
				t.Errorf("GlobToRegexp(%q) = %v must match %q", c.pattern, re, s)
			}
		}
		for _, s := range c.reject {
			if re.MatchString(s) {
				t.Errorf("GlobToRegexp(%q) = %v must not match %q", c.pattern, re, s)
			}
		}
	}
}

func collectNotes() (func(string), *[]string) {
	var notes []string
	return func(msg string) { notes = append(notes, msg) }, &notes
}

func TestBuildPatternsResolvesAgainstTheRoot(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"packages/*"}, note)
	if got := ps.Expand([]string{"/packages/a", "/packages/a/b", "/other"}); !reflect.DeepEqual(got, []string{"/packages/a"}) {
		t.Errorf("Expand = %v", got)
	}

	ps = BuildPatterns("/tools", []string{"pkgs/*"}, note)
	if got := ps.Expand([]string{"/tools/pkgs/a", "/pkgs/a"}); !reflect.DeepEqual(got, []string{"/tools/pkgs/a"}) {
		t.Errorf("Expand = %v", got)
	}
}

func TestBuildPatternsNegation(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"packages/*", "!packages/legacy"}, note)
	got := ps.Expand([]string{"/packages/a", "/packages/legacy", "/packages/z"})
	if want := []string{"/packages/a", "/packages/z"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Expand = %v, want %v", got, want)
	}
}

func TestBuildPatternsCleansAndSkips(t *testing.T) {
	note, notes := collectNotes()
	ps := BuildPatterns("/", []string{"./pkgs/*", "trail//", "", "!"}, note)
	got := ps.Expand([]string{"/pkgs/a", "/trail", "/other"})
	if want := []string{"/pkgs/a", "/trail"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Expand = %v, want %v", got, want)
	}
	if len(*notes) != 0 {
		t.Errorf("unexpected notes %v", *notes)
	}
}

func TestBuildPatternsNotesCharacterClasses(t *testing.T) {
	note, notes := collectNotes()
	BuildPatterns("/", []string{"pkg[ab]/*"}, note)
	want := "workspace pattern 'pkg[ab]/*' uses a character class, which is matched literally"
	if len(*notes) != 1 || (*notes)[0] != want {
		t.Errorf("notes = %v, want [%q]", *notes, want)
	}
}

func TestExpandWithNoPositivePatternsMatchesNothing(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"!packages/legacy"}, note)
	if got := ps.Expand([]string{"/packages/a", "/packages/legacy"}); len(got) != 0 {
		// A negation with no positive patterns has nothing to subtract from.
		t.Errorf("Expand = %v, want empty", got)
	}
}

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
	rep := newReporter(&out, &out)
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

func runGroup(t *testing.T, pairs []Pair, rawNpm, rawComposer []string) ([]Block, string) {
	t.Helper()
	var out bytes.Buffer
	rep := newReporter(&out, &out)
	blocks := Group(pairs, rawNpm, rawComposer, rep)
	return blocks, out.String()
}

func TestGroupCollapsesExactSiblingsIntoAGlob(t *testing.T) {
	pairs := []Pair{
		{Eco: "composer", Dir: "/plugins/a", Kind: "lock"},
		{Eco: "composer", Dir: "/plugins/b", Kind: "lock"},
	}
	blocks, out := runGroup(t, pairs, nil, []string{"/plugins/a", "/plugins/b"})
	want := []Block{{Eco: "composer", Dir: "/plugins/*", IsGlob: true, Members: []string{"/plugins/a", "/plugins/b"}}}
	if !reflect.DeepEqual(blocks, want) {
		t.Errorf("blocks = %v, want %v", blocks, want)
	}
	if out != "" {
		t.Errorf("unexpected output %q", out)
	}
}

func TestGuard1RootParentKeepsSingulars(t *testing.T) {
	pairs := []Pair{
		{Eco: "composer", Dir: "/a", Kind: "lock"},
		{Eco: "composer", Dir: "/b", Kind: "lock"},
	}
	blocks, out := runGroup(t, pairs, nil, []string{"/a", "/b"})
	want := []Block{{Eco: "composer", Dir: "/a"}, {Eco: "composer", Dir: "/b"}}
	if !reflect.DeepEqual(blocks, want) {
		t.Errorf("blocks = %v, want %v", blocks, want)
	}
	if !strings.Contains(out, "repository root") {
		t.Errorf("missing Guard 1 note in %q", out)
	}
}

func TestGuard2UnmappedSiblingKeepsSingulars(t *testing.T) {
	pairs := []Pair{
		{Eco: "composer", Dir: "/plugins/a", Kind: "lock"},
		{Eco: "composer", Dir: "/plugins/b", Kind: "lock"},
	}
	// The raw list carries a lockless sibling the run did not map.
	blocks, out := runGroup(t, pairs, nil, []string{"/plugins/a", "/plugins/b", "/plugins/c"})
	want := []Block{{Eco: "composer", Dir: "/plugins/a"}, {Eco: "composer", Dir: "/plugins/b"}}
	if !reflect.DeepEqual(blocks, want) {
		t.Errorf("blocks = %v, want %v", blocks, want)
	}
	if !strings.Contains(out, "did not map") {
		t.Errorf("missing Guard 2 note in %q", out)
	}
}

func TestGuard2SeesSoftExcludedSiblings(t *testing.T) {
	// The raw list ignores exclusions on purpose: Dependabot would expand
	// the glob over an excluded sibling too.
	pairs := []Pair{
		{Eco: "composer", Dir: "/plugins/a", Kind: "lock"},
		{Eco: "composer", Dir: "/plugins/b", Kind: "lock"},
	}
	blocks, _ := runGroup(t, pairs, nil, []string{"/plugins/a", "/plugins/b", "/plugins/fixtures"})
	for _, b := range blocks {
		if b.IsGlob {
			t.Errorf("glob emitted over an excluded sibling: %v", blocks)
		}
	}
}

func TestWorkspaceRootsAndActionsAreNeverGrouped(t *testing.T) {
	pairs := []Pair{
		{Eco: "npm", Dir: "/apps/a", Kind: "root"},
		{Eco: "npm", Dir: "/apps/b", Kind: "root"},
		{Eco: "github-actions", Dir: "/", Kind: "actions"},
	}
	blocks, _ := runGroup(t, pairs, []string{"/apps/a", "/apps/b"}, nil)
	for _, b := range blocks {
		if b.IsGlob {
			t.Errorf("roots or actions were globbed: %v", blocks)
		}
	}
	if len(blocks) != 3 {
		t.Errorf("blocks = %v, want 3 singulars", blocks)
	}
}

func TestEcosystemsNeverShareAGlob(t *testing.T) {
	pairs := []Pair{
		{Eco: "composer", Dir: "/plugins/a", Kind: "lock"},
		{Eco: "npm", Dir: "/plugins/b", Kind: "lock"},
	}
	blocks, _ := runGroup(t, pairs, []string{"/plugins/b"}, []string{"/plugins/a"})
	for _, b := range blocks {
		if b.IsGlob {
			t.Errorf("cross-ecosystem glob emitted: %v", blocks)
		}
	}
}

func TestGroupOrdersBlocksByJoinedRecord(t *testing.T) {
	pairs := []Pair{
		{Eco: "npm", Dir: "/", Kind: "root"},
		{Eco: "npm", Dir: "/packages/legacy", Kind: "lock"},
	}
	blocks, _ := runGroup(t, pairs, []string{"/", "/packages/legacy"}, nil)
	// '|' sorts after 'p', so the longer path comes first — the bash
	// sort -u ordering the report contract pins.
	want := []Block{{Eco: "npm", Dir: "/packages/legacy"}, {Eco: "npm", Dir: "/"}}
	if !reflect.DeepEqual(blocks, want) {
		t.Errorf("blocks = %v, want %v", blocks, want)
	}
}
