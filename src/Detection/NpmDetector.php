<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

use Automattic\DependabotDirectories\Glob\PatternSet;
use Automattic\DependabotDirectories\Report\Reporter;
use Automattic\DependabotDirectories\Source\BlobReader;
use Symfony\Component\Yaml\Exception\ParseException;
use Symfony\Component\Yaml\Yaml;

/**
 * Detect the npm-family entries.
 *
 * Roots are directories holding both a package.json and a lockfile. A root
 * that declares workspaces covers the manifests its patterns match, and
 * covered packages get no entry of their own — the rule that prevents
 * per-package entry spam in hoisted monorepos.
 */
final class NpmDetector
{
    /**
     * The lockfile basenames the npm family writes.
     *
     * @var list<string>
     */
    public const LOCKFILES = ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml'];

    /**
     * @param list<string> $kept
     *
     * @return list<Pair>
     */
    public static function detect(array $kept, BlobReader $blobs, Reporter $reporter): array
    {
        $keptSet = array_fill_keys($kept, true);

        $manifests = Paths::dirsOf(Paths::withBasenames($kept, ['package.json']));
        $locks = Paths::dirsOf(Paths::withBasenames($kept, self::LOCKFILES));

        if ([] === $manifests) {
            return [];
        }

        $roots = [];
        $covered = [];

        foreach (Paths::intersect($locks, $manifests) as $directory) {
            $rel = ltrim($directory, '/');
            if ('' !== $rel) {
                $rel .= '/';
            }

            // pnpm before package.json, so a root using both reports its
            // pnpm-workspace.yaml findings first.
            $patterns = [];
            $declared = false;

            if (isset($keptSet[$rel.'pnpm-workspace.yaml'])) {
                $body = $blobs->readBlob($rel.'pnpm-workspace.yaml');
                if (null !== $body) {
                    $declared = true;
                    $patterns = array_merge($patterns, self::pnpmPatterns($body, $directory, $reporter));
                }
            }

            [$npmPatterns, $npmDeclared] = self::npmPatterns($blobs, $rel, $directory, $reporter);
            $patterns = array_merge($patterns, $npmPatterns);
            $declared = $declared || $npmDeclared;

            if (!$declared) {
                continue;
            }
            $roots[] = $directory;
            if ([] === $patterns) {
                continue;
            }

            $set = PatternSet::build($directory, $patterns, $reporter->note(...));
            foreach ($set->expand($manifests) as $candidate) {
                // A root never covers itself.
                if ($candidate !== $directory) {
                    $covered[] = $candidate;
                }
            }
        }

        $roots = Paths::sortedUnique($roots);
        $covered = Paths::sortedUnique($covered);

        $pairs = [];
        foreach ($roots as $directory) {
            $pairs[] = new Pair(Ecosystem::Npm, $directory, PairKind::Root);
        }
        // Lockfiles no workspace covers, minus the roots already emitted.
        foreach (Paths::subtract(Paths::subtract($locks, $covered), $roots) as $directory) {
            $pairs[] = new Pair(Ecosystem::Npm, $directory, PairKind::Lock);
        }

        // A covered package with its own lockfile: hoisted installs ignore
        // it, and PRs against it would churn a file CI never reads.
        $reporter->noteGroup(
            Paths::subtract(Paths::intersect($locks, $covered), $roots),
            'with a lockfile shadowed by the workspace covering them — hoisted installs ignore those, so no entry was emitted:',
        );

        // A manifest nobody covers and with no lockfile of its own.
        $reporter->noteGroup(
            Paths::subtract(Paths::subtract($manifests, $locks), $covered),
            'with a package.json but no lockfile and no workspace covering them — no entry was emitted:',
        );

        return $pairs;
    }

    /**
     * A package.json's workspace patterns, in both shapes yarn and npm
     * accept: the plain array, and the yarn v1 object form
     * `{"packages": [...], "nohoist": [...]}`.
     *
     * Decoding to objects rather than associative arrays is deliberate. It is
     * what keeps a JSON array distinguishable from a JSON object, which is
     * the whole point of the shape switch below; decoding to arrays collapses
     * the two and gets `{}` versus `[]` wrong.
     *
     * @return array{list<string>, bool}
     */
    private static function npmPatterns(BlobReader $blobs, string $rel, string $directory, Reporter $reporter): array
    {
        $body = $blobs->readBlob($rel.'package.json');
        if (null === $body) {
            return [[], false];
        }

        $manifest = json_decode($body, false);
        if (!$manifest instanceof \stdClass) {
            // Unparseable JSON, or a non-object top level, reads as "no
            // workspaces declared", exactly as the silenced original did.
            return [[], false];
        }

        $workspaces = $manifest->workspaces ?? null;

        if (null === $workspaces) {
            return [[], false];
        }
        if (is_array($workspaces)) {
            return [self::stringsOf($workspaces), true];
        }
        if ($workspaces instanceof \stdClass) {
            $packages = $workspaces->packages ?? null;

            return [is_array($packages) ? self::stringsOf($packages) : [], true];
        }

        // Treating an unrecognised shape as "no workspaces" is what produces
        // per-package entry spam, so say so rather than guess.
        $reporter->note(sprintf(
            "package.json at %s declares 'workspaces' as a %s, which is not a shape we recognise — treating it as covering nothing",
            $directory,
            self::jsonTypeName($workspaces),
        ));

        return [[], true];
    }

    /**
     * A pnpm-workspace.yaml's packages list.
     *
     * "Could not parse it" and "it declares nothing" are different facts, and
     * conflating them sends people looking for a missing key that is right
     * there. WooCommerce's file is the live example: it declares `packages:`
     * on line 72, and every YAML parser rejects the file over a tab on line 4.
     *
     * @return list<string>
     */
    private static function pnpmPatterns(string $body, string $directory, Reporter $reporter): array
    {
        try {
            $document = Yaml::parse($body);
        } catch (ParseException) {
            $reporter->note(sprintf(
                'cannot parse pnpm-workspace.yaml at %s — treating it as covering nothing (a tab character in the indentation is the usual cause)',
                $directory,
            ));

            return [];
        }

        $patterns = [];
        if (is_array($document) && is_array($document['packages'] ?? null)) {
            $patterns = self::stringsOf($document['packages']);
        }

        if ([] === $patterns) {
            $reporter->note(sprintf(
                "pnpm-workspace.yaml at %s declares no 'packages:' — treating it as covering nothing",
                $directory,
            ));
        }

        return $patterns;
    }

    /**
     * Keep the non-empty string members of a decoded list, skipping anything
     * else the way jq's `select(type == "string")` did.
     *
     * @param array<mixed> $list
     *
     * @return list<string>
     */
    private static function stringsOf(array $list): array
    {
        $out = [];
        foreach ($list as $value) {
            if (is_string($value) && '' !== $value) {
                $out[] = $value;
            }
        }

        return $out;
    }

    /**
     * Name a decoded JSON value the way jq's `type` builtin does — the note
     * text is part of the report contract.
     */
    private static function jsonTypeName(mixed $value): string
    {
        return match (true) {
            is_string($value) => 'string',
            is_bool($value) => 'boolean',
            is_int($value), is_float($value) => 'number',
            default => 'unknown',
        };
    }
}
