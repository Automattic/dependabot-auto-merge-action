<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

use Automattic\DependabotDirectories\Detection\Block;

/**
 * Render one update entry in the repo's house style, matching the
 * indentation detected from the existing file.
 */
final class BlockRenderer
{
    /**
     * Values are spliced into the quotes verbatim, as the original `printf`
     * did. Escaping them would drift from the transcripts.
     */
    public static function render(Block $block, string $item, string $child, bool $versionUpdates): string
    {
        $eco = $block->ecosystem->value;

        $out = sprintf("%s- package-ecosystem: \"%s\"\n", $item, $eco);

        if ($block->isGlob) {
            $out .= sprintf("%sdirectories:\n", $child);
            $out .= sprintf("%s  - \"%s\"\n", $child, $block->directory);
        } else {
            $out .= sprintf("%sdirectory: \"%s\"\n", $child, $block->directory);
        }

        $out .= sprintf("%sschedule:\n", $child);
        $out .= sprintf("%s  interval: \"weekly\"\n", $child);
        $out .= sprintf("%s  day: \"monday\"\n", $child);

        if ($versionUpdates) {
            $out .= sprintf("%sopen-pull-requests-limit: 10\n", $child);
            $out .= sprintf("%sgroups:\n", $child);
            $out .= sprintf("%s  %s-minor-patch:\n", $child, $eco);
            $out .= sprintf("%s    patterns:\n", $child);
            $out .= sprintf("%s      - \"*\"\n", $child);
            $out .= sprintf("%s    update-types:\n", $child);
            $out .= sprintf("%s      - \"minor\"\n", $child);
            $out .= sprintf("%s      - \"patch\"\n", $child);
            $out .= sprintf("%s  %s-major:\n", $child, $eco);
            $out .= sprintf("%s    patterns:\n", $child);
            $out .= sprintf("%s      - \"*\"\n", $child);
            $out .= sprintf("%s    update-types:\n", $child);
            $out .= sprintf("%s      - \"major\"\n", $child);
        } else {
            // Security updates need the directory mapping; version-update PRs
            // are noise the repo owner did not ask for.
            $out .= sprintf("%sopen-pull-requests-limit: 0\n", $child);
        }

        $out .= sprintf("%scooldown:\n", $child);
        $out .= sprintf("%s  default-days: 7\n", $child);

        return $out;
    }
}
