// Package detect holds the detection heuristics: which directories in a
// repository's file list need a .github/dependabot.yml entry, per
// docs/directory-mapping.md. Everything here is pure — the repository is a
// path list plus a blob reader, never a working tree.
package detect

import (
	"path"
	"sort"
	"strings"
)

// Ecosystem policy, as resolved in the spec (§2, §4). Exported so the command
// can name them in report text without a second copy drifting.
var (
	// HardExcludes never hold first-party manifests; they are dropped
	// silently and --include cannot readmit them.
	HardExcludes = []string{"node_modules", "vendor", "bower_components", ".git"}

	// SoftExcludes usually hold copies, samples or build output. Matching
	// paths are reported and skipped; --include readmits a name.
	SoftExcludes = []string{"fixtures", "__fixtures__", "testdata", "examples", "example", "dist", "build", ".next", "coverage"}

	// NpmLockfiles are the lockfile basenames the npm family writes.
	NpmLockfiles = []string{"package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml"}

	// DeferredLockfiles are recognizable ecosystems deferred to v1.1.
	// Seeing one is reported so that partial coverage is never silent.
	DeferredLockfiles = []struct{ Lockfile, Ecosystem string }{
		{"Gemfile.lock", "bundler"},
		{"go.sum", "gomod"},
		{"Cargo.lock", "cargo"},
		{"poetry.lock", "pip"},
		{"uv.lock", "pip"},
	}
)

// NormalizeDir maps "", "." and relative spellings onto the leading-slash
// directory form the report uses: "/" for the root, "/a/b" otherwise.
func NormalizeDir(d string) string {
	d = strings.TrimPrefix(d, "./")
	if d == "" || d == "." {
		return "/"
	}
	if !strings.HasPrefix(d, "/") {
		d = "/" + d
	}
	for strings.HasSuffix(d, "/") && d != "/" {
		d = strings.TrimSuffix(d, "/")
	}
	return d
}

// ParentDir returns the parent of a normalized directory, and "" for the
// root — the sentinel for "no parent".
func ParentDir(d string) string {
	if d == "/" {
		return ""
	}
	parent := d[:strings.LastIndex(d, "/")]
	if parent == "" {
		return "/"
	}
	return parent
}

// DirsOf maps repo-relative file paths to their normalized directories,
// sorted and deduplicated.
func DirsOf(paths []string) []string {
	dirs := make([]string, 0, len(paths))
	for _, p := range paths {
		dir := ""
		if i := strings.LastIndex(p, "/"); i >= 0 {
			dir = p[:i]
		}
		dirs = append(dirs, NormalizeDir(dir))
	}
	return SortedUnique(dirs)
}

// WithBasenames selects the paths whose basename is one of names, keeping
// input order.
func WithBasenames(paths []string, names ...string) []string {
	want := make(map[string]bool, len(names))
	for _, n := range names {
		want[n] = true
	}
	var out []string
	for _, p := range paths {
		if want[path.Base(p)] {
			out = append(out, p)
		}
	}
	return out
}

// SortedUnique sorts byte-wise and drops duplicates. Go's string ordering is
// the ordering the bash script forced with LC_ALL=C, so every list that flows
// into the report keeps the exact same line order on every machine.
func SortedUnique(items []string) []string {
	out := append([]string(nil), items...)
	sort.Strings(out)
	return slicesCompact(out)
}

// slicesCompact removes adjacent duplicates in place.
func slicesCompact(sorted []string) []string {
	if len(sorted) == 0 {
		return sorted
	}
	w := 1
	for _, s := range sorted[1:] {
		if s != sorted[w-1] {
			sorted[w] = s
			w++
		}
	}
	return sorted[:w]
}
