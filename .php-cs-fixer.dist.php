<?php

declare(strict_types=1);

$finder = PhpCsFixer\Finder::create()
    ->in([__DIR__.'/src', __DIR__.'/tests'])
    ->append([__DIR__.'/bin/dependabot-directories']);

return (new PhpCsFixer\Config())
    ->setRiskyAllowed(true)
    ->setRules([
        '@PSR12' => true,
        '@PSR12:risky' => true,
        '@Symfony' => true,
        '@Symfony:risky' => true,
        '@PHP82Migration' => true,
        'declare_strict_types' => true,
        'global_namespace_import' => ['import_classes' => false, 'import_constants' => false, 'import_functions' => false],
        // Pest binds every test closure to a TestCase, and a static closure
        // cannot be bound. @Symfony would make the ones not touching $this
        // static and break the suite.
        'static_lambda' => false,
        // @Symfony:risky prefixes every global call with a backslash. Symfony
        // core does it for the opcode; here it would put a \ in front of
        // several hundred sprintf/count calls and read as noise.
        'native_function_invocation' => false,
        'native_constant_invocation' => false,
        // Keep the explicit binary mode. This tool's whole contract is
        // byte-exact output, and 'b' is not a no-op everywhere.
        'fopen_flags' => ['b_mode' => true],
        // Keep the author's line breaks. Long report messages read better
        // broken across lines than collapsed past the margin.
        'method_argument_space' => ['on_multiline' => 'ignore'],
        // Exception messages here are full sentences naming the fix. Forcing
        // the throw onto one line pushes them well past the margin.
        'single_line_throw' => false,
        // The explanatory comments in this codebase are prose about why, not
        // type annotations; @Symfony would rewrite them into docblocks.
        'phpdoc_to_comment' => false,
    ])
    ->setFinder($finder);
