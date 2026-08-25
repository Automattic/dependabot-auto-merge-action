<?php

declare(strict_types=1);

/*
 * Ports of the bats coverage, refusal and template tests, plus the three
 * parser-era tests that replaced the two bats tests of the deleted YAML
 * backend shim.
 */

// --- coverage of an existing config -----------------------------------------

it('produces no changes for a fully covering singular entry', function () {
    [$code, $out] = mergeFixture('composer-single', 'covered-singular.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('already covers every detected directory')
        ->toContain('0 would change');
});

it('treats an existing glob as covering the directories it expands to', function () {
    [$code, $out] = mergeFixture('composer-siblings', 'covered-glob.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('already mapped')->not->toContain('+  - package-ecosystem');
});

it('does not count a target-branch entry as coverage', function () {
    // Dependabot's security updates ignore target-branch entries, so counting
    // one as coverage would reintroduce the very bug this tool exists to fix.
    [$code, $out] = mergeFixture('composer-single', 'target-branch.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"');
});

it('appends only the gap and degrades the glob on partial coverage', function () {
    [$code, $out] = mergeFixture('composer-siblings', 'partial-commented.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('would overlap')
        ->toContain('directory: "/projects/plugins/b"')
        ->toContain('directory: "/projects/plugins/c"')
        // Overlapping entries are what make Dependabot reject a config
        // outright.
        ->not->toContain('"/projects/plugins/*"');
});

it('reports an existing entry we detected nothing for rather than removing it', function () {
    [$code, $out] = mergeFixture('composer-single', 'stale-entry.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('matches nothing we detected')->not->toContain('-  - package-ecosystem');
});

it('preserves comments and key order outside the appended region', function () {
    [$code, $out] = mergeFixture('composer-siblings', 'partial-commented.yml');

    expect($code)->toBe(0);
    // An append-only text splice: nothing in the original may show as removed.
    expect($out)->not->toContain('-# Managed by the platform team')
        ->not->toContain('-  # the first plugin only');
});

it("matches the file's own indentation rather than ours", function () {
    [$code, $out] = mergeFixture('composer-single', 'four-space-indent.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+    - package-ecosystem: "composer"')
        ->toContain('+      directory: "/"');
});

it('treats an updates key with no items as a valid append target', function () {
    [$code, $out] = mergeFixture('composer-single', 'empty-updates.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"');
});

it('does not swallow a following top-level key', function () {
    [$code, $out] = mergeFixture('composer-single', 'registries-after.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"')->not->toContain('-registries:');
});

// --- refusals ---------------------------------------------------------------

it('refuses a structure it cannot reason about', function (string $config, string $expected) {
    [$code, $out] = mergeFixture('composer-single', $config);

    expect($code)->toBe(1);
    expect($out)->toContain($expected);
})->with([
    'inline updates form' => ['inline-updates.yml', 'inline form'],
    'tab indentation' => ['tab-indent.yml', 'tabs'],
    'anchors and aliases' => ['anchors.yml', 'anchors'],
]);

it('stops on an unparseable config rather than appending blindly', function () {
    $broken = sys_get_temp_dir().'/broken-'.bin2hex(random_bytes(6)).'.yml';
    file_put_contents($broken, "version: 2\nupdates:\n  - [oops\n");

    [$code, $out] = runTool([
        'acme/widgets',
        '--paths-from-file', fixturePath('trees', 'composer-single.paths'),
        '--existing-config', $broken,
        '--dry-run',
    ]);

    expect($code)->toBe(1);
    // Never fall through to "nothing is covered, append everything".
    expect($out)->not->toContain('+  - package-ecosystem');

    unlink($broken);
});

// --- entry template ---------------------------------------------------------

it('defaults entries to security-only', function () {
    [, $out] = mergeFixture('composer-single', 'empty-updates.yml');

    expect($out)->toContain('open-pull-requests-limit: 0')->not->toContain('groups:');
});

it('swaps in the full house template with --enable-version-updates', function () {
    [, $out] = mergeFixture('composer-single', 'empty-updates.yml', ['--enable-version-updates']);

    expect($out)->toContain('open-pull-requests-limit: 10')
        ->toContain('composer-minor-patch:')
        ->toContain('composer-major:');
});

it('carries the house cooldown on generated entries', function () {
    [, $out] = mergeFixture('composer-single', 'empty-updates.yml');

    expect($out)->toContain('cooldown:')->toContain('default-days: 7');
});

// --- byte-level splice behaviour --------------------------------------------

it('carries CRLF line endings through the splice byte for byte', function () {
    // The splice splits on \n alone, so the \r bytes of a CRLF file ride
    // along unchanged — the diff's context lines prove it.
    [$code, $out] = mergeFixture('composer-single', 'crlf.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"')
        ->toContain("directory: \"/somewhere/else\"\r\n")
        ->toContain('matches nothing we detected');
});

it('normalizes a missing trailing newline rather than duplicating it', function () {
    [$code, $out] = mergeFixture('composer-single', 'no-trailing-newline.yml');

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"')
        // Both diff inputs end in exactly one newline, so diff never marks one.
        ->not->toContain('No newline');
});

it('refuses duplicate mapping keys', function () {
    // The bash shim's backends silently took the last value. Both the Go
    // build and Symfony Yaml refuse, which is the fail-closed direction the
    // spec demands.
    $duplicate = sys_get_temp_dir().'/dup-'.bin2hex(random_bytes(6)).'.yml';
    file_put_contents($duplicate, "version: 2\nversion: 3\nupdates:\n");

    [$code, $out] = runTool([
        'acme/widgets',
        '--paths-from-file', fixturePath('trees', 'composer-single.paths'),
        '--existing-config', $duplicate,
        '--dry-run',
    ]);

    expect($code)->toBe(1);
    expect($out)->toContain('cannot parse')->not->toContain('+  - package-ecosystem');

    unlink($duplicate);
});
