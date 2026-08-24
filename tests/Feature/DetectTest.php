<?php

declare(strict_types=1);

/*
 * Ports of the bats detection tests, one for one, driving the real CLI over
 * the tree fixtures in --detect-only mode.
 */

// --- npm detection ----------------------------------------------------------

it('maps the root once for a root npm repo', function () {
    [$code, $out] = detectFixture('root-npm');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')
        ->toListMapping('github-actions: /')
        ->toListMappingCount(2);
});

it('maps only the workspace root, not every package', function () {
    [$code, $out] = detectFixture('yarn-workspaces');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')
        // The rule that prevents per-package entry spam in hoisted monorepos.
        ->toNotListMapping('/packages/a');
});

it('reports a workspace-covered package with its own lockfile rather than mapping it', function () {
    [, $out] = detectFixture('yarn-workspaces');

    expect($out)->toNotListMapping('/packages/b')
        ->toContain('shadowed by the workspace')
        ->toNoteExample('/packages/b');
});

it('reports an uncovered manifest with no lockfile rather than mapping it', function () {
    [, $out] = detectFixture('yarn-workspaces');

    expect($out)->toNotListMapping('/tools/helper')
        ->toContain('no lockfile and no workspace covering them')
        ->toNoteExample('/tools/helper');
});

it('parses the yarn v1 object form of workspaces', function () {
    [$code, $out] = detectFixture('workspaces-object-form');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')->toListMappingCount(1)
        // Parsed means covered: neither package may surface as an entry or a
        // finding.
        ->toNotNoteExample('/packages/a')
        ->toNotNoteExample('/packages/b');
});

it('leaves a negated workspace package to fend for itself', function () {
    [$code, $out] = detectFixture('workspaces-negation');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')
        // Excluded from the workspace and holding its own lockfile, so it
        // needs an entry.
        ->toListMapping('npm: /packages/legacy');
});

it('covers the zero-segment globstar case', function () {
    [$code, $out] = detectFixture('workspaces-globstar');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')
        // apps/**/web must match apps/web as well as apps/deep/nested/web.
        ->toNotNoteExample('/apps/web')
        ->toNotNoteExample('/apps/deep/nested/web')
        // Outside the pattern, so it is still reported.
        ->toNoteExample('/other/thing');
});

it('reports an unrecognised workspaces shape rather than assuming it absent', function () {
    [$code, $out] = detectFixture('workspaces-unknown-shape');

    expect($code)->toBe(0);
    expect($out)->toContain('not a shape we recognise')->toListMapping('npm: /');
});

it('honours pnpm-workspace.yaml packages', function () {
    [$code, $out] = detectFixture('pnpm');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')->toListMappingCount(1);
});

it('reports a pnpm workspace with no packages key', function () {
    [$code, $out] = detectFixture('pnpm-no-packages-key');

    expect($code)->toBe(0);
    expect($out)->toContain("declares no 'packages:'")->toListMapping('npm: /');
});

// --- composer detection -----------------------------------------------------

it('needs both a composer manifest and a lock', function () {
    [$code, $out] = detectFixture('composer-single');

    expect($code)->toBe(0);
    expect($out)->toListMapping('composer: /');
});

// --- exclusions -------------------------------------------------------------

it('drops hard-excluded directories silently', function () {
    [$code, $out] = detectFixture('excluded');

    expect($code)->toBe(0);
    expect($out)->toNotListMapping('node_modules')
        ->toNotListMapping('vendor')
        // Silent means silent: not even a note.
        ->not->toContain('node_modules');
});

it('drops soft-excluded directories with a note', function () {
    [, $out] = detectFixture('excluded');

    expect($out)->toNotListMapping('examples')->toContain('soft-excluded');
});

it('readmits a soft-excluded directory with --include', function () {
    [$code, $out] = detectFixture('excluded', ['--include', 'examples']);

    expect($code)->toBe(0);
    expect($out)->toListMapping('composer: /examples/demo');
});

it('accepts the --include=value form', function () {
    [$code] = detectFixture('excluded', ['--include=examples']);

    expect($code)->toBe(0);
});

// --- deferred ecosystems ----------------------------------------------------

it('reports deferred-ecosystem lockfiles', function () {
    [$code, $out] = detectFixture('deferred-ecosystems');

    expect($code)->toBe(0);
    foreach (['Gemfile.lock', 'go.sum', 'Cargo.lock', 'poetry.lock', 'uv.lock'] as $lockfile) {
        expect($out)->toContain($lockfile);
    }
    expect($out)->toListMapping('composer: /');
});

// --- mixed and empty --------------------------------------------------------

it('reports and exits clean for a repo with no manifests', function () {
    [$code, $out] = detectFixture('no-manifests');

    expect($code)->toBe(0);
    expect($out)->toContain('no npm, composer or github-actions manifests');
});

it('maps github-actions at the root for workflows alone', function () {
    [$code, $out] = detectFixture('actions-only');

    expect($code)->toBe(0);
    expect($out)->toListMapping('github-actions: /')->toListMappingCount(1);
});

// --- grouping and guards ----------------------------------------------------

it('collapses sibling composer packages into one glob', function () {
    [$code, $out] = detectFixture('composer-siblings');

    expect($code)->toBe(0);
    expect($out)->toListMapping('composer: /projects/plugins/* (glob)')->toListMappingCount(1);
});

it('degrades to singulars when a glob would sweep an unmapped sibling', function () {
    [$code, $out] = detectFixture('composer-siblings-lockless');

    expect($code)->toBe(0);
    expect($out)->toNotListMapping('*')
        ->toListMapping('composer: /projects/plugins/a')
        ->toListMapping('composer: /projects/plugins/b')
        ->toListMapping('composer: /projects/plugins/c')
        ->toContain('did not map')
        // d has a manifest but no lock, so it is reported and never mapped.
        ->toNotListMapping('/projects/plugins/d');
});

it('never produces a root glob for top-level siblings', function () {
    [$code, $out] = detectFixture('top-level-siblings');

    expect($code)->toBe(0);
    expect($out)->toNotListMapping('*')
        ->toListMapping('composer: /a')
        ->toListMapping('composer: /b')
        ->toContain('repository root');
});

// --- awkward paths ----------------------------------------------------------

it('survives regex metacharacters and unicode in paths', function () {
    [$code, $out] = detectFixture('weird-paths');

    expect($code)->toBe(0);
    expect($out)->toListMapping('composer: /my dir')
        ->toListMapping('composer: /p+kg')
        ->toListMapping('composer: /br[ack]et')
        ->toListMapping('composer: /uni_café');
});

it('processes a path containing a pipe like any other', function () {
    // The bash script skipped these paths to protect its '|'-delimited record
    // format and said so with a note. The record format is gone, so the pipe
    // directory flows through detection like any other: it holds a
    // composer.json with no lock, which lands it in that note group.
    [, $out] = detectFixture('weird-paths');

    expect($out)->not->toContain("containing '|'");
    expect($out)->toNotListMapping('bad|pipe')->toNoteExample('/bad|pipe');
});

// --- mixed ------------------------------------------------------------------

it('maps the pnpm root and globs the composer plugins in a mixed monorepo', function () {
    [$code, $out] = detectFixture('mixed-monorepo');

    expect($code)->toBe(0);
    expect($out)->toListMapping('npm: /')
        ->toListMapping('composer: /projects/plugins/* (glob)')
        ->toListMapping('github-actions: /');
});

// --- sanity cap -------------------------------------------------------------

it('stops an implausible number of mappings unless forced', function () {
    $tree = '';
    for ($i = 1; $i <= 60; ++$i) {
        $tree .= "pkg{$i}/composer.json\npkg{$i}/composer.lock\n";
    }
    $pathsFile = sys_get_temp_dir().'/many-'.bin2hex(random_bytes(6)).'.paths';
    file_put_contents($pathsFile, $tree);

    [$code, $out] = runTool(['acme/widgets', '--paths-from-file', $pathsFile, '--detect-only']);
    expect($code)->toBe(1);
    expect($out)->toContain('sanity cap');

    [$code] = runTool(['acme/widgets', '--paths-from-file', $pathsFile, '--detect-only', '--force']);
    expect($code)->toBe(0);

    unlink($pathsFile);
});
