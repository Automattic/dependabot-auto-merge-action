<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Config\ShapeGuard;

it('refuses a structure an append-only splice cannot reason about', function (string $raw, string $expected) {
    expect(fn () => ShapeGuard::check($raw))
        ->toThrow(RuntimeException::class, $expected);
})->with([
    'tab indentation' => ["version: 2\nupdates:\n\t- package-ecosystem: \"composer\"\n", 'tabs'],
    'space then tab' => ["version: 2\nupdates:\n \t- x\n", 'tabs'],
    'multiple documents' => ["---\na: 1\n---\nb: 2\nupdates:\n", 'more than one YAML document'],
    'anchor' => ["version: 2\ndefaults: &weekly\n  interval: \"weekly\"\nupdates:\n", 'anchors'],
    'alias' => ["version: 2\nupdates:\n  - schedule: *weekly\n", 'anchors'],
    'merge key' => ["version: 2\nupdates:\n  - <<: *base\n", 'anchors'],
    'inline list' => ["version: 2\nupdates: []\n", 'inline form'],
    'inline map' => ["version: 2\nupdates: {}\n", 'inline form'],
    'missing updates' => ["version: 2\n", "no top-level 'updates:'"],
]);

it('accepts a structure it can splice', function (string $raw) {
    ShapeGuard::check($raw);

    expect(true)->toBeTrue();
})->with([
    'plain two-space' => ["version: 2\nupdates:\n  - package-ecosystem: \"composer\"\n    directory: \"/\"\n"],
    // One document marker is a document start, not a second document.
    'single leading marker' => ["---\nversion: 2\nupdates:\n"],
    // [[:space:]] matches \r, so CRLF endings pass every per-line check.
    'crlf' => ["version: 2\nupdates:\r\n  - package-ecosystem: \"composer\"\r\n    directory: \"/x\"\r\n"],
    'comment after updates' => ["version: 2\nupdates: # none yet\n"],
    'glob directory value' => ["version: 2\nupdates:\n  - directories:\n      - \"/p/*\"\n"],
]);
