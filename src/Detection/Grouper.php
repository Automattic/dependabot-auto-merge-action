<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

use Automattic\DependabotDirectories\Report\Reporter;

/**
 * Turn detected pairs into render blocks, folding two or more same-ecosystem
 * siblings under one parent into a `parent/*` glob.
 *
 * Workspace roots and github-actions are never grouped: the root lockfile
 * already absorbs packages added later, so a glob has nothing to gain.
 */
final class Grouper
{
    /**
     * @param list<Pair>   $pairs
     * @param list<string> $rawNpm      UNFILTERED npm manifest directories
     * @param list<string> $rawComposer UNFILTERED composer manifest directories
     *
     * @return list<Block>
     */
    public static function group(array $pairs, array $rawNpm, array $rawComposer, Reporter $reporter): array
    {
        $blocks = [];
        /** @var array<string, list<string>> $members eco|parent => member dirs */
        $members = [];
        /** @var array<string, true> $globbed eco|dir already standing behind a glob */
        $globbed = [];

        foreach (Pair::sortUnique($pairs) as $pair) {
            if (PairKind::Root === $pair->kind || Ecosystem::GithubActions === $pair->ecosystem) {
                $blocks[] = new Block($pair->ecosystem, $pair->directory);
                continue;
            }
            $key = $pair->ecosystem->value.'|'.Paths::parentDir($pair->directory);
            $members[$key][] = $pair->directory;
        }

        $keys = array_keys($members);
        usort($keys, strcmp(...));

        foreach ($keys as $key) {
            $group = Paths::sortedUnique($members[$key]);
            if (count($group) < 2) {
                continue;
            }
            [$eco, $parent] = explode('|', $key, 2);
            $ecosystem = Ecosystem::from($eco);

            // Guard 1: a parent of / would emit "/*" and sweep every
            // top-level directory in the repository.
            if ('' === $parent || '/' === $parent) {
                $reporter->note(sprintf(
                    "%s: %d directories sit at the repository root — keeping singular entries rather than globbing '/*'",
                    $eco,
                    count($group),
                ));
                continue;
            }

            // Guard 2: the glob must not re-admit what we excluded or map
            // what we did not.
            if (!self::globIsExact($ecosystem, $parent, $group, $rawNpm, $rawComposer)) {
                $reporter->note(sprintf(
                    "%s: '%s/*' would also match sibling directories this run did not map — keeping singular entries",
                    $eco,
                    $parent,
                ));
                continue;
            }

            $blocks[] = new Block($ecosystem, $parent.'/*', true, $group);
            foreach ($group as $directory) {
                $globbed[$eco.'|'.$directory] = true;
            }
        }

        foreach ($keys as $key) {
            [$eco] = explode('|', $key, 2);
            $ecosystem = Ecosystem::from($eco);
            foreach (Paths::sortedUnique($members[$key]) as $directory) {
                if (!isset($globbed[$eco.'|'.$directory])) {
                    $blocks[] = new Block($ecosystem, $directory);
                }
            }
        }

        return Block::sortUnique($blocks);
    }

    /**
     * Whether `<parent>/*` would match exactly the directories in $group and
     * nothing more, measured against the unfiltered manifest list.
     *
     * Unfiltered is the point: the glob GitHub expands knows nothing about
     * our exclusion list, so measuring against what we kept would let the
     * glob silently re-admit an excluded sibling.
     *
     * @param list<string> $group
     * @param list<string> $rawNpm
     * @param list<string> $rawComposer
     */
    private static function globIsExact(Ecosystem $ecosystem, string $parent, array $group, array $rawNpm, array $rawComposer): bool
    {
        $raw = match ($ecosystem) {
            Ecosystem::Npm => $rawNpm,
            Ecosystem::Composer => $rawComposer,
            Ecosystem::GithubActions => null,
        };
        if (null === $raw) {
            return false;
        }

        $inGroup = array_fill_keys($group, true);
        $prefix = $parent.'/';

        foreach ($raw as $directory) {
            // A direct child of parent holding a manifest, exclusions ignored.
            if (str_starts_with($directory, $prefix)
                && !str_contains(substr($directory, strlen($prefix)), '/')
                && !isset($inGroup[$directory])
            ) {
                return false;
            }
        }

        return true;
    }
}
