<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Config\ProposalBuilder;

it('finds the last line of the updates block', function (string $raw, int $want) {
    expect(ProposalBuilder::insertionLine(explode("\n", $raw)))->toBe($want);
})->with([
    'empty updates block' => ["version: 2\nupdates:\n", 2],
    'entries to the end of file' => ["version: 2\nupdates:\n  - a: 1\n    b: 2\n", 4],
    // The blank line separates updates from the next key; appending must land
    // before it.
    'following top-level key' => ["version: 2\nupdates:\n  - a: 1\n\nregistries:\n  x: 1\n", 3],
    'blank lines inside the block do not end it' => ["version: 2\nupdates:\n  - a: 1\n\n  - b: 2\nnext:\n", 5],
    'comments inside the block advance it' => ["version: 2\nupdates:\n  # todo\nregistries:\n", 3],
    'comment after the updates key' => ["version: 2\nupdates: # none yet\n", 2],
]);

it('proposes a whole file when none exists', function () {
    $proposal = null;
    [, $out] = captureReport(function ($reporter) use (&$proposal) {
        $proposal = ProposalBuilder::build('', false, [], '  ', '    ', false, $reporter);
    });

    expect($proposal->current)->toBeNull();
    expect($proposal->proposed)->toBe("version: 2\nupdates:\n");
    expect($out)->toBe('');
});

it('normalizes trailing newlines to exactly one without touching CR bytes', function () {
    // The splice must leave a CRLF file byte-identical outside the appended
    // region, so only the trailing run of newlines collapses.
    $proposal = null;
    captureReport(function ($reporter) use (&$proposal) {
        $proposal = ProposalBuilder::build("version: 2\r\nupdates:\r\n\n\n", true, [], '  ', '    ', false, $reporter);
    });

    expect($proposal->current)->toBe("version: 2\r\nupdates:\r\n");
});
