<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Report\Reporter;

/**
 * Render the missing blocks and splice them into the existing file after the
 * last line of the `updates:` block.
 */
final class ProposalBuilder
{
    /**
     * Normalization mirrors the original `$(cat)`/`printf` pair: all trailing
     * newlines collapse to exactly one, and nothing else changes — CR bytes
     * included.
     *
     * @param list<Block> $missing
     */
    public static function build(
        string $raw,
        bool $present,
        array $missing,
        string $item,
        string $child,
        bool $versionUpdates,
        Reporter $reporter,
    ): Proposal {
        $rendered = '';
        foreach ($missing as $block) {
            $rendered .= BlockRenderer::render($block, $item, $child, $versionUpdates);
            $reporter->would(sprintf('map %s -> %s', $block->ecosystem->value, $block->directory));
        }

        if (!$present) {
            return new Proposal(null, "version: 2\nupdates:\n".$rendered);
        }

        $normalized = rtrim($raw, "\n")."\n";

        // Split on \n alone, never a \r-trimming reader: CRLF files must come
        // through the splice byte-identical outside the appended region.
        $lines = explode("\n", $normalized);
        $insert = self::insertionLine($lines);

        $out = '';
        for ($i = 0; $i < $insert; ++$i) {
            $out .= $lines[$i]."\n";
        }
        $out .= $rendered;
        // count - 1 skips the final split artifact.
        for ($i = $insert, $last = count($lines) - 1; $i < $last; ++$i) {
            $out .= $lines[$i]."\n";
        }

        return new Proposal($normalized, $out);
    }

    /**
     * The 1-based number of the last line of the `updates:` block — the line
     * new entries are appended after.
     *
     * Blank lines do not extend the block (a trailing gap belongs to whatever
     * follows), comments inside it do, and the next top-level key ends it.
     *
     * @param list<string> $lines
     */
    public static function insertionLine(array $lines): int
    {
        $last = 0;
        $seen = false;

        foreach ($lines as $n => $line) {
            if (!$seen) {
                if (1 === preg_match(ShapeGuard::UPDATES_KEY, $line)) {
                    $seen = true;
                    $last = $n + 1;
                }
                continue;
            }

            if ('' === trim($line)) {
                // Blank: skip without advancing.
                continue;
            }
            if (str_starts_with(ltrim($line, " \t"), '#')) {
                $last = $n + 1;
                continue;
            }
            // A line starting in column zero is the next top-level key, and
            // it ends the block. Blank lines were handled above, so this line
            // is known to have a first byte.
            if (' ' !== $line[0] && "\t" !== $line[0]) {
                return $last;
            }
            $last = $n + 1;
        }

        return $last;
    }
}
