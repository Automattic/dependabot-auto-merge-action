package detect

import "strings"

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
