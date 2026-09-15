<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

use Automattic\DependabotDirectories\Config\ConfigFile;
use Automattic\DependabotDirectories\Detection\Paths;
use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\TruncatedTreeException;

/**
 * Reads the repository through the gh CLI, which owns the whole
 * authentication story: `gh auth login`, GH_TOKEN, and the
 * GH_HOST / GH_ENTERPRISE_TOKEN pair for GitHub Enterprise Server.
 *
 * Nothing here touches a token.
 */
final class GhRepository implements TreeSource, ConfigSource
{
    private string $defaultBranch = '';
    private string $encodedBranch = '';

    public function __construct(
        private readonly string $repository,
        private readonly Execer $exec,
    ) {
    }

    /**
     * Verify gh exists and is authenticated against the effective host.
     *
     * @throws FatalException
     */
    public function check(): void
    {
        $host = getenv('GH_HOST');
        if (false === $host || '' === $host) {
            $host = 'github.com';
        }

        $result = $this->exec->combined(['gh', 'auth', 'status', '--hostname', $host]);
        if ($result->succeeded()) {
            return;
        }

        if ($result->notFound()) {
            throw new FatalException('gh not found — install it from https://cli.github.com');
        }

        throw new FatalException(sprintf(
            "gh is not authenticated to %s — run 'gh auth login' or set GH_TOKEN",
            $host,
        ));
    }

    /**
     * Look the repository up and pin its default branch.
     *
     * A renamed or transferred repo redirects, so the response can describe a
     * different repository than the one named on the command line. That is
     * refused rather than followed.
     *
     * @throws FatalException
     */
    public function resolve(): void
    {
        $result = $this->exec->combined(['gh', 'api', 'repos/'.$this->repository]);
        if (!$result->succeeded()) {
            throw new FatalException(sprintf(
                'cannot read repos/%s: %s',
                $this->repository,
                $result->truncatedOutput(),
            ));
        }

        $decoded = json_decode($result->output, true);
        if (!is_array($decoded)) {
            throw new FatalException(sprintf(
                'cannot read repos/%s: %s',
                $this->repository,
                $result->truncatedOutput(),
            ));
        }

        $fullName = is_string($decoded['full_name'] ?? null) ? $decoded['full_name'] : '';
        if (0 !== strcasecmp($fullName, $this->repository)) {
            throw new FatalException(sprintf(
                "repos/%s resolved to '%s' (renamed or transferred?) — re-run with the canonical name",
                $this->repository,
                $fullName,
            ));
        }

        $this->defaultBranch = is_string($decoded['default_branch'] ?? null) ? $decoded['default_branch'] : '';
        $this->encodedBranch = Uri::escape($this->defaultBranch);
    }

    public function defaultBranch(): string
    {
        return $this->defaultBranch;
    }

    /**
     * Every blob path on the default branch, via the git trees API.
     */
    public function listPaths(): array
    {
        $result = $this->exec->combined(['gh', 'api', sprintf(
            'repos/%s/git/trees/%s?recursive=1',
            $this->repository,
            $this->encodedBranch,
        )]);

        if (!$result->succeeded()) {
            throw new \RuntimeException('cannot read the file tree: '.$result->truncatedOutput());
        }

        $decoded = json_decode($result->output, true);
        if (!is_array($decoded)) {
            throw new \RuntimeException(sprintf('cannot parse the file tree for %s', $this->repository));
        }

        if (true === ($decoded['truncated'] ?? false)) {
            throw new TruncatedTreeException($this->repository);
        }

        $tree = $decoded['tree'] ?? [];
        if (!is_array($tree)) {
            throw new \RuntimeException(sprintf('cannot parse the file tree for %s', $this->repository));
        }

        $paths = [];
        foreach ($tree as $entry) {
            if (is_array($entry) && 'blob' === ($entry['type'] ?? null) && is_string($entry['path'] ?? null)) {
                $paths[] = $entry['path'];
            }
        }

        return Paths::sortedUnique($paths);
    }

    /**
     * One file's raw contents from the default branch.
     *
     * Any failure means "treat the file as absent", exactly like the silenced
     * call it replaces.
     */
    public function readBlob(string $path): ?string
    {
        $result = $this->exec->output(['gh', 'api', sprintf(
            'repos/%s/contents/%s?ref=%s',
            $this->repository,
            Uri::escape($path),
            $this->encodedBranch,
        ), '-H', 'Accept: application/vnd.github.raw']);

        return $result->succeeded() ? $result->output : null;
    }

    /**
     * Fetch .github/dependabot.yml.
     *
     * Dependabot reads `.yml` only, so a `.yaml` sitting there alone is a
     * trap. That state is an error, not an absence.
     */
    public function readConfig(): ?string
    {
        $primary = $this->contents(ConfigFile::PATH);
        if ($primary->succeeded()) {
            return $primary->output;
        }

        $alternate = $this->contents(ConfigFile::ALTERNATE_PATH);
        if ($alternate->succeeded() && '' !== $alternate->output) {
            throw new \RuntimeException(sprintf(
                '%s exists but Dependabot reads %s — rename it first',
                ConfigFile::ALTERNATE_PATH,
                ConfigFile::PATH,
            ));
        }

        return null;
    }

    private function contents(string $path): ExecResult
    {
        return $this->exec->output(['gh', 'api', sprintf(
            'repos/%s/contents/%s?ref=%s',
            $this->repository,
            Uri::escape($path),
            $this->encodedBranch,
        ), '-H', 'Accept: application/vnd.github.raw']);
    }
}
