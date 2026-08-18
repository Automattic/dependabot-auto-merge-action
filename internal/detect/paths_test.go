package detect

import (
	"reflect"
	"sort"
	"testing"
)

func TestNormalizeDir(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "/"},
		{".", "/"},
		{"./", "/"},
		{"a", "/a"},
		{"./a", "/a"},
		{"/a", "/a"},
		{"a/", "/a"},
		{"a//", "/a"},
		{"/", "/"},
		{"a/b", "/a/b"},
		{"packages/*", "/packages/*"},
	}
	for _, c := range cases {
		if got := NormalizeDir(c.in); got != c.want {
			t.Errorf("NormalizeDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParentDir(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/", ""}, // sentinel: the root has no parent
		{"/a", "/"},
		{"/a/b", "/a"},
		{"/a/b/c", "/a/b"},
	}
	for _, c := range cases {
		if got := ParentDir(c.in); got != c.want {
			t.Errorf("ParentDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDirsOf(t *testing.T) {
	got := DirsOf([]string{
		"package.json",
		"a/b/x.txt",
		"a/c.json",
		"a/b/y.txt", // duplicate directory
	})
	want := []string{"/", "/a", "/a/b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("DirsOf = %v, want %v", got, want)
	}
}

func TestWithBasenames(t *testing.T) {
	paths := []string{
		"package.json",
		"sub/package.json",
		"sub/package.json5",
		"docs/composer.lock",
		"yarn.lock",
	}
	got := WithBasenames(paths, "package.json", "yarn.lock")
	want := []string{"package.json", "sub/package.json", "yarn.lock"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("WithBasenames = %v, want %v", got, want)
	}
}

func TestSortedUnique(t *testing.T) {
	got := SortedUnique([]string{"b", "a", "b", "c", "a"})
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("SortedUnique = %v, want %v", got, want)
	}
}

// The report's ordering comes from sorting joined "eco|dir|kind" records, the
// way the bash script sorted its record files under LC_ALL=C. That is not the
// same as sorting field-wise: '|' (0x7C) sorts after every letter, so
// "npm|/packages/legacy|0" orders BEFORE "npm|/|0". Sorting fields first and
// joining after would flip them and silently break output parity.
func TestJoinedRecordOrderingMatchesBash(t *testing.T) {
	records := []string{"npm|/|0", "npm|/packages/legacy|0"}
	sort.Strings(records)
	if records[0] != "npm|/packages/legacy|0" {
		t.Errorf("joined-record sort put %q first; bash sort -u orders the longer path first", records[0])
	}
}
