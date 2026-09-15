<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Detection\Ecosystem;
use Automattic\DependabotDirectories\Detection\Grouper;
use Automattic\DependabotDirectories\Detection\Pair;
use Automattic\DependabotDirectories\Detection\PairKind;

/**
 * @param list<Pair>   $pairs
 * @param list<string> $rawNpm
 * @param list<string> $rawComposer
 *
 * @return array{list<Block>, string}
 */
function runGroup(array $pairs, array $rawNpm = [], array $rawComposer = []): array
{
    $blocks = [];
    [, $out] = captureReport(function ($reporter) use ($pairs, $rawNpm, $rawComposer, &$blocks) {
        $blocks = Grouper::group($pairs, $rawNpm, $rawComposer, $reporter);
    });

    return [$blocks, $out];
}

function composerLock(string $directory): Pair
{
    return new Pair(Ecosystem::Composer, $directory, PairKind::Lock);
}

it('collapses exact siblings into a glob', function () {
    [$blocks, $out] = runGroup(
        [composerLock('/plugins/a'), composerLock('/plugins/b')],
        rawComposer: ['/plugins/a', '/plugins/b'],
    );

    expect($blocks)->toHaveCount(1);
    expect($blocks[0]->directory)->toBe('/plugins/*');
    expect($blocks[0]->isGlob)->toBeTrue();
    expect($blocks[0]->members)->toBe(['/plugins/a', '/plugins/b']);
    expect($out)->toBe('');
});

it('keeps singulars when the parent is the repository root', function () {
    // Guard 1: a parent of / emits "/*" and sweeps every top-level directory.
    [$blocks, $out] = runGroup(
        [composerLock('/a'), composerLock('/b')],
        rawComposer: ['/a', '/b'],
    );

    expect($blocks)->toHaveCount(2);
    expect(array_map(fn (Block $b) => $b->directory, $blocks))->toBe(['/a', '/b']);
    expect($out)->toContain('repository root');
});

it('keeps singulars when a glob would sweep an unmapped sibling', function () {
    // Guard 2, with a lockless sibling the run did not map.
    [$blocks, $out] = runGroup(
        [composerLock('/plugins/a'), composerLock('/plugins/b')],
        rawComposer: ['/plugins/a', '/plugins/b', '/plugins/c'],
    );

    expect(array_map(fn (Block $b) => $b->directory, $blocks))->toBe(['/plugins/a', '/plugins/b']);
    expect($out)->toContain('did not map');
});

it('measures guard 2 against soft-excluded siblings too', function () {
    // The raw list ignores exclusions on purpose: the glob GitHub expands
    // knows nothing about our exclusion list.
    [$blocks] = runGroup(
        [composerLock('/plugins/a'), composerLock('/plugins/b')],
        rawComposer: ['/plugins/a', '/plugins/b', '/plugins/fixtures'],
    );

    foreach ($blocks as $block) {
        expect($block->isGlob)->toBeFalse();
    }
});

it('never groups workspace roots or github-actions', function () {
    // The root lockfile already absorbs packages added later, so a glob has
    // nothing to gain.
    [$blocks] = runGroup([
        new Pair(Ecosystem::Npm, '/apps/a', PairKind::Root),
        new Pair(Ecosystem::Npm, '/apps/b', PairKind::Root),
        new Pair(Ecosystem::GithubActions, '/', PairKind::Actions),
    ], rawNpm: ['/apps/a', '/apps/b']);

    expect($blocks)->toHaveCount(3);
    foreach ($blocks as $block) {
        expect($block->isGlob)->toBeFalse();
    }
});

it('never lets two ecosystems share a glob', function () {
    [$blocks] = runGroup([
        composerLock('/plugins/a'),
        new Pair(Ecosystem::Npm, '/plugins/b', PairKind::Lock),
    ], rawNpm: ['/plugins/b'], rawComposer: ['/plugins/a']);

    foreach ($blocks as $block) {
        expect($block->isGlob)->toBeFalse();
    }
});

it('orders blocks by the joined record', function () {
    // '|' sorts after 'p', so the longer path comes first — the sort -u
    // ordering the report contract pins.
    [$blocks] = runGroup([
        new Pair(Ecosystem::Npm, '/', PairKind::Root),
        new Pair(Ecosystem::Npm, '/packages/legacy', PairKind::Lock),
    ], rawNpm: ['/', '/packages/legacy']);

    expect(array_map(fn (Block $b) => $b->directory, $blocks))->toBe(['/packages/legacy', '/']);
});
