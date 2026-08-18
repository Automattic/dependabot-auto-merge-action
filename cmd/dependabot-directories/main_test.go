package main

// The end-to-end suite drives run() the way the bats suite drove the bash
// script: through the real CLI with --paths-from-file and --existing-config,
// asserting on the combined output. One buffer receives both stdout and
// stderr because bats' $output merged the streams; keeping that shape lets
// the ported assertions stay line-for-line comparable.

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

// execute runs the tool as a subprocess would see it and returns the exit
// code plus the merged output.
func execute(t *testing.T, args ...string) (int, string) {
	t.Helper()
	var out bytes.Buffer
	code := run(context.Background(), args, &out, &out)
	return code, out.String()
}

func assertContains(t *testing.T, output, want string) {
	t.Helper()
	if !strings.Contains(output, want) {
		t.Errorf("output does not contain %q\noutput:\n%s", want, output)
	}
}

func assertExit(t *testing.T, got, want int, output string) {
	t.Helper()
	if got != want {
		t.Errorf("exit code = %d, want %d\noutput:\n%s", got, want, output)
	}
}

// --- argument validation ----------------------------------------------------

func TestNoArgumentsExits2WithUsage(t *testing.T) {
	code, out := execute(t)
	assertExit(t, code, 2, out)
	assertContains(t, out, "missing required argument")
	assertContains(t, out, "USAGE:")
}

func TestRepoWithoutSlashIsRejected(t *testing.T) {
	code, out := execute(t, "widgets", "--detect-only")
	assertExit(t, code, 2, out)
	assertContains(t, out, "invalid repository")
}

func TestLiteralGhAPIPlaceholdersAreRejected(t *testing.T) {
	code, out := execute(t, "{owner}/{repo}", "--detect-only")
	assertExit(t, code, 2, out)
	assertContains(t, out, "invalid repository")
}

func TestUnknownOptionExits2(t *testing.T) {
	code, out := execute(t, "acme/widgets", "--frobnicate")
	assertExit(t, code, 2, out)
	assertContains(t, out, "frobnicate")
}

func TestIncludeDoesNotSwallowAFollowingOption(t *testing.T) {
	// urfave/cli consumes the next token as the flag's value no matter what
	// it looks like, so `--include --dry-run` parses as include="--dry-run".
	// The post-parse guard turns that back into the usage error the bash
	// script raised at parse time.
	code, out := execute(t, "acme/widgets", "--include", "--dry-run")
	assertExit(t, code, 2, out)
	assertContains(t, out, "--include needs a value")
}

func TestPlainRunRefusesWhileWritePathIsUnimplemented(t *testing.T) {
	code, out := execute(t, "acme/widgets", "--paths-from-file", "testdata/trees/root-npm.paths")
	assertExit(t, code, 2, out)
	assertContains(t, out, "--dry-run")
}

func TestPathsFromFileWithAMissingFileExits2(t *testing.T) {
	code, out := execute(t, "acme/widgets", "--paths-from-file", "/nonexistent/nope.paths", "--detect-only")
	assertExit(t, code, 2, out)
	assertContains(t, out, "no such file")
}
