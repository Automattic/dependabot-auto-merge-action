<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories;

use Automattic\DependabotDirectories\Config\ConfigFile;
use Automattic\DependabotDirectories\Config\CoverageParser;
use Automattic\DependabotDirectories\Config\IndentationDetector;
use Automattic\DependabotDirectories\Config\Planner;
use Automattic\DependabotDirectories\Config\ProposalBuilder;
use Automattic\DependabotDirectories\Config\ShapeGuard;
use Automattic\DependabotDirectories\Config\UnifiedDiff;
use Automattic\DependabotDirectories\Console\Options;
use Automattic\DependabotDirectories\Detection\ActionsDetector;
use Automattic\DependabotDirectories\Detection\ComposerDetector;
use Automattic\DependabotDirectories\Detection\DeferredDetector;
use Automattic\DependabotDirectories\Detection\ExclusionPolicy;
use Automattic\DependabotDirectories\Detection\Grouper;
use Automattic\DependabotDirectories\Detection\NpmDetector;
use Automattic\DependabotDirectories\Detection\Paths;
use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\TruncatedTreeException;
use Automattic\DependabotDirectories\Report\Reporter;
use Automattic\DependabotDirectories\Source\ConfigSource;
use Automattic\DependabotDirectories\Source\Execer;
use Automattic\DependabotDirectories\Source\FixtureConfig;
use Automattic\DependabotDirectories\Source\FixtureTree;
use Automattic\DependabotDirectories\Source\GhRepository;
use Automattic\DependabotDirectories\Source\RealExec;
use Automattic\DependabotDirectories\Source\Uri;
use Automattic\DependabotDirectories\Write\Lander;

/**
 * The run itself, after the command line has been validated: list paths,
 * exclude, detect, group, report, and — outside `--detect-only` — plan the
 * config change and land it as a pull request.
 */
final class Pipeline
{
    /**
     * The mappings a single run may emit. A repo yielding more is far more
     * likely a detection bug than a real configuration; `--force` overrides.
     */
    public const MAX_PAIRS = 50;

    /**
     * @param resource $out
     * @param resource $errOut
     *
     * @return int the process exit code: 0 clean, 1 problems, 2 environment
     */
    public static function run(Options $options, $out, $errOut, ?Execer $exec = null): int
    {
        $exec ??= new RealExec();
        $reporter = new Reporter($out, $errOut);

        // Pick the sources once; nothing downstream knows which mode this is.
        // --paths-from-file swaps in the fixture tree and, without
        // --existing-config, an absent config — offline runs never touch the
        // network. Real mode verifies gh and resolves the repository before
        // anything else.
        $configSource = null;
        $gh = null;

        if (null !== $options->pathsFromFile) {
            $tree = new FixtureTree($options->pathsFromFile);
        } else {
            $gh = new GhRepository($options->repository, $exec);
            try {
                $gh->check();
                $gh->resolve();
            } catch (FatalException $e) {
                fwrite($errOut, sprintf("error: %s\n", $e->getMessage()));

                return 2;
            }
            $tree = $gh;
            $configSource = $gh;
        }

        if (null !== $options->existingConfigFile) {
            $configSource = new FixtureConfig($options->existingConfigFile);
        }

        fwrite($out, sprintf("Scanning %s\n\n", $options->repository));

        try {
            $paths = $tree->listPaths();
        } catch (TruncatedTreeException $e) {
            if (null === $gh) {
                $reporter->fail('cannot read the file list: '.$e->getMessage());

                return 1;
            }
            $reporter->note(sprintf(
                'the git trees API truncated its response for %s — falling back to a blobless clone',
                $options->repository,
            ));
            try {
                $paths = $gh->listPathsByClone($options->allowFullClone, $reporter);
            } catch (\RuntimeException $e) {
                $reporter->fail($e->getMessage());

                return 1;
            }
        } catch (\RuntimeException $e) {
            $reporter->fail('cannot read the file list: '.$e->getMessage());

            return 1;
        }

        // Guard 2 compares candidate globs against these UNFILTERED manifest
        // lists: the glob GitHub expands knows nothing about our exclusions.
        $rawNpm = Paths::dirsOf(Paths::withBasenames($paths, ['package.json']));
        $rawComposer = Paths::dirsOf(Paths::withBasenames($paths, ['composer.json']));

        $split = ExclusionPolicy::split($paths, $options->include);
        if ([] !== $split->soft) {
            $reporter->note(sprintf(
                'skipped %d path(s) under a soft-excluded directory (dist, examples, fixtures, ...) — use --include <dir> to keep one',
                count($split->soft),
            ));
        }

        $pairs = NpmDetector::detect($split->kept, $tree, $reporter);
        $pairs = array_merge($pairs, ComposerDetector::detect($split->kept, $reporter));
        $pairs = array_merge($pairs, ActionsDetector::detect($split->kept));
        DeferredDetector::report($split->kept, $reporter);

        $blocks = Grouper::group($pairs, $rawNpm, $rawComposer, $reporter);

        if ([] === $blocks) {
            $reporter->note(sprintf(
                'no npm, composer or github-actions manifests detected in %s',
                $options->repository,
            ));
            $reporter->blankLine();
            $reporter->summary('would change');

            return 0;
        }

        if (count($blocks) > self::MAX_PAIRS && !$options->force) {
            $reporter->fail(sprintf(
                'detected %d mappings, past the sanity cap of %d — this is far more likely a detection bug than a real layout. Re-run with --force to proceed.',
                count($blocks),
                self::MAX_PAIRS,
            ));
            $reporter->blankLine();
            $reporter->summary('would change');

            return 1;
        }

        $reporter->line('Detected mappings:');
        foreach ($blocks as $block) {
            $reporter->detected($block->isGlob
                ? sprintf('%s: %s (glob)', $block->ecosystem->value, $block->directory)
                : sprintf('%s: %s', $block->ecosystem->value, $block->directory));
        }
        $reporter->blankLine();

        if ($options->detectOnly) {
            $reporter->summary('would change');

            return $reporter->failCount > 0 ? 1 : 0;
        }

        // --dry-run from here: read the existing config, plan the gap, print
        // the diff. A structural refusal stops the run without a summary.
        $raw = '';
        $present = false;
        if ($configSource instanceof ConfigSource) {
            try {
                $existing = $configSource->readConfig();
            } catch (\RuntimeException $e) {
                $reporter->fail($e->getMessage());

                return 1;
            }
            if (null !== $existing) {
                $raw = $existing;
                $present = true;
            }
        }

        $item = '  ';
        $child = '    ';
        $entries = [];

        if ($present) {
            try {
                ShapeGuard::check($raw);
                [$item, $child] = IndentationDetector::detect($raw);
                $entries = CoverageParser::parse($raw);
            } catch (\RuntimeException $e) {
                $reporter->fail($e->getMessage());

                return 1;
            }
        }

        $missing = Planner::planMissing($blocks, $entries, $reporter);
        foreach (CoverageParser::staleNotes($entries, $pairs) as $note) {
            $reporter->note($note);
        }

        $summaryLabel = $options->dryRun ? 'would change' : 'changed';

        if ([] === $missing) {
            $reporter->ok(ConfigFile::PATH.' already covers every detected directory');
            $reporter->blankLine();
            $reporter->summary($summaryLabel);

            return $reporter->failCount > 0 ? 1 : 0;
        }

        $proposal = ProposalBuilder::build(
            $raw,
            $present,
            $missing,
            $item,
            $child,
            $options->enableVersionUpdates,
            $reporter,
        );

        // Printing a diff is not a mutation, so it runs in both modes. Seeing
        // exactly what landed is as useful after the fact as before it.
        //
        // Always a real exec: the diff rendering must come from the same
        // external `diff` the transcripts were captured with, and it is not
        // part of the gh call budget the write path counts.
        $reporter->blankLine();
        UnifiedDiff::render($proposal, new RealExec(), $out, $errOut);
        $reporter->blankLine();

        // The offline seams describe a repository read from disk. There is no
        // branch to push to and no pull request to open, so the report is the
        // whole output. This is a "nowhere to write" guard, not a second
        // reader of the dry-run flag — Lander::mutate stays the only place
        // that inspects it.
        if (null === $gh) {
            $reporter->blankLine();
            $reporter->summary($summaryLabel);

            return $reporter->failCount > 0 ? 1 : 0;
        }

        $lander = new Lander(
            $options->repository,
            $gh->defaultBranch(),
            $gh->encodedBranch(),
            $exec,
            $reporter,
            $options->dryRun,
        );

        if (!$lander->ensureBranch()) {
            $reporter->blankLine();
            $reporter->summary($summaryLabel);

            return 1;
        }

        // A branch already carrying exactly this content needs no write. The
        // proposal is always computed against the base branch, so re-running
        // after the base moves refreshes the branch rather than reverting it.
        $alreadyProposed = false;
        if ($lander->branchExists && $lander->configBodyOn(Uri::escape(Lander::BRANCH)) === $proposal->proposed) {
            $number = $lander->openPullRequestNumber();
            if (null !== $number) {
                $reporter->ok(sprintf(
                    "branch '%s' already proposes exactly this (pull request #%d)",
                    Lander::BRANCH,
                    $number,
                ));
                $reporter->blankLine();
                $reporter->summary($summaryLabel);

                return 0;
            }
            $reporter->ok(sprintf("branch '%s' already carries exactly this content", Lander::BRANCH));
            $alreadyProposed = true;
        }

        if (!$alreadyProposed) {
            $lander->writeConfig($proposal->proposed, $present);
        }

        if (0 === $reporter->failCount) {
            $lander->ensurePullRequest($missing);
        }

        $reporter->blankLine();
        $reporter->summary($summaryLabel);

        return $reporter->failCount > 0 ? 1 : 0;
    }
}
