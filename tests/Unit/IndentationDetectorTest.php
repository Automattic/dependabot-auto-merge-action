<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Config\IndentationDetector;

it("matches the file's own indentation", function (string $raw, string $item, string $child) {
    expect(IndentationDetector::detect($raw))->toBe([$item, $child]);
})->with([
    'two-space' => ["version: 2\nupdates:\n  - package-ecosystem: \"x\"\n    directory: \"/\"\n", '  ', '    '],
    'four-space' => ["version: 2\nupdates:\n    - package-ecosystem: \"x\"\n      directory: \"/\"\n", '    ', '      '],
    'empty updates keeps the defaults' => ["version: 2\nupdates:\n", '  ', '    '],
    // Prefer what the file actually does over what the dash implies.
    'child key overrides the computed gap' => ["version: 2\nupdates:\n  - package-ecosystem: \"x\"\n     schedule:\n", '  ', '     '],
    'crlf' => ["version: 2\nupdates:\r\n  - package-ecosystem: \"x\"\r\n    directory: \"/\"\r\n", '  ', '    '],
]);
