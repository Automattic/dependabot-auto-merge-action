<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Detection;

/**
 * Why a pair was emitted. Grouping reads it: workspace roots and the
 * github-actions entry never fold into a glob, because a root lockfile
 * already absorbs packages added later and a glob has nothing to gain.
 */
enum PairKind: string
{
    /** A directory whose manifest declares workspaces. */
    case Root = 'root';

    /** A plain directory holding a manifest and its lockfile. */
    case Lock = 'lock';

    /** The repository-root github-actions entry. */
    case Actions = 'actions';
}
