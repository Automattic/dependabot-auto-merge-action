<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Console;

use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\UsageException;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * The command line surface.
 *
 * Parsing and validation only. The run itself is {@see \Automattic\DependabotDirectories\Pipeline}.
 */
#[AsCommand(
    name: 'dependabot-directories',
    description: 'map dependency manifests and lockfiles into .github/dependabot.yml',
)]
final class DetectDirectoriesCommand extends Command
{
    /**
     * Accept only a literal owner/repo.
     *
     * gh expands the placeholders {owner} and {repo} from GH_REPO or the
     * current checkout, so anything that is not strictly literal could
     * address a different repository than the one named on the command line.
     */
    private const REPOSITORY = '~^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$~D';

    private const DESCRIPTION = <<<'TEXT'
        Detect manifest and lockfile locations in a repository and land the
        .github/dependabot.yml directory mappings needed to cover them, proposed on
        a branch as a pull request. The default branch is never written to directly.

        Detection is remote — the git trees API, plus a handful of Contents API reads
        for workspace declarations, with a blobless-clone fallback for trees the API
        truncates.

        Authentication uses the gh CLI's credentials (gh auth login, or the GH_TOKEN
        env var). GH_TOKEN/GITHUB_TOKEN apply to github.com and ghe.com; for GitHub
        Enterprise Server set GH_HOST and GH_ENTERPRISE_TOKEN (or
        GITHUB_ENTERPRISE_TOKEN). A fine-grained PAT scoped to the repo needs:
           - Contents: Read & write      (file list, file contents, branch and commit)
           - Pull requests: Read & write (opening and updating the PR)
           - Metadata: Read              (implied by the above)
        --dry-run needs only the read halves.
        TEXT;

    protected function configure(): void
    {
        $this
            ->setHelp(self::DESCRIPTION)
            // Declared as an array so the "how many were given" checks below
            // can produce their own messages rather than Symfony's.
            ->addArgument('repository', InputArgument::IS_ARRAY, 'owner/repo')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'report the mapping and print a unified diff of the proposed .github/dependabot.yml without writing anything; read-only calls still run, so the output matches what a real run would decide')
            ->addOption('detect-only', null, InputOption::VALUE_NONE, 'print the detected mappings and exit, before any API call')
            ->addOption('include', null, InputOption::VALUE_REQUIRED | InputOption::VALUE_IS_ARRAY, 'treat a soft-excluded directory name (examples, dist, fixtures, ...) as real; repeatable')
            ->addOption('enable-version-updates', null, InputOption::VALUE_NONE, 'emit the full house template (open-pull-requests-limit 10 plus minor/patch grouping) instead of the security-only default of 0')
            ->addOption('force', null, InputOption::VALUE_NONE, 'proceed past the sanity cap of 50 mapped pairs')
            ->addOption('allow-full-clone', null, InputOption::VALUE_NONE, 'when the git trees API truncates and the server refuses a blobless clone, fall back to a full clone; off by default because the repositories that truncate are exactly the ones too large to clone whole')
            ->addOption('paths-from-file', null, InputOption::VALUE_REQUIRED, 'read the repository file list from file, one path per line, instead of calling the API; blob contents are read from <file-without-extension>.blobs/<path> — offline testing seam')
            ->addOption('existing-config', null, InputOption::VALUE_REQUIRED, 'read the current .github/dependabot.yml from file instead of the API — offline testing seam');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        // Never reached: Application drives the pipeline so it can hand the
        // report raw streams instead of Symfony's formatter.
        return Command::SUCCESS;
    }

    /**
     * Validate the parsed command line in the same order the original did, so
     * the first reported problem stays the same.
     *
     * @throws UsageException
     * @throws FatalException
     */
    public static function gather(InputInterface $input): Options
    {
        /** @var list<string> $include */
        $include = $input->getOption('include');

        // Symfony refuses a bare `--include --dry-run` at parse time, so an
        // option cannot be swallowed as a value. The `=` form hands the value
        // straight over though, past that check, so `--include=--dry-run` and
        // `--include=` still have to be caught here.
        foreach ($include as $name) {
            if ('' === $name) {
                throw new UsageException('--include needs a value');
            }
            if (str_starts_with($name, '-')) {
                throw new UsageException(sprintf("--include needs a value, got option '%s'", $name));
            }
        }

        /** @var list<string> $arguments */
        $arguments = $input->getArgument('repository');
        if ([] === $arguments) {
            throw new UsageException('missing required argument: owner/repo');
        }
        if (count($arguments) > 1) {
            throw new UsageException(sprintf('unexpected argument: %s', $arguments[1]));
        }

        $repository = $arguments[0];
        if (1 !== preg_match(self::REPOSITORY, $repository)) {
            throw new UsageException(sprintf("invalid repository '%s' — expected owner/repo", $repository));
        }

        $pathsFromFile = self::stringOption($input, 'paths-from-file');
        if (null !== $pathsFromFile && !file_exists($pathsFromFile)) {
            throw new FatalException(sprintf('--paths-from-file: no such file: %s', $pathsFromFile));
        }

        $existingConfig = self::stringOption($input, 'existing-config');
        if (null !== $existingConfig && !file_exists($existingConfig)) {
            throw new FatalException(sprintf('--existing-config: no such file: %s', $existingConfig));
        }

        $dryRun = (bool) $input->getOption('dry-run');
        $detectOnly = (bool) $input->getOption('detect-only');

        // The offline seams describe a repository that may not be the real
        // one, so they must never drive a write.
        if (!$dryRun && !$detectOnly && (null !== $pathsFromFile || null !== $existingConfig)) {
            throw new FatalException('--paths-from-file and --existing-config describe a repository from disk — combine them with --dry-run or --detect-only');
        }

        return new Options(
            repository: $repository,
            dryRun: $dryRun,
            detectOnly: $detectOnly,
            enableVersionUpdates: (bool) $input->getOption('enable-version-updates'),
            force: (bool) $input->getOption('force'),
            allowFullClone: (bool) $input->getOption('allow-full-clone'),
            include: $include,
            pathsFromFile: $pathsFromFile,
            existingConfigFile: $existingConfig,
        );
    }

    private static function stringOption(InputInterface $input, string $name): ?string
    {
        $value = $input->getOption($name);

        return is_string($value) && '' !== $value ? $value : null;
    }
}
