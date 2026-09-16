<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Exception;

/**
 * The command line was wrong. Aborts with exit 2, the message, and the usage
 * text — the `die_usage` of the bash bootstrap scripts.
 */
final class UsageException extends \RuntimeException
{
}
