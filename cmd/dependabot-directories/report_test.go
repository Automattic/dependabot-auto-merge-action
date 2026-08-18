package main

import (
	"bytes"
	"strings"
	"testing"
)

// The line prefixes are part of the tool's contract — the bats suite asserted
// on them and the golden transcripts pin them byte-for-byte — so these tests
// spell them out as literals rather than reusing the constants under test.

func TestLinePrefixesAndCounters(t *testing.T) {
	var out, errOut bytes.Buffer
	r := newReporter(&out, &errOut)

	r.OK("a")
	r.Would("b")
	r.Note("c")
	r.Detected("d")

	want := "✓  a\n→  b\n!  c\n   d\n"
	if out.String() != want {
		t.Errorf("stdout = %q, want %q", out.String(), want)
	}
	if errOut.Len() != 0 {
		t.Errorf("stderr = %q, want empty", errOut.String())
	}
	if r.OKCount != 1 || r.ChangedCount != 1 || r.NoteCount != 1 {
		t.Errorf("counters = %d ok, %d changed, %d notes; want 1, 1, 1",
			r.OKCount, r.ChangedCount, r.NoteCount)
	}
}

func TestFailWritesToStderrAndCounts(t *testing.T) {
	var out, errOut bytes.Buffer
	r := newReporter(&out, &errOut)

	r.Fail("boom")

	if out.Len() != 0 {
		t.Errorf("stdout = %q, want empty", out.String())
	}
	if got, want := errOut.String(), "✗  boom\n"; got != want {
		t.Errorf("stderr = %q, want %q", got, want)
	}
	if r.FailCount != 1 {
		t.Errorf("FailCount = %d, want 1", r.FailCount)
	}
}

func TestDetectedIsNotCounted(t *testing.T) {
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.Detected("x")
	if r.OKCount+r.ChangedCount+r.NoteCount+r.FailCount != 0 {
		t.Error("Detected must not move any counter")
	}
}

func TestNoteGroupEmpty(t *testing.T) {
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.NoteGroup(nil, "irrelevant:")
	if out.Len() != 0 || r.NoteCount != 0 {
		t.Errorf("empty group must print nothing, got %q", out.String())
	}
}

func TestNoteGroupSingular(t *testing.T) {
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.NoteGroup([]string{"/a"}, "with a problem:")
	want := "!  1 directory with a problem:\n     /a\n"
	if out.String() != want {
		t.Errorf("output = %q, want %q", out.String(), want)
	}
	if r.NoteCount != 1 {
		t.Errorf("NoteCount = %d, want 1 (one note per group)", r.NoteCount)
	}
}

func TestNoteGroupAtTheSampleBoundary(t *testing.T) {
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.NoteGroup([]string{"/a", "/b", "/c", "/d", "/e"}, "found:")
	got := out.String()
	if strings.Contains(got, "more") {
		t.Errorf("five items must print without a '... and N more' line, got %q", got)
	}
	if !strings.Contains(got, "!  5 directories found:\n") {
		t.Errorf("missing count line in %q", got)
	}
	for _, d := range []string{"/a", "/b", "/c", "/d", "/e"} {
		if !strings.Contains(got, "     "+d+"\n") {
			t.Errorf("missing example %q in %q", d, got)
		}
	}
}

func TestNoteGroupPastTheSampleBoundary(t *testing.T) {
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.NoteGroup([]string{"/a", "/b", "/c", "/d", "/e", "/f", "/g"}, "found:")
	got := out.String()
	if !strings.Contains(got, "!  7 directories found:\n") {
		t.Errorf("missing count line in %q", got)
	}
	if !strings.Contains(got, "     ... and 2 more\n") {
		t.Errorf("missing overflow line in %q", got)
	}
	if strings.Contains(got, "/f") || strings.Contains(got, "/g") {
		t.Errorf("items past the sample must not be printed, got %q", got)
	}
}

func TestPlural(t *testing.T) {
	if got := Plural(1, "entry", "entries"); got != "entry" {
		t.Errorf("Plural(1) = %q", got)
	}
	if got := Plural(0, "entry", "entries"); got != "entries" {
		t.Errorf("Plural(0) = %q", got)
	}
	if got := Plural(2, "entry", "entries"); got != "entries" {
		t.Errorf("Plural(2) = %q", got)
	}
}

func TestSummaryHasNoLeadingBlankLine(t *testing.T) {
	// The blank line before the summary belongs to the call sites: the
	// detect-only path prints none, every other path prints one.
	var out bytes.Buffer
	r := newReporter(&out, &out)
	r.OK("a")
	r.Fail("b")
	out.Reset()
	r.Summary()
	if got, want := out.String(), "Summary: 1 ok, 0 would change, 0 notes, 1 failed\n"; got != want {
		t.Errorf("summary = %q, want %q", got, want)
	}
}
