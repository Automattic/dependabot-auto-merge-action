<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Source\ExecResult;
use Automattic\DependabotDirectories\Tests\Support\FakeExec;

/*
 * Ports of the write-path bats tests. The bash suite ran against gh and git
 * stubs on PATH; here a recording Execer plays both parts, which also makes
 * the central invariant checkable in-process: --dry-run issues no mutating
 * gh api call.
 */

const CONFIG_YML = 'repos/acme/widgets/contents/.github%2Fdependabot.yml';
const CONFIG_YAML = 'repos/acme/widgets/contents/.github%2Fdependabot.yaml';
const BRANCH_REF = 'bootstrap/dependabot-directories';
const RAW_HEADER = ' -H Accept: application/vnd.github.raw';
const PULLS_QUERY = 'gh api repos/acme/widgets/pulls?state=open&head=acme:'.BRANCH_REF;

/**
 * What the run proposes for plainRepo(), byte for byte.
 */
const PROPOSED_ROOT_COMPOSER = <<<'YAML'
    version: 2
    updates:
      - package-ecosystem: "composer"
        directory: "/"
        schedule:
          interval: "weekly"
          day: "monday"
        open-pull-requests-limit: 0
        cooldown:
          default-days: 7

    YAML;

/**
 * A repo whose tree holds one composer package at the root, and no config.
 */
function plainRepo(): FakeExec
{
    return new FakeExec([
        'gh auth status --hostname github.com' => new ExecResult('', 0),
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"acme/widgets","default_branch":"main"}', 0),
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('{"truncated":false,"tree":[
            {"type":"blob","path":"composer.json"},
            {"type":"blob","path":"composer.lock"}
        ]}', 0),
        'gh api repos/acme/widgets/git/ref/heads/main' => new ExecResult('{"object":{"sha":"basesha1"}}', 0),
    ]);
}

/**
 * plainRepo plus everything a successful first run needs to write.
 */
function writableRepo(): FakeExec
{
    $exec = plainRepo();
    $exec->responses['gh api -X POST repos/acme/widgets/git/refs --input -'] = new ExecResult('', 0);
    $exec->responses['gh api -X PUT '.CONFIG_YML.' --input -'] = new ExecResult('', 0);
    $exec->responses['gh api -X POST repos/acme/widgets/pulls --input -'] = new ExecResult('', 0);
    $exec->responses[PULLS_QUERY] = new ExecResult('[]', 0);

    return $exec;
}

/**
 * The YAML actually committed, decoded out of the Contents PUT payload.
 */
function writtenConfig(FakeExec $exec): string
{
    $payload = json_decode($exec->payloadFor('-X PUT '.CONFIG_YML), true);
    expect($payload)->toBeArray();

    return (string) base64_decode((string) $payload['content'], true);
}

// --- dry-run ----------------------------------------------------------------

it('prints the diff and issues no mutating call under dry-run', function () {
    $exec = plainRepo();

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(0);
    expect($out)->toContain('+  - package-ecosystem: "composer"')
        // Branch, file write, pull request — the calls a real run would make.
        ->toContain('3 would change');
    expect($exec->mutatingCalls())->toBe([]);
});

it('redacts the base64 payload but still names the call', function () {
    $exec = plainRepo();

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(0);
    expect($out)->toContain('gh api -X PUT repos/acme/widgets/contents')->toContain('base64,');
    expect($exec->mutatingCalls())->toBe([]);
});

it('issues no mutation under --detect-only', function () {
    $exec = plainRepo();

    [$code] = runTool(['acme/widgets', '--detect-only'], $exec);

    expect($code)->toBe(0);
    expect($exec->mutatingCalls())->toBe([]);
});

// --- the happy path ---------------------------------------------------------

it('creates the branch, writes the file and opens the pull request', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($exec->callCount('-X POST repos/acme/widgets/git/refs'))->toBe(1);
    expect($exec->callCount('-X PUT repos/acme/widgets/contents'))->toBe(1);
    expect($exec->callCount('-X POST repos/acme/widgets/pulls'))->toBe(1);
    expect($exec->mutatingCalls())->toHaveCount(3);
});

it('creates the branch from the default branch tip', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($exec->payloadFor('-X POST repos/acme/widgets/git/refs'))
        ->toContain('refs/heads/bootstrap/dependabot-directories')
        ->toContain('basesha1');
});

it('writes a file that decodes to the expected YAML', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect(writtenConfig($exec))->toBe(PROPOSED_ROOT_COMPOSER);
});

it('targets the proposal branch, never the default branch', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($exec->payloadFor('-X PUT '.CONFIG_YML))
        ->toContain('"branch": "bootstrap/dependabot-directories"')
        ->not->toContain('"branch": "main"');
});

it('lists what was mapped in the pull request body', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($exec->payloadFor('-X POST repos/acme/widgets/pulls'))
        ->toContain('composer')
        ->toContain('QAO-641')
        ->toContain('"base": "main"');
});

// --- idempotency ------------------------------------------------------------

it('writes nothing at all when the config already covers everything', function () {
    $exec = plainRepo();
    $exec->responses['gh api '.CONFIG_YML.'?ref=main'.RAW_HEADER] = new ExecResult(<<<'YAML'
        version: 2
        updates:
          - package-ecosystem: "composer"
            directory: "/"
            schedule:
              interval: "weekly"

        YAML, 0);

    [$code, $out] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($out)->toContain('already covers every detected directory');
    expect($exec->mutatingCalls())->toBe([]);
});

it('leaves a branch already proposing exactly this alone', function () {
    $exec = plainRepo();
    $exec->responses['gh api repos/acme/widgets/git/ref/heads/'.BRANCH_REF] = new ExecResult('{"object":{"sha":"branchsha"}}', 0);
    $exec->responses['gh api repos/acme/widgets/compare/main...'.BRANCH_REF] = new ExecResult('{"files":[{"filename":".github/dependabot.yml"}]}', 0);
    $exec->responses[PULLS_QUERY] = new ExecResult('[{"number":7}]', 0);
    $exec->responses['gh api '.CONFIG_YML.'?ref=bootstrap%2Fdependabot-directories'.RAW_HEADER] = new ExecResult(PROPOSED_ROOT_COMPOSER, 0);

    [$code, $out] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($out)->toContain('pull request #7')
        // A run that wrote nothing must say so. The "map x -> y" plan lines
        // used to increment this, so a repeat run reported changes it had
        // not made.
        ->toContain('0 changed');
    expect($exec->mutatingCalls())->toBe([]);
});

it('updates an open pull request in place rather than opening a second', function () {
    $exec = writableRepo();
    $exec->responses['gh api repos/acme/widgets/git/ref/heads/'.BRANCH_REF] = new ExecResult('{"object":{"sha":"branchsha"}}', 0);
    $exec->responses['gh api repos/acme/widgets/compare/main...'.BRANCH_REF] = new ExecResult('{"files":[{"filename":".github/dependabot.yml"}]}', 0);
    $exec->responses[PULLS_QUERY] = new ExecResult('[{"number":7}]', 0);
    $exec->responses['gh api -X PATCH repos/acme/widgets/pulls/7 --input -'] = new ExecResult('', 0);
    // The branch carries something different, so the file is rewritten.
    $exec->responses['gh api '.CONFIG_YML.'?ref=bootstrap%2Fdependabot-directories'.RAW_HEADER] = new ExecResult('version: 2', 0);

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    expect($exec->callCount('-X PATCH repos/acme/widgets/pulls/7'))->toBe(1);
    expect($exec->callCount('-X POST repos/acme/widgets/pulls '))->toBe(0);
    // An existing branch is reused, never recreated.
    expect($exec->callCount('-X POST repos/acme/widgets/git/refs'))->toBe(0);
});

it('updates an existing file by sha rather than recreating it blindly', function () {
    $exec = writableRepo();
    // Raw bytes and JSON metadata for the same path: the pipeline reads the
    // content one way and the blob sha the other.
    $exec->responses['gh api '.CONFIG_YML.'?ref=main'.RAW_HEADER] = new ExecResult(<<<'YAML'
        version: 2
        updates:
          - package-ecosystem: "composer"
            directory: "/elsewhere"
            schedule:
              interval: "weekly"

        YAML, 0);
    $exec->responses['gh api '.CONFIG_YML.'?ref=main'] = new ExecResult('{"sha":"filesha1"}', 0);

    [$code] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(0);
    // Omitting the sha on an existing file is how a Contents PUT 422s.
    expect($exec->payloadFor('-X PUT '.CONFIG_YML))->toContain('"sha": "filesha1"');
});

// --- refusals ---------------------------------------------------------------

it('refuses a branch carrying unrelated work before any write', function () {
    $exec = plainRepo();
    $exec->responses['gh api repos/acme/widgets/git/ref/heads/'.BRANCH_REF] = new ExecResult('{"object":{"sha":"branchsha"}}', 0);
    $exec->responses['gh api repos/acme/widgets/compare/main...'.BRANCH_REF] = new ExecResult(
        '{"files":[{"filename":".github/dependabot.yml"},{"filename":"src/app.php"}]}',
        0,
    );

    [$code, $out] = runTool(['acme/widgets'], $exec);

    expect($code)->toBe(1);
    expect($out)->toContain('unrelated work');
    expect($exec->mutatingCalls())->toBe([]);
});

it('never force-updates the branch ref', function () {
    // Reviewer commits on the branch must survive.
    $exec = writableRepo();
    $exec->responses['gh api repos/acme/widgets/git/ref/heads/'.BRANCH_REF] = new ExecResult('{"object":{"sha":"branchsha"}}', 0);
    $exec->responses['gh api repos/acme/widgets/compare/main...'.BRANCH_REF] = new ExecResult('{"files":[]}', 0);
    $exec->responses['gh api '.CONFIG_YML.'?ref=bootstrap%2Fdependabot-directories'.RAW_HEADER] = new ExecResult('version: 2', 0);

    runTool(['acme/widgets'], $exec);

    expect($exec->callCount('-X PATCH repos/acme/widgets/git/refs'))->toBe(0);
    expect($exec->callCount('force'))->toBe(0);
});

it('refuses a renamed repository before any mutation', function () {
    $exec = new FakeExec([
        'gh auth status --hostname github.com' => new ExecResult('', 0),
        'gh api repos/acme/old-name' => new ExecResult('{"full_name":"acme/widgets","default_branch":"main"}', 0),
    ]);

    [$code, $out] = runTool(['acme/old-name', '--dry-run'], $exec);

    expect($code)->toBe(2);
    expect($out)->toContain("resolved to 'acme/widgets'");
    expect($exec->mutatingCalls())->toBe([]);
});

it('refuses a .yaml config where Dependabot reads .yml', function () {
    $exec = plainRepo();
    $exec->responses['gh api '.CONFIG_YAML.'?ref=main'.RAW_HEADER] = new ExecResult('version: 2', 0);

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(1);
    expect($out)->toContain('.yaml exists but Dependabot reads');
    expect($exec->mutatingCalls())->toBe([]);
});

it('will not let the offline seams drive a real write', function () {
    // They describe a repository that may not be the real one.
    [$code, $out] = runTool([
        'acme/widgets',
        '--paths-from-file', fixturePath('trees', 'root-npm.paths'),
    ]);

    expect($code)->toBe(2);
    expect($out)->toContain('--dry-run');
});

it('fails the run on an unreadable tree rather than mapping nothing', function () {
    $exec = new FakeExec([
        'gh auth status --hostname github.com' => new ExecResult('', 0),
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"acme/widgets","default_branch":"main"}', 0),
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('HTTP 500 Internal Server Error', 1),
    ]);

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(1);
    expect($out)->toContain('cannot read the file tree');
    expect($exec->mutatingCalls())->toBe([]);
});

// --- truncated tree ---------------------------------------------------------

it('falls back to a blobless clone on a truncated tree', function () {
    $exec = new FakeExec([
        'gh auth status --hostname github.com' => new ExecResult('', 0),
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"acme/widgets","default_branch":"main"}', 0),
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('{"truncated":true,"tree":[]}', 0),
        'gh api repos/acme/widgets/git/ref/heads/main' => new ExecResult('{"object":{"sha":"basesha1"}}', 0),
    ]);
    $exec->clonePaths = "composer.json\ncomposer.lock\n";

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(0);
    expect($out)->toContain('falling back to a blobless clone')
        ->toContain('+  - package-ecosystem: "composer"');
});

it('stops rather than cloning whole when the server refuses the filter', function () {
    // A silent full clone would fetch exactly the repositories too large for
    // the tree API in the first place.
    $exec = new FakeExec([
        'gh auth status --hostname github.com' => new ExecResult('', 0),
        'gh api repos/acme/widgets' => new ExecResult('{"full_name":"acme/widgets","default_branch":"main"}', 0),
        'gh api repos/acme/widgets/git/trees/main?recursive=1' => new ExecResult('{"truncated":true,"tree":[]}', 0),
    ]);
    // No clonePaths: the clone refuses the filter, as a GHES without
    // uploadpack.allowFilter would.

    [$code, $out] = runTool(['acme/widgets', '--dry-run'], $exec);

    expect($code)->toBe(1);
    expect($out)->toContain('--allow-full-clone');
    expect($exec->mutatingCalls())->toBe([]);
});

// --- entry template ---------------------------------------------------------

it('carries --enable-version-updates through to the written file', function () {
    $exec = writableRepo();

    [$code] = runTool(['acme/widgets', '--enable-version-updates'], $exec);

    expect($code)->toBe(0);
    expect(writtenConfig($exec))
        ->toContain('open-pull-requests-limit: 10')
        ->toContain('composer-minor-patch:');
});
