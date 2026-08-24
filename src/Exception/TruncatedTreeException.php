<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Exception;

/**
 * The git trees API refused to return a listing whole.
 *
 * Never proceed on a partial list. A silently incomplete file list is
 * precisely the failure mode this tool exists to prevent. The pipeline
 * answers it with {@see \Automattic\DependabotDirectories\Source\GhRepository::listPathsByClone}.
 */
final class TruncatedTreeException extends \RuntimeException
{
    public function __construct(public readonly string $repository)
    {
        parent::__construct(sprintf('the git trees API truncated its response for %s', $repository));
    }
}
