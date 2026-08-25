<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * Ecosystem exclusion policy, as resolved in docs/directory-mapping.md §2.
 */
final class ExclusionPolicy
{
    /**
     * Directories that never hold first-party manifests. Dropped silently,
     * and `--include` cannot readmit them.
     *
     * @var list<string>
     */
    public const HARD = ['node_modules', 'vendor', 'bower_components', '.git'];

    /**
     * Directories that usually hold copies, samples or build output. Matching
     * paths are reported and skipped; `--include` readmits a name.
     *
     * @var list<string>
     */
    public const SOFT = ['fixtures', '__fixtures__', 'testdata', 'examples', 'example', 'dist', 'build', '.next', 'coverage'];

    /**
     * Apply the hard and soft exclusion lists to a path list.
     *
     * Input order is preserved in both outputs.
     *
     * @param list<string> $paths
     * @param list<string> $include soft names to readmit, and only soft names —
     *                              a hard exclusion is not negotiable
     */
    public static function split(array $paths, array $include): ExclusionResult
    {
        $included = array_fill_keys($include, true);

        $soft = [];
        foreach (self::SOFT as $name) {
            if (!isset($included[$name])) {
                $soft[$name] = true;
            }
        }
        $hard = array_fill_keys(self::HARD, true);

        $keptPaths = [];
        $softPaths = [];
        foreach ($paths as $path) {
            if (self::underAnyDir($path, $hard)) {
                continue;
            }
            if (self::underAnyDir($path, $soft)) {
                $softPaths[] = $path;
                continue;
            }
            $keptPaths[] = $path;
        }

        return new ExclusionResult($keptPaths, $softPaths);
    }

    /**
     * Whether any non-final path segment is one of $names.
     *
     * The exclusions name directories, so a plain file that happens to share
     * the name survives.
     *
     * @param array<string, true> $names
     */
    private static function underAnyDir(string $path, array $names): bool
    {
        $segments = explode('/', $path);
        array_pop($segments);

        foreach ($segments as $segment) {
            if (isset($names[$segment])) {
                return true;
            }
        }

        return false;
    }
}
