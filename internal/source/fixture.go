package source

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FixtureTree is the offline TreeSource behind --paths-from-file: the file
// list comes from a text file, one path per line, and blob contents from the
// sibling <file-without-extension>.blobs/ directory.
type FixtureTree struct {
	PathsFile string
}

// BlobDir mirrors the bash derivation ${f%.*}.blobs — everything after the
// last dot anywhere in the path counts as the extension.
func (f FixtureTree) BlobDir() string {
	base := f.PathsFile
	if i := strings.LastIndex(base, "."); i >= 0 {
		base = base[:i]
	}
	return base + ".blobs"
}

// ListPaths accepts hand-written fixtures as they are: ./x and /x spellings
// are normalized, blank lines dropped, and the result sorted byte-wise.
func (f FixtureTree) ListPaths() ([]string, error) {
	raw, err := os.ReadFile(f.PathsFile)
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimPrefix(line, "./")
		line = strings.TrimPrefix(line, "/")
		if strings.TrimSpace(line) == "" {
			continue
		}
		paths = append(paths, line)
	}
	sort.Strings(paths)
	out := paths[:0]
	for i, p := range paths {
		if i == 0 || p != paths[i-1] {
			out = append(out, p)
		}
	}
	return out, nil
}

func (f FixtureTree) ReadBlob(path string) ([]byte, error) {
	body, err := os.ReadFile(filepath.Join(f.BlobDir(), path))
	if err != nil {
		return nil, err
	}
	return body, nil
}

// FixtureConfig is the offline ConfigSource behind --existing-config. A
// missing file means "the repository has no dependabot.yml yet", not an
// error.
type FixtureConfig struct {
	Path string
}

func (f FixtureConfig) ReadConfig() (string, bool, error) {
	raw, err := os.ReadFile(f.Path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return string(raw), true, nil
}
