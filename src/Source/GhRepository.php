<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

use Automattic\DependabotDirectories\Config\ConfigFile;
use Automattic\DependabotDirectories\Detection\Paths;
use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\TruncatedTreeException;
use Automattic\DependabotDirectories\Report\Reporter;

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
     * The default branch percent-encoded for use in a URL path.
     */
    public function encodedBranch(): string
    {
        return $this->encodedBranch;
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
     * The fallback for repositories big enough to truncate the git trees
     * API: a blobless shallow clone, listed with `git ls-tree`.
     *
     * `gh repo clone` rather than a raw `git clone`, so the token never lands
     * in argv or in a remote URL.
     *
     * A server without `uploadpack.allowFilter` refuses the filter. Falling
     * back to a full clone silently would mean cloning, in full, exactly the
     * repositories large enough to truncate the tree API in the first place,
     * so that path is gated behind $allowFullClone.
     *
     * @return list<string>
     *
     * @throws \RuntimeException
     */
    public function listPathsByClone(bool $allowFullClone, Reporter $reporter): array
    {
        if ($this->exec->output(['git', '--version'])->notFound()) {
            throw new \RuntimeException('git not found, and the tree API truncated — install git or run against a smaller repository');
        }

        $destination = sys_get_temp_dir().'/dependabot-directories-clone-'.bin2hex(random_bytes(8));

        try {
            $this->clone($destination, $allowFullClone, $reporter);

            $listing = $this->exec->output(['git', '-C', $destination, 'ls-tree', '-r', '--name-only', 'HEAD']);
            if (!$listing->succeeded()) {
                throw new \RuntimeException(sprintf('cannot list files in the clone of %s', $this->repository));
            }

            $paths = [];
            foreach (explode("\n", $listing->output) as $line) {
                if ('' !== $line) {
                    $paths[] = $line;
                }
            }

            $paths = Paths::sortedUnique($paths);
            if ([] === $paths) {
                throw new \RuntimeException(sprintf('the clone of %s produced an empty file list', $this->repository));
            }

            return $paths;
        } finally {
            $this->removeTree($destination);
        }
    }

    private function clone(string $destination, bool $allowFullClone, Reporter $reporter): void
    {
        $blobless = $this->exec->combined([
            'gh', 'repo', 'clone', $this->repository, $destination, '--',
            '--depth', '1', '--filter=blob:none', '--no-checkout',
            '--single-branch', '--branch', $this->defaultBranch,
        ]);
        if ($blobless->succeeded()) {
            return;
        }

        if (!$allowFullClone) {
            throw new \RuntimeException(sprintf(
                'blobless clone of %s failed and --allow-full-clone was not given: %s',
                $this->repository,
                $blobless->truncatedOutput(),
            ));
        }

        $reporter->note('blobless clone refused — falling back to a full clone as requested');

        $full = $this->exec->combined([
            'gh', 'repo', 'clone', $this->repository, $destination, '--',
            '--depth', '1', '--no-checkout', '--single-branch', '--branch', $this->defaultBranch,
        ]);
        if (!$full->succeeded()) {
            throw new \RuntimeException(sprintf(
                'cannot clone %s: %s',
                $this->repository,
                $full->truncatedOutput(),
            ));
        }
    }

    private function removeTree(string $path): void
    {
        if (!is_dir($path)) {
            return;
        }

        $entries = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($path, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST,
        );
        foreach ($entries as $entry) {
            /** @var \SplFileInfo $entry */
            if ($entry->isDir()) {
                @rmdir($entry->getPathname());
            } else {
                @unlink($entry->getPathname());
            }
        }
        @rmdir($path);
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
