package detect

import (
	"encoding/json"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

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
func Npm(kept []string, blobs BlobReader, rep *report.Reporter) []Pair {
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
func npmWorkspacePatterns(blobs BlobReader, rel, dir string, rep *report.Reporter) ([]string, bool) {
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
func pnpmWorkspacePatterns(body []byte, dir string, rep *report.Reporter) []string {
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
