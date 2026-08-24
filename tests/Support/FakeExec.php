<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Tests\Support;

use Automattic\DependabotDirectories\Source\Execer;
use Automattic\DependabotDirectories\Source\ExecResult;

/**
 * Scripts responses per command line and records every invocation.
 *
 * The bash suite ran against gh and git stubs on PATH. This plays both parts
 * in-process, which is also what makes the central invariant checkable:
 * `--dry-run` issues no mutating call.
 *
 * An unscripted `gh api` call fails rather than defaulting, so a change to
 * which API calls the tool makes has to be declared in the test.
 */
final class FakeExec implements Execer
{
    /** @var list<list<string>> */
    public array $calls = [];

    /** @var array<string, string> payloads fed to runInput, keyed by the joined argv */
    public array $inputs = [];

    /**
     * The `git ls-tree` listing a clone produces.
     *
     * Null means the clone itself fails, which is how a server without
     * `uploadpack.allowFilter` behaves.
     */
    public ?string $clonePaths = null;

    /**
     * @param array<string, ExecResult> $responses keyed by the argv joined with spaces
     */
    public function __construct(public array $responses = [])
    {
    }

    public function output(array $argv): ExecResult
    {
        return $this->lookup($argv);
    }

    public function combined(array $argv): ExecResult
    {
        return $this->lookup($argv);
    }

    public function runInput(array $argv, string $stdin): ExecResult
    {
        $this->inputs[implode(' ', $argv)] = $stdin;

        return $this->lookup($argv);
    }

    /**
     * @param list<string> $argv
     */
    private function lookup(array $argv): ExecResult
    {
        $this->calls[] = $argv;

        // git and the clone are matched by shape, not by exact argv: the
        // clone destination is a fresh temp directory on every run.
        if (['git', '--version'] === $argv) {
            return new ExecResult('git version 2.0.0', 0);
        }
        if (array_slice($argv, 0, 3) === ['gh', 'repo', 'clone']) {
            return null === $this->clonePaths
                ? new ExecResult('fatal: filter not supported', 1)
                : new ExecResult('', 0);
        }
        if ('git' === ($argv[0] ?? null) && in_array('ls-tree', $argv, true)) {
            return new ExecResult($this->clonePaths ?? '', 0);
        }

        $key = implode(' ', $argv);

        return $this->responses[$key] ?? new ExecResult('unscripted call: '.$key, 1);
    }

    /**
     * Every call that was not a plain read.
     *
     * `gh api -X <METHOD>` is the only shape the mutation funnel issues, so
     * counting those is what proves "--dry-run issues no writes".
     *
     * @return list<list<string>>
     */
    public function mutatingCalls(): array
    {
        return array_values(array_filter(
            $this->calls,
            static fn (array $argv): bool => in_array('-X', $argv, true),
        ));
    }

    /**
     * How many recorded calls contain $fragment as a contiguous substring of
     * the joined argv.
     */
    public function callCount(string $fragment): int
    {
        $count = 0;
        foreach ($this->calls as $argv) {
            if (str_contains(implode(' ', $argv), $fragment)) {
                ++$count;
            }
        }

        return $count;
    }

    /**
     * The payload fed to the one call whose joined argv contains $fragment.
     */
    public function payloadFor(string $fragment): string
    {
        foreach ($this->inputs as $key => $payload) {
            if (str_contains($key, $fragment)) {
                return $payload;
            }
        }

        throw new \RuntimeException('no recorded payload for '.$fragment);
    }
}
