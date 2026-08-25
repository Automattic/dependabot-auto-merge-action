<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * One dependabot.yml entry to render: a singular directory, or a parent glob
 * standing for its members.
 */
final readonly class Block
{
    /**
     * @param list<string> $members the directories a glob stands for, so the
     *                              coverage pass can degrade it to singular
     *                              entries when only some are already mapped
     */
    public function __construct(
        public Ecosystem $ecosystem,
        public string $directory,
        public bool $isGlob = false,
        public array $members = [],
    ) {
    }

    /**
     * Reproduce the original ordering, which sorted joined `eco|dir|glob`
     * records as whole strings.
     *
     * Comparing the fields one at a time is NOT the same ordering: '|' sorts
     * after every letter, so "npm|/packages/legacy|0" comes before "npm|/|0".
     */
    public function sortKey(): string
    {
        return $this->ecosystem->value.'|'.$this->directory.'|'.($this->isGlob ? '1' : '0');
    }

    /**
     * Order by sort key and drop duplicates.
     *
     * @param list<self> $blocks
     *
     * @return list<self>
     */
    public static function sortUnique(array $blocks): array
    {
        usort($blocks, static fn (self $a, self $b): int => strcmp($a->sortKey(), $b->sortKey()));

        $out = [];
        foreach ($blocks as $i => $block) {
            if (0 === $i || $block->sortKey() !== $blocks[$i - 1]->sortKey()) {
                $out[] = $block;
            }
        }

        return $out;
    }
}
