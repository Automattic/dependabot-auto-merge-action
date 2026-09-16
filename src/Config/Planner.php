<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Detection\Paths;
use Automattic\DependabotDirectories\Report\Reporter;

/**
 * Decide what is missing, one detected block at a time.
 */
final class Planner
{
    /**
     * A glob whose members are only PARTLY mapped already is degraded to
     * singular entries for the unmapped members: emitting the glob would
     * overlap the existing entry, and overlapping entries are exactly what
     * makes Dependabot reject a config file outright, disabling updates the
     * repository already had.
     *
     * @param list<Block>         $blocks
     * @param list<CoverageEntry> $entries
     *
     * @return list<Block>
     */
    public static function planMissing(array $blocks, array $entries, Reporter $reporter): array
    {
        $missing = [];

        foreach ($blocks as $block) {
            if (CoverageParser::covers($entries, $block->ecosystem, $block->directory)) {
                $reporter->ok(sprintf('%s %s: already mapped', $block->ecosystem->value, $block->directory));
                continue;
            }

            if (!$block->isGlob) {
                $missing[] = $block;
                continue;
            }

            $coveredCount = 0;
            $uncovered = [];
            foreach ($block->members as $member) {
                if (CoverageParser::covers($entries, $block->ecosystem, $member)) {
                    ++$coveredCount;
                } else {
                    $uncovered[] = $member;
                }
            }

            if ([] === $uncovered) {
                $reporter->ok(sprintf('%s %s: already mapped', $block->ecosystem->value, $block->directory));
                continue;
            }
            if (0 === $coveredCount) {
                $missing[] = $block;
                continue;
            }

            $reporter->note(sprintf(
                "%s: '%s' would overlap %d %s already in the file — adding the %d unmapped %s singly instead",
                $block->ecosystem->value,
                $block->directory,
                $coveredCount,
                Paths::plural($coveredCount, 'entry', 'entries'),
                count($uncovered),
                Paths::plural(count($uncovered), 'directory', 'directories'),
            ));
            foreach ($uncovered as $member) {
                $missing[] = new Block($block->ecosystem, $member);
            }
        }

        return $missing;
    }
}
