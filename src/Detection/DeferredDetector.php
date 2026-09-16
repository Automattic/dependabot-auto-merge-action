<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

use Automattic\DependabotDirectories\Report\Reporter;

/**
 * Report recognizable lockfiles of ecosystems deferred to v1.1, so partial
 * coverage is never silent.
 */
final class DeferredDetector
{
    /**
     * Lockfile basename => ecosystem. Order is report order.
     *
     * @var array<string, string>
     */
    public const LOCKFILES = [
        'Gemfile.lock' => 'bundler',
        'go.sum' => 'gomod',
        'Cargo.lock' => 'cargo',
        'poetry.lock' => 'pip',
        'uv.lock' => 'pip',
    ];

    /**
     * @param list<string> $kept
     */
    public static function report(array $kept, Reporter $reporter): void
    {
        foreach (self::LOCKFILES as $lockfile => $ecosystem) {
            if ([] !== Paths::withBasenames($kept, [$lockfile])) {
                $reporter->note(sprintf(
                    'found %s (%s is deferred to v1.1) — those directories are not mapped',
                    $lockfile,
                    $ecosystem,
                ));
            }
        }
    }
}
