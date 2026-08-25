<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Tests\Support;

use Automattic\DependabotDirectories\Source\BlobReader;

/**
 * Serves blob contents from a map. Anything absent reads as a missing file.
 */
final readonly class FakeBlobs implements BlobReader
{
    /**
     * @param array<string, string> $blobs
     */
    public function __construct(private array $blobs = [])
    {
    }

    public function readBlob(string $path): ?string
    {
        return $this->blobs[$path] ?? null;
    }
}
