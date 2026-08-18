// Package source supplies the repository inputs the pipeline consumes: the
// file list, blob contents, and the existing dependabot.yml. One
// implementation reads fixtures from disk (--paths-from-file and
// --existing-config), the other calls gh. Detection never knows which one it
// is talking to — that seam is what lets the heuristics run offline against
// synthetic repositories.
package source

// TreeSource lists a repository's file paths and reads individual blobs.
type TreeSource interface {
	// ListPaths returns every blob path, cleaned, deduplicated and sorted
	// byte-wise.
	ListPaths() ([]string, error)
	// ReadBlob returns one file's contents by repo-relative path. Any error
	// means "treat the file as absent".
	ReadBlob(path string) ([]byte, error)
}

// ConfigSource reads the existing .github/dependabot.yml.
type ConfigSource interface {
	// ReadConfig returns the raw file and whether it exists at all. A
	// non-nil error is fatal to the run — it marks a state that must stop
	// the merge, not a missing file.
	ReadConfig() (raw string, present bool, err error)
}
