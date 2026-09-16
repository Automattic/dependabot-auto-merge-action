<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

/**
 * Match the file's own indentation rather than imposing ours.
 *
 * The item indent comes from the first entry's dash, the child indent from
 * the first child key when there is one — prefer what the file actually does
 * over what the dash implies.
 */
final class IndentationDetector
{
    private const ITEM_LINE = '~^[[:space:]]*-[[:space:]]+package-ecosystem:~';
    private const CHILD_KEY = '~^[[:space:]]+(schedule|directory|directories|open-pull-requests-limit|cooldown|groups|target-branch):~';

    /**
     * @return array{string, string} the item indent and the child indent
     */
    public static function detect(string $raw): array
    {
        $item = '  ';
        $child = '    ';

        $afterUpdates = false;
        $itemFound = false;

        foreach (explode("\n", $raw) as $line) {
            if (!$afterUpdates) {
                $afterUpdates = str_starts_with($line, 'updates:');
                continue;
            }

            if (!$itemFound && 1 === preg_match(self::ITEM_LINE, $line)) {
                $itemFound = true;
                $item = self::leadingSpace($line);
                // Past the dash.
                $rest = substr($line, strlen($item) + 1);
                $gap = self::leadingSpace($rest);
                $child = $item.' '.str_repeat(' ', strlen($gap));
            }

            if ($itemFound && 1 === preg_match(self::CHILD_KEY, $line)) {
                $child = self::leadingSpace($line);
                break;
            }
        }

        return [$item, $child];
    }

    private static function leadingSpace(string $line): string
    {
        return substr($line, 0, strlen($line) - strlen(ltrim($line, " \t")));
    }
}
