// Command dependabot-directories detects where dependency manifests and
// lockfiles actually live in a repository and maps them into
// .github/dependabot.yml.
//
// Dependabot only updates a lockfile it has been pointed at. Where the
// lockfile is not at the default path — workspaces, monorepos, any non-root
// lockfile — security PRs ship without the lockfile update, CI stays red, and
// auto-merge never fires. See docs/directory-mapping.md for the full spec.
//
// This revision computes and reports the mapping. Writing it back (branch,
// Contents API, pull request) lands in a follow-up, so --dry-run is required.
package main

import (
	"context"
	"os"
)

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Stdout, os.Stderr))
}
