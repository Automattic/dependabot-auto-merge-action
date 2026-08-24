<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

use Automattic\DependabotDirectories\Detection\Ecosystem;
use Automattic\DependabotDirectories\Detection\Pair;
use Automattic\DependabotDirectories\Detection\Paths;
use Automattic\DependabotDirectories\Glob\GlobTranslator;
use Symfony\Component\Yaml\Exception\ParseException;
use Symfony\Component\Yaml\Yaml;

/**
 * What an existing dependabot.yml already covers.
 *
 * Parsing here is read-only. The merge never round-trips YAML.
 */
final class CoverageParser
{
    private const GLOB_CHARS = '~[*?]~';

    /**
     * List the (ecosystem, directory) records the file already maps.
     *
     * Entries carrying `target-branch` are skipped: Dependabot's security
     * updates ignore them, so counting one as coverage would reintroduce the
     * exact bug this tool exists to fix.
     *
     * `PARSE_OBJECT_FOR_MAP` keeps a YAML mapping distinguishable from a YAML
     * sequence, which the shape checks below depend on. Without it both
     * decode to a PHP array and a top-level sequence would read as an empty
     * mapping instead of the refusal it is.
     *
     * @return list<CoverageEntry>
     *
     * @throws \RuntimeException
     */
    public static function parse(string $raw): array
    {
        try {
            $document = Yaml::parse($raw, Yaml::PARSE_OBJECT_FOR_MAP);
        } catch (ParseException) {
            throw new \RuntimeException(sprintf(
                'cannot parse %s as YAML — refusing to guess at what it already covers',
                ConfigFile::PATH,
            ));
        }

        if (null === $document) {
            return [];
        }
        if (!$document instanceof \stdClass) {
            throw new \RuntimeException('cannot read the update entries in '.ConfigFile::PATH);
        }

        $updates = $document->updates ?? null;
        if (null === $updates) {
            return [];
        }
        if (!is_array($updates)) {
            throw new \RuntimeException(sprintf(
                "%s has an 'updates' key that is not a list — fix it by hand",
                ConfigFile::PATH,
            ));
        }

        $entries = [];
        foreach ($updates as $item) {
            if (!$item instanceof \stdClass) {
                throw new \RuntimeException('cannot read the update entries in '.ConfigFile::PATH);
            }
            if (null !== ($item->{'target-branch'} ?? null)) {
                continue;
            }

            $ecosystem = '?';
            $declared = $item->{'package-ecosystem'} ?? null;
            if (null !== $declared) {
                $ecosystem = self::stringify($declared);
            }

            $directories = $item->directories ?? null;
            if (is_array($directories)) {
                foreach ($directories as $directory) {
                    $entries[] = new CoverageEntry($ecosystem, self::stringify($directory));
                }
            }

            $directory = $item->directory ?? null;
            if (null !== $directory) {
                $entries[] = new CoverageEntry($ecosystem, self::stringify($directory));
            }
        }

        return $entries;
    }

    /**
     * Whether (ecosystem, directory) is already mapped.
     *
     * An existing glob entry counts: matching it beats emitting a duplicate
     * Dependabot would reject the whole config over.
     *
     * @param list<CoverageEntry> $entries
     */
    public static function covers(array $entries, Ecosystem $ecosystem, string $directory): bool
    {
        foreach ($entries as $entry) {
            if ($entry->ecosystem !== $ecosystem->value) {
                continue;
            }

            $existing = Paths::normalizeDir($entry->directory);
            if ($existing === $directory) {
                return true;
            }
            if (1 === preg_match(self::GLOB_CHARS, $existing)
                && GlobTranslator::matches(GlobTranslator::toRegexp($existing), $directory)
            ) {
                return true;
            }
        }

        return false;
    }

    /**
     * Existing entries pointing at directories detection found no manifest in.
     *
     * Compared against the detected pairs rather than the rendered blocks: a
     * directory folded into a glob is still very much detected. Glob entries
     * are never called stale.
     *
     * @param list<CoverageEntry> $entries
     * @param list<Pair>          $pairs
     *
     * @return list<string>
     */
    public static function staleNotes(array $entries, array $pairs): array
    {
        if ([] === $entries) {
            return [];
        }

        $detected = [];
        foreach ($pairs as $pair) {
            $detected[$pair->ecosystem->value.'|'.$pair->directory] = true;
        }

        $notes = [];
        foreach ($entries as $entry) {
            if (1 === preg_match(self::GLOB_CHARS, $entry->directory)) {
                continue;
            }
            $directory = Paths::normalizeDir($entry->directory);
            if (!isset($detected[$entry->ecosystem.'|'.$directory])) {
                $notes[] = sprintf(
                    'existing entry (%s, %s) matches nothing we detected — left alone',
                    $entry->ecosystem,
                    $directory,
                );
            }
        }

        return $notes;
    }

    /**
     * Render a decoded YAML scalar for the report.
     *
     * PHP's own string cast is not a substitute. It renders `true` as "1",
     * where the report text needs "true".
     */
    private static function stringify(mixed $value): string
    {
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_scalar($value)) {
            return (string) $value;
        }

        return get_debug_type($value);
    }
}
