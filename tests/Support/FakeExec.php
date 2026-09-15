<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Tests\Support;

use Automattic\DependabotDirectories\Source\Execer;
use Automattic\DependabotDirectories\Source\ExecResult;

/**
 * Scripts responses per command line and records every invocation.
 *
 * An unscripted call is a failure rather than a default, so a test that
 * changes which API calls the tool makes has to say so.
 */
final class FakeExec implements Execer
{
    /** @var list<list<string>> */
    public array $calls = [];

    /**
     * @param array<string, ExecResult> $responses keyed by the argv joined with spaces
     */
    public function __construct(public array $responses = [])
    {
    }

    /**
     * Record a call and return its scripted response.
     *
     * @param list<string> $argv
     */
    private function lookup(array $argv): ExecResult
    {
        $this->calls[] = $argv;
        $key = implode(' ', $argv);

        return $this->responses[$key] ?? new ExecResult('unscripted call: '.$key, 1);
    }

    public function output(array $argv): ExecResult
    {
        return $this->lookup($argv);
    }

    public function combined(array $argv): ExecResult
    {
        return $this->lookup($argv);
    }

    /**
     * Every call that was not a plain GET through `gh api`.
     *
     * The write path proves "--dry-run issues no writes" by asserting this is
     * empty.
     *
     * @return list<list<string>>
     */
    public function mutatingCalls(): array
    {
        return array_values(array_filter(
            $this->calls,
            static fn (array $argv): bool => in_array('-X', $argv, true)
                || in_array('--method', $argv, true)
                || in_array('-f', $argv, true),
        ));
    }
}
