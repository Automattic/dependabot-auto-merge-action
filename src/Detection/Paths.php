<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * Path arithmetic over a repository's file list.
 *
 * Everything here is pure. The repository is a list of strings, never a
 * working tree.
 *
 * Every sort in this class is byte-wise, via {@see strcmp}. That is
 * deliberate and load-bearing: it is the `LC_ALL=C` collation the original
 * bash script forced on `sort` and `comm`, so report line ordering is
 * machine-independent by construction. PHP's bare `sort()` defaults to
 * `SORT_REGULAR`, which compares numeric-looking strings numerically and
 * would order `['10', '9']` as `9, 10`. Do not use it here.
 */
final class Paths
{
    /**
     * Map "", "." and relative spellings onto the leading-slash directory
     * form the report uses: "/" for the root, "/a/b" otherwise.
     */
    public static function normalizeDir(string $dir): string
    {
        if (str_starts_with($dir, './')) {
            $dir = substr($dir, 2);
        }
        if ('' === $dir || '.' === $dir) {
            return '/';
        }
        if (!str_starts_with($dir, '/')) {
            $dir = '/'.$dir;
        }
        while (str_ends_with($dir, '/') && '/' !== $dir) {
            $dir = substr($dir, 0, -1);
        }

        return $dir;
    }

    /**
     * The parent of a normalized directory. The root has none, and returns
     * the empty string as that sentinel.
     */
    public static function parentDir(string $dir): string
    {
        if ('/' === $dir) {
            return '';
        }
        $parent = substr($dir, 0, (int) strrpos($dir, '/'));

        return '' === $parent ? '/' : $parent;
    }

    /**
     * The directory part of a repo-relative file path, before normalization.
     *
     * Hand-rolled rather than {@see \basename}/{@see \dirname}, which special-case
     * trailing slashes and (for basename) can be locale-sensitive. A file
     * list needs neither behaviour.
     */
    public static function dirOf(string $path): string
    {
        $slash = strrpos($path, '/');

        return false === $slash ? '' : substr($path, 0, $slash);
    }

    /**
     * The final segment of a repo-relative file path.
     */
    public static function baseOf(string $path): string
    {
        $slash = strrpos($path, '/');

        return false === $slash ? $path : substr($path, $slash + 1);
    }

    /**
     * Map file paths to their normalized directories, sorted and deduplicated.
     *
     * @param list<string> $paths
     *
     * @return list<string>
     */
    public static function dirsOf(array $paths): array
    {
        $dirs = [];
        foreach ($paths as $path) {
            $dirs[] = self::normalizeDir(self::dirOf($path));
        }

        return self::sortedUnique($dirs);
    }

    /**
     * Select the paths whose basename is one of $names, keeping input order.
     *
     * @param list<string> $paths
     * @param list<string> $names
     *
     * @return list<string>
     */
    public static function withBasenames(array $paths, array $names): array
    {
        $want = array_fill_keys($names, true);

        $out = [];
        foreach ($paths as $path) {
            if (isset($want[self::baseOf($path)])) {
                $out[] = $path;
            }
        }

        return $out;
    }

    /**
     * Sort byte-wise and drop duplicates.
     *
     * @param list<string> $items
     *
     * @return list<string>
     */
    public static function sortedUnique(array $items): array
    {
        usort($items, strcmp(...));

        $out = [];
        foreach ($items as $i => $item) {
            if (0 === $i || $item !== $items[$i - 1]) {
                $out[] = $item;
            }
        }

        return $out;
    }

    /**
     * The items present in both sorted lists — `comm -12`.
     *
     * @param list<string> $a
     * @param list<string> $b
     *
     * @return list<string>
     */
    public static function intersect(array $a, array $b): array
    {
        $out = [];
        $i = $j = 0;
        while ($i < count($a) && $j < count($b)) {
            $cmp = strcmp($a[$i], $b[$j]);
            if ($cmp < 0) {
                ++$i;
            } elseif ($cmp > 0) {
                ++$j;
            } else {
                $out[] = $a[$i];
                ++$i;
                ++$j;
            }
        }

        return $out;
    }

    /**
     * The items of sorted $a that are not in sorted $b — `comm -23`.
     *
     * @param list<string> $a
     * @param list<string> $b
     *
     * @return list<string>
     */
    public static function subtract(array $a, array $b): array
    {
        $out = [];
        $i = $j = 0;
        while ($i < count($a)) {
            if ($j >= count($b) || strcmp($a[$i], $b[$j]) < 0) {
                $out[] = $a[$i];
                ++$i;
            } elseif (strcmp($a[$i], $b[$j]) > 0) {
                ++$j;
            } else {
                ++$i;
                ++$j;
            }
        }

        return $out;
    }

    /**
     * Pick the plural form matching $n.
     */
    public static function plural(int $n, string $one, string $many): string
    {
        return 1 === $n ? $one : $many;
    }
}
