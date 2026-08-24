<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

/**
 * One (ecosystem, directory) an existing config maps.
 *
 * The directory is verbatim from the file; matching normalizes it.
 */
final readonly class CoverageEntry
{
    public function __construct(
        public string $ecosystem,
        public string $directory,
    ) {
    }
}
