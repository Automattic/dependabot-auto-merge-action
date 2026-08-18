package detect

import (
	"fmt"
	"regexp"

	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

// Composer detects composer entries: a directory needs both a composer.json
// and a composer.lock. A manifest alone is often a library whose consumers
// resolve dependencies, or a committed-vendor WP plugin, so it is reported
// rather than mapped.
func Composer(kept []string, rep *report.Reporter) []Pair {
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
func Deferred(kept []string, rep *report.Reporter) {
	for _, d := range DeferredLockfiles {
		if len(WithBasenames(kept, d.Lockfile)) > 0 {
			rep.Note(fmt.Sprintf("found %s (%s is deferred to v1.1) — those directories are not mapped", d.Lockfile, d.Ecosystem))
		}
	}
}
