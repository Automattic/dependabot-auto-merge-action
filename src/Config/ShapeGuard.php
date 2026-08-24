<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

/**
 * Refuse to text-splice a file whose structure cannot be reasoned about.
 *
 * The merge is an append-only text splice — never a YAML round-trip, which
 * would destroy comments and reorder keys — so these guards stay line
 * oriented on purpose. The splice edits bytes, so its guards must reason
 * about bytes, never a parse.
 *
 * Each refusal names the fix. None of them is guessed around.
 */
final class ShapeGuard
{
    private const CONTENT_LINE = '~^[[:space:]]*[^[:space:]#]~';
    private const TAB_INDENT = "~^\t| \t|\t ~";
    private const DOC_MARKER = '~^(---|\.\.\.)[[:space:]]*$~D';
    private const ANCHOR = '~(^|[[:space:]])[&*][A-Za-z0-9_-]+|<<:~';
    private const INLINE = '~^updates:[[:space:]]*[\[{]~';

    public const UPDATES_KEY = '~^updates:[[:space:]]*(#.*)?$~D';

    /**
     * @throws \RuntimeException naming the structure that cannot be spliced
     */
    public static function check(string $raw): void
    {
        $lines = explode("\n", $raw);

        $hasContent = false;
        $hasTabIndent = false;
        $documentMarkers = 0;

        foreach ($lines as $line) {
            if (1 === preg_match(self::CONTENT_LINE, $line)) {
                $hasContent = true;
            }
            if (1 === preg_match(self::TAB_INDENT, $line)) {
                $hasTabIndent = true;
            }
            if (1 === preg_match(self::DOC_MARKER, $line)) {
                ++$documentMarkers;
            }
        }

        if ($hasContent && $hasTabIndent) {
            throw new \RuntimeException(ConfigFile::PATH.' indents with tabs, which YAML forbids — fix it by hand');
        }
        if ($documentMarkers > 1) {
            throw new \RuntimeException(ConfigFile::PATH.' holds more than one YAML document — fix it by hand');
        }

        foreach ($lines as $line) {
            if (1 === preg_match(self::ANCHOR, $line)) {
                throw new \RuntimeException(ConfigFile::PATH.' uses YAML anchors, aliases or merge keys — an append-only text edit cannot reason about those');
            }
        }

        $hasUpdates = false;
        foreach ($lines as $line) {
            if (1 === preg_match(self::INLINE, $line)) {
                throw new \RuntimeException(ConfigFile::PATH.' declares updates in inline form — convert it to a block sequence first');
            }
            if (1 === preg_match(self::UPDATES_KEY, $line)) {
                $hasUpdates = true;
            }
        }
        if (!$hasUpdates) {
            throw new \RuntimeException(ConfigFile::PATH." has no top-level 'updates:' key — fix it by hand");
        }
    }
}
