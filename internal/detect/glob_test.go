package detect

import (
	"reflect"
	"testing"
)

func TestGlobToRegexp(t *testing.T) {
	cases := []struct {
		pattern string
		match   []string
		reject  []string
	}{
		{"packages/*", []string{"packages/a", "packages/a-b"}, []string{"packages", "packages/a/b", "packagesx/a"}},
		{"a?c", []string{"abc", "a-c"}, []string{"ac", "abbc", "a/c"}},
		// The zero-segment case is the one everyone gets wrong: a/**/b must
		// match a/b as well as a/z/b.
		{"a/**/b", []string{"a/b", "a/z/b", "a/z/y/b"}, []string{"a/zb", "ab"}},
		{"packages/**", []string{"packages/a", "packages/a/b"}, []string{"packages"}},
		{"**x", []string{"x", "ax", "a/bx"}, []string{"xy"}},
		{"p+kg/*", []string{"p+kg/a"}, []string{"ppkg/a", "pkg/a"}},
		{"café/*", []string{"café/a"}, []string{"cafe/a"}},
		// A character class is matched literally, bracket and all.
		{"a[b]c", []string{"a[b]c"}, []string{"abc", "ab"}},
		{"my dir/*", []string{"my dir/a"}, []string{"mydir/a"}},
	}
	for _, c := range cases {
		re := GlobToRegexp(c.pattern)
		for _, s := range c.match {
			if !re.MatchString(s) {
				t.Errorf("GlobToRegexp(%q) = %v must match %q", c.pattern, re, s)
			}
		}
		for _, s := range c.reject {
			if re.MatchString(s) {
				t.Errorf("GlobToRegexp(%q) = %v must not match %q", c.pattern, re, s)
			}
		}
	}
}

func collectNotes() (func(string), *[]string) {
	var notes []string
	return func(msg string) { notes = append(notes, msg) }, &notes
}

func TestBuildPatternsResolvesAgainstTheRoot(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"packages/*"}, note)
	if got := ps.Expand([]string{"/packages/a", "/packages/a/b", "/other"}); !reflect.DeepEqual(got, []string{"/packages/a"}) {
		t.Errorf("Expand = %v", got)
	}

	ps = BuildPatterns("/tools", []string{"pkgs/*"}, note)
	if got := ps.Expand([]string{"/tools/pkgs/a", "/pkgs/a"}); !reflect.DeepEqual(got, []string{"/tools/pkgs/a"}) {
		t.Errorf("Expand = %v", got)
	}
}

func TestBuildPatternsNegation(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"packages/*", "!packages/legacy"}, note)
	got := ps.Expand([]string{"/packages/a", "/packages/legacy", "/packages/z"})
	if want := []string{"/packages/a", "/packages/z"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Expand = %v, want %v", got, want)
	}
}

func TestBuildPatternsCleansAndSkips(t *testing.T) {
	note, notes := collectNotes()
	ps := BuildPatterns("/", []string{"./pkgs/*", "trail//", "", "!"}, note)
	got := ps.Expand([]string{"/pkgs/a", "/trail", "/other"})
	if want := []string{"/pkgs/a", "/trail"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Expand = %v, want %v", got, want)
	}
	if len(*notes) != 0 {
		t.Errorf("unexpected notes %v", *notes)
	}
}

func TestBuildPatternsNotesCharacterClasses(t *testing.T) {
	note, notes := collectNotes()
	BuildPatterns("/", []string{"pkg[ab]/*"}, note)
	want := "workspace pattern 'pkg[ab]/*' uses a character class, which is matched literally"
	if len(*notes) != 1 || (*notes)[0] != want {
		t.Errorf("notes = %v, want [%q]", *notes, want)
	}
}

func TestExpandWithNoPositivePatternsMatchesNothing(t *testing.T) {
	note, _ := collectNotes()
	ps := BuildPatterns("/", []string{"!packages/legacy"}, note)
	if got := ps.Expand([]string{"/packages/a", "/packages/legacy"}); len(got) != 0 {
		// A negation with no positive patterns has nothing to subtract from.
		t.Errorf("Expand = %v, want empty", got)
	}
}
