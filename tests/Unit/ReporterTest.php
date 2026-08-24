<?php

declare(strict_types=1);

/*
 * The line prefixes are part of the tool's contract — the bats suite asserted
 * on them and the golden transcripts pin them byte for byte — so these tests
 * spell them out as literals rather than reusing the constants under test.
 */

it('writes each line item with its prefix and counts it', function () {
    [$reporter, $out, $err] = captureReport(function ($r) {
        $r->ok('a');
        $r->would('b');
        $r->note('c');
        $r->detected('d');
    });

    expect($out)->toBe("✓  a\n→  b\n!  c\n   d\n");
    expect($err)->toBe('');
    expect([$reporter->okCount, $reporter->changedCount, $reporter->noteCount])->toBe([1, 1, 1]);
});

it('writes failures to stderr and counts them', function () {
    [$reporter, $out, $err] = captureReport(fn ($r) => $r->fail('boom'));

    expect($out)->toBe('');
    expect($err)->toBe("✗  boom\n");
    expect($reporter->failCount)->toBe(1);
});

it('does not count a detection line', function () {
    // It describes a finding, not an action.
    [$reporter] = captureReport(fn ($r) => $r->detected('x'));

    expect($reporter->okCount + $reporter->changedCount + $reporter->noteCount + $reporter->failCount)
        ->toBe(0);
});

it('prints nothing for an empty note group', function () {
    [$reporter, $out] = captureReport(fn ($r) => $r->noteGroup([], 'irrelevant:'));

    expect($out)->toBe('');
    expect($reporter->noteCount)->toBe(0);
});

it('uses the singular for a one-item note group', function () {
    [$reporter, $out] = captureReport(fn ($r) => $r->noteGroup(['/a'], 'with a problem:'));

    expect($out)->toBe("!  1 directory with a problem:\n     /a\n");
    expect($reporter->noteCount)->toBe(1);
});

it('prints all five at the sample boundary without an overflow line', function () {
    [, $out] = captureReport(fn ($r) => $r->noteGroup(['/a', '/b', '/c', '/d', '/e'], 'found:'));

    expect($out)->toContain("!  5 directories found:\n")->not->toContain('more');
    foreach (['/a', '/b', '/c', '/d', '/e'] as $dir) {
        expect($out)->toContain("     {$dir}\n");
    }
});

it('collapses past the sample boundary to a count and a tail', function () {
    // A jetpack run emits 270 of these. As individual lines that is a wall of
    // text nobody reads, and so reports nothing.
    [, $out] = captureReport(fn ($r) => $r->noteGroup(['/a', '/b', '/c', '/d', '/e', '/f', '/g'], 'found:'));

    expect($out)->toContain("!  7 directories found:\n")
        ->toContain("     ... and 2 more\n")
        ->not->toContain('/f')
        ->not->toContain('/g');
});

it('prints the summary with no leading blank line', function () {
    // The blank line above it belongs to the call sites: the detect-only path
    // prints none, every other path prints one.
    [, $out] = captureReport(function ($r) {
        $r->ok('a');
        $r->fail('b');
        $r->summary();
    });

    expect($out)->toEndWith("Summary: 1 ok, 0 would change, 0 notes, 1 failed\n");
});
