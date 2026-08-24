<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Glob;

/**
 * Translate a workspace glob into an anchored regular expression.
 *
 * There is no working tree to glob against — only a path list — so the
 * pattern has to become a matcher over strings.
 *
 * The compiled pattern deliberately carries no `u` modifier, and the
 * translation walks bytes rather than code points. Both choices are the same
 * choice: no UTF-8 continuation byte can ever equal `*`, `?` or `/`, so
 * `[^/]*` matches exactly one path segment whether it is read as bytes or as
 * runes, and `preg_quote` leaves bytes above 0x7F alone. Adding `u` would buy
 * nothing and would make `preg_match` return `false` on any path git happens
 * to hold that is not valid UTF-8 — a silent "no match" that would
 * under-report coverage rather than fail loudly.
 */
final class GlobTranslator
{
    // The translation, by example:
    //
    //   packages/*    ->  ^packages/[^/]*$
    //   packages/**   ->  ^packages/.*$
    //   a/**/b        ->  ^a/(.*/)?b$      (matches a/b as well as a/z/b)

    /**
     * Compile a glob into an anchored, delimited PCRE pattern.
     */
    public static function toRegexp(string $glob): string
    {
        $out = '';
        $length = strlen($glob);

        for ($i = 0; $i < $length; ++$i) {
            $char = $glob[$i];

            if ('*' === $char) {
                if ($i + 1 < $length && '*' === $glob[$i + 1]) {
                    ++$i;
                    if ($i + 1 < $length && '/' === $glob[$i + 1]) {
                        // The zero-segment case is the one everyone gets
                        // wrong: a/**/b must match a/b.
                        $out .= '(.*/)?';
                        ++$i;
                    } else {
                        $out .= '.*';
                    }
                    continue;
                }
                $out .= '[^/]*';
                continue;
            }

            if ('?' === $char) {
                $out .= '[^/]';
                continue;
            }

            $out .= preg_quote($char, '#');
        }

        return '#^'.$out.'$#';
    }

    /**
     * Match a compiled pattern against a subject.
     *
     * `preg_match` returns `false` on a PCRE failure rather than a match
     * result, and `false` is falsy, so letting it flow on would read as "no
     * match" and silently drop a directory from coverage. Turn it into a loud
     * failure instead.
     *
     * A blown backtrack limit is the plausible cause, since `**` compiles to
     * an unbounded wildcard. Realistic path depths do not come near the
     * default limit, so this guards a class of failure rather than fixing an
     * observed one.
     *
     * @throws \RuntimeException on any PCRE error
     */
    public static function matches(string $pattern, string $subject): bool
    {
        $result = preg_match($pattern, $subject);

        if (false === $result) {
            throw new \RuntimeException(sprintf(
                'matching %s against %s failed: %s',
                $pattern,
                $subject,
                preg_last_error_msg(),
            ));
        }

        return 1 === $result;
    }
}
