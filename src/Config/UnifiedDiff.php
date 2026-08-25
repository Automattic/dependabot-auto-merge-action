<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Config;

use Automattic\DependabotDirectories\Source\Execer;

/**
 * Show current vs proposed through `diff -u`.
 *
 * Exec'ing the same external `diff` the original used is the point: matching
 * another implementation's hunk headers and context selection byte for byte
 * is exactly the risk this avoids.
 *
 * Both sides always end in one newline, since ProposalBuilder normalizes, so
 * diff never emits "\ No newline at end of file" markers. A missing current
 * diffs against /dev/null. Exit status 1 is "differences found"; any real
 * failure has already written to stderr.
 */
final class UnifiedDiff
{
    /**
     * @param resource $out
     * @param resource $errOut
     */
    public static function render(Proposal $proposal, Execer $exec, $out, $errOut): void
    {
        $dir = self::tempDir();
        if (null === $dir) {
            fwrite($errOut, "cannot create a temp dir for diff\n");

            return;
        }

        try {
            $currentPath = '/dev/null';
            if (null !== $proposal->current) {
                $currentPath = $dir.'/current.txt';
                if (false === @file_put_contents($currentPath, $proposal->current)) {
                    fwrite($errOut, "cannot write the diff input\n");

                    return;
                }
            }

            $proposedPath = $dir.'/proposed.txt';
            if (false === @file_put_contents($proposedPath, $proposal->proposed)) {
                fwrite($errOut, "cannot write the diff input\n");

                return;
            }

            $result = $exec->output([
                'diff', '-u',
                '--label', 'a/'.ConfigFile::PATH,
                '--label', 'b/'.ConfigFile::PATH,
                $currentPath, $proposedPath,
            ]);

            fwrite($out, $result->output);
        } finally {
            self::removeDir($dir);
        }
    }

    private static function tempDir(): ?string
    {
        $base = sys_get_temp_dir().'/dependabot-directories-'.bin2hex(random_bytes(8));

        return @mkdir($base, 0o700, true) ? $base : null;
    }

    private static function removeDir(string $dir): void
    {
        foreach (glob($dir.'/*') ?: [] as $file) {
            @unlink($file);
        }
        @rmdir($dir);
    }
}
