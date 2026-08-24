<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Console;

/**
 * Every decision made on the command line.
 *
 * Gathered once, after parsing. Nothing downstream reads flags.
 */
final readonly class Options
{
    /**
     * @param list<string> $include
     */
    public function __construct(
        public string $repository,
        public bool $dryRun = false,
        public bool $detectOnly = false,
        public bool $enableVersionUpdates = false,
        public bool $force = false,
        public array $include = [],
        public ?string $pathsFromFile = null,
        public ?string $existingConfigFile = null,
    ) {
    }
}
