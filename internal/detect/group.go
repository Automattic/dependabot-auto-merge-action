package detect

import (
	"sort"
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

// Group turns detected pairs into render blocks. Grouping proper — folding
// same-parent siblings into a glob — lands with the guards; for now every
// pair is its own singular block.
func Group(pairs []Pair) []Block {
	var blocks []Block
	for _, p := range sortPairs(pairs) {
		blocks = append(blocks, Block{Eco: p.Eco, Dir: p.Dir})
	}
	return sortBlocks(blocks)
}
