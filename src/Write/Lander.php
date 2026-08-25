<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Write;

use Automattic\DependabotDirectories\Config\ConfigFile;
use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Report\Reporter;
use Automattic\DependabotDirectories\Source\Execer;
use Automattic\DependabotDirectories\Source\Uri;

/**
 * Turns the computed proposal into a branch, a commit and a pull request.
 *
 * The default branch is never written to directly, and every write flows
 * through one funnel, so "--dry-run issues no writes" is a provable property
 * rather than a hope: a recording Execer counts zero mutating calls.
 */
final class Lander
{
    /**
     * Where the mapping is proposed. Fixed rather than configurable:
     * idempotency depends on finding the same branch again.
     */
    public const BRANCH = 'bootstrap/dependabot-directories';

    public const COMMIT_MESSAGE = 'Map Dependabot to the directories holding lockfiles';

    /**
     * Set by {@see self::ensureBranch} and steers the file write.
     */
    public bool $branchExists = false;

    public function __construct(
        private readonly string $repository,
        private readonly string $defaultBranch,
        private readonly string $encodedBranch,
        private readonly Execer $exec,
        private readonly Reporter $reporter,
        private readonly bool $dryRun,
    ) {
    }

    /**
     * The ONLY place that reads the dry-run flag, and the only place issuing
     * a mutating gh api call. Steps must never call `gh api -X` directly.
     *
     * Every write is a `gh api` call for the same reason: `gh pr create`
     * would be a second, uncounted channel.
     *
     * $preview, when non-empty, replaces the payload in dry-run output. A
     * Contents PUT carries kilobytes of base64, and printing it buries the
     * very summary dry-run exists to show.
     */
    private function mutate(string $description, string $method, string $path, string $payload = '', string $preview = ''): bool
    {
        if ($this->dryRun) {
            $this->reporter->would($description.' (dry-run)');
            $this->reporter->line(sprintf('     gh api -X %s %s', $method, $path));

            if ('' !== $preview) {
                $this->printIndented($preview);
            } elseif ('' !== $payload) {
                // The formatter is cosmetic — its failure must not hide the
                // payload, which is the whole point of dry-run — so fall back
                // to the raw JSON.
                if (is_array(json_decode($payload, true))) {
                    $this->printIndented($payload);
                } else {
                    $this->reporter->line('     '.$payload);
                }
            }

            return true;
        }

        $argv = ['gh', 'api', '-X', $method, $path];
        if ('' !== $payload) {
            $argv[] = '--input';
            $argv[] = '-';
        }

        $result = $this->exec->runInput($argv, $payload);
        if (!$result->succeeded()) {
            $this->reporter->fail(sprintf('%s: %s', $description, $result->truncatedOutput()));

            return false;
        }

        $this->reporter->changed($description);

        return true;
    }

    /**
     * Find or create the proposal branch.
     *
     * An existing branch is reused, never force-updated: someone may have
     * pushed review commits onto it, and a forced ref would destroy them. The
     * scope check is what makes reuse safe.
     */
    public function ensureBranch(): bool
    {
        if ($this->exec->output(['gh', 'api', 'repos/'.$this->repository.'/git/ref/heads/'.self::BRANCH])->succeeded()) {
            $this->branchExists = true;

            return $this->branchSafeToReuse();
        }
        $this->branchExists = false;

        $sha = $this->refSha($this->encodedBranch);
        if (null === $sha) {
            $this->reporter->fail(sprintf("cannot read the tip of '%s'", $this->defaultBranch));

            return false;
        }

        return $this->mutate(
            sprintf("branch '%s': create", self::BRANCH),
            'POST',
            'repos/'.$this->repository.'/git/refs',
            Json::object(['ref' => 'refs/heads/'.self::BRANCH, 'sha' => $sha]),
        );
    }

    /**
     * Refuse a branch carrying work that is not ours.
     */
    private function branchSafeToReuse(): bool
    {
        $result = $this->exec->combined([
            'gh', 'api',
            'repos/'.$this->repository.'/compare/'.$this->encodedBranch.'...'.self::BRANCH,
        ]);

        $comparison = $result->succeeded() ? json_decode($result->output, true) : null;
        if (!is_array($comparison)) {
            $this->reporter->fail(sprintf(
                "cannot compare '%s' against '%s': %s",
                self::BRANCH,
                $this->defaultBranch,
                $result->truncatedOutput(),
            ));

            return false;
        }

        $files = $comparison['files'] ?? [];
        if (is_array($files)) {
            foreach ($files as $file) {
                $filename = is_array($file) ? ($file['filename'] ?? null) : null;
                if (is_string($filename) && ConfigFile::PATH !== $filename) {
                    $this->reporter->fail(sprintf(
                        "branch '%s' also changes %s — refusing to touch a branch carrying unrelated work",
                        self::BRANCH,
                        $filename,
                    ));

                    return false;
                }
            }
        }

        return true;
    }

    /**
     * PUT the proposed file onto the branch.
     *
     * The blob sha of whatever it replaces has to ride along — omitting the
     * sha on an existing file is how a Contents PUT 422s.
     */
    public function writeConfig(string $proposed, bool $existingPresent): bool
    {
        $sha = null;
        if ($this->branchExists) {
            $sha = $this->configShaOn(Uri::escape(self::BRANCH));
        }
        if (null === $sha && $existingPresent && !$this->branchExists) {
            $sha = $this->configShaOn($this->encodedBranch);
        }

        $fields = [
            'message' => self::COMMIT_MESSAGE,
            'content' => base64_encode($proposed),
            'branch' => self::BRANCH,
        ];
        if (null !== $sha) {
            $fields['sha'] = $sha;
        }

        $preview = sprintf(
            "{\n  \"message\": \"%s\",\n  \"content\": \"<base64, %d bytes of YAML>\",\n  \"branch\": \"%s\"\n}",
            self::COMMIT_MESSAGE,
            strlen($proposed),
            self::BRANCH,
        );

        return $this->mutate(
            sprintf("%s: write on '%s'", ConfigFile::PATH, self::BRANCH),
            'PUT',
            'repos/'.$this->repository.'/contents/'.Uri::escape(ConfigFile::PATH),
            Json::object($fields),
            $preview,
        );
    }

    /**
     * Open the pull request, or refresh the description of the one already
     * open for the branch.
     *
     * @param list<Block> $missing
     */
    public function ensurePullRequest(array $missing): bool
    {
        $body = PullRequestBody::render($missing);

        $number = $this->openPullRequestNumber();
        if (null !== $number) {
            return $this->mutate(
                sprintf('pull request #%d: refresh the description', $number),
                'PATCH',
                sprintf('repos/%s/pulls/%d', $this->repository, $number),
                Json::object(['body' => $body]),
            );
        }

        return $this->mutate(
            sprintf("pull request: open against '%s'", $this->defaultBranch),
            'POST',
            'repos/'.$this->repository.'/pulls',
            Json::object([
                'title' => self::COMMIT_MESSAGE,
                'head' => self::BRANCH,
                'base' => $this->defaultBranch,
                'body' => $body,
            ]),
        );
    }

    /**
     * The open pull request for the proposal branch, if there is one.
     */
    public function openPullRequestNumber(): ?int
    {
        $owner = strstr($this->repository, '/', true);
        if (false === $owner) {
            return null;
        }

        $result = $this->exec->output(['gh', 'api', sprintf(
            'repos/%s/pulls?state=open&head=%s:%s',
            $this->repository,
            $owner,
            self::BRANCH,
        )]);
        if (!$result->succeeded()) {
            return null;
        }

        $pulls = json_decode($result->output, true);
        if (!is_array($pulls) || [] === $pulls) {
            return null;
        }

        $first = $pulls[0] ?? null;
        $number = is_array($first) ? ($first['number'] ?? null) : null;

        return is_int($number) ? $number : null;
    }

    /**
     * The config's raw bytes on a ref, null when it does not exist there.
     */
    public function configBodyOn(string $encodedRef): ?string
    {
        $result = $this->exec->output(['gh', 'api',
            'repos/'.$this->repository.'/contents/'.Uri::escape(ConfigFile::PATH).'?ref='.$encodedRef,
            '-H', 'Accept: application/vnd.github.raw',
        ]);

        return $result->succeeded() ? $result->output : null;
    }

    /**
     * The config's blob sha on a ref, null when it does not exist there.
     */
    public function configShaOn(string $encodedRef): ?string
    {
        $result = $this->exec->output(['gh', 'api',
            'repos/'.$this->repository.'/contents/'.Uri::escape(ConfigFile::PATH).'?ref='.$encodedRef,
        ]);
        if (!$result->succeeded()) {
            return null;
        }

        $meta = json_decode($result->output, true);
        $sha = is_array($meta) ? ($meta['sha'] ?? null) : null;

        return is_string($sha) ? $sha : null;
    }

    private function refSha(string $encodedRef): ?string
    {
        $result = $this->exec->combined(['gh', 'api', 'repos/'.$this->repository.'/git/ref/heads/'.$encodedRef]);
        if (!$result->succeeded()) {
            return null;
        }

        $decoded = json_decode($result->output, true);
        $object = is_array($decoded) ? ($decoded['object'] ?? null) : null;
        $sha = is_array($object) ? ($object['sha'] ?? null) : null;

        return is_string($sha) ? $sha : null;
    }

    private function printIndented(string $text): void
    {
        foreach (explode("\n", rtrim($text, "\n")) as $line) {
            $this->reporter->line('     '.$line);
        }
    }
}
