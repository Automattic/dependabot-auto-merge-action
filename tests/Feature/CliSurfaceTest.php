<?php

declare(strict_types=1);

/*
 * The command line surface.
 *
 * These assert Symfony Console's own message wording, which is the only part
 * of the output no transcript pins — everything the tool *reports* is fixed
 * byte for byte by the golden transcripts instead, see GoldenTest. Swapping
 * the CLI library would rewrite these bytes and leave the report untouched,
 * which is the right way round.
 *
 * What they actually guard is the contract underneath the wording: exit 2 for
 * usage and environment errors, which problem is reported first, and that
 * usage text accompanies a usage error but never an environment one.
 */

it('exits 2 with usage when given no arguments', function () {
    [$code, $out] = runTool([]);

    expect($code)->toBe(2);
    expect($out)->toContain('missing required argument')->toContain('Usage:');
});

it('rejects a repository without a slash', function () {
    [$code, $out] = runTool(['widgets', '--detect-only']);

    expect($code)->toBe(2);
    expect($out)->toContain('invalid repository');
});

it('rejects literal gh api placeholders', function () {
    // gh expands {owner} and {repo} from GH_REPO or the current checkout, so
    // a non-literal name could address a different repository than the one on
    // the command line.
    [$code, $out] = runTool(['{owner}/{repo}', '--detect-only']);

    expect($code)->toBe(2);
    expect($out)->toContain('invalid repository');
});

it('exits 2 on an unknown option', function () {
    [$code, $out] = runTool(['acme/widgets', '--frobnicate']);

    expect($code)->toBe(2);
    expect($out)->toContain('frobnicate');
});

it('does not let --include swallow a following option', function (array $args, string $expected) {
    // Symfony refuses at parse time, which is what the bash script did. The
    // post-parse guard still earns its place: the `=` form hands the value
    // over directly, past that check.
    [$code, $out] = runTool(array_merge(['acme/widgets'], $args));

    expect($code)->toBe(2);
    expect($out)->toContain($expected);
})->with([
    'separate token' => [['--include', '--dry-run'], 'The "--include" option requires a value.'],
    'equals form, option as value' => [['--include=--dry-run', '--detect-only'], "--include needs a value, got option '--dry-run'"],
    'equals form, empty value' => [['--include=', '--detect-only'], '--include needs a value'],
]);

it('refuses a plain run while the write path is unimplemented', function () {
    [$code, $out] = runTool([
        'acme/widgets',
        '--paths-from-file', fixturePath('trees', 'root-npm.paths'),
    ]);

    expect($code)->toBe(2);
    expect($out)->toContain('--dry-run');
});

it('exits 2 when --paths-from-file names a missing file', function () {
    [$code, $out] = runTool([
        'acme/widgets',
        '--paths-from-file', '/nonexistent/nope.paths',
        '--detect-only',
    ]);

    expect($code)->toBe(2);
    expect($out)->toContain('no such file');
});

it('prints usage for a usage error but not for an environment one', function () {
    // die_usage versus die. A wrong command line earns the usage text; a
    // correct command line meeting a wrong environment does not, because the
    // usage text would be misleading.
    [, $usage] = runTool(['acme/widgets', '--include', '--dry-run']);
    [, $environment] = runTool([
        'acme/widgets',
        '--paths-from-file', '/nonexistent/nope.paths',
        '--detect-only',
    ]);

    expect($usage)->toContain('Usage:');
    expect($environment)->not->toContain('Usage:');
});

it('shows help on --help and exits 0', function () {
    [$code, $out] = runTool(['--help']);

    expect($code)->toBe(0);
    expect($out)->toContain('Usage:')
        ->toContain('--paths-from-file')
        // The global options Symfony adds by default are trimmed away: this
        // tool writes a report to a stream, so verbosity flags would advertise
        // behaviour that does not exist.
        ->not->toContain('--quiet')
        ->not->toContain('--no-interaction');
});
