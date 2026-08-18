package detect

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

func runGroup(t *testing.T, pairs []Pair, rawNpm, rawComposer []string) ([]Block, string) {
	t.Helper()
	var out bytes.Buffer
	rep := report.New(&out, &out)
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
