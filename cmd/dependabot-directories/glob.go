package main

import (
	"fmt"
	"regexp"
	"strings"
)

// GlobToRegexp translates a workspace glob into an anchored regexp:
//
//	packages/*   ->  ^packages/[^/]*$
//	packages/**  ->  ^packages/.*$
//	a/**/b       ->  ^a/(.*/)?b$      (matches a/b as well as a/z/b)
//
// There is no working tree to glob against — only a path list — so the
// pattern has to become a matcher over strings. Runes are quoted one at a
// time with regexp.QuoteMeta rather than blanket-escaped: RE2 rejects a
// backslash before a letter it has no meaning for, which is exactly what
// blanket escaping produces on non-ASCII.
func GlobToRegexp(pat string) *regexp.Regexp {
	var out strings.Builder
	out.WriteString("^")
	runes := []rune(pat)
	for i := 0; i < len(runes); i++ {
		switch runes[i] {
		case '*':
			if i+1 < len(runes) && runes[i+1] == '*' {
				i++
				if i+1 < len(runes) && runes[i+1] == '/' {
					// The zero-segment case is the one everyone gets
					// wrong: a/**/b must match a/b.
					out.WriteString("(.*/)?")
					i++
				} else {
					out.WriteString(".*")
				}
				continue
			}
			out.WriteString("[^/]*")
		case '?':
			out.WriteString("[^/]")
		default:
			out.WriteString(regexp.QuoteMeta(string(runes[i])))
		}
	}
	out.WriteString("$")
	return regexp.MustCompile(out.String())
}

// PatternSet is a workspace's glob patterns split into positive and negative
// matchers, resolved against the workspace root.
type PatternSet struct {
	pos []*regexp.Regexp
	neg []*regexp.Regexp
}

// BuildPatterns resolves workspace patterns against root. note receives one
// line per pattern that uses a character class, which this translation
// matches literally rather than as a class.
func BuildPatterns(root string, patterns []string, note func(string)) PatternSet {
	var ps PatternSet
	prefix := strings.TrimSuffix(root, "/")

	for _, pat := range patterns {
		pat = strings.TrimPrefix(pat, "./")
		for strings.HasSuffix(pat, "/") && len(pat) > 1 {
			pat = strings.TrimSuffix(pat, "/")
		}
		if pat == "" {
			continue
		}
		if strings.Contains(pat, "[") {
			note(fmt.Sprintf("workspace pattern '%s' uses a character class, which is matched literally", pat))
		}
		target := &ps.pos
		if strings.HasPrefix(pat, "!") {
			target = &ps.neg
			pat = strings.TrimPrefix(pat, "!")
			if pat == "" {
				continue
			}
		}
		*target = append(*target, GlobToRegexp(prefix+"/"+strings.TrimPrefix(pat, "/")))
	}
	return ps
}

// Expand returns the candidates matched by at least one positive pattern and
// no negative one, preserving candidate order. No positive patterns means
// nothing is covered — a negation alone has nothing to subtract from.
func (ps PatternSet) Expand(candidates []string) []string {
	if len(ps.pos) == 0 {
		return nil
	}
	var out []string
candidates:
	for _, c := range candidates {
		for _, re := range ps.neg {
			if re.MatchString(c) {
				continue candidates
			}
		}
		for _, re := range ps.pos {
			if re.MatchString(c) {
				out = append(out, c)
				continue candidates
			}
		}
	}
	return out
}
