<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

use Symfony\Component\Process\Process;

/**
 * Runs commands for real.
 *
 * Always the array form of {@see Process}, which escapes every argument, so a
 * repository path containing shell metacharacters is passed through as one
 * literal argument. Never `Process::fromShellCommandline`.
 */
final class RealExec implements Execer
{
    /**
     * No timeout. A tree listing for a repository the size of jetpack can sit
     * well past Symfony's 60-second default, and a truncated run is worse
     * than a slow one.
     */
    private const TIMEOUT = null;

    public function output(array $argv): ExecResult
    {
        $process = new Process($argv, timeout: self::TIMEOUT);
        $process->run();

        return new ExecResult($process->getOutput(), $process->getExitCode() ?? 1);
    }

    public function combined(array $argv): ExecResult
    {
        $process = new Process($argv, timeout: self::TIMEOUT);

        $combined = '';
        $process->run(static function (string $type, string $buffer) use (&$combined): void {
            $combined .= $buffer;
        });

        return new ExecResult($combined, $process->getExitCode() ?? 1);
    }
}
