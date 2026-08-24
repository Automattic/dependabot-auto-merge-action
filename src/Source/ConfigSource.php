<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * Reads the existing .github/dependabot.yml.
 */
interface ConfigSource
{
    /**
     * The raw file, or null when the repository has none.
     *
     * A thrown exception is fatal to the run — it marks a state that must
     * stop the merge, not a missing file.
     *
     * @throws \RuntimeException
     */
    public function readConfig(): ?string;
}
