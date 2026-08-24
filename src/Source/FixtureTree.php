<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

use Automattic\DependabotDirectories\Detection\Paths;

/**
 * The offline TreeSource behind `--paths-from-file`.
 *
 * The file list comes from a text file, one path per line, and blob contents
 * from the sibling `<file-without-extension>.blobs/` directory.
 */
final readonly class FixtureTree implements TreeSource
{
    public function __construct(private string $pathsFile)
    {
    }

    /**
     * Mirror the original `${f%.*}.blobs` derivation — everything after the
     * last dot anywhere in the path counts as the extension.
     */
    public function blobDir(): string
    {
        $base = $this->pathsFile;
        $dot = strrpos($base, '.');
        if (false !== $dot) {
            $base = substr($base, 0, $dot);
        }

        return $base.'.blobs';
    }

    /**
     * Accept hand-written fixtures as they are: `./x` and `/x` spellings are
     * normalized, blank lines dropped, and the result sorted byte-wise.
     */
    public function listPaths(): array
    {
        if (!is_file($this->pathsFile)) {
            throw new \RuntimeException(sprintf('cannot read %s', $this->pathsFile));
        }
        $raw = file_get_contents($this->pathsFile);
        if (false === $raw) {
            throw new \RuntimeException(sprintf('cannot read %s', $this->pathsFile));
        }

        $paths = [];
        foreach (explode("\n", $raw) as $line) {
            if (str_starts_with($line, './')) {
                $line = substr($line, 2);
            }
            if (str_starts_with($line, '/')) {
                $line = substr($line, 1);
            }
            if ('' === trim($line)) {
                continue;
            }
            $paths[] = $line;
        }

        return Paths::sortedUnique($paths);
    }

    public function readBlob(string $path): ?string
    {
        $file = $this->blobDir().'/'.$path;
        if (!is_file($file)) {
            return null;
        }

        $body = file_get_contents($file);

        return false === $body ? null : $body;
    }
}
