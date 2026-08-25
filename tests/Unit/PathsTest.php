<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Detection\Paths;

it('normalizes a directory onto the leading-slash form', function (string $in, string $want) {
    expect(Paths::normalizeDir($in))->toBe($want);
})->with([
    ['', '/'],
    ['.', '/'],
    ['./', '/'],
    ['a', '/a'],
    ['./a', '/a'],
    ['/a', '/a'],
    ['a/', '/a'],
    ['a//', '/a'],
    ['/', '/'],
    ['a/b', '/a/b'],
    ['packages/*', '/packages/*'],
]);

it('returns the parent of a normalized directory', function (string $in, string $want) {
    expect(Paths::parentDir($in))->toBe($want);
})->with([
    // The root has no parent, and the empty string is that sentinel.
    ['/', ''],
    ['/a', '/'],
    ['/a/b', '/a'],
    ['/a/b/c', '/a/b'],
]);

it('maps paths to sorted unique directories', function () {
    expect(Paths::dirsOf([
        'package.json',
        'a/b/x.txt',
        'a/c.json',
        'a/b/y.txt', // duplicate directory
    ]))->toBe(['/', '/a', '/a/b']);
});

it('selects paths by basename, keeping input order', function () {
    expect(Paths::withBasenames([
        'package.json',
        'sub/package.json',
        'sub/package.json5',
        'docs/composer.lock',
        'yarn.lock',
    ], ['package.json', 'yarn.lock']))->toBe(['package.json', 'sub/package.json', 'yarn.lock']);
});

it('sorts and deduplicates', function () {
    expect(Paths::sortedUnique(['b', 'a', 'b', 'c', 'a']))->toBe(['a', 'b', 'c']);
});

it('sorts byte-wise, not numerically', function () {
    // PHP's bare sort() defaults to SORT_REGULAR and would order these
    // 1, 9, 10 by comparing them as numbers. The report's line ordering is
    // the LC_ALL=C collation the bash script forced, so every sort here goes
    // through strcmp.
    expect(Paths::sortedUnique(['10', '9', '1']))->toBe(['1', '10', '9']);
});

it('orders joined records the way the bash sort did', function () {
    // The report's ordering comes from sorting joined "eco|dir|kind" records.
    // That is not the same as sorting field-wise: '|' (0x7C) sorts after
    // every letter, so "npm|/packages/legacy|0" orders BEFORE "npm|/|0".
    // Sorting fields first and joining after would flip them and silently
    // break output parity.
    expect(Paths::sortedUnique(['npm|/|0', 'npm|/packages/legacy|0'])[0])
        ->toBe('npm|/packages/legacy|0');
});

it('intersects and subtracts sorted lists', function () {
    $a = ['/a', '/b', '/c'];
    $b = ['/b', '/d'];

    expect(Paths::intersect($a, $b))->toBe(['/b']);
    expect(Paths::subtract($a, $b))->toBe(['/a', '/c']);
    expect(Paths::subtract($b, $a))->toBe(['/d']);
});

it('picks the plural form matching the count', function (int $n, string $want) {
    expect(Paths::plural($n, 'entry', 'entries'))->toBe($want);
})->with([[1, 'entry'], [0, 'entries'], [2, 'entries']]);
