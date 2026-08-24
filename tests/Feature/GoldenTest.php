<?php

declare(strict_types=1);

/*
 * Byte-level parity with the original bash script.
 *
 * The transcripts under tests/Fixtures/golden/ were captured from
 * scripts/dependabot-directories.sh before its deletion — see manifest.tsv
 * beside them for each exact invocation. An implementation that reproduces
 * them against the same fixtures is, for report purposes, that script. The
 * line-by-line assertions elsewhere in this suite cannot see ordering or
 * spacing. These can.
 *
 * They also survived a rewrite to Go and a rewrite from it, which is the
 * point: the transcripts are the contract, not any one implementation.
 *
 * Deliberately absent: weird-paths, whose '|' handling changed when the
 * record format was retired, and anything printing usage, which belongs to
 * the implementation.
 */

/**
 * @return list<array{string, int, list<string>}>
 */
function goldenCases(): array
{
    $manifest = file(fixturePath('golden', 'manifest.tsv'), FILE_IGNORE_NEW_LINES);
    if (false === $manifest) {
        throw new RuntimeException('cannot read the golden manifest');
    }

    $cases = [];
    foreach ($manifest as $line) {
        if ('' === $line || str_starts_with($line, '#')) {
            continue;
        }
        [$file, $exit, $args] = explode("\t", $line, 3);

        // The manifest records paths relative to the repository root.
        $argv = array_map(
            static fn (string $arg): string => str_starts_with($arg, 'tests/Fixtures/')
                ? projectRoot().'/'.$arg
                : $arg,
            explode(' ', $args),
        );

        $cases[] = [$file, (int) $exit, $argv];
    }

    return $cases;
}

it('reproduces the transcript byte for byte', function (string $golden, int $exit, array $argv) {
    $want = file_get_contents(fixturePath('golden', $golden));

    [$code, $output] = runTool(array_merge(['acme/widgets'], $argv));

    expect($output)->toBe($want, firstDivergence((string) $want, $output));
    expect($code)->toBe($exit);
})->with(array_map(
    static fn (array $case): array => [$case[0], $case[1], $case[2]],
    goldenCases(),
));

/**
 * Render the first differing line with context, which reads far better than
 * two full transcripts side by side.
 */
function firstDivergence(string $want, string $got): string
{
    $wantLines = explode("\n", $want);
    $gotLines = explode("\n", $got);

    $count = max(count($wantLines), count($gotLines));
    for ($i = 0; $i < $count; ++$i) {
        $w = $wantLines[$i] ?? '<missing>';
        $g = $gotLines[$i] ?? '<missing>';
        if ($w !== $g) {
            return sprintf("line %d:\n  transcript: %s\n  php:        %s", $i + 1, var_export($w, true), var_export($g, true));
        }
    }

    return 'outputs differ only in trailing bytes';
}
