<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Detection\Ecosystem;
use Automattic\DependabotDirectories\Report\Reporter;
use Automattic\DependabotDirectories\Source\ExecResult;
use Automattic\DependabotDirectories\Tests\Support\FakeExec;
use Automattic\DependabotDirectories\Write\Json;
use Automattic\DependabotDirectories\Write\Lander;
use Automattic\DependabotDirectories\Write\PullRequestBody;

/**
 * Run $body against a Lander wired to $exec, returning its output.
 *
 * @param callable(Lander, Reporter): void $body
 */
function withLander(FakeExec $exec, bool $dryRun, callable $body): string
{
    $stream = fopen('php://memory', 'r+b');
    if (false === $stream) {
        throw new RuntimeException('cannot open an in-memory stream');
    }

    $reporter = new Reporter($stream, $stream);
    $lander = new Lander('acme/widgets', 'main', 'main', $exec, $reporter, $dryRun);

    $body($lander, $reporter);

    rewind($stream);
    $output = (string) stream_get_contents($stream);
    fclose($stream);

    return $output;
}

// --- the mutation funnel ----------------------------------------------------

it('prints the call under dry-run and executes nothing', function () {
    // Read-only calls still run under dry-run, so the output matches what a
    // real run would decide.
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/ref/heads/main' => new ExecResult('{"object":{"sha":"basesha1"}}', 0),
    ]);

    $out = withLander($exec, true, function (Lander $lander) {
        $lander->ensureBranch();
    });

    expect($out)->toContain("→  branch 'bootstrap/dependabot-directories': create (dry-run)\n")
        ->toContain("     gh api -X POST repos/acme/widgets/git/refs\n");
    expect($exec->mutatingCalls())->toBe([]);
});

it('prefers the preview over a payload that would bury the summary', function () {
    // A Contents PUT carries kilobytes of base64.
    $exec = new FakeExec();

    $out = withLander($exec, true, function (Lander $lander) {
        $lander->writeConfig("version: 2\nupdates:\n", false);
    });

    expect($out)->toContain('<base64, 20 bytes of YAML>')
        ->not->toContain(base64_encode("version: 2\nupdates:\n"));
    expect($exec->mutatingCalls())->toBe([]);
});

it('executes the call and reports it as changed', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/ref/heads/main' => new ExecResult('{"object":{"sha":"basesha1"}}', 0),
        'gh api -X POST repos/acme/widgets/git/refs --input -' => new ExecResult('', 0),
    ]);

    $out = withLander($exec, false, function (Lander $lander) {
        $lander->ensureBranch();
    });

    expect($out)->toContain("+  branch 'bootstrap/dependabot-directories': create\n");
    expect($exec->payloadFor('-X POST repos/acme/widgets/git/refs'))
        ->toContain('refs/heads/bootstrap/dependabot-directories')
        ->toContain('basesha1');
});

it('truncates the error body when a mutation fails', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/ref/heads/main' => new ExecResult('{"object":{"sha":"s"}}', 0),
        'gh api -X POST repos/acme/widgets/git/refs --input -' => new ExecResult(str_repeat('e', 900), 1),
    ]);

    $failures = 0;
    $out = withLander($exec, false, function (Lander $lander, Reporter $reporter) use (&$failures) {
        expect($lander->ensureBranch())->toBeFalse();
        $failures = $reporter->failCount;
    });

    expect($failures)->toBe(1);
    expect(strlen($out))->toBeLessThan(400);
});

// --- payload rendering ------------------------------------------------------

it('keeps field order and the two-space spacing jq produced', function () {
    expect(Json::object(['ref' => 'refs/heads/b', 'sha' => 'abc']))
        ->toBe("{\n  \"ref\": \"refs/heads/b\",\n  \"sha\": \"abc\"\n}");
});

it('leaves slashes and non-ASCII unescaped', function () {
    // The pull request body carries markdown links and em dashes. Escaping
    // either would change the bytes sent.
    expect(Json::object(['body' => 'see https://example.com/a — really']))
        ->toBe("{\n  \"body\": \"see https://example.com/a — really\"\n}");
});

it('caps the pull request body at twenty-five entries', function () {
    $missing = [];
    for ($i = 0; $i < 30; ++$i) {
        $missing[] = new Block(Ecosystem::Composer, sprintf('/p%02d', $i));
    }

    $body = PullRequestBody::render($missing);

    expect($body)->toContain("- ... and 5 more\n")
        ->not->toContain('/p26');
    expect($body)->toContain('QAO-641');
});

it('marks a glob in the pull request body', function () {
    $body = PullRequestBody::render([new Block(Ecosystem::Composer, '/plugins/*', true)]);

    expect($body)->toContain("- `composer` -> `/plugins/*` (glob)\n");
});

// --- branch safety ----------------------------------------------------------

it('refuses a branch carrying unrelated work, before any write', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/git/ref/heads/bootstrap/dependabot-directories' => new ExecResult('{"object":{"sha":"b"}}', 0),
        'gh api repos/acme/widgets/compare/main...bootstrap/dependabot-directories' => new ExecResult(
            '{"files":[{"filename":".github/dependabot.yml"},{"filename":"src/app.php"}]}',
            0,
        ),
    ]);

    $out = withLander($exec, false, function (Lander $lander) {
        expect($lander->ensureBranch())->toBeFalse();
    });

    expect($out)->toContain('unrelated work');
    expect($exec->mutatingCalls())->toBe([]);
});

it('carries the replaced blob sha on the write', function () {
    // Omitting the sha on an existing file is how a Contents PUT 422s.
    $exec = new FakeExec([
        'gh api repos/acme/widgets/contents/.github%2Fdependabot.yml?ref=main' => new ExecResult('{"sha":"filesha1"}', 0),
        'gh api -X PUT repos/acme/widgets/contents/.github%2Fdependabot.yml --input -' => new ExecResult('', 0),
    ]);

    withLander($exec, false, function (Lander $lander) {
        expect($lander->writeConfig("version: 2\n", true))->toBeTrue();
    });

    expect($exec->payloadFor('-X PUT'))
        ->toContain('"sha": "filesha1"')
        ->toContain('"branch": "bootstrap/dependabot-directories"');
});

it('refreshes an open pull request in place', function () {
    $exec = new FakeExec([
        'gh api repos/acme/widgets/pulls?state=open&head=acme:bootstrap/dependabot-directories' => new ExecResult('[{"number":7}]', 0),
        'gh api -X PATCH repos/acme/widgets/pulls/7 --input -' => new ExecResult('', 0),
    ]);

    $out = withLander($exec, false, function (Lander $lander) {
        expect($lander->ensurePullRequest([]))->toBeTrue();
    });

    expect($out)->toContain('pull request #7: refresh the description');
});
