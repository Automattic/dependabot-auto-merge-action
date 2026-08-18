package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestFixtureTreeListPathsCleansAndSorts(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "tree.paths")
	content := "./b/file\n/a/file\n\n   \nc/file\nc/file\n"
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := FixtureTree{PathsFile: file}.ListPaths()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a/file", "b/file", "c/file"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ListPaths = %v, want %v", got, want)
	}
}

func TestFixtureTreeBlobDir(t *testing.T) {
	cases := []struct{ in, want string }{
		{"trees/pnpm.paths", "trees/pnpm.blobs"},
		// The bash rule was ${f%.*}.blobs: the LAST dot anywhere counts,
		// and a dotless path gains the suffix whole.
		{"noext", "noext.blobs"},
		{"a.b/file", "a.blobs"},
	}
	for _, c := range cases {
		if got := (FixtureTree{PathsFile: c.in}).BlobDir(); got != c.want {
			t.Errorf("BlobDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFixtureTreeReadBlob(t *testing.T) {
	dir := t.TempDir()
	pathsFile := filepath.Join(dir, "tree.paths")
	if err := os.WriteFile(pathsFile, []byte("pkg/package.json\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	blobPath := filepath.Join(dir, "tree.blobs", "pkg")
	if err := os.MkdirAll(blobPath, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(blobPath, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	tree := FixtureTree{PathsFile: pathsFile}
	body, err := tree.ReadBlob("pkg/package.json")
	if err != nil || string(body) != "{}" {
		t.Errorf("ReadBlob = %q, %v", body, err)
	}
	if _, err := tree.ReadBlob("missing.json"); err == nil {
		t.Error("ReadBlob of a missing blob must error")
	}
}

func TestFixtureConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dependabot.yml")

	raw, present, err := FixtureConfig{Path: path}.ReadConfig()
	if err != nil || present || raw != "" {
		t.Errorf("missing file = (%q, %v, %v), want empty, absent, nil", raw, present, err)
	}

	if err := os.WriteFile(path, []byte("version: 2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	raw, present, err = FixtureConfig{Path: path}.ReadConfig()
	if err != nil || !present || raw != "version: 2\n" {
		t.Errorf("present file = (%q, %v, %v)", raw, present, err)
	}
}

// fakeExec scripts responses per command line and records every invocation.
type fakeExec struct {
	calls     [][]string
	responses map[string]fakeResponse
}

type fakeResponse struct {
	stdout, combined string
	err              error
}

func (f *fakeExec) lookup(name string, args []string) (fakeResponse, error) {
	call := append([]string{name}, args...)
	f.calls = append(f.calls, call)
	resp, ok := f.responses[strings.Join(call, " ")]
	if !ok {
		return fakeResponse{}, fmt.Errorf("unscripted call: %v", call)
	}
	return resp, nil
}

func (f *fakeExec) Output(name string, args ...string) ([]byte, error) {
	resp, err := f.lookup(name, args)
	if err != nil {
		return nil, err
	}
	return []byte(resp.stdout), resp.err
}

func (f *fakeExec) Combined(name string, args ...string) ([]byte, error) {
	resp, err := f.lookup(name, args)
	if err != nil {
		return nil, err
	}
	return []byte(resp.combined), resp.err
}

func TestCheckReportsMissingAndUnauthenticatedGhDistinctly(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh auth status --hostname github.com": {err: fmt.Errorf("spawn: %w", exec.ErrNotFound)},
	}}
	g := &GH{Repo: "acme/widgets", X: x}
	if err := g.Check(); err == nil || !strings.Contains(err.Error(), "gh not found") {
		t.Errorf("missing gh: %v", err)
	}

	x.responses["gh auth status --hostname github.com"] = fakeResponse{err: errors.New("exit 1")}
	if err := g.Check(); err == nil || !strings.Contains(err.Error(), "not authenticated to github.com") {
		t.Errorf("unauthenticated gh: %v", err)
	}
}

func TestResolvePinsTheDefaultBranch(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets": {combined: `{"full_name":"Acme/Widgets","default_branch":"trunk"}`},
	}}
	g := &GH{Repo: "acme/widgets", X: x}
	if err := g.Resolve(); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	// The comparison is case-insensitive: GitHub canonicalizes case without
	// a redirect.
	if g.branch != "trunk" {
		t.Errorf("branch = %q", g.branch)
	}
}

func TestResolveRefusesARenamedRepository(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets": {combined: `{"full_name":"acme/renamed","default_branch":"main"}`},
	}}
	g := &GH{Repo: "acme/widgets", X: x}
	err := g.Resolve()
	if err == nil || !strings.Contains(err.Error(), "renamed or transferred") {
		t.Errorf("Resolve: %v", err)
	}
}

func TestResolveTruncatesLongAPIErrors(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets": {combined: strings.Repeat("x", 900), err: errors.New("exit 1")},
	}}
	g := &GH{Repo: "acme/widgets", X: x}
	err := g.Resolve()
	if err == nil || len(err.Error()) > 350 {
		t.Errorf("error not truncated to ~300 bytes: %d chars", len(err.Error()))
	}
}

func TestListPathsFiltersBlobsAndSorts(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets/git/trees/main?recursive=1": {combined: `{
			"truncated": false,
			"tree": [
				{"type": "tree", "path": "src"},
				{"type": "blob", "path": "src/b.js"},
				{"type": "blob", "path": "package.json"}
			]
		}`},
	}}
	g := &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	got, err := g.ListPaths()
	if err != nil {
		t.Fatalf("ListPaths: %v", err)
	}
	if want := []string{"package.json", "src/b.js"}; !reflect.DeepEqual(got, want) {
		t.Errorf("ListPaths = %v, want %v", got, want)
	}
}

func TestListPathsRefusesATruncatedTree(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets/git/trees/main?recursive=1": {combined: `{"truncated": true, "tree": []}`},
	}}
	g := &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	_, err := g.ListPaths()
	var te TruncatedError
	if !errors.As(err, &te) {
		t.Fatalf("want TruncatedError, got %v", err)
	}
	if !strings.Contains(err.Error(), "truncated its response for acme/widgets") {
		t.Errorf("message: %v", err)
	}
}

func TestListPathsReportsUnparseableTrees(t *testing.T) {
	x := &fakeExec{responses: map[string]fakeResponse{
		"gh api repos/acme/widgets/git/trees/main?recursive=1": {combined: `<!DOCTYPE html>`},
	}}
	g := &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	if _, err := g.ListPaths(); err == nil || !strings.Contains(err.Error(), "cannot parse the file tree") {
		t.Errorf("ListPaths: %v", err)
	}
}

func TestReadBlobEscapesThePathLikeJqAtUri(t *testing.T) {
	key := "gh api repos/acme/widgets/contents/bad%7Cpipe%2Fpackage.json?ref=main -H Accept: application/vnd.github.raw"
	x := &fakeExec{responses: map[string]fakeResponse{key: {stdout: "{}"}}}
	g := &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	body, err := g.ReadBlob("bad|pipe/package.json")
	if err != nil || string(body) != "{}" {
		t.Errorf("ReadBlob = %q, %v (calls %v)", body, err, x.calls)
	}
}

func TestReadConfigPrefersYmlAndTrapsYamlOnly(t *testing.T) {
	yml := "gh api repos/acme/widgets/contents/.github%2Fdependabot.yml?ref=main -H Accept: application/vnd.github.raw"
	yaml := "gh api repos/acme/widgets/contents/.github%2Fdependabot.yaml?ref=main -H Accept: application/vnd.github.raw"

	// .yml present.
	x := &fakeExec{responses: map[string]fakeResponse{yml: {stdout: "version: 2\n"}}}
	g := &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	raw, present, err := g.ReadConfig()
	if err != nil || !present || raw != "version: 2\n" {
		t.Errorf("yml present = (%q, %v, %v)", raw, present, err)
	}

	// Only .yaml present: a trap, not an absence.
	x = &fakeExec{responses: map[string]fakeResponse{
		yml:  {err: errors.New("404")},
		yaml: {stdout: "version: 2\n"},
	}}
	g = &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	_, _, err = g.ReadConfig()
	if err == nil || !strings.Contains(err.Error(), "rename it first") {
		t.Errorf("yaml trap: %v", err)
	}

	// Neither present.
	x = &fakeExec{responses: map[string]fakeResponse{
		yml:  {err: errors.New("404")},
		yaml: {err: errors.New("404")},
	}}
	g = &GH{Repo: "acme/widgets", X: x, encBranch: "main"}
	raw, present, err = g.ReadConfig()
	if err != nil || present || raw != "" {
		t.Errorf("absent = (%q, %v, %v)", raw, present, err)
	}
}

func TestURIEscapeMatchesJqAtUri(t *testing.T) {
	cases := []struct{ in, want string }{
		{"main", "main"},
		{"a/b", "a%2Fb"},
		{"café", "caf%C3%A9"},
		{"a b", "a%20b"},
		{"p+kg", "p%2Bkg"},
		{"bad|pipe", "bad%7Cpipe"},
		{"A-Z_0.9~", "A-Z_0.9~"},
		{"release/v1.2", "release%2Fv1.2"},
	}
	for _, c := range cases {
		if got := uriEscape(c.in); got != c.want {
			t.Errorf("uriEscape(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
