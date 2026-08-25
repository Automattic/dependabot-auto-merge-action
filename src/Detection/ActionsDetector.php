<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * Map github-actions at the root when any workflow file exists.
 */
final class ActionsDetector
{
    private const WORKFLOW = '#^\.github/workflows/[^/]+\.ya?ml$#';

    /**
     * @param list<string> $kept
     *
     * @return list<Pair>
     */
    public static function detect(array $kept): array
    {
        foreach ($kept as $path) {
            if (1 === preg_match(self::WORKFLOW, $path)) {
                return [new Pair(Ecosystem::GithubActions, '/', PairKind::Actions)];
            }
        }

        return [];
    }
}
