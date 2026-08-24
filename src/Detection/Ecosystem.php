<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * The package ecosystems this tool maps.
 *
 * The backing values are the strings Dependabot writes in
 * `package-ecosystem:`, and they are also sort keys and report text, so they
 * are a contract with the golden transcripts and are not free to drift.
 */
enum Ecosystem: string
{
    case Npm = 'npm';
    case Composer = 'composer';
    case GithubActions = 'github-actions';
}
