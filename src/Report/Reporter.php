<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Report;

use Automattic\DependabotDirectories\Detection\Paths;

/**
 * The line-item vocabulary and the counters behind the final summary.
 *
 * The prefixes and spacing are a contract: the offline suite asserts on exact
 * lines, operators grep run output, and the golden transcripts captured from
 * the original implementation are reproduced byte for byte. Nothing here is
 * free to drift.
 *
 * Output goes to two raw stream resources rather than through Symfony
 * Console's OutputInterface. The formatter interprets style tags, so a note
 * containing `<info>` or `<error>` would be stripped without a word, and
 * these lines are a byte-level contract. Today's text would survive it,
 * since unknown tags like the `<dir>` in "use --include <dir> to keep one"
 * pass through untouched, but the margin is not worth spending. Raw streams
 * also give the tests a seam they can assert on directly.
 */
final class Reporter
{
    /**
     * Bound on the examples printed under a grouped note.
     *
     * Real monorepos produce findings by the hundred — a jetpack run emits
     * 270 "manifest without lockfile" findings, which as individual lines is
     * a wall of text nobody reads, and so reports nothing. Collapse to a
     * count plus the first few. Never to silence.
     */
    private const NOTE_SAMPLE = 5;

    public int $okCount = 0;
    public int $changedCount = 0;
    public int $noteCount = 0;
    public int $failCount = 0;

    /**
     * @param resource $out    everything but failures
     * @param resource $errOut failures, matching the original stdout/stderr split
     */
    public function __construct(
        private $out,
        private $errOut,
    ) {
    }

    /**
     * Mark something already in the desired state.
     */
    public function ok(string $message): void
    {
        fwrite($this->out, "✓  {$message}\n");
        ++$this->okCount;
    }

    /**
     * Mark a change this run would make.
     */
    public function would(string $message): void
    {
        fwrite($this->out, "→  {$message}\n");
        ++$this->changedCount;
    }

    /**
     * Mark a finding worth reading that changes nothing.
     */
    public function note(string $message): void
    {
        fwrite($this->out, "!  {$message}\n");
        ++$this->noteCount;
    }

    /**
     * Mark a problem. Any failure turns the exit code to 1.
     */
    public function fail(string $message): void
    {
        fwrite($this->errOut, "✗  {$message}\n");
        ++$this->failCount;
    }

    /**
     * Print an informational detection line. It describes a finding, not an
     * action, so it stays out of the summary counters.
     */
    public function detected(string $message): void
    {
        fwrite($this->out, "   {$message}\n");
    }

    /**
     * Collapse a whole class of findings into one note — a count, the first
     * few directories, and how many were left unprinted.
     *
     * @param list<string> $directories
     */
    public function noteGroup(array $directories, string $summary): void
    {
        $count = count($directories);
        if (0 === $count) {
            return;
        }

        $this->note(sprintf('%d %s %s', $count, Paths::plural($count, 'directory', 'directories'), $summary));

        foreach (array_slice($directories, 0, self::NOTE_SAMPLE) as $directory) {
            fwrite($this->out, "     {$directory}\n");
        }
        if ($count > self::NOTE_SAMPLE) {
            fwrite($this->out, sprintf("     ... and %d more\n", $count - self::NOTE_SAMPLE));
        }
    }

    /**
     * Write a blank line.
     */
    public function blankLine(): void
    {
        fwrite($this->out, "\n");
    }

    /**
     * Write a raw line to the report stream, without a line-item prefix.
     */
    public function line(string $message): void
    {
        fwrite($this->out, "{$message}\n");
    }

    /**
     * Print the closing tally.
     *
     * The blank line usually seen above it belongs to the call sites: the
     * detect-only path prints none, because the mappings block just ended
     * with one.
     */
    public function summary(): void
    {
        fwrite($this->out, sprintf(
            "Summary: %d ok, %d would change, %d notes, %d failed\n",
            $this->okCount,
            $this->changedCount,
            $this->noteCount,
            $this->failCount,
        ));
    }

    /**
     * @return resource
     */
    public function outStream()
    {
        return $this->out;
    }

    /**
     * @return resource
     */
    public function errorStream()
    {
        return $this->errOut;
    }
}
