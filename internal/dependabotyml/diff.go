package dependabotyml

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// UnifiedDiff shows current vs proposed through diff -u, the same rendering
// the bash script used — matching another implementation's hunk headers and
// context selection byte-for-byte is exactly the risk exec avoids. Both
// sides always end in one newline (BuildProposal normalizes), so diff never
// emits "\ No newline at end of file" markers. A missing current diffs
// against /dev/null. Exit status 1 is "differences found"; any real failure
// has already written to stderr, matching the script's `|| true`.
func UnifiedDiff(current *string, proposed string, stdout, stderr io.Writer) {
	dir, err := os.MkdirTemp("", "dependabot-directories")
	if err != nil {
		io.WriteString(stderr, "cannot create a temp dir for diff: "+err.Error()+"\n")
		return
	}
	defer os.RemoveAll(dir)

	aPath := os.DevNull
	if current != nil {
		aPath = filepath.Join(dir, "current.txt")
		if err := os.WriteFile(aPath, []byte(*current), 0o600); err != nil {
			io.WriteString(stderr, "cannot write the diff input: "+err.Error()+"\n")
			return
		}
	}
	bPath := filepath.Join(dir, "proposed.txt")
	if err := os.WriteFile(bPath, []byte(proposed), 0o600); err != nil {
		io.WriteString(stderr, "cannot write the diff input: "+err.Error()+"\n")
		return
	}

	cmd := exec.Command("diff", "-u",
		"--label", "a/"+Path, "--label", "b/"+Path, aPath, bPath)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	_ = cmd.Run()
}
