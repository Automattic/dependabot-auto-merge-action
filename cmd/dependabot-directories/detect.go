package main

import (
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// --- detection --------------------------------------------------------------
//
// Which directories in a repository's file list need a dependabot.yml entry,
// per docs/directory-mapping.md. Everything here is pure — the repository is
// a path list plus a blob reader, never a working tree.

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

// Intersect returns the items present in both sorted lists — comm -12.
func Intersect(a, b []string) []string {
	var out []string
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		switch {
		case a[i] < b[j]:
			i++
		case a[i] > b[j]:
			j++
		default:
			out = append(out, a[i])
			i++
			j++
		}
	}
	return out
}

// Subtract returns the items of sorted a that are not in sorted b — comm -23.
func Subtract(a, b []string) []string {
	var out []string
	i, j := 0, 0
	for i < len(a) {
		switch {
		case j >= len(b) || a[i] < b[j]:
			out = append(out, a[i])
			i++
		case a[i] > b[j]:
			j++
		default:
			i++
			j++
		}
	}
	return out
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

// SplitExclusions applies the hard and soft exclusion lists to a path list.
// Hard-excluded paths vanish; soft-excluded ones come back in soft so the
// caller can report how much was skipped; everything else lands in kept.
// include readmits soft names (and only soft names — a hard exclusion is not
// negotiable). Input order is preserved in both outputs.
func SplitExclusions(paths, include []string) (kept, soft []string) {
	included := make(map[string]bool, len(include))
	for _, name := range include {
		included[name] = true
	}
	softNames := make(map[string]bool, len(SoftExcludes))
	for _, name := range SoftExcludes {
		if !included[name] {
			softNames[name] = true
		}
	}
	hardNames := make(map[string]bool, len(HardExcludes))
	for _, name := range HardExcludes {
		hardNames[name] = true
	}

	for _, p := range paths {
		switch {
		case underAnyDir(p, hardNames):
			// dropped silently
		case underAnyDir(p, softNames):
			soft = append(soft, p)
		default:
			kept = append(kept, p)
		}
	}
	return kept, soft
}

// underAnyDir reports whether any non-final path segment is one of names —
// the exclusions name directories, so a plain file that happens to share the
// name survives.
func underAnyDir(p string, names map[string]bool) bool {
	segments := strings.Split(p, "/")
	for _, seg := range segments[:len(segments)-1] {
		if names[seg] {
			return true
		}
	}
	return false
}

// BlobReader is the one slice of the repository detection reads beyond the
// path list: individual files, for workspace declarations. Defined here, on
// the consumer, so the detect package depends on nothing but the report.
type BlobReader interface {
	ReadBlob(path string) ([]byte, error)
}

// Npm detects the npm-family entries. Roots are directories holding both a
// package.json and a lockfile; a root that declares workspaces covers the
// manifests its patterns match, and covered packages get no entry of their
// own — the rule that prevents per-package entry spam in hoisted monorepos.
func Npm(kept []string, blobs BlobReader, rep *Reporter) []Pair {
	keptSet := make(map[string]bool, len(kept))
	for _, p := range kept {
		keptSet[p] = true
	}

	manifests := DirsOf(WithBasenames(kept, "package.json"))
	locks := DirsOf(WithBasenames(kept, NpmLockfiles...))
	if len(manifests) == 0 {
		return nil
	}

	var roots, covered []string
	for _, dir := range Intersect(locks, manifests) {
		rel := strings.TrimPrefix(dir, "/")
		if rel != "" {
			rel += "/"
		}

		// pnpm before package.json, so a root using both reports its
		// pnpm-workspace.yaml findings first — the order the bash script
		// printed them in.
		var patterns []string
		declared := false
		if keptSet[rel+"pnpm-workspace.yaml"] {
			if body, err := blobs.ReadBlob(rel + "pnpm-workspace.yaml"); err == nil {
				declared = true
				patterns = append(patterns, pnpmWorkspacePatterns(body, dir, rep)...)
			}
		}
		npmPatterns, npmDeclared := npmWorkspacePatterns(blobs, rel, dir, rep)
		patterns = append(patterns, npmPatterns...)
		declared = declared || npmDeclared

		if !declared {
			continue
		}
		roots = append(roots, dir)
		if len(patterns) == 0 {
			continue
		}

		ps := BuildPatterns(dir, patterns, rep.Note)
		for _, c := range ps.Expand(manifests) {
			// A root never covers itself.
			if c != dir {
				covered = append(covered, c)
			}
		}
	}
	roots = SortedUnique(roots)
	covered = SortedUnique(covered)

	var pairs []Pair
	for _, dir := range roots {
		pairs = append(pairs, Pair{Eco: "npm", Dir: dir, Kind: "root"})
	}
	// Lockfiles no workspace covers, minus the roots already emitted.
	for _, dir := range Subtract(Subtract(locks, covered), roots) {
		pairs = append(pairs, Pair{Eco: "npm", Dir: dir, Kind: "lock"})
	}

	// A covered package with its own lockfile: hoisted installs ignore it,
	// and PRs against it would churn a file CI never reads.
	shadowed := Subtract(Intersect(locks, covered), roots)
	rep.NoteGroup(shadowed,
		"with a lockfile shadowed by the workspace covering them — hoisted installs ignore those, so no entry was emitted:")

	// A manifest nobody covers and with no lockfile of its own.
	lockless := Subtract(Subtract(manifests, locks), covered)
	rep.NoteGroup(lockless,
		"with a package.json but no lockfile and no workspace covering them — no entry was emitted:")

	return pairs
}

// npmWorkspacePatterns reads a package.json's workspace patterns, in both
// shapes yarn and npm accept: the plain array, and the yarn v1 object form
// {"packages": [...], "nohoist": [...]}.
func npmWorkspacePatterns(blobs BlobReader, rel, dir string, rep *Reporter) ([]string, bool) {
	body, err := blobs.ReadBlob(rel + "package.json")
	if err != nil {
		return nil, false
	}
	var manifest map[string]any
	if json.Unmarshal(body, &manifest) != nil {
		// Unparseable JSON reads as "no workspaces declared", exactly as
		// the silenced jq call did.
		return nil, false
	}

	switch ws := manifest["workspaces"].(type) {
	case nil:
		return nil, false
	case []any:
		return stringsOf(ws), true
	case map[string]any:
		patterns, _ := ws["packages"].([]any)
		return stringsOf(patterns), true
	default:
		// Treating an unrecognised shape as "no workspaces" is what
		// produces per-package entry spam, so say so rather than guess.
		rep.Note(fmt.Sprintf("package.json at %s declares 'workspaces' as a %s, which is not a shape we recognise — treating it as covering nothing",
			dir, jsonTypeName(ws)))
		return nil, true
	}
}

// pnpmWorkspacePatterns reads a pnpm-workspace.yaml's packages list. "Could
// not parse it" and "it declares nothing" are different facts, and conflating
// them sends people looking for a missing key that is right there —
// WooCommerce's file is the live example: it declares packages: on line 72,
// and every YAML parser rejects the file over a tab on line 4.
func pnpmWorkspacePatterns(body []byte, dir string, rep *Reporter) []string {
	var doc any
	if yaml.Unmarshal(body, &doc) != nil {
		rep.Note(fmt.Sprintf("cannot parse pnpm-workspace.yaml at %s — treating it as covering nothing (a tab character in the indentation is the usual cause)", dir))
		return nil
	}
	var patterns []string
	if m, ok := doc.(map[string]any); ok {
		if list, ok := m["packages"].([]any); ok {
			patterns = stringsOf(list)
		}
	}
	if len(patterns) == 0 {
		rep.Note(fmt.Sprintf("pnpm-workspace.yaml at %s declares no 'packages:' — treating it as covering nothing", dir))
	}
	return patterns
}

// stringsOf keeps the string members of a decoded JSON/YAML list, skipping
// anything else the way jq's select(type == "string") did.
func stringsOf(list []any) []string {
	var out []string
	for _, v := range list {
		if s, ok := v.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

// jsonTypeName names a decoded JSON value the way jq's type builtin does —
// the note text is part of the report contract.
func jsonTypeName(v any) string {
	switch v.(type) {
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64, json.Number:
		return "number"
	default:
		return "unknown"
	}
}

// Composer detects composer entries: a directory needs both a composer.json
// and a composer.lock. A manifest alone is often a library whose consumers
// resolve dependencies, or a committed-vendor WP plugin, so it is reported
// rather than mapped.
func Composer(kept []string, rep *Reporter) []Pair {
	manifests := DirsOf(WithBasenames(kept, "composer.json"))
	locks := DirsOf(WithBasenames(kept, "composer.lock"))
	if len(manifests) == 0 {
		return nil
	}

	var pairs []Pair
	for _, dir := range Intersect(manifests, locks) {
		pairs = append(pairs, Pair{Eco: "composer", Dir: dir, Kind: "lock"})
	}
	rep.NoteGroup(Subtract(manifests, locks),
		"with a composer.json but no composer.lock — no entry was emitted:")
	return pairs
}

var workflowRe = regexp.MustCompile(`^\.github/workflows/[^/]+\.ya?ml$`)

// Actions maps github-actions at the root when any workflow file exists.
func Actions(kept []string) []Pair {
	for _, p := range kept {
		if workflowRe.MatchString(p) {
			return []Pair{{Eco: "github-actions", Dir: "/", Kind: "actions"}}
		}
	}
	return nil
}

// Deferred reports recognizable lockfiles of ecosystems deferred to v1.1, so
// partial coverage is never silent.
func Deferred(kept []string, rep *Reporter) {
	for _, d := range DeferredLockfiles {
		if len(WithBasenames(kept, d.Lockfile)) > 0 {
			rep.Note(fmt.Sprintf("found %s (%s is deferred to v1.1) — those directories are not mapped", d.Lockfile, d.Ecosystem))
		}
	}
}

// Pair is one detected (ecosystem, directory) before grouping. Kind records
// why it was emitted: "root" for workspace roots, "lock" for plain lockfile
// directories, "actions" for the github-actions entry. Grouping reads it —
// roots and github-actions never fold into a glob.
type Pair struct {
	Eco, Dir, Kind string
}

func (p Pair) key() string { return p.Eco + "|" + p.Dir + "|" + p.Kind }

// Block is one dependabot.yml entry to render: a singular directory, or a
// parent glob standing for Members.
type Block struct {
	Eco, Dir string
	IsGlob   bool
	// Members lists the directories a glob stands for, so the coverage
	// pass can degrade it to singular entries when only some of them are
	// already mapped.
	Members []string
}

// SortKey reproduces the bash script's ordering, which sorted joined
// eco|dir|glob records as whole strings. Comparing the fields one at a time
// is NOT the same ordering — '|' sorts after every letter, so
// "npm|/packages/legacy|0" comes before "npm|/|0". See paths_test.go.
func (b Block) SortKey() string {
	glob := "0"
	if b.IsGlob {
		glob = "1"
	}
	return b.Eco + "|" + b.Dir + "|" + glob
}

// sortPairs orders pairs by their joined record and drops duplicates — the
// sort -u the bash script applied to its pairs file.
func sortPairs(pairs []Pair) []Pair {
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].key() < pairs[j].key() })
	out := pairs[:0]
	for i, p := range pairs {
		if i == 0 || p.key() != pairs[i-1].key() {
			out = append(out, p)
		}
	}
	return out
}

// sortBlocks orders blocks by SortKey and drops duplicates.
func sortBlocks(blocks []Block) []Block {
	sort.Slice(blocks, func(i, j int) bool { return blocks[i].SortKey() < blocks[j].SortKey() })
	out := blocks[:0]
	for i, b := range blocks {
		if i == 0 || b.SortKey() != blocks[i-1].SortKey() {
			out = append(out, b)
		}
	}
	return out
}

// Group turns detected pairs into render blocks, folding two or more
// same-ecosystem siblings under one parent into a "parent/*" glob. Workspace
// roots and github-actions are never grouped: the root lockfile already
// absorbs packages added later, so a glob has nothing to gain.
//
// rawNpm and rawComposer are the UNFILTERED manifest directory lists — the
// glob GitHub expands knows nothing about our exclusions, so Guard 2 has to
// measure candidate globs against everything, not just what we kept.
func Group(pairs []Pair, rawNpm, rawComposer []string, rep *Reporter) []Block {
	var blocks []Block
	members := make(map[string][]string) // eco|parent -> sorted member dirs
	globbed := make(map[string]bool)     // eco|dir already standing behind a glob

	for _, p := range sortPairs(pairs) {
		if p.Kind == "root" || p.Eco == "github-actions" {
			blocks = append(blocks, Block{Eco: p.Eco, Dir: p.Dir})
			continue
		}
		key := p.Eco + "|" + ParentDir(p.Dir)
		members[key] = append(members[key], p.Dir)
	}

	keys := make([]string, 0, len(members))
	for key := range members {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		group := SortedUnique(members[key])
		if len(group) < 2 {
			continue
		}
		eco, parent, _ := strings.Cut(key, "|")

		// Guard 1: a parent of / would emit "/*" and sweep every top-level
		// directory in the repository.
		if parent == "" || parent == "/" {
			rep.Note(fmt.Sprintf("%s: %d directories sit at the repository root — keeping singular entries rather than globbing '/*'", eco, len(group)))
			continue
		}

		// Guard 2: the glob must not re-admit what we excluded or map what
		// we did not.
		if !globIsExact(eco, parent, group, rawNpm, rawComposer) {
			rep.Note(fmt.Sprintf("%s: '%s/*' would also match sibling directories this run did not map — keeping singular entries", eco, parent))
			continue
		}

		blocks = append(blocks, Block{Eco: eco, Dir: parent + "/*", IsGlob: true, Members: group})
		for _, dir := range group {
			globbed[eco+"|"+dir] = true
		}
	}

	for _, key := range keys {
		eco, _, _ := strings.Cut(key, "|")
		for _, dir := range SortedUnique(members[key]) {
			if !globbed[eco+"|"+dir] {
				blocks = append(blocks, Block{Eco: eco, Dir: dir})
			}
		}
	}

	return sortBlocks(blocks)
}

// globIsExact reports whether <parent>/* would match exactly the directories
// in group, and nothing more, against the unfiltered manifest list for eco.
func globIsExact(eco, parent string, group, rawNpm, rawComposer []string) bool {
	var raw []string
	switch eco {
	case "npm":
		raw = rawNpm
	case "composer":
		raw = rawComposer
	default:
		return false
	}

	inGroup := make(map[string]bool, len(group))
	for _, dir := range group {
		inGroup[dir] = true
	}
	prefix := parent + "/"
	for _, dir := range raw {
		// A direct child of parent holding a manifest, exclusions ignored.
		if strings.HasPrefix(dir, prefix) && !strings.Contains(dir[len(prefix):], "/") && !inGroup[dir] {
			return false
		}
	}
	return true
}
