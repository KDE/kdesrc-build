package ksb::BuildSystem 0.30;

# Base module for the various build systems, includes built-in implementations of
# generic functions and supports hooks for subclasses to provide needed detailed
# functionality.

use strict;
use warnings;
use 5.014;

use ksb::BuildException;
use ksb::Debug 0.30;
use ksb::Util;
use ksb::StatusView;

use List::Util qw(first);

sub new
{
    my ($class, $module) = @_;
    my $self = bless { module => $module }, $class;

    # This is simply the 'default' build system at this point, also used for
    # KF5.
    if ($class ne 'ksb::BuildSystem::CMake') {
        _maskGlobalBuildSystemOptions($self);
    }

    return $self;
}

# Removes or masks global build system-related options, so that they aren't
# accidentally picked up for use with our non-default build system.
# Module-specific options are left intact.
sub _maskGlobalBuildSystemOptions
{
    my $self = shift;
    my $module = $self->module();
    my $ctx = $module->buildContext();
    my @buildSystemOptions = qw(
        cmake-options cmake-generator configure-flags custom-build-command cxxflags
        make-options run-tests use-clean-install
    );

    for my $opt (@buildSystemOptions) {
        # If an option is present, and not set at module-level, it must be
        # global. Can't use getOption() method due to recursion.
        if ($ctx->{options}->{$opt} && !$module->{options}->{$opt}) {
            $module->{options}->{$opt} = '';
        }
    }
}

#
# Check if a (custom) toolchain is defined.
# If a build system is configured with a (custom) toolchain, it is assumed that
#
#  a: the user knows what they are doing, or
#  b: they are using an SDK that knows what it is about
#
# In either case, kdesrc-build will avoid touching the environment variables to
# give the custom configuration maximum 'power' (including foot shooting power).
#
sub hasToolchain
{
    my $self = shift;
    return 0;
}

sub module
{
    my $self = shift;
    return $self->{module};
}

# Subroutine to determine if a given module needs to have the build system
# recreated from scratch.
# If so, it returns a non empty string
sub needsRefreshed
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');
    my $confFileKey = $self->configuredModuleFileName();

    if (not -e "$builddir") {
       return "the build directory doesn't exist";
   }
   if (-e "$builddir/.refresh-me") {
       return "the last configure failed"; # see Module.pm
   }
   if ($module->getOption("refresh-build")) {
       return "the option refresh-build was set";
   }
   if (not -e "$builddir/$confFileKey") {
       return "$builddir/$confFileKey is missing";
   }

    return "";
}

# Called by the module being built before it runs its build/install process. Should
# setup any needed environment variables, build context settings, etc., in preparation
# for the build and install phases. Should take `hasToolchain()` into account here.
sub prepareModuleBuildEnvironment
{
    my ($self, $ctx, $module, $prefix) = @_;
}

# Returns true if the module should have make install run in order to be
# used, or false if installation is not required or possible.
sub needsInstalled
{
    return 1;
}

# This should return a list of executable names that must be present to
# even bother attempting to use this build system. An empty list should be
# returned if there's no required programs.
sub requiredPrograms
{
    return;
}

sub name
{
    return 'generic';
}

# Returns a list of possible build commands to run, any one of which should
# be supported by the build system.
sub buildCommands
{
    # Non Linux systems can sometimes fail to build when GNU Make would work,
    # so prefer GNU Make if present, otherwise try regular make.
    return 'gmake', 'make';
}

sub defaultBuildCommand
{
    my $self = shift;
    # Convert the path to an absolute path since I've encountered a sudo
    # that is apparently unable to guess.  Maybe it's better that it
    # doesn't guess anyways from a security point-of-view.
    my $buildCommand = first { absPathToExecutable($_) } $self->buildCommands();
    return $buildCommand;
}

# Return value style: hashref {was_successful => bool, warnings => int, ...}
sub buildInternal
{
    my $self = shift;
    my $optionsName = shift // 'make-options';

    return $self->safe_make({
        target => undef,
        message => 'Compiling...',
        'make-options' => [
            split(' ', $self->module()->getOption($optionsName)),
        ],
        logbase => 'build',
    });
}

# Return value style: boolean
sub configureInternal
{
    # It is possible to make it here if there's no source dir and if we're
    # pretending. If we're not actually pretending then this should be a
    # bug...
    return 1 if pretending();

    croak_internal('We were not supposed to get to this point...');
}

# Returns name of file that should exist (relative to the module's build directory)
# if the module has been configured.
sub configuredModuleFileName
{
    my $self = shift;
    return 'Makefile';
}

# Runs the testsuite for the given module.
# Returns true if a testsuite is present and all tests passed, false otherwise.
sub runTestsuite
{
    my $self = shift;
    my $module = $self->module();

    whisper ("\ty[$module] does not support the b[run-tests] option");
    return 0;
}

# Used to install a module (that has already been built, tested, etc.)
# All options passed are prefixed to the eventual command to be run.
# Returns boolean false if unable to install, true otherwise.
sub installInternal
{
    my $self = shift;
    my $module = $self->module();
    my @cmdPrefix = @_;

    return $self->safe_make ({
            target => 'install',
            message => 'Installing..',
            'prefix-options' => [@cmdPrefix],
           })->{was_successful};
}

# Used to uninstall a previously installed module.
# All options passed are prefixed to the eventual command to be run.
# Returns boolean false if unable to uninstall, true otherwise.
sub uninstallInternal
{
    my $self = shift;
    my $module = $self->module();
    my @cmdPrefix = @_;

    return $self->safe_make ({
            target => 'uninstall',
            message => "Uninstalling g[$module]",
            'prefix-options' => [@cmdPrefix],
           })->{was_successful};
}

# Subroutine to clean the build system for the given module.  Works by
# recursively deleting the directory and then recreating it.
# Returns 0 for failure, non-zero for success.
sub cleanBuildSystem
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my $builddir = $module->fullpath('build');

    if (pretending())
    {
        pretend ("\tWould have cleaned build system for g[$module]");
        return 1;
    }

    # Use an existing directory
    if (-e $builddir && $builddir ne $srcdir)
    {
        whisper ("\tCleaning out build directory");

        # This variant of log_command runs the sub prune_under_directory($builddir)
        # in a forked child, so that we can log its output.
        if (log_command($module, 'clean-builddir', [ 'kdesrc-build', 'main::prune_under_directory', $builddir ]))
        {
            error (" r[b[*]\tFailed to clean build directory.  Verify the permissions are correct.");
            return 0; # False for this function.
        }

        # Let users know we're done so they don't wonder why rm -rf is taking so
        # long and oh yeah, why's my HD so active?...
        whisper ("\tOld build system cleaned, starting new build system.");
    }
    # or create the directory
    elsif (!super_mkdir ($builddir))
    {
        error ("\tUnable to create directory r[$builddir].");
        return 0;
    }

    return 1;
}

sub needsBuilddirHack
{
    return 0; # By default all build systems are assumed to be sane
}

# Return convention: boolean
sub createBuildSystem
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');
    my $srcdir   = $module->fullpath('source');

    if (! -e "$builddir" && !super_mkdir("$builddir"))
    {
        error ("\tUnable to create build directory for r[$module]!!");
        return 0;
    }

    if ($builddir ne $srcdir && $self->needsBuilddirHack() && 0 != log_command($module, 'lndir',
            ['kdesrc-build', 'main::safe_lndir', $srcdir, $builddir]))
    {
        error ("\tUnable to setup symlinked build directory for r[$module]!!");
        return 0;
    }

    return 1;
}

# Subroutine to run the build command with the arguments given by the
# passed hash.
#
# Due to the various ways the build command is called by this script, it is
# required to pass customization options in a hash:
# {
#    target         => undef, or a valid build target e.g. 'install',
#    message        => 'Compiling.../Installing.../etc.'
#    make-options   => [ list of command line arguments to pass to make. See
#                        make-options ],
#    prefix-options => [ list of command line arguments to prefix *before* the
#                        make command, used for make-install-prefix support for
#                        e.g. sudo ],
#    logbase        => 'base-log-filename',
# }
#
# target and message are required. logbase is required if target is left
# undefined, but otherwise defaults to the same value as target.
#
# Note that the make command is based on the results of the 'buildCommands'
# subroutine which should be overridden if necessary by subclasses. Each
# command should be the command name (i.e. no path). The user may override
# the command used (for build only) by using the 'custom-build-command'
# option.
#
# The first command name found which resolves to an executable on the
# system will be used, if no command this function will fail.
#
# The first argument should be the ksb::Module object to be made.
# The second argument should be the reference to the hash described above.
#
# Returns a hashref:
# {
#   was_successful => $bool, (if successful)
# }
sub safe_make (@)
{
    my ($self, $optsRef) = @_;
    assert_isa($self, 'ksb::BuildSystem');
    my $module = $self->module();

    my $buildCommand = $self->defaultBuildCommand();
    my @buildCommandLine = $buildCommand;

    # Check for custom user command. We support command line options being
    # passed to the command as well.
    my $userCommand = $module->getOption('custom-build-command');
    if ($userCommand) {
        @buildCommandLine = split_quoted_on_whitespace($userCommand);
        $buildCommand = absPathToExecutable($buildCommandLine[0]);
    }

    if (!$buildCommand) {
        $buildCommand = $userCommand || $self->buildCommands();
        error (" r[b[*] Unable to find the g[$buildCommand] executable!");
        return { was_successful => 0 };
    }

    # Make it prettier if pretending (Remove leading directories).
    $buildCommand =~ s{^/.*/}{} if pretending();
    shift @buildCommandLine; # $buildCommand is already the first entry.

    # Simplify code by forcing lists to exist.
    $optsRef->{'prefix-options'} //= [ ];
    $optsRef->{'make-options'} //= [ ];

    my @prefixOpts = @{$optsRef->{'prefix-options'}};

    # If using sudo ensure that it doesn't wait on tty, but tries to read from
    # stdin (which should fail as we redirect that from /dev/null)
    if (@prefixOpts && $prefixOpts[0] eq 'sudo' && !grep { /^-S$/ } @prefixOpts)
    {
        splice (@prefixOpts, 1, 0, '-S'); # Add -S right after 'sudo'
    }

    # Assemble arguments
    my @args = (@prefixOpts, $buildCommand, @buildCommandLine);
    push @args, $optsRef->{target} if $optsRef->{target};
    push @args, @{$optsRef->{'make-options'}};

    # Will be output by _runBuildCommand
    my $buildMessage = $optsRef->{message};
    my $logname = $optsRef->{logbase} // $optsRef->{logfile} // $optsRef->{target};
    p_chdir ($module->fullpath('build'));

    return $self->_runBuildCommand($buildMessage, $logname, \@args);
}

# Subroutine to run make and process the build process output in order to
# provide completion updates.  This procedure takes the same arguments as
# log_command() (described here as well), except that the callback argument
# is not used.
#
# First parameter is the message to display to the user while the build
#   happens.
# Second parameter is the name of the log file to use (relative to the log
#   directory).
# Third parameter is a reference to an array with the command and its
#   arguments.  i.e. ['command', 'arg1', 'arg2']
#
# The return value is a hashref as defined by safe_make
sub _runBuildCommand
{
    my ($self, $message, $filename, $argRef) = @_;
    my $module = $self->module();
    my $resultRef = { was_successful => 0 };
    my $ctx = $module->buildContext();

    # There are situations when we don't want progress output:
    # 1. If we're not printing to a terminal.
    # 2. When we're debugging (we'd interfere with debugging output).
    if (! -t STDERR || debugging())
    {
        $resultRef->{was_successful} = (0 == log_command($module, $filename, $argRef));
        return $resultRef;
    }

    # TODO More details
    my $warnings = 0;

    my $log_command_callback = sub {
        state $oldX = -1;
        state $oldY = -1;

        my $input = shift;
        return if not defined $input;

        $warnings++ if ($input =~ /warning: /);

        my ($x, $y);
        my ($percentage) = ($input =~ /^\[\s*([0-9]+)%]/);
        if ($percentage) {
            $x = int $percentage; $y = 100;
        }
        else {
            # ninja-syntax
            my ($newX, $newY) = ($input =~ /^\[([0-9]+)\/([0-9]+)] /);
            return unless ($newX && $newY);

            ($x, $y) = (int $newX, int $newY);
        }

        if ($x != $oldX || $y != $oldY) {
            ksb::Debug::reportProgressToParent($module, $x, $y);
        }
    };

    $resultRef->{was_successful} =
        (0 == log_command($module, $filename, $argRef, {
            callback => $log_command_callback
        }));

    $resultRef->{warnings} = $warnings;

    # TODO: Install phase can also cause warnings. This persistent option stuff
    # should probably be done by the calling code which can intelligently
    # decide whether to sum up all warnings, use only one phase, etc.
    if ($filename =~ /^build/) {
        $self->{module}->setPersistentOption('last-compile-warnings', $warnings);
    }

    return $resultRef;
}

1;
