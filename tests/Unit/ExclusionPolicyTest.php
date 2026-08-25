<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Detection\ExclusionPolicy;

it('drops hard exclusions silently', function () {
    $result = ExclusionPolicy::split([
        'package.json',
        'node_modules/left-pad/package.json',
        'a/vendor/pkg/composer.json',
        '.git/config',
        'bower_components/x/bower.json',
    ], []);

    expect($result->kept)->toBe(['package.json']);
    expect($result->soft)->toBe([]);
});

it('lets a file named like an excluded directory survive', function () {
    // The exclusion names directories, so a plain file called vendor is not
    // under a vendor/ directory.
    $result = ExclusionPolicy::split(['vendor', 'docs/build'], []);

    expect($result->kept)->toBe(['vendor', 'docs/build']);
});

it('returns soft exclusions separately', function () {
    $result = ExclusionPolicy::split([
        'package.json',
        'examples/demo/package.json',
        'dist/package.json',
        'docs/fixtures/tree/package.json',
    ], []);

    expect($result->kept)->toBe(['package.json']);
    expect($result->soft)->toBe([
        'examples/demo/package.json',
        'dist/package.json',
        'docs/fixtures/tree/package.json',
    ]);
});

it('readmits a soft-excluded name with include', function () {
    $result = ExclusionPolicy::split([
        'examples/demo/package.json',
        'dist/package.json',
    ], ['examples']);

    expect($result->kept)->toBe(['examples/demo/package.json']);
    expect($result->soft)->toBe(['dist/package.json']);
});

it('never readmits a hard exclusion', function () {
    $result = ExclusionPolicy::split(['node_modules/x/package.json'], ['node_modules']);

    expect($result->kept)->toBe([]);
});

it('treats example and examples as distinct names', function () {
    // Both are on the soft list; --include of one must not readmit the other.
    $result = ExclusionPolicy::split([
        'example/package.json',
        'examples/package.json',
    ], ['example']);

    expect($result->kept)->toBe(['example/package.json']);
    expect($result->soft)->toBe(['examples/package.json']);
});

it('matches a whole path segment, not a prefix', function () {
    // "distribution" contains "dist" but is not the segment "dist".
    $result = ExclusionPolicy::split(['distribution/package.json'], []);

    expect($result->kept)->toBe(['distribution/package.json']);
    expect($result->soft)->toBe([]);
});
