<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * The outcome of one external command.
 */
final readonly class ExecResult
{
    public function __construct(
        public string $output,
        public int $exitCode,
    ) {
    }

    public function succeeded(): bool
    {
        return 0 === $this->exitCode;
    }

    /**
     * Whether the binary itself could not be found.
     *
     * 127 is the shell's "command not found", which is what a launch failure
     * surfaces as.
     */
    public function notFound(): bool
    {
        return 127 === $this->exitCode;
    }

    /**
     * Bound an error body the way `head -c 300` did — API errors can be whole
     * HTML pages.
     */
    public function truncatedOutput(): string
    {
        return substr($this->output, 0, 300);
    }
}
