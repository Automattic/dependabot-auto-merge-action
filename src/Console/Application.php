<?php

declare(strict_types=1);

namespace Automattic\DependabotDirectories\Console;

use Automattic\DependabotDirectories\Exception\FatalException;
use Automattic\DependabotDirectories\Exception\UsageException;
use Automattic\DependabotDirectories\Pipeline;
use Automattic\DependabotDirectories\Source\Execer;
use Symfony\Component\Console\Application as SymfonyApplication;
use Symfony\Component\Console\Exception\ExceptionInterface as ConsoleException;
use Symfony\Component\Console\Helper\DescriptorHelper;
use Symfony\Component\Console\Input\ArgvInput;
use Symfony\Component\Console\Input\InputDefinition;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Output\StreamOutput;

/**
 * The process boundary.
 *
 * Exit codes are the contract: 0 clean, 1 problems, 2 usage or environment
 * errors. Symfony Console would swallow an exception into a rendered block
 * and exit 1, so exceptions are caught here and the codes are returned rather
 * than exited on — that is what lets the tests call {@see self::run} directly
 * with in-memory streams and observe both the bytes and the code.
 */
final class Application extends SymfonyApplication
{
    public const NAME = 'dependabot-directories';
    public const VERSION = '1.0.0';

    public function __construct()
    {
        parent::__construct(self::NAME, self::VERSION);

        $this->setCatchExceptions(false);
        $this->setAutoExit(false);
    }

    /**
     * Trim the global options to just `--help`.
     *
     * Symfony's defaults (`--quiet`, `--verbose`, `--ansi`, `--version`,
     * `--no-interaction`) mean nothing to a tool whose entire output is a
     * report written straight to a stream, and listing them in the help text
     * would advertise behaviour that does not exist.
     */
    protected function getDefaultInputDefinition(): InputDefinition
    {
        return new InputDefinition([
            new InputOption('help', 'h', InputOption::VALUE_NONE, 'Display help for the command'),
        ]);
    }

    /**
     * Register no default commands.
     *
     * Symfony's `list`, `help`, `completion` and `_complete` are dead weight
     * for a tool that is one command, and one of them is actively harmful:
     * DumpCompletionCommand scans a Resources/ directory at construction
     * time, which throws inside a PHAR that packages only *.php. Help is
     * rendered through the DescriptorHelper below instead.
     *
     * @return list<\Symfony\Component\Console\Command\Command>
     */
    protected function getDefaultCommands(): array
    {
        return [];
    }

    /**
     * Execute the tool.
     *
     * @param list<string> $argv   the arguments after the program name
     * @param resource     $out
     * @param resource     $errOut
     */
    public static function execute(array $argv, $out, $errOut, ?Execer $exec = null): int
    {
        $application = new self();
        $command = new DetectDirectoriesCommand();
        $application->addCommand($command);
        $application->setDefaultCommand(self::NAME, true);

        $input = new ArgvInput(array_merge([self::NAME], $argv));

        if ($input->hasParameterOption(['--help', '-h'], true)) {
            self::describe($command, $out);

            return 0;
        }

        try {
            $command->mergeApplicationDefinition();
            $input->bind($command->getDefinition());
            $input->validate();
            $options = DetectDirectoriesCommand::gather($input);
        } catch (FatalException $e) {
            // The command line was fine, the environment is not. The message
            // stands alone; usage text would be misleading.
            fwrite($errOut, sprintf("error: %s\n", $e->getMessage()));

            return 2;
        } catch (UsageException|ConsoleException $e) {
            // The usage text accompanies the error, so it belongs on the same
            // stream as the error.
            fwrite($errOut, sprintf("error: %s\n\n", $e->getMessage()));
            self::describe($command, $errOut);

            return 2;
        }

        return Pipeline::run($options, $out, $errOut, $exec);
    }

    /**
     * @param resource $stream
     */
    private static function describe(DetectDirectoriesCommand $command, $stream): void
    {
        $command->mergeApplicationDefinition();
        (new DescriptorHelper())->describe(
            new StreamOutput($stream, OutputInterface::VERBOSITY_NORMAL, false),
            $command,
        );
    }
}
