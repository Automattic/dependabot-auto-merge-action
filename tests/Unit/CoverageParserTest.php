<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Config\CoverageEntry;
use Automattic\DependabotDirectories\Config\CoverageParser;
use Automattic\DependabotDirectories\Detection\Ecosystem;
use Automattic\DependabotDirectories\Detection\Pair;
use Automattic\DependabotDirectories\Detection\PairKind;

/**
 * @param list<CoverageEntry> $entries
 *
 * @return list<array{string, string}>
 */
function flatten(array $entries): array
{
    return array_map(
        static fn (CoverageEntry $e): array => [$e->ecosystem, $e->directory],
        $entries,
    );
}

it('lists what the file already maps', function (string $raw, array $want) {
    expect(flatten(CoverageParser::parse($raw)))->toBe($want);
})->with([
    'singular directory' => [
        "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n",
        [['composer', '/']],
    ],
    'directories array' => [
        "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directories:\n      - \"/a\"\n      - \"/b\"\n",
        [['composer', '/a'], ['composer', '/b']],
    ],
    'array and singular together' => [
        "version: 2\nupdates:\n  - package-ecosystem: \"npm\"\n    directories:\n      - \"/a\"\n    directory: \"/b\"\n",
        [['npm', '/a'], ['npm', '/b']],
    ],
    // Entries carrying target-branch are invisible to Dependabot's security
    // updates, so they never count as coverage.
    'target-branch skipped' => [
        "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n    target-branch: \"develop\"\n",
        [],
    ],
    'empty updates' => ["version: 2\nupdates:\n", []],
    'missing ecosystem becomes ?' => ["version: 2\nupdates:\n  - directory: \"/\"\n", [['?', '/']]],
    'scalar values are stringified' => [
        "version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: 2025\n",
        [['composer', '2025']],
    ],
]);

it('refuses to guess at a config it cannot read', function (string $raw, string $expected) {
    expect(fn () => CoverageParser::parse($raw))
        ->toThrow(RuntimeException::class, $expected);
})->with([
    'broken yaml' => ["version: 2\nupdates:\n  - [oops\n", 'cannot parse'],
    // Symfony Yaml refuses duplicate keys where the bash shim's backends
    // silently took the last value — the fail-closed direction.
    'duplicate keys' => ["version: 2\nversion: 3\nupdates:\n", 'cannot parse'],
    'updates not a list' => ["version: 2\nupdates: 3\n", 'not a list'],
    'scalar entry' => ["version: 2\nupdates:\n  - just-a-string\n", 'cannot read the update entries'],
    'top level is a sequence' => ["- a\n- b\n", 'cannot read the update entries'],
]);

it('decides whether a directory is already covered', function (string $eco, string $dir, bool $want) {
    $entries = [
        new CoverageEntry('composer', '/'),
        new CoverageEntry('npm', 'packages/a'), // no leading slash in the file
        new CoverageEntry('composer', '/projects/plugins/*'),
    ];

    expect(CoverageParser::covers($entries, Ecosystem::from($eco), $dir))->toBe($want);
})->with([
    ['composer', '/', true],
    ['npm', '/', false],
    // The entry normalizes to /packages/a.
    ['npm', '/packages/a', true],
    // An existing glob counts: matching it beats emitting a duplicate
    // Dependabot would reject the whole config over.
    ['composer', '/projects/plugins/b', true],
    // * does not cross a slash.
    ['composer', '/projects/plugins/b/c', false],
    ['composer', '/other', false],
]);

it('honours a question-mark glob in an existing entry', function () {
    $entries = [new CoverageEntry('npm', '/pkg?')];

    expect(CoverageParser::covers($entries, Ecosystem::Npm, '/pkg1'))->toBeTrue();
    expect(CoverageParser::covers($entries, Ecosystem::Npm, '/pkg12'))->toBeFalse();
});

it('reports a stale entry rather than removing it', function () {
    $entries = [
        new CoverageEntry('composer', '/gone'),
        new CoverageEntry('composer', '/'),
        new CoverageEntry('npm', '/p/*'), // globs are never called stale
    ];
    $pairs = [new Pair(Ecosystem::Composer, '/', PairKind::Lock)];

    expect(CoverageParser::staleNotes($entries, $pairs))
        ->toBe(['existing entry (composer, /gone) matches nothing we detected — left alone']);
});

it('has nothing stale to report when the file maps nothing', function () {
    expect(CoverageParser::staleNotes([], [new Pair(Ecosystem::Npm, '/', PairKind::Root)]))->toBe([]);
});
