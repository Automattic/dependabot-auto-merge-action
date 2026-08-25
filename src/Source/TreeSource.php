<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * Lists a repository's file paths and reads individual blobs.
 *
 * One implementation reads fixtures from disk, the other execs `gh`.
 * Detection never knows which one it is talking to — that seam is what lets
 * the heuristics run offline against synthetic repositories.
 */
interface TreeSource extends BlobReader
{
    /**
     * Every blob path, cleaned, deduplicated and sorted byte-wise.
     *
     * @return list<string>
     *
     * @throws \RuntimeException when the listing cannot be trusted
     */
    public function listPaths(): array;
}
