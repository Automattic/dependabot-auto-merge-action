package source

import (
	"os"
	"path/filepath"
	"reflect"
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
