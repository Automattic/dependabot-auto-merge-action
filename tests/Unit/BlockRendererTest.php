<?php

declare(strict_types=1);

use Automattic\DependabotDirectories\Config\BlockRenderer;
use Automattic\DependabotDirectories\Detection\Block;
use Automattic\DependabotDirectories\Detection\Ecosystem;

it('renders the security-only default', function () {
    $got = BlockRenderer::render(new Block(Ecosystem::Composer, '/'), '  ', '    ', false);

    expect($got)->toBe(<<<'YAML'
          - package-ecosystem: "composer"
            directory: "/"
            schedule:
              interval: "weekly"
              day: "monday"
            open-pull-requests-limit: 0
            cooldown:
              default-days: 7

        YAML);
});

it('renders a glob as a directories list', function () {
    $got = BlockRenderer::render(new Block(Ecosystem::Composer, '/plugins/*', true), '  ', '    ', false);

    expect($got)->toBe(<<<'YAML'
          - package-ecosystem: "composer"
            directories:
              - "/plugins/*"
            schedule:
              interval: "weekly"
              day: "monday"
            open-pull-requests-limit: 0
            cooldown:
              default-days: 7

        YAML);
});

it('renders the full house template for version updates', function () {
    $got = BlockRenderer::render(new Block(Ecosystem::Npm, '/'), '  ', '    ', true);

    expect($got)->toBe(<<<'YAML'
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
              day: "monday"
            open-pull-requests-limit: 10
            groups:
              npm-minor-patch:
                patterns:
                  - "*"
                update-types:
                  - "minor"
                  - "patch"
              npm-major:
                patterns:
                  - "*"
                update-types:
                  - "major"
            cooldown:
              default-days: 7

        YAML);
});

it('honours the detected indentation', function () {
    $got = BlockRenderer::render(new Block(Ecosystem::Composer, '/'), '    ', '      ', false);

    expect($got)->toContain("    - package-ecosystem: \"composer\"\n")
        ->toContain("      directory: \"/\"\n");
});
