<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Source;

/**
 * Percent-encoding for path segments sent to the API.
 */
final class Uri
{
    /**
     * Percent-encode every byte outside RFC 3986's unreserved set.
     *
     * `rawurlencode` leaves exactly `A-Za-z0-9-_.~` alone, which is the same
     * set jq's `@uri` preserves, so the bytes sent for a given path match
     * what the original implementation sent. `urlencode` is NOT a substitute:
     * it renders a space as `+`.
     */
    public static function escape(string $value): string
    {
        return rawurlencode($value);
    }
}
