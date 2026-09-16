<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * The offline ConfigSource behind `--existing-config`.
 *
 * A missing file means "the repository has no dependabot.yml yet", not an
 * error.
 */
final readonly class FixtureConfig implements ConfigSource
{
    public function __construct(private string $path)
    {
    }

    public function readConfig(): ?string
    {
        if (!is_file($this->path)) {
            return null;
        }

        $raw = file_get_contents($this->path);
        if (false === $raw) {
            throw new \RuntimeException(sprintf('cannot read %s', $this->path));
        }

        return $raw;
    }
}
