<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * Runs one external command from an argv list — never a shell, so no
 * repository content can ever be interpreted.
 *
 * The two methods are the two capture shapes every original call site used:
 * `output()` is `cmd 2>/dev/null`, `combined()` is `cmd 2>&1`. The write path
 * counts calls through this seam to prove `--dry-run` issues no writes.
 */
interface Execer
{
    /**
     * Run a command, returning stdout and discarding stderr.
     *
     * @param list<string> $argv
     */
    public function output(array $argv): ExecResult;

    /**
     * Run a command, returning stdout and stderr in one stream.
     *
     * @param list<string> $argv
     */
    public function combined(array $argv): ExecResult;

    /**
     * Feed stdin to a command and return stderr alone, discarding stdout —
     * the `2>&1 >/dev/null` shape the mutation funnel captures its error
     * bodies with.
     *
     * @param list<string> $argv
     */
    public function runInput(array $argv, string $stdin): ExecResult;
}
