<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

/**
 * Where Dependabot reads its configuration.
 */
final class ConfigFile
{
    /**
     * Nowhere else. A `.yaml` sibling is a trap the reader checks for
     * separately: appending to a fresh `.yml` would leave two files and the
     * repository obeying neither.
     */
    public const PATH = '.github/dependabot.yml';

    public const ALTERNATE_PATH = '.github/dependabot.yaml';
}
