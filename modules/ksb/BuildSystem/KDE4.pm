package ksb::BuildSystem::KDE4;

# Class responsible for building KDE4 CMake-based modules.

use strict;
use warnings;
use v5.10;

use ksb::Debug;
use ksb::Util;
use ksb::BuildSystem;

our @ISA = ('ksb::BuildSystem');

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

sub isProgressOutputSupported
{
    return 1;
}

sub prefixEnvironmentVariable
{
    return 'CMAKE_PREFIX_PATH';
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
        if ($numTests > 0) {
            warning ("\t$numTests tests failed for y[$module], consult latest/$module/test-results.log for info");
        }
        else {
            warning ("\tSome tests failed for y[$module], consult latest/$module/test-results.log for info");
        }

        return 0;
    }
    else {
        info ("\tAll tests ran successfully.");
    }

    return 1;
}

sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::KDE4');
    my $module = $self->module();

    # Use cmake to create the build directory (sh script return value
    # semantics).
    if (main::safe_run_cmake ($module))
    {
        error ("\tUnable to configure r[$module] with CMake!");
        return 0;
    }

    return 1;
}

1;
