package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// --- repository sources -------------------------------------------------------
//
// Where the pipeline's inputs come from: the file list, blob contents, and
// the existing dependabot.yml. One implementation reads fixtures from disk
// (--paths-from-file and --existing-config), the other execs gh. Detection
// never knows which one it is talking to — that seam is what lets the
// heuristics run offline against synthetic repositories.

// TreeSource lists a repository's file paths and reads individual blobs.
type TreeSource interface {
	// ListPaths returns every blob path, cleaned, deduplicated and sorted
	// byte-wise.
	ListPaths() ([]string, error)
	// ReadBlob returns one file's contents by repo-relative path. Any error
	// means "treat the file as absent".
	ReadBlob(path string) ([]byte, error)
}

// ConfigSource reads the existing .github/dependabot.yml.
type ConfigSource interface {
	// ReadConfig returns the raw file and whether it exists at all. A
	// non-nil error is fatal to the run — it marks a state that must stop
	// the merge, not a missing file.
	ReadConfig() (raw string, present bool, err error)
}

// Execer runs one external command from an argv slice — never a shell, so no
// repository content can ever be interpreted. Its two methods are the two
// capture shapes every bash call site used: Output is `cmd 2>/dev/null`,
// Combined is `cmd 2>&1`. The write-path follow-up counts calls through this
// seam to prove --dry-run issues no writes.
type Execer interface {
	// Output returns stdout, discarding stderr.
	Output(name string, args ...string) ([]byte, error)
	// Combined returns stdout and stderr interleaved in one stream.
	Combined(name string, args ...string) ([]byte, error)
}

// RealExec runs commands for real.
type RealExec struct{}

func (RealExec) Output(name string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return out.Bytes(), err
}

func (RealExec) Combined(name string, args ...string) ([]byte, error) {
	// The same value on both streams matters: os/exec only shares one pipe
	// (and so preserves interleaving without a data race) when Stderr is
	// interface-equal to Stdout.
	var buf bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.Bytes(), err
}

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

// GH reads the repository through the gh CLI, which owns the whole
// authentication story: gh auth login, GH_TOKEN, and the GH_HOST /
// GH_ENTERPRISE_TOKEN pair for GitHub Enterprise Server. Nothing here
// touches a token.
type GH struct {
	Repo string
	X    Execer

	branch    string
	encBranch string
}

// TruncatedError marks a tree listing the API refused to return whole. Never
// proceed on a partial list — a silently incomplete file list is precisely
// the failure mode this tool exists to prevent. The write-path follow-up
// swaps this error for the blobless-clone fallback.
type TruncatedError struct{ Repo string }

func (e TruncatedError) Error() string {
	return fmt.Sprintf("the git trees API truncated its response for %s — the blobless-clone fallback lands with the write path", e.Repo)
}

// Check verifies gh exists and is authenticated against the effective host.
func (g *GH) Check() error {
	host := os.Getenv("GH_HOST")
	if host == "" {
		host = "github.com"
	}
	if _, err := g.X.Combined("gh", "auth", "status", "--hostname", host); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return errors.New("gh not found — install it from https://cli.github.com")
		}
		return fmt.Errorf("gh is not authenticated to %s — run 'gh auth login' or set GH_TOKEN", host)
	}
	return nil
}

// Resolve looks the repository up and pins its default branch. A renamed or
// transferred repo redirects, so the response can describe a different
// repository than the one named on the command line — that is refused rather
// than followed.
func (g *GH) Resolve() error {
	comb, err := g.X.Combined("gh", "api", "repos/"+g.Repo)
	if err != nil {
		return fmt.Errorf("cannot read repos/%s: %s", g.Repo, truncate(comb))
	}
	var repo struct {
		FullName      string `json:"full_name"`
		DefaultBranch string `json:"default_branch"`
	}
	if json.Unmarshal(comb, &repo) != nil {
		return fmt.Errorf("cannot read repos/%s: %s", g.Repo, truncate(comb))
	}
	if !strings.EqualFold(repo.FullName, g.Repo) {
		return fmt.Errorf("repos/%s resolved to '%s' (renamed or transferred?) — re-run with the canonical name", g.Repo, repo.FullName)
	}
	g.branch = repo.DefaultBranch
	g.encBranch = uriEscape(repo.DefaultBranch)
	return nil
}

// ListPaths returns every blob path on the default branch via the git trees
// API.
func (g *GH) ListPaths() ([]string, error) {
	comb, err := g.X.Combined("gh", "api", fmt.Sprintf("repos/%s/git/trees/%s?recursive=1", g.Repo, g.encBranch))
	if err != nil {
		return nil, fmt.Errorf("cannot read the file tree: %s", truncate(comb))
	}
	var tree struct {
		Truncated bool `json:"truncated"`
		Tree      []struct {
			Type string `json:"type"`
			Path string `json:"path"`
		} `json:"tree"`
	}
	if json.Unmarshal(comb, &tree) != nil {
		return nil, fmt.Errorf("cannot parse the file tree for %s", g.Repo)
	}
	if tree.Truncated {
		return nil, TruncatedError{Repo: g.Repo}
	}
	var paths []string
	for _, entry := range tree.Tree {
		if entry.Type == "blob" {
			paths = append(paths, entry.Path)
		}
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

// ReadBlob fetches one file's raw contents from the default branch. Any
// error means "treat the file as absent", exactly like the silenced gh call
// it replaces.
func (g *GH) ReadBlob(path string) ([]byte, error) {
	stdout, err := g.X.Output("gh", "api",
		fmt.Sprintf("repos/%s/contents/%s?ref=%s", g.Repo, uriEscape(path), g.encBranch),
		"-H", "Accept: application/vnd.github.raw")
	if err != nil {
		return nil, err
	}
	return stdout, nil
}

// ReadConfig fetches .github/dependabot.yml. Dependabot reads .yml only, so
// a .yaml sitting there alone is a trap: appending to a fresh .yml would
// leave two files and the repo obeying neither. That state is an error, not
// an absence.
func (g *GH) ReadConfig() (string, bool, error) {
	stdout, err := g.X.Output("gh", "api",
		"repos/"+g.Repo+"/contents/.github%2Fdependabot.yml?ref="+g.encBranch,
		"-H", "Accept: application/vnd.github.raw")
	if err == nil {
		return string(stdout), true, nil
	}
	alt, err := g.X.Output("gh", "api",
		"repos/"+g.Repo+"/contents/.github%2Fdependabot.yaml?ref="+g.encBranch,
		"-H", "Accept: application/vnd.github.raw")
	if err == nil && len(alt) > 0 {
		return "", false, errors.New(".github/dependabot.yaml exists but Dependabot reads .github/dependabot.yml — rename it first")
	}
	return "", false, nil
}

// truncate bounds an error body the way head -c 300 did — API errors can be
// whole HTML pages.
func truncate(b []byte) string {
	if len(b) > 300 {
		b = b[:300]
	}
	return string(b)
}

// uriEscape percent-encodes every byte outside RFC 3986's unreserved set,
// faithfully to jq's @uri — url.PathEscape leaves a different set alone, and
// the escaping must match what the bash script sent for the same path.
func uriEscape(s string) string {
	var out strings.Builder
	for _, b := range []byte(s) {
		switch {
		case b >= 'A' && b <= 'Z', b >= 'a' && b <= 'z', b >= '0' && b <= '9',
			b == '-', b == '_', b == '.', b == '~':
			out.WriteByte(b)
		default:
			fmt.Fprintf(&out, "%%%02X", b)
		}
	}
	return out.String()
}
