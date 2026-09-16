<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * One detected (ecosystem, directory) before grouping.
 */
final readonly class Pair
{
    public function __construct(
        public Ecosystem $ecosystem,
        public string $directory,
        public PairKind $kind,
    ) {
    }

    /**
     * The joined record the original `sort -u` ordered pairs by.
     */
    public function key(): string
    {
        return $this->ecosystem->value.'|'.$this->directory.'|'.$this->kind->value;
    }

    /**
     * Order by joined record and drop duplicates — the `sort -u` over the
     * pairs file.
     *
     * @param list<self> $pairs
     *
     * @return list<self>
     */
    public static function sortUnique(array $pairs): array
    {
        usort($pairs, static fn (self $a, self $b): int => strcmp($a->key(), $b->key()));

        $out = [];
        foreach ($pairs as $i => $pair) {
            if (0 === $i || $pair->key() !== $pairs[$i - 1]->key()) {
                $out[] = $pair;
            }
        }

        return $out;
    }
}
