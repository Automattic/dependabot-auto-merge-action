package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"github.com/urfave/cli/v3"
)

// repoRe accepts only a literal owner/repo. gh expands the placeholders
// {owner} and {repo} from GH_REPO or the current checkout, so anything that
// is not strictly literal could address a different repository than the one
// named on the command line.
var repoRe = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$`)

// usageError aborts with exit 2, the message, and the usage text — the
// die_usage of the bash bootstrap scripts. fatalError aborts with exit 2 and
// the message alone (die): the command line was fine, the environment is not.
type usageError struct{ msg string }

func (e usageError) Error() string { return e.msg }

type fatalError struct{ msg string }

func (e fatalError) Error() string { return e.msg }

// options carries every decision made on the command line. It is gathered
// once, after parsing; nothing downstream reads flags.
type options struct {
	repo                 string
	dryRun               bool
	detectOnly           bool
	enableVersionUpdates bool
	force                bool
	include              []string
	pathsFromFile        string
	existingConfigFile   string
}

const descriptionText = `Detect manifest and lockfile locations in a repository and report the
.github/dependabot.yml directory mappings needed to cover them.

Detection is remote — the git trees API, plus a handful of Contents API reads
for workspace declarations. No full clone.

Authentication uses the gh CLI's credentials (gh auth login, or the GH_TOKEN
env var). GH_TOKEN/GITHUB_TOKEN apply to github.com and ghe.com; for GitHub
Enterprise Server set GH_HOST and GH_ENTERPRISE_TOKEN (or
GITHUB_ENTERPRISE_TOKEN). Detection is read-only; a fine-grained PAT scoped
to the repo needs:
   - Contents: Read        (file list and file contents)
   - Metadata: Read        (implied)`

// run executes the tool and returns its exit code: 0 clean, 1 problems,
// 2 usage or environment errors. main is the only caller that turns the code
// into os.Exit; tests call run directly with in-memory writers.
func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	exitCode := 0
	cmd := &cli.Command{
		Name:            "dependabot-directories",
		Usage:           "map dependency manifests and lockfiles into .github/dependabot.yml",
		ArgsUsage:       "<owner/repo>",
		Description:     descriptionText,
		HideHelpCommand: true,
		Writer:          stdout,
		ErrWriter:       stderr,
		Flags: []cli.Flag{
			&cli.BoolFlag{
				Name:  "dry-run",
				Usage: "report the mapping and print a unified diff of the proposed .github/dependabot.yml; currently required — the write path lands in a follow-up",
			},
			&cli.BoolFlag{
				Name:  "detect-only",
				Usage: "print the detected mappings and exit, before any API call",
			},
			&cli.StringSliceFlag{
				Name:  "include",
				Usage: "treat a soft-excluded directory `name` (examples, dist, fixtures, ...) as real; repeatable",
			},
			&cli.BoolFlag{
				Name:  "enable-version-updates",
				Usage: "emit the full house template (open-pull-requests-limit 10 plus minor/patch grouping) instead of the security-only default of 0",
			},
			&cli.BoolFlag{
				Name:  "force",
				Usage: "proceed past the sanity cap of 50 mapped pairs",
			},
			&cli.StringFlag{
				Name:  "paths-from-file",
				Usage: "read the repository file list from `file`, one path per line, instead of calling the API; blob contents are read from <file-without-extension>.blobs/<path> — offline testing seam",
			},
			&cli.StringFlag{
				Name:  "existing-config",
				Usage: "read the current .github/dependabot.yml from `file` instead of the API — offline testing seam",
			},
		},
		// Returning the error unchanged keeps urfave's parse message
		// ("flag provided but not defined: ..."); wrapping it routes the
		// rendering through the one error path below instead of urfave's.
		OnUsageError: func(_ context.Context, _ *cli.Command, err error, _ bool) error {
			return usageError{err.Error()}
		},
		// The default handler calls os.Exit on ExitCoder errors. Exit codes
		// must instead flow back through run so tests can observe them.
		ExitErrHandler: func(context.Context, *cli.Command, error) {},
		Action: func(ctx context.Context, cmd *cli.Command) error {
			opts, err := gatherOptions(cmd)
			if err != nil {
				return err
			}
			exitCode = runPipeline(opts, stdout, stderr)
			return nil
		},
	}

	err := cmd.Run(ctx, append([]string{cmd.Name}, args...))
	if err == nil {
		return exitCode
	}
	var ue usageError
	if errors.As(err, &ue) {
		fmt.Fprintf(stderr, "error: %s\n\n", ue.msg)
		// The usage text accompanies the error, so it belongs on stderr
		// with it.
		cmd.Writer = stderr
		_ = cli.ShowSubcommandHelp(cmd)
		return 2
	}
	fmt.Fprintf(stderr, "error: %s\n", err)
	return 2
}

// gatherOptions validates the parsed command line in the same order the bash
// script did, so the first reported problem stays the same.
func gatherOptions(cmd *cli.Command) (options, error) {
	o := options{
		dryRun:               cmd.Bool("dry-run"),
		detectOnly:           cmd.Bool("detect-only"),
		enableVersionUpdates: cmd.Bool("enable-version-updates"),
		force:                cmd.Bool("force"),
		include:              cmd.StringSlice("include"),
		pathsFromFile:        cmd.String("paths-from-file"),
		existingConfigFile:   cmd.String("existing-config"),
	}

	// urfave/cli consumes the token after --include as its value no matter
	// what it looks like, so a swallowed option can only be caught here,
	// after parsing.
	for _, name := range o.include {
		if name == "" {
			return o, usageError{"--include needs a value"}
		}
		if strings.HasPrefix(name, "-") {
			return o, usageError{fmt.Sprintf("--include needs a value, got option '%s'", name)}
		}
	}

	args := cmd.Args()
	if !args.Present() {
		return o, usageError{"missing required argument: owner/repo"}
	}
	if args.Len() > 1 {
		return o, usageError{fmt.Sprintf("unexpected argument: %s", args.Get(1))}
	}
	o.repo = args.First()
	if !repoRe.MatchString(o.repo) {
		return o, usageError{fmt.Sprintf("invalid repository '%s' — expected owner/repo", o.repo)}
	}

	if o.pathsFromFile != "" {
		if _, err := os.Stat(o.pathsFromFile); err != nil {
			return o, fatalError{fmt.Sprintf("--paths-from-file: no such file: %s", o.pathsFromFile)}
		}
	}
	if o.existingConfigFile != "" {
		if _, err := os.Stat(o.existingConfigFile); err != nil {
			return o, fatalError{fmt.Sprintf("--existing-config: no such file: %s", o.existingConfigFile)}
		}
	}

	if !o.dryRun && !o.detectOnly {
		return o, fatalError{"this revision only reports — re-run with --dry-run (or --detect-only). The write path lands in a follow-up."}
	}
	return o, nil
}
