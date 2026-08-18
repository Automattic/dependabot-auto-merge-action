package detect

import (
	"fmt"
	"sort"
	"strings"

	"github.com/Automattic/dependabot-auto-merge-action/internal/report"
)

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
func Group(pairs []Pair, rawNpm, rawComposer []string, rep *report.Reporter) []Block {
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
