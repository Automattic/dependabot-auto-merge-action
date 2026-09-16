<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

use Automattic\DependabotDirectories\Report\Reporter;

/**
 * A directory needs both a composer.json and a composer.lock.
 *
 * A manifest alone is often a library whose consumers resolve dependencies,
 * or a committed-vendor WP plugin, so it is reported rather than mapped.
 */
final class ComposerDetector
{
    /**
     * @param list<string> $kept
     *
     * @return list<Pair>
     */
    public static function detect(array $kept, Reporter $reporter): array
    {
        $manifests = Paths::dirsOf(Paths::withBasenames($kept, ['composer.json']));
        $locks = Paths::dirsOf(Paths::withBasenames($kept, ['composer.lock']));

        if ([] === $manifests) {
            return [];
        }

        $pairs = [];
        foreach (Paths::intersect($manifests, $locks) as $directory) {
            $pairs[] = new Pair(Ecosystem::Composer, $directory, PairKind::Lock);
        }

        $reporter->noteGroup(
            Paths::subtract($manifests, $locks),
            'with a composer.json but no composer.lock — no entry was emitted:',
        );

        return $pairs;
    }
}
