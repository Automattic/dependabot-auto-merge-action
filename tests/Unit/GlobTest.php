<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Glob\GlobTranslator;
use Automattic\DependabotDirectories\Glob\PatternSet;

it('translates a glob into an anchored matcher', function (string $pattern, array $match, array $reject) {
    $compiled = GlobTranslator::toRegexp($pattern);

    foreach ($match as $subject) {
        expect(GlobTranslator::matches($compiled, $subject))
            ->toBeTrue("{$pattern} must match {$subject}");
    }
    foreach ($reject as $subject) {
        expect(GlobTranslator::matches($compiled, $subject))
            ->toBeFalse("{$pattern} must not match {$subject}");
    }
})->with([
    'single star stays inside one segment' => ['packages/*', ['packages/a', 'packages/a-b'], ['packages', 'packages/a/b', 'packagesx/a']],
    'question mark is one character' => ['a?c', ['abc', 'a-c'], ['ac', 'abbc', 'a/c']],
    // The zero-segment case is the one everyone gets wrong: a/**/b must match
    // a/b as well as a/z/b.
    'globstar covers zero segments' => ['a/**/b', ['a/b', 'a/z/b', 'a/z/y/b'], ['a/zb', 'ab']],
    'trailing globstar crosses slashes' => ['packages/**', ['packages/a', 'packages/a/b'], ['packages']],
    'leading globstar' => ['**x', ['x', 'ax', 'a/bx'], ['xy']],
    'regex metacharacters are literal' => ['p+kg/*', ['p+kg/a'], ['ppkg/a', 'pkg/a']],
    'unicode survives' => ['café/*', ['café/a'], ['cafe/a']],
    // A character class is matched literally, bracket and all.
    'character class is literal' => ['a[b]c', ['a[b]c'], ['abc', 'ab']],
    'spaces survive' => ['my dir/*', ['my dir/a'], ['mydir/a']],
]);

it('resolves patterns against the workspace root', function () {
    $set = PatternSet::build('/', ['packages/*'], fn () => null);
    expect($set->expand(['/packages/a', '/packages/a/b', '/other']))->toBe(['/packages/a']);

    $set = PatternSet::build('/tools', ['pkgs/*'], fn () => null);
    expect($set->expand(['/tools/pkgs/a', '/pkgs/a']))->toBe(['/tools/pkgs/a']);
});

it('subtracts negated patterns', function () {
    $set = PatternSet::build('/', ['packages/*', '!packages/legacy'], fn () => null);

    expect($set->expand(['/packages/a', '/packages/legacy', '/packages/z']))
        ->toBe(['/packages/a', '/packages/z']);
});

it('cleans and skips empty patterns without complaining', function () {
    $notes = [];
    $set = PatternSet::build('/', ['./pkgs/*', 'trail//', '', '!'], function (string $n) use (&$notes) {
        $notes[] = $n;
    });

    expect($set->expand(['/pkgs/a', '/trail', '/other']))->toBe(['/pkgs/a', '/trail']);
    expect($notes)->toBe([]);
});

it('notes a character class rather than pretending to support it', function () {
    $notes = [];
    PatternSet::build('/', ['pkg[ab]/*'], function (string $n) use (&$notes) {
        $notes[] = $n;
    });

    expect($notes)->toBe(["workspace pattern 'pkg[ab]/*' uses a character class, which is matched literally"]);
});

it('matches nothing when there are no positive patterns', function () {
    // A negation alone has nothing to subtract from.
    $set = PatternSet::build('/', ['!packages/legacy'], fn () => null);

    expect($set->expand(['/packages/a', '/packages/legacy']))->toBe([]);
});

it('fails loudly rather than silently reporting no match on a PCRE error', function () {
    // preg_match returns false on a blown backtrack limit, and false is
    // falsy, so letting it flow on would read as "no match" and quietly drop
    // a directory from coverage. The limit is forced down here because
    // realistic path depths never reach the default.
    $limit = ini_get('pcre.backtrack_limit');
    ini_set('pcre.backtrack_limit', '1');

    try {
        $compiled = GlobTranslator::toRegexp('a/**/b');
        $subject = 'a/'.str_repeat('deep/', 50).'b';

        expect(fn () => GlobTranslator::matches($compiled, $subject))
            ->toThrow(RuntimeException::class);
    } finally {
        ini_set('pcre.backtrack_limit', false === $limit ? '1000000' : $limit);
    }
});
