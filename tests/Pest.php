<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Console\Application;
use Automattic\DependabotDirectories\Report\Reporter;
use Automattic\DependabotDirectories\Source\Execer;

/*
 * The end-to-end suite drives the real CLI the way the bats suite drove the
 * bash script: through --paths-from-file and --existing-config, asserting on
 * the combined output. One stream receives both stdout and stderr because
 * bats' $output merged them, and keeping that shape lets the ported
 * assertions stay line-for-line comparable with the originals.
 */

/**
 * The repository root, so fixtures resolve wherever the runner was started.
 */
function projectRoot(): string
{
    return dirname(__DIR__);
}

function fixturePath(string ...$parts): string
{
    return projectRoot().'/tests/Fixtures/'.implode('/', $parts);
}

/**
 * Run the tool as a subprocess would see it.
 *
 * @param list<string> $args
 *
 * @return array{int, string} the exit code and the merged output
 */
function runTool(array $args, ?Execer $exec = null): array
{
    $stream = fopen('php://memory', 'r+b');
    if (false === $stream) {
        throw new RuntimeException('cannot open an in-memory stream');
    }

    $code = Application::execute($args, $stream, $stream, $exec);

    rewind($stream);
    $output = (string) stream_get_contents($stream);
    fclose($stream);

    return [$code, $output];
}

/**
 * Run the tool over a tree fixture in --detect-only mode.
 *
 * @param list<string> $extra
 *
 * @return array{int, string}
 */
function detectFixture(string $fixture, array $extra = []): array
{
    return runTool(array_merge(
        ['acme/widgets', '--paths-from-file', fixturePath('trees', $fixture.'.paths'), '--detect-only'],
        $extra,
    ));
}

/**
 * Detect a tree and merge against an existing config, in --dry-run mode.
 *
 * @param list<string> $extra
 *
 * @return array{int, string}
 */
function mergeFixture(string $tree, string $config, array $extra = []): array
{
    return runTool(array_merge([
        'acme/widgets',
        '--paths-from-file', fixturePath('trees', $tree.'.paths'),
        '--existing-config', fixturePath('dependabot', $config),
        '--dry-run',
    ], $extra));
}

/**
 * Capture what a Reporter writes.
 *
 * @param callable(Reporter): void $body
 *
 * @return array{Reporter, string, string} the reporter, stdout and stderr
 */
function captureReport(callable $body): array
{
    $out = fopen('php://memory', 'r+b');
    $err = fopen('php://memory', 'r+b');
    if (false === $out || false === $err) {
        throw new RuntimeException('cannot open an in-memory stream');
    }

    $reporter = new Reporter($out, $err);
    $body($reporter);

    rewind($out);
    rewind($err);
    $result = [$reporter, (string) stream_get_contents($out), (string) stream_get_contents($err)];
    fclose($out);
    fclose($err);

    return $result;
}

/**
 * Extract the "Detected mappings:" block, one "<eco>: <dir>" per line,
 * exactly as the original sed/grep pipeline did.
 *
 * @return list<string>
 */
function mappings(string $output): array
{
    $found = [];
    $inBlock = false;

    foreach (explode("\n", $output) as $line) {
        if ('Detected mappings:' === $line) {
            $inBlock = true;
            continue;
        }
        if ($inBlock && '' === $line) {
            return $found;
        }
        if ($inBlock && str_starts_with($line, '   ')) {
            $found[] = substr($line, 3);
        }
    }

    return $found;
}

expect()->extend('toListMapping', function (string $want) {
    expect(mappings($this->value))->toContain($want);

    return $this;
});

expect()->extend('toNotListMapping', function (string $fragment) {
    foreach (mappings($this->value) as $mapping) {
        expect($mapping)->not->toContain($fragment);
    }

    return $this;
});

expect()->extend('toListMappingCount', function (int $want) {
    expect(mappings($this->value))->toHaveCount($want);

    return $this;
});

/*
 * A note-group example line carries a five-space indent, which is what
 * distinguishes "reported as a finding" from "emitted as a mapping".
 */
expect()->extend('toNoteExample', function (string $item) {
    expect($this->value)->toContain("\n     ".$item."\n");

    return $this;
});

expect()->extend('toNotNoteExample', function (string $item) {
    expect($this->value)->not->toContain("\n     ".$item."\n");

    return $this;
});
