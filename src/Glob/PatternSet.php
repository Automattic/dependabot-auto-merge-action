<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Glob;

/**
 * A workspace's glob patterns, split into positive and negative matchers and
 * resolved against the workspace root.
 */
final readonly class PatternSet
{
    /**
     * @param list<string> $positive
     * @param list<string> $negative
     */
    private function __construct(
        private array $positive,
        private array $negative,
    ) {
    }

    /**
     * Resolve workspace patterns against $root.
     *
     * @param list<string>           $patterns
     * @param callable(string): void $note     receives one line per pattern using
     *                                         a character class, which this
     *                                         translation matches literally
     *                                         rather than as a class
     */
    public static function build(string $root, array $patterns, callable $note): self
    {
        $positive = [];
        $negative = [];
        $prefix = rtrim($root, '/');

        foreach ($patterns as $pattern) {
            if (str_starts_with($pattern, './')) {
                $pattern = substr($pattern, 2);
            }
            while (str_ends_with($pattern, '/') && strlen($pattern) > 1) {
                $pattern = substr($pattern, 0, -1);
            }
            if ('' === $pattern) {
                continue;
            }

            if (str_contains($pattern, '[')) {
                $note(sprintf("workspace pattern '%s' uses a character class, which is matched literally", $pattern));
            }

            $negated = str_starts_with($pattern, '!');
            if ($negated) {
                $pattern = substr($pattern, 1);
                if ('' === $pattern) {
                    continue;
                }
            }

            $compiled = GlobTranslator::toRegexp($prefix.'/'.ltrim($pattern, '/'));
            if ($negated) {
                $negative[] = $compiled;
            } else {
                $positive[] = $compiled;
            }
        }

        return new self($positive, $negative);
    }

    /**
     * The candidates matched by at least one positive pattern and no negative
     * one, preserving candidate order.
     *
     * No positive patterns means nothing is covered — a negation alone has
     * nothing to subtract from.
     *
     * @param list<string> $candidates
     *
     * @return list<string>
     */
    public function expand(array $candidates): array
    {
        if ([] === $this->positive) {
            return [];
        }

        $out = [];
        foreach ($candidates as $candidate) {
            foreach ($this->negative as $pattern) {
                if (GlobTranslator::matches($pattern, $candidate)) {
                    continue 2;
                }
            }
            foreach ($this->positive as $pattern) {
                if (GlobTranslator::matches($pattern, $candidate)) {
                    $out[] = $candidate;
                    continue 2;
                }
            }
        }

        return $out;
    }
}
