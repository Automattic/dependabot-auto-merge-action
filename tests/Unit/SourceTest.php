<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\TruncatedTreeException;
use Automattic\DependabotDirectories\Source\ExecResult;
use Automattic\DependabotDirectories\Source\FixtureConfig;
use Automattic\DependabotDirectories\Source\FixtureTree;
use Automattic\DependabotDirectories\Source\GhRepository;
use Automattic\DependabotDirectories\Source\Uri;
use Automattic\DependabotDirectories\Tests\Support\FakeExec;

function tempDir(): string
{
    $dir = sys_get_temp_dir().'/dd-test-'.bin2hex(random_bytes(8));
    mkdir($dir, 0o700, true);

    return $dir;
}

// --- fixture sources --------------------------------------------------------

it('cleans and sorts a hand-written path list', function () {
    $dir = tempDir();
    $file = $dir.'/tree.paths';
    file_put_contents($file, "./b/file\n/a/file\n\n   \nc/file\nc/file\n");

    expect((new FixtureTree($file))->listPaths())->toBe(['a/file', 'b/file', 'c/file']);
});

it('derives the blob directory the way the shell parameter expansion did', function (string $in, string $want) {
    // The rule was ${f%.*}.blobs: the LAST dot anywhere counts, and a dotless
    // path gains the suffix whole.
    expect((new FixtureTree($in))->blobDir())->toBe($want);
})->with([
    ['trees/pnpm.paths', 'trees/pnpm.blobs'],
    ['noext', 'noext.blobs'],
    ['a.b/file', 'a.blobs'],
]);

it('reads a blob from the sibling blobs directory, and nothing from a missing one', function () {
    $dir = tempDir();
    $pathsFile = $dir.'/tree.paths';
    file_put_contents($pathsFile, "pkg/package.json\n");
    mkdir($dir.'/tree.blobs/pkg', 0o700, true);
    file_put_contents($dir.'/tree.blobs/pkg/package.json', '{}');

    $tree = new FixtureTree($pathsFile);

    expect($tree->readBlob('pkg/package.json'))->toBe('{}');
    expect($tree->readBlob('missing.json'))->toBeNull();
});

it('treats a missing config file as an absence, not an error', function () {
    $dir = tempDir();
    $path = $dir.'/dependabot.yml';

    expect((new FixtureConfig($path))->readConfig())->toBeNull();

    file_put_contents($path, "version: 2\n");
    expect((new FixtureConfig($path))->readConfig())->toBe("version: 2\n");
});

// --- gh ---------------------------------------------------------------------

it('distinguishes a missing gh from an unauthenticated one', function () {
    // 127 is the shell's "command not found", which is how a launch failure
    // surfaces.
    $exec = new FakeExec(['gh auth status --hostname github.com' => new ExecResult('', 127)]);
    expect(fn () => (new GhRepository('acme/widgets', $exec))->check())
        ->toThrow(FatalException::class, 'gh not found');

    $exec = new FakeExec(['gh auth status --hostname github.com' => new ExecResult('', 1)]);
    expect(fn () => (new GhRepository('acme/widgets', $exec))->check())
        ->toThrow(FatalException::class, 'not authenticated to github.com');
});

it('pins the default branch, comparing the name case-insensitively', function () {
    // GitHub canonicalizes case without a redirect.
    $exec = new FakeExec([
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"Acme/Widgets","default_branch":"trunk"}', 0),
    ]);

    $gh = new GhRepository('acme/widgets', $exec);
    $gh->resolve();

    expect($gh->defaultBranch())->toBe('trunk');
});

it('refuses a renamed or transferred repository rather than following it', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"acme/renamed","default_branch":"main"}', 0),
    ]);

    expect(fn () => (new GhRepository('acme/widgets', $exec))->resolve())
        ->toThrow(FatalException::class, 'renamed or transferred');
});

it('truncates a long API error body', function () {
    // API errors can be whole HTML pages.
    $exec = new FakeExec([
        'gh api repos/acme/widgets' => new ExecResult(str_repeat('x', 900), 1),
    ]);

    try {
        (new GhRepository('acme/widgets', $exec))->resolve();
        expect(false)->toBeTrue('resolve must throw');
    } catch (FatalException $e) {
        expect(strlen($e->getMessage()))->toBeLessThan(350);
    }
});

it('keeps only blobs from a tree listing, sorted', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('{
            "truncated": false,
            "tree": [
                {"type": "tree", "path": "src"},
                {"type": "blob", "path": "src/b.js"},
                {"type": "blob", "path": "package.json"}
            ]
        }', 0),
    ]);

    expect(resolvedGh($exec)->listPaths())->toBe(['package.json', 'src/b.js']);
});

it('refuses a truncated tree rather than proceeding on a partial list', function () {
    // A silently incomplete file list is precisely the failure mode this tool
    // exists to prevent.
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('{"truncated": true, "tree": []}', 0),
    ]);

    expect(fn () => resolvedGh($exec)->listPaths())
        ->toThrow(TruncatedTreeException::class, 'truncated its response for acme/widgets');
});

it('reports an unparseable tree', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('<!DOCTYPE html>', 0),
    ]);

    expect(fn () => resolvedGh($exec)->listPaths())
        ->toThrow(RuntimeException::class, 'cannot parse the file tree');
});

it('escapes a blob path the way jq @uri did', function () {
    $key = 'gh api repos/acme/widgets/contents/bad%7Cpipe%2Fpackage.json?ref=main -H Accept: application/vnd.github.raw';
    $exec = new FakeExec([$key => new ExecResult('{}', 0)]);

    expect(resolvedGh($exec)->readBlob('bad|pipe/package.json'))->toBe('{}');
});

it('prefers .yml and treats a lone .yaml as a trap', function () {
    // Dependabot reads .yml only, so appending to a fresh .yml would leave two
    // files and the repository obeying neither.
    $yml = 'gh api repos/acme/widgets/contents/.github%2Fdependabot.yml?ref=main -H Accept: application/vnd.github.raw';
    $yaml = 'gh api repos/acme/widgets/contents/.github%2Fdependabot.yaml?ref=main -H Accept: application/vnd.github.raw';

    $present = new FakeExec([$yml => new ExecResult("version: 2\n", 0)]);
    expect(resolvedGh($present)->readConfig())->toBe("version: 2\n");

    $trap = new FakeExec([
        $yml => new ExecResult('', 1),
        $yaml => new ExecResult("version: 2\n", 0),
    ]);
    expect(fn () => resolvedGh($trap)->readConfig())
        ->toThrow(RuntimeException::class, 'rename it first');

    $absent = new FakeExec([
        $yml => new ExecResult('', 1),
        $yaml => new ExecResult('', 1),
    ]);
    expect(resolvedGh($absent)->readConfig())->toBeNull();
});

it('percent-encodes exactly the bytes outside the unreserved set', function (string $in, string $want) {
    expect(Uri::escape($in))->toBe($want);
})->with([
    ['main', 'main'],
    ['a/b', 'a%2Fb'],
    ['café', 'caf%C3%A9'],
    ['a b', 'a%20b'],
    ['p+kg', 'p%2Bkg'],
    ['bad|pipe', 'bad%7Cpipe'],
    ['A-Z_0.9~', 'A-Z_0.9~'],
    ['release/v1.2', 'release%2Fv1.2'],
]);

/**
 * A repository already resolved against a "main" default branch.
 */
function resolvedGh(FakeExec $exec): GhRepository
{
    $exec->responses['gh api repos/acme/widgets'] ??= new ExecResult(
        '{"full_name":"acme/widgets","default_branch":"main"}',
        0,
    );

    $gh = new GhRepository('acme/widgets', $exec);
    $gh->resolve();

    return $gh;
}
