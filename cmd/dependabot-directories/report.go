package main

import (
	"fmt"
	"io"
)

// --- report -----------------------------------------------------------------
//
// The line-item vocabulary and the counters behind the final summary. The
// prefixes and spacing are a contract: the offline test suite asserts on
// exact lines, and operators grep run output, so nothing here is free to
// drift.

// noteSample bounds the examples printed under a grouped note. Real monorepos
// produce findings by the hundred — a jetpack run emitted 270 "manifest
// without lockfile" lines, which is a wall of text nobody reads and so
// reports nothing. Collapse to a count plus the first few, never to silence.
const noteSample = 5

// Reporter writes the report and counts what it wrote. Fail goes to errOut,
// everything else to out — the same split the bash script had between stdout
// and stderr.
type Reporter struct {
	out    io.Writer
	errOut io.Writer

	OKCount      int
	ChangedCount int
	NoteCount    int
	FailCount    int
}

func newReporter(out, errOut io.Writer) *Reporter {
	return &Reporter{out: out, errOut: errOut}
}

// OK marks something already in the desired state.
func (r *Reporter) OK(msg string) {
	fmt.Fprintf(r.out, "✓  %s\n", msg)
	r.OKCount++
}

// Would marks a change this run would make.
func (r *Reporter) Would(msg string) {
	fmt.Fprintf(r.out, "→  %s\n", msg)
	r.ChangedCount++
}

// Note marks a finding worth reading that changes nothing.
func (r *Reporter) Note(msg string) {
	fmt.Fprintf(r.out, "!  %s\n", msg)
	r.NoteCount++
}

// Fail marks a problem; any Fail turns the exit code to 1.
func (r *Reporter) Fail(msg string) {
	fmt.Fprintf(r.errOut, "✗  %s\n", msg)
	r.FailCount++
}

// Detected prints an informational detection line. It describes a finding,
// not an action, so it stays out of the summary counters.
func (r *Reporter) Detected(msg string) {
	fmt.Fprintf(r.out, "   %s\n", msg)
}

// NoteGroup collapses a whole class of findings into one note — a count, the
// first few directories, and how many were left unprinted.
func (r *Reporter) NoteGroup(dirs []string, summary string) {
	n := len(dirs)
	if n == 0 {
		return
	}
	r.Note(fmt.Sprintf("%d %s %s", n, Plural(n, "directory", "directories"), summary))
	for i, dir := range dirs {
		if i == noteSample {
			break
		}
		fmt.Fprintf(r.out, "     %s\n", dir)
	}
	if n > noteSample {
		fmt.Fprintf(r.out, "     ... and %d more\n", n-noteSample)
	}
}

// Summary prints the closing tally. The blank line usually seen above it
// belongs to the call sites: the detect-only path prints none because the
// mappings block just ended with one.
func (r *Reporter) Summary() {
	fmt.Fprintf(r.out, "Summary: %d ok, %d would change, %d notes, %d failed\n",
		r.OKCount, r.ChangedCount, r.NoteCount, r.FailCount)
}

// Plural picks the form matching n.
func Plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
