<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Write;

/**
 * A JSON object rendered with its fields in declaration order and two-space
 * indentation — the same bytes `jq -n` produced, which the ported tests
 * assert on.
 *
 * Hand-rolled rather than `JSON_PRETTY_PRINT`, which indents with four
 * spaces. The per-value encoding drops PHP's default escaping of `/` and of
 * non-ASCII: the pull request body carries markdown links and em dashes, and
 * escaping either would change the bytes sent.
 */
final class Json
{
    private const FLAGS = \JSON_UNESCAPED_SLASHES | \JSON_UNESCAPED_UNICODE;

    /**
     * @param array<string, string> $fields
     */
    public static function object(array $fields): string
    {
        $out = "{\n";

        $last = array_key_last($fields);
        foreach ($fields as $key => $value) {
            $out .= sprintf('  %s: %s', self::encode($key), self::encode($value));
            $out .= $key === $last ? "\n" : ",\n";
        }

        return $out.'}';
    }

    private static function encode(string $value): string
    {
        return (string) json_encode($value, self::FLAGS);
    }
}
