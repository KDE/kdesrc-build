package ksb::BuildSystem 0.30;

# Base module for the various build systems, includes built-in implementations of
# generic functions and supports hooks for subclasses to provide needed detailed
# functionality.

use ksb;

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;
use ksb::StatusView;

use List::Util qw(max min first);

sub new
{
    my ($class, $module) = @_;
    my $self = bless { module => $module }, $class;

    # This is simply the 'default' build system at this point, so options
    # intended for unique/bespoke build systems should be stripped from global
    # before being applied to a module.
    if ($class ne 'ksb::BuildSystem::KDECMake') {
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

# Returns a hashref holding the resource constraints to try to apply during the
# build.  Buildsystems should apply the constraints they understand before
# running the build command.
# {
#   'compute' => OPTIONAL, if set a max number of CPU cores to use, or '1' if unable to tell
#   # no other constraints supported
# }
sub buildConstraints
{
    my $self = shift;
    my $cores = $self->module()->getOption('num-cores');

    # If set to empty, accept user's decision
    return { } unless $cores;

    my $max_cores = eval {
        chomp(my @out = ksb::Util::filter_program_output(undef, 'nproc'));
        max(1, int $out[0]);
    } // 1;

    # On multi-core systems, reduce number of cores by one to leave at least one
    # core available for non-compilation activities and avoid making the machine
    # unresponsive
    $cores = $max_cores - 1
        if $cores eq 'auto' and $max_cores > 1;

    # If user sets cores to something silly, set it to a failsafe.
    $cores = 4
        if (int $cores) <= 0;

    # Finally, if user sets cores above what's possible, use 'auto' logic
    # instead. But let user max out their CPU if they ask specifically for
    # that.
    $cores = min($max_cores - 1, $cores)
        if $cores > $max_cores;

    return { compute => $cores };
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

# Return value style: hashref to build results object (see safe_make)
sub buildInternal
{
    my $self = shift;
    my $optionsName = shift // 'make-options';

    # I removed the default value to num-cores but forgot to account for old
    # configs that needed a value for num-cores, as this is handled
    # automatically below. So filter out the naked -j for configs where what
    # previously might have been "-j 4" is now only "-j". See
    # https://invent.kde.org/sdk/kdesrc-build/-/issues/78
    my $optionVal = $self->module()->getOption($optionsName);

    # Look for -j being present but not being followed by digits
    if ($optionVal =~ /(^|[^a-zA-Z0-9_])-j$/ || $optionVal =~ /(^|[^a-zA-Z_])-j(?! *[0-9]+)/) {
        warning(" y[b[*] Removing empty -j setting during build for y[b[" . $self->module() . "]");
        $optionVal =~ s/(^|[^a-zA-Z_])-j */$1/; # Remove the -j entirely for now
    }

    my @makeOptions = split(' ', $optionVal);

    # Look for CPU core limits to enforce. This handles core limits for all
    # current build systems.
    my $buildConstraints = $self->buildConstraints();
    my $numCores = $buildConstraints->{compute};

    if ($numCores) {
        # Prepend parallelism arg to allow user settings to override
        unshift @makeOptions, '-j', $numCores;
    }

    return $self->safe_make({
        target => undef,
        message => 'Compiling...',
        'make-options' => \@makeOptions,
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

    info ("\ty[$module] does not support the b[run-tests] option");
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
        info ("\tRemoving files in build directory for g[$module]");

        # This variant of log_command runs the sub prune_under_directory($builddir)
        # in a forked child, so that we can log its output.
        if (log_command($module, 'clean-builddir', [ 'kdesrc-build', 'ksb::Util::prune_under_directory', $builddir ]))
        {
            error (" r[b[*]\tFailed to clean build directory.  Verify the permissions are correct.");
            return 0; # False for this function.
        }

        # Let users know we're done so they don't wonder why rm -rf is taking so
        # long and oh yeah, why's my HD so active?...
        info ("\tOld build system cleaned, starting new build system.");
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
            ['kdesrc-build', 'ksb::Util::safe_lndir', $srcdir, $builddir]))
    {
        error ("\tUnable to setup symlinked build directory for r[$module]!!");
        return 0;
    }

    return 1;
}

# Subroutine to run the build command with the arguments given by the
# passed hash, laid out as:
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
# Returns a hashref:
# {
#   was_successful => $bool, (if successful)
#   warnings       => $int,  (num of warnings, in [0..INT_MAX])
#   work_done      => $bool, (true if the make command had work to do, may be needlessly set)
# }
sub safe_make($self, $optsRef)
{
    assert_isa($self, 'ksb::BuildSystem');
    my $module = $self->module();

    my $commandToUse = $module->getOption('custom-build-command');
    my $buildCommand;
    my @buildCommandLine;

    # Check for custom user command. We support command line options being
    # passed to the command as well.
    if ($commandToUse) {
        ($buildCommand, @buildCommandLine) = split_quoted_on_whitespace($commandToUse);
        $commandToUse = $buildCommand; # Don't need whole cmdline in any errors.
        $buildCommand = absPathToExecutable($buildCommand);
    }
    else {
        # command line options passed in optsRef
        $commandToUse = $buildCommand = $self->defaultBuildCommand();
    }

    if (!$buildCommand) {
        error (" r[b[*] Unable to find the g[$commandToUse] executable!");
        return { was_successful => 0 };
    }

    # Make it prettier if pretending (Remove leading directories).
    $buildCommand =~ s{^/.*/}{} if pretending();

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

    my $logname = $optsRef->{logbase} // $optsRef->{logfile} // $optsRef->{target};

    my $builddir = $module->fullpath('build');
    $builddir =~ s/\/*$//; # Remove trailing /

    p_chdir ($builddir);

    return $self->_runBuildCommand($optsRef->{message}, $logname, \@args);
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
        note("\t$message");
        $resultRef->{was_successful} = (0 == log_command($module, $filename, $argRef));
        return $resultRef;
    }

    my $time = time;

    my $statusViewer = $ctx->statusViewer();
    $statusViewer->setStatus("\t$message");
    $statusViewer->update();

    # TODO More details
    my $warnings = 0;
    my $workDoneFlag = 1;

    # w00t.  Check out the closure!  Maks would be so proud.
    my $log_command_callback = sub ($input) {
        return if not defined $input;

        my ($percentage) = ($input =~ /^\[\s*([0-9]+)%]/);
        if ($percentage) {
            $statusViewer->setProgressTotal(100);
            $statusViewer->setProgress($percentage);
        }
        else {
            my ($x, $y) = ($input =~ /^\[([0-9]+)\/([0-9]+)] /);
            if ($x && $y) {
                # ninja-syntax
                $statusViewer->setProgressTotal($y);
                $statusViewer->setProgress($x);
            }
        }

        $workDoneFlag = 0 if $input =~ /^ninja: no work to do/;
        $warnings++ if $input =~ /warning: /;
    };

    my $resultCode = log_command($module, $filename, $argRef, {
            callback => $log_command_callback
        });

    $resultRef = {
        was_successful => $resultCode == 0,
        warnings       => $warnings,
        work_done      => $workDoneFlag,
    };

    # Cleanup TTY output.
    $time = prettify_seconds(time - $time);
    my $status = $resultRef->{was_successful} ? "g[b[succeeded]" : "r[b[failed]";
    $statusViewer->releaseTTY("\t$message $status (after $time)\n");

    if ($warnings) {
        my $count = ($warnings < 3  ) ? 1 :
                    ($warnings < 10 ) ? 2 :
                    ($warnings < 30 ) ? 3 : 4;
        my $msg = sprintf("%s b[y[$warnings] %s", '-' x $count, '-' x $count);
        note ("\tNote: $msg compile warnings");
        $self->{module}->setPersistentOption('last-compile-warnings', $warnings);
    }

    return $resultRef;
}

1;
