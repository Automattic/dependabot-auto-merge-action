<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

/**
 * The two sides of the diff.
 */
final readonly class Proposal
{
    /**
     * @param string|null $current null when no file exists — the diff's "a"
     *                             side is /dev/null then
     */
    public function __construct(
        public ?string $current,
        public string $proposed,
    ) {
    }
}
