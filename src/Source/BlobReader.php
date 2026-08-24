<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * The one slice of the repository detection reads beyond the path list:
 * individual files, for workspace declarations.
 */
interface BlobReader
{
    /**
     * One file's contents by repo-relative path.
     *
     * Null means "treat the file as absent". Every failure mode collapses to
     * that, exactly as the silenced original call did.
     */
    public function readBlob(string $path): ?string;
}
