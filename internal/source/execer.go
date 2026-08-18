package source

import (
	"bytes"
	"io"
	"os/exec"
)

// Execer runs one external command from an argv slice — never a shell, so no
// repository content can ever be interpreted. Its two methods are the two
// capture shapes every bash call site used: Output is `cmd 2>/dev/null`,
// Combined is `cmd 2>&1`. The write-path follow-up counts calls through this
// seam to prove --dry-run issues no writes.
type Execer interface {
	// Output returns stdout, discarding stderr.
	Output(name string, args ...string) ([]byte, error)
	// Combined returns stdout and stderr interleaved in one stream.
	Combined(name string, args ...string) ([]byte, error)
}

// RealExec runs commands for real.
type RealExec struct{}

func (RealExec) Output(name string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return out.Bytes(), err
}

func (RealExec) Combined(name string, args ...string) ([]byte, error) {
	// The same value on both streams matters: os/exec only shares one pipe
	// (and so preserves interleaving without a data race) when Stderr is
	// interface-equal to Stdout.
	var buf bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.Bytes(), err
}
