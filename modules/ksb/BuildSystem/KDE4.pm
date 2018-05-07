package ksb::BuildSystem::KDE4 0.20;

# Class responsible for building KDE4 CMake-based modules.

use strict;
use warnings;
use 5.014;

use parent qw(ksb::BuildSystem);

use ksb::BuildContext 0.30;
use ksb::Debug;
use ksb::Util;

sub needsInstalled
{
    my $self = shift;

    return 0 if $self->name() eq 'kde-common'; # Vestigial
    return 1;
}

sub name
{
    return 'KDE';
}

# Called by the module being built before it runs its build/install process. Should
# setup any needed environment variables, build context settings, etc., in preparation
# for the build and install phases.
sub prepareModuleBuildEnvironment
{
    my ($self, $ctx, $module, $prefix) = @_;

    # Avoid moving /usr up in env vars
    if ($prefix ne '/usr') {
        $ctx->prependEnvironmentValue('CMAKE_PREFIX_PATH', $prefix);
        $ctx->prependEnvironmentValue('XDG_DATA_DIRS', "$prefix/share");
    }

    my $qtdir = $module->getOption('qtdir');
    if ($qtdir && $qtdir ne $prefix) {
        # Ensure we can find Qt5's own CMake modules
        $ctx->prependEnvironmentValue('CMAKE_MODULE_PATH', "$qtdir/lib/cmake");
    }
}

sub requiredPrograms
{
    return qw{cmake qmake};
}

sub configuredModuleFileName
{
    my $self = shift;
    return 'cmake_install.cmake';
}

sub runTestsuite
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::KDE4');
    my $module = $self->module();

    # Note that we do not run safe_make, which should really be called
    # safe_compile at this point.

    # Step 1: Ensure the tests are built, oh wait we already did that when we ran
    # CMake :)

    my $make_target = 'test';
    if ($module->getOption('run-tests') eq 'upload') {
        $make_target = 'Experimental';
    }

    info ("\tRunning test suite...");

    # Step 2: Run the tests.
    my $numTests = -1;
    my $countCallback = sub {
        if ($_ && /([0-9]+) tests failed out of/) {
            $numTests = $1;
        }
    };

    my $result = log_command($module, 'test-results',
                             [ 'make', $make_target ],
                             { callback => $countCallback, no_translate => 1});

    if ($result != 0) {
        my $logDir = $module->getLogDir();

        if ($numTests > 0) {
            warning ("\t$numTests tests failed for y[$module], consult $logDir/test-results.log for info");
        }
        else {
            warning ("\tSome tests failed for y[$module], consult $logDir/test-results.log for info");
        }

        return 0;
    }
    else {
        info ("\tAll tests ran successfully.");
    }

    return 1;
}

# Re-implementing the one in BuildSystem since in CMake we want to call
# make install/fast, so it only installs rather than building + installing
sub installInternal
{
    my $self = shift;
    my $module = $self->module();
    my $target = 'install/fast';
    my @cmdPrefix = @_;

    $target = 'install' if $module->getOption('custom-build-command');

    return $self->safe_make ({
            target => $target,
            logfile => 'install',
            message => 'Installing..',
            'prefix-options' => [@cmdPrefix],
            subdirs => [ split(' ', $module->getOption("checkout-only")) ],
           }) == 0;
}

sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::KDE4');
    my $module = $self->module();

    # Use cmake to create the build directory (sh script return value
    # semantics).
    if (_safe_run_cmake ($module))
    {
        error ("\tUnable to configure r[$module] with CMake!");
        return 0;
    }

    return 1;
}

### Internal package functions.

# Subroutine to run CMake to create the build directory for a module.
# CMake is not actually run if pretend mode is enabled.
#
# First parameter is the module to run cmake on.
# Return value is the shell return value as returned by log_command().  i.e.
# 0 for success, non-zero for failure.
sub _safe_run_cmake
{
    my $module = assert_isa(shift, 'ksb::Module');
    my $srcdir = $module->fullpath('source');
    my @commands = split_quoted_on_whitespace ($module->getOption('cmake-options'));

    # grep out empty fields
    @commands = grep {!/^\s*$/} @commands;

    # Add -DBUILD_foo=OFF options for the directories in do-not-compile.
    # This will only work if the CMakeLists.txt file uses macro_optional_add_subdirectory()
    my @masked_directories = split(' ', $module->getOption('do-not-compile'));
    push @commands, "-DBUILD_$_=OFF" foreach @masked_directories;

    # Get the user's CXXFLAGS, use them if specified and not already given
    # on the command line.
    my $cxxflags = $module->getOption('cxxflags');
    if ($cxxflags and not grep { /^-DCMAKE_CXX_FLAGS(:\w+)?=/ } @commands)
    {
        push @commands, "-DCMAKE_CXX_FLAGS:STRING=$cxxflags";
    }

    my $prefix = $module->installationPath();

    push @commands, "-DCMAKE_INSTALL_PREFIX=$prefix";

    # Add custom Qt to the prefix
    my $qtdir = $module->getOption('qtdir');
    if ($qtdir && $qtdir ne $prefix) {
        push @commands, "-DCMAKE_PREFIX_PATH=$qtdir";
    }

    if ($module->getOption('run-tests') &&
        !grep { /^\s*-DKDE4_BUILD_TESTS(:BOOL)?=(ON|TRUE|1)\s*$/ } (@commands)
       )
    {
        whisper ("Enabling tests");
        push @commands, "-DKDE4_BUILD_TESTS:BOOL=ON";

        # Also enable phonon tests.
        if ($module =~ /^phonon$/) {
            push @commands, "-DPHONON_BUILD_TESTS:BOOL=ON";
        }
    }

    if ($module->getOption('run-tests') eq 'upload')
    {
        whisper ("Enabling upload of test results");
        push @commands, "-DBUILD_experimental:BOOL=ON";
    }

    unshift @commands, 'cmake', $srcdir; # Add to beginning of list.

    my $old_options =
        $module->getPersistentOption('last-cmake-options') || '';
    my $builddir = $module->fullpath('build');

    if (($old_options ne get_list_digest(@commands)) ||
        $module->getOption('reconfigure') ||
        ! -e "$builddir/CMakeCache.txt" # File should exist only on successful cmake run
       )
    {
        info ("\tRunning g[cmake]...");

        # Remove any stray CMakeCache.txt
        safe_unlink ("$srcdir/CMakeCache.txt")   if -e "$srcdir/CMakeCache.txt";
        safe_unlink ("$builddir/CMakeCache.txt") if -e "$builddir/CMakeCache.txt";

        $module->setPersistentOption('last-cmake-options', get_list_digest(@commands));
        return log_command($module, "cmake", \@commands);
    }

    # Skip cmake run
    return 0;
}

1;
