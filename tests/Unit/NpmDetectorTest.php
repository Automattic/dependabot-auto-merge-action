<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Detection\Ecosystem;
use Automattic\DependabotDirectories\Detection\NpmDetector;
use Automattic\DependabotDirectories\Detection\PairKind;
use Automattic\DependabotDirectories\Tests\Support\FakeBlobs;

/**
 * @param list<string>          $kept
 * @param array<string, string> $blobs
 *
 * @return array{list<Automattic\DependabotDirectories\Detection\Pair>, string}
 */
function runNpm(array $kept, array $blobs): array
{
    $pairs = [];
    [, $out] = captureReport(function ($reporter) use ($kept, $blobs, &$pairs) {
        $pairs = NpmDetector::detect($kept, new FakeBlobs($blobs), $reporter);
    });

    return [$pairs, $out];
}

it('reads every workspaces shape a package.json can declare', function (string $manifest, bool $wantRoot, bool $wantCovered, string $wantNote) {
    $kept = ['package.json', 'yarn.lock', 'packages/a/package.json'];

    [$pairs, $out] = runNpm($kept, ['package.json' => $manifest]);

    $isRoot = false;
    foreach ($pairs as $pair) {
        if ('/' === $pair->directory && PairKind::Root === $pair->kind) {
            $isRoot = true;
        }
    }
    expect($isRoot)->toBe($wantRoot);

    // Covered means absorbed by the workspace, so no lockless finding for it.
    expect(str_contains($out, '/packages/a'))->toBe(!$wantCovered);

    if ('' !== $wantNote) {
        expect($out)->toContain($wantNote);
    }
})->with([
    'array' => ['{"workspaces":["packages/*"]}', true, true, ''],
    'yarn v1 object' => ['{"workspaces":{"packages":["packages/*"]}}', true, true, ''],
    'object without packages' => ['{"workspaces":{"nohoist":["**/x"]}}', true, false, ''],
    'string shape' => ['{"workspaces":"packages/*"}', true, false, "declares 'workspaces' as a string"],
    'number shape' => ['{"workspaces":7}', true, false, "declares 'workspaces' as a number"],
    'boolean shape' => ['{"workspaces":true}', true, false, "declares 'workspaces' as a boolean"],
    'null' => ['{"workspaces":null}', false, false, ''],
    'absent' => ['{"name":"x"}', false, false, ''],
    'invalid json' => ['{"name":', false, false, ''],
    'non-string members skipped' => ['{"workspaces":["packages/*", 7, null]}', true, true, ''],
]);

it('reads every pnpm-workspace.yaml shape', function (string $yaml, bool $wantCovered, string $wantNote) {
    $kept = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'packages/a/package.json'];

    [$pairs, $out] = runNpm($kept, [
        'package.json' => '{"name":"root"}',
        'pnpm-workspace.yaml' => $yaml,
    ]);

    // Reading pnpm-workspace.yaml declares a workspace no matter what is in
    // it, so the root is always emitted.
    expect($pairs)->not->toBeEmpty();
    expect($pairs[0]->directory)->toBe('/');
    expect($pairs[0]->kind)->toBe(PairKind::Root);

    expect(str_contains($out, '/packages/a'))->toBe(!$wantCovered);

    if ('' !== $wantNote) {
        expect($out)->toContain($wantNote);
    }
})->with([
    'packages honoured' => ["packages:\n  - 'packages/*'\n", true, ''],
    'no packages key' => ["onlyBuiltDependencies:\n  - esbuild\n", false, "declares no 'packages:'"],
    // "Cannot parse it" and "it declares nothing" are different facts, and
    // conflating them sends people looking for a key that is right there.
    'tab indentation' => ["packages:\n\t- 'packages/*'\n", false, 'cannot parse pnpm-workspace.yaml'],
    'packages not a list' => ["packages: everything\n", false, "declares no 'packages:'"],
    'top level not a map' => ["- just\n- a\n- list\n", false, "declares no 'packages:'"],
    'empty file' => ['', false, "declares no 'packages:'"],
]);

it('reports a shadowed lockfile rather than mapping it', function () {
    // Hoisted installs ignore it, and PRs against it would churn a file CI
    // never reads.
    [$pairs, $out] = runNpm([
        'package.json', 'yarn.lock',
        'packages/a/package.json',
        'packages/b/package.json', 'packages/b/package-lock.json',
    ], ['package.json' => '{"workspaces":["packages/*"]}']);

    expect($pairs)->toHaveCount(1);
    expect($pairs[0]->ecosystem)->toBe(Ecosystem::Npm);
    expect($pairs[0]->directory)->toBe('/');
    expect($pairs[0]->kind)->toBe(PairKind::Root);

    expect($out)->toContain('shadowed by the workspace')->toContain("     /packages/b\n");
});

it('gives an uncovered lockfile its own entry', function () {
    [$pairs] = runNpm([
        'package.json', 'yarn.lock',
        'packages/a/package.json',
        'packages/legacy/package.json', 'packages/legacy/yarn.lock',
    ], ['package.json' => '{"workspaces":["packages/*","!packages/legacy"]}']);

    expect($pairs)->toHaveCount(2);
    expect($pairs[0]->directory)->toBe('/');
    expect($pairs[0]->kind)->toBe(PairKind::Root);
    expect($pairs[1]->directory)->toBe('/packages/legacy');
    expect($pairs[1]->kind)->toBe(PairKind::Lock);
});

it('says nothing at all when there are no manifests', function () {
    [$pairs, $out] = runNpm(['src/main.rs'], []);

    expect($pairs)->toBe([]);
    expect($out)->toBe('');
});
