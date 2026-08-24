<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * A path list split by the exclusion policy.
 */
final readonly class ExclusionResult
{
    /**
     * @param list<string> $kept paths detection should consider
     * @param list<string> $soft paths skipped under a soft exclusion, kept so
     *                           the caller can report how much was skipped
     */
    public function __construct(
        public array $kept,
        public array $soft,
    ) {
    }
}
