<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Exception;

/**
 * The command line was fine, the environment is not. Aborts with exit 2 and
 * the message alone — the `die` of the bash bootstrap scripts.
 */
final class FatalException extends \RuntimeException
{
}
